package com.rillight.player

/** Translate the consumed-frame counter to the hardware presentation counter. */
internal class CorePresentationClock {
    private var epochNs = 0L
    private var lastValidNs = -1L
    private var deviceFrames = 0L

    fun reset(nowNs: Long) {
        epochNs = nowNs
        lastValidNs = -1
        deviceFrames = 0
    }

    fun position(headPosition: Long, timestampFrames: Long?, timestampNs: Long?,
                 nowNs: Long, speed: Double, sampleRate: Int = 48_000): Long? {
        require(sampleRate > 0)
        val head = headPosition and 0xffffffffL
        if (timestampFrames != null && timestampNs != null &&
            timestampNs >= epochNs && timestampNs <= nowNs &&
            nowNs - timestampNs <= 500_000_000L && speed.isFinite() && speed in .5..3.0) {
            val pending = (head - timestampFrames) and 0xffffffffL
            // A future/reset counter cannot become a multi-hour device queue.
            if (pending <= 5L * sampleRate) {
                val elapsedFrames = ((nowNs - timestampNs) * (sampleRate.toDouble() / 1_000_000_000) * speed).toLong()
                deviceFrames = (pending - elapsedFrames).coerceAtLeast(0)
                lastValidNs = nowNs
            }
        }
        // A short timestamp outage must not suddenly advance video by the
        // entire hardware latency. Stop trusting the estimate after two seconds.
        if (lastValidNs < 0 || nowNs - lastValidNs > 2_000_000_000L) return null
        return (head - deviceFrames) and 0xffffffffL
    }
}
