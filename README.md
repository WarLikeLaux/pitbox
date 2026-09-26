# pitbox

[![CI](https://github.com/WarLikeLaux/pitbox/actions/workflows/ci.yml/badge.svg)](https://github.com/WarLikeLaux/pitbox/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

English | [Русский](README-ru.md)

A coordination layer for parallel coding agents: reusable worktree workers, an explicit handoff marker, and a deterministic integration procedure. A bash CLI plus an MCP facade whose tool descriptions carry the workflow rules, so agents follow the process without any AGENTS.md edits.

## Why

AI coding agents step on each other when they share one checkout. Creating a worktree per task looks easy but leaves two problems: abandoned worktrees pile up as disk garbage, and an agent has no standard way to say "my task is finished, come collect it".

pitbox answers with three decisions. The worktrees are only the runtime. What pitbox owns is the task lifecycle around them: claim, work, ready, collect, release.

- A fixed pool of two or three slots created once next to the checkout and reused forever. No spawn per task, no leftovers, dependency installs are paid once per slot.
- A readiness marker. A slot agent finishes by writing `TASK_READY.md`, the integrator collects only marked slots, and the user's word always overrides the marker.
- A strict split of roles. Slot agents never merge and never deploy. The integrator collects, runs full checks, deploys, pushes, releases the slots back into the pool.

## How it works

```
your-repo/            your-repo-wt1/       your-repo-wt2/       your-repo-wt3/
main checkout         slot wt1             slot wt2             slot wt3
integrator only       agent + task branch  agent + task branch  spare
```

- One task: work directly in the main checkout, no slots involved.
- Two or three parallel tasks: one slot each, the main checkout belongs to the integrator.
- A slot agent books a slot with `pitbox claim` (it atomically reserves a free slot and creates the task branch), verifies inside the slot, commits, pushes, then marks the slot ready.
- The integrator collects ready slots, runs the repository's full checks, deploys, pushes, and releases the slots back to the pool.

## Quick start

Requires bash, git, and node only for the MCP server. Windows works through WSL.

```bash
curl -fsSL https://raw.githubusercontent.com/WarLikeLaux/pitbox/main/bin/pitbox -o ~/.local/bin/pitbox
chmod +x ~/.local/bin/pitbox
```

Prepare a repository once:

```bash
cd your-repo
pitbox init      # writes .slots/ templates, auto-detects bun or php + docker
pitbox setup     # creates ../your-repo-wt1 .. wt3 and installs dependencies in each
```

Optionally teach git to ignore the readiness marker globally, so agents do not see it in `git status` (pitbox already excludes it from its own checks):

```bash
git config --global core.excludesFile ~/.config/git/ignore
mkdir -p ~/.config/git && echo TASK_READY.md >> ~/.config/git/ignore
```

Everyday commands:

| Command | What it does |
|---------|--------------|
| `pitbox init [--stack S] [--force]` | Write `.slots/` templates for this repository (stacks: `bun`, `php-docker`, auto-detected) |
| `pitbox setup [N]` | Create the slot pool, default three slots |
| `pitbox claim [slot] [name]` | Atomically book a free slot and create the task branch in it (auto-picks when the slot is omitted) |
| `pitbox status` | Branch, dirty files, commits ahead of main, readiness per slot |
| `pitbox ready <slot> [note]` | Mark the slot's task ready, records the branch HEAD, refuses dirty or stub-branch slots |
| `pitbox collect <slot\|ready>` | Merge the slot's task branch into the main branch with `--no-ff`, refuses a dirty or off-branch main checkout and slots changed after the marker |
| `pitbox release <slot>` | Reset the slot to main, delete the merged branch, run release hooks |
| `pitbox guide` | Print the full workflow rules for agents |

## MCP server

The MCP server is a zero-dependency stdio facade over the CLI. It exists so agents see the workflow rules without any AGENTS.md edits: every tool description embeds the relevant rule, and the `guide` tool returns the complete workflow.

Point any MCP client at it:

```json
{
  "mcpServers": {
    "pitbox": {
      "command": "node",
      "args": ["/path/to/pitbox/mcp/server.mjs"]
    }
  }
}
```

Claude Code:

```bash
claude mcp add pitbox -- node /path/to/pitbox/mcp/server.mjs
```

Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.pitbox]
command = "node"
args = ["/path/to/pitbox/mcp/server.mjs"]
```

The server resolves the repository from the client's working directory, so run your agent inside the repository as usual.

### Tools reference

| Tool | Purpose |
|------|---------|
| `guide` | Full workflow rules, call once before using the others |
| `status` | Slot pool state, call it before integrating; to start a task use `claim`, never book a slot by hand |
| `claim` | Book a free slot atomically and create your task branch in it |
| `setup` | Create the fixed slot pool, never spawn ad-hoc worktrees |
| `ready` | Mark a slot ready, records the branch HEAD, refuses dirty or stub-branch slots, never merge yourself |
| `collect` | Integrator: merge a slot branch, or `ready` for all marked slots, refuses dirty or off-branch main checkouts |
| `release` | Integrator: return a collected slot to the pool |
| `init` | Write `.slots/` templates for a repository, commit the result |

## Plugins for Claude Code and Codex

The plugin bundles the MCP server and the `integrate` skill, so both the workflow rules and the integrator procedure arrive together.

Claude Code:

```
/plugin marketplace add WarLikeLaux/pitbox
/plugin install pitbox@pitbox
```

Codex: the repository ships `.agents/plugins/marketplace.json` and a plugin directory in the [agent-plugins.org](https://agent-plugins.org) layout (`plugin/plugin.json`, `plugin/mcp.json`). If your Codex build does not resolve `${CLAUDE_PLUGIN_ROOT}` in MCP configs, register the server manually as shown above and copy `plugin/skills/integrate` into your skills directory.

## Repository configuration

pitbox is global, repository specifics live in `.slots/` committed next to the code.

- `.slots/config`: shell variables, `MAIN_BRANCH=<branch>` overrides autodetection. Autodetect order: `MAIN_BRANCH` from config, then `origin/HEAD`, then the current branch. `REQUIRE_PUSH=1` makes `pitbox ready` demand a pushed branch, off by default.
- `.slots/setup.sh`: called with the slot directory as `$1` after a worktree is added and on release. The `bun` template runs `bun install --frozen-lockfile`, the `php-docker` template runs `composer install`.
- `.slots/release.sh`: optional extra cleanup on release, falls back to `setup.sh`.

`pitbox init` writes these templates and detects the stack from `composer.json` and `bun.lock` or `package.json`. Stack templates are the natural place for contributors to add new stacks.

For php + docker projects, parallel slots need per-slot compose isolation: a distinct `COMPOSE_PROJECT_NAME` per slot, unique host ports, and no fixed `container_name` in compose files. The template prints a reminder.

## Notes

- Slots live as sibling directories: `../your-repo-wt1` and so on, same parent as the checkout.
- Merges are `--no-ff` on purpose, task batches stay visible in history.
- Nothing here conflicts with native worktree features of specific agents. Claude Code sessions can use their built-in worktree isolation, pitbox is the shared pool and the collection procedure for everyone else.
- No npm package yet, install from the clone. Star the repo if you want one.

## License

[MIT](LICENSE)
