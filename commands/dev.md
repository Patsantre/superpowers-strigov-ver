---
description: Start the dev-orchestrator multi-model workflow on the task in arguments or the preceding user request — or, with no task, resume an in-progress plan.
disable-model-invocation: true
---

`Read` `${CLAUDE_PLUGIN_ROOT}/skills/dev-orchestrator/SKILL.md` and follow it. `dev-orchestrator` is manual-only: load it with the Read tool, never through the Skill tool (which refuses it). If the path above still shows `${CLAUDE_PLUGIN_ROOT}` unexpanded, resolve it with `ls -1d ~/.claude/plugins/cache/strigov-cc-plugins/superpowers-strigov-ver/*/skills/dev-orchestrator/SKILL.md | sort -rV | head -1`.

Treat the user's request as an implementation task and run the full protocol (or Sonnet quickfix if it's trivially small). Auto-commit after clean review unless the user explicitly said not to commit. With no task in the arguments or the preceding request, start with the resume-check ("Before Step 1") — an in-progress plan is the likely target — and ask what to implement only if none exists.

Arguments (if any): $ARGUMENTS
