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
    @Test fun fragmentedInterleavedTracksKeepTheirLoopbackResponses() {
        val requests = java.util.concurrent.atomic.AtomicInteger()
        val release = CountDownLatch(1)
        val server = LocalHttpServer { headers, output ->
            requests.incrementAndGet()
            val start = headers.getValue("range").removePrefix("bytes=").substringBefore('-').toInt()
            replyHeader(output, 206, 256 * 1024, "bytes $start-${start + 256 * 1024 - 1}/${4 * 1024 * 1024}")
            repeat(8) {
                output.write(ByteArray(1024) { 7 })
                output.flush()
                Thread.sleep(20)
            }
            release.await(5, TimeUnit.SECONDS)
        }
        val input = CoreInput("http://127.0.0.1:${server.port}/media", null)
        try {
            val positions = longArrayOf(1024 * 1024, 2 * 1024 * 1024)
            val bytes = ByteArray(1024)
            repeat(8) {
                for (track in positions.indices) {
                    input.seek(positions[track], 0)
                    val count = input.read(bytes, bytes.size)
                    org.junit.Assert.assertTrue(count > 0)
                    org.junit.Assert.assertArrayEquals(ByteArray(count) { 7 }, bytes.copyOf(count))
                    positions[track] += count
                }
            }
            assertEquals(2, requests.get())
            input.interrupt()
            assertEquals(positions[0], input.seek(positions[0], 0))
            org.junit.Assert.assertTrue(input.read(bytes, bytes.size) > 0)
            assertEquals(3, requests.get())
        } finally {
            release.countDown()
            input.close()
            server.close()
        }
    }

    @Test fun fragmentedProbeReturnsPrefixBeforeTheRequestedSizeArrives() {
        val release = CountDownLatch(1)
        val server = LocalHttpServer { _, output ->
            replyHeader(output, 200, 512 * 1024)
            output.write(ByteArray(1024) { 7 })
            output.flush()
            release.await(5, TimeUnit.SECONDS)
        }
        val input = CoreInput("http://127.0.0.1:${server.port}/media", null)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val bytes = ByteArray(32768)
            val read = executor.submit<Int> { input.read(bytes, bytes.size) }
            val count = read.get(1, TimeUnit.SECONDS)
            org.junit.Assert.assertTrue(count in 1..1024)
            org.junit.Assert.assertArrayEquals(ByteArray(count) { 7 }, bytes.copyOf(count))
        } finally {
            release.countDown()
            input.close()
            executor.shutdownNow()
            server.close()
        }
    }

    @Test fun laterReadsReturnRequestedBytesWithoutWaitingForSpeculativeWindow() {
        val release = CountDownLatch(1)
        val server = LocalHttpServer { _, output ->
            replyHeader(output, 200, 512 * 1024)
            output.write(ByteArray(2048) { 7 })
            output.flush()
            release.await(5, TimeUnit.SECONDS)
        }
        val input = CoreInput("http://127.0.0.1:${server.port}/media", null)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val bytes = ByteArray(1024)
            assertEquals(1024, input.read(bytes, bytes.size))
            val next = executor.submit<Int> { input.read(bytes, bytes.size) }
            assertEquals(1024, next.get(1, TimeUnit.SECONDS))
            org.junit.Assert.assertArrayEquals(ByteArray(1024) { 7 }, bytes)
        } finally {
            release.countDown()
            input.close()
            executor.shutdownNow()
            server.close()
        }
    }

    @Test fun startupReturnsAvailableProbeWithoutFillingAReadAheadWindow() {
        val release = CountDownLatch(1)
        val server = LocalHttpServer { _, output ->
            replyHeader(output, 200, 256 * 1024)
            output.write(ByteArray(1024) { 7 })
            output.flush()
            release.await(5, TimeUnit.SECONDS)
        }
        val input = CoreInput("http://127.0.0.1:${server.port}/media", null)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val bytes = ByteArray(1024)
            val read = executor.submit<Int> { input.read(bytes, bytes.size) }
            assertEquals(1024, read.get(2, TimeUnit.SECONDS))
            org.junit.Assert.assertArrayEquals(ByteArray(1024) { 7 }, bytes)
        } finally {
            release.countDown()
            input.close()
            executor.shutdownNow()
            server.close()
        }
    }

    @Test fun slowProxyRecoveryCanOutliveOneUpstreamHeaderAttempt() {
        val server = LocalHttpServer { _, output ->
            // A stalled body followed by legitimately slow recovery headers
            // can outlive the old 45-second loopback deadline.
            Thread.sleep(46_000)
            reply(output, 200, byteArrayOf(42))
        }
        val input = CoreInput("http://127.0.0.1:${server.port}/slow", null)
        try {
            val bytes = ByteArray(1)
            assertEquals(1, input.read(bytes, 1))
            assertEquals(42.toByte(), bytes[0])
        } finally { input.close(); server.close() }
    }

    @Test fun sequentialReadsGrowWindowsButDistantSeeksStaySmall() {
        val data = ByteArray(8 * 1024 * 1024) { (it % 251).toByte() }
        val ranges = java.util.Collections.synchronizedList(mutableListOf<Pair<Int, Int>>())
        val server = LocalHttpServer { headers, output ->
            val range = headers.getValue("range").removePrefix("bytes=").split('-')
            val start = range[0].toInt()
            val end = minOf(range[1].toIntOrNull() ?: data.lastIndex, data.lastIndex)
            ranges.add(Pair(start, end - start + 1))
            reply(output, 206, data.copyOfRange(start, end + 1), "bytes $start-$end/${data.size}")
        }
        val input = CoreInput("http://127.0.0.1:${server.port}/media", null)
        try {
            val bytes = ByteArray(32768)
            var offset = 0
            while (offset < 4 * 1024 * 1024) {
                val count = input.read(bytes, bytes.size)
                org.junit.Assert.assertTrue(count > 0)
                org.junit.Assert.assertArrayEquals(data.copyOfRange(offset, offset + count), bytes.copyOf(count))
                offset += count
            }
            org.junit.Assert.assertTrue("Sequential reads must not reopen every 256 KiB", ranges.size <= 6)
            assertEquals(Pair(0, data.size), ranges.first())
            org.junit.Assert.assertTrue(ranges.drop(1).all { it.second <= 1024 * 1024 })
            val distant = 7 * 1024 * 1024
            assertEquals(distant.toLong(), input.seek(distant.toLong(), 0))
            assertEquals(bytes.size, input.read(bytes, bytes.size))
            org.junit.Assert.assertArrayEquals(data.copyOfRange(distant, distant + bytes.size), bytes)
            assertEquals(Pair(distant, 256 * 1024), ranges.last())
        } finally { input.close(); server.close() }
    }

    @Test fun interleavedTracksReuseBoundedWindows() {
        val data = ByteArray(2 * 1024 * 1024) { (it % 251).toByte() }
        val requests = java.util.concurrent.atomic.AtomicInteger()
        val largest = java.util.concurrent.atomic.AtomicInteger()
        val server = LocalHttpServer { headers, output ->
            requests.incrementAndGet()
            val range = headers["range"]?.removePrefix("bytes=")?.split('-') ?: listOf("0", "")
            val start = range[0].toInt()
            val end = minOf(range[1].toIntOrNull() ?: data.lastIndex, data.lastIndex)
            if (range[1].isNotEmpty()) largest.updateAndGet { maxOf(it, end - start + 1) }
            reply(output, 206, data.copyOfRange(start, end + 1), "bytes $start-$end/${data.size}")
        }
        val input = CoreInput("http://127.0.0.1:${server.port}/media", null)
        try {
            val bytes = ByteArray(1024)
            repeat(100) { packet ->
                for (track in listOf(0, 1024 * 1024)) {
                    val position = track + packet * bytes.size
                    assertEquals(position.toLong(), input.seek(position.toLong(), 0))
                    assertEquals(bytes.size, input.read(bytes, bytes.size))
                    org.junit.Assert.assertArrayEquals(data.copyOfRange(position, position + bytes.size), bytes)
                }
            }
            // The immediate first probe precedes one retained window per track.
            assertEquals(3, requests.get())
            assertEquals(256 * 1024, largest.get())
        } finally { input.close(); server.close() }
    }

    @Test fun shortPartialResponsesContinueUntilRepresentationEof() {
        val data = ByteArray(4099) { (it % 251).toByte() }
        val server = LocalHttpServer { headers, output ->
            val start = headers.getValue("range").removePrefix("bytes=").substringBefore('-').toInt()
            val end = minOf(start + 1023, data.lastIndex)
            reply(output, 206, data.copyOfRange(start, end + 1), "bytes $start-$end/${data.size}")
        }
        val input = CoreInput("http://127.0.0.1:${server.port}/media", null)
        try {
            val all = java.io.ByteArrayOutputStream()
            val bytes = ByteArray(333)
            while (true) {
                val count = input.read(bytes, bytes.size)
                if (count == 0) break
                org.junit.Assert.assertTrue(count > 0)
                all.write(bytes, 0, count)
            }
            org.junit.Assert.assertArrayEquals(data, all.toByteArray())
            assertEquals(0, input.read(bytes, bytes.size))
        } finally { input.close(); server.close() }
    }

    @Test fun sequentialUnknownLengthResponseKeepsOneConnectionAndEnds() {
        val data = ByteArray(400 * 1024) { (it % 251).toByte() }
        val requests = java.util.concurrent.atomic.AtomicInteger()
        val server = LocalHttpServer { _, output ->
            requests.incrementAndGet()
            output.write("HTTP/1.0 200 OK\r\nConnection: close\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
            output.write(data)
            output.flush()
        }
        val input = CoreInput("http://127.0.0.1:${server.port}/media", null)
        try {
            val all = java.io.ByteArrayOutputStream()
            val bytes = ByteArray(65536)
            while (true) {
                val count = input.read(bytes, bytes.size)
                if (count == 0) break
                org.junit.Assert.assertTrue(count > 0)
                all.write(bytes, 0, count)
            }
            org.junit.Assert.assertArrayEquals(data, all.toByteArray())
            assertEquals(1, requests.get())
        } finally { input.close(); server.close() }
    }

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
