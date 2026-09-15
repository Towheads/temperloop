- **The §3e review ceiling now actually waits, so routed reviewers stop being
  discarded as timeouts** (#2049). Its wall-clock tick was an inline
  `sleep N; printf` Bash command, which a harness permission control refuses in
  the machinery executor's seat — and the executor's prompt then told it to
  report the interval elapsed anyway. Measured in run `wf_ebd4b5e0-3a8`, slices
  asking 300s/540s/360s returned in 8s/9s/9s, so a nominal 1200s ceiling
  realized in ~30s of wall clock and abandoned reviewers that were completing
  normally at 177s and 257s; three consecutive items reported `ran: []` as a
  result. The wait now runs inside the new
  `workflows/scripts/build/review-wait.sh` helper, and `build-level.mjs` honours
  an elapse only when it carries that script's own measured `realized_secs` —
  so a tick that did not wait can no longer claim it did, and reports
  `REVIEW_WAIT_UNAVAILABLE` instead, which fails open with a legible notice.
  temperloop#2003's bound on a genuinely hung reviewer is unchanged.
