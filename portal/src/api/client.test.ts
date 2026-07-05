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
