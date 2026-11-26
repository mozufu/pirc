package org.mozufu.pirc.files

/** The composer's bounds in the Flutter view, in physical pixels. */
data class DropBounds(val left: Float, val top: Float, val right: Float, val bottom: Float) {
    fun contains(x: Float, y: Float): Boolean =
        x.isFinite() && y.isFinite() && x >= left && x < right && y >= top && y < bottom

    companion object {
        /** Bounds from Flutter's logical pixels; null when they are not a real rectangle. */
        fun fromLogical(left: Double, top: Double, right: Double, bottom: Double, devicePixelRatio: Double): DropBounds? {
            val values = listOf(left, top, right, bottom, devicePixelRatio)
            if (!values.all(Double::isFinite) || devicePixelRatio <= 0 || right <= left || bottom <= top) return null
            return DropBounds(
                (left * devicePixelRatio).toFloat(),
                (top * devicePixelRatio).toFloat(),
                (right * devicePixelRatio).toFloat(),
                (bottom * devicePixelRatio).toFloat(),
            )
        }
    }
}

/** The one composer that takes dropped images now; Dart names it with [token]. */
data class DropTarget(val token: Long, val bounds: DropBounds)

/** Whether a drag that starts with these MIME types may hold images. */
fun mayHoldImages(mimeTypes: Iterable<String>?): Boolean = mimeTypes?.any {
    it.startsWith("image/", ignoreCase = true) || it.equals("text/uri-list", ignoreCase = true)
} == true

/**
 * Reads the images of one drop and always gives the drop's read grant back afterwards
 * ([release] is `DragAndDropPermissions.release`), whether the read worked or not.
 */
fun readDrop(read: () -> List<FileRead>, release: () -> Unit): List<FileRead> = try {
    read()
} finally {
    runCatching(release)
}
