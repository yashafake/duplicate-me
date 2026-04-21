import Foundation
import MediaFingerprint

public enum ScanLocationKind: String, Codable, CaseIterable, Sendable, Hashable {
    case preset
    case custom
}

public enum IgnoreScope: String, Codable, CaseIterable, Sendable, Hashable {
    case folder
    case file
}

public enum ScanStage: String, Codable, CaseIterable, Sendable, Hashable {
    case idle
    case enumerating
    case hashing
    case fingerprinting
    case clustering
    case finished
    case failed
}

public struct ScanLocation: Codable, Sendable, Hashable {
    public let id: String
    public let path: String
    public let kind: ScanLocationKind
    public let isEnabled: Bool

    public init(id: String = UUID().uuidString, path: String, kind: ScanLocationKind, isEnabled: Bool = true) {
        self.id = id
        self.path = path
        self.kind = kind
        self.isEnabled = isEnabled
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }
}

public struct ScanOptions: Codable, Sendable, Hashable {
    public var scanDuplicates: Bool
    public var scanSimilarImages: Bool
    public var scanSimilarVideos: Bool
    public var scanSimilarAudio: Bool
    public var includeHidden: Bool

    public init(
        scanDuplicates: Bool = true,
        scanSimilarImages: Bool = false,
        scanSimilarVideos: Bool = false,
        scanSimilarAudio: Bool = false,
        includeHidden: Bool = false
    ) {
        self.scanDuplicates = scanDuplicates
        self.scanSimilarImages = scanSimilarImages
        self.scanSimilarVideos = scanSimilarVideos
        self.scanSimilarAudio = scanSimilarAudio
        self.includeHidden = includeHidden
    }
}

public struct FileRecord: Codable, Sendable, Hashable {
    public let id: String
    public let path: String
    public let volumeID: String
    public let fileID: String
    public let sourceLocationID: String
    public let sourceLocationKind: ScanLocationKind
    public let size: Int64
    public let createdAt: Date
    public let modifiedAt: Date
    public let mediaKind: MediaKind
    public var sampleHash: String?
    public var fullHash: String?
    public var imageFingerprint: ImageFingerprint?
    public var videoFingerprint: VideoFingerprint?
    public var audioFingerprint: AudioFingerprint?

    public init(
        id: String,
        path: String,
        volumeID: String,
        fileID: String,
        sourceLocationID: String,
        sourceLocationKind: ScanLocationKind,
        size: Int64,
        createdAt: Date,
        modifiedAt: Date,
        mediaKind: MediaKind,
        sampleHash: String? = nil,
        fullHash: String? = nil,
        imageFingerprint: ImageFingerprint? = nil,
        videoFingerprint: VideoFingerprint? = nil,
        audioFingerprint: AudioFingerprint? = nil
    ) {
        self.id = id
        self.path = path
        self.volumeID = volumeID
        self.fileID = fileID
        self.sourceLocationID = sourceLocationID
        self.sourceLocationKind = sourceLocationKind
        self.size = size
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.mediaKind = mediaKind
        self.sampleHash = sampleHash
        self.fullHash = fullHash
        self.imageFingerprint = imageFingerprint
        self.videoFingerprint = videoFingerprint
        self.audioFingerprint = audioFingerprint
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }

    public var inodeKey: String {
        "\(volumeID):\(fileID)"
    }
}

public struct DuplicateCluster: Codable, Sendable, Hashable {
    public let id: String
    public let memberIDs: [String]
    public let recommendedKeepID: String
    public let autoSelectedIDs: [String]
    public let reclaimableBytes: Int64

    public init(id: String, memberIDs: [String], recommendedKeepID: String, autoSelectedIDs: [String], reclaimableBytes: Int64) {
        self.id = id
        self.memberIDs = memberIDs
        self.recommendedKeepID = recommendedKeepID
        self.autoSelectedIDs = autoSelectedIDs
        self.reclaimableBytes = reclaimableBytes
    }
}

public struct SimilarCluster: Codable, Sendable, Hashable {
    public let id: String
    public let mediaKind: MediaKind
    public let memberIDs: [String]
    public let similarityScore: Double
    public let recommendedKeepID: String?

    public init(id: String, mediaKind: MediaKind, memberIDs: [String], similarityScore: Double, recommendedKeepID: String?) {
        self.id = id
        self.mediaKind = mediaKind
        self.memberIDs = memberIDs
        self.similarityScore = similarityScore
        self.recommendedKeepID = recommendedKeepID
    }
}

public struct IgnoreRule: Codable, Sendable, Hashable {
    public let id: String
    public let scope: IgnoreScope
    public let path: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, scope: IgnoreScope, path: String, createdAt: Date = .now) {
        self.id = id
        self.scope = scope
        self.path = path
        self.createdAt = createdAt
    }
}

public struct CleanupSelection: Codable, Sendable, Hashable {
    public let scanRunID: String
    public let clusterIDs: [String]
    public let memberIDs: [String]

    public init(scanRunID: String, clusterIDs: [String] = [], memberIDs: [String]) {
        self.scanRunID = scanRunID
        self.clusterIDs = clusterIDs
        self.memberIDs = memberIDs
    }
}

public struct CleanupReport: Codable, Sendable, Hashable {
    public let trashedIDs: [String]
    public let skippedChangedIDs: [String]
    public let failedIDs: [String]
}

public struct ScanProgress: Codable, Sendable, Hashable {
    public var stage: ScanStage
    public var filesSeen: Int
    public var bytesSeen: Int64
    public var candidatesFound: Int
    public var startedAt: Date
    public var updatedAt: Date

    public init(
        stage: ScanStage = .idle,
        filesSeen: Int = 0,
        bytesSeen: Int64 = 0,
        candidatesFound: Int = 0,
        startedAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.stage = stage
        self.filesSeen = filesSeen
        self.bytesSeen = bytesSeen
        self.candidatesFound = candidatesFound
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

public struct ScanStatistics: Codable, Sendable, Hashable {
    public let totalFiles: Int
    public let totalBytes: Int64
    public let duplicateClusters: Int
    public let similarClusters: Int
    public let reclaimableBytes: Int64
    public let cacheHits: Int

    public init(totalFiles: Int, totalBytes: Int64, duplicateClusters: Int, similarClusters: Int, reclaimableBytes: Int64, cacheHits: Int) {
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
        self.duplicateClusters = duplicateClusters
        self.similarClusters = similarClusters
        self.reclaimableBytes = reclaimableBytes
        self.cacheHits = cacheHits
    }
}

public struct ScanResults: Codable, Sendable, Hashable {
    public let generatedAt: Date
    public let files: [FileRecord]
    public let duplicateClusters: [DuplicateCluster]
    public let similarClusters: [SimilarCluster]
    public let stats: ScanStatistics

    public init(generatedAt: Date, files: [FileRecord], duplicateClusters: [DuplicateCluster], similarClusters: [SimilarCluster], stats: ScanStatistics) {
        self.generatedAt = generatedAt
        self.files = files
        self.duplicateClusters = duplicateClusters
        self.similarClusters = similarClusters
        self.stats = stats
    }
}

public struct ScanRun: Codable, Sendable, Hashable {
    public let id: String
    public let createdAt: Date
    public let locations: [ScanLocation]
    public let options: ScanOptions
    public var progress: ScanProgress
    public var results: ScanResults?

    public init(id: String, createdAt: Date = .now, locations: [ScanLocation], options: ScanOptions, progress: ScanProgress, results: ScanResults? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.locations = locations
        self.options = options
        self.progress = progress
        self.results = results
    }
}

public struct CacheEntry: Codable, Sendable, Hashable {
    public let key: String
    public let path: String
    public let volumeID: String
    public let fileID: String
    public let size: Int64
    public let modifiedAt: Date
    public let mediaKind: MediaKind
    public var sampleHash: String?
    public var fullHash: String?
    public var imageFingerprint: ImageFingerprint?
    public var videoFingerprint: VideoFingerprint?
    public var audioFingerprint: AudioFingerprint?
}
