package org.mozufu.pirc.scripts

/**
 * `localStorage` and `sessionStorage` of one document.
 *
 * A message document has an opaque origin, so its storage belongs to that one document: it is
 * created when the document opens, kept only in memory, never shared with the Gateway or with
 * another message, and dropped when the document closes. Nothing is written to disk.
 */
class DocumentStorage {
    private val areas = mapOf("local" to LinkedHashMap<String, String>(), "session" to LinkedHashMap())

    /**
     * Applies [operations] in order and returns both areas afterwards. An operation is
     * `{area: local|session, op: set|remove|clear, key?, value?}`. A write that would pass the
     * quota fails as a whole: no operation of the list is kept.
     */
    @Synchronized
    fun apply(operations: List<Map<*, *>>): Map<String, Any?> {
        require(operations.size <= MAX_OPERATIONS) { "Too many storage operations" }
        val next = areas.mapValues { LinkedHashMap(it.value) }
        for (operation in operations) {
            val area = next[operation["area"]] ?: throw IllegalArgumentException("Unknown storage area")
            when (operation["op"]) {
                "set" -> {
                    val key = operation["key"] as? String ?: throw IllegalArgumentException("Storage key is required")
                    val value = operation["value"] as? String ?: throw IllegalArgumentException("Storage value is required")
                    area[key] = value
                    if (size(area) > QUOTA_CHARS) {
                        throw ScriptFailure("STORAGE_QUOTA", "The document storage quota (5 MiB) is full.")
                    }
                }
                "remove" -> area.remove(
                    operation["key"] as? String ?: throw IllegalArgumentException("Storage key is required"),
                )
                "clear" -> area.clear()
                else -> throw IllegalArgumentException("Unknown storage operation")
            }
        }
        for ((name, values) in next) {
            val area = areas.getValue(name)
            area.clear()
            area.putAll(values)
        }
        return snapshot()
    }

    @Synchronized
    fun snapshot(): Map<String, Any?> = areas.mapValues { LinkedHashMap(it.value) }

    @Synchronized
    fun clear() = areas.values.forEach { it.clear() }

    private fun size(area: Map<String, String>) = area.entries.sumOf { it.key.length.toLong() + it.value.length }

    companion object {
        const val MAX_OPERATIONS = 256
        /** Browsers allow about 5 MiB per area; counted in UTF-16 code units, as they do. */
        const val QUOTA_CHARS = 5L * 1024 * 1024 / 2
    }
}

/**
 * `document.cookie` of one document.
 *
 * A message document has no URL and an opaque origin: it gets no Gateway cookie and no cookie
 * of another document, and its own cookies are never sent with a request (resource fetches go
 * out without any cookie). They live in memory for as long as the document is open, so a
 * script that keeps state in a cookie still works.
 */
class DocumentCookies(private val now: () -> Long = System::currentTimeMillis) {
    private data class Cookie(val value: String, val expires: Long?)

    private val cookies = LinkedHashMap<String, Cookie>()

    /** Applies the `document.cookie = line` assignments in [writes] and returns `document.cookie`. */
    @Synchronized
    fun write(writes: List<String>): String {
        require(writes.size <= MAX_WRITES) { "Too many cookie writes" }
        for (line in writes) assign(line)
        return read()
    }

    @Synchronized
    fun read(): String {
        val time = now()
        cookies.entries.removeAll { (_, cookie) -> cookie.expires != null && cookie.expires <= time }
        return cookies.entries.joinToString("; ") { (name, cookie) ->
            if (name.isEmpty()) cookie.value else "$name=${cookie.value}"
        }
    }

    @Synchronized
    fun clear() = cookies.clear()

    /** Follows RFC 6265 § 5.2 for the parts a document without a URL can use. */
    private fun assign(line: String) {
        if (line.length > MAX_COOKIE_CHARS || line.any { it.code < 0x20 && it != '\t' || it.code == 0x7f }) return
        val parts = line.split(';')
        val pair = parts.first()
        val equals = pair.indexOf('=')
        val name = if (equals < 0) "" else pair.substring(0, equals).trim()
        val value = (if (equals < 0) pair else pair.substring(equals + 1)).trim()
        if (name.isEmpty() && value.isEmpty()) return
        // Prefixed cookies need a secure origin; an opaque origin has none.
        if (name.startsWith("__Secure-", ignoreCase = true) || name.startsWith("__Host-", ignoreCase = true)) return
        var expires: Long? = null
        var maxAgeSeen = false
        for (attribute in parts.drop(1)) {
            val at = attribute.indexOf('=')
            val key = (if (at < 0) attribute else attribute.substring(0, at)).trim().lowercase()
            val raw = if (at < 0) "" else attribute.substring(at + 1).trim()
            when (key) {
                // A script can never set an HttpOnly cookie.
                "httponly" -> return
                "max-age" -> raw.toLongOrNull()?.let {
                    maxAgeSeen = true
                    expires = if (it <= 0) Long.MIN_VALUE else now() + it.coerceAtMost(MAX_AGE_SECONDS) * 1000
                }
                "expires" -> if (!maxAgeSeen) {
                    runCatching { java.time.ZonedDateTime.parse(raw, java.time.format.DateTimeFormatter.RFC_1123_DATE_TIME) }
                        .getOrNull()?.let { expires = it.toInstant().toEpochMilli() }
                }
            }
        }
        val until = expires
        if (until != null && until <= now()) {
            cookies.remove(name)
            return
        }
        if (name !in cookies && cookies.size >= MAX_COOKIES) return
        cookies[name] = Cookie(value, expires)
    }

    companion object {
        const val MAX_COOKIES = 50
        const val MAX_COOKIE_CHARS = 4096
        const val MAX_WRITES = 256
        const val MAX_AGE_SECONDS = 400L * 24 * 60 * 60
    }
}
