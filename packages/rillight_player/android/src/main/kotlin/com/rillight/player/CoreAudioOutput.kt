package com.rillight.player

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRouting
import android.media.AudioTrack
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
    direct: (Int) -> Boolean,
): AudioSinkCapability {
    val selected = outputs.filter { it.id in routedIds }
    if (routedIds.isEmpty() || selected.isEmpty()) return AudioSinkCapability(2, 0, false)
    var channels = 8
    var accept = 3
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
        if (eac3Encoding in device.encodings && direct(eac3Encoding)) {
            deviceAccept = deviceAccept or 1
            deviceAtmos = true
        }
        if (trueHdEncoding in device.encodings && direct(trueHdEncoding))
            deviceAccept = deviceAccept or 2
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
    return routeCapability(outputs, routed, eac3, trueHd, ::directPlayback)
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
    private var endOfInput = false
    private var playbackSpeed = 1f
    private var volume = 1f
    private var wantPlay = false
    private var channels = 0
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

    fun routedDeviceIds(): Set<Int> {
        if (Build.VERSION.SDK_INT < 24) return emptySet()
        val id = track?.routedDevice?.id ?: return emptySet()
        return setOf(id)
    }

    fun matches(frame: CoreAudioFrame): Boolean {
        val track = track ?: return false
        return track.state == AudioTrack.STATE_INITIALIZED &&
            channels == pcmChannels(frame) &&
            encoding == encodingOf(frame) &&
            passthrough == frame.passthrough
    }

    fun ensure(frame: CoreAudioFrame): Boolean {
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
        if (track.playState != AudioTrack.PLAYSTATE_PLAYING) track.play()
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
            track.setStartThresholdInFrames(track.bufferCapacityInFrames)
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
                (frame.ptsUs.coerceAtLeast(0) + offset / 4L * 1_000_000L / 48_000L) * 1000L)
        } else track.write(frame.bytes, offset, frame.bytes.size - offset,
            AudioTrack.WRITE_NON_BLOCKING)
        if (written < 0) throw IllegalStateException("AudioTrack write failed: $written")
        if (written > 0 && frame.passthrough && offset + written >= frame.bytes.size) {
            val samples = frame.sampleCount.coerceAtLeast(1)
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
        track?.let {
            it.pause()
            it.flush()
            it.release()
        }
        track = null
    }

    private fun open(frame: CoreAudioFrame) {
        val nextChannels = pcmChannels(frame)
        val nextEncoding = encodingOf(frame)
        val nextPassthrough = frame.passthrough
        val mask = channelMask(nextChannels)
        val format = AudioFormat.Builder()
            .setEncoding(nextEncoding)
            .setSampleRate(48_000)
            .setChannelMask(mask)
            .build()
        val minimum = AudioTrack.getMinBufferSize(48_000, mask, nextEncoding)
        if (minimum <= 0) throw IllegalStateException("AudioTrack format is unavailable")
        val frameBytes = if (nextPassthrough) 1 else nextChannels * 2
        val capacity = if (nextPassthrough) maxOf(minimum, 24_576 * 2)
        else maxOf(minimum * 2, 48_000 / 2 * frameBytes)
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
        // The first track opens lazily, and route/layout changes replace it.
        // Keep a previously selected volume (including mute) on every track.
        created.setVolume(volume)
        track?.release()
        track = created
        channels = nextChannels
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

    private fun encodingOf(frame: CoreAudioFrame): Int {
        if (!frame.passthrough || Build.VERSION.SDK_INT < 29) return AudioFormat.ENCODING_PCM_16BIT
        return when (frame.codec) {
            1 -> AudioFormat.ENCODING_E_AC3_JOC
            2 -> AudioFormat.ENCODING_DOLBY_TRUEHD
            else -> AudioFormat.ENCODING_PCM_16BIT
        }
    }

    private fun channelMask(count: Int): Int = when {
        count >= 8 -> AudioFormat.CHANNEL_OUT_7POINT1_SURROUND
        count >= 6 -> AudioFormat.CHANNEL_OUT_5POINT1
        else -> AudioFormat.CHANNEL_OUT_STEREO
    }

    private fun resetClock() {
        val track = track ?: return
        clock.reset(track.playbackHeadPosition.toLong())
    }

    private fun checkedSnapshot(): Pair<Long, Long>? {
        val track = track ?: return null
        val snapshot = clock.snapshot(track.playbackHeadPosition.toLong())
        if (!clock.takeCounterReset()) return snapshot
        val wasPlaying = track.playState == AudioTrack.PLAYSTATE_PLAYING
        flush()
        if (wasPlaying) play()
        return null
    }
}
