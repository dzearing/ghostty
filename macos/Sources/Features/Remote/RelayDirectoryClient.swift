import Foundation

/// Minimal HTTP client for the relay's account resource directory
/// (`/v1/client/devices` — list / rename / delete). See WP-C2 in
/// `docs/design/remote-relay-roadmap.md` and `relay/README.md` for the
/// endpoint shapes.
///
/// Auth: the bearer comes from the single token-resolution seam
/// (`RelayAccount.resolveToken()`) — the signed-in account's relay session
/// token (brokered OAuth). Use `current()` to build a client.
struct RelayDirectoryClient {
    /// The dev relay base URL used when `GHOSTTY_RELAY_BASE` is not set.
    static let defaultBase: String =
        ProcessInfo.processInfo.environment["GHOSTTY_RELAY_BASE"]
        ?? "https://ghoztty-relay-dz17575.westus2.cloudapp.azure.com"

    /// One device (account resource) as returned by the relay's list and
    /// rename endpoints: `{"id":..., "name":..., "hostname":..., "online":...,
    /// "created_at":...}`. `hostname` is the machine's OS-reported hostname —
    /// distinct from the display `name` (rename changes only the name) — and
    /// is omitted by the relay when unknown.
    struct Device: Decodable, Hashable {
        let id: String
        let name: String
        let hostname: String?
        let online: Bool
    }

    enum DirectoryError: LocalizedError {
        /// No client token configured — account features are unavailable.
        case noAccount
        /// The relay rejected the bearer token (HTTP 401).
        case unauthorized
        /// The device id is unknown or not owned by this account (HTTP 404).
        case notFound
        /// The account is already at its device limit (HTTP 409).
        case quotaExceeded
        /// Any other non-2xx status.
        case http(Int)
        /// The response body couldn't be parsed.
        case badResponse

        var errorDescription: String? {
            switch self {
            case .noAccount:
                return "No relay account is available. Sign in with Google."
            case .unauthorized:
                return "The relay rejected the session token (401). Sign in again."
            case .notFound:
                return "The relay doesn't know this device (404). It may already have been removed."
            case .quotaExceeded:
                return "This account is already at its machine limit — remove a machine and try again."
            case .http(let code):
                return "The relay returned an unexpected HTTP \(code)."
            case .badResponse:
                return "The relay returned a response that couldn't be parsed."
            }
        }
    }

    let base: URL
    let token: String
    /// Injectable for tests (a `URLProtocol`-stubbed session); production uses
    /// the shared session, exactly as before.
    var urlSession: URLSession = .shared

    /// Resolve the CURRENT directory client: base from `GHOSTTY_RELAY_BASE`
    /// (defaulting to the dev relay) and the CLIENT bearer from the
    /// token-resolution seam (`RelayAccount.resolveToken()` — the signed-in
    /// account's relay session token). Returns nil when no token is available —
    /// callers then skip account-list features entirely (hardcoded/TCP registry
    /// entries keep working).
    static func current() async -> RelayDirectoryClient? {
        guard let token = await RelayAccount.resolveToken(),
              let url = URL(string: defaultBase)
        else { return nil }
        return RelayDirectoryClient(base: url, token: token)
    }

    /// GET /v1/client/devices — the caller's devices with live online status.
    func listDevices() async throws -> [Device] {
        struct ListResponse: Decodable { let devices: [Device] }
        let data = try await perform(request("GET", path: "v1/client/devices"))
        guard let resp = try? JSONDecoder().decode(ListResponse.self, from: data) else {
            throw DirectoryError.badResponse
        }
        return resp.devices
    }

    /// PATCH /v1/client/devices/{id} — rename an owned device. Returns the
    /// updated device view.
    func rename(deviceID: String, to name: String) async throws -> Device {
        let body = try JSONEncoder().encode(["name": name])
        let data = try await perform(
            request("PATCH", path: "v1/client/devices/\(deviceID)", body: body))
        guard let dev = try? JSONDecoder().decode(Device.self, from: data) else {
            throw DirectoryError.badResponse
        }
        return dev
    }

    /// POST /v1/client/devices — enroll a NEW device owned by this account.
    /// The relay returns the raw device token EXACTLY ONCE (it stores only the
    /// hash), so the caller must persist it or lose it. Used to restore this
    /// machine's own enrollment after a sign-out revoked it
    /// (`LocalMachineEnrollment.restoreEnrollment`).
    func enroll(name: String) async throws -> Enrolled {
        let body = try JSONEncoder().encode(["name": name])
        let data = try await perform(request("POST", path: "v1/client/devices", body: body))
        guard let out = try? JSONDecoder().decode(Enrolled.self, from: data) else {
            throw DirectoryError.badResponse
        }
        return out
    }

    /// The one-time enrollment response: the new device's id/name plus its raw
    /// bearer token.
    struct Enrolled: Decodable, Equatable {
        let id: String
        let name: String
        let token: String
    }

    /// DELETE /v1/client/devices/{id} — remove an owned device and revoke its
    /// credential (204 on success).
    func delete(deviceID: String) async throws {
        _ = try await perform(request("DELETE", path: "v1/client/devices/\(deviceID)"))
    }

    // MARK: - Plumbing

    private func request(_ method: String, path: String, body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 10
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// Run the request and map status codes onto `DirectoryError`.
    private func perform(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw DirectoryError.badResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw DirectoryError.unauthorized
        case 404: throw DirectoryError.notFound
        case 409: throw DirectoryError.quotaExceeded
        default: throw DirectoryError.http(http.statusCode)
        }
    }
}
