# 00 — Current dispatcher architecture (baseline for a generic multi-harness dispatcher)

- **Key:** `00-current-architecture` · **Date:** 2026-10-20 · **Method:** local source reading plus two local runs (the stub test suite and an offline probe of the Codex companion against a fabricated job store). No web, no model calls.
- **Source snapshot:** working tree at `main` = `c1aa9e0`. The branch `research/universal-dispatchers` (`ecdc5da`) is an ancestor of `main`. Its only differences are docs and README text plus 4 lines in `skills/zcode-invocation/SKILL.md`; no code differs. All `[source:…]` line numbers refer to `c1aa9e0`.
- **Tags:** `[source:<path>:<lines>]` (repo-relative), `[local-run]`, `[unverified]`.

## Bottom line

1. Two wrappers implement one **de-facto contract**, and it holds only as far as the orchestrator uses it: `task --background [--cwd] [--resume-task <id> | --fresh] --prompt-file <f>` → a start line with the id. Then `status <id> --json` → `['job']['status']` ∈ {completed, failed, cancelled}, polled by a Monitor `until` loop. Then `result <id>` → the harness's final message, whose **line 1** is the status or verdict token. Everything else differs between the two wrappers: exit codes, id format, `result` on failure, errorClass, write locking and liveness (§1.10).
2. `bin/lib/zcode-dispatch.mjs` (1,673 lines) is already **~70 % harness-agnostic**: about 900 lines are generic as written and about 250 more are generic mechanisms that take adapter-supplied values. Only about 470 lines are ZCode/GLM-specific (§2). The code already has adapter hooks: `PROMPT_TRANSPORT`, `MODEL_ARGS`/`MODEL_ENV`, `REPORTED_MODEL_PATH`, `USAGE_FIELDS`, `PATTERNS`, `ENV_ALLOW`/`ENV_DENY`.
3. The **Codex companion is the weaker base**. It has no per-workspace write lock, no task timeout and no reaping of dead workers (a killed worker leaves a job `running` forever). It has no errorClass. It exits 1 for every error, and `result` exits 0 for a failed job. A generic core should be built from the ZCode runner, not from the companion.
4. The orchestrator hardcodes **three channels** (`glm` / `luna` / `sol`), **two dispatchers** (`$ZDISPATCH` / `$DISPATCH`) and **two id prefixes** (`zt-` / `task-`). That shows up in roughly 25 places: the state line, the session marker, the kill switch, the ladder, the dispatch-file suffix, the checklist items, the failure ladders, the stale-reservation procedure, the parallel-group rules and the Red Flags (§3). Most of these mechanisms are already **channel-name-agnostic**: the sidecar `channel:id`, the "highest seq wins" rule and the verdict tokens. Only the enumerated values are hardcoded, so a **channel-profile registry** can replace them mechanically.
5. One hidden capability manifest already exists in prose: zcode-invocation "Verified facts" (`Model selection`, `Model confirmation`, `GLM resume`, `GLM concurrency`), which dev-orchestrator reads. Promote it to per-profile fields.
6. **Reviewer channels are Codex-only today.** zcode-dispatch has no read-only mode: every task takes the write reservation and runs `--mode yolo`. A generic dispatcher therefore needs a `--read-only` task kind that skips the reservation and is enforced by the harness, not by prose.
7. **Family rule:** with `claude -p` pointed at GLM or DeepSeek endpoints, the harness family ≠ the model family. Profiles must declare the **model** family, and the writer/reviewer check must use it.
8. The stub-CLI test pattern is directly reusable: an env-selected fake binary, mode switches, a record mode, and exported constants used as the test oracle. Locally: **110 PASS, 0 FAIL** `[local-run]`.

---

## 1. The de-facto dispatcher contract

### 1.1 Verbs and flags

| Verb | `zcode-dispatch` (ZCode/GLM) | `codex-dispatch` → vendored companion | What the orchestrator relies on |
|---|---|---|---|
| `task` | `task --background [--cwd P] [--resume-task zt-N \| --fresh] --prompt-file F`. `--background` is mandatory; without it, exit 2 [source:bin/lib/zcode-dispatch.mjs:1154-1166]. `--resume-task` and `--fresh` are mutually exclusive [:1167]. No model/effort flags: the model is pinned [:31,50]. | `task [--background] [--write] [--model M] [--effort E] [--cwd P] [--resume-task ID \| --resume-last \| --fresh] [--prompt-file F \| "prompt" \| stdin] [--json]` [source:vendor/codex-companion/scripts/codex-companion.mjs:749-803]. The bash shim injects `--model gpt-6.1-sol` when no `--model` is given [source:bin/codex-dispatch:54-66]. | Always `--background`, always `--prompt-file`, `--cwd` for worktrees [source:skills/dev-orchestrator/SKILL.md:209,214] |
| `status` | `status [id] [--cwd] [--all] [--json]` → `{"job":{…}}` or `{"workspaceRoot","running","recent"}` (10 newest terminal jobs) [source:bin/lib/zcode-dispatch.mjs:1351-1370]. Runs the liveness reaper first [:1354]. | `status [id] [--cwd] [--all] [--json] [--wait --timeout-ms --poll-interval-ms]` → `{"workspaceRoot","job"}` [source:vendor/codex-companion/scripts/codex-companion.mjs:869-894; lib/job-control.mjs:242-254]. Accepts a unique id prefix [lib/job-control.mjs:191-211]. | `status "$ID" --json`, parsed as `['job']['status']` (and `['job']['errorClass']` for GLM) |
| `result` | `completed` → the stored `response` verbatim, exit 0. Any other state → stderr `job <id> is <status> errorClass=<class>` plus the last 20 log lines, exit 1 [source:bin/lib/zcode-dispatch.mjs:1372-1384]. | Prints `rawOutput` (or the rendered failure text), then the trailer `\nCodex session ID: <thread>\nResume in Codex: codex resume <thread>`. Exits 0 even for a `failed` job; a running id → `No job found …`, exit 1 [source:vendor/codex-companion/scripts/lib/render.mjs:390-419] [local-run]. | Machine-reads line 1 only [source:skills/dev-orchestrator/SKILL.md:124-142] |
| `cancel` | Claims a sticky `cancelled`, SIGTERM to the CLI process group, 5 s grace, then SIGKILL. A terminal job prints `<id> is <status>`, exit 0 [source:bin/lib/zcode-dispatch.mjs:1386-1410]. | Interrupts the app-server turn, terminates the worker process tree, writes `cancelled`. A terminal id → `No job found`, exit 1 [source:vendor/codex-companion/scripts/codex-companion.mjs:949-1008] [local-run]. | Rarely used; `cancelled` → report to the user and wait [source:skills/dev-orchestrator/SKILL.md:426] |
| health | `doctor [--cwd]` offline checks, `doctor --probe` = one PONG request [source:bin/lib/zcode-dispatch.mjs:1412-1560]. | `setup [--json]` / `status --json` as a sanity check [source:skills/codex-invocation/SKILL.md:45-53]. | GLM: doctor + probe once per session → `glm=ok\|down` [source:skills/dev-orchestrator/SKILL.md:366] |
| extra | `release-stale` [:840-885]; `api-key set\|clear` (user-only; key read from stdin) [:1605-1635]; internal `__run` [:1655-1656]. | `review`, `adversarial-review`, `task-worker`, `task-resume-candidate` [source:vendor/codex-companion/scripts/codex-companion.mjs:1017-1049]. | Codex reviews use `task` without `--write`, not the native `review` verb [source:skills/dev-orchestrator/codex-control-review-prompt.md:8-18] |

### 1.2 Lines the orchestrator parses

| Output | ZCode | Codex | Parsed how |
|---|---|---|---|
| Start line (stdout) | `ZCode Task started in the background as zt-NNNN` [source:bin/lib/zcode-dispatch.mjs:1244] | `Codex Task started in the background as task-<id>. Check /codex:status task-<id> for progress.` [source:vendor/codex-companion/scripts/codex-companion.mjs:569-571]. `--json` gives `{jobId,status:"queued",…}` [:687-695,800-801]. | Read by the model and written to the `.id` sidecar as `glm:zt-…` / `luna:task-…` / `sol:task-…` [source:skills/dev-orchestrator/SKILL.md:389]. The ZCode tests take the last word [source:tests/test-zcode-dispatch.sh:146-150]; for Codex the last word is `progress.`, so the two lines are not uniformly parseable. |
| Poll | `status ID --json` → `job.status` | same path | Monitor loop `until … case completed\|failed\|cancelled … sleep 25` [source:skills/zcode-invocation/SKILL.md:89-103; skills/codex-invocation/SKILL.md:120-134] |
| Failure class | `status ID --json` → `job.errorClass` [source:skills/zcode-invocation/SKILL.md:167] | none (free-text `errorMessage`) [source:vendor/codex-companion/scripts/lib/tracked-jobs.mjs:181-201] | GLM ladder keys on the class [source:skills/dev-orchestrator/SKILL.md:422-428] |
| Result | line 1 = token | line 1 = token (trailer appended after the message) | first non-empty line, whitespace and emphasis stripped, exact match against the step's token set [source:skills/dev-orchestrator/SKILL.md:134-138] |
| Exact stderr strings | `zcode-dispatch: failed to start the runner for <id>`, `… workspace reservation was lost …`, `… prompt file is N bytes, above MAX_PROMPT_BYTES=…`, the release-stale family (`released <ws> generation <n>`, `… is already released`, `… held by live runner pid …`, `… still has live CLI process group …`, `… changed while checking …`, `no workspace reservation to release`, `… has no valid holder`) [source:bin/lib/zcode-dispatch.mjs:840-885,1137-1139,1236-1240] | `Task task-X is still running. Use /codex:status …` (stale-lock gotcha) [source:skills/codex-invocation/SKILL.md:240-252] | Quoted verbatim in first-match procedures [source:skills/dev-orchestrator/SKILL.md:428-437; skills/zcode-invocation/SKILL.md:162-165] |

### 1.3 Exit codes

| | ZCode | Codex |
|---|---|---|
| success | 0 | 0 |
| runtime failure | 1 (failed job on `result`, doctor FAIL, internal error) | 1 for **every** thrown error [source:vendor/codex-companion/scripts/codex-companion.mjs:1052-1056] |
| usage / guard refusal | **2** (`UsageError`) [source:bin/lib/zcode-dispatch.mjs:107,1660-1663] | 1 (no distinction) |
| `result` on a failed job | 1 [local-run: "result on a failed job … exit 1"] | **0** [local-run] |

The orchestrator relies on the exit-2 / exit-1 distinction for GLM only: exit 2 means "refused dispatch, not a job failure" [source:skills/dev-orchestrator/SKILL.md:428].

### 1.4 Ids and job states

| | ZCode | Codex |
|---|---|---|
| Id format | `zt-` + ≥4 digits, sequential per workspace, `wx`-allocated [source:bin/lib/zcode-dispatch.mjs:103,279,605-619] | `task-<Date.now() base36>-<6 random base36>` (e.g. `task-mvgk3up4-yo2np5`); `review-…` for review jobs [source:vendor/codex-companion/scripts/lib/state.mjs:124-127] [local-run]. The docs' `task-NNNN` / `task-XXXX` is a placeholder. |
| Reference matching | exact, regex-checked; a `task-` id is refused with exit 2 [source:bin/lib/zcode-dispatch.mjs:621-626,1143-1144] [local-run] | exact or unique prefix [source:vendor/codex-companion/scripts/lib/job-control.mjs:191-211] [local-run] |
| States | `running → completed\|failed\|cancelled` (no `queued`). Terminal states are sticky through an atomic `link(2)` claim of `<id>.json.terminal` [source:bin/lib/zcode-dispatch.mjs:104,282-336] | `queued → running → completed\|failed`, `cancelled` [source:vendor/codex-companion/scripts/codex-companion.mjs:676-684; lib/tracked-jobs.mjs:142-203]. No sticky-terminal protection. |
| Retention | unlimited | the 50 most recently updated jobs per workspace; older job files **and logs are deleted** [source:vendor/codex-companion/scripts/lib/state.mjs:13,80-116]. An old `.id` sidecar can stop resolving. |
| Record fields | `id,status,errorClass,sessionId,resumeOf,workspaceRoot,promptFile,model,provider,reportedModel,appVersion,runnerPid,childPid,startedAt,bootId,finishedAt,exitCode,signal,timeoutMin,response,usage,note` [source:bin/lib/zcode-dispatch.mjs:1199-1221] | `id,kind,jobClass,title,summary,write,status,phase,pid,logFile,request{…},threadId,turnId,result{rawOutput,…},rendered,errorMessage,createdAt/startedAt/completedAt` |

### 1.5 errorClass taxonomy (ZCode only) and orchestrator policy

Classification order, first match wins [source:bin/lib/zcode-dispatch.mjs:1077-1096]:

1. `timeout`
2. `launch` (spawn error)
3. a pattern match, in this order: `model-not-selected`, `auth`, `quota`, `launch`
4. `crash` (anything else, non-zero exit)

Exit 0 with output that does not parse → `malformed`. The haystack is the stderr tail plus stdout, with ` (traceId: …)` stripped. Patterns live in `PATTERNS` [:58-63]. The runner also sets classes itself: `auth` (no key), `model-not-selected` (no pin), `launch` (lost reservation, unreadable prompt, config lock), `crash` (`runner died`, `runner never started`, `system rebooted…`, `stale reservation released`) [:1235-1301, 899-923, 873-879].

| Class set | Policy (dev-orchestrator) |
|---|---|
| `quota`, `auth`, `model-not-selected` | channel `down` for the session (state line + marker); announce; the **same operation** on Luna max FRESH [source:skills/dev-orchestrator/SKILL.md:424] |
| `timeout`, `crash`, `launch`, `malformed` | one `--fresh` retry on GLM; a second failure → Luna (marked `down` only if the second class is in the set above) [:425] |
| Codex `failed` (no class) | retry once with `--fresh`, then the user [source:skills/codex-invocation/SKILL.md:236-238] |

### 1.6 Resume semantics

| | ZCode | Codex |
|---|---|---|
| Mechanism | job id → stored `sessionId` → CLI `--resume <sess_…>` [source:bin/lib/zcode-dispatch.mjs:945,1143-1152] | job id → stored `threadId` → app-server thread resume [source:vendor/codex-companion/scripts/codex-companion.mjs:458-470,481-492] |
| Preconditions | the referenced job is `completed`, has a `sessionId`, and its `provider` equals the pinned provider; otherwise exit 2 with a "dispatch --fresh" message | not `queued`/`running` and has a `threadId`. **A failed or cancelled job with a thread can be resumed.** |
| Chain | every resumed record copies the same `sessionId`; any id of the chain works [source:skills/zcode-invocation/SKILL.md:139] | any id of the thread works [source:skills/codex-invocation/SKILL.md:161] |
| Positional resume | none | `--resume-last` (banned by the protocol) [source:skills/dev-orchestrator/SKILL.md:753] |
| Global switch | `GLM resume: disabled` in zcode-invocation → every follow-up is FRESH [source:skills/dev-orchestrator/SKILL.md:391] | — |

Protocol usage: implementer fix, gate-fix and `NEEDS_CONTEXT` rounds resume by id. Reviewers (Step 2, Step 4.2) are **always FRESH**. A channel switch is FRESH with the re-brief and the channel-switch notice [source:skills/dev-orchestrator/SKILL.md:380-391].

### 1.7 Workspace scoping and concurrency

| | ZCode | Codex |
|---|---|---|
| Workspace | `git rev-parse --show-toplevel` of `--cwd`; outside a git tree → **refused**, exit 2 [source:bin/lib/zcode-dispatch.mjs:212-226] | same, but **falls back to cwd** outside a git tree [source:vendor/codex-companion/scripts/lib/workspace.mjs:1-9] |
| State dir | `~/.claude/plugins/data/superpowers-strigov-ver-zcode/state/<basename>-<sha1(root)[:8]>/jobs/` [source:bin/lib/zcode-dispatch.mjs:133-135,217-218] | `$CLAUDE_PLUGIN_DATA/state/<basename>-<sha256(realpath)[:16]>/jobs/`; the shim pins `CLAUDE_PLUGIN_DATA=…-codex` [source:vendor/codex-companion/scripts/lib/state.mjs:29-44; bin/codex-dispatch:52] |
| Write lock | atomic per-workspace **reservation** (`active.lock.<generation>`, token, holder pid, boot id; `release-stale` is the only release path) plus a refusal while another job is running [source:bin/lib/zcode-dispatch.mjs:727-838,1173,1193-1198] | **none**. "One write task per tree" and "max 2 write tasks across both dispatchers" are orchestrator discipline only [source:skills/codex-invocation/SKILL.md:217-230; skills/dev-orchestrator/SKILL.md:119,640] |
| Sandbox | none: `--mode yolo`, as the user [source:bin/lib/zcode-dispatch.mjs:934-935] | `workspace-write` with `--write`, else `read-only`; `approvalPolicy: never` [source:vendor/codex-companion/scripts/codex-companion.mjs:504; lib/codex.mjs:60-61] |
| Timeout | `ZCODE_TASK_TIMEOUT_MIN` (default 60) → SIGTERM to the group, 10 s, SIGKILL → `failed/timeout` [source:bin/lib/zcode-dispatch.mjs:97,228-236,1046-1051] | none at task level |
| Dead worker | reaper on every `status`/`result`/`cancel`/`task`; boot-id aware [source:bin/lib/zcode-dispatch.mjs:680-725,899-923] | none: a job with a dead pid stays `running` [local-run]; the stale-lock gotcha is documented [source:skills/codex-invocation/SKILL.md:240-256] |

### 1.8 Background + Monitor polling

Both skills prescribe the identical loop: Monitor, terminal-only `case` guard, `sleep 25`, never print per poll [source:skills/zcode-invocation/SKILL.md:87-103; skills/codex-invocation/SKILL.md:118-134]. ZCode's `task` spawns a detached runner (`node zcode-dispatch.mjs __run <id> <jobsDir> <token>`), which spawns the CLI as its own process group [source:bin/lib/zcode-dispatch.mjs:1222-1245,973-1065]. The Codex `task --background` spawns a detached `task-worker` that talks to the app-server broker [source:vendor/codex-companion/scripts/codex-companion.mjs:658-697,824-867].

### 1.9 Result format and the line-1 status token

- Token sets [source:skills/dev-orchestrator/SKILL.md:124-132]:
  - Implementer: `DONE | DONE_WITH_CONCERNS | NEEDS_CONTEXT | NEEDS_AUTHORIZATION | BLOCKED`
  - Plan review: `APPROVED | CHANGES_REQUESTED`
  - Code review: `REVIEW_OK | REVIEW_BLOCKING`. Step 4.1 also needs lines 2–3 (`SPEC:`, `QUALITY:`) [:140].
- Implementers write the full report to `[REPORT_FILE]` and end with at most 15 lines whose line 1 is the bare token [source:skills/dev-orchestrator/implementer-prompt.md:128-152,195-220].
- Malformed output → one re-dispatch by resume (Codex `--resume-task`, GLM `--resume-task` with the preamble), then the user [source:skills/dev-orchestrator/SKILL.md:137-138].
- The wrapper never interprets the token; ZCode only requires stdout to be one JSON object with a string `response` [source:bin/lib/zcode-dispatch.mjs:1067-1075].

### 1.10 Divergences a generic contract must normalize

| Aspect | Needed normalization |
|---|---|
| Start line | One machine line, e.g. `<Harness> Task started in the background as <id>` with the id as the **last token**, or `--json` everywhere |
| Exit codes | 0 / 1 / 2 everywhere; `result` on non-completed → 1 |
| errorClass | Every adapter emits the 7-class taxonomy (Codex: classify `errorMessage` with the same pattern framework) |
| Write lock + reaper + timeout | In the core, for every adapter (Codex gets them only if it is wrapped) |
| Retention | No pruning of records that sidecars may reference, or a documented window |
| Resume preconditions | One rule: `completed` + session handle, else exit 2 "dispatch --fresh" |
| Read-only tasks | A task kind that skips the write reservation and is enforced by the harness |

---

## 2. Function-level map of `bin/lib/zcode-dispatch.mjs`

Category key:
- **CORE**: harness-agnostic as written (at most an id-prefix or env-var-name parameter).
- **CORE-P**: a generic mechanism whose values come from the adapter.
- **ZC**: ZCode/GLM-specific.

| Lines | Symbols | Cat. | Notes |
|---|---|---|---|
| 1-20 | header | ZC | docs |
| 22-28 | imports | CORE | node builtins only, no deps |
| 30-63 | `PINNED_MODEL`, `VERIFIED_APP_VERSION`, `VERIFIED_NODE_MAJOR`, `APP_VERSION_PLIST_KEY`, `SELECTION_PATH`, `PERSONAL_CONFIG_BASE`, `PINNED_SELECTION`, `API_KEY_*`, `DISALLOWED_TOOLS` | ZC | adapter manifest values |
| 34-41, 56-63 | `PROMPT_TRANSPORT`, `MAX_PROMPT_BYTES`, `SUPPORTED_PLATFORMS`, `MODEL_ARGS`, `MODEL_ENV`, `REPORTED_MODEL_PATH`, `USAGE_FIELDS`, `PATTERNS` | CORE-P | **adapter hooks that already exist**: argv/stdin transport, flag- or env-based model pin, model verification, usage mapping, classifier patterns |
| 66-93 | `ENV_PASSTHROUGH_VAR`, `ENV_ALLOW`, `ENV_ALLOW_PREFIXES`, `ENV_DENY` | CORE-P | allowlist mechanism is generic; the list holds `ZCODE_*` entries |
| 95-105 | timeouts and graces, `ID_RE`, `TERMINAL`, `SELF` | CORE | `ID_RE` is prefix-parameterized |
| 107 | `UsageError` | CORE | exit-2 class |
| 109-131 | `DEFAULT_APP`, `zcodePaths` | ZC | app discovery (macOS bundle, Linux `/opt/ZCode`) |
| 133-137 | `stateRoot`, `personalConfigFile` | CORE-P / ZC | state root env name and default dir |
| 139-163 | `cliHome`, `cliHomeEnv`, `ensureCliHome` | ZC (pattern reusable) | isolated harness home (0700) so the user's own harness state is never touched |
| 165-210 | `readAppVersion`, `readAsarVersion` | ZC | truthful client version |
| 212-226 | `resolveWorkspace`, `requireWorkspace` | CORE | git-tree guard |
| 228-236 | `readTimeoutMin` | CORE-P | env name |
| 238-273 | `passthroughNames`, `isDenied`, `filterCliEnv`, `describeCliEnv` | CORE | env filtering; logs names only (the `ZCODE_SESSION_DB` special case is ZC) |
| 275-336 | `jobFile`, `logFile`, `formatId`, `idNumber`, `terminalFile`, `tmpFile`, `readJson`, `readRecord`, `writeRecord`, `finalizeRecord`, `updateRunning` | CORE | atomic records; sticky terminal claim via `link(2)` |
| 338-370, 424-440 | `REDACTED_KEY`, `API_KEY_PATTERN`, `readPersonalConfig`, `providerRulesOf`, `apiKeyRuleOf`, `hasApiKey`, `canonical`, `isPinned` | ZC | ZCode personal-provider-config format |
| 372-386 | `ensurePrivateDir`, `securePersonalConfig` | CORE-P | 0700/0600 secret-file hygiene |
| 388-422 | `keyRedactor` | CORE-P | generic redaction engine (stat-cached reload, longest key first); the key source is ZC |
| 442-465 | `writePrivateJson`, `sweepTempCopies` | CORE | atomic 0600 write; removes crash leftovers |
| 467-538 | `configLockProblem`, `tryLockFd`, `openConfigLock` (macOS `O_SHLOCK`/`O_EXLOCK`, Linux `flock(1)`) | CORE-P | the "secret is frozen while any run or orphan can read it" lock, handed to the CLI as fd 3 |
| 540-589 | `setApiKeyRule`, `writeApiKeyRule`, `apiKeyTemplateProblem` | ZC | Z.ai Coding Plan template rule |
| 591-644 | `listRecords`, `nextJobId`, `allocateRecord`, `requireJob`, `appendLog`, `tailLines` | CORE | prefix-parameterized; `requireJob` names Codex in its message |
| 646-678 | `isAlive`, `groupAlive`, `killGroup`, `sleep` | CORE | process groups; guards against pid ≤ 1 |
| 680-725 | `readBootId`, `bootId`, `bootOf` | CORE | reboot-safe liveness (`kern.bootsessionuuid` / `/proc/sys/kernel/random/boot_id`) |
| 727-838 | reservation: `reservationGenerations` … `acquireReservation` | CORE | per-workspace write lock with generations |
| 840-885 | `cmdReleaseStale` | CORE | |
| 887-923 | `claimRunnerReservation`, `reapDeadRunners` | CORE | |
| 925-962 | `buildCliArgv`, `buildCliEnv` | ZC | the adapter's two main functions (argv; env = filtered + adapter-owned) |
| 964-968 | `summarizeArgv` | CORE-P | hides the prompt from the log (assumes `-p`) |
| 970-1065 | `runCli` | CORE | detached group spawn, timeout, line-wise stderr redaction, `extraFds`, close-wait for descendants |
| 1067-1075 | `parseCliOutput` | ZC | ZCode JSON `{response, sessionId, usage}` |
| 1077-1096 | `classifyFailure`, `evaluate` | CORE-P | framework is generic; the traceId strip is ZC |
| 1098-1110 | `pick`, `reportedModelOf`, `reportedMatchesPin` | CORE-P | |
| 1112-1152 | `parse`, `checkPromptFile`, `resolveResume` | CORE / CORE-P | the resume provider check is ZC |
| 1154-1249 | `cmdTask` | ~60 CORE / ~36 ZC | ZC lines: app version, CLI/config existence, API key, pin, template, the `SP_IMPLEMENTER=luna` kill switch [:1168], the "ZCode Task" start line [:1244] |
| 1251-1341 | `runJob` (`__run`) | ~60 CORE / ~31 ZC | ZC: config lock + key/pin checks, cli-home, env/argv |
| 1343-1410 | `statusLine`, `cmdStatus`, `cmdResult`, `cmdCancel` | CORE | |
| 1412-1495 | `cmdDoctor` | ~30 CORE / ~54 ZC | framework (`ok\|WARN\|FAIL <check>: <detail>`, `doctor: ok\|FAIL`) is generic |
| 1497-1560 | `runProbe`, `probeWithLock` | CORE-P (~39) / ZC (~25) | generic PONG probe output (`model-selected/answers/reported-model/usage/probe`) |
| 1562-1596 | `readSecretLine` | CORE | hidden-echo stdin secret reader |
| 1598-1635 | `cmdApiKey` | ZC (pattern reusable) | stdin-only secret verb |
| 1637-1673 | `main`, `invokedDirectly` | CORE | verb switch; `UsageError` → 2 |

**Sizing (manual classification of the ranges above; estimate):** CORE ≈ 900 lines, CORE-P ≈ 250, ZC ≈ 470, of about 1,620 classified (blank lines and section comments excluded). **About 70 % (≈1,150 lines) could move into a shared core**, leaving a ZCode adapter of about 450–500 lines. The minimum adapter interface the code implies:

`paths()`, `version()`, `preflight()` (the task/doctor guards), `buildArgv({prompt, workspaceRoot, sessionId, readOnly})`, `buildEnv()` (adapter-owned vars applied after filtering), `parseOutput(stdout) → {response, sessionId, usage, reportedModel}`, `PATTERNS`, `secretSource()` (for the redactor and the config lock), `doctorChecks()`, `probeHints()`, `idPrefix`, `resumeCompatible(record)`.

The spec anticipated this seam: "the wrapper's job-record shape is designed so a broker-backed runner can replace `__run` without changing the verbs" [source:docs/superpowers/specs/2026-10-13-glm-zcode-implementer-design.md:638]. It also chose the Codex-shaped surface so that "the protocol changes stay small and mechanical" [:116].

---

## 3. Coupling points (orchestrator, skills, wrapper)

The generic replacement in every row assumes a **channel profile** with these fields: `name`, `dispatcher`, `idPrefix`, `family` (the **model** family), `model`/`effort`, `sandbox`, `roles`, `resume`, `concurrency`, `preamble`, `probe`, `credential`.

| # | Coupling | Where | Generic replacement |
|---|---|---|---|
| C1 | Two dispatcher variables and their resolution snippets | skills/zcode-invocation/SKILL.md:31-38; skills/codex-invocation/SKILL.md:24-33; dev-orchestrator SKILL.md:46,68,71-72 (gate allowlists) | one resolver (`agent-dispatch` or a registry file) mapping channel → wrapper path + fixed flags |
| C2 | Prefix → dispatcher mapping (`zt-` → `$ZDISPATCH`, `task-` → `$DISPATCH`) | SKILL.md:109 (recovery), :753 (Red Flag); zcode-dispatch.mjs:622,1144 (error names Codex); zcode-invocation:142 | the sidecar already stores `channel:id`; resolve the dispatcher from the channel name; the core rejects foreign prefixes generically |
| C3 | Dispatch-file and sidecar suffix `.glm\|.luna\|.sol` | SKILL.md:384,389,109 (examples), :214 (item 10); implementer-prompt.md:10,25,30 | `<name>.<seq>.<channel>.(md\|id)` with `<channel>` from the registry. "Highest seq = current channel" is already channel-agnostic. |
| C4 | State line `impl=<glm:zt-…\|luna:task-…\|sol:task-…\|claude\|—>` and `glm=<unprobed\|ok\|down\|off>`; per-track form | SKILL.md:100,104-105,667 | `impl=<channel>:<id>`; `health=<ch>:<state>[,…]` only for channels with `probe` |
| C5 | Session marker `<scratchpad>/dev-orchestrator/glm-channel` | SKILL.md:27,46,106,108; zcode-invocation:77,190 | `<scratchpad>/dev-orchestrator/channel-<name>`, same one-line `<state> <reason> <time>` format |
| C6 | Kill switch: `SP_IMPLEMENTER=luna`, phrases "через Luna" / "без GLM" | SKILL.md:108,116,370,378; zcode-dispatch.mjs:1168,1477-1478; zcode-invocation:179 | `SP_DISABLE_CHANNELS=<ch,…>` (or `SP_IMPLEMENTER=<channel>`) checked by the core's `task` guard; session phrase "без <channel>" |
| C7 | Channel ladder (GLM default, Luna fallback, Sol risk + stickiness) | SKILL.md:368-376; repeated for Step 5 at :558 and integration repair at :659 | one ladder over profiles: kill-switch filter → risk-marked → first healthy channel with `sandbox≠none` from `implementer.risk` → sticky hand-off → first healthy channel in `implementer.default[]` |
| C8 | Escalation target Sol (BLOCKED-needs-reasoning, gate `CODE`, review round-3 stall; "nothing above Sol") | SKILL.md:157,174,416,474,524-525 | `implementer.escalation` profile; "nothing above" = an escalation profile equal to the current channel |
| C9 | Model split table (Luna/Sol/Astra/GLM, effort per role) | SKILL.md:144-176; codex-invocation:67-80; bin/codex-dispatch:54 (default `gpt-6.1-sol`) | role → profile map; effort is part of the profile |
| C10 | Family rule ("GLM adds a third family (Z.ai)") | SKILL.md:178 | `profile.family` is the **model** family, not the harness (`claude -p` + GLM endpoint = Z.ai family); check writer.family ≠ reviewer.family per artifact |
| C11 | Pre-dispatch checklist item 5 (Codex: model/effort per role, no `zt-` resume) and item 10 (GLM: `.glm.md`, preamble, `glm=ok`, kill switch) | SKILL.md:209,214 | one item: "flags match the profile; resume id belongs to the channel; preamble iff `profile.preamble`; channel healthy and not disabled" |
| C12 | GLM infrastructure-failure ladder keyed on errorClass; Codex rule is different | SKILL.md:422-428; zcode-invocation:155-165; codex-invocation:232-238 | per-class policy for all channels: `{quota,auth,model-not-selected}` → channel down; transient classes → one `--fresh` retry; requires every adapter to emit errorClass |
| C13 | Stale-reservation procedure quoting `zcode-dispatch:` strings | SKILL.md:430-437; zcode-invocation:164 | core strings prefixed `<dispatcher>:`; the procedure applies to every core-based channel |
| C14 | `MAX_PROMPT_BYTES` guard → "Luna FRESH, do not trim" | SKILL.md:428; zcode-invocation:163; zcode-dispatch.mjs:37,1137-1139 | route to the next channel whose transport accepts the size (`stdin` channels have no cap) |
| C15 | First-GLM-dispatch probe procedure quoting doctor/probe lines and the `api-key set` remedy | SKILL.md:366; zcode-invocation:56,60-77 | "`doctor` then `doctor --probe`; exit 0 = ok"; the adapter prints a `hint:` line that the orchestrator relays verbatim (no per-channel remedy text in the orchestrator) |
| C16 | "Verified facts" lines read by the orchestrator (`Model selection`, `Model confirmation`, `GLM resume`, `GLM concurrency`) | zcode-invocation:19-27; SKILL.md:366,391,635 | profile fields `modelSelection`, `modelConfirmation`, `resume`, `concurrency` |
| C17 | "ZCode preamble (GLM dispatches only)" | implementer-prompt.md:40-53; SKILL.md:385-388; zcode-invocation:85 | `profile.preamble: headless-unsandboxed`; generic text, with `~/.zcode` replaced by the profile's credential dirs. Also guarantees the prompt does not start with `-` or `/`. |
| C18 | Channel-switch notice enumerations `<GLM-5.3-Flash via ZCode \| Codex Luna \| Codex Sol>`, `job <zt-NNNN \| task-NNNN>`; fix template "Opus + Astra control" | implementer-prompt.md:57-62,158,228 | `<profile.displayName>`, `job <channel>:<id>`; reviewer names from the role map |
| C19 | "Run `$DISPATCH status` and `$ZDISPATCH status`" before any dispatch; width cap of 2 "across both dispatchers" | SKILL.md:57,119,256,640; codex-invocation:230; zcode-invocation:148-150 | "status on every write-capable channel" (or `agent-dispatch status --all-channels`); the cap counts all channels |
| C20 | GLM concurrency rule in parallel groups | SKILL.md:635 | `profile.concurrency` |
| C21 | Reviewer dispatches hardwired to `$DISPATCH --model gpt-6-astra` | SKILL.md:299-309,514,555; codex-plan-reviewer-prompt.md:8-21; codex-control-review-prompt.md:8-24; final-review-prompt.md:19-23; brainstorming/spec-reviewer-prompt.md:8-21; requesting-code-review/SKILL.md:96; systematic-debugging/SKILL.md:276-278 | reviewer role → profile with `readOnly` and family checks |
| C22 | GLM/ZCode-specific Red Flags (ToS, no bypass, never touch the key) | SKILL.md:775-780; zcode-invocation:181-192 | generic flags ("never bypass the dispatcher; never handle credentials in chat; never give a risk-marked phase to `sandbox:none`") plus a per-provider compliance block in each adapter skill |
| C23 | Rule 1 / Role / triage prose naming GLM/Luna/Sol | SKILL.md:3,18,94,236-238,741 (reporting lines) | prose that names the role, with the channel from the registry |
| C24 | Wrapper-internal strings: "GLM run", "the GLM channel is switched off", "ZCode Task started" | zcode-dispatch.mjs:546,1168,1244,1612 | adapter display name |
| C25 | Plugin manifest description enumerates every model | .claude-plugin/plugin.json:3 | describe roles + "configurable channels" |

Already generic, keep as is: verdict token sets and the parsing procedure (SKILL.md:122-142), the operation/body/dispatch-file/seq scheme (:380-390), `[REPORT_FILE]`, review packages, the ledger, the frontmatter `risk_phases` (the rule "risk-marked → sandboxed channel" needs only `profile.sandbox`), and the Claude in-process agent channels (`impl=claude`, no id).

---

## 4. Implicit requirements for a new harness adapter

### 4.1 Drop-in IMPLEMENTER channel

| # | Requirement | Evidence | ZCode | Codex |
|---|---|---|---|---|
| I1 | Headless one-shot agent run from a prompt (file read, file edit, shell) in a given cwd, with no interactive approvals | zcode-dispatch.mjs:927-947; codex `approvalPolicy: never` | yolo | workspace-write |
| I2 | `task --background` returns at once with an id; the job survives the caller (detached) | §1.8 | ✓ | ✓ |
| I3 | `status <id> --json` → `job.status` ∈ {running(\|queued), completed, failed, cancelled} | §1.2 | ✓ | ✓ |
| I4 | `result <id>` = the clean **final assistant message** (no transcript or stream), line 1 = token | SKILL.md:124-142 | `response` | `rawOutput` + trailer |
| I5 | `errorClass` on failure, separating channel-down from transient | SKILL.md:422-428 | ✓ | ✗ |
| I6 | Resume by job id → harness session, model/provider kept (or declare `resume: disabled`) | §1.6; spec U2 [docs/superpowers/specs/2026-10-13-glm-zcode-implementer-design.md:623] | ✓ | ✓ |
| I7 | `--fresh` accepted; `--resume-task` + `--fresh` refused | zcode-dispatch.mjs:1167; companion:769-771 | ✓ | ✓ |
| I8 | `--cwd` → per-git-toplevel job namespace; same `--cwd` on status/result/cancel; worktree isolation | §1.7; local-run "9 a --cwd <worktree> job is zt-0001 …" | ✓ | ✓ |
| I9 | One write task per working tree, enforced | zcode-dispatch.mjs:1173,1193-1198 | ✓ | ✗ (orchestrator only) |
| I10 | Edits stay uncommitted (no commit, index or branch ops); the report goes to an absolute `[REPORT_FILE]` under `.superpowers/sdd/…` inside the repo | implementer-prompt.md:49,107,128-150 | prompt/preamble | prompt + sandbox |
| I11 | Prompts of ~100–200 KB; argv or stdin transport; a prompt must not start with `-` or `/` | zcode-dispatch.mjs:34-37; zcode-invocation:85 | argv, 120/200 KiB cap | file/stdin |
| I12 | Deterministic model + effort, no silent downgrade; a probe that can confirm it | bin/codex-dispatch:9-15; zcode-dispatch.mjs:1106-1110,1508-1560 | pin + probe | `--model` pin |
| I13 | `cancel` kills the whole process tree; `cancelled` is sticky | zcode-dispatch.mjs:1386-1410 | ✓ | partly (not sticky) |
| I14 | A wall-clock timeout → `failed/timeout` | zcode-dispatch.mjs:1046-1051 | ✓ | ✗ |
| I15 | Liveness: no record left `running` with a dead worker | zcode-dispatch.mjs:899-923 | ✓ | ✗ [local-run] |
| I16 | Credentials: stored by a user action (stdin or own login), never in chat, argv or tool-visible env; redacted from logs and results | zcode-dispatch.mjs:388-422,1598-1635; local-run "15 … key is redacted" | ✓ | `codex login` |
| I17 | Env allowlist, because the harness's shell tool inherits the env. Endpoint secrets (e.g. `ANTHROPIC_*` for `claude -p` [unverified names]) collide with `ENV_DENY` `^ANTHROPIC_` / `_TOKEN$`, so they must be adapter-owned vars applied **after** filtering, as `ZCODE_*` are at :949-961, and fed to the redactor | zcode-dispatch.mjs:66-92,249-262 | ✓ | inherits the env |
| I18 | An isolated harness home, so the user's own harness config and sessions are not mutated | zcode-dispatch.mjs:139-163 | `cli-home` | `CLAUDE_PLUGIN_DATA` |
| I19 | An unsandboxed harness refuses to run outside a git tree; risk-marked phases go only to `sandbox≠none` channels | zcode-dispatch.mjs:212-226; SKILL.md:371,776 | ✓ | (sandboxed) |
| I20 | Truthful client identification and provider ToS (official harness, no token extraction) | zcode-invocation:175-179; spec:84-100 | ✓ | ✓ |
| I21 | Declared concurrency (two runs at once?) and quota class | zcode-invocation:24; SKILL.md:635 | 2 | — |
| I22 | Declared **model family** for the family rule | SKILL.md:178 | Z.ai | OpenAI |
| I23 | `doctor` (offline) + `doctor --probe` (one cheap request) with `hint:` remedy lines | zcode-dispatch.mjs:1412-1560 | ✓ | `setup` |

### 4.2 Drop-in REVIEWER channel

| # | Requirement | Evidence |
|---|---|---|
| R1 | **Read-only, enforced by the harness**. Codex runs reviews without `--write` → `sandbox: read-only`. A harness without a sandbox needs a tool-level restriction; prose alone is insufficient for a reviewer that must "never move HEAD". | companion:504; codex-control-review-prompt.md:18,110; final-review-prompt.md:19-23,53-55 |
| R2 | A read-only task must **not** take the write reservation, so it can run in parallel with a running write task in the same tree. zcode-dispatch has no such mode: every task reserves the workspace and runs yolo. | codex-invocation:219; zcode-dispatch.mjs:934-935,1173,1193-1198; spec D1 "GLM never plans, never reviews" [spec:112] |
| R3 | **Fresh every round**: `--fresh` / no resume flags; no thread memory | codex-plan-reviewer-prompt.md:21; codex-control-review-prompt.md:22; SKILL.md:301,528 |
| R4 | Line-1 verdict tokens (`APPROVED\|CHANGES_REQUESTED`, `REVIEW_OK\|REVIEW_BLOCKING`) and structured sections. Plan BLOCKING items carry `class:`; 4.2 BLOCKING items need `authorization_relation`, `why_now`, `minimal_fix` (missing → DEFER). | codex-plan-reviewer-prompt.md:135-164; codex-control-review-prompt.md:85-108; SKILL.md:521,533 |
| R5 | Reads the **review package by path**: `.superpowers/sdd/<plan>/review-*.diff`, relative to the task cwd (4.2) or absolute (4.1, Step 5). The package is git-ignored; reading by explicit path must work. | codex-control-review-prompt.md:20,62,71; SKILL.md:197,488-495 |
| R6 | Can read cited source and run read-only git (`show/diff/log`); never writes | codex-control-review-prompt.md:71,110 |
| R7 | The control review (4.2) runs no tests; the Step 5 fallback cannot run the suite in a read-only sandbox, so the orchestrator supplies check 6 | SKILL.md:514; final-review-prompt.md:19-23 |
| R8 | Model family ≠ the artifact writer's family (per artifact) | SKILL.md:178 |
| R9 | Full output via `result` (reviews are long; no 15-line cap); pinned effort (xhigh plan review, high control) | SKILL.md:153,161 |
| R10 | Prompt via `--prompt-file`; anti-coaching scan applies to the prompt, not the channel | SKILL.md:213 |

---

## 5. Reusable test infrastructure

| Asset | What it does | Reuse for a generic dispatcher |
|---|---|---|
| `tests/fixtures/zcode-stub.cjs` (199 lines) | Stands in for the harness CLI, selected via `ZCODE_BIN`. `ZCODE_STUB_MODE` = `ok, pong, resume, record, leak, linger, model-not-selected, auth, quota, launch, hang, ignore-term, split-utf8, crash, malformed` [source:tests/fixtures/zcode-stub.cjs:3-9,111-197]. `record` dumps argv, stdin, cwd, selected env, the full env and the stub's model of the CLI's path resolvers to `ZCODE_STUB_RECORD` [:77-109]. `leak` prints the secret split across stderr chunks to test redaction [:141-158]. `linger` leaves a descendant holding stderr [:123-140]. | Generalize to `agent-stub.cjs` with one `emit()` per output dialect (ZCode JSON, Claude Code JSON, OpenCode events, …); same modes |
| `tests/fixtures/FakeZCode.app` | `Info.plist` + `zcode-builtin.json` (the `zai-api` template); on Linux the test builds `resources/app.asar` at runtime (`write_asar`) [source:tests/test-zcode-dispatch.sh:63-105] | per-adapter fake install trees |
| `tests/test-zcode-dispatch.sh` (1,784 lines, 17 numbered sections) | bash `pass`/`fail`; temp root; `HOME` override (forces the shim's dev-tree resolution); temp `ZCODE_STATE_DIR`; `git init` repo. Helpers: `jfield`, `const_of`/`first_pattern` (exported constants as the test oracle), `wait_status`, `wait_child`, `gone`, `spawn_sleeper`, `running_record` (hand-made records), `expect_exit`, `latest_reservation_generation`. Reboot simulation via `ZCODE_TEST_BOOT_ID`. Stub control vars go through `ZCODE_ENV_PASSTHROUGH` because the wrapper filters the env. [source:tests/test-zcode-dispatch.sh:1-258] | Split into **core tests** (reservation, boot id, reaper, cancel, timeout, sticky terminal, redaction, env filter: sections 3,5,7,8,9,10,16) run once against a trivial adapter, and **adapter tests** (argv/env pins, output parsing, classification, doctor/probe, credential verb: sections 2,4,6,11,12,15,17) |
| Local result | `bash tests/test-zcode-dispatch.sh` → **110 `[PASS]`, 0 `[FAIL]`, exit 0**, repo tree unchanged [local-run] | baseline before any refactor |
| `vendor/codex-companion/tests/*.test.mjs` | broker graceful-shutdown, heartbeat, kill-9, orphan scan | Codex-only; not part of a core |

---

## 6. Open questions

1. Should Codex stay behind the companion and broker, or be wrapped by the new core (with its runner calling the companion or `codex` directly)? Wrapping would give Codex the reservation, timeout, reaper and errorClass that it lacks (§1.7).
2. Profile registry format and location: a plugin-shipped default plus a user override under `~/.claude/plugins/data/…`. How does the orchestrator (Rule 2: no research reads) read it? Probably one `agent-dispatch channels` bookkeeping call with one-line output.
3. Can the generic core keep both `--resume-task` preconditions (ZCode: `completed` only; Codex: any non-active with a thread)? Which is right for fix rounds after a `failed/timeout`?
4. Read-only mode for unsandboxed harnesses: which harnesses can enforce read-only at the tool level headless? (Out of scope here; for the per-harness researchers.)
5. `MAX_PROMPT_BYTES` on Linux (120 KiB) vs prompts that inline ledgers. Is stdin transport available on the candidate harnesses?
6. Retention: the Codex companion prunes to 50 jobs and deletes their files [source:vendor/codex-companion/scripts/lib/state.mjs:13,80-116]. Does any long plan exceed that between a dispatch and its resume?

## 7. Minor findings (doc/code drift)

- `skills/zcode-invocation/SKILL.md:132` documents `ZCODE_TEST_BOOT_TIME` (and boot-time sources `kern.boottime` / `/proc/stat`), but `bin/lib/zcode-dispatch.mjs` reads only `ZCODE_TEST_BOOT_ID` [source:bin/lib/zcode-dispatch.mjs:710-716]; `grep BOOT_TIME` finds no code use [local-run].
- The skills write Codex ids as `task-NNNN` / `task-XXXX`, but real ids are `task-<base36>-<random6>` [source:vendor/codex-companion/scripts/lib/state.mjs:124-127].
- Codex `result <running-id>` returns `No job found …` instead of the intended "still running" message: `matchJobReference` throws before the active-job branch [source:vendor/codex-companion/scripts/lib/job-control.mjs:256-279] [local-run].
- The spec's §4.3 said the wrapper "must never set" `ZCODE_DATA_BASE_DIR` [docs/superpowers/specs/2026-10-13-glm-zcode-implementer-design.md:48,166]; the current code always sets it to its own `cli-home` [source:bin/lib/zcode-dispatch.mjs:146-155]. This is a deliberate later change ("CLI data home"), not a bug, but the spec is stale.
