# codex-vision

A Claude Code skill that lets Claude pass images to (and request images from) the OpenAI Codex CLI without writing temp files by hand.

## Why

Claude Code can run `codex exec` via Bash, but the upstream `codex` CLI's image flag (`-i / --image`) is what actually unlocks Codex's vision features. The companion plugin most people use (`codex-companion.mjs`) doesn't pass `-i` through. This skill is a thin, opinionated wrapper that:

- Calls `codex exec -i ...` directly (skipping the companion that drops the flag)
- Picks predictable session/log names so the user always knows what Claude spawned
- Adds an opt-in tmux mode for long-running observable runs (`--tmux <name>` → `claude-codex-<name>`)
- Distinguishes three modes Claude actually uses: review, generate, edit

## Install

### Recommended: as a Claude Code plugin

If you have the `claude` CLI on your PATH (Claude Code is already installed), this is one command:

```bash
claude plugin marketplace add thenamangoyal/codex-vision
claude plugin install codex-vision
```

Or from inside an interactive Claude Code session:

```
/plugin marketplace add thenamangoyal/codex-vision
/plugin install codex-vision
```

That's it — the skill loads in every project. Verify with:

```bash
~/.claude/plugins/.../codex-vision/scripts/codex-vision.sh doctor
~/.claude/plugins/.../codex-vision/scripts/codex-vision.sh selftest
```

To uninstall:

```bash
claude plugin uninstall codex-vision
```

### Alternative: drop-in skills directory (no plugin manager)

If you'd rather avoid the marketplace flow:

```bash
git clone https://github.com/thenamangoyal/codex-vision ~/.claude/skills/codex-vision
~/.claude/skills/codex-vision/scripts/codex-vision.sh doctor
~/.claude/skills/codex-vision/scripts/codex-vision.sh selftest
```

`~/.claude/skills/` is the user-level skills directory, so the skill auto-loads cross-project.

To uninstall:

```bash
rm -rf ~/.claude/skills/codex-vision
```

## Usage

The skill activates whenever a user prompt mentions Codex + an image, or explicitly invokes `/codex-vision`. Internally it shells out to:

```bash
~/.claude/skills/codex-vision/scripts/codex-vision.sh <mode> [options] <args>
```

### Modes

| Mode | Args | Use case |
|------|------|----------|
| `review` | `IMAGE [IMAGE...] PROMPT` | Have Codex look at one or more screenshots and report back |
| `generate` | `PROMPT` | Have Codex generate an image via its `image_gen.imagegen` tool |
| `edit` | `IMAGE PROMPT` | Have Codex edit an image via its `image_gen.imagegen` tool |

### Options

```
--out PATH         Output path for generated/edited image (default /tmp/codex-vision-out/<slug>-<ts>.png)
--tmux NAME        Run in claude-codex-<NAME>; user attaches with `tmux attach -t claude-codex-<NAME>`
--keep             Keep tmux session + log after completion
--model MODEL      Pass to `codex exec --model`
```

### Examples

```bash
# Quick review
codex-vision review screenshot.png "what's wrong here?"

# Generate
codex-vision generate "isometric GRPO group diagram" --out /tmp/grpo.png

# Edit
codex-vision edit raw.png "remove the red overlay" --out /tmp/clean.png

# Long-running, watchable
codex-vision review screenshot.png "deep walk-through of every issue" --tmux ui-review
# user runs: tmux attach -t claude-codex-ui-review
```

## How it routes

| Operation | What it triggers in Codex |
|-----------|---------------------------|
| `review`  | `codex exec -i <png>` → Codex's `functions.view_image` tool |
| `generate`| Prompt: `"Use the built-in image_gen tool to generate ... Save to ..."` |
| `edit`    | `codex exec -i <png>` + prompt: `"Use the built-in image_gen tool to edit the attached image..."` |

The exact tool name `image_gen.imagegen` and the natural-language convention come straight from Codex's own self-report. There is no `@image` or `/image` prefix — phrasing alone routes to the tool.

## Prerequisites

- Codex CLI installed (Codex.app on macOS, or `codex` on PATH)
- Codex authenticated (`codex login` once)
- tmux installed if you use `--tmux` mode

## License

MIT — do whatever you want, no warranty.
