#!/usr/bin/env bash
# Regression test for the stale-image bug (codex-vision generate/edit returning a PREVIOUS session's
# image). The fix: the wrapper — not the model — claims the image produced THIS run via
# claim_generated_image(), selecting the newest ig_*.png NEWER than a per-run marker, and returns
# EMPTY when only stale images exist (so generate/edit refuse to write a stale file).
# This exercises the hidden `__claimtest` entrypoint; no Codex/network needed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CV="$HERE/../scripts/codex-vision.sh"
PASS=0; FAIL=0
ok()  { echo "  ok   : $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL : $1"; FAIL=$((FAIL+1)); }

# --- A: a fresh image was produced this run -> claim returns IT, not the stale one ---
A="$(mktemp -d)"; genA="$A/generated_images/sess-new"; mkdir -p "$genA"
touch -t 202601010000 "$genA/ig_STALE.png"          # leftover from a prior session
markerA="$A/marker"; touch "$markerA"
sleep 1
: > "$genA/ig_FRESH.png"                             # produced THIS run (newer than the marker)
outA="$(CODEX_GENERATED_DIR="$A/generated_images" bash "$CV" __claimtest "$markerA")"
case "$outA" in
  *ig_FRESH.png) ok "picks the fresh image, ignores the stale one";;
  *)             bad "A: expected …/ig_FRESH.png, got '$outA'";;
esac
rm -rf "$A"

# --- B: ONLY stale images exist -> claim returns EMPTY (the stale-leak guard) ---
B="$(mktemp -d)"; genB="$B/generated_images/sess-old"; mkdir -p "$genB"
touch -t 202601010000 "$genB/ig_STALE.png"
markerB="$B/marker"; touch "$markerB"               # marker is NEWER than the only (stale) image
outB="$(CODEX_GENERATED_DIR="$B/generated_images" bash "$CV" __claimtest "$markerB")"
if [ -z "$outB" ]; then ok "no fresh image -> empty (refuse to write a stale image)"; else bad "B: expected empty, got '$outB'"; fi
rm -rf "$B"

# --- C: also finds an image in an EXTRA dir (the -C workspace), recursively ---
C="$(mktemp -d)"; mkdir -p "$C/generated_images" "$C/workspace/sub"
markerC="$C/marker"; touch "$markerC"; sleep 1
: > "$C/workspace/sub/ig_WS.png"
outC="$(CODEX_GENERATED_DIR="$C/generated_images" bash "$CV" __claimtest "$markerC" "$C/workspace")"
case "$outC" in
  *ig_WS.png) ok "finds a fresh image in an extra (workspace) dir";;
  *)          bad "C: expected …/ig_WS.png, got '$outC'";;
esac
rm -rf "$C"

echo "codex-vision select-image test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
