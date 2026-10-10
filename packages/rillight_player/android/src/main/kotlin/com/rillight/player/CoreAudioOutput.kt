package com.rillight.player

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRouting
import android.media.AudioTrack
import android.media.AudioTimestamp
import android.media.PlaybackParams
import android.os.Build
import java.nio.ByteBuffer

internal const val AUDIO_WRITE_REJECT = -2
internal const val AUDIO_WRITE_DROP = -3

internal data class AudioSinkCapability(
    val channels: Int,
    val accept: Int,
    val atmos: Boolean,
)

internal data class RouteDevice(
    val id: Int,
    val maxChannels: Int,
    val encodings: Set<Int>,
)

internal fun AudioSinkCapability.withoutFormats(rejected: Int): AudioSinkCapability {
    val remaining = accept and rejected.inv()
    return copy(accept = remaining, atmos = atmos && remaining and 1 != 0)
}

/**
 * Only devices on the current media route count. An unknown route stays stereo
 * so a disconnected HDMI receiver cannot keep a downmix from happening.
 * Several devices on one route use the smallest layout and the shared formats.
 */
internal fun routeCapability(
    outputs: List<RouteDevice>,
    routedIds: Set<Int>,
    eac3Encoding: Int,
    trueHdEncoding: Int,
    plainEac3Encoding: Int = -1,
    otherEncodings: Map<Int, Int> = emptyMap(),
    direct: (Int) -> Boolean,
): AudioSinkCapability {
    val selected = outputs.filter { it.id in routedIds }
    if (routedIds.isEmpty() || selected.isEmpty()) return AudioSinkCapability(2, 0, false)
    var channels = 8
    var accept = 3 or otherEncodings.keys.fold(0) { mask, bit -> mask or bit }
    var atmos = true
    for (device in selected) {
        val target = when {
            device.maxChannels >= 8 -> 8
            device.maxChannels >= 6 -> 6
            else -> 2
        }
        channels = minOf(channels, target)
        var deviceAccept = 0
        var deviceAtmos = false
        if (plainEac3Encoding in device.encodings && direct(plainEac3Encoding))
            deviceAccept = deviceAccept or 1
        if (eac3Encoding in device.encodings && direct(eac3Encoding)) {
            deviceAccept = deviceAccept or 1
            deviceAtmos = true
        }
        if (trueHdEncoding in device.encodings && direct(trueHdEncoding))
            deviceAccept = deviceAccept or 2
        for ((bit, encoding) in otherEncodings) {
            if (encoding in device.encodings && direct(encoding)) deviceAccept = deviceAccept or bit
        }
        accept = accept and deviceAccept
        atmos = atmos && deviceAtmos
    }
    if (accept and 1 == 0) atmos = false
    return AudioSinkCapability(channels.coerceAtLeast(2), accept, atmos)
}

/** Passthrough is claimed only when API 29 can open the compressed encoding. */
internal fun probeAudioSink(context: Context, routedDeviceIds: Set<Int> = emptySet()): AudioSinkCapability {
    val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
        .build()
    val routed = when {
        routedDeviceIds.isNotEmpty() -> routedDeviceIds
        Build.VERSION.SDK_INT >= 31 ->
            manager.getAudioDevicesForAttributes(attributes).map { it.id }.toSet()
        else -> emptySet()
    }
    val outputs = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map { device ->
        RouteDevice(device.id, device.channelCounts.maxOrNull() ?: 0, device.encodings.toSet())
    }
    val eac3 = if (Build.VERSION.SDK_INT >= 28) AudioFormat.ENCODING_E_AC3_JOC else -1
    val trueHd = if (Build.VERSION.SDK_INT >= 25) AudioFormat.ENCODING_DOLBY_TRUEHD else -1
    // Retain DTS/DTS-HD's existing decoded PCM path. On the tested HDMI route,
    // direct support and successful writes still produced no physical sound.
    // Do not enable that experimental route as part of the E-AC-3 fix.
    return routeCapability(outputs, routed, eac3, trueHd,
        AudioFormat.ENCODING_E_AC3, mapOf(4 to AudioFormat.ENCODING_AC3), ::directPlayback)
}

// Keep native RillightCorePassthroughKind values explicit. Compressed bytes
// must never silently use PCM when a new/unsupported kind crosses the ABI.
internal fun coreAudioEncoding(passthrough: Boolean, codec: Int, api: Int): Int? {
    if (!passthrough) return AudioFormat.ENCODING_PCM_16BIT
    if (api < 29) return null
    return when (codec) {
        1 -> AudioFormat.ENCODING_E_AC3_JOC
        2 -> AudioFormat.ENCODING_DOLBY_TRUEHD
        3 -> AudioFormat.ENCODING_E_AC3
        4 -> AudioFormat.ENCODING_AC3
        5 -> AudioFormat.ENCODING_DTS
        6 -> AudioFormat.ENCODING_DTS_HD
        else -> null
    }
}

internal fun coreAudioAcceptBit(codec: Int): Int = when (codec) {
    1, 3 -> 1
    2 -> 2
    4 -> 4
    5 -> 8
    6 -> 16
    else -> 0
}

private fun directPlayback(encoding: Int): Boolean {
    if (Build.VERSION.SDK_INT < 29) return false
    val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
        .build()
    val masks = intArrayOf(
        AudioFormat.CHANNEL_OUT_5POINT1,
        AudioFormat.CHANNEL_OUT_STEREO,
        AudioFormat.CHANNEL_OUT_7POINT1_SURROUND,
    )
    return masks.any { mask ->
        val format = AudioFormat.Builder()
            .setEncoding(encoding)
            .setSampleRate(48_000)
            .setChannelMask(mask)
            .build()
        AudioTrack.isDirectPlaybackSupported(format, attributes)
    }
}

/** AudioTrack is the only audio consumer; every queued sample belongs to one core timeline. */
internal class CoreAudioOutput(val tunneled: Boolean = false) {
    private var track: AudioTrack? = null
    private val clock = CoreQueueClock()
    private val presentationClock = CorePresentationClock()
    private val timestamp = AudioTimestamp()
    private val headPoll = CoreAudioHeadPoll()
    private val routePoll = CoreAudioRoutePoll()
    private var startThreshold = 1
    private var timestampAvailable = false
    private var lastTimestampPollNs = 0L
    private var hardwareClockActive = false
    private var hardwareDelayUs = 0L
    private var endOfInput = false
    private var playbackSpeed = 1f
    private var volume = 1f
    private var wantPlay = false
    private var channels = 0
    private var sampleRate = 48_000
    private var encoding = AudioFormat.ENCODING_PCM_16BIT
    private var passthrough = false
    private var bytesPerFrame = 4
    private var onRoute: (() -> Unit)? = null

    private var tunnelBuffer: ByteBuffer? = null
    private var tunnelFrame: CoreAudioFrame? = null
    val sessionId: Int get() = requireNotNull(track).audioSessionId

    init {
        // The tunnel binds its video decoder to this stable stereo PCM session.
        if (tunneled) open(CoreAudioFrame(0, 0, 0, ByteArray(0)))
    }

    fun setRouteListener(listener: (() -> Unit)?) { onRoute = listener }

    fun timingStatus(): Map<String, Any> = mapOf(
        "sinkSampleRate" to sampleRate,
        "sinkEncoding" to encoding,
        "sinkHardwareClock" to hardwareClockActive,
        "sinkHardwareDelayUs" to hardwareDelayUs,
        "sinkBufferFrames" to (track?.bufferCapacityInFrames ?: 0),
        "sinkStartThresholdFrames" to (if (Build.VERSION.SDK_INT >= 31)
            track?.startThresholdInFrames ?: 0 else 0),
        "sinkUnderruns" to (track?.underrunCount ?: 0))

    fun routedDeviceIds(refresh: Boolean = false): Set<Int> {
        if (Build.VERSION.SDK_INT < 24) return emptySet()
        val active = track ?: return emptySet()
        if (refresh) routePoll.reset()
        return routePoll.read(System.nanoTime()) {
            active.routedDevice?.id?.let { setOf(it) } ?: emptySet()
        }
    }

    fun matches(frame: CoreAudioFrame): Boolean {
        val track = track ?: return false
        return track.state == AudioTrack.STATE_INITIALIZED &&
            channels == pcmChannels(frame) &&
            sampleRate == frame.sampleRate &&
            encoding == encodingOf(frame) &&
            passthrough == frame.passthrough
    }

    fun ensure(frame: CoreAudioFrame): Boolean {
        if (encodingOf(frame) == null || frame.sampleRate <= 0 ||
            (frame.passthrough && frame.sampleCount <= 0)) return false
        if (matches(frame)) return true
        // Replacing the AudioTrack would invalidate the tunnel's session ID.
        if (tunneled) return false
        return try {
            open(frame)
            true
        } catch (error: IllegalArgumentException) {
            false
        } catch (error: IllegalStateException) {
            false
        }
    }

    fun play() {
        wantPlay = true
        val track = track ?: return
        if (track.playState != AudioTrack.PLAYSTATE_PLAYING) {
            resetPresentationClock()
            track.play()
        }
    }

    fun pause() {
        wantPlay = false
        val track = track ?: return
        if (track.playState == AudioTrack.PLAYSTATE_PLAYING) track.pause()
    }

    fun setVolume(value: Float) {
        if (!value.isFinite()) return
        volume = value.coerceIn(0f, 1f)
        track?.setVolume(volume)
    }

    fun setSpeed(value: Float) {
        require(value.isFinite() && value in .5f..3f)
        val changed = value != playbackSpeed
        playbackSpeed = value
        // Compressed AudioTrack data stays at 1x. Drop it as soon as speed leaves 1
        // so the next PCM frame can open at the requested rate.
        if (passthrough) {
            if (changed && !unitySpeed(value)) flush()
            return
        }
        if (!changed) return
        resetPresentationClock()
        val active = track ?: return
        val wasPlaying = active.playState == AudioTrack.PLAYSTATE_PLAYING
        try {
            active.playbackParams = PlaybackParams().allowDefaults()
                .setAudioFallbackMode(PlaybackParams.AUDIO_FALLBACK_MODE_FAIL)
                .setPitch(1f).setSpeed(value)
        } finally {
            // Setting a nonzero speed can resume a paused AudioTrack.
            if (!wasPlaying && active.playState == AudioTrack.PLAYSTATE_PLAYING)
                active.pause()
        }
    }

    fun flush() {
        val track = track ?: return
        if (track.playState == AudioTrack.PLAYSTATE_PLAYING) track.pause()
        track.flush()
        if (Build.VERSION.SDK_INT >= 31 && endOfInput)
            track.setStartThresholdInFrames(startThreshold)
        resetClock()
        endOfInput = false
        tunnelBuffer = null; tunnelFrame = null
        if (wantPlay) track.play()
    }

    /** Nonblocking so stop/seek can retire the timeline without waiting for a full device buffer. */
    fun write(frame: CoreAudioFrame, offset: Int, playbackSpeed: Double): Int {
        if (frame.passthrough && !unitySpeed(this.playbackSpeed)) return AUDIO_WRITE_DROP
        if (!ensure(frame)) {
            if (frame.passthrough) return AUDIO_WRITE_REJECT
            throw IllegalStateException("AudioTrack does not support the PCM layout")
        }
        val track = track ?: return 0
        if (offset >= frame.bytes.size) return 0
        endOfInput = false
        val written = if (tunneled) {
            if (tunnelFrame !== frame) {
                tunnelFrame = frame
                tunnelBuffer = ByteBuffer.allocateDirect(frame.bytes.size).apply {
                    put(frame.bytes); flip()
                }
            }
            val buffer = requireNotNull(tunnelBuffer)
            buffer.position(offset)
            track.write(buffer, buffer.remaining(), AudioTrack.WRITE_NON_BLOCKING,
                (frame.ptsUs.coerceAtLeast(0) + offset / bytesPerFrame.toLong() * 1_000_000L / sampleRate) * 1000L)
        } else track.write(frame.bytes, offset, frame.bytes.size - offset,
            AudioTrack.WRITE_NON_BLOCKING)
        if (written < 0) throw IllegalStateException("AudioTrack write failed: $written")
        if (written > 0 && frame.passthrough && offset + written >= frame.bytes.size) {
            val samples = frame.sampleCount
            clock.submittedAccessUnit(frame.ptsUs, samples, playbackSpeed)
        } else if (written > 0 && !frame.passthrough) {
            clock.submitted(frame.ptsUs, offset + written, written, playbackSpeed, bytesPerFrame)
        }
        return written
    }

    /** Core ABI6 expects submitted tail PTS and remaining delay in media time. */
    fun clock(): Pair<Long, Long>? {
        if (track == null) return null
        val snapshot = checkedSnapshot()
        return snapshot.takeIf { clock.hasPlaybackProgress() }
    }

    /** Release the start gate when a short stream ends below the prebuffer size. */
    fun finishInput() {
        val track = track ?: return
        if (checkedSnapshot() == null || clock.hasPlaybackProgress()) return
        if (Build.VERSION.SDK_INT >= 31) {
            if (track.startThresholdInFrames > 1) track.setStartThresholdInFrames(1)
        } else if (!passthrough) {
            // Before API 31 the gate is fixed at buffer capacity. Silent PCM
            // starts the device without extending the core's audible timeline.
            val eofSilence = ByteArray(track.bufferCapacityInFrames * bytesPerFrame)
            val tail = checkedSnapshot()?.first ?: return
            val written = if (tunneled) {
                val buffer = ByteBuffer.allocateDirect(eofSilence.size)
                track.write(buffer, buffer.remaining(), AudioTrack.WRITE_NON_BLOCKING, tail * 1000)
            } else track.write(eofSilence, 0, eofSilence.size,
                AudioTrack.WRITE_NON_BLOCKING)
            if (written < 0) throw IllegalStateException("AudioTrack EOF padding failed: $written")
        }
        endOfInput = true
    }

    fun drained(): Boolean {
        if (track == null) return true
        val snapshot = checkedSnapshot() ?: return true
        return clock.hasPlaybackProgress() && snapshot.second == 0L
    }

    fun release() {
        routePoll.reset()
        track?.let {
            it.pause()
            it.flush()
            it.release()
        }
        track = null
    }

    private fun open(frame: CoreAudioFrame) {
        val nextChannels = pcmChannels(frame)
        val nextEncoding = requireNotNull(encodingOf(frame))
        val nextPassthrough = frame.passthrough
        val nextRate = frame.sampleRate
        val mask = channelMask(nextChannels)
        val format = AudioFormat.Builder()
            .setEncoding(nextEncoding)
            .setSampleRate(nextRate)
            .setChannelMask(mask)
            .build()
        val minimum = AudioTrack.getMinBufferSize(nextRate, mask, nextEncoding)
        if (minimum <= 0) throw IllegalStateException("AudioTrack format is unavailable")
        val frameBytes = if (nextPassthrough) 1 else nextChannels * 2
        val capacity = if (nextPassthrough) maxOf(minimum, 24_576 * 2)
        else maxOf(minimum * 2, nextRate / 2 * frameBytes)
        val created = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                .setFlags(if (tunneled) AudioAttributes.FLAG_HW_AV_SYNC else 0).build())
            .setAudioFormat(format)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(capacity)
            .build()
        if (created.state != AudioTrack.STATE_INITIALIZED) {
            created.release()
            throw IllegalStateException("AudioTrack initialization failed")
        }
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                startThreshold = if (nextPassthrough)
                    compressedStartThreshold(frame.bytes.size, frame.sampleCount,
                        nextRate, created.bufferCapacityInFrames)
                    else created.startThresholdInFrames
                if (nextPassthrough) created.setStartThresholdInFrames(startThreshold)
            }
            // The first track opens lazily, and route/layout changes replace it.
            // Keep a previously selected volume (including mute) on every track.
            created.setVolume(volume)
        } catch (error: RuntimeException) {
            // ensure() can fall back to PCM without leaking an unowned track.
            created.release()
            throw error
        }
        track?.release()
        track = created
        routePoll.reset()
        channels = nextChannels
        sampleRate = nextRate
        encoding = nextEncoding
        passthrough = nextPassthrough
        bytesPerFrame = frameBytes
        endOfInput = false
        resetClock()
        if (!nextPassthrough && playbackSpeed != 1f) {
            val speed = playbackSpeed
            playbackSpeed = 1f
            setSpeed(speed)
        }
        if (wantPlay) created.play()
        watchRoute(created)
    }

    private fun watchRoute(created: AudioTrack) {
        if (Build.VERSION.SDK_INT < 24) return
        created.addOnRoutingChangedListener(AudioRouting.OnRoutingChangedListener {
            routePoll.reset()
            onRoute?.invoke()
        }, null)
    }

    private fun unitySpeed(value: Float) = value > 0.999f && value < 1.001f

    private fun pcmChannels(frame: CoreAudioFrame): Int {
        val count = if (frame.channels > 0) frame.channels else 2
        return when {
            count >= 8 -> 8
            count >= 6 -> 6
            else -> 2
        }
    }

    private fun encodingOf(frame: CoreAudioFrame): Int? =
        coreAudioEncoding(frame.passthrough, frame.codec, Build.VERSION.SDK_INT)

    private fun channelMask(count: Int): Int = when {
        count >= 8 -> AudioFormat.CHANNEL_OUT_7POINT1_SURROUND
        count >= 6 -> AudioFormat.CHANNEL_OUT_5POINT1
        else -> AudioFormat.CHANNEL_OUT_STEREO
    }

    private fun resetClock() {
        val track = track ?: return
        clock.reset(track.playbackHeadPosition.toLong(), sampleRate)
        resetPresentationClock()
    }

    private fun resetPresentationClock() {
        headPoll.reset()
        presentationClock.reset(System.nanoTime())
        timestampAvailable = false
        lastTimestampPollNs = 0
        hardwareClockActive = false
        hardwareDelayUs = 0
    }

    private fun checkedSnapshot(): Pair<Long, Long>? {
        val track = track ?: return null
        var nowNs = System.nanoTime()
        if (track.playState == AudioTrack.PLAYSTATE_PLAYING &&
            nowNs - lastTimestampPollNs >= 100_000_000L) {
            timestampAvailable = track.getTimestamp(timestamp)
            lastTimestampPollNs = nowNs
        }
        // Multiple queue/drain queries in one feeder iteration share a hardware
        // read; submitted sample accounting is still recomputed for every call.
        val head = if (passthrough)
            headPoll.read(nowNs) { track.playbackHeadPosition.toLong() }
            else track.playbackHeadPosition.toLong()
        nowNs = System.nanoTime()
        val presented = if (track.playState == AudioTrack.PLAYSTATE_PLAYING)
            presentationClock.position(head,
                timestamp.framePosition.takeIf { timestampAvailable },
                timestamp.nanoTime.takeIf { timestampAvailable }, nowNs, playbackSpeed.toDouble(), sampleRate)
            else null
        hardwareClockActive = presented != null
        hardwareDelayUs = if (presented == null) 0 else
            (((head - presented) and 0xffffffffL) * 1_000_000L / sampleRate)
        val snapshot = clock.snapshot(head, presented)
        if (!clock.takeCounterReset()) return snapshot
        val wasPlaying = track.playState == AudioTrack.PLAYSTATE_PLAYING
        flush()
        if (wasPlaying) play()
        return null
    }
}
