package com.gurfdev.light_compressor_v2.lightcompressorlibrary.config

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.VideoFormat
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.VideoQuality
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils.saveVideoInExternal
import java.io.File
import java.io.FileInputStream
import java.io.IOException

data class Configuration(
    var quality: VideoQuality = VideoQuality.MEDIUM,
    var isMinBitrateCheckEnabled: Boolean = true,
    var videoBitrateInMbps: Number? = null,
    var disableAudio: Boolean = false,
    val resizer: VideoResizer? = VideoResizer.auto,
    var videoNames: List<String>,
    var videoFormat: VideoFormat = VideoFormat.H264,
    // Target output size in bytes. When set, the compressor solves
    // for the video bitrate that lands the output at/under it. Appended last so
    // the deprecated positional secondary constructors below stay valid.
    var targetSizeBytes: Long? = null,
    // Target output frame rate. Downsample-only; null leaves the
    // source rate unchanged.
    var videoFps: Int? = null,
    // AAC audio re-encode controls. When [audioBitrate] is set the
    // audio is re-encoded at that bitrate. NOTE: Android re-encodes at the
    // SOURCE sample rate (no resampler), so [audioSampleRate] is carried for API
    // parity but not applied here; it is honored on Apple.
    var audioBitrate: Int? = null,
    var audioSampleRate: Int? = null,
    // Two-pass encoding. When true AND [targetSizeBytes] is set, the
    // compressor re-encodes once more at a corrected bitrate if the first pass
    // overshot the target. Ignored without a target.
    var twoPass: Boolean = false,
    // Native editing. [trimStartMs]/[trimEndMs] select the kept range
    // in milliseconds (the output timeline is rebased to 0); [rotationDegrees]
    // adds a quarter-turn (0/90/180/270) on top of the source orientation. All
    // null = no edit. Appended last so the deprecated positional constructors
    // above stay valid.
    var trimStartMs: Long? = null,
    var trimEndMs: Long? = null,
    var rotationDegrees: Int? = null,
    // Color adjust. brightness -1..1 (0 = none), contrast/saturation
    // 0..2 (1 = none); null leaves the channel unchanged. Baked by the GL shader.
    var brightness: Double? = null,
    var contrast: Double? = null,
    var saturation: Double? = null,
    // Max videos transcoded at once in a batch. null keeps the
    // default cap (MAX_CONCURRENT_COMPRESSIONS); coerced to >= 1 when sized.
    var maxConcurrent: Int? = null,
    // Opt-in structured debug logging. Paths are reduced to base
    // names in the logs. Off by default.
    var debugLogging: Boolean = false,
) {
    @Deprecated("Use VideoResizer to override the output video dimensions.", ReplaceWith("Configuration(quality, isMinBitrateCheckEnabled, videoBitrateInMbps, disableAudio, resizer = if (keepOriginalResolution) null else VideoResizer.auto, videoNames)"))
    constructor(
        quality: VideoQuality = VideoQuality.MEDIUM,
        isMinBitrateCheckEnabled: Boolean = true,
        videoBitrateInMbps: Number? = null,
        disableAudio: Boolean = false,
        keepOriginalResolution: Boolean,
        videoNames: List<String>) : this(quality, isMinBitrateCheckEnabled, videoBitrateInMbps, disableAudio, getVideoResizer(keepOriginalResolution, null, null), videoNames)

    @Deprecated("Use VideoResizer to override the output video dimensions.", ReplaceWith("Configuration(quality, isMinBitrateCheckEnabled, videoBitrateInMbps, disableAudio, resizer = VideoResizer.matchSize(videoWidth, videoHeight), videoNames)"))
    constructor(
        quality: VideoQuality = VideoQuality.MEDIUM,
        isMinBitrateCheckEnabled: Boolean = true,
        videoBitrateInMbps: Number? = null,
        disableAudio: Boolean = false,
        keepOriginalResolution: Boolean = false,
        videoHeight: Double? = null,
        videoWidth: Double? = null,
        videoNames: List<String>) : this(quality, isMinBitrateCheckEnabled, videoBitrateInMbps, disableAudio, getVideoResizer(keepOriginalResolution, videoHeight, videoWidth), videoNames)
}

private fun getVideoResizer(keepOriginalResolution: Boolean, videoHeight: Double?, videoWidth: Double?): VideoResizer? =
    if (keepOriginalResolution) {
        null
    } else if (videoWidth != null && videoHeight != null) {
        VideoResizer.matchSize(videoWidth, videoHeight, true)
    } else {
        VideoResizer.auto
    }

interface StorageConfiguration {
    fun createFileToSave(
        context: Context,
        videoFile: File,
        fileName: String,
        shouldSave: Boolean
    ): File
}

class AppSpecificStorageConfiguration(
    private val subFolderName: String? = null,
) : StorageConfiguration {

    override fun createFileToSave(
        context: Context,
        videoFile: File,
        fileName: String,
        shouldSave: Boolean
    ): File {
        val fullPath =
            if (subFolderName != null) "${subFolderName}/$fileName"
            else fileName

        if (!File("${context.filesDir}/$fullPath").exists()) {
            File("${context.filesDir}/$fullPath").parentFile?.mkdirs()
        }
        return File(context.filesDir, fullPath)
    }
}


enum class SaveLocation {
    pictures,
    downloads,
    movies,
}

class SharedStorageConfiguration(
    private val saveAt: SaveLocation? = null,
    private val subFolderName: String? = null,
) : StorageConfiguration {

    override fun createFileToSave(
        context: Context,
        videoFile: File,
        fileName: String,
        shouldSave: Boolean
    ): File {
        val saveLocation =
            when (saveAt) {
                SaveLocation.downloads -> {
                    Environment.DIRECTORY_DOWNLOADS
                }

                SaveLocation.pictures -> {
                    Environment.DIRECTORY_PICTURES
                }

                else -> {
                    Environment.DIRECTORY_MOVIES
                }
            }

        if (Build.VERSION.SDK_INT >= 29) {
            val fullPath =
                if (subFolderName != null) "$saveLocation/${subFolderName}"
                else saveLocation
            if (shouldSave) {
                saveVideoInExternal(context, fileName, fullPath, videoFile)
                File(context.cacheDir, fileName).delete()
                return File("/storage/emulated/0/${fullPath}", fileName)
            }
            return File(context.cacheDir, fileName)
        } else {
            val savePath =
                Environment.getExternalStoragePublicDirectory(saveLocation)

            val fullPath =
                if (subFolderName != null) "$savePath/${subFolderName}"
                else savePath.path

            val desFile = File(fullPath, fileName)

            if (!desFile.exists()) {
                try {
                    desFile.parentFile?.mkdirs()
                } catch (e: IOException) {
                    e.printStackTrace()
                }
            }

            if (shouldSave) {
                context.openFileOutput(fileName, Context.MODE_PRIVATE)
                    .use { outputStream ->
                        FileInputStream(videoFile).use { inputStream ->
                            val buf = ByteArray(4096)
                            while (true) {
                                val sz = inputStream.read(buf)
                                if (sz <= 0) break
                                outputStream.write(buf, 0, sz)
                            }

                        }
                    }

            }
            return desFile
        }
    }
}

class CacheStorageConfiguration(
) : StorageConfiguration {
    override fun createFileToSave(
        context: Context,
        videoFile: File,
        fileName: String,
        shouldSave: Boolean
    ): File =
        File.createTempFile(videoFile.nameWithoutExtension,videoFile.extension)
}
