// End-to-end tests for HDR input on the REAL native pipeline. iPhones record HDR
// by default: 10-bit HEVC, HLG / BT.2020, with a Dolby Vision 8.4 layer on top.
// The bundled sample_hdr.mp4 is exactly that shape (2 s, 720p), made from an
// iPhone recording by tools/make_hdr_hlg.swift; sample_hdr_pq.mp4 is the same
// picture as HDR10 (PQ), made by tools/make_hdr_pq.swift.
//
// By default (HdrMode.toSdr) the output is 8-bit SDR: an 8-bit file still
// tagged HLG/PQ is non-standard and shows banding or washed-out colour
// depending on the player. HdrMode.keep writes 10-bit HEVC with the source's
// colour instead, on iOS/macOS; Android stays SDR.
//
//   cd example && flutter test integration_test/hdr_test.dart -d <deviceId>

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';

import 'support.dart';

// ISO/IEC 23091-2 codes, as written in the `colr` box.
const int _bt2020 = 9;
const int _pq = 16;
const int _hlg = 18;
const int _hevcMain10 = 2;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final LightCompressor compressor = LightCompressor();
  final bool keepsHdr = Platform.isIOS || Platform.isMacOS;
  String? source;
  String? pqSource;
  String? sdrSource;

  setUpAll(() async {
    source = await prepareHdrSampleSource();
    pqSource = await prepareHdrPqSampleSource();
    sdrSource = await prepareSampleSource();
  });

  Future<OnSuccess> compress(
    String path,
    String name,
    VideoFormat format, {
    HdrMode hdrMode = HdrMode.toSdr,
    VideoEdit? edit,
  }) async {
    final Result result = await compressor.compressVideo(
      path: path,
      videoQuality: VideoQuality.medium,
      isMinBitrateCheckEnabled: false,
      video: Video(videoName: name),
      android: AndroidConfig(isSharedStorage: false),
      ios: IOSConfig(saveInGallery: false),
      videoFormat: format,
      hdrMode: hdrMode,
      edit: edit,
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
      final OnSuccess ok =
          await compress(source!, 'lc_it_hdr_${format.name}', format);
      await expectReadableVideo(compressor, ok.destinationPath);

      final MediaInfo out = await compressor.getMediaInfo(ok.destinationPath);
      expect(out.isHdr, isFalse,
          reason: 'an 8-bit output must not keep the HLG/PQ tags');
      expect(ok.isHdr, isFalse);
    });
  }

  testWidgets('a PQ (HDR10) clip compresses to SDR', (
    WidgetTester tester,
  ) async {
    if (pqSource == null) return markTestSkipped(kNoHdrClipSkipReason);
    expect((await compressor.getMediaInfo(pqSource!)).isHdr, isTrue);

    final OnSuccess ok =
        await compress(pqSource!, 'lc_it_hdr_pq_sdr', VideoFormat.h265);
    await expectReadableVideo(compressor, ok.destinationPath);
    expect((await compressor.getMediaInfo(ok.destinationPath)).isHdr, isFalse);
    expect(ok.isHdr, isFalse);
  });

  testWidgets('keep: an HLG clip stays HDR, in HEVC even when H.264 is asked', (
    WidgetTester tester,
  ) async {
    if (source == null) return markTestSkipped(kNoHdrClipSkipReason);

    final OnSuccess ok = await compress(
      source!,
      'lc_it_hdr_keep_hlg',
      VideoFormat.h264,
      hdrMode: HdrMode.keep,
    );
    await expectReadableVideo(compressor, ok.destinationPath);
    final MediaInfo out = await compressor.getMediaInfo(ok.destinationPath);

    if (!keepsHdr) {
      // Not supported on Android yet: the output is SDR, as with toSdr.
      expect(ok.isHdr, isFalse);
      expect(out.isHdr, isFalse);
      return;
    }
    expect(ok.isHdr, isTrue);
    expect(ok.usedFormat, VideoFormat.h265,
        reason: '10-bit HDR needs HEVC, so the codec follows');
    expect(out.isHdr, isTrue);

    final Mp4VideoFacts facts = readMp4VideoFacts(ok.destinationPath);
    expect(facts.hevcProfile, _hevcMain10);
    expect(facts.transfer, _hlg);
    expect(facts.primaries, _bt2020);
    // The encoder regenerates Dolby Vision from the HLG picture. A file must
    // never declare Dolby Vision without the per-frame metadata.
    if (facts.dolbyVisionProfile != null) {
      expect(facts.dolbyVisionRpus, greaterThan(0));
    }
  });

  testWidgets('keep: a PQ (HDR10) clip stays HDR10', (
    WidgetTester tester,
  ) async {
    if (pqSource == null) return markTestSkipped(kNoHdrClipSkipReason);

    final OnSuccess ok = await compress(
      pqSource!,
      'lc_it_hdr_keep_pq',
      VideoFormat.h265,
      hdrMode: HdrMode.keep,
    );
    await expectReadableVideo(compressor, ok.destinationPath);
    if (!keepsHdr) {
      expect(ok.isHdr, isFalse);
      return;
    }
    expect(ok.isHdr, isTrue);
    final Mp4VideoFacts facts = readMp4VideoFacts(ok.destinationPath);
    expect(facts.hevcProfile, _hevcMain10);
    expect(facts.transfer, _pq);
    expect(facts.primaries, _bt2020);
  });

  testWidgets('keep with a colour adjustment falls back to SDR', (
    WidgetTester tester,
  ) async {
    if (source == null) return markTestSkipped(kNoHdrClipSkipReason);

    final OnSuccess ok = await compress(
      source!,
      'lc_it_hdr_keep_colour',
      VideoFormat.h265,
      hdrMode: HdrMode.keep,
      edit: const VideoEdit(saturation: 0.5),
    );
    expect(ok.isHdr, isFalse);
    expect((await compressor.getMediaInfo(ok.destinationPath)).isHdr, isFalse);
  });

  testWidgets('keep leaves an SDR source as it was', (
    WidgetTester tester,
  ) async {
    if (sdrSource == null) return markTestSkipped(kNoClipSkipReason);

    final OnSuccess ok = await compress(
      sdrSource!,
      'lc_it_hdr_keep_sdr',
      VideoFormat.h264,
      hdrMode: HdrMode.keep,
    );
    expect(ok.isHdr, isFalse);
    expect(ok.usedFormat, VideoFormat.h264,
        reason: 'only an HDR source switches the codec to HEVC');
  });

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
