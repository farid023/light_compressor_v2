/// Configurations for the output video.
class Video {
  /// Creates a new [Video] configuration instance.
  ///
  /// The [videoName] is required.
  Video({
    required this.videoName,
    this.keepOriginalResolution = false,
    this.videoBitrateInMbps,
    this.videoHeight,
    this.videoWidth,
    this.targetSizeMb,
    this.videoFps,
    this.twoPass = false,
  })  : assert(
          targetSizeMb == null || videoBitrateInMbps == null,
          'targetSizeMb and videoBitrateInMbps are mutually exclusive',
        ),
        assert(
          targetSizeMb == null || targetSizeMb > 0,
          'targetSizeMb must be greater than 0',
        ),
        assert(
          videoFps == null || videoFps > 0,
          'videoFps must be greater than 0',
        );

  /// The name of the output video file (e.g., `compressed_video.mp4`).
  ///
  /// This value is required. If the `.mp4` extension is omitted, it will
  /// be appended automatically by the plugin.
  final String videoName;

  /// Whether to preserve the original video resolution (width and height) during compression.
  ///
  /// Defaults to `false`.
  final bool? keepOriginalResolution;

  /// A custom target bitrate for the output video in Mbps (Megabits per second).
  ///
  /// If provided, this overrides the default bitrate calculated by the selected VideoQuality.
  final num? videoBitrateInMbps;

  /// A custom height for the output video in pixels.
  ///
  /// If specified, you must also provide [videoWidth].
  final int? videoHeight;

  /// A custom width for the output video in pixels.
  ///
  /// If specified, you must also provide [videoHeight].
  final int? videoWidth;

  /// A target output file size in **megabytes** (decimal, 1 MB = 1,000,000
  /// bytes).
  ///
  /// When set, the compressor solves for the video bitrate that lands the
  /// output at or below this size (reserving room for audio + container
  /// overhead), instead of using the `videoQuality` preset. It is mutually
  /// exclusive with [videoBitrateInMbps] and must be greater than 0.
  ///
  /// The size is approximate (single-pass VBR): the result is usually within
  /// ~10–15% of the target. A target that is physically unreachable at the
  /// output resolution is honoured as closely as the bitrate floor allows, and
  /// reported via `OnSuccess.targetSizeMet`.
  final int? targetSizeMb;

  /// A target output frame rate, in frames per second.
  ///
  /// When set **and lower** than the source frame rate, the compressor drops
  /// frames to land at approximately this rate. It only ever downsamples — a
  /// value at or above the source fps leaves the frame rate unchanged (frames
  /// are never duplicated). Must be greater than 0.
  final int? videoFps;

  /// Whether to use **two-pass** encoding to land closer to [targetSizeMb].
  ///
  /// When `true` *and* [targetSizeMb] is set, the compressor encodes once at the
  /// solved bitrate, measures the output, and — only if it **overshot** the
  /// target — recomputes the bitrate downward and encodes a second time (capped
  /// at two passes). This tightens the result toward the requested size at the
  /// cost of roughly **doubling** the time on overshooting clips.
  ///
  /// Ignored when [targetSizeMb] is `null` (there is no size to solve for).
  /// Defaults to `false`. The number of passes actually run is reported by
  /// `OnSuccess.passesUsed`.
  final bool twoPass;
}
