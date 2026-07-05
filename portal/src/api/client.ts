/**
 * Thin fetch wrapper for the admin API.
 *
 * - Same-origin: `/v1/admin/...` (Vite proxy in dev, Caddy in prod). No CORS.
 * - The bearer token is supplied per-call by a getter so it can live in
 *   memory only (auth/AuthContext owns it — see the XSS note there).
 * - Error mapping: every non-2xx becomes an ApiError carrying the status and
 *   the relay's plain-text error body (http.Error output), so screens can
 *   branch on 401 (re-auth), 403 (not an admin), 409 (duplicate code), etc.
 */

import type {
  Account,
  AccountsQuery,
  AccountUsage,
  AttemptsQuery,
  CreateInviteRequest,
  DeleteAccountResponse,
  InviteCode,
  SigninAttempt,
} from "./types";

export class ApiError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

export const isApiError = (e: unknown): e is ApiError => e instanceof ApiError;

export interface ApiClientOptions {
  /** Returns the current bearer token, or null when signed out. */
  getToken: () => string | null;
  /** Invoked on any 401 so the auth layer can drop the token & re-prompt. */
  onUnauthorized?: () => void;
  /** Base URL override for tests; defaults to same-origin relative paths. */
  baseUrl?: string;
}

export class ApiClient {
  private readonly opts: ApiClientOptions;

  constructor(opts: ApiClientOptions) {
    this.opts = opts;
  }

  private async request<T>(path: string, init?: RequestInit): Promise<T> {
    const token = this.opts.getToken();
    const headers = new Headers(init?.headers);
    if (token) headers.set("Authorization", `Bearer ${token}`);
    if (init?.body != null) headers.set("Content-Type", "application/json");

    const res = await fetch(`${this.opts.baseUrl ?? ""}${path}`, {
      ...init,
      headers,
    });

    if (!res.ok) {
      // The relay writes plain-text errors via http.Error.
      const text = (await res.text().catch(() => "")).trim();
      if (res.status === 401) this.opts.onUnauthorized?.();
      throw new ApiError(res.status, text || res.statusText);
    }

    if (res.status === 204) return undefined as T;
    return (await res.json()) as T;
  }

  // --- Sign-in attempts ---

  async listAttempts(q: AttemptsQuery = {}): Promise<SigninAttempt[]> {
    const params = new URLSearchParams();
    if (q.outcome) params.set("outcome", q.outcome);
    if (q.email) params.set("email", q.email);
    if (q.since) params.set("since", q.since);
    if (q.limit) params.set("limit", String(q.limit));
    const qs = params.toString();
    const body = await this.request<{ attempts: SigninAttempt[] }>(
      `/v1/admin/signin-attempts${qs ? `?${qs}` : ""}`,
    );
    return body.attempts;
  }

  // --- Accounts ---

  async listAccounts(q: AccountsQuery = {}): Promise<Account[]> {
    const params = new URLSearchParams();
    if (q.q) params.set("q", q.q);
    if (q.status) params.set("status", q.status);
    const qs = params.toString();
    const body = await this.request<{ accounts: Account[] }>(
      `/v1/admin/accounts${qs ? `?${qs}` : ""}`,
    );
    return body.accounts;
  }

  async blockAccount(id: string, reason: string): Promise<Account> {
    const body = await this.request<{ account: Account }>(
      `/v1/admin/accounts/${encodeURIComponent(id)}/block`,
      { method: "POST", body: JSON.stringify({ reason }) },
    );
    return body.account;
  }

  async unblockAccount(id: string): Promise<Account> {
    const body = await this.request<{ account: Account }>(
      `/v1/admin/accounts/${encodeURIComponent(id)}/unblock`,
      { method: "POST" },
    );
    return body.account;
  }

  async deleteAccount(id: string): Promise<DeleteAccountResponse> {
    return this.request<DeleteAccountResponse>(
      `/v1/admin/accounts/${encodeURIComponent(id)}`,
      { method: "DELETE" },
    );
  }

  async accountUsage(id: string): Promise<AccountUsage> {
    return this.request<AccountUsage>(
      `/v1/admin/accounts/${encodeURIComponent(id)}/usage`,
    );
  }

  // --- Invite codes ---

  async listInvites(): Promise<InviteCode[]> {
    const body = await this.request<{ invites: InviteCode[] }>(
      "/v1/admin/invites",
    );
    return body.invites;
  }

  async createInvite(req: CreateInviteRequest): Promise<InviteCode> {
    const body = await this.request<{ invite: InviteCode }>(
      "/v1/admin/invites",
      { method: "POST", body: JSON.stringify(req) },
    );
    return body.invite;
  }

  async revokeInvite(code: string): Promise<void> {
    await this.request<void>(
      `/v1/admin/invites/${encodeURIComponent(code)}`,
      { method: "DELETE" },
    );
  }
}
