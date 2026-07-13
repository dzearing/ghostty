/**
 * Runtime portal configuration.
 *
 * The Google web client ID is fetched from /portal-config.json at startup
 * (rather than baked in via a Vite env var) so ONE build artifact works in
 * every environment: rotating the client ID or standing up a second relay
 * host is a static-file edit next to the assets, not a rebuild. In dev,
 * Vite serves portal/public/portal-config.json; in production Caddy serves
 * the same filename from the assets root (see portal/README.md).
 *
 * An empty/missing googleClientId is tolerated: Google sign-in is simply
 * unavailable and the dev-token path (relay DEV_AUTH) is the only way in.
 */

export interface PortalConfig {
  googleClientId: string;
}

export async function loadPortalConfig(): Promise<PortalConfig> {
  try {
    // BASE_URL-relative so the same code works at "/" (dev) and "/admin/"
    // (prod path-routed deploy).
    const res = await fetch(`${import.meta.env.BASE_URL}portal-config.json`, {
      cache: "no-store",
    });
    if (!res.ok) return { googleClientId: "" };
    const raw: unknown = await res.json();
    const obj = (raw ?? {}) as Record<string, unknown>;
    return {
      googleClientId:
        typeof obj.googleClientId === "string" ? obj.googleClientId : "",
    };
  } catch {
    return { googleClientId: "" };
  }
}
