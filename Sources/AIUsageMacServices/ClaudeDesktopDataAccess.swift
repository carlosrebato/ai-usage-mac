import AIUsageCore
import Foundation

public enum ProviderDataDirectory: String, CaseIterable, Sendable {
    case claude
    case claudeCode
    case codex

    public var folderName: String {
        switch self {
        case .claude: "Claude"
        case .claudeCode: ".claude"
        case .codex: ".codex"
        }
    }

    fileprivate var providerName: String {
        switch self {
        case .claude, .claudeCode: "Claude"
        case .codex: "Codex"
        }
    }

    fileprivate var acceptedFolderNames: Set<String> {
        switch self {
        case .claude: ["Claude", ".claude"]
        case .claudeCode: [".claude"]
        case .codex: [".codex"]
        }
    }

    fileprivate var bookmarkKey: String {
        switch self {
        case .claude: "providerDataBookmark.claude.v2"
        case .claudeCode: "providerDataBookmark.claudeCode.v1"
        case .codex: "providerDataBookmark.codex.v1"
        }
    }
}

public enum ProviderDataAccessError: LocalizedError {
    case unexpectedFolder(expected: String)
    case accessNotGranted(provider: ProviderDataDirectory)

    public var errorDescription: String? {
        switch self {
        case .unexpectedFolder(let expected):
            AppLanguage.current.text(
                "Select the \(expected) folder in your home directory.",
                "Selecciona la carpeta \(expected) de tu carpeta de usuario."
            )
        case .accessNotGranted(let provider):
            AppLanguage.current.text(
                "Connect \(provider.providerName) to grant read-only access to \(provider.folderName).",
                "Conecta \(provider.providerName) para conceder acceso de solo lectura a \(provider.folderName)."
            )
        }
    }
}

/// Owns the persistent security-scoped bookmarks selected in onboarding.
///
/// Each provider gets its own least-privilege folder grant. Callers must perform
/// every file read inside `withAccess(to:_:)` so the security scope is active in
/// sandboxed builds and is always released afterwards.
public final class ProviderDataAccess: @unchecked Sendable {
    public static let shared = ProviderDataAccess()

    private let defaults: UserDefaults
    private let bookmarkCoder: any ClaudeDesktopBookmarkCoding
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bookmarkCoder = SystemProviderBookmarkCoder()
    }

    init(
        defaults: UserDefaults,
        bookmarkCoder: any ClaudeDesktopBookmarkCoding
    ) {
        self.defaults = defaults
        self.bookmarkCoder = bookmarkCoder
    }

    public func hasStoredAccess(for provider: ProviderDataDirectory) -> Bool {
        lock.withLock { defaults.data(forKey: provider.bookmarkKey) != nil }
    }

    public func hasUsableAccess(for provider: ProviderDataDirectory) -> Bool {
        resolvedURL(for: provider) != nil
    }

    public func saveAccess(to folder: URL, for provider: ProviderDataDirectory) throws {
        let normalized = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard provider.acceptedFolderNames.contains(normalized.lastPathComponent) else {
            throw ProviderDataAccessError.unexpectedFolder(expected: provider.folderName)
        }

        let bookmark = try bookmarkCoder.createBookmark(for: normalized)
        lock.withLock { defaults.set(bookmark, forKey: provider.bookmarkKey) }
    }

    public func resolvedURL(for provider: ProviderDataDirectory) -> URL? {
        guard let bookmark = lock.withLock({ defaults.data(forKey: provider.bookmarkKey) }) else {
            return nil
        }

        guard let resolution = try? bookmarkCoder.resolveBookmark(bookmark) else {
            return nil
        }

        guard provider.acceptedFolderNames.contains(
            resolution.url.standardizedFileURL.lastPathComponent
        ) else {
            return nil
        }

        if resolution.isStale,
           let refreshed = try? bookmarkCoder.createBookmark(for: resolution.url) {
            lock.withLock { defaults.set(refreshed, forKey: provider.bookmarkKey) }
        }
        return resolution.url
    }

    public func withAccess<T>(
        to provider: ProviderDataDirectory,
        _ operation: (URL) throws -> T
    ) throws -> T {
        guard let folder = resolvedURL(for: provider) else {
            throw ProviderDataAccessError.accessNotGranted(provider: provider)
        }

        let didStart = folder.startAccessingSecurityScopedResource()
        defer {
            if didStart { folder.stopAccessingSecurityScopedResource() }
        }
        return try operation(folder)
    }

    public func removeAccess(for provider: ProviderDataDirectory) {
        lock.withLock { defaults.removeObject(forKey: provider.bookmarkKey) }
    }
}

// Temporary source compatibility while the old Claude Desktop-specific reader
// is phased out. New code should use ProviderDataAccess with an explicit provider.
public typealias ClaudeDesktopDataAccess = ProviderDataAccess

extension ProviderDataAccess {
    public var hasStoredAccess: Bool { hasStoredAccess(for: .claude) }
    public var hasUsableAccess: Bool { hasUsableAccess(for: .claude) }
    public var isDesktopSessionAuthorized: Bool { hasUsableAccess(for: .claude) }
    public func authorizeDesktopSession() {}
    public func saveAccess(to folder: URL) throws { try saveAccess(to: folder, for: .claude) }
    public func resolvedURL() -> URL? { resolvedURL(for: .claude) }
    public func removeAccess() { removeAccess(for: .claude) }
}

protocol ClaudeDesktopBookmarkCoding: Sendable {
    func createBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool)
}

private struct SystemProviderBookmarkCoder: ClaudeDesktopBookmarkCoding {
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
