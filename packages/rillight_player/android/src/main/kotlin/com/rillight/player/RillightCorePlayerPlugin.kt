package com.rillight.player

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.View
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import kotlin.math.roundToInt

internal fun effectiveDisplayBrightness(
    windowBrightness: Float, systemBrightness: Int
): Double? {
    if (windowBrightness.isFinite() && windowBrightness >= 0f)
        return windowBrightness.coerceIn(0f, 1f).toDouble()
    if (systemBrightness >= 0) return (systemBrightness / 255.0).coerceIn(0.0, 1.0)
    return null
}

/** Android output for the owned FFmpeg core. It contains no Media3 player. */
class RillightCorePlayerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler, ActivityAware, PluginRegistry.ActivityResultListener {
    companion object {
        private var current: RillightCorePlayerPlugin? = null
        fun userLeave(activity: Activity) { current?.takeIf { it.activity === activity }?.pip?.userLeave() }
        fun pipMode(activity: Activity, active: Boolean) { current?.takeIf { it.activity === activity }?.pip?.mode(active) }
        fun pipTransition(activity: Activity) { current?.takeIf { it.activity === activity }?.pip?.transition() }
    }
    private var pip: PhonePipCoordinator? = null
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private lateinit var events: EventChannel
    private val handler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var imageSaveResult: MethodChannel.Result? = null
    private var imageSaveBytes: ByteArray? = null
    private val imageWriter = java.util.concurrent.Executors.newSingleThreadExecutor()
    private var activityCallbacks: Application.ActivityLifecycleCallbacks? = null
    private val owners = mutableMapOf<String, CorePlayback>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "rillight/android_core")
        channel.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "rillight/android_core/events")
        events.setStreamHandler(this)
        binding.platformViewRegistry.registerViewFactory("rillight/android_core/view",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, id: Int, args: Any?): PlatformView {
                    val ownerId = (args as? Map<*, *>)?.get("owner") as? String
                        ?: throw IllegalArgumentException("Missing view owner")
                    val owner = owners.getOrPut(ownerId) { owner(ownerId) }
                    val view = owner.attachView(context)
                    return object : PlatformView {
                        override fun getView(): View = view
                        override fun dispose() = owner.detachView(view)
                    }
                }
            })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        finishImageSave(false)
        imageWriter.shutdown()
        detachActivity()
        owners.values.forEach { it.dispose() }
        owners.clear()
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
    }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attachActivity(binding.activity)
        activityBinding = binding
        binding.addActivityResultListener(this)
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }
    override fun onDetachedFromActivityForConfigChanges() {
        owners.values.forEach { it.pauseForActivity() }
        detachActivity()
    }
    override fun onDetachedFromActivity() {
        finishImageSave(false)
        owners.values.forEach { it.stop() }
        detachActivity()
    }

    private fun attachActivity(current: Activity) {
        detachActivity()
        activity = current
        Companion.current = this
        pip = PhonePipCoordinator(current, handler) { id, token, state ->
            sink?.success(mapOf("owner" to id, "sessionId" to token, "kind" to "presentation", "value" to state))
        }
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityPaused(candidate: Activity) {
                if (candidate === current) {
                    pip?.paused()
                    owners.values.filter { pip?.protects(it) != true }.forEach { it.pauseForActivity() }
                }
            }
            override fun onActivityCreated(candidate: Activity, state: Bundle?) = Unit
            override fun onActivityStarted(candidate: Activity) = Unit
            override fun onActivityResumed(candidate: Activity) { if (candidate === current) pip?.resumed() }
            override fun onActivityStopped(candidate: Activity) { if (candidate === current) pip?.stopped() }
            override fun onActivitySaveInstanceState(candidate: Activity, state: Bundle) = Unit
            override fun onActivityDestroyed(candidate: Activity) = Unit
        }
        current.application.registerActivityLifecycleCallbacks(callbacks)
        activityCallbacks = callbacks
    }

    private fun detachActivity() {
        pip?.dispose(); pip = null
        if (Companion.current === this) Companion.current = null
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        val previous = activity
        val callbacks = activityCallbacks
        if (previous != null && callbacks != null)
            previous.application.unregisterActivityLifecycleCallbacks(callbacks)
        activity = null
        activityCallbacks = null
    }

    private fun owner(id: String): CorePlayback = CorePlayback(context, id, handler) { token, kind, value ->
        pip?.event(id, token, kind, value)
        sink?.success(mapOf("owner" to id, "sessionId" to token, "kind" to kind, "value" to value))
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        if (call.method == "saveAlbumImage") {
            val current = activity
            val bytes = args["bytes"] as? ByteArray
            if (current == null || bytes == null || bytes.isEmpty()) {
                result.error("save", "Image or activity unavailable", null)
                return
            }
            if (imageSaveResult != null) {
                result.error("save", "A save dialog is already open", null)
                return
            }
            imageSaveResult = result
            imageSaveBytes = bytes
            try {
                current.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = args["mime"] as? String ?: "image/jpeg"
                    putExtra(Intent.EXTRA_TITLE, args["name"] as? String ?: "rillight-image.jpg")
                }, 54652)
            } catch (_: Exception) {
                imageSaveResult = null
                imageSaveBytes = null
                result.error("save", "Save dialog unavailable", null)
            }
            return
        }
        if (call.method == "capabilities") {
            val abi = try { CoreNative.abiVersion() } catch (error: Throwable) {
                result.error("native", error.message ?: "Native core unavailable", null)
                return
            }
            fun has(name: String) = try {
                CoreNative.hasDecoder(name)
            } catch (_: Throwable) {
                false
            }
            result.success(mapOf("sessionId" to (args["sessionId"] as? String ?: ""),
                "abiVersion" to abi,
                "h264" to has("h264"),
                "hevc" to has("hevc"),
                "aac" to has("aac"),
                "ac3" to has("ac3"),
                "eac3" to has("eac3"),
                "truehd" to has("truehd"),
                "dts" to has("dts"),
                "pgssub" to has("pgssub"),
                "ass" to has("ass"),
                "ssa" to has("ssa")))
            return
        }
        if (call.method in setOf("setSystemBrightness", "getSystemBrightness",
                "setSystemVolume", "getSystemVolume", "setSystemBarsHidden", "androidSdkInt")) {
            display(call, result)
            return
        }
        val id = args["owner"] as? String ?: run {
            result.error("arguments", "Missing owner", null); return
        }
        val token = args["sessionId"] as? String ?: ""
        val owner = owners.getOrPut(id) { owner(id) }
        if (call.method == "setVideoScale") {
            owner.setScale(args["mode"] as? String)
            result.success(mapOf("sessionId" to token))
            return
        }
        if (call.method == "open") {
            pip?.bind(id, token)
            if (pip?.allowsOpen(id) == false) {
                owner.rejectOpenForActivity(token, result)
                return
            }
            owner.open(token, args, result); return
        }
        if (owner.session.isNotEmpty() && owner.session != token) {
            result.error("stale", "Expired playback session", mapOf("sessionId" to token)); return
        }
        when (call.method) {
            "configurePhonePresentation" -> {
                pip?.configure(id, owner, args["enabled"] == true)
                result.success(pip?.snapshot() ?: mapOf("supported" to false))
            }
            "phonePresentation" -> result.success(pip?.snapshot() ?: mapOf("supported" to false))
            "enterPictureInPicture" -> result.success(mapOf("accepted" to (pip?.enter(true) == true)))
            "stop" -> { pip?.mediaStopped(id); owner.stop(result) }
            "dispose" -> { pip?.retire(id); owner.dispose(result); owners.remove(id) }
            else -> owner.command(call.method, args, result)
        }
    }

    private fun display(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        when (call.method) {
            "setSystemBrightness" -> {
                val window = activity?.window ?: run { result.error("control", "No activity", null); return }
                val attrs = window.attributes
                attrs.screenBrightness = (args["value"] as? Number)?.toFloat()?.coerceIn(0f, 1f) ?: -1f
                window.attributes = attrs
                result.success(null)
            }
            "getSystemBrightness" -> {
                val current = activity ?: run { result.error("control", "No activity", null); return }
                val windowBrightness = current.window.attributes.screenBrightness
                // -1 means this window follows the system setting.
                val systemBrightness = if (windowBrightness < 0f)
                    runCatching { Settings.System.getInt(
                        context.contentResolver, Settings.System.SCREEN_BRIGHTNESS, -1) }.getOrDefault(-1)
                else -1
                val effective = effectiveDisplayBrightness(windowBrightness, systemBrightness)
                if (effective != null) {
                    result.success(effective)
                } else {
                    result.error("control", "System brightness unavailable", null)
                }
            }
            "setSystemVolume" -> {
                val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                val value = (args["value"] as? Number)?.toFloat()?.coerceIn(0f, 1f) ?: 0f
                audio.setStreamVolume(AudioManager.STREAM_MUSIC, (value * max).roundToInt(), 0)
                result.success(null)
            }
            "getSystemVolume" -> {
                val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                result.success(if (max > 0) audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max else 0.0)
            }
            "androidSdkInt" -> result.success(Build.VERSION.SDK_INT)
            "setSystemBarsHidden" -> {
                val window = activity?.window ?: run { result.error("control", "No activity", null); return }
                val controller = WindowInsetsControllerCompat(window, window.decorView)
                controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                val bars = WindowInsetsCompat.Type.systemBars()
                if (args["hidden"] == true) controller.hide(bars) else controller.show(bars)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun finishImageSave(saved: Boolean) {
        val pending = imageSaveResult
        imageSaveResult = null
        imageSaveBytes = null
        pending?.success(saved)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != 54652) return false
        val bytes = imageSaveBytes
        val pending = imageSaveResult
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || bytes == null || pending == null) {
            finishImageSave(false)
            return true
        }
        imageSaveResult = null
        imageSaveBytes = null
        imageWriter.execute {
            try {
                context.contentResolver.openOutputStream(uri, "w")?.use { it.write(bytes) }
                    ?: throw java.io.IOException("Cannot open image destination")
                handler.post { pending.success(true) }
            } catch (_: Exception) {
                handler.post { pending.error("save", "Cannot write image", null) }
            }
        }
        return true
    }
}
