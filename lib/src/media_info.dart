import 'package:flutter/foundation.dart';

/// Structured metadata describing a video file.
///
/// Returned by `LightCompressor.getMediaInfo`. Every field is nullable because
/// a given container or device may not expose all of the metadata; read the
/// fields defensively.
@immutable
class MediaInfo {
  /// Creates a [MediaInfo].
  const MediaInfo({
    this.width,
    this.height,
    this.duration,
    this.fileSize,
    this.bitrate,
    this.rotation,
    this.frameRate,
    this.mimeType,
    this.isHdr,
  });

  /// Builds a [MediaInfo] from the raw map returned by the platform channel.
  ///
  /// Non-positive numeric values are treated as "unknown" (`null`), since some
  /// devices report `-1`/`0` for metadata that is actually missing. [rotation]
  /// is exempt because `0` is a valid value.
  factory MediaInfo.fromMap(Map<String, dynamic> map) {
    final int? durationMs = _positiveInt(map['durationMs']);
    return MediaInfo(
      width: _positiveInt(map['width']),
      height: _positiveInt(map['height']),
      duration: durationMs != null ? Duration(milliseconds: durationMs) : null,
      fileSize: _positiveInt(map['fileSize']),
      bitrate: _positiveInt(map['bitrate']),
      rotation: (map['rotation'] as num?)?.toInt(),
      frameRate: _positiveDouble(map['frameRate']),
      mimeType: map['mimeType'] as String?,
      isHdr: map['isHdr'] as bool?,
    );
  }

  static int? _positiveInt(Object? value) {
    final int? n = (value as num?)?.toInt();
    return (n != null && n > 0) ? n : null;
  }

  static double? _positiveDouble(Object? value) {
    final double? n = (value as num?)?.toDouble();
    return (n != null && n > 0) ? n : null;
  }

  /// The encoded width of the video in pixels, before [rotation] is applied.
  final int? width;

  /// The encoded height of the video in pixels, before [rotation] is applied.
  final int? height;

  /// The total duration of the video.
  final Duration? duration;

  /// The size of the file in bytes.
  final int? fileSize;

  /// The overall bitrate in bits per second.
  final int? bitrate;

  /// Rotation metadata in degrees: `0`, `90`, `180` or `270`.
  final int? rotation;

  /// The nominal frame rate in frames per second.
  final double? frameRate;

  /// The MIME type of the video (e.g. `video/mp4`), when available.
  final String? mimeType;

  /// Whether the video is HDR: its transfer function is HLG or PQ (ST 2084),
  /// as in the HDR / Dolby Vision recordings modern phones make by default.
  ///
  /// Compressed output is always SDR (8-bit, BT.709), so this tells an app
  /// beforehand that the colours will be converted. `null` when the platform
  /// did not report it.
  final bool? isHdr;

  /// The width as displayed, accounting for [rotation].
  ///
  /// For videos rotated by 90° or 270°, the stored [width] and [height] are
  /// swapped relative to how the video is shown.
  int? get displayWidth => (rotation == 90 || rotation == 270) ? height : width;

  /// The height as displayed, accounting for [rotation].
  int? get displayHeight =>
      (rotation == 90 || rotation == 270) ? width : height;

  /// Returns a copy of this [MediaInfo] with the given fields replaced.
  MediaInfo copyWith({
    int? width,
    int? height,
    Duration? duration,
    int? fileSize,
    int? bitrate,
    int? rotation,
    double? frameRate,
    String? mimeType,
    bool? isHdr,
  }) =>
      MediaInfo(
        width: width ?? this.width,
        height: height ?? this.height,
        duration: duration ?? this.duration,
        fileSize: fileSize ?? this.fileSize,
        bitrate: bitrate ?? this.bitrate,
        rotation: rotation ?? this.rotation,
        frameRate: frameRate ?? this.frameRate,
        mimeType: mimeType ?? this.mimeType,
        isHdr: isHdr ?? this.isHdr,
      );

  @override
  String toString() =>
      'MediaInfo(width: $width, height: $height, duration: $duration, '
      'fileSize: $fileSize, bitrate: $bitrate, rotation: $rotation, '
      'frameRate: $frameRate, mimeType: $mimeType, isHdr: $isHdr)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MediaInfo &&
          other.width == width &&
          other.height == height &&
          other.duration == duration &&
          other.fileSize == fileSize &&
          other.bitrate == bitrate &&
          other.rotation == rotation &&
          other.frameRate == frameRate &&
          other.mimeType == mimeType &&
          other.isHdr == isHdr;

  @override
  int get hashCode => Object.hash(
        width,
        height,
        duration,
        fileSize,
        bitrate,
        rotation,
        frameRate,
        mimeType,
        isHdr,
      );
}
