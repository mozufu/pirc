package org.mozufu.pirc.media

import android.content.ContentValues
import android.content.Context
import android.media.MediaPlayer
import android.provider.MediaStore
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.io.File

/** The Flutter texture a player draws into; Dart shows it with `Texture(textureId: id)`. */
interface MediaTexture {
    val id: Long
    val surface: Surface?
    fun setSize(width: Int, height: Int)
    fun setCallback(callback: Callback?)
    fun release()

    interface Callback {
        fun onAvailable()
        fun onCleanup()
    }
}

/** The decoder. [MediaPlayers] calls it on the main thread only. */
interface MediaPlayback {
    val videoWidth: Int
    val videoHeight: Int
    val duration: Int
    val currentPosition: Int
    val isPlaying: Boolean

    /** Starts preparing [path]; [listener] is called on the main thread. */
    fun prepare(path: String, looping: Boolean, volume: Float, listener: Listener)
    fun setSurface(surface: Surface?)
    fun start()
    fun pause()
    fun seekTo(position: Long)
    fun setVolume(volume: Float)
    fun setLooping(looping: Boolean)
    fun setSpeed(speed: Float)
    fun release()

    interface Listener {
        fun onPrepared()
        fun onError(what: Int, extra: Int)
        fun onSeekComplete()
    }
}

/** Saves a played file into the shared Downloads folder and returns its name there. */
fun interface MediaDownloads {
    fun save(file: File, name: String, mimeType: String): String
}

class FlutterMediaTexture(private val producer: TextureRegistry.SurfaceProducer) : MediaTexture {
    override val id: Long get() = producer.id()
    override val surface: Surface? get() = producer.surface

    override fun setSize(width: Int, height: Int) = producer.setSize(width, height)

    override fun setCallback(callback: MediaTexture.Callback?) {
        producer.setCallback(
            callback?.let {
                object : TextureRegistry.SurfaceProducer.Callback {
                    override fun onSurfaceAvailable() = it.onAvailable()
                    override fun onSurfaceCleanup() = it.onCleanup()
                }
            },
        )
    }

    override fun release() = producer.release()
}

/** [MediaPlayer] decodes WebM (VP8/VP9 with Vorbis/Opus), MP4, Ogg, MP3, AAC, FLAC and WAV. */
class AndroidMediaPlayback : MediaPlayback {
    private val player = MediaPlayer()

    override val videoWidth get() = player.videoWidth
    override val videoHeight get() = player.videoHeight
    override val duration get() = player.duration
    override val currentPosition get() = player.currentPosition
    override val isPlaying get() = player.isPlaying

    override fun prepare(path: String, looping: Boolean, volume: Float, listener: MediaPlayback.Listener) {
        player.setDataSource(path)
        player.isLooping = looping
        player.setVolume(volume, volume)
        player.setOnPreparedListener { listener.onPrepared() }
        player.setOnSeekCompleteListener { listener.onSeekComplete() }
        player.setOnErrorListener { _, what, extra ->
            listener.onError(what, extra)
            true
        }
        player.prepareAsync()
    }

    override fun setSurface(surface: Surface?) = player.setSurface(surface)
    override fun start() = player.start()
    override fun pause() = player.pause()
    override fun seekTo(position: Long) = player.seekTo(position, MediaPlayer.SEEK_CLOSEST)
    override fun setVolume(volume: Float) = player.setVolume(volume, volume)
    override fun setLooping(looping: Boolean) {
        player.isLooping = looping
    }

    override fun setSpeed(speed: Float) {
        player.playbackParams = player.playbackParams.allowDefaults().setSpeed(speed)
    }

    override fun release() {
        player.setOnPreparedListener(null)
        player.setOnSeekCompleteListener(null)
        player.setOnErrorListener(null)
        player.release()
    }
}

/** Downloads through MediaStore: no storage permission from Android 10 (the app's minimum). */
class MediaStoreDownloads(private val context: Context) : MediaDownloads {
    override fun save(file: File, name: String, mimeType: String): String {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        val uri = checkNotNull(resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)) {
            "Unable to create the download"
        }
        try {
            checkNotNull(resolver.openOutputStream(uri)).use { out -> file.inputStream().use { it.copyTo(out) } }
            resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        // MediaStore may rename the file ("clip (1).webm") when the name is taken.
        resolver.query(uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) return it.getString(0) ?: name
        }
        return name
    }
}
