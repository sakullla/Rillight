package com.rillight.player

import android.view.Surface

internal class CoreAudioFrame(
    val session: Long,
    val timeline: Long,
    val ptsUs: Long,
    val bytes: ByteArray,
)

/** JNI calls use the versioned core ABI; the wrapper never owns a decoded frame. */
internal object CoreNative {
    init { System.loadLibrary("rillight_android_core") }

    external fun abiVersion(): Int
    external fun create(factory: CoreIoFactory): Long
    external fun destroy(handle: Long)
    external fun open(handle: Long, url: String, operation: Long): Int
    external fun play(handle: Long, playing: Boolean, operation: Long): Int
    external fun seek(handle: Long, positionUs: Long, operation: Long): Int
    external fun speed(handle: Long, speed: Double, operation: Long): Int
    external fun selectAudio(handle: Long, stream: Int, operation: Long): Int
    external fun selectSubtitle(handle: Long, stream: Int, operation: Long): Int
    external fun addSubtitle(handle: Long, url: String, operation: Long): Int
    external fun snapshot(handle: Long): LongArray?
    external fun trackCount(handle: Long): Int
    external fun track(handle: Long, ordinal: Int): IntArray?
    external fun trackLanguage(handle: Long, ordinal: Int): String?
    external fun takeAudio(handle: Long): CoreAudioFrame?
    /** Returns PTS, geometry, SAR, rotation, session and timeline after Surface post. */
    external fun renderVideo(handle: Long, surface: Surface): LongArray?
    external fun reportAudio(handle: Long, session: Long, timeline: Long, queuedEndPtsUs: Long, remainingMediaDelayUs: Long): Int
    external fun reportAudioUnavailable(handle: Long, session: Long, timeline: Long): Int
    external fun reportDrained(handle: Long, session: Long, timeline: Long): Int
}
