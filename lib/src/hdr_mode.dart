import 'package:light_compressor_v2/light_compressor_v2.dart';

/// What happens to an HDR source (HLG or PQ, including an iPhone's Dolby Vision
/// recording).
///
/// Pass to [LightCompressor.compressVideo] / [LightCompressor.compressVideos]
/// through their `hdrMode` parameter. An SDR source is unaffected by either
/// value. Whether the output really is HDR is reported by [OnSuccess.isHdr].
enum HdrMode {
  /// Tone-map to SDR (BT.709) — the default. The output plays the same on every
  /// device and player.
  toSdr,

  /// Keep the HDR: write 10-bit HEVC (Main10) with the source's colour (HLG or
  /// PQ). An HDR source is written as HEVC even when `videoFormat` is
  /// [VideoFormat.h264], since 10-bit HDR needs HEVC; [OnSuccess.usedFormat]
  /// reports it.
  ///
  /// Background by platform:
  /// * **iOS / macOS** — supported where the device can encode 10-bit HEVC. An
  ///   iPhone Dolby Vision source comes out as Dolby Vision 8.4 again: the
  ///   encoder regenerates its metadata.
  /// * **Android** — not supported yet; the output is SDR as with [toSdr].
  ///
  /// Falls back to SDR when the device can't encode 10-bit HEVC, and when
  /// colour adjustments (`VideoEdit.brightness` / `contrast` / `saturation`)
  /// are requested.
  keep,
}
