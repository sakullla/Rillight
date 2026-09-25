package com.rillight.player

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack

/** AudioTrack is the only audio consumer; every queued sample belongs to one core timeline. */
internal class CoreAudioOutput {
    private val format = AudioFormat.Builder()
        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
        .setSampleRate(48_000)
        .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
        .build()
    private val track: AudioTrack
    private val clock = CoreQueueClock()

    init {
        val minimum = AudioTrack.getMinBufferSize(48_000, AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_16BIT)
        require(minimum > 0) { "AudioTrack does not support stereo PCM" }
        track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
            .setAudioFormat(format)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(maxOf(minimum * 2, 48_000 / 2 * 4))
            .build()
        require(track.state == AudioTrack.STATE_INITIALIZED) { "AudioTrack initialization failed" }
        resetClock()
    }

    fun play() { if (track.playState != AudioTrack.PLAYSTATE_PLAYING) track.play() }
    fun pause() { if (track.playState == AudioTrack.PLAYSTATE_PLAYING) track.pause() }
    fun setVolume(value: Float) { track.setVolume(value.coerceIn(0f, 1f)) }

    fun flush() {
        pause()
        track.flush()
        resetClock()
    }

    /** Nonblocking so stop/seek can retire the timeline without waiting for a full device buffer. */
    fun write(frame: CoreAudioFrame, offset: Int, playbackSpeed: Double): Int {
        if (offset >= frame.bytes.size) return 0
        val written = track.write(frame.bytes, offset, frame.bytes.size - offset,
            AudioTrack.WRITE_NON_BLOCKING)
        if (written < 0) throw IllegalStateException("AudioTrack write failed: $written")
        if (written > 0) {
            clock.submitted(frame.ptsUs, offset + written, written, playbackSpeed)
        }
        return written
    }

    /** Core ABI6 expects submitted tail PTS and remaining delay in media time. */
    fun clock(): Pair<Long, Long>? {
        val snapshot = clock.snapshot(track.playbackHeadPosition.toLong())
        // A newly started AudioTrack can wait for its prebuffer. Feeding a
        // stationary head to the core would freeze video before more audio
        // can be decoded and submitted.
        return snapshot.takeIf { clock.hasPlaybackProgress() }
    }

    fun drained(): Boolean = clock()?.second == 0L

    fun release() { track.pause(); track.flush(); track.release() }

    private fun resetClock() {
        clock.reset(track.playbackHeadPosition.toLong())
    }
}
