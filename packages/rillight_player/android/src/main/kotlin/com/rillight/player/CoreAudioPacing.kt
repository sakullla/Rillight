package com.rillight.player

/** Raw compressed AudioTrack frames are bytes, not IEC carrier/PCM samples. */
internal fun compressedStartThreshold(
    packetBytes: Int, packetSamples: Int, sampleRate: Int, capacityBytes: Int,
): Int {
    require(packetBytes > 0 && packetSamples > 0 && sampleRate > 0 && capacityBytes > 0)
    // Keep buffer capacity for scheduling jitter, but never require seconds of
    // low-bitrate audio just to restart after an underrun. Round to whole AUs.
    val packets = (sampleRate.toLong() + 4L * packetSamples - 1) / (4L * packetSamples)
    return (packets.coerceAtLeast(1) * packetBytes).coerceIn(1, capacityBytes.toLong()).toInt()
}

/** Compressed playback-head queries make synchronous Binder/HAL calls. */
internal class CoreAudioHeadPoll {
    private var lastPollNs = Long.MIN_VALUE
    private var position = 0L

    fun reset() { lastPollNs = Long.MIN_VALUE }

    fun read(nowNs: Long, query: () -> Long): Long {
        if (lastPollNs == Long.MIN_VALUE || nowNs < lastPollNs ||
            nowNs - lastPollNs >= 10_000_000L) {
            position = query()
            lastPollNs = nowNs
        }
        return position
    }
}

/** Device enumeration allocates platform port/device lists; it is not a frame clock. */
internal class CoreAudioRoutePoll {
    private var lastPollNs = Long.MIN_VALUE
    private var devices = emptySet<Int>()

    // Routing callbacks and the feeder can arrive on different threads.
    @Synchronized fun reset() { lastPollNs = Long.MIN_VALUE; devices = emptySet() }

    @Synchronized fun read(nowNs: Long, query: () -> Set<Int>): Set<Int> {
        if (lastPollNs == Long.MIN_VALUE || nowNs < lastPollNs ||
            nowNs - lastPollNs >= 250_000_000L) {
            devices = query()
            lastPollNs = nowNs
        }
        return devices
    }
}
