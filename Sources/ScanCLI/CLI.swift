import Foundation
import ScanCore
import ScanStore

@main
enum DuplicateMeCLI {
    static func main() async {
        do {
            let cli = try CLI(arguments: Array(CommandLine.arguments.dropFirst()))
            try await cli.run()
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private struct CLI {
    private let arguments: [String]
    private let store: SQLiteScanStore
    private let engine: DuplicateMeEngine
    private let encoder: JSONEncoder

    init(arguments: [String]) throws {
        self.arguments = arguments
        self.store = try SQLiteScanStore(databaseURL: Self.defaultDatabaseURL())
        self.engine = DuplicateMeEngine(store: store)
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    }

    func run() async throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }

        switch command {
        case "scan":
            try await runScan(Array(arguments.dropFirst()))
        case "rescan":
            try await runRescan(Array(arguments.dropFirst()))
        case "list-clusters":
            try await runListClusters(Array(arguments.dropFirst()))
        case "export-json":
            try runExportJSON(Array(arguments.dropFirst()))
        case "export-html":
            try runExportHTML(Array(arguments.dropFirst()))
        case "serve":
            try await runServe(Array(arguments.dropFirst()))
        case "trash":
            try await runTrash(Array(arguments.dropFirst()))
        case "ignore":
            try runIgnore(Array(arguments.dropFirst()))
        case "progress":
            try await runProgress(Array(arguments.dropFirst()))
        case "help", "--help", "-h":
            printUsage()
        default:
            throw CLIError("Unknown command '\(command)'.")
        }
    }

    private func runScan(_ args: [String]) async throws {
        let parser = try ArgumentParser(arguments: args)
        let locationPaths = parser.values(for: "--location")
        guard !locationPaths.isEmpty else {
            throw CLIError("scan requires at least one --location.")
        }

        let locations = locationPaths.map { path in
            ScanLocation(path: normalize(path), kind: .custom, isEnabled: true)
        }
        let options = ScanOptions(
            scanDuplicates: !parser.hasFlag("--no-duplicates"),
            scanSimilarImages: parser.hasFlag("--similar-images"),
            scanSimilarVideos: parser.hasFlag("--similar-videos"),
            scanSimilarAudio: parser.hasFlag("--similar-audio"),
            includeHidden: parser.hasFlag("--include-hidden")
        )

        let runID = try await engine.scan(locations: locations, options: options)
        let results = try await engine.getResults(scanRunId: runID)
        print("scan_run_id=\(runID)")
        print("files=\(results.stats.totalFiles) duplicates=\(results.stats.duplicateClusters) similars=\(results.stats.similarClusters) reclaimable=\(results.stats.reclaimableBytes)")
    }

    private func runRescan(_ args: [String]) async throws {
        let parser = try ArgumentParser(arguments: args)
        let runID = parser.value(for: "--run-id")
        let newRunID = try await engine.rescan(runID: runID)
        let results = try await engine.getResults(scanRunId: newRunID)
        print("scan_run_id=\(newRunID)")
        print("files=\(results.stats.totalFiles) duplicates=\(results.stats.duplicateClusters) similars=\(results.stats.similarClusters) reclaimable=\(results.stats.reclaimableBytes)")
    }

    private func runListClusters(_ args: [String]) async throws {
        let parser = try ArgumentParser(arguments: args)
        let runID = try parser.requiredValue(for: "--run-id")
        let kind = parser.value(for: "--kind") ?? "all"
        let results = try await engine.getResults(scanRunId: runID)

        if kind == "all" || kind == "duplicates" {
            print("duplicate_clusters:")
            for cluster in results.duplicateClusters {
                print("- id=\(cluster.id) members=\(cluster.memberIDs.count) keep=\(cluster.recommendedKeepID) reclaimable=\(cluster.reclaimableBytes)")
            }
        }
        if kind == "all" || kind == "similar" {
            print("similar_clusters:")
            for cluster in results.similarClusters {
                print("- id=\(cluster.id) kind=\(cluster.mediaKind.rawValue) members=\(cluster.memberIDs.count) score=\(String(format: "%.3f", cluster.similarityScore))")
            }
        }
    }

    private func runExportJSON(_ args: [String]) throws {
        let parser = try ArgumentParser(arguments: args)
        let runID = try parser.requiredValue(for: "--run-id")
        let outputPath = try parser.requiredValue(for: "--output")
        guard let run = try store.loadRun(id: runID) else {
            throw CLIError("Run '\(runID)' not found.")
        }

        let envelope = ExportEnvelope(version: 1, run: run)
        let data = try encoder.encode(envelope)
        try data.write(to: URL(fileURLWithPath: normalize(outputPath)), options: .atomic)
        print("wrote \(normalize(outputPath))")
    }

    private func runExportHTML(_ args: [String]) throws {
        let parser = try ArgumentParser(arguments: args)
        let runID = try parser.requiredValue(for: "--run-id")
        let outputPath = try parser.requiredValue(for: "--output")
        guard let run = try store.loadRun(id: runID) else {
            throw CLIError("Run '\(runID)' not found.")
        }
        try HTMLReportExporter().export(run: run, to: URL(fileURLWithPath: normalize(outputPath)))
        print("wrote \(normalize(outputPath))")
    }

    private func runServe(_ args: [String]) async throws {
        let parser = try ArgumentParser(arguments: args)
        let requestedRunID = parser.value(for: "--run-id")
        let port = try parser.optionalUInt16Value(for: "--port")
        let opensBrowser = !parser.hasFlag("--no-open")

        let run: ScanRun?
        if let requestedRunID {
            guard let loaded = try store.loadRun(id: requestedRunID) else {
                throw CLIError("Run '\(requestedRunID)' not found.")
            }
            guard loaded.results != nil else {
                throw CLIError("Run '\(requestedRunID)' has no results yet. Start `serve` without `--run-id`, or finish the scan first.")
            }
            run = loaded
        } else {
            run = try store.latestCompletedRun()
        }

        let server = try ReviewWebServer(run: run, engine: engine, store: store, port: port)
        try await server.run(opensBrowser: opensBrowser)
    }

    private func runTrash(_ args: [String]) async throws {
        let parser = try ArgumentParser(arguments: args)
        let runID = try parser.requiredValue(for: "--run-id")
        let memberIDs = parser.values(for: "--member")
        let clusterIDs = parser.values(for: "--cluster")
        guard !memberIDs.isEmpty else {
            throw CLIError("trash requires at least one --member.")
        }

        let report = try await engine.trash(selection: CleanupSelection(scanRunID: runID, clusterIDs: clusterIDs, memberIDs: memberIDs))
        let data = try encoder.encode(report)
        print(String(decoding: data, as: UTF8.self))
    }

    private func runIgnore(_ args: [String]) throws {
        guard let subcommand = args.first else {
            throw CLIError("ignore requires a subcommand: add, remove, list.")
        }

        switch subcommand {
        case "add":
            let parser = try ArgumentParser(arguments: Array(args.dropFirst()))
            let path = normalize(try parser.requiredValue(for: "--path"))
            let scopeRaw = parser.value(for: "--scope")
            let scope = IgnoreScope(rawValue: scopeRaw ?? inferredScope(for: path).rawValue) ?? inferredScope(for: path)
            try store.addIgnoreRule(IgnoreRule(scope: scope, path: path))
            print("added \(scope.rawValue) \(path)")
        case "remove":
            let parser = try ArgumentParser(arguments: Array(args.dropFirst()))
            let path = normalize(try parser.requiredValue(for: "--path"))
            try store.removeIgnoreRule(path: path)
            print("removed \(path)")
        case "list":
            let rules = try store.listIgnoreRules()
            for rule in rules {
                print("- \(rule.scope.rawValue) \(rule.path)")
            }
        default:
            throw CLIError("Unknown ignore subcommand '\(subcommand)'.")
        }
    }

    private func runProgress(_ args: [String]) async throws {
        let parser = try ArgumentParser(arguments: args)
        let runID = try parser.requiredValue(for: "--run-id")
        let progress = try await engine.getProgress(scanRunId: runID)
        let data = try encoder.encode(progress)
        print(String(decoding: data, as: UTF8.self))
    }

    private func printUsage() {
        print(
            """
            duplicate-me

            Commands:
              scan --location PATH [--location PATH ...] [--similar-images] [--similar-videos] [--similar-audio] [--include-hidden] [--no-duplicates]
              rescan [--run-id ID]
              list-clusters --run-id ID [--kind duplicates|similar|all]
              export-json --run-id ID --output FILE
              export-html --run-id ID --output FILE
              serve [--run-id ID] [--port 48222] [--no-open]
              progress --run-id ID
              trash --run-id ID --member FILE_ID [--member FILE_ID ...] [--cluster CLUSTER_ID ...]
              ignore add --path PATH [--scope folder|file]
              ignore remove --path PATH
              ignore list
            """
        )
    }

    private static func defaultDatabaseURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".duplicate-me", isDirectory: true)
            .appendingPathComponent("store.sqlite")
    }

    private func normalize(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private func inferredScope(for path: String) -> IgnoreScope {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .folder
        }
        return .file
    }
}

private struct ExportEnvelope: Encodable {
    let version: Int
    let run: ScanRun
}

private struct ArgumentParser {
    private let valuesByFlag: [String: [String]]
    private let flags: Set<String>

    init(arguments: [String]) throws {
        var valuesByFlag: [String: [String]] = [:]
        var flags: Set<String> = []
        var index = 0

        while index < arguments.count {
            let token = arguments[index]
            guard token.hasPrefix("--") else {
                throw CLIError("Unexpected argument '\(token)'.")
            }
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                valuesByFlag[token, default: []].append(arguments[index + 1])
                index += 2
            } else {
                flags.insert(token)
                index += 1
            }
        }

        self.valuesByFlag = valuesByFlag
        self.flags = flags
    }

    func hasFlag(_ flag: String) -> Bool {
        flags.contains(flag)
    }

    func value(for flag: String) -> String? {
        valuesByFlag[flag]?.last
    }

    func values(for flag: String) -> [String] {
        valuesByFlag[flag] ?? []
    }

    func requiredValue(for flag: String) throws -> String {
        guard let value = value(for: flag) else {
            throw CLIError("Missing value for \(flag).")
        }
        return value
    }

    func optionalUInt16Value(for flag: String) throws -> UInt16? {
        guard let value = value(for: flag) else {
            return nil
        }
        guard let parsed = UInt16(value) else {
            throw CLIError("Value for \(flag) must be a valid TCP port.")
        }
        return parsed
    }
}

private struct CLIError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
