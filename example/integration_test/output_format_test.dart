// End-to-end tests for the shape of the output on the REAL native pipeline:
// its size keeps the source's picture undistorted, and the codec level it
// declares fits that size.
//
// The output size used to be forced to multiples of 16: a 1080p source kept at
// its resolution came out 1920x1088 on Android (a stretch), and Apple's scaled
// presets cut 540 down to 528. The level used to be the highest the device
// advertised, so an encoder that honoured it declared 1080p as level 6.x, which
// iOS refuses to save.
//
//   cd example && flutter test integration_test/output_format_test.dart -d <deviceId>

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';

import 'support.dart';

/// The bytes of the first [tag] box's body, or null when the file has none.
Uint8List? _boxBody(Uint8List bytes, String tag) {
  final List<int> t = tag.codeUnits;
  for (int i = 4; i + 4 <= bytes.length; i++) {
    if (bytes[i] == t[0] &&
        bytes[i + 1] == t[1] &&
        bytes[i + 2] == t[2] &&
        bytes[i + 3] == t[3]) {
      return Uint8List.sublistView(bytes, i + 4);
    }
  }
  return null;
}

/// The level the output declares: H.264 `level_idc` (for example 40 = 4.0)
/// or HEVC `general_level_idc` (30 x level, for example 120 = 4.0).
int _declaredLevel(String path, VideoFormat format) {
  final Uint8List bytes = File(path).readAsBytesSync();
  if (format == VideoFormat.h264) {
    final Uint8List avcC = _boxBody(bytes, 'avcC')!;
    return avcC[3];
  }
  final Uint8List hvcC = _boxBody(bytes, 'hvcC')!;
  return hvcC[12];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final LightCompressor compressor = LightCompressor();
  String? source;

  setUpAll(() async {
    source = await prepareSampleSource();
  });

  Future<OnSuccess> compress(
    String name,
    VideoFormat format, {
    bool keepOriginalResolution = false,
  }) async {
    final Result result = await compressor.compressVideo(
      path: source!,
      videoQuality: VideoQuality.medium,
      isMinBitrateCheckEnabled: false,
      video: Video(
        videoName: name,
        keepOriginalResolution: keepOriginalResolution,
      ),
      android: AndroidConfig(isSharedStorage: false),
      ios: IOSConfig(saveInGallery: false),
      videoFormat: format,
    );
    expect(result, isA<OnSuccess>(), reason: '$name should succeed: $result');
    return result as OnSuccess;
  }

  for (final VideoFormat format in VideoFormat.values) {
    testWidgets('keeps a 1080p source at its exact size (${format.name})', (
      WidgetTester tester,
    ) async {
      if (source == null) return markTestSkipped(kNoClipSkipReason);
      final MediaInfo src = await compressor.getMediaInfo(source!);
      final OnSuccess ok = await compress(
        'lc_it_size_keep_${format.name}',
        format,
        keepOriginalResolution: true,
      );
      final MediaInfo out = await compressor.getMediaInfo(ok.destinationPath);
      expect('${out.displayWidth}x${out.displayHeight}',
          '${src.displayWidth}x${src.displayHeight}');
    });

    testWidgets('a scaled preset keeps the aspect ratio (${format.name})', (
      WidgetTester tester,
    ) async {
      if (source == null) return markTestSkipped(kNoClipSkipReason);
      final MediaInfo src = await compressor.getMediaInfo(source!);
      final OnSuccess ok =
          await compress('lc_it_size_scaled_${format.name}', format);
      final MediaInfo out = await compressor.getMediaInfo(ok.destinationPath);
      expect(out.displayWidth, lessThan(src.displayWidth!),
          reason: 'the medium preset should scale the 1080p sample down');
      final double srcAspect = src.displayWidth! / src.displayHeight!;
      final double outAspect = out.displayWidth! / out.displayHeight!;
      expect((outAspect - srcAspect).abs() / srcAspect, lessThan(0.005),
          reason: '${out.displayWidth}x${out.displayHeight} distorts the '
              '${src.displayWidth}x${src.displayHeight} picture');
    });

    testWidgets('declares a codec level that fits 1080p (${format.name})', (
      WidgetTester tester,
    ) async {
      if (source == null) return markTestSkipped(kNoClipSkipReason);
      final OnSuccess ok = await compress(
        'lc_it_level_${format.name}',
        format,
        keepOriginalResolution: true,
      );
      if (ok.usedFormat != format) {
        return markTestSkipped('This device has no ${format.name} encoder.');
      }
      // 1080p30 at these bitrates needs level 4.0 (H.264 40, HEVC 120). Some
      // encoders pick their own level whatever is requested (the Mi 8's HEVC
      // encoder always writes 5.0), so this allows a little headroom; what
      // must never happen again is 1080p declared as level 6.
      final int maxLevel = format == VideoFormat.h264 ? 42 : 150;
      expect(_declaredLevel(ok.destinationPath, format),
          lessThanOrEqualTo(maxLevel));
    });
  }
}
