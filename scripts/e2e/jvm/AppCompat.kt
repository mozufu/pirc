package dev.pirc.e2e

import dev.pirc.android.core.*
import kotlinx.coroutines.runBlocking
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * Calls the App's real API client (PircApi.kt of whichever tree this was
 * compiled with) against a running Gateway, one operation per line:
 *   OP|<name>|OK
 *   OP|<name>|FAIL|<http status>|<code>|<message>
 * Compiled by scripts/e2e/jvm.mjs; not part of the App.
 * args: gateway token sessionId projectId proposalId workspaceId
 */
object AppCompat {
    private val png = byteArrayOf(
        0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1f, 0x15, 0xc4.toByte(), 0x89.toByte(),
        0, 0, 0, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c.toByte(), 0x63, 0x60, 0, 0, 0, 0, 2, 0, 1, 0, 5,
        0xfe.toByte(), 2, 0xfe.toByte(), 0, 0, 0, 0, 0x49, 0x45, 0x4e, 0x44, 0xae.toByte(), 0x42, 0x60, 0x82.toByte(),
    )

    @JvmStatic fun main(args: Array<String>) = runBlocking {
        val (gateway, token, sessionId, projectId, proposalId, workspaceId) = args.toList().let {
            require(it.size == 6) { "gateway token sessionId projectId proposalId workspaceId" }
            Six(it[0], it[1], it[2], it[3], it[4], it[5])
        }
        // Only fixture routing is substituted (the Host the proxy would present); the
        // device bearer, headers and bodies are exactly what PircApi builds.
        val client = defaultHttpClient().newBuilder().addInterceptor { chain ->
            chain.proceed(chain.request().newBuilder().header("Host", "test.example").build())
        }.build()
        val api = PircApi(Pairing(gateway, token), client)
        suspend fun op(name: String, block: suspend () -> Unit) {
            try {
                block()
                println("OP|$name|OK")
            } catch (error: ApiException) {
                println("OP|$name|FAIL|${error.status}|${error.code}|${error.message?.replace('\n', ' ')}")
            } catch (error: Throwable) {
                println("OP|$name|FAIL|-|${error.javaClass.simpleName}|${error.message?.replace('\n', ' ')}")
            }
        }
        op("create session (JSON POST)") { api.createSession(workspaceId) }
        op("rename session (JSON PATCH)") { api.updateSession(sessionId, name = "renamed by app") }
        op("acquire control (JSON POST)") { api.acquireControl(sessionId, "e2e-app", false) }
        op("upload text file (raw POST)") { api.upload(sessionId, "hello from the app".toByteArray(), "text/plain", "app.txt") }
        op("upload image (raw POST)") { api.upload(sessionId, png, "image/png", "app.png") }
        op("project file write (raw POST)") {
            api.uploadProjectFile(projectId, "app-file.txt", "app bytes".toByteArray().toRequestBody("application/octet-stream".toMediaType()))
        }
        op("approve memory proposal (JSON POST)") { api.approveProposal(proposalId) }
        var scheduleId: String? = null
        op("create schedule (JSON POST)") {
            scheduleId = api.createSchedule(
                ScheduleInput(workspaceId, "e2e", "say hi", "0 0 1 1 *", null, "UTC", null, null, "none"),
            ).id
        }
        op("delete schedule (body-less DELETE)") { api.deleteSchedule(scheduleId ?: "missing-schedule") }
        System.out.flush()
    }

    private data class Six(val a: String, val b: String, val c: String, val d: String, val e: String, val f: String)
    private operator fun Six.component1() = a
    private operator fun Six.component2() = b
    private operator fun Six.component3() = c
    private operator fun Six.component4() = d
    private operator fun Six.component5() = e
    private operator fun Six.component6() = f
}
