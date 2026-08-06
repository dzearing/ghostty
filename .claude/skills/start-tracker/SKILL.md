---
name: start-tracker
description: Use when the user asks to start the tracker, open the task dashboard, or resume tracking ("start tracker", "open the dashboard", "show the parity dashboard"). Starts the Windows-parity task dashboard in a Ghoztty side pane AND catches up the daily digest if one is due.
---

# Start the parity tracker

Two halves, always both:

## 1. Start the dashboard

```powershell
powershell -NoProfile -File scripts\task-dashboard.ps1
```

Idempotent: an already-running server is reused and an existing `tasks` pane is
focused, not duplicated. If ghoztty is not on PATH the script prints the URL to
open by hand.

## 2. Digest catch-up (no backfill)

The tracker has a **Daily digest** view that expects one entry per day, written
at 5am by the go-loop (go.md step 0.5). If Claude was shut down over that
boundary, the digest is missing — so on tracker startup:

1. Compute today's local date `YYYY-MM-DD`.
2. If the local time is **before 5am**, do nothing (today's digest is not due
   yet).
3. If `docs/design/windows-parity-digests/<today>.md` exists, do nothing.
4. Otherwise write today's digest now, following the content rules in go.md
   step 0.5 ("Daily digest"): frontmatter `date: "YYYY-MM-DD"`, then markdown
   sections **Yesterday**, **Today's focus**, **Reflection**, **Decisions** —
   written for the user over coffee, from evidence (`git log` since yesterday
   5am, `docs/design/windows-parity-log.md`, the dashboard payload via
   `node scripts\task-dashboard.js --once`, resolved decisions).

**Never backfill older days.** If several days are missing, write today's only
— a digest is a morning read, not a ledger, and a backfilled reflection is
fiction. The dashboard picks the new file up within one poll; no restart
needed.
