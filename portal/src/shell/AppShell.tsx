/** App chrome: sidebar nav, sticky header with admin identity + theme toggle. */

import { useEffect, useState, type ReactNode } from "react";
import { NavLink, useLocation } from "react-router-dom";
import { useAuth } from "../auth/AuthContext";

const NAV = [
  {
    to: "/",
    label: "Dashboard",
    icon: (
      <svg className="nav-icon" viewBox="0 0 16 16" fill="none">
        <rect x="1.5" y="1.5" width="5.5" height="5.5" rx="1.5" stroke="currentColor" strokeWidth="1.3" />
        <rect x="9" y="1.5" width="5.5" height="5.5" rx="1.5" stroke="currentColor" strokeWidth="1.3" />
        <rect x="1.5" y="9" width="5.5" height="5.5" rx="1.5" stroke="currentColor" strokeWidth="1.3" />
        <rect x="9" y="9" width="5.5" height="5.5" rx="1.5" stroke="currentColor" strokeWidth="1.3" />
      </svg>
    ),
  },
  {
    to: "/attempts",
    label: "Sign-in attempts",
    icon: (
      <svg className="nav-icon" viewBox="0 0 16 16" fill="none">
        <path d="M6 3h6.5A1.5 1.5 0 0114 4.5v7A1.5 1.5 0 0112.5 13H6" stroke="currentColor" strokeWidth="1.3" />
        <path d="M2 8h7M7 5.5L9.5 8 7 10.5" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    ),
  },
  {
    to: "/accounts",
    label: "Accounts",
    icon: (
      <svg className="nav-icon" viewBox="0 0 16 16" fill="none">
        <circle cx="8" cy="5" r="2.75" stroke="currentColor" strokeWidth="1.3" />
        <path d="M2.5 14c.6-2.9 2.9-4.5 5.5-4.5s4.9 1.6 5.5 4.5" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
      </svg>
    ),
  },
  {
    to: "/invites",
    label: "Invite codes",
    icon: (
      <svg className="nav-icon" viewBox="0 0 16 16" fill="none">
        <rect x="1.5" y="4" width="13" height="8.5" rx="1.5" stroke="currentColor" strokeWidth="1.3" />
        <path d="M4.5 8.25h4M10.75 8.25h.75" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
      </svg>
    ),
  },
  {
    to: "/settings",
    label: "Settings",
    icon: (
      <svg className="nav-icon" viewBox="0 0 16 16" fill="none">
        <path d="M1.75 4.75h6M12 4.75h2.25M1.75 11.25h2.25M8 11.25h6.25" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
        <circle cx="9.9" cy="4.75" r="1.9" stroke="currentColor" strokeWidth="1.3" />
        <circle cx="6.1" cy="11.25" r="1.9" stroke="currentColor" strokeWidth="1.3" />
      </svg>
    ),
  },
];

const TITLES: Record<string, string> = {
  "/": "Dashboard",
  "/attempts": "Sign-in attempts",
  "/accounts": "Accounts",
  "/invites": "Invite codes",
  "/settings": "Settings",
};

function pageTitle(pathname: string): string {
  if (TITLES[pathname]) return TITLES[pathname];
  if (pathname.startsWith("/accounts/")) return "Account";
  return "Admin";
}

type Theme = "dark" | "light";

/** Theme preference persists in localStorage (a UI preference, not a secret —
 * unlike the auth token, which never touches storage). */
function useTheme(): [Theme, () => void] {
  const [theme, setTheme] = useState<Theme>(() => {
    const stored = localStorage.getItem("portal-theme");
    return stored === "light" ? "light" : "dark";
  });
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem("portal-theme", theme);
  }, [theme]);
  return [theme, () => setTheme((t) => (t === "dark" ? "light" : "dark"))];
}

export function AppShell({ children }: { children: ReactNode }) {
  const { identity, signOut } = useAuth();
  const location = useLocation();
  const [theme, toggleTheme] = useTheme();

  const initial = identity?.email?.[0]?.toUpperCase() ?? "?";

  return (
    <div className="shell">
      <aside className="sidebar">
        <div className="sidebar-brand">
          <span className="glyph">👻</span>
          <span>
            Ghoztty Relay
            <span className="sub">Admin</span>
          </span>
        </div>
        {NAV.map((item) => (
          <NavLink
            key={item.to}
            to={item.to}
            end={item.to === "/"}
            className={({ isActive }) => `nav-item ${isActive ? "active" : ""}`}
          >
            {item.icon}
            {item.label}
          </NavLink>
        ))}
        <div className="sidebar-foot">ghoztty relay · admin portal</div>
      </aside>

      <div className="main">
        <header className="header">
          <div className="header-title">{pageTitle(location.pathname)}</div>
          <div className="header-side">
            <button
              className="icon-btn"
              onClick={toggleTheme}
              title={theme === "dark" ? "Switch to light theme" : "Switch to dark theme"}
              aria-label="Toggle theme"
            >
              {theme === "dark" ? (
                <svg width="15" height="15" viewBox="0 0 16 16" fill="none">
                  <circle cx="8" cy="8" r="3.25" stroke="currentColor" strokeWidth="1.3" />
                  <path d="M8 1.5v1.6M8 12.9v1.6M1.5 8h1.6M12.9 8h1.6M3.4 3.4l1.13 1.13M11.47 11.47l1.13 1.13M12.6 3.4l-1.13 1.13M4.53 11.47L3.4 12.6" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
                </svg>
              ) : (
                <svg width="15" height="15" viewBox="0 0 16 16" fill="none">
                  <path d="M13.5 9.5A5.75 5.75 0 016.5 2.5a5.75 5.75 0 107 7z" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round" />
                </svg>
              )}
            </button>
            <div className="whoami" title={identity ? `sub: ${identity.sub}` : undefined}>
              {identity?.picture ? (
                <img
                  className="avatar"
                  src={identity.picture}
                  alt=""
                  referrerPolicy="no-referrer"
                />
              ) : (
                <span className="avatar">{initial}</span>
              )}
              <span>{identity?.email}</span>
              {identity?.isDev && <span className="badge warn">dev</span>}
            </div>
            <button className="btn ghost small" onClick={signOut}>
              Sign out
            </button>
          </div>
        </header>
        <div className="content">{children}</div>
      </div>
    </div>
  );
}
