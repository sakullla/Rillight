package com.rillight.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DisplayBrightnessTest {
    @Test fun windowOverrideWins() {
        assertEquals(0.4, effectiveDisplayBrightness(0.4f, 200)!!, 0.00001)
    }

    @Test fun systemDefaultUsesSetting() {
        assertEquals(128 / 255.0, effectiveDisplayBrightness(-1f, 128)!!, 0.00001)
    }

    @Test fun missingBrightnessNeverInventsHalfScale() {
        assertNull(effectiveDisplayBrightness(-1f, -1))
        assertNull(effectiveDisplayBrightness(Float.NaN, -1))
    }
}
