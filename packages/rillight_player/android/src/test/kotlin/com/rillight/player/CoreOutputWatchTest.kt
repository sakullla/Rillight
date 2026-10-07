package com.rillight.player

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreOutputWatchTest {
    private fun snap(kind: Long = 3, delivery: Long = 4, effective: Long = 2) =
        LongArray(36).also {
            it[9] = 50_000
            it[CoreOutputWatch.outputStart] = 8
            it[18] = kind
            it[19] = delivery
            it[25] = effective
            it[35] = 6
        }

    private fun reasons(reason: Int = 1) = IntArray(19).also {
        it[CoreOutputWatch.reasonStart] = reason
    }

    @Test fun firstSampleAndOutputOrReasonChangesAreVisible() {
        val current = snap()
        assertTrue(CoreOutputWatch.changed(null, current, null, reasons()))
        assertFalse(CoreOutputWatch.changed(current, current.copyOf().also { it[9] = 90_000 }, reasons(), reasons()))
        assertTrue(CoreOutputWatch.changed(current, snap(kind = 1), reasons(), reasons()))
        assertTrue(CoreOutputWatch.changed(current, snap(delivery = 3), reasons(), reasons()))
        assertTrue(CoreOutputWatch.changed(current, snap(effective = 0), reasons(), reasons()))
        assertTrue(CoreOutputWatch.changed(current, current, reasons(1), reasons(4)))
    }

    @Test fun missingReasonArraysDoNotRepeat() {
        val current = snap()
        assertFalse(CoreOutputWatch.changed(current, current.copyOf(), null, null))
        assertTrue(CoreOutputWatch.changed(current, current, null, reasons()))
    }
}
