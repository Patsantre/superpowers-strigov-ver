# GLM-5.3-Flash as the default implementer via Z.ai's ZCode CLI — design spec

- **Date:** 2026-10-13
- **Status:** draft — awaiting Codex Astra spec review, then user review
- **Plugin:** `superpowers-strigov-ver` 0.7.0 → **0.8.0**
- **Repository:** `/Users/strigov/Documents/Claude/projects-code/superpowers-strigov-ver`
- **Consumers:** the plan writer (Opus xhigh, `writing-plans` / dev-orchestrator Step 1) and the Codex Astra spec reviewer. Everything a plan needs is in this file; the few facts that cannot be known without running ZCode are collected in §10 "Open unknowns", each with a defined fallback.

---

## 1. Context and goal

### 1.1 User's request (verbatim)

> давай поразгоняем, можем ли мы в пайплайн добавить как-то вызов GLM  в харнессе от самой Z.ai?

Translation: "Let's push this further — can we somehow add a GLM call to the pipeline, through Z.ai's own harness?"

### 1.2 Goal

Add a third implementer channel to the dev-orchestrator pipeline: **GLM-5.3-Flash at reasoning effort `max`, driven exclusively through Z.ai's official coding-agent harness (the ZCode CLI embedded in `/Applications/ZCode.app`)**, and make it the default implementer for non-frontend phases. The user holds an individual GLM Coding Plan; the point of the change is to move implementation tokens off Codex onto that plan without leaving Z.ai's supported tooling.

### 1.3 What does not change

- The fork's architecture: a Sonnet `medium` main thread orchestrates; Opus writes plans; Codex Astra reviews plans and controls diffs; Opus reviews code; writer and reviewer of one artifact are never from the same family. The change is **by substitution** (who implements), ported narrowly.
- Frontend-only phases still go to the Claude frontend implementer subagent (`claude-frontend-implementer-prompt.md`). The channel ladder in §5.2 applies to backend / non-frontend phases only.
- `implementer-prompt.md` is reused as is for GLM — no GLM fork of the template. A short preamble block is prepended (§6.1).
- Codex remains in the pipeline as **availability fallback** (Luna max) and **reasoning escalation / high-risk implementer** (Sol 6.1 xhigh).
- Reviewer roles, loop caps (Step 2 cap 4, Step 4 cap 4, Step 5 cap 2), the ledger, auto-commit, plan archival, and the trivial-edit quickfix path are untouched.

### 1.4 Constraints (from the user)

1. Use Z.ai's own harness (the ZCode CLI). **Never** raw API calls, never extracted credentials.
2. Keep the fork's architecture; change by substitution; port narrowly.
3. Frontend phases unchanged.

---

## 2. Background — verified facts

Everything in this section was verified on 2026-10-13 on the user's machine or in the ZCode source. Items the implementation must still discover are in §10.

### 2.1 ZCode and the embedded CLI

- **ZCode** is Z.ai's official coding-agent harness: `github.com/zai-org/ZCode`, Apache-2.0, default branch `main`, newest tag `v3.15.1` (2026-10-10; the GitHub "latest release" page still points at `v3.14.3` of 2026-09-24 — the tag is the authority).
- The user has `/Applications/ZCode.app` **3.15.1** installed (`CFBundleShortVersionString` = `3.15.1`, `CFBundleVersion` = `3.15.1.8093`; `Contents/Info.plist` is an XML plist, readable with `plutil -extract CFBundleShortVersionString raw -o - <plist>`) and is logged in on an individual **GLM Coding Plan**.
- The app embeds the Agent CLI at `/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs` (zcode **0.16.9**, a 15 MB single-file bundle built from `apps/zcode-cli/packages/cli/dist/zcode.cjs`; `.node-bundle-meta.json` next to it says `"runtime": "electron-node"`, `"platform": "darwin-arm64"`). It runs under plain `node` — **v26.11.0** on this machine. There is **no `zcode` on `PATH`**.
- The CLI only starts when both `ZCODE_BUILTIN_PROVIDER_CONFIG_FILE` and `ZCODE_BUILTIN_PROVIDER_BUNDLED_CONFIG_FILE` point at `/Applications/ZCode.app/Contents/Resources/config/provider/zcode-builtin.json` (185 KB). The env plumbing lives in `apps/zcode-cli/packages/cli/src/provider-runtime-env.ts`, which also reads an optional `ZCODE_DATA_BASE_DIR` (defaults to `$HOME`) — the wrapper must **never** set it, or the CLI would look for credentials in the wrong place.
- The CLI's own state lives under `~/.zcode/`: `cli/config.json`, `cli/db/`, `cli/log/`, `cli/plugins/`, `v2/setting.json`, `v2/provider_config.json`, `v2/credentials.json`, `v2/tasks-index.sqlite`, `v2/logs/`. Only the file **names** were listed for this spec; nothing under `~/.zcode` is read or written by the design (Red Flag 1 and 6, §5.12).
- The user's ZCode CLI has 13 official plugins installed; the `superpowers-plugin` that ships in the ZCode monorepo is **not** installed.

### 2.2 CLI surface (`--help` + `apps/zcode-cli/packages/cli/src/arguments.ts`)

| Flag | Meaning |
|---|---|
| `-p, --prompt <text>` | headless run with this prompt |
| `--output-format text\|json\|stream-json` | `json` prints ONE object: `{sessionId, traceId, turnId, response, usage, eventCount, …}`; an explicit `--output-format` wins over the older `--json` |
| `--json` | legacy alias for JSON output |
| `--resume <sess_…>` | continue a saved session |
| `-c, --continue` | continue the most recent session |
| `--cwd <path>` | working directory |
| `--mode build\|edit\|plan\|yolo\|guarded` | permission mode; **default for `--prompt` is `yolo`** |
| `--disallowedTools <list>` (alias `--disallowed-tools`) | disables whole tools by name; no command patterns |
| `--attach <file>` | attach a file |
| `--target <text>` | goal mode |
| `--workflow-mode disabled\|onDemand\|alwaysOn` | dynamic workflows; default `disabled` |
| `--surface terminal\|desktop` | presentation surface (also sent as `X-Title: Z Code@<surface>`) |
| `--verbose` | verbose logging |
| subcommands | `login`, `logout`, `plugins`, `skills`, `doctor`, `app-server` |

There is **no `--model` and no `--effort` flag.**

### 2.3 Model selection and the headless gap

- Model selection format: `provider/modelId$reasoningLevel`, e.g. `GLM-5.3-Flash$max`.
- Headless `-p` currently fails with `Model creation failed — Select a model before continuing`. CLI model selection is persisted separately from the desktop app's selection. The error is raised in `apps/zcode-cli/packages/core/src/runtime/methods/runtime-model.ts`; `prompt-command.ts` feeds `createApp` a `configuredDefaultModelSelection` taken from `providerRegistryRuntime`, with an optional `legacyCliUserConfigFilePath` (`deps.userConfigPath`). `apps/zcode-cli/packages/core/tests/runtime-unbound-resume.test.ts` covers resuming a session that has no bound model.
- Not yet verified: whether a TUI `/model` selection persists for headless `-p`, and whether `--resume` keeps the model and effort. → §10 U1, U2.

### 2.4 Modes and sandboxing

- `guarded` routes approvals to a broker ("user-once"). Headless `-p` has no interactive approval surface: `prompt-command.ts` installs a minimal permission broker that only allows `CreateWorkflow` and denies everything else that asks (`headless-workflow.ts`). `guarded` is therefore **unusable headless**.
- The implementer must run `--mode yolo`, which has **no sandbox** — unlike Codex `--write`, which is `workspace-write` sandboxed. GLM runs as the user's account with the user's file and network access. Mitigations are in §6.6.

### 2.5 Client identification

The CLI sends `User-Agent: ZCode/<version>`, `X-ZCode-App-Version`, `X-ZCode-Agent: glm`, `X-Title: Z Code@<surface>`. The version comes from `ZCODE_APP_VERSION`; unset, it degrades to `ZCode/unknown`. The design passes the **real** app version from `Info.plist` and `--surface terminal` — honest identification, no spoofing (§6.5).

### 2.6 GLM-5.3-Flash and Coding Plan economics

- `reasoning_effort` ∈ `low | high | max`; default `max`; thinking cannot be disabled; Z.ai recommends `max` for coding. Published scores exist only at `max`: Terminal-Bench 2.1 **84.3** (Opus 4.8: 85.0); DeepSWE v1.1 **63.4** (full GLM-5.3: 66.9); Artificial Analysis index **57** (GLM-5.3: 60).
- Coding Plan credit multipliers — Flash: input **2.3**, cached input **0.56**, output **8** (full GLM-5.3: 6.9 / 1.7 / 24). `credits = Σ(tokens × multiplier) / 10,000`. Off-peak hours and weekends are billed at 50 %.
- ZCode quota bonus ("150 % / 1.5× in ZCode"): sources conflict on whether it is still active (launch promo ending Jul 31 / Aug 31 vs. codingplan.org 2026-09-24 calling it a standing benefit); it is not in the official docs. **Must be measured** (§8.2).

### 2.7 Z.ai usage policy (docs.z.ai/devpack/usage-policy, /faq)

- The plan may be used only in officially supported tools/products; SDK-based access and unsupported tools lead to benefit restrictions; account sharing is prohibited; more than 3 violations → ban.
- Nothing official about headless or automated use of a supported tool, either way.
- Concurrency guidance: Lite = 1 project at a time, Pro = 1–2, Max = 2+.

The design stays inside the supported tool (the ZCode CLI), identifies itself truthfully, and never touches credentials or the API. The residual policy risk is recorded in §12 and surfaced to the user in the new skill.

### 2.8 Source pointers for the discovery phase

`apps/zcode-cli/packages/cli/src/`: `arguments.ts` (flags; `extractDisallowedToolsArgs`), `prompt-command.ts` (headless path, output-format handling, `configuredDefaultModelSelection`, headless permission broker), `resume.ts` (`resolveResumeSession`), `headless-workflow.ts`, `workflow-mode.ts`, `provider-runtime-env.ts`, `env.ts`, `cwd.ts`, `shutdown.ts`, `process-errors.ts`. `apps/zcode-cli/packages/core/src/runtime/methods/runtime-model.ts` (model-not-selected error). `apps/zcode-cli/packages/core/tests/runtime-unbound-resume.test.ts`. Read with `gh api -H 'Accept: application/vnd.github.raw' repos/zai-org/ZCode/contents/<path>` at tag `v3.15.1` — no clone needed.

---

## 3. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **Role of GLM: implementation offload.** GLM never plans, never reviews. | Keeps the cross-family review scheme; implementation is where the tokens go. |
| D2 | **Default implementer: GLM-5.3-Flash, effort `max`, everywhere** — first implementation and fix rounds — via ZCode. | Z.ai recommends `max` for coding; thinking cannot be disabled anyway; published scores exist only at `max`. One pinned level mirrors "Luna always runs at `max`". |
| D3 | **Infrastructure failure of the GLM channel → Codex Luna max** (availability fallback only). Luna is **not** a reasoning escalation target. | Luna is today's implementer; falling back to it restores v0.7 behaviour exactly. |
| D4 | **"Needs more reasoning" (BLOCKED + Opus diagnosis) and review stall → Codex Sol 6.1 xhigh directly.** | Sol is already the fork's escalation tier; Luna max would be a lateral move. |
| D5 | **Approach A — a wrapper `bin/zcode-dispatch`** in the shape of `codex-dispatch`, with three guarantees: a Red Flag ban on extracting tokens or calling the API directly; the real `ZCODE_APP_VERSION` from `Info.plist` plus `--surface terminal`; a quota-deduction measurement to verify the 1.5× bonus. | Same orchestrator surface (`task/status/result/cancel`, Monitor loop) → the protocol changes stay small and mechanical. |
| D6 | **Amendment 1 — phases carrying SECURITY / DATA_LOSS risk go to Sol 6.1 xhigh (`--write`, Codex sandbox) from the start.** Not Sonnet (family rule: Opus reviews; Sonnet is not stronger than Sol). **Nothing above Sol**: BLOCKED-needs-reasoning or a review stall on such a phase → hand to the user. | The risk check already exists (4.1 `xhigh` escalation reads the plan's Risks section); unsandboxed yolo is the wrong place for destructive or security-sensitive work. |
| D7 | **Amendment 2 — gate stall diagnosis.** 2 consecutive gate-fix rounds without `GATE_OK` → Opus `high` diagnosis returning first-match-wins `ENVIRONMENT` / `CODE` / `CONTEXT` (§5.5). Review stall (fused-review round 3 still BLOCKING) still goes straight to Sol. | A weaker implementer will hit environment problems it cannot fix; machine-state changes need user consent; code/reasoning stalls need a stronger model, once. |
| D8 | **Implementer channel ladder per phase** (§5.2). | One ordered first-match procedure instead of scattered rules. |
| D9 | **Kill switch: the phrase "через Luna" / "без GLM" for the session; env `SP_IMPLEMENTER=luna` permanently. Nothing more.** | One escape hatch in each scope; no configuration surface to maintain. |

Decisions the spec writer made where the approved design was silent are listed in §13.

---

## 4. Architecture — `bin/zcode-dispatch`

### 4.1 Files and resolution

- `bin/zcode-dispatch` — bash shim. Resolves `bin/lib/zcode-dispatch.mjs` next to itself (marketplace cache first — `~/.claude/plugins/cache/strigov-cc-plugins/superpowers-strigov-ver/*/bin/lib/zcode-dispatch.mjs`, newest by `sort -rV` — then the dev tree `$(dirname "$0")/lib/zcode-dispatch.mjs`), exports the default `ZCODE_STATE_DIR`, and `exec node "$MJS" "$@"`. Same structure as `codex-dispatch`'s `resolve_companion`.
- `bin/lib/zcode-dispatch.mjs` — pure Node ESM, **no dependencies**, no shell: `child_process.spawn` with argv arrays only.
- Orchestrator-side resolution, by the same 3-line idiom as `$DISPATCH`:

```bash
ZDISPATCH="$(command -v zcode-dispatch || true)"
[ -z "$ZDISPATCH" ] && ZDISPATCH="$(ls -1d ~/.claude/plugins/cache/strigov-cc-plugins/superpowers-strigov-ver/*/bin/zcode-dispatch 2>/dev/null | sort -rV | head -1)"
[ -z "$ZDISPATCH" ] && ZDISPATCH="$(pwd)/bin/zcode-dispatch"
echo "ZDISPATCH=$ZDISPATCH"
```

### 4.2 Verbs

Same shape as `codex-dispatch`. Exit codes everywhere: **0** success · **1** runtime failure (failed job on `result`, failed checks on `doctor`, internal error) · **2** usage error or guard refusal.

| Verb | Behaviour |
|---|---|
| `task --background [--cwd <path>] [--resume-task zt-NNNN \| --fresh] --prompt-file <f>` | Allocates `zt-NNNN`, spawns the detached runner (§4.3), prints exactly `ZCode Task started in the background as zt-NNNN`, returns. `--background` is mandatory (a missing flag is exit 2 — there is no foreground mode; the flag exists so the orchestrator's dispatch lines look like Codex's). `--resume-task` and `--fresh` are mutually exclusive (exit 2). Omitting both equals `--fresh`. |
| `status [zt-NNNN] [--cwd <path>] [--all] [--json]` | With an id: `{"job":{…}}` (record schema §4.4) — the Monitor loop reads `['job']['status']`. Without an id: `{"workspaceRoot":…,"running":[…],"recent":[…]}` (recent = the 10 newest terminal jobs; `--all` = every job in the workspace, as in the Codex companion). Non-JSON: one line per job: `zt-0007 running 2m14s GLM-5.3-Flash$max sess_… resumeOf=zt-0003`. Every `status` call first runs the liveness check (§4.5). Unknown id → exit 2. |
| `result zt-NNNN [--cwd <path>]` | `completed` → prints the stored `response` verbatim to stdout, exit 0. Any other status → stderr `job zt-NNNN is <status> errorClass=<class>` plus the last 20 log lines, exit 1. |
| `cancel zt-NNNN [--cwd <path>]` | SIGTERM to the CLI's process group, 5 s grace, SIGKILL; SIGTERM to the runner; record `status: cancelled`; prints `cancelled zt-NNNN`. Already terminal → prints the status, exit 0. Unknown → exit 2. |
| `doctor [--cwd <path>]` | Offline checks (§4.8), no model call. |
| `doctor --probe [--cwd <path>]` | Offline checks, then ONE synchronous PONG request (§4.8). The only *diagnostic* verb that spends quota (`task` spends it by design). |

`--cwd` defaults to the process cwd. `status` / `result` / `cancel` for a worktree job must pass the same `--cwd` as the `task` — ids are per workspace (§4.4), exactly like Codex.

### 4.3 Runner invocation and environment

`task` spawns a detached **runner** (`node zcode-dispatch.mjs __run zt-NNNN`, internal verb, `detached: true`, stdio to the job log, `unref()`). The runner spawns the CLI as its own process group (`detached: true`) with this argv — an array, never a shell string:

```
<ZCODE_NODE> <ZCODE_BIN> -p <prompt-file contents> --output-format json --mode yolo --surface terminal --workflow-mode disabled --cwd <workspaceRoot> [--resume <sess_…>]
```

- stdin `ignore`; stdout captured by the runner (the JSON object); stderr appended to `zt-NNNN.log`.
- Runner and CLI cwd = `workspaceRoot`.
- Environment = the inherited environment plus exactly three variables: `ZCODE_BUILTIN_PROVIDER_CONFIG_FILE` and `ZCODE_BUILTIN_PROVIDER_BUNDLED_CONFIG_FILE` (both `<ZCODE_APP>/Contents/Resources/config/provider/zcode-builtin.json`) and `ZCODE_APP_VERSION` = `CFBundleShortVersionString` read from `<ZCODE_APP>/Contents/Info.plist` via `plutil -extract CFBundleShortVersionString raw -o -` at every `task`. There is **no override** for `ZCODE_APP_VERSION`: an unreadable plist is a refusal (exit 2), because running as `ZCode/unknown` is the degraded identity the design exists to avoid. The wrapper never sets `ZCODE_DATA_BASE_DIR`.
- The wrapper never passes `--target`, never passes `--json`, never passes `-c/--continue`. `--disallowedTools` is passed only if discovery (§10 U6) confirms what it covers; until then it is not passed.
- Defaults, each overridable by env for tests and for a relocated app (§4.10): `ZCODE_APP=/Applications/ZCode.app`, `ZCODE_BIN=$ZCODE_APP/Contents/Resources/glm/zcode.cjs`, `ZCODE_NODE=node`.
- Prompt transport and size guard: the constant `PROMPT_TRANSPORT` (`argv` initially — the prompt travels as the `-p` argument; `stdin` if discovery U10 finds `-p -` works) and, for `argv`, the constant `MAX_PROMPT_BYTES` (initially 200 KB): a larger prompt file is refused (exit 2).

### 4.4 Job records and state directory

- State root: `ZCODE_STATE_DIR` (default `~/.claude/plugins/data/superpowers-strigov-ver-zcode`) → `state/<workspace-slug>/jobs/zt-NNNN.json` and `zt-NNNN.log`.
- Workspace = `git rev-parse --show-toplevel` evaluated in `--cwd`; slug = `<basename of root>-<first 8 hex of sha1(absolute root)>`. Each git worktree therefore has its own job list and its own id counter — the same isolation the Codex companion gives.
- Id allocation: scan `jobs/` for the highest `zt-*.json`, take +1, create the record with the `wx` flag; `EEXIST` → +1 and retry. Four digits zero-padded (`zt-0001`), more digits beyond 9999.
- Record schema:

```json
{
  "id": "zt-0007",
  "status": "running",
  "errorClass": null,
  "sessionId": "sess_…",
  "resumeOf": "zt-0003",
  "workspaceRoot": "/abs/path",
  "promptFile": "/abs/path/implement-Ф2.md",
  "model": "GLM-5.3-Flash$max",
  "reportedModel": null,
  "appVersion": "3.15.1",
  "runnerPid": 48213,
  "childPid": 48214,
  "startedAt": "2026-10-13T12:00:00Z",
  "finishedAt": null,
  "exitCode": null,
  "signal": null,
  "timeoutMin": 60,
  "response": null,
  "usage": null
}
```

`status` ∈ `running | completed | failed | cancelled`. `errorClass` ∈ `timeout | crash | model-not-selected | auth | quota | launch | malformed`, set only with `failed`. `sessionId`, `response`, `usage`, `reportedModel` are copied from the CLI's JSON object on completion (`reportedModel` only if the JSON exposes a model — §10 U3; otherwise it stays `null`). On a resume the new record inherits `sessionId` from the referenced job at creation so the chain is resolvable even if the new run fails.

- Log file: the CLI's stderr, plus runner lines prefixed `[zcode-dispatch]` — argv summary without the prompt text, start/finish timestamps, the classification reason, and the raw stdout whenever it fails to parse.

### 4.5 Job lifecycle

- **Terminal statuses are sticky.** The runner re-reads the record before writing its final state and never overwrites a status that is already terminal (a `cancel` that landed first wins).
- **Completion:** CLI exit 0 and stdout parses as one JSON object with a string `response` → `completed`. Exit 0 without a parsable object or without `response` → `failed/malformed`.
- **Failure:** non-zero exit or a signal not sent by the wrapper → `failed` with `errorClass` from the classifier (§7, table "Classifier").
- **Timeout:** `ZCODE_TASK_TIMEOUT_MIN` (positive decimal minutes, default 60). On expiry the runner sends SIGTERM to the CLI's process group, waits 10 s, sends SIGKILL, records `failed/timeout`.
- **Liveness check** (run by every `status`, `result`, `cancel`, and by `task` before its guards): for each `running` record, `process.kill(runnerPid, 0)`; `ESRCH` → the runner died without writing a terminal record → best-effort `SIGKILL` to the CLI's group, record `failed/crash` with the note `runner died`. No record is ever left `running` with a dead runner.
- **Cancel:** see §4.2. A cancelled job keeps whatever `sessionId` it inherited, for diagnostics only — the wrapper resumes `completed` jobs exclusively (§4.6), and the orchestrator treats `cancelled` as "report to the user".

### 4.6 Resume mapping

`--resume-task zt-NNNN` resolves the referenced record's `sessionId` and passes `--resume <sess_…>` to the CLI. Rules (mirroring `codex-invocation` "Resume semantics"):

- The referenced job must be `completed` and carry a `sessionId`. Otherwise exit 2: a `running` reference → `job zt-NNNN is still running; wait for it to finish`; a `failed` / `cancelled` reference, or a completed one whose record has no `sessionId` → `job zt-NNNN is <status> / has no session; dispatch --fresh`.
- Any id in the same session chain works: every resumed record stores the same `sessionId`, so resuming `zt-0003` after the chain continued in `zt-0007` lands in the same GLM session.
- Ids are per workspace: pass the same `--cwd` as the original dispatch.
- `zt-` ids and Codex `task-` ids never cross dispatchers; each wrapper rejects the other's prefix with exit 2.

### 4.7 Guards and refusals (all exit 2, before anything is spawned)

1. `--cwd` is not inside a git work tree (`git rev-parse --show-toplevel` fails).
2. No `--prompt-file`, or the file is missing/empty, or (argv transport) larger than `MAX_PROMPT_BYTES`.
3. `Info.plist` unreadable / `CFBundleShortVersionString` missing (§4.3).
4. `ZCODE_BIN` or the provider config file does not exist.
5. Another job in the same workspace is `running` (after the liveness check) — one write task per tree is the protocol's invariant, and every ZCode task is a write task.
6. `SP_IMPLEMENTER=luna` is set — the permanent kill switch is enforced by the wrapper too, not only by the orchestrator's ladder.
7. `--resume-task` violations (§4.6), `--resume-task` together with `--fresh`, unknown verbs or flags.

### 4.8 `doctor` and `doctor --probe`

`doctor` prints one line per check — `ok | WARN | FAIL <check>: <detail>` — then `doctor: ok` or `doctor: FAIL`; exit 1 on any FAIL. Checks, in order:

1. `app` — `<ZCODE_APP>/Contents/Info.plist` readable, version extracted (FAIL otherwise).
2. `cli` — `<ZCODE_BIN>` exists (FAIL).
3. `provider-config` — `zcode-builtin.json` exists (FAIL).
4. `node` — `<ZCODE_NODE> --version` runs (FAIL if not); WARN if the major version is below the floor recorded by discovery (constant `VERIFIED_NODE_MAJOR` in the `.mjs`; initial value 26, the version verified on this machine — discovery may lower it).
5. `app-version` — WARN if the installed version differs from the constant `VERIFIED_APP_VERSION` (initially `3.15.1`) — an app auto-update may move `zcode.cjs` or change flags; a WARN tells the user to re-run the live acceptance (§8.2).
6. `git` — `--cwd` is inside a git work tree (FAIL).
7. `state-dir` — `ZCODE_STATE_DIR` writable (FAIL).
8. `kill-switch` — WARN `SP_IMPLEMENTER=luna is set; task will refuse`.

`doctor --probe`: runs the offline checks first (any FAIL → exit 1, no request); then runs the CLI **synchronously** (no job record, 120 s timeout, same argv and env as a task, prompt `Reply with exactly one word: PONG`) and prints:

```
model-selected: ok | FAIL(<errorClass>)
answers: ok | FAIL
reported-model: <model string from the JSON> | unreported
usage: input=<n> cached=<n> output=<n>
probe: ok | FAIL
```

Exit 0 iff `model-selected: ok`, `answers: ok` (the response contains `PONG`), and `reported-model` is either `unreported` or equal to the pinned model id (`GLM-5.3-Flash`, effort suffix compared only when the JSON reports one). The `usage` line feeds the bonus measurement (§8.2).

### 4.9 Model pin

The pinned selection is one constant in the `.mjs`: `PINNED_MODEL = "GLM-5.3-Flash$max"`. **How a headless run receives it is unknown** (§10 U1) and is the first plan phase. Whatever discovery finds, two rules hold: the wrapper may pass the model per invocation (a flag or an env variable, if one exists), but it **never edits files under `~/.zcode`** (Red Flag 6: model selection via `/model` is the user's action); and `doctor --probe` is run once per session before the first dispatch to confirm the model actually answering (§5.4).

### 4.10 Overrides (tests and relocated installs)

`ZCODE_APP`, `ZCODE_BIN`, `ZCODE_NODE`, `ZCODE_STATE_DIR`, `ZCODE_TASK_TIMEOUT_MIN`. Nothing else is configurable; in particular there is no override for the model, the mode, the surface, or the app version.

---

## 5. Protocol integration (`skills/dev-orchestrator/SKILL.md`)

Section names below are the real headings in `SKILL.md`; each item names the edit.

### 5.1 "Model split" table

Replace the implementer rows and add two:

| Role | Step | Model · effort |
|---|---|---|
| Implementer — phases, fix rounds, gate-fix rounds, Step 5 fix wave, integration repair | 3, 3.5, 4, 5 | **GLM `GLM-5.3-Flash` · `max` via `$ZDISPATCH`** (ZCode CLI) |
| Implementer of SECURITY / DATA_LOSS phases (risk-marked, §5.3) | 3, 3.5, 4, 5 | Codex `gpt-6.1-sol` · `xhigh` · `--write` |
| Availability fallback (GLM channel down or failed, kill switch) | 3, 3.5, 4, 5 | Codex `gpt-6-luna` · `max` · `--write` — the **same operation** re-dispatched FRESH with re-brief + channel-switch notice (§5.4), **announced** |
| Reasoning escalation (BLOCKED + "needs more reasoning"; fused-review round 3 still BLOCKING; gate diagnosis `CODE`) — on GLM **and** Luna phases | 3, 3.5, 4 | Codex `gpt-6.1-sol` · `xhigh` · `--write` — GLM phase: FRESH, composed per the §5.4 rules for the operation type (`implement`: first-round body + notice, no re-brief; fix-type: re-brief opening + notice + body); Luna phase: `--resume-task` of the Luna thread (as today). From then on Sol is the phase's channel; on a phase already on Sol these points go to the user. |

Bullet notes under the table:

- **GLM implementer** — dispatched only through `$ZDISPATCH` (never `zcode -p` directly); the wrapper pins the model, there are no `--model`/`--effort` flags. GLM always runs at `max`; there is no cheaper GLM dispatch.
- **Family rule** addition: GLM adds a third family (Z.ai). GLM writes the code → Opus reviews (4.1), Astra cross-checks (4.2): clean cross-family on both sides. Escalation to Sol returns the phase to today's Luna/Sol scheme.
- The description frontmatter of `SKILL.md`, and the summary line in "Role", name GLM as the implementer and Luna as the fallback.

### 5.2 Channel ladder (new subsection under Step 3, referenced from Steps 3.5, 4, 5 and "Parallel groups")

Decided **once per non-frontend phase**, at the first Step 3 dispatch; first match wins:

1. **Kill switch active** — the user said "через Luna" / "без GLM" in this session, or `SP_IMPLEMENTER` is `luna` → Codex Luna max. (Risk-marked phases also go to Luna, as they did before 0.8.0; the stall rules of §5.5–5.6 still apply — they are pipeline rules, not GLM rules.)
2. **Phase is risk-marked** (its entry in the frontmatter's `risk_phases` is non-empty, §5.3) → Codex Sol 6.1 xhigh `--write`.
3. **GLM channel down this session.** If the state line still shows `glm=unprobed`, run `doctor` and `doctor --probe` now (§5.4) and set `glm` before evaluating this item. `glm=down` — `doctor` or the probe failed, or an earlier GLM job failed with `quota | auth | model-not-selected` → Codex Luna max, announced once per session.
4. **Phase already handed to Luna or Sol** (fallback or escalation earlier in this phase) → stays there; resume that thread with `--resume-task <task-id>`.
5. **Otherwise** → GLM-5.3-Flash max via `$ZDISPATCH`.

Frontend-only phases do not enter the ladder (Claude frontend implementer, unchanged). The chosen channel is written into the state line (`impl=`, §5.9) and announced in one line (§5.11 Reporting cadence).

### 5.3 Risk-marked phases

A phase is **risk-marked** when the plan's `## Risks / unknowns` section (or the phase's own Risks lines) names `SECURITY` or `DATA_LOSS` for it — the same determination the 4.1 `xhigh` escalation already makes "per the plan's Risks section".

To make the determination mechanical and compaction-safe, **Step 2.5 — Pre-flight scan** gets a fourth item: during the single full read, classify **every** phase and write ONE top-level key into the plan-file YAML frontmatter (an allowed mechanical metadata edit under Rule 1):

```yaml
risk_phases: { Ф1: [], Ф2: [], Ф3: [DATA_LOSS], Ф5: [SECURITY, DATA_LOSS] }
```

Every phase id appears; an empty list means "scanned, no risk". Commit the plan file alone as `docs(plans): record risk phases for <slug>` (same class as the existing `docs(plans): advance to <id>` bookkeeping commit). Rules that follow:

- "Phase X is risk-marked" ⇔ `risk_phases[X]` is non-empty. "The plan has a risk-marked phase" (§5.7) ⇔ any value is non-empty. The ladder (§5.2), Step 5, integration repair and the 4.1 `xhigh` escalation read this key; the value lists the kinds for the announcement line. After compaction the frontmatter read (Durable Progress item 1) restores it; no second read of the plan body.
- **Re-derivation after plan changes.** Every plan-writer Mode B dispatch that lands after Step 2.5 has run — pre-flight edits the user accepted, a BLOCKED "task too large" sub-phase split (Step 3 outcome 3), a scope revision after a completed phase's findings ("Multi-phase plans"), a legacy frontmatter retrofit — is followed, **before the revised plan file is committed and before any implementer dispatch**, by a re-run of the four Step 2.5 checks on the revised plan (the existing "re-run the checks once on the revised plan" sentence, now covering every post-approval revision). The map is rewritten in full — new ids added, removed ids dropped, changed risks updated — and lands in the same commit as the revision.
- **Compaction-safe guards**, checked before every non-frontend implementer dispatch (Pre-dispatch checklist items 5 and 10), first match wins: (a) no `risk_phases` key at all (pre-0.8.0 plan on the confirmed-resume path, or a pre-flight that never ran) → run the Step 2.5 scan once — the single allowed full read — write the map, commit; (b) the current phase id — for the plan-wide operations `final-fix` and `repair`, every id in the frontmatter `phases:` list — is not a key of the map (new sub-phase, renamed phase) → the map is stale → re-scan, rewrite, commit, then dispatch; (c) the plan file is dirty in `git status` → a revision may have landed without its re-scan → re-scan, rewrite the map and commit the plan file — carrying whatever uncommitted revision it holds — as `docs(plans): record risk phases for <slug>`; (d) otherwise the map is current — a present, complete map is never re-derived without one of these triggers. **Admission condition** (one rule, checked by Pre-dispatch checklist items 5 and 10 after any guard fired): the needed phase ids are keys of `risk_phases` **and** the plan file is clean in `git status`. No implementer dispatch while either half fails.

### 5.4 Step 3 — implement the current phase

**Prompt files and the retry / channel-switch rule** (new subsection; applies to every implementer dispatch on every channel — Steps 3, 3.5, 4, 5 and integration repair):

- Every dispatch belongs to exactly one **operation**: `implement` (first round), `fix r<N>` (Step 4 fix round), `gatefix r<N>` (Step 3.5 gate-fix round), `final-fix` (Step 5 fix wave) or `repair r<N>` (integration repair). The operation fixes the template (first-round or fix-round, with the "Step 5 fix wave" substitutions where applicable), the scope, the ledger items inlined, the round number and `[REPORT_FILE]`.
- The orchestrator writes the operation's **body file** once — the filled template and nothing else — to `$dir/prompts/<op>-<phase>-r<N>.md`, where `$dir = $("$WS" <plan-file>)` (for a parallel track, `"$WS"` run inside the worktree) and the name is one of `implement-<id>-r1`, `fix-<id>-r<N>`, `gatefix-<id>-r<N>`, `final-fix-r<N>`, `repair-<G>-r<N>`. The plan-scoped workspace, not the session scratchpad, so the files outlive compaction and sessions. A continuation of the same operation (`NEEDS_CONTEXT`, added context after a diagnosis) appends an `## Added context` section to the body file before the `--resume-task` follow-up, so a later retry carries it.
- Every dispatch — every `task` invocation, resumes and follow-ups included — is written to a **dispatch file** `$dir/prompts/<op>-<phase>-r<N>.<seq>.<glm|luna|sol>.md`. `<seq>` is a three-digit **per-phase dispatch sequence number** (per operation name for the plan-wide `final-fix` / `repair-<G>`), monotonic across operations, rounds **and channels**: the next seq is the highest seq present for the phase plus one (`ls "$dir"/prompts/`). Composition depends on the operation type and on whether the dispatch resumes a thread:
  - `implement` — ZCode preamble (GLM target only, §6.1 b) → the body (the self-contained first-round template); on a retry or channel switch the channel-switch notice (§6.1 c) is inserted right after the body's opening paragraph. **Never the fresh-fallback re-brief** — that block declares a fix round and would contradict the first-round template.
  - fix-type operations (`fix`, `gatefix`, `final-fix`, `repair`), **thread resume** (`--resume-task` — a GLM session resume, a Luna/Sol thread resume, and the Luna → Sol escalation, which resumes the Luna thread) — preamble (GLM only) → the body as written (fix-round template with its standard opening paragraph). No re-brief, no notice: the thread holds the history.
  - fix-type operations, **FRESH** (a new thread: GLM ↔ Codex channel switch, `--fresh` retry, lost handle; the Step 5 wave and integration repair are fresh by nature) — preamble (GLM only) → the body with its opening paragraph **replaced** by the fresh-fallback re-brief block, exactly as `implementer-prompt.md` already prescribes for that block, and the channel-switch notice inserted right after the re-brief whenever an earlier dispatch of this operation exists.
  - a continuation follow-up on a resumed thread (`NEEDS_CONTEXT`, added context) is the short follow-up text — on a GLM target still preceded by the ZCode preamble, which opens **every** GLM dispatch file without exception; it still takes the next seq, a dispatch file and a sidecar.
  The moment the dispatcher prints the id, the orchestrator writes it — `glm:zt-NNNN` / `luna:task-NNNN` / `sol:task-NNNN` — into the sidecar `<same name>.id` (a one-line bookkeeping write, same class as the ledger). Because seq is monotonic across channels, **the highest seq for a phase is always its current channel and handle** — e.g. `implement-Ф2-r1.001.glm` → `.002.glm` (retry) → `.003.luna` (fallback) resolves to Luna; `implement-Ф2-r1.001.luna` → `.002.sol` (escalation) resolves to Sol.
- **A retry or a channel switch never changes the operation.** A failed `fix r2` on GLM is re-dispatched as `fix r2` on the new channel with the same body — same AUTHORIZED_BLOCKERS, same round number, same `[REPORT_FILE]` append rule; a failed `final-fix` stays a whole-plan fix wave; a failed `gatefix r1` stays a gate-fix round. The first-round template appears only when the operation is `implement`. On Codex channels the `codex-invocation` terminal-status rule (retry once with `--fresh`, then the user) applies with the same body file at the next seq.

**Before the first GLM dispatch of a session** (one more item in the "Before every implementer dispatch" list, executed only when the ladder reaches item 3 with `glm=unprobed`): resolve `$ZDISPATCH`, run `"$ZDISPATCH" doctor`, then `"$ZDISPATCH" doctor --probe` (cwd inside the repo). Both exit 0 → `glm=ok`. Either fails → `glm=down`, one announcement (`ZCode doctor failed (<first FAIL line>) — implementer for this session: Luna max.`), ladder item 3 applies for the rest of the session. Write the result to the session marker (§5.9). The probe runs **once per session**; after compaction the marker, not a new probe, restores the state.

**Route by phase type** — the "Backend / non-frontend phase" bullet becomes: "→ implementer per the channel ladder (§5.2): GLM via `$ZDISPATCH` with `./implementer-prompt.md` prefixed by the ZCode preamble; Luna or Sol via `$DISPATCH` as before." Dispatch line for GLM:

```bash
"$ZDISPATCH" task --background [--cwd <worktree-path>] --prompt-file "$dir"/prompts/implement-<id>-r1.<seq>.glm.md
```

Poll with the Monitor loop from `zcode-invocation` (identical to Codex's, `zt-` ids, terminal set `completed|failed|cancelled`), fetch with `"$ZDISPATCH" result zt-NNNN`, parse line 1 exactly as for Codex.

**Implementer status handling** is unchanged for `DONE`, `DONE_WITH_CONCERNS`, `NEEDS_AUTHORIZATION`. Two branches change:

- `NEEDS_CONTEXT` → GLM: `--resume-task <zt-id>` with the added context (also appended to the body file); Codex channels as today.
- `BLOCKED` → Opus `high` diagnosis as today; the four outcomes:
  1. More context needed → resume the phase's channel with the added context (GLM: `"$ZDISPATCH" task --background --resume-task <zt-id>`).
  2. Needs more reasoning → Codex Sol xhigh (`--write --model gpt-6.1-sol --effort xhigh`). GLM phase: **FRESH**, dispatch file `implement-<id>-r1.<seq>.sol.md` — the first-round body with the channel-switch notice (naming the GLM job id and the report file) after its opening paragraph, the BLOCKED report appended to the body as `## Added context`; no re-brief (`implement` composition). Luna phase (fallback or kill switch): `--resume-task <luna id>`, as today. In both cases Sol becomes the phase's channel (ladder item 4). A phase already on Sol (risk-marked or escalated) → hand to the user — nothing above Sol.
  3. Task too large → sub-phases via the plan writer, unchanged (then the `risk_phases` re-derivation of §5.3).
  4. Plan is wrong → user, unchanged.

**GLM infrastructure failures** — the job reached `failed` (the Monitor loop reported it) or `cancelled`. First match wins:

1. `errorClass ∈ {quota, auth, model-not-selected}` → retry is pointless. Set `glm=down` for the session (state line + marker), announce (`GLM channel failed (errorClass=<class>) — Ф<id> falls back to Luna max; GLM is off for this session.`), re-dispatch the **same operation** on Codex Luna max FRESH — dispatch file `<op>-<phase>-r<N>.<seq>.luna.md` in the FRESH composition for its operation type (`implement`: body + notice; fix-type: re-brief opening + notice + body; the tree may hold partial GLM work).
2. `errorClass ∈ {timeout, crash, launch, malformed}` → ONE retry of the same operation on GLM: `"$ZDISPATCH" task --background --fresh --prompt-file "$dir"/prompts/<op>-<phase>-r<N>.<seq>.glm.md` (same FRESH composition). The retry fails again with any class → Luna per item 1's mechanics (announce; set `glm=down` only if the second class is in item 1's set).
3. `cancelled` → report to the user and wait, exactly as for Codex.

A `completed` job whose line 1 is not a valid token is **not** an infrastructure failure: apply "Verdict parsing" step 3 (re-dispatch once with `--resume-task <zt-id>`).

### 5.5 Step 3.5 — Verification gate

- `GATE_FAIL` → gate-fix round (operation `gatefix r<N>`) on the phase's channel: GLM `"$ZDISPATCH" task --background --resume-task <zt-id> --prompt-file "$dir"/prompts/gatefix-<id>-r<N>.<seq>.glm.md` with the gate's failure report as the fix list (fix-round template, preamble prepended); Luna/Sol `--resume-task <task-id>` as today. Gate-fix rounds still do not increment the fused-review counter.
- **Gate stall (every non-frontend channel — GLM, Luna, Sol):** the second consecutive gate-fix round ends without `GATE_OK` → do **not** dispatch a third fix. Dispatch the gate-stall diagnosis — **at most once per phase**; a later stall on the same phase goes straight to the user — `Agent(subagent_type="general-purpose", model="opus", effort="high")` with this skeleton:

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
  - `ENVIRONMENT` + `fix-location: machine` → **pause the phase**; report to the user the diagnosis and the proposed commands verbatim. The orchestrator runs none of them (machine state changes need consent). When the user confirms the environment is fixed, re-run the gate (not the fixer — the tree did not change) with the consecutive counter reset to 0; a `GATE_FAIL` there starts ordinary gate-fix rounds again, and because the diagnosis already ran once for this phase, a second stall goes to the user.
  - `CODE` → ONE gate-fix round on Sol xhigh (`--write --model gpt-6.1-sol --effort xhigh`), the diagnosis inlined: GLM phase → FRESH Sol, dispatch file `gatefix-<id>-r<N>.<seq>.sol.md` (FRESH fix-type composition: re-brief opening + notice + body); Luna phase (fallback or kill switch) → Sol resuming the Luna thread (`--resume-task <luna id>`, resume composition — plain body). In both cases Sol becomes the phase's channel. A phase already on Sol → user directly (nothing above Sol).
  - `CONTEXT` → ONE more gate-fix round on the phase's channel with the named context added.
  - After that round: `GATE_OK` → Step 4; `GATE_FAIL` → user with both failure outputs and the diagnosis. Malformed diagnosis (line 1 not one of the three tokens) → the standard verdict-parsing re-dispatch, then user.
- Frontend phases are unchanged (2 consecutive gate-fix rounds → user, as in v0.7).

### 5.6 Step 4(c) — fix rounds

- Fix round (operation `fix r<N>`) on a GLM phase: `"$ZDISPATCH" task --background [--cwd …] --resume-task <zt-id> --prompt-file "$dir"/prompts/fix-<id>-r<N>.<seq>.glm.md` — the fix-round template with the preamble prepended (resume composition); the fixer continues its own GLM session. `--resume-last` remains forbidden (the ZCode wrapper has no such flag at all).
- **Review stall (GLM and Luna phases):** when fused-review **round 3** returns a non-empty combined BLOCKING list, the fixer for `## Fix round 3` is **Codex Sol xhigh** (`--write --model gpt-6.1-sol --effort xhigh`). GLM phase → FRESH Sol, dispatch file `fix-<id>-r3.<seq>.sol.md` (FRESH fix-type composition: re-brief opening + notice + body); the body's fix-round template carries the ledger path, the open ACCEPTED / PARTIALLY_ACCEPTED items inline, and the explicit instruction to read **every** `## Fix round` section already in `[REPORT_FILE]` so closed items are not redone (the orchestrator passes the path and the instruction; it does not read or inline those sections — Rule 2). Luna phase (fallback or kill switch) → Sol resuming the Luna thread (`--resume-task <luna id>`, plain fix-round body — the thread already holds the history). In both cases Sol becomes the phase's channel and Sol's task id goes into `impl=`. Round 4's review proceeds as usual; the round cap (next round would be 5) escalates to the user as today — Sol gets exactly one fix round inside the loop.
- **Review stall on a phase already on Sol** (risk-marked, or escalated earlier in this phase): round 3 still BLOCKING → do **not** dispatch fix round 3; escalate to the user immediately with the same content as the round-cap escalation (diff, combined list, one-sentence impasse summary by an Opus `high` subagent). Nothing above Sol (D6).
- Cap 4, the fix-report check, the `NEEDS_AUTHORIZATION` branch, the loop-control checks and reviewer freshness are unchanged.
- **Lost handle** (no `.id` sidecar, `status` does not know the id, or the wrapper refuses the resume): the same operation FRESH on the same channel at the next seq, in the FRESH composition for its operation type (§5.4).

### 5.7 Step 5 — final whole-branch review, fix wave

The single fixer of step 4 (operation `final-fix`) is chosen by, first match wins: kill switch active → Luna max FRESH; **the plan has any risk-marked phase** (any non-empty value in `risk_phases`) → Sol xhigh FRESH (`--write --model gpt-6.1-sol --effort xhigh`) does the whole wave; `glm=down` → Luna max FRESH; otherwise → GLM FRESH via `$ZDISPATCH` (`--fresh`, fix-round template with the fresh-fallback re-brief and the "Step 5 fix wave" substitutions, preamble prepended, `[REPORT_FILE] = $dir/final-fix-report.md`, body `$dir/prompts/final-fix-r1.md`, dispatch file `final-fix-r1.<seq>.<channel>.md` in the FRESH fix-type composition). One fixer, complete list, fix-report check before round 2 — unchanged. An infrastructure failure of the wave follows the retry / channel-switch rule (§5.4): the re-dispatch is still the whole-plan wave with the same findings list and the same report file.

**Integration repair** ("Parallel groups" step 7, operation `repair r<N>`) uses the same selection, where "risk-marked" means either phase of the group has a non-empty `risk_phases` entry; body `$dir/prompts/repair-<G>-r<N>.md`; round 2 of the repair resumes the repairer (`--resume-task` on its own dispatcher).

### 5.8 "Parallel groups" and "Durable Progress"

- Routing per track = the channel ladder per phase. GLM+GLM, GLM+Luna, GLM+Claude, Codex+Codex, Codex+Claude, Claude+Claude are all valid pairs.
- Precondition 3 becomes: "No other write task running on **either** dispatcher — check `"$DISPATCH" status` and `"$ZDISPATCH" status`." The width cap (max 2 concurrent write tasks) counts **across both dispatchers**.
- Every `task` / `status` / `result` / `cancel` for a track carries the track's `--cwd` on whichever dispatcher owns the job; the job lives in that worktree's workspace.
- **GLM concurrency** is unknown (§10 U5 — a possible session-DB lock). If discovery finds that two `zcode` processes cannot run concurrently, a group runs at most **one** GLM track: the track whose phase is listed first in the frontmatter takes GLM, the other takes Luna max for the duration of the group, announced in the group's setup line. The verified answer is recorded as one line in `zcode-invocation` ("GLM concurrency: 1 | 2") and the orchestrator follows it.
- Durable Progress item 4 becomes: "Before re-dispatching any phase's implementer, run `"$DISPATCH" status` **and** `"$ZDISPATCH" status` (with the track's `--cwd` where applicable): a running write task for this phase on either → poll it, never dispatch a second." The pre-flight gate's confirmed-resume sentence ("a write task already running … found via `"$DISPATCH" status`") and the "Before Step 1" item 4 text gain the same "either dispatcher" wording.
- **Rule 1 / Rule 2 allowances.** `Write` of the prompt bodies, dispatch files and `.id` sidecars under `$dir/prompts/` and of the session marker (§5.9) join Rule 1's exceptions (dispatch plumbing, like scratch prompt files today). `"$ZDISPATCH" status`, `doctor`, `doctor --probe`, `echo "${SP_IMPLEMENTER:-}"`, `ls "$dir"/prompts/` (filenames only), `cat` of one `.id` sidecar and `cat` of the session marker join the allowed bookkeeping commands in Rule 2 and the pre-flight gate's list (c).

### 5.9 "Protocol state line"

Two fields are appended:

```
[dev-orchestrator] step=… phase=… round=… base=… gate=… impl=<glm:zt-NNNN | luna:task-NNNN | sol:task-NNNN | claude | —> glm=<unprobed | ok | down | off>
```

- `impl` is the phase's current implementer channel and its resume handle (the Claude frontend subagent has no handle; `—` before the first dispatch). During a parallel group the per-track form is `tracks=Ф2:4-r1@glm:zt-0003,Ф3:3@luna:task-0011`.
- `glm` is the session's channel state: `unprobed` (no probe yet), `ok`, `down` (doctor/probe failed or a quota/auth/model-not-selected failure), `off` (kill switch).
- **Durable copies.** `impl` handles live in the `.id` sidecars under `$dir/prompts/` (§5.4) and in the dispatchers' job records. `glm` lives in the **session marker** `<scratchpad>/dev-orchestrator/glm-channel` — one line `<ok|down|off> <reason> <ISO time>` — written whenever `glm` leaves `unprobed` or changes; `<scratchpad>` is the session-specific scratchpad directory the host names in the system prompt, which survives compaction and dies with the session. `down` and `off` are never overwritten by a later probe: they hold until the session ends (a new session starts `unprobed`; `SP_IMPLEMENTER=luna` re-writes `off` at every skill start). If the host names no scratchpad, the state exists only in the state line and the orchestrator says so once at skill start.
- **Recovery after compaction, in this order:**
  1. `glm` — `echo "${SP_IMPLEMENTER:-}"` prints `luna` → `off`; else `cat` the marker → its state; else `unprobed` (the ladder's item 3 will probe when first needed — that is the session's one probe). Never probe when a marker exists.
  2. `impl` — `ls "$dir"/prompts/` (filename listing, allowed); take the `.id` sidecars of the current phase (name contains `-<phase>-r`; for plan-wide work the names starting with `final-fix-` or `repair-<G>-`); of those, the **highest `<seq>`**, regardless of operation, round or channel; `cat` that one sidecar; confirm with `status <id> --json` on the dispatcher its prefix names (`zt-` → `$ZDISPATCH`, `task-` → `$DISPATCH`, with the track's `--cwd`). `running` → keep polling it (the pre-flight gate's running-task rule). Terminal → that is the resume handle; its channel is the phase's channel (ladder item 4), and the file's `<op>-r<N>` names the step and round the phase is in. Checked cases: `implement-Ф2-r1.001.glm`, `.002.glm`, `.003.luna` → `luna:` (not the failed GLM task); `implement-Ф2-r1.001.luna`, `.002.sol` → `sol:` (no tie).
  3. **No sidecar for the phase, or `status` rejects the id** (unknown id, other workspace) → `impl=—`, and never pick a job by recency: apply Durable Progress item 3 — `git log` / `git status` show the phase's implementation → resume at the step the newest report and review package in `$dir` name, with the next dispatch FRESH in the §5.4 composition for its operation type (lost handle, §5.6 — an `implement` dispatch carries no re-brief); not implemented → first-round dispatch per the ladder.

### 5.10 "Pre-dispatch checklist"

- Item 5 (**Codex only**) — the role list becomes: plan review = `gpt-6-astra`/xhigh; control review = `gpt-6-astra`/high; **availability-fallback implementer = `gpt-6-luna`/max; risk-marked-phase implementer and reasoning escalation = `gpt-6.1-sol`/xhigh**; final-review fallback = `gpt-6-astra`/xhigh. Resume rule addition: a Codex resume never references a `zt-` id. Implementer dispatches only: the **admission condition** of §5.3 holds — the current phase id (plan-wide operations: every phase id) is a key of `risk_phases` **and** the plan file is clean in `git status`; the prompt is a dispatch file under `$dir/prompts/` at the next seq, whose operation matches the step and whose composition matches the dispatch kind (resume vs FRESH, §5.4).
- New item 10 (**GLM only**): dispatched as `"$ZDISPATCH" task --background --prompt-file "$dir"/prompts/<op>-<phase>-r<N>.<seq>.glm.md` (no `--model`/`--effort` exist — the wrapper pins them); the dispatch file **begins with the ZCode preamble** (§6.1), its operation matches the step and its composition the dispatch kind; the same admission condition holds; fix, gate-fix and `NEEDS_CONTEXT` rounds carry `--resume-task zt-…` (never a `task-` id); parallel tracks carry `--cwd` on the task and on every later `status`/`result`; the state line shows `glm=ok`; the phase's `risk_phases` entry exists and is empty; the kill switch is not active. Any check fails → fix the dispatch or re-run the ladder; never dispatch and patch later.

### 5.11 Other `SKILL.md` edits

- **Rule 1** bullet "Full protocol tasks → Codex implementer, Luna max" → "Full protocol tasks → the implementer chosen by the channel ladder (GLM via `$ZDISPATCH`, Luna/Sol via `$DISPATCH`; `./implementer-prompt.md`)".
- **"Role"** paragraph and the **"Triage"** block's "Codex implementer (Luna max)" → "implementer per the channel ladder".
- **"Reporting cadence"** — channel lines are mandatory and one line each: `Ф2 → GLM-5.3-Flash max via ZCode (zt-0007).` · `GLM channel failed (errorClass=quota) — Ф2 falls back to Luna max (task-0012); GLM off for this session.` · `Ф3 is risk-marked (DATA_LOSS) → Sol 6.1 xhigh (task-0013).` · `Ф2 review round 3 still BLOCKING → fix round 3 on Sol 6.1 xhigh (task-0015).` · `Gate stalled on Ф2 → Opus diagnosis: ENVIRONMENT (machine) — paused; commands for you below.`
- **"Prompt templates (siblings)"** — the `implementer-prompt.md` line reads "GLM-5.3-Flash max via ZCode (default) / Codex Luna max (fallback) / Codex Sol xhigh (risk-marked phases, escalation), implementation + fix rounds (Step 3 / 3.5 / 4 / 5, non-frontend phases); carries the ZCode preamble and the channel-switch notice".
- The sentence "Codex is invoked via `companion.mjs --background` + Monitor poll … Read the `codex-invocation` skill before your first Codex call" gets a sibling: "GLM is invoked via `zcode-dispatch --background` + the same Monitor poll. Read the `zcode-invocation` skill before your first GLM call in a session."

### 5.12 "Red Flags — never" — six new bullets

1. **Extract tokens from `~/.zcode`, read `credentials.json`, or call the Z.ai API / SDK directly** — violates the Coding Plan terms. The ZCode CLI through `$ZDISPATCH` is the only channel.
2. **Give GLM a SECURITY / DATA_LOSS phase** — risk-marked phases run on Sol in the Codex sandbox.
3. **Run two write tasks in one working tree across both dispatchers**, or more than 2 write tasks in total — `status` on **both** dispatchers before every dispatch.
4. **Switch implementer channels silently** — every fallback and escalation is one announced line (Reporting cadence).
5. **Call `zcode -p` (or `node zcode.cjs`) bypassing the wrapper** — the wrapper is what guarantees the env, the identification headers, the git-tree guard and the job record.
6. **Change ZCode settings, plugins or login on the user's behalf** — model selection via `/model`, logging in, enabling or disabling plugins are user actions; the orchestrator asks, never does.

The existing `--resume-last` bullet gains: "ids are per dispatcher — a `zt-` id never goes to `$DISPATCH`, a `task-` id never to `$ZDISPATCH`."

---

## 6. Prompt, documentation, safety

### 6.1 `implementer-prompt.md` — three additions, templates unchanged

**(a) Invocation** gains the GLM variant next to the Codex one:

```bash
"$ZDISPATCH" task --background [--cwd <worktree-path>] [--resume-task zt-NNNN | --fresh] --prompt-file "$dir"/prompts/<op>-<phase>-r<N>.<seq>.glm.md
```

with the note: resolve `$ZDISPATCH` per `zcode-invocation`; the wrapper pins the model; the dispatch file's first block is the ZCode preamble below; fix rounds use `--resume-task <this phase's zt-id>`. The paragraph "Write the filled prompt to a scratch file first" is replaced for **both** dispatchers by the prompt-file scheme of SKILL.md Step 3 ("Prompt files and the retry / channel-switch rule"): body file `$dir/prompts/<op>-<phase>-r<N>.md`, per-dispatch file `<same>.<seq>.<glm|luna|sol>.md` composed per operation type and dispatch kind, `.id` sidecar with the dispatched id. Prompts no longer live in the session scratchpad.

**(b) ZCode preamble** — new section placed before "## First-round prompt template", prepended verbatim to **every** GLM dispatch (first round, fix rounds, gate-fix rounds, Step 5 wave, integration repair):

```
## ZCode headless run — read this first

- This is a headless, non-interactive run. Nobody can answer questions. Do not ask. If something is unclear, stop and finish with the status token `NEEDS_CONTEXT` (first round) or `BLOCKED`, with the specific question in your final message.
- Do not invoke skills, plugins, dynamic workflows, sub-agents, browser or computer-use tools, or goal mode. Use only file reads, file edits and shell commands.
- No git operations that change history, refs or the index: no `git commit`, `git push`, `git branch`, `git checkout`, `git switch`, `git stash`, `git reset`, `git rebase`, `git add`. Read-only git (`git status`, `git diff`, `git log`, `git show`) is fine.
- Stay inside the repository root named below. Never read or write `~/.zcode`, `~/.ssh`, `~/.aws`, keychains, or any credential store, and never read `.env` files outside the repository.
- Network only for package installs the plan explicitly requires (for example an `npm install` / `pip install` of a dependency the plan names). No other downloads, no API calls.
- Write the full report to [REPORT_FILE] (create parent directories if needed). Your final message is at most 15 lines; line 1 is the bare status token and nothing else.
```

**(c) Channel-switch notice** — new short block, inserted right after the opening paragraph of whichever template is used, whenever a phase moves between channels or a channel retries after an infrastructure failure (Luna fallback, Sol escalation, `--fresh` retry):

```
## Previous attempt

A previous run on another implementer (<GLM-5.3-Flash via ZCode | Codex Luna>, job <zt-NNNN | task-NNNN>, status <failed/<errorClass> | BLOCKED | review stall after round 3 | gate stall>) worked on this same task before you. It may have left uncommitted partial changes in the working tree and a report at [REPORT_FILE]. Before anything else: `git status --porcelain` and `git diff <base-sha>`; read [REPORT_FILE] if it exists (including every `## Fix round` section). Your task and its scope are exactly what the sections after this notice say — a fix round stays a fix round: fix only its AUTHORIZED_BLOCKERS and append to the same [REPORT_FILE] under the same `## Fix round <N>` heading. Keep partial work that falls inside that scope and matches the plan, redo what does not, and say in your report what you kept.
```

For the `--fresh` retry on the same channel the first sentence names the same model ("a previous run of this implementer"). Where the notice sits is fixed by the composition rule (§5.4): on an `implement` dispatch it follows the first-round template's opening paragraph and there is **no** re-brief (that block declares a fix round); on a FRESH fix-type dispatch the existing fresh-fallback re-brief block keeps its existing role — it **replaces** the fix-round template's opening paragraph — and the notice follows it; on a thread resume neither block appears. The re-brief block's text is unchanged.

### 6.2 Wrapper pins (restating §4.3 as requirements)

`--mode yolo`, `--output-format json`, `--surface terminal`, `--workflow-mode disabled`, `--cwd <workspaceRoot>`; never `--target`; `--disallowedTools` only after discovery confirms its scope (U6), and then only for tools irrelevant to implementation (browser-use, computer-use, presentations and similar plugin tools) — never as a substitute for the preamble.

### 6.3 New skill `skills/zcode-invocation/SKILL.md`

Mirrors `codex-invocation` section by section:

1. Frontmatter `name: zcode-invocation`; description: how to invoke GLM-5.3-Flash through Z.ai's ZCode CLI via the `zcode-dispatch` wrapper — background tasks + Monitor polling; read before the first GLM call in a session, including from dev-orchestrator.
2. **What this is** — ZCode is Z.ai's official harness; the plan's terms; the compliance stance (§6.5) and the sandbox warning (§6.6) in the user's face, not buried.
3. **Working path** — (1) resolve `$ZDISPATCH` (snippet §4.1); (2) one-time setup, user actions only: install ZCode.app, log in **in the app**, select the model in the CLI as discovery U1 prescribes (documented as a `!`-prefixed user command, never run by the orchestrator); (3) `doctor`, then `doctor --probe` once per session — what each line means, that a FAIL means Luna for the session, and that after compaction the dev-orchestrator session marker (its §5.9), not a new probe, restores the state; (4) submit a task — always `--background`, always `--prompt-file`, preamble first; (5) the Monitor loop (identical to `codex-invocation` step 5 with `$ZDISPATCH` and `zt-` ids, terminal-only `case` guard non-negotiable); (6) fetch the result.
4. **Flag reference** — the verbs and flags of §4.2; the pins of §6.2; the env overrides of §4.10.
5. **Resume semantics** — §4.6; the `--resume-task zt-…` → `--resume sess_…` mapping; the per-workspace ids; what to do when the wrapper refuses a resume (`--fresh` at the next seq, composed per dev-orchestrator §5.4 for the operation type — the re-brief only on fix-type operations, never on `implement`).
6. **Parallel tasks and worktrees** — `--cwd`; width cap across both dispatchers; the "GLM concurrency: 1 | 2" line from discovery.
7. **Terminal status handling** — the errorClass → action table of §7.
8. **Sandbox warning** — §6.6 verbatim.
9. **Compliance** — §6.5.
10. **Never do** — the six Red Flags of §5.12 in wrapper terms, plus: never run `doctor --probe` when the session marker already exists — one probe per session, the marker carries the result across compaction (it spends quota); never omit `--background`; never print per-poll status.
11. **Session paths** — wrapper, `.mjs`, state dir, job log, the constants `PINNED_MODEL`, `VERIFIED_APP_VERSION`, `VERIFIED_NODE_MAJOR`, `MAX_PROMPT_BYTES`, `PROMPT_TRANSPORT`, and `docs/zcode-cli-findings.md`.

`codex-invocation` itself changes in three places: the role table's "Implementation + fix rounds" row becomes "Availability-fallback implementation (Luna max) / risk-marked phases and reasoning escalation (Sol xhigh)"; "Parallel tasks and worktrees" says the width cap counts ZCode jobs too; a one-line pointer to `zcode-invocation` at the top.

### 6.4 Documentation and release

- `README.md` and `README.ru.md` (mirrored, same sections): "Quick start → 1. Install the prerequisites" (ZCode.app installed and logged in is **optional** — without it `doctor` fails and the pipeline runs on Luna, announced); "Delivery protocol" step 3 (GLM builds, Luna is the fallback, Sol the escalation and the risk-phase implementer); "Model roles" table (rows of §5.1); "Guardrails" — one new bullet: *Terms-respecting GLM access — GLM is reached only through Z.ai's own ZCode CLI with truthful client identification; no raw API, no token extraction; GLM never receives SECURITY / DATA_LOSS phases and runs unsandboxed only inside a git tree under the preamble's restrictions*; "Inside the plugin → Fork-specific capabilities" rows for `zcode-invocation` and `bin/zcode-dispatch`. The workflow SVGs under `assets/readme/` are updated only if their text names Luna as the builder; otherwise left alone.
- `PLUGIN_README.md`: version line → `0.8.0`; the `dev-orchestrator` bullet; a new `zcode-invocation` bullet; "Machine-specific assumptions" paragraph: ZCode.app at `/Applications`, the embedded CLI, Node ≥ the verified floor, no `zcode` on PATH, state under `~/.claude/plugins/data/superpowers-strigov-ver-zcode`.
- `.claude-plugin/plugin.json`: `version` → `0.8.0`; description mentions the GLM implementer via ZCode, Luna fallback, Sol for risk-marked phases; keyword `glm`, `zcode`.
- `skills/dev-orchestrator/SKILL.md` frontmatter description; `final-review-prompt.md`, `opus-review-prompt.md`, `codex-control-review-prompt.md` where they say "Luna-written code" → "the implementer's code" (reviewers must not assume the family).
- `docs/zcode-cli-findings.md` — the discovery output (§8, §9, §10): verified facts only, each with how it was verified and the ZCode version it holds for.

### 6.5 Compliance

The wrapper passes the real `ZCODE_APP_VERSION` from `Info.plist` and `--surface terminal`; it adds no headers, rewrites none, and never pretends to be the desktop app. Nothing reads `~/.zcode`. If Z.ai ever declares headless use of the CLI unsupported, the kill switch (`SP_IMPLEMENTER=luna`) turns the channel off without code changes.

### 6.6 Sandbox warning (verbatim in `zcode-invocation`)

> GLM runs **unsandboxed**, as your user account, in ZCode's `yolo` mode: it can read and write any file you can and reach the network. Codex's `--write` tasks are sandboxed to the workspace; GLM's are not. Mitigations in this plugin: the wrapper refuses to start outside a git work tree; every prompt begins with the ZCode preamble (no credentials, no paths outside the repo, no network beyond plan-mandated installs, no git history operations); phases carrying SECURITY or DATA_LOSS risk never go to GLM — they run on Codex Sol inside its sandbox. These are instructions to a model, not an enforcement boundary. If that is not acceptable for a repository, run it with `SP_IMPLEMENTER=luna`.

Upgrade path to a real boundary: a permission broker over `zcode app-server` with `--mode guarded` (approach C) — recorded as future work (§11).

### 6.7 Kill switch

- **Session:** the user says "через Luna" or "без GLM" (in any sentence of the session) → `glm=off`, written to the session marker (§5.9) so it survives compaction; ladder item 1 for every phase until the session ends. Nothing re-enables GLM within the session.
- **Permanent:** `SP_IMPLEMENTER=luna` in the environment → the orchestrator sets `glm=off` at every skill start (`echo "${SP_IMPLEMENTER:-}"`, allowed bookkeeping; the marker is re-written), and the wrapper refuses `task` anyway (§4.7 item 6).
- Nothing else: no per-phase toggles, no config file, no other values of `SP_IMPLEMENTER`.

---

## 7. Error handling — errorClass → action

**Classifier** (in the runner; one ordered pattern list at the top of the `.mjs`, filled in from `docs/zcode-cli-findings.md` — §10 U4; first match wins):

| # | Condition | errorClass |
|---|---|---|
| 1 | The runner's own timeout fired | `timeout` |
| 2 | `spawn` error (`ENOENT`, `EACCES`, node or `zcode.cjs` missing) | `launch` |
| 3 | stderr/stdout matches a model-not-selected pattern (initially `Select a model before continuing`, `Model creation failed`) | `model-not-selected` |
| 4 | matches an auth pattern (initially `401`, `unauthorized`, `not logged in`, `login`, `token expired`, `credential`) | `auth` |
| 5 | matches a quota pattern (initially `429`, `quota`, `rate limit`, `usage limit`, `insufficient`, `balance`) | `quota` |
| 6 | matches a startup pattern (initially `ZCODE_BUILTIN_PROVIDER`, `provider config`, `Cannot find module`) | `launch` |
| 7 | non-zero exit or killed by a signal the wrapper did not send | `crash` |
| 8 | exit 0 but stdout is not one JSON object with a string `response` | `malformed` |

Patterns are matched case-insensitively against the last 200 lines of stderr plus stdout. The default for anything unrecognised is `crash` — unknown strings cost a retry and a Luna fallback, never a false success.

**Orchestrator action** (identical to §5.4's first-match list, repeated here as the table the `zcode-invocation` skill carries):

| Terminal state | Action |
|---|---|
| `completed` | `result`; parse line 1; malformed token → re-dispatch once with `--resume-task <zt-id>`, then user |
| `failed` / `quota`, `auth`, `model-not-selected` | `glm=down` for the session (state line + marker); announce; the **same operation** on Luna max FRESH — next-seq `.luna` dispatch file in the FRESH composition for its operation type, unchanged body (§5.4) |
| `failed` / `timeout`, `crash`, `launch`, `malformed` | one retry of the **same operation** on GLM: `--fresh`, next-seq `.glm` dispatch file in the FRESH composition, unchanged body; second failure → Luna as above (`glm=down` only if the second class is quota/auth/model-not-selected) |
| `cancelled` | report to the user, wait |
| `doctor --probe` FAIL (before any task) | `glm=down` (state line + marker); announce once; Luna for the session |
| wrapper exit 2 on `task` (guard) | not a job failure — fix the dispatch (wrong cwd, missing prompt file, another job running, kill switch); if the guard is `Info.plist`/`zcode.cjs` missing → treat as `doctor` FAIL |

---

## 8. Testing and acceptance

### 8.1 Unit tests — `tests/test-zcode-dispatch.sh` (zero model calls)

Written in the style of `tests/test-sdd-scripts.sh` (`pass`/`fail` helpers, `mktemp -d` root, `git init -q -b main`, physical-path comparison, exit-code assertions, cleanup trap). Fixtures:

- `tests/fixtures/zcode-stub.cjs` — a Node script standing in for `zcode.cjs`, selected via `ZCODE_BIN`. Behaviour by env `ZCODE_STUB_MODE`: `ok` (prints a canned JSON object with `sessionId: "sess_stub_<pid>"`, a `response` whose line 1 is `DONE`, a `usage` object; exit 0) · `pong` (`response: "PONG"`) · `resume` (asserts `--resume <sess>` is present, echoes that session id) · `record` (writes its argv and the three env variables to `$ZCODE_STUB_RECORD`, then behaves as `ok`) · `model-not-selected` / `auth` / `quota` / `launch` (prints the corresponding string to stderr, exit 1) · `hang` (sleeps 600 s) · `crash` (`process.kill(process.pid, 'SIGKILL')`) · `malformed` (prints `not json`, exit 0).
- `tests/fixtures/FakeZCode.app/Contents/Info.plist` (XML, `CFBundleShortVersionString` = `9.9.9`) and `Contents/Resources/config/provider/zcode-builtin.json` (`{}`), selected via `ZCODE_APP`. `ZCODE_STATE_DIR` points into the test root.

Assertions:

1. `task --background --prompt-file f` prints `ZCode Task started in the background as zt-0001`; the next task is `zt-0002`.
2. `record` mode: argv contains `--output-format json`, `--mode yolo`, `--surface terminal`, `--workflow-mode disabled`, `--cwd <repo root>`; no `--target`, no `--json`; the prompt arrives by the transport the wrapper's exported `PROMPT_TRANSPORT` constant names (`argv`: `-p <file contents>`; `stdin`: `-p -` plus the contents on stdin — chosen per discovery U10); env has both provider variables = the fake config path and `ZCODE_APP_VERSION=9.9.9`.
3. `status zt-0001 --json` → `running` then `completed`; `result zt-0001` prints the response; `sessionId` and `usage` stored in the record; `status --json` without an id lists at most 10 terminal jobs, `--all` lists every job.
4. `--resume-task zt-0001` → stub (`resume` mode) sees `--resume sess_stub_…` equal to job 1's; the new record has `resumeOf: zt-0001` and the same `sessionId`; resuming a running job → exit 2; resuming a failed job → exit 2; `--resume-task` + `--fresh` → exit 2; a `task-0001` id → exit 2.
5. `ZCODE_TASK_TIMEOUT_MIN=0.05` + `hang` → `failed/timeout` within ~15 s (3 s timeout + 10 s SIGKILL grace) and the stub process is gone.
6. `crash` → `failed/crash`; `malformed` → `failed/malformed`; `model-not-selected`, `auth`, `quota`, `launch` → the matching errorClass; `ZCODE_NODE=/nonexistent/node` (a spawn `ENOENT` that no guard catches) → `failed/launch`.
7. Dead runner: start `hang`, `kill -9 <runnerPid>`, then `status` → `failed/crash` with note `runner died`, and the stub child is gone.
8. `cancel` on a `hang` job → `cancelled`; group gone; a later runner write does not overwrite `cancelled`.
9. Worktree isolation: a job started with `--cwd <linked worktree>` is `zt-0001` in its own workspace, invisible to `status` without `--cwd`, visible with it.
10. Refusals (exit 2): outside a git tree; missing/empty prompt file; prompt file larger than the wrapper's exported `MAX_PROMPT_BYTES` constant (initially 200 KB, set from U10; the test reads the constant, and is skipped when `PROMPT_TRANSPORT` is `stdin`); second `task` while one is `running` in the same workspace; `SP_IMPLEMENTER=luna`; `ZCODE_APP` without a readable `Info.plist`; unknown id on `status`/`result`/`cancel`.
11. `doctor` offline: all `ok` against the fixtures (node WARN allowed); FAIL lines and exit 1 for a missing `zcode.cjs`, a missing provider config, outside a git tree.
12. `doctor --probe` with the stub: `pong` → `probe: ok`, exit 0, `reported-model: unreported`; `model-not-selected` → `model-selected: FAIL(model-not-selected)`, exit 1.
13. `bin/zcode-dispatch` shim resolves the dev-tree `.mjs` when no marketplace cache exists.

### 8.2 Live acceptance (small Coding Plan quota; no Opus or Codex calls)

1. Run the acceptance in a fresh session, outside the dev-orchestrator protocol, so that no earlier probe or task of the session falls inside the window. `"$ZDISPATCH" doctor` passes. **Baseline:** the user reads the Plan Overview deduction in the Z.ai console *now*, before any request of this run. Then `"$ZDISPATCH" doctor --probe` passes and reports GLM-5.3-Flash (or `unreported` with the U3 fallback in force); keep its `usage` line.
2. E2E on a throwaway git repo in a scratch directory: a tiny task through the wrapper with the real preamble + first-round template (e.g. "add a function and a test") → line 1 `DONE`, `[REPORT_FILE]` written, `git log` unchanged (nothing committed), the diff present in the working tree; keep the job's `usage`.
3. A fix round. If discovery U2 confirmed that `--resume` keeps model and effort: `--resume-task <zt-id>` → the new record carries the **same** `sessionId`, the fixer's final message shows it remembered the task (no re-exploration from scratch), and `## Fix round 1` is appended to the same report file. If U2 was unfavourable, the fix round is dispatched FRESH with the re-brief (the U2 fallback) and the criteria are only: line 1 `DONE`, `## Fix round 1` appended to the same report file. Keep the job's `usage`.
4. **1.5× bonus check.** The measurement window is exactly the three requests above (probe, E2E, fix round); nothing else may run on the plan between the baseline and the second reading, which the user takes now. Expected credits = Σ over the three `usage` objects of `(uncached_input × 2.3 + cached_input × 0.56 + output × 8) / 10,000`, with the field mapping recorded by discovery (U3): `cached_input` = the prompt-cache-read count; `uncached_input` = the input count **minus** `cached_input` when the CLI reports cached tokens as a subset of input, else the input count as reported; `output` = output tokens plus reasoning tokens when the CLI reports them separately. Record the local time: off-peak hours and weekends halve the deduction — run during peak hours or halve the expected value. Interpretation: measured ≈ expected / 1.5 (ratio expected/measured in 1.3–1.7) → bonus active; ratio in 0.85–1.15 → no bonus; anything else, or an unresolved field mapping → report the raw numbers as inconclusive, do not conclude. The result goes into `docs/zcode-cli-findings.md` and one sentence in `zcode-invocation`.

### 8.3 Not unit-testable

The channel ladder, the gate-stall and review-stall rules, the state-line fields and the Red Flags are model-facing prose in `SKILL.md`. They are verified by the plan review, the code review of the skill edits (Step 4.1 / 4.2 read prose too), and the first real `/dev` run on GLM, whose transcript should show: the announcement line per phase, `impl=glm:zt-…` in every state line, one probe per session, and a fix round resuming the same session (or, if discovery U2 forced the FRESH fallback, a fix round whose dispatch file carries the re-brief and appends to the same report file).

---

## 9. Suggested phase order (the plan writer owns the final ordering)

1. **Discovery spike on the ZCode CLI** → `docs/zcode-cli-findings.md`. Resolve every item of §10 by reading the modules in §2.8 and by running the CLI against a throwaway repo: how headless gets the model and whether `/model` persists; whether `--resume` keeps model and effort; whether the JSON exposes the effective model; the exact error strings and exit codes for auth / model / quota / hang; whether two `zcode` processes can run concurrently; what `--disallowedTools` applies to; whether a session is saved on SIGTERM; which plugins load headless; the prompt-size limit of `-p` and whether stdin works; the `usage` field names and whether cached tokens are a subset of input; what the desktop app passes as `ZCODE_APP_VERSION`. The wrapper's constants (`PINNED_MODEL`, `VERIFIED_APP_VERSION`, `VERIFIED_NODE_MAJOR`, `MAX_PROMPT_BYTES`, `PROMPT_TRANSPORT`) and pattern lists are filled from this file.
2. **Wrapper + tests**: `bin/zcode-dispatch`, `bin/lib/zcode-dispatch.mjs`, `tests/test-zcode-dispatch.sh`, fixtures (§8.1). Zero model calls.
3. **Protocol**: `skills/zcode-invocation/SKILL.md`; `dev-orchestrator/SKILL.md` edits (§5); `implementer-prompt.md` additions (§6.1); `codex-invocation` touch-ups (§6.3).
4. **Docs & release**: README.md, README.ru.md, PLUGIN_README.md, plugin.json description, version 0.8.0 (§6.4).
5. **Live acceptance** (§8.2) — run by the user with the orchestrator's help; its measured facts land in the findings doc and the skill.

Phase 1 is a go/no-go gate: if U1 resolves to "no headless model selection by any means" (§10), the plan stops after phase 1 and the user decides.

---

## 10. Open unknowns — resolved by the discovery phase

Each item: what is unknown · how to verify · what the design does if the answer is unfavourable.

| # | Unknown | Verify | Fallback if unfavourable |
|---|---|---|---|
| U1 | **How a headless `-p` run receives the model.** Candidates: a persisted CLI selection that `-p` honours (after a TUI `/model GLM-5.3-Flash$max` once); a flag or env variable not in `--help`; the model bound to a session on `--resume`. | Read `runtime-model.ts`, `prompt-command.ts` (`configuredDefaultModelSelection`, `legacyCliUserConfigFilePath`), `resume.ts`, `runtime-unbound-resume.test.ts`; then select in the TUI once and run `-p` PONG. | Persisted-by-user → the one-time `/model` selection is documented as a user action in `zcode-invocation`; the wrapper pins nothing; `doctor --probe` (+U3) is the check. Per-invocation mechanism → the wrapper passes it. **No way at all** → the GLM channel is not viable: ship nothing beyond the findings doc, keep 0.7.0 routing, user decides. |
| U2 | Does `--resume` keep model and effort? | Resume the probe session with a second `-p` and compare the reported model / behaviour; read `resume.ts`. | Resume resets the model → the mechanism from U1 is re-applied on every resume if per-invocation; if the model is only user-persisted and resume loses it, fix rounds are dispatched **FRESH** with the fresh-fallback re-brief (rule in `zcode-invocation`; the wrapper's mapping stays, the skill says not to use it). |
| U3 | Does the JSON object expose the effective model? What are the `usage` field names and semantics — is the cached count a subset of the input count, are reasoning tokens reported inside or beside output? | Inspect the probe's JSON; grep `prompt-command.ts` for the summary fields and core for the usage accumulator. | Model: `reportedModel` stays `null`, `doctor --probe` prints `unreported` and still passes; if U1 is user-persisted, the orchestrator asks the user **once per session** to confirm `/model` is `GLM-5.3-Flash$max` before the first dispatch. Usage: an unresolved mapping makes the bonus check (§8.2) inconclusive — it is reported as such, never guessed. |
| U4 | Exact error strings and exit codes for auth, model-not-selected, quota, hang. | Provoke each (logged-out copy is **not** acceptable — do not log out the user's CLI; use the existing model-not-selected state, read `process-errors.ts`, `runtime-model.ts`, and the auth/quota paths in core for the strings). | Unmatched strings classify as `crash` → one retry, then Luna; the pattern list is the single place to extend. |
| U5 | Can two `zcode -p` processes run concurrently (one per worktree)? Possible lock on `~/.zcode/cli/db` / `tasks-index.sqlite`. | Start two PONG runs in two worktrees at once; look for lock errors in stderr. | One GLM track per parallel group; the other track takes Luna for the group (§5.8). |
| U6 | What `--disallowedTools` applies to (built-in tools only, or plugin tools too). | `arguments.ts` `extractDisallowedToolsArgs` and its consumer in core; a run with a plugin tool disallowed. | The wrapper passes no `--disallowedTools`; the preamble is the only restriction. |
| U7 | Is the session saved when the CLI gets SIGTERM (timeout, cancel)? | Run `hang`-like long prompt, SIGTERM it, try `--resume`. | After a timeout the retry is `--fresh` (already the rule); a `cancelled` job is never resumed. |
| U8 | Which of the 13 plugins load headless and whether any auto-activates (hooks, dynamic workflows). | `--verbose` run; `zcode plugins` output; `plugins-command.ts`. | Preamble forbids invoking them; `--workflow-mode disabled` is pinned; an interfering plugin is named in the findings doc and the **user** disables it (Red Flag 6); if U6 allows, the wrapper disallows its tools. |
| U9 | Is the 1.5× ZCode quota bonus active? | §8.2 step 4. | Cost model without the bonus; Flash's multipliers still make GLM the cheapest channel; no protocol change; the README states the measured ratio. |
| U10 | Prompt-size limit of `-p` in argv; whether `-p -` reads stdin. | Run with a 150 KB and a 300 KB prompt; `arguments.ts`. | `MAX_PROMPT_BYTES` (initially 200 KB) is lowered to the measured limit; if stdin works, `PROMPT_TRANSPORT` becomes `stdin` and the size guard (and its test) go. |
| U11 | What the desktop app sets as `ZCODE_APP_VERSION` (`3.15.1` vs `3.15.1.8093`). | `ps -Eww` on the CLI process spawned by the running app, or the app's main-process source. | Use `CFBundleShortVersionString` (`3.15.1`). |

---

## 11. Out of scope / future work

- **Approach C** — a permission broker over `zcode app-server` with `--mode guarded`, giving GLM a real approval boundary instead of yolo. Future work; the wrapper's job-record shape is designed so a broker-backed runner can replace `__run` without changing the verbs.
- GLM as a planner, reviewer, spec writer, or diagnosis model; GLM for frontend phases; other GLM models (full GLM-5.3) or efforts other than `max`.
- Raw Z.ai API or SDK access, token extraction, any use outside the ZCode CLI — forbidden, not deferred.
- Installing the ZCode `superpowers-plugin` or any plugin into the user's ZCode; changing ZCode settings programmatically.
- Changes to the Codex reviewer roles, the plan writer, the ledger, caps, or the frontend route.
- Automated quota accounting beyond the one-off bonus measurement; Linux/Windows support of the wrapper (macOS app bundle only).

---

## 12. Risks

| Risk | Mitigation | Residual |
|---|---|---|
| **Policy**: Z.ai treats headless/automated CLI use as "unsupported" → benefit restriction or ban after 3 violations. | Official harness only; truthful identification; no credential access; concurrency ≤ 2 (within Pro/Max guidance, above Lite's); the warning is in the skill; the kill switch disables the channel instantly. | Unknown stance; the user accepts it knowingly. |
| **No sandbox** in yolo mode. | Git-tree guard; preamble; risk-marked phases on Sol; `--workflow-mode disabled`; no `--target`. | Prose, not enforcement — see §6.6. Approach C is the fix. |
| **Quality gap** vs Luna/Opus (Terminal-Bench 84.3 vs 85.0; DeepSWE 63.4 vs 66.9). | Cross-family review unchanged; Sol escalation on BLOCKED, gate stall `CODE`, and round-3 stall; loop caps unchanged (on Sol phases the round-3 stall merely reaches the user one round earlier). | More fix rounds per phase than with Luna; measured on the first real runs. |
| **Discovery kills the feature** (U1: no headless model selection). | Phase 1 is a go/no-go gate; nothing else is built before it passes. | Time spent on the spike. |
| **Quota exhaustion mid-plan.** | `quota` → `glm=down` → Luna for the session, announced. | A partially implemented phase handed over with the channel-switch notice. |
| **App auto-update** moves `zcode.cjs`, changes flags or JSON shape. | `doctor` WARN on version mismatch; `launch`/`malformed` classes fall back to Luna; `VERIFIED_APP_VERSION` constant. | Live acceptance must be re-run per app version. |
| **Session-DB lock** between concurrent runs (U5). | One GLM track per group if confirmed. | Lower parallel throughput. |
| **Node coupling** — `zcode.cjs` is built for Electron's Node; system Node v26 works today. | `doctor` node check with a discovered floor; `ZCODE_NODE` override. | A future bundle may need a newer Node. |
| **Bonus not active** (U9). | Cost model without it; Flash remains the cheapest channel. | None for the protocol. |
| **Orchestrator drift** — a Sonnet main thread mis-applies the ladder. | First-match ordered lists, strict tokens, checklist item 10, state-line fields, Red Flags; announcements make a wrong channel visible. | Caught at the first real run. |

---

## 13. Decisions made by the spec writer where the approved design was silent

1. **Risk marking is persisted in the plan frontmatter** as one top-level `risk_phases` map that classifies **every** phase (empty list = scanned, no risk), written at Step 2.5 with one bookkeeping commit and re-derived in full after every post-approval plan revision; three compaction-safe guards (no key / unknown phase id / dirty plan file) trigger a re-scan before a dispatch (§5.3). Round 1 of this spec stored only the risk-marked ids; the reviewer showed that shape could not detect a stale map after a sub-phase split.
2. **Gate-stall diagnosis (Amendment 2) and the round-3 review-stall escalation are pipeline rules for every non-frontend channel** — GLM, Luna (fallback *or* kill switch) and, for the diagnosis, Sol. Only the hand-off mechanics differ: GLM → fresh Sol with re-brief; Luna → Sol resuming the Luna thread; Sol → the user on `CODE` and on a round-3 stall ("nothing above Sol") (§5.5, §5.6). Round 1 had scoped both rules to GLM; the orchestrator ruled otherwise.
3. **Session-wide `glm=down`** is set not only by a failed `doctor`/probe but also by a `quota | auth | model-not-selected` failure — "retry pointless" read as session-wide; a second `glm` field in the state line carries it, and a **session marker file** in the host's session scratchpad makes `ok`/`down`/`off` survive compaction without a second probe (§5.4, §5.9, §6.7).
4. **A channel-switch notice** block was added to `implementer-prompt.md` so a fallback or escalation dispatch knows that partial work may already be in the tree, and it states that the operation's scope is unchanged (§6.1 c). Composition is fixed per operation type and dispatch kind (§5.4): `implement` never carries the fix-round re-brief; the re-brief appears only on FRESH fix-type dispatches, where it replaces the template's opening paragraph as `implementer-prompt.md` already prescribes; thread resumes carry neither block. (Round 1 had prepended the re-brief on every fresh retry, which contradicted the first-round template.)
9. **Operation / body / dispatch-file scheme with `.id` sidecars under `$dir/prompts/`** (§5.4): prompt files move from the session scratchpad into the plan-scoped workspace, every retry or channel switch re-dispatches the same operation body, and the sidecar binds each dispatched id to plan, operation, phase, round and a **per-phase dispatch sequence number** that is monotonic across channels, so "highest seq wins" is unambiguous after any fallback or escalation — the only durable binding available, since the Codex companion stores the prompt text but not its path (§5.9 recovery; "never pick a job by recency"). (Round 1 used per-channel attempt counters, which made recovery pick the wrong channel.)
5. **Wrapper guards beyond the two named** (git tree, prompt file): refuses a second running job in the same workspace, refuses when `SP_IMPLEMENTER=luna`, refuses when `Info.plist` is unreadable, refuses prompts over `MAX_PROMPT_BYTES` on the argv transport (§4.7). All are mechanical restatements of existing rules (one write task per tree; kill switch; truthful identification).
6. **Exit-code, record-schema, id-allocation, liveness and sticky-terminal details** (§4.2–4.6) were fixed so the plan writer does not have to invent them; they mirror the Codex companion's observable behaviour.
7. **`doctor` carries two WARN-only version checks** (`VERIFIED_APP_VERSION`, `VERIFIED_NODE_MAJOR`) so an app auto-update is noticed before it breaks a run (§4.8).
8. **`doctor --probe` passes with `reported-model: unreported`** (U3 fallback) rather than failing — otherwise an unfavourable U3 would disable the channel for a cosmetic reason; the compensating one-per-session user confirmation applies only when U1 is user-persisted (§10).
