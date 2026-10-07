package com.rillight.player

import org.junit.Assert.*
import org.junit.Test

class CoreSurfacePolicyTest {
    @Test fun decodedColorDoesNotMistakeHdrOrUnknownForSdr() {
        assertEquals("SDR", coreDecodedVideoRange(1, 1))
        assertEquals("SDR", coreDecodedVideoRange(6, 6))
        assertEquals("HDR", coreDecodedVideoRange(16, 9))
        assertEquals("HDR", coreDecodedVideoRange(16, 2))
        assertEquals("HDR", coreDecodedVideoRange(18, 9))
        assertEquals("HDR", coreDecodedVideoRange(1, 9))
        assertNull(coreDecodedVideoRange(2, 2))
    }
    @Test fun onlyKnownSdrUsesAnSdrTexture() {
        assertTrue(coreUseTextureVideo(listOf("SDR")))
        assertTrue(coreUseTextureVideo(listOf(" sdr ")))
        for (ranges in listOf(emptyList(), listOf(null), listOf("HDR10"), listOf("HDR"), listOf("HLG"), listOf("DOVI"), listOf("SDR", "HDR")))
            assertFalse(coreUseTextureVideo(ranges))
    }
}
