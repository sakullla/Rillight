package com.rillight.player

import android.media.AudioFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CoreAudioEncodingTest {
    @Test fun ordinaryEac3IsNeverOpenedAsPcm() {
        assertEquals(AudioFormat.ENCODING_E_AC3, coreAudioEncoding(true, 3, 34))
        assertEquals(AudioFormat.ENCODING_E_AC3_JOC, coreAudioEncoding(true, 1, 34))
        assertEquals(AudioFormat.ENCODING_DOLBY_TRUEHD, coreAudioEncoding(true, 2, 34))
        assertEquals(AudioFormat.ENCODING_AC3, coreAudioEncoding(true, 4, 34))
        assertEquals(AudioFormat.ENCODING_DTS, coreAudioEncoding(true, 5, 34))
        assertEquals(AudioFormat.ENCODING_DTS_HD, coreAudioEncoding(true, 6, 34))
    }

    @Test fun unsupportedCompressedKindsRejectBeforeDeviceCreation() {
        for (codec in listOf(0, 99)) assertNull(coreAudioEncoding(true, codec, 34))
        assertNull(coreAudioEncoding(true, 3, 28))
        assertEquals(AudioFormat.ENCODING_PCM_16BIT, coreAudioEncoding(false, 0, 24))
    }

    @Test fun rejectedOutputClearsOnlyItsNativeFormatCapability() {
        assertEquals(listOf(1, 2, 1, 4, 8, 16), (1..6).map(::coreAudioAcceptBit))
        assertEquals(0, coreAudioAcceptBit(99))
    }

    @Test fun untimedOrUnknownCompressedPacketsRequestPcmFallback() {
        val output = CoreAudioOutput()
        for (codec in listOf(3, 99)) {
            val frame = CoreAudioFrame(1, 1, 0, byteArrayOf(1),
                passthrough = true, codec = codec, sampleCount = 0)
            assertEquals(AUDIO_WRITE_REJECT, output.write(frame, 0, 1.0))
        }
    }
}
