import Foundation
import Testing
@testable import Ghostty

// MARK: - Test doubles

/// A `URLProtocol` that answers every request from a table keyed by
/// "<METHOD> <path>", so the real client code (status handling, headers,
/// decoding) is exercised with no network.
final class StubRelayProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: String = ""
        /// When set, the request fails with this error instead of replying —
        /// how "the relay could not be reached" is simulated.
        var failure: Error?
    }

    /// Keyed by "<METHOD> <path>". Guarded by `lock` because URLSession calls
    /// in from its own queue.
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    /// Every request seen, in order, as "<METHOD> <path>" plus its bearer.
    nonisolated(unsafe) private static var seen: [(key: String, bearer: String?, body: String)] = []
    nonisolated(unsafe) private static let lock = NSLock()

    static func set(_ key: String, _ reply: Reply) {
        lock.lock(); defer { lock.unlock() }
        replies[key] = reply
    }

    static var requests: [(key: String, bearer: String?, body: String)] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    static func count(of key: String) -> Int {
        requests.filter { $0.key == key }.count
    }

    static func bearer(for key: String) -> String? {
        requests.last { $0.key == key }?.bearer
    }

    static func body(for key: String) -> String? {
        requests.last { $0.key == key }?.body
    }

    /// A session wired to this protocol only.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubRelayProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let host = request.url?.host ?? ""
        let path = request.url?.path ?? ""
        // Keyed by HOST as well as path: swift-testing runs suites in
        // parallel and this protocol's tables are process-global, so each
        // fixture gets its own relay hostname and the traffic never mixes.
        let key = "\(method) \(host)\(path)"
        // URLProtocol strips httpBody into httpBodyStream for some sessions;
        // read whichever is present.
        var body = ""
        if let data = request.httpBody {
            body = String(decoding: data, as: UTF8.self)
        } else if let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = stream.read(&buf, maxLength: buf.count)
            stream.close()
            if n > 0 { body = String(decoding: buf[0..<n], as: UTF8.self) }
        }

        Self.lock.lock()
        Self.seen.append((key, request.value(forHTTPHeaderField: "Authorization"), body))
        let reply = Self.replies[key]
        Self.lock.unlock()

        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let resp = HTTPURLResponse(
            url: request.url!, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty {
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A fresh temp `relay.env` path and a `UserDefaults` suite per test, so
/// nothing touches the real machine's credential or preferences.
@MainActor
struct EnrollmentFixture {
    let envFile: RelayEnvFile
    let store: MachineEnrollmentStore
    let suiteName: String
    /// A hostname unique to this fixture (see `StubRelayProtocol.startLoading`).
    let host: String
    let relayBase: String

    init() {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        host = "r\(id).relay.test"
        relayBase = "https://r\(id).relay.test"
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghoztty-enrollment-\(id)")
        envFile = RelayEnvFile(url: dir.appendingPathComponent("relay.env"))
        suiteName = "ghoztty.tests.enrollment.\(id)"
        store = MachineEnrollmentStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    /// This fixture's key for a "<METHOD> <path>" pair.
    func key(_ method: String, _ path: String) -> String { "\(method) \(host)\(path)" }
    func count(_ method: String, _ path: String) -> Int {
        StubRelayProtocol.count(of: key(method, path))
    }
    func bearer(_ method: String, _ path: String) -> String? {
        StubRelayProtocol.bearer(for: key(method, path))
    }
    func body(_ method: String, _ path: String) -> String? {
        StubRelayProtocol.body(for: key(method, path))
    }
    /// Requests this fixture's relay saw, in order.
    var requests: [(key: String, bearer: String?, body: String)] {
        StubRelayProtocol.requests.filter { $0.key.contains(host) }
    }

    func makeSubject(appRelayBase: String? = nil) -> LocalMachineEnrollment {
        LocalMachineEnrollment(
            envFile: envFile,
            store: store,
            appRelayBase: appRelayBase ?? relayBase,
            urlSession: StubRelayProtocol.session())
    }

    /// Seed a local enrollment credential, as `ghoztty-agent --enroll` would.
    func seedCredential(token: String = "dev-token", base: String? = nil) throws {
        try envFile.save(relayBase: base ?? relayBase, deviceToken: token)
    }

    func whoami(email: String, deviceID: String = "dev-1", name: String = "thisbox") {
        StubRelayProtocol.set(key("GET", "/v1/agent/whoami"), .init(
            status: 200,
            body: #"{"email":"\#(email)","device_id":"\#(deviceID)","name":"\#(name)"}"#))
    }

    func reply(_ method: String, _ path: String, _ reply: StubRelayProtocol.Reply) {
        StubRelayProtocol.set(key(method, path), reply)
    }

    func teardown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: envFile.url.deletingLastPathComponent())
    }
}

// MARK: - relay.env parity with the agent

struct RelayEnvFileTests {
    @Test func parsesTheAgentsFormat() {
        let c = RelayEnvFile.parse("RELAY_BASE=https://relay.test\nDEVICE_TOKEN=abc123\n")
        #expect(c.relayBase == "https://relay.test")
        #expect(c.deviceToken == "abc123")
    }

    /// CRLF (the Windows installer writes it), comments, blank lines, padding,
    /// the `GHOSTTY_DEVICE_TOKEN` alias, and later-line-wins — all exactly as
    /// `enroll.parseRelayEnv` handles them.
    @Test func matchesTheAgentsParsingRules() {
        let text = [
            "# a comment",
            "",
            "  RELAY_BASE = https://first.test  ",
            "RELAY_BASE=https://second.test\r",
            "GHOSTTY_DEVICE_TOKEN=aliased\r",
            "DEVICE_TOKEN=final",
            "UNRELATED=ignored",
            "novalue=",
            "no-equals-sign",
        ].joined(separator: "\n")
        let c = RelayEnvFile.parse(text)
        #expect(c.relayBase == "https://second.test")
        #expect(c.deviceToken == "final")
    }

    @Test func emptyValuesNeverProduceACredential() {
        #expect(RelayEnvFile.parse("RELAY_BASE=\nDEVICE_TOKEN=\n").credential == nil)
        #expect(RelayEnvFile.parse("RELAY_BASE=https://x\n").credential == nil)
        #expect(RelayEnvFile.parse("").credential == nil)
    }

    @Test func formatRoundTrips() {
        let text = RelayEnvFile.format(relayBase: "https://relay.test", deviceToken: "tok")
        #expect(text == "RELAY_BASE=https://relay.test\nDEVICE_TOKEN=tok\n")
        let c = RelayEnvFile.parse(text)
        #expect(c.credential?.relayBase == "https://relay.test")
        #expect(c.credential?.deviceToken == "tok")
    }

    /// The file holds a bearer credential: it must land 0600, and the write
    /// must be atomic (no `.tmp` sibling left behind).
    @Test func savesOwnerOnlyAndLeavesNoTemp() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghoztty-relayenv-\(UUID().uuidString)")
        let file = RelayEnvFile(url: dir.appendingPathComponent("relay.env"))
        defer { try? FileManager.default.removeItem(at: dir) }

        try file.save(relayBase: "https://relay.test", deviceToken: "tok")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!FileManager.default.fileExists(atPath: file.url.path + ".tmp"))
        #expect(file.load()?.credential?.deviceToken == "tok")

        // Overwriting an existing credential works (the re-enroll path).
        try file.save(relayBase: "https://relay.test", deviceToken: "tok2")
        #expect(file.load()?.credential?.deviceToken == "tok2")

        file.delete()
        #expect(file.load() == nil)
        // Deleting again is success, not a crash.
        file.delete()
    }

    @Test func sameRelayComparesHostsTheWayTheAgentDoes() {
        #expect(LocalMachineEnrollment.sameRelay("https://relay.test/", "wss://relay.test"))
        #expect(LocalMachineEnrollment.sameRelay("https://Relay.Test", "https://relay.test"))
        #expect(!LocalMachineEnrollment.sameRelay("https://relay.test", "https://other.test"))
        #expect(!LocalMachineEnrollment.sameRelay("https://relay.test:8443", "https://relay.test"))
        #expect(!LocalMachineEnrollment.sameRelay("", "https://relay.test"))
    }
}

// MARK: - The revocation policy

@MainActor
struct MachineEnrollmentRevocationTests {
    /// The bug this whole change exists to close, at the client boundary: a
    /// machine enrolled to the account that is signing out gets a REAL
    /// revocation (`POST /v1/agent/deenroll` with the machine's own
    /// credential), and the local credential is dropped so a restart can't dial
    /// with it.
    @Test func signOutRevokesThisMachine() async throws {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        try fx.seedCredential(token: "device-tok")
        fx.whoami(email: "owner@example.com", deviceID: "dev-9", name: "thisbox")
        fx.reply("POST", "/v1/agent/deenroll", .init(status: 204))

        let outcome = await fx.makeSubject().revokeForSignOut(accountEmail: "owner@example.com")

        #expect(outcome == .revoked(deviceID: "dev-9", machineName: "thisbox"))
        #expect(outcome.isSecured)
        // It authenticated as the MACHINE, not as the account.
        #expect(fx.bearer("POST", "/v1/agent/deenroll") == "Bearer device-tok")
        // The local credential is gone.
        #expect(fx.envFile.load()?.credential == nil)
        // ...and the machine is remembered so the same account can get it back.
        #expect(fx.store.suspended == SuspendedEnrollment(
            relayBase: fx.relayBase, machineName: "thisbox",
            ownerEmail: "owner@example.com"))
    }

    /// Email comparison is case-insensitive: Google hands back mixed case and a
    /// machine must not survive sign-out over a capital letter.
    @Test func ownerMatchIsCaseInsensitive() async throws {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        try fx.seedCredential()
        fx.whoami(email: "Owner@Example.com")
        fx.reply("POST", "/v1/agent/deenroll", .init(status: 204))

        let outcome = await fx.makeSubject().revokeForSignOut(accountEmail: "owner@example.COM")
        if case .revoked = outcome {} else { Issue.record("expected .revoked, got \(outcome)") }
    }

    /// A Mac used only as a client has nothing to revoke, and sign-out is
    /// unchanged for it — no requests at all.
    @Test func noLocalEnrollmentIsANoOp() async {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }

        let outcome = await fx.makeSubject().revokeForSignOut(accountEmail: "owner@example.com")
        #expect(outcome == .nothingEnrolled)
        #expect(fx.requests.isEmpty)
    }

    /// A machine enrolled by SOMEBODY ELSE is left completely alone: the app is
    /// a guest on this host and the account walking away isn't the one that
    /// enrolled it.
    @Test func anotherAccountsMachineIsUntouched() async throws {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        try fx.seedCredential()
        fx.whoami(email: "someone@else.com")

        let outcome = await fx.makeSubject().revokeForSignOut(accountEmail: "owner@example.com")

        #expect(outcome == .otherAccount(ownerEmail: "someone@else.com"))
        #expect(fx.count("POST", "/v1/agent/deenroll") == 0)
        // The other account's credential survives untouched.
        #expect(fx.envFile.load()?.credential?.deviceToken == "dev-token")
        #expect(fx.store.suspended == nil)
    }

    /// A credential the relay already rejects (a prior revocation, or the
    /// device removed from another client) is not an error — it is the machine
    /// already being unreachable. The dead file is cleaned up.
    @Test func alreadyDeadCredentialIsClearedNotRetried() async throws {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        try fx.seedCredential()
        fx.reply("GET", "/v1/agent/whoami", .init(status: 401))

        let outcome = await fx.makeSubject().revokeForSignOut(accountEmail: "owner@example.com")

        #expect(outcome == .alreadyRevoked)
        #expect(outcome.isSecured)
        #expect(fx.envFile.load()?.credential == nil)
    }

    /// THE failure mode that must never be silent: the relay is unreachable, so
    /// the machine is still enrolled. The outcome says so, the credential is
    /// deliberately LEFT in place (it is the retry's own record), and nothing
    /// was suspended.
    @Test func unreachableRelayReportsTheMachineStillEnrolled() async throws {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        try fx.seedCredential()
        fx.reply("GET", "/v1/agent/whoami", .init(
            status: 0, failure: URLError(.notConnectedToInternet)))

        let outcome = await fx.makeSubject().revokeForSignOut(accountEmail: "owner@example.com")

        guard case .unreachable = outcome else {
            Issue.record("expected .unreachable, got \(outcome)")
            return
        }
        #expect(!outcome.isSecured)
        #expect(fx.envFile.load()?.credential?.deviceToken == "dev-token")
        #expect(fx.store.suspended == nil)
    }

    /// A de-enroll that itself fails (whoami succeeded, the POST didn't) is
    /// equally not silent — the machine is still enrolled.
    @Test func failedDeenrollIsUnreachableNotSuccess() async throws {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        try fx.seedCredential()
        fx.whoami(email: "owner@example.com")
        fx.reply("POST", "/v1/agent/deenroll", .init(status: 500))

        let outcome = await fx.makeSubject().revokeForSignOut(accountEmail: "owner@example.com")

        guard case .unreachable = outcome else {
            Issue.record("expected .unreachable, got \(outcome)")
            return
        }
        #expect(fx.envFile.load()?.credential?.deviceToken == "dev-token")
    }
}

// MARK: - Pending revocation (the offline hole, closed)

@MainActor
struct PendingRevocationTests {
    @Test func armedRevocationRetriesUntilItLands() async throws {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        try fx.seedCredential(token: "device-tok")
        let subject = fx.makeSubject()

        // Signed out while offline.
        fx.reply("GET", "/v1/agent/whoami", .init(
            status: 0, failure: URLError(.notConnectedToInternet)))
        subject.armPendingRevocation(accountEmail: "owner@example.com")
        #expect(fx.store.pendingRevocationEmail == "owner@example.com")

        // A retry that still can't reach the relay stays armed.
        await subject.retryPendingRevocation()
        #expect(fx.store.pendingRevocationEmail == "owner@example.com")
        // The credential stays put — it IS the retry's record, and the machine
        // genuinely is still enrolled until the relay says otherwise.
        #expect(fx.envFile.load()?.credential?.deviceToken == "device-tok")

        // Network comes back: the retry revokes for real and disarms.
        fx.whoami(email: "owner@example.com", deviceID: "dev-3")
        fx.reply("POST", "/v1/agent/deenroll", .init(status: 204))
        await subject.retryPendingRevocation()

        #expect(fx.store.pendingRevocationEmail == nil)
        #expect(fx.envFile.load()?.credential == nil)
        #expect(fx.bearer("POST", "/v1/agent/deenroll") == "Bearer device-tok")
    }

    /// The retry uses the MACHINE credential, so it works long after the
    /// account session it was signed out of is gone. Nothing here needs a
    /// session token.
    @Test func retryNeedsNoAccountSession() async throws {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        try fx.seedCredential(token: "device-tok")
        fx.store.pendingRevocationEmail = "owner@example.com"
        fx.whoami(email: "owner@example.com")
        fx.reply("POST", "/v1/agent/deenroll", .init(status: 204))

        await fx.makeSubject().retryPendingRevocation()

        #expect(fx.store.pendingRevocationEmail == nil)
        for request in fx.requests {
            #expect(request.bearer == "Bearer device-tok")
        }
    }

    @Test func nothingArmedIsANoOp() async {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        await fx.makeSubject().retryPendingRevocation()
        #expect(fx.requests.isEmpty)
    }

    /// The LAUNCH path, driven exactly as `AppDelegate` drives it: a
    /// fire-and-forget kick that must actually revoke.
    ///
    /// This is the shape that deadlocked in a real launch — the queued body
    /// awaited the very task it was running inside — while every plain
    /// `await`-style test passed, so it is tested on its own. The follow-up
    /// `retryPendingRevocation()` queues BEHIND the launch kick, so it returns
    /// only once that work has finished: deterministic, no wall-clock polling,
    /// and a re-introduced deadlock stalls here instead of racing.
    @Test(.timeLimit(.minutes(1)))
    func launchRetryActuallyRunsAndRevokes() async throws {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        try fx.seedCredential(token: "device-tok")
        fx.store.pendingRevocationEmail = "owner@example.com"
        fx.whoami(email: "owner@example.com", deviceID: "dev-7")
        fx.reply("POST", "/v1/agent/deenroll", .init(status: 204))
        let subject = fx.makeSubject()

        subject.startPendingRevocationRetries()
        await subject.retryPendingRevocation()

        #expect(fx.store.pendingRevocationEmail == nil)
        // Exactly one revocation: the launch kick did it, and the follow-up
        // found nothing left to revoke.
        #expect(fx.count("POST", "/v1/agent/deenroll") == 1)
        #expect(fx.envFile.load()?.credential == nil)
    }

    /// Overlapping public calls serialize instead of deadlocking or racing on
    /// one credential file.
    @Test(.timeLimit(.minutes(1)))
    func overlappingCallsSerialize() async throws {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        try fx.seedCredential(token: "device-tok")
        fx.store.pendingRevocationEmail = "owner@example.com"
        fx.whoami(email: "owner@example.com")
        fx.reply("POST", "/v1/agent/deenroll", .init(status: 204))
        let subject = fx.makeSubject()

        subject.startPendingRevocationRetries()
        await subject.retryPendingRevocation()
        _ = await subject.revokeForSignOut(accountEmail: "owner@example.com")

        #expect(fx.store.pendingRevocationEmail == nil)
        // The first pass revoked; the rest found nothing left to revoke.
        #expect(fx.count("POST", "/v1/agent/deenroll") == 1)
    }
}

// MARK: - Restore on sign-in

@MainActor
struct MachineEnrollmentRestoreTests {
    /// The symmetric half: the same account signing back in gets its machine
    /// back under a FRESH credential, written where a running agent's watcher
    /// will find it.
    @Test func sameAccountSignInReEnrollsThisMachine() async {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        fx.store.suspended = SuspendedEnrollment(
            relayBase: fx.relayBase, machineName: "thisbox", ownerEmail: "owner@example.com")
        fx.reply("POST", "/v1/client/devices", .init(
            status: 201, body: #"{"id":"dev-new","name":"thisbox","token":"fresh-tok"}"#))

        await fx.makeSubject().restoreForSignIn(
            accountEmail: "owner@example.com", sessionToken: "session-tok")

        #expect(fx.store.suspended == nil)
        let credential = fx.envFile.load()?.credential
        #expect(credential?.deviceToken == "fresh-tok")
        #expect(credential?.relayBase == fx.relayBase)
        // Enrolling is an ACCOUNT call, so it carries the session token, and it
        // keeps the machine's name rather than arriving as a stranger.
        #expect(fx.bearer("POST", "/v1/client/devices") == "Bearer session-tok")
        #expect(fx.body("POST", "/v1/client/devices")?.contains("thisbox") == true)
    }

    /// A DIFFERENT account signing in never inherits the machine.
    @Test func otherAccountSignInDoesNotInheritTheMachine() async {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        fx.store.suspended = SuspendedEnrollment(
            relayBase: fx.relayBase, machineName: "thisbox", ownerEmail: "owner@example.com")

        await fx.makeSubject().restoreForSignIn(
            accountEmail: "someone@else.com", sessionToken: "session-tok")

        #expect(fx.count("POST", "/v1/client/devices") == 0)
        #expect(fx.envFile.load()?.credential == nil)
        #expect(fx.store.suspended == nil)
    }

    /// A session on relay A cannot mint a device on relay B, and silently
    /// enrolling the machine somewhere new is the opposite of what sign-out
    /// promised — so a cross-relay record is dropped, not restored.
    @Test func suspendedEnrollmentOnAnotherRelayIsNotRestored() async {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        fx.store.suspended = SuspendedEnrollment(
            relayBase: "https://other-relay.test", machineName: "thisbox",
            ownerEmail: "owner@example.com")

        await fx.makeSubject().restoreForSignIn(
            accountEmail: "owner@example.com", sessionToken: "session-tok")

        #expect(fx.count("POST", "/v1/client/devices") == 0)
        #expect(fx.envFile.load()?.credential == nil)
        #expect(fx.store.suspended == nil)
    }

    /// A credential that arrived while signed out (a manual
    /// `ghoztty-agent --enroll`) is never clobbered — the machine is already
    /// enrolled and a second row would orphan the first.
    @Test func doesNotOverwriteACredentialEnrolledMeanwhile() async throws {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        try fx.seedCredential(token: "manually-enrolled")
        fx.store.suspended = SuspendedEnrollment(
            relayBase: fx.relayBase, machineName: "thisbox", ownerEmail: "owner@example.com")

        await fx.makeSubject().restoreForSignIn(
            accountEmail: "owner@example.com", sessionToken: "session-tok")

        #expect(fx.count("POST", "/v1/client/devices") == 0)
        #expect(fx.envFile.load()?.credential?.deviceToken == "manually-enrolled")
        #expect(fx.store.suspended == nil)
    }

    /// A failed re-enroll leaves the record in place for a later attempt, and
    /// fails in the SAFE direction: the machine stays unenrolled.
    @Test func failedReEnrollKeepsTheRecordAndEnrollsNothing() async {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        fx.store.suspended = SuspendedEnrollment(
            relayBase: fx.relayBase, machineName: "thisbox", ownerEmail: "owner@example.com")
        fx.reply("POST", "/v1/client/devices", .init(status: 409))

        await fx.makeSubject().restoreForSignIn(
            accountEmail: "owner@example.com", sessionToken: "session-tok")

        #expect(fx.envFile.load()?.credential == nil)
        #expect(fx.store.suspended != nil)
    }

    /// Signing back in on a machine whose revocation never landed CANCELS it:
    /// the account that walked away came back to the same machine, and the
    /// credential it left behind never left this Mac.
    @Test func signingBackInCancelsAPendingRevocation() async throws {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        try fx.seedCredential(token: "device-tok")
        fx.store.pendingRevocationEmail = "owner@example.com"

        await fx.makeSubject().restoreForSignIn(
            accountEmail: "owner@example.com", sessionToken: "session-tok")

        #expect(fx.store.pendingRevocationEmail == nil)
        #expect(fx.envFile.load()?.credential?.deviceToken == "device-tok")
        #expect(fx.requests.isEmpty)
    }

    /// ...but a DIFFERENT account signing in must not take over a host whose
    /// previous account is still reachable on it: the revocation is completed
    /// first.
    @Test func otherAccountSignInCompletesThePendingRevocation() async throws {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        try fx.seedCredential(token: "device-tok")
        fx.store.pendingRevocationEmail = "owner@example.com"
        fx.whoami(email: "owner@example.com")
        fx.reply("POST", "/v1/agent/deenroll", .init(status: 204))

        await fx.makeSubject().restoreForSignIn(
            accountEmail: "someone@else.com", sessionToken: "session-tok")

        #expect(fx.count("POST", "/v1/agent/deenroll") == 1)
        #expect(fx.store.pendingRevocationEmail == nil)
        #expect(fx.envFile.load()?.credential == nil)
    }
}
