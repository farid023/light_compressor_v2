# Changelog

# 1.9.2

### Changed

- **Fractional video bitrates:** `videoBitrateInMbps` now accepts values such as `2.5` in `Video`, `compressVideos`, and `getCompressionEstimate` on Android, iOS, and macOS. Existing integer values still work.

# 1.9.1

### Fixed

- **iOS/macOS: a compression could end with no result at all** — no success, no failure, no crash — leaving the caller waiting forever. The encode loop now always ends a pass exactly once: a drained or failed reader is handled explicitly, the file is closed only once, and cancellation is honoured while the audio track is being written.

### Internal

- **Audio is now covered by the integration tests.** The bundled sample clip had no audio track, so the Apple audio path (passthrough and AAC re-encode) was never exercised. Added a clip with audio and tests for both.

# 1.9.0

### New

- **Tap the foreground notification to reopen the app (Android, [#16](https://github.com/Farid023/light_compressor_v2/issues/16)):** the ongoing compression notification now carries a content intent, so tapping it brings the running app forward (`FLAG_ACTIVITY_REORDER_TO_FRONT`). With a task-reusing host activity (Flutter's default `launchMode="singleTop"`) the existing Flutter state is kept; after a full process kill it cold-starts. Thanks [@khlebobul](https://github.com/khlebobul) ([#18](https://github.com/Farid023/light_compressor_v2/pull/18)).

### Fixed

- **iOS/macOS crash when compressing videos that have audio ([#17](https://github.com/Farid023/light_compressor_v2/issues/17)):** with no `AudioConfig` (the default), the source audio is muxed through unchanged. The native audio writer input was created without the source format description, which made `AVAssetWriter` throw `NSInvalidArgumentException` ("provide a format hint") on a **physical iOS device** — reproducing 100% on `.mov` camera recordings (they always carry an audio track). The input now carries the source `CMFormatDescription`, so passthrough muxing to the `.mp4` container succeeds. The simulator and macOS did not surface the crash, which is why it slipped past.
- **Batch progress bounds:** `BatchProgress.percent` and `overallPercent` are now clamped to `0..100`, matching single-video progress — a native value that rounds just over `100` (or a transient negative) no longer leaks into batch progress UIs.

# 1.8.2

### Changed

- **Wider compatibility:** lowered the minimum toolchain to **Flutter 3.24 / Dart 3.5** (from 3.41 / 3.11) — no code changes; the floor now matches the SwiftPM baseline and Android `compileSdk 34` (AGP 8.1.1+).

# 1.8.1

### Changed

- **Docs:** refreshed the pub.dev package description. No code or API changes.

# 1.8.0

### New

- **Opt-in debug logging** — pass `debugLogging: true` to `compressVideo` /
  `compressVideos` to have the native side emit a couple of structured log lines
  per video (the resolved encode plan and the outcome). File paths are reduced to
  their base names. Off by default; intended for diagnosing a single run.
- **Progress detail (ETA + bytes)** — a new **`onProgressDetail`**
  (`Stream<CompressionProgress>`) reports, alongside the percentage, the
  estimated time remaining (`etaMs`), elapsed time (`elapsedMs`) and encoded
  output bytes written so far (`bytesProcessed`) for the single-video flow. The
  same fields are now also on **`BatchProgress`** (via `onBatchUpdate`). The
  existing **`onProgressUpdated`** (`Stream<double>`) is unchanged — it stays the
  simplest option for just the percentage. `etaMs` is a rough projection (an
  indicator, not a guarantee) and is `null` until it becomes estimable.
- **Configurable batch concurrency** — pass `maxConcurrent` to `compressVideos`
  to cap how many videos transcode at the same time. Leaving it unset keeps each
  platform's historic default (Android compresses up to 2 at once; Apple starts
  them all); setting it (`>= 1`) compresses strictly one-at-a-time (`1`) or trades
  memory and device heat for throughput at higher values. Honoured on Android,
  iOS and macOS; has no effect on a single `compressVideo`.
- Example app gains a **"Max concurrent"** (Auto / 1 / 2 / 3) selector in the
  batch flow.

### Fixed

- **iOS/macOS:** `getMediaInfo` now reports the correct `fileSize` for sources
  larger than ~2 GB (it read the size as a 32-bit value, which wrapped). Affects
  metadata only; compression was unaffected.
- **Android:** the AAC audio re-encode (`AudioConfig`) no longer holds the whole
  encoded audio track in RAM — it spills to a temp file and streams into the
  muxer, so memory stays flat regardless of audio duration. Output is unchanged.

### Known limitations (large files)

- **~4 GB MP4 output ceiling (Android).** `MediaMuxer`'s MP4 writer uses 32-bit
  box offsets, so outputs approaching 4 GB may fail or truncate. Target a smaller
  size (`targetSizeMb`) for very large/long sources.

All additions are additive and fully backward compatible — existing APIs are
unchanged.

# 1.7.0

### New

- **Lightweight native editing** — pass an optional **`VideoEdit`** as `edit:` to
  `compressVideo` / `compressVideos` to trim and/or rotate while compressing
  (still 100% native — no ffmpeg):
  - **Trim** — `trimStartMs` / `trimEndMs` keep a time range; the output timeline
    is rebased to start at `0` and the reported `duration` reflects the trimmed
    length. Frame-accurate (the clip is re-encoded). Either bound is optional.
  - **Rotate** — `rotationDegrees` (`0` / `90` / `180` / `270`) applies a
    quarter-turn on top of the source orientation. This is a cheap
    container-metadata rotation (no extra pixel pass) that players honour — a 90°
    turn swaps the displayed dimensions.
  - **Colour adjust** — `brightness` (`-1..1`), `contrast` (`0..2`) and
    `saturation` (`0..2`) tweak the picture (CIColorControls semantics; `0` / `1`
    / `1` = no change). Baked into the output pixels — Android via a GL shader,
    Apple via a `CIColorControls` video composition. Exact cross-platform pixel
    parity is not guaranteed.
- Example app gains trim start/end (ms) fields, a 0/90/180/270 rotate selector and
  brightness/contrast/saturation sliders in the single-video flow.

All additions are additive and fully backward compatible — existing APIs are
unchanged.

# 1.6.0

### New

- **Target output size** — pass `targetSizeMb` to `compressVideo` (on `Video`) or
  to `compressVideos` to compress toward a maximum file size in megabytes. The
  compressor solves for the video bitrate that lands the output at or below the
  target (reserving room for audio + ~3% container overhead), clamped to a 2 Mbps
  quality floor and never above the source bitrate. Mutually exclusive with
  `videoBitrateInMbps`. The new **`OnSuccess.targetSizeMet`** reports whether the
  target was achievable — `false` when the floor forced a larger output.
  Single-pass and approximate (typically within ~10–15%).
- **Two-pass encoding** — pass `twoPass: true` (on `Video` / `compressVideos`,
  alongside `targetSizeMb`) to land closer to the target size: the compressor
  encodes once, and only if the output overshot the target does it re-encode a
  second time at a corrected (lower) bitrate. An undershoot is kept as-is, so it
  re-encodes only when needed (roughly doubling the time on overshooting clips).
  The new **`OnSuccess.passesUsed`** reports how many passes ran (1 or 2). Ignored
  without a `targetSizeMb`.
- **Frame-rate control** — pass `videoFps` (on `Video` / `compressVideos`) to
  downsample the output frame rate (e.g. 30 → 24). Downsample-only: a value at or
  above the source rate leaves it unchanged (frames are never duplicated).
- **Audio re-encoding** — pass an **`AudioConfig(bitrate:, sampleRate:)`** as
  `audio:` to re-encode the audio track as AAC with a custom bitrate (and, on
  Apple, sample rate). Omitting it copies the source audio through untouched.
  - **Platform note:** `audioSampleRate` is applied on iOS/macOS; **Android
    re-encodes at the source sample rate** (no resampler), so only `bitrate`
    takes effect there.
- Example app gains "max output size (MB)", a "Two-pass (precise size)" toggle,
  "output FPS" and "audio bitrate (kbps)" fields in the single-video flow.

All additions are additive and fully backward compatible — existing APIs are
unchanged.

# 1.5.0

### New

- **`getCompressionEstimate()`** — predict a compression's output (size, bitrate, output resolution, % reduction) **without transcoding**, via the new `CompressionEstimate` model. It reuses the same bitrate/resize math the compressor uses, so the figures track the real output (approximate — single-pass).
- **`getVideoThumbnails()`** — extract several frames in a single native round-trip, returning the JPEG paths in request order, via the new `ThumbnailRequest` model. More efficient than calling `getVideoThumbnail` repeatedly.
- **`isCompressing()`** — query whether a compression (single or batch) is currently running (e.g. to gate UI).
- New **`EstimateException`** (extends `LightCompressorException`) for estimate failures.
- Example app gains a pre-flight **estimate** card and a multi-thumbnail **filmstrip** in the single-video flow.

All additions are additive and fully backward compatible — existing APIs are unchanged.

# 1.4.0

### New

- **H.265 / HEVC output** — pass an optional `videoFormat` to `compressVideo` / `compressVideos` to choose the output codec (`VideoFormat.h264` — the default — or `VideoFormat.h265`). HEVC produces noticeably smaller files at comparable quality. Omitting the parameter keeps the previous H.264 behaviour and is fully backwards compatible.
  - **Automatic fallback** — `VideoFormat.h265` is used only when the device can encode HEVC in hardware (Android: a non-software `video/hevc` encoder; iOS/macOS: an advertised HEVC encoder). On devices without it, the compressor transparently falls back to H.264 instead of failing.
  - **`OnSuccess.usedFormat`** — every successful result now reports the codec actually used, so you can tell whether an H.265 request was honoured or fell back to H.264.
- **`OnFailure.failureType`** — failures now carry a `CompressionFailureType` (`permission`, `unsupported`, `notFound`, `unknown`) so you can react to *why* a video failed — including per-item in a batch — without parsing message text. Defaults to `unknown` and `OnFailure.message` is unchanged, so this is fully backwards compatible.
- Example app gains a **“Use H.265 (HEVC)”** toggle in both the single and batch flows, and the single-video result now shows the codec used.

### Changed

- **Android:** video muxing now uses the platform `MediaMuxer` (native H.264 **and** H.265 support) instead of a bundled mp4 writer. This removes the third-party `mp4parser` / `isoparser` dependency.

# 1.3.0

### New

- **Background execution** — pass an optional `BackgroundConfig` to `compressVideo` / `compressVideos` to keep a compression running while the app is backgrounded or the screen is off. Omitting it (the default) preserves the previous behaviour and is fully backwards compatible. Behaviour is platform-specific:
  - **Android** — runs under a foreground service. Its ongoing notification shows live progress (bar + %), an elapsed-time timer, the current file name (single) or a done/total count like `2 / 5` (batch, since videos compress in parallel) and a **Cancel** action. The title comes from `BackgroundConfig`. The plugin declares the service + receiver and requests `POST_NOTIFICATIONS` (Android 13+) automatically; no host-app manifest changes are required.
  - **macOS** — suppresses App Nap (`NSProcessInfo.beginActivity`) so the process keeps full CPU while in the background. The notification fields are ignored.
  - **iOS** — not supported. iOS suspends backgrounded apps within seconds and offers no sanctioned way to keep video transcoding running, so passing a `BackgroundConfig` has no effect there; the compression pauses and resumes when the app returns to the foreground.
- Example app gains a **“Run in background”** toggle in both the single and batch flows.

# 1.2.0

### New

- **Batch compression** — `compressVideos({required List<String> paths, required List<String> videoNames, ...})` compresses multiple videos with a shared set of options and returns `Future<List<Result>>` in the same order as the inputs (each entry an `OnSuccess`, `OnFailure` or `OnCancelled`). A single video failing does not stop the rest.
- **`onBatchUpdate`** — a `Stream<BatchEvent>` that emits `BatchProgress` (per-video and overall percent) and `BatchItemCompleted` (a video's result) as the batch runs, for building per-item UIs.
- The single-video `compressVideo` and its `onProgressUpdated` stream are unchanged — batch uses a separate `compression/batch-stream` channel, so existing code is unaffected.

### Changed

- **`cancelCompression()` now returns `Future<void>`** instead of `Future<Map<String, dynamic>?>`. The old return type never carried a meaningful value; the cancellation outcome arrives as an `OnCancelled` result on the pending `compressVideo` / `compressVideos` call.

### Fixed

- **Cancelling a single compression crashed the app on Android.** Cancellation delivered two terminal callbacks for one video (`onCancelled` followed by `onFailure`) and replied twice on the same `MethodChannel.Result`, throwing `IllegalStateException: Reply already submitted`. Cancellation now yields exactly one `onCancelled`, and the single-video handler de-duplicates its reply like batch already did.
- **`cancelCompression()` never completed.** The Android, iOS and macOS handlers did not reply to the method call, so the returned `Future` hung forever. All three platforms now reply.
- **iOS / macOS:** the single-video handler funnels every terminal reply through one main-thread reply, so a cancel/finish race can no longer deliver two `FlutterResult`s or reply off the main thread.

# 1.1.0

### New

- **`getMediaInfo(path)`** — returns a structured `MediaInfo` (width, height, duration, file size, bitrate, rotation, frame rate, MIME type) with rotation-aware `displayWidth`/`displayHeight`. On Android, duration/bitrate fall back to the `MediaExtractor` track format when the metadata retriever does not expose them.
- **`getVideoThumbnail(path, {positionInMs, quality})`** — extracts a JPEG frame and returns its file path (Android `MediaMetadataRetriever`, iOS/macOS `AVAssetImageGenerator`).
- **`clearCache()`** — deletes temporary files generated during compression and thumbnail extraction (`.mp4` and `.jpg`).
- **Structured success result** — `OnSuccess` now carries `originalSize`, `compressedSize`, `duration` and `ratio` (percentage reduction).
- **Typed exceptions** — `PermissionDeniedException`, `UnsupportedVideoException`, `VideoNotFoundException`, `MediaInfoException`, `ThumbnailException`, all extending `LightCompressorException`. Native failures are surfaced via stable error codes instead of message text.
- Example app demonstrates metadata display, thumbnail preview, and a Clear Cache action.

### Fixed

- **Android H.264 encoder** — pair `KEY_PROFILE` with a supported `KEY_LEVEL`, so the hardware encoder no longer fails `configure()` with error `-38` and silently downgrades to Baseline.
- **Reported duration** — use the exact duration measured during transcoding instead of a file-size/bitrate estimate (previously could report wildly wrong values for files without duration metadata).
- **Over-compression** — when a source has no duration/bitrate metadata, estimate the bitrate from the resolution instead of collapsing to the minimum bitrate.
- **Resource handling (Android)** — keep `MediaMetadataRetriever`/`MediaExtractor` file descriptors open while reading and release the retriever (previously leaked).
- **macOS** — fixed a build failure caused by an out-of-sync `LightCompressor.swift`.

# 1.0.1

- Added Swift Package Manager (SPM) support for iOS.
- Fully migrated the Android native layer to Kotlin, including core compression algorithms, MP4 builder, and video/texture renderers.
- Integrated the native compression library sources directly into the plugin codebase.
- Upgraded the Android build system and configurations (converted build scripts to Kotlin DSL `.gradle.kts`).
- Added comprehensive production-ready documentation (`README.md`).
- Updated example project and video player.
- Optimized codebase and improved performance.
- Fixed minor issues.

# 1.0.0 (Fork)

- Forked from the original `light_compressor` package.
- Updated `kotlin-gradle-plugin` to version 1.8.21.
- Upgraded the `LightCompressor` dependency to version 1.3.2.
- Increased `compileSdkVersion` to 33.
- Fixed various bugs and improved performance.

