package dev.pirc.pirc_mobile

enum class NotificationAction { Granted, Request, AppSettings, ChannelSettings }
fun notificationAction(sdk: Int, granted: Boolean, asked: Boolean, rationale: Boolean, appEnabled: Boolean, channelEnabled: Boolean): NotificationAction = when {
    sdk >= 33 && !granted -> if (asked && !rationale) NotificationAction.AppSettings else NotificationAction.Request
    !appEnabled -> NotificationAction.AppSettings
    !channelEnabled -> NotificationAction.ChannelSettings
    else -> NotificationAction.Granted
}
