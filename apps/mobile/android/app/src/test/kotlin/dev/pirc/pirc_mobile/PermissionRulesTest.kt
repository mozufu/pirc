package dev.pirc.pirc_mobile
import org.junit.Assert.assertEquals
import org.junit.Test
class PermissionRulesTest {
    @Test fun preAndroid13UsesNotificationSettings() = assertEquals(NotificationAction.AppSettings, notificationAction(32, true, false, false, false, true))
    @Test fun firstRequestUsesRuntimeDialog() = assertEquals(NotificationAction.Request, notificationAction(33, false, false, false, false, true))
    @Test fun ordinaryDenialCanAskAgain() = assertEquals(NotificationAction.Request, notificationAction(36, false, true, true, false, true))
    @Test fun permanentDenialUsesSettings() = assertEquals(NotificationAction.AppSettings, notificationAction(36, false, true, false, false, true))
    @Test fun blockedChannelUsesItsSettings() = assertEquals(NotificationAction.ChannelSettings, notificationAction(36, true, true, false, true, false))
    @Test fun missingRuntimePermissionTakesPriorityOverBlockedChannel() = assertEquals(NotificationAction.Request, notificationAction(36, false, false, false, false, false))
    @Test fun grantedDoesNotPrompt() = assertEquals(NotificationAction.Granted, notificationAction(36, true, false, false, true, true))
}
