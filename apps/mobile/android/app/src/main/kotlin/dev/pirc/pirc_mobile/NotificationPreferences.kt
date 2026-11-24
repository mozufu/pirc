package dev.pirc.pirc_mobile

import android.content.Context
import java.util.Calendar

/** Preferences apply on this phone, including while Flutter is not running. */
class NotificationPreferences(context: Context) {
    private val prefs = context.getSharedPreferences("notification_preferences", Context.MODE_PRIVATE)
    private val defaults = mapOf("q" to true, "missed" to true, "deleg" to true, "mem" to false,
        "done" to false, "live" to true, "popup" to true, "rich" to true, "recall" to true, "quiet" to false)
    fun enabled(key: String) = prefs.getBoolean(key, defaults[key] ?: false)
    val lock get() = prefs.getString("lock", "hide")!!
    fun read(): Map<String, Any> = defaults.mapValues { enabled(it.key) } + mapOf(
        "lock" to lock, "start" to prefs.getInt("start", 23 * 60), "end" to prefs.getInt("end", 450),
        "muted" to prefs.getStringSet("muted", emptySet())!!.toList(), "appearance" to prefs.getString("appearance", "system")!!)
    fun save(values: Map<*, *>) {
        val edit = prefs.edit()
        for ((key, value) in values) when {
            key in defaults && value is Boolean -> edit.putBoolean(key as String, value)
            key in listOf("start", "end") && value is Number -> edit.putInt(key as String, value.toInt().coerceIn(0, 1439))
            key == "lock" && value in listOf("hide", "summary", "all") -> edit.putString("lock", value as String)
            key == "appearance" && value in listOf("system", "light", "dark") -> edit.putString("appearance", value as String)
            key == "muted" && value is List<*> -> edit.putStringSet("muted", value.filterIsInstance<String>().toSet())
        }
        check(edit.commit()) { "無法儲存設定" }
    }
    fun allows(category: String, workspace: String? = null, minute: Int = Calendar.getInstance().let { it.get(Calendar.HOUR_OF_DAY)*60+it.get(Calendar.MINUTE) }): Boolean {
        if (!enabled(category)) return false
        if (workspace != null && prefs.getStringSet("muted", emptySet())!!.contains(workspace)) return false
        if (!enabled("quiet") || category == "q") return true
        return !inQuietHours(minute, prefs.getInt("start",1380), prefs.getInt("end",450))
    }
}
internal fun inQuietHours(minute: Int, start: Int, end: Int): Boolean = when {
    start == end -> true
    start < end -> minute >= start && minute < end
    else -> minute >= start || minute < end
}
