import Foundation

/// THIS machine's relay **enrollment** — the device credential that makes the
/// Mac the app is running on reachable *as a machine* through the relay.
///
/// ### Why this exists (the security rule)
/// An account's **user session** (`RelayAccount`) and a machine's **device
/// enrollment** are two independent credentials on the relay, deliberately so:
/// an account may own headless hosts that no app is ever signed in on, and
/// `POST /oauth/signout` is session-scoped by design (proven by
/// `TestSignoutAloneLeavesMachineReachable` in `relay/signout_revoke_test.go`).
///
/// That independence was also a hole. Signing out in the app running ON an
/// enrolled machine revoked only the session, so from any *other* client on the
/// same account the machine stayed listed, stayed online, and a session already
/// bridged to it kept streaming. Sign-out looked like "this machine is no
/// longer mine" and wasn't.
///
/// **The rule this type implements:** signing out of the app hard-revokes the
/// relay enrollment of the machine the app is running on, when — and only when
/// — that enrollment belongs to the account signing out. "The account that
/// enrolled this machine is walking away from it, so the machine goes with it."
/// Concretely `POST /v1/agent/deenroll` with the local device credential, which
/// deletes the device row (the token hash is gone, so it can never
/// re-authenticate) *and* severs every live connection — control and in-flight
/// bridged data alike (`Directory.KickDevice`; proven end to end by
/// `TestDeenrollRevokesAndKicksLiveBridge`).
///
/// Two boundaries follow from "only when it belongs to the account":
///
/// - A machine whose agent is enrolled to a **different** account is left
///   completely alone (`.otherAccount`). Someone else's machine is not this
///   app's to revoke, and the app is merely a guest on this host.
/// - A machine with **no** local enrollment — the common case, a Mac used only
///   as a client — has nothing to revoke and sign-out is unchanged.
///
/// ### The one enrollment this cannot see, stated rather than papered over
/// An agent started with `GHOSTTY_DEVICE_TOKEN` in its environment holds a
/// credential that is deliberately NOT on disk: that env var outranks
/// `relay.env` by design (`relay_creds.decide` → `env_wins`), which is what
/// makes it usable as an ops/CI override. The app has no way to read another
/// process's environment, so it cannot identify — and therefore cannot revoke
/// — such a machine, and sign-out reports `.nothingEnrolled` for it.
///
/// Identifying it by HOSTNAME instead was considered and rejected: hostnames
/// collide (two default-named boxes, or a `localhost` entry in
/// `Host.current().names`), and the failure mode would be silently deleting a
/// DIFFERENT machine from the account during sign-out. Hiding a chooser row on
/// a hostname guess is recoverable; revoking the wrong machine is not. The
/// remedy for an env-token host is the existing, explicit one: remove it from
/// the account in the machine chooser ("Remove from Account" →
/// `DELETE /v1/client/devices/{id}`), which performs the very same hard
/// revocation — credential deleted, live connections severed.
///
/// ### What a later sign-in does
/// Sign-out **suspends** the enrollment rather than discarding the fact of it:
/// the machine's name and relay are remembered (`SuspendedEnrollment` — no
/// secret is kept; the credential is dead). Signing back in **with the same
/// account** re-enrolls this machine (`POST /v1/client/devices`) and writes the
/// fresh credential back to `relay.env`, which a running `ghoztty-agent` adopts
/// within one watcher tick and reconnects with (`src/remote/agent/relay_creds.zig`).
/// That mirrors what sign-out/sign-in already do to the account's remote
/// WINDOWS (closed preserving their manifest, restored on sign-in) and is what
/// makes signing out a safe thing to do rather than a one-way door.
///
/// A **different** account signing in never inherits the machine: the suspended
/// record is dropped unread. And restore is refused unless the suspended
/// enrollment's relay is the one this app talks to — a session on relay A
/// cannot mint a device on relay B, and silently enrolling the machine
/// somewhere new is the opposite of what sign-out promised. (Revocation makes
/// the opposite trade: it acts on whatever relay the credential names, because
/// failing safe there means revoking more, not less.)
///
/// ### When the relay can't be reached
/// A revocation that silently fails would leave the machine reachable while the
/// UI says "signed out" — the exact hole this fixes, re-opened. So the
/// revocation is awaited and its failure is **reported** (`RelayAccount.signOut`
/// throws; the account stays signed in so the user can retry). A user who signs
/// out anyway arms a **pending revocation**: `relay.env` is deliberately left
/// in place — it is the retry's own record, and the machine genuinely IS still
/// enrolled until the relay says otherwise — and the revocation is retried at
/// every launch and on every network-came-back transition until the relay
/// confirms it.
@MainActor
protocol MachineEnrollmentRevoking: AnyObject {
    /// Hard-revoke this machine's enrollment because `accountEmail` is signing
    /// out. Never throws: every outcome — including "couldn't reach the relay"
    /// — is a value the caller must decide about.
    func revokeForSignOut(accountEmail: String) async -> MachineEnrollmentRevocation

    /// Record that `accountEmail` signed out while its machine could not be
    /// revoked, so the revocation is retried until it lands.
    func armPendingRevocation(accountEmail: String)

    /// Retry an armed pending revocation. No-op when none is armed.
    func retryPendingRevocation() async

    /// Give this machine back to `accountEmail`: cancel a pending revocation
    /// for that same account, or re-enroll a suspended enrollment. Called on
    /// sign-in AND at every launch while signed in, because a re-enroll can
    /// fail transiently (relay 5xx, device quota, offline at that moment) and
    /// a machine that never comes back is not something the user would think
    /// to fix by signing out and in again.
    ///
    /// Best-effort — a failure leaves the machine unenrolled, which is the safe
    /// direction — and idempotent: with nothing suspended and nothing pending
    /// it costs two `UserDefaults` reads and no network.
    func restoreEnrollment(accountEmail: String, sessionToken: String) async
}

/// What `revokeForSignOut` did. Every case except `.notRevoked` means the
/// machine is not reachable through the relay any more.
enum MachineEnrollmentRevocation: Equatable {
    /// This machine has no relay enrollment — nothing to revoke.
    case nothingEnrolled
    /// Enrolled, but to a different account: not this sign-out's to revoke.
    case otherAccount(ownerEmail: String)
    /// The credential was already dead server-side (401). The local file is
    /// cleared; nothing was reachable to begin with.
    case alreadyRevoked
    /// Revoked: the device row is gone and every live connection was severed.
    case revoked(deviceID: String, machineName: String)
    /// The revocation did NOT happen — the relay refused it or could not be
    /// reached — so THE MACHINE IS STILL REACHABLE. `detail` carries what the
    /// relay actually said (an HTTP status, a URLSession error), because
    /// "couldn't reach" and "reached it and got a 500" call for different
    /// things from the user and only the detail distinguishes them.
    case notRevoked(detail: String)

    /// Whether the machine is known to be unreachable through the relay now.
    var isSecured: Bool {
        if case .notRevoked = self { return false }
        return true
    }
}

// MARK: - relay.env

/// The agent's persisted relay credential file, as the app reads and writes it.
///
/// This is the SAME file `src/remote/agent/enroll.zig` owns (`RELAY_BASE` +
/// `DEVICE_TOKEN`, `KEY=value` lines, `#` comments, LF or CRLF, later line
/// wins, `GHOSTTY_DEVICE_TOKEN` accepted as an alias). Parsing and formatting
/// mirror that module deliberately — a machine may be enrolled by the agent's
/// own CLI/installer flow and revoked by the app, or the reverse, and the two
/// must agree byte for byte. Writes are atomic (tmp + `rename`) and 0600, for
/// the same reason the Zig side is: a live `--relay` daemon polls this file and
/// must never observe a half-written credential.
struct RelayEnvFile {
    /// The parsed credential. Both fields are optional because a partially
    /// written or hand-edited file is ordinary.
    struct Contents: Equatable {
        var relayBase: String?
        var deviceToken: String?

        /// Whether this names a usable enrollment (both halves present).
        var credential: (relayBase: String, deviceToken: String)? {
            guard let relayBase, !relayBase.isEmpty,
                  let deviceToken, !deviceToken.isEmpty
            else { return nil }
            return (relayBase, deviceToken)
        }
    }

    let url: URL

    init(url: URL = RelayEnvFile.defaultURL) {
        self.url = url
    }

    /// Where the agent keeps its credential, resolved exactly as
    /// `enroll.relayEnvPath` does: `GHOSTTY_RELAY_ENV` wins (tests and dev
    /// harnesses use it), then `$XDG_CONFIG_HOME/ghoztty/relay.env`, then
    /// `$HOME/.config/ghoztty/relay.env`.
    static var defaultURL: URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["GHOSTTY_RELAY_ENV"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg)
                .appendingPathComponent("ghoztty", isDirectory: true)
                .appendingPathComponent("relay.env")
        }
        let home = env["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("ghoztty", isDirectory: true)
            .appendingPathComponent("relay.env")
    }

    /// Parse relay.env content. Pure, so the agent-parity rules above are
    /// unit-testable without touching the filesystem.
    ///
    /// Lines are split on `Character.isNewline`, NOT on a literal `"\n"`:
    /// Swift treats CRLF as ONE grapheme cluster, so splitting on `"\n"`
    /// silently fails to split a CRLF file at all — and the Windows installer
    /// writes CRLF. That would have read a whole credential file as one line.
    static func parse(_ text: String) -> Contents {
        var out = Contents()
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            switch key {
            case "RELAY_BASE": out.relayBase = value
            case "DEVICE_TOKEN", "GHOSTTY_DEVICE_TOKEN": out.deviceToken = value
            default: continue
            }
        }
        return out
    }

    /// Render relay.env content (LF endings, matching `enroll.formatRelayEnv`).
    static func format(relayBase: String, deviceToken: String) -> String {
        "RELAY_BASE=\(relayBase)\nDEVICE_TOKEN=\(deviceToken)\n"
    }

    /// The stored credential, or nil when the file is absent or unreadable.
    func load() -> Contents? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Self.parse(String(decoding: data, as: UTF8.self))
    }

    /// Write the credential atomically at 0600. The temp file is a sibling so
    /// the rename never crosses a filesystem, exactly like the agent's write.
    func save(relayBase: String, deviceToken: String) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let tmpPath = url.path + ".tmp"
        let data = Data(Self.format(relayBase: relayBase, deviceToken: deviceToken).utf8)
        try? fm.removeItem(atPath: tmpPath)
        guard fm.createFile(
            atPath: tmpPath, contents: data,
            attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(tmpPath, url.path) == 0 else {
            let err = errno
            try? fm.removeItem(atPath: tmpPath)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
    }

    /// Delete the credential (and any leftover `.tmp` sibling). A missing file
    /// is success — this is the local half of a revocation, and the revocation
    /// itself already happened on the relay.
    func delete() {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try? fm.removeItem(atPath: url.path + ".tmp")
    }
}

// MARK: - Device-authenticated relay client

/// The relay's DEVICE-authenticated endpoints — the ones whose bearer is a
/// machine's own credential rather than an account session token. Separate from
/// `RelayDirectoryClient` (account-scoped) precisely because the credential is
/// different: these keep working after the account session is revoked, which is
/// what lets a pending revocation be retried by a signed-out app.
struct RelayDeviceClient {
    /// The account a device credential is bound to (`GET /v1/agent/whoami`).
    struct Identity: Decodable, Equatable {
        let email: String
        let deviceID: String
        let name: String

        enum CodingKeys: String, CodingKey {
            case email
            case deviceID = "device_id"
            case name
        }
    }

    enum DeviceError: LocalizedError {
        case badBase(String)
        case http(Int)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .badBase(let s): return "The stored relay address “\(s)” isn't a valid URL."
            case .http(let code): return "The relay returned HTTP \(code)."
            case .badResponse: return "The relay returned a response that couldn't be parsed."
            }
        }
    }

    let base: URL
    var urlSession: URLSession = .shared

    /// Build a client for a `RELAY_BASE` string as relay.env spells it
    /// (`https://host/`, trailing slash optional).
    ///
    /// A `ws://`/`wss://` spelling is normalized to `http`/`https` rather than
    /// rejected: relay.env legitimately carries either — `relay_creds.baseMatches`
    /// strips all four schemes precisely because the agent's own ws base and
    /// the file's https base name the same relay — and a `wss` URL handed to
    /// `URLSession` fails every request with `unsupportedURL`, which would
    /// read as "the relay is down" forever.
    init(base: String, urlSession: URLSession = .shared) throws {
        var trimmed = base.trimmingCharacters(in: .whitespaces).trimmingSuffix("/")
        for (ws, http) in [("wss://", "https://"), ("ws://", "http://")]
        where trimmed.lowercased().hasPrefix(ws) {
            trimmed = http + trimmed.dropFirst(ws.count)
            break
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil
        else {
            throw DeviceError.badBase(base)
        }
        self.base = url
        self.urlSession = urlSession
    }

    /// `GET /v1/agent/whoami` — which account this machine is enrolled to.
    /// Returns nil for a 401: the credential is already dead, which is an
    /// answer, not an error. Throws only when the relay could not be reached
    /// or answered something unexpected.
    func whoami(deviceToken: String) async throws -> Identity? {
        var req = URLRequest(url: base.appendingPathComponent("v1/agent/whoami"))
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw DeviceError.badResponse }
        if http.statusCode == 401 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw DeviceError.http(http.statusCode)
        }
        guard let identity = try? JSONDecoder().decode(Identity.self, from: data) else {
            throw DeviceError.badResponse
        }
        return identity
    }

    /// `POST /v1/agent/deenroll` — revoke this machine's own credential and
    /// sever every live connection it holds. 204 (revoked now) and 401 (a
    /// prior revocation already landed) are both "revoked": the endpoint is
    /// idempotent from the caller's side, so a retry can't loop forever.
    func deenroll(deviceToken: String) async throws {
        var req = URLRequest(url: base.appendingPathComponent("v1/agent/deenroll"))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        let (_, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw DeviceError.badResponse }
        guard http.statusCode == 204 || http.statusCode == 401 else {
            throw DeviceError.http(http.statusCode)
        }
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var s = self
        while s.hasSuffix(suffix), s.count > suffix.count { s.removeLast(suffix.count) }
        return s
    }
}

// MARK: - Persisted state

/// A machine whose enrollment this app revoked at sign-out, remembered so the
/// same account signing back in gets its machine back. Holds NO secret — the
/// credential it describes is already dead on the relay.
struct SuspendedEnrollment: Codable, Equatable {
    /// The relay the machine was enrolled with (`RELAY_BASE`).
    var relayBase: String
    /// The device's display name, so the re-enrollment keeps its identity in
    /// the machine chooser rather than arriving as a stranger.
    var machineName: String
    /// The account that owned it. Only this account may restore it.
    var ownerEmail: String
}

/// Where suspended enrollments and pending revocations live between launches.
/// `UserDefaults` because neither holds a secret: the suspended record is
/// public metadata about a dead credential, and a pending revocation is a
/// single email — the credential the retry needs stays in `relay.env`, which is
/// where it already was.
struct MachineEnrollmentStore {
    static let suspendedKey = "GhosttySuspendedRelayEnrollment"
    static let pendingRevocationKey = "GhosttyPendingMachineRevocation"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .ghostty) {
        self.defaults = defaults
    }

    var suspended: SuspendedEnrollment? {
        get {
            guard let data = defaults.data(forKey: Self.suspendedKey) else { return nil }
            return try? JSONDecoder().decode(SuspendedEnrollment.self, from: data)
        }
        nonmutating set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Self.suspendedKey)
                return
            }
            defaults.set(data, forKey: Self.suspendedKey)
        }
    }

    /// The email of an account that signed out while its machine could not be
    /// revoked. Non-nil means "this machine is still enrolled and must not be".
    var pendingRevocationEmail: String? {
        get { defaults.string(forKey: Self.pendingRevocationKey) }
        nonmutating set {
            guard let newValue, !newValue.isEmpty else {
                defaults.removeObject(forKey: Self.pendingRevocationKey)
                return
            }
            defaults.set(newValue, forKey: Self.pendingRevocationKey)
        }
    }
}

// MARK: - The implementation

/// The real `MachineEnrollmentRevoking`: reads this machine's `relay.env`,
/// talks to the relay it names, and keeps the suspended/pending records.
///
/// Everything it depends on is injectable (`relay.env` path, defaults, relay
/// base, `URLSession`) so the whole policy — including the HTTP status handling
/// — is unit-testable without a network or a real credential.
@MainActor
final class LocalMachineEnrollment: MachineEnrollmentRevoking {
    static let shared = LocalMachineEnrollment()

    private let envFile: RelayEnvFile
    private let store: MachineEnrollmentStore
    /// The relay THIS APP talks to. Restore is refused when the suspended
    /// enrollment names a different one (see the type doc).
    private let appRelayBase: String
    private let urlSession: URLSession

    /// Tail of the serialized work queue, so a launch retry, a
    /// network-came-back retry, and a sign-in can't run the flow concurrently
    /// against one credential file. Every PUBLIC entry point queues behind it;
    /// the `…Core` methods are the un-queued bodies, so one flow calling
    /// another (restore completing a pending revocation) can never wait on
    /// itself.
    private var queue: Task<Void, Never>?
    private var observingNetwork = false

    init(
        envFile: RelayEnvFile = RelayEnvFile(),
        store: MachineEnrollmentStore = MachineEnrollmentStore(),
        appRelayBase: String = RelayDirectoryClient.defaultBase,
        urlSession: URLSession = .shared
    ) {
        self.envFile = envFile
        self.store = store
        self.appRelayBase = appRelayBase
        self.urlSession = urlSession
    }

    // MARK: Sign-out

    func revokeForSignOut(accountEmail: String) async -> MachineEnrollmentRevocation {
        await serialize { await self.revokeCore(accountEmail: accountEmail) }
    }

    /// What the local credential currently is, as far as the relay is
    /// concerned. Shared by the revocation and by the sign-in path, which has
    /// to answer the same question ("is this credential still ours and still
    /// alive?") before it decides anything.
    private enum CredentialProbe {
        /// No credential on this machine.
        case absent
        /// The relay rejected it (401): already revoked, by us or by someone
        /// removing the device from another client.
        case dead(client: RelayDeviceClient, credential: (relayBase: String, deviceToken: String))
        /// Alive and bound to `identity`.
        case alive(
            identity: RelayDeviceClient.Identity,
            client: RelayDeviceClient,
            credential: (relayBase: String, deviceToken: String))
        /// The relay refused the question or could not be reached. We know
        /// NOTHING about the credential — in particular, not that it is dead.
        case unknown(detail: String)
    }

    /// Ask the relay who this machine's credential belongs to.
    private func probeCredential() async -> CredentialProbe {
        guard let credential = envFile.load()?.credential else { return .absent }

        let client: RelayDeviceClient
        do {
            client = try RelayDeviceClient(base: credential.relayBase, urlSession: urlSession)
        } catch {
            // relay.env's RELAY_BASE is unusable as a URL. That does NOT make
            // the credential dead: the agent daemon dials the base it was
            // STARTED with (`--relay=<url>`) and only ever compares this field
            // (`relay_creds.baseMatches`), so the machine can be perfectly
            // reachable with an unparseable line in this file. Fall back to the
            // relay this app talks to — in practice the same one — rather than
            // deleting the only credential that can revoke the machine and
            // declaring it secured.
            guard let fallback = try? RelayDeviceClient(
                base: appRelayBase, urlSession: urlSession)
            else {
                return .unknown(detail: RelayDeviceClient.DeviceError
                    .badBase(credential.relayBase).localizedDescription)
            }
            Ghostty.logger.warning(
                "machine enrollment: unusable RELAY_BASE in relay.env; trying this app's relay instead")
            return await probe(with: fallback, credential: credential)
        }
        return await probe(with: client, credential: credential)
    }

    private func probe(
        with client: RelayDeviceClient,
        credential: (relayBase: String, deviceToken: String)
    ) async -> CredentialProbe {
        do {
            guard let identity = try await client.whoami(deviceToken: credential.deviceToken) else {
                return .dead(client: client, credential: credential)
            }
            return .alive(identity: identity, client: client, credential: credential)
        } catch {
            return .unknown(detail: error.localizedDescription)
        }
    }

    /// The revocation itself. Also used by the pending-revocation retry, which
    /// is why it takes the email rather than reading the account.
    private func revokeCore(accountEmail: String) async -> MachineEnrollmentRevocation {
        switch await probeCredential() {
        case .absent:
            // Nothing enrolled here. A suspended record is left alone: a
            // machine can be suspended precisely BECAUSE it has no credential.
            return .nothingEnrolled

        case .unknown(let detail):
            return .notRevoked(detail: detail)

        case .dead:
            // Already revoked server-side. Drop the dead file.
            //
            // The suspension record is deliberately NOT cleared here. This
            // branch is reached on the retry after a revocation whose RESPONSE
            // was lost — the POST landed, we reported `.notRevoked`, and the
            // retry now finds a 401 — and clearing it there would silently
            // discard the machine the previous attempt already recorded. When
            // nothing was recorded (the device was removed from another
            // client), there is nothing to keep and nothing to clear either.
            envFile.delete()
            return .alreadyRevoked

        case .alive(let identity, let client, let credential):
            guard identity.email.caseInsensitiveCompare(accountEmail) == .orderedSame else {
                // Enrolled to somebody else. Not ours to revoke — see the type doc.
                return .otherAccount(ownerEmail: identity.email)
            }

            // Record the suspension BEFORE the POST, not after. The relay is
            // about to delete the only record of this machine's name, and if
            // the response is lost we will never be able to learn it again
            // (the retry sees a bare 401). Writing it first costs nothing when
            // the revocation fails — a suspension with a live credential is
            // self-healing, see `restoreCore`.
            store.suspended = SuspendedEnrollment(
                relayBase: credential.relayBase,
                machineName: identity.name,
                ownerEmail: identity.email)

            do {
                try await client.deenroll(deviceToken: credential.deviceToken)
            } catch {
                return .notRevoked(detail: error.localizedDescription)
            }

            // Revoked server-side: the device row is gone and every live
            // control and bridged connection was severed. Drop the local
            // credential so a restart can't dial with it.
            envFile.delete()
            Ghostty.logger.warning(
                "machine enrollment: revoked this machine (device \(identity.deviceID, privacy: .public)) on sign-out")
            return .revoked(deviceID: identity.deviceID, machineName: identity.name)
        }
    }

    // MARK: Pending revocation

    func armPendingRevocation(accountEmail: String) {
        store.pendingRevocationEmail = accountEmail
        Ghostty.logger.warning(
            "machine enrollment: THIS MACHINE IS STILL ENROLLED — revocation deferred; will retry until it lands")
        observeNetworkIfNeeded()
    }

    func retryPendingRevocation() async {
        await serialize { await self.retryPendingCore() }
    }

    private func retryPendingCore() async {
        guard let email = store.pendingRevocationEmail else { return }
        let outcome = await revokeCore(accountEmail: email)
        switch outcome {
        case .notRevoked:
            // The machine is still enrolled. Stay armed.
            observeNetworkIfNeeded()
        case .revoked, .alreadyRevoked, .nothingEnrolled, .otherAccount:
            // Every one of these means the machine is not reachable under the
            // signed-out account any more.
            store.pendingRevocationEmail = nil
        }
    }

    /// The account whose machine revocation is still outstanding, if any.
    /// Non-nil means THIS MACHINE IS STILL ENROLLED under that account despite
    /// having been signed out of — the chooser says so rather than leaving the
    /// user to assume a sign-out they were warned about actually completed.
    var outstandingRevocationAccount: String? { store.pendingRevocationEmail }

    /// Arm the launch/reachability retries. Idempotent; safe to call whether or
    /// not a revocation is pending (it costs one defaults read when none is).
    func startPendingRevocationRetries() {
        guard store.pendingRevocationEmail != nil else { return }
        observeNetworkIfNeeded()
        enqueue { await self.retryPendingCore() }
    }

    private func observeNetworkIfNeeded() {
        guard !observingNetwork else { return }
        observingNetwork = true
        NetworkPathMonitor.shared.start()
        NotificationCenter.default.addObserver(
            forName: .ghosttyNetworkPathDidBecomeSatisfied,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.enqueue { await self.retryPendingCore() }
            }
        }
    }

    // MARK: Sign-in

    func restoreEnrollment(accountEmail: String, sessionToken: String) async {
        await serialize {
            await self.restoreCore(accountEmail: accountEmail, sessionToken: sessionToken)
        }
    }

    private func restoreCore(accountEmail: String, sessionToken: String) async {
        if let pending = store.pendingRevocationEmail {
            if pending.caseInsensitiveCompare(accountEmail) == .orderedSame {
                // The account that walked away came back to the same machine,
                // so the revocation it never landed is moot — PROVIDED the
                // credential is really still alive. It may not be: a
                // revocation whose response was lost is indistinguishable from
                // one that failed, and cancelling on the email alone would
                // leave a dead token in relay.env, a machine unenrolled, and
                // nothing left to notice it.
                switch await probeCredential() {
                case .alive(let identity, _, _)
                where identity.email.caseInsensitiveCompare(accountEmail) == .orderedSame:
                    // Still ours and still connected. Nothing to revoke.
                    store.pendingRevocationEmail = nil
                    store.suspended = nil
                    return
                case .dead:
                    // The revocation did land after all. Clear the dead
                    // credential and fall through to re-enroll below.
                    store.pendingRevocationEmail = nil
                    envFile.delete()
                case .absent:
                    store.pendingRevocationEmail = nil
                case .alive, .unknown:
                    // Somebody else's credential now, or we couldn't ask.
                    // Stay armed; the launch and network retries settle it.
                    return
                }
            } else {
                // A DIFFERENT account is signing in. The previous account's
                // machine must still go away before this one takes over the
                // host.
                await retryPendingCore()
            }
        }

        guard let suspended = store.suspended else { return }
        guard suspended.ownerEmail.caseInsensitiveCompare(accountEmail) == .orderedSame else {
            // Not this account's machine to resurrect.
            store.suspended = nil
            return
        }
        guard Self.sameRelay(suspended.relayBase, appRelayBase) else {
            Ghostty.logger.warning(
                "machine enrollment: suspended enrollment is on another relay; not restoring")
            store.suspended = nil
            return
        }
        // Never overwrite a credential that arrived while we were signed out
        // (a manual `ghoztty-agent --enroll`): the machine is already enrolled.
        if envFile.load()?.credential != nil {
            store.suspended = nil
            return
        }
        guard let base = URL(string: appRelayBase) else {
            store.suspended = nil
            return
        }

        let client = RelayDirectoryClient(base: base, token: sessionToken, urlSession: urlSession)
        do {
            let enrolled = try await client.enroll(name: suspended.machineName)
            try envFile.save(relayBase: suspended.relayBase, deviceToken: enrolled.token)
            store.suspended = nil
            Ghostty.logger.warning(
                "machine enrollment: re-enrolled this machine (device \(enrolled.id, privacy: .public)) on sign-in")
        } catch {
            // Leave the record in place: a later sign-in or launch retries. The
            // failure direction is safe — the machine simply stays unenrolled.
            Ghostty.logger.warning(
                "machine enrollment: re-enroll on sign-in failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Plumbing

    /// Whether two relay base strings name the same relay, compared the way
    /// `relay_creds.baseMatches` does it agent-side: scheme-insensitive,
    /// trailing slashes trimmed, host+port compared case-insensitively.
    nonisolated static func sameRelay(_ a: String, _ b: String) -> Bool {
        func hostPart(_ s: String) -> String {
            var v = s.trimmingCharacters(in: .whitespaces).lowercased()
            for prefix in ["wss://", "https://", "ws://", "http://"] where v.hasPrefix(prefix) {
                v.removeFirst(prefix.count)
                break
            }
            while v.hasSuffix("/") { v.removeLast() }
            return v
        }
        return !a.isEmpty && hostPart(a) == hostPart(b)
    }

    /// Queue `body` behind everything already queued and await its result.
    /// Public entry points only — a `…Core` body must never call this, or it
    /// would await the very task it is running inside (which is exactly how
    /// the launch-time retry deadlocked before this shape).
    private func serialize<T: Sendable>(
        _ body: @escaping @MainActor () async -> T
    ) async -> T {
        let previous = queue
        let work = Task { @MainActor () -> T in
            await previous?.value
            return await body()
        }
        queue = Task { @MainActor in _ = await work.value }
        return await work.value
    }

    /// Fire-and-forget variant for the launch and network-came-back retries,
    /// which have nobody to report to.
    private func enqueue(_ body: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            await body()
        }
    }
}
