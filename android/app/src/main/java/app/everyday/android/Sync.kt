package app.everyday.android

import android.content.Context
import android.graphics.Bitmap
import android.net.wifi.WifiManager
import androidx.compose.runtime.*
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import kotlinx.coroutines.delay
import org.json.JSONObject

/**
 * Wi‑Fi sync with the person's other devices. The Rust core runs the listener and mDNS (windows/mobile/src/synchost.rs);
 * Android only has to allow multicast while the app is open and reload when another device changed something.
 */
object SyncLink {
    private var lock: WifiManager.MulticastLock? = null
    var status by mutableStateOf(JSONObject())

    suspend fun start(ctx: Context) {
        if (lock == null) lock = (ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).createMulticastLock("everyday-sync").apply { setReferenceCounted(false); acquire() }
        runCatching { status = Core.run("syncStart") as JSONObject }
    }

    fun release() { runCatching { lock?.release() }; lock = null }

    /** Polls while the app is open; reloads the screens when another device changed data here. */
    suspend fun watch(model: AppModel) {
        var seen = -1L
        while (true) {
            runCatching { status = Core.run("syncStatus") as JSONObject }
            if (status.optBoolean("setupWaiting")) runCatching {
                // Another device handed over accounts, keys and settings: store them and start fresh with them.
                (Core.run("syncTakeSetup") as? String)?.let { msg -> model.toast(msg); model.start() }
            }
            val c = status.optLong("changes")
            if (seen >= 0 && c != seen) { model.loadLocal(); model.reloadTopics() }
            seen = c
            delay(8000)
        }
    }

    fun qr(text: String, size: Int = 640): Bitmap {
        val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size)
        val px = IntArray(size * size) { i -> if (m[i % size, i / size]) 0xFF000000.toInt() else 0xFFFFFFFF.toInt() }
        return Bitmap.createBitmap(px, size, size, Bitmap.Config.ARGB_8888)
    }
}
