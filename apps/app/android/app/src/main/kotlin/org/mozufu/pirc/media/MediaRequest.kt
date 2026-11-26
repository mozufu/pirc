package org.mozufu.pirc.media

/**
 * The validated arguments of `open`. The channel plays bytes that Dart already holds
 * (a Gateway recording, a document's media); it never fetches a URL itself. The bytes
 * come either in the call ([bytes], at most [MAX_MEDIA_BYTES]) or as an [upload] that
 * Dart wrote in parts before (a recording, at most [MAX_UPLOAD_BYTES]).
 */
class MediaOpenRequest(
    val bytes: ByteArray?,
    val upload: Long?,
    val mimeType: String,
    val kind: String,
    val muted: Boolean,
    val loop: Boolean,
)

/** The limit of media bytes in one call, and so of HTML media. */
const val MAX_MEDIA_BYTES = 32 * 1024 * 1024

/** The limit of an upload: a 30-minute browser recording. */
const val MAX_UPLOAD_BYTES = 1024L * 1024 * 1024

/** Checks untrusted arguments from Dart before any file or player work. */
fun validateMediaOpenRequest(
    bytes: ByteArray?,
    upload: Long? = null,
    mimeType: String?,
    kind: String?,
    muted: Boolean?,
    loop: Boolean?,
): MediaOpenRequest {
    require((bytes != null) != (upload != null)) { "Give either bytes or upload" }
    if (bytes != null) {
        require(bytes.isNotEmpty()) { "bytes is required" }
        require(bytes.size <= MAX_MEDIA_BYTES) { "Media exceeds the 32 MiB limit" }
    }
    require(kind == "audio" || kind == "video") { "kind must be audio or video" }
    require(mimeType != null && mimeType.length <= 256 && mimeType.matches(MIME_TYPE_PATTERN)) {
        "A valid MIME type is required"
    }
    val essence = mediaEssence(mimeType)
    require('*' !in essence) { "A concrete MIME type is required" }
    require(essence.startsWith("audio/") || essence.startsWith("video/") || essence == "application/ogg") {
        "Only audio and video MIME types can be played"
    }
    return MediaOpenRequest(
        // Dart may reuse its buffer; keep our own copy for the async write.
        bytes = bytes?.copyOf(),
        upload = upload,
        mimeType = mimeType,
        kind = kind,
        muted = muted ?: false,
        loop = loop ?: false,
    )
}

/** `video/webm; codecs=vp9` → `video/webm`. */
fun mediaEssence(mimeType: String): String = mimeType.substringBefore(';').trim().lowercase()

/** A file name for Downloads: the last path part, without control characters. */
fun mediaFileName(name: String?): String {
    // Drops C0 and C1 controls and format characters (bidi overrides such as U+202E,
    // zero-width characters), so a name cannot hide its real extension.
    val last = (name ?: "").substringAfterLast('/').substringAfterLast('\\')
    val base = buildString {
        last.codePoints().forEach {
            val type = Character.getType(it)
            if (type != Character.CONTROL.toInt() && type != Character.FORMAT.toInt()) appendCodePoint(it)
        }
    }.trim().take(MAX_NAME_LENGTH).let { if (it.lastOrNull()?.isHighSurrogate() == true) it.dropLast(1) else it }
    return if (base.isEmpty() || base == "." || base == "..") "media" else base
}

private const val MAX_NAME_LENGTH = 200

private val MIME_TYPE_PATTERN = Regex(
    """^[!#$%&'*+.^_`|~0-9A-Za-z-]+/[!#$%&'*+.^_`|~0-9A-Za-z-]+(?:\s*;[^\r\n]*)?$""",
)
