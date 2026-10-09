package com.tuma.lan

import android.app.UiModeManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import androidx.fragment.app.FragmentActivity
import com.nativephp.mobile.bridge.BridgeFunction
import com.nativephp.mobile.utils.NativeActionCoordinator
import fi.iki.elonen.NanoHTTPD
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.OutputStream
import java.net.DatagramPacket
import java.net.InetAddress
import java.net.MulticastSocket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Bridge functions for the tuma/mobile-lan plugin. Namespace: "Lan.*".
 *
 * Every function is thin: it hands the request to [LanManager], which owns the
 * long-lived multicast discovery loop and the HTTP receive server on
 * background threads. Results and progress come back to PHP as events under
 * Tuma\Lan\Events\*.
 */
object LanFunctions {

    class StartDiscovery(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val deviceInfo = mapToJson(parameters["deviceInfo"])
            LanManager.attach(activity)
            LanManager.startDiscovery(deviceInfo)
            return mapOf("ok" to true)
        }
    }

    class StopDiscovery(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            LanManager.stopDiscovery()
            return mapOf("ok" to true)
        }
    }

    class StartServer(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val deviceInfo = mapToJson(parameters["deviceInfo"])
            val incomingDir = parameters["incomingDir"] as? String ?: return mapOf("ok" to false)
            val publicFolder = (parameters["publicFolder"] as? String)?.takeIf { it.isNotBlank() }
            LanManager.attach(activity)
            val port = LanManager.startServer(deviceInfo, incomingDir, publicFolder)
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

    class Respond(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val requestId = parameters["requestId"] as? String ?: return mapOf("ok" to false)
            val accepted = stringList(parameters["acceptedFileIds"])
            val sessionId = parameters["sessionId"] as? String
            val status = (parameters["status"] as? Number)?.toInt() ?: 200
            LanManager.respond(requestId, accepted, sessionId, status)
            return mapOf("ok" to true)
        }
    }

    class CancelSession(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val sessionId = parameters["sessionId"] as? String ?: return mapOf("ok" to false)
            LanManager.cancelSession(sessionId, "sender")
            return mapOf("ok" to true)
        }
    }

    class LocalIp(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            LanManager.attach(activity)
            return mapOf("ip" to (LanManager.localIp() ?: ""))
        }
    }

    /**
     * Force the app into light or dark mode, or back to following the system.
     * The OS persists the choice across launches (API 31+) and fires a uiMode
     * configuration change, so the renderers, system bars and PHP's
     * AppearanceChanged listener all follow.
     */
    class SetAppearance(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val mode = when (parameters["mode"] as? String) {
                "light" -> UiModeManager.MODE_NIGHT_NO
                "dark" -> UiModeManager.MODE_NIGHT_YES
                else -> UiModeManager.MODE_NIGHT_AUTO
            }
            val uiModeManager = activity.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
                ?: return mapOf("ok" to false)

            activity.runOnUiThread { uiModeManager.setApplicationNightMode(mode) }
            return mapOf("ok" to true)
        }
    }

    /** Open a received content:// URI (Downloads/Tumira) in the system viewer. */
    class OpenFile(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val uri = (parameters["uri"] as? String)?.let(Uri::parse) ?: return mapOf("ok" to false)
            val resolver = activity.contentResolver

            // A deleted Downloads entry no longer resolves; report it so PHP can say so.
            val exists = runCatching { resolver.openFileDescriptor(uri, "r")?.use { true } ?: false }.getOrDefault(false)
            if (!exists) return mapOf("ok" to false)

            val mime = (parameters["mime"] as? String)?.takeIf { it.isNotBlank() }
                ?: resolver.getType(uri)
                ?: "*/*"

            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }

            return try {
                activity.runOnUiThread {
                    activity.startActivity(Intent.createChooser(intent, null))
                }
                mapOf("ok" to true)
            } catch (e: Exception) {
                Log.e(LanManager.TAG, "open failed for $uri", e)
                mapOf("ok" to false)
            }
        }
    }
}

/**
 * Convert a decoded bridge param into a JSONObject we can hold/serve. The
 * bridge passes nested PHP arrays as JSONObject, not Map.
 */
private fun mapToJson(value: Any?): JSONObject =
    when (value) {
        is JSONObject -> value
        is Map<*, *> -> JSONObject(value.entries.associate { (k, v) -> k.toString() to (v ?: JSONObject.NULL) })
        is String -> runCatching { JSONObject(value) }.getOrDefault(JSONObject())
        else -> JSONObject()
    }

/** A bridge param PHP sent as a list: JSONArray from the bridge, or a List. */
private fun stringList(value: Any?): List<String> =
    when (value) {
        is JSONArray -> (0 until value.length()).mapNotNull { value.opt(it) as? String }
        is List<*> -> value.filterIsInstance<String>()
        else -> emptyList()
    }

/**
 * Owns discovery and the receive listener. All heavy work runs off the PHP UI
 * thread; only metadata and progress numbers cross back as events.
 */
object LanManager {

    const val TAG = "TumaLan"
    const val MULTICAST_GROUP = "224.0.0.167"
    const val MULTICAST_PORT = 53317

    private var appContext: Context? = null
    private var activityRef: FragmentActivity? = null

    private var deviceInfo: JSONObject = JSONObject()
    private var incomingDir: String? = null

    /** When set, uploads stream into MediaStore Downloads/{publicFolder}. */
    private var publicFolder: String? = null

    private var server: LanHttpServer? = null
    private var discovery: DiscoveryManager? = null

    /** Parked prepare-upload requests awaiting a PHP decision, by requestId. */
    private val pending = ConcurrentHashMap<String, PendingRequest>()

    /** Live sessions: sessionId -> (fileId -> token). */
    private val sessions = ConcurrentHashMap<String, MutableMap<String, String>>()

    /** Accepted file names: sessionId -> (fileId -> sanitized fileName). */
    private val sessionFiles = ConcurrentHashMap<String, MutableMap<String, String>>()

    /** Declared mime types: sessionId -> (fileId -> fileType). */
    private val sessionMimes = ConcurrentHashMap<String, MutableMap<String, String>>()

    /** MediaStore entries still being written: sessionId -> uris. Deleted on cancel. */
    private val pendingUris = ConcurrentHashMap<String, MutableSet<Uri>>()

    fun attach(activity: FragmentActivity) {
        activityRef = activity
        appContext = activity.applicationContext
    }

    // ── Discovery ────────────────────────────────────────────────

    fun startDiscovery(info: JSONObject) {
        deviceInfo = info
        stopDiscovery()
        val context = appContext ?: return
        discovery = DiscoveryManager(context, info, this).also { it.start() }
    }

    fun stopDiscovery() {
        discovery?.stop()
        discovery = null
    }

    // ── Server ───────────────────────────────────────────────────

    /**
     * Bind the listener on the announced port, falling back to port + 1 when
     * it is busy. Returns the bound port, or null if both attempts failed.
     * The served device info is updated to the bound port.
     */
    fun startServer(info: JSONObject, dir: String, folder: String?): Int? {
        deviceInfo = info
        incomingDir = dir
        publicFolder = folder
        File(dir).mkdirs()

        val preferred = info.optInt("port", 53317)
        stopServer()

        var lastError: Exception? = null
        for (port in listOf(preferred, preferred + 1)) {
            try {
                server = LanHttpServer(port, this).also { it.start(NanoHTTPD.SOCKET_READ_TIMEOUT, true) }
                deviceInfo.put("port", port)
                Log.d(TAG, "receive server started on :$port, incoming=$dir, publicFolder=$folder")
                return port
            } catch (e: Exception) {
                Log.w(TAG, "could not bind :$port", e)
                lastError = e
            }
        }

        dispatch("ServerError", JSONObject().put("message", lastError?.message ?: "Could not start listener"))
        return null
    }

    fun stopServer() {
        server?.stop()
        server = null
        pending.clear()
        sessions.clear()
        sessionFiles.clear()
        sessionMimes.clear()
    }

    fun deviceInfoJson(): JSONObject = deviceInfo

    fun incomingDir(): String? = incomingDir

    // ── prepare-upload parking / respond ─────────────────────────

    fun parkUploadRequest(sender: JSONObject, files: JSONArray, pinProvided: String?): PendingRequest {
        val requestId = UUID.randomUUID().toString()
        val request = PendingRequest(requestId, files)
        pending[requestId] = request

        val payload = JSONObject()
            .put("requestId", requestId)
            .put("sender", sender)
            .put("files", files)
        if (pinProvided != null) {
            payload.put("pinProvided", pinProvided)
        }

        Log.d(TAG, "prepare-upload parked $requestId from ${sender.optString("alias")} (${files.length()} files)")
        dispatch("UploadRequested", payload)
        return request
    }

    fun respond(requestId: String, acceptedFileIds: List<String>, sessionId: String?, status: Int) {
        val request = pending[requestId] ?: return
        Log.d(TAG, "respond $requestId status=$status accepted=${acceptedFileIds.size}")
        request.status = status
        request.acceptedFileIds = acceptedFileIds

        if (status == 200 && sessionId != null) {
            val tokens = mutableMapOf<String, String>()
            val names = mutableMapOf<String, String>()
            val mimes = mutableMapOf<String, String>()
            for (i in 0 until request.files.length()) {
                val file = request.files.optJSONObject(i) ?: continue
                val id = file.optString("id")
                if (id in acceptedFileIds) {
                    tokens[id] = UUID.randomUUID().toString()
                    names[id] = sanitizeFileName(file.optString("fileName", id))
                    file.optString("fileType").takeIf { it.isNotBlank() }?.let { mimes[id] = it }
                }
            }
            request.sessionId = sessionId
            request.tokens = tokens
            sessions[sessionId] = tokens
            sessionFiles[sessionId] = names
            sessionMimes[sessionId] = mimes
        }

        request.latch.countDown()
    }

    fun fileNameFor(sessionId: String, fileId: String): String? = sessionFiles[sessionId]?.get(fileId)

    // ── Upload destinations ──────────────────────────────────────

    /** Where one upload's bytes go, and how to finish or abandon it. */
    class UploadTarget(
        val output: OutputStream,
        val location: String,
        val commit: () -> Unit,
        val discard: () -> Unit,
    )

    /**
     * Open the destination for an upload: a pending MediaStore Downloads entry
     * when a public folder is configured, otherwise {incomingDir}/{sessionId}/{fileName}.
     */
    fun openUploadTarget(sessionId: String, fileId: String): UploadTarget? {
        val fileName = fileNameFor(sessionId, fileId) ?: "file"
        val folder = publicFolder
        val context = appContext

        if (folder != null && context != null) {
            return openMediaStoreTarget(context, sessionId, fileId, fileName, folder)
        }

        val dir = incomingDir ?: return null
        val destination = File(File(dir, sessionId).apply { mkdirs() }, fileName)
        return UploadTarget(
            output = destination.outputStream(),
            location = destination.absolutePath,
            commit = {},
            discard = { destination.delete() },
        )
    }

    private fun openMediaStoreTarget(context: Context, sessionId: String, fileId: String, fileName: String, folder: String): UploadTarget? {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            sessionMimes[sessionId]?.get(fileId)?.let { put(MediaStore.Downloads.MIME_TYPE, it) }
            put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$folder")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }

        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return null
        val output = resolver.openOutputStream(uri) ?: run {
            resolver.delete(uri, null, null)
            return null
        }
        pendingUris.getOrPut(sessionId) { ConcurrentHashMap.newKeySet() }.add(uri)

        return UploadTarget(
            output = output,
            location = uri.toString(),
            commit = {
                resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
                pendingUris[sessionId]?.remove(uri)
            },
            discard = {
                runCatching { resolver.delete(uri, null, null) }
                pendingUris[sessionId]?.remove(uri)
            },
        )
    }

    private fun sanitizeFileName(name: String): String {
        val cleaned = name.replace(Regex("[/\\\\]"), "_").trim()
        return cleaned.ifEmpty { "file" }
    }

    fun completePending(requestId: String) {
        pending.remove(requestId)
    }

    // ── upload validation / progress ─────────────────────────────

    fun validToken(sessionId: String?, fileId: String?, token: String?): Boolean {
        if (sessionId == null || fileId == null || token == null) return false
        return sessions[sessionId]?.get(fileId) == token
    }

    fun cancelSession(sessionId: String, reason: String) {
        sessions.remove(sessionId)
        sessionFiles.remove(sessionId)
        sessionMimes.remove(sessionId)
        incomingDir?.let { File(it, sessionId).deleteRecursively() }
        val resolver = appContext?.contentResolver
        pendingUris.remove(sessionId)?.forEach { uri -> runCatching { resolver?.delete(uri, null, null) } }
        dispatch("SessionCancelled", JSONObject().put("sessionId", sessionId).put("reason", reason))
    }

    fun emitProgress(sessionId: String, fileId: String, received: Long, total: Long) {
        dispatch(
            "UploadProgress",
            JSONObject()
                .put("sessionId", sessionId)
                .put("fileId", fileId)
                .put("bytesReceived", received)
                .put("bytesTotal", total)
        )
    }

    fun emitComplete(sessionId: String, fileId: String, path: String) {
        Log.d(TAG, "upload complete $fileId -> $path")
        dispatch(
            "UploadComplete",
            JSONObject().put("sessionId", sessionId).put("fileId", fileId).put("path", path)
        )
    }

    fun emitPeerFound(peer: JSONObject) = dispatch("PeerFound", peer)

    // ── Local IP ─────────────────────────────────────────────────

    @Suppress("DEPRECATION")
    fun localIp(): String? {
        val wifi = appContext?.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
        val ipInt = wifi.connectionInfo?.ipAddress ?: return null
        if (ipInt == 0) return fallbackIp()
        return String.format(
            "%d.%d.%d.%d",
            ipInt and 0xff,
            ipInt shr 8 and 0xff,
            ipInt shr 16 and 0xff,
            ipInt shr 24 and 0xff
        )
    }

    private fun fallbackIp(): String? = runCatching {
        java.net.NetworkInterface.getNetworkInterfaces().toList()
            .flatMap { it.inetAddresses.toList() }
            .firstOrNull { !it.isLoopbackAddress && it is java.net.Inet4Address }
            ?.hostAddress
    }.getOrNull()

    // ── Event bridge ─────────────────────────────────────────────

    fun dispatch(event: String, payload: JSONObject) {
        val activity = activityRef ?: return
        val fqcn = "Tuma\\Lan\\Events\\$event"
        activity.runOnUiThread {
            NativeActionCoordinator.dispatchEvent(activity, fqcn, payload.toString())
        }
    }

    /** A parked prepare-upload request, blocking the HTTP thread until PHP answers. */
    class PendingRequest(val requestId: String, val files: JSONArray) {
        val latch = CountDownLatch(1)
        var status: Int = 403
        var acceptedFileIds: List<String> = emptyList()
        var sessionId: String? = null
        var tokens: Map<String, String> = emptyMap()

        /** Wait up to 60s for PHP; on timeout the receiver replies 403. */
        fun await(): Boolean = latch.await(60, TimeUnit.SECONDS)
    }
}
