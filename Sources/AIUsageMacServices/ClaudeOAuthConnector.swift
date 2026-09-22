import AIUsageCore
import Foundation

/// Reads only the numeric statusline artifact produced by Claude Code. It is a
/// lower-priority Mac fallback and never reads Claude's credential store.
struct ClaudeStatuslineReader: Sendable {
    let fileURL: URL?
    let maximumAge: TimeInterval
    private let dataAccess: ProviderDataAccess?

    init(fileURL: URL? = nil, maximumAge: TimeInterval = 10 * 60) {
        self.fileURL = fileURL
        self.maximumAge = maximumAge
        dataAccess = fileURL == nil ? .shared : nil
    }

    func readFresh(now: Date) -> ProviderUsageSnapshot? {
        if let fileURL { return read(fileURL, now: now) }
        return try? dataAccess?.withAccess(to: .claudeCode) { root in
            read(root.appendingPathComponent("ai-usage-rate-limits.json"), now: now)
        }
    }

    private func read(_ fileURL: URL, now: Date) -> ProviderUsageSnapshot? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let modifiedAt = attributes[.modificationDate] as? Date,
            now.timeIntervalSince(modifiedAt) <= maximumAge,
            let data = try? Data(contentsOf: fileURL),
            let payload = try? JSONDecoder().decode(StatuslinePayload.self, from: data),
            payload.sessionPercent != nil || payload.weekPercent != nil
        else { return nil }

        // A statusline artifact is a current local data source, not the app's
        // persisted last-known-value cache. The file-age guard above is what
        // makes it safe to surface as live data.
        let observedAt = min(parse(payload.lastUpdated) ?? modifiedAt, now)
        return ProviderUsageSnapshot(
            id: .claude,
            session: UsageWindow(
                usedPercent: payload.sessionPercent,
                resetsAt: parse(payload.resetAt)
            ),
            weekly: UsageWindow(
                usedPercent: payload.weekPercent,
                resetsAt: parse(payload.weekResetAt)
            ),
            observedAt: observedAt,
            source: .live,
            message: "Claude Code statusline"
        )
    }

    private func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private struct StatuslinePayload: Decodable {
    let sessionPercent: Double?
    let weekPercent: Double?
    let resetAt: String?
    let weekResetAt: String?
    let lastUpdated: String?
}
