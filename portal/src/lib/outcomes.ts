/** Presentation metadata for sign-in outcomes: label, tone, chart color. */

import type { Outcome } from "../api/types";

export type Tone = "ok" | "danger" | "warn" | "orange" | "neutral";

interface OutcomeMeta {
  label: string;
  tone: Tone;
  /** Token-based color used for chart fills and mini bars. */
  cssVar: string;
}

export const OUTCOME_META: Record<Outcome, OutcomeMeta> = {
  allowed: { label: "Allowed", tone: "ok", cssVar: "var(--ok)" },
  blocked: { label: "Blocked", tone: "danger", cssVar: "var(--danger)" },
  no_account: { label: "No account", tone: "warn", cssVar: "var(--warn)" },
  bad_invite: { label: "Bad invite", tone: "orange", cssVar: "var(--orange)" },
  expired_invite: {
    label: "Expired invite",
    tone: "orange",
    cssVar: "var(--orange)",
  },
  revoked_invite: {
    label: "Revoked invite",
    tone: "orange",
    cssVar: "var(--orange)",
  },
  exhausted_invite: {
    label: "Exhausted invite",
    tone: "orange",
    cssVar: "var(--orange)",
  },
  not_verified: {
    label: "Not verified",
    tone: "neutral",
    cssVar: "var(--text-3)",
  },
};

export function outcomeMeta(outcome: string): OutcomeMeta {
  return (
    OUTCOME_META[outcome as Outcome] ?? {
      label: outcome,
      tone: "neutral",
      cssVar: "var(--text-3)",
    }
  );
}
