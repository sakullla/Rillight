package com.rillight.player

import com.sun.net.httpserver.HttpServer
import java.io.File
import java.net.InetSocketAddress
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
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/media") { exchange ->
            val requested = exchange.requestHeaders.getFirst("Range")
            val start = requested?.removePrefix("bytes=")?.substringBefore('-')?.toIntOrNull() ?: 0
            val bytes = data.copyOfRange(start, data.size)
            if (requested != null) exchange.responseHeaders.add("Content-Range", "bytes $start-5/6")
            exchange.sendResponseHeaders(if (requested == null) 200 else 206, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()
        try {
            val input = CoreInput("http://127.0.0.1:${server.address.port}/media", null)
            assertEquals(6L, input.seek(0, 0x10000))
            assertEquals(3L, input.seek(3, 0))
            val bytes = ByteArray(3)
            assertEquals(3, input.read(bytes, 3))
            assertEquals("def", String(bytes))
            input.close()
        } finally { server.stop(0) }
    }

    @Test fun targetedCancelUnblocksReadAndNextSeekCanRecover() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        var request = 0
        server.createContext("/slow") { exchange ->
            request++
            exchange.sendResponseHeaders(200, 1)
            if (request == 1) {
                entered.countDown()
                release.await(5, TimeUnit.SECONDS)
            }
            try { exchange.responseBody.use { it.write(byteArrayOf(42)) } }
            catch (_: java.io.IOException) { exchange.close() }
        }
        server.start()
        val executor = Executors.newSingleThreadExecutor()
        try {
            val input = CoreInput("http://127.0.0.1:${server.address.port}/slow", null)
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
            server.stop(0)
        }
    }
}
