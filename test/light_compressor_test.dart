import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LightCompressor', () {
    late LightCompressor compressor;
    const MethodChannel channel = MethodChannel('light_compressor');
    final List<MethodCall> log = <MethodCall>[];
    String mockedResponse = '';
    Object? mediaInfoResponse;
    Object? thumbnailResponse;
    Object? batchResponse;
    Object? estimateResponse;
    Object? thumbnailsResponse;
    bool? isCompressingResponse;
    PlatformException? platformError;

    setUp(() {
      compressor = LightCompressor();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        if (platformError != null) {
          throw platformError!;
        }
        switch (methodCall.method) {
          case 'getMediaInfo':
            return mediaInfoResponse;
          case 'getVideoThumbnail':
            return thumbnailResponse;
          case 'getVideoThumbnails':
            return thumbnailsResponse;
          case 'getCompressionEstimate':
            return estimateResponse;
          case 'isCompressing':
            return isCompressingResponse;
          case 'startBatchCompression':
            return batchResponse;
          default:
            return mockedResponse;
        }
      });
    });

    tearDown(() {
      log.clear();
      mediaInfoResponse = null;
      thumbnailResponse = null;
      batchResponse = null;
      estimateResponse = null;
      thumbnailsResponse = null;
      isCompressingResponse = null;
      platformError = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'compressVideo calls startCompression with correct arguments',
      () async {
        mockedResponse = jsonEncode({
          'onSuccess': '/path/to/output.mp4',
          'duration': 5.5,
        });

        await compressor.compressVideo(
          path: '/path/to/input.mp4',
          videoQuality: VideoQuality.medium,
          isMinBitrateCheckEnabled: false,
          disableAudio: true,
          video: Video(
            videoName: 'output.mp4',
            keepOriginalResolution: true,
            videoBitrateInMbps: 2.5,
            videoHeight: 720,
            videoWidth: 1280,
          ),
          android: AndroidConfig(isSharedStorage: true, saveAt: SaveAt.Movies),
          ios: IOSConfig(saveInGallery: false),
        );

        expect(log, hasLength(1));
        expect(log.first.method, 'startCompression');

        final arguments = log.first.arguments as Map<dynamic, dynamic>;
        expect(arguments['path'], '/path/to/input.mp4');
        expect(arguments['videoQuality'], 'medium');
        expect(arguments['isSharedStorage'], true);
        expect(arguments['saveAt'], 'Movies');
        expect(arguments['disableAudio'], true);
        expect(arguments['keepOriginalResolution'], true);
        expect(arguments['isMinBitrateCheckEnabled'], false);
        expect(arguments['videoBitrateInMbps'], 2.5);
        expect(arguments['videoHeight'], 720);
        expect(arguments['videoWidth'], 1280);
        expect(arguments['videoName'], 'output.mp4');
        expect(arguments['saveInGallery'], false);
      },
    );

    test(
      'compressVideo forwards BackgroundConfig as a background map',
      () async {
        mockedResponse = jsonEncode({'onSuccess': '/path/to/output.mp4'});

        await compressor.compressVideo(
          path: '/path/to/input.mp4',
          videoQuality: VideoQuality.medium,
          video: Video(videoName: 'output.mp4'),
          android: AndroidConfig(),
          ios: IOSConfig(),
          background: const BackgroundConfig(notificationTitle: 'Title'),
        );

        final arguments = log.first.arguments as Map<dynamic, dynamic>;
        expect(arguments['background'], <String, dynamic>{
          'notificationTitle': 'Title',
        });
      },
    );

    test('compressVideo sends a null background when not requested', () async {
      mockedResponse = jsonEncode({'onSuccess': '/path/to/output.mp4'});

      await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      final arguments = log.first.arguments as Map<dynamic, dynamic>;
      expect(arguments.containsKey('background'), isTrue);
      expect(arguments['background'], isNull);
    });

    test('compressVideos forwards BackgroundConfig defaults', () async {
      batchResponse = <Map<String, dynamic>>[
        {'onSuccess': '/out0.mp4'},
      ];

      await compressor.compressVideos(
        paths: ['/a.mp4'],
        videoNames: ['out0.mp4'],
        videoQuality: VideoQuality.medium,
        android: AndroidConfig(),
        ios: IOSConfig(),
        background: const BackgroundConfig(),
      );

      final arguments = log.last.arguments as Map<dynamic, dynamic>;
      final background = arguments['background'] as Map<dynamic, dynamic>;
      expect(background['notificationTitle'], 'Compressing video');
    });

    test('compressVideos forwards maxConcurrent when set', () async {
      batchResponse = <Map<String, dynamic>>[
        {'onSuccess': '/out0.mp4'},
      ];

      await compressor.compressVideos(
        paths: ['/a.mp4'],
        videoNames: ['out0.mp4'],
        videoQuality: VideoQuality.medium,
        android: AndroidConfig(),
        ios: IOSConfig(),
        maxConcurrent: 3,
      );

      final arguments = log.last.arguments as Map<dynamic, dynamic>;
      expect(arguments['maxConcurrent'], 3);
    });

    test('compressVideos sends a null maxConcurrent by default', () async {
      batchResponse = <Map<String, dynamic>>[
        {'onSuccess': '/out0.mp4'},
      ];

      await compressor.compressVideos(
        paths: ['/a.mp4'],
        videoNames: ['out0.mp4'],
        videoQuality: VideoQuality.medium,
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      final arguments = log.last.arguments as Map<dynamic, dynamic>;
      expect(arguments.containsKey('maxConcurrent'), isTrue);
      expect(arguments['maxConcurrent'], isNull);
    });

    test('compressVideos rejects maxConcurrent below 1', () async {
      await expectLater(
        compressor.compressVideos(
          paths: ['/a.mp4'],
          videoNames: ['out0.mp4'],
          videoQuality: VideoQuality.medium,
          android: AndroidConfig(),
          ios: IOSConfig(),
          maxConcurrent: 0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('compressVideo forwards debugLogging (defaults to false)', () async {
      mockedResponse = jsonEncode({'onSuccess': '/out.mp4'});
      await compressor.compressVideo(
        path: '/a.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'out.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );
      final arguments = log.first.arguments as Map<dynamic, dynamic>;
      expect(arguments['debugLogging'], false);
    });

    test('compressVideo forwards debugLogging when enabled', () async {
      mockedResponse = jsonEncode({'onSuccess': '/out.mp4'});
      await compressor.compressVideo(
        path: '/a.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'out.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
        debugLogging: true,
      );
      final arguments = log.first.arguments as Map<dynamic, dynamic>;
      expect(arguments['debugLogging'], true);
    });

    test('compressVideos forwards debugLogging', () async {
      batchResponse = <Map<String, dynamic>>[
        {'onSuccess': '/out0.mp4'},
      ];
      await compressor.compressVideos(
        paths: ['/a.mp4'],
        videoNames: ['out0.mp4'],
        videoQuality: VideoQuality.medium,
        android: AndroidConfig(),
        ios: IOSConfig(),
        debugLogging: true,
      );
      final arguments = log.last.arguments as Map<dynamic, dynamic>;
      expect(arguments['debugLogging'], true);
    });

    test('compressVideo forwards videoFormat (defaults to h264)', () async {
      mockedResponse = jsonEncode({'onSuccess': '/path/to/output.mp4'});

      await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      final arguments = log.first.arguments as Map<dynamic, dynamic>;
      expect(arguments['videoFormat'], 'h264');
    });

    test('compressVideo forwards videoFormat h265 when requested', () async {
      mockedResponse = jsonEncode({'onSuccess': '/path/to/output.mp4'});

      await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        videoFormat: VideoFormat.h265,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      final arguments = log.first.arguments as Map<dynamic, dynamic>;
      expect(arguments['videoFormat'], 'h265');
    });

    test('compressVideo parses usedFormat into OnSuccess', () async {
      mockedResponse = jsonEncode({
        'onSuccess': '/path/to/output.mp4',
        'usedFormat': 'h265',
      });

      final result = await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        videoFormat: VideoFormat.h265,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      expect(result, isA<OnSuccess>());
      expect((result as OnSuccess).usedFormat, VideoFormat.h265);
    });

    test('compressVideo defaults usedFormat to h264 when absent', () async {
      mockedResponse = jsonEncode({'onSuccess': '/path/to/output.mp4'});

      final result = await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      expect((result as OnSuccess).usedFormat, VideoFormat.h264);
    });

    test('compressVideos forwards videoFormat and parses usedFormat', () async {
      batchResponse = <Map<String, dynamic>>[
        {'onSuccess': '/out0.mp4', 'usedFormat': 'h265'},
      ];

      final results = await compressor.compressVideos(
        paths: ['/a.mp4'],
        videoNames: ['out0.mp4'],
        videoQuality: VideoQuality.medium,
        videoFormat: VideoFormat.h265,
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      final arguments = log.last.arguments as Map<dynamic, dynamic>;
      expect(arguments['videoFormat'], 'h265');
      expect((results.first as OnSuccess).usedFormat, VideoFormat.h265);
    });

    test('compressVideo returns OnSuccess when successful', () async {
      mockedResponse = jsonEncode({
        'onSuccess': '/path/to/output.mp4',
        'duration': 5.5,
      });

      final result = await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      expect(result, isA<OnSuccess>());
      expect((result as OnSuccess).destinationPath, '/path/to/output.mp4');
      expect(result.duration, 5.5);
    });

    test('compressVideo computes statistics from native sizes', () async {
      mockedResponse = jsonEncode({
        'onSuccess': '/path/to/output.mp4',
        'duration': 5.5,
        'originalSize': 1000,
        'compressedSize': 250,
      });

      final result = await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      expect(result, isA<OnSuccess>());
      result as OnSuccess;
      expect(result.originalSize, 1000);
      expect(result.compressedSize, 250);
      expect(result.ratio, 75.0);
    });

    test('compressVideo clamps ratio to zero when output grows', () async {
      mockedResponse = jsonEncode({
        'onSuccess': '/path/to/output.mp4',
        'duration': 1.0,
        'originalSize': 500,
        'compressedSize': 800,
      });

      final result = await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      expect(result, isA<OnSuccess>());
      expect((result as OnSuccess).ratio, 0.0);
    });

    test('compressVideo returns OnFailure when output path is empty', () async {
      mockedResponse = jsonEncode({'onSuccess': ''});

      final result = await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      expect(result, isA<OnFailure>());
    });

    test('compressVideo returns OnFailure when failed', () async {
      mockedResponse = jsonEncode({'onFailure': 'Compression failed'});

      final result = await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      expect(result, isA<OnFailure>());
      expect((result as OnFailure).message, 'Compression failed');
    });

    test('compressVideo returns OnCancelled when cancelled', () async {
      mockedResponse = jsonEncode({'onCancelled': true});

      final result = await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      expect(result, isA<OnCancelled>());
      expect((result as OnCancelled).isCancelled, true);
    });

    test('compressVideo returns OnFailure when response is invalid', () async {
      mockedResponse = jsonEncode({'unknown': 'invalid'});

      final result = await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      expect(result, isA<OnFailure>());
      expect((result as OnFailure).message, 'Something went wrong');
    });

    test(
      'compressVideo throws PermissionDeniedException when native fails with permission error',
      () async {
        mockedResponse = jsonEncode({'onFailure': 'Permission denied'});

        expect(
          () => compressor.compressVideo(
            path: '/path/to/input.mp4',
            videoQuality: VideoQuality.medium,
            video: Video(videoName: 'output.mp4'),
            android: AndroidConfig(),
            ios: IOSConfig(),
          ),
          throwsA(isA<PermissionDeniedException>()),
        );
      },
    );

    test(
      'compressVideo throws UnsupportedVideoException when native fails with unsupported codec',
      () async {
        mockedResponse = jsonEncode({'onFailure': 'Unsupported video codec'});

        expect(
          () => compressor.compressVideo(
            path: '/path/to/input.mp4',
            videoQuality: VideoQuality.medium,
            video: Video(videoName: 'output.mp4'),
            android: AndroidConfig(),
            ios: IOSConfig(),
          ),
          throwsA(isA<UnsupportedVideoException>()),
        );
      },
    );

    test('compressVideo maps failureType code to typed exception', () async {
      // Message text gives no hint; classification must come from failureType.
      mockedResponse = jsonEncode({
        'onFailure': 'Something broke',
        'failureType': 'unsupported',
      });

      expect(
        () => compressor.compressVideo(
          path: '/path/to/input.mp4',
          videoQuality: VideoQuality.medium,
          video: Video(videoName: 'output.mp4'),
          android: AndroidConfig(),
          ios: IOSConfig(),
        ),
        throwsA(isA<UnsupportedVideoException>()),
      );
    });

    test(
      'compressVideo returns OnFailure when failureType is unknown',
      () async {
        mockedResponse = jsonEncode({
          'onFailure': 'Some opaque error',
          'failureType': 'unknown',
        });

        final result = await compressor.compressVideo(
          path: '/path/to/input.mp4',
          videoQuality: VideoQuality.medium,
          video: Video(videoName: 'output.mp4'),
          android: AndroidConfig(),
          ios: IOSConfig(),
        );

        expect(result, isA<OnFailure>());
        expect((result as OnFailure).message, 'Some opaque error');
      },
    );

    test(
      'compressVideo throws VideoNotFoundException when native fails with file not found',
      () async {
        mockedResponse = jsonEncode({
          'onFailure': 'File not found or does not exist',
        });

        expect(
          () => compressor.compressVideo(
            path: '/path/to/input.mp4',
            videoQuality: VideoQuality.medium,
            video: Video(videoName: 'output.mp4'),
            android: AndroidConfig(),
            ios: IOSConfig(),
          ),
          throwsA(isA<VideoNotFoundException>()),
        );
      },
    );

    test('cancelCompression calls cancelCompression method', () async {
      mockedResponse = jsonEncode({'success': true});

      await compressor.cancelCompression();

      expect(log, hasLength(1));
      expect(log.first.method, 'cancelCompression');
    });
    test('clearCache calls clearCache method', () async {
      mockedResponse = jsonEncode({'success': true});

      await compressor.clearCache();

      expect(log, hasLength(1));
      expect(log.first.method, 'clearCache');
    });

    test('getMediaInfo returns parsed MediaInfo', () async {
      mediaInfoResponse = <String, dynamic>{
        'width': 1920,
        'height': 1080,
        'durationMs': 66000,
        'fileSize': 1000,
        'bitrate': 5000000,
        'rotation': 0,
        'frameRate': 30.0,
        'mimeType': 'video/mp4',
      };

      final info = await compressor.getMediaInfo('/path/to/input.mp4');

      expect(log.last.method, 'getMediaInfo');
      expect(log.last.arguments, <String, dynamic>{
        'path': '/path/to/input.mp4',
      });
      expect(info.width, 1920);
      expect(info.height, 1080);
      expect(info.duration, const Duration(seconds: 66));
      expect(info.mimeType, 'video/mp4');
    });

    test(
      'getMediaInfo throws VideoNotFoundException on native error',
      () async {
        platformError = PlatformException(
          code: 'VIDEO_NOT_FOUND',
          message: 'missing',
        );

        expect(
          () => compressor.getMediaInfo('/path/to/input.mp4'),
          throwsA(isA<VideoNotFoundException>()),
        );
      },
    );

    test('getMediaInfo throws MediaInfoException on generic error', () async {
      platformError = PlatformException(
        code: 'MEDIA_INFO_FAILED',
        message: 'boom',
      );

      expect(
        () => compressor.getMediaInfo('/path/to/input.mp4'),
        throwsA(isA<MediaInfoException>()),
      );
    });

    test('getVideoThumbnail returns path and forwards arguments', () async {
      thumbnailResponse = '/cache/thumb_1.jpg';

      final path = await compressor.getVideoThumbnail(
        '/path/to/input.mp4',
        positionInMs: 5000,
        quality: 80,
      );

      expect(path, '/cache/thumb_1.jpg');
      expect(log.last.method, 'getVideoThumbnail');
      final args = log.last.arguments as Map<dynamic, dynamic>;
      expect(args['path'], '/path/to/input.mp4');
      expect(args['positionInMs'], 5000);
      expect(args['quality'], 80);
    });

    test('getVideoThumbnail clamps quality to 0..100', () async {
      thumbnailResponse = '/cache/thumb_1.jpg';

      await compressor.getVideoThumbnail('/path/to/input.mp4', quality: 250);

      final args = log.last.arguments as Map<dynamic, dynamic>;
      expect(args['quality'], 100);
    });

    test(
      'getVideoThumbnail throws ThumbnailException when native returns null',
      () async {
        thumbnailResponse = null;

        expect(
          () => compressor.getVideoThumbnail('/path/to/input.mp4'),
          throwsA(isA<ThumbnailException>()),
        );
      },
    );

    test(
      'getVideoThumbnail maps permission error to PermissionDeniedException',
      () async {
        platformError = PlatformException(
          code: 'PERMISSION_DENIED',
          message: 'denied',
        );

        expect(
          () => compressor.getVideoThumbnail('/path/to/input.mp4'),
          throwsA(isA<PermissionDeniedException>()),
        );
      },
    );

    test(
      'compressVideos returns ordered results and forwards arguments',
      () async {
        batchResponse = <Map<String, dynamic>>[
          {
            'onSuccess': '/out0.mp4',
            'originalSize': 1000,
            'compressedSize': 400,
            'duration': 5.0,
          },
          {'onFailure': 'bad codec'},
        ];

        final results = await compressor.compressVideos(
          paths: ['/a.mp4', '/b.mp4'],
          videoNames: ['out0.mp4', 'out1.mp4'],
          videoQuality: VideoQuality.high,
          android: AndroidConfig(
            isSharedStorage: false,
            saveAt: SaveAt.Pictures,
          ),
          ios: IOSConfig(saveInGallery: true),
          videoWidth: 1280,
          videoHeight: 720,
          disableAudio: true,
        );

        expect(log.last.method, 'startBatchCompression');
        final args = log.last.arguments as Map<dynamic, dynamic>;
        expect(args['paths'], ['/a.mp4', '/b.mp4']);
        expect(args['videoNames'], ['out0.mp4', 'out1.mp4']);
        expect(args['videoQuality'], 'high');
        expect(args['saveAt'], 'Pictures');
        expect(args['videoWidth'], 1280);
        expect(args['disableAudio'], true);

        expect(results, hasLength(2));
        expect(results[0], isA<OnSuccess>());
        expect((results[0] as OnSuccess).ratio, 60.0);
        expect(results[1], isA<OnFailure>());
        expect((results[1] as OnFailure).message, 'bad codec');
      },
    );

    test(
      'compressVideos returns empty list and skips channel for empty input',
      () async {
        final results = await compressor.compressVideos(
          paths: <String>[],
          videoNames: <String>[],
          videoQuality: VideoQuality.medium,
          android: AndroidConfig(),
          ios: IOSConfig(),
        );

        expect(results, isEmpty);
        expect(
          log.where((MethodCall c) => c.method == 'startBatchCompression'),
          isEmpty,
        );
      },
    );

    test(
      'compressVideo defaults usedFormat to h264 for an unknown wire value',
      () async {
        mockedResponse = jsonEncode({
          'onSuccess': '/path/to/output.mp4',
          'usedFormat': 'av1',
        });

        final result = await compressor.compressVideo(
          path: '/path/to/input.mp4',
          videoQuality: VideoQuality.medium,
          video: Video(videoName: 'output.mp4'),
          android: AndroidConfig(),
          ios: IOSConfig(),
        );

        expect((result as OnSuccess).usedFormat, VideoFormat.h264);
      },
    );

    test('compressVideos preserves order across mixed outcomes', () async {
      batchResponse = <Map<String, dynamic>>[
        {'onSuccess': '/a.mp4', 'originalSize': 100, 'compressedSize': 40},
        {'onFailure': 'bad codec', 'failureType': 'unsupported'},
        {'onCancelled': true},
      ];

      final results = await compressor.compressVideos(
        paths: ['/a.mp4', '/b.mp4', '/c.mp4'],
        videoNames: ['a.mp4', 'b.mp4', 'c.mp4'],
        videoQuality: VideoQuality.medium,
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      expect(results, hasLength(3));
      expect(results[0], isA<OnSuccess>());
      expect(results[1], isA<OnFailure>());
      expect(results[2], isA<OnCancelled>());
      expect((results[2] as OnCancelled).isCancelled, isTrue);
    });

    test('compressVideos exposes failureType on OnFailure', () async {
      batchResponse = <Map<String, dynamic>>[
        {'onFailure': 'denied', 'failureType': 'permission'},
        {'onFailure': 'opaque error'},
      ];

      final results = await compressor.compressVideos(
        paths: ['/a.mp4', '/b.mp4'],
        videoNames: ['a.mp4', 'b.mp4'],
        videoQuality: VideoQuality.medium,
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      expect(
        (results[0] as OnFailure).failureType,
        CompressionFailureType.permission,
      );
      expect(
        (results[1] as OnFailure).failureType,
        CompressionFailureType.unknown,
      );
    });

    test(
      'getMediaInfo throws MediaInfoException when native returns null',
      () async {
        mediaInfoResponse = null;

        expect(
          () => compressor.getMediaInfo('/path/to/input.mp4'),
          throwsA(isA<MediaInfoException>()),
        );
      },
    );

    test(
      'onProgressUpdated emits doubles (int coerced, null becomes 0)',
      () async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const EventChannel progressChannel = EventChannel('compression/stream');
        messenger.setMockStreamHandler(
          progressChannel,
          MockStreamHandler.inline(
            onListen: (Object? args, MockStreamHandlerEventSink sink) {
              sink.success(50); // int from native
              sink.success(null); // null → 0.0
              sink.endOfStream();
            },
          ),
        );
        addTearDown(
          () => messenger.setMockStreamHandler(progressChannel, null),
        );

        final List<double> values =
            await compressor.onProgressUpdated.take(2).toList();
        expect(values, <double>[50.0, 0.0]);
      },
    );

    test('onBatchUpdate decodes a progress event into BatchProgress', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const EventChannel batchChannel = EventChannel(
        'compression/batch-stream',
      );
      messenger.setMockStreamHandler(
        batchChannel,
        MockStreamHandler.inline(
          onListen: (Object? args, MockStreamHandlerEventSink sink) {
            sink.success(<String, dynamic>{
              'type': 'progress',
              'index': 1,
              'percent': 40, // int from native → coerced to double
              'overallPercent': 20.0,
              'bytesProcessed': 4096,
              'etaMs': 5000,
              'elapsedMs': 2000,
            });
            sink.success(<String, dynamic>{
              'type': 'progress',
              'index': 1,
              'percent': 60.0,
              'overallPercent': 30.0,
              'etaMs': -1, // not yet estimable → null
            });
            sink.endOfStream();
          },
        ),
      );
      addTearDown(() => messenger.setMockStreamHandler(batchChannel, null));

      final List<BatchEvent> events =
          await compressor.onBatchUpdate.take(2).toList();

      final BatchProgress first = events[0] as BatchProgress;
      expect(first.index, 1);
      expect(first.percent, 40.0);
      expect(first.overallPercent, 20.0);
      expect(first.bytesProcessed, 4096);
      expect(first.etaMs, 5000);
      expect(first.elapsedMs, 2000);

      final BatchProgress second = events[1] as BatchProgress;
      expect(second.etaMs, isNull); // -1 coerced to null
      expect(second.bytesProcessed, isNull); // absent → null
    });

    test(
      'onBatchUpdate decodes a result event into BatchItemCompleted',
      () async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const EventChannel batchChannel = EventChannel(
          'compression/batch-stream',
        );
        messenger.setMockStreamHandler(
          batchChannel,
          MockStreamHandler.inline(
            onListen: (Object? args, MockStreamHandlerEventSink sink) {
              sink.success(<String, dynamic>{
                'type': 'result',
                'index': 0,
                'onSuccess': '/out.mp4',
                'originalSize': 2000,
                'compressedSize': 800,
                'duration': 3000,
                'usedFormat': 'h265',
              });
              sink.endOfStream();
            },
          ),
        );
        addTearDown(() => messenger.setMockStreamHandler(batchChannel, null));

        final List<BatchEvent> events =
            await compressor.onBatchUpdate.take(1).toList();

        final BatchItemCompleted completed = events[0] as BatchItemCompleted;
        expect(completed.index, 0);
        expect(completed.result, isA<OnSuccess>());
        final OnSuccess ok = completed.result as OnSuccess;
        expect(ok.destinationPath, '/out.mp4');
        expect(ok.usedFormat, VideoFormat.h265);
      },
    );

    // --- Phase 7: pre-flight & introspection ---

    test(
      'getCompressionEstimate forwards arguments and parses the estimate',
      () async {
        estimateResponse = <String, dynamic>{
          'originalSizeBytes': 1000,
          'estimatedSizeBytes': 250,
          'targetBitrate': 2000000,
          'outputWidth': 1280,
          'outputHeight': 720,
          'estimatedRatio': 75.0,
        };

        final estimate = await compressor.getCompressionEstimate(
          '/path/to/input.mp4',
          videoQuality: VideoQuality.medium,
          videoFormat: VideoFormat.h265,
          keepOriginalResolution: true,
          videoWidth: 1280,
          videoHeight: 720,
          videoBitrateInMbps: 2.5,
          disableAudio: true,
        );

        expect(log.last.method, 'getCompressionEstimate');
        final args = log.last.arguments as Map<dynamic, dynamic>;
        expect(args['path'], '/path/to/input.mp4');
        expect(args['videoQuality'], 'medium');
        expect(args['videoFormat'], 'h265');
        expect(args['keepOriginalResolution'], true);
        expect(args['videoWidth'], 1280);
        expect(args['videoHeight'], 720);
        expect(args['videoBitrateInMbps'], 2.5);
        expect(args['disableAudio'], true);

        expect(estimate.originalSizeBytes, 1000);
        expect(estimate.estimatedSizeBytes, 250);
        expect(estimate.targetBitrate, 2000000);
        expect(estimate.outputWidth, 1280);
        expect(estimate.outputHeight, 720);
        expect(estimate.estimatedRatio, 75.0);
      },
    );

    test(
      'getCompressionEstimate throws EstimateException on ESTIMATE_FAILED',
      () async {
        platformError = PlatformException(
          code: 'ESTIMATE_FAILED',
          message: 'boom',
        );

        expect(
          () => compressor.getCompressionEstimate(
            '/path/to/input.mp4',
            videoQuality: VideoQuality.medium,
          ),
          throwsA(isA<EstimateException>()),
        );
      },
    );

    test(
      'getCompressionEstimate maps VIDEO_NOT_FOUND to VideoNotFoundException',
      () async {
        platformError = PlatformException(
          code: 'VIDEO_NOT_FOUND',
          message: 'missing',
        );

        expect(
          () => compressor.getCompressionEstimate(
            '/path/to/input.mp4',
            videoQuality: VideoQuality.medium,
          ),
          throwsA(isA<VideoNotFoundException>()),
        );
      },
    );

    test('isCompressing returns the parsed boolean', () async {
      isCompressingResponse = true;

      final running = await compressor.isCompressing();

      expect(running, isTrue);
      expect(log.last.method, 'isCompressing');
    });

    test('isCompressing returns false when native returns null', () async {
      isCompressingResponse = null;

      expect(await compressor.isCompressing(), isFalse);
    });

    test(
      'getVideoThumbnails forwards requests and returns ordered paths',
      () async {
        thumbnailsResponse = <String>['/cache/t0.jpg', '/cache/t1.jpg'];

        final paths = await compressor
            .getVideoThumbnails('/path/to/input.mp4', const <ThumbnailRequest>[
          ThumbnailRequest(positionInMs: 0, quality: 80),
          ThumbnailRequest(positionInMs: 5000),
        ]);

        expect(paths, <String>['/cache/t0.jpg', '/cache/t1.jpg']);
        expect(log.last.method, 'getVideoThumbnails');
        final args = log.last.arguments as Map<dynamic, dynamic>;
        expect(args['path'], '/path/to/input.mp4');
        final requests = args['requests'] as List<dynamic>;
        expect(requests, hasLength(2));
        expect((requests[0] as Map<dynamic, dynamic>)['positionInMs'], 0);
        expect((requests[0] as Map<dynamic, dynamic>)['quality'], 80);
        expect((requests[1] as Map<dynamic, dynamic>)['positionInMs'], 5000);
        expect((requests[1] as Map<dynamic, dynamic>)['quality'], 50);
      },
    );

    test('getVideoThumbnails clamps quality and floors position', () async {
      thumbnailsResponse = <String>['/cache/t0.jpg'];

      await compressor.getVideoThumbnails(
        '/path/to/input.mp4',
        const <ThumbnailRequest>[
          ThumbnailRequest(positionInMs: -100, quality: 250),
        ],
      );

      final args = log.last.arguments as Map<dynamic, dynamic>;
      final requests = args['requests'] as List<dynamic>;
      expect((requests[0] as Map<dynamic, dynamic>)['positionInMs'], 0);
      expect((requests[0] as Map<dynamic, dynamic>)['quality'], 100);
    });

    test(
      'getVideoThumbnails throws ThumbnailException on THUMBNAIL_FAILED',
      () async {
        platformError = PlatformException(
          code: 'THUMBNAIL_FAILED',
          message: 'no frame',
        );

        expect(
          () => compressor.getVideoThumbnails(
            '/path/to/input.mp4',
            const <ThumbnailRequest>[ThumbnailRequest(positionInMs: 0)],
          ),
          throwsA(isA<ThumbnailException>()),
        );
      },
    );

    // --- Phase 8a: target file size ---

    test('compressVideo forwards targetSizeBytes from targetSizeMb', () async {
      mockedResponse = jsonEncode({'onSuccess': '/path/to/output.mp4'});

      await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4', targetSizeMb: 10),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      final arguments = log.first.arguments as Map<dynamic, dynamic>;
      expect(arguments['targetSizeBytes'], 10 * 1000 * 1000);
    });

    test(
      'compressVideo sends a null targetSizeBytes when not requested',
      () async {
        mockedResponse = jsonEncode({'onSuccess': '/path/to/output.mp4'});

        await compressor.compressVideo(
          path: '/path/to/input.mp4',
          videoQuality: VideoQuality.medium,
          video: Video(videoName: 'output.mp4'),
          android: AndroidConfig(),
          ios: IOSConfig(),
        );

        final arguments = log.first.arguments as Map<dynamic, dynamic>;
        expect(arguments.containsKey('targetSizeBytes'), isTrue);
        expect(arguments['targetSizeBytes'], isNull);
      },
    );

    test('compressVideos forwards targetSizeBytes from targetSizeMb', () async {
      batchResponse = <Map<String, dynamic>>[
        {'onSuccess': '/out0.mp4'},
      ];

      await compressor.compressVideos(
        paths: ['/a.mp4'],
        videoNames: ['out0.mp4'],
        videoQuality: VideoQuality.medium,
        android: AndroidConfig(),
        ios: IOSConfig(),
        targetSizeMb: 25,
      );

      final args = log.last.arguments as Map<dynamic, dynamic>;
      expect(args['targetSizeBytes'], 25 * 1000 * 1000);
    });

    test('compressVideos forwards fractional video bitrate', () async {
      batchResponse = <Map<String, dynamic>>[
        {'onSuccess': '/out0.mp4'},
      ];

      await compressor.compressVideos(
        paths: ['/a.mp4'],
        videoNames: ['out0.mp4'],
        videoQuality: VideoQuality.medium,
        android: AndroidConfig(),
        ios: IOSConfig(),
        videoBitrateInMbps: 1.5,
      );

      final args = log.last.arguments as Map<dynamic, dynamic>;
      expect(args['videoBitrateInMbps'], 1.5);
    });

    test('compressVideos rejects a non-positive or non-finite bitrate',
        () async {
      for (final num bad in <num>[0, double.nan, double.infinity]) {
        await expectLater(
          compressor.compressVideos(
            paths: ['/a.mp4'],
            videoNames: ['out0.mp4'],
            videoQuality: VideoQuality.medium,
            android: AndroidConfig(),
            ios: IOSConfig(),
            videoBitrateInMbps: bad,
          ),
          throwsA(isA<AssertionError>()),
          reason: 'videoBitrateInMbps: $bad must be rejected',
        );
      }
    });

    test('getCompressionEstimate rejects a non-positive or non-finite bitrate',
        () async {
      for (final num bad in <num>[0, double.nan, double.infinity]) {
        await expectLater(
          compressor.getCompressionEstimate(
            '/a.mp4',
            videoQuality: VideoQuality.medium,
            videoBitrateInMbps: bad,
          ),
          throwsA(isA<AssertionError>()),
          reason: 'videoBitrateInMbps: $bad must be rejected',
        );
      }
    });

    test('compressVideos asserts targetSizeMb excludes videoBitrateInMbps', () {
      expect(
        () => compressor.compressVideos(
          paths: ['/a.mp4'],
          videoNames: ['out0.mp4'],
          videoQuality: VideoQuality.medium,
          android: AndroidConfig(),
          ios: IOSConfig(),
          targetSizeMb: 25,
          videoBitrateInMbps: 5,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test(
      'compressVideo parses targetSizeMet=false from the success map',
      () async {
        mockedResponse = jsonEncode({
          'onSuccess': '/path/to/output.mp4',
          'targetSizeMet': false,
        });

        final result = await compressor.compressVideo(
          path: '/path/to/input.mp4',
          videoQuality: VideoQuality.medium,
          video: Video(videoName: 'output.mp4', targetSizeMb: 1),
          android: AndroidConfig(),
          ios: IOSConfig(),
        );

        expect((result as OnSuccess).targetSizeMet, isFalse);
      },
    );

    test('compressVideo defaults targetSizeMet to true when absent', () async {
      mockedResponse = jsonEncode({'onSuccess': '/path/to/output.mp4'});

      final result = await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      expect((result as OnSuccess).targetSizeMet, isTrue);
    });

    test('compressVideos parses targetSizeMet from the result map', () async {
      batchResponse = <Map<String, dynamic>>[
        {'onSuccess': '/out0.mp4', 'targetSizeMet': false},
      ];

      final results = await compressor.compressVideos(
        paths: ['/a.mp4'],
        videoNames: ['out0.mp4'],
        videoQuality: VideoQuality.medium,
        android: AndroidConfig(),
        ios: IOSConfig(),
        targetSizeMb: 1,
      );

      expect((results.first as OnSuccess).targetSizeMet, isFalse);
    });

    // --- Phase 8b: frame-rate downsampling ---

    test('compressVideo forwards videoFps', () async {
      mockedResponse = jsonEncode({'onSuccess': '/path/to/output.mp4'});

      await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4', videoFps: 24),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      final arguments = log.first.arguments as Map<dynamic, dynamic>;
      expect(arguments['videoFps'], 24);
    });

    test('compressVideo sends a null videoFps when not requested', () async {
      mockedResponse = jsonEncode({'onSuccess': '/path/to/output.mp4'});

      await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      final arguments = log.first.arguments as Map<dynamic, dynamic>;
      expect(arguments.containsKey('videoFps'), isTrue);
      expect(arguments['videoFps'], isNull);
    });

    test('compressVideos forwards videoFps', () async {
      batchResponse = <Map<String, dynamic>>[
        {'onSuccess': '/out0.mp4'},
      ];

      await compressor.compressVideos(
        paths: ['/a.mp4'],
        videoNames: ['out0.mp4'],
        videoQuality: VideoQuality.medium,
        android: AndroidConfig(),
        ios: IOSConfig(),
        videoFps: 24,
      );

      final args = log.last.arguments as Map<dynamic, dynamic>;
      expect(args['videoFps'], 24);
    });

    // --- Phase 8d: two-pass encoding ---

    test('compressVideo forwards twoPass=true', () async {
      mockedResponse = jsonEncode({'onSuccess': '/path/to/output.mp4'});

      await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4', targetSizeMb: 10, twoPass: true),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      final arguments = log.first.arguments as Map<dynamic, dynamic>;
      expect(arguments['twoPass'], isTrue);
    });

    test('compressVideo forwards twoPass=false by default', () async {
      mockedResponse = jsonEncode({'onSuccess': '/path/to/output.mp4'});

      await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      final arguments = log.first.arguments as Map<dynamic, dynamic>;
      expect(arguments.containsKey('twoPass'), isTrue);
      expect(arguments['twoPass'], isFalse);
    });

    test('compressVideos forwards twoPass', () async {
      batchResponse = <Map<String, dynamic>>[
        {'onSuccess': '/out0.mp4'},
      ];

      await compressor.compressVideos(
        paths: ['/a.mp4'],
        videoNames: ['out0.mp4'],
        videoQuality: VideoQuality.medium,
        android: AndroidConfig(),
        ios: IOSConfig(),
        targetSizeMb: 25,
        twoPass: true,
      );

      final args = log.last.arguments as Map<dynamic, dynamic>;
      expect(args['twoPass'], isTrue);
    });

    test('compressVideo parses passesUsed from the success map', () async {
      mockedResponse = jsonEncode({
        'onSuccess': '/path/to/output.mp4',
        'passesUsed': 2,
      });

      final result = await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4', targetSizeMb: 10, twoPass: true),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      expect(result, isA<OnSuccess>());
      expect((result as OnSuccess).passesUsed, 2);
    });

    test('compressVideo defaults passesUsed to 1 when absent', () async {
      mockedResponse = jsonEncode({'onSuccess': '/path/to/output.mp4'});

      final result = await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      expect((result as OnSuccess).passesUsed, 1);
    });

    test('compressVideos parses passesUsed from the result map', () async {
      batchResponse = <Map<String, dynamic>>[
        {'onSuccess': '/out0.mp4', 'passesUsed': 2},
      ];

      final results = await compressor.compressVideos(
        paths: ['/a.mp4'],
        videoNames: ['out0.mp4'],
        videoQuality: VideoQuality.medium,
        android: AndroidConfig(),
        ios: IOSConfig(),
        targetSizeMb: 1,
        twoPass: true,
      );

      expect((results.first as OnSuccess).passesUsed, 2);
    });

    // --- Phase 8c: audio controls ---

    test('compressVideo forwards audio bitrate and sample rate', () async {
      mockedResponse = jsonEncode({'onSuccess': '/path/to/output.mp4'});

      await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
        audio: const AudioConfig(bitrate: 96000, sampleRate: 44100),
      );

      final arguments = log.first.arguments as Map<dynamic, dynamic>;
      expect(arguments['audioBitrate'], 96000);
      expect(arguments['audioSampleRate'], 44100);
    });

    test('compressVideo sends null audio fields when not requested', () async {
      mockedResponse = jsonEncode({'onSuccess': '/path/to/output.mp4'});

      await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      final arguments = log.first.arguments as Map<dynamic, dynamic>;
      expect(arguments.containsKey('audioBitrate'), isTrue);
      expect(arguments['audioBitrate'], isNull);
      expect(arguments['audioSampleRate'], isNull);
    });

    test('compressVideos forwards audio config', () async {
      batchResponse = <Map<String, dynamic>>[
        {'onSuccess': '/out0.mp4'},
      ];

      await compressor.compressVideos(
        paths: ['/a.mp4'],
        videoNames: ['out0.mp4'],
        videoQuality: VideoQuality.medium,
        android: AndroidConfig(),
        ios: IOSConfig(),
        audio: const AudioConfig(bitrate: 64000),
      );

      final args = log.last.arguments as Map<dynamic, dynamic>;
      expect(args['audioBitrate'], 64000);
      expect(args['audioSampleRate'], isNull);
    });

    // --- Phase 9a/9b: trim & rotate ---

    test('compressVideo forwards the edit map (trim + rotate)', () async {
      mockedResponse = jsonEncode({'onSuccess': '/path/to/output.mp4'});

      await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
        edit: const VideoEdit(
          trimStartMs: 1000,
          trimEndMs: 4000,
          rotationDegrees: 90,
        ),
      );

      final arguments = log.first.arguments as Map<dynamic, dynamic>;
      final edit = arguments['edit'] as Map<dynamic, dynamic>;
      expect(edit['trimStartMs'], 1000);
      expect(edit['trimEndMs'], 4000);
      expect(edit['rotationDegrees'], 90);
    });

    test('compressVideo sends a null edit when not requested', () async {
      mockedResponse = jsonEncode({'onSuccess': '/path/to/output.mp4'});

      await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
      );

      final arguments = log.first.arguments as Map<dynamic, dynamic>;
      expect(arguments.containsKey('edit'), isTrue);
      expect(arguments['edit'], isNull);
    });

    test('compressVideos forwards the edit map', () async {
      batchResponse = <Map<String, dynamic>>[
        {'onSuccess': '/out0.mp4'},
      ];

      await compressor.compressVideos(
        paths: ['/a.mp4'],
        videoNames: ['out0.mp4'],
        videoQuality: VideoQuality.medium,
        android: AndroidConfig(),
        ios: IOSConfig(),
        edit: const VideoEdit(trimStartMs: 500, rotationDegrees: 270),
      );

      final args = log.last.arguments as Map<dynamic, dynamic>;
      final edit = args['edit'] as Map<dynamic, dynamic>;
      expect(edit['trimStartMs'], 500);
      expect(edit['trimEndMs'], isNull);
      expect(edit['rotationDegrees'], 270);
    });

    test('compressVideo forwards color edits (clamped on the wire)', () async {
      mockedResponse = jsonEncode({'onSuccess': '/path/to/output.mp4'});

      await compressor.compressVideo(
        path: '/path/to/input.mp4',
        videoQuality: VideoQuality.medium,
        video: Video(videoName: 'output.mp4'),
        android: AndroidConfig(),
        ios: IOSConfig(),
        edit: const VideoEdit(brightness: 0.3, contrast: 1.5, saturation: 0.0),
      );

      final arguments = log.first.arguments as Map<dynamic, dynamic>;
      final edit = arguments['edit'] as Map<dynamic, dynamic>;
      expect(edit['brightness'], 0.3);
      expect(edit['contrast'], 1.5);
      expect(edit['saturation'], 0.0);
    });
  });
}
