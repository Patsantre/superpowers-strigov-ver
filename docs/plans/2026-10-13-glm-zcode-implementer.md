---
slug: glm-zcode-implementer
created: 2026-10-13
status: in-progress
phases:
  - id: Ф1
    scope: "[Executor: Claude subagent opus/high + one user step] ZCode CLI discovery spike → docs/zcode-cli-findings.md; GO/NO-GO gate"
    status: done
    commits: "7bfbd61.."
  - id: Ф2
    scope: "bin/zcode-dispatch shim + bin/lib/zcode-dispatch.mjs job wrapper, stubbed unit tests tests/test-zcode-dispatch.sh"
    status: done
    commits: "001e318.."
  - id: Ф3
    scope: "Protocol: dev-orchestrator SKILL.md + implementer-prompt.md + new zcode-invocation skill + codex-invocation + reviewer prompts"
    status: in-progress
  - id: Ф4
    scope: "Release 0.8.0: plugin.json, README.md, README.ru.md, PLUGIN_README.md, README SVG text"
    status: pending
  - id: Ф5
    scope: "[Executor: the user in a fresh plain Claude Code session] live acceptance §8.2 + 1.5x bonus measurement → findings, skill, READMEs"
    status: pending
---

# GLM-5.3-Flash via Z.ai's ZCode CLI as the default implementer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use dev-orchestrator to implement this plan phase-by-phase. Steps inside each phase use checkbox (`- [ ]`) syntax for tracking.

---

## Goal

Add a third implementer channel to the dev-orchestrator pipeline: GLM-5.3-Flash at reasoning effort `max`, driven exclusively through Z.ai's own coding-agent harness (the ZCode CLI embedded in `/Applications/ZCode.app`), and make it the default implementer for non-frontend phases. The user holds an individual GLM Coding Plan; the point is to move implementation tokens off Codex onto that plan without leaving Z.ai's supported tooling, by substitution only — Codex Luna max stays as the availability fallback, Codex Sol 6.1 xhigh as the reasoning escalation and the implementer of SECURITY / DATA_LOSS phases, and every reviewer role, cap, ledger rule and the frontend route stay as they are.

The authoritative requirement set is the approved spec `docs/superpowers/specs/2026-10-13-glm-zcode-implementer-design.md` (committed in `09c29e8`). The first phase is a go/no-go discovery spike: headless model selection in the ZCode CLI is unverified (spec §10 U1), so nothing else is built until it passes.

## Acceptance criteria

List 3–7 externally observable criteria that define "done" for the whole plan. Reviewers may block only on these criteria, stated user requirements, repo constraints, or high-materiality risks.

1. `docs/zcode-cli-findings.md` exists and resolves spec §10 U1–U8, U10 and U11 — each with the answer, how it was verified and the ZCode version it holds for — plus the `## Inputs for later phases` table (every key of Contract C7 filled) and a `VERDICT: GO | NO-GO` line; on `NO-GO` the plan stops after Ф1 and the user decides.
2. `bash tests/test-zcode-dispatch.sh` prints `PASS` with zero model calls (the CLI is the stub `tests/fixtures/zcode-stub.cjs`), covering spec §8.1 assertions 1–13; `bash tests/test-sdd-scripts.sh` still prints `PASS`.
3. `bin/zcode-dispatch` implements `task` / `status` / `result` / `cancel` / `doctor` / `doctor --probe` exactly per Contracts C1–C5 (exit codes 0/1/2, pinned argv and environment, the model pin in its own personal provider config under the state root passed as `ZCODE_PERSONAL_PROVIDER_CONFIG_FILE`, job records, per-workspace ids, guards); it never sets `ZCODE_DATA_BASE_DIR` and never reads or writes `~/.zcode`.
4. `skills/dev-orchestrator/SKILL.md`, `skills/dev-orchestrator/implementer-prompt.md`, the new `skills/zcode-invocation/SKILL.md` and `skills/codex-invocation/SKILL.md` encode spec §5–§6.3: the per-phase channel ladder, the `risk_phases` frontmatter map with its guards, the operation / body / dispatch-file / `.id`-sidecar scheme, GLM infrastructure-failure handling, the gate-stall diagnosis, the review-stall Sol escalation, the `impl=` / `glm=` state-line fields with the session marker, the kill switch, the ZCode preamble and channel-switch notice, and the six new Red Flags; frontend phases are routed exactly as before.
5. Plugin version is `0.8.0` in `.claude-plugin/plugin.json`, `README.md`, `README.ru.md`, `PLUGIN_README.md` and the hero SVG badges; the docs name GLM-5.3-Flash via ZCode as the default implementer, Luna as the fallback and Sol as the risk-phase implementer and escalation, and carry the terms-respecting-GLM-access guardrail.
6. The live acceptance (spec §8.2) is recorded in `docs/zcode-cli-findings.md`: `doctor` and `doctor --probe` pass, the E2E task ends `DONE` with nothing committed, the fix round appends `## Fix round 1`, and the 1.5× bonus result (active / not active / inconclusive, with raw numbers) also appears in `zcode-invocation` and both READMEs.

## Non-goals / deferred

List explicit exclusions. Reviewers MUST classify requests for these as `REJECTED_BY_SCOPE` or `DEFER` unless the orchestrator authorizes scope expansion.

- Approach C — a permission broker over `zcode app-server` with `--mode guarded` (a real approval boundary for GLM). Future work (spec §11).
- GLM as planner, reviewer, spec writer or diagnosis model; GLM for frontend phases; other GLM models (full GLM-5.3) or efforts other than `max`.
- Raw Z.ai API or SDK access, token extraction, any use outside the ZCode CLI — forbidden, not deferred.
- Installing the ZCode `superpowers-plugin` or any plugin into the user's ZCode; changing the user's ZCode settings (anything under `~/.zcode`, the desktop app's provider config), login or plugins programmatically. The one-time `zcode login zai` is the user's action; the wrapper's own personal provider config under its state root (C5), which carries the model pin, is wrapper state, not a ZCode setting.
- Changes to the Codex reviewer roles, the plan writer, the ledger, the loop caps, the trivial quickfix path or the frontend route.
- Automated quota accounting beyond the one-off bonus measurement; Linux / Windows support of the wrapper (macOS app bundle only).
- Any configuration surface beyond the kill switch (`SP_IMPLEMENTER=luna`, session phrases) and the five `ZCODE_*` overrides of Contract C5.
- Publishing the release to the external `strigov-cc-plugins` marketplace catalog, and reinstalling the plugin so the running orchestrator uses 0.8.0.
- Redesigning the README SVGs beyond the text swaps of Ф4; changes to `vendor/codex-companion/`.
- A lock file or other cross-process locking for job records beyond atomic rename + sticky terminal statuses claimed through an exclusively created `.terminal` sibling (see Risk R7). The single exception is the per-workspace write reservation of C1/C3 (ledger F1-B1-Ф2, F3-B1-Ф2, F4-B1-Ф2): generation-numbered, exclusively created files `active.lock.<gen>` in the workspace state dir plus their release records `active.lock.<gen>.released` are the only lock, Node built-ins only — no external locking dependency, no cross-workspace locking, no other lock. Automatic reclaim of a stale reservation is also a non-goal: a reservation whose holder is gone is released only by the explicit `release-stale` verb (C1), so after a runner crash the workspace stays blocked until it runs.

## Global Constraints

List the spec's project-wide requirements — version floors, dependency limits, naming and copy rules, platform requirements — one line each, with exact values copied verbatim from the spec or user request. If the spec imposes none, write literally `None declared in the spec.`

- "Use Z.ai's own harness (the ZCode CLI). **Never** raw API calls, never extracted credentials." (spec §1.4)
- "Keep the fork's architecture; change by substitution; port narrowly." (spec §1.4)
- "Frontend phases unchanged." (spec §1.4)
- Plugin version: `0.7.0` → **`0.8.0`** (spec header).
- Pinned model selection: `PINNED_MODEL = "GLM-5.3-Flash$max"` — one pinned level, no other model or effort (spec §4.9, D2).
- `bin/lib/zcode-dispatch.mjs` — "pure Node ESM, **no dependencies**, no shell: `child_process.spawn` with argv arrays only." (spec §4.1)
- No new external dependencies: pure bash + Node built-ins (repo constraint).
- Exit codes everywhere: "**0** success · **1** runtime failure (failed job on `result`, failed checks on `doctor`, internal error) · **2** usage error or guard refusal." (spec §4.2)
- "The wrapper never sets `ZCODE_DATA_BASE_DIR`" and "nothing under `~/.zcode` is read or written by the design" (spec §2.1).
- Overrides: "`ZCODE_APP`, `ZCODE_BIN`, `ZCODE_NODE`, `ZCODE_STATE_DIR`, `ZCODE_TASK_TIMEOUT_MIN`. Nothing else is configurable" (spec §4.10).
- State root default: `~/.claude/plugins/data/superpowers-strigov-ver-zcode` (spec §4.4).
- Job ids: `zt-NNNN`, "Four digits zero-padded (`zt-0001`), more digits beyond 9999"; "`zt-` ids and Codex `task-` ids never cross dispatchers" (spec §4.4, §4.6).
- Kill switch: "the phrase "через Luna" / "без GLM" for the session; env `SP_IMPLEMENTER=luna` permanently. Nothing more." (spec D9)
- Client identification: real `ZCODE_APP_VERSION` from `Info.plist` plus `--surface terminal` — "honest identification, no spoofing" (spec §2.5).
- Unit tests never call the real zcode or any model — the CLI is stubbed via `ZCODE_BIN` (spec §8.1).
- Live probes and the live acceptance never change ZCode settings, login or plugins on the user's behalf and never log the user out (spec §10 U4, Red Flag 6).
- `docs/` is listed in `.gitignore`: every commit that stages a file under `docs/` uses `git add -f <path>` (repo constraint).
- Skill and prompt text is English; `README.ru.md` mirrors `README.md` in Russian (repo convention).
- Platform: macOS, `/Applications/ZCode.app` 3.15.1 (CLI zcode 0.16.9), `plutil`, `node` v26.11.0 verified (spec §2.1).

## Files

**Ф1**
- Create: `docs/zcode-cli-findings.md` — verified ZCode CLI facts (U1–U8, U10, U11), `## Inputs for later phases` table, `VERDICT` line; later extended by Ф5.

**Ф2**
- Create: `bin/zcode-dispatch` — bash shim: resolves the `.mjs` (marketplace cache, then dev tree), defaults `ZCODE_STATE_DIR`, `exec node`.
- Create: `bin/lib/zcode-dispatch.mjs` — the wrapper: verbs, job records, detached runner, CLI invocation, classifier, liveness, doctor/probe.
- Create: `tests/test-zcode-dispatch.sh` — bash unit tests for spec §8.1 assertions 1–13 (style of `tests/test-sdd-scripts.sh`).
- Create: `tests/fixtures/zcode-stub.cjs` — stand-in for `zcode.cjs`, behaviour by `ZCODE_STUB_MODE`.
- Create: `tests/fixtures/FakeZCode.app/Contents/Info.plist` — fake app bundle plist (version `9.9.9`).
- Create: `tests/fixtures/FakeZCode.app/Contents/Resources/config/provider/zcode-builtin.json` — fake provider config (`{}`).

**Ф3**
- Create: `skills/zcode-invocation/SKILL.md` — how to invoke GLM through `zcode-dispatch` (mirrors `codex-invocation`).
- Modify: `skills/dev-orchestrator/SKILL.md` — channel ladder, risk phases, prompt-file scheme, failure handling, stalls, state line, Red Flags (spec §5).
- Modify: `skills/dev-orchestrator/implementer-prompt.md` — GLM invocation, prompt-file scheme, ZCode preamble, channel-switch notice (spec §6.1).
- Modify: `skills/codex-invocation/SKILL.md` — pointer to `zcode-invocation`, role rows, width cap across dispatchers (spec §6.3).
- Modify: `skills/dev-orchestrator/opus-review-prompt.md`, `skills/dev-orchestrator/final-review-prompt.md`, `skills/dev-orchestrator/codex-control-review-prompt.md` — family-neutral wording; Step 5 fixer per the new selection (spec §6.4).

**Ф4**
- Modify: `.claude-plugin/plugin.json` — version `0.8.0`, description, keywords `glm`, `zcode`.
- Modify: `README.md`, `README.ru.md` — badge, quick start, protocol step 3/6, model roles, guardrail, capabilities, repo map, test commands.
- Modify: `PLUGIN_README.md` — version line, `dev-orchestrator` bullet, `zcode-invocation` bullet, machine-specific assumptions.
- Modify: `assets/readme/hero-en.svg`, `assets/readme/hero-ru.svg`, `assets/readme/workflow-en.svg`, `assets/readme/workflow-ru.svg` — the builder is named GLM (they name Luna today), badge `v0.8.0`.

**Ф5**
- Modify: `docs/zcode-cli-findings.md` — `## Live acceptance` section.
- Modify: `skills/zcode-invocation/SKILL.md` — the quota-bonus line under "Verified facts".
- Modify: `README.md`, `README.ru.md` — one measured-quota sentence each.

## Contracts

### C1. `zcode-dispatch` command surface

```
zcode-dispatch task --background [--cwd <path>] [--resume-task zt-NNNN | --fresh] --prompt-file <file>
    stdout (exit 0): ZCode Task started in the background as zt-NNNN
zcode-dispatch status [zt-NNNN] [--cwd <path>] [--all] [--json]
    --json + id:   {"job": <C2 record>}
    --json, no id: {"workspaceRoot": "<abs root>", "running": [<C2>...], "recent": [<C2>...]}
                   recent = the 10 newest terminal jobs (by id); --all = every terminal job
    text:          one line per job: <id> <status>[/<errorClass>] <M>m<SS>s <model> <sessionId|-> [resumeOf=<id>]
zcode-dispatch result zt-NNNN [--cwd <path>]
    completed → the stored response on stdout (newline-terminated), exit 0
    otherwise → stderr "job zt-NNNN is <status> errorClass=<class>" + the last 20 log lines, exit 1
zcode-dispatch cancel zt-NNNN [--cwd <path>]
    running → "cancelled zt-NNNN"; terminal → "zt-NNNN is <status>"; exit 0
zcode-dispatch release-stale [--cwd <path>]
    released → "released <workspace> generation <n>", exit 0
    refused (already released, holder runner alive, CLI process group alive,
             generation or holder changed) → one-line reason on stderr, exit 2
    I/O or internal error → exit 1
zcode-dispatch doctor [--cwd <path>] [--probe]
    one line per check "<ok|WARN|FAIL> <check>: <detail>" for, in order:
    app, cli, provider-config, node, app-version, git, state-dir, personal-config, kill-switch
    then "doctor: ok" | "doctor: FAIL" (exit 1 on any FAIL; --probe sends no request then)
    --probe, after "doctor: ok":
      model-selected: ok | FAIL(<errorClass>)   (FAIL(model-not-selected|auth): the CLI is not logged in — the user's one-time `zcode login zai`)
      answers: ok | FAIL
      reported-model: <string> | unreported
      usage: input=<n|-> cached=<n|-> output=<n|->
      probe: ok | FAIL                       (exit 0 iff probe: ok)
exit codes: 0 success · 1 runtime failure · 2 usage error or guard refusal
```

Guards on `task` (exit 2, nothing spawned): missing `--background`; `--resume-task` with `--fresh`; `SP_IMPLEMENTER=luna`; `--cwd` not in a git work tree; missing / whitespace-only prompt file, or (argv transport) larger than `MAX_PROMPT_BYTES`; `Info.plist` unreadable; `ZCODE_BIN` or provider config missing; bad `--resume-task` (non-`zt-` id, unknown, `running`, `failed`/`cancelled`, no `sessionId`); another `running` job in the workspace, or the workspace write reservation held (holder runner alive → the guard message; holder gone → the stale message, see below); invalid `ZCODE_TASK_TIMEOUT_MIN`; unknown verbs or flags. `status` / `result` / `cancel` with an unknown or non-`zt-` id → exit 2.

Workspace write reservation (ledger F1-B1-Ф2): `task` atomically acquires one per-workspace reservation (an exclusively created file in the workspace state dir, C3, recording the holder runner pid and job id) before allocating the job id or spawning; a second concurrent `task` fails to acquire it and is refused with the guard message. The reservation is held until the CLI child has actually exited and is released by the runner on every terminal path (completed, failed, timeout, cancelled). `cancel` may still claim the sticky terminal status first (C2) but never releases the reservation, so the next `task` is refused until the cancelled CLI is gone. The reservation is generation-numbered (ledger F3-B1-Ф2): files `active.lock.<gen>` (C3; holder pid, job id, token, generation), the current reservation being the highest generation. The only transition to the next generation is acquire after a normal release: when generation n has its `.released` record, `task` takes the workspace by exclusive creation of `active.lock.<n+1>` (temp file + `link(2)`; losers get `EEXIST` and re-read the highest generation), so exactly one of several concurrent `task`s wins. `task` hands the reservation to the runner (holder = runner pid) before `task` itself exits, so the holder is never a normally exited `task` process. The holder records release in `active.lock.<gen>.released` (the token, exclusively created) without deleting the generation file; the runner finds its generation file by the token passed to it. The current reservation is never deleted, and there is no separate reclaim marker.

No automatic reclaim (ledger F4-B1-Ф2): `task` never reclaims a stale reservation. When the highest generation has no `.released` record, `task` refuses with exit 2 and changes nothing — no reservation, job record or process is touched: if the holder runner pid is alive it prints the existing guard message; if the holder is gone it prints a distinct stale message whose text contains the literal `release-stale` (the release command, with the `--cwd` it needs); no other `task` refusal contains that literal. A stale reservation is released only by the explicit single-actor verb `release-stale [--cwd <path>]`: it reads the highest generation and refuses (exit 2) if that generation is already released, if the holder runner pid is alive, or if the job's recorded CLI process group is alive; otherwise it finalizes a non-terminal job as `failed` / `crash` through the sticky-terminal path (C2), re-reads the generation after its liveness checks and refuses if the generation or the holder changed, then writes the generation's `.released` record by exclusive creation (a concurrent second `release-stale` gets `EEXIST` and reports already released) and prints `released <workspace> generation <n>` (exit 0). It never sends signals and never unlinks anything. Residual cost: after a runner crash the workspace stays blocked for GLM until `release-stale` runs.

### C2. Job record (`<jobsDir>/zt-NNNN.json`)

```json
{
  "id": "zt-0007",
  "status": "running",
  "errorClass": null,
  "sessionId": "sess_…",
  "resumeOf": "zt-0003",
  "workspaceRoot": "/abs/path",
  "promptFile": "/abs/path/implement-Ф2-r1.001.glm.md",
  "model": "GLM-5.3-Flash$max",
  "reportedModel": null,
  "appVersion": "3.15.1",
  "runnerPid": 48213,
  "childPid": 48214,
  "startedAt": "2026-10-13T12:00:00.000Z",
  "finishedAt": null,
  "exitCode": null,
  "signal": null,
  "timeoutMin": 60,
  "response": null,
  "usage": null,
  "note": null
}
```

`status` ∈ `running | completed | failed | cancelled`; `errorClass` ∈ `timeout | crash | model-not-selected | auth | quota | launch | malformed`, set only with `failed`. `note` (an addition to the spec schema) carries `runner died`, `runner never started`, `cancelled by zcode-dispatch cancel`, or a launch reason. Terminal statuses are sticky: the first terminal write claims `zt-NNNN.json.terminal` (the full terminal record, created atomically with `link(2)`, which fails if it exists) before mirroring it into `zt-NNNN.json`; every reader prefers the `.terminal` file, so a later writer holding a stale `running` copy cannot undo it. `runnerPid` and `childPid` are written by the runner itself; `task` creates the record with both `null`.

### C3. State layout

`<ZCODE_STATE_DIR>/state/<basename(root)>-<first 8 hex of sha1(root)>/jobs/zt-NNNN.{json,log}` (plus `zt-NNNN.json.terminal` once the job is terminal, C2), the generation-numbered workspace write reservation files of C1 in that same workspace state dir (`active.lock.<gen>`, the highest generation being the current reservation, and `active.lock.<gen>.released` once its holder — or, for a stale reservation, the explicit `release-stale` verb (ledger F4-B1-Ф2) — released it; the generation files and their release records are the only lock, and a stale reservation is never reclaimed automatically, so after a runner crash the workspace stays blocked until `release-stale` runs; ledger F3-B1-Ф2; old generations and release records are never cleaned up, so they accumulate per workspace at a few bytes each), and `<ZCODE_STATE_DIR>/personal-provider-config.json` (the wrapper-owned personal provider config, C5), where `root` = `git rev-parse --show-toplevel` evaluated in `--cwd` (default: process cwd). The log holds the CLI's stderr plus `[zcode-dispatch] <ISO time> …` lines (argv summary with the prompt replaced by `<prompt N bytes>`, start/finish, classification reason, raw stdout on failure).

### C4. Module exports of `bin/lib/zcode-dispatch.mjs`

Constants (values filled from `docs/zcode-cli-findings.md` in Ф2 Step 8): `PINNED_MODEL: string`, `VERIFIED_APP_VERSION: string`, `VERIFIED_NODE_MAJOR: number`, `PROMPT_TRANSPORT: "argv" | "stdin"`, `MAX_PROMPT_BYTES: number`, `APP_VERSION_PLIST_KEY: "CFBundleShortVersionString" | "CFBundleVersion"`, `MODEL_ARGS: string[]`, `MODEL_ENV: Record<string,string>`, `SELECTION_PATH: string`, `PERSONAL_CONFIG_BASE: object`, `PINNED_SELECTION: object`, `DISALLOWED_TOOLS: string[]`, `REPORTED_MODEL_PATH: string | null`, `USAGE_FIELDS: { input: string|null, cached: string|null, output: string|null }`, `PATTERNS: { "model-not-selected": string[], auth: string[], quota: string[], launch: string[] }`.

Functions: `main(argv: string[]): Promise<number>`; `readRecord(file: string): object | null` (the `.terminal` record when one was claimed, else the main record); `finalizeRecord(file: string, patch: object): object | null` (never rewrites a terminal record; of two racing finalizers exactly one claim wins and the other returns the winner's record); `buildCliArgv({ bin, prompt, workspaceRoot, sessionId }): string[]`; `pinPersonalConfig(file: string): object` (sets `SELECTION_PATH` to `PINNED_SELECTION`, keeps the rest of the file, starts from `PERSONAL_CONFIG_BASE` when the file is missing or unreadable; atomic rename); `parseCliOutput(stdout: string): object | null`; `classifyFailure({ timedOut, spawnError, stdout, stderrTail }): string`. Importing the module does not run `main` (it runs only when the file is the process entry point).

### C5. Pinned CLI invocation

```
<ZCODE_NODE> <ZCODE_BIN> -p <prompt file contents | "-" on the stdin transport> --output-format json --mode yolo --surface terminal --workflow-mode disabled --cwd <workspaceRoot> [...MODEL_ARGS] [--disallowedTools <DISALLOWED_TOOLS joined by ",">] [--resume <sess_…>]
```

Spawned with `detached: true` (own process group), cwd = workspaceRoot, stdin `ignore` (or the prompt on the stdin transport), stdout captured, stderr appended to the log. Both streams are decoded as UTF-8 by the stream itself (`setEncoding('utf8')` before the `data` handlers), so a multibyte character split across chunks stays intact (ledger F1-B2-Ф2). Environment = inherited + `MODEL_ENV` + `ZCODE_BUILTIN_PROVIDER_CONFIG_FILE` and `ZCODE_BUILTIN_PROVIDER_BUNDLED_CONFIG_FILE` (both `<ZCODE_APP>/Contents/Resources/config/provider/zcode-builtin.json`) + `ZCODE_APP_VERSION` (plist key `APP_VERSION_PLIST_KEY`, read at every `task`) + `ZCODE_PERSONAL_PROVIDER_CONFIG_FILE` = `<ZCODE_STATE_DIR>/personal-provider-config.json` (a fourth variable beyond spec §4.3: Ф1 U1 found that a headless run takes its model only from the personal provider config this variable names). The wrapper owns that file: before every CLI run (task runner, `doctor`, `doctor --probe`) `pinPersonalConfig` sets its default selection to `PINNED_SELECTION` (C4). It never lives under `~/.zcode` and holds no credentials. The CLI's login identity stays in ZCode's own credential store, written only by the user's one-time `zcode login zai`, and the wrapper never reads it. Never `--target`, `--json`, `-c/--continue`. Defaults: `ZCODE_APP=/Applications/ZCode.app`, `ZCODE_BIN=$ZCODE_APP/Contents/Resources/glm/zcode.cjs`, `ZCODE_NODE=node`, `ZCODE_STATE_DIR=~/.claude/plugins/data/superpowers-strigov-ver-zcode`, `ZCODE_TASK_TIMEOUT_MIN=60`. Timeout → SIGTERM to the group, 10 s, SIGKILL. Probe timeout 120 s.

### C6. Test stub `tests/fixtures/zcode-stub.cjs`

`ZCODE_STUB_MODE`: `ok` (JSON `{sessionId:"sess_stub_<pid>", traceId, turnId, response:"DONE\nstub finished", usage:{inputTokens:100, cacheReadTokens:40, outputTokens:7, reasoningTokens:3}, eventCount:1}`, exit 0) · `pong` (response `PONG`) · `resume` (exit 1 unless `--resume <sess>` is present; echoes that session id) · `record` (writes `{argv, stdin, cwd, env:{the two provider vars, ZCODE_APP_VERSION, ZCODE_PERSONAL_PROVIDER_CONFIG_FILE, ZCODE_DATA_BASE_DIR}, personalConfig:<that file's parsed content at run time, or null>}` to `$ZCODE_STUB_RECORD`, then as `ok`; reads stdin when `-p -`) · `model-not-selected` / `auth` / `quota` / `launch` (stderr `Error: <$ZCODE_STUB_MESSAGE or a default>`, exit 1) · `hang` (600 s) · `crash` (SIGKILLs itself) · `malformed` (`not json`, exit 0). `ZCODE_STUB_DELAY_MS` delays the action.

### C7. `docs/zcode-cli-findings.md` — `## Inputs for later phases`

A markdown table `| Key | Value | Evidence |`, one row per key, values exactly in these forms:

| Key | Allowed value | Consumed by |
|---|---|---|
| `VERDICT` | `GO` \| `NO-GO` (`NO-GO` iff `MODEL_MECHANISM` = `none`) | orchestrator after Ф1 |
| `MODEL_MECHANISM` | `personal-config` \| `flag:<--flag-name>` \| `env:<VAR_NAME>` \| `none` (`personal-config`: the wrapper owns a personal provider config, passes it as `ZCODE_PERSONAL_PROVIDER_CONFIG_FILE`, and its default selection is the pin. Requires the user's one-time `zcode login zai`; verified by Ф1 Step 6. `none`: all three spec §10 U1 candidates (persisted default, flag/env, session-bound resume) refused model selection. An untested or indeterminate candidate is not `none`: Ф1 then ends `BLOCKED` with no value) | Ф2 `MODEL_ARGS`/`MODEL_ENV` and the three rows below; Ф3 "Verified facts"; orchestrator after Ф1 |
| `SELECTION_PATH` | dot path of the default selection inside the personal provider config the login wrote, e.g. `config.defaultModelSelection` | Ф2 `SELECTION_PATH` |
| `PERSONAL_CONFIG_BASE` | one-line JSON: the file the login wrote with the key at `SELECTION_PATH` removed (Ф1 Step 6 checks it holds no credential-like value) | Ф2 `PERSONAL_CONFIG_BASE` |
| `PINNED_SELECTION` | one-line JSON: the selection object for GLM-5.3-Flash at reasoning `max` that Ф1 Step 6 wrote at `SELECTION_PATH` and verified with a headless PONG | Ф2 `PINNED_SELECTION` |
| `RESUME_KEEPS_MODEL` | `yes` \| `no` | Ф3 "Verified facts" (`GLM resume`) |
| `REPORTED_MODEL_FIELD` | `none` \| dot path in the `--output-format json` object | Ф2 `REPORTED_MODEL_PATH`; Ф3 |
| `USAGE_INPUT_FIELD` | dot path inside `usage`, or `none` | Ф2 `USAGE_FIELDS.input`; Ф5 |
| `USAGE_CACHED_FIELD` | dot path inside `usage` (prompt-cache-read count), or `none` | Ф2 `USAGE_FIELDS.cached`; Ф5 |
| `USAGE_OUTPUT_FIELD` | dot path inside `usage`, or `none` | Ф2 `USAGE_FIELDS.output`; Ф5 |
| `USAGE_REASONING_FIELD` | dot path of reasoning tokens reported **beside** (not inside) the output count, or `none` | Ф5 |
| `CACHED_IS_SUBSET_OF_INPUT` | `yes` \| `no` \| `unknown` | Ф5 |
| `PROMPT_TRANSPORT` | `argv` \| `stdin` | Ф2 |
| `MAX_PROMPT_BYTES` | integer bytes | Ф2 |
| `VERIFIED_APP_VERSION` | the value of the `APP_VERSION_PLIST_KEY` plist key, e.g. `3.15.1` (or `3.15.1.8093` with `CFBundleVersion`) | Ф2 |
| `VERIFIED_NODE_MAJOR` | integer | Ф2 |
| `APP_VERSION_PLIST_KEY` | `CFBundleShortVersionString` \| `CFBundleVersion` | Ф2 |
| `DISALLOWED_TOOLS` | `none` \| comma-separated tool names | Ф2 |
| `GLM_CONCURRENCY` | `1` \| `2` | Ф3 "Verified facts" |
| `SESSION_SAVED_ON_SIGTERM` | `yes` \| `no` \| `unknown` | record only (retry after timeout is `--fresh` either way) |
| `INTERFERING_PLUGINS` | `none` \| comma-separated plugin names | user action only |
| `PATTERN_MODEL_NOT_SELECTED` | `;`-separated case-insensitive substrings | Ф2 `PATTERNS` |
| `PATTERN_AUTH` | same form | Ф2 `PATTERNS` |
| `PATTERN_QUOTA` | same form | Ф2 `PATTERNS` |
| `PATTERN_LAUNCH` | same form | Ф2 `PATTERNS` |

The file also carries a line `VERDICT: GO` or `VERDICT: NO-GO — <reason>` under `## Go / no-go`, and sections `## U1 — …` … `## U11 — …`, each with the four bullets `- Answer:`, `- How verified:`, `- Holds for:`, `- Design consequence:`.

### C8. Protocol artifacts (dev-orchestrator, Ф3)

- Operations: `implement` · `fix r<N>` · `gatefix r<N>` · `final-fix` · `repair r<N>`.
- Body file: `$dir/prompts/<name>.md`, `<name>` ∈ `implement-<id>-r1`, `fix-<id>-r<N>`, `gatefix-<id>-r<N>`, `final-fix-r<N>`, `repair-<G>-r<N>`; `$dir = $("$WS" <plan-file>)`.
- Dispatch file: `$dir/prompts/<name>.<seq>.<glm|luna|sol>.md`; `<seq>` = three digits, per phase (per operation name for `final-fix` / `repair-<G>`), monotonic across operations, rounds and channels.
- Sidecar: `$dir/prompts/<name>.<seq>.<glm|luna|sol>.id`, one line `glm:zt-NNNN` | `luna:task-NNNN` | `sol:task-NNNN`.
- Session marker: `<scratchpad>/dev-orchestrator/glm-channel`, one line `<ok|down|off> <reason> <ISO time>`.
- State line suffix: ` impl=<glm:zt-NNNN | luna:task-NNNN | sol:task-NNNN | claude | —> glm=<unprobed | ok | down | off>`; group form `tracks=Ф2:4-r1@glm:zt-0003,Ф3:3@luna:task-0011`.
- Plan frontmatter key: `risk_phases: { Ф1: [], Ф2: [DATA_LOSS], … }` — every phase id, empty list = scanned, no risk.
- `zcode-invocation` "Verified facts" lines (exact prefixes dev-orchestrator reads): `- Model selection: wrapper`; `- Model confirmation: required` | `- Model confirmation: not required`; `- GLM resume: enabled` | `- GLM resume: disabled`; `- GLM concurrency: 1` | `- GLM concurrency: 2`; `- Quota bonus (1.5× in ZCode): …`.
- Gate-stall diagnosis tokens: `ENVIRONMENT` (line 2 `fix-location: in-repo` | `fix-location: machine`) | `CODE` | `CONTEXT`.

## Test strategy

- **Ф1 (discovery, document).** Evidence, not tests: every U-section names how it was verified (source path at tag `v3.15.1`, or the exact live command and its output). A mechanical completeness check (Ф1 Step 1 command) must print only `check-done`. Live calls are listed in Ф1 and kept to small PONG-style prompts plus one 150 KB prompt. Not tested: anything under `~/.zcode` (never read), logout behaviour (never provoked).
- **Ф2 (wrapper).** Integration-style bash tests in `tests/test-zcode-dispatch.sh` against the real wrapper with the stub CLI: spec §8.1 assertions 1–13 plus result-on-failure, sticky `finalizeRecord` (including the two cancel-vs-runner interleavings, injected in-process), the `MODEL_ARGS` / `DISALLOWED_TOOLS` wiring, and the personal provider config pin (file created under the state root before the run, selection re-pinned before every run, other content kept, `ZCODE_PERSONAL_PROVIDER_CONFIG_FILE` passed), the workspace write reservation (two concurrent `task` → exactly one starts; after `cancel` the next `task` is refused until the cancelled CLI exits; a stale reservation with a dead holder → `task` exits 2 with the stale message and leaves the files untouched; `release-stale` refuses while the holder runner is alive; `release-stale` on a dead holder finalizes a non-terminal job, writes `.released`, and the next `task` is admitted and completes; two concurrent `release-stale` → exactly one release record and one success — ledger F4-B1-Ф2, which removed automatic reclaim and its tests) and UTF-8 decoding of a multibyte character split across two stdout writes (ledger F1-B1-Ф2, F1-B2-Ф2); the tests read exported constants so Ф1's values cannot break them. RED = the suite fails at assertion 13 before the shim exists; GREEN = `PASS`. Regression: `bash tests/test-sdd-scripts.sh`. Not tested: the real ZCode CLI or any model (Ф5 covers it live), Linux, PID reuse.
- **Ф3 (prose).** A grep-based structural check (Ф3 Step 1 block) proves every required section, rule anchor and Red Flag is present and the stale Luna-as-implementer wording is gone; both test suites still pass. The ladder, stall rules, state-line fields and Red Flags are model-facing prose (spec §8.3): they are verified by the plan review, the fused code review of the skill edits, and the first real `/dev` run on GLM. Not tested: model behaviour under the new prose.
- **Ф4 (docs).** A grep / `xmllint` / JSON check (Ф4 Step 1 block): version `0.8.0` everywhere, no stale `0.7.0`, new rows and guardrail present in both languages, SVGs well-formed. Not tested: rendering on GitHub.
- **Ф5 (live acceptance).** End-to-end on the real CLI and the real plan (spec §8.2): `doctor`, `doctor --probe`, an E2E first-round task in a throwaway repo, a fix round, and the quota measurement. The orchestrator then runs the verification gate and the fused review on the resulting doc edits. Not tested: concurrency under load, other app versions.

## Risks / unknowns / assumptions

- **R1 — U1 kills the feature (GO/NO-GO).** Headless `-p` fails with `Select a model before continuing`. If no headless model selection exists by any means, Ф1 ends with `VERDICT: NO-GO`, Ф1 is committed, and the plan stops; the user decides. Ф1's first run established the following, from source and live runs:
  - The CLI has no `--model` flag and no model env variable.
  - The embedded CLI ships without its TUI (`Cannot find package '@zcode/tui'`), so `/model` is impossible. Headless `-p "/model …"` is plain prompt text.
  - A fresh run takes `defaultModelSelection` from the personal provider config named by `ZCODE_PERSONAL_PROVIDER_CONFIG_FILE`. The account provider is entitled only after the CLI's own `zcode login zai`, a user action that writes the identity into ZCode's shared credential store.

  The remaining mechanism is `MODEL_MECHANISM = personal-config`: the user logs the CLI in once, and the wrapper pins GLM-5.3-Flash/max in its own personal provider config. An invalid configured default silently falls back to the first registry model (`registry-fallback` in the bundle), so a PONG alone does not prove the pin. Ф1 Step 6 therefore checks the effective model in the run's own output. If the login fails, the pin is not applied, or the model cannot be confirmed, Ф1 ends `BLOCKED` and the user decides.
- **R2 — Discovery cannot run in the Codex sandbox.** The Codex implementer's workspace-write sandbox most likely blocks network and writes to `~/.zcode`. Ф1's executor is therefore a Claude subagent (`opus` / `high`), stated in its frontmatter scope and its body; zcode was verified to run from Claude Code's own Bash tool.
- **R3 — A user step is required.** The one-time `zcode login zai` (Z.ai's own browser OAuth) is a user action (Red Flag 6). It writes the CLI's identity into ZCode's shared credential store under `~/.zcode`; that is the CLI's own write, never ours. Ф1 and `zcode-invocation` give the exact command, with `ZCODE_PERSONAL_PROVIDER_CONFIG_FILE` pointing at a file outside `~/.zcode`, so the default model the login writes never touches the desktop app's provider config. The login opens a browser. If Claude Code's `!` prefix cannot host it, the user runs the line in a separate terminal window; `zcode-invocation` documents both forms.
- **R4 — Live probes spend Coding Plan quota.** Ф1: about ten short prompts plus one 150 KB prompt; Ф5: one probe, one small E2E task, one fix round. All other phases make zero model calls.
- **R5 — Classifier patterns are broad.** Initial patterns (`401`, `login`, `quota`, …) may misclassify; Ф1 records the exact strings (U4) and Ф2 Step 8 replaces the lists. Unknown strings classify as `crash` → one retry, then Luna: never a false success.
- **R6 — Prompt text the CLI could misparse.** Node's `parseArgs` treats a `-p` value starting with `-` as ambiguous, and the CLI treats a prompt starting with `/` as a slash command. Every GLM dispatch file begins with the ZCode preamble (`## ZCode headless run …`) and the probe prompt is fixed, so neither can occur; `zcode-invocation` says so.
- **R7 — Record races (accepted).** Records are written by atomic rename; terminal statuses are sticky through the exclusively created `.terminal` claim (C2), which readers prefer — so neither a racing runner finalize nor a stale `running` rename by the runner (`updateRunning`) can overwrite a `cancelled` written by `cancel` before it signals; `updateRunning` re-checks the claim after writing and reports the job as no longer running. A `cancel` issued within the ~100 ms between `task` and the runner's first write can miss the child (both pids still `null`); the orchestrator never cancels that fast. No lock file for job records (Non-goal); the only lock is the per-workspace write reservation (C1, ledger F1-B1-Ф2), which makes the one-write-task guard atomic and keeps the workspace reserved after `cancel` until the cancelled CLI has exited, and is generation-numbered (C3, ledger F3-B1-Ф2): acquire after a normal release advances only by exclusive creation of `active.lock.<n+1>` and release is a separate `.released` record, so the current reservation is never deleted and two concurrent `task`s cannot both take the workspace; the generation files and their release records are the only lock. A stale reservation is never reclaimed automatically (ledger F4-B1-Ф2): `task` refuses with the stale message, and only the explicit single-actor `release-stale` verb (C1; never signals, never unlinks, exclusive `.released` creation so a concurrent second call reports already released) frees it. Residual cost (accepted): after a runner crash the workspace stays blocked for GLM until `release-stale` runs.
- **R8 — Policy (residual, accepted by the user).** Headless use of the CLI is not addressed by Z.ai's terms either way. Mitigations: official harness only, truthful identification, no credential access, width cap 2, the warning in the skill, the kill switch.
- **R9 — No sandbox in `yolo` (SECURITY).** GLM runs as the user. Mitigations: git-tree guard, preamble, risk-marked phases on Sol, `--workflow-mode disabled`, no `--target`. Prose, not enforcement. The ZCode CLI also loads a `.env` from its working directory (`loadCliDotenv` in `prompt-command.ts`) — the repository's own `.env`, inside the trust boundary the user already accepts. **Ф2 carries SECURITY materiality** (it is the enforcement point for the guards, the environment pins and process-group signalling) and **Ф3 carries SECURITY materiality** (the routing rules that keep risk-marked phases off the unsandboxed channel).
- **R10 — App auto-update.** A new ZCode.app may move `zcode.cjs`, change flags or the JSON shape. `doctor` WARNs on a version mismatch (`VERIFIED_APP_VERSION`); `launch` / `malformed` fall back to Luna; the live acceptance must be re-run per app version.
- **R11 — The running orchestrator is the installed 0.7.0 plugin.** This plan's own non-frontend phases are implemented by Codex Luna under 0.7.0 rules; the new protocol takes effect only after release and reinstall (Non-goal). The dev-tree wrapper (`$(pwd)/bin/zcode-dispatch`) is what Ф5 exercises.
- **R12 — Large prose phase (Ф3).** About thirty anchored edits to `SKILL.md` plus a new skill. Mitigation: the plan carries the exact replacement text and a structural check; reviewers check against spec §5–§6.
- **R13 — Quota measurement noise.** Off-peak and weekend billing halve the deduction (Ф5 records the local time); the `doctor --probe` usage line carries no reasoning count, so when U3 finds reasoning billed as a separate counter the probe's reasoning is a missing required value and Ф5 Step 7 reports the result as inconclusive — it is never estimated or treated as 0; any other missing counter does the same, and a ratio outside both bands is reported as inconclusive.
- **R14 — Assumption: the Codex sandbox runs the Ф2 suite.** The tests use `mktemp -d`, detached processes, signals, `pkill`, `plutil` and a temporary `HOME`; `tests/test-sdd-scripts.sh` (mktemp + git) already runs there. The suite was prototyped against this exact code at plan time: `PASS` in ~20 s, including with `PROMPT_TRANSPORT = "stdin"`, `APP_VERSION_PLIST_KEY = "CFBundleVersion"`, and non-empty `MODEL_ARGS` / `DISALLOWED_TOOLS`.
- **R15 — Assumption: usage field names.** `USAGE_FIELDS` starts at `inputTokens` / `cacheReadTokens` / `outputTokens` (names present in the bundled CLI); Ф1 confirms or replaces them (U3).

## Phases

## Ф1: ZCode CLI discovery spike (go/no-go)

**Executor:** a Claude subagent — `Agent(subagent_type="general-purpose", model="opus", effort="high")` — dispatched with the first-round template of `skills/dev-orchestrator/implementer-prompt.md` (it supplies `[REPORT_FILE]` and the status tokens). **Not the Codex implementer:** this phase needs network, real `zcode` runs and the CLI's own writes under `~/.zcode`, which the Codex workspace-write sandbox blocks. `NEEDS_CONTEXT` round trips go through fresh Agent calls carrying the added context (SKILL.md Step 3, Claude path). One step needs the **user** (Step 6a: the one-time `zcode login zai`). The executor's final message carries `VERDICT: GO` or `VERDICT: NO-GO` on line 2. The exception is a `BLOCKED` finish (Step 6 cases (a)–(e): the login did not complete, the probe file holds a credential-like value, the pinned run failed, the pin was not applied, or the effective model could not be confirmed). A `BLOCKED` finish carries no verdict and is handled as `BLOCKED` (SKILL.md), never as `NO-GO`. On `NO-GO` the orchestrator commits Ф1 and stops before Ф2 ("## Multi-phase plans": findings invalidate later phases → ask the user).

**Resume point (plan revision after the first `BLOCKED`).** Steps 1–5 are done; `[REPORT_FILE]` lists them and records `PROBE_ROOT`. The embedded CLI has no TUI, so the old `/model` user step is replaced by Step 6a. The user ran Step 6a's command themselves. The re-dispatch carries `## Added context: zcode login zai — done` or `— failed: <what the user saw>`. Continue at Step 6b, and do not send the Step 6a message again.

**Files in this phase:**
- Create: `docs/zcode-cli-findings.md`

**Interfaces:**
- Consumes: nothing
- Produces: `docs/zcode-cli-findings.md` with sections `## Go / no-go` (line `VERDICT: GO` | `VERDICT: NO-GO — <reason>`), `## U1 — …` through `## U11 — …`, and `## Inputs for later phases` filled for every key of Contract C7 (`VERDICT`, `MODEL_MECHANISM`, `SELECTION_PATH`, `PERSONAL_CONFIG_BASE`, `PINNED_SELECTION`, `RESUME_KEEPS_MODEL`, `REPORTED_MODEL_FIELD`, `USAGE_INPUT_FIELD`, `USAGE_CACHED_FIELD`, `USAGE_OUTPUT_FIELD`, `USAGE_REASONING_FIELD`, `CACHED_IS_SUBSET_OF_INPUT`, `PROMPT_TRANSPORT`, `MAX_PROMPT_BYTES`, `VERIFIED_APP_VERSION`, `VERIFIED_NODE_MAJOR`, `APP_VERSION_PLIST_KEY`, `DISALLOWED_TOOLS`, `GLM_CONCURRENCY`, `SESSION_SAVED_ON_SIGTERM`, `INTERFERING_PLUGINS`, `PATTERN_MODEL_NOT_SELECTED`, `PATTERN_AUTH`, `PATTERN_QUOTA`, `PATTERN_LAUNCH`)

Rules for this phase (in addition to the implementer template):
- Discovery-only exception: the wrapper does not exist yet, so this phase calls the CLI directly (through the `zc` helper below, with exactly the environment the wrapper will use). After this plan, Red Flag 5 forbids that.
- Never read or write anything under `~/.zcode` yourself (the CLI writes its own state there — that is normal use). Never run `zcode login`, `logout`, `plugins install/enable/disable/remove`, or change any ZCode setting. Never open the ZCode desktop app. The login is the user's Step 6a. The only ZCode-format file you read and edit is the probe-owned `<PROBE_ROOT>/personal-provider-config.json`, which is outside `~/.zcode` and holds no credentials (Step 6b checks).
- If `[REPORT_FILE]` already exists when you start, read it first and continue from the first step it does not list as done; record every finished step (and `PROBE_ROOT`) there as you go — a `NEEDS_CONTEXT` round trip restarts you as a fresh session.
- Shell state does not persist between tool calls: re-set `PROBE_ROOT=<value from the report>` at the top of each command block.

- [ ] **Step 1: Run the completeness check (fails — the file does not exist yet)**

Run from the repo root:

```bash
f=docs/zcode-cli-findings.md
for u in U1 U2 U3 U4 U5 U6 U7 U8 U9 U10 U11; do grep -q "^## $u — " "$f" 2>/dev/null || echo "missing section $u"; done
grep -Eq '^VERDICT: (GO|NO-GO)' "$f" 2>/dev/null || echo "missing VERDICT line"
for k in VERDICT MODEL_MECHANISM SELECTION_PATH PERSONAL_CONFIG_BASE PINNED_SELECTION RESUME_KEEPS_MODEL REPORTED_MODEL_FIELD USAGE_INPUT_FIELD USAGE_CACHED_FIELD USAGE_OUTPUT_FIELD USAGE_REASONING_FIELD CACHED_IS_SUBSET_OF_INPUT PROMPT_TRANSPORT MAX_PROMPT_BYTES VERIFIED_APP_VERSION VERIFIED_NODE_MAJOR APP_VERSION_PLIST_KEY DISALLOWED_TOOLS GLM_CONCURRENCY SESSION_SAVED_ON_SIGTERM INTERFERING_PLUGINS PATTERN_MODEL_NOT_SELECTED PATTERN_AUTH PATTERN_QUOTA PATTERN_LAUNCH; do
  grep -Eq "^\| $k \| *[^| ][^|]* \|" "$f" 2>/dev/null || echo "missing key $k"
done
echo check-done
```

Expected now: 11 `missing section` lines, `missing VERDICT line`, 25 `missing key` lines, then `check-done`.

- [ ] **Step 2: Create the findings skeleton**

Write `docs/zcode-cli-findings.md` with exactly this structure (fill every `- Answer:` … line in later steps; the header lines in Step 4):

```markdown
# ZCode CLI findings — discovery for the GLM implementer channel

- ZCode.app:
- Embedded CLI:
- Source tag read: v3.15.1 (`gh api -H 'Accept: application/vnd.github.raw' repos/zai-org/ZCode/contents/<path>?ref=v3.15.1`)
- Node:
- Date:
- Method: source reading at the tag above, plus direct CLI runs (discovery-only exception — the wrapper did not exist yet) against throwaway git repos. Nothing under `~/.zcode` was read; the executor made no login/logout, settings or plugin change. The user ran the one-time `zcode login zai` (U1), with the personal provider config pointed at a probe-owned file.

## Go / no-go

VERDICT:

## U1 — how a headless `-p` run receives the model
- Answer:
- How verified:
- Holds for:
- Design consequence:

## U2 — does `--resume` keep model and effort
- Answer:
- How verified:
- Holds for:
- Design consequence:

## U3 — effective model in the JSON; `usage` field names and semantics
- Answer:
- How verified:
- Holds for:
- Design consequence:

## U4 — error strings and exit codes (auth, model-not-selected, quota, hang)
- Answer:
- How verified:
- Holds for:
- Design consequence:

## U5 — can two `zcode -p` processes run concurrently
- Answer:
- How verified:
- Holds for:
- Design consequence:

## U6 — what `--disallowedTools` applies to
- Answer:
- How verified:
- Holds for:
- Design consequence:

## U7 — is the session saved on SIGTERM
- Answer:
- How verified:
- Holds for:
- Design consequence:

## U8 — which plugins load headless; any auto-activation
- Answer:
- How verified:
- Holds for:
- Design consequence:

## U9 — is the 1.5× ZCode quota bonus active
- Answer: Deferred to the live acceptance (plan Ф5, spec §8.2 step 4).
- How verified: —
- Holds for: —
- Design consequence: none for the protocol; measured in Ф5.

## U10 — prompt-size limit of `-p`; does `-p -` read stdin
- Answer:
- How verified:
- Holds for:
- Design consequence:

## U11 — what the desktop app sets as `ZCODE_APP_VERSION`
- Answer:
- How verified:
- Holds for:
- Design consequence:

## Inputs for later phases

| Key | Value | Evidence |
|---|---|---|
| VERDICT |  | U1 |
| MODEL_MECHANISM |  | U1 |
| SELECTION_PATH |  | U1 |
| PERSONAL_CONFIG_BASE |  | U1 |
| PINNED_SELECTION |  | U1 |
| RESUME_KEEPS_MODEL |  | U2 |
| REPORTED_MODEL_FIELD |  | U3 |
| USAGE_INPUT_FIELD |  | U3 |
| USAGE_CACHED_FIELD |  | U3 |
| USAGE_OUTPUT_FIELD |  | U3 |
| USAGE_REASONING_FIELD |  | U3 |
| CACHED_IS_SUBSET_OF_INPUT |  | U3 |
| PROMPT_TRANSPORT |  | U10 |
| MAX_PROMPT_BYTES |  | U10 |
| VERIFIED_APP_VERSION |  | header |
| VERIFIED_NODE_MAJOR |  | header |
| APP_VERSION_PLIST_KEY |  | U11 |
| DISALLOWED_TOOLS |  | U6 |
| GLM_CONCURRENCY |  | U5 |
| SESSION_SAVED_ON_SIGTERM |  | U7 |
| INTERFERING_PLUGINS |  | U8 |
| PATTERN_MODEL_NOT_SELECTED |  | U4 |
| PATTERN_AUTH |  | U4 |
| PATTERN_QUOTA |  | U4 |
| PATTERN_LAUNCH |  | U4 |
```

- [ ] **Step 3: Read the source (offline, no quota)**

Fetch each file at tag `v3.15.1` with `gh api -H 'Accept: application/vnd.github.raw' "repos/zai-org/ZCode/contents/<path>?ref=v3.15.1"` and record what it says for the U-item named:

- `apps/zcode-cli/packages/cli/src/prompt-command.ts` — U1 (`configuredDefaultModelSelection`, `legacyCliUserConfigFilePath` / `deps.userConfigPath`), U3 (the JSON summary fields: `sessionId`, `traceId`, `turnId`, `response`, `usage`, `eventCount`, `projection` — is any model field present?), U4 (errors are written as `Error: <message>` and the run returns 1).
- `apps/zcode-cli/packages/core/src/runtime/methods/runtime-model.ts` — U1, U4 (the exact `Select a model before continuing` throw and its error code).
- `apps/zcode-cli/packages/core/tests/runtime-unbound-resume.test.ts` and `apps/zcode-cli/packages/cli/src/resume.ts` — U2 (what a resumed session uses as its model).
- `apps/zcode-cli/packages/cli/src/arguments.ts` (`parseGlobalArgs`, `extractDisallowedToolsArgs`) — U1 (no `--model` / `--effort`), U6, U10 (`prompt` is a plain string option).
- `apps/zcode-cli/packages/cli/src/run.ts` — U10 (does anything read stdin for `-p -`?).
- `apps/zcode-cli/packages/cli/src/process-errors.ts` — U4.
- `apps/zcode-cli/packages/cli/src/plugins-command.ts` — U8 (the read-only list subcommand).
- `apps/zcode-cli/packages/core/src/runtime/methods/turn-model-step-usage.ts` — U3 (is the cached count a subset of input; are reasoning tokens inside or beside output).

Also grep the local bundle for the provider registry's persisted default selection and for the auth / quota strings (read-only):

```bash
B=/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs
grep -o '.\{160\}configuredDefaultModelSelection.\{160\}' "$B" | head -5
grep -o '.\{120\}modelSelectionConfigRepository.\{120\}' "$B" | head -5
for s in 401 429 Unauthorized 'rate limit' quota 'not logged in' 'token expired' insufficient; do echo "== $s"; grep -o ".\{80\}$s.\{80\}" "$B" | head -3; done
grep -a -o 'ZCODE_APP_VERSION.\{0,120\}' /Applications/ZCode.app/Contents/Resources/app.asar | head -5
```

The last line is U11 (what the desktop app passes). If ZCode.app happens to be running with an agent session, also run `ps -Eww -o command= | grep -o 'ZCODE_APP_VERSION=[^ ]*' | head -1`; do not launch the app.

- [ ] **Step 4: Fill the header with local facts (offline)**

```bash
plutil -extract CFBundleShortVersionString raw -o - /Applications/ZCode.app/Contents/Info.plist
plutil -extract CFBundleVersion raw -o - /Applications/ZCode.app/Contents/Info.plist
node --version
```

Then create the probe helper and the throwaway repo; record the printed `PROBE_ROOT` in `[REPORT_FILE]`:

```bash
PROBE_ROOT="$(mktemp -d)"
cat > "$PROBE_ROOT/zc" <<'EOF'
#!/usr/bin/env bash
# Discovery-only direct ZCode CLI call with the environment zcode-dispatch will use (plan Ф1 only).
ZAPP=/Applications/ZCode.app
ZCFG="$ZAPP/Contents/Resources/config/provider/zcode-builtin.json"
export ZCODE_BUILTIN_PROVIDER_CONFIG_FILE="$ZCFG" ZCODE_BUILTIN_PROVIDER_BUNDLED_CONFIG_FILE="$ZCFG"
export ZCODE_APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ZAPP/Contents/Info.plist")"
# Per-invocation model mechanism found in Step 5 (absent until then): applied to every later -p run.
HERE="$(cd "$(dirname "$0")" && pwd)"
extra=()
if [[ " $* " == *" -p "* ]]; then
  [[ -f "$HERE/model.env" ]] && export "$(cat "$HERE/model.env")"
  [[ -f "$HERE/model.args" ]] && while IFS= read -r a; do extra+=("$a"); done < "$HERE/model.args"
fi
exec node "$ZAPP/Contents/Resources/glm/zcode.cjs" "$@" "${extra[@]}"
EOF
chmod +x "$PROBE_ROOT/zc"
git init -q -b main "$PROBE_ROOT/repo"
(cd "$PROBE_ROOT/repo" && printf 'probe\n' > README.md && git add README.md \
  && git -c user.email=p@example.com -c user.name=p -c commit.gpgsign=false commit -qm init)
"$PROBE_ROOT/zc" --version
"$PROBE_ROOT/zc" --help > "$PROBE_ROOT/help.txt" 2>&1; head -60 "$PROBE_ROOT/help.txt"
echo "PROBE_ROOT=$PROBE_ROOT"
```

Fill `ZCode.app:` (`<short> (<bundle version>)`), `Embedded CLI:` (`zcode <--version output>`), `Node:` and `Date:`; keep both plist values printed above in `[REPORT_FILE]` (`VERIFIED_APP_VERSION` is set in Step 13 from the key chosen as `APP_VERSION_PLIST_KEY`), and set `VERIFIED_NODE_MAJOR` to the node major (26 unless a lower major was verified to run the CLI).

- [ ] **Step 5: Live probe 1 — headless PONG in the current state (U1, U4)**

```bash
PROBE_ROOT=<from the report>
cd "$PROBE_ROOT/repo" && "$PROBE_ROOT/zc" -p 'Reply with exactly one word: PONG' --output-format json --mode yolo \
  --surface terminal --workflow-mode disabled --cwd "$PROBE_ROOT/repo" \
  > "$PROBE_ROOT/pong1.out" 2> "$PROBE_ROOT/pong1.err"; echo "exit=$?"
cat "$PROBE_ROOT/pong1.out"; tail -20 "$PROBE_ROOT/pong1.err"
```

Record the exit code and the exact stderr text (U4 model-not-selected). If it already succeeds (the user selected a model earlier), skip Step 6 and use `pong1.out` as `pong2.out` (`cp "$PROBE_ROOT/pong1.out" "$PROBE_ROOT/pong2.out"`).
If Step 3 found a per-invocation mechanism (a flag or env variable that sets the model selection), register it with the helper before Step 6 — a flag: `printf '%s\n' '<--flag-name>' 'GLM-5.3-Flash$max' > "$PROBE_ROOT/model.args"`; an env variable: `printf '%s\n' '<VAR_NAME>=GLM-5.3-Flash$max' > "$PROBE_ROOT/model.env"` — then re-run the probe command above with `pong2.out` / `pong2.err` in place of `pong1.*`: success → `MODEL_MECHANISM = flag:<name>` or `env:<NAME>`, keep the file (the `zc` helper now adds the mechanism to every later `-p` run — Steps 8–12, including the resume probes and `sigterm-probe.mjs`) and skip Step 6; failure → delete the file again and go on to Step 6.

- [ ] **Step 6: User login, then pin GLM-5.3-Flash / max in a probe-owned personal provider config (U1). Runs only if Step 5 failed with model-not-selected and no per-invocation mechanism exists.**

The embedded CLI ships without its TUI (`Cannot find package '@zcode/tui'`), so `/model` cannot run, and a headless `-p "/model …"` is plain prompt text. Headless `-p` gets an entitled model only after the CLI's own login (`zcode login zai` writes `account-provider:<id>:identity` into ZCode's shared credential store). It takes its default selection from the personal provider config named by `ZCODE_PERSONAL_PROVIDER_CONFIG_FILE`. Here that file is probe-owned and lives outside `~/.zcode`.

**6a. User step: one-time `zcode login zai`.** Skip this on the resume dispatch (see "Resume point" above). Otherwise stop here and finish with this final message. Line 1 is the token; fill `<PROBE_ROOT>` and the report path before finishing:

```
NEEDS_CONTEXT
U1 needs a one-time user action: the standalone ZCode CLI has no entitled model until it is logged in with Z.ai's own browser login. Its TUI is not shipped, so /model is impossible.
Please run this in a separate terminal window (it opens the browser for Z.ai's OAuth):
ZCODE_BUILTIN_PROVIDER_CONFIG_FILE=/Applications/ZCode.app/Contents/Resources/config/provider/zcode-builtin.json ZCODE_BUILTIN_PROVIDER_BUNDLED_CONFIG_FILE=/Applications/ZCode.app/Contents/Resources/config/provider/zcode-builtin.json ZCODE_APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - /Applications/ZCode.app/Contents/Info.plist)" ZCODE_PERSONAL_PROVIDER_CONFIG_FILE=<PROBE_ROOT>/personal-provider-config.json node /Applications/ZCode.app/Contents/Resources/glm/zcode.cjs login zai
It stores the CLI login in ZCode's own credential store. It writes the default model into the probe file named above, not into ~/.zcode/v2/provider_config.json, so the desktop app's selection stays untouched. Reply "done", or "failed: <what you saw>".
Report: <[REPORT_FILE] path>
```

The orchestrator relays the message verbatim. It then re-dispatches this phase (a fresh Agent call) with `## Added context: zcode login zai — done` or `## Added context: zcode login zai — failed: <text>`.

**6b. Record what the login wrote (offline, no quota).** The script prints:
- `SHAPE <json>`: keys and value types only, no values.
- `SECRET-LIKE <path>`: a key whose name looks like a credential and whose value is a non-URL string of 16 or more characters. Only the path is printed, never the value.
- `SELECTION_PATH <path>`: every key named `defaultModelSelection`.
- `LOGIN_SELECTION <json>` and `FILE <json>`: printed only when there is no `SECRET-LIKE` line.

```bash
PROBE_ROOT=<from the report>
F="$PROBE_ROOT/personal-provider-config.json"
ls -l "$F"
node -e '
const fs = require("node:fs");
let o;
try { o = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { console.log("UNREADABLE", e.code || e.message); process.exit(0); }
const secretName = /token|secret|password|passwd|credential|api.?key|authorization|cookie|private/i;
const shape = (v) => Array.isArray(v) ? `array(${v.length})` : v && typeof v === "object" ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, shape(x)])) : typeof v;
const secrets = [];
const selections = [];
const walk = (v, p) => {
  if (!v || typeof v !== "object") return;
  for (const [k, x] of Object.entries(v)) {
    const q = p ? `${p}.${k}` : k;
    if (secretName.test(k) && typeof x === "string" && x.length >= 16 && !/^https?:\/\//.test(x)) secrets.push(q);
    if (k === "defaultModelSelection") selections.push(q);
    walk(x, q);
  }
};
walk(o, "");
console.log("SHAPE", JSON.stringify(shape(o)));
for (const q of secrets) console.log("SECRET-LIKE", q); // the path only, never the value
for (const q of selections) console.log("SELECTION_PATH", q);
if (secrets.length === 0) {
  for (const q of selections) console.log("LOGIN_SELECTION", JSON.stringify(q.split(".").reduce((a, k) => a[k], o)));
  console.log("FILE", JSON.stringify(o));
}' "$F"
```

Work through these in order; the first that applies wins:
- (a) The added context says `failed`, the file is missing, empty or `UNREADABLE`, or no `SELECTION_PATH` line was printed → record what happened in U1 and `[REPORT_FILE]`. Leave `MODEL_MECHANISM` and `VERDICT` unset (no `none`, no `NO-GO`), ask the user nothing more, and finish with line 1 `BLOCKED` and the reason `zcode login zai did not complete — <user report | file missing | unreadable | no defaultModelSelection>`.
- (b) A `SECRET-LIKE` line → do not print, copy or edit the file. Record only the path in U1, leave both unset, and finish with line 1 `BLOCKED` and the reason `probe personal provider config holds a credential-like value at <path>; not copied`.
- Otherwise record in U1 the `SHAPE`, the `SELECTION_PATH` and the `LOGIN_SELECTION` (the JSON shape the login writes). The findings file was written before this revision, so make two edits if they are missing:
  1. Add the rows `| SELECTION_PATH |  | U1 |`, `| PERSONAL_CONFIG_BASE |  | U1 |` and `| PINNED_SELECTION |  | U1 |` right after the `MODEL_MECHANISM` row.
  2. Replace the header's `- Method:` line with the Step 2 skeleton's version.

  If more than one `SELECTION_PATH` was printed, use the one directly under the file's `config` object, or the top-level one if there is none, and record the others in U1.

**6c. Pin GLM-5.3-Flash / max in the probe-owned file (offline, no quota).** First confirm the selection schema in the bundle (read-only):

```bash
B=/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs
grep -o '.\{80\}options:m.object({reasoningLevel.\{60\}' "$B" | head -3
```

Plan-time reading of 3.15.1 found a strict `{providerId, modelId, options?: {reasoningLevel?}}` selection object; the personal-config serializer writes it under `config`. If the grep shows a different shape for the reasoning level, adapt only that part of the object in the script below and record why in U1. Then run the following, with `<SELECTION_PATH>` = the path from 6b:

```bash
PROBE_ROOT=<from the report>
F="$PROBE_ROOT/personal-provider-config.json"
cp "$F" "$PROBE_ROOT/personal-provider-config.login.json"
node -e '
const fs = require("node:fs");
const [file, selPath] = process.argv.slice(1);
const o = JSON.parse(fs.readFileSync(file, "utf8"));
const keys = selPath.split(".");
const parent = keys.slice(0, -1).reduce((a, k) => a[k], o);
const login = parent[keys.at(-1)];
parent[keys.at(-1)] = { providerId: login.providerId, modelId: "GLM-5.3-Flash", options: { ...(login.options || {}), reasoningLevel: "max" } };
fs.writeFileSync(file, `${JSON.stringify(o, null, 2)}\n`);
console.log("PINNED_SELECTION", JSON.stringify(parent[keys.at(-1)]));
delete parent[keys.at(-1)];
console.log("PERSONAL_CONFIG_BASE", JSON.stringify(o));' "$F" "<SELECTION_PATH>"
printf '%s\n' "ZCODE_PERSONAL_PROVIDER_CONFIG_FILE=$F" > "$PROBE_ROOT/model.env"
```

Record both printed values in `[REPORT_FILE]`. With `model.env` in place, the `zc` helper (Step 4) exports the variable on every later `-p` run: probe 2, Steps 8–12, the resume probes and `sigterm-probe.mjs`. The rest of Ф1 therefore runs on the pin.

**6d. Probe 2: a fresh headless PONG on the pin (U1, U3).** Two short requests:

```bash
PROBE_ROOT=<from the report>
cd "$PROBE_ROOT/repo" && "$PROBE_ROOT/zc" -p 'Reply with exactly one word: PONG' --output-format json --mode yolo \
  --surface terminal --workflow-mode disabled --cwd "$PROBE_ROOT/repo" \
  > "$PROBE_ROOT/pong2.out" 2> "$PROBE_ROOT/pong2.err"; echo "exit=$?"
cat "$PROBE_ROOT/pong2.out"; tail -20 "$PROBE_ROOT/pong2.err"
cd "$PROBE_ROOT/repo" && "$PROBE_ROOT/zc" -p 'Reply with exactly one word: PONG' --output-format stream-json --verbose --mode yolo \
  --surface terminal --workflow-mode disabled --cwd "$PROBE_ROOT/repo" \
  > "$PROBE_ROOT/pong2s.out" 2> "$PROBE_ROOT/pong2s.err"; echo "exit=$?"
cat "$PROBE_ROOT/pong2s.out" "$PROBE_ROOT/pong2s.err" \
  | grep -aoE '"(modelId|model|mainModel)" *: *"[^"]*"|"reasoningLevel" *: *"[^"]*"|GLM-[0-9][0-9.]*(-[A-Za-z]+)?(\$[a-z]+)?' \
  | sort | uniq -c | sort -rn | head -30
```

The JSON summary has no model field (U3, source). An invalid configured default silently falls back to the first registry model (R1). So the model evidence is the stream run's model-identifying matches: if needed, read the lines around them in `pong2s.*` to see which model the turn's request used. Decide; the first match wins:
- (c) `pong2` exits non-zero → record the exit code and the exact stderr in U1 and `[REPORT_FILE]`, leave `MODEL_MECHANISM` and `VERDICT` unset, and finish with line 1 `BLOCKED` and one of these reasons:
  - A model-not-selected string (`Select a model before continuing` / `Model creation failed`): the login gave the CLI no entitled model, since the fallback found nothing either. Reason: `login gave the CLI no entitled model — <stderr>`.
  - An auth string: reason `CLI auth failed after zcode login zai — <stderr>`.
  - Anything else (launch, timeout, crash): reason `pinned PONG indeterminate — <exit code / stderr summary>`.
- (d) `pong2` succeeds, but the matches show the run used a different model (for example `GLM-5.3` without `-Flash`) or a reasoning level other than `max`. The pin was not applied: the registry fell back. Record the matches in U1 and leave both unset. Session-bound resume, the third spec §10 U1 candidate, stays untested in this build (no TUI, no session with the model bound), so this is not `none`. Finish with line 1 `BLOCKED` and the reason `pinned selection rejected — run used <model / level>; session-bound resume untested`.
- (e) `pong2` succeeds, but the matches name no model, or name GLM-5.3-Flash and another model with no way to tell which one ran → record the matches, leave both unset, and finish with line 1 `BLOCKED` and the reason `effective model unverified — <matches>`.
- (f) `pong2` exits 0 with a JSON object whose `response` contains `PONG`, and the matches show `GLM-5.3-Flash` as the run's model (and `max` wherever a reasoning level appears). Set `MODEL_MECHANISM = personal-config`, then `SELECTION_PATH`, `PERSONAL_CONFIG_BASE` and `PINNED_SELECTION` (the 6b/6c values, one line each). Quote the deciding matches in U1 and continue with Step 7.

Step 6 never sets `MODEL_MECHANISM = none` or `VERDICT = NO-GO`. Every failure above ends `BLOCKED` with no verdict, and the user decides (spec §10 U1, "No way at all").

- [ ] **Step 7: U3 — JSON keys and usage semantics**

```bash
PROBE_ROOT=<from the report>
node -e 'const o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(Object.keys(o).join(" ")); console.log(JSON.stringify(o.usage, null, 2))' "$PROBE_ROOT/pong2.out"
```

Fill `REPORTED_MODEL_FIELD` (`none` unless a key carries the model id), the four `USAGE_*` fields (dot paths inside `usage`; `USAGE_REASONING_FIELD` only when reasoning is reported beside output, else `none`) and `CACHED_IS_SUBSET_OF_INPUT` (from `turn-model-step-usage.ts`; `unknown` if neither the source nor the numbers settle it).

- [ ] **Step 8: U2 — resume keeps model and effort**

```bash
PROBE_ROOT=<from the report>
SID="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).sessionId)' "$PROBE_ROOT/pong2.out")"
cd "$PROBE_ROOT/repo" && "$PROBE_ROOT/zc" -p 'Reply with exactly one word: PONG2' --output-format json --mode yolo \
  --surface terminal --workflow-mode disabled --cwd "$PROBE_ROOT/repo" --resume "$SID" \
  > "$PROBE_ROOT/resume.out" 2> "$PROBE_ROOT/resume.err"; echo "exit=$?"
cat "$PROBE_ROOT/resume.out"; tail -5 "$PROBE_ROOT/resume.err"
```

`RESUME_KEEPS_MODEL = yes` when the resume succeeds with the same `sessionId` and the source (Step 3) shows a resumed session keeps its bound selection including the reasoning level; `no` when the resume fails with model-not-selected or the source shows the level is dropped.

- [ ] **Step 9: U5 — two concurrent runs in two worktrees**

```bash
PROBE_ROOT=<from the report>
cd "$PROBE_ROOT/repo" && git worktree add -q "$PROBE_ROOT/wt1" -b wt1 && git worktree add -q "$PROBE_ROOT/wt2" -b wt2
: > "$PROBE_ROOT/conc.txt"
for w in wt1 wt2; do
  (cd "$PROBE_ROOT/$w" && "$PROBE_ROOT/zc" -p 'Reply with exactly one word: PONG' --output-format json --mode yolo \
    --surface terminal --workflow-mode disabled --cwd "$PROBE_ROOT/$w" > "$PROBE_ROOT/$w.out" 2> "$PROBE_ROOT/$w.err"; \
    echo "$w exit=$?" >> "$PROBE_ROOT/conc.txt") &
done
wait; cat "$PROBE_ROOT/conc.txt"
grep -il 'lock\|busy\|sqlite' "$PROBE_ROOT"/wt1.err "$PROBE_ROOT"/wt2.err || echo "no lock errors"
```

Both exit 0 with PONG and no lock errors → `GLM_CONCURRENCY = 2`; otherwise `1`.

- [ ] **Step 10: U7 — SIGTERM a long run, then try to resume it**

Write `$PROBE_ROOT/sigterm-probe.mjs`:

```js
// Discovery helper (plan Ф1, U7): run a long prompt, SIGTERM it after 20 s, report the session id seen.
import { spawn } from "node:child_process";
import fs from "node:fs";

const [zc, repo, out] = process.argv.slice(2);
const args = ["-p", "Count from 1 to 300, one number per line, then reply DONE.", "--output-format", "stream-json",
  "--mode", "yolo", "--surface", "terminal", "--workflow-mode", "disabled", "--cwd", repo];
const child = spawn(zc, args, { cwd: repo });
let text = "";
child.stdout.on("data", (d) => { text += d; });
child.stderr.on("data", (d) => fs.appendFileSync(`${out}.err`, d));
setTimeout(() => child.kill("SIGTERM"), 20_000);
child.on("exit", (code, signal) => {
  fs.writeFileSync(out, text);
  const m = /"sessionId"\s*:\s*"(sess_[^"]+)"/.exec(text);
  console.log(JSON.stringify({ code, signal, sessionId: m ? m[1] : null }));
});
```

```bash
PROBE_ROOT=<from the report>
node "$PROBE_ROOT/sigterm-probe.mjs" "$PROBE_ROOT/zc" "$PROBE_ROOT/repo" "$PROBE_ROOT/long.out"
```

If it printed a `sessionId`, resume it with the PONG prompt (`--resume <id>`, same flags as Step 8): success → `SESSION_SAVED_ON_SIGTERM = yes`; failure → `no`; no id visible in the stream → `unknown`. No design change follows either way (a retry after timeout is `--fresh`; a cancelled job is never resumed).

- [ ] **Step 11: U10 — prompt size and transport**

```bash
PROBE_ROOT=<from the report>
node -e 'const pad = "x".repeat(150 * 1024 - 200); process.stdout.write("Ignore the padding block below and reply with exactly one word: PONG\n\n<padding>\n" + pad + "\n</padding>\n")' > "$PROBE_ROOT/p150.txt"
cd "$PROBE_ROOT/repo" && "$PROBE_ROOT/zc" -p "$(cat "$PROBE_ROOT/p150.txt")" --output-format json --mode yolo \
  --surface terminal --workflow-mode disabled --cwd "$PROBE_ROOT/repo" > "$PROBE_ROOT/p150.out" 2> "$PROBE_ROOT/p150.err"; echo "exit=$?"
node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).response)' "$PROBE_ROOT/p150.out"
node -e 'const { spawnSync } = require("node:child_process"); const big = "y".repeat(300 * 1024); const r = spawnSync(process.execPath, ["-e", "console.log(process.argv[1].length)", big], { encoding: "utf8" }); console.log("status", r.status, "len", r.stdout.trim(), r.error ? r.error.code : "")'
```

The last command checks the OS argv limit without quota (expected `status 0 len 307200`). `PROMPT_TRANSPORT = stdin` only if `run.ts` reads stdin for `-p -` (Step 3); otherwise `argv`. `MAX_PROMPT_BYTES = 204800` when the 150 KB run answered PONG and the argv check printed `len 307200`; otherwise the largest size that worked (re-run the 150 KB command at 64 KB to find it).

- [ ] **Step 12: U8 and U6 — plugins and `--disallowedTools`**

```bash
PROBE_ROOT=<from the report>
"$PROBE_ROOT/zc" plugins --help 2>&1 | head -40
```

Run the read-only list subcommand that help names (never install / enable / disable / remove). Then a verbose PONG and two tool-list runs:

```bash
PROBE_ROOT=<from the report>
cd "$PROBE_ROOT/repo" && "$PROBE_ROOT/zc" -p 'Reply with exactly one word: PONG' --output-format json --mode yolo \
  --surface terminal --workflow-mode disabled --cwd "$PROBE_ROOT/repo" --verbose > "$PROBE_ROOT/verbose.out" 2> "$PROBE_ROOT/verbose.err"; echo "exit=$?"
grep -i 'plugin\|hook\|workflow' "$PROBE_ROOT/verbose.err" | head -40
cd "$PROBE_ROOT/repo" && "$PROBE_ROOT/zc" -p 'List the exact names of every tool you can call right now, one per line, nothing else.' \
  --output-format json --mode yolo --surface terminal --workflow-mode disabled --cwd "$PROBE_ROOT/repo" > "$PROBE_ROOT/tools1.out" 2>/dev/null
node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).response)' "$PROBE_ROOT/tools1.out"
```

Pick one plugin-provided tool name from that list (for example a browser-use or presentations tool) and repeat the tool-list run with `--disallowedTools <that name>` into `tools2.out`. The name disappears → `--disallowedTools` covers plugin tools; record `DISALLOWED_TOOLS` as the comma-separated plugin tools irrelevant to implementation (browser-use, computer-use, presentations and similar — spec §6.2), or `none` when it does not cover them. `INTERFERING_PLUGINS` = plugins that auto-activate headless (hooks, workflows) despite `--workflow-mode disabled`, else `none`.

- [ ] **Step 13: Fill U1–U11, the patterns and the verdict**

Fill every `- Answer:` / `- How verified:` / `- Holds for:` (`ZCode <short version> (zcode <cli version>)`) / `- Design consequence:` line, and every table value:
- `PATTERN_MODEL_NOT_SELECTED`: `Select a model before continuing;Model creation failed` plus any other exact substring Step 5 showed.
- `PATTERN_AUTH`: `401;unauthorized;not logged in;login;token expired;credential` plus the exact auth strings Step 3 found (do not provoke a logout).
- `PATTERN_QUOTA`: `429;quota;rate limit;usage limit;insufficient;balance` plus the exact quota strings Step 3 found.
- `PATTERN_LAUNCH`: `ZCODE_BUILTIN_PROVIDER;provider config;Cannot find module` plus any exact startup-error string found.
- `APP_VERSION_PLIST_KEY`: `CFBundleVersion` only if Step 3 showed the desktop app passes the full `3.15.1.8093`-style version; otherwise `CFBundleShortVersionString`.
- `VERIFIED_APP_VERSION`: the value Step 4 printed for that **same** plist key (the short `3.15.1` with `CFBundleShortVersionString`, the full `3.15.1.8093`-style value with `CFBundleVersion`) — the wrapper's `doctor` compares the value it reads via `APP_VERSION_PLIST_KEY` against it, so both sides come from one key.
- U1: replace the first run's `Unresolved (Ф1 BLOCKED …)` text with the Step 6 outcome. Cover the login, the JSON shape it wrote, the pinned selection, and the PONG and model evidence of probe 2. Under `Design consequence:` write that the wrapper owns its personal provider config and pins `PINNED_SELECTION` before every run, and that the user's one-time `zcode login zai` is a prerequisite.
- `SELECTION_PATH`, `PERSONAL_CONFIG_BASE`, `PINNED_SELECTION`: the values Step 6 recorded, each a single line (the two JSON values exactly as printed).
- `VERDICT`: `NO-GO` iff `MODEL_MECHANISM` is `none` (all three spec §10 U1 candidates shown to fail with an explicit model-selection refusal); otherwise `GO`. Step 6 never produces `none`, so a run that reaches this step has `MODEL_MECHANISM = personal-config` (or a Step 5 `flag:` / `env:`) and `VERDICT = GO`. Every Step 6 failure finishes `BLOCKED` with no verdict and never reaches this step. Write the `## Go / no-go` line as `VERDICT: GO` or `VERDICT: NO-GO — no headless model selection by any means (U1)`.

- [ ] **Step 14: Run the completeness check (passes)**

Run the Step 1 command block again. Expected: only `check-done`.

- [ ] **Step 15: Report**

Final message: line 1 `DONE` (or `DONE_WITH_CONCERNS`, naming the concern), line 2 exactly `VERDICT: GO` or `VERDICT: NO-GO`, then the report path. Do not commit. (A Step 6 `BLOCKED` finish skips Steps 13–15.)

- [ ] **Step 16: Commit the phase (orchestrator)**

```bash
git add -f docs/zcode-cli-findings.md
git commit -m "docs(zcode): record ZCode CLI discovery findings"
```

On `VERDICT: NO-GO`: after this commit, stop and ask the user — do not start Ф2.

## Ф2: `zcode-dispatch` wrapper and stubbed unit tests

**Executor:** default non-frontend route (Codex implementer). Zero model calls: every test runs against `tests/fixtures/zcode-stub.cjs`. Materiality: SECURITY (R9).

**Files in this phase:**
- Create: `bin/zcode-dispatch`
- Create: `bin/lib/zcode-dispatch.mjs`
- Create: `tests/fixtures/zcode-stub.cjs`
- Create: `tests/fixtures/FakeZCode.app/Contents/Info.plist`
- Create: `tests/fixtures/FakeZCode.app/Contents/Resources/config/provider/zcode-builtin.json`
- Test: `tests/test-zcode-dispatch.sh`

**Interfaces:**
- Consumes: `docs/zcode-cli-findings.md` with sections `## Go / no-go` (line `VERDICT: GO` | `VERDICT: NO-GO — <reason>`), `## U1 — …` through `## U11 — …`, and `## Inputs for later phases` filled for every key of Contract C7 (`VERDICT`, `MODEL_MECHANISM`, `SELECTION_PATH`, `PERSONAL_CONFIG_BASE`, `PINNED_SELECTION`, `RESUME_KEEPS_MODEL`, `REPORTED_MODEL_FIELD`, `USAGE_INPUT_FIELD`, `USAGE_CACHED_FIELD`, `USAGE_OUTPUT_FIELD`, `USAGE_REASONING_FIELD`, `CACHED_IS_SUBSET_OF_INPUT`, `PROMPT_TRANSPORT`, `MAX_PROMPT_BYTES`, `VERIFIED_APP_VERSION`, `VERIFIED_NODE_MAJOR`, `APP_VERSION_PLIST_KEY`, `DISALLOWED_TOOLS`, `GLM_CONCURRENCY`, `SESSION_SAVED_ON_SIGTERM`, `INTERFERING_PLUGINS`, `PATTERN_MODEL_NOT_SELECTED`, `PATTERN_AUTH`, `PATTERN_QUOTA`, `PATTERN_LAUNCH`) — this phase reads the Ф2 keys of C7 (Step 8).
- Produces: `bin/zcode-dispatch` with the command surface of Contract C1 (verbs `task`, `status`, `result`, `cancel`, `release-stale`, `doctor`, `doctor --probe`; start line `ZCode Task started in the background as zt-NNNN`; exit codes 0/1/2), job records per Contract C2 under the layout of Contract C3, errorClass set `timeout | crash | model-not-selected | auth | quota | launch | malformed`, and `bin/lib/zcode-dispatch.mjs` exports per Contract C4 (`PINNED_MODEL`, `VERIFIED_APP_VERSION`, `VERIFIED_NODE_MAJOR`, `PROMPT_TRANSPORT`, `MAX_PROMPT_BYTES`, `APP_VERSION_PLIST_KEY`, `MODEL_ARGS`, `MODEL_ENV`, `SELECTION_PATH`, `PERSONAL_CONFIG_BASE`, `PINNED_SELECTION`, `DISALLOWED_TOOLS`, `REPORTED_MODEL_PATH`, `USAGE_FIELDS`, `PATTERNS`, `main`, `readRecord`, `finalizeRecord`, `buildCliArgv`, `pinPersonalConfig`, `parseCliOutput`, `classifyFailure`); the test suite `tests/test-zcode-dispatch.sh`.

**As-built supersedes (fix rounds, ledger F1-B1-Ф2, F1-B2-Ф2, F2-B1-Ф2, F3-B1-Ф2, F4-B1-Ф2).** For two items the as-built `bin/lib/zcode-dispatch.mjs` and its tests in `tests/test-zcode-dispatch.sh` (and stub fixture) supersede the code blocks transcribed below: (1) the one-write-task-per-workspace guard is the atomic workspace write reservation of C1/C3, held until the CLI child exits, not released by `cancel`, and generation-numbered (`active.lock.<gen>` advanced only by exclusive creation of the next generation, release recorded in `active.lock.<gen>.released`, F3-B1-Ф2; this replaces the `active.lock.reclaim` marker of F2-B1-Ф2; no automatic reclaim — a stale reservation makes `task` refuse with the stale message and is freed only by the `release-stale` verb, which the blocks below do not contain, F4-B1-Ф2) (the block's check-then-create guard in `cmdTask` and its cancel-then-admit behaviour are superseded); (2) the child's stdout and stderr are decoded with `setEncoding('utf8')` (C5) instead of per-chunk conversion. The blocks below are left as originally written.

- [ ] **Step 1: Write the test fixtures**

`tests/fixtures/zcode-stub.cjs`:

```js
#!/usr/bin/env node
// Test stand-in for ZCode's zcode.cjs, selected via ZCODE_BIN. Never calls a model.
// ZCODE_STUB_MODE: ok | pong | resume | record | model-not-selected | auth | quota |
//                  launch | hang | crash | malformed
// ZCODE_STUB_RECORD: file the `record` mode writes; ZCODE_STUB_DELAY_MS: wait before
// acting; ZCODE_STUB_MESSAGE: stderr text for the four error modes.
"use strict";
const fs = require("node:fs");

const argv = process.argv.slice(2);
const mode = process.env.ZCODE_STUB_MODE || "ok";
const flag = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};
const sessionId = flag("--resume") || `sess_stub_${process.pid}`;

function emit(response) {
  process.stdout.write(
    `${JSON.stringify({
      sessionId,
      traceId: "trace_stub",
      turnId: "turn_stub",
      response,
      usage: { inputTokens: 100, cacheReadTokens: 40, outputTokens: 7, reasoningTokens: 3 },
      eventCount: 1,
    })}\n`,
  );
}

function fail(defaultMessage) {
  process.stderr.write(`Error: ${process.env.ZCODE_STUB_MESSAGE || defaultMessage}\n`);
  process.exit(1);
}

function readStdin() {
  return new Promise((resolve) => {
    let text = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => (text += chunk));
    process.stdin.on("end", () => resolve(text));
  });
}

async function run() {
  switch (mode) {
    case "ok":
      return emit("DONE\nstub finished");
    case "pong":
      return emit("PONG");
    case "resume":
      if (!flag("--resume")) fail("stub resume mode: --resume is missing");
      return emit("DONE\nresumed");
    case "record": {
      const stdin = flag("-p") === "-" ? await readStdin() : null;
      let personalConfig = null; // the personal provider config as the wrapper left it for this run
      try {
        personalConfig = JSON.parse(fs.readFileSync(process.env.ZCODE_PERSONAL_PROVIDER_CONFIG_FILE, "utf8"));
      } catch {
        personalConfig = null;
      }
      fs.writeFileSync(
        process.env.ZCODE_STUB_RECORD,
        JSON.stringify({
          argv,
          stdin,
          cwd: process.cwd(),
          env: {
            ZCODE_BUILTIN_PROVIDER_CONFIG_FILE: process.env.ZCODE_BUILTIN_PROVIDER_CONFIG_FILE ?? null,
            ZCODE_BUILTIN_PROVIDER_BUNDLED_CONFIG_FILE: process.env.ZCODE_BUILTIN_PROVIDER_BUNDLED_CONFIG_FILE ?? null,
            ZCODE_APP_VERSION: process.env.ZCODE_APP_VERSION ?? null,
            ZCODE_PERSONAL_PROVIDER_CONFIG_FILE: process.env.ZCODE_PERSONAL_PROVIDER_CONFIG_FILE ?? null,
            ZCODE_DATA_BASE_DIR: process.env.ZCODE_DATA_BASE_DIR ?? null,
          },
          personalConfig,
        }),
      );
      return emit("DONE\nrecorded");
    }
    case "model-not-selected":
      return fail("Model creation failed — Select a model before continuing");
    case "auth":
      return fail("401 Unauthorized");
    case "quota":
      return fail("429 usage limit reached");
    case "launch":
      return fail("Cannot find module '@zcode/bootstrap'");
    case "hang":
      setTimeout(() => {}, 600_000);
      return undefined;
    case "crash":
      process.kill(process.pid, "SIGKILL");
      return undefined;
    case "malformed":
      process.stdout.write("not json\n");
      return undefined;
    default:
      return fail(`unknown ZCODE_STUB_MODE: ${mode}`);
  }
}

setTimeout(run, Number(process.env.ZCODE_STUB_DELAY_MS || 0));
```

`tests/fixtures/FakeZCode.app/Contents/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleShortVersionString</key>
	<string>9.9.9</string>
	<key>CFBundleVersion</key>
	<string>9.9.9.1</string>
</dict>
</plist>
```

`tests/fixtures/FakeZCode.app/Contents/Resources/config/provider/zcode-builtin.json`:

```json
{}
```

- [ ] **Step 2: Write the failing test suite**

`tests/test-zcode-dispatch.sh` (then `chmod +x tests/test-zcode-dispatch.sh`):

```bash
#!/usr/bin/env bash
# Tests for bin/zcode-dispatch, the ZCode CLI job wrapper. Zero model calls:
# ZCODE_BIN points at tests/fixtures/zcode-stub.cjs, ZCODE_APP at
# tests/fixtures/FakeZCode.app, and all job state lives under a temp root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZD="$REPO_ROOT/bin/zcode-dispatch"
MJS="$REPO_ROOT/bin/lib/zcode-dispatch.mjs"
FIX="$SCRIPT_DIR/fixtures"

FAILURES=0
TEST_ROOT=""

pass() { echo "  [PASS] $1"; }
fail() {
    echo "  [FAIL] $1"
    FAILURES=$((FAILURES + 1))
}

cleanup() {
    pkill -f "$FIX/zcode-stub.cjs" 2>/dev/null || true
    if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
        rm -rf "$TEST_ROOT"
    fi
}

# jfield <dot.path> — read JSON on stdin, print the field ('' when missing; objects as JSON).
jfield() {
    node -e '
let s = "";
process.stdin.on("data", (d) => (s += d)).on("end", () => {
  let v = JSON.parse(s);
  for (const k of process.argv[1].split(".")) v = v == null ? undefined : v[k];
  process.stdout.write(v === undefined || v === null ? "" : typeof v === "object" ? JSON.stringify(v) : String(v));
});' "$1"
}

# const_of <NAME> — print an exported constant of the wrapper module (objects as JSON).
const_of() {
    ZD_MJS="$MJS" node --input-type=module -e '
const { pathToFileURL } = await import("node:url");
const m = await import(pathToFileURL(process.env.ZD_MJS).href);
const v = m[process.argv[1]];
console.log(typeof v === "object" ? JSON.stringify(v) : String(v));' "$1"
}

# first_pattern <errorClass> — the first classifier pattern of a class.
first_pattern() {
    ZD_MJS="$MJS" node --input-type=module -e '
const { pathToFileURL } = await import("node:url");
const m = await import(pathToFileURL(process.env.ZD_MJS).href);
console.log(m.PATTERNS[process.argv[1]][0]);' "$1"
}

# wait_status <id> <regex> <seconds> [status args...] — poll until the status matches; print it.
wait_status() {
    local id="$1" want="$2" limit="$3"
    shift 3
    local st="" i=0
    while ((i < limit * 5)); do
        st="$("$ZD" status "$id" --json "$@" 2>/dev/null | jfield job.status || true)"
        if [[ "$st" =~ ^($want)$ ]]; then break; fi
        sleep 0.2
        i=$((i + 1))
    done
    echo "$st"
}

# wait_child <id> [status args...] — wait until the runner has recorded childPid; print it.
wait_child() {
    local id="$1"
    shift
    local child="" i=0
    while ((i < 50)); do
        child="$("$ZD" status "$id" --json "$@" 2>/dev/null | jfield job.childPid || true)"
        if [[ -n "$child" ]]; then break; fi
        sleep 0.2
        i=$((i + 1))
    done
    echo "$child"
}

# gone <pid> — true once the process no longer exists (waits up to 3 s).
gone() {
    local i=0
    while ((i < 15)); do
        if ! kill -0 "$1" 2>/dev/null; then return 0; fi
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

# start_task [task args...] — run `task --background`, print the new job id.
start_task() {
    local out
    out="$("$ZD" task --background "$@")"
    echo "${out##* }"
}

# expect_exit <code> <label> <command...>
expect_exit() {
    local want="$1" label="$2"
    shift 2
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq "$want" ]]; then
        pass "$label"
    else
        fail "$label"
        echo "    exit: $rc (want $want)"
    fi
}

main() {
    echo "=== Test: zcode-dispatch ==="

    TEST_ROOT="$(mktemp -d)"
    trap cleanup EXIT

    # No marketplace cache under this HOME, so the shim must resolve the dev-tree .mjs.
    export HOME="$TEST_ROOT/home"
    mkdir -p "$HOME"
    export ZCODE_APP="$FIX/FakeZCode.app"
    export ZCODE_BIN="$FIX/zcode-stub.cjs"
    export ZCODE_STATE_DIR="$TEST_ROOT/state"
    unset ZCODE_NODE ZCODE_TASK_TIMEOUT_MIN SP_IMPLEMENTER ZCODE_DATA_BASE_DIR
    unset ZCODE_STUB_MODE ZCODE_STUB_RECORD ZCODE_STUB_DELAY_MS ZCODE_STUB_MESSAGE

    git init -q -b main "$TEST_ROOT/repo"
    local repo
    repo="$(cd "$TEST_ROOT/repo" && git rev-parse --show-toplevel)"
    local git_id=(-c user.email=t@example.com -c user.name=t -c commit.gpgsign=false)
    printf 'x\n' > "$repo/a.txt"
    (cd "$repo" && git add a.txt && git "${git_id[@]}" commit -qm c0)
    mkdir -p "$TEST_ROOT/notgit"
    local prompt="$TEST_ROOT/prompt.md"
    printf '## ZCode headless run — read this first\n\nImplement the thing.\n' > "$prompt"
    cd "$repo"

    local out rc id st ec rec child runner

    # --- 13. shim resolution ---
    rc=0
    out="$("$ZD" 2>&1)" || rc=$?
    if [[ "$rc" -eq 2 && "$out" == *"usage: zcode-dispatch"* ]]; then
        pass "13 shim resolves the dev-tree .mjs when no marketplace cache exists"
    else
        fail "13 shim resolves the dev-tree .mjs when no marketplace cache exists"
        echo "    exit: $rc out: $out"
    fi

    # --- 1. task prints the start line; ids increment ---
    export ZCODE_STUB_MODE=ok
    out="$("$ZD" task --background --prompt-file "$prompt")"
    st="$(wait_status zt-0001 'completed|failed|cancelled' 20)"
    local out2
    out2="$("$ZD" task --background --prompt-file "$prompt")"
    wait_status zt-0002 'completed|failed|cancelled' 20 >/dev/null
    if [[ "$out" == "ZCode Task started in the background as zt-0001" \
        && "$out2" == "ZCode Task started in the background as zt-0002" && "$st" == completed ]]; then
        pass "1 task prints 'ZCode Task started in the background as zt-0001', next is zt-0002"
    else
        fail "1 task prints 'ZCode Task started in the background as zt-0001', next is zt-0002"
        echo "    out: $out | $out2 | status: $st"
    fi

    # --- 2. pinned argv and environment ---
    export ZCODE_STUB_MODE=record ZCODE_STUB_RECORD="$TEST_ROOT/record.json"
    id="$(start_task --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    local transport plist_key want_version cfg
    transport="$(const_of PROMPT_TRANSPORT)"
    plist_key="$(const_of APP_VERSION_PLIST_KEY)"
    want_version="$(plutil -extract "$plist_key" raw -o - "$ZCODE_APP/Contents/Info.plist")"
    cfg="$ZCODE_APP/Contents/Resources/config/provider/zcode-builtin.json"
    if [[ "$st" == completed ]] && REC="$TEST_ROOT/record.json" PROMPT="$prompt" ROOT="$repo" \
        TRANSPORT="$transport" CFG="$cfg" VER="$want_version" \
        MODEL_ARGS="$(const_of MODEL_ARGS)" DISALLOWED="$(const_of DISALLOWED_TOOLS)" node -e '
const fs = require("node:fs");
const r = JSON.parse(fs.readFileSync(process.env.REC, "utf8"));
const a = r.argv;
const pair = (f, v) => a.some((x, i) => x === f && a[i + 1] === v);
const prompt = fs.readFileSync(process.env.PROMPT, "utf8");
const promptOk = process.env.TRANSPORT === "stdin" ? pair("-p", "-") && r.stdin === prompt : pair("-p", prompt);
const modelArgs = JSON.parse(process.env.MODEL_ARGS);
const at = a.indexOf(modelArgs[0]);
const modelOk = modelArgs.length === 0 || (at >= 0 && modelArgs.every((x, k) => a[at + k] === x));
const disallowed = JSON.parse(process.env.DISALLOWED);
const disallowedOk = disallowed.length === 0 ? !a.includes("--disallowedTools") : pair("--disallowedTools", disallowed.join(","));
const ok = pair("--output-format", "json") && pair("--mode", "yolo") && pair("--surface", "terminal")
  && pair("--workflow-mode", "disabled") && pair("--cwd", process.env.ROOT)
  && !a.includes("--target") && !a.includes("--json") && !a.includes("-c") && !a.includes("--continue")
  && promptOk && modelOk && disallowedOk
  && r.env.ZCODE_BUILTIN_PROVIDER_CONFIG_FILE === process.env.CFG
  && r.env.ZCODE_BUILTIN_PROVIDER_BUNDLED_CONFIG_FILE === process.env.CFG
  && r.env.ZCODE_APP_VERSION === process.env.VER
  && r.env.ZCODE_DATA_BASE_DIR === null;
process.exit(ok ? 0 : 1);'; then
        pass "2 CLI argv pins json/yolo/terminal/workflow-disabled/--cwd root, prompt per PROMPT_TRANSPORT, env = provider config x2 + app version, no ZCODE_DATA_BASE_DIR"
    else
        fail "2 CLI argv pins json/yolo/terminal/workflow-disabled/--cwd root, prompt per PROMPT_TRANSPORT, env = provider config x2 + app version, no ZCODE_DATA_BASE_DIR"
        echo "    status: $st record: $(cat "$TEST_ROOT/record.json" 2>/dev/null | head -c 600)"
    fi

    # --- 2. personal provider config: wrapper-owned, pinned before every run, passed by env ---
    local pcfg sel_path pinned
    pcfg="$ZCODE_STATE_DIR/personal-provider-config.json"
    sel_path="$(const_of SELECTION_PATH)"
    pinned="$(const_of PINNED_SELECTION)"
    if [[ "$st" == completed ]] && REC="$TEST_ROOT/record.json" PCFG="$pcfg" SEL_PATH="$sel_path" PINNED="$pinned" node -e '
const fs = require("node:fs");
const r = JSON.parse(fs.readFileSync(process.env.REC, "utf8"));
const at = (o) => process.env.SEL_PATH.split(".").reduce((a, k) => (a == null ? undefined : a[k]), o);
process.exit(r.env.ZCODE_PERSONAL_PROVIDER_CONFIG_FILE === process.env.PCFG && r.personalConfig !== null
  && JSON.stringify(at(r.personalConfig)) === process.env.PINNED ? 0 : 1);'; then
        pass "2 the CLI gets ZCODE_PERSONAL_PROVIDER_CONFIG_FILE=<state root>/personal-provider-config.json, created before the run with SELECTION_PATH = PINNED_SELECTION"
    else
        fail "2 the CLI gets ZCODE_PERSONAL_PROVIDER_CONFIG_FILE=<state root>/personal-provider-config.json, created before the run with SELECTION_PATH = PINNED_SELECTION"
        echo "    status: $st file: $(head -c 400 "$pcfg" 2>/dev/null)"
    fi
    PCFG="$pcfg" SEL_PATH="$sel_path" node -e '
const fs = require("node:fs");
const o = JSON.parse(fs.readFileSync(process.env.PCFG, "utf8"));
const keys = process.env.SEL_PATH.split(".");
keys.slice(0, -1).reduce((a, k) => a[k], o)[keys.at(-1)] = { providerId: "p", modelId: "GLM-5.3" };
o.keptByWrapper = true;
fs.writeFileSync(process.env.PCFG, JSON.stringify(o));'
    id="$(start_task --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    if [[ "$st" == completed ]] && REC="$TEST_ROOT/record.json" SEL_PATH="$sel_path" PINNED="$pinned" node -e '
const fs = require("node:fs");
const r = JSON.parse(fs.readFileSync(process.env.REC, "utf8"));
const at = (o) => process.env.SEL_PATH.split(".").reduce((a, k) => (a == null ? undefined : a[k]), o);
process.exit(r.personalConfig?.keptByWrapper === true && JSON.stringify(at(r.personalConfig)) === process.env.PINNED ? 0 : 1);'; then
        pass "2 a changed selection is re-pinned before the next run; other content of the file is kept"
    else
        fail "2 a changed selection is re-pinned before the next run; other content of the file is kept"
        echo "    status: $st record: $(head -c 600 "$TEST_ROOT/record.json" 2>/dev/null)"
    fi
    unset ZCODE_STUB_RECORD

    # --- 3. status running -> completed; result; stored fields; recent cap ---
    export ZCODE_STUB_MODE=ok ZCODE_STUB_DELAY_MS=1500
    id="$(start_task --prompt-file "$prompt")"
    local st1
    st1="$("$ZD" status "$id" --json | jfield job.status)"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    unset ZCODE_STUB_DELAY_MS
    local res line1 sid usage
    res="$("$ZD" result "$id")"
    line1="$(printf '%s\n' "$res" | head -1)"
    rec="$("$ZD" status "$id" --json)"
    sid="$(jfield job.sessionId <<<"$rec")"
    usage="$(jfield job.usage <<<"$rec")"
    if [[ "$st1" == running && "$st" == completed && "$line1" == DONE \
        && "$sid" == sess_stub_* && "$usage" == *inputTokens* ]]; then
        pass "3 status running then completed; result prints the response; sessionId and usage stored"
    else
        fail "3 status running then completed; result prints the response; sessionId and usage stored"
        echo "    st1=$st1 st=$st line1=$line1 sid=$sid usage=$usage"
    fi

    local i
    for i in 1 2 3 4 5 6 7 8; do
        id="$(start_task --prompt-file "$prompt")"
        wait_status "$id" 'completed|failed|cancelled' 20 >/dev/null
    done
    local n_recent n_all
    n_recent="$("$ZD" status --json | jfield recent | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).length))')"
    n_all="$("$ZD" status --json --all | jfield recent | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).length))')"
    if [[ "$n_recent" -eq 10 && "$n_all" -eq 13 ]]; then
        pass "3 status without id lists the 10 newest terminal jobs; --all lists every job"
    else
        fail "3 status without id lists the 10 newest terminal jobs; --all lists every job"
        echo "    recent=$n_recent all=$n_all"
    fi

    # --- 6. failure classes ---
    local mode want crash_id=""
    for mode in crash malformed model-not-selected auth quota launch; do
        export ZCODE_STUB_MODE="$mode"
        case "$mode" in
            crash | malformed) unset ZCODE_STUB_MESSAGE ;;
            *) export ZCODE_STUB_MESSAGE="$(first_pattern "$mode")" ;;
        esac
        id="$(start_task --prompt-file "$prompt")"
        st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
        ec="$("$ZD" status "$id" --json | jfield job.errorClass)"
        [[ "$mode" == crash ]] && crash_id="$id"
        if [[ "$st" == failed && "$ec" == "$mode" ]]; then
            pass "6 stub mode $mode -> failed/$mode"
        else
            fail "6 stub mode $mode -> failed/$mode"
            echo "    got $st/$ec"
        fi
    done
    # ZCode suffixes errors with " (traceId: <uuid>)" (findings U4); its digit runs must not match auth.
    export ZCODE_STUB_MODE=quota
    export ZCODE_STUB_MESSAGE="$(first_pattern quota) (traceId: 5e401b7c-1429-4d2a-9c3e-0f4012ab7c11)"
    id="$(start_task --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    ec="$("$ZD" status "$id" --json | jfield job.errorClass)"
    if [[ "$st" == failed && "$ec" == quota ]]; then
        pass "6 traceId suffix containing 401/429 is stripped before matching -> failed/quota, not auth"
    else
        fail "6 traceId suffix containing 401/429 is stripped before matching -> failed/quota, not auth"
        echo "    got $st/$ec"
    fi
    unset ZCODE_STUB_MESSAGE
    export ZCODE_STUB_MODE=ok
    id="$(ZCODE_NODE=/nonexistent/node start_task --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    ec="$("$ZD" status "$id" --json | jfield job.errorClass)"
    if [[ "$st" == failed && "$ec" == launch ]]; then
        pass "6 ZCODE_NODE=/nonexistent/node (spawn ENOENT) -> failed/launch"
    else
        fail "6 ZCODE_NODE=/nonexistent/node (spawn ENOENT) -> failed/launch"
        echo "    got $st/$ec"
    fi
    rc=0
    "$ZD" result "$id" >/dev/null 2>"$TEST_ROOT/result-err.txt" || rc=$?
    if [[ "$rc" -eq 1 ]] && grep -q "^job $id is failed errorClass=launch$" "$TEST_ROOT/result-err.txt"; then
        pass "result on a failed job: stderr 'job <id> is failed errorClass=<class>', exit 1"
    else
        fail "result on a failed job: stderr 'job <id> is failed errorClass=<class>', exit 1"
        echo "    exit: $rc stderr: $(head -3 "$TEST_ROOT/result-err.txt")"
    fi

    # --- 4. resume mapping ---
    local sid1
    sid1="$("$ZD" status zt-0001 --json | jfield job.sessionId)"
    export ZCODE_STUB_MODE=resume
    id="$(start_task --resume-task zt-0001 --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    rec="$("$ZD" status "$id" --json)"
    if [[ "$st" == completed && "$(jfield job.resumeOf <<<"$rec")" == zt-0001 \
        && "$(jfield job.sessionId <<<"$rec")" == "$sid1" ]]; then
        pass "4 --resume-task zt-0001 passes --resume <job 1 session>; record has resumeOf and the same sessionId"
    else
        fail "4 --resume-task zt-0001 passes --resume <job 1 session>; record has resumeOf and the same sessionId"
        echo "    st=$st rec=$(printf '%s' "$rec" | head -c 400)"
    fi
    expect_exit 2 "4 resuming a failed job is refused (exit 2)" "$ZD" task --background --resume-task "$crash_id" --prompt-file "$prompt"
    expect_exit 2 "4 --resume-task together with --fresh is refused (exit 2)" "$ZD" task --background --resume-task zt-0001 --fresh --prompt-file "$prompt"
    expect_exit 2 "4 a Codex task- id is refused (exit 2)" "$ZD" task --background --resume-task task-0001 --prompt-file "$prompt"

    # --- 5. timeout ---
    export ZCODE_STUB_MODE=hang ZCODE_TASK_TIMEOUT_MIN=0.05
    id="$(start_task --prompt-file "$prompt")"
    child="$(wait_child "$id")"
    local started=$SECONDS
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    local elapsed=$((SECONDS - started))
    ec="$("$ZD" status "$id" --json | jfield job.errorClass)"
    unset ZCODE_TASK_TIMEOUT_MIN
    if [[ "$st" == failed && "$ec" == timeout && "$elapsed" -le 15 && -n "$child" ]] && gone "$child"; then
        pass "5 ZCODE_TASK_TIMEOUT_MIN=0.05 + hang -> failed/timeout within 15 s, stub gone"
    else
        fail "5 ZCODE_TASK_TIMEOUT_MIN=0.05 + hang -> failed/timeout within 15 s, stub gone"
        echo "    got $st/$ec after ${elapsed}s child=$child"
    fi

    # --- 7. dead runner ---
    export ZCODE_STUB_MODE=hang
    id="$(start_task --prompt-file "$prompt")"
    child="$(wait_child "$id")"
    runner="$("$ZD" status "$id" --json | jfield job.runnerPid)"
    kill -9 "$runner"
    sleep 0.5
    rec="$("$ZD" status "$id" --json)"
    if [[ "$(jfield job.status <<<"$rec")" == failed && "$(jfield job.errorClass <<<"$rec")" == crash \
        && "$(jfield job.note <<<"$rec")" == "runner died" && -n "$child" ]] && gone "$child"; then
        pass "7 runner killed -> status marks failed/crash note 'runner died', stub child gone"
    else
        fail "7 runner killed -> status marks failed/crash note 'runner died', stub child gone"
        echo "    rec=$(printf '%s' "$rec" | head -c 400)"
    fi

    # --- 8. cancel (plus guards that need a running job) ---
    id="$(start_task --prompt-file "$prompt")"
    child="$(wait_child "$id")"
    expect_exit 2 "4 resuming a running job is refused (exit 2)" "$ZD" task --background --resume-task "$id" --prompt-file "$prompt"
    expect_exit 2 "10 a second task while one is running in the workspace is refused (exit 2)" "$ZD" task --background --prompt-file "$prompt"
    out="$("$ZD" cancel "$id")"
    st="$("$ZD" status "$id" --json | jfield job.status)"
    if [[ "$out" == "cancelled $id" && "$st" == cancelled && -n "$child" ]] && gone "$child"; then
        pass "8 cancel prints 'cancelled <id>', record cancelled, CLI process group gone"
    else
        fail "8 cancel prints 'cancelled <id>', record cancelled, CLI process group gone"
        echo "    out=$out st=$st child=$child"
    fi
    sleep 1
    st="$("$ZD" status "$id" --json | jfield job.status)"
    out="$("$ZD" cancel "$id")"
    if [[ "$st" == cancelled && "$out" == "$id is cancelled" ]]; then
        pass "8 cancelled stays cancelled; cancel on a terminal job prints its status, exit 0"
    else
        fail "8 cancelled stays cancelled; cancel on a terminal job prints its status, exit 0"
        echo "    st=$st out=$out"
    fi
    printf '{"id":"zt-0500","status":"cancelled","errorClass":null}\n' > "$TEST_ROOT/sticky.json"
    if STICKY="$TEST_ROOT/sticky.json" ZD_MJS="$MJS" node --input-type=module -e '
const { pathToFileURL } = await import("node:url");
const m = await import(pathToFileURL(process.env.ZD_MJS).href);
m.finalizeRecord(process.env.STICKY, { status: "failed", errorClass: "crash" });
process.exit(m.readRecord(process.env.STICKY).status === "cancelled" ? 0 : 1);'; then
        pass "8 finalizeRecord never overwrites a terminal status (a late runner write keeps cancelled)"
    else
        fail "8 finalizeRecord never overwrites a terminal status (a late runner write keeps cancelled)"
    fi
    mkdir -p "$TEST_ROOT/race"
    printf '{"id":"zt-0501","status":"running","errorClass":null,"runnerPid":null,"childPid":null}\n' > "$TEST_ROOT/race/zt-0501.json"
    if RACE="$TEST_ROOT/race" ZD_MJS="$MJS" node --input-type=module -e '
const { pathToFileURL } = await import("node:url");
const fs = (await import("node:fs")).default;
const m = await import(pathToFileURL(process.env.ZD_MJS).href);
const file = `${process.env.RACE}/zt-0501.json`;
const realRename = fs.renameSync;
let injected = false;
// The runner has read `running`; cancel lands before the runner renames its stale copy into place.
fs.renameSync = (from, to) => {
  if (!injected && to === file) {
    injected = true;
    m.finalizeRecord(file, { status: "cancelled", errorClass: null, note: "cancelled by zcode-dispatch cancel" });
  }
  return realRename(from, to);
};
const rc = await m.main(["__run", "zt-0501", process.env.RACE]);
fs.renameSync = realRename;
const main = JSON.parse(fs.readFileSync(file, "utf8"));
const ok = injected && rc === 0 && main.status === "running" && Number.isInteger(main.runnerPid)
  && m.readRecord(file).status === "cancelled";
process.exit(ok ? 0 : 1);'; then
        pass "8 race: a runner renaming a stale running copy over a cancellation leaves the job cancelled"
    else
        fail "8 race: a runner renaming a stale running copy over a cancellation leaves the job cancelled"
    fi
    printf '{"id":"zt-0502","status":"running","errorClass":null,"runnerPid":null,"childPid":null}\n' > "$TEST_ROOT/race/zt-0502.json"
    if RACE="$TEST_ROOT/race" ZD_MJS="$MJS" node --input-type=module -e '
const { pathToFileURL } = await import("node:url");
const fs = (await import("node:fs")).default;
const m = await import(pathToFileURL(process.env.ZD_MJS).href);
const file = `${process.env.RACE}/zt-0502.json`;
const realLink = fs.linkSync;
let injected = false;
// The runner finalizes from a stale `running` read; cancel claims the terminal record first.
fs.linkSync = (from, to) => {
  if (!injected) {
    injected = true;
    m.finalizeRecord(file, { status: "cancelled", errorClass: null, note: "cancelled by zcode-dispatch cancel" });
  }
  return realLink(from, to);
};
const runner = m.finalizeRecord(file, { status: "completed", errorClass: null, response: "DONE" });
fs.linkSync = realLink;
process.exit(injected && runner.status === "cancelled" && m.readRecord(file).status === "cancelled" ? 0 : 1);'; then
        pass "8 race: a runner finalizing from a stale running read loses to a cancel that claimed first"
    else
        fail "8 race: a runner finalizing from a stale running read loses to a cancel that claimed first"
    fi

    # --- 9. worktree isolation ---
    (cd "$repo" && git worktree add -q "$TEST_ROOT/wt" -b wt-feature)
    local wt_root
    wt_root="$(cd "$TEST_ROOT/wt" && git rev-parse --show-toplevel)"
    export ZCODE_STUB_MODE=ok
    out="$("$ZD" task --background --cwd "$wt_root" --prompt-file "$prompt")"
    wait_status zt-0001 'completed|failed|cancelled' 20 --cwd "$wt_root" >/dev/null
    local main_roots wt_ws
    main_roots="$("$ZD" status --json --all)"
    wt_ws="$("$ZD" status zt-0001 --cwd "$wt_root" --json | jfield job.workspaceRoot)"
    if [[ "$out" == "ZCode Task started in the background as zt-0001" && "$wt_ws" == "$wt_root" \
        && "$main_roots" != *"\"workspaceRoot\": \"$wt_root\""* ]]; then
        pass "9 a --cwd <worktree> job is zt-0001 in its own workspace, invisible without --cwd"
    else
        fail "9 a --cwd <worktree> job is zt-0001 in its own workspace, invisible without --cwd"
        echo "    out=$out wt_ws=$wt_ws"
    fi

    # --- 10. refusals (exit 2) ---
    expect_exit 2 "10 outside a git work tree" "$ZD" task --background --cwd "$TEST_ROOT/notgit" --prompt-file "$prompt"
    expect_exit 2 "10 missing --prompt-file" "$ZD" task --background
    expect_exit 2 "10 prompt file does not exist" "$ZD" task --background --prompt-file "$TEST_ROOT/nope.md"
    : > "$TEST_ROOT/empty.md"
    expect_exit 2 "10 empty prompt file" "$ZD" task --background --prompt-file "$TEST_ROOT/empty.md"
    if [[ "$transport" == argv ]]; then
        local max
        max="$(const_of MAX_PROMPT_BYTES)"
        head -c $((max + 1)) /dev/zero | tr '\0' 'a' > "$TEST_ROOT/big.md"
        expect_exit 2 "10 prompt file larger than MAX_PROMPT_BYTES ($max)" "$ZD" task --background --prompt-file "$TEST_ROOT/big.md"
    else
        # stdin transport: the size guard does not apply (C1), so the big prompt starts a task.
        local max
        max="$(const_of MAX_PROMPT_BYTES)"
        head -c $((max + 1)) /dev/zero | tr '\0' 'a' > "$TEST_ROOT/big.md"
        rc=0
        out="$("$ZD" task --background --prompt-file "$TEST_ROOT/big.md" 2>&1)" || rc=$?
        st=""
        if [[ "$rc" -eq 0 && "$out" == "ZCode Task started in the background as zt-"* ]]; then
            st="$(wait_status "${out##* }" 'completed|failed|cancelled' 20)"
        fi
        if [[ "$st" == completed ]]; then
            pass "10 prompt file larger than MAX_PROMPT_BYTES ($max) is accepted on the stdin transport"
        else
            fail "10 prompt file larger than MAX_PROMPT_BYTES ($max) is accepted on the stdin transport"
            echo "    exit: $rc out: $out status: $st"
        fi
    fi
    expect_exit 2 "10 SP_IMPLEMENTER=luna" env SP_IMPLEMENTER=luna "$ZD" task --background --prompt-file "$prompt"
    mkdir -p "$TEST_ROOT/NoPlist.app/Contents"
    expect_exit 2 "10 ZCODE_APP without a readable Info.plist" env ZCODE_APP="$TEST_ROOT/NoPlist.app" "$ZD" task --background --prompt-file "$prompt"
    expect_exit 2 "10 missing --background" "$ZD" task --prompt-file "$prompt"
    expect_exit 2 "10 unknown flag" "$ZD" task --background --bogus --prompt-file "$prompt"
    expect_exit 2 "10 unknown id on status" "$ZD" status zt-9999
    expect_exit 2 "10 unknown id on result" "$ZD" result zt-9999
    expect_exit 2 "10 unknown id on cancel" "$ZD" cancel zt-9999

    # --- 11. doctor (offline) ---
    rc=0
    out="$("$ZD" doctor)" || rc=$?
    local checks=0 c
    for c in app cli provider-config node app-version git state-dir personal-config kill-switch; do
        if grep -Eq "^(ok|WARN) $c: " <<<"$out"; then checks=$((checks + 1)); fi
    done
    if [[ "$rc" -eq 0 && "$checks" -eq 9 && "$(tail -1 <<<"$out")" == "doctor: ok" ]] && ! grep -q '^FAIL' <<<"$out"; then
        pass "11 doctor against the fixtures: 9 checks ok/WARN, 'doctor: ok', exit 0"
    else
        fail "11 doctor against the fixtures: 9 checks ok/WARN, 'doctor: ok', exit 0"
        echo "    exit: $rc"
        echo "$out" | sed 's/^/    /'
    fi
    rc=0
    out="$(ZCODE_BIN=/nonexistent/zcode.cjs "$ZD" doctor)" || rc=$?
    if [[ "$rc" -eq 1 && "$out" == *"FAIL cli: "* && "$(tail -1 <<<"$out")" == "doctor: FAIL" ]]; then
        pass "11 doctor: missing zcode.cjs -> FAIL cli, exit 1"
    else
        fail "11 doctor: missing zcode.cjs -> FAIL cli, exit 1"
        echo "    exit: $rc"
    fi
    mkdir -p "$TEST_ROOT/NoCfg.app/Contents"
    cp "$ZCODE_APP/Contents/Info.plist" "$TEST_ROOT/NoCfg.app/Contents/Info.plist"
    rc=0
    out="$(ZCODE_APP="$TEST_ROOT/NoCfg.app" "$ZD" doctor)" || rc=$?
    if [[ "$rc" -eq 1 && "$out" == *"FAIL provider-config: "* ]]; then
        pass "11 doctor: missing provider config -> FAIL provider-config, exit 1"
    else
        fail "11 doctor: missing provider config -> FAIL provider-config, exit 1"
        echo "    exit: $rc"
    fi
    rc=0
    out="$("$ZD" doctor --cwd "$TEST_ROOT/notgit")" || rc=$?
    if [[ "$rc" -eq 1 && "$out" == *"FAIL git: "* ]]; then
        pass "11 doctor: outside a git tree -> FAIL git, exit 1"
    else
        fail "11 doctor: outside a git tree -> FAIL git, exit 1"
        echo "    exit: $rc"
    fi

    # --- 12. doctor --probe ---
    rc=0
    out="$(ZCODE_STUB_MODE=pong "$ZD" doctor --probe)" || rc=$?
    if [[ "$rc" -eq 0 && "$out" == *"model-selected: ok"* && "$out" == *"answers: ok"* \
        && "$out" == *"reported-model: unreported"* && "$out" == *"usage: input="* && "$(tail -1 <<<"$out")" == "probe: ok" ]]; then
        pass "12 doctor --probe with pong: probe ok, reported-model unreported, exit 0"
    else
        fail "12 doctor --probe with pong: probe ok, reported-model unreported, exit 0"
        echo "    exit: $rc"
        echo "$out" | sed 's/^/    /'
    fi
    rc=0
    out="$(ZCODE_STUB_MODE=model-not-selected ZCODE_STUB_MESSAGE="$(first_pattern model-not-selected)" "$ZD" doctor --probe 2>/dev/null)" || rc=$?
    if [[ "$rc" -eq 1 && "$out" == *"model-selected: FAIL(model-not-selected)"* && "$(tail -1 <<<"$out")" == "probe: FAIL" ]]; then
        pass "12 doctor --probe with model-not-selected: FAIL(model-not-selected), exit 1"
    else
        fail "12 doctor --probe with model-not-selected: FAIL(model-not-selected), exit 1"
        echo "    exit: $rc"
        echo "$out" | sed 's/^/    /'
    fi

    echo ""
    if [[ "$FAILURES" -ne 0 ]]; then
        echo "FAILED: $FAILURES assertion(s)."
        exit 1
    fi
    echo "PASS"
}

main "$@"
```

- [ ] **Step 3: Run the suite to verify it fails**

Run: `bash tests/test-zcode-dispatch.sh`
Expected: `[FAIL] 13 shim resolves the dev-tree .mjs when no marketplace cache exists` (the shim does not exist yet), then the script aborts with a non-zero exit.

- [ ] **Step 4: Write the shim**

`bin/zcode-dispatch` (then `chmod +x bin/zcode-dispatch`):

```bash
#!/usr/bin/env bash
# Wrapper for the plugin's ZCode dispatcher (bin/lib/zcode-dispatch.mjs).
#
# Resolves zcode-dispatch.mjs regardless of install layout (marketplace cache,
# newest version first, then the local dev tree), pins ZCODE_STATE_DIR so job
# state lives under ~/.claude/plugins/data/superpowers-strigov-ver-zcode, and
# execs node. The .mjs drives Z.ai's own ZCode CLI (embedded in
# /Applications/ZCode.app) headless — never the Z.ai API directly.
#
# Usage: zcode-dispatch <task|status|result|cancel|doctor> [args...]
set -eu

resolve_mjs() {
  local marketplace_glob="$HOME/.claude/plugins/cache/strigov-cc-plugins/superpowers-strigov-ver/*/bin/lib/zcode-dispatch.mjs"
  local path
  for path in $(ls -1d $marketplace_glob 2>/dev/null | sort -rV); do
    if [ -f "$path" ]; then echo "$path"; return; fi
  done

  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$self_dir/lib/zcode-dispatch.mjs" ]; then echo "$self_dir/lib/zcode-dispatch.mjs"; return; fi

  echo ""
}

MJS="$(resolve_mjs)"
if [ -z "$MJS" ]; then
  echo "zcode-dispatch: cannot find bin/lib/zcode-dispatch.mjs" >&2
  echo "  searched: ~/.claude/plugins/cache/strigov-cc-plugins/superpowers-strigov-ver/*/bin/lib/... and \$(dirname zcode-dispatch)/lib/..." >&2
  exit 1
fi

export ZCODE_STATE_DIR="${ZCODE_STATE_DIR:-$HOME/.claude/plugins/data/superpowers-strigov-ver-zcode}"

exec node "$MJS" "$@"
```

- [ ] **Step 5: Write the wrapper**

`bin/lib/zcode-dispatch.mjs` — the constants block carries the spec's initial values; Step 8 replaces them with Ф1's findings:

```js
// zcode-dispatch.mjs — background-job wrapper around Z.ai's official ZCode CLI
// (the Agent CLI embedded in /Applications/ZCode.app), shaped like the vendored
// Codex companion: task / status / result / cancel / doctor.
//
// Pure Node ESM, no dependencies, no shell: every child process is spawned with
// an argv array. Never reads or writes ~/.zcode, never sets ZCODE_DATA_BASE_DIR,
// never calls the Z.ai API itself — the ZCode CLI is the only channel. The model pin
// travels in the wrapper's own personal provider config under the state root
// (ZCODE_PERSONAL_PROVIDER_CONFIG_FILE); the CLI login is the user's `zcode login zai`.
//
// Usage: zcode-dispatch <task|status|result|cancel|doctor> [args...]
// Exit codes: 0 success · 1 runtime failure · 2 usage error or guard refusal.

import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

// ---- Values copied from docs/zcode-cli-findings.md "## Inputs for later phases" ----
export const PINNED_MODEL = "GLM-5.3-Flash$max";
export const VERIFIED_APP_VERSION = "3.15.1";
export const VERIFIED_NODE_MAJOR = 26;
export const PROMPT_TRANSPORT = "argv"; // "argv" | "stdin"
export const MAX_PROMPT_BYTES = 200 * 1024;
export const APP_VERSION_PLIST_KEY = "CFBundleShortVersionString";
export const MODEL_ARGS = []; // MODEL_MECHANISM flag:<--name> → ["<--name>", PINNED_MODEL]
export const MODEL_ENV = {}; // MODEL_MECHANISM env:<NAME> → { "<NAME>": PINNED_MODEL }
// MODEL_MECHANISM personal-config: the selection written at SELECTION_PATH of the wrapper-owned
// personal provider config before every run; PERSONAL_CONFIG_BASE seeds a missing file.
export const SELECTION_PATH = "config.defaultModelSelection";
export const PERSONAL_CONFIG_BASE = { schemaVersion: 1, config: { providerConfigRules: { providerRules: [] }, modelConfigRules: {} } };
export const PINNED_SELECTION = { providerId: "account:zai-individual-coding-plan", modelId: "GLM-5.3-Flash", options: { reasoningLevel: "max" } };
export const DISALLOWED_TOOLS = []; // DISALLOWED_TOOLS list → one --disallowedTools a,b,c
export const REPORTED_MODEL_PATH = null; // REPORTED_MODEL_FIELD dot path; null = not exposed
export const USAGE_FIELDS = { input: "inputTokens", cached: "cacheReadTokens", output: "outputTokens" };
export const PATTERNS = {
  "model-not-selected": ["Select a model before continuing", "Model creation failed"],
  auth: ["401", "unauthorized", "not logged in", "login", "token expired", "credential"],
  quota: ["429", "quota", "rate limit", "usage limit", "insufficient", "balance"],
  launch: ["ZCODE_BUILTIN_PROVIDER", "provider config", "Cannot find module"],
};
// --------------------------------------------------------------------------------------

const PROBE_PROMPT = "Reply with exactly one word: PONG";
const PROBE_TIMEOUT_MS = 120_000;
const TIMEOUT_KILL_GRACE_MS = 10_000;
const CANCEL_GRACE_MS = 5_000;
const CLOSE_WAIT_MS = 5_000;
const STARTUP_GRACE_MS = 60_000;
const DEFAULT_TIMEOUT_MIN = 60;
const ID_RE = /^zt-\d{4,}$/;
const TERMINAL = new Set(["completed", "failed", "cancelled"]);
const SELF = fileURLToPath(import.meta.url);

class UsageError extends Error {}

// ---------- environment and paths ----------

function zcodePaths(env = process.env) {
  const app = env.ZCODE_APP || "/Applications/ZCode.app";
  return {
    app,
    plist: path.join(app, "Contents", "Info.plist"),
    bin: env.ZCODE_BIN || path.join(app, "Contents", "Resources", "glm", "zcode.cjs"),
    providerConfig: path.join(app, "Contents", "Resources", "config", "provider", "zcode-builtin.json"),
    node: env.ZCODE_NODE || "node",
  };
}

function stateRoot(env = process.env) {
  return env.ZCODE_STATE_DIR || path.join(os.homedir(), ".claude", "plugins", "data", "superpowers-strigov-ver-zcode");
}

const personalConfigFile = (env = process.env) => path.join(stateRoot(env), "personal-provider-config.json");

function readAppVersion(plist) {
  const r = spawnSync("plutil", ["-extract", APP_VERSION_PLIST_KEY, "raw", "-o", "-", plist], { encoding: "utf8" });
  if (r.error || r.status !== 0) return null;
  const version = r.stdout.trim();
  return version.length > 0 ? version : null;
}

function resolveWorkspace(cwd) {
  const r = spawnSync("git", ["rev-parse", "--show-toplevel"], { cwd, encoding: "utf8" });
  if (r.error || r.status !== 0) return null;
  const root = r.stdout.trim();
  if (!root) return null;
  const slug = `${path.basename(root)}-${createHash("sha1").update(root).digest("hex").slice(0, 8)}`;
  return { root, jobsDir: path.join(stateRoot(), "state", slug, "jobs") };
}

function requireWorkspace(cwdOption) {
  const cwd = path.resolve(cwdOption ?? process.cwd());
  const ws = resolveWorkspace(cwd);
  if (!ws) throw new UsageError(`not inside a git work tree: ${cwd}`);
  return ws;
}

function readTimeoutMin(env = process.env) {
  const raw = env.ZCODE_TASK_TIMEOUT_MIN;
  if (raw === undefined || raw === "") return DEFAULT_TIMEOUT_MIN;
  const value = Number(raw);
  if (!/^\d+(\.\d+)?$/.test(raw.trim()) || !(value > 0)) {
    throw new UsageError(`ZCODE_TASK_TIMEOUT_MIN must be a positive number of minutes, got "${raw}"`);
  }
  return value;
}

// ---------- job records ----------

const jobFile = (jobsDir, id) => path.join(jobsDir, `${id}.json`);
const logFile = (jobsDir, id) => path.join(jobsDir, `${id}.log`);
const formatId = (n) => `zt-${String(n).padStart(4, "0")}`;
const idNumber = (id) => Number(id.slice(3));

// The terminal record is claimed once, in a sibling file created atomically and
// exclusively (link(2) fails with EEXIST when it already exists): the first
// finalizer wins, and every reader prefers that file over the main record, so a
// writer holding a stale `running` copy can never undo a terminal status.
const terminalFile = (file) => `${file}.terminal`;
let tmpSeq = 0;
const tmpFile = (file) => `${file}.tmp-${process.pid}-${++tmpSeq}`;

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

export function readRecord(file) {
  return readJson(terminalFile(file)) ?? readJson(file);
}

function writeRecord(file, record) {
  const tmp = tmpFile(file);
  fs.writeFileSync(tmp, `${JSON.stringify(record, null, 2)}\n`);
  fs.renameSync(tmp, file);
}

// Terminal statuses are sticky: a completed / failed / cancelled record is never rewritten,
// also when two finalizers (cancel and the runner) race — exactly one claim succeeds.
export function finalizeRecord(file, patch) {
  const current = readRecord(file);
  if (!current || TERMINAL.has(current.status)) return current;
  const next = { ...current, ...patch, finishedAt: new Date().toISOString() };
  const tmp = tmpFile(file);
  fs.writeFileSync(tmp, `${JSON.stringify(next, null, 2)}\n`);
  try {
    fs.linkSync(tmp, terminalFile(file));
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
    return readRecord(file); // another finalizer won: its terminal record stands
  } finally {
    fs.rmSync(tmp, { force: true });
  }
  writeRecord(file, next); // mirror into the main record (readers already see the claim)
  return next;
}

// Returns null when the job is (or meanwhile became) terminal: a terminal claim that
// landed after our read wins even if our stale rename replaced the main record.
function updateRunning(file, patch) {
  const current = readRecord(file);
  if (!current || current.status !== "running") return null;
  const next = { ...current, ...patch };
  writeRecord(file, next);
  return fs.existsSync(terminalFile(file)) ? null : next;
}

// The wrapper-owned personal provider config (ZCODE_PERSONAL_PROVIDER_CONFIG_FILE). Before every CLI
// run the default selection at SELECTION_PATH is set to PINNED_SELECTION; everything else in the file
// (e.g. what the user's one-time `zcode login zai` wrote there) is kept, and a missing or unreadable
// file starts from PERSONAL_CONFIG_BASE. It lives under the state root, never under ~/.zcode, and
// holds no credentials.
export function pinPersonalConfig(file) {
  const current = readJson(file);
  const config = current && typeof current === "object" && !Array.isArray(current) ? current : structuredClone(PERSONAL_CONFIG_BASE);
  const keys = SELECTION_PATH.split(".");
  let node = config;
  for (const key of keys.slice(0, -1)) {
    if (!node[key] || typeof node[key] !== "object" || Array.isArray(node[key])) node[key] = {};
    node = node[key];
  }
  node[keys.at(-1)] = structuredClone(PINNED_SELECTION);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  writeRecord(file, config); // atomic rename
  return config;
}

function listRecords(jobsDir) {
  let names = [];
  try {
    names = fs.readdirSync(jobsDir);
  } catch {
    return [];
  }
  return names
    .filter((name) => /^zt-\d+\.json$/.test(name))
    .map((name) => readRecord(path.join(jobsDir, name)))
    .filter(Boolean)
    .sort((a, b) => idNumber(b.id) - idNumber(a.id));
}

function allocateRecord(jobsDir, fields) {
  fs.mkdirSync(jobsDir, { recursive: true });
  const used = fs
    .readdirSync(jobsDir)
    .map((name) => /^zt-(\d+)\.json$/.exec(name))
    .filter(Boolean)
    .map((match) => Number(match[1]));
  let n = 1 + Math.max(0, ...used);
  for (;;) {
    const id = formatId(n);
    try {
      fs.writeFileSync(jobFile(jobsDir, id), `${JSON.stringify({ id, ...fields }, null, 2)}\n`, { flag: "wx" });
      return id;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      n += 1;
    }
  }
}

function requireJob(jobsDir, ref) {
  if (!ID_RE.test(ref)) throw new UsageError(`${ref} is not a zcode-dispatch job id (zt-NNNN); Codex task- ids belong to codex-dispatch`);
  const record = readRecord(jobFile(jobsDir, ref));
  if (!record) throw new UsageError(`unknown job ${ref} in this workspace (pass the same --cwd as the original task)`);
  return record;
}

function appendLog(file, line) {
  try {
    fs.appendFileSync(file, `[zcode-dispatch] ${new Date().toISOString()} ${line}\n`);
  } catch {
    // the log is best effort
  }
}

function tailLines(file, n) {
  try {
    const lines = fs.readFileSync(file, "utf8").split("\n");
    if (lines.at(-1) === "") lines.pop();
    return lines.slice(-n).map((line) => `${line}\n`).join("");
  } catch {
    return "";
  }
}

// ---------- processes ----------

function isAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === "EPERM";
  }
}

function groupAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(-pid, 0);
    return true;
  } catch (error) {
    return error.code === "EPERM";
  }
}

function killGroup(pid, signal) {
  if (!Number.isInteger(pid) || pid <= 0) return;
  try {
    process.kill(-pid, signal);
  } catch {
    // group already gone
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Liveness check: no record is ever left `running` with a dead runner.
function reapDeadRunners(jobsDir) {
  for (const record of listRecords(jobsDir)) {
    if (record.status !== "running") continue;
    const file = jobFile(jobsDir, record.id);
    if (record.runnerPid == null) {
      if (Date.now() - Date.parse(record.startedAt) > STARTUP_GRACE_MS) {
        finalizeRecord(file, { status: "failed", errorClass: "crash", note: "runner never started" });
      }
      continue;
    }
    if (isAlive(record.runnerPid)) continue;
    killGroup(record.childPid, "SIGKILL");
    const after = finalizeRecord(file, { status: "failed", errorClass: "crash", note: "runner died" });
    if (after?.note === "runner died") appendLog(logFile(jobsDir, record.id), "runner died; liveness check marked the job failed/crash");
  }
}

// ---------- the ZCode CLI invocation ----------

export function buildCliArgv({ bin, prompt, workspaceRoot, sessionId }) {
  const argv = [
    bin,
    "-p",
    PROMPT_TRANSPORT === "stdin" ? "-" : prompt,
    "--output-format",
    "json",
    "--mode",
    "yolo",
    "--surface",
    "terminal",
    "--workflow-mode",
    "disabled",
    "--cwd",
    workspaceRoot,
    ...MODEL_ARGS,
  ];
  if (DISALLOWED_TOOLS.length > 0) argv.push("--disallowedTools", DISALLOWED_TOOLS.join(","));
  if (sessionId) argv.push("--resume", sessionId);
  return argv;
}

function buildCliEnv(paths, appVersion) {
  return {
    ...process.env,
    ...MODEL_ENV,
    ZCODE_BUILTIN_PROVIDER_CONFIG_FILE: paths.providerConfig,
    ZCODE_BUILTIN_PROVIDER_BUNDLED_CONFIG_FILE: paths.providerConfig,
    ZCODE_APP_VERSION: appVersion,
    ZCODE_PERSONAL_PROVIDER_CONFIG_FILE: personalConfigFile(),
  };
}

function summarizeArgv(argv) {
  return argv
    .map((arg, i) => (i > 0 && argv[i - 1] === "-p" && arg !== "-" ? `<prompt ${Buffer.byteLength(arg)} bytes>` : JSON.stringify(arg)))
    .join(" ");
}

// Runs the CLI as its own process group; resolves once it has exited and its output is drained.
function runCli({ node, argv, cwd, env, stdinText, timeoutMs, logPath, onSpawn }) {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let spawnError = null;
    let exitCode = null;
    let signal = null;
    let settled = false;
    let timer = null;
    let killTimer = null;
    let closeTimer = null;
    let child = null;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      clearTimeout(killTimer);
      clearTimeout(closeTimer);
      if (timedOut && child?.pid) killGroup(child.pid, "SIGKILL");
      resolve({ timedOut, spawnError, exitCode, signal, stdout, stderrTail: stderr.split("\n").slice(-200).join("\n") });
    };
    try {
      child = spawn(node, argv, { cwd, env, detached: true, stdio: [stdinText === null ? "ignore" : "pipe", "pipe", "pipe"] });
    } catch (error) {
      spawnError = error;
      finish();
      return;
    }
    child.on("error", (error) => {
      spawnError = error;
      finish();
    });
    if (child.pid) onSpawn?.(child.pid);
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      const text = chunk.toString();
      stderr = (stderr + text).slice(-262144);
      if (logPath) {
        try {
          fs.appendFileSync(logPath, text);
        } catch {
          // the log is best effort
        }
      }
    });
    if (stdinText !== null) {
      child.stdin.on("error", () => {});
      child.stdin.end(stdinText);
    }
    timer = setTimeout(() => {
      timedOut = true;
      if (logPath) appendLog(logPath, `timeout after ${timeoutMs} ms: SIGTERM to process group ${child.pid}`);
      killGroup(child.pid, "SIGTERM");
      killTimer = setTimeout(() => killGroup(child.pid, "SIGKILL"), TIMEOUT_KILL_GRACE_MS);
    }, timeoutMs);
    child.on("exit", (code, sig) => {
      exitCode = code;
      signal = sig;
      closeTimer = setTimeout(finish, CLOSE_WAIT_MS);
    });
    child.on("close", (code, sig) => {
      if (exitCode === null && signal === null) {
        exitCode = code;
        signal = sig;
      }
      finish();
    });
  });
}

export function parseCliOutput(stdout) {
  try {
    const value = JSON.parse(stdout.trim());
    if (value && typeof value === "object" && !Array.isArray(value) && typeof value.response === "string") return value;
  } catch {
    // not JSON
  }
  return null;
}

// First match wins: timeout, launch (spawn error), then the pattern lists, then crash.
// ZCode ends every error with " (traceId: <uuid>)" (findings U4); strip it before matching,
// because a uuid can contain digit runs such as 401 or 429.
export function classifyFailure({ timedOut, spawnError, stdout, stderrTail }) {
  if (timedOut) return "timeout";
  if (spawnError) return "launch";
  const haystack = `${stderrTail}\n${stdout}`.replace(/\s*\(traceId:[^)]*\)/gi, "").toLowerCase();
  for (const errorClass of ["model-not-selected", "auth", "quota", "launch"]) {
    if (PATTERNS[errorClass].some((pattern) => haystack.includes(pattern.toLowerCase()))) return errorClass;
  }
  return "crash";
}

function evaluate(result) {
  if (!result.timedOut && !result.spawnError && result.exitCode === 0) {
    const json = parseCliOutput(result.stdout);
    return json ? { status: "completed", errorClass: null, json } : { status: "failed", errorClass: "malformed", json: null };
  }
  return { status: "failed", errorClass: classifyFailure(result), json: null };
}

const pick = (object, dotPath) => dotPath.split(".").reduce((acc, key) => (acc == null ? undefined : acc[key]), object);

function reportedModelOf(json) {
  if (!REPORTED_MODEL_PATH) return null;
  const value = pick(json, REPORTED_MODEL_PATH);
  return typeof value === "string" ? value : null;
}

function reportedMatchesPin(reported) {
  const [pinnedId, pinnedLevel] = PINNED_MODEL.split("$");
  const [id, level] = reported.slice(reported.lastIndexOf("/") + 1).split("$");
  return id === pinnedId && (level === undefined || level === pinnedLevel);
}

// ---------- verbs ----------

function parse(args, options, maxPositionals, minPositionals = 0) {
  let parsed;
  try {
    parsed = parseArgs({ args, options, allowPositionals: true, strict: true });
  } catch (error) {
    throw new UsageError(error.message);
  }
  const count = parsed.positionals.length;
  if (count > maxPositionals || count < minPositionals) throw new UsageError(`unexpected arguments: ${args.join(" ")}`);
  return parsed;
}

function checkPromptFile(value) {
  if (!value) throw new UsageError("task requires --prompt-file <file>");
  const file = path.resolve(value);
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    throw new UsageError(`prompt file not found or unreadable: ${file}`);
  }
  if (text.trim().length === 0) throw new UsageError(`prompt file is empty: ${file}`);
  const bytes = Buffer.byteLength(text);
  if (PROMPT_TRANSPORT === "argv" && bytes > MAX_PROMPT_BYTES) {
    throw new UsageError(`prompt file is ${bytes} bytes, above MAX_PROMPT_BYTES=${MAX_PROMPT_BYTES} for the argv transport`);
  }
  return file;
}

function resolveResume(jobsDir, ref) {
  if (!ID_RE.test(ref)) throw new UsageError(`${ref} is not a zcode-dispatch job id (zt-NNNN); Codex task- ids belong to codex-dispatch`);
  const record = readRecord(jobFile(jobsDir, ref));
  if (!record) throw new UsageError(`unknown job ${ref} in this workspace (pass the same --cwd as the original task)`);
  if (record.status === "running") throw new UsageError(`job ${ref} is still running; wait for it to finish`);
  if (record.status !== "completed" || !record.sessionId) throw new UsageError(`job ${ref} is ${record.status} / has no session; dispatch --fresh`);
  return { resumeOf: ref, sessionId: record.sessionId };
}

async function cmdTask(args) {
  const { values } = parse(
    args,
    {
      background: { type: "boolean" },
      cwd: { type: "string" },
      "resume-task": { type: "string" },
      fresh: { type: "boolean" },
      "prompt-file": { type: "string" },
    },
    0,
  );
  if (!values.background) throw new UsageError("task requires --background (there is no foreground mode)");
  if (values["resume-task"] !== undefined && values.fresh) throw new UsageError("--resume-task and --fresh are mutually exclusive");
  if (process.env.SP_IMPLEMENTER === "luna") throw new UsageError("SP_IMPLEMENTER=luna is set: the GLM channel is switched off (kill switch)");
  const ws = requireWorkspace(values.cwd);
  reapDeadRunners(ws.jobsDir);
  const promptFile = checkPromptFile(values["prompt-file"]);
  const paths = zcodePaths();
  const appVersion = readAppVersion(paths.plist);
  if (!appVersion) throw new UsageError(`cannot read ${APP_VERSION_PLIST_KEY} from ${paths.plist}; refusing to run with an unknown client version`);
  if (!fs.existsSync(paths.bin)) throw new UsageError(`ZCode CLI not found: ${paths.bin}`);
  if (!fs.existsSync(paths.providerConfig)) throw new UsageError(`ZCode provider config not found: ${paths.providerConfig}`);
  const resume = values["resume-task"] !== undefined ? resolveResume(ws.jobsDir, values["resume-task"]) : { resumeOf: null, sessionId: null };
  const running = listRecords(ws.jobsDir).find((record) => record.status === "running");
  if (running) throw new UsageError(`job ${running.id} is still running in this workspace; one write task per working tree`);
  const timeoutMin = readTimeoutMin();

  const id = allocateRecord(ws.jobsDir, {
    status: "running",
    errorClass: null,
    sessionId: resume.sessionId,
    resumeOf: resume.resumeOf,
    workspaceRoot: ws.root,
    promptFile,
    model: PINNED_MODEL,
    reportedModel: null,
    appVersion,
    runnerPid: null,
    childPid: null,
    startedAt: new Date().toISOString(),
    finishedAt: null,
    exitCode: null,
    signal: null,
    timeoutMin,
    response: null,
    usage: null,
    note: null,
  });
  const logFd = fs.openSync(logFile(ws.jobsDir, id), "a");
  const runner = spawn(process.execPath, [SELF, "__run", id, ws.jobsDir], {
    cwd: ws.root,
    detached: true,
    stdio: ["ignore", logFd, logFd],
    env: process.env,
  });
  fs.closeSync(logFd);
  if (!runner.pid) {
    finalizeRecord(jobFile(ws.jobsDir, id), { status: "failed", errorClass: "launch", note: "runner failed to start" });
    throw new Error(`failed to start the runner for ${id}`);
  }
  runner.unref();
  process.stdout.write(`ZCode Task started in the background as ${id}\n`);
  return 0;
}

async function runJob(id, jobsDir) {
  if (!ID_RE.test(id ?? "") || !jobsDir) throw new UsageError("usage: zcode-dispatch __run <zt-id> <jobs-dir> (internal)");
  const file = jobFile(jobsDir, id);
  const log = logFile(jobsDir, id);
  const record = updateRunning(file, { runnerPid: process.pid });
  if (!record) return 0; // cancelled (or otherwise terminal) before the runner started
  let prompt;
  try {
    prompt = fs.readFileSync(record.promptFile, "utf8");
  } catch (error) {
    finalizeRecord(file, { status: "failed", errorClass: "launch", note: `cannot read prompt file: ${error.message}` });
    return 1;
  }
  try {
    pinPersonalConfig(personalConfigFile());
  } catch (error) {
    finalizeRecord(file, { status: "failed", errorClass: "launch", note: `cannot write the personal provider config: ${error.message}` });
    return 1;
  }
  const paths = zcodePaths();
  const argv = buildCliArgv({ bin: paths.bin, prompt, workspaceRoot: record.workspaceRoot, sessionId: record.resumeOf ? record.sessionId : null });
  appendLog(log, `start ${id}: ${JSON.stringify(paths.node)} ${summarizeArgv(argv)}`);
  const result = await runCli({
    node: paths.node,
    argv,
    cwd: record.workspaceRoot,
    env: buildCliEnv(paths, record.appVersion),
    stdinText: PROMPT_TRANSPORT === "stdin" ? prompt : null,
    timeoutMs: record.timeoutMin * 60_000,
    logPath: log,
    onSpawn: (pid) => {
      if (!updateRunning(file, { childPid: pid })) killGroup(pid, "SIGTERM"); // cancelled meanwhile
    },
  });
  const verdict = evaluate(result);
  const patch = { status: verdict.status, errorClass: verdict.errorClass, exitCode: result.exitCode, signal: result.signal };
  if (verdict.json) {
    patch.response = verdict.json.response;
    patch.usage = verdict.json.usage && typeof verdict.json.usage === "object" ? verdict.json.usage : null;
    patch.reportedModel = reportedModelOf(verdict.json);
    if (typeof verdict.json.sessionId === "string") patch.sessionId = verdict.json.sessionId;
  } else {
    const reason = result.spawnError ? `spawn error ${result.spawnError.code ?? result.spawnError.message}` : `exit=${result.exitCode} signal=${result.signal} timedOut=${result.timedOut}`;
    appendLog(log, `classified failed/${verdict.errorClass} (${reason})`);
    if (result.stdout.trim()) appendLog(log, `raw stdout:\n${result.stdout}`);
  }
  const final = finalizeRecord(file, patch);
  appendLog(log, `finish ${id}: ${final?.status}${final?.errorClass ? `/${final.errorClass}` : ""}`);
  return 0;
}

function statusLine(record) {
  const end = record.finishedAt ? Date.parse(record.finishedAt) : Date.now();
  const secs = Math.max(0, Math.round((end - Date.parse(record.startedAt)) / 1000));
  const state = record.status === "failed" ? `failed/${record.errorClass}` : record.status;
  const elapsed = `${Math.floor(secs / 60)}m${String(secs % 60).padStart(2, "0")}s`;
  return [record.id, state, elapsed, record.model, record.sessionId ?? "-", ...(record.resumeOf ? [`resumeOf=${record.resumeOf}`] : [])].join(" ");
}

function cmdStatus(args) {
  const { values, positionals } = parse(args, { cwd: { type: "string" }, all: { type: "boolean" }, json: { type: "boolean" } }, 1);
  const ws = requireWorkspace(values.cwd);
  reapDeadRunners(ws.jobsDir);
  if (positionals.length === 1) {
    const record = requireJob(ws.jobsDir, positionals[0]);
    process.stdout.write(values.json ? `${JSON.stringify({ job: record }, null, 2)}\n` : `${statusLine(record)}\n`);
    return 0;
  }
  const records = listRecords(ws.jobsDir);
  const running = records.filter((record) => record.status === "running");
  const terminal = records.filter((record) => record.status !== "running");
  const recent = values.all ? terminal : terminal.slice(0, 10);
  if (values.json) {
    process.stdout.write(`${JSON.stringify({ workspaceRoot: ws.root, running, recent }, null, 2)}\n`);
  } else {
    for (const record of [...running, ...recent]) process.stdout.write(`${statusLine(record)}\n`);
  }
  return 0;
}

function cmdResult(args) {
  const { values, positionals } = parse(args, { cwd: { type: "string" } }, 1, 1);
  const ws = requireWorkspace(values.cwd);
  reapDeadRunners(ws.jobsDir);
  const record = requireJob(ws.jobsDir, positionals[0]);
  if (record.status === "completed") {
    const text = record.response ?? "";
    process.stdout.write(text.endsWith("\n") ? text : `${text}\n`);
    return 0;
  }
  process.stderr.write(`job ${record.id} is ${record.status} errorClass=${record.errorClass}\n${tailLines(logFile(ws.jobsDir, record.id), 20)}`);
  return 1;
}

async function cmdCancel(args) {
  const { values, positionals } = parse(args, { cwd: { type: "string" } }, 1, 1);
  const ws = requireWorkspace(values.cwd);
  reapDeadRunners(ws.jobsDir);
  const record = requireJob(ws.jobsDir, positionals[0]);
  const file = jobFile(ws.jobsDir, record.id);
  // The cancelled record is written first, so a runner finishing meanwhile cannot overwrite it.
  const after = record.status === "running" ? finalizeRecord(file, { status: "cancelled", errorClass: null, note: "cancelled by zcode-dispatch cancel" }) : record;
  if (after.status !== "cancelled" || record.status !== "running") {
    process.stdout.write(`${record.id} is ${after.status}\n`);
    return 0;
  }
  appendLog(logFile(ws.jobsDir, record.id), "cancel: record set to cancelled; SIGTERM to the CLI process group");
  killGroup(after.childPid, "SIGTERM");
  const deadline = Date.now() + CANCEL_GRACE_MS;
  while (groupAlive(after.childPid) && Date.now() < deadline) await sleep(200);
  if (groupAlive(after.childPid)) killGroup(after.childPid, "SIGKILL");
  if (isAlive(after.runnerPid)) {
    try {
      process.kill(after.runnerPid, "SIGTERM");
    } catch {
      // runner already gone
    }
  }
  process.stdout.write(`cancelled ${record.id}\n`);
  return 0;
}

async function cmdDoctor(args) {
  const { values } = parse(args, { cwd: { type: "string" }, probe: { type: "boolean" } }, 0);
  const cwd = path.resolve(values.cwd ?? process.cwd());
  const paths = zcodePaths();
  const lines = [];
  let failed = false;
  const report = (level, check, detail) => {
    lines.push(`${level} ${check}: ${detail}`);
    if (level === "FAIL") failed = true;
  };

  const appVersion = readAppVersion(paths.plist);
  if (appVersion) report("ok", "app", `${paths.app} ${appVersion}`);
  else report("FAIL", "app", `cannot read ${APP_VERSION_PLIST_KEY} from ${paths.plist}`);
  if (fs.existsSync(paths.bin)) report("ok", "cli", paths.bin);
  else report("FAIL", "cli", `not found: ${paths.bin}`);
  if (fs.existsSync(paths.providerConfig)) report("ok", "provider-config", paths.providerConfig);
  else report("FAIL", "provider-config", `not found: ${paths.providerConfig}`);
  const nodeRun = spawnSync(paths.node, ["--version"], { encoding: "utf8" });
  if (nodeRun.error || nodeRun.status !== 0) {
    report("FAIL", "node", `cannot run ${paths.node} --version`);
  } else {
    const version = nodeRun.stdout.trim();
    const major = Number(/^v(\d+)/.exec(version)?.[1] ?? 0);
    if (major >= VERIFIED_NODE_MAJOR) report("ok", "node", version);
    else report("WARN", "node", `${version} is below the verified major ${VERIFIED_NODE_MAJOR}`);
  }
  if (!appVersion) report("WARN", "app-version", "unknown (app check failed)");
  else if (appVersion !== VERIFIED_APP_VERSION) report("WARN", "app-version", `installed ${appVersion} differs from verified ${VERIFIED_APP_VERSION}; re-run the live acceptance`);
  else report("ok", "app-version", appVersion);
  const ws = resolveWorkspace(cwd);
  if (ws) report("ok", "git", ws.root);
  else report("FAIL", "git", `not inside a git work tree: ${cwd}`);
  try {
    fs.mkdirSync(stateRoot(), { recursive: true });
    fs.accessSync(stateRoot(), fs.constants.W_OK);
    report("ok", "state-dir", stateRoot());
  } catch (error) {
    report("FAIL", "state-dir", `${stateRoot()} is not writable: ${error.message}`);
  }
  try {
    pinPersonalConfig(personalConfigFile());
    const selection = pick(readJson(personalConfigFile()) ?? {}, SELECTION_PATH);
    if (JSON.stringify(selection) === JSON.stringify(PINNED_SELECTION)) report("ok", "personal-config", `${personalConfigFile()} pins ${PINNED_MODEL}`);
    else report("FAIL", "personal-config", `${personalConfigFile()}: ${SELECTION_PATH} does not hold PINNED_SELECTION after pinning`);
  } catch (error) {
    report("FAIL", "personal-config", `cannot write ${personalConfigFile()}: ${error.message}`);
  }
  if (process.env.SP_IMPLEMENTER === "luna") report("WARN", "kill-switch", "SP_IMPLEMENTER=luna is set; task will refuse");
  else report("ok", "kill-switch", "SP_IMPLEMENTER is not luna");

  process.stdout.write(`${lines.join("\n")}\ndoctor: ${failed ? "FAIL" : "ok"}\n`);
  if (failed) return 1;
  if (!values.probe) return 0;
  return await runProbe(paths, appVersion, ws.root);
}

// One synchronous PONG request: the only diagnostic that spends quota.
async function runProbe(paths, appVersion, root) {
  pinPersonalConfig(personalConfigFile());
  const argv = buildCliArgv({ bin: paths.bin, prompt: PROBE_PROMPT, workspaceRoot: root, sessionId: null });
  const result = await runCli({
    node: paths.node,
    argv,
    cwd: root,
    env: buildCliEnv(paths, appVersion),
    stdinText: PROMPT_TRANSPORT === "stdin" ? PROBE_PROMPT : null,
    timeoutMs: PROBE_TIMEOUT_MS,
    logPath: null,
  });
  const verdict = evaluate(result);
  const json = verdict.json;
  const modelSelected = verdict.status === "completed";
  const answers = modelSelected && json.response.includes("PONG");
  const reported = json ? reportedModelOf(json) : null;
  const modelMatches = reported === null || reportedMatchesPin(reported);
  const usage = json?.usage ?? {};
  const count = (field) => {
    const value = field ? pick(usage, field) : undefined;
    return typeof value === "number" ? String(value) : "-";
  };
  const ok = modelSelected && answers && modelMatches;
  process.stdout.write(
    [
      `model-selected: ${modelSelected ? "ok" : `FAIL(${verdict.errorClass})`}`,
      `answers: ${answers ? "ok" : "FAIL"}`,
      `reported-model: ${reported ?? "unreported"}`,
      `usage: input=${count(USAGE_FIELDS.input)} cached=${count(USAGE_FIELDS.cached)} output=${count(USAGE_FIELDS.output)}`,
      `probe: ${ok ? "ok" : "FAIL"}`,
    ].join("\n") + "\n",
  );
  if (!modelSelected && result.stderrTail.trim()) process.stderr.write(`${result.stderrTail.split("\n").slice(-20).join("\n")}\n`);
  return ok ? 0 : 1;
}

export async function main(argv) {
  const [verb, ...rest] = argv;
  try {
    switch (verb) {
      case "task":
        return await cmdTask(rest);
      case "status":
        return cmdStatus(rest);
      case "result":
        return cmdResult(rest);
      case "cancel":
        return await cmdCancel(rest);
      case "doctor":
        return await cmdDoctor(rest);
      case "__run":
        return await runJob(rest[0], rest[1]);
      default:
        throw new UsageError(`usage: zcode-dispatch <task|status|result|cancel|doctor> [args...]${verb ? ` (unknown verb: ${verb})` : ""}`);
    }
  } catch (error) {
    process.stderr.write(`zcode-dispatch: ${error.message}\n`);
    return error instanceof UsageError ? 2 : 1;
  }
}

const invokedDirectly = (() => {
  try {
    return Boolean(process.argv[1]) && fs.realpathSync(process.argv[1]) === fs.realpathSync(SELF);
  } catch {
    return false;
  }
})();
if (invokedDirectly) process.exitCode = await main(process.argv.slice(2));
```

- [ ] **Step 6: Run the suite to verify it passes**

Run: `bash tests/test-zcode-dispatch.sh`
Expected: every line `[PASS] …` (the as-built suite's assertion count (see the Ф2 report), including the tests added by the fix rounds for F1-B1-Ф2 / F1-B2-Ф2 / F2-B1-Ф2 / F3-B1-Ф2 / F4-B1-Ф2), last line `PASS`, exit 0, about 20 s. No `zcode-stub.cjs` process survives (`pgrep -f zcode-stub.cjs` prints nothing).

- [ ] **Step 7: Run the existing suite (regression)**

Run: `bash tests/test-sdd-scripts.sh`
Expected: last line `PASS`.

- [ ] **Step 8: Apply the discovery findings to the constants block**

Open `docs/zcode-cli-findings.md` → `## Inputs for later phases` and edit only the constants block at the top of `bin/lib/zcode-dispatch.mjs`, row by row:

| Findings key = value | Edit |
|---|---|
| `PROMPT_TRANSPORT` = `argv` / `stdin` | `export const PROMPT_TRANSPORT = "argv";` / `= "stdin";` |
| `MAX_PROMPT_BYTES` = `<n>` | `export const MAX_PROMPT_BYTES = <n>;` (keep `200 * 1024` when the value is `204800`) |
| `VERIFIED_APP_VERSION` = `<v>` | `export const VERIFIED_APP_VERSION = "<v>";` |
| `VERIFIED_NODE_MAJOR` = `<n>` | `export const VERIFIED_NODE_MAJOR = <n>;` |
| `APP_VERSION_PLIST_KEY` = `<key>` | `export const APP_VERSION_PLIST_KEY = "<key>";` |
| `MODEL_MECHANISM` = `personal-config` | leave `MODEL_ARGS = []` and `MODEL_ENV = {}`; apply the next three rows |
| `SELECTION_PATH` = `<path>` | `export const SELECTION_PATH = "<path>";` |
| `PERSONAL_CONFIG_BASE` = `<json>` | `export const PERSONAL_CONFIG_BASE = <json>;` (the JSON pasted unchanged as the object literal) |
| `PINNED_SELECTION` = `<json>` | `export const PINNED_SELECTION = <json>;` (the JSON pasted unchanged as the object literal) |
| `MODEL_MECHANISM` = `flag:<--name>` | `export const MODEL_ARGS = ["<--name>", PINNED_MODEL];` |
| `MODEL_MECHANISM` = `env:<NAME>` | `export const MODEL_ENV = { "<NAME>": PINNED_MODEL };` |
| `DISALLOWED_TOOLS` = `none` / `a,b` | leave `[]` / `export const DISALLOWED_TOOLS = ["a", "b"];` |
| `REPORTED_MODEL_FIELD` = `none` / `<path>` | leave `null` / `export const REPORTED_MODEL_PATH = "<path>";` |
| `USAGE_INPUT_FIELD`, `USAGE_CACHED_FIELD`, `USAGE_OUTPUT_FIELD` | the three values of `USAGE_FIELDS` (`input`, `cached`, `output`); a `none` becomes `null` |
| `PATTERN_MODEL_NOT_SELECTED`, `PATTERN_AUTH`, `PATTERN_QUOTA`, `PATTERN_LAUNCH` | the four `PATTERNS` arrays: split the value on `;`, trim each part, keep the order |

`PINNED_MODEL` stays `"GLM-5.3-Flash$max"`. Change nothing else in the file.

- [ ] **Step 9: Re-run both suites**

Run: `bash tests/test-zcode-dispatch.sh && bash tests/test-sdd-scripts.sh`
Expected: both end with `PASS` (the tests read the exported constants, so Step 8's values are exercised: transport, plist key, `MODEL_ARGS`, `DISALLOWED_TOOLS`, `SELECTION_PATH` / `PINNED_SELECTION`, first pattern of each class).

- [ ] **Step 10: Commit the phase**

```bash
git add bin/zcode-dispatch bin/lib/zcode-dispatch.mjs tests/test-zcode-dispatch.sh tests/fixtures/zcode-stub.cjs \
  tests/fixtures/FakeZCode.app/Contents/Info.plist \
  tests/fixtures/FakeZCode.app/Contents/Resources/config/provider/zcode-builtin.json
git commit -m "feat(zcode): add zcode-dispatch wrapper for the ZCode CLI with stubbed tests"
```

## Ф3: Protocol integration — dev-orchestrator, implementer prompt, `zcode-invocation`, `codex-invocation`

**Executor:** default non-frontend route (Codex implementer). Prose only; no model calls. Materiality: SECURITY (R9 — these rules keep risk-marked phases off the unsandboxed channel).

All edits below are exact find/replace pairs: **Find** text occurs exactly once in the named file; replace it with the **Replace with** text verbatim. Section names follow spec §5–§6.3.

**Files in this phase:**
- Create: `skills/zcode-invocation/SKILL.md`
- Modify: `skills/dev-orchestrator/SKILL.md`
- Modify: `skills/dev-orchestrator/implementer-prompt.md`
- Modify: `skills/codex-invocation/SKILL.md`
- Modify: `skills/dev-orchestrator/opus-review-prompt.md`
- Modify: `skills/dev-orchestrator/final-review-prompt.md`
- Modify: `skills/dev-orchestrator/codex-control-review-prompt.md`

**Interfaces:**
- Consumes: `docs/zcode-cli-findings.md` with sections `## Go / no-go` (line `VERDICT: GO` | `VERDICT: NO-GO — <reason>`), `## U1 — …` through `## U11 — …`, and `## Inputs for later phases` filled for every key of Contract C7 (`VERDICT`, `MODEL_MECHANISM`, `SELECTION_PATH`, `PERSONAL_CONFIG_BASE`, `PINNED_SELECTION`, `RESUME_KEEPS_MODEL`, `REPORTED_MODEL_FIELD`, `USAGE_INPUT_FIELD`, `USAGE_CACHED_FIELD`, `USAGE_OUTPUT_FIELD`, `USAGE_REASONING_FIELD`, `CACHED_IS_SUBSET_OF_INPUT`, `PROMPT_TRANSPORT`, `MAX_PROMPT_BYTES`, `VERIFIED_APP_VERSION`, `VERIFIED_NODE_MAJOR`, `APP_VERSION_PLIST_KEY`, `DISALLOWED_TOOLS`, `GLM_CONCURRENCY`, `SESSION_SAVED_ON_SIGTERM`, `INTERFERING_PLUGINS`, `PATTERN_MODEL_NOT_SELECTED`, `PATTERN_AUTH`, `PATTERN_QUOTA`, `PATTERN_LAUNCH`) — this phase reads `MODEL_MECHANISM`, `REPORTED_MODEL_FIELD`, `RESUME_KEEPS_MODEL`, `GLM_CONCURRENCY`; and `bin/zcode-dispatch` with the command surface of Contract C1 (verbs `task`, `status`, `result`, `cancel`, `release-stale`, `doctor`, `doctor --probe`; start line `ZCode Task started in the background as zt-NNNN`; exit codes 0/1/2), job records per Contract C2 under the layout of Contract C3, errorClass set `timeout | crash | model-not-selected | auth | quota | launch | malformed`.
- Produces: the protocol artifacts of Contract C8 (operations, body / dispatch / sidecar file names, session marker, state-line suffix, `risk_phases`, the `zcode-invocation` "Verified facts" lines including `- Quota bonus (1.5× in ZCode): not measured yet — live acceptance pending.`, gate-stall tokens); the skill `skills/zcode-invocation/SKILL.md` (name `zcode-invocation`); the ZCode preamble and channel-switch notice sections in `skills/dev-orchestrator/implementer-prompt.md`.

- [ ] **Step 1: Write the structural check and run it (fails)**

Run from the repo root:

```bash
S=skills/dev-orchestrator/SKILL.md; I=skills/dev-orchestrator/implementer-prompt.md
Z=skills/zcode-invocation/SKILL.md; C=skills/codex-invocation/SKILL.md; D=skills/dev-orchestrator
fails=0
need() { grep -qF -- "$2" "$1" 2>/dev/null || { echo "MISSING in $1: $2"; fails=$((fails+1)); }; }
none() { if grep -qF -- "$2" "$1" 2>/dev/null; then echo "STALE in $1: $2"; fails=$((fails+1)); fi; }
need $S '**Channel ladder**'
need $S '**Kill switch.**'
need $S '**Prompt files and the retry / channel-switch rule**'
need $S '**GLM resume disabled.**'
need $S '**GLM infrastructure failures**'
need $S '**Gate stall — every non-frontend channel (GLM, Luna, Sol):**'
need $S '**Review stall (GLM and Luna phases):**'
need $S '**Review stall on a phase already on Sol**'
need $S 'impl=<glm:zt-NNNN | luna:task-NNNN | sol:task-NNNN | claude | —> glm=<unprobed | ok | down | off>'
need $S 'risk_phases: { Ф1: [], Ф2: [], Ф3: [DATA_LOSS], Ф5: [SECURITY, DATA_LOSS] }'
need $S '**Compaction-safe guards**'
need $S '**Re-derivation after plan changes.**'
need $S '10. **GLM only:**'
need $S 'Gate-stall diagnosis (Step 3.5): `ENVIRONMENT` | `CODE` | `CONTEXT`'
need $S 'GLM is invoked via `zcode-dispatch --background`'
need $S '- **Extract tokens from `~/.zcode`'
need $S '- **Give GLM a SECURITY / DATA_LOSS phase**'
need $S '- **Run two write tasks in one working tree across both dispatchers**'
need $S '- **Switch implementer channels silently**'
need $S '- **Call `zcode -p` (or `node zcode.cjs`) bypassing the wrapper**'
need $S '- **Change ZCode settings, plugins or login on the user'
need $S '**Stale workspace reservation** — `"$ZDISPATCH" task` exits 2 with the stale message'
none $S 'Full protocol tasks → Codex implementer, Luna max'
none $S 'No other Codex write task currently running.'
none $S 'a single Codex Luna max FRESH task'
none $S 'Codex implementer (Luna max)'
need $I '## ZCode preamble (GLM dispatches only)'
need $I '## ZCode headless run — read this first'
need $I '## Channel-switch notice (retries and channel switches)'
need $I '## Previous attempt'
none $I '# Implementer Prompt (Codex Luna max)'
for h in '## What this is' '## Verified facts (from `docs/zcode-cli-findings.md`)' '## Working path' '## Flag reference' \
  '## Resume semantics' '## Parallel tasks and worktrees' '## Terminal status handling' '## Sandbox warning' \
  '## Compliance' '## Never do' '## Session paths (for debugging)'; do need $Z "$h"; done
need $Z 'name: zcode-invocation'
need $Z '| `release-stale [--cwd <path>]` | Frees a stale workspace reservation (holder runner gone)'
need $Z 'a stale workspace reservation whose holder runner is gone (the message contains `release-stale`'
need $Z '- Delete reservation files (`active.lock.*`) by hand while a job might run'
none $Z '⟨'
need $C 'see `zcode-invocation`'
need $C 'counted across both dispatchers'
none $D/final-review-prompt.md 'Luna-written code'
none $D/final-review-prompt.md 'a single Codex Luna max FRESH task'
none $D/opus-review-prompt.md '(Codex Luna)'
none $D/opus-review-prompt.md "Codex's self-report"
none $D/codex-control-review-prompt.md "(Codex Luna's)"
[ "$fails" -eq 0 ] && echo "ALL CHECKS PASSED" || echo "FAILED CHECKS: $fails"
```

Expected now: many `MISSING` / `STALE` lines, last line `FAILED CHECKS: <n>`.

- [ ] **Step 2: Create `skills/zcode-invocation/SKILL.md`**

Write this file verbatim:

````markdown
---
name: zcode-invocation
description: How to invoke GLM-5.3-Flash through Z.ai's ZCode CLI via the zcode-dispatch wrapper — background tasks + Monitor polling. Read this before the first GLM call in a session, including from dev-orchestrator.
---

# ZCode invocation (zcode-dispatch wrapper, background-only)

## What this is

ZCode is Z.ai's official coding-agent harness (`github.com/zai-org/ZCode`, Apache-2.0). `/Applications/ZCode.app` embeds its Agent CLI at `Contents/Resources/glm/zcode.cjs`; there is no `zcode` on `PATH`. This plugin drives that CLI headless through the `bin/zcode-dispatch` wrapper to run **GLM-5.3-Flash at reasoning effort `max`** — the dev-orchestrator default implementer for non-frontend phases — on the user's individual GLM Coding Plan. Codex Luna max is the fallback when this channel is down; Codex Sol 6.1 xhigh takes SECURITY / DATA_LOSS phases and reasoning escalations.

The plan's terms (docs.z.ai/devpack/usage-policy): the Coding Plan may be used only in officially supported tools; SDK-based access and unsupported tools lead to benefit restrictions; account sharing is prohibited; more than 3 violations → ban. Nothing official exists about headless or automated use of a supported tool, either way. Concurrency guidance: Lite = 1 project at a time, Pro = 1–2, Max = 2+.

> **Read before the first GLM dispatch.** GLM runs **unsandboxed**, as your user account, in ZCode's `yolo` mode — see "Sandbox warning". The plugin stays inside the official ZCode CLI with truthful client identification and never touches credentials or the API — see "Compliance". If either is not acceptable for a repository, set `SP_IMPLEMENTER=luna`.

## Verified facts (from `docs/zcode-cli-findings.md`)

- Model selection: ⟨MODEL_SELECTION⟩
- Model confirmation: ⟨MODEL_CONFIRMATION⟩
- GLM resume: ⟨GLM_RESUME⟩
- GLM concurrency: ⟨GLM_CONCURRENCY⟩
- Quota bonus (1.5× in ZCode): not measured yet — live acceptance pending.

dev-orchestrator reads these lines: `Model selection: wrapper` → the wrapper pins GLM-5.3-Flash at `max` in its own personal provider config before every run, and the user's only setup step is the one-time CLI login ("One-time setup"); `Model confirmation: required` → one user confirmation per session, before the first GLM dispatch, that ZCode runs GLM-5.3-Flash with reasoning `max`; `GLM resume: disabled` → every GLM follow-up is a FRESH dispatch (dev-orchestrator Step 3); `GLM concurrency: 1` → at most one GLM track per parallel group.

## Working path

### 1. Resolve the wrapper once per session

```bash
ZDISPATCH="$(command -v zcode-dispatch || true)"
[ -z "$ZDISPATCH" ] && ZDISPATCH="$(ls -1d ~/.claude/plugins/cache/strigov-cc-plugins/superpowers-strigov-ver/*/bin/zcode-dispatch 2>/dev/null | sort -rV | head -1)"
[ -z "$ZDISPATCH" ] && ZDISPATCH="$(pwd)/bin/zcode-dispatch"
echo "ZDISPATCH=$ZDISPATCH"
```

Same idiom as `$DISPATCH` in `codex-invocation`: `command -v` when the marketplace install put `bin/` on `PATH`, the cache glob for a fresh session, `$(pwd)/bin/...` for local dev runs from the repo root.

### 2. One-time setup (user actions only — never run by the orchestrator)

1. Install ZCode.app into `/Applications`.
2. Log the **CLI** in once with Z.ai's own browser login (GLM Coding Plan account). The embedded CLI ships without its TUI, so there is no `/model` step. The user runs the line below; the `!` prefix makes it a user-shell command. It opens the browser; if the `!` prompt cannot host it, run the same line without `!` in a separate terminal window:

   ```
   ! mkdir -p ~/.claude/plugins/data/superpowers-strigov-ver-zcode && ZCODE_BUILTIN_PROVIDER_CONFIG_FILE=/Applications/ZCode.app/Contents/Resources/config/provider/zcode-builtin.json ZCODE_BUILTIN_PROVIDER_BUNDLED_CONFIG_FILE=/Applications/ZCode.app/Contents/Resources/config/provider/zcode-builtin.json ZCODE_APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - /Applications/ZCode.app/Contents/Info.plist)" ZCODE_PERSONAL_PROVIDER_CONFIG_FILE="$HOME/.claude/plugins/data/superpowers-strigov-ver-zcode/personal-provider-config.json" node /Applications/ZCode.app/Contents/Resources/glm/zcode.cjs login zai
   ```

   The login stores the CLI's identity in ZCode's own credential store; the wrapper never reads it. It also writes a default model into the wrapper's personal provider config named above, not into `~/.zcode/v2/provider_config.json`, so the desktop app's selection stays untouched. The model itself needs no user step: the wrapper pins GLM-5.3-Flash at `max` in that file before every run. One login per machine is enough; repeat it only when step 3 applies.
3. Login missing or expired: `doctor --probe` prints `model-selected: FAIL(model-not-selected)` or `FAIL(auth)`, and a task fails with the same `errorClass`. Then `glm=down` and Luna max for the rest of the session (dev-orchestrator channel ladder, unchanged). Tell the user to run step 2; never run it yourself.

Login and plugins belong to the user: the orchestrator asks, never does.

### 3. `doctor`, then `doctor --probe` — once per session

```bash
"$ZDISPATCH" doctor            # offline: app, cli, provider-config, node, app-version, git, state-dir, personal-config, kill-switch
"$ZDISPATCH" doctor --probe    # offline checks + ONE synchronous PONG request (spends a little quota)
```

`doctor` prints `ok | WARN | FAIL <check>: <detail>` per check, then `doctor: ok` or `doctor: FAIL` (exit 1 on any FAIL). `WARN app-version` means ZCode.app updated past the verified version — the CLI may have moved or changed flags; tell the user to re-run the live acceptance (`docs/zcode-cli-findings.md`). `doctor --probe` adds:

```
model-selected: ok | FAIL(<errorClass>)
answers: ok | FAIL
reported-model: <model string from the JSON> | unreported
usage: input=<n> cached=<n> output=<n>
probe: ok | FAIL
```

Exit 0 iff the model answered, the answer contains `PONG`, and `reported-model` is `unreported` or the pinned GLM-5.3-Flash. `model-selected: FAIL(model-not-selected)` or `FAIL(auth)` means the CLI login is missing or expired ("One-time setup", step 3). Any FAIL of either command means **Luna for the rest of the session** (dev-orchestrator sets `glm=down` and writes its session marker). After compaction the dev-orchestrator session marker (`<scratchpad>/dev-orchestrator/glm-channel`), not a new probe, restores the state.

### 4. Submit a task (ALWAYS `--background`, ALWAYS `--prompt-file`)

```bash
"$ZDISPATCH" task --background [--cwd <worktree-path>] [--resume-task zt-NNNN | --fresh] --prompt-file "$dir"/prompts/<op>-<phase>-r<N>.<seq>.glm.md
```

Expected output: `ZCode Task started in the background as zt-NNNN`. The dispatch file begins with the ZCode preamble (`dev-orchestrator/implementer-prompt.md`), so it never starts with `-` or `/` (the CLI would read those as an option or a slash command). There are no `--model` / `--effort` flags — the wrapper pins GLM-5.3-Flash at `max`.

### 5. Poll with terminal-only filter (via Monitor)

```bash
ZTASK=zt-XXXX
until
  st=$("$ZDISPATCH" status "$ZTASK" --json 2>/dev/null \
       | python3 -c "import json,sys; print(json.load(sys.stdin)['job']['status'])")
  case "$st" in
    completed|failed|cancelled) echo "zcode task terminal: $st"; true ;;
    *) false ;;
  esac
do
  sleep 25
done
```

Run this via the Monitor tool (add `--cwd <worktree-path>` to the `status` call for a worktree job). **The `case` guard is non-negotiable** — a monitor that prints every poll floods the chat and auto-stops.

### 6. Fetch the result

```bash
"$ZDISPATCH" result zt-XXXX
```

`completed` → the implementer's final message on stdout; machine-read line 1 for the status token. Any other status → exit 1 with `job zt-XXXX is <status> errorClass=<class>` and the log tail on stderr — see "Terminal status handling".

## Flag reference

Exit codes everywhere: **0** success · **1** runtime failure (failed job on `result`, failed checks on `doctor`, internal error) · **2** usage error or guard refusal.

| Verb | Behaviour |
|---|---|
| `task --background [--cwd <path>] [--resume-task zt-NNNN \| --fresh] --prompt-file <f>` | Starts a background job; prints `ZCode Task started in the background as zt-NNNN`. `--background` is mandatory (there is no foreground mode). `--resume-task` and `--fresh` are mutually exclusive; neither means `--fresh`. |
| `status [zt-NNNN] [--cwd <path>] [--all] [--json]` | With an id: `{"job":{…}}`. Without: `{"workspaceRoot":…,"running":[…],"recent":[…]}` — the 10 newest terminal jobs; `--all` lists every job. Text mode: one line per job. Runs the liveness check first. |
| `result zt-NNNN [--cwd <path>]` | `completed` → the stored response verbatim, exit 0; otherwise exit 1 with status, errorClass and the last 20 log lines on stderr. |
| `cancel zt-NNNN [--cwd <path>]` | Claims the sticky `cancelled` status, SIGTERM to the CLI's process group, 5 s grace, then SIGKILL to that group; does not signal the runner, which exits after the CLI exits and releases the workspace reservation; prints `cancelled zt-NNNN`. Already terminal → prints its status, exit 0. |
| `release-stale [--cwd <path>]` | Frees a stale workspace reservation (holder runner gone) — the only way one is freed; `task` never reclaims automatically. Refuses (exit 2, one-line reason on stderr) if the reservation is already released, the holder runner is alive, the job's CLI process group is alive, or the reservation changed while it checked; otherwise finalizes a non-terminal job as `failed` / `crash`, records the release and prints `released <workspace> generation <n>`, exit 0 (exit 1 on an I/O or internal error). Never signals, never deletes files. Single actor: run it once, never in parallel with any other dispatch for that workspace. |
| `doctor [--cwd <path>]` | Offline checks, no model call. |
| `doctor --probe [--cwd <path>]` | Offline checks, then ONE synchronous PONG request (120 s timeout). The only diagnostic that spends quota. |

Refusals (exit 2, nothing spawned): `--cwd` not inside a git work tree; missing or empty prompt file, or one larger than `MAX_PROMPT_BYTES` on the argv transport; `Info.plist` unreadable; `zcode.cjs` or the provider config missing; another job `running` in the same workspace, or a cancelled job whose CLI has not exited yet (the workspace stays reserved until it does); a stale workspace reservation whose holder runner is gone (the message contains `release-stale`; nothing is changed — see "Terminal status handling"); `SP_IMPLEMENTER=luna`; a bad `--resume-task` (see "Resume semantics"); unknown verbs or flags; an unknown id on `status` / `result` / `cancel`.

Pins (not configurable): `--output-format json`, `--mode yolo`, `--surface terminal`, `--workflow-mode disabled`, `--cwd <workspace root>`; never `--target`, `--json` or `-c/--continue`; `--disallowedTools` only for the tools `docs/zcode-cli-findings.md` (U6) confirmed, never as a substitute for the preamble. Environment = the inherited one plus `ZCODE_BUILTIN_PROVIDER_CONFIG_FILE` and `ZCODE_BUILTIN_PROVIDER_BUNDLED_CONFIG_FILE` (both the app's `zcode-builtin.json`) and `ZCODE_APP_VERSION` read from `Info.plist` at every task, plus `ZCODE_PERSONAL_PROVIDER_CONFIG_FILE` = the wrapper's own `personal-provider-config.json` under the state root, where the model pin is written before every run; `ZCODE_DATA_BASE_DIR` is never set.

Env overrides (tests and relocated installs only): `ZCODE_APP` (default `/Applications/ZCode.app`), `ZCODE_BIN` (default `$ZCODE_APP/Contents/Resources/glm/zcode.cjs`), `ZCODE_NODE` (default `node`), `ZCODE_STATE_DIR` (default `~/.claude/plugins/data/superpowers-strigov-ver-zcode`), `ZCODE_TASK_TIMEOUT_MIN` (default 60). Nothing else — no override for the model, the mode, the surface or the app version.

## Resume semantics

`--resume-task zt-NNNN` resolves that job's stored `sessionId` and passes `--resume <sess_…>` to the CLI — the fixer continues its own GLM session.

- The referenced job must be `completed` and carry a `sessionId`. A `running` reference is refused (`job zt-NNNN is still running; wait for it to finish`); a `failed` or `cancelled` one, or a completed one without a session, is refused (`job zt-NNNN is <status> / has no session; dispatch --fresh`).
- Any id of the same chain works: every resumed record stores the same `sessionId`.
- Ids are per workspace: pass the same `--cwd` as the original task.
- `zt-` ids and Codex `task-` ids never cross dispatchers; each wrapper rejects the other's prefix.
- When the wrapper refuses a resume, dispatch the same operation `--fresh` at the next seq, composed per dev-orchestrator Step 3 ("Prompt files and the retry / channel-switch rule") for its operation type — the fresh-fallback re-brief only on fix-type operations, never on `implement`.
- `GLM resume: disabled` under "Verified facts" → do not use `--resume-task` at all: every GLM follow-up is a FRESH dispatch of the same operation (the mapping stays in the wrapper, unused).

## Parallel tasks and worktrees

- One write task per working tree, across **both** dispatchers: the wrapper refuses a second running ZCode job in the same workspace; check `"$DISPATCH" status` as well before dispatching.
- Dispatch into a worktree with `--cwd <worktree-path>`; the workspace is `git rev-parse --show-toplevel` of that path, so each worktree has its own job list and id counter. `status` / `result` / `cancel` for that job must pass the same `--cwd`.
- **Width cap: max 2 concurrent write tasks, counted across both dispatchers.**
- GLM concurrency: see "Verified facts" — `1` means at most one GLM track per parallel group (only when the ladder resolved **both** tracks to GLM does the second one take Luna max for the group; Claude and Sol tracks are never changed by this rule).

## Terminal status handling

| Terminal state | Action |
|---|---|
| `completed` | `result`; parse line 1; malformed token → re-dispatch once with `--resume-task <zt-id>`, then the user |
| `failed` / `quota`, `auth`, `model-not-selected` | `glm=down` for the session (state line + marker); announce; the **same operation** on Luna max FRESH — next-seq `.luna` dispatch file in the FRESH composition for its operation type, unchanged body. On `auth` / `model-not-selected`, also tell the user the CLI login is likely missing ("One-time setup", step 2) |
| `failed` / `timeout`, `crash`, `launch`, `malformed` | one retry of the **same operation** on GLM: `--fresh`, next-seq `.glm` dispatch file in the FRESH composition, unchanged body; second failure → Luna as above (`glm=down` only if the second class is quota/auth/model-not-selected) |
| `cancelled` | report to the user, wait |
| `doctor --probe` FAIL (before any task) | `glm=down` (state line + marker); announce once; Luna for the session |
| wrapper exit 2 on `task` with the stale message (contains `release-stale`) | run `"$ZDISPATCH" release-stale` (same `--cwd` as the task) exactly once — single actor, never in parallel with any other dispatch for that workspace; prints `released …` → re-run the identical `task` command once (the refused call spawned nothing); `release-stale` refuses, or the re-run is refused again → infrastructure failure of the GLM channel: the same operation on Luna max FRESH as for `quota` above (announced; `glm=down` not set), and tell the user the workspace reservation is stuck, quoting the wrapper's message |
| wrapper exit 2 on `task` (any other guard) | not a job failure — fix the dispatch (wrong cwd, missing prompt file, another job running, kill switch); if the guard names `Info.plist`, `zcode.cjs` or the provider config → treat as `doctor` FAIL |

Read the class with `"$ZDISPATCH" status zt-XXXX --json | python3 -c "import json,sys; print(json.load(sys.stdin)['job']['errorClass'])"`. The job log (`~/.claude/plugins/data/superpowers-strigov-ver-zcode/state/<workspace-slug>/jobs/zt-XXXX.log`) holds the CLI's stderr and `[zcode-dispatch]` lines (argv summary without the prompt, timestamps, classification reason, raw stdout when it failed to parse). Unrecognised errors classify as `crash` — a retry and a Luna fallback, never a false success.

## Sandbox warning

> GLM runs **unsandboxed**, as your user account, in ZCode's `yolo` mode: it can read and write any file you can and reach the network. Codex's `--write` tasks are sandboxed to the workspace; GLM's are not. Mitigations in this plugin: the wrapper refuses to start outside a git work tree; every prompt begins with the ZCode preamble (no credentials, no paths outside the repo, no network beyond plan-mandated installs, no git history operations); phases carrying SECURITY or DATA_LOSS risk never go to GLM — they run on Codex Sol inside its sandbox. These are instructions to a model, not an enforcement boundary. If that is not acceptable for a repository, run it with `SP_IMPLEMENTER=luna`.

A real boundary — a permission broker over `zcode app-server` with `--mode guarded` — is future work.

## Compliance

The wrapper passes the real `ZCODE_APP_VERSION` from `Info.plist` and `--surface terminal`; it adds no headers, rewrites none, and never pretends to be the desktop app. Nothing reads `~/.zcode`. If Z.ai ever declares headless use of the CLI unsupported, the kill switch (`SP_IMPLEMENTER=luna`) turns the channel off without code changes.

Kill switch: within a session, the user's "через Luna" or "без GLM" turns GLM off until the session ends; permanently, `SP_IMPLEMENTER=luna` in the environment (the wrapper refuses `task` too). Nothing else.

## Never do

- Extract tokens from `~/.zcode`, read `credentials.json`, or call the Z.ai API / SDK directly — it violates the Coding Plan terms. The ZCode CLI through `$ZDISPATCH` is the only channel.
- Give GLM a SECURITY / DATA_LOSS phase — risk-marked phases run on Codex Sol in its sandbox.
- Run two write tasks in one working tree across both dispatchers, or more than 2 write tasks in total.
- Switch implementer channels silently — every fallback and escalation is one announced line.
- Call `zcode -p` or `node zcode.cjs` bypassing the wrapper — the wrapper guarantees the env, the identification headers, the git-tree guard and the job record.
- Change ZCode settings, plugins or login on the user's behalf — logging in (`zcode login zai`), enabling or disabling plugins are user actions. The wrapper's own personal provider config (the model pin) is the only ZCode-format file it writes.
- Run `doctor --probe` when the dev-orchestrator session marker already exists — one probe per session; the marker carries the result across compaction, and the probe spends quota.
- Omit `--background`; print per-poll status from the Monitor loop.
- Delete reservation files (`active.lock.*`) by hand while a job might run — a stale reservation is freed only by `"$ZDISPATCH" release-stale`.

## Session paths (for debugging)

- Wrapper: `<plugin-root>/bin/zcode-dispatch` → `<plugin-root>/bin/lib/zcode-dispatch.mjs`
- State: `~/.claude/plugins/data/superpowers-strigov-ver-zcode/state/<workspace-slug>/jobs/` — `zt-NNNN.json` (the job record) and `zt-NNNN.log`; `<workspace-slug>` = `<basename of the git root>-<first 8 hex of sha1(root)>`
- Personal provider config (wrapper-owned; holds the model pin, no credentials): `~/.claude/plugins/data/superpowers-strigov-ver-zcode/personal-provider-config.json`
- Constants in the `.mjs`, filled from `docs/zcode-cli-findings.md`: `PINNED_MODEL`, `PINNED_SELECTION`, `VERIFIED_APP_VERSION`, `VERIFIED_NODE_MAJOR`, `MAX_PROMPT_BYTES`, `PROMPT_TRANSPORT`, and the classifier `PATTERNS`
- Discovery facts and the live-acceptance results: `docs/zcode-cli-findings.md`
````

Then replace the four `⟨…⟩` tokens under "Verified facts" from `docs/zcode-cli-findings.md` → `## Inputs for later phases`:

| Token | Value |
|---|---|
| `⟨MODEL_SELECTION⟩` | `wrapper` (`MODEL_MECHANISM` = `personal-config`, `flag:…` or `env:…`) |
| `⟨MODEL_CONFIRMATION⟩` | `not required` (Ф1 reaches `GO` only after Step 6 confirmed the effective model) |
| `⟨GLM_RESUME⟩` | `enabled` if `RESUME_KEEPS_MODEL` = `yes`; `disabled` if `no` |
| `⟨GLM_CONCURRENCY⟩` | the `GLM_CONCURRENCY` value (`1` or `2`) |

No `⟨` may remain in the file.

- [ ] **Step 3: Edit `skills/dev-orchestrator/implementer-prompt.md`**

**I1.** **Find** in `skills/dev-orchestrator/implementer-prompt.md`:

```text
# Implementer Prompt (Codex Luna max)

Use when dispatching implementation to the Codex implementer (Luna max). Luna always runs at `max`. Reasoning escalation for BLOCKED phases goes to Sol 6.1 xhigh (`--model gpt-6.1-sol --effort xhigh`) on the same thread.
```

**Replace with:**

```text
# Implementer Prompt (GLM-5.3-Flash via ZCode · Codex Luna max · Codex Sol xhigh)

Use for every non-frontend implementer dispatch; the channel ladder in SKILL.md Step 3 picks the channel: GLM-5.3-Flash at `max` through Z.ai's ZCode CLI (default), Codex Luna max (availability fallback, kill switch), Codex Sol 6.1 xhigh (risk-marked SECURITY / DATA_LOSS phases, reasoning escalation). Luna always runs at `max`, Sol at `xhigh`. The templates below are the same on every channel; a GLM dispatch file additionally begins with the ZCode preamble, and a retry or channel switch adds the channel-switch notice.
```

**I2.** **Find** in `skills/dev-orchestrator/implementer-prompt.md`:

````text
## Invocation

```bash
"$DISPATCH" task \
  --background \
  --write \
  --model gpt-6-luna \
  --effort max \
  [--cwd <worktree-path>] \
  --prompt-file <scratch>/implement-<phase-id>.md
```

`$DISPATCH` is the `codex-dispatch` wrapper — resolve it once per session per the `codex-invocation` skill. Write the filled prompt to a scratch file first and pass it via `--prompt-file` — do not inline multi-line text. For a parallel-track phase, add `--cwd <worktree-path>` so Codex works in that track's worktree (and use the same `--cwd` on `status`/`result`).
````

**Replace with:**

````text
## Invocation

GLM (default):

```bash
"$ZDISPATCH" task --background [--cwd <worktree-path>] [--resume-task zt-NNNN | --fresh] --prompt-file "$dir"/prompts/<op>-<phase>-r<N>.<seq>.glm.md
```

`$ZDISPATCH` is the `zcode-dispatch` wrapper — resolve it once per session per the `zcode-invocation` skill. The wrapper pins the model (GLM-5.3-Flash at `max`); there are no `--model` / `--effort` flags. The dispatch file's first block is the ZCode preamble below. Fix rounds use `--resume-task <this phase's zt-id>`.

Codex — Luna (availability fallback) shown; for Sol (risk-marked phases, reasoning escalation) use `--model gpt-6.1-sol --effort xhigh` instead:

```bash
"$DISPATCH" task \
  --background \
  --write \
  --model gpt-6-luna \
  --effort max \
  [--cwd <worktree-path>] \
  [--resume-task task-NNNN | --fresh] \
  --prompt-file "$dir"/prompts/<op>-<phase>-r<N>.<seq>.<luna|sol>.md
```

`$DISPATCH` is the `codex-dispatch` wrapper — resolve it once per session per the `codex-invocation` skill.

**Prompt files** (both dispatchers — SKILL.md Step 3, "Prompt files and the retry / channel-switch rule"): write the filled template once as the operation's body file `$dir/prompts/<op>-<phase>-r<N>.md` (`$dir = $(sdd-workspace <plan-file>)`; operations `implement`, `fix`, `gatefix`, `final-fix`, `repair`); every dispatch goes out as its own dispatch file `<same name>.<seq>.<glm|luna|sol>.md`, composed per operation type and dispatch kind; the dispatched id goes into the sidecar `<same name>.<seq>.<glm|luna|sol>.id`. Never inline multi-line text; prompts no longer live in the session scratchpad. For a parallel-track phase, add `--cwd <worktree-path>` so the implementer works in that track's worktree (and use the same `--cwd` on `status` / `result`), and run `sdd-workspace` inside the worktree.
````

**I3.** **Find** in `skills/dev-orchestrator/implementer-prompt.md`:

```text
For follow-up rounds after the fused review (Step 4), resume the implementer's own thread: same flags plus `--resume-task <this phase's implementer task id>`, with the fix-round template below (it carries the authorized blockers; the thread already knows the plan and the phase). Thread-addressed resume is safe even though the control reviewer ran in between — see `codex-invocation` "Resume semantics". Never `--resume-last`. The same `--resume-task` id also serves `NEEDS_CONTEXT` / effort-upgrade re-dispatches in Step 3.

**Fresh fallback**: if the implementer thread is unavailable (phase implemented by a Claude subagent, task id lost, stale job record forcing `--fresh`), prepend the re-brief block from the template's "fresh fallback" note so the new session has full context.

Poll with Monitor using the terminal-only filter from `codex-invocation`. Fetch via `"$DISPATCH" result task-XXXX`.
```

**Replace with:**

```text
For follow-up rounds after the fused review (Step 4) and gate-fix rounds (Step 3.5), resume the implementer's own thread or session on the phase's channel: same flags plus `--resume-task <this phase's id>` (`zt-…` on `$ZDISPATCH`, `task-…` on `$DISPATCH` — ids never cross dispatchers), with the fix-round template below (it carries the authorized blockers; the thread already knows the plan and the phase). Addressed resume is safe even though the control reviewer ran in between — see `codex-invocation` / `zcode-invocation` "Resume semantics". Never `--resume-last`. The same id also serves `NEEDS_CONTEXT` re-dispatches in Step 3 and the Luna → Sol escalation, which resumes the Luna thread. When `zcode-invocation` records `GLM resume: disabled`, GLM follow-ups are FRESH dispatches instead (SKILL.md Step 3).

**Fresh fallback**: if a fix-type round cannot resume the implementer thread (phase implemented by a Claude subagent, id lost, stale job record forcing `--fresh`, a GLM ↔ Codex channel switch, a GLM → Sol escalation), the fix-round template's opening paragraph is **replaced** by the re-brief block from the template's "fresh fallback" note so the new session has full context; the channel-switch notice follows it whenever an earlier dispatch of the same operation exists. A first-round (`implement`) dispatch never carries the re-brief — it is self-contained; a retry or channel switch of it only adds the channel-switch notice after its opening paragraph.

Poll with Monitor using the terminal-only filter from `codex-invocation` (GLM: the same loop from `zcode-invocation`, `zt-` ids). Fetch via `"$DISPATCH" result task-XXXX` or `"$ZDISPATCH" result zt-XXXX`.
```

**I4.** **Find** in `skills/dev-orchestrator/implementer-prompt.md`:

```text
## First-round prompt template
```

**Replace with:**

````text
## ZCode preamble (GLM dispatches only)

Prepend this block verbatim to **every** GLM dispatch file — first round, fix rounds, gate-fix rounds, `NEEDS_CONTEXT` follow-ups, the Step 5 wave and integration repair. Replace `[REPORT_FILE]` with the same absolute path the template uses. Never send it to Codex or Claude implementers.

```
## ZCode headless run — read this first

- This is a headless, non-interactive run. Nobody can answer questions. Do not ask. If something is unclear, stop and finish with the status token `NEEDS_CONTEXT` (first round) or `BLOCKED`, with the specific question in your final message.
- Do not invoke skills, plugins, dynamic workflows, sub-agents, browser or computer-use tools, or goal mode. Use only file reads, file edits and shell commands.
- No git operations that change history, refs or the index: no `git commit`, `git push`, `git branch`, `git checkout`, `git switch`, `git stash`, `git reset`, `git rebase`, `git add`. Read-only git (`git status`, `git diff`, `git log`, `git show`) is fine.
- Stay inside the repository root named below. Never read or write `~/.zcode`, `~/.ssh`, `~/.aws`, keychains, or any credential store, and never read `.env` files outside the repository.
- Network only for package installs the plan explicitly requires (for example an `npm install` / `pip install` of a dependency the plan names). No other downloads, no API calls.
- Write the full report to [REPORT_FILE] (create parent directories if needed). Your final message is at most 15 lines; line 1 is the bare status token and nothing else.
```

## Channel-switch notice (retries and channel switches)

Insert this block whenever a phase moves between channels or a channel retries after an infrastructure failure (Luna fallback, Sol escalation, `--fresh` retry). Placement is fixed by SKILL.md Step 3 ("Prompt files and the retry / channel-switch rule"): on an `implement` dispatch it follows the first-round template's opening paragraph and there is **no** re-brief (that block declares a fix round); on a FRESH fix-type dispatch the fresh-fallback re-brief keeps its role — it **replaces** the fix-round template's opening paragraph — and this notice follows it; on a thread resume neither block appears. Fill the angle-bracket choices with the previous attempt's channel, job id and status. For a `--fresh` retry on the same channel, the first sentence names the same model: "A previous run of this implementer (<GLM-5.3-Flash via ZCode | Codex Luna | Codex Sol>, job <zt-NNNN | task-NNNN>, status failed/<errorClass>) worked on this same task before you."

```
## Previous attempt

A previous run on another implementer (<GLM-5.3-Flash via ZCode | Codex Luna>, job <zt-NNNN | task-NNNN>, status <failed/<errorClass> | BLOCKED | review stall after round 3 | gate stall>) worked on this same task before you. It may have left uncommitted partial changes in the working tree and a report at [REPORT_FILE]. Before anything else: `git status --porcelain` and `git diff <base-sha>`; read [REPORT_FILE] if it exists (including every `## Fix round` section). Your task and its scope are exactly what the sections after this notice say — a fix round stays a fix round: fix only its AUTHORIZED_BLOCKERS and append to the same [REPORT_FILE] under the same `## Fix round <N>` heading. Keep partial work that falls inside that scope and matches the plan, redo what does not, and say in your report what you kept.
```

## First-round prompt template
````

**I5.** **Find** in `skills/dev-orchestrator/implementer-prompt.md`:

```text
When the orchestrator dispatches the final-review fix wave (SKILL.md Step 5), the fix-round template above is reused as a **FRESH task with the fresh-fallback re-brief**
```

**Replace with:**

```text
When the orchestrator dispatches the final-review fix wave (SKILL.md Step 5) — on the channel Step 5 picks (GLM, Luna or Sol; a GLM dispatch file begins with the ZCode preamble) — the fix-round template above is reused as a **FRESH task with the fresh-fallback re-brief**
```

- [ ] **Step 4: Edit `skills/dev-orchestrator/SKILL.md` — frontmatter, hard rules, pre-flight gate, role**

**E1.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
Codex Luna max implements; fix rounds resume the implementer's own thread (--resume-task); Codex Sol 6.1 xhigh is the reasoning escalation, Opus high the BLOCKED diagnosis.
```

**Replace with:**

```text
GLM-5.3-Flash max implements non-frontend phases through Z.ai's own ZCode CLI (zcode-dispatch wrapper, zcode-invocation skill); Codex Luna max is the availability fallback (GLM channel down, or the kill switch "через Luna" / "без GLM" / SP_IMPLEMENTER=luna); Codex Sol 6.1 xhigh implements SECURITY/DATA_LOSS phases and is the reasoning escalation; fix rounds resume the implementer's own session (--resume-task); Opus high is the BLOCKED and gate-stall diagnosis.
```

**E2.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
- Full protocol tasks → Codex implementer, Luna max (`./implementer-prompt.md`).
```

**Replace with:**

```text
- Full protocol tasks → the implementer chosen by the channel ladder (GLM via `$ZDISPATCH`, Luna/Sol via `$DISPATCH`; `./implementer-prompt.md`).
```

**E3.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
- Plan file (`docs/plans/<slug>.md`) — frontmatter status flips during auto-commit. Reason: mechanical metadata bookkeeping, not production code.
```

**Replace with:**

```text
- Plan file (`docs/plans/<slug>.md`) — frontmatter status flips during auto-commit, and the `risk_phases` map (Step 2.5). Reason: mechanical metadata bookkeeping, not production code.
```

**E4.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
- Scratch prompt files for `--prompt-file` dispatches — `Write` to the scratchpad or workspace, never to source paths. Reason: dispatch plumbing, not production code.
```

**Replace with:**

```text
- Scratch prompt files for `--prompt-file` dispatches — `Write` to the scratchpad or workspace, never to source paths. Reason: dispatch plumbing, not production code.
- Implementer prompt bodies, dispatch files and `.id` sidecars under `$dir/prompts/` (Step 3, "Prompt files and the retry / channel-switch rule"), and the GLM session marker `<scratchpad>/dev-orchestrator/glm-channel` ("## Protocol state line") — `Write` only. Reason: dispatch plumbing, not production code.
```

**E5.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
Never `Read` a review package (`review-*.diff`) — the diff must not transit your context.
```

**Replace with:**

```text
Never `Read` a review package (`review-*.diff`) — the diff must not transit your context.
- `"$ZDISPATCH" status`, `"$ZDISPATCH" doctor`, `"$ZDISPATCH" doctor --probe`, `echo "${SP_IMPLEMENTER:-}"`, `ls "$dir"/prompts/` (filenames only), `cat` of one `.id` sidecar under `$dir/prompts/`, and `cat` of the session marker `<scratchpad>/dev-orchestrator/glm-channel` — GLM channel bookkeeping (Step 3, "## Protocol state line"). Only their short stdout enters your context.
```

**E6.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
after a later plan revision, re-extract only that section. See Step 2.5.
```

**Replace with:**

```text
after a later plan revision, re-extract only that section. The same full read is allowed again only for a `risk_phases` re-scan that Step 2.5's re-derivation rule or a compaction-safe guard (Pre-dispatch checklist items 5 and 10) triggers. See Step 2.5.
```

**E7.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
the first implementer dispatch (`"$DISPATCH" task` or the Claude implementer Agent call) disarms the gate the same way
```

**Replace with:**

```text
the first implementer dispatch (`"$DISPATCH" task`, `"$ZDISPATCH" task`, or the Claude implementer Agent call) disarms the gate the same way
```

**E8.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
found via `"$DISPATCH" status` after a compaction or session break, counts as that dispatch
```

**Replace with:**

```text
found via `"$DISPATCH" status` or `"$ZDISPATCH" status` (either dispatcher) after a compaction or session break, counts as that dispatch
```

**E9.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
  - (c) the script-resolution snippet from "## Workspace scripts" verbatim, and invocations of the resolved `"$WS"`, `"$RPKG"`, `"$DISPATCH" status` — workspace/package/dispatch bookkeeping (only their one-line stdout enters context) — plus, on resume, `ls` / `find` on the directory a `"$WS"` call just printed (filenames only, to locate the last round's report and packages).
```

**Replace with:**

```text
  - (c) the script-resolution snippet from "## Workspace scripts" verbatim, and invocations of the resolved `"$WS"`, `"$RPKG"`, `"$DISPATCH" status`, `"$ZDISPATCH" status`, `"$ZDISPATCH" doctor`, `"$ZDISPATCH" doctor --probe` — workspace/package/dispatch bookkeeping (only their short stdout enters context) — plus `echo "${SP_IMPLEMENTER:-}"`, `cat` of the GLM session marker, and, on resume, `ls` / `find` on the directory a `"$WS"` call just printed or its `prompts/` subdirectory (filenames only, to locate the last round's report, packages and dispatch files) and `cat` of one `.id` sidecar there.
```

**E10.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
(The Codex wrapper-resolution snippet from `codex-invocation` also stays allowed — it is `command -v` / `ls` bookkeeping, and Step 2's Codex plan-review dispatch needs `$DISPATCH` resolved.)
```

**Replace with:**

```text
(The Codex wrapper-resolution snippet from `codex-invocation` and the `$ZDISPATCH` resolution snippet from `zcode-invocation` also stay allowed — they are `command -v` / `ls` bookkeeping, and Step 2's Codex plan-review dispatch needs `$DISPATCH` resolved.)
```

**E11.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
- **Confirmed-resume path only** ("Before Step 1" item 4): `Edit` of the plan-file frontmatter and `git add <plan-file>` / `git commit` for the advance-bookkeeping commit; `Write` of the scratch prompt file for `--prompt-file`; `"$DISPATCH" task` / `"$DISPATCH" result`; `Read` of the ledger file; and `Monitor` polling of a running task. The resume path jumps straight to Step 3/4 — the implementer dispatch itself (or the already-running task found via `"$DISPATCH" status`) disarms the gate.
```

**Replace with:**

```text
- **Confirmed-resume path only** ("Before Step 1" item 4): `Edit` of the plan-file frontmatter (status flips and the `risk_phases` map) and `git add <plan-file>` / `git commit` for the advance-bookkeeping and risk-phases commits; the Step 2.5 `risk_phases` scan when the plan has no map (compaction-safe guard (a)); `Write` of prompt body, dispatch and `.id` files under `$dir/prompts/`; `"$DISPATCH" task` / `"$DISPATCH" result` / `"$ZDISPATCH" task` / `"$ZDISPATCH" result`; `Read` of the ledger file; and `Monitor` polling of a running task. The resume path jumps straight to Step 3/4 — the implementer dispatch itself (or the already-running task found via `"$DISPATCH" status` or `"$ZDISPATCH" status`) disarms the gate.
```

**E12.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
the Opus and Codex Astra code reviewers, and the Opus diagnosis subagent — not done on main.
```

**Replace with:**

```text
the Opus and Codex Astra code reviewers, and the Opus diagnosis subagent — not done on main. Implementation goes to the implementer per the channel ladder (Step 3): GLM-5.3-Flash max through Z.ai's ZCode CLI by default, Codex Luna max as the availability fallback, Codex Sol 6.1 xhigh for risk-marked phases and reasoning escalation; frontend-only phases go to the Claude frontend implementer.
```

- [ ] **Step 5: Edit `skills/dev-orchestrator/SKILL.md` — state line, durable progress, verdict parsing, model split, checklist, triage, resume**

**E13.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
| commit | archive> phase=<Ф-id or —> round=<k>/4 base=<base7 or —> gate=<armed | passed>`
```

**Replace with:**

```text
| commit | archive> phase=<Ф-id or —> round=<k>/4 base=<base7 or —> gate=<armed | passed> impl=<glm:zt-NNNN | luna:task-NNNN | sol:task-NNNN | claude | —> glm=<unprobed | ok | down | off>`
```

**E14.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
Never skip the state line "because the turn is short"; it is exactly the long, multi-round sessions where skipping it lets the protocol drift.
```

**Replace with:**

```text
Never skip the state line "because the turn is short"; it is exactly the long, multi-round sessions where skipping it lets the protocol drift.

- `impl` is the current phase's implementer channel and its resume handle (the Claude frontend subagent has no handle; `—` before the first dispatch). During a parallel group the per-track form replaces it: `tracks=Ф2:4-r1@glm:zt-0003,Ф3:3@luna:task-0011`.
- `glm` is the session's GLM channel state: `unprobed` (no probe yet), `ok`, `down` (`doctor` / `doctor --probe` failed, or a GLM job failed with `quota | auth | model-not-selected`), `off` (kill switch).
- **Durable copies.** `impl` handles live in the `.id` sidecars under `$dir/prompts/` (Step 3) and in the dispatchers' job records. `glm` lives in the **session marker** `<scratchpad>/dev-orchestrator/glm-channel` — one line `<ok|down|off> <reason> <ISO time>` — written whenever `glm` leaves `unprobed` or changes; `<scratchpad>` is the session-specific scratchpad directory the host names in the system prompt, which survives compaction and dies with the session. `down` and `off` are never overwritten by a later probe: they hold until the session ends (a new session starts `unprobed`; `SP_IMPLEMENTER=luna` re-writes `off` at every skill start). If the host names no scratchpad, the state exists only in the state line — say so once at skill start.
- **Recovery after compaction, in this order:**
  1. `glm` — `echo "${SP_IMPLEMENTER:-}"` prints `luna` → `off`; else `cat` the marker → its state; else `unprobed` (ladder item 3 probes when first needed — that is the session's one probe). Never probe when a marker exists.
  2. `impl` — `ls "$dir"/prompts/` (filename listing); take the `.id` sidecars of the current phase (name contains `-<phase>-r`; for plan-wide work the names starting with `final-fix-` or `repair-<G>-`); of those, the **highest `<seq>`**, regardless of operation, round or channel; `cat` that one sidecar; confirm with `status <id> --json` on the dispatcher its prefix names (`zt-` → `$ZDISPATCH`, `task-` → `$DISPATCH`, with the track's `--cwd`). `running` → keep polling it (the pre-flight gate's running-task rule). Terminal → that is the resume handle; its channel is the phase's channel (ladder item 4), and the file's `<op>-r<N>` names the step and round the phase is in. Checked cases: `implement-Ф2-r1.001.glm`, `.002.glm`, `.003.luna` → `luna:` (not the failed GLM job); `implement-Ф2-r1.001.luna`, `.002.sol` → `sol:` (no tie).
  3. No sidecar for the phase, or `status` rejects the id (unknown id, other workspace) → `impl=—`, and never pick a job by recency: apply "## Durable Progress" item 3 — `git log` / `git status` show the phase's implementation → resume at the step the newest report and review package in `$dir` name, with the next dispatch FRESH in the Step 3 composition for its operation type (lost handle — an `implement` dispatch carries no re-brief); not implemented → first-round dispatch per the ladder.
```

**E15.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
`git log --oneline -15` — both are allowed resume-check reads under the pre-flight gate.
```

**Replace with:**

```text
`git log --oneline -15` — both are allowed resume-check reads under the pre-flight gate. Then restore the state line's `glm` field (and, after compaction, `impl`) per "## Protocol state line" → Recovery after compaction; at skill start, `echo "${SP_IMPLEMENTER:-}"` printing `luna` sets `glm=off` and re-writes the session marker.
```

**E16.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
4. **Before re-dispatching any phase's implementer**, run `"$DISPATCH" status`: if a write task for this phase is already running, do NOT dispatch a second — two write tasks in one working tree corrupt each other; keep polling the running one.
```

**Replace with:**

```text
4. **Before re-dispatching any phase's implementer**, run `"$DISPATCH" status` **and** `"$ZDISPATCH" status` (with the track's `--cwd` where applicable): a running write task for this phase on either → poll it, never dispatch a second — two write tasks in one working tree corrupt each other.
```

**E17.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
- Integration check (parallel groups): `INTEGRATION_OK` | `INTEGRATION_FAIL`
```

**Replace with:**

```text
- Integration check (parallel groups): `INTEGRATION_OK` | `INTEGRATION_FAIL`
- Gate-stall diagnosis (Step 3.5): `ENVIRONMENT` | `CODE` | `CONTEXT`
```

**E18.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
3. No exact match → output is malformed. Re-dispatch ONCE (Codex: `--resume-task <that task's id>`; Claude: fresh Agent call) saying:
```

**Replace with:**

```text
3. No exact match → output is malformed. Re-dispatch ONCE (Codex: `--resume-task <that task's id>`; GLM: `"$ZDISPATCH" task --background --resume-task <that job's zt-id>` with a dispatch file at the next seq — the ZCode preamble, then the sentence below; Claude: fresh Agent call) saying:
```

**E19.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
| Implementer — phases, fix rounds, Step 5 fix wave, integration repair | 3, 4, 5 | Codex `gpt-6-luna` · `max` |
| Reasoning escalation (BLOCKED + diagnosis "needs more reasoning") | 3 | Codex `gpt-6.1-sol` · `xhigh`, resuming the implementer thread |
```

**Replace with:**

```text
| Implementer — phases, fix rounds, gate-fix rounds, Step 5 fix wave, integration repair | 3, 3.5, 4, 5 | **GLM `GLM-5.3-Flash` · `max` via `$ZDISPATCH`** (ZCode CLI) |
| Implementer of SECURITY / DATA_LOSS phases (risk-marked, Step 2.5) | 3, 3.5, 4, 5 | Codex `gpt-6.1-sol` · `xhigh` · `--write` |
| Availability fallback (GLM channel down or failed, kill switch) | 3, 3.5, 4, 5 | Codex `gpt-6-luna` · `max` · `--write` — the **same operation** re-dispatched FRESH in the Step 3 composition for its operation type (channel-switch notice; re-brief only on fix-type operations), **announced** |
| Reasoning escalation (BLOCKED + "needs more reasoning"; fused-review round 3 still BLOCKING; gate diagnosis `CODE`) — on GLM **and** Luna phases | 3, 3.5, 4 | Codex `gpt-6.1-sol` · `xhigh` · `--write` — GLM phase: FRESH, composed per the Step 3 rules for the operation type (`implement`: first-round body + notice, no re-brief; fix-type: re-brief opening + notice + body); Luna phase: `--resume-task` of the Luna thread. From then on Sol is the phase's channel; on a phase already on Sol these points go to the user. |
```

**E20.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
| Primary review | 4.1 | Claude `opus` · `high`; `xhigh` when the phase carries SECURITY / DATA_LOSS risk or in round 4 (the last round before the cap) |
```

**Replace with:**

```text
| Primary review | 4.1 | Claude `opus` · `high`; `xhigh` when the phase is risk-marked (`risk_phases`, Step 2.5) or in round 4 (the last round before the cap) |
```

**E21.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
| Diagnosis (BLOCKED) and impasse summaries | 3, escalations | Claude `opus` · `high` |
```

**Replace with:**

```text
| Diagnosis (BLOCKED, gate stall) and impasse summaries | 3, 3.5, escalations | Claude `opus` · `high` |
```

**E22.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
- **Codex Luna implementer** (`--model gpt-6-luna --effort max`, always `--write`) — Step 3 implementation for **non-frontend** phases, Step 4 fix rounds, the Step 5 fix wave and integration repairs. Luna always runs at `max`: a Luna dispatch at any other level is a wrong dispatch, not a cheaper option.
- **Codex Sol escalation** (`--model gpt-6.1-sol --effort xhigh --write`) — resume the implementer thread at Sol when Luna reports BLOCKED and the Opus diagnosis says "needs more reasoning".
```

**Replace with:**

```text
- **GLM implementer** (GLM-5.3-Flash at `max`, through Z.ai's ZCode CLI) — the default implementer for **non-frontend** phases: Step 3, Step 3.5 gate-fix rounds, Step 4 fix rounds, the Step 5 fix wave and integration repairs, as the channel ladder (Step 3) decides. Dispatched only through `$ZDISPATCH` (never `zcode -p` or `node zcode.cjs` directly); the wrapper pins the model, there are no `--model` / `--effort` flags. GLM always runs at `max`; there is no cheaper GLM dispatch.
- **Codex Luna fallback** (`--model gpt-6-luna --effort max`, always `--write`) — the availability fallback: the GLM channel is down or failed, or the kill switch is active. Luna always runs at `max`: a Luna dispatch at any other level is a wrong dispatch, not a cheaper option. Luna is not a reasoning-escalation target.
- **Codex Sol** (`--model gpt-6.1-sol --effort xhigh --write`) — implements risk-marked phases (SECURITY / DATA_LOSS, Step 2.5) from the start, inside the Codex sandbox, and is the reasoning escalation for GLM and Luna phases (BLOCKED + "needs more reasoning", gate diagnosis `CODE`, fused-review round 3 still BLOCKING). Nothing sits above Sol: on a phase already on Sol those points go to the user.
```

**E23.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
Luna writes the code → Opus reviews it, Astra cross-checks.
```

**Replace with:**

```text
The implementer writes the code → Opus reviews it, Astra cross-checks. GLM adds a third family (Z.ai): GLM-written code is reviewed cross-family on both sides; an escalation to Sol returns the phase to the Codex-writes / Opus-reviews scheme.
```

**E24.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
(Astra as the only final reviewer of Luna-written code)
```

**Replace with:**

```text
(Astra as the only final reviewer of a branch with Luna- or Sol-written code)
```

**E25.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
Read the `codex-invocation` skill before your first Codex call in a session.
```

**Replace with:**

```text
Read the `codex-invocation` skill before your first Codex call in a session. GLM is invoked via `zcode-dispatch --background` + the same Monitor poll. Read the `zcode-invocation` skill before your first GLM call in a session.
```

**E26.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
## Pre-dispatch checklist (every Agent / Codex dispatch)
```

**Replace with:**

```text
## Pre-dispatch checklist (every Agent / Codex / ZCode dispatch)
```

**E27.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
5. **Codex only:** `--background` present; `--model` + `--effort` match the Model split table — plan review = `gpt-6-astra`/xhigh, control review = `gpt-6-astra`/high, implementer = `gpt-6-luna`/max, reasoning escalation = `gpt-6.1-sol`/xhigh, final-review fallback = `gpt-6-astra`/xhigh
```

**Replace with:**

```text
5. **Codex only:** `--background` present; `--model` + `--effort` match the Model split table — plan review = `gpt-6-astra`/xhigh, control review = `gpt-6-astra`/high, availability-fallback implementer = `gpt-6-luna`/max, risk-marked-phase implementer and reasoning escalation = `gpt-6.1-sol`/xhigh, final-review fallback = `gpt-6-astra`/xhigh
```

**E28.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
Record every dispatched task id next to its role — you will need it for the resume.
```

**Replace with:**

```text
Record every dispatched task id next to its role — you will need it for the resume. A Codex resume never references a `zt-` id. **Implementer dispatches only:** the Step 2.5 compaction-safe guards ran first and the **admission condition** holds — the current phase id (plan-wide operations `final-fix` / `repair`: every phase id) is a key of `risk_phases` **and** the plan file is clean in `git status`; the prompt is a dispatch file under `$dir/prompts/` at the next seq, whose operation matches the step and whose composition matches the dispatch kind (resume vs FRESH, Step 3).
```

**E29.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
Exception: a sentence that references already-triaged ledger entries by id (`REJECTED_BY_SCOPE` / `DEFER`) is allowed — the ban is on pre-judging NEW findings, not on relaying settled triage.
```

**Replace with:**

```text
Exception: a sentence that references already-triaged ledger entries by id (`REJECTED_BY_SCOPE` / `DEFER`) is allowed — the ban is on pre-judging NEW findings, not on relaying settled triage.
10. **GLM only:** dispatched as `"$ZDISPATCH" task --background --prompt-file "$dir"/prompts/<op>-<phase>-r<N>.<seq>.glm.md` (no `--model` / `--effort` exist — the wrapper pins them); the dispatch file **begins with the ZCode preamble** (`./implementer-prompt.md`), its operation matches the step and its composition the dispatch kind; the Step 2.5 guards ran and the same admission condition holds; fix, gate-fix and `NEEDS_CONTEXT` rounds carry `--resume-task zt-…` (never a `task-` id) unless `zcode-invocation` records `GLM resume: disabled`; parallel tracks carry `--cwd` on the task and on every later `status` / `result`; the state line shows `glm=ok`; the phase's `risk_phases` entry exists and is empty; the kill switch is not active. Any check fails → fix the dispatch or re-run the ladder; never dispatch and patch later.
```

**E30.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
  NO  → Full protocol below. Step 3 routes per-phase: Codex implementer (Luna max)
        for backend / non-frontend phases, Claude frontend implementer subagent for
        frontend-only phases.
```

**Replace with:**

```text
  NO  → Full protocol below. Step 3 routes per-phase: implementer per the channel
        ladder (GLM / Luna / Sol) for backend / non-frontend phases, Claude frontend
        implementer subagent for frontend-only phases.
```

**E31.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
and run `"$DISPATCH" status` first — a write task already running for the phase means poll, not re-dispatch.
```

**Replace with:**

```text
and run `"$DISPATCH" status` and `"$ZDISPATCH" status` first — a write task already running for the phase on either dispatcher means poll, not re-dispatch.
```

- [ ] **Step 6: Edit `skills/dev-orchestrator/SKILL.md` — Step 2.5 risk phases**

**E32.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
used ONLY for the three mechanical string checks below
```

**Replace with:**

```text
used ONLY for the four mechanical checks below
```

**E33.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
3. **Rubric-mandated defects.** The plan explicitly mandates an item from this fixed list: a test that asserts nothing; verbatim duplication of a logic block; an instruction to skip tests.
```

**Replace with:**

````text
3. **Rubric-mandated defects.** The plan explicitly mandates an item from this fixed list: a test that asserts nothing; verbatim duplication of a logic block; an instruction to skip tests.
4. **Risk phases.** Classify **every** phase: a phase is risk-marked when the plan's `## Risks / unknowns` section (or the phase's own Risks lines) names `SECURITY` or `DATA_LOSS` for it — the same determination the 4.1 `xhigh` escalation makes. Write ONE top-level key into the plan-file YAML frontmatter (a mechanical metadata edit under Rule 1), listing every phase id — an empty list means "scanned, no risk":

   ```yaml
   risk_phases: { Ф1: [], Ф2: [], Ф3: [DATA_LOSS], Ф5: [SECURITY, DATA_LOSS] }
   ```

   Commit the plan file alone as `docs(plans): record risk phases for <slug>` (same class as the `docs(plans): advance to <id>` bookkeeping commit). "Phase X is risk-marked" ⇔ `risk_phases[X]` is non-empty; "the plan has a risk-marked phase" ⇔ any value is non-empty. The channel ladder (Step 3), Step 5, integration repair and the 4.1 `xhigh` escalation read this key; the value lists the kinds for the announcement line. After compaction the frontmatter read ("## Durable Progress" item 1) restores it — no second read of the plan body. This check produces no findings for the batched question below; it only writes the map.
````

**E34.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
Re-run the three checks once on the revised plan, then proceed.
```

**Replace with:**

```text
Re-run the four checks once on the revised plan, then proceed.

**Re-derivation after plan changes.** Every plan-writer Mode B dispatch that lands after Step 2.5 has run — pre-flight edits the user accepted, a BLOCKED "task too large" sub-phase split (Step 3), a scope revision after a completed phase's findings ("## Multi-phase plans"), a legacy frontmatter retrofit — is followed, **before the revised plan file is committed and before any implementer dispatch**, by a re-run of the four checks on the revised plan. The `risk_phases` map is rewritten in full — new ids added, removed ids dropped, changed risks updated — and lands in the same commit as the revision.

**Compaction-safe guards** — checked before every non-frontend implementer dispatch (Pre-dispatch checklist items 5 and 10), first match wins:
- (a) no `risk_phases` key at all (a pre-0.8.0 plan on the confirmed-resume path, or a pre-flight that never ran) → run check 4 once now — this full read of the plan body is allowed — write the map, commit;
- (b) the current phase id — for the plan-wide operations `final-fix` and `repair`, every id in the frontmatter `phases:` list — is not a key of the map (new sub-phase, renamed phase) → the map is stale → re-scan, rewrite, commit, then dispatch;
- (c) the plan file is dirty in `git status` → a revision may have landed without its re-scan → re-scan, rewrite the map and commit the plan file — carrying whatever uncommitted revision it holds — as `docs(plans): record risk phases for <slug>`;
- (d) otherwise the map is current — a present, complete map is never re-derived without one of these triggers.

**Admission condition** (checked by Pre-dispatch checklist items 5 and 10 after any guard fired): the needed phase ids are keys of `risk_phases` **and** the plan file is clean in `git status`. No implementer dispatch while either half fails.
```

- [ ] **Step 7: Edit `skills/dev-orchestrator/SKILL.md` — Step 3 (ladder, prompt files, routing, status, failures)**

**E35.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
For a parallel track, run `"$WS"` with cwd inside the track's worktree. Fix rounds append to the same file — never mint a new report path for round 2+.

**Route by phase type** (decide from the plan's `Files` section for this phase):
```

**Replace with:**

```text
For a parallel track, run `"$WS"` with cwd inside the track's worktree. Fix rounds append to the same file — never mint a new report path for round 2+.
3. **Non-frontend phase: decide the channel** — at the phase's first Step 3 dispatch, run the channel ladder below; write the result into the state line (`impl=`) and announce it in one line ("## Reporting cadence").
4. **Before the first GLM dispatch of a session** (only when the ladder reaches item 3 with `glm=unprobed`): resolve `$ZDISPATCH` (snippet in `zcode-invocation`), run `"$ZDISPATCH" doctor`, then `"$ZDISPATCH" doctor --probe` (cwd inside the repo). Both exit 0 → `glm=ok`. Either fails → `glm=down`, one announcement (`ZCode doctor failed (<first FAIL line>) — implementer for this session: Luna max.`), and ladder item 3 applies for the rest of the session. If `zcode-invocation` records `Model confirmation: required`, then — after a passing probe, once per session — ask the user (`AskUserQuestion`) to confirm that ZCode runs GLM-5.3-Flash with reasoning `max`; a "no" → `glm=down` with reason `model not confirmed`. Write the result to the session marker. The probe runs **once per session**; after compaction the marker, not a new probe, restores the state.

**Channel ladder** (non-frontend phases; decided **once per phase**, at its first Step 3 dispatch; Steps 3.5, 4, 5 and "## Parallel groups" use the channel it picked). First match wins:

1. **Kill switch active** — the user said "через Luna" or "без GLM" in this session, or `SP_IMPLEMENTER` is `luna` (`glm=off`) → Codex Luna max. (Risk-marked phases also go to Luna under the kill switch, as they did before 0.8.0; the gate-stall and review-stall rules of Steps 3.5 and 4 still apply — they are pipeline rules, not GLM rules.)
2. **Phase is risk-marked** (`risk_phases[<id>]` non-empty, Step 2.5) → Codex Sol 6.1 xhigh `--write`.
3. **GLM channel down this session.** If the state line still shows `glm=unprobed`, run item 4 above now and set `glm` before evaluating this item. `glm=down` → Codex Luna max, announced once per session.
4. **Phase already handed to Luna or Sol** (fallback or escalation earlier in this phase) → stays there; resume that thread with `--resume-task <task-id>`.
5. **Otherwise** → GLM-5.3-Flash max via `$ZDISPATCH`.

Frontend-only phases do not enter the ladder (Claude frontend implementer, unchanged).

**Kill switch.** Session: the user says "через Luna" or "без GLM" (in any message of the session) → `glm=off`, written to the session marker so it survives compaction; ladder item 1 for every phase until the session ends — nothing re-enables GLM within the session. Permanent: `SP_IMPLEMENTER=luna` in the environment → `glm=off` at every skill start (the wrapper refuses `task` anyway). Nothing else: no per-phase toggles, no config file, no other values of `SP_IMPLEMENTER`.

**Prompt files and the retry / channel-switch rule** (every implementer dispatch on every non-frontend channel — Steps 3, 3.5, 4, 5 and integration repair):

- Every dispatch belongs to exactly one **operation**: `implement` (first round), `fix r<N>` (Step 4 fix round), `gatefix r<N>` (Step 3.5 gate-fix round), `final-fix` (Step 5 fix wave) or `repair r<N>` (integration repair). The operation fixes the template (first-round or fix-round, with the "Step 5 fix wave" substitutions where applicable), the scope, the ledger items inlined, the round number and `[REPORT_FILE]`.
- Write the operation's **body file** once — the filled template and nothing else — to `$dir/prompts/<name>.md`, where `$dir = $("$WS" <plan-file>)` (for a parallel track, `"$WS"` run inside the worktree) and `<name>` is one of `implement-<id>-r1`, `fix-<id>-r<N>`, `gatefix-<id>-r<N>`, `final-fix-r<N>`, `repair-<G>-r<N>`. The plan-scoped workspace, not the session scratchpad, so the files outlive compaction and sessions. A continuation of the same operation (`NEEDS_CONTEXT`, added context after a diagnosis) appends an `## Added context` section to the body file before the `--resume-task` follow-up, so a later retry carries it.
- Every dispatch — every `task` invocation, resumes and follow-ups included — is written to a **dispatch file** `$dir/prompts/<name>.<seq>.<glm|luna|sol>.md`. `<seq>` is a three-digit **per-phase dispatch sequence number** (per operation name for the plan-wide `final-fix` / `repair-<G>`), monotonic across operations, rounds **and channels**: the next seq is the highest seq present for the phase plus one (`ls "$dir"/prompts/`). Composition, by operation type and dispatch kind:
  - `implement` — ZCode preamble (GLM target only) → the body (the self-contained first-round template); on a retry or channel switch the channel-switch notice is inserted right after the body's opening paragraph. **Never the fresh-fallback re-brief** — that block declares a fix round and would contradict the first-round template.
  - fix-type operations (`fix`, `gatefix`, `final-fix`, `repair`), **thread resume** (`--resume-task` — a GLM session resume, a Luna/Sol thread resume, and the Luna → Sol escalation, which resumes the Luna thread) — preamble (GLM only) → the body as written (fix-round template with its standard opening paragraph). No re-brief, no notice: the thread holds the history.
  - fix-type operations, **FRESH** (a new thread: GLM ↔ Codex channel switch, `--fresh` retry, lost handle; the Step 5 wave and integration repair are fresh by nature) — preamble (GLM only) → the body with its opening paragraph **replaced** by the fresh-fallback re-brief block (`./implementer-prompt.md`), and the channel-switch notice inserted right after the re-brief whenever an earlier dispatch of this operation exists.
  - a continuation follow-up on a resumed thread (`NEEDS_CONTEXT`, added context) is the short follow-up text — on a GLM target still preceded by the ZCode preamble, which opens **every** GLM dispatch file without exception; it still takes the next seq, a dispatch file and a sidecar.
- The moment the dispatcher prints the id, write it — `glm:zt-NNNN` / `luna:task-NNNN` / `sol:task-NNNN` — into the sidecar `<same name>.id` (`$dir/prompts/<name>.<seq>.<channel>.id`; a one-line bookkeeping write, same class as the ledger). Because seq is monotonic across channels, **the highest seq for a phase is always its current channel and handle** — e.g. `implement-Ф2-r1.001.glm` → `.002.glm` (retry) → `.003.luna` (fallback) resolves to Luna; `implement-Ф2-r1.001.luna` → `.002.sol` (escalation) resolves to Sol.
- **A retry or a channel switch never changes the operation.** A failed `fix r2` on GLM is re-dispatched as `fix r2` on the new channel with the same body — same AUTHORIZED_BLOCKERS, same round number, same `[REPORT_FILE]` append rule; a failed `final-fix` stays a whole-plan fix wave; a failed `gatefix r1` stays a gate-fix round. The first-round template appears only when the operation is `implement`. On Codex channels the `codex-invocation` terminal-status rule (retry once with `--fresh`, then the user) applies with the same body file at the next seq.
- **GLM resume disabled.** When `zcode-invocation` records `GLM resume: disabled` (discovery found that a resumed ZCode session loses the model), every GLM dispatch this skill writes as `--resume-task <zt-id>` is instead a FRESH GLM dispatch of the same operation (`--fresh`, the FRESH composition for its operation type); a continuation's added context goes into the body file's `## Added context` section, which the FRESH dispatch carries.

**Route by phase type** (decide from the plan's `Files` section for this phase):
```

**E36.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
- **Backend / non-frontend phase** → Codex implementer (Luna max) using `./implementer-prompt.md`. Points Codex at the plan file and names the current phase id.

Dispatch, wait terminal (Codex) or Agent completion (Claude subagent), fetch result.
```

**Replace with:**

````text
- **Backend / non-frontend phase** → implementer per the channel ladder: GLM via `$ZDISPATCH` with `./implementer-prompt.md` prefixed by the ZCode preamble; Luna or Sol via `$DISPATCH` as before. The prompt points the implementer at the plan file and names the current phase id. GLM dispatch line:

  ```bash
  "$ZDISPATCH" task --background [--cwd <worktree-path>] --prompt-file "$dir"/prompts/implement-<id>-r1.<seq>.glm.md
  ```

  Poll with the Monitor loop from `zcode-invocation` (identical to Codex's, `zt-` ids, terminal set `completed|failed|cancelled`), fetch with `"$ZDISPATCH" result zt-NNNN`, parse line 1 exactly as for Codex.

Dispatch, wait terminal (GLM / Codex) or Agent completion (Claude subagent), fetch result.
````

**E37.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
- `NEEDS_CONTEXT` → provide the missing context and re-dispatch (Codex: `--resume-task <implementer-task-id>`; Claude subagent: fresh Agent call carrying the added context).
```

**Replace with:**

```text
- `NEEDS_CONTEXT` → provide the missing context and re-dispatch — append it to the body file as `## Added context`, then: GLM `"$ZDISPATCH" task --background --resume-task <zt-id>` with a follow-up dispatch file; Codex `--resume-task <implementer-task-id>`; Claude subagent: fresh Agent call carrying the added context.
```

**E38.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
    1. More context needed → re-dispatch implementer with added context, same effort.
    2. Needs more reasoning → Codex path: re-dispatch with `--resume-task <implementer-task-id>` at Sol xhigh (`--write --model gpt-6.1-sol --effort xhigh`). Claude path: upgrade from Sonnet `medium` to Opus `high`; if already Opus, hand back to user.
```

**Replace with:**

```text
    1. More context needed → resume the phase's channel with the added context (appended to the body file; GLM: `"$ZDISPATCH" task --background --resume-task <zt-id>`), same effort.
    2. Needs more reasoning → Codex Sol xhigh (`--write --model gpt-6.1-sol --effort xhigh`). GLM phase: **FRESH** Sol dispatch of the same operation — dispatch file `<name>.<seq>.sol.md` in the FRESH composition for its operation type (`implement`: the first-round body with the channel-switch notice, naming the GLM job id and the report file, after its opening paragraph, no re-brief; fix-type: re-brief opening + notice + body), the BLOCKED report appended to the body as `## Added context`. Luna phase (fallback or kill switch): `--resume-task <luna id>`. In both cases Sol becomes the phase's channel (ladder item 4). A phase already on Sol (risk-marked or escalated) → hand to the user — nothing above Sol. Claude path: upgrade from Sonnet `medium` to Opus `high`; if already Opus, hand back to user.
```

**E39.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
to edit the plan accordingly, re-run Step 2 on the plan change.
```

**Replace with:**

```text
to edit the plan accordingly, re-run Step 2 on the plan change, then the `risk_phases` re-derivation (Step 2.5) before the revised plan is committed.
```

**E40.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
Never force the same model to retry without changes.
```

**Replace with:**

```text
Never force the same model to retry without changes.

**GLM infrastructure failures** — the job reached `failed` (the Monitor loop reported it; read the class with `"$ZDISPATCH" status <zt-id> --json | python3 -c "import json,sys; print(json.load(sys.stdin)['job']['errorClass'])"`) or `cancelled`. First match wins:

1. `errorClass ∈ {quota, auth, model-not-selected}` → retry is pointless. Set `glm=down` for the session (state line + marker), announce (`GLM channel failed (errorClass=<class>) — Ф<id> falls back to Luna max; GLM is off for this session.`), re-dispatch the **same operation** on Codex Luna max FRESH — dispatch file `<name>.<seq>.luna.md` in the FRESH composition for its operation type (`implement`: body + notice; fix-type: re-brief opening + notice + body; the tree may hold partial GLM work).
2. `errorClass ∈ {timeout, crash, launch, malformed}` → ONE retry of the same operation on GLM: `"$ZDISPATCH" task --background --fresh --prompt-file "$dir"/prompts/<name>.<seq>.glm.md` (same FRESH composition). The retry fails again with any class → Luna per item 1's mechanics (announce; set `glm=down` only if the second class is in item 1's set).
3. `cancelled` → report to the user and wait, exactly as for Codex.

A `completed` job whose line 1 is not a valid token is **not** an infrastructure failure: apply "## Verdict parsing" step 3 (re-dispatch once with `--resume-task <zt-id>`). A wrapper exit 2 on `task` is a refused dispatch, not a job failure — fix the dispatch (wrong `--cwd`, missing prompt file, another job running, kill switch); a refusal naming `Info.plist`, the ZCode CLI or the provider config counts as a failed `doctor` (`glm=down`).

**Stale workspace reservation** — `"$ZDISPATCH" task` exits 2 with the stale message (its text contains `release-stale`; the wrapper never reclaims a stale reservation automatically). Mechanical rule, no judgment:
1. Run `"$ZDISPATCH" release-stale` (plus the task's `--cwd <worktree-path>` for a worktree track) **exactly once** — you are the single actor: never run it in parallel with any other `task` / `release-stale` / `cancel` for that workspace, and never delete `active.lock.*` files by hand.
2. It prints `released <workspace> generation <n>` → re-run the identical `task` command once (same dispatch file — the refused call spawned nothing and wrote no sidecar).
3. `release-stale` refuses (exit 2 or 1), or the re-run `task` is refused again → infrastructure failure of the GLM channel: re-dispatch the **same operation** on Codex Luna max FRESH per item 1's mechanics (announce the fallback; `glm=down` is not set — the failure is this workspace's reservation, not the channel), still subject to "one write task per working tree across both dispatchers", and tell the user the workspace reservation is stuck, quoting the wrapper's message.
```

- [ ] **Step 8: Edit `skills/dev-orchestrator/SKILL.md` — Step 3.5 gate stall, Step 4 fix rounds and review stall, Step 5 fixer**

**E41.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
- `GATE_FAIL` → do NOT start (or resume) the review loop. Dispatch the implementer (`--resume-task <implementer-task-id>`, or fresh-fallback) with the gate's failure report as the fix list — this is a gate-fix round, it does NOT increment the fused-review round counter. Cap: 2 consecutive gate-fix rounds without reaching `GATE_OK` → escalate to the user with the failure output.
```

**Replace with:**

````text
- `GATE_FAIL` → do NOT start (or resume) the review loop. Dispatch a gate-fix round (operation `gatefix r<N>`) on the phase's channel with the gate's failure report as the fix list (fix-round template): GLM `"$ZDISPATCH" task --background --resume-task <zt-id> --prompt-file "$dir"/prompts/gatefix-<id>-r<N>.<seq>.glm.md` (preamble prepended); Luna / Sol `--resume-task <task-id>`; a frontend-only phase, the Claude frontend implementer's follow-up template (fresh Agent call). A gate-fix round does NOT increment the fused-review round counter.
- **Gate stall — every non-frontend channel (GLM, Luna, Sol):** the second consecutive gate-fix round ends without `GATE_OK` → do **not** dispatch a third fix. Dispatch the gate-stall diagnosis — **at most once per phase**; a later stall on the same phase goes straight to the user — `Agent(subagent_type="general-purpose", model="opus", effort="high")` with this skeleton:

  ```
  You are diagnosing why a verification gate keeps failing after two fix attempts. Read the plan at <plan-path> (phase <id>), the implementer report at [REPORT_FILE] (all sections), and the two gate failure reports below. Do not modify files.

  Line 1 of your answer is exactly one token, first match wins:
  ENVIRONMENT — the failure is caused by the machine, not the code: missing or wrong toolchain, missing system dependency, a service (DB, broker) not running, network or infrastructure flake. On line 2 write exactly `fix-location: in-repo` if the remedy is a change to files inside the repository (package manifest, lockfile, in-repo config), otherwise exactly `fix-location: machine`.
  CODE — the code or tests are wrong in a way two attempts did not resolve; the phase needs stronger reasoning.
  CONTEXT — the implementer lacks information that exists (plan text, repo convention, a file it did not find); name it.

  Then: the evidence (file:line, command output), and for ENVIRONMENT the exact commands a human would run to fix the machine.

  ## Gate failure 1
  <verbatim>
  ## Gate failure 2
  <verbatim>
  ```

  Handling (one more round, then the user):
  - `ENVIRONMENT` + `fix-location: in-repo` → ONE more gate-fix round on the phase's channel with the diagnosis inlined.
  - `ENVIRONMENT` + `fix-location: machine` → **pause the phase**; report the diagnosis and the proposed commands to the user verbatim. Run none of them (machine state changes need consent). When the user confirms the environment is fixed, re-run the gate (not the fixer — the tree did not change) with the consecutive counter reset to 0; a `GATE_FAIL` there starts ordinary gate-fix rounds again, and because the diagnosis already ran once for this phase, a second stall goes to the user.
  - `CODE` → ONE gate-fix round on Sol xhigh (`--write --model gpt-6.1-sol --effort xhigh`), the diagnosis inlined: GLM phase → FRESH Sol, dispatch file `gatefix-<id>-r<N>.<seq>.sol.md` (FRESH fix-type composition: re-brief opening + notice + body); Luna phase (fallback or kill switch) → Sol resuming the Luna thread (`--resume-task <luna id>`, resume composition — plain body). In both cases Sol becomes the phase's channel. A phase already on Sol → the user directly (nothing above Sol).
  - `CONTEXT` → ONE more gate-fix round on the phase's channel with the named context added.
  - After that round: `GATE_OK` → Step 4; `GATE_FAIL` → the user, with both failure outputs and the diagnosis. Malformed diagnosis (line 1 not one of the three tokens) → the standard verdict-parsing re-dispatch, then the user.
- **Frontend-only phases** keep the old cap: 2 consecutive gate-fix rounds without `GATE_OK` → escalate to the user with the failure output.
````

**E42.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
when the phase carries SECURITY / DATA_LOSS materiality risks (per the plan's Risks section) or in round 4 of this fused loop
```

**Replace with:**

```text
when the phase is risk-marked (`risk_phases[<id>]` non-empty — Step 2.5) or in round 4 of this fused loop
```

**E43.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
  - **(c) Dispatch the fix round to the Codex implementer** (`--write --model gpt-6-luna --effort max`) with `--resume-task <implementer-task-id>` — the fixer continues its own implementation thread (full context retained; the control reviewer having run in between does not matter, the resume is thread-addressed). Use the fix-round template in `./implementer-prompt.md`: ledger path, `[REPORT_FILE]` (the fixer appends its `## Fix round <N>` section there), plus the open ACCEPTED / PARTIALLY_ACCEPTED items inline. For a frontend-only phase, dispatch the Claude frontend implementer's follow-up template instead (fresh Agent call, same ledger-derived list, same `[REPORT_FILE]` rules) — never Codex. `--resume-last` remains FORBIDDEN anywhere in Step 4 — positional resume would land in the control reviewer's read-only thread. If the implementer thread is unavailable (Claude-implemented phase, lost task id, stale job record), fall back to a FRESH task with the same template prefixed by the fresh-fallback re-brief block. Increment iteration counter.
```

**Replace with:**

```text
  - **(c) Dispatch the fix round (operation `fix r<N>`) on the phase's channel**, resuming the implementer's own thread or session (full context retained; the control reviewer having run in between does not matter, the resume is addressed by id): GLM `"$ZDISPATCH" task --background [--cwd …] --resume-task <zt-id> --prompt-file "$dir"/prompts/fix-<id>-r<N>.<seq>.glm.md` — the fix-round template with the preamble prepended (resume composition); Luna `--write --model gpt-6-luna --effort max --resume-task <task-id>`; Sol `--write --model gpt-6.1-sol --effort xhigh --resume-task <task-id>`. Use the fix-round template in `./implementer-prompt.md`: ledger path, `[REPORT_FILE]` (the fixer appends its `## Fix round <N>` section there), plus the open ACCEPTED / PARTIALLY_ACCEPTED items inline. For a frontend-only phase, dispatch the Claude frontend implementer's follow-up template instead (fresh Agent call, same ledger-derived list, same `[REPORT_FILE]` rules) — never GLM or Codex. `--resume-last` remains FORBIDDEN anywhere in Step 4 — positional resume would land in the control reviewer's read-only thread (the ZCode wrapper has no such flag at all). **Lost handle** (no `.id` sidecar, `status` does not know the id, or the wrapper refuses the resume) or a stale job record: the same operation FRESH on the same channel at the next seq, in the FRESH composition for its operation type (Step 3). Increment iteration counter.
  - **Review stall (GLM and Luna phases):** when fused-review **round 3** returns a non-empty combined BLOCKING list, the fixer for `## Fix round 3` is **Codex Sol xhigh** (`--write --model gpt-6.1-sol --effort xhigh`). GLM phase → FRESH Sol, dispatch file `fix-<id>-r3.<seq>.sol.md` (FRESH fix-type composition: re-brief opening + notice + body); the body's fix-round template carries the ledger path, the open ACCEPTED / PARTIALLY_ACCEPTED items inline, and the explicit instruction to read **every** `## Fix round` section already in `[REPORT_FILE]` so closed items are not redone (pass the path and the instruction; do not read or inline those sections — Rule 2). Luna phase (fallback or kill switch) → Sol resuming the Luna thread (`--resume-task <luna id>`, plain fix-round body — the thread already holds the history). In both cases Sol becomes the phase's channel and Sol's task id goes into `impl=`. Round 4's review proceeds as usual; the round cap (the next round would be 5) escalates to the user as before — Sol gets exactly one fix round inside the loop.
  - **Review stall on a phase already on Sol** (risk-marked, or escalated earlier in this phase): round 3 still BLOCKING → do **not** dispatch fix round 3; escalate to the user immediately with the same content as the round-cap escalation (diff, combined list, one-sentence impasse summary by an Opus `high` subagent). Nothing above Sol.
```

**E44.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
dispatch ONE fixer: a single Codex Luna max FRESH task (`--write --model gpt-6-luna --effort max`; no resume — the whole-plan fix wave has no single implementer thread) with the COMPLETE findings list
```

**Replace with:**

```text
dispatch ONE fixer (operation `final-fix`), chosen first match wins — kill switch active → Codex Luna max (`--write --model gpt-6-luna --effort max`); **the plan has any risk-marked phase** (any non-empty value in `risk_phases`) → Codex Sol xhigh (`--write --model gpt-6.1-sol --effort xhigh`) does the whole wave; `glm=down` → Codex Luna max; otherwise → GLM via `$ZDISPATCH` (`--fresh`, preamble prepended). Always FRESH, no resume — the whole-plan fix wave has no single implementer thread; body `$dir/prompts/final-fix-r1.md`, dispatch file `final-fix-r1.<seq>.<channel>.md` in the FRESH fix-type composition (Step 3); an infrastructure failure of the wave follows the retry / channel-switch rule (the re-dispatch is still the whole-plan wave with the same findings list and the same report file). The fixer gets the COMPLETE findings list
```

- [ ] **Step 9: Edit `skills/dev-orchestrator/SKILL.md` — multi-phase, parallel groups, reporting, Red Flags, templates**

**E45.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
- Codex reported `BLOCKED` that more context cannot resolve.
```

**Replace with:**

```text
- The implementer reported `BLOCKED` that more context cannot resolve.
```

**E46.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
(prod schema migration, external API writes, destructive git ops) — flag before dispatching Codex.
```

**Replace with:**

```text
(prod schema migration, external API writes, destructive git ops) — flag before dispatching the implementer.
```

**E47.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
Routing per track is unchanged: frontend-only phase → Claude frontend implementer subagent (Opus `high` for new UI, Sonnet `medium` for tweaks); everything else → Codex implementer (Luna max). Codex+Codex, Codex+Claude, Claude+Claude are all valid pairs.
```

**Replace with:**

```text
Routing per track = the channel ladder per phase (Step 3): frontend-only phase → Claude frontend implementer subagent (Opus `high` for new UI, Sonnet `medium` for tweaks); everything else → GLM, Luna or Sol as the ladder decides. GLM+GLM, GLM+Luna, GLM+Claude, Codex+Codex, Codex+Claude, Claude+Claude are all valid pairs. **GLM concurrency:** when `zcode-invocation` records `GLM concurrency: 1` (two ZCode processes cannot run at once), a group runs at most **one** GLM track. First resolve each track's channel by the ladder as usual (frontend-only → Claude, risk-marked → Sol, kill switch / `glm=down` / earlier hand-off → Luna); only when **both** tracks resolved to GLM, the track whose phase is listed first in the frontmatter keeps GLM and the other takes Luna max for the duration of the group, announced in the group's setup line. A pair where at most one track resolved to GLM is unaffected.
```

**E48.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
3. No other Codex write task currently running.
```

**Replace with:**

```text
3. No other write task running on **either** dispatcher — check `"$DISPATCH" status` and `"$ZDISPATCH" status`. The width cap (max 2 concurrent write tasks) counts across both dispatchers.
```

**E49.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
   - Codex: standard implementer dispatch plus `--cwd <worktree-path>` (`--prompt-file` as usual). In the prompt, `Repository root:` = the worktree path.
```

**Replace with:**

```text
   - GLM / Codex: standard implementer dispatch on the track's channel plus `--cwd <worktree-path>` (`--prompt-file` as usual; the dispatch file lives in the track's own `$dir/prompts/`). In the prompt, `Repository root:` = the worktree path.
```

**E50.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
3. **Poll both.** Codex via Monitor (remember `--cwd <worktree-path>` on every `status`/`result` call); Claude via Agent completion.
```

**Replace with:**

```text
3. **Poll both.** GLM / Codex via Monitor — every `task` / `status` / `result` / `cancel` for a track carries the track's `--cwd <worktree-path>` on whichever dispatcher owns the job (the job lives in that worktree's workspace); Claude via Agent completion.
```

**E51.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
   - `INTEGRATION_FAIL` → dispatch the Codex implementer (fresh, main tree, `--write --model gpt-6-luna --effort max`) with the failure report + plan path + both phase ids to repair the integration; re-run the check. Cap 2 repair rounds, then escalate.
```

**Replace with:**

```text
   - `INTEGRATION_FAIL` → dispatch the integration repairer (operation `repair r<N>`, FRESH, main tree) with the failure report + plan path + both phase ids to repair the integration; re-run the check. The repairer is chosen like the Step 5 fixer, first match wins: kill switch active → Codex Luna max; either phase of the group risk-marked (non-empty `risk_phases` entry) → Codex Sol xhigh; `glm=down` → Codex Luna max; otherwise → GLM via `$ZDISPATCH` (`--fresh`). Body `$dir/prompts/repair-<G>-r<N>.md`; round 2 of the repair resumes the repairer (`--resume-task` on its own dispatcher). Cap 2 repair rounds, then escalate.
```

**E52.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
**State line during a group:** append `tracks=<id>:<step>-r<k>,<id>:<step>-r<k>` (e.g. `tracks=Ф2:4-r1,Ф3:3`).
```

**Replace with:**

```text
**State line during a group:** replace `impl=` with `tracks=<id>:<step>-r<k>@<impl>,<id>:<step>-r<k>@<impl>` (e.g. `tracks=Ф2:4-r1@glm:zt-0003,Ф3:3@luna:task-0011`).
```

**E53.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
- Each loop iteration: one line with verdict summary. Example: `Opus review round 2/4: REVIEW_BLOCKING (3 items). Dispatching the fixer (Luna max).`
```

**Replace with:**

```text
- Each loop iteration: one line with verdict summary. Example: `Opus review round 2/4: REVIEW_BLOCKING (3 items). Dispatching the fixer (GLM-5.3-Flash max).`
- **Implementer channel lines are mandatory, one line each:** `Ф2 → GLM-5.3-Flash max via ZCode (zt-0007).` · `GLM channel failed (errorClass=quota) — Ф2 falls back to Luna max (task-0012); GLM off for this session.` · `Ф3 is risk-marked (DATA_LOSS) → Sol 6.1 xhigh (task-0013).` · `Ф2 review round 3 still BLOCKING → fix round 3 on Sol 6.1 xhigh (task-0015).` · `Gate stalled on Ф2 → Opus diagnosis: ENVIRONMENT (machine) — paused; commands for you below.`
```

**E54.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
The Step 2 plan review and control review rounds 2+ stay FRESH by design.
```

**Replace with:**

```text
The Step 2 plan review and control review rounds 2+ stay FRESH by design. Ids are per dispatcher — a `zt-` id never goes to `$DISPATCH`, a `task-` id never to `$ZDISPATCH`.
```

**E55.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
- Dispatch one fixer per finding in Step 5 — the final-review fix wave is ONE Codex task with the complete list.
```

**Replace with:**

```text
- Dispatch one fixer per finding in Step 5 — the final-review fix wave is ONE implementer task with the complete list.
```

**E56.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
- Let a nit block progress.
```

**Replace with:**

```text
- Let a nit block progress.
- **Extract tokens from `~/.zcode`, read `credentials.json`, or call the Z.ai API / SDK directly** — it violates the Coding Plan terms. The ZCode CLI through `$ZDISPATCH` is the only channel.
- **Give GLM a SECURITY / DATA_LOSS phase** — risk-marked phases run on Sol in the Codex sandbox.
- **Run two write tasks in one working tree across both dispatchers**, or more than 2 write tasks in total — `status` on **both** dispatchers before every dispatch.
- **Switch implementer channels silently** — every fallback and escalation is one announced line ("## Reporting cadence").
- **Call `zcode -p` (or `node zcode.cjs`) bypassing the wrapper** — the wrapper is what guarantees the env, the identification headers, the git-tree guard and the job record.
- **Change ZCode settings, plugins or login on the user's behalf** — logging in (`zcode login zai`), enabling or disabling plugins are user actions; ask, never do. The wrapper's own personal provider config (the model pin) is the only ZCode-format file it writes.
```

**E57.** **Find** in `skills/dev-orchestrator/SKILL.md`:

```text
- `./implementer-prompt.md` — Codex Luna max, implementation + fix rounds (Step 3 / Step 4, non-frontend phases)
```

**Replace with:**

```text
- `./implementer-prompt.md` — GLM-5.3-Flash max via ZCode (default) / Codex Luna max (fallback) / Codex Sol xhigh (risk-marked phases, escalation), implementation + fix rounds (Step 3 / 3.5 / 4 / 5, non-frontend phases); carries the ZCode preamble and the channel-switch notice
```

- [ ] **Step 10: Edit `skills/codex-invocation/SKILL.md`**

**C1.** **Find** in `skills/codex-invocation/SKILL.md`:

```text
# Codex invocation (codex-dispatch wrapper, background-only)
```

**Replace with:**

```text
# Codex invocation (codex-dispatch wrapper, background-only)

> GLM-5.3-Flash through Z.ai's ZCode CLI — the dev-orchestrator default implementer — has its own wrapper and skill: see `zcode-invocation`. This skill covers Codex only.
```

**C2.** **Find** in `skills/codex-invocation/SKILL.md`:

```text
| Implementation + fix rounds (Step 3 / 4 / 5, integration repair) | `--model gpt-6-luna --effort max --write` |
| Reasoning escalation on BLOCKED | `--model gpt-6.1-sol --effort xhigh --write` (resume the implementer thread) |
```

**Replace with:**

```text
| Availability-fallback implementation (Luna max) — GLM channel down or kill switch; implementation + fix rounds (dev-orchestrator Step 3 / 3.5 / 4 / 5, integration repair) | `--model gpt-6-luna --effort max --write` |
| Risk-marked phases (SECURITY / DATA_LOSS) and reasoning escalation (Sol xhigh) | `--model gpt-6.1-sol --effort xhigh --write` (GLM phase: FRESH; Luna phase: resume the Luna thread) |
```

**C3.** **Find** in `skills/codex-invocation/SKILL.md`:

```text
Astra is the reviewer model, Luna the implementer, Sol 6.1 the escalation and ad-hoc default.
```

**Replace with:**

```text
Astra is the reviewer model, Luna the availability-fallback implementer (GLM via ZCode is the default — `zcode-invocation`), Sol 6.1 the risk-phase implementer, the escalation and the ad-hoc default.
```

**C4.** **Find** in `skills/codex-invocation/SKILL.md`:

```text
implementation = luna/max; escalation = sol 6.1/xhigh;
```

**Replace with:**

```text
fallback implementation = luna/max; risk-phase implementation and escalation = sol 6.1/xhigh;
```

**C5.** **Find** in `skills/codex-invocation/SKILL.md`:

```text
- **Width cap: max 2 concurrent write tasks.** Subscription rate limits and orchestrator attention both degrade beyond that.
```

**Replace with:**

```text
- **Width cap: max 2 concurrent write tasks, counted across both dispatchers** — ZCode jobs (`"$ZDISPATCH" status`) count too. Subscription rate limits and orchestrator attention both degrade beyond that.
```

- [ ] **Step 11: Edit the reviewer prompts (family-neutral; Step 5 fixer)**

**R1.** **Find** in `skills/dev-orchestrator/opus-review-prompt.md`:

```text
Use when Sonnet orchestrator needs Opus to review the implementer's (Codex Luna) work on a phase.
```

**Replace with:**

```text
Use when Sonnet orchestrator needs Opus to review the implementer's work on a phase (GLM, Codex Luna or Sol, or the Claude frontend implementer — do not assume the family).
```

**R2.** **Find** in `skills/dev-orchestrator/opus-review-prompt.md`:

```text
Do NOT trust Codex's self-report
```

**Replace with:**

```text
Do NOT trust the implementer's self-report
```

**R3.** **Find** in `skills/dev-orchestrator/final-review-prompt.md`:

```text
Tell the user the final review ran on Astra and that it is same-family with the Luna-written code (a declared exception to the family rule) — never a silent substitution.
```

**Replace with:**

```text
Tell the user the final review ran on Astra and — when Codex (Luna or Sol) implemented any phase of the branch — that it is same-family with the implementer's code (a declared exception to the family rule) — never a silent substitution.
```

**R4.** **Find** in `skills/dev-orchestrator/final-review-prompt.md`:

```text
then dispatch ONE fixer — a single Codex Luna max FRESH task (`--write --model gpt-6-luna --effort max`; no resume — the whole-plan fix wave has no single implementer thread) — with the COMPLETE findings list
```

**Replace with:**

```text
then dispatch ONE fixer — a single FRESH implementer task on the channel SKILL.md Step 5 picks (kill switch → Luna max; any risk-marked phase → Sol xhigh; `glm=down` → Luna max; otherwise GLM via `$ZDISPATCH`; no resume — the whole-plan fix wave has no single implementer thread) — with the COMPLETE findings list
```

**R5.** **Find** in `skills/dev-orchestrator/codex-control-review-prompt.md`:

```text
and it must never continue the fixer's (Codex Luna's) thread
```

**Replace with:**

```text
and it must never continue the fixer's thread or session
```

- [ ] **Step 12: Run the structural check and both suites (pass)**

Run the Step 1 block again. Expected: last line `ALL CHECKS PASSED`, no `MISSING` / `STALE` lines.
Run: `bash tests/test-zcode-dispatch.sh && bash tests/test-sdd-scripts.sh`
Expected: both end with `PASS`.

- [ ] **Step 13: Commit the phase**

```bash
git add skills/zcode-invocation/SKILL.md skills/dev-orchestrator/SKILL.md skills/dev-orchestrator/implementer-prompt.md \
  skills/codex-invocation/SKILL.md skills/dev-orchestrator/opus-review-prompt.md \
  skills/dev-orchestrator/final-review-prompt.md skills/dev-orchestrator/codex-control-review-prompt.md
git commit -m "feat(dev-orchestrator): route non-frontend phases to GLM via ZCode with Luna fallback and Sol escalation"
```

## Ф4: Release 0.8.0 — manifest, READMEs, plugin README, README art

**Executor:** default non-frontend route (Codex implementer). Docs only. `README.ru.md` mirrors `README.md` section by section. The SVGs are touched only because their text names Luna as the builder (spec §6.4).

**Files in this phase:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `README.md`
- Modify: `README.ru.md`
- Modify: `PLUGIN_README.md`
- Modify: `assets/readme/hero-en.svg`
- Modify: `assets/readme/hero-ru.svg`
- Modify: `assets/readme/workflow-en.svg`
- Modify: `assets/readme/workflow-ru.svg`

**Interfaces:**
- Consumes: the skill `skills/zcode-invocation/SKILL.md` (name `zcode-invocation`); `bin/zcode-dispatch` with the command surface of Contract C1 (verbs `task`, `status`, `result`, `cancel`, `release-stale`, `doctor`, `doctor --probe`; start line `ZCode Task started in the background as zt-NNNN`; exit codes 0/1/2), job records per Contract C2 under the layout of Contract C3, errorClass set `timeout | crash | model-not-selected | auth | quota | launch | malformed`; the test suite `tests/test-zcode-dispatch.sh`.
- Produces: plugin version `0.8.0` (manifest, both READMEs, `PLUGIN_README.md`, hero badges); the README paragraphs Ф5 appends to — `README.md` paragraph starting "`max` is reserved for the implementers GLM and Luna" and `README.ru.md` paragraph starting "`max` зарезервирован за имплементерами GLM и Luna".

- [ ] **Step 1: Write the release check and run it (fails)**

Run from the repo root:

```bash
fails=0
need() { grep -qF -- "$2" "$1" || { echo "MISSING in $1: $2"; fails=$((fails+1)); }; }
none() { if grep -qF -- "$2" "$1"; then echo "STALE in $1: $2"; fails=$((fails+1)); fi; }
node -e 'const p = JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json", "utf8")); process.exit(p.version === "0.8.0" && p.keywords.includes("glm") && p.keywords.includes("zcode") && p.description.includes("ZCode") ? 0 : 1)' \
  || { echo "plugin.json: version/keywords/description"; fails=$((fails+1)); }
for f in .claude-plugin/plugin.json README.md README.ru.md PLUGIN_README.md assets/readme/hero-en.svg assets/readme/hero-ru.svg; do none "$f" '0.7.0'; done
need README.md 'version-0.8.0'; need README.ru.md 'version-0.8.0'
need PLUGIN_README.md 'Current repo/plugin version: `0.8.0`.'
need README.md '**Terms-respecting GLM access**'; need README.ru.md '**Доступ к GLM по правилам Z.ai**'
need README.md '| `zcode-invocation` |'; need README.ru.md '| `zcode-invocation` |'
need README.md '| `bin/zcode-dispatch` |'; need README.ru.md '| `bin/zcode-dispatch` |'
need README.md 'bash tests/test-zcode-dispatch.sh'; need README.ru.md 'bash tests/test-zcode-dispatch.sh'
need README.md '| Implementer, fix rounds, final fix wave | GLM-5.3-Flash'
need README.ru.md '| Имплементер, fix-раунды, финальная волна фиксов | GLM-5.3-Flash'
need README.md '`max` is reserved for the implementers GLM and Luna'
need README.ru.md '`max` зарезервирован за имплементерами GLM и Luna'
need PLUGIN_README.md '**`zcode-invocation`**'
need PLUGIN_README.md 'superpowers-strigov-ver-zcode'
none README.md 'One consolidated Luna fix wave'; none README.ru.md 'волна фиксов Luna.'
for f in assets/readme/workflow-en.svg assets/readme/workflow-ru.svg; do none "$f" '03 / LUNA'; need "$f" '03 / GLM'; done
for f in assets/readme/hero-en.svg assets/readme/hero-ru.svg; do none "$f" '>Luna</text>'; need "$f" '>GLM</text>'; need "$f" '>v0.8.0</text>'; done
for f in assets/readme/*.svg; do xmllint --noout "$f" || { echo "SVG not well-formed: $f"; fails=$((fails+1)); }; done
[ "$fails" -eq 0 ] && echo "ALL CHECKS PASSED" || echo "FAILED CHECKS: $fails"
```

Expected now: `MISSING` / `STALE` lines, last line `FAILED CHECKS: <n>`.

- [ ] **Step 2: Edit `.claude-plugin/plugin.json`**

**P1.** **Find** in `.claude-plugin/plugin.json`:

```text
Codex GPT-6 Luna max implements with GPT-6.1 Sol xhigh as reasoning escalation and Opus high as BLOCKED diagnosis;
```

**Replace with:**

```text
GLM-5.3-Flash max implements non-frontend phases through Z.ai's own ZCode CLI (bin/zcode-dispatch, zcode-invocation skill) with Codex GPT-6 Luna max as availability fallback, GPT-6.1 Sol xhigh for SECURITY/DATA_LOSS phases and as reasoning escalation, and Opus high as BLOCKED / gate-stall diagnosis;
```

**P2.** **Find** in `.claude-plugin/plugin.json`:

```text
Plus codex-invocation recipe (incl. an ad-hoc second-opinion template), architecture-memory
```

**Replace with:**

```text
Plus codex-invocation recipe (incl. an ad-hoc second-opinion template), zcode-invocation recipe, architecture-memory
```

**P3.** **Find** in `.claude-plugin/plugin.json`:

```text
  "version": "0.7.0",
```

**Replace with:**

```text
  "version": "0.8.0",
```

**P4.** **Find** in `.claude-plugin/plugin.json`:

```text
    "codex",
```

**Replace with:**

```text
    "codex",
    "glm",
    "zcode",
```

- [ ] **Step 3: Edit `README.md`**

**N1.** **Find** in `README.md`:

```text
  <img alt="Version 0.7.0" src="https://img.shields.io/badge/version-0.7.0-7c8cff?style=flat-square">
```

**Replace with:**

```text
  <img alt="Version 0.8.0" src="https://img.shields.io/badge/version-0.8.0-7c8cff?style=flat-square">
```

**N2.** **Find** in `README.md`:

````text
```bash
npm install -g @openai/codex
codex login
```

### 2. Install the plugin
````

**Replace with:**

````text
```bash
npm install -g @openai/codex
codex login
```

Optional — the default implementer, **GLM-5.3-Flash via Z.ai's ZCode**: install [ZCode.app](https://github.com/zai-org/ZCode) into `/Applications`, then log its CLI in once with your GLM Coding Plan account via `zcode login zai` (the exact command is in the `zcode-invocation` skill, "One-time setup"). Without it, `zcode-dispatch doctor` fails and the pipeline implements on Codex Luna `max` instead — announced, never silent.

### 2. Install the plugin
````

**N3.** **Find** in `README.md`:

```text
3. **Build** — Luna `max` implements one phase and writes a report. Sol 6.1 `xhigh` continues the same thread when an Opus diagnosis says deeper reasoning is required.
```

**Replace with:**

```text
3. **Build** — GLM-5.3-Flash `max` implements one phase through Z.ai's own ZCode CLI and writes a report. Codex Luna `max` takes over when the GLM channel is down or switched off; Sol 6.1 `xhigh` implements SECURITY/DATA_LOSS phases from the start and takes over when an Opus diagnosis, a stalled gate or a third blocked review round calls for deeper reasoning.
```

**N4.** **Find** in `README.md`:

```text
One consolidated Luna fix wave is allowed before the final verdict.
```

**Replace with:**

```text
One consolidated fix wave is allowed before the final verdict.
```

**N5.** **Find** in `README.md`:

```text
Every Codex continuation is thread-addressed with `--resume-task <task-id>`.
```

**Replace with:**

```text
Every implementer continuation is addressed by id with `--resume-task` — `task-…` for Codex threads, `zt-…` for ZCode sessions.
```

**N6.** **Find** in `README.md`:

```text
| Implementer, fix rounds, final fix wave | GPT-6 Luna · `max` |
| Reasoning escalation (BLOCKED) | GPT-6.1 Sol · `xhigh`, same thread |
```

**Replace with:**

```text
| Implementer, fix rounds, final fix wave | GLM-5.3-Flash · `max` via Z.ai's ZCode CLI |
| Availability fallback (GLM down or switched off) | GPT-6 Luna · `max` |
| SECURITY/DATA_LOSS phases, reasoning escalation | GPT-6.1 Sol · `xhigh` |
```

**N7.** **Find** in `README.md`:

```text
| BLOCKED diagnosis, impasse summaries | Claude Opus · `high` |
```

**Replace with:**

```text
| BLOCKED and gate-stall diagnosis, impasse summaries | Claude Opus · `high` |
```

**N8.** **Find** in `README.md`:

```text
`max` is reserved for Luna (or used when the user asks for it by name);
```

**Replace with:**

```text
`max` is reserved for the implementers GLM and Luna (or used when the user asks for it by name);
```

**N9.** **Find** in `README.md`:

```text
- **Isolated parallelism** — plan-marked independent phases may run in separate worktrees, with a hard concurrency width of two.
```

**Replace with:**

```text
- **Isolated parallelism** — plan-marked independent phases may run in separate worktrees, with a hard concurrency width of two.
- **Terms-respecting GLM access** — GLM is reached only through Z.ai's own ZCode CLI with truthful client identification; no raw API, no token extraction; GLM never receives SECURITY / DATA_LOSS phases and runs unsandboxed only inside a git tree under the preamble's restrictions.
```

**N10.** **Find** in `README.md`:

```text
| `codex-invocation` | Reliable background Codex dispatch through the vendored companion runtime |
```

**Replace with:**

```text
| `codex-invocation` | Reliable background Codex dispatch through the vendored companion runtime |
| `zcode-invocation` | Background GLM-5.3-Flash dispatch through Z.ai's ZCode CLI: setup, doctor/probe, Monitor loop, failure handling |
```

**N11.** **Find** in `README.md`:

```text
| `bin/sdd-workspace` | Resolves isolated per-plan scratch workspaces |
```

**Replace with:**

```text
| `bin/sdd-workspace` | Resolves isolated per-plan scratch workspaces |
| `bin/zcode-dispatch` | ZCode CLI job wrapper: task/status/result/cancel/release-stale/doctor with pinned model, mode and client identification; `release-stale` frees a workspace reservation left by a crashed job, after verifying it is dead |
```

**N12.** **Find** in `README.md`:

```text
│   ├── review-package               # Reviewer-ready diff package generator
│   └── sdd-workspace                # Per-plan scratch workspace resolver
```

**Replace with:**

```text
│   ├── review-package               # Reviewer-ready diff package generator
│   ├── sdd-workspace                # Per-plan scratch workspace resolver
│   ├── zcode-dispatch               # ZCode CLI job wrapper (shim)
│   └── lib/zcode-dispatch.mjs       # ZCode job runner, records, doctor
```

**N13.** **Find** in `README.md`:

```text
│   ├── codex-invocation/
```

**Replace with:**

```text
│   ├── codex-invocation/
│   ├── zcode-invocation/
```

**N14.** **Find** in `README.md`:

```text
├── tests/test-sdd-scripts.sh        # Workspace/package integration tests
```

**Replace with:**

```text
├── tests/test-sdd-scripts.sh        # Workspace/package integration tests
├── tests/test-zcode-dispatch.sh     # ZCode wrapper tests (stubbed CLI)
```

**N15.** **Find** in `README.md`:

````text
Run the integration suite:

```bash
bash tests/test-sdd-scripts.sh
```
````

**Replace with:**

````text
Run the test suites:

```bash
bash tests/test-sdd-scripts.sh
bash tests/test-zcode-dispatch.sh
```
````

- [ ] **Step 4: Edit `README.ru.md` (mirror)**

**U1.** **Find** in `README.ru.md`:

```text
  <img alt="Версия 0.7.0" src="https://img.shields.io/badge/version-0.7.0-7c8cff?style=flat-square">
```

**Replace with:**

```text
  <img alt="Версия 0.8.0" src="https://img.shields.io/badge/version-0.8.0-7c8cff?style=flat-square">
```

**U2.** **Find** in `README.ru.md`:

````text
```bash
npm install -g @openai/codex
codex login
```

### 2. Установите плагин
````

**Replace with:**

````text
```bash
npm install -g @openai/codex
codex login
```

Необязательно — имплементер по умолчанию, **GLM-5.3-Flash через ZCode от Z.ai**: установите [ZCode.app](https://github.com/zai-org/ZCode) в `/Applications` и один раз войдите в его CLI под аккаунтом GLM Coding Plan через `zcode login zai` (точная команда — в скилле `zcode-invocation`, раздел «One-time setup»). Без этого `zcode-dispatch doctor` не проходит, и пайплайн реализует фазы на Codex Luna `max` — с объявлением, никогда молча.

### 2. Установите плагин
````

**U3.** **Find** in `README.ru.md`:

```text
3. **Реализация** — Luna `max` реализует одну фазу и пишет отчёт. Sol 6.1 `xhigh` продолжает тот же тред, если диагностика Opus говорит, что нужно более глубокое reasoning.
```

**Replace with:**

```text
3. **Реализация** — GLM-5.3-Flash `max` реализует одну фазу через собственный ZCode CLI от Z.ai и пишет отчёт. Codex Luna `max` подхватывает работу, если канал GLM недоступен или выключен; Sol 6.1 `xhigh` с самого начала реализует фазы SECURITY/DATA_LOSS и подхватывает работу, когда диагностика Opus, застрявший гейт или третий заблокированный раунд ревью требуют более глубокого reasoning.
```

**U4.** **Find** in `README.ru.md`:

```text
До финального вердикта разрешена одна объединённая волна фиксов Luna.
```

**Replace with:**

```text
До финального вердикта разрешена одна объединённая волна фиксов.
```

**U5.** **Find** in `README.ru.md`:

```text
Каждое продолжение Codex адресуется через `--resume-task <task-id>`.
```

**Replace with:**

```text
Каждое продолжение имплементера адресуется по id через `--resume-task` — `task-…` для тредов Codex, `zt-…` для сессий ZCode.
```

**U6.** **Find** in `README.ru.md`:

```text
| Имплементер, fix-раунды, финальная волна фиксов | GPT-6 Luna · `max` |
| Эскалация reasoning (BLOCKED) | GPT-6.1 Sol · `xhigh`, тот же тред |
```

**Replace with:**

```text
| Имплементер, fix-раунды, финальная волна фиксов | GLM-5.3-Flash · `max` через ZCode CLI от Z.ai |
| Резерв по доступности (GLM недоступен или выключен) | GPT-6 Luna · `max` |
| Фазы SECURITY/DATA_LOSS, эскалация reasoning | GPT-6.1 Sol · `xhigh` |
```

**U7.** **Find** in `README.ru.md`:

```text
| Диагностика BLOCKED, сводка по тупику (impasse) | Claude Opus · `high` |
```

**Replace with:**

```text
| Диагностика BLOCKED и застрявшего гейта, сводка по тупику (impasse) | Claude Opus · `high` |
```

**U8.** **Find** in `README.ru.md`:

```text
`max` зарезервирован за Luna (или по явному запросу пользователя);
```

**Replace with:**

```text
`max` зарезервирован за имплементерами GLM и Luna (или по явному запросу пользователя);
```

**U9.** **Find** in `README.ru.md`:

```text
- **Изолированный параллелизм** — независимые фазы из плана могут идти в отдельных worktree с жёстким лимитом параллелизма два.
```

**Replace with:**

```text
- **Изолированный параллелизм** — независимые фазы из плана могут идти в отдельных worktree с жёстким лимитом параллелизма два.
- **Доступ к GLM по правилам Z.ai** — GLM вызывается только через собственный ZCode CLI от Z.ai с честной идентификацией клиента; без прямого API и извлечения токенов; GLM никогда не получает фазы SECURITY / DATA_LOSS и работает без песочницы только внутри git-дерева под ограничениями преамбулы.
```

**U10.** **Find** in `README.ru.md`:

```text
| `codex-invocation` | Надёжный фоновый dispatch Codex через вендорный companion runtime |
```

**Replace with:**

```text
| `codex-invocation` | Надёжный фоновый dispatch Codex через вендорный companion runtime |
| `zcode-invocation` | Фоновый dispatch GLM-5.3-Flash через ZCode CLI от Z.ai: настройка, doctor/probe, цикл Monitor, обработка сбоев |
```

**U11.** **Find** in `README.ru.md`:

```text
| `bin/sdd-workspace` | Резолвит изолированные scratch-workspace для каждого плана |
```

**Replace with:**

```text
| `bin/sdd-workspace` | Резолвит изолированные scratch-workspace для каждого плана |
| `bin/zcode-dispatch` | Обёртка задач ZCode CLI: task/status/result/cancel/release-stale/doctor с закреплёнными моделью, режимом и идентификацией клиента; `release-stale` освобождает резервацию рабочего дерева, оставленную упавшей задачей, после проверки, что та мертва |
```

**U12.** **Find** in `README.ru.md`:

```text
│   ├── review-package               # Генератор diff-пакета для ревьюеров
│   └── sdd-workspace                # Резолвер scratch-workspace для плана
```

**Replace with:**

```text
│   ├── review-package               # Генератор diff-пакета для ревьюеров
│   ├── sdd-workspace                # Резолвер scratch-workspace для плана
│   ├── zcode-dispatch               # Обёртка задач ZCode CLI (shim)
│   └── lib/zcode-dispatch.mjs       # Раннер задач ZCode, записи, doctor
```

**U13.** **Find** in `README.ru.md`:

```text
│   ├── codex-invocation/
```

**Replace with:**

```text
│   ├── codex-invocation/
│   ├── zcode-invocation/
```

**U14.** **Find** in `README.ru.md`:

```text
├── tests/test-sdd-scripts.sh        # Интеграционные тесты workspace/package
```

**Replace with:**

```text
├── tests/test-sdd-scripts.sh        # Интеграционные тесты workspace/package
├── tests/test-zcode-dispatch.sh     # Тесты обёртки ZCode (CLI-заглушка)
```

**U15.** **Find** in `README.ru.md`:

````text
Запуск интеграционного suite:

```bash
bash tests/test-sdd-scripts.sh
```
````

**Replace with:**

````text
Запуск тестовых suite:

```bash
bash tests/test-sdd-scripts.sh
bash tests/test-zcode-dispatch.sh
```
````

- [ ] **Step 5: Edit `PLUGIN_README.md`**

**L1.** **Find** in `PLUGIN_README.md`:

```text
Current repo/plugin version: `0.7.0`.
```

**Replace with:**

```text
Current repo/plugin version: `0.8.0`.
```

**L2.** **Find** in `PLUGIN_README.md`:

```text
GPT-6 Luna max implement with GPT-6.1 Sol xhigh escalation
```

**Replace with:**

```text
GLM-5.3-Flash max implement via Z.ai's ZCode CLI (`bin/zcode-dispatch`) with GPT-6 Luna max availability fallback and GPT-6.1 Sol xhigh for SECURITY/DATA_LOSS phases and reasoning escalation (channel ladder per phase, `risk_phases` frontmatter map, gate-stall diagnosis)
```

**L3.** **Find** in `PLUGIN_README.md`:

```text
- **`architecture-memory`** — maintain
```

**Replace with:**

```text
- **`zcode-invocation`** — reference recipe for running GLM-5.3-Flash at `max` through Z.ai's own ZCode CLI via the `bin/zcode-dispatch` wrapper (`bin/lib/zcode-dispatch.mjs`): background jobs `zt-NNNN` + Monitor polling, `doctor` / `doctor --probe`, errorClass → action table, sandbox warning, compliance stance, kill switch `SP_IMPLEMENTER=luna`.
- **`architecture-memory`** — maintain
```

**L4.** **Find** in `PLUGIN_README.md`:

```text
The only external dependency is the standalone `codex` CLI (`npm install -g @openai/codex`) and a one-time `!codex login` per machine.
```

**Replace with:**

```text
The only external dependency is the standalone `codex` CLI (`npm install -g @openai/codex`) and a one-time `!codex login` per machine.

The GLM channel assumes `/Applications/ZCode.app` (macOS) with its embedded Agent CLI at `Contents/Resources/glm/zcode.cjs` — there is no `zcode` on `PATH` — run under the system `node` (major version at least `VERIFIED_NODE_MAJOR` in `bin/lib/zcode-dispatch.mjs`), with the CLI logged in once by the user (`zcode login zai`, see `zcode-invocation`). `bin/zcode-dispatch` keeps its job state and its own personal provider config (the model pin) under `~/.claude/plugins/data/superpowers-strigov-ver-zcode` and never touches `~/.zcode`. Without ZCode.app, `zcode-dispatch doctor` fails and dev-orchestrator implements on Codex Luna max (announced).
```

- [ ] **Step 6: Edit the README SVGs**

**V1.** **Find** in `assets/readme/hero-en.svg`:

```text
fill="#E7EBFA">v0.7.0</text>
```

**Replace with:**

```text
fill="#E7EBFA">v0.8.0</text>
```

**V2.** **Find** in `assets/readme/hero-en.svg`:

```text
font-weight="650">Luna</text>
```

**Replace with:**

```text
font-weight="650">GLM</text>
```

**V3.** **Find** in `assets/readme/hero-ru.svg`:

```text
fill="#E7EBFA">v0.7.0</text>
```

**Replace with:**

```text
fill="#E7EBFA">v0.8.0</text>
```

**V4.** **Find** in `assets/readme/hero-ru.svg`:

```text
font-weight="650">Luna</text>
```

**Replace with:**

```text
font-weight="650">GLM</text>
```

**V5.** **Find** in `assets/readme/workflow-en.svg`:

```text
>03 / LUNA</text>
```

**Replace with:**

```text
>03 / GLM</text>
```

**V6.** **Find** in `assets/readme/workflow-ru.svg`:

```text
>03 / LUNA</text>
```

**Replace with:**

```text
>03 / GLM</text>
```

- [ ] **Step 7: Run the release check and both suites (pass)**

Run the Step 1 block again. Expected: last line `ALL CHECKS PASSED`.
Run: `bash tests/test-zcode-dispatch.sh && bash tests/test-sdd-scripts.sh`
Expected: both end with `PASS`.

- [ ] **Step 8: Commit the phase**

```bash
git add .claude-plugin/plugin.json README.md README.ru.md PLUGIN_README.md \
  assets/readme/hero-en.svg assets/readme/hero-ru.svg assets/readme/workflow-en.svg assets/readme/workflow-ru.svg
git commit -m "chore(release): 0.8.0 — GLM-5.3-Flash via ZCode as default implementer"
```

## Ф5: Live acceptance and the 1.5× quota-bonus measurement

**Executor: the user, in a fresh plain Claude Code session** opened at the repo root (no `/dev`, no dev-orchestrator, no Opus or Codex calls) — spec §8.2 requires a session outside the protocol so that no other request falls inside the measurement window. Nothing else may use the Coding Plan between the baseline and the second reading (close agent sessions in the ZCode desktop app).

**Orchestrator handling:** do not dispatch an implementer for Ф5. Announce in one line: `Ф5 is the live acceptance — run it in a fresh Claude Code session (not /dev) following the plan's Ф5 steps 1–10, then tell me "Ф5 done".` Wait. When the user reports it done, the working tree holds Ф5's edits: run Step 3.5 (verification gate) on it, then Step 4 with `[REPORT_FILE]` = `$("$WS" docs/plans/2026-10-13-glm-zcode-implementer.md)/phase-Ф5-report.md`, then auto-commit (Step 11). Fix rounds, if any, go to the default route for these doc files.

**Files in this phase:**
- Modify: `docs/zcode-cli-findings.md`
- Modify: `skills/zcode-invocation/SKILL.md`
- Modify: `README.md`
- Modify: `README.ru.md`

**Interfaces:**
- Consumes: `bin/zcode-dispatch` with the command surface of Contract C1 (verbs `task`, `status`, `result`, `cancel`, `release-stale`, `doctor`, `doctor --probe`; start line `ZCode Task started in the background as zt-NNNN`; exit codes 0/1/2), job records per Contract C2 under the layout of Contract C3, errorClass set `timeout | crash | model-not-selected | auth | quota | launch | malformed`; `docs/zcode-cli-findings.md` with sections `## Go / no-go` (line `VERDICT: GO` | `VERDICT: NO-GO — <reason>`), `## U1 — …` through `## U11 — …`, and `## Inputs for later phases` filled for every key of Contract C7 (`VERDICT`, `MODEL_MECHANISM`, `SELECTION_PATH`, `PERSONAL_CONFIG_BASE`, `PINNED_SELECTION`, `RESUME_KEEPS_MODEL`, `REPORTED_MODEL_FIELD`, `USAGE_INPUT_FIELD`, `USAGE_CACHED_FIELD`, `USAGE_OUTPUT_FIELD`, `USAGE_REASONING_FIELD`, `CACHED_IS_SUBSET_OF_INPUT`, `PROMPT_TRANSPORT`, `MAX_PROMPT_BYTES`, `VERIFIED_APP_VERSION`, `VERIFIED_NODE_MAJOR`, `APP_VERSION_PLIST_KEY`, `DISALLOWED_TOOLS`, `GLM_CONCURRENCY`, `SESSION_SAVED_ON_SIGTERM`, `INTERFERING_PLUGINS`, `PATTERN_MODEL_NOT_SELECTED`, `PATTERN_AUTH`, `PATTERN_QUOTA`, `PATTERN_LAUNCH`); the protocol artifacts of Contract C8 (operations, body / dispatch / sidecar file names, session marker, state-line suffix, `risk_phases`, the `zcode-invocation` "Verified facts" lines including `- Quota bonus (1.5× in ZCode): not measured yet — live acceptance pending.`, gate-stall tokens); the ZCode preamble and channel-switch notice sections in `skills/dev-orchestrator/implementer-prompt.md`; the README paragraphs Ф5 appends to — `README.md` paragraph starting "`max` is reserved for the implementers GLM and Luna" and `README.ru.md` paragraph starting "`max` зарезервирован за имплементерами GLM и Luna".
- Produces: nothing

- [ ] **Step 1: Preconditions and `doctor` (no quota)**

Prerequisite (user, once per machine): the ZCode CLI is logged in with `zcode login zai`. The exact command is in `skills/zcode-invocation/SKILL.md` → "One-time setup", step 2. On this machine Ф1 Step 6a already did it, because the login identity is shared by every CLI run. Repeat it only when Step 3 fails with `model-selected: FAIL(model-not-selected)` or `FAIL(auth)`; then restart Ф5 from Step 1. The wrapper pins the model itself, so there is no model-selection step.

In the fresh session, from the repo root:

```bash
REPO="$(git rev-parse --show-toplevel)"; echo "REPO=$REPO"
ZDISPATCH="$(command -v zcode-dispatch || true)"
[ -z "$ZDISPATCH" ] && ZDISPATCH="$(ls -1d ~/.claude/plugins/cache/strigov-cc-plugins/superpowers-strigov-ver/*/bin/zcode-dispatch 2>/dev/null | sort -rV | head -1)"
[ -z "$ZDISPATCH" ] && ZDISPATCH="$(pwd)/bin/zcode-dispatch"
echo "ZDISPATCH=$ZDISPATCH"
"$ZDISPATCH" doctor
```

Expected: `ZDISPATCH=<repo>/bin/zcode-dispatch` (the dev tree — the marketplace install is still 0.7.0 without the wrapper), every check `ok` (`WARN node` tolerated), last line `doctor: ok`. A `WARN app-version` means ZCode.app updated since Ф1: stop and tell the orchestrator — the findings must be re-verified first (plan revision). Create the report file now and record every result below in it:

```bash
WSDIR="$("$REPO/bin/sdd-workspace" "$REPO/docs/plans/2026-10-13-glm-zcode-implementer.md")"; echo "REPORT=$WSDIR/phase-Ф5-report.md"
```

- [ ] **Step 2: Baseline reading (user)**

The user opens the Z.ai console → Plan Overview and reads the current credit deduction **now**, before any request of this run. Record the number and the local date/time in the report.

- [ ] **Step 3: Probe (request 1 of 3)**

```bash
"$ZDISPATCH" doctor --probe
```

Expected: `model-selected: ok`, `answers: ok`, `reported-model: GLM-5.3-Flash…` or `unreported` (with the U3 fallback in force), `probe: ok`, exit 0. Copy the `usage:` line into the report verbatim. `model-selected: FAIL(model-not-selected)` or `FAIL(auth)` means the CLI login is missing: stop, the user runs the one-time login (Step 1 prerequisite), then restart from Step 1. In the dev-orchestrator pipeline the same failure means Luna for the session (unchanged ladder).

- [ ] **Step 4: E2E first round in a throwaway repo (request 2 of 3)**

```bash
T="$(mktemp -d)/glm-e2e"; mkdir -p "$T/docs/plans"; git init -q -b main "$T"
cat > "$T/docs/plans/e2e.md" <<'EOF'
---
slug: e2e
created: 2026-10-13
status: in-progress
phases:
  - id: Ф1
    scope: "add src/add.mjs with add(a, b) and its node:test test"
    status: in-progress
---

# E2E smoke plan

## E2E phase Ф1 — add()

- Create `src/add.mjs` exporting `export function add(a, b) { return a + b; }`.
- Create `test/add.test.mjs` using `node:test` and `node:assert/strict`: `add(2, 3)` equals `5`.
- Run `node --test test/` and make sure it passes.
EOF
printf '{ "name": "glm-e2e", "type": "module", "private": true }\n' > "$T/package.json"
(cd "$T" && git add -A && git -c user.email=e@example.com -c user.name=e -c commit.gpgsign=false commit -qm init)
E2E_DIR="$(cd "$T" && "$REPO/bin/sdd-workspace" docs/plans/e2e.md)"; mkdir -p "$E2E_DIR/prompts"
echo "T=$T E2E_DIR=$E2E_DIR BASE=$(git -C "$T" rev-parse HEAD)"
```

Compose `$E2E_DIR/prompts/implement-Ф1-r1.001.glm.md` exactly as dev-orchestrator would: the fenced block under `## ZCode preamble (GLM dispatches only)` in `skills/dev-orchestrator/implementer-prompt.md` (verbatim, `[REPORT_FILE]` filled), a blank line, then the fenced block under `## First-round prompt template`, filled with: plan path `$T/docs/plans/e2e.md`; phase `Ф1`; scope `add src/add.mjs with add(a, b) and its node:test test`; repository root `$T`; style `plain Node ESM, no dependencies`; other phases done `none`; the parallel-track note line removed; `[REPORT_FILE]` = `$E2E_DIR/phase-Ф1-report.md` (absolute paths everywhere, no `<…>` left). Then:

```bash
"$ZDISPATCH" task --background --cwd "$T" --prompt-file "$E2E_DIR/prompts/implement-Ф1-r1.001.glm.md"
```

Expected: `ZCode Task started in the background as zt-0001`. Poll it with the Monitor loop from `skills/zcode-invocation/SKILL.md` (with `--cwd "$T"` on `status`), then:

```bash
"$ZDISPATCH" result zt-0001 --cwd "$T" | head -1
test -s "$E2E_DIR/phase-Ф1-report.md" && echo report-ok
git -C "$T" log --oneline | wc -l
git -C "$T" status --porcelain
(cd "$T" && node --test test/)
"$ZDISPATCH" status zt-0001 --cwd "$T" --json > "$T.e2e-job.json"
```

Expected: line 1 `DONE`; `report-ok`; `1` (nothing committed); `src/add.mjs` and `test/add.test.mjs` untracked; the test passes.

- [ ] **Step 5: Fix round (request 3 of 3)**

Write the body `$E2E_DIR/prompts/fix-Ф1-r1.md`: the fenced block under `## Fix-round prompt (round 2+ …)` in `implementer-prompt.md`, filled with `<base-sha>` = the `BASE` printed in Step 4, `[REPORT_FILE]` = `$E2E_DIR/phase-Ф1-report.md`, and AUTHORIZED_BLOCKERS replaced by exactly:

```
1. `E2E-B1` — `opus-review` — `src/add.mjs:1` — `add(a, b)` must throw `TypeError("add expects numbers")` when either argument is not a number; add a test for it in `test/add.test.mjs`.
```

Then read the `GLM resume:` line under "Verified facts" in `skills/zcode-invocation/SKILL.md`:

- `GLM resume: enabled` → dispatch file `$E2E_DIR/prompts/fix-Ф1-r1.002.glm.md` = the ZCode preamble block + the body as written (resume composition), and:

  ```bash
  "$ZDISPATCH" task --background --cwd "$T" --resume-task zt-0001 --prompt-file "$E2E_DIR/prompts/fix-Ф1-r1.002.glm.md"
  ```

  Criteria: `zt-0002` ends `completed`, line 1 `DONE`; its record's `sessionId` equals zt-0001's (`"$ZDISPATCH" status zt-0002 --cwd "$T" --json`); its final message refers to the existing implementation instead of re-exploring from scratch; `## Fix round 1` was appended to the same report file.
- `GLM resume: disabled` → dispatch file = the ZCode preamble + the body with its opening paragraph replaced by the fresh-fallback re-brief block (FRESH composition), and `"$ZDISPATCH" task --background --cwd "$T" --fresh --prompt-file "$E2E_DIR/prompts/fix-Ф1-r1.002.glm.md"`. Criteria: line 1 `DONE`; `## Fix round 1` appended to the same report file.

Then: `"$ZDISPATCH" status zt-0002 --cwd "$T" --json > "$T.fix-job.json"`.

- [ ] **Step 6: Second reading (user)**

Immediately, with nothing else run on the plan: the user reads the Plan Overview deduction again. Record it and the local date/time. Measured credits = second reading − baseline. Note whether the window fell in off-peak hours or on a weekend (those bill at 50 %).

- [ ] **Step 7: Compute the expected credits**

Take the four usage keys and `CACHED_IS_SUBSET_OF_INPUT` from `docs/zcode-cli-findings.md` → `## Inputs for later phases`, and the probe's `usage:` line from the report. Every billed counter U3 established is required for **all three** requests: input, cached and output always, plus reasoning when `USAGE_REASONING_FIELD` is not `none` (reasoning billed beside output). A required value that is missing — a `none` field, a `-` on the probe line, an absent key in a job's `usage` — is never treated as 0: the script lists it under `missing` and prints `result: "inconclusive"`.

```bash
node -e '
const fs = require("node:fs");
const [inF, caF, outF, reF, subset, probeLine, ...jobs] = process.argv.slice(1);
// Required counters (spec §8.2 / U3): input, cached, output always; reasoning only when U3 found it billed beside output.
const fields = { input: inF, cached: caF, output: outF, ...(reF === "none" ? {} : { reasoning: reF }) };
const missing = [];
if (subset !== "yes" && subset !== "no") missing.push(`CACHED_IS_SUBSET_OF_INPUT=${subset}`);
const get = (o, p) => p.split(".").reduce((a, k) => (a == null ? undefined : a[k]), o);
const m = /input=(\d+|-) cached=(\d+|-) output=(\d+|-)/.exec(probeLine) || [];
const fromLine = { input: m[1], cached: m[2], output: m[3] }; // the probe line carries no reasoning count
const rows = [];
const take = (src, read) => {
  const row = { src };
  for (const [key, path] of Object.entries(fields)) {
    const value = path === "none" ? undefined : read(key, path);
    if (typeof value === "number" && Number.isFinite(value)) row[key] = value;
    else missing.push(`${src}.${key}`); // never treated as 0
  }
  rows.push(row);
};
take("probe", (key) => (/^\d+$/.test(fromLine[key] ?? "") ? Number(fromLine[key]) : undefined));
for (const f of jobs) {
  const u = JSON.parse(fs.readFileSync(f, "utf8")).job.usage || {};
  take(f, (key, path) => get(u, path));
}
if (missing.length > 0) {
  console.log(JSON.stringify({ rows, missing, expectedCredits: null, result: "inconclusive" }, null, 2));
} else {
  let credits = 0;
  for (const r of rows) {
    const uncached = subset === "yes" ? r.input - r.cached : r.input;
    credits += (uncached * 2.3 + r.cached * 0.56 + (r.output + (r.reasoning ?? 0)) * 8) / 10000;
  }
  console.log(JSON.stringify({ rows, missing, expectedCredits: Number(credits.toFixed(3)), result: "computed" }, null, 2));
}
' "<USAGE_INPUT_FIELD>" "<USAGE_CACHED_FIELD>" "<USAGE_OUTPUT_FIELD>" "<USAGE_REASONING_FIELD>" "<CACHED_IS_SUBSET_OF_INPUT>" "<the probe usage line>" "$T.e2e-job.json" "$T.fix-job.json"
```

(Substitute the five findings values and the probe line before running; `none` is accepted for every field — for input, cached and output it counts as missing, for reasoning it means no separate counter.) If `result` is `inconclusive`, the bonus result is **inconclusive** — record the raw numbers and the `missing` list, do not compute a ratio (write `n/a` for the expected credits and the ratio in Step 8). Otherwise: if the window was off-peak or on a weekend, halve `expectedCredits`; ratio = expected / measured. Interpretation (spec §8.2 step 4), first match wins: ratio in 1.3–1.7 → **active**; ratio in 0.85–1.15 → **not active**; anything else → **inconclusive**. The probe's `usage:` line carries no reasoning count, so when `USAGE_REASONING_FIELD` is not `none` the probe's reasoning is a missing required value and the result is inconclusive (R13).

- [ ] **Step 8: Record the results**

Append to `docs/zcode-cli-findings.md`:

```markdown
## Live acceptance (<YYYY-MM-DD>, ZCode <short version>)

| Check | Result |
|---|---|
| `doctor` | <ok / the FAIL lines> |
| `doctor --probe` | <probe line, reported-model line, usage line> |
| E2E first round (zt-0001) | <line 1 token; report written yes/no; commits after = 1 yes/no; node --test pass/fail> |
| Fix round (zt-0002) | <resume or fresh; line 1 token; same sessionId yes/no/n.a.; `## Fix round 1` appended yes/no> |
| Baseline / second reading | <baseline> → <second> (measured <measured> credits); local time <time>, <peak / off-peak / weekend> |
| Expected credits | <expectedCredits> (formula of spec §8.2 step 4; halved: yes/no) |
| Ratio expected / measured | <ratio rounded to 2 decimals> → <active / not active / inconclusive> |

Usage objects: probe `<usage line>`; zt-0001 `<usage JSON>`; zt-0002 `<usage JSON>`.
```

and fill `U9 — Answer:` with the conclusion and ratio, `How verified:` with `live acceptance, this file`, `Holds for:` with the ZCode version.

In `skills/zcode-invocation/SKILL.md`, replace the line `- Quota bonus (1.5× in ZCode): not measured yet — live acceptance pending.` with exactly one of (date `YYYY-MM-DD`, version, ratio filled):

```text
- Quota bonus (1.5× in ZCode): active — measured <YYYY-MM-DD> on ZCode <version>, expected/measured credits = <ratio> (docs/zcode-cli-findings.md "Live acceptance").
- Quota bonus (1.5× in ZCode): not active — measured <YYYY-MM-DD> on ZCode <version>, expected/measured credits = <ratio> (docs/zcode-cli-findings.md "Live acceptance").
- Quota bonus (1.5× in ZCode): inconclusive — measured <YYYY-MM-DD> on ZCode <version>; raw numbers in docs/zcode-cli-findings.md "Live acceptance".
```

In `README.md`, append to the end of the paragraph that starts with "`max` is reserved for the implementers GLM and Luna" one sentence: `GLM quota: on <YYYY-MM-DD> the 1.5× ZCode quota bonus measured <active | not active | inconclusive> (expected/measured credits = <ratio>; details in docs/zcode-cli-findings.md).`
In `README.ru.md`, append to the paragraph that starts with "`max` зарезервирован за имплементерами GLM и Luna": `Квота GLM: <YYYY-MM-DD> бонус 1.5× для ZCode по замеру <активен | не активен | не определён> (ожидаемые/списанные кредиты = <ratio>; подробности в docs/zcode-cli-findings.md).`

- [ ] **Step 9: Check the edits**

```bash
grep -q '^## Live acceptance (' docs/zcode-cli-findings.md && echo findings-ok
! grep -q 'not measured yet' skills/zcode-invocation/SKILL.md && grep -q '^- Quota bonus (1.5× in ZCode): ' skills/zcode-invocation/SKILL.md && echo skill-ok
grep -q 'GLM quota: on ' README.md && grep -q 'Квота GLM: ' README.ru.md && echo readmes-ok
{ awk '/^## Live acceptance \(/,0' docs/zcode-cli-findings.md; grep -h 'Quota bonus (1.5' skills/zcode-invocation/SKILL.md; grep -h 'GLM quota: on ' README.md; grep -h 'Квота GLM: ' README.ru.md; } | grep -n '<[A-Za-z]' || echo no-unfilled
```

Expected: `findings-ok`, `skill-ok`, `readmes-ok`, `no-unfilled` (every `<…>` of Step 8 replaced by a measured value).

- [ ] **Step 10: Write the report and hand back**

Write the report file printed in Step 1 (`phase-Ф5-report.md`): each step's command, result and the numbers above. Leave every change uncommitted. Tell the orchestrator session `Ф5 done`.

- [ ] **Step 11: Commit the phase (orchestrator, after the gate and the fused review)**

```bash
git add -f docs/zcode-cli-findings.md
git add skills/zcode-invocation/SKILL.md README.md README.ru.md
git commit -m "docs(zcode): record live acceptance and quota-bonus measurement"
```
