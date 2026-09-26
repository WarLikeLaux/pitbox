---
name: workflow
description: "Run Pitbox slot work or integrate ready slots. Use when working in a Pitbox slot, starting a parallel task with Pitbox, continuing a slot conversation after ready, or when the user explicitly asks to collect ready slots. Ordinary single-task work in the main checkout follows the repository's normal workflow."
---

# Pitbox workflow

Pitbox has two modes. Use the Pitbox MCP tools when available, passing the absolute repository or worktree path as `repo`. The CLI provides the same commands. Read `pitbox guide` if the pool is unfamiliar. Pitbox never edits `AGENTS.md`. Read it for project checks and deployment commands.

## Slot mode

Use this mode for a task in a Pitbox worktree. The main checkout belongs to the integrator while parallel tasks run. Start a new task with `pitbox status`, then `pitbox claim` without a slot number. Claim atomically chooses a free slot and reports its path. Work in that path. Do not ask the user to pick a slot. If there are no slots yet, run `pitbox setup`. If all existing slots are busy, report that rather than creating more slots without a request.

Run relevant checks, commit only this task's files, and call `pitbox ready <slot>`. A ready marker records the exact commit for handoff. It never starts collection or deployment. For visual work, capture a screenshot from the local preview and display the image in the result. A localhost link is not a screenshot. Do not wait for visual acceptance before committing and marking ready.

The user's selection of Pitbox slot work places repository deploy-before-commit and visual acceptance steps at integration. The slot agent does not deploy, collect, or push the main branch. Push the task branch only if `.pitbox/config` sets `REQUIRE_PUSH=1`.

The user may continue in the same conversation. Feedback on the same ready task before collection stays in that slot: make the fix, check it, commit, and call `pitbox ready` again. A separate new task needs a separate free slot. After collection and release, inspect status and claim a free slot for the next task, even if the conversation is unchanged. Do not reuse the old task branch.

## Integrator mode

Enter this mode only when the user explicitly asks to collect or integrate. A ready marker alone is not permission to start. Run `pitbox status`, state which ready slots you will collect, and collect those slots. The user's request to collect ready slots is sufficient authorization. Do not ask for another confirmation or require visual acceptance. Honor any slots the user explicitly includes or excludes.

If collection refuses a dirty or off-branch main checkout, or a slot changed after its ready marker, report the reason and do not force. After successful collection, run the repository's full checks, deploy once using its documented command, verify affected services, push the main branch, then release each collected slot. Schedule service restarts for a safe moment when other sessions are active. Report what landed and what remains in slots.

Do not commit unrelated main-checkout changes while integrating. Ordinary single-task work directly in the main checkout uses the repository's normal delivery policy.
