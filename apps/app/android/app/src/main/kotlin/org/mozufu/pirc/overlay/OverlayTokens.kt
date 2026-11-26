package org.mozufu.pirc.overlay

/**
 * The colours of the quick-reply overlay, one set per theme. Each value is the token of
 * the same name in `docs/design/tokens.json`; OverlayTokensTest reads that file and checks
 * every value, so a token change fails the test until this file follows it.
 */
data class OverlayPalette(
    val surfaceLayer: Int,
    val surfaceSubtle: Int,
    val textPrimary: Int,
    val textSecondary: Int,
    val textMuted: Int,
    val textWarning: Int,
    val lineStrong: Int,
    val lineDefault: Int,
    val accentDefault: Int,
    val accentSoft: Int,
    val accentOn: Int,
    val actionPrimary: Int,
    val actionOnPrimary: Int,
    val statusDanger: Int,
) {
    /** Token name → value, as tokens.json names them. */
    fun byToken(): Map<String, Int> = mapOf(
        "surface.layer" to surfaceLayer,
        "surface.subtle" to surfaceSubtle,
        "text.primary" to textPrimary,
        "text.secondary" to textSecondary,
        "text.muted" to textMuted,
        "text.warning" to textWarning,
        "line.strong" to lineStrong,
        "line.default" to lineDefault,
        "accent.default" to accentDefault,
        "accent.soft" to accentSoft,
        "accent.on" to accentOn,
        "action.primary" to actionPrimary,
        "action.onPrimary" to actionOnPrimary,
        "status.danger" to statusDanger,
    )
}

/** A type style of tokens.json: size and line height in sp, and the weight. */
data class OverlayType(val size: Float, val lineHeight: Float, val weight: Int)

object OverlayTokens {
    val light = OverlayPalette(
        surfaceLayer = 0xFFFFFFFF.toInt(),
        surfaceSubtle = 0xFFF1F3F5.toInt(),
        textPrimary = 0xFF0F1115.toInt(),
        textSecondary = 0xFF61666B.toInt(),
        textMuted = 0xFF6E7278.toInt(),
        textWarning = 0xFF7D4F1B.toInt(),
        // rgba(0,0,0,0.16)
        lineStrong = 0x29000000,
        // rgba(0,0,0,0.12)
        lineDefault = 0x1F000000,
        accentDefault = 0xFF4B6BA6.toInt(),
        accentSoft = 0xFFEEF2F9.toInt(),
        accentOn = 0xFFFFFFFF.toInt(),
        actionPrimary = 0xFF0F1115.toInt(),
        actionOnPrimary = 0xFFFFFFFF.toInt(),
        statusDanger = 0xFFC0453D.toInt(),
    )

    val dark = OverlayPalette(
        surfaceLayer = 0xFF232324.toInt(),
        surfaceSubtle = 0xFF2C2C2E.toInt(),
        textPrimary = 0xFFF9FAFB.toInt(),
        textSecondary = 0xFFC8CCD2.toInt(),
        textMuted = 0xFF969AA0.toInt(),
        textWarning = 0xFFE7B369.toInt(),
        // rgba(255,255,255,0.20)
        lineStrong = 0x33FFFFFF,
        // rgba(255,255,255,0.12)
        lineDefault = 0x1FFFFFFF,
        accentDefault = 0xFF88ABEA.toInt(),
        // rgba(136,171,234,0.14)
        accentSoft = 0x2488ABEA,
        accentOn = 0xFF10182A.toInt(),
        actionPrimary = 0xFFF9FAFB.toInt(),
        actionOnPrimary = 0xFF151517.toInt(),
        statusDanger = 0xFFE2726B.toInt(),
    )

    fun palette(dark: Boolean) = if (dark) this.dark else light

    /** typography: title.card, row, button, secondary and caption. */
    val titleCard = OverlayType(17f, 24f, 600)
    val row = OverlayType(15f, 22f, 400)
    val button = OverlayType(15f, 20f, 500)
    val secondary = OverlayType(13f, 18f, 400)
    val caption = OverlayType(12.5f, 18f, 400)

    /** radius: the sheet (panel), choices (md), the app mark (sm); buttons are pills. */
    const val RADIUS_PANEL = 28
    const val RADIUS_MD = 12
    const val RADIUS_SM = 8

    /** spacing: gutter.phone, stack.sm, stack.md, stack.lg, stack.xl. */
    const val GUTTER = 16
    const val STACK_SM = 8
    const val STACK_MD = 12
    const val STACK_LG = 16
    const val STACK_XL = 24

    /** size: touchTarget.preferred, icon.bar. */
    const val TOUCH_TARGET = 48
    const val ICON_BAR = 22
}
