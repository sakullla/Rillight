package com.rillight.player

/** Activity presentation facts with separately bound media readiness and commands. */
internal class PhonePipPolicy {
    var session = ""; private set
    var enabled = false
    var ready = false
    var playing = false
    var foreground = true
    var entering = false
    var active = false
    var returning = false
    var blocked = false
    var revision = 0L; private set
    private var mediaBound = false
    fun bind(token: String) {
        if (session == token && mediaBound) return
        session = token; ready = false; playing = false; mediaBound = token.isNotEmpty()
        // Activity presentation and stop/lock facts outlive a decoder. Rebind
        // media identity without inventing another mode=true callback.
        entering = false
        if (!enabled || blocked) { active = false; returning = false }
        revision++
    }
    fun eligible(supported: Boolean, manual: Boolean) = supported && enabled &&
        session.isNotEmpty() && mediaBound && ready && !blocked && (manual || playing)
    fun canOpenMedia() = enabled && !blocked && (foreground || retainsPlayback())
    fun retainsPlayback() = enabled && !blocked && (active || entering || returning)
    fun request(supported: Boolean, manual: Boolean): Long? {
        if (!eligible(supported, manual)) return null
        entering = true; returning = false
        return ++revision
    }
    fun pauseForSystemAutoEnter(supported: Boolean): Long? {
        foreground = false
        return if (!retainsPlayback() && eligible(supported, false)) request(true, false) else null
    }
    fun mode(value: Boolean) {
        returning = !value && active && !foreground
        active = value; entering = false; revision++
    }
    fun expire(request: Long) {
        if (request == revision && !active) { entering = false; revision++ }
    }
    fun mediaStopped() {
        ready = false; playing = false; mediaBound = false
        entering = false; revision++
    }
    fun confirmActiveWindow() {
        if (enabled && !blocked && !returning && (active || entering)) { active = true; entering = false }
    }
    fun mediaFailedOrEnded() {
        ready = false; playing = false
        if (entering && !active) { entering = false; revision++ }
    }
    fun acceptsWindowGeometry(token: String) = token == session
    fun acceptsEvent(token: String) = token == session && mediaBound
    fun retire() {
        enabled = false; ready = false; playing = false; mediaBound = false
        entering = false; active = false; returning = false; revision++
        // Caller-owned stop is not an Activity pause/lock fact.
    }
    fun suspend() {
        entering = false; active = false; returning = false; playing = false; ready = false; blocked = true; mediaBound = false; revision++
    }
    fun resume() {
        foreground = true; returning = false; blocked = false
        // Foreground is a fact, not a new request. A denied in-flight entry's
        // existing bounded timeout must still expire after transient resume.
    }
    fun current(token: String, request: Long) = token == session && request == revision
    fun accepts(token: String) = token == session && mediaBound && enabled && ready && !blocked
}
