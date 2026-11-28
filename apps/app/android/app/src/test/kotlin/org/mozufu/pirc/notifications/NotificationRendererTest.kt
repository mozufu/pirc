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

    @Test fun aLateAnsweredUpdateDoesNotRepostARemovedNotification() {
        // The overlay's own send removed it while the "answered" push was being read.
        renderer.apply(listOf(ReceiptStep.Show(spec().copy(answeredOn = "Pixel", actions = emptyList(), choices = emptyList()))))
        assertTrue(shadowOf(manager).allNotifications.isEmpty())
    }

    @Test fun aQuestionsTitleIsWordedHereFromItsSessionName() {
        val note = renderer.build(spec().copy(waitingSession = "New session", body = KnownText.AUTO_MODE_APPROVAL_TITLE))
        assertEquals("New session is waiting for you", note.title())
        assertEquals("Auto mode: allow a potentially dangerous action?", note.text())
        // Without a session name, the title as sent.
        assertEquals("Build is waiting for you", renderer.build(spec()).title())
    }

    private fun plain(title: String, body: String, text: PushText? = null) = spec().copy(
        tag = "thread:t1",
        title = title,
        body = body,
        actions = emptyList(),
        choices = emptyList(),
        text = text,
    )

    @Test fun pushWordsAreBuiltFromTheirText() {
        val replied = renderer.build(plain("Butler replied", "Open the thread to read it.", PushText("potReplied", mapOf("pot" to "Butler"))))
        assertEquals("Butler replied", replied.title())
        assertEquals("Open the thread to read it.", replied.text())
        val summary = renderer.build(plain("1 new update", "a", PushText(PushNote.SUMMARY_KEY, mapOf("count" to "1"))))
        assertEquals("1 new update", summary.title())
        // An unknown key or a missing name: the words as sent.
        assertEquals("Sent", renderer.build(plain("Sent", "B", PushText("later", mapOf("pot" to "Butler")))).title())
        assertEquals("Sent", renderer.build(plain("Sent", "B", PushText("potReplied", emptyMap()))).title())
    }

    @Test @Config(qualifiers = "zh-rTW")
    fun pushWordsFollowTheSystemLanguage() {
        fun shown(title: String, body: String, key: String? = null, vararg args: Pair<String, String>) =
            renderer.build(plain(title, body, key?.let { PushText(it, args.toMap()) })).let { it.title() to it.text() }
        assertEquals(
            "Butler 想使用模型" to "openai/gpt-5，用於「iPad tests」",
            shown("Butler asks to use a model", "openai/gpt-5 for \"iPad tests\"", "potApproval",
                "pot" to "Butler", "provider" to "openai", "model" to "gpt-5", "work" to "iPad tests"),
        )
        assertEquals(
            "Butler 的預算已用完" to "有一項預算上限已用完。開啟對話查看它的上限。",
            shown("Butler is blocked by its budget", "A budget limit is used up. Open the thread to review its limits.",
                "potBudgetBlocked", "pot" to "Butler"),
        )
        assertEquals(
            "Butler 開了一項工作" to "iPad tests",
            shown("Butler opened work", "iPad tests", "potOpenedWork", "pot" to "Butler"),
        )
        assertEquals(
            "Daily digest 已錯過" to "現在執行，或略過這次。",
            shown("Daily digest was missed", "Allow it to run it now, or dismiss it.", "scheduleMissed", "schedule" to "Daily digest"),
        )
        assertEquals(
            "事件提醒：Dentist" to "這個事件將於 2026-11-28 09:30 開始（Asia/Taipei）。",
            shown("Event reminder: Dentist", "This event starts at 2026-11-28 09:30 (Asia/Taipei).", "calendarStarts",
                "event" to "Dentist", "when" to "2026-11-28 09:30", "timezone" to "Asia/Taipei"),
        )
        assertEquals(
            "3 則新動態" to "a · b · c",
            shown("3 new updates", "a · b · c", PushNote.SUMMARY_KEY, "count" to "3"),
        )
        assertEquals(
            "pirc 通知正常運作" to "排程執行和等你處理的事都會顯示在這裡。",
            shown("pirc notifications work", "Scheduled runs and anything waiting for you will show up here."),
        )
        assertEquals(
            "有個 pot 注意到一件事" to "需要你的回答才能繼續。",
            shown("A pot noticed something", "It needs your answer to go on."),
        )
        // Anything else is shown as sent.
        assertEquals("Sent" to "Body", shown("Sent", "Body", "later", "pot" to "Butler"))
        // The lock screen shows the same title.
        val locked = renderer.build(plain("Butler replied", "Open the thread to read it.", PushText("potReplied", mapOf("pot" to "Butler"))))
        assertEquals("Butler 回覆了", locked.publicVersion.title())
    }

    @Test @Config(qualifiers = "zh-rTW")
    fun anApprovalsFrameFollowsTheSystemLanguage() {
        val message = "Command (bash, in /repo):\n\nrm -rf build\n\nReason: x\n\nReason: deletes files"
        assertEquals(
            "指令（bash，位於 /repo）：\n\nrm -rf build\n\nReason: x\n\n原因：deletes files",
            KnownText.questionMessage(context, KnownText.AUTO_MODE_APPROVAL_TITLE, message),
        )
        assertEquals(message, KnownText.questionMessage(context, "Q", message))
        assertEquals("Odd (x):\n\ny\n\nReason: z", KnownText.questionMessage(context, KnownText.READ_ONLY_APPROVAL_TITLE, "Odd (x):\n\ny\n\nReason: z"))
    }

    @Test @Config(qualifiers = "zh-rTW")
    fun knownServerTextFollowsTheSystemLanguage() {
        val waiting = renderer.build(
            spec().copy(
                waitingSession = "New session",
                body = KnownText.AUTO_MODE_APPROVAL_TITLE,
                choices = listOf(
                    NotificationChoice("A", question),
                    NotificationChoice("Other (type your own answer)", question, other = true),
                ),
            ),
        )
        assertEquals("新對話 正在等你回覆", waiting.title())
        assertEquals("自動模式：要允許這個可能有風險的動作嗎？", waiting.text())
        assertEquals("Build 正在等你回覆", renderer.build(spec().copy(waitingSession = "Build")).title())
    }

    @Test @Config(qualifiers = "zh-rTW")
    fun stringsFollowTheSystemLanguage() {
        val note = renderer.build(spec(lockScreen = "title"))
        assertEquals(listOf("回答…", "開啟對話"), note.actions.map { it.title.toString() })
        assertEquals("解鎖後查看內容", note.publicVersion.text())
    }
}
