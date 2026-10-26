// Generates a local, silent H.264 or 4K HEVC fixture for playback checks. Never included in the app.
import AVFoundation
import AppKit
let url = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: url)
let is4K = CommandLine.arguments.contains("--4k")
let width = is4K ? 3840 : 640, height = is4K ? 2160 : 360
let frameCount = is4K ? 600 : (CommandLine.arguments.contains("--long") ? 720 : 240)
let frameRate: Int32 = is4K ? 30 : 24
let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
writer.shouldOptimizeForNetworkUse = true
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: (is4K ? AVVideoCodecType.hevc : AVVideoCodecType.h264), AVVideoWidthKey: width, AVVideoHeightKey: height])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
for frame in 0..<frameCount {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    let b = buffer!; CVPixelBufferLockBaseAddress(b, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(b), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(b), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    ctx.setFillColor(CGColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 1, green: 0.4, blue: 0.31, alpha: 1)); ctx.fillEllipse(in: CGRect(x: (frame * (is4K ? 12 : 2)) % (width - 100), y: height / 2 - 50, width: 100, height: 100))
    CVPixelBufferUnlockBaseAddress(b, [])
    precondition(adaptor.append(b, withPresentationTime: CMTime(value: Int64(frame), timescale: frameRate)))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }; done.wait()
if writer.status != .completed { throw writer.error! }
print("Created local \(width)x\(height) \(is4K ? "HEVC" : "H.264") playback fixture")
