/**
 * Local-display-only JWT payload decode. The relay does the real
 * verification; the portal only peeks at the payload to show who is signed
 * in and to know roughly when the token expires. Never used for authz.
 */

export interface TokenClaims {
  email?: string;
  sub?: string;
  name?: string;
  picture?: string; // Google profile photo URL (header avatar)
  exp?: number; // seconds since epoch
}

export function decodeJwtClaims(token: string): TokenClaims | null {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const json = decodeURIComponent(
      atob(b64)
        .split("")
        .map((c) => "%" + c.charCodeAt(0).toString(16).padStart(2, "0"))
        .join(""),
    );
    return JSON.parse(json) as TokenClaims;
  } catch {
    return null;
  }
}
