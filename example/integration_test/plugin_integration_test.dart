// End-to-end tests for the rest of the plugin's public surface on the REAL
// native pipeline: metadata, thumbnails, compression options, progress streams,
// cache and cancellation. (Codec selection has its own hevc_compression_test.)
//
// Requires a real input clip at example/integration_test/assets/sample.mp4 (the
// committed file is a tiny placeholder — these tests SKIP until it is replaced).
//
//   cd example && flutter test integration_test/plugin_integration_test.dart -d <deviceId>

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';

import 'support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final LightCompressor compressor = LightCompressor();
  String? source;

  setUpAll(() async {
    source = await prepareSampleSource();
  });

  // Compresses the sample to app-specific storage (no runtime permission) with
  // the given tweaks, asserting success.
  Future<OnSuccess> compressSample({
    VideoQuality quality = VideoQuality.medium,
    int? width,
    int? height,
    num? bitrateMbps,
    bool disableAudio = false,
    String name = 'lc_it_out',
  }) async {
    final Result r = await compressor.compressVideo(
      path: source!,
      videoQuality: quality,
      isMinBitrateCheckEnabled: false,
      disableAudio: disableAudio,
      video: Video(
        videoName: name,
        videoWidth: width,
        videoHeight: height,
        videoBitrateInMbps: bitrateMbps,
      ),
      android: AndroidConfig(isSharedStorage: false),
      ios: IOSConfig(saveInGallery: false),
    );
    expect(r, isA<OnSuccess>(), reason: 'compression should succeed');
    return r as OnSuccess;
  }

  group('getMediaInfo', () {
    testWidgets('reads sane metadata from a real clip', (
      WidgetTester tester,
    ) async {
      if (source == null) return markTestSkipped(kNoClipSkipReason);
      final MediaInfo info = await compressor.getMediaInfo(source!);
      expect((info.width ?? 0) > 0, isTrue);
      expect((info.height ?? 0) > 0, isTrue);
      expect(info.duration, isNotNull);
      expect(info.duration! > Duration.zero, isTrue);
    });

    testWidgets('throws VideoNotFoundException for a missing file', (
      WidgetTester tester,
    ) async {
      if (source == null) return markTestSkipped(kNoClipSkipReason);
      await expectLater(
        compressor.getMediaInfo('/does/not/exist_lc_it.mp4'),
        throwsA(isA<VideoNotFoundException>()),
      );
    });
  });

  group('getVideoThumbnail', () {
    testWidgets('writes a JPEG frame', (WidgetTester tester) async {
      if (source == null) return markTestSkipped(kNoClipSkipReason);
      final String path = await compressor.getVideoThumbnail(
        source!,
        positionInMs: 0,
        quality: 70,
      );
      expect(path, isNotEmpty);
      final File f = File(path);
      expect(f.existsSync(), isTrue);
      final List<int> bytes = await f.readAsBytes();
      expect(bytes.length, greaterThan(0));
      // JPEG SOI marker (0xFFD8).
      expect(bytes[0], 0xFF);
      expect(bytes[1], 0xD8);
    });

    testWidgets('throws for a missing file', (WidgetTester tester) async {
      if (source == null) return markTestSkipped(kNoClipSkipReason);
      await expectLater(
        compressor.getVideoThumbnail('/does/not/exist_lc_it.mp4'),
        throwsA(isA<LightCompressorException>()),
      );
    });
  });

  group('compressVideo options', () {
    testWidgets('reports sane size statistics', (WidgetTester tester) async {
      if (source == null) return markTestSkipped(kNoClipSkipReason);
      final OnSuccess ok = await compressSample(name: 'lc_it_stats');
      expect(ok.originalSize, greaterThan(0));
      expect(ok.compressedSize, greaterThan(0));
      expect(ok.ratio, inInclusiveRange(0.0, 100.0));
      await expectReadableVideo(compressor, ok.destinationPath);
    });

    testWidgets('honours a custom output resolution', (
      WidgetTester tester,
    ) async {
      if (source == null) return markTestSkipped(kNoClipSkipReason);
      final OnSuccess ok =
          await compressSample(width: 640, height: 360, name: 'lc_it_res');
      final MediaInfo info = await compressor.getMediaInfo(ok.destinationPath);
      // Orientation-agnostic: compare the sorted dimensions within a tolerance
      // (the encoder rounds to macroblock-friendly sizes).
      final List<int> dims = <int>[
        info.displayWidth ?? 0,
        info.displayHeight ?? 0,
      ]..sort();
      expect(dims[0], closeTo(360, 48));
      expect(dims[1], closeTo(640, 48));
    });

    testWidgets('honours a fractional videoBitrateInMbps', (
      WidgetTester tester,
    ) async {
      if (source == null) return markTestSkipped(kNoClipSkipReason);
      // The estimate is pure arithmetic on the native side: 1.5 must map to
      // exactly 1.5 Mbps, not a truncated 1.
      final CompressionEstimate estimate =
          await compressor.getCompressionEstimate(
        source!,
        videoQuality: VideoQuality.medium,
        videoBitrateInMbps: 1.5,
      );
      expect(estimate.targetBitrate, 1500000);

      // The encoder is VBR, so compare outputs instead of asserting an exact
      // bitrate: if 1.5 were truncated to 1, both runs would be ~equal.
      final OnSuccess one =
          await compressSample(bitrateMbps: 1, name: 'lc_it_br1');
      final OnSuccess oneAndHalf =
          await compressSample(bitrateMbps: 1.5, name: 'lc_it_br15');
      expect(
        oneAndHalf.compressedSize,
        greaterThan(one.compressedSize * 1.1),
        reason: '1.5 Mbps (${oneAndHalf.compressedSize} B) should be clearly '
            'larger than 1 Mbps (${one.compressedSize} B)',
      );
      await expectReadableVideo(compressor, oneAndHalf.destinationPath);
    });

    testWidgets('disableAudio still produces a valid video', (
      WidgetTester tester,
    ) async {
      if (source == null) return markTestSkipped(kNoClipSkipReason);
      final OnSuccess ok =
          await compressSample(disableAudio: true, name: 'lc_it_noaudio');
      await expectReadableVideo(compressor, ok.destinationPath);
    });

    testWidgets('debugLogging does not break a compression', (
      WidgetTester tester,
    ) async {
      if (source == null) return markTestSkipped(kNoClipSkipReason);
      final Result r = await compressor.compressVideo(
        path: source!,
        videoQuality: VideoQuality.medium,
        isMinBitrateCheckEnabled: false,
        video: Video(videoName: 'lc_it_debuglog'),
        android: AndroidConfig(isSharedStorage: false),
        ios: IOSConfig(saveInGallery: false),
        debugLogging: true,
      );
      expect(r, isA<OnSuccess>());
      await expectReadableVideo(compressor, (r as OnSuccess).destinationPath);
    });
  });

  group('progress streams', () {
    testWidgets('onProgressUpdated emits during a compression', (
      WidgetTester tester,
    ) async {
      if (source == null) return markTestSkipped(kNoClipSkipReason);
      final List<double> values = <double>[];
      final sub = compressor.onProgressUpdated.listen(values.add);
      await compressSample(name: 'lc_it_progress');
      await sub.cancel();
      expect(values, isNotEmpty);
      expect(values.every((double v) => v >= 0 && v <= 100), isTrue);
    });

    testWidgets('onProgressDetail reports rich progress samples', (
      WidgetTester tester,
    ) async {
      if (source == null) return markTestSkipped(kNoClipSkipReason);
      final List<CompressionProgress> samples = <CompressionProgress>[];
      final sub = compressor.onProgressDetail.listen(samples.add);
      await compressSample(name: 'lc_it_progress_detail');
      await sub.cancel();

      expect(samples, isNotEmpty);
      expect(
        samples.every(
            (CompressionProgress p) => p.percent >= 0 && p.percent <= 100),
        isTrue,
      );
      // The rich payload arrives (not just a bare percent): elapsed time is
      // always reported by both natives.
      expect(
        samples.any((CompressionProgress p) => p.elapsedMs != null),
        isTrue,
        reason: 'expected elapsedMs in the rich payload',
      );
      // When present, the extra fields are sane (non-negative).
      expect(
        samples.every((CompressionProgress p) => (p.elapsedMs ?? 0) >= 0),
        isTrue,
      );
      expect(
        samples.every((CompressionProgress p) => (p.etaMs ?? 0) >= 0),
        isTrue,
      );
      expect(
        samples.every((CompressionProgress p) => (p.bytesProcessed ?? 0) >= 0),
        isTrue,
      );
    });

    testWidgets('onBatchUpdate emits progress and completion events', (
      WidgetTester tester,
    ) async {
      if (source == null) return markTestSkipped(kNoClipSkipReason);
      final List<BatchEvent> events = <BatchEvent>[];
      final sub = compressor.onBatchUpdate.listen(events.add);
      final List<Result> results = await compressor.compressVideos(
        paths: <String>[source!, source!],
        videoNames: <String>['lc_it_be0', 'lc_it_be1'],
        videoQuality: VideoQuality.medium,
        isMinBitrateCheckEnabled: false,
        android: AndroidConfig(isSharedStorage: false),
        ios: IOSConfig(saveInGallery: false),
      );
      await sub.cancel();
      expect(results, hasLength(2));
      expect(events.whereType<BatchProgress>(), isNotEmpty);
      expect(events.whereType<BatchItemCompleted>().length, 2);
    });
  });

  group('batch resilience', () {
    // A batch runs items under a concurrency cap (Android Semaphore(2)); these
    // assert that one failing item neither stops the others nor reorders the
    // results, which stay indexed by input position.
    const String bogus = '/does/not/exist_lc_it_batch.mp4';

    testWidgets(
      'a bad path fails its slot without blocking the valid one (order kept)',
      (WidgetTester tester) async {
        if (source == null) return markTestSkipped(kNoClipSkipReason);
        final List<Result> results = await compressor.compressVideos(
          paths: <String>[source!, bogus],
          videoNames: <String>['lc_it_ok0', 'lc_it_bad1'],
          videoQuality: VideoQuality.medium,
          isMinBitrateCheckEnabled: false,
          android: AndroidConfig(isSharedStorage: false),
          ios: IOSConfig(saveInGallery: false),
        );
        expect(results, hasLength(2));
        expect(results[0], isA<OnSuccess>(),
            reason: 'valid clip at index 0 should still succeed');
        expect(results[1], isA<OnFailure>(),
            reason: 'bogus path at index 1 should fail, not block index 0');
        expect((results[1] as OnFailure).message, isNotEmpty);
        await expectReadableVideo(
            compressor, (results[0] as OnSuccess).destinationPath);
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    testWidgets(
      'a failure at index 0 still lets index 1 succeed (order kept)',
      (WidgetTester tester) async {
        if (source == null) return markTestSkipped(kNoClipSkipReason);
        final List<Result> results = await compressor.compressVideos(
          paths: <String>[bogus, source!],
          videoNames: <String>['lc_it_bad0', 'lc_it_ok1'],
          videoQuality: VideoQuality.medium,
          isMinBitrateCheckEnabled: false,
          android: AndroidConfig(isSharedStorage: false),
          ios: IOSConfig(saveInGallery: false),
        );
        expect(results, hasLength(2));
        expect(results[0], isA<OnFailure>(),
            reason: 'bogus path at index 0 should fail');
        expect(results[1], isA<OnSuccess>(),
            reason: 'valid clip at index 1 should succeed despite the failure');
        await expectReadableVideo(
            compressor, (results[1] as OnSuccess).destinationPath);
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  group('batch concurrency', () {
    // maxConcurrent caps how many videos transcode at once. Correctness —
    // every slot reports, input order is preserved and each output is a valid
    // video — must hold regardless of the cap. Serial (1) is the strictest
    // case and exercises the start-one / finish / start-next pump directly.
    testWidgets(
      'maxConcurrent: 1 compresses a batch sequentially, order kept',
      (WidgetTester tester) async {
        if (source == null) return markTestSkipped(kNoClipSkipReason);
        final List<Result> results = await compressor.compressVideos(
          paths: <String>[source!, source!, source!],
          videoNames: <String>['lc_it_mc0', 'lc_it_mc1', 'lc_it_mc2'],
          videoQuality: VideoQuality.medium,
          isMinBitrateCheckEnabled: false,
          maxConcurrent: 1,
          android: AndroidConfig(isSharedStorage: false),
          ios: IOSConfig(saveInGallery: false),
        );
        expect(results, hasLength(3));
        for (final Result r in results) {
          expect(r, isA<OnSuccess>(),
              reason: 'every capped slot should still succeed');
        }
        for (final Result r in results) {
          await expectReadableVideo(
              compressor, (r as OnSuccess).destinationPath);
        }
      },
      timeout: const Timeout(Duration(seconds: 180)),
    );
  });

  group('lifecycle', () {
    testWidgets('clearCache completes without error', (
      WidgetTester tester,
    ) async {
      if (source == null) return markTestSkipped(kNoClipSkipReason);
      await compressor.clearCache(); // smoke: must not throw or hang
    });

    testWidgets('cancelCompression resolves the pending call (no hang)', (
      WidgetTester tester,
    ) async {
      if (source == null) return markTestSkipped(kNoClipSkipReason);
      // Tolerant by design: on a short clip the compression may finish before
      // the cancel lands. The contract under test is that cancelCompression()
      // returns and the pending compressVideo Future resolves to a terminal
      // result — guarding the 1.2.0 "cancel never completed" hang regression.
      final Future<Result> pending = compressor.compressVideo(
        path: source!,
        videoQuality: VideoQuality.medium,
        isMinBitrateCheckEnabled: false,
        video: Video(videoName: 'lc_it_cancel'),
        android: AndroidConfig(isSharedStorage: false),
        ios: IOSConfig(saveInGallery: false),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await compressor.cancelCompression();
      final Result result = await pending;
      expect(
        result is OnCancelled || result is OnSuccess || result is OnFailure,
        isTrue,
      );
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
