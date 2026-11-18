// Shared helpers for the integration tests. Not a test file itself (no
// `_test.dart` suffix), so the runner won't execute it directly.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';

/// Pubspec-relative key of the bundled sample clip. Video-only — it has **no
/// audio track**, so it does not exercise the native audio mux.
const String kSampleAssetKey = 'integration_test/assets/sample.mp4';

/// Pubspec-relative key of the bundled clip that carries an AAC audio track.
/// Required by anything covering the audio path (passthrough mux or re-encode).
const String kAudioSampleAssetKey = 'integration_test/assets/sample_audio.mp4';

/// Reason shown when the audio-bearing clip is missing and a test skips.
const String kNoAudioClipSkipReason =
    'Add a real clip WITH an audio track at example/$kAudioSampleAssetKey to '
    'run this test.';

/// Pubspec-relative key of a short .mov whose audio is 16-bit PCM, as many
/// cameras and screen recorders write it. PCM cannot be muxed into the .mp4
/// output as-is. Regenerate with `tools/make_pcm_mov.swift`.
const String kPcmAudioSampleAssetKey = 'integration_test/assets/sample_pcm.mov';

/// Reason shown when the PCM-audio clip is missing and a test skips.
const String kNoPcmClipSkipReason =
    'Add the PCM-audio clip at example/$kPcmAudioSampleAssetKey to run this '
    'test.';

/// Pubspec-relative key of a short iPhone-style HDR clip: 10-bit HEVC, HLG /
/// BT.2020, with a Dolby Vision 8.4 configuration. Regenerate from an iPhone
/// HDR recording with `tools/make_hdr_hlg.swift`.
const String kHdrSampleAssetKey = 'integration_test/assets/sample_hdr.mp4';

/// Reason shown when the HDR clip is missing and a test skips.
const String kNoHdrClipSkipReason =
    'Add the HDR clip at example/$kHdrSampleAssetKey to run this test.';

/// Pubspec-relative key of a short HDR10 clip: 10-bit HEVC, PQ / BT.2020, with
/// mastering-display and content-light-level metadata. Regenerate from
/// sample_hdr.mp4 with `tools/make_hdr_pq.swift`.
const String kHdrPqSampleAssetKey = 'integration_test/assets/sample_hdr_pq.mp4';

/// Anything smaller than this is treated as the committed placeholder.
const int _minRealClipBytes = 5000;

/// Reason shown when the placeholder is still in place and a test skips.
const String kNoClipSkipReason =
    'Add a real clip at example/$kSampleAssetKey to run this test.';

/// Copies the bundled sample clip to a temp file and returns its path, or null
/// when the asset is still the placeholder (so callers can skip cleanly).
Future<String?> prepareSampleSource() =>
    _prepareAsset(kSampleAssetKey, 'source.mp4');

/// Same as [prepareSampleSource] for the clip that carries an audio track.
Future<String?> prepareAudioSampleSource() =>
    _prepareAsset(kAudioSampleAssetKey, 'source_audio.mp4');

/// Same as [prepareSampleSource] for the clip whose audio is PCM.
Future<String?> preparePcmAudioSource() =>
    _prepareAsset(kPcmAudioSampleAssetKey, 'source_pcm.mov');

/// Same as [prepareSampleSource] for the HDR clip.
Future<String?> prepareHdrSampleSource() =>
    _prepareAsset(kHdrSampleAssetKey, 'source_hdr.mp4');

/// Same as [prepareSampleSource] for the PQ (HDR10) clip.
Future<String?> prepareHdrPqSampleSource() =>
    _prepareAsset(kHdrPqSampleAssetKey, 'source_hdr_pq.mp4');

Future<String?> _prepareAsset(String assetKey, String fileName) async {
  final ByteData data;
  try {
    data = await rootBundle.load(assetKey);
  } catch (_) {
    // Asset not bundled (e.g. placeholder removed) — let the caller skip.
    return null;
  }
  final Uint8List bytes = data.buffer.asUint8List();
  if (bytes.length < _minRealClipBytes) return null;
  // Write into a dedicated sub-directory: LightCompressor.clearCache() wipes
  // *.mp4 in the (top-level) temp dir, which would otherwise delete this shared
  // source mid-suite (e.g. before the cancellation test).
  final Directory dir = Directory('${Directory.systemTemp.path}/lc_it_fixtures')
    ..createSync(recursive: true);
  final File file = File('${dir.path}/$fileName');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

/// Asserts the file at [path] is a real, *playable* video: its metadata reads
/// back with valid dimensions AND a frame can actually be decoded from it
/// (the latter catches malformed bitstreams that still carry correct metadata).
Future<void> expectReadableVideo(
    LightCompressor compressor, String path) async {
  final MediaInfo info = await compressor.getMediaInfo(path);
  expect(info.width, isNotNull);
  expect(info.height, isNotNull);
  expect((info.width ?? 0) > 0 && (info.height ?? 0) > 0, isTrue);

  // Decode a frame to prove the bitstream is valid, not just well-described.
  final String thumb = await compressor.getVideoThumbnail(path);
  expect(File(thumb).existsSync(), isTrue);
  expect(File(thumb).lengthSync(), greaterThan(0));
}

/// The bytes after the first [tag] box header in an MP4 file, or null when the
/// file has none. A plain byte scan — enough for the small sample-description
/// boxes the tests read from a short output (avcC, hvcC, colr, dvvC).
Uint8List? mp4BoxBody(Uint8List bytes, String tag) {
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

/// What an MP4 file declares about its video, read straight from the file
/// (no ffprobe).
class Mp4VideoFacts {
  const Mp4VideoFacts({
    this.primaries,
    this.transfer,
    this.matrix,
    this.hevcProfile,
    this.dolbyVisionProfile,
    this.dolbyVisionRpus = 0,
  });

  /// `colr` (nclx) codes per ISO/IEC 23091-2: primaries and matrix 1 = BT.709,
  /// 9 = BT.2020; transfer 1 = BT.709, 16 = PQ, 18 = HLG. Null without `colr`.
  final int? primaries;
  final int? transfer;
  final int? matrix;

  /// HEVC `general_profile_idc` (1 = Main, 2 = Main10); null for H.264.
  final int? hevcProfile;

  /// The Dolby Vision profile from `dvvC`, or null when not declared.
  final int? dolbyVisionProfile;

  /// Dolby Vision RPU NAL units (HEVC type 62) in `mdat`.
  final int dolbyVisionRpus;
}

int _u32(Uint8List b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

/// Reads [Mp4VideoFacts] from the MP4 at [path].
Mp4VideoFacts readMp4VideoFacts(String path) {
  final Uint8List bytes = File(path).readAsBytesSync();
  final Uint8List? colr = mp4BoxBody(bytes, 'colr');
  final bool nclx =
      colr != null && String.fromCharCodes(colr.sublist(0, 4)) == 'nclx';
  final Uint8List? hvcC = mp4BoxBody(bytes, 'hvcC');
  final Uint8List? dvvC = mp4BoxBody(bytes, 'dvvC');

  // Walk the top-level boxes to mdat, then count HEVC NAL units of type 62.
  int rpus = 0;
  if (hvcC != null) {
    int pos = 0;
    while (pos + 8 <= bytes.length) {
      int size = _u32(bytes, pos);
      int header = 8;
      if (size == 1) {
        size = (_u32(bytes, pos + 8) << 32) | _u32(bytes, pos + 12);
        header = 16;
      } else if (size == 0) {
        size = bytes.length - pos;
      }
      if (size < header) break;
      if (String.fromCharCodes(bytes.sublist(pos + 4, pos + 8)) == 'mdat') {
        int p = pos + header;
        final int end = pos + size;
        while (p + 5 <= end) {
          final int n = _u32(bytes, p);
          if (n == 0 || p + 4 + n > end) break;
          if ((bytes[p + 4] >> 1) & 0x3f == 62) rpus++;
          p += 4 + n;
        }
      }
      pos += size;
    }
  }

  return Mp4VideoFacts(
    primaries: nclx ? (colr[4] << 8) | colr[5] : null,
    transfer: nclx ? (colr[6] << 8) | colr[7] : null,
    matrix: nclx ? (colr[8] << 8) | colr[9] : null,
    hevcProfile: hvcC == null ? null : hvcC[1] & 0x1f,
    dolbyVisionProfile: dvvC == null ? null : dvvC[2] >> 1,
    dolbyVisionRpus: rpus,
  );
}
