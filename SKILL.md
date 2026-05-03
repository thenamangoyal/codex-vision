---
name: codex-vision
description: Use when the user wants Claude to send images to OpenAI Codex (review screenshots, generate images via Codex's image_gen tool, edit images), or explicitly invokes "codex-vision". Wraps the upstream `codex exec -i` CLI with three modes (review / generate / edit) and an opt-in tmux session prefixed `claude-codex-` so the user can attach and watch.
---

# codex-vision

Wraps the OpenAI Codex CLI (the upstream binary at `/Applications/Codex.app/Contents/Resources/codex`) for vision tasks — image input, image generation, image editing — so Claude can call Codex without writing temp files manually or shelling out by hand each time.

## When to invoke this skill

- User asks Claude to "have Codex look at this screenshot" / "use codex on this PNG"
- User asks "generate an image with Codex" / "use Codex's image tool"
- User asks Codex to edit / annotate / clean up an image file
- User explicitly says "use codex-vision" or "/codex-vision"
- A screenshot exists on disk (e.g. saved by `mcp__claude-in-chrome__computer` with `save_to_disk: true`) and the user wants a second-opinion analysis from Codex

## How to invoke

The skill is a single shell wrapper. From the Bash tool:

```bash
~/.claude/skills/codex-vision/scripts/codex-vision.sh <mode> [options] <args>
```

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

### Conventions Claude must follow

- **Always prefix tmux sessions with `claude-codex-`.** The script enforces this; never bypass it. Lets the user identify Claude-spawned sessions with `tmux ls | grep claude-codex-`.
- **Logs go to `/tmp/claude-codex-<slug>.log`** — predictable so user can `tail -f` independently.
- **Images output to `/tmp/codex-vision-out/`** by default.
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

If a user asks "how do I install codex-vision" or wants to share it with someone, the canonical install path (assuming `claude` CLI is on PATH) is:

```bash
claude plugin marketplace add thenamangoyal/codex-vision
claude plugin install codex-vision
```

Or interactively inside Claude Code:
```
/plugin marketplace add thenamangoyal/codex-vision
/plugin install codex-vision
```

Drop-in fallback (no plugin manager): `git clone https://github.com/thenamangoyal/codex-vision ~/.claude/skills/codex-vision`. After install, `<skill-dir>/scripts/codex-vision.sh doctor && selftest` verifies the install end-to-end.

## Don't

- Don't bypass the `claude-codex-` prefix — it's how the user identifies sessions Claude spawned.
- Don't leave logs/sessions around unless `--keep` was passed.
- Don't write images to the user's repo without asking; default `/tmp/codex-vision-out/` is safe.
- Don't use `--tmux` for trivial 5-second reviews — it's pure overhead there.
