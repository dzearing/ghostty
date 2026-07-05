/**
 * Auth state machine + token custody.
 *
 * The bearer token (a Google ID token, or the relay's DEV_CLIENT_TOKEN in
 * dev) lives in memory plus sessionStorage — NOT localStorage. Rationale:
 * memory-only forced a Google round-trip on every refresh, and Chrome's
 * FedCM auto-reauthn cooldown degrades that to a visible chip per F5 (user
 * hit exactly this). sessionStorage survives refresh in the same tab,
 * evaporates when the tab closes, and holds a token that self-expires in
 * ~1h; an XSS on this origin could equally hook the in-memory path, so the
 * marginal exposure is the persistence window of an already-short-lived
 * token. localStorage (indefinite, cross-tab) remains off the table.
 * On boot a saved, unexpired token is adopted directly (no Google
 * round-trip); GIS one-tap remains the fallback for expiry/new sessions.
 *
 * Flow: signed-out → (GIS credential | dev token) → probe the admin API
 * (GET /v1/admin/signin-attempts?limit=1 as a cheap "am I an admin?") →
 *   200 → ready (admin)   403 → not-admin (show email+sub to provision)
 *   401 → rejected (bad/expired token) → back to signed-out
 * A 401 later, mid-session, drops the token and returns to signed-out with a
 * "session expired" note; GIS silent re-prompt is attempted automatically.
 */

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { ApiClient, isApiError } from "../api/client";
import { decodeJwtClaims } from "../lib/jwt";
import { loadPortalConfig } from "../config";
import { loadGis, type GisCredentialResponse } from "./gis";

export type AuthStatus =
  | "loading" // fetching portal config
  | "signed-out"
  | "checking" // token obtained, probing admin-ness
  | "ready" // verified admin
  | "not-admin"; // verified identity, but 403 from the admin API

export interface AuthIdentity {
  email: string;
  sub: string;
  isDev: boolean;
  /** Google profile photo URL from the ID token's picture claim, if any. */
  picture?: string;
}

interface AuthContextValue {
  status: AuthStatus;
  identity: AuthIdentity | null;
  /** Human-readable note for the sign-in screen (e.g. "session expired"). */
  notice: string | null;
  googleClientId: string;
  api: ApiClient;
  signInWithDevToken: (token: string) => void;
  signOut: () => void;
  /** Mount the GIS button into a container (SignInPage). */
  renderGoogleButton: (el: HTMLElement) => void;
}

const AuthContext = createContext<AuthContextValue | null>(null);

/** sessionStorage key for the bearer token (see header comment for custody). */
const TOKEN_KEY = "ghoztty-admin-token";

function saveToken(token: string) {
  try {
    sessionStorage.setItem(TOKEN_KEY, token);
  } catch {
    /* storage unavailable (private mode etc.) — memory-only fallback */
  }
}

function clearToken() {
  try {
    sessionStorage.removeItem(TOKEN_KEY);
  } catch {
    /* ignore */
  }
}

/**
 * A saved token worth adopting on boot: present and, when it carries an exp
 * claim, not within 30s of expiry. Dev tokens (not JWTs) have no exp and are
 * adoptable as-is.
 */
function loadSavedToken(): string | null {
  try {
    const t = sessionStorage.getItem(TOKEN_KEY);
    if (!t) return null;
    const claims = decodeJwtClaims(t);
    if (claims?.exp && claims.exp * 1000 < Date.now() + 30_000) {
      sessionStorage.removeItem(TOKEN_KEY);
      return null;
    }
    return t;
  } catch {
    return null;
  }
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const tokenRef = useRef<string | null>(null);
  const [status, setStatus] = useState<AuthStatus>("loading");
  const [identity, setIdentity] = useState<AuthIdentity | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [googleClientId, setGoogleClientId] = useState("");
  const statusRef = useRef(status);
  statusRef.current = status;

  const handleUnauthorized = useCallback(() => {
    if (statusRef.current === "checking") return; // probe handles its own 401
    tokenRef.current = null;
    clearToken();
    setIdentity(null);
    setNotice("Your session expired — sign in again.");
    setStatus("signed-out");
    // Silent refresh attempt: a returning Google session resolves one-tap.
    void loadGis().then((gis) => gis?.prompt());
  }, []);

  const api = useMemo(
    () =>
      new ApiClient({
        getToken: () => tokenRef.current,
        onUnauthorized: handleUnauthorized,
      }),
    [handleUnauthorized],
  );

  /** Probe admin-ness with the freshly obtained token. */
  const adopt = useCallback(
    async (token: string, ident: AuthIdentity) => {
      tokenRef.current = token;
      saveToken(token);
      setIdentity(ident);
      setNotice(null);
      setStatus("checking");
      try {
        await api.listAttempts({ limit: 1 });
        setStatus("ready");
      } catch (e) {
        if (isApiError(e) && e.status === 403) {
          setStatus("not-admin");
        } else if (isApiError(e) && e.status === 401) {
          tokenRef.current = null;
          clearToken();
          setIdentity(null);
          setNotice("The relay rejected that token (401). Sign in again.");
          setStatus("signed-out");
        } else {
          tokenRef.current = null;
          setIdentity(null);
          setNotice(
            `Could not reach the relay: ${e instanceof Error ? e.message : String(e)}`,
          );
          setStatus("signed-out");
        }
      }
    },
    [api],
  );

  const onGoogleCredential = useCallback(
    (resp: GisCredentialResponse) => {
      const claims = decodeJwtClaims(resp.credential);
      void adopt(resp.credential, {
        email: claims?.email ?? "(unknown)",
        sub: claims?.sub ?? "(unknown)",
        isDev: false,
        picture: claims?.picture,
      });
    },
    [adopt],
  );

  // Boot: load runtime config, adopt a saved (unexpired) session token if one
  // survives in sessionStorage — F5 stays signed in with zero Google round
  // trips — else initialize GIS and try a silent one-tap.
  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const cfg = await loadPortalConfig();
      if (cancelled) return;
      setGoogleClientId(cfg.googleClientId);

      const saved = loadSavedToken();
      if (saved) {
        const claims = decodeJwtClaims(saved);
        void adopt(saved, {
          email: claims?.email ?? "dev",
          sub: claims?.sub ?? "dev",
          isDev: claims === null,
          picture: claims?.picture,
        });
      } else {
        setStatus("signed-out");
      }

      if (cfg.googleClientId) {
        const gis = await loadGis();
        if (cancelled || !gis) return;
        gis.initialize({
          client_id: cfg.googleClientId,
          callback: onGoogleCredential,
          auto_select: true,
        });
        // No saved token: attempt the silent one-tap for a returning admin.
        // (Chrome FedCM may render a small chip; the sessionStorage path
        // above is what makes plain refreshes seamless.) After an explicit
        // sign-out, disableAutoSelect() keeps this non-automatic.
        if (!saved) gis.prompt();
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [onGoogleCredential, adopt]);

  const renderGoogleButton = useCallback(
    (el: HTMLElement) => {
      if (!googleClientId) return;
      void loadGis().then((gis) => {
        if (gis && el.isConnected) {
          gis.renderButton(el, {
            theme: "filled_black",
            size: "large",
            width: 280,
          });
        }
      });
    },
    [googleClientId],
  );

  const signInWithDevToken = useCallback(
    (token: string) => {
      const t = token.trim();
      if (!t) return;
      // The relay's DEV_AUTH maps this static token to sub "dev"; a pasted
      // real ID token also works (claims shown if decodable).
      const claims = decodeJwtClaims(t);
      void adopt(t, {
        email: claims?.email ?? "dev",
        sub: claims?.sub ?? "dev",
        isDev: claims === null,
      });
    },
    [adopt],
  );

  const signOut = useCallback(() => {
    tokenRef.current = null;
    clearToken();
    setIdentity(null);
    setNotice(null);
    setStatus("signed-out");
    void loadGis().then((gis) => gis?.disableAutoSelect());
  }, []);

  const value = useMemo<AuthContextValue>(
    () => ({
      status,
      identity,
      notice,
      googleClientId,
      api,
      signInWithDevToken,
      signOut,
      renderGoogleButton,
    }),
    [
      status,
      identity,
      notice,
      googleClientId,
      api,
      signInWithDevToken,
      signOut,
      renderGoogleButton,
    ],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth outside AuthProvider");
  return ctx;
}
