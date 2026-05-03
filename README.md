# codex-vision

A Claude Code skill that lets Claude pass images to (and request images from) the OpenAI Codex CLI without writing temp files by hand.

## Why

Claude Code can run `codex exec` via Bash, but the upstream `codex` CLI's image flag (`-i / --image`) is what actually unlocks Codex's vision features. The companion plugin most people use (`codex-companion.mjs`) doesn't pass `-i` through. This skill is a thin, opinionated wrapper that:

- Calls `codex exec -i ...` directly (skipping the companion that drops the flag)
- Picks predictable session/log names so the user always knows what Claude spawned
- Adds an opt-in tmux mode for long-running observable runs (`--tmux <name>` → `claude-codex-<name>`)
- Distinguishes three modes Claude actually uses: review, generate, edit

## Install

### Manual (this directory)

Drop the `codex-vision/` directory into your skills directory:

```bash
git clone <this-repo> /tmp/codex-vision-src
cp -r /tmp/codex-vision-src ~/.claude/skills/codex-vision
chmod +x ~/.claude/skills/codex-vision/scripts/codex-vision.sh
```

The skill auto-loads in any Claude Code session because `~/.claude/skills/` is the user-level skills directory (cross-project).

### As a Claude Code plugin

`.claude-plugin/plugin.json` is shipped so the directory can be installed via `claude plugin install` from any source the Claude Code CLI supports.

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
