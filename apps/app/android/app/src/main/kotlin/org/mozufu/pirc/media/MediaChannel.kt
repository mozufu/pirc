package org.mozufu.pirc.media

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.mozufu.pirc.PlatformFeature
import org.mozufu.pirc.mainThreadExecutor

/**
 * `org.mozufu.pirc/media`: plays media bytes that Dart already holds.
 * - `open {bytes | upload, mimeType, kind: audio|video, muted?, loop?}` → status;
 *   `bytes` holds at most 32 MiB (HTML media)
 * - `upload {upload?, bytes}` → the upload ID: appends a part (at most 32 MiB) of a
 *   larger file, such as a recording (at most 1 GiB in all); `discard {upload}` drops it
 * - `closeAll`: closes every player and drops every upload (unpairing)
 * - `control {id, action, position?, volume?, rate?, loop?}` → status; actions are
 *   `status`, `play`, `pause`, `seek` (ms), `volume` (0–1), `rate`, `loop`
 * - `save {id, name}` → the file name in Downloads
 * - `close {id}`
 *
 * A status is `{id, width, height, duration, position, playing, rate, volume, muted,
 * loop, mimeType}`; `id` is the Flutter texture ID. Errors: `INVALID`, `CLOSED`,
 * `NOT_READY`, `BACKGROUND` and `MEDIA`.
 */
class MediaChannel(
    private val players: MediaPlayers,
    private val work: ExecutorService? = null,
) : PlatformFeature {
    override val name = "media"

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val answer: MediaReply = { outcome -> outcome.fold(result::success, { fail(result, it) }) }
        try {
            when (call.method) {
                "open" -> players.open(
                    validateMediaOpenRequest(
                        bytes = call.argument<ByteArray>("bytes"),
                        upload = call.argument<Number>("upload")?.toLong(),
                        mimeType = call.argument<String>("mimeType"),
                        kind = call.argument<String>("kind"),
                        muted = call.argument<Boolean>("muted"),
                        loop = call.argument<Boolean>("loop"),
                    ),
                    answer,
                )
                "control" -> players.control(
                    id = id(call),
                    action = call.argument<String>("action") ?: throw IllegalArgumentException("action is required"),
                    position = call.argument<Number>("position")?.toLong(),
                    volume = call.argument<Number>("volume")?.toDouble(),
                    rate = call.argument<Number>("rate")?.toDouble(),
                    loop = call.argument<Boolean>("loop"),
                    reply = answer,
                )
                "save" -> players.save(id(call), call.argument<String>("name")) { outcome ->
                    outcome.fold(result::success) { fail(result, it) }
                }
                "upload" -> players.upload(
                    call.argument<Number>("upload")?.toLong(),
                    call.argument<ByteArray>("bytes") ?: throw IllegalArgumentException("bytes is required"),
                ) { outcome -> outcome.fold(result::success) { fail(result, it) } }
                "discard" -> {
                    players.discard(
                        call.argument<Number>("upload")?.toLong() ?: throw IllegalArgumentException("upload is required"),
                    )
                    result.success(null)
                }
                "closeAll" -> {
                    players.closeAll()
                    result.success(null)
                }
                "close" -> {
                    players.close(id(call))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: IllegalArgumentException) {
            fail(result, e)
        } catch (e: ClassCastException) {
            result.error("INVALID", "Wrong argument type", null)
        }
    }

    /** The app went to the background: no media plays there (as in the old app). */
    override fun background() = players.pauseAll()

    override fun foreground() = players.resume()

    override fun detach() {
        players.dispose()
        work?.shutdown()
    }

    private fun id(call: MethodCall): Long =
        call.argument<Number>("id")?.toLong() ?: throw IllegalArgumentException("id is required")

    private fun fail(result: MethodChannel.Result, error: Throwable) = when (error) {
        is MediaException -> result.error(error.code, error.message, null)
        is IllegalArgumentException -> result.error("INVALID", error.message, null)
        else -> result.error("MEDIA", error.javaClass.simpleName, null)
    }

    companion object {
        fun create(context: Context, textures: TextureRegistry): MediaChannel {
            val work = Executors.newSingleThreadExecutor()
            val handler = Handler(Looper.getMainLooper())
            val players = MediaPlayers(
                cacheDir = context.cacheDir,
                textures = { FlutterMediaTexture(textures.createSurfaceProducer()) },
                players = ::AndroidMediaPlayback,
                downloads = MediaStoreDownloads(context.applicationContext),
                work = work,
                main = mainThreadExecutor(),
                schedule = { delay, action ->
                    val runnable = Runnable(action)
                    handler.postDelayed(runnable, delay)
                    ({ handler.removeCallbacks(runnable) })
                },
            )
            return MediaChannel(players, work)
        }
    }
}
