- **`/triage`'s cull path no longer closes an issue another session is
  building** (#1220). The board claim is a cross-session lock, and the cull
  read straight past it: on 2026-08-08 a concurrent `/triage` closed an issue
  claimed 30 minutes earlier — with a green PR already open carrying its
  `Closes #N` — and stripped the foreign session's claim stamp as part of its
  own Done bookkeeping, silently orphaning the PR's issue linkage. A new
  `workflows/scripts/board/claim-guard.sh` partitions the cull set into
  `CULL` (unclaimed, or claimed by this session) and `SKIP` (a foreign
  `fnd:host/session:*` stamp), and Step 4.8a of the spec runs it before the
  first close write. A skipped candidate stays open, keeps its stamp
  untouched, and is named in the run report's new "Skipped (claimed by
  another session)" line. The guard issues no writes on any path, never
  blocks — a **stale** foreign claim reports and skips exactly like a live
  one, leaving disposal to `/tidy`'s stale-claim sweep — and fails **safe**
  rather than open: an unreadable board culls nothing.
