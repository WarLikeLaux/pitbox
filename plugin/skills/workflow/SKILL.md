---
name: workflow
description: "Use Pitbox for a task routed to a slot, continued slot work, or an explicit request to collect ready slots."
---

# Pitbox workflow

Pitbox manages worktrees and handoff markers. Follow repository instructions for task routing, checks, review, CI, push, and deployment. Use the Pitbox MCP tools when available and pass the absolute repository or worktree path as `repo`. The CLI provides the same operations.

## Worker

Run `status`, then `claim` without a slot number. Continue in the returned worktree. If no slots exist, run `setup`. If all slots are busy, report that. Run the repository's relevant checks, commit only task files, and call `ready`. A ready marker records the branch HEAD. It does not certify tests or grant permission to integrate. For feedback before collection, call `unready`, make the fix, and call `ready` again. A session that worked in a slot remains its worker and never deploys, collects, releases, or pushes the main branch.

## Integrator

Integrate only on the user's explicit request in a session that did no slot work. Run `status`, then `collect` for the requested slots or `collect ready` for all marked slots. A ready marker alone is not permission to start. Respect refusals for a dirty main checkout or changed slot HEAD. If a merge stops with conflicts, resolve them in main, complete the Git merge, then rerun `collect`. Follow the repository's checks, CI, push, and deployment rules. Call `release` after those required steps. The request to collect already authorizes collection.
