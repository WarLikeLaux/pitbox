---
name: workflow
description: "Run Pitbox slot work or integrate ready slots. Use when repository instructions route a task to a Pitbox slot, when continuing slot work after ready, or when the user explicitly asks to collect ready slots."
---

# Pitbox workflow

Use the Pitbox MCP tools when available, passing the absolute repository or worktree path as `repo`. The CLI mirrors them. Follow the repository's instructions for task routing and delivery. Call `guide` with the repo path for its slot protocol and settings. If direct-work rules in `AGENTS.md` conflict with slot work, add an explicit slot exception there. Pitbox never edits `AGENTS.md`.

## Slot mode

Use this mode for a task routed to a Pitbox worktree, even if it is the only task. The main checkout remains available for integration. Start a new task with `status`, then `claim` without a slot number, and work in the claimed path. Do not ask the user to pick a slot. If there are no slots yet, run `setup`. If all existing slots are busy, report that rather than creating more slots without a request. Commit only this task's files and follow the slot-agent section of `guide` for proof of work and ready timing. When the user gives feedback on a ready task, run `unready` first so the slot stops advertising ready, then ready again after the fix. Finish with ready. A conversation that did slot work is a worker and never the integrator: when the user asks to collect here, decline and point them to a fresh conversation.

## Integrator mode

Enter this mode only when the user explicitly asks to collect or integrate and this conversation did no slot work. The worker conversation refuses to integrate and points to a fresh one. A ready marker alone is not permission to start. Run `status`, state which ready slots you will collect, and collect those slots. The user's request to collect ready slots is sufficient authorization. Do not ask for another confirmation. Honor any slots the user explicitly includes or excludes.

If collection refuses a dirty or off-branch main checkout, or a slot changed after its marker, report the reason and do not force. Already collected slots are skipped until released. If a merge stops with conflicts, resolve them in the main checkout, commit, and run collect again. After successful collection, follow the integrator steps of `guide` and the repository's delivery rules. Deploy only if the repository requires it. Release each collected slot after the required checks and delivery. The checks policy (`INTEGRATE_CHECKS`) runs the full checks after manually resolved conflicts by default, always with `full`, or in CI with `ci`. After the push, run `pitbox ci` and watch it when GitHub CI is configured. Report what landed and what remains in slots.

Do not commit unrelated main-checkout changes while integrating. Work explicitly routed to the main checkout uses the repository's normal delivery policy.
