/**
 * ApiClient contract tests against a mocked fetch: auth header propagation
 * and — most importantly — error mapping (401 triggers onUnauthorized, 403
 * and 409 surface as typed ApiErrors carrying the relay's plain-text body).
 */

import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiClient, ApiError, isApiError } from "./client";

function textResponse(status: number, body: string): Response {
  return new Response(body, {
    status,
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("ApiClient", () => {
  it("sends the bearer token and parses list responses", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(jsonResponse(200, { attempts: [] }));

    const client = new ApiClient({ getToken: () => "tok-123" });
    const attempts = await client.listAttempts({ outcome: "allowed", limit: 5 });

    expect(attempts).toEqual([]);
    const [url, init] = fetchMock.mock.calls[0];
    expect(String(url)).toBe("/v1/admin/signin-attempts?outcome=allowed&limit=5");
    expect(new Headers(init?.headers).get("Authorization")).toBe("Bearer tok-123");
  });

  it("maps 401 to ApiError and invokes onUnauthorized", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      textResponse(401, "unauthorized"),
    );
    const onUnauthorized = vi.fn();
    const client = new ApiClient({ getToken: () => "expired", onUnauthorized });

    const err = await client.listAccounts().catch((e: unknown) => e);
    expect(isApiError(err)).toBe(true);
    expect((err as ApiError).status).toBe(401);
    expect((err as ApiError).message).toBe("unauthorized");
    expect(onUnauthorized).toHaveBeenCalledTimes(1);
  });

  it("maps 403 to ApiError WITHOUT invoking onUnauthorized (not-an-admin is not re-auth)", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      textResponse(403, "forbidden: admin access required"),
    );
    const onUnauthorized = vi.fn();
    const client = new ApiClient({ getToken: () => "valid", onUnauthorized });

    const err = await client.listInvites().catch((e: unknown) => e);
    expect((err as ApiError).status).toBe(403);
    expect((err as ApiError).message).toContain("admin access required");
    expect(onUnauthorized).not.toHaveBeenCalled();
  });

  it("maps 409 duplicate invite to ApiError with the relay's message", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      textResponse(409, "invite code already exists"),
    );
    const client = new ApiClient({ getToken: () => "valid" });

    const err = await client
      .createInvite({ code: "DUPE-CODE", max_uses: 1, expires_at: null, note: "" })
      .catch((e: unknown) => e);
    expect((err as ApiError).status).toBe(409);
    expect((err as ApiError).message).toBe("invite code already exists");
  });

  it("treats 204 (invite revoke) as success with no body", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(null, { status: 204 }),
    );
    const client = new ApiClient({ getToken: () => "valid" });
    await expect(client.revokeInvite("ABCD-EFGH")).resolves.toBeUndefined();
  });

  it("gets service settings with the bearer token", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(
        jsonResponse(200, { signup_mode: "invite", source: "env-default" }),
      );
    const client = new ApiClient({ getToken: () => "tok-123" });

    const settings = await client.getSettings();
    expect(settings).toEqual({ signup_mode: "invite", source: "env-default" });
    const [url, init] = fetchMock.mock.calls[0];
    expect(String(url)).toBe("/v1/admin/settings");
    expect(init?.method).toBeUndefined(); // GET
    expect(new Headers(init?.headers).get("Authorization")).toBe("Bearer tok-123");
  });

  it("PUTs the signup mode and returns the new state", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(jsonResponse(200, { signup_mode: "open", source: "db" }));
    const client = new ApiClient({ getToken: () => "tok-123" });

    const settings = await client.putSettings("open");
    expect(settings).toEqual({ signup_mode: "open", source: "db" });
    const [url, init] = fetchMock.mock.calls[0];
    expect(String(url)).toBe("/v1/admin/settings");
    expect(init?.method).toBe("PUT");
    expect(JSON.parse(String(init?.body))).toEqual({ signup_mode: "open" });
    expect(new Headers(init?.headers).get("Content-Type")).toBe("application/json");
  });

  it("maps a rejected settings PUT (400) to ApiError with the relay's message", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      textResponse(400, "invalid signup_mode: expected open, invite, closed, or allowlist"),
    );
    const client = new ApiClient({ getToken: () => "valid" });

    const err = await client.putSettings("open").catch((e: unknown) => e);
    expect(isApiError(err)).toBe(true);
    expect((err as ApiError).status).toBe(400);
    expect((err as ApiError).message).toContain("invalid signup_mode");
  });

  it("lists the allowlist with the bearer token and unwraps entries", async () => {
    const entries = [
      { email: "owner@example.com", source: "env" },
      { email: "friend@example.com", source: "db", note: "college friend", created_at: "2026-07-01T00:00:00Z" },
    ];
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(jsonResponse(200, { emails: entries }));
    const client = new ApiClient({ getToken: () => "tok-123" });

    const got = await client.listAllowlist();
    expect(got).toEqual(entries);
    const [url, init] = fetchMock.mock.calls[0];
    expect(String(url)).toBe("/v1/admin/allowlist");
    expect(init?.method).toBeUndefined(); // GET
    expect(new Headers(init?.headers).get("Authorization")).toBe("Bearer tok-123");
  });

  it("POSTs an allowlist add and unwraps the created entry", async () => {
    const entry = {
      email: "friend@example.com",
      source: "db",
      note: "college friend",
      created_at: "2026-07-05T00:00:00Z",
    };
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(jsonResponse(201, { email: entry }));
    const client = new ApiClient({ getToken: () => "tok-123" });

    const got = await client.addAllowlistEmail({
      email: "friend@example.com",
      note: "college friend",
    });
    expect(got).toEqual(entry);
    const [url, init] = fetchMock.mock.calls[0];
    expect(String(url)).toBe("/v1/admin/allowlist");
    expect(init?.method).toBe("POST");
    expect(JSON.parse(String(init?.body))).toEqual({
      email: "friend@example.com",
      note: "college friend",
    });
  });

  it("maps an invalid allowlist add (400) to ApiError with the relay's message", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      textResponse(400, "invalid email"),
    );
    const client = new ApiClient({ getToken: () => "valid" });

    const err = await client
      .addAllowlistEmail({ email: "not-an-email" })
      .catch((e: unknown) => e);
    expect(isApiError(err)).toBe(true);
    expect((err as ApiError).status).toBe(400);
    expect((err as ApiError).message).toBe("invalid email");
  });

  it("maps a duplicate allowlist add (409) to ApiError with the relay's message", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      textResponse(409, "email already on the allowlist"),
    );
    const client = new ApiClient({ getToken: () => "valid" });

    const err = await client
      .addAllowlistEmail({ email: "dupe@example.com" })
      .catch((e: unknown) => e);
    expect((err as ApiError).status).toBe(409);
    expect((err as ApiError).message).toBe("email already on the allowlist");
  });

  it("DELETEs an allowlist email URL-encoded and returns removed", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(jsonResponse(200, { removed: true }));
    const client = new ApiClient({ getToken: () => "valid" });

    const got = await client.removeAllowlistEmail("friend@example.com");
    expect(got).toEqual({ removed: true });
    const [url, init] = fetchMock.mock.calls[0];
    expect(String(url)).toBe("/v1/admin/allowlist/friend%40example.com");
    expect(init?.method).toBe("DELETE");
  });

  it("maps an env-entry allowlist delete (409) to ApiError with the env-managed message", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      textResponse(
        409,
        "email is managed by the ALLOWED_EMAILS environment variable and cannot be removed from the portal",
      ),
    );
    const client = new ApiClient({ getToken: () => "valid" });

    const err = await client
      .removeAllowlistEmail("owner@example.com")
      .catch((e: unknown) => e);
    expect((err as ApiError).status).toBe(409);
    expect((err as ApiError).message).toContain("ALLOWED_EMAILS");
  });

  it("omits the Authorization header when signed out", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(jsonResponse(200, { invites: [] }));
    const client = new ApiClient({ getToken: () => null });
    await client.listInvites();
    const [, init] = fetchMock.mock.calls[0];
    expect(new Headers(init?.headers).get("Authorization")).toBeNull();
  });
});
