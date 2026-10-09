package com.rillight.player

import android.view.Surface

internal class CoreAudioFrame(
    val session: Long,
    val timeline: Long,
    val ptsUs: Long,
    val bytes: ByteArray,
    val channels: Int = 2,
    val sampleCount: Int = 0,
    val delivery: Int = 0,
    val passthrough: Boolean = false,
    val codec: Int = 0,
)

internal class CoreVideoOverlay(
    val x: Int, val y: Int, val width: Int, val height: Int,
    val videoWidth: Int, val videoHeight: Int, val bytes: ByteArray,
)

/** JNI calls use the versioned core ABI; the wrapper never owns a decoded frame. */
internal object CoreNative {
    init { System.loadLibrary("rillight_android_core") }

    external fun abiVersion(): Int
    external fun hasDecoder(name: String): Boolean
    external fun create(factory: CoreIoFactory): Long
    external fun destroy(handle: Long)
    external fun configureHardware(handle: Long, preferredHardware: Int, allowSoftwareFallback: Boolean): Int
    external fun configureTunnel(handle: Long, factory: CoreTunnelFactory?, profiles: Int): Int
    external fun configureExternalAudioSpeed(handle: Long, enabled: Boolean): Int
    external fun configureAudioSink(handle: Long, channels: Int, accepted: Int, atmos: Boolean): Int
    external fun videoOutputSize(handle: Long, width: Int, height: Int): Int
    external fun outputSurface(handle: Long, surface: Surface?, doviProfiles: Int): Int
    external fun takeVideoOverlay(handle: Long): CoreVideoOverlay?
    external fun open(handle: Long, url: String, positionUs: Long, operation: Long): Int
    external fun play(handle: Long, playing: Boolean, operation: Long): Int
    external fun seek(handle: Long, positionUs: Long, operation: Long): Int
    external fun speed(handle: Long, speed: Double, operation: Long): Int
    external fun selectAudio(handle: Long, stream: Int, operation: Long): Int
    external fun subtitlePresentation(handle: Long, session: Long,
        displayWidth: Double, displayHeight: Double, fontSize: Double,
        userScale: Double, originalAss: Boolean,
        safeHorizontal: Double, safeVertical: Double): Int
    external fun selectSubtitle(handle: Long, stream: Int, operation: Long): Int
    external fun addSubtitle(handle: Long, url: String, operation: Long): Int
    external fun snapshot(handle: Long): LongArray?
    external fun trackCount(handle: Long): Int
    /** Selected MP4/MOV track IDs, or -1 where the container identity is unknown. */
    external fun containerTrackIds(handle: Long): IntArray?
    external fun track(handle: Long, ordinal: Int): IntArray?
    external fun trackLanguage(handle: Long, ordinal: Int): String?
    external fun takeAudio(handle: Long): CoreAudioFrame?
    /** Returns PTS, geometry, SAR, rotation, session, timeline, transfer and primaries after post. */
    external fun renderVideo(handle: Long, surface: Surface, hdrDisplaySupported: Boolean): LongArray?
    external fun releaseColorRenderer()
    external fun videoFrameRate(handle: Long): Double
    external fun outputFrameRate(handle: Long): Double
    external fun configureEnhancement(
        handle: Long,
        interpolation: Int,
        anime4k: Int,
        superResolution: Int,
        denoise: Int,
        sharpen: Int,
        acceptLeaveNativeDolby: Int,
        displayRefreshHz: Int,
    ): Int

    external fun retryEnhancement(
        handle: Long,
        interpolation: Int,
        anime4k: Int,
        superResolution: Int,
        denoise: Int,
        sharpen: Int,
        acceptLeaveNativeDolby: Int,
        displayRefreshHz: Int,
    ): Int
    external fun noteFrameDeadline(handle: Long, met: Int, monotonicUs: Long): Int
    /** Nineteen status ints, matching RillightCoreEnhancementStatus after struct_size. */
    external fun enhancementStatus(handle: Long): IntArray?
    external fun reportAudio(handle: Long, session: Long, timeline: Long, queuedEndPtsUs: Long, remainingMediaDelayUs: Long): Int
    external fun reportAudioUnavailable(handle: Long, session: Long, timeline: Long): Int
    external fun reportDrained(handle: Long, session: Long, timeline: Long): Int
}
