package org.mozufu.pirc.media

import android.view.Surface
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mozufu.pirc.Answer
import org.mozufu.pirc.call
import org.mozufu.pirc.direct
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class MediaChannelTest {
    private class FakeTexture(override val id: Long) : MediaTexture {
        override val surface: Surface? = null
        var size = 0 to 0
        var attached: MediaTexture.Callback? = null
        var released = false

        override fun setSize(width: Int, height: Int) {
            size = width to height
        }

        override fun setCallback(callback: MediaTexture.Callback?) {
            attached = callback
        }

        override fun release() {
            released = true
        }
    }

    private class FakePlayback : MediaPlayback {
        override var videoWidth = 640
        override var videoHeight = 360
        override var duration = 10_000
        override var currentPosition = 0
        override var isPlaying = false
        var path: String? = null
        var bytes: ByteArray? = null
        var listener: MediaPlayback.Listener? = null
        var level = -1f
        var loops = false
        var appliedSpeed = 1f
        val seeks = mutableListOf<Long>()
        var released = false

        override fun prepare(path: String, looping: Boolean, volume: Float, listener: MediaPlayback.Listener) {
            this.path = path
            bytes = File(path).readBytes()
            loops = looping
            level = volume
            this.listener = listener
        }

        override fun setSurface(surface: Surface?) {}
        override fun start() {
            isPlaying = true
        }

        override fun pause() {
            isPlaying = false
        }

        override fun seekTo(position: Long) {
            seeks += position
        }

        override fun setVolume(volume: Float) {
            level = volume
        }

        override fun setLooping(looping: Boolean) {
            loops = looping
        }

        override fun setSpeed(speed: Float) {
            appliedSpeed = speed
            // MediaPlayer starts playing when a speed is applied.
            isPlaying = true
        }

        override fun release() {
            released = true
        }
    }

    private val cache: File = Files.createTempDirectory("media-test").toFile()
    private val textures = mutableListOf<FakeTexture>()
    private val players = mutableListOf<FakePlayback>()
    private val timers = mutableListOf<Pair<Long, () -> Unit>>()
    private val saved = mutableListOf<Triple<ByteArray, String, String>>()
    private val media = MediaPlayers(
        cacheDir = cache,
        textures = { FakeTexture(textures.size + 7L).also { textures += it } },
        players = { FakePlayback().also { players += it } },
        downloads = { file, name, mime -> saved += Triple(file.readBytes(), name, mime); "$name (1)" },
        work = direct,
        main = direct,
        schedule = { delay, action ->
            val timer = delay to action
            timers += timer
            ({ timers.remove(timer) })
        },
        uploadLimit = 10,
        cacheLimit = 20,
    )
    private val channel = MediaChannel(media)
    private val webm = byteArrayOf(0x1a, 0x45, 0xdf.toByte(), 0xa3.toByte(), 1, 2, 3)

    private fun open(
        bytes: Any? = webm,
        mimeType: String? = "video/webm",
        kind: String? = "video",
        muted: Boolean? = null,
        loop: Boolean? = null,
    ): Answer = channel.call(
        "open",
        mapOf("bytes" to bytes, "mimeType" to mimeType, "kind" to kind, "muted" to muted, "loop" to loop),
    )

    private fun control(action: String, vararg args: Pair<String, Any?>) =
        channel.call("control", mapOf("id" to 7, "action" to action) + args)

    @Suppress("UNCHECKED_CAST")
    private fun status(answer: Answer) = answer.value as Map<String, Any?>

    /** Opens a WebM video and lets the decoder finish preparing. */
    private fun ready(): Answer {
        val answer = open()
        assertFalse(answer.answered)
        players.single().listener!!.onPrepared()
        return answer
    }

    @Test fun opensWebmBytesIntoATexture() {
        assertEquals("media", channel.name)
        val answer = ready()
        val status = status(answer)
        assertEquals(7L, status["id"])
        assertEquals(640, status["width"])
        assertEquals(360, status["height"])
        assertEquals(10_000, status["duration"])
        assertEquals(false, status["playing"])
        assertEquals("video/webm", status["mimeType"])
        assertEquals(640 to 360, textures.single().size)
        // The decoder reads a private copy of the bytes, not a URL.
        assertArrayEquals(webm, players.single().bytes)
        assertTrue(players.single().path!!.startsWith(File(cache, MediaPlayers.CACHE_FOLDER).path))
        assertEquals(1f, players.single().level)
        // The prepare timeout is cancelled once the media is ready.
        assertTrue(timers.isEmpty())
    }

    @Test fun mutedAndLoopingAudio() {
        val answer = open(mimeType = "audio/ogg; codecs=opus", kind = "audio", muted = true, loop = true)
        players.single().listener!!.onPrepared()
        val status = status(answer)
        assertEquals(0f, players.single().level)
        assertTrue(players.single().loops)
        assertEquals(true, status["muted"])
        assertEquals(true, status["loop"])
        assertEquals("audio/ogg", status["mimeType"])
    }

    @Test fun refusesBadOpenArguments() {
        assertEquals("INVALID", open(bytes = null).errorCode)
        assertEquals("INVALID", open(bytes = ByteArray(0)).errorCode)
        assertEquals("INVALID", open(bytes = ByteArray(MAX_MEDIA_BYTES + 1)).errorCode)
        assertEquals("INVALID", open(bytes = "https://example.test/a.webm").errorCode)
        assertEquals("INVALID", open(mimeType = null).errorCode)
        assertEquals("INVALID", open(mimeType = "video/*").errorCode)
        assertEquals("INVALID", open(mimeType = "text/html").errorCode)
        assertEquals("INVALID", open(mimeType = "video/webm\r\nX: y").errorCode)
        assertEquals("INVALID", open(kind = "image").errorCode)
        assertTrue(players.isEmpty())
        assertTrue(channel.call("stream").notImplemented)
    }

    @Test fun aDecoderErrorOrTimeoutFailsTheOpenAndCleansUp() {
        val failed = open()
        players.single().listener!!.onError(1, -1010)
        assertEquals("MEDIA", failed.errorCode)
        assertTrue(players.single().released)
        assertTrue(textures.single().released)
        assertFalse(File(players.single().path!!).exists())

        val slow = open()
        val (delay, timeout) = timers.single()
        assertEquals(MediaPlayers.PREPARE_TIMEOUT_MS, delay)
        timeout()
        assertEquals("MEDIA", slow.errorCode)
        assertEquals(0, media.openCount)
    }

    @Test fun playPauseVolumeAndLoop() {
        ready()
        assertEquals(true, status(control("play"))["playing"])
        assertEquals(false, status(control("pause"))["playing"])
        val muted = status(control("volume", "volume" to 0))
        assertEquals(true, muted["muted"])
        assertEquals(0f, players.single().level)
        assertEquals(0.5, status(control("volume", "volume" to 0.5))["volume"])
        assertEquals(1f, players.single().apply { control("volume", "volume" to 3) }.level)
        assertEquals(true, status(control("loop", "loop" to true))["loop"])
        assertEquals("INVALID", control("volume").errorCode)
        assertEquals("INVALID", control("rewind").errorCode)
    }

    @Test fun aRateChangeKeepsAPausedPlayerPaused() {
        ready()
        val status = status(control("rate", "rate" to 1.5))
        assertEquals(1.5, status["rate"])
        assertEquals(false, status["playing"])
        assertEquals(1.5f, players.single().appliedSpeed)
        assertEquals("INVALID", control("rate", "rate" to 0).errorCode)
        assertEquals("INVALID", control("rate", "rate" to Double.NaN).errorCode)
        assertEquals("INVALID", control("rate").errorCode)
    }

    @Test fun seekAnswersAtTheNewestPosition() {
        ready()
        val first = control("seek", "position" to 2_000)
        val second = control("seek", "position" to 4_000)
        val third = control("seek", "position" to 99_000)
        val player = players.single()
        // One seek at a time; the second target is dropped for the newest.
        assertEquals(listOf(2_000L), player.seeks)
        player.currentPosition = 2_000
        player.listener!!.onSeekComplete()
        assertFalse(first.answered)
        assertEquals(listOf(2_000L, 10_000L), player.seeks)
        player.currentPosition = 10_000
        player.listener!!.onSeekComplete()
        for (answer in listOf(first, second, third)) assertEquals(10_000, status(answer)["position"])
        assertTrue(timers.isEmpty())
        assertEquals("INVALID", control("seek").errorCode)
    }

    @Test fun aSeekThatNeverEndsDropsThePlayer() {
        ready()
        val answer = control("seek", "position" to -5)
        assertEquals(listOf(0L), players.single().seeks)
        timers.single().second()
        assertEquals("MEDIA", answer.errorCode)
        assertEquals("CLOSED", control("status").errorCode)
        assertTrue(players.single().released)
    }

    @Test fun nothingPlaysInTheBackground() {
        ready()
        control("play")
        channel.background()
        assertFalse(players.single().isPlaying)
        assertEquals("BACKGROUND", control("play").errorCode)
        assertEquals(false, status(control("status"))["playing"])
        channel.foreground()
        assertEquals(true, status(control("play"))["playing"])
    }

    @Test fun beforePreparedTheControlsWait() {
        open()
        assertEquals("NOT_READY", control("play").errorCode)
    }

    @Test fun savesTheHeldBytesToDownloads() {
        ready()
        val answer = channel.call("save", mapOf("id" to 7, "name" to ".pirc/recordings/clip.webm"))
        assertEquals("clip.webm (1)", answer.value)
        val (bytes, name, mime) = saved.single()
        assertArrayEquals(webm, bytes)
        assertEquals("clip.webm", name)
        assertEquals("video/webm", mime)
        assertEquals("media", mediaFileName("../\u0000"))
        // C1 controls and format characters (here U+202E, a bidi override) are dropped.
        assertEquals("clipcod.webm", mediaFileName("clip\u202Ecod\u0085.webm"))
        assertEquals("ab.webm", mediaFileName("a\u200Bb\uDB40\uDC01.webm"))
        assertEquals("media", mediaFileName(null))
        assertEquals("CLOSED", channel.call("save", mapOf("id" to 8)).errorCode)
    }

    @Test fun closeReleasesEverything() {
        ready()
        val file = File(players.single().path!!)
        assertNull(channel.call("close", mapOf("id" to 7)).value)
        assertTrue(players.single().released)
        assertTrue(textures.single().released)
        assertNull(textures.single().attached)
        assertFalse(file.exists())
        assertEquals("CLOSED", control("play").errorCode)
        assertEquals("INVALID", channel.call("close").errorCode)
        // Closing twice is fine.
        assertTrue(channel.call("close", mapOf("id" to 7)).answered)
    }

    @Test fun aRecordingArrivesInPartsAndOpensFromTheUpload() {
        val first = channel.call("upload", mapOf("bytes" to webm.copyOfRange(0, 4)))
        val id = first.value as Long
        assertEquals(id, channel.call("upload", mapOf("upload" to id, "bytes" to webm.copyOfRange(4, 7))).value)
        val answer = channel.call(
            "open",
            mapOf("upload" to id, "mimeType" to "video/webm", "kind" to "video"),
        )
        players.single().listener!!.onPrepared()
        assertEquals("video/webm", status(answer)["mimeType"])
        assertArrayEquals(webm, players.single().bytes)
        // The upload was taken over by the player.
        assertEquals("CLOSED", channel.call("upload", mapOf("upload" to id, "bytes" to webm)).errorCode)
    }

    @Test fun uploadsHaveALimitAndCanBeDropped() {
        val id = channel.call("upload", mapOf("bytes" to webm)).value as Long
        // 7 + 7 bytes is over this test's limit of 10: the upload is dropped.
        assertEquals("INVALID", channel.call("upload", mapOf("upload" to id, "bytes" to webm)).errorCode)
        assertEquals("CLOSED", channel.call("open", mapOf("upload" to id, "mimeType" to "video/webm", "kind" to "video")).errorCode)
        val other = channel.call("upload", mapOf("bytes" to webm)).value as Long
        assertNull(channel.call("discard", mapOf("upload" to other)).value)
        assertEquals("CLOSED", channel.call("open", mapOf("upload" to other, "mimeType" to "video/webm", "kind" to "video")).errorCode)
        assertEquals("INVALID", channel.call("open", mapOf("upload" to other, "bytes" to webm, "mimeType" to "video/webm", "kind" to "video")).errorCode)
        assertEquals("INVALID", channel.call("upload", mapOf("bytes" to ByteArray(0))).errorCode)
        assertTrue(File(cache, MediaPlayers.CACHE_FOLDER).listFiles().orEmpty().isEmpty())
    }

    @Test fun theMediaCacheHasOneLimitForPlayersAndUploads() {
        ready()
        val upload = channel.call("upload", mapOf("bytes" to webm)).value as Long
        assertEquals(14L, media.cachedBytes)
        // 7 + 7 + 7 bytes is over this test's cache limit of 20.
        assertEquals("INVALID", open().errorCode)
        assertEquals("INVALID", channel.call("upload", mapOf("bytes" to webm)).errorCode)
        assertEquals("INVALID", channel.call("upload", mapOf("upload" to upload, "bytes" to byteArrayOf(1, 2, 3, 4, 5, 6, 7))).errorCode)
        // The failed part dropped its upload; closing frees the rest.
        assertEquals(7L, media.cachedBytes)
        channel.call("close", mapOf("id" to 7))
        assertEquals(0L, media.cachedBytes)
        assertTrue(open().let { !it.answered || it.errorCode == null })
    }

    @Test fun closeAllClosesPlayersAndUploadsButKeepsTheChannel() {
        ready()
        val upload = channel.call("upload", mapOf("bytes" to webm)).value as Long
        assertNull(channel.call("closeAll").value)
        assertTrue(players.single().released)
        assertEquals(0, media.openCount)
        assertEquals("CLOSED", channel.call("upload", mapOf("upload" to upload, "bytes" to webm)).errorCode)
        assertTrue(File(cache, MediaPlayers.CACHE_FOLDER).listFiles().orEmpty().isEmpty())
        // Unlike detach, new players still open.
        open()
        assertEquals(2, players.size)
    }

    @Test fun detachClosesOpenPlayersAndRefusesNewOnes() {
        ready()
        val pending = open()
        channel.detach()
        assertEquals("CLOSED", pending.errorCode)
        assertTrue(players.all { it.released })
        assertEquals(0, media.openCount)
        assertEquals("CLOSED", open().errorCode)
    }
}
