/**
 * Pre-app gate screens: sign-in (401 / signed-out), verifying, and the
 * 403 "signed in, but not an admin" page. All render full-viewport, before
 * the AppShell exists.
 */

import { useEffect, useRef, useState, type FormEvent } from "react";
import { useAuth } from "../auth/AuthContext";
import { CopyButton } from "../components/ui";

export function SignInPage() {
  const { notice, googleClientId, renderGoogleButton, signInWithDevToken } =
    useAuth();
  const btnRef = useRef<HTMLDivElement>(null);
  const [devOpen, setDevOpen] = useState(false);
  const [devToken, setDevToken] = useState("");

  useEffect(() => {
    if (btnRef.current && googleClientId) renderGoogleButton(btnRef.current);
  }, [googleClientId, renderGoogleButton]);

  const submitDev = (e: FormEvent) => {
    e.preventDefault();
    signInWithDevToken(devToken);
  };

  return (
    <div className="gate">
      <div className="gate-card">
        <div className="gate-glyph">👻</div>
        <div>
          <div className="gate-title">Ghoztty Relay Admin</div>
          <div className="gate-sub">Sign in with an admin Google account.</div>
        </div>

        {notice && <div className="callout info">{notice}</div>}

        {googleClientId ? (
          <div ref={btnRef} />
        ) : (
          <div className="gate-note">
            No Google client ID configured (portal-config.json). Use a dev
            token below, or serve a portal-config.json with{" "}
            <code>googleClientId</code> set.
          </div>
        )}

        {devOpen ? (
          <form className="dev-auth" onSubmit={submitDev}>
            <label className="overline" htmlFor="dev-token">
              Dev token
            </label>
            <input
              id="dev-token"
              className="input"
              type="password"
              placeholder="DEV_CLIENT_TOKEN or a raw ID token"
              value={devToken}
              onChange={(e) => setDevToken(e.target.value)}
              autoComplete="off"
            />
            <div className="gate-note">
              For relays running with <code>DEV_AUTH=true</code>: paste the
              static <code>DEV_CLIENT_TOKEN</code> (maps to sub{" "}
              <code>dev</code>). Held in memory only.
            </div>
            <button className="btn primary" type="submit" disabled={!devToken.trim()}>
              Continue
            </button>
          </form>
        ) : (
          <button className="link-quiet" onClick={() => setDevOpen(true)}>
            dev sign-in
          </button>
        )}
      </div>
    </div>
  );
}

export function CheckingPage() {
  return (
    <div className="gate">
      <div className="gate-card">
        <div className="gate-glyph">👻</div>
        <div className="gate-title">Verifying access…</div>
        <div className="skeleton" style={{ width: 180, height: 10 }} />
      </div>
    </div>
  );
}

/** 403: verified identity, but not on ADMIN_SUBS / is_admin. Shows exactly
 * what a provisioning human needs: the email and the stable sub. */
export function NotAdminPage() {
  const { identity, signOut } = useAuth();
  return (
    <div className="gate">
      <div className="gate-card">
        <div className="gate-glyph">🚫</div>
        <div>
          <div className="gate-title">Not an admin</div>
          <div className="gate-sub">
            You are signed in, but this identity has no admin access.
          </div>
        </div>
        <div className="gate-ident">
          <div className="row">
            <span className="k">email</span>
            <span className="v">{identity?.email}</span>
          </div>
          <div className="row">
            <span className="k">sub</span>
            <span className="v">{identity?.sub}</span>
            {identity?.sub && <CopyButton text={identity.sub} label="Copy sub" />}
          </div>
        </div>
        <div className="gate-note">
          To grant access, add this sub to the relay's <code>ADMIN_SUBS</code>{" "}
          environment variable (or set <code>is_admin</code> on the account)
          and try again.
        </div>
        <button className="btn" onClick={signOut}>
          Sign in as someone else
        </button>
      </div>
    </div>
  );
}
