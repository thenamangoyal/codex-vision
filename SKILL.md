---
name: codex-vision
description: Use when the user wants Claude to send images to OpenAI Codex — Codex-side review of an existing screenshot/mockup/wireframe, generate an image via Codex's image_gen tool, or edit an existing image via Codex — or explicitly invokes "codex-vision" / "/codex-vision". Wraps the upstream `codex exec -i` CLI with three modes (review / generate / edit) and an opt-in tmux session prefixed `claude-codex-` so the user can attach and watch. SKIP when the task is text-only, or when the user needs a durable multi-turn repo task — use codex-tmux-dev for long-running image+coding work. The bare word "codex" is not a trigger; the bare word "screenshot" is not a trigger. For generate/edit, require explicit Codex intent unless the user invoked the skill by name. Explicit `/codex-vision` invocation overrides every other gating rule below.
---

# codex-vision

Wraps the OpenAI Codex CLI (the upstream binary at `/Applications/Codex.app/Contents/Resources/codex`) for vision tasks — image input, image generation, image editing — so Claude can call Codex without writing temp files manually or shelling out by hand each time.

## When to invoke this skill

Two ways to qualify:

**A. Explicit invocation — fires unconditionally.** Anything matching `use codex-vision`, `/codex-vision`, or a direct shell call to the wrapper. Image context is not required (the user is naming the skill on purpose).

**B. Image-intent triggers — require *image context AND Codex intent*.** Image context is one of: an existing image path/attachment (PNG, JPG, JPEG, WebP, GIF), a freshly produced screenshot the user is now referencing, or an explicit ask to generate/edit a visual artifact (mockup, wireframe, design image). The word "codex" alone is not enough; bare "screenshot" without a target file is not enough.

- User asks Claude to **have Codex look at** a specific screenshot or PNG/JPG path on disk → `review`.
- User asks Codex to **generate an image / mockup / wireframe / device-frame render** (Codex intent must be explicit — "generate a mock" alone routes to other tools) → `generate`.
- User asks Codex to **edit / annotate / clean up an existing image file** (path required) → `edit`.
- A screenshot was just produced (e.g. saved by `mcp__claude-in-chrome__computer` with `save_to_disk: true`) **AND** the user explicitly asks for a Codex-side review of *that* image — not just any follow-up Codex task that happens after the screenshot.

## When NOT to invoke this skill

Default to a plain `codex exec` or a durable Codex session skill when:

- User asks Codex to **review code, a PR, a diff, a function** — text-only, no image. The `-i` flag is irrelevant.
- User asks Codex to **write, refactor, or debug code** — call `codex exec "<prompt>"` directly.
- User asks Codex a **generic question** ("ask codex what it thinks of X", "have codex explain Y") with no image attached.
- User wants a **long-running repo coding session** with Codex, especially a screenshot-driven implementation loop — use the installed durable Codex/tmux workflow instead so the same repo-scoped Codex session can review, implement, test, and resume.
- User mentions "codex" but the actual artifact is text (logs, stack trace, JSON, code) — codex-vision adds nothing; the `image_gen` tool prompt would mislead the model.
- User has a screenshot on disk **but the current ask is unrelated** to that screenshot — don't auto-fire just because a PNG exists in `/tmp/`.

If the user's intent is ambiguous ("Codex, look at my work"), pause and ask whether the artifact is an image or text before invoking either path.

## How to invoke

The skill is a single shell wrapper. From the Bash tool:

```bash
~/.claude/skills/codex-vision/scripts/codex-vision.sh <mode> [options] <args>
```

## Long-Running Image Work

Do not use this skill's `--tmux` mode for durable repo work. That mode is only an observable wrapper around a one-shot `codex exec` call.

For tasks like "use this dashboard screenshot, redesign the page, implement the code, test it, and keep working later", use the installed durable Codex/tmux workflow instead of codex-vision. It should preserve the repo-scoped Codex UUID, support repeated image attachments, and keep input/output images in the repo's `.agent/codex/images/` handoff area.

## Artifact Storage

This skill is intentionally temporary and one-shot. Do not create or manage a repo-local `.agent/codex/` tree from codex-vision.

- Input images are read from the path the caller provides. If the caller gives a URL, download it to `/tmp/` first.
- Generated and edited images default to `/tmp/codex-vision-out/<slug>-<timestamp>.png`.
- tmux observation logs default to `/tmp/claude-codex-<slug>.log`.

If the user wants persistent repo-local image history, repeated screenshots, or generated assets tied to implementation work, route to the durable Codex/tmux workflow instead.

### Modes

| Mode | Synopsis | What it does |
|------|----------|--------------|
| `review IMAGE [IMAGE...] PROMPT` | one-shot image review | runs `codex exec -i ...` |
| `generate PROMPT` | ask Codex to generate an image | wraps prompt as "Use image_gen to <prompt>; save to <out>" |
| `edit IMAGE PROMPT` | ask Codex to edit an image | wraps prompt as "Use image_gen to edit the attached image: ..." |

### Options

| Option | Effect |
|--------|--------|
| `--out PATH` | output path for generated/edited image (default: `/tmp/codex-vision-out/<slug>-<ts>.png`) |
| `--tmux NAME` | run inside `claude-codex-<NAME>` tmux session; user can `tmux attach -t claude-codex-<NAME>` to watch live |
| `--keep` | leave tmux session + log after completion (default: clean up) |
| `--model MODEL` | pass to `codex exec --model` (e.g. `gpt-5-codex`) |
| `--resume UUID` | resume a specific codex session by id; useful when the caller already knows the UUID |
| `--resume-last-vision` | force-resume the most recent codex-vision session (cached at `~/.claude/skills/codex-vision/.last-session-uuid`) |
| `--fresh` | force a brand-new codex session even if the prompt's phrasing would trip the smart-resume heuristic |

### Session continuation

The wrapper keeps codex context warm across follow-up calls so iterating on a
mockup or re-reviewing an updated screenshot doesn't pay the cold-start cost
twice. Every successful call records the codex session UUID at
`~/.claude/skills/codex-vision/.last-session-uuid`, and the next call consults
that cache via a small heuristic:

- Auto-resume applies to **`review` only.** If a `review` prompt contains
  follow-up phrasing — `continue`, `iterate`, `follow up`, `based on the
  previous`, `again with`, `now also`, `now add`, `also add`, `refine`, `tweak`,
  `as before`, `same image`, `keep going` — the wrapper auto-resumes the cached
  session (re-reviewing an updated screenshot keeps context warm).
- **`generate` / `edit` NEVER auto-resume** (even with follow-up phrasing): a
  resumed image session re-emits ~the same image (the regenerate-same-image bug).
  They start fresh unless you pass `--resume <UUID>` / `--resume-last-vision`.
- Otherwise the wrapper starts fresh and updates the cache with the new UUID.

Flag overrides, in priority order: `--fresh` (always new) > `--resume UUID`
(use that exact UUID) > `--resume-last-vision` (force cache) > heuristic.

Resumed sessions reuse the codex sandbox + workspace config from their
original turn, so `generate` / `edit` writes to the same `OUT_PATH` parent
directory they did the first time without re-passing `--sandbox`. If the
cache file is missing, the heuristic silently falls through to a fresh
session — never errors.

### Conventions Claude must follow

- **Always prefix tmux sessions with `claude-codex-`.** The script enforces this; never bypass it. Lets the user identify Claude-spawned sessions with `tmux ls | grep claude-codex-`.
- **Logs go to `/tmp/claude-codex-<slug>.log`** — predictable so user can `tail -f` independently.
- **Images output to `/tmp/codex-vision-out/`** by default.
- **Do not write codex-vision images into `.agent/codex/`** — that folder belongs to durable repo-scoped Codex/tmux sessions.
- **Use `--tmux` only when** the run is expected to take >30s OR the user wants to observe / interrupt OR the user explicitly asks for a session. For quick image reviews, default to synchronous mode.
- **For mixed workflows** (input image + generated output), use `edit` mode — it sets up both halves in one Codex call.

## Examples

```bash
# Quick screenshot review
~/.claude/skills/codex-vision/scripts/codex-vision.sh review /tmp/ui.png "What's wrong with this layout?"

# Image generation
~/.claude/skills/codex-vision/scripts/codex-vision.sh generate "isometric diagram of a 4-trajectory GRPO group with advantages" --out /tmp/grpo.png

# Image editing
~/.claude/skills/codex-vision/scripts/codex-vision.sh edit /tmp/raw.png "remove the red overlay; make background transparent" --out /tmp/clean.png

# Long observable review
~/.claude/skills/codex-vision/scripts/codex-vision.sh review /tmp/ui.png "deep walk-through" --tmux ui-review
# user attaches with: tmux attach -t claude-codex-ui-review
```

## What Claude does when this skill fires

1. Identify mode from user intent: review (look at image) / generate (make image) / edit (modify image).
2. Resolve image paths — they should already exist on disk. If user gives a URL, download to `/tmp/` first.
3. Build the command using the shell wrapper. Single `Bash` call.
4. Choose sync vs `--tmux`: sync for short tasks; `--tmux` if the user wants to watch or task is long-running.
5. After the call, return Codex's text response (review mode) OR the output path + a one-line summary (generate / edit modes).
6. If a generated file exists at `OUT_PATH`, surface it to the user (e.g. "Image saved to `/tmp/codex-vision-out/...`").

## Prerequisites

The skill assumes:
- Codex CLI installed (`/Applications/Codex.app/Contents/Resources/codex` on macOS, or `codex` on PATH from the OpenAI Codex CLI)
- Codex authenticated — user has run `codex login` once (or signed into Codex.app)
- `tmux` installed if `--tmux` is used (`brew install tmux` on macOS)

The script auto-detects the codex binary in this order:
1. `which codex`
2. `/Applications/Codex.app/Contents/Resources/codex`
3. fail with a clear error message

## How users install the skill

If a user asks "how do I install codex-vision" or wants to share it with someone, install via [`npx skills`](https://skills.sh).

Claude Code only — drops directly into `~/.claude/skills/codex-vision/`:

```bash
npx skills add thenamangoyal/codex-vision -g -a claude-code -y
```

Every agent at once — Claude Code, Cursor, Codex CLI, Gemini CLI. Source is written once to `~/.agents/skills/codex-vision/` and symlinked into each agent's skills directory:

```bash
npx skills add thenamangoyal/codex-vision -g --all
```

Pin a specific version with `@v0.3.1`. Drop `-g` for project-scoped install. Uninstall with `npx skills remove codex-vision`.

Verify:

```bash
~/.claude/skills/codex-vision/scripts/codex-vision.sh doctor
~/.claude/skills/codex-vision/scripts/codex-vision.sh selftest
```

Drop-in fallback (no `npx skills`): `git clone https://github.com/thenamangoyal/codex-vision ~/.claude/skills/codex-vision`.

## Triggering test

The triggering eval (`tests/triggering/cases.yaml` + `scripts/check-triggering.sh`)
benchmarks the gating in this manifest against 50 hand-written user prompts —
15 should fire, 20 should skip, 15 should clarify. The runner batches all cases
into one `codex exec` call, parses verdicts, and fails on any false positive
(expected `skip`/`clarify` but model said FIRE) or false negative (expected
`fire` but model said SKIP/CLARIFY). Stable at 50/50 across 3 trial runs as of
v0.3.2. Run with:

```bash
bash ~/.claude/skills/codex-vision/scripts/check-triggering.sh             # one trial
bash ~/.claude/skills/codex-vision/scripts/check-triggering.sh --runs 3    # majority over 3
```

If you change the YAML `description` or the **When to invoke** / **When NOT to
invoke** sections, re-run the test and tighten phrasing until it returns to
50/50.

## Session-modes stress test

The session-continuation logic has its own regression test at
`tests/session-modes/check-session-modes.sh`. It stubs the codex CLI,
fabricates realistic rollout files under a private `CODEX_HOME`, and asserts
the four core behaviors: fresh-by-default, `--resume UUID`, heuristic-resume
(prompt contains follow-up phrasing), and heuristic-fresh (prompt does not).
A fifth case verifies `--fresh` defeats the heuristic. Each run writes a
markdown summary to `tests/session-modes/results-<timestamp>.md`. Run with:

```bash
bash ~/.claude/skills/codex-vision/tests/session-modes/check-session-modes.sh
```

The test is offline (no network, no real codex calls); re-run after any edit
to the wrapper's session-continuation block.

## Don't

- Don't bypass the `claude-codex-` prefix — it's how the user identifies sessions Claude spawned.
- Don't leave logs/sessions around unless `--keep` was passed.
- Don't write images to the user's repo without asking; default `/tmp/codex-vision-out/` is safe.
- Don't use `--tmux` for trivial 5-second reviews — it's pure overhead there.
