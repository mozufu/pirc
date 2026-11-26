package org.mozufu.pirc.files

import android.app.Activity
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/** The real host: the system clipboard and the app's FileProvider (`res/xml/files_paths.xml`). */
@RunWith(RobolectricTestRunner::class)
class ActivityFilesHostTest {
    private val activity: Activity = Robolectric.buildActivity(Activity::class.java).setup().get()
    private val host = ActivityFilesHost(activity)

    @Test fun theClipboardDescriptionTellsImagesApart() {
        val clipboard = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("note", "hello"))
        assertFalse(host.clipHasImages())
        val image = Uri.parse("content://gallery/1")
        clipboard.setPrimaryClip(ClipData(ClipDescription("photo", arrayOf("image/jpeg")), ClipData.Item(image)))
        assertTrue(host.clipHasImages())
        assertEquals(image, host.primaryClip()!!.getItemAt(0).uri)
    }

    @Test fun theProviderServesOnlyTheShareCache() {
        val shared = File(activity.cacheDir, "share/abc/a.webm").apply {
            parentFile!!.mkdirs()
            writeBytes(byteArrayOf(1))
        }
        val uri = host.shareUri(shared)
        assertEquals("content", uri.scheme)
        assertEquals(activity.packageName + ".files", uri.authority)
        assertEquals(listOf("share", "abc", "a.webm"), uri.pathSegments)

        for (outside in listOf(File(activity.filesDir, "token"), File(activity.cacheDir, "other/a.webm"))) {
            outside.parentFile!!.mkdirs()
            outside.writeBytes(byteArrayOf(2))
            try {
                host.shareUri(outside)
                throw AssertionError("$outside was served")
            } catch (_: IllegalArgumentException) {
            }
        }
    }
}
