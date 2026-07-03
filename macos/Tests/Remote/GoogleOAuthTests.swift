import Foundation
import Testing
@testable import Ghostty

/// Unit tests for the pure pieces of the WP-B2 Google sign-in flow
/// (`GoogleOAuth`): PKCE, token-response parsing, ID-token claims, and
/// expiry math. The loopback receiver and the code-exchange path against a
/// fake token endpoint are additionally exercised headlessly by the
/// standalone harness (see the WP-B2 notes in
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
}

struct GoogleOAuthTokenParsingTests {
    @Test func decodesGoogleTokenResponse() throws {
        let json = """
        {"access_token":"ya29.a0Af","expires_in":3599,"scope":"openid https://www.googleapis.com/auth/userinfo.email",
         "token_type":"Bearer","id_token":"eyJhbGciOi.header.sig","refresh_token":"1//0gRefresh"}
        """
        let resp = try JSONDecoder().decode(
            GoogleOAuth.TokenResponse.self, from: Data(json.utf8))
        #expect(resp.accessToken == "ya29.a0Af")
        #expect(resp.expiresIn == 3599)
        #expect(resp.idToken == "eyJhbGciOi.header.sig")
        #expect(resp.refreshToken == "1//0gRefresh")
        #expect(resp.tokenType == "Bearer")
    }

    @Test func refreshResponseWithoutRefreshTokenDecodes() throws {
        let json = #"{"access_token":"x","expires_in":3599,"id_token":"a.b.c","token_type":"Bearer"}"#
        let resp = try JSONDecoder().decode(
            GoogleOAuth.TokenResponse.self, from: Data(json.utf8))
        #expect(resp.refreshToken == nil)
        #expect(resp.idToken == "a.b.c")
    }

    @Test func parsesIDTokenClaims() throws {
        let idToken = Self.fakeJWT(claims: [
            "email": "dzearing@gmail.com",
            "email_verified": true,
            "exp": 1_900_000_000,
            "sub": "1234567890",
        ])
        let claims = try GoogleOAuth.parseIDTokenClaims(idToken)
        #expect(claims.email == "dzearing@gmail.com")
        #expect(claims.emailVerified == true)
        #expect(claims.exp == 1_900_000_000)
        #expect(claims.sub == "1234567890")
    }

    @Test func malformedIDTokenThrows() {
        #expect(throws: GoogleOAuth.ClaimsError.self) {
            _ = try GoogleOAuth.parseIDTokenClaims("not-a-jwt")
        }
        #expect(throws: GoogleOAuth.ClaimsError.self) {
            _ = try GoogleOAuth.parseIDTokenClaims("a.!!!.c")
        }
    }

    @Test func formEncodingEscapesAndSorts() {
        let encoded = GoogleOAuth.TokenClient.formEncode([
            "b": "1//x y+z&=",
            "a": "plain-value_.~",
        ])
        #expect(encoded == "a=plain-value_.~&b=1%2F%2Fx%20y%2Bz%26%3D")
    }

    @Test func authorizationURLCarriesPKCEAndScopes() throws {
        let url = GoogleOAuth.authorizationURL(
            endpoints: .google,
            clientID: "cid.apps.googleusercontent.com",
            redirectURI: "http://127.0.0.1:49152",
            state: "st4te",
            codeChallenge: "ch4llenge")
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.host == "accounts.google.com")
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] { query[item.name] = item.value }
        #expect(query["client_id"] == "cid.apps.googleusercontent.com")
        #expect(query["redirect_uri"] == "http://127.0.0.1:49152")
        #expect(query["response_type"] == "code")
        #expect(query["scope"] == "openid email")
        #expect(query["code_challenge"] == "ch4llenge")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "st4te")
    }

    /// An unsigned JWT with the given payload (signature is NOT verified by
    /// the client — the relay is the enforcement point).
    static func fakeJWT(claims: [String: Any]) -> String {
        func seg(_ obj: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: obj)
            return GoogleOAuth.PKCE.base64URLEncode(data)
        }
        return seg(["alg": "RS256", "typ": "JWT"]) + "." + seg(claims) + ".c2ln"
    }
}

struct GoogleOAuthExpiryTests {
    @Test func prefersJWTExpClaim() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let token = GoogleOAuthTokenParsingTests.fakeJWT(claims: ["exp": 1_003_600])
        // expires_in deliberately contradicts the claim; the claim wins.
        let cached = GoogleOAuth.CachedIDToken(token: token, expiresIn: 10, now: now)
        #expect(cached.expiresAt == Date(timeIntervalSince1970: 1_003_600))
        #expect(cached.isFresh(now: now))
    }

    @Test func fallsBackToExpiresIn() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cached = GoogleOAuth.CachedIDToken(token: "opaque", expiresIn: 3600, now: now)
        #expect(cached.expiresAt == now.addingTimeInterval(3600))
    }

    @Test func unknownExpiryIsImmediatelyStale() {
        let now = Date()
        let cached = GoogleOAuth.CachedIDToken(token: "opaque", expiresIn: nil, now: now)
        #expect(!cached.isFresh(now: now))
    }

    @Test func sixtySecondLeeway() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cached = GoogleOAuth.CachedIDToken(token: "opaque", expiresIn: 3600, now: now)
        #expect(cached.isFresh(now: now.addingTimeInterval(3600 - 61)))   // >60s left
        #expect(!cached.isFresh(now: now.addingTimeInterval(3600 - 60)))  // exactly 60s
        #expect(!cached.isFresh(now: now.addingTimeInterval(3600 - 5)))   // inside leeway
        #expect(!cached.isFresh(now: now.addingTimeInterval(3601)))       // expired
    }
}
