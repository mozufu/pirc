package dev.pirc.pirc_mobile

import org.junit.Assert.*
import org.junit.Test

class ContextRegistryTest {
    @Test fun childContextsRequireExplicitOpenAndCloseCannotBeReused() {
        val registry = ContextRegistry()
        registry.bindPairingStamp("stamp-a")

        assertEquals("primary", registry.requireContext().contextId)
        assertThrows(ContextRegistryException::class.java) {
            registry.requireContext("child-a")
        }

        val opened = registry.openContext("child-a", "stamp-a")
        assertTrue(registry.isCurrent(opened))
        assertSame(opened, registry.requireContext("child-a"))
        assertSame(opened, registry.closeContext("child-a"))
        assertFalse(registry.isCurrent(opened))
        assertThrows(ContextRegistryException::class.java) {
            registry.requireContext("child-a")
        }
        assertThrows(IllegalStateException::class.java) {
            registry.openContext("child-a", "stamp-a")
        }
    }

    @Test fun pairingChangePurgesContextsAndInvalidatesCapturedAsyncLeases() {
        val registry = ContextRegistry()
        registry.bindPairingStamp("stamp-a")
        val first = registry.openContext("child-a", "stamp-a")
        val second = registry.openContext("child-b", "stamp-a")
        val primaryBeforeChange = registry.requireContext()

        assertEquals(listOf(first, second), registry.bindPairingStamp("stamp-b"))
        assertFalse(registry.isCurrent(first))
        assertFalse(registry.isCurrent(second))
        assertFalse(registry.isCurrent(primaryBeforeChange))
        assertThrows(ContextRegistryException::class.java) {
            registry.requireContext("child-a")
        }
        assertThrows(ContextRegistryException::class.java) {
            registry.openContext("child-c", "stamp-a")
        }
        assertTrue(registry.isCurrent(registry.requireContext()))
    }

    @Test fun closingOneContextDoesNotInvalidateOtherContexts() {
        val registry = ContextRegistry()
        registry.bindPairingStamp("stamp-a")
        val first = registry.openContext("child-a", "stamp-a")
        val second = registry.openContext("child-b", "stamp-a")

        registry.closeContext("child-a")

        assertFalse(registry.isCurrent(first))
        assertTrue(registry.isCurrent(second))
        assertSame(second, registry.requireContext("child-b"))
    }

    @Test fun contextLeasesCarryNoCredentialAndNeverOutliveTheirAccount() {
        // A lease is identity bookkeeping only: it holds no token and confers no trust.
        val fields = ContextRegistry.Lease::class.java.declaredFields.map { it.name.lowercase() }
        assertTrue(fields.none { "token" in it || "credential" in it || "bearer" in it || "auth" in it || "trust" in it })

        val registry = ContextRegistry()
        registry.bindPairingStamp("stamp-a")
        val authority = AppRequestAuthority()
        val gateway = dev.pirc.android.core.Pairing("https://gateway.example.test", "token-a")
        val lease = registry.openContext("child-a", "stamp-a")
        val appHandle = authority.issue(gateway)

        // Unpair / pair to another server / stamp rotation: the runtime revokes handles and retires contexts.
        registry.bindPairingStamp("stamp-b")
        authority.revokeAll()
        val newGateway = dev.pirc.android.core.Pairing("https://other.example.test", "token-b")
        assertFalse(registry.isCurrent(lease))
        assertFalse(appHandle.mayCarry(gateway))
        assertFalse(appHandle.mayCarry(newGateway))
        // An expired context cannot be reopened or used to obtain anything.
        assertThrows(ContextRegistryException::class.java) { registry.requireContext("child-a") }
        assertThrows(IllegalStateException::class.java) { registry.openContext("child-a", "stamp-b") }
        assertThrows(ContextRegistryException::class.java) { registry.openContext("child-b", "stamp-a") }
        // A context that is open and current still has no way to be a credentialed initiator.
        val fresh = registry.openContext("child-c", "stamp-b")
        assertTrue(registry.isCurrent(fresh))
        assertFalse(RequestInitiator.Content.mayCarry(newGateway))
    }
}
