/**
 * Service settings: the runtime sign-up policy (signup_mode), switchable
 * live — the relay applies it on the next sign-in decision, no restart.
 * A radio-group of the four modes with one-line descriptions; changing one
 * confirms first (it changes who can sign up, effective immediately), then
 * PUTs and refetches.
 */

import { useState } from "react";
import { useSettings, useUpdateSettings } from "../api/hooks";
import type { ServiceSettings, SignupMode } from "../api/types";
import { Dialog } from "../components/Dialog";
import { useToast } from "../components/Toast";
import { ErrorState } from "../components/ui";

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
