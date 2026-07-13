/**
 * Service settings: the runtime sign-up policy (signup_mode), switchable
 * live — the relay applies it on the next sign-in decision, no restart.
 * A radio-group of the four modes with one-line descriptions; changing one
 * confirms first (it changes who can sign up, effective immediately), then
 * PUTs and refetches.
 *
 * Below it: the sign-in allowlist. DB entries are portal-managed (add with
 * an optional note, remove with confirm — live, no restart); env entries
 * (ALLOWED_EMAILS) are the bootstrap/recovery half — badged, immutable here.
 * The list only gates sign-in in Allowlist mode but is editable in any mode
 * so it can be staged before switching.
 */

import { useState, type FormEvent } from "react";
import {
  useAddAllowlistEmail,
  useAllowlist,
  useRemoveAllowlistEmail,
  useSettings,
  useUpdateSettings,
} from "../api/hooks";
import type { AllowlistEntry, ServiceSettings, SignupMode } from "../api/types";
import { isApiError } from "../api/client";
import { Dialog } from "../components/Dialog";
import { useToast } from "../components/Toast";
import { EmptyState, ErrorState, RelTime, TableSkeleton } from "../components/ui";

interface ModeMeta {
  mode: SignupMode;
  label: string;
  desc: string;
}

const MODES: ModeMeta[] = [
  {
    mode: "open",
    label: "Open",
    desc: "Anyone with a Google account can sign up.",
  },
  {
    mode: "invite",
    label: "Invite only",
    desc: "New users need an invite code; existing accounts are unaffected.",
  },
  {
    mode: "closed",
    label: "Closed",
    desc: "No new signups. Existing accounts keep working.",
  },
  {
    mode: "allowlist",
    label: "Allowlist",
    desc: "Legacy env-var gate (ALLOWED_EMAILS). Only listed emails sign in.",
  },
];

const modeLabel = (m: SignupMode) =>
  MODES.find((x) => x.mode === m)?.label ?? m;

export default function SettingsPage() {
  const query = useSettings();

  return (
    <div className="page">
      <div className="page-intro">
        Runtime service flags. Changes apply to the live relay immediately —
        no deploy, no restart.
      </div>

      <div className="panel">
        <div className="panel-head">
          <div className="panel-title">Sign-up policy</div>
          {query.data && (
            <span
              className={`badge ${query.data.source === "db" ? "accent" : "warn"}`}
              title={
                query.data.source === "db"
                  ? "This mode was set from the portal and is stored in the database."
                  : "No mode has been set from the portal yet — the server environment (SIGNUP_MODE / INVITE_SIGNUP) is providing the default."
              }
            >
              {query.data.source === "db" ? "set via portal" : "env default"}
            </span>
          )}
        </div>
        <div className="panel-body">
          {query.isPending ? (
            <div className="mode-list" aria-hidden>
              {MODES.map((m) => (
                <div key={m.mode} className="mode-option skeleton" />
              ))}
            </div>
          ) : query.isError ? (
            <ErrorState error={query.error} retry={() => void query.refetch()} />
          ) : (
            <SignupModePicker settings={query.data} />
          )}
        </div>
      </div>

      <AllowlistPanel mode={query.data?.signup_mode} />
    </div>
  );
}

function SignupModePicker({ settings }: { settings: ServiceSettings }) {
  const update = useUpdateSettings();
  const toast = useToast();
  const [pending, setPending] = useState<SignupMode | null>(null);

  const current = settings.signup_mode;

  const confirm = (mode: SignupMode) => {
    update.mutate(mode, {
      onSuccess: (s) => {
        toast.ok(`Sign-up policy is now “${modeLabel(s.signup_mode)}”`);
        setPending(null);
      },
      onError: (e) => toast.error(`Change failed: ${e.message}`),
    });
  };

  return (
    <>
      <div className="mode-list" role="radiogroup" aria-label="Sign-up policy">
        {MODES.map((m) => {
          const on = m.mode === current;
          return (
            <button
              key={m.mode}
              type="button"
              role="radio"
              aria-checked={on}
              className={`mode-option ${on ? "on" : ""}`}
              onClick={() => {
                if (!on) setPending(m.mode);
              }}
            >
              <span className="mode-radio" aria-hidden />
              <span className="mode-text">
                <span className="mode-label">
                  {m.label}
                  {on && <span className="badge accent">current</span>}
                </span>
                <span className="mode-desc">{m.desc}</span>
              </span>
            </button>
          );
        })}
      </div>

      {pending && (
        <Dialog
          title="Change sign-up policy"
          onClose={() => setPending(null)}
          footer={
            <>
              <button
                className="btn ghost"
                onClick={() => setPending(null)}
                disabled={update.isPending}
              >
                Cancel
              </button>
              <button
                className="btn primary"
                onClick={() => confirm(pending)}
                disabled={update.isPending}
              >
                {update.isPending
                  ? "Applying…"
                  : `Switch to ${modeLabel(pending)}`}
              </button>
            </>
          }
        >
          <p>
            Switch the sign-up policy from{" "}
            <strong>{modeLabel(current)}</strong> to{" "}
            <strong>{modeLabel(pending)}</strong>?
          </p>
          <p>
            This changes who can sign up, <strong>effective immediately</strong>.
            Existing accounts are not affected.
          </p>
        </Dialog>
      )}
    </>
  );
}

/* ---- Allowlist ---- */

function AllowlistPanel({ mode }: { mode?: SignupMode }) {
  const query = useAllowlist();

  return (
    <div className="panel" style={{ marginTop: "var(--sp-5)" }}>
      <div className="panel-head">
        <div className="panel-title">Allowlist</div>
        {mode && mode !== "allowlist" && (
          <span
            className="badge"
            title="The allowlist can be edited in any mode, but sign-in is only gated by it while the sign-up policy is Allowlist."
          >
            Only enforced in Allowlist mode
          </span>
        )}
      </div>
      <div className="panel-body">
        <p className="page-intro" style={{ marginTop: 0 }}>
          Emails allowed to sign in under the Allowlist policy. Changes apply
          live. Entries marked <span className="badge warn">env</span> come
          from the server's <code>ALLOWED_EMAILS</code> variable — the
          bootstrap/recovery list — and can only be changed on the server.
        </p>

        <AddAllowlistForm />

        {query.isPending ? (
          <TableSkeleton rows={3} cols={3} />
        ) : query.isError ? (
          <ErrorState error={query.error} retry={() => void query.refetch()} />
        ) : (
          <AllowlistTable entries={query.data} />
        )}
      </div>
    </div>
  );
}

function AddAllowlistForm() {
  const add = useAddAllowlistEmail();
  const toast = useToast();
  const [email, setEmail] = useState("");
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);

  const submit = (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    const addr = email.trim().toLowerCase();
    if (!addr) return;
    add.mutate(
      { email: addr, note: note.trim() || undefined },
      {
        onSuccess: (entry) => {
          toast.ok(`Added ${entry.email} to the allowlist`);
          setEmail("");
          setNote("");
        },
        onError: (err) => {
          if (isApiError(err) && err.status === 409) {
            setError(`${addr} is already on the allowlist.`);
          } else if (isApiError(err) && err.status === 400) {
            setError(`“${addr}” doesn't look like a valid email address.`);
          } else {
            setError(err.message);
          }
        },
      },
    );
  };

  return (
    <form
      className="stack"
      style={{ gap: "var(--sp-3)", marginBottom: "var(--sp-4)" }}
      onSubmit={submit}
    >
      {error && (
        <div className="callout" role="alert">
          {error}
        </div>
      )}
      <div className="row" style={{ gap: "var(--sp-3)", alignItems: "flex-end" }}>
        <div className="field grow">
          <label htmlFor="al-email">Email</label>
          <input
            id="al-email"
            className="input"
            type="email"
            placeholder="person@example.com"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            maxLength={254}
            autoComplete="off"
            required
          />
        </div>
        <div className="field grow">
          <label htmlFor="al-note">Note</label>
          <input
            id="al-note"
            className="input"
            placeholder="Who is this? (optional)"
            value={note}
            onChange={(e) => setNote(e.target.value)}
            maxLength={512}
          />
        </div>
        <button className="btn primary" type="submit" disabled={add.isPending}>
          {add.isPending ? "Adding…" : "Add"}
        </button>
      </div>
    </form>
  );
}

function AllowlistTable({ entries }: { entries: AllowlistEntry[] }) {
  const remove = useRemoveAllowlistEmail();
  const toast = useToast();
  const [removeTarget, setRemoveTarget] = useState<AllowlistEntry | null>(null);

  const doRemove = (entry: AllowlistEntry) => {
    remove.mutate(entry.email, {
      onSuccess: () => {
        toast.ok(`Removed ${entry.email} from the allowlist`);
        setRemoveTarget(null);
      },
      onError: (e) => toast.error(`Remove failed: ${e.message}`),
    });
  };

  if (entries.length === 0) {
    return (
      <EmptyState
        glyph="📧"
        title="No allowlisted emails"
        hint="Add an email above to let it sign in under the Allowlist policy."
      />
    );
  }

  return (
    <>
      <div className="tbl-wrap">
        <table className="tbl">
          <thead>
            <tr>
              <th>Email</th>
              <th style={{ width: 90 }}>Source</th>
              <th>Note</th>
              <th style={{ width: 110 }}>Added</th>
              <th className="actions" style={{ width: 90 }} />
            </tr>
          </thead>
          <tbody>
            {entries.map((entry) => (
              <tr key={entry.email}>
                <td>
                  <span className="cell-main mono">{entry.email}</span>
                </td>
                <td>
                  {entry.source === "env" ? (
                    <span
                      className="badge warn"
                      title="From the ALLOWED_EMAILS server environment variable — the bootstrap/recovery list. It cannot be edited from the portal."
                    >
                      env
                    </span>
                  ) : (
                    <span
                      className="badge accent"
                      title="Added from the portal; stored in the database."
                    >
                      portal
                    </span>
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
                    title={entry.note}
                  >
                    {entry.note || "—"}
                  </span>
                </td>
                <td className="cell-dim">
                  {entry.created_at ? <RelTime iso={entry.created_at} /> : "—"}
                </td>
                <td className="actions">
                  {entry.source === "db" && (
                    <button
                      className="btn small danger"
                      onClick={() => setRemoveTarget(entry)}
                    >
                      Remove
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {removeTarget && (
        <Dialog
          title="Remove from allowlist"
          onClose={() => setRemoveTarget(null)}
          footer={
            <>
              <button className="btn ghost" onClick={() => setRemoveTarget(null)}>
                Cancel
              </button>
              <button
                className="btn danger-solid"
                onClick={() => doRemove(removeTarget)}
                disabled={remove.isPending}
              >
                {remove.isPending ? "Removing…" : "Remove email"}
              </button>
            </>
          }
        >
          <p>
            Remove <strong className="mono">{removeTarget.email}</strong> from
            the allowlist? Under the Allowlist policy they can no longer sign
            in, <strong>effective immediately</strong>. Their account and
            devices are not deleted.
          </p>
        </Dialog>
      )}
    </>
  );
}
