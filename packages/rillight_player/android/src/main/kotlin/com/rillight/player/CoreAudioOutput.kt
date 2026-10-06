package com.rillight.player

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.PlaybackParams
import android.os.Build

internal data class AudioSinkCapability(
    val channels: Int,
    val accept: Int,
    val atmos: Boolean,
)

/** Passthrough is claimed only when API 29 can open the compressed encoding. */
internal fun probeAudioSink(context: Context): AudioSinkCapability {
    val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    var channels = 2
    var accept = 0
    var atmos = false
    for (device in manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
        val count = device.channelCounts.maxOrNull() ?: 0
        if (count >= 8) channels = maxOf(channels, 8)
        else if (count >= 6) channels = maxOf(channels, 6)
        if (Build.VERSION.SDK_INT < 29) continue
        if (device.encodings.contains(AudioFormat.ENCODING_E_AC3_JOC) &&
            directPlayback(AudioFormat.ENCODING_E_AC3_JOC)) {
            accept = accept or 1
            atmos = true
        }
        if (device.encodings.contains(AudioFormat.ENCODING_DOLBY_TRUEHD) &&
            directPlayback(AudioFormat.ENCODING_DOLBY_TRUEHD)) {
            accept = accept or 2
        }
    }
    return AudioSinkCapability(channels, accept, atmos)
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
internal class CoreAudioOutput {
    private var track: AudioTrack? = null
    private val clock = CoreQueueClock()
    private var endOfInput = false
    private var playbackSpeed = 1f
    private var wantPlay = false
    private var channels = 0
    private var encoding = AudioFormat.ENCODING_PCM_16BIT
    private var passthrough = false
    private var bytesPerFrame = 4

    fun matches(frame: CoreAudioFrame): Boolean {
        val track = track ?: return false
        return track.state == AudioTrack.STATE_INITIALIZED &&
            channels == pcmChannels(frame) &&
            encoding == encodingOf(frame) &&
            passthrough == frame.passthrough
    }

    fun ensure(frame: CoreAudioFrame): Boolean {
        if (matches(frame)) return true
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

    fun setVolume(value: Float) { track?.setVolume(value.coerceIn(0f, 1f)) }

    fun setSpeed(value: Float) {
        require(value.isFinite() && value in .5f..3f)
        if (passthrough) {
            playbackSpeed = value
            return
        }
        if (track != null && value == playbackSpeed) return
        playbackSpeed = value
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
        if (wantPlay) track.play()
    }

    /** Nonblocking so stop/seek can retire the timeline without waiting for a full device buffer. */
    fun write(frame: CoreAudioFrame, offset: Int, playbackSpeed: Double): Int {
        if (!ensure(frame)) {
            if (frame.passthrough) return -2
            throw IllegalStateException("AudioTrack does not support the PCM layout")
        }
        val track = track ?: return 0
        if (offset >= frame.bytes.size) return 0
        endOfInput = false
        val written = track.write(frame.bytes, offset, frame.bytes.size - offset,
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
            val silence = ByteArray(track.bufferCapacityInFrames * bytesPerFrame)
            val written = track.write(silence, 0, silence.size, AudioTrack.WRITE_NON_BLOCKING)
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
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
            .setAudioFormat(format)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(capacity)
            .build()
        if (created.state != AudioTrack.STATE_INITIALIZED) {
            created.release()
            throw IllegalStateException("AudioTrack initialization failed")
        }
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
    }

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
