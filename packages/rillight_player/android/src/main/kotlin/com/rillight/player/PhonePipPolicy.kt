package com.rillight.player

/** Pure session-bound decisions shared by Activity protection and platform UI. */
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
    fun bind(token: String) {
        if (session == token) return
        session = token; ready = false; playing = false
        entering = false; active = false; returning = false; blocked = false; revision++
    }
    fun eligible(supported: Boolean, manual: Boolean) = supported && enabled &&
        session.isNotEmpty() && ready && !blocked && (manual || playing)
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
    fun retire() {
        enabled = false; ready = false; playing = false
        entering = false; active = false; returning = false; revision++
        // Caller-owned stop is not an Activity pause/lock fact.
    }
    fun suspend() {
        entering = false; active = false; returning = false; playing = false; blocked = true; revision++
    }
    fun resume() {
        foreground = true; returning = false; blocked = false
        // Foreground is a fact, not a new request. A denied in-flight entry's
        // existing bounded timeout must still expire after transient resume.
    }
    fun current(token: String, request: Long) = token == session && request == revision
    fun accepts(token: String) = token == session && enabled && ready && !blocked
}
