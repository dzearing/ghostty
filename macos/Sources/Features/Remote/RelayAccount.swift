import AppKit
import Combine
import Foundation
import Security

/// The signed-in Google account that authorizes relay calls (WP-B2).
///
/// One instance (`shared`) owns:
/// - the **refresh token** persisted in the Keychain (generic password,
///   service `com.mitchellh.ghostty.relay-account`)
/// - a short-lived **ID token** cached in memory and refreshed via the refresh
///   token when it is expired or within 60s of expiry
/// - the signed-in **email** (from the ID-token claims, for display)
///
/// `signIn()` runs Google's authorization-code + PKCE flow for a **Desktop
/// app** OAuth client: it opens the system browser and catches the redirect on
/// a loopback mini-listener (`GoogleOAuth.LoopbackCodeReceiver`). The system
/// browser (rather than `ASWebAuthenticationSession`) was chosen because it is
/// what Google documents for Desktop clients (loopback redirects need no
/// registered URI), it reuses the user's existing Google session + 2FA state,
/// and every stage up to "open the browser" is headlessly testable with an
/// injected URL-opener.
///
/// ### The token-resolution seam
/// `RelayAccount.resolveToken()` is the ONE place any relay call gets its
/// bearer: the signed-in account's ID token first, falling back to the dev
/// token (`GHOSTTY_RELAY_TOKEN`) when signed out. The directory client
/// (`RelayDirectoryClient.current()`), the chooser dial, the WP-D2 restore
/// path, the WP-D1 reconnect path, and the IPC `+new-remote-window` path (when
/// no explicit `--token` is given) all go through it.
@MainActor
final class RelayAccount: ObservableObject {
    static let shared = RelayAccount()

    enum AccountError: LocalizedError {
        /// No Google OAuth client id is configured.
        case notConfigured
        /// No refresh token in the Keychain — the user is signed out.
        case signedOut
        /// The token response was missing a required field.
        case badTokenResponse
        /// The system refused to open the sign-in URL in a browser.
        case browserFailed
        /// A Keychain read/write failed.
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Google client not configured — see docs/design/relay-oidc-setup.md"
            case .signedOut:
                return "Not signed in to a Google account."
            case .badTokenResponse:
                return "Google's sign-in response was missing the expected tokens."
            case .browserFailed:
                return "Couldn't open the browser for Google sign-in."
            case .keychain(let status):
                return "Keychain error \(status) while storing the account."
            }
        }
    }

    /// The signed-in account's email, or nil when signed out. Drives the
    /// chooser's account row.
    @Published private(set) var email: String?

    var isSignedIn: Bool { email != nil }

    private let endpoints: GoogleOAuth.Endpoints
    private let keychain: RelayAccountKeychain
    private let openURL: (URL) -> Bool

    /// In-memory ID-token cache; never persisted (ID tokens are short-lived).
    private var cachedIDToken: GoogleOAuth.CachedIDToken?

    /// In-flight refresh, shared so concurrent `currentIDToken()` callers
    /// coalesce onto one token-endpoint request.
    private var refreshTask: Task<GoogleOAuth.TokenResponse, Error>?

    /// `endpoints`/`keychain`/`openURL` are injectable for tests ONLY (the
    /// relay's `IssuerURL` pattern — no environment override in production).
    init(
        endpoints: GoogleOAuth.Endpoints = .google,
        keychain: RelayAccountKeychain =
            RelayAccountKeychain(service: "com.mitchellh.ghostty.relay-account"),
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.endpoints = endpoints
        self.keychain = keychain
        self.openURL = openURL
        // Restore the signed-in identity across launches (the refresh token
        // outlives the app; the first relay call mints a fresh ID token).
        self.email = keychain.load()?.email
    }

    // MARK: - OAuth client configuration

    struct ClientConfig {
        let clientID: String
        let clientSecret: String?
    }

    nonisolated static let clientIDDefaultsKey = "GhosttyGoogleClientID"
    nonisolated static let clientSecretDefaultsKey = "GhosttyGoogleClientSecret"

    /// The Google OAuth client, sourced from (in order) the environment
    /// (`GHOSTTY_GOOGLE_CLIENT_ID` / `GHOSTTY_GOOGLE_CLIENT_SECRET`) then
    /// UserDefaults (`GhosttyGoogleClientID` / `GhosttyGoogleClientSecret`,
    /// e.g. `defaults write <bundle id> GhosttyGoogleClientID <id>`). Returns
    /// nil when no client id is configured — the sign-in UI then points at the
    /// setup doc. There is deliberately no baked-in default: the client is not
    /// registered yet (see docs/design/relay-oidc-setup.md §1).
    nonisolated static func clientConfig() -> ClientConfig? {
        func nonEmpty(_ s: String?) -> String? { (s?.isEmpty == false) ? s : nil }
        let env = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        guard let id = nonEmpty(env["GHOSTTY_GOOGLE_CLIENT_ID"])
            ?? nonEmpty(defaults.string(forKey: clientIDDefaultsKey))
        else { return nil }
        let secret = nonEmpty(env["GHOSTTY_GOOGLE_CLIENT_SECRET"])
            ?? nonEmpty(defaults.string(forKey: clientSecretDefaultsKey))
        return ClientConfig(clientID: id, clientSecret: secret)
    }

    /// Whether sign-in is possible (a Google client id is configured).
    nonisolated static var isConfigured: Bool { clientConfig() != nil }

    // MARK: - Sign-in / sign-out

    /// Run the full browser sign-in: PKCE + loopback redirect + code exchange.
    /// On success the refresh token (+ email) is stored in the Keychain, the
    /// ID token is cached, and `email` publishes the signed-in state.
    func signIn() async throws {
        guard let config = Self.clientConfig() else { throw AccountError.notConfigured }

        let verifier = GoogleOAuth.PKCE.generateVerifier()
        let state = GoogleOAuth.PKCE.randomURLSafeToken(byteCount: 16)
        let receiver = try GoogleOAuth.LoopbackCodeReceiver(expectedState: state)
        let port = try await receiver.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        let url = GoogleOAuth.authorizationURL(
            endpoints: endpoints,
            clientID: config.clientID,
            redirectURI: redirectURI,
            state: state,
            codeChallenge: GoogleOAuth.PKCE.challenge(for: verifier))
        guard openURL(url) else {
            receiver.cancel()
            throw AccountError.browserFailed
        }

        let code: String
        do {
            code = try await receiver.waitForCode()
        } catch {
            receiver.cancel()
            throw error
        }

        let client = GoogleOAuth.TokenClient(
            endpoints: endpoints,
            clientID: config.clientID,
            clientSecret: config.clientSecret)
        let tokens = try await client.exchange(
            code: code, redirectURI: redirectURI, codeVerifier: verifier)
        guard let idToken = tokens.idToken, let refreshToken = tokens.refreshToken else {
            throw AccountError.badTokenResponse
        }
        let claims = try GoogleOAuth.parseIDTokenClaims(idToken)
        guard let email = claims.email else { throw AccountError.badTokenResponse }

        try keychain.save(.init(refreshToken: refreshToken, email: email))
        cachedIDToken = .init(token: idToken, expiresIn: tokens.expiresIn)
        refreshTask?.cancel()
        refreshTask = nil
        self.email = email
    }

    /// Forget the account: delete the Keychain item and drop the in-memory
    /// token. Relay calls fall back to the dev token (if any) afterwards.
    ///
    /// Also clears the account's machine list from the shared registry —
    /// machines are per-account resources, so a signed-out chooser must not
    /// keep showing them. This clear is unconditional: even when a dev token
    /// (`GHOSTTY_RELAY_TOKEN`) remains available, sign-out empties the list
    /// (the dev token only repopulates it on the NEXT explicit refresh, e.g.
    /// reopening the chooser).
    func signOut() {
        keychain.delete()
        cachedIDToken = nil
        refreshTask?.cancel()
        refreshTask = nil
        email = nil
        // Only the real app account touches the shared registry (test
        // instances with injected keychains must not).
        if self === Self.shared {
            MachineRegistry.shared.clearRelayMachines()
        }
    }

    // MARK: - Tokens

    /// The account's current ID token: the cached one while it has >60s of
    /// life left, otherwise a fresh one minted via the refresh-token grant.
    /// Throws when signed out, unconfigured, or when the refresh fails.
    func currentIDToken() async throws -> String {
        if let cached = cachedIDToken, cached.isFresh() { return cached.token }

        // Coalesce onto an in-flight refresh.
        if let task = refreshTask {
            guard let idToken = try await task.value.idToken else {
                throw AccountError.badTokenResponse
            }
            return idToken
        }

        guard let stored = keychain.load() else { throw AccountError.signedOut }
        guard let config = Self.clientConfig() else { throw AccountError.notConfigured }

        let client = GoogleOAuth.TokenClient(
            endpoints: endpoints,
            clientID: config.clientID,
            clientSecret: config.clientSecret)
        let task = Task { try await client.refresh(refreshToken: stored.refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }

        let tokens = try await task.value
        guard let idToken = tokens.idToken else { throw AccountError.badTokenResponse }
        cachedIDToken = .init(token: idToken, expiresIn: tokens.expiresIn)
        // Google may rotate the refresh token; persist the newest one.
        if let rotated = tokens.refreshToken, rotated != stored.refreshToken {
            try? keychain.save(.init(refreshToken: rotated, email: stored.email))
        }
        return idToken
    }
}

// MARK: - Token-resolution seam

extension RelayAccount {
    /// The dev bearer from `GHOSTTY_RELAY_TOKEN`, or nil. Fallback only —
    /// dead once the relay's `DEV_AUTH` is switched off (WP-B1).
    nonisolated static var devToken: String? {
        let t = ProcessInfo.processInfo.environment["GHOSTTY_RELAY_TOKEN"]
        return (t?.isEmpty == false) ? t : nil
    }

    /// THE token-resolution seam for every relay call (directory + dials):
    /// the signed-in account's ID token first (refreshing as needed), falling
    /// back to the dev token when signed out or when the refresh fails.
    /// Returns nil when neither source is available.
    static func resolveToken() async -> String? {
        if let token = try? await shared.currentIDToken() { return token }
        return devToken
    }

    /// Synchronous capability check: is ANY token source configured (signed-in
    /// account or dev token)? Used where an async resolve would be premature
    /// (e.g. "should the chooser open at zero machines").
    static var hasCredentials: Bool { shared.isSignedIn || devToken != nil }
}

// MARK: - Keychain storage

/// Generic-password storage for the relay account (refresh token + email).
/// One item per `service`; the payload is a small JSON blob so future fields
/// don't need a Keychain schema change.
struct RelayAccountKeychain {
    let service: String
    private let account = "google-account"

    struct Stored: Codable, Equatable {
        var refreshToken: String
        var email: String
    }

    func load() -> Stored? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        return stored
    }

    func save(_ stored: Stored) throws {
        guard let data = try? JSONEncoder().encode(stored) else {
            throw RelayAccount.AccountError.keychain(errSecParam)
        }
        // Replace-then-add keeps this a single code path (no update branch).
        SecItemDelete(baseQuery() as CFDictionary)
        var attrs = baseQuery()
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw RelayAccount.AccountError.keychain(status)
        }
    }

    func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
