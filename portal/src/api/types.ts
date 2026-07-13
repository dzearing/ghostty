/**
 * Wire shapes of the M2 admin REST API (/v1/admin/*), transcribed from the
 * relay's Go source (relay/admin.go, relay/admin_store.go). These are the
 * exact JSON field names the relay serves — do not "improve" them here.
 */

export type AccountStatus = "active" | "blocked";

export interface Account {
  id: string;
  google_sub: string;
  email: string;
  status: AccountStatus;
  invited_by_code?: string;
  created_at: string;
  blocked_at?: string;
  blocked_reason?: string;
  is_admin: boolean;
  device_count: number;
}

/** signin_attempts.outcome enum (relay/accounts.go). */
export type Outcome =
  | "allowed"
  | "blocked"
  | "no_account"
  | "bad_invite"
  | "expired_invite"
  | "revoked_invite"
  | "exhausted_invite"
  | "not_verified"
  // A verified fresh identity refused because the signup mode is `closed`
  // (relay/settings.go); existing accounts are unaffected.
  | "signup_closed"
  // Legacy allowlist-path decisions (signup mode `allowlist`). Distinct
  // names so the feed shows which auth model decided.
  | "allowlist_allowed"
  | "allowlist_rejected";

export const ALL_OUTCOMES: Outcome[] = [
  "allowed",
  "blocked",
  "no_account",
  "bad_invite",
  "expired_invite",
  "revoked_invite",
  "exhausted_invite",
  "not_verified",
  "signup_closed",
  "allowlist_allowed",
  "allowlist_rejected",
];

/** Sign-in succeeded, under either auth model (dashboard bucketing). */
export function isAllowedOutcome(o: Outcome | string): boolean {
  return o === "allowed" || o === "allowlist_allowed";
}

export interface SigninAttempt {
  id: number;
  ts: string;
  email: string;
  google_sub: string;
  ip: string;
  outcome: Outcome;
  account_id?: string;
}

export interface InviteCode {
  code: string;
  created_by?: string;
  max_uses: number | null;
  uses: number;
  expires_at: string | null;
  revoked_at: string | null;
  note: string;
  created_at: string;
}

export interface Device {
  id: string;
  name: string;
  hostname?: string;
  online: boolean;
  created_at: string;
}

export interface AccountUsage {
  account: Account;
  devices: Device[];
  device_count: number;
  signin_attempts: Record<string, number>;
}

export interface AttemptsQuery {
  outcome?: Outcome;
  email?: string;
  since?: string; // RFC3339, inclusive
  limit?: number; // default 100, cap 1000 (server-enforced)
}

export interface AccountsQuery {
  q?: string; // case-insensitive email substring
  status?: AccountStatus;
}

export interface CreateInviteRequest {
  code?: string;
  max_uses: number | null;
  expires_at: string | null;
  note: string;
}

export interface DeleteAccountResponse {
  deleted: boolean;
  devices_deleted: number;
}

/** Sign-up policy (relay settings.signup_mode; relay/settings.go). */
export type SignupMode = "open" | "invite" | "closed" | "allowlist";

export const ALL_SIGNUP_MODES: SignupMode[] = [
  "open",
  "invite",
  "closed",
  "allowlist",
];

/** GET/PUT /v1/admin/settings response. */
export interface ServiceSettings {
  signup_mode: SignupMode;
  /**
   * "db" when a portal-set settings row governs; "env-default" when the mode
   * is still seeded from the server environment (SIGNUP_MODE / INVITE_SIGNUP).
   */
  source: "db" | "env-default";
}

/**
 * One effective-allowlist entry (GET /v1/admin/allowlist). The effective
 * list is the union of portal-managed allowed_emails rows (source "db") and
 * the ALLOWED_EMAILS env var (source "env" — bootstrap/recovery: always
 * honored, immutable from the portal, so no note/created_at).
 */
export interface AllowlistEntry {
  email: string;
  source: "db" | "env";
  note?: string;
  created_at?: string;
}

export interface AddAllowlistRequest {
  email: string;
  note?: string;
}

/** DELETE /v1/admin/allowlist/{email} response. */
export interface RemoveAllowlistResponse {
  removed: boolean;
}
