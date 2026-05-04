#!/usr/bin/env bash
# check-triggering.sh — evaluate codex-vision SKILL.md gating against tests/triggering/cases.yaml.
#
# How it works
# ------------
# Reads SKILL.md and tests/triggering/cases.yaml, batches all cases into a single
# `codex exec` call, and asks Codex to classify each user prompt as FIRE / SKIP /
# CLARIFY purely on the basis of what's in SKILL.md. Then compares against the
# `expected` label per case and reports.
#
# Failure modes the test catches
# ------------------------------
# - FALSE POSITIVE  : SKILL.md too loose, fires when it should not.
# - FALSE NEGATIVE  : SKILL.md too tight, skips when it should fire.
# - AMBIGUITY       : phrasing in SKILL.md leads to inconsistent verdicts.
#
# Verdict semantics
# -----------------
# FIRE      — the skill should auto-invoke for this user prompt.
# SKIP      — the skill should not fire; route to a different tool.
# CLARIFY   — intent is genuinely ambiguous; pause and ask.
#
# The hard pass/fail bar is on FIRE-vs-not-FIRE: any case expected `fire` that
# Codex labels SKIP or CLARIFY counts as a failure (false negative). Any case
# expected `skip` that Codex labels FIRE counts as a failure (false positive).
# `clarify`-expected cases pass if Codex returns either CLARIFY or SKIP.
#
# Usage
# -----
#   bash scripts/check-triggering.sh              # run with default cases
#   bash scripts/check-triggering.sh --runs 3     # run 3 trials, take majority
#   bash scripts/check-triggering.sh --json       # machine-readable output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
SKILL_MD="$SKILL_DIR/SKILL.md"
CASES="$SKILL_DIR/tests/triggering/cases.yaml"

RUNS=1
JSON_OUT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="$2"; shift 2 ;;
    --json) JSON_OUT=1; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# Resolve codex binary (matches the wrapper's auto-detection).
if command -v codex >/dev/null 2>&1; then
  CODEX="$(command -v codex)"
elif [[ -x /Applications/Codex.app/Contents/Resources/codex ]]; then
  CODEX="/Applications/Codex.app/Contents/Resources/codex"
else
  echo "FAIL: codex CLI not found on PATH or at /Applications/Codex.app/..." >&2
  exit 1
fi

# Build the eval prompt.
prompt_file="$(mktemp -t check-triggering-prompt.XXXXXX)"
trap 'rm -f "$prompt_file"' EXIT

{
  cat <<'INSTR'
You are evaluating skill triggering for an autonomous coding agent.

Below is a Claude Code "skill" — a small package whose YAML `description` field
plus body content is what the agent reads to decide whether to auto-invoke the
skill on a given user message. Your job: for each numbered user prompt in the
final block, decide whether this skill should auto-fire on that prompt.

Output verdicts as one verdict per line, in the form `Tnn: VERDICT`, where
VERDICT is one of:
  FIRE      — the skill should auto-invoke
  SKIP      — the skill should NOT fire; route to a different tool
  CLARIFY   — intent is genuinely ambiguous; the agent should pause and ask
             the user before invoking either path

Output only the lines `Tnn: VERDICT` — no extra commentary, no preamble.
Output exactly one line per input prompt.

INSTR

  echo "==== SKILL.md ===="
  cat "$SKILL_MD"
  echo "==== END SKILL.md ===="
  echo
  echo "==== USER PROMPTS ===="
  python3 - <<PY
import yaml
data = yaml.safe_load(open("$CASES"))
for c in data["cases"]:
    print(f"{c['id']}: {c['prompt']}")
PY
  echo "==== END USER PROMPTS ===="
} > "$prompt_file"

# Run the eval N times, accumulate verdicts in a file.
all_runs="$(mktemp -t check-triggering-runs.XXXXXX)"
trap 'rm -f "$prompt_file" "$all_runs"' EXIT

for run in $(seq 1 "$RUNS"); do
  if (( JSON_OUT == 0 )); then
    echo "[check-triggering] run $run/$RUNS — calling codex exec…"
  fi
  "$CODEX" exec - < "$prompt_file" 2>/dev/null \
    | grep -E '^(T[0-9]+|[0-9]+)[:.] *(FIRE|SKIP|CLARIFY)' \
    >> "$all_runs" || true
done

# Tally per-case majority verdict and compare to expected.
python3 - "$CASES" "$all_runs" "$JSON_OUT" <<'PY'
import sys, yaml, re, json, collections
cases_path, runs_path, json_out = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
cases = yaml.safe_load(open(cases_path))["cases"]
expected = {c["id"]: c["expected"].upper() for c in cases}
prompts = {c["id"]: c["prompt"] for c in cases}

per_case_votes = collections.defaultdict(collections.Counter)
with open(runs_path) as f:
    for line in f:
        m = re.match(r"^(T\d+)[:.]\s*(FIRE|SKIP|CLARIFY)", line.strip(), re.I)
        if not m:
            continue
        per_case_votes[m.group(1).upper()][m.group(2).upper()] += 1

verdicts = {}
for cid in expected:
    if per_case_votes[cid]:
        verdicts[cid] = per_case_votes[cid].most_common(1)[0][0]
    else:
        verdicts[cid] = "MISSING"

# Pass/fail rules:
#   expected=fire     → must be FIRE
#   expected=skip     → must be SKIP (CLARIFY counted as soft fail / mismatch)
#   expected=clarify  → either CLARIFY or SKIP passes
fp = []   # false positives: expected skip/clarify, got FIRE
fn = []   # false negatives: expected fire, got SKIP/CLARIFY
mismatches = []  # other label disagreements that don't break the hard bar

for cid, exp in expected.items():
    got = verdicts[cid]
    if exp == "FIRE" and got != "FIRE":
        fn.append((cid, got, prompts[cid]))
    elif exp == "SKIP" and got == "FIRE":
        fp.append((cid, got, prompts[cid]))
    elif exp == "CLARIFY" and got == "FIRE":
        fp.append((cid, got, prompts[cid]))
    elif exp != got:
        mismatches.append((cid, exp, got, prompts[cid]))

passed = sum(1 for c in expected if (
    (expected[c] == "FIRE" and verdicts[c] == "FIRE") or
    (expected[c] == "SKIP" and verdicts[c] == "SKIP") or
    (expected[c] == "CLARIFY" and verdicts[c] in ("CLARIFY", "SKIP"))
))
total = len(expected)

if json_out:
    print(json.dumps({
        "total": total,
        "passed": passed,
        "false_positives": [{"id": c, "got": g, "prompt": p} for c, g, p in fp],
        "false_negatives": [{"id": c, "got": g, "prompt": p} for c, g, p in fn],
        "soft_mismatches": [{"id": c, "expected": e, "got": g, "prompt": p} for c, e, g, p in mismatches],
        "verdicts": verdicts,
    }, indent=2))
else:
    print()
    print(f"[check-triggering] {passed}/{total} passed")
    print(f"  false positives (expected skip/clarify, got FIRE): {len(fp)}")
    print(f"  false negatives (expected fire, got SKIP/CLARIFY): {len(fn)}")
    print(f"  soft mismatches (clarify⇄skip): {len(mismatches)}")
    if fp:
        print("\nFalse positives (FAIL — skill firing when it shouldn't):")
        for cid, got, p in fp:
            print(f"  {cid}: got {got} (expected {expected[cid]})")
            print(f"        \"{p}\"")
    if fn:
        print("\nFalse negatives (FAIL — skill skipping when it should fire):")
        for cid, got, p in fn:
            print(f"  {cid}: got {got} (expected FIRE)")
            print(f"        \"{p}\"")
    if mismatches:
        print("\nSoft mismatches (informational):")
        for cid, exp, got, p in mismatches:
            print(f"  {cid}: got {got} (expected {exp})")

# Exit non-zero on any hard failure (FP or FN).
sys.exit(0 if not fp and not fn else 1)
PY
