package com.rillight.player

/** Converts AudioTrack's consumed PCM frames to ABI6 media-time queue delay. */
internal class CoreQueueClock {
    private var submitted = 0L
    private var headBase = 0L
    private var lastHead = 0L
    private var wraps = 0L
    private var endPtsUs = -1L
    private var speed = 1.0
    private var playbackProgressed = false
    private var counterReset = false

    fun reset(headPosition: Long) {
        val head = headPosition and 0xffffffffL
        submitted = 0
        headBase = head
        lastHead = head
        wraps = 0
        endPtsUs = -1
        speed = 1.0
        playbackProgressed = false
        counterReset = false
    }

    fun submitted(framePtsUs: Long, frameBytesWritten: Int, newBytes: Int,
                  playbackSpeed: Double) {
        require(frameBytesWritten >= 0 && newBytes >= 0 && newBytes % 4 == 0)
        submitted += newBytes / 4
        speed = playbackSpeed
        endPtsUs = framePtsUs +
            (frameBytesWritten.toDouble() / 4 / 48_000 * 1_000_000 * speed).toLong()
    }

    fun snapshot(headPosition: Long): Pair<Long, Long>? {
        if (endPtsUs < 0) return null
        val head = headPosition and 0xffffffffL
        if (head < lastHead) {
            if (lastHead > 0xf0000000L && head < 0x10000000L) wraps += 1L shl 32
            else {
                // The old device queue is no longer measurable. The caller must
                // flush it before using a new timeline or reporting a drain.
                reset(head)
                counterReset = true
                return null
            }
        }
        lastHead = head
        val consumed = (wraps + head - headBase).coerceAtLeast(0)
        if (consumed > 0) playbackProgressed = true
        val waiting = (submitted - consumed).coerceAtLeast(0)
        val mediaDelay = (waiting.toDouble() * 1_000_000 / 48_000 * speed).toLong()
        return endPtsUs to mediaDelay
    }

    fun hasPlaybackProgress(): Boolean = playbackProgressed

    fun takeCounterReset(): Boolean {
        val value = counterReset
        counterReset = false
        return value
    }
}
