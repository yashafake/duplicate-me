import AppKit
import AVFoundation
import Foundation
import ImageIO
import MediaFingerprint
import Network
import ScanCore
import UniformTypeIdentifiers

final class ReviewWebServer: @unchecked Sendable {
    private let engine: DuplicateMeEngine
    private let store: ScanStoreProtocol
    private let state: ReviewSessionState
    private let listener: NWListener
    private let queue = DispatchQueue(label: "duplicate-me.review-server")
    private let reviewToken = UUID().uuidString
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(run: ScanRun?, engine: DuplicateMeEngine, store: ScanStoreProtocol, port: UInt16?) throws {
        self.engine = engine
        self.store = store
        let dismissRules = try store.listReviewDismissRules()
        let dismissedSimilarClusterSignatures = Set(
            dismissRules
                .filter { $0.kind == .similarCluster }
                .map(\.signature)
        )
        let dismissedSimilarFileSignatures = Set(
            dismissRules
                .filter { $0.kind == .similarFile }
                .map(\.signature)
        )
        self.state = ReviewSessionState(
            initialRun: run,
            dismissedSimilarClusterSignatures: dismissedSimilarClusterSignatures,
            dismissedSimilarFileSignatures: dismissedSimilarFileSignatures
        )

        if let port, let endpointPort = NWEndpoint.Port(rawValue: port) {
            self.listener = try NWListener(using: .tcp, on: endpointPort)
        } else {
            self.listener = try NWListener(using: .tcp)
        }

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func run(opensBrowser: Bool) async throws {
        let url = try await start()
        print("review_url=\(url.absoluteString)")
        if opensBrowser {
            NSWorkspace.shared.open(url)
        }

        while true {
            try await Task.sleep(for: .seconds(86_400))
        }
    }

    private func start() async throws -> URL {
        final class ReadyState: @unchecked Sendable {
            var didResume = false
        }

        let readyState = ReadyState()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !readyState.didResume, let port = self.listener.port else { return }
                    readyState.didResume = true
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/")!)
                case .failed(let error):
                    guard !readyState.didResume else { return }
                    readyState.didResume = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.finish(connection: connection, with: self.errorResponse(status: 500, message: error.localizedDescription))
                return
            }

            var buffer = accumulated
            if let data {
                buffer.append(data)
            }

            if let request = self.parseRequest(from: buffer) {
                Task {
                    let response = await self.route(request)
                    self.finish(connection: connection, with: response)
                }
                return
            }

            if isComplete {
                self.finish(connection: connection, with: self.errorResponse(status: 400, message: "Incomplete HTTP request."))
                return
            }

            self.receive(on: connection, accumulated: buffer)
        }
    }

    private func finish(connection: NWConnection, with response: HTTPResponse) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return .ok(Data(shellHTML().utf8), contentType: "text/html; charset=utf-8")
        case ("GET", "/review.css"):
            return assetResponse(named: "review", extension: "css", mimeType: "text/css; charset=utf-8")
        case ("GET", "/review.js"):
            return assetResponse(named: "review", extension: "js", mimeType: "text/javascript; charset=utf-8")
        case ("GET", "/api/session"):
            do {
                let activeScanRunID = await state.activeScanRunID
                let scanProgress = try activeScanRunID.flatMap { runID in
                    try store.loadRun(id: runID)?.progress
                }
                let payload = await state.payload(scanProgress: scanProgress)
                let data = try encoder.encode(payload)
                return .ok(data, contentType: "application/json; charset=utf-8")
            } catch {
                return errorResponse(status: 500, message: error.localizedDescription)
            }
        case ("GET", "/api/run"):
            do {
                guard let payload = await state.currentRunPayload() else {
                    return errorResponse(status: 404, message: "No scan results loaded.")
                }
                let data = try encoder.encode(payload)
                return .ok(data, contentType: "application/json; charset=utf-8")
            } catch {
                return errorResponse(status: 500, message: error.localizedDescription)
            }
        case ("GET", "/health"):
            return .ok(Data("ok".utf8), contentType: "text/plain; charset=utf-8")
        case ("POST", "/api/pick-folders"):
            guard request.header(named: "x-viewer-token") == reviewToken else {
                return errorResponse(status: 403, message: "Missing or invalid review token.")
            }
            do {
                let locations = pickFolders()
                await state.setSelectedLocations(locations)
                let data = try encoder.encode(FolderSelectionResponse(locations: locations))
                return .ok(data, contentType: "application/json; charset=utf-8")
            } catch {
                return errorResponse(status: 500, message: error.localizedDescription)
            }
        case ("POST", "/api/scan"):
            guard request.header(named: "x-viewer-token") == reviewToken else {
                return errorResponse(status: 403, message: "Missing or invalid review token.")
            }
            do {
                guard !(await state.isScanning) else {
                    return errorResponse(status: 409, message: "A scan is already running in this browser session.")
                }
                let body = try decoder.decode(ScanActionRequest.self, from: request.body)
                let normalizedLocations = body.locations.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
                guard !normalizedLocations.isEmpty else {
                    return errorResponse(status: 400, message: "At least one folder is required.")
                }
                let scanLocations = normalizedLocations.map { ScanLocation(path: $0, kind: .custom, isEnabled: true) }
                let runID = try await engine.prepareScan(locations: scanLocations, options: body.options)
                await state.beginScan(locations: normalizedLocations, runID: runID)

                Task { [engine, store, state] in
                    do {
                        try await engine.executePreparedScan(runID: runID)
                        guard let run = try store.loadRun(id: runID) else {
                            await state.failScan(message: "Scan completed, but the run could not be loaded.")
                            return
                        }
                        await state.finishScan(run: run)
                    } catch {
                        await state.failScan(message: error.localizedDescription)
                    }
                }

                let scanProgress = try store.loadRun(id: runID)?.progress
                let data = try encoder.encode(await state.payload(scanProgress: scanProgress))
                return .ok(data, contentType: "application/json; charset=utf-8")
            } catch {
                return errorResponse(status: 500, message: error.localizedDescription)
            }
        case ("POST", "/api/clear-run"):
            guard request.header(named: "x-viewer-token") == reviewToken else {
                return errorResponse(status: 403, message: "Missing or invalid review token.")
            }
            guard !(await state.isScanning) else {
                return errorResponse(status: 409, message: "Cannot clear results while a scan is running.")
            }
            await state.clearCurrentRun()
            return .empty(status: 204)
        case ("POST", "/api/trash"):
            guard request.header(named: "x-viewer-token") == reviewToken else {
                return errorResponse(status: 403, message: "Missing or invalid review token.")
            }
            do {
                let body = try decoder.decode(TrashActionRequest.self, from: request.body)
                guard let runID = await state.runID else {
                    return errorResponse(status: 400, message: "No active scan run.")
                }
                let report = try await engine.trash(
                    selection: CleanupSelection(
                        scanRunID: runID,
                        clusterIDs: body.clusterIDs,
                        memberIDs: body.memberIDs
                    )
                )
                await state.applyCleanup(report)
                let data = try encoder.encode(report)
                return .ok(data, contentType: "application/json; charset=utf-8")
            } catch {
                return errorResponse(status: 400, message: error.localizedDescription)
            }
        case ("POST", "/api/reveal"):
            guard request.header(named: "x-viewer-token") == reviewToken else {
                return errorResponse(status: 403, message: "Missing or invalid review token.")
            }
            do {
                let body = try decoder.decode(RevealActionRequest.self, from: request.body)
                guard let record = await state.fileRecord(id: body.fileID) else {
                    return errorResponse(status: 404, message: "File not found in run.")
                }
                await MainActor.run {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NSWorkspace.shared.activateFileViewerSelecting([record.url])
                }
                return .empty(status: 204)
            } catch {
                return errorResponse(status: 400, message: error.localizedDescription)
            }
        case ("POST", "/api/dismiss-cluster"):
            guard request.header(named: "x-viewer-token") == reviewToken else {
                return errorResponse(status: 403, message: "Missing or invalid review token.")
            }
            do {
                let body = try decoder.decode(DismissClusterActionRequest.self, from: request.body)
                guard let payload = await state.dismissSimilarCluster(clusterID: body.clusterID) else {
                    return errorResponse(status: 404, message: "Similar cluster not found.")
                }
                try store.addReviewDismissRule(
                    ReviewDismissRule(
                        kind: .similarCluster,
                        signature: payload.signature,
                        mediaKind: payload.mediaKind
                    )
                )
                let data = try encoder.encode(["signature": payload.signature])
                return .ok(data, contentType: "application/json; charset=utf-8")
            } catch {
                return errorResponse(status: 400, message: error.localizedDescription)
            }
        case ("POST", "/api/dismiss-file"):
            guard request.header(named: "x-viewer-token") == reviewToken else {
                return errorResponse(status: 403, message: "Missing or invalid review token.")
            }
            do {
                let body = try decoder.decode(DismissFileActionRequest.self, from: request.body)
                guard let payload = await state.dismissSimilarFile(fileID: body.fileID) else {
                    return errorResponse(status: 404, message: "File not found in the active run.")
                }
                try store.addReviewDismissRule(
                    ReviewDismissRule(
                        kind: .similarFile,
                        signature: payload.signature,
                        mediaKind: payload.mediaKind
                    )
                )
                let data = try encoder.encode(["signature": payload.signature])
                return .ok(data, contentType: "application/json; charset=utf-8")
            } catch {
                return errorResponse(status: 400, message: error.localizedDescription)
            }
        case ("GET", let path) where path.hasPrefix("/preview/"):
            do {
                let fileID = String(path.dropFirst("/preview/".count))
                guard let record = await state.fileRecord(id: fileID) else {
                    return errorResponse(status: 404, message: "Preview target not found.")
                }
                if (record.mediaKind == .video || record.mediaKind == .audio), record.size > 64 * 1024 * 1024 {
                    return errorResponse(status: 413, message: "Preview is disabled for media over 64 MB.")
                }
                return try previewResponse(for: record, rangeHeader: request.header(named: "range"))
            } catch {
                return errorResponse(status: 500, message: error.localizedDescription)
            }
        case ("GET", let path) where path.hasPrefix("/thumbnail/"):
            do {
                let fileID = String(path.dropFirst("/thumbnail/".count))
                guard let record = await state.fileRecord(id: fileID) else {
                    return errorResponse(status: 404, message: "Thumbnail target not found.")
                }
                guard let data = try await thumbnailData(for: record) else {
                    return errorResponse(status: 404, message: "No thumbnail available.")
                }
                return .ok(data, contentType: "image/jpeg")
            } catch {
                return errorResponse(status: 500, message: error.localizedDescription)
            }
        case ("GET", "/favicon.ico"):
            return .empty(status: 204)
        default:
            return errorResponse(status: 404, message: "Route not found.")
        }
    }

    private func shellHTML() -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <title>DuplicateMe Review</title>
          <link rel="stylesheet" href="/review.css">
        </head>
        <body>
          <div id="app"></div>
          <script>
            window.DUPLICATEME_CONFIG = {
              reviewToken: "\(escapeForJavaScript(reviewToken))"
            };
          </script>
          <script type="module" src="/review.js"></script>
        </body>
        </html>
        """
    }

    private func assetResponse(named name: String, extension ext: String, mimeType: String) -> HTTPResponse {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
            return errorResponse(status: 500, message: "Missing bundled asset \(name).\(ext)")
        }
        do {
            let data = try Data(contentsOf: url)
            return .ok(data, contentType: mimeType)
        } catch {
            return errorResponse(status: 500, message: error.localizedDescription)
        }
    }

    private func errorResponse(status: Int, message: String) -> HTTPResponse {
        let body: [String: Any] = [
            "status": status,
            "message": message
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    private func parseRequest(from data: Data) -> HTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter) else {
            return nil
        }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return HTTPRequest(method: "INVALID", path: "/", headers: [:], body: Data())
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else {
            return nil
        }

        let rawPath = String(parts[1])
        let path = URLComponents(string: "http://localhost\(rawPath)")?.path ?? rawPath
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return HTTPRequest(method: String(parts[0]), path: path, headers: headers, body: body)
    }

    private func thumbnailData(for record: FileRecord) async throws -> Data? {
        switch record.mediaKind {
        case .image:
            guard
                let source = CGImageSourceCreateWithURL(record.url as CFURL, nil),
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 720
                    ] as CFDictionary
                )
            else {
                return nil
            }
            return try jpegData(from: image)
        case .video:
            let asset = AVURLAsset(url: record.url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 960, height: 720)
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            let timestamp = duration.isFinite && duration > 0 ? duration * 0.2 : 0
            let image = try generator.copyCGImage(at: CMTime(seconds: timestamp, preferredTimescale: 600), actualTime: nil)
            return try jpegData(from: image)
        case .audio, .other:
            return nil
        }
    }

    private func previewResponse(for record: FileRecord, rangeHeader: String?) throws -> HTTPResponse {
        let contentType = mimeType(for: record.url)
        let supportsRanges = record.mediaKind == .audio || record.mediaKind == .video

        guard supportsRanges, let rangeHeader else {
            let data = try Data(contentsOf: record.url, options: .mappedIfSafe)
            return HTTPResponse(
                status: 200,
                headers: [
                    "Accept-Ranges": supportsRanges ? "bytes" : "none",
                    "Content-Type": contentType
                ],
                body: data
            )
        }

        guard let range = parseByteRange(rangeHeader, fileSize: record.size) else {
            return HTTPResponse(
                status: 416,
                headers: [
                    "Accept-Ranges": "bytes",
                    "Content-Range": "bytes */\(record.size)",
                    "Content-Type": contentType
                ],
                body: Data()
            )
        }

        let data = try readFileChunk(from: record.url, range: range)
        return HTTPResponse(
            status: 206,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound)/\(record.size)",
                "Content-Type": contentType
            ],
            body: data
        )
    }

    private func parseByteRange(_ header: String, fileSize: Int64) -> ClosedRange<Int64>? {
        guard fileSize > 0 else { return nil }

        let prefix = "bytes="
        guard header.lowercased().hasPrefix(prefix) else { return nil }
        let rawValue = header.dropFirst(prefix.count).split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true).first
        guard let rawValue else { return nil }

        let bounds = rawValue.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }

        let lowerPart = String(bounds[0]).trimmingCharacters(in: .whitespaces)
        let upperPart = String(bounds[1]).trimmingCharacters(in: .whitespaces)

        if lowerPart.isEmpty {
            guard let suffixLength = Int64(upperPart), suffixLength > 0 else { return nil }
            let clampedLength = min(suffixLength, fileSize)
            let lowerBound = max(0, fileSize - clampedLength)
            return lowerBound...(fileSize - 1)
        }

        guard let lowerBound = Int64(lowerPart), lowerBound >= 0, lowerBound < fileSize else {
            return nil
        }

        if upperPart.isEmpty {
            return lowerBound...(fileSize - 1)
        }

        guard let parsedUpperBound = Int64(upperPart), parsedUpperBound >= lowerBound else {
            return nil
        }

        return lowerBound...min(parsedUpperBound, fileSize - 1)
    }

    private func readFileChunk(from url: URL, range: ClosedRange<Int64>) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        try handle.seek(toOffset: UInt64(range.lowerBound))
        let byteCount = Int(range.upperBound - range.lowerBound + 1)
        return try handle.read(upToCount: byteCount) ?? Data()
    }

    private func pickFolders() -> [String] {
        let script = """
        set chosenFolders to choose folder with prompt "Choose the folders DuplicateMe should scan." with multiple selections allowed
        set folderPaths to {}
        repeat with chosenFolder in chosenFolders
            set end of folderPaths to POSIX path of chosenFolder
        end repeat
        set AppleScript's text item delimiters to linefeed
        return folderPaths as text
        """

        do {
            let output = try runAppleScript(script)
            return output
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted()
        } catch let error as AppleScriptError where error.isUserCancellation {
            return []
        } catch {
            return []
        }
    }

    private func jpegData(from image: CGImage) throws -> Data {
        let mutable = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutable, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "ReviewWebServer", code: 11, userInfo: [NSLocalizedDescriptionKey: "Unable to create thumbnail destination."])
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ReviewWebServer", code: 12, userInfo: [NSLocalizedDescriptionKey: "Unable to finalize thumbnail."])
        }
        return mutable as Data
    }

    private func runAppleScript(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errorOutput = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw AppleScriptError(message: errorOutput.isEmpty ? "AppleScript folder picker failed." : errorOutput)
        }

        return output
    }
}

private actor ReviewSessionState {
    private var currentRun: ScanRun?
    private var hiddenMemberIDs: Set<String> = []
    private var dismissedSimilarClusterSignatures: Set<String>
    private var dismissedSimilarFileSignatures: Set<String>
    private var scanInFlight = false
    private var currentActiveScanRunID: String?
    private var scanErrorMessage: String?
    private var selectedLocations: [String]

    init(
        initialRun: ScanRun?,
        dismissedSimilarClusterSignatures: Set<String>,
        dismissedSimilarFileSignatures: Set<String>
    ) {
        self.currentRun = initialRun
        self.dismissedSimilarClusterSignatures = dismissedSimilarClusterSignatures
        self.dismissedSimilarFileSignatures = dismissedSimilarFileSignatures
        self.selectedLocations = initialRun?.locations.map(\.path) ?? []
    }

    var runID: String? {
        currentRun?.id
    }

    var activeScanRunID: String? {
        currentActiveScanRunID
    }

    var isScanning: Bool {
        scanInFlight
    }

    func setSelectedLocations(_ locations: [String]) {
        selectedLocations = locations
    }

    func beginScan(locations: [String], runID: String) {
        selectedLocations = locations
        scanInFlight = true
        currentActiveScanRunID = runID
        scanErrorMessage = nil
        hiddenMemberIDs.removeAll()
    }

    func finishScan(run: ScanRun) {
        currentRun = run
        scanInFlight = false
        currentActiveScanRunID = nil
        scanErrorMessage = nil
        hiddenMemberIDs.removeAll()
        selectedLocations = run.locations.map(\.path)
    }

    func failScan(message: String) {
        scanInFlight = false
        currentActiveScanRunID = nil
        scanErrorMessage = message
    }

    func clearCurrentRun() {
        currentRun = nil
        hiddenMemberIDs.removeAll()
        scanErrorMessage = nil
    }

    func applyCleanup(_ report: CleanupReport) {
        hiddenMemberIDs.formUnion(report.trashedIDs)
    }

    func dismissSimilarCluster(clusterID: String) -> DismissedSimilarClusterPayload? {
        guard
            let results = currentRun?.results,
            let cluster = results.similarClusters.first(where: { $0.id == clusterID })
        else {
            return nil
        }

        let fileMap = Dictionary(uniqueKeysWithValues: results.files.map { ($0.id, $0) })
        let memberPaths = cluster.memberIDs.compactMap { fileMap[$0]?.path }
        let signature = ReviewDismissSignature.similarCluster(mediaKind: cluster.mediaKind, memberPaths: memberPaths)
        dismissedSimilarClusterSignatures.insert(signature)
        return DismissedSimilarClusterPayload(signature: signature, mediaKind: cluster.mediaKind)
    }

    func dismissSimilarFile(fileID: String) -> DismissedSimilarFilePayload? {
        guard let record = currentRun?.results?.files.first(where: { $0.id == fileID }) else {
            return nil
        }
        let signature = ReviewDismissSignature.similarFile(path: record.path)
        dismissedSimilarFileSignatures.insert(signature)
        return DismissedSimilarFilePayload(signature: signature, mediaKind: record.mediaKind)
    }

    func fileRecord(id: String) -> FileRecord? {
        currentRun?.results?.files.first { $0.id == id }
    }

    func payload(scanProgress: ScanProgress?) -> ReviewSessionDocument {
        ReviewSessionDocument(
            version: 1,
            isScanning: scanInFlight,
            activeScanRunID: currentActiveScanRunID,
            scanProgress: scanProgress,
            scanErrorMessage: scanErrorMessage,
            selectedLocations: selectedLocations,
            currentRun: currentRunPayload()
        )
    }

    func currentRunPayload() -> ReviewDocument? {
        let run = filteredRun()
        guard let run else { return nil }
        let results = run.results
        let files = results?.files.map(ReviewFile.init) ?? []
        let duplicates = results?.duplicateClusters.map(ReviewDuplicateCluster.init) ?? []
        let similars = results?.similarClusters.map(ReviewSimilarCluster.init) ?? []

        return ReviewDocument(
            version: 1,
            runID: run.id,
            createdAt: run.createdAt,
            progress: run.progress,
            options: run.options,
            locations: run.locations,
            stats: results?.stats ?? ScanStatistics(totalFiles: 0, totalBytes: 0, duplicateClusters: 0, similarClusters: 0, reclaimableBytes: 0, cacheHits: 0),
            files: files,
            duplicateClusters: duplicates,
            similarClusters: similars
        )
    }

    private func filteredRun() -> ScanRun? {
        guard let currentRun else {
            return nil
        }
        guard let results = currentRun.results else {
            return currentRun
        }

        let files = results.files.filter { !hiddenMemberIDs.contains($0.id) }
        let fileMap = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })

        let duplicateClusters = results.duplicateClusters.compactMap { cluster -> DuplicateCluster? in
            let members = cluster.memberIDs.filter { fileMap[$0] != nil }
            guard members.count > 1 else { return nil }
            let keepID = fileMap[cluster.recommendedKeepID] != nil ? cluster.recommendedKeepID : members.first!
            let reclaimable = members
                .filter { $0 != keepID }
                .compactMap { fileMap[$0]?.size }
                .reduce(0, +)

            return DuplicateCluster(
                id: cluster.id,
                memberIDs: members,
                recommendedKeepID: keepID,
                autoSelectedIDs: cluster.autoSelectedIDs.filter { fileMap[$0] != nil && $0 != keepID },
                reclaimableBytes: reclaimable
            )
        }

        let similarClusters = results.similarClusters.compactMap { cluster -> SimilarCluster? in
            let members = cluster.memberIDs.filter {
                guard let record = fileMap[$0] else { return false }
                return !dismissedSimilarFileSignatures.contains(ReviewDismissSignature.similarFile(path: record.path))
            }
            guard members.count > 1 else { return nil }
            let memberPaths = members.compactMap { fileMap[$0]?.path }
            let signature = ReviewDismissSignature.similarCluster(mediaKind: cluster.mediaKind, memberPaths: memberPaths)
            guard !dismissedSimilarClusterSignatures.contains(signature) else { return nil }
            let recommendedKeepID = cluster.recommendedKeepID.flatMap { fileMap[$0] != nil ? $0 : nil }
            return SimilarCluster(
                id: cluster.id,
                mediaKind: cluster.mediaKind,
                memberIDs: members,
                similarityScore: cluster.similarityScore,
                recommendedKeepID: recommendedKeepID
            )
        }

        let updatedResults = ScanResults(
            generatedAt: results.generatedAt,
            files: files,
            duplicateClusters: duplicateClusters,
            similarClusters: similarClusters,
            stats: ScanStatistics(
            totalFiles: files.count,
            totalBytes: files.reduce(0) { $0 + $1.size },
            duplicateClusters: duplicateClusters.count,
            similarClusters: similarClusters.count,
            reclaimableBytes: duplicateClusters.reduce(0) { $0 + $1.reclaimableBytes },
            cacheHits: results.stats.cacheHits
        ))

        var run = currentRun
        run.results = updatedResults
        return run
    }
}

private struct ReviewSessionDocument: Encodable {
    let version: Int
    let isScanning: Bool
    let activeScanRunID: String?
    let scanProgress: ScanProgress?
    let scanErrorMessage: String?
    let selectedLocations: [String]
    let currentRun: ReviewDocument?
}

private struct ReviewDocument: Encodable {
    let version: Int
    let runID: String
    let createdAt: Date
    let progress: ScanProgress
    let options: ScanOptions
    let locations: [ScanLocation]
    let stats: ScanStatistics
    let files: [ReviewFile]
    let duplicateClusters: [ReviewDuplicateCluster]
    let similarClusters: [ReviewSimilarCluster]
}

private struct ReviewFile: Encodable {
    let id: String
    let path: String
    let sourceLocationKind: ScanLocationKind
    let size: Int64
    let createdAt: Date
    let modifiedAt: Date
    let mediaKind: MediaKind

    init(_ record: FileRecord) {
        self.id = record.id
        self.path = record.path
        self.sourceLocationKind = record.sourceLocationKind
        self.size = record.size
        self.createdAt = record.createdAt
        self.modifiedAt = record.modifiedAt
        self.mediaKind = record.mediaKind
    }
}

private struct ReviewDuplicateCluster: Encodable {
    let id: String
    let memberIDs: [String]
    let recommendedKeepID: String
    let autoSelectedIDs: [String]
    let reclaimableBytes: Int64

    init(_ cluster: DuplicateCluster) {
        self.id = cluster.id
        self.memberIDs = cluster.memberIDs
        self.recommendedKeepID = cluster.recommendedKeepID
        self.autoSelectedIDs = cluster.autoSelectedIDs
        self.reclaimableBytes = cluster.reclaimableBytes
    }
}

private struct ReviewSimilarCluster: Encodable {
    let id: String
    let mediaKind: MediaKind
    let memberIDs: [String]
    let similarityScore: Double
    let recommendedKeepID: String?

    init(_ cluster: SimilarCluster) {
        self.id = cluster.id
        self.mediaKind = cluster.mediaKind
        self.memberIDs = cluster.memberIDs
        self.similarityScore = cluster.similarityScore
        self.recommendedKeepID = cluster.recommendedKeepID
    }
}

private struct FolderSelectionResponse: Encodable {
    let locations: [String]
}

private struct ScanActionRequest: Decodable {
    let locations: [String]
    let options: ScanOptions
}

private struct TrashActionRequest: Decodable {
    let clusterIDs: [String]
    let memberIDs: [String]
}

private struct RevealActionRequest: Decodable {
    let fileID: String
}

private struct DismissClusterActionRequest: Decodable {
    let clusterID: String
}

private struct DismissedSimilarClusterPayload {
    let signature: String
    let mediaKind: MediaKind
}

private struct DismissFileActionRequest: Decodable {
    let fileID: String
}

private struct DismissedSimilarFilePayload {
    let signature: String
    let mediaKind: MediaKind
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    func header(named name: String) -> String? {
        headers[name.lowercased()]
    }
}

private struct HTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    static func ok(_ body: Data, contentType: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["Content-Type": contentType], body: body)
    }

    static func empty(status: Int) -> HTTPResponse {
        HTTPResponse(status: status, headers: [:], body: Data())
    }

    func serialized() -> Data {
        var lines = ["HTTP/1.1 \(status) \(reasonPhrase(for: status))"]
        let combinedHeaders = headers.merging([
            "Content-Length": "\(body.count)",
            "Connection": "close",
            "Cache-Control": "no-store"
        ]) { current, _ in current }
        for (name, value) in combinedHeaders.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }
        lines.append("")
        lines.append("")

        var data = Data(lines.joined(separator: "\r\n").utf8)
        data.append(body)
        return data
    }
}

private struct AppleScriptError: Error, LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }

    var isUserCancellation: Bool {
        message.contains("-128") || message.localizedCaseInsensitiveContains("User canceled")
    }
}

private func reasonPhrase(for status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 206: return "Partial Content"
    case 204: return "No Content"
    case 400: return "Bad Request"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 409: return "Conflict"
    case 413: return "Payload Too Large"
    case 416: return "Range Not Satisfiable"
    case 500: return "Internal Server Error"
    default: return "HTTP"
    }
}

private func mimeType(for url: URL) -> String {
    if let type = UTType(filenameExtension: url.pathExtension.lowercased()), let mime = type.preferredMIMEType {
        return mime
    }
    return "application/octet-stream"
}

private func escapeForJavaScript(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
}
