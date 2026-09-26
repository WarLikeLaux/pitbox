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
- A per-repository delivery policy. `pitbox guide` renders the workflow rules from `.pitbox/config`: when agents mark ready, what proof of work they show, whether branches must be pushed. In slot mode this policy overrides the repository's AGENTS.md delivery rules, so agents stop freezing on a foreign "deploy before commit" line.
- A strict split of roles. Slot agents never merge and never deploy, and the conversation that did slot work never integrates either: it ends at ready, and a fresh conversation does the collecting, deploying, pushing, and releasing. The integrator's local checks are policy: by default only after a merge with manually resolved conflicts, otherwise always, or never with CI as the gate.

## How it works

```
your-repo/            your-repo-wt1/       your-repo-wt2/       your-repo-wt3/
main checkout         slot wt1             slot wt2             slot wt3
integrator only       agent + task branch  agent + task branch  spare
```

- One task: work directly in the main checkout, no slots involved.
- Two or three parallel tasks: one slot each, the main checkout belongs to the integrator.
- A slot agent books a slot with `pitbox claim` (it atomically reserves a free slot and creates the task branch), verifies inside the slot, commits the task files, then marks the branch ready.
- The integrator collects ready slots, deploys, pushes, and releases the slots back to the pool. By default the full checks run only when a merge needed manual conflict resolution, `INTEGRATE_CHECKS=full|ci` changes that.

In slot mode, pitbox defers a repository's deploy-before-commit rule to the integrator. By default (`READY_MODE=auto`) slot agents verify, commit, and mark work ready without waiting for review or approval. Repositories that want a confirmation step set `READY_MODE=confirm`. What agents show as proof of work is policy too (`EVIDENCE`): a screenshot from a local preview for UI work, a request and response example for backend work, plain text for logic. Ready does not merge or deploy anything. The user reviews the result and explicitly asks a fresh conversation to collect when satisfied, the worker does not collect its own work. The integrator collects ready slots on that one request and deploys once. Local checks on the merged main are policy too: by default they run only when a merge needed manual conflict resolution. Feedback after review is follow-up work. Direct work in the main checkout keeps the repository's normal delivery order. `pitbox guide` prints these rules rendered for the repository, from its own config, without touching `AGENTS.md`.

You can keep using the same agent conversation. Feedback on a ready task before collection stays in its slot: the agent commits the fix and marks it ready again. After collection and release, give the agent a new task. It checks status and claims a free slot without asking you for a slot number. A separate new task before collection needs another free slot.

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
| `pitbox collect <slot\|ready>` | Merge the slot's task branch into the main branch with `--no-ff`, refuses a dirty or off-branch main checkout and slots changed after the marker, collected slots are skipped until released |
| `pitbox release <slot>` | Reset the slot to main, delete the merged branch, run release hooks |
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

The update script requires a clean checkout at the published `origin/main` commit. It refreshes the Codex, Claude, and MiniMax Code marketplaces, updates all installed plugins and `~/.local/bin/pitbox`, runs `mcode update` to refresh the MiniMax Code CLI itself, then compares the plugin caches with this checkout. Set `PITBOX_CLI_TARGET` to override the CLI install path or `PITBOX_MAVIS_TARGET` to override the MiniMax Code plugin directory. Pass `--only=claude|codex|mavis|mavis-cli|cli` to update a single target. Start new Codex, Claude, and mavis sessions to load the updated plugin.

## Repository configuration

pitbox is global, repository specifics live in `.pitbox/` committed next to the code.

- `.pitbox/config`: shell variables. `MAIN_BRANCH=<branch>` overrides autodetection (order: config, `origin/HEAD`, current branch). `READY_MODE=auto|confirm` sets when slot agents mark ready: `auto` (default) commits and marks ready right after checks, `confirm` commits always but waits for the user's confirmation. `EVIDENCE=auto|screenshot|requests|none` sets what agents show as proof of work: `auto` (default) picks per task type. `REQUIRE_PUSH=1` makes `pitbox ready` demand a pushed branch, off by default. `INTEGRATE_CHECKS=auto|full|ci` sets when the integrator runs the repository's full checks: `auto` (default) only after a merge with manually resolved conflicts, since a clean merge adds no untested code and the slot agents verified their branches, clean merges push and release the slots right away and deploy when CI is green if it exists, `full` always before deploy, `ci` never locally, push and let CI be the gate, deploy on green.
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
