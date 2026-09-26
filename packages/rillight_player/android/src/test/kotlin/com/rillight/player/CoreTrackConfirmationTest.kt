package com.rillight.player

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreTrackConfirmationTest {
    private fun snapshot(state: Long, timeline: Long, audio: Long,
                         subtitle: Long) = longArrayOf(state, 1, 5, timeline, 0, 0, audio, subtitle)

    @Test fun confirmsSubtitleWhileCoreRecoversOrBuffers() {
        assertTrue(CoreTrackConfirmation.matches(snapshot(6, 12, 1, -1), 12, -1, true))
        assertTrue(CoreTrackConfirmation.matches(snapshot(5, 12, 1, 27), 12, 27, true))
    }

    @Test fun rejectsStaleTimelineAndUnconfirmedOrTerminalSelection() {
        assertFalse(CoreTrackConfirmation.matches(snapshot(6, 11, 1, 27), 12, 27, true))
        assertFalse(CoreTrackConfirmation.matches(snapshot(6, 12, 1, 27), 12, -1, true))
        assertFalse(CoreTrackConfirmation.matches(snapshot(8, 12, 1, -1), 12, -1, true))
        assertFalse(CoreTrackConfirmation.matches(snapshot(6, 12, 1, 27), 12, 27, false))
    }

    @Test fun reportsActualVideoHardwareRatherThanAnAudioCapability() {
        assertEquals(0, CoreTrackConfirmation.actualHardware(emptyList()))
        assertEquals(0, CoreTrackConfirmation.actualHardware(listOf(intArrayOf(1, 2, 0, 8, 8))))
        assertEquals(8, CoreTrackConfirmation.actualHardware(listOf(
            intArrayOf(1, 2, 0, 8, 8), intArrayOf(0, 1, 0, 8, 8))))
        assertEquals(0, CoreTrackConfirmation.actualHardware(listOf(intArrayOf(0, 1, 0, 8, 0))))
    }
}
