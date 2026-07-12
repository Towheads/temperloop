#!/usr/bin/env bash
#
# portable-timeout.sh — a SOURCED library providing ONE bounded-subprocess
# watchdog, `run_with_timeout SECS cmd...`, reused by every script that
# needs to bound an external command (a `gh` call, a report drop-in, an LLM
# turn) without assuming GNU coreutils `timeout` is on PATH.
#
# WHY THIS EXISTS (temperloop#256): stock macOS ships no `timeout` binary at
# all — coreutils is opt-in via Homebrew, and even then it installs as
# `gtimeout` (the `g`-prefix convention every GNU coreutils tool gets on
# macOS to avoid shadowing BSD userland). A script that shells out to a bare
# `timeout N cmd` dies with "timeout: command not found" the first time it
# runs on a stock Mac. Before this file existed, half a dozen scripts each
# independently rediscovered the same bash-3.2-safe background+kill
# workaround (baseline-snapshot.sh, conventions-probe.sh, try.sh, report.sh,
# configure.sh) — correct, but duplicated, and every NEW script that needed
# a bounded subprocess had to rediscover it again (the "recurring" half of
# #256's title). This file is the ONE guard those call sites now source
# instead of re-deriving it.
#
# BACKEND SELECTION, in order:
#   1. `timeout`  — present on every Linux box (coreutils) and on a Mac with
#                   GNU coreutils installed unprefixed (rare but possible).
#   2. `gtimeout` — present on a Mac with Homebrew coreutils (`brew install
#                   coreutils`), which prefixes every GNU tool with `g` so it
#                   never shadows the BSD original.
#   3. a portable, dependency-free bash watchdog — always available (bash +
#      `sleep` + `kill`, nothing else), so a bare stock macOS with neither
#      `timeout` nor `gtimeout` still gets a bounded call, never a hang.
# There is no 4th "no-op" tier IN THIS FILE — #256's fix direction allows a
# caller to drop the wrapper entirely where the timeout isn't load-bearing,
# but that's a per-call-site decision (skip calling run_with_timeout at all),
# not something this shim decides on a caller's behalf.
#
# EXIT-CODE CONTRACT — normalized to 137 (128+SIGKILL) on a timeout,
# REGARDLESS of which backend fired: the portable bash fallback naturally
# produces 137 (it `kill -9`s the child), but GNU `timeout`'s own default
# convention is 124 (see `timeout --help`). Every existing call site this
# file's callers migrate from was written against the bash fallback's 137,
# so this function remaps `timeout`/`gtimeout`'s 124 to 137 rather than
# push a second exit-code convention onto every caller. A caller's own
# command legitimately exiting 124 is (as before this file existed, under
# the bash-only fallback's equivalent 137 collision risk) an accepted, rare
# ambiguity — not a new risk this normalization introduces.
#
# PIPE-LEAK FIX (foundation #861), preserved from the fallback's original
# per-script copies: the watchdog subshell is redirected to /dev/null AT
# THE SUBSHELL BOUNDARY (`) </dev/null >/dev/null 2>&1 &`), never left to
# inherit this function's stdout. Without that redirect, a caller invoking
# this inside a command substitution (`out="$(run_with_timeout ...)"`) sees
# its watchdog's `sleep $secs` child inherit the substitution's pipe
# write-end — so even after the fast path kills the watchdog PROCESS, that
# orphaned `sleep` grandchild keeps the pipe open and the command
# substitution can't see EOF until the full $secs elapses, turning every
# fast, successful call into a full-timeout-length stall.
#
# Usage (after `source .../portable-timeout.sh`):
#   if out="$(run_with_timeout 10 gh api "repos/$repo/branches/$b/protection" 2>&1)"; then
#     ...
#   else
#     status=$?
#     [ "$status" -eq 137 ] && ...timed out...
#   fi
#
# shellcheck shell=bash

run_with_timeout() {
  local secs="$1"; shift
  local status

  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
    status=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
    status=$?
  else
    "$@" &
    local cmd_pid=$!
    ( sleep "$secs" 2>/dev/null; kill -9 "$cmd_pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
    local watchdog_pid=$!
    wait "$cmd_pid" 2>/dev/null
    status=$?
    kill "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null
  fi

  # Normalize the native-timeout-backend "timed out" code (124) onto the
  # fallback's natural SIGKILL code (137) — see the exit-code contract note
  # above. Any other status (success or the wrapped command's own failure)
  # passes through unchanged.
  [ "$status" -eq 124 ] && status=137
  return "$status"
}
