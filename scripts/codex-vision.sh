#!/usr/bin/env bash
# codex-vision: pass images to/from the OpenAI Codex CLI from Claude Code.
# Modes: review | generate | edit
# Optional: --tmux <name> for an observable session prefixed "claude-codex-".

set -u
set -o pipefail

# ---------- locate codex binary ----------
locate_codex() {
  # Test hook: set CODEX_VISION_TEST_MISSING=1 to simulate a missing CLI without
  # actually uninstalling Codex. Used by tests; unset in normal use.
  if [[ -n "${CODEX_VISION_TEST_MISSING:-}" ]]; then
    return 1
  fi
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

print_install_help() {
  cat >&2 <<'EOF'
codex-vision needs the OpenAI Codex CLI installed. None was found at:
  • which codex                                       (anywhere on PATH)
  • /Applications/Codex.app/Contents/Resources/codex  (macOS Codex app)

Official install — pick one:

  Codex.app (macOS GUI, bundles the CLI inside it):
      brew install --cask codex                       # via Homebrew
      https://openai.com/codex/                       # or download the .dmg

  Codex CLI only (no GUI, any platform):
      npm install -g @openai/codex                    # via npm

After install, authenticate once (opens a browser):
  codex login

Re-run preflight to confirm:
  ~/.claude/skills/codex-vision/scripts/codex-vision.sh doctor

Upstream: https://github.com/openai/codex
codex-vision: https://github.com/thenamangoyal/codex-vision
EOF
}

# Resolve once; per-mode checks decide whether absence is fatal.
CODEX_BIN="$(locate_codex || true)"

require_codex() {
  if [[ -z "${CODEX_BIN:-}" ]]; then
    print_install_help
    exit 127
  fi
}

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
  --resume UUID             Resume a specific codex session by UUID.
  --resume-last-vision      Resume the most recent codex-vision session
                            (cached at ~/.claude/skills/codex-vision/.last-session-uuid).
  --fresh                   Force a new session even if the prompt looks like
                            a follow-up (overrides the resume heuristic).
  -h | --help               This help.

SESSION CONTINUATION
  Without any flag, codex-vision starts a fresh codex session and caches the
  resulting UUID. If your next prompt contains follow-up phrasing — "continue",
  "iterate", "now also", "now add", "again with", "based on the previous",
  "refine", "tweak", etc. — the wrapper auto-resumes the cached session so
  context stays warm. Use --fresh to opt out, --resume <UUID> to target a
  specific session, or --resume-last-vision to force-resume the cache.

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
  __claimtest) ;;   # hidden: exercise claim_generated_image() in tests (no codex needed)
  *) echo "ERROR: unknown mode '$MODE'. Run with --help." >&2; exit 2 ;;
esac

# ---------- parse options + positional args ----------
# Default model: gpt-5.5 — the current Codex generation as of May 2026.
# image_gen.imagegen quality is materially better on gpt-5.5+ vs older
# models, so we pin it here unless the user explicitly overrides via --model.
# This silently overrides anything in ~/.codex/config.toml that's older.
OUT_PATH=""
TMUX_NAME=""
KEEP=0
MODEL="gpt-5.5"
RESUME_UUID=""           # set by --resume <UUID>
RESUME_LAST_VISION=0     # set by --resume-last-vision
FRESH=0                  # set by --fresh — override heuristic
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_PATH="${2:-}"; shift 2 ;;
    --tmux) TMUX_NAME="${2:-}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --resume) RESUME_UUID="${2:-}"; shift 2 ;;
    --resume-last-vision) RESUME_LAST_VISION=1; shift ;;
    --fresh) FRESH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

# ---------- session-continuation state ----------
LAST_VISION_FILE="$(dirname "$0")/../.last-session-uuid"
CODEX_SESSIONS_DIR="${CODEX_HOME:-$HOME/.codex}/sessions"
# Where codex's image_gen writes its PNGs (overridable for tests). The wrapper — NOT the model —
# claims the image produced THIS run from here, so a stale image from a prior session can't leak.
CODEX_GENERATED_DIR="${CODEX_GENERATED_DIR:-${CODEX_HOME:-$HOME/.codex}/generated_images}"

# Heuristic: does the prompt look like a follow-up?
# We pick phrasings that strongly imply "build on the prior turn":
# continue, follow up, iterate, based on the previous, again with, now also,
# now add, still, refine, tweak, also add. Returns 0 (match) / 1 (no match).
prompt_looks_like_followup() {
  local p="$1"
  # Case-insensitive substring scan with bash 3.2 (no [[ =~ ]] flag for icase).
  local lower
  lower="$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')"
  local phrase
  for phrase in \
      "continue" \
      "follow up" \
      "follow-up" \
      "iterate" \
      "based on the previous" \
      "based on previous" \
      "again with" \
      "now also" \
      "now add" \
      "also add" \
      "refine" \
      "tweak" \
      "as before" \
      "same image" \
      "same one" \
      "keep going"
  do
    case "$lower" in
      *"$phrase"*) return 0 ;;
    esac
  done
  return 1
}

# Read the cached last-vision UUID (if any). Empty stdout if no file or empty.
read_last_vision_uuid() {
  if [[ -f "$LAST_VISION_FILE" ]]; then
    # Strip whitespace; the file is one line.
    tr -d '[:space:]' < "$LAST_VISION_FILE"
  fi
}

# Find the newest session rollout file under ~/.codex/sessions/ and pull its
# UUID from the filename. Used right after a fresh `codex exec` to capture
# the session id we just created.
#
# Filename shape:
#   rollout-2026-05-20T00-28-08-019e45e1-aaaa-77b3-9701-1c092aa1f8ae.jsonl
# UUID is everything between the trailing "<HH-MM-SS>-" and ".jsonl".
newest_session_uuid() {
  local newest
  # macOS `find -printf` is unavailable; use stat -f instead. Sort by mtime desc.
  newest="$(find "$CODEX_SESSIONS_DIR" -type f -name 'rollout-*.jsonl' 2>/dev/null \
    | xargs stat -f '%m %N' 2>/dev/null \
    | sort -rn \
    | head -1 \
    | awk '{ $1=""; sub(/^ /,""); print }')"
  [[ -z "$newest" ]] && return 1
  # Extract the trailing UUID. UUID is 36 chars: 8-4-4-4-12 hex with dashes.
  basename "$newest" \
    | sed -E 's/^rollout-.*-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/\1/'
}

# Write a UUID to .last-session-uuid (creates file if needed). Silent on empty.
write_last_vision_uuid() {
  local uuid="$1"
  [[ -z "$uuid" ]] && return 0
  printf '%s\n' "$uuid" > "$LAST_VISION_FILE"
}

# Resolve final resume target. Sets RESUME_TARGET (UUID or empty).
#   --fresh                 → empty (force new)
#   --resume UUID           → that UUID
#   --resume-last-vision    → cached UUID (fail if cache empty)
#   no flag + heuristic hit → cached UUID (silently fall through if empty)
#   no flag + no heuristic  → empty
resolve_resume_target() {
  local prompt_for_heuristic="$1"
  RESUME_TARGET=""
  if [[ "$FRESH" -eq 1 ]]; then
    return 0
  fi
  if [[ -n "$RESUME_UUID" ]]; then
    RESUME_TARGET="$RESUME_UUID"
    return 0
  fi
  if [[ "$RESUME_LAST_VISION" -eq 1 ]]; then
    RESUME_TARGET="$(read_last_vision_uuid)"
    if [[ -z "$RESUME_TARGET" ]]; then
      echo "ERROR: --resume-last-vision passed but no cached session at $LAST_VISION_FILE" >&2
      exit 2
    fi
    return 0
  fi
  # Heuristic AUTO-resume applies to `review` ONLY (re-reviewing an updated
  # screenshot benefits from warm context). `generate`/`edit` must NOT auto-resume:
  # a resumed image session re-emits ~the same image (the regenerate-same-image
  # bug). They resume only when the caller explicitly passes --resume /
  # --resume-last-vision (handled above). Conditions to auto-resume:
  #   (a) mode is review, (b) phrasing looks like a follow-up, (c) cached uuid exists.
  if [[ "$MODE" == "review" ]] && [[ -n "$prompt_for_heuristic" ]] && prompt_looks_like_followup "$prompt_for_heuristic"; then
    local cached
    cached="$(read_last_vision_uuid)"
    if [[ -n "$cached" ]]; then
      RESUME_TARGET="$cached"
    fi
  fi
}

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

# Claim the image image_gen produced DURING this run: the newest `ig_*.png` across
# $CODEX_GENERATED_DIR plus any extra dirs (e.g. the -C workspace) whose mtime is NEWER than MARKER
# (a file touched just before the run). Echo its path; empty if none. The WRAPPER copies this file —
# it never trusts the model's own `cp` — so a stale image from an earlier session cannot leak into
# OUT_PATH (the root cause of the "regenerate returns the previous image" bug). See tests/.
claim_generated_image() {
  local marker="$1"; shift
  local d f candidates=()
  for d in "$CODEX_GENERATED_DIR" "$@"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do
      [[ -n "$f" ]] && candidates+=("$f")
    done < <(find "$d" -type f -name 'ig_*.png' -newer "$marker" 2>/dev/null)
  done
  [[ ${#candidates[@]} -eq 0 ]] && return 0
  printf '%s\n' "${candidates[@]}" | xargs stat -f '%m %N' 2>/dev/null \
    | sort -rn | head -1 | awk '{ $1=""; sub(/^ /,""); print }'
}

run_codex() {
  # All input goes through one entrypoint so tmux-mode and direct-mode share a code path.
  #
  # Two subcommands:
  #   * `codex exec` — fresh session (RESUME_TARGET empty)
  #   * `codex exec resume <UUID>` — continue an existing session
  # Both accept the same shared flags below, so we build the prefix once.
  local args
  if [[ -n "${RESUME_TARGET:-}" ]]; then
    args=("exec" "resume" "$RESUME_TARGET" "--skip-git-repo-check")
    echo "[codex-vision] resuming session: $RESUME_TARGET" >&2
  else
    args=("exec" "--skip-git-repo-check")
  fi
  # `generate` and `edit` need to write the produced image to OUT_PATH.
  # codex defaults to read-only sandbox; switch to workspace-write AND
  # set the workspace (-C) to the OUT_PATH's parent directory, since
  # workspace-write only allows writes inside the workspace, $TMPDIR, and
  # ~/.codex/memories — not arbitrary paths under $HOME.
  if [[ "$MODE" == "generate" || "$MODE" == "edit" ]]; then
    # `codex exec resume` does NOT accept --sandbox / -C flags. They are
    # already baked into the resumed session's config. Only the fresh path
    # passes them.
    if [[ -z "${RESUME_TARGET:-}" ]]; then
      args+=("--sandbox" "workspace-write")
      args+=("-C" "$(dirname "$OUT_PATH")")
    fi
  fi
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
    session="$(unique_session_name "claude-codex-$(slugify "$TMUX_NAME")")"
    local log="/tmp/${session}.log"
    local runner="/tmp/${session}.runner.sh"
    : > "$log"

    # Build a runner script that holds the codex command in a bash array.
    # We can't safely embed `printf %q` output inside `bash -lc '…'` — a single
    # quote in a prompt (e.g. "Papa's") expands to `\'` which terminates the
    # outer single-quoted string and silently corrupts the run. Writing the
    # quoted args to a script file removes that nesting hazard entirely.
    {
      echo '#!/bin/bash'
      printf 'CMD=('
      printf ' %q' "$CODEX_BIN" "${args[@]}"
      echo ')'
      echo 'exec "${CMD[@]}"'
    } > "$runner"
    chmod +x "$runner"

    # The shell command tmux runs only references slugified paths (no quoting
    # hazards) and the runner — which has the codex args baked in.
    tmux new-session -d -s "$session" \
      "bash -lc '\"$runner\" 2>&1 | tee \"$log\"; echo --- codex-vision done --- | tee -a \"$log\"'"

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
      rm -f "$log" "$runner"
    fi
  else
    "$CODEX_BIN" "${args[@]}"
  fi

  # ---- record session UUID for future --resume-last-vision / heuristic ----
  # Strategy:
  #   * If we just RESUMED a session, codex reuses the same UUID — keep the
  #     cached one so subsequent follow-ups thread through it too.
  #   * If we ran fresh, scan ~/.codex/sessions and pick the newest rollout
  #     filename. That UUID is what we want to cache.
  # We do not gate on exit status — even partial runs persist a rollout, and
  # caching it is cheap; if the call failed hard there is no new file so the
  # cache stays correct.
  if [[ -n "${RESUME_TARGET:-}" ]]; then
    write_last_vision_uuid "$RESUME_TARGET"
  else
    local _new_uuid
    _new_uuid="$(newest_session_uuid 2>/dev/null || true)"
    if [[ -n "$_new_uuid" ]]; then
      write_last_vision_uuid "$_new_uuid"
      echo "[codex-vision] session id: $_new_uuid (cached for --resume-last-vision)" >&2
    fi
  fi
}

# ---------- mode dispatch ----------
case "$MODE" in
  review)
    require_codex
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
    resolve_resume_target "$PROMPT"
    run_codex
    ;;

  generate)
    require_codex
    if [[ ${#POSITIONAL[@]} -ne 1 ]]; then
      echo "ERROR: generate needs exactly one PROMPT." >&2; usage; exit 2
    fi
    USER_PROMPT="${POSITIONAL[0]}"
    ensure_out_path "gen" "$(slugify "$USER_PROMPT")"
    PROMPT="Use the built-in image_gen tool to generate the following image: ${USER_PROMPT}

After image_gen finishes, the resulting PNG will be at \`~/.codex/generated_images/<session-id>/ig_*.png\` (use the most recent file in your current session's directory). Use a shell command to \`cp\` that file to exactly: ${OUT_PATH}

Then on its own line print exactly the saved path, followed by a one-sentence summary of what you drew."
    IMAGES=()
    # Apply heuristic against the user's prompt, not the wrapped instructions.
    resolve_resume_target "$USER_PROMPT"
    _marker="$(mktemp -t cvmark.XXXXXX)"; rm -f "$OUT_PATH"
    run_codex
    _src="$(claim_generated_image "$_marker" "$(dirname "$OUT_PATH")")"; rm -f "$_marker"
    if [[ -n "$_src" ]]; then
      cp -f "$_src" "$OUT_PATH"
      echo "[codex-vision] image written: $OUT_PATH (source: $_src)"
    else
      rm -f "$OUT_PATH"   # never leave a stale image the model may have wrongly cp'd
      echo "ERROR: image_gen produced no NEW image this run (cached/failed generation) — refusing to write a stale image. Re-run (try --fresh, or restart Codex)." >&2
      exit 3
    fi
    ;;

  edit)
    require_codex
    if [[ ${#POSITIONAL[@]} -ne 2 ]]; then
      echo "ERROR: edit needs exactly IMAGE and PROMPT." >&2; usage; exit 2
    fi
    SRC_IMAGE="${POSITIONAL[0]}"
    USER_PROMPT="${POSITIONAL[1]}"
    [[ -f "$SRC_IMAGE" ]] || { echo "ERROR: image not found: $SRC_IMAGE" >&2; exit 2; }
    ensure_out_path "edit" "$(slugify "$USER_PROMPT")"
    PROMPT="Use the built-in image_gen tool to edit the attached image with this instruction: ${USER_PROMPT}

After image_gen finishes, the edited PNG will be at \`~/.codex/generated_images/<session-id>/ig_*.png\` (use the most recent file in your current session's directory). Use a shell command to \`cp\` that file to exactly: ${OUT_PATH}

Then on its own line print exactly the saved path, followed by a one-sentence summary of what changed."
    IMAGES=("$SRC_IMAGE")
    resolve_resume_target "$USER_PROMPT"
    _marker="$(mktemp -t cvmark.XXXXXX)"; rm -f "$OUT_PATH"
    run_codex
    _src="$(claim_generated_image "$_marker" "$(dirname "$OUT_PATH")")"; rm -f "$_marker"
    if [[ -n "$_src" ]]; then
      cp -f "$_src" "$OUT_PATH"
      echo "[codex-vision] image written: $OUT_PATH (source: $_src)"
    else
      rm -f "$OUT_PATH"
      echo "ERROR: image_gen produced no NEW image this run (cached/failed edit) — refusing to write a stale image. Re-run (try --fresh, or restart Codex)." >&2
      exit 3
    fi
    ;;

  doctor)
    echo "[codex-vision] doctor — preflight checks"
    if [[ -z "${CODEX_BIN:-}" ]]; then
      echo "  codex binary : NOT FOUND"
      if command -v tmux >/dev/null 2>&1; then
        echo "  tmux         : $(tmux -V)"
      else
        echo "  tmux         : NOT FOUND"
      fi
      echo "  fixture PNG  : $(dirname "$0")/../tests/fixture.png $(test -f "$(dirname "$0")/../tests/fixture.png" && echo OK || echo MISSING)"
      echo
      print_install_help
      exit 1
    fi
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
    require_codex
    FIXTURE="$(dirname "$0")/../tests/fixture.png"
    [[ -f "$FIXTURE" ]] || { echo "ERROR: bundled fixture missing at $FIXTURE" >&2; exit 1; }
    echo "[codex-vision] selftest — running review on bundled fixture (320x200, three coloured swatches)"
    PROMPT="In one short line, list the three solid-coloured rectangles you see at the top of this image, left to right, by their dominant hue (e.g. red, green, blue). Then on a second line write OK if you can see them, FAIL if you cannot."
    IMAGES=("$FIXTURE")
    resolve_resume_target "$PROMPT"
    run_codex
    echo "[codex-vision] review OK if Codex reported: red/dark-red, green/dark-green, gold/yellow."
    # ---- image_gen probe: does THIS codex build actually PRODUCE image files? ----
    echo "[codex-vision] selftest — probing image_gen (generate a tiny square)…"
    _pm="$(mktemp -t cvprobe.XXXXXX)"
    MODE="generate"; PROMPT="Use the image_gen tool to generate a 64x64 solid red square PNG, then stop."
    IMAGES=(); OUT_PATH="/tmp/codex-vision-out/probe-$$.png"; mkdir -p "$(dirname "$OUT_PATH")"; rm -f "$OUT_PATH"
    FRESH=1; resolve_resume_target "$PROMPT"; run_codex
    _pi="$(claim_generated_image "$_pm" "$(dirname "$OUT_PATH")")"; rm -f "$_pm"
    if [[ -n "$_pi" ]]; then
      echo "[codex-vision] image_gen: OK — produced $_pi"
    else
      echo "[codex-vision] image_gen: NOT PRODUCING FILES on this codex build ($("$CODEX_BIN" --version 2>&1 | head -1))."
      echo "               'review' works; 'generate'/'edit' will fail-safe (refuse to write a stale image) until"
      echo "               image_gen produces files (update Codex / check image_gen availability). This is the"
      echo "               root cause of the old 'regenerate returns the previous image' bug — now caught, not masked."
    fi
    echo "[codex-vision] selftest complete."
    ;;

  __claimtest)
    # Hidden test entrypoint: codex-vision __claimtest <marker> [extra-dir...]
    # Prints the image claim_generated_image() would copy (drives tests/test_select_image.sh).
    # Searches $CODEX_GENERATED_DIR (set by the test) + any extra dirs given.
    claim_generated_image "${POSITIONAL[@]}"
    ;;
esac
