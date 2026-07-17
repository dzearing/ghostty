import Foundation
import Testing
@testable import Ghostty

/// Unit tests for the pure pieces of the relay-brokered Google sign-in flow
/// (`GoogleOAuth`): PKCE, the authorization URL, base64url, and decoding the
/// relay's session response. The loopback receiver and the code→session
/// exchange against a fake relay endpoint are additionally exercised headlessly
/// by the standalone harness (see the WP-B2 notes in
/// `docs/design/remote-relay-roadmap.md`) because running this hosted test
/// target launches the app.
struct GoogleOAuthPKCETests {
    /// RFC 7636 Appendix B reference vector.
    @Test func challengeMatchesRFCVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(GoogleOAuth.PKCE.challenge(for: verifier)
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifierShapeAndUniqueness() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let a = GoogleOAuth.PKCE.generateVerifier()
        let b = GoogleOAuth.PKCE.generateVerifier()
        #expect(a != b)
        #expect(a.count == 43) // 32 bytes, base64url, unpadded
        #expect(a.allSatisfy { allowed.contains($0) })
    }

    @Test func base64URLRoundTrip() {
        let data = Data([0xfb, 0xef, 0xff, 0x00, 0x01, 0x3e])
        let encoded = GoogleOAuth.PKCE.base64URLEncode(data)
        #expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="))
        #expect(GoogleOAuth.PKCE.base64URLDecode(encoded) == data)
    }

    @Test func authorizationURLCarriesPKCEAndScopes() throws {
        let url = GoogleOAuth.authorizationURL(
            endpoints: .relay(base: URL(string: "http://127.0.0.1:8080")!),
            clientID: "cid.apps.googleusercontent.com",
            redirectURI: "http://127.0.0.1:49152",
            state: "st4te",
            codeChallenge: "ch4llenge")
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        // The browser leg still goes to Google's authorization endpoint.
        #expect(comps.host == "accounts.google.com")
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] { query[item.name] = item.value }
        #expect(query["client_id"] == "cid.apps.googleusercontent.com")
        #expect(query["redirect_uri"] == "http://127.0.0.1:49152")
        #expect(query["response_type"] == "code")
        #expect(query["scope"] == "openid email profile")
        #expect(query["code_challenge"] == "ch4llenge")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "st4te")
        #expect(query["access_type"] == "offline")
        #expect(query["prompt"] == "consent")
    }
}

struct RelaySessionResponseTests {
    @Test func decodesRelaySessionResponse() throws {
        let json = #"""
        {"session_token":"sess_abc","expiry":1900000000,"email":"dzearing@gmail.com",
         "picture":"https://lh3.googleusercontent.com/a/ACg8ocK=s96-c"}
        """#
        let r = try JSONDecoder().decode(
            GoogleOAuth.RelaySessionClient.SessionResponse.self, from: Data(json.utf8))
        #expect(r.sessionToken == "sess_abc")
        #expect(r.email == "dzearing@gmail.com")
        #expect(r.picture == "https://lh3.googleusercontent.com/a/ACg8ocK=s96-c")
        #expect(r.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
    }

    /// A session response without a picture (session minted before the
    /// `profile` scope, or a relay that omits it) still decodes; the UI falls
    /// back to a monogram.
    @Test func decodesWithoutPicture() throws {
        let json = #"{"session_token":"s","expiry":1900000000,"email":"a@b.com"}"#
        let r = try JSONDecoder().decode(
            GoogleOAuth.RelaySessionClient.SessionResponse.self, from: Data(json.utf8))
        #expect(r.picture == nil)
        #expect(r.sessionToken == "s")
    }

    /// The relay endpoints for a base URL are built with the expected paths.
    @Test func relayEndpointsBuildExpectedPaths() {
        let e = GoogleOAuth.Endpoints.relay(base: URL(string: "https://relay.example.com")!)
        #expect(e.exchange.absoluteString == "https://relay.example.com/oauth/exchange")
        #expect(e.renew.absoluteString == "https://relay.example.com/oauth/renew")
        #expect(e.signout.absoluteString == "https://relay.example.com/oauth/signout")
    }
}
