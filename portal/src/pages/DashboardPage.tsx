/**
 * Dashboard: glanceable headline numbers + a 24h attempts chart + the most
 * recent attempts feed. Attempt buckets are computed client-side from the
 * feed (Prometheus-backed availability charts are M5b, not here).
 */

import { useMemo } from "react";
import { Link } from "react-router-dom";
import {
  Bar,
  BarChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { useAccounts, useAttempts, useInvites } from "../api/hooks";
import { isAllowedOutcome } from "../api/types";
import type { InviteCode, SigninAttempt } from "../api/types";
import {
  EmptyState,
  OutcomeBadge,
  RelTime,
  TableSkeleton,
} from "../components/ui";
import { hoursAgoIso } from "../lib/time";

/* ---- stat helpers ---- */

function inviteUsable(i: InviteCode, now: number): boolean {
  if (i.revoked_at) return false;
  if (i.expires_at && new Date(i.expires_at).getTime() < now) return false;
  if (i.max_uses != null && i.uses >= i.max_uses) return false;
  return true;
}

interface HourBucket {
  label: string;
  allowed: number;
  refused: number;
}

/** Bucket the last-24h feed into hours, oldest → newest. */
function bucketByHour(attempts: SigninAttempt[], now: number): HourBucket[] {
  const HOUR = 3_600_000;
  const buckets: HourBucket[] = [];
  const start = now - 23 * HOUR;
  for (let i = 0; i < 24; i++) {
    const t = new Date(start + i * HOUR);
    buckets.push({
      label: t.toLocaleTimeString(undefined, { hour: "numeric" }),
      allowed: 0,
      refused: 0,
    });
  }
  for (const a of attempts) {
    const t = new Date(a.ts).getTime();
    const idx = Math.floor((t - (start - HOUR / 2)) / HOUR);
    const b = buckets[Math.min(23, Math.max(0, idx))];
    if (t >= start - HOUR && b) {
      if (isAllowedOutcome(a.outcome)) b.allowed++;
      else b.refused++;
    }
  }
  return buckets;
}

export default function DashboardPage() {
  const now = Date.now();
  const since24h = useMemo(() => hoursAgoIso(24, now), [now]);

  const accounts = useAccounts();
  const invites = useInvites();
  const attempts24h = useAttempts({ since: since24h, limit: 1000 });

  const stats = useMemo(() => {
    const acc = accounts.data ?? [];
    const inv = invites.data ?? [];
    const att = attempts24h.data ?? [];
    const active = acc.filter((a) => a.status === "active").length;
    const blocked = acc.length - active;
    const devices = acc.reduce((n, a) => n + a.device_count, 0);
    const usable = inv.filter((i) => inviteUsable(i, now)).length;
    const allowed = att.filter((a) => isAllowedOutcome(a.outcome)).length;
    return {
      accounts: acc.length,
      active,
      blocked,
      devices,
      invitesUsable: usable,
      invitesTotal: inv.length,
      attempts: att.length,
      allowed,
      refused: att.length - allowed,
    };
  }, [accounts.data, invites.data, attempts24h.data, now]);

  const chartData = useMemo(
    () => bucketByHour(attempts24h.data ?? [], now),
    [attempts24h.data, now],
  );

  const recent = (attempts24h.data ?? []).slice(0, 8);
  const loading = accounts.isPending || invites.isPending || attempts24h.isPending;

  return (
    <div className="page">
      <div className="stat-grid">
        <div className="stat">
          <span className="stat-label">Accounts</span>
          <span className="stat-value">{loading ? "–" : stats.accounts}</span>
          <span className="stat-meta">
            <span className="pt" style={{ "--pt-color": "var(--ok)" } as React.CSSProperties}>
              {stats.active} active
            </span>
            <span className="pt" style={{ "--pt-color": "var(--danger)" } as React.CSSProperties}>
              {stats.blocked} blocked
            </span>
          </span>
        </div>
        <div className="stat">
          <span className="stat-label">Devices</span>
          <span className="stat-value">{loading ? "–" : stats.devices}</span>
          <span className="stat-meta">enrolled across all accounts</span>
        </div>
        <div className="stat">
          <span className="stat-label">Invites outstanding</span>
          <span className="stat-value">{loading ? "–" : stats.invitesUsable}</span>
          <span className="stat-meta">
            of {stats.invitesTotal} total · <Link to="/invites">manage</Link>
          </span>
        </div>
        <div className="stat">
          <span className="stat-label">Sign-ins · 24h</span>
          <span className="stat-value">{loading ? "–" : stats.attempts}</span>
          <span className="stat-meta">
            <span className="pt" style={{ "--pt-color": "var(--ok)" } as React.CSSProperties}>
              {stats.allowed} allowed
            </span>
            <span className="pt" style={{ "--pt-color": "var(--danger)" } as React.CSSProperties}>
              {stats.refused} refused
            </span>
          </span>
        </div>
      </div>

      <div className="dash-cols">
        <div className="panel">
          <div className="panel-head">
            <span className="panel-title">Sign-in attempts · last 24 hours</span>
          </div>
          <div className="chart-box">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={chartData} barCategoryGap={2}>
                <CartesianGrid stroke="var(--chart-grid)" vertical={false} />
                <XAxis
                  dataKey="label"
                  tick={{ fill: "var(--text-3)", fontSize: 10.5 }}
                  tickLine={false}
                  axisLine={{ stroke: "var(--border)" }}
                  interval={3}
                />
                <YAxis
                  allowDecimals={false}
                  width={28}
                  tick={{ fill: "var(--text-3)", fontSize: 10.5 }}
                  tickLine={false}
                  axisLine={false}
                />
                <Tooltip
                  cursor={{ fill: "var(--bg-hover)" }}
                  contentStyle={{
                    background: "var(--bg-raised)",
                    border: "1px solid var(--border-strong)",
                    borderRadius: 8,
                    fontSize: 12,
                    color: "var(--text-1)",
                  }}
                  labelStyle={{ color: "var(--text-2)" }}
                />
                <Bar dataKey="allowed" name="Allowed" stackId="a" fill="var(--ok)" radius={[0, 0, 0, 0]} />
                <Bar dataKey="refused" name="Refused" stackId="a" fill="var(--danger)" radius={[2, 2, 0, 0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>
          <div className="legend">
            <span className="li">
              <span className="sw" style={{ background: "var(--ok)" }} /> allowed
            </span>
            <span className="li">
              <span className="sw" style={{ background: "var(--danger)" }} /> refused
            </span>
          </div>
        </div>

        <div className="panel">
          <div className="panel-head">
            <span className="panel-title">Recent attempts</span>
            <Link to="/attempts" className="btn ghost small">
              View all
            </Link>
          </div>
          {attempts24h.isPending ? (
            <TableSkeleton rows={6} cols={3} />
          ) : recent.length === 0 ? (
            <EmptyState
              title="No sign-ins yet"
              hint="Attempts appear here the moment anyone hits the relay's sign-in path."
            />
          ) : (
            <div className="feed">
              {recent.map((a) => (
                <div className="feed-row" key={a.id}>
                  <span className="feed-time">
                    <RelTime iso={a.ts} />
                  </span>
                  <span className="feed-who" title={a.email}>
                    {a.email || "(no email)"}
                  </span>
                  <OutcomeBadge outcome={a.outcome} />
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
