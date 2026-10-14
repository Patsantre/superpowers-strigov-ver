<p align="center">
  <img src="./assets/readme/hero-en.svg" width="100%" alt="superpowers-strigov-ver — a multi-model delivery control plane for Claude Code">
</p>

<p align="center">
  <a href="./README.ru.md"><strong>Читать на русском</strong></a>
  ·
  <a href="#quick-start">Quick start</a>
  ·
  <a href="#delivery-protocol">Protocol</a>
  ·
  <a href="#model-roles">Models</a>
  ·
  <a href="#inside-the-plugin">Contents</a>
</p>

<p align="center">
  <img alt="Version 0.9.0" src="https://img.shields.io/badge/version-0.9.0-7c8cff?style=flat-square">
  <img alt="Claude Code plugin" src="https://img.shields.io/badge/Claude_Code-plugin-d97757?style=flat-square">
  <img alt="MIT License" src="https://img.shields.io/badge/license-MIT-35d6a6?style=flat-square">
</p>

`superpowers-strigov-ver` turns Claude Code into a structured software-delivery system. One model orchestrates, specialized models plan and implement, independent reviewers challenge the result, and every important handoff leaves a durable artifact.

> **The outcome:** long implementation tasks can survive context compaction, review loops stay bounded, and code does not reach “done” until phase-level and whole-branch gates are clean.

## Quick start

### 1. Install the prerequisites

You need a recent **Claude Code**, the standalone **Codex CLI**, and a one-time Codex login:

```bash
npm install -g @openai/codex
codex login
```

Optional — the default implementer, **GLM-5.3-Flash via Z.ai's ZCode**: install [ZCode.app](https://github.com/zai-org/ZCode) into `/Applications`, then log its CLI in once with your GLM Coding Plan account via `zcode-dispatch login` — it runs ZCode's own `zcode login zai` in the wrapper's separate CLI home, so the ZCode desktop app's login stays untouched; repeat it when the CLI login expires (details in the `zcode-invocation` skill, "One-time setup"). Without it, `zcode-dispatch doctor` fails and the pipeline implements on Codex Luna `max` instead — announced, never silent. Behind a local proxy, prefix the login with `ZCODE_HTTP_PROXY=http://<host>:<port>` (the CLI ignores `HTTP(S)_PROXY` and the macOS system proxy; the wrapper passes this variable via the allowlist to headless runs too). The CLI receives an allowlisted environment; explicitly pass extra names with `ZCODE_ENV_PASSTHROUGH="NAME1,NAME2"`.

### 2. Install the plugin

Run in Claude Code:

```text
/plugin marketplace add strigov/strigov-cc-plugins
/plugin install superpowers-strigov-ver@strigov-cc-plugins
/reload-plugins
```

The companion runtime is already vendored. OpenAI's separate `codex-plugin-cc` Claude Code plugin is **not** required.

### 3. Ship a real task

```text
/dev Implement resumable uploads with integrity checks
```

The pipeline never starts on its own. Start it with `/dev`, or with `/superpowers-strigov-ver:brainstorming` to settle the design first. To pick an in-progress plan back up in a new session, type `/dev` with no task or just ask to continue: a quiet SessionStart hook names the plan. Inside the pipeline, `dev-orchestrator` triages the task, and trivial single-file edits take a lightweight Sonnet quickfix path.

## What changes

| Default agent workflow | This plugin |
|---|---|
| One model plans, writes, and grades its own work | Different model families write and review each artifact |
| Progress lives mainly in chat context | Plans, ledgers, reports, diffs, and task IDs make progress resumable |
| Review can expand scope or loop indefinitely | Authorization rules, churn detection, and hard round caps bound every loop |
| A green phase can still hide integration failures | A final whole-branch review checks contracts and runs the full suite |

## Delivery protocol

<p align="center">
  <img src="./assets/readme/workflow-en.svg" width="100%" alt="Six-stage delivery protocol from plan to whole-branch merge gate">
</p>

1. **Plan** — an Opus `xhigh` subagent explores the repository and writes a durable implementation plan with scope, interfaces, global constraints, tests, and risks.
2. **Challenge** — a fresh Codex Astra `xhigh` review finds material gaps; authorized corrections go back to a fresh Opus `high` reviser through the ledger.
3. **Build** — GLM-5.3-Flash `max` implements one phase through Z.ai's own ZCode CLI and writes a report. Codex Luna `max` takes over when the GLM channel is down or switched off; Sol 6.1 `xhigh` implements SECURITY/DATA_LOSS phases from the start and takes over when an Opus diagnosis, a stalled gate or a third blocked review round calls for deeper reasoning.
4. **Verify** — a Sonnet `medium` gate runs lint, typecheck, and affected tests before expensive review begins.
5. **Review twice** — Opus `high` checks spec compliance and quality (`xhigh` on SECURITY/DATA_LOSS phases and in the last round), then a fresh Codex Astra `high` control review probes edge cases, races, security, and regressions.
6. **Gate the branch** — after all phases pass, a fresh Opus `xhigh` review checks the complete branch and full test suite (Astra `xhigh` if Opus is unavailable). One consolidated fix wave is allowed before the final verdict.

Every implementer continuation is addressed by id with `--resume-task` — `task-…` for Codex threads, `zt-…` for ZCode sessions. Reviewers receive a generated package containing the commit list, stat, and contextual diff instead of reconstructing the change from chat history.

## Model roles

Every role runs on a pinned model + effort pair. Claude subagents receive an explicit `effort` on the Agent call (no `ultrathink`); Codex tasks receive explicit `--model` + `--effort`.

| Role | Model · effort |
|---|---|
| Orchestrator (main thread) | Claude Sonnet · `medium` |
| Plan writer / spec writer | Claude Opus · `xhigh` |
| Plan and spec reviser | Claude Opus · `high` |
| Plan and spec reviewer | GPT-6 Astra · `xhigh` |
| Implementer, fix rounds, final fix wave | GLM-5.3-Flash · `max` via Z.ai's ZCode CLI |
| Availability fallback (GLM down or switched off) | GPT-6 Luna · `max` |
| SECURITY/DATA_LOSS phases, reasoning escalation | GPT-6.1 Sol · `xhigh` |
| Frontend implementer | Claude Opus · `high` (new UI) / Claude Sonnet · `medium` (tweaks) |
| Primary code review (4.1) | Claude Opus · `high`; `xhigh` on SECURITY/DATA_LOSS phases and in round 4 |
| Control review (4.2) | GPT-6 Astra · `high` |
| Final whole-branch review | Claude Opus · `xhigh`; GPT-6 Astra · `xhigh` if Opus is unavailable |
| BLOCKED and gate-stall diagnosis, impasse summaries | Claude Opus · `high` |
| Verification gate, synthesis, quickfix, integration check | Claude Sonnet · `medium` |

`max` is reserved for the implementers GLM and Luna (or used when the user asks for it by name); `ultra` is never chosen automatically — only when the user explicitly asks for it. GLM quota: on 2026-10-14 the 1.5× ZCode quota bonus measured inconclusive (expected/measured credits = 3.02 at the standard rate, or 1.51 if the window was off-peak; details in docs/zcode-cli-findings.md).

## Guardrails

- **Manual start** — pipeline skills carry `disable-model-invocation: true`: the model neither sees nor loads them on its own. They run only after you start them, chain into each other by reading `SKILL.md` files, and resume an in-progress plan only when you ask to continue. The discipline skills (`systematic-debugging`, `test-driven-development`, `verification-before-completion`, `receiving-code-review`) still trigger automatically.
- **Independent judgment** — the writer and reviewer of an artifact come from different model families.
- **Authorization ledger** — review feedback is triaged before a fixer receives it; scope expansion is never silently implemented.
- **Bounded loops** — plan and phase reviews cap at four rounds; final whole-branch review caps at two.
- **No review ping-pong** — rejected findings cannot return unchanged, identical blocker lists escalate, and late low-materiality churn cannot keep a converged loop alive.
- **Human authority** — plan conflicts, material scope changes, and unresolved impasses return to the user.
- **Safe Git** — no `--no-verify`, no amend, no force push, and no push without explicit approval in the current session.
- **Isolated parallelism** — plan-marked independent phases may run in separate worktrees, with a hard concurrency width of two.
- **Terms-respecting GLM access** — GLM is reached only through Z.ai's own ZCode CLI with truthful client identification; no raw API, no token extraction; GLM never receives SECURITY / DATA_LOSS phases and runs unsandboxed only inside a git tree under the preamble's restrictions.

## Inside the plugin

### Fork-specific capabilities

| Component | Purpose |
|---|---|
| `dev-orchestrator` | Complete planning, implementation, verification, review, commit, and resume protocol |
| `codex-invocation` | Reliable background Codex dispatch through the vendored companion runtime |
| `zcode-invocation` | Background GLM-5.3-Flash dispatch through Z.ai's ZCode CLI: setup, doctor/probe, Monitor loop, failure handling |
| `architecture-memory` | Compact persistent architecture map in `docs/ARCHI.md` |
| `/dev` | Explicit entry point for the full delivery protocol; with no task, resumes an in-progress plan |
| `bin/pipeline-context` | SessionStart hook: names an in-progress plan and the skill to re-read after compaction, otherwise silent |
| `bin/review-package` | Generates reviewer-ready commit and diff packages |
| `bin/sdd-workspace` | Resolves isolated per-plan scratch workspaces |
| `bin/zcode-dispatch` | ZCode CLI job wrapper: task/status/result/cancel/release-stale/doctor/login with pinned model, mode and client identification; `release-stale` frees a workspace reservation left by a crashed job, after verifying it is dead |

### Adapted Superpowers skills

`brainstorming`, `dispatching-parallel-agents`, `executing-plans`, `finishing-a-development-branch`, `receiving-code-review`, `requesting-code-review`, `systematic-debugging`, `test-driven-development`, `using-git-worktrees`, `verification-before-completion`, `writing-plans`, and `writing-skills`.

The upstream `subagent-driven-development` skill is replaced by `dev-orchestrator`. The aggressive `using-superpowers` injection and its SessionStart hook are intentionally not included; the plugin's own SessionStart hook speaks only when a plan is in progress or a pipeline skill needs re-reading after compaction.

<details>
<summary><strong>Repository map</strong></summary>

```text
.
├── .claude-plugin/plugin.json       # Plugin manifest and source version
├── commands/dev.md                  # /dev command entry point
├── hooks/hooks.json                 # SessionStart → bin/pipeline-context
├── bin/
│   ├── codex-dispatch               # Vendored companion wrapper
│   ├── pipeline-context             # In-progress plan / re-read hint for the session
│   ├── review-package               # Reviewer-ready diff package generator
│   ├── sdd-workspace                # Per-plan scratch workspace resolver
│   ├── zcode-dispatch               # ZCode CLI job wrapper (shim)
│   └── lib/zcode-dispatch.mjs       # ZCode job runner, records, doctor
├── skills/
│   ├── dev-orchestrator/            # Protocol and role prompt templates
│   ├── codex-invocation/
│   ├── zcode-invocation/
│   ├── architecture-memory/
│   └── ...                          # Adapted Superpowers skills
├── tests/test-sdd-scripts.sh        # Workspace/package integration tests
├── tests/test-pipeline-context.sh   # SessionStart hook + manual-only skill checks
├── tests/test-zcode-dispatch.sh     # ZCode wrapper tests (stubbed CLI)
└── vendor/codex-companion/          # Vendored OpenAI companion runtime
```

</details>

<details>
<summary><strong>Vendored Codex companion</strong></summary>

All Codex calls go through `bin/codex-dispatch`. The wrapper works from a marketplace installation or local checkout and isolates state under `~/.claude/plugins/data/superpowers-strigov-ver-codex`.

The upstream base is recorded in `vendor/codex-companion/VERSION`. Local patches add thread-addressed resume, GPT-6 `max`/`ultra` reasoning efforts, broker cleanup, and optional review-authorization fields.

</details>

## Development and releases

Run the test suites:

```bash
bash tests/test-sdd-scripts.sh
bash tests/test-pipeline-context.sh
bash tests/test-zcode-dispatch.sh
```

For a release, synchronize the version in `.claude-plugin/plugin.json`, both README files, `PLUGIN_README.md`, and the plugin entry in the external [`strigov-cc-plugins` marketplace catalog](https://github.com/strigov/strigov-cc-plugins). Updating this repository alone does not publish a marketplace release.

## Provenance

- [Superpowers](https://github.com/obra/superpowers) by Jesse Vincent / obra — MIT. This fork includes adapted v5.0.7 skills and selected source-verified mechanisms from Superpowers 6 v6.1.1.
- [TRIP-workflow](https://github.com/PiLastDigit/TRIP-workflow) by PiLastDigit — MIT. Thread-addressed resume, verification gates, review synthesis, the ad-hoc consultation template, and architecture-memory concepts were adapted from this project.
- The vendored Codex companion originates from OpenAI's `codex-plugin-cc` and retains its Apache-2.0 license.

## License

Original work in this repository is released under the [MIT License](./LICENSE). Vendored components retain their respective licenses.
