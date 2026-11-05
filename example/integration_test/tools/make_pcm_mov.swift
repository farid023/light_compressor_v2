// Generates integration_test/assets/sample_pcm.mov: a short .mov whose audio
// track is uncompressed 16-bit PCM, the way many cameras and screen recorders
// write it. It exercises the path where the source audio cannot be muxed into
// the .mp4 output as-is and has to be re-encoded.
//
// The picture comes from the SDR clip and is tagged BT.709 explicitly, so this
// fixture tests the audio path only (sample_audio.mp4's picture is HLG-tagged).
//
// Native AVFoundation only (macOS), no ffmpeg:
//
//   cd example
//   swift integration_test/tools/make_pcm_mov.swift \
//     integration_test/assets/sample.mp4 integration_test/assets/sample_audio.mp4 \
//     integration_test/assets/sample_pcm.mov

import AVFoundation

let args = CommandLine.arguments
guard args.count == 4 else {
    print("usage: make_pcm_mov.swift <video-source> <audio-source> <output.mov>")
    exit(2)
}
let videoSource = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let audioSource = AVURLAsset(url: URL(fileURLWithPath: args[2]))
let output = URL(fileURLWithPath: args[3])
try? FileManager.default.removeItem(at: output)

guard let videoTrack = videoSource.tracks(withMediaType: .video).first,
      let audioTrack = audioSource.tracks(withMediaType: .audio).first else {
    print("need a video track in the first source and an audio track in the second")
    exit(1)
}

let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
let videoReader = try AVAssetReader(asset: videoSource)
let audioReader = try AVAssetReader(asset: audioSource)
videoReader.timeRange = range
audioReader.timeRange = range
let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
])
let pcm: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: 44_100,
    AVNumberOfChannelsKey: 2,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
]
let audioOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcm)
videoReader.add(videoOut)
audioReader.add(audioOut)

let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: 640,
    AVVideoHeightKey: 360,
    AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_000_000],
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ],
])
let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
videoIn.expectsMediaDataInRealTime = false
audioIn.expectsMediaDataInRealTime = false
writer.add(videoIn)
writer.add(audioIn)

videoReader.startReading()
audioReader.startReading()
writer.startWriting()
writer.startSession(atSourceTime: .zero)

// Interleave the two tracks so neither input starves the other.
var videoDone = false
var audioDone = false
while !videoDone || !audioDone {
    var progressed = false
    if !videoDone && videoIn.isReadyForMoreMediaData {
        if let buffer = videoOut.copyNextSampleBuffer() {
            videoIn.append(buffer)
        } else {
            videoIn.markAsFinished()
            videoDone = true
        }
        progressed = true
    }
    if !audioDone && audioIn.isReadyForMoreMediaData {
        if let buffer = audioOut.copyNextSampleBuffer() {
            audioIn.append(buffer)
        } else {
            audioIn.markAsFinished()
            audioDone = true
        }
        progressed = true
    }
    if !progressed { usleep(1000) }
}

let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else {
    print("write failed: \(String(describing: writer.error))")
    exit(1)
}
let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size]) ?? 0
print("wrote \(output.path) (\(size) bytes)")
