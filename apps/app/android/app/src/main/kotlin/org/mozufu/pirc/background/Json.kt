package org.mozufu.pirc.background

import org.json.JSONObject

/**
 * The string at [key], or null when it is missing, JSON `null` or empty. `optString`
 * turns a JSON `null` into the text "null", so optional strings are read with this.
 */
fun JSONObject.text(key: String): String? {
    if (isNull(key)) return null
    val value = opt(key)
    return if (value is String) value.takeIf { it.isNotEmpty() } else value?.toString()?.takeIf { it.isNotEmpty() }
}

/** The number at [key], or null when it is missing or not a number. */
fun JSONObject.long(key: String): Long? = if (isNull(key)) null else (opt(key) as? Number)?.toLong()
