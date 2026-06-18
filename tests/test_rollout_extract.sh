#!/usr/bin/env bash
# Regression test for the REAL image_gen fix: on codex-cli 0.140.x, image_gen.imagegen has no
# output-path param and writes no file in headless `codex exec` — it returns the PNG INLINE, which
# codex persists in the session rollout (.jsonl) as base64 at payload.result of an
# `image_generation_call`/`_end` event. extract_image_from_rollout() decodes the newest such image
# (from a rollout newer than a per-run marker) straight to --out. This drives the hidden
# `__rollouttest` entrypoint with synthetic rollout fixtures; no Codex/network needed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CV="$HERE/../scripts/codex-vision.sh"
PASS=0; FAIL=0
ok()  { echo "  ok   : $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL : $1"; FAIL=$((FAIL+1)); }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }

# A tiny but real 2x2 PNG, base64 — same shape codex stores at payload.result (starts iVBORw0KGgo).
PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGNkYPjPgAcw4ZMcAAjsAQ2tQ0n3AAAAAElFTkSuQmCC"

mk_rollout() {  # mk_rollout <file> <type> <b64>
  python3 - "$1" "$2" "$3" <<'PY'
import sys, json
path, typ, b64 = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "w") as f:
    f.write(json.dumps({"type":"event_msg","payload":{"type":"agent_message","message":"hi"}})+"\n")
    f.write(json.dumps({"type":"response_item","payload":{"type":typ,"result":b64}})+"\n")
PY
}

# --- A: rollout newer than the marker -> extracts the embedded PNG to --out ---
A="$(mktemp -d)"; S="$A/sessions/2026/06/18"; mkdir -p "$S"
markerA="$A/marker"; touch "$markerA"; sleep 1
mk_rollout "$S/rollout-2026-06-18T14-00-00-aaaa.jsonl" image_generation_end "$PNG_B64"
outA="$A/out.png"
res="$(CODEX_SESSIONS_DIR="$A/sessions" bash "$CV" __rollouttest "$markerA" "$outA")"
if [ -s "$outA" ] && python3 -c "import sys;sys.exit(0 if open('$outA','rb').read(8)==b'\x89PNG\r\n\x1a\n' else 1)"; then
  ok "extracts embedded PNG from a fresh rollout (got valid PNG at --out)"
else
  bad "A: expected a valid PNG at $outA (res='$res')"
fi
rm -rf "$A"

# --- B: ONLY a STALE rollout (older than the marker) -> refuse (no file, nonzero) ---
B="$(mktemp -d)"; S="$B/sessions/2026/06/17"; mkdir -p "$S"
mk_rollout "$S/rollout-2026-06-17T10-00-00-bbbb.jsonl" image_generation_end "$PNG_B64"
touch -t 202601010000 "$S/rollout-2026-06-17T10-00-00-bbbb.jsonl"   # force stale mtime
markerB="$B/marker"; touch "$markerB"                                # marker is NEWER than the rollout
outB="$B/out.png"
CODEX_SESSIONS_DIR="$B/sessions" bash "$CV" __rollouttest "$markerB" "$outB" >/dev/null 2>&1
if [ ! -e "$outB" ]; then ok "stale-only rollout -> no extraction (refuse to write stale)"; else bad "B: wrote $outB from a stale rollout"; fi
rm -rf "$B"

# --- C: image_generation_call (not _end) also works; newest rollout wins over an older fresh one ---
C="$(mktemp -d)"; S="$C/sessions/2026/06/18"; mkdir -p "$S"
markerC="$C/marker"; touch "$markerC"; sleep 1
mk_rollout "$S/rollout-2026-06-18T14-00-00-old.jsonl" image_generation_call "$PNG_B64"
sleep 1
mk_rollout "$S/rollout-2026-06-18T14-05-00-new.jsonl" image_generation_call "$PNG_B64"
outC="$C/out.png"
CODEX_SESSIONS_DIR="$C/sessions" bash "$CV" __rollouttest "$markerC" "$outC" >/dev/null 2>&1
if [ -s "$outC" ]; then ok "image_generation_call payloads extract; newest-rollout-first"; else bad "C: expected a PNG at $outC"; fi
rm -rf "$C"

echo "codex-vision rollout-extract test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
