# codex-vision — changelog

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
