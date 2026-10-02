package com.rillight.player

/** Margins in the unrotated subtitle plane; the surface rotates both together. */
internal fun subtitleCropMargins(videoWidth: Int, videoHeight: Int,
    viewportWidth: Int, viewportHeight: Int, rotation: Int): Pair<Float, Float> {
    val horizontal = if (rotation % 180 == 0) viewportWidth else viewportHeight
    val vertical = if (rotation % 180 == 0) viewportHeight else viewportWidth
    return Pair(maxOf(0f, (videoWidth - horizontal) / 2f),
        maxOf(0f, (videoHeight - vertical) / 2f))
}
