/**
 * Settings page flow: the current mode renders checked with its source badge;
 * picking another mode confirms first, then PUTs {"signup_mode"} and reflects
 * the new state; cancel never touches the API; a failed PUT surfaces a toast
 * and keeps the old mode.
 *
 * Allowlist section: env entries render with the immutable "env" badge and
 * no Remove; portal entries show note + Remove (confirmed, URL-encoded
 * DELETE); the add form POSTs {email, note} and surfaces 409 duplicates
 * inline; the "Only enforced in Allowlist mode" hint tracks the mode.
 */

import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiClient } from "../api/client";
import type { AllowlistEntry, ServiceSettings } from "../api/types";
import { jsonResponse, renderPage, textResponse } from "../test/harness";
import SettingsPage from "./SettingsPage";

vi.mock("../auth/AuthContext", () => ({
  useAuth: () => ({
    api: new ApiClient({ getToken: () => "test-token" }),
    status: "ready",
    identity: { email: "admin@example.com", sub: "admin", isDev: true },
  }),
}));

afterEach(() => {
  vi.restoreAllMocks();
});

interface MockApiOpts {
  putFailure?: { status: number; body: string };
  allowlist?: AllowlistEntry[];
  addFailure?: { status: number; body: string };
}

/** Mocks fetch with mutable settings + allowlist state: GETs serve it,
 * PUT/POST/DELETE mutate it (or fail when a failure is configured). */
function mockSettingsApi(initial: ServiceSettings, opts: MockApiOpts = {}) {
  let state = initial;
  let entries = [...(opts.allowlist ?? [])];
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const url = new URL(String(input), "http://localhost");
    const method = init?.method ?? "GET";
    if (url.pathname === "/v1/admin/settings") {
      if (method === "GET") {
        return jsonResponse(200, state);
      }
      if (method === "PUT") {
        if (opts.putFailure) return textResponse(opts.putFailure.status, opts.putFailure.body);
        const body = JSON.parse(String(init?.body)) as { signup_mode: ServiceSettings["signup_mode"] };
        state = { signup_mode: body.signup_mode, source: "db" };
        return jsonResponse(200, state);
      }
    }
    if (url.pathname === "/v1/admin/allowlist") {
      if (method === "GET") {
        return jsonResponse(200, { emails: entries });
      }
      if (method === "POST") {
        if (opts.addFailure) return textResponse(opts.addFailure.status, opts.addFailure.body);
        const body = JSON.parse(String(init?.body)) as { email: string; note?: string };
        const entry: AllowlistEntry = {
          email: body.email,
          source: "db",
          note: body.note,
          created_at: "2026-07-05T12:00:00Z",
        };
        entries = [...entries, entry];
        return jsonResponse(201, { email: entry });
      }
    }
    if (url.pathname.startsWith("/v1/admin/allowlist/") && method === "DELETE") {
      const email = decodeURIComponent(url.pathname.slice("/v1/admin/allowlist/".length));
      const before = entries.length;
      entries = entries.filter((e) => e.email !== email);
      return jsonResponse(200, { removed: entries.length < before });
    }
    throw new Error(`unexpected fetch ${method} ${url.pathname}`);
  });
}

describe("SettingsPage", () => {
  it("renders the four modes with the current one checked and the env-default badge", async () => {
    mockSettingsApi({ signup_mode: "invite", source: "env-default" });
    renderPage(<SettingsPage />);

    const invite = await screen.findByRole("radio", { name: /Invite only/ });
    expect(invite).toHaveAttribute("aria-checked", "true");
    for (const name of [/^Open/, /Closed/, /Allowlist/]) {
      expect(screen.getByRole("radio", { name })).toHaveAttribute("aria-checked", "false");
    }
    expect(screen.getByText("env default")).toBeInTheDocument();
  });

  it("confirms, PUTs the new mode, and reflects the flip", async () => {
    const fetchMock = mockSettingsApi({ signup_mode: "invite", source: "env-default" });
    renderPage(<SettingsPage />);

    await userEvent.click(await screen.findByRole("radio", { name: /^Open/ }));

    // Confirm dialog spells out the transition and the immediacy.
    const dialog = await screen.findByRole("dialog", { name: "Change sign-up policy" });
    expect(dialog).toHaveTextContent(/effective immediately/);

    await userEvent.click(screen.getByRole("button", { name: "Switch to Open" }));

    // PUT body matches, and the UI reflects the new (db-governed) state.
    await waitFor(() => {
      expect(screen.getByRole("radio", { name: /^Open/ })).toHaveAttribute("aria-checked", "true");
    });
    const put = fetchMock.mock.calls.find((c) => c[1]?.method === "PUT")!;
    expect(JSON.parse(String(put[1]!.body))).toEqual({ signup_mode: "open" });
    expect(screen.getByText("set via portal")).toBeInTheDocument();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("cancelling the confirm never PUTs", async () => {
    const fetchMock = mockSettingsApi({ signup_mode: "invite", source: "db" });
    renderPage(<SettingsPage />);

    await userEvent.click(await screen.findByRole("radio", { name: /Closed/ }));
    await screen.findByRole("dialog", { name: "Change sign-up policy" });
    await userEvent.click(screen.getByRole("button", { name: "Cancel" }));

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(fetchMock.mock.calls.every((c) => (c[1]?.method ?? "GET") === "GET")).toBe(true);
    expect(screen.getByRole("radio", { name: /Invite only/ })).toHaveAttribute("aria-checked", "true");
  });

  it("surfaces a failed PUT as an error toast and keeps the old mode", async () => {
    mockSettingsApi(
      { signup_mode: "invite", source: "db" },
      { putFailure: { status: 403, body: "forbidden: admin access required" } },
    );
    renderPage(<SettingsPage />);

    await userEvent.click(await screen.findByRole("radio", { name: /^Open/ }));
    await userEvent.click(await screen.findByRole("button", { name: "Switch to Open" }));

    expect(await screen.findByText(/Change failed:.*admin access required/)).toBeInTheDocument();
    expect(screen.getByRole("radio", { name: /Invite only/ })).toHaveAttribute("aria-checked", "true");
  });
});

describe("SettingsPage allowlist", () => {
  const envEntry: AllowlistEntry = { email: "owner@example.com", source: "env" };
  const dbEntry: AllowlistEntry = {
    email: "friend@example.com",
    source: "db",
    note: "college friend",
    created_at: "2026-07-01T00:00:00Z",
  };

  /** The table row containing the given email. */
  const rowFor = (email: string) =>
    screen.getByText(email).closest("tr") as HTMLElement;

  it("renders env entries badged and immutable, portal entries removable", async () => {
    mockSettingsApi(
      { signup_mode: "allowlist", source: "db" },
      { allowlist: [envEntry, dbEntry] },
    );
    renderPage(<SettingsPage />);

    await screen.findByText("owner@example.com");

    // Env entry: "env" badge, NO Remove button.
    const envRow = rowFor("owner@example.com");
    expect(within(envRow).getByText("env")).toBeInTheDocument();
    expect(within(envRow).queryByRole("button", { name: "Remove" })).not.toBeInTheDocument();

    // Portal entry: "portal" badge, note, Remove button.
    const dbRow = rowFor("friend@example.com");
    expect(within(dbRow).getByText("portal")).toBeInTheDocument();
    expect(within(dbRow).getByText("college friend")).toBeInTheDocument();
    expect(within(dbRow).getByRole("button", { name: "Remove" })).toBeInTheDocument();
  });

  it("shows the enforcement hint when the mode is not allowlist, hides it when it is", async () => {
    mockSettingsApi({ signup_mode: "invite", source: "db" }, { allowlist: [] });
    const { unmount } = renderPage(<SettingsPage />);
    expect(await screen.findByText("Only enforced in Allowlist mode")).toBeInTheDocument();
    unmount();
    vi.restoreAllMocks();

    mockSettingsApi({ signup_mode: "allowlist", source: "db" }, { allowlist: [] });
    renderPage(<SettingsPage />);
    await screen.findByRole("radio", { name: /Allowlist/ });
    expect(screen.queryByText("Only enforced in Allowlist mode")).not.toBeInTheDocument();
  });

  it("adds an email with a note: POSTs, clears the form, and shows the entry", async () => {
    const fetchMock = mockSettingsApi(
      { signup_mode: "allowlist", source: "db" },
      { allowlist: [envEntry] },
    );
    renderPage(<SettingsPage />);

    await userEvent.type(await screen.findByLabelText("Email"), "New.Friend@Example.com");
    await userEvent.type(screen.getByLabelText("Note"), "beta wave 2");
    await userEvent.click(screen.getByRole("button", { name: "Add" }));

    // The new entry appears (list refetched after the mutation).
    await screen.findByText("new.friend@example.com");
    const post = fetchMock.mock.calls.find((c) => c[1]?.method === "POST")!;
    expect(JSON.parse(String(post[1]!.body))).toEqual({
      email: "new.friend@example.com", // lowercased client-side
      note: "beta wave 2",
    });
    // Form cleared for the next add.
    expect(screen.getByLabelText("Email")).toHaveValue("");
    expect(screen.getByLabelText("Note")).toHaveValue("");
  });

  it("surfaces a duplicate add (409) inline and keeps the input", async () => {
    mockSettingsApi(
      { signup_mode: "allowlist", source: "db" },
      {
        allowlist: [dbEntry],
        addFailure: { status: 409, body: "email already on the allowlist" },
      },
    );
    renderPage(<SettingsPage />);

    await userEvent.type(await screen.findByLabelText("Email"), "friend@example.com");
    await userEvent.click(screen.getByRole("button", { name: "Add" }));

    expect(await screen.findByRole("alert")).toHaveTextContent(
      /friend@example.com is already on the allowlist/,
    );
    expect(screen.getByLabelText("Email")).toHaveValue("friend@example.com");
  });

  it("removes a portal entry after confirming, DELETEing the encoded email", async () => {
    const fetchMock = mockSettingsApi(
      { signup_mode: "allowlist", source: "db" },
      { allowlist: [envEntry, dbEntry] },
    );
    renderPage(<SettingsPage />);

    await screen.findByText("friend@example.com");
    await userEvent.click(
      within(rowFor("friend@example.com")).getByRole("button", { name: "Remove" }),
    );

    const dialog = await screen.findByRole("dialog", { name: "Remove from allowlist" });
    expect(dialog).toHaveTextContent(/effective immediately/);
    await userEvent.click(screen.getByRole("button", { name: "Remove email" }));

    await waitFor(() => {
      expect(screen.queryByText("friend@example.com")).not.toBeInTheDocument();
    });
    const del = fetchMock.mock.calls.find((c) => c[1]?.method === "DELETE")!;
    expect(String(del[0])).toBe("/v1/admin/allowlist/friend%40example.com");
    // The env entry is untouched.
    expect(screen.getByText("owner@example.com")).toBeInTheDocument();
  });

  it("cancelling the remove confirm never DELETEs", async () => {
    const fetchMock = mockSettingsApi(
      { signup_mode: "allowlist", source: "db" },
      { allowlist: [dbEntry] },
    );
    renderPage(<SettingsPage />);

    await screen.findByText("friend@example.com");
    await userEvent.click(
      within(rowFor("friend@example.com")).getByRole("button", { name: "Remove" }),
    );
    await screen.findByRole("dialog", { name: "Remove from allowlist" });
    await userEvent.click(screen.getByRole("button", { name: "Cancel" }));

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(fetchMock.mock.calls.every((c) => (c[1]?.method ?? "GET") !== "DELETE")).toBe(true);
    expect(screen.getByText("friend@example.com")).toBeInTheDocument();
  });
});
