package org.mozufu.pirc.files

/**
 * A file name to show or to write: the last path part of [name], without C0 and C1
 * controls or format characters (bidi overrides such as U+202E, zero-width
 * characters), so a name cannot hide its real extension or climb out of a folder.
 * A display name from another app is never used as a path before this.
 */
fun cleanFileName(name: String?, fallback: String): String {
    val last = (name ?: "").substringAfterLast('/').substringAfterLast('\\')
    val base = buildString {
        last.codePoints().forEach {
            val type = Character.getType(it)
            if (type != Character.CONTROL.toInt() && type != Character.FORMAT.toInt()) appendCodePoint(it)
        }
    }.trim().take(MAX_NAME_LENGTH).let { if (it.lastOrNull()?.isHighSurrogate() == true) it.dropLast(1) else it }
    return if (base.isEmpty() || base == "." || base == "..") fallback else base
}

/** The `type/subtype` of [mimeType] in lower case, or null when it is not one concrete type. */
fun concreteMimeType(mimeType: String?): String? {
    val essence = mimeType?.substringBefore(';')?.trim()?.lowercase() ?: return null
    if (essence.length > 255 || !essence.matches(MIME_ESSENCE)) return null
    return essence
}

private const val MAX_NAME_LENGTH = 200

private val MIME_ESSENCE = Regex("""^[!#$%&'+.^_`|~0-9a-z-]+/[!#$%&'+.^_`|~0-9a-z-]+$""")
