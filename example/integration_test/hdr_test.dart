// End-to-end tests for HDR input on the REAL native pipeline. iPhones record HDR
// by default: 10-bit HEVC, HLG / BT.2020, with a Dolby Vision 8.4 layer on top.
// The bundled sample_hdr.mp4 is exactly that shape (2 s, 720p), made from an
// iPhone recording by tools/make_hdr_hlg.swift.
//
// The output of a compression is 8-bit, so it must come out as proper SDR: an
// 8-bit file still tagged HLG is non-standard (HLG needs 10 bits) and shows
// banding or washed-out colour depending on the player.
//
//   cd example && flutter test integration_test/hdr_test.dart -d <deviceId>

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';

import 'support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final LightCompressor compressor = LightCompressor();
  String? source;

  setUpAll(() async {
    source = await prepareHdrSampleSource();
  });

  Future<OnSuccess> compress(String name, VideoFormat format) async {
    final Result result = await compressor.compressVideo(
      path: source!,
      videoQuality: VideoQuality.medium,
      isMinBitrateCheckEnabled: false,
      video: Video(videoName: name),
      android: AndroidConfig(isSharedStorage: false),
      ios: IOSConfig(saveInGallery: false),
      videoFormat: format,
    );
    expect(result, isA<OnSuccess>(), reason: '$name should succeed: $result');
    return result as OnSuccess;
  }

  testWidgets('the HDR sample is detected as HDR', (WidgetTester tester) async {
    if (source == null) return markTestSkipped(kNoHdrClipSkipReason);
    expect((await compressor.getMediaInfo(source!)).isHdr, isTrue);
  });

  for (final VideoFormat format in VideoFormat.values) {
    testWidgets('an iPhone HDR clip compresses to SDR (${format.name})', (
      WidgetTester tester,
    ) async {
      if (source == null) return markTestSkipped(kNoHdrClipSkipReason);

      // Android used to fail outright here: the track is reported as
      // video/dolby-vision and most devices have no such decoder, although
      // Dolby Vision 8.4 is plain HEVC underneath.
      final OnSuccess ok = await compress('lc_it_hdr_${format.name}', format);
      await expectReadableVideo(compressor, ok.destinationPath);

      final MediaInfo out = await compressor.getMediaInfo(ok.destinationPath);
      expect(out.isHdr, isFalse,
          reason: 'an 8-bit output must not keep the HLG/PQ tags');
    });
  }

  testWidgets('a thumbnail can be taken from the HDR clip', (
    WidgetTester tester,
  ) async {
    if (source == null) return markTestSkipped(kNoHdrClipSkipReason);
    final List<String> thumbs = await compressor.getVideoThumbnails(
      source!,
      <ThumbnailRequest>[const ThumbnailRequest(positionInMs: 500)],
    );
    expect(thumbs, hasLength(1));
  });
}
