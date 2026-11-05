package com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils

import android.media.MediaCodec
import android.media.MediaCodecInfo.EncoderCapabilities
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build

/**
 * Measurement-only hooks for the constant-quality (CQ) investigation: describes
 * the device's video encoders and lets a test force one exact rate-control
 * setup on the following compressions. Not part of the public API.
 */
object RateControlProbe {

    /** A forced setup: [quality] for CQ, [bitrate] for CBR / VBR or as a CQ hint. */
    class Override(val mode: Int, val quality: Int?, val bitrate: Int?) {
        override fun toString(): String =
            "${modeName(mode)} quality=$quality bitrate=$bitrate"
    }

    @Volatile var override: Override? = null

    /** Name of the encoder the last forced compression actually configured. */
    @Volatile var lastEncoderName: String? = null

    /** Parses `{mode: "cq"|"vbr"|"cbr", quality?, bitrate?}`; null clears. */
    fun parse(args: Map<*, *>?): Override? {
        if (args == null) return null
        val mode = when (args["mode"]) {
            "cq" -> EncoderCapabilities.BITRATE_MODE_CQ
            "vbr" -> EncoderCapabilities.BITRATE_MODE_VBR
            "cbr" -> EncoderCapabilities.BITRATE_MODE_CBR
            else -> throw IllegalArgumentException("unknown mode ${args["mode"]}")
        }
        return Override(
            mode,
            (args["quality"] as? Number)?.toInt(),
            (args["bitrate"] as? Number)?.toInt(),
        )
    }

    /**
     * Configures the default encoder for [outputFormat]'s type with exactly the
     * forced setup. One attempt and no fallback, so a rejected mode fails
     * loudly instead of quietly turning into another mode.
     */
    fun configureExactly(outputFormat: MediaFormat, forced: Override): MediaCodec {
        outputFormat.setInteger(MediaFormat.KEY_BITRATE_MODE, forced.mode)
        if (forced.bitrate != null) {
            outputFormat.setInteger(MediaFormat.KEY_BIT_RATE, forced.bitrate)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            outputFormat.removeKey(MediaFormat.KEY_BIT_RATE)
        }
        if (forced.quality != null) {
            check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) { "KEY_QUALITY needs API 28" }
            outputFormat.setInteger(MediaFormat.KEY_QUALITY, forced.quality)
        }
        val encoder = MediaCodec.createEncoderByType(outputFormat.getString(MediaFormat.KEY_MIME)!!)
        val name = encoder.name
        try {
            encoder.configure(outputFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        } catch (e: Exception) {
            encoder.release()
            throw IllegalStateException("rejected by $name: ${e.message ?: e.javaClass.simpleName}", e)
        }
        lastEncoderName = name
        return encoder
    }

    /** The device and every AVC / HEVC encoder with its rate-control support. */
    fun describe(): Map<String, Any?> = mapOf(
        "manufacturer" to Build.MANUFACTURER,
        "model" to Build.MODEL,
        "hardware" to Build.HARDWARE,
        "soc" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            "${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}"
        } else {
            null
        },
        "release" to Build.VERSION.RELEASE,
        "sdk" to Build.VERSION.SDK_INT,
        "encoders" to encoders(),
    )

    private fun encoders(): List<Map<String, Any?>> {
        val infos = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
        val out = mutableListOf<Map<String, Any?>>()
        for (mime in listOf(MediaFormat.MIMETYPE_VIDEO_AVC, MediaFormat.MIMETYPE_VIDEO_HEVC)) {
            val default = try {
                MediaCodec.createEncoderByType(mime).let { codec -> codec.name.also { codec.release() } }
            } catch (e: Exception) {
                null
            }
            for (info in infos) {
                if (!info.isEncoder || info.supportedTypes.none { it.equals(mime, ignoreCase = true) }) continue
                val caps = info.getCapabilitiesForType(mime).encoderCapabilities
                out += mapOf(
                    "mime" to mime,
                    "name" to info.name,
                    "default" to (info.name == default),
                    "hardware" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        info.isHardwareAccelerated
                    } else {
                        null
                    },
                    "alias" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) info.isAlias else null,
                    "cq" to caps.isBitrateModeSupported(EncoderCapabilities.BITRATE_MODE_CQ),
                    "vbr" to caps.isBitrateModeSupported(EncoderCapabilities.BITRATE_MODE_VBR),
                    "cbr" to caps.isBitrateModeSupported(EncoderCapabilities.BITRATE_MODE_CBR),
                    "qualityRange" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        caps.qualityRange.let { "${it.lower}–${it.upper}" }
                    } else {
                        null
                    },
                )
            }
        }
        return out
    }

    private fun modeName(mode: Int): String = when (mode) {
        EncoderCapabilities.BITRATE_MODE_CQ -> "CQ"
        EncoderCapabilities.BITRATE_MODE_VBR -> "VBR"
        EncoderCapabilities.BITRATE_MODE_CBR -> "CBR"
        else -> "mode $mode"
    }
}
