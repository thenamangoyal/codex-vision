# codex-vision — changelog

## 2026-07-10 — fix: find the codex CLI bundled inside ChatGPT.app (+ `CODEX_VISION_CODEX_BIN` override)

**Why.** The standalone Codex.app can be moved or uninstalled, and recent builds ship the codex CLI
**inside ChatGPT.app** (`/Applications/ChatGPT.app/Contents/Resources/codex`) now that the Codex app
merged into ChatGPT.app. `locate_codex()` only checked `command -v codex` and
`/Applications/Codex.app/...`, so `generate`/`edit`/`review` failed with "no codex found" even when a
working codex (codex-cli 0.144.0) sat on disk inside ChatGPT.app.

**Fix.** `locate_codex()` now resolves, in order: (1) `$CODEX_VISION_CODEX_BIN` explicit override,
(2) `command -v codex` on PATH, (3) `Codex.app` then `ChatGPT.app` bundles under `/Applications` and
per-user `~/Applications`. `print_install_help()` and the SKILL.md detection order were updated to
match. Verified with `doctor`: resolves `/Applications/ChatGPT.app/Contents/Resources/codex` with no
PATH hacks.

## 2026-06-18 (2) — fix: generate/edit now WORK (extract the image from the session rollout)

**The real root cause.** On `codex-cli 0.140.x`, `image_gen.imagegen` takes **only** a `prompt` — it
has **no** output-path / destination / filename parameter — and in headless `codex exec` it writes
**no file**. It returns the PNG **inline**, and codex persists that inline artifact in the session
**rollout log** (`~/.codex/sessions/**/rollout-*.jsonl`) as base64 at `payload.result` of an
`image_generation_call` / `image_generation_end` event. So the bytes always existed; nothing on disk
ever exposed them. (Confirmed by asking the model for the tool schema, then locating the base64 in the
rollout — a real 1254×1254 PNG.)

**Fix.** `extract_image_from_rollout()` (python3) finds the newest rollout written **this run** (mtime
≥ a per-run marker), decodes the latest embedded PNG, and writes it straight to `--out`.
`collect_generated_image()` now tries, in order: (1) rollout extraction (this build), (2) the on-disk
`ig_*.png` claim (builds that *do* write a file) — and still **refuses to write** (`exit 3`) if neither
yields a fresh image, so a stale image can never leak. `generate`/`edit` produce real images again.

**Also.** `CODEX_SESSIONS_DIR` is now env-overridable (was hard-assigned) so the path is testable.
`selftest` reports `image_gen: OK — extracted from session rollout (<n> bytes)` on this build.

**Test.** `tests/test_rollout_extract.sh` (no Codex/network) drives hidden `__rollouttest` with
synthetic rollout fixtures: (A) extracts an embedded PNG from a fresh rollout, (B) refuses when only a
stale rollout exists, (C) handles `image_generation_call` and picks the newest rollout. Run:
`bash tests/test_rollout_extract.sh`.

---

## 2026-06-18 — fix: stale-image leak on generate/edit (the "regenerate returns the previous image" bug)

**Symptom.** `codex-vision generate "<prompt>" --out X` (even with `--fresh`) printed a reply that
matched the prompt but wrote an **unrelated image from a previous session** to `X`; the real image
was nowhere on disk.

**Root cause (investigated).** The wrapper instructed *the model* to `cp` "the most recent file in
your session dir" to `--out`. On this Codex build (`codex-cli 0.140.0-alpha.19`), `image_gen`
**produces no new file** — the model reports success but writes nothing — so the model's `cp` grabbed
the newest *pre-existing* `ig_*.png` from `~/.codex/generated_images/` (a leftover from an earlier
session). The wrapper then trusted that copy. So two things combined: (a) the wrapper trusted the
model to select the file, and (b) image_gen was silently a no-op.

**Fix.** The *wrapper* now claims the image (`claim_generated_image()`): before each run it touches a
marker, and afterwards it selects the newest `ig_*.png` (under `~/.codex/generated_images` + the `-C`
workspace) **newer than the marker** — i.e. produced *this run* — and copies that to `--out`. If no
fresh image exists, it **refuses to write** (`exit 3`) instead of leaking a stale one. A stale image
from a prior session can no longer reach `--out`.

**Diagnosability.** `selftest` now probes `image_gen` end-to-end and reports
`image_gen: NOT PRODUCING FILES on this codex build` when the build can't generate — so the failure
is explicit, not mysterious.

**Test.** `tests/test_select_image.sh` (no Codex/network needed) drives the hidden `__claimtest` mode:
(A) picks the fresh image over a stale one, (B) returns empty when only stale images exist (refuse to
write), (C) finds a fresh image in an extra workspace dir. Run: `bash tests/test_select_image.sh`.

**Note.** `review` mode is unaffected and works. `generate`/`edit` will fail-safe until a Codex build
with a working `image_gen` (producing files) is installed.
