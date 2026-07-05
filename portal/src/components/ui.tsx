/** Small shared presentational pieces: badges, time, copy, empty/skeleton. */

import { useEffect, useState, type ReactNode } from "react";
import type { AccountStatus } from "../api/types";
import { outcomeMeta } from "../lib/outcomes";
import { absTime, relTime } from "../lib/time";

/* ---- Outcome + status badges ---- */

export function OutcomeBadge({ outcome }: { outcome: string }) {
  const meta = outcomeMeta(outcome);
  const tone = meta.tone === "neutral" ? "" : meta.tone;
  return (
    <span className={`badge ${tone}`}>
      <span className="dot" />
      {meta.label}
    </span>
  );
}

export function StatusBadge({ status }: { status: AccountStatus }) {
  return status === "active" ? (
    <span className="badge ok">
      <span className="dot" />
      Active
    </span>
  ) : (
    <span className="badge danger">
      <span className="dot" />
      Blocked
    </span>
  );
}

/* ---- Relative timestamp with absolute on hover ---- */

/** Shared 30s ticker so hundreds of cells don't each own a timer. */
function useNow(): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), 30_000);
    return () => window.clearInterval(id);
  }, []);
  return now;
}

export function RelTime({ iso }: { iso: string }) {
  const now = useNow();
  return (
    <time dateTime={iso} title={absTime(iso)}>
      {relTime(iso, now)}
    </time>
  );
}

/* ---- Copy-to-clipboard ---- */

export function CopyButton({ text, label }: { text: string; label?: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      className={`icon-btn ${copied ? "copied" : ""}`}
      aria-label={label ?? `Copy ${text}`}
      title={copied ? "Copied" : (label ?? "Copy")}
      onClick={(e) => {
        e.stopPropagation();
        void navigator.clipboard.writeText(text).then(() => {
          setCopied(true);
          window.setTimeout(() => setCopied(false), 1500);
        });
      }}
    >
      {copied ? (
        <svg width="13" height="13" viewBox="0 0 14 14" fill="none">
          <path
            d="M2.5 7.5l3 3 6-6"
            stroke="currentColor"
            strokeWidth="1.6"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      ) : (
        <svg width="13" height="13" viewBox="0 0 14 14" fill="none">
          <rect
            x="4.5"
            y="4.5"
            width="7"
            height="7"
            rx="1.5"
            stroke="currentColor"
            strokeWidth="1.2"
          />
          <path
            d="M9.5 4.5v-1a1.5 1.5 0 00-1.5-1.5H4A1.5 1.5 0 002.5 3.5v4A1.5 1.5 0 004 9h.5"
            stroke="currentColor"
            strokeWidth="1.2"
          />
        </svg>
      )}
    </button>
  );
}

/* ---- Empty / error / skeleton states ---- */

export function EmptyState({
  glyph = "👻",
  title,
  hint,
  action,
}: {
  glyph?: string;
  title: string;
  hint?: string;
  action?: ReactNode;
}) {
  return (
    <div className="empty">
      <div className="empty-glyph">{glyph}</div>
      <div className="empty-title">{title}</div>
      {hint && <div className="empty-hint">{hint}</div>}
      {action}
    </div>
  );
}

export function ErrorState({ error, retry }: { error: unknown; retry?: () => void }) {
  return (
    <div className="error-box" role="alert">
      <div className="error-title">Something went wrong</div>
      <div className="error-detail">
        {error instanceof Error ? error.message : String(error)}
      </div>
      {retry && (
        <button className="btn" onClick={retry}>
          Retry
        </button>
      )}
    </div>
  );
}

/** Table-shaped loading skeleton. */
export function TableSkeleton({ rows = 6, cols = 4 }: { rows?: number; cols?: number }) {
  return (
    <div style={{ padding: "var(--sp-4)" }} aria-hidden data-testid="skeleton">
      {Array.from({ length: rows }, (_, r) => (
        <div key={r} className="row" style={{ marginBottom: "var(--sp-3)", gap: "var(--sp-4)" }}>
          {Array.from({ length: cols }, (_, c) => (
            <div
              key={c}
              className="skeleton"
              style={{
                height: 14,
                flex: c === 0 ? 2 : 1,
                opacity: 1 - r * 0.09,
              }}
            />
          ))}
        </div>
      ))}
    </div>
  );
}

/* ---- Truncated mono id with copy (subs, ids) ---- */

export function MonoId({ value, chars = 12 }: { value: string; chars?: number }) {
  if (!value) return <span className="cell-mono">—</span>;
  const shown = value.length > chars ? `${value.slice(0, chars)}…` : value;
  return (
    <span className="row" style={{ gap: 2, display: "inline-flex" }}>
      <span className="cell-mono" title={value}>
        {shown}
      </span>
      <CopyButton text={value} label="Copy full value" />
    </span>
  );
}
