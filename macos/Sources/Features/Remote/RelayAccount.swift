import AppKit
import Combine
import Foundation
import Security

/// The signed-in Google account that authorizes relay calls, in a
/// relay-brokered (BFF) posture.
///
/// One instance (`shared`) owns:
/// - a short-lived **relay session token** persisted in the Keychain (generic
///   password, service `com.dzearing.ghoztty.relay-account`) with its expiry
/// - the signed-in **email** + profile **picture** (for display)
///
/// `signIn()` runs Google's authorization-code + PKCE flow for a **Desktop
/// app** OAuth client: it opens the system browser, catches the redirect on a
/// loopback mini-listener (`GoogleOAuth.LoopbackCodeReceiver`), and hands the
/// authorization `code` (+ PKCE verifier) to the RELAY's `/oauth/exchange`.
/// The relay holds the confidential client secret, performs the Google token
/// exchange server-side, enforces the email allowlist, stores the Google
/// refresh token (encrypted, server-side only), and returns a relay session
/// token. **Google id/refresh tokens never touch the client.**
///
/// ### The token-resolution seam
/// `RelayAccount.resolveToken()` is the ONE place any relay call gets its
/// bearer: the signed-in account's relay session token (renewed via
/// `/oauth/renew` as it nears expiry). The directory client
/// (`RelayDirectoryClient.current()`), the chooser dial, the WP-D2 restore
/// path, the WP-D1 reconnect path, and the IPC `+new-remote-window` path (when
/// no explicit `--token` is given) all go through it.
@MainActor
final class RelayAccount: ObservableObject {
    static let shared = RelayAccount()

    enum AccountError: LocalizedError {
        /// No Google OAuth client id is baked into the build.
        case notConfigured
        /// No relay session in the Keychain — the user is signed out.
        case signedOut
        /// The system refused to open the sign-in URL in a browser.
        case browserFailed
        /// A Keychain read/write failed.
        case keychain(OSStatus)
        /// Sign-out could not revoke THIS machine's relay enrollment, so the
        /// machine is still reachable by every other client on the account.
        /// The account is deliberately left signed IN — see `signOut(_:)`.
        case machineRevocationFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "This build has no Google client id — sign-in is unavailable."
            case .signedOut:
                return "Not signed in to a Google account."
            case .browserFailed:
                return "Couldn't open the browser for Google sign-in."
            case .keychain(let status):
                return "Keychain error \(status) while storing the account."
            case .machineRevocationFailed(let detail):
                return "This machine couldn't be removed from your account: \(detail)"
            }
        }
    }

    /// Whether `signOut` should attempt this machine's revocation, or skip
    /// straight to queueing it because the caller already saw it fail and the
    /// user chose to sign out regardless.
    enum SignOutMode {
        case revokingMachine
        case deferringMachineRevocation
    }

    /// The signed-in account's email, or nil when signed out. Drives the
    /// chooser's account row.
    @Published private(set) var email: String?

    /// The signed-in account's Google profile-photo URL (from the relay's
    /// sign-in response), or nil when signed out / when the session predates
    /// the `profile` scope — the UI then shows a monogram.
    @Published private(set) var pictureURL: URL?

    var isSignedIn: Bool { email != nil }

    /// The Google OAuth client id — a build-time constant baked into the app
    /// bundle (Info.plist `GhosttyGoogleClientID`, injected via the
    /// `-Dgoogle-client-id` build option). Injectable for tests. The client id
    /// is public (it appears in the browser authorize URL); the confidential
    /// client secret lives ONLY on the relay.
    let clientID: String

    private let endpoints: GoogleOAuth.Endpoints
    private let keychain: RelayAccountStorage
    private let openURL: (URL) -> Bool

    /// THIS machine's relay enrollment. Sign-out hard-revokes it and sign-in
    /// restores it — see `MachineEnrollmentRevoking` for the rule and why the
    /// two credentials are separate. Injectable for tests.
    private let enrollment: MachineEnrollmentRevoking

    /// In-memory copy of the stored session (token + expiry), so the hot path
    /// avoids a Keychain read. Renewed via `/oauth/renew` near expiry.
    private var cachedSession: RelayAccountKeychain.Stored?

    /// In-flight renew, shared so concurrent `currentToken()` callers coalesce
    /// onto one `/oauth/renew` request.
    private var refreshTask: Task<GoogleOAuth.RelaySessionClient.SessionResponse, Error>?

    /// The deferred Keychain load kicked off in `init` (see there for why it
    /// is off-main). Until it completes, `isSignedIn`/`hasCredentials` read as
    /// signed OUT even when a persisted session exists — anything that gates
    /// on those at launch (e.g. the machine registry's refresh, which CLEARS
    /// account state when credentials are absent) must `waitForInitialLoad()`
    /// first or it races to a false "signed out".
    private var initialLoadTask: Task<Void, Never>?

    /// The Google OAuth client id baked into the app bundle at build time.
    nonisolated static func bundledClientID() -> String {
        (Bundle.main.infoDictionary?["GhosttyGoogleClientID"] as? String) ?? ""
    }

    /// Sign-in is possible whenever a client id is baked in — always true in a
    /// shipped build. (No runtime credential lookup remains.)
    nonisolated static var isConfigured: Bool { !bundledClientID().isEmpty }

    /// The relay base URL (mirrors `RelayDirectoryClient.defaultBase`).
    nonisolated static var defaultRelayBase: URL {
        URL(string: RelayDirectoryClient.defaultBase)!
    }

    /// `clientID`/`endpoints`/`keychain`/`openURL` are injectable for tests
    /// ONLY (the relay's `IssuerURL` pattern — no environment override in
    /// production).
    init(
        clientID: String = RelayAccount.bundledClientID(),
        endpoints: GoogleOAuth.Endpoints = .relay(base: RelayAccount.defaultRelayBase),
        keychain: RelayAccountStorage =
            RelayAccountKeychain(service: "com.dzearing.ghoztty.relay-account"),
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        enrollment: MachineEnrollmentRevoking = LocalMachineEnrollment.shared
    ) {
        self.clientID = clientID
        self.endpoints = endpoints
        self.keychain = keychain
        self.openURL = openURL
        self.enrollment = enrollment
        // Restore the signed-in identity across launches (the session token
        // outlives the app until it expires; the first relay call renews it) —
        // but NEVER on the main thread. `SecItemCopyMatching` can stall for a
        // long time (ACL prompt after a re-sign, locked keychain, securityd
        // contention); doing it synchronously here froze the ENTIRE app at
        // launch. Defer it off-main and publish the identity when it arrives;
        // until then we read as signed out (`email == nil`), which degrades
        // gracefully — a relay call that races the load resolves its own token
        // via `currentToken()` (also off-main), and the UI updates via
        // `@Published` when it lands.
        initialLoadTask = Task { [weak self] in
            guard let self else { return }
            let stored = await Self.loadStoredOffMain(self.keychain)
            self.cachedSession = stored
            self.email = stored?.email
            self.pictureURL = stored?.picture.flatMap(URL.init(string:))
        }
    }

    /// Suspend until the persisted session (if any) has been loaded from the
    /// Keychain and published. After this, `isSignedIn`/`hasCredentials`
    /// reflect reality instead of the pre-load "signed out" default.
    func waitForInitialLoad() async {
        await initialLoadTask?.value
    }

    /// Load the persisted session OFF the main thread. Keychain reads block
    /// (see `init`); the whole purpose of this hop is to keep the main actor
    /// responsive. A slow read (> 0.5s) is logged.
    nonisolated static func loadStoredOffMain(
        _ keychain: RelayAccountStorage
    ) async -> RelayAccountKeychain.Stored? {
        await Task.detached(priority: .userInitiated) {
            let start = Date()
            let stored = keychain.load()
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > 0.5 {
                Ghostty.logger.warning(
                    "relay account: Keychain load took \(elapsed, format: .fixed(precision: 2), privacy: .public)s (off main thread; UI was not blocked)")
            }
            return stored
        }.value
    }

    // MARK: - Sign-in / sign-out

    /// Run the full browser sign-in: PKCE + loopback redirect, then hand the
    /// authorization code to the relay's `/oauth/exchange`. On success the
    /// relay session token (+ email/picture) is stored in the Keychain and
    /// `email` publishes the signed-in state.
    func signIn() async throws {
        guard !clientID.isEmpty else { throw AccountError.notConfigured }

        let verifier = GoogleOAuth.PKCE.generateVerifier()
        let state = GoogleOAuth.PKCE.randomURLSafeToken(byteCount: 16)
        let receiver = try GoogleOAuth.LoopbackCodeReceiver(expectedState: state)
        let port = try await receiver.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        let url = GoogleOAuth.authorizationURL(
            endpoints: endpoints,
            clientID: clientID,
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

        let client = GoogleOAuth.RelaySessionClient(endpoints: endpoints)
        let session = try await client.exchange(
            code: code, redirectURI: redirectURI, codeVerifier: verifier)

        let stored = RelayAccountKeychain.Stored(
            sessionToken: session.sessionToken, expiry: session.expiry,
            email: session.email, picture: session.picture)
        try keychain.save(stored)
        cachedSession = stored
        refreshTask?.cancel()
        refreshTask = nil
        self.email = session.email
        self.pictureURL = session.picture.flatMap(URL.init(string:))
        // Give this machine its enrollment back, if THIS account is the one
        // whose sign-out revoked it: the machine rejoins the account under a
        // fresh credential and a running agent adopts it within one watcher
        // tick. A different account signing in never inherits it — see
        // `MachineEnrollmentRevoking`.
        await enrollment.restoreEnrollment(
            accountEmail: session.email, sessionToken: session.sessionToken)
        // Recover the remote windows suspended at sign-out: replay their
        // preserved manifest entries through the launch-restore path. Only the
        // real app account drives app-level window state (test instances with
        // injected keychains must not).
        if self === Self.shared {
            (NSApp.delegate as? AppDelegate)?.relayAccountDidSignIn()
        }
    }

    /// Forget the account. In order:
    ///
    /// 1. **Hard-revoke THIS machine's relay enrollment** when it belongs to
    ///    this account (`MachineEnrollmentRevoking`): the device row is deleted
    ///    server-side and every live connection — control and in-flight bridged
    ///    data — is severed, so no other client on the account can reach or
    ///    observe this machine afterwards. This is the security half of
    ///    sign-out and it is why the method is `async throws`: revoking a
    ///    machine needs the network, and a revocation that silently failed is
    ///    exactly the hole this closes.
    /// 2. Revoke the user SESSION server-side (`/oauth/signout`).
    /// 3. Delete the Keychain item and drop the in-memory session. Relay calls
    ///    have no token afterwards (there is no dev fallback).
    /// 4. Clear the account's machine list from the shared registry — machines
    ///    are per-account resources, so a signed-out chooser must not keep
    ///    showing them.
    /// 5. Close every open account-backed (relay) remote window via
    ///    `AppDelegate.relayAccountDidSignOut()`, preserving each window's
    ///    `RemoteSessionManifest` entry so `signIn()` can restore them.
    ///
    /// **Throws `AccountError.machineRevocationFailed` and stays SIGNED IN**
    /// when step 1 did not revoke the machine: it is still reachable, so
    /// reporting "signed out" would be a lie. The caller offers a retry, and
    /// `.deferringMachineRevocation` signs out anyway — arming a pending
    /// revocation that is retried at every launch and on every
    /// network-came-back transition until the relay confirms it. Nothing about
    /// a failed step 1 is silent.
    ///
    /// Steps 2–5 are unconditional once step 1 is settled. `/oauth/signout` is
    /// deliberately fire-and-forget: its failure is ignored either way (the
    /// session token is destroyed locally and the relay-side row expires on its
    /// own), so awaiting it would only make a signed-out-while-offline user
    /// stare at a disabled button for the request timeout, buying nothing.
    @discardableResult
    func signOut(_ mode: SignOutMode = .revokingMachine) async throws
        -> MachineEnrollmentRevocation
    {
        await waitForInitialLoad()

        // 1. The machine, first and blocking.
        var revocation: MachineEnrollmentRevocation = .nothingEnrolled
        if let email {
            switch mode {
            case .revokingMachine:
                revocation = await enrollment.revokeForSignOut(accountEmail: email)
                if case .notRevoked(let detail) = revocation {
                    throw AccountError.machineRevocationFailed(detail)
                }
            case .deferringMachineRevocation:
                // The caller already watched the revocation fail and the user
                // chose to proceed. Attempting it a second time would make
                // them wait out the same timeouts again — and a retry that
                // happened to succeed on a half-landed revocation is what the
                // pending queue is for anyway.
                enrollment.armPendingRevocation(accountEmail: email)
                revocation = .notRevoked(detail: "deferred by the user")
            }
        }

        // 2. The session.
        if let token = cachedSession?.sessionToken {
            let client = GoogleOAuth.RelaySessionClient(endpoints: endpoints)
            Task { await client.signOut(sessionToken: token) }
        }
        keychain.delete()
        cachedSession = nil
        refreshTask?.cancel()
        refreshTask = nil
        email = nil
        pictureURL = nil
        // Only the real app account touches shared app state (test instances
        // with injected keychains must not).
        if self === Self.shared {
            MachineRegistry.shared.clearRelayMachines()
            // Account-backed remote windows must not outlive the account:
            // close them now, preserving their manifest entries so a later
            // sign-in restores them (the agent keeps the detached sessions
            // alive — detach ≠ terminate).
            (NSApp.delegate as? AppDelegate)?.relayAccountDidSignOut()
        }
        return revocation
    }

    // MARK: - Tokens

    /// The account's current relay session token: the cached one while it has
    /// more than 60s of life left, otherwise a freshly renewed one (via
    /// `/oauth/renew`, which uses the relay-held Google refresh token behind
    /// the scenes). Throws when signed out or when the renew fails.
    func currentToken() async throws -> String {
        let leeway: TimeInterval = 60

        // Ensure the stored session is in memory (races the deferred launch
        // load — reload off-main if it hasn't landed yet).
        if cachedSession == nil {
            cachedSession = await Self.loadStoredOffMain(keychain)
        }
        guard let stored = cachedSession else { throw AccountError.signedOut }

        if stored.expiry - Date().timeIntervalSince1970 > leeway {
            return stored.sessionToken
        }

        // Coalesce onto an in-flight renew.
        if let task = refreshTask {
            return try await task.value.sessionToken
        }

        let client = GoogleOAuth.RelaySessionClient(endpoints: endpoints)
        let task = Task { try await client.renew(sessionToken: stored.sessionToken) }
        refreshTask = task
        defer { refreshTask = nil }

        let session = try await task.value
        let newStored = RelayAccountKeychain.Stored(
            sessionToken: session.sessionToken, expiry: session.expiry,
            email: session.email, picture: session.picture)
        try? keychain.save(newStored)
        cachedSession = newStored
        if email != session.email { email = session.email }
        if pictureURL?.absoluteString != session.picture {
            pictureURL = session.picture.flatMap(URL.init(string:))
        }
        return session.sessionToken
    }
}

// MARK: - Token-resolution seam

extension RelayAccount {
    /// THE token-resolution seam for every relay call (directory + dials): the
    /// signed-in account's relay session token, renewing as needed. Returns nil
    /// when signed out or when the renew fails.
    static func resolveToken() async -> String? {
        try? await shared.currentToken()
    }

    /// Synchronous capability check: is there a stored session? Used where an
    /// async resolve would be premature (e.g. "should the chooser open at zero
    /// machines").
    static var hasCredentials: Bool { shared.isSignedIn }
}

// MARK: - Keychain storage

/// Where the relay session is persisted. `RelayAccountKeychain` is the only
/// production conformance; the protocol exists so tests can drive
/// `RelayAccount` (sign-out in particular) without touching the real Keychain —
/// which, on an ad-hoc-signed debug build, would prompt for a password on every
/// rebuild (see `RelayAccountKeychain.isDisabled`).
///
/// `Sendable` because the load runs on a detached task (see
/// `RelayAccount.loadStoredOffMain`).
protocol RelayAccountStorage: Sendable {
    func load() -> RelayAccountKeychain.Stored?
    func save(_ stored: RelayAccountKeychain.Stored) throws
    func delete()
}

/// Generic-password storage for the relay account (session token + expiry +
/// display fields). One item per `service`; the payload is a small JSON blob so
/// future fields don't need a Keychain schema change.
struct RelayAccountKeychain: RelayAccountStorage {
    let service: String
    private let account = "google-account"

    /// Dev/test opt-out: when set, ALL Keychain access is skipped (`load` → nil,
    /// `save`/`delete` → no-op), so an ad-hoc-signed debug build never triggers
    /// the login-keychain ACL password prompt.
    ///
    /// Why this is needed: an ad-hoc signature (`codesign -s -`, no team
    /// identity) has NO stable designated requirement — the keychain ACL can
    /// only trust the app by its exact code hash, which changes on EVERY
    /// rebuild. So macOS re-prompts after each build and "Always Allow" can't
    /// stick (the entry it adds is for the previous hash). This gate lets the
    /// rebuild-heavy dev/test loop (and manual debug launches that don't need
    /// relay) run prompt-free.
    ///
    /// Off by default → ZERO change for the release app or anyone who hasn't
    /// opted in. Enable via env `GHOSTTY_RELAY_DISABLE=1` (dev shells / the E2E
    /// harness) or `defaults write <bundle id> GhosttyRelayDisable -bool YES`
    /// (persists across Finder launches of the debug app; delete the key or set
    /// it NO to re-enable relay). While disabled the app reads as signed out.
    static var isDisabled: Bool {
        if let env = ProcessInfo.processInfo.environment["GHOSTTY_RELAY_DISABLE"],
           !env.isEmpty, env != "0", env.lowercased() != "false" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "GhosttyRelayDisable")
    }

    struct Stored: Codable, Equatable {
        /// The relay-minted session token (opaque, short-lived, revocable).
        var sessionToken: String
        /// Session-token expiry (unix seconds), from the relay.
        var expiry: Double
        var email: String
        /// Profile-photo URL from the relay's sign-in response. Optional so
        /// blobs written without it decode unchanged (nil → the UI shows the
        /// monogram).
        var picture: String?
    }

    func load() -> Stored? {
        if Self.isDisabled { return nil }
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
        if Self.isDisabled { return }
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
        if Self.isDisabled { return }
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
