package org.mozufu.pirc.images

import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.os.Build
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

/**
 * Decodes a static AVIF image into an 8-bit sRGB PNG for Flutter to paint. It works on
 * the bytes it is given only: no network and no files. Ported from the old app's
 * `NativeRasterImages.kt`.
 */
object RasterImages {
    const val MAX_BYTES = 32 * 1024 * 1024
    private const val MAX_PIXELS = 16_777_216L

    /** AVIF decoding needs Android 12 (API 31). */
    fun avifSupported(): Boolean = Build.VERSION.SDK_INT >= 31

    fun capabilities(): Map<String, Boolean> = mapOf("avif" to avifSupported())

    /** Throws [IllegalArgumentException] for bytes that are not a static AVIF image. */
    fun checkAvif(bytes: ByteArray) {
        require(avifSupported()) { "AVIF requires Android 12 or later" }
        require(bytes.size in 12..MAX_BYTES) { "Invalid image byte size" }
        val header = bytes.copyOfRange(0, minOf(bytes.size, 128)).toString(Charsets.ISO_8859_1)
        require(header.substring(4, 8) == "ftyp" && header.contains("avif") && !header.contains("avis")) {
            "Only static AVIF is supported"
        }
    }

    fun normalize(bytes: ByteArray): ByteArray {
        checkAvif(bytes)
        val decoded = ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { decoder, info, _ ->
            require(info.size.width.toLong() * info.size.height <= MAX_PIXELS) { "Decoded image exceeds pixel limit" }
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            decoder.isUnpremultipliedRequired = true
            decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
        }
        try {
            // An explicit 8-bit sRGB surface also normalizes high-bit-depth data.
            val normalized = Bitmap.createBitmap(decoded.width, decoded.height, Bitmap.Config.ARGB_8888)
            try {
                // Request straight alpha, then let setPixels premultiply once.
                // Android AVIF alpha otherwise reaches Flutter with an incorrect
                // premultiplication flag, brightening transparent RGB channels.
                val row = IntArray(decoded.width)
                for (y in 0 until decoded.height) {
                    decoded.getPixels(row, 0, decoded.width, 0, y, decoded.width, 1)
                    normalized.setPixels(row, 0, decoded.width, 0, y, decoded.width, 1)
                }
                val output = ByteArrayOutputStream()
                check(normalized.compress(Bitmap.CompressFormat.PNG, 100, output)) { "Image encoding failed" }
                val result = output.toByteArray()
                check(result.size <= MAX_BYTES) { "Normalized image exceeds byte limit" }
                return result
            } finally {
                normalized.recycle()
            }
        } finally {
            decoded.recycle()
        }
    }
}
