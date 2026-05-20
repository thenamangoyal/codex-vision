#!/usr/bin/env bash
# Stress-test: session continuation modes.
#
# Verifies the four behaviors of the wrapper's --resume / --resume-last-vision
# / --fresh flags + the smart-default heuristic:
#
#   1. Fresh-by-default — two back-to-back generate calls produce DIFFERENT
#      session UUIDs (no flag, no follow-up phrasing).
#   2. Resume-explicit — second call with --resume <UUID> reuses that UUID.
#   3. Heuristic-resume — second call whose prompt contains "now also" auto-
#      resumes the cached session.
#   4. Heuristic-fresh — second call with non-follow-up phrasing starts a
#      brand-new session even though a cache exists.
#
# How it works:
#   * We stub the codex binary. The stub fabricates a session rollout file
#     under $CODEX_HOME/sessions/<YYYY>/<MM>/<DD>/rollout-...-<UUID>.jsonl
#     matching the real codex naming convention.
#   * `codex exec resume <UUID>` is recognized — the stub does NOT create a
#     new rollout file (it appends a marker line to the existing one), so
#     newest_session_uuid() in the wrapper still returns the resumed UUID.
#   * We point $CODEX_HOME at an empty tmpdir, so the wrapper's
#     newest_session_uuid() scan sees only files our stub created.
#   * The wrapper caches the post-call UUID to .last-session-uuid; we read
#     that file to assert what UUID the wrapper actually decided to use.
#
# This keeps the test offline-friendly and deterministic. To exercise the
# real `codex exec` path, see the LIVE_MODE block at the bottom — opt in
# with `RUN_LIVE=1 ./check-session-modes.sh`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$ROOT/scripts/codex-vision.sh"
CACHE_FILE="$ROOT/.last-session-uuid"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$SCRIPT_DIR/results-$STAMP.md"

# --- tmp workspace -----------------------------------------------------------
WORK="$(mktemp -d)"
PATHDIR="$WORK/bin"
mkdir -p "$PATHDIR"

# Preserve any existing cache so the real user state is untouched.
SAVED_CACHE=""
if [[ -f "$CACHE_FILE" ]]; then
  SAVED_CACHE="$(cat "$CACHE_FILE")"
fi

cleanup() {
  rm -rf "$WORK"
  rm -f "$CACHE_FILE"
  if [[ -n "$SAVED_CACHE" ]]; then
    printf '%s\n' "$SAVED_CACHE" > "$CACHE_FILE"
  fi
}
trap cleanup EXIT

# --- write the codex stub ----------------------------------------------------
# The stub mimics two flows:
#   * `codex exec ... <PROMPT>`           → write a fresh rollout
#   * `codex exec resume <UUID> ... <P>`  → append to existing rollout
# It also accepts `--version` for any defensive probe.
cat > "$PATHDIR/codex" <<'STUB'
#!/usr/bin/env bash
# Fake codex CLI for codex-vision session-mode tests.
set -u

if [[ "${1:-}" == "--version" ]]; then
  echo "codex-cli stub 0.0.0"
  exit 0
fi

# Strip the leading "exec".
if [[ "${1:-}" != "exec" ]]; then
  echo "stub: unsupported subcommand $1" >&2
  exit 64
fi
shift

# Detect resume.
SESSIONS_ROOT="${CODEX_HOME:-$HOME/.codex}/sessions"
mkdir -p "$SESSIONS_ROOT"

RESUME_UUID=""
if [[ "${1:-}" == "resume" ]]; then
  shift
  RESUME_UUID="${1:-}"
  shift
fi

# Drain any flags + the rest of the args. We don't care what they are.
while [[ $# -gt 0 ]]; do shift; done

# Date scaffolding matches the real layout.
Y="$(date +%Y)"; M="$(date +%m)"; D="$(date +%d)"
TS="$(date +%Y-%m-%dT%H-%M-%S)"
DIR="$SESSIONS_ROOT/$Y/$M/$D"
mkdir -p "$DIR"

if [[ -n "$RESUME_UUID" ]]; then
  # Append to the existing rollout (find by suffix). If missing, create.
  existing="$(ls -1 "$SESSIONS_ROOT"/*/*/*/rollout-*-"$RESUME_UUID".jsonl 2>/dev/null | head -1 || true)"
  if [[ -z "$existing" ]]; then
    existing="$DIR/rollout-$TS-$RESUME_UUID.jsonl"
    printf '{"type":"session_meta","payload":{"id":"%s"}}\n' "$RESUME_UUID" > "$existing"
  fi
  printf '{"type":"event_msg","payload":{"resumed":true}}\n' >> "$existing"
  echo "[stub] resumed session $RESUME_UUID"
  # bump mtime so newest-scan picks this file
  touch "$existing"
  exit 0
fi

# Fresh session — fabricate a unique UUID. v7-ish (timestamp-prefixed).
hex8()  { LC_ALL=C tr -dc '0-9a-f' < /dev/urandom | head -c 8; }
hex4()  { LC_ALL=C tr -dc '0-9a-f' < /dev/urandom | head -c 4; }
hex12() { LC_ALL=C tr -dc '0-9a-f' < /dev/urandom | head -c 12; }
UUID="$(hex8)-$(hex4)-$(hex4)-$(hex4)-$(hex12)"
ROLLOUT="$DIR/rollout-$TS-$UUID.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s"}}\n' "$UUID" > "$ROLLOUT"
echo "[stub] fresh session $UUID"
# tiny sleep so back-to-back fresh calls have distinct mtimes for sort -rn
sleep 0.05
STUB
chmod +x "$PATHDIR/codex"

# --- helpers ----------------------------------------------------------------
pass=0
fail=0
RESULTS=()

record() {
  local status="$1" name="$2" detail="$3"
  RESULTS+=("$status|$name|$detail")
  if [[ "$status" == "PASS" ]]; then
    pass=$((pass+1))
    echo "  PASS [$name] $detail"
  else
    fail=$((fail+1))
    echo "  FAIL [$name] $detail"
  fi
}

run_wrapper() {
  # Run the wrapper with our stub on PATH and a private CODEX_HOME.
  # Suppress the wrapper's stderr noise from the test transcript.
  PATH="$PATHDIR:$PATH" \
    CODEX_HOME="$WORK/codex" \
    "$WRAPPER" "$@" 2>>"$WORK/wrapper.stderr" >>"$WORK/wrapper.stdout"
}

read_cache() {
  [[ -f "$CACHE_FILE" ]] && tr -d '[:space:]' < "$CACHE_FILE" || echo ""
}

reset_state() {
  # Each test starts with no cache and no prior sessions, so heuristics and
  # newest-scans are deterministic.
  rm -f "$CACHE_FILE"
  rm -rf "$WORK/codex"
  mkdir -p "$WORK/codex/sessions"
  : > "$WORK/wrapper.stdout"
  : > "$WORK/wrapper.stderr"
}

# --- tests ------------------------------------------------------------------
echo "[codex-vision] session-modes stress test — stubbed codex"
echo "  workdir : $WORK"
echo "  report  : $REPORT"
echo

# 1. Fresh-by-default ---------------------------------------------------------
reset_state
run_wrapper generate "draw a red circle on white" --out "$WORK/test-fresh-1.png"
UUID1="$(read_cache)"
run_wrapper generate "draw a red circle on white" --out "$WORK/test-fresh-2.png"
UUID2="$(read_cache)"
if [[ -n "$UUID1" && -n "$UUID2" && "$UUID1" != "$UUID2" ]]; then
  record PASS "fresh-by-default" "uuids differ: ${UUID1:0:8}… ≠ ${UUID2:0:8}…"
else
  record FAIL "fresh-by-default" "uuid1=${UUID1:-EMPTY} uuid2=${UUID2:-EMPTY}"
fi

# 2. Resume-explicit ----------------------------------------------------------
reset_state
run_wrapper generate "draw a red circle on white" --out "$WORK/test-explicit-1.png"
UUID_BASE="$(read_cache)"
run_wrapper generate "now add a blue square" --resume "$UUID_BASE" --out "$WORK/test-explicit-2.png"
UUID_AFTER="$(read_cache)"
if [[ -n "$UUID_BASE" && "$UUID_AFTER" == "$UUID_BASE" ]]; then
  record PASS "resume-explicit" "cache stayed at ${UUID_BASE:0:8}…"
else
  record FAIL "resume-explicit" "before=${UUID_BASE:-EMPTY} after=${UUID_AFTER:-EMPTY}"
fi

# 3. Heuristic-resume ---------------------------------------------------------
reset_state
run_wrapper generate "draw a circle" --out "$WORK/test-heur-resume-1.png"
UUID_H1="$(read_cache)"
run_wrapper generate "now also add a square" --out "$WORK/test-heur-resume-2.png"
UUID_H2="$(read_cache)"
if [[ -n "$UUID_H1" && "$UUID_H1" == "$UUID_H2" ]]; then
  record PASS "heuristic-resume" "cache preserved at ${UUID_H1:0:8}… (heuristic fired on 'now also')"
else
  record FAIL "heuristic-resume" "before=${UUID_H1:-EMPTY} after=${UUID_H2:-EMPTY}"
fi

# 4. Heuristic-fresh ----------------------------------------------------------
reset_state
run_wrapper generate "draw a circle" --out "$WORK/test-heur-fresh-1.png"
UUID_F1="$(read_cache)"
run_wrapper generate "render a completely new mockup of a TUI" --out "$WORK/test-heur-fresh-2.png"
UUID_F2="$(read_cache)"
if [[ -n "$UUID_F1" && -n "$UUID_F2" && "$UUID_F1" != "$UUID_F2" ]]; then
  record PASS "heuristic-fresh" "uuids differ: ${UUID_F1:0:8}… ≠ ${UUID_F2:0:8}… (no follow-up phrasing)"
else
  record FAIL "heuristic-fresh" "before=${UUID_F1:-EMPTY} after=${UUID_F2:-EMPTY}"
fi

# 5. --fresh flag overrides heuristic ----------------------------------------
reset_state
run_wrapper generate "draw a circle" --out "$WORK/test-fresh-flag-1.png"
UUID_FF1="$(read_cache)"
run_wrapper generate "now also add a square" --fresh --out "$WORK/test-fresh-flag-2.png"
UUID_FF2="$(read_cache)"
if [[ -n "$UUID_FF1" && -n "$UUID_FF2" && "$UUID_FF1" != "$UUID_FF2" ]]; then
  record PASS "fresh-flag-override" "uuids differ: ${UUID_FF1:0:8}… ≠ ${UUID_FF2:0:8}… (--fresh defeated heuristic)"
else
  record FAIL "fresh-flag-override" "before=${UUID_FF1:-EMPTY} after=${UUID_FF2:-EMPTY}"
fi

# --- write report ------------------------------------------------------------
{
  echo "# codex-vision session-modes stress test — $STAMP"
  echo
  echo "Wrapper: \`$WRAPPER\`"
  echo "Stubbed codex; isolated CODEX_HOME at \`$WORK/codex\`."
  echo
  echo "## Results"
  echo
  echo "| Test | Status | Detail |"
  echo "|------|--------|--------|"
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r status name detail <<<"$r"
    echo "| $name | $status | $detail |"
  done
  echo
  echo "## Summary"
  echo
  echo "- pass: $pass"
  echo "- fail: $fail"
} > "$REPORT"

echo
echo "[codex-vision] session-modes result: $pass passed, $fail failed"
echo "[codex-vision] report: $REPORT"

[[ "$fail" -eq 0 ]]
