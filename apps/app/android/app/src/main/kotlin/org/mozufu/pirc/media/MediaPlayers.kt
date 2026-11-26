package org.mozufu.pirc.media

import java.io.File
import java.util.concurrent.Executor

/** A failure Dart can tell apart by [code]. */
class MediaException(val code: String, message: String) : Exception(message)

typealias MediaReply = (Result<Map<String, Any?>>) -> Unit

/**
 * Recording playback and HTML `<audio>`/`<video>`, decoded into Flutter textures.
 * Ported from the old app's `RecordingPlayer.kt` and `HtmlMediaPlayer.kt` without their
 * Gateway client: the bytes come from Dart, so this class makes no network request.
 *
 * Every public method runs on the main thread; [work] only writes and copies files.
 * Error codes: `CLOSED` (no such player), `NOT_READY`, `BACKGROUND` (play while the app
 * is in the background), `MEDIA` (the decoder failed or timed out).
 */
class MediaPlayers(
    private val cacheDir: File,
    private val textures: () -> MediaTexture,
    private val players: () -> MediaPlayback,
    private val downloads: MediaDownloads,
    private val work: Executor,
    private val main: Executor,
    /** Runs the action after the delay (ms) on the main thread; returns a cancel. */
    private val schedule: (Long, () -> Unit) -> () -> Unit,
    private val uploadLimit: Long = MAX_UPLOAD_BYTES,
    /** The limit of all media files at once: uploads, players and files being written. */
    private val cacheLimit: Long = MAX_UPLOAD_BYTES,
) {
    private class Entry(
        val texture: MediaTexture,
        val player: MediaPlayback,
        val file: File,
        val size: Long,
        val mimeType: String,
        var volume: Float,
        var muted: Boolean,
        var loop: Boolean,
    ) {
        var ready = false
        var released = false
        var failed = false
        var rate = 1f
        var opening: MediaReply? = null
        var cancelPrepare: () -> Unit = {}
        var activeSeek: Long? = null
        var queuedSeek: Long? = null
        val seekReplies = mutableListOf<MediaReply>()
        var cancelSeek: () -> Unit = {}
    }

    /** A file Dart is writing in parts; [open] takes it over. */
    private class Upload(val file: File, var size: Long = 0)

    private val entries = mutableMapOf<Long, Entry>()
    private val uploads = mutableMapOf<Long, Upload>()
    private var nextUpload = 1L
    private var generation = 0L
    private var foreground = true
    private var disposed = false

    val openCount: Int get() = entries.size

    /** Bytes of opens whose file is being written. */
    private var pendingBytes = 0L

    /** What the media cache folder holds, or is about to. */
    val cachedBytes: Long
        get() = uploads.values.sumOf { it.size } + entries.values.sumOf { it.size } + pendingBytes

    private fun checkRoom(more: Long) =
        require(cachedBytes + more <= cacheLimit) { "The media cache is full" }

    init {
        // Files of a previous process that ended without closing its players.
        work.execute { File(cacheDir, CACHE_FOLDER).listFiles()?.forEach { it.delete() } }
    }

    /**
     * Appends [bytes] to upload [id], or to a new upload when [id] is null, and answers
     * the upload's ID. An upload over [uploadLimit] (1 GiB) is dropped.
     */
    fun upload(id: Long?, bytes: ByteArray, reply: (Result<Long>) -> Unit) {
        if (disposed) return reply(closed())
        require(bytes.isNotEmpty() && bytes.size <= MAX_MEDIA_BYTES) { "An upload part holds 1 byte to 32 MiB" }
        val uploadId = id ?: nextUpload++
        val upload = if (id == null) {
            Upload(File(File(cacheDir, CACHE_FOLDER), "upload-$uploadId-${System.nanoTime()}.bin")).also {
                uploads[uploadId] = it
            }
        } else {
            uploads[id] ?: return reply(closed())
        }
        if (upload.size + bytes.size > uploadLimit || cachedBytes + bytes.size > cacheLimit) {
            discard(uploadId)
            throw IllegalArgumentException("The upload exceeds its limit or the media cache is full")
        }
        upload.size += bytes.size
        val data = bytes.copyOf()
        work.execute {
            val written = runCatching {
                val directory = upload.file.parentFile!!
                check(directory.isDirectory || directory.mkdirs()) { "Unable to create the media cache" }
                java.io.FileOutputStream(upload.file, true).use { it.write(data) }
            }
            main.execute {
                when {
                    uploads[uploadId] !== upload -> reply(closed())
                    written.isFailure -> {
                        discard(uploadId)
                        reply(Result.failure(MediaException("MEDIA", "Unable to cache the media")))
                    }
                    else -> reply(Result.success(uploadId))
                }
            }
        }
    }

    /** Drops an upload that will not be opened. */
    fun discard(id: Long) {
        val upload = uploads.remove(id) ?: return
        work.execute { upload.file.delete() }
    }

    fun open(request: MediaOpenRequest, reply: MediaReply) {
        if (disposed) return reply(closed())
        val ticket = generation
        if (request.bytes != null) checkRoom(request.bytes.size.toLong())
        val upload = request.upload?.let { uploads.remove(it) ?: return reply(closed()) }
        // An upload's bytes are already counted; they move with it.
        val size = upload?.size ?: request.bytes!!.size.toLong()
        pendingBytes += size
        work.execute {
            val written = runCatching {
                if (upload != null) {
                    // Earlier parts were written in order on this thread.
                    check(upload.file.isFile && upload.file.length() == upload.size) { "The upload is incomplete" }
                    return@runCatching upload.file
                }
                val directory = File(cacheDir, CACHE_FOLDER)
                check(directory.isDirectory || directory.mkdirs()) { "Unable to create the media cache" }
                File.createTempFile("media-", ".bin", directory).also { file ->
                    try {
                        file.outputStream().use { it.write(checkNotNull(request.bytes)) }
                    } catch (e: Exception) {
                        file.delete()
                        throw e
                    }
                }
            }
            main.execute {
                pendingBytes -= size
                written.fold(
                    onSuccess = { file ->
                        if (disposed || ticket != generation) {
                            file.delete()
                            reply(closed())
                        } else {
                            start(file, size, request, reply)
                        }
                    },
                    onFailure = {
                        upload?.file?.delete()
                        reply(Result.failure(MediaException("MEDIA", "Unable to cache the media")))
                    },
                )
            }
        }
    }

    private fun start(file: File, size: Long, request: MediaOpenRequest, reply: MediaReply) {
        val texture: MediaTexture
        val player: MediaPlayback
        try {
            texture = textures()
            player = players()
        } catch (e: Exception) {
            file.delete()
            return reply(Result.failure(MediaException("MEDIA", "Unable to create the player")))
        }
        val volume = if (request.muted) 0f else 1f
        val entry = Entry(texture, player, file, size, mediaEssence(request.mimeType), volume, request.muted, request.loop)
        val id = texture.id
        entries[id] = entry
        entry.opening = reply
        texture.setSize(1, 1)
        texture.setCallback(object : MediaTexture.Callback {
            override fun onAvailable() {
                if (isCurrent(id, entry)) runCatching { player.setSurface(texture.surface) }
            }

            override fun onCleanup() {
                if (isCurrent(id, entry)) {
                    runCatching {
                        if (entry.ready && player.isPlaying) player.pause()
                        player.setSurface(null)
                    }
                }
            }
        })
        try {
            player.setSurface(texture.surface)
            player.prepare(file.absolutePath, request.loop, volume, object : MediaPlayback.Listener {
                override fun onPrepared() {
                    if (!isCurrent(id, entry) || entry.ready) return
                    entry.ready = true
                    texture.setSize(player.videoWidth.coerceAtLeast(1), player.videoHeight.coerceAtLeast(1))
                    finishOpen(entry, Result.success(status(id, entry)))
                }

                override fun onError(what: Int, extra: Int) {
                    if (!isCurrent(id, entry)) return
                    val failure = MediaException("MEDIA", "Unable to play this media ($what/$extra)")
                    if (!entry.ready) {
                        release(id, entry, Result.failure(failure))
                    } else {
                        entry.failed = true
                        answerSeeks(entry, Result.failure(failure))
                    }
                }

                override fun onSeekComplete() = seekComplete(id, entry)
            })
        } catch (e: Exception) {
            return release(id, entry, Result.failure(MediaException("MEDIA", "Unable to open this media")))
        }
        entry.cancelPrepare = schedule(PREPARE_TIMEOUT_MS) {
            if (isCurrent(id, entry) && !entry.ready) {
                release(id, entry, Result.failure(MediaException("MEDIA", "The media did not load in time")))
            }
        }
    }

    /**
     * `status`, `play`, `pause`, `seek` (with [position] in ms), `volume` (0–1),
     * `rate` (positive) or `loop`. Seek answers once the decoder has reached the
     * newest requested position.
     */
    fun control(
        id: Long,
        action: String,
        position: Long?,
        volume: Double?,
        rate: Double?,
        loop: Boolean?,
        reply: MediaReply,
    ) {
        val entry = entries[id] ?: return reply(closed())
        if (!entry.ready) return reply(Result.failure(MediaException("NOT_READY", "The media is not ready")))
        if (entry.failed) return reply(Result.failure(MediaException("MEDIA", "The media failed")))
        val player = entry.player
        try {
            when (action) {
                "status" -> Unit
                "play" -> {
                    if (!foreground) {
                        return reply(Result.failure(MediaException("BACKGROUND", "The app is in the background")))
                    }
                    if (!player.isPlaying) player.start()
                }
                "pause" -> if (player.isPlaying) player.pause()
                "seek" -> {
                    val target = requireNotNull(position) { "position is required" }
                    return seek(id, entry, target, reply)
                }
                "volume" -> {
                    val level = requireNotNull(volume) { "volume is required" }
                    require(level.isFinite()) { "volume must be finite" }
                    val normalized = level.coerceIn(0.0, 1.0).toFloat()
                    player.setVolume(normalized)
                    entry.volume = normalized
                    entry.muted = normalized == 0f
                }
                "rate" -> {
                    val speed = requireNotNull(rate) { "rate is required" }
                    require(speed.isFinite() && speed > 0.0 && speed <= MAX_RATE) { "rate must be positive" }
                    val wasPlaying = player.isPlaying
                    try {
                        player.setSpeed(speed.toFloat())
                        entry.rate = speed.toFloat()
                    } finally {
                        // MediaPlayer starts when nonzero playback parameters are applied;
                        // HTML media keeps a paused element paused when its speed changes.
                        if (!wasPlaying && runCatching { player.isPlaying }.getOrDefault(false)) {
                            runCatching { player.pause() }
                        }
                    }
                }
                "loop" -> {
                    val enabled = requireNotNull(loop) { "loop is required" }
                    player.setLooping(enabled)
                    entry.loop = enabled
                }
                else -> throw IllegalArgumentException("Unknown media action")
            }
        } catch (e: IllegalArgumentException) {
            return reply(Result.failure(e))
        } catch (e: Exception) {
            return reply(Result.failure(MediaException("MEDIA", "Unable to control the media")))
        }
        reply(Result.success(status(id, entry)))
    }

    /** Copies the file this player holds into Downloads; no new request is made. */
    fun save(id: Long, name: String?, reply: (Result<String>) -> Unit) {
        val entry = entries[id] ?: return reply(Result.failure(MediaException("CLOSED", "The media player is closed")))
        val fileName = mediaFileName(name)
        work.execute {
            val saved = runCatching {
                check(entry.file.isFile) { "The media file is gone" }
                downloads.save(entry.file, fileName, entry.mimeType)
            }
            main.execute {
                reply(saved.recoverCatching { throw MediaException("MEDIA", "Unable to save the media") })
            }
        }
    }

    fun close(id: Long) {
        val entry = entries[id] ?: return
        release(id, entry, closed())
    }

    /** The app went to the background: pause everything and refuse `play` until [resume]. */
    fun pauseAll() {
        foreground = false
        for (entry in entries.values) {
            if (entry.ready && !entry.failed) runCatching { if (entry.player.isPlaying) entry.player.pause() }
        }
    }

    fun resume() {
        foreground = true
    }

    /** Closes every player and drops every upload (the app unpairs, or the engine goes). */
    fun closeAll() {
        generation++
        entries.toList().forEach { (id, entry) -> release(id, entry, closed()) }
        uploads.keys.toList().forEach(::discard)
    }

    fun dispose() {
        disposed = true
        closeAll()
    }

    private fun seek(id: Long, entry: Entry, requested: Long, reply: MediaReply) {
        val target = requested.coerceIn(0L, entry.player.duration.toLong().coerceAtLeast(0L))
        entry.seekReplies += reply
        if (entry.activeSeek == null) {
            startSeek(id, entry, target)
        } else {
            // Only the newest target matters; every waiting caller gets its result.
            entry.queuedSeek = target
        }
    }

    private fun startSeek(id: Long, entry: Entry, target: Long) {
        entry.activeSeek = target
        entry.cancelSeek()
        entry.cancelSeek = schedule(SEEK_TIMEOUT_MS) {
            // MediaPlayer cannot cancel a seek; dropping the player is the only way out.
            if (isCurrent(id, entry) && entry.activeSeek != null) {
                answerSeeks(entry, Result.failure(MediaException("MEDIA", "The seek timed out")))
                release(id, entry, closed())
            }
        }
        try {
            entry.player.seekTo(target)
        } catch (e: Exception) {
            entry.activeSeek = null
            entry.queuedSeek = null
            entry.cancelSeek()
            answerSeeks(entry, Result.failure(MediaException("MEDIA", "Unable to seek")))
        }
    }

    private fun seekComplete(id: Long, entry: Entry) {
        if (!isCurrent(id, entry) || entry.activeSeek == null) return
        val next = entry.queuedSeek
        entry.queuedSeek = null
        if (next != null) return startSeek(id, entry, next)
        entry.activeSeek = null
        entry.cancelSeek()
        answerSeeks(entry, Result.success(status(id, entry)))
    }

    private fun answerSeeks(entry: Entry, result: Result<Map<String, Any?>>) {
        val replies = entry.seekReplies.toList()
        entry.seekReplies.clear()
        replies.forEach { it(result) }
    }

    private fun finishOpen(entry: Entry, result: Result<Map<String, Any?>>) {
        val reply = entry.opening ?: return
        entry.opening = null
        entry.cancelPrepare()
        reply(result)
    }

    private fun release(id: Long, entry: Entry, result: Result<Map<String, Any?>>) {
        if (entry.released) return
        entry.released = true
        if (entries[id] === entry) entries.remove(id)
        entry.cancelSeek()
        answerSeeks(entry, closed())
        finishOpen(entry, result)
        runCatching { entry.texture.setCallback(null) }
        runCatching { entry.player.release() }
        runCatching { entry.texture.release() }
        entry.file.delete()
    }

    private fun isCurrent(id: Long, entry: Entry) = !disposed && entries[id] === entry

    private fun status(id: Long, entry: Entry): Map<String, Any?> {
        val player = entry.player
        return mapOf(
            "id" to id,
            "width" to player.videoWidth,
            "height" to player.videoHeight,
            "duration" to player.duration.coerceAtLeast(0),
            "position" to player.currentPosition.coerceAtLeast(0),
            "playing" to player.isPlaying,
            "rate" to entry.rate.toDouble(),
            "volume" to entry.volume.toDouble(),
            "muted" to entry.muted,
            "loop" to entry.loop,
            "mimeType" to entry.mimeType,
        )
    }

    private fun <T> closed(): Result<T> = Result.failure(MediaException("CLOSED", "The media player is closed"))

    companion object {
        const val CACHE_FOLDER = "media"
        const val PREPARE_TIMEOUT_MS = 30_000L
        const val SEEK_TIMEOUT_MS = 15_000L
        const val MAX_RATE = 16.0
    }
}
