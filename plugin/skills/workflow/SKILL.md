---
name: workflow
description: "Use Pitbox to manage reusable Git worktree slots and handoff markers when repository instructions or the user call for it."
---

# Pitbox workflow

Pitbox manages worktrees and handoff markers. Follow the repository's instructions for task routing, checks, review, CI, push, and deployment. Use the Pitbox MCP tools when available and pass the absolute repository or worktree path as `repo`. The CLI provides the same operations.

Run `status` to inspect the pool. `setup` creates slots when needed. `claim` without a slot number picks a free worktree and prints its path. `ready` records a clean branch and its exact HEAD; it does not run tests. `unready` removes that marker while the branch is edited. `collect ready` merges all marked slots into main, while `collect <slot>` can merge a named slot without a marker and warns when doing so. `release` resets a slot for reuse. Use these operations when the repository's instructions and the user's request call for them.
