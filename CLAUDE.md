# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`light_compressor_v2` is a **Flutter plugin** that compresses videos — one at a
time or in batches — using **each platform's native codecs**: Android
`MediaCodec` / `MediaMuxer`, Apple `AVFoundation`. It also exposes media-info,
thumbnail extraction (single + batch), a pre-flight size estimate, cancellation,
progress streams, optional background execution, H.264 / H.265 (HEVC) selection
with automatic fallback, fine output control — target file size, frame-rate
downsampling, AAC audio re-encode, optional two-pass encoding — and lightweight
native editing (trim, quarter-turn rotate, and colour adjust).

Published to pub.dev (version in [`pubspec.yaml`](pubspec.yaml)). The
**consumer-facing** API and every option are documented in [`README.md`](README.md);
this file is the **contributor** view — how the layers fit together and what must
not break.

> **There is no ffmpeg/ffprobe anywhere in this project, and none may ever be
> added** — not in the library, the example app, or in tests / manual
> verification. Everything is native codecs. This is a hard constraint.

## Repository layout

| Path | What lives there |
|------|------------------|
| [`lib/`](lib/) | The pure-Dart public API and the platform-channel client. |
| [`android/`](android/) | Android plugin (Kotlin): a thin Flutter bridge + a vendored `MediaCodec`/`MediaMuxer` transcode engine. |
| [`ios/`](ios/) | iOS plugin (Swift): Flutter bridge + an `AVFoundation` engine, as a SwiftPM package + podspec. |
| [`macos/`](macos/) | macOS plugin (Swift): near-mirror of iOS; engine is byte-identical, the plugin file differs. |
| [`example/`](example/) | Demo app **and** the integration tests that exercise the real native pipeline. |
| [`test/`](test/) | Dart-only unit tests (no device needed). |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | CI: format + analyze + unit tests on every push/PR. |

The four platform layers talk to each other **only** through the platform-channel
contract below. Keeping that contract in lock-step across Dart + all three
natives is the single most important invariant in the repo.

---

## The platform-channel contract (the spine)

One `MethodChannel` + two `EventChannel`s, declared with identical names in Dart
([`lib/src/light_compressor.dart`](lib/src/light_compressor.dart)) and every native
plugin:

- **MethodChannel `light_compressor`** — methods: `startCompression`,
  `startBatchCompression`, `cancelCompression`, `clearCache`, `getMediaInfo`,
  `getVideoThumbnail`, `getVideoThumbnails`, `getCompressionEstimate`,
  `isCompressing`.
- **EventChannel `compression/stream`** — single-video progress: a map
  `{ percent, bytesProcessed, etaMs, elapsedMs }`. `etaMs` is `-1`
  until estimable. Dart's `CompressionProgress.fromEvent` also still accepts a
  **bare `double`** (the pre-1.8.0 wire), so a Dart upgrade never hard-breaks
  against an older native; `onProgressUpdated` extracts `percent`.
- **EventChannel `compression/batch-stream`** — batch events: maps tagged
  `type: "progress"` (`index`, `percent`, `overallPercent`, plus the same
  `bytesProcessed` / `etaMs` / `elapsedMs`) or `type: "result"`
  (an `index` plus a result map).

**Result maps** (what the natives send back; parsed by `_resultFromMap` in
[`lib/src/light_compressor.dart`](lib/src/light_compressor.dart)):

- success → `{ onSuccess: <path>, originalSize, compressedSize, duration, usedFormat: "h264"|"h265", targetSizeMet, passesUsed, index }`
- failure → `{ onFailure: <message>, failureType: "permission"|"unsupported"|"notFound"|"unknown", index }`
- cancelled → `{ onCancelled: true }`

**Wire encoding differs per method — easy to get wrong:**

- `startCompression` returns a **JSON string** (Android `gson.toJson`, Apple
  `Encodable.toJson`) that Dart `jsonDecode`s.
- `startBatchCompression` returns a **`List` of maps directly** (no JSON string).
- `getMediaInfo` returns a map (incl. a bool `isHdr`: HLG/PQ transfer or Dolby
  Vision); `getVideoThumbnail` returns a path string. Both
  report errors as a `PlatformException` (`result.error(code, …)`) with codes
  `VIDEO_NOT_FOUND` / `PERMISSION_DENIED` / `UNSUPPORTED_VIDEO` /
  `MEDIA_INFO_FAILED` / `THUMBNAIL_FAILED`.
- `getVideoThumbnails` returns a **`List` of path strings** (one per requested
  frame); `getCompressionEstimate` returns a **map** (parsed by
  `CompressionEstimate.fromMap`); `isCompressing` returns a bare **`bool`**.
  The introspection methods report errors as a `PlatformException` (same codes).

The `failureType` string values are matched **verbatim** on every side —
Kotlin `CompressionErrorType.toWireValue()`, Swift `MediaError.type.rawValue`,
Dart `_failureTypeFromWire` / `_exceptionFor`. **Change one, change all four.**

## Cross-cutting invariants (don't regress these)

- **Reply once.** A platform `Result` / `FlutterResult` may be answered exactly
  once, but a cancelled run can fire more than one terminal callback. The
  single-compress path guards with `replyOnce` (an `AtomicBoolean` on Android, a
  `didReply` flag on Apple); batch de-dups per index (`results[index] == null`).
  Never add a path that can reply twice — it crashes the engine.
- **Batch order + resilience.** Results return in the same order as the input
  `paths`, and one video failing must never abort the others (its slot becomes an
  `OnFailure`). Verified by the *batch resilience* group in
  [`example/integration_test/plugin_integration_test.dart`](example/integration_test/plugin_integration_test.dart).
- **Batch concurrency is capped, never zero.** A batch transcodes at most
  `maxConcurrent` videos at once (`>= 1`); unset keeps each platform's historic
  default (Android `Semaphore(2)`; Apple started them all). Whatever the cap,
  **every** input index must still reach exactly one terminal reply — so the cap
  throttles *starts*, it must never *skip* a video (Apple keeps starting queued
  videos even after a cancel, so each one still reports). Don't let throttling
  break the "same order / every slot replies" guarantee above.
- **HEVC fallback is silent.** `videoFormat: h265` falls back to H.264 when the
  device has no hardware HEVC encoder; the caller learns the truth only from
  `OnSuccess.usedFormat`. Never *fail* just because HEVC is unavailable.
- **Native-reported sizes win.** Output may land in scoped/shared storage that
  Dart's `File` cannot stat, so Dart prefers the native `originalSize` /
  `compressedSize` and only falls back to reading the file when they are absent.
- **Target size is a ceiling with a floor.** `targetSizeMb` makes the natives
  solve for a bitrate, but never below ~2 Mbps (`MIN_BITRATE`); when that floor
  forces a larger output, `OnSuccess.targetSizeMet` is `false`. The real size is
  always in `compressedSize`. Precedence: explicit `videoBitrateInMbps` >
  `targetSizeMb` > quality preset.
- **Two-pass never enlarges.** `twoPass` runs a corrective second pass only when
  pass 1 *overshoots* the target by >10% (and the target was reachable); an
  undershoot is kept as-is, and a failed/cancelled pass 2 discards its temp and
  keeps pass 1 — so a two-pass run can never be worse than single-pass.
  `OnSuccess.passesUsed` (1 or 2) reports what actually happened.
- **Editing is trim + metadata-rotate, never re-render-to-rotate.** `VideoEdit`
  trims to a time range — the output PTS are **rebased to 0** and the reported
  `duration` is the trimmed length (the size solver + progress denominator use it
  too) — and rotates by a composed quarter-turn. Rotation is **container
  metadata**: Apple composes onto `preferredTransform`; Android applies it as a
  `setOrientationHint` *after* its source-rotation normalization (a 90/270 turn
  swaps the *displayed* dims, never the stored ones — folding it into the
  dim-swap would distort instead of rotate). Colour adjust
  (`brightness`/`contrast`/`saturation`, CIColorControls semantics) **is** baked
  into the pixels — Android via the `TextureRenderer` GL shader, Apple via a
  `CIColorControls` video composition — so cross-platform pixel parity is not
  guaranteed; the no-colour path stays a cheap no-op (identity uniforms / the
  plain track output).
- **HDR in, SDR out.** Output is always 8-bit, so an HDR source (HLG/PQ, incl.
  an iPhone's Dolby Vision 8.4) must come out tone-mapped and tagged BT.709 —
  never 8-bit with the source's HLG/PQ tags. Apple reads such a source straight
  into BT.709 (reader output + writer + colour composition); Android asks the
  decoder to tone-map (`KEY_COLOR_TRANSFER_REQUEST`, API 33+, honoured where
  supported) and always writes SDR tags. SDR sources keep the untouched path.
  A Dolby Vision track decodes through its HEVC/AVC base layer when the device
  has no Dolby Vision decoder (`CompressorUtils.remapDolbyVisionForDecoding`) —
  otherwise Android fails outright on every iPhone HDR clip.
- **Audio in the .mp4 is AAC.** With no `AudioConfig`, AAC source audio is copied
  through; Apple re-encodes any other format (e.g. `.mov` PCM) instead of
  copying it into the .mp4. Android's `MediaExtractor` cannot read QuickTime
  `lpcm` at all (`application/octet-stream`), so that track is dropped there.

---

## Dart layer — [`lib/`](lib/)

[`lib/light_compressor_v2.dart`](lib/light_compressor_v2.dart) is a barrel
re-exporting everything under `src/`. This layer is the **only** place that
encodes/decodes the channel contract.

- **[`src/light_compressor.dart`](lib/src/light_compressor.dart)** — the heart.
  The `LightCompressor` **singleton** (`factory LightCompressor() => _instance`)
  owning the one `MethodChannel` and two `EventChannel`s. Holds: the API methods
  (`compressVideo`, `compressVideos`, `getMediaInfo`, `getVideoThumbnail`,
  `getVideoThumbnails`, `getCompressionEstimate`, `isCompressing`, `clearCache`,
  `cancelCompression`); the lazy broadcast streams
  `onProgressUpdated` (`Stream<double>`), `onProgressDetail`
  (`Stream<CompressionProgress>`, both mapped from one shared `compression/stream`
  broadcast) and `onBatchUpdate` (`Stream<BatchEvent>`);
  `_resultFromMap` (the decoder shared by the batch return value and
  `BatchItemCompleted` events); the wire decoders `_videoFormatFromWire` /
  `_failureTypeFromWire`; the failure→exception mappers `_exceptionFor` (compress)
  and `_mapPlatformException` (the introspection methods); and the `VideoQuality` enum.
- **[`src/compression_result.dart`](lib/src/compression_result.dart)** — the
  `Result` type and its `OnSuccess` / `OnFailure` / `OnCancelled` subtypes (the
  `OnSuccess` carries `usedFormat`, `targetSizeMet`, and `passesUsed`), plus
  the `CompressionFailureType` enum.
- **[`src/compression_progress.dart`](lib/src/compression_progress.dart)** — the
  `CompressionProgress` model (`percent` + `bytesProcessed` / `etaMs` /
  `elapsedMs`) behind `onProgressDetail`; its `fromEvent` accepts both the map
  wire and a bare-`double` percent (back-compat).
- **[`src/batch_event.dart`](lib/src/batch_event.dart)** — `BatchEvent` with
  `BatchProgress` and `BatchItemCompleted`.
- **[`src/media_info.dart`](lib/src/media_info.dart)** — `MediaInfo` + `fromMap`;
  exposes encoded `width`/`height` and rotation-aware `displayWidth`/`displayHeight`.
- **[`src/compression_estimate.dart`](lib/src/compression_estimate.dart)** —
  `CompressionEstimate` + `fromMap`: the pre-flight prediction returned by
  `getCompressionEstimate` (`estimatedSizeBytes`, `targetBitrate`, output
  dimensions, `estimatedRatio`), computed natively from metadata with no transcode.
- **[`src/thumbnail_request.dart`](lib/src/thumbnail_request.dart)** —
  `ThumbnailRequest` (`positionInMs`, `quality`) + `toMap()`, the per-frame input
  to the batch `getVideoThumbnails`.
- **[`src/exceptions.dart`](lib/src/exceptions.dart)** — `LightCompressorException`
  base + `PermissionDeniedException`, `UnsupportedVideoException`,
  `VideoNotFoundException`, `MediaInfoException`, `ThumbnailException`.
- **Option models** — [`src/video.dart`](lib/src/video.dart) (output name +
  `videoBitrateInMbps` / `targetSizeMb` / `videoFps` / `twoPass`),
  [`src/audio_config.dart`](lib/src/audio_config.dart) (`AudioConfig` —
  `bitrate` / `sampleRate`), [`src/video_edit.dart`](lib/src/video_edit.dart)
  (`VideoEdit` — `trimStartMs` / `trimEndMs` / `rotationDegrees` +
  `brightness` / `contrast` / `saturation` (clamped in `toMap()`); the top-level
  `edit:` param on both entry points),
  [`src/video_format.dart`](lib/src/video_format.dart)
  (`VideoFormat { h264, h265 }`),
  [`src/android_config.dart`](lib/src/android_config.dart) (`AndroidConfig` +
  `SaveAt`), [`src/ios_config.dart`](lib/src/ios_config.dart) (`IOSConfig`),
  [`src/background_config.dart`](lib/src/background_config.dart) (`BackgroundConfig`
  with `toMap()` — the shape the natives parse).

**Behaviour to preserve:**

- **Argument-map keys are the contract.** The keys passed to `invokeMethod`
  (`videoName`, `isMinBitrateCheckEnabled`, `saveAt`, `videoFormat`, `background`,
  the output-control keys `targetSizeBytes` / `videoFps` / `audioBitrate` /
  `audioSampleRate` / `twoPass`, the nested `edit` map
  (`trimStartMs` / `trimEndMs` / `rotationDegrees`), the batch-only
  `maxConcurrent`, and the opt-in `debugLogging`, …) must match the keys the
  natives read via
  `call.argument(...)` / `args[...]`. Renaming a key here means renaming it in all
  three natives.
- **Two failure-delivery modes, kept distinct:** `compressVideo` /
  `compressVideos` *throw* a typed exception only for a **classified** failure
  (via `_exceptionFor`) and otherwise *return* `OnFailure` (batch slots never
  throw); the introspection methods (`getMediaInfo`, `getVideoThumbnail`,
  `getVideoThumbnails`, `getCompressionEstimate`) *always throw* on error
  (mapping a native `PlatformException` code).
- **Defensive numeric parsing** — channel numbers arrive as `int` or `double`
  unpredictably; always coerce with `(x as num?)?.toDouble()` / `.toInt()`.
- `compressVideos` short-circuits an empty `paths` list to `[]` and asserts
  `paths.length == videoNames.length` before touching the channel.

---

## Android layer — [`android/`](android/)

Two distinct parts: a thin Flutter **bridge** and a vendored **transcode engine**.

**Bridge** — [`LightCompressorPlugin.kt`](android/src/main/kotlin/com/gurfdev/light_compressor_v2/LightCompressorPlugin.kt)
implements `MethodCallHandler` + `EventChannel.StreamHandler` + `ActivityAware`.
It parses the argument map, requests storage permission in an API-level-aware way
(`READ_MEDIA_VIDEO` on API 33+, `READ/WRITE_EXTERNAL_STORAGE` on legacy), drives
`VideoCompressor.start`, and marshals the `CompressionListener` callbacks into
result maps (via `replyOnce` for single / per-index `record` for batch). It also
implements `getMediaInfo` / `getVideoThumbnail` / `getVideoThumbnails` with
`MediaMetadataRetriever` on a worker thread, `getCompressionEstimate` (the
size/bitrate prediction, computed here from metadata), `isCompressing`
(delegating to `VideoCompressor.isCompressing()`), and `clearCache` (deletes
`.mp4`/`.jpg` from the app cache dir).

**Engine** — [`lightcompressorlibrary/`](android/src/main/kotlin/com/gurfdev/light_compressor_v2/lightcompressorlibrary/),
a vendored fork of the LightCompressor library:

- [`VideoCompressor.kt`](android/src/main/kotlin/com/gurfdev/light_compressor_v2/lightcompressorlibrary/VideoCompressor.kt)
  — entry `object` (a `MainScope` coroutine scope). `start()` validates, then
  `doVideoCompression()` launches one `Dispatchers.IO` coroutine per URI, **bounded
  by a `Semaphore` sized from `Configuration.maxConcurrent` (coerced `>= 1`), or
  `MAX_CONCURRENT_COMPRESSIONS = 2` when unset** — running a whole batch in
  parallel oversubscribes the hardware codecs and surfaces as "Surface frame wait
  timed out". `cancel()` flips `isRunning = false` and cancels all jobs.
  `classifyThrowable` maps `SecurityException`→`PERMISSION`,
  `FileNotFoundException`→`NOT_FOUND`, else `UNKNOWN`. Also defines the
  `VideoQuality` and `VideoFormat` enums.
- [`compressor/Compressor.kt`](android/src/main/kotlin/com/gurfdev/light_compressor_v2/lightcompressorlibrary/compressor/Compressor.kt)
  — the actual decode→GL→encode→`MediaMuxer` pipeline; the `@Volatile isRunning`
  flag lives here. Also home to the target-size bitrate solver
  (`MIN_BITRATE` floor), frame-dropping for `videoFps`, the AAC audio re-encode
  (`transcodeAudioToBuffer` + muxer track ordering), and the two-pass corrective
  loop (`TWO_PASS_TOLERANCE`, a fresh `MediaExtractor` per pass, temp-file replace).
  Native editing: trim — `seekTo(trimStartUs)`, drop-before / EOS-after the range in
  the decode loop, PTS rebased to 0 (video + both audio paths) — rotate, as a
  `setOrientationHint` applied *after* the source-rotation normalization — and
  colour, baked by the `TextureRenderer` fragment shader (identity uniforms when
  no colour, so it stays free).
  **Large-file note:** `transcodeAudioToBuffer` spills the re-encoded AAC to a
  temp file (in the cache dir, deleted when compression finishes; re-read for
  each two-pass run) and `writeBufferedAudio` streams it into the muxer, so the
  AAC re-encode path's memory stays flat regardless of audio *duration* — it
  can't write straight to the muxer because `MediaMuxer` needs the audio format
  before `start()`. The remaining large-file limit: `MediaMuxer`'s MP4 writer
  uses 32-bit box offsets, so outputs near **4 GB** can fail/truncate (documented
  in the README's "Large files & memory"). (The size/bitrate/PTS math is
  `Long`/`Double`; only Apple's `getMediaInfo` had a 32-bit `fileSize`
  truncation, since fixed via `int64Value`.)
- [`config/Configuration.kt`](android/src/main/kotlin/com/gurfdev/light_compressor_v2/lightcompressorlibrary/config/Configuration.kt)
  — the `Configuration` settings data class **and** the `StorageConfiguration`
  strategies that decide where output lands: `SharedStorageConfiguration`
  (MediaStore), `AppSpecificStorageConfiguration` (app `filesDir`),
  `CacheStorageConfiguration`, plus the `SaveLocation` enum.
  [`config/VideoResizer.kt`](android/src/main/kotlin/com/gurfdev/light_compressor_v2/lightcompressorlibrary/config/VideoResizer.kt)
  is the output-resolution math (`auto` / `scale` / `limitSize` / `matchSize`).
- [`video/InputSurface.kt`](android/src/main/kotlin/com/gurfdev/light_compressor_v2/lightcompressorlibrary/video/InputSurface.kt),
  [`OutputSurface.kt`](android/src/main/kotlin/com/gurfdev/light_compressor_v2/lightcompressorlibrary/video/OutputSurface.kt),
  [`TextureRenderer.kt`](android/src/main/kotlin/com/gurfdev/light_compressor_v2/lightcompressorlibrary/video/TextureRenderer.kt)
  — the EGL/OpenGL surfaces (EGL14 context + `SurfaceTexture` + GLES2 shaders)
  that pipe decoder output into encoder input.
  [`video/Result.kt`](android/src/main/kotlin/com/gurfdev/light_compressor_v2/lightcompressorlibrary/video/Result.kt)
  is the internal transcode result.
  [`video/FrameGrabber.kt`](android/src/main/kotlin/com/gurfdev/light_compressor_v2/lightcompressorlibrary/video/FrameGrabber.kt)
  is the thumbnail fallback when `MediaMetadataRetriever` cannot decode a frame
  (Dolby Vision / 10-bit): the compressor's own decode → SurfaceTexture → GL
  path, drawn into an RGBA `ImageReader`.
- [`utils/`](android/src/main/kotlin/com/gurfdev/light_compressor_v2/lightcompressorlibrary/utils/)
  — `CompressorUtils.kt` (bitrate / codec-capability / track helpers: `getBitrate`,
  `findTrack`, `isHevcHardwareEncoderAvailable`, `setOutputFileParameters`, …),
  `FileUtils.kt` (the `saveVideoInExternal` MediaStore writer used by shared
  storage), `NumbersUtils.kt` (dimension rounding).
- [`CompressionInterface.kt`](android/src/main/kotlin/com/gurfdev/light_compressor_v2/lightcompressorlibrary/CompressionInterface.kt)
  — the threading-annotated `CompressionListener` and the `CompressionErrorType`
  enum with `toWireValue()` (the source of the `failureType` strings).

**Background execution** —
[`CompressionForegroundService.kt`](android/src/main/kotlin/com/gurfdev/light_compressor_v2/CompressionForegroundService.kt)
(ongoing notification with live progress + a Cancel action) and
[`CompressionCancelReceiver.kt`](android/src/main/kotlin/com/gurfdev/light_compressor_v2/CompressionCancelReceiver.kt),
both declared in
[`AndroidManifest.xml`](android/src/main/AndroidManifest.xml) along with the
foreground-service / notification permissions.

**Build** — Kotlin DSL ([`build.gradle.kts`](android/build.gradle.kts)), **minSdk 24**.
Built through the example app, not standalone. The floor stays 24 **by toolchain**:
recent Flutter's Gradle dependency checker *errors* an app `minSdk < 23` and
*warns* `< 24`, with no opt-out — so lowering the plugin below 24 cannot help any
consumer on a current Flutter. The `Build.VERSION.SDK_INT` runtime gates all have
correct ≤22 fallbacks (so the engine *runs* on 21+), but it is **not lint-clean
below 29**: `lint` at minSdk 21 reports harmless `InlinedApi` constants
(`KEY_LEVEL`, `KEY_COLOR_*`, MediaStore `RELATIVE_PATH` / `IS_PENDING` /
`VOLUME_EXTERNAL_PRIMARY`) **and** one real `NewApi` error —
`MediaStore.Downloads.EXTERNAL_CONTENT_URI` (API 29) in
`FileUtils.saveVideoInExternal`, runtime-safe only because its caller gates
`SDK_INT >= Q` (a guard lint can't see). Do not lower the floor without
re-checking the Flutter threshold **and** running the plugin's `lint` (it would
first need `@RequiresApi` annotations on the MediaStore writer).

**SDK/Flutter floor (`pubspec.yaml`)** — the package declares `sdk: ^3.5.0` /
`flutter: ">=3.24.0"`. The Dart code alone only needs 3.0 (`sealed class` in
[`batch_event.dart`](lib/src/batch_event.dart)); the binding floor is the **native
build** — `compileSdk 34` above needs **AGP 8.1.1+** (stock from ~Flutter 3.16),
and 3.24 is the SwiftPM baseline. Don't drop below 3.24 without re-checking both: a
lower value (e.g. 3.10) lets the Dart resolve but fails a stock Android build.

---

## Apple layers — [`ios/`](ios/) and [`macos/`](macos/)

Each is a SwiftPM package (`…/Package.swift`) **plus** a CocoaPods podspec
(`…/light_compressor_v2.podspec`); Flutter ≥ 3.24 prefers SwiftPM and falls back
to CocoaPods. Sources sit under `…/Sources/light_compressor_v2/`:

- **Bridge** — iOS
  [`SwiftLightCompressorPlugin.swift`](ios/light_compressor_v2/Sources/light_compressor_v2/SwiftLightCompressorPlugin.swift)
  / macOS
  [`LightCompressorPlugin.swift`](macos/light_compressor_v2/Sources/light_compressor_v2/LightCompressorPlugin.swift)
  — registers the three channels, dispatches the methods, applies `replyOnce` /
  per-index `record`, saves to the Photos library when `saveInGallery`, and
  implements `getMediaInfo` / `getVideoThumbnail` / `getVideoThumbnails` /
  `getCompressionEstimate` / `isCompressing` / `clearCache`. A nested
  `BatchStreamHandler` backs the batch EventChannel.
- **Engine** — `LightCompressor.swift` — the `AVFoundation` transcoder:
  `AVAssetReader` → `AVAssetWriter` (created with `fileType: .mp4` so the
  container matches the `.mp4` name), quality→bitrate math, HEVC selection with
  silent H.264 fallback, progress + completion callbacks, the typed `MediaError`,
  the static `mediaInfo` / `thumbnail` / `clearCache` helpers, and the
  `estimate(...)` behind `getCompressionEstimate`. The `cancel` flag rides on the
  returned `Compression` handle. It also has the target-size solver, frame-dropping
  for `videoFps`, the AAC audio re-encode, and the two-pass corrective loop — the
  transcode body is factored into a re-callable `encodePass(...)` (each pass streams
  0..<100, so the terminal signal is the result, never a mid-stream 100) driven from
  the pass-1 completion. Native editing: trim — each reader's `timeRange` + a
  `startSession(atSourceTime:)` at the range start (output rebased to 0; reported
  duration = trimmed) — rotate, by composing the quarter-turn onto
  `videoWriterInput.transform` — and colour, by reading through an
  `AVAssetReaderVideoCompositionOutput` driven by a `CIColorControls` filter
  (only when a colour knob is set; otherwise the cheap track output).
  **Batch throttling:** `compressVideo(videos:)` no longer starts every
  video at once — the per-video work moved into a nested `startVideo(...)` driven
  by an async pump on a private serial scheduler that keeps at most
  `maxConcurrent` (`?? count`, so unset = start-all) in flight, each finishing
  video freeing its slot via a single `onDone` funnel; the method still returns
  the `Compression` handle immediately.
- **`extensions/Encodable.swift`** — the `toJson` used to encode the
  single-compress reply.

> **Sync rule (important).** The **engine** (`LightCompressor.swift`) and
> `extensions/Encodable.swift` are **byte-identical** between `ios/` and `macos/`
> — edit the iOS copy, then copy it verbatim to macOS. The **plugin files are
> NOT identical** and must be edited per-platform: macOS imports `FlutterMacOS`
> (vs `Flutter`), is named `LightCompressorPlugin` (vs `SwiftLightCompressorPlugin`),
> is written in an older inlined style, and adds a macOS-only `BackgroundExecution`
> class. **Never blind-copy the plugin file across platforms.**

**Optional channel arguments (Apple):** read them as `args[key] as? T`, never
`as? T?` inside an `if let` chain. A Dart `null` arrives as `NSNull`, and since
the OS 27 runtimes `NSNull as? Int?` no longer yields `.some(nil)` — the binding
fails. That once made the macOS `startCompression` reject every call with
`INVALID_ARGS` with no change in our code.

**Background behaviour differs by design:** iOS has **no** background support
(the OS suspends transcoding); macOS suppresses **App Nap** via
`BackgroundExecution` (`ProcessInfo.beginActivity(.idleSystemSleepDisabled)`) when
a `BackgroundConfig` is passed — its notification fields are ignored.

**Minimum versions:** iOS 11, macOS 10.15. Photo-library save needs
`NSPhotoLibraryUsageDescription` in the host app's Info.plist.

---

## Example app & integration tests — [`example/`](example/)

The demo app is also the only place the native pipeline runs end-to-end.

- **App** — [`lib/main.dart`](example/lib/main.dart),
  [`lib/single_compress_view.dart`](example/lib/single_compress_view.dart),
  [`lib/batch_compress_view.dart`](example/lib/batch_compress_view.dart),
  [`lib/video_player.dart`](example/lib/video_player.dart),
  [`lib/utils/file_utils.dart`](example/lib/utils/file_utils.dart). Uses
  `file_picker` to choose sources and `video_player` to preview output.
- **Integration tests** (run on a real device/emulator/simulator):
  - [`integration_test/plugin_integration_test.dart`](example/integration_test/plugin_integration_test.dart)
    — the main suite: metadata, thumbnails, options, progress streams,
    cancellation, lifecycle, and the *batch resilience* group (one bad path must
    not sink the others; input order preserved).
  - [`integration_test/hevc_compression_test.dart`](example/integration_test/hevc_compression_test.dart)
    — H.264 / H.265 selection and the automatic fallback (`usedFormat`).
  - [`integration_test/preflight_test.dart`](example/integration_test/preflight_test.dart)
    — `getCompressionEstimate`, batch `getVideoThumbnails`, and `isCompressing`
    (the introspection methods).
  - [`integration_test/target_size_test.dart`](example/integration_test/target_size_test.dart),
    [`fps_test.dart`](example/integration_test/fps_test.dart),
    [`audio_test.dart`](example/integration_test/audio_test.dart), and
    [`two_pass_test.dart`](example/integration_test/two_pass_test.dart) — the
    output-control options (target size, frame-rate downsample, AAC audio re-encode
    — plus a PCM-audio `.mov` source, checked by the audio track's size —
    two-pass). The corrective second pass only runs when pass 1 overshoots, so a
    highly compressible clip stays single-pass (`passesUsed == 1`).
  - [`integration_test/edit_test.dart`](example/integration_test/edit_test.dart)
    — the native editing: trim yields an output of ~the requested length (and
    shorter than the source), a 90° rotate swaps the displayed dims vs an
    unrotated baseline (source-agnostic), and `saturation: 0` desaturates the
    output toward grayscale (decoded via `dart:ui`).
  - [`integration_test/input_variety_test.dart`](example/integration_test/input_variety_test.dart)
    — input-variety coverage: no-audio, rotated, and HEVC *input* clips (each
    derived from the sample via the plugin's own pipeline).
  - [`integration_test/hdr_test.dart`](example/integration_test/hdr_test.dart)
    — an iPhone-style HDR source (10-bit HEVC, HLG, Dolby Vision 8.4):
    `MediaInfo.isHdr`, compression to SDR in both codecs (output `isHdr ==
    false`), and a thumbnail.
  - [`integration_test/benchmark_test.dart`](example/integration_test/benchmark_test.dart)
    — **not a correctness test:** runs the matrix (quality presets × H.264/H.265)
    and prints a Markdown table of size-reduction + wall-clock time. Also benchmarks
    large local clips read by device path (`adb push` to the app's external files
    dir) with incremental per-row output — used to capture real benchmark numbers.
  - [`integration_test/support.dart`](example/integration_test/support.dart) —
    shared helpers (e.g. `expectReadableVideo`).
  - `integration_test/assets/sample.mp4` — a short sample clip the tests feed in
    (loaded via `prepareSampleSource()` in `support.dart`). The tests **skip
    cleanly when it is absent or still the committed placeholder** (anything under
    ~5 KB is treated as the placeholder). The clip is excluded from the published
    package — see `.pubignore`. `sample.mp4` is video-only; the other fixtures
    carry what it lacks — `sample_audio.mp4` (AAC), `sample_pcm.mov` (PCM audio)
    and `sample_hdr.mp4` (HDR). The last two are generated natively on macOS by
    the AVFoundation scripts in `integration_test/tools/` (no ffmpeg).

---

## Common commands

```bash
# Dart unit tests (no device needed).
flutter test
flutter test test/models_test.dart                   # one file
flutter test --plain-name "keeps input order"         # one test by name

# Static analysis + formatting (CI gates; both must be clean).
flutter analyze
dart format .                                         # apply
dart format --output=none --set-exit-if-changed .     # check only (as CI runs it)

# Integration tests — REAL native pipeline; require a device/emulator/simulator.
flutter devices
cd example
flutter test integration_test/plugin_integration_test.dart -d <deviceId>
flutter test integration_test/hevc_compression_test.dart   -d <deviceId>

# Run the demo app (also how the native code gets compiled).
cd example && flutter run

# Pre-publish dry run (uses .pubignore, not .gitignore, for the archive).
flutter pub publish --dry-run
```

Native code is built **through the example app** — there is no standalone plugin
build step.

## Conventions & release notes

- **Native codecs only** — never ffmpeg/ffprobe, anywhere, ever (see top).
- **Apple sync rule** — engine + `Encodable.swift` are copy-identical iOS↔macOS;
  plugin files are per-platform (see the Apple section). Enforced by
  [`test/apple_engine_sync_test.dart`](test/apple_engine_sync_test.dart) (runs
  under `flutter test`, so CI fails on drift) — after editing the iOS engine,
  copy it to macOS or this test goes red.
- **Strict lint.** [`analysis_options.yaml`](analysis_options.yaml) enables a
  large explicit rule set (e.g. `always_specify_types`, `prefer_single_quotes`,
  `sort_constructors_first`, `directives_ordering`) — *not* stock `flutter_lints`.
  `flutter analyze` must be clean.
- **Source and code comments are in English** (user-facing communication is in
  Russian).
- **Releasing:** bump the version in [`pubspec.yaml`](pubspec.yaml), add a
  [`CHANGELOG.md`](CHANGELOG.md) entry, and **update the install snippet version
  in [`README.md`](README.md)** (the `light_compressor_v2: ^x.y.z` line — easy to
  forget); [`.pubignore`](.pubignore) (which pub uses *instead of* `.gitignore`)
  controls what ships — it must keep excluding `test/`, `coverage/` and
  `example/test/` (an uncommitted `.pubignore` edit was once lost, so an archive
  shipped `test/`; verify with `flutter pub publish --dry-run`). `git push` and
  `flutter pub publish` are done by the maintainer — the agent environment has no
  git credentials.
- **Commit messages** carry no `Co-Authored-By` / agent-attribution trailer.
