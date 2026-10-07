package com.rillight.player

/** Compares the ABI 10 output region of a core snapshot, not playback position. */
internal object CoreOutputWatch {
    const val outputStart = 17
    const val outputEnd = 35
    const val reasonStart = 10
    const val reasonEnd = 14

    fun changed(
        previousSnap: LongArray?,
        snap: LongArray,
        previousReasons: IntArray?,
        reasons: IntArray?,
    ): Boolean {
        if (previousSnap == null) return true
        if (!same(previousSnap, snap, outputStart, outputEnd)) return true
        return !same(previousReasons, reasons, reasonStart, reasonEnd)
    }

    private fun same(previous: LongArray, next: LongArray, start: Int, end: Int): Boolean {
        if (previous.size <= end || next.size <= end) return previous.contentEquals(next)
        for (index in start..end) {
            if (previous[index] != next[index]) return false
        }
        return true
    }

    private fun same(previous: IntArray?, next: IntArray?, start: Int, end: Int): Boolean {
        if (previous == null && next == null) return true
        if (previous == null || next == null) return false
        for (index in start..end) {
            if ((previous.getOrNull(index) ?: 0) != (next.getOrNull(index) ?: 0)) return false
        }
        return true
    }
}

/** Monotonic id for one output sample. Position changes do not advance it. */
internal class OutputEpoch {
    var epoch: Long = 0
        private set
    var snap: LongArray? = null
        private set
    var reasons: IntArray? = null
        private set

    fun observe(current: LongArray?, currentReasons: IntArray?): Long {
        if (current == null) return epoch
        if (!CoreOutputWatch.changed(snap, current, reasons, currentReasons)) return epoch
        epoch += 1
        snap = current.copyOf()
        reasons = currentReasons?.copyOf()
        return epoch
    }
}
