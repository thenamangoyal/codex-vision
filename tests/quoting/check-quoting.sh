#!/usr/bin/env bash
# Regression test: tmux mode must survive shell-special chars in the prompt.
#
# History: a prompt containing a single quote (e.g. "Papa's") used to break the
# `bash -lc '…'` nesting in run_codex's tmux branch — `printf %q` produced
# `Papa\'s`, which closed the outer single-quoted string. The session would
# launch, the inner command would die before printing anything, the log would
# stay empty, and the script would silently return.
#
# This test stubs the codex binary, runs the wrapper in tmux mode with prompts
# containing every awkward char we can think of, and asserts each prompt
# arrives at the stub byte-for-byte.
#
# We bake the capture path into each stub at write time (rather than relying
# on env vars) because tmux servers don't inherit the calling shell's env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$ROOT/scripts/codex-vision.sh"

WORK="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK"
  tmux ls 2>/dev/null | awk -F: '/^claude-codex-quoting-/{print $1}' \
    | xargs -n1 -I{} tmux kill-session -t {} 2>/dev/null || true
}
trap cleanup EXIT

PATHDIR="$WORK/bin"
mkdir -p "$PATHDIR"

pass=0
fail=0

check_prompt() {
  local label="$1" prompt="$2"
  local capture="$WORK/capture-$label.txt"
  local fixture="$ROOT/tests/fixture.png"

  # Per-test stub with the capture path baked in. The tmux child can't see the
  # caller's env, so the path must be embedded.
  cat > "$PATHDIR/codex" <<EOF
#!/usr/bin/env bash
{
  printf 'argc=%d\n' "\$#"
  for a in "\$@"; do
    printf 'arg=%s\n' "\$a"
  done
} > "$capture"
EOF
  chmod +x "$PATHDIR/codex"

  PATH="$PATHDIR:$PATH" "$WRAPPER" review "$fixture" "$prompt" \
    --tmux "quoting-$label" >/dev/null 2>&1 || true

  if [[ ! -f "$capture" ]]; then
    echo "  FAIL [$label]: stub never ran (capture file missing)"
    fail=$((fail+1))
    return
  fi

  # Wrapper places PROMPT as the final positional arg (after `--`).
  local got
  got="$(awk '/^arg=/{ sub(/^arg=/, ""); last=$0 } END{ print last }' "$capture")"
  if [[ "$got" == "$prompt" ]]; then
    echo "  PASS [$label]"
    pass=$((pass+1))
  else
    echo "  FAIL [$label]"
    echo "    expected: $(printf '%q' "$prompt")"
    echo "    got     : $(printf '%q' "$got")"
    fail=$((fail+1))
  fi
}

echo "[codex-vision] tmux quoting regression — prompts must reach codex intact"

check_prompt apostrophe   "Papa's angioplasty report"
check_prompt double-quote 'he said "ok" and left'
check_prompt backtick     'use `image_gen` for this'
check_prompt dollar       'cost is $5 and rising'
check_prompt backslash    'path is C:\Users\foo'
check_prompt mixed        $'Papa'\''s "report" — `cost`: $5'
check_prompt unicode      'résumé — naïve façade ✓'

echo "[codex-vision] result: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
