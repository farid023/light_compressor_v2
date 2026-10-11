import Flutter
import Photos

/// Flutter plugin that bridges the `LightCompressor` Swift library to Dart.
public class SwiftLightCompressorPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    // MARK: - Properties

    private var eventSink: FlutterEventSink?
    private var compression: Compression?
    private var running = false
    private let batchStreamHandler = BatchStreamHandler()

    // MARK: - FlutterPlugin

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "light_compressor",
            binaryMessenger: registrar.messenger())
        let instance = SwiftLightCompressorPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)

        let eventChannel = FlutterEventChannel(
            name: "compression/stream",
            binaryMessenger: registrar.messenger())
        eventChannel.setStreamHandler(instance)

        let batchChannel = FlutterEventChannel(
            name: "compression/batch-stream",
            binaryMessenger: registrar.messenger())
        batchChannel.setStreamHandler(instance.batchStreamHandler)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startCompression":
            startCompression(call: call, result: result)
        case "startBatchCompression":
            startBatchCompression(call: call, result: result)
        case "cancelCompression":
            compression?.cancel = true
            // Reply so the Dart-side Future completes; the outcome is delivered
            // as onCancelled on the pending compression call.
            result(nil)
        case "clearCache":
            clearCache(result: result)
        case "getMediaInfo":
            getMediaInfo(call: call, result: result)
        case "getVideoThumbnail":
            getVideoThumbnail(call: call, result: result)
        case "getVideoThumbnails":
            getVideoThumbnails(call: call, result: result)
        case "getCompressionEstimate":
            getCompressionEstimate(call: call, result: result)
        case "isCompressing":
            result(running)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - Private

    private func startCompression(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard
            let args                  = call.arguments as? [String: Any?],
            let path                  = args["path"]                  as? String,
            let videoName             = args["videoName"]             as? String,
            let isMinBitrateEnabled   = args["isMinBitrateCheckEnabled"] as? Bool,
            let disableAudio          = args["disableAudio"]          as? Bool,
            let saveInGallery         = args["saveInGallery"]         as? Bool,
            let keepOriginalResolution = args["keepOriginalResolution"] as? Bool,
            let videoQuality          = args["videoQuality"]          as? String
        else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "One or more required arguments are missing or have an invalid type.",
                details: nil))
            return
        }

        // Optional arguments
        let videoBitrateInMbps = (args["videoBitrateInMbps"] as? NSNumber)?.doubleValue
        let videoHeight        = args["videoHeight"]        as? Int
        let videoWidth         = args["videoWidth"]         as? Int
        let targetSizeBytes    = args["targetSizeBytes"]    as? Int
        let videoFps           = args["videoFps"]           as? Int
        let audioBitrate       = args["audioBitrate"]       as? Int
        let audioSampleRate    = args["audioSampleRate"]    as? Int
        let twoPass            = args["twoPass"]            as? Bool ?? false
        let edit               = args["edit"]               as? [String: Any]

        let destinationURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(videoName).mp4")
        try? FileManager.default.removeItem(at: destinationURL)

        let videoSize: CGSize? = videoWidth != nil && videoHeight != nil
            ? CGSize(width: videoWidth!, height: videoHeight!)
            : nil

        // A FlutterResult may be delivered only once. Cancellation can race with
        // completion (onCancelled is signalled from a background queue), so funnel
        // every terminal reply through this guard on the main thread.
        var didReply = false
        let replyOnce: (Any?) -> Void = { [weak self] payload in
            DispatchQueue.main.async {
                guard !didReply else { return }
                didReply = true
                self?.running = false
                result(payload)
            }
        }

        let videoFormat = VideoFormat.from(wire: args["videoFormat"] as? String)

        running = true
        compression = LightCompressor().compressVideo(
            videos: [
                .init(
                    source: URL(fileURLWithPath: path),
                    destination: destinationURL,
                    configuration: .init(
                        quality: getVideoQuality(quality: videoQuality),
                        isMinBitrateCheckEnabled: isMinBitrateEnabled,
                        videoBitrateInMbps: videoBitrateInMbps,
                        disableAudio: disableAudio,
                        keepOriginalResolution: keepOriginalResolution,
                        videoSize: videoSize,
                        videoFormat: videoFormat,
                        targetSizeBytes: targetSizeBytes,
                        videoFps: videoFps,
                        audioBitrate: audioBitrate,
                        audioSampleRate: audioSampleRate,
                        twoPass: twoPass,
                        trimStartMs: edit?["trimStartMs"] as? Int,
                        trimEndMs: edit?["trimEndMs"] as? Int,
                        rotationDegrees: edit?["rotationDegrees"] as? Int,
                        brightness: edit?["brightness"] as? Double,
                        contrast: edit?["contrast"] as? Double,
                        saturation: edit?["saturation"] as? Double,
                        debugLogging: args["debugLogging"] as? Bool ?? false))
            ],
            progressQueue: .main,
            progressHandler: { [weak self] _, progress in
                guard let self else { return }
                if let eventSink, progress.percent <= 100 {
                    eventSink([
                        "percent": progress.percent,
                        "bytesProcessed": progress.bytesProcessed,
                        "etaMs": progress.etaMs,
                        "elapsedMs": progress.elapsedMs,
                    ])
                }
            },
            completion: { compressionResult in
                // completion is already dispatched to main in LightCompressor
                switch compressionResult {
                case .onStart:
                    break

                case .onSuccess(let index, let url, let duration, let usedFormat, let targetSizeMet, let passesUsed):
                    if saveInGallery {
                        PHPhotoLibrary.shared().performChanges {
                            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                        }
                    }
                    let originalSize = (try? FileManager.default
                        .attributesOfItem(atPath: path))?[.size] as? Int ?? 0
                    let compressedSize = (try? FileManager.default
                        .attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
                    struct SuccessResponse: Encodable {
                        let onSuccess: String
                        let index: String
                        let duration: Double
                        let originalSize: Int
                        let compressedSize: Int
                        let usedFormat: String
                        let targetSizeMet: Bool
                        let passesUsed: Int
                    }
                    let response = SuccessResponse(
                        onSuccess: url.path,
                        index: String(index),
                        duration: duration,
                        originalSize: originalSize,
                        compressedSize: compressedSize,
                        usedFormat: usedFormat.wireValue,
                        targetSizeMet: targetSizeMet,
                        passesUsed: passesUsed
                    )
                    replyOnce(response.toJson)

                case .onFailure(let index, let error):
                    let response: [String: String] = [
                        "onFailure": error.title,
                        "index": String(index),
                        "failureType": error.type.rawValue,
                    ]
                    replyOnce(response.toJson)

                case .onCancelled:
                    let response: [String: Bool] = ["onCancelled": true]
                    replyOnce(response.toJson)
                }
            }
        )
    }

    private func startBatchCompression(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard
            let args                   = call.arguments as? [String: Any?],
            let paths                  = args["paths"]                  as? [String],
            let videoNames             = args["videoNames"]             as? [String],
            let isMinBitrateEnabled    = args["isMinBitrateCheckEnabled"] as? Bool,
            let disableAudio           = args["disableAudio"]           as? Bool,
            let saveInGallery          = args["saveInGallery"]          as? Bool,
            let keepOriginalResolution = args["keepOriginalResolution"] as? Bool,
            let videoQuality           = args["videoQuality"]           as? String,
            paths.count == videoNames.count
        else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing or mismatched batch arguments.",
                details: nil))
            return
        }
        if paths.isEmpty {
            result([])
            return
        }

        let videoBitrateInMbps = (args["videoBitrateInMbps"] as? NSNumber)?.doubleValue
        let targetSizeBytes    = args["targetSizeBytes"]    as? Int
        let videoFps           = args["videoFps"]           as? Int
        let audioBitrate       = args["audioBitrate"]       as? Int
        let audioSampleRate    = args["audioSampleRate"]    as? Int
        let twoPass            = args["twoPass"]            as? Bool ?? false
        let edit               = args["edit"]               as? [String: Any]
        let videoHeight        = args["videoHeight"]        as? Int
        let videoWidth         = args["videoWidth"]         as? Int
        let videoSize: CGSize? = videoWidth != nil && videoHeight != nil
            ? CGSize(width: videoWidth!, height: videoHeight!)
            : nil

        let configuration = LightCompressor.Video.Configuration(
            quality: getVideoQuality(quality: videoQuality),
            isMinBitrateCheckEnabled: isMinBitrateEnabled,
            videoBitrateInMbps: videoBitrateInMbps,
            disableAudio: disableAudio,
            keepOriginalResolution: keepOriginalResolution,
            videoSize: videoSize,
            videoFormat: VideoFormat.from(wire: args["videoFormat"] as? String),
            targetSizeBytes: targetSizeBytes,
            videoFps: videoFps,
            audioBitrate: audioBitrate,
            audioSampleRate: audioSampleRate,
            twoPass: twoPass,
            trimStartMs: edit?["trimStartMs"] as? Int,
            trimEndMs: edit?["trimEndMs"] as? Int,
            rotationDegrees: edit?["rotationDegrees"] as? Int,
            brightness: edit?["brightness"] as? Double,
            contrast: edit?["contrast"] as? Double,
            saturation: edit?["saturation"] as? Double,
            maxConcurrent: args["maxConcurrent"] as? Int,
            debugLogging: args["debugLogging"] as? Bool ?? false)

        let count = paths.count
        var videos: [LightCompressor.Video] = []
        for i in 0..<count {
            let destination = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("\(videoNames[i]).mp4")
            try? FileManager.default.removeItem(at: destination)
            videos.append(.init(
                source: URL(fileURLWithPath: paths[i]),
                destination: destination,
                configuration: configuration))
        }

        var results = [[String: Any]?](repeating: nil, count: count)
        var percents = [Double](repeating: 0, count: count)
        var completed = 0

        // Records a video's outcome on the main thread, emits a per-item event,
        // and resolves the method result once every video has reported.
        func record(_ index: Int, _ map: [String: Any]) {
            DispatchQueue.main.async {
                guard index >= 0, index < count, results[index] == nil else { return }
                results[index] = map
                completed += 1
                var event = map
                event["type"] = "result"
                event["index"] = index
                self.batchStreamHandler.eventSink?(event)
                if completed == count {
                    self.running = false
                    result(results.map { $0 ?? ["onFailure": "Unknown error"] })
                }
            }
        }

        running = true
        compression = LightCompressor().compressVideo(
            videos: videos,
            progressQueue: .main,
            progressHandler: { [weak self] index, progress in
                guard let self else { return }
                if index >= 0, index < count {
                    percents[index] = progress.percent
                }
                let overall = percents.reduce(0, +) / Double(count)
                self.batchStreamHandler.eventSink?([
                    "type": "progress",
                    "index": index,
                    "percent": progress.percent,
                    "overallPercent": overall,
                    "bytesProcessed": progress.bytesProcessed,
                    "etaMs": progress.etaMs,
                    "elapsedMs": progress.elapsedMs,
                ])
            },
            completion: { compressionResult in
                switch compressionResult {
                case .onStart:
                    break

                case .onSuccess(let index, let url, let duration, let usedFormat, let targetSizeMet, let passesUsed):
                    if saveInGallery {
                        PHPhotoLibrary.shared().performChanges {
                            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                        }
                    }
                    let originalSize = (try? FileManager.default
                        .attributesOfItem(atPath: paths[index]))?[.size] as? Int ?? 0
                    let compressedSize = (try? FileManager.default
                        .attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
                    record(index, [
                        "onSuccess": url.path,
                        "originalSize": originalSize,
                        "compressedSize": compressedSize,
                        "duration": duration,
                        "usedFormat": usedFormat.wireValue,
                        "targetSizeMet": targetSizeMet,
                        "passesUsed": passesUsed,
                    ])

                case .onFailure(let index, let error):
                    record(index, [
                        "onFailure": error.title,
                        "failureType": error.type.rawValue,
                    ])

                case .onCancelled:
                    // onCancelled carries no index; mark every video that has not
                    // finished yet as cancelled so the batch can complete.
                    for i in 0..<count {
                        record(i, ["onCancelled": true])
                    }
                }
            }
        )
    }

    /// Maps a quality string received from Dart to a `VideoQuality` enum value.
    private func getVideoQuality(quality: String) -> VideoQuality {
        switch quality {
        case "very_low":  return .very_low
        case "low":       return .low
        case "medium":    return .medium
        case "high":      return .high
        case "very_high": return .very_high
        default:          return .medium
        }
    }

    private func clearCache(result: @escaping FlutterResult) {
        do {
            try LightCompressor.clearCache()
            result(true)
        } catch {
            result(FlutterError(code: "CLEAR_CACHE_FAILED", message: error.localizedDescription, details: nil))
        }
    }

    private func getMediaInfo(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any?],
              let path = args["path"] as? String else {
            result(FlutterError(code: "VIDEO_NOT_FOUND", message: "No video path was provided.", details: nil))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let info = try LightCompressor.mediaInfo(for: path)
                DispatchQueue.main.async { result(info) }
            } catch {
                DispatchQueue.main.async {
                    result(Self.flutterError(from: error, fallbackCode: "MEDIA_INFO_FAILED"))
                }
            }
        }
    }

    private func getVideoThumbnail(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any?],
              let path = args["path"] as? String else {
            result(FlutterError(code: "VIDEO_NOT_FOUND", message: "No video path was provided.", details: nil))
            return
        }
        let positionInMs = (args["positionInMs"] as? Int) ?? 0
        let quality = (args["quality"] as? Int) ?? 50
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let thumbPath = try LightCompressor.thumbnail(
                    for: path, positionInMs: positionInMs, quality: quality)
                DispatchQueue.main.async { result(thumbPath) }
            } catch {
                DispatchQueue.main.async {
                    result(Self.flutterError(from: error, fallbackCode: "THUMBNAIL_FAILED"))
                }
            }
        }
    }

    private func getVideoThumbnails(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any?],
              let path = args["path"] as? String else {
            result(FlutterError(code: "VIDEO_NOT_FOUND", message: "No video path was provided.", details: nil))
            return
        }
        let requests = (args["requests"] as? [[String: Any]]) ?? []
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let paths = try LightCompressor.thumbnails(for: path, requests: requests)
                DispatchQueue.main.async { result(paths) }
            } catch {
                DispatchQueue.main.async {
                    result(Self.flutterError(from: error, fallbackCode: "THUMBNAIL_FAILED"))
                }
            }
        }
    }

    private func getCompressionEstimate(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any?],
              let path = args["path"] as? String,
              let videoQuality = args["videoQuality"] as? String else {
            result(FlutterError(code: "VIDEO_NOT_FOUND", message: "No video path was provided.", details: nil))
            return
        }
        let quality = getVideoQuality(quality: videoQuality)
        let keepOriginalResolution = (args["keepOriginalResolution"] as? Bool) ?? false
        let disableAudio = (args["disableAudio"] as? Bool) ?? false
        let videoBitrateInMbps = (args["videoBitrateInMbps"] as? NSNumber)?.doubleValue
        let videoWidth = args["videoWidth"] as? Int
        let videoHeight = args["videoHeight"] as? Int
        let videoSize: CGSize? = videoWidth != nil && videoHeight != nil
            ? CGSize(width: videoWidth!, height: videoHeight!)
            : nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let estimate = try LightCompressor().estimate(
                    for: path,
                    quality: quality,
                    keepOriginalResolution: keepOriginalResolution,
                    videoSize: videoSize,
                    videoBitrateInMbps: videoBitrateInMbps,
                    disableAudio: disableAudio)
                DispatchQueue.main.async { result(estimate) }
            } catch {
                DispatchQueue.main.async {
                    result(Self.flutterError(from: error, fallbackCode: "ESTIMATE_FAILED"))
                }
            }
        }
    }

    /// Maps a thrown error to a FlutterError, preferring a typed `MediaError`
    /// code and falling back to [fallbackCode] for anything else.
    private static func flutterError(from error: Error, fallbackCode: String) -> FlutterError {
        if let mediaError = error as? MediaError {
            return FlutterError(code: mediaError.code, message: mediaError.message, details: nil)
        }
        return FlutterError(code: fallbackCode, message: error.localizedDescription, details: nil)
    }
}

/// Stream handler for the batch progress/result EventChannel
/// (`compression/batch-stream`).
final class BatchStreamHandler: NSObject, FlutterStreamHandler {
    var eventSink: FlutterEventSink?

    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
