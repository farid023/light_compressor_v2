import 'package:flutter_test/flutter_test.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';

void main() {
  group('AndroidConfig', () {
    test('default values', () {
      final config = AndroidConfig();
      expect(config.isSharedStorage, true);
      expect(config.saveAt, SaveAt.Movies);
    });

    test('custom values', () {
      final config = AndroidConfig(
        isSharedStorage: false,
        saveAt: SaveAt.Pictures,
      );
      expect(config.isSharedStorage, false);
      expect(config.saveAt, SaveAt.Pictures);
    });
  });

  group('IOSConfig', () {
    test('default values', () {
      final config = IOSConfig();
      expect(config.saveInGallery, true);
    });

    test('custom values', () {
      final config = IOSConfig(saveInGallery: false);
      expect(config.saveInGallery, false);
    });
  });

  group('Video', () {
    test('required properties', () {
      final video = Video(videoName: 'test.mp4');
      expect(video.videoName, 'test.mp4');
      expect(video.keepOriginalResolution, false);
      expect(video.videoBitrateInMbps, null);
      expect(video.videoHeight, null);
      expect(video.videoWidth, null);
    });

    test('custom values', () {
      final video = Video(
        videoName: 'test.mp4',
        keepOriginalResolution: true,
        videoBitrateInMbps: 5.5,
        videoHeight: 720,
        videoWidth: 1280,
      );
      expect(video.videoName, 'test.mp4');
      expect(video.keepOriginalResolution, true);
      expect(video.videoBitrateInMbps, 5.5);
      expect(video.videoHeight, 720);
      expect(video.videoWidth, 1280);
    });

    test('targetSizeMb defaults to null and can be set', () {
      expect(Video(videoName: 'test.mp4').targetSizeMb, isNull);
      expect(Video(videoName: 'test.mp4', targetSizeMb: 10).targetSizeMb, 10);
    });

    test(
      'asserts targetSizeMb and videoBitrateInMbps are mutually exclusive',
      () {
        expect(
          () => Video(
            videoName: 't.mp4',
            targetSizeMb: 10,
            videoBitrateInMbps: 5,
          ),
          throwsA(isA<AssertionError>()),
        );
      },
    );

    test('asserts targetSizeMb is positive', () {
      expect(
        () => Video(videoName: 't.mp4', targetSizeMb: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('videoFps defaults to null and can be set', () {
      expect(Video(videoName: 'test.mp4').videoFps, isNull);
      expect(Video(videoName: 'test.mp4', videoFps: 24).videoFps, 24);
    });

    test('asserts videoFps is positive', () {
      expect(
        () => Video(videoName: 't.mp4', videoFps: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('twoPass defaults to false and can be set', () {
      expect(Video(videoName: 'test.mp4').twoPass, isFalse);
      expect(
        Video(videoName: 'test.mp4', targetSizeMb: 10, twoPass: true).twoPass,
        isTrue,
      );
    });
  });

  group('CompressionResult', () {
    test('OnSuccess contains destinationPath', () {
      const result = OnSuccess(
        destinationPath: '/path/to/video.mp4',
        originalSize: 1000,
        compressedSize: 500,
        duration: 10.0,
        ratio: 50.0,
      );
      expect(result.destinationPath, '/path/to/video.mp4');
      expect(result.originalSize, 1000);
      expect(result.compressedSize, 500);
      expect(result.duration, 10.0);
      expect(result.ratio, 50.0);
      // Defaults to H.264 when not specified.
      expect(result.usedFormat, VideoFormat.h264);
    });

    test('OnSuccess carries the codec actually used', () {
      const result = OnSuccess(
        destinationPath: '/path/to/video.mp4',
        originalSize: 1000,
        compressedSize: 500,
        duration: 10.0,
        ratio: 50.0,
        usedFormat: VideoFormat.h265,
      );
      expect(result.usedFormat, VideoFormat.h265);
    });

    test('OnSuccess targetSizeMet defaults to true and can be set false', () {
      const met = OnSuccess(
        destinationPath: '/path/to/video.mp4',
        originalSize: 1000,
        compressedSize: 500,
        duration: 10.0,
        ratio: 50.0,
      );
      expect(met.targetSizeMet, true);

      const unmet = OnSuccess(
        destinationPath: '/path/to/video.mp4',
        originalSize: 1000,
        compressedSize: 500,
        duration: 10.0,
        ratio: 50.0,
        targetSizeMet: false,
      );
      expect(unmet.targetSizeMet, false);
    });

    test('OnSuccess passesUsed defaults to 1 and can be set', () {
      const single = OnSuccess(
        destinationPath: '/path/to/video.mp4',
        originalSize: 1000,
        compressedSize: 500,
        duration: 10.0,
        ratio: 50.0,
      );
      expect(single.passesUsed, 1);

      const two = OnSuccess(
        destinationPath: '/path/to/video.mp4',
        originalSize: 1000,
        compressedSize: 500,
        duration: 10.0,
        ratio: 50.0,
        passesUsed: 2,
      );
      expect(two.passesUsed, 2);
    });

    test('OnFailure contains message', () {
      const result = OnFailure('Failed to compress');
      expect(result.message, 'Failed to compress');
    });

    test(
      'OnFailure defaults failureType to unknown and carries an explicit one',
      () {
        const a = OnFailure('boom');
        expect(a.failureType, CompressionFailureType.unknown);
        const b = OnFailure(
          'denied',
          failureType: CompressionFailureType.permission,
        );
        expect(b.failureType, CompressionFailureType.permission);
      },
    );

    test('OnCancelled contains isCancelled', () {
      const result = OnCancelled(isCancelled: true);
      expect(result.isCancelled, true);
    });
  });

  group('MediaInfo', () {
    test('fromMap parses all fields', () {
      final info = MediaInfo.fromMap(<String, dynamic>{
        'width': 1920,
        'height': 1080,
        'durationMs': 66000,
        'fileSize': 227712771,
        'bitrate': 27000000,
        'rotation': 90,
        'frameRate': 30.0,
        'mimeType': 'video/mp4',
      });

      expect(info.width, 1920);
      expect(info.height, 1080);
      expect(info.duration, const Duration(milliseconds: 66000));
      expect(info.fileSize, 227712771);
      expect(info.bitrate, 27000000);
      expect(info.rotation, 90);
      expect(info.frameRate, 30.0);
      expect(info.mimeType, 'video/mp4');
    });

    test('fromMap tolerates missing fields', () {
      final info = MediaInfo.fromMap(<String, dynamic>{});
      expect(info.width, isNull);
      expect(info.height, isNull);
      expect(info.duration, isNull);
      expect(info.bitrate, isNull);
      expect(info.mimeType, isNull);
    });

    test('zero duration maps to null', () {
      final info = MediaInfo.fromMap(<String, dynamic>{'durationMs': 0});
      expect(info.duration, isNull);
    });

    test('non-positive numeric metadata maps to null', () {
      final info = MediaInfo.fromMap(<String, dynamic>{
        'width': 0,
        'height': -1,
        'bitrate': -4,
        'frameRate': 0.0,
        'rotation': 0,
      });
      expect(info.width, isNull);
      expect(info.height, isNull);
      expect(info.bitrate, isNull);
      expect(info.frameRate, isNull);
      // rotation == 0 is valid and must be preserved.
      expect(info.rotation, 0);
    });

    test('displayWidth/displayHeight swap on 90/270 rotation', () {
      final rotated = MediaInfo.fromMap(<String, dynamic>{
        'width': 1920,
        'height': 1080,
        'rotation': 90,
      });
      expect(rotated.displayWidth, 1080);
      expect(rotated.displayHeight, 1920);

      final upright = MediaInfo.fromMap(<String, dynamic>{
        'width': 1920,
        'height': 1080,
        'rotation': 0,
      });
      expect(upright.displayWidth, 1920);
      expect(upright.displayHeight, 1080);
    });

    test('rotation 180 keeps dimensions; 270 swaps them', () {
      final r180 = MediaInfo.fromMap(<String, dynamic>{
        'width': 1920,
        'height': 1080,
        'rotation': 180,
      });
      expect(r180.displayWidth, 1920);
      expect(r180.displayHeight, 1080);

      final r270 = MediaInfo.fromMap(<String, dynamic>{
        'width': 1920,
        'height': 1080,
        'rotation': 270,
      });
      expect(r270.displayWidth, 1080);
      expect(r270.displayHeight, 1920);
    });

    test('fromMap coerces integer bitrate/frameRate', () {
      final info = MediaInfo.fromMap(<String, dynamic>{
        'width': 100,
        'height': 100,
        'bitrate': 5000000,
        'frameRate': 30,
      });
      expect(info.bitrate, 5000000);
      expect(info.frameRate, 30.0);
    });

    test('copyWith and equality', () {
      const a = MediaInfo(width: 100, height: 200, rotation: 0);
      expect(a, equals(a.copyWith(height: 200)));
      expect(a == a.copyWith(width: 999), isFalse);
      expect(a.hashCode, a.copyWith(height: 200).hashCode);
    });
  });

  group('CompressionEstimate', () {
    test('fromMap parses and coerces numeric fields', () {
      final est = CompressionEstimate.fromMap(<String, dynamic>{
        'originalSizeBytes': 1000,
        'estimatedSizeBytes': 250,
        'targetBitrate': 2000000,
        'outputWidth': 1280,
        'outputHeight': 720,
        'estimatedRatio': 75, // int on the wire → coerced to double
      });
      expect(est.originalSizeBytes, 1000);
      expect(est.estimatedSizeBytes, 250);
      expect(est.targetBitrate, 2000000);
      expect(est.outputWidth, 1280);
      expect(est.outputHeight, 720);
      expect(est.estimatedRatio, 75.0);
    });

    test('fromMap defaults missing fields to zero', () {
      final est = CompressionEstimate.fromMap(<String, dynamic>{});
      expect(est.originalSizeBytes, 0);
      expect(est.estimatedSizeBytes, 0);
      expect(est.targetBitrate, 0);
      expect(est.outputWidth, 0);
      expect(est.outputHeight, 0);
      expect(est.estimatedRatio, 0.0);
    });
  });

  group('ThumbnailRequest', () {
    test('default quality is 50', () {
      const r = ThumbnailRequest(positionInMs: 1000);
      expect(r.positionInMs, 1000);
      expect(r.quality, 50);
    });

    test('custom values', () {
      const r = ThumbnailRequest(positionInMs: 2000, quality: 90);
      expect(r.positionInMs, 2000);
      expect(r.quality, 90);
    });
  });

  group('AudioConfig', () {
    test('defaults to null fields', () {
      const a = AudioConfig();
      expect(a.bitrate, isNull);
      expect(a.sampleRate, isNull);
    });

    test('stores values', () {
      const a = AudioConfig(bitrate: 128000, sampleRate: 44100);
      expect(a.bitrate, 128000);
      expect(a.sampleRate, 44100);
    });

    test('asserts positive bitrate and sampleRate', () {
      expect(() => AudioConfig(bitrate: 0), throwsA(isA<AssertionError>()));
      expect(() => AudioConfig(sampleRate: 0), throwsA(isA<AssertionError>()));
    });
  });

  group('VideoEdit', () {
    test('defaults to null fields', () {
      const edit = VideoEdit();
      expect(edit.trimStartMs, isNull);
      expect(edit.trimEndMs, isNull);
      expect(edit.rotationDegrees, isNull);
    });

    test('stores values', () {
      const edit = VideoEdit(
        trimStartMs: 1000,
        trimEndMs: 5000,
        rotationDegrees: 90,
      );
      expect(edit.trimStartMs, 1000);
      expect(edit.trimEndMs, 5000);
      expect(edit.rotationDegrees, 90);
    });

    test('toMap serializes all keys (null when unset)', () {
      expect(const VideoEdit().toMap(), <String, dynamic>{
        'trimStartMs': null,
        'trimEndMs': null,
        'rotationDegrees': null,
        'brightness': null,
        'contrast': null,
        'saturation': null,
      });
      expect(
        const VideoEdit(
          trimStartMs: 1000,
          trimEndMs: 5000,
          rotationDegrees: 180,
        ).toMap(),
        <String, dynamic>{
          'trimStartMs': 1000,
          'trimEndMs': 5000,
          'rotationDegrees': 180,
          'brightness': null,
          'contrast': null,
          'saturation': null,
        },
      );
    });

    test('asserts trimStartMs is non-negative', () {
      expect(() => VideoEdit(trimStartMs: -1), throwsA(isA<AssertionError>()));
    });

    test('asserts trimEndMs is greater than trimStartMs', () {
      expect(
        () => VideoEdit(trimStartMs: 5000, trimEndMs: 5000),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => VideoEdit(trimStartMs: 5000, trimEndMs: 4000),
        throwsA(isA<AssertionError>()),
      );
    });

    test('asserts trimEndMs is positive when no start is given', () {
      expect(() => VideoEdit(trimEndMs: 0), throwsA(isA<AssertionError>()));
    });

    test('accepts trimEndMs alone (trim from 0)', () {
      const edit = VideoEdit(trimEndMs: 5000);
      expect(edit.trimStartMs, isNull);
      expect(edit.trimEndMs, 5000);
    });

    test('asserts rotationDegrees is a quarter turn', () {
      expect(
        () => VideoEdit(rotationDegrees: 45),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => VideoEdit(rotationDegrees: 360),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => VideoEdit(rotationDegrees: -90),
        throwsA(isA<AssertionError>()),
      );
    });

    test('accepts every quarter-turn rotation value', () {
      for (final int deg in <int>[0, 90, 180, 270]) {
        expect(VideoEdit(rotationDegrees: deg).rotationDegrees, deg);
      }
    });

    test('stores color values', () {
      const edit = VideoEdit(brightness: 0.2, contrast: 1.3, saturation: 0.5);
      expect(edit.brightness, 0.2);
      expect(edit.contrast, 1.3);
      expect(edit.saturation, 0.5);
    });

    test('toMap clamps color to their valid ranges', () {
      final map = const VideoEdit(
        brightness: 5.0, // > 1.0
        contrast: -2.0, // < 0.0
        saturation: 9.0, // > 2.0
      ).toMap();
      expect(map['brightness'], 1.0);
      expect(map['contrast'], 0.0);
      expect(map['saturation'], 2.0);
      expect(const VideoEdit(brightness: -3.0).toMap()['brightness'], -1.0);
    });
  });

  group('CompressionProgress', () {
    test('fromEvent parses a full progress map', () {
      final progress = CompressionProgress.fromEvent(<String, dynamic>{
        'percent': 42.5,
        'bytesProcessed': 1024,
        'etaMs': 3000,
        'elapsedMs': 1500,
      });
      expect(progress.percent, 42.5);
      expect(progress.bytesProcessed, 1024);
      expect(progress.etaMs, 3000);
      expect(progress.elapsedMs, 1500);
    });

    test('fromEvent accepts a bare numeric percent (legacy wire)', () {
      final progress = CompressionProgress.fromEvent(73);
      expect(progress.percent, 73.0);
      expect(progress.bytesProcessed, isNull);
      expect(progress.etaMs, isNull);
      expect(progress.elapsedMs, isNull);
    });

    test('fromEvent maps a negative etaMs to null (not yet estimable)', () {
      final progress = CompressionProgress.fromEvent(<String, dynamic>{
        'percent': 1.0,
        'etaMs': -1,
      });
      expect(progress.etaMs, isNull);
    });

    test('fromEvent coerces int/double channel numbers', () {
      final progress = CompressionProgress.fromEvent(<String, dynamic>{
        'percent': 10, // int on the wire
        'bytesProcessed': 2048.0, // double on the wire
        'etaMs': 500.0,
        'elapsedMs': 250,
      });
      expect(progress.percent, 10.0);
      expect(progress.bytesProcessed, 2048);
      expect(progress.etaMs, 500);
      expect(progress.elapsedMs, 250);
    });

    test('fromEvent defaults percent to 0 for a null event', () {
      expect(CompressionProgress.fromEvent(null).percent, 0.0);
    });
  });

  group('toString', () {
    test('models and batch events produce descriptive strings', () {
      expect(
        MediaInfo.fromMap(<String, dynamic>{
          'width': 100,
          'height': 200,
        }).toString(),
        contains('MediaInfo'),
      );
      expect(
        CompressionEstimate.fromMap(<String, dynamic>{}).toString(),
        contains('CompressionEstimate'),
      );
      expect(
        CompressionProgress.fromEvent(50).toString(),
        contains('CompressionProgress'),
      );
      expect(
        const MediaInfoException('boom').toString(),
        contains('MediaInfoException'),
      );
      expect(
        const BatchProgress(
          index: 0,
          percent: 10.0,
          overallPercent: 5.0,
        ).toString(),
        contains('BatchProgress'),
      );
      expect(
        const BatchItemCompleted(index: 0, result: OnFailure('x')).toString(),
        contains('BatchItemCompleted'),
      );
    });
  });
}
