/**
 * Invite codes: list with usable/expired/exhausted/revoked state, one-click
 * copy, inline revoke (confirm), and a create dialog that surfaces the
 * generated XXXX-XXXX code prominently on success.
 */

import { useMemo, useState, type FormEvent } from "react";
import { useCreateInvite, useInvites, useRevokeInvite } from "../api/hooks";
import type { InviteCode } from "../api/types";
import { isApiError } from "../api/client";
import { Dialog } from "../components/Dialog";
import { useToast } from "../components/Toast";
import {
  CopyButton,
  EmptyState,
  ErrorState,
  RelTime,
  TableSkeleton,
} from "../components/ui";
import { absTime, inTime } from "../lib/time";

type InviteState = "usable" | "exhausted" | "expired" | "revoked";

function inviteState(i: InviteCode, now: number): InviteState {
  if (i.revoked_at) return "revoked";
  if (i.expires_at && new Date(i.expires_at).getTime() < now) return "expired";
  if (i.max_uses != null && i.uses >= i.max_uses) return "exhausted";
  return "usable";
}

function StateBadge({ state }: { state: InviteState }) {
  switch (state) {
    case "usable":
      return (
        <span className="badge ok">
          <span className="dot" />
          Usable
        </span>
      );
    case "exhausted":
      return <span className="badge warn">Exhausted</span>;
    case "expired":
      return <span className="badge orange">Expired</span>;
    case "revoked":
      return <span className="badge danger">Revoked</span>;
  }
}

export default function InvitesPage() {
  const query = useInvites();
  const revoke = useRevokeInvite();
  const toast = useToast();
  const [creating, setCreating] = useState(false);
  const [revokeTarget, setRevokeTarget] = useState<InviteCode | null>(null);
  const now = Date.now();

  const rows = useMemo(() => {
    // Usable first, then by recency — dead codes sink.
    const order: Record<InviteState, number> = {
      usable: 0,
      exhausted: 1,
      expired: 2,
      revoked: 3,
    };
    return [...(query.data ?? [])].sort((a, b) => {
      const d = order[inviteState(a, now)] - order[inviteState(b, now)];
      if (d !== 0) return d;
      return new Date(b.created_at).getTime() - new Date(a.created_at).getTime();
    });
  }, [query.data, now]);

  const doRevoke = (i: InviteCode) => {
    revoke.mutate(i.code, {
      onSuccess: () => {
        toast.ok(`Revoked ${i.code}`);
        setRevokeTarget(null);
      },
      onError: (e) => toast.error(`Revoke failed: ${e.message}`),
    });
  };

  return (
    <div className="page">
      <div className="toolbar">
        <div className="page-intro" style={{ marginTop: 0 }}>
          Codes gate new-account sign-up. Revoking a code never affects
          accounts already created with it.
        </div>
        <div className="spacer" />
        <button className="btn primary" onClick={() => setCreating(true)}>
          New invite code
        </button>
      </div>

      <div className="panel">
        {query.isPending ? (
          <TableSkeleton rows={5} cols={5} />
        ) : query.isError ? (
          <ErrorState error={query.error} retry={() => void query.refetch()} />
        ) : rows.length === 0 ? (
          <EmptyState
            glyph="🎟️"
            title="No invite codes"
            hint="Create a code to let someone sign up."
            action={
              <button className="btn primary" onClick={() => setCreating(true)}>
                New invite code
              </button>
            }
          />
        ) : (
          <div className="tbl-wrap">
            <table className="tbl">
              <thead>
                <tr>
                  <th>Code</th>
                  <th style={{ width: 110 }}>State</th>
                  <th className="num" style={{ width: 80 }}>
                    Uses
                  </th>
                  <th style={{ width: 120 }}>Expires</th>
                  <th>Note</th>
                  <th style={{ width: 100 }}>Created</th>
                  <th className="actions" style={{ width: 90 }} />
                </tr>
              </thead>
              <tbody>
                {rows.map((i) => {
                  const state = inviteState(i, now);
                  return (
                    <tr key={i.code}>
                      <td>
                        <span className="row" style={{ display: "inline-flex", gap: 4 }}>
                          <span className="cell-main mono">{i.code}</span>
                          <CopyButton text={i.code} label={`Copy ${i.code}`} />
                        </span>
                      </td>
                      <td>
                        <StateBadge state={state} />
                      </td>
                      <td className="num">
                        {i.uses} / {i.max_uses ?? "∞"}
                      </td>
                      <td className="cell-dim">
                        {i.expires_at ? (
                          <span title={absTime(i.expires_at)}>
                            {new Date(i.expires_at).getTime() < now ? (
                              <RelTime iso={i.expires_at} />
                            ) : (
                              inTime(new Date(i.expires_at).getTime() - now)
                            )}
                          </span>
                        ) : (
                          "never"
                        )}
                      </td>
                      <td className="cell-dim" style={{ maxWidth: 220 }}>
                        <span
                          style={{
                            display: "block",
                            overflow: "hidden",
                            textOverflow: "ellipsis",
                            whiteSpace: "nowrap",
                          }}
                          title={i.note}
                        >
                          {i.note || "—"}
                        </span>
                      </td>
                      <td className="cell-dim">
                        <RelTime iso={i.created_at} />
                      </td>
                      <td className="actions">
                        {state !== "revoked" && (
                          <button
                            className="btn small danger"
                            onClick={() => setRevokeTarget(i)}
                          >
                            Revoke
                          </button>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {creating && <CreateInviteDialog onClose={() => setCreating(false)} />}

      {revokeTarget && (
        <Dialog
          title="Revoke invite code"
          onClose={() => setRevokeTarget(null)}
          footer={
            <>
              <button className="btn ghost" onClick={() => setRevokeTarget(null)}>
                Cancel
              </button>
              <button
                className="btn danger-solid"
                onClick={() => doRevoke(revokeTarget)}
                disabled={revoke.isPending}
              >
                {revoke.isPending ? "Revoking…" : "Revoke code"}
              </button>
            </>
          }
        >
          <p>
            Revoke <strong className="mono">{revokeTarget.code}</strong>? It can
            no longer be used to sign up. Accounts already created with it are
            unaffected.
          </p>
        </Dialog>
      )}
    </div>
  );
}

/* ---- Create dialog ---- */

function CreateInviteDialog({ onClose }: { onClose: () => void }) {
  const create = useCreateInvite();
  const toast = useToast();
  const [code, setCode] = useState("");
  const [maxUses, setMaxUses] = useState("1");
  const [expiry, setExpiry] = useState("");
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [created, setCreated] = useState<InviteCode | null>(null);

  const submit = (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    const uses = maxUses.trim() === "" ? null : Number(maxUses);
    if (uses !== null && (!Number.isInteger(uses) || uses <= 0)) {
      setError("Max uses must be a positive whole number, or blank for unlimited.");
      return;
    }
    create.mutate(
      {
        code: code.trim() || undefined,
        max_uses: uses,
        expires_at: expiry ? new Date(expiry).toISOString() : null,
        note: note.trim(),
      },
      {
        onSuccess: (invite) => {
          setCreated(invite);
          toast.ok(`Created ${invite.code}`);
        },
        onError: (err) => {
          if (isApiError(err) && err.status === 409) {
            setError(`The code “${code.trim()}” already exists — pick another.`);
          } else {
            setError(err.message);
          }
        },
      },
    );
  };

  if (created) {
    return (
      <Dialog
        title="Invite code created"
        onClose={onClose}
        footer={
          <button className="btn primary" onClick={onClose}>
            Done
          </button>
        }
      >
        <div className="code-hero" data-testid="created-code">
          {created.code}
          <CopyButton text={created.code} label="Copy invite code" />
        </div>
        <p>
          Share this code with the person you're inviting —{" "}
          {created.max_uses == null
            ? "unlimited uses"
            : `${created.max_uses} use${created.max_uses === 1 ? "" : "s"}`}
          {created.expires_at
            ? `, expires ${absTime(created.expires_at)}.`
            : ", never expires."}
        </p>
      </Dialog>
    );
  }

  return (
    <Dialog
      title="New invite code"
      onClose={onClose}
      footer={
        <>
          <button className="btn ghost" onClick={onClose} type="button">
            Cancel
          </button>
          <button
            className="btn primary"
            type="submit"
            form="create-invite"
            disabled={create.isPending}
          >
            {create.isPending ? "Creating…" : "Create code"}
          </button>
        </>
      }
    >
      <form id="create-invite" className="stack" style={{ gap: "var(--sp-4)" }} onSubmit={submit}>
        {error && (
          <div className="callout" role="alert">
            {error}
          </div>
        )}
        <div className="field">
          <label htmlFor="inv-code">Custom code</label>
          <input
            id="inv-code"
            className="input"
            placeholder="Leave blank to generate (XXXX-XXXX)"
            value={code}
            onChange={(e) => setCode(e.target.value)}
            maxLength={64}
            autoComplete="off"
          />
        </div>
        <div className="row" style={{ gap: "var(--sp-4)", alignItems: "flex-start" }}>
          <div className="field grow">
            <label htmlFor="inv-uses">Max uses</label>
            <input
              id="inv-uses"
              className="input"
              inputMode="numeric"
              placeholder="∞"
              value={maxUses}
              onChange={(e) => setMaxUses(e.target.value)}
            />
            <span className="hint">Blank = unlimited</span>
          </div>
          <div className="field grow">
            <label htmlFor="inv-exp">Expires</label>
            <input
              id="inv-exp"
              className="input"
              type="datetime-local"
              value={expiry}
              onChange={(e) => setExpiry(e.target.value)}
            />
            <span className="hint">Blank = never</span>
          </div>
        </div>
        <div className="field">
          <label htmlFor="inv-note">Note</label>
          <input
            id="inv-note"
            className="input"
            placeholder="Who is this for?"
            value={note}
            onChange={(e) => setNote(e.target.value)}
            maxLength={512}
          />
        </div>
      </form>
    </Dialog>
  );
}
