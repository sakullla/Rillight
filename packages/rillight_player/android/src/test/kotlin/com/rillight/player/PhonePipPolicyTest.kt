package com.rillight.player

import org.junit.Assert.*
import org.junit.Test

class PhonePipPolicyTest {
    private fun ready() = PhonePipPolicy().apply { bind("one"); enabled = true; ready = true; playing = true }
    @Test fun activePipMediaStopBindAndReadyKeepsWindowButRevokesOldControls() {
        val p = ready(); p.foreground = false; p.mode(true)
        p.mediaStopped() // Actual plugin stop path used by controller next/open.
        assertTrue(p.active); assertTrue(p.retainsPlayback())
        assertFalse(p.accepts("one")); assertFalse(p.acceptsEvent("one"))
        assertTrue(p.acceptsWindowGeometry("one"))
        p.bind("two")
        assertTrue(p.active); assertTrue(p.retainsPlayback()); assertTrue(p.canOpenMedia())
        assertFalse(p.ready); assertFalse(p.playing)
        assertFalse(p.accepts("one")); assertFalse(p.acceptsEvent("one"))
        assertTrue(p.acceptsEvent("two"))
        assertFalse(p.acceptsWindowGeometry("one")); assertTrue(p.acceptsWindowGeometry("two"))
        p.ready = true; p.playing = true
        assertTrue(p.accepts("two")); assertTrue(p.retainsPlayback())
        assertFalse(p.foreground)
    }

    @Test fun mediaReopenDuringExpansionPreservesReturningFact() {
        val p = ready(); p.foreground = false; p.mode(true); p.mode(false)
        p.confirmActiveWindow() // A stale positive query cannot undo mode=false.
        assertFalse(p.active)
        p.mediaStopped(); p.bind("two")
        assertTrue(p.returning); assertTrue(p.retainsPlayback())
        p.resume()
        assertFalse(p.returning); assertFalse(p.retainsPlayback())
    }
    @Test fun routeExitAndScreenOffCannotBeRevivedByMediaBind() {
        val closed = ready(); closed.mode(true); closed.retire(); closed.bind("two")
        assertFalse(closed.enabled); assertFalse(closed.retainsPlayback()); assertFalse(closed.canOpenMedia())
        val locked = ready(); locked.mode(true); locked.suspend(); locked.bind("two")
        locked.confirmActiveWindow() // A stale platform mode cannot override stop/lock.
        assertTrue(locked.blocked); assertFalse(locked.retainsPlayback()); assertFalse(locked.canOpenMedia())
        assertFalse(locked.accepts("two"))
    }
    @Test fun pendingUnconfirmedEntryDoesNotGrantNewMediaBackgroundPlayback() {
        val p = ready(); p.request(true, false); p.foreground = false
        p.mediaStopped(); p.bind("two")
        assertFalse(p.entering); assertFalse(p.retainsPlayback()); assertFalse(p.canOpenMedia())
        assertFalse(p.acceptsEvent("one"))
    }
    @Test fun confirmedWindowSurvivesMediaStopBeforeDelayedModeCallback() {
        val p = ready(); p.request(true, false); p.foreground = false
        p.confirmActiveWindow(); p.mediaStopped(); p.bind("two")
        assertTrue(p.active); assertTrue(p.retainsPlayback())
        p.mediaFailedOrEnded()
        assertFalse(p.accepts("two")); assertFalse(p.playing)
        p.suspend()
        assertFalse(p.retainsPlayback())
    }

    @Test fun endedSessionRejectsPreviouslyEnabledRemoteAction() {
        val p = ready(); p.mode(true)
        assertTrue(p.accepts("one"))
        p.ready = false; p.playing = false
        assertFalse(p.accepts("one"))
    }
    @Test fun unsupportedPausedAndUnreadyNeverAutoEnter() {
        val p = ready()
        assertFalse(p.eligible(false, false))
        p.playing = false
        assertFalse(p.eligible(true, false))
        assertTrue(p.eligible(true, true))
        p.ready = false
        assertFalse(p.eligible(true, true))
    }
    @Test fun deniedEntryExpiresButAcceptedModeSurvivesTimer() {
        val p = ready()
        val request = p.request(true, false)!!
        p.foreground = false
        assertTrue(p.retainsPlayback())
        p.expire(request)
        assertFalse(p.retainsPlayback())
        val next = p.request(true, false)!!
        p.mode(true); p.expire(next)
        assertTrue(p.retainsPlayback())
    }
    @Test fun staleSessionTimerAndRemoteActionCannotChangeReplacement() {
        val p = ready()
        val old = p.request(true, false)!!
        p.bind("two"); p.ready = true
        p.request(true, true)
        p.expire(old)
        assertTrue(p.entering)
        assertFalse(p.accepts("one"))
        assertTrue(p.accepts("two"))
    }
    @Test fun pauseBeforeAutoEnterCallbackHasBoundedCurrentSessionGrace() {
        val p = ready()
        val request = p.pauseForSystemAutoEnter(true)!!
        assertTrue(p.retainsPlayback()); assertTrue(p.playing)
        p.mode(true); p.expire(request)
        assertTrue(p.active); assertTrue(p.playing)
        val denied = ready()
        val pending = denied.pauseForSystemAutoEnter(true)!!
        denied.expire(pending)
        assertFalse(denied.retainsPlayback())
        val paused = ready().apply { playing = false }
        assertNull(paused.pauseForSystemAutoEnter(true))
        assertNull(ready().pauseForSystemAutoEnter(false))
    }
    @Test fun retiringPreviousDecoderDoesNotInventForegroundLifecycleStop() {
        val p = ready(); p.retire()
        assertFalse(p.blocked)
        assertTrue(p.foreground)
        p.bind("two")
        assertFalse(p.blocked)
        assertFalse(p.retainsPlayback())
    }
    @Test fun rejectedEntryStillExpiresAfterTransientResume() {
        val p = ready()
        val pending = p.request(true, false)!!
        p.foreground = false
        p.resume()
        p.expire(pending)
        assertFalse(p.entering)
        assertFalse(p.retainsPlayback())
    }
    @Test fun api26ResumePauseModeFalseResumePreservesSessionAndPlayback() {
        val p = ready(); p.foreground = false; p.mode(true)
        p.resume() // The platform mode callback has not arrived yet.
        assertTrue(p.active); assertTrue(p.retainsPlayback())
        p.foreground = false // Transient expansion/rotation pause.
        assertTrue(p.retainsPlayback()); assertTrue(p.playing)
        p.mode(false)
        assertTrue(p.returning); assertTrue(p.retainsPlayback())
        p.resume()
        assertEquals("one", p.session)
        assertFalse(p.active); assertFalse(p.returning)
        assertTrue(p.foreground); assertTrue(p.playing); assertFalse(p.blocked)
    }
    @Test fun slowExpansionWaitsForResumeOrDefinitiveStopNotATimer() {
        val p = ready(); p.foreground = false; p.mode(true); p.mode(false)
        assertTrue(p.returning); assertTrue(p.retainsPlayback()); assertTrue(p.playing)
        p.resume()
        assertFalse(p.returning); assertFalse(p.retainsPlayback()); assertTrue(p.playing)
        p.foreground = false; p.mode(true); p.mode(false); p.suspend()
        assertFalse(p.retainsPlayback()); assertFalse(p.playing)
    }
    @Test fun stopAndScreenLockRevokeProtectionAndResumeDoesNotPlay() {
        val p = ready(); p.mode(true); p.suspend(); p.suspend()
        assertFalse(p.retainsPlayback()); assertFalse(p.accepts("one"))
        p.resume()
        assertFalse(p.playing); assertFalse(p.eligible(true, false))
    }
}
