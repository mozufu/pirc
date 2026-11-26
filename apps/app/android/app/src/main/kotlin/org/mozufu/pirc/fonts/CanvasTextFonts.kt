package org.mozufu.pirc.fonts

import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.fonts.Font
import android.graphics.fonts.FontStyle
import android.graphics.text.PositionedGlyphs
import android.graphics.text.TextRunShaper
import android.os.Build
import java.security.MessageDigest
import java.text.Bidi
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Collects the exact system font files selected by Android's public text shaper, for the
 * Canvas text of document scripts. It reads installed system fonts only: no network.
 * Ported from the old app's `NativeCanvasTextFonts.kt`.
 */
object CanvasTextFonts {
    const val MAX_FAMILIES = 16
    const val MAX_SAMPLE_LENGTH = 4096
    private const val MAX_RESOURCES = 32
    // Complete Latin/CJK sans + serif outlines must fit without stripping real ink.
    // The isolate heap and evaluation limits remain independently bounded.
    private const val MAX_TOTAL_FONT_BYTES = 64 * 1024 * 1024
    private const val LATIN_DIGITS_SAMPLE = "AaZz 0123456789 "

    private val styles = listOf(
        RequestedStyle(weight = 400, italic = false),
        RequestedStyle(weight = 400, italic = true),
        RequestedStyle(weight = 700, italic = false),
        RequestedStyle(weight = 700, italic = true),
    )

    /**
     * Returns font resources selected for each requested family and standard CSS weight/slant.
     * The text is shaped with the authored sample plus Latin letters and digits so callers always
     * receive a useful Latin face as well as fonts needed by the sample's scripts.
     */
    fun collect(families: List<String>, sampleText: String): Map<String, Any?> {
        check(supported()) { "Canvas font collection requires Android 12 (API 31) or later" }
        checkRequest(families, sampleText)

        val text = LATIN_DIGITS_SAMPLE + sampleText
        val resourcesById = linkedMapOf<String, CapturedResource>()
        val binaryByDigest = HashMap<String, ByteArray>()
        val binaryBySource = HashMap<FontSourceKey, FontBinary>()
        val shapedFontIds = HashMap<ShapedFontKey, String>()
        var uniqueBinaryBytes = 0L
        val matches = ArrayList<Map<String, Any?>>(families.size * styles.size)

        for (family in families) {
            val baseTypeface = typefaceForFamily(family)
            for (requestedStyle in styles) {
                val typeface = Typeface.create(baseTypeface, requestedStyle.weight, requestedStyle.italic)
                val paint = Paint().apply {
                    this.typeface = typeface
                    textSize = 1f
                }
                val resourceIds = linkedSetOf<String>()
                val bidi = Bidi(text, Bidi.DIRECTION_DEFAULT_LEFT_TO_RIGHT)
                for (runIndex in 0 until bidi.runCount) {
                    val runStart = bidi.getRunStart(runIndex)
                    val runLimit = bidi.getRunLimit(runIndex)
                    val glyphs = TextRunShaper.shapeTextRun(
                        text,
                        runStart,
                        runLimit - runStart,
                        0,
                        text.length,
                        0f,
                        0f,
                        bidi.getRunLevel(runIndex) and 1 != 0,
                        paint,
                    )
                    for (glyphIndex in 0 until glyphs.glyphCount()) {
                        val font = glyphs.getFont(glyphIndex)
                        val overrides = glyphVariationOverrides(glyphs, glyphIndex)
                        val axes = effectiveAxes(font, overrides.weight, overrides.italic)
                        val style = font.style
                        val weight = overrides.weight?.roundToInt()
                            ?: axes.firstOrNull { it.axis == "wght" }?.value?.roundToInt()
                            ?: style.weight
                        require(weight in 1..1000) {
                            "Selected font reported an invalid weight: $weight"
                        }
                        val italic = overrides.italic?.let { it >= 0.5f } ?: (
                            style.slant == FontStyle.FONT_SLANT_ITALIC ||
                                (axes.firstOrNull { it.axis == "ital" }?.value ?: 0.0) >= 0.5 ||
                                (axes.firstOrNull { it.axis == "slnt" }?.value ?: 0.0) != 0.0
                            )
                        // API 35 exposes the shaper's per-glyph synthesis flags. Earlier
                        // releases fall back to comparing the requested style to the selected
                        // Font style/axes using Minikin's >=600 / two-grade fake-bold threshold;
                        // this is an inference, not an Android-reported flag.
                        val fakeBold = overrides.fakeBold ?: (
                            requestedStyle.weight >= 600 && requestedStyle.weight - weight >= 200
                            )
                        val fakeItalic = overrides.fakeItalic ?: (requestedStyle.italic && !italic)
                        val key = ShapedFontKey(
                            sourceIdentifier = font.sourceIdentifier,
                            originalTtcIndex = font.ttcIndex,
                            weight = weight,
                            italic = italic,
                            fakeBold = fakeBold,
                            fakeItalic = fakeItalic,
                            axes = axes.map { AxisKey(it.axis, it.floatBits) },
                        )
                        val id = shapedFontIds[key] ?: captureFont(
                            font = font,
                            weight = weight,
                            italic = italic,
                            fakeBold = fakeBold,
                            fakeItalic = fakeItalic,
                            axes = axes,
                            resourcesById = resourcesById,
                            binaryByDigest = binaryByDigest,
                            binaryBySource = binaryBySource,
                            uniqueBinaryBytes = uniqueBinaryBytes,
                        ).let { captured ->
                            uniqueBinaryBytes = captured.updatedUniqueBinaryBytes
                            shapedFontIds[key] = captured.resource.id
                            captured.resource.id
                        }
                        resourceIds.add(id)
                    }
                }
                check(resourceIds.isNotEmpty()) {
                    "Android text shaping returned no fonts for family '$family'"
                }
                matches.add(
                    linkedMapOf(
                        "family" to family,
                        "weight" to requestedStyle.weight,
                        "italic" to requestedStyle.italic,
                        "resourceIds" to resourceIds.toList(),
                    ),
                )
            }
        }

        return linkedMapOf(
            "resources" to resourcesById.values.map { it.toMap() },
            "matches" to matches,
        )
    }

    /** The public text shaper ([TextRunShaper]) needs Android 12 (API 31). */
    fun supported(): Boolean = Build.VERSION.SDK_INT >= 31

    /** Throws [IllegalArgumentException] for a request [collect] refuses. */
    fun checkRequest(families: List<String>, sampleText: String) {
        require(families.size <= MAX_FAMILIES) {
            "At most $MAX_FAMILIES font families can be collected"
        }
        require(sampleText.length <= MAX_SAMPLE_LENGTH) {
            "Font sample text must be at most $MAX_SAMPLE_LENGTH UTF-16 code units"
        }
        require(families.all { it.isNotBlank() }) { "Font family names must not be blank" }
    }

    private fun typefaceForFamily(family: String): Typeface = when (family.trim().lowercase(Locale.ROOT)) {
        "sans-serif" -> Typeface.SANS_SERIF
        "system-ui" -> Typeface.DEFAULT
        "serif" -> Typeface.SERIF
        "monospace" -> Typeface.MONOSPACE
        else -> Typeface.create(family.trim(), Typeface.NORMAL)
    }

    private fun glyphVariationOverrides(
        glyphs: PositionedGlyphs,
        glyphIndex: Int,
    ): GlyphVariationOverrides {
        // PositionedGlyphs exposed variable-font overrides starting in API 35. On API 31-34,
        // the selected Font's own axes and FontStyle are the available public metadata. Fake
        // style flags have the same API 35 boundary and are inferred by the caller on 31-34.
        if (Build.VERSION.SDK_INT < 35) {
            return GlyphVariationOverrides(
                weight = null,
                italic = null,
                fakeBold = null,
                fakeItalic = null,
            )
        }

        val noOverride = PositionedGlyphs.NO_OVERRIDE
        val weight = glyphs.getWeightOverride(glyphIndex).takeUnless { it == noOverride }
        val italic = glyphs.getItalicOverride(glyphIndex).takeUnless { it == noOverride }
        return GlyphVariationOverrides(
            weight = weight,
            italic = italic,
            fakeBold = glyphs.getFakeBold(glyphIndex),
            fakeItalic = glyphs.getFakeItalic(glyphIndex),
        )
    }

    private fun effectiveAxes(
        font: Font,
        weightOverride: Float?,
        italicOverride: Float?,
    ): List<AxisValue> {
        val byTag = linkedMapOf<String, AxisValue>()
        for (axis in font.axes.orEmpty()) {
            val value = axis.styleValue
            require(value.isFinite()) { "Selected font reported a non-finite '${axis.tag}' axis" }
            byTag[axis.tag] = AxisValue(axis.tag, value.toDouble(), java.lang.Float.floatToIntBits(value))
        }
        if (weightOverride != null) {
            require(weightOverride.isFinite()) { "Selected font reported a non-finite weight override" }
            byTag["wght"] = axisValue("wght", weightOverride)
        }
        if (italicOverride != null) {
            require(italicOverride.isFinite()) { "Selected font reported a non-finite italic override" }
            byTag["ital"] = axisValue("ital", italicOverride)
        }
        return byTag.values.sortedWith(compareBy<AxisValue>({ it.axis }, { it.floatBits }))
    }

    private fun axisValue(tag: String, value: Float) =
        AxisValue(tag, value.toDouble(), java.lang.Float.floatToIntBits(value))

    private fun captureFont(
        font: Font,
        weight: Int,
        italic: Boolean,
        fakeBold: Boolean,
        fakeItalic: Boolean,
        axes: List<AxisValue>,
        resourcesById: LinkedHashMap<String, CapturedResource>,
        binaryByDigest: HashMap<String, ByteArray>,
        binaryBySource: HashMap<FontSourceKey, FontBinary>,
        uniqueBinaryBytes: Long,
    ): CapturedFont {
        val originalTtcIndex = font.ttcIndex
        require(originalTtcIndex >= 0) {
            "Selected font reported an invalid TTC index: $originalTtcIndex"
        }
        val file = font.file
            ?: error("Selected font has no regular font file path for its basename label")
        val label = file.name
        require(label.isNotBlank()) { "Selected font has an empty basename label" }

        val sourceIdentifier = font.sourceIdentifier
        val sourceKey = FontSourceKey(sourceIdentifier, originalTtcIndex)
        val cachedSource = binaryBySource[sourceKey]
        val digest: String
        val sharedBytes: ByteArray
        val nextUniqueBinaryBytes: Long
        if (cachedSource != null) {
            digest = cachedSource.digest
            sharedBytes = cachedSource.bytes
            nextUniqueBinaryBytes = uniqueBinaryBytes
        } else {
            // Android's Font buffer can reference an entire TTC. Extract directly from a
            // read-only duplicate so only the selected face tables are copied into the result.
            val extracted = CanvasFontFace.extract(font.buffer.duplicate(), originalTtcIndex)
            // Preserve complete CFF/CFF2 outlines so CanvasKit can return real ink bounds.
            val bytes = extracted
            digest = sha256(bytes)
            val existingBinary = binaryByDigest[digest]
            sharedBytes = if (existingBinary != null) {
                check(existingBinary.contentEquals(bytes)) { "Font binary digest collision for '$label'" }
                existingBinary
            } else {
                val nextTotal = uniqueBinaryBytes + bytes.size
                require(nextTotal <= MAX_TOTAL_FONT_BYTES.toLong()) {
                    "Collected system font files exceed $MAX_TOTAL_FONT_BYTES bytes: " +
                        "'$label' TTC index $originalTtcIndex adds ${bytes.size} extracted bytes " +
                        "after $uniqueBinaryBytes previously unique bytes"
                }
                binaryByDigest[digest] = bytes
                bytes
            }
            nextUniqueBinaryBytes = if (existingBinary == null) {
                uniqueBinaryBytes + bytes.size
            } else {
                uniqueBinaryBytes
            }
            binaryBySource[sourceKey] = FontBinary(digest, sharedBytes)
        }

        val instanceKey = buildString {
            append(digest)
            append('|').append(originalTtcIndex)
            append('|').append(weight)
            append('|').append(if (italic) 1 else 0)
            append('|').append(if (fakeBold) 1 else 0)
            append('|').append(if (fakeItalic) 1 else 0)
            for (axis in axes) {
                append('|').append(axis.axis).append(':').append(hexInt(axis.floatBits))
            }
        }
        val id = "font-${sha256(instanceKey.toByteArray(Charsets.UTF_8))}"
        val existing = resourcesById[id]
        if (existing != null) {
            check(existing.bytes.contentEquals(sharedBytes)) {
                "Font resource identifier collision for '$label'"
            }
            return CapturedFont(existing, uniqueBinaryBytes)
        }
        require(resourcesById.size < MAX_RESOURCES) {
            "Collected fonts exceed the $MAX_RESOURCES resource limit"
        }
        val resource = CapturedResource(
            id = id,
            bytes = sharedBytes,
            ttcIndex = 0,
            originalTtcIndex = originalTtcIndex,
            weight = weight,
            italic = italic,
            fakeBold = fakeBold,
            fakeItalic = fakeItalic,
            axes = axes,
            label = label,
        )
        resourcesById[id] = resource
        return CapturedFont(resource, nextUniqueBinaryBytes)
    }

    private fun sha256(bytes: ByteArray): String = hexBytes(
        MessageDigest.getInstance("SHA-256").digest(bytes),
    )

    private fun hexBytes(bytes: ByteArray): String = buildString(bytes.size * 2) {
        for (byte in bytes) {
            val value = byte.toInt() and 0xff
            append(HEX[value ushr 4])
            append(HEX[value and 0x0f])
        }
    }

    private fun hexInt(value: Int): String {
        val raw = Integer.toHexString(value)
        return "0".repeat(8 - raw.length) + raw
    }

    private data class RequestedStyle(val weight: Int, val italic: Boolean)

    private data class GlyphVariationOverrides(
        val weight: Float?,
        val italic: Float?,
        val fakeBold: Boolean?,
        val fakeItalic: Boolean?,
    )

    private data class FontBinary(val digest: String, val bytes: ByteArray)

    private data class FontSourceKey(val sourceIdentifier: Int, val originalTtcIndex: Int)

    private data class AxisValue(val axis: String, val value: Double, val floatBits: Int)

    private data class AxisKey(val axis: String, val floatBits: Int)

    private data class ShapedFontKey(
        val sourceIdentifier: Int,
        val originalTtcIndex: Int,
        val weight: Int,
        val italic: Boolean,
        val fakeBold: Boolean,
        val fakeItalic: Boolean,
        val axes: List<AxisKey>,
    )

    private data class CapturedFont(
        val resource: CapturedResource,
        val updatedUniqueBinaryBytes: Long,
    )

    private data class CapturedResource(
        val id: String,
        val bytes: ByteArray,
        val ttcIndex: Int,
        val originalTtcIndex: Int,
        val weight: Int,
        val italic: Boolean,
        val fakeBold: Boolean,
        val fakeItalic: Boolean,
        val axes: List<AxisValue>,
        val label: String,
    ) {
        fun toMap(): Map<String, Any?> = linkedMapOf(
            "id" to id,
            "bytes" to bytes,
            "ttcIndex" to ttcIndex,
            "originalTtcIndex" to originalTtcIndex,
            "weight" to weight,
            "italic" to italic,
            "fakeBold" to fakeBold,
            "fakeItalic" to fakeItalic,
            "axes" to axes.map { mapOf("axis" to it.axis, "value" to it.value) },
            "label" to label,
        )
    }

    private const val HEX = "0123456789abcdef"
}
