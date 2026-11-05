// End-to-end tests for background execution (BackgroundConfig) on the REAL
// native pipeline.
//
// On Android a compression with a BackgroundConfig runs under a foreground
// service. Android kills the whole app when that service is stopped before it
// has called startForeground(), and a compression that ends at once used to do
// exactly that: it finished before the service had even started. The process
// dies a moment after the stop, so each test waits briefly and then checks
// that the plugin still answers.
//
//   cd example && flutter test integration_test/background_test.dart -d <deviceId>

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';

import 'support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final LightCompressor compressor = LightCompressor();
  const String missing = '/does/not/exist_lc_it_background.mp4';
  // Long enough for Android to crash the app after an early stop.
  const Duration crashWindow = Duration(seconds: 3);
  String? source;

  setUpAll(() async {
    source = await prepareSampleSource();
  });

  Future<Result> compressInBackground(String path, String name) =>
      compressor.compressVideo(
        path: path,
        videoQuality: VideoQuality.medium,
        isMinBitrateCheckEnabled: false,
        video: Video(videoName: name),
        android: AndroidConfig(isSharedStorage: false),
        ios: IOSConfig(saveInGallery: false),
        background: const BackgroundConfig(),
      );

  // A missing file fails inside the engine, right after the service start.
  Future<void> failAtOnce(String name) async {
    try {
      final Result result = await compressInBackground(missing, name);
      expect(result, isA<OnFailure>(), reason: '$result');
    } on LightCompressorException {
      // A classified failure is thrown instead; either way it ended at once.
    }
  }

  testWidgets('a background compression that fails at once does not crash', (
    WidgetTester tester,
  ) async {
    for (int i = 0; i < 5; i++) {
      await failAtOnce('lc_it_bg_missing_$i');
    }
    await Future<void>.delayed(crashWindow);
    expect(await compressor.isCompressing(), isFalse);
  });

  testWidgets('a background compression runs, then one fails right after', (
    WidgetTester tester,
  ) async {
    if (source == null) return markTestSkipped(kNoClipSkipReason);

    final Result ok = await compressInBackground(source!, 'lc_it_bg_ok');
    expect(ok, isA<OnSuccess>(), reason: '$ok');
    await expectReadableVideo(
      compressor,
      (ok as OnSuccess).destinationPath,
    );

    // The next run starts while the previous service may still be going down.
    await failAtOnce('lc_it_bg_after_ok');
    await Future<void>.delayed(crashWindow);
    expect(await compressor.isCompressing(), isFalse);
  });
}
