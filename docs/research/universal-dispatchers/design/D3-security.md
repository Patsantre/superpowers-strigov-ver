# D3: Security and compliance first

Design proposal, 2026-10-20, for superpowers-strigov-ver 0.11.1 (branch `research/universal-dispatchers`).

The design is grounded in the research corpus in `docs/research/universal-dispatchers/` (00 to 10, with their fact-check logs). A citation `[07 §5]` means report 07, section 5. Uncited statements are design decisions.

## 1. Thesis

```
Extract the ~70% generic job machinery of zcode-dispatch into one core, bin/agent-dispatch. Thin adapters (zcode, codex-exec,
claude-code, pi, opencode, dsh) describe each harness in a capability manifest. The core owns the boundary, not the prompt:
a shipped ToS table refuses no-go (plan, harness) pairs before spawn, and adapters take keys only from the plugin's own store,
never a login, so impersonating flows are unreachable. Keys reach a harness by srt mask or the harness's own custody, never
through argv, chat or tool env. Every role runs in an OS sandbox tier, and only canary-verified profiles take SECURITY/DATA_LOSS
phases (today only Codex). A refusal is exit 2 plus one line, and the orchestrator announces the next profile in the role's list.
```

## 2. Architecture overview

### 2.1 Components

| Component | File(s) | Origin |
|---|---|---|
| Core CLI and job machinery | `bin/agent-dispatch` (shim) and `bin/lib/agent-core.mjs` | Extracted from `bin/lib/zcode-dispatch.mjs`. Its CORE (~900 lines) and CORE-P (~250) parts are generic; only ZC (~470) is ZCode-specific [00 §2] |
| Policy evaluator (pure functions) | `bin/lib/policy.mjs` | New. Evaluates ToS, role, tier, family and pool. One implementation serves `channels add`, `route`, `task` and `doctor` |
| Sandbox runner | `bin/lib/sandbox-srt.mjs` and `policy/sandbox/{implementer,reviewer,risk}.json` (srt templates) | New. Follows the layered design in [09 §7] |
| Post-run audit | `bin/lib/audit.mjs` | New. Runs the L3 checks [09 §7.1] |
| Adapters | `bin/lib/adapters/{zcode,codex-exec,claude-code,pi,opencode,dsh,companion}.mjs` | `zcode` is the ZC part of today's wrapper. `companion` is routing-only (§8.2) |
| Shipped policy data | `policy/tos-policy.json` and `policy/families.json` | Built from the [07 §4–§6] matrix and the [06 §2] data terms |
| User registry and state | `~/.claude/plugins/data/superpowers-strigov-ver-agents/` (0700) | Generalizes `superpowers-strigov-ver-zcode/` |
| Compat shim | `bin/zcode-dispatch` | Calls the core with the `glm-zcode` profile. Keeps every verb, line and exit code of today |
| Codex companion | `bin/codex-dispatch` and the vendored companion | Unchanged. Luna, Sol and Astra become registry profiles with `adapter: "companion"` |

User state layout (none of it is ever inside a repo):

```
~/.claude/plugins/data/superpowers-strigov-ver-agents/
  channels.json                 0600  profiles, role lists, pools, gray consents; no secrets (refused if a key-like field appears)
  keys/<profile>                0600  one API key per profile, written only by `agent-dispatch key set <profile>` (stdin/TTY)
  tiers/<profile>.json          0600  canary results keyed by (adapter, harness version, srt version)
  homes/<profile>/              0700  harness home templates (CLAUDE_CONFIG_DIR, CODEX_HOME, PI_CODING_AGENT_DIR, XDG_*, DSH_HOME)
  state/<workspace-slug>/
    active.lock.<generation>          one write reservation per workspace, shared by every core adapter
    jobs/<id>.json, jobs/<id>.log     record and log, written by the runner outside every sandbox allowWrite path
    jobs/<id>/{srt.json, home/, tmp/, cache/, secret/}   per-job sandbox inputs; only home/sessions, tmp, cache are writable inside
```

### 2.2 Data flow

```
dev-orchestrator (SKILL.md)                                   user's own terminal (never the orchestrator)
  │ route --role R --phase-risk K [--writer-family F]         │ agent-dispatch key set <p>            (stdin / hidden TTY)
  │   → "route: <profile> adapter=… tier=… via=…"             │ agent-dispatch channels accept-gray … (TTY only)
  │ task --background --profile P --role R --phase-risk K --prompt-file F [--cwd W] [--resume-task id | --fresh]
  ▼
agent-dispatch (agent-core.mjs)
  L0 pre-spawn ── registry → policy row (ok | gray+consent | no/unknown → exit 2) → kill switch → role/tier → family
                  → pool capacity → git-tree guard → workspace reservation (write roles only) → env allowlist
                  → per-job harness home from template → key read into runner memory (never argv, never logged)
  ▼
detached runner (one per job, own process group)
  L1 OS boundary ─ sandbox=srt:    srt --settings <job>/srt.json -- <adapter argv>   real key only in srt's env [09 §2.4]
                   sandbox=native: <adapter argv + harness sandbox flags>             key via auth.command / apiKeyHelper
                   sandbox=none:   <adapter argv>                                     tier T0, implementer only
  L2 harness policy ─ adapter-written tool set, permission rules, housekeeping-traffic flags, isolated home
  ▼
harness ──HTTPS──▶ provider host  (srt proxy: strict allowlist; mask swaps sentinel → key on injectHosts only)
  ▼
L3 post-run ─ secret scan (key, base64/hex forms, sentinel) · .git/hooks + .git/config hash · protected paths · state integrity
  ▼
job record {status, errorClass, errorGroup, tier, family, audit} → status --json / result (line-1 token) → orchestrator
```

Two invariants hold everywhere. First, the policy decision and the tier decision come from the same `policy.mjs` call, both in `route`, which plans the dispatch, and in `task`, which re-checks it. A stale `route` line therefore cannot bypass a refusal. Second, nothing in the flow waits for a human. The only human steps are one-time setup verbs, which run in the user's terminal.

## 3. Harness adapter contract

### 3.1 Interface every adapter implements

This interface extends the minimum that 00 derives from the existing hooks [00 §2]. Additions are marked `+`.

```js
// bin/lib/adapters/<id>.mjs
export const manifest = { /* §3.2 */ };
export function paths(ctx)                 // harness binary, versionCmd; pinned resolution, never a workspace node_modules [09 §2.5]
export function version(ctx)               // → "1.3.0"; core compares with manifest.versionPin
export function preflight(ctx)             // → [{level: ok|WARN|FAIL, check, detail}]  (offline)
export function buildHome(ctx)             // + writes the per-profile/per-job harness home from homes/<profile>/ template
export function buildArgv(ctx)             // ctx = {role, readOnly, prompt:{path,bytes}, resume:{sessionId}|null, model, effort, job}
                                           // → {cmd, args, stdin: 'file'|'none'}   prompt never in argv unless transport==='argv'
export function buildEnv(ctx)              // → {env, secretEnv:{NAME:'<key>'}} ; env applied AFTER the core allowlist [00 §4.1 I17]
export function parseOutput(o)             // o = {stdout, stderr, exitCode, signal, record}
                                           // → {response, sessionId, usage, reportedModel, errorClass?}
export const PATTERNS                      // classifier rows (first match wins), as in zcode today [00 §1.5]
export function doctorChecks(ctx)          // + auth-path assertion (§6.5 item 4), housekeeping flags present
export function probeArgv(ctx)             // one PONG turn, no tools
export function canaryArgv(ctx, command)   // + run a shell command inside the same boundary the harness's tools get
export function resumeCompatible(rec, ctx) // same profile, same cwd, same home; else "dispatch --fresh"
export function cancelPlan(rec)            // + ordered signals + descendant sweep (§3.2 "cancel")
```

The core supplies the rest: the CLI, ids, records, reservation, reaper, boot id, the sticky terminal claim, `runCli` with timeout, redaction, `readSecretLine`, the doctor framework, the policy gate, the sandbox wrapper and the audits [00 §2].

### 3.2 Capability manifest

| Field | Values | Consumed by |
|---|---|---|
| `id`, `idPrefix`, `displayName` | `pi`, `pi`, `pi (earendil)` | ids `pi-NNNN`. A wrong prefix is refused on `--resume-task` [00 §1.6] |
| `versionPin`, `versionRule` | `"1.3.0"`, `exact\|major\|min` | doctor and task. A drift lowers the tier (§6.2) |
| `transport`, `maxPromptBytes` | `stdin\|argv\|file`, number or null | `route` skips argv profiles when the prompt is too large [00 §3 C14] |
| `output`, `finalMessage` | `json\|ndjson\|jsonl+file` | parseOutput |
| `exitZeroOnError` | list of cases | parseOutput never trusts the exit code alone |
| `resume` | `session-id\|thread\|none`, plus `boundTo:[cwd,home]` | route prints `resume=yes\|no`; replaces "GLM resume: disabled" [00 §3 C16] |
| `readOnly` | `os\|os-writes\|harness\|none` | reviewer eligibility (§6.2) |
| `nativeSandbox` | `tools-only\|bash-only\|writes-only\|none` | tier computation |
| `nestsSeatbelt` | bool | never wrapped in srt when true [09 §2.5] |
| `srt` | `required\|optional\|never` | tier computation and fail-closed start |
| `keyDelivery` | subset of `mask\|native\|env\|adapter` | credential mode validation (§6.4) |
| `structuredOutput` | `json-schema\|output-schema\|none` | optional. The line-1 token stays canonical [05 §12] |
| `cancel` | e.g. `[["SIGINT",10],["SIGTERM",5],["SIGKILL"]]`, `sweepDescendants` | `cancel`, timeout path |
| `homeEnv` | e.g. `["CLAUDE_CONFIG_DIR"]` | buildHome, env allowlist overrides |
| `housekeepingEnv` | flags that stop updates and telemetry | always applied (M7) |
| `forbiddenAuth` | login flows the adapter refuses to see | doctor (§6.5 item 4) |
| `roles` | roles this harness can serve at all | route |

Normalized error classes. The existing seven classes keep their names [00 §1.5]. Three harness classes (`network`, `rate-limit`, `context`) and three sandbox and security classes (`sandbox-start`, `sandbox-violation`, `credential-leak`) are added [01 §16, 05 §11, 09 §7.1]. Each class belongs to a group, and the orchestrator reads only the group (`job.errorGroup`):

| Group | Classes | Orchestrator action |
|---|---|---|
| `down` | `auth`, `quota`, `model-not-selected`, `sandbox-start` | Mark the profile down for the session, announce, and route the same operation FRESH to the next profile |
| `retry` | `timeout`, `launch`, `crash`, `malformed`, `network`, `rate-limit` | One `--fresh` retry on the same profile, then act as for `down` |
| `next` | `context` | No retry. Route to the next profile |
| `security` | `credential-leak`, `sandbox-violation` | Mark the profile down and ask the user exactly one question (§5.4) |

### 3.3 How each harness fits

| Capability | zcode (`zt-`) | claude-code (`cc-`) | codex-exec (`cx-`) | pi (`pi-`) | opencode v1 (`oc-`) | dsh (`dt-`) |
|---|---|---|---|---|---|---|
| Pin | verified ZCode app version | ≥2.1.302. Auto-update off [01 §9] | 0.163.0 [05] | 1.3.0 exact [03] | major 1 (1.19.x). v2.1.0 ships the same command [02 §1] | 0.2.1-rc.2 exact; prerelease only [04b §1] |
| Transport | argv, ≤204,800 B on macOS [00 §1] | stdin, 10 MB [01 §2] | stdin `-` [05 §2] | stdin from file [03 §2.2] | stdin, then closed; never one argv string [02 §2] | stdin `-` [04b §2] |
| Output | one JSON | one JSON object. `is_error:true` can come with `subtype:"success"` [01 §11] | JSONL + `-o last.txt` [05 §3] | `--mode json` NDJSON. Exits 0 on provider errors [03 §15] | `--format json`. An auto-reject exits 0 with no text [02 §7] | `--json` NDJSON [04b §3] |
| Resume | `--resume <sess>` | `--resume <id>`, same `CLAUDE_CONFIG_DIR` and cwd [01 §4] | `exec … resume <thread>`, flags before `resume` [05 §15.10] | same `--session-dir`/`--session-id`/cwd [03 §4] | `--session <id>` [02 §4] | `--session-id`, same cwd and patch [04b §16] |
| Read-only | none (yolo) | harness: `--tools "Read,Glob,Grep" --permission-mode dontAsk` [01 §7]. OS read-only only under srt | **os**: `-s read-only` blocks writes and network [05 §7] | harness: `--tools read,grep,find,ls`, which removes tools but does not enforce [03 §8] | harness: an explicit deny-all reviewer agent. `plan` is not read-only [02 §7] | os-writes: `DSH_PERMISSION_MODE=read-only` [04b §16] |
| Native sandbox | none | Bash only [01 §8] | tools-only Seatbelt, network off [05 §8] | none [03 §8] | none [02 §8] | writes-only Seatbelt [09 §3] |
| nestsSeatbelt / srt | no / optional via `-c 'ZCODE_HTTP_PROXY="$HTTPS_PROXY" …'` [09 §7.3] | yes when the Bash sandbox is on. Under srt it runs with the inner sandbox off [09 §7.3] | yes / never | no / required | no / required | yes / never in v1 |
| Key delivery | adapter (personal provider config, a file) | mask (`ANTHROPIC_AUTH_TOKEN`), or env for subscription plans | native `auth.command` | mask (`<PROVIDER>_API_KEY`, `auth.json` empty) | mask (`{env:…}` in generated config) | env (native) |
| Cancel | SIGTERM group → 5 s → SIGKILL | SIGINT → grace → SIGTERM (143) [01 §10] | SIGINT → 10 s → SIGTERM → SIGKILL, then sweep orphaned tool groups [05 §10] | SIGTERM (143) → 5–10 s → SIGKILL + sweep [03 §16.2] | snapshot descendants (detached pgids) → signals → sweep [02 §10] | snapshot, SIGINT, 7 s, SIGKILL, sweep. SIGTERM exits 0 [04b §16] |
| Structured output | none | `--json-schema` [01 §12] | `--output-schema`, backend-dependent [05 §12] | none | none | none |

Adapter-specific mandatory settings. These are code, and doctor checks them:

- **zcode.** Everything the wrapper pins today stays: `--mode yolo`, the `ENV_ALLOW` list, `ZCODE_*` home variables, and the `api-key set|clear` semantics [zcode-invocation "Flag reference"]. New: the L3 audit, and optional `sandbox: "srt"` once the live check in §9 passes.
- **claude-code** [01 §9, §16]:
  - `--setting-sources ""` and `--settings <home>/settings.json`. Without them a repo's `.claude/settings.json` `env.ANTHROPIC_BASE_URL` redirects the bearer token, even under `--bare` (E9).
  - A fresh `CLAUDE_CONFIG_DIR`, so no claude.ai login reaches a third party (E5).
  - `ANTHROPIC_AUTH_TOKEN` set and `ANTHROPIC_API_KEY=""`.
  - The env allowlist drops all inherited `CLAUDE*` and `ANTHROPIC*` variables (E23).
  - `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` and `CLAUDE_CODE_MAX_RETRIES=2`.
  - `skipWebFetchPreflight` and deny rules for WebFetch and WebSearch.
  - `--strict-mcp-config`, `--disable-slash-commands`, `disableAllHooks:true`.
  - The adapter refuses `claude*` model ids on a non-Anthropic host. DeepSeek, for example, maps `claude-opus*` to its own model [06 §1.4], which would blur the family label.
- **codex-exec** [05 §9, §16]:
  - `-c model_providers.<id>={…, auth={command="/bin/cat", args=["<job>/secret/key"]}}`. The file is written 0600 at spawn and removed at job end.
  - A permission profile marks `keys/`, `<job>/secret/`, `homes/*` and the credential stores `"none"` [09 §3, §7.3].
  - Hardening flags: `--disable plugins --disable multi_agent --disable goals -c web_search="disabled" -c analytics.enabled=false -c feedback.enabled=false -c check_for_update_on_startup=false -c shell_environment_policy.ignore_default_excludes=false -c sandbox_workspace_write.exclude_slash_tmp=true -c sandbox_workspace_write.exclude_tmpdir_env_var=true`.
  - `CODEX_HOME` is per chain. This absorbs the trust write-back and gives each chain its own `installation_id` [05 §9, §14].
  - Responses-API providers only. The chat wire API is gone [05 §15.1].
- **pi** [03 §16, 09 §7.3]:
  - `--mode json --no-approve -ne -ns -np --no-mcp`, with `PI_OFFLINE=1 PI_TELEMETRY=0 PI_SKIP_VERSION_CHECK=1` and `PI_CODING_AGENT_DIR=<job home>`.
  - `auth.json` stays empty. The provider must be the declared one.
  - `anthropic` OAuth, `github-copilot` and `openai-codex` are in `forbiddenAuth` [07 §3].
- **opencode v1** [02 §7, §9]:
  - Isolation through `XDG_*`, `OPENCODE_CONFIG`, `OPENCODE_DISABLE_PROJECT_CONFIG=1`, `OPENCODE_DISABLE_CLAUDE_CODE=1`, `OPENCODE_DISABLE_EXTERNAL_SKILLS=1`, `OPENCODE_DISABLE_DEFAULT_PLUGINS=1`, `OPENCODE_DISABLE_AUTOUPDATE`, `OPENCODE_DISABLE_MODELS_FETCH` and `OPENCODE_DISABLE_LSP_DOWNLOAD`.
  - `enabled_providers` holds only the declared provider. Inherited `GITHUB_TOKEN` is dropped [02 §6].
  - A complete explicit permission set is written and `--auto` is never passed. `auto-rejecting` on stderr classifies as `malformed`.
  - An unknown `--agent` name falls back to the default agent with only a stderr warning (`agent … not found`) [02 §2]. That warning classifies as `malformed` and the run is cancelled.
- **dsh** [04b §9, §16]:
  - `--profile headless --patch <job>/dsh.patch.yml --json -`.
  - The patch disables `session-log-deepseek`, `plugin-package-inventory-deepseek`, `session-title-llm` and `tool-web`, and pins `baseURL`. A repo `.env` could otherwise redirect the key.
  - `DSH_HOME` and `DSH_AGENTS_HOME` are isolated, and `DSH_TELEMETRY_DISABLED=1` is set.
  - `sdk-minimal` and `danger-full-access` are never used. doctor verifies the patch with `--dump-config`.
- **companion.** No spawn by the core. `route` prints the `"$DISPATCH" task --background [--write] --model … --effort …` line.

### 3.4 Which adapters to build first, and which never

Build order:

1. **zcode**: the extraction vehicle. No behaviour change.
2. **companion**: routing only.
3. **codex-exec**: the only harness whose native sandbox keeps the harness and the key outside and confines tools and network [09 §3 takeaway, §8]. It brings third-party models in without srt, which is beta and not installed [09 §2.1].
4. **claude-code**: the path most vendors document (DS2, ZA2, OR2, Kimi platform guide [07 §4, 01 §14]). It needs srt for anything above T0.
5. **pi**.
6. **opencode v1**. Both have no sandbox at all, so srt is required.
7. **dsh**: prerelease, uploads the session log by default, data in the PRC [04b, 06 §2.2]. Native implementer only. An ACP "guarded" mode comes later [04b §16, 10 §4.7].

Never build:

| Harness or path | Reason |
|---|---|
| Kimi Code CLI `kimi -p` | Headless `-p` always runs under `auto`, with no read-only mode [04 §B]. The membership is interactive-only (KI1) |
| Crush `run`, Cline CLI | Auto-approve by default [04 §B.2]. Plan use is gray [07 §5] |
| Antigravity `agy`, Gemini CLI on Google consumer OAuth | No-go (GO1–GO4) |
| Any localhost translating gateway or plan proxy (CCR, LiteLLM in front of a plan, sub2api) | No-go [07 §5, §6.8] |
| pi or OpenCode login flows (Anthropic OAuth, Copilot via pi, ChatGPT) | Keys only in v1. Anthropic and Copilot-via-pi are impersonation [07 §3] |
| `ollama launch --yes` | Auto-pulls models [08] |
| Codex `--oss` | Auto-pulls models [05 §15.9] |
| Qwen Code | Not now. Alibaba plans are no or gray (AL1, AL2). PAYG Qwen already works through claude-code, codex-exec or pi profiles |

## 4. Profiles and registry

### 4.1 Files and format

- **User registry.** `~/.claude/plugins/data/superpowers-strigov-ver-agents/channels.json`, mode 0600. JSON, because the core stays dependency-free Node, as the wrapper is today, and Node parses no TOML or YAML.
- **Shipped data.** `policy/tos-policy.json`, `policy/families.json` and `policy/sandbox/*.json`. Read-only plugin files.
- **What is never in the registry.** Keys never go in `channels.json`. The core refuses to load a registry with a field named like `apiKey|token|secret|password`, or any value that matches the key regex of a plan.

### 4.2 Example `channels.json` (seven ToS-safe profiles)

```json
{
  "schema": 1,
  "srt": { "bin": "/opt/homebrew/bin/srt", "version": "0.0.81" },
  "registries": ["registry.npmjs.org:443", "pypi.org:443", "files.pythonhosted.org:443"],
  "pools": { "zai-coding-plan": 2, "deepseek": 2, "minimax": 2, "openai-chatgpt": 2 },
  "profiles": {
    "glm-zcode": {
      "adapter": "zcode", "plan": "zai-coding-plan", "model": "GLM-5.3-Flash", "effort": "max",
      "family": "glm", "sandbox": "none", "credential": { "store": "adapter" },
      "pool": "zai-coding-plan", "displayName": "GLM-5.3-Flash max via ZCode"
    },
    "glm-claude": {
      "adapter": "claude-code", "plan": "zai-coding-plan", "baseUrl": "https://api.z.ai/api/anthropic",
      "model": "GLM-5.3-Flash", "effort": "max", "family": "glm", "sandbox": "srt",
      "credential": { "store": "file", "mode": "env" }, "pool": "zai-coding-plan",
      "displayName": "GLM-5.3-Flash max via Claude Code"
    },
    "deepseek-codex": {
      "adapter": "codex-exec", "plan": "deepseek-payg", "baseUrl": "https://api.deepseek.com",
      "model": "deepseek-v4-pro", "effort": "high", "family": "deepseek", "sandbox": "native",
      "credential": { "store": "file", "mode": "native" }, "pool": "deepseek",
      "displayName": "DeepSeek V4 Pro via Codex exec"
    },
    "minimax-pi": {
      "adapter": "pi", "plan": "minimax-payg", "provider": "minimax", "model": "MiniMax-M3.1-Flash",
      "effort": "high", "family": "minimax", "sandbox": "srt",
      "credential": { "store": "keychain", "service": "superpowers-agents", "account": "minimax-pi", "mode": "mask" },
      "pool": "minimax", "displayName": "MiniMax M3.1 Flash via pi"
    },
    "luna":  { "adapter": "companion", "plan": "chatgpt", "model": "gpt-6-luna",  "effort": "max",   "write": true,  "family": "openai", "pool": "openai-chatgpt" },
    "sol":   { "adapter": "companion", "plan": "chatgpt", "model": "gpt-6.1-sol", "effort": "xhigh", "write": true,  "family": "openai", "pool": "openai-chatgpt" },
    "astra": { "adapter": "companion", "plan": "chatgpt", "model": "gpt-6-astra", "effort": "xhigh", "write": false, "family": "openai" }
  },
  "roles": {
    "implementer":            ["glm-zcode", "glm-claude", "deepseek-codex", "luna"],
    "implementer.risk":       ["sol"],
    "implementer.escalation": ["sol"],
    "plan-reviewer":          ["astra@xhigh"],
    "control-reviewer":       ["astra@high", "minimax-pi"],
    "final-review-fallback":  ["astra@xhigh"]
  },
  "acceptGray": {}
}
```

Why each profile is ToS-safe:

| Profile | Reason |
|---|---|
| `glm-zcode` and `glm-claude` | The GLM Coding Plan in tools Z.ai lists (ZA2) |
| `deepseek-codex` | PAYG, with DeepSeek's own Codex page (DS2) |
| `minimax-pi` | PAYG (MM1 recommends pay-as-you-go for production use; PI6) |
| `luna`, `sol`, `astra` | A ChatGPT plan in Codex (OA3, OA5) [07 §5] |

Notes on the example:

- **Shared pool.** `glm-zcode` and `glm-claude` share the `zai-coding-plan` pool. The plan's concurrency limit then holds across harnesses (ZA1 tiers; "GLM concurrency: 2" today) [07 §6.5].
- **Effort override.** `astra@high` overrides effort per role, so one profile serves both the xhigh and the high Astra rows of today's model split.
- **Starting state.** The migration (§8) writes this file with only `glm-zcode` and the companion profiles, which reproduces today's ladder exactly. The other three profiles are what the user adds.

### 4.3 Shipped `policy/tos-policy.json` (excerpt)

```json
{
  "schema": 1, "reviewed": "2026-10-20", "reviewDueDays": 90, "default": "no",
  "plans": {
    "zai-coding-plan": { "class": "subscription", "provider": "zai", "hosts": ["api.z.ai"], "allowMask": false },
    "zai-standard":    { "class": "payg", "provider": "zai", "hosts": ["api.z.ai"], "allowMask": true },
    "deepseek-payg":   { "class": "payg", "provider": "deepseek", "hosts": ["api.deepseek.com"], "allowMask": true },
    "kimi-platform":   { "class": "payg", "provider": "moonshot", "hosts": ["api.moonshot.ai"], "allowMask": true },
    "kimi-code":       { "class": "subscription", "provider": "moonshot", "hosts": ["api.kimi.ai"], "allowMask": false },
    "minimax-payg":    { "class": "payg", "provider": "minimax", "hosts": ["api.minimax.io"], "allowMask": true },
    "minimax-mplan":   { "class": "subscription", "provider": "minimax", "hosts": ["api.minimax.io"], "allowMask": false },
    "alibaba-payg":    { "class": "payg", "provider": "alibaba", "hosts": ["*.maas.aliyuncs.com", "dashscope-intl.aliyuncs.com"], "keyPattern": "^sk-(?!sp-)", "allowMask": true },
    "alibaba-coding":  { "class": "subscription", "provider": "alibaba", "hosts": ["coding-intl.dashscope.aliyuncs.com"], "keyPattern": "^sk-sp-" },
    "alibaba-token":   { "class": "subscription", "provider": "alibaba", "hosts": ["token-plan.ap-southeast-1.maas.aliyuncs.com"] },
    "openrouter-payg": { "class": "payg", "provider": "openrouter", "hosts": ["openrouter.ai"], "allowMask": true },
    "chatgpt":         { "class": "subscription", "provider": "openai", "auth": "harness-login" },
    "anthropic-max":   { "class": "subscription", "provider": "anthropic", "auth": "harness-login" },
    "local":           { "class": "local", "hosts": ["127.0.0.1", "localhost"], "credential": "none" }
  },
  "providers": {
    "zai": { "dataUse": "no-store" }, "alibaba": { "dataUse": "no-train" }, "openai": { "dataUse": "status-quo" },
    "deepseek": { "dataUse": "no-promise", "jurisdiction": "PRC" }, "moonshot": { "dataUse": "may-use" },
    "minimax": { "dataUse": "may-use" }, "openrouter": { "dataUse": "per-account-zdr" }
  },
  "rows": [
    { "plan": "zai-coding-plan", "harness": ["zcode", "claude-code", "codex-exec", "opencode", "pi"], "mode": "headless", "status": "ok", "evidence": ["ZA2", "ZA3"] },
    { "plan": "zai-coding-plan", "harness": ["dsh", "qwen-code", "kimi-cli", "gemini-cli", "sdk"], "status": "no", "evidence": ["ZA1", "ZA2", "ZA3"] },
    { "planClass": "payg", "harness": "*", "mode": "headless", "status": "ok", "evidence": ["AN1", "OA4", "DS1", "OR1", "GO2", "MM1"] },
    { "planClass": "local", "harness": ["claude-code", "codex-exec", "opencode", "pi"], "status": "ok", "evidence": ["OL1"] },
    { "plan": "kimi-code", "harness": "*", "status": "gray", "evidence": ["KI1", "KI3"] },
    { "plan": "minimax-mplan", "harness": "*", "status": "gray", "evidence": ["MM1"] },
    { "plan": "alibaba-coding", "harness": "*", "status": "no", "evidence": ["AL1"] },
    { "plan": "alibaba-token", "harness": "*", "status": "no", "evidence": ["AL2"], "note": "06 §1.2 says not compliant; 07 §5 says gray. Held at no." },
    { "plan": "chatgpt", "harness": ["companion"], "status": "ok", "evidence": ["OA3", "OA5"] },
    { "plan": "anthropic-max", "harness": "*", "status": "no", "evidence": ["AN1", "AN7", "AN8"] }
  ]
}
```

The file stores each evidence row's text by id; it is copied from the 07 evidence register at build time. The core prints that text in refusals and in `accept-gray`, which is how 07 §5 says gray pairs should be shown ("with the quote shown at setup"). `dataUse` comes from 06 §2. Only `no-store` and `no-train` providers, plus the status-quo OpenAI path, can reach the risk tier (M9, §6.2).

### 4.4 How credentials are referenced

| `credential.store` | Where the key lives | Who writes it | Justification for clear text at rest |
|---|---|---|---|
| `file` (default) | `keys/<profile>`, 0600, in a 0700 dir under the plugin data root | the user, via `agent-dispatch key set <profile>` (stdin or hidden TTY prompt; refuses argv, empty or multi-word input) [00 §2 `readSecretLine`] | The harness must receive the raw key. Every srt tier and every Codex permission profile denies reads of `keys/`. Pattern D is hygiene, not isolation, and that is why it is paired with B or F [09 §5] |
| `keychain` | macOS Keychain item `service/account` | the user, via `security add-generic-password` or `key set --keychain` | Good at rest. The wrapper reads it outside the sandbox. Readability inside srt is [unverified], so it counts as a key store for canary 7 [09 §2.5, §10.7] |
| `adapter` | Harness-owned. ZCode personal provider config; the companion's own Codex login | the adapter's own `key set` (zcode: the existing `api-key set`) or the harness login done by the user | ZCode cannot take the key any other way. The CLI reads only that file [09 §8] |

`credential.mode` must be one of the adapter's `keyDelivery` values:

- `mask`: srt sentinel. Allowed only when the plan has `allowMask: true`.
- `native`: `auth.command` (Codex) or `apiKeyHelper` (Claude, native mode).
- `env`: the key is visible inside the sandbox. Tier T1 at most.
- `adapter`.

### 4.5 Creating and checking a profile

```bash
# 1. Declare (non-secret; the user runs it, or the orchestrator runs it when the user asked in chat)
agent-dispatch channels add deepseek-codex --adapter codex-exec --plan deepseek-payg \
  --base-url https://api.deepseek.com --model deepseek-v4-pro --effort high --roles implementer
#   → validates policy row, host binding, family derivation, adapter roles; writes channels.json; prints step 2

# 2. Store the key: user only, in the user's own terminal
! pbpaste | agent-dispatch key set deepseek-codex        # or: agent-dispatch key set deepseek-codex  (hidden prompt)

# 3. Check
agent-dispatch doctor --profile deepseek-codex                  # offline
agent-dispatch doctor --profile deepseek-codex --probe          # one PONG turn
agent-dispatch doctor --profile deepseek-codex --probe-sandbox  # canaries (§6.2); caches tiers/deepseek-codex.json
agent-dispatch channels list                                    # profile | adapter | plan | policy | family | tier | key | roles
```

Example offline doctor output:

```
ok   adapter: codex-exec 0.163.0 (pin 0.163.0)
ok   policy: deepseek-payg × codex-exec = ok (DS1, DS2; reviewed 2026-10-20)
ok   family: deepseek-v4-pro → deepseek (declared deepseek)
ok   host: api.deepseek.com ∈ plan hosts
ok   key: stored (keys/deepseek-codex, 0600)
ok   sandbox: native (workspace-write, network off, key store deny-read)
WARN tier: implementer (risk tier needs dataUse no-store|no-train; deepseek = no-promise)
WARN data: requests carry the absolute workspace path and git HEAD [05 §14]
doctor: ok
```

Gray pairs need a one-time consent: `agent-dispatch channels accept-gray minimax-mplan/pi`. It refuses unless stdin is a TTY. It prints the evidence text and requires the user to type the plan id, then writes `acceptGray["minimax-mplan/pi"] = ["MM1"]`. `revoke-gray` reverses it.

## 5. Roles and routing

### 5.1 Which roles may use profiles

| Role | Pipeline step | Minimum tier | Other constraints |
|---|---|---|---|
| `implementer` | Step 3, 3.5 gate-fix, 4 fix, 5 fix wave, integration repair (non-frontend) | T0 | family ≠ `anthropic` (Opus reviews in 4.1) |
| `implementer.risk` | phases with non-empty `risk_phases` | T2 | family ≠ `anthropic`. Provider `dataUse` ∈ {no-store, no-train, status-quo} |
| `implementer.escalation` | BLOCKED + "needs more reasoning", gate diagnosis `CODE`, round-3 BLOCKING | T1 (T2 if the phase is risk-marked) | as `implementer` |
| `plan-reviewer` | Step 2 | T1 with OS read-only (`reviewer` variant) | family ≠ `anthropic` (Opus wrote the plan), hard |
| `control-reviewer` | Step 4.2 | T1, OS read-only | family ∉ writer families, preferred (§5.3) |
| `final-review-fallback` | Step 5, when Opus is unavailable | T1, OS read-only | announced, as today |

These roles never use profiles:

- the orchestrator main thread;
- the Opus plan writer and reviser, the Opus 4.1 primary reviewer, Step 5 and the Opus diagnosis;
- the Sonnet gate, synthesis, quickfix and integration check;
- the Claude frontend implementer.

They are Claude subagents, and the gate must run the build on the host [SKILL.md:144-166]. Local-model profiles (`class: local`) are refused in every reviewer role and in `implementer.risk` [08 §9]. The example registry does not enable them [08 bottom line].

### 5.2 Picking a profile: `route`

The ladder moves from prose into code. The orchestrator asks:

```bash
"$AGENT" route --role implementer --phase-risk none --prompt-file "$f" --exclude glm-zcode
route: glm-claude adapter=claude-code family=glm tier=implementer via=agent-dispatch resume=yes preamble=headless-sandboxed probe=needed
skip: glm-zcode (excluded: down this session)
```

`route` walks the role list in order. The first profile that passes every check below wins:

- not disabled (`SP_DISABLE_CHANNELS`, `--exclude` from the session marker);
- policy `ok`, or `gray` with consent;
- version pin met;
- tier ≥ the role's minimum;
- the family constraint;
- pool capacity;
- the prompt fits the transport;
- the key is present.

With no winner it prints `route: none` and one `skip:` line per profile, and exits 1. `via=` names the dispatcher. For companion profiles it is `codex-dispatch`, and `args=` carries `--model/--effort/--write` from the registry.

### 5.3 Family rule by model family

- **Derivation.** A profile's family is derived from its model id by `policy/families.json`, by prefix: `GLM-`/`glm-` → `glm`, `deepseek` → `deepseek`, `kimi`/`moonshot` → `kimi`, `MiniMax` → `minimax`, `qwen` → `qwen`, `gpt-` → `openai`, `claude`/`anthropic/` → `anthropic`. A declared `family` that differs is refused. The rule follows the model's creator, not the host or harness [06 §6, 03 §16.4, 05 §16].
- **Writer families.** Each implementer sidecar records `<profile>:<id> family=<f>`. The writer families of a phase are the union over its sidecars. A phase written by GLM and then escalated to Sol has `{glm, openai}`.
- **Reviewer tasks.** A reviewer task carries `--writer-family glm,openai`. The core refuses a reviewer whose family is in that set, unless `--same-family-ok` is passed.
- **Same-family exceptions.** The orchestrator passes `--same-family-ok` only for the two same-family cases the skill already allows, both announced: Astra control review of Codex-written code, and the Step 5 Astra fallback [SKILL.md:178].
- **Hard rules.** `route` never offers an `anthropic`-family implementer, and never an `anthropic` plan reviewer.

### 5.4 Fallbacks and failure handling

- **Refusals.** Exit 2 always prints one line: `agent-dispatch: refused <code>: <detail> (hint: <next step>)`. The codes are `policy-no`, `policy-gray`, `disabled`, `tier`, `family`, `pool`, `version`, `key-missing`, `transport-size`, `sandbox-start`, `reserved`, `stale` and `usage`.
  - `reserved` and `stale` follow the existing stale-reservation procedure (strings now prefixed with `agent-dispatch:`) [00 §3 C13].
  - `usage` means: fix the dispatch.
  - Every other code means: route again with that profile excluded, and announce it.
- **Job failures.** The table in §3.2 applies by `errorGroup` to every core profile. Companion jobs keep the `codex-invocation` terminal rule.
- **Exhausted list.**
  - `implementer`: the last entry is `luna`, which is today's fallback.
  - `implementer.risk`: exactly one `AskUserQuestion`, with the options *wait for <first risk profile> / stop the plan here*. A risk phase is never moved to a lower tier.
  - Reviewer roles: today's announced Opus-only or Astra paths apply.
- **Security events** (`credential-leak`, `sandbox-violation`). These are the only job failures that ask the user. The orchestrator asks one question:
  - *rotate the key yourself, restore the job's files to BASE, re-dispatch on <next profile>*;
  - *keep the files and stop*.

  The record names the affected paths, never the key.

### 5.5 Kill switch

- **Permanent.** `SP_DISABLE_CHANNELS="glm-zcode,family:deepseek,plan:minimax-mplan,harness:pi"`. Tokens can be a profile, `family:`, `plan:`, `harness:` or `third-party`. `task` refuses (code `disabled`), and `route` skips the profile.
- **Legacy.** `SP_IMPLEMENTER=luna` is kept as an alias for disabling every non-companion implementer profile [00 §3 C6].
- **Session.** The user says "без <profile>", "без GLM" or "через Luna". The orchestrator writes `<profile> off <reason> <time>` lines to the session marker.
- **Policy-level.** A plugin update that flips a row to `no` disables that pair everywhere with no code change [07 §6.6].

### 5.6 Concurrency

| Limit | Value | Enforced by |
|---|---|---|
| Write width | 2 write tasks in total, as today | the orchestrator, from `"$AGENT" status` and `"$DISPATCH" status`, two calls instead of one per dispatcher [00 §3 C19] |
| Workspace | one write task per workspace across all core adapters | the core reservation. Read-only reviewer tasks take no reservation (R2) [00 §4.2] |
| Pools | `pools[<name>]`; defaults from plan guidance (Z.ai Lite 1, Pro 1–2, Max 2+; Kimi Tier0 1 [06 §2]; local servers 1 [08 §10]) | the core counts running jobs per pool across workspaces, and refuses with `pool` |

## 6. Security and compliance

### 6.1 What is protected

The threat model follows [09 §1]. The protected assets are:

- files outside the worktree;
- credential stores;
- the channel's own key;
- network egress;
- `.git/hooks` and `.git/config`, which the orchestrator's later unsandboxed `git commit` would run.

Repo content that runs later (package scripts, tests) cannot be sandboxed. Diff review stays the gate.

### 6.2 Sandbox tiers

| Tier | Definition | Who can reach it |
|---|---|---|
| **T0 unconfined** | no OS write allowlist, or writes-only confinement without read and egress control | zcode `sandbox: none` (status quo), dsh native, claude-code native (its Read/Edit tools are not OS-confined [01 §8]) |
| **T1 confined** | OS write allowlist with protected paths (M1); OS read-deny of credential stores, `keys/`, other profiles' homes and the plugin state root (M2); strict egress allowlist with provider hosts, plus registries for implementers only (M3); fail-closed start, no nesting (M5); deterministic tool set (M7). The key may be visible to the job | srt default tier (any `srt`-capable adapter); Codex native (`workspace-write` / `read-only` + permission profile) |
| **T2 risk** | All of M1–M8 [09 §9]: srt strict tier (`denyRead ["~/"]` plus allow-list) or Codex native; key not readable in the sandbox (`mask` or harness-outside, M4); canaries passed for the pinned harness and srt versions (M6); plus M9 = policy `ok` and provider `dataUse` ∈ {no-store, no-train} | codex-exec with a qualifying provider; claude-code, pi or opencode under srt with `mask` on a PAYG plan after canaries; companion `sol` (built-in, status quo) |

Reviewer variant: any T1 or T2 sandbox whose `allowWrite` holds only `<job>/home/sessions` and `<job>/tmp`. This makes the repository OS read-only and closes the R1 gap [09 bottom line 7, 00 §4.2]. For Codex it is `-s read-only`. Harness-only read-only (claude-code `--tools`, pi `--tools`, OpenCode deny-all agent) runs inside the srt reviewer variant, never instead of it.

| Adapter | implementer | reviewer (OS read-only) | risk |
|---|---|---|---|
| zcode | T0 today. T1 with `sandbox: srt` after the live proxy check [09 §7.3: ZCODE_HTTP_PROXY userinfo unverified] | only under srt | **never**: the key sits in a file that is readable in-sandbox on macOS [09 §8] |
| claude-code | T1 under srt (env key, subscription plans). T2 under srt strict + mask (PAYG). Native = T0 | srt reviewer + `--tools "Read,Glob,Grep" --permission-mode dontAsk` | srt strict + mask + PAYG + canaries + dataUse |
| codex-exec | T1/T2 native | native `-s read-only` | native + permission-profile deny + canaries + dataUse |
| pi | T1/T2 under srt (required) | srt reviewer + `--tools read,grep,find,ls` | srt strict + mask + canaries + dataUse |
| opencode v1 | T1/T2 under srt (required) | srt reviewer + deny-all reviewer agent | same as pi |
| dsh | T0 native (`workspace-write`) | not offered: reads and egress are unconfined [09 §3] | never in v1 (PRC, no no-training promise [06 §2.2]; srt nesting unresolved) |
| companion | Luna: Codex workspace-write (status quo) | Astra: no `--write` | `sol`: built-in T2, today's Sol path [09 §8] |

How a tier is earned:

- `doctor --probe-sandbox --profile P` runs the canaries of [09 §7.4] inside the profile's exact boundary. For srt that is `srt --settings <job>/srt.json -- sh -c …`. For Codex it is `codex sandbox -P <profile> -- sh -c …` [09 §3]. The canaries are:
  - write `~/canary`;
  - read a planted `~/.ssh` canary;
  - read `keys/<other>`;
  - `curl https://example.com`;
  - `curl -x http://127.0.0.1:1082 …`;
  - append to `.git/hooks/pre-commit`;
  - `printenv <KEY>` must print the sentinel.
- One real PONG then proves the provider accepts the swapped key. The result is cached in `tiers/<P>.json` with the adapter, harness and srt versions.
- After a version drift, `route` reports the profile at T1. That is a capability report, not a stop: the risk role simply falls to `sol`.

### 6.3 Generated srt settings: the reviewer variant for `minimax-pi`

The settings follow [09 §7.3]. The file is written 0600 to `<job>/srt.json`, outside every `allowWrite` path.

```json
{
  "network": {
    "allowedDomains": ["api.minimax.io:443"], "strictAllowlist": true, "allowLocalBinding": false,
    "allowAllUnixSockets": false, "tlsTerminate": {},
    "deniedResolvedAddresses": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "fc00::/7"]
  },
  "filesystem": {
    "denyRead": ["~/"],
    "allowRead": ["<WORKTREE>", "<GIT_COMMON_DIR>", "<JOB>/home", "<JOB>/tmp", "~/.nvm", "~/.cargo", "~/.bun", "~/go"],
    "allowWrite": ["<JOB>/home/sessions", "<JOB>/tmp"],
    "denyWrite": ["<JOB>/home/config"]
  },
  "credentials": { "envVars": [{ "name": "MINIMAX_API_KEY", "mode": "mask", "injectHosts": ["api.minimax.io"] }] },
  "allowAppleEvents": false, "enableWeakerNetworkIsolation": false, "allowPty": false
}
```

Fail-closed preflight, applied before every srt job [09 §2.5, §6, §7.4]:

- refuse with `sandbox-start` when `SANDBOX_RUNTIME=1` is already set;
- refuse when srt is not the pinned version or resolves inside a workspace;
- refuse when `allowLocalBinding` would be true;
- refuse when the settings path is under `allowWrite`;
- refuse when `srt --settings <job>/srt.json -- /usr/bin/true` fails;
- spawn srt without `HTTP(S)_PROXY`/`ALL_PROXY`, so the :1082 TUN proxy is never chained;
- classify cancel and timeout from the record, never from srt's exit code (0 on SIGTERM).

### 6.4 Key custody

- **In.** Keys enter only through `key set`, from stdin or a hidden TTY. They are never argv or chat, and never a variable the orchestrator sets [00 §4.1 I16]. The orchestrator never runs `key set`.
- **At rest.** `keys/<profile>` (0600) or the Keychain. The ZCode file is the exception, because the CLI reads only that file.
- **In flight to the harness.**
  - `mask`: the real key is only in srt's environment. The child sees `fake_value_<uuid>` [09 §2.4].
  - `native`: Codex `auth.command` reads `<job>/secret/key`, which the tool sandbox cannot read [09 §5 F].
  - `env`: allowed for T0/T1 only, and only where the plan forbids or leaves unclear a local header swap (`allowMask:false`) [09 §5 B note].
  - There is no `print-key` verb. If one existed, any T0 job could ask the wrapper for every key.
- **Out.** Redaction of the key in logs, records and output stays [00 §2 keyRedactor]. The L3 secret scan (§6.6) catches reflected keys [09 §2.4].
- **Inherited env.** The core allowlist drops every `*_API_KEY`, `*_TOKEN`, `ANTHROPIC_*`, `OPENAI_*`, `CLAUDE*`, `GITHUB_TOKEN` and `CODEX_*` variable from the parent. The adapter's own variables are applied after the filter [00 §4.1 I17, 01 §6, 02 §6].

### 6.5 ToS gating: how a no-go pair is prevented

1. **Default deny.** An unknown (plan, harness, headless) triple evaluates to `no` [07 §6.1].
2. **`no` rows are unconditional.** No flag, environment variable or registry field overrides them. The refusal prints the evidence ids and text.
3. **`gray` needs a one-time TTY consent** (§4.5). It is not a per-run prompt.
4. **Login paths are closed by construction.** Adapters take keys only from the core store. They never run `login`, `auth login`, `/login` or `setup-token`, and they start from fresh homes with no saved login. doctor asserts API-key auth:
   - claude-code: `claude auth status --json` must report `authMethod` ∈ {`oauth_token` (how `ANTHROPIC_AUTH_TOKEN` is reported), `api_key_helper`}, never a claude.ai login [01 §6, §16];
   - pi: `pi auth check` must not report `oauth` [03 §16.2];
   - OpenCode: `enabled_providers` holds only the declared provider [02 §5].

   Claude Pro/Max in third-party harnesses, pi's Anthropic and Copilot logins, and Google consumer OAuth are therefore unreachable even by editing `channels.json` [07 §5 no-go].
5. **Endpoint binding.** `baseUrl`'s host must be in the plan's `hosts`. Loopback is allowed only for `class: local`, and such a profile may carry no credential [08 §10]. A local reverse proxy or a protocol-translating gateway therefore cannot stand in for a subscription [07 §6.8].
6. **Key-type binding.** `keyPattern` is checked at `key set` (Alibaba `sk-sp-` vs `sk-` [06 §1.3]). Z.ai Standard and Coding Plan keys cannot be told apart by shape [06 §1.3], so the declared plan is the user's attestation, and doctor shows it.
7. **Truthful identity.** No adapter sets `User-Agent`, `originator`, `x-app` or client ids [07 §6.3]. An inherited `CLAUDE_CODE_ENTRYPOINT` is dropped [01 §6 E23]. Third-party providers never go through the companion, whose `clientInfo.name` would read "Claude Code" [05 §14].
8. **Staleness.** doctor prints a WARN once a row is older than `reviewDueDays`. It never blocks [07 §6.7].

### 6.6 L3 post-run audit

Runs in the runner after the harness exits, before the record turns terminal [09 §7.1 L3]:

| Check | How | On a hit |
|---|---|---|
| Secret scan | Search the job's changed files (git status snapshot before vs after), the report file, the job log and the stored response. Patterns: the real key, its base64 and hex forms, the srt sentinel | `credential-leak`. The response is replaced by `<quarantined>`, and the paths are listed |
| Git control files | sha256 of `.git/hooks/*`, `.git/config` and the worktree `.git` file, before vs after | `sandbox-violation` |
| Protected paths | changes to `.claude/`, `.mcp.json`, `.envrc`, shell rc files, `.gitmodules` | `sandbox-violation` |
| State integrity | hash of `channels.json`, `policy/*.json`, the plugin `bin/` tree and the `keys/` listing. Changes made by the core's own verbs bump a generation counter, so they do not count | `sandbox-violation` (`state-tamper`). This mainly protects against T0 jobs |

### 6.7 Enforced by code versus asked by instructions

| Control | Code / OS | Instructions |
|---|---|---|
| No-go, gray and unknown pairs | `policy.mjs` in `channels add`, `route`, `task` and `doctor` | — |
| Impersonating logins, OAuth leakage | adapters, env allowlist, doctor auth check | — |
| Key out of argv, chat and logs | `key set` stdin-only, redaction, L3 scan | "never ask for a key in chat" |
| Key unreadable by tools | OS: srt mask and denyRead, Codex harness-outside (T2 only) | T0 preamble asks the model not to touch credentials (not a control [09 bottom line 5]) |
| Writes outside the worktree, egress | OS at T1/T2 | T0 preamble only |
| Reviewer read-only | OS at T1/T2 reviewer variant | — |
| Risk phase on T2 only | `--phase-risk` is a required flag, and the tier check refuses | the value is copied from `risk_phases` |
| Family rule | core check against `--writer-family` | the families come from the phase's sidecars |
| Profile choice and order | `route` | "dispatch exactly the line `route` printed" |
| Registry, keys and policy left alone | TTY-only `key set` and `accept-gray`; L3 state-integrity hash | Red Flag: never edit `channels.json`, `keys/` or `policy/` |
| No direct harness calls (`claude -p`, `pi`, `opencode run`, `codex exec`, `dsh`) | — | Red Flag (generalizes "never `zcode -p`" [00 §3 C22]) |
| Deferred execution of repo content | — | diff review, as today [09 §1] |

### 6.8 Why it stays low-ceremony

- No receipts, hash bindings, provenance gates or per-run confirmations. Gray consent and keys are one-time setup.
- Every refusal names its next step. The orchestrator re-routes and announces in one line. The canary cache describes capability. A profile without it is simply not offered for risk work, which then goes to `sol`, as today.
- Exactly two situations ask the user one question: a risk phase with no T2 profile left, and a security event. Policy staleness and version drift are WARN lines only.
- `route` takes the ladder logic out of the model's context, so the skill text gets shorter (§7.4).

## 7. Orchestrator and skill changes

### 7.1 `skills/dev-orchestrator/SKILL.md`, by anchor

| Anchor | Today | Change |
|---|---|---|
| :100 state line | `impl=<glm:zt-NNNN \| luna:task-NNNN \| sol:task-NNNN \| claude \| —> glm=<…>` | `impl=<profile>:<id> \| claude \| —` and `health=<profile>:<ok\|down\|off>[,…] \| —`, listing only the profiles touched this session [00 §3 C4] |
| :104-110 durable copies and recovery | `glm-channel` marker | `<scratchpad>/dev-orchestrator/channels`, one line per profile `<profile> <ok\|down\|off> <reason> <ISO>` [C5]. Recovery reads `SP_DISABLE_CHANNELS` and the marker. Sidecars are `<profile>:<id> family=<f>`; `task-` ids go to `$DISPATCH`, every other id goes to `$AGENT` |
| :119 Durable Progress item 4 | `status` on both dispatchers | `"$AGENT" status` and `"$DISPATCH" status` (unchanged count). The core reservation covers all third-party profiles |
| :137 malformed re-dispatch | GLM-specific line | "`--resume-task <id>` when route showed `resume=yes`, else FRESH" |
| :144-178 model split and family rule | GLM, Luna and Sol rows | Role rows point to `channels.json` role lists, with defaults shown. The family rule refers to `family` and `--writer-family` |
| :201-214 checklist items 5 and 10 | two dispatcher-specific items (≈3.3 KB) | one item 5, "Dispatch via route" [C11]: the profile line comes from `route` this turn; flags copied verbatim; `--phase-risk` from `risk_phases`; reviewers carry `--writer-family`; the dispatch file is `<name>.<seq>.<profile>.md` at the next seq; the preamble named by `route`; the admission condition holds |
| :351-357 guards and admission | "checklist items 5 and 10" | "checklist item 5" |
| :366 probe procedure (≈1.8 KB) | ZCode doctor and probe, api-key remedy | "On a profile's first use in a session, `route` prints `probe=needed`. Run `"$AGENT" doctor --profile P --probe` once and write the marker. On FAIL, mark the profile down, announce its `hint:` line, and route again" [C15] |
| :368-378 ladder and kill switch | 5 GLM-specific rungs | 1. frontend → Claude. 2. phase sticky on a later profile (highest-seq sidecar) → stay. 3. risk-marked → `route --role implementer.risk`. 4. otherwise → `route --role implementer`. The kill switch is §5.5 [C6, C7] |
| :380-391 prompt files | suffix `.glm\|.luna\|.sol`, "GLM resume: disabled" | suffix `.<profile>`; the preamble comes from `route`; `resume=no` replaces the GLM rule [C3, C16, C17] |
| :399-405, :412-416 dispatch, NEEDS_CONTEXT, BLOCKED | `$ZDISPATCH` lines | the generic `"$AGENT" task …` line. Escalation is `route --role implementer.escalation` [C8] |
| :422-437 GLM failure ladder and stale reservation (≈4.8 KB) | ZCode-only | the §3.2 errorGroup table for all core profiles, the security-event question (§5.4), and the stale-reservation steps with `agent-dispatch:` strings [C12, C13] |
| :741 reporting lines | GLM and Luna phrasing | `<displayName>` from the registry [C18] |
| :753, :775-780 Red Flags | ZCode-specific flags | generic flags: never bypass `route` or the dispatcher; never edit the registry, keys or policy; never run `key set` or `accept-gray`; never give a risk phase to a profile `route` did not print for `implementer.risk` [C22] |

`.claude-plugin/plugin.json` describes roles and the registry instead of listing models [C25].

### 7.2 Invocation skills

- **New `skills/agent-invocation/SKILL.md`** (manual-only, read with `Read`). Contents:
  - resolve `$AGENT` with the same three-step idiom;
  - `route`, `task`, the Monitor loop (unchanged `case` guard), `result` and `cancel`;
  - the refusal-code table and the errorGroup table;
  - one-time setup (`channels add`, `key set`, `doctor`, `--probe-sandbox`);
  - Never-do items.
- **`skills/zcode-invocation/SKILL.md`** shrinks to a pointer. Its verified facts move into the zcode manifest. Setup and failure details move to `docs/adapters/zcode.md`, which is read only on a zcode doctor FAIL.
- **`skills/codex-invocation/SKILL.md`** stays and gains one line: third-party models through Codex use `codex-exec` profiles, never the companion.
- **`implementer-prompt.md`** gets two preambles: `headless-unsandboxed` (today's ZCode preamble, for T0) and `headless-sandboxed` (writes outside the worktree, network and credential reads are blocked by the OS; report blocked operations as concerns). The channel-switch notice uses `displayName`.
- **Reviewer templates** (`codex-plan-reviewer-prompt.md`, `codex-control-review-prompt.md`, `final-review-prompt.md`) lose their Codex-tool assumptions and read the review package by path (R5).

### 7.3 Size

Measured on HEAD:

- `dev-orchestrator/SKILL.md` is 127.6 KB. 19 passages, ≈29.2 KB, are channel-coupled, and 86 lines mention GLM, ZCode or `zt-`.
- `zcode-invocation` is 33.2 KB.
- `codex-invocation` is 20.4 KB.

Estimates:

- The generic replacement text for SKILL.md is ≈13 KB, so the skill shrinks by ≈16 KB (≈12%).
- `agent-invocation` is ≈14 KB, replacing the 33.2 KB `zcode-invocation`.
- What the orchestrator reads per session drops from ≈181 KB to ≈146 KB.
- New text: the refusal and errorGroup tables (≈3 KB) and the security-event paragraph (≈1 KB).

## 8. Migration of the existing channels

### 8.1 GLM (zcode-dispatch)

1. **Split the wrapper.** `bin/lib/zcode-dispatch.mjs` becomes `agent-core.mjs` (CORE, CORE-P) plus `adapters/zcode.mjs` (ZC) [00 §2]. `bin/zcode-dispatch` becomes a shim. It keeps:
   - the verbs, flags and `zt-` ids;
   - the start line `ZCode Task started in the background as zt-NNNN`;
   - the `zcode-dispatch:` stderr prefix;
   - exit codes, `api-key set|clear`, `MAX_PROMPT_BYTES`, and the state root `~/.claude/plugins/data/superpowers-strigov-ver-zcode` (CLI home and personal provider config untouched; no key re-entry).

   The 110-case `tests/test-zcode-dispatch.sh` runs unchanged against the shim [00 §5].
2. **Record lookup and reservation.** The core reads `zt-` records from the legacy state dir for `status`, `result` and `cancel`. New `zt-` ids continue the counter. `task` refuses with `stale` while a legacy `active.lock.*` is unreleased.
3. **Registry.** On first run, `channels.json` is created with `glm-zcode` (`sandbox: none`, `credential.store: adapter`) and the companion profiles. The role lists equal today's ladder: `implementer: [glm-zcode, luna]`; `implementer.risk` and `implementer.escalation: [sol]`; the reviewers on `astra`.
4. **Compatibility.** `SP_IMPLEMENTER=luna` maps to "disable non-companion implementers". The skill reads an existing `glm-channel` marker once and rewrites it as a `channels` line.
5. **srt.** `sandbox: "srt"` becomes the default for `glm-zcode` only after the live check in §9 passes. Until then the status quo holds, with a doctor WARN that a T0 job can read other profiles' keys.

### 8.2 Codex (companion)

- **No change to the binary.** `bin/codex-dispatch` and the vendored companion are not changed. Luna, Sol and Astra become `adapter: "companion"` profiles. `route` prints their `$DISPATCH` lines, so the kill switch, policy row (`chatgpt × companion = ok`), family and pools apply.
- **Known gaps stay** [00 §1.7]:
  - no write lock, so "status on both" stays;
  - `result` exits 0 for failed jobs, so the orchestrator reads `status` first;
  - no errorClass, so the codex-invocation terminal rule applies.
- **Third-party models never go through the companion.** They use `codex-exec` (`cx-` ids). Reasons: the shared broker inherits the first caller's environment [05 §15.12], and its client name would misidentify the plugin [05 §14].
- **Later.** Running the ChatGPT-login channels through the core (`codex exec` with the user's own `CODEX_HOME`) is deferred. `-s workspace-write` writes trust entries into that home's `config.toml` [05 §9], which would modify the user's own Codex config. See the open questions.

## 9. Delivery plan

| # | Increment | Scope | Tests (stub harnesses) | Size (rough) |
|---|---|---|---|---|
| 1 | **Core + zcode + policy + registry + L3** | Extract the core. Add the zcode adapter, `policy.mjs`, `tos-policy.json`, `families.json`, `channels.json` creation, `key set\|clear` generalization, the refusal codes, `errorGroup` in `status --json`, and the L3 audit | `test-zcode-dispatch.sh` 110/110 via the shim. New `tests/fixtures/agent-stub.cjs` (one `emit()` per dialect; modes ok, pong, auth, quota, hang, ignore-term, crash, malformed, `leak` (key plain/base64 in a file and the response), `hooktamper`, `statetamper`). `test-agent-core.sh` ≈40 cases: reservation across adapters, kill switch tokens, pools, stdin-only keys, secret-field refusal, legacy `zt-` lookup. `test-policy.sh` ≈35 cases: every `no` row, gray with and without consent, default deny, host binding, key pattern, family derivation, `claude*` id on a non-Anthropic host | ≈1,150 lines moved, ≈700 new, ≈900 test |
| 2 | **Routing in the orchestrator** | `route` verb, companion profiles, SKILL.md edits (§7.1), `agent-invocation`, the two preambles, `plugin.json` | `test-route.sh` ≈25 cases: list order, `--exclude`, risk → T2 or `sol` only, writer-family filter and `--same-family-ok`, pool skip, argv-size skip, version drift → T1. `test-sdd-scripts.sh` unchanged | ≈250 code. SKILL.md −16 KB. New skill ≈14 KB |
| 3 | **srt runner, tiers, canaries** | `sandbox-srt.mjs`, `policy/sandbox/*.json`, fail-closed preflight, `doctor --probe-sandbox`, `tiers/` cache, zcode `sandbox: srt` opt-in | `tests/fixtures/srt-stub.cjs` validates the generated settings (`allowLocalBinding:false`, `strictAllowlist`, settings outside allowWrite, denyRead covers `keys/` and other homes, no proxy vars in srt's env) and records argv. The canary runner is tested against a stub that reports blocked or allowed. `tests/live/srt-canaries.sh` is user-run | ≈550 + ≈450 test |
| 4 | **codex-exec (`cx-`)** | provider config via `-c`, per-chain `CODEX_HOME`, `auth.command` on the job secret file, permission profile, hardening flags, cancel sweep, Codex canaries via `codex sandbox -P` | codex-jsonl dialect with the [05 §11] signatures (401, 429 rate/quota, 404 model, context, missing key, config). SIGTERM orphan → sweep. Assert the flags and that the prompt is on stdin | ≈380 + ≈280 |
| 5 | **claude-code (`cc-`)** | settings file, `--setting-sources ""`, env allowlist, mask/env modes, `auth status` doctor | claude-json dialect: `is_error` with `subtype:"success"`, SIGINT exit 0 with empty stdout, 143. E9 regression: a fixture repo whose `.claude/settings.json` sets `env.ANTHROPIC_BASE_URL` must not change the effective base URL | ≈380 + ≈300 |
| 6 | **pi (`pi-`)** | srt required, forbidden auth, empty `auth.json` | pi-ndjson dialect including exit 0 on provider error. Forbidden providers refused | ≈320 + ≈220 |
| 7 | **opencode v1 (`oc-`)** | srt required, generated permissions and reviewer agent, major-version pin | opencode-json dialect: `auto-rejecting` → malformed; `agent … not found` → malformed; exit 1 with final text after the last error → completed (recovered `context_length_exceeded` [02 fact-check log]); v2 refused | ≈400 + ≈260 |
| 8 | **dsh (`dt-`)** | native implementer only, patch generation, `--dump-config` check | dsh-ndjson dialect. SIGTERM exit 0 classified from the record. Repo `.env` warning | ≈340 + ≈220 |

Each increment is shippable on its own. 1 changes no orchestrator text. 2 reproduces today's routing exactly with the default registry. 3 to 8 add opt-in profiles.

Validation that must be done live, by the user, with their own keys and installs (I cannot run these):

- **Inc 1.** One GLM phase end to end, plus `doctor --probe` (PONG), to confirm the shim changes nothing.
- **Inc 3.**
  - Install `@anthropic-ai/sandbox-runtime@0.0.81` globally (user action).
  - Run [09 §10] items 1, 2, 6 and 7: the :1082 canary, nesting, overhead, and Keychain inside srt.
  - Run ZCode under srt: PONG through `ZCODE_HTTP_PROXY` with srt's userinfo token [09 §8 unverified]. Pass → flip the `glm-zcode` default to srt.
- **Inc 4.**
  - DeepSeek Responses PONG via codex-exec.
  - Canaries showing that `keys/` and `<job>/secret` are unreadable from Codex tools.
  - Whether a Z.ai Coding Plan key on `https://api.z.ai/api/v1` (Responses) bills the plan [05 §14 unverified].
- **Inc 5.**
  - claude-code + `https://api.z.ai/api/anthropic` with a Coding Plan key in env mode under srt with the inner sandbox off.
  - claude-code + DeepSeek PAYG with mask and `tlsTerminate`: the provider accepts the swapped key, streaming works, an SSE idle gap over 6 s survives, and the reflection test passes [09 §10.3–4].
- **Inc 6.** pi + MiniMax PAYG under srt mask: undici proxying and CA trust [09 §8 unverified for pi].
- **Inc 7.** OpenCode v1 under srt mask: Bun proxy and CA trust.
- **Inc 8.** DSH + DeepSeek: with the patch, no `dsh_session_log` upload appears in egress (watch through srt's proxy log in a one-off check).
- **All.** Whether `ps eww` inside an srt sandbox shows a same-sandbox process's environment. This decides how weak env-mode T1 really is [09 open questions]. Also the per-plan concurrency at the user's Z.ai tier.

## 10. Risks and open questions

1. **srt is a 0.0.x beta, released about weekly** [09 §2.1]. Mitigation: pin the version, record it in `tiers/`, re-run canaries on every bump, and drop to T1 on drift.
2. **Mask needs EXPERIMENTAL `tlsTerminate`, rewrites request bodies and does not scrub responses** [09 §2.4]. The L3 scan catches plain, base64 and hex forms, but not arbitrary encodings. The worst case is the provider's own key in an artifact. The scan quarantines it and the user rotates.
3. **The ZCode key cannot be masked on macOS** [09 §8]. GLM-on-ZCode stays at most T1. Can the CLI take the key from env [09 open questions]?
4. **Is an srt header swap "use outside listed tools" under subscription terms?** This is open [09 §5 B, open questions]. Subscription plans therefore use `allowMask:false` and `env` mode, which caps them at T1.
5. **Corpus conflicts, resolved conservatively:**
   - Alibaba Token Plan: 06 §1.2 says not compliant, 07 §5 says gray. Policy: `no`.
   - GLM Coding Plan in pi: 03 §16.1 says block, 07 §5 via ZA2 says ok. Policy: `ok`; 07 is the ToS authority.
   - Claude auto mode on non-Claude endpoints: "unusable" per 01 §7, "unproven" per its fact-check. Not used.
   - Local models: 09 §8 would allow risk work if the harness qualifies; 08 §9 says never. Policy follows 08.
6. **Z.ai's terms do not address headless self-use in listed tools** [07 §7]. Kill switch and policy row updates are the response path.
7. **T0 profiles can read other keys and the registry.** L3 state integrity detects tampering after the fact only. Moving `glm-zcode` to srt (Inc 3) is the real fix.
8. **The model can still edit `channels.json`** with an editing tool. That is instruction-only, plus the L3 hash for jobs. A user-level HMAC was rejected as ceremony.
9. **Implementers lose some self-testing inside srt.** No local servers (`allowLocalBinding:false`), no caches under `~`, `git add` blocked in linked worktrees [09 §2.5]. The Step 3.5 host gate covers it, but more `DONE_WITH_CONCERNS` results are likely.
10. **Codex sends the absolute workspace path, git HEAD and `installation_id` to third-party providers** [05 §14]. Per-chain homes rotate the installation id, and doctor WARNs.
11. **DSH is prerelease, uploads its session log by default and keeps data in the PRC** [04b, 06 §2.2]. Exact pin, patch verified by `--dump-config`, implementer-only.
12. **OpenCode v2 ships under the same command name** [02 §1]. The doctor major-version check refuses it.
13. **Keychain readability inside srt is unverified** [09 §2.5]. Until canary 7 passes, `keychain` and `file` stores are treated alike.
14. **The family table needs maintenance.** OpenRouter `vendor/model` ids, and models re-hosted under another vendor's name. An unknown family is refused in every reviewer role.
15. **Open: can Luna, Sol and Astra move onto the core** (`codex exec` with the user's own `CODEX_HOME`, which would give the shared reservation and errorClass) without the trust write-back touching the user's `~/.codex/config.toml` [05 §9]?
16. **Open: does the companion's "Claude Code" client name matter on OpenAI's own endpoint** [05 §14]? It is irrelevant for third parties, which never use it.

## 11. Deliberate non-goals

- No ACP broker in this design. ACP is not a security boundary [10 §4.3]. A DSH "guarded" mode may use it later [04b §16].
- No containers or VMs: the always-on VM cost on 16 GB, and per-harness images [09 §4].
- No harness login flows (OAuth, device code, `setup-token`) in any core adapter, and no reading of existing harness credential stores (`~/.codex`, `~/.zcode`, `~/.claude`, `~/.pi`, `~/.local/share/opencode`).
- No localhost credential gateway (pattern C) and no protocol translation, even for PAYG. Pattern B covers the need with less code [09 §5].
- No `print-key` or any other verb that returns a key.
- No per-dispatch approvals, receipts, signed registries or provenance checks.
- No Claude-family third-party implementer while Opus does the 4.1 review. No configurable 4.1 or Step 5 primary reviewer.
- No local models in risk or reviewer roles, and none enabled by default on this 16 GB machine [08].
- No replacement of the Codex companion engine in this design.
- No automatic ToS refresh. Re-verification is a documented maintenance task with doctor WARNs [07 §6.7].
- No Windows support, same as the wrapper today.
