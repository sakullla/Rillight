package com.rillight.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class CorePresentationClockTest {
    @Test fun highRateOutputProjectsInItsOwnSampleUnits() {
        val clock = CorePresentationClock()
        clock.reset(1_000_000_000)
        assertEquals(35_520L, clock.position(48_000, 33_600,
            1_000_000_000, 1_020_000_000, 1.0, 96_000))
    }

    @Test fun pcmQueueIncludesHardwareLatencyBeyondTheMixer() {
        val presentation = CorePresentationClock()
        presentation.reset(1_000_000_000)
        // Mixer consumed 500 ms; hardware played only 350 ms. The timestamp
        // is 20 ms old, so extrapolate the hardware to 370 ms at the sample time.
        val head = presentation.position(24_000, 16_800, 1_000_000_000, 1_020_000_000, 1.0)
        assertEquals(17_760L, head)
        val queue = CoreQueueClock()
        queue.reset(0)
        queue.submitted(0, 192_000, 192_000, 1.0)
        assertEquals(1_000_000L to 630_000L, queue.snapshot(24_000, head))
    }

    @Test fun consumptionBeforeHardwareStartsDoesNotClaimAudibleProgress() {
        val queue = CoreQueueClock()
        queue.reset(0)
        queue.submitted(0, 96_000, 96_000, 1.0)
        assertEquals(500_000L to 500_000L, queue.snapshot(7200, 0))
        assertFalse(queue.hasPlaybackProgress())
    }

    @Test fun invalidTimestampsFallBackWithoutInventingLatency() {
        val clock = CorePresentationClock()
        clock.reset(1_000_000_000)
        assertNull(clock.position(24000, null, null, 1_020_000_000, 1.0))
        assertNull(clock.position(24000, 16800, 900_000_000, 1_020_000_000, 1.0))
        assertNull(clock.position(24000, 16800, 1_030_000_000, 1_020_000_000, 1.0))
        assertNull(clock.position(24000, 25000, 1_020_000_000, 1_020_000_000, 1.0))
        assertNull(clock.position(24000, 16800, 1_000_000_000, 1_600_000_000, 1.0))
    }

    @Test fun transientTimestampLossKeepsLastMeasuredHardwareDelay() {
        val clock = CorePresentationClock()
        clock.reset(1_000_000_000)
        assertEquals(16800L, clock.position(24000, 16800, 1_000_000_000, 1_000_000_000, 1.0))
        assertEquals(21600L, clock.position(28800, null, null, 1_100_000_000, 1.0))
        assertNull(clock.position(28800, null, null, 3_100_000_000, 1.0))
        clock.reset(4_000_000_000)
        assertNull(clock.position(0, 16800, 1_000_000_000, 4_000_000_000, 1.0))
    }

    @Test fun timestampProjectionUsesDeviceTempoAndCannotPassConsumedHead() {
        val clock = CorePresentationClock()
        clock.reset(1_000_000_000)
        assertEquals(18720L, clock.position(24000, 16800, 1_000_000_000, 1_020_000_000, 2.0))
        assertEquals(24000L, clock.position(24000, 23900, 1_000_000_000, 1_020_000_000, 2.0))
    }

    @Test fun presentationAndConsumedCountersCanStraddleWrap() {
        val clock = CorePresentationClock()
        clock.reset(1_000_000_000)
        assertEquals(0xfffffff0L, clock.position(0x20, 0xfffffff0L,
            1_000_000_000, 1_000_000_000, 1.0))
        val queue = CoreQueueClock()
        queue.reset(0xffffffe0L)
        queue.submitted(0, 384, 384, 1.0)
        queue.snapshot(0xfffffff0L)
        assertEquals(2_000L to 1_666L, queue.snapshot(0x20, 0xfffffff0L))
    }
}
