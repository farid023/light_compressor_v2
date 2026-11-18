package com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils

import android.media.MediaCodecInfo.CodecProfileLevel
import kotlin.math.sqrt

// The level an output declares tells a player what it must be able to decode.
// Requesting the highest level the device advertises made an encoder that
// honours the request declare 1080p as level 5 or 6, which some players refuse
// (iOS can play such a file but not save it). These pick the lowest level that
// fits the frame size, frame rate and bitrate instead.

/** H.264 Table A-1: max macroblocks/s, max frame size in macroblocks, max kbit/s. */
private class AvcLimit(val level: Int, val maxMbps: Long, val maxFs: Int, val maxBrKbps: Long)

private val AVC_LIMITS = listOf(
    AvcLimit(CodecProfileLevel.AVCLevel1, 1_485, 99, 64),
    AvcLimit(CodecProfileLevel.AVCLevel11, 3_000, 396, 192),
    AvcLimit(CodecProfileLevel.AVCLevel12, 6_000, 396, 384),
    AvcLimit(CodecProfileLevel.AVCLevel13, 11_880, 396, 768),
    AvcLimit(CodecProfileLevel.AVCLevel2, 11_880, 396, 2_000),
    AvcLimit(CodecProfileLevel.AVCLevel21, 19_800, 792, 4_000),
    AvcLimit(CodecProfileLevel.AVCLevel22, 20_250, 1_620, 4_000),
    AvcLimit(CodecProfileLevel.AVCLevel3, 40_500, 1_620, 10_000),
    AvcLimit(CodecProfileLevel.AVCLevel31, 108_000, 3_600, 14_000),
    AvcLimit(CodecProfileLevel.AVCLevel32, 216_000, 5_120, 20_000),
    AvcLimit(CodecProfileLevel.AVCLevel4, 245_760, 8_192, 20_000),
    AvcLimit(CodecProfileLevel.AVCLevel41, 245_760, 8_192, 50_000),
    AvcLimit(CodecProfileLevel.AVCLevel42, 522_240, 8_704, 50_000),
    AvcLimit(CodecProfileLevel.AVCLevel5, 589_824, 22_080, 135_000),
    AvcLimit(CodecProfileLevel.AVCLevel51, 983_040, 36_864, 240_000),
    AvcLimit(CodecProfileLevel.AVCLevel52, 2_073_600, 36_864, 240_000),
    AvcLimit(CodecProfileLevel.AVCLevel6, 4_177_920, 139_264, 240_000),
    AvcLimit(CodecProfileLevel.AVCLevel61, 8_355_840, 139_264, 480_000),
    AvcLimit(CodecProfileLevel.AVCLevel62, 16_711_680, 139_264, 800_000),
)

/** HEVC Table A.8, Main tier: max luma samples per picture and per second, max kbit/s. */
private class HevcLimit(val level: Int, val maxLumaPs: Long, val maxLumaSr: Long, val maxBrKbps: Long)

private val HEVC_LIMITS = listOf(
    HevcLimit(CodecProfileLevel.HEVCMainTierLevel1, 36_864, 552_960, 128),
    HevcLimit(CodecProfileLevel.HEVCMainTierLevel2, 122_880, 3_686_400, 1_500),
    HevcLimit(CodecProfileLevel.HEVCMainTierLevel21, 245_760, 7_372_800, 3_000),
    HevcLimit(CodecProfileLevel.HEVCMainTierLevel3, 552_960, 16_588_800, 6_000),
    HevcLimit(CodecProfileLevel.HEVCMainTierLevel31, 983_040, 33_177_600, 10_000),
    HevcLimit(CodecProfileLevel.HEVCMainTierLevel4, 2_228_224, 66_846_720, 12_000),
    HevcLimit(CodecProfileLevel.HEVCMainTierLevel41, 2_228_224, 133_693_440, 20_000),
    HevcLimit(CodecProfileLevel.HEVCMainTierLevel5, 8_912_896, 267_386_880, 25_000),
    HevcLimit(CodecProfileLevel.HEVCMainTierLevel51, 8_912_896, 534_773_760, 40_000),
    HevcLimit(CodecProfileLevel.HEVCMainTierLevel52, 8_912_896, 1_069_547_520, 60_000),
    HevcLimit(CodecProfileLevel.HEVCMainTierLevel6, 35_651_584, 1_069_547_520, 60_000),
    HevcLimit(CodecProfileLevel.HEVCMainTierLevel61, 35_651_584, 2_139_095_040, 120_000),
    HevcLimit(CodecProfileLevel.HEVCMainTierLevel62, 35_651_584, 4_278_190_080, 240_000),
)

/**
 * The lowest H.264 level (an `AVCLevel*` constant) for this output, or null
 * when it exceeds level 6.2. High profile allows 1.25x the bitrate.
 */
fun minimumAvcLevel(width: Int, height: Int, frameRate: Int, bitrate: Int, profile: Int): Int? {
    val widthMbs = (width + 15) / 16
    val heightMbs = (height + 15) / 16
    val frameMbs = widthMbs * heightMbs
    val mbPerSecond = frameMbs.toLong() * frameRate
    val bitrateFactor = if (profile == CodecProfileLevel.AVCProfileHigh) 1.25 else 1.0
    return AVC_LIMITS.firstOrNull { limit ->
        // A side may not exceed sqrt(8 * MaxFS) macroblocks.
        val maxSideMbs = sqrt(8.0 * limit.maxFs)
        frameMbs <= limit.maxFs && mbPerSecond <= limit.maxMbps &&
            widthMbs <= maxSideMbs && heightMbs <= maxSideMbs &&
            bitrate <= limit.maxBrKbps * 1000 * bitrateFactor
    }?.level
}

/**
 * The lowest HEVC Main-tier level (an `HEVCMainTierLevel*` constant) for this
 * output, or null when it exceeds level 6.2.
 */
fun minimumHevcLevel(width: Int, height: Int, frameRate: Int, bitrate: Int): Int? {
    val lumaPs = width.toLong() * height
    val lumaSr = lumaPs * frameRate
    return HEVC_LIMITS.firstOrNull { limit ->
        // A side may not exceed sqrt(8 * MaxLumaPs) samples.
        val maxSide = sqrt(8.0 * limit.maxLumaPs)
        lumaPs <= limit.maxLumaPs && lumaSr <= limit.maxLumaSr &&
            width <= maxSide && height <= maxSide &&
            bitrate <= limit.maxBrKbps * 1000
    }?.level
}

/**
 * The level to request: the [required] one, unless the encoder's highest level
 * for the profile ([encoderMax]) is lower or nothing fits, in which case the
 * encoder's own highest — as before.
 */
fun chooseLevel(required: Int?, encoderMax: Int): Int =
    if (required != null && required <= encoderMax) required else encoderMax
