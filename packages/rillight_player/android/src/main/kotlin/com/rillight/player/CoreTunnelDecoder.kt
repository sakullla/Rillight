package com.rillight.player

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import android.view.Surface
import java.nio.ByteBuffer

/** FFmpeg owns demuxing and audio decoding; this sink owns tunneled video only. */
internal class CoreTunnelFactory(private val audioSession: Int) {
    fun open(surface: Surface, width: Int, height: Int, profile: Int, level: Int,
             csd: ByteBuffer, config: ByteBuffer, rate: Int): CoreTunnelDecoder? {
        if (audioSession <= 0 || !surface.isValid) return null
        var codec: MediaCodec? = null
        return try {
            val format = MediaFormat.createVideoFormat("video/dolby-vision", width, height)
            format.setInteger(MediaFormat.KEY_PROFILE, profile)
            if (level > 0) format.setInteger(MediaFormat.KEY_LEVEL, level)
            format.setByteBuffer("csd-0", csd)
            format.setByteBuffer("csd-2", config)
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 8 * 1024 * 1024)
            format.setInteger(MediaFormat.KEY_OPERATING_RATE, rate.coerceIn(1, 240))
            format.setFeatureEnabled(MediaCodecInfo.CodecCapabilities.FEATURE_TunneledPlayback, true)
            format.setInteger("audio-session-id", audioSession)
            val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(format)
                ?: return null
            codec = MediaCodec.createByCodecName(name)
            codec.configure(format, surface, null, 0)
            CoreTunnelDecoder(codec).also { it.start() }
        } catch (_: Exception) {
            runCatching { codec?.release() }
            null
        }
    }

    companion object {
        fun supportedProfiles(): Int = runCatching {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .filter { !it.isEncoder && it.supportedTypes.contains("video/dolby-vision") }
                .map { it.getCapabilitiesForType("video/dolby-vision") }
                .filter { it.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_TunneledPlayback) }
                .flatMap { it.profileLevels.toList() }
                .fold(0) { bits, profile -> bits or profile.profile }
        }.getOrDefault(0)
    }
}

/** One instance per timeline; callbacks never enter the core or retain a native pointer. */
internal class CoreTunnelDecoder(private val codec: MediaCodec) {
    @Volatile private var closed = false
    @Volatile private var renderedUs = -1L
    @Volatile private var ended = false

    fun start() {
        codec.setOnFrameRenderedListener({ _, pts, _ ->
            if (!closed) {
                if (pts == Long.MAX_VALUE) ended = true
                else if (pts >= 0) renderedUs = maxOf(renderedUs, pts)
            }
        }, Handler(Looper.getMainLooper()))
        codec.start()
    }

    /** 1 accepted, 0 backpressure, -1 rejected; the caller retains unaccepted input. */
    fun queue(bytes: ByteBuffer?, ptsUs: Long): Int = try {
        if (closed) -1 else {
            val index = codec.dequeueInputBuffer(0)
            if (index < 0) 0 else {
                val input = codec.getInputBuffer(index) ?: throw IllegalStateException("No codec input")
                input.clear()
                val size = bytes?.remaining() ?: 0
                require(size <= input.remaining())
                if (bytes != null) input.put(bytes)
                codec.queueInputBuffer(index, 0, size, ptsUs.coerceAtLeast(0),
                    if (bytes == null) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0)
                1
            }
        }
    } catch (_: Exception) { -1 }

    fun rendered(): Long = renderedUs
    fun drained(): Boolean = ended

    fun close() {
        closed = true
        runCatching { codec.setOnFrameRenderedListener(null, null) }
        try { codec.stop() } finally { codec.release() }
    }
}
