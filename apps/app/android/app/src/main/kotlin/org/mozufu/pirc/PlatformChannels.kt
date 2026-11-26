package org.mozufu.pirc

import android.app.Activity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import org.mozufu.pirc.credentials.CredentialsChannel
import org.mozufu.pirc.credentials.KeystoreCredentialStore
import org.mozufu.pirc.fonts.FontsChannel
import org.mozufu.pirc.images.ImagesChannel
import org.mozufu.pirc.media.MediaChannel

/**
 * One feature's method channel, named `org.mozufu.pirc/<name>`. Each feature
 * lives in its own package and adds one line to [PlatformChannels.features].
 */
interface PlatformFeature : MethodChannel.MethodCallHandler {
    /** The last part of the channel name, for example `credentials`. */
    val name: String

    /** The engine is going away: stop work and drop references to it. */
    fun detach() {}

    /** The activity is paused (another app or the lock screen is in front). */
    fun background() {}

    /** The activity is in front again. */
    fun foreground() {}
}

/** Registers every feature's channel on the engine and removes them again. */
class PlatformChannels(private val features: List<PlatformFeature>) {
    private val channels = mutableListOf<MethodChannel>()

    init {
        val names = features.map { it.name }
        require(names.toSet().size == names.size) { "Two features share a channel name: $names" }
    }

    fun attach(messenger: BinaryMessenger) {
        detachChannels()
        for (feature in features) {
            val channel = MethodChannel(messenger, channelName(feature.name))
            channel.setMethodCallHandler(feature)
            channels += channel
        }
    }

    fun detach() {
        detachChannels()
        features.forEach { it.detach() }
    }

    fun background() = features.forEach { it.background() }

    fun foreground() = features.forEach { it.foreground() }

    private fun detachChannels() {
        channels.forEach { it.setMethodCallHandler(null) }
        channels.clear()
    }

    companion object {
        const val PREFIX = "org.mozufu.pirc/"

        fun channelName(feature: String) = PREFIX + feature

        /** The features of the app. Later M8 steps add theirs here. */
        fun features(activity: Activity, textures: TextureRegistry): List<PlatformFeature> = listOf(
            CredentialsChannel(KeystoreCredentialStore.create(activity.applicationContext)),
            MediaChannel.create(activity, textures),
            ImagesChannel(),
            FontsChannel(),
        )
    }
}
