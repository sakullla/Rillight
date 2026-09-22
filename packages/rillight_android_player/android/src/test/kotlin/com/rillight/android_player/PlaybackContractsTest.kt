package com.rillight.android_player

import org.junit.Assert.*
import org.junit.Test

class PlaybackContractsTest {
    @Test fun credentialScopeIncludesSchemeHostAndPort() {
        val credentials = mapOf("X-Emby-Token" to "secret", "Authorization" to "Emby secret")
        val public = mapOf("User-Agent" to "test", "Cookie" to "private", "X-Emby-Token" to "secret")
        assertEquals("secret", RequestPolicy.headers("https://media.test/segment.ts", "https://media.test", credentials, public)["X-Emby-Token"])
        for (url in listOf("http://media.test/", "https://other.test/", "https://media.test:444/")) {
            assertEquals(mapOf("User-Agent" to "test"), RequestPolicy.headers(url, "https://media.test", credentials, public))
        }
    }
    @Test fun redirectAndHlsTargetsStripTokensAndPreservePublicQuery() {
        assertEquals("https://cdn.test/a?quality=1", RequestPolicy.sanitize("https://cdn.test/a?api_key=secret&quality=1&custom=prefix-secret", "https://emby.test", listOf("secret")))
        assertEquals("https://emby.test/a?api_key=secret", RequestPolicy.sanitize("https://emby.test/a?api_key=secret", "https://emby.test", listOf("secret")))
        assertEquals("https://cdn.test/a%2Fb?signature=x%2Fy", RequestPolicy.sanitize("https://cdn.test/a%2Fb?signature=x%2Fy", "https://emby.test", listOf("secret")))
    }
    @Test fun tracksUseTypeAndLanguageNotServerIndex() {
        val source = listOf(StreamDescriptor(8,"Video",null,false), StreamDescriptor(11,"Audio","eng",false), StreamDescriptor(19,"Audio","zho",false), StreamDescriptor(27,"Subtitle","eng",false))
        val native = listOf(NativeDescriptor("0:0","Video",null), NativeDescriptor("1:0","Audio","zho"), NativeDescriptor("2:0","Audio","eng"), NativeDescriptor("3:0","Subtitle","eng"))
        assertEquals(mapOf(11 to "2:0", 19 to "1:0", 27 to "3:0"), mapTracks(source, native))
        assertFalse(mapTracks(source, native.filterNot { it.id == "2:0" }).containsKey(19))
    }
    @Test fun externalStreamsNeverShiftEmbeddedTrackOrdinals() {
        val source = listOf(StreamDescriptor(3,"Subtitle",null,true), StreamDescriptor(8,"Subtitle",null,false))
        assertEquals(mapOf(8 to "1:0"), mapTracks(source,listOf(NativeDescriptor("1:0","Subtitle",null))))
    }
}
