# D4: Universal dispatchers, abstraction and protocol first

- **Key:** `D4-abstraction` · **Date:** 2026-10-20 · **Branch:** `research/universal-dispatchers` · **Code baseline:** `c1aa9e0` [00 header]
- **Optimizes for:** a clean, durable abstraction. That means a shared job core, a precise adapter interface and capability model, an optional rather than mandatory protocol layer, and tests that do not need keys or network.
- **Citations:** `[NN §x]` points to `docs/research/universal-dispatchers/<NN>-*.md`, section x. `[repo:<path>:<lines>]` points to source at `c1aa9e0`. Statements about what we will build are design and carry no citation. Every statement about a harness, a provider, terms of service or today's code carries one. Line counts for new code are estimates.

| Key | Report |
|---|---|
| 00 | `00-current-architecture.md` |
| 01 | `01-claude-code-headless.md` |
| 02 | `02-opencode.md` |
| 03 | `03-pi.md` |
| 04 | `04-dsh-and-harness-survey.md` |
| 04b | `04b-deepseek-harness.md` |
| 05 | `05-codex-multi-provider.md` |
| 06 | `06-providers-and-plans.md` |
| 07 | `07-tos-matrix.md` |
| 08 | `08-local-models.md` |
| 09 | `09-sandboxing-and-credentials.md` |
| 10 | `10-acp-universal-transport.md` |

---

## 1. Thesis

Build one dispatcher, `bin/agent-dispatch`. It is a job core extracted from `zcode-dispatch.mjs`, which is already about 70 % harness-agnostic [00 §2], plus thin harness adapters behind one interface with a declared capability manifest.
A user-owned profile registry binds adapter, endpoint, model, key reference, model family and sandbox tier. A plugin-shipped ToS policy table filters it, and the table denies by default [07 §6].
The orchestrator asks the core to route a role to a profile and reads one failure policy (`onFailure`). The skills stop naming harnesses.
Eligibility comes from capabilities, not names. Blocking reviewers need enforced read-only, and risk phases need `riskEligible`, which only Codex has today [09 §9].
ACP is one optional transport kind, used first for dsh and never as the core protocol [10 §4.7]. The Codex companion is wrapped unchanged now, and it is replaced under the same profile names only after a live parity run.

---

## 2. Architecture overview

### 2.1 Components

| Component | Path | Responsibility | Built from |
|---|---|---|---|
| CLI shim | `bin/agent-dispatch` | Resolves `node` and execs the core. | `bin/zcode-dispatch` (36 lines) [repo:bin/zcode-dispatch] |
| Job core | `bin/lib/agent-core.mjs` | Verbs and ids. Records with a sticky terminal claim. Per-workspace write reservation and per-profile slots. Boot-id reaper and wall-clock timeout. Env allowlist and key redaction. Error classification and failure policy. Post-run checks (L3). Doctor framework, keystore, `route` and `channels`. | The CORE and CORE-P ranges of `bin/lib/zcode-dispatch.mjs`, about 1,150 lines [00 §2] |
| CLI transport | `bin/lib/transport/cli.mjs` | Spawns the harness as its own process group. Feeds stdin from the prompt file, then closes it. Writes stdout to `<id>.events.ndjson` and stderr, redacted line by line, to `<id>.log`. Executes the manifest's signal ladder and sweeps descendant groups. | `runCli` and `killGroup` [00 §2] |
| ACP transport (optional, late) | `bin/lib/transport/acp.mjs` | A newline-delimited JSON-RPC client pinned to `protocolVersion` 1. It holds the session, answers permission requests from a fixed policy and rebuilds the final message. | [10 §4.1, §4.7] |
| Adapters | `bin/lib/adapters/<id>.mjs` | A manifest plus pure functions (§3.2): `zcode`, `claude`, `codex`, `dsh`, `pi`, `opencode`, `companion`, plus a built-in `inproc` pseudo-adapter. | The ZC lines of zcode-dispatch, about 470 [00 §2], and the §16 sketches in 01–05 |
| Registry | `bin/lib/registry.mjs` | Loads and validates `profiles/*.json` and `config.json`, and checks each profile's family against its model id. | new |
| Policy | `bin/lib/policy.json` | ToS rows. A missing row means "no". | [07 §6.1] |
| Sandbox wrapper (later) | `bin/lib/sandbox/srt.mjs` | Renders `<job>/srt.json`, applies the fail-closed checks and runs the canaries. | [09 §7.3–7.4] |
| Test stub | `tests/fixtures/agent-stub.cjs` | One fake harness, with one output dialect per adapter and shared failure modes. | `tests/fixtures/zcode-stub.cjs` [00 §5] |

### 2.2 Data flow

```text
dev-orchestrator (main thread)
 │ "$AGENT" route implementer --skip glm-zcode        → "route implementer -> luna adapter=companion family=openai …"
 │ "$AGENT" task --background --profile luna --role implementer --prompt-file P [--cwd W] [--resume-task ID | --fresh]
 ▼
agent-core: task  (returns at once)
 registry.load(luna) ─► policy.check(plan, adapter, "headless") ─► adapter.preflight()
   ─► family / read-only / risk / kill-switch / caps checks   (each refusal: exit 2 + one "hint:" line)
   ─► write reservation (write roles only) ─► profile slot ─► record <id> (status=running)
   ─► spawn detached runner:  node agent-core.mjs __run <id> <jobsDir> <token>
   stdout: "<displayName> task started in the background as <profile>:<id>"
 ▼
runner (__run)
 adapter.prepareHome() ─► adapter.invocation() = {argv, env, stdin, cwd, secretEnv}
   ─► L0: env = allowlist(parent) + adapter env + secrets from keystore (never argv)
   ─► L1: native sandbox per manifest, OR sandbox/srt.mjs wrap (never both if nestsSeatbelt)
   ─► transport.cli: harness process group
        stdout ─► <id>.events.ndjson     stderr ─► redactor ─► <id>.log
 on exit | timeout | cancel:
   adapter.reduce(events, stderrTail, exit) ─► Outcome
   core.classify(Outcome, adapter.patterns) ─► errorClass, errorDetail, onFailure, downProfiles
   L3: .git hooks/config hash, refs unchanged for read-only jobs, secret scan
   finalize record (sticky terminal claim via link(2))
 ▼
orchestrator Monitor loop: "$AGENT" status <id> --json → job.status ∈ {completed, failed, cancelled}
   completed → "$AGENT" result <id> → line-1 token (unchanged parsing)
   failed    → job.onFailure ∈ {down, retry, next} (§5.4)

companion profiles (luna, sol, astra), increments 1–2:
 agent-core task ─► adapters/companion.mjs ─► bin/codex-dispatch task --background … (unchanged vendored code)
 status / result / cancel ─► companion verbs + overlay (exit codes, errorClass, dead-worker detection)
```

### 2.3 On-disk layout

```text
plugin (versioned, read-only at runtime)
  bin/agent-dispatch
  bin/lib/agent-core.mjs  bin/lib/registry.mjs  bin/lib/policy.json
  bin/lib/transport/{cli,acp}.mjs  bin/lib/adapters/*.mjs  bin/lib/sandbox/srt.mjs
  profiles/templates/<adapter>/<provider>.json        # copied by `profile add`; never active by itself

user data (0700): ~/.claude/plugins/data/superpowers-strigov-ver-agents/   (override: AGENT_DISPATCH_DATA)
  config.json                       # roles, disabled profiles, gray opt-ins, caps
  profiles/<name>.json              # no secrets
  keys/<keyname>                    # 0600; written only by `agent-dispatch key set <keyname>` (stdin)
  homes/<name>/                     # isolated harness homes rendered by prepareHome()
  state/<basename>-<sha1(root)[:8]>/jobs/<id>.json|.log|.events.ndjson
  state/slots/<profile>/<id>        # per-profile concurrency slots (pid + boot id, reaped)
```

The job-dir layout copies today's zcode state dir [00 §1.7]. The file format is JSON because the core keeps zcode-dispatch's "node builtins only, no deps" property [00 §2], and Node ships no TOML or YAML parser.

### 2.4 Where the security layers sit

| Layer [09 §7.1] | Owner in this design |
|---|---|
| L0 pre-spawn | Core `task` guards: git-tree guard, reservation, env allowlist, keys read by the dispatcher, harness home. |
| L1 OS boundary | The adapter's native sandbox (manifest `nativeSandbox`) **or** `sandbox/srt.mjs`. Never both when `nestsSeatbelt` is true [09 §7.1]. |
| L2 harness policy | Flags and config written by `adapter.invocation()` and `prepareHome()`. |
| L3 post-run | Core, after `reduce()` (§6.3). |

---

## 3. Harness adapter contract

### 3.1 Verbs (one surface for every adapter)

The surface is today's de-facto contract [00 §1.1], normalized as 00 §1.10 asks. Exit codes are 0, 1 and 2 everywhere. Exit 2 means a refusal, not a job failure [00 §1.3].

| Verb | Contract |
|---|---|
| `task --background --profile <P\|auto> --role R [--writer W] [--risk] [--cwd D] [--resume-task ID \| --fresh] [--effort E] --prompt-file F` | Prints `<displayName> task started in the background as <P>:<ID>`. The last token is the sidecar value. Exit-2 refusals: policy, kill switch, family, read-only capability, caps, prompt size, resume preconditions, unknown effort. |
| `status [ID] [--cwd D] [--all \| --running] [--json]` | `{"job":{id, profile, adapter, role, readOnly, status, errorClass, errorDetail, onFailure, downProfiles, sessionId, reportedModel, appVersion, note}}`. `--running` lists every running job across workspaces and counts write tasks. |
| `result ID` | `completed`: the final message verbatim, exit 0. Any other state: exit 1 and `job <id> is <status> errorClass=<c>` plus the last 20 log lines. These are today's zcode semantics [00 §1.1]. |
| `cancel ID` | Claims a sticky `cancelled`, then runs the manifest's signal ladder. |
| `release-stale [--cwd D]` | As today [00 §1.1]. |
| `doctor --profile P [--probe] [--probe-sandbox] [--record DIR]` | Prints `ok\|WARN\|FAIL <check>: <detail>` and `hint:` lines, then `doctor: ok\|FAIL` [00 §2]. |
| `key set\|clear\|check <keyname>` | Reads from stdin with hidden echo (`readSecretLine` already exists [00 §2]). `check` prints presence, mode and key shape, never the value. |
| `profile add NAME --from TEMPLATE [--set k=v]…`, `profile check NAME`, `profile env NAME`, `profile list` | §4.6 |
| `route ROLE [--writer W] [--risk] [--sticky P] [--skip P,…] [--prompt-bytes N]` | §5.2 |
| `channels` | Prints one line per profile. |

`ID` may be given bare (`ct-0008`) or qualified (`glm-cc:ct-0008`). Each adapter keeps the id prefix its research sketch proposed: `zt` zcode [00 §1.4], `ct` claude [01 §16], `cx` codex [05 §16], `dt` dsh [04b §16], `pi` pi [03 §16.2], `oc` opencode [02 §16]. Companion jobs keep `task-…` [00 §1.4]. One sequence per workspace is shared by all core adapters, so ids never collide. The core rejects a foreign prefix generically, which removes coupling point C2 [00 §3].

**Resume rule (one rule for all core adapters).** The referenced job must be `completed`, carry a `sessionId`, belong to the same profile, and pass `adapter.resumeCheck()`. Otherwise the core exits 2 with "dispatch --fresh". This adopts zcode's stricter precondition [00 §1.6, §6 Q3]. It is consistent with today's policy: a transient failure gets one `--fresh` retry, never a resume [repo:skills/dev-orchestrator/SKILL.md:425]. Companion profiles keep the companion's own rule, which accepts any non-active job with a thread [00 §1.6], until they move to the `codex` adapter (§8.2).

### 3.2 Adapter interface

```js
// bin/lib/adapters/<id>.mjs — default export; no top-level side effects
export default {
  id: "claude",                  // also the "harness" key in policy.json
  idPrefix: "ct",
  displayName: "Claude Code",
  manifest: { /* §3.3 */ },

  // offline; may run the harness binary through ctx.exec (injected, stubbed in tests)
  discover(ctx) {},               // -> { bin, version }   or throws AdapterError("launch", hint)
  preflight(profile, ctx) {},     // -> Problem[] {check, level: "FAIL"|"WARN", detail, hint}  (task + doctor)
  doctorChecks(profile, ctx) {},  // -> Problem[]  preflight + requiredFlags in --help, home modes, auth method

  // per job; returns data, never spawns, never reads keys
  prepareHome(profile, job, ctx) {},   // -> { env: {VAR: path}, files: [{path, mode, content}] }
  invocation(req, ctx) {},        // req = {profile, role, readOnly, effort, job, prompt: {path, bytes},
                                  //        resume: {sessionId} | null}
                                  // -> { argv: [...], env: {...}, stdin: "prompt" | "null", cwd, secretEnv: ["NAME"] }
  reduce(io) {},                  // io = {events, stderrTail, exit: {code, signal}, timedOut, cancelled}
                                  // -> { ok, response, sessionId, usage, reportedModel, errorText }
  patterns: { "model-not-selected": [], auth: [], quota: [], context: [], blocked: [], transient: [] },
  resumeCheck(prev, profile, req) {},  // -> null | "reason"
  probe(profile, ctx) {},         // -> invocation for one "Reply with exactly: PONG" turn, parsed by reduce()
};
```

Rules that keep adapters small and testable:

- **The core owns every side effect.** It spawns processes, writes files, reads keys, enforces timeouts, executes signal ladders and enforces policy. The adapter returns data. `discover` and `doctorChecks` may run offline commands such as `--version`, `--help` and `auth status` through `ctx.exec`.
- **Adapter env comes after the allowlist.** The core filters the parent env with `ENV_ALLOW` and `ENV_DENY`, then applies the adapter's `env`, as zcode applies `ZCODE_*` today [00 §4.1 I17]. `secretEnv` names get their values from the keystore at spawn, and those values feed the redactor [00 §2].
- **`reduce()` alone decides success.** Exit codes are only a hint, because several harnesses exit 0 on failure:
  - Claude Code: permission denials, SIGINT, and API errors reported as `is_error` [01 §11].
  - pi: provider errors in JSON mode [03 §15].
  - Codex: an unknown model [05 §3].
  - dsh: SIGTERM [04b §10].

  In the other direction, OpenCode can exit 1 after a recovered compaction and still have a valid final text [02 Fact-check log]. Empty or non-JSON stdout is always a failure [01 §11].
- **No adapter sets identity.** No User-Agent, originator, `x-app` or client id is ever set, so each harness identifies itself [07 §6.3].

### 3.3 Capability manifest

| Field | Values | Used by |
|---|---|---|
| `transport` | `cli` \| `acp` \| `external` \| `inproc` | core: which runner |
| `output` | dialect id (`zcode-json`, `claude-stream-json`, `codex-jsonl`, `dsh-ndjson`, `pi-jsonl`, `opencode-jsonl`, `companion-text`) | stub and tests |
| `prompt` | `{via: "stdin"\|"argv"\|"file", maxBytes}` | core size guard; `route --prompt-bytes` |
| `sessionId` | `preassign` \| `first-event` \| `final` | runner records it early when it can |
| `resume` | `{supported, bind: ["cwd"\|"home"\|"provider"]}` | `resumeCheck` |
| `readOnly` | `os` \| `permission-rules` \| `tool-removal` \| `none` | role eligibility (§6.2) |
| `nativeSandbox` | `{scope: "tools"\|"bash"\|"process", writes, network}` \| `null` | sandbox tier (§6.1) |
| `nestsSeatbelt` | bool | refuses srt [09 §7.2] |
| `srt` | `compatible` \| `with-native-off` \| `no` | sandbox tier |
| `credential` | `{delivery: "env"\|"file"\|"login", toolEnvScrub, maskable}` | key custody (§6.4) |
| `structuredOutput` | `json-schema` \| `extension` \| `none` | informational; verdicts stay line-1 tokens |
| `cancel` | `{ladder: [[signal, graceMs]…], sweepDescendants}` | core cancel and timeout |
| `model` | `{select, confirm}` | the no-silent-downgrade check [00 §4.1 I12] |
| `effort` | `{via, vocab}` | the core refuses an effort outside the vocabulary |
| `concurrencyPerHome` | int \| null | slot default |
| `riskEligible` | bool, **static**, flipped only by a code change after LIVE canaries | `route --risk` |
| `version` | `{tested, accept, outside: "WARN"\|"FAIL", requiredFlags: []}` | doctor (§3.7) |
| `homeEnv`, `housekeeping` | env names for isolation; telemetry and update switches | `prepareHome` |

The `claude` manifest in full, as an example:

```json
{
  "transport": "cli",
  "output": "claude-stream-json",
  "prompt": { "via": "stdin", "maxBytes": null },
  "sessionId": "preassign",
  "resume": { "supported": true, "bind": ["home", "cwd"] },
  "readOnly": "permission-rules",
  "nativeSandbox": { "scope": "bash", "writes": true, "network": true },
  "nestsSeatbelt": true,
  "srt": "with-native-off",
  "credential": { "delivery": "env", "toolEnvScrub": "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1", "maskable": true },
  "structuredOutput": "json-schema",
  "cancel": { "ladder": [["SIGINT", 5000], ["SIGTERM", 5000], ["SIGKILL", 0]], "sweepDescendants": true },
  "model": { "select": "--model + ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL + CLAUDE_CODE_SUBAGENT_MODEL", "confirm": "result.modelUsage keys" },
  "effort": { "via": "--effort", "vocab": "per-profile" },
  "concurrencyPerHome": 4,
  "riskEligible": false,
  "version": {
    "tested": "2.1.302", "accept": ">=2.1.302 <2.2.0", "outside": "WARN",
    "requiredFlags": ["--setting-sources", "--settings", "--session-id", "--tools", "--strict-mcp-config",
                      "--append-system-prompt-file", "--output-format", "--max-turns", "--permission-mode"]
  },
  "homeEnv": ["CLAUDE_CONFIG_DIR"],
  "housekeeping": { "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CODE_MAX_RETRIES": "2" }
}
```

Sources for the manifest values:

- Flags, signal ladder, session pre-assignment and `modelUsage`: [01 §16].
- Bash-only sandbox: [09 §8].
- Four parallel runs on one config dir: [01 §10, E19].
- The env scrub: [01 E13].
- Version 2.1.302 is installed, and releases are near-daily, 13 published between 2026-10-05 and 2026-10-19: [01 §1].

### 3.4 Manifest values per harness

| Field | zcode | claude | codex | dsh | pi | opencode | companion |
|---|---|---|---|---|---|---|---|
| output | one JSON `{response, sessionId, usage}` [00 §2] | stream-json; final `type:"result"` [01 §16] | `exec --json` JSONL + `-o last.txt` [05 §16] | `--json` NDJSON; `final.text` [04b §16] | `--mode json` JSONL; last assistant `message_end` [03 §16.2] | `run --format json` JSONL [02 §16] | text + trailer [00 §1.1] |
| prompt | argv, 120/200 KiB cap [00 §4.1 I11] | stdin [01 §16] | stdin `-` [05 §16] | stdin `-` [04b §16] | stdin [03 §16.2] | stdin redirect; runner must close it [02 §2; 02 Fact-check log] | file [00 §1.1] |
| sessionId | final [00 §2] | preassign `--session-id <uuid>` [01 §16] | first event (`thread_id`) [05 §16] | first `session` event; `--session-id` cannot create one [04b §4] | preassign, but an unknown id silently starts a new session [03 §4] | first event [02 §16] | companion record [00 §1.6] |
| resume bind | completed + same provider [00 §1.6] | same home + cwd [01 §16] | same provider flags, placed before `resume` [05 §16] | same cwd + same patch [04b §16] | same cwd + session dir; session file must exist [03 §16.2] | same profile, `-s <id>` [02 §16] | any non-active job with a thread [00 §1.6] |
| readOnly | none [00 §4.2 R2] | permission-rules: `--tools "Read,Glob,Grep"` or plan [01 §16] | os: `-s read-only` [09 §8] | os: `DSH_PERMISSION_MODE=read-only` [04b §16] | tool-removal: `--tools read,grep,find,ls` [03 §16.2] | permission-rules: a custom reviewer agent, since `plan` is not read-only [02 §7] | os (no `--write`) [00 §1.7] |
| nativeSandbox | none (`--mode yolo`) [00 §1.7] | Bash only [09 §8] | tools: writes + network [09 §8] | writes only; network not covered [10 §4.3] | none [03 §8] | none [02 §8] | Codex [00 §1.7] |
| srt | via `-c` and `ZCODE_HTTP_PROXY`; unverified [09 §7.3] | with the inner sandbox off [09 §7.3] | no, nested Seatbelt [09 §8] | only with its own sandbox off; inference [09 §8] | yes [09 §8] | yes; `run` opens no port [09 §7.3] | no |
| credential | file in cli-home under the config lock; not maskable on macOS [00 §2; 09 §8] | env + `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` [01 E13] | `env_key` + `shell_environment_policy.ignore_default_excludes=false` [05 Bottom line] | env `DEEPSEEK_API_KEY` [04b §16] | env; the bash tool inherits it [03 Bottom line] | `{file:…}` or env [02 §16] | `codex login` [00 §4.1 I16] |
| structuredOutput | none | `--json-schema` [01 §12] | `--output-schema` [05 §12] | not used | extension tool only [03 §12] | none in `run` [02 §12] | none |
| cancel ladder | SIGTERM group, 5 s, SIGKILL [00 §1.1] | SIGINT, grace, SIGTERM group (143) [01 §16] | SIGINT, 10 s, SIGTERM, SIGKILL, sweep [05 §16] | snapshot, SIGINT, 7 s, SIGKILL, sweep; SIGTERM exits 0 [04b §16] | SIGTERM (143), 5–10 s, SIGKILL pgid, sweep [03 §16.2] | snapshot, SIGTERM pgid + descendant pgids, 5 s, SIGKILL [02 §16] | companion `cancel` [00 §1.1] |
| model select / confirm | pinned selection file / `REPORTED_MODEL_PATH` [00 §2] | `--model` + tier env pins / `modelUsage` [01 §16] | `-m` + `-c model_provider` [05 §16] | patch `agent-default-model` [04 §A.2 (5)] | `--model p/m` / assistant message [03 §16.5] | `-m p/m` / export `providerID/modelID` [02 §16] | `--model` [00 §1.1] |
| effort | pinned `max` [repo:bin/lib/zcode-dispatch.mjs:50] | `--effort` → `output_config.effort` [01 §5] | `-c model_reasoning_effort` [05 §5.2] | patch `reasoningEffort` [04b §16] | `--thinking off…max`, clamped [03 §16.5] | `--variant` [02 §16] | `--effort` [00 §1.1] |
| riskEligible | no [09 §8] | after srt canaries [09 §8] | **yes** [09 §9] | after canaries [09 §8] | after srt canaries [09 §8] | after srt canaries [09 §8] | **yes** (the Sol path today) [09 §8] |
| version policy | exact 3.15.1 [repo:bin/lib/zcode-dispatch.mjs:32] | range + WARN; near-daily releases [01 §1] | range + WARN; daily alphas [05 §1] | exact 0.2.1-rc.2, FAIL outside; every release is a prerelease [10 §2.1] | `~1.3`, FAIL outside; breaking changes in 1.0.3 and 1.2.0 [03 §15] | major 1 only, FAIL on 2; Homebrew Core installs v2 [02 Bottom line] | vendored |

### 3.5 Error taxonomy and failure policy (owned by the core)

**Classification order.** Today's order is kept and extended: `timeout`, then `launch` (spawn error), then `cancelled`, then L3 signals (`sandbox`), then the adapter's `patterns` in the order model-not-selected, auth, quota, context, blocked, transient, then `crash`. A completed run with no parseable final message is `malformed` [00 §1.5].

**The core computes `onFailure`.** One table lives in code, so the orchestrator needs no per-harness ladders:

| errorClass | Typical signals | onFailure | Orchestrator action (§5.4) |
|---|---|---|---|
| `auth`, `quota`, `model-not-selected` | 401/403, exhausted balance or plan, unknown model, reported model ≠ pin | `down` | Mark every profile in `job.downProfiles` down, announce once, run the same operation on the next route FRESH. These are today's GLM rules [00 §1.5]. |
| `sandbox` | `sandbox-start`, `sandbox-violation`, `git-config-changed`, `read-only-violated`, `credential-leak` [09 §7.1 L3] | `down` | As above. For `credential-leak` the announcement also says "rotate key `<keyname>`". |
| `blocked` | OpenCode `auto-rejecting` [02 §7]; an ACP run where every permission was denied [10 §4.7] | `next` | The next profile, FRESH. The profile is not marked down. |
| `context` | prompt too long, context overflow [01 §16; 02 §11; 04b §11]; local context too small [08 §10] | `next` | The next profile, FRESH. |
| `timeout`, `crash`, `launch`, `malformed`, `transient` | wrapper deadline, signal deaths, spawn errors, 429 rate limits, 5xx/529, network | `retry` | One `--fresh` retry on the same profile. A second failure goes to the next profile, marked `down` only if the second class maps to `down`. These are today's GLM rules [00 §1.5]. |

`downProfiles` widens one failure to every profile that shares the cause:

- `auth`: every profile with the same `credential.ref`.
- `quota`: every profile with the same `quotaGroup`. For example, `glm-zcode` and `glm-cc` draw on one Coding Plan.

**Where the signals come from, per adapter.** `quota` (plan or balance exhausted) must stay separate from `transient` (rate limited).

- **claude:** `api_error_status` 401/403 → auth; 429 plus the provider's text → quota or transient; 529/5xx → transient; 404 or "issue with the selected model" → model-not-selected; `prompt_too_long` → context [01 §16].
- **codex:** "unexpected status 401" → auth; "Quota exceeded" → quota; "Codex ran out of room" → context; 5xx "high demand" → transient [05 §11].
- **dsh:** stable `dsh: <CODE>:` prefixes: `AUTH`, `QUOTA`, `RATE_LIMIT`, `UNKNOWN_MODEL`, `CONTEXT_WINDOW_EXCEEDED`, `TRANSPORT`, and `SANDBOX_UNAVAILABLE` → sandbox [04b §11].
- **pi:** its exported `isRetryableAssistantError` and `isContextOverflow` classifiers [03 §11].
- **opencode:** ProviderAuthError/401/403; 429/`insufficient_quota`/GoUsageLimitError; ContextOverflowError; "Model not found" [02 §11].

### 3.6 How each harness fits

**zcode (migrated first).**
- Behaviour does not change.
- The ZC ranges (≈470 lines) become `adapters/zcode.mjs`, sized at 450–500 lines [00 §2].
- It keeps its argv transport and caps, its pinned selection, its cli-home and config lock, and its `api-key set` writer, which is reached through the core's `key set glm-zcode` with a `native` credential ref (§4.5).
- Manifest: `readOnly: none` and `riskEligible: false`. It stays implementer-only, as spec D1 decided ("GLM never plans, never reviews") [00 §4.2 R2].

**claude (endpoint profiles).** One adapter serves every Anthropic-compatible endpoint with an official Claude Code setup: Z.ai, DeepSeek, MiniMax, Alibaba, OpenRouter, Ollama, LM Studio and Kimi [01 Bottom line; 06 §1.1].
- **Home.** `homes/<profile>/claude/` becomes `CLAUDE_CONFIG_DIR`. `settings.json` carries the env pins, `permissions.deny: ["WebSearch","WebFetch"]`, `skipWebFetchPreflight`, `disableAllHooks` and the sandbox block [01 §16].
- **Argv.**
  - It always passes `--setting-sources ""` and `--settings <home>/settings.json`. Together these block the repo-level `.claude/settings.json` redirect of `ANTHROPIC_BASE_URL`, which works even with `--bare` [01 E9].
  - CLAUDE.md rules come back through `--append-system-prompt-file`, because `--setting-sources ""` drops them [01 §9].
- **Credentials.** `ANTHROPIC_AUTH_TOKEN` comes from the keystore, with `ANTHROPIC_API_KEY=""` [07 §6.2].
- **Inherited identity.** Inherited `CLAUDE_CODE_ENTRYPOINT` and similar variables never pass the allowlist [01 E23].
- **Permissions.** `--permission-mode acceptEdits` plus `--allowedTools`. Auto mode is not used, because it is unproven on non-Claude endpoints [01 §7].
- **Preflight.** `claude auth status --json` must show `authMethod` in {`api_key_helper`, `oauth_token`} and never a claude.ai login [01 §16]. Without a key, a fresh home fails closed with "Not logged in" [01 E5].
- **Local models** are claude profiles with `endpoint.local: true`: a loopback-only base URL, `--bare`, a dummy key, `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, and raised stream watchdogs [08 §10].

**codex (custom Responses providers).**
- **Engine.** `codex exec --json` drives the run. `CODEX_HOME` is `homes/<profile>/codex/`, which also absorbs the trust write-back of `-s workspace-write` [05 §16].
- **Provider.** `-c model_providers.<id>={base_url, env_key, wire_api="responses"}`. Chat wire is a hard error, so only Responses endpoints qualify: DeepSeek, Z.ai `/api/v1`, Kimi, MiniMax, Alibaba, OpenRouter, Ollama and LM Studio [05 Bottom line; 06 §1.1].
- **Hardening flags:** `--disable plugins --disable multi_agent --disable goals`, `web_search="disabled"`, analytics/feedback/update-check off, and `ignore_default_excludes=false` [05 §9].
- **Never** `--oss`, which pulls models on its own [05 §15].
- **Later use.** With `credential.ref: "login"` and the user's own Codex home, the same adapter can serve Luna, Sol and Astra (§8.2). OpenAI calls API keys "the right default for automation" but sanctions `codex exec` with a saved login [07 OA3].

**dsh (DeepSeek Harness, headless CLI first).**
- **Patch file.** Each job gets `<job>/dsh.patch.yml` with the role preset (model, effort, `DSH_PERMISSION_MODE`) and a pinned `baseURL`. It turns off `session-log-deepseek`, the inventory plugin and title generation, and turns off `tool-web` for reviewers [04b §16].
- **Env.** `DSH_HOME` per profile, `DSH_AGENTS_HOME` set to an empty dir, and `DSH_TELEMETRY_DISABLED=1` [04b §16].
- **Never used:** `danger-full-access` and `sdk-minimal` [04b §16].
- **Doctor:**
  - `--dump-config` must show session-log disabled and the pinned `baseURL`.
  - A target-repo `.env` produces a WARN [04b §16].
- **Linked worktrees.** `workspace-write` is scoped to the cwd, so `.git` writes from linked worktrees can fail [04b §15]. Implementers do not commit [00 §4.1 I10], so this is a LIVE check rather than a blocker.

**pi (API keys only).**
- **Agent dir.** `PI_CODING_AGENT_DIR` per profile. `models.json` holds custom endpoints, and `auth.json` stays empty because the key arrives through env [03 §16.1; 09 §8].
- **Flags and env:** `--mode json --no-approve -ne -ns -np --no-mcp`, with `PI_OFFLINE=1 PI_TELEMETRY=0 PI_SKIP_VERSION_CHECK=1`. Settings: `enableInstallTelemetry:false`, `defaultProjectTrust:"never"`, `cacheWarming:"off"` [03 §16.1–16.2].
- **Hard refusal in code.** If `pi auth check` reports `authType:"oauth"`, the profile is refused. That covers pi's Anthropic and GitHub Copilot logins, which impersonate other clients [07 §3, §5].
- **Z.ai plan.** The GLM Coding Plan in pi is allowed, because Z.ai lists pi [07 ZA2]. The `zai*` denial in 03 §16.1 was "pending the ToS matrix", and 07 resolves it as OK.
- **Reviews.** Read-only is `tool-removal` only, so pi is eligible for advisory review but not blocking review.

**opencode (v1 pinned).**
- **Isolation.** Per-profile `XDG_*` dirs and `OPENCODE_CONFIG`, plus `OPENCODE_DISABLE_PROJECT_CONFIG=1`, `OPENCODE_PURE=1`, and the autoupdate, LSP-download, Claude-Code and external-skills disables [02 §9].
- **Rendered `opencode.json`.** `enabled_providers`, `small_model`, `snapshot:false`, `share:"disabled"`, an explicit permission ruleset, and `agent.implementer` / `agent.reviewer` [02 §16].
- **Runner duties:**
  - Close stdin [02 Fact-check log].
  - Treat `auto-rejecting` on stderr as `blocked` [02 §7].
  - Treat the `--agent`-typo warning as fatal [02 §15].
  - Accept a valid final text that arrives after the last error [02 Fact-check log].
- **Version.** Doctor requires major version 1 [02 §16].
- **Subscriptions.** OpenCode's own ChatGPT Plus/Pro and Copilot logins are truthful and OK [07 §3, §5]. They are used only through the harness's own login inside the profile home (`profile env`, §4.6).

**companion (pass-through, increments 1–2).** `bin/codex-dispatch` and the vendored code are untouched. The overlays are described in §8.2.

**inproc (pseudo-adapter).**
- It makes `opus@inproc` and `sonnet@inproc` (family `anthropic`) visible to routing and to the family rule.
- `task` on them exits 2 with "dispatch with the Agent tool".
- The in-process Claude roles stay as they are [00 §3, "Already generic"].

### 3.7 Version pinning and upgrade testing

1. **The manifest pins what was tested.** `version.tested` is the exact version that produced the recorded dialect fixtures and passed LIVE validation. `accept` is the range doctor tolerates. `outside` sets the response beyond it:
   - Stable, fast-moving CLIs (claude, codex) get WARN.
   - Prerelease or recently breaking CLIs (dsh, pi, opencode) get FAIL.
2. **An offline check on every `doctor`:**
   - `<bin> --version`.
   - Every `requiredFlags` entry must appear in `<bin> --help` (or `<bin> exec --help`). This catches a removed or renamed flag on any upgrade for zero tokens.
3. **The probe exercises the real parser.** `doctor --probe` sends one PONG turn through the same `invocation()` and `reduce()`, so an output-format change fails the probe and the profile goes `down` with a `hint:`. This is zcode's probe pattern [00 §2], made generic.
4. **Every job records `appVersion`.** zcode records already carry it [00 §1.4]. If a failed job ran on a version other than `tested`, the record's `note` says "harness <v> differs from tested <t>", and the orchestrator's single fallback announcement carries the likely cause.
5. **No automatic updates during dispatch.** Each adapter turns off its harness's own updater:
   - claude: `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` or `DISABLE_AUTOUPDATER=1` [01 §9].
   - opencode: `OPENCODE_DISABLE_AUTOUPDATE=1` [02 §9].
   - pi: `PI_SKIP_VERSION_CHECK=1` [03 §16.2].
   - codex: `check_for_update_on_startup=false` [05 §9].
6. **Upgrade procedure (developer-side, no runtime state):**
   1. Run `doctor --profile P --probe --record tests/fixtures/dialects/<adapter>/<version>/`, which saves redacted stdout and stderr.
   2. Add a replay case to the stub.
   3. Run the adapter suite against the old and new recordings.
   4. Bump `tested` in the manifest.

   Adoption is a code edit reviewed like any other. There is no approval file, receipt or cached "verified" flag.

### 3.8 ACP: an optional transport, not the protocol

- **Decision:** `transport: "acp"` is one manifest value. The verbs, records, reservation, timeout and errorClass framework stay the same, and the runner's exec loop is replaced by a JSON-RPC loop [10 §4.1–4.2].
- **First consumer, and the only planned one:** dsh "guarded" mode (`dsh --profile acp`).
  - It is an automation-only server with resume, close and list, plus `model` and `reasoning_effort` config options and `usage_update` [10 Bottom line 3].
  - Its permission requests come from its own sandbox's escalation path, which makes a deny-by-default broker meaningful [10 §2.1].
  - The dsh report already puts ACP at v2 "guarded" [04b §16].
- **Not used** for claude, codex or pi [10 §4.6]:
  - claude would sit behind a third-party adapter with 29 releases in 60 days, and `-p` already has a host permission channel.
  - `codex-acp` wraps the same app-server the companion drives, so it adds no capability.
  - `pi-acp` is a 0.0.x community adapter with no tool permission prompts.
- **Not the core protocol.**
  - ACP removes per-harness output parsing, but not profiles, env, homes, config-option ids, `rawInput` extractors, error patterns or ToS notes [10 §4.6].
  - Three of the six target harnesses need third-party adapters [10 Bottom line 2].
  - ZCode has no ACP at all [10 §2.1].
- **Implementation constraints:**
  - A hand-rolled NDJSON client of 400–600 lines, pinned to `protocolVersion` 1 [10 §4.7].
  - A stub ACP agent, with every message validated against the vendored `schema/v1/schema.json` [10 §4.7].
  - No TS SDK: 2.0.0 removed `ClientSideConnection` on 2026-10-19 [10 §1.1].
  - No `npx` launches [10 §4.5].
- **The broker is defence in depth, not containment.** Permission requests are optional for the agent ("MAY"). Containment comes from the harness sandbox or srt [10 §4.3].
- **Known gaps:** ACP has no quota or rate-limit code, and per-turn usage is unstable, so errorClass stays pattern-based [10 §1.3–1.4].

### 3.9 Build order and never-build list

**Build order:**

1. **zcode.** Migrating it proves the core extraction against a 110-test oracle [00 §5].
2. **companion pass-through.** It is cheap, and it gives the orchestrator one dispatcher command (§8.2).
3. **claude.** One adapter reaches GLM, DeepSeek, Kimi Platform, MiniMax, Qwen PAYG, OpenRouter and local models [01 Bottom line; 06 §1.1]. It also brings stdin transport, a read-only mode and a Bash sandbox.
4. **codex** (`exec --json`). It is the only risk-eligible engine [09 §9] and serves Responses providers [05 Bottom line]. It is the path to retiring the companion.
5. **dsh.** It has a native OS sandbox and a read-only mode, and DeepSeek is PAYG with no anti-automation clause [04b §14; 07 DS1].
6. **pi.** It adds API-key breadth (40+ providers) [03 Bottom line; 03 §5.2], but it has no sandbox or permissions [03 §8].
7. **opencode (v1).** Its unique value is the subscriptions it can use truthfully (ChatGPT, Copilot, OpenCode Go) [07 §5]. It carries the heaviest gotchas, including v2 being installed by Homebrew [02 Bottom line].
8. **acp transport** (optional) for dsh guarded mode.

**Never build:**

| Item | Why |
|---|---|
| Kimi Code CLI adapter | Kimi Code membership is interactive-only [07 KI1], and `-p` has no read-only or plan mode [04 §B; 04 Fact-check log]. The Kimi Platform is reached through `claude` instead. |
| Antigravity `agy`, Gemini CLI with consumer OAuth | Wrapping them is forbidden under consumer plans [07 GO1–GO2]. |
| Qwen Code adapter | The Alibaba Coding Plan is non-interactive-banned [07 AL1]. Qwen PAYG is reachable through `claude` [06 §1.1]. |
| Crush, Cline | Their run modes auto-approve by default [04 §B.2], and plan listings are unclear [07 §5 gray]. |
| ACP adapters for claude, codex and pi (CAA, codex-acp, pi-acp) | They add churn and no capability [10 §4.6]. |
| SDK-embedded runners (Agent SDK, pi SDK) | They mean vendoring large npm trees and tracking a fast API [03 §16.6]. Z.ai also bans SDK access for its plan [07 ZA3]. |
| Local reverse proxies (CCR, LiteLLM) that turn a plan into an API | No-go [07 §6.8; 08 §10 #14]. |
| Third-party-provider patches to the vendored companion | The local patch set would grow on every upstream bump [05 §16]. |

---

## 4. Profiles / registry

### 4.1 Location and format

- **User data.** User-owned files live in `~/.claude/plugins/data/superpowers-strigov-ver-agents/` (§2.3). This mirrors today's per-channel data roots, `…-zcode` and `…-codex` [00 §1.7]. Profiles and keys are not stored in the plugin cache, so a plugin update never touches them.
- **Plugin files.** The plugin ships read-only `bin/lib/policy.json` and `profiles/templates/`.
- **Format.** Plain JSON, one file per profile, schema version `"schema": 1`, validated by `registry.mjs`.
- **Names.** A profile name is the channel name everywhere: sidecars, the state line and markers (§7).

### 4.2 Profile schema

| Field | Meaning |
|---|---|
| `name`, `adapter`, `displayName` | identity |
| `plan` | the policy key (`zai-coding-plan`, `deepseek-payg`, `kimi-platform-payg`, `alibaba-modelstudio-payg`, `chatgpt-plan`, `local`, …) |
| `family` | the **model creator**, not the host or harness [06 §6; 00 §3 C10] |
| `quotaGroup` | profiles that draw on one quota; `quota` failures and caps propagate across it |
| `endpoint` | `{protocol: anthropic\|responses\|deepseek\|…, baseUrl, local?}` |
| `model` | `{id, tierPins?, contextTokens?, reportedMatch?}`. `reportedMatch` is a regex for the reported model, or `null` when the provider does not report one. |
| `effort` | `{default, vocab, map?}`, for example `{"xhigh":"max"}` for providers with `low/high/max` only [06 §1.4] |
| `credential` | `{ref: "store:<keyname>"\|"keychain:<service>"\|"native"\|"login"\|"none", var?, rejectPrefix?}` |
| `sandbox` | `none` \| `native` \| `srt` (§6.1) |
| `roles` | the roles this profile may serve |
| `concurrency`, `timeoutMin` | slots and the wall-clock limit (zcode's default today is 60 [00 §1.7]) |
| `preamble` | `headless-unsandboxed` or absent (00 C17) |
| `env`, `adapterOptions` | extra adapter-owned env; adapter-specific knobs |
| `enabled` | `false` keeps a profile installed but unroutable |
| `peakUtc`, `data` | informational: peak windows [06 §2.2], jurisdiction |

### 4.3 Seven example profiles (all ToS-safe)

1. **`glm-zcode`**: today's GLM channel, migrated. This is the model and effort that are pinned today [repo:bin/lib/zcode-dispatch.mjs:50]. The 60-minute timeout is today's default [00 §1.7]. The concurrency of 2 is today's "GLM concurrency" fact [00 §4.1 I21]. Policy: ZCode is listed by Z.ai [07 ZA2].

```json
{ "schema": 1, "name": "glm-zcode", "adapter": "zcode", "displayName": "GLM-5.3-Flash via ZCode",
  "plan": "zai-coding-plan", "quotaGroup": "zai-coding-plan", "family": "zai",
  "model": { "id": "GLM-5.3-Flash", "reportedMatch": "GLM-5\\.3-Flash" },
  "effort": { "default": "max", "vocab": ["max"] },
  "credential": { "ref": "native" },
  "sandbox": "none", "preamble": "headless-unsandboxed",
  "roles": ["implementer"], "concurrency": 2, "timeoutMin": 60 }
```

2. **`luna`**: Codex Luna through the companion, unchanged. `sol` (`gpt-6.1-sol`, xhigh, roles `implementer.risk` and `implementer.escalation`) and `astra` (`gpt-6-astra`, the reviewer roles) have the same shape [repo:bin/codex-dispatch:54; 00 §3 C9]. Policy: Codex is official for ChatGPT plans [07 OA3, OA5].

```json
{ "schema": 1, "name": "luna", "adapter": "companion", "displayName": "Codex GPT-6 Luna",
  "plan": "chatgpt-plan", "family": "openai",
  "model": { "id": "gpt-6-luna" }, "effort": { "default": "max", "vocab": ["low","medium","high","xhigh","max","ultra"] },
  "credential": { "ref": "native" }, "sandbox": "native",
  "roles": ["implementer"], "concurrency": 2 }
```

3. **`glm-cc`**: the GLM Coding Plan through Claude Code. Sources:
   - Endpoint, `[1m]` tier ids and `API_TIMEOUT_MS`: Z.ai's own recipe [06 §2.1].
   - Effort vocabulary: [06 §1.4].
   - Policy: a safe default when the plan key is used with `ANTHROPIC_AUTH_TOKEN` against this URL [07 §5].
   - Key type: a plan key, not a Standard key, which would be billed pay-as-you-go [06 §1.3].

```json
{ "schema": 1, "name": "glm-cc", "adapter": "claude", "displayName": "GLM-5.3 via Claude Code",
  "plan": "zai-coding-plan", "quotaGroup": "zai-coding-plan", "family": "zai",
  "endpoint": { "protocol": "anthropic", "baseUrl": "https://api.z.ai/api/anthropic" },
  "model": { "id": "glm-5.3[1m]",
             "tierPins": { "opus": "glm-5.3[1m]", "sonnet": "glm-5.3[1m]", "haiku": "glm-5.3-flash[1m]", "subagent": "glm-5.3-flash[1m]" },
             "reportedMatch": "glm-5\\.3" },
  "effort": { "default": "max", "vocab": ["low","high","max"], "map": { "medium": "high", "xhigh": "max" } },
  "credential": { "ref": "store:zai-plan", "var": "ANTHROPIC_AUTH_TOKEN" },
  "sandbox": "native", "roles": ["implementer"], "concurrency": 1, "timeoutMin": 60,
  "env": { "API_TIMEOUT_MS": "3000000", "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "1000000" } }
```

4. **`deepseek-pro-dsh`**: DeepSeek V4 Pro in DSH. Sources:
   - Implementer preset `v4-pro`/`high`, `workspace-write`: [04b §16].
   - The default provider is `deepseek-official` [10 §2.1].
   - Peak windows: [06 §2.2].
   - Policy: DeepSeek PAYG is OK in DSH [07 §2].

```json
{ "schema": 1, "name": "deepseek-pro-dsh", "adapter": "dsh", "displayName": "DeepSeek V4 Pro via DSH",
  "plan": "deepseek-payg", "quotaGroup": "deepseek-payg", "family": "deepseek",
  "endpoint": { "protocol": "deepseek", "baseUrl": "https://api.deepseek.com" },
  "model": { "id": "deepseek-v4-pro", "reportedMatch": "deepseek-v4-pro|DeepSeek-V4-Pro" },
  "effort": { "default": "high", "vocab": ["off","low","high","max"] },
  "credential": { "ref": "store:deepseek", "var": "DEEPSEEK_API_KEY" },
  "sandbox": "native", "roles": ["implementer"], "concurrency": 2, "timeoutMin": 60,
  "peakUtc": ["Mon-Fri 01:00-04:00", "Mon-Fri 06:00-10:00"],
  "adapterOptions": { "provider": "deepseek-official", "toolWeb": false } }
```

5. **`deepseek-flash-cc`**: a cheap utility channel that shares the DeepSeek key. Sources:
   - Endpoint: [06 §1.1].
   - Flash as the cheap utility pick: [06 §6].
   - Policy: DeepSeek documents the Claude Code setup itself [07 DS2].

```json
{ "schema": 1, "name": "deepseek-flash-cc", "adapter": "claude", "displayName": "DeepSeek Flash via Claude Code",
  "plan": "deepseek-payg", "quotaGroup": "deepseek-payg", "family": "deepseek",
  "endpoint": { "protocol": "anthropic", "baseUrl": "https://api.deepseek.com/anthropic" },
  "model": { "id": "deepseek-flash",
             "tierPins": { "opus": "deepseek-flash", "sonnet": "deepseek-flash", "haiku": "deepseek-flash", "subagent": "deepseek-flash" } },
  "effort": { "default": "low", "vocab": ["low","high","max"] },
  "credential": { "ref": "store:deepseek", "var": "ANTHROPIC_AUTH_TOKEN" },
  "sandbox": "native", "roles": ["utility"], "concurrency": 2, "timeoutMin": 20 }
```

6. **`qwen-max-cc`**: Qwen3.8 Max on Alibaba Model Studio pay-as-you-go, as a cross-family advisory reviewer. Sources:
   - Endpoint: [06 §1.1].
   - Effort `low/medium/xhigh`: [06 §1.4].
   - Use the US deployment scope: [06 §6].
   - `sk-sp-` keys belong to the Coding Plan, which is no-go for any non-interactive dispatch [06 §1.3; 07 AL1].

```json
{ "schema": 1, "name": "qwen-max-cc", "adapter": "claude", "displayName": "Qwen3.8 Max via Claude Code",
  "plan": "alibaba-modelstudio-payg", "family": "qwen",
  "endpoint": { "protocol": "anthropic", "baseUrl": "https://<WorkspaceId>.us-east-1.maas.aliyuncs.com/apps/anthropic" },
  "model": { "id": "qwen3.8-max" },
  "effort": { "default": "xhigh", "vocab": ["low","medium","xhigh"], "map": { "high": "xhigh", "max": "xhigh" } },
  "credential": { "ref": "store:alibaba-payg", "var": "ANTHROPIC_AUTH_TOKEN", "rejectPrefix": ["sk-sp-"] },
  "sandbox": "native", "roles": ["advisory-reviewer"], "concurrency": 1, "timeoutMin": 40 }
```

7. **`local-qwen-cc`**: a local llama-server, **disabled by default**. Sources:
   - llama-server's default port 9931: [08 §3].
   - Minimal env and watchdogs: [08 §10].
   - A 16 GB M4 is not viable as an implementer. Opt-in trivial phases need 32–48 GB, for example Qwen3.6-35B-A3B [08 §9].
   - Policy: local models fall under no service terms [07 §2].

```json
{ "schema": 1, "name": "local-qwen-cc", "adapter": "claude", "displayName": "Local Qwen3.6-35B-A3B (llama-server)",
  "plan": "local", "family": "qwen", "enabled": false,
  "endpoint": { "protocol": "anthropic", "baseUrl": "http://127.0.0.1:9931", "local": true },
  "model": { "id": "qwen3.6-35b-a3b", "contextTokens": 65536, "reportedMatch": null },
  "credential": { "ref": "none" }, "sandbox": "native",
  "roles": ["utility"], "concurrency": 1, "timeoutMin": 90,
  "env": { "CLAUDE_STREAM_IDLE_TIMEOUT_MS": "1800000", "API_FORCE_IDLE_TIMEOUT": "0", "CLAUDE_CODE_ATTRIBUTION_HEADER": "0" } }
```

Other endpoints fit the same claude shape:

- `kimi-k3-cc`: `https://api.moonshot.ai/anthropic` on Kimi Platform PAYG. The concurrency is 1 at Tier0 [06 §2.3]. The Kimi Code membership is a different, gray plan [07 §5].
- `minimax-cc`: `https://api.minimax.io/anthropic` with a PAYG key. The M Plan is gray headless [07 §5]. Data note: MiniMax may use inputs to improve its services [06 §7 Q2].
- `openrouter-*`: `https://openrouter.ai/api` [06 §1.1]. Each model's own terms pass through [07 OR1].

### 4.4 `config.json` (roles, opt-ins, caps)

The defaults reproduce today's model split exactly [00 §3 C9; repo:.claude-plugin/plugin.json:3]. A new profile does nothing until the user lists it under a role.

```json
{
  "schema": 1,
  "roles": {
    "implementer":            ["glm-zcode", "luna"],
    "implementer.risk":       ["sol"],
    "implementer.escalation": ["sol"],
    "plan-reviewer":          [{ "profile": "astra", "effort": "xhigh" }],
    "code-reviewer":          [{ "profile": "opus@inproc", "effort": "high" }],
    "control-reviewer":       [{ "profile": "astra", "effort": "high" }],
    "final-reviewer":         [{ "profile": "opus@inproc", "effort": "xhigh" }, { "profile": "astra", "effort": "xhigh" }],
    "advisory-reviewer":      [],
    "utility":                []
  },
  "familyRule": { "plan-reviewer": "required", "code-reviewer": "required", "final-reviewer": "required-or-announce",
                  "control-reviewer": "preferred", "advisory-reviewer": "required" },
  "disabled": [],
  "grayOptIn": {},
  "caps": { "writeTasks": 2, "quotaGroups": { "zai-coding-plan": 2 } }
}
```

### 4.5 Credential references

| `ref` | Who writes it | How the runner delivers it | Source |
|---|---|---|---|
| `store:<keyname>` | The user, in their own terminal: `agent-dispatch key set <keyname>` (hidden stdin, 0600 file) | Into the child's env object under `credential.var`, after allowlist filtering, and into the redactor | The zcode `api-key set` pattern [00 §2]; [07 §6.4] |
| `keychain:<service>` | The user, with `security add-generic-password` | The runner reads it with `security find-generic-password -s <service> -w` at spawn | Pattern E [09 §5] |
| `native` | The adapter's own writer, reached through `key set` (zcode personal config) or the harness's own login (companion: `codex login`) | Read by the harness itself; the core only checks presence | [00 §2; 00 §4.1 I16] |
| `login` | The harness's own login command, run by the user against the profile home (`profile env`) | Read by the harness itself | [07 §5] (OpenCode ChatGPT and Copilot, Codex) |
| `none` | — | Local profiles only, with a dummy key | [08 §10 #13] |

A key is never put in argv, chat, a repo file or the parent env. One key may serve several profiles (`store:deepseek` above), and an `auth` failure then marks all of them down through `downProfiles`.

### 4.6 How the user creates and checks a profile

All of this runs in the user's own terminal. The orchestrator never runs `key set` and never edits `profiles/` or `config.json`.

```text
$ agent-dispatch profile add deepseek-flash-cc --from claude/deepseek
wrote profiles/deepseek-flash-cc.json (no secrets)
policy: deepseek-payg × claude × headless = ok [DS1, DS2]
next: agent-dispatch key set deepseek ; agent-dispatch profile check deepseek-flash-cc

$ agent-dispatch key set deepseek          # hidden prompt, stdin only
stored keys/deepseek (0600)

$ agent-dispatch profile check deepseek-flash-cc        # = registry validation + doctor (offline)
ok   schema: profiles/deepseek-flash-cc.json
ok   family: deepseek matches model prefix "deepseek-"
ok   policy: deepseek-payg/claude/headless = ok [DS1, DS2]
ok   harness: claude 2.1.302 (tested 2.1.302)
ok   flags: 9/9 required flags in `claude --help`
ok   home: homes/deepseek-flash-cc/claude 0700, settings.json 0600
ok   key: store:deepseek present (0600), shape ok
ok   auth: `claude auth status --json` → loggedIn, authMethod=oauth_token, no claude.ai login
doctor: ok

$ agent-dispatch doctor --profile deepseek-flash-cc --probe   # one cheap paid request
ok   probe: answers=PONG reported-model=deepseek-flash usage=in:… out:…
doctor: ok

$ $EDITOR ~/.claude/plugins/data/superpowers-strigov-ver-agents/config.json   # add to roles.utility
$ agent-dispatch channels
deepseek-flash-cc  adapter=claude family=deepseek roles=utility sandbox=native policy=ok enabled
```

`oauth_token` is how Claude Code reports `ANTHROPIC_AUTH_TOKEN` [01 §16].

For `login` refs, `agent-dispatch profile env <name>` prints the `export` lines for the profile's isolated home, for example `XDG_CONFIG_HOME=… XDG_DATA_HOME=…` for OpenCode. The user then runs the harness's own login, such as `opencode auth login`, in their own shell. The credential never passes through the dispatcher or the chat.

---

## 5. Roles and routing

### 5.1 Roles

| Role | Pipeline step | Today | Eligibility (code-enforced) |
|---|---|---|---|
| `implementer` | Step 3 | GLM via ZCode, Luna as fallback [repo:skills/dev-orchestrator/SKILL.md:368-376] | write-capable adapter |
| `implementer.risk` | risk-marked phase | Sol xhigh [same] | `manifest.riskEligible` and sandbox ≠ none |
| `implementer.escalation` | BLOCKED, gate `CODE`, round-3 stall | Sol [00 §3 C8] | as for `implementer` |
| `plan-reviewer` | Step 2 | Astra xhigh, fresh each round [00 §4.2 R3] | `readOnly ∈ {os, permission-rules}`, family ≠ plan writer |
| `code-reviewer` | 4.1 | Opus high, in-process [00 §3 C21] | family ≠ implementer |
| `control-reviewer` | 4.2 | Astra high [00 §3 C9] | read-only enforced; family preferred ≠ implementer |
| `final-reviewer` | Step 5 | Opus xhigh, with Astra xhigh as fallback [repo:.claude-plugin/plugin.json:3] | family ≠ every writer on the branch, or announced [repo:skills/dev-orchestrator/SKILL.md:178] |
| `advisory-reviewer` (new, optional) | extra non-blocking findings | — | any `readOnly ≠ none`; family ≠ writer |
| `utility` (new, optional) | summaries, triage, condensing logs | Sonnet in-process | read-only; never authoritative [08 §9] |

Reviewer tasks always run with `--fresh` and read the review package by path [00 §4.2 R3, R5]. A read-only task skips the write reservation, so it can run beside a write task in the same tree [00 §4.2 R2].

### 5.2 Route algorithm (`agent-dispatch route`, pure and offline)

```text
route ROLE [--writer P|family[,…]] [--risk] [--sticky P] [--skip P,…] [--prompt-bytes N]
 1. candidates = config.roles[ROLE --risk ? ROLE+".risk" : ROLE], in order
 2. drop: enabled=false, config.disabled, SP_DISABLE_CHANNELS, --skip (session down/off),
          policy ≠ ok (gray without grayOptIn), static doctor FAIL (binary or key missing)
 3. drop: role capability mismatch (write vs read-only; readOnly level; riskEligible)
 4. family: familyRule required → drop same family as any --writer; preferred → move to the end
 5. --sticky P still eligible → P   (the phase stays where it was handed; today's ladder item 4)
 6. drop: manifest.prompt.maxBytes < N
 7. print the first remaining:
      route implementer -> luna adapter=companion family=openai sandbox=native effort=max (skipped: glm-zcode=down)
    none left → exit 2:
      route advisory-reviewer: no eligible profile (qwen-max-cc: key missing; deepseek-flash-cc: same family deepseek)
```

`task --profile auto --role R …` runs the same algorithm inside `task` and prints the chosen profile in the start line, which saves a call for reviewer dispatches. `task` always re-checks policy, family and capability, so `route` is a convenience and never a security boundary. For reviewer roles, `--writer` is required (exit 2 without it).

### 5.3 Family rule

- Family is the model creator: GLM through OpenRouter or Alibaba is still `zai` [06 §6].
- A local model belongs to its vendor family [08 §9].
- `anthropic/*` routes in pi are the Claude family [03 §16.4].
- **Validation.** `registry.mjs` checks the declared `family` against a model-id prefix table: `glm`→zai, `deepseek`→deepseek, `kimi`→moonshot, `qwen`→qwen, `minimax`→minimax, `gpt`→openai, `claude|opus|sonnet|haiku`→anthropic. A mismatch is a FAIL, so a mislabelled profile cannot defeat the rule.
- **Strength per role** follows today's prose [repo:skills/dev-orchestrator/SKILL.md:178]:
  - Plan and code review: `required`.
  - Control review: `preferred`, because Astra cross-checks Luna- and Sol-written code today.
  - Final review: `required-or-announce`, which keeps the declared Astra-fallback exception and its announcement.

### 5.4 Fallbacks

`status --json` gives `job.onFailure` and `job.downProfiles` (§3.5). The orchestrator does exactly this:

```text
down  → health=<p>:down for each p in downProfiles (marker), one announcement,
        same operation on `route <role> --skip <all down/off>` FRESH
retry → one `task --fresh` on the same profile; a second failure → treat as down (class in the down set) or next
next  → same operation on `route <role> --skip <p,…>` FRESH, one announcement
route exit 2 → ONE question to the user: the dropped profiles with their reasons, plus the options
              (wait / enable <gray profile> in config.json yourself / stop the phase)
cancelled → report and wait (unchanged) [00 §1.5]
completed with a bad line 1 → today's verdict-parsing rule (one resume re-dispatch, then the user) [00 §1.9]
```

### 5.5 Kill switches

| Scope | Mechanism |
|---|---|
| Permanent, per profile | `SP_DISABLE_CHANNELS=glm-zcode,deepseek-pro-dsh` (env), or `config.json` `disabled`. Checked by `route` and by `task` (exit 2). |
| Legacy | `SP_IMPLEMENTER=luna` disables every implementer profile except `luna` [00 §3 C6]. |
| Session | The user says "без <profile>" or "через <profile>". The orchestrator writes `channel-<profile>` with `off` and passes it in `--skip`. The legacy phrases "через Luna" and "без GLM" map to the zai-family implementer profiles [00 §3 C6]. |
| Provider terms change | A policy row edited to `no` in a plugin update refuses at once, with no code change [07 §6.6]. |

### 5.6 Concurrency limits

| Limit | Default | Enforced by |
|---|---|---|
| One write task per working tree | 1 | The core reservation [00 §1.7]. Companion write jobs are counted through pass-through `status`. |
| Write tasks across all channels | `caps.writeTasks: 2` (today's "max 2 write tasks across both dispatchers" [00 §3 C19]) | The core counts running write records in every workspace dir. Exit 2 means "wait", not failure. |
| Per profile | `profile.concurrency`. Z.ai plans suggest 1 / 1–2 / 2+ parallel projects by tier [06 §2.1]; Kimi Tier0 allows 1 [06 §2.3]. | Slot files with pid and boot id, reaped like reservations. Reviewers count too. |
| Per quota group | `caps.quotaGroups`, e.g. `zai-coding-plan: 2` | Slots summed across the group's profiles |
| Per local server | 1 per `baseUrl` on 16 GB [08 §10 #10–11] | Slot keyed by `baseUrl` |

---

## 6. Security and compliance

### 6.1 Sandbox tiers per adapter

| Adapter | T0 `none` | T1 `native` | T2 `srt` | Source |
|---|---|---|---|---|
| zcode | today (`--mode yolo`) | — | possible via `-c` with the proxy variable; the key cannot be masked on macOS | [00 §1.7; 09 §8] |
| claude | not offered | `sandbox{enabled, failIfUnavailable, allowUnsandboxedCommands:false}` + permission rules for file tools + env scrub | inner sandbox off, key masked, `denyWrite` on the config dir | [09 §7.3] |
| codex | — | `-s workspace-write\|read-only`, network off, `ignore_default_excludes=false` | never (nested Seatbelt) | [09 §7.3, §8] |
| dsh | — | `DSH_PERMISSION_MODE`; writes only | only with its own sandbox off (unverified) | [04b §16; 10 §4.3; 09 §8] |
| pi | default | — | yes | [09 §8] |
| opencode | default | — | yes | [09 §8] |
| companion | — | Codex | — | [00 §1.7] |

### 6.2 Minimum tier per role

| Role | Requirement |
|---|---|
| `implementer` | Any tier. T0 also needs `preamble: headless-unsandboxed`, as GLM has today [00 §3 C17]. |
| `implementer.risk` | `riskEligible`, which means the M1–M9 bar [09 §9]. Today that is codex and the companion only. claude, pi and opencode on T2, and dsh on T1, flip to eligible only by a code change after their LIVE canaries pass. |
| plan, code, control and final reviewers | `readOnly ∈ {os, permission-rules}`, plus the L3 ref check [00 §4.2 R1]. |
| `advisory-reviewer`, `utility` | Any `readOnly ≠ none`; `tool-removal` (pi) is acceptable. |

### 6.3 Post-run checks (L3, every job)

These run in the core and are cheap and deterministic.

1. **Git config and hooks.** Hash `.git/hooks/*`, `.git/config` and the worktree `.git` file before and after the job. A difference gives `sandbox`/`git-config-changed` [09 §7.1].
2. **Read-only jobs.** `HEAD` and the ref set (`git for-each-ref` hash) must not change, or the job gets `sandbox`/`read-only-violated`. The index is deliberately not checked, because `git status` and `git diff` refresh it.
3. **Secret scan.** Check every keystore value the job used against the final message, the log, the `[REPORT_FILE]` named in the prompt, and `git diff`. A hit gives `sandbox`/`credential-leak`. The redactor already masks logs and results [00 §2], and the scan catches what reached files [09 §5 G].

### 6.4 Key custody

- **Entry.** Keys enter only through `key set` (stdin), the keychain, or the harness's own login run by the user (§4.5). This continues today's rules: "never in chat, argv or tool-visible env" [00 §4.1 I16] and "keys stay out of chat" [07 §6.4].
- **Tool-env scrub.**
  - claude: `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`, which E13 showed removes the token from Bash [01 E13].
  - codex: `ignore_default_excludes=false` [05 Bottom line].
  - T2 adds srt `mask`, which keeps the real key out of the sandbox [09 §2.4].
- **Residual risk, stated plainly.** pi, opencode and dsh on T0/T1 expose the env key to model-run shell commands [03 Bottom line; 09 §8]. That is the same class of exposure as today's ZCode key file [09 §8]. These profiles are therefore never risk-eligible until T2.
- **claude isolation.**
  - The profile home holds no claude.ai login, and `ANTHROPIC_API_KEY=""` is set.
  - An inherited `CLAUDE_CODE_OAUTH_TOKEN` is filtered out.
  - Preflight refuses if `auth status` shows a claude.ai login while `baseUrl` is not Anthropic's [07 §6.2; 01 E5].

### 6.5 ToS gating

`bin/lib/policy.json` follows the 07 recommendation. Rows are evaluated top-down and the first match wins. A missing row means `no` [07 §6.1].

```json
{
  "schema": 1, "reviewed": "2026-10-20",
  "rows": [
    { "plan": "zai-coding-plan", "harness": ["zcode","claude","codex","pi","opencode"], "status": "ok", "evidence": ["ZA2"] },
    { "plan": "zai-coding-plan", "harness": "*", "status": "no", "evidence": ["ZA1","ZA2","ZA3"],
      "why": "GLM Coding Plan only in tools Z.ai lists; never SDK or raw API" },
    { "plan": "alibaba-coding-plan", "harness": "*", "status": "no", "evidence": ["AL1"], "keyPrefix": ["sk-sp-"] },
    { "plan": "alibaba-token-plan", "harness": "*", "status": "no", "evidence": ["AL2"],
      "why": "06 §1.2 reads it as interactive-only; 07 §5 calls it gray; deny until clarified" },
    { "plan": "kimi-code-membership", "harness": "*", "status": "gray", "evidence": ["KI1","KI3"] },
    { "plan": "minimax-mplan", "harness": "*", "status": "gray", "evidence": ["MM1"] },
    { "plan": "claude-subscription", "harness": "*", "status": "no", "evidence": ["AN1","AN7","AN10","AN11"],
      "why": "Claude Pro/Max OAuth only in the unmodified claude binary; not dispatched by this plugin" },
    { "plan": "chatgpt-plan", "harness": ["companion","codex"], "status": "ok", "evidence": ["OA3","OA5"] },
    { "plan": "chatgpt-plus-pro", "harness": ["opencode","pi"], "status": "ok", "evidence": ["OA1","OCH1","PI4"] },
    { "plan": "copilot", "harness": "opencode", "status": "ok", "evidence": ["GH1","OCH2"] },
    { "plan": "opencode-go", "harness": ["claude","codex","zcode","pi","opencode"], "status": "ok", "evidence": ["OC1"] },
    { "plan": "deepseek-payg", "harness": "*", "status": "ok", "evidence": ["DS1","DS2"] },
    { "plan": "kimi-platform-payg", "harness": "*", "status": "ok", "evidence": ["07 §5 PAYG"] },
    { "plan": "minimax-payg", "harness": "*", "status": "ok", "evidence": ["MM1"] },
    { "plan": "alibaba-modelstudio-payg", "harness": "*", "status": "ok", "evidence": ["07 §5 PAYG"] },
    { "plan": "openrouter-payg", "harness": "*", "status": "ok", "evidence": ["OR1","OR2"] },
    { "plan": "local", "harness": "*", "status": "ok", "evidence": ["07 §2 local row"] }
  ]
}
```

The rows follow 07 §2 and §5. 07 has no "copilot in pi" row because pi's Copilot login is refused in code [07 §3].

**Order of checks at `profile add`, `doctor`, `route` and `task`.** `task` is the authoritative check.

1. **Adapter hard refusals in code.** These hold whatever the policy says:
   - pi with any OAuth `authType` [07 §3].
   - claude with a claude.ai login or an inherited OAuth token when `baseUrl` is not Anthropic's [07 §6.2].
   - A local profile with a non-loopback `baseUrl` [08 §10 #13].
   - codex `--oss` is never emitted [05 §15].
2. **Policy row.**
   - `no`: exit 2 with `refused: <plan> × <harness> = no [evidence]` and `hint: see docs/research/universal-dispatchers/07-tos-matrix.md §4`.
   - `gray`: the same refusal, unless `config.json` has `"grayOptIn": {"<profile>": {"rule": "MM1", "acknowledged": "<date>"}}`, written by the user. Doctor prints the evidence row whenever it applies [07 §6.1].
3. **Key shape.** `keyPrefix` and `rejectPrefix` are checked by reading the stored key's prefix inside the core, never printing it [06 §1.3].
4. **Re-verification is non-blocking.** Doctor WARNs once `reviewed` is more than 90 days old, because six governing pages changed in 2026 [07 §6.7].

### 6.6 What is enforced in code, and what stays in instructions

| In code (core or adapter) | In the skills (prose) |
|---|---|
| Policy and impersonation refusals. Family rule at `task`. Read-only capability and the L3 ref check. Env allowlist and repo-config neutralization (claude `--setting-sources ""`, OpenCode `OPENCODE_DISABLE_PROJECT_CONFIG=1`, the dsh pinned `baseURL`, the Codex project config that cannot redirect the provider [05 §5.1]). Key custody. Prompt-size caps. Write and slot caps. Kill switches. Version checks. `onFailure`. | When to call `route` and `task`. Prompt composition and the anti-coaching scan [00 §4.2 R10]. Verdict parsing. The one-question rule. **Never** run `key set`, edit `config.json`, `profiles/` or `policy.json`, enable a gray profile, or bypass `$AGENT` (Red Flags). |

Harness output is data. The core never executes anything taken from events or the final message.

### 6.7 Staying low-ceremony

- There are no receipts, hash-bound approvals, provenance chains or per-dispatch confirmations.
- Doctor and probe results are not persisted gates. The only health state is the session marker the orchestrator already keeps [00 §3 C5].
- Every refusal is one stderr line plus one `hint:` line, and exits 2.
- Every failure maps to one of three `onFailure` actions.
- When routing runs out of options, the user gets exactly one question (§5.4).
- WARN never blocks. Only FAIL and policy `no` block.
- Version adoption, risk eligibility and policy changes are code or config edits made by people. The runtime never "upgrades trust" on its own.

---

## 7. Orchestrator and skill changes

### 7.1 `skills/dev-orchestrator/SKILL.md`, by coupling point [00 §3]

| # | Today | After | Text |
|---|---|---|---|
| C1 | `$ZDISPATCH` and `$DISPATCH` resolution snippets | one `$AGENT` snippet (`bin/agent-dispatch`) | shrinks |
| C2 | prefix → dispatcher map, Red Flag at :753 | removed; one dispatcher takes every id | shrinks |
| C3 | `<name>.<seq>.(glm\|luna\|sol).(md\|id)` | `<name>.<seq>.<profile>.(md\|id)`; "highest seq wins" unchanged | same |
| C4 | `impl=<glm:zt-…\|luna:task-…\|sol:task-…\|claude\|—>` `glm=<…>` | `impl=<profile>:<id>\|claude\|—` and `health=<profile>:<ok\|down\|off>[,…]\|—` | same |
| C5 | marker `glm-channel` | marker `channel-<profile>`, same one-line format | same |
| C6 | `SP_IMPLEMENTER=luna`, "через Luna", "без GLM" | `SP_DISABLE_CHANNELS`, "без <profile>"; legacy forms mapped (§5.5) | shrinks |
| C7 | 5-item ladder, repeated for Step 5 and integration repair | `"$AGENT" route implementer [--risk] [--sticky <p>] --skip <down/off>`, once per phase | shrinks a lot |
| C8 | Sol escalation, "nothing above Sol" | `route implementer.escalation`; "nothing above" = escalation profile equals the current one | shrinks |
| C9 | model split table | role → profile table printed by `channels`; the skill keeps role names and effort-by-step | shrinks |
| C10 | family-rule prose | prose stays; `--writer` is enforced by the core | same |
| C11 | checklist items 5 and 10 | one item: "`$AGENT task --profile <p> --role <r>`; resume id from that profile's sidecar; preamble iff `channels` shows one" | shrinks |
| C12 | two failure ladders | the `onFailure` block (§5.4) | shrinks a lot |
| C13 | stale-reservation procedure quoting `zcode-dispatch:` strings | the same procedure with `agent-dispatch:` strings, for every core channel | same |
| C14 | `MAX_PROMPT_BYTES` → Luna FRESH | `task` exit 2 names the cap; re-route with `--prompt-bytes N` | shrinks |
| C15 | GLM first-dispatch probe procedure | "first dispatch to a profile this session: `doctor --profile P --probe`; exit 0 = ok; otherwise relay its `hint:` line once and mark it down" | shrinks |
| C16 | "Verified facts" lines in zcode-invocation | manifest and profile fields | shrinks |
| C17 | ZCode preamble | generic `headless-unsandboxed` preamble, chosen by `channels`; credential dirs filled from the profile | same |
| C18 | switch-notice enumerations | `<displayName>`, `job <profile>:<id>` | same |
| C19 | status on both dispatchers; cap of 2 | `"$AGENT" status --running`; the cap is enforced by the core | shrinks |
| C20 | GLM concurrency rule | `profile.concurrency` and quota groups, enforced by the core | shrinks |
| C21 | `$DISPATCH --model gpt-6-astra` in 7 files | `"$AGENT" task --background --profile auto --role <r> --writer <w> --fresh --prompt-file …` | same |
| C22 | GLM-specific Red Flags | generic flags (§6.6) plus the adapter notes | shrinks |
| C23 | prose naming GLM, Luna and Sol | role names | same |
| C24 | wrapper strings ("GLM run", "ZCode Task started") | `displayName` | same |
| C25 | `plugin.json` enumerates every model | roles plus "configurable channels" | shrinks |

The verdict token sets, the seq scheme, `[REPORT_FILE]`, review packages, the ledger, `risk_phases` and the in-process Claude roles stay as they are [00 §3, "Already generic"]. The Monitor loop changes only its variable:

```bash
until s=$("$AGENT" status "$ID" --json | python3 -c "import json,sys;print(json.load(sys.stdin)['job']['status'])"); \
  case "$s" in completed|failed|cancelled) true;; *) false;; esac; do sleep 25; done
```

The new ladder text in full:

```text
Channel (once per phase, at its first Step 3 dispatch):
  "$AGENT" route implementer [--risk if risk_phases[<id>]] [--sticky <profile already holding this phase>] --skip <health down/off>
  → use the printed profile for Steps 3, 3.5, 4, 5 of this phase. Exit 2 → ask the user one question (§5.4).
  Frontend-only phases: unchanged (Claude frontend implementer).
```

### 7.2 Invocation skills

- **`agent-invocation`.** `skills/zcode-invocation` (202 lines) and `skills/codex-invocation` (274 lines) merge into one manual-only `skills/agent-invocation/SKILL.md`. Its sections:
  - resolving `$AGENT`;
  - the verbs;
  - the Monitor loop;
  - `status` and `result`;
  - `onFailure`;
  - profile setup (`profile add`, `key set` in the user's terminal, `doctor --probe`);
  - the ad-hoc second-opinion template moved from codex-invocation, which `plugin.json` advertises;
  - generic Red Flags.
- **Adapter notes.** `skills/agent-invocation/adapters/<adapter>.md` holds per-harness notes: the ToS block with evidence ids, one-time setup, and known gotchas. They are read only during setup, or when a `hint:` line points there.
- **Old skills.** `zcode-invocation` and `codex-invocation` stay for one release as five-line redirect stubs, because they are manual-only entry points users may type.

### 7.3 Prompt files

The following files change only their dispatch line, from `$DISPATCH --model … task …` to `$AGENT task --profile auto --role … --writer …` [00 §3 C21]:

- `codex-plan-reviewer-prompt.md`
- `codex-control-review-prompt.md`
- `final-review-prompt.md`
- `brainstorming/spec-reviewer-prompt.md`
- `requesting-code-review/SKILL.md`
- `systematic-debugging/SKILL.md`

`implementer-prompt.md` swaps the channel enumerations for placeholders [00 §3 C17–C18]. File names stay, to avoid churn.

### 7.4 Net text size (estimate)

| File | Today | After |
|---|---|---|
| `dev-orchestrator/SKILL.md` | 793 lines [local wc] | ≈690–720. Ladder items, probe procedure, two failure ladders, checklist items 5 and 10, and the C14/C19/C20 specifics collapse. About 25 lines of `route` and `onFailure` are added. |
| invocation skills | 476 lines (202 + 274) | ≈250 in `agent-invocation`, plus ≈40 per adapter note, loaded on demand |
| prompt files | — | ≈0 net (string replacements) |
| `plugin.json` description | lists every model | shorter |

The orchestrator's always-loaded text **shrinks**. Harness-specific knowledge moves into code and on-demand notes.

---

## 8. Migration

### 8.1 GLM channel (`zcode-dispatch`)

1. **Extract.**
   - CORE and CORE-P (≈1,150 lines) move to `agent-core.mjs` and `transport/cli.mjs`. ZC (≈470) moves to `adapters/zcode.mjs` [00 §2].
   - The ZC lines inside `cmdTask` (≈36), `runJob` (≈31), `cmdDoctor` (≈54) and `runProbe` (≈25) become the `preflight`, `prepareHome`, `invocation`, `doctorChecks` and `probe` hooks [00 §2].
   - `parseCliOutput` becomes `reduce` [00 §2].
2. **Compatibility shim.**
   - `bin/zcode-dispatch` keeps its name and maps `task …` to `task --profile glm-zcode --role implementer …`.
   - In `--compat zcode` mode it keeps the exact strings the skills quote: the start line `ZCode Task started in the background as zt-NNNN` and the `zcode-dispatch:` stderr prefix [00 §1.2]. So no skill text changes in increment 0.
   - Oracle: `tests/test-zcode-dispatch.sh` stays at 110 PASS, 0 FAIL [00 §5].
3. **State.**
   - New jobs go to the new root. A `zt-` id that is missing there is looked up **read-only** in the legacy root `…-zcode/state/…` [00 §1.7] for `status`, `result` and as a `--resume-task` source. The resumed job copies the `sessionId` into a new record in the new root.
   - While a legacy runner is still alive, its legacy reservation is honoured, so two writers cannot meet in one tree across the two roots.
4. **Unchanged:** the key location (ZCode personal config inside the existing cli-home, behind the config lock) [00 §2], the selection pin, `SP_IMPLEMENTER=luna` [00 §3 C6] and the timeout env name (aliased).
5. **Drive-by fix:** remove the documented-but-unused `ZCODE_TEST_BOOT_TIME` [00 §7].

### 8.2 Codex channels (vendored companion)

1. **Increment 1: wrap unchanged.** `adapters/companion.mjs` has `transport: "external"`.
   - **task.** `bin/codex-dispatch task --background [--write] --model <profile.model> --effort <e> [--resume-task <task-id> | --fresh] --prompt-file F [--cwd W]`. `--model` is always passed, so the shim's `gpt-6.1-sol` default never applies silently [00 §1.1]. The id is parsed as the `task-…` token in the companion's start line, not its last word [00 §1.2].
   - **status, result and cancel** call the companion's verbs with `--json`, with read-only overlays on the companion's state:
     - `result` on a failed job exits 1 [00 §1.3].
     - `errorClass` comes from running the core's pattern framework over `errorMessage` [00 §1.10].
     - A `running` job with a dead `pid` is reported as `failed/crash` [00 §1.7].
     - A pruned job (50 per workspace) gives exit 2 "dispatch --fresh" on resume [00 §1.4].
   - **Write tasks** are counted toward the core's caps, because the companion has no lock [00 §1.7].
   - **Profiles:** `luna`, `sol` and `astra` (§4.3).
2. **Increment 3: `adapters/codex.mjs`** (`codex exec --json`, `cx-` ids) for third-party Responses providers.
3. **Parity run, LIVE, then one question.**
   - Add `luna-exec` and `astra-exec`: the codex adapter, `credential.ref: "login"`, and the user's own Codex home.
   - With the user's own Codex home, `-s workspace-write` writes its trust entry as interactive Codex does [05 §9].
   - Run one real phase: implement on `luna-exec`, control review on `astra-exec`.
   - Compare the reported model, the effort applied, resume by thread, that the read-only review cannot move refs (L3), the line-1 token, and cancel cleanliness.
   - **Green:** ask the user one question, "switch roles to the exec profiles and remove `vendor/codex-companion` after one release?" The switch is a `config.json` edit and needs no skill change.
   - **Not green:** the companion stays behind the pass-through indefinitely.
4. **Identity.** The companion's `clientInfo` name is "Claude Code" [00 §1.1; 05 §15]. It is used only with OpenAI's own login and never for third-party providers [05 §16].

---

## 9. Delivery plan

### 9.1 Increments

| # | Scope | Stub tests | Rough size | LIVE with the user's own keys (user's terminal) |
|---|---|---|---|---|
| 0 | `agent-core.mjs`, `transport/cli.mjs`, `adapters/zcode.mjs`, `bin/agent-dispatch`, compat shim | `test-zcode-dispatch.sh` still 110 PASS. New `tests/test-agent-core.sh`: zcode suite sections 3, 5, 7, 8, 9, 10 and 16 [00 §5] ported to a `null` adapter. `agent-stub.cjs` with the `zcode-json` dialect. | ≈1,650 lines moved, ≈300 new; tests ≈+700 | One GLM phase through the shim: doctor, probe, task, resume. |
| 1 | `registry.mjs`, `policy.json`, `route`, `channels`, `profile`, `key`, `status --running`, caps and slots, L3 checks; `adapters/companion.mjs`; the skill rewrite (§7) | `test-policy.sh` (every `no` row in 07 §5 refuses with exit 2); `test-route.sh` (family, risk, skip, sticky, gray, prompt bytes, quota-group down); companion overlays against a fake `codex-dispatch` script; L3 tamper cases | ≈+600 core, ≈200 adapter; skills net about −100 | A full `/dev` run on a small plan. Then `SP_DISABLE_CHANNELS=glm-zcode` to force Luna, with Astra reviews. Behaviour must match today's. |
| 2 | `adapters/claude.mjs`; templates `claude/{zai,deepseek,kimi,minimax,alibaba,openrouter,local}`; `advisory-reviewer` and `utility` roles | `claude-stream-json` dialect: ok; `is_error` with exit 0 (401/429/529); `error_max_turns`; SIGTERM 143 with empty stdout; `permission_denials`; preassigned session and resume; record mode asserts `--setting-sources ""` and no parent `ANTHROPIC_*` or `CLAUDE_CODE_ENTRYPOINT`; an E9 redirect regression with a fake repo `.claude/settings.json` | ≈450 | Per profile: `profile check` and probe on the Z.ai Anthropic endpoint with the plan key, DeepSeek and Kimi Platform. A wrong-key 401 must classify as `auth`. One implementer phase on `glm-cc`. One advisory review. `count_tokens` and `anthropic-beta` behaviour on Z.ai, Kimi and Alibaba [06 §7 Q5]. |
| 3 | `adapters/codex.mjs` (custom providers), then `luna-exec` and `astra-exec` | `codex-jsonl`: `thread.started`, `turn.failed`, unknown-model exit 0, SIGINT/SIGTERM orphan sweep, flags-before-`resume` order, `-o last.txt` | ≈400 | Probes: DeepSeek Responses and Z.ai `/api/v1`. Resume. A read-only review cannot write. The §8.2 parity run. |
| 4 | `adapters/dsh.mjs` (headless) | `dsh-ndjson`: late session event, SIGTERM exit 0, `dsh: QUOTA:`-style codes, a non-completed `turn_end` with exit 1, cancel with detached descendants | ≈400 | `--dump-config` assertions, probe, one implementer phase in a linked worktree [04b §15], the `.env` WARN. |
| 5 | `sandbox/srt.mjs`, `doctor --probe-sandbox`, T2 tier | A fake `srt` that records `--settings` and exits 0 on SIGTERM [09 §7.4]; nesting refusal when `SANDBOX_RUNTIME=1` | ≈350 | The user installs srt 0.0.81 globally. Canaries per harness. Mask with a DeepSeek key. The reflection test [09 §10]. Only then flip `riskEligible` per adapter, in code. |
| 6 | `adapters/pi.mjs` | `pi-jsonl`: provider error with exit 0, unknown session id, refusal when `pi auth check` reports OAuth, `length` stop reason | ≈400 | `pi auth check`, probe with a DeepSeek key, SIGTERM cleanup. |
| 7 | `adapters/opencode.mjs` (v1) | `opencode-jsonl`: error-then-recover exit 1 with a final text, `auto-rejecting`, stdin left open, the `--agent` typo warning, detached bash pgids, a major-2 FAIL | ≈450 | A pinned v1 install (not Homebrew Core v2), probe, exit-code behaviour. The ChatGPT or Copilot login in an isolated home only if the user wants it. |
| 8 (opt.) | `transport/acp.mjs` and dsh guarded mode | A stub ACP agent, every frame validated against the vendored v1 schema [10 §4.7] | 400–600 [10 §4.7] | `dsh --profile acp`. Whether read-only can be selected per session is open [10 §6 Q1]. |

### 9.2 Test strategy

- **One stub, many dialects.** `tests/fixtures/agent-stub.cjs` takes these variables:
  - `AGENT_STUB_DIALECT` ∈ {`zcode-json`, `claude-stream-json`, `codex-jsonl`, `dsh-ndjson`, `pi-jsonl`, `opencode-jsonl`, `acp`};
  - `AGENT_STUB_MODE`;
  - `AGENT_STUB_RECORD`.

  It is selected per adapter through `AGENT_BIN_<ADAPTER>`, the same way `ZCODE_BIN` works today [00 §5]. The modes are the 15 existing ones (`ok … malformed`) [00 §5], plus cross-harness traps found in the reports:

  | Mode | Report |
  |---|---|
  | `exit0-error` | [01 §11; 03 §15; 05 §3] |
  | `sigterm-exit0` | [04b §10; 09 §7.4] |
  | `error-then-recover` | [02 Fact-check log] |
  | `auto-reject` | [02 §7] |
  | `stdin-wait` | [02 Fact-check log] |
  | `detached-child` | [02 §10; 04b §10] |
  | `late-session` | [04b §4] |
  | `max-turns` | [01 §11] |
  | `rate-limit` vs `quota-exhausted` | — |
  | `context` | — |
  | `reported-model-mismatch` | — |
  | `replay:<file>` | — |
- **Core suite, run once.** `tests/test-agent-core.sh` uses a `null` adapter. It covers reservation, boot id, reaper, cancel, timeout, sticky terminal, redaction, env filter [00 §5], plus slots, caps, `onFailure` and the L3 checks.
- **Adapter suites.** One per adapter: `tests/adapters/test-<id>.sh`. Each covers:
  - argv and env goldens in record mode;
  - dialect parsing;
  - one case per classification row;
  - signal-ladder order (the stub logs the signals it receives);
  - resume preconditions;
  - doctor and probe on the stub;
  - `requiredFlags` against a fake `--help`;
  - the adapter's hard refusals.
- **Policy and route suites.** Table-driven JSON cases. Every no-go pair in 07 §5 has a case that must exit 2.
- **Dialect recordings.** `tests/fixtures/dialects/<adapter>/<version>/` holds redacted transcripts from `doctor --probe --record`. The stub replays them, so a harness upgrade becomes "record, replay, bump `tested`" (§3.7).
- **What tests never do:** call a network endpoint, need a key, or install a harness. Real harness binaries appear only in LIVE checks, run by the user.

### 9.3 Validated only LIVE (no stub can prove these)

1. Each provider accepts the request shape its adapter sends: tool_choice, thinking and effort fields [06 §1.4], and Kimi's lack of a `tool` tool_choice [06 §1.4].
2. Reported-model strings match each profile's `reportedMatch`.
3. Real 401, 429 and quota texts classify as intended.
4. Plan keys versus Standard keys bill as expected on Z.ai [06 §1.3].
5. srt canaries and mask behaviour per harness and version [09 §10].
6. dsh `workspace-write` in linked worktrees [04b §15].
7. Codex `exec` parity with the companion for Luna, Sol and Astra (§8.2).

---

## 10. Risks and open questions

| Risk | Mitigation |
|---|---|
| The core extraction regresses the GLM channel. | Increment 0 changes no skill text, keeps exact strings in compat mode, and uses the 110-test oracle [00 §5]. |
| Harness churn: claude ships near-daily [01 §1]; codex ships daily alphas [05 §1]; dsh ships only prereleases [10 §2.1]; pi has breaking minors [03 §15]; OpenCode has a v2 split [02 Bottom line]. | Offline `requiredFlags` checks on every doctor; the probe runs through the real reducer; exact pins for prerelease harnesses; recorded dialect fixtures. |
| Failures that exit 0, and successes that exit non-zero (§3.2). | `reduce()` alone decides, and a stub mode exists for each trap. |
| Key exposure on T0 and T1 for pi, opencode and dsh [09 §8]. | Never risk-eligible before T2. The L3 secret scan. The same class of exposure as ZCode today. |
| A mislabelled `family` defeats the family rule. | The prefix-table check makes it a FAIL (§5.3). |
| Profiles that share a plan hide a single quota (`glm-zcode` and `glm-cc`). | `quotaGroup` caps and `downProfiles` propagation (§3.5, §5.6). |
| Companion overlays drift from vendored output. | The companion is vendored and pinned, and the overlay tests run against a fake script; retiring it is the goal (§8.2). |
| Policy rows go stale; six governing pages changed in 2026 [07 §6.7]. | The `reviewed` date with a non-blocking WARN; a row edit is the kill switch [07 §6.6]. |
| srt is beta, and `tlsTerminate` masking is experimental [09 §2]. | T2 comes late, is opt-in per profile, and fails closed [09 §7.4]. |

**Open questions:**

1. **Z.ai.** Does headless self-use of a listed tool (`claude -p`, `opencode run`, `pi`) count as "automated usage"? The terms address only use "on behalf of others" [06 §7 Q1; 07 §7]. Today's ZCode channel lives with the same gap.
2. **Z.ai and srt.** Is an srt sentinel→key swap in front of a listed tool "use outside such tools" under the Z.ai terms [09 Open questions]? This decides whether a GLM Coding Plan profile can ever reach T2 with masking.
3. **dsh over ACP.** Can a reviewer choose `read-only` per session over ACP, and which calls raise `approval/request` under the default ACP profile [10 §6 Q1]?
4. **Claude Code auto mode** is unproven on non-Claude endpoints [01 §7]. The design uses `acceptEdits` plus `--allowedTools`. Is that tool set enough for the implementer prompts without stalls?
5. **Alibaba Token Plan.** Is it gray or no? The reports disagree [06 §1.2; 07 §5]. The policy denies it until clarified.
6. **Retention.** The core keeps records indefinitely, as zcode does, while the companion prunes to 50 [00 §1.4]. Does the core need a `gc --older-than` verb, and what horizon is safe for cross-session plan resume?
7. **Write cap.** Should `caps.writeTasks` be global (today's 2) or per quota group once several providers run in parallel?
8. **Structured verdicts.** Should reviewer channels with `json-schema` or `--output-schema` [01 §12; 05 §12] return structured verdicts in addition to line 1? The current proposal keeps line-1 tokens only.
9. **OpenCode v1.** How long will the 1.x line keep getting releases now that Homebrew Core ships v2 [02 §17 Open questions]?

---

## 11. Deliberate non-goals

- **No ACP-everywhere.** No ACP SDK dependency and no `npx` launches at runtime [10 §4.5, §4.7].
- **No SDK-embedded runners** (Claude Agent SDK, pi SDK) [03 §16.6; 07 ZA3].
- **No plan-to-API proxies**, credential pooling, User-Agent or originator rewriting, or reuse of another client's OAuth identity [07 §3, §6.3, §6.8].
- **No subscription credential handling by the plugin.** Logins are run by the user against an isolated home. Claude Pro/Max OAuth is never dispatched outside the unmodified binary [07 §5].
- **No automatic installs, updates or model pulls.** No `ollama launch --yes`, no `codex --oss`, no harness auto-update [08 §10 #12; 05 §15].
- **No dynamic routing** by cost, benchmark or latency. A role is an ordered list that the user edits.
- **No new verdict format.** Line-1 tokens and `[REPORT_FILE]` stay [00 §1.9].
- **No receipts, approvals or persisted trust state** (§6.7).
- **No local models** for planning, risk phases or blocking review [08 §9].
- **No change to the in-process Claude roles** (Opus plan writer and reviewers, the Sonnet gate and quickfix, the frontend implementer).
- **No containers or VMs** in this plan [09 §4]. T2 means srt only.
- **No adapters for** Kimi CLI, Antigravity, consumer Gemini CLI, Qwen Code, Crush or Cline (§3.9).
