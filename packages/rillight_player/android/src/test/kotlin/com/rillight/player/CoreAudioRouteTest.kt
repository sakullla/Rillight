package com.rillight.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreAudioRouteTest {
    private val hdmi = RouteDevice(1, 6, setOf(12, 14))
    private val speaker = RouteDevice(2, 2, emptySet())

    @Test fun unknownRouteDoesNotUseAnotherOutput() {
        val capability = routeCapability(listOf(hdmi, speaker), emptySet(), 12, 14) { true }
        assertEquals(2, capability.channels)
        assertEquals(0, capability.accept)
        assertFalse(capability.atmos)
    }

    @Test fun stereoRouteIgnoresHdmiCapability() {
        val capability = routeCapability(listOf(hdmi, speaker), setOf(2), 12, 14) { true }
        assertEquals(2, capability.channels)
        assertEquals(0, capability.accept)
        assertFalse(capability.atmos)
    }

    @Test fun hdmiRouteKeepsSixChannelsAndCompressedFormats() {
        val capability = routeCapability(listOf(hdmi, speaker), setOf(1), 12, 14) { true }
        assertEquals(6, capability.channels)
        assertEquals(3, capability.accept)
        assertTrue(capability.atmos)
    }

    @Test fun sharedRouteUsesTheSmallestLayoutAndCommonFormats() {
        val wide = RouteDevice(7, 8, setOf(12))
        val narrow = RouteDevice(8, 2, setOf(12, 14))
        val capability = routeCapability(listOf(wide, narrow), setOf(7, 8), 12, 14) { true }
        assertEquals(2, capability.channels)
        assertEquals(1, capability.accept)
        assertTrue(capability.atmos)
    }

    @Test fun directPlaybackFailureKeepsChannelsWithoutPassthrough() {
        val capability = routeCapability(listOf(hdmi), setOf(1), 12, 14) { false }
        assertEquals(6, capability.channels)
        assertEquals(0, capability.accept)
        assertFalse(capability.atmos)
    }
}
