import CryptoKit
import Foundation
import MediaFingerprint

public actor DuplicateMeEngine {
    private let store: ScanStoreProtocol
    private let imageFingerprinter = ImageFingerprinter()
    private let videoFingerprinter = VideoFingerprinter()
    private let audioFingerprinter = AudioFingerprinter()
    private let fileManager = FileManager.default

    public init(store: ScanStoreProtocol) {
        self.store = store
    }

    public func scan(locations: [ScanLocation], options: ScanOptions) async throws -> String {
        let runID = try prepareScan(locations: locations, options: options)
        try await executePreparedScan(runID: runID)
        return runID
    }

    public func rescan(runID: String?) async throws -> String {
        let baseline = try runID.flatMap { try store.loadRun(id: $0) } ?? store.latestRun()
        guard let baseline else {
            throw NSError(domain: "ScanCore", code: 404, userInfo: [NSLocalizedDescriptionKey: "No previous scan run found."])
        }
        let newRunID = try prepareScan(locations: baseline.locations, options: baseline.options)
        try await executePreparedScan(runID: newRunID)
        return newRunID
    }

    public func prepareScan(locations: [ScanLocation], options: ScanOptions) throws -> String {
        let enabledLocations = try validatedLocations(locations)
        let runID = UUID().uuidString
        let now = Date()
        let run = ScanRun(
            id: runID,
            createdAt: now,
            locations: enabledLocations,
            options: options,
            progress: ScanProgress(stage: .enumerating, startedAt: now, updatedAt: now)
        )
        try store.saveRun(run)
        return runID
    }

    public func executePreparedScan(runID: String) async throws {
        guard let run = try store.loadRun(id: runID) else {
            throw NSError(domain: "ScanCore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Prepared scan run not found."])
        }

        do {
            try await performScan(runID: runID, locations: run.locations, options: run.options, createdAt: run.createdAt, startedAt: run.progress.startedAt)
        } catch {
            try? markScanFailed(runID: runID)
            throw error
        }
    }

    public func markScanFailed(runID: String) throws {
        guard var run = try store.loadRun(id: runID) else {
            return
        }
        run.progress.stage = .failed
        run.progress.updatedAt = .now
        try store.saveRun(run)
    }

    public func getProgress(scanRunId: String) throws -> ScanProgress {
        guard let run = try store.loadRun(id: scanRunId) else {
            throw NSError(domain: "ScanCore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Scan run not found."])
        }
        return run.progress
    }

    public func getResults(scanRunId: String) throws -> ScanResults {
        guard let run = try store.loadRun(id: scanRunId), let results = run.results else {
            throw NSError(domain: "ScanCore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Results not found for scan run."])
        }
        return results
    }

    public func trash(selection: CleanupSelection) throws -> CleanupReport {
        guard let run = try store.loadRun(id: selection.scanRunID), let results = run.results else {
            throw NSError(domain: "ScanCore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Scan run not found."])
        }

        let allowedClusterIDs = Set(selection.clusterIDs)
        let allowedMembers = Set(selection.memberIDs)
        guard !allowedMembers.isEmpty else {
            throw NSError(domain: "ScanCore", code: 400, userInfo: [NSLocalizedDescriptionKey: "At least one member id must be selected for trash."])
        }

        let duplicateClusterMembers = Dictionary(uniqueKeysWithValues: results.duplicateClusters.flatMap { cluster in
            cluster.memberIDs.map { memberID in (memberID, cluster.id) }
        })
        let fileMap = Dictionary(uniqueKeysWithValues: results.files.map { ($0.id, $0) })

        var trashed: [String] = []
        var skippedChanged: [String] = []
        var failed: [String] = []

        for memberID in allowedMembers {
            guard let record = fileMap[memberID] else {
                failed.append(memberID)
                continue
            }

            if let clusterID = duplicateClusterMembers[memberID], !allowedClusterIDs.isEmpty, !allowedClusterIDs.contains(clusterID) {
                failed.append(memberID)
                continue
            }

            do {
                let currentAttributes = try fileManager.attributesOfItem(atPath: record.path)
                let currentSize = (currentAttributes[.size] as? NSNumber)?.int64Value ?? -1
                let currentModified = currentAttributes[.modificationDate] as? Date ?? .distantPast
                let currentModifiedSecond = Int(currentModified.timeIntervalSince1970)
                let recordedModifiedSecond = Int(record.modifiedAt.timeIntervalSince1970)
                guard currentSize == record.size, currentModifiedSecond == recordedModifiedSecond else {
                    skippedChanged.append(memberID)
                    continue
                }

                var trashedURL: NSURL?
                try fileManager.trashItem(at: record.url, resultingItemURL: &trashedURL)
                trashed.append(memberID)
            } catch {
                failed.append(memberID)
            }
        }

        return CleanupReport(trashedIDs: trashed, skippedChangedIDs: skippedChanged, failedIDs: failed)
    }

    private func validatedLocations(_ locations: [ScanLocation]) throws -> [ScanLocation] {
        let enabledLocations = locations.filter(\.isEnabled)
        guard !enabledLocations.isEmpty else {
            throw NSError(domain: "ScanCore", code: 400, userInfo: [NSLocalizedDescriptionKey: "At least one enabled location is required."])
        }
        return enabledLocations
    }

    private func performScan(
        runID: String,
        locations: [ScanLocation],
        options: ScanOptions,
        createdAt: Date,
        startedAt: Date
    ) async throws {
        var run = ScanRun(
            id: runID,
            createdAt: createdAt,
            locations: locations,
            options: options,
            progress: ScanProgress(stage: .enumerating, startedAt: startedAt, updatedAt: .now)
        )

        let ignoreRules = try store.listIgnoreRules()
        let reviewDismissRules = try store.listReviewDismissRules()
        let dismissedSimilarClusterSignatures = Set(
            reviewDismissRules
                .filter { $0.kind == .similarCluster }
                .map(\.signature)
        )
        let dismissedSimilarFileSignatures = Set(
            reviewDismissRules
                .filter { $0.kind == .similarFile }
                .map(\.signature)
        )
        let concurrencyLimit = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        let seeds = try enumerateFiles(
            locations: locations,
            options: options,
            ignoreRules: ignoreRules,
            runID: runID,
            startedAt: startedAt
        )
        run.progress.filesSeen = seeds.count
        run.progress.bytesSeen = seeds.reduce(0) { $0 + $1.size }
        run.progress.updatedAt = .now

        var records = Dictionary(uniqueKeysWithValues: seeds.map { ($0.id, $0.asRecord()) })
        var cacheHits = 0
        let store = self.store
        let imageFingerprinter = self.imageFingerprinter
        let videoFingerprinter = self.videoFingerprinter
        let audioFingerprinter = self.audioFingerprinter

        if options.scanDuplicates {
            run.progress.stage = .hashing
            run.progress.updatedAt = .now
            try store.updateProgress(run.progress, for: runID)

            let sizeCandidates = Dictionary(grouping: seeds, by: \.size).values.filter { $0.count > 1 }.flatMap { $0 }
            run.progress.candidatesFound = sizeCandidates.count
            try store.updateProgress(run.progress, for: runID)

            let sampleUpdates = try await boundedConcurrentMap(items: sizeCandidates, limit: concurrencyLimit) { seed in
                try ensureSampleHash(for: seed, store: store)
            }
            for update in sampleUpdates {
                records[update.id]?.sampleHash = update.sampleHash
                cacheHits += update.cacheHitCount
            }

            let sampleGroups = Dictionary(grouping: sampleUpdates, by: { "\($0.size)|\($0.sampleHash)" })
                .values
                .filter { $0.count > 1 }
                .flatMap { $0 }

            let fullUpdates = try await boundedConcurrentMap(items: sampleGroups, limit: concurrencyLimit) { update in
                try ensureFullHash(for: update, store: store)
            }
            for update in fullUpdates {
                records[update.id]?.fullHash = update.fullHash
                cacheHits += update.cacheHitCount
            }
        }

        let mediaCandidates = seeds.filter { shouldFingerprint(kind: $0.mediaKind, options: options) }
        if !mediaCandidates.isEmpty {
            run.progress.stage = .fingerprinting
            run.progress.updatedAt = .now
            run.progress.candidatesFound = mediaCandidates.count
            try store.updateProgress(run.progress, for: runID)

            let fingerprintLimit = mediaCandidates.contains(where: { $0.mediaKind == .audio })
                ? min(concurrencyLimit, 2)
                : concurrencyLimit

            let fingerprintUpdates = try await boundedConcurrentMap(items: mediaCandidates, limit: fingerprintLimit) { seed in
                try await ensureFingerprint(
                    for: seed,
                    store: store,
                    imageFingerprinter: imageFingerprinter,
                    videoFingerprinter: videoFingerprinter,
                    audioFingerprinter: audioFingerprinter
                )
            }
            for update in fingerprintUpdates {
                cacheHits += update.cacheHitCount
                switch update.payload {
                case .image(let fingerprint):
                    records[update.id]?.imageFingerprint = fingerprint
                case .video(let fingerprint):
                    records[update.id]?.videoFingerprint = fingerprint
                case .audio(let fingerprint):
                    records[update.id]?.audioFingerprint = fingerprint
                case .none:
                    break
                }
            }
        }

        run.progress.stage = .clustering
        run.progress.updatedAt = .now
        try store.updateProgress(run.progress, for: runID)

        let orderedRecords = seeds.compactMap { records[$0.id] }
        let duplicateClusters = buildDuplicateClusters(from: orderedRecords)
        let exactMemberIDs = Set(duplicateClusters.flatMap(\.memberIDs))
        let similarCandidateRecords = orderedRecords.filter { record in
            guard !exactMemberIDs.contains(record.id) else {
                return false
            }
            let signature = ReviewDismissSignature.similarFile(path: record.path)
            return !dismissedSimilarFileSignatures.contains(signature)
        }
        let similarClusters = buildSimilarClusters(
            from: similarCandidateRecords,
            options: options,
            dismissedSignatures: dismissedSimilarClusterSignatures
        )
        let reclaimableBytes = duplicateClusters.reduce(0) { $0 + $1.reclaimableBytes }
        let stats = ScanStatistics(
            totalFiles: orderedRecords.count,
            totalBytes: orderedRecords.reduce(0) { $0 + $1.size },
            duplicateClusters: duplicateClusters.count,
            similarClusters: similarClusters.count,
            reclaimableBytes: reclaimableBytes,
            cacheHits: cacheHits
        )

        run.progress.stage = .finished
        run.progress.updatedAt = .now
        run.progress.candidatesFound = duplicateClusters.count + similarClusters.count
        run.results = ScanResults(
            generatedAt: .now,
            files: orderedRecords,
            duplicateClusters: duplicateClusters,
            similarClusters: similarClusters,
            stats: stats
        )
        try store.saveRun(run)
    }

    private func enumerateFiles(
        locations: [ScanLocation],
        options: ScanOptions,
        ignoreRules: [IgnoreRule],
        runID: String,
        startedAt: Date
    ) throws -> [FileSeed] {
        let normalizedIgnoreRules = ignoreRules.map { rule in
            (scope: rule.scope, path: URL(fileURLWithPath: rule.path).standardizedFileURL.path)
        }
        let excludedFragments = ["/.Trash/", "/Library/Caches/", "/Library/Logs/"]
        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isPackageKey,
            .isAliasFileKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .creationDateKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]

        var seeds: [FileSeed] = []
        var filesSeen = 0
        var bytesSeen: Int64 = 0

        for location in locations {
            let rootURL = location.url.standardizedFileURL
            guard fileManager.fileExists(atPath: rootURL.path) else {
                continue
            }

            let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: resourceKeys,
                options: options.includeHidden ? [] : [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            )

            while let item = enumerator?.nextObject() as? URL {
                let standardized = item.standardizedFileURL
                let path = standardized.path
                let values = try standardized.resourceValues(forKeys: Set(resourceKeys))

                if values.isDirectory == true {
                    if shouldSkipDirectory(path: path, values: values, ignoreRules: normalizedIgnoreRules, excludedFragments: excludedFragments) {
                        enumerator?.skipDescendants()
                    }
                    continue
                }

                guard values.isRegularFile == true else {
                    continue
                }
                guard values.isSymbolicLink != true, values.isAliasFile != true else {
                    continue
                }
                guard !shouldIgnore(path: path, ignoreRules: normalizedIgnoreRules) else {
                    continue
                }

                if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != URLUbiquitousItemDownloadingStatus.current {
                    continue
                }

                let attributes = try fileManager.attributesOfItem(atPath: path)
                let volumeID = String(describing: attributes[.systemNumber] ?? "0")
                let fileID = String(describing: attributes[.systemFileNumber] ?? path)
                let size = Int64((attributes[.size] as? NSNumber)?.int64Value ?? Int64(values.fileSize ?? 0))
                let createdAt = (attributes[.creationDate] as? Date) ?? values.creationDate ?? .distantPast
                let modifiedAt = (attributes[.modificationDate] as? Date) ?? values.contentModificationDate ?? .distantPast
                let mediaKind = MediaKindDetector.mediaKind(for: standardized)

                let seed = FileSeed(
                    id: stableID(volumeID: volumeID, fileID: fileID, path: path),
                    path: path,
                    volumeID: volumeID,
                    fileID: fileID,
                    sourceLocationID: location.id,
                    sourceLocationKind: location.kind,
                    size: size,
                    createdAt: createdAt,
                    modifiedAt: modifiedAt,
                    mediaKind: mediaKind
                )
                seeds.append(seed)
                filesSeen += 1
                bytesSeen += size

                if filesSeen.isMultiple(of: 100) {
                    let progress = ScanProgress(
                        stage: .enumerating,
                        filesSeen: filesSeen,
                        bytesSeen: bytesSeen,
                        candidatesFound: 0,
                        startedAt: startedAt,
                        updatedAt: .now
                    )
                    try store.updateProgress(progress, for: runID)
                }
            }
        }

        let progress = ScanProgress(
            stage: .enumerating,
            filesSeen: filesSeen,
            bytesSeen: bytesSeen,
            candidatesFound: 0,
            startedAt: startedAt,
            updatedAt: .now
        )
        try store.updateProgress(progress, for: runID)
        return seeds
    }

    private func buildDuplicateClusters(from records: [FileRecord]) -> [DuplicateCluster] {
        let fullHashGroups = Dictionary(grouping: records.filter { $0.fullHash != nil }, by: { $0.fullHash! })
        return fullHashGroups.values.compactMap { group in
            let uniqueInodes = Dictionary(grouping: group, by: \.inodeKey)
            guard uniqueInodes.count > 1 else {
                return nil
            }

            let members = uniqueInodes.values.compactMap { inodeGroup in
                inodeGroup.sorted { $0.path < $1.path }.first
            }.sorted { $0.path < $1.path }
            let keep = recommendedKeep(for: members)
            let selected = members.filter { $0.id != keep.id }.map(\.id)
            let reclaimable = members.filter { $0.id != keep.id }.reduce(0) { $0 + $1.size }

            return DuplicateCluster(
                id: stableID(volumeID: keep.volumeID, fileID: keep.fileID, path: keep.path + "|dup"),
                memberIDs: members.map(\.id),
                recommendedKeepID: keep.id,
                autoSelectedIDs: selected,
                reclaimableBytes: reclaimable
            )
        }
        .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    private func buildSimilarClusters(
        from records: [FileRecord],
        options: ScanOptions,
        dismissedSignatures: Set<String>
    ) -> [SimilarCluster] {
        var clusters: [SimilarCluster] = []
        if options.scanSimilarImages {
            clusters.append(contentsOf: buildSimilarityClusters(
                records: records.filter { $0.mediaKind == .image && $0.imageFingerprint != nil },
                kind: .image
            ))
        }
        if options.scanSimilarVideos {
            clusters.append(contentsOf: buildSimilarityClusters(
                records: records.filter { $0.mediaKind == .video && $0.videoFingerprint != nil },
                kind: .video
            ))
        }
        if options.scanSimilarAudio {
            clusters.append(contentsOf: buildSimilarityClusters(
                records: records.filter { $0.mediaKind == .audio && $0.audioFingerprint != nil },
                kind: .audio
            ))
        }
        let fileMap = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return clusters
            .filter { cluster in
                let memberPaths = cluster.memberIDs.compactMap { fileMap[$0]?.path }
                let signature = ReviewDismissSignature.similarCluster(mediaKind: cluster.mediaKind, memberPaths: memberPaths)
                return !dismissedSignatures.contains(signature)
            }
            .sorted { $0.similarityScore > $1.similarityScore }
    }

    private func buildSimilarityClusters(records: [FileRecord], kind: MediaKind) -> [SimilarCluster] {
        guard records.count > 1 else {
            return []
        }

        var pairScores: [PairKey: Double] = [:]

        for leftIndex in 0..<records.count {
            for rightIndex in (leftIndex + 1)..<records.count {
                let score: Double?
                switch kind {
                case .image:
                    score = FingerprintSimilarity.imageSimilarity(records[leftIndex].imageFingerprint!, records[rightIndex].imageFingerprint!)
                case .video:
                    score = FingerprintSimilarity.videoSimilarity(records[leftIndex].videoFingerprint!, records[rightIndex].videoFingerprint!)
                case .audio:
                    let left = records[leftIndex]
                    let right = records[rightIndex]
                    let acousticScore = FingerprintSimilarity.audioSimilarity(left.audioFingerprint!, right.audioFingerprint!)
                    if let acousticScore {
                        let nameScore = audioNameSimilarity(left.path, right.path)
                        if acousticScore < 0.97, nameScore < 0.34 {
                            score = nil
                        } else if acousticScore < 0.955, nameScore < 0.2 {
                            score = nil
                        } else {
                            score = min(1, (acousticScore * 0.92) + (nameScore * 0.08))
                        }
                    } else {
                        score = nil
                    }
                case .other:
                    score = nil
                }

                guard let score else {
                    continue
                }
                pairScores[PairKey(leftIndex, rightIndex)] = score
            }
        }

        let groups: [[Int]]
        if kind == .audio {
            groups = buildStrictSimilarityGroups(recordCount: records.count, pairScores: pairScores)
        } else {
            groups = buildUnionFindGroups(recordCount: records.count, pairScores: pairScores)
        }

        return groups.compactMap { indices in
            let members = indices.map { records[$0] }.sorted { $0.path < $1.path }
            let averagedScore = averageSimilarityScore(for: indices, pairScores: pairScores)
            guard averagedScore > 0 else { return nil }
            return SimilarCluster(
                id: stableID(volumeID: members[0].volumeID, fileID: members[0].fileID, path: members[0].path + "|sim"),
                mediaKind: kind,
                memberIDs: members.map(\.id),
                similarityScore: averagedScore,
                recommendedKeepID: nil
            )
        }
    }

    private func recommendedKeep(for members: [FileRecord]) -> FileRecord {
        members.min {
            keepRank(for: $0) < keepRank(for: $1)
        } ?? members[0]
    }

    private func keepRank(for record: FileRecord) -> KeepRank {
        let path = record.path.lowercased()
        let folderRank: Int
        if path.contains("/pictures/") || path.contains("/music/") || path.contains("/documents/") {
            folderRank = 0
        } else if record.sourceLocationKind == .custom {
            folderRank = 1
        } else if path.contains("/downloads/") {
            folderRank = 2
        } else if path.contains("/desktop/") {
            folderRank = 3
        } else {
            folderRank = 4
        }
        return KeepRank(
            folderRank: folderRank,
            createdAt: record.createdAt,
            pathLength: record.path.count,
            path: record.path
        )
    }

    private func shouldFingerprint(kind: MediaKind, options: ScanOptions) -> Bool {
        switch kind {
        case .image: return options.scanSimilarImages
        case .video: return options.scanSimilarVideos
        case .audio: return options.scanSimilarAudio
        case .other: return false
        }
    }

    private func shouldSkipDirectory(
        path: String,
        values: URLResourceValues,
        ignoreRules: [(scope: IgnoreScope, path: String)],
        excludedFragments: [String]
    ) -> Bool {
        if values.isPackage == true {
            return true
        }
        if excludedFragments.contains(where: { path.contains($0) }) {
            return true
        }
        return ignoreRules.contains { rule in
            rule.scope == .folder && path.hasPrefix(rule.path)
        }
    }

    private func shouldIgnore(path: String, ignoreRules: [(scope: IgnoreScope, path: String)]) -> Bool {
        ignoreRules.contains { rule in
            switch rule.scope {
            case .folder:
                return path.hasPrefix(rule.path)
            case .file:
                return path == rule.path
            }
        }
    }
}

private struct FileSeed: Sendable, Hashable {
    let id: String
    let path: String
    let volumeID: String
    let fileID: String
    let sourceLocationID: String
    let sourceLocationKind: ScanLocationKind
    let size: Int64
    let createdAt: Date
    let modifiedAt: Date
    let mediaKind: MediaKind

    var url: URL { URL(fileURLWithPath: path) }
    var cacheKey: String { "\(volumeID)|\(fileID)|\(size)|\(Int(modifiedAt.timeIntervalSince1970))" }

    func asRecord() -> FileRecord {
        FileRecord(
            id: id,
            path: path,
            volumeID: volumeID,
            fileID: fileID,
            sourceLocationID: sourceLocationID,
            sourceLocationKind: sourceLocationKind,
            size: size,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            mediaKind: mediaKind
        )
    }
}

private struct HashUpdate: Sendable {
    let id: String
    let path: String
    let volumeID: String
    let fileID: String
    let modifiedAt: Date
    let mediaKind: MediaKind
    let size: Int64
    let sampleHash: String
    let fullHash: String?
    let cacheHitCount: Int

    var cacheKey: String {
        "\(volumeID)|\(fileID)|\(size)|\(Int(modifiedAt.timeIntervalSince1970))"
    }
}

private struct FingerprintUpdate: Sendable {
    let id: String
    let payload: FingerprintPayload?
    let cacheHitCount: Int
}

private struct PairKey: Hashable {
    let lhs: Int
    let rhs: Int

    init(_ lhs: Int, _ rhs: Int) {
        self.lhs = min(lhs, rhs)
        self.rhs = max(lhs, rhs)
    }
}

private let audioClusterMembershipThreshold = 0.90

private enum FingerprintPayload: Sendable {
    case image(ImageFingerprint)
    case video(VideoFingerprint)
    case audio(AudioFingerprint)

    var imageValue: ImageFingerprint? {
        if case .image(let value) = self { return value }
        return nil
    }

    var videoValue: VideoFingerprint? {
        if case .video(let value) = self { return value }
        return nil
    }

    var audioValue: AudioFingerprint? {
        if case .audio(let value) = self { return value }
        return nil
    }
}

private struct KeepRank: Comparable {
    let folderRank: Int
    let createdAt: Date
    let pathLength: Int
    let path: String

    static func < (lhs: KeepRank, rhs: KeepRank) -> Bool {
        if lhs.folderRank != rhs.folderRank { return lhs.folderRank < rhs.folderRank }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.pathLength != rhs.pathLength { return lhs.pathLength < rhs.pathLength }
        return lhs.path < rhs.path
    }
}

private struct UnionFind {
    private var parent: [Int]

    init(count: Int) {
        self.parent = Array(0..<count)
    }

    mutating func find(_ value: Int) -> Int {
        if parent[value] == value {
            return value
        }
        parent[value] = find(parent[value])
        return parent[value]
    }

    mutating func union(_ lhs: Int, _ rhs: Int) {
        let left = find(lhs)
        let right = find(rhs)
        guard left != right else {
            return
        }
        parent[right] = left
    }
}

private func stableID(volumeID: String, fileID: String, path: String) -> String {
    let digest = SHA256.hash(data: Data("\(volumeID)|\(fileID)|\(path)".utf8))
    return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
}

private func ensureSampleHash(for seed: FileSeed, store: ScanStoreProtocol) throws -> HashUpdate {
    let cacheKey = fingerprintCacheKey(for: seed)
    if let cached = try store.cacheEntry(for: cacheKey), let sampleHash = cached.sampleHash {
        return HashUpdate(
            id: seed.id,
            path: seed.path,
            volumeID: seed.volumeID,
            fileID: seed.fileID,
            modifiedAt: seed.modifiedAt,
            mediaKind: seed.mediaKind,
            size: seed.size,
            sampleHash: sampleHash,
            fullHash: cached.fullHash,
            cacheHitCount: 1
        )
    }

    let sampleHash = try hashFile(url: seed.url, sampleOnly: true)
    let cacheEntry = CacheEntry(
        key: cacheKey,
        path: seed.path,
        volumeID: seed.volumeID,
        fileID: seed.fileID,
        size: seed.size,
        modifiedAt: seed.modifiedAt,
        mediaKind: seed.mediaKind,
        sampleHash: sampleHash,
        fullHash: nil,
        imageFingerprint: nil,
        videoFingerprint: nil,
        audioFingerprint: nil
    )
    try store.upsertCacheEntry(cacheEntry)
    return HashUpdate(
        id: seed.id,
        path: seed.path,
        volumeID: seed.volumeID,
        fileID: seed.fileID,
        modifiedAt: seed.modifiedAt,
        mediaKind: seed.mediaKind,
        size: seed.size,
        sampleHash: sampleHash,
        fullHash: nil,
        cacheHitCount: 0
    )
}

private func ensureFullHash(for update: HashUpdate, store: ScanStoreProtocol) throws -> HashUpdate {
    guard let record = try store.cacheEntry(for: update.cacheKey), record.sampleHash == update.sampleHash else {
        return try computeMissingFullHash(update: update, store: store)
    }
    if let fullHash = record.fullHash {
        return HashUpdate(
            id: update.id,
            path: update.path,
            volumeID: update.volumeID,
            fileID: update.fileID,
            modifiedAt: update.modifiedAt,
            mediaKind: update.mediaKind,
            size: update.size,
            sampleHash: update.sampleHash,
            fullHash: fullHash,
            cacheHitCount: update.cacheHitCount + 1
        )
    }
    return try computeMissingFullHash(update: update, store: store)
}

private func computeMissingFullHash(update: HashUpdate, store: ScanStoreProtocol) throws -> HashUpdate {
    let fullHash = try hashFile(url: URL(fileURLWithPath: update.path), sampleOnly: false)
    let existing = try store.cacheEntry(for: update.cacheKey)
    let cacheEntry = CacheEntry(
        key: update.cacheKey,
        path: update.path,
        volumeID: update.volumeID,
        fileID: update.fileID,
        size: update.size,
        modifiedAt: update.modifiedAt,
        mediaKind: update.mediaKind,
        sampleHash: update.sampleHash,
        fullHash: fullHash,
        imageFingerprint: existing?.imageFingerprint,
        videoFingerprint: existing?.videoFingerprint,
        audioFingerprint: existing?.audioFingerprint
    )
    try store.upsertCacheEntry(cacheEntry)
    return HashUpdate(
        id: update.id,
        path: update.path,
        volumeID: update.volumeID,
        fileID: update.fileID,
        modifiedAt: update.modifiedAt,
        mediaKind: update.mediaKind,
        size: update.size,
        sampleHash: update.sampleHash,
        fullHash: fullHash,
        cacheHitCount: update.cacheHitCount
    )
}

private func ensureFingerprint(
    for seed: FileSeed,
    store: ScanStoreProtocol,
    imageFingerprinter: ImageFingerprinter,
    videoFingerprinter: VideoFingerprinter,
    audioFingerprinter: AudioFingerprinter
) async throws -> FingerprintUpdate {
    let cacheKey = fingerprintCacheKey(for: seed)
    if let cached = try store.cacheEntry(for: cacheKey) {
        switch seed.mediaKind {
        case .image where cached.imageFingerprint != nil:
            return FingerprintUpdate(id: seed.id, payload: .image(cached.imageFingerprint!), cacheHitCount: 1)
        case .video where cached.videoFingerprint != nil:
            return FingerprintUpdate(id: seed.id, payload: .video(cached.videoFingerprint!), cacheHitCount: 1)
        case .audio where cached.audioFingerprint != nil:
            return FingerprintUpdate(id: seed.id, payload: .audio(cached.audioFingerprint!), cacheHitCount: 1)
        default:
            break
        }
    }

    let fingerprint: FingerprintPayload?
    switch seed.mediaKind {
    case .image:
        fingerprint = try imageFingerprinter.fingerprint(url: seed.url).map(FingerprintPayload.image)
    case .video:
        fingerprint = try await videoFingerprinter.fingerprint(url: seed.url).map(FingerprintPayload.video)
    case .audio:
        fingerprint = try await audioFingerprinter.fingerprint(url: seed.url).map(FingerprintPayload.audio)
    case .other:
        fingerprint = nil
    }

    if let fingerprint {
        let existing = try store.cacheEntry(for: cacheKey)
        let cacheEntry = CacheEntry(
            key: cacheKey,
            path: seed.path,
            volumeID: seed.volumeID,
            fileID: seed.fileID,
            size: seed.size,
            modifiedAt: seed.modifiedAt,
            mediaKind: seed.mediaKind,
            sampleHash: existing?.sampleHash,
            fullHash: existing?.fullHash,
            imageFingerprint: fingerprint.imageValue ?? existing?.imageFingerprint,
            videoFingerprint: fingerprint.videoValue ?? existing?.videoFingerprint,
            audioFingerprint: fingerprint.audioValue ?? existing?.audioFingerprint
        )
        try store.upsertCacheEntry(cacheEntry)
    }

    return FingerprintUpdate(id: seed.id, payload: fingerprint, cacheHitCount: 0)
}

private func fingerprintCacheKey(for seed: FileSeed) -> String {
    switch seed.mediaKind {
    case .audio:
        return "\(seed.cacheKey)|audiofp-v3"
    case .image, .video, .other:
        return seed.cacheKey
    }
}

private func buildUnionFindGroups(recordCount: Int, pairScores: [PairKey: Double]) -> [[Int]] {
    var unionFind = UnionFind(count: recordCount)
    for pair in pairScores.keys {
        unionFind.union(pair.lhs, pair.rhs)
    }
    return Dictionary(grouping: 0..<recordCount, by: { unionFind.find($0) })
        .values
        .filter { $0.count > 1 }
        .map(Array.init)
}

private func buildStrictSimilarityGroups(recordCount: Int, pairScores: [PairKey: Double]) -> [[Int]] {
    guard !pairScores.isEmpty else {
        return []
    }

    var neighbors: [Int: [Int]] = [:]
    for pair in pairScores.keys {
        neighbors[pair.lhs, default: []].append(pair.rhs)
        neighbors[pair.rhs, default: []].append(pair.lhs)
    }

    let orderedSeeds = (0..<recordCount).sorted { (neighbors[$0]?.count ?? 0) > (neighbors[$1]?.count ?? 0) }
    var assigned: Set<Int> = []
    var groups: [[Int]] = []

    for seed in orderedSeeds where !assigned.contains(seed) {
        guard let directNeighbors = neighbors[seed], !directNeighbors.isEmpty else {
            continue
        }

        var cluster = [seed]
        let rankedNeighbors = directNeighbors.sorted { left, right in
            (pairScores[PairKey(seed, left)] ?? 0) > (pairScores[PairKey(seed, right)] ?? 0)
        }

        for candidate in rankedNeighbors where !assigned.contains(candidate) {
            let isStrongWithCluster = cluster.allSatisfy { member in
                guard let score = pairScores[PairKey(candidate, member)] else { return false }
                return score >= audioClusterMembershipThreshold
            }
            if isStrongWithCluster {
                cluster.append(candidate)
            }
        }

        guard cluster.count > 1 else {
            continue
        }

        assigned.formUnion(cluster)
        groups.append(cluster.sorted())
    }

    return groups
}

private func averageSimilarityScore(for indices: [Int], pairScores: [PairKey: Double]) -> Double {
    var scores: [Double] = []
    for leftOffset in 0..<indices.count {
        for rightOffset in (leftOffset + 1)..<indices.count {
            if let score = pairScores[PairKey(indices[leftOffset], indices[rightOffset])] {
                scores.append(score)
            }
        }
    }
    guard !scores.isEmpty else {
        return 0
    }
    return scores.reduce(0, +) / Double(scores.count)
}

private func audioNameSimilarity(_ lhsPath: String, _ rhsPath: String) -> Double {
    let lhsTokens = normalizedAudioNameTokens(lhsPath)
    let rhsTokens = normalizedAudioNameTokens(rhsPath)
    guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else {
        return 0
    }

    let lhsSet = Set(lhsTokens)
    let rhsSet = Set(rhsTokens)
    let overlap = lhsSet.intersection(rhsSet).count
    guard overlap > 0 else {
        return 0
    }

    let overlapCoefficient = Double(overlap) / Double(min(lhsSet.count, rhsSet.count))
    let jaccard = Double(overlap) / Double(lhsSet.union(rhsSet).count)
    return max(overlapCoefficient, jaccard)
}

private func normalizedAudioNameTokens(_ path: String) -> [String] {
    let noiseWords: Set<String> = [
        "extended", "mix", "remix", "edit", "original", "radio", "club", "dub",
        "version", "remaster", "records", "recordings", "feat", "featuring", "ft",
        "va", "vol", "pt", "part", "the", "and", "with", "official"
    ]

    let stem = URL(fileURLWithPath: path)
        .deletingPathExtension()
        .lastPathComponent
        .lowercased()
        .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)

    return stem
        .split(separator: " ")
        .map(String.init)
        .filter { $0.count >= 2 && !noiseWords.contains($0) }
}

private func hashFile(url: URL, sampleOnly: Bool) throws -> String {
    let fileManager = FileManager.default
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hasher = SHA256()
    let chunkSize = 64 * 1024

    if sampleOnly {
        let head = try handle.read(upToCount: chunkSize) ?? Data()
        hasher.update(data: head)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? Int64(head.count)
        if size > Int64(chunkSize) {
            try handle.seek(toOffset: UInt64(max(0, size - Int64(chunkSize))))
            let tail = try handle.readToEnd() ?? Data()
            hasher.update(data: tail)
        }
    } else {
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            hasher.update(data: data)
        }
    }

    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func boundedConcurrentMap<Input: Sendable, Output: Sendable>(
    items: [Input],
    limit: Int,
    operation: @escaping @Sendable (Input) async throws -> Output
) async throws -> [Output] {
    guard !items.isEmpty else {
        return []
    }

    return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
        var iterator = Array(items.enumerated()).makeIterator()
        var results = Array<Output?>(repeating: nil, count: items.count)

        for _ in 0..<min(limit, items.count) {
            guard let next = iterator.next() else { break }
            group.addTask {
                (next.offset, try await operation(next.element))
            }
        }

        while let (index, output) = try await group.next() {
            results[index] = output
            if let next = iterator.next() {
                group.addTask {
                    (next.offset, try await operation(next.element))
                }
            }
        }

        return results.compactMap { $0 }
    }
}
