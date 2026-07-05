/**
 * Accounts: server-side search (q = email substring) + status filter, inline
 * block/unblock/delete, row click → detail. Search debounces 200ms and keeps
 * previous rows while refetching so typing feels instant.
 */

import { useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAccounts, useUnblockAccount } from "../api/hooks";
import type { Account, AccountStatus } from "../api/types";
import { BlockDialog, DeleteDialog } from "../components/AccountDialogs";
import { useToast } from "../components/Toast";
import {
  EmptyState,
  ErrorState,
  RelTime,
  StatusBadge,
  TableSkeleton,
} from "../components/ui";

function useDebounced<T>(value: T, ms: number): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const id = window.setTimeout(() => setDebounced(value), ms);
    return () => window.clearTimeout(id);
  }, [value, ms]);
  return debounced;
}

export default function AccountsPage() {
  const [q, setQ] = useState("");
  const [status, setStatus] = useState<AccountStatus | "">("");
  const [blockTarget, setBlockTarget] = useState<Account | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<Account | null>(null);
  const searchRef = useRef<HTMLInputElement>(null);
  const navigate = useNavigate();
  const toast = useToast();

  const debouncedQ = useDebounced(q, 200);
  const query = useAccounts({
    q: debouncedQ.trim() || undefined,
    status: status || undefined,
  });
  const unblock = useUnblockAccount();

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

  const doUnblock = (a: Account) =>
    unblock.mutate(a.id, {
      onSuccess: () => toast.ok(`Unblocked ${a.email}`),
      onError: (e) => toast.error(`Unblock failed: ${e.message}`),
    });

  const rows = query.data ?? [];

  return (
    <div className="page">
      <div className="toolbar">
        <div className="chip-row" role="group" aria-label="Status filter">
          <button className={`chip ${status === "" ? "on" : ""}`} onClick={() => setStatus("")}>
            All
          </button>
          <button
            className={`chip ${status === "active" ? "on" : ""}`}
            onClick={() => setStatus(status === "active" ? "" : "active")}
          >
            Active
          </button>
          <button
            className={`chip ${status === "blocked" ? "on" : ""}`}
            onClick={() => setStatus(status === "blocked" ? "" : "blocked")}
          >
            Blocked
          </button>
        </div>
        <div className="spacer" />
        <div className="search">
          <svg className="search-icon" viewBox="0 0 16 16" fill="none">
            <circle cx="7" cy="7" r="4.5" stroke="currentColor" strokeWidth="1.3" />
            <path d="M10.5 10.5L14 14" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
          </svg>
          <input
            ref={searchRef}
            className="input"
            placeholder="Search email…"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            aria-label="Search accounts"
          />
          <kbd>/</kbd>
        </div>
      </div>

      <div className="panel">
        {query.isPending ? (
          <TableSkeleton rows={6} cols={5} />
        ) : query.isError ? (
          <ErrorState error={query.error} retry={() => void query.refetch()} />
        ) : rows.length === 0 ? (
          <EmptyState
            title={q || status ? "No matching accounts" : "No accounts yet"}
            hint={
              q || status
                ? "Adjust the search or status filter."
                : "Accounts appear when someone signs up with an invite code."
            }
          />
        ) : (
          <div className="tbl-wrap">
            <table className="tbl">
              <thead>
                <tr>
                  <th>Account</th>
                  <th style={{ width: 110 }}>Status</th>
                  <th className="num" style={{ width: 80 }}>
                    Devices
                  </th>
                  <th style={{ width: 110 }}>Invited by</th>
                  <th style={{ width: 100 }}>Created</th>
                  <th className="actions" style={{ width: 180 }} />
                </tr>
              </thead>
              <tbody>
                {rows.map((a) => (
                  <tr
                    key={a.id}
                    className="clickable"
                    tabIndex={0}
                    onClick={() => navigate(`/accounts/${a.id}`)}
                    onKeyDown={(e) => {
                      if (e.key === "Enter") navigate(`/accounts/${a.id}`);
                    }}
                  >
                    <td>
                      <div className="row">
                        <span className="cell-main">{a.email}</span>
                        {a.is_admin && <span className="badge accent">admin</span>}
                      </div>
                      <div className="cell-sub" title={a.google_sub}>
                        {a.google_sub || "no sub bound"}
                      </div>
                    </td>
                    <td>
                      <StatusBadge status={a.status} />
                    </td>
                    <td className="num">{a.device_count}</td>
                    <td className="cell-mono">{a.invited_by_code || "—"}</td>
                    <td className="cell-dim">
                      <RelTime iso={a.created_at} />
                    </td>
                    <td className="actions" onClick={(e) => e.stopPropagation()}>
                      {a.status === "active" ? (
                        <button className="btn small" onClick={() => setBlockTarget(a)}>
                          Block
                        </button>
                      ) : (
                        <button
                          className="btn small"
                          onClick={() => doUnblock(a)}
                          disabled={unblock.isPending}
                        >
                          Unblock
                        </button>
                      )}{" "}
                      <button className="btn small danger" onClick={() => setDeleteTarget(a)}>
                        Delete
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {blockTarget && (
        <BlockDialog account={blockTarget} onClose={() => setBlockTarget(null)} />
      )}
      {deleteTarget && (
        <DeleteDialog account={deleteTarget} onClose={() => setDeleteTarget(null)} />
      )}
    </div>
  );
}
