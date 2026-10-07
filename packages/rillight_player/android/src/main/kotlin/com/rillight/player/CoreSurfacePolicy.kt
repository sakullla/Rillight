package com.rillight.player

/** This firmware's YUV SurfaceView composition blacks out the entire Flutter window.
 * Keep the workaround restricted to verified SDR streams; HDR still needs its native layer. */
internal fun coreUseTextureVideo(hardware: String, model: String, sdk: Int,
                                 videoRanges: List<String?>): Boolean =
    hardware.equals("amlogic", ignoreCase = true) && model == "Box R 4K Plus" && sdk == 30 &&
        videoRanges.isNotEmpty() && videoRanges.all { it?.trim().equals("SDR", ignoreCase = true) }

/** FFmpeg/ISO color enums; unidentified color stays on the native surface. */
internal fun coreDecodedVideoRange(transfer: Long, primaries: Long): String? = when {
    transfer == 16L || transfer == 18L || primaries == 9L -> "HDR"
    transfer in setOf(1L, 4L, 5L, 6L, 7L, 13L, 14L, 15L) -> "SDR"
    else -> null
}
