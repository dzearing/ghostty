import CryptoKit
import Foundation
import Network

/// The pure, headlessly-testable pieces of the Google OAuth 2.0
/// authorization-code + PKCE flow used by `RelayAccount` (WP-B2):
///
/// - PKCE verifier/challenge generation (RFC 7636, S256)
/// - the authorization URL builder
/// - a loopback redirect receiver (`http://127.0.0.1:<random port>` — the
///   redirect style Google supports for **Desktop app** OAuth clients, no
///   registered redirect URI needed)
/// - the token-endpoint client (code exchange + refresh) with decoding of
///   Google's token response and ID-token (JWT) claims
/// - ID-token expiry math
///
/// Endpoint URLs are injectable via `Endpoints` **at construction time only**
/// (the relay's `IssuerURL` pattern: tests build their own `Endpoints`
/// pointing at a local fake; production always uses `.google` — there is no
/// environment override).
///
/// Everything here is UI-free (Foundation + CryptoKit + Network) so it can be
/// exercised by a standalone `swiftc` harness without the app.
enum GoogleOAuth {
    // MARK: - Endpoints

    /// The OAuth endpoints in use. Injectable for tests only; production code
    /// always passes `.google`.
    struct Endpoints: Sendable {
        var authorization: URL
        var token: URL

        static let google = Endpoints(
            authorization: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            token: URL(string: "https://oauth2.googleapis.com/token")!)
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
    /// `prompt=consent` guarantee a refresh token on every (re-)sign-in.
    static func authorizationURL(
        endpoints: Endpoints,
        clientID: String,
        redirectURI: String,
        state: String,
        codeChallenge: String,
        scopes: [String] = ["openid", "email"]
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

    // MARK: - Token response + ID-token claims

    /// Google's token-endpoint response (both the code exchange and the
    /// refresh grant). Snake-case keys per OAuth.
    struct TokenResponse: Decodable, Equatable {
        var accessToken: String?
        var expiresIn: Double?
        var idToken: String?
        var refreshToken: String?
        var scope: String?
        var tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case idToken = "id_token"
            case refreshToken = "refresh_token"
            case scope
            case tokenType = "token_type"
        }
    }

    /// The ID-token (JWT) claims we read. NOTE: the client does NOT verify
    /// the signature — the token came over TLS straight from Google's token
    /// endpoint and the RELAY is the enforcement point (it verifies signature,
    /// `aud`, `exp`, allowlist). The claims here are display/cache hints only.
    struct IDTokenClaims: Decodable, Equatable {
        var email: String?
        var emailVerified: Bool?
        var exp: Double?
        var sub: String?

        enum CodingKeys: String, CodingKey {
            case email
            case emailVerified = "email_verified"
            case exp
            case sub
        }
    }

    enum ClaimsError: LocalizedError {
        case malformed
        var errorDescription: String? { "The Google ID token could not be parsed." }
    }

    /// Decode the payload (claims) segment of a JWT without verifying it.
    static func parseIDTokenClaims(_ idToken: String) throws -> IDTokenClaims {
        let parts = idToken.split(separator: ".")
        guard parts.count == 3,
              let payload = PKCE.base64URLDecode(String(parts[1])),
              let claims = try? JSONDecoder().decode(IDTokenClaims.self, from: payload)
        else { throw ClaimsError.malformed }
        return claims
    }

    // MARK: - Expiry math

    /// An ID token cached in memory with its expiry. The token is considered
    /// usable only while it has more than `refreshLeeway` (60s) of life left,
    /// so relay calls never race the expiry.
    struct CachedIDToken {
        let token: String
        let expiresAt: Date

        static let refreshLeeway: TimeInterval = 60

        /// Expiry resolution order: the JWT `exp` claim (authoritative),
        /// else `expires_in` relative to `now`, else "already stale" (forces
        /// a refresh on next use — safe default for an opaque response).
        init(token: String, expiresIn: Double?, now: Date = Date()) {
            self.token = token
            if let exp = (try? GoogleOAuth.parseIDTokenClaims(token))?.exp {
                self.expiresAt = Date(timeIntervalSince1970: exp)
            } else if let expiresIn {
                self.expiresAt = now.addingTimeInterval(expiresIn)
            } else {
                self.expiresAt = now
            }
        }

        func isFresh(now: Date = Date()) -> Bool {
            expiresAt.timeIntervalSince(now) > Self.refreshLeeway
        }
    }

    // MARK: - Token-endpoint client

    /// Client for the token endpoint: authorization-code exchange and
    /// refresh-token grant. The endpoint comes from `Endpoints` (injectable
    /// for tests, `.google` in production).
    struct TokenClient {
        let endpoints: Endpoints
        let clientID: String
        /// Desktop-app clients are issued a `client_secret` that Google
        /// requires at the token endpoint even though it is not confidential
        /// for this client type.
        let clientSecret: String?
        var urlSession: URLSession = .shared

        enum TokenError: LocalizedError {
            /// Non-2xx from the token endpoint; carries the OAuth `error`
            /// / `error_description` when the body had one.
            case http(Int, String)
            case badResponse

            var errorDescription: String? {
                switch self {
                case .http(let code, let detail):
                    return detail.isEmpty
                        ? "Google's token endpoint returned HTTP \(code)."
                        : "Google's token endpoint returned HTTP \(code): \(detail)"
                case .badResponse:
                    return "Google's token endpoint returned a response that couldn't be parsed."
                }
            }
        }

        /// Exchange an authorization code (+ PKCE verifier) for tokens.
        func exchange(
            code: String,
            redirectURI: String,
            codeVerifier: String
        ) async throws -> TokenResponse {
            var form = [
                "grant_type": "authorization_code",
                "code": code,
                "client_id": clientID,
                "redirect_uri": redirectURI,
                "code_verifier": codeVerifier,
            ]
            if let clientSecret { form["client_secret"] = clientSecret }
            return try await post(form)
        }

        /// Redeem a refresh token for a fresh ID token.
        func refresh(refreshToken: String) async throws -> TokenResponse {
            var form = [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": clientID,
            ]
            if let clientSecret { form["client_secret"] = clientSecret }
            return try await post(form)
        }

        private func post(_ form: [String: String]) async throws -> TokenResponse {
            var req = URLRequest(url: endpoints.token)
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(Self.formEncode(form).utf8)
            let (data, resp) = try await urlSession.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw TokenError.badResponse }
            guard (200..<300).contains(http.statusCode) else {
                struct OAuthErrorBody: Decodable {
                    let error: String?
                    let errorDescription: String?
                    enum CodingKeys: String, CodingKey {
                        case error
                        case errorDescription = "error_description"
                    }
                }
                let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: data)
                throw TokenError.http(
                    http.statusCode, body?.errorDescription ?? body?.error ?? "")
            }
            guard let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
                throw TokenError.badResponse
            }
            return tokens
        }

        /// `application/x-www-form-urlencoded` encoding. Keys are sorted so
        /// the output is deterministic (testability).
        static func formEncode(_ form: [String: String]) -> String {
            form.sorted { $0.key < $1.key }
                .map { "\(formEscape($0.key))=\(formEscape($0.value))" }
                .joined(separator: "&")
        }

        private static let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

        static func formEscape(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
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
        private let queue = DispatchQueue(label: "com.mitchellh.ghostty.oauth-loopback")

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
