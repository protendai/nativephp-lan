package com.protendai.lan

import fi.iki.elonen.NanoHTTPD
import org.json.JSONObject
import java.io.IOException
import java.io.InputStream

/**
 * The receiving half of the LAN protocol (LocalSend-derived; routes under
 * the configured API prefix), served on 0.0.0.0:{port}. JSON bodies are
 * capped at 1 MB; upload bodies stream straight to disk and must match the
 * size declared in prepare-upload. Only metadata and progress numbers cross
 * the bridge back to PHP as events.
 *
 * Request headers are capped by NanoHTTPD itself (8 KB). Chunked request
 * bodies are not decoded: they are rejected with 501, and uploads without a
 * Content-Length get 411.
 */
class LanHttpServer(port: Int, private val manager: LanManager, private val config: LanConfig) : NanoHTTPD("0.0.0.0", port) {

    init {
        setAsyncRunner(BoundedRunner(config.maxConnections))
    }

    /** NanoHTTPD's thread-per-connection runner with a cap: connections over it are closed at once. */
    private class BoundedRunner(private val max: Int) : NanoHTTPD.DefaultAsyncRunner() {
        override fun exec(clientHandler: NanoHTTPD.ClientHandler) {
            if (running.size >= max) {
                clientHandler.close()
                return
            }
            super.exec(clientHandler)
        }
    }

    override fun serve(session: IHTTPSession): Response {
        val path = session.uri.trimEnd('/')
        val remoteIp = normalizeIp(session.remoteIpAddress)

        return try {
            when (path) {
                config.endpoint("info") -> json(200, manager.deviceInfoJson())
                config.endpoint("register") -> handleRegister(session, remoteIp)
                config.endpoint("prepare-upload") -> handlePrepareUpload(session, remoteIp)
                config.endpoint("upload") -> handleUpload(session)
                config.endpoint("cancel") -> handleCancel(session, remoteIp)
                else -> json(404, message("Not found"))
            }
        } catch (e: BodyException) {
            json(e.status, message(e.message ?: "Bad request"), close = true)
        } catch (e: Exception) {
            json(500, message("Receiver error"), close = true)
        }
    }

    private fun handleRegister(session: IHTTPSession, remoteIp: String): Response {
        val body = readJsonBody(session)
        if (body != null && body.optString("app") == config.serviceId) {
            // Only the address we see counts; a declared "ip" is ignored.
            body.put("ip", remoteIp)
            if (body.optString("fingerprint").isNotEmpty()) manager.emitPeerFound(peerJson(body))
        }
        return json(200, manager.deviceInfoJson())
    }

    private fun handlePrepareUpload(session: IHTTPSession, remoteIp: String): Response {
        val locked = manager.pinLockedFor(remoteIp)
        if (locked > 0) {
            return json(429, message("Too many wrong PINs; retry in ${locked}s"), close = true).apply {
                addHeader("Retry-After", locked.toString())
            }
        }

        val body = readJsonBody(session) ?: return json(400, message("Invalid JSON"), close = true)
        val sender = body.optJSONObject("info") ?: JSONObject()
        val filesObject = body.optJSONObject("files") ?: JSONObject()
        val pin = session.parameters["pin"]?.firstOrNull()

        if (filesObject.length() == 0) return json(400, message("No files"))
        if (filesObject.length() > config.maxFiles) return json(413, message("Too many files"))

        val files = mutableListOf<LanManager.DeclaredFile>()
        for (key in filesObject.keys()) {
            val file = filesObject.optJSONObject(key) ?: return json(400, message("Invalid file entry"))
            val id = file.optString("id").ifEmpty { key }
            val size = file.optLong("size", -1L)
            if (size < 0) return json(400, message("Missing file size"))
            if (config.maxFileSize > 0 && size > config.maxFileSize) return json(413, message("File too large"))
            files.add(
                LanManager.DeclaredFile(
                    id = id,
                    fileName = file.optString("fileName"),
                    size = size,
                    fileType = file.optString("fileType").takeIf { it.isNotBlank() },
                    json = file,
                )
            )
        }

        val request = manager.parkUploadRequest(sender, files, pin, remoteIp)
            ?: return json(429, message("Too many pending requests"))

        // Block this connection's thread until PHP answers or the timeout passes.
        if (!request.await(config.prepareTimeoutSeconds.toLong())) {
            if (!manager.expire(request.requestId)) {
                // respond() won the race at the last moment; its answer is on the way.
                request.await(5)
            }
        }

        return json(request.status, request.body)
    }

    private fun handleUpload(session: IHTTPSession): Response {
        val sessionId = session.parameters["sessionId"]?.firstOrNull()
        val fileId = session.parameters["fileId"]?.firstOrNull()
        val token = session.parameters["token"]?.firstOrNull()

        rejectChunked(session)?.let { return it }

        val live = manager.session(sessionId)
        val file = if (live != null && fileId != null) live.files[fileId] else null
        if (live == null || file == null || token == null || file.token != token) {
            return json(403, message("Invalid token"), close = true)
        }
        if (!file.used.compareAndSet(false, true)) {
            return json(409, message("Token already used"), close = true)
        }

        val total = session.headers["content-length"]?.trim()?.toLongOrNull()
            ?: return json(411, message("Content-Length required"), close = true)
        if (total < 0 || total > file.size) return json(413, message("Larger than declared"), close = true)
        if (config.maxFileSize > 0 && total > config.maxFileSize) return json(413, message("File too large"), close = true)
        if (total > manager.freeSpace()) return json(507, message("Not enough storage"), close = true)

        val target = runCatching { manager.openUploadTarget(live, file) }.getOrNull()
            ?: return json(500, message("Cannot open destination"), close = true)

        val input = session.inputStream
        // Big chunks + a 1 MB write buffer: storage writes on Android go through
        // scoped-storage FUSE, where many small writes cost far more than few big ones.
        val buffer = ByteArray(512 * 1024)
        var received = 0L
        var lastEmit = 0L

        try {
            target.output.buffered(1 shl 20).use { output ->
                while (received < total) {
                    if (live.cancelled) {
                        target.discard()
                        return json(410, message("Session cancelled"), close = true)
                    }
                    val toRead = minOf(buffer.size.toLong(), total - received).toInt()
                    val read = input.read(buffer, 0, toRead)
                    if (read < 0) break
                    try {
                        output.write(buffer, 0, read)
                    } catch (e: IOException) {
                        throw WriteFailure(e)
                    }
                    received += read

                    val now = System.currentTimeMillis()
                    // Each progress event costs PHP a DB write and a re-render; twice a second is plenty.
                    if (now - lastEmit >= 500) {
                        manager.emitProgress(live.id, file.id, received, total)
                        lastEmit = now
                    }
                }
            }
        } catch (e: WriteFailure) {
            target.discard()
            manager.cancelSession(live.id, if (isDiskFull(e.cause)) "storage" else "error")
            return if (isDiskFull(e.cause)) json(507, message("Not enough storage"), close = true)
            else json(500, message("Write failed"), close = true)
        } catch (e: Exception) {
            // Connection dropped mid-stream (sender cancelled, left Wi-Fi, server stopped) or the flush on close failed.
            target.discard()
            if (isDiskFull(e)) {
                manager.cancelSession(live.id, "storage")
                return json(507, message("Not enough storage"), close = true)
            }
            manager.cancelSession(live.id, "interrupted")
            return json(400, message("Upload interrupted"), close = true)
        }

        // The sender hung up before the declared length: drop the partial file.
        if (received < total || live.cancelled) {
            target.discard()
            manager.cancelSession(live.id, "interrupted")
            return json(400, message("Incomplete upload"), close = true)
        }

        target.commit()
        manager.emitProgress(live.id, file.id, received, total)
        manager.emitComplete(live.id, file.id, target.location)

        return json(200, JSONObject())
    }

    private fun handleCancel(session: IHTTPSession, remoteIp: String): Response {
        val sessionId = session.parameters["sessionId"]?.firstOrNull()
        val fingerprint = session.parameters["fingerprint"]?.firstOrNull()
        when {
            sessionId != null -> manager.cancelFromSender(sessionId, remoteIp)
            fingerprint != null -> manager.cancelPendingFrom(fingerprint, remoteIp)
        }
        return json(200, JSONObject())
    }

    // ── Helpers ──────────────────────────────────────────────────

    private class BodyException(val status: Int, message: String) : Exception(message)

    private class WriteFailure(cause: IOException) : Exception(cause)

    private fun isDiskFull(e: Throwable?): Boolean {
        var current = e
        while (current != null) {
            val text = current.message.orEmpty()
            if ("ENOSPC" in text || "No space left" in text) return true
            current = current.cause
        }
        return false
    }

    /** 501 for a chunked (or otherwise encoded) request body, which NanoHTTPD would not decode. */
    private fun rejectChunked(session: IHTTPSession): Response? {
        val encoding = session.headers["transfer-encoding"]?.trim()?.lowercase() ?: return null
        if (encoding.isEmpty() || encoding == "identity") return null
        return json(501, message("Transfer-Encoding not supported; send Content-Length"), close = true)
    }

    /**
     * Read a JSON object body of at most 1 MB. Reads exactly Content-Length
     * bytes from the raw stream (NanoHTTPD's parseBody has no size limit).
     */
    private fun readJsonBody(session: IHTTPSession): JSONObject? {
        val encoding = session.headers["transfer-encoding"]?.trim()?.lowercase()
        if (!encoding.isNullOrEmpty() && encoding != "identity") throw BodyException(501, "Transfer-Encoding not supported")

        val length = session.headers["content-length"]?.trim()?.toLongOrNull() ?: 0L
        if (length > LanConfig.MAX_JSON_BYTES) throw BodyException(413, "Body too large")
        if (length <= 0L) return null

        val bytes = readExactly(session.inputStream, length.toInt()) ?: throw BodyException(400, "Incomplete body")
        return runCatching { JSONObject(String(bytes, Charsets.UTF_8)) }.getOrNull()
    }

    private fun readExactly(input: InputStream, length: Int): ByteArray? {
        val bytes = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val read = input.read(bytes, offset, length - offset)
            if (read < 0) return null
            offset += read
        }
        return bytes
    }

    private fun peerJson(info: JSONObject): JSONObject = JSONObject()
        .put("alias", info.optString("alias"))
        .put("fingerprint", info.optString("fingerprint"))
        .put("ip", info.optString("ip"))
        .put("port", info.optInt("port", config.port))
        .put("protocol", info.optString("protocol", "http"))
        .put("deviceModel", info.optString("deviceModel"))
        .put("deviceType", info.optString("deviceType"))

    private fun message(text: String): JSONObject = JSONObject().put("message", text)

    private fun json(code: Int, body: JSONObject, close: Boolean = false): Response {
        val status = Response.Status.lookup(code) ?: object : Response.IStatus {
            override fun getRequestStatus(): Int = code
            override fun getDescription(): String = "$code ${reasonFor(code)}"
        }
        return newFixedLengthResponse(status, "application/json", body.toString()).apply {
            if (close) addHeader("Connection", "close")
        }
    }

    private fun reasonFor(code: Int): String = when (code) {
        411 -> "Length Required"
        413 -> "Payload Too Large"
        429 -> "Too Many Requests"
        431 -> "Request Header Fields Too Large"
        501 -> "Not Implemented"
        507 -> "Insufficient Storage"
        else -> "Error"
    }

    companion object {
        /** "::ffff:192.168.1.5" and "fe80::1%wlan0" -> plain address. */
        fun normalizeIp(raw: String?): String {
            val ip = raw.orEmpty().substringBefore('%')
            return if (ip.startsWith("::ffff:", ignoreCase = true)) ip.substring(7) else ip
        }
    }
}
