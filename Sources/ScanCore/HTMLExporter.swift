import Foundation

public struct HTMLReportExporter: Sendable {
    public init() {}

    public func export(run: ScanRun, to url: URL) throws {
        guard let results = run.results else {
            throw NSError(domain: "ScanCore", code: 500, userInfo: [NSLocalizedDescriptionKey: "Run has no results to export."])
        }

        let fileMap = Dictionary(uniqueKeysWithValues: results.files.map { ($0.id, $0) })
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file

        func rows(for members: [String]) -> String {
            members.compactMap { fileMap[$0] }.map { record in
                """
                <tr>
                  <td><code>\(escape(record.path))</code></td>
                  <td>\(formatter.string(fromByteCount: record.size))</td>
                  <td>\(record.mediaKind.rawValue)</td>
                </tr>
                """
            }.joined(separator: "\n")
        }

        let duplicateSections = results.duplicateClusters.map { cluster in
            """
            <section class="cluster">
              <h3>Duplicate cluster \(escape(cluster.id))</h3>
              <p>Reclaimable: \(formatter.string(fromByteCount: cluster.reclaimableBytes))</p>
              <p>Keep: <code>\(escape(fileMap[cluster.recommendedKeepID]?.path ?? cluster.recommendedKeepID))</code></p>
              <table>
                <thead><tr><th>File</th><th>Size</th><th>Kind</th></tr></thead>
                <tbody>\(rows(for: cluster.memberIDs))</tbody>
              </table>
            </section>
            """
        }.joined(separator: "\n")

        let similarSections = results.similarClusters.map { cluster in
            """
            <section class="cluster">
              <h3>\(cluster.mediaKind.rawValue.capitalized) similars \(escape(cluster.id))</h3>
              <p>Score: \(String(format: "%.3f", cluster.similarityScore))</p>
              <table>
                <thead><tr><th>File</th><th>Size</th><th>Kind</th></tr></thead>
                <tbody>\(rows(for: cluster.memberIDs))</tbody>
              </table>
            </section>
            """
        }.joined(separator: "\n")

        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <title>DuplicateMe report \(escape(run.id))</title>
          <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            body { margin: 40px auto; max-width: 1080px; padding: 0 20px 80px; line-height: 1.45; }
            h1, h2, h3 { margin-bottom: 0.35em; }
            .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin: 24px 0; }
            .card, .cluster { border: 1px solid rgba(128,128,128,0.35); border-radius: 14px; padding: 16px; margin-bottom: 16px; }
            table { width: 100%; border-collapse: collapse; }
            th, td { text-align: left; border-top: 1px solid rgba(128,128,128,0.2); padding: 8px 0; vertical-align: top; }
            code { word-break: break-all; }
          </style>
        </head>
        <body>
          <h1>DuplicateMe report</h1>
          <p>Run: <code>\(escape(run.id))</code></p>
          <div class="summary">
            <div class="card"><strong>Total files</strong><br>\(results.stats.totalFiles)</div>
            <div class="card"><strong>Total size</strong><br>\(formatter.string(fromByteCount: results.stats.totalBytes))</div>
            <div class="card"><strong>Duplicate clusters</strong><br>\(results.stats.duplicateClusters)</div>
            <div class="card"><strong>Similar clusters</strong><br>\(results.stats.similarClusters)</div>
            <div class="card"><strong>Reclaimable</strong><br>\(formatter.string(fromByteCount: results.stats.reclaimableBytes))</div>
            <div class="card"><strong>Cache hits</strong><br>\(results.stats.cacheHits)</div>
          </div>
          <h2>Duplicate clusters</h2>
          \(duplicateSections.isEmpty ? "<p>No duplicate clusters found.</p>" : duplicateSections)
          <h2>Similar clusters</h2>
          \(similarSections.isEmpty ? "<p>No similar clusters found.</p>" : similarSections)
        </body>
        </html>
        """

        try html.write(to: url, atomically: true, encoding: .utf8)
    }
}

private func escape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
