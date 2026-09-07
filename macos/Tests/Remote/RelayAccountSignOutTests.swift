import Foundation
import Testing
@testable import Ghostty

/// In-memory `RelayAccountStorage`, so sign-out can be driven without touching
/// the real Keychain (which prompts on every rebuild of an ad-hoc-signed debug
/// build — see `RelayAccountKeychain.isDisabled`).
final class FakeAccountStorage: RelayAccountStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RelayAccountKeychain.Stored?
    private(set) var deleteCount = 0

    init(_ stored: RelayAccountKeychain.Stored?) {
        self.stored = stored
    }

    func load() -> RelayAccountKeychain.Stored? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func save(_ value: RelayAccountKeychain.Stored) throws {
        lock.lock(); defer { lock.unlock() }
        stored = value
    }

    func delete() {
        lock.lock(); defer { lock.unlock() }
        stored = nil
        deleteCount += 1
    }
}

/// Records what `RelayAccount.signOut` asked of the machine enrollment and
/// replays a scripted outcome.
@MainActor
final class SpyMachineEnrollment: MachineEnrollmentRevoking {
    var outcome: MachineEnrollmentRevocation = .nothingEnrolled
    private(set) var revokedFor: [String] = []
    private(set) var armedFor: [String] = []
    private(set) var restoredFor: [(email: String, token: String)] = []
    private(set) var retryCount = 0

    func revokeForSignOut(accountEmail: String) async -> MachineEnrollmentRevocation {
        revokedFor.append(accountEmail)
        return outcome
    }

    func armPendingRevocation(accountEmail: String) {
        armedFor.append(accountEmail)
    }

    func retryPendingRevocation() async {
        retryCount += 1
    }

    func restoreEnrollment(accountEmail: String, sessionToken: String) async {
        restoredFor.append((accountEmail, sessionToken))
    }
}

@MainActor
struct RelayAccountSignOutTests {
    private func makeAccount(
        _ enrollment: SpyMachineEnrollment,
        storage: FakeAccountStorage
    ) -> RelayAccount {
        RelayAccount(
            clientID: "test-client-id",
            // A loopback base that is never actually dialed in these tests
            // except by /oauth/signout, whose failure is deliberately not fatal.
            endpoints: .relay(base: URL(string: "http://127.0.0.1:1")!),
            keychain: storage,
            openURL: { _ in false },
            enrollment: enrollment)
    }

    private var signedInSession: RelayAccountKeychain.Stored {
        .init(
            sessionToken: "session-tok",
            expiry: Date().addingTimeInterval(3600).timeIntervalSince1970,
            email: "owner@example.com",
            picture: nil)
    }

    /// Sign-out revokes THIS machine's enrollment before it tears anything
    /// down, and passes the signed-in account's email so the enrollment can
    /// tell "ours" from "somebody else's".
    @Test func signOutRevokesTheMachineFirst() async throws {
        let spy = SpyMachineEnrollment()
        spy.outcome = .revoked(deviceID: "dev-1", machineName: "thisbox")
        let storage = FakeAccountStorage(signedInSession)
        let account = makeAccount(spy, storage: storage)
        await account.waitForInitialLoad()
        #expect(account.isSignedIn)

        let outcome = try await account.signOut()

        #expect(outcome == .revoked(deviceID: "dev-1", machineName: "thisbox"))
        #expect(spy.revokedFor == ["owner@example.com"])
        #expect(spy.armedFor.isEmpty)
        #expect(!account.isSignedIn)
        #expect(storage.deleteCount == 1)
    }

    /// THE regression test for the reported bug's failure mode: when the
    /// machine could not be revoked, sign-out FAILS and the account stays
    /// signed in. Reporting "signed out" while every other client on the
    /// account can still reach this machine is precisely the lie being fixed.
    @Test func signOutRefusesWhenTheMachineCannotBeRevoked() async {
        let spy = SpyMachineEnrollment()
        spy.outcome = .notRevoked(detail: "offline")
        let storage = FakeAccountStorage(signedInSession)
        let account = makeAccount(spy, storage: storage)
        await account.waitForInitialLoad()

        await #expect(throws: RelayAccount.AccountError.self) {
            try await account.signOut()
        }
        #expect(account.isSignedIn)
        #expect(account.email == "owner@example.com")
        #expect(storage.deleteCount == 0)
        #expect(storage.load() != nil)
        // Nothing was armed: the user has not chosen to sign out anyway yet.
        #expect(spy.armedFor.isEmpty)
    }

    /// Signing out anyway is allowed, but it is never silent: the revocation is
    /// armed so it is retried at every launch and network-came-back until the
    /// relay confirms it.
    ///
    /// It also does NOT attempt the revocation a second time. The user just
    /// waited out its failure and said go ahead; repeating it makes them wait
    /// out the same timeouts again.
    @Test func deferredSignOutArmsAPendingRevocationWithoutRetryingInline() async throws {
        let spy = SpyMachineEnrollment()
        spy.outcome = .notRevoked(detail: "offline")
        let storage = FakeAccountStorage(signedInSession)
        let account = makeAccount(spy, storage: storage)
        await account.waitForInitialLoad()

        let outcome = try await account.signOut(.deferringMachineRevocation)

        guard case .notRevoked = outcome else {
            Issue.record("expected .notRevoked, got \(outcome)")
            return
        }
        #expect(spy.armedFor == ["owner@example.com"])
        #expect(spy.revokedFor.isEmpty)
        #expect(!account.isSignedIn)
        #expect(storage.deleteCount == 1)
    }

    /// A machine enrolled to a different account doesn't block sign-out — it
    /// isn't this account's to revoke, and nothing is left reachable BY this
    /// account.
    @Test func anotherAccountsMachineDoesNotBlockSignOut() async throws {
        let spy = SpyMachineEnrollment()
        spy.outcome = .otherAccount(ownerEmail: "someone@else.com")
        let account = makeAccount(spy, storage: FakeAccountStorage(signedInSession))
        await account.waitForInitialLoad()

        let outcome = try await account.signOut()

        #expect(outcome == .otherAccount(ownerEmail: "someone@else.com"))
        #expect(!account.isSignedIn)
        #expect(spy.armedFor.isEmpty)
    }

    /// Signing out when already signed out asks the enrollment nothing (there
    /// is no account to attribute a machine to) and still succeeds.
    @Test func signOutWhileSignedOutIsHarmless() async throws {
        let spy = SpyMachineEnrollment()
        let account = makeAccount(spy, storage: FakeAccountStorage(nil))
        await account.waitForInitialLoad()

        let outcome = try await account.signOut()

        #expect(outcome == .nothingEnrolled)
        #expect(spy.revokedFor.isEmpty)
        #expect(!account.isSignedIn)
    }
}
