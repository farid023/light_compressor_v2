package com.gurfdev.light_compressor_v2.lightcompressorlibrary.video

import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils.CompressorUtils

/**
 * Decodes one frame straight from a video track, for when
 * `MediaMetadataRetriever` cannot. The retriever picks its decoder from the
 * track's MIME type and has no fallback, so a Dolby Vision track (an iPhone HDR
 * recording) fails on every device without a Dolby Vision decoder — and its
 * own HEVC attempt can fail too, since hardware decoders may hand 10-bit
 * frames to buffer output in a vendor layout and the software decoder may not
 * do 10-bit at all.
 *
 * So the frame takes the compressor's own path instead: the track remapped to
 * its base layer, a decoder rendering to a SurfaceTexture, drawn with GL into
 * an RGBA ImageReader. An HDR source is tone-mapped by the decoder where it
 * supports that (API 33+).
 */
object FrameGrabber {

    private const val TIMEOUT_US = 10_000L
    private const val IMAGE_WAIT_MS = 2_500L

    /**
     * Returns the sync frame at or before [positionUs], upright, or null when
     * the track cannot be decoded. Matches `OPTION_CLOSEST_SYNC`.
     */
    fun frameAt(path: String, positionUs: Long): Bitmap? {
        val extractor = MediaExtractor()
        var reader: ImageReader? = null
        var inputSurface: InputSurface? = null
        var outputSurface: OutputSurface? = null
        var decoder: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            val track = CompressorUtils.findTrack(extractor, isVideo = true)
            if (track < 0) return null
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            // A decoder rendering to a surface applies the track rotation itself,
            // so the drawn frame is already upright (as in the compressor); a
            // quarter-turn only swaps the target's dimensions.
            val rotation =
                if (format.containsKey(MediaFormat.KEY_ROTATION)) format.getInteger(MediaFormat.KEY_ROTATION) else 0
            val quarterTurn = rotation == 90 || rotation == 270
            val width = format.getInteger(if (quarterTurn) MediaFormat.KEY_HEIGHT else MediaFormat.KEY_WIDTH)
            val height = format.getInteger(if (quarterTurn) MediaFormat.KEY_WIDTH else MediaFormat.KEY_HEIGHT)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && CompressorUtils.isHdr(format)) {
                format.setInteger(
                    MediaFormat.KEY_COLOR_TRANSFER_REQUEST,
                    MediaFormat.COLOR_TRANSFER_SDR_VIDEO,
                )
            }
            CompressorUtils.remapDolbyVisionForDecoding(format)

            val imageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
            reader = imageReader
            val input = InputSurface(imageReader.surface).also { inputSurface = it }
            input.makeCurrent()
            val output = OutputSurface().also { outputSurface = it }
            val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            decoder = codec
            codec.configure(format, output.getSurface(), null, 0)
            codec.start()
            extractor.seekTo(positionUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

            val info = MediaCodec.BufferInfo()
            var inputDone = false
            while (true) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inIndex >= 0) {
                        val size = extractor.readSampleData(codec.getInputBuffer(inIndex)!!, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                if (outIndex < 0) continue
                if (info.size > 0) {
                    // The first decoded frame after the seek is the sync frame.
                    codec.releaseOutputBuffer(outIndex, true)
                    output.awaitNewImage()
                    output.drawImage()
                    input.setPresentationTime(info.presentationTimeUs * 1000)
                    input.swapBuffers()
                    return readFrame(imageReader, width, height)
                }
                codec.releaseOutputBuffer(outIndex, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return null
            }
        } catch (e: Exception) {
            return null
        } finally {
            try { decoder?.stop() } catch (ignored: Exception) {}
            try { decoder?.release() } catch (ignored: Exception) {}
            try { outputSurface?.release() } catch (ignored: Exception) {}
            try { inputSurface?.release() } catch (ignored: Exception) {}
            try { reader?.close() } catch (ignored: Exception) {}
            try { extractor.release() } catch (ignored: Exception) {}
        }
    }

    /** Waits for the drawn frame to land in [reader] and copies it out. */
    private fun readFrame(reader: ImageReader, width: Int, height: Int): Bitmap? {
        val deadline = System.currentTimeMillis() + IMAGE_WAIT_MS
        var image = reader.acquireLatestImage()
        while (image == null && System.currentTimeMillis() < deadline) {
            Thread.sleep(5)
            image = reader.acquireLatestImage()
        }
        return image?.use {
            val plane = it.planes[0]
            // Rows may be padded: copy at the padded width, then crop.
            val padded = Bitmap.createBitmap(
                plane.rowStride / plane.pixelStride, height, Bitmap.Config.ARGB_8888,
            )
            padded.copyPixelsFromBuffer(plane.buffer)
            if (padded.width == width) {
                padded
            } else {
                Bitmap.createBitmap(padded, 0, 0, width, height).also { padded.recycle() }
            }
        }
    }
}
