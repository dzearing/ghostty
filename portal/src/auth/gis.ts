/**
 * Google Identity Services (GIS) loader + minimal typings.
 *
 * The GIS client library is loaded on demand from Google's CDN; the ID-token
 * credential it returns has aud = the configured web client ID, which the
 * relay already accepts (relay/auth.go allowedAuds includes
 * GOOGLE_WEB_CLIENT_ID), so the token is sent to /v1/admin as-is.
 */

export interface GisCredentialResponse {
  credential: string; // the Google ID token (JWT)
}

interface GisIdApi {
  initialize(config: {
    client_id: string;
    callback: (resp: GisCredentialResponse) => void;
    auto_select?: boolean;
    use_fedcm_for_prompt?: boolean;
  }): void;
  renderButton(
    parent: HTMLElement,
    options: {
      type?: "standard" | "icon";
      theme?: "outline" | "filled_black" | "filled_blue";
      size?: "large" | "medium" | "small";
      text?: string;
      shape?: string;
      width?: number;
    },
  ): void;
  prompt(): void;
  disableAutoSelect(): void;
}

declare global {
  interface Window {
    google?: { accounts?: { id?: GisIdApi } };
  }
}

const GIS_SRC = "https://accounts.google.com/gsi/client";

let loadPromise: Promise<GisIdApi | null> | null = null;

/** Load the GIS script once; resolves null on failure (offline, blocked). */
export function loadGis(): Promise<GisIdApi | null> {
  if (loadPromise) return loadPromise;
  loadPromise = new Promise((resolve) => {
    if (window.google?.accounts?.id) {
      resolve(window.google.accounts.id);
      return;
    }
    const script = document.createElement("script");
    script.src = GIS_SRC;
    script.async = true;
    script.onload = () => resolve(window.google?.accounts?.id ?? null);
    script.onerror = () => resolve(null);
    document.head.appendChild(script);
  });
  return loadPromise;
}
