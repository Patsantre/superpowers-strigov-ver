# D2: User configuration and UX first

Architecture proposal for universal dispatchers in superpowers-strigov-ver. Date: 2026-10-20. Branch: `research/universal-dispatchers`.

Citation keys:
- `[NN §x]` is `docs/research/universal-dispatchers/NN-*.md`, section x. `[NN FC]` is that report's fact-check log.
- `[SKILL:L]` is `skills/dev-orchestrator/SKILL.md`, line L.
- `[ZI:L]` is `skills/zcode-invocation/SKILL.md`, line L.
- Evidence IDs such as ZA2 and DS2 are rows of the evidence register in [07 §4].

---

## 1. Thesis

A user should be able to plug in what they already pay for with one terminal command, and see on one screen which model does which job.

The design has three parts:
- **One dispatcher.** `agent-dispatch` is the generic core already inside `zcode-dispatch.mjs` (about 70% of that file [00 §2]), plus a small adapter per harness.
- **One file the user edits.** `~/.config/superpowers-strigov-ver/profiles.toml` holds named profiles (harness + plan + model + key *reference*, never a secret) and an ordered profile list per role.
- **Shipped presets and a ToS policy table.** They make the safe choice the default, and the dispatcher refuses any plan × harness pair the policy forbids.

The orchestrator stops knowing about GLM, Luna or Sol. It asks `agent-dispatch pick <role>`, which prints one line naming the profile and the announcement, and it follows one `errorGroup` table. Every failure ends in the next profile or in one question.

---

## 2. Architecture overview

```
 USER'S TERMINAL (setup, keys)                      CLAUDE CODE SESSION (orchestrator, Rule 2 bookkeeping)
 ─────────────────────────────                      ─────────────────────────────────────────────────────
 agent-dispatch setup | add | key set | check       "$AD" pick <role> … --session F   → 1 line: profile + announce
 agent-dispatch presets | list | routes | explain   "$AD" task --profile P --background --prompt-file …  → id
            │                                        "$AD" status <id> --json | result <id> | cancel <id>
            ▼                                        "$AD" mark P down <class> --session F
 ~/.config/superpowers-strigov-ver/profiles.toml               │
   [profiles.*] + [routing]   (no secrets, 0644 ok)            │
            │                                                  ▼
            └────────► bin/lib/agent-dispatch/registry.mjs ◄── share/agent-dispatch/
                        parse · merge · validate · policy ·      defaults.toml   (today's routing)
                        families · eligibility filters · pick    presets/*.toml  (provider facts)
                                   │                             policy.json     (ToS rows)
                                   ▼                             families.json   (model id → family)
                        bin/lib/agent-dispatch/core.mjs
                        job records · reservation lock · boot-id reaper · detached runner · timeout ·
                        cancel · env allowlist · key redaction · errorClass → errorGroup · doctor/probe frame
                                   │
            ┌──────────┬───────────┼──────────────┬───────────┬──────────┬────────┐
         zcode   claude-code  codex-companion  opencode  codex-exec    pi      dsh      (adapters/*.mjs)
            │          │           │              │           │          │        │
            ▼          ▼           ▼              ▼           ▼          ▼        ▼
     harness process: detached process group, isolated per-profile home, cwd = worktree → provider endpoint

 ~/.claude/plugins/data/superpowers-strigov-ver-agent/   (0700; secrets + state, never edited by hand)
   keys/<ref>.key (0600) · homes/<profile>/ · jobs/<workspace-hash>/<id>.json · active.lock.<gen>
```

Three locations with three purposes:
- **Config** (`profiles.toml`): human-edited and shareable, and holds no secrets.
- **Secrets and state** (plugin data dir, 0700): written only by `agent-dispatch`.
- **Plugin data** (`share/agent-dispatch/`): reviewed with the code and read-only to the user.

`agent-dispatch where` prints all of these paths.

Data flow of one implementer dispatch:
1. **`pick implementer --phase Ф3 --session F [--sticky P] [--bytes N]`.**
   - It merges the defaults with the user file, then drops profiles that are disabled, down, refused by policy, ineligible for the role, busy, or too small for the prompt.
   - It runs `doctor` and `doctor --probe` on a candidate the session has not probed yet. This happens once per profile per session, and the result is written to the session file.
   - It prints `pick … profile=deepseek …` followed by `announce: …`.
2. **Dispatch.** The orchestrator writes the dispatch file `implement-Ф3-r1.004.deepseek.md` and runs `"$AD" task --profile deepseek --background --prompt-file …`. That prints a start line ending in `ct-0004`, which goes into the sidecar `implement-Ф3-r1.004.deepseek.id` as `deepseek:ct-0004`. The scheme is the existing per-operation seq [SKILL:384-389] with the profile name as the suffix.
3. **Poll.** The Monitor loop is unchanged: `"$AD" status ct-0004 --json` with `sleep 25` until `job.status` ∈ {completed, failed, cancelled} [00 §1.8].
4. **Result.** `"$AD" result ct-0004` returns the final message, and line 1 is the token [SKILL:122-142]. On failure, `job.errorGroup` selects one row of the table in §5.4.

The orchestrator reads only one-line outputs (`pick`, `routes --line`, `status`, `mark`). This keeps Rule 2 intact: only short stdout enters its context [SKILL:45-46, 00 §6.2].

---

## 3. Harness adapter contract

### 3.1 Interface

Each adapter is one ES module under `bin/lib/agent-dispatch/adapters/`. It generalizes the hooks `zcode-dispatch.mjs` already has (PROMPT_TRANSPORT, MODEL_ARGS/MODEL_ENV, REPORTED_MODEL_PATH, USAGE_FIELDS, PATTERNS, ENV_ALLOW/ENV_DENY) and follows the minimum interface in [00 §2].

```js
export const manifest = { /* §3.2, static */ };
export function paths(profile, env)            // → { bin, home, sessionDir }
export async function version(ctx)             // → { version, inRange, hint }
export async function preflight(ctx)           // offline checks; throws UsageError("…", { hint })
export function buildInvocation(ctx, { promptFile, workspaceRoot, sessionId, resume, readOnly })
                                               // → { argv, env, stdin: "file" | "none", files: [{ path, content, mode }] }
                                               //   env holds adapter-owned vars, applied AFTER the core's allowlist (00 I17)
export function parseOutput(stdout, stderrTail, exit)
                                               // → { response, sessionId, usage, reportedModel, errorClass | null, detail }
export const PATTERNS                          // [{ re, errorClass }] for stderr / provider text
export function keyDelivery(profile, keyPath)  // → files/env/flags that hand the key to the harness (§4.4)
export function doctorChecks(ctx)              // → [{ name, ok, detail, hint }]
export function probeInvocation(ctx)           // one cheap "Reply with exactly: PONG" request, no tools
export function resumeCompatible(record, profile) // same profile, same home, allowed prior status
```

The core keeps everything that is generic today [00 §2]:
- reservation lock (`active.lock.<generation>`), boot-id reaper, and sticky terminal states via link(2);
- detached group spawn with a wall-clock timeout, env allowlist and `keyRedactor`;
- `release-stale`, and the frame for `doctor` / `doctor --probe`.

Three things are new in the core:
- `--read-only` tasks take no write reservation [00 R2];
- `errorGroup` is derived from `errorClass` (§3.3);
- the L3 post-run checks (§6.1).

### 3.2 Capability manifest

Every field is something the registry or `pick` reads. Example for `claude-code`:

```js
export const manifest = {
  harness: "claude-code",
  idPrefix: "ct-",
  versionRange: ">=2.1.302 <2.2",            // doctor fails outside the range; pinned per plugin release (01 §15.15)
  promptTransport: "stdin",                  // argv | stdin | file
  maxPromptBytes: 10_000_000,                // piped stdin cap (01 §2)
  resume: { mode: "session-id", after: ["completed", "failed"], boundTo: "profile-home" },   // 01 §4
  readOnly: "tools",                         // os | native | tools | none   (reviewer eligibility)
  reviewGit: true,                           // reviewer can run read-only git (00 R6)
  sandbox: { tier: "T0", native: "bash-only", nestsSeatbelt: false, srtCompatible: true },  // 09 §8
  riskEligible: false,                       // M1–M9 met (09 §9)?
  structuredOutput: "json-schema",           // none | json-schema | output-schema (01 §12)
  finalMessage: "result-json",               // where the final text lives
  exitTraps: ["api-error-with-subtype-success", "sigint-exit0-empty-stdout"],               // 01 §15.6-7
  cancel: ["SIGINT", 5000, "SIGTERM", 5000, "SIGKILL"],
  sweepDetachedGroups: false,
  errorClasses: ["auth", "quota", "rate-limit", "model-not-selected", "context-overflow",
                 "transport", "server", "timeout", "launch", "crash", "malformed"],
  modelSelection: "flag",                    // flag | config-patch | pinned
  effort: { flag: "--effort", values: ["low", "medium", "high", "xhigh", "max"] },          // 01 §5
  keyDelivery: "apiKeyHelper",               // own-config | apiKeyHelper | auth.command | env-after-filter | harness-login | none
  identity: "truthful",                      // the adapter never sets User-Agent / originator / x-app (07 §6.3)
  confirmModel: false,                       // one per-session user confirmation needed (ZCode's "Model confirmation")
  preamble: "headless-unsandboxed",          // implementer preamble when tier is T0 (00 C17)
};
```

### 3.3 Normalized error classes and groups

The core maps every adapter's `errorClass` to a group. The orchestrator reads only the group (§5.4).

| errorClass | Meaning | Sources | errorGroup |
|---|---|---|---|
| `auth` | Key missing, rejected or revoked | ZCode `auth` [00 §1.5]; claude 401/403 [01 §11]; DSH `AUTH`, `MISSING_CREDENTIAL` [04b §11] | **down** |
| `quota` | Plan or balance exhausted | ZCode `quota`; OpenCode `insufficient_quota`, `GoUsageLimitError` [02 §11]; DSH `QUOTA` | **down** |
| `model-not-selected` | Model unknown or not pinned | ZCode; claude 404 "issue with the selected model" [01 §11]; DSH `UNKNOWN_MODEL`; Codex unknown model → keyed on `turn.failed` [05 §3] | **down** |
| `sandbox-start` | srt or the native sandbox did not start | [09 §7.1, §7.4]; DSH `SANDBOX_UNAVAILABLE` | **down** |
| `rate-limit` | 429 throttle | claude 429 (quota vs throttle known only from provider text) [01 §11]; DSH `RATE_LIMIT` | retry |
| `transport` | Connection refused, DNS, TLS | claude status null + `ECONNREFUSED` [01 §11]; DSH `TRANSPORT` | retry |
| `server` | 5xx, 529 | [01 §11]; DSH `SERVER` | retry |
| `timeout`, `launch`, `crash`, `malformed` | As in ZCode today | [00 §1.5] | retry |
| `context-overflow` | Prompt too long for the model | claude `terminal_reason: prompt_too_long` [01 §11]; DSH `CONTEXT_WINDOW_EXCEEDED` | **next** |
| (task exit 2) `prompt-too-large` | Over the transport cap | ZCode `MAX_PROMPT_BYTES` [SKILL:428] | **next** |
| `credential-leak` | Key or sentinel found in the diff, report or log | L3 scan [09 §7.1] | **stop** |
| `sandbox-violation` | A protected path changed (`.git/hooks`, `.git/config`, worktree `.git`) | L3 hash check [09 §7.1] | **stop** |

An unclassifiable 429 maps to `rate-limit`, not `quota`. A misclassified quota costs one retry, while a misclassified throttle would take the profile down for the whole session.

### 3.4 How each harness fits

| | zcode | claude-code | codex-companion | opencode (v1) | codex-exec | pi | dsh |
|---|---|---|---|---|---|---|---|
| Id prefix | `zt-` | `ct-` | `task-` | `oc-` | `cx-` | `pi-` | `dt-` |
| Prompt transport | argv, ≤200 KiB macOS / 120 KiB Linux [SKILL:428] | stdin, 10 MB cap [01 §2] | prompt file | stdin redirect only; stdin must close [02 §2, 02 FC] | stdin `-` [05 §2] | stdin, `--mode json` [03 §2] | stdin, `--json -` [04b §2] |
| Resume | session; resumes only after `completed` [00 §1.6] | `--session-id`/`--resume`, bound to the profile's `CLAUDE_CONFIG_DIR` [01 §4] | thread `--resume-task` [00 §1.6] | `run -s <id>`, same XDG env [02 §4] | `exec resume <thread>`, same `CODEX_HOME` and provider [05 §4] | `--session-id`, which silently creates on a typo, so the adapter checks the file exists [03 §4] | `--session-id` adopts; the id cannot be preassigned [04b §4] |
| Read-only (reviewer) | **none**: never a reviewer [00 R2] | tools: `--tools Read,Glob,Grep` + read-only git `Bash(...)` + `dontAsk` [01 §16] | OS: no `--write` → read-only sandbox [00 R1] | tools: agent `"*":"deny"` + read/grep/glob/list + git read patterns [02 §7] | OS: `-s read-only` [05 §2] | tools: `--tools read,grep,find,ls` (no git) [03 §16] | native: `DSH_PERMISSION_MODE=read-only` [04b §8] |
| Sandbox tier | T0 (yolo) | T0 + bash sandbox; srt-compatible [09 §8] | T2 native | T0; srt-compatible | T2 native | T0; srt-compatible | T2 writes-only; nests Seatbelt [09 §8] |
| Risk-eligible (M1–M9) | no | no (candidate after srt + canaries) | **yes** (Sol today) | no (candidate) | **yes**, provider data terms permitting (M9) [09 §8-9] | no (candidate) | after canaries |
| Key delivery | own config file 0600 [ZI:53] | `apiKeyHelper` reading a 0600 file (pattern F) [01 §16, 09 §5] | harness login (user's `codex login`) | env after filter (A); srt `mask` (B) later [09 §5] | `auth.command` `/bin/cat <0600 file>` (F) [05 §6] | env after filter (A) | env after filter + pinned baseURL [04b §6] |
| Final message / exit traps | `response` | `result` field; API errors come back as `is_error:true` with `subtype:"success"`; SIGINT gives exit 0 with empty stdout [01 §15] | companion `result`; exits 0 on a failed job [00 BL3] | last text after the last `session.error`; exit 1 even after recovery [02 FC] | `-o last.txt`; unknown model gives exit 0, so key on `turn.failed` [05 §3] | last assistant `message_end`; exit 0 on provider errors [03 §3.3] | `final` event; SIGTERM gives exit 0 [04b §3, §10] |
| Cancel | group SIGTERM | SIGINT → grace → SIGTERM to group [01 §16] | companion `cancel` | group kill + sweep detached bash groups [02 §10] | SIGINT → 10 s → SIGTERM → SIGKILL + sweep [05 §10] | group kill [03 §10] | snapshot descendants → SIGINT → 7 s → SIGKILL → kill PGIDs [04b §10] |
| Isolation | `cli-home` [00 I18] | fresh per-profile `CLAUDE_CONFIG_DIR`, `--setting-sources ""`, `--settings <file>` (blocks a repo redirect) [01 §9, §15.1] | `CLAUDE_PLUGIN_DATA` | per-profile `XDG_*` + `OPENCODE_DISABLE_*`; doctor refuses v2 [02 §1, §9] | per-profile `CODEX_HOME` (exec writes trust_level back) [05 §9] | `PI_CODING_AGENT_DIR`, `PI_OFFLINE=1`, `PI_TELEMETRY=0` [03 §9] | `DSH_HOME`, empty `DSH_AGENTS_HOME`, telemetry off, session-log upload neutralized [04b §9] |
| Plans it unlocks | Z.ai GLM Coding Plan | every Anthropic-endpoint provider: Z.ai, DeepSeek, Kimi Platform, MiniMax, Alibaba, OpenRouter, Ollama, LM Studio [01 §14, 06 §1.1] | ChatGPT login (OpenAI models) | OpenCode Go/Zen, Copilot, ChatGPT [07 §5] | any Responses endpoint: DeepSeek, Z.ai, Kimi, MiniMax, Alibaba, OpenRouter, Ollama [05 §5.3] | 40+ providers [03 §5.2]; refuses `anthropic` OAuth and `github-copilot` [07 §3] | DeepSeek only; GLM plan forbidden [07 §2] |
| Build order | **1** (migrate) | **2** | **3** (wrap) | **4** | **5** | **6** | **7** |

**Why this order.**
- **claude-code second.** Every provider the user named publishes a Claude Code setup for its Anthropic endpoint [01 §14, 06 §1.1]. One adapter therefore covers "my DeepSeek key", "my Z.ai plan", "my MiniMax key", "my Qwen key" and "my local Ollama model".
- **OpenCode next.** It is the only harness that carries the OpenCode Zen and Copilot subscriptions [07 §5].
- **codex-exec after that.** It is the only route by which a third-party model can qualify for SECURITY/DATA_LOSS phases, because the Codex sandbox does not change with the provider [09 §8].
- **pi late.** It adds breadth but little unique coverage, since every provider in scope already has an Anthropic endpoint [06 §1.1].
- **dsh last.** It is prerelease (`0.2.1-rc.2`, pinned exactly), it needs four features neutralized, and DeepSeek is already reachable [04b §1, §9].
- **ACP** stays an optional transport for later, dsh first [10 §4.7].

**Never build:**
- Kimi Code CLI or Qwen Code as plan channels. Both plans are interactive-only [06 §1.2], and Kimi `-p` has no read-only mode [04 FC].
- Gemini CLI or Antigravity on a consumer login [07 §5, GO1-GO4].
- Crush or Cline (they auto-approve), or Kilo (an OpenCode fork with no added coverage) [04 §B].
- A `claude-code` profile on the user's own claude.ai login. It is sanctioned [07 §5], but it is the same family as the Opus reviewers and duplicates the in-process `claude:*` subagents.
- Any re-originating or translating gateway (LiteLLM-style) used for subscription plans [09 §5 C, 07 §6.8].
- ACP as a security boundary [10 §4.3].

---

## 4. Profiles / registry

### 4.1 Location, layering, format

| Layer | Path | Who writes it |
|---|---|---|
| Shipped defaults | `share/agent-dispatch/defaults.toml`: built-in profiles `glm-zcode` (alias `glm`), `luna`, `sol`, `astra-high`, `astra-xhigh`, pseudo-profiles `claude:opus`, `claude:sonnet`, and a `[routing]` that reproduces v0.11.1 exactly | plugin release |
| Shipped facts | `share/agent-dispatch/presets/<preset>.toml`, `policy.json`, `families.json` | plugin release |
| User config | `~/.config/superpowers-strigov-ver/profiles.toml` (override: `SP_PROFILES_FILE`) | the user, or `add` / `route` / `enable` / `disable` |
| Secrets + state | `~/.claude/plugins/data/superpowers-strigov-ver-agent/` (0700): `keys/`, `homes/`, `jobs/`. The zcode adapter keeps its existing `…/superpowers-strigov-ver-zcode` dir [zcode-dispatch.mjs:134] | `agent-dispatch` only |

Merge rules:
- A user profile with a default's name overrides that default field by field.
- A user `[routing]` key replaces that role's default list.
- If the user file is absent, behavior is identical to today.

Format: a strict TOML subset.
- **Allowed:** `[a.b]` tables, strings, integers, booleans, string arrays and `#` comments.
- **Why TOML:** it allows comments, a non-expert can read it, and Codex users already edit TOML [05 §5].
- **Parser:** about 150 lines, no dependency. Errors carry the line number.
- **Programmatic edits** append a block or replace a single line, so user comments survive.

### 4.2 Profile fields

| Field | Filled by preset | Meaning |
|---|---|---|
| `preset` | — | Preset to inherit from. Every field below can be overridden |
| `harness` | default | `zcode`, `claude-code`, `codex-companion`, `opencode`, `codex-exec`, `pi`, `dsh` |
| `plan` | yes | Policy key, e.g. `zai-coding-plan`, `deepseek-payg`, `minimax-payg`, `minimax-mplan`, `kimi-platform-payg`, `alibaba-payg`, `opencode-go`, `local` |
| `base_url` | yes | Endpoint, chosen to match the key type [06 §1.3]. Alibaba presets ask for workspace id + region [06 §1.1] |
| `provider` | yes | Harness-native provider id where one exists (pi `minimax`, OpenCode `opencode-go`, Codex `[model_providers.<id>]`) |
| `model`, `effort` | default | Pinned per job [06 §1.4] |
| `family` | derived | Model creator from `families.json`. An unknown id fails `check` until the user sets it |
| `key` | — | `store:<ref>`, `keychain:<service>`, `file:/abs`, `harness-login`, `own-config`, `none` (§4.4) |
| `concurrency`, `quota_group` | yes | Running jobs allowed. The limit is counted across profiles sharing `quota_group` (default: the key ref; local: the base URL) |
| `timeout_min` | 60 | Wall-clock cap → `timeout` |
| `harness_env` | yes | Extra env from a per-adapter allowlist, e.g. the local-model vars [08 §10]. Never `*_BASE_URL` or key vars |
| `enabled` | `true` | `agent-dispatch disable <p>` sets `false` |
| `aliases` | — | Extra names for kill-switch phrases (`glm`, `luna`) |
| `display` | derived | Text used in announcements: "DeepSeek V4 Pro via Claude Code" |
| `accept_gray` | — | Written only by `add` after the user typed the plan id (§6.3) |

Role assignment lives only in `[routing]`, so there is one place to read. Presets carry `allowed_roles`; for example, `ollama-local` excludes risk and every review role [08 §9].

### 4.3 Example: seven ToS-safe profiles

```toml
# ~/.config/superpowers-strigov-ver/profiles.toml
# Profiles = what you plugged in. [routing] = who does which job. No secrets here, ever.

[profiles.glm-zcode]              # built-in; overridden only to match a Lite plan
concurrency = 1                   # Z.ai plan tiers allow 1–2+ concurrent requests (06 §6)
quota_group = "zai"               # one Z.ai account behind two harnesses: one shared limit

[profiles.glm-cc]                 # GLM Coding Plan in Claude Code: listed by Z.ai (ZA2, 07 §2)
preset      = "zai-coding-plan"
harness     = "claude-code"
model       = "glm-5.3"
effort      = "max"
key         = "store:zai-plan"
quota_group = "zai"

[profiles.deepseek]               # pay-as-you-go key, any harness (DS2, 07 §5)
preset  = "deepseek-api"
harness = "claude-code"
model   = "deepseek-v4-pro"
effort  = "max"
key     = "store:deepseek"

[profiles.deepseek-cx]            # same key, second harness: Codex sandbox → eligible for risk phases
preset  = "deepseek-api"
harness = "codex-exec"
model   = "deepseek-v4-pro"
effort  = "high"
key     = "store:deepseek"

[profiles.kimi-review]            # Kimi Open Platform PAYG, not the Kimi Code membership (07 §5)
preset  = "kimi-platform"
harness = "claude-code"
model   = "kimi-k3"
effort  = "max"
key     = "keychain:sp-kimi-platform"

[profiles.minimax]                # MiniMax pay-as-you-go key (the M Plan is gray, see §6.3)
preset  = "minimax-api"
harness = "pi"
model   = "MiniMax-M3"
key     = "store:minimax"

[profiles.go]                     # OpenCode Go subscription in OpenCode itself (OC1, 07 §2)
preset  = "opencode-go"
harness = "opencode"
model   = "opencode-go/<id>"      # `add` lists the ids `opencode models opencode-go` prints; family follows the id
key     = "store:opencode"

[profiles.local]                  # local model, loopback only, no key (07 §2 "Local model")
preset  = "ollama-local"
harness = "claude-code"
model   = "qwen3.5:9b"            # example tag: use the name `ollama list` prints; Qwen3.5-9B fits 16 GB (08 §7)
key     = "none"

[routing]
implementer    = ["glm-zcode", "deepseek", "luna"]       # first eligible wins; the rest are the fallbacks
risk           = ["sol", "deepseek-cx"]                  # SECURITY / DATA_LOSS: risk-eligible profiles only
escalation     = ["sol"]
plan_review    = ["astra-xhigh"]
primary_review = ["claude:opus"]
control_review = ["kimi-review", "minimax", "astra-high"]
final_review   = ["claude:opus", "astra-xhigh"]
utility        = ["claude:sonnet", "local"]
```

What `agent-dispatch show deepseek` prints is the fully resolved profile:
- harness and base URL `https://api.deepseek.com/anthropic` [06 §1.1];
- family `deepseek`, and the policy row `deepseek-payg × claude-code = ok (DS2)`;
- the data note: PRC, no no-training promise [06 §4];
- the manifest summary, key ref `deepseek` (stored, 0600), and the roles that use it.

### 4.4 Credential referencing

| `key =` | Where the secret lives | How it gets there | Use |
|---|---|---|---|
| `store:<ref>` | `keys/<ref>.key`, 0600, under the 0700 root | `agent-dispatch key set <ref>`: hidden prompt on a TTY, or stdin (`! pbpaste \| "$AD" key set deepseek`). The key is refused as an argument. Same rules as `zcode-dispatch api-key set` [ZI:42-53] | default |
| `keychain:<service>` | macOS Keychain generic password | the user runs `security add-generic-password -s sp-kimi-platform -a "$USER" -w` (it prompts). The dispatcher reads it outside the harness (pattern E) [09 §5] | users who prefer Keychain |
| `file:/abs/path` | a user-managed file | refused unless it is owned by the user and has mode 0600 or 0400 | keys already kept in files |
| `harness-login` | the harness's own login (Codex ChatGPT, OpenCode Copilot/ChatGPT) | the user logs in in their own terminal | only where a policy row says the login is ok; pi `anthropic` and `github-copilot` are always refused [07 §5] |
| `own-config` | the ZCode personal config | `key set glm` delegates to today's `api-key set` logic | zcode only |
| `none` | — | — | refused unless `base_url` is loopback [08 §10] |

There is no `env:` form and no cleartext. A value without one of these prefixes is a parse error that tells the user what to do: `keys never go in this file; run: agent-dispatch key set deepseek`. An `env:` reference would put the key in Claude Code's own environment, where the orchestrator's Bash could print it.

`key set` also writes `keys/<ref>.meta.json`, which records the declared key type and the creation date and never any part of the key. Where the provider's key format allows, it refuses a known mismatch; for example, an Alibaba `sk-sp-` Coding Plan key cannot be stored for the `alibaba-payg` preset [06 §1.3].

Delivery to the harness follows `manifest.keyDelivery` (§3.4). The core always feeds the key to the redactor [00 §2].

### 4.5 How the user creates and checks a profile

"My DeepSeek key", in a terminal:

```
$ agent-dispatch add deepseek-api
DeepSeek API · pay-as-you-go · family deepseek · data: PRC entity, no no-training promise
Harness   [claude-code]   also ok: codex-exec opencode pi dsh                ⏎
Model     [deepseek-v4-pro]   also: deepseek-flash                           ⏎
Name      [deepseek]                                                         ⏎
Key ref   [deepseek] not stored yet. Paste the key (hidden): ****************
          stored keys/deepseek.key (0600)
Use it as [1] implementer, after glm-zcode  [2] utility  [3] control_review  [4] none for now > 1
          wrote [profiles.deepseek]; routing.implementer = ["glm-zcode", "deepseek", "luna"]
Checking deepseek …
  ok   claude 2.1.3xx is in the pinned range
  ok   profile home 0700, settings 0600, setting sources isolated
  ok   auth: api_key_helper (this profile has no claude.ai login)
  ok   policy: deepseek-payg × claude-code × headless = ok (DS2, reviewed 2026-10-20)
  ok   probe: PONG from deepseek-v4-pro in 2.8 s
Done. /dev will use deepseek whenever glm-zcode is down, busy or disabled.
```

The same thing without a TTY, from Claude Code's `!` prompt, with the key copied last [ZI:48-53]:

```
! pbpaste | agent-dispatch add deepseek-api --harness claude-code --role implementer --key-stdin --yes
```

The other three cases from the request:
- **"My MiniMax plan."** `add minimax-mplan` explains that the plan is gray: MiniMax aims it at individual interactive use and recommends pay-as-you-go for heavier use [06 §1.2, 07 §5]. It offers `minimax-api` first. Enabling the plan anyway takes typing the plan id `minimax-mplan`, which writes `accept_gray = "minimax-mplan@claude-code 2026-10-20"`.
- **"My OpenCode subscription."** `add opencode-go` lists the harnesses where Go is ok (opencode, claude-code, codex-exec, pi) and the refused one, dsh (listed as problematic, OC1). It runs the doctor, which requires the OpenCode v1 line [02 §1]. It then offers the model ids from `opencode models opencode-go`, and the family follows the chosen id.
- **"My local Ollama model."** `add ollama-local` (or `setup`) finds a server on 127.0.0.1:11434, 1234 or 9931 [08 §2]. It reads `ollama ps` and the machine's memory, and on 16 GB it allows only the `utility` role and sets concurrency 1 per server [08 §9, §10].

Commands for discovery and checking:

| Command | Output |
|---|---|
| `agent-dispatch` (no args) | 5-line summary: profiles (enabled / gray-blocked / down last check), routing per role, next step |
| `agent-dispatch setup` | Guided: detects installed harnesses (`command -v claude codex opencode pi dsh`, the ZCode app) and local servers, offers matching presets, then runs `add` and `check` |
| `agent-dispatch presets [--for <role>]` | Table: preset · plan · harnesses ok / gray / no · family · price-index note [06 §4] · data note |
| `agent-dispatch list` | Profiles: name · harness · model · family · plan · roles using it · enabled |
| `agent-dispatch check <p> \| --all [--offline]` | doctor (offline) then probe (one PONG). Exit 0/1, with `hint:` lines carrying the exact remedy command [00 I23] |
| `agent-dispatch routes [--line \| --json]` | Effective routing after every filter |
| `agent-dispatch explain <role> [--writer <p>]` | Why each candidate is eligible or skipped |
| `agent-dispatch route <role> a,b,c` · `enable` / `disable <p>` · `key set` / `clear` / `list` · `where` | Edits and housekeeping. `key list` shows refs, storage and users, never values |

```
$ agent-dispatch explain risk
risk: sol → deepseek-cx
  sol          eligible   codex-companion · native OS sandbox (M1–M9)
  deepseek-cx  eligible   codex-exec · native OS sandbox · data note: PRC, no no-training promise
  deepseek     not usable here: tier T0 is below the risk bar (09 §9); add it to implementer instead
```

### 4.6 Shipped policy and family tables

```json
{
  "reviewed": "2026-10-20",
  "rows": [
    { "plan": "zai-coding-plan",     "harness": "zcode",       "status": "ok",   "evidence": ["ZA2"] },
    { "plan": "zai-coding-plan",     "harness": "claude-code", "status": "ok",   "evidence": ["ZA2"] },
    { "plan": "zai-coding-plan",     "harness": "dsh",         "status": "no",   "evidence": ["ZA1", "ZA2"], "why": "not on Z.ai's tool list" },
    { "plan": "deepseek-payg",       "harness": "*",           "status": "ok",   "evidence": ["DS2"] },
    { "plan": "minimax-mplan",       "harness": "*",           "status": "gray", "evidence": ["MM1"], "why": "aimed at interactive use; PAYG recommended" },
    { "plan": "kimi-code",           "harness": "*",           "status": "gray", "evidence": ["KI1", "KI3"] },
    { "plan": "alibaba-coding-plan", "harness": "*",           "status": "no",   "evidence": ["AL1"], "alt": "alibaba-payg" },
    { "plan": "opencode-go",         "harness": "dsh",         "status": "no",   "evidence": ["OC1"] },
    { "plan": "local",               "harness": "*",           "status": "ok",   "evidence": ["OL1"] },
    { "login": "pi:anthropic",       "status": "no", "evidence": ["PI1", "PI2"] },
    { "login": "pi:github-copilot",  "status": "no", "evidence": ["PI3"] }
  ]
}
```

Lookup rules:
- An exact (plan, harness) row beats `*`.
- **No row means `no`**: deny by default [07 §6.1].
- The mode is always `headless` for dispatch.

`families.json` holds case-insensitive id regexes that map a model id to its creator:
- `^glm` → zai; `^deepseek` → deepseek; `^kimi` → moonshot; `^minimax` → minimax; `^qwen` → qwen;
- `^gpt` → openai; `^(claude|opus|sonnet|haiku)` → anthropic; `^gemma` → google.

Aggregator prefixes (`opencode-go/`, `openrouter/<vendor>/`) are stripped first. Family is the model creator, not the host [06 §6, 00 C10].

---

## 5. Roles and routing

### 5.1 Roles

| Role | Pipeline use | Default list (= v0.11.1) | Eligibility |
|---|---|---|---|
| `implementer` | Step 3, 3.5 gate-fix, 4 fix rounds, 5 fix wave, integration repair; non-frontend phases [SKILL:154] | `["glm-zcode", "luna"]` | Write-capable. A T0 profile needs a git tree [00 I19] |
| fallback | **The tail of the `implementer` list.** It is used as a FRESH dispatch of the same operation, with the channel-switch notice [SKILL:156, 384-390] | `luna` | as implementer |
| `risk` | Phases with non-empty `risk_phases[<id>]` [SKILL:371] | `["sol"]` | `riskEligible` (M1–M9 [09 §9]): today only codex-companion and codex-exec |
| `escalation` | BLOCKED needing more reasoning, gate `CODE`, round-3 review stall [SKILL:157] | `["sol"]` | Write-capable. "Nothing above" means the escalation pick equals the current profile, which goes to the user [00 C8] |
| `plan_review` | Step 2 [SKILL:153] | `["astra-xhigh"]` | `readOnly ≠ none`; family ≠ anthropic (the plan writer) |
| `primary_review` | Step 4.1 [SKILL:160] | `["claude:opus"]` | Family ≠ the phase writer's family |
| `control_review` | Step 4.2 [SKILL:161] | `["astra-high"]` | `readOnly ≠ none`; family ≠ writer |
| `final_review` | Step 5 [SKILL:163] | `["claude:opus", "astra-xhigh"]` | Family ∉ the branch writers' families, except for the existing announced same-family fallback [SKILL:178] |
| `utility` | Quickfix, verification gate, review synthesis, integration check [SKILL:159-166] | `["claude:sonnet"]` | Any profile whose preset allows the role |

These roles are **not routable** in this proposal:
- the plan writer and reviser, and diagnosis (Claude Opus);
- the frontend implementer (Claude);
- the orchestrator.

Effort belongs to the profile, so one model at two efforts is two profiles (`astra-high`, `astra-xhigh`). The 4.1 `xhigh` escalation stays an Agent parameter [SKILL:160].

The `claude:*` pseudo-profiles are in-process Agent subagents. `pick` prints `profile=claude:opus agent=opus effort=xhigh`; no dispatcher and no dispatch file is involved.

### 5.2 Resolution: `pick`

`"$AD" pick <role> --phase <id> --session <file> [--writer <profile>] [--sticky <profile>] [--bytes <n>] [--parallel] [--exclude a,b]`

Candidates are the role's list, in order, with `--sticky` first. A candidate is skipped, with the reason recorded, when any of these applies:
1. It is disabled: `enabled=false`, `SP_DISABLE`, or a session `off`.
2. The session file marks it `down`.
3. The policy row is `no`, or `gray` without `accept_gray`.
4. Its preset's `allowed_roles` exclude the role, the role is `risk` and the profile is not `riskEligible`, or the role is a review role and the profile's `readOnly` is `none`.
5. It is the same family as `--writer`.
6. The prompt exceeds `maxPromptBytes` (`--bytes`).
7. Its `quota_group` is at its concurrency limit (`--parallel`).
8. It is unprobed and its doctor or probe fails. The probe runs inline, at most 45 s, and its result is written to the session file.

```
$ "$AD" pick implementer --phase Ф3 --session "$S" --bytes 61234
pick role=implementer profile=deepseek harness=claude-code id_prefix=ct- family=deepseek preamble=headless-unsandboxed
announce: Ф3 implementer: DeepSeek V4 Pro via Claude Code (deepseek). Skipped glm-zcode: down (quota, 14:02).

$ "$AD" pick control_review --phase Ф3 --writer deepseek --session "$S"
pick role=control_review profile=kimi-review harness=claude-code id_prefix=ct- family=moonshot read_only=tools

$ "$AD" pick risk --phase Ф4 --session "$S"
pick role=risk profile=NONE
ask: Ф4 is SECURITY and no risk-eligible profile is up (sol: down, auth; hint: run `codex login` in your terminal). Options: 1) retry sol after you log in, 2) skip Ф4 and continue with the next phase, 3) stop the plan here.
```

`NONE` always comes with exactly one `ask:` line, and the orchestrator relays it once through `AskUserQuestion`. No option on that line ever hands a risk phase to a T0 profile [00 C22].

### 5.3 Family rule

- `family` is derived from the model id (§4.6). The writer of a phase is the profile in the highest-seq sidecar [SKILL:389]; the plan writer is `anthropic`.
- Review roles skip candidates of the writer's family, and the skip is part of the announcement: `Skipped kimi-review: same family as writer`. This mechanizes the prose rule [SKILL:178].
- Two existing exceptions are kept unchanged:
  - frontend phases: Claude writes, Opus does 4.1, and Astra does the 4.2 cross-check;
  - the announced Step 5 Astra fallback [SKILL:178].
- For local models, the family is the vendor of the weights [08 §9].

### 5.4 Fallbacks and failures (one table for every profile)

| `job.errorGroup` | Orchestrator action |
|---|---|
| `down` | `"$AD" mark P down <class>`. Then `pick` again (P is now filtered out) and dispatch the **same operation** FRESH on the result, with the channel-switch notice. Relay the `announce:` line and any `hint:` line verbatim (the remedy command for the user) |
| `retry` | One `--fresh` retry on P. If the second attempt also fails: a class in the down set gets the `down` row; otherwise `pick --exclude P`, so the phase sticks to the new profile and P stays up for other phases |
| `next` | `pick --exclude P --bytes N`, with no retry and no mark. Never trim the prompt [SKILL:428] |
| `stop` | Stop the phase. Never auto-commit. Ask one question: (1) discard the job's changes, (2) keep them for inspection, (3) stop the plan |
| `cancelled` | Report and wait, as today [SKILL:426] |
| `pick` → `NONE` | Relay the `ask:` line once |

This table is the existing GLM ladder [SKILL:422-428] without the channel names. Companion jobs have no `errorClass`, so they map to `retry`, which is today's Codex rule: one `--fresh` retry, then the next profile in the list, or the user when the list is exhausted [SKILL:390]. Malformed line-1 verdicts stay under "Verdict parsing" step 3 [SKILL:137], resumed on the same profile.

### 5.5 Kill switch

| Scope | Form | Effect |
|---|---|---|
| Session | "без <name or alias>" / "without <name>" | `mark P off user`; holds until the session ends |
| Session | "через <name or alias>" / "via <name>" | `mark P pin implementer`. P comes first for implementer, and for risk too **if** it is `riskEligible`; otherwise risk keeps its list, announced |
| Environment | `SP_DISABLE=glm-zcode,deepseek` | The core's `task` refuses with exit 2, and `pick` filters them |
| Environment | `SP_IMPLEMENTER=<profile>` | A permanent pin |
| Persistent | `agent-dispatch disable <p>` | `enabled = false` in `profiles.toml` |

Back compatibility:
- "через Luna", "без GLM" and `SP_IMPLEMENTER=luna` mean what they mean today [SKILL:370, 378], through the aliases `luna` and `glm`.
- Luna is `riskEligible`, so risk phases go to Luna under the kill switch, exactly as now [SKILL:370].

### 5.6 Concurrency

- `concurrency` is set per profile and counted per `quota_group` across all workspaces from the job records. The preset defaults follow the provider tables:
  - Z.ai plan: 1–2+ by tier [06 §6];
  - Kimi Tier0: 1 [06 §6];
  - local server: 1 on 16 GB [08 §10];
  - glm-zcode: 2 [ZI:24].
- A busy profile makes `task` exit 2 with `busy: <p> at concurrency <n> (zt-0007 running in <ws>)`, and `pick --parallel` skips it. This replaces the special GLM rule for parallel groups [SKILL:635, 00 C20].
- One write task per working tree remains a hard rule (the reservation, [00 I9]). Read-only reviewer tasks take no reservation [00 R2].
- The width cap of 2 tracks per group remains and counts every profile [SKILL:631, 00 C19].

---

## 6. Security and compliance

### 6.1 Sandbox tiers per role and adapter

| Tier | Meaning | Adapters |
|---|---|---|
| T0 | No OS boundary. L0 controls (git-tree guard, env allowlist, isolated home, key out of argv) plus L3 post-run checks [09 §7.1] | zcode, opencode, pi, claude-code. Claude Code's own Bash sandbox (`failIfUnavailable` [01 §16]) is switched on as an extra, but it confines only Bash, so the tier stays T0 |
| T1 | T0 plus harness-level tool removal for read-only roles (L2) | claude-code, opencode and pi reviewer modes |
| T2 | Native OS sandbox | codex-companion, codex-exec (full); dsh (writes only) [09 §8] |
| T3 | srt with credential `mask`, after canaries on pinned versions [09 §7.3-7.4, §9 M6] | later increment: claude-code, opencode, pi, zcode |

| Role | Minimum |
|---|---|
| implementer, fallback, escalation, utility | T0 (the same exposure as GLM today) |
| risk | `riskEligible`: M1–M9 [09 §9]. Today T2 Codex only; T3 adapters after canaries |
| plan / primary / control / final review | `readOnly ≠ none` (T1 or T2). A T0 harness without a read-only mode, such as zcode, is never a reviewer [00 R1-R2] |

L3 checks run in the core for every adapter, starting in Increment 3 (§9). Each is cheap and local and fails only the job it inspects:
- hashes of `.git/hooks`, `.git/config` and the worktree `.git` file, before and after the job;
- a scan of the diff, report and logs for the profile's key.

The result is the `stop` group [09 §7.1]. Nesting rule: srt is never wrapped around Codex, DSH, or a `claude` running its own sandbox [09 §2.5, §7.2].

### 6.2 Key custody

- **Keys enter only from the user's terminal:** `key set` (hidden prompt or stdin pipe), the Keychain, or the harness's own login run by the user. The orchestrator never runs `key set`, never asks for a key in chat, and only relays the `hint:` line with the absolute path filled in [SKILL:366, 00 C15].
- **Keys are never in `profiles.toml`, argv or the parent environment.** Adapter-owned variables are applied after the allowlist [00 I17], and every key is fed to the redactor [00 §2].
- **`claude-code` isolation:**
  - a per-profile `CLAUDE_CONFIG_DIR` with no claude.ai login;
  - `--setting-sources ""` plus `--settings <file>`, so a repo's `.claude/settings.json` cannot redirect the key [01 §9, §15.1];
  - `ANTHROPIC_API_KEY` empty when the helper supplies the key; `CLAUDE_CODE_OAUTH_TOKEN` and `CLAUDE_CODE_ENTRYPOINT` never inherited [07 §6.2, 01 §14];
  - doctor requires `authMethod: api_key_helper` [01 §16];
  - `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` and `CLAUDE_CODE_MAX_RETRIES=2`, so failures surface in seconds rather than about 3 minutes [01 §15.5, 09 §5].
- **Env-keyed harnesses** (opencode, pi, dsh) before T3: the model's shell can read the key (pattern A) [09 §5]. `check` prints one line advising a dedicated pay-as-you-go key with a spend cap. This is information, not a gate.
- **dsh:** the base URL is pinned in the patch, because a repo `.env` can redirect it, and the session-log upload is neutralized [04b §6, §9].

### 6.3 ToS gating

- `policy.json` is deny-by-default with three statuses (§4.6):
  - **`no`:** `add`, `check` and `task` refuse (exit 2) with the evidence ids and the `ok` alternative ("Alibaba Coding Plan bans non-interactive use (AL1); use preset alibaba-payg").
  - **`gray`:** refused until the profile carries `accept_gray`. Only `add` writes that field, after the user types the plan id in their own terminal [07 §5]. `profiles.toml` is not on Rule 1's list of files the orchestrator may edit [SKILL:23-28], so the orchestrator cannot enable a gray row.
  - **`ok`:** proceeds.
- **Typed keys.** A preset stores the endpoint and key type together. The wizard asks which Z.ai key type the user has, because a Standard key and a Coding Plan key cannot be told apart by prefix and the wrong pairing bills pay-as-you-go [06 §1.3].
- **Truthful identity.** No adapter sets a User-Agent, originator, `x-app` or client id [07 §6.3]. Third-party models in Codex go through `codex-exec`, never through the companion, whose client info names it "Claude Code" [05 §14].
- **No local reverse proxy** that turns a plan into an API for another harness [07 §6.8].
- **Data terms are shown, not gated.** `add` and `check` print the provider's data note (DeepSeek PRC; MiniMax may use inputs) [06 §4].
- **Staleness.** Rows carry `reviewed`. After 180 days `check` prints a warning and never blocks [07 §6.7].

### 6.4 Code versus instructions

- **Repo files never control endpoint, key, tools or permissions.**
  - claude-code: `--setting-sources ""` (project rules re-injected via `--append-system-prompt-file`, since that flag drops CLAUDE.md) [01 §15.9].
  - opencode: per-profile `XDG_*` with `OPENCODE_DISABLE_*`. `OPENCODE_CONFIG_DIR` is additive, so it is not used for isolation [02 §9].
  - Codex project config cannot redirect the provider [05 §5].
  - DSH: the base URL is pinned and `DSH_AGENTS_HOME` is empty [04b §9].
- **Job outputs are data.** `pick` reads only the registry and the session file, so nothing a harness writes can change routing.
- **Users can add, not loosen.** Presets and the policy are reviewed plugin data. The user file can add profiles but cannot turn a `no` row into `ok`.

### 6.5 Staying low-ceremony

- No receipts, hash-bound approvals, provenance gates or per-dispatch confirmations.
- The one gray acknowledgement is a setup act in the user's terminal, not a pipeline gate.
- Every failure ends in an announced next profile or in one question (§5.4).
- The coordinator still verifies by `git diff` and by its own checks (Step 3.5 gate, unchanged).

---

## 7. Orchestrator and skill changes

| Coupling [00 §3] | Today | Proposed |
|---|---|---|
| C1 resolution | `$DISPATCH` + `$ZDISPATCH` snippets | One `$AD` snippet (same `command -v` / plugin-cache idiom) |
| C2 prefix → dispatcher | `zt-` → `$ZDISPATCH`, `task-` → `$DISPATCH` [SKILL:109] | Removed: `"$AD" status <id>` routes by prefix itself, including `task-` |
| C3 file suffix | `<name>.<seq>.<glm\|luna\|sol>.(md\|id)` [SKILL:384, 389] | `<name>.<seq>.<profile>.(md\|id)`; names match `[a-z0-9-]{2,24}`; the sidecar holds `<profile>:<id>`. The highest-seq rule is unchanged |
| C4 state line | `impl=<glm:zt-…\|luna:task-…\|sol:task-…\|claude\|—> glm=<unprobed\|ok\|down\|off>` [SKILL:100] | `impl=<profile>:<id>\|claude\|— ch=<profile>:<ok\|down\|off\|pin>[,…]` (only profiles touched this session) |
| C5 session marker | `<scratchpad>/dev-orchestrator/glm-channel` | `<scratchpad>/dev-orchestrator/channel-state`, written by `"$AD" mark`. Lines are `<profile> <state> <reason> <iso>`, and the last line per profile wins. Recovery is one `cat` |
| C6 kill switch | `SP_IMPLEMENTER=luna`, two phrases | §5.5; the old forms work through aliases |
| C7/C8 ladder, escalation | 5-item ladder + kill-switch and probe paragraphs [SKILL:365-378] | "At a phase's first dispatch run `"$AD" pick implementer` (risk-marked: `pick risk`) with `--session` and `--sticky`. Dispatch what it prints, relay `announce:`, and on `ask:` ask once" |
| C9 model split | 33-line table [SKILL:144-176] | The same table as "role → default profile", plus `"$AD" routes --line` echoed once at skill start |
| C10 family | Prose | Prose (shorter), enforced by `pick --writer` |
| C11 checklist 5 and 10 | Two long Codex/GLM items [SKILL:209, 214] | One item: the profile is the one `pick` printed; the file suffix is that profile; the resume id belongs to it; `--fresh` iff FRESH composition; `--cwd` on tracks; preamble iff `pick` printed one; the admission condition (risk map, `risk_checked`, clean plan file) is unchanged |
| C12-C14 failures | GLM infra ladder, stale-reservation procedure, MAX_PROMPT_BYTES rule [SKILL:422-437] | The errorGroup table (§5.4). The stale-reservation procedure stays as is with `agent-dispatch:` strings (the prefix is the invoked program name, so the old shim keeps `zcode-dispatch:`) |
| C15 probe | Long paragraph [SKILL:366] | Inside `pick`; one line: "relay `hint:` lines verbatim; never run `key set`" |
| C16 verified facts | `Model selection`, `Model confirmation`, `GLM resume`, `GLM concurrency` lines [ZI:19-27] | Manifest fields; `pick` prints `confirm=` when a once-per-session confirmation is due |
| C17 preamble | "ZCode preamble" | `preamble=headless-unsandboxed` from `pick` for T0 implementers; the text in `implementer-prompt.md` says `<harness home>` instead of `~/.zcode` |
| C18 notice | `<GLM-5.3-Flash via ZCode \| Codex Luna \| Codex Sol>` | `<profile.display>`, `job <profile>:<id>` |
| C19 status | Both dispatchers | `"$AD" status --all` lists every profile's jobs, companion jobs included |
| C21 reviewers | Hardwired `$DISPATCH --model gpt-6-astra` | `pick plan_review \| control_review \| final_review`. For Codex profiles the adapter passes `--model` and `--effort` from the profile. Templates say "the control reviewer" |
| C22 Red Flags | GLM-specific | Generic: never bypass the dispatcher; never handle keys in chat; never give a risk phase to a non-`riskEligible` profile; never edit `profiles.toml` |
| Gate allowlist | `"$DISPATCH" status`, `"$ZDISPATCH" status \| doctor \| doctor --probe`, `cat` of the marker [SKILL:61-72] | `"$AD" status \| routes \| pick \| mark`, `cat` of `channel-state` |
| C25 plugin.json | Lists every model | Roles plus "configurable profiles (agent-dispatch)" |

New and retired files:
- **New** `skills/agent-dispatch/SKILL.md` (about 220 lines). It replaces `zcode-invocation` (202 lines) and the dispatch half of `codex-invocation` (274 lines; the ad-hoc second-opinion template stays, about 120 lines).
- **New** `docs/agent-dispatch.md`: the user guide (setup, presets, troubleshooting by `hint:`).

Estimated size changes:
- `SKILL.md`: from 793 to about 720 lines. About −85 from the ladder, probe, infra and verified-facts prose, about +15 for `pick`, `mark` and the errorGroup table.
- Invocation skills: from 476 to about 340 lines.
- **Net prose: about −200 lines.**
- **New code: about +2,500 lines** across all increments, plus tests.

---

## 8. Migration of the GLM and Codex channels

### 8.1 GLM (`zcode-dispatch`)

1. **Split the file.** `bin/lib/zcode-dispatch.mjs` (1,673 lines: CORE ≈900, CORE-P ≈250, ZC ≈470 [00 §2]) becomes `agent-dispatch/core.mjs` plus `adapters/zcode.mjs`. Ids (`zt-`), the state dir, the personal-config path, lock names and user-visible strings stay the same.
2. **Keep the shim.** `bin/zcode-dispatch` stays as `exec node …/agent-dispatch.mjs --profile glm-zcode "$@"`. `api-key set|clear` maps to `key set|clear glm`, which writes the ZCode personal config exactly as today [ZI:126].
3. **Add the built-in profile `glm-zcode`** (alias `glm`): zcode, GLM-5.3-Flash, `max`, family zai, `own-config`, concurrency 2, preamble, resume enabled [ZI:23-24].
4. **Regression gate.** `bash tests/test-zcode-dispatch.sh` must stay at 110 PASS against the shim before anything else merges [00 §5].
5. **Orchestrator switch.** `SKILL.md` keeps `$ZDISPATCH` until Increment 3, which works through the shim. In-flight plans resume across the switch, because old suffixes `.glm` and `.luna` and old sidecars `glm:zt-…` resolve through the aliases.

### 8.2 Codex (vendored companion)

1. **Leave the companion alone.** The vendored companion and `bin/codex-dispatch` stay untouched as the official OpenAI-login path.
2. **Wrap it.** The `codex-companion` adapter is a pass-through:
   - `task --profile luna` → `codex-dispatch task --background --write --model gpt-6-luna --effort max --prompt-file …`;
   - `status`, `result` and `cancel task-…` are delegated;
   - status is normalized (`errorGroup: retry` on failure, since there is no class [00 BL3]);
   - **`result` exits 1 on a failed job**, which fixes BL3 at the wrapper.
3. **Built-in profiles.** `luna` (gpt-6-luna, max, write), `sol` (gpt-6.1-sol, xhigh, write, `riskEligible`), `astra-high` and `astra-xhigh` (read-only); family openai [SKILL:153-163].
4. **Old sidecars keep working.** Ids stay `task-NNNN`, and the existing sidecar text `luna:task-…` / `sol:task-…` already has the `<profile>:<id>` shape [SKILL:389].
5. **Third-party models** in Codex only through `codex-exec` (Increment 5), never through the companion (client identity, [05 §14]).

---

## 9. Delivery plan

Each increment merges on its own and leaves `/dev` working. Stub tests generalize `tests/fixtures/zcode-stub.cjs` into `tests/fixtures/agent-stub.cjs`, with one output dialect per harness and the existing modes (ok, pong, resume, record, leak, linger, auth, quota, launch, hang, ignore-term, split-utf8, crash, malformed) [00 §5]. They split into core tests (sections 3, 5, 7-10, 16) and adapter tests (sections 2, 4, 6, 11, 12, 15, 17).

| # | Scope | Stub tests | Size | Live, with the user's keys |
|---|---|---|---|---|
| 1 | **Core split + registry + UX shell.** zcode adapter + shim; TOML-subset parser; `defaults.toml` reproducing today; preset files for every provider named in §4 and §9, `policy.json`, `families.json`; verbs `where, presets, list, show, routes, explain, add, key set/clear/list, check, enable/disable, route, status --all`. Orchestrator untouched | 110 existing via shim; new `tests/test-agent-registry.sh`: parser errors with line numbers, cleartext key rejected, merge and override, defaults == v0.11.1 map, family derivation, policy precedence + deny-by-default, gray needs `accept_gray`, key file modes, line edits keep comments | M: ~1,650 lines moved, ~900 new code, ~300 data, ~500 test | `agent-dispatch check glm-zcode`: one PONG with the existing key (the same request as today's probe) |
| 2 | **claude-code adapter.** Profile homes (settings.json, key helper), stdin prompt, `--session-id`/`--resume`, reviewer mode, error classes from `api_error_status`/`terminal_reason`, probe `--bare --tools "" --max-turns 1` with `MAX_RETRIES=0` [01 §16], cancel. Presets: zai-coding-plan, deepseek-api, kimi-platform, minimax-api, alibaba-payg, openrouter, ollama-local, lmstudio-local | Dialect `claude-json`: 401, 429-quota text, 429-throttle, `prompt_too_long`, SIGINT-empty, hang, leak. Assert: no inherited `ANTHROPIC_*`/`CLAUDE_*`, `CLAUDE_CONFIG_DIR` = profile home, `--setting-sources ""`, a repo `.claude/settings.json` base URL ignored (E9 replay), key absent from argv and env dumps | M: ~600 code, ~450 test | `add deepseek-api`; `check` PONG; `task --profile deepseek` on a scratch repo → DONE + diff; a reviewer-mode job asked to write a file writes nothing; a wrong key gives `auth`; cancel mid-run leaves no processes |
| 3 | **Orchestrator on routes.** `pick`, `mark`, `errorGroup` in status JSON, read-only tasks without reservation, L3 checks, `codex-companion` adapter + luna/sol/astra profiles; edits to `SKILL.md`, `implementer-prompt.md`, the Codex review prompts, `plugin.json`; new `agent-dispatch` skill | `tests/test-agent-pick.sh`, table-driven: kill-switch phrase/env, risk → `riskEligible` only, down skip, sticky, family skip, `--bytes` → next, busy, `NONE` → one `ask:`, aliases `glm`/`luna`, old sidecars. Companion adapter against a fake `codex-dispatch` | M-L: ~500 code, ~400 test, SKILL net −70 | `/dev` on a toy 2-phase plan: (a) defaults behave as v0.11.1; (b) `SP_DISABLE=glm-zcode` → deepseek implements, Astra controls, announcements right; (c) "без deepseek" mid-session → next phase on luna |
| 4 | **opencode adapter** (v1 pin). Presets opencode-go, opencode-zen, copilot (`harness-login`) | Dialect `opencode-jsonl`: `session.error` then recovery with exit 1, auto-reject with exit 0, stdin close, v2 refused | M: ~500 code, ~350 test | OpenCode Go key: `check`, one toy implement, a deny-all reviewer cannot write |
| 5 | **codex-exec adapter.** Custom Responses providers [05 §5.3], `auth.command`, per-profile `CODEX_HOME`, hardening flags [05 §2], `riskEligible` | Dialect `codex-jsonl`: unknown model exit 0 + `turn.failed`, SIGTERM orphan sweep, resume with the provider defined | M: ~450 code, ~300 test | `deepseek-cx` as risk profile on a toy repo: write outside the worktree denied; probe |
| 6 | **pi adapter.** `anthropic`/`github-copilot` refused, event parsing, session-file existence check before resume | Dialect `pi-json`: provider error with exit 0, `agent_settled`, typo'd session id | S-M: ~400, ~300 | MiniMax PAYG key: `check`, toy implement |
| 7 | **dsh adapter.** Exact pin, neutralization patch, cancel sequence | Dialect `dsh-json`: `error` codes, SIGTERM exit 0, unknown session id | M: ~500, ~350 | DeepSeek key: `check`; confirm with `--dump-config` that no session-log upload is configured |
| 8 | **srt tier (T3)** for claude-code, opencode, pi and zcode; `doctor --probe-sandbox` canaries [09 §7.4]; promotion to `riskEligible` after canaries | srt stubbed at the spawn seam; canary harness | L | The smoke matrix of [09 §10] on this Mac |

---

## 10. Risks and open questions

### Risks

1. **GLM regression from the split.**
   - Mitigation: the 110-test gate through the shim, and no orchestrator change in Increment 1.
2. **TOML subset surprises.**
   - A user may type TOML features outside the subset.
   - Mitigation: strict errors with line numbers, and `add`/`route`/`enable` so most users never hand-edit. JSON is the fallback format if the subset proves confusing.
3. **Policy staleness.**
   - Six governing pages changed in 2026 [07 §6.7].
   - Mitigation: dated rows, a warning after 180 days, and updates shipped with plugin releases.
4. **Misdeclared key types.**
   - A Z.ai Standard key cannot be told from a Coding Plan key by prefix [06 §1.3]; the result is a billing surprise, not a ToS breach.
   - Mitigation: the wizard asks which key type, and `check` prints the billing note.
5. **Unsandboxed third-party implementers (T0).**
   - The exposure equals GLM today.
   - Mitigation: excluded from risk phases, L3 checks, and T3 later.
6. **Env-keyed harnesses can read their key** until T3 [09 §5 A].
   - Mitigation: `check` advises a dedicated pay-as-you-go key with a spend cap.
7. **Third-party model quality inside Claude Code varies.**
   - Auto mode is unproven on non-Claude endpoints [01 FC], and Kimi has no `tool_choice: tool` [06 §1.4].
   - Mitigation: the line-1 token stays the contract, and `--json-schema` is off by default.
8. **Wrong family through aggregator ids** would silently weaken the family rule.
   - Mitigation: an unknown id fails `check`, and `show` and `pick` print the family.
9. **Probe latency inside `pick`.**
   - At most 45 s per unprobed candidate, once per session.
   - Mitigation: the skill gives `pick` a 300 s Bash timeout.
10. **Data jurisdiction.**
    - DeepSeek is PRC-based and MiniMax may use inputs [06 §4].
    - This is the user's choice; it is displayed, never gated.

### Open questions

1. **Alibaba Token Plan.** [06 §1.2] says Personal is non-compliant; [07 §2] says OK\*. The policy ships Personal as `no` and Team as `gray`. Should it?
2. **Z.ai headless use.** Z.ai does not address headless use of a listed tool by the subscriber [07 §7]. The status quo assumption (`ok`) is kept.
3. **Luna and Sol on codex-exec.** Should they move from the companion to `codex-exec` with the user's ChatGPT login, to gain timeout, lock and errorClass? That needs a safe way to share the auth across a per-profile `CODEX_HOME` [00 §6.1].
4. **Shared claude-code home.** Are concurrent `claude -p` jobs sharing one per-profile `CLAUDE_CONFIG_DIR` safe [unverified]? Per-job dirs would break resume [01 §4].
5. **Utility off Claude.** Should `utility` (verification gate, synthesis) leave Claude for anyone? The default stays `claude:sonnet`.
6. **Keychain inside srt.** An item may be readable from inside srt [09 §5 E, unverified]. This matters only once T3 lands.
7. **Port scanning in `setup`.** Is probing loopback ports 11434, 1234 and 9931 during `setup` acceptable to the user? The probes are local only.

---

## 11. Deliberate non-goals

- No GUI or web configuration page: one terminal tool and one TOML file.
- No key entry through chat, no orchestrator-run key commands, no `env:` key references and no cleartext keys.
- No live model-catalog fetch at dispatch time. Presets are shipped data; the wizard may list harness-local catalogs such as `opencode models`.
- No routing of the orchestrator, plan writer or reviser, diagnosis, or frontend implementer away from Claude.
- No cost budgets, spend tracking or price-based routing. Usage is logged only.
- No racing or load-balancing: the first eligible profile wins.
- No translating gateways, plan-pooling proxies or User-Agent rewriting.
- No containers or VMs. The srt tier is a later increment, not a prerequisite.
- No ACP transport in these increments.
- No receipts, attestations, hash-bound approvals or per-dispatch confirmations.
- No automatic enabling of gray rows, and no overriding of `no` rows even when the user asks in chat.
- No Claude Pro/Max login in non-Anthropic harnesses, and no `claude-code` profile on the user's claude.ai login.
- No per-phase model choice inside plan files. Plans stay model-agnostic; the session kill switch covers one-off steering.
