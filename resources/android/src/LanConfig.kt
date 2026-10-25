package com.protendai.lan

import org.json.JSONArray
import org.json.JSONObject

/**
 * Protocol and limit settings, sent by PHP (config/lan.php merged with
 * per-call options) with every start call. Immutable: a running server or
 * discovery loop keeps the snapshot it was started with.
 */
data class LanConfig(
    /** Every device-info JSON carries "app": serviceId; anything else is ignored. */
    val serviceId: String = "nativephp-lan",
    /** HTTP route prefix, e.g. "/api/nativephp-lan/v1" (no trailing slash). */
    val apiPrefix: String = "/api/nativephp-lan/v1",
    val port: Int = 53530,
    val multicastGroup: String = "224.0.0.170",
    val multicastPort: Int = 53530,
    /** How long a prepare-upload waits for Lan::respond() before answering 403 and dispatching SessionCancelled(timeout). */
    val prepareTimeoutSeconds: Int = 60,
    /** Largest single file accepted, in bytes. 0 = no limit. */
    val maxFileSize: Long = 0,
    /** Most files in one prepare-upload. */
    val maxFiles: Int = 1000,
    /** Most simultaneous HTTP connections; extra connections are closed at once. */
    val maxConnections: Int = 32,
    /** Wrong PINs from one IP before that IP is locked out (with exponential backoff). */
    val pinMaxAttempts: Int = 3,
) {
    /** The full path of one route, e.g. endpoint("info") = "/api/nativephp-lan/v1/info". */
    fun endpoint(name: String): String = "$apiPrefix/$name"

    companion object {
        const val MAX_JSON_BYTES = 1 shl 20
        const val MAX_PROBE_BYTES = 64 * 1024

        fun from(value: Any?): LanConfig {
            val json = asJson(value)
            val defaults = LanConfig()
            return LanConfig(
                serviceId = json.optString("serviceId").trim().ifEmpty { defaults.serviceId },
                apiPrefix = normalizePrefix(json.optString("apiPrefix")) ?: defaults.apiPrefix,
                port = json.optInt("port", defaults.port).takeIf { it in 1..65534 } ?: defaults.port,
                multicastGroup = json.optString("multicastGroup").trim().ifEmpty { defaults.multicastGroup },
                multicastPort = json.optInt("multicastPort", defaults.multicastPort).takeIf { it in 1..65535 } ?: defaults.multicastPort,
                prepareTimeoutSeconds = json.optInt("prepareTimeout", defaults.prepareTimeoutSeconds).coerceIn(5, 600),
                maxFileSize = json.optLong("maxFileSize", 0L).coerceAtLeast(0L),
                maxFiles = json.optInt("maxFiles", defaults.maxFiles).coerceIn(1, 100_000),
                maxConnections = json.optInt("maxConnections", defaults.maxConnections).coerceIn(4, 256),
                pinMaxAttempts = json.optInt("pinMaxAttempts", defaults.pinMaxAttempts).coerceIn(1, 100),
            )
        }

        /** "/api/x/v1/" or "api/x/v1" -> "/api/x/v1"; null when unusable. */
        private fun normalizePrefix(raw: String): String? {
            val trimmed = raw.trim().trim('/')
            if (trimmed.isEmpty() || trimmed.any { it.isWhitespace() || it == '?' || it == '#' }) return null
            return "/$trimmed"
        }
    }
}

/**
 * Convert a decoded bridge param into a JSONObject. The bridge passes nested
 * PHP arrays as JSONObject, but older cores used Map or a JSON string.
 */
internal fun asJson(value: Any?): JSONObject =
    when (value) {
        is JSONObject -> value
        is Map<*, *> -> JSONObject(value.entries.associate { (k, v) -> k.toString() to (v ?: JSONObject.NULL) })
        is String -> runCatching { JSONObject(value) }.getOrDefault(JSONObject())
        else -> JSONObject()
    }

/** A bridge param PHP sent as a list: JSONArray from the bridge, or a List. */
internal fun stringList(value: Any?): List<String> =
    when (value) {
        is JSONArray -> (0 until value.length()).mapNotNull { value.opt(it) as? String }
        is List<*> -> value.filterIsInstance<String>()
        else -> emptyList()
    }

/** Received file names: never a path, never empty, ".", ".." or a control character, at most 255 UTF-8 bytes. */
object FileNames {
    private const val MAX_BYTES = 255
    private val forbidden = setOf('/', '\\', ':', '*', '?', '"', '<', '>', '|')

    fun sanitize(name: String?): String {
        val replaced = buildString {
            for (ch in name.orEmpty()) {
                when {
                    ch.code < 0x20 || ch.code == 0x7f -> {}
                    ch in forbidden -> append('_')
                    else -> append(ch)
                }
            }
        }.trim()

        if (replaced.isEmpty() || replaced.all { it == '.' }) return "file"
        return fitBytes(replaced, MAX_BYTES)
    }

    /** [name], or "name (2).ext", "name (3).ext"... when [taken] (case-insensitive) already has it. Adds the result to [taken]. */
    fun unique(name: String, taken: MutableSet<String>): String {
        var candidate = name
        var counter = 2
        while (candidate.lowercase() in taken) {
            val dot = name.lastIndexOf('.')
            val (base, ext) = if (dot > 0) name.substring(0, dot) to name.substring(dot) else name to ""
            candidate = fitBytes("$base ($counter)$ext", MAX_BYTES)
            counter++
        }
        taken.add(candidate.lowercase())
        return candidate
    }

    /** Cut to [max] UTF-8 bytes on a code point boundary, keeping a short extension. */
    private fun fitBytes(name: String, max: Int): String {
        if (name.toByteArray(Charsets.UTF_8).size <= max) return name
        val dot = name.lastIndexOf('.')
        val ext = if (dot > 0 && name.length - dot <= 16) name.substring(dot) else ""
        val base = if (ext.isEmpty()) name else name.substring(0, dot)
        val budget = max - ext.toByteArray(Charsets.UTF_8).size

        val out = StringBuilder()
        var used = 0
        var i = 0
        while (i < base.length) {
            val cp = base.codePointAt(i)
            val chunk = String(Character.toChars(cp))
            val bytes = chunk.toByteArray(Charsets.UTF_8).size
            if (used + bytes > budget) break
            out.append(chunk)
            used += bytes
            i += Character.charCount(cp)
        }
        return out.toString().ifEmpty { "file" } + ext
    }
}
