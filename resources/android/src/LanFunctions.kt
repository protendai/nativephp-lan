package com.protendai.lan

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.ThumbnailUtils
import android.net.Uri
import android.net.wifi.WifiManager
import android.util.Log
import android.util.Size
import androidx.fragment.app.FragmentActivity
import com.nativephp.mobile.bridge.BridgeFunction
import java.io.File

/**
 * Bridge functions for protendai/nativephp-lan. Namespace: "Lan.*".
 *
 * Every function is thin: it hands the request to [LanManager], which owns
 * the multicast discovery loop and the HTTP receive server on background
 * threads. Results and progress come back to PHP as events under
 * Protendai\Lan\Events\*. Start calls carry a "config" object (service id,
 * API prefix, ports, limits) built by the PHP facade from config/lan.php.
 */
object LanFunctions {

    /** Params: deviceInfo, config. Multicast announce + listen, plus an HTTP probe of the /24. */
    class StartDiscovery(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            LanManager.attach(activity)
            LanManager.startDiscovery(asJson(parameters["deviceInfo"]), LanConfig.from(parameters["config"]))
            return mapOf("ok" to true)
        }
    }

    /** Params: deviceInfo, prefix ("192.168.49"), seconds, config. Emits PeerFound for the first device that answers. */
    class SweepSubnet(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val prefix = (parameters["prefix"] as? String)?.trim()?.trimEnd('.')
                ?.takeIf { it.matches(Regex("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$")) }
                ?: return mapOf("ok" to false)
            val seconds = ((parameters["seconds"] as? Number)?.toInt() ?: 20).coerceIn(1, 300)
            LanManager.attach(activity)
            LanManager.sweepSubnet(asJson(parameters["deviceInfo"]), prefix, seconds, LanConfig.from(parameters["config"]))
            return mapOf("ok" to true)
        }
    }

    /**
     * Params: deviceInfo, host, port, seconds, config. POSTs register to a
     * server until it answers, so that server learns our address.
     */
    class Announce(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val host = (parameters["host"] as? String)?.takeIf { it.isNotBlank() } ?: return mapOf("ok" to false)
            val config = LanConfig.from(parameters["config"])
            val port = (parameters["port"] as? Number)?.toInt()?.takeIf { it in 1..65535 } ?: config.port
            val seconds = ((parameters["seconds"] as? Number)?.toInt() ?: 20).coerceIn(1, 300)
            LanManager.attach(activity)
            LanManager.announce(asJson(parameters["deviceInfo"]), host, port, seconds, config)
            return mapOf("ok" to true)
        }
    }

    class StopDiscovery(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            LanManager.stopDiscovery()
            return mapOf("ok" to true)
        }
    }

    /** Params: deviceInfo, incomingDir, publicFolder (optional), config. Returns the bound port. */
    class StartServer(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val incomingDir = (parameters["incomingDir"] as? String)?.takeIf { it.isNotBlank() } ?: return mapOf("ok" to false)
            val publicFolder = (parameters["publicFolder"] as? String)?.takeIf { it.isNotBlank() }?.let { FileNames.sanitize(it) }
            LanManager.attach(activity)
            val port = LanManager.startServer(asJson(parameters["deviceInfo"]), incomingDir, publicFolder, LanConfig.from(parameters["config"]))
                ?: return mapOf("ok" to false)
            return mapOf("ok" to true, "port" to port)
        }
    }

    class StopServer(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            LanManager.stopServer()
            return mapOf("ok" to true)
        }
    }

    /** Params: requestId, acceptedFileIds, sessionId, status. ok=false when the request is gone. */
    class Respond(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val requestId = parameters["requestId"] as? String ?: return mapOf("ok" to false, "error" to "requestId is required")
            val accepted = stringList(parameters["acceptedFileIds"])
            val sessionId = parameters["sessionId"] as? String
            val status = (parameters["status"] as? Number)?.toInt() ?: 200
            return LanManager.respond(requestId, accepted, sessionId, status)
        }
    }

    /** Params: sessionId. The receiving app cancels: uploads stop, partial files go, SessionCancelled(receiver). */
    class CancelSession(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val sessionId = parameters["sessionId"] as? String ?: return mapOf("ok" to false)
            return mapOf("ok" to LanManager.cancelSession(sessionId, "receiver"))
        }
    }

    /** Whether the Wi-Fi radio is on. Joining a network isn't needed for direct links. */
    class WifiEnabled(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val wifi = activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            return mapOf("enabled" to (wifi?.isWifiEnabled ?: true))
        }
    }

    class LocalIp(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            LanManager.attach(activity)
            return mapOf("ip" to (LanManager.localIp() ?: ""))
        }
    }

    /** Utility: system document picker, multi-select. FilesPicking { count } then FilesPicked { files }. */
    class PickFiles(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            LanManager.attach(activity)
            val mimeTypes = stringList(parameters["mimeTypes"]).ifEmpty { listOf("*/*") }
            PickFilesFragment.launch(activity, mimeTypes.toTypedArray())
            return mapOf("ok" to true)
        }
    }

    /** Utility: system photo picker (photos and videos), multi-select. Same events as PickFiles. */
    class PickMedia(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            LanManager.attach(activity)
            PickFilesFragment.launchMedia(activity)
            return mapOf("ok" to true)
        }
    }

    /**
     * Utility: write a small JPEG preview of an image or video to `dest`.
     * `source` is a file path or a content:// URI.
     */
    class Thumbnail(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val source = parameters["source"] as? String ?: return mapOf("ok" to false)
            val dest = parameters["dest"] as? String ?: return mapOf("ok" to false)
            val mime = parameters["mime"] as? String ?: ""
            val edge = ((parameters["size"] as? Number)?.toInt() ?: 256).coerceIn(16, 2048)
            val size = Size(edge, edge)

            val bitmap = runCatching {
                if (source.startsWith("content://")) {
                    activity.contentResolver.loadThumbnail(Uri.parse(source), size, null)
                } else if (mime.startsWith("video/")) {
                    ThumbnailUtils.createVideoThumbnail(File(source), size, null)
                } else {
                    ThumbnailUtils.createImageThumbnail(File(source), size, null)
                }
            }.onFailure { Log.w(LanManager.TAG, "thumbnail failed", it) }.getOrNull()
                ?: return mapOf("ok" to false)

            val written = runCatching {
                File(dest).parentFile?.mkdirs()
                File(dest).outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 80, it) }
            }.getOrDefault(false)
            bitmap.recycle()

            return mapOf("ok" to written)
        }
    }

    /** Utility: open a content:// URI (or file the app can share) in the system viewer. */
    class OpenFile(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val uri = (parameters["uri"] as? String)?.takeIf { it.isNotBlank() }?.let(Uri::parse) ?: return mapOf("ok" to false)
            val resolver = activity.contentResolver

            // A deleted Downloads entry no longer resolves; report it so PHP can say so.
            val exists = runCatching { resolver.openFileDescriptor(uri, "r")?.use { true } ?: false }.getOrDefault(false)
            if (!exists) return mapOf("ok" to false)

            val mime = (parameters["mime"] as? String)?.takeIf { it.isNotBlank() }
                ?: runCatching { resolver.getType(uri) }.getOrNull()
                ?: "*/*"

            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }

            activity.runOnUiThread {
                try {
                    activity.startActivity(Intent.createChooser(intent, null))
                } catch (e: Exception) {
                    Log.w(LanManager.TAG, "open failed", e)
                }
            }
            return mapOf("ok" to true)
        }
    }
}
