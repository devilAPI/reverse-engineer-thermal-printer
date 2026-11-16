/// Web bridge: the desktop app listens on 127.0.0.1 so the web app can
/// print in browsers without device APIs (Firefox, Safari) or where the OS
/// driver blocks WebUSB (Windows usbprint.sys). See docs/WEB.md.
///
///   GET  /v1/printers                  -> {"app","bridge","printers":[...]}
///   POST /v1/print?transport=&id=      body = raw ESC/POS -> {"ok","message"}
///   GET  /v1/status?transport=&id=     -> {"ok","message"}
///   GET  /                             -> redirect to the proxied web app
///
/// Only pages from [allowedOrigins] get CORS access (any other website can't
/// read the list or print); requests without an Origin (curl) are allowed —
/// they come from local programs, which could reach the printer anyway.
library;

const bridgePort = 9632;

/// The bridge also serves the web app itself, proxied from GitHub Pages, at
/// http://127.0.0.1:9632/ — page and bridge then share one origin, which is
/// the only way Safari allows (it blocks https pages from calling http
/// localhost as mixed content; RE log §18).
const webAppUpstream = 'https://devilapi.github.io';
const webAppPath = '/reverse-engineer-thermal-printer/';
const bridgeVersion = 1;

/// Exact origins, plus any port on loopback for local development.
const allowedOrigins = ['https://devilapi.github.io'];

bool isAllowedOrigin(String origin) {
  if (allowedOrigins.contains(origin)) return true;
  final u = Uri.tryParse(origin);
  if (u == null || !(u.scheme == 'http' || u.scheme == 'https')) return false;
  return u.host == 'localhost' || u.host == '127.0.0.1' || u.host == '[::1]' || u.host == '::1';
}
