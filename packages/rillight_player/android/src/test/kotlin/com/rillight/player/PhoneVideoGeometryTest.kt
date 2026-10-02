package com.rillight.player
import org.junit.Assert.assertEquals
import org.junit.Test
class PhoneVideoGeometryTest {
    @Test fun fitKeepsMarginsAndFillExcludesClippedPixels() {
        assertEquals(Pair(0f, 0f), subtitleCropMargins(360, 203, 360, 800, 0))
        assertEquals(Pair(531f, 0f), subtitleCropMargins(1422, 800, 360, 800, 0))
    }
    @Test fun quarterTurnMapsViewportToUnrotatedSubtitleCoordinates() {
        assertEquals(Pair(0f, 0f), subtitleCropMargins(800, 360, 360, 800, 90))
        assertEquals(Pair(531f, 0f), subtitleCropMargins(1422, 800, 800, 360, 270))
    }
}
