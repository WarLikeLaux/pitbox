---
name: workflow
description: "Run Pitbox slot work or integrate ready slots. Use when working in a Pitbox slot, starting a parallel task with Pitbox, continuing a slot conversation after ready, or when the user explicitly asks to collect ready slots. Ordinary single-task work in the main checkout follows the repository's normal workflow."
---

# Pitbox workflow

Use the Pitbox MCP tools when available, passing the absolute repository or worktree path as `repo`. The CLI mirrors them. The workflow rules are repository-specific: call `guide` with the repo path and follow its output. It renders the repository's delivery policy (ready mode, evidence, push requirement), its priority over AGENTS.md delivery rules, and the slot-agent and integrator duties. Pitbox never edits `AGENTS.md`.

## Slot mode

Use this mode for a task in a Pitbox worktree. The main checkout belongs to the integrator while parallel tasks run. Start a new task with `status`, then `claim` without a slot number, and work in the claimed path. Do not ask the user to pick a slot. If there are no slots yet, run `setup`. If all existing slots are busy, report that rather than creating more slots without a request. Commit only this task's files and follow the slot-agent section of `guide` for proof of work and ready timing.

## Integrator mode

Enter this mode only when the user explicitly asks to collect or integrate. A ready marker alone is not permission to start. Run `status`, state which ready slots you will collect, and collect those slots. The user's request to collect ready slots is sufficient authorization. Do not ask for another confirmation. Honor any slots the user explicitly includes or excludes.

If collection refuses a dirty or off-branch main checkout, or a slot changed after its marker, report the reason and do not force. Already collected slots are skipped until released. If a merge stops with conflicts, resolve them in the main checkout, commit, and run collect again. After successful collection, follow the integrator steps of `guide`, then release each collected slot once the branch is pushed. The checks and deploy timing are policy (`INTEGRATE_CHECKS`): by default (`auto`) run the full checks only when collect reports a slot merged with manually resolved conflicts, `full` always runs them before deploy, `ci` delegates to CI on the pushed main. The pool never waits for CI. Report what landed and what remains in slots.

Do not commit unrelated main-checkout changes while integrating. Ordinary single-task work directly in the main checkout uses the repository's normal delivery policy.
