package com.gurfdev.light_compressor_v2.lightcompressorlibrary

import android.content.ContentValues
import android.content.Context
import android.content.Context.MODE_PRIVATE
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.compressor.Compressor.compressVideo
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.compressor.Compressor.isRunning
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.config.*
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils.describeFailure
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils.saveVideoInExternal
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.video.Result
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Semaphore
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException


enum class VideoQuality {
    VERY_HIGH, HIGH, MEDIUM, LOW, VERY_LOW
}

/** Output video codec. [H265] falls back to [H264] when no hardware HEVC
 *  encoder is available on the device. */
enum class VideoFormat {
    H264, H265
}

object VideoCompressor : CoroutineScope by MainScope() {

    private val jobs = mutableListOf<Job>()

    /**
     * Maximum number of videos transcoded at the same time within one batch.
     *
     * Each transcode holds a hardware decoder + encoder + GL surface, and most
     * SoCs expose only a few concurrent codec instances. Running an entire
     * batch in parallel oversubscribes them and surfaces as
     * "Surface frame wait timed out". Two gives some overlap without exhausting
     * the codecs; any extra videos queue until a slot frees up.
     */
    private const val MAX_CONCURRENT_COMPRESSIONS = 2

    /**
     * This function compresses a given list of [uris] of video files and writes the compressed
     * video file at [SharedStorageConfiguration.saveAt] directory, or at [AppSpecificStorageConfiguration.subFolderName]
     *
     * The source videos should be provided content uris.
     *
     * Only [sharedStorageConfiguration] or [appSpecificStorageConfiguration] must be specified at a
     * time. Passing both will throw an Exception.
     *
     * @param [context] the application context.
     * @param [uris] the list of content Uris of the video files.
     * @param [sharedStorageConfiguration] configuration for the path directory where the compressed
     * videos will be saved, and the name of the file
     * @param [appSpecificStorageConfiguration] configuration for the path directory where the compressed
     * videos will be saved, the name of the file, and any sub-folders name. The library won't create the subfolder
     * and will throw an exception if the subfolder does not exist.
     * @param [listener] a compression listener that listens to compression [CompressionListener.onStart],
     * [CompressionListener.onProgress], [CompressionListener.onFailure], [CompressionListener.onSuccess]
     * and if the compression was [CompressionListener.onCancelled]
     * @param [configureWith] to allow add video compression configuration that could be:
     * [Configuration.quality] to allow choosing a video quality that can be [VideoQuality.LOW],
     * [VideoQuality.MEDIUM], [VideoQuality.HIGH], and [VideoQuality.VERY_HIGH].
     * This defaults to [VideoQuality.MEDIUM]
     * [Configuration.isMinBitrateCheckEnabled] to determine if the checking for a minimum bitrate threshold
     * before compression is enabled or not. This default to `true`
     * [Configuration.videoBitrateInMbps] which is a custom bitrate for the video. You might consider setting
     * [Configuration.isMinBitrateCheckEnabled] to `false` if your bitrate is less than 2000000.
     *  * [Configuration.keepOriginalResolution] to keep the original video height and width when compressing.
     * This defaults to `false`
     * [Configuration.videoHeight] which is a custom height for the video. Must be specified with [Configuration.videoWidth]
     * [Configuration.videoWidth] which is a custom width for the video. Must be specified with [Configuration.videoHeight]
     */
    @JvmStatic
    @JvmOverloads
    fun start(
        context: Context,
        uris: List<Uri>,
        storageConfiguration: StorageConfiguration,
        configureWith: Configuration,
        listener: CompressionListener,
    ) {
        require(configureWith.videoNames.size == uris.size) {
            "videoNames.size (${configureWith.videoNames.size}) must equal uris.size (${uris.size})"
        }

        doVideoCompression(
            context,
            uris,
            storageConfiguration,
            configureWith,
            listener,
        )
    }

    /**
     * Call this function to cancel video compression process which will call [CompressionListener.onCancelled]
     */
    @JvmStatic
    fun cancel() {
        // Stop the running compressions first, then cancel every coroutine so a
        // batch is fully halted (not just the most recently launched video).
        isRunning = false
        jobs.forEach { it.cancel() }
        jobs.clear()
    }

    /**
     * Whether a compression run is currently active. Reflects live coroutine
     * state ([Job.isActive]) rather than [Compressor.isRunning], which is not
     * reset on normal completion and so cannot tell "finished" from "running".
     */
    @JvmStatic
    fun isCompressing(): Boolean = jobs.any { it.isActive }

    private fun doVideoCompression(
        context: Context,
        uris: List<Uri>,
        storageConfiguration: StorageConfiguration,
        configuration: Configuration,
        listener: CompressionListener,
    ) {
        // Mark the whole run active once, so concurrent videos don't each reset
        // the flag and clobber a cancel() request mid-batch.
        isRunning = true
        jobs.clear()
        // Bound concurrent transcodes per batch. Honors a caller-supplied
        // maxConcurrent (coerced to >= 1); otherwise the default cap (see
        // MAX_CONCURRENT_COMPRESSIONS) — running a whole batch at once
        // oversubscribes the hardware codecs.
        val concurrency =
            configuration.maxConcurrent?.coerceAtLeast(1) ?: MAX_CONCURRENT_COMPRESSIONS
        val semaphore = Semaphore(concurrency)
        for (i in uris.indices) {

            // Every terminal callback for this video goes through `report`, so it
            // fires exactly once — including for a job cancelled before it ever
            // ran, which reportIfUnreported below catches.
            val report = TerminalReport()
            val coroutineExceptionHandler = CoroutineExceptionHandler { _, throwable ->
                report.once { listener.onFailure(i, describeFailure(throwable), classifyThrowable(throwable)) }
            }
            val coroutineScope = CoroutineScope(Job() + coroutineExceptionHandler)

            jobs.add(coroutineScope.launch(Dispatchers.IO) {
                var tempSrcFile: File? = null
                var finalDesFile: File? = null
                var permitAcquired = false
                try {
                    // Wait for a free transcode slot. Suspends (cheaply) when the
                    // batch is already at MAX_CONCURRENT_COMPRESSIONS. Acquiring
                    // inside the try means a cancel while still queued is caught
                    // below and reported as onCancelled(i), like a running video.
                    semaphore.acquire()
                    permitAcquired = true

                    val job = async { getMediaPath(context, uris[i]) }
                    val path = job.await()

                    if (path.startsWith(context.cacheDir.path)) {
                        tempSrcFile = File(path)
                    }

                    val desFile = saveVideoFile(
                        context,
                        path,
                        storageConfiguration,
                        configuration.videoNames[i],
                        shouldSave = false
                    )
                    finalDesFile = desFile

                    if (desFile == null) {
                        report.once {
                            listener.onFailure(i, "Could not create the output file.", CompressionErrorType.UNKNOWN)
                        }
                    }

                    desFile?.let {
                        listener.onStart(i)
                        val result = startCompression(
                            i,
                            context,
                            uris[i],
                            desFile.path,
                            configuration,
                            listener,
                        )

                        // Runs in Main(UI) Thread
                        if (result.success) {
                            val savedFile = saveVideoFile(
                                context,
                                result.path,
                                storageConfiguration,
                                configuration.videoNames[i],
                                shouldSave = true
                            )

                            report.once {
                                listener.onSuccess(i, result.size, savedFile?.path, result.duration, result.videoFormat, result.targetSizeMet, result.passesUsed)
                            }
                        } else {
                            try {
                                if (finalDesFile?.exists() == true) finalDesFile.delete()
                            } catch (e: Exception) {}

                            report.once {
                                if (result.cancelled) {
                                    listener.onCancelled(i)
                                } else {
                                    listener.onFailure(i, result.failureMessage ?: "An error has occurred!", result.errorType)
                                }
                            }
                        }
                    }
                } catch (t: Throwable) {
                    try {
                        if (finalDesFile?.exists() == true) finalDesFile.delete()
                    } catch (e: Exception) {}
                    report.once {
                        if (t is CancellationException) {
                            listener.onCancelled(i)
                        } else {
                            listener.onFailure(i, describeFailure(t), classifyThrowable(t))
                        }
                    }
                } finally {
                    if (permitAcquired) semaphore.release()
                    try {
                        if (tempSrcFile?.exists() == true) tempSrcFile.delete()
                    } catch (e: Exception) {}
                }
            }.reportIfUnreported(report) { cause ->
                if (cause is CancellationException) {
                    listener.onCancelled(i)
                } else {
                    listener.onFailure(
                        i,
                        cause?.let(::describeFailure) ?: "The compression ended without a result.",
                        cause?.let(::classifyThrowable) ?: CompressionErrorType.UNKNOWN,
                    )
                }
            })
        }
    }

    private suspend fun startCompression(
        index: Int,
        context: Context,
        srcUri: Uri,
        destPath: String,
        configuration: Configuration,
        listener: CompressionListener,
    ): Result = withContext(Dispatchers.Default) {
        return@withContext compressVideo(
            index,
            context,
            srcUri,
            destPath,
            configuration,
            object : CompressionProgressListener {
                override fun onProgressChanged(index: Int, progress: ProgressInfo) {
                    listener.onProgress(index, progress)
                }
            },
        )
    }

    private fun saveVideoFile(
        context: Context,
        filePath: String?,
        storageConfiguration: StorageConfiguration,
        videoName: String,
        shouldSave: Boolean
    ): File? {
        return filePath?.let {
            val videoFile = File(filePath)
            storageConfiguration.createFileToSave(
                context,
                videoFile,
                validatedFileName(videoName),
                shouldSave
            )
        }
    }

    private fun getMediaPath(context: Context, uri: Uri): String {

        val resolver = context.contentResolver
        val projection = arrayOf(MediaStore.Video.Media.DATA)
        var cursor: Cursor? = null
        try {
            cursor = resolver.query(uri, projection, null, null, null)
            return if (cursor != null) {
                val columnIndex = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DATA)
                cursor.moveToFirst()
                cursor.getString(columnIndex)

            } else throw Exception()

        } catch (e: Exception) {
            resolver.let {
                val filePath = (context.cacheDir.path + File.separator
                        + System.currentTimeMillis() + ".mp4")
                val file = File(filePath)

                resolver.openInputStream(uri)?.use { inputStream ->
                    FileOutputStream(file).use { outputStream ->
                        val buf = ByteArray(4096)
                        var len: Int
                        while (inputStream.read(buf).also { len = it } > 0) outputStream.write(
                            buf,
                            0,
                            len
                        )
                    }
                }
                return file.absolutePath
            }
        } finally {
            cursor?.close()
        }
    }

    /**
     * Maps a low-level [Throwable] raised during compression onto a
     * [CompressionErrorType] so callers can react without parsing message text.
     */
    private fun classifyThrowable(throwable: Throwable): CompressionErrorType = when (throwable) {
        is SecurityException -> CompressionErrorType.PERMISSION
        is FileNotFoundException -> CompressionErrorType.NOT_FOUND
        else -> CompressionErrorType.UNKNOWN
    }

    private fun validatedFileName(name: String): String {
        if (!name.contains("mp4")) return "${name}.mp4"
        return name
    }
}
