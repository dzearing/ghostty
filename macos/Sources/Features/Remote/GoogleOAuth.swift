import CryptoKit
import Foundation
import Network

/// The pure, headlessly-testable pieces of the Google OAuth 2.0
/// authorization-code + PKCE flow used by `RelayAccount` (WP-B2), now in a
/// relay-brokered (BFF) posture:
///
/// - PKCE verifier/challenge generation (RFC 7636, S256)
/// - the authorization URL builder (the browser leg still goes to Google)
/// - a loopback redirect receiver (`http://127.0.0.1:<random port>` — the
///   redirect style Google supports for **Desktop app** OAuth clients, no
///   registered redirect URI needed)
/// - the **relay session client** (`RelaySessionClient`): the app hands the
///   authorization `code` (+ PKCE verifier) to the RELAY's `/oauth/exchange`,
///   which holds the confidential client secret, performs the Google token
///   exchange server-side, and returns a short-lived **relay session token**.
///   Google id/refresh tokens never touch the client.
///
/// Endpoint URLs are injectable via `Endpoints` **at construction time only**
/// (the relay's `IssuerURL` pattern: tests build their own `Endpoints`
/// pointing at a local fake; production always uses `.relay(base:)`).
///
/// Everything here is UI-free (Foundation + CryptoKit + Network) so it can be
/// exercised by a standalone `swiftc` harness without the app.
enum GoogleOAuth {
    // MARK: - Endpoints

    /// The OAuth/relay endpoints in use. `authorization` is Google's (the
    /// browser leg); the token `exchange`/`renew`/`signout` are the RELAY's —
    /// the app never talks to Google's token endpoint (BFF). Injectable for
    /// tests only; production uses `.relay(base:)`.
    struct Endpoints: Sendable {
        var authorization: URL
        var exchange: URL
        var renew: URL
        var signout: URL

        static let googleAuthorization =
            URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!

        /// Production endpoints for a given relay base (e.g. the Azure relay).
        static func relay(base: URL) -> Endpoints {
            Endpoints(
                authorization: googleAuthorization,
                exchange: base.appendingPathComponent("oauth/exchange"),
                renew: base.appendingPathComponent("oauth/renew"),
                signout: base.appendingPathComponent("oauth/signout"))
        }
    }

    // MARK: - PKCE (RFC 7636)

    enum PKCE {
        /// A fresh, high-entropy `code_verifier`: 32 random bytes,
        /// base64url-encoded (43 chars — within the RFC's 43–128 bound, all
        /// characters from the unreserved set).
        static func generateVerifier() -> String {
            randomURLSafeToken(byteCount: 32)
        }

        /// The S256 `code_challenge` for `verifier`:
        /// `base64url(SHA256(ASCII(verifier)))`, unpadded.
        static func challenge(for verifier: String) -> String {
            base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        /// `byteCount` random bytes as an unpadded base64url string. Also used
        /// for the OAuth `state` value. `SystemRandomNumberGenerator` is
        /// cryptographically secure on Apple platforms.
        static func randomURLSafeToken(byteCount: Int) -> String {
            var rng = SystemRandomNumberGenerator()
            var bytes = Data(capacity: byteCount)
            for _ in 0..<byteCount {
                bytes.append(UInt8.random(in: .min ... .max, using: &rng))
            }
            return base64URLEncode(bytes)
        }

        /// Unpadded base64url (RFC 4648 §5).
        static func base64URLEncode(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        /// Inverse of `base64URLEncode` (accepts unpadded input).
        static func base64URLDecode(_ string: String) -> Data? {
            var s = string
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while s.count % 4 != 0 { s.append("=") }
            return Data(base64Encoded: s)
        }
    }

    // MARK: - Authorization URL

    /// The browser URL that starts the sign-in: Google's authorization
    /// endpoint with the code+PKCE parameters. `access_type=offline` +
    /// `prompt=consent` guarantee a refresh token on every (re-)sign-in — the
    /// relay captures and holds that refresh token (it never reaches the app).
    static func authorizationURL(
        endpoints: Endpoints,
        clientID: String,
        redirectURI: String,
        state: String,
        codeChallenge: String,
        scopes: [String] = ["openid", "email", "profile"]
    ) -> URL {
        var comps = URLComponents(url: endpoints.authorization, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return comps.url!
    }

    // MARK: - Relay session client

    /// The app's client for the relay's brokered-OAuth endpoints. It exchanges
    /// the PKCE authorization code for a relay session token, renews it, and
    /// signs out. Google tokens never touch the client — the relay holds them.
    struct RelaySessionClient {
        let endpoints: Endpoints
        var urlSession: URLSession = .shared

        /// The relay's session response: an opaque session token, its expiry
        /// (unix seconds), and display fields.
        struct SessionResponse: Decodable, Equatable {
            let sessionToken: String
            let expiry: Double
            let email: String
            let picture: String?

            enum CodingKeys: String, CodingKey {
                case sessionToken = "session_token"
                case expiry
                case email
                case picture
            }

            var expiresAt: Date { Date(timeIntervalSince1970: expiry) }
        }

        enum SessionError: LocalizedError {
            case http(Int, String)
            case badResponse

            var errorDescription: String? {
                switch self {
                case .http(let code, let detail):
                    return detail.isEmpty
                        ? "The relay returned HTTP \(code) during sign-in."
                        : "The relay returned HTTP \(code) during sign-in: \(detail)"
                case .badResponse:
                    return "The relay returned a sign-in response that couldn't be parsed."
                }
            }
        }

        /// POST /oauth/exchange — trade the PKCE code for a relay session token.
        func exchange(
            code: String,
            redirectURI: String,
            codeVerifier: String
        ) async throws -> SessionResponse {
            var req = URLRequest(url: endpoints.exchange)
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "code": code,
                "code_verifier": codeVerifier,
                "redirect_uri": redirectURI,
            ])
            return try await send(req)
        }

        /// POST /oauth/renew — rotate the session token using the relay-held
        /// Google refresh token. The current (possibly just-expired) session
        /// token is the bearer.
        func renew(sessionToken: String) async throws -> SessionResponse {
            var req = URLRequest(url: endpoints.renew)
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
            return try await send(req)
        }

        /// POST /oauth/signout — best-effort revoke (failures are ignored).
        func signOut(sessionToken: String) async {
            var req = URLRequest(url: endpoints.signout)
            req.httpMethod = "POST"
            req.timeoutInterval = 10
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
            _ = try? await urlSession.data(for: req)
        }

        private func send(_ req: URLRequest) async throws -> SessionResponse {
            let (data, resp) = try await urlSession.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw SessionError.badResponse }
            guard (200..<300).contains(http.statusCode) else {
                let detail = String(decoding: data, as: UTF8.self)
                throw SessionError.http(http.statusCode, String(detail.prefix(200)))
            }
            guard let out = try? JSONDecoder().decode(SessionResponse.self, from: data) else {
                throw SessionError.badResponse
            }
            return out
        }
    }

    // MARK: - Loopback redirect receiver

    /// A one-shot mini HTTP listener on `127.0.0.1:<random port>` that catches
    /// Google's redirect (`GET /?code=...&state=...`), shows a "you can close
    /// this tab" page, and hands the authorization code back. Google Desktop
    /// clients accept any loopback port without prior registration.
    ///
    /// All state is confined to `queue`. The receiver resolves exactly once
    /// (code, denial, state mismatch, timeout, or cancel); stray requests
    /// (e.g. `/favicon.ico`) get a 404 and don't consume the flow.
    final class LoopbackCodeReceiver: @unchecked Sendable {
        enum Failure: LocalizedError {
            case listener(Error?)
            case timedOut
            case denied(String)
            case stateMismatch
            case cancelled

            var errorDescription: String? {
                switch self {
                case .listener(let err):
                    return "Couldn't listen for the sign-in redirect"
                        + (err.map { ": \($0.localizedDescription)" } ?? ".")
                case .timedOut:
                    return "Timed out waiting for the browser sign-in to complete."
                case .denied(let reason):
                    return "Google sign-in was not completed (\(reason))."
                case .stateMismatch:
                    return "The sign-in redirect did not match this sign-in attempt (state mismatch)."
                case .cancelled:
                    return "Sign-in was cancelled."
                }
            }
        }

        private let expectedState: String
        private let listener: NWListener
        private let queue = DispatchQueue(label: "com.dzearing.ghoztty.oauth-loopback")

        // Queue-confined:
        private var portContinuation: CheckedContinuation<UInt16, Error>?
        private var codeContinuation: CheckedContinuation<String, Error>?
        private var pendingResult: Result<String, Failure>?
        private var finished = false

        init(expectedState: String) throws {
            self.expectedState = expectedState
            let params = NWParameters.tcp
            // Loopback only: never listen on a routable interface.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            self.listener = try NWListener(using: params)
        }

        /// Start listening; resolves with the kernel-assigned port.
        func start() async throws -> UInt16 {
            try await withCheckedThrowingContinuation { cont in
                queue.async {
                    self.portContinuation = cont
                    self.listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            if let cont = self.portContinuation {
                                self.portContinuation = nil
                                if let port = self.listener.port?.rawValue {
                                    cont.resume(returning: port)
                                } else {
                                    cont.resume(throwing: Failure.listener(nil))
                                }
                            }
                        case .failed(let err):
                            if let cont = self.portContinuation {
                                self.portContinuation = nil
                                cont.resume(throwing: Failure.listener(err))
                            } else {
                                self.finish(.failure(.listener(err)))
                            }
                        case .cancelled:
                            if let cont = self.portContinuation {
                                self.portContinuation = nil
                                cont.resume(throwing: Failure.cancelled)
                            }
                        default:
                            break
                        }
                    }
                    self.listener.newConnectionHandler = { [weak self] conn in
                        self?.accept(conn)
                    }
                    self.listener.start(queue: self.queue)
                }
            }
        }

        /// Await the authorization code (the browser redirect). One-shot.
        func waitForCode(timeout: TimeInterval = 300) async throws -> String {
            try await withCheckedThrowingContinuation { cont in
                queue.async {
                    // The redirect may have already landed (fast browser).
                    if let result = self.pendingResult {
                        self.pendingResult = nil
                        cont.resume(with: result)
                        return
                    }
                    self.codeContinuation = cont
                    self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.finish(.failure(.timedOut))
                    }
                }
            }
        }

        /// Abort the flow (sign-in dismissed, app-side failure, …).
        func cancel() {
            queue.async { self.finish(.failure(.cancelled)) }
        }

        // MARK: Internals (queue-confined)

        private func finish(_ result: Result<String, Failure>) {
            guard !finished else { return }
            finished = true
            listener.cancel()
            if let cont = codeContinuation {
                codeContinuation = nil
                cont.resume(with: result)
            } else {
                pendingResult = result
            }
        }

        private func accept(_ connection: NWConnection) {
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) {
                [weak self] data, _, _, error in
                guard let self else {
                    connection.cancel()
                    return
                }
                guard error == nil, let data,
                      let request = String(data: data, encoding: .utf8)
                else {
                    connection.cancel()
                    return
                }
                self.handle(request: request, on: connection)
            }
        }

        private func handle(request: String, on connection: NWConnection) {
            // Request line: "GET /?code=…&state=… HTTP/1.1"
            let line = request.prefix { $0 != "\r" && $0 != "\n" }
            let parts = line.split(separator: " ")
            guard parts.count >= 2,
                  let comps = URLComponents(string: String(parts[1])),
                  let items = comps.queryItems,
                  items.contains(where: { $0.name == "code" || $0.name == "error" })
            else {
                // Not the OAuth redirect (favicon etc.) — keep waiting.
                respond(status: 404, body: "Not found", on: connection)
                return
            }

            func value(_ name: String) -> String? {
                items.first { $0.name == name }?.value
            }

            if let error = value("error") {
                respond(status: 200, body: Self.page(
                    title: "Sign-in not completed",
                    detail: "You can close this tab and try again from Ghoztty."),
                    on: connection)
                finish(.failure(.denied(error)))
                return
            }
            guard value("state") == expectedState else {
                respond(status: 400, body: "State mismatch", on: connection)
                finish(.failure(.stateMismatch))
                return
            }
            guard let code = value("code"), !code.isEmpty else {
                respond(status: 400, body: "Missing code", on: connection)
                return
            }
            respond(status: 200, body: Self.page(
                title: "Signed in to Ghoztty",
                detail: "You can close this tab and return to Ghoztty."),
                on: connection)
            finish(.success(code))
        }

        private func respond(status: Int, body: String, on connection: NWConnection) {
            let reason = status == 200 ? "OK" : status == 404 ? "Not Found" : "Bad Request"
            let payload = Data(body.utf8)
            let head = "HTTP/1.1 \(status) \(reason)\r\n"
                + "Content-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(payload.count)\r\n"
                + "Connection: close\r\n\r\n"
            connection.send(
                content: Data(head.utf8) + payload,
                completion: .contentProcessed { _ in connection.cancel() })
        }

        private static func page(title: String, detail: String) -> String {
            """
            <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>
            <body style="font-family:-apple-system,sans-serif;text-align:center;margin-top:20vh">
            <h2>\(title)</h2><p>\(detail)</p></body></html>
            """
        }
    }
}
