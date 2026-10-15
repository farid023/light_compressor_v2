// End-to-end tests for the audio paths on the REAL native pipeline (the
// package unit tests only cover the mocked MethodChannel): the AAC re-encode,
// and a source whose audio cannot be muxed into the .mp4 output as-is.
//
// Uses the bundled clips that actually carry audio — sample_audio.mp4 (AAC)
// and sample_pcm.mov (16-bit PCM). The tests SKIP when they are absent.
//
//   cd example && flutter test integration_test/audio_test.dart -d <deviceId>

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';

import 'support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final LightCompressor compressor = LightCompressor();
  String? aacSource;
  String? pcmSource;

  setUpAll(() async {
    aacSource = await prepareAudioSampleSource();
    pcmSource = await preparePcmAudioSource();
  });

  Future<OnSuccess> compress(
    String path,
    String name, {
    AudioConfig? audio,
    bool disableAudio = false,
  }) async {
    final Result result = await compressor.compressVideo(
      path: path,
      videoQuality: VideoQuality.medium,
      isMinBitrateCheckEnabled: false,
      disableAudio: disableAudio,
      video: Video(videoName: name),
      android: AndroidConfig(isSharedStorage: false),
      ios: IOSConfig(saveInGallery: false),
      audio: audio,
    );
    expect(result, isA<OnSuccess>(), reason: '$name should succeed: $result');
    return result as OnSuccess;
  }

  // Bytes the audio track adds to the output: the same compression with and
  // without audio, so the picture part cancels out. Two seconds of AAC is tens
  // of KB. ~0 means the track was dropped; ~350 KB means the raw PCM was passed
  // through into the .mp4, which many players cannot play and which defeats
  // the compression.
  Future<int> audioTrackBytes(String path, String name,
      {AudioConfig? audio}) async {
    final OnSuccess withAudio = await compress(path, name, audio: audio);
    await expectReadableVideo(compressor, withAudio.destinationPath);
    final OnSuccess withoutAudio =
        await compress(path, '${name}_noaudio', disableAudio: true);
    return withAudio.compressedSize - withoutAudio.compressedSize;
  }

  void expectCompressedAudio(int audioBytes) {
    expect(audioBytes, greaterThan(8000),
        reason: 'the audio track went missing ($audioBytes B of audio)');
    expect(audioBytes, lessThan(100000),
        reason: 'the PCM audio was not compressed ($audioBytes B of audio)');
  }

  group('audio re-encode (real device)', () {
    testWidgets('re-encoding the audio yields a valid video', (
      WidgetTester tester,
    ) async {
      if (aacSource == null) return markTestSkipped(kNoAudioClipSkipReason);

      // Re-encode the audio to a low AAC bitrate + sample rate. The decode→PCM→
      // encode path and the muxer track ordering must produce a valid file, not
      // hang or corrupt the container.
      final OnSuccess ok = await compress(
        aacSource!,
        'lc_it_audio',
        audio: const AudioConfig(bitrate: 64000, sampleRate: 44100),
      );
      await expectReadableVideo(compressor, ok.destinationPath);
    });
  });

  group('non-AAC source audio (real device)', () {
    // PCM has no place in a standard .mp4, so the default passthrough path has
    // to re-encode it to AAC. Without that, Apple copied the raw PCM into the
    // .mp4 (~1.4 Mbps of audio, unplayable in many players).
    //
    // Android cannot run these: its MediaExtractor does not recognise the
    // QuickTime `lpcm` audio entry at all (it reports the track as
    // application/octet-stream, with no decoder), so there is no audio to keep.
    const String androidSkip = 'Android cannot read QuickTime lpcm audio '
        '(MediaExtractor reports application/octet-stream)';
    testWidgets('default settings keep PCM audio by re-encoding it', (
      WidgetTester tester,
    ) async {
      if (pcmSource == null) return markTestSkipped(kNoPcmClipSkipReason);
      if (Platform.isAndroid) return markTestSkipped(androidSkip);

      expectCompressedAudio(await audioTrackBytes(pcmSource!, 'lc_it_pcm'));
    });

    testWidgets('an AudioConfig re-encode of PCM audio also works', (
      WidgetTester tester,
    ) async {
      if (pcmSource == null) return markTestSkipped(kNoPcmClipSkipReason);
      if (Platform.isAndroid) return markTestSkipped(androidSkip);

      expectCompressedAudio(await audioTrackBytes(
        pcmSource!,
        'lc_it_pcm_reenc',
        audio: const AudioConfig(bitrate: 96000),
      ));
    });
  });
}
