import Foundation

public protocol ScanStoreProtocol: AnyObject, Sendable {
    func saveRun(_ run: ScanRun) throws
    func updateProgress(_ progress: ScanProgress, for runID: String) throws
    func loadRun(id: String) throws -> ScanRun?
    func latestRun() throws -> ScanRun?

    func cacheEntry(for key: String) throws -> CacheEntry?
    func upsertCacheEntry(_ entry: CacheEntry) throws

    func addIgnoreRule(_ rule: IgnoreRule) throws
    func removeIgnoreRule(path: String) throws
    func listIgnoreRules() throws -> [IgnoreRule]

    func addReviewDismissRule(_ rule: ReviewDismissRule) throws
    func listReviewDismissRules() throws -> [ReviewDismissRule]
}
