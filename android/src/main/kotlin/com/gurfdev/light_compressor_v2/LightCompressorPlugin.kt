package com.gurfdev.light_compressor_v2

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import android.graphics.Bitmap
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import java.io.FileOutputStream
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.CompressionErrorType
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.CompressionListener
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.ProgressInfo
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.VideoCompressor
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.VideoFormat
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.VideoQuality
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.config.*
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils.CompressorUtils
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils.roundDimension
import com.gurfdev.light_compressor_v2.lightcompressorlibrary.video.FrameGrabber
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File
import kotlin.math.roundToInt

/** Flutter plugin that bridges the LightCompressor Android library to Dart. */
class LightCompressorPlugin : FlutterPlugin, MethodCallHandler,
    EventChannel.StreamHandler, ActivityAware {

    companion object {
        const val CHANNEL = "light_compressor"
        const val STREAM  = "compression/stream"
        const val BATCH_STREAM = "compression/batch-stream"
    }

    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var batchEventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private var batchEventSink: EventChannel.EventSink? = null
    private val gson = Gson()
    private lateinit var applicationContext: Context
    private lateinit var activity: Activity

    // MARK: - FlutterPlugin

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, STREAM)
        eventChannel.setStreamHandler(this)

        batchEventChannel = EventChannel(binding.binaryMessenger, BATCH_STREAM)
        batchEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                batchEventSink = events
            }

            override fun onCancel(arguments: Any?) {
                batchEventSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        batchEventChannel.setStreamHandler(null)
    }

    // MARK: - MethodCallHandler

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "startCompression" -> handleStartCompression(call, result)
            "startBatchCompression" -> handleStartBatchCompression(call, result)
            "cancelCompression" -> {
                VideoCompressor.cancel()
                // Always reply so the Dart-side Future completes instead of
                // hanging; the actual outcome arrives as onCancelled on the
                // pending compression call.
                result.success(null)
            }
            "clearCache" -> handleClearCache(result)
            "getMediaInfo" -> handleGetMediaInfo(call, result)
            "getVideoThumbnail" -> handleGetVideoThumbnail(call, result)
            "getVideoThumbnails" -> handleGetVideoThumbnails(call, result)
            "getCompressionEstimate" -> handleGetCompressionEstimate(call, result)
            "isCompressing" -> result.success(VideoCompressor.isCompressing())
            else -> result.notImplemented()
        }
    }

    private fun handleStartCompression(call: MethodCall, result: Result) {
        val path: String                    = call.argument("path")!!
        val videoName: String               = call.argument("videoName")!!
        val isMinBitrateCheckEnabled: Boolean = call.argument("isMinBitrateCheckEnabled")!!
        val isSharedStorage: Boolean        = call.argument("isSharedStorage")!!
        val disableAudio: Boolean           = call.argument("disableAudio")!!
        val keepOriginalResolution: Boolean = call.argument("keepOriginalResolution")!!
        val videoBitrateInMbps: Number?     = call.argument("videoBitrateInMbps")
        val targetSizeBytes: Long?          = call.argument<Number>("targetSizeBytes")?.toLong()
        val twoPass: Boolean                = call.argument("twoPass") ?: false
        val videoFps: Int?                  = call.argument("videoFps")
        val audioBitrate: Int?              = call.argument("audioBitrate")
        val audioSampleRate: Int?           = call.argument("audioSampleRate")
        val videoHeight: Int?               = call.argument("videoHeight")
        val videoWidth: Int?                = call.argument("videoWidth")
        val saveAt: String                  = call.argument("saveAt")!!

        val quality: VideoQuality = when (call.argument<String>("videoQuality")!!) {
            "very_low"  -> VideoQuality.VERY_LOW
            "low"       -> VideoQuality.LOW
            "medium"    -> VideoQuality.MEDIUM
            "high"      -> VideoQuality.HIGH
            "very_high" -> VideoQuality.VERY_HIGH
            else        -> VideoQuality.MEDIUM
        }

        // Build VideoResizer based on parameters
        val resizer: VideoResizer? = when {
            keepOriginalResolution              -> null
            videoWidth != null && videoHeight != null ->
                VideoResizer.matchSize(videoWidth.toDouble(), videoHeight.toDouble(), true)
            else                               -> VideoResizer.auto
        }

        // Build StorageConfiguration
        val storageConfiguration: StorageConfiguration = if (isSharedStorage) {
            SharedStorageConfiguration(
                saveAt = when (saveAt) {
                    "Downloads" -> SaveLocation.downloads
                    "Pictures"  -> SaveLocation.pictures
                    else        -> SaveLocation.movies
                }
            )
        } else {
            AppSpecificStorageConfiguration()
        }

        val background = parseBackground(call)
        if (background != null) maybeRequestNotificationPermission()
        val videoFormat = parseVideoFormat(call)
        val edit = parseEdit(call)
        val debugLogging: Boolean = call.argument("debugLogging") ?: false

        if (isSharedStorage) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                requestPermissionAndCompress33(
                    path, result, quality, isMinBitrateCheckEnabled,
                    videoBitrateInMbps, targetSizeBytes, twoPass, videoFps, audioBitrate, audioSampleRate, disableAudio, resizer,
                    storageConfiguration, videoName, background, videoFormat, edit, debugLogging
                )
            } else {
                requestPermissionAndCompressLegacy(
                    path, result, quality, isMinBitrateCheckEnabled,
                    videoBitrateInMbps, targetSizeBytes, twoPass, videoFps, audioBitrate, audioSampleRate, disableAudio, resizer,
                    storageConfiguration, videoName, background, videoFormat, edit, debugLogging
                )
            }
        } else {
            compressVideo(
                path, result, quality, isMinBitrateCheckEnabled,
                videoBitrateInMbps, targetSizeBytes, twoPass, videoFps, audioBitrate, audioSampleRate, disableAudio, resizer,
                storageConfiguration, videoName, background, videoFormat, edit, debugLogging
            )
        }
    }

    // MARK: - Compression

    private fun compressVideo(
        path: String,
        result: Result,
        quality: VideoQuality,
        isMinBitrateCheckEnabled: Boolean,
        videoBitrateInMbps: Number?,
        targetSizeBytes: Long?,
        twoPass: Boolean,
        videoFps: Int?,
        audioBitrate: Int?,
        audioSampleRate: Int?,
        disableAudio: Boolean,
        resizer: VideoResizer?,
        storageConfiguration: StorageConfiguration,
        videoName: String,
        background: BackgroundParams?,
        videoFormat: VideoFormat,
        edit: EditParams?,
        debugLogging: Boolean,
    ) {
        val sourcePath = path
        // A MethodChannel reply may be submitted only once. A cancelled run can
        // surface more than one terminal callback, so collapse them to a single
        // reply (mirrors the per-index de-dup used by batch compression) and
        // always reply on the main thread.
        val replied = java.util.concurrent.atomic.AtomicBoolean(false)
        fun replyOnce(payload: Map<String, Any?>) {
            if (replied.compareAndSet(false, true)) {
                if (background != null) CompressionForegroundService.stop(applicationContext)
                Handler(Looper.getMainLooper()).post { result.success(gson.toJson(payload)) }
            }
        }
        if (background != null) {
            CompressionForegroundService.start(
                applicationContext, background.title, videoName,
            )
        }
        VideoCompressor.start(
            context = applicationContext,
            uris = listOf(Uri.fromFile(File(path))),
            storageConfiguration = storageConfiguration,
            configureWith = Configuration(
                quality = quality,
                isMinBitrateCheckEnabled = isMinBitrateCheckEnabled,
                videoBitrateInMbps = videoBitrateInMbps,
                targetSizeBytes = targetSizeBytes,
                twoPass = twoPass,
                videoFps = videoFps,
                audioBitrate = audioBitrate,
                audioSampleRate = audioSampleRate,
                disableAudio = disableAudio,
                resizer = resizer,
                videoNames = listOf(videoName),
                videoFormat = videoFormat,
                trimStartMs = edit?.trimStartMs,
                trimEndMs = edit?.trimEndMs,
                rotationDegrees = edit?.rotationDegrees,
                brightness = edit?.brightness,
                contrast = edit?.contrast,
                saturation = edit?.saturation,
                debugLogging = debugLogging,
            ),
            listener = object : CompressionListener {
                override fun onStart(index: Int) {}

                override fun onProgress(index: Int, progress: ProgressInfo) {
                    Handler(Looper.getMainLooper()).post {
                        eventSink?.success(mapOf(
                            "percent" to progress.percent.toDouble(),
                            "bytesProcessed" to progress.bytesProcessed,
                            "etaMs" to progress.etaMs,
                            "elapsedMs" to progress.elapsedMs,
                        ))
                        if (background != null) {
                            CompressionForegroundService.updateProgress(
                                applicationContext, progress.percent.toInt(), videoName,
                            )
                        }
                    }
                }

                override fun onSuccess(index: Int, size: Long, path: String?, duration: Double, videoFormat: String, targetSizeMet: Boolean, passesUsed: Int) {
                    val originalSize = try {
                        File(sourcePath).length()
                    } catch (e: Exception) {
                        0L
                    }
                    replyOnce(mapOf(
                        "onSuccess" to (path ?: ""),
                        "index" to index.toString(),
                        "duration" to duration,
                        "originalSize" to originalSize,
                        "compressedSize" to size,
                        "usedFormat" to videoFormat,
                        "targetSizeMet" to targetSizeMet,
                        "passesUsed" to passesUsed
                    ))
                }

                override fun onFailure(index: Int, failureMessage: String, errorType: CompressionErrorType) {
                    replyOnce(mapOf(
                        "onFailure" to failureMessage,
                        "index" to index.toString(),
                        "failureType" to errorType.toWireValue()
                    ))
                }

                override fun onCancelled(index: Int) {
                    replyOnce(mapOf("onCancelled" to true))
                }
            }
        )
    }

    // MARK: - Batch compression

    private fun handleStartBatchCompression(call: MethodCall, result: Result) {
        val paths: List<String> = call.argument("paths") ?: emptyList()
        val videoNames: List<String> = call.argument("videoNames") ?: emptyList()
        if (paths.isEmpty() || paths.size != videoNames.size) {
            result.success(emptyList<Any?>())
            return
        }

        val isMinBitrateCheckEnabled: Boolean = call.argument("isMinBitrateCheckEnabled") ?: true
        val isSharedStorage: Boolean = call.argument("isSharedStorage") ?: true
        val disableAudio: Boolean = call.argument("disableAudio") ?: false
        val keepOriginalResolution: Boolean = call.argument("keepOriginalResolution") ?: false
        val videoBitrateInMbps: Number? = call.argument("videoBitrateInMbps")
        val targetSizeBytes: Long? = call.argument<Number>("targetSizeBytes")?.toLong()
        val twoPass: Boolean = call.argument("twoPass") ?: false
        val videoFps: Int? = call.argument("videoFps")
        val audioBitrate: Int? = call.argument("audioBitrate")
        val audioSampleRate: Int? = call.argument("audioSampleRate")
        val videoHeight: Int? = call.argument("videoHeight")
        val videoWidth: Int? = call.argument("videoWidth")
        val saveAt: String = call.argument("saveAt") ?: "Movies"

        val quality: VideoQuality = when (call.argument<String>("videoQuality")) {
            "very_low"  -> VideoQuality.VERY_LOW
            "low"       -> VideoQuality.LOW
            "medium"    -> VideoQuality.MEDIUM
            "high"      -> VideoQuality.HIGH
            "very_high" -> VideoQuality.VERY_HIGH
            else        -> VideoQuality.MEDIUM
        }

        val resizer: VideoResizer? = when {
            keepOriginalResolution -> null
            videoWidth != null && videoHeight != null ->
                VideoResizer.matchSize(videoWidth.toDouble(), videoHeight.toDouble(), true)
            else -> VideoResizer.auto
        }

        val storageConfiguration: StorageConfiguration = if (isSharedStorage) {
            SharedStorageConfiguration(
                saveAt = when (saveAt) {
                    "Downloads" -> SaveLocation.downloads
                    "Pictures"  -> SaveLocation.pictures
                    else        -> SaveLocation.movies
                }
            )
        } else {
            AppSpecificStorageConfiguration()
        }

        val background = parseBackground(call)
        if (background != null) maybeRequestNotificationPermission()

        val edit = parseEdit(call)
        val count = paths.size
        val results = arrayOfNulls<Map<String, Any?>>(count)
        val percents = FloatArray(count)
        var completed = 0
        val mainHandler = Handler(Looper.getMainLooper())

        // Records a video's outcome on the main thread, emits a per-item event,
        // and resolves the method result once every video has reported.
        fun record(index: Int, map: Map<String, Any?>) {
            mainHandler.post {
                if (index in 0 until count && results[index] == null) {
                    results[index] = map
                    completed += 1
                    val event = HashMap<String, Any?>(map)
                    event["type"] = "result"
                    event["index"] = index
                    batchEventSink?.success(event)
                    if (completed == count) {
                        if (background != null) CompressionForegroundService.stop(applicationContext)
                        result.success(results.map { it ?: mapOf("onFailure" to "Unknown error") })
                    }
                }
            }
        }

        if (background != null) {
            CompressionForegroundService.start(
                applicationContext, background.title, "0 / $count",
            )
        }

        VideoCompressor.start(
            context = applicationContext,
            uris = paths.map { Uri.fromFile(File(it)) },
            storageConfiguration = storageConfiguration,
            configureWith = Configuration(
                quality = quality,
                isMinBitrateCheckEnabled = isMinBitrateCheckEnabled,
                videoBitrateInMbps = videoBitrateInMbps,
                targetSizeBytes = targetSizeBytes,
                twoPass = twoPass,
                videoFps = videoFps,
                audioBitrate = audioBitrate,
                audioSampleRate = audioSampleRate,
                disableAudio = disableAudio,
                resizer = resizer,
                videoNames = videoNames,
                videoFormat = parseVideoFormat(call),
                trimStartMs = edit?.trimStartMs,
                trimEndMs = edit?.trimEndMs,
                rotationDegrees = edit?.rotationDegrees,
                brightness = edit?.brightness,
                contrast = edit?.contrast,
                saturation = edit?.saturation,
                maxConcurrent = call.argument("maxConcurrent"),
                debugLogging = call.argument("debugLogging") ?: false,
            ),
            listener = object : CompressionListener {
                override fun onStart(index: Int) {}

                override fun onProgress(index: Int, progress: ProgressInfo) {
                    mainHandler.post {
                        if (index in 0 until count) percents[index] = progress.percent
                        val overall = if (count > 0) percents.sum() / count else 0f
                        batchEventSink?.success(mapOf(
                            "type" to "progress",
                            "index" to index,
                            "percent" to progress.percent.toDouble(),
                            "overallPercent" to overall.toDouble(),
                            "bytesProcessed" to progress.bytesProcessed,
                            "etaMs" to progress.etaMs,
                            "elapsedMs" to progress.elapsedMs,
                        ))
                        if (background != null) {
                            // Videos compress in parallel, so there is no single
                            // "current" index — show a language-neutral
                            // done/total count instead.
                            CompressionForegroundService.updateProgress(
                                applicationContext, overall.toInt(), "$completed / $count",
                            )
                        }
                    }
                }

                override fun onSuccess(index: Int, size: Long, path: String?, duration: Double, videoFormat: String, targetSizeMet: Boolean, passesUsed: Int) {
                    val originalSize = try {
                        File(paths[index]).length()
                    } catch (e: Exception) {
                        0L
                    }
                    record(index, mapOf(
                        "onSuccess" to (path ?: ""),
                        "originalSize" to originalSize,
                        "compressedSize" to size,
                        "duration" to duration,
                        "usedFormat" to videoFormat,
                        "targetSizeMet" to targetSizeMet,
                        "passesUsed" to passesUsed
                    ))
                }

                override fun onFailure(index: Int, failureMessage: String, errorType: CompressionErrorType) {
                    record(index, mapOf(
                        "onFailure" to failureMessage,
                        "failureType" to errorType.toWireValue()
                    ))
                }

                override fun onCancelled(index: Int) {
                    record(index, mapOf("onCancelled" to true))
                }
            }
        )
    }

    // MARK: - Permissions

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun requestPermissionAndCompress33(
        path: String, result: Result, quality: VideoQuality,
        isMinBitrateCheckEnabled: Boolean, videoBitrateInMbps: Number?,
        targetSizeBytes: Long?, twoPass: Boolean, videoFps: Int?,
        audioBitrate: Int?, audioSampleRate: Int?,
        disableAudio: Boolean, resizer: VideoResizer?,
        storageConfiguration: StorageConfiguration, videoName: String,
        background: BackgroundParams?, videoFormat: VideoFormat, edit: EditParams?,
        debugLogging: Boolean
    ) {
        if (ContextCompat.checkSelfPermission(
                activity, Manifest.permission.READ_MEDIA_VIDEO
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            if (!ActivityCompat.shouldShowRequestPermissionRationale(
                    activity, Manifest.permission.READ_MEDIA_VIDEO
                )
            ) {
                ActivityCompat.requestPermissions(
                    activity,
                    arrayOf(Manifest.permission.READ_MEDIA_VIDEO),
                    2
                )
            }
        }
        compressVideo(
            path, result, quality, isMinBitrateCheckEnabled,
            videoBitrateInMbps, targetSizeBytes, twoPass, videoFps, audioBitrate, audioSampleRate, disableAudio, resizer, storageConfiguration, videoName, background, videoFormat, edit, debugLogging
        )
    }

    private fun requestPermissionAndCompressLegacy(
        path: String, result: Result, quality: VideoQuality,
        isMinBitrateCheckEnabled: Boolean, videoBitrateInMbps: Number?,
        targetSizeBytes: Long?, twoPass: Boolean, videoFps: Int?,
        audioBitrate: Int?, audioSampleRate: Int?,
        disableAudio: Boolean, resizer: VideoResizer?,
        storageConfiguration: StorageConfiguration, videoName: String,
        background: BackgroundParams?, videoFormat: VideoFormat, edit: EditParams?,
        debugLogging: Boolean
    ) {
        val permissions = arrayOf(
            Manifest.permission.READ_EXTERNAL_STORAGE,
            Manifest.permission.WRITE_EXTERNAL_STORAGE
        )
        if (!hasPermissions(applicationContext, permissions)) {
            ActivityCompat.requestPermissions(activity, permissions, 1)
        }
        compressVideo(
            path, result, quality, isMinBitrateCheckEnabled,
            videoBitrateInMbps, targetSizeBytes, twoPass, videoFps, audioBitrate, audioSampleRate, disableAudio, resizer, storageConfiguration, videoName, background, videoFormat, edit, debugLogging
        )
    }

    private fun hasPermissions(context: Context, permissions: Array<String>): Boolean =
        permissions.all {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }

    // MARK: - Background execution

    /** Notification content for the Android foreground service. */
    private data class BackgroundParams(
        val title: String,
    )

    /**
     * Parses the optional `background` map sent from Dart. Returns `null` when
     * background execution was not requested, in which case the compression
     * runs in-process exactly as before.
     */
    private fun parseBackground(call: MethodCall): BackgroundParams? {
        val map = call.argument<Map<String, Any?>>("background") ?: return null
        return BackgroundParams(
            title = (map["notificationTitle"] as? String) ?: "Compressing video",
        )
    }

    /** Optional native edits: a trim range + a quarter-turn rotation. */
    private data class EditParams(
        val trimStartMs: Long?,
        val trimEndMs: Long?,
        val rotationDegrees: Int?,
        val brightness: Double?,
        val contrast: Double?,
        val saturation: Double?,
    )

    /**
     * Parses the optional nested `edit` map sent from Dart. Returns `null` when
     * no editing was requested, in which case the video is compressed unchanged.
     */
    private fun parseEdit(call: MethodCall): EditParams? {
        val map = call.argument<Map<String, Any?>>("edit") ?: return null
        return EditParams(
            trimStartMs = (map["trimStartMs"] as? Number)?.toLong(),
            trimEndMs = (map["trimEndMs"] as? Number)?.toLong(),
            rotationDegrees = (map["rotationDegrees"] as? Number)?.toInt(),
            brightness = (map["brightness"] as? Number)?.toDouble(),
            contrast = (map["contrast"] as? Number)?.toDouble(),
            saturation = (map["saturation"] as? Number)?.toDouble(),
        )
    }

    /** Parses the optional `videoFormat` argument; defaults to H.264. */
    private fun parseVideoFormat(call: MethodCall): VideoFormat =
        when (call.argument<String>("videoFormat")) {
            "h265" -> VideoFormat.H265
            else -> VideoFormat.H264
        }

    /**
     * Requests the POST_NOTIFICATIONS runtime permission (Android 13+) so the
     * foreground-service notification can be shown. Best-effort and
     * non-blocking: compression proceeds regardless of the outcome — only the
     * notification is hidden if the user denies it.
     */
    private fun maybeRequestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ::activity.isInitialized &&
            ContextCompat.checkSelfPermission(
                activity, Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                activity, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 3,
            )
        }
    }

    // MARK: - EventChannel.StreamHandler

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // MARK: - ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {}

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {}

    // MARK: - Media info & thumbnails

    private fun handleGetMediaInfo(call: MethodCall, result: Result) {
        val path: String? = call.argument("path")
        if (path.isNullOrEmpty()) {
            result.error("VIDEO_NOT_FOUND", "No video path was provided.", null)
            return
        }
        Thread {
            val retriever = MediaMetadataRetriever()
            try {
                val file = File(path)
                if (!file.exists()) {
                    postError(result, "VIDEO_NOT_FOUND", "The video file was not found: $path")
                    return@Thread
                }
                retriever.setDataSource(file.absolutePath)
                val frameRate =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)
                            ?.toDoubleOrNull()
                    } else null

                var durationMs =
                    retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
                var bitrate =
                    retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull()

                // Fall back to the video track's format when the retriever does
                // not expose duration/bitrate (some containers omit them).
                if ((durationMs == null || durationMs <= 0L) || (bitrate == null || bitrate <= 0)) {
                    val (trackDurationUs, trackBitrate) = readTrackDurationAndBitrate(file.absolutePath)
                    if ((durationMs == null || durationMs <= 0L) && trackDurationUs != null && trackDurationUs > 0L) {
                        durationMs = trackDurationUs / 1000L
                    }
                    if ((bitrate == null || bitrate <= 0) && trackBitrate != null && trackBitrate > 0) {
                        bitrate = trackBitrate
                    }
                }

                val info = mapOf(
                    "width" to retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull(),
                    "height" to retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull(),
                    "durationMs" to durationMs,
                    "fileSize" to file.length(),
                    "bitrate" to bitrate,
                    "rotation" to retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull(),
                    "frameRate" to frameRate,
                    "mimeType" to retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE),
                    "isHdr" to readIsHdr(file.absolutePath),
                )
                postSuccess(result, info)
            } catch (e: Exception) {
                postError(result, "MEDIA_INFO_FAILED", e.message ?: "Failed to read media info.")
            } finally {
                try { retriever.release() } catch (ignored: Exception) {}
            }
        }.start()
    }

    private fun handleGetVideoThumbnail(call: MethodCall, result: Result) {
        val path: String? = call.argument("path")
        if (path.isNullOrEmpty()) {
            result.error("VIDEO_NOT_FOUND", "No video path was provided.", null)
            return
        }
        val positionInMs: Int = (call.argument<Int>("positionInMs") ?: 0).coerceAtLeast(0)
        val quality: Int = (call.argument<Int>("quality") ?: 50).coerceIn(0, 100)

        Thread {
            val retriever = MediaMetadataRetriever()
            try {
                val file = File(path)
                if (!file.exists()) {
                    postError(result, "VIDEO_NOT_FOUND", "The video file was not found: $path")
                    return@Thread
                }
                retriever.setDataSource(file.absolutePath)
                val bitmap: Bitmap? = frameAt(retriever, file.absolutePath, positionInMs * 1000L)
                if (bitmap == null) {
                    postError(result, "THUMBNAIL_FAILED", "Could not extract a frame at ${positionInMs}ms.")
                    return@Thread
                }
                val outFile = File(applicationContext.cacheDir, "thumb_${System.currentTimeMillis()}.jpg")
                FileOutputStream(outFile).use { out ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
                }
                bitmap.recycle()
                postSuccess(result, outFile.absolutePath)
            } catch (e: Exception) {
                postError(result, "THUMBNAIL_FAILED", e.message ?: "Failed to generate thumbnail.")
            } finally {
                try { retriever.release() } catch (ignored: Exception) {}
            }
        }.start()
    }

    // Extracts several frames from one source in a single call, reusing one
    // MediaMetadataRetriever. Returns the JPEG paths in request order.
    private fun handleGetVideoThumbnails(call: MethodCall, result: Result) {
        val path: String? = call.argument("path")
        if (path.isNullOrEmpty()) {
            result.error("VIDEO_NOT_FOUND", "No video path was provided.", null)
            return
        }
        val requests: List<Map<String, Any?>> = call.argument("requests") ?: emptyList()

        Thread {
            val retriever = MediaMetadataRetriever()
            try {
                val file = File(path)
                if (!file.exists()) {
                    postError(result, "VIDEO_NOT_FOUND", "The video file was not found: $path")
                    return@Thread
                }
                retriever.setDataSource(file.absolutePath)
                val paths = ArrayList<String>(requests.size)
                for ((i, req) in requests.withIndex()) {
                    val positionInMs =
                        ((req["positionInMs"] as? Number)?.toInt() ?: 0).coerceAtLeast(0)
                    val quality = ((req["quality"] as? Number)?.toInt() ?: 50).coerceIn(0, 100)
                    val bitmap: Bitmap? = frameAt(retriever, file.absolutePath, positionInMs * 1000L)
                    if (bitmap == null) {
                        postError(result, "THUMBNAIL_FAILED", "Could not extract a frame at ${positionInMs}ms.")
                        return@Thread
                    }
                    val outFile = File(applicationContext.cacheDir, "thumb_${System.currentTimeMillis()}_$i.jpg")
                    FileOutputStream(outFile).use { out ->
                        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
                    }
                    bitmap.recycle()
                    paths.add(outFile.absolutePath)
                }
                postSuccess(result, paths)
            } catch (e: Exception) {
                postError(result, "THUMBNAIL_FAILED", e.message ?: "Failed to generate thumbnails.")
            } finally {
                try { retriever.release() } catch (ignored: Exception) {}
            }
        }.start()
    }

    // Predicts the compressed output (size/bitrate/resolution) without running a
    // transcode, by applying the SAME bitrate + resize math the compressor uses.
    private fun handleGetCompressionEstimate(call: MethodCall, result: Result) {
        val path: String? = call.argument("path")
        if (path.isNullOrEmpty()) {
            result.error("VIDEO_NOT_FOUND", "No video path was provided.", null)
            return
        }
        val keepOriginalResolution: Boolean = call.argument("keepOriginalResolution") ?: false
        val videoWidth: Int? = call.argument("videoWidth")
        val videoHeight: Int? = call.argument("videoHeight")
        val videoBitrateInMbps: Number? = call.argument("videoBitrateInMbps")
        val disableAudio: Boolean = call.argument("disableAudio") ?: false
        val quality: VideoQuality = when (call.argument<String>("videoQuality")) {
            "very_low"  -> VideoQuality.VERY_LOW
            "low"       -> VideoQuality.LOW
            "medium"    -> VideoQuality.MEDIUM
            "high"      -> VideoQuality.HIGH
            "very_high" -> VideoQuality.VERY_HIGH
            else        -> VideoQuality.MEDIUM
        }

        Thread {
            val retriever = MediaMetadataRetriever()
            try {
                val file = File(path)
                if (!file.exists()) {
                    postError(result, "VIDEO_NOT_FOUND", "The video file was not found: $path")
                    return@Thread
                }
                retriever.setDataSource(file.absolutePath)

                val srcWidth =
                    retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toDoubleOrNull()
                val srcHeight =
                    retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toDoubleOrNull()
                if (srcWidth == null || srcHeight == null || srcWidth <= 0 || srcHeight <= 0) {
                    postError(result, "UNSUPPORTED_VIDEO", "The video has no readable video track.")
                    return@Thread
                }
                val rotation =
                    retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                val durationSec =
                    (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L) / 1000.0
                val sourceBitrate =
                    retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull() ?: 0
                val hasAudio =
                    retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"
                val originalSize = file.length()

                // Output resolution — mirror Compressor: resizer/custom/source, then
                // round to even/16, then swap on 90°/270°.
                val rawWidth: Double
                val rawHeight: Double
                when {
                    keepOriginalResolution -> { rawWidth = srcWidth; rawHeight = srcHeight }
                    videoWidth != null && videoHeight != null -> {
                        rawWidth = videoWidth.toDouble(); rawHeight = videoHeight.toDouble()
                    }
                    else -> {
                        val p = CompressorUtils.autoResizePercentage(srcWidth, srcHeight)
                        rawWidth = srcWidth * p; rawHeight = srcHeight * p
                    }
                }
                var outWidth = roundDimension(rawWidth)
                var outHeight = roundDimension(rawHeight)
                if (rotation == 90 || rotation == 270) {
                    val tmp = outWidth; outWidth = outHeight; outHeight = tmp
                }

                // Target video bitrate — the same value compression would request.
                val targetBitrate =
                    if (videoBitrateInMbps != null) (videoBitrateInMbps.toDouble() * 1_000_000).roundToInt()
                    else CompressorUtils.getBitrate(sourceBitrate, quality)

                val audioBitrate = if (disableAudio || !hasAudio) 0 else 128_000
                val estimatedSize =
                    ((targetBitrate + audioBitrate) / 8.0 * durationSec * 1.02).toLong()
                val ratio =
                    if (originalSize > 0)
                        ((1 - estimatedSize.toDouble() / originalSize) * 100).coerceIn(0.0, 100.0)
                    else 0.0

                postSuccess(result, mapOf(
                    "originalSizeBytes" to originalSize,
                    "estimatedSizeBytes" to estimatedSize,
                    "targetBitrate" to targetBitrate,
                    "outputWidth" to outWidth,
                    "outputHeight" to outHeight,
                    "estimatedRatio" to ratio
                ))
            } catch (e: Exception) {
                postError(result, "ESTIMATE_FAILED", e.message ?: "Failed to estimate compression result.")
            } finally {
                try { retriever.release() } catch (ignored: Exception) {}
            }
        }.start()
    }

    // Reads the video track's duration (microseconds) and bitrate (bps) from
    // the container, used as a fallback when MediaMetadataRetriever does not
    // expose them. Returns nulls when unavailable.
    /**
     * The sync frame at [positionUs], via the retriever — or, when it cannot
     * decode the track (a Dolby Vision recording on a device without a Dolby
     * Vision decoder), decoded directly by [FrameGrabber].
     */
    private fun frameAt(retriever: MediaMetadataRetriever, path: String, positionUs: Long): Bitmap? =
        try {
            retriever.getFrameAtTime(positionUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        } catch (e: Exception) {
            null
        } ?: FrameGrabber.frameAt(path, positionUs)

    /** Whether the video track is HDR (HLG / PQ, or Dolby Vision); null if unreadable. */
    private fun readIsHdr(path: String): Boolean? {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            val index = CompressorUtils.findTrack(extractor, isVideo = true)
            if (index < 0) null else CompressorUtils.isHdr(extractor.getTrackFormat(index))
        } catch (e: Exception) {
            null
        } finally {
            try { extractor.release() } catch (ignored: Exception) {}
        }
    }

    private fun readTrackDurationAndBitrate(path: String): Pair<Long?, Int?> {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            var durationUs: Long? = null
            var bitrate: Int? = null
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) {
                    if (format.containsKey(MediaFormat.KEY_DURATION)) {
                        durationUs = format.getLong(MediaFormat.KEY_DURATION)
                    }
                    if (format.containsKey(MediaFormat.KEY_BIT_RATE)) {
                        bitrate = format.getInteger(MediaFormat.KEY_BIT_RATE)
                    }
                    break
                }
            }
            Pair(durationUs, bitrate)
        } catch (e: Exception) {
            Pair(null, null)
        } finally {
            try { extractor.release() } catch (ignored: Exception) {}
        }
    }

    private fun postSuccess(result: Result, value: Any?) {
        Handler(Looper.getMainLooper()).post { result.success(value) }
    }

    private fun postError(result: Result, code: String, message: String) {
        Handler(Looper.getMainLooper()).post { result.error(code, message, null) }
    }

    private fun handleClearCache(result: Result) {
        try {
            val cacheDir = applicationContext.cacheDir
            if (cacheDir != null && cacheDir.isDirectory) {
                for (file in cacheDir.listFiles() ?: emptyArray()) {
                    // Compressed outputs (.mp4) and generated thumbnails (.jpg).
                    if (file.name.endsWith(".mp4") || file.name.endsWith(".jpg")) {
                        file.delete()
                    }
                }
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("CLEAR_CACHE_FAILED", e.message, null)
        }
    }
}
