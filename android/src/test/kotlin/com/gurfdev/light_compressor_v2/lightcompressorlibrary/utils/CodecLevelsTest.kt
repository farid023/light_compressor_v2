package com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils

import android.media.MediaCodecInfo.CodecProfileLevel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CodecLevelsTest {

    private val high = CodecProfileLevel.AVCProfileHigh
    private val baseline = CodecProfileLevel.AVCProfileBaseline

    @Test
    fun avcPicksTheLowestLevelThatFits() {
        assertEquals(CodecProfileLevel.AVCLevel4, minimumAvcLevel(1920, 1080, 30, 3_000_000, high))
        assertEquals(CodecProfileLevel.AVCLevel31, minimumAvcLevel(1280, 720, 30, 2_000_000, high))
        assertEquals(CodecProfileLevel.AVCLevel42, minimumAvcLevel(1920, 1080, 60, 8_000_000, high))
        assertEquals(CodecProfileLevel.AVCLevel51, minimumAvcLevel(3840, 2160, 30, 20_000_000, high))
        assertEquals(CodecProfileLevel.AVCLevel3, minimumAvcLevel(640, 360, 30, 1_000_000, baseline))
    }

    @Test
    fun avcBitrateCanRaiseTheLevel() {
        // Level 4 allows 20 Mbps (25 Mbps for High); 30 Mbps needs 4.1.
        assertEquals(CodecProfileLevel.AVCLevel41, minimumAvcLevel(1920, 1080, 30, 30_000_000, high))
        assertEquals(CodecProfileLevel.AVCLevel4, minimumAvcLevel(1920, 1080, 30, 24_000_000, high))
        assertEquals(CodecProfileLevel.AVCLevel41, minimumAvcLevel(1920, 1080, 30, 24_000_000, baseline))
    }

    @Test
    fun avcBeyondTheTableIsNull() {
        // 8K at 240 fps exceeds even level 6.2 (16.7M macroblocks per second).
        assertNull(minimumAvcLevel(7680, 4320, 240, 50_000_000, high))
    }

    @Test
    fun hevcPicksTheLowestLevelThatFits() {
        assertEquals(CodecProfileLevel.HEVCMainTierLevel4, minimumHevcLevel(1920, 1080, 30, 3_000_000))
        assertEquals(CodecProfileLevel.HEVCMainTierLevel31, minimumHevcLevel(1280, 720, 30, 2_000_000))
        assertEquals(CodecProfileLevel.HEVCMainTierLevel41, minimumHevcLevel(1920, 1080, 60, 8_000_000))
        assertEquals(CodecProfileLevel.HEVCMainTierLevel5, minimumHevcLevel(3840, 2160, 30, 20_000_000))
    }

    @Test
    fun hevcBitrateCanRaiseTheLevel() {
        // Level 4 (Main tier) allows 12 Mbps; 15 Mbps needs 4.1.
        assertEquals(CodecProfileLevel.HEVCMainTierLevel41, minimumHevcLevel(1920, 1080, 30, 15_000_000))
    }

    @Test
    fun hevcBeyondTheTableIsNull() {
        assertNull(minimumHevcLevel(15360, 8640, 120, 50_000_000))
    }

    @Test
    fun requestsTheFittingLevelCappedAtTheEncoders() {
        assertEquals(CodecProfileLevel.AVCLevel4, chooseLevel(CodecProfileLevel.AVCLevel4, CodecProfileLevel.AVCLevel52))
        assertEquals(CodecProfileLevel.AVCLevel41, chooseLevel(CodecProfileLevel.AVCLevel51, CodecProfileLevel.AVCLevel41))
        assertEquals(CodecProfileLevel.AVCLevel52, chooseLevel(null, CodecProfileLevel.AVCLevel52))
    }
}
