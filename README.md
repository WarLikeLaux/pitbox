# pitbox

[![CI](https://github.com/WarLikeLaux/pitbox/actions/workflows/ci.yml/badge.svg)](https://github.com/WarLikeLaux/pitbox/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

English | [Русский](README-ru.md)

A coordination layer for parallel coding agents: reusable worktree workers, an explicit handoff marker, and a deterministic integration procedure. A single plugin skill covers slot work and integration. The bash CLI and MCP tools carry the same workflow rules. `pitbox init` writes only `.pitbox/` files.

## Why

AI coding agents step on each other when they share one checkout. Creating a worktree per task looks easy but leaves two problems: abandoned worktrees pile up as disk garbage, and an agent has no standard way to say "my task is finished, come collect it".

pitbox answers with three decisions. The worktrees are only the runtime. What pitbox owns is the task lifecycle around them: claim, work, ready, collect, release.

- A fixed pool of two or three slots created once next to the checkout and reused forever. No spawn per task, no leftovers, dependency installs are paid once per slot.
- A readiness marker. A slot agent finishes by marking the slot ready, the integrator collects only marked slots, and the user's word always overrides the marker. Slot state lives in the git directory under `pitbox/`, so nothing pollutes `git status` or gets committed by accident.
- Per-repository slot settings. `pitbox guide` renders `.pitbox/config`: when agents mark ready, what proof of work they show, and whether branches must be pushed. Repository instructions decide which tasks use slots and how delivery works.
- A strict split of roles. Slot agents never merge or deploy. The conversation that did slot work ends at ready, and a fresh conversation collects, pushes, and releases. It deploys only if the repository requires it.

## How it works

```
your-repo/            your-repo-wt1/       your-repo-wt2/       your-repo-wt3/
main checkout         slot wt1             slot wt2             slot wt3
integration           agent + task branch  agent + task branch  spare
```

- Repository instructions can route even a single task to a slot. Starting an agent in the main checkout does not make it the integrator.
- While slots are active, use the main checkout for integration in a separate conversation.
- A slot agent books a slot with `pitbox claim` (it atomically reserves a free slot and creates the task branch), verifies inside the slot, commits the task files, then marks the branch ready.
- The integrator collects ready slots, follows the repository's delivery rules, and releases the slots back to the pool. `INTEGRATE_CHECKS=auto|full|ci` controls its local checks.

By default (`READY_MODE=auto`) slot agents verify, commit, and mark work ready without waiting for review. Repositories that want confirmation before ready can set `READY_MODE=confirm`. The user explicitly asks a fresh conversation to collect when satisfied. `pitbox guide` prints the slot settings, and the repository's `AGENTS.md` should state any exception to direct-work rules such as deploy or review before commit. Pitbox never reads or edits `AGENTS.md`.

If you start coding agents in the main checkout and want them to choose a free slot, add this rule to the repository's `AGENTS.md`:

```md
- For an ordinary coding task, run `pitbox status` and `pitbox claim` without a slot number. Work in the returned worktree.
- A session that claimed a slot is its worker. Run relevant checks there, commit only task files, then run `pitbox ready`. Do not deploy, collect, release, or push the main branch.
- Integrate only on the user's explicit request, in a separate session that did no slot work. Deploy only if this repository requires it.
- Work explicitly assigned to the main checkout follows the repository's normal delivery policy.
```

You can keep using the same agent conversation. Feedback on a ready task before collection stays in its slot: the agent removes the marker with `unready` while fixing, so the slot stops advertising ready, and marks it ready again after. After collection and release, give the agent a new task. It checks status and claims a free slot without asking you for a slot number. A separate new task before collection needs another free slot.

## Quick start

Requires bash, git 2.31+, and node only for the MCP server. Windows works through WSL.

```bash
curl -fsSL https://raw.githubusercontent.com/WarLikeLaux/pitbox/main/bin/pitbox -o ~/.local/bin/pitbox
chmod +x ~/.local/bin/pitbox
```

Prepare a repository once:

```bash
cd your-repo
pitbox init      # writes .pitbox/ templates
pitbox setup     # creates ../your-repo-wt1 .. wt3 and installs dependencies in each
```

Slot markers are written into the git directory (`pitbox/slots/` inside `.git`), so no global git ignore is needed.

Everyday commands:

| Command | What it does |
|---------|--------------|
| `pitbox init [--stack S] [--force]` | Write `.pitbox/` templates without editing `AGENTS.md` (stacks: `bun`, `php-docker`, auto-detected) |
| `pitbox setup [N]` | Create the slot pool, default three slots |
| `pitbox claim [branch-name]` | Atomically book a free slot and create the task branch (auto-picks a slot, optionally pass a slot before the branch name) |
| `pitbox status` | Branch, dirty files, commits ahead of main, state (work/ready/collected) per slot, plus the active policy line |
| `pitbox ready <slot> [note]` | Mark the slot's task ready, records the branch HEAD, refuses dirty or stub-branch slots |
| `pitbox unready <slot>` | Remove the readiness marker while handling feedback, the slot returns to work until ready again |
| `pitbox collect <slot\|ready>` | Merge the slot's task branch into the main branch with `--no-ff`, refuses a dirty or off-branch main checkout and slots changed after the marker, collected slots are skipped until released |
| `pitbox release <slot>` | Reset the slot to main, delete the merged branch, run release hooks |
| `pitbox ci` | CI status of the pushed main commit: green (exit 0), red (exit 1), pending (exit 2) |
| `pitbox deploy-guard` | Exit nonzero while a slot is ready and uncollected, for deploy scripts to call as a gate |
| `pitbox guide` | Print the workflow rules for this repository, rendered from `.pitbox/config` |

## MCP server

The MCP server is a zero-dependency stdio facade over the CLI. The `guide` tool returns the complete workflow rendered from the repository's policy, and a hanging `.pitbox` hook cannot block a tool call forever (default timeout 120 s, override with `PITBOX_TIMEOUT_MS`). The plugin's `workflow` skill selects slot or integrator mode.

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

Plugin hosts may start the MCP server inside a plugin cache. Every repository tool therefore requires `repo`, the absolute path to the target repository or worktree. At connect, the server injects the onboarding and task lifecycle instructions. For a new repository, call `init` with `repo`, review and commit `.pitbox/`, then call `setup` with the same `repo`.

### Tools reference

| Tool | Purpose |
|------|---------|
| `guide` | Workflow rules rendered from the repository policy, call once before using the others |
| `status` | Slot pool state and the active policy, call it before integrating. To start a task use `claim`, never book a slot by hand |
| `claim` | Book a free slot atomically and create your task branch in it |
| `setup` | Create the fixed slot pool, never spawn ad-hoc worktrees |
| `ready` | Mark a slot ready, records the branch HEAD in the git directory, refuses dirty or stub-branch slots, never merge yourself |
| `collect` | Integrator: merge a slot branch, or `ready` for all marked slots, refuses dirty or off-branch main checkouts, skips already collected slots |
| `ci` | Integrator: CI status of the pushed main commit, green, red or pending |
| `release` | Integrator: return a collected slot to the pool |
| `init` | Write `.pitbox/` templates without editing `AGENTS.md` |

## Plugins for Claude Code, Codex, and MiniMax Code

The plugin bundles the MCP server and one `workflow` skill with slot and integrator modes. Agents can select the skill when working in a Pitbox slot or when asked to collect ready slots.

Claude Code:

```
/plugin marketplace add WarLikeLaux/pitbox
/plugin install pitbox@pitbox
```

Codex (0.157+):

```
codex plugin marketplace add WarLikeLaux/pitbox
codex plugin add pitbox@pitbox
```

MiniMax Code (mavis / mcode, 0.5+):

```bash
# Local plugin marketplace is `directory ~/.minimax/plugins`.
# Symlink or copy the plugin directory there, then refresh.
ln -sfn "$(pwd)/plugin" "$HOME/.minimax/plugins/pitbox"
mcode plugin marketplace upgrade
mcode plugin list    # shows `[*] pitbox@local enabled`
```

The plugin's `mcp.json` uses the spec `${PLUGIN_ROOT}` variable, so the plugin wires its own MCP server in every supported host. On older Codex builds without plugin support, register the server manually as shown above and copy `plugin/skills/workflow` into your skills directory.

### Updating installed copies

When `plugin/` changes, increase the version in `plugin/plugin.json`, `plugin/.claude-plugin/plugin.json`, and `.claude-plugin/marketplace.json` together. Claude keeps the cached copy when the version stays the same. Run `bash scripts/smoke.sh`, commit, and push `main`. Then update this machine:

```bash
bash scripts/update-installed.sh
```

The update script requires a clean checkout at the published `origin/main` commit. It refreshes the Codex, Claude, and MiniMax Code marketplaces, updates all installed plugins and `~/.local/bin/pitbox`, then compares the plugin caches with this checkout. Set `PITBOX_CLI_TARGET` to override the CLI install path or `PITBOX_MAVIS_TARGET` to override the MiniMax Code plugin directory. Pass `--only=claude|codex|mavis|cli` to update a single target. Start new Codex, Claude, and mavis sessions to load the updated plugin.

## Repository configuration

pitbox is global, repository specifics live in `.pitbox/` committed next to the code.

- `.pitbox/config`: shell variables. `MAIN_BRANCH=<branch>` overrides autodetection (order: config, `origin/HEAD`, current branch). `SLOTS=<N>` sets the pool size a bare `setup` creates (default 3), `status` warns when the registered pool differs. `READY_MODE=auto|confirm` controls when workers mark ready. `EVIDENCE=auto|screenshot|requests|none` controls how they show results. `REQUIRE_PUSH=1` requires a pushed task branch before ready. `INTEGRATE_CHECKS=auto|full|ci` runs full local checks after a manually resolved merge by default, after every merge with `full`, or in CI with `ci`. Repository instructions decide whether to deploy.
- `.pitbox/setup.sh`: called with the slot directory as `$1` after a worktree is added and on release. The `bun` template runs `bun install --frozen-lockfile`, the `php-docker` template runs `composer install`.
- `.pitbox/release.sh`: optional extra cleanup on release, falls back to `setup.sh`.

Slot state lives in the common git directory so it is shared by every worktree and invisible to `git status`: `pitbox/slots/<name>.path` registers each slot, `pitbox/slots/<name>.ready` is the readiness marker, `pitbox/slots/<name>.collected` appears after a successful merge and makes a repeated `collect` skip the slot until release.

For a repository created with an older pitbox version, rename `.slots/` to `.pitbox/` before using the new CLI. The old directory is no longer read. A pre-0.4 `TASK_READY.md` marker in a slot is imported into the new state automatically on the first command.

`pitbox init` writes these templates and detects the stack from `composer.json` and `bun.lock` or `package.json`. Stack templates are the natural place for contributors to add new stacks.

For php + docker projects, parallel slots need per-slot compose isolation: a distinct `COMPOSE_PROJECT_NAME` per slot, unique host ports, and no fixed `container_name` in compose files. The template prints a reminder.

## Notes

- Slots live as sibling directories: `../your-repo-wt1` and so on, same parent as the checkout.
- Merges are `--no-ff` on purpose, task batches stay visible in history.
- Nothing here conflicts with native worktree features of specific agents. Claude Code sessions can use their built-in worktree isolation, pitbox is the shared pool and the collection procedure for everyone else.
- No npm package yet, install from the clone. Star the repo if you want one.

## License

[MIT](LICENSE)
