package com.rillight.player

import android.content.Context
import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.concurrent.atomic.AtomicLong

/** Only a sealed loopback transport or an app-private subtitle may reach FFmpeg. */
internal class CoreIoFactory(context: Context) {
    private val privateRoot = File(context.applicationInfo.dataDir).canonicalFile

    fun open(raw: String): CoreInput? {
        val uri = try { URI(raw) } catch (_: Exception) { return null }
        if (uri.userInfo != null || uri.fragment != null) return null
        return when (uri.scheme?.lowercase()) {
            "http" -> if (uri.host == "127.0.0.1" && uri.port in 1..65535)
                CoreInput(raw, null) else null
            "file" -> {
                val file = try { File(uri).canonicalFile } catch (_: Exception) { return null }
                if (!file.isFile || !file.toPath().startsWith(privateRoot.toPath())) null
                else CoreInput(null, file)
            }
            else -> null
        }
    }
}

/** AVIO-compatible input. interrupt() never waits for read/seek and is reusable. */
internal class CoreInput(private val url: String?, private val file: File?) {
    private val epoch = AtomicLong()
    @Volatile private var connection: HttpURLConnection? = null
    @Volatile private var input: InputStream? = null
    private var localFile: RandomAccessFile? = null
    private var position = 0L
    private var total = -1L
    private var connectionEpoch = -1L
    private var httpPosition = 0L
    private var responseRemaining = -1L
    private var wholeResponse = false
    // MP4 audio/video chunks can be far apart. Retain a few bounded windows
    // so interleaved packet reads do not reopen loopback HTTP for each packet.
    private val blocks = java.util.LinkedHashMap<Long, ByteArray>(8, 0.75f, true)
    private var blockBytes = 256 * 1024
    private var previousWindowEnd = -1L

    fun read(buffer: ByteArray, size: Int): Int {
        if (size !in 1..buffer.size) return -22
        val observed = epoch.get()
        return try {
            val local = file
            val count = if (local != null) {
                val reader = localFile ?: RandomAccessFile(local, "r").also { localFile = it }
                reader.seek(position)
                reader.read(buffer, 0, size)
            } else {
                readHttp(buffer, size, observed)
            }
            if (epoch.get() != observed) return -4
            if (count < 0) 0 else { position += count; count }
        } catch (_: java.net.SocketTimeoutException) {
            if (epoch.get() != observed) -4 else -11
        } catch (_: Exception) {
            if (epoch.get() != observed) -4 else -5
        }
    }

    fun seek(offset: Long, whence: Int): Long {
        val observed = epoch.get()
        return try {
            if (connectionEpoch != observed) closeHttp()
            val base = when (whence and 0xffff) {
                0 -> 0L
                1 -> position
                2 -> length(observed).takeIf { it >= 0 } ?: return -38
                else -> return -22
            }
            if ((whence and 0x10000) != 0) return length(observed)
            val target = Math.addExact(base, offset)
            if (target < 0) return -22
            if (target != position) {
                position = target
            }
            target
        } catch (_: Exception) {
            if (epoch.get() != observed) -4 else -5
        }
    }

    fun interrupt() {
        epoch.incrementAndGet()
        // HttpURLConnection.disconnect() is a signal; do not acquire a read lock.
        connection?.disconnect()
    }

    fun close() {
        interrupt()
        closeHttp()
        localFile?.close()
        localFile = null
        blocks.clear()
    }

    private fun length(observed: Long): Long {
        if (file != null) return file.length()
        if (total >= 0) return total
        ensureHttp(observed)
        return total.takeIf { it >= 0 } ?: -38
    }

    private fun ensureHttp(observed: Long) {
        if (connectionEpoch != observed) closeHttp()
        if (input != null && httpPosition == position) return
        if (input != null) closeHttp()
        val request = URL(url).openConnection() as HttpURLConnection
        connection = request
        request.instanceFollowRedirects = false
        request.useCaches = false
        request.connectTimeout = 10_000
        // The owned proxy may spend 20 seconds waiting for origin headers,
        // then renew/reconnect. Let that recovery finish before AVIO fails;
        // CorePlayback still bounds initial readiness at 60 seconds, and
        // interrupt() cancels seek/stop immediately instead of waiting here.
        request.readTimeout = 45_000
        request.setRequestProperty("Accept-Encoding", "identity")
        val requestEnd = position + minOf(blockBytes.toLong() - 1, Long.MAX_VALUE - position)
        // Let the owned proxy adopt the first response as its continuous
        // download. Subsequent distant reads stay bounded and reusable. An
        // initial tiny range otherwise closes the origin response before the
        // proxy can hand it to the downloader, adding another network open.
        val bootstrap = position == 0L && total < 0 && blocks.isEmpty()
        request.setRequestProperty("Range", if (bootstrap) "bytes=0-" else "bytes=$position-$requestEnd")
        val status = request.responseCode
        if (epoch.get() != observed) { request.disconnect(); throw java.io.InterruptedIOException() }
        if (status !in 200..299 || (position > 0 && status != 206)) {
            request.disconnect()
            throw java.io.IOException("Unexpected media HTTP status $status")
        }
        val contentRange = request.getHeaderField("Content-Range")
        val rangeStart = contentRange?.substringAfter(' ')?.substringBefore('-')?.toLongOrNull()
        if (status == 206 && rangeStart != position) {
            request.disconnect()
            throw java.io.IOException("Mismatched media byte range")
        }
        val rangeTotal = contentRange?.substringAfterLast('/')?.toLongOrNull()
        if (rangeTotal != null) total = rangeTotal
        else if (status == 200) total = request.contentLengthLong
        input = request.inputStream
        httpPosition = position
        responseRemaining = request.contentLengthLong
        wholeResponse = status == 200
        connectionEpoch = observed
        if (epoch.get() != observed) { closeHttp(); throw java.io.InterruptedIOException() }
    }

    private fun readHttp(buffer: ByteArray, size: Int, observed: Long): Int {
        if (total >= 0 && position >= total) return -1
        val cached = blocks.entries.firstOrNull { (start, bytes) ->
            position >= start && position - start < bytes.size
        }
        val start: Long
        val bytes: ByteArray
        if (cached != null) {
            start = cached.key
            bytes = blocks[start]!! // Touch the LRU entry.
        } else {
            // Grow only consecutive reads (large MP4 sample tables in particular).
            // A distant track/index seek retains the small first window. The
            // eight-entry LRU remains bounded to at most 8 MiB per input.
            blockBytes = if (position == previousWindowEnd)
                minOf(blockBytes * 2, 1024 * 1024) else 256 * 1024
            ensureHttp(observed)
            start = position
            // Return the initial probe as soon as the requested bytes arrive.
            // A slow first response must not fill a speculative 256 KiB window
            // before FFmpeg can inspect its header. Keep this response open;
            // following reads still grow the ordinary reusable windows.
            val firstProbe = position == 0L && previousWindowEnd < 0
            val windowBytes = if (firstProbe) minOf(size, blockBytes) else blockBytes
            val capacity = if (responseRemaining >= 0)
                minOf(windowBytes.toLong(), responseRemaining).toInt() else windowBytes
            val pending = ByteArray(capacity)
            var count = 0
            while (count < capacity) {
                val read = try { input!!.read(pending, count, capacity - count) }
                catch (failure: java.io.IOException) {
                    closeHttp()
                    if (count == 0) throw failure
                    break // Preserve the prefix; the next window resumes it.
                }
                if (epoch.get() != observed) throw java.io.InterruptedIOException()
                if (read < 0) {
                    if (wholeResponse && total < 0) total = httpPosition
                    closeHttp()
                    break
                }
                if (read == 0) break
                count += read
                httpPosition += read
                if (responseRemaining >= 0) responseRemaining -= read
            }
            if (responseRemaining == 0L) closeHttp()
            if (count == 0) {
                if (total >= 0 && position < total) throw java.io.EOFException()
                return -1
            }
            bytes = if (count == pending.size) pending else pending.copyOf(count)
            previousWindowEnd = start + bytes.size
            blocks[start] = bytes
            while (blocks.size > 8) blocks.remove(blocks.keys.first())
        }
        val offset = (position - start).toInt()
        val count = minOf(size, bytes.size - offset)
        bytes.copyInto(buffer, 0, offset, offset + count)
        return count
    }

    private fun closeHttp() {
        val oldInput = input
        input = null
        val oldConnection = connection
        connection = null
        connectionEpoch = -1
        try { oldInput?.close() } finally { oldConnection?.disconnect() }
    }
}
