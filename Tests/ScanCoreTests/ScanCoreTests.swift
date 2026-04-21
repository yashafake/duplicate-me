import CoreGraphics
import Foundation
import ImageIO
import ScanCore
import ScanStore
import Testing
import UniformTypeIdentifiers

struct ScanCoreTests {
    @Test
    func exactDuplicatesAreFoundAndRescanUsesCache() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        try "same content".write(to: workspace.root.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try "same content".write(to: workspace.root.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        try "unique".write(to: workspace.root.appendingPathComponent("three.txt"), atomically: true, encoding: .utf8)

        let engine = DuplicateMeEngine(store: workspace.store)
        let runID = try await engine.scan(
            locations: [ScanLocation(path: workspace.root.path, kind: .custom)],
            options: ScanOptions(scanDuplicates: true)
        )

        let results = try await engine.getResults(scanRunId: runID)
        #expect(results.duplicateClusters.count == 1)
        #expect(results.duplicateClusters.first?.memberIDs.count == 2)
        #expect(results.stats.totalFiles == 3)

        let rescanID = try await engine.rescan(runID: runID)
        let rescanResults = try await engine.getResults(scanRunId: rescanID)
        #expect(rescanResults.stats.cacheHits > 0)
    }

    @Test
    func ignoreRulesAndTrashSafety() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let ignored = workspace.root.appendingPathComponent("ignored", isDirectory: true)
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try "same content".write(to: ignored.appendingPathComponent("ignore-a.txt"), atomically: true, encoding: .utf8)
        try "same content".write(to: ignored.appendingPathComponent("ignore-b.txt"), atomically: true, encoding: .utf8)
        try workspace.store.addIgnoreRule(IgnoreRule(scope: .folder, path: ignored.path))

        try "live duplicate".write(to: workspace.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "live duplicate".write(to: workspace.root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let engine = DuplicateMeEngine(store: workspace.store)
        let runID = try await engine.scan(
            locations: [ScanLocation(path: workspace.root.path, kind: .custom)],
            options: ScanOptions(scanDuplicates: true)
        )
        let results = try await engine.getResults(scanRunId: runID)
        #expect(results.duplicateClusters.count == 1)

        let cluster = try #require(results.duplicateClusters.first)
        let targetID = try #require(cluster.autoSelectedIDs.first)
        let targetRecord = try #require(results.files.first { $0.id == targetID })
        try "changed".write(to: targetRecord.url, atomically: true, encoding: .utf8)

        let report = try await engine.trash(
            selection: CleanupSelection(scanRunID: runID, clusterIDs: [cluster.id], memberIDs: [targetID])
        )
        #expect(report.trashedIDs.isEmpty)
        #expect(report.skippedChangedIDs == [targetID])
    }

    @Test
    func imageSimilarityProducesCluster() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let pngURL = workspace.root.appendingPathComponent("image-a.png")
        let jpgURL = workspace.root.appendingPathComponent("image-b.jpg")
        try writePatternImage(to: pngURL, type: UTType.png.identifier as CFString, size: CGSize(width: 180, height: 120))
        try writePatternImage(to: jpgURL, type: UTType.jpeg.identifier as CFString, size: CGSize(width: 220, height: 146), compression: 0.76)

        let engine = DuplicateMeEngine(store: workspace.store)
        let runID = try await engine.scan(
            locations: [ScanLocation(path: workspace.root.path, kind: .custom)],
            options: ScanOptions(scanDuplicates: false, scanSimilarImages: true)
        )
        let results = try await engine.getResults(scanRunId: runID)
        #expect(results.similarClusters.count == 1)
        #expect(results.similarClusters.first?.mediaKind == .image)
    }

    @Test
    func hardLinksAreNotReportedAsDuplicates() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let original = workspace.root.appendingPathComponent("original.txt")
        let linked = workspace.root.appendingPathComponent("linked.txt")
        try "same inode".write(to: original, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: original, to: linked)

        let engine = DuplicateMeEngine(store: workspace.store)
        let runID = try await engine.scan(
            locations: [ScanLocation(path: workspace.root.path, kind: .custom)],
            options: ScanOptions(scanDuplicates: true)
        )

        let results = try await engine.getResults(scanRunId: runID)
        #expect(results.duplicateClusters.isEmpty)
    }

    @Test
    func trashMovesUnchangedDuplicateSelection() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        try "same payload".write(to: workspace.root.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        try "same payload".write(to: workspace.root.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)

        let engine = DuplicateMeEngine(store: workspace.store)
        let runID = try await engine.scan(
            locations: [ScanLocation(path: workspace.root.path, kind: .custom)],
            options: ScanOptions(scanDuplicates: true)
        )
        let results = try await engine.getResults(scanRunId: runID)
        let cluster = try #require(results.duplicateClusters.first)
        let targetID = try #require(cluster.autoSelectedIDs.first)

        let report = try await engine.trash(
            selection: CleanupSelection(scanRunID: runID, clusterIDs: [cluster.id], memberIDs: [targetID])
        )

        #expect(report.trashedIDs == [targetID])
        #expect(report.skippedChangedIDs.isEmpty)
        #expect(report.failedIDs.isEmpty)
    }

    @Test
    func preparedScanCanBeExecutedSeparately() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        try "same payload".write(to: workspace.root.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        try "same payload".write(to: workspace.root.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)

        let engine = DuplicateMeEngine(store: workspace.store)
        let runID = try await engine.prepareScan(
            locations: [ScanLocation(path: workspace.root.path, kind: .custom)],
            options: ScanOptions(scanDuplicates: true)
        )

        let initialProgress = try await engine.getProgress(scanRunId: runID)
        #expect(initialProgress.stage == .enumerating)

        try await engine.executePreparedScan(runID: runID)

        let results = try await engine.getResults(scanRunId: runID)
        #expect(results.duplicateClusters.count == 1)
        #expect(results.stats.totalFiles == 2)
    }

    @Test
    func latestCompletedRunSkipsNewerIncompleteRun() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        try "same payload".write(to: workspace.root.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        try "same payload".write(to: workspace.root.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)

        let engine = DuplicateMeEngine(store: workspace.store)
        let completedRunID = try await engine.scan(
            locations: [ScanLocation(path: workspace.root.path, kind: .custom)],
            options: ScanOptions(scanDuplicates: true)
        )

        let incompleteRunID = try await engine.prepareScan(
            locations: [ScanLocation(path: workspace.root.path, kind: .custom)],
            options: ScanOptions(scanDuplicates: true)
        )

        let latestRun = try #require(try workspace.store.latestRun())
        #expect(latestRun.id == incompleteRunID)

        let latestCompletedRun = try #require(try workspace.store.latestCompletedRun())
        #expect(latestCompletedRun.id == completedRunID)
        #expect(latestCompletedRun.results != nil)
    }

    @Test
    func dismissedSimilarClusterIsFilteredFromFutureScans() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let pngURL = workspace.root.appendingPathComponent("image-a.png")
        let jpgURL = workspace.root.appendingPathComponent("image-b.jpg")
        try writePatternImage(to: pngURL, type: UTType.png.identifier as CFString, size: CGSize(width: 180, height: 120))
        try writePatternImage(to: jpgURL, type: UTType.jpeg.identifier as CFString, size: CGSize(width: 220, height: 146), compression: 0.76)

        let engine = DuplicateMeEngine(store: workspace.store)
        let runID = try await engine.scan(
            locations: [ScanLocation(path: workspace.root.path, kind: .custom)],
            options: ScanOptions(scanDuplicates: false, scanSimilarImages: true)
        )
        let results = try await engine.getResults(scanRunId: runID)
        let cluster = try #require(results.similarClusters.first)
        let fileMap = Dictionary(uniqueKeysWithValues: results.files.map { ($0.id, $0) })
        let signature = ReviewDismissSignature.similarCluster(
            mediaKind: cluster.mediaKind,
            memberPaths: cluster.memberIDs.compactMap { fileMap[$0]?.path }
        )

        try workspace.store.addReviewDismissRule(
            ReviewDismissRule(kind: .similarCluster, signature: signature, mediaKind: cluster.mediaKind)
        )

        let rescanID = try await engine.scan(
            locations: [ScanLocation(path: workspace.root.path, kind: .custom)],
            options: ScanOptions(scanDuplicates: false, scanSimilarImages: true)
        )
        let rescanned = try await engine.getResults(scanRunId: rescanID)
        #expect(rescanned.similarClusters.isEmpty)
    }

    @Test
    func dismissedSimilarFileIsExcludedFromFutureScans() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let pngURL = workspace.root.appendingPathComponent("image-a.png")
        let jpgURL = workspace.root.appendingPathComponent("image-b.jpg")
        let jpgURLTwo = workspace.root.appendingPathComponent("image-c.jpg")
        try writePatternImage(to: pngURL, type: UTType.png.identifier as CFString, size: CGSize(width: 180, height: 120))
        try writePatternImage(to: jpgURL, type: UTType.jpeg.identifier as CFString, size: CGSize(width: 220, height: 146), compression: 0.76)
        try writePatternImage(to: jpgURLTwo, type: UTType.jpeg.identifier as CFString, size: CGSize(width: 215, height: 143), compression: 0.72)

        let engine = DuplicateMeEngine(store: workspace.store)
        let runID = try await engine.scan(
            locations: [ScanLocation(path: workspace.root.path, kind: .custom)],
            options: ScanOptions(scanDuplicates: false, scanSimilarImages: true)
        )
        let results = try await engine.getResults(scanRunId: runID)
        let fileToDismiss = try #require(results.files.first { $0.path == jpgURL.path })

        try workspace.store.addReviewDismissRule(
            ReviewDismissRule(
                kind: .similarFile,
                signature: ReviewDismissSignature.similarFile(path: fileToDismiss.path),
                mediaKind: fileToDismiss.mediaKind
            )
        )

        let rescanID = try await engine.scan(
            locations: [ScanLocation(path: workspace.root.path, kind: .custom)],
            options: ScanOptions(scanDuplicates: false, scanSimilarImages: true)
        )
        let rescanned = try await engine.getResults(scanRunId: rescanID)
        let rescannedFileMap = Dictionary(uniqueKeysWithValues: rescanned.files.map { ($0.id, $0) })
        #expect(rescanned.similarClusters.allSatisfy { cluster in
            cluster.memberIDs.compactMap { rescannedFileMap[$0]?.path }.allSatisfy { $0 != jpgURL.path }
        })
    }

    @Test
    func audioSimilarityProducesClusterForSameTrackAcrossVariants() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let first = workspace.root.appendingPathComponent("Artist - Track Name (Extended Mix).wav")
        let second = workspace.root.appendingPathComponent("Artist - Track Name (Radio Edit).wav")
        try writeWAV(to: first, sampleRate: 44_100, duration: 1.4, baseFrequency: 440)
        try writeWAV(to: second, sampleRate: 22_050, duration: 1.4, baseFrequency: 440)

        let engine = DuplicateMeEngine(store: workspace.store)
        let runID = try await engine.scan(
            locations: [ScanLocation(path: workspace.root.path, kind: .custom)],
            options: ScanOptions(scanDuplicates: false, scanSimilarAudio: true)
        )

        let results = try await engine.getResults(scanRunId: runID)
        #expect(results.similarClusters.count == 1)
        #expect(results.similarClusters.first?.mediaKind == .audio)
        #expect(results.similarClusters.first?.memberIDs.count == 2)
    }
}

private struct TestWorkspace {
    let root: URL
    let store: SQLiteScanStore
}

private func makeWorkspace() throws -> TestWorkspace {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-store.sqlite")
    return TestWorkspace(root: root, store: try SQLiteScanStore(databaseURL: dbURL))
}

private func writePatternImage(to url: URL, type: CFString, size: CGSize, compression: CGFloat? = nil) throws {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw NSError(domain: "ScanCoreTests", code: 1)
    }
    let width = Int(size.width)
    let height = Int(size.height)
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "ScanCoreTests", code: 2)
    }

    context.setFillColor(CGColor(red: 0.98, green: 0.96, blue: 0.88, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    context.setFillColor(CGColor(red: 0.15, green: 0.33, blue: 0.72, alpha: 1))
    context.fill(CGRect(x: size.width * 0.08, y: size.height * 0.12, width: size.width * 0.6, height: size.height * 0.18))
    context.setFillColor(CGColor(red: 0.82, green: 0.29, blue: 0.19, alpha: 1))
    context.fillEllipse(in: CGRect(x: size.width * 0.55, y: size.height * 0.36, width: size.width * 0.26, height: size.width * 0.26))
    context.setStrokeColor(CGColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1))
    context.setLineWidth(max(2, size.width * 0.03))
    context.stroke(CGRect(x: size.width * 0.16, y: size.height * 0.48, width: size.width * 0.36, height: size.height * 0.3))

    guard let image = context.makeImage() else {
        throw NSError(domain: "ScanCoreTests", code: 3)
    }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
        throw NSError(domain: "ScanCoreTests", code: 4)
    }

    if let compression {
        let options = [kCGImageDestinationLossyCompressionQuality: compression] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
    } else {
        CGImageDestinationAddImage(destination, image, nil)
    }

    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "ScanCoreTests", code: 5)
    }
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

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    var copy = value.littleEndian
    return withUnsafeBytes(of: &copy) { Data($0) }
}
