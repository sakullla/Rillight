package com.rillight.player

import org.junit.Assert.assertEquals
import org.junit.Test

class CoreAudioPacingTest {
    @Test fun feederReusesRouteEnumerationButDeviceEventsRefreshImmediately() {
        val poll = CoreAudioRoutePoll()
        var reads = 0
        var devices = setOf(7)
        val query = { reads++; devices }
        for (millis in 0L until 1000L) {
            assertEquals(setOf(7), poll.read(millis * 1_000_000L, query))
        }
        assertEquals(4, reads)
        devices = setOf(8)
        poll.reset() // HDMI/headphone change; no wait for periodic fallback.
        assertEquals(setOf(8), poll.read(999_000_001L, query))
        assertEquals(5, reads)
        devices = emptySet()
        poll.reset() // Replaced/released AudioTrack must not reuse the old route.
        assertEquals(emptySet<Int>(), poll.read(999_000_002L, query))
        assertEquals(6, reads)
        devices = setOf(9) // Recover even if a vendor drops its route callback.
        assertEquals(setOf(9), poll.read(1_249_000_002L, query))
        assertEquals(7, reads)
    }

    @Test fun rawEac3ThresholdTracksDurationInsteadOfIecBurstCapacity() {
        // 256 kbps E-AC-3: the old 49,152-byte threshold withheld 1.536 seconds.
        // Eight 32 ms access units provide 256 ms without reducing capacity.
        assertEquals(8192, compressedStartThreshold(1024, 1536, 48000, 49152))
        assertEquals(2048, compressedStartThreshold(256, 1536, 48000, 49152))
        assertEquals(49152, compressedStartThreshold(32768, 1536, 48000, 49152))
    }

    @Test fun thresholdSupportsShortTrueHdUnitsAndOtherSampleRates() {
        assertEquals(30000, compressedStartThreshold(100, 40, 48000, 49152))
        assertEquals(800, compressedStartThreshold(100, 1536, 44100, 49152))
        assertEquals(100, compressedStartThreshold(100, 48000, 48000, 49152))
    }

    @Test fun repeatedQueueChecksShareTheHardwareReadWithoutInventingProgress() {
        val poll = CoreAudioHeadPoll()
        var reads = 0
        val query = { (++reads * 480).toLong() }
        assertEquals(480L, poll.read(0, query))
        for (now in listOf(0L, 1L, 4_000_000L, 9_999_999L))
            assertEquals(480L, poll.read(now, query))
        assertEquals(1, reads)
        assertEquals(960L, poll.read(10_000_000L, query))
        poll.reset() // seek, resume, device or speed change
        assertEquals(1440L, poll.read(10_000_001L, query))
        assertEquals(1920L, poll.read(0, query))
    }
}
