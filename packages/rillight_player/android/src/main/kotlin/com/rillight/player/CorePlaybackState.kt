package com.rillight.player

// Buffering and seeking do not change the user's play/pause intent. Reporting
// them as Pause/Unpause also wakes the controls and releases the display lock.
internal fun corePlaybackPlaying(
    state: Long,
    paused: Boolean,
    hasVideo: Boolean,
    firstVideoFrame: Boolean,
): Boolean = !paused && (state == 3L || state == 5L || state == 6L) &&
    (!hasVideo || firstVideoFrame)
