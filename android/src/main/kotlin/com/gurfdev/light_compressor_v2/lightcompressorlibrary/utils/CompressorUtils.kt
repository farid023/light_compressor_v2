package com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Build
import android.util.Log
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.VideoQuality
import kotlin.math.roundToInt

object CompressorUtils {

    private const val MIN_HEIGHT = 640.0
    private const val MIN_WIDTH = 368.0

    // 1 second between I-frames
    private const val I_FRAME_INTERVAL = 1

    fun prepareVideoWidth(
        mediaMetadataRetriever: MediaMetadataRetriever,
    ): Double {
        val widthData =
            mediaMetadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
        return if (widthData.isNullOrEmpty()) {
            MIN_WIDTH
        } else {
            widthData.toDouble()
        }
    }

    fun prepareVideoHeight(
        mediaMetadataRetriever: MediaMetadataRetriever,
    ): Double {
        val heightData =
            mediaMetadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
        return if (heightData.isNullOrEmpty()) {
            MIN_HEIGHT
        } else {
            heightData.toDouble()
        }
    }

    /**
     * Set output parameters like bitrate and frame rate
     */
    fun setOutputFileParameters(
        inputFormat: MediaFormat,
        outputFormat: MediaFormat,
        newBitrate: Int,
    ) {
        val newFrameRate = getFrameRate(inputFormat)
        val iFrameInterval = getIFrameIntervalRate(inputFormat)
        outputFormat.apply {

            // according to https://developer.android.com/media/optimize/sharing#b-frames_and_encoding_profiles
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val type = outputFormat.getString(MediaFormat.KEY_MIME)
                // IMPORTANT: a profile must be paired with a compatible level, otherwise
                // many hardware encoders (notably Qualcomm) reject configure() with
                // error -38 and we silently fall back to Baseline. Pick a profile+level
                // pair that the encoder actually advertises.
                val profileLevel = getSupportedProfileLevel(type)
                if (profileLevel != null) {
                    Log.i(
                        "Output file parameters",
                        "Selected profile=${profileLevel.profile} level=${profileLevel.level}"
                    )
                    setInteger(MediaFormat.KEY_PROFILE, profileLevel.profile)
                    setInteger(MediaFormat.KEY_LEVEL, profileLevel.level)
                }
                // If no supported pair is found we deliberately leave profile/level unset
                // and let the encoder choose its own defaults.
            } else if (outputFormat.getString(MediaFormat.KEY_MIME) != "video/hevc") {
                setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
            }

            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
            )

            setInteger(MediaFormat.KEY_FRAME_RATE, newFrameRate)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, iFrameInterval)
            // expected bps
            setInteger(MediaFormat.KEY_BIT_RATE, newBitrate)
            setInteger(
                MediaFormat.KEY_BITRATE_MODE,
                MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
            )



            if (isHdr(inputFormat)) {
                // The output is 8-bit SDR (the decoder is asked to tone-map, see
                // Compressor.prepareDecoder), so tag it as such. Copying the
                // source's HLG/PQ tags would mark an 8-bit file as HDR.
                setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
                setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
                setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
            } else {
                getColorStandard(inputFormat)?.let {
                    setInteger(MediaFormat.KEY_COLOR_STANDARD, it)
                }

                getColorTransfer(inputFormat)?.let {
                    setInteger(MediaFormat.KEY_COLOR_TRANSFER, it)
                }

                getColorRange(inputFormat)?.let {
                    setInteger(MediaFormat.KEY_COLOR_RANGE, it)
                }
            }


            Log.i(
                "Output file parameters",
                "videoFormat: $this"
            )
        }
    }

    private fun getFrameRate(format: MediaFormat): Int {
        return if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) format.getInteger(MediaFormat.KEY_FRAME_RATE)
        else 30
    }

    private fun getIFrameIntervalRate(format: MediaFormat): Int {
        return if (format.containsKey(MediaFormat.KEY_I_FRAME_INTERVAL)) format.getInteger(
            MediaFormat.KEY_I_FRAME_INTERVAL
        )
        else I_FRAME_INTERVAL
    }

    /**
     * Whether [format] describes HDR video: an HLG or PQ (ST 2084) transfer, or
     * a Dolby Vision track. iPhone HDR recordings are Dolby Vision 8.4 over HLG.
     */
    fun isHdr(format: MediaFormat): Boolean {
        if (format.getString(MediaFormat.KEY_MIME) == MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION) {
            return true
        }
        val transfer = getColorTransfer(format) ?: return false
        return transfer == MediaFormat.COLOR_TRANSFER_HLG ||
            transfer == MediaFormat.COLOR_TRANSFER_ST2084
    }

    /**
     * Makes a Dolby Vision [format] decodable on a device without a Dolby Vision
     * decoder, which is most of them. The extractor reports such a track as
     * `video/dolby-vision`, so creating a decoder for it fails outright. Its
     * backward-compatible profiles carry a plain base layer — HEVC for 4, 7 and
     * 8 (iPhone recordings are 8.4), AVC for 9 — so the format is rewritten in
     * place to decode as that codec; HEVC/AVC decoders skip the Dolby Vision
     * metadata. Other profiles (e.g. 5) have no compatible base layer and are
     * left as they are.
     */
    fun remapDolbyVisionForDecoding(format: MediaFormat) {
        if (format.getString(MediaFormat.KEY_MIME) != MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION) return
        if (MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(format) != null) return
        val profile =
            if (format.containsKey(MediaFormat.KEY_PROFILE)) format.getInteger(MediaFormat.KEY_PROFILE) else -1
        val (mime, baseProfile) = when (profile) {
            MediaCodecInfo.CodecProfileLevel.DolbyVisionProfileDvavSe ->
                MediaFormat.MIMETYPE_VIDEO_AVC to MediaCodecInfo.CodecProfileLevel.AVCProfileHigh
            MediaCodecInfo.CodecProfileLevel.DolbyVisionProfileDvheDtr,
            MediaCodecInfo.CodecProfileLevel.DolbyVisionProfileDvheDtb,
            MediaCodecInfo.CodecProfileLevel.DolbyVisionProfileDvheSt,
            -1 ->
                MediaFormat.MIMETYPE_VIDEO_HEVC to MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10
            else -> return
        }
        format.setString(MediaFormat.KEY_MIME, mime)
        format.setInteger(MediaFormat.KEY_PROFILE, baseProfile)
        // The level is a Dolby Vision level, meaningless to the base codec.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) format.removeKey(MediaFormat.KEY_LEVEL)
    }

    private fun getColorStandard(format: MediaFormat): Int? {
        return if (format.containsKey(MediaFormat.KEY_COLOR_STANDARD)) format.getInteger(
            MediaFormat.KEY_COLOR_STANDARD
        )
        else null
    }

    private fun getColorTransfer(format: MediaFormat): Int? {
        return if (format.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) format.getInteger(
            MediaFormat.KEY_COLOR_TRANSFER
        )
        else null
    }

    private fun getColorRange(format: MediaFormat): Int? {
        return if (format.containsKey(MediaFormat.KEY_COLOR_RANGE)) format.getInteger(
            MediaFormat.KEY_COLOR_RANGE
        )
        else null
    }

    /**
     * Counts the number of tracks (video, audio) found in the file source provided
     * @param extractor what is used to extract the encoded data
     * @param isVideo to determine whether we are processing video or audio at time of call
     * @return index of the requested track
     */
    fun findTrack(
        extractor: MediaExtractor,
        isVideo: Boolean,
    ): Int {
        val numTracks = extractor.trackCount
        for (i in 0 until numTracks) {
            val format = extractor.getTrackFormat(i)
            val mime = format.getString(MediaFormat.KEY_MIME)
            if (isVideo) {
                if (mime?.startsWith("video/")!!) return i
            } else {
                if (mime?.startsWith("audio/")!!) return i
            }
        }
        return -5
    }

    fun printException(exception: Exception) {
        var message = "An error has occurred!"
        exception.localizedMessage?.let {
            message = it
        }
        Log.e("Compressor", message, exception)
    }

    /**
     * Get fixed bitrate value based on the file's current bitrate
     * @param bitrate file's current bitrate
     * @return new smaller bitrate value
     */
    fun getBitrate(
        bitrate: Int,
        quality: VideoQuality,
    ): Int {
        return when (quality) {
            VideoQuality.VERY_LOW -> (bitrate * 0.1).roundToInt()
            VideoQuality.LOW -> (bitrate * 0.2).roundToInt()
            VideoQuality.MEDIUM -> (bitrate * 0.3).roundToInt()
            VideoQuality.HIGH -> (bitrate * 0.4).roundToInt()
            VideoQuality.VERY_HIGH -> (bitrate * 0.6).roundToInt()
        }
    }

    /**
     * Generate new width and height for source file
     * @param width file's original width
     * @param height file's original height
     * @return the scale factor to apply to the video's resolution
     */
    fun autoResizePercentage(width: Double, height: Double): Double {
        return when {
            width >= 1920 || height >= 1920 -> 0.5
            width >= 1280 || height >= 1280 -> 0.75
            width >= 960 || height >= 960 -> 0.95
            else -> 0.9
        }
    }

    /**
     * True when the device advertises a **hardware** HEVC (H.265) encoder.
     *
     * AOSP software HEVC encoders (`c2.android.*` / `OMX.google.*`) are excluded
     * because they are far too slow to be practical for video compression; when
     * only those are present the caller falls back to H.264. Vendor Codec2
     * encoders (e.g. `c2.qti.*`, `c2.exynos.*`, `c2.mtk.*`) are hardware and pass
     * this check.
     */
    fun isHevcHardwareEncoderAvailable(): Boolean =
        runCatching {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { codec ->
                codec.isEncoder &&
                    "video/hevc" in codec.supportedTypes &&
                    !codec.name.contains("google", ignoreCase = true) &&
                    !codec.name.contains("c2.android", ignoreCase = true)
            }
        }.getOrDefault(false)

    /**
     * Finds a profile+level pair that an available encoder for [type] actually
     * supports. Preference order is High > Main > Baseline, and within a profile
     * the highest advertised level is chosen.
     *
     * Returns `null` when no encoder/capabilities are found, in which case the
     * caller should leave the profile/level unset (the encoder picks defaults).
     *
     * Pairing a profile with a compatible level is required: setting
     * [MediaFormat.KEY_PROFILE] without [MediaFormat.KEY_LEVEL] makes many
     * hardware encoders fail `configure()` with error -38.
     */
    private fun getSupportedProfileLevel(type: String?): MediaCodecInfo.CodecProfileLevel? {
        if (type == null) return null

        val capabilities = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .filter { codec -> codec.isEncoder && type in codec.supportedTypes }
            .mapNotNull { codec -> runCatching { codec.getCapabilitiesForType(type) }.getOrNull() }

        val preferenceOrder = if (type == "video/hevc") {
            // HEVC Main covers 8-bit 4:2:0 video, which is what this surface
            // pipeline produces.
            listOf(MediaCodecInfo.CodecProfileLevel.HEVCProfileMain)
        } else {
            listOf(
                MediaCodecInfo.CodecProfileLevel.AVCProfileHigh,
                MediaCodecInfo.CodecProfileLevel.AVCProfileMain,
                MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline,
            )
        }

        for (profile in preferenceOrder) {
            var best: MediaCodecInfo.CodecProfileLevel? = null
            capabilities.forEach { capabilitiesForType ->
                capabilitiesForType.profileLevels.forEach { profileLevel ->
                    if (profileLevel.profile == profile &&
                        (best == null || profileLevel.level > best!!.level)
                    ) {
                        best = profileLevel
                    }
                }
            }
            if (best != null) return best
        }

        return null
    }
}
