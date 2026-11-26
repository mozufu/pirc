package org.mozufu.pirc.overlay

import java.io.File
import kotlin.math.roundToInt
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** The overlay's colours and type are the tokens of docs/design/tokens.json. */
@RunWith(RobolectricTestRunner::class)
class OverlayTokensTest {
    // Gradle runs unit tests in the module directory (apps/app/android/app).
    private val tokens = File("../../../../docs/design/tokens.json").also {
        assertTrue("${it.absolutePath} exists", it.isFile)
    }.let { JSONObject(it.readText()) }

    private fun argb(value: String): Int {
        if (value.startsWith("#")) {
            require(value.length == 7) { value }
            return (0xFF000000 or value.substring(1).toLong(16)).toInt()
        }
        val parts = value.substringAfter('(').substringBefore(')').split(',').map { it.trim() }
        require(value.startsWith("rgba(") && parts.size == 4) { value }
        val alpha = (parts[3].toDouble() * 255).roundToInt()
        return (alpha shl 24) or (parts[0].toInt() shl 16) or (parts[1].toInt() shl 8) or parts[2].toInt()
    }

    @Test fun lightAndDarkColoursMatchTheTokens() {
        for ((mode, palette) in listOf("light" to OverlayTokens.light, "dark" to OverlayTokens.dark)) {
            val colors = tokens.getJSONObject("color").getJSONObject(mode)
            for ((name, value) in palette.byToken()) {
                assertEquals("$mode $name", Integer.toHexString(argb(colors.getString(name))), Integer.toHexString(value))
            }
        }
    }

    @Test fun typeRadiusSpacingAndSizesMatchTheTokens() {
        val type = tokens.getJSONObject("typography")
        for ((name, style) in listOf(
            "title.card" to OverlayTokens.titleCard,
            "row" to OverlayTokens.row,
            "button" to OverlayTokens.button,
            "secondary" to OverlayTokens.secondary,
            "caption" to OverlayTokens.caption,
        )) {
            val token = type.getJSONObject(name)
            assertEquals(name, token.getDouble("size").toFloat(), style.size)
            assertEquals(name, token.getDouble("lineHeight").toFloat(), style.lineHeight)
            assertEquals(name, token.getInt("weight"), style.weight)
        }
        val radius = tokens.getJSONObject("radius")
        assertEquals(radius.getInt("panel"), OverlayTokens.RADIUS_PANEL)
        assertEquals(radius.getInt("md"), OverlayTokens.RADIUS_MD)
        assertEquals(radius.getInt("sm"), OverlayTokens.RADIUS_SM)
        val spacing = tokens.getJSONObject("spacing")
        assertEquals(spacing.getInt("gutter.phone"), OverlayTokens.GUTTER)
        assertEquals(spacing.getInt("stack.sm"), OverlayTokens.STACK_SM)
        assertEquals(spacing.getInt("stack.md"), OverlayTokens.STACK_MD)
        assertEquals(spacing.getInt("stack.lg"), OverlayTokens.STACK_LG)
        assertEquals(spacing.getInt("stack.xl"), OverlayTokens.STACK_XL)
        val size = tokens.getJSONObject("size")
        assertEquals(size.getInt("touchTarget.preferred"), OverlayTokens.TOUCH_TARGET)
        assertEquals(size.getInt("icon.bar"), OverlayTokens.ICON_BAR)
    }
}
