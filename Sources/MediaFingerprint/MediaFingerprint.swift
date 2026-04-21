import Accelerate
import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MediaKind: String, Codable, CaseIterable, Sendable, Hashable {
    case other
    case image
    case video
    case audio
}

public enum MediaKindDetector {
    public static func mediaKind(for url: URL) -> MediaKind {
        guard
            let type = UTType(filenameExtension: url.pathExtension.lowercased())
        else {
            return .other
        }

        if type.conforms(to: .image) {
            return .image
        }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            return .video
        }
        if type.conforms(to: .audio) {
            return .audio
        }
        return .other
    }
}

public struct ImageFingerprint: Codable, Sendable, Equatable, Hashable {
    public let perceptualHashHex: String
    public let histogram: [Double]
    public let width: Int
    public let height: Int
    public let aspectRatio: Double
}

public struct VideoFingerprint: Codable, Sendable, Equatable, Hashable {
    public let frameHashes: [String]
    public let duration: Double
    public let width: Int
    public let height: Int
    public let aspectRatio: Double
}

public struct AudioFingerprint: Codable, Sendable, Equatable, Hashable {
    public let trendHashHex: String
    public let energyProfile: [Double]
    public let zeroCrossingProfile: [Double]
    public let brightnessProfile: [Double]
    public let segmentProfile: [Double]
    public let segmentHashHex: String
    public let averageZeroCrossingRate: Double
    public let averageBrightness: Double
    public let duration: Double

    public init(
        trendHashHex: String,
        energyProfile: [Double],
        zeroCrossingProfile: [Double] = [],
        brightnessProfile: [Double] = [],
        segmentProfile: [Double] = [],
        segmentHashHex: String = "",
        averageZeroCrossingRate: Double = 0,
        averageBrightness: Double = 0,
        duration: Double
    ) {
        self.trendHashHex = trendHashHex
        self.energyProfile = energyProfile
        self.zeroCrossingProfile = zeroCrossingProfile
        self.brightnessProfile = brightnessProfile
        self.segmentProfile = segmentProfile
        self.segmentHashHex = segmentHashHex
        self.averageZeroCrossingRate = averageZeroCrossingRate
        self.averageBrightness = averageBrightness
        self.duration = duration
    }

    enum CodingKeys: String, CodingKey {
        case trendHashHex
        case energyProfile
        case zeroCrossingProfile
        case brightnessProfile
        case segmentProfile
        case segmentHashHex
        case averageZeroCrossingRate
        case averageBrightness
        case duration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.trendHashHex = try container.decode(String.self, forKey: .trendHashHex)
        self.energyProfile = try container.decode([Double].self, forKey: .energyProfile)
        self.zeroCrossingProfile = try container.decodeIfPresent([Double].self, forKey: .zeroCrossingProfile) ?? []
        self.brightnessProfile = try container.decodeIfPresent([Double].self, forKey: .brightnessProfile) ?? []
        self.segmentProfile = try container.decodeIfPresent([Double].self, forKey: .segmentProfile) ?? []
        self.segmentHashHex = try container.decodeIfPresent(String.self, forKey: .segmentHashHex) ?? ""
        self.averageZeroCrossingRate = try container.decodeIfPresent(Double.self, forKey: .averageZeroCrossingRate) ?? 0
        self.averageBrightness = try container.decodeIfPresent(Double.self, forKey: .averageBrightness) ?? 0
        self.duration = try container.decode(Double.self, forKey: .duration)
    }
}

public enum FingerprintSimilarity {
    public static func imageSimilarity(_ lhs: ImageFingerprint, _ rhs: ImageFingerprint) -> Double? {
        guard relativeDelta(lhs.aspectRatio, rhs.aspectRatio) <= 0.15 else {
            return nil
        }
        let hamming = hammingDistance(lhs.perceptualHashHex, rhs.perceptualHashHex)
        let histogramScore = cosineSimilarity(lhs.histogram, rhs.histogram)
        let hashScore = max(0, 1 - (Double(hamming) / 64.0))
        let score = (hashScore * 0.55) + (histogramScore * 0.45)
        return score >= 0.90 && hamming <= 10 && histogramScore >= 0.88 ? score : nil
    }

    public static func videoSimilarity(_ lhs: VideoFingerprint, _ rhs: VideoFingerprint) -> Double? {
        guard relativeDelta(lhs.duration, rhs.duration) <= 0.05 else {
            return nil
        }
        guard relativeDelta(lhs.aspectRatio, rhs.aspectRatio) <= 0.20 else {
            return nil
        }

        let pairCount = min(lhs.frameHashes.count, rhs.frameHashes.count)
        guard pairCount >= 3 else {
            return nil
        }

        var distances: [Double] = []
        for index in 0..<pairCount {
            let distance = Double(hammingDistance(lhs.frameHashes[index], rhs.frameHashes[index]))
            distances.append(distance)
        }
        let medianDistance = distances.sorted()[pairCount / 2]
        let score = max(0, 1 - (medianDistance / 64.0))
        return medianDistance <= 10 ? score : nil
    }

    public static func audioSimilarity(_ lhs: AudioFingerprint, _ rhs: AudioFingerprint) -> Double? {
        let maxDurationDelta = min(2.5, max(lhs.duration, rhs.duration) * 0.015)
        guard abs(lhs.duration - rhs.duration) <= maxDurationDelta else {
            return nil
        }
        guard relativeDelta(lhs.averageZeroCrossingRate, rhs.averageZeroCrossingRate) <= 0.16 else {
            return nil
        }
        guard relativeDelta(lhs.averageBrightness, rhs.averageBrightness) <= 0.18 else {
            return nil
        }
        let energyCosine = cosineSimilarity(lhs.energyProfile, rhs.energyProfile)
        let zeroCrossingCosine = cosineSimilarity(lhs.zeroCrossingProfile, rhs.zeroCrossingProfile)
        let brightnessCosine = cosineSimilarity(lhs.brightnessProfile, rhs.brightnessProfile)
        let segmentCosine = cosineSimilarity(lhs.segmentProfile, rhs.segmentProfile)
        let zeroCrossingDelta = profileDeltaSimilarity(lhs.zeroCrossingProfile, rhs.zeroCrossingProfile)
        let brightnessDelta = profileDeltaSimilarity(lhs.brightnessProfile, rhs.brightnessProfile)
        let segmentDelta = profileDeltaSimilarity(lhs.segmentProfile, rhs.segmentProfile)

        let globalHamming = hammingDistance(lhs.trendHashHex, rhs.trendHashHex)
        let segmentHamming = hammingDistance(lhs.segmentHashHex, rhs.segmentHashHex)
        let globalHashScore = max(0, 1 - (Double(globalHamming) / 64.0))
        let segmentHashScore = max(0, 1 - (Double(segmentHamming) / 64.0))

        let score = min(1,
            (energyCosine * 0.12) +
            (zeroCrossingCosine * 0.13) +
            (zeroCrossingDelta * 0.15) +
            (brightnessCosine * 0.15) +
            (brightnessDelta * 0.17) +
            (segmentCosine * 0.13) +
            (segmentDelta * 0.15) +
            (globalHashScore * 0.05) +
            (segmentHashScore * 0.05)
        )

        guard energyCosine >= 0.92 else { return nil }
        guard zeroCrossingCosine >= 0.90 else { return nil }
        guard zeroCrossingDelta >= 0.88 else { return nil }
        guard brightnessCosine >= 0.94 else { return nil }
        guard brightnessDelta >= 0.90 else { return nil }
        guard segmentCosine >= 0.94 else { return nil }
        guard segmentDelta >= 0.90 else { return nil }
        return score >= 0.93 ? score : nil
    }
}

public struct ImageFingerprinter: Sendable {
    public init() {}

    public func fingerprint(url: URL) throws -> ImageFingerprint? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 128
                ] as CFDictionary
            )
        else {
            return nil
        }

        let raster = try rasterize(image: image, width: 64, height: 64)
        let dHashImage = try rasterize(image: image, width: 9, height: 8)
        let hash = differenceHash(raster: dHashImage, width: 9, height: 8)
        let histogram = colorHistogram(raster: raster, width: 64, height: 64)
        let aspectRatio = Double(image.width) / Double(max(image.height, 1))

        return ImageFingerprint(
            perceptualHashHex: hex(hash),
            histogram: histogram,
            width: image.width,
            height: image.height,
            aspectRatio: aspectRatio
        )
    }
}

public struct VideoFingerprinter: Sendable {
    public init() {}

    public func fingerprint(url: URL) async throws -> VideoFingerprint? {
        let asset = AVURLAsset(url: url)
        let durationTime = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationTime)
        guard duration.isFinite, duration > 0 else {
            return nil
        }

        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            return nil
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = naturalSize.applying(transform)
        let width = max(Int(abs(transformed.width.rounded())), 1)
        let height = max(Int(abs(transformed.height.rounded())), 1)
        let aspectRatio = Double(width) / Double(height)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceAfter = .zero
        generator.requestedTimeToleranceBefore = .zero

        let sampleCount = min(max(Int(duration.rounded(.up)), 4), 8)
        let times = sampleTimes(duration: duration, count: sampleCount)
        var frameHashes: [String] = []

        for time in times {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) else {
                continue
            }
            let small = try rasterize(image: cgImage, width: 9, height: 8)
            frameHashes.append(hex(differenceHash(raster: small, width: 9, height: 8)))
        }

        guard frameHashes.count >= 3 else {
            return nil
        }

        return VideoFingerprint(
            frameHashes: frameHashes,
            duration: duration,
            width: width,
            height: height,
            aspectRatio: aspectRatio
        )
    }
}

public struct AudioFingerprinter: Sendable {
    private static let fingerprintQueue = DispatchQueue(label: "duplicate-me.audio-fingerprint", qos: .utility, attributes: .concurrent)

    public init() {}

    public func fingerprint(url: URL) async throws -> AudioFingerprint? {
        try await withCheckedThrowingContinuation { continuation in
            Self.fingerprintQueue.async {
                do {
                    continuation.resume(returning: try blockingAudioFingerprint(url: url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private func blockingAudioFingerprint(url: URL) throws -> AudioFingerprint? {
    let asset = AVURLAsset(url: url)
    let duration = CMTimeGetSeconds(asset.duration)
    guard duration.isFinite, duration > 0 else {
        return nil
    }

    let tracks = asset.tracks(withMediaType: .audio)
    guard let track = tracks.first else {
        return nil
    }

    let reader = try AVAssetReader(asset: asset)
    // Similarity needs more than the intro of a track; sample a longer local range.
    reader.timeRange = CMTimeRange(
        start: .zero,
        duration: CMTime(seconds: min(duration, 180), preferredTimescale: 600)
    )

    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: 8_000,
        AVNumberOfChannelsKey: 1
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else {
        return nil
    }

    var samples: [Float] = []
    samples.reserveCapacity(Int(min(duration, 180) * 8_000))

    while let buffer = output.copyNextSampleBuffer() {
        defer { CMSampleBufferInvalidate(buffer) }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else {
            continue
        }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else {
            continue
        }

        var bytes = [UInt8](repeating: 0, count: length)
        CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &bytes)
        let floatCount = length / MemoryLayout<Float>.size
        bytes.withUnsafeBytes { rawBuffer in
            let pointer = rawBuffer.bindMemory(to: Float.self)
            samples.append(contentsOf: pointer.prefix(floatCount))
        }
    }

    guard !samples.isEmpty else {
        return nil
    }

    let normalizedSamples = normalizedAudioSamples(samples)
    let energies = normalizedEnergyProfile(samples: normalizedSamples, buckets: 96)
    let (zeroCrossings, averageZeroCrossingRate) = normalizedZeroCrossingProfile(samples: normalizedSamples, buckets: 96)
    let (brightness, averageBrightness) = normalizedBrightnessProfile(samples: normalizedSamples, buckets: 96)
    let segmentProfile = distributedEnvelopeProfile(
        samples: normalizedSamples,
        segmentCount: 10,
        samplesPerSegment: 8_000,
        bucketsPerSegment: 12
    )
    let globalTrendHash = trendHash(energies)
    let segmentTrendHash = trendHash(segmentProfile)
    return AudioFingerprint(
        trendHashHex: hex(globalTrendHash),
        energyProfile: energies,
        zeroCrossingProfile: zeroCrossings,
        brightnessProfile: brightness,
        segmentProfile: segmentProfile,
        segmentHashHex: hex(segmentTrendHash),
        averageZeroCrossingRate: averageZeroCrossingRate,
        averageBrightness: averageBrightness,
        duration: duration
    )
}

private func rasterize(image: CGImage, width: Int, height: Int) throws -> [UInt8] {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)
    guard let context = CGContext(
        data: &buffer,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "MediaFingerprint", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create bitmap context."])
    }

    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
}

private func differenceHash(raster: [UInt8], width: Int, height: Int) -> UInt64 {
    var result: UInt64 = 0
    for row in 0..<height {
        for column in 0..<(width - 1) {
            let left = grayscaleValue(raster: raster, width: width, x: column, y: row)
            let right = grayscaleValue(raster: raster, width: width, x: column + 1, y: row)
            result <<= 1
            if left > right {
                result |= 1
            }
        }
    }
    return result
}

private func colorHistogram(raster: [UInt8], width: Int, height: Int) -> [Double] {
    var bins = [Double](repeating: 0, count: 16)
    for y in 0..<height {
        for x in 0..<width {
            let index = ((y * width) + x) * 4
            let red = Double(raster[index]) / 255
            let green = Double(raster[index + 1]) / 255
            let blue = Double(raster[index + 2]) / 255

            let maxChannel = max(red, green, blue)
            let minChannel = min(red, green, blue)
            let delta = maxChannel - minChannel
            let brightness = maxChannel

            let bin: Int
            if delta < 0.12 {
                bin = 12 + min(Int(brightness * 4), 3)
            } else {
                let hue: Double
                switch maxChannel {
                case red:
                    hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
                case green:
                    hue = ((blue - red) / delta) + 2
                default:
                    hue = ((red - green) / delta) + 4
                }
                let normalizedHue = (hue < 0 ? hue + 6 : hue) / 6
                bin = min(Int(normalizedHue * 12), 11)
            }
            bins[bin] += 1
        }
    }

    let total = bins.reduce(0, +)
    guard total > 0 else {
        return bins
    }
    return bins.map { $0 / total }
}

private func grayscaleValue(raster: [UInt8], width: Int, x: Int, y: Int) -> Double {
    let index = ((y * width) + x) * 4
    let red = Double(raster[index])
    let green = Double(raster[index + 1])
    let blue = Double(raster[index + 2])
    return (0.299 * red) + (0.587 * green) + (0.114 * blue)
}

private func sampleTimes(duration: Double, count: Int) -> [Double] {
    guard count > 0 else {
        return []
    }
    if count == 1 {
        return [duration / 2]
    }
    return (0..<count).map { index in
        let position = Double(index + 1) / Double(count + 1)
        return duration * position
    }
}

private func normalizedEnergyProfile(samples: [Float], buckets: Int) -> [Double] {
    guard !samples.isEmpty else {
        return []
    }

    let bucketSize = max(samples.count / buckets, 1)
    var energies: [Double] = []
    energies.reserveCapacity(buckets)

    var cursor = 0
    while cursor < samples.count, energies.count < buckets {
        let end = min(cursor + bucketSize, samples.count)
        let slice = samples[cursor..<end]
        let energy = slice.reduce(0.0) { partial, sample in
            partial + Double(abs(sample))
        } / Double(slice.count)
        energies.append(energy)
        cursor = end
    }

    while energies.count < buckets {
        energies.append(0)
    }

    let norm = sqrt(energies.reduce(0) { $0 + ($1 * $1) })
    guard norm > 0 else {
        return energies
    }
    return energies.map { $0 / norm }
}

private func normalizedZeroCrossingProfile(samples: [Float], buckets: Int) -> ([Double], Double) {
    guard !samples.isEmpty else {
        return ([], 0)
    }

    let bucketSize = max(samples.count / buckets, 1)
    var profile: [Double] = []
    profile.reserveCapacity(buckets)

    var cursor = 0
    while cursor < samples.count, profile.count < buckets {
        let end = min(cursor + bucketSize, samples.count)
        let slice = Array(samples[cursor..<end])
        guard slice.count > 1 else {
            profile.append(0)
            cursor = end
            continue
        }

        var crossings = 0
        for index in 1..<slice.count {
            let previous = slice[index - 1]
            let current = slice[index]
            if (previous >= 0 && current < 0) || (previous < 0 && current >= 0) {
                crossings += 1
            }
        }
        profile.append(Double(crossings) / Double(slice.count - 1))
        cursor = end
    }

    while profile.count < buckets {
        profile.append(0)
    }
    let average = profile.isEmpty ? 0 : profile.reduce(0, +) / Double(profile.count)
    return (normalizeProfile(profile), average)
}

private func normalizedBrightnessProfile(samples: [Float], buckets: Int) -> ([Double], Double) {
    guard !samples.isEmpty else {
        return ([], 0)
    }

    let bucketSize = max(samples.count / buckets, 1)
    var profile: [Double] = []
    profile.reserveCapacity(buckets)

    var cursor = 0
    while cursor < samples.count, profile.count < buckets {
        let end = min(cursor + bucketSize, samples.count)
        let slice = samples[cursor..<end]
        guard slice.count > 1 else {
            profile.append(0)
            cursor = end
            continue
        }

        var total: Double = 0
        var last = slice.first ?? 0
        for sample in slice.dropFirst() {
            total += Double(abs(sample - last))
            last = sample
        }
        profile.append(total / Double(slice.count - 1))
        cursor = end
    }

    while profile.count < buckets {
        profile.append(0)
    }
    let average = profile.isEmpty ? 0 : profile.reduce(0, +) / Double(profile.count)
    return (normalizeProfile(profile), average)
}

private func distributedEnvelopeProfile(
    samples: [Float],
    segmentCount: Int,
    samplesPerSegment: Int,
    bucketsPerSegment: Int
) -> [Double] {
    guard !samples.isEmpty else {
        return []
    }

    let clampedSegmentCount = max(1, segmentCount)
    let windowSize = max(512, min(samplesPerSegment, samples.count))
    let lastStart = max(samples.count - windowSize, 0)
    var profile: [Double] = []
    profile.reserveCapacity(clampedSegmentCount * bucketsPerSegment)

    for segmentIndex in 0..<clampedSegmentCount {
        let start: Int
        if clampedSegmentCount == 1 {
            start = lastStart / 2
        } else {
            let position = Double(segmentIndex) / Double(clampedSegmentCount - 1)
            start = Int((Double(lastStart) * position).rounded())
        }
        let end = min(start + windowSize, samples.count)
        let window = Array(samples[start..<end])
        profile.append(contentsOf: normalizedEnergyProfile(samples: window, buckets: bucketsPerSegment))
    }

    return normalizeProfile(profile)
}

private func normalizedAudioSamples(_ samples: [Float]) -> [Float] {
    guard let peak = samples.map({ abs($0) }).max(), peak > 0 else {
        return samples
    }
    return samples.map { $0 / peak }
}

private func normalizeProfile(_ values: [Double]) -> [Double] {
    let norm = sqrt(values.reduce(0) { $0 + ($1 * $1) })
    guard norm > 0 else {
        return values
    }
    return values.map { $0 / norm }
}

private func trendHash(_ values: [Double]) -> UInt64 {
    guard values.count > 1 else {
        return 0
    }
    var hash: UInt64 = 0
    for index in 0..<min(values.count - 1, 64) {
        hash <<= 1
        if values[index] > values[index + 1] {
            hash |= 1
        }
    }
    return hash
}

private func relativeDelta(_ lhs: Double, _ rhs: Double) -> Double {
    let baseline = max(abs(lhs), abs(rhs), 0.000_1)
    return abs(lhs - rhs) / baseline
}

private func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
    guard lhs.count == rhs.count, !lhs.isEmpty else {
        return 0
    }
    let dot = zip(lhs, rhs).reduce(0) { $0 + ($1.0 * $1.1) }
    let lhsNorm = sqrt(lhs.reduce(0) { $0 + ($1 * $1) })
    let rhsNorm = sqrt(rhs.reduce(0) { $0 + ($1 * $1) })
    guard lhsNorm > 0, rhsNorm > 0 else {
        return 0
    }
    return dot / (lhsNorm * rhsNorm)
}

private func profileDeltaSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
    guard lhs.count == rhs.count, !lhs.isEmpty else {
        return 0
    }
    let meanAbsoluteDelta = zip(lhs, rhs).reduce(0.0) { partial, pair in
        partial + abs(pair.0 - pair.1)
    } / Double(lhs.count)
    return max(0, 1 - meanAbsoluteDelta)
}

public func hammingDistance(_ lhsHex: String, _ rhsHex: String) -> Int {
    let lhs = UInt64(lhsHex, radix: 16) ?? 0
    let rhs = UInt64(rhsHex, radix: 16) ?? 0
    return (lhs ^ rhs).nonzeroBitCount
}

private func hex(_ value: UInt64) -> String {
    let raw = String(value, radix: 16, uppercase: false)
    return String(repeating: "0", count: max(0, 16 - raw.count)) + raw
}
