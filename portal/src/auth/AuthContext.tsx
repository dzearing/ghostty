/**
 * Auth state machine + token custody.
 *
 * The bearer token (a Google ID token, or the relay's DEV_CLIENT_TOKEN in
 * dev) is held ONLY in memory (a ref), never in localStorage/sessionStorage:
 * an XSS anywhere on the origin could exfiltrate persisted tokens at leisure,
 * while a memory-only token confines the blast radius to the live session.
 * The cost is a re-prompt on refresh — GIS auto_select makes that a silent
 * one-tap for a returning admin.
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
      });
    },
    [adopt],
  );

  // Boot: load runtime config, then initialize GIS if a client ID exists.
  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const cfg = await loadPortalConfig();
      if (cancelled) return;
      setGoogleClientId(cfg.googleClientId);
      setStatus("signed-out");
      if (cfg.googleClientId) {
        const gis = await loadGis();
        if (cancelled || !gis) return;
        gis.initialize({
          client_id: cfg.googleClientId,
          callback: onGoogleCredential,
          auto_select: true,
        });
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [onGoogleCredential]);

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
