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

        #expect(throws: ClaudeDesktopDataAccessError.self) {
            try access.saveAccess(to: folder)
        }
        #expect(!access.hasStoredAccess)
    }
}
