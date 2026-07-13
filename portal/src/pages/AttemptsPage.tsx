/**
 * Sign-in attempts: dense filterable feed.
 *
 * Server-side filters (the M2 API): outcome (exact), since, limit.
 * The search box filters CLIENT-side (substring over email/sub/IP within the
 * fetched window) because the API's email param is exact-match only — local
 * substring search over the window is instant and more forgiving. Press "/"
 * to focus search.
 */

import { useEffect, useMemo, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { useAttempts } from "../api/hooks";
import { ALL_OUTCOMES, type Outcome } from "../api/types";
import {
  EmptyState,
  ErrorState,
  MonoId,
  OutcomeBadge,
  RelTime,
  TableSkeleton,
} from "../components/ui";
import { outcomeMeta } from "../lib/outcomes";
import { hoursAgoIso } from "../lib/time";

const SINCE_PRESETS = [
  { key: "1h", label: "1h", hours: 1 },
  { key: "24h", label: "24h", hours: 24 },
  { key: "7d", label: "7d", hours: 168 },
  { key: "all", label: "All", hours: 0 },
] as const;

type SinceKey = (typeof SINCE_PRESETS)[number]["key"];

const LIMITS = [100, 250, 500, 1000];

export default function AttemptsPage() {
  const [outcome, setOutcome] = useState<Outcome | "">("");
  const [sinceKey, setSinceKey] = useState<SinceKey>("24h");
  const [limit, setLimit] = useState(250);
  const [search, setSearch] = useState("");
  const searchRef = useRef<HTMLInputElement>(null);

  // "/" focuses search from anywhere on the page.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (
        e.key === "/" &&
        !(e.target instanceof HTMLInputElement) &&
        !(e.target instanceof HTMLTextAreaElement)
      ) {
        e.preventDefault();
        searchRef.current?.focus();
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  const since = useMemo(() => {
    const preset = SINCE_PRESETS.find((p) => p.key === sinceKey)!;
    return preset.hours ? hoursAgoIso(preset.hours) : undefined;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sinceKey, outcome, limit]); // re-anchor "now" when any filter changes

  const query = useAttempts({
    outcome: outcome || undefined,
    since,
    limit,
  });

  const rows = useMemo(() => {
    const all = query.data ?? [];
    const q = search.trim().toLowerCase();
    if (!q) return all;
    return all.filter(
      (a) =>
        a.email.toLowerCase().includes(q) ||
        a.google_sub.toLowerCase().includes(q) ||
        a.ip.includes(q),
    );
  }, [query.data, search]);

  return (
    <div className="page">
      <div className="toolbar">
        <div className="chip-row" role="group" aria-label="Outcome filter">
          <button
            className={`chip ${outcome === "" ? "on" : ""}`}
            onClick={() => setOutcome("")}
          >
            All
          </button>
          {ALL_OUTCOMES.map((o) => (
            <button
              key={o}
              className={`chip ${outcome === o ? "on" : ""}`}
              onClick={() => setOutcome(outcome === o ? "" : o)}
            >
              {outcomeMeta(o).label}
            </button>
          ))}
        </div>
        <div className="spacer" />
        <div className="chip-row" role="group" aria-label="Time window">
          {SINCE_PRESETS.map((p) => (
            <button
              key={p.key}
              className={`chip ${sinceKey === p.key ? "on" : ""}`}
              onClick={() => setSinceKey(p.key)}
            >
              {p.label}
            </button>
          ))}
        </div>
        <select
          className="select"
          value={limit}
          onChange={(e) => setLimit(Number(e.target.value))}
          aria-label="Row limit"
        >
          {LIMITS.map((n) => (
            <option key={n} value={n}>
              {n} rows
            </option>
          ))}
        </select>
        <div className="search">
          <svg className="search-icon" viewBox="0 0 16 16" fill="none">
            <circle cx="7" cy="7" r="4.5" stroke="currentColor" strokeWidth="1.3" />
            <path d="M10.5 10.5L14 14" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
          </svg>
          <input
            ref={searchRef}
            className="input"
            placeholder="Filter email, sub, IP…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            aria-label="Filter attempts"
          />
          <kbd>/</kbd>
        </div>
      </div>

      <div className="panel">
        {query.isPending ? (
          <TableSkeleton rows={8} cols={5} />
        ) : query.isError ? (
          <ErrorState error={query.error} retry={() => void query.refetch()} />
        ) : rows.length === 0 ? (
          <EmptyState
            title={search || outcome ? "Nothing matches" : "No attempts in this window"}
            hint={
              search || outcome
                ? "Loosen the outcome filter, widen the time window, or clear the search."
                : "Widen the time window, or wait — new attempts stream in automatically."
            }
          />
        ) : (
          <div className="tbl-wrap">
            <table className="tbl">
              <thead>
                <tr>
                  <th style={{ width: 90 }}>When</th>
                  <th>Identity</th>
                  <th style={{ width: 140 }}>Outcome</th>
                  <th style={{ width: 130 }}>IP</th>
                  <th style={{ width: 100 }}>Account</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((a) => (
                  <tr key={a.id}>
                    <td className="cell-dim">
                      <RelTime iso={a.ts} />
                    </td>
                    <td>
                      <div className="cell-main">{a.email || "(no email)"}</div>
                      <div className="cell-sub">
                        {a.google_sub ? (
                          <MonoId value={a.google_sub} chars={18} />
                        ) : (
                          "—"
                        )}
                      </div>
                    </td>
                    <td>
                      <OutcomeBadge outcome={a.outcome} />
                    </td>
                    <td className="cell-mono">{a.ip || "—"}</td>
                    <td>
                      {a.account_id ? (
                        <Link to={`/accounts/${a.account_id}`}>view</Link>
                      ) : (
                        <span className="cell-dim">—</span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {query.data && (
        <div className="page-intro">
          {rows.length === query.data.length
            ? `${rows.length} attempt${rows.length === 1 ? "" : "s"}`
            : `${rows.length} of ${query.data.length} fetched attempts match`}
          {query.data.length === limit && " · window full — raise the row limit for more"}
        </div>
      )}
    </div>
  );
}
