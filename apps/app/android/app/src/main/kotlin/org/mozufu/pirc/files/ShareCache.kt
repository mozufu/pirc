package org.mozufu.pirc.files

import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong

/** The limit of one shared file: a 30-minute browser recording, as in the media channel. */
const val MAX_SHARE_BYTES = 1024L * 1024 * 1024

/** The limit of one part of a shared file. */
const val MAX_SHARE_PART_BYTES = 32 * 1024 * 1024

/**
 * The files the app hands to other apps, in `cacheDir/share/` (the only folder the
 * FileProvider serves). Dart writes a file in parts; [finish] gives it its clean name.
 * A shared file stays for [ttlMillis], because the receiving app reads it after the
 * share sheet closes; older files and unfinished uploads are removed by [prune].
 */
class ShareCache(
    cacheDir: File,
    private val ttlMillis: Long = TTL_MILLIS,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    val root = File(cacheDir, DIR)

    private class Upload(val dir: File, var size: Long)

    private val uploads = mutableMapOf<Long, Upload>()
    private val sequence = AtomicLong(0)

    /** Appends [bytes] to [share], or starts a new share; returns its ID. */
    @Synchronized
    fun append(share: Long?, bytes: ByteArray): Long {
        require(bytes.isNotEmpty()) { "bytes is required" }
        require(bytes.size <= MAX_SHARE_PART_BYTES) { "A part exceeds 32 MiB" }
        val id = share ?: run {
            prune()
            val dir = File(root, UUID.randomUUID().toString())
            check(dir.mkdirs()) { "Could not create the share folder" }
            sequence.incrementAndGet().also { uploads[it] = Upload(dir, 0) }
        }
        val upload = uploads[id] ?: throw IllegalArgumentException("Unknown share")
        if (upload.size + bytes.size > MAX_SHARE_BYTES) {
            discard(id)
            throw IllegalArgumentException("The file exceeds 1 GiB")
        }
        FileOutputStream(File(upload.dir, DATA), true).use { it.write(bytes) }
        upload.size += bytes.size
        return id
    }

    /** The finished file of [share], named [name] after cleaning; the upload ends. */
    @Synchronized
    fun finish(share: Long, name: String?): File {
        val upload = uploads.remove(share) ?: throw IllegalArgumentException("Unknown share")
        val target = File(upload.dir, cleanFileName(name, FALLBACK_NAME))
        // A clean name has no separator; check anyway that the file stays in its folder.
        if (target.canonicalFile.parentFile != upload.dir.canonicalFile ||
            !File(upload.dir, DATA).renameTo(target)
        ) {
            upload.dir.deleteRecursively()
            throw IllegalStateException("Could not name the shared file")
        }
        upload.dir.setLastModified(clock())
        return target
    }

    @Synchronized
    fun discard(share: Long) {
        uploads.remove(share)?.dir?.deleteRecursively()
    }

    /** Drops every unfinished upload (the engine is going away), then old shares. */
    @Synchronized
    fun discardUploads() {
        uploads.values.forEach { it.dir.deleteRecursively() }
        uploads.clear()
        prune()
    }

    /** Removes shared files older than the time to live, and anything else left in the folder. */
    @Synchronized
    fun prune() {
        val open = uploads.values.map { it.dir.canonicalFile }.toSet()
        val now = clock()
        root.listFiles()?.forEach { entry ->
            if (entry.canonicalFile in open) return@forEach
            if (!entry.isDirectory || now - entry.lastModified() >= ttlMillis || now < entry.lastModified() - ttlMillis) {
                entry.deleteRecursively()
            }
        }
    }

    companion object {
        /** The folder name; `res/xml/files_paths.xml` serves only this folder. */
        const val DIR = "share"
        const val TTL_MILLIS = 60 * 60 * 1000L
        private const val DATA = ".part"
        private const val FALLBACK_NAME = "file"
    }
}
