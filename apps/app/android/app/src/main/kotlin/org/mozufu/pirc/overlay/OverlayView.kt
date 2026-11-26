package org.mozufu.pirc.overlay

import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.LayerDrawable
import android.text.TextUtils
import android.text.format.DateFormat
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import java.util.Date
import org.mozufu.pirc.R

/** What the overlay's buttons do; [OverlayController] and the window answer them. */
interface OverlayActions {
    fun select(choiceId: String)

    fun send()

    fun decide(action: RunAction)

    fun retry()

    /** The top right: the full conversation (or the schedule) in the app. */
    fun open()

    /** The top right ×, "Later" and "OK": closes without answering. */
    fun close()
}

/**
 * Draws the overlay's bottom sheet (C § 6.4, screenshots 13–15 and 28) from an
 * [OverlayState], in the token colours and type of [OverlayTokens]. Every render builds
 * the sheet again; nothing in it holds state. Buttons that act carry a tag
 * (`overlay:send`, `overlay:choice:<id>`, …) for tests.
 */
class OverlayView(context: Context, private val actions: OverlayActions) {
    /** Strings, sizes and density come from here; [updateContext] swaps it on a configuration change. */
    private var ctx: Context = context
    private val density get() = ctx.resources.displayMetrics.density

    /** The expiry line of a ready question, which [refreshExpiry] keeps up to date. */
    private var expiryLine: TextView? = null

    /** Sees every touch of the window first. */
    var onTouch: ((MotionEvent) -> Unit)? = null

    /**
     * The whole window, exactly the sheet: the window has no transparent margin that
     * would take touches meant for the app below. Touches that arrive while another
     * window covers this one are dropped (`filterTouchesWhenObscured`), so an app drawn
     * over the sheet cannot trick a tap onto Send, Run now or a choice.
     */
    val root: FrameLayout = object : FrameLayout(ctx) {
        override fun dispatchTouchEvent(event: MotionEvent): Boolean {
            onTouch?.invoke(event)
            return super.dispatchTouchEvent(event)
        }
    }
    private val scroll = object : ScrollView(ctx) {
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            val max = (ctx.resources.displayMetrics.heightPixels * MAX_HEIGHT).toInt()
            super.onMeasure(widthMeasureSpec, MeasureSpec.makeMeasureSpec(max, MeasureSpec.AT_MOST))
        }
    }
    private val sheet = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
    private var palette = OverlayTokens.light

    init {
        scroll.addView(sheet)
        scroll.isVerticalScrollBarEnabled = false
        scroll.clipToOutline = true
        for (view in listOf(root, scroll, sheet)) view.filterTouchesWhenObscured = true
        root.addView(scroll, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        sheet.setPadding(dp(OverlayTokens.GUTTER), dp(OverlayTokens.STACK_MD), dp(OverlayTokens.GUTTER), dp(OverlayTokens.STACK_LG))
    }

    /** A new configuration (rotation, language, density): the next render uses it. */
    fun updateContext(context: Context) {
        ctx = context
    }

    /** Only the "Expires in N min" line of a ready question; the rest of the sheet stays. */
    fun refreshExpiry(state: OverlayState) {
        val at = (state as? OverlayState.Question)?.expiresAt ?: return
        expiryLine?.text = expiryText(at)
    }

    private fun expiryText(at: Long): String {
        val minutes = ((at - System.currentTimeMillis()) / 60_000).toInt()
        return if (minutes < 1) string(R.string.overlay_expires_soon) else string(R.string.overlay_expires_in, minutes)
    }

    fun render(state: OverlayState, dark: Boolean = isDark(ctx)) {
        expiryLine = null
        palette = OverlayTokens.palette(dark)
        // A window cannot draw its shadow outside itself, so a hairline separates the
        // sheet from the app below instead.
        scroll.background = rounded(palette.surfaceLayer, OverlayTokens.RADIUS_PANEL).apply {
            setStroke(dp(1), palette.lineDefault)
        }
        sheet.removeAllViews()
        when (state) {
            is OverlayState.Checking -> checking(state)
            is OverlayState.Question -> question(state)
            is OverlayState.Run -> run(state)
            is OverlayState.Sent -> sent(state)
            is OverlayState.AnsweredElsewhere -> answered(state)
            is OverlayState.Expired -> {
                header(state.sessionName)
                state.title?.let { title(it) }
                status(string(R.string.overlay_expired))
                buttons(primary = Button("overlay:ok", string(R.string.overlay_ok)) { actions.close() })
            }
            is OverlayState.Offline -> {
                header(null, run = state.run)
                status(string(R.string.overlay_offline))
                buttons(
                    secondary = Button("overlay:open-conversation", openLabel(state.run)) { actions.open() },
                    primary = Button("overlay:retry", string(R.string.overlay_retry)) { actions.retry() },
                )
                footer(null)
            }
            is OverlayState.NoControl -> {
                header(null)
                status(string(R.string.overlay_no_control, state.holder ?: string(R.string.notification_another_device)))
                buttons(primary = Button("overlay:open-conversation", openLabel(false)) { actions.open() })
                footer(null)
            }
            is OverlayState.NotSure -> {
                header(null, run = state.run)
                status(string(if (state.run) R.string.overlay_not_sure_run else R.string.overlay_not_sure), warning = true)
                buttons(primary = Button("overlay:open-conversation", openLabel(state.run)) { actions.open() })
                footer(null)
            }
            is OverlayState.RunSettled -> {
                header(null, run = true)
                status(
                    string(
                        when (state.state) {
                            "running" -> R.string.overlay_run_running
                            "completed" -> R.string.overlay_run_completed
                            "dismissed", "skipped" -> R.string.overlay_run_skipped_already
                            "failed" -> R.string.overlay_run_failed
                            else -> R.string.overlay_run_gone
                        },
                    ),
                )
                buttons(primary = Button("overlay:ok", string(R.string.overlay_ok)) { actions.close() })
            }
            OverlayState.Closing -> Unit
        }
    }

    private fun checking(state: OverlayState.Checking) {
        header(null, run = state.run)
        if (state.run) contextLine(string(R.string.overlay_missed_run), warning = false)
        progress(string(R.string.overlay_checking))
        if (state.run) {
            buttons(
                secondary = Button("overlay:skip", string(R.string.overlay_skip), enabled = false) {},
                primary = Button("overlay:run", string(R.string.overlay_run_now), enabled = false) {},
            )
        } else {
            buttons(
                secondary = Button("overlay:later", string(R.string.overlay_later), enabled = false) {},
                primary = Button("overlay:send", string(R.string.overlay_send), enabled = false) {},
            )
        }
        footer(null)
    }

    private fun question(state: OverlayState.Question) {
        header(state.sessionName)
        state.expiresAt?.let { at -> expiryLine = contextLine(expiryText(at), warning = true) }
        title(state.title)
        state.message?.let { body(it) }
        if (state.choices.isEmpty()) {
            status(string(R.string.overlay_open_to_answer))
            buttons(
                secondary = Button("overlay:later", string(R.string.overlay_later)) { actions.close() },
                primary = Button("overlay:open-conversation", openLabel(false)) { actions.open() },
            )
        } else {
            val list = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
            for (choice in state.choices) list.addView(option(choice, state.selected == choice.id, enabled = !state.sending))
            sheet.addView(list, block(top = OverlayTokens.STACK_MD))
            val control = state.control
            if (state.confirmTakeover && control is OverlayControl.Other) {
                status(string(R.string.overlay_recent_holder, holderName(control)), warning = true)
            }
            if (state.sending) progress(string(R.string.overlay_sending))
            val label = if (state.confirmTakeover) R.string.overlay_take_control_and_send else R.string.overlay_send
            buttons(
                secondary = Button("overlay:later", string(R.string.overlay_later), enabled = !state.sending) { actions.close() },
                primary = Button("overlay:send", string(label), enabled = state.canSend) { actions.send() },
            )
        }
        footer(state.control)
    }

    private fun run(state: OverlayState.Run) {
        header(null, run = true)
        val ago = state.dueAt?.let { relative(it) }
        contextLine(listOfNotNull(string(R.string.overlay_missed_run), ago).joinToString(SEPARATOR), warning = false)
        title(state.title?.let { string(R.string.overlay_run_question, it) } ?: string(R.string.overlay_run_question_untitled))
        if (state.sending != null) progress(string(R.string.overlay_checking))
        val planned = state.dueAt?.let { string(R.string.overlay_planned, DateFormat.getTimeFormat(ctx).format(Date(it))) }
        listOfNotNull(planned, state.reason).joinToString(SEPARATOR).takeIf { it.isNotEmpty() }?.let { body(it) }
        val idle = state.sending == null
        buttons(
            secondary = Button("overlay:skip", string(R.string.overlay_skip), enabled = idle) { actions.decide(RunAction.SKIP) },
            primary = Button("overlay:run", string(R.string.overlay_run_now), enabled = idle) { actions.decide(RunAction.RUN) },
        )
        footer(null)
    }

    private fun sent(state: OverlayState.Sent) {
        header(null, run = state.action != null)
        status(
            string(
                when (state.action) {
                    null -> R.string.overlay_sent
                    RunAction.RUN -> R.string.overlay_run_started
                    RunAction.SKIP -> R.string.overlay_run_skipped
                },
            ),
            emphasis = true,
        )
    }

    private fun answered(state: OverlayState.AnsweredElsewhere) {
        header(state.sessionName)
        state.title?.let { title(it) }
        val text = if (state.deviceName != null && state.at != null) {
            string(R.string.overlay_answered_on, state.deviceName, DateFormat.getTimeFormat(ctx).format(Date(state.at)))
        } else {
            string(R.string.overlay_answered)
        }
        status(text)
        buttons(primary = Button("overlay:ok", string(R.string.overlay_ok)) { actions.close() })
    }

    // ---- parts ----------------------------------------------------------------------

    private fun header(sessionName: String?, run: Boolean = false) {
        val row = LinearLayout(ctx).apply { gravity = Gravity.CENTER_VERTICAL }
        val mark = TextView(ctx).apply {
            text = "π"
            gravity = Gravity.CENTER
            style(OverlayTokens.button, palette.accentOn)
            background = rounded(palette.accentDefault, OverlayTokens.RADIUS_SM)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        row.addView(mark, LinearLayout.LayoutParams(dp(26), dp(26)))
        val name = sessionName ?: if (run) string(R.string.overlay_schedule) else null
        val label = TextView(ctx).apply {
            text = if (name.isNullOrBlank()) string(R.string.notification_app_name) else string(R.string.overlay_header, name)
            style(OverlayTokens.secondary, palette.textMuted)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        row.addView(label, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = dp(OverlayTokens.STACK_MD) })
        row.addView(icon("overlay:open", R.drawable.overlay_open, string(R.string.overlay_open_full)) { actions.open() })
        row.addView(icon("overlay:close", R.drawable.overlay_close, string(R.string.overlay_close)) { actions.close() })
        sheet.addView(row, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(OverlayTokens.TOUCH_TARGET)).apply { marginEnd = -dp(OverlayTokens.STACK_MD) })
    }

    private fun icon(tag: String, drawable: Int, description: String, action: () -> Unit) = ImageView(ctx).apply {
        this.tag = tag
        filterTouchesWhenObscured = true
        setImageResource(drawable)
        imageTintList = ColorStateList.valueOf(palette.textPrimary)
        scaleType = ImageView.ScaleType.CENTER
        contentDescription = description
        isClickable = true
        isFocusable = true
        setOnClickListener { action() }
        layoutParams = LinearLayout.LayoutParams(dp(OverlayTokens.TOUCH_TARGET), dp(OverlayTokens.TOUCH_TARGET))
    }

    /** The line above the title: the expiry (warning colour) or the run's age. */
    private fun contextLine(text: String, warning: Boolean): TextView {
        val line = TextView(ctx).apply {
            this.text = text
            style(OverlayTokens.secondary, if (warning) palette.textWarning else palette.textMuted)
        }
        sheet.addView(line, block(top = OverlayTokens.STACK_SM))
        return line
    }

    private fun title(text: String) {
        sheet.addView(TextView(ctx).apply { this.text = text; style(OverlayTokens.titleCard, palette.textPrimary) }, block(top = OverlayTokens.STACK_SM))
    }

    private fun body(text: String) {
        sheet.addView(TextView(ctx).apply { this.text = text; style(OverlayTokens.row, palette.textSecondary) }, block(top = OverlayTokens.STACK_MD))
    }

    private fun status(text: String, warning: Boolean = false, emphasis: Boolean = false) {
        sheet.addView(
            TextView(ctx).apply {
                tag = "overlay:status"
                this.text = text
                style(
                    if (emphasis) OverlayTokens.titleCard else OverlayTokens.row,
                    if (warning) palette.textWarning else palette.textPrimary,
                )
            },
            block(top = OverlayTokens.STACK_LG),
        )
    }

    private fun progress(text: String) {
        val row = LinearLayout(ctx).apply { gravity = Gravity.CENTER_VERTICAL }
        row.addView(
            ProgressBar(ctx).apply {
                isIndeterminate = true
                indeterminateTintList = ColorStateList.valueOf(palette.textMuted)
            },
            LinearLayout.LayoutParams(dp(18), dp(18)),
        )
        row.addView(
            TextView(ctx).apply {
                tag = "overlay:progress"
                this.text = text
                style(OverlayTokens.row, palette.textMuted)
            },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginStart = dp(OverlayTokens.STACK_SM) },
        )
        sheet.addView(row, block(top = OverlayTokens.STACK_LG))
    }

    private fun option(choice: OverlayChoice, selected: Boolean, enabled: Boolean): View {
        val row = LinearLayout(ctx).apply {
            tag = "overlay:choice:${choice.id}"
            filterTouchesWhenObscured = true
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(OverlayTokens.TOUCH_TARGET)
            setPadding(dp(OverlayTokens.STACK_MD), dp(OverlayTokens.STACK_MD), dp(OverlayTokens.STACK_LG), dp(OverlayTokens.STACK_MD))
            background = GradientDrawable().apply {
                setColor(if (selected) palette.accentSoft else palette.surfaceSubtle)
                cornerRadius = dp(OverlayTokens.RADIUS_MD).toFloat()
                if (selected) setStroke(dp(1), palette.accentDefault)
            }
            isSelected = selected
            isClickable = enabled
            isEnabled = enabled
            contentDescription = choice.label
            setOnClickListener { actions.select(choice.id) }
        }
        row.addView(View(ctx).apply { background = radio(selected) }, LinearLayout.LayoutParams(dp(20), dp(20)))
        row.addView(
            TextView(ctx).apply {
                text = choice.label
                style(OverlayTokens.row, palette.textPrimary)
            },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = dp(OverlayTokens.STACK_MD) },
        )
        return row.also { it.layoutParams = block(top = OverlayTokens.STACK_SM) }
    }

    private fun radio(selected: Boolean) = if (selected) {
        LayerDrawable(
            arrayOf(
                GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(palette.accentDefault) },
                GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(palette.accentOn) },
            ),
        ).apply { setLayerInset(1, dp(6), dp(6), dp(6), dp(6)) }
    } else {
        GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setStroke((1.5f * density).toInt().coerceAtLeast(1), palette.lineStrong)
        }
    }

    private class Button(val tag: String, val label: String, val enabled: Boolean = true, val action: () -> Unit)

    /** One primary button, or a secondary and a primary of equal width (C 13–15). */
    private fun buttons(primary: Button, secondary: Button? = null) {
        val row = LinearLayout(ctx)
        if (secondary != null) {
            row.addView(button(secondary, primary = false), LinearLayout.LayoutParams(0, dp(44), 1f).apply { marginEnd = dp(OverlayTokens.STACK_SM) })
        }
        row.addView(button(primary, primary = true), LinearLayout.LayoutParams(0, dp(44), 1f))
        sheet.addView(row, block(top = OverlayTokens.STACK_LG))
    }

    private fun button(spec: Button, primary: Boolean) = TextView(ctx).apply {
        tag = spec.tag
        filterTouchesWhenObscured = true
        text = spec.label
        gravity = Gravity.CENTER
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
        style(OverlayTokens.button, if (primary) palette.actionOnPrimary else palette.textPrimary)
        background = rounded(if (primary) palette.actionPrimary else palette.surfaceSubtle, PILL)
        isEnabled = spec.enabled
        isClickable = spec.enabled
        isFocusable = spec.enabled
        alpha = if (spec.enabled) 1f else DISABLED_ALPHA
        if (spec.enabled) setOnClickListener { spec.action() }
    }

    private fun footer(control: OverlayControl?) {
        val parts = buildList {
            when (control) {
                OverlayControl.Mine -> add(string(R.string.overlay_control_mine))
                is OverlayControl.Other -> add(string(R.string.overlay_control_other, holderName(control)))
                null -> Unit
            }
            add(string(R.string.overlay_stays))
        }
        sheet.addView(
            TextView(ctx).apply {
                tag = "overlay:footer"
                text = parts.joinToString(SEPARATOR)
                gravity = Gravity.CENTER_HORIZONTAL
                style(OverlayTokens.caption, palette.textMuted)
            },
            block(top = OverlayTokens.STACK_MD),
        )
    }

    private fun holderName(control: OverlayControl.Other) = control.name ?: string(R.string.notification_another_device)

    private fun openLabel(run: Boolean) = string(if (run) R.string.overlay_open_schedule else R.string.overlay_open_conversation)

    private fun relative(at: Long): String {
        val minutes = ((System.currentTimeMillis() - at) / 60_000).toInt()
        return when {
            minutes < 1 -> string(R.string.overlay_just_now)
            minutes < 60 -> string(R.string.overlay_minutes_ago, minutes)
            else -> string(R.string.overlay_hours_ago, minutes / 60)
        }
    }

    // ---- helpers --------------------------------------------------------------------

    private fun TextView.style(type: OverlayType, color: Int) {
        setTextSize(TypedValue.COMPLEX_UNIT_SP, type.size)
        lineHeight = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, type.lineHeight, resources.displayMetrics).toInt()
        typeface = Typeface.create(Typeface.DEFAULT, type.weight, false)
        setTextColor(color)
        includeFontPadding = false
    }

    private fun rounded(color: Int, radius: Int) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = if (radius == PILL) 999f * density else radius * density
    }

    private fun block(top: Int) = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
        topMargin = dp(top)
    }

    private fun string(id: Int, vararg args: Any): String = ctx.getString(id, *args)

    private fun dp(value: Int) = (value * density).toInt()

    companion object {
        private const val PILL = -1
        private const val SEPARATOR = " · "
        private const val DISABLED_ALPHA = 0.45f
        private const val MAX_HEIGHT = 0.7

        fun isDark(context: Context) =
            context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    }
}
