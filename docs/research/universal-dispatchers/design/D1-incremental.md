# D1 — Incremental, MVP-first universal dispatch

- **Proposal id:** `D1-incremental` · **Date:** 2026-10-20 · **Branch:** `research/universal-dispatchers` (code snapshot `c1aa9e0`)
- **Citations:** `[NN §x]` means `docs/research/universal-dispatchers/NN-*.md`, section x. `SKILL.md:N` means `skills/dev-orchestrator/SKILL.md` line N at `c1aa9e0`. Evidence IDs such as `ZA2` or `AL1` refer to the register in `[07 §4]`.

---

## 1. Thesis

- Grow the dispatcher that already works; do not design a new one.
- Split `zcode-dispatch.mjs` into a shared job core and a ZCode adapter. About 70 % of it is already harness-agnostic [00 §2].
- Add one wrapper, `agent-dispatch --profile <name>`. Its first adapter, `claude -p` on Anthropic-compatible endpoints, reaches GLM, DeepSeek, Kimi, MiniMax, Qwen, OpenRouter and local servers [01; 06 §1.1].
- Its second adapter, `codex exec` with custom Responses providers, is the only OS-sandboxed path for third-party models [05 §8; 09 §9].
- Profiles are user JSON gated by a ToS allowlist that ships with the plugin [07 §6]. The orchestrator's hardcoded GLM/Luna/Sol choices become role → channel lists whose defaults equal today's ladder.

---

## 2. Architecture overview

### 2.1 Components

| Component | File(s) | Status | What it does |
|---|---|---|---|
| Job core | `bin/lib/dispatch-core.mjs` | **new, moved code** | Everything CORE and CORE-P in the [00 §2] map: job records with sticky terminal claims, the per-workspace reservation, the boot-id reaper, timeouts, process-group kill, env allowlist, key redaction, the classifier framework, the doctor/probe framework, `release-stale`, and the stdin secret reader. It exports `createDispatcher(adapter, options) → main(argv)`. |
| ZCode adapter | `bin/lib/adapters/zcode.mjs` | **new, moved code** | The roughly 470 ZC lines [00 §2]: app discovery, cli-home, the personal provider config, the template rule, the argv build and `parseCliOutput`. |
| ZCode entry | `bin/lib/zcode-dispatch.mjs`, `bin/zcode-dispatch` | shrinks / unchanged | Now about 40 lines: core + zcode adapter, plus re-exports of the constants the tests use as an oracle (`PATTERNS`, `MAX_PROMPT_BYTES`, `ENV_ALLOW`, `ID_RE`, …) [00 §5]. Same verbs, `zt-` ids, state dir and messages. |
| Agent entry | `bin/agent-dispatch` (shim), `bin/lib/agent-dispatch.mjs` | **new** | Loads profiles and policy, applies the policy, role and family gates, and resolves routing. Owns the verbs `profiles`, `profile add`, `profiles check` and `key set|clear|status`. Calls the core with the adapter the profile names. Ids are `at-NNNN` for every profile. |
| Adapters | `bin/lib/adapters/claude-compat.mjs` (Inc 1), `bin/lib/adapters/codex-provider.mjs` (Inc 4) | **new** | Implement the §3.2 interface. |
| Policy | `bin/lib/agent-policy.json` | **new, shipped** | The (plan, harness) allowlist with evidence IDs and a review date; plan → allowed hosts; model-id → family prefixes [07 §6.1]. |
| Templates | `bin/lib/agent-templates/*.json` | **new, shipped** | One file per §4.2 profile, with no secrets. |
| User data | `~/.claude/plugins/data/superpowers-strigov-ver-agents/` | **new** | `profiles.json` (user-edited), `keys/<profile>` (0600), `homes/<profile>/` (0700 harness homes), `state/<ws>/jobs/`, `slots/<profile>/`. The shim pins it as `AGENTS_STATE_DIR`, the way `bin/zcode-dispatch` pins `ZCODE_STATE_DIR`. |
| Skill | `skills/agent-invocation/SKILL.md` | **new** | A manual-only recipe modelled on `zcode-invocation`. |
| Codex companion | `bin/codex-dispatch`, `vendor/codex-companion/` | **unchanged** | Still serves Astra, Luna and Sol on the user's ChatGPT login. |

### 2.2 Data flow

```
dev-orchestrator (Sonnet main thread)
  | once per session:  "$ADISPATCH" profiles      -> channel rows + resolved routing (section 4.5)
  | per phase:         ladder over routing.implementer -> channel name
  | writes             $dir/prompts/<op>.<seq>.<channel>.md      (channel = glm | luna | sol | <profile>)
  | dispatches via     $ZDISPATCH (glm)  |  $DISPATCH (luna/sol/astra)  |  $ADISPATCH (any profile)
  v
bin/agent-dispatch task --background --profile ds-pro --role implementer [--risk] [--writer-family F]
                        [--cwd W] [--resume-task at-N | --fresh] --prompt-file F
  | agent-dispatch.mjs: load profiles.json + agent-policy.json
  |   gate: policy row ok (or gray + allowGray) | base-URL host in plan hosts | role vs adapter tier
  |         | family vs --writer-family | kill switches | per-profile slot          -> else exit 2 "refused (<kind>)"
  | dispatch-core: git-tree guard, reservation (write roles only), record at-NNNN, spawn detached runner
  |   stdout: "ds-pro Task started in the background as at-0007"   (id = last token, [00 §1.10])
  v
runner (__run): adapter.writeJobFiles -> buildArgv/buildEnv -> harness CLI in its own process group
  |   claude -p ... < prompt        (claude-compat)     |  codex exec --json ... - < prompt   (codex-provider)
  |   timeout -> group kill; stderr redaction; post-run secret scan + .git protected-path check
  v
record finalized: completed | failed/<errorClass> | cancelled
  ^ Monitor loop: "$ADISPATCH" status at-0007 --json -> job.status   (same loop, sleep 25, [00 §1.8])
  ^ "$ADISPATCH" result at-0007 -> final message; line 1 = status/verdict token
```

The orchestrator-facing contract is unchanged, so the line-1 token parser, the Monitor loop, sidecars and "highest seq wins" carry over as is [00 §3, "Already generic"].

---

## 3. Harness adapter contract

### 3.1 Verbs (identical on `zcode-dispatch` and `agent-dispatch`)

```
task --background --profile P --role implementer|reviewer [--risk] [--writer-family F]
     [--cwd W] [--resume-task <id> | --fresh] --prompt-file F         # zcode-dispatch: no --profile/--role
status [<id>] [--cwd W] [--all] [--json]       # {"job":{status, errorClass, profile, adapter, family, role, ...}}
result <id> [--cwd W]                           # completed -> stored final message, exit 0; else exit 1
cancel <id> [--cwd W]
release-stale [--cwd W]
doctor [--profile P] [--probe] [--cwd W]        # "ok|WARN|FAIL <check>: <detail>", "hint: ...", "doctor: ok|FAIL"
```

The rules come from the normalization list in [00 §1.10]:

- **Exit codes:** 0, 1 or 2. Exit 2 is a refusal and is always printed as `agent-dispatch: refused (<kind>): <reason>`, where `<kind>` is one of `policy`, `disabled`, `busy`, `role`, `family`, `usage` or `resume`.
- **Resume:** allowed only from a `completed` job that has a session handle, with the same profile. Anything else exits 2 with "dispatch --fresh" [00 §1.6, §1.10].
- **Retention:** records are never pruned.

### 3.2 Adapter interface

The interface is the minimum the existing code implies [00 §2]. Two hooks are added: `writeJobFiles` and `classify`.

```js
// bin/lib/adapters/<name>.mjs
export default {
  name: "claude-compat",          // adapter id used in profiles
  harness: "claude-code",         // harness id used in agent-policy.json rows
  idPrefix: "at",                 // zcode adapter: "zt"
  manifest: { /* section 3.3 */ },
  paths(profile, stateRoot) {},   // harness binary, home dir, job dir layout
  version(paths) {},              // truthful harness version string for the record
  preflight(ctx) {},              // task/doctor guards; throws UsageError(kind, msg) -> exit 2
  writeJobFiles(ctx) {},          // e.g. homes/<p>/settings.<role>.json (0600), system-append.md
  buildArgv({ profile, role, workspaceRoot, sessionId, resume, jobDir }) {},
  buildEnv({ profile, role, key, jobDir }) {},   // adapter-owned vars, applied AFTER filterCliEnv [00 §4.1 I17]
  parseOutput(stdout, stderrTail) {},            // -> { response, sessionId, usage, reportedModel, denials }
  classify({ exitCode, signal, parsed, stdout, stderrTail }) {},  // -> errorClass | null (then PATTERNS)
  PATTERNS: { /* model-not-selected, auth, quota, launch regexes, as in zcode */ },
  secretSource(profile) {},       // { values: [key], files: [keyFile] } for the redactor and the post-run scan
  doctorChecks(ctx) {},           // [{ level, check, detail, hint }]
  probe(ctx) {},                  // { argv, env, stdinText: "Reply with exactly: PONG", expect: "PONG" }
  resumeCompatible(record, profile) {},
};
```

### 3.3 Capability manifest

Every adapter declares these fields. `agent-dispatch profiles` prints them per channel, which replaces the prose "Verified facts" lines [00 §3 C16].

| Field | Values | Used by |
|---|---|---|
| `promptTransport`, `maxPromptBytes` | `argv` + cap, or `stdin` + cap | core `checkPromptFile`; orchestrator oversize rule (C14) |
| `resume` | `session` (handle stored in the record), `none` | core resume guard; orchestrator fresh vs resume |
| `readOnly` | `none`, `tools` (no write/exec tools exist in the run), `os` (OS-enforced) | role gate: `--role reviewer` needs `tools` or `os` |
| `sandboxTier` | `T0` none, `T1` tools, `T2` bash-os, `T3` os (see §6.1) | role gate: `--risk` needs `T3`; new implementer profiles need ≥ `T2` |
| `nestsSeatbelt` | bool | doctor refuses when `SANDBOX_RUNTIME=1` [09 §2.5] |
| `structuredOutput` | `none`, `json-schema`, `output-schema` | informational; the MVP keeps the line-1 token [05 §12] |
| `cancel` | `{ first: "SIGINT" or "SIGTERM", graceMs, sweepDescendants }` | core `cmdCancel` and timeout |
| `errorClasses` | subset of the 7 classes [00 §1.5] plus `context` and `violation` | orchestrator failure ladder (§5.4) |
| `keyCustody` | `harness-file`, `env-scrubbed`, `auth-command` | doctor text; §6.2 |
| `isolation` | how the harness home is pinned | doctor |
| `minVersion` / `pinnedVersion` | semver | doctor FAIL below the minimum; WARN off the pinned version |

The two new classes have narrow meanings:
- `context`: the prompt does not fit the model. Claude Code reports this as `terminal_reason: prompt_too_long` [01 §11]; [08 §10 #3] proposes the same class.
- `violation`: the post-run scan found the key in the diff, report or result, or `.git/hooks` / `.git/config` changed [09 §7.1 L3].

### 3.4 How each harness fits

| | **zcode** (exists) | **claude-compat** (`claude -p` + endpoint profile) | **codex-provider** (`codex exec`, custom provider) | **opencode** | **pi** | **dsh** |
|---|---|---|---|---|---|---|
| Unique unlock | GLM Coding Plan in Z.ai's own harness (status quo) | Every provider with an Anthropic Messages endpoint: Z.ai, DeepSeek, Kimi Platform, MiniMax, Alibaba, OpenRouter, Ollama, llama-server [06 §1.1] | Providers with a Responses endpoint (DeepSeek, Z.ai, Kimi, MiniMax, Alibaba, OpenRouter, local) **inside Codex's OS sandbox** [05 §5.3, §8] | Copilot plan (GH1), OpenCode Go/Zen natively, ChatGPT through SIWC [07 §5] | 40+ providers; the ChatGPT subscription flow [03 §5; 07 §3] | DeepSeek's own harness [04b] |
| Prompt | argv, 120/200 KiB cap [00 §1.1] | stdin, 10 MB cap [01 §2] | stdin `-` [05 §2] | stdin redirect only [02] | stdin [03 §2.2] | stdin `-` [04b §2] |
| Final message | JSON `response` | JSON `result` (`is_error`, `api_error_status`, `terminal_reason`) [01 §3] | JSONL plus `-o last.txt` [05 §3] | JSONL text events or `opencode export` [02 §16] | `--mode json` events [03 §3] | NDJSON `final.text` [04b §16] |
| Resume | `--resume sess_…` | `--session-id <uuid>` pre-assigned, `--resume <uuid>` with the same `CLAUDE_CONFIG_DIR` [01 §4] | `exec [flags] resume <thread_id>`, with flags before `resume` [05 §4] | `-s <sessionID>` [02 §16] | `--session-id` + same dir + same cwd; an unknown id silently creates a new session [03 §4] | `--session-id`, same cwd [04b §16] |
| Read-only | none [00 §4.2 R2] | `tools`: `--tools "Read,Glob,Grep"` + `--permission-mode dontAsk` [01 §7] | `os`: `-s read-only` blocks writes and network [05 §7] | `tools`: a custom reviewer agent; `plan` is not read-only [02] | `tools`: `--tools read,grep,find,ls` [03 §16.2] | `os`-ish: native `read-only` mode [04b §16] |
| Native sandbox / tier | none, yolo / **T0** | Bash-only Seatbelt or bwrap; Read/Edit governed by permission rules / **T2** implementer, **T1** reviewer [01 §8; 09 §3] | tools inside, harness and key outside, network off / **T3** [09 §3, §8] | none / T0, or T2 under srt [09 §8] | none / T0, or T2 under srt [09 §8] | Seatbelt, writes only [09 §3] |
| Cancel | SIGTERM group, 5 s, SIGKILL | SIGINT exits 0 with empty stdout; SIGTERM exits 143 and kills Bash trees [01 §10] → `SIGTERM` first | SIGTERM orphans tools; SIGINT cleans them [05 §10] → `SIGINT`, 10 s, SIGTERM, SIGKILL, sweep | sweep descendant pgids [02 §16] | SIGTERM; SIGKILL orphans [03 §16.2] | SIGINT, 7 s, SIGKILL, PGIDs [04b §16] |
| Provider-error exit | non-zero | 1, but `subtype:"success"` + `is_error:true` [01 §3] | 1 via `turn.failed`; an `error` item can appear on exit 0 [05 §3] | 0 on auto-reject [02] | 0; classify from events [03 §3.3] | 1 [04b] |
| Key custody | plaintext personal config file [09 §3] | env var scrubbed from Bash [01 §6, E13] | `auth.command` [05 §6] | `auth.json` or `{file:}` [02 §16] | `auth.json` / env [03 §16.1] | env / `.env` [04b §16] |
| Isolation | cli-home | fresh `CLAUDE_CONFIG_DIR` + `--setting-sources ""` + `--settings <file>` [01 §9] | `CODEX_HOME` per profile [05 §9] | `XDG_*` + `OPENCODE_*` [02] | `PI_CODING_AGENT_DIR` + flags [03 §9] | `DSH_HOME`, empty `DSH_AGENTS_HOME` [04b §16] |
| Version | ZCode app pin | ≥ 2.1.302; about 13 releases in 2 weeks [01 §1] | 0.163.0 [05 §1] | 1.19.3; the v1/v2 split matters [02] | 1.3.0, high churn [03] | `dsh-v0.2.1-rc.2`, a prerelease [04b] |
| **Build order** | **Inc 0** (extract) | **Inc 1** | **Inc 4** | Inc 5, on demand, behind srt | Inc 5, on demand, behind srt | Inc 5, on demand |

### 3.5 claude-compat: the exact invocation

**Implementer argv.** The runner spawns this detached, in its own process group, with cwd = the worktree:

```
claude -p --output-format json \
  --setting-sources "" --settings <homes>/<p>/settings.implementer.json \
  --model <profile.model> --effort <profile.effort> \
  --tools "Bash,Read,Edit,Write,Glob,Grep" --permission-mode acceptEdits \
  --strict-mcp-config --disable-slash-commands \
  --append-system-prompt-file <job>/system-append.md \
  --session-id <uuid generated by the runner> [--resume <stored uuid>] \
  --max-turns <profile.maxTurns, default 200>        < <prompt file>
```

Why each part is there:
- `--setting-sources ""` together with `--settings` blocks the repo-settings credential redirect [01 §9 E9].
- Non-bare mode with an explicit `--tools` list is used because `--bare` offers only Bash/Edit/Read [01 §15.8].
- `system-append.md` re-injects the repo's `CLAUDE.md` / `AGENTS.md`, which `--setting-sources ""` drops [01 §15.9].
- `--session-id` pre-assigns the session handle, so the record holds it before the run starts [01 §4].

**Reviewer argv** (Inc 3): the same, but with `--tools "Read,Glob,Grep" --permission-mode dontAsk` and `settings.reviewer.json` [01 §7]. The reviewer gets no Bash, so it cannot move HEAD (R1). It reads the review package by path (R5), and the package already carries the diff, so no git command is needed (R6 is covered by the package). The run takes **no** reservation (R2).

**Environment.** The child env is `filterCliEnv(process.env)`, the core allowlist [00 §2]. Its `ENV_DENY` already drops every `ANTHROPIC_*` and `CLAUDE_*` variable, including `CLAUDE_CODE_ENTRYPOINT` [01 §6 E23]. Only these adapter-owned variables are added after the filter:
- `CLAUDE_CONFIG_DIR=<homes>/<p>`. The home is per profile, not per job, because resume is bound to the config dir [01 §4], and 4 concurrent runs can share one dir [01 §10].
- `ANTHROPIC_AUTH_TOKEN=<key>` and nothing else as a credential, because two credential variables send two headers [01 §15.2]. A `local` profile gets the dummy `local-dummy` [08 §10].

**Generated `settings.implementer.json`** (0600, rewritten at every task, under the profile home):

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4-pro[1m]",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-pro[1m]",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-flash",
    "CLAUDE_CODE_SUBAGENT_MODEL": "deepseek-flash",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB": "1",
    "CLAUDE_CODE_MAX_RETRIES": "2",
    "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
    "DISABLE_AUTOUPDATER": "1",
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "786432"
  },
  "permissions": {
    "deny": ["WebFetch", "WebSearch",
             "Read(<agents data root>/**)", "Read(~/.ssh/**)", "Read(~/.aws/**)", "Read(~/.codex/**)",
             "Read(~/.zcode/**)", "Read(~/.claude/**)", "Edit(.git/**)", "Write(.git/**)"]
  },
  "skipWebFetchPreflight": true,
  "disableAllHooks": true,
  "sandbox": {
    "enabled": true, "failIfUnavailable": true, "allowUnsandboxedCommands": false,
    "network": { "allowedDomains": [], "strictAllowlist": true },
    "credentials": { "envVars": [{ "name": "ANTHROPIC_AUTH_TOKEN", "mode": "deny" }] }
  }
}
```

Sources for this file:
- Every alias tier is pinned to a provider id, so no `claude-*` id reaches the provider [01 §5].
- Errors fail fast instead of after about 3 minutes [01 §11].
- WebFetch and WebSearch are denied, the preflight is off, hooks are off and Anthropic traffic is off [01 §9, §15.11].
- Bash runs in a sandbox with the token denied [01 §8 E13; 09 §7.3 "Alternative without srt"].

The exact permission-rule path syntax, and the nesting of `network.*`, are fixed by the Inc 1 local-real test (§9), not assumed. A profile's `env` may set only `API_TIMEOUT_MS`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS`, `CLAUDE_STREAM_IDLE_TIMEOUT_MS`, `API_FORCE_IDLE_TIMEOUT` and `CLAUDE_CODE_ATTRIBUTION_HEADER` [01 §5; 08 §10]. Any other key, including `ANTHROPIC_BASE_URL`, is refused at load.

**Classification.** Structured fields are checked first, then `PATTERNS`, then the default [01 §3, §10, §11]:

| Signal | errorClass |
|---|---|
| Wrapper deadline | `timeout` |
| Spawn error. Exit ≠ 0 with stderr only (unknown flag, invalid settings, `No conversation found`). `api_error_status:null` with `Connection refused` / `ENOTFOUND` | `launch` |
| `api_error_status` 401/403, or `Not logged in` / `Failed to authenticate` | `auth` (keyed on the status, because the text varies [01 §15.4]) |
| 404, or `There's an issue with the selected model` | `model-not-selected` |
| 429 with usage/limit/quota/balance/billing wording | `quota` (quota and throttling differ only in the provider text [01 §11]) |
| `terminal_reason:"prompt_too_long"` | `context` |
| Any other 429, 5xx or 529 | `crash` (transient) |
| `subtype:"error_max_turns"` (`result:null`); exit 0 with empty or non-JSON stdout; empty `result` | `malformed` |
| Post-run key match or a protected-path hash change | `violation` |

A non-empty `permission_denials` on a completed job is stored as `job.denials`. It is not a failure.

### 3.6 codex-provider: the exact invocation (Inc 4)

The runner uses `CODEX_HOME=<homes>/<p>`, which also absorbs the `trust_level` write-back [05 §9]:

```
codex exec --json -o <job>/last.txt -C <worktree> -s workspace-write|read-only \
  -c 'model_providers.glm-cx={name="glm-cx",base_url="https://api.z.ai/api/v1",wire_api="responses",auth={command="<node>",args=["<plugin>/bin/lib/agent-dispatch.mjs","__print-key","glm-cx"]}}' \
  -c 'model_provider="glm-cx"' -m glm-5.3 -c 'model_reasoning_effort="max"' \
  -c 'web_search="disabled"' --disable plugins --disable multi_agent --disable goals \
  -c analytics.enabled=false -c feedback.enabled=false -c check_for_update_on_startup=false \
  -c shell_environment_policy.ignore_default_excludes=false \
  -c sandbox_workspace_write.exclude_slash_tmp=true -c sandbox_workspace_write.exclude_tmpdir_env_var=true \
  [resume <thread_id>] -                 < <prompt file>
```

The provider and its key handling follow [05 §5.1, §6, §16] and pattern F [09 §5]. The hardening flags come from [05 §9]. A resume puts the same flags before `resume` [05 §4]. On top of this the runner:
- adds a Codex permissions profile that marks the keys dir unreadable [09 §7.3], so `__print-key` fails if a sandboxed tool tries it;
- treats `turn.failed` or exit 1 as failure and ignores the metadata `error` item that appears on exit 0 [05 §3];
- classifies with [05 §11]: `Quota exceeded` → `quota`, 401 → `auth`, 404 `model_not_found` → `model-not-selected`, context window → `context`, `Missing environment variable` / `Error loading config.toml` → `launch`, rate limits and 5xx → `crash`.

### 3.7 Build first, later, never

- **First:** `zcode` extraction (Inc 0, no behaviour change), then `claude-compat` (Inc 1). One adapter covers every Anthropic-endpoint provider, including the GLM Coding Plan, because Z.ai lists Claude Code (ZA2). It has stdin transport, fast failure and a Bash sandbox. A loopback stub can test it with dummy tokens, as [01 §18] already did.
- **Second:** `codex-provider` (Inc 4). It is the only route that meets the minimum bar for SECURITY/DATA_LOSS phases (M1–M9) with a third-party model, and it gives reviewers OS-enforced read-only [09 §8, §9]. It does not replace the companion for OpenAI models (§8.2).
- **On demand (Inc 5):**
  - `opencode` behind srt, if the user wants the Copilot plan or OpenCode Go natively [07 §5];
  - `pi` behind srt;
  - `dsh` on its native sandbox, for the DeepSeek API only (DS2);
  - an ACP transport only if dsh or Kimi needs the guarded mode [10 §4.7].
  Each one is gated on the [09 §10] smoke matrix.
- **Never build:**
  - Qwen Code: its draw is the Alibaba Coding and Token plans, which are refused headless [06 §1.2; AL1].
  - Kimi Code CLI on a membership: interactive only (KI1).
  - Antigravity / Gemini CLI on consumer logins (GO1–GO4).
  - pi's Anthropic and Copilot logins, which impersonate other clients (PI1–PI3).
  - Crush, Cline and Aider [04 §B.1].
  - Any translating or pooling proxy [05 §15.1; 07 §6.8; 09 §5 C].

---

## 4. Profiles / registry

### 4.1 Location and format

- **User file:** `~/.claude/plugins/data/superpowers-strigov-ver-agents/profiles.json`, plain JSON. The wrappers are dependency-free Node [00 §2], and TOML/YAML would need a parser. No secrets go in it. Profile names match `^[a-z][a-z0-9-]{1,15}$` and must not be `glm|luna|sol|astra|claude`.
- **Shipped files:** `bin/lib/agent-policy.json` (ToS, plan hosts, family prefixes) and `bin/lib/agent-templates/*.json`.
- **No repo-level config.** A worked-on repository cannot add or redirect a profile, mirroring Codex ignoring project `model_providers` [05 §5.1].

### 4.2 Example `profiles.json` (7 ToS-safe profiles + routing)

```json
{
  "version": 1,
  "profiles": {
    "glm-cc": {
      "adapter": "claude-compat", "plan": "zai-coding-plan",
      "baseUrl": "https://api.z.ai/api/anthropic",
      "model": "glm-5.3-flash[1m]", "smallModel": "glm-5.3-flash", "effort": "max",
      "family": "glm", "roles": ["implementer"], "concurrency": 1, "timeoutMin": 60,
      "env": { "API_TIMEOUT_MS": "3000000", "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "1000000" }
    },
    "ds-pro": {
      "adapter": "claude-compat", "plan": "deepseek-payg",
      "baseUrl": "https://api.deepseek.com/anthropic",
      "model": "deepseek-v4-pro[1m]", "smallModel": "deepseek-flash", "effort": "high",
      "family": "deepseek", "roles": ["implementer"], "concurrency": 2,
      "env": { "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "786432" }
    },
    "kimi-k3": {
      "adapter": "claude-compat", "plan": "kimi-platform-payg",
      "baseUrl": "https://api.moonshot.ai/anthropic",
      "model": "kimi-k3[1m]", "smallModel": "kimi-k2.7-code", "effort": "max",
      "family": "kimi", "roles": ["reviewer"], "concurrency": 1
    },
    "qwen-max": {
      "adapter": "claude-compat", "plan": "alibaba-modelstudio-payg",
      "baseUrl": "https://<WorkspaceId>.us-east-1.maas.aliyuncs.com/apps/anthropic",
      "model": "qwen3.8-max", "smallModel": "qwen3.8-flash", "effort": "xhigh",
      "family": "qwen", "roles": ["reviewer"], "concurrency": 2
    },
    "minimax-flash": {
      "adapter": "claude-compat", "plan": "minimax-payg",
      "baseUrl": "https://api.minimax.io/anthropic",
      "model": "MiniMax-M3.1-Flash[1m]", "smallModel": "MiniMax-M3.1-Flash", "effort": "max",
      "family": "minimax", "roles": ["implementer"], "concurrency": 2, "enabled": false,
      "env": { "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "524288" }
    },
    "glm-cx": {
      "adapter": "codex-provider", "plan": "zai-coding-plan",
      "baseUrl": "https://api.z.ai/api/v1", "model": "glm-5.3", "effort": "max",
      "family": "glm", "roles": ["implementer.risk"], "concurrency": 1,
      "catalog": "<abs path to Z.ai's models.json>"
    },
    "local-qwen": {
      "adapter": "claude-compat", "plan": "local",
      "baseUrl": "http://127.0.0.1:9931",
      "model": "qwen3.6-35b-a3b", "smallModel": "qwen3.6-35b-a3b", "effort": "high",
      "family": "qwen", "roles": ["implementer"], "concurrency": 1, "enabled": false, "timeoutMin": 120,
      "env": { "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "65536", "CLAUDE_STREAM_IDLE_TIMEOUT_MS": "1800000",
               "API_FORCE_IDLE_TIMEOUT": "0", "CLAUDE_CODE_ATTRIBUTION_HEADER": "0" },
      "note": "not viable on a 16 GB M4 (08 bottom line 2); for a 32 GB+ machine"
    }
  },
  "routing": {
    "implementer": ["glm", "ds-pro"],
    "implementer.risk": ["sol"],
    "reviewer.plan": ["astra"],
    "reviewer.control": ["astra"]
  }
}
```

Why each profile is ToS-safe and what its values rest on:
- **`glm-cc`:** the GLM Coding Plan in Claude Code is a safe default (ZA2) [07 §5]. It uses the same model as today's channel, so switching harness is a clean A/B.
- **`ds-pro`, `kimi-k3`, `qwen-max`, `minimax-flash`:** PAYG keys carry no tool restriction [06 §1.2; 07 §5].
- **Recipes:** the endpoints and tier models are the vendors' Claude Code recipes [06 §2.1–2.5]. MiniMax M3.1 Flash has no published benchmarks [06 §5], so its profile ships `enabled:false`.
- **`glm-cx`:** the GLM Coding Plan in Codex is also listed (ZA2), and Z.ai documents this exact Codex configuration [05 §5.3]. It needs Inc 4.
- **`local-qwen`:** a loopback-only endpoint profile, as [08 bottom line 6] recommends. llama-server's default port is 9931 [08 §3].
- **Routing:** the defaults are today's ladder. Adding `"ds-pro"` puts DeepSeek V4 Pro behind GLM as a second family before the Luna tail [06 §6].

### 4.3 `agent-policy.json` (shipped; excerpt)

```json
{
  "version": 1, "reviewed": "2026-10-20", "source": "docs/research/universal-dispatchers/07-tos-matrix.md",
  "plans": {
    "zai-coding-plan":   { "vendor": "zai",      "hosts": ["api.z.ai", "open.bigmodel.cn"] },
    "deepseek-payg":     { "vendor": "deepseek", "hosts": ["api.deepseek.com"] },
    "kimi-platform-payg":{ "vendor": "moonshot", "hosts": ["api.moonshot.ai", "api.moonshot.cn"] },
    "kimi-code":         { "vendor": "moonshot", "hosts": ["api.kimi.ai", "api.kimi.com"] },
    "minimax-payg":      { "vendor": "minimax",  "hosts": ["api.minimax.io", "api.minimaxi.com"] },
    "minimax-m-plan":    { "vendor": "minimax",  "hosts": ["api.minimax.io", "api.minimaxi.com"] },
    "alibaba-modelstudio-payg": { "vendor": "alibaba",
      "hostPattern": "^(?!token-plan\\.)[a-z0-9-]+\\.(ap-southeast-1|us-east-1|eu-central-1|ap-northeast-1|cn-beijing)\\.maas\\.aliyuncs\\.com$" },
    "alibaba-coding-plan": { "vendor": "alibaba", "hosts": ["coding-intl.dashscope.aliyuncs.com"], "keyPrefixes": ["sk-sp-"] },
    "alibaba-token-plan":  { "vendor": "alibaba", "hostPattern": "^token-plan\\." },
    "openrouter-payg":   { "vendor": "openrouter", "hosts": ["openrouter.ai", "eu.openrouter.ai"] },
    "local":             { "vendor": "local", "hosts": ["127.0.0.1", "::1", "localhost"], "loopbackOnly": true }
  },
  "rules": [
    { "plan": "zai-coding-plan",     "harness": "zcode",       "status": "ok",   "evidence": ["ZA2"] },
    { "plan": "zai-coding-plan",     "harness": "claude-code", "status": "ok",   "evidence": ["ZA2", "ZA3"] },
    { "plan": "zai-coding-plan",     "harness": "codex",       "status": "ok",   "evidence": ["ZA2"] },
    { "plan": "zai-coding-plan",     "harness": "dsh",         "status": "no",   "evidence": ["ZA1", "ZA2"] },
    { "plan": "deepseek-payg",       "harness": "*",           "status": "ok",   "evidence": ["DS1", "DS2"] },
    { "plan": "kimi-platform-payg",  "harness": "*",           "status": "ok",   "evidence": [], "basis": "07 §5 pay-as-you-go row" },
    { "plan": "kimi-code",           "harness": "*",           "status": "gray", "evidence": ["KI1", "KI3"] },
    { "plan": "minimax-payg",        "harness": "*",           "status": "ok",   "evidence": ["MM1"] },
    { "plan": "minimax-m-plan",      "harness": "*",           "status": "gray", "evidence": ["MM1"] },
    { "plan": "alibaba-modelstudio-payg", "harness": "*",      "status": "ok",   "evidence": [], "basis": "07 §5 pay-as-you-go row" },
    { "plan": "alibaba-coding-plan", "harness": "*",           "status": "no",   "evidence": ["AL1"] },
    { "plan": "alibaba-token-plan",  "harness": "*",           "status": "no",   "evidence": ["AL2"] },
    { "plan": "openrouter-payg",     "harness": "*",           "status": "ok",   "evidence": ["OR1", "OR2"] },
    { "plan": "local",               "harness": "*",           "status": "ok",   "evidence": [], "basis": "07 §2 local-model row" }
  ],
  "families": { "glm": ["glm-", "z-ai/"], "deepseek": ["deepseek"], "kimi": ["kimi", "moonshotai/"],
                "minimax": ["minimax"], "qwen": ["qwen"], "openai": ["gpt-", "openai/"],
                "anthropic": ["claude", "anthropic/"], "google": ["gemini", "gemma", "google/"] }
}
```

How the policy is applied:
- **Matching:** the most specific row wins.
- **Default deny:** a (plan, harness) pair with no row is refused.
- **Messages:** a refusal prints the evidence IDs and the line in `07-tos-matrix.md` §4 to read. Register quotes are not copied into code.
- **Token Plan conflict:** the Token Plan is `no` here even though [07 §5] files it as gray, because [06 §1.2] quotes the Personal overview as banning automation. The stricter source wins until the discrepancy is resolved (§10).

### 4.4 How credentials are referenced

A profile never contains a key. The key's only home is `keys/<profile>`: mode 0600, inside the 0700 data dir, written atomically by `agent-dispatch key set <profile>`.

- **Input:** `key set` reads stdin through the core's hidden-echo `readSecretLine` [00 §2]. It refuses empty or multi-line input, any prefix in the plan's `keyPrefixes` blacklist (for example `sk-sp-` for the Alibaba Coding Plan [06 §1.3]), and any `local` plan.
- **Other verbs:** `key clear` deletes the key. `key status` prints only `set` or `missing`.
- **Delivery to the harness:**
  - claude-compat: the runner reads the file in-process and sets `ANTHROPIC_AUTH_TOKEN` in the child env object. The key never goes into argv or a settings file.
  - codex-provider: `auth.command` calls `__print-key` (§3.6).
- **Redaction and scan:** the value always feeds the core redactor and the post-run scan (§6.2).

### 4.5 How the user creates and checks a profile

1. **Copy a template** (no secrets). The user runs it, or asks Claude in chat to run it: `"$ADISPATCH" profile add ds-pro --from deepseek-v4-pro`. The orchestrator never edits `profiles.json` on its own initiative. `allowGray`, `enabled` and `routing` are the user's own edits.
2. **Store the key.** The user runs this in their own terminal, with a hidden prompt: `"$ADISPATCH" key set ds-pro`. Or they copy the key last and run `! pbpaste | "$ADISPATCH" key set ds-pro`, the same pattern as `zcode-invocation` "One-time setup".
3. **Validate offline:** `"$ADISPATCH" profiles check` checks the schema, policy row, host-to-plan pairing, family-to-model-prefix match, env-key allowlist, unresolved `<…>` placeholders and role-to-tier compatibility. It prints one line per profile and exits 1 on any error.
4. **Run doctor:** `"$ADISPATCH" doctor --profile ds-pro`, then `--probe` (one paid PONG request). Example output:

```
ok   version: claude 2.1.302 (min 2.1.302)
ok   policy: deepseek-payg x claude-code = ok [DS1,DS2] reviewed 2026-10-20
ok   host: api.deepseek.com in plan hosts
ok   key: set (keys/ds-pro, 0600)
ok   home: homes/ds-pro 0700; auth status authMethod=oauth_token, no claude.ai login
ok   nesting: SANDBOX_RUNTIME unset
doctor: ok
answers: PONG
reported-model: deepseek-v4-pro
probe: ok
```

   The `auth status` line uses `claude auth status --json` [01 §6]. A fresh config dir has no login and fails closed [01 §6 E5]. The probe line format is the existing generic probe output [00 §2].
5. **Route it:** add the name to `routing.implementer`.
6. **What the orchestrator reads, once per session** (`"$ADISPATCH" profiles`):

```
glm           builtin  adapter=zcode          family=glm      roles=implementer      tier=T0 maxPrompt=200K resume=yes conc=2 state=enabled
ds-pro        profile  adapter=claude-compat  family=deepseek roles=implementer      tier=T2 maxPrompt=10M  resume=yes conc=2 state=enabled policy=ok
kimi-k3       profile  adapter=claude-compat  family=kimi     roles=reviewer         tier=T1 maxPrompt=10M  resume=no  conc=1 state=enabled policy=ok
minimax-flash profile  adapter=claude-compat  family=minimax  roles=implementer      tier=T2 maxPrompt=10M  resume=yes conc=2 state=off(enabled:false)
routing implementer=glm,ds-pro,luna implementer.risk=sol reviewer.plan=astra reviewer.control=astra
```

If `agent-dispatch` cannot be resolved, or `profiles.json` is absent, the orchestrator uses the built-in default, `implementer=glm,luna`, which is exactly today's ladder.

---

## 5. Roles and routing

### 5.1 Which roles can use profiles

| Role (SKILL.md model split) | Default | Profile-eligible | Minimum tier | Freshness |
|---|---|---|---|---|
| Plan writer / reviser, primary review 4.1, final review Step 5, diagnosis, gate, quickfix, frontend implementer | Claude subagents | **no** (non-goal) | — | — |
| Implementer, non-risk (Steps 3, 3.5, 4, 5, integration repair) | `glm` → `luna` | **yes, Inc 2** (`routing.implementer`) | T2 for profiles; built-in `glm` stays T0 | resume by id |
| Implementer, SECURITY/DATA_LOSS phases | `sol` | **yes, Inc 4**, T3 adapters only (`routing.implementer.risk`) | T3 | resume by id |
| Reasoning escalation | `sol` | no | — | as today |
| Plan reviewer (Step 2) | `astra` | **yes, Inc 3** (`routing.reviewer.plan`) | T1 without write/exec tools, or T3 read-only | FRESH every round (R3) |
| Control reviewer (Step 4.2) | `astra` | **yes, Inc 3** (`routing.reviewer.control`) | same | FRESH every round |

### 5.2 Per-role selection

`agent-dispatch profiles` resolves each role list and appends the built-in tail if it is missing:
- `implementer` gets `luna`;
- `implementer.risk` gets `sol`;
- the reviewer roles get `astra`.

So every list ends on a channel that works today. The orchestrator picks the **first channel in the list that is enabled, healthy and family-eligible**. Probing happens lazily: the first time the ladder reaches an `unprobed` channel, it runs `doctor` and then `doctor --probe`, once per session per channel [00 §3 C15].

### 5.3 Family rule (model family, not harness family)

- **Where the family comes from:** each channel's family comes from `profiles` (`glm`, `deepseek`, `kimi`, `minimax`, `qwen`, `openai`, `anthropic`, …). Built-ins: `glm` = glm, `luna`/`sol`/`astra` = openai, Opus/Sonnet = anthropic.
- **Validation:** `profiles check` checks `profile.family` against the model-id prefix table in `agent-policy.json`. GLM through OpenRouter or Alibaba is still `glm` [06 §6]. A local model belongs to its vendor family [08 §9]. A mismatch exits 2 (`refused (family)`).
- **Writer vs reviewer:** the orchestrator passes the artifact writer's family with `--writer-family <f>` on every profile-reviewer dispatch, and the dispatcher refuses when they match. The prose rule at SKILL.md:178 stays authoritative and the code is the backstop.
- **Implementer warning:** `profiles check` **warns** when an implementer profile's family is `anthropic` or `openai`, because Opus and Astra review its code.

### 5.4 Fallbacks (one generic failure ladder replacing SKILL.md:422-428, C12)

| Outcome | Action (announced in one line) |
|---|---|
| `failed` with `quota`, `auth` or `model-not-selected` | The channel goes `down` for the session (state line + marker). Relay the dispatcher's `hint:` line verbatim. Re-dispatch the **same operation** FRESH on the next channel in the role list. |
| `failed` with `timeout`, `crash`, `launch` or `malformed` | One `--fresh` retry on the same channel. A second failure moves to the next channel; the channel is marked `down` only if the second class is in the row above. |
| `failed` with `context` | No retry. Same operation, FRESH, on the next channel whose `maxPrompt` and context fit. The channel stays `ok`. |
| `failed` with `violation` | The channel goes `down`. Dispatch nothing more into this tree. Ask **one** question with two options: discard the job's changes to the reported paths, or inspect them first. Tell the user to rotate the key in their own terminal. |
| `cancelled` | Report and wait (as today). |
| exit 2 `refused (busy)` | Next channel in the list. If none is left, wait in a Monitor loop of at most 10 minutes for a slot, then ask the user. |
| exit 2 `refused (disabled)` or `refused (policy)` | The channel goes `off` for the session; next channel. |
| exit 2, any other kind | Fix the dispatch (as today for zcode exit 2). |

The stale-reservation procedure (SKILL.md:430-437) applies unchanged to both wrappers. Its quoted strings carry a `<dispatcher>:` prefix (C13).

### 5.5 Kill switch

- **Global, new code only:** `SP_AGENT_DISPATCH=off`. `agent-dispatch task` refuses with `refused (disabled)`, and `profiles` shows every profile `off`. Routing then collapses to the built-ins, which is exactly today's behaviour.
- **Per channel:**
  - `SP_DISABLE_CHANNELS=ds-pro,glm-cc` in the environment;
  - `"enabled": false` in `profiles.json`;
  - the session phrase "без <channel>", stored as the marker `channel-<name>` = `off`.
- **Legacy, kept:**
  - `SP_IMPLEMENTER=luna` disables every implementer wrapper channel (`glm` and all profiles), so implementer = Luna, as today.
  - "через Luna" / "без GLM" keep their meaning [00 §3 C6].

### 5.6 Concurrency limits

- **Per tree:** one write task per working tree, enforced by the core reservation [00 §1.7]. Reviewer roles take no reservation (R2).
- **Per profile:** `profile.concurrency`, enforced by the core across workspaces with `slots/<profile>/slot.<n>` files. They are created with `O_EXCL`, record pid and boot id, and are reaped like reservations. A full profile gives `refused (busy)`. Defaults follow plan ceilings:
  - GLM plan: 1 until the user sets their tier (Lite 1, Pro 1–2, Max 2+) [06 §2.1];
  - Kimi Platform Tier0: 1 [06 §2.3];
  - DeepSeek: 2, well under its 500 [06 §2.2];
  - local: 1 [08 §10 #10–11].
- **Orchestrator:** the width cap of 2 write tasks counts **all** channels (C19).

---

## 6. Security and compliance

### 6.1 Sandbox tiers per role and adapter

| Tier | Meaning | Adapters | Allowed roles |
|---|---|---|---|
| **T0** none | Harness runs as the user; only the git-tree guard and env allowlist apply [00 §4.1 I19] | `zcode` (yolo) | Non-risk implementer, **grandfathered for built-in `glm` only**. No new T0 channel is added. |
| **T1** tools | No write or exec tools exist in the run | claude-compat reviewer (`Read,Glob,Grep`) | Reviewers |
| **T2** bash-os | Shell under Seatbelt/bwrap with no network and the key scrubbed; Read/Edit under deny rules; the harness itself outside [01 §8; 09 §7.3] | claude-compat implementer | Non-risk implementer |
| **T3** os | Harness and key outside; every tool command inside an OS sandbox with network off [09 §3, §8] | codex-provider, companion | Everything, including SECURITY/DATA_LOSS (M1–M9 [09 §9]) and OS read-only reviewers |

OpenCode and pi rise from T0 to T2 only behind srt with key masking, after the [09 §10] smoke matrix (Inc 5).

### 6.2 Key custody

| Adapter | At rest | In flight | Visible to model tools? | Backstops |
|---|---|---|---|---|
| zcode | ZCode personal config, 0600, under a config lock (unchanged) [00 §2] | harness file | yes (yolo) | redaction |
| claude-compat | `keys/<p>`, 0600 | `ANTHROPIC_AUTH_TOKEN` in the claude process only | no for Bash (`SUBPROCESS_ENV_SCRUB` + sandbox `credentials` deny, verified [01 §6 E13]); no for Read (deny rule on the agents data root) | redaction; post-run scan |
| codex-provider | `keys/<p>`, 0600 | `auth.command` in Codex memory | no (`ignore_default_excludes=false`; keys dir unreadable in the sandbox) [05 §6; 09 §5 F] | redaction; post-run scan |

The post-run scan is a single substring search for the key across the job diff (`git diff` against the reservation-time HEAD), the report file, the result and the logs. A hit gives `violation` [09 §5 G]. Credentials never pass through chat, argv or a settings file. The user stores them with `key set` from their own terminal [07 §6.4].

### 6.3 ToS gating

ToS is checked at profile load, as a pure table lookup in `agent-policy.json` [07 §6.1]. There are no runtime gates:
- `ok` → proceed.
- `gray` → only when the user wrote `"allowGray": true` in the profile. `profiles check` then prints the evidence IDs once, and doctor shows `WARN policy: gray (<ids>) enabled by user`.
- `no` or no row → exit 2 `refused (policy)`.

Further controls:
- **Host pinning:** the base-URL host must match the plan's hosts. This blocks sending a plan key to the wrong endpoint; typed keys are a known trap [06 §1.3].
- **No Anthropic endpoints:** claude-compat refuses `api.anthropic.com`, any profile without a key (except `local`), and any home that has a claude.ai login. A Claude subscription is therefore never routed through the dispatcher [07 §3, §6.2].
- **Truthful identity:** each harness identifies itself [07 §6.3]. The env allowlist strips `CLAUDE_CODE_ENTRYPOINT` [01 §14]. The adapters never set user-agent, originator or client-ID values.

### 6.4 What code enforces vs what instructions say

| Control | Code (where) | Instruction only |
|---|---|---|
| (plan, harness) allowlist; gray opt-in; plan ↔ host | `agent-dispatch.mjs` profile load → exit 2 | — |
| No claude.ai login reaches a third party | claude-compat: fresh `CLAUDE_CONFIG_DIR`; doctor checks `authMethod`; Anthropic hosts refused | — |
| Repo cannot redirect the key | `--setting-sources ""` + `--settings` [01 §9] | — |
| Key out of chat, argv, logs and tool env | `key set` stdin only; env allowlist; scrub; redactor; post-run scan | skill: never ask for a key, never run `key set` |
| Reviewer cannot write | `--role reviewer` → T1/T3 argv; no reservation | prompt text "never move HEAD" (defence in depth) |
| Risk phase only on T3 | `--risk` refused below T3 | orchestrator must pass `--risk` (checklist item, §7.1) |
| Family rule | `--writer-family` check; `profiles check` warning | orchestrator picks reviewers by family (SKILL.md:178) |
| One write task per tree | core reservation (per wrapper) | `status` on every dispatcher before re-dispatch (C19) |
| Per-plan concurrency | slot files | — |
| Kill switches | env vars and the `enabled` flag checked by `task` | session phrases → marker file |
| No commits, branches or index changes by implementers | Bash sandbox protects `.git/hooks` and `.git/config` [01 §8]; deny rules on `.git/**`; post-run hash check | headless preamble forbids history ops |
| No network beyond the provider | claude-compat Bash `allowedDomains: []`; Codex network off | preamble |

### 6.5 Staying low-ceremony

- **No added machinery:** no receipts, prompt hashes, provenance records or approval gates. The only one-time step is the user's own `key set`.
- **Refusals are deterministic and immediate.** Every refusal is an exit 2 with one line, and the orchestrator has one fixed reaction to each kind (§5.4): next channel (announced), fix the dispatch, or exactly one question.
- **Health checks** are one `doctor` and one `--probe` per channel per session. Markers restore state after compaction, the same mechanism as today [00 §3 C5].
- **The post-run checks** (secret scan and `.git` hash) take milliseconds and end in a fallback, never a wait.
- **Verification stays where it is:** the coordinator's `git diff`, the Step 3.5 gate and its own test runs. Nothing in this design asks the orchestrator to trust a dispatcher's claim of success.

---

## 7. Orchestrator and skill changes

### 7.1 `skills/dev-orchestrator/SKILL.md` (Inc 2; reviewer parts in Inc 3)

| Coupling [00 §3] | Today (line) | Change |
|---|---|---|
| C4 state line | `impl=<glm:zt-…\|luna:task-…\|sol:task-…\|claude\|—> glm=<unprobed\|ok\|down\|off>` (:100) | `impl=<channel>:<id> \| claude \| —` and `ch=<name>:<unprobed\|ok\|down\|off>[,…]` for the channels in the resolved implementer list. Default: `ch=glm:unprobed`. |
| C5 marker | `<scratchpad>/dev-orchestrator/glm-channel` (:106) | `<scratchpad>/dev-orchestrator/channel-<name>`, same one-line format |
| C1/C2 recovery prefix map | `zt-` → `$ZDISPATCH`, `task-` → `$DISPATCH` (:109, :753) | add `at-` → `$ADISPATCH` (resolved like `$ZDISPATCH`); the sidecar's `channel:` already names the channel |
| C19 Durable Progress item 4 | `status` on both dispatchers (:119) | `status` on every resolved dispatcher (at most three) |
| C9 model split | Implementer row = GLM via `$ZDISPATCH` (:144-176) | "first healthy channel of `routing.implementer` (default `glm`); profile channels via `$ADISPATCH`, model and effort pinned by the profile". The risk row and the reviewer rows each name their routing key. |
| C10 family rule | "GLM adds a third family" (:178) | Family = the `family` column of `"$ADISPATCH" profiles`; pass `--writer-family` on profile-reviewer dispatches |
| C11 checklist item 10 | GLM only (:214) | "Wrapper channels (glm and profiles)": the dispatch file `.<channel>.md` starts with the headless preamble; `--profile` + `--role` are present; `--risk` iff the phase is risk-marked; the resume id is this channel's; `ch=<name>:ok`; the channel is not disabled. Item 5 (Codex) is unchanged. |
| C15 probe | Step 3 item 4, GLM-specific remedies (:366) | "first dispatch on an `unprobed` channel: `doctor` then `doctor --probe` (`--profile <name>` for profiles); exit 0 → `ok`; otherwise `down`, and relay the `hint:` line verbatim". The GLM `api-key set` remedy moves into the zcode hint. |
| C7 ladder | items 1–5 (:368-374, repeated at :558, :659) | 1. kill-switch filter; 2. risk-marked → `implementer.risk` (legacy `SP_IMPLEMENTER=luna` still sends risk phases to Luna, as at :370); 3. phase already handed to a channel → stays; 4. first `ok` channel of `implementer`, probing `unprobed` ones in order; 5. Luna. |
| C6 kill switch | (:378) | add `SP_DISABLE_CHANNELS`, `SP_AGENT_DISPATCH=off`, and the phrase "без <channel>" |
| C3 suffix | `.<glm\|luna\|sol>.md` / `.id` (:384, :389) | `.<channel>.md` / `.id`, channel = built-in or profile name; "highest seq wins" is unchanged |
| C12 failure ladder | GLM-only, keyed on errorClass (:422-428) | the generic table in §5.4 |
| C14 oversize | `MAX_PROMPT_BYTES` → Luna (:428) | → next channel whose `maxPrompt` fits (stdin channels hold 10 MB) |
| C20 GLM concurrency | (:635) | `conc` column per channel |
| C21 reviewers | `$DISPATCH --model gpt-6-astra` (:299-309, :514) | Inc 3: "first eligible channel of `reviewer.plan` / `reviewer.control`. `astra` → today's command; a profile → `"$ADISPATCH" task --background --profile P --role reviewer --writer-family F --fresh --prompt-file …`". The FRESH-every-round rule is unchanged. |
| C22 Red Flags | GLM-specific (:775-780) | Generic: never bypass a dispatcher; never handle credentials in chat; never edit `profiles.json` on your own; never give a risk-marked phase to a channel below T3. |

### 7.2 `skills/dev-orchestrator/implementer-prompt.md`

- "ZCode preamble (GLM dispatches only)" (lines 40-53) becomes "Headless preamble (every wrapper channel: glm and profiles)". The text is the same, except that `~/.zcode` becomes "any harness config or key directory" (C17).
- In the channel-switch notice enumerations (lines 57-62), `<GLM-5.3-Flash via ZCode | Codex Luna | Codex Sol>` becomes `<channel display name from "$ADISPATCH" profiles>` and `job <zt-NNNN | task-NNNN>` becomes `job <channel>:<id>` (C18).

### 7.3 Invocation skills

- **New `skills/agent-invocation/SKILL.md`, about 170 lines:**
  - the `$ADISPATCH` resolution snippet (a copy of `zcode-invocation`'s);
  - one-time setup (§4.5);
  - doctor/probe output and the Monitor loop (identical; `at-` ids);
  - the flag reference, resume semantics and the exit-2 kinds table;
  - the compliance block, which points at `agent-policy.json` and the never-build list;
  - a never-do list.
  Add it to `PIPELINE_SKILLS` in `tests/test-pipeline-context.sh`, which checks the manual-only marker.
- **`zcode-invocation`:** one line points to `agent-invocation`. The "Verified facts" lines stay, because `profiles` prints the glm row from them. The skill shrinks by about 5 lines.
- **`codex-invocation`:** unchanged in Inc 1–3. Inc 4 adds 3 lines saying that third-party models in Codex go through `agent-dispatch`, never the companion. The companion would misidentify itself to third parties [05 §14].
- **Reviewer templates** (`codex-plan-reviewer-prompt.md`, `codex-control-review-prompt.md`): Inc 3 makes the dispatch line channel-neutral, about 4 lines each.

### 7.4 How much text shrinks or grows

- **`dev-orchestrator/SKILL.md` (793 lines):** about 90 lines are touched and the net change is about +25 lines (+3 %). The GLM-only paragraphs (:366, :422-428) become shorter generic ones, and the ladder and routing paragraph grows by about 15 lines.
- **`implementer-prompt.md`:** about 12 lines touched, net 0.
- **New:** `agent-invocation` (+170 lines).
- **`.claude-plugin/plugin.json`** (C25): the description gains "configurable channels".
- **Orchestrator per-turn context cost:** the state line grows by a few characters only when more than one implementer channel is routed.

---

## 8. Migration of the existing GLM (zcode-dispatch) and Codex (companion) channels

### 8.1 GLM (zcode-dispatch)

- **Inc 0:** zcode moves onto the core with **zero surface change**. The verbs, the `zt-` ids, `ZCODE_STATE_DIR`, `api-key set`, every quoted stderr string (the orchestrator quotes them verbatim [00 §1.2]) and the `SP_IMPLEMENTER=luna` refusal stay. The acceptance gate is `bash tests/test-zcode-dispatch.sh` → 110 PASS, 0 FAIL, unchanged [00 §5].
- **Inc 2:** `glm` becomes a **built-in channel row** in `profiles` (adapter `zcode`, tier T0, conc 2 from the "Verified facts"). The orchestrator treats it like any channel. The only changes are naming (C3–C5) and the generic failure ladder, whose `{quota, auth, model-not-selected}` / transient split is today's GLM rule [00 §1.5].
- **Optional, the user's choice:** `glm-cc` (§4.2) runs the same model on the same Coding Plan through Claude Code, which Z.ai lists (ZA2).
  - Gains: stdin transport (no `MAX_PROMPT_BYTES` fallback), a T2 Bash sandbox instead of yolo, fast failure, and resume by pre-assigned session id.
  - Possible loss: ZCode's quota bonus, which `zcode-invocation` records as inconclusive.
  - Mechanics: no automatic switch; the user writes `"implementer": ["glm-cc", "glm"]` to try it.
- **Shared write lock:** after Inc 0 both wrappers run on one core, but each keeps its own reservation directory. A later one-line core option (`reservationRoot`) can point both at `~/.claude/plugins/data/superpowers-strigov-ver-locks/`. Until then the cross-wrapper rule is today's orchestrator discipline (§10).

### 8.2 Codex (companion)

- **Unchanged for OpenAI models.** Astra, Luna and Sol stay on `bin/codex-dispatch` and the ChatGPT login. That pair is sanctioned [07 §5] and covered by the companion's own tests. Moving it would gain the reservation, timeout, reaper and errorClass it lacks [00 bottom line 3], but it is not needed for multi-provider dispatch. It is listed as a later option (§11).
- **Third-party models never go through the companion.** They use `codex-provider` (Inc 4), a separate runner on `codex exec --json`, as [05 §16] recommends. This avoids the companion's `clientInfo.name = "Claude Code"`, its provider-filtered `--resume-last`, and a broker env fixed at spawn [05 §14, §15.12].
- **One small fix in Inc 2:** the orchestrator's Codex `failed` rule (one `--fresh` retry, then the user) stays [00 §1.5]. Only the wrapper channels move to the errorClass ladder, so Codex's missing errorClass needs no work.

---

## 9. Delivery plan

The test pattern throughout is the existing one: an env-selected fake harness binary with mode switches and a `record` mode, plus exported constants used as the oracle [00 §5]. "Local-real" means the real harness binary run against a **loopback stub with dummy tokens**, as [01 §18] and [05 Appendix A] did. Those tests make no remote calls and need no keys, and they are opt-in (`AGENT_REAL_HARNESS=1`). "LIVE" means the user's own keys against real providers.

### Inc 0: core extraction (no behaviour change)

- **Scope:**
  - `bin/lib/dispatch-core.mjs` (≈1,150 moved lines);
  - `bin/lib/adapters/zcode.mjs` (≈480 moved);
  - `bin/lib/zcode-dispatch.mjs` reduced to ≈40 lines;
  - core error messages parameterized with the dispatcher name;
  - the `requireJob` message that names Codex [00 §2] is kept verbatim for zcode.
- **Tests:** `tests/test-zcode-dispatch.sh` unchanged, 110 PASS; `node --check` on every module; `git diff --stat` shows no change under `tests/`.
- **Size:** about 1,700 lines moved and about 120 new; 1–2 days.
- **LIVE:** the user runs `"$ZDISPATCH" doctor --probe` and one tiny `task` on the existing key, and confirms the record matches a pre-refactor record field for field.

### Inc 1: `agent-dispatch` + claude-compat, implementer role, ad hoc use

- **Scope:**
  - `bin/agent-dispatch`;
  - `bin/lib/agent-dispatch.mjs` (≈350 lines: profiles, policy, routing printout, `key`, `profile add`, `profiles check`);
  - `bin/lib/adapters/claude-compat.mjs` (≈420);
  - `agent-policy.json` and the 7 templates;
  - the post-run secret scan and `.git` hash check in the core, used by agent-dispatch only;
  - `skills/agent-invocation/SKILL.md`.
  - No orchestrator change: the user can say "dispatch this to ds-pro" and the skill recipe runs it.
- **Stub tests** (`tests/fixtures/agent-stub.cjs` with a `claude-json` dialect; `tests/test-agent-dispatch.sh`):
  - argv shape: `--setting-sources ""`, `--settings`, `--tools`, `--session-id`, stdin prompt;
  - env: no parent `ANTHROPIC_*`/`CLAUDE_*`, exactly one credential variable, `CLAUDE_CONFIG_DIR` = the profile home;
  - generated settings content;
  - policy refusals: no row, `no`, gray without `allowGray`, host mismatch, `sk-sp-` key, Anthropic host;
  - family/prefix mismatch, `busy` slots, the three kill switches;
  - every row of the §3.5 classification table, using modes `auth401`, `quota429`, `throttle429`, `model404`, `too-long`, `max-turns`, `sigint-empty`, `hang`, `malformed`, `refused-conn`;
  - redaction of a key split across stderr chunks (mode `leak`), and the post-run scan → `violation` when the stub writes the key into a file;
  - resume preconditions;
  - the start line, with the id as the last token.
- **Local-real** (real `claude` ≥ 2.1.302 + `tests/fixtures/anthropic-stub.cjs` on 127.0.0.1):
  - a repo `.claude/settings.json` redirect does **not** receive the token (E9 replay);
  - a Bash child does not see the token (E13 replay);
  - the user agent carries no `claude-desktop` (E23 replay);
  - the sandbox allows a scripted `node -e` test command with no prompt, and blocks a write outside the worktree;
  - a resume continues the session;
  - the exact deny-rule syntax and `sandbox.network` keys are confirmed.
- **Size:** ≈1,100 lines of code and JSON, ≈900 of tests, ≈170 of skill; 4–5 days.
- **LIVE (the user's keys):**
  - `key set` + `doctor --probe` for `ds-pro` (DeepSeek PAYG) and `glm-cc` (GLM Coding Plan);
  - one small `implement` job per profile in a scratch repo, checking line-1 token compliance and that the report file was written;
  - the provider dashboards show the expected billing type (Z.ai plan vs standard key [06 §1.3]);
  - a deliberately wrong key gives `auth` within a minute, not about 3 [01 §11].

### Inc 2: profile channels in the implementer ladder

- **Scope:** the routing section; the SKILL.md edits in §7.1 except C21; the `implementer-prompt.md` edits in §7.2; `glm` as a built-in row.
- **Tests:**
  - `tests/test-pipeline-context.sh` gains `agent-invocation`;
  - a text lint, `tests/test-channel-text.sh` (≈60 lines), fails on leftover hardcoded `glm=`, `.glm.md` or `$ZDISPATCH`-only status rules outside the documented built-in examples;
  - `agent-dispatch profiles` golden output for no file, a default file and the §4.2 file.
- **Size:** ≈120 lines touched across skills and ≈100 test lines; 1–2 days.
- **LIVE:**
  - one real `/dev` run on a two-phase toy plan with `implementer = ["ds-pro"]`;
  - a forced failure (wrong key) → announced fallback to Luna, `ch=ds-pro:down` marker, recovery after a manual `/compact`;
  - one run with the default routing, to confirm behaviour identical to v0.11.1.

### Inc 3: read-only reviewer kind and reviewer routing

- **Scope:**
  - core `--role reviewer` (no reservation);
  - claude-compat reviewer argv and settings;
  - the `--writer-family` gate;
  - SKILL.md C21 and the two reviewer templates.
- **Tests:**
  - stub `record` proves that no reservation is taken and that a reviewer runs while an implementer holds the tree;
  - argv contains no `Bash`, `Edit` or `Write`;
  - family refusal.
  - Local-real: a reviewer told to write a file leaves it unchanged, with a non-empty `permission_denials`; reading a git-ignored `.superpowers/sdd/…/review-*.diff` by explicit path works (R5).
- **Size:** ≈300 lines; 2 days.
- **LIVE:** one Step 4.2 control review by `kimi-k3` or `qwen-max` on a real GLM-written diff, side by side with Astra's on the same package. Check the verdict-token format and the 4.2 item fields (`authorization_relation`, `why_now`, `minimal_fix`) [00 §4.2 R4].

### Inc 4: codex-provider (T3: risk phases and OS read-only reviewers)

- **Scope:**
  - `bin/lib/adapters/codex-provider.mjs` (≈450 lines, §3.6);
  - the `__print-key` internal verb;
  - per-profile `CODEX_HOME`;
  - `routing.implementer.risk` accepts T3 profiles;
  - `agent-invocation` and `codex-invocation` notes.
- **Tests:**
  - stub dialect `codex-jsonl`: `thread.started`, `item.completed`, `turn.completed`/`turn.failed`, and the metadata `error` item on exit 0;
  - flag order with `resume`;
  - SIGINT-first cancel with a descendant sweep;
  - the [05 §11] classification table.
  - Local-real (`codex` 0.163.0 + a loopback Responses stub, dummy key): canaries for a write outside the tree, `curl`, and reading the keys dir (all must fail); `printenv` shows no key; `-s read-only` blocks a write [05 §7].
- **Size:** ≈450 lines of code and ≈600 of tests; 3–4 days.
- **LIVE:** a `glm-cx` probe and one ordinary phase; then, with the user's explicit go-ahead, one SECURITY-tagged phase in a toy repo, reviewed by Opus and Astra.

### Inc 5+ (on demand only)

- **Adapters:** OpenCode (Copilot plan, OpenCode Go native) and pi behind srt with key masking; DSH headless; an ACP client (≈400–600 lines [10 §4.7]).
- **Shared srt layer:** ≈300 lines, written once.
- **Each adapter:** ≈500–700 lines plus tests. Each must first pass the [09 §10] smoke matrix on the pinned versions, LIVE.

**MVP = Inc 0 + 1 + 2:** about 2 weeks of focused work. It delivers multi-provider implementers in the pipeline with today's defaults intact.

---

## 10. Risks and open questions

1. **Claude Code release cadence** (13 releases between 10-05 and 10-19 [01 §1]). Flags and settings keys can drift. Mitigations: a `minVersion` doctor check, a pinned-version WARN, and the local-real suite re-run on every bump.
2. **Support caveat.** Anthropic does not support Claude Code against non-Claude models [01 §14; AN6]. It is legal but unsupported. Strict upstreams may reject beta body fields, which `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` is for [01 bottom line], and the per-profile env allowlist permits it.
3. **Headless use of a listed tool on the GLM Coding Plan** is not addressed in writing either way [07 §7; 06 §7 Q1]. This is the same exposure as today's ZCode channel, and the policy row records it.
4. **Seatbelt nesting.** If the dispatcher itself runs inside a sandbox, `failIfUnavailable` makes claude exit [09 §2.5]. In practice the dispatcher already writes under `~/.claude/plugins/data`, so it already runs outside a Claude Bash sandbox (an inference, not a measurement). Doctor checks `SANDBOX_RUNTIME`, and a nested start ends as `launch` → fallback.
5. **T2 limits.**
   - Tests that bind localhost or need the network fail inside the Bash sandbox (`allowLocalBinding` stays off because of the 127.0.0.1:1082 proxy [09 §6]). The implementer reports `DONE_WITH_CONCERNS` and the Step 3.5 gate runs those tests outside.
   - Read/Edit are governed by permission rules, not the OS [09 §7.3], so T2 stays off risk phases.
6. **Separate reservations for `zcode-dispatch` and `agent-dispatch`** until the shared lock root lands (§8.1). Overlap is prevented today only by the orchestrator's single-channel-per-phase ladder and status checks, as between zcode and Codex [00 §1.7].
7. **Model quality of non-GLM implementers on this repo is unmeasured.** Independent evidence is thin and harness-dependent [06 bottom line 5], so the user should A/B before reordering routing.
8. **Data jurisdiction.** DeepSeek stores data in the PRC with no no-training promise [06 §2.2]. Codex sends the absolute workspace path and git HEAD to the provider [05 §14]. Templates state this in `note`; the choice belongs to the user (M9 [09 §9]).
9. **Open: Alibaba Token Plan status.** It is gray in [07 §5] and "not compliant" in [06 §1.2]. The policy uses `no` until reconciled.
10. **Open: credential transport.** Env plus scrub was verified end to end [01 E13]. `apiKeyHelper` keeps the key out of the process env but sends both auth headers [01 §6]. Whether every provider accepts both headers is unverified, so the decision is deferred to the Inc 1 LIVE run.
11. **Open: does `--setting-sources ""` keep honouring `sandbox` and `permissions` from `--settings`** in non-bare mode? E9, E13 and E18 cover the parts separately [01 §9, §8, §6]. The Inc 1 local-real test settles it before any LIVE run.
12. **Open: ZCode quota bonus.** It decides whether `glm-cc` should ever lead `glm` in routing. The measurement is inconclusive per `zcode-invocation` "Verified facts".
13. **Cost reporting.** `total_cost_usd` is meaningless for third-party endpoints [01 §13], so records keep tokens only. There is no budget enforcement beyond `timeoutMin`.

---

## 11. Deliberate non-goals

- **No new pipeline steps and no new roles.** There is no advisory-reviewer step and no profile-driven planner, final reviewer, gate or diagnosis. Opus and Sonnet subagents stay.
- **No migration of the OpenAI channels off the companion** in this plan (§8.2). It is possible later on the same core.
- **No translating, pooling or re-originating proxy** (LiteLLM, claude-code-router), and no local gateway for subscription plans [05 §15.1; 07 §6.8; 09 §5 C].
- **No subscription OAuth flows inside the dispatcher.** There is no Claude Pro/Max through claude-compat, no pi Anthropic/Copilot logins and no Google consumer logins [07 §5 no-go].
- **No srt, containers or ACP in the MVP.** They arrive only with the on-demand adapters that need them [09 §4; 10 §4.7].
- **No repo-level profile files and no profile edits by the orchestrator.** Configuration is the user's.
- **No automatic policy refresh from the network.** `agent-policy.json` changes only by a plugin release that cites the [07 §4] register with a new review date.
- **No structured-output contract change.** The line-1 token stays; `--json-schema` and `--output-schema` are not used [05 §12].
- **No Windows support and no per-job harness homes.** Homes are per profile; resume needs them [01 §4].
- **No local models as default, risk-phase or blocking-review channels** [08 §9].
