package com.rillight.player

/** SDR textures compose with Flutter; HDR never enters an 8-bit SDR texture. */
internal fun coreUseTextureVideo(videoRanges: List<String?>): Boolean =
    videoRanges.isNotEmpty() && videoRanges.all { it?.trim().equals("SDR", ignoreCase = true) }

/** FFmpeg/ISO color enums; unidentified color stays on the native surface. */
internal fun coreDecodedVideoRange(transfer: Long, primaries: Long): String? = when {
    transfer == 16L || transfer == 18L || primaries == 9L -> "HDR"
    transfer in setOf(1L, 4L, 5L, 6L, 7L, 13L, 14L, 15L) -> "SDR"
    else -> null
}
