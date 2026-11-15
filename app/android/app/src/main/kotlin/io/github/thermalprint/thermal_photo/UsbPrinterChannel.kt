package io.github.thermalprint.thermal_photo

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Driverless USB printing via Android's USB Host API: find an interface with a
 * bulk-OUT endpoint (USB printer class 0x07, CDC data 0x0A or vendor 0xFF) and
 * write raw ESC/POS bytes to it. Mirrors what the vendor's usbsdk.jar does.
 */
class UsbPrinterChannel(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "thermal_photo/usb")
    private val manager = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val io = Executors.newSingleThreadExecutor()
    private val open = HashMap<String, Pair<UsbDeviceConnection, Pair<UsbInterface, UsbEndpoint>>>()
    private var pendingPermission: Pair<String, MethodChannel.Result>? = null

    private val action = "${context.packageName}.USB_PERMISSION"
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            if (intent.action != action) return
            val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
            pendingPermission?.second?.success(granted)
            pendingPermission = null
        }
    }

    init {
        channel.setMethodCallHandler(this)
        val filter = IntentFilter(action)
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        try { context.unregisterReceiver(receiver) } catch (_: Exception) {}
        open.values.forEach { (conn, ie) -> conn.releaseInterface(ie.first); conn.close() }
        open.clear()
        io.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "list" -> result.success(manager.deviceList.values.mapNotNull { describe(it) })
            "requestPermission" -> requestPermission(call.argument<String>("name")!!, result)
            "open" -> openDevice(call.argument<String>("name")!!, result)
            "write" -> {
                val name = call.argument<String>("name")!!
                val data = call.argument<ByteArray>("data")!!
                val timeout = call.argument<Int>("timeoutMs") ?: 5000
                io.execute { write(name, data, timeout, result) }
            }
            "close" -> {
                open.remove(call.argument<String>("name")!!)?.let { (conn, ie) ->
                    conn.releaseInterface(ie.first); conn.close()
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun findBulkOut(dev: UsbDevice): Pair<UsbInterface, UsbEndpoint>? {
        // Prefer printer class, then CDC data, then anything with bulk OUT.
        val order = listOf(UsbConstants.USB_CLASS_PRINTER, UsbConstants.USB_CLASS_CDC_DATA, -1)
        for (cls in order) {
            for (i in 0 until dev.interfaceCount) {
                val intf = dev.getInterface(i)
                if (cls != -1 && intf.interfaceClass != cls) continue
                for (e in 0 until intf.endpointCount) {
                    val ep = intf.getEndpoint(e)
                    if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK && ep.direction == UsbConstants.USB_DIR_OUT) {
                        return intf to ep
                    }
                }
            }
        }
        return null
    }

    private fun describe(dev: UsbDevice): Map<String, Any?>? {
        val bulk = findBulkOut(dev) ?: return null
        return mapOf(
            "name" to dev.deviceName,
            "vendorId" to dev.vendorId,
            "productId" to dev.productId,
            "product" to (try { dev.productName } catch (_: Exception) { null }),
            "manufacturer" to (try { dev.manufacturerName } catch (_: Exception) { null }),
            "interfaceClass" to bulk.first.interfaceClass,
            "hasPermission" to manager.hasPermission(dev),
        )
    }

    private fun requestPermission(name: String, result: MethodChannel.Result) {
        val dev = manager.deviceList[name] ?: return result.error("not_found", name, null)
        if (manager.hasPermission(dev)) return result.success(true)
        pendingPermission?.second?.success(false)
        pendingPermission = name to result
        val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val pi = PendingIntent.getBroadcast(context, 0, Intent(action).setPackage(context.packageName), flags)
        manager.requestPermission(dev, pi)
    }

    private fun openDevice(name: String, result: MethodChannel.Result) {
        if (open.containsKey(name)) return result.success(null)
        val dev = manager.deviceList[name] ?: return result.error("not_found", name, null)
        if (!manager.hasPermission(dev)) return result.error("no_permission", name, null)
        val bulk = findBulkOut(dev) ?: return result.error("no_endpoint", name, null)
        val conn = manager.openDevice(dev) ?: return result.error("open_failed", name, null)
        if (!conn.claimInterface(bulk.first, true)) {
            conn.close()
            return result.error("claim_failed", name, null)
        }
        open[name] = conn to bulk
        result.success(null)
    }

    private fun write(name: String, data: ByteArray, timeoutMs: Int, result: MethodChannel.Result) {
        val entry = open[name]
        if (entry == null) {
            post { result.error("not_open", name, null) }
            return
        }
        val (conn, ie) = entry
        val max = 16384
        var off = 0
        while (off < data.size) {
            val len = minOf(max, data.size - off)
            val n = conn.bulkTransfer(ie.second, data, off, len, timeoutMs)
            if (n < 0) {
                post { result.error("write_failed", "bulkTransfer returned $n at offset $off", null) }
                return
            }
            off += n
        }
        post { result.success(data.size) }
    }

    private fun post(r: () -> Unit) = android.os.Handler(context.mainLooper).post(r)
}
