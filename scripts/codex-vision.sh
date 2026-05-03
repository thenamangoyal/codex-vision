#!/usr/bin/env bash
# codex-vision: pass images to/from the OpenAI Codex CLI from Claude Code.
# Modes: review | generate | edit
# Optional: --tmux <name> for an observable session prefixed "claude-codex-".

set -u
set -o pipefail

# ---------- locate codex binary ----------
locate_codex() {
  if command -v codex >/dev/null 2>&1; then
    command -v codex
    return 0
  fi
  if [[ -x "/Applications/Codex.app/Contents/Resources/codex" ]]; then
    echo "/Applications/Codex.app/Contents/Resources/codex"
    return 0
  fi
  return 1
}

CODEX_BIN="$(locate_codex || true)"
if [[ -z "${CODEX_BIN:-}" ]]; then
  echo "ERROR: codex CLI not found. Install Codex.app or run 'brew install codex' / npm-equivalent. https://github.com/openai/codex" >&2
  exit 127
fi

# ---------- usage ----------
usage() {
  cat <<'EOF'
codex-vision MODE [options] [args]

MODES
  review IMAGE [IMAGE...] PROMPT       Send image(s) + prompt; print Codex's text reply.
  generate PROMPT                       Ask Codex to generate an image via image_gen.
  edit IMAGE PROMPT                     Ask Codex to edit an image via image_gen.
  doctor                                Run preflight checks (codex binary, auth, tmux); print health report.
  selftest                              Run a real review against the bundled fixture; verifies end-to-end.

OPTIONS
  --out PATH                Output path for generated/edited image
                            (default: /tmp/codex-vision-out/<slug>.png)
  --tmux NAME               Run inside "claude-codex-NAME" tmux session.
                            User can attach with: tmux attach -t claude-codex-NAME
                            Logs to /tmp/claude-codex-NAME.log
  --keep                    Keep tmux session + log after completion (default: clean up).
  --model MODEL             Pass to `codex exec --model MODEL`.
  -h | --help               This help.

EXAMPLES
  codex-vision review /tmp/ui.png "What's wrong with this layout?"
  codex-vision generate "isometric GRPO group diagram" --out /tmp/grpo.png
  codex-vision edit /tmp/raw.png "remove the red overlay" --out /tmp/clean.png
  codex-vision review /tmp/ui.png "deep walk-through" --tmux ui-review

CONVENTIONS
  * tmux sessions are always prefixed "claude-codex-" so you know Claude spawned them.
    List with:  tmux ls | grep claude-codex-
    Kill all :  tmux ls | awk -F: '/claude-codex-/{print $1}' | xargs -n1 tmux kill-session -t
  * Logs at /tmp/claude-codex-<slug>.log (predictable for `tail -f`).
  * Image outputs default to /tmp/codex-vision-out/.
EOF
}

# ---------- parse mode ----------
if [[ $# -lt 1 ]]; then usage; exit 1; fi
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
MODE="$1"; shift
case "$MODE" in
  review|generate|edit|selftest|doctor) ;;
  *) echo "ERROR: unknown mode '$MODE'. Run with --help." >&2; exit 2 ;;
esac

# ---------- parse options + positional args ----------
OUT_PATH=""
TMUX_NAME=""
KEEP=0
MODEL=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_PATH="${2:-}"; shift 2 ;;
    --tmux) TMUX_NAME="${2:-}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

# ---------- helpers ----------
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//' | cut -c1-40
}

unique_session_name() {
  local base="$1" name="$1" n=2
  while tmux has-session -t "$name" 2>/dev/null; do
    name="${base}-${n}"
    n=$((n+1))
  done
  echo "$name"
}

ensure_out_path() {
  local mode="$1" slug="$2"
  if [[ -z "$OUT_PATH" ]]; then
    mkdir -p /tmp/codex-vision-out
    OUT_PATH="/tmp/codex-vision-out/${mode}-${slug}-$(date +%s).png"
  fi
  mkdir -p "$(dirname "$OUT_PATH")"
}

run_codex() {
  # All input goes through one entrypoint so tmux-mode and direct-mode share a code path.
  local args=("exec" "--skip-git-repo-check")
  [[ -n "$MODEL" ]] && args+=("--model" "$MODEL")
  # bash 3.2: ${IMAGES[@]:-} is unreliable on empty arrays under set -u.
  if [[ ${#IMAGES[@]} -gt 0 ]]; then
    for img in "${IMAGES[@]}"; do
      [[ -n "$img" ]] && args+=("-i" "$img")
    done
  fi
  # `-i` is variadic in codex 0.128 — `--` separates image list from PROMPT positional.
  args+=("--" "$PROMPT")

  if [[ -n "$TMUX_NAME" ]]; then
    local session
    session="claude-codex-$(unique_session_name "claude-codex-$(slugify "$TMUX_NAME")" | sed 's/^claude-codex-//')"
    # ^ unique_session_name returns full name; reconstruct cleanly:
    session="$(unique_session_name "claude-codex-$(slugify "$TMUX_NAME")")"
    local log="/tmp/${session}.log"
    : > "$log"

    # Run codex inside tmux, tee output to the log.
    # `printf %q` quotes each arg safely for the shell tmux will run.
    local cmd
    cmd="$(printf '%q ' "$CODEX_BIN" "${args[@]}")"
    tmux new-session -d -s "$session" "bash -lc '${cmd} 2>&1 | tee ${log}; echo --- codex-vision done ---'"

    echo "[codex-vision] tmux session  : $session"
    echo "[codex-vision] attach with   : tmux attach -t $session"
    echo "[codex-vision] tail log with : tail -f $log"

    # Wait for the inner command to finish, then capture and clean up.
    while tmux has-session -t "$session" 2>/dev/null; do
      if grep -q -- '--- codex-vision done ---' "$log" 2>/dev/null; then break; fi
      sleep 1
    done

    cat "$log"

    if [[ "$KEEP" -eq 0 ]]; then
      tmux kill-session -t "$session" 2>/dev/null || true
      rm -f "$log"
    fi
  else
    "$CODEX_BIN" "${args[@]}"
  fi
}

# ---------- mode dispatch ----------
case "$MODE" in
  review)
    if [[ ${#POSITIONAL[@]} -lt 2 ]]; then
      echo "ERROR: review needs at least one IMAGE and a PROMPT." >&2; usage; exit 2
    fi
    # bash 3.2 (macOS default) does not support negative array indices.
    _last_idx=$(( ${#POSITIONAL[@]} - 1 ))
    PROMPT="${POSITIONAL[$_last_idx]}"
    IMAGES=("${POSITIONAL[@]:0:$_last_idx}")
    for img in "${IMAGES[@]}"; do
      [[ -f "$img" ]] || { echo "ERROR: image not found: $img" >&2; exit 2; }
    done
    run_codex
    ;;

  generate)
    if [[ ${#POSITIONAL[@]} -ne 1 ]]; then
      echo "ERROR: generate needs exactly one PROMPT." >&2; usage; exit 2
    fi
    USER_PROMPT="${POSITIONAL[0]}"
    ensure_out_path "gen" "$(slugify "$USER_PROMPT")"
    PROMPT="Use the built-in image_gen tool to generate the following image: ${USER_PROMPT}. Save the result to ${OUT_PATH}. After saving, print only the absolute output path on its own line, then a one-sentence summary."
    IMAGES=()
    run_codex
    [[ -f "$OUT_PATH" ]] && echo "[codex-vision] image written: $OUT_PATH"
    ;;

  edit)
    if [[ ${#POSITIONAL[@]} -ne 2 ]]; then
      echo "ERROR: edit needs exactly IMAGE and PROMPT." >&2; usage; exit 2
    fi
    SRC_IMAGE="${POSITIONAL[0]}"
    USER_PROMPT="${POSITIONAL[1]}"
    [[ -f "$SRC_IMAGE" ]] || { echo "ERROR: image not found: $SRC_IMAGE" >&2; exit 2; }
    ensure_out_path "edit" "$(slugify "$USER_PROMPT")"
    PROMPT="Use the built-in image_gen tool to edit the attached image with this instruction: ${USER_PROMPT}. Save the edited result to ${OUT_PATH}. After saving, print only the absolute output path on its own line, then a one-sentence summary of what changed."
    IMAGES=("$SRC_IMAGE")
    run_codex
    [[ -f "$OUT_PATH" ]] && echo "[codex-vision] image written: $OUT_PATH"
    ;;

  doctor)
    echo "[codex-vision] doctor — preflight checks"
    echo "  codex binary : $CODEX_BIN"
    echo "  codex version: $("$CODEX_BIN" --version 2>&1 | head -1)"
    if command -v tmux >/dev/null 2>&1; then
      echo "  tmux         : $(tmux -V)"
    else
      echo "  tmux         : NOT FOUND (--tmux mode unavailable; brew install tmux)"
    fi
    # Auth probe — minimal exec; if it fails fast with an auth-y message, surface that.
    auth_probe="$("$CODEX_BIN" exec --skip-git-repo-check 'reply with the single word: ok' 2>&1 | tail -20)"
    if echo "$auth_probe" | grep -qiE 'unauthor|not logged|login|api key|expired|forbid'; then
      echo "  auth         : FAIL — run 'codex login' (probe said: $(echo "$auth_probe" | head -3 | tr '\n' ' '))"
      exit 1
    elif echo "$auth_probe" | grep -qi 'ok'; then
      echo "  auth         : OK"
    else
      echo "  auth         : UNKNOWN — probe output: $(echo "$auth_probe" | head -3 | tr '\n' ' ')"
    fi
    echo "  fixture PNG  : $(dirname "$0")/../tests/fixture.png $(test -f "$(dirname "$0")/../tests/fixture.png" && echo OK || echo MISSING)"
    echo "[codex-vision] doctor complete."
    ;;

  selftest)
    FIXTURE="$(dirname "$0")/../tests/fixture.png"
    [[ -f "$FIXTURE" ]] || { echo "ERROR: bundled fixture missing at $FIXTURE" >&2; exit 1; }
    echo "[codex-vision] selftest — running review on bundled fixture (320x200, three coloured swatches)"
    PROMPT="In one short line, list the three solid-coloured rectangles you see at the top of this image, left to right, by their dominant hue (e.g. red, green, blue). Then on a second line write OK if you can see them, FAIL if you cannot."
    IMAGES=("$FIXTURE")
    run_codex
    echo "[codex-vision] selftest complete. Visually verify Codex reported: red/dark-red, green/dark-green, gold/yellow → OK"
    ;;
esac
