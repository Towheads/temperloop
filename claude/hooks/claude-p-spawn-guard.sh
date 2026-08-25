#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash) — bare `claude -p` spawn guard
# (temperloop#1836, the harness-level half temperloop#1829 explicitly parked).
#
# WHY: a headless `claude -p` / `--print` spawn does NOT inherit the launching
# session's model. It resolves the MACHINE's saved default — whatever `/model`
# was last set to in any interactive session on that host, possibly days
# earlier, by unrelated work. So a fan-out composed mid-run silently routes
# every worker to an unintended tier. `validate-model-usage-emit.sh` §6e is the
# repo-file half of this guard, but it can only see committed `*.sh` under its
# scan dir; the 2026-08-24 incident's 57 spawns ran from `/tmp/sweep2/
# review-one.sh` — a script a worker composed at run time and never committed,
# which no repo-scanning validator will ever see. This hook is the run-time
# half: it reads the spawn text as it passes through a Bash TOOL CALL.
#
# DETECTION: the whole command string is scanned — HEREDOC BODIES INCLUDED, not
# just the argv head. That is load-bearing, not incidental. The incident's
# spawns were dispatched as `bash /tmp/sweep2/review-one.sh … &` inside
# backgrounded `while read` loops; a hook keying on the leading command word
# sees only `bash …` and stays silent (temperloop#1836 probed and DISCONFIRMED
# that design). The two interception points that DO carry the literal text are
# both single Bash calls occurring BEFORE the fan-out — the inline smoke test
# (`… && time claude -p "$(…)" --output-format json`) and, decisively, the
# heredoc that AUTHORED the script (`cat > review-one.sh <<'SCRIPT' … claude -p
# … SCRIPT`). Firing at the authoring heredoc turns one `ask` into prevention
# of all 57 spawns.
#
# Mechanics: line continuations are joined, the command is tokenized, and every
# token whose basename is `claude` AND that sits in COMMAND POSITION (start of
# input; after `;` `&` `&&` `||` `|` or a newline; after a leading modifier
# such as `time`/`env`/`exec`/`sudo` or a `VAR=val` assignment; after `sh -c`;
# after a NAMED LAUNCHER PREFIX — `timeout` / `gtimeout` / `xargs` / `parallel`,
# which take their own arguments and so put a non-modifier token in between; or
# opening a `$( … )` / backtick substitution) starts an invocation. Command
# position is what keeps `grep -n "claude -p" file` silent. Flags are then read
# up to the next separator, where a separator sitting inside an OPEN QUOTE
# REGION does not terminate — quoting is tracked as one shell-accurate state
# (none / double / single) rather than as two independent parities, so both a
# multi-line double-quoted prompt and `-p 'be brief; be kind'` stay a single
# invocation while an apostrophe inside "don't" stays a literal. That same quote
# state ALSO gates FLAG RECOGNITION: a flag-shaped word inside an open quote
# region is prompt text, not a flag, which closes one bug with two faces —
# `claude -p "explain the --model flag"` passes no --model and must still ask,
# while `--append-system-prompt "always use -p mode"` passes no -p and must stay
# silent.
# `ask` is emitted when the invocation carries `-p`/`--print` and
# carries NEITHER `--model`/`--model=…` NOR a `--settings` source that pins a
# model. Deliberate edge-case dispositions:
#   * `--print` is recognised exactly like `-p`.
#   * the ATTACHED spellings `-p"hi"` / `--print'hi'` (a value joined to the
#     flag with no space) are recognised too -> NOT a blind spot.
#   * an UNBALANCED quote sitting between `claude` and its `-p` leaves the
#     quote region open, so the rest of that invocation reads as prompt text
#     -> silent. That input is a shell SYNTAX ERROR and cannot execute, so this
#     is the fail-open-on-malformed-input rule below, not a coverage gap. Quote
#     state RESETS at each invocation, so an apostrophe anywhere BEFORE the
#     `claude` token — prose in a heredoc comment, an earlier command — is
#     harmless and the load-bearing heredoc case is unaffected.
#   * a `-p` sitting in the VALUE slot of a value-taking flag (e.g. `claude
#     --output-format -p`) is a value, not the print flag -> silent.
#   * `--settings` pointing at a file whose `.model` is set, or inline JSON
#     mentioning `model`, counts as pinned -> silent. `--fallback-model` does
#     NOT count: it is a fallback, the primary tier is still inherited.
#   * a `--settings` value this hook cannot resolve (a `$VAR`, a path that does
#     not exist at hook time) is treated as pinned -> silent. Fail-open, per
#     the family philosophy; this guard is advisory, never a security boundary.
#   * `--model` supplied through a shell variable is silent only when the
#     literal `--model` token is visible (`--model "$M"`); an invocation whose
#     flags arrive wholly inside an unexpanded `$FLAGS` will ask. The ask is
#     cheap and approvable — this hook reads text, not runtime state.
#   * several `claude` invocations in one command string are each checked; the
#     verdict names how many are bare and quotes the first.
#   * awk hands the shell half a `@@HOOK_NO_SETTINGS@@` sentinel to mean "this
#     invocation passed no --settings" (a leading empty field would be eaten by
#     `read`'s IFS whitespace-stripping). The sentinel is deliberately a value
#     no real `--settings` argument can be, so nothing a caller writes can
#     collide with it and flip the verdict.
#
# VERDICT: `ask`, never `deny` — same philosophy as git-stale-branch-guard.sh,
# write-lane-guard.sh and subtree-edit-guard.sh. A deliberate inherit is
# occasionally correct (a one-off interactive spawn the operator wants on the
# machine default), so this forces a conscious beat rather than blocking work.
# ANY internal error (no jq, unparseable input, an awk failure) exits 0
# silently and lets the command proceed.
#
# BLIND SPOT — stated because an overclaimed guard is worse than none, since it
# stops people looking. This sees ONLY spawn text that passes through a Bash
# TOOL CALL. It does NOT catch:
#   * a bare `claude -p` inside an ALREADY-COMMITTED script invoked by path
#     (`bash tools/fanout.sh`) — the file's text never reaches the hook. That
#     case belongs to validate-model-usage-emit.sh §6e, which scans committed
#     `*.sh`; between them the run-time-composed case and the committed case
#     are covered, and a committed script OUTSIDE §6e's scan dir is covered by
#     neither.
#   * a spawn launched outside the harness entirely (a shell the operator
#     drives by hand, a cron entry, a launchd agent).
#   * a spawn behind an UNLISTED launcher prefix. Command-position detection
#     knows a short, NAMED set of argument-taking launchers (`timeout`,
#     `gtimeout`, `xargs`, `parallel` — see LAUNCH in the awk BEGIN block);
#     anything else that puts its own arguments before `claude` (a wrapper
#     script, `nice -n`, `flock`, a container `run`) is not recognised as
#     command position and stays silent. This list is deliberately bounded —
#     enumerating every possible launcher is not attempted, and widening it is
#     a judgement call about false positives, not an oversight.
#   * a spawn whose `claude` token is hidden from text scanning — built by
#     string concatenation, held in a variable, or base64-decoded at run time.
# The incident class is NARROWED here, not closed.
#
# EVAL_RUN: exits 0 silently — an unanswerable interactive `ask` would hang a
# headless eval run, and a bare spawn is not a scored finding.
set -uo pipefail

[ -n "${EVAL_RUN:-}" ] && exit 0           # no interactive prompt under eval

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0    # fail open: no jq, no guard

tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$tool" = "Bash" ] || exit 0             # matcher scopes this; double-check

cmd=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

case "$cmd" in *claude*) ;; *) exit 0 ;; esac   # cheap prefilter

# Emit one "<settings-value>\t<snippet>" line per `claude` invocation that
# carries -p/--print and no --model. The settings value is resolved in shell
# below (it may need a file read). Any awk failure -> empty output -> silent.
findings=$(printf '%s\n' "$cmd" | awk '
  function base(t,   n2, a2) { n2 = split(t, a2, "/"); return a2[n2] }
  function unq(t) { gsub(/^["\047]+/, "", t); gsub(/["\047]+$/, "", t); return t }
  function clean(t,   s) {
    s = t
    gsub(/^["\047]+/, "", s)
    # `X=$(claude …)` / `X=`claude …`` — drop the assignment prefix so the
    # substitution below exposes the real command word. Only when a
    # substitution actually follows, so a plain `FOO=claude` stays an
    # assignment and is never read as an invocation.
    if (s ~ /^[A-Za-z_][A-Za-z_0-9]*=(\$\(|`)/) sub(/^[A-Za-z_][A-Za-z_0-9]*=/, "", s)
    while (s ~ /^(\$\(|`|\(|\{)/) {
      sub(/^(\$\(|`|\(|\{)/, "", s)
      gsub(/^["\047]+/, "", s)
    }
    gsub(/["\047);}]+$/, "", s)
    return s
  }
  function issep(r) { return (r == NLTOK || r ~ /^(;|;;|&|&&|\||\|\||\(|\))$/) }
  # Quote state, tracked the way the SHELL tracks it: one state (none / "d" /
  # "s"), not two independent parities. Two parities get an APOSTROPHE INSIDE A
  # DOUBLE-QUOTED PROMPT wrong (it is a literal to the shell, so it must NOT
  # open a quote region and swallow the next separator). Fed every token of
  # an invocation in order; the sep/endsep breaks below fire only at qs == "".
  function qscan(t,   k, c, L) {
    L = length(t)
    for (k = 1; k <= L; k++) {
      c = substr(t, k, 1)
      if (qs == "") {
        if (c == "\\") k++
        else if (c == "\"") qs = "d"
        else if (c == "\047") qs = "s"
      } else if (qs == "d") {
        if (c == "\\") k++          # \" inside "…" does not close the region
        else if (c == "\"") qs = ""
      } else {
        if (c == "\047") qs = ""    # in a single-quoted region nothing escapes
      }
    }
  }
  # A launcher that takes its OWN arguments (a timeout duration, an xargs -I{},
  # a parallel ::: ) puts a non-modifier token between itself and `claude`, so
  # every immediate-predecessor test in cmdpos() misses it. Walk back to the
  # head of this pipeline segment, skip leading modifiers and assignments, and
  # accept command position when that head is a NAMED launcher.
  # BOUNDED BY DESIGN: LAUNCH is a short, named list (see BEGIN, and the
  # BLIND SPOT block in the header) — an UNLISTED launcher prefix is not
  # covered, and this
  # deliberately does not try to enumerate every possible launcher.
  function launched(i,   s) {
    s = i - 1
    while (s >= 1 && !sep[s] && !endsep[s]) s--
    s++                                   # first token of this pipeline segment
    while (s < i && (cl[s] in MOD || cl[s] ~ /^[A-Za-z_][A-Za-z_0-9]*=/)) s++
    if (s >= i) return 0
    return (base(cl[s]) in LAUNCH)
  }
  function cmdpos(i,   p) {
    if (i == 1) return 1
    if (opener[i]) return 1
    if (sep[i - 1] || endsep[i - 1]) return 1
    p = cl[i - 1]
    if (p in MOD) return 1
    if (tok[i - 1] ~ /^["\047]*[A-Za-z_][A-Za-z_0-9]*=/) return 1
    if (p == "-c" && i >= 3 && base(cl[i - 2]) ~ /^(bash|sh|zsh|dash|ksh)$/) return 1
    if (launched(i)) return 1
    return 0
  }
  BEGIN {
    nt = 0
    NLTOK = "@@HOOK_NL@@"
    # Flags whose NEXT token is a VALUE, not a flag. Deliberately excludes
    # --resume/-r/--continue/--debug (optional values: swallowing the next
    # token there would hide a real -p).
    nv = split("--model --settings --setting-sources --append-system-prompt " \
               "--system-prompt --output-format --input-format --allowedTools " \
               "--allowed-tools --disallowedTools --disallowed-tools " \
               "--permission-mode --permission-prompt-tool --mcp-config " \
               "--add-dir --session-id --agents --fallback-model --max-turns", va, / /)
    for (k = 1; k <= nv; k++) VAL[va[k]] = 1
    nm = split("time exec env nohup command sudo caffeinate stdbuf eval then do else", ma, / /)
    for (k = 1; k <= nm; k++) MOD[ma[k]] = 1
    # Launchers that take their OWN arguments before the command they run. Kept
    # SHORT and NAMED on purpose (see launched() and the header BLIND SPOT):
    # these are the forms the build machinery in this repo, and a hand-rolled
    # fan-out, actually reach for. An unlisted launcher prefix is not covered.
    nl = split("timeout gtimeout xargs parallel", la, / /)
    for (k = 1; k <= nl; k++) LAUNCH[la[k]] = 1
    NOSET = "@@HOOK_NO_SETTINGS@@"
  }
  {
    line = $0
    cont = 0
    if (line ~ /\\$/) { sub(/\\$/, "", line); cont = 1 }
    n = split(line, a, /[ \t]+/)
    for (i = 1; i <= n; i++) if (a[i] != "") tok[++nt] = a[i]
    if (!cont) tok[++nt] = NLTOK          # newline is a command separator
  }
  END {
    for (i = 1; i <= nt; i++) {
      cl[i] = clean(tok[i])
      opener[i] = (tok[i] ~ /^["\047]*([A-Za-z_][A-Za-z_0-9]*=)?(\$\(|`|\(|\{)/) ? 1 : 0
      sep[i] = issep(tok[i])
      endsep[i] = (!sep[i] && tok[i] ~ /[;&]$/) ? 1 : 0
    }
    for (i = 1; i <= nt; i++) {
      if (base(cl[i]) != "claude") continue
      if (!cmdpos(i)) continue
      printflag = 0; model = 0; sval = ""; qs = ""; prev = ""
      snippet = cl[i]; sn = 1
      for (j = i + 1; j <= nt; j++) {
        # A separator INSIDE an open quote region is prompt text, not a command
        # break — this is what stops a `;` or `&&` inside a SINGLE-QUOTED prompt
        # from ending the flag scan before a later --model is reached.
        if (sep[j] && qs == "") break
        # Quote state ENTERING this token, captured BEFORE qscan() advances it:
        # what makes a token prompt text rather than a flag is the state it
        # STARTS in, not the state it leaves behind.
        qin = qs
        qscan(tok[j])
        # The snippet is diagnostic text and stays OUTSIDE the gate below on
        # purpose — it quotes the invocation as written, prompt words included.
        if (tok[j] != NLTOK && sn < 8) { snippet = snippet " " tok[j]; sn++ }
        t = cl[j]
        # A flag-shaped token INSIDE an open quote region is prompt text, not a
        # command flag. Both directions of that are the same bug, so one gate
        # closes both: the false NEGATIVE (`claude -p "explain the --model
        # flag"` passes no --model, so it must still ask) and the false ASK
        # (`--append-system-prompt "always use -p mode"` passes no -p, so it
        # must stay silent). The VALUE-SLOT capture is gated too — a
        # `--settings` merely named inside a quoted prompt must not consume the
        # following word as its value.
        if (qin == "") {
          if (prev != "" && (prev in VAL)) {
            if (prev == "--settings") sval = unq(tok[j])
            prev = ""
            if (endsep[j] && qs == "") break
            continue
          }
          # `-p"hi"` / `--print"hi"` — a value attached to the flag with no
          # space (the single-quoted spelling too; it is not written literally
          # here because a lone apostrophe would close the shell quoting that
          # wraps this whole awk program). clean() strips the TRAILING quote
          # but the LEADING one survives into t, so the exact comparisons
          # alone would miss it.
          if (t == "-p" || t == "--print" || t ~ /^-p["\047]/ || t ~ /^--print["\047]/) printflag = 1
          else if (t == "--model" || t ~ /^--model=/) model = 1
          else if (t ~ /^--settings=/) sval = unq(substr(t, 12))
          prev = (t in VAL) ? t : ""
        }
        if (endsep[j] && qs == "") break
      }
      if (printflag && !model) {
        if (length(snippet) > 140) snippet = substr(snippet, 1, 137) "..."
        # A sentinel stands in for "no --settings value": a leading EMPTY field
        # would be eaten by `read`, whose IFS whitespace-stripping drops a
        # leading tab. It is deliberately a string no real --settings value can
        # collide with (a literal `-` could: `--settings -` would then read as
        # "no settings" and silently change the verdict).
        print (sval == "" ? NOSET : sval) "\t" snippet
      }
    }
  }
' 2>/dev/null) || exit 0

[ -n "$findings" ] || exit 0

bare=0
first=""
while IFS=$'\t' read -r sval snip; do
  [ -n "$snip" ] || continue
  # awk's "no --settings" sentinel — see the NOSET note in the awk block.
  [ "$sval" = "@@HOOK_NO_SETTINGS@@" ] && sval=""
  if [ -n "$sval" ]; then
    pinned=0
    case "$sval" in
      *'$'* | *'`'*) pinned=1 ;;              # unresolvable expansion -> fail open
      *'{'*) case "$sval" in *model*) pinned=1 ;; esac ;;   # inline JSON pinning a model
      *)
        if [ -f "$sval" ]; then
          jq -e '.model // empty' "$sval" >/dev/null 2>&1 && pinned=1
        else
          pinned=1                            # unresolvable path -> fail open
        fi
        ;;
    esac
    [ "$pinned" -eq 1 ] && continue
  fi
  bare=$((bare + 1))
  [ -n "$first" ] || first="$snip"
done <<EOF
$findings
EOF

[ "$bare" -gt 0 ] || exit 0

if [ "$bare" -eq 1 ]; then
  count_phrase="A headless \`claude\` spawn in this command"
else
  count_phrase="${bare} headless \`claude\` spawns in this command"
fi

reason="${count_phrase} carries -p/--print with no --model (and no --settings source pinning one): ${first}
A bare 'claude -p' does NOT inherit this session's model — it resolves the MACHINE's saved default (whatever /model last wrote to ~/.claude/settings.json, possibly days ago from unrelated work), so the tier you chose here is thrown away and every spawned worker silently runs on that host default. On 2026-08-24 that routed 57 review spawns to the wrong tier (temperloop#1836/#1829).
Fix: pass --model explicitly, taking its value from a named setting in workflows/scripts/build/build.config.sh (e.g. \$PIPELINE_DRIVE_MODEL) rather than a hard-coded model id — or pass a --settings source that pins .model. If this command WRITES a script (a heredoc), fix the spawn line inside the heredoc: that is the cheapest point, before any fan-out runs.
Approve only if inheriting the machine default is what you actually want here."

jq -cn --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}' \
  2>/dev/null || true
exit 0
