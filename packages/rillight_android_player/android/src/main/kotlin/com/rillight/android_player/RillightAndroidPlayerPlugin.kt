package com.rillight.android_player

import android.app.Activity
import android.content.Context
import android.media.AudioManager
import android.media.MediaCodecList
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import androidx.media3.common.*
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.*
import io.flutter.plugin.platform.*
import kotlin.math.roundToInt
class RillightAndroidPlayerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler, ActivityAware {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var sink: EventChannel.EventSink? = null
    private var activity: Activity? = null
    private val handler = Handler(Looper.getMainLooper())
    private val owners = mutableMapOf<String, Owner>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "rillight/android_player")
        channel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "rillight/android_player/events")
        eventChannel.setStreamHandler(this)
        binding.platformViewRegistry.registerViewFactory("rillight/android_player/view", object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
            override fun create(context: Context, id: Int, args: Any?): PlatformView {
                val owner = owners.getOrPut((args as Map<*, *>)["owner"] as String) { Owner(args["owner"] as String) }
                val view = PlayerView(context).apply {
                    useController = false
                    // 显式适应：完整画面，只留比例所需黑边。不使用 PlayerView 未赋值时的缩放。
                    resizeMode = owner.resizeMode
                    isFocusable = false; isFocusableInTouchMode = false
                    descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
                }
                owner.view?.player = null
                owner.view = view; view.player = owner.player
                view.keepScreenOn = owner.player?.isPlaying == true
                return object : PlatformView {
                    override fun getView(): View = view
                    override fun dispose() { view.player = null; if (owner.view === view) owner.view = null }
                }
            }
        })
    }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        owners.values.forEach { it.release() }; owners.clear()
        channel.setMethodCallHandler(null); eventChannel.setStreamHandler(null); sink = null
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() { activity = null; owners.values.forEach { it.player?.pause() } }
    override fun onDetachedFromActivity() { activity = null; owners.values.forEach { it.release() } }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: run { result.error("arguments", "Missing playback identity", null); return }
        val id = args["owner"] as? String ?: ""
        val session = args["sessionId"] as? String ?: ""
        try {
            if (call.method == "capabilities") {
                val types = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { !it.isEncoder }.flatMap { it.supportedTypes.toList() }
                result.success(mapOf("sessionId" to session, "h264" to types.contains("video/avc"), "aac" to types.contains("audio/mp4a-latm"))); return
            }
            // System brightness / volume are activity-scoped, not session-scoped.
            if (call.method == "setSystemBrightness" || call.method == "getSystemBrightness" ||
                call.method == "setSystemVolume" || call.method == "getSystemVolume") {
                display(call, result); return
            }
            val owner = owners.getOrPut(id) { Owner(id) }
            if (call.method == "setVideoScale") {
                owner.applyScale(args["mode"] as? String)
                result.success(mapOf("sessionId" to session))
                return
            }
            if (call.method == "open") { owner.open(session, args, result); return }
            if (session != owner.session && owner.session.isNotEmpty()) { result.error("stale", "Expired playback session", mapOf("sessionId" to session)); return }
            if (call.method == "dispose" || call.method == "stop") {
                owner.release(); if (call.method == "dispose") owners.remove(id)
                result.success(mapOf("sessionId" to session)); return
            }
            val player = owner.player ?: throw IllegalStateException("Playback has been released")
            when (call.method) {
                "play" -> player.play()
                "pause" -> player.pause()
                "seek" -> player.seekTo((args["position"] as Number).toLong().coerceAtLeast(0))
                "volume" -> player.volume = (args["value"] as Number).toFloat().coerceIn(0f, 1f)
                "rate" -> player.setPlaybackSpeed((args["value"] as Number).toFloat())
                "audio", "subtitle" -> { owner.select((args["index"] as Number).toInt(), call.method == "audio", result); return }
                "subtitleOff" -> { owner.subtitleOff(result); return }
                "subtitleUri" -> { owner.external(args["url"] as String, args["title"] as? String, result); return }
                else -> { result.notImplemented(); return }
            }
            owner.success(result)
        } catch (error: Exception) { result.error("control", error.message ?: "Native playback command failed", mapOf("sessionId" to session)) }
    }

    private fun display(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setSystemBrightness" -> {
                val window = activity?.window ?: run { result.error("control", "No activity", null); return }
                val attrs = window.attributes
                attrs.screenBrightness = ((call.arguments as? Map<*, *>)?.get("value") as? Number)?.toFloat()?.coerceIn(0f, 1f) ?: -1f
                window.attributes = attrs
                result.success(null)
            }
            "getSystemBrightness" -> result.success(activity?.window?.attributes?.screenBrightness ?: -1f)
            "setSystemVolume" -> {
                val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                val value = ((call.arguments as? Map<*, *>)?.get("value") as? Number)?.toFloat()?.coerceIn(0f, 1f) ?: 0f
                audio.setStreamVolume(AudioManager.STREAM_MUSIC, (value * max).roundToInt(), 0)
                result.success(null)
            }
            "getSystemVolume" -> {
                val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                result.success(if (max > 0) audio.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat() / max else 0f)
            }
            else -> result.notImplemented()
        }
    }

    private inner class Owner(val id: String) {
        var session = ""
        var player: ExoPlayer? = null
        var view: PlayerView? = null
        var resizeMode: Int = AspectRatioFrameLayout.RESIZE_MODE_FIT

        fun applyScale(mode: String?) {
            resizeMode = if (mode == "fill") {
                AspectRatioFrameLayout.RESIZE_MODE_ZOOM
            } else {
                AspectRatioFrameLayout.RESIZE_MODE_FIT
            }
            view?.resizeMode = resizeMode
        }
        private var pendingOpen: MethodChannel.Result? = null
        private var pendingTrack: MethodChannel.Result? = null
        private var desiredTrack: String? = null
        private var streams = emptyList<StreamDescriptor>()
        private var mappings = emptyMap<Int, String>()
        private var firstFrame = false
        private var baseItem: MediaItem? = null
        private var externalUri: String? = null
        private var externalRollback: MediaItem? = null
        private var externalRollbackParameters: TrackSelectionParameters? = null
        private var stallSince = 0L
        private val tick = object : Runnable {
            override fun run() {
                val p = player ?: return
                emit("position", p.currentPosition); emit("duration", p.duration.coerceAtLeast(0)); emit("buffer", p.bufferedPosition)
                if (p.playbackState == Player.STATE_BUFFERING) {
                    if (stallSince == 0L) stallSince = android.os.SystemClock.elapsedRealtime()
                    if (android.os.SystemClock.elapsedRealtime() - stallSince > 20000) {
                        fail("Media buffering timed out"); p.stop(); return
                    }
                } else stallSince = 0
                handler.postDelayed(this, 250)
            }
        }
        private val openTimeout = Runnable { if (pendingOpen != null) { fail("Media ready / first frame timed out"); release() } }
        private val trackTimeout = Runnable { trackFailure("Native track selection timed out") }
        fun emit(kind: String, value: Any) { sink?.success(mapOf("owner" to id, "sessionId" to session, "kind" to kind, "value" to value)) }
        fun success(result: MethodChannel.Result) {
            val selected = player?.currentTracks?.groups?.flatMapIndexed { groupIndex, g -> (0 until g.length).filter { g.isTrackSelected(it) }.map { "$groupIndex:$it" } } ?: emptyList()
            result.success(mapOf("sessionId" to session, "audioIndex" to mappings.entries.firstOrNull { it.value in selected && streams.any { s -> s.index == it.key && s.type == "Audio" } }?.key,
                "subtitleIndex" to mappings.entries.firstOrNull { it.value in selected && streams.any { s -> s.index == it.key && s.type == "Subtitle" } }?.key))
        }
        fun release() {
            handler.removeCallbacks(tick); handler.removeCallbacks(openTimeout); handler.removeCallbacks(trackTimeout)
            pendingOpen?.error("cancelled", "Playback open cancelled", mapOf("sessionId" to session)); pendingOpen = null
            pendingTrack?.error("cancelled", "Track selection cancelled", mapOf("sessionId" to session)); pendingTrack = null
            view?.player = null; view?.keepScreenOn = false
            val old = player; player = null; old?.release()
        }
        @Suppress("UNCHECKED_CAST")
        fun open(token: String, args: Map<*, *>, result: MethodChannel.Result) {
            release(); session = token; firstFrame = false; stallSince = 0; mappings = emptyMap(); externalUri = null; externalRollback = null; externalRollbackParameters = null
            streams = (args["streams"] as? List<Map<String, Any?>> ?: emptyList()).map { StreamDescriptor((it["index"] as Number).toInt(), it["type"] as String, it["language"] as? String, it["external"] == true) }
            val factory = DefaultDataSource.Factory(context, DataSource.Factory {
                SafeDataSource(args["credentialOrigin"] as? String, args["credentialHeaders"] as? Map<String, String> ?: emptyMap(), args["headers"] as? Map<String, String> ?: emptyMap())
            })
            val p = ExoPlayer.Builder(context).setMediaSourceFactory(DefaultMediaSourceFactory(factory)).build()
            player = p; pendingOpen = result
            p.setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), true)
            p.setHandleAudioBecomingNoisy(true)
            p.addListener(object : Player.Listener {
                fun current() = player === p && session == token
                override fun onPlaybackStateChanged(state: Int) {
                    if (!current()) return
                    emit("buffering", state == Player.STATE_BUFFERING)
                    if (state == Player.STATE_ENDED) emit("completed", true)
                    ready()
                }
                override fun onRenderedFirstFrame() { if (current()) { firstFrame = true; emit("firstFrame", true); ready() } }
                override fun onIsPlayingChanged(value: Boolean) { if (current()) { view?.keepScreenOn = value; emit("playing", value && firstFrame) } }
                override fun onPlayWhenReadyChanged(value: Boolean, reason: Int) {
                    if (current() && reason in listOf(Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS, Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY)) {
                        p.pause(); emit("interruption", if (reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS) "audioFocus" else "headphones")
                    }
                }
                override fun onPlaybackSuppressionReasonChanged(reason: Int) {
                    if (current() && reason != Player.PLAYBACK_SUPPRESSION_REASON_NONE) {
                        p.pause(); emit("interruption", "audioFocus")
                    }
                }
                override fun onTracksChanged(tracks: Tracks) { if (current()) { updateTracks(); confirmTrack() } }
                override fun onPlayerError(error: PlaybackException) {
                    if (!current()) return
                    if (externalRollback != null) { trackFailure("External subtitle could not be loaded"); return }
                    val http = generateSequence<Throwable>(error) { it.cause }.filterIsInstance<MediaHttpException>().firstOrNull()
                    if (http?.status == 401 || http?.status == 403) emit("authenticationRequired", http.status)
                    fail(http?.message ?: "Media3 ${error.errorCodeName}")
                }
            })
            baseItem = MediaItem.fromUri(args["url"] as String)
            view?.player = p
            p.setMediaItem(baseItem!!, (args["start"] as? Number)?.toLong() ?: 0)
            p.playWhenReady = args["paused"] != true
            p.prepare(); handler.post(tick); handler.postDelayed(openTimeout, 22000)
        }
        private fun ready() {
            val p = player ?: return
            val hasVideo = p.currentTracks.groups.any { it.type == C.TRACK_TYPE_VIDEO }
            if (p.playbackState == Player.STATE_READY && (!hasVideo || firstFrame)) {
                handler.removeCallbacks(openTimeout)
                emit("ready", true); emit("playing", p.isPlaying)
                pendingOpen?.let { pendingOpen = null; success(it) }
                confirmTrack()
            }
        }
        private fun fail(message: String) {
            pendingOpen?.error("playback", message, mapOf("sessionId" to session)); pendingOpen = null
            view?.keepScreenOn = false; emit("playing", false); emit("error", message)
        }
        private fun updateTracks() {
            val native = player!!.currentTracks.groups.flatMapIndexed { gi, g ->
                (0 until g.length).filter { !isExternal(g.getTrackFormat(it)) }.map { ti ->
                    NativeDescriptor("$gi:$ti", when(g.type) { C.TRACK_TYPE_AUDIO -> "Audio"; C.TRACK_TYPE_TEXT -> "Subtitle"; else -> "Video" }, g.getTrackFormat(ti).language)
                }
            }
            mappings = mapTracks(streams, native)
        }
        private fun isExternal(format: Format) = format.id == "rillight-external" || format.label == "rillight-external"
        fun select(index: Int, audio: Boolean, result: MethodChannel.Result) {
            val key = mappings[index] ?: throw IllegalStateException("Container track cannot be mapped to server stream $index")
            val (gi, ti) = key.split(':').map { it.toInt() }
            val p = player!!; val group = p.currentTracks.groups[gi]
            val type = if(audio) C.TRACK_TYPE_AUDIO else C.TRACK_TYPE_TEXT
            require(group.type == type && group.isTrackSupported(ti)) { "Unsupported media track" }
            beginTrack(key, result)
            p.trackSelectionParameters = p.trackSelectionParameters.buildUpon().setTrackTypeDisabled(type, false).setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, ti)).build()
            confirmTrack()
        }
        private fun beginTrack(key: String, result: MethodChannel.Result) {
            pendingTrack?.error("superseded", "Track selection superseded", mapOf("sessionId" to session))
            pendingTrack = result; desiredTrack = key
            handler.removeCallbacks(trackTimeout); handler.postDelayed(trackTimeout, 4500)
        }
        private fun confirmTrack() {
            val p = player ?: return
            if (pendingTrack == null || p.playbackState != Player.STATE_READY) return
            val found = if (desiredTrack == "off") p.currentTracks.groups.none { it.type == C.TRACK_TYPE_TEXT && it.isSelected }
            else p.currentTracks.groups.withIndex().any { (gi,g) -> (0 until g.length).any { ti ->
                g.isTrackSelected(ti) && (if (desiredTrack == "external") isExternal(g.getTrackFormat(ti)) else "$gi:$ti" == desiredTrack)
            } }
            if (found) { handler.removeCallbacks(trackTimeout); externalRollback = null; externalRollbackParameters = null; pendingTrack?.let { pendingTrack = null; success(it) } }
            else if (desiredTrack == "external") {
                val group = p.currentTracks.groups.firstOrNull { g -> (0 until g.length).any { isExternal(g.getTrackFormat(it)) } }
                if (group != null) {
                    val track = (0 until group.length).first { isExternal(group.getTrackFormat(it)) }
                    p.trackSelectionParameters = p.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false).setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, track)).build()
                }
            }
        }
        fun subtitleOff(result: MethodChannel.Result) {
            val p = player!!
            beginTrack("off", result)
            p.trackSelectionParameters = p.trackSelectionParameters.buildUpon().clearOverridesOfType(C.TRACK_TYPE_TEXT).setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).build()
            confirmTrack()
        }
        private fun trackFailure(message: String) {
            handler.removeCallbacks(trackTimeout)
            pendingTrack?.error("track", message, mapOf("sessionId" to session)); pendingTrack = null
            val rollback = externalRollback; externalRollback = null; externalUri = null
            if (rollback != null) {
                val p = player ?: return; val position = p.currentPosition
                externalRollbackParameters?.let { p.trackSelectionParameters = it }
                externalRollbackParameters = null
                p.setMediaItem(rollback, position); p.prepare()
            }
        }
        fun external(url: String, title: String?, result: MethodChannel.Result) {
            if (url == externalUri) {
                val p = player!!
                val group = p.currentTracks.groups.firstOrNull { g -> (0 until g.length).any { isExternal(g.getTrackFormat(it)) } }
                if (group != null) {
                    val track = (0 until group.length).first { isExternal(group.getTrackFormat(it)) }
                    beginTrack("external", result)
                    p.trackSelectionParameters = p.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false).setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, track)).build()
                    confirmTrack(); return
                }
            }
            // The controller downloads with credential-safe redirects first.
            val uri = android.net.Uri.parse(url)
            require(uri.scheme == "file" && java.io.File(uri.path!!).canonicalPath.startsWith(context.cacheDir.parentFile!!.canonicalPath + "/")) { "External subtitles must be application-private files" }
            val file = java.io.File(uri.path!!)
            require(file.length() in 1..(4 * 1024 * 1024)) { "Invalid subtitle size" }
            val mime = when(file.extension.lowercase()) { "srt" -> MimeTypes.APPLICATION_SUBRIP; "vtt" -> MimeTypes.TEXT_VTT; else -> throw IllegalArgumentException("Only SRT and WebVTT subtitles are supported") }
            val sample = file.readText().trimStart()
            require(sample.contains("-->") && (mime != MimeTypes.TEXT_VTT || sample.startsWith("WEBVTT"))) { "Invalid subtitle document" }
            val p = player!!
            externalRollback = p.currentMediaItem
            externalRollbackParameters = p.trackSelectionParameters
            val item = baseItem!!.buildUpon().setSubtitleConfigurations(listOf(MediaItem.SubtitleConfiguration.Builder(uri).setId("rillight-external").setMimeType(mime).setLabel("rillight-external").setSelectionFlags(C.SELECTION_FLAG_DEFAULT).build())).build()
            beginTrack("external", result); externalUri = url
            p.trackSelectionParameters = p.trackSelectionParameters.buildUpon().clearOverridesOfType(C.TRACK_TYPE_TEXT).setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false).build()
            val position = p.currentPosition; p.setMediaItem(item, position); p.prepare()
        }
    }
}
