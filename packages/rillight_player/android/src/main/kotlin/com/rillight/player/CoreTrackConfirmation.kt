package com.rillight.player

/** A selected track is confirmed by the core even while output is buffering. */
internal object CoreTrackConfirmation {
    fun actualHardware(tracks: List<IntArray>): Int =
        tracks.firstOrNull { it.size >= 5 && it[1] == 1 }?.get(4) ?: 0

    fun matches(snapshot: LongArray?, timeline: Long, expected: Int,
                subtitle: Boolean): Boolean {
        if (snapshot == null || snapshot.size < 8) return false
        // READY through RECOVERING are live states. ENDED/FAILED cannot confirm
        // a command, even if their last selected index happens to match.
        if (snapshot[0] !in 2L..6L || snapshot[3] != timeline) return false
        return snapshot[if (subtitle) 7 else 6] == expected.toLong()
    }
}
