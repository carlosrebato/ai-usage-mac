import AIUsageCore
import Foundation

struct CodexAppServerConnector: UsageConnector {
    let providerID = UsageProviderID.codex
    let timeout: Duration
    private let executableURL: URL?

    init(executableURL: URL? = CodexExecutableLocator.locate(), timeout: Duration = .seconds(8)) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    func fetchSnapshot(allowInteraction: Bool) async throws -> ProviderUsageSnapshot {
        guard let executableURL else { throw UsageConnectorError.executableNotFound }

        let response = try await CodexAppServerExchange(
            executableURL: executableURL,
            timeout: timeout
        ).readRateLimits()

        return try CodexRateLimitsNormalizer.snapshot(from: response, observedAt: .now)
    }
}

enum CodexExecutableLocator {
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let configured = environment["AI_USAGE_CODEX_PATH"], isExecutable(configured) {
            return URL(fileURLWithPath: configured)
        }

        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/codex" }

        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ] + pathCandidates

        return candidates.first(where: isExecutable).map(URL.init(fileURLWithPath:))
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

private final class CodexAppServerExchange: @unchecked Sendable {
    private let executableURL: URL
    private let timeout: Duration
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var process: Process?
    private var buffer = Data()
    private var finished = false

    init(executableURL: URL, timeout: Duration) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    func readRateLimits() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let registered = lock.withLock {
                    guard !finished else { return false }
                    self.continuation = continuation
                    return true
                }
                guard registered else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                start()

                Task { [weak self, timeout] in
                    do {
                        try await Task.sleep(for: timeout)
                        self?.complete(.failure(UsageConnectorError.timedOut))
                    } catch {
                        // The exchange completed or its parent task was cancelled.
                    }
                }
            }
        } onCancel: {
            complete(.failure(CancellationError()))
        }
    }

    private func start() {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.environment = ProcessInfo.processInfo.environment

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data, input: input.fileHandleForWriting)
        }

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            if process.terminationStatus == 0 {
                let remaining = output.fileHandleForReading.readDataToEndOfFile()
                if !remaining.isEmpty {
                    self.ingest(remaining, input: input.fileHandleForWriting)
                }
                if !self.isFinished {
                    self.complete(.failure(UsageConnectorError.malformedResponse))
                }
                return
            }
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            let reason = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.complete(.failure(UsageConnectorError.launchFailed(reason ?? "código \(process.terminationStatus)")))
        }

        do {
            lock.withLock { self.process = process }
            try process.run()

            try write(
                [
                    "id": "1",
                    "method": "initialize",
                    "params": [
                        "clientInfo": ["name": "ai-usage-mac", "version": "0.1.0"],
                        "capabilities": ["experimentalApi": true]
                    ]
                ],
                to: input.fileHandleForWriting
            )
        } catch {
            complete(.failure(UsageConnectorError.launchFailed(error.localizedDescription)))
        }
    }

    private func write(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func ingest(_ data: Data, input: FileHandle) {
        let lines: [Data] = lock.withLock {
            buffer.append(data)
            var completeLines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                completeLines.append(buffer[..<newline])
                buffer.removeSubrange(...newline)
            }
            return completeLines
        }

        for line in lines where !line.isEmpty {
            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let id = object["id"].map({ String(describing: $0) })
            else { continue }

            if id == "1" {
                if let error = object["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? "Codex no pudo inicializarse"
                    complete(.failure(UsageConnectorError.serverError(message)))
                    return
                }
                do {
                    try write(
                        ["id": "2", "method": "account/rateLimits/read"],
                        to: input
                    )
                } catch {
                    complete(.failure(UsageConnectorError.launchFailed(error.localizedDescription)))
                    return
                }
                continue
            }

            guard id == "2" else { continue }
            complete(.success(line))
            return
        }
    }

    private func complete(_ result: Result<Data, Error>) {
        let values: (CheckedContinuation<Data, Error>?, Process?) = lock.withLock {
            guard !finished else { return (nil, nil) }
            finished = true
            let values = (continuation, process)
            continuation = nil
            process = nil
            return values
        }

        guard let continuation = values.0 else { return }
        if let output = values.1?.standardOutput as? Pipe {
            output.fileHandleForReading.readabilityHandler = nil
        }
        if values.1?.isRunning == true { values.1?.terminate() }
        continuation.resume(with: result)
    }

    private var isFinished: Bool {
        lock.withLock { finished }
    }
}

enum CodexRateLimitsNormalizer {
    static func snapshot(from data: Data, observedAt: Date) throws -> ProviderUsageSnapshot {
        let response: RPCResponse
        do {
            response = try JSONDecoder().decode(RPCResponse.self, from: data)
        } catch {
            throw UsageConnectorError.malformedResponse
        }

        if let error = response.error {
            throw UsageConnectorError.serverError(error.message)
        }

        guard let limits = response.result?.rateLimits else {
            throw UsageConnectorError.missingUsageWindows
        }

        let windows = [limits.primary, limits.secondary].compactMap { $0 }
        let weekly = windows.first { ($0.windowDurationMins ?? 0) >= 7 * 24 * 60 }
        let session: RateLimitWindow?

        if weekly != nil {
            session = windows.first { $0 != weekly }
        } else {
            session = limits.primary
        }

        let fallbackWeekly = weekly ?? (limits.primary == session ? limits.secondary : limits.primary)
        guard session?.usedPercent != nil || fallbackWeekly?.usedPercent != nil else {
            throw UsageConnectorError.missingUsageWindows
        }

        let plan = limits.planType?.capitalized
        return ProviderUsageSnapshot(
            id: .codex,
            session: usageWindow(session),
            weekly: usageWindow(fallbackWeekly),
            observedAt: observedAt,
            source: .live,
            message: plan.map { "Plan \($0)" } ?? AppLanguage.current.text(
                "Connected locally",
                "Conectado localmente"
            )
        )
    }

    private static func usageWindow(_ window: RateLimitWindow?) -> UsageWindow {
        UsageWindow(
            usedPercent: window?.usedPercent.map { min(max($0, 0), 100) },
            resetsAt: window?.resetsAt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

private struct RPCResponse: Decodable {
    let result: RPCResult?
    let error: RPCError?
}

private struct RPCResult: Decodable {
    let rateLimits: RateLimits?
}

private struct RPCError: Decodable {
    let message: String
}

private struct RateLimits: Decodable {
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let planType: String?
}

private struct RateLimitWindow: Decodable, Equatable {
    let usedPercent: Double?
    let windowDurationMins: Double?
    let resetsAt: Double?
}
