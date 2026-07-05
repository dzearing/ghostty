/**
 * Account detail: metadata, block state, actions, devices (with live online
 * status), and per-outcome sign-in attempt counts (GET /accounts/{id}/usage).
 */

import { useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { useAccountUsage, useUnblockAccount } from "../api/hooks";
import { isApiError } from "../api/client";
import { BlockDialog, DeleteDialog } from "../components/AccountDialogs";
import { useToast } from "../components/Toast";
import {
  EmptyState,
  ErrorState,
  MonoId,
  RelTime,
  StatusBadge,
  TableSkeleton,
} from "../components/ui";
import { outcomeMeta } from "../lib/outcomes";

export default function AccountDetailPage() {
  const { id = "" } = useParams();
  const query = useAccountUsage(id);
  const unblock = useUnblockAccount();
  const toast = useToast();
  const navigate = useNavigate();
  const [blocking, setBlocking] = useState(false);
  const [deleting, setDeleting] = useState(false);

  if (query.isPending) {
    return (
      <div className="page">
        <div className="panel">
          <TableSkeleton rows={5} cols={3} />
        </div>
      </div>
    );
  }

  if (query.isError) {
    const notFound = isApiError(query.error) && query.error.status === 404;
    return (
      <div className="page">
        <div className="panel">
          {notFound ? (
            <EmptyState
              glyph="🫥"
              title="Account not found"
              hint="It may have been deleted."
              action={
                <Link className="btn" to="/accounts">
                  Back to accounts
                </Link>
              }
            />
          ) : (
            <ErrorState error={query.error} retry={() => void query.refetch()} />
          )}
        </div>
      </div>
    );
  }

  const { account, devices, signin_attempts } = query.data;
  const outcomes = Object.entries(signin_attempts).sort((a, b) => b[1] - a[1]);
  const maxCount = Math.max(1, ...outcomes.map(([, n]) => n));
  const online = devices.filter((d) => d.online).length;

  return (
    <div className="page">
      <div className="row" style={{ gap: "var(--sp-1)" }}>
        <Link to="/accounts" className="btn ghost small">
          ← Accounts
        </Link>
      </div>

      <div className="panel">
        <div className="panel-head">
          <div className="row">
            <span className="panel-title">{account.email}</span>
            <StatusBadge status={account.status} />
            {account.is_admin && <span className="badge accent">admin</span>}
          </div>
          <div className="row">
            {account.status === "active" ? (
              <button className="btn small" onClick={() => setBlocking(true)}>
                Block
              </button>
            ) : (
              <button
                className="btn small"
                disabled={unblock.isPending}
                onClick={() =>
                  unblock.mutate(account.id, {
                    onSuccess: () => toast.ok(`Unblocked ${account.email}`),
                    onError: (e) => toast.error(`Unblock failed: ${e.message}`),
                  })
                }
              >
                Unblock
              </button>
            )}
            <button className="btn small danger" onClick={() => setDeleting(true)}>
              Delete
            </button>
          </div>
        </div>
        <div className="panel-body">
          <div className="kv-grid">
            <span className="k">Account ID</span>
            <span className="v mono">
              <MonoId value={account.id} chars={36} />
            </span>
            <span className="k">Google sub</span>
            <span className="v mono">
              {account.google_sub ? <MonoId value={account.google_sub} chars={30} /> : "not bound yet"}
            </span>
            <span className="k">Created</span>
            <span className="v">
              <RelTime iso={account.created_at} />
            </span>
            <span className="k">Invited by</span>
            <span className="v mono">{account.invited_by_code || "— (migrated owner)"}</span>
            {account.status === "blocked" && (
              <>
                <span className="k">Blocked</span>
                <span className="v">
                  {account.blocked_at ? <RelTime iso={account.blocked_at} /> : "yes"}
                  {account.blocked_reason && (
                    <span className="cell-dim"> — “{account.blocked_reason}”</span>
                  )}
                </span>
              </>
            )}
          </div>
        </div>
      </div>

      <div className="dash-cols">
        <div className="panel">
          <div className="panel-head">
            <span className="panel-title">
              Devices · {devices.length} ({online} online)
            </span>
          </div>
          {devices.length === 0 ? (
            <EmptyState
              glyph="💻"
              title="No devices"
              hint="This account has not enrolled any machines."
            />
          ) : (
            <div className="tbl-wrap">
              <table className="tbl">
                <thead>
                  <tr>
                    <th>Device</th>
                    <th style={{ width: 90 }}>State</th>
                    <th style={{ width: 110 }}>Enrolled</th>
                  </tr>
                </thead>
                <tbody>
                  {devices.map((d) => (
                    <tr key={d.id}>
                      <td>
                        <div className="row">
                          <span className={`online-dot ${d.online ? "on" : ""}`} />
                          <span className="cell-main">{d.name}</span>
                        </div>
                        <div className="cell-sub">{d.hostname || d.id}</div>
                      </td>
                      <td>
                        {d.online ? (
                          <span className="badge ok">online</span>
                        ) : (
                          <span className="badge">offline</span>
                        )}
                      </td>
                      <td className="cell-dim">
                        <RelTime iso={d.created_at} />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>

        <div className="panel">
          <div className="panel-head">
            <span className="panel-title">Sign-in attempts by outcome</span>
            <Link to="/attempts" className="btn ghost small">
              Open feed
            </Link>
          </div>
          <div className="panel-body">
            {outcomes.length === 0 ? (
              <EmptyState
                title="No attempts recorded"
                hint="Sign-in attempts for this account will appear here."
              />
            ) : (
              <div className="outcome-bars">
                {outcomes.map(([outcome, n]) => {
                  const meta = outcomeMeta(outcome);
                  return (
                    <div className="outcome-bar" key={outcome}>
                      <span>{meta.label}</span>
                      <span className="bar-track">
                        <span
                          className="bar-fill"
                          style={{
                            width: `${(n / maxCount) * 100}%`,
                            background: meta.cssVar,
                          }}
                        />
                      </span>
                      <span className="bar-n">{n}</span>
                    </div>
                  );
                })}
              </div>
            )}
          </div>
        </div>
      </div>

      {blocking && <BlockDialog account={account} onClose={() => setBlocking(false)} />}
      {deleting && (
        <DeleteDialog
          account={account}
          onClose={() => setDeleting(false)}
          onDeleted={() => navigate("/accounts")}
        />
      )}
    </div>
  );
}
