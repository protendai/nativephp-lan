package com.tuma.lan

import fi.iki.elonen.NanoHTTPD
import org.json.JSONArray
import org.json.JSONObject

/**
 * The receiving half of the Tumira LAN protocol (LocalSend-derived, own port/paths), served on 0.0.0.0:{port}. Bodies stream
 * straight to disk; only metadata and progress numbers cross the bridge back
 * to PHP as events.
 */
class LanHttpServer(port: Int, private val manager: LanManager) : NanoHTTPD("0.0.0.0", port) {

    private val apiPrefix = "/api/tumira/v1/"

    override fun serve(session: IHTTPSession): Response {
        val path = session.uri.removeSuffix("/")

        return try {
            when {
                path.endsWith("${apiPrefix}info".removeSuffix("/")) -> handleInfo()
                path.endsWith("${apiPrefix}register".removeSuffix("/")) -> handleRegister(session)
                path.endsWith("${apiPrefix}prepare-upload".removeSuffix("/")) -> handlePrepareUpload(session)
                path.endsWith("${apiPrefix}upload".removeSuffix("/")) -> handleUpload(session)
                path.endsWith("${apiPrefix}cancel".removeSuffix("/")) -> handleCancel(session)
                else -> json(Response.Status.NOT_FOUND, JSONObject().put("message", "Not found"))
            }
        } catch (e: Exception) {
            json(Response.Status.INTERNAL_ERROR, JSONObject().put("message", e.message ?: "error"))
        }
    }

    private fun handleInfo(): Response = json(Response.Status.OK, manager.deviceInfoJson())

    private fun handleRegister(session: IHTTPSession): Response {
        val body = readJsonBody(session)
        if (body != null && body.optString("app") == LanManager.APP_ID) {
            manager.emitPeerFound(body)
        }
        return json(Response.Status.OK, manager.deviceInfoJson())
    }

    private fun handlePrepareUpload(session: IHTTPSession): Response {
        val body = readJsonBody(session) ?: return json(Response.Status.BAD_REQUEST, JSONObject())

        val sender = body.optJSONObject("info") ?: JSONObject()
        val filesObject = body.optJSONObject("files") ?: JSONObject()
        val pin = session.parameters["pin"]?.firstOrNull()

        // Convert the {fileId: {...}} map into a JSON array for the event.
        val files = JSONArray()
        for (key in filesObject.keys()) {
            filesObject.optJSONObject(key)?.let { files.put(it) }
        }

        val request = manager.parkUploadRequest(sender, files, pin)

        // Block this HTTP thread until PHP answers (or 60s timeout -> 403).
        val answered = request.await()
        manager.completePending(request.requestId)

        if (!answered || request.status == 403) {
            return json(Response.Status.FORBIDDEN, JSONObject().put("message", "declined"))
        }
        if (request.status == 401) {
            return status(401, JSONObject().put("message", "PIN required"))
        }
        if (request.status == 429) {
            return status(429, JSONObject().put("message", "Too many requests"))
        }

        val filesResponse = JSONObject()
        for ((fileId, token) in request.tokens) {
            filesResponse.put(fileId, token)
        }

        return json(
            Response.Status.OK,
            JSONObject().put("sessionId", request.sessionId).put("files", filesResponse)
        )
    }

    private fun handleUpload(session: IHTTPSession): Response {
        val sessionId = session.parameters["sessionId"]?.firstOrNull()
        val fileId = session.parameters["fileId"]?.firstOrNull()
        val token = session.parameters["token"]?.firstOrNull()

        if (!manager.validToken(sessionId, fileId, token)) {
            return json(Response.Status.FORBIDDEN, JSONObject().put("message", "invalid token"))
        }

        val target = manager.openUploadTarget(sessionId!!, fileId!!)
            ?: return json(Response.Status.INTERNAL_ERROR, JSONObject().put("message", "cannot open destination"))

        val total = session.headers["content-length"]?.toLongOrNull() ?: -1L
        val input = session.inputStream
        val buffer = ByteArray(64 * 1024)
        var received = 0L
        var lastEmit = 0L

        try {
            target.output.use { output ->
                while (total < 0 || received < total) {
                    val toRead = if (total in 0..(received + buffer.size)) (total - received).toInt() else buffer.size
                    if (toRead <= 0) break
                    val read = input.read(buffer, 0, toRead)
                    if (read < 0) break
                    output.write(buffer, 0, read)
                    received += read

                    val now = System.currentTimeMillis()
                    if (now - lastEmit >= 250) {
                        manager.emitProgress(sessionId, fileId, received, if (total > 0) total else received)
                        lastEmit = now
                    }
                }
            }
        } catch (e: Exception) {
            // Connection dropped mid-stream (sender cancelled, left Wi-Fi, app killed).
            target.discard()
            manager.cancelSession(sessionId, "interrupted")
            throw e
        }

        // The sender hung up (or cancelled) before the declared length: drop the partial file.
        if (total > 0 && received < total) {
            target.discard()
            manager.cancelSession(sessionId, "interrupted")
            return json(Response.Status.BAD_REQUEST, JSONObject().put("message", "incomplete upload"))
        }

        target.commit()
        manager.emitProgress(sessionId, fileId, received, if (total > 0) total else received)
        manager.emitComplete(sessionId, fileId, target.location)

        return json(Response.Status.OK, JSONObject())
    }

    private fun handleCancel(session: IHTTPSession): Response {
        val sessionId = session.parameters["sessionId"]?.firstOrNull()
        val fingerprint = session.parameters["fingerprint"]?.firstOrNull()
        when {
            sessionId != null -> manager.cancelSession(sessionId, "sender")
            fingerprint != null -> manager.cancelPendingFrom(fingerprint)
        }
        return json(Response.Status.OK, JSONObject())
    }

    // ── Helpers ──────────────────────────────────────────────────

    /** Read a JSON request body without disturbing the raw upload stream path. */
    private fun readJsonBody(session: IHTTPSession): JSONObject? {
        val map = HashMap<String, String>()
        return runCatching {
            session.parseBody(map)
            val raw = map["postData"] ?: session.parameters["postData"]?.firstOrNull()
            raw?.let { JSONObject(it) }
        }.getOrNull()
    }

    private fun json(status: Response.Status, body: JSONObject): Response =
        newFixedLengthResponse(status, "application/json", body.toString())

    private fun status(code: Int, body: JSONObject): Response {
        val custom = object : Response.IStatus {
            override fun getRequestStatus(): Int = code
            override fun getDescription(): String = "$code Custom"
        }
        return newFixedLengthResponse(custom, "application/json", body.toString())
    }
}
