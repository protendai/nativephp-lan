package com.protendai.lan

import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import kotlin.concurrent.thread

/**
 * Headless fragment that runs one multi-select pick (documents, or photos
 * and videos from the system photo picker) and removes itself. The picker hands back content:// URIs that PHP's fopen() cannot
 * read, so each one is streamed into the app cache first; that happens on a
 * background thread because picked videos can be hundreds of MB.
 *
 * Events: FilesPicking { count } as soon as the picker returns, then one
 * FilesPicked { files: [{path, name, size}] } (empty when cancelled).
 */
class PickFilesFragment : Fragment() {

    private var mimeTypes: Array<String> = arrayOf("*/*")
    private var media = false
    private var launched = false

    private val documentPicker = registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        onPicked(uris)
    }

    private val mediaPicker = registerForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { uris ->
        onPicked(uris)
    }

    override fun onStart() {
        super.onStart()
        if (launched) return
        launched = true
        if (media) {
            mediaPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
        } else {
            documentPicker.launch(mimeTypes)
        }
    }

    /**
     * Tell PHP how many are coming straight away (so the UI can show
     * placeholders), then copy on a background thread and report once.
     */
    private fun onPicked(uris: List<Uri>) {
        val context = context?.applicationContext
        remove()

        if (context == null || uris.isEmpty()) {
            LanManager.dispatch("FilesPicked", JSONObject().put("files", JSONArray()))
            return
        }

        LanManager.dispatch("FilesPicking", JSONObject().put("count", uris.size))

        thread(name = "lan-pick-copy") {
            pruneOldCopies(context)
            val files = JSONArray()
            for (uri in uris) {
                copyIntoCache(context, uri)?.let { files.put(it) }
            }
            LanManager.dispatch("FilesPicked", JSONObject().put("files", files))
        }
    }

    private fun remove() {
        runCatching { parentFragmentManager.beginTransaction().remove(this).commitAllowingStateLoss() }
    }

    companion object {
        private const val TAG = "nativephp-lan-pick-files"

        fun launch(activity: FragmentActivity, mimeTypes: Array<String>) = add(activity) { this.mimeTypes = mimeTypes }

        /** The system photo picker (photos and videos), multi-select. */
        fun launchMedia(activity: FragmentActivity) = add(activity) { this.media = true }

        private fun add(activity: FragmentActivity, configure: PickFilesFragment.() -> Unit) {
            activity.runOnUiThread {
                val fragment = PickFilesFragment().apply(configure)
                activity.supportFragmentManager.beginTransaction().add(fragment, TAG).commitAllowingStateLoss()
            }
        }

        /**
         * Copies are only needed until they've been sent; drop pick folders older
         * than a day so large videos don't pile up in the cache. A day is far longer
         * than any transfer, so an in-flight send never loses its file.
         */
        private fun pruneOldCopies(context: android.content.Context) {
            val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
            File(context.cacheDir, "picked-documents").listFiles()
                ?.filter { it.isDirectory && it.lastModified() < cutoff }
                ?.forEach { runCatching { it.deleteRecursively() } }
        }

        /**
         * Copy one picked document to cacheDir/picked-documents/<uuid>/<name>.
         * A directory per file keeps same-named picks from overwriting each other.
         */
        private fun copyIntoCache(context: android.content.Context, uri: Uri): JSONObject? = runCatching {
            val resolver = context.contentResolver
            var name: String? = null
            var size = -1L
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    name = cursor.getString(0)
                    if (!cursor.isNull(1)) size = cursor.getLong(1)
                }
            }

            // DISPLAY_NAME comes from another app's provider: strip anything path-like
            // so the copy cannot land outside its directory.
            val safeName = FileNames.sanitize(name)

            val directory = File(context.cacheDir, "picked-documents/" + UUID.randomUUID()).apply { mkdirs() }
            val destination = File(directory, safeName)

            resolver.openInputStream(uri)?.use { input ->
                destination.outputStream().use { output -> input.copyTo(output, 1 shl 20) }
            } ?: return@runCatching null

            JSONObject()
                .put("path", destination.absolutePath)
                .put("name", safeName)
                .put("size", if (size >= 0) size else destination.length())
        }.onFailure { Log.w(LanManager.TAG, "could not copy a picked file", it) }.getOrNull()
    }
}
