package com.rillight.android_player

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSpec
import java.io.InputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL

/** Redirects are handled here, never by the platform HTTP stack. */
internal object RequestPolicy {
    fun sameOrigin(a: String, b: String): Boolean {
        val x = URI(a); val y = URI(b)
        fun port(u: URI) = if (u.port >= 0) u.port else if (u.scheme == "https") 443 else 80
        return x.scheme.equals(y.scheme, true) && x.host.equals(y.host, true) && port(x) == port(y)
    }
    fun headers(url: String, origin: String?, credentials: Map<String, String>, public: Map<String, String>): Map<String, String> {
        val safe = public.filterKeys { it.lowercase() in setOf("user-agent", "accept", "accept-language") }
        return if (origin != null && sameOrigin(url, origin)) safe + credentials else safe
    }
    fun sanitize(url: String, origin: String?, secrets: Collection<String>): String {
        val uri = URI(url)
        require(uri.scheme in listOf("http", "https") && uri.userInfo == null) { "Unsupported media URL" }
        if (origin != null && sameOrigin(url, origin)) return url
        val query = uri.rawQuery?.split("&")?.filterNot {
            val key = it.substringBefore('=').lowercase()
            val value = java.net.URLDecoder.decode(it.substringAfter('=', ""), "UTF-8")
            key in setOf("api_key", "apikey", "x-emby-token", "access_token") || secrets.any { s -> s.isNotEmpty() && value.contains(s) }
        }?.joinToString("&")?.takeIf { it.isNotEmpty() }
        return "${uri.scheme}://${uri.rawAuthority}${uri.rawPath}" + (query?.let { "?$it" } ?: "")
    }
}

internal class SafeDataSource(
    private val origin: String?, private val credentials: Map<String, String>,
    private val publicHeaders: Map<String, String>,
) : BaseDataSource(true) {
    private var connection: HttpURLConnection? = null
    private var input: InputStream? = null
    private var current: Uri? = null
    private var remaining = C.LENGTH_UNSET.toLong()
    private var opened = false
    override fun open(spec: DataSpec): Long {
        transferInitializing(spec)
        var url = RequestPolicy.sanitize(spec.uri.toString(), origin, credentials.values)
        repeat(6) {
            val conn = URL(url).openConnection() as HttpURLConnection
            connection = conn
            conn.instanceFollowRedirects = false
            conn.useCaches = false
            conn.connectTimeout = 10000; conn.readTimeout = 10000
            conn.setRequestProperty("Accept-Encoding", "identity")
            RequestPolicy.headers(url, origin, credentials, publicHeaders).forEach { (k, v) -> conn.setRequestProperty(k, v) }
            if (spec.position != 0L || spec.length != C.LENGTH_UNSET.toLong()) {
                val end = if (spec.length == C.LENGTH_UNSET.toLong()) "" else (spec.position + spec.length - 1).toString()
                conn.setRequestProperty("Range", "bytes=${spec.position}-$end")
            }
            val status = conn.responseCode
            if (status in listOf(301,302,303,307,308)) {
                val location = conn.getHeaderField("Location") ?: throw IOException("Media redirect has no destination")
                val next = URL(URL(url), location).toString()
                conn.disconnect()
                if (url.startsWith("https:") && next.startsWith("http:")) throw IOException("Insecure media redirect")
                url = RequestPolicy.sanitize(next, origin, credentials.values)
            } else {
                if (status !in 200..299) throw MediaHttpException(status)
                input = conn.inputStream
                if (status == 200 && spec.position > 0) {
                    var skip = spec.position
                    val discard = ByteArray(4096)
                    while (skip > 0) {
                        if (Thread.currentThread().isInterrupted) throw java.io.InterruptedIOException()
                        val n = input!!.read(discard, 0, minOf(skip, discard.size.toLong()).toInt())
                        if (n <= 0) throw IOException("Media range unavailable")
                        skip -= n
                    }
                }
                current = Uri.parse(url)
                val contentLength = conn.getHeaderField("Content-Length")?.toLongOrNull()
                remaining = if (spec.length != C.LENGTH_UNSET.toLong()) spec.length
                    else contentLength?.let { (it - if (status == 200) spec.position else 0).coerceAtLeast(0) } ?: C.LENGTH_UNSET.toLong()
                opened = true; transferStarted(spec)
                return remaining
            }
        }
        throw IOException("Too many media redirects")
    }
    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (remaining == 0L) return C.RESULT_END_OF_INPUT
        val read = input!!.read(buffer, offset, if (remaining < 0) length else minOf(length.toLong(), remaining).toInt())
        if (read < 0) {
            if (remaining > 0) throw java.io.EOFException("Truncated media response")
            return C.RESULT_END_OF_INPUT
        }
        if (remaining > 0) remaining -= read
        bytesTransferred(read); return read
    }
    override fun getUri() = current
    override fun close() {
        try { input?.close() } finally {
            input = null; connection?.disconnect(); connection = null; current = null
            if (opened) { opened = false; transferEnded() }
        }
    }
}

internal class MediaHttpException(val status: Int) : IOException("Media HTTP $status")
