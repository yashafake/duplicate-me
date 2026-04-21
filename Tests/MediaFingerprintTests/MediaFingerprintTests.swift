import AVFoundation
import CoreGraphics
import Foundation
import MediaFingerprint
import Testing

struct MediaFingerprintTests {
    @Test
    func audioSimilarityMatchesSameWaveformAtDifferentSampleRates() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let audioA = root.appendingPathComponent("tone-a.wav")
        let audioB = root.appendingPathComponent("tone-b.wav")
        try writeWAV(to: audioA, sampleRate: 44_100, duration: 1.2, baseFrequency: 440)
        try writeWAV(to: audioB, sampleRate: 22_050, duration: 1.2, baseFrequency: 440)

        let fingerprinter = AudioFingerprinter()
        let first = try await fingerprinter.fingerprint(url: audioA)
        let second = try await fingerprinter.fingerprint(url: audioB)
        #expect(first != nil)
        #expect(second != nil)
        guard let first, let second else { return }
        let similarity = try #require(FingerprintSimilarity.audioSimilarity(first, second))
        #expect(similarity > 0.94)
    }

    @Test
    func audioSimilarityRejectsDifferentWaveformsWithSameDuration() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let audioA = root.appendingPathComponent("tone-a.wav")
        let audioB = root.appendingPathComponent("tone-b.wav")
        try writeWAV(to: audioA, sampleRate: 44_100, duration: 1.6, baseFrequency: 440)
        try writeWAV(to: audioB, sampleRate: 44_100, duration: 1.6, baseFrequency: 554.37)

        let fingerprinter = AudioFingerprinter()
        let first = try await fingerprinter.fingerprint(url: audioA)
        let second = try await fingerprinter.fingerprint(url: audioB)
        #expect(first != nil)
        #expect(second != nil)
        guard let first, let second else { return }
        #expect(FingerprintSimilarity.audioSimilarity(first, second) == nil)
    }

    @Test
    func videoSimilarityMatchesSameSceneAtDifferentSizes() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let videoA = root.appendingPathComponent("clip-a.mov")
        let videoB = root.appendingPathComponent("clip-b.mov")
        try await writeVideo(to: videoA, size: CGSize(width: 96, height: 96))
        try await writeVideo(to: videoB, size: CGSize(width: 144, height: 144))

        let fingerprinter = VideoFingerprinter()
        let first = try await fingerprinter.fingerprint(url: videoA)
        let second = try await fingerprinter.fingerprint(url: videoB)
        #expect(first != nil)
        #expect(second != nil)
        guard let first, let second else { return }
        let similarity = try #require(FingerprintSimilarity.videoSimilarity(first, second))
        #expect(similarity > 0.90)
    }
}

private func makeTempDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeWAV(to url: URL, sampleRate: Int, duration: Double, baseFrequency: Double) throws {
    let sampleCount = Int(Double(sampleRate) * duration)
    var pcm = Data(capacity: sampleCount * MemoryLayout<Int16>.size)

    for index in 0..<sampleCount {
        let t = Double(index) / Double(sampleRate)
        let sample = sin(2 * Double.pi * baseFrequency * t) * 0.65 + sin(2 * Double.pi * baseFrequency * 2 * t) * 0.15
        let clamped = max(-1.0, min(1.0, sample))
        var value = Int16(clamped * Double(Int16.max))
        withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
    }

    let headerSize = 44
    let byteRate = sampleRate * MemoryLayout<Int16>.size
    let blockAlign = MemoryLayout<Int16>.size
    let totalSize = headerSize + pcm.count - 8

    var data = Data()
    data.append("RIFF".data(using: .ascii)!)
    data.append(littleEndian(UInt32(totalSize)))
    data.append("WAVE".data(using: .ascii)!)
    data.append("fmt ".data(using: .ascii)!)
    data.append(littleEndian(UInt32(16)))
    data.append(littleEndian(UInt16(1)))
    data.append(littleEndian(UInt16(1)))
    data.append(littleEndian(UInt32(sampleRate)))
    data.append(littleEndian(UInt32(byteRate)))
    data.append(littleEndian(UInt16(blockAlign)))
    data.append(littleEndian(UInt16(16)))
    data.append("data".data(using: .ascii)!)
    data.append(littleEndian(UInt32(pcm.count)))
    data.append(pcm)

    try data.write(to: url, options: .atomic)
}

private func writeVideo(to url: URL, size: CGSize) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height)
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height)
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
    guard writer.canAdd(input) else {
        throw NSError(domain: "MediaFingerprintTests", code: 20)
    }
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let frameDuration = CMTime(value: 1, timescale: 10)
    for frame in 0..<8 {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(10))
        }
        let buffer = try makePixelBuffer(size: size, frame: frame)
        let time = CMTimeMultiply(frameDuration, multiplier: Int32(frame))
        adaptor.append(buffer, withPresentationTime: time)
    }

    input.markAsFinished()
    try await withCheckedThrowingContinuation { continuation in
        writer.finishWriting {
            if writer.status == .completed {
                continuation.resume()
            } else {
                continuation.resume(throwing: writer.error ?? NSError(domain: "MediaFingerprintTests", code: 21))
            }
        }
    }
}

private func makePixelBuffer(size: CGSize, frame: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        nil,
        Int(size.width),
        Int(size.height),
        kCVPixelFormatType_32ARGB,
        [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw NSError(domain: "MediaFingerprintTests", code: 22)
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: baseAddress,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )
    else {
        throw NSError(domain: "MediaFingerprintTests", code: 23)
    }

    context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.92, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    context.setFillColor(CGColor(red: 0.18, green: 0.39, blue: 0.81, alpha: 1))
    context.fill(CGRect(x: size.width * 0.1, y: size.height * 0.1, width: size.width * 0.4, height: size.height * 0.18))

    let orbit = CGFloat(frame) / 7
    context.setFillColor(CGColor(red: 0.87, green: 0.33, blue: 0.18, alpha: 1))
    context.fillEllipse(in: CGRect(
        x: size.width * (0.18 + orbit * 0.4),
        y: size.height * 0.42,
        width: size.width * 0.18,
        height: size.width * 0.18
    ))

    context.setStrokeColor(CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))
    context.setLineWidth(max(2, size.width * 0.03))
    context.stroke(CGRect(x: size.width * 0.2, y: size.height * 0.68, width: size.width * 0.5, height: size.height * 0.12))
    return pixelBuffer
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    var copy = value.littleEndian
    return withUnsafeBytes(of: &copy) { Data($0) }
}
