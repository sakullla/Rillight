package com.rillight.player

import android.app.Activity
import android.app.AppOpsManager
import android.app.KeyguardManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.app.UiModeManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.util.Rational
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel

/** The sole Activity/PiP state owner; Flutter consumes complete snapshots. */
internal class PhonePipCoordinator(private val activity: Activity, private val handler: Handler,
    private val changed: (String, String, Map<String, Any>) -> Unit) {
    val policy = PhonePipPolicy()
    private var disposed = false
    private var ownerId = ""
    private var entrySession = ""
    private var owner: CorePlayback? = null
    private var geometry = emptyMap<String, Any>()
    private val appOps = activity.getSystemService(AppOpsManager::class.java)
    private var watchingPermission = false
    private val permissionListener = AppOpsManager.OnOpChangedListener { op, packageName ->
        if (op == AppOpsManager.OPSTR_PICTURE_IN_PICTURE && packageName == activity.packageName) {
            handler.post { if (!disposed) { if (!supported()) suspend() else refresh() } }
        }
    }
    private val action = "${activity.packageName}.PHONE_PIP_CONTROL"
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != action || !policy.active ||
                !policy.accepts(intent.getStringExtra("session") ?: "")) return
            val method = if (intent.getBooleanExtra("play", false)) "play" else "pause"
            owner?.command(method, emptyMap<String, Any>(), object : MethodChannel.Result {
                override fun success(result: Any?) { refresh() }
                override fun error(code: String, message: String?, details: Any?) { refresh() }
                override fun notImplemented() = Unit
            })
        }
    }
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_SCREEN_OFF) suspend()
        }
    }
    init {
        val filter = IntentFilter(action).apply { addDataScheme("rillight-pip") }
        ContextCompat.registerReceiver(activity, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        ContextCompat.registerReceiver(activity, screenReceiver,
            IntentFilter(Intent.ACTION_SCREEN_OFF), ContextCompat.RECEIVER_NOT_EXPORTED)
        if (capable()) {
            try {
                appOps?.startWatchingMode(AppOpsManager.OPSTR_PICTURE_IN_PICTURE,
                    activity.packageName, permissionListener)
                watchingPermission = appOps != null
            } catch (_: SecurityException) { }
        }
    }
    private fun locked() = activity.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked == true
    private fun capable(): Boolean {
        if (Build.VERSION.SDK_INT < 26) return false
        if (activity.getSystemService(UiModeManager::class.java)?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)) return false
        return activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }
    private fun supported(): Boolean {
        if (!capable() || locked()) return false
        val ops = activity.getSystemService(AppOpsManager::class.java)
        return ops?.checkOpNoThrow(AppOpsManager.OPSTR_PICTURE_IN_PICTURE,
            android.os.Process.myUid(), activity.packageName) == AppOpsManager.MODE_ALLOWED
    }
    fun configure(id: String, playback: CorePlayback, enabled: Boolean) {
        if (ownerId != id) { owner?.pauseForActivity(); policy.bind("") }
        ownerId = id; owner = playback; policy.bind(playback.session); policy.enabled = enabled
        policy.ready = playback.pipReady(); policy.playing = playback.pipPlaying()
        if (!enabled) { owner?.pauseForActivity(); policy.retire(); refresh(); return }
        refresh()
    }
    fun bind(id: String, token: String) { if (id == ownerId) { policy.bind(token); refresh() } }
    fun event(id: String, token: String, kind: String, value: Any) {
        if (id != ownerId || token != policy.session) return
        when (kind) {
            "firstFrame" -> policy.ready = value == true
            "playing" -> policy.playing = value == true
            "completed", "error" -> { policy.ready = false; policy.playing = false; if (policy.entering) { suspend(); return } }
            "videoGeometry" -> {
                @Suppress("UNCHECKED_CAST")
                val current = value as Map<String, Any>
                geometry = current
            }
            else -> return
        }
        refresh()
    }
    fun snapshot(): Map<String, Any> = mapOf("version" to 1, "session" to policy.session, "supported" to supported(),
        "active" to policy.active, "entering" to policy.entering, "returning" to policy.returning,
        "foreground" to policy.foreground, "retainPlayback" to policy.retainsPlayback(),
        "shouldSuspend" to (policy.blocked || (!policy.foreground && !policy.retainsPlayback())),
        "generation" to policy.revision, "geometry" to geometry,
        "core" to (owner?.presentationDiagnostics() ?: emptyMap<String, Any>()),
        "displayRect" to (owner?.videoSourceRect()?.let { listOf(it.left, it.top, it.right, it.bottom) } ?: emptyList<Int>()))
    private fun publish() { if (ownerId.isNotEmpty()) changed(ownerId, policy.session, snapshot()) }
    private fun params(): PictureInPictureParams {
        val width = (geometry["visibleWidth"] as? Number)?.toDouble() ?: 16.0
        val height = (geometry["visibleHeight"] as? Number)?.toDouble() ?: 9.0
        val ratio = (width / height.coerceAtLeast(1.0)).coerceIn(1.0 / 2.39, 2.39)
        val intent = Intent(action).setPackage(activity.packageName)
            .setData(android.net.Uri.parse("rillight-pip://${policy.session}/${!policy.playing}"))
            .putExtra("session", policy.session).putExtra("play", !policy.playing)
        val pending = PendingIntent.getBroadcast(activity, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val control = RemoteAction(Icon.createWithResource(activity,
            if (policy.playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play),
            if (policy.playing) "暂停" else "播放", if (policy.playing) "暂停" else "播放", pending).apply { isEnabled = policy.ready && !policy.blocked }
        val builder = PictureInPictureParams.Builder().setAspectRatio(Rational((ratio * 10000).toInt(), 10000))
            .setActions(listOf(control))
        val rect = owner?.videoSourceRect()
        if (rect != null && !rect.isEmpty) builder.setSourceRectHint(rect)
        if (Build.VERSION.SDK_INT >= 31) builder.setAutoEnterEnabled(policy.eligible(supported(), false))
            .setSeamlessResizeEnabled(true)
        return builder.build()
    }
    private fun awaitSystemEntry(request: Long) {
        val token = policy.session
        entrySession = token
        publish()
        handler.postDelayed({
            if (disposed || !policy.current(token, request)) return@postDelayed
            if (!activity.isInPictureInPictureMode) {
                policy.expire(request)
                if (!policy.foreground && !policy.retainsPlayback()) suspend() else publish()
            }
        }, 1500)
    }

    fun refresh() {
        if (disposed) return
        if (capable()) {
            try { activity.setPictureInPictureParams(params()) } catch (_: RuntimeException) { }
        }
        publish()
    }
    fun enter(manual: Boolean): Boolean {
        val request = policy.request(supported(), manual) ?: return false
        entrySession = policy.session
        publish()
        val accepted = try { activity.enterPictureInPictureMode(params()) } catch (_: RuntimeException) { false }
        if (!accepted) { policy.expire(request); if (!policy.foreground) suspend() else publish(); return false }
        val token = policy.session
        handler.postDelayed({
            if (disposed || !policy.current(token, request)) return@postDelayed
            if (!activity.isInPictureInPictureMode) {
                policy.expire(request)
                if (!policy.foreground && !policy.retainsPlayback()) suspend() else publish()
            }
        }, 1500)
        return true
    }
    fun userLeave() {
        if (!policy.eligible(supported(), false)) return
        // API 31+ enters through the system's preconfigured auto-enter params.
        if (Build.VERSION.SDK_INT >= 31) {
            val request = policy.request(true, false) ?: return
            entrySession = policy.session
            publish()
            val token = policy.session
            handler.postDelayed({
                if (disposed || !policy.current(token, request)) return@postDelayed
                if (!activity.isInPictureInPictureMode) {
                    policy.expire(request)
                    if (!policy.foreground && !policy.retainsPlayback()) suspend() else publish()
                }
            }, 1500)
        } else enter(false)
    }
    fun transition() {
        if (!policy.eligible(supported(), false)) return
        if (!policy.retainsPlayback()) {
            val request = policy.request(true, false) ?: return
            val token = policy.session
            entrySession = token
            handler.postDelayed({
                if (disposed || !policy.current(token, request)) return@postDelayed
                if (!activity.isInPictureInPictureMode) {
                    policy.expire(request)
                    if (!policy.foreground && !policy.retainsPlayback()) suspend() else publish()
                }
            }, 1500)
        }
        publish()
    }
    fun mode(value: Boolean) {
        if (value && (entrySession != policy.session || !policy.enabled || policy.blocked)) { suspend(); return }
        if (!value && policy.entering && !policy.active) return
        policy.mode(value)
        // Mode=false can precede resumed by several seconds during expansion.
        // A previously visible PiP Activity remains protected until resumed or
        // the definitive stopped/screen-off callback; a timer is not closure.
        refresh()
    }
    fun paused() {
        policy.foreground = false
        if (locked()) { suspend(); return }
        // System auto-enter can omit userLeaveHint, and onPause may arrive
        // before the API35 transition callback. Only an armed, ready, playing
        // phone receives this bounded grace; stop/lock always revoke it.
        if (Build.VERSION.SDK_INT >= 31) {
            policy.pauseForSystemAutoEnter(supported())?.let { awaitSystemEntry(it) }
        }
        if (!policy.retainsPlayback()) suspend() else publish()
    }
    fun resumed() {
        // Android O can resume briefly before its mode=false callback, then
        // pause for expansion/rotation. A system query can change between calls;
        // it must not synthesize mode=false and revoke the active PiP lease.
        policy.resume()
        refresh()
    }
    fun stopped() = suspend()
    fun suspend() {
        policy.suspend(); owner?.pauseForActivity(); refresh()
    }
    fun protects(playback: CorePlayback) = owner === playback && policy.retainsPlayback()
    fun retire(id: String) { if (id == ownerId) { owner?.pauseForActivity(); policy.retire(); refresh() } }
    fun dispose() {
        disposed = true
        policy.enabled = false; suspend()
        activity.unregisterReceiver(receiver); activity.unregisterReceiver(screenReceiver)
        if (watchingPermission) appOps?.stopWatchingMode(permissionListener)
    }
}
