import AIUsageCore
import AIUsageMacServices
import AppKit
import CryptoKit
import Foundation
import Network
import Security

@MainActor
enum ClaudeBrowserLogin {
    enum LoginError: LocalizedError {
        case timedOut
        case cancelled
        case stateMismatch
        case noRandomness
        case browserFailed
        case denied(String)

        var errorDescription: String? {
            switch self {
            case .timedOut:
                AppLanguage.current.text("Claude sign-in timed out.", "El acceso a Claude agotó el tiempo de espera.")
            case .cancelled:
                AppLanguage.current.text("Claude sign-in was cancelled.", "Se canceló el acceso a Claude.")
            case .stateMismatch:
                AppLanguage.current.text("Claude sign-in could not be verified.", "No se pudo verificar el acceso a Claude.")
            case .noRandomness:
                AppLanguage.current.text("Secure sign-in could not be started.", "No se pudo iniciar el acceso seguro.")
            case .browserFailed:
                AppLanguage.current.text("The Claude sign-in page could not be opened.", "No se pudo abrir la página de acceso de Claude.")
            case .denied(let reason):
                AppLanguage.current.text("Claude declined sign-in: \(reason)", "Claude rechazó el acceso: \(reason)")
            }
        }
    }

    static func signIn() async throws {
        let verifier = try randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let state = try randomURLSafe(32)
        let server = ClaudeOAuthLoopbackServer()
        let port = try await server.start()
        let redirectURI = "http://localhost:\(port)/callback"

        var components = URLComponents(string: ClaudeAccountOAuth.authorizeURL)!
        components.queryItems = [
            .init(name: "client_id", value: ClaudeAccountOAuth.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: ClaudeAccountOAuth.scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state)
        ]
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            server.cancel()
            throw LoginError.browserFailed
        }

        let outcome = await withTaskCancellationHandler {
            await server.waitForCallback()
        } onCancel: {
            server.cancel()
        }
        switch outcome {
        case .success(let code, let returnedState):
            guard returnedState == state else { throw LoginError.stateMismatch }
            try await ClaudeAccountOAuth.completeSignIn(
                code: code,
                verifier: verifier,
                redirectURI: redirectURI,
                state: state
            )
        case .denied(let reason): throw LoginError.denied(reason)
        case .cancelled: throw LoginError.cancelled
        case .timedOut: throw LoginError.timedOut
        }
    }

    private static func randomURLSafe(_ count: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw LoginError.noRandomness
        }
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private enum ClaudeOAuthLoopbackOutcome: Sendable {
    case success(code: String, state: String)
    case denied(String)
    case cancelled
    case timedOut
}

private final class ClaudeOAuthLoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.carlosrebato.aiusage.oauth-loopback")
    private var listener: NWListener?
    private var callback: CheckedContinuation<ClaudeOAuthLoopbackOutcome, Never>?
    private var finished = false
    private var startResumed = false

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            if !self.startResumed, let port = listener.port?.rawValue {
                                self.startResumed = true
                                continuation.resume(returning: port)
                            }
                        case .failed(let error):
                            listener.cancel()
                            self.listener = nil
                            if !self.startResumed {
                                self.startResumed = true
                                continuation.resume(throwing: error)
                            }
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.handle(connection)
                    }
                    listener.start(queue: self.queue)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func waitForCallback() async -> ClaudeOAuthLoopbackOutcome {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.finished {
                    continuation.resume(returning: .cancelled)
                    return
                }
                self.callback = continuation
                self.queue.asyncAfter(deadline: .now() + 300) { self.finish(.timedOut) }
            }
        }
    }

    func cancel() {
        queue.async { self.finish(.cancelled) }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard let outcome = Self.parse(request) else {
                self.respond(connection, status: "404 Not Found", body: "Not found")
                return
            }
            self.respond(connection, status: "200 OK", body: Self.page(for: outcome))
            self.finish(outcome)
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let html = """
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:-apple-system,system-ui;text-align:center;padding:4em;color:#1d1d1f">
        \(body)</body></html>
        """
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func page(for outcome: ClaudeOAuthLoopbackOutcome) -> String {
        if case .denied(let reason) = outcome {
            return "<h2>Sign-in cancelled</h2><p>\(reason)</p>"
        }
        return "<h2>✓ Connected</h2><p>You can close this tab and return to AI Usage.</p>"
    }

    private func finish(_ outcome: ClaudeOAuthLoopbackOutcome) {
        guard !finished else { return }
        finished = true
        callback?.resume(returning: outcome)
        callback = nil
        listener?.cancel()
        listener = nil
    }

    private static func parse(_ request: String) -> ClaudeOAuthLoopbackOutcome? {
        guard let line = request.split(separator: "\r\n").first,
              let path = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://localhost\(path)")
        else { return nil }
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value
        }
        if let code = value("code") {
            return .success(code: code, state: value("state") ?? "")
        }
        if let error = value("error") {
            return .denied(value("error_description") ?? error)
        }
        return nil
    }
}
