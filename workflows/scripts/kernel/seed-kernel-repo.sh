#!/usr/bin/env bash
#
# seed-kernel-repo.sh — materialize the kernel file set (per
# kernel-manifest.txt) into a destination directory: the fresh-history seed
# for the public-track kernel repo (foundation #803, epic #762 "kernel
# split"). Re-runnable / re-usable by the later overlay-subtree-cutover item,
# which consumes this same materialized tree as a known artifact.
#
# What it does:
#   1. Copies every path list-kernel-set.sh classifies `kernel` from --root
#      into --dest, 1:1 (same relative path in both repos — the layout
#      choice this item owns; see "PATH MAPPING" below).
#   2. Generates the repo-identity files a fresh OSS repo needs that do NOT
#      exist in foundation's own tree today: LICENSE (Apache-2.0, verbatim
#      upstream text), NOTICE, SECURITY.md, CHANGELOG.md. kernel-manifest.txt's
#      header records that owning these three (LICENSE/NOTICE/SECURITY.md) is
#      THIS item's job, not a carry-over — see that file's header.
#   3. Generates a standalone Makefile: the subset of foundation's Makefile
#      targets that (a) the KERNEL_GATES layer of scripts/quality-gates.sh
#      invokes, plus (b) the docs generator — recipe bodies copied verbatim
#      from foundation's Makefile (never hand-edited), restricted to targets
#      whose entire dependency closure is itself kernel-classified. One
#      deliberate deviation (F#836): test suites enumerated as an explicit
#      file list in foundation's recipe (test-board) are generated as a
#      tests/test_*.sh glob instead — a static copy of the list goes stale
#      when foundation registers a new test, silently skipping it in kernel
#      CI; the glob runs whatever tests the seeded tree actually carries.
#      Install/deploy targets (install, install-env, install-claude, ...) are
#      deliberately NOT included: they depend on env/* and machine-specific
#      paths that are overlay-only and don't exist in this repo — wiring them
#      in would look like a working install path that silently does nothing.
#      That's later integration work, not this item's job.
#   4. Generates a dual-OS CI workflow (.github/workflows/ci.yml, job name
#      `checks`) that runs `bash scripts/quality-gates.sh` on ubuntu-latest
#      AND macos-latest — the exact same script foundation's own CI runs,
#      unmodified, so "local gate = CI gate" holds in the kernel repo too.
#
# PATH MAPPING: 1:1 mirror of foundation's paths, no flattening. This is the
# layout call this item owns (per the F#803 contract) — a 1:1 mirror is what
# makes the later overlay-subtree-cutover item's `git subtree` vendor-back
# trivial (subtree preserves paths; a flattened layout would need a rewrite
# step on every future sync).
#
# What this script deliberately does NOT do (kept out so it stays a pure,
# idempotent tree-materializer, not a release tool):
#   - git init / add / commit / tag / push — the caller does that once over
#     the materialized tree.
#   - delete paths in DEST that this run didn't touch — a first seed is
#     always into an empty DEST; a re-run mirrors the CURRENT manifest but
#     doesn't chase manifest removals from a prior run. Dropping a file from
#     the kernel set is a deliberate `git rm` in the kernel repo, not
#     something this script infers.
#
# Idempotent: running twice against the same --root into two fresh --dest
# directories yields byte-identical trees (diff -rq exits 0) — every copy is
# content-only (cp -p) and every generated file's content is static.
#
# Usage:
#   seed-kernel-repo.sh --dest DIR [--root DIR]
#
# --dest DIR   required. Must already exist (create it first — a scratch
#              clone or empty tmpdir). May be empty or a git working tree;
#              this script only writes files, it never runs git.
# --root DIR   foundation checkout to read the kernel set from (default: the
#              checkout this script itself lives in).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ROOT="$DEFAULT_ROOT"
DEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      DEST="${2:-}"
      shift 2
      ;;
    --root)
      ROOT="${2:-}"
      shift 2
      ;;
    *)
      echo "usage: $(basename "$0") --dest DIR [--root DIR]" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$DEST" ]]; then
  echo "seed-kernel-repo: --dest DIR is required" >&2
  exit 2
fi
if [[ ! -d "$DEST" ]]; then
  echo "seed-kernel-repo: --dest '$DEST' does not exist (create it first)" >&2
  exit 1
fi
if [[ ! -f "$ROOT/workflows/scripts/kernel/kernel-manifest.txt" ]]; then
  echo "seed-kernel-repo: --root '$ROOT' has no kernel-manifest.txt — not a foundation checkout" >&2
  exit 1
fi

DEST="$(cd "$DEST" && pwd)"

echo "==> Materializing kernel set from $ROOT into $DEST"
n=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  src="$ROOT/$f"
  [[ -f "$src" ]] || continue
  d="$DEST/$f"
  mkdir -p "$(dirname "$d")"
  cp -p "$src" "$d"
  n=$((n + 1))
done < <("$SCRIPT_DIR/list-kernel-set.sh" --root "$ROOT")
echo "  -> copied $n kernel file(s)"

# ---------------------------------------------------------------------------
# LICENSE — Apache License 2.0, verbatim upstream text (no filled-in
# copyright line inside LICENSE itself; that lives in NOTICE, matching the
# common convention of leaving the Apache boilerplate template untouched).
# ---------------------------------------------------------------------------
cat > "$DEST/LICENSE" <<'LICENSE_EOF'

                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
LICENSE_EOF
echo "  -> wrote LICENSE (Apache-2.0)"

# ---------------------------------------------------------------------------
# NOTICE
# ---------------------------------------------------------------------------
cat > "$DEST/NOTICE" <<'NOTICE_EOF'
temperloop
Copyright 2026 the temperloop project contributors

This product includes software developed as part of the temperloop
project: the process layer for a board-driven
bug -> PR pipeline (board toolkit, build spine, funnel driver, quality
gates, and the Claude Code commands/skills that drive them).

Licensed under the Apache License, Version 2.0. See LICENSE for the full
license text.
NOTICE_EOF
echo "  -> wrote NOTICE"

# ---------------------------------------------------------------------------
# SECURITY.md — responsible-disclosure contact. No hardcoded org/repo URL or
# personal email (both would trip the kernel scrub bar this repo is meant to
# hold to) — GitHub's own Security tab is the pointer, addressable from any
# fork/rename without edits here.
# ---------------------------------------------------------------------------
cat > "$DEST/SECURITY.md" <<'SECURITY_EOF'
# Security Policy

## Supported versions

This project is pre-1.0. Only the latest tagged release receives security
fixes; there is no backport policy yet.

## Reporting a vulnerability

Please report suspected vulnerabilities privately using GitHub's built-in
private vulnerability reporting flow: open this repository's **Security**
tab -> **Advisories** -> **Report a vulnerability**. Do not open a public
issue for a security report.

We aim to acknowledge new reports within 5 business days and will work with
you on a disclosure timeline before any public writeup.
SECURITY_EOF
echo "  -> wrote SECURITY.md"

# ---------------------------------------------------------------------------
# CHANGELOG.md — stub establishing the release-tag convention (Keep a
# Changelog + SemVer), the precondition Epic C's Pages versioning consumes.
# ---------------------------------------------------------------------------
cat > "$DEST/CHANGELOG.md" <<'CHANGELOG_EOF'
# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/) —
pre-1.0, so a minor version bump (`0.x.0`) may include breaking changes.

## [0.1.0] - 2026-07-02

### Added

- Initial fresh-history seed of the kernel file set from the foundation
  repo's `kernel`-classified tree (see
  `workflows/scripts/kernel/kernel-manifest.txt` in the source repo, and
  `workflows/scripts/kernel/seed-kernel-repo.sh`, the re-runnable seeder that
  produced this commit). Board toolkit, build spine, funnel driver, quality
  gates, and the Claude Code commands/skills/hooks that drive them.
CHANGELOG_EOF
echo "  -> wrote CHANGELOG.md"

# ---------------------------------------------------------------------------
# kernel-manifest.txt classifies every git-tracked path in the SOURCE
# (foundation) repo; LICENSE/NOTICE/SECURITY.md/CHANGELOG.md/Makefile don't
# exist there (kernel-manifest.txt's own header records that their
# LICENSE/NOTICE/SECURITY.md ownership belongs to this item, not a
# carry-over). Once materialized here they become newly tracked paths in
# THIS repo, so the copied manifest needs a line for each or
# `make test-kernel-manifest` fails its own coverage check on its first run
# in the kernel repo. Makefile needs no new line: the copied manifest already
# carries `split Makefile` for the repo root, which still matches here.
# ---------------------------------------------------------------------------
cat >> "$DEST/workflows/scripts/kernel/kernel-manifest.txt" <<'MANIFEST_APPEND_EOF'

# --- appended by seed-kernel-repo.sh (F#803): these paths are generated by
# the seeder directly into the kernel repo and never exist in the foundation
# source tree, so they have no entry in the manifest copied from there. ---
kernel LICENSE
kernel NOTICE
kernel SECURITY.md
kernel CHANGELOG.md
MANIFEST_APPEND_EOF
echo "  -> appended LICENSE/NOTICE/SECURITY.md/CHANGELOG.md classification to kernel-manifest.txt"

# ---------------------------------------------------------------------------
# Makefile — standalone subset. Every recipe body below is copied VERBATIM
# from foundation's own Makefile (never hand-edited here) for every target
# whose full dependency closure is itself kernel-classified: the
# KERNEL_GATES layer of scripts/quality-gates.sh, plus the docs generator
# (also kernel per the manifest). Install/deploy targets are intentionally
# excluded — see this script's header.
# ---------------------------------------------------------------------------
cat > "$DEST/Makefile" <<'MAKEFILE_EOF'
# temperloop Makefile — standalone subset of foundation's Makefile,
# generated by workflows/scripts/kernel/seed-kernel-repo.sh (F#803). Every
# recipe body here is copied verbatim from foundation's own Makefile for the
# kernel-classified targets scripts/quality-gates.sh's KERNEL_GATES invoke,
# plus the docs generator. Do not hand-edit this file in the kernel repo —
# change the source in foundation's Makefile and re-run the seeder.
SHELL := /bin/bash
FOUNDATION := $(shell pwd)
BOARD_SRC := $(FOUNDATION)/workflows/scripts/board
BUILD_SRC := $(FOUNDATION)/workflows/scripts/build
HOOKS_SRC := $(FOUNDATION)/claude/hooks

.PHONY: help shellcheck quality-gates test-board test-build test-build-workflow \
	test-hooks test-install test-install-links test-install-worktree-guard \
	test-prune-branches validate-live-drain validate-command-run-emit \
	validate-lexicon test-scan-stub lint-pr-body-test test-stranger-config \
	test-kernel-manifest test-kernel-denylist test-kernel-gitleaks docs \
	test-docs-generator guard-install-worktree

help:
	@echo "Targets:"
	@echo "  quality-gates          Run the full static gate set (= CI's checks job)"
	@echo "  shellcheck              Whole-tree shellcheck (production + hook scripts)"
	@echo "  test-board              Board toolkit tests"
	@echo "  test-build              Build deterministic-spine toolkit tests"
	@echo "  test-build-workflow     build-level.mjs offline harness"
	@echo "  test-hooks              Claude Code hook tests"
	@echo "  test-install            install-settings reconcile test"
	@echo "  test-install-links      install-links helper tests"
	@echo "  test-install-worktree-guard  Canonical-checkout guard tests"
	@echo "  test-prune-branches     prune-merged-branches.sh tests"
	@echo "  validate-live-drain     Live/Drain pairing registry lint"
	@echo "  validate-command-run-emit  emit-command-run.sh presence/wiring lint"
	@echo "  validate-lexicon        drain-mind tell-lexicon lint"
	@echo "  test-scan-stub          Session-stub scanner tests"
	@echo "  lint-pr-body-test       PR-body issue-linkage lint tests"
	@echo "  test-stranger-config    Kernel-portability seam integration test"
	@echo "  test-kernel-manifest    kernel-manifest.txt coverage check"
	@echo "  test-kernel-denylist    Personal-token denylist check"
	@echo "  test-kernel-gitleaks    gitleaks secret scan over the kernel set"
	@echo "  docs                    Render the generated docs site"
	@echo "  test-docs-generator     Docs generator unit tests"

# Canonical-checkout guard (foundation #509): refuses to run from a linked git
# worktree unless FORCE_REHOME=1. Not wired into any target below today (no
# install-* target ships in this standalone Makefile yet) — kept for parity
# with foundation's own Makefile and for a future install-* target to depend
# on without reintroducing the guard logic.
guard-install-worktree:
	@bash -c ' \
		if [ -n "$${FORCE_REHOME:-}" ]; then exit 0; fi; \
		_common="$$(git rev-parse --git-common-dir 2>/dev/null)" || exit 0; \
		_gitdir="$$(git rev-parse --absolute-git-dir 2>/dev/null)" || exit 0; \
		_common_abs="$$(cd "$$_common" && pwd)"; \
		_gitdir_abs="$$(cd "$$_gitdir" && pwd)"; \
		if [ "$$_common_abs" != "$$_gitdir_abs" ]; then \
			_canonical="$$(dirname "$$_common_abs")"; \
			echo "make: refusing to install from a git worktree ($$PWD)." >&2; \
			echo "  Run from the canonical checkout: $$_canonical" >&2; \
			echo "  Set FORCE_REHOME=1 to override." >&2; \
			exit 1; \
		fi \
	'

# test-board runs every tests/test_*.sh via a glob rather than mirroring
# foundation's explicit list — a static copy of that list goes stale the
# moment foundation registers a new board test (F#836: the pre-glob heredoc
# silently skipped test_issues_backend.sh in kernel CI). The glob matches
# whatever tests are actually vendored, so kernel coverage can never trail
# the tree it ships.
test-board:
	@echo "==> Running board toolkit tests..."
	@for t in $(BOARD_SRC)/tests/test_*.sh; do \
		bash "$$t" >/dev/null 2>&1 && echo "  [ok] $$(basename $$t)" || { echo "  [FAIL] $$(basename $$t)"; exit 1; }; \
	done

test-build:
	@echo "==> Running build toolkit tests..."
	@for t in $(BUILD_SRC)/tests/test_*.sh; do \
		bash "$$t" >/dev/null 2>&1 && echo "  [ok] $$(basename $$t)" || { echo "  [FAIL] $$(basename $$t)"; exit 1; }; \
	done

test-build-workflow:
	@echo "==> Running build-level.mjs offline harness..."
	@bash $(BUILD_SRC)/tests/test_workflow.sh

test-hooks:
	@echo "==> Running hook tests..."
	@for t in $(HOOKS_SRC)/tests/test_*.sh; do \
		bash "$$t" >/dev/null 2>&1 && echo "  [ok] $$(basename $$t)" || { echo "  [FAIL] $$(basename $$t)"; exit 1; }; \
	done

shellcheck:
	@echo "==> shellcheck (production + hook scripts)..."
	@find . -name '*.sh' -not -path './.git/*' -not -path '*/tests/*' -print0 \
		| xargs -0 --no-run-if-empty shellcheck -e SC1091

quality-gates:
	@bash $(FOUNDATION)/scripts/quality-gates.sh

validate-live-drain:
	@bash $(FOUNDATION)/workflows/scripts/validate-live-drain.sh

validate-command-run-emit:
	@bash $(FOUNDATION)/workflows/scripts/validate-command-run-emit.sh

validate-lexicon:
	@bash $(FOUNDATION)/workflows/scripts/drain/validate-lexicon.sh

test-kernel-manifest:
	@echo "==> Running kernel-manifest coverage check..."
	@bash $(FOUNDATION)/workflows/scripts/kernel/check-kernel-manifest.sh

docs:
	@python3 $(FOUNDATION)/workflows/scripts/docs/generate.py

test-docs-generator:
	@echo "==> Running docs generator tests..."
	@python3 -m unittest discover -s $(FOUNDATION)/workflows/scripts/docs/tests -t $(FOUNDATION)/workflows/scripts/docs -v

test-kernel-denylist:
	@echo "==> Running kernel personal-token denylist check..."
	@bash $(FOUNDATION)/workflows/scripts/kernel/check-personal-token-denylist.sh
	@echo "==> Running check-personal-token-denylist.sh fixture tests..."
	@bash $(FOUNDATION)/workflows/scripts/kernel/tests/test_check_personal_token_denylist.sh

test-kernel-gitleaks:
	@echo "==> Running kernel gitleaks scan..."
	@bash $(FOUNDATION)/workflows/scripts/kernel/check-gitleaks-kernel.sh

test-scan-stub:
	@echo "==> Running stub scanner tests..."
	@bash $(FOUNDATION)/workflows/scripts/drain/tests/test_scan_stub.sh

lint-pr-body-test:
	@echo "==> Running PR-body issue-linkage lint tests..."
	@bash $(FOUNDATION)/workflows/scripts/tests/test_lint_pr_body.sh

test-install:
	@echo "==> Running install-settings reconcile test..."
	@bash workflows/scripts/tests/test_install_settings.sh

test-install-links:
	@echo "==> Running install-links tests..."
	@bash workflows/scripts/tests/test_install_links.sh

test-install-worktree-guard:
	@echo "==> Running install-worktree-guard tests..."
	@bash workflows/scripts/tests/test_install_worktree_guard.sh

test-prune-branches:
	@echo "==> Running prune-merged-branches tests..."
	@bash scripts/tests/test_prune_merged_branches.sh

test-stranger-config:
	@echo "==> Running stranger-config test..."
	@bash scripts/tests/test_stranger_config.sh
MAKEFILE_EOF
echo "  -> wrote Makefile (standalone subset)"

# ---------------------------------------------------------------------------
# .github/workflows/ci.yml — overwrite the copied single-OS foundation
# version with a dual-OS (ubuntu-latest + macos-latest) matrix running the
# SAME `bash scripts/quality-gates.sh` command, job named `checks` (the
# required-check contract this item's acceptance criteria call for). No
# Homebrew/bash-upgrade step needed: the kernel scripts are deliberately
# bash-3.2-compatible (no declare -A/mapfile/readarray — verified against the
# full kernel set) with BSD-vs-GNU fallbacks already in place for the few
# `stat`/`date` calls that differ (e.g. board/lib/board.sh's
# `stat -c ... || stat -f ...`), so macOS's system bash/coreutils run this
# gate set unmodified, same as ubuntu's. shellcheck IS installed via brew on
# macOS only: unlike ubuntu-latest (shellcheck preinstalled), macos-latest
# GitHub-hosted runners don't ship it (confirmed by a live CI run of this
# workflow, F#803) — `make shellcheck` fails with ENOENT otherwise.
# ---------------------------------------------------------------------------
mkdir -p "$DEST/.github/workflows"
cat > "$DEST/.github/workflows/ci.yml" <<'CI_EOF'
name: CI

# temperloop's CI: a single job named `checks` (the required status
# check for branch protection), run on ubuntu-latest AND macos-latest so
# "protected + green" holds on both OSes a stranger's clone might run on.
# The job runs ONE command, scripts/quality-gates.sh — the single source of
# truth for the whole static gate set (board/build/install/hooks suites,
# Live/Drain + PR-body-lint registries, the kernel manifest/denylist/gitleaks
# scrub checks, and a whole-tree shellcheck). Add or change a gate THERE, not
# here.

on:
  pull_request:
  merge_group:
  push:
    branches: [main]

jobs:
  checks:
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
    steps:
      - uses: actions/checkout@v6

      - name: Install shellcheck (macOS)
        if: runner.os == 'macOS'
        run: brew install shellcheck

      - run: bash scripts/quality-gates.sh
CI_EOF
echo "  -> wrote .github/workflows/ci.yml (ubuntu + macOS matrix)"

echo "==> Done. Materialized $n kernel file(s) + LICENSE/NOTICE/SECURITY.md/CHANGELOG.md/Makefile/.github/workflows/ci.yml into $DEST"
