package dev.pirc.pirc_mobile

import dev.pirc.android.core.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import java.io.File
import java.io.IOException
import java.net.URI
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermission
import java.nio.file.attribute.PosixFilePermissions

/** Explicit conformance process entrypoint, not an Android OS/instrumentation test. */
object NativeFirstSendLive {
    private const val owner = "test@example.com"
    private const val stamp = "fixture-pairing"
    private val operations = listOf("native-reply-loss", "native-local-write-loss")
    private fun obj(value: Any?) = value as Map<*, *>
    private fun preparation(value: Any?) = obj(obj(value)["preparation"])
    private fun publish(root: File, name: String, value: Any?) {
        val pending = File(root, "$name.pending")
        pending.writeText(value.json().toString())
        Files.move(pending.toPath(), File(root, "$name.json").toPath(), StandardCopyOption.ATOMIC_MOVE)
    }
    private suspend fun marker(root: File, name: String): JsonObject {
        val deadline = System.nanoTime() + 60_000_000_000L
        while (!File(root, "$name.json").isFile) {
            check(System.nanoTime() < deadline) { "Timed out waiting for $name" }
            delay(30)
        }
        return PircJson.parseToJsonElement(File(root, "$name.json").readText()).jsonObject
    }
    @JvmStatic fun main(args: Array<String>) = runBlocking {
        require(args.size == 2 && args[1] in setOf("send", "recover", "compete", "compete-recover", "offline-send", "offline-recover", "allocation-send", "allocation-recover", "allocation-final"))
        val config = PircJson.parseToJsonElement(File(args[0]).readText()).jsonObject
        val gateway = config.getValue("gateway").jsonPrimitive.content
        require(URI(gateway).host == "127.0.0.1")
        val root = File(config.getValue("directory").jsonPrimitive.content)
        val directory = File(root, "primary")
        val scope = FirstSendDraftStore.scope(gateway, owner)
        val calls = mutableListOf<Map<String, Any>>()
        var beforeDispatch: ((String) -> Unit)? = null
        var lost = false
        var readonly: Pair<File, Set<PosixFilePermission>>? = null
        val faulting = args[1] == "send"
        val client = defaultHttpClient().newBuilder().addInterceptor(Interceptor { chain ->
            val request = chain.request()
            check(request.header("x-pirc-user") == null && request.header("Origin") == null)
            check(request.header("Authorization")?.startsWith("Bearer pirc_dev_") == true)
            if (faulting && request.url.encodedPath.endsWith("/dispatch")) {
                beforeDispatch!!(request.url.pathSegments[2])
            }
            if (args[1] == "offline-send" && request.url.encodedPath.endsWith("/materialize")) {
                val id = config.getValue("operationId").jsonPrimitive.content
                val row = FirstSendDraftStore(directory).get(scope, id)!!
                val prep = row.getValue("preparation").jsonObject
                check(prep["state"] == JsonPrimitive("accepted") && prep["nodeMapped"] == JsonPrimitive(false))
                publish(root, "allocation-held", mapOf("id" to id, "session" to prep.getValue("sessionId").jsonPrimitive.content))
                runBlocking { marker(root, "release-allocation") }
            }
            // Only fixture routing is substituted; authentication remains the real device bearer.
            val response = chain.proceed(request.newBuilder().header("Host", config.getValue("host").jsonPrimitive.content).build())
            calls += mapOf("method" to request.method, "path" to request.url.encodedPath, "status" to response.code)
            if (request.url.encodedPath.endsWith("/capabilities") && response.isSuccessful) {
                val text = response.body.string()
                val original = PircJson.parseToJsonElement(text).jsonObject
                // The fixture Gateway runs with PIRC_FIRST_SEND=1; the real capability says so.
                check(original["canSubmit"] == JsonPrimitive(true))
                check(original["clientContract"] == JsonPrimitive(2))
                return@Interceptor response.newBuilder().body(
                    text.toResponseBody("application/json".toMediaType())
                ).build()
            }
            if (faulting && request.url.encodedPath.endsWith("/dispatch") && response.isSuccessful) {
                if (request.url.encodedPath.contains("native-reply-loss") && !lost) {
                    lost = true
                    response.close()
                    throw IOException("Injected loss after real Gateway dispatch")
                }
                if (request.url.encodedPath.contains("native-local-write-loss")) {
                    val op = File(File(directory, FirstSendDraftStore.digest(scope.toByteArray())), FirstSendDraftStore.digest("native-local-write-loss".toByteArray()))
                    readonly = op to Files.getPosixFilePermissions(op.toPath())
                    Files.setPosixFilePermissions(op.toPath(), PosixFilePermissions.fromString("r-xr-xr-x"))
                    check(!Files.isWritable(op.toPath())) { "Run this filesystem-failure fixture as an ordinary user, not root" }
                }
            }
            response
        }).build()
        fun connection(token: String, dir: File): NativeFirstSend {
            val api = PircApi(Pairing(gateway, token), client)
            return NativeFirstSend(dir, { requested -> requirePairingStamp(requested, stamp); api }, { requested -> requirePairingStamp(requested, stamp) })
        }
        suspend fun save(c: NativeFirstSend, id: String, withFile: Boolean) = c.drafts(stamp, owner, mapOf(
            "action" to "put", "operationId" to id,
            "record" to mapOf("workspaceId" to "test:chats", "message" to "First message $id",
                "model" to mapOf("provider" to "fake", "id" to "fake-model"), "thinking" to "low",
                "files" to if (withFile) listOf(mapOf("id" to "original-file", "name" to "native.txt", "mimeType" to "text/plain", "byteSize" to "Original bytes for $id".toByteArray().size)) else emptyList()),
            "files" to if (withFile) listOf(mapOf("id" to "original-file", "bytes" to "Original bytes for $id".toByteArray())) else emptyList(),
        ))
        suspend fun row(c: NativeFirstSend, id: String) = obj(c.drafts(stamp, owner, mapOf("action" to "get", "operationId" to id)))
        try {
            val primary = connection(config.getValue("token").jsonPrimitive.content, directory)
            primary.capabilities(stamp)
            if (args[1].startsWith("allocation")) {
                val id = config.getValue("operationId").jsonPrimitive.content
                if (args[1] == "allocation-send") {
                    save(primary, id, true)
                    try {
                        primary.submit(stamp, owner, id, 1, "native-allocation")
                        error("The Gateway must be killed before returning materialization")
                    } catch (_: IOException) { /* The real Gateway connection was interrupted. */ }
                    val saved = row(primary, id)
                    check(saved["frozen"] == true && saved["uncertain"] == true)
                    check(preparation(saved)["state"] == "accepted")
                    check(calls.none { (it["path"] as String).endsWith("/dispatch") })
                    publish(root, "native-allocation-interrupted", mapOf("record" to saved, "calls" to calls))
                } else {
                    // First retry of uncertain state is query-only. It must not
                    // recreate storage, transfer attachments or execute the input.
                    val checked = primary.submit(stamp, owner, id, null, "native-allocation")
                    val expected = if (args[1] == "allocation-final") "admitted" else "accepted"
                    check(preparation(checked)["state"] == expected)
                    check(calls.all { it["method"] == "GET" })
                    publish(root, "native-allocation-" + if (args[1] == "allocation-final") "final" else "checked", mapOf("record" to checked, "calls" to calls.toList()))
                    if (args[1] == "allocation-recover") {
                        marker(root, "explicit-send")
                        val result = primary.submit(stamp, owner, id, null, "native-allocation")
                        check(preparation(result)["state"] == "admitted")
                        check(preparation(result)["sessionId"] == preparation(checked)["sessionId"])
                        check(calls.count { (it["path"] as String).endsWith("/dispatch") } == 1)
                        publish(root, "native-allocation-sent", mapOf("record" to result, "calls" to calls))
                    }
                }
                check(FirstSendDraftStore(directory).attachment(scope, id, "original-file").second.contentEquals("Original bytes for $id".toByteArray()))
                return@runBlocking
            }
            if (args[1].startsWith("offline")) {
                val id = config.getValue("operationId").jsonPrimitive.content
                val deleting = id == "offline-delete"
                if (args[1] == "offline-send") {
                    save(primary, id, true)
                    primary.submit(stamp, owner, id, 1, "native-before-allocation")
                    val result = primary.check(stamp, owner, id)
                    check(preparation(result)["state"] == if (deleting) "cancelled" else "stopping")
                    check(preparation(result)["nodeMapped"] == false)
                    check(calls.none { (it["path"] as String).endsWith("/dispatch") })
                    publish(root, "native-offline-paused", mapOf("record" to result, "calls" to calls))
                } else {
                    val checked = primary.check(stamp, owner, id)
                    check(preparation(checked)["state"] == if (deleting) "cancelled" else "stopped")
                    check(preparation(checked)["nodeMapped"] == false)
                    primary.submit(stamp, owner, id, null, "native-before-allocation")
                    check(calls.all { it["method"] == "GET" })
                    publish(root, "native-offline-checked", checked)
                    marker(root, "web-offline-result")
                    val result = primary.check(stamp, owner, id)
                    check(preparation(result)["nodeMapped"] == !deleting)
                    check(preparation(result)["state"] == if (deleting) "cancelled" else "stopped")
                    if (deleting) {
                        check(obj(result)["message"] == "" && (obj(result)["files"] as List<*>).isEmpty())
                        check(!directory.walkTopDown().any { it.name.startsWith("blob-") })
                    } else {
                        check(obj(result)["message"] == "First message $id")
                        check(FirstSendDraftStore(directory).attachment(scope, id, "original-file").second.contentEquals("Original bytes for $id".toByteArray()))
                    }
                    check(calls.all { it["method"] == "GET" })
                    publish(root, "native-offline-result", mapOf("record" to result, "calls" to calls))
                }
                return@runBlocking
            }
            if (args[1].startsWith("compete")) {
                compete(args[1], root, primary, PircApi(Pairing(gateway, config.getValue("token").jsonPrimitive.content), client), calls)
                return@runBlocking
            }
            val secondDirectory = File(root, "secondary")
            val secondary = connection(config.getValue("secondToken").jsonPrimitive.content, secondDirectory)
            secondary.capabilities(stamp)
            if (faulting) {
                // A second paired client opens the pending conversation before delivery.
                // Completed operations intentionally disappear from the pending-session API.
                beforeDispatch = { id ->
                    val saved = FirstSendDraftStore(directory).get(scope, id)!!
                    val session = saved.getValue("preparation").jsonObject.getValue("sessionId").jsonPrimitive.content
                    runBlocking {
                        val adopted = secondary.adopt(stamp, owner, session)
                        check(preparation(adopted)["state"] == "ready")
                        check(preparation(adopted)["operationId"] == id)
                    }
                }
                val pending = operations.map { id ->
                    save(primary, id, true)
                    var failed = false
                    try { primary.submit(stamp, owner, id, 1, "primary-native") }
                    catch (_: Exception) { failed = true }
                    check(failed) { "Expected interrupted submission for $id" }
                    if (id == "native-local-write-loss") check(readonly != null) { "Expected real file write refusal" }
                    val saved = row(primary, id)
                    check(saved["frozen"] == true && saved["uncertain"] == true)
                    check(preparation(saved)["state"] == "ready")
                    val content = FirstSendDraftStore(directory).attachment(scope, id, "original-file").second
                    check(content.contentEquals("Original bytes for $id".toByteArray()))
                    readonly?.let { (file, permissions) -> Files.setPosixFilePermissions(file.toPath(), permissions) }
                    readonly = null
                    mapOf("id" to id, "session" to preparation(saved)["sessionId"])
                }
                check(lost)
                for (id in operations) check(calls.count { it["path"] == "/api/conversation-submissions/$id/dispatch" } == 1)
                publish(root, "before-restart", mapOf("operations" to pending, "calls" to calls))
            } else {
                val recovered = operations.map { id ->
                    val before = row(primary, id)
                    check(before["uncertain"] == true)
                    val result = primary.submit(stamp, owner, id, null, "primary-native")
                    check(preparation(result)["state"] == "admitted")
                    val session = preparation(result)["sessionId"] as String
                    check(session == preparation(before)["sessionId"])
                    val other = secondary.check(stamp, owner, id)
                    check(preparation(other) == preparation(result))
                    check(FirstSendDraftStore(directory).attachment(scope, id, "original-file").second.contentEquals("Original bytes for $id".toByteArray()))
                    check(!secondDirectory.walkTopDown().any { it.name.startsWith("blob-") })
                    mapOf("id" to id, "session" to session, "command" to obj(preparation(result)["messageAdmission"])["commandId"])
                }
                check(calls.all { it["method"] == "GET" })
                save(primary, "revoked-new", false)
                publish(root, "recovered", mapOf("operations" to recovered))
                marker(root, "revoked")
                val beforeRevocation = row(primary, "revoked-new")
                for (id in listOf(operations.first(), "revoked-new")) {
                    try { primary.submit(stamp, owner, id, 1, "primary-native"); error("Revoked token must be refused") }
                    catch (error: ApiException) { check(error.status == 401) }
                }
                check(row(primary, "revoked-new") == beforeRevocation)
                for (id in operations) check(preparation(secondary.check(stamp, owner, id))["state"] == "admitted")
                check(calls.all { it["method"] == "GET" })
                check(calls.count { it["status"] == 401 } == 2)
                publish(root, "result", mapOf("operations" to recovered, "calls" to calls, "revokedRefused" to true))
            }
        } finally {
            readonly?.let { (file, permissions) -> Files.setPosixFilePermissions(file.toPath(), permissions) }
            client.connectionPool.evictAll()
            client.dispatcher.executorService.shutdown()
        }
    }
    private suspend fun compete(phase: String, root: File, native: NativeFirstSend, api: PircApi, calls: MutableList<Map<String, Any>>) {
        val expected = linkedMapOf("race-stop" to "stopped", "race-delete" to "cancelled", "race-admit" to "admitted")
        val results = mutableListOf<Map<String, Any?>>()
        for ((id, state) in expected) {
            if (phase == "compete") {
                val held = marker(root, "held-$id")
                val found = FirstSendApi(api).request("GET", "/api/conversation-submissions/$id", owner)!!.jsonObject.getValue("preparation").jsonObject
                val session = found.getValue("sessionId").jsonPrimitive.content
                val adopted = native.adopt(stamp, owner, session)
                check(preparation(adopted)["state"] == "ready")
                check(preparation(adopted)["operationId"] == id)
                try {
                    native.submit(stamp, owner, id, null, "native-competitor")
                    error("A competing client must not silently take Web control")
                } catch (error: ApiException) { check(error.status == 409) }
                check(calls.none { it["path"] == "/api/conversation-submissions/$id/dispatch" })
                val generation = native.takeControl(stamp, owner, id, "native-competitor")
                check(generation > held.getValue("generation").jsonPrimitive.long)
                when (id) {
                    "race-stop" -> {
                        val stopped = native.stop(stamp, owner, id, "native-competitor")
                        check(obj(preparation(stopped)["messageAdmission"])["stopConfirmed"] == true)
                        val boundary = calls.size
                        native.stop(stamp, owner, id, "native-competitor")
                        check(calls.drop(boundary).all { it["method"] == "GET" })
                    }
                    "race-delete" -> {
                        try { native.cancel(stamp, owner, id); error("Accepted deletion requires confirmation") }
                        catch (error: ApiException) { check(error.status == 409 && error.code == "confirmation_required") }
                        check(preparation(native.check(stamp, owner, id))["state"] == "ready")
                        native.cancel(stamp, owner, id, deleteAccepted = true)
                    }
                    "race-admit" -> native.submit(stamp, owner, id, null, "native-competitor")
                }
            }
            val result = native.check(stamp, owner, id)
            val prep = preparation(result)
            check(prep["state"] == state) { "Unexpected state for $id: ${prep["state"]}" }
            if (id == "race-delete") {
                check(obj(result)["message"] == "" && (obj(result)["files"] as List<*>).isEmpty())
            } else check(obj(result)["message"] == "First message $id")
            if (id == "race-stop") check(obj(prep["messageAdmission"])["stopConfirmed"] == true)
            val summary = mapOf("id" to id, "session" to prep["sessionId"], "state" to state,
                "command" to (prep["messageAdmission"] as? Map<*, *>)?.get("commandId"))
            results += summary
            if (phase == "compete") publish(root, "release-$id", summary)
        }
        check(!File(root, "primary").walkTopDown().any { it.name.startsWith("blob-") })
        if (phase == "compete-recover") check(calls.all { it["method"] == "GET" })
        publish(root, if (phase == "compete") "native-races-done" else "native-race-result", mapOf("operations" to results, "calls" to calls))
    }

}
