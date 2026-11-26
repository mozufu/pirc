package org.mozufu.pirc.files

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.DragEvent
import android.view.View
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.mozufu.pirc.PlatformFeature
import org.mozufu.pirc.R
import org.mozufu.pirc.mainThreadExecutor

/** What the channel needs from the activity; tests give a fake. */
interface FilesHost {
    val content: ContentAccess

    /** The app's package name: its own providers are never read back. */
    val packageName: String

    /** Throws [ActivityNotFoundException] when no app answers [intent]. */
    fun startForResult(intent: Intent, requestCode: Int)

    fun start(intent: Intent)

    /** The FileProvider URI of a file in the share cache. */
    fun shareUri(file: File): Uri

    fun primaryClip(): ClipData?

    fun clipHasImages(): Boolean

    fun chooserTitle(): String

    /** Sets [listener] on the Flutter view; false while the view is not there yet. */
    fun listenForDrops(listener: View.OnDragListener?): Boolean

    /** The read grant of a drop and the function that gives it back, or null without one. */
    fun dropPermissions(event: DragEvent): (() -> Unit)?
}

class ActivityFilesHost(private val activity: Activity) : FilesHost {
    override val content = ResolverContentAccess(activity.contentResolver)

    override val packageName: String = activity.packageName

    private val clipboard get() = activity.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager

    override fun startForResult(intent: Intent, requestCode: Int) = activity.startActivityForResult(intent, requestCode)

    override fun start(intent: Intent) = activity.startActivity(intent)

    // `${applicationId}.files`: the tailscale flavor has its own application ID.
    override fun shareUri(file: File): Uri = FileProvider.getUriForFile(activity, activity.packageName + AUTHORITY_SUFFIX, file)

    override fun primaryClip(): ClipData? = clipboard?.primaryClip

    // The description only: reading it shows no clipboard notice.
    override fun clipHasImages(): Boolean = clipboard?.primaryClipDescription?.hasMimeType("image/*") == true

    override fun chooserTitle(): String = activity.getString(R.string.files_share_title)

    override fun listenForDrops(listener: View.OnDragListener?): Boolean {
        val view = activity.findViewById<View>(FlutterActivity.FLUTTER_VIEW_ID) ?: return false
        view.setOnDragListener(listener)
        return true
    }

    override fun dropPermissions(event: DragEvent): (() -> Unit)? =
        runCatching { activity.requestDragAndDropPermissions(event) }.getOrNull()?.let { permissions -> { permissions.release() } }

    companion object {
        const val AUTHORITY_SUFFIX = ".files"
    }
}

/** The FileProvider of the share cache (`${applicationId}.files`); not exported. */
class PircFileProvider : FileProvider()

/**
 * `org.mozufu.pirc/files`: the system pickers, share, clipboard images and dropped images.
 * - `pick {multiple?, mimeTypes?, maxBytes?}` → files, or null when the user cancelled
 *   (`maxBytes` per file, at most [MAX_PICK_BYTES], default [MAX_FILE_BYTES])
 *   (`ACTION_OPEN_DOCUMENT`, else `ACTION_GET_CONTENT`; no persistable grant is taken)
 * - `save {name, mimeType, bytes}` → the saved name, or null when cancelled
 *   (`ACTION_CREATE_DOCUMENT`; at most 32 MiB)
 * - `shareText {text, subject?}`; `sharePart {share?, bytes}` → the share ID (parts of at
 *   most 32 MiB, 1 GiB in all); `shareFile {share, name, mimeType}`; `shareDiscard {share}`
 * - `clipboardHasImages` → bool; `clipboardImages` → files
 * - `setDropTarget {token, left, top, right, bottom, devicePixelRatio}` (logical pixels in
 *   the Flutter view), `clearDropTarget {token}`; a drop on the target calls Dart's
 *   `dropped {token, files}`
 *
 * A file is `{name, mimeType, bytes}`, or `{name, mimeType, error}` with `TOO_LARGE`
 * (over [MAX_FILE_BYTES]), `TOO_MANY` (past [MAX_FILES] files or [MAX_TOTAL_BYTES] in
 * all in one pick, paste or drop) or `READ` (also any URI of the app's own providers). Names are cleaned with [cleanFileName]. Errors:
 * `INVALID`, `BUSY` (a picker is open), `UNAVAILABLE` (no app answers) and `FILES`.
 */
class FilesChannel(
    private val host: FilesHost,
    private val cache: ShareCache,
    private val work: Executor,
    private val reply: Executor = mainThreadExecutor(),
    private val owned: ExecutorService? = null,
) : PlatformFeature {
    override val name = "files"

    private sealed class Pending(val result: MethodChannel.Result) {
        class Pick(result: MethodChannel.Result, val maxBytes: Int) : Pending(result)

        class Save(result: MethodChannel.Result, val name: String, val bytes: ByteArray) : Pending(result)
    }

    private var pending: Pending? = null
    private var channel: MethodChannel? = null
    private var dropTarget: DropTarget? = null
    private var listening = false
    private val dragListener = View.OnDragListener { _, event -> onDrag(event) }

    override fun attached(channel: MethodChannel) {
        this.channel = channel
        work.execute { runCatching { cache.prune() } }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "pick" -> pick(call, result)
                "save" -> save(call, result)
                "shareText" -> shareText(call, result)
                "sharePart" -> {
                    val share = call.argument<Number>("share")?.toLong()
                    val bytes = call.argument<ByteArray>("bytes") ?: throw IllegalArgumentException("bytes is required")
                    later(result, { cache.append(share, bytes) }) { it }
                }
                "shareFile" -> shareFile(call, result)
                "shareDiscard" -> {
                    val share = shareId(call)
                    work.execute { runCatching { cache.discard(share) } }
                    result.success(null)
                }
                "clipboardHasImages" -> result.success(runCatching { host.clipHasImages() }.getOrDefault(false))
                "clipboardImages" -> {
                    val uris = host.primaryClip()?.let(::clipUris).orEmpty()
                    later(result, { readImages(host.content, uris, host.packageName) }) { files -> files.map { it.wire() } }
                }
                "setDropTarget" -> {
                    setDropTarget(call)
                    result.success(null)
                }
                "clearDropTarget" -> {
                    if (dropTarget?.token == call.argument<Number>("token")?.toLong()) dropTarget = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: IllegalArgumentException) {
            result.error("INVALID", e.message, null)
        } catch (e: ClassCastException) {
            result.error("INVALID", "Wrong argument type", null)
        }
    }

    private fun pick(call: MethodCall, result: MethodChannel.Result) {
        val multiple = call.argument<Boolean>("multiple") ?: true
        val mimeTypes = call.argument<List<String>>("mimeTypes").orEmpty().map {
            require(it == "*/*" || it.endsWith("/*") || concreteMimeType(it) != null) { "Invalid MIME type" }
            it.lowercase()
        }
        val maxBytes = call.argument<Number>("maxBytes")?.toLong() ?: MAX_FILE_BYTES.toLong()
        require(maxBytes in 1..MAX_PICK_BYTES) { "maxBytes must be 1 to $MAX_PICK_BYTES" }
        if (busy(result)) return
        val request = Pending.Pick(result, maxBytes.toInt())
        pending = request
        val opened = launch(openDocumentIntent(multiple, mimeTypes), PICK_REQUEST) ||
            launch(getContentIntent(multiple, mimeTypes), PICK_REQUEST)
        if (!opened && pending === request) {
            pending = null
            result.error("UNAVAILABLE", "No app can pick files", null)
        }
    }

    private fun save(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes") ?: throw IllegalArgumentException("bytes is required")
        require(bytes.size <= MAX_SAVE_BYTES) { "bytes exceed the 32 MiB save limit" }
        val name = cleanFileName(call.argument<String>("name"), FALLBACK_NAME)
        val mimeType = concreteMimeType(call.argument<String>("mimeType")) ?: DEFAULT_MIME_TYPE
        if (busy(result)) return
        // The message codec decodes each call into its own array: no copy is needed.
        val request = Pending.Save(result, name, bytes)
        pending = request
        if (!launch(createDocumentIntent(name, mimeType), SAVE_REQUEST) && pending === request) {
            pending = null
            result.error("UNAVAILABLE", "No app can save files", null)
        }
    }

    override fun activityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val request = pending
        when {
            requestCode == PICK_REQUEST && request is Pending.Pick -> {
                pending = null
                val uris = pickedUris(resultCode, data)
                if (uris.isNullOrEmpty()) {
                    request.result.success(null)
                } else {
                    later(request.result, { readAll(host.content, uris, host.packageName, request.maxBytes) }) { files ->
                        files.map { it.wire() }
                    }
                }
            }
            requestCode == SAVE_REQUEST && request is Pending.Save -> {
                pending = null
                val destination = data?.data
                if (resultCode != Activity.RESULT_OK || destination == null) {
                    request.result.success(null)
                } else {
                    later(request.result, { write(destination, request) }) { it }
                }
            }
            requestCode == SAVE_REQUEST && request == null -> {
                // The activity was created again while the save picker was open: the bytes
                // are gone, so remove the empty document the picker just made.
                val orphan = data?.data
                if (resultCode == Activity.RESULT_OK && orphan != null) {
                    work.execute { runCatching { host.content.delete(orphan) } }
                }
            }
            else -> return false
        }
        return true
    }

    private fun write(destination: Uri, request: Pending.Save): String {
        try {
            (host.content.write(destination) ?: throw IOException("No stream")).use { it.write(request.bytes) }
        } catch (e: Exception) {
            // Do not leave an empty or partial document behind.
            runCatching { host.content.delete(destination) }
            throw e
        }
        val saved = runCatching { host.content.describe(destination).first }.getOrNull()
        return saved?.let { cleanFileName(it, request.name) } ?: request.name
    }

    private fun shareText(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text") ?: throw IllegalArgumentException("text is required")
        require(text.isNotEmpty() && text.length <= MAX_SHARE_TEXT) { "text must hold 1 to $MAX_SHARE_TEXT characters" }
        val subject = call.argument<String>("subject")?.take(MAX_SUBJECT)
        startChooser(result, shareTextIntent(text, subject))
    }

    private fun shareFile(call: MethodCall, result: MethodChannel.Result) {
        val share = shareId(call)
        val name = call.argument<String>("name")
        val mimeType = concreteMimeType(call.argument<String>("mimeType")) ?: DEFAULT_MIME_TYPE
        later(result, { cache.finish(share, name) }) { file ->
            startChooser(null, shareFileIntent(host.shareUri(file), mimeType))
            null
        }
    }

    private fun shareTextIntent(text: String, subject: String?): Intent {
        val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
        if (!subject.isNullOrEmpty()) send.putExtra(Intent.EXTRA_SUBJECT, subject)
        return Intent.createChooser(send, host.chooserTitle())
    }

    /** Only a read grant, for this one URI. */
    private fun shareFileIntent(uri: Uri, mimeType: String): Intent {
        val send = Intent(Intent.ACTION_SEND)
            .setType(mimeType)
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        send.clipData = ClipData.newRawUri(null, uri)
        return Intent.createChooser(send, host.chooserTitle())
    }

    /** Starts [chooser]; answers [result] when given, else throws for [later] to answer. */
    private fun startChooser(result: MethodChannel.Result?, chooser: Intent) {
        try {
            host.start(chooser)
            result?.success(null)
        } catch (e: ActivityNotFoundException) {
            if (result == null) throw e
            result.error("UNAVAILABLE", "No app can take this", null)
        }
    }

    private fun setDropTarget(call: MethodCall) {
        val token = call.argument<Number>("token")?.toLong() ?: throw IllegalArgumentException("token is required")
        fun number(key: String) = call.argument<Number>(key)?.toDouble() ?: throw IllegalArgumentException("$key is required")
        val bounds = DropBounds.fromLogical(
            number("left"),
            number("top"),
            number("right"),
            number("bottom"),
            number("devicePixelRatio"),
        ) ?: throw IllegalArgumentException("Invalid bounds")
        dropTarget = DropTarget(token, bounds)
        listen()
    }

    private fun listen() {
        if (!listening) listening = host.listenForDrops(dragListener)
    }

    private fun onDrag(event: DragEvent): Boolean {
        if (dropTarget == null) return false
        return when (event.action) {
            DragEvent.ACTION_DRAG_STARTED -> mayHoldImages(
                event.clipDescription?.let { description -> (0 until description.mimeTypeCount).map(description::getMimeType) },
            )
            DragEvent.ACTION_DROP -> {
                val uris = event.clipData?.let(::clipUris).orEmpty()
                drop(event.x, event.y, uris) { host.dropPermissions(event) }
            }
            else -> true
        }
    }

    /**
     * A drop of [uris] at ([x], [y]) in physical pixels: taken only on the current target and
     * with the drop's read grant, which is given back once the images are read.
     */
    internal fun drop(x: Float, y: Float, uris: List<Uri>, permissions: () -> (() -> Unit)?): Boolean {
        val target = dropTarget ?: return false
        if (!target.bounds.contains(x, y) || uris.isEmpty()) return false
        val release = permissions() ?: return false
        work.execute {
            val files = readDrop({ readImages(host.content, uris, host.packageName) }, release)
            reply.execute {
                if (files.isNotEmpty() && dropTarget?.token == target.token) {
                    channel?.invokeMethod("dropped", mapOf("token" to target.token, "files" to files.map { it.wire() }))
                }
            }
        }
        return true
    }

    override fun foreground() {
        if (dropTarget != null) listen()
    }

    override fun detach() {
        // The engine is going away: an open picker's answer has no one to go to.
        pending?.let { runCatching { it.result.success(null) } }
        pending = null
        dropTarget = null
        if (listening) runCatching { host.listenForDrops(null) }
        listening = false
        channel = null
        work.execute { runCatching { cache.discardUploads() } }
        owned?.shutdown()
    }

    private fun busy(result: MethodChannel.Result): Boolean {
        if (pending == null) return false
        result.error("BUSY", "A file picker is already open", null)
        return true
    }

    /** False when the picker did not start, for any reason, so no request stays pending. */
    private fun launch(intent: Intent, requestCode: Int): Boolean = try {
        host.startForResult(intent, requestCode)
        true
    } catch (_: Exception) {
        // ActivityNotFoundException, or a SecurityException from a locked-down picker.
        false
    }

    private fun shareId(call: MethodCall): Long =
        call.argument<Number>("share")?.toLong() ?: throw IllegalArgumentException("share is required")

    /** Runs [action] on the work thread, then [then] on the main thread, and answers. */
    private fun <T> later(result: MethodChannel.Result, action: () -> T, then: (T) -> Any?) {
        work.execute {
            val outcome = runCatching(action)
            reply.execute {
                outcome.mapCatching(then).fold(
                    onSuccess = { result.success(it) },
                    onFailure = {
                        val code = when (it) {
                            is IllegalArgumentException -> "INVALID"
                            is ActivityNotFoundException -> "UNAVAILABLE"
                            else -> "FILES"
                        }
                        result.error(code, it.message ?: it.javaClass.simpleName, null)
                    },
                )
            }
        }
    }

    companion object {
        const val PICK_REQUEST = 0x7046
        const val SAVE_REQUEST = 0x7047
        const val MAX_SAVE_BYTES = 32 * 1024 * 1024
        const val MAX_SHARE_TEXT = 100_000
        private const val MAX_SUBJECT = 1_000
        private const val FALLBACK_NAME = "file"

        fun create(activity: Activity): FilesChannel {
            val work = Executors.newSingleThreadExecutor()
            return FilesChannel(ActivityFilesHost(activity), ShareCache(activity.cacheDir), work, owned = work)
        }
    }
}
