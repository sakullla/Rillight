package com.rillight.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreAudioRouteTest {
    @Test fun routeRefreshCannotReenableARejectedFormatOnTheSameRoute() {
        val reported = AudioSinkCapability(6, 31, true)
        assertEquals(AudioSinkCapability(6, 30, false), reported.withoutFormats(1))
        assertEquals(AudioSinkCapability(6, 29, true), reported.withoutFormats(2))
        assertEquals(AudioSinkCapability(6, 0, false), reported.withoutFormats(31))
        assertEquals(reported, reported.withoutFormats(0))
    }

    @Test fun homeTheaterFormatsRequireBothRouteAndDirectSupport() {
        val formats = mapOf(4 to 5, 8 to 7, 16 to 8)
        val sink = RouteDevice(1, 8, setOf(5, 6, 7, 8, 14, 18))
        val all = routeCapability(listOf(sink), setOf(1), 18, 14, 6, formats) { true }
        assertEquals(31, all.accept)
        val limited = routeCapability(listOf(sink), setOf(1), 18, 14, 6, formats) { it == 5 || it == 7 }
        assertEquals(12, limited.accept)
        assertFalse(limited.atmos)
        val stereo = RouteDevice(2, 2, setOf(5))
        val shared = routeCapability(listOf(sink, stereo), setOf(1, 2), 18, 14, 6, formats) { true }
        assertEquals(4, shared.accept)
        assertEquals(2, shared.channels)
        assertFalse(shared.atmos)
    }

    @Test fun ordinaryEac3DoesNotRequireOrClaimAtmos() {
        val sink = RouteDevice(1, 6, setOf(6))
        val capability = routeCapability(listOf(sink), setOf(1), 18, 14, 6) { it == 6 }
        assertEquals(1, capability.accept)
        assertFalse(capability.atmos)
        val rejected = routeCapability(listOf(sink), setOf(1), 18, 14, 6) { false }
        assertEquals(0, rejected.accept)
    }

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
