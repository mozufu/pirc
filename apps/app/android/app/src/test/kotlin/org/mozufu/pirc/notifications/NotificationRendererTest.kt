package org.mozufu.pirc.notifications

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mozufu.pirc.MainActivity
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
class NotificationRendererTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val manager = context.getSystemService(NotificationManager::class.java)
    private val signer = TapSigner(context.getSharedPreferences("taps-test", Context.MODE_PRIVATE))
    private val renderer = NotificationRenderer(context, signer, manager)

    private val question = OpenTarget.question("s1", "q1", "3")

    private fun spec(
        channel: String = NotificationChannels.NEEDS_YOU,
        lockScreen: String = "title",
        silent: Boolean = false,
    ) = NotificationSpec(
        tag = "interaction:7331:3:7131",
        channel = channel,
        title = "Build is waiting for you",
        body = "Rerun only the failures?",
        lockScreen = lockScreen,
        silent = silent,
        open = question,
        actions = listOf(
            NotificationAction(ActionLabel.ANSWER, question),
            NotificationAction(ActionLabel.OPEN_CONVERSATION, OpenTarget.session("s1")),
        ),
        choices = listOf(
            NotificationChoice("Only the failures", OpenTarget.question("s1", "q1", "3", "c1", "Only the failures")),
            NotificationChoice("All", OpenTarget.question("s1", "q1", "3", "c2", "All")),
        ),
    )

    private fun Notification.title() = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()

    private fun Notification.text() = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()

    @Test fun eachCategoryHasItsChannel() {
        renderer.apply(listOf(ReceiptStep.Show(spec())))
        val expected = mapOf(
            NotificationChannels.NEEDS_YOU to NotificationManager.IMPORTANCE_HIGH,
            NotificationChannels.DONE to NotificationManager.IMPORTANCE_DEFAULT,
            NotificationChannels.PROGRESS to NotificationManager.IMPORTANCE_LOW,
            NotificationChannels.CALENDAR to NotificationManager.IMPORTANCE_HIGH,
            NotificationChannels.SUMMARY to NotificationManager.IMPORTANCE_DEFAULT,
        )
        for ((id, importance) in expected) {
            val channel = manager.getNotificationChannel(id)
            assertNotNull(id, channel)
            assertEquals(id, importance, channel.importance)
        }
        assertEquals("Needs you", manager.getNotificationChannel(NotificationChannels.NEEDS_YOU).name)
        for (id in NotificationChannels.all) {
            assertEquals(id, renderer.build(spec(channel = id)).channelId)
        }
    }

    @Test fun aQuestionHasItsButtonsAndChoices() {
        val note = renderer.build(spec())
        assertEquals("Build is waiting for you", note.title())
        assertEquals("Rerun only the failures?", note.text())
        assertEquals(listOf("Answer…", "Open conversation"), note.actions.map { it.title.toString() })
        // Expanded: a custom view with the choices.
        assertNotNull(note.bigContentView)
        assertEquals(
            Notification.DecoratedCustomViewStyle::class.java.name,
            note.extras.getString(Notification.EXTRA_TEMPLATE),
        )
        assertTrue(note.actions.all { it.isAuthenticationRequired })
    }

    @Test fun tapsAreExplicitImmutableAndSigned() {
        val note = renderer.build(spec())
        val intents = listOf(note.contentIntent) + note.actions.map { it.actionIntent }
        val keys = mutableSetOf<String>()
        for (pending in intents) {
            val shadow = shadowOf(pending)
            assertTrue(shadow.isActivityIntent)
            assertTrue(shadow.flags and PendingIntent.FLAG_IMMUTABLE != 0)
            val intent = shadow.savedIntent
            assertEquals(MainActivity::class.java.name, intent.component?.className)
            assertEquals(context.packageName, intent.component?.packageName)
            assertEquals(NotificationRenderer.ACTION_OPEN, intent.action)
            val target = intent.getStringExtra(NotificationRenderer.EXTRA_TARGET)!!
            assertTrue(signer.verify(target, intent.getStringExtra(NotificationRenderer.EXTRA_SIGNATURE)))
            assertNotNull(openTargetOf(intent, restored = false, signer))
            keys += intent.identifier!!
        }
        // The content tap and each button are their own PendingIntents.
        assertEquals(intents.size, keys.size)
    }

    @Test fun theLockScreenShowsWhatTheSettingAllows() {
        // Hidden: nothing on the lock screen, whatever Android's own setting is.
        val hidden = renderer.build(spec(lockScreen = "hidden"))
        assertEquals(Notification.VISIBILITY_SECRET, hidden.visibility)
        assertNull(hidden.publicVersion)

        val title = renderer.build(spec(lockScreen = "title"))
        assertEquals(Notification.VISIBILITY_PRIVATE, title.visibility)
        assertEquals("Build is waiting for you", title.publicVersion.title())
        assertEquals("Unlock to view", title.publicVersion.text())

        val full = renderer.build(spec(lockScreen = "full"))
        assertEquals(Notification.VISIBILITY_PRIVATE, full.visibility)
        assertEquals("Build is waiting for you", full.publicVersion.title())
        assertEquals("Rerun only the failures?", full.publicVersion.text())

        // Buttons and choices appear only after unlock.
        for (note in listOf(title, full)) {
            assertNull(note.publicVersion.actions)
            assertNull(note.publicVersion.bigContentView)
        }
    }

    @Test fun anEmptyTitleIsTheAppsName() {
        val note = renderer.build(spec().copy(title = "", answeredOn = "iPad", actions = emptyList(), choices = emptyList()))
        assertEquals("pirc", note.title())
        assertEquals("pirc", note.publicVersion.title())
    }

    @Test fun aQuestionGoesAwayWhenItExpires() {
        assertEquals(60_000L, renderer.build(spec().copy(timeoutMillis = 60_000)).timeoutAfter)
    }

    @Test fun pairingEndedIsShownOncePerPairing() {
        val shadow = shadowOf(manager)
        renderer.apply(listOf(ReceiptStep.PairingEnded), "pairing-1")
        assertEquals(listOf("Pairing ended"), shadow.allNotifications.map { it.title() })
        manager.cancelAll()
        renderer.apply(listOf(ReceiptStep.PairingEnded), "pairing-1")
        assertTrue(shadow.allNotifications.isEmpty())
        renderer.apply(listOf(ReceiptStep.PairingEnded), "pairing-2")
        assertEquals(1, shadow.allNotifications.size)
    }

    @Test fun theTitleOnScreenIsRead() {
        renderer.apply(listOf(ReceiptStep.Show(spec())))
        assertEquals("Build is waiting for you", renderer.shownTitle("interaction:7331:3:7131"))
        assertNull(renderer.shownTitle("other"))
    }

    @Test fun quietHoursMakeItSilent() {
        assertEquals(Notification.GROUP_ALERT_SUMMARY, renderer.build(spec(silent = true)).groupAlertBehavior)
        assertEquals(Notification.GROUP_ALERT_ALL, renderer.build(spec(silent = false)).groupAlertBehavior)
        assertNull(renderer.build(spec(silent = false)).group)
    }

    @Test fun answeredOnAnotherDeviceGoesAwayAfterFiveSeconds() {
        val answered = spec().copy(actions = emptyList(), choices = emptyList(), answeredOn = "iPad", timeoutMillis = 5_000)
        val note = renderer.build(answered)
        assertEquals("Answered on iPad", note.text())
        assertEquals(5_000L, note.timeoutAfter)
        assertNull(note.actions)
        assertEquals("Answered on another device", renderer.build(answered.copy(answeredOn = "")).text())
    }

    @Test fun showsUpdatesAndRemovesByTag() {
        val shadow = shadowOf(manager)
        renderer.apply(listOf(ReceiptStep.Show(spec())))
        assertEquals(setOf("interaction:7331:3:7131"), renderer.shownTags())
        renderer.apply(listOf(ReceiptStep.Show(spec().copy(answeredOn = "iPad", actions = emptyList(), choices = emptyList()))))
        assertEquals(1, shadow.allNotifications.size)
        assertEquals("Answered on iPad", shadow.allNotifications.single().text())
        renderer.apply(listOf(ReceiptStep.Remove("interaction:7331:3:7131")))
        assertTrue(shadow.allNotifications.isEmpty())
        assertFalse(renderer.shownTags().contains("interaction:7331:3:7131"))
    }

    @Test @Config(qualifiers = "zh-rTW")
    fun stringsFollowTheSystemLanguage() {
        val note = renderer.build(spec(lockScreen = "title"))
        assertEquals(listOf("回答…", "開啟對話"), note.actions.map { it.title.toString() })
        assertEquals("解鎖後查看內容", note.publicVersion.text())
    }
}
