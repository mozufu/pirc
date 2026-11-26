package org.mozufu.pirc.files

import android.app.Activity
import android.content.ClipData
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/**
 * The limit of one picked, pasted or dropped file: the most any Gateway accepts for an
 * upload (`MAX_UPLOAD_BYTES` in `crates/pirc-config`, 11 MiB). A Gateway set lower
 * (10 MiB by default) still refuses a larger upload itself.
 */
const val MAX_FILE_BYTES = 11 * 1024 * 1024

/** The most files one pick, paste or drop reads: the node's `maxAttachments` (16). */
const val MAX_FILES = 16

/** The most bytes one pick, paste or drop holds in memory in all. */
const val MAX_TOTAL_BYTES = 64 * 1024 * 1024

/** The largest file Dart may ask for with `maxBytes` (a picture that is cropped before upload). */
const val MAX_PICK_BYTES = 32 * 1024 * 1024

/** The content of other apps, read through [ContentResolver] streams only. */
interface ContentAccess {
    fun type(uri: Uri): String?

    /** The display name and size the provider reports; either may be missing or wrong. */
    fun describe(uri: Uri): Pair<String?, Long?>

    fun open(uri: Uri): InputStream?

    /** Truncates and writes the document at [uri]. */
    fun write(uri: Uri): OutputStream?

    fun delete(uri: Uri)
}

class ResolverContentAccess(private val resolver: ContentResolver) : ContentAccess {
    override fun type(uri: Uri): String? = resolver.getType(uri)

    override fun describe(uri: Uri): Pair<String?, Long?> {
        val columns = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return resolver.query(uri, columns, null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst()) return@use null to null
            val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
            val name = if (nameColumn >= 0 && !cursor.isNull(nameColumn)) cursor.getString(nameColumn) else null
            val size = if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) cursor.getLong(sizeColumn) else null
            name to size?.takeIf { it >= 0 }
        } ?: (null to null)
    }

    override fun open(uri: Uri): InputStream? = resolver.openInputStream(uri)

    // "wt": plain "w" does not truncate an existing document on some providers.
    override fun write(uri: Uri): OutputStream? = resolver.openOutputStream(uri, "wt")

    override fun delete(uri: Uri) {
        DocumentsContract.deleteDocument(resolver, uri)
    }
}

/** One file read for Dart, or why it was not. */
sealed class FileRead {
    abstract val name: String
    abstract val mimeType: String

    class Bytes(override val name: String, override val mimeType: String, val bytes: ByteArray) : FileRead()

    /** [reason] is `TOO_LARGE`, `TOO_MANY` (over [MAX_FILES] or [MAX_TOTAL_BYTES] in all) or `READ`. */
    data class Refused(override val name: String, override val mimeType: String, val reason: String) : FileRead()

    fun wire(): Map<String, Any> = when (this) {
        is Bytes -> mapOf("name" to name, "mimeType" to mimeType, "bytes" to bytes)
        is Refused -> mapOf("name" to name, "mimeType" to mimeType, "error" to reason)
    }
}

class TooLargeException : IOException("The file exceeds the size limit")

/** Reads [input] whole, failing as soon as it passes [limit] bytes. */
fun readLimited(input: InputStream, limit: Int): ByteArray {
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(64 * 1024)
    while (true) {
        val count = input.read(buffer)
        if (count < 0) break
        if (output.size() + count > limit) throw TooLargeException()
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}

/** Whether [uri] is a `content:` URI of another app; [ownPackage] is the app's package name. */
fun isForeignContent(uri: Uri, ownPackage: String): Boolean {
    if (uri.scheme != ContentResolver.SCHEME_CONTENT) return false
    val authority = uri.authority ?: return false
    // The app's own providers (the share cache, plugins' providers) are never read back.
    return authority != ownPackage && !authority.startsWith("$ownPackage.")
}

/**
 * Reads one `content:` URI of another app that the user picked, pasted or dropped.
 * Other schemes are refused (a `file:` URI could name the app's own private files), and
 * so are the app's own providers.
 */
fun readContent(content: ContentAccess, uri: Uri, ownPackage: String, limit: Int = MAX_FILE_BYTES): FileRead {
    var name = cleanFileName(uri.lastPathSegment, FALLBACK_NAME)
    var mimeType = DEFAULT_MIME_TYPE
    return try {
        if (!isForeignContent(uri, ownPackage)) return FileRead.Refused(name, mimeType, "READ")
        val (displayName, size) = content.describe(uri)
        name = cleanFileName(displayName ?: uri.lastPathSegment, FALLBACK_NAME)
        mimeType = concreteMimeType(content.type(uri)) ?: mimeFromName(name) ?: DEFAULT_MIME_TYPE
        // The reported size refuses early; the stream is still limited, as it may be wrong.
        if (size != null && size > limit) return FileRead.Refused(name, mimeType, "TOO_LARGE")
        val bytes = (content.open(uri) ?: throw IOException("No stream")).use { readLimited(it, limit) }
        FileRead.Bytes(name, mimeType, bytes)
    } catch (_: TooLargeException) {
        FileRead.Refused(name, mimeType, "TOO_LARGE")
    } catch (_: Exception) {
        // SecurityException (no grant), FileNotFoundException, a provider crash.
        FileRead.Refused(name, mimeType, "READ")
    }
}

/**
 * Reads [uris] in order: each at most [limit] bytes, the first [MAX_FILES] only, and at
 * most [MAX_TOTAL_BYTES] in all. The rest are refused with `TOO_MANY` without being read.
 */
fun readAll(content: ContentAccess, uris: List<Uri>, ownPackage: String, limit: Int = MAX_FILE_BYTES): List<FileRead> {
    var total = 0L
    return uris.mapIndexed { index, uri ->
        val left = MAX_TOTAL_BYTES - total
        if (index >= MAX_FILES || left <= 0) {
            return@mapIndexed FileRead.Refused(cleanFileName(uri.lastPathSegment, FALLBACK_NAME), DEFAULT_MIME_TYPE, "TOO_MANY")
        }
        val read = readContent(content, uri, ownPackage, minOf(limit.toLong(), left).toInt())
        if (read is FileRead.Bytes) total += read.bytes.size
        // Too large only for what is left: the total is what refused it.
        if (read is FileRead.Refused && read.reason == "TOO_LARGE" && left < limit) read.copy(reason = "TOO_MANY") else read
    }
}

/** Only the images of [uris], by the type their provider reports, read as [readAll] does. */
fun readImages(content: ContentAccess, uris: List<Uri>, ownPackage: String, limit: Int = MAX_FILE_BYTES): List<FileRead> =
    readAll(
        content,
        uris.filter { uri ->
            isForeignContent(uri, ownPackage) &&
                runCatching { concreteMimeType(content.type(uri)) }.getOrNull()?.startsWith("image/") == true
        },
        ownPackage,
        limit,
    )

/** The URIs of a picker's answer, in order and once each; null when the user cancelled. */
fun pickedUris(resultCode: Int, data: Intent?): List<Uri>? {
    if (resultCode != Activity.RESULT_OK) return null
    val uris = LinkedHashSet<Uri>()
    data?.clipData?.let { uris += clipUris(it) }
    data?.data?.let { uris += it }
    return uris.toList()
}

/** The URIs of [clip], in order and once each. */
fun clipUris(clip: ClipData): List<Uri> =
    (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }.distinct()

/** `ACTION_OPEN_DOCUMENT` for [mimeTypes] (any type when empty); never a persistable grant. */
fun openDocumentIntent(multiple: Boolean, mimeTypes: List<String>): Intent =
    Intent(Intent.ACTION_OPEN_DOCUMENT).withPickerOptions(multiple, mimeTypes)

/** The fallback when no app answers `ACTION_OPEN_DOCUMENT`. */
fun getContentIntent(multiple: Boolean, mimeTypes: List<String>): Intent =
    Intent(Intent.ACTION_GET_CONTENT).withPickerOptions(multiple, mimeTypes)

private fun Intent.withPickerOptions(multiple: Boolean, mimeTypes: List<String>): Intent {
    addCategory(Intent.CATEGORY_OPENABLE)
    type = mimeTypes.singleOrNull() ?: "*/*"
    if (mimeTypes.size > 1) putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple)
    return this
}

/** `ACTION_CREATE_DOCUMENT` suggesting [name] (already clean). */
fun createDocumentIntent(name: String, mimeType: String): Intent =
    Intent(Intent.ACTION_CREATE_DOCUMENT)
        .addCategory(Intent.CATEGORY_OPENABLE)
        .setType(mimeType)
        .putExtra(Intent.EXTRA_TITLE, name)

private fun mimeFromName(name: String): String? {
    val extension = name.substringAfterLast('.', "").lowercase()
    if (extension.isEmpty()) return null
    return concreteMimeType(runCatching { MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) }.getOrNull())
}

const val DEFAULT_MIME_TYPE = "application/octet-stream"
private const val FALLBACK_NAME = "file"
