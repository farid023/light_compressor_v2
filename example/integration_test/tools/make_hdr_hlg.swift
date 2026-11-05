// Generates integration_test/assets/sample_hdr.mp4: a short 10-bit HEVC clip
// tagged HLG / BT.2020, the way an iPhone records HDR video. Feed it an
// iPhone HDR recording; the picture is scaled to 720p and cut to 2 s so the
// fixture stays small. Audio is left out.
//
// Native AVFoundation only (macOS), no ffmpeg:
//
//   cd example
//   swift integration_test/tools/make_hdr_hlg.swift <iphone-hdr.MOV> \
//     integration_test/assets/sample_hdr.mp4

import AVFoundation
import VideoToolbox

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: make_hdr_hlg.swift <hdr-source> <output.mp4>")
    exit(2)
}
let source = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let output = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: output)

guard let track = source.tracks(withMediaType: .video).first else {
    print("source has no video track")
    exit(1)
}

let reader = try AVAssetReader(asset: source)
reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
// Read 10-bit so the HLG signal is not quantised on the way through.
let videoOut = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
])
reader.add(videoOut)

let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: 1280,
    AVVideoHeightKey: 720,
    AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 4_000_000,
        AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
    ],
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
    ],
])
videoIn.expectsMediaDataInRealTime = false
videoIn.transform = track.preferredTransform
writer.add(videoIn)

reader.startReading()
writer.startWriting()
writer.startSession(atSourceTime: .zero)
while true {
    if !videoIn.isReadyForMoreMediaData {
        usleep(1000)
        continue
    }
    guard let buffer = videoOut.copyNextSampleBuffer() else { break }
    videoIn.append(buffer)
}
videoIn.markAsFinished()

let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else {
    print("write failed: \(String(describing: writer.error))")
    exit(1)
}
let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size]) ?? 0
print("wrote \(output.path) (\(size) bytes)")
