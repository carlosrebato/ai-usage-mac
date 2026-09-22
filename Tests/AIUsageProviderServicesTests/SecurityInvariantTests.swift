import Foundation
import Testing

struct SecurityInvariantTests {
    @Test func sourceCannotReintroduceForbiddenScopesOrCredentialFiles() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let roots = ["Sources", "App", "iOSApp"].map { packageRoot.appendingPathComponent($0) }
        let forbidden = [
            "user:" + "inference",
            "org:" + "create_api_key",
            ".codex/" + "auth.json",
            ".claude/" + ".credentials.json",
            "ns" + "panel-rate-limits.json"
        ]
        let manager = FileManager.default
        for root in roots {
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                for value in forbidden {
                    #expect(!source.contains(value), "Forbidden credential capability in \(url.path)")
                }
            }
        }
    }
}
