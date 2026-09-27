# pitbox

[![CI](https://github.com/WarLikeLaux/pitbox/actions/workflows/ci.yml/badge.svg)](https://github.com/WarLikeLaux/pitbox/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

English | [Русский](README-ru.md)

Pitbox keeps a reusable pool of Git worktrees for coding agents. It books a free slot, records when a branch is ready, merges it on request, and returns the slot to the pool. Its CLI and MCP server expose the same operations.

Pitbox handles slot state and Git operations. Each repository decides which tasks use slots, which checks to run, when to review, and whether to push or deploy. Put those decisions in the repository instructions. Pitbox does not run tests, watch CI, or deploy.

## Work cycle

```text
main checkout        slot wt1           slot wt2
integration          task branch        free
```

1. A worker calls `pitbox status`, then `pitbox claim` without a slot number. Claim atomically picks a free worktree and prints its path.
2. The worker follows the repository's rules, commits its task, and calls `pitbox ready wt1`. Ready records the branch and exact HEAD in the shared Git directory. It does not certify that tests passed.
3. When the repository's workflow calls for integration, run `pitbox collect ready` or name specific slots. Collect refuses a dirty or off-branch main checkout and a slot changed after ready.
4. Follow the repository's checks, CI, push, and deploy rules. Run `pitbox release wt1` when the slot is no longer needed. Release resets it for another task.

Feedback before collection stays in the worker's slot. Call `pitbox unready wt1` while editing, then mark it ready again. If all slots are busy, wait for a release.

Pitbox does not assign agent roles. To route ordinary tasks into slots and reserve integration for a separate session, add rules like these to the repository's `AGENTS.md` or the instruction file read by that agent:

```md
- For an ordinary coding task, run `pitbox status` and `pitbox claim` without a slot number. Work in the returned worktree.
- A session that claimed a slot is its worker. Run relevant checks there, commit the task files, then run `pitbox ready`. Do not deploy, collect, release, or push the main branch.
- Integrate only on the user's explicit request in a separate session. Follow this repository's checks, CI, push, and deploy rules.
- Work explicitly assigned to the main checkout follows this repository's normal delivery rules.
```

## Setup

Requires Bash, Git 2.31+, and Node.js for MCP. Run `pitbox setup` with the standalone CLI, or the MCP `setup` tool, inside a Git repository to create three reusable slots next to its main checkout. Pass a count to create a different pool:

```bash
pitbox setup 5
pitbox status
```

No initialization or repository config is required for a repository on its main branch. For a custom branch or a persistent pool size, commit an optional `.pitbox/config` with only these entries:

```text
MAIN_BRANCH=custom
SLOTS=5
```

Pitbox reads these values as data. It does not execute the config as shell code. An existing config with `READY_MODE`, `EVIDENCE`, `REQUIRE_PUSH`, or `INTEGRATE_CHECKS` must be reduced to `MAIN_BRANCH` and `SLOTS` before using this version. Move delivery rules to the repository instructions.

Repositories can add `.pitbox/setup.sh` to prepare a new or resynced slot and `.pitbox/release.sh` to clean a released slot. Each receives the slot path as `$1`. If `release.sh` is absent, release runs `setup.sh`. Pitbox does not generate stack-specific scripts.

## Commands

| Command | Effect |
|---------|--------|
| `pitbox setup [N]` | Create and register the fixed pool |
| `pitbox status` | Show each slot's path, branch, dirty count, commits ahead, and state |
| `pitbox claim [slot\|branch-name] [branch-name]` | Atomically book a free slot and create a task branch |
| `pitbox ready <slot> [note]` | Record the clean task branch and its HEAD |
| `pitbox unready <slot>` | Remove the ready marker while continuing work |
| `pitbox collect <slot\|ready>` | Merge a slot or all marked slots into main |
| `pitbox release <slot>` | Reset a slot to main and run its release hook |

Slot state is stored under `pitbox/slots/` in the common Git directory, outside the worktrees.

## MCP and plugins

The MCP server is a stdio facade over the CLI. Every tool requires `repo`, an absolute path to the target repository or worktree, because plugin hosts can start the server from a cache directory. A hook timeout defaults to 120 seconds and can be changed with `PITBOX_TIMEOUT_MS`.

For a standalone MCP connection, use `node /path/to/pitbox/mcp/server.mjs`. The plugin bundles the server, CLI, and one short `workflow` skill. MCP tools use the bundled CLI, so installing the plugin does not require a separate CLI installation. To call `pitbox` directly from a shell, install the CLI once on that machine from this checkout with `install -D -m 755 bin/pitbox "$HOME/.local/bin/pitbox"` and put `$HOME/.local/bin` on `PATH`.

Claude Code:

```text
/plugin marketplace add WarLikeLaux/pitbox
/plugin install pitbox@pitbox
```

Codex:

```text
codex plugin marketplace add WarLikeLaux/pitbox
codex plugin add pitbox@pitbox
```

MiniMax Code (mavis / mcode):

```bash
ln -sfn "$(pwd)/plugin" "$HOME/.minimax/plugins/pitbox"
mcode plugin marketplace upgrade
mcode plugin list
```

To update installed copies after publishing a new `main`, run `bash scripts/update-installed.sh` from its clean checkout. The script updates Claude Code, Codex, MiniMax Code, and the standalone CLI. Pass `--only=claude|codex|mavis|cli` to select one target. Start new agent sessions to load an updated plugin.

## License

[MIT](LICENSE)
