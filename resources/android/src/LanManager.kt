package com.protendai.lan

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import androidx.fragment.app.FragmentActivity
import com.nativephp.mobile.utils.NativeActionCoordinator
import fi.iki.elonen.NanoHTTPD
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.OutputStream
import java.lang.ref.WeakReference
import java.net.InetSocketAddress
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * Owns discovery and the receive listener. All heavy work runs off the PHP
 * thread; only metadata and progress numbers cross back as events.
 * Lifecycle calls (start/stop) are synchronized; request state lives in
 * concurrent maps touched by the HTTP threads.
 */
object LanManager {

    const val TAG = "NativePhpLan"
    private const val EVENT_NAMESPACE = "Protendai\\Lan\\Events\\"

    /** Prepare-upload requests allowed to wait for PHP at once; more get 429. */
    private const val MAX_PENDING = 8

    private var activityRef: WeakReference<FragmentActivity>? = null

    @Volatile
    private var appContext: Context? = null

    /** Settings of the running server (discovery keeps its own snapshot). */
    @Volatile
    var config: LanConfig = LanConfig()
        private set

    /** Device info served by /info and /register: an immutable JSON string, replaced whole. */
    @Volatile
    private var deviceInfoText: String = "{}"

    @Volatile
    private var incomingDir: String? = null

    /** When set, uploads stream into MediaStore Downloads/{publicFolder}. */
    @Volatile
    private var publicFolder: String? = null

    private var server: LanHttpServer? = null
    private var discovery: DiscoveryManager? = null
    private val sweeps = ConcurrentHashMap.newKeySet<DiscoveryManager>()
    private val announceGeneration = AtomicInteger()

    /** Parked prepare-upload requests awaiting a PHP decision, by requestId. */
    private val pending = ConcurrentHashMap<String, PendingRequest>()

    /** Accepted sessions, by sessionId. */
    private val sessions = ConcurrentHashMap<String, Session>()

    /** MediaStore entries still being written: sessionId -> uris. Deleted on cancel/stop. */
    private val pendingUris = ConcurrentHashMap<String, MutableSet<Uri>>()

    @Volatile
    private var pinGuard = PinGuard(LanConfig().pinMaxAttempts)

    fun attach(activity: FragmentActivity) {
        activityRef = WeakReference(activity)
        appContext = activity.applicationContext
    }

    // ── Wi-Fi lock ───────────────────────────────────────────────

    private var wifiLock: WifiManager.WifiLock? = null

    /**
     * Keep Wi-Fi out of power-save while the server or discovery runs; without
     * it Android dozes the radio between beacons and transfers crawl. Released
     * as soon as both are stopped.
     */
    @Suppress("DEPRECATION")
    @Synchronized
    private fun updateWifiLock() {
        val needed = server != null || discovery != null
        if (needed) {
            if (wifiLock?.isHeld == true) return
            val wifi = appContext?.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
            val mode = if (android.os.Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
            wifiLock = runCatching {
                wifi.createWifiLock(mode, "nativephp-lan").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }.onFailure { Log.w(TAG, "wifi lock failed", it) }.getOrNull()
        } else {
            wifiLock?.let { lock -> runCatching { if (lock.isHeld) lock.release() } }
            wifiLock = null
        }
    }

    // ── Discovery ────────────────────────────────────────────────

    @Synchronized
    fun startDiscovery(info: JSONObject, cfg: LanConfig) {
        stopDiscoveryLocked()
        val context = appContext ?: return
        val snapshot = withServiceId(info, cfg)
        discovery = DiscoveryManager(context, snapshot, cfg, this).also { it.start() }
        updateWifiLock()
    }

    fun sweepSubnet(info: JSONObject, prefix: String, seconds: Int, cfg: LanConfig) {
        val context = appContext ?: return
        val sweeper = DiscoveryManager(context, withServiceId(info, cfg), cfg, this)
        sweeps.add(sweeper)
        thread(name = "lan-sweep") {
            try {
                sweeper.sweep(prefix, seconds)
            } finally {
                sweeps.remove(sweeper)
            }
        }
    }

    /**
     * Tell a server who we are (POST register), retrying until it answers 200
     * or [seconds] pass. Stopped early by stopDiscovery().
     */
    fun announce(info: JSONObject, host: String, port: Int, seconds: Int, cfg: LanConfig) {
        val generation = announceGeneration.get()
        val body = withServiceId(info, cfg).toString().toByteArray()
        thread(name = "lan-announce-to") {
            val deadline = System.currentTimeMillis() + seconds * 1000L
            var attempt = 0
            while (System.currentTimeMillis() < deadline && announceGeneration.get() == generation) {
                attempt++
                try {
                    Socket().use { socket ->
                        socket.connect(InetSocketAddress(host, port), 1500)
                        socket.soTimeout = 3000
                        val head = "POST ${cfg.endpoint("register")} HTTP/1.1\r\nHost: $host:$port\r\n" +
                            "Content-Type: application/json\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n"
                        socket.getOutputStream().apply { write(head.toByteArray()); write(body); flush() }
                        val status = readLine(socket.getInputStream(), 512)
                        if (status.contains(" 200")) return@thread
                    }
                } catch (_: Exception) {
                }
                runCatching { Thread.sleep(1000) }
            }
        }
    }

    @Synchronized
    fun stopDiscovery() {
        stopDiscoveryLocked()
        updateWifiLock()
    }

    private fun stopDiscoveryLocked() {
        discovery?.stop()
        discovery = null
        sweeps.forEach { it.stop() }
        sweeps.clear()
        announceGeneration.incrementAndGet()
    }

    /** A copy of [info] with "app" set to the service id when missing. */
    private fun withServiceId(info: JSONObject, cfg: LanConfig): JSONObject {
        val copy = JSONObject(info.toString())
        if (copy.optString("app").isEmpty()) copy.put("app", cfg.serviceId)
        return copy
    }

    // ── Server ───────────────────────────────────────────────────

    /**
     * Bind the listener on the configured port, falling back to port + 1 when
     * it is busy. Returns the bound port, or null if both attempts failed.
     * The served device info is updated to the bound port.
     */
    @Synchronized
    fun startServer(info: JSONObject, dir: String, folder: String?, cfg: LanConfig): Int? {
        stopServerLocked()

        config = cfg
        pinGuard = PinGuard(cfg.pinMaxAttempts)
        incomingDir = dir
        publicFolder = folder
        File(dir).mkdirs()

        val snapshot = withServiceId(info, cfg)
        val preferred = snapshot.optInt("port", cfg.port).takeIf { it in 1..65534 } ?: cfg.port

        var lastError: Exception? = null
        for (port in listOf(preferred, preferred + 1)) {
            try {
                val httpServer = LanHttpServer(port, this, cfg)
                httpServer.start(NanoHTTPD.SOCKET_READ_TIMEOUT, true)
                server = httpServer
                deviceInfoText = snapshot.put("port", port).toString()
                updateWifiLock()
                return port
            } catch (e: Exception) {
                Log.w(TAG, "could not bind :$port", e)
                lastError = e
            }
        }

        dispatch("ServerError", JSONObject().put("message", lastError?.message ?: "Could not start listener"))
        updateWifiLock()
        return null
    }

    @Synchronized
    fun stopServer() {
        stopServerLocked()
        updateWifiLock()
    }

    /**
     * Release parked requests (503), cancel live sessions, close every
     * connection and drop half-written MediaStore rows.
     */
    private fun stopServerLocked() {
        val running = server
        server = null

        for (request in pending.values) request.resolve(503, JSONObject().put("message", "Receiver stopped"))
        pending.clear()

        val active = sessions.values.toList()
        sessions.clear()
        active.forEach { it.cancelled = true }

        runCatching { running?.stop() }

        val resolver = appContext?.contentResolver
        pendingUris.values.flatten().forEach { uri -> runCatching { resolver?.delete(uri, null, null) } }
        pendingUris.clear()

        active.forEach { session ->
            dispatch("SessionCancelled", JSONObject().put("sessionId", session.id).put("reason", "stopped"))
        }
    }

    fun deviceInfoJson(): JSONObject = JSONObject(deviceInfoText)

    // ── prepare-upload parking / respond ─────────────────────────

    /** Seconds [ip] must still wait after too many wrong PINs, or 0. */
    fun pinLockedFor(ip: String): Long = pinGuard.lockedSeconds(ip)

    fun pendingCount(): Int = pending.size

    fun parkUploadRequest(sender: JSONObject, files: List<DeclaredFile>, pinProvided: String?, remoteIp: String): PendingRequest? {
        if (pending.size >= MAX_PENDING) return null

        val requestId = UUID.randomUUID().toString()
        val request = PendingRequest(requestId, files, sender.optString("fingerprint"), remoteIp, pinProvided)
        pending[requestId] = request

        // The sender's self-declared address is never trusted: report the one we see.
        val senderOut = JSONObject(sender.toString()).put("ip", remoteIp)
        val filesOut = JSONArray()
        files.forEach { filesOut.put(it.json) }

        val payload = JSONObject()
            .put("requestId", requestId)
            .put("sender", senderOut)
            .put("files", filesOut)
            .put("remoteIp", remoteIp)
        if (pinProvided != null) payload.put("pinProvided", pinProvided)

        dispatch("UploadRequested", payload)
        return request
    }

    /**
     * The prepare timeout passed. Returns true when this call expired the
     * request (PHP never answered), false when respond() won the race.
     */
    fun expire(requestId: String): Boolean {
        val request = pending.remove(requestId) ?: return false
        request.resolve(403, JSONObject().put("message", "timeout"))
        dispatch("SessionCancelled", JSONObject().put("requestId", requestId).put("reason", "timeout"))
        return true
    }

    /**
     * PHP's answer to a parked request. Any status is passed to the sender
     * as-is; 200 needs a sessionId (else the sender gets 500).
     *
     * @return ok=false (with error) when the request is gone (answered, timed out, withdrawn) or the answer was unusable.
     */
    fun respond(requestId: String, acceptedFileIds: List<String>, sessionId: String?, status: Int): Map<String, Any> {
        val request = pending.remove(requestId)
            ?: return mapOf("ok" to false, "error" to "unknown request (already answered, timed out or withdrawn)")

        if (status != 200) {
            if (status == 401 && request.pinProvided != null) pinGuard.failed(request.remoteIp)
            val code = if (status in 400..599) status else 500
            request.resolve(code, JSONObject().put("message", messageFor(code)))
            return if (code == status) mapOf("ok" to true) else mapOf("ok" to false, "error" to "invalid status $status")
        }

        if (sessionId.isNullOrBlank()) {
            request.resolve(500, JSONObject().put("message", "Receiver error"))
            return mapOf("ok" to false, "error" to "sessionId is required with status 200")
        }

        val taken = mutableSetOf<String>()
        val files = LinkedHashMap<String, SessionFile>()
        for (file in request.files) {
            if (file.id !in acceptedFileIds || files.containsKey(file.id)) continue
            val name = FileNames.unique(FileNames.sanitize(file.fileName.ifEmpty { file.id }), taken)
            files[file.id] = SessionFile(file.id, name, file.size, file.fileType, UUID.randomUUID().toString())
        }

        val needed = files.values.sumOf { it.size }
        if (needed > 0 && needed > freeSpace()) {
            request.resolve(507, JSONObject().put("message", "Not enough storage"))
            return mapOf("ok" to false, "error" to "insufficient storage")
        }

        if (request.pinProvided != null) pinGuard.succeeded(request.remoteIp)

        sessions[sessionId] = Session(sessionId, request.remoteIp, files)
        val tokens = JSONObject()
        files.values.forEach { tokens.put(it.id, it.token) }
        request.resolve(200, JSONObject().put("sessionId", sessionId).put("files", tokens))
        return mapOf("ok" to true)
    }

    fun session(sessionId: String?): Session? = sessionId?.let { sessions[it] }

    /** Bytes free where uploads land. */
    fun freeSpace(): Long = runCatching {
        if (publicFolder != null) {
            (appContext?.getExternalFilesDir(null) ?: Environment.getDataDirectory()).usableSpace
        } else {
            File(incomingDir ?: return@runCatching Long.MAX_VALUE).usableSpace
        }
    }.getOrDefault(Long.MAX_VALUE)

    private fun messageFor(status: Int): String = when (status) {
        401 -> "PIN required"
        403 -> "Declined"
        409 -> "Busy"
        413 -> "Too large"
        429 -> "Too many requests"
        503 -> "Unavailable"
        507 -> "Not enough storage"
        else -> "Error"
    }

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
     * when a public folder is configured, otherwise
     * {incomingDir}/{sessionId}/{fileName} (names are unique per session).
     */
    fun openUploadTarget(session: Session, file: SessionFile): UploadTarget? {
        val folder = publicFolder
        val context = appContext

        if (folder != null && context != null) {
            return openMediaStoreTarget(context, session.id, file, folder)
        }

        val dir = incomingDir ?: return null
        val sessionDir = File(dir, session.id).apply { mkdirs() }
        val destination = File(sessionDir, file.name)
        if (destination.canonicalFile.parentFile != sessionDir.canonicalFile) return null

        return UploadTarget(
            output = destination.outputStream(),
            location = destination.absolutePath,
            commit = {},
            discard = { destination.delete() },
        )
    }

    private fun openMediaStoreTarget(context: Context, sessionId: String, file: SessionFile, folder: String): UploadTarget? {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, file.name)
            file.mime?.let { put(MediaStore.Downloads.MIME_TYPE, it) }
            put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$folder")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }

        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return null
        val output = runCatching { resolver.openOutputStream(uri) }.getOrNull() ?: run {
            runCatching { resolver.delete(uri, null, null) }
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

    // ── Cancelling ───────────────────────────────────────────────

    /**
     * End a session: in-flight uploads stop at their next chunk, partial files
     * are removed and PHP hears SessionCancelled once.
     */
    fun cancelSession(sessionId: String, reason: String): Boolean {
        val session = sessions.remove(sessionId) ?: return false
        session.cancelled = true
        incomingDir?.let { File(it, sessionId).deleteRecursively() }
        val resolver = appContext?.contentResolver
        pendingUris.remove(sessionId)?.forEach { uri -> runCatching { resolver?.delete(uri, null, null) } }
        dispatch("SessionCancelled", JSONObject().put("sessionId", sessionId).put("reason", reason))
        return true
    }

    /** POST /cancel?sessionId=…: honoured only from the address that opened the session. */
    fun cancelFromSender(sessionId: String, remoteIp: String) {
        val session = sessions[sessionId] ?: return
        if (session.senderIp != remoteIp) return
        cancelSession(sessionId, "sender")
    }

    /**
     * POST /cancel?fingerprint=…: the sender withdrew before anyone answered.
     * Releases its parked prepare-upload (403) and tells PHP to close the
     * prompt. Only requests from the same address are withdrawn.
     */
    fun cancelPendingFrom(fingerprint: String, remoteIp: String) {
        if (fingerprint.isEmpty()) return
        for (request in pending.values.filter { it.senderFingerprint == fingerprint && it.remoteIp == remoteIp }) {
            if (pending.remove(request.requestId) == null) continue
            request.resolve(403, JSONObject().put("message", "withdrawn"))
            dispatch("SessionCancelled", JSONObject().put("requestId", request.requestId).put("reason", "sender"))
        }
    }

    // ── Events ───────────────────────────────────────────────────

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
        dispatch("UploadComplete", JSONObject().put("sessionId", sessionId).put("fileId", fileId).put("path", path))
    }

    fun emitPeerFound(peer: JSONObject) = dispatch("PeerFound", peer)

    fun dispatch(event: String, payload: JSONObject) {
        val activity = activityRef?.get() ?: return
        val fqcn = EVENT_NAMESPACE + event
        val json = payload.toString()
        activity.runOnUiThread {
            runCatching { NativeActionCoordinator.dispatchEvent(activity, fqcn, json) }
                .onFailure { Log.w(TAG, "dispatch $event failed", it) }
        }
    }

    // ── Local IP ─────────────────────────────────────────────────

    @Suppress("DEPRECATION")
    fun localIp(): String? {
        val wifi = appContext?.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return fallbackIp()
        val ipInt = wifi.connectionInfo?.ipAddress ?: return fallbackIp()
        if (ipInt == 0) return fallbackIp()
        return String.format(
            java.util.Locale.ROOT,
            "%d.%d.%d.%d",
            ipInt and 0xff,
            ipInt shr 8 and 0xff,
            ipInt shr 16 and 0xff,
            ipInt shr 24 and 0xff
        )
    }

    private fun fallbackIp(): String? = runCatching {
        java.net.NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .firstOrNull { !it.isLoopbackAddress && it is java.net.Inet4Address }
            ?.hostAddress
    }.getOrNull()

    /** One CRLF-terminated line, at most [max] bytes. */
    internal fun readLine(input: java.io.InputStream, max: Int): String {
        val out = java.io.ByteArrayOutputStream()
        while (out.size() < max) {
            val b = input.read()
            if (b < 0 || b == '\n'.code) break
            if (b != '\r'.code) out.write(b)
        }
        return out.toString("UTF-8")
    }

    // ── Types ────────────────────────────────────────────────────

    /** One file as the sender declared it in prepare-upload. */
    class DeclaredFile(val id: String, val fileName: String, val size: Long, val fileType: String?, val json: JSONObject)

    class SessionFile(val id: String, val name: String, val size: Long, val mime: String?, val token: String) {
        /** Tokens are one-shot: the second upload with the same token gets 409. */
        val used = AtomicBoolean(false)
    }

    class Session(val id: String, val senderIp: String, val files: Map<String, SessionFile>) {
        @Volatile
        var cancelled = false
    }

    /** A parked prepare-upload request; its HTTP thread waits until resolve(). */
    class PendingRequest(
        val requestId: String,
        val files: List<DeclaredFile>,
        val senderFingerprint: String,
        val remoteIp: String,
        val pinProvided: String?,
    ) {
        private val latch = CountDownLatch(1)

        @Volatile
        var status: Int = 503
            private set

        @Volatile
        var body: JSONObject = JSONObject()
            private set

        fun resolve(status: Int, body: JSONObject) {
            if (latch.count == 0L) return
            this.status = status
            this.body = body
            latch.countDown()
        }

        fun await(seconds: Long): Boolean = latch.await(seconds, TimeUnit.SECONDS)
    }

    /**
     * Per-IP wrong-PIN counter: after [maxAttempts] wrong PINs the IP is
     * locked out for 10 s, doubling with every further failure up to 5 min.
     * A correct PIN clears it.
     */
    class PinGuard(private val maxAttempts: Int) {
        private class Entry(var failures: Int = 0, var lockedUntil: Long = 0L)

        private val entries = HashMap<String, Entry>()

        @Synchronized
        fun lockedSeconds(ip: String): Long {
            val entry = entries[ip] ?: return 0
            val remaining = entry.lockedUntil - System.currentTimeMillis()
            return if (remaining > 0) (remaining + 999) / 1000 else 0
        }

        @Synchronized
        fun failed(ip: String) {
            val entry = entries.getOrPut(ip) { Entry() }
            entry.failures++
            if (entry.failures >= maxAttempts) {
                val step = (entry.failures - maxAttempts).coerceAtMost(5)
                entry.lockedUntil = System.currentTimeMillis() + minOf(300_000L, 10_000L shl step)
            }
            if (entries.size > 256) entries.keys.firstOrNull()?.let { entries.remove(it) }
        }

        @Synchronized
        fun succeeded(ip: String) {
            entries.remove(ip)
        }
    }
}
