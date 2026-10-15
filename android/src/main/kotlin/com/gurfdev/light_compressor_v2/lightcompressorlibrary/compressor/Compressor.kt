package com.gurfdev.light_compressor_v2.lightcompressorlibrary.compressor

import android.content.Context
import android.media.*
import android.net.Uri
import android.os.Build
import android.util.Log
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.CompressionErrorType
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.CompressionProgressListener
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.ProgressInfo
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.VideoFormat
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.config.Configuration
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils.CompressorUtils.findTrack
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils.CompressorUtils.isHdr
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils.CompressorUtils.isHevcHardwareEncoderAvailable
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils.CompressorUtils.getBitrate
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils.CompressorUtils.prepareVideoHeight
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils.CompressorUtils.prepareVideoWidth
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils.CompressorUtils.printException
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils.CompressorUtils.remapDolbyVisionForDecoding
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils.CompressorUtils.setOutputFileParameters
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils.roundDimension
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.video.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import kotlin.math.roundToInt

object Compressor {

    // 2Mbps
    private const val MIN_BITRATE = 2000000

    // A two-pass run triggers a corrective second pass only when the
    // first pass overshoots the target by more than this fraction.
    private const val TWO_PASS_TOLERANCE = 0.10

    // H.264 Advanced Video Coding
    private const val MIME_TYPE = "video/avc"
    // H.265 High Efficiency Video Coding
    private const val HEVC_MIME = "video/hevc"
    private const val MEDIACODEC_TIMEOUT_DEFAULT = 100L

    // Tag for opt-in debug logging (gated on Configuration.debugLogging).
    private const val DEBUG_TAG = "LightCompressor"

    /** A path reduced to its base name, for privacy-safe debug logging. */
    private fun redact(path: String?): String =
        path?.substringAfterLast('/') ?: "?"

    private const val INVALID_BITRATE =
        "The provided bitrate is smaller than what is needed for compression " +
                "try to set isMinBitRateEnabled to false"

    @Volatile
    var isRunning = true

    suspend fun compressVideo(
        index: Int,
        context: Context,
        srcUri: Uri,
        destination: String,
        configuration: Configuration,
        listener: CompressionProgressListener,
    ): Result = withContext(Dispatchers.Default) {

        val extractor = MediaExtractor()
        // Retrieve the source's metadata to be used as input to generate new values for compression
        val mediaMetadataRetriever = MediaMetadataRetriever()

        val file = File(srcUri.path ?: "")
        if (!file.exists() || file.length() == 0L) {
            return@withContext Result(
                index,
                success = false,
                failureMessage = "File does not exist or is empty (size 0). It may not have been fully copied by file_picker.",
                errorType = CompressionErrorType.NOT_FOUND
            )
        }

        var fisRetriever: FileInputStream? = null
        try {
            fisRetriever = FileInputStream(file)
            mediaMetadataRetriever.setDataSource(fisRetriever.fd)
        } catch (exception: Exception) {
            printException(exception)
            // The fd-based source failed; drop it and fall back to a Uri source.
            try { fisRetriever?.close() } catch (ignored: Exception) {}
            fisRetriever = null
            try {
                mediaMetadataRetriever.setDataSource(context, srcUri)
            } catch (inner: Exception) {
                printException(inner)
                try { mediaMetadataRetriever.release() } catch (ignored: Exception) {}
                return@withContext Result(
                    index,
                    success = false,
                    failureMessage = "Retriever failed: ${inner.message}",
                    errorType = CompressionErrorType.UNSUPPORTED
                )
            }
        }
        // IMPORTANT: do NOT close fisRetriever here. MediaMetadataRetriever reads
        // the fd lazily during extractMetadata(); closing it now makes every
        // metadata lookup return null (observed on Qualcomm/MIUI devices), which
        // breaks duration/bitrate detection. It is closed in the finally below.

        var fisExtractor: FileInputStream? = null
        try {
            fisExtractor = FileInputStream(file)
            extractor.setDataSource(fisExtractor.fd)
        } catch (exception: Exception) {
            printException(exception)
            try { fisExtractor?.close() } catch (ignored: Exception) {}
            fisExtractor = null
            try {
                extractor.setDataSource(context, srcUri, null)
            } catch (inner: Exception) {
                printException(inner)
                try { mediaMetadataRetriever.release() } catch (ignored: Exception) {}
                try { fisRetriever?.close() } catch (ignored: Exception) {}
                return@withContext Result(
                    index,
                    success = false,
                    failureMessage = "Extractor failed: ${inner.message}",
                    errorType = CompressionErrorType.UNSUPPORTED
                )
            }
        }
        // IMPORTANT: keep fisExtractor open for the whole compression; the
        // extractor reads samples from this fd until start() releases it.

        // Hoisted out of the try so the finally can delete the re-encoded-audio
        // spill file on every exit path (success, failure, cancel, exception).
        var audioSpillFile: File? = null
        try {

        val height: Double = prepareVideoHeight(mediaMetadataRetriever)

        val width: Double = prepareVideoWidth(mediaMetadataRetriever)

        val rotationData =
            mediaMetadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION) ?: "0"

        val bitrateData =
            mediaMetadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE) ?: "0"

        val durationData =
            mediaMetadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)


        val hasVideo = mediaMetadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO)

        // Duration from retriever is in milliseconds, convert to microseconds
        var duration = (durationData?.toLongOrNull() ?: 0L) * 1000L

        if (duration <= 0L) {
            // Try to extract duration from MediaExtractor if Retriever failed.
            val videoIndex = findTrack(extractor, true)
            if (videoIndex >= 0) {
                val format = extractor.getTrackFormat(videoIndex)
                if (format.containsKey(MediaFormat.KEY_DURATION)) {
                    duration = format.getLong(MediaFormat.KEY_DURATION)
                }
            }
        }

        // Fallback: use MediaPlayer to get duration
        if (duration <= 0L) {
            try {
                val mp = android.media.MediaPlayer()
                try {
                    val fis = FileInputStream(file)
                    try {
                        mp.setDataSource(fis.fd)
                        mp.prepare()
                        val durationMs = mp.duration // in milliseconds
                        if (durationMs > 0) {
                            duration = durationMs.toLong() * 1000L // to microseconds
                        }
                    } finally {
                        try { fis.close() } catch (ignored: Exception) {}
                    }
                } finally {
                    mp.release()
                }
            } catch (e: Exception) {
                Log.w("Compressor", "MediaPlayer duration fallback failed: ${e.message}")
            }
        }

        var actualBitrate = bitrateData?.toDoubleOrNull()?.toInt() ?: 0

        // Fall back to the extractor's per-track bitrate when the retriever has none.
        if (actualBitrate <= 0) {
            val videoIndex = findTrack(extractor, true)
            if (videoIndex >= 0) {
                val format = extractor.getTrackFormat(videoIndex)
                if (format.containsKey(MediaFormat.KEY_BIT_RATE)) {
                    actualBitrate = format.getInteger(MediaFormat.KEY_BIT_RATE)
                }
            }
        }

        // If bitrate is missing or unreliable, compute from file size and duration
        if (actualBitrate <= 0 && duration > 0L) {
            val durationSec = duration / 1000000.0
            if (durationSec > 0) {
                actualBitrate = ((file.length() * 8.0) / durationSec).toInt()
                Log.i("Compressor", "Computed bitrate from file size: $actualBitrate bps (file=${file.length()} bytes, duration=${durationSec}s)")
            }
        }
        if (actualBitrate <= 0) {
            // Neither the metadata nor a duration-based computation produced a
            // bitrate. Estimate from the source resolution instead of falling
            // back to MIN_BITRATE, which would crush HD video to a tiny output.
            actualBitrate = estimateBitrateFromResolution(width, height)
        }

        if (duration <= 0L) {
            // Last resort: estimate duration based on file size and actualBitrate.
            // Note: this is only used for the progress denominator; the value
            // reported back to Dart is replaced with the exact duration measured
            // during transcoding (see start()).
            val durationSeconds = file.length() / (actualBitrate / 8.0)
            duration = (durationSeconds * 1000000.0).toLong()
            if (duration <= 0L) duration = 1L
        }

        var rotation = rotationData?.toDoubleOrNull()?.toInt() ?: 0
        val bitrate = actualBitrate

        // Native editing: resolve the kept time range in microseconds.
        // The output timeline is rebased to 0, so the *output* duration — used by
        // the size solver, the progress denominator and the reported duration — is
        // the trimmed length. loopTrimEndUs == Long.MAX_VALUE means "to the end".
        val trimStartUs =
            ((configuration.trimStartMs ?: 0L) * 1000L).coerceIn(0L, duration)
        val trimEndUs =
            if (configuration.trimEndMs != null)
                (configuration.trimEndMs!! * 1000L).coerceIn(trimStartUs + 1L, duration)
            else duration
        val loopTrimEndUs =
            if (configuration.trimEndMs != null) trimEndUs else Long.MAX_VALUE
        val outDurationUs = (trimEndUs - trimStartUs).coerceAtLeast(1L)

        // Native editing: color knobs baked by the GL shader. Identity
        // defaults (brightness 0, contrast 1, saturation 1) mean "no change".
        val colorBrightness = configuration.brightness?.toFloat() ?: 0f
        val colorContrast = configuration.contrast?.toFloat() ?: 1f
        val colorSaturation = configuration.saturation?.toFloat() ?: 1f

        // Check for a min video bitrate before compression
        // Note: this is an experimental value
        if (configuration.isMinBitrateCheckEnabled && bitrate > 0 && bitrate <= MIN_BITRATE)
            return@withContext Result(index, success = false, failureMessage = INVALID_BITRATE)

        //Handle new width and height values. Computed before the bitrate so the
        //target-size solver can scale its floor to the OUTPUT resolution.
        val resizer = configuration.resizer
        val target = resizer?.resize(width, height) ?: Pair(width, height)
        var newWidth = roundDimension(target.first)
        var newHeight = roundDimension(target.second)

        // Handle new bitrate value. Precedence: an explicit videoBitrateInMbps
        // wins; else a requested target output size is solved for; else the
        // quality preset is used.
        var targetSizeMet = true
        val newBitrate: Int = when {
            configuration.videoBitrateInMbps != null ->
                (configuration.videoBitrateInMbps!!.toDouble() * 1_000_000).roundToInt()

            configuration.targetSizeBytes != null -> {
                val durationSec = outDurationUs / 1000000.0
                // Reserve bits for the (passed-through) audio track and ~3%
                // container overhead, then solve for the video bitrate.
                val audioBps =
                    if (configuration.disableAudio) 0 else findAudioBitrate(extractor)
                val totalBudgetBits = configuration.targetSizeBytes!! * 8.0
                val audioBits = audioBps.toDouble() * durationSec
                val videoBudgetBits = totalBudgetBits * 0.97 - audioBits
                val solvedBps =
                    if (durationSec > 0) videoBudgetBits / durationSec else 0.0
                // Quality floor: keep at least MIN_BITRATE but never exceed the
                // source (a sub-floor source can't be compressed further). A
                // target below this lands at the floor and reports
                // targetSizeMet = false.
                val floor = minOf(MIN_BITRATE, actualBitrate).toDouble()
                targetSizeMet = solvedBps >= floor
                solvedBps.coerceIn(floor, actualBitrate.toDouble()).toInt()
            }

            else -> getBitrate(actualBitrate, configuration.quality)
        }

        //Handle rotation values and swapping height and width if needed
        rotation = when (rotation) {
            90, 270 -> {
                val tempHeight = newHeight
                newHeight = newWidth
                newWidth = tempHeight
                0
            }

            180 -> 0
            else -> rotation
        }

        // Native editing: apply the requested quarter-turn as a
        // container orientation hint on top of the (now-upright) output. The GL
        // pipeline draws frames upright regardless of this value, so this is a
        // metadata-only rotation — stored frames are unchanged and players rotate
        // on playback. start() writes it via mediaMuxer.setOrientationHint().
        configuration.rotationDegrees?.let { rotation = (rotation + it) % 360 }

        // Decide the output codec. H.265 is used only when the caller asked for
        // it AND the device exposes a hardware HEVC encoder; otherwise we fall
        // back to H.264 so compatibility is never silently broken.
        val outputMime =
            if (configuration.videoFormat == VideoFormat.H265 && isHevcHardwareEncoderAvailable())
                HEVC_MIME
            else
                MIME_TYPE

        // Re-encode the audio to AAC up front when a bitrate is
        // requested, capturing the encoder's output format + buffered samples so
        // the muxer track is described correctly. Null keeps the cheap
        // passthrough copy.
        val audioTranscode: AudioTranscodeResult? =
            if (!configuration.disableAudio && configuration.audioBitrate != null)
                transcodeAudioToBuffer(
                    context, srcUri, file, configuration.audioBitrate!!,
                    trimStartUs, loopTrimEndUs,
                )
            else null
        audioSpillFile = audioTranscode?.bufferFile

        // Two-pass. Enabled only when requested AND a target size was
        // set AND it is reachable (a floor-bound pass 1 can't be improved by a
        // lower bitrate). Pass 1 encodes at the solved bitrate; if it overshoots,
        // pass 2 re-encodes at a corrected (lower) bitrate. Capped at two passes.
        // Each pass's progress runs 0..99 (see start()); the terminal 100 is
        // emitted once, after this function returns.
        val twoPassEnabled =
            configuration.twoPass && configuration.targetSizeBytes != null && targetSizeMet
        val targetBytes = configuration.targetSizeBytes ?: 0L
        val floor = minOf(MIN_BITRATE, actualBitrate).toDouble()

        if (configuration.debugLogging) {
            Log.d(
                DEBUG_TAG,
                "plan #$index out=${redact(destination)} dims=${newWidth}x$newHeight " +
                    "bitrate=$newBitrate codec=${if (outputMime == HEVC_MIME) "h265" else "h264"} " +
                    "fps=${configuration.videoFps ?: "src"} " +
                    "target=${configuration.targetSizeBytes ?: "-"} targetMet=$targetSizeMet " +
                    "twoPass=$twoPassEnabled rotation=$rotation " +
                    "color=[$colorBrightness,$colorContrast,$colorSaturation]",
            )
        }

        var passesUsed = 1
        // Pass 1 reuses the extractor set up above; start() releases it.
        var result = start(
            index, newWidth, newHeight, destination, newBitrate,
            configuration.disableAudio, extractor, listener, outDurationUs, rotation,
            outputMime, targetSizeMet, configuration.videoFps, audioTranscode,
            trimStartUs, loopTrimEndUs,
            colorBrightness, colorContrast, colorSaturation,
        )

        if (twoPassEnabled && result.success && isRunning &&
            result.size > targetBytes * (1.0 + TWO_PASS_TOLERANCE)
        ) {
            val adjusted = (newBitrate.toDouble() * targetBytes / result.size)
                .coerceIn(floor, actualBitrate.toDouble()).toInt()
            // Skip pass 2 when it can't lower the bitrate (already at the floor).
            if (adjusted < newBitrate) {
                // Pass 2 writes to a temp; the valid pass-1 output is kept until
                // pass 2 succeeds, then atomically replaced. A fresh extractor is
                // required — start() drains and releases the one it is given.
                val tempDest = "$destination.p2.mp4"
                val pass2Extractor = MediaExtractor()
                var pass2Fis: FileInputStream? = null
                try {
                    try {
                        pass2Fis = FileInputStream(file)
                        pass2Extractor.setDataSource(pass2Fis.fd)
                    } catch (e: Exception) {
                        printException(e)
                        try { pass2Fis?.close() } catch (ignored: Exception) {}
                        pass2Fis = null
                        pass2Extractor.setDataSource(context, srcUri, null)
                    }
                    val pass2 = start(
                        index, newWidth, newHeight, tempDest, adjusted,
                        configuration.disableAudio, pass2Extractor, listener,
                        outDurationUs, rotation, outputMime, targetSizeMet,
                        configuration.videoFps, audioTranscode,
                        trimStartUs, loopTrimEndUs,
                        colorBrightness, colorContrast, colorSaturation,
                    )
                    passesUsed = 2
                    if (pass2.success) {
                        try {
                            File(destination).delete()
                            File(tempDest).renameTo(File(destination))
                        } catch (e: Exception) { printException(e) }
                        result = pass2.copy(
                            path = destination,
                            size = File(destination).length(),
                        )
                    } else if (pass2.cancelled) {
                        // Cancelled mid pass-2 — report the cancellation rather
                        // than the (now stale) pass-1 success.
                        try { File(tempDest).delete() } catch (ignored: Exception) {}
                        result = pass2
                    } else {
                        // Pass 2 failed — discard it, keep the valid pass 1.
                        try { File(tempDest).delete() } catch (ignored: Exception) {}
                    }
                } finally {
                    try { pass2Extractor.release() } catch (ignored: Exception) {}
                    try { pass2Fis?.close() } catch (ignored: Exception) {}
                }
            }
        }

        if (configuration.debugLogging) {
            Log.d(
                DEBUG_TAG,
                if (result.success) {
                    "done #$index out=${redact(result.path)} size=${result.size} " +
                        "durationMs=${result.duration} passes=$passesUsed " +
                        "codec=${result.videoFormat}"
                } else if (result.cancelled) {
                    "cancelled #$index"
                } else {
                    "failed #$index type=${result.errorType} msg=${result.failureMessage}"
                },
            )
        }

        return@withContext result.copy(passesUsed = passesUsed)

        } finally {
            // Release metadata resources and close the file descriptors that were
            // kept open for lazy reads during extraction/compression.
            try { mediaMetadataRetriever.release() } catch (ignored: Exception) {}
            try { fisRetriever?.close() } catch (ignored: Exception) {}
            try { fisExtractor?.close() } catch (ignored: Exception) {}
            // Delete the re-encoded-audio spill file (shared across two passes).
            try { audioSpillFile?.delete() } catch (ignored: Exception) {}
        }
    }

    @Suppress("DEPRECATION")
    private fun start(
        id: Int,
        newWidth: Int,
        newHeight: Int,
        destination: String,
        newBitrate: Int,
        disableAudio: Boolean,
        extractor: MediaExtractor,
        compressionProgressListener: CompressionProgressListener,
        duration: Long,
        rotation: Int,
        outputMime: String,
        targetSizeMet: Boolean,
        videoFps: Int?,
        audioTranscode: AudioTranscodeResult?,
        trimStartUs: Long,
        trimEndUs: Long,
        brightness: Float,
        contrast: Float,
        saturation: Float,
    ): Result {

        if (newWidth != 0 && newHeight != 0) {

            val cacheFile = File(destination)

            // Tracks the largest frame presentation time seen while transcoding.
            // This is the ground-truth duration and is used in place of the
            // (possibly estimated) input duration when reporting back to Dart.
            var maxPresentationTimeUs = 0L

            // Progress observability. encodeStartMs anchors elapsed
            // time (and the ETA projection); outputBytes accumulates encoded
            // video sample bytes written to the muxer (audio is muxed on its own
            // path, so this is the live video-output size, an indicator).
            val encodeStartMs = System.currentTimeMillis()
            var outputBytes = 0L

            // Held outside the try so the outer finally can always release the
            // native muxer, including on the early-return error paths below.
            var mediaMuxerRef: MediaMuxer? = null

            try {
                // MediaCodec accesses encoder and decoder components and processes the new video
                //input to generate a compressed/smaller size video
                val bufferInfo = MediaCodec.BufferInfo()

                // Platform MP4 muxer — natively handles AVC and HEVC, so no
                // codec-specific container code (or a third-party mp4 parser) is
                // needed. MediaMuxer requires every track to be added before
                // start(), so it is started lazily once the encoder publishes its
                // real output format (which carries the codec-specific data).
                val mediaMuxer = MediaMuxer(
                    cacheFile.absolutePath,
                    MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4,
                )
                mediaMuxerRef = mediaMuxer
                if (rotation != 0) mediaMuxer.setOrientationHint(rotation)
                var muxerStarted = false

                // Start with video track
                val videoIndex = findTrack(extractor, isVideo = true)
                if (videoIndex < 0) {
                    return Result(
                        id,
                        success = false,
                        failureMessage = "No video track found in the source file.",
                        errorType = CompressionErrorType.UNSUPPORTED,
                    )
                }

                extractor.selectTrack(videoIndex)
                // Trim (9a): start decoding at the sync sample at/before the trim
                // start; frames before trimStartUs are decoded but not rendered.
                extractor.seekTo(trimStartUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                val inputFormat = extractor.getTrackFormat(videoIndex)

                // Frame-rate downsampling (8b): drop frames toward videoFps, but
                // only when it is below the source rate (never duplicate frames).
                // frameIntervalUs == 0 disables dropping; nextEmitUs tracks the
                // timestamp of the next frame to keep.
                val sourceFps =
                    if (inputFormat.containsKey(MediaFormat.KEY_FRAME_RATE))
                        inputFormat.getInteger(MediaFormat.KEY_FRAME_RATE) else 0
                val frameIntervalUs =
                    if (videoFps != null && videoFps > 0 && (sourceFps <= 0 || videoFps < sourceFps))
                        1_000_000L / videoFps else 0L
                var nextEmitUs = 0L

                // Audio is copied through untouched. Resolve it up front because
                // every track must be added to MediaMuxer before start().
                val audioExtractorIndex = findTrack(extractor, isVideo = false)
                val audioFormat: MediaFormat? =
                    if (!disableAudio && audioExtractorIndex >= 0)
                        extractor.getTrackFormat(audioExtractorIndex)
                    else null
                var audioMuxerTrackIndex = -1

                val outputFormat: MediaFormat =
                    MediaFormat.createVideoFormat(outputMime, newWidth, newHeight)
                //set output format
                setOutputFileParameters(
                    inputFormat,
                    outputFormat,
                    newBitrate,
                )
                // When downsampling, report the reduced rate on the output format.
                if (frameIntervalUs > 0L && videoFps != null) {
                    outputFormat.setInteger(MediaFormat.KEY_FRAME_RATE, videoFps)
                }

                var decoder: MediaCodec? = null
                var encoder: MediaCodec? = null
                var inputSurface: InputSurface? = null
                var outputSurface: OutputSurface? = null

                try {
                    encoder = prepareEncoder(outputFormat)

                    var inputDone = false
                    var outputDone = false
                    // Trim (9a): set once we signal EOS early at trimEndUs, so the
                    // decoder's own end-of-stream below never signals it twice.
                    var trimEosSignaled = false

                    var videoTrackIndex = -5

                    inputSurface = InputSurface(encoder.createInputSurface())
                    inputSurface.makeCurrent()
                    //Move to executing state
                    encoder.start()

                    outputSurface = OutputSurface(brightness, contrast, saturation)

                    decoder = prepareDecoder(inputFormat, outputSurface)

                    //Move to executing state
                    decoder.start()

                    while (!outputDone) {
                        if (!inputDone) {

                            val index = extractor.sampleTrackIndex

                            if (index == videoIndex) {
                                val inputBufferIndex =
                                    decoder.dequeueInputBuffer(MEDIACODEC_TIMEOUT_DEFAULT)
                                if (inputBufferIndex >= 0) {
                                    val inputBuffer = decoder.getInputBuffer(inputBufferIndex)
                                    val chunkSize = extractor.readSampleData(inputBuffer!!, 0)
                                    when {
                                        chunkSize < 0 -> {

                                            decoder.queueInputBuffer(
                                                inputBufferIndex,
                                                0,
                                                0,
                                                0L,
                                                MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                            )
                                            inputDone = true
                                        }

                                        else -> {

                                            decoder.queueInputBuffer(
                                                inputBufferIndex,
                                                0,
                                                chunkSize,
                                                extractor.sampleTime,
                                                0
                                            )
                                            extractor.advance()

                                        }
                                    }
                                }

                            } else if (index == -1) { //end of file
                                val inputBufferIndex =
                                    decoder.dequeueInputBuffer(MEDIACODEC_TIMEOUT_DEFAULT)
                                if (inputBufferIndex >= 0) {
                                    decoder.queueInputBuffer(
                                        inputBufferIndex,
                                        0,
                                        0,
                                        0L,
                                        MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                    )
                                    inputDone = true
                                }
                            }
                        }

                        var decoderOutputAvailable = true
                        var encoderOutputAvailable = true

                        loop@ while (decoderOutputAvailable || encoderOutputAvailable) {

                            if (!isRunning) {
                                // Signal cancellation through the result; the caller
                                // turns this into a single onCancelled callback. We must
                                // NOT also fire a terminal callback here, otherwise the
                                // video reports twice (onCancelled + onFailure).
                                return Result(
                                    id,
                                    success = false,
                                    failureMessage = "The compression has stopped!",
                                    cancelled = true
                                )
                            }

                            //Encoder
                            val encoderStatus =
                                encoder.dequeueOutputBuffer(bufferInfo, MEDIACODEC_TIMEOUT_DEFAULT)

                            when {
                                encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER -> encoderOutputAvailable =
                                    false

                                encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                                    // Add every track and start the muxer exactly
                                    // once, when the encoder publishes its real
                                    // output format (which carries the csd needed
                                    // to write a correct avcC/hvcC).
                                    if (!muxerStarted) {
                                        videoTrackIndex =
                                            mediaMuxer.addTrack(encoder.outputFormat)
                                        // Re-encoded audio (8c) supplies its own
                                        // output format; otherwise use the source
                                        // format for the passthrough copy.
                                        val audioMuxFormat =
                                            audioTranscode?.format ?: audioFormat
                                        if (audioMuxFormat != null) {
                                            audioMuxerTrackIndex =
                                                mediaMuxer.addTrack(audioMuxFormat)
                                        }
                                        mediaMuxer.start()
                                        muxerStarted = true
                                    }
                                }

                                encoderStatus == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> {
                                    // ignore this status
                                }

                                encoderStatus < 0 -> throw RuntimeException("unexpected result from encoder.dequeueOutputBuffer: $encoderStatus")
                                else -> {
                                    val encodedData = encoder.getOutputBuffer(encoderStatus)
                                        ?: throw RuntimeException("encoderOutputBuffer $encoderStatus was null")

                                    if (muxerStarted && bufferInfo.size > 0 &&
                                        (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0
                                    ) {
                                        encodedData.position(bufferInfo.offset)
                                        encodedData.limit(bufferInfo.offset + bufferInfo.size)
                                        mediaMuxer.writeSampleData(
                                            videoTrackIndex, encodedData, bufferInfo
                                        )
                                        outputBytes += bufferInfo.size.toLong()
                                    }

                                    outputDone =
                                        bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                                    encoder.releaseOutputBuffer(encoderStatus, false)
                                }
                            }
                            if (encoderStatus != MediaCodec.INFO_TRY_AGAIN_LATER) continue@loop

                            //Decoder
                            val decoderStatus =
                                decoder.dequeueOutputBuffer(bufferInfo, MEDIACODEC_TIMEOUT_DEFAULT)
                            when {
                                decoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER -> decoderOutputAvailable =
                                    false

                                decoderStatus == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> {
                                    // ignore this status
                                }

                                decoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                                    // ignore this status
                                }

                                decoderStatus < 0 -> throw RuntimeException("unexpected result from decoder.dequeueOutputBuffer: $decoderStatus")
                                else -> {
                                    val pts = bufferInfo.presentationTimeUs
                                    when {
                                        // Trim (9a): past the kept range — stop here.
                                        // Drop the frame and signal end-of-stream so
                                        // the encoder drains; the output ends at
                                        // trimEndUs.
                                        trimEndUs != Long.MAX_VALUE && pts >= trimEndUs -> {
                                            decoder.releaseOutputBuffer(decoderStatus, false)
                                            decoderOutputAvailable = false
                                            inputDone = true
                                            if (!trimEosSignaled) {
                                                encoder.signalEndOfInputStream()
                                                trimEosSignaled = true
                                            }
                                        }

                                        // Trim (9a): before the kept range — decode
                                        // without rendering (don't advance the fps
                                        // emit clock) so it never reaches the encoder.
                                        pts < trimStartUs ->
                                            decoder.releaseOutputBuffer(decoderStatus, false)

                                        else -> {
                                            // Rebase the output timeline to start at 0.
                                            val rebasedUs = pts - trimStartUs
                                            // Frame-rate downsampling (8b): keep this
                                            // frame only once its (rebased) timestamp
                                            // reaches the next emit point; otherwise
                                            // drop it (decode without rendering).
                                            val keep = frameIntervalUs <= 0L ||
                                                rebasedUs >= nextEmitUs
                                            val doRender = bufferInfo.size != 0 && keep
                                            if (doRender && frameIntervalUs > 0L) {
                                                nextEmitUs += frameIntervalUs
                                            }

                                            decoder.releaseOutputBuffer(decoderStatus, doRender)
                                            if (doRender) {
                                                var errorWait = false
                                                try {
                                                    outputSurface.awaitNewImage()
                                                } catch (e: Exception) {
                                                    errorWait = true
                                                    Log.e(
                                                        "Compressor",
                                                        e.message ?: "Compression failed at swapping buffer"
                                                    )
                                                }

                                                if (!errorWait) {
                                                    outputSurface.drawImage()

                                                    inputSurface.setPresentationTime(rebasedUs * 1000)

                                                    if (rebasedUs > maxPresentationTimeUs) {
                                                        maxPresentationTimeUs = rebasedUs
                                                    }

                                                    val progress = (rebasedUs.toFloat() / duration.toFloat() * 100).coerceAtMost(99f)
                                                    val elapsedMs =
                                                        System.currentTimeMillis() - encodeStartMs
                                                    val frac = progress / 100f
                                                    // ETA only once there is enough signal; -1 = "not yet".
                                                    val etaMs = if (frac > 0.01f) {
                                                        (elapsedMs / frac - elapsedMs).toLong()
                                                    } else {
                                                        -1L
                                                    }
                                                    compressionProgressListener.onProgressChanged(
                                                        id,
                                                        ProgressInfo(
                                                            progress,
                                                            outputBytes,
                                                            etaMs,
                                                            elapsedMs,
                                                        )
                                                    )

                                                    inputSurface.swapBuffers()
                                                }
                                            }
                                        }
                                    }
                                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                                        decoderOutputAvailable = false
                                        if (!trimEosSignaled) {
                                            encoder.signalEndOfInputStream()
                                            trimEosSignaled = true
                                        }
                                    }
                                }
                            }
                        }
                    }

                } catch (exception: Exception) {
                    printException(exception)
                    return Result(id, success = false, failureMessage = exception.message)
                } finally {
                    extractor.unselectTrack(videoIndex)

                    try { decoder?.stop() } catch (ignored: Exception) {}
                    try { decoder?.release() } catch (ignored: Exception) {}

                    try { encoder?.stop() } catch (ignored: Exception) {}
                    try { encoder?.release() } catch (ignored: Exception) {}

                    try { inputSurface?.release() } catch (ignored: Exception) {}
                    try { outputSurface?.release() } catch (ignored: Exception) {}
                }

                if (muxerStarted && audioMuxerTrackIndex >= 0) {
                    if (audioTranscode != null) {
                        // Stream the pre-encoded AAC samples from the spill file.
                        writeBufferedAudio(
                            mediaMuxer,
                            audioMuxerTrackIndex,
                            audioTranscode.bufferFile,
                            bufferInfo,
                        )
                    } else if (audioFormat != null) {
                        copyAudioSamples(
                            mediaMuxer,
                            audioMuxerTrackIndex,
                            audioExtractorIndex,
                            extractor,
                            bufferInfo,
                            trimStartUs,
                            trimEndUs,
                        )
                    }
                }

                extractor.release()
                if (muxerStarted) {
                    try { mediaMuxer.stop() } catch (e: Exception) { printException(e) }
                } else {
                    // The encoder never published an output format, so no track
                    // was written — report failure instead of a 0-byte "success".
                    return Result(
                        id,
                        success = false,
                        failureMessage = "Compression produced no output (the source may be empty or unsupported).",
                        errorType = CompressionErrorType.UNSUPPORTED,
                    )
                }

            } catch (exception: Exception) {
                printException(exception)
                return Result(
                    id,
                    success = false,
                    failureMessage = exception.message ?: "An error occurred during video compression setup"
                )
            } finally {
                // Always release the native muxer — including the early-return
                // error paths above. release() is safe whether or not start()/
                // stop() ran.
                try { mediaMuxerRef?.release() } catch (ignored: Exception) {}
            }

            // Prefer the exact duration measured during transcoding; fall back to
            // the (possibly estimated) input duration only if no frames were timed.
            val reportedDurationUs =
                if (maxPresentationTimeUs > 0L) maxPresentationTimeUs else duration
            return Result(
                id,
                success = true,
                failureMessage = null,
                size = cacheFile.length(),
                path = cacheFile.path,
                duration = reportedDurationUs.toDouble() / 1000000.0,
                videoFormat = if (outputMime == HEVC_MIME) "h265" else "h264",
                targetSizeMet = targetSizeMet,
            )
        }

        return Result(
            id,
            success = false,
            failureMessage = "Something went wrong, please try again"
        )
    }

    /**
     * The captured AAC output format plus a temp file holding every re-encoded
     * access unit as length-prefixed records (pts: Long, flags: Int, size: Int,
     * then the bytes). Samples are spilled to disk instead of held in RAM, so
     * memory stays flat regardless of audio duration; [bufferFile] is deleted
     * once compression finishes (compressVideo's finally).
     */
    private class AudioTranscodeResult(
        val format: MediaFormat,
        val bufferFile: File,
    )

    /**
     * Decodes the source audio to PCM and re-encodes it to AAC at
     * [targetBitrate], keeping the source sample rate (no resampler). Buffers the
     * encoded samples and captures the encoder's real output format so the caller
     * can add a correctly-described muxer track before MediaMuxer.start(). Uses
     * its own MediaExtractor so it does not disturb the video extractor. Returns
     * null when there is no audio track or transcoding fails (the caller then
     * falls back to the verbatim passthrough copy).
     *
     * The encoded audio is written to a temp file rather than held in RAM, so
     * memory stays flat regardless of audio duration (MediaMuxer needs the audio
     * track format before start(), so the samples can't go straight to the muxer).
     */
    private fun transcodeAudioToBuffer(
        context: Context,
        srcUri: Uri,
        file: File,
        targetBitrate: Int,
        trimStartUs: Long,
        trimEndUs: Long,
    ): AudioTranscodeResult? {
        val extractor = MediaExtractor()
        var fis: FileInputStream? = null
        var decoder: MediaCodec? = null
        var encoder: MediaCodec? = null
        var bufferFile: File? = null
        var bufferOut: DataOutputStream? = null
        var success = false
        try {
            try {
                fis = FileInputStream(file)
                extractor.setDataSource(fis.fd)
            } catch (e: Exception) {
                try { fis?.close() } catch (ignored: Exception) {}
                fis = null
                extractor.setDataSource(context, srcUri, null)
            }

            val audioIndex = findTrack(extractor, isVideo = false)
            if (audioIndex < 0) return null
            extractor.selectTrack(audioIndex)
            extractor.seekTo(trimStartUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val inputFormat = extractor.getTrackFormat(audioIndex)
            val mime = inputFormat.getString(MediaFormat.KEY_MIME) ?: return null
            val sampleRate =
                if (inputFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE))
                    inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE) else 44100
            val channelCount =
                if (inputFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT))
                    inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else 2

            decoder = MediaCodec.createDecoderByType(mime)
            decoder.configure(inputFormat, null, null, 0)
            decoder.start()

            val outFormat = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channelCount,
            )
            outFormat.setInteger(
                MediaFormat.KEY_AAC_PROFILE,
                MediaCodecInfo.CodecProfileLevel.AACObjectLC,
            )
            outFormat.setInteger(MediaFormat.KEY_BIT_RATE, targetBitrate)
            outFormat.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 64 * 1024)
            encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            encoder.configure(outFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoder.start()

            bufferFile = File.createTempFile("lc_audio_", ".tmp", context.cacheDir)
            bufferOut = DataOutputStream(BufferedOutputStream(FileOutputStream(bufferFile)))
            var encoderFormat: MediaFormat? = null
            val info = MediaCodec.BufferInfo()
            val timeoutUs = 10000L

            var extractorDone = false
            var decoderDone = false
            var encoderDone = false

            // A decoded PCM buffer is held here until the encoder can accept it,
            // so we never dequeue a decoder buffer we cannot immediately feed.
            var pendingIndex = -1
            var pendingOffset = 0
            var pendingSize = 0
            var pendingPts = 0L
            var pendingEos = false

            while (!encoderDone) {
                // 1) Feed the extractor into the decoder.
                if (!extractorDone) {
                    val inIndex = decoder.dequeueInputBuffer(timeoutUs)
                    if (inIndex >= 0) {
                        // Trim (9a): skip audio before the trim start.
                        while (extractor.sampleTrackIndex == audioIndex &&
                            extractor.sampleTime in 0L until trimStartUs
                        ) {
                            extractor.advance()
                        }
                        val sampleTime = extractor.sampleTime
                        val buf = decoder.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(buf, 0)
                        if (size < 0 ||
                            (trimEndUs != Long.MAX_VALUE && sampleTime >= trimEndUs)
                        ) {
                            decoder.queueInputBuffer(
                                inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            extractorDone = true
                        } else {
                            // Rebase onto the trimmed timeline.
                            decoder.queueInputBuffer(
                                inIndex, 0, size, sampleTime - trimStartUs, 0,
                            )
                            extractor.advance()
                        }
                    }
                }

                // 2) Pull a decoded PCM buffer (only when not already holding one).
                if (!decoderDone && pendingIndex < 0) {
                    val outIndex = decoder.dequeueOutputBuffer(info, timeoutUs)
                    if (outIndex >= 0) {
                        pendingIndex = outIndex
                        pendingOffset = info.offset
                        pendingSize = info.size
                        pendingPts = info.presentationTimeUs
                        pendingEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    }
                }

                // 3) Feed the held PCM into the encoder once it has an input slot.
                if (pendingIndex >= 0) {
                    val encIn = encoder.dequeueInputBuffer(timeoutUs)
                    if (encIn >= 0) {
                        val encBuf = encoder.getInputBuffer(encIn)!!
                        encBuf.clear()
                        if (pendingSize > 0) {
                            val pcm = decoder.getOutputBuffer(pendingIndex)!!
                            pcm.position(pendingOffset)
                            pcm.limit(pendingOffset + pendingSize)
                            encBuf.put(pcm)
                        }
                        encoder.queueInputBuffer(
                            encIn, 0, pendingSize, pendingPts,
                            if (pendingEos) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0,
                        )
                        decoder.releaseOutputBuffer(pendingIndex, false)
                        if (pendingEos) decoderDone = true
                        pendingIndex = -1
                    }
                }

                // 4) Drain the encoder, buffering samples + capturing the format.
                val encOut = encoder.dequeueOutputBuffer(info, timeoutUs)
                if (encOut == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    encoderFormat = encoder.outputFormat
                } else if (encOut >= 0) {
                    val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                    if (info.size > 0 && !isConfig) {
                        val out = encoder.getOutputBuffer(encOut)!!
                        out.position(info.offset)
                        out.limit(info.offset + info.size)
                        val data = ByteArray(info.size)
                        out.get(data)
                        // Spill each access unit to disk (length-prefixed)
                        // instead of accumulating in RAM, so the buffer no longer
                        // scales with audio duration.
                        bufferOut!!.writeLong(info.presentationTimeUs)
                        bufferOut!!.writeInt(info.flags)
                        bufferOut!!.writeInt(data.size)
                        bufferOut!!.write(data)
                    }
                    encoder.releaseOutputBuffer(encOut, false)
                    if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        encoderDone = true
                    }
                }
            }

            try { bufferOut?.flush() } catch (ignored: Exception) {}
            val transcodeResult =
                encoderFormat?.let { AudioTranscodeResult(it, bufferFile!!) }
            success = transcodeResult != null
            return transcodeResult
        } catch (e: Exception) {
            printException(e)
            return null
        } finally {
            try { decoder?.stop() } catch (ignored: Exception) {}
            try { decoder?.release() } catch (ignored: Exception) {}
            try { encoder?.stop() } catch (ignored: Exception) {}
            try { encoder?.release() } catch (ignored: Exception) {}
            try { extractor.release() } catch (ignored: Exception) {}
            try { fis?.close() } catch (ignored: Exception) {}
            try { bufferOut?.close() } catch (ignored: Exception) {}
            // Drop the spill file unless it was handed off in the result.
            if (!success) try { bufferFile?.delete() } catch (ignored: Exception) {}
        }
    }

    /** Streams the AAC access units that [transcodeAudioToBuffer] spilled to
     *  [bufferFile] into the already-added muxer audio [trackIndex], one record
     *  at a time (so memory stays flat regardless of audio length). */
    private fun writeBufferedAudio(
        mediaMuxer: MediaMuxer,
        trackIndex: Int,
        bufferFile: File,
        bufferInfo: MediaCodec.BufferInfo,
    ) {
        DataInputStream(BufferedInputStream(FileInputStream(bufferFile))).use { input ->
            while (true) {
                val presentationTimeUs: Long
                try {
                    presentationTimeUs = input.readLong()
                } catch (e: EOFException) {
                    break // clean end of the spill file
                }
                val flags = input.readInt()
                val size = input.readInt()
                val data = ByteArray(size)
                input.readFully(data)
                bufferInfo.offset = 0
                bufferInfo.size = size
                bufferInfo.presentationTimeUs = presentationTimeUs
                bufferInfo.flags = flags
                mediaMuxer.writeSampleData(trackIndex, ByteBuffer.wrap(data), bufferInfo)
            }
        }
    }

    /**
     * Copies the source audio track verbatim into [mediaMuxer]. The track is
     * already added (MediaMuxer requires that before start()); here we just pump
     * the encoded audio samples through, unchanged.
     */
    private fun copyAudioSamples(
        mediaMuxer: MediaMuxer,
        muxerTrackIndex: Int,
        audioExtractorIndex: Int,
        extractor: MediaExtractor,
        bufferInfo: MediaCodec.BufferInfo,
        trimStartUs: Long,
        trimEndUs: Long,
    ) {
        extractor.selectTrack(audioExtractorIndex)
        val audioFormat = extractor.getTrackFormat(audioExtractorIndex)
        var maxBufferSize =
            if (audioFormat.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE))
                audioFormat.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)
            else 0
        if (maxBufferSize <= 0) maxBufferSize = 64 * 1024

        var buffer: ByteBuffer = ByteBuffer.allocateDirect(maxBufferSize)
        if (Build.VERSION.SDK_INT >= 28) {
            val size = extractor.sampleSize
            if (size > maxBufferSize) {
                maxBufferSize = (size + 1024).toInt()
                buffer = ByteBuffer.allocateDirect(maxBufferSize)
            }
        }

        extractor.seekTo(trimStartUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        var inputDone = false
        while (!inputDone) {
            when (extractor.sampleTrackIndex) {
                audioExtractorIndex -> {
                    val sampleTime = extractor.sampleTime
                    when {
                        // Trim (9a): past the kept range — stop.
                        trimEndUs != Long.MAX_VALUE && sampleTime >= trimEndUs ->
                            inputDone = true
                        // Trim (9a): before the kept range — skip without writing.
                        sampleTime in 0L until trimStartUs -> extractor.advance()
                        else -> {
                            val chunkSize = extractor.readSampleData(buffer, 0)
                            if (chunkSize >= 0) {
                                bufferInfo.offset = 0
                                bufferInfo.size = chunkSize
                                // Rebase onto the trimmed timeline.
                                bufferInfo.presentationTimeUs = sampleTime - trimStartUs
                                bufferInfo.flags =
                                    if ((extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0)
                                        MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                                buffer.position(0)
                                buffer.limit(chunkSize)
                                mediaMuxer.writeSampleData(muxerTrackIndex, buffer, bufferInfo)
                                extractor.advance()
                            } else {
                                inputDone = true
                            }
                        }
                    }
                }
                -1 -> inputDone = true
                else -> extractor.advance()
            }
        }
        extractor.unselectTrack(audioExtractorIndex)
    }

    /**
     * Rough source-bitrate estimate (bps) based on the source resolution, used
     * only when neither the file metadata nor a duration-based computation could
     * provide a real bitrate. Picks a sane H.264 ballpark so that the
     * quality-based fraction in [CompressorUtils.getBitrate] yields a reasonable
     * output instead of the absurdly small result MIN_BITRATE would produce.
     */
    /**
     * Source audio-track bitrate (bps) for the target-size solver's audio
     * reserve, or a 128 kbps AAC fallback when the track does not report one.
     */
    private fun findAudioBitrate(extractor: MediaExtractor): Int {
        val audioIndex = findTrack(extractor, isVideo = false)
        if (audioIndex >= 0) {
            val format = extractor.getTrackFormat(audioIndex)
            if (format.containsKey(MediaFormat.KEY_BIT_RATE)) {
                val br = format.getInteger(MediaFormat.KEY_BIT_RATE)
                if (br > 0) return br
            }
        }
        return 128_000
    }

    private fun estimateBitrateFromResolution(width: Double, height: Double): Int {
        val pixels = width * height
        return when {
            pixels >= 1920 * 1080 -> 12_000_000 // 1080p+
            pixels >= 1280 * 720 -> 6_000_000   // 720p
            pixels >= 854 * 480 -> 3_000_000    // 480p
            else -> MIN_BITRATE
        }
    }

    private fun prepareEncoder(outputFormat: MediaFormat): MediaCodec {
        var encoder: MediaCodec? = null
        var lastException: Exception? = null
        // The encoder must match the codec chosen for the output format (AVC/HEVC).
        val mime = outputFormat.getString(MediaFormat.KEY_MIME) ?: MIME_TYPE

        // Attempt 1: Default configuration (Hardware, Profile, CBR mode)
        try {
            encoder = MediaCodec.createEncoderByType(mime)
            encoder.configure(outputFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            return encoder
        } catch (e: Exception) {
            lastException = e
            Log.w("Compressor", "Failed to configure hardware encoder with default format: ${e.message}")
            try { encoder?.release() } catch (ignored: Exception) {}
        }

        // Attempt 2: Fallback to VBR (Variable Bitrate Mode) with profile
        val formatVBR = cloneFormat(outputFormat)
        formatVBR.setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
        try {
            encoder = MediaCodec.createEncoderByType(mime)
            encoder.configure(formatVBR, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            return encoder
        } catch (e: Exception) {
            lastException = e
            Log.w("Compressor", "Failed to configure hardware encoder with VBR mode: ${e.message}")
            try { encoder?.release() } catch (ignored: Exception) {}
        }

        // Attempt 3: Remove profile level (Baseline/Default fallback, VBR mode)
        val formatNoProfile = cloneFormat(formatVBR, listOf(MediaFormat.KEY_PROFILE, MediaFormat.KEY_LEVEL))
        try {
            encoder = MediaCodec.createEncoderByType(mime)
            encoder.configure(formatNoProfile, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            return encoder
        } catch (e: Exception) {
            lastException = e
            Log.w("Compressor", "Failed to configure hardware encoder without profile: ${e.message}")
            try { encoder?.release() } catch (ignored: Exception) {}
        }

        // Attempt 4: Fallback to Software Encoders (codec-specific names).
        val softwareEncoderNames = if (mime == HEVC_MIME) {
            listOf("c2.android.hevc.encoder", "OMX.google.hevc.encoder")
        } else {
            listOf("c2.android.avc.encoder", "OMX.google.h264.encoder")
        }
        for (name in softwareEncoderNames) {
            try {
                encoder = MediaCodec.createByCodecName(name)
                encoder.configure(formatNoProfile, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                Log.i("Compressor", "Successfully configured software encoder fallback: $name")
                return encoder
            } catch (e: Exception) {
                lastException = e
                Log.w("Compressor", "Failed to configure software encoder $name: ${e.message}")
                try { encoder?.release() } catch (ignored: Exception) {}
            }
        }

        throw lastException ?: RuntimeException("Failed to prepare and configure encoder")
    }

    private fun cloneFormat(format: MediaFormat, excludeKeys: List<String> = emptyList()): MediaFormat {
        val width = format.getInteger(MediaFormat.KEY_WIDTH)
        val height = format.getInteger(MediaFormat.KEY_HEIGHT)
        val mime = format.getString(MediaFormat.KEY_MIME)!!
        val newFormat = MediaFormat.createVideoFormat(mime, width, height)

        val keys = listOf(
            MediaFormat.KEY_BIT_RATE,
            MediaFormat.KEY_FRAME_RATE,
            MediaFormat.KEY_I_FRAME_INTERVAL,
            MediaFormat.KEY_COLOR_FORMAT,
            MediaFormat.KEY_COLOR_STANDARD,
            MediaFormat.KEY_COLOR_TRANSFER,
            MediaFormat.KEY_COLOR_RANGE,
            MediaFormat.KEY_BITRATE_MODE,
            MediaFormat.KEY_PROFILE,
            MediaFormat.KEY_LEVEL
        )
        for (key in keys) {
            if (!excludeKeys.contains(key) && format.containsKey(key)) {
                try {
                    newFormat.setInteger(key, format.getInteger(key))
                } catch (ignored: Exception) {}
            }
        }
        return newFormat
    }

    private fun prepareDecoder(
        inputFormat: MediaFormat,
        outputSurface: OutputSurface,
    ): MediaCodec {
        // This seems to cause an issue with certain phones
        // val decoderName =
        //    MediaCodecList(REGULAR_CODECS).findDecoderForFormat(inputFormat)
        // val decoder = MediaCodec.createByCodecName(decoderName)
        // Log.i("decoderName", decoder.name)

        // val decoder = if (hasQTI) {
        // MediaCodec.createByCodecName("c2.android.avc.decoder")
        //} else {

        // The encoder input is 8-bit, so ask the decoder to tone-map an HDR
        // source to SDR (API 33+, honoured where the decoder supports it).
        val toneMap = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            isHdr(inputFormat)
        if (toneMap) {
            inputFormat.setInteger(
                MediaFormat.KEY_COLOR_TRANSFER_REQUEST,
                MediaFormat.COLOR_TRANSFER_SDR_VIDEO,
            )
        }
        remapDolbyVisionForDecoding(inputFormat)

        val decoder = MediaCodec.createDecoderByType(inputFormat.getString(MediaFormat.KEY_MIME)!!)
        //}

        try {
            decoder.configure(inputFormat, outputSurface.getSurface(), null, 0)
        } catch (e: Exception) {
            if (!toneMap || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) throw e
            // A decoder that rejects the tone-mapping request: decode as-is.
            decoder.reset()
            inputFormat.removeKey(MediaFormat.KEY_COLOR_TRANSFER_REQUEST)
            decoder.configure(inputFormat, outputSurface.getSurface(), null, 0)
        }

        return decoder
    }
}
