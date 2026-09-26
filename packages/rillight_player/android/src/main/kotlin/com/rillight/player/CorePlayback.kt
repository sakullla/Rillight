package com.rillight.player

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.view.Surface
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/** One owner has at most one ABI6 core. Shutdown and reopen run off the UI thread. */
internal class CorePlayback(
    private val context: Context,
    val id: String,
    private val handler: Handler,
    private val send: (String, String, Any) -> Unit,
) : SurfaceOwner {
    private data class Running(val handle: Long, val generation: Int,
                               val alive: AtomicBoolean = AtomicBoolean(true),
                               var thread: Thread? = null)
    private data class TrackRequest(val result: MethodChannel.Result, val expected: Int,
                                    val subtitle: Boolean)
    private data class ServerStream(val index: Int, val type: String,
                                    val language: String?, val external: Boolean)
    private val serial = Executors.newSingleThreadExecutor()
    private val generation = AtomicInteger()
    private val operation = AtomicLong()
    private val surfaceLock = Any()
    private val outputLock = Any()
    private var surface: Surface? = null
    private var audioOutput: CoreAudioOutput? = null
    private var running: Running? = null
    private var pendingOpen: MethodChannel.Result? = null
    private var pendingTrack: TrackRequest? = null
    private var externalPending: MethodChannel.Result? = null
    private val openTimeout = Runnable { fail("Media ready / first frame timed out") }
    private val trackTimeout = Runnable { trackFailure("Native track selection timed out") }
    private var serverStreams = emptyList<ServerStream>()
    private var mapping = emptyMap<Int, Int>()
    @Volatile private var requestedStartUs = 0L
    @Volatile private var requestedStartApplied = false
    @Volatile private var desiredPaused = false
    @Volatile private var audioReady = false
    private var renderedFirst = false
    private var emittedCompletion = false
    private var buffering = false
    private var lastPlaying = false
    private var scaleMode = "fit"
    private var lastHardware: Int? = null
    @Volatile private var volume = 1f
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
                handler.post { interruption("headphones") }
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
        synchronized(surfaceLock) { this.surface = surface }
    }

    fun setScale(mode: String?) {
        scaleMode = if (mode == "fill") "fill" else "fit"
        view?.scale(scaleMode)
    }

    fun open(token: String, args: Map<*, *>, result: MethodChannel.Result) {
        val address = args["url"] as? String
        if (address == null || CoreIoFactory(context).open(address) == null) {
            result.error("source", "Core requires a sealed loopback URL", mapOf("sessionId" to token))
            return
        }
        val revision = generation.incrementAndGet()
        val previous = running
        previous?.alive?.set(false)
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
        requestedStartUs = ((args["start"] as? Number)?.toLong() ?: 0).coerceAtLeast(0) * 1000
        requestedStartApplied = requestedStartUs == 0L
        desiredPaused = args["paused"] == true
        audioReady = false
        renderedFirst = false
        emittedCompletion = false
        buffering = false
        lastPlaying = false
        mapping = emptyMap()
        lastHardware = null
        operation.set(0)
        handler.removeCallbacks(openTimeout)
        handler.postDelayed(openTimeout, 22_000)
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
                CoreNative.open(handle, address, operation.incrementAndGet()) == 0 &&
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
                if (desiredPaused) {
                    CoreNative.play(handle, false, operation.incrementAndGet())
                } else if (!requestFocus()) {
                    desiredPaused = true
                    CoreNative.play(handle, false, operation.incrementAndGet())
                    emit("interruption", "audioFocus")
                }
                active.thread = Thread({ pump(active) }, "rillight-android-core-$revision").also { it.start() }
            }
        }
    }

    fun command(method: String, args: Map<*, *>, result: MethodChannel.Result) {
        val active = running ?: run {
            result.error("control", "Playback is opening or closed", mapOf("sessionId" to session)); return
        }
        val handle = active.handle
        try {
            val accepted = when (method) {
                "play" -> {
                    desiredPaused = false
                    if (!requestFocus()) {
                        desiredPaused = true
                        CoreNative.play(handle, false, operation.incrementAndGet())
                        emit("interruption", "audioFocus")
                        -1
                    }
                    else CoreNative.play(handle, true, operation.incrementAndGet())
                }
                "pause" -> { desiredPaused = true; CoreNative.play(handle, false, operation.incrementAndGet()) }
                "seek" -> synchronized(outputLock) {
                    val code = CoreNative.seek(handle,
                        ((args["position"] as? Number)?.toLong() ?: -1L) * 1000,
                        operation.incrementAndGet())
                    if (code == 0) audioOutput?.flush()
                    code
                }
                "rate" -> synchronized(outputLock) {
                    val code = CoreNative.speed(handle,
                        (args["value"] as? Number)?.toDouble() ?: Double.NaN,
                        operation.incrementAndGet())
                    if (code == 0) audioOutput?.flush()
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
                    if (code == 0) { beginTrack(TrackRequest(result, stream, method == "subtitle")); return }
                    code
                }
                "subtitleOff" -> {
                    val code = synchronized(outputLock) {
                        val selected = CoreNative.selectSubtitle(handle, -1, operation.incrementAndGet())
                        if (selected == 0) audioOutput?.flush()
                        selected
                    }
                    if (code == 0) { beginTrack(TrackRequest(result, -1, true)); return }
                    code
                }
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
            if (accepted != 0) result.error("control", "Core rejected $method", mapOf("sessionId" to session))
            else result.success(successMap(handle))
        } catch (error: Throwable) {
            result.error("control", error.message ?: "Core command failed", mapOf("sessionId" to session))
        }
    }

    fun stop(result: MethodChannel.Result? = null) {
        val stoppedSession = session
        generation.incrementAndGet()
        val previous = running
        previous?.alive?.set(false)
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
        view?.keepScreenOn = false
        emit("playing", false)
        emit("interruption", reason)
    }

    private fun beginTrack(request: TrackRequest) {
        pendingTrack?.result?.error("superseded", "Track selection superseded", mapOf("sessionId" to session))
        pendingTrack = request
        handler.removeCallbacks(trackTimeout)
        handler.postDelayed(trackTimeout, 4_500)
    }

    private fun trackFailure(message: String) {
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
        CoreNative.destroy(previous.handle)
    }

    private fun pump(active: Running) {
        var audio: CoreAudioOutput? = null
        var pending: CoreAudioFrame? = null
        var pendingOffset = 0
        var timeline = -1L
        var audioClockActive = false
        var lastTick = 0L
        var lastEnded = false
        try {
            while (active.alive.get() && generation.get() == active.generation) {
                val snap = CoreNative.snapshot(active.handle) ?: throw IllegalStateException("Core snapshot unavailable")
                if (snap[3] != timeline) {
                    timeline = snap[3]
                    pending = null; pendingOffset = 0
                    audioReady = false
                    audioClockActive = false
                    synchronized(outputLock) { audio?.flush() }
                    handler.post { if (generation.get() == active.generation) renderedFirst = false }
                }
                if (snap[0] == 8L) throw IllegalStateException("FFmpeg core error ${snap[4]}")
                if (!requestedStartApplied && snap[0] in 2L..6L && snap[10] == 1L) {
                    if (synchronized(outputLock) {
                        CoreNative.seek(active.handle, requestedStartUs, operation.incrementAndGet())
                    } != 0)
                        throw IllegalStateException("Start position unavailable")
                    requestedStartApplied = true
                    continue
                }
                if (snap[6] >= 0 && snap[11] == 1L && audio == null) {
                    audio = CoreAudioOutput()
                    audio.setVolume(volume)
                    synchronized(outputLock) { audioOutput = audio }
                }
                synchronized(outputLock) {
                    val audible = !desiredPaused && snap[0] in 3L..6L
                    if (audible) audio?.play() else audio?.pause()
                    if (audible && audio != null) {
                        val latest = CoreNative.snapshot(active.handle)
                        if (latest == null || latest[1] != snap[1] || latest[3] != snap[3]) {
                            pending = null
                            pendingOffset = 0
                            audio.flush()
                        } else {
                            if (pending == null) {
                                pending = CoreNative.takeAudio(active.handle)
                                pendingOffset = 0
                            }
                            val frame = pending
                            if (frame != null) {
                                if (frame.session != snap[1] || frame.timeline != snap[3]) {
                                    pending = null; pendingOffset = 0
                                } else {
                                    val written = audio.write(frame, pendingOffset, snap[16] / 1000.0)
                                    if (written > 0) audioReady = true
                                    pendingOffset += written
                                    if (pendingOffset >= frame.bytes.size) {
                                        pending = null; pendingOffset = 0
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
                    if (audioClockActive && pending == null && snap[14] == 0L &&
                        audio?.drained() == true) {
                        audio.clock()?.let { (tail, delay) ->
                            CoreNative.reportAudio(active.handle, snap[1], snap[3], tail, delay)
                        }
                        if (CoreNative.reportAudioUnavailable(active.handle, snap[1], snap[3]) == 0)
                            audioClockActive = false
                    }
                }
                val videoSurface = synchronized(surfaceLock) { surface }
                val frame = videoSurface?.takeIf { it.isValid }
                    ?.let { CoreNative.renderVideo(active.handle, it) }
                if (frame != null && frame[6] == snap[1] && frame[7] == snap[3]) {
                    handler.post {
                        if (generation.get() == active.generation) {
                            val current = CoreNative.snapshot(active.handle)
                            if (current != null && current[1] == frame[6] && current[3] == frame[7]) {
                                view?.frame(frame[1].toInt(), frame[2].toInt(), frame[3].toInt(),
                                    frame[4].toInt(), frame[5].toInt())
                                if (!renderedFirst) { renderedFirst = true; emit("firstFrame", true) }
                            }
                        }
                    }
                }
                if (snap[12] == 1L && snap[13] == 0L && snap[14] == 0L &&
                    pending == null && (audio == null || audio.drained())) {
                    CoreNative.reportDrained(active.handle, snap[1], snap[3])
                }
                val now = android.os.SystemClock.elapsedRealtime()
                if (now - lastTick >= 250) {
                    lastTick = now
                    val copy = snap.copyOf()
                    handler.post { if (generation.get() == active.generation) update(active, copy) }
                }
                if (snap[0] == 7L && !lastEnded) {
                    lastEnded = true
                    handler.post { if (generation.get() == active.generation && !emittedCompletion) {
                        emittedCompletion = true; emit("completed", true) } }
                }
                Thread.sleep(15)
            }
        } catch (error: Throwable) {
            handler.post { if (generation.get() == active.generation) fail(error.message ?: "Native output failed") }
        } finally {
            synchronized(outputLock) {
                audioOutput = null
                audio?.release()
            }
        }
    }

    private fun update(active: Running, snap: LongArray) {
        emit("position", (snap[9] / 1000).coerceAtLeast(0))
        emit("duration", (snap[8] / 1000).coerceAtLeast(0))
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
        val open = pendingOpen
        if (open != null && requestedStartApplied && snap[0] in 2L..6L &&
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
                if (code == 0) beginTrack(TrackRequest(external, selected[0], true))
                else external.error("track", "External subtitle selection failed", mapOf("sessionId" to session))
            }
        }
        val track = pendingTrack
        if (track != null && snap[0] in 2L..4L &&
            (if (track.subtitle) snap[7] else snap[6]) == track.expected.toLong()) {
            pendingTrack = null
            handler.removeCallbacks(trackTimeout)
            updateTrackMapping(active.handle)
            track.result.success(successMap(active.handle))
        }
    }

    private fun updateTrackMapping(handle: Long) {
        val tracks = (0 until CoreNative.trackCount(handle))
            .mapNotNull { ordinal -> CoreNative.track(handle, ordinal)?.let {
                Triple(it, CoreNative.trackLanguage(handle, ordinal)?.lowercase(), ordinal)
            } }
        tracks.firstOrNull { it.first[1] == 1 }?.first?.let { video ->
            if (lastHardware != video[4]) {
                lastHardware = video[4]
                emit("decoderHardware", mapOf("actual" to video[4],
                    "capabilities" to video[3], "codecId" to video[2]))
            }
        }
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

    fun successMap(handle: Long? = running?.handle): Map<String, Any?> {
        val snap = handle?.let(CoreNative::snapshot)
        val audioIndex = snap?.get(6)?.toInt()?.let { native -> mapping.entries.firstOrNull { it.value == native }?.key }
        val subtitleIndex = snap?.get(7)?.toInt()?.let { native -> mapping.entries.firstOrNull { it.value == native }?.key }
        val playableAudio = serverStreams.filter { it.type == "Audio" && it.index in mapping }.map { it.index }
        val playableText = serverStreams.filter { it.type == "Subtitle" && it.index in mapping }.map { it.index }
        val rejectedAudio = serverStreams.filter { it.type == "Audio" && it.index !in mapping }.map { it.index }
        val rejectedText = serverStreams.filter { it.type == "Subtitle" && !it.external && it.index !in mapping }.map { it.index }
        return mapOf("sessionId" to session, "audioIndex" to audioIndex,
            "subtitleIndex" to subtitleIndex, "playableAudio" to playableAudio,
            "rejectedAudio" to rejectedAudio, "playableSubtitle" to playableText,
            "rejectedSubtitle" to rejectedText)
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
