package com.rillight.player

import org.junit.Assert.*
import org.junit.Test

class CoreSurfacePolicyTest {
    @Test fun decodedColorDoesNotMistakeHdrOrUnknownForSdr() {
        assertEquals("SDR", coreDecodedVideoRange(1, 1))
        assertEquals("SDR", coreDecodedVideoRange(6, 6))
        assertEquals("HDR", coreDecodedVideoRange(16, 9))
        assertEquals("HDR", coreDecodedVideoRange(18, 9))
        assertEquals("HDR", coreDecodedVideoRange(1, 9))
        assertNull(coreDecodedVideoRange(2, 2))
    }
    @Test fun verifiedFirmwareUsesTextureForSdrOnly() {
        assertTrue(coreUseTextureVideo("amlogic", "Box R 4K Plus", 30, listOf("SDR")))
        for (ranges in listOf(emptyList(), listOf(null), listOf("HDR"), listOf("SDR", "HDR")))
            assertFalse(coreUseTextureVideo("amlogic", "Box R 4K Plus", 30, ranges))
    }
    @Test fun otherDevicesRetainNativeSurface() {
        assertFalse(coreUseTextureVideo("other", "Box R 4K Plus", 30, listOf("SDR")))
        assertFalse(coreUseTextureVideo("amlogic", "other", 30, listOf("SDR")))
        assertFalse(coreUseTextureVideo("amlogic", "Box R 4K Plus", 31, listOf("SDR")))
    }
}
