// Measurement harness for constant-quality (CQ) encoding on Android, NOT a
// correctness test. It lists the device's H.264 / HEVC encoders and what they
// support, then compresses two clips with each rate-control setup forced
// exactly (no fallback) and prints the resulting video bitrate:
//
//   * motion = sample.mp4, a 1080p camera clip
//   * static = sample_static.mp4, one unchanging frame of the same clip
//
// Run it on an Android device and paste everything from "## CQ measurements"
// to the end of the output:
//
//   cd example
//   flutter test integration_test/cq_measurement_test.dart -d <deviceId>
//
// Audio is removed, so the bitrate is the video's. A "rejected" row means the
// encoder refused that setup at configure time.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';

import 'support.dart';

const MethodChannel _channel = MethodChannel('light_compressor');

class _Setting {
  const _Setting(this.mode, {this.quality, this.bitrate});

  final String mode;
  final int? quality;
  final int? bitrate;

  String get label => mode == 'cq'
      ? 'CQ $quality${bitrate == null ? '' : ' + ${_mbps(bitrate!)} hint'}'
      : '${mode.toUpperCase()} ${_mbps(bitrate!)}';

  Map<String, Object?> toMap() => <String, Object?>{
        'mode': mode,
        'quality': quality,
        'bitrate': bitrate,
      };
}

/// Run on both clips and both codecs.
const List<_Setting> _settings = <_Setting>[
  _Setting('cbr', bitrate: 2500000),
  _Setting('cq', quality: 0),
  _Setting('cq', quality: 25),
  _Setting('cq', quality: 50),
  _Setting('cq', quality: 75),
  _Setting('cq', quality: 90),
  _Setting('cq', quality: 50, bitrate: 2500000),
];

/// Motion clip at 1280x720 only: does VBR honour a low target, or hit the
/// framework's quality floor? The floor is chosen by resolution class (up to
/// 1920x1080, up to 1280x720, …). The matrix above keeps the source size, which
/// the engine rounds up to 1920x1088, just outside the 1080p class, so this
/// block uses 720p.
const List<_Setting> _bitrateSettings = <_Setting>[
  _Setting('cbr', bitrate: 1000000),
  _Setting('vbr', bitrate: 1000000),
  _Setting('vbr', bitrate: 2500000),
];

String _mbps(int bps) => '${(bps / 1e6).toStringAsFixed(1)} Mbps';

String _cell(Object? value) =>
    (value ?? '–').toString().replaceAll('|', '/').replaceAll('\n', ' ');

void _emit(String line) => debugPrint(line);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final LightCompressor compressor = LightCompressor();
  final List<String> rows = <String>[];
  int run = 0;

  Future<String> measure(
    String clip,
    String source,
    VideoFormat format,
    _Setting setting, {
    int? width,
    int? height,
  }) async {
    await _channel.invokeMethod<void>('debugForceRateControl', setting.toMap());
    final Stopwatch watch = Stopwatch()..start();
    String outcome;
    String codec = format.name;
    String? output;
    try {
      final Result result = await compressor.compressVideo(
        path: source,
        videoQuality: VideoQuality.medium,
        isMinBitrateCheckEnabled: false,
        disableAudio: true,
        video: Video(
          videoName: 'lc_cq_${run++}',
          keepOriginalResolution: width == null,
          videoWidth: width,
          videoHeight: height,
          videoBitrateInMbps: 2.5,
        ),
        android: AndroidConfig(isSharedStorage: false),
        ios: IOSConfig(saveInGallery: false),
        videoFormat: format,
      );
      if (result is OnSuccess) {
        final double kbps = result.compressedSize * 8 / result.duration / 1000;
        outcome = '${kbps.round()} kbps';
        codec = result.usedFormat == format
            ? format.name
            : '${format.name} → ${result.usedFormat.name}';
        final MediaInfo media =
            await compressor.getMediaInfo(result.destinationPath);
        output = '${media.width}x${media.height}';
        try {
          File(result.destinationPath).deleteSync();
        } on FileSystemException {
          // Leftovers only cost cache space.
        }
      } else if (result is OnFailure) {
        outcome = 'rejected: ${result.message}';
      } else {
        outcome = '$result';
      }
    } on LightCompressorException catch (e) {
      outcome = 'rejected: ${e.message}';
    }
    watch.stop();
    final String? encoder =
        await _channel.invokeMethod<String>('debugLastEncoder');
    final String row = '| $clip | $codec | ${setting.label} '
        '| ${_cell(output)} | ${_cell(encoder)} | ${_cell(outcome)} '
        '| ${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s |';
    _emit('[cq] $row');
    return row;
  }

  tearDownAll(() async {
    await _channel.invokeMethod<void>('debugForceRateControl');
  });

  testWidgets('CQ measurements', (WidgetTester tester) async {
    if (!Platform.isAndroid) {
      return markTestSkipped('Android only: Apple has been measured already.');
    }
    final String? motion = await prepareSampleSource();
    final String? still = await prepareStaticSampleSource();
    if (motion == null || still == null) {
      return markTestSkipped(kNoClipSkipReason);
    }

    final Map<String, String> clips = <String, String>{
      'motion': motion,
      'static': still,
    };
    for (final MapEntry<String, String> clip in clips.entries) {
      for (final VideoFormat format in VideoFormat.values) {
        for (final _Setting setting in _settings) {
          rows.add(await measure(clip.key, clip.value, format, setting));
        }
      }
    }
    for (final VideoFormat format in VideoFormat.values) {
      for (final _Setting setting in _bitrateSettings) {
        rows.add(await measure('motion', motion, format, setting,
            width: 1280, height: 720));
      }
    }

    final Map<Object?, Object?> info = (await _channel
        .invokeMapMethod<Object?, Object?>('debugDescribeEncoders'))!;
    final List<String> out = <String>[
      '',
      '## CQ measurements',
      '',
      '- Device: ${info['manufacturer']} ${info['model']}, '
          'SoC ${_cell(info['soc'])} (hardware ${info['hardware']}), '
          'Android ${info['release']} (API ${info['sdk']})',
    ];
    for (final MapEntry<String, String> clip in clips.entries) {
      final MediaInfo media = await compressor.getMediaInfo(clip.value);
      out.add(
          '- Clip ${clip.key}: ${media.displayWidth}x${media.displayHeight}, '
          '${((media.duration?.inMilliseconds ?? 0) / 1000).toStringAsFixed(1)} s, '
          '${((media.bitrate ?? 0) / 1000).round()} kbps');
    }
    out.addAll(<String>[
      '',
      '### Encoders',
      '',
      '| Codec | Encoder | Default | HW | Alias | CQ | Quality range | VBR | CBR |',
      '|---|---|---|---|---|---|---|---|---|',
    ]);
    for (final Object? entry in info['encoders']! as List<Object?>) {
      final Map<Object?, Object?> e = entry! as Map<Object?, Object?>;
      out.add('| ${e['mime']} | ${e['name']} | ${e['default']} '
          '| ${_cell(e['hardware'])} | ${_cell(e['alias'])} | ${e['cq']} '
          '| ${_cell(e['qualityRange'])} | ${e['vbr']} | ${e['cbr']} |');
    }
    out.addAll(<String>[
      '',
      '### Results (video bitrate, audio removed)',
      '',
      '| Clip | Codec | Setting | Output | Encoder | Result | Time |',
      '|---|---|---|---|---|---|---|',
      ...rows,
      '',
    ]);
    for (final String line in out) {
      _emit(line);
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
