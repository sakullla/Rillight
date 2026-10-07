package com.rillight.player

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CorePlaybackStateTest {
    @Test fun rebufferingDoesNotPausePlaybackOrWakeControls() {
        for (state in listOf(3L, 5L, 3L, 6L, 3L)) {
            assertTrue(corePlaybackPlaying(state, false, true, true))
        }
    }

    @Test fun explicitPauseAndUnreadyVideoRemainInactive() {
        for (state in 0L..8L) {
            assertFalse(corePlaybackPlaying(state, true, true, true))
            assertFalse(corePlaybackPlaying(state, false, true, false))
        }
        for (state in listOf(0L, 1L, 2L, 4L, 7L, 8L)) {
            assertFalse(corePlaybackPlaying(state, false, true, true))
        }
    }

    @Test fun audioOnlyPlaybackDoesNotRequireAVideoFrame() {
        assertTrue(corePlaybackPlaying(3L, false, false, false))
        assertTrue(corePlaybackPlaying(5L, false, false, false))
        assertFalse(corePlaybackPlaying(4L, true, false, false))
    }
}
