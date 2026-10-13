# superpowers-strigov-ver

Personal Claude Code plugin assembled from:
Current repo/plugin version: `0.7.0`.

- **`dev-orchestrator`** — multi-model subagent-driven workflow with a pinned model + effort per role (Opus xhigh plan + Opus high revisions + GPT-6 Astra xhigh plan-review loop + GPT-6 Luna max implement with GPT-6.1 Sol xhigh escalation + Sonnet medium verification gate + per-phase fused review: Opus high spec+quality (xhigh on SECURITY/DATA_LOSS phases and in round 4) and Astra high control, both fed a pre-baked review package via `bin/review-package`; file-based implementer reports; Opus high BLOCKED diagnosis; final whole-branch Opus xhigh review before archival, cap=2, Astra xhigh fallback; review synthesis; plan-marked parallel groups run as 2 concurrent tracks in git worktrees; auto-commit, fused loop cap=4 with anti-pingpong / no-progress guards; thread-addressed Codex resume via `--resume-task`; `ultra` effort strictly user-initiated).
- **`codex-invocation`** — reference recipe for calling Codex via the `bin/codex-dispatch` wrapper around the vendored `codex-companion.mjs` (background mode + Monitor polling; bypasses the silent auto-reject on standard Agent/`codex exec` paths and pins the default model to `gpt-6.1-sol` to block backend auto-downgrade to spark; per-role GPT-6 routing table included).
- **`architecture-memory`** — maintain `docs/ARCHI.md`, a persistent tool-agnostic architecture memory with token budget, update discipline, and compaction script. Adapted from TRIP-workflow.
- 12 upstream skills copied from `superpowers` (Jesse Vincent / obra), namespace-stripped: `brainstorming`, `dispatching-parallel-agents`, `executing-plans`, `finishing-a-development-branch`, `receiving-code-review`, `requesting-code-review`, `systematic-debugging`, `test-driven-development`, `using-git-worktrees`, `verification-before-completion`, `writing-plans`, `writing-skills`. `brainstorming` extended to delegate spec/ADR writing to Opus xhigh (revisions Opus high) and spec review to Codex Astra xhigh; `writing-plans` delegates plan writing to Opus xhigh and plan review to Codex Astra xhigh (loop cap=4) — the same writer/reviewer pair as dev-orchestrator Steps 1–2.
- `/dev` slash command — explicit entry point for `dev-orchestrator`.

**Code review** is dispatched as an Opus subagent via `Agent(subagent_type="general-purpose", model="opus", effort="high", ...)` — see `skills/requesting-code-review/`. The standalone `code-reviewer` agent type from upstream was removed; use the skill instead.

**Not included:** upstream `subagent-driven-development` (replaced by `dev-orchestrator`), `using-superpowers` (aggressive MUST-directive was not wanted), the SessionStart hook that injected `using-superpowers`.

## Install on another machine

Copy this directory to the target machine, then:

```
/plugin marketplace add ~/superpowers-strigov-ver
/plugin install superpowers-strigov-ver
/reload-plugins
```

(Adjust the path if you put it elsewhere.)

## Machine-specific assumptions

The Codex companion runtime is **vendored** under `vendor/codex-companion/` (Apache-2.0, copyright OpenAI; sourced from `github.com/openai/codex-plugin-cc`). All dispatch goes through the `bin/codex-dispatch` wrapper, which (1) resolves the script from either the marketplace install path or the local dev tree, (2) pins state to `~/.claude/plugins/data/superpowers-strigov-ver-codex`, and (3) auto-injects `--model gpt-6.1-sol` (overridable via `CODEX_DEFAULT_MODEL=...` or an explicit `--model` flag) for `task`/`review`/`adversarial-review` so the backend can't auto-downgrade to spark. You do **not** need OpenAI's `codex-plugin-cc` installed.

The only external dependency is the standalone `codex` CLI (`npm install -g @openai/codex`) and a one-time `!codex login` per machine.

To bump the vendored runtime, replace the contents of `vendor/codex-companion/{scripts,prompts,schemas}` from a newer `openai/codex-plugin-cc` release and update `vendor/codex-companion/VERSION` — then re-apply the local patches listed in that file (notably the `--resume-task` flag and the `max`/`ultra` reasoning efforts).

## Upstream attribution

Original `superpowers` plugin: <https://github.com/obra/superpowers> — MIT-licensed. This personal fork copies and adapts skills from upstream 5.0.7; cross-references have been stripped of the `superpowers:` namespace and pointers to `subagent-driven-development` have been rewritten to `dev-orchestrator`. Selected Superpowers 6 (v6.1.1) mechanisms were ported in 2026-07 after source verification: `sdd-workspace`/`review-package` scripts (plan-scoped, with an uncommitted-worktree mode), file-based implementer reports, merged spec+quality reviewer pass with a `CANNOT_VERIFY` channel, reviewer read-only/anti-coaching/plan-mandated rules, Global Constraints + Interfaces plan blocks, pre-flight plan scan, durable-progress resume rules, and a final whole-branch review step.

Thread-addressed Codex resume, the verification gate, review synthesis, the ad-hoc consultation template (now in `codex-invocation`), and `architecture-memory` are adapted from [TRIP-workflow](https://github.com/PiLastDigit/TRIP-workflow) (PiLastDigit, MIT).
