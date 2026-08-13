import Foundation

public enum AIUsageAppGroup {
    public static var identifier: String {
        if let override = ProcessInfo.processInfo.environment["AI_USAGE_APP_GROUP"],
           !override.isEmpty {
            return override
        }
        if let configured = Bundle.main.object(forInfoDictionaryKey: "AIUsageAppGroup") as? String,
           !configured.isEmpty {
            return configured
        }
        return "group.com.example.aiusage"
    }
}

public enum AIUsageWidgetKind {
    public static let summary = "AIUsageWidget"
}

public struct UsageSnapshotCache: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }

        let base = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AIUsageAppGroup.identifier
        ) ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.fileURL = base
            .appendingPathComponent("AIUsageMac", isDirectory: true)
            .appendingPathComponent("usage-cache.json")
    }

    public func load() -> [UsageProviderID: ProviderUsageSnapshot] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let snapshots = try? JSONDecoder().decode([ProviderUsageSnapshot].self, from: data)
        else { return [:] }

        return Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
    }

    public func save(_ snapshots: [ProviderUsageSnapshot]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Keep the last useful value even when a provider temporarily falls back
        // to cached data. Otherwise a successful refresh from another provider
        // can overwrite the cache and make this provider disappear on relaunch.
        let data = try JSONEncoder().encode(snapshots.filter { $0.highestPercent != nil })
        try data.write(to: fileURL, options: .atomic)
    }
}
