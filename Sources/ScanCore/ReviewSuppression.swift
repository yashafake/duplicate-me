import CryptoKit
import Foundation
import MediaFingerprint

public enum ReviewDismissKind: String, Codable, CaseIterable, Sendable, Hashable {
    case similarCluster
    case similarFile
}

public struct ReviewDismissRule: Codable, Sendable, Hashable {
    public let id: String
    public let kind: ReviewDismissKind
    public let signature: String
    public let mediaKind: MediaKind?
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: ReviewDismissKind,
        signature: String,
        mediaKind: MediaKind? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.signature = signature
        self.mediaKind = mediaKind
        self.createdAt = createdAt
    }
}

public enum ReviewDismissSignature {
    public static func similarCluster(mediaKind: MediaKind, memberPaths: [String]) -> String {
        let normalizedPaths = memberPaths
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path.lowercased() }
            .sorted()
        let payload = ([mediaKind.rawValue] + normalizedPaths).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public static func similarFile(path: String) -> String {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        let digest = SHA256.hash(data: Data(normalizedPath.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
