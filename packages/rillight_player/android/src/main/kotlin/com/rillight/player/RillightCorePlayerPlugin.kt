package com.rillight.player

import android.app.Activity
import android.app.Application
import android.content.Context
import android.media.AudioManager
import android.media.MediaCodecList
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
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
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import kotlin.math.roundToInt

/** Android output for the FFmpeg ABI6 core. It contains no Media3 player. */
class RillightCorePlayerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler, ActivityAware {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private lateinit var events: EventChannel
    private val handler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var activity: Activity? = null
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
        detachActivity()
        owners.values.forEach { it.dispose() }
        owners.clear()
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
    }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) { attachActivity(binding.activity) }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attachActivity(binding.activity)
    }
    override fun onDetachedFromActivityForConfigChanges() {
        owners.values.forEach { it.pauseForActivity() }
        detachActivity()
    }
    override fun onDetachedFromActivity() {
        owners.values.forEach { it.stop() }
        detachActivity()
    }

    private fun attachActivity(current: Activity) {
        detachActivity()
        activity = current
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityPaused(candidate: Activity) {
                if (candidate === current) owners.values.forEach { it.pauseForActivity() }
            }
            override fun onActivityCreated(candidate: Activity, state: Bundle?) = Unit
            override fun onActivityStarted(candidate: Activity) = Unit
            override fun onActivityResumed(candidate: Activity) = Unit
            override fun onActivityStopped(candidate: Activity) = Unit
            override fun onActivitySaveInstanceState(candidate: Activity, state: Bundle) = Unit
            override fun onActivityDestroyed(candidate: Activity) = Unit
        }
        current.application.registerActivityLifecycleCallbacks(callbacks)
        activityCallbacks = callbacks
    }

    private fun detachActivity() {
        val previous = activity
        val callbacks = activityCallbacks
        if (previous != null && callbacks != null)
            previous.application.unregisterActivityLifecycleCallbacks(callbacks)
        activity = null
        activityCallbacks = null
    }

    private fun owner(id: String): CorePlayback = CorePlayback(context, id, handler) { token, kind, value ->
        sink?.success(mapOf("owner" to id, "sessionId" to token, "kind" to kind, "value" to value))
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        if (call.method == "capabilities") {
            val abi = try { CoreNative.abiVersion() } catch (error: Throwable) {
                result.error("native", error.message ?: "Native core unavailable", null)
                return
            }
            val types = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .filter { !it.isEncoder }.flatMap { it.supportedTypes.toList() }
            result.success(mapOf("sessionId" to (args["sessionId"] as? String ?: ""),
                "abiVersion" to abi, "h264" to ("video/avc" in types),
                "aac" to ("audio/mp4a-latm" in types)))
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
        if (call.method == "open") { owner.open(token, args, result); return }
        if (owner.session.isNotEmpty() && owner.session != token) {
            result.error("stale", "Expired playback session", mapOf("sessionId" to token)); return
        }
        when (call.method) {
            "stop" -> owner.stop(result)
            "dispose" -> { owner.dispose(result); owners.remove(id) }
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
            "getSystemBrightness" -> result.success(activity?.window?.attributes?.screenBrightness ?: -1f)
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
                result.success(if (max > 0) audio.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat() / max else 0f)
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
}
