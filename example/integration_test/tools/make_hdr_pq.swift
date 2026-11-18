// Generates integration_test/assets/sample_hdr_pq.mp4: a short 10-bit HEVC
// clip tagged PQ / BT.2020 (HDR10), converted from the HLG fixture. The reader
// converts HLG to PQ, and the writer adds HDR10 static metadata (mastering
// display and content light level), the way PQ masters usually carry it.
//
// Native AVFoundation only (macOS), no ffmpeg:
//
//   cd example
//   swift integration_test/tools/make_hdr_pq.swift \
//     integration_test/assets/sample_hdr.mp4 integration_test/assets/sample_hdr_pq.mp4

import AVFoundation
import VideoToolbox

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: make_hdr_pq.swift <hlg-source> <output.mp4>")
    exit(2)
}
let source = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let output = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: output)

guard let track = source.tracks(withMediaType: .video).first else {
    print("source has no video track")
    exit(1)
}

let pq: [String: String] = [
    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
    AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
]

let reader = try AVAssetReader(asset: source)
// 10-bit, converted to PQ on the way out of the decoder.
let videoOut = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
    AVVideoColorPropertiesKey: pq,
])
reader.add(videoOut)

// SMPTE ST 2086 mastering display (P3-D65 primaries, 1000 / 0.0001 nits) and
// CTA-861.3 content light level (1000 / 400 nits), big-endian as in the HEVC SEI.
func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
let masteringDisplay = Data(
    be16(13250) + be16(34500) +   // G
    be16(7500) + be16(3000) +     // B
    be16(34000) + be16(16000) +   // R
    be16(15635) + be16(16450) +   // white point D65
    be32(10_000_000) + be32(1))   // max / min luminance (0.0001 nits)
let contentLightLevel = Data(be16(1000) + be16(400))

let size = track.naturalSize
let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: Int(size.width),
    AVVideoHeightKey: Int(size.height),
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 4_000_000,
        AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
        kVTCompressionPropertyKey_MasteringDisplayColorVolume as String: masteringDisplay,
        kVTCompressionPropertyKey_ContentLightLevelInfo as String: contentLightLevel,
    ],
    AVVideoColorPropertiesKey: pq,
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
let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size]) ?? 0
print("wrote \(output.path) (\(bytes) bytes)")
