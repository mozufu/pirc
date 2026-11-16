package dev.pirc.pirc_mobile

import dev.pirc.android.core.Pairing
import java.io.File
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test

/**
 * Structural checks for the credential boundary: which code may declare a request as the app's
 * own, and that anything undeclared is page content. Behavioural checks live next to each transport.
 */
class CredentialBoundaryTest {
    private val sourceRoot = listOf(
        File("src/main/kotlin/dev/pirc"),
        File("app/src/main/kotlin/dev/pirc"),
    ).first { it.isDirectory }

    private fun sources(): Map<String, String> = sourceRoot.walkTopDown()
        .filter { it.isFile && it.extension == "kt" }
        .associate { it.name to it.readText() }

    private fun withoutComments(text: String) = text
        .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
        .lines().joinToString("\n") { it.substringBefore("//") }

    @Test fun noProductionCodeMintsAnAppInitiatedRequestAndTheBridgeCannotSelectOne() {
        val code = sources().mapValues { withoutComments(it.value) }
        // The mechanism exists for native-only callers; today nothing in main sources mints a handle.
        val minting = code.filter { (name, text) ->
            name != "RequestInitiator.kt" &&
                ("RequestInitiator.App" in text || "AppRequestAuthority" in text || ".issue(" in text)
        }.keys
        assertEquals(emptySet<String>(), minting)
        // Nothing that arrives over the bridge can select or name a trust level, and no bridge
        // method resolves a path into a credentialed request.
        val bridge = code.getValue("GatewayBridge.kt")
        assertFalse("RequestInitiator" in bridge)
        assertFalse("AppRequestAuthority" in bridge)
        assertFalse("trusted" in bridge.lowercase())
        assertFalse("appImage" in bridge)
        assertFalse("appImage" in code.getValue("GatewayRuntime.kt"))
    }

    @Test fun everyTransportDefaultsToPageContentAndGuardsTheCredential() {
        val code = sources().mapValues { withoutComments(it.value) }
        for (name in listOf("NativeDocumentTransport.kt", "NativeImageTransport.kt", "NativeScriptResourceTransport.kt")) {
            val text = code.getValue(name)
            assertTrue(name, "initiator: RequestInitiator = RequestInitiator.Content" in text)
            val attach = Regex("""\.header\("Authorization"""").findAll(text).toList()
            assertEquals(name, 1, attach.size)
            val before = text.substring(maxOf(0, attach.single().range.first - 400), attach.single().range.first)
            assertTrue("$name attaches the credential without asking the initiator", "initiator.mayCarry(pairing)" in before)
            assertTrue("$name has no one-way switch", "authorizationMayBeSent" in before)
        }
    }

    @Test fun credentialsAndRequestShapeHeadersAreOnlyBuiltByTheAppClientAndTheGuardedTransports() {
        val code = sources().mapValues { withoutComments(it.value) }
        val allowedAuthorization = setOf(
            "PircApi.kt", "NativeDocumentTransport.kt", "NativeImageTransport.kt", "NativeScriptResourceTransport.kt",
        )
        assertEquals(
            allowedAuthorization,
            code.filter { """header("Authorization"""" in it.value }.keys,
        )
        assertEquals(setOf("PircApi.kt"), code.filter { "\"X-Pirc-Management\"" in it.value }.keys)
        // REQUEST_SHAPE_HEADER is set in the app client and named nowhere that handles page content.
        assertEquals(
            setOf("PircApi.kt"),
            code.filter { "REQUEST_SHAPE_HEADER" in it.value || "\"X-Pirc-Request\"" in it.value }.keys,
        )
        // A new file that builds raw requests must be reviewed against this boundary.
        assertEquals(
            allowedAuthorization,
            code.filter { "Request.Builder()" in it.value }.keys,
        )
    }

    @Test fun handlesAreBoundToOnePairingAndRevokedTogether() {
        val authority = AppRequestAuthority()
        val gateway = Pairing("https://gateway.example.test", "token-a")
        val handle = authority.issue(gateway)
        assertTrue(handle.mayCarry(gateway))
        assertFalse(handle.mayCarry(null))
        assertFalse(handle.mayCarry(Pairing("https://gateway.example.test", "token-b")))
        assertFalse(handle.mayCarry(Pairing("https://other.example.test", "token-a")))
        assertFalse(RequestInitiator.Content.mayCarry(gateway))
        val second = authority.issue(gateway)
        authority.revokeAll()
        assertFalse(handle.mayCarry(gateway))
        assertFalse(second.mayCarry(gateway))
        assertTrue(authority.issue(gateway).mayCarry(gateway))
    }

    @Test fun cookieScopeOfThePairedOriginIsOnlyForAppInitiatedRequests() {
        val pairing = Pairing("https://gateway.example.test", "token")
        val origin = "https://gateway.example.test".toHttpUrl()
        val app = AppRequestAuthority().issue(pairing)
        val gatewayUrl = "https://gateway.example.test/api/x".toHttpUrl()
        val externalUrl = "https://elsewhere.example.test/x".toHttpUrl()
        assertFalse(cookiesMayApply(RequestInitiator.Content, pairing, origin, gatewayUrl))
        assertTrue(cookiesMayApply(app, pairing, origin, gatewayUrl))
        assertTrue(cookiesMayApply(RequestInitiator.Content, pairing, origin, externalUrl))
        // Without a pairing there is no paired origin to protect.
        assertTrue(cookiesMayApply(RequestInitiator.Content, null, null, gatewayUrl))
    }
}
