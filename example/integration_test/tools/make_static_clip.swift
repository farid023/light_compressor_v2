// Generates integration_test/assets/sample_static.mp4: 4 s of one unchanging
// frame (the first frame of the source), the near-static end of the content
// range for the constant-quality measurements. Encoded at a high bitrate so
// the frame itself stays clean.
//
// Native AVFoundation only (macOS), no ffmpeg:
//
//   cd example
//   swift integration_test/tools/make_static_clip.swift \
//     integration_test/assets/sample.mp4 integration_test/assets/sample_static.mp4

import AVFoundation

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: make_static_clip.swift <source> <output.mp4>")
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
let frameOut = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
])
reader.add(frameOut)
reader.startReading()
guard let first = frameOut.copyNextSampleBuffer(),
      let frame = CMSampleBufferGetImageBuffer(first) else {
    print("could not read the first frame")
    exit(1)
}
reader.cancelReading()

let size = track.naturalSize
let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: Int(size.width),
    AVVideoHeightKey: Int(size.height),
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ],
])
videoIn.expectsMediaDataInRealTime = false
videoIn.transform = track.preferredTransform
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: nil)
writer.add(videoIn)

writer.startWriting()
writer.startSession(atSourceTime: .zero)
let fps: Int32 = 30
for i in 0..<(4 * Int64(fps)) {
    while !videoIn.isReadyForMoreMediaData { usleep(1000) }
    adaptor.append(frame, withPresentationTime: CMTime(value: i, timescale: fps))
}
videoIn.markAsFinished()

let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else {
    print("write failed: \(String(describing: writer.error))")
    exit(1)
}
let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size]) ?? 0
print("wrote \(output.path) (\(bytes) bytes)")
