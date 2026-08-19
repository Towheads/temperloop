#!/usr/bin/env bash
#
# validate-clean-host-ks-search.sh — OPT-IN, MANUALLY INVOKED clean-host
# validation of the stranger first-run ks_search path (temperloop#1635).
#
# Run it with:  make validate-clean-host-ks-search
#          or:  bash workflows/scripts/dev/validate-clean-host-ks-search.sh
#
# ── WHY THIS IS NOT A GATE, AND MUST NEVER BECOME ONE ─────────────────────
# It performs a REAL `uv tool install` over the network, in a container, and
# downloads a Python interpreter and an embedding model. Kernel principle 3
# ("deterministic tests over recorded fixtures, never live-network") forbids
# exactly that inside the gated suite — a KERNEL_GATES entry firing a real
# install from inside a hermetic sandbox is the HIGH review finding that
# blocked temperloop#1113's first attempt. So this script is deliberately
# absent from scripts/quality-gates.sh, from KERNEL_GATES, and from every
# .github/workflows/ job. Its `make` target exists so it is discoverable and
# reproducible, not so anything runs it automatically.
#
# ── WHEN TO RUN IT ────────────────────────────────────────────────────────
# When the install path or its pins change: KNOWLEDGE_SEARCH_BM_VERSION,
# KNOWLEDGE_SEARCH_BM_PYTHON, _ks_bm_install_tool, _ks_bm_tool_ready, the
# availability gate, or the cold-start index. Those are the surfaces whose
# tests all stub `uv`, so the suite cannot see a flag real uv rejects, an
# entry point that lands somewhere the adapter does not look, or an install
# that succeeds into a search that answers out of an empty index (the defect
# this validation actually found — docs/validation/clean-host-ks-search.md).
#
# ── WHY A CONTAINER, NOT A SCRATCH HOME ───────────────────────────────────
# A scratch `HOME=` on the developer's Mac is cheaper but proves less: it
# shares the host's PATH, its uv build, its architecture and its already-warm
# caches, so "clean" is a claim about environment variables rather than about
# the machine. A container starts from a published image with `uv` and
# nothing else, on Linux, which is what a stranger's first contact actually
# looks like. Ratified by the operator when this item was scoped.
#
# ── SHAPE ─────────────────────────────────────────────────────────────────
#   1. preflight — Docker must be present AND its daemon reachable. A missing
#      daemon FAILS LOUDLY (exit 2). It is never a skip: a validation that
#      quietly passes when it did not run is worse than no validation.
#   2. build a small image: the published uv image plus `jq` (which the
#      adapter itself needs) and CA certificates. ripgrep is deliberately NOT
#      installed, so ks_search's score-0 lexical fallback cannot manufacture
#      a hit — see the probe's own header.
#   3. `docker create` + `docker cp` the adapter's lib/ and the probe in, then
#      `docker start -a`. Files go in by `docker cp` rather than a bind mount
#      on purpose: a VM-backed Docker (colima, Docker Desktop) only mounts a
#      configured subset of the host filesystem, so a bind mount of a checkout
#      outside that subset silently mounts an EMPTY directory. `docker cp`
#      streams a tar over the daemon socket and works from any path.
#   4. stream the probe's transcript and propagate its exit code.
#
# Options:
#   --keep                 leave the container behind for inspection
#   --image TAG            image tag to build/use (default below)
#   --platform PLATFORM    docker --platform value (default: the host's own
#                          architecture — see the note in the VERDICT block)
#   --run-timeout SECS     bound on the probe run    (default 1800)
#   --build-timeout SECS   bound on the image build  (default 900)
#   -h | --help            this header's usage summary
#
# Exit codes: 0 = every probe assertion passed; 1 = a probe assertion failed
# (or the run timed out); 2 = preflight/usage failure — Docker missing,
# daemon unreachable, or an unknown flag.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

IMAGE_TAG="temperloop/clean-host-ks-search:probe"
PLATFORM=""
KEEP=0
RUN_TIMEOUT=1800
BUILD_TIMEOUT=900

usage() {
  cat <<'USAGE'
usage: validate-clean-host-ks-search.sh [options]

Opt-in, manually invoked. Runs the stranger first-run ks_search path inside a
clean Linux Docker container: a real uv-tool install of the pinned
basic-memory, a first search over a fixture corpus, and a second search that
must install nothing. Never part of any gate or CI job (temperloop#1635).

  --keep                 leave the container behind for inspection
  --image TAG            image tag to build/use
  --platform PLATFORM    docker --platform value (default: host architecture)
  --run-timeout SECS     bound on the probe run   (default 1800)
  --build-timeout SECS   bound on the image build (default 900)
  -h, --help             show this message

Exit: 0 pass, 1 assertion failure/timeout, 2 preflight or usage failure.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --keep)          KEEP=1; shift ;;
    --image)         IMAGE_TAG="${2:?--image requires a value}"; shift 2 ;;
    --platform)      PLATFORM="${2:?--platform requires a value}"; shift 2 ;;
    --run-timeout)   RUN_TIMEOUT="${2:?--run-timeout requires a value}"; shift 2 ;;
    --build-timeout) BUILD_TIMEOUT="${2:?--build-timeout requires a value}"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) printf 'validate-clean-host-ks-search: unrecognised argument "%s"\n\n' "$1" >&2
       usage >&2; exit 2 ;;
  esac
done

# shellcheck source=/dev/null
source "$REPO_ROOT/workflows/scripts/lib/portable-timeout.sh"

die() { printf '\nvalidate-clean-host-ks-search: %s\n' "$1" >&2; exit "${2:-2}"; }

# ---------------------------------------------------------------------------
# 1. Preflight — LOUD, never a skip.
# ---------------------------------------------------------------------------
printf '=== preflight ===\n'
command -v docker >/dev/null 2>&1 || die \
  "docker is not on PATH. This validation REQUIRES a real Linux container — it
  cannot degrade to a host-local run and must not be reported as skipped.
  Install Docker (or colima: 'brew install colima && colima start') and re-run." 2

if ! docker_info="$(run_with_timeout 60 docker info --format '{{.ServerVersion}} {{.OSType}}/{{.Architecture}}' 2>&1)"; then
  printf '%s\n' "$docker_info" >&2
  die "the Docker daemon is not reachable (see the output above). Start it
  ('colima start', or launch Docker Desktop) and re-run. This is a FAILURE,
  not a skip: the whole point of this script is that it actually executes." 2
fi
printf 'docker daemon: %s\n' "$docker_info"

host_arch="$(printf '%s' "$docker_info" | awk '{print $2}')"
printf 'container platform: %s\n' "${PLATFORM:-$host_arch (host default)}"  # setting:exempt — PLATFORM is this script's own --platform flag variable, never an env setting
if [ -n "$PLATFORM" ]; then
  printf '\nNOTE: --platform was passed explicitly (%s). A run under emulation is\n' "$PLATFORM"
  printf 'NOT the same evidence as a native one — record which you used.\n\n'
fi

# ---------------------------------------------------------------------------
# 2. Build the image.
# ---------------------------------------------------------------------------
printf '\n=== building %s ===\n' "$IMAGE_TAG"
build_args=(build -t "$IMAGE_TAG")
[ -n "$PLATFORM" ] && build_args+=(--platform "$PLATFORM")
build_args+=(-)

# Dockerfile on stdin, no build context: nothing from the checkout is sent to
# the daemon, so the image can never accidentally bake in a stale copy of the
# adapter. The adapter arrives later, by `docker cp`, straight from this
# working tree.
#
# `jq` is a genuine adapter dependency (it reshapes basic-memory's JSON), so
# installing it is not a shortcut. `ripgrep` is NOT installed, deliberately:
# without it ks_search's score-0 lexical fallback cannot fire, and a hit is
# provably a real backend hit.
if ! run_with_timeout "$BUILD_TIMEOUT" docker "${build_args[@]}" <<'DOCKERFILE'
FROM ghcr.io/astral-sh/uv:debian-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq ca-certificates \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE
then
  die "image build failed (or exceeded ${BUILD_TIMEOUT}s)" 1
fi

# ---------------------------------------------------------------------------
# 3. Create, populate, run.
# ---------------------------------------------------------------------------
create_args=(create)
[ -n "$PLATFORM" ] && create_args+=(--platform "$PLATFORM")
create_args+=(
  -e KS_PROBE_LIB=/ks-lib
  -e KS_PROBE_CORPUS=/corpus
  -e KS_PROBE_BM_HOME=/clean/bm-home
  "$IMAGE_TAG" bash /clean-host-ks-search-probe.sh
)

CONTAINER_ID="$(docker "${create_args[@]}")" \
  || die "could not create the container" 1

# Invoked indirectly, by the EXIT trap below.
# shellcheck disable=SC2329
cleanup() {
  if [ "$KEEP" -eq 1 ]; then
    printf '\n--keep: container left behind as %s\n' "$CONTAINER_ID"
    printf 'inspect it with: docker start -ai %s\n' "$CONTAINER_ID"
    return
  fi
  docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker cp "$REPO_ROOT/workflows/scripts/lib" "$CONTAINER_ID:/ks-lib" >/dev/null \
  || die "could not copy the adapter libraries into the container" 1
docker cp "$SCRIPT_DIR/clean-host-ks-search-probe.sh" \
  "$CONTAINER_ID:/clean-host-ks-search-probe.sh" >/dev/null \
  || die "could not copy the probe into the container" 1

printf '\n=== running the clean-host probe (bound: %ss) ===\n' "$RUN_TIMEOUT"
run_with_timeout "$RUN_TIMEOUT" docker start -a "$CONTAINER_ID"
rc=$?

printf '\n=== driver verdict ===\n'
case "$rc" in
  0)   printf 'PASS — every clean-host assertion held (container platform: %s)\n' \
         "${PLATFORM:-$host_arch}" ;;  # setting:exempt — the --platform flag variable, not an env setting
  137) printf 'FAIL — the probe exceeded the %ss bound. That IS a finding about\n' "$RUN_TIMEOUT"
       printf 'stranger first-run cost; record the observed duration rather than\n'
       printf 'raising the bound reflexively.\n'
       rc=1 ;;
  *)   printf 'FAIL — the probe reported failing assertions (exit %s). Read the\n' "$rc"
       printf 'FAIL lines and the OBSERVED blocks above; they are the evidence.\n' ;;
esac
exit "$rc"
