package com.rillight.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreQueueClockTest {
    @Test fun queueDelayUsesMediaTimeAtDoubleSpeed() {
        val clock = CoreQueueClock()
        clock.reset(120)
        assertNull(clock.snapshot(120))
        clock.submitted(1_000_000, 19_200, 19_200, 2.0)
        assertEquals(1_200_000L to 200_000L, clock.snapshot(120))
        assertFalse(clock.hasPlaybackProgress())
        assertEquals(1_200_000L to 100_000L, clock.snapshot(2_520))
        assertTrue(clock.hasPlaybackProgress())
        assertEquals(1_200_000L to 0L, clock.snapshot(4_920))
    }

    @Test fun flushedTimelineHasNoOldSampleDelay() {
        val clock = CoreQueueClock()
        clock.reset(0)
        clock.submitted(0, 19_200, 19_200, 1.0)
        clock.reset(0)
        assertFalse(clock.hasPlaybackProgress())
        assertNull(clock.snapshot(0))
        clock.submitted(5_000_000, 19_200, 19_200, 1.0)
        assertEquals(5_100_000L to 100_000L, clock.snapshot(0))
    }

    @Test fun wrapDoesNotLookLikeDeviceDrain() {
        val clock = CoreQueueClock()
        clock.reset(0xfffffff0L)
        clock.submitted(0, 384, 384, 1.0)
        assertEquals(2_000L to 2_000L, clock.snapshot(0xfffffff0L))
        assertEquals(2_000L to 1_000L, clock.snapshot(0x20L))
    }

    @Test fun unexpectedDeviceCounterResetRevokesClockHandoff() {
        val clock = CoreQueueClock()
        clock.reset(120)
        clock.submitted(0, 19_200, 19_200, 1.0)
        clock.snapshot(2_520)
        assertTrue(clock.hasPlaybackProgress())
        assertNull(clock.snapshot(0))
        assertFalse(clock.hasPlaybackProgress())
        assertTrue(clock.takeCounterReset())
        assertFalse(clock.takeCounterReset())
        assertNull(clock.snapshot(2_400))
        clock.submitted(5_000_000, 19_200, 19_200, 1.0)
        assertEquals(5_100_000L to 100_000L, clock.snapshot(0))
        assertFalse(clock.hasPlaybackProgress())
    }
}
