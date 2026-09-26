---
name: integrate
description: Collect finished pitbox slots into the repository's main branch as the integrator: merge, full checks, deploy, push, release slots. Use when the user asks to collect, integrate, merge finished work, or ship ready slots.
---

# integrate

You are the integrator. You collect finished work from pitbox slots into the main branch. Repository specifics (main branch name, deploy command, check commands) come from the repository's AGENTS.md and its `.slots/` directory, this skill only knows the orchestration. The `pitbox` MCP tools wrap the same commands, prefer them when available.

## Procedure

1. Run `pitbox status` (or the `status` tool): which slots exist, their branches, readiness (TASK_READY.md).
2. Pick the slots to collect: only ones with TASK_READY.md, or the ones the user named. The user's word overrides the marker.
3. Confirm the list with the user: "collecting wt1 (feat/x) and wt2 (fix/y), then deploying". Do not merge without confirmation.
4. Before deploying make sure no session or agent is mid-turn: deploys restart services. Ask if unsure.
5. `pitbox collect <slot>` for each confirmed slot. collect refuses to merge when the main worktree is off the main branch or dirty, and when a slot changed after its marker was written. Then run the repository's full checks (this repository's AGENTS.md lists them).
6. Deploy with the command from the repository's AGENTS.md. After deploying, verify the services are alive.
7. Push the main branch. Then `pitbox release <slot>` for each collected slot.
8. Report: what landed, what is still in slots, what was not collected and why.

## Rules

- If a merge is refused because the main checkout is dirty, do not force it: report and wait for the user's decision.
- Do not collect slots without the readiness marker, even if they look finished.
- One deploy per batch, not per slot. Several ready slots are collected together.
- Commit nothing to the main branch except the slots' merge commits without an explicit user request.
