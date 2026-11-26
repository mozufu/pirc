package org.mozufu.pirc.files

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.DragEvent
import android.view.View
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mozufu.pirc.call
import org.mozufu.pirc.direct
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class FilesChannelTest {
    private class FakeContent : ContentAccess {
        val files = mutableMapOf<Uri, Triple<String?, String?, ByteArray>>()
        val reportedSizes = mutableMapOf<Uri, Long>()
        val written = mutableMapOf<Uri, ByteArrayOutputStream>()
        val deleted = mutableListOf<Uri>()
        val opened = mutableListOf<Uri>()
        var failWrites = false
        var savedName: String? = null

        fun add(uri: String, name: String?, type: String?, bytes: ByteArray): Uri =
            Uri.parse(uri).also { files[it] = Triple(name, type, bytes) }

        override fun type(uri: Uri) = files[uri]?.second

        override fun describe(uri: Uri): Pair<String?, Long?> =
            if (uri in written) savedName to null else (files[uri]?.first to (reportedSizes[uri] ?: files[uri]?.third?.size?.toLong()))

        override fun open(uri: Uri): InputStream? {
            opened += uri
            return files[uri]?.let { ByteArrayInputStream(it.third) }
        }

        override fun write(uri: Uri): OutputStream {
            if (failWrites) {
                written[uri] = ByteArrayOutputStream()
                throw IOException("disk full")
            }
            return ByteArrayOutputStream().also { written[uri] = it }
        }

        override fun delete(uri: Uri) {
            deleted += uri
        }
    }

    private class FakeHost(val clip: ClipData? = null) : FilesHost {
        override val content = FakeContent()
        override val packageName = "org.mozufu.pirc"
        var startFailure: Exception? = null
        val forResult = mutableListOf<Pair<Intent, Int>>()
        val started = mutableListOf<Intent>()
        var refuse = setOf<String>()
        var listener: View.OnDragListener? = null
        var hasView = true

        override fun startForResult(intent: Intent, requestCode: Int) {
            if (intent.action in refuse) throw ActivityNotFoundException()
            startFailure?.let { throw it }
            forResult += intent to requestCode
        }

        override fun start(intent: Intent) {
            started += intent
        }

        override fun shareUri(file: File): Uri = Uri.parse("content://org.mozufu.pirc.files/share/${file.parentFile!!.name}/${file.name}")

        override fun primaryClip() = clip

        override fun clipHasImages() = clip?.description?.hasMimeType("image/*") == true

        override fun chooserTitle() = "Share"

        override fun listenForDrops(listener: View.OnDragListener?): Boolean {
            if (!hasView) return false
            this.listener = listener
            return true
        }

        override fun dropPermissions(event: DragEvent): (() -> Unit)? = null
    }

    private val cacheDir: File = Files.createTempDirectory("files").toFile()

    private fun channel(host: FakeHost, cache: ShareCache = ShareCache(cacheDir)) =
        FilesChannel(host, cache, work = direct, reply = direct)

    private fun resultIntent(vararg uris: Uri): Intent = Intent().apply {
        if (uris.size == 1) {
            data = uris[0]
        } else {
            clipData = ClipData.newRawUri(null, uris[0]).also { clip -> uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) } }
        }
    }

    // The save picker.

    @Test fun saveOpensTheCreateDocumentPickerAndWritesThePickedDocument() {
        val host = FakeHost()
        val files = channel(host)
        val bytes = byteArrayOf(1, 2, 3)
        val answer = files.call("save", mapOf("name" to "../re‮port.pdf", "mimeType" to "Application/PDF", "bytes" to bytes))
        assertFalse(answer.answered)
        val (intent, code) = host.forResult.single()
        assertEquals(Intent.ACTION_CREATE_DOCUMENT, intent.action)
        assertEquals(FilesChannel.SAVE_REQUEST, code)
        assertEquals("report.pdf", intent.getStringExtra(Intent.EXTRA_TITLE))
        assertEquals("application/pdf", intent.type)
        assertTrue(intent.hasCategory(Intent.CATEGORY_OPENABLE))

        val destination = Uri.parse("content://com.android.externalstorage.documents/document/primary%3Areport%20(1).pdf")
        host.content.savedName = "report (1).pdf"
        assertTrue(files.activityResult(code, Activity.RESULT_OK, Intent().setData(destination)))
        assertEquals("report (1).pdf", answer.value)
        assertArrayEquals(bytes, host.content.written.getValue(destination).toByteArray())
    }

    @Test fun aCancelledSaveAnswersNullAndWritesNothing() {
        val host = FakeHost()
        val files = channel(host)
        val answer = files.call("save", mapOf("name" to "a.txt", "mimeType" to "text/plain", "bytes" to byteArrayOf(1)))
        assertTrue(files.activityResult(FilesChannel.SAVE_REQUEST, Activity.RESULT_CANCELED, null))
        assertTrue(answer.answered)
        assertNull(answer.value)
        assertNull(answer.errorCode)
        assertTrue(host.content.written.isEmpty())
    }

    @Test fun aFailedWriteRemovesTheDocumentAndFails() {
        val host = FakeHost()
        host.content.failWrites = true
        val files = channel(host)
        val answer = files.call("save", mapOf("name" to "a.txt", "mimeType" to "text/plain", "bytes" to byteArrayOf(1)))
        val destination = Uri.parse("content://docs/document/a")
        files.activityResult(FilesChannel.SAVE_REQUEST, Activity.RESULT_OK, Intent().setData(destination))
        assertEquals("FILES", answer.errorCode)
        assertEquals(listOf(destination), host.content.deleted)
    }

    @Test fun aSecondPickerWhileOneIsOpenIsBusy() {
        val host = FakeHost()
        val files = channel(host)
        files.call("save", mapOf("name" to "a.txt", "mimeType" to "text/plain", "bytes" to byteArrayOf(1)))
        assertEquals("BUSY", files.call("pick").errorCode)
        assertEquals("BUSY", files.call("save", mapOf("name" to "b", "mimeType" to "text/plain", "bytes" to byteArrayOf(1))).errorCode)
        assertEquals(1, host.forResult.size)
    }

    @Test fun saveRefusesTooManyBytesAndAnotherFeaturesResult() {
        val host = FakeHost()
        val files = channel(host)
        val big = ByteArray(FilesChannel.MAX_SAVE_BYTES + 1)
        assertEquals("INVALID", files.call("save", mapOf("name" to "a", "mimeType" to "text/plain", "bytes" to big)).errorCode)
        assertEquals("INVALID", files.call("save", mapOf("name" to "a", "mimeType" to "text/plain")).errorCode)
        assertFalse(files.activityResult(1234, Activity.RESULT_OK, null))
        assertTrue(host.forResult.isEmpty())
    }

    @Test fun anUnknownMimeTypeSavesAsBytes() {
        val host = FakeHost()
        channel(host).call("save", mapOf("name" to "", "mimeType" to "*/*", "bytes" to byteArrayOf(1)))
        val intent = host.forResult.single().first
        assertEquals(DEFAULT_MIME_TYPE, intent.type)
        assertEquals("file", intent.getStringExtra(Intent.EXTRA_TITLE))
    }

    // The picker.

    @Test fun pickOpensTheDocumentPickerWithoutAPersistableGrant() {
        val host = FakeHost()
        val files = channel(host)
        files.call("pick", mapOf("multiple" to true, "mimeTypes" to listOf("image/png", "image/jpeg")))
        val (intent, code) = host.forResult.single()
        assertEquals(Intent.ACTION_OPEN_DOCUMENT, intent.action)
        assertEquals(FilesChannel.PICK_REQUEST, code)
        assertEquals("*/*", intent.type)
        assertArrayEquals(arrayOf("image/png", "image/jpeg"), intent.getStringArrayExtra(Intent.EXTRA_MIME_TYPES))
        assertTrue(intent.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false))
        assertEquals(0, intent.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        assertEquals(0, intent.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
    }

    @Test fun pickFallsBackToGetContentAndIsUnavailableWithoutAnyPicker() {
        val host = FakeHost()
        host.refuse = setOf(Intent.ACTION_OPEN_DOCUMENT)
        val files = channel(host)
        files.call("pick", mapOf("multiple" to false, "mimeTypes" to listOf("image/png")))
        val intent = host.forResult.single().first
        assertEquals(Intent.ACTION_GET_CONTENT, intent.action)
        assertEquals("image/png", intent.type)
        files.activityResult(FilesChannel.PICK_REQUEST, Activity.RESULT_CANCELED, null)

        host.refuse = setOf(Intent.ACTION_OPEN_DOCUMENT, Intent.ACTION_GET_CONTENT)
        assertEquals("UNAVAILABLE", files.call("pick").errorCode)
        // The failed open leaves no picker pending.
        host.refuse = emptySet()
        assertFalse(files.call("pick").answered)
    }

    @Test fun pickedFilesAreReadWithCleanNamesAndTheSizeLimit() {
        val host = FakeHost()
        val content = host.content
        val photo = content.add("content://media/1", "ph\u0000oto​.png", "image/png", byteArrayOf(9, 8))
        val big = content.add("content://media/2", "big.bin", "application/octet-stream", ByteArray(4))
        content.reportedSizes[big] = MAX_FILE_BYTES + 1L
        val lying = content.add("content://media/3", "lying.bin", null, ByteArray(MAX_FILE_BYTES + 1))
        content.reportedSizes[lying] = 10
        val private = Uri.parse("file:///data/data/org.mozufu.pirc/shared_prefs/x.xml")
        val files = channel(host)
        val answer = files.call("pick")
        files.activityResult(FilesChannel.PICK_REQUEST, Activity.RESULT_OK, resultIntent(photo, big, lying, private))

        @Suppress("UNCHECKED_CAST")
        val picked = answer.value as List<Map<String, Any>>
        assertEquals(4, picked.size)
        assertEquals("photo.png", picked[0]["name"])
        assertEquals("image/png", picked[0]["mimeType"])
        assertArrayEquals(byteArrayOf(9, 8), picked[0]["bytes"] as ByteArray)
        assertEquals("TOO_LARGE", picked[1]["error"])
        // The reported size refused it before any read.
        assertFalse(big in content.opened)
        assertEquals("TOO_LARGE", picked[2]["error"])
        assertEquals("READ", picked[3]["error"])
        assertFalse(private in content.opened)
    }

    @Test fun aPickReadsAtMostSixteenFilesAndSixtyFourMiBInAll() {
        val host = FakeHost()
        val uris = (1..17).map { host.content.add("content://media/n$it", "f$it.txt", "text/plain", byteArrayOf(1)) }
        val files = channel(host)
        val answer = files.call("pick")
        files.activityResult(FilesChannel.PICK_REQUEST, Activity.RESULT_OK, resultIntent(*uris.toTypedArray()))
        @Suppress("UNCHECKED_CAST")
        val picked = answer.value as List<Map<String, Any>>
        assertEquals(16, picked.count { it.containsKey("bytes") })
        assertEquals("TOO_MANY", picked.last()["error"])
        assertFalse(uris.last() in host.content.opened)

        // Six files of 10 MiB fit; the seventh passes 64 MiB in all.
        val big = (1..7).map { host.content.add("content://media/b$it", "b$it.bin", "x/y", ByteArray(10 * 1024 * 1024)) }
        val second = files.call("pick")
        files.activityResult(FilesChannel.PICK_REQUEST, Activity.RESULT_OK, resultIntent(*big.toTypedArray()))
        @Suppress("UNCHECKED_CAST")
        val reads = second.value as List<Map<String, Any>>
        assertEquals(6, reads.count { it.containsKey("bytes") })
        assertEquals("TOO_MANY", reads.last()["error"])
    }

    @Test fun theAppsOwnProvidersAreNeverReadBack() {
        val host = FakeHost()
        val own = host.content.add("content://org.mozufu.pirc.files/share/a/x.png", "x.png", "image/png", byteArrayOf(1))
        val plugin = host.content.add("content://org.mozufu.pirc.flutter.share_provider/x.png", "y.png", "image/png", byteArrayOf(1))
        val other = host.content.add("content://org.mozufu.pircs/x.png", "z.png", "image/png", byteArrayOf(1))
        val files = channel(host)
        val answer = files.call("pick")
        files.activityResult(FilesChannel.PICK_REQUEST, Activity.RESULT_OK, resultIntent(own, plugin, other))
        @Suppress("UNCHECKED_CAST")
        val picked = answer.value as List<Map<String, Any>>
        assertEquals(listOf("READ", "READ", null), picked.map { it["error"] })
        assertEquals(listOf(other), host.content.opened)
        assertEquals(emptyList<FileRead>(), readImages(host.content, listOf(own), host.packageName))
    }

    @Test fun aPickMayAskForLargerFilesUpTo32MiB() {
        val host = FakeHost()
        val photo = host.content.add("content://media/p", "p.jpg", "image/jpeg", ByteArray(20 * 1024 * 1024))
        val files = channel(host)
        val answer = files.call("pick", mapOf("maxBytes" to 32 * 1024 * 1024))
        files.activityResult(FilesChannel.PICK_REQUEST, Activity.RESULT_OK, resultIntent(photo))
        @Suppress("UNCHECKED_CAST")
        assertTrue((answer.value as List<Map<String, Any>>).single().containsKey("bytes"))
        assertEquals("INVALID", files.call("pick", mapOf("maxBytes" to 32 * 1024 * 1024 + 1)).errorCode)
        assertEquals("INVALID", files.call("pick", mapOf("maxBytes" to 0)).errorCode)
    }

    @Test fun aPickerThatFailsToStartLeavesNothingPending() {
        val host = FakeHost()
        host.startFailure = SecurityException("locked down")
        val files = channel(host)
        assertEquals("UNAVAILABLE", files.call("pick").errorCode)
        assertEquals("UNAVAILABLE", files.call("save", mapOf("name" to "a", "mimeType" to "text/plain", "bytes" to byteArrayOf(1))).errorCode)
        host.startFailure = null
        assertFalse(files.call("pick").answered)
    }

    @Test fun aSaveAnswerWithNothingPendingRemovesTheEmptyDocument() {
        val host = FakeHost()
        val files = channel(host)
        val orphan = Uri.parse("content://docs/document/empty")
        assertTrue(files.activityResult(FilesChannel.SAVE_REQUEST, Activity.RESULT_OK, Intent().setData(orphan)))
        assertEquals(listOf(orphan), host.content.deleted)
        assertTrue(files.activityResult(FilesChannel.SAVE_REQUEST, Activity.RESULT_CANCELED, null))
        assertEquals(1, host.content.deleted.size)
    }

    @Test fun aCancelledPickAnswersNull() {
        val host = FakeHost()
        val files = channel(host)
        val answer = files.call("pick")
        files.activityResult(FilesChannel.PICK_REQUEST, Activity.RESULT_CANCELED, null)
        assertTrue(answer.answered)
        assertNull(answer.value)
        val again = files.call("pick")
        files.activityResult(FilesChannel.PICK_REQUEST, Activity.RESULT_OK, Intent())
        assertNull(again.value)
    }

    @Test fun detachAnswersAnOpenPicker() {
        val host = FakeHost()
        val files = channel(host)
        val answer = files.call("pick")
        files.detach()
        assertTrue(answer.answered)
        assertNull(answer.value)
    }

    @Test fun pickedUrisMergeTheClipAndTheDataInOrderOnce() {
        val a = Uri.parse("content://p/a")
        val b = Uri.parse("content://p/b")
        val intent = resultIntent(a, b, a).setData(b)
        assertEquals(listOf(a, b), pickedUris(Activity.RESULT_OK, intent))
        assertEquals(listOf(a), pickedUris(Activity.RESULT_OK, Intent().setData(a)))
        assertEquals(emptyList<Uri>(), pickedUris(Activity.RESULT_OK, null))
        assertNull(pickedUris(Activity.RESULT_CANCELED, intent))
    }

    // The clipboard.

    @Test fun clipboardImagesReadsOnlyTheImagesOfTheClipboard() {
        val context: Context = RuntimeEnvironment.getApplication()
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val image = Uri.parse("content://gallery/7")
        val text = Uri.parse("content://notes/1")
        val clip = ClipData(ClipDescription("copied", arrayOf("image/png", "text/plain")), ClipData.Item(image))
        clip.addItem(ClipData.Item(text))
        clip.addItem(ClipData.Item("just text"))
        clipboard.setPrimaryClip(clip)

        val host = FakeHost(clipboard.primaryClip)
        host.content.add(image.toString(), "cat.png", "image/png", byteArrayOf(5))
        host.content.add(text.toString(), "note.txt", "text/plain", byteArrayOf(6))
        val files = channel(host)
        assertEquals(true, files.call("clipboardHasImages").value)

        @Suppress("UNCHECKED_CAST")
        val read = files.call("clipboardImages").value as List<Map<String, Any>>
        assertEquals(listOf("cat.png"), read.map { it["name"] })
        assertArrayEquals(byteArrayOf(5), read[0]["bytes"] as ByteArray)
        assertFalse(text in host.content.opened)
    }

    @Test fun aLargeClipboardImageIsRefusedAndAnEmptyClipboardHasNone() {
        val image = Uri.parse("content://gallery/8")
        val host = FakeHost(ClipData.newRawUri(null, image))
        host.content.add(image.toString(), "huge.png", "image/png", ByteArray(MAX_FILE_BYTES + 1))
        host.content.reportedSizes[image] = 1
        @Suppress("UNCHECKED_CAST")
        val read = channel(host).call("clipboardImages").value as List<Map<String, Any>>
        assertEquals("TOO_LARGE", read.single()["error"])

        val empty = channel(FakeHost())
        assertEquals(false, empty.call("clipboardHasImages").value)
        assertEquals(emptyList<Any>(), empty.call("clipboardImages").value)
    }

    // Share.

    @Test fun shareTextOpensTheChooser() {
        val host = FakeHost()
        val answer = channel(host).call("shareText", mapOf("text" to "hello", "subject" to "Result"))
        assertTrue(answer.answered)
        assertNull(answer.errorCode)
        val chooser = host.started.single()
        assertEquals(Intent.ACTION_CHOOSER, chooser.action)
        @Suppress("DEPRECATION")
        val send = chooser.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)!!
        assertEquals(Intent.ACTION_SEND, send.action)
        assertEquals("hello", send.getStringExtra(Intent.EXTRA_TEXT))
        assertEquals("Result", send.getStringExtra(Intent.EXTRA_SUBJECT))
        assertEquals("INVALID", channel(host).call("shareText", mapOf("text" to "")).errorCode)
    }

    @Test fun aSharedFileGetsItsCleanNameAndOnlyAReadGrant() {
        val host = FakeHost()
        val files = channel(host)
        val share = files.call("sharePart", mapOf("bytes" to byteArrayOf(1, 2))).value as Long
        assertEquals(share, files.call("sharePart", mapOf("share" to share, "bytes" to byteArrayOf(3))).value)
        val answer = files.call("shareFile", mapOf("share" to share, "name" to "rec/../clip‮.webm", "mimeType" to "video/webm"))
        assertNull(answer.errorCode)

        val shared = File(cacheDir, "share").listFiles()!!.single().listFiles()!!.single()
        assertEquals("clip.webm", shared.name)
        assertArrayEquals(byteArrayOf(1, 2, 3), shared.readBytes())
        @Suppress("DEPRECATION")
        val send = host.started.single().getParcelableExtra<Intent>(Intent.EXTRA_INTENT)!!
        assertEquals("video/webm", send.type)
        @Suppress("DEPRECATION")
        val uri = send.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)!!
        assertEquals("clip.webm", uri.lastPathSegment)
        assertEquals(uri, send.clipData!!.getItemAt(0).uri)
        assertEquals(Intent.FLAG_GRANT_READ_URI_PERMISSION, send.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
        assertEquals(0, send.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        assertEquals(0, send.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        // The upload is finished: it takes no more parts.
        assertEquals("INVALID", files.call("sharePart", mapOf("share" to share, "bytes" to byteArrayOf(4))).errorCode)
    }

    @Test fun theShareCacheDropsOldSharesAndUnfinishedUploads() {
        var now = 1_000_000L
        val cache = ShareCache(cacheDir, ttlMillis = 1_000, clock = { now })
        val old = cache.finish(cache.append(null, byteArrayOf(1)), "old.txt")
        val unfinished = cache.append(null, byteArrayOf(2))
        cache.root.resolve("stray.txt").writeText("x")
        now += 500
        cache.prune()
        assertTrue(old.exists())
        assertFalse(cache.root.resolve("stray.txt").exists())
        now += 1_000
        // A new share prunes the old one, never an open upload.
        val fresh = cache.finish(cache.append(null, byteArrayOf(3)), "new.txt")
        assertFalse(old.exists())
        assertTrue(fresh.exists())
        assertEquals(2, cache.root.listFiles()!!.size)
        cache.discardUploads()
        assertEquals(listOf(fresh.parentFile), cache.root.listFiles()!!.toList())
        assertEquals("INVALID", channel(FakeHost(), cache).call("shareFile", mapOf("share" to unfinished, "name" to "x")).errorCode)
    }

    // Drops.

    @Test fun aDropOnTheTargetReadsItsImagesAndGivesTheGrantBack() {
        val host = FakeHost()
        val image = host.content.add("content://files/1", "drop.webp", "image/webp", byteArrayOf(7))
        val text = host.content.add("content://files/2", "notes.txt", "text/plain", byteArrayOf(8))
        val files = channel(host)
        files.call("setDropTarget", mapOf("token" to 3, "left" to 10.0, "top" to 20.0, "right" to 110.0, "bottom" to 70.0, "devicePixelRatio" to 2.0))
        assertTrue(host.listener != null)

        var released = 0
        // (30, 50) logical is outside; (60, 120) physical is (30, 60) logical, inside.
        assertFalse(files.drop(10f, 30f, listOf(image)) { { released++ } })
        assertTrue(files.drop(60f, 120f, listOf(image, text)) { { released++ } })
        assertEquals(1, released)
        assertTrue(image in host.content.opened)
        assertFalse(text in host.content.opened)
        // Without a grant there is no read.
        assertFalse(files.drop(60f, 120f, listOf(image)) { null })
    }

    @Test fun aFailedDropReadStillGivesTheGrantBack() {
        var released = false
        try {
            readDrop({ throw IllegalStateException("provider died") }, { released = true })
        } catch (_: IllegalStateException) {
        }
        assertTrue(released)
    }

    @Test fun aClearedTargetTakesNoDrops() {
        val host = FakeHost()
        val image = host.content.add("content://files/1", "drop.png", "image/png", byteArrayOf(7))
        val files = channel(host)
        files.call("setDropTarget", mapOf("token" to 4, "left" to 0, "top" to 0, "right" to 100, "bottom" to 100, "devicePixelRatio" to 1))
        files.call("clearDropTarget", mapOf("token" to 5))
        assertTrue(files.drop(5f, 5f, listOf(image)) { {} })
        files.call("clearDropTarget", mapOf("token" to 4))
        assertFalse(files.drop(5f, 5f, listOf(image)) { {} })
        assertEquals("INVALID", files.call("setDropTarget", mapOf("token" to 4, "left" to 5, "top" to 0, "right" to 1, "bottom" to 100, "devicePixelRatio" to 1)).errorCode)
        assertTrue(mayHoldImages(listOf("text/plain", "image/png")))
        assertTrue(mayHoldImages(listOf("text/uri-list")))
        assertFalse(mayHoldImages(listOf("text/plain")))
        assertFalse(mayHoldImages(null))
    }

    // Names.

    @Test fun namesLoseFoldersControlsAndFormatCharacters() {
        assertEquals("file", cleanFileName("../\u0000", "file"))
        assertEquals("passwd", cleanFileName("/etc/passwd", "file"))
        assertEquals("b.png", cleanFileName("a\\b.png", "file"))
        assertEquals("clipcod.webm", cleanFileName("clip‮cod\u0085.webm", "file"))
        assertEquals("ab.webm", cleanFileName("a​b󠀁.webm", "file"))
        assertEquals("file", cleanFileName("..", "file"))
        assertEquals("file", cleanFileName("  ", "file"))
        assertEquals("file", cleanFileName(null, "file"))
        assertEquals(200, cleanFileName("a".repeat(300), "file").length)
        assertEquals("image/png", concreteMimeType("Image/PNG; charset=x"))
        assertNull(concreteMimeType("image/*"))
        assertNull(concreteMimeType("no type"))
    }
}
