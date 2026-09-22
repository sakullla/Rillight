package com.rillight.android_player

internal data class StreamDescriptor(val index: Int, val type: String, val language: String?, val external: Boolean)
internal data class NativeDescriptor(val id: String, val type: String, val language: String?)

/** Map within a media type, never equate Emby indices and Media3 indices.
 * Unique language matches take priority. Remaining tracks use container order
 * only when the counts agree; partial/transcoded layouts fail explicitly. */
internal fun mapTracks(streams: List<StreamDescriptor>, native: List<NativeDescriptor>): Map<Int, String> {
    val result = mutableMapOf<Int, String>()
    for (type in listOf("Audio", "Subtitle")) {
        val source = streams.filter { it.type == type && !it.external }
        val tracks = native.filter { it.type == type }
        if (source.size != tracks.size) continue
        val used = mutableSetOf<String>()
        source.forEach { s ->
            val language = s.language?.lowercase()?.takeUnless { it in listOf("", "und") }
            if (language != null && source.count { it.language?.lowercase() == language } == 1) {
                val matches = tracks.filter { it.language?.lowercase() == language }
                if (matches.size == 1) { result[s.index] = matches.single().id; used.add(matches.single().id) }
            }
        }
        val remaining = tracks.filter { it.id !in used }.iterator()
        source.filter { it.index !in result }.forEach { result[it.index] = remaining.next().id }
    }
    return result
}
