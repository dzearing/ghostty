/** Relative + absolute time formatting shared by all tables and feeds. */

const MIN = 60_000;
const HOUR = 3_600_000;
const DAY = 86_400_000;

/** Compact relative timestamp: "12s", "4m", "3h", "2d", then a date. */
export function relTime(iso: string, now: number = Date.now()): string {
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return "—";
  const d = now - t;
  if (d < 0) return inTime(-d);
  if (d < MIN) return `${Math.max(0, Math.floor(d / 1000))}s ago`;
  if (d < HOUR) return `${Math.floor(d / MIN)}m ago`;
  if (d < DAY) return `${Math.floor(d / HOUR)}h ago`;
  if (d < 14 * DAY) return `${Math.floor(d / DAY)}d ago`;
  return new Date(t).toLocaleDateString();
}

/** Future variant for expiries: "in 3h", "in 5d". */
export function inTime(deltaMs: number): string {
  if (deltaMs < MIN) return "in <1m";
  if (deltaMs < HOUR) return `in ${Math.floor(deltaMs / MIN)}m`;
  if (deltaMs < DAY) return `in ${Math.floor(deltaMs / HOUR)}h`;
  return `in ${Math.floor(deltaMs / DAY)}d`;
}

/** Full absolute timestamp for hover titles. */
export function absTime(iso: string): string {
  const t = new Date(iso);
  if (Number.isNaN(t.getTime())) return iso;
  return t.toLocaleString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

/** RFC3339 for the `since` filter, N hours back from now. */
export function hoursAgoIso(hours: number, now: number = Date.now()): string {
  return new Date(now - hours * HOUR).toISOString();
}
