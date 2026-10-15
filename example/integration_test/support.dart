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
