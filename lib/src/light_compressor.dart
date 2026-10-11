import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';

/// Video quality presets to determine the target bitrate for compression.
enum VideoQuality {
  /// Very low quality. Results in the smallest file size but lowest detail.
  very_low,

  /// Low quality. Good for high compression with moderate detail loss.
  low,

  /// Medium quality. Balanced setting for size reduction and good video quality.
  medium,

  /// High quality. Retains high levels of detail with moderate file size reduction.
  high,

  /// Very high quality. Focuses on maximum quality preservation with minor file size reduction.
  very_high,
}

/// A lightweight, easy-to-use video compressor for Flutter.
///
/// This class provides methods to compress videos and track their progress.
class LightCompressor {
  /// Returns the singleton instance of [LightCompressor].
  factory LightCompressor() => _instance;

  LightCompressor._internal();

  static final LightCompressor _instance = LightCompressor._internal();

  static const MethodChannel _channel = MethodChannel('light_compressor');

  /// A stream to listen to video compression progress
  static const EventChannel _progressStream = EventChannel(
    'compression/stream',
  );

  /// A stream that carries per-video updates while a batch is compressing.
  static const EventChannel _batchStream = EventChannel(
    'compression/batch-stream',
  );

  Stream<dynamic>? _progressEvents;
  Stream<double>? _onProgressUpdated;
  Stream<CompressionProgress>? _onProgressDetail;
  Stream<BatchEvent>? _onBatchUpdate;

  /// The shared raw `compression/stream` broadcast, mapped by both
  /// [onProgressUpdated] and [onProgressDetail] (one native subscription).
  Stream<dynamic> get _rawProgress =>
      _progressEvents ??= _progressStream.receiveBroadcastStream();

  /// A broadcast stream that emits the current compression progress.
  ///
  /// The emitted values range from `0.0` to `100.0`. For estimated time
  /// remaining and bytes processed, use [onProgressDetail] instead.
  Stream<double> get onProgressUpdated {
    _onProgressUpdated ??= _rawProgress.map<double>(
      (dynamic event) => CompressionProgress.fromEvent(event).percent,
    );
    return _onProgressUpdated!;
  }

  /// A broadcast stream of rich single-video progress samples.
  ///
  /// Each [CompressionProgress] carries the percentage plus, when the platform
  /// reports them, the estimated time remaining (`etaMs`), elapsed time
  /// (`elapsedMs`) and encoded output bytes so far (`bytesProcessed`). For just
  /// the percentage, [onProgressUpdated] is simpler. Batch progress (including
  /// the same fields) arrives via [onBatchUpdate].
  Stream<CompressionProgress> get onProgressDetail {
    _onProgressDetail ??= _rawProgress.map<CompressionProgress>(
      CompressionProgress.fromEvent,
    );
    return _onProgressDetail!;
  }

  /// A broadcast stream of [BatchEvent]s emitted during [compressVideos].
  ///
  /// Emits [BatchProgress] as each video advances and [BatchItemCompleted] the
  /// moment a video finishes (success, failure or cancellation). Subscribe to
  /// this to drive a per-item UI; the final ordered results are also returned
  /// by [compressVideos].
  Stream<BatchEvent> get onBatchUpdate {
    _onBatchUpdate ??= _batchStream.receiveBroadcastStream().map<BatchEvent>((
      dynamic event,
    ) {
      final Map<String, dynamic> map = Map<String, dynamic>.from(
        event as Map<dynamic, dynamic>,
      );
      final int index = (map['index'] as num?)?.toInt() ?? 0;
      if (map['type'] == 'progress') {
        final int? eta = (map['etaMs'] as num?)?.toInt();
        return BatchProgress(
          index: index,
          percent: ((map['percent'] as num?)?.toDouble() ?? 0.0)
              .clamp(0.0, 100.0)
              .toDouble(),
          overallPercent: ((map['overallPercent'] as num?)?.toDouble() ?? 0.0)
              .clamp(0.0, 100.0)
              .toDouble(),
          bytesProcessed: (map['bytesProcessed'] as num?)?.toInt(),
          etaMs: (eta == null || eta < 0) ? null : eta,
          elapsedMs: (map['elapsedMs'] as num?)?.toInt(),
        );
      }
      return BatchItemCompleted(index: index, result: _resultFromMap(map));
    });
    return _onBatchUpdate!;
  }

  /// Compresses a video file at the given [path] using the specified options.
  ///
  /// The video is saved into either app-specific or shared storage depending on
  /// the configurations provided in [android] and [ios].
  ///
  /// Required Parameters:
  /// * [path] — The absolute file path of the source video to be compressed.
  /// * [videoQuality] — The target quality preset.
  /// * [android] — Android-specific configuration (e.g., storage type).
  /// * [ios] — iOS/macOS-specific configuration (e.g., gallery saving).
  /// * [video] — Specifications for the output video (e.g., name, resolution).
  ///
  /// Optional Parameters:
  /// * [disableAudio] — If set to `true`, the audio track will be stripped, producing a silent video. Defaults to `false`.
  /// * [isMinBitrateCheckEnabled] — If `true`, the compressor checks if the source video's bitrate is above a minimum threshold (2 Mbps) before starting. If it's below the threshold, compression is skipped to prevent quality degradation. Defaults to `true`.
  /// * [videoFormat] — The output codec. Defaults to [VideoFormat.h264].
  ///   Requesting [VideoFormat.h265] (HEVC) yields smaller files but requires
  ///   hardware support; on devices without it the compressor automatically
  ///   falls back to H.264. The format actually used is reported by
  ///   [OnSuccess.usedFormat].
  /// * [background] — When provided, keeps the compression running while the
  ///   app is backgrounded or the screen is off. Behaviour and guarantees vary
  ///   per platform; see [BackgroundConfig]. Defaults to `null` (the OS may
  ///   pause/terminate the compression once the app leaves the foreground).
  /// * [audio] — When provided, re-encodes the audio track as AAC with the
  ///   given bitrate/sample-rate; see [AudioConfig]. Ignored when [disableAudio]
  ///   is `true`. Defaults to `null` (the source audio is copied through).
  /// * [edit] — Optional native edits applied during compression: trim to a
  ///   time range and/or rotate by a quarter-turn; see [VideoEdit]. Defaults to
  ///   `null` (no edits).
  /// * [debugLogging] — When `true`, the native side emits structured debug log
  ///   lines for this compression (the resolved encode plan and the outcome),
  ///   with file paths reduced to their base names. Off by default. Intended for
  ///   diagnosing a single run, not for production.
  ///
  /// Returns a [Result] which can be:
  /// * [OnSuccess] containing the output destination file path and statistics.
  /// * [OnFailure] containing an error message.
  /// * [OnCancelled] indicating that the compression was manually cancelled.
  ///
  /// Throws a [LightCompressorException] when the native side reports a
  /// recognizable error:
  /// * [PermissionDeniedException] — missing read/write permission.
  /// * [UnsupportedVideoException] — unsupported format/codec or missing track.
  /// * [VideoNotFoundException] — the source video could not be found.
  Future<Result> compressVideo({
    required String path,
    required VideoQuality videoQuality,
    required AndroidConfig android,
    required IOSConfig ios,
    required Video video,
    bool? disableAudio = false,
    bool isMinBitrateCheckEnabled = true,
    VideoFormat videoFormat = VideoFormat.h264,
    BackgroundConfig? background,
    AudioConfig? audio,
    VideoEdit? edit,
    bool debugLogging = false,
  }) async {
    final Map<String, dynamic> response = jsonDecode(
      await _channel
          .invokeMethod<dynamic>('startCompression', <String, dynamic>{
        'path': path,
        'videoQuality': videoQuality.toString().split('.').last,
        'isSharedStorage': android.isSharedStorage,
        'saveAt': android.saveAt.name,
        'disableAudio': disableAudio,
        'audioBitrate': audio?.bitrate,
        'audioSampleRate': audio?.sampleRate,
        'keepOriginalResolution': video.keepOriginalResolution,
        'isMinBitrateCheckEnabled': isMinBitrateCheckEnabled,
        'videoBitrateInMbps': video.videoBitrateInMbps,
        'targetSizeBytes': video.targetSizeMb != null
            ? video.targetSizeMb! * 1000 * 1000
            : null,
        'twoPass': video.twoPass,
        'videoHeight': video.videoHeight,
        'videoWidth': video.videoWidth,
        'videoFps': video.videoFps,
        'videoName': video.videoName,
        'saveInGallery': ios.saveInGallery,
        'videoFormat': videoFormat.name,
        'background': background?.toMap(),
        'edit': edit?.toMap(),
        'debugLogging': debugLogging,
      }),
    );

    if (response['onSuccess'] != null) {
      final String destinationPath = response['onSuccess'] as String;
      if (destinationPath.isEmpty) {
        return const OnFailure(
          'Compression reported success but returned no output path.',
        );
      }

      final double duration = (response['duration'] as num?)?.toDouble() ?? 0.0;

      // Prefer the sizes reported by the native side. The output file may live
      // in scoped/shared storage (e.g. MediaStore on Android) whose path is not
      // directly readable via `File`, so re-reading it in Dart is unreliable.
      int originalSize = (response['originalSize'] as num?)?.toInt() ?? 0;
      int compressedSize = (response['compressedSize'] as num?)?.toInt() ?? 0;

      // Fallback to reading from disk when the native side did not report sizes.
      if (originalSize <= 0) {
        originalSize = _fileSizeOrZero(path);
      }
      if (compressedSize <= 0) {
        compressedSize = _fileSizeOrZero(destinationPath);
      }

      final double ratio = originalSize > 0
          ? ((1 - compressedSize / originalSize) * 100).clamp(0.0, 100.0)
          : 0.0;

      return OnSuccess(
        destinationPath: destinationPath,
        originalSize: originalSize,
        compressedSize: compressedSize,
        duration: duration,
        ratio: ratio,
        usedFormat: _videoFormatFromWire(response['usedFormat'] as String?),
        targetSizeMet: (response['targetSizeMet'] as bool?) ?? true,
        passesUsed: (response['passesUsed'] as num?)?.toInt() ?? 1,
      );
    } else if (response['onFailure'] != null) {
      final String failureMessage = response['onFailure'] as String;
      final String? failureType = response['failureType'] as String?;
      final LightCompressorException? exception = _exceptionFor(
        failureType,
        failureMessage,
      );
      if (exception != null) {
        throw exception;
      }
      return OnFailure(
        failureMessage,
        failureType: _failureTypeFromWire(failureType),
      );
    } else if (response['onCancelled'] != null) {
      return OnCancelled(isCancelled: response['onCancelled'] == true);
    } else {
      return const OnFailure('Something went wrong');
    }
  }

  /// Compresses multiple videos with a single shared set of options.
  ///
  /// [paths] are the source video paths and [videoNames] the matching output
  /// file names; the two lists must have the same length. Every video shares
  /// the same [videoQuality], resolution and bitrate settings.
  ///
  /// Returns the results in the same order as [paths]; each entry is an
  /// [OnSuccess], [OnFailure] or [OnCancelled]. Every video is attempted: a
  /// single video failing does not throw and does not stop the others — its
  /// slot in the returned list becomes an [OnFailure].
  ///
  /// Subscribe to [onBatchUpdate] for per-video progress and completion events
  /// as the batch runs.
  ///
  /// [videoFormat] selects the output codec for every video (defaults to
  /// [VideoFormat.h264]); see [compressVideo] for the H.265 fallback behaviour.
  ///
  /// When [background] is provided the whole batch keeps running while the app
  /// is backgrounded or the screen is off; see [BackgroundConfig] for the
  /// per-platform behaviour and caveats.
  ///
  /// [twoPass] enables two-pass encoding to land closer to [targetSizeMb] (it is
  /// ignored without a target). See `Video.twoPass` for the trade-offs; the
  /// number of passes run per video is reported by `OnSuccess.passesUsed`.
  ///
  /// [edit] applies the same native trim/rotate edits to every video; see
  /// [VideoEdit].
  ///
  /// [maxConcurrent] caps how many videos transcode at the same time. Leaving it
  /// `null` keeps each platform's default (Android compresses up to 2 at once;
  /// Apple starts them all). Setting it (must be `>= 1`) is honoured on every
  /// platform — use `1` for strictly sequential compression, or a higher value
  /// to trade memory/heat for throughput. Has no effect on a single video.
  ///
  /// [debugLogging] turns on native structured debug logging for every video in
  /// the batch (paths reduced to base names); see [compressVideo]. Off by
  /// default.
  Future<List<Result>> compressVideos({
    required List<String> paths,
    required List<String> videoNames,
    required VideoQuality videoQuality,
    required AndroidConfig android,
    required IOSConfig ios,
    bool keepOriginalResolution = false,
    int? videoWidth,
    int? videoHeight,
    num? videoBitrateInMbps,
    int? targetSizeMb,
    int? videoFps,
    bool twoPass = false,
    bool disableAudio = false,
    bool isMinBitrateCheckEnabled = true,
    VideoFormat videoFormat = VideoFormat.h264,
    BackgroundConfig? background,
    AudioConfig? audio,
    VideoEdit? edit,
    int? maxConcurrent,
    bool debugLogging = false,
  }) async {
    assert(
      paths.length == videoNames.length,
      'paths and videoNames must have the same length',
    );
    assert(
      targetSizeMb == null || videoBitrateInMbps == null,
      'targetSizeMb and videoBitrateInMbps are mutually exclusive',
    );
    assert(
      targetSizeMb == null || targetSizeMb > 0,
      'targetSizeMb must be greater than 0',
    );
    assert(videoFps == null || videoFps > 0, 'videoFps must be greater than 0');
    assert(
      maxConcurrent == null || maxConcurrent >= 1,
      'maxConcurrent must be greater than or equal to 1',
    );
    if (paths.isEmpty) {
      return <Result>[];
    }

    final List<dynamic>? response = await _channel
        .invokeListMethod<dynamic>('startBatchCompression', <String, dynamic>{
      'paths': paths,
      'videoNames': videoNames,
      'videoQuality': videoQuality.toString().split('.').last,
      'isSharedStorage': android.isSharedStorage,
      'saveAt': android.saveAt.name,
      'saveInGallery': ios.saveInGallery,
      'keepOriginalResolution': keepOriginalResolution,
      'videoWidth': videoWidth,
      'videoHeight': videoHeight,
      'videoBitrateInMbps': videoBitrateInMbps,
      'targetSizeBytes':
          targetSizeMb != null ? targetSizeMb * 1000 * 1000 : null,
      'twoPass': twoPass,
      'videoFps': videoFps,
      'disableAudio': disableAudio,
      'audioBitrate': audio?.bitrate,
      'audioSampleRate': audio?.sampleRate,
      'isMinBitrateCheckEnabled': isMinBitrateCheckEnabled,
      'videoFormat': videoFormat.name,
      'background': background?.toMap(),
      'edit': edit?.toMap(),
      'maxConcurrent': maxConcurrent,
      'debugLogging': debugLogging,
    });

    if (response == null) {
      return <Result>[];
    }
    return response
        .map(
          (dynamic e) => _resultFromMap(
            Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
          ),
        )
        .toList();
  }

  /// Builds a [Result] from a native result map. Shared by the [compressVideos]
  /// return value and the [BatchItemCompleted] events on [onBatchUpdate].
  Result _resultFromMap(Map<String, dynamic> map) {
    if (map['onSuccess'] != null) {
      final String destinationPath = map['onSuccess'] as String;
      final double duration = (map['duration'] as num?)?.toDouble() ?? 0.0;
      final int originalSize = (map['originalSize'] as num?)?.toInt() ?? 0;
      final int compressedSize = (map['compressedSize'] as num?)?.toInt() ?? 0;
      final double ratio = originalSize > 0
          ? ((1 - compressedSize / originalSize) * 100).clamp(0.0, 100.0)
          : 0.0;
      return OnSuccess(
        destinationPath: destinationPath,
        originalSize: originalSize,
        compressedSize: compressedSize,
        duration: duration,
        ratio: ratio,
        usedFormat: _videoFormatFromWire(map['usedFormat'] as String?),
        targetSizeMet: (map['targetSizeMet'] as bool?) ?? true,
        passesUsed: (map['passesUsed'] as num?)?.toInt() ?? 1,
      );
    } else if (map['onFailure'] != null) {
      return OnFailure(
        map['onFailure'] as String,
        failureType: _failureTypeFromWire(map['failureType'] as String?),
      );
    } else if (map['onCancelled'] != null) {
      return OnCancelled(isCancelled: map['onCancelled'] == true);
    }
    return const OnFailure('Something went wrong');
  }

  /// Maps the native `usedFormat` wire value (`"h264"` / `"h265"`) onto a
  /// [VideoFormat]. Defaults to [VideoFormat.h264] when absent (older native
  /// builds or platforms that do not report it).
  VideoFormat _videoFormatFromWire(String? wire) =>
      wire == 'h265' ? VideoFormat.h265 : VideoFormat.h264;

  /// Maps the native `failureType` wire value onto a [CompressionFailureType];
  /// defaults to [CompressionFailureType.unknown] for absent/unrecognized codes.
  CompressionFailureType _failureTypeFromWire(String? wire) {
    switch (wire) {
      case 'permission':
        return CompressionFailureType.permission;
      case 'unsupported':
        return CompressionFailureType.unsupported;
      case 'notFound':
        return CompressionFailureType.notFound;
      default:
        return CompressionFailureType.unknown;
    }
  }

  /// Maps a native failure to a typed exception.
  ///
  /// Prefers the structured [failureType] code reported by the native side.
  /// Falls back to message heuristics for untyped OS-level errors (whose text
  /// the package does not control). Returns `null` when the failure cannot be
  /// classified, in which case an [OnFailure] is returned instead of throwing.
  LightCompressorException? _exceptionFor(String? failureType, String message) {
    switch (failureType) {
      case 'permission':
        return PermissionDeniedException(message);
      case 'unsupported':
        return UnsupportedVideoException(message);
      case 'notFound':
        return VideoNotFoundException(message);
    }

    final String lower = message.toLowerCase();
    if (lower.contains('permission') || lower.contains('denied')) {
      return PermissionDeniedException(message);
    }
    if (lower.contains('unsupported') ||
        lower.contains('codec') ||
        lower.contains('format') ||
        lower.contains('track')) {
      return UnsupportedVideoException(message);
    }
    if (lower.contains('not found') ||
        lower.contains('no such file') ||
        lower.contains('does not exist')) {
      return VideoNotFoundException(message);
    }
    return null;
  }

  /// Returns the size of the file at [filePath] in bytes, or `0` if it cannot
  /// be read (e.g. the path points to scoped storage or does not exist).
  int _fileSizeOrZero(String filePath) {
    try {
      final File file = File(filePath);
      return file.existsSync() ? file.lengthSync() : 0;
    } on Exception catch (_) {
      return 0;
    }
  }

  /// Reads metadata (dimensions, duration, bitrate, rotation, etc.) from the
  /// video located at [path].
  ///
  /// Throws a [VideoNotFoundException] if the file does not exist,
  /// a [PermissionDeniedException] if it cannot be accessed, or a
  /// [MediaInfoException] if the metadata could not be read.
  Future<MediaInfo> getMediaInfo(String path) async {
    try {
      final Map<dynamic, dynamic>? result = await _channel
          .invokeMapMethod<dynamic, dynamic>('getMediaInfo', <String, dynamic>{
        'path': path,
      });
      if (result == null) {
        throw const MediaInfoException();
      }
      return MediaInfo.fromMap(Map<String, dynamic>.from(result));
    } on PlatformException catch (e) {
      throw _mapPlatformException(
        e,
        MediaInfoException(e.message ?? _defaultMediaInfoMessage),
      );
    }
  }

  /// Generates a JPEG thumbnail from the video at [path] and returns the
  /// absolute path of the generated image file.
  ///
  /// * [positionInMs] — the timecode (in milliseconds) of the frame to grab.
  ///   Clamped to the video duration by the native side. Defaults to `0`.
  /// * [quality] — JPEG quality from `0` (smallest) to `100` (best).
  ///   Defaults to `50`.
  ///
  /// The image is written to a temporary directory; use [clearCache] to remove
  /// generated files when they are no longer needed.
  ///
  /// Throws a [VideoNotFoundException] if the file does not exist,
  /// a [PermissionDeniedException] if it cannot be accessed, or a
  /// [ThumbnailException] if the frame could not be extracted.
  Future<String> getVideoThumbnail(
    String path, {
    int positionInMs = 0,
    int quality = 50,
  }) async {
    try {
      final String? thumbnailPath = await _channel
          .invokeMethod<String>('getVideoThumbnail', <String, dynamic>{
        'path': path,
        'positionInMs': positionInMs < 0 ? 0 : positionInMs,
        'quality': quality.clamp(0, 100),
      });
      if (thumbnailPath == null || thumbnailPath.isEmpty) {
        throw const ThumbnailException();
      }
      return thumbnailPath;
    } on PlatformException catch (e) {
      throw _mapPlatformException(
        e,
        ThumbnailException(e.message ?? _defaultThumbnailMessage),
      );
    }
  }

  /// Generates several thumbnails from the video at [path] in a single native
  /// round-trip, returning their file paths **in the same order** as [requests].
  ///
  /// More efficient than calling [getVideoThumbnail] repeatedly: the native side
  /// opens the source once and extracts every requested frame from it.
  ///
  /// Each image is written to a temporary directory; use [clearCache] to remove
  /// generated files when they are no longer needed.
  ///
  /// Throws a [VideoNotFoundException] if the file does not exist,
  /// a [PermissionDeniedException] if it cannot be accessed, or a
  /// [ThumbnailException] if no frames could be extracted.
  Future<List<String>> getVideoThumbnails(
    String path,
    List<ThumbnailRequest> requests,
  ) async {
    try {
      final List<String>? paths = await _channel
          .invokeListMethod<String>('getVideoThumbnails', <String, dynamic>{
        'path': path,
        'requests': requests
            .map((ThumbnailRequest request) => request.toMap())
            .toList(),
      });
      if (paths == null) {
        throw const ThumbnailException();
      }
      return paths;
    } on PlatformException catch (e) {
      throw _mapPlatformException(
        e,
        ThumbnailException(e.message ?? _defaultThumbnailMessage),
      );
    }
  }

  /// Estimates the result of compressing the video at [path] **without**
  /// transcoding it, using the same bitrate and resize math the compressor
  /// uses. The figures are approximate (typically within ~30% for single-pass).
  ///
  /// The parameters mirror the ones on [compressVideo] that affect the output
  /// size: [videoQuality], [videoFormat], [keepOriginalResolution], a custom
  /// [videoWidth]/[videoHeight], a [videoBitrateInMbps] override, and
  /// [disableAudio].
  ///
  /// Throws a [VideoNotFoundException] if the file does not exist,
  /// an [UnsupportedVideoException] if it cannot be read, or an
  /// [EstimateException] if the estimate could not be computed.
  Future<CompressionEstimate> getCompressionEstimate(
    String path, {
    required VideoQuality videoQuality,
    VideoFormat videoFormat = VideoFormat.h264,
    bool keepOriginalResolution = false,
    int? videoWidth,
    int? videoHeight,
    num? videoBitrateInMbps,
    bool disableAudio = false,
  }) async {
    try {
      final Map<dynamic, dynamic>? result =
          await _channel.invokeMapMethod<dynamic, dynamic>(
        'getCompressionEstimate',
        <String, dynamic>{
          'path': path,
          'videoQuality': videoQuality.toString().split('.').last,
          'videoFormat': videoFormat.name,
          'keepOriginalResolution': keepOriginalResolution,
          'videoWidth': videoWidth,
          'videoHeight': videoHeight,
          'videoBitrateInMbps': videoBitrateInMbps,
          'disableAudio': disableAudio,
        },
      );
      if (result == null) {
        throw const EstimateException();
      }
      return CompressionEstimate.fromMap(Map<String, dynamic>.from(result));
    } on PlatformException catch (e) {
      throw _mapPlatformException(
        e,
        EstimateException(e.message ?? _defaultEstimateMessage),
      );
    }
  }

  /// Maps a native [PlatformException] code onto a typed exception, falling
  /// back to [fallback] for codes that are not specifically recognized.
  LightCompressorException _mapPlatformException(
    PlatformException e,
    LightCompressorException fallback,
  ) {
    switch (e.code) {
      case 'PERMISSION_DENIED':
        return PermissionDeniedException(
          e.message ?? _defaultPermissionMessage,
        );
      case 'VIDEO_NOT_FOUND':
        return VideoNotFoundException(e.message ?? _defaultNotFoundMessage);
      case 'UNSUPPORTED_VIDEO':
        return UnsupportedVideoException(
          e.message ?? _defaultUnsupportedMessage,
        );
      default:
        return fallback;
    }
  }

  static const String _defaultMediaInfoMessage =
      'Failed to read media information from the video.';
  static const String _defaultEstimateMessage =
      'Failed to estimate the compression result for the video.';
  static const String _defaultThumbnailMessage =
      'Failed to generate a thumbnail from the video.';
  static const String _defaultPermissionMessage =
      'Permission denied to access the video file or storage.';
  static const String _defaultNotFoundMessage =
      'The video file was not found at the specified path.';
  static const String _defaultUnsupportedMessage =
      'The provided video format or codec is unsupported.';

  /// Clears temporary `.mp4` files created during compression.
  ///
  /// Platform behavior differs:
  /// * **Android** — deletes `.mp4` files from the app cache directory
  ///   (temporary source copies). Compressed outputs saved to shared storage or
  ///   app-specific storage are **not** affected.
  /// * **iOS / macOS** — deletes all `.mp4` files in the temporary directory.
  ///   Compressed videos are written there, so any output that has not been
  ///   moved or saved elsewhere (e.g. via `saveInGallery`) will be removed.
  ///   Call this only after you have copied/consumed the compressed file.
  Future<void> clearCache() async {
    await _channel.invokeMethod<void>('clearCache');
  }

  /// Requests cancellation of the active video compression.
  ///
  /// Cancellation is best-effort: the request is forwarded to the platform and
  /// the returned [Future] completes once it has been delivered. The pending
  /// [compressVideo] / [compressVideos] call usually then resolves to an
  /// [OnCancelled] result — but if the compression happens to finish first it
  /// may still resolve to [OnSuccess] or [OnFailure].
  Future<void> cancelCompression() =>
      _channel.invokeMethod<void>('cancelCompression');

  /// Whether a compression (single or batch) is currently running.
  ///
  /// Useful for gating UI (e.g. disabling a "compress" button) without tracking
  /// the in-flight [compressVideo] / [compressVideos] future yourself.
  Future<bool> isCompressing() async {
    final bool? running = await _channel.invokeMethod<bool>('isCompressing');
    return running ?? false;
  }
}
