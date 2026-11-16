// End-to-end test of the web app in real browser engines (Playwright):
// Chromium, Firefox and WebKit (Safari's engine).
//
//   node tools/web_e2e.mjs <url> [chromium|firefox|webkit ...] [--mock-devices]
//
// Default mode prints through the desktop web bridge on 127.0.0.1:9632 (start
// it with: BRIDGE_E2E_SECONDS=600 THERMAL_PHOTO_DUMP=/tmp/job.bin
// flutter test test/bridge_test.dart --plain-name 'e2e harness').
// --mock-devices (Chromium only) replaces navigator.serial / usb / bluetooth
// with fakes that record the bytes, exercising the Web Serial / WebUSB / Web
// Bluetooth transports without a device chooser.
import { createRequire } from 'node:module';
const require = createRequire(process.env.PLAYWRIGHT_DIR ? process.env.PLAYWRIGHT_DIR + '/' : import.meta.url);
const pw = require('playwright');

const args = process.argv.slice(2);
const url = args.find((a) => a.startsWith('http'));
const mock = args.includes('--mock-devices');
// --status-only: press "Status" instead of "Test page" (no paper used) on
// every printer the bridge lists — for runs against real hardware.
const statusOnly = args.includes('--status-only');
// --serve-as=<dir>: serve <dir> (a web build) as https://devilapi.github.io/
// via request interception — tests the real HTTPS origin calling the
// http://127.0.0.1 bridge (mixed content rules, CORS allowlist).
const serveAs = args.find((a) => a.startsWith('--serve-as='))?.slice(11);
const engines = args.filter((a) => ['chromium', 'firefox', 'webkit'].includes(a));
import fs from 'node:fs';
import path from 'node:path';
const types = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.wasm': 'application/wasm', '.html': 'text/html',
  '.json': 'application/json', '.png': 'image/png', '.ttf': 'font/ttf', '.otf': 'font/otf', '.css': 'text/css', '.bin': 'application/octet-stream' };
if (!url) throw new Error('usage: web_e2e.mjs <url> [engines] [--mock-devices]');

const mockScript = () => {
  window.__sent = { serial: [], usb: [], ble: [] };
  const sppInfo = { bluetoothServiceClassId: '00001101-0000-1000-8000-00805f9b34fb' };
  const port = {
    getInfo: () => sppInfo,
    async open(o) { window.__serialOpen = o; },
    async close() {},
    readable: new ReadableStream({
      start(c) { window.__serialRx = c; },
    }),
    writable: new WritableStream({
      write(chunk) {
        window.__sent.serial.push(...chunk);
        // answer DLE EOT n with "ready" (0x12) like the MP583
        if (chunk.length === 3 && chunk[0] === 0x10 && chunk[1] === 0x04) window.__serialRx.enqueue(new Uint8Array([0x12]));
      },
    }),
  };
  let granted = [];
  Object.defineProperty(navigator, 'serial', { value: {
    async getPorts() { return granted; },
    async requestPort(o) { window.__requestPortOptions = o; granted = [port]; return port; },
  } });
  const ep = (n, d) => ({ endpointNumber: n, direction: d, type: 'bulk', packetSize: 64 });
  const cfg = { configurationValue: 1, interfaces: [{ interfaceNumber: 0, alternate: { interfaceClass: 7, interfaceSubclass: 1, endpoints: [ep(1, 'out'), ep(1, 'in')] } }] };
  const dev = {
    vendorId: 0x0416, productId: 0x5011, productName: 'POS80 Printer USB', opened: false, configuration: null, configurations: [cfg],
    async open() { this.opened = true; }, async close() { this.opened = false; },
    async selectConfiguration() { this.configuration = cfg; },
    async claimInterface(n) { window.__claimed = n; }, async releaseInterface() {},
    async transferOut(e, d) { window.__sent.usb.push(...new Uint8Array(d.buffer, d.byteOffset, d.byteLength)); return { status: 'ok', bytesWritten: d.byteLength }; },
    async transferIn() { return { status: 'ok', data: new DataView(new Uint8Array([0x12]).buffer) }; },
  };
  let usbGranted = [];
  Object.defineProperty(navigator, 'usb', { value: {
    async getDevices() { return usbGranted; },
    async requestDevice(o) { window.__usbFilters = o; usbGranted = [dev]; return dev; },
  } });
  const chr = { uuid: '00002af1-0000-1000-8000-00805f9b34fb', properties: { write: true, writeWithoutResponse: true, notify: false },
    async writeValueWithoutResponse(v) { window.__sent.ble.push(...new Uint8Array(v.buffer, v.byteOffset, v.byteLength)); } };
  const svc = { uuid: '000018f0-0000-1000-8000-00805f9b34fb', async getCharacteristics() { return [chr]; } };
  const gatt = { connected: false, async connect() { this.connected = true; return this; }, disconnect() { this.connected = false; },
    async getPrimaryServices() { return [svc]; } };
  Object.defineProperty(navigator, 'bluetooth', { value: {
    async getAvailability() { return true; },
    async requestDevice(o) { window.__bleOptions = o; return { id: 'ble-1', name: 'MP583', gatt }; },
  } });
};

async function run(engine) {
  const browser = await pw[engine].launch();
  const ctx = await browser.newContext({ serviceWorkers: 'block' });
  if (serveAs) {
    await ctx.route('https://devilapi.github.io/**', (route) => {
      let p = new URL(route.request().url()).pathname;
      if (p.endsWith('/')) p += 'index.html';
      const f = path.join(serveAs, p);
      if (!fs.existsSync(f)) return route.fulfill({ status: 404, body: 'not found' });
      route.fulfill({ status: 200, body: fs.readFileSync(f), headers: { 'content-type': types[path.extname(f)] || 'application/octet-stream' } });
    });
  }
  const page = await ctx.newPage();
  const logs = [];
  page.on('console', (m) => logs.push(`[${m.type()}] ${m.text()}`));
  page.on('pageerror', (e) => logs.push(`[pageerror] ${e}`));
  if (mock) await page.addInitScript(mockScript);
  const t0 = Date.now();
  await page.goto(url);
  // Flutter renders to canvas; turn on its semantics tree to get real buttons.
  await page.locator('flt-semantics-placeholder').waitFor({ state: 'attached', timeout: 60000 });
  await page.locator('flt-semantics-placeholder').dispatchEvent('click');
  const status = () => page.evaluate(() => [...document.querySelectorAll('flt-semantics')]
    .map((e) => e.getAttribute('aria-label') || '').filter((l) => l.startsWith('Status: ')).map((l) => l.slice(8)));
  const waitStatus = async (re, what) => {
    for (let i = 0; i < 120; i++) {
      const s = (await status()).join(' | ');
      if (re.test(s)) return s;
      await page.waitForTimeout(500);
    }
    throw new Error(`${engine}: timed out waiting for ${what}; status: ${(await status()).join(' | ')}\n${logs.join('\n')}`);
  };
  const results = [];
  const flows = mock
    ? [['Add Bluetooth / serial printer', 'serial'], ['Add USB printer', 'usb'], ['Add Bluetooth LE printer', 'ble']]
    : [['Use desktop app (bridge)', 'bridge']];
  if (statusOnly) {
    await page.getByRole('button', { name: 'Use desktop app (bridge)' }).click({ timeout: 30000 });
    await waitStatus(/Added|Could not add/, 'bridge pairing');
    // open the Connection dropdown and query each listed printer
    const names = await page.evaluate(() => [...document.querySelectorAll('flt-semantics[role=button]')]
      .map((e) => e.getAttribute('aria-label') || e.innerText).filter((t) => t && t.startsWith('Desktop app:')));
    for (const n of names) {
      await page.getByRole('button', { name: n }).first().click();
      await page.waitForTimeout(500);
      const items = page.getByRole('menuitem');
      if (await items.count()) {
        for (let i = 0; i < await items.count(); i++) {
          const label = (await items.nth(i).innerText()) || (await items.nth(i).getAttribute('aria-label'));
          await items.nth(i).click();
          await page.getByRole('button', { name: 'Status' }).click();
          const s = await waitStatus(/Printer:|Status failed|cannot read/, `status of ${label}`);
          results.push(`${label} -> ${s}`);
          if (i + 1 < await items.count()) await page.getByRole('button', { name: /Desktop app:/ }).first().click();
          await page.waitForTimeout(500);
        }
      } else {
        await page.keyboard.press('Escape');
        await page.getByRole('button', { name: 'Status' }).click();
        results.push(`${n} -> ${await waitStatus(/Printer:|Status failed|cannot read/, 'status')}`);
      }
    }
    await browser.close();
    return `${engine} OK in ${((Date.now() - t0) / 1000).toFixed(1)} s\n  ${results.join('\n  ')}`;
  }
  for (const [button, kind] of flows) {
    if (kind === 'bridge' && engine === 'webkit' && url.startsWith('https:')) {
      // Safari blocks https -> http://127.0.0.1: expect the hand-off tab instead.
      const popup = ctx.waitForEvent('page', { timeout: 15000 });
      await page.getByRole('button', { name: button }).click({ timeout: 30000 });
      const p = await popup;
      results.push(`bridge: hand-off tab opened at ${p.url()}`);
      continue;
    }
    await page.getByRole('button', { name: button }).click({ timeout: 30000 });
    await waitStatus(/Added|Could not add/, `${kind} pairing`);
    const added = (await status()).join(' | ');
    if (!/Added/.test(added)) throw new Error(`${engine} ${kind}: ${added}\n${logs.join('\n')}`);
    await page.getByRole('button', { name: 'Test page' }).click();
    const s = await waitStatus(/Sent test page|Failed/, `${kind} print`);
    if (/Failed/.test(s)) throw new Error(`${engine} ${kind}: ${s}\n${logs.join('\n')}`);
    const bytes = mock ? await page.evaluate((k) => window.__sent[k].length, kind) : null;
    results.push(`${kind}: ${s.match(/Sent[^|]*/)?.[0]}${bytes != null ? ` [${bytes} bytes captured]` : ''}`);
  }
  if (mock) results.push(`requestPort options: ${JSON.stringify(await page.evaluate(() => window.__requestPortOptions))}`,
    `serial open: ${JSON.stringify(await page.evaluate(() => window.__serialOpen))}`,
    `usb filters: ${JSON.stringify(await page.evaluate(() => window.__usbFilters))}`);
  await browser.close();
  return `${engine} OK in ${((Date.now() - t0) / 1000).toFixed(1)} s\n  ${results.join('\n  ')}`;
}

let failed = false;
for (const e of engines.length ? engines : ['chromium', 'firefox', 'webkit']) {
  try {
    console.log(await run(e));
  } catch (err) {
    failed = true;
    console.log(`${e} FAILED: ${err.message}`);
  }
}
process.exit(failed ? 1 : 0);
