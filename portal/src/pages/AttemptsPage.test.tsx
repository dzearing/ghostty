/**
 * Attempts screen: server-side outcome filtering (chip click → refetch with
 * ?outcome=) and instant client-side search over the fetched window.
 */

import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiClient } from "../api/client";
import type { SigninAttempt } from "../api/types";
import { jsonResponse, renderPage } from "../test/harness";
import AttemptsPage from "./AttemptsPage";

vi.mock("../auth/AuthContext", () => ({
  useAuth: () => ({
    api: new ApiClient({ getToken: () => "test-token" }),
    status: "ready",
    identity: { email: "admin@example.com", sub: "admin", isDev: true },
  }),
}));

const now = Date.now();

const ATTEMPTS: SigninAttempt[] = [
  {
    id: 3,
    ts: new Date(now - 60_000).toISOString(),
    email: "ada@example.com",
    google_sub: "sub-ada",
    ip: "10.0.0.1",
    outcome: "allowed",
    account_id: "acct-1",
  },
  {
    id: 2,
    ts: new Date(now - 120_000).toISOString(),
    email: "mallory@evil.example",
    google_sub: "sub-mallory",
    ip: "203.0.113.9",
    outcome: "blocked",
  },
  {
    id: 1,
    ts: new Date(now - 180_000).toISOString(),
    email: "newbie@example.com",
    google_sub: "sub-newbie",
    ip: "198.51.100.7",
    outcome: "bad_invite",
  },
];

afterEach(() => {
  vi.restoreAllMocks();
});

function mockAttemptsFetch() {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
    const url = new URL(String(input), "http://localhost");
    expect(url.pathname).toBe("/v1/admin/signin-attempts");
    const outcome = url.searchParams.get("outcome");
    const rows = outcome ? ATTEMPTS.filter((a) => a.outcome === outcome) : ATTEMPTS;
    return jsonResponse(200, { attempts: rows });
  });
}

describe("AttemptsPage", () => {
  it("lists attempts and refetches server-side when an outcome chip is toggled", async () => {
    const fetchMock = mockAttemptsFetch();
    renderPage(<AttemptsPage />);

    // All three rows arrive from the unfiltered query.
    expect(await screen.findByText("ada@example.com")).toBeInTheDocument();
    expect(screen.getByText("mallory@evil.example")).toBeInTheDocument();

    // Default window: since (24h) + limit are sent to the server.
    const firstUrl = new URL(String(fetchMock.mock.calls[0][0]), "http://localhost");
    expect(firstUrl.searchParams.get("limit")).toBe("250");
    expect(firstUrl.searchParams.get("since")).toBeTruthy();

    // Toggle the "Blocked" outcome chip → new request with outcome=blocked.
    await userEvent.click(screen.getByRole("button", { name: "Blocked" }));
    await waitFor(() => {
      const urls = fetchMock.mock.calls.map((c) => String(c[0]));
      expect(urls.some((u) => u.includes("outcome=blocked"))).toBe(true);
    });
    await waitFor(() => {
      expect(screen.queryByText("ada@example.com")).not.toBeInTheDocument();
    });
    expect(screen.getByText("mallory@evil.example")).toBeInTheDocument();
  });

  it("filters instantly client-side via the search box", async () => {
    mockAttemptsFetch();
    renderPage(<AttemptsPage />);
    expect(await screen.findByText("ada@example.com")).toBeInTheDocument();

    await userEvent.type(screen.getByLabelText("Filter attempts"), "newbie");

    expect(screen.getByText("newbie@example.com")).toBeInTheDocument();
    expect(screen.queryByText("ada@example.com")).not.toBeInTheDocument();
    expect(screen.queryByText("mallory@evil.example")).not.toBeInTheDocument();
    // Match by IP too.
    await userEvent.clear(screen.getByLabelText("Filter attempts"));
    await userEvent.type(screen.getByLabelText("Filter attempts"), "203.0.113");
    expect(screen.getByText("mallory@evil.example")).toBeInTheDocument();
    expect(screen.queryByText("newbie@example.com")).not.toBeInTheDocument();
  });

  it("shows an empty state when nothing matches", async () => {
    mockAttemptsFetch();
    renderPage(<AttemptsPage />);
    expect(await screen.findByText("ada@example.com")).toBeInTheDocument();

    await userEvent.type(screen.getByLabelText("Filter attempts"), "zzz-no-match");
    expect(screen.getByText("Nothing matches")).toBeInTheDocument();
  });
});
