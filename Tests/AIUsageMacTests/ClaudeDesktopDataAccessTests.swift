import Foundation
import Testing
@testable import AIUsageMacServices

private struct PathBookmarkCoder: ClaudeDesktopBookmarkCoding {
    func createBookmark(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        let path = try #require(String(data: data, encoding: .utf8))
        return (URL(fileURLWithPath: path, isDirectory: true), false)
    }
}

struct ClaudeDesktopDataAccessTests {
    @Test func storesAndResolvesTheSelectedClaudeFolder() throws {
        let suite = "ClaudeDesktopDataAccessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let access = ClaudeDesktopDataAccess(
            defaults: defaults,
            bookmarkCoder: PathBookmarkCoder()
        )
        try access.saveAccess(to: folder)

        #expect(access.hasStoredAccess)
        #expect(access.resolvedURL()?.standardizedFileURL == folder.standardizedFileURL)
    }

    @Test func savedAccessRemainsUsableInTheNextAppSession() throws {
        let suite = "ClaudeDesktopDataAccessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let firstSession = ClaudeDesktopDataAccess(defaults: defaults, bookmarkCoder: PathBookmarkCoder())
        try firstSession.saveAccess(to: folder)

        let nextSession = ClaudeDesktopDataAccess(defaults: defaults, bookmarkCoder: PathBookmarkCoder())
        #expect(nextSession.hasUsableAccess)
        #expect(nextSession.resolvedURL()?.standardizedFileURL == folder.standardizedFileURL)
    }

    @Test func desktopSessionAndClaudeCodeLogsUseIndependentBookmarks() throws {
        let suite = "ClaudeDesktopDataAccessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let desktopFolder = root.appendingPathComponent("Claude", isDirectory: true)
        let codeFolder = root.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: desktopFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codeFolder, withIntermediateDirectories: true)

        let access = ClaudeDesktopDataAccess(
            defaults: defaults,
            bookmarkCoder: PathBookmarkCoder()
        )
        try access.saveAccess(to: desktopFolder, for: .claude)
        try access.saveAccess(to: codeFolder, for: .claudeCode)

        #expect(access.resolvedURL(for: .claude)?.standardizedFileURL == desktopFolder.standardizedFileURL)
        #expect(access.resolvedURL(for: .claudeCode)?.standardizedFileURL == codeFolder.standardizedFileURL)
    }

    @Test func rejectsAParentFolderThatWouldGrantBroaderAccess() throws {
        let suite = "ClaudeDesktopDataAccessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Application Support", isDirectory: true)

        let access = ClaudeDesktopDataAccess(
            defaults: defaults,
            bookmarkCoder: PathBookmarkCoder()
        )

        #expect(throws: ProviderDataAccessError.self) {
            try access.saveAccess(to: folder)
        }
        #expect(!access.hasStoredAccess)
    }
}
