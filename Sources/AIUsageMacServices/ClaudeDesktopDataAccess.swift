import AIUsageCore
import Foundation

public enum ClaudeDesktopDataAccessError: LocalizedError {
    case unexpectedFolder

    public var errorDescription: String? {
        switch self {
        case .unexpectedFolder:
            AppLanguage.current.text(
                "Select the “Claude” folder inside Library/Application Support.",
                "Selecciona la carpeta “Claude” de Library/Application Support."
            )
        }
    }
}

public final class ClaudeDesktopDataAccess: @unchecked Sendable {
    public static let shared = ClaudeDesktopDataAccess()

    private static let bookmarkKey = "claudeDesktopDataBookmark"
    private let defaults: UserDefaults
    private let bookmarkCoder: any ClaudeDesktopBookmarkCoding
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bookmarkCoder = SystemClaudeDesktopBookmarkCoder()
    }

    init(
        defaults: UserDefaults,
        bookmarkCoder: any ClaudeDesktopBookmarkCoding
    ) {
        self.defaults = defaults
        self.bookmarkCoder = bookmarkCoder
    }

    public var hasStoredAccess: Bool {
        lock.withLock { defaults.data(forKey: Self.bookmarkKey) != nil }
    }

    public var hasUsableAccess: Bool {
        resolvedURL() != nil
    }

    public func saveAccess(to folder: URL) throws {
        let normalized = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard normalized.lastPathComponent == "Claude" else {
            throw ClaudeDesktopDataAccessError.unexpectedFolder
        }

        let bookmark = try bookmarkCoder.createBookmark(for: normalized)
        lock.withLock { defaults.set(bookmark, forKey: Self.bookmarkKey) }
    }

    public func resolvedURL() -> URL? {
        guard let bookmark = lock.withLock({ defaults.data(forKey: Self.bookmarkKey) }) else {
            return nil
        }

        guard let resolution = try? bookmarkCoder.resolveBookmark(bookmark) else {
            return nil
        }

        if resolution.isStale,
           let refreshed = try? bookmarkCoder.createBookmark(for: resolution.url) {
            lock.withLock { defaults.set(refreshed, forKey: Self.bookmarkKey) }
        }
        return resolution.url
    }

    public func removeAccess() {
        lock.withLock { defaults.removeObject(forKey: Self.bookmarkKey) }
    }
}

protocol ClaudeDesktopBookmarkCoding: Sendable {
    func createBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool)
}

private struct SystemClaudeDesktopBookmarkCoder: ClaudeDesktopBookmarkCoding {
    func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }
}
