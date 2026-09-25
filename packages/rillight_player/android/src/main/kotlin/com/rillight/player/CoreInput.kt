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
                ensureHttp(observed)
                input!!.read(buffer, 0, size)
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
                closeHttp()
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
    }

    private fun length(observed: Long): Long {
        if (file != null) return file.length()
        if (total >= 0) return total
        ensureHttp(observed)
        return total.takeIf { it >= 0 } ?: -38
    }

    private fun ensureHttp(observed: Long) {
        if (connectionEpoch != observed) closeHttp()
        if (input != null) return
        val request = URL(url).openConnection() as HttpURLConnection
        connection = request
        request.instanceFollowRedirects = false
        request.useCaches = false
        request.connectTimeout = 10_000
        request.readTimeout = 10_000
        request.setRequestProperty("Accept-Encoding", "identity")
        if (position > 0) request.setRequestProperty("Range", "bytes=$position-")
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
        connectionEpoch = observed
        if (epoch.get() != observed) { closeHttp(); throw java.io.InterruptedIOException() }
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
