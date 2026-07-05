/**
 * Invite-create flow: dialog → POST body → generated code surfaced
 * prominently on success; 409 duplicate custom code surfaced inline.
 */

import { screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiClient } from "../api/client";
import type { InviteCode } from "../api/types";
import { jsonResponse, renderPage, textResponse } from "../test/harness";
import InvitesPage from "./InvitesPage";

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

const CREATED: InviteCode = {
  code: "WXYZ-2345",
  created_by: "admin",
  max_uses: 3,
  uses: 0,
  expires_at: null,
  revoked_at: null,
  note: "for a friend",
  created_at: new Date().toISOString(),
};

describe("InvitesPage create flow", () => {
  it("creates an invite and surfaces the generated code prominently", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = new URL(String(input), "http://localhost");
      if (url.pathname === "/v1/admin/invites" && (init?.method ?? "GET") === "GET") {
        return jsonResponse(200, { invites: [] });
      }
      if (url.pathname === "/v1/admin/invites" && init?.method === "POST") {
        return jsonResponse(201, { invite: CREATED });
      }
      throw new Error(`unexpected fetch ${init?.method} ${url.pathname}`);
    });

    renderPage(<InvitesPage />);
    expect(await screen.findByText("No invite codes")).toBeInTheDocument();

    await userEvent.click(screen.getAllByRole("button", { name: "New invite code" })[0]);
    await userEvent.clear(screen.getByLabelText("Max uses"));
    await userEvent.type(screen.getByLabelText("Max uses"), "3");
    await userEvent.type(screen.getByLabelText("Note"), "for a friend");
    await userEvent.click(screen.getByRole("button", { name: "Create code" }));

    // The generated code is the hero of the success state.
    const hero = await screen.findByTestId("created-code");
    expect(hero).toHaveTextContent("WXYZ-2345");

    // And the POST body matched the form.
    const post = fetchMock.mock.calls.find((c) => c[1]?.method === "POST")!;
    expect(JSON.parse(String(post[1]!.body))).toEqual({
      max_uses: 3,
      expires_at: null,
      note: "for a friend",
    });
  });

  it("surfaces a 409 duplicate custom code inline", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = new URL(String(input), "http://localhost");
      if (url.pathname === "/v1/admin/invites" && (init?.method ?? "GET") === "GET") {
        return jsonResponse(200, { invites: [] });
      }
      if (init?.method === "POST") {
        return textResponse(409, "invite code already exists");
      }
      throw new Error("unexpected fetch");
    });

    renderPage(<InvitesPage />);
    expect(await screen.findByText("No invite codes")).toBeInTheDocument();

    await userEvent.click(screen.getAllByRole("button", { name: "New invite code" })[0]);
    await userEvent.type(screen.getByLabelText("Custom code"), "TAKEN-CODE");
    await userEvent.click(screen.getByRole("button", { name: "Create code" }));

    expect(await screen.findByRole("alert")).toHaveTextContent(/already exists/);
    // Dialog stays open for a retry.
    expect(screen.getByLabelText("Custom code")).toBeInTheDocument();
  });

  it("rejects a non-positive max uses before hitting the API", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = new URL(String(input), "http://localhost");
      if (url.pathname === "/v1/admin/invites" && (init?.method ?? "GET") === "GET") {
        return jsonResponse(200, { invites: [] });
      }
      throw new Error("should not POST");
    });

    renderPage(<InvitesPage />);
    expect(await screen.findByText("No invite codes")).toBeInTheDocument();

    await userEvent.click(screen.getAllByRole("button", { name: "New invite code" })[0]);
    await userEvent.clear(screen.getByLabelText("Max uses"));
    await userEvent.type(screen.getByLabelText("Max uses"), "0");
    await userEvent.click(screen.getByRole("button", { name: "Create code" }));

    expect(await screen.findByRole("alert")).toHaveTextContent(/positive whole number/);
    expect(fetchMock.mock.calls.every((c) => (c[1]?.method ?? "GET") === "GET")).toBe(true);
  });
});
