- **`lint-pipe-grep-q` no longer fires on the shape inside PRINTED TEXT — its
  own usage block included, which is what blocked the v0.29.0 vendor** (#1420).
  The lint already stripped `#` comments quote-aware, so it never fired on prose
  *describing* the `<writer> | grep -q <pat>` footgun it guards. It did not do
  the same for **quoted string literals or heredoc bodies**, so a `grep -q`
  inside an `echo`/`printf` help string was read as an executed pipeline. Two
  consequences, both live: the linter flagged **its own** error-message line
  (`echo "     <writer> | grep -Fxq \"\$needle\"" >&2`) wherever the vendored
  `kernel/scripts/lint-pipe-grep-q.sh` path is reachable, and it flagged
  ordinary overlay code that merely *echoes* a `curl … | grep -q …` probe
  instruction. Because the gate line is a **KERNEL_GATES** entry an overlay
  vendors as a symlink and cannot amend downstream, this was release-blocking
  rather than cosmetic — measured on the real composed overlay checkout it was
  **23 findings before, 0 after**, with every one of the 23 confirmed printed
  text rather than code.

  The scanner now reduces each line to its **executable part** before matching:
  the comment strip as before, plus the *contents* of every quoted string
  literal blanked, plus heredoc bodies skipped. **The exemption is by parse
  position, never by filename** — a filename allowlist would only move the
  defect to the next file that documents the shape. What decides is the simple
  command *consuming* the text: hand it to a shell (`bash -c`/`sh -c`, `eval`,
  `ssh`, `env`, `xargs`, `timeout`, a `bash <<EOF` heredoc) and it is still
  scanned, so the real in-a-string sites the #1050 sweep found stay flagged.
  The strip is content-only — quote *delimiters* survive — so `echo "x" | grep
  -q y` still reads as a pipeline and still fires. Heredoc detection is
  deliberately tight (a `<<<` herestring and an arithmetic `$(( a << B ))`
  shift are both rejected) because a false heredoc would swallow the rest of the
  file; a probe that appended a genuine violation to the end of all 404 tracked
  shell files confirmed **zero** files go blind that way.

  Both strips err toward a **missed site, never a false alarm on prose** — the
  stated safe direction for a guard whose false positives block a release. The
  bounded cost is spelled out in the script's own header: a heredoc body written
  to a file rather than printed is no longer scanned (~3.8% of the shell corpus,
  almost all test fixtures, hiding no site that exists today). `T8` asserts the
  discrimination on byte-identical text — code line named, printed and heredoc
  lines not — and `T9` reproduces the whole thing on a synthetic
  composed/vendoring overlay layout, where the defect actually fired.
