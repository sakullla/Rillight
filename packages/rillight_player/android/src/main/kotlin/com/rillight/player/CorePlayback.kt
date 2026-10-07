package com.rillight.player

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaCodecList
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Handler
import android.view.Surface
import android.view.Display
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** One owner has at most one owned core. Shutdown and reopen run off the UI thread. */
internal class CorePlayback(
    private val context: Context,
    val id: String,
    private val handler: Handler,
    private val send: (String, String, Any) -> Unit,
) : SurfaceOwner {
    private data class Running(val handle: Long, val generation: Int,
                               val alive: AtomicBoolean = AtomicBoolean(true),
                               var thread: Thread? = null,
                               var audioThread: Thread? = null,
                               val drainedAudioTimeline: AtomicLong = AtomicLong(-1))
    private data class TrackRequest(val result: MethodChannel.Result, val expected: Int,
                                    val subtitle: Boolean, val timeline: Long)
    private data class ServerStream(val index: Int, val type: String,
                                    val language: String?, val external: Boolean)
    private val serial = Executors.newSingleThreadExecutor()
    private val generation = AtomicInteger()
    private val operation = AtomicLong()
    private val surfaceLock = Any()
    private val surfaceRevision = AtomicInteger()
    private val outputLock = Any()
    private val outputWaitLock = ReentrantLock()
    private val outputWake = outputWaitLock.newCondition()
    private var surface: Surface? = null
    // Some NDK implementations accept Dolby MIME through an ordinary HEVC
    // decoder. Only advertised Dolby profiles establish a native color path.
    private val doviProfiles: Int by lazy {
        runCatching {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .filter { !it.isEncoder && it.supportedTypes.contains("video/dolby-vision") }
                .flatMap { it.getCapabilitiesForType("video/dolby-vision").profileLevels.toList() }
                .fold(0) { profiles, level -> profiles or level.profile }
        }.getOrDefault(0)
    }
    @Volatile private var viewport = Pair(0, 0)
    private var audioOutput: CoreAudioOutput? = null
    private var running: Running? = null
    private var pendingOpen: MethodChannel.Result? = null
    private var pendingTrack: TrackRequest? = null
    private var externalPending: MethodChannel.Result? = null
    private val openTimeout = Runnable { fail("Media ready / first frame timed out") }
    private val trackTimeout = Runnable {
        val active = running
        val snapshot = active?.let { CoreNative.snapshot(it.handle) }
        if (active != null && confirmTrack(active, snapshot)) return@Runnable
        val pending = pendingTrack
        trackFailure("Native track selection timed out (state=${snapshot?.getOrNull(0)}, " +
            "timeline=${snapshot?.getOrNull(3)}, selected=${snapshot?.getOrNull(if (pending?.subtitle == true) 7 else 6)})")
    }
    private var serverStreams = emptyList<ServerStream>()
    private var mapping = emptyMap<Int, Int>()
    @Volatile private var desiredPaused = false
    @Volatile private var audioReady = false
    private var renderedFirst = false
    private var emittedCompletion = false
    private var buffering = false
    private var lastPlaying = false
    private var scaleMode = "fit"
    private var lastHardware: Int? = null
    private var preferredHardware = 8
    private var lastDecoderCheckMs = 0L
    private var lastDiagnosticMs = 0L
    private val debugDiagnostics = (context.applicationInfo.flags and
        android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
    @Volatile private var volume = 1f
    private var sinkChannels = 2
    private var sinkAccept = 0
    private var sinkAtmos = false
    @Volatile private var pendingRoute: AudioSinkCapability? = null
    private var deviceCallbackRegistered = false
    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
            refreshAudioRoute()
        }
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
            refreshAudioRoute()
        }
    }
    @Volatile private var lastPresentedUs = -1L
    private var watchedOutput: LongArray? = null
    private var watchedReasons: IntArray? = null
    @Volatile var session = ""
        private set
    var view: CoreSurfaceView? = null
        private set
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change != AudioManager.AUDIOFOCUS_GAIN) handler.post { interruption("audioFocus") }
    }
    private var focusRequest: AudioFocusRequest? = null
    private var noisyRegistered = false
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY)
                handler.post {
                    refreshAudioRoute()
                    interruption("headphones")
                }
        }
    }

    fun attachView(context: Context): CoreSurfaceView {
        view?.detach()
        return CoreSurfaceView(context, this).also {
            view = it
            it.scale(scaleMode)
        }
    }

    fun detachView(candidate: CoreSurfaceView) {
        candidate.detach(view === candidate)
        if (view === candidate) view = null
    }

    override fun setSurface(surface: Surface?) {
        synchronized(surfaceLock) { this.surface = surface; surfaceRevision.incrementAndGet() }
        wakeOutput()
    }

    override fun videoGeometry(value: Map<String, Any>) { emit("videoGeometry", value) }
    fun videoSourceRect() = view?.sourceRect()
    fun presentationDiagnostics(): Map<String, Any> {
        val snap = running?.let { CoreNative.snapshot(it.handle) }
        return mapOf("surfaceValid" to (surface?.isValid == true),
            "surfaceRevision" to surfaceRevision.get(), "desiredPaused" to desiredPaused,
            "renderedFirst" to renderedFirst, "presentedPositionMs" to (lastPresentedUs / 1000), "state" to (snap?.get(0) ?: -1),
            "firstVideo" to (snap?.get(10) ?: 0), "firstAudio" to (snap?.get(11) ?: 0),
            "queuedVideo" to (snap?.get(13) ?: 0), "queuedAudio" to (snap?.get(14) ?: 0),
            "timeline" to (snap?.get(3) ?: 0))
    }
    fun pipReady() = renderedFirst && running?.let {
        CoreNative.snapshot(it.handle)?.get(0) in setOf(2L, 3L, 4L, 5L)
    } == true
    fun pipPlaying() = !desiredPaused && running?.let {
        CoreNative.snapshot(it.handle)?.get(0) == 3L
    } == true

    override fun setViewport(width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        viewport = Pair(width.coerceAtMost(8192), height.coerceAtMost(8192))
        wakeOutput()
    }

    private fun wakeOutput() = outputWaitLock.withLock { outputWake.signalAll() }

    fun setScale(mode: String?) {
        scaleMode = if (mode == "fill") "fill" else "fit"
        view?.scale(scaleMode)
    }

    fun rejectOpenForActivity(token: String, result: MethodChannel.Result) {
        stop()
        session = token
        result.error("activity", "Phone playback route is not active", mapOf("sessionId" to token))
    }

    fun open(token: String, args: Map<*, *>, result: MethodChannel.Result) {
        val address = args["url"] as? String
        if (address == null || CoreIoFactory(context).open(address) == null) {
            result.error("source", "Core requires a sealed loopback URL", mapOf("sessionId" to token))
            return
        }
        val preferredHardware = (args["preferredHardware"] as? Number)?.toInt() ?: 8
        if (preferredHardware != 0 && preferredHardware != 8) {
            result.error("hardware", "Unsupported Android decoder preference", mapOf("sessionId" to token))
            return
        }
        val revision = generation.incrementAndGet()
        val previous = running
        previous?.alive?.set(false)
        wakeOutput()
        running = null
        cancelPending("superseded")
        abandonFocus()
        session = token
        pendingOpen = result
        serverStreams = (args["streams"] as? List<*>)?.mapNotNull { item ->
            val stream = item as? Map<*, *> ?: return@mapNotNull null
            ServerStream((stream["index"] as? Number)?.toInt() ?: return@mapNotNull null,
                stream["type"] as? String ?: return@mapNotNull null,
                stream["language"] as? String, stream["external"] == true)
        } ?: emptyList()
        val initialStartUs = ((args["start"] as? Number)?.toLong() ?: 0).coerceAtLeast(0) * 1000
        desiredPaused = args["paused"] == true
        audioReady = false
        renderedFirst = false
        lastPresentedUs = -1
        emittedCompletion = false
        buffering = false
        lastPlaying = false
        mapping = emptyMap()
        lastHardware = null
        this.preferredHardware = preferredHardware
        lastDecoderCheckMs = 0L
        operation.set(0)
        handler.removeCallbacks(openTimeout)
        // Include proxy body/header recovery, container probes and the first
        // decoded frame. Keep this outside the 90 s loopback read deadline.
        // Retirement and a new open still cancel this generation's timeout.
        handler.postDelayed(openTimeout, 120_000)
        serial.execute {
            retire(previous)
            if (generation.get() != revision) return@execute
            val handle = try {
                CoreNative.create(CoreIoFactory(context))
            } catch (error: Throwable) {
                handler.post { if (generation.get() == revision) fail(error.message ?: "Native core unavailable") }
                return@execute
            }
            if (handle == 0L) {
                handler.post { if (generation.get() == revision) fail("Native core unavailable") }
                return@execute
            }
            val accepted = try {
                // Wait off the UI thread for the mounted native view's Surface.
                var target = synchronized(surfaceLock) { surface }
                while (target?.isValid != true && generation.get() == revision) {
                    outputWaitLock.withLock { outputWake.await(100, TimeUnit.MILLISECONDS) }
                    target = synchronized(surfaceLock) { surface }
                }
                generation.get() == revision && target?.isValid == true &&
                    CoreNative.outputSurface(handle, target, doviProfiles) == 0 &&
                    CoreNative.configureHardware(handle, preferredHardware, true) == 0 &&
                    CoreNative.configureExternalAudioSpeed(handle, true) == 0 &&
                    configureProbedAudioSink(handle) &&
                    CoreNative.open(handle, address, initialStartUs, operation.incrementAndGet()) == 0 &&
                    (!desiredPaused || CoreNative.play(handle, false, operation.incrementAndGet()) == 0)
            } catch (error: Throwable) {
                CoreNative.destroy(handle)
                handler.post { if (generation.get() == revision) fail(error.message ?: "Native open failed") }
                return@execute
            }
            if (!accepted || generation.get() != revision) {
                CoreNative.destroy(handle)
                if (!accepted) handler.post { if (generation.get() == revision) fail("Core rejected media open") }
                return@execute
            }
            handler.post {
                if (generation.get() != revision) {
                    serial.execute { CoreNative.destroy(handle) }
                    return@post
                }
                val active = Running(handle, revision)
                running = active
                watchedOutput = null
                watchedReasons = null
                registerRouteWatcher()
                if (desiredPaused) {
                    CoreNative.play(handle, false, operation.incrementAndGet())
                } else if (!requestFocus()) {
                    desiredPaused = true
                    CoreNative.play(handle, false, operation.incrementAndGet())
                    abandonFocus()
                    emit("interruption", "audioFocus")
                }
                active.audioThread = Thread({ pumpAudio(active) }, "rillight-android-audio-$revision").also { it.start() }
                active.thread = Thread({ pump(active) }, "rillight-android-core-$revision").also { it.start() }
            }
        }
    }

    fun command(method: String, args: Map<*, *>, result: MethodChannel.Result) {
        val active = running ?: run {
            result.error("control", "Playback is opening or closed", mapOf("sessionId" to session)); return
        }
        val handle = active.handle
        val started = System.nanoTime()
        if (debugDiagnostics) android.util.Log.i("RillightCommand",
            "begin method=$method generation=${active.generation}")
        try {
            if (method == "outputStatus") {
                result.success(successMap(handle))
                return
            }
            val accepted = when (method) {
                "play" -> {
                    desiredPaused = false
                    if (!requestFocus()) {
                        desiredPaused = true
                        CoreNative.play(handle, false, operation.incrementAndGet())
                        abandonFocus()
                        emit("interruption", "audioFocus")
                        -1
                    }
                    else CoreNative.play(handle, true, operation.incrementAndGet())
                }
                "pause" -> {
                    desiredPaused = true
                    val code = CoreNative.play(handle, false, operation.incrementAndGet())
                    abandonFocus()
                    view?.keepScreenOn = false
                    code
                }
                "seek" -> synchronized(outputLock) {
                    val code = CoreNative.seek(handle,
                        ((args["position"] as? Number)?.toLong() ?: -1L) * 1000,
                        operation.incrementAndGet())
                    if (code == 0) audioOutput?.flush()
                    code
                }
                "rate" -> synchronized(outputLock) {
                    val rate = (args["value"] as? Number)?.toDouble() ?: Double.NaN
                    require(rate.isFinite() && rate in .5..3.0)
                    val previous = CoreNative.snapshot(handle)?.getOrNull(16)?.div(1000.0) ?: 1.0
                    val code = CoreNative.speed(handle, rate, operation.incrementAndGet())
                    audioOutput?.setSpeed((if (code == 0) rate else previous).toFloat())
                    code
                }
                "volume" -> {
                    volume = (args["value"] as? Number)?.toFloat()?.coerceIn(0f, 1f) ?: volume
                    synchronized(outputLock) { audioOutput?.setVolume(volume) }
                    0
                }
                "audio", "subtitle" -> {
                    val server = (args["index"] as? Number)?.toInt()
                    val stream = server?.let(mapping::get)
                    if (stream == null) {
                        result.error("unsupported", "Container track cannot be mapped", mapOf("sessionId" to session))
                        return
                    }
                    val code = synchronized(outputLock) {
                        val selected = if (method == "audio")
                            CoreNative.selectAudio(handle, stream, operation.incrementAndGet())
                        else CoreNative.selectSubtitle(handle, stream, operation.incrementAndGet())
                        if (selected == 0) audioOutput?.flush()
                        selected
                    }
                    if (code == 0) { beginTrack(result, stream, method == "subtitle", handle); return }
                    code
                }
                "subtitlePresentation" -> {
                    val nativeSession = CoreNative.snapshot(handle)?.get(1)
                        ?: throw IllegalStateException("Core session unavailable")
                    CoreNative.subtitlePresentation(handle, nativeSession,
                        (args["displayWidth"] as Number).toDouble(),
                        (args["displayHeight"] as Number).toDouble(),
                        (args["fontSize"] as Number).toDouble(),
                        (args["userScale"] as Number).toDouble(),
                        args["originalAss"] == true,
                        (args["safeHorizontal"] as Number).toDouble(),
                        (args["safeVertical"] as Number).toDouble())
                }
                "subtitleOff" -> {
                    val code = synchronized(outputLock) {
                        val timeline = CoreNative.snapshot(handle)?.get(3)
                        val selected = CoreNative.selectSubtitle(handle, -1, operation.incrementAndGet())
                        if (selected == 0 && CoreNative.snapshot(handle)?.get(3) != timeline)
                            audioOutput?.flush()
                        selected
                    }
                    if (code == 0) { beginTrack(result, -1, true, handle); return }
                    code
                }
                "enhancement" -> CoreNative.configureEnhancement(
                    handle,
                    (args["interpolation"] as? Number)?.toInt() ?: 0,
                    (args["anime4k"] as? Number)?.toInt() ?: 0,
                    (args["superResolution"] as? Number)?.toInt() ?: 0,
                    (args["denoise"] as? Number)?.toInt() ?: 0,
                    (args["sharpen"] as? Number)?.toInt() ?: 0,
                    if (args["acceptLeaveNativeDolby"] == true) 1 else 0,
                    (args["displayRefreshHz"] as? Number)?.toInt() ?: 0)
                "frameDeadline" -> CoreNative.noteFrameDeadline(
                    handle,
                    if (args["met"] == true) 1 else 0,
                    (args["monotonicUs"] as? Number)?.toLong() ?: -1L)
                "subtitleUri" -> {
                    val url = args["url"] as? String
                    if (url == null || CoreIoFactory(context).open(url) == null) {
                        result.error("source", "External subtitle must be app-private", mapOf("sessionId" to session)); return
                    }
                    val code = CoreNative.addSubtitle(handle, url, operation.incrementAndGet())
                    if (code == 0) { externalPending = result; handler.postDelayed(trackTimeout, 6_000); return }
                    code
                }
                else -> { result.notImplemented(); return }
            }
            wakeOutput()
            if (accepted != 0) result.error("control", "Core rejected $method", mapOf("sessionId" to session))
            else result.success(successMap(handle))
        } catch (error: Throwable) {
            result.error("control", error.message ?: "Core command failed", mapOf("sessionId" to session))
        } finally {
            if (debugDiagnostics) android.util.Log.i("RillightCommand",
                "end method=$method generation=${active.generation} ms=${(System.nanoTime() - started) / 1_000_000}")
        }
    }

    fun stop(result: MethodChannel.Result? = null) {
        val stoppedSession = session
        generation.incrementAndGet()
        watchedOutput = null
        watchedReasons = null
        unregisterRouteWatcher()
        val previous = running
        previous?.alive?.set(false)
        wakeOutput()
        running = null
        cancelPending("cancelled")
        abandonFocus()
        view?.keepScreenOn = false
        serial.execute {
            retire(previous)
            handler.post { result?.success(mapOf("sessionId" to stoppedSession)) }
        }
    }

    fun dispose(result: MethodChannel.Result? = null) {
        stop(result)
        serial.shutdown()
    }

    fun pauseForActivity() { interruption("activity") }

    private fun interruption(reason: String) {
        if (desiredPaused) return
        desiredPaused = true
        running?.let { CoreNative.play(it.handle, false, operation.incrementAndGet()) }
        abandonFocus()
        wakeOutput()
        view?.keepScreenOn = false
        emit("playing", false)
        emit("interruption", reason)
    }

    private fun beginTrack(result: MethodChannel.Result, expected: Int,
                           subtitle: Boolean, handle: Long) {
        val timeline = CoreNative.snapshot(handle)?.getOrNull(3)
        if (timeline == null) {
            result.error("track", "Native track timeline unavailable", mapOf("sessionId" to session))
            return
        }
        pendingTrack?.result?.error("superseded", "Track selection superseded", mapOf("sessionId" to session))
        pendingTrack = TrackRequest(result, expected, subtitle, timeline)
        handler.removeCallbacks(trackTimeout)
        handler.postDelayed(trackTimeout, 12_000)
    }

    private fun trackFailure(message: String) {
        if (debugDiagnostics && (pendingTrack != null || externalPending != null))
            android.util.Log.i("RillightCommand", "track-failure generation=${generation.get()} " +
                "subtitle=${pendingTrack?.subtitle} external=${externalPending != null}")
        handler.removeCallbacks(trackTimeout)
        pendingTrack?.result?.error("track", message, mapOf("sessionId" to session))
        pendingTrack = null
        externalPending?.error("track", message, mapOf("sessionId" to session))
        externalPending = null
    }

    private fun cancelPending(reason: String) {
        handler.removeCallbacks(openTimeout)
        handler.removeCallbacks(trackTimeout)
        pendingOpen?.error(reason, "Playback open $reason", mapOf("sessionId" to session))
        pendingOpen = null
        trackFailure("Track selection $reason")
    }

    private fun fail(message: String) {
        handler.removeCallbacks(openTimeout)
        pendingOpen?.error("playback", message, mapOf("sessionId" to session))
        pendingOpen = null
        trackFailure(message)
        view?.keepScreenOn = false
        emit("playing", false)
        emit("error", message)
        stop()
    }

    private fun emit(kind: String, value: Any) { send(session, kind, value) }

    private fun retire(previous: Running?) {
        if (previous == null) return
        previous.alive.set(false)
        previous.thread?.join()
        previous.audioThread?.join()
        CoreNative.destroy(previous.handle)
    }

    // AudioTrack owns a dedicated feeder: a blocked surface must never delay PCM.
    private fun pumpAudio(active: Running) {
        var audio: CoreAudioOutput? = null
        var pending: CoreAudioFrame? = null
        var pendingOffset = 0
        var timeline = -1L
        var audioClockActive = false
        var sampledRoute = emptySet<Int>()
        try {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO)
            while (active.alive.get() && generation.get() == active.generation) {
                val snap = CoreNative.snapshot(active.handle) ?: throw IllegalStateException("Core snapshot unavailable")
                if (snap[0] == 8L) throw IllegalStateException("FFmpeg core error ${snap[4]}")
                if (snap[3] != timeline) {
                    timeline = snap[3]
                    pending = null; pendingOffset = 0
                    audioReady = false
                    audioClockActive = false
                    active.drainedAudioTimeline.set(-1)
                    synchronized(outputLock) { audio?.flush() }
                }
                if (snap[6] >= 0 && snap[11] == 1L && audio == null) {
                    audio = CoreAudioOutput()
                    audio.setVolume(volume)
                    audio.setRouteListener { handler.post { refreshAudioRoute() } }
                    synchronized(outputLock) { audioOutput = audio }
                }
                synchronized(outputLock) {
                    val routed = audio?.routedDeviceIds().orEmpty()
                    if (routed.isNotEmpty() && routed != sampledRoute) {
                        sampledRoute = routed
                        pendingRoute = try {
                            probeAudioSink(context, routed)
                        } catch (_: RuntimeException) {
                            AudioSinkCapability(2, 0, false)
                        }
                    }
                    val requested = pendingRoute
                    if (requested != null &&
                        (requested.channels != sinkChannels || requested.accept != sinkAccept ||
                            requested.atmos != sinkAtmos)) {
                        sinkChannels = requested.channels
                        sinkAccept = requested.accept
                        sinkAtmos = requested.atmos
                        CoreNative.configureAudioSink(active.handle, sinkChannels, sinkAccept, sinkAtmos)
                        audio?.flush()
                        pending = null
                        pendingOffset = 0
                    }
                    val audible = !desiredPaused && snap[0] in 3L..6L
                    if (audible) audio?.play() else audio?.pause()
                    if (audible && audio != null) {
                        val latest = CoreNative.snapshot(active.handle)
                        if (latest == null || latest[1] != snap[1] || latest[3] != snap[3]) {
                            pending = null
                            pendingOffset = 0
                            audio.flush()
                        } else {
                            audio.setSpeed((latest[16] / 1000.0).toFloat())
                            if (pending == null) {
                                pending = CoreNative.takeAudio(active.handle)
                                pendingOffset = 0
                            }
                            val frame = pending
                            if (frame != null) {
                                if (frame.session != snap[1] || frame.timeline != snap[3]) {
                                    pending = null; pendingOffset = 0
                                } else {
                                    // PCM carries source-time samples. AudioTrack applies
                                    // tempo; multiplying this clock by rate counts it twice.
                                    val written = audio.write(frame, pendingOffset, 1.0)
                                    if (written == AUDIO_WRITE_DROP) {
                                        pending = null
                                        pendingOffset = 0
                                        audio.flush()
                                    } else if (written == AUDIO_WRITE_REJECT) {
                                        val bit = if (frame.codec == 2) 2 else 1
                                        sinkAccept = sinkAccept and bit.inv()
                                        if (sinkAccept and 1 == 0) sinkAtmos = false
                                        val channels = try {
                                            probeAudioSink(context, audio.routedDeviceIds()).channels
                                        } catch (_: RuntimeException) {
                                            2
                                        }
                                        sinkChannels = channels
                                        val next = AudioSinkCapability(sinkChannels, sinkAccept, sinkAtmos)
                                        pendingRoute = next
                                        CoreNative.configureAudioSink(active.handle, sinkChannels, sinkAccept, sinkAtmos)
                                        audio.flush()
                                        pending = null
                                        pendingOffset = 0
                                    } else if (written < 0) {
                                        throw IllegalStateException("AudioTrack write failed: $written")
                                    } else {
                                        if (written > 0) audioReady = true
                                        pendingOffset += written
                                        if (pendingOffset >= frame.bytes.size) {
                                            pending = null; pendingOffset = 0
                                        }
                                    }
                                }
                            }
                            if (pending != null || snap[14] > 0 || !audio.drained()) {
                                audio.clock()?.let { (tail, delay) ->
                                    if (CoreNative.reportAudio(active.handle, snap[1], snap[3],
                                            tail, delay) == 0) audioClockActive = true
                                }
                            }
                        }
                    }
                    if (audioClockActive && audio?.clock() == null) {
                        if (CoreNative.reportAudioUnavailable(active.handle, snap[1], snap[3]) == 0)
                            audioClockActive = false
                    }
                    if (audioClockActive && pending == null && snap[14] == 0L &&
                        audio?.drained() == true) {
                        audio.clock()?.let { (tail, delay) ->
                            CoreNative.reportAudio(active.handle, snap[1], snap[3], tail, delay)
                        }
                        if (CoreNative.reportAudioUnavailable(active.handle, snap[1], snap[3]) == 0)
                            audioClockActive = false
                    }
                }
                synchronized(outputLock) {
                    if (snap[12] == 1L && snap[14] == 0L && pending == null) {
                        audio?.finishInput()
                        if (audio == null || audio.drained())
                            active.drainedAudioTimeline.set(timeline)
                    }
                }
                outputWaitLock.withLock {
                    if (active.alive.get())
                        outputWake.await(if (desiredPaused) 100L else 4L, TimeUnit.MILLISECONDS)
                }
            }
        } catch (error: Throwable) {
            handler.post { if (generation.get() == active.generation) fail(error.message ?: "Native audio failed") }
        } finally {
            synchronized(outputLock) {
                audioOutput = null
                audio?.release()
            }
        }
    }

    private fun pump(active: Running) {
        var timeline = -1L
        var outputSurfaceRevision = -1
        var outputViewport = Pair(-1, -1)
        var lastTick = 0L
        var lastEnded = false
        var hdrDisplaySupported = false
        var hintedFrameRate = 0f
        try {
            while (active.alive.get() && generation.get() == active.generation) {
                val surfaceState = synchronized(surfaceLock) { Pair(surface, surfaceRevision.get()) }
                val videoSurface = surfaceState.first
                if (surfaceState.second != outputSurfaceRevision) {
                    CoreNative.releaseColorRenderer()
                    val display = view?.display ?: context.getSystemService(DisplayManager::class.java)
                        ?.getDisplay(Display.DEFAULT_DISPLAY)
                    hdrDisplaySupported = display?.hdrCapabilities?.supportedHdrTypes
                        ?.contains(Display.HdrCapabilities.HDR_TYPE_HDR10) == true
                    CoreNative.outputSurface(active.handle, videoSurface, doviProfiles)
                    outputSurfaceRevision = surfaceState.second
                    hintedFrameRate = 0f
                }
                val requestedViewport = viewport
                if (requestedViewport != outputViewport) {
                    CoreNative.videoOutputSize(active.handle,
                        requestedViewport.first, requestedViewport.second)
                    outputViewport = requestedViewport
                }
                val snap = CoreNative.snapshot(active.handle) ?: throw IllegalStateException("Core snapshot unavailable")
                if (snap[0] == 8L) throw IllegalStateException("FFmpeg core error ${snap[4]}")
                if (snap[3] != timeline) {
                    timeline = snap[3]
                    lastEnded = false
                    handler.post { if (generation.get() == active.generation) {
                        renderedFirst = false; view?.clearOverlay()
                    } }
                }
                val frame = videoSurface?.takeIf { it.isValid }
                    ?.let { CoreNative.renderVideo(active.handle, it, hdrDisplaySupported) }
                if (frame != null && frame[6] == snap[1] && frame[7] == snap[3] && generation.get() == active.generation) {
                    lastPresentedUs = frame[0]
                    val overlay = CoreNative.takeVideoOverlay(active.handle)
                    handler.post {
                        if (generation.get() == active.generation) {
                            val current = CoreNative.snapshot(active.handle)
                            if (current != null && current[1] == frame[6] && current[3] == frame[7]) {
                                view?.frame(frame[1].toInt(), frame[2].toInt(), frame[3].toInt(),
                                    frame[4].toInt(), frame[5].toInt())
                                if (overlay != null) view?.overlay(overlay)
                                if (!renderedFirst) { renderedFirst = true; emit("firstFrame", true) }
                            }
                        }
                    }
                }
                if (snap[12] == 1L && snap[13] == 0L && snap[14] == 0L &&
                    active.drainedAudioTimeline.get() == snap[3])
                    CoreNative.reportDrained(active.handle, snap[1], snap[3])
                val now = android.os.SystemClock.elapsedRealtime()
                if (now - lastTick >= 250) {
                    lastTick = now
                    if (Build.VERSION.SDK_INT >= 30 && videoSurface?.isValid == true) {
                        val rate = (CoreNative.videoFrameRate(active.handle) * snap[16] / 1000.0).toFloat()
                        if (rate.isFinite() && rate in 1f..240f && rate != hintedFrameRate) {
                            try {
                                videoSurface.setFrameRate(rate, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
                                hintedFrameRate = rate
                            } catch (_: IllegalArgumentException) {
                                // Display hint rejection does not invalidate decoded video.
                            } catch (_: IllegalStateException) {
                                // The Surface can be retired during a display/lock transition.
                            }
                        }
                    }
                    val copy = snap.copyOf()
                    handler.post { if (generation.get() == active.generation) update(active, copy) }
                }
                if (snap[0] == 7L && !lastEnded) {
                    lastEnded = true
                    handler.post { if (generation.get() == active.generation && !emittedCompletion) {
                        emittedCompletion = true; emit("completed", true) } }
                }
                if (desiredPaused || (videoSurface == null && snap[6] < 0)) {
                    // Poll metadata at 4 Hz while opening/paused, but wake
                    // immediately for play, seek, surface changes or stop.
                    outputWaitLock.withLock {
                        if (active.alive.get() && generation.get() == active.generation)
                            outputWake.await(250, TimeUnit.MILLISECONDS)
                    }
                } else {
                    // Surface posts already pace output. A fixed 15 ms sleep
                    // after every post further reduces effective frame rate.
                    outputWaitLock.withLock {
                        if (active.alive.get() && generation.get() == active.generation)
                            outputWake.await(if (frame == null) 2 else 1, TimeUnit.MILLISECONDS)
                    }
                }
            }
        } catch (error: Throwable) {
            handler.post { if (generation.get() == active.generation) fail(error.message ?: "Native output failed") }
        } finally {
            CoreNative.releaseColorRenderer()
        }
    }

    private fun update(active: Running, snap: LongArray) {
        emit("position", (snap[9] / 1000).coerceAtLeast(0))
        emit("duration", (snap[8] / 1000).coerceAtLeast(0))
        publishObservedOutput(active, snap)
        val newBuffering = snap[0] == 5L || snap[0] == 6L
        if (newBuffering != buffering) { buffering = newBuffering; emit("buffering", buffering) }
        val playing = !desiredPaused && snap[0] == 3L && (renderedFirst || snap[5] < 0)
        if (playing != lastPlaying) {
            lastPlaying = playing
            view?.keepScreenOn = playing
            emit("playing", playing)
        }
        val current = CoreNative.snapshot(active.handle)
        if (current == null || current[1] != snap[1] || current[3] != snap[3]) return
        val now = android.os.SystemClock.elapsedRealtime()
        if (debugDiagnostics && now - lastDiagnosticMs >= 2000) {
            lastDiagnosticMs = now
            android.util.Log.i("RillightPresent", "generation=${active.generation} timeline=${snap[3]} " +
                "state=${snap[0]} posMs=${snap[9] / 1000} presentedMs=${lastPresentedUs / 1000} " +
                "first=$renderedFirst surface=${surface?.isValid == true} paused=$desiredPaused " +
                "audioReady=$audioReady hardware=$lastHardware vq=${snap[13]} aq=${snap[14]}")
        }
        if (snap[5] >= 0 && snap[10] == 1L && now - lastDecoderCheckMs >= 1000) {
            lastDecoderCheckMs = now
            for (ordinal in 0 until CoreNative.trackCount(active.handle)) {
                val video = CoreNative.track(active.handle, ordinal) ?: continue
                if (video[1] == 1 && video[0].toLong() == snap[5]) {
                    emitDecoderIfChanged(video)
                    break
                }
            }
        }
        val open = pendingOpen
        if (open != null && snap[0] in 2L..6L &&
            (snap[5] < 0 && snap[11] == 1L && (desiredPaused || audioReady) || renderedFirst)) {
            handler.removeCallbacks(openTimeout)
            updateTrackMapping(active.handle)
            pendingOpen = null
            emit("ready", true)
            open.success(successMap(active.handle))
        }
        val external = externalPending
        if (external != null && snap[15] == 0L) {
            val count = CoreNative.trackCount(active.handle)
            val selected = (0 until count).mapNotNull { CoreNative.track(active.handle, it) }
                .lastOrNull { it[1] == 3 && it[5] == 1 }
            if (selected == null || snap[4] != 0L) trackFailure("External subtitle could not be loaded")
            else {
                externalPending = null
                handler.removeCallbacks(trackTimeout)
                val code = synchronized(outputLock) {
                    val chosen = CoreNative.selectSubtitle(active.handle, selected[0], operation.incrementAndGet())
                    if (chosen == 0) audioOutput?.flush()
                    chosen
                }
                if (code == 0) beginTrack(external, selected[0], true, active.handle)
                else external.error("track", "External subtitle selection failed", mapOf("sessionId" to session))
            }
        }
        confirmTrack(active, snap)
    }

    // The pump already reads kind, delivery and effective tiers. Push the same
    // sample as outputStatus when one of them, or a reason, changes.
    private fun publishObservedOutput(active: Running, snap: LongArray) {
        val reasons = CoreNative.enhancementStatus(active.handle)
        if (!CoreOutputWatch.changed(watchedOutput, snap, watchedReasons, reasons)) return
        watchedOutput = snap.copyOf()
        watchedReasons = reasons?.copyOf()
        emit("outputStatus", successMap(active.handle))
    }

    private fun confirmTrack(active: Running, snapshot: LongArray?): Boolean {
        val track = pendingTrack ?: return false
        if (!CoreTrackConfirmation.matches(snapshot, track.timeline, track.expected,
                track.subtitle)) return false
        pendingTrack = null
        handler.removeCallbacks(trackTimeout)
        updateTrackMapping(active.handle)
        track.result.success(successMap(active.handle))
        return true
    }

    private fun updateTrackMapping(handle: Long) {
        val tracks = (0 until CoreNative.trackCount(handle))
            .mapNotNull { ordinal -> CoreNative.track(handle, ordinal)?.let {
                Triple(it, CoreNative.trackLanguage(handle, ordinal)?.lowercase(), ordinal)
            } }
        tracks.firstOrNull { it.first[1] == 1 }?.first?.let(::emitDecoderIfChanged)
        val used = mutableSetOf<Int>()
        val result = mutableMapOf<Int, Int>()
        for (server in serverStreams) {
            val type = when (server.type) { "Video" -> 1; "Audio" -> 2; "Subtitle" -> 3; else -> 0 }
            if (type == 0 || server.external) continue
            val candidates = tracks.filter { (it.first[1] == type && it.first[5] == 0 && it.first[0] !in used) }
            val exact = candidates.firstOrNull { it.first[0] == server.index }
            val language = server.language?.lowercase()
            val matching = candidates.filter { language != null && it.second == language }
            val chosen = exact ?: matching.singleOrNull() ?: candidates.singleOrNull()
            if (chosen != null) { result[server.index] = chosen.first[0]; used += chosen.first[0] }
        }
        mapping = result
    }

    private fun emitDecoderIfChanged(video: IntArray) {
        if (lastHardware == video[4]) return
        lastHardware = video[4]
        emit("decoderHardware", mapOf("actual" to video[4],
            "preferred" to preferredHardware,
            "fallback" to (preferredHardware != 0 && video[4] == 0),
            "capabilities" to video[3], "codecId" to video[2]))
    }

    fun successMap(handle: Long? = running?.handle): Map<String, Any?> {
        val snap = handle?.let(CoreNative::snapshot)
        val actualHardware = handle?.let { core ->
            CoreTrackConfirmation.actualHardware((0 until CoreNative.trackCount(core))
                .mapNotNull { CoreNative.track(core, it) })
        } ?: 0
        val audioIndex = snap?.get(6)?.toInt()?.let { native -> mapping.entries.firstOrNull { it.value == native }?.key }
        val subtitleIndex = snap?.get(7)?.toInt()?.let { native -> mapping.entries.firstOrNull { it.value == native }?.key }
        val playableAudio = serverStreams.filter { it.type == "Audio" && it.index in mapping }.map { it.index }
        val playableText = serverStreams.filter { it.type == "Subtitle" && it.index in mapping }.map { it.index }
        val rejectedAudio = serverStreams.filter { it.type == "Audio" && it.index !in mapping }.map { it.index }
        val rejectedText = serverStreams.filter { it.type == "Subtitle" && !it.external && it.index !in mapping }.map { it.index }
        val containerIds = handle?.let(CoreNative::containerTrackIds)
        return mapOf("sessionId" to session, "audioIndex" to audioIndex,
            "subtitleIndex" to subtitleIndex, "playableAudio" to playableAudio,
            "rejectedAudio" to rejectedAudio, "playableSubtitle" to playableText,
            "rejectedSubtitle" to rejectedText,
            "videoTrackId" to containerIds?.getOrNull(0)?.takeIf { it > 0 },
            "audioTrackId" to containerIds?.getOrNull(1)?.takeIf { it > 0 },
            // Decoder actually used for the video track; 0 means software or no video.
            "actualHardware" to actualHardware,
            "dolbyVisionProfile" to (snap?.getOrNull(17)?.toInt() ?: -1),
            "videoOutputKind" to (snap?.getOrNull(18)?.toInt() ?: 0),
            "audioDelivery" to (snap?.getOrNull(19)?.toInt() ?: 0),
            "audioChannels" to (snap?.getOrNull(20)?.toInt() ?: 0),
            "audioLayout" to (snap?.getOrNull(21)?.toInt() ?: 0),
            "audioAtmos" to (snap?.getOrNull(22)?.toInt() ?: 0),
            "audioCodecId" to (snap?.getOrNull(23)?.toInt() ?: 0),
            "requestedInterpolation" to (snap?.getOrNull(24)?.toInt() ?: 0),
            "effectiveInterpolation" to (snap?.getOrNull(25)?.toInt() ?: 0),
            "requestedAnime4k" to (snap?.getOrNull(26)?.toInt() ?: 0),
            "effectiveAnime4k" to (snap?.getOrNull(27)?.toInt() ?: 0),
            "requestedSuperResolution" to (snap?.getOrNull(28)?.toInt() ?: 0),
            "effectiveSuperResolution" to (snap?.getOrNull(29)?.toInt() ?: 0),
            "requestedDenoise" to (snap?.getOrNull(30)?.toInt() ?: 0),
            "effectiveDenoise" to (snap?.getOrNull(31)?.toInt() ?: 0),
            "requestedSharpen" to (snap?.getOrNull(32)?.toInt() ?: 0),
            "effectiveSharpen" to (snap?.getOrNull(33)?.toInt() ?: 0),
            "doviReconstruction" to (snap?.getOrNull(34)?.toInt() ?: 0),
            "dolbyVisionCompatibility" to (snap?.getOrNull(35)?.toInt() ?: -1)) +
            enhancementFields(handle)
    }

    private fun enhancementFields(handle: Long?): Map<String, Any> {
        if (handle == null) return emptyMap()
        val status = CoreNative.enhancementStatus(handle) ?: return emptyMap()
        fun at(index: Int) = status.getOrNull(index) ?: 0
        return mapOf(
            "reasonInterpolation" to at(10),
            "reasonAnime4k" to at(11),
            "reasonSuperResolution" to at(12),
            "reasonDenoise" to at(13),
            "reasonSharpen" to at(14),
            "interpolationBackend" to at(15),
            "anime4kBackend" to at(16),
            "superResolutionBackend" to at(17),
            "leftNativeDolby" to at(18),
            "sourceFrameRate" to CoreNative.videoFrameRate(handle),
            "outputFrameRate" to CoreNative.outputFrameRate(handle),
        )
    }

    private fun refreshAudioRoute() {
        val routed = synchronized(outputLock) { audioOutput?.routedDeviceIds().orEmpty() }
        val probed = try {
            probeAudioSink(context, routed)
        } catch (_: RuntimeException) {
            AudioSinkCapability(2, 0, false)
        }
        pendingRoute = probed
        wakeOutput()
    }

    private fun registerRouteWatcher() {
        if (deviceCallbackRegistered) return
        audioManager.registerAudioDeviceCallback(deviceCallback, handler)
        deviceCallbackRegistered = true
    }

    private fun unregisterRouteWatcher() {
        if (!deviceCallbackRegistered) return
        audioManager.unregisterAudioDeviceCallback(deviceCallback)
        deviceCallbackRegistered = false
    }

    private fun configureProbedAudioSink(handle: Long): Boolean {
        val probed = try {
            probeAudioSink(context)
        } catch (error: RuntimeException) {
            AudioSinkCapability(2, 0, false)
        }
        sinkChannels = probed.channels
        sinkAccept = probed.accept
        sinkAtmos = probed.atmos
        if (CoreNative.configureAudioSink(handle, sinkChannels, sinkAccept, sinkAtmos) == 0)
            return true
        sinkChannels = 2
        sinkAccept = 0
        sinkAtmos = false
        return CoreNative.configureAudioSink(handle, 2, 0, false) == 0
    }

    private fun requestFocus(): Boolean {
        if (!noisyRegistered) {
            context.registerReceiver(noisyReceiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
            noisyRegistered = true
        }
        val result = if (Build.VERSION.SDK_INT >= 26) {
            val request = focusRequest ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
                .setOnAudioFocusChangeListener(focusListener).build().also { focusRequest = it }
            audioManager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN)
        }
        return result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonFocus() {
        if (noisyRegistered) {
            context.unregisterReceiver(noisyReceiver)
            noisyRegistered = false
        }
        if (Build.VERSION.SDK_INT >= 26) focusRequest?.let(audioManager::abandonAudioFocusRequest)
        else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(focusListener)
        }
    }
}
