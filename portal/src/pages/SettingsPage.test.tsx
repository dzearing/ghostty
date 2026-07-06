/**
 * Settings page flow: the current mode renders checked with its source badge;
 * picking another mode confirms first, then PUTs {"signup_mode"} and reflects
 * the new state; cancel never touches the API; a failed PUT surfaces a toast
 * and keeps the old mode.
 */

import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiClient } from "../api/client";
import type { ServiceSettings } from "../api/types";
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

/** Mocks fetch with a mutable settings state: GET serves it, PUT mutates it
 * (or fails when putStatus is set). Returns the fetch spy. */
function mockSettingsApi(initial: ServiceSettings, putFailure?: { status: number; body: string }) {
  let state = initial;
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const url = new URL(String(input), "http://localhost");
    if (url.pathname !== "/v1/admin/settings") {
      throw new Error(`unexpected fetch ${init?.method} ${url.pathname}`);
    }
    if ((init?.method ?? "GET") === "GET") {
      return jsonResponse(200, state);
    }
    if (init?.method === "PUT") {
      if (putFailure) return textResponse(putFailure.status, putFailure.body);
      const body = JSON.parse(String(init.body)) as { signup_mode: ServiceSettings["signup_mode"] };
      state = { signup_mode: body.signup_mode, source: "db" };
      return jsonResponse(200, state);
    }
    throw new Error(`unexpected method ${init?.method}`);
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
      { status: 403, body: "forbidden: admin access required" },
    );
    renderPage(<SettingsPage />);

    await userEvent.click(await screen.findByRole("radio", { name: /^Open/ }));
    await userEvent.click(await screen.findByRole("button", { name: "Switch to Open" }));

    expect(await screen.findByText(/Change failed:.*admin access required/)).toBeInTheDocument();
    expect(screen.getByRole("radio", { name: /Invite only/ })).toHaveAttribute("aria-checked", "true");
  });
});
