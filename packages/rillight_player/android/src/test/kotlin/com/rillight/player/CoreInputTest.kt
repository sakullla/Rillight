package com.rillight.player

import java.io.File
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Test

class CoreInputTest {
    @Test fun appPrivateFileSupportsSizeAndSeekAfterCancel() {
        val file = File.createTempFile("rillight-core-io", ".bin")
        try {
            file.writeBytes("abcdef".toByteArray())
            val input = CoreInput(null, file)
            assertEquals(6L, input.seek(0, 0x10000))
            assertEquals(3L, input.seek(3, 0))
            input.interrupt()
            val bytes = ByteArray(3)
            assertEquals(3, input.read(bytes, 3))
            assertEquals("def", String(bytes))
            input.close()
        } finally { file.delete() }
    }

    @Test fun remoteSeekRequiresMatchingByteRange() {
        val data = "abcdef".toByteArray()
        val server = LocalHttpServer { headers, output ->
            val requested = headers["range"]
            val start = requested?.removePrefix("bytes=")?.substringBefore('-')?.toIntOrNull() ?: 0
            val bytes = data.copyOfRange(start, data.size)
            reply(output, if (requested == null) 200 else 206, bytes,
                  if (requested == null) null else "bytes $start-5/6")
        }
        try {
            val input = CoreInput("http://127.0.0.1:${server.port}/media", null)
            assertEquals(6L, input.seek(0, 0x10000))
            assertEquals(3L, input.seek(3, 0))
            val bytes = ByteArray(3)
            assertEquals(3, input.read(bytes, 3))
            assertEquals("def", String(bytes))
            input.close()
        } finally { server.close() }
    }

    @Test fun targetedCancelUnblocksReadAndNextSeekCanRecover() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val requests = java.util.concurrent.atomic.AtomicInteger()
        val server = LocalHttpServer { _, output ->
            val request = requests.incrementAndGet()
            replyHeader(output, 200, 1)
            if (request == 1) {
                entered.countDown()
                release.await(5, TimeUnit.SECONDS)
            }
            try { output.write(byteArrayOf(42)); output.flush() }
            catch (_: java.io.IOException) { /* The first client cancelled. */ }
        }
        val executor = Executors.newSingleThreadExecutor()
        try {
            val input = CoreInput("http://127.0.0.1:${server.port}/slow", null)
            val read = executor.submit<Int> { input.read(ByteArray(1), 1) }
            org.junit.Assert.assertTrue(entered.await(2, TimeUnit.SECONDS))
            input.interrupt()
            assertEquals(-4, read.get(2, TimeUnit.SECONDS))
            release.countDown()
            assertEquals(0L, input.seek(0, 0))
            assertEquals(1, input.read(ByteArray(1), 1))
            input.close()
        } finally {
            release.countDown()
            executor.shutdownNow()
            server.close()
        }
    }
}

private fun replyHeader(output: OutputStream, status: Int, length: Int,
                        contentRange: String? = null) {
    val text = buildString {
        append("HTTP/1.1 $status ${if (status == 200) "OK" else "Partial Content"}\r\n")
        append("Content-Length: $length\r\n")
        if (contentRange != null) append("Content-Range: $contentRange\r\n")
        append("Connection: close\r\n\r\n")
    }
    output.write(text.toByteArray(StandardCharsets.US_ASCII))
    output.flush()
}

private fun reply(output: OutputStream, status: Int, bytes: ByteArray,
                  contentRange: String? = null) {
    replyHeader(output, status, bytes.size, contentRange)
    output.write(bytes)
    output.flush()
}

private class LocalHttpServer(private val response: (Map<String, String>, OutputStream) -> Unit) {
    private val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
    private val workers = Executors.newCachedThreadPool()
    val port: Int get() = server.localPort

    init {
        workers.execute {
            while (!server.isClosed) {
                val socket = try { server.accept() } catch (_: java.io.IOException) { break }
                workers.execute { handle(socket) }
            }
        }
    }

    private fun handle(socket: Socket) {
        socket.use {
            try {
                val reader = it.getInputStream().bufferedReader(StandardCharsets.US_ASCII)
                val headers = mutableMapOf<String, String>()
                while (true) {
                    val line = reader.readLine() ?: break
                    if (line.isEmpty()) break
                    val separator = line.indexOf(':')
                    if (separator > 0)
                        headers[line.substring(0, separator).lowercase()] = line.substring(separator + 1).trim()
                }
                response(headers, it.getOutputStream())
            } catch (_: java.io.IOException) { /* The client may cancel the request. */ }
        }
    }

    fun close() {
        server.close()
        workers.shutdownNow()
    }
}
