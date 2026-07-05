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
  | "not_verified";

export const ALL_OUTCOMES: Outcome[] = [
  "allowed",
  "blocked",
  "no_account",
  "bad_invite",
  "expired_invite",
  "revoked_invite",
  "exhausted_invite",
  "not_verified",
];

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
