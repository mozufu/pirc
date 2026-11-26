package org.mozufu.pirc.push

import android.content.Context
import java.util.concurrent.Executor
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mozufu.pirc.background.BackgroundConfig
import org.mozufu.pirc.call
import org.mozufu.pirc.direct
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * The Gateway's push targets as `/api/push*` keeps them: one per endpoint, new ones with
 * the default preferences, PATCH at the revision (crates/pirc-gateway/src/push.rs).
 */
private class FakePushGateway : Dispatcher() {
    val targets = linkedMapOf<String, JSONObject>()
    val log = mutableListOf<String>()
    val bodies = mutableListOf<JSONObject?>()
    var failKey = false
    var failPatch = false
    var failDelete = false
    private var next = 0

    private fun json(code: Int, body: JSONObject) = MockResponse.Builder().code(code).body(body.toString()).build()

    @Synchronized
    override fun dispatch(request: RecordedRequest): MockResponse {
        val path = request.url.encodedPath
        log += "${request.method} $path"
        val body = request.body?.utf8()?.takeIf { it.isNotEmpty() }?.let { JSONObject(it) }
        bodies += body
        return when {
            request.method == "GET" && path == "/api/push" -> if (failKey) {
                json(500, JSONObject().put("error", JSONObject().put("code", "internal").put("message", "boom")))
            } else {
                json(200, JSONObject().put("publicKey", "VAPID").put("subscriptions", JSONArray(targets.values.toList())))
            }
            request.method == "POST" && path == "/api/push/subscriptions" -> {
                val endpoint = body!!.getString("endpoint")
                val target = targets.getOrPut(endpoint) {
                    JSONObject()
                        .put("id", "push-${++next}")
                        .put("kind", "unifiedpush")
                        .put("levels", JSONObject().put("needs_you", "immediate").put("done", "digest").put("progress", "off").put("calendar", "immediate"))
                        .put("quietHours", JSONObject.NULL)
                        .put("timeZone", "UTC")
                        .put("lockScreen", "title")
                        .put("digestAt", "18:00")
                        .put("revision", 1)
                }
                json(201, JSONObject().put("subscription", target))
            }
            request.method == "PATCH" && path.startsWith("/api/push/subscriptions/") -> {
                if (failPatch) return json(502, JSONObject())
                val id = path.substringAfterLast('/')
                val target = targets.values.first { it.getString("id") == id }
                if (body!!.getLong("revision") != target.getLong("revision")) {
                    return json(409, JSONObject().put("error", JSONObject().put("code", "revision_mismatch")))
                }
                for (key in body.keys()) {
                    if (key == "revision") continue
                    if (key == "levels") {
                        val levels = target.getJSONObject("levels")
                        val patch = body.getJSONObject("levels")
                        for (category in patch.keys()) levels.put(category, patch.get(category))
                    } else {
                        target.put(key, body.get(key))
                    }
                }
                target.put("revision", target.getLong("revision") + 1)
                json(200, JSONObject().put("subscription", target))
            }
            request.method == "DELETE" && path == "/api/push/subscriptions" -> {
                if (failDelete) return json(502, JSONObject())
                targets.remove(body!!.getString("endpoint"))
                MockResponse.Builder().code(204).build()
            }
            else -> json(404, JSONObject())
        }
    }
}

@RunWith(RobolectricTestRunner::class)
class PushRegistrationTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val server = MockWebServer()
    private val gateway = FakePushGateway()
    private val config = BackgroundConfig(context.getSharedPreferences("background-test", Context.MODE_PRIVATE))
    private var token: String? = "pirc_dev_token"
    private var zone = "Asia/Taipei"

    private class Distributors : PushDistributors {
        var installed = listOf("io.heckel.ntfy")
        var selected: String? = null
        val calls = mutableListOf<String>()
        val failing = mutableSetOf<String>()

        override fun installed() = installed

        override fun label(distributor: String) = "ntfy"

        override fun select(distributor: String) {
            selected = distributor
        }

        override fun register(instance: String, vapid: String) {
            calls += "register $instance $vapid"
        }

        override fun unregister(instance: String) {
            calls += "unregister $instance"
            if (instance in failing) error("temporary connector failure")
        }
    }

    private val distributors = Distributors()
    private lateinit var registration: PushRegistration
    private val changes = mutableListOf<String>()

    @Before fun start() {
        server.dispatcher = gateway
        server.start()
        config.save(server.url("/").toString(), "client-1")
        registration = PushRegistration(
            prefs = context.getSharedPreferences("push-test", Context.MODE_PRIVATE),
            config = config,
            distributors = distributors,
            gatewayFor = { PushGateway(it.gateway, { token }) },
            work = direct,
            deviceName = "Pixel 9",
            timeZone = { zone },
        )
        registration.onChange = { changes += it.state }
    }

    @After fun stop() = server.close()

    private fun lastInstance() = distributors.calls.last { it.startsWith("register") }.split(" ")[1]

    private val p256dh = "B" + "a".repeat(86)
    private val auth = "a".repeat(22)

    private fun connect(endpoint: String): String {
        registration.enable("io.heckel.ntfy")
        val instance = lastInstance()
        registration.onEndpoint(instance, endpoint, p256dh, auth)
        return instance
    }

    private fun target(endpoint: String) = gateway.targets.getValue(endpoint)

    @Test fun enableRegistersAndSendsTheEndpointToTheGateway() {
        val instance = connect("https://push.example/e1")
        assertEquals("io.heckel.ntfy", distributors.selected)
        assertEquals(listOf("register $instance VAPID"), distributors.calls)
        assertEquals(
            listOf("GET /api/push", "POST /api/push/subscriptions", "PATCH /api/push/subscriptions/push-1"),
            gateway.log,
        )
        val subscribe = gateway.bodies[1]!!
        assertEquals("https://push.example/e1", subscribe.getString("endpoint"))
        assertEquals("unifiedpush", subscribe.getString("kind"))
        assertEquals(p256dh, subscribe.getJSONObject("keys").getString("p256dh"))
        assertEquals(auth, subscribe.getJSONObject("keys").getString("auth"))
        assertEquals("Pixel 9", subscribe.getString("name"))
        assertEquals(setOf("endpoint", "keys", "kind", "name"), subscribe.keys().asSequence().toSet())
        // The phone's zone is set before the app hears of the target.
        assertEquals(JSONObject().put("revision", 1).put("timeZone", "Asia/Taipei").toString(), gateway.bodies[2].toString())

        val status = registration.status()
        assertEquals("on", status.state)
        assertEquals("push-1", status.subscriptionId)
        assertEquals("io.heckel.ntfy", status.distributor)
        assertTrue(registration.acceptsMessage(instance))
        assertEquals(listOf("connecting", "on"), changes)
        assertEquals(2, target("https://push.example/e1").getInt("revision"))
    }

    @Test fun enablingAgainCarriesThePreferencesAndDeletesTheOldTargetOnlyAfterTheNewIsSaved() {
        val old = connect("https://push.example/e1")
        // The user's preferences, set through the app at the Gateway.
        target("https://push.example/e1")
            .put("lockScreen", "hidden")
            .put("digestAt", "07:15")
            .put("quietHours", JSONObject().put("start", "22:00").put("end", "07:00"))
            .getJSONObject("levels").put("done", "off")
        gateway.log.clear()

        registration.enable("io.heckel.ntfy")
        val new = lastInstance()
        // Nothing is deleted yet: a switch that fails keeps the old target.
        assertTrue(gateway.log.none { it.startsWith("DELETE") })
        assertTrue("https://push.example/e1" in gateway.targets)
        assertEquals(listOf("register $old VAPID", "register $new VAPID", "unregister $old"), distributors.calls)

        registration.onEndpoint(new, "https://push.example/e2", p256dh, auth)
        val fresh = target("https://push.example/e2")
        assertEquals("push-2", fresh.getString("id"))
        assertEquals("hidden", fresh.getString("lockScreen"))
        assertEquals("07:15", fresh.getString("digestAt"))
        assertEquals("22:00", fresh.getJSONObject("quietHours").getString("start"))
        assertEquals("off", fresh.getJSONObject("levels").getString("done"))
        assertEquals("Asia/Taipei", fresh.getString("timeZone"))
        // The old target goes after the new one is saved.
        assertEquals("DELETE /api/push/subscriptions", gateway.log.last())
        assertEquals(setOf("https://push.example/e2"), gateway.targets.keys)
        assertEquals("push-2", registration.status().subscriptionId)

        // Callbacks of the retired instance are ignored.
        assertFalse(registration.acceptsMessage(old))
        registration.fail(old, "late failure")
        assertEquals("on", registration.status().state)
        registration.onUnregistered(old)
        assertEquals("on", registration.status().state)
        assertTrue(registration.acceptsMessage(new))
    }

    @Test fun aFailedSwitchKeepsTheOldRegistrationAndTarget() {
        val old = connect("https://push.example/e1")
        gateway.failKey = true
        val error = runCatching { registration.enable("io.heckel.ntfy") }.exceptionOrNull()
        assertTrue(error is PushGatewayException)
        val status = registration.status()
        assertEquals("on", status.state)
        assertEquals("push-1", status.subscriptionId)
        assertTrue(registration.acceptsMessage(old))
        assertTrue("https://push.example/e1" in gateway.targets)
        assertEquals(listOf("register $old VAPID"), distributors.calls)
    }

    @Test fun aRenewedEndpointKeepsItsPreferences() {
        val instance = connect("https://push.example/e1")
        target("https://push.example/e1").put("lockScreen", "full")
        registration.onEndpoint(instance, "https://push.example/e1b", p256dh, auth)
        assertEquals("full", target("https://push.example/e1b").getString("lockScreen"))
        assertEquals(setOf("https://push.example/e1b"), gateway.targets.keys)
        assertTrue(registration.acceptsMessage(instance))
    }

    @Test fun offThenOnKeepsThePreferences() {
        connect("https://push.example/e1")
        target("https://push.example/e1").put("digestAt", "20:00")
        registration.disable()
        assertTrue(gateway.targets.isEmpty())
        connect("https://push.example/e2")
        assertEquals("20:00", target("https://push.example/e2").getString("digestAt"))
    }

    @Test fun forgetDeletesWithoutReadingFirst() {
        connect("https://push.example/e1")
        gateway.log.clear()
        registration.forget()
        assertEquals(listOf("DELETE /api/push/subscriptions"), gateway.log)
        assertTrue(gateway.targets.isEmpty())
    }

    @Test fun carriedPreferencesThatCouldNotBeSetAreSetAtTheNextSync() {
        connect("https://push.example/e1")
        target("https://push.example/e1").put("digestAt", "06:45")
        registration.enable("io.heckel.ntfy")
        gateway.failPatch = true
        registration.onEndpoint(lastInstance(), "https://push.example/e2", p256dh, auth)
        // Saved anyway; the preferences wait.
        assertEquals("on", registration.status().state)
        assertEquals("18:00", target("https://push.example/e2").getString("digestAt"))
        gateway.failPatch = false
        registration.syncTimeZone()
        assertEquals("06:45", target("https://push.example/e2").getString("digestAt"))
        // Once set, they are not sent again.
        gateway.log.clear()
        registration.syncTimeZone()
        assertEquals(listOf("GET /api/push"), gateway.log)
    }

    @Test fun thePhonesZoneComesAfterTheCarriedOne() {
        connect("https://push.example/e1")
        // The old target was left in another zone (the phone travelled since).
        target("https://push.example/e1").put("timeZone", "Europe/Paris")
        registration.enable("io.heckel.ntfy")
        target("https://push.example/e1").put("timeZone", "Europe/Paris")
        // The new target already has the phone's zone, but the carried one would replace it.
        zone = "UTC"
        registration.onEndpoint(lastInstance(), "https://push.example/e2", p256dh, auth)
        assertEquals("UTC", target("https://push.example/e2").getString("timeZone"))
    }

    @Test fun aRenewedEndpointWhoseOldTargetCouldNotBeDeletedIsTriedAgain() {
        val instance = connect("https://push.example/e1")
        gateway.failDelete = true
        registration.onEndpoint(instance, "https://push.example/e1b", p256dh, auth)
        assertTrue("https://push.example/e1" in gateway.targets)
        gateway.failDelete = false
        registration.onEndpoint(instance, "https://push.example/e1c", p256dh, auth)
        assertEquals(setOf("https://push.example/e1c"), gateway.targets.keys)
    }

    @Test fun anUnregisteredEndpointWhoseDeleteFailedIsTriedAgain() {
        val instance = connect("https://push.example/e1")
        gateway.failDelete = true
        registration.onUnregistered(instance)
        assertTrue("https://push.example/e1" in gateway.targets)
        gateway.failDelete = false
        registration.disable()
        assertTrue(gateway.targets.isEmpty())
    }

    @Test fun aDistributorWithoutWebPushKeysFails() {
        registration.enable("io.heckel.ntfy")
        registration.onEndpoint(lastInstance(), "https://push.example/e1", null, null)
        val status = registration.status()
        assertEquals("failed", status.state)
        assertTrue(status.error!!.contains("Web Push keys"))
    }

    @Test fun aGatewayRefusalFailsTheFirstEnable() {
        gateway.failKey = true
        val error = runCatching { registration.enable("io.heckel.ntfy") }.exceptionOrNull()
        assertTrue(error is PushGatewayException)
        assertEquals("failed", registration.status().state)
        assertTrue(distributors.calls.isEmpty())
    }

    @Test fun anUninstalledDistributorIsRefused() {
        distributors.installed = emptyList()
        assertTrue(runCatching { registration.enable("io.heckel.ntfy") }.exceptionOrNull() is IllegalArgumentException)
        assertEquals("off", registration.status().state)
    }

    @Test fun disableUnregistersAndForgetsTheEndpoint() {
        val instance = connect("https://push.example/e1")
        val status = registration.disable()
        assertEquals("off", status.state)
        assertNull(status.subscriptionId)
        assertEquals("unregister $instance", distributors.calls.last())
        assertEquals("DELETE /api/push/subscriptions", gateway.log.last())
        assertTrue(gateway.targets.isEmpty())
        assertFalse(registration.acceptsMessage(instance))
        // An endpoint that arrives late is not sent.
        val requests = gateway.log.size
        registration.onEndpoint(instance, "https://push.example/e2", p256dh, auth)
        assertEquals(requests, gateway.log.size)
    }

    @Test fun anInstanceThatCouldNotBeUnregisteredIsTriedAgain() {
        val instance = connect("https://push.example/e1")
        distributors.failing += instance
        registration.disable()
        distributors.failing.clear()
        distributors.calls.clear()
        registration.disable()
        assertEquals(listOf("unregister $instance"), distributors.calls)
        distributors.calls.clear()
        registration.disable()
        assertTrue(distributors.calls.isEmpty())
    }

    @Test fun anUnregisteredInstanceLeavesTheGatewayToo() {
        val instance = connect("https://push.example/e1")
        registration.onUnregistered(instance)
        assertEquals("off", registration.status().state)
        assertTrue(gateway.targets.isEmpty())
        assertEquals("DELETE /api/push/subscriptions", gateway.log.last())
    }

    @Test fun theTimeZoneFollowsThePhone() {
        connect("https://push.example/e1")
        val requests = gateway.log.size
        registration.syncTimeZone()
        // The same zone: read, nothing changed.
        assertEquals(requests + 1, gateway.log.size)
        zone = "Europe/Berlin"
        changes.clear()
        registration.syncTimeZone()
        assertEquals("Europe/Berlin", target("https://push.example/e1").getString("timeZone"))
        assertEquals(listOf("on"), changes)
    }

    @Test fun aNewPairingRefusesTheOldRegistrationsMessages() {
        val instance = connect("https://push.example/e1")
        config.clear()
        assertFalse(registration.acceptsMessage(instance))
        config.save("https://other.test/", "client-2")
        assertFalse(registration.acceptsMessage(instance))
    }

    @Test fun thePairingStampStaysForTheSameGateway() {
        val first = config.read()!!
        assertEquals("client-1", first.clientId)
        assertEquals(first.pairingStamp, config.save(server.url("/").toString(), "client-1").pairingStamp)
        config.clear()
        assertNull(config.read())
        assertTrue(config.save(server.url("/").toString(), "client-1").pairingStamp != first.pairingStamp)
    }

    @Test fun theChannelConfiguresAndForgets() {
        val replies = Executor { it.run() }
        val channel = PushChannel(registration, config, direct, replies, sync = direct) { "Asia/Taipei" }
        assertEquals("push", channel.name)
        assertEquals(listOf(mapOf("id" to "io.heckel.ntfy", "name" to "ntfy")), channel.call("distributors").value)
        assertEquals(
            mapOf("state" to "off", "distributor" to null, "error" to null, "subscriptionId" to null, "timeZone" to "Asia/Taipei"),
            channel.call("status").value,
        )
        assertEquals("INVALID", channel.call("configure", mapOf("gateway" to "")).errorCode)
        assertEquals("INVALID", channel.call("configure", mapOf("gateway" to "ftp://x", "clientId" to "c")).errorCode)
        channel.call("configure", mapOf("gateway" to "https://gateway.test/", "clientId" to "client-9"))
        assertEquals("https://gateway.test/", config.read()!!.gateway.toString())
        assertEquals("client-9", config.read()!!.clientId)
        channel.call("forget")
        assertNull(config.read())
        assertEquals("INVALID", channel.call("enable").errorCode)
    }

    @Test fun anOldChannelDetachingKeepsTheNewOnesListener() {
        val first = PushChannel(registration, config, direct, direct, sync = direct) { "UTC" }
        val second = PushChannel(registration, config, direct, direct, sync = direct) { "UTC" }
        first.attached(io.flutter.plugin.common.MethodChannel(NoMessenger, "a"))
        second.attached(io.flutter.plugin.common.MethodChannel(NoMessenger, "b"))
        val listener = registration.onChange
        first.detach()
        assertTrue(registration.onChange === listener)
        second.detach()
        assertNull(registration.onChange)
    }

    private object NoMessenger : io.flutter.plugin.common.BinaryMessenger {
        override fun send(channel: String, message: java.nio.ByteBuffer?) {}

        override fun send(channel: String, message: java.nio.ByteBuffer?, callback: io.flutter.plugin.common.BinaryMessenger.BinaryReply?) {}

        override fun setMessageHandler(channel: String, handler: io.flutter.plugin.common.BinaryMessenger.BinaryMessageHandler?) {}
    }
}

class PushRegistrationGuardTest {
    @Test fun aPendingEndpointIsTakenBackAfterDisableOrReplacement() {
        val pending = PushRegistrationAttempt("attempt-a", "pairing-1")
        val active = PushRegistrationSnapshot(true, "attempt-a", "pairing-1")
        assertTrue(active.accepts(pending))
        assertFalse(active.shouldCompensate(pending))
        assertTrue(PushRegistrationSnapshot(false, null, "pairing-1").shouldCompensate(pending))
        assertTrue(PushRegistrationSnapshot(true, "attempt-b", "pairing-1").shouldCompensate(pending))
        // Paired again meanwhile, even with the same instance.
        assertTrue(PushRegistrationSnapshot(true, "attempt-a", "pairing-2").shouldCompensate(pending))
        assertTrue(PushRegistrationSnapshot(true, "attempt-a", null).shouldCompensate(pending))
    }

    @Test fun lateCallbacksOfARetiredInstanceAreIgnored() {
        val current = PushRegistrationSnapshot(true, "attempt-b", "pairing-1")
        assertTrue(current.acceptsCallback("attempt-b"))
        assertFalse(current.acceptsCallback("attempt-a"))
        assertFalse(PushRegistrationSnapshot(true, null, "pairing-1").acceptsCallback("default"))
    }

    @Test fun theReplacementIsRegisteredBeforeOldInstancesAreRetired() {
        val calls = mutableListOf<String>()
        val failed = runCatching {
            registerBeforeRetiring("new", setOf("old"), register = {
                calls += "register"
                error("invalid VAPID")
            }, unregister = { calls += "unregister:$it" })
        }.exceptionOrNull()
        assertTrue(failed is IllegalStateException)
        assertEquals(listOf("register"), calls)

        calls.clear()
        val result = registerBeforeRetiring("new", setOf("old-a", "old-b", "new"), register = {
            calls += "register"
            true
        }, unregister = {
            calls += "unregister:$it"
            if (it == "old-b") error("temporary connector failure")
        })
        assertEquals(listOf("register", "unregister:old-a", "unregister:old-b"), calls)
        assertTrue(result.registered)
        assertEquals(setOf("old-b"), result.pendingRetiredInstances)

        calls.clear()
        val stale = registerBeforeRetiring("new", setOf("old"), register = { false }, unregister = { calls += it })
        assertFalse(stale.registered)
        assertTrue(calls.isEmpty())
        assertEquals(setOf("old"), stale.pendingRetiredInstances)
    }
}
