# 02 — OpenCode as a dispatch target (implementer / reviewer channel)

Researched 2026-10-20. Primary versions: **OpenCode 1 = `opencode-ai` v1.19.3** (GitHub release, 2026-10-16) and **OpenCode 2 = `@opencode/cli` v2.1.0** (git tag + npm, 2026-10-20). Read-only research: OpenCode is not installed on this machine, so nothing here was run against a live binary. Code facts come from the source at the release tags. Docs facts come from opencode.ai/docs (pages stamped "Last updated: Oct 19, 2026").

## Bottom line

- **Feasible, and the most flexible single harness for "bring your own API/subscription".** One binary covers OpenAI-compatible, Anthropic-compatible, Responses-API and local endpoints (`opencode.json` → `provider.<id>.npm/options.baseURL/options.apiKey`). The live catalog already includes `zai-coding-plan`, `deepseek`, `kimi-code-plan-*`, `minimax-coding-plan`, `alibaba-coding-plan`, `opencode-go`, `github-copilot`, `openai` (ChatGPT OAuth), `lmstudio` and others [third-party:https://models.opencode.ai/api.json, fetched 2026-10-20].
- **Recommended transport for v1:** `opencode run --format json` (JSONL on stdout). Without `--attach` it runs the server **in-process through a fetch shim and opens no TCP port**, so concurrent jobs have no port conflicts [source:anomalyco/opencode@v1.19.3:packages/opencode/src/cli/cmd/run.ts:938-951]. Use `opencode serve` + HTTP/SSE only if you need graceful abort, retry visibility, per-session permission rules or JSON-schema structured output.
- **Unattended safety is weak by default.** The default permission is `"*": "allow"` (bash, edit and webfetch all allowed), and there is **no sandbox** in v1 or v2. In `run` mode a permission "ask" never hangs: it is auto-rejected. In v1 that rejection **stops the agent loop** (often with exit 0), and `--auto` approves every ask, including `.env` reads [source:…/agent/agent.ts:119-135; …/cli/cmd/run.ts:791-811; …/session/processor.ts:200-201,647,694].
- **Isolation is mandatory and has to be built by the wrapper.** Each dispatch otherwise merges global `~/.config/opencode` (this machine already has `plugins/orca-opencode-status.js` there [local-run]), project `opencode.json`/`.opencode/`, `~/.claude/CLAUDE.md`, `~/.claude/skills` and `~/.agents/skills` (both present here [local-run]), plus **every provider whose env var happens to be set** (for example, `GITHUB_TOKEN` enables `github-copilot`). `OPENCODE_CONFIG_DIR` is additive and **does not** replace the global dir. Isolate with per-profile `XDG_CONFIG_HOME`/`XDG_DATA_HOME`/`XDG_CACHE_HOME`/`XDG_STATE_HOME`, an env allowlist and the `OPENCODE_DISABLE_*`/`OPENCODE_PURE` flags (§9).
- **Version split risk.** OpenCode 2 (`@opencode/cli`, 34 tags since 2026-09-11, no GitHub release notes) uses the same `opencode` command and the same XDG dirs, and Homebrew Core's `opencode` formula now installs v2 [source:…@v1.19.3:packages/opencode/src/installation/index.ts:63-66,314-315; docs:https://opencode.ai/docs/]. In v2, `run` defaults to a **shared per-user background service** (per-job env isolation then needs `--standalone`), `--variant` moves into `-m provider/model#variant`, and a permission reject no longer stops the loop. The adapter must detect the major version (`opencode --version`) and pin v1 or carry two mappings.
- **ToS headline (details elsewhere):** the Anthropic OAuth plugin was removed in v1.3.0 (2026-03-22), and the docs say Anthropic "explicitly prohibits" Pro/Max plugins. ChatGPT Plus/Pro (Codex OAuth) and Copilot logins are built in and identify as `opencode`.

---

## 1. Identity

| Item | Value | Evidence |
|---|---|---|
| Name / repo | OpenCode, `anomalyco/opencode` (`sst/opencode` redirects to it) | [local-run: `gh api repos/sst/opencode` → `anomalyco/opencode`] |
| Maintainer | Anomaly (org `anomalyco`, anoma.ly) | [local-run: `gh api orgs/anomalyco`] |
| License | MIT | [local-run: gh api repo metadata] |
| Activity | ~218k stars, ~29k forks, ~2.6k open issues (+ ~1.2k open PRs; ~3.8k is GitHub's combined `open_issues_count`) [corrected 2026-10-20: `gh api repos/anomalyco/opencode` open_issues_count=3783 counts PRs too; search API is:issue is:open = 2617, is:pr is:open = 1163], pushed 2026-10-20 | [local-run] |
| OpenCode 1 latest | **v1.19.3**, 2026-10-16 (GitHub release; npm `opencode-ai@latest` = 1.19.3). 16 releases between 2026-08-28 and 2026-10-16 (v1.18.24 through v1.19.3) [corrected 2026-10-20: `gh api repos/anomalyco/opencode/releases` lists v1.18.24 and v1.18.25 both on 2026-08-28, so 12 v1.18.x + 4 v1.19.x] | [local-run: gh releases; npm registry] |
| OpenCode 2 latest | **v2.1.0**, tagged 2026-10-20 (npm `@opencode/cli@latest` = 2.1.0, 07:15Z). 34 `v2.*` tags, first v2.0.0 on 2026-09-11. **No GitHub release objects** for v2 (issue #52184 "v2 releases have no published release notes") | [local-run: gh tags, npm registry, issue search] |
| v1 ↔ v2 | v1 offers v2 only as an explicit choice: `opencode upgrade --major` or the 2.0 offer in the TUI `/update` (v1.19.0+) [corrected 2026-10-20: release notes v1.19.0/v1.19.2 name both routes]. v1 update checks never offer 2.x (v1.19.2). Both ship an `opencode` binary and "cannot be installed side by side under their default command" [corrected 2026-10-20: verbatim wording on https://opencode.ai/docs/, Last updated Oct 19, 2026]; `@opencode/cli` also ships an `opencode2` bin | [source:anomalyco/opencode@v1.19.3:packages/opencode/src/installation/index.ts:63-118; source:…@v2.1.0:packages/cli/package.json; docs:https://opencode.ai/docs/] |
| Runtime | Bun-compiled single binary. The npm package's `bin/opencode` is a Node shim that spawns the native binary and forwards SIGINT/SIGTERM/SIGHUP and the exit code | [source:…@v1.19.3:packages/opencode/bin/opencode:8-42; …/script/build.ts:172-177] |
| OS binaries (v1.19.3) | darwin arm64/x64(+baseline); linux x64/arm64 (glibc + musl, x64 baseline); windows x64/arm64(+baseline). The docs recommend WSL on Windows | [local-run: release assets; docs:https://opencode.ai/docs/] |
| Install | `curl -fsSL https://opencode.ai/install \| bash`, `npm i -g opencode-ai`, `brew install anomalyco/tap/opencode` (**not** core `opencode`, which is v2), choco/scoop/mise/docker | [docs:https://opencode.ai/docs/] |

## 2. Headless invocation

**v1 `opencode run [message..]` flags** [source:…@v1.19.3:packages/opencode/src/cli/cmd/run.ts:126-263; docs:https://opencode.ai/docs/cli/]:

| Flag | Meaning |
|---|---|
| `-m/--model provider/model` | split on the first `/`; the rest is the model id |
| `--variant <v>` | provider-specific reasoning effort (e.g. `high`, `max`, `minimal`) |
| `--agent <name>` | primary agent. **An unknown name or a subagent falls back to the default agent with a stderr warning, not an error** [run.ts:585-609] |
| `-s/--session <id>`, `-c/--continue`, `--fork` | resume (§4) |
| `--format default\|json` | `json` = raw JSONL events (§3) |
| `-f/--file <path>` (repeatable) | attachments; in local mode they are passed as `file://` URLs (directories allowed); in `--attach` mode they are inlined as data URLs, max 10 MiB each |
| `--title <t>` | session title. **Also skips the small-model title-generation call** [source:…/session/prompt.ts:193-251] |
| `--command <name>` | run a slash command with the message as arguments |
| `--dir <path>` | chdir before boot (or remote path with `--attach`) |
| `--attach <url>` `-p/--password` `-u/--username` | use a running `opencode serve` |
| `--auto` (hidden aliases `--yolo`, `--dangerously-skip-permissions`) | auto-approve asks not explicitly denied |
| `--thinking` | include reasoning (`reasoning` events in JSON) |
| `--port` | declared but **unused** by `run.ts` at v1.19.3 |
| global: `--pure`, `--print-logs`, `--log-level` | `--pure` sets `OPENCODE_PURE=1` = no external plugins [source:…/src/index.ts:52-77] |

**Prompt transport:** argv words are joined with spaces, and any argv element that itself contains a space is wrapped in double quotes (inner `"` escaped), so a prompt passed as one argv string reaches the model with added quotes [corrected 2026-10-20: run.ts@v1.19.3 lines 289-291 map `arg.includes(" ") ? "\"…\"" : arg`]. Piped stdin is read in full (`Bun.stdin.text()`) and **appended** after a newline. With no argv message, stdin alone is the prompt [run.ts:40-50,417-424]. Recommended: `opencode run … < prompt.md` (no argv size limit; macOS `ARG_MAX` is 1 MiB [verified by fact-check 2026-10-20: `getconf ARG_MAX` = 1048576 on this machine]). An empty message plus empty stdin → `You must provide a message or a command`, exit 1.

**Canonical job command (v1):**
```sh
opencode run --format json --title "<jobId>" --agent implementer \
  -m zai-coding-plan/glm-5.3 --variant high --dir "<worktree>" < prompt.md \
  > events.jsonl 2> stderr.log
```

**v2 `opencode run`** [source:anomalyco/opencode@v2.1.0:packages/cli/src/commands/commands.ts (run spec); …/commands/handlers/run.ts]: flags `--standalone`, `--server <url>`, `-c/-s/--fork`, `-m provider/model#variant`, `--agent`, `--format default|json`, `-f` (≤100, data URLs only, ≤10 MiB, no directories), `--title`, `--thinking`, `--auto`. **Removed:** `--variant`, `--dir`, `--attach`, `--command`, `--port`. Without `--standalone`/`--server`, it **discovers or starts a shared per-user background service** [source:…@v2.1.0:packages/cli/src/services/server-connection.ts:20-48; docs:https://opencode.ai/v2/docs/cli/].

## 3. Output and final-message extraction

**v1 `--format json`:** one JSON object per line on stdout, shape `{type, timestamp, sessionID, ...data}` [run.ts:668-681]:

| `type` | Emitted when | Payload |
|---|---|---|
| `step_start` | a `step-start` part of the main session | `part` |
| `text` | a text part **finishes** (`part.time.end` set) | `part` = `{id, sessionID, messageID, type:"text", text, time, …}` |
| `tool_use` | a tool part reaches `completed` or `error` | `part` (`tool`, `state.status`, `state.input/output/error`) |
| `step_finish` | end of each LLM step | `part.reason`, `part.cost`, `part.tokens{total?,input,output,reasoning,cache{read,write}}` [source:…@v1.19.3:packages/schema/src/v1/session.ts:240-256] |
| `reasoning` | only with `--thinking` | `part` |
| `error` | `session.error` for the main session, or a failed prompt call | `error` = NamedError object `{name, data{message,…}}` |

- Events from child (subagent) sessions are **filtered out** of text/tool output. Their permission asks are still answered [run.ts:692-712,791-811; release v1.18.20].
- Warnings (`agent … not found`, `permission requested: …; auto-rejecting`) and `UI.error` go to **stderr**, so stdout stays pure JSONL [source:…/src/cli/ui.ts:33-38].
- The process exits when the main session reports `session.status` = `idle` [run.ts:783-789]; then `process.exit()` runs explicitly to avoid hanging MCP children [source:…/src/index.ts:136-141].
- **Session id:** the `sessionID` field of any event line. It is not printed in default format.
- **Final message:** take the `text` events, group by `part.messageID`, and use the **last** messageID's text parts in order. More robust: `opencode export <sessionID>` (stdout JSON `{info, messages:[{info, parts}]}`) → last `role:"assistant"` message → its `text` parts. `info.error`, `info.modelID/providerID`, `info.cost`, `info.tokens` and `info.finish` are also there [source:…/src/cli/cmd/export.ts:223-290; …/schema/src/v1/session.ts:453-485]. Line 1 of that text carries the plugin's status token.
- **Exit codes (v1, local mode):** 0 = session went idle with no `session.error`. 1 = any `session.error` (provider/auth/API/overflow), a prompt-call error, a usage error, model-not-found, config errors [run.ts:825-866; …/src/index.ts:127-135]. **0 is also returned when the run ended early because a permission was auto-rejected** (the loop stops without a `session.error`) [inference from processor.ts:200-201,694 + run.ts:829-833; confidence medium].
- **`--attach` gotcha:** `finish()` returns immediately when attaching, so the CLI neither drains the event loop nor maps `session.error` to exit 1 [run.ts:829-833]. Do not use `--attach` for a job runner.
- **v2 JSON:** same `type` names (`text`, `reasoning`, `step_start`, `step_finish` with `cost`/`tokens`, `tool_use`, `error`). Exit 1 on failure, **130** on user interrupt. Pre-session failures emit `{"type":"error","sessionID":"",…}` [source:…@v2.1.0:packages/cli/src/run/noninteractive.ts:100-104,494-540,680; …/run/run.ts:240-256].

## 4. Sessions and resume

| Item | v1.19.3 | Evidence |
|---|---|---|
| Id | `sessionID` string from the session service (format not pinned here; the SDK treats it as an opaque string) | [run.ts:661-666] |
| Resume by id | `opencode run -s <id> …` (exits 1 `Session not found` if missing). `--fork` forks first. `-c` = newest top-level session (positional; avoid) | [run.ts:457-517] |
| Persistence | SQLite `$XDG_DATA_HOME/opencode/opencode.db` (WAL, `busy_timeout=5000`). Non-release channels use `opencode-<channel>.db`. Override with `OPENCODE_DB` (absolute path or `:memory:`) | [source:…@v1.19.3:packages/core/src/database/database.ts:27-29,43-54] |
| Scope | Sessions belong to a project (git worktree). `--dir` picks the instance | [run.ts:131-134] |
| Export | `opencode export <id> [--sanitize]` → JSON on stdout; `opencode session list --format json` | [source:…/cli/cmd/export.ts; …/cli/cmd/session.ts:71-146] |
| Undo data | Shadow git dir `$XDG_DATA_HOME/opencode/snapshot/<projectId>/<hash(worktree)>` (alternates into the repo's objects); disable with `"snapshot": false` | [source:…/src/snapshot/index.ts:71-75,184-231] |
| v2 | Credentials and sessions live in the v2 SQLite DB. `-s <id>` "Session ID to continue, **or to create if it does not exist**" [corrected 2026-10-20: verbatim flag description in commands.ts@v2.1.0] | [source:…@v2.1.0:packages/cli/src/commands/commands.ts (run.session)] |

The resume model fits the plugin contract (job id → stored `sessionID` → `run -s`). The isolated profile env (§9) must be identical across resumes, or the DB will not contain the session.

## 5. Model and provider selection

- **Selection order:** `-m` → config `model` → last used (`$XDG_STATE_HOME/opencode/model.json`) → first model by internal priority [source:…@v1.19.3:packages/opencode/src/provider/provider.ts:2033-2066; docs:https://opencode.ai/docs/models/]. **Always pass `-m`.** An unknown model → `Model not found: p/m` + suggestions, exit 1 (no silent fallback) [source:…/src/cli/error.ts].
- **Catalog:** `https://models.opencode.ai/api.json` (models.dev format), cached at `$XDG_CACHE_HOME/opencode/models.json` (5 min freshness, background refresh every 60 min, cross-process flock). A build-time snapshot is the offline fallback. Override with `OPENCODE_MODELS_URL` / `OPENCODE_MODELS_PATH`; `OPENCODE_DISABLE_MODELS_FETCH=1` [source:…@v1.19.3:packages/core/src/models-dev.ts:160-257].
- **Provider activation sources**, merged in order: env vars named in the catalog (`provider.env`), `auth.json` API keys, plugin auth loaders, custom loaders, config `provider` [provider.ts:1636-1707]. `enabled_providers` (allowlist) and `disabled_providers` (wins) restrict them [provider.ts:1496-1499; docs:https://opencode.ai/docs/config/].
- **Custom endpoints** (`opencode.json`) [docs:https://opencode.ai/docs/providers/; source:…@v1.19.3:packages/core/src/v1/config/provider.ts]:

```jsonc
{
  "enabled_providers": ["myglm"],
  "provider": {
    "myglm": {                                   // any id
      "npm": "@ai-sdk/openai-compatible",        // /v1/chat/completions
      // "npm": "@ai-sdk/anthropic",             // Anthropic Messages-compatible (catalog uses it for minimax*)
      // "npm": "@ai-sdk/openai",                // OpenAI Responses API
      "options": {
        "baseURL": "https://api.example.com/v1",
        "apiKey": "{file:/abs/path/key}",        // or "{env:VAR}"; missing env → empty string
        "headers": {}, "timeout": 600000, "chunkTimeout": 300000
      },
      "models": { "glm-x": { "limit": { "context": 200000, "output": 32000 },
                             "variants": { "high": { /* provider options */ } } } }
    }
  }
}
```

- **Local models:** Ollama `http://localhost:11434/v1`, LM Studio `http://127.0.0.1:1234/v1`, llama.cpp `http://127.0.0.1:8080/v1`, all via `@ai-sdk/openai-compatible` [docs:https://opencode.ai/docs/providers/]. The catalog has a built-in `lmstudio` provider (env `LMSTUDIO_API_KEY`) [third-party:https://models.opencode.ai/api.json].
- **Reasoning effort:** `--variant <name>` (v1) or `#variant` (v2). Variants are generated per model from catalog `reasoning_options` (since v1.19.3; configured `reasoning_options` replace catalog variants, configured `variants` overlay them) [source:…@v1.19.3:packages/opencode/src/provider/provider.ts:1619-1630; release v1.19.3]. Examples from the live catalog: `zai-coding-plan/glm-5.3*` → `low|high|max`; `deepseek/deepseek-v4-pro` → toggle + `low|high|max`; `kimi-code-plan-global/kimi-for-coding` → `none|low|high|max`; `minimax-coding-plan/MiniMax-M3.1-Flash` → `low…max` [third-party:https://models.opencode.ai/api.json]. Per-agent `variant` and per-model `options` are also accepted [source:…/agent/agent.ts:279-293].
- **Hidden extra calls:** title generation uses `small_model` or the provider's small model (skipped when `--title` is given) [prompt.ts:193-251]. Compaction/summary agents call the main model. Set `small_model` explicitly so no second provider is touched.

**Catalog providers relevant to the user's list** [third-party:https://models.opencode.ai/api.json, fetched 2026-10-20]:

| Provider id | SDK | Base URL | Env var |
|---|---|---|---|
| `zai-coding-plan` | openai-compatible | `https://api.z.ai/api/coding/paas/v4` | `ZHIPU_API_KEY` (shared with `zai`, `zhipuai`, `zhipuai-coding-plan`) |
| `deepseek` | openai-compatible | `https://api.deepseek.com` | `DEEPSEEK_API_KEY` |
| `kimi-code-plan-global` / `-cn` | openai-compatible | `https://api.kimi.ai/coding/v1` / `api.kimi.com/coding/v1` | `KIMI_API_KEY` |
| `minimax-coding-plan` / `minimax` | **anthropic** | `https://api.minimax.io/anthropic/v1` | `MINIMAX_API_KEY` |
| `alibaba-coding-plan` / `-cn` | openai-compatible | `https://coding-intl.dashscope.aliyuncs.com/v1` | `ALIBABA_CODING_PLAN_API_KEY` |
| `alibaba` (DashScope/Qwen) | openai-compatible | `…/compatible-mode/v1` | `DASHSCOPE_API_KEY` |
| `opencode` (Zen / Console PAYG), `opencode-go` | openai-compatible | `https://opencode.ai/inference/{openai,go/openai}/v1` | `OPENCODE_API_KEY` |
| `github-copilot` | openai-compatible | `https://api.githubcopilot.com` | **`GITHUB_TOKEN`** |
| `openai` | `@ai-sdk/openai` | — | `OPENAI_API_KEY` (or ChatGPT OAuth) |
| `anthropic` | `@ai-sdk/anthropic` | — | `ANTHROPIC_API_KEY` (API key only) |

## 6. Auth and credentials

| Item | Detail | Evidence |
|---|---|---|
| v1 store | `$XDG_DATA_HOME/opencode/auth.json` (default `~/.local/share/opencode/auth.json`, written with mode 0600). Entries `{type:"api",key}`, `{type:"oauth",refresh,access,expires,accountId?}`, `{type:"wellknown",key,token}` | [source:…@v1.19.3:packages/opencode/src/auth/index.ts:9-90; docs:https://opencode.ai/docs/cli/] |
| Env override | **`OPENCODE_AUTH_CONTENT`** (JSON) replaces the file read (undocumented) | [auth/index.ts:59-64] |
| Env keys | Any catalog `provider.env` var present in the process env activates that provider | [provider.ts:1636-1646] |
| Login CLI | `opencode auth login` (alias of `providers login`) `[url] [-p provider] [-m method]`: interactive prompts. `auth list` prints provider names + types + **env var names only** (no values). `auth logout` | [source:…/cli/cmd/providers.ts:240-330,248-296] |
| Subscriptions (built-in plugins) | **Codex / ChatGPT Plus-Pro** (browser + headless device flow, OpenAI Codex OAuth client id, `originator: opencode`, UA `opencode/<ver>`); **GitHub Copilot** (device code, own GitHub app); GitLab, Poe, Cloudflare, Azure, DigitalOcean, Snowflake, xAI, Cerebras, Modal. `OPENCODE_DISABLE_DEFAULT_PLUGINS=1` disables all of them | [source:…/src/plugin/index.ts:67-86; …/plugin/openai/codex.ts:10-12,91-99,441-562; …/plugin/github-copilot/copilot.ts:9] |
| Claude Pro/Max | **Removed in v1.3.0** (2026-03-22, "Removed anthropic oauth plugin", PR #18186). The docs still show a stale "Claude Pro/Max" `/connect` step, next to callouts that "Anthropic explicitly prohibits this" and "no longer the case as of 1.3.0" | [local-run: release notes v1.3.0; docs:https://opencode.ai/docs/providers/] |
| Key-only subscriptions | Z.ai Coding Plan ("select Z.AI Coding Plan" in `/connect`), Kimi For Coding, MiniMax Token Plan, Alibaba Coding Plan, DeepSeek, OpenCode Go/Zen: API key → `auth.json` or env | [docs:https://opencode.ai/docs/providers/; third-party catalog] |
| OpenCode Go | $10/mo (Go Plus $40). Per-model monthly $ limits with 5h=20% / week=50% rolling shares. Optional fallback to Console balance. The page says "Your client should" "Identify itself with its own user agent, such as `my-coding-agent/1.0`" and send a stable session ID in `x-opencode-session` [corrected 2026-10-20: verbatim text of https://opencode.ai/docs/go/ uses "should" and "Identify itself with its own user agent"; the earlier quote was not verbatim and "must" overstated it] | [docs:https://opencode.ai/docs/go/] |
| Zen | `/docs/zen/` now describes the "OpenCode Console" pay-as-you-go gateway (provider `opencode`), auto-reload $20 below $5 by default | [docs:https://opencode.ai/docs/zen/] |
| Console account | `opencode console`/account login pulls an org config (`<url>/api/config`) and sets `OPENCODE_CONSOLE_TOKEN` in process env | [source:…/src/config/config.ts:492-528] |
| v2 store | Credentials in the v2 SQLite DB; migration imports legacy `auth.json`. `opencode auth login --answer key=value` (non-interactive); **`opencode auth export` prints secrets as JSON** | [source:…@v2.1.0:packages/core/src/database/migration/20260805200742_import_legacy_credentials.ts; …/cli/src/commands/commands.ts (auth)] |

**Profile isolation recipe:** give each profile its own `XDG_DATA_HOME` (own `auth.json`, DB, snapshots) and `XDG_CONFIG_HOME`. The wrapper writes `auth.json` from a hidden prompt or stdin (mirroring `zcode-dispatch api-key`), or references a 0600 key file via `"apiKey": "{file:/abs/path}"` in the generated config.

**Leak risks:**
1. The bash tool's env is the **full `process.env`** plus plugin `shell.env` [source:…@v1.19.3:packages/opencode/src/tool/shell.ts:415-424]. Keys passed via env, `OPENCODE_AUTH_CONTENT` or an inline `OPENCODE_CONFIG_CONTENT` are readable by the model (`env`, `printenv`).
2. Inherited `GITHUB_TOKEN`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` and similar silently enable those providers.
3. The `{env:…}`/`{file:…}` expansion also applies to project `opencode.json` files that are not under your control.
4. A wellknown auth entry fetches remote config from `<url>/.well-known/opencode` at startup [config.ts:370-410].

## 7. Autonomy for unattended runs

**Built-in defaults** (v1.19.3) [source:…/src/agent/agent.ts:119-135]: `"*": "allow"`; `doom_loop: ask`; `external_directory: {"*": ask, <tmp, truncation, skill dirs>: allow}`; `question/plan_enter/plan_exit: deny` (build re-allows question/plan_enter); `read: {"*": allow, "*.env": ask, "*.env.*": ask, "*.env.example": allow}`. The docs claim `.env` is **denied** by default; the source says **ask** [docs:https://opencode.ai/docs/permissions/].

**Evaluation:** rules are flattened in order and the **last match wins**. No match → `ask` [source:…/src/permission/index.ts:28-37]. Merge order per agent: defaults → built-in agent rules → top-level `permission` → `agent.<name>.permission` → session rules [agent.ts:138-178,267-293]. A tool whose last matching rule is `deny` with pattern `*` is **removed from the model's tool list** [permission/index.ts:204-216]. Keys: `read, edit (write/patch/apply_patch), glob, grep, list, bash, task, skill, lsp, question, webfetch, websearch, external_directory, doom_loop, todowrite, plan_enter/exit` plus MCP tool names [docs:https://opencode.ai/docs/permissions/; source]. `OPENCODE_PERMISSION` (JSON) is merged last; invalid JSON is ignored with a warning [config.ts:559-565]. Legacy `tools: {x: false}` maps to `deny` [config.ts:567-578].

**What happens on "ask" in `run` (v1):**

| Mode | Behaviour | Evidence |
|---|---|---|
| default | stderr `! permission requested: <perm> (<patterns>); auto-rejecting` → reply `reject` (also rejects other pending asks of that session). The tool fails with `RejectedError`, **and the agent loop stops** (`blocked`) unless `experimental.continue_loop_on_deny: true` | [run.ts:791-811; permission/index.ts:121-140; processor.ts:200-201,647,694] |
| `--auto` | every ask → `once` (approve). Explicit `deny` is still enforced. That approves `.env` reads, `external_directory` and `doom_loop` | [run.ts:275,795-799; docs:https://opencode.ai/docs/permissions/] |
| explicit `deny` | `DeniedError` goes back to the model as a tool error; the loop **continues** | [permission/index.ts:72-78] |
| question tool | denied for run sessions (session rules) | [run.ts:431-449] |
| v2 | reject **with feedback** ("This non-interactive run cannot ask…"), and the model continues; questions are cancelled with feedback | [source:…@v2.1.0:packages/cli/src/run/noninteractive.ts:70-75,159-187] |

**Recommendation:** never rely on "ask". Write a complete explicit ruleset (allow or deny for everything) in the generated config and run **without** `--auto`. Then any surviving ask is a bug signal: grep stderr for `auto-rejecting` → classify it as a blocked or permission failure.

**Reviewer (read-only) role:** the built-in `plan` agent is **not read-only**. It denies `edit` except `.opencode/plans/*.md` and `$XDG_DATA_HOME/opencode/plans/*.md` (**it can still write those plan files**), but it inherits `bash: allow` [agent.ts:156-180]. The docs say edit/bash are `ask` for plan, which contradicts the source [docs:https://opencode.ai/docs/agents/]. A top-level `permission` (for example from the user's global config) is merged **after** plan's built-in rules and can re-enable edit. Define a dedicated agent instead:

```jsonc
"agent": {
  "reviewer": { "mode": "primary", "description": "read-only reviewer", "steps": 60,
    "permission": { "*": "deny", "read": {"*": "allow", "*.env": "deny", "*.env.*": "deny"},
      "grep": "allow", "glob": "allow", "list": "allow",
      "bash": { "*": "deny", "git diff*": "allow", "git log*": "allow", "git show*": "allow", "git status*": "allow" },
      "external_directory": "deny", "webfetch": "deny", "websearch": "deny", "task": "deny" } }
}
```

Bash allow patterns are matched against parsed commands (tree-sitter) [source:…/src/tool/shell.ts:262-290]. Pattern bypass resistance is unverified.

## 8. Sandboxing

- **None.** There is no seatbelt, bubblewrap, landlock or container isolation in v1.19.3 or v2.1.0 (no such source files) [local-run: tree listing at both tags]. Issue #2242 "Is there a way to sandbox the agent?" and #48411 "Better execution permissions and sandboxing" are open [local-run: gh issue search]. "Sandbox" in OpenCode UI terms means a git-worktree workspace, not isolation. Third-party ecosystem plugins (e.g. "opencode-sandbox") exist [verified by fact-check 2026-10-20: npm `opencode-sandbox` 0.6.0, described as a plugin that sandboxes agent commands via seatbelt/bubblewrap]. The repo's own `SECURITY.md` states that OpenCode does not sandbox the agent and that the permission system is not a sandbox (second primary source).
- The only guards are permission rules plus the `external_directory` check on bash commands and file tools. The plugin rule "unsandboxed harnesses only inside a git tree" applies unchanged. The bash tool runs as the user with full env (§6).

## 9. Config/state isolation and side effects

**Config sources, merged in order (later wins; `instructions` arrays are concatenated)** [source:…@v1.19.3:packages/opencode/src/config/config.ts:328-610; …/config/paths.ts; docs:https://opencode.ai/docs/config/]:

1. Remote `.well-known/opencode` (only for wellknown auth entries)
2. Global `$XDG_CONFIG_HOME/opencode/{config.json,opencode.json,opencode.jsonc}` (+ legacy TOML)
3. `OPENCODE_CONFIG` file
4. Project `opencode.json(c)` walking up from `--dir` to the worktree root (skipped with `OPENCODE_DISABLE_PROJECT_CONFIG=1`)
5. Directories: **global config dir (always)**, project `.opencode/` dirs, `~/.opencode`, then `OPENCODE_CONFIG_DIR` (**additive**). Each one contributes `agents/`, `commands/`, `plugin(s)/*.{ts,js}`, and its `opencode.json` where it is `.opencode`/`OPENCODE_CONFIG_DIR`
6. `OPENCODE_CONFIG_CONTENT` (inline JSON)
7. Console org config (active account)
8. Managed dir `/Library/Application Support/opencode` (macOS), `/etc/opencode` (Linux), `%ProgramData%\opencode`
9. macOS MDM plist `ai.opencode.managed` (highest)
10. `OPENCODE_PERMISSION`

**Other inputs that leak into a dispatch:**

| Input | Default | Disable |
|---|---|---|
| Global instructions `$CONFIG/opencode/AGENTS.md`, else `~/.claude/CLAUDE.md` | on | `OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1` / `OPENCODE_DISABLE_CLAUDE_CODE=1`; isolate `XDG_CONFIG_HOME` [source:…/session/instruction.ts:60-69] |
| Project `AGENTS.md`, `CLAUDE.md`, `CONTEXT.md` (walk up) | on | `OPENCODE_DISABLE_CLAUDE_CODE` drops `CLAUDE.md`; `OPENCODE_DISABLE_PROJECT_CONFIG=1` drops all project files |
| Skills `~/.claude/skills`, `~/.agents/skills` (+ project `.claude`/`.agents`) | on | `OPENCODE_DISABLE_EXTERNAL_SKILLS=1` (both) or `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` [source:…/src/skill/index.ts:21-23,186-201] |
| Global/project plugins (`plugin` config, `plugin(s)/` dirs) | on | `OPENCODE_PURE=1` / `--pure` [source:…/src/plugin/index.ts:181] |
| MCP servers from config | on | isolated config |
| Provider env vars | on | env allowlist + `enabled_providers` |

**On this machine** [local-run]: `~/.config/opencode/{tui.json, plugins/orca-opencode-status.js, plugins/orca-opencode-status-tui/}` (dated 2026-10-07; apparently installed by Orca) would auto-load into every non-isolated dispatch. `~/.claude/skills` (firecrawl-*, agterm, …) and `~/.agents/skills` exist. `~/.claude/CLAUDE.md` does not exist. `~/.local/share/opencode` does not exist.

**Isolation recipe (per profile `P`):** run with `env -i` plus an allowlist (`PATH`, `HOME`, `LANG`, `TMPDIR`, `SHELL`, `TERM=dumb`), and set:
`XDG_CONFIG_HOME=$S/P/config XDG_DATA_HOME=$S/P/data XDG_CACHE_HOME=$S/P/cache XDG_STATE_HOME=$S/P/state OPENCODE_CONFIG=$S/P/opencode.json OPENCODE_DISABLE_PROJECT_CONFIG=1 OPENCODE_PURE=1 OPENCODE_DISABLE_CLAUDE_CODE=1 OPENCODE_DISABLE_EXTERNAL_SKILLS=1 OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_CLIENT=superpowers-dispatch` (+ `OPENCODE_DISABLE_DEFAULT_PLUGINS=1` unless the profile uses Codex/Copilot OAuth).
`HOME` stays real (git/ssh need it), so `~/.opencode` would still be scanned; it does not exist here. Setting `HOME` to a temp dir is stronger but breaks git identity. The `xdg-basedir` defaults fall back to `$HOME/.config` etc. when the XDG vars are unset [source:…@v1.19.3:packages/core/src/global.ts:1-40].

**Side effects observed in source (v1.19.3):**

| Effect | Where | Control |
|---|---|---|
| Writes `"$schema"` into **any loaded config file lacking it**, including a project `opencode.json` | config.ts:245-249 | wrapper-generated config already contains `$schema`; `OPENCODE_DISABLE_PROJECT_CONFIG=1` |
| Creates the global `opencode.json` if missing (skipped when `OPENCODE_CONFIG`/`_DIR`/`_CONTENT` is set) | config.ts:260-271 | set `OPENCODE_CONFIG` |
| For each config dir: writes `.gitignore` and **npm-installs `@opencode-ai/plugin@<version>`** (Arborist, network) into it, in the background. That includes a repo's `.opencode/` | config.ts:438-471; core/npm.ts:86-133 | isolated config home (one install per profile per version); disable project config |
| Writes the project id to `<git-common-dir>/opencode` | core/project.ts:41,125 | none (inside `.git`, untracked) |
| Shadow-git snapshots under the data dir | snapshot/index.ts:71 | `"snapshot": false` |
| Models catalog fetch every 60 min | core/models-dev.ts:255-257 | `OPENCODE_DISABLE_MODELS_FETCH=1` (+ `OPENCODE_MODELS_PATH`) |
| Update check: **TUI only**; since v1.19.0 updates are **never auto-installed** | cli/upgrade.ts:6-37; cli/cmd/tui.ts:76-82; release v1.19.0 | `autoupdate:false` / `OPENCODE_DISABLE_AUTOUPDATE=1` |
| LSP servers and formatters: **off unless config sets `lsp`/`formatter`** (true or object). LSP binary downloads when enabled | format/index.ts:118-127; lsp/lsp.ts:151-161; lsp/server.ts (`disableLspDownload`) | omit keys; `OPENCODE_DISABLE_LSP_DOWNLOAD=1` |
| Session sharing: **discontinued in v1.19.1** (`share` throws; `--share` is hidden/deprecated) | share/session.ts:18-26; release v1.19.1 | n/a |
| Telemetry: OTLP export only when `OTEL_EXPORTER_OTLP_ENDPOINT` is set; AI-SDK spans only with `experimental.openTelemetry` | core/flag/flag.ts:15-16; agent.ts:376-390 | keep `OTEL_*` out of env. No other analytics SDK found in the files read [medium confidence] |
| Logs | `$XDG_DATA_HOME/opencode/log/` | per-profile data dir |

## 10. Concurrency and cancellation

- **Ports:** `run` (no `--attach`) talks to `Server.Default().app.fetch` in-process, so no listener is opened [run.ts:938-951]. `serve` default `--port 0` means "try 4096, else random free port" [source:…/src/server/server.ts:118-122; …/cli/network.ts]. Parse `opencode server listening on http://…` from stdout. The SDK's `createOpencodeServer` defaults to an explicit `--port=4096` (conflicts) [source:…@v1.19.3:packages/sdk/js/src/v2/server.ts:21-35].
- **Shared state between concurrent runs in one profile:** the SQLite DB (WAL, 5 s busy timeout), the models cache (flock), npm-install locks (flock under `$XDG_STATE_HOME`), and the snapshot gitdir per worktree. The plugin's per-workspace reservation lock still applies; separate worktrees are fine.
- **Process tree:** `node` shim (npm installs) → native `opencode` → bash-tool commands spawned with **`detached: true`** (own process group/session on POSIX) + MCP/LSP children [source:…/src/tool/shell.ts:293-310; bin/opencode:8-42]. **Killing the job's process group does not reach bash-tool children.** With no SIGTERM handler in the run path, they are orphaned. Cancellation must (a) snapshot the descendant tree (`ps -A -o pid,ppid,pgid`) before signalling, (b) SIGTERM the group and every descendant pgid, (c) after the grace period, SIGKILL. With the server transport: `POST /session/:id/abort` first. Abort interrupts the stream and kills shell handles (`forceKillAfter 3s`) [shell.ts:540-556].
- **Shell timeout:** default 2 min per bash call (`OPENCODE_EXPERIMENTAL_BASH_DEFAULT_TIMEOUT_MS`) [shell.ts:347].
- **Hidden long stalls:** retries honour `retry-after`/`retry-after-ms` up to 2^31-1 ms with **max 5 retries**. With no headers, the delay is ≤30 s exponential [source:…/src/session/retry.ts:26-31,47-75,183-205]. A long `retry-after` (quota reset) can park a run for hours, and retry status is **not** emitted in `run --format json`. The wrapper needs its own wall-clock timeout (reuse `TIMEOUT_MIN`). Provider header and chunk timeouts default to 300 s [core/v1/config/provider.ts].
- **v2:** the shared background service owns sessions and tool execution, so per-job env/XDG isolation and kill semantics do not apply to it. `--standalone` spawns a private `opencode serve --stdio --port 0` child (random basic-auth password, env inherited, lease ends on stdin EOF) [source:…@v2.1.0:packages/cli/src/services/standalone.ts:13-31]. Open issues at time of writing include a service busy loop (#56712, closed), MCP children not killed (#57341), and unbounded session resume on startup (#57371) [local-run: gh issue search].

## 11. Error signatures for classification

| Plugin class | Signals (v1) | Evidence |
|---|---|---|
| `auth` | `error.name == "ProviderAuthError"`; `APIError` with `statusCode` 401/403; message "Unauthorized: request was blocked by a gateway…"; `ProviderInitError` → "Failed to initialize provider \"X\". Check credentials and configuration." | [source:…@v1.19.3:packages/core/src/v1/session.ts:48-68; …/provider/error.ts:58-66; …/cli/error.ts] |
| `quota` | `APIError` 429 or body containing `insufficient_quota` → "Quota exceeded. Check your plan and billing details."; `usage_not_included` (ChatGPT plan); OpenCode Go `GoUsageLimitError` / `FreeUsageLimitError` ("Free usage exceeded, subscribe to Go"). **429 is retried up to 5×** before the final error | [provider/error.ts:111-130; session/retry.ts:10-11,99-140] |
| rate limit (transient) | the retry regex `/429\|rate limit\|too many requests\|overloaded\|…/` fires `session.status{type:"retry"}` (visible via SSE only) | [retry.ts:33-41] |
| `model-not-selected` / not found | stderr "Model not found: p/m … Did you mean …", exit 1 (`ProviderModelNotFoundError`); `NoProvidersError` / `NoModelsError` when no `-m` and nothing configured; **agent typo = silent fallback + stderr warning** | [cli/error.ts; provider.ts:2056-2061; run.ts:592-606] |
| network | messages matching `fetch failed\|ECONNREFUSED\|ETIMEDOUT\|socket hang up…` (retried); `ProviderHeaderTimeoutError` "Provider response headers timed out after Nms"; `ProviderResponseStreamError` | [retry.ts:37; provider/error.ts:7-19] |
| context overflow | `ContextOverflowError` ("Input exceeds context window of this model" for `context_length_exceeded`). Not retried. Auto-compaction normally prevents it; z.ai "can accept overflow silently" (comment); Z.ai overflow classification was added in v1.17.15 | [core/v1/session.ts:64-67; provider/error.ts:31,111-116; retry.ts:87] |
| content filter | `ContentFilterError` "The response was blocked by the provider's content filter" | [prompt.ts:1299-1307] |
| aborted | `MessageAbortedError` | [core/v1/session.ts:50] |
| blocked (plugin-specific) | stderr `permission requested: … auto-rejecting` + exit 0 + no final text | [run.ts:801-809] |
| `malformed` | exit 0 but no `text` event / empty last message / line 1 not a token | plugin rule |
| `crash`/`launch` | non-zero exit with no `error` event; spawn ENOENT; "Config file at … is not valid JSON(C)"; "Configuration is invalid…" | [cli/error.ts] |

## 12. Structured output / verdict support

- The CLI has **no** JSON-schema flag. The plugin's line-1 token convention works unchanged (prompt-level).
- The HTTP API/SDK accepts `format: {type:"json_schema", schema, retryCount?}` on the prompt body. The model is forced (`toolChoice: required`) to call a `StructuredOutput` tool. Failure → `StructuredOutputError{message, retries}` [source:…@v1.19.3:packages/opencode/src/session/prompt.ts:82,1243-1314,1500-1520]. The result field in the v1 message schema is **`structured`** (`AssistantMessage.structured`) [source:…/schema/src/v1/session.ts:482]. The SDK docs say `info.structured_output` and also mention `outputFormat` (doc inconsistency) [docs:https://opencode.ai/docs/sdk/].
- The prompt body also takes `system` (an extra system prompt), `agent`, `model {providerID, modelID}`, `variant`, `noReply` [prompt.ts:1500-1520]. That is useful for injecting the role preamble without touching the user prompt.

## 13. Usage and cost reporting

- Per step: `step_finish.part.cost` (USD) and `tokens{total?, input, output, reasoning, cache{read, write}}` in the JSON stream. Per message: `info.cost` and `info.tokens` via `export` or the API [schema/src/v1/session.ts:240-256,471-483].
- Cost is computed from catalog prices (`cost.input/output/cache_read/cache_write`, `context_over_200k` tier). Subscription and plan providers often list 0, and custom providers default to 0 unless `cost` is configured [source:…/provider/provider.ts:1600-1607].
- `opencode stats [--days N] [--models] [--project]` aggregates usage from the DB [docs:https://opencode.ai/docs/cli/].
- Retry attempts and title or compaction calls are billed but not shown as `step_finish` of the main stream (title uses the small model).

## 14. ToS notes (brief; full matrix is another report)

- Anthropic: the OAuth plugin was removed in v1.3.0. The docs say Anthropic "explicitly prohibits" Pro/Max plugins [docs:https://opencode.ai/docs/providers/]. API keys only.
- ChatGPT Plus/Pro: built in. It uses OpenAI's Codex OAuth client id with `originator: opencode` and UA `opencode/<ver>` (truthful client identity, borrowed client id) [source:…/plugin/openai/codex.ts:10-12,99,561-562]. Policy acceptability is for the ToS researcher.
- GitHub Copilot: built in, device flow, OpenCode's own GitHub OAuth app id [source:…/plugin/github-copilot/copilot.ts:9].
- Z.ai Coding Plan: OpenCode documents it as a first-class `/connect` option [docs:https://opencode.ai/docs/providers/]. The plugin's current rule "GLM only through Z.ai's own harness" would forbid this route unless the policy changes (whether Z.ai lists OpenCode as a permitted tool: [unverified]).
- OpenCode Go: asks ("should") that a client send its own UA and a stable `x-opencode-session` header [corrected 2026-10-20: https://opencode.ai/docs/go/ phrases these as "Your client should", not a hard requirement]; OpenCode sends session-identity headers since v1.18.34 [docs:https://opencode.ai/docs/go/; release v1.18.34].
- Provider attribution headers sent by OpenCode: `X-Title: opencode`, `X-Source`, etc. for gateways [provider.ts:505-541].

## 15. Gotchas

1. **v1 vs v2 under one command name.** `brew install opencode` (core) gives v2; `opencode-ai` npm and the anomalyco tap give v1. Doctor must check `opencode --version` major [installation/index.ts:314-326].
2. **An auto-rejected permission ends the run early with exit 0 (v1)**, so a missing final text must be classified, not trusted.
3. **`--auto` also approves `.env` reads and out-of-tree paths.** Use explicit allow/deny rules instead.
4. **Agent typo → silent fallback to `build`** (full write access) with only a stderr warning. Treat that warning as fatal for reviewer jobs.
5. **`plan` is not read-only** (bash allowed; it can write plan markdown files). The docs disagree with the source.
6. **`OPENCODE_CONFIG_DIR` does not isolate.** Global config, plugins and `AGENTS.md` still load. Use XDG vars.
7. **Env-var provider auto-activation** (`GITHUB_TOKEN` → Copilot, one `ZHIPU_API_KEY` → 4 providers).
8. **Bash tool sees the full env**, so secrets passed via env are model-readable.
9. **Config loader rewrites files** (`$schema` injection) and npm-installs into `.opencode/` dirs. That dirties a repo that has an `.opencode/` without the generated `.gitignore`.
10. **`--attach` breaks exit codes and event draining**; `--port` on `run` is a no-op.
11. **Retry with server `retry-after` can stall for hours**, invisible in `run` JSON. Enforce a wall-clock timeout.
12. **Bash children are detached process groups**: group-kill is insufficient.
13. **Docs lag source:** `.env` default (deny vs ask), plan permissions, `structured_output` vs `structured`, `autoupdate` wording, the stale Claude Pro/Max step.
14. Free `opencode/*-free` models were reportedly throttled from datacenter IPs since 2026-10-17 (issue #56719, closed) [local-run: gh issue search]. Do not use free models for probes.
15. The first run per profile/version triggers an npm install (network). `doctor` should warm it, otherwise the first job is slower.

## 16. Adapter sketch for this plugin (`bin/opencode-dispatch` → `bin/lib/opencode-dispatch.mjs`)

Reuse the zcode-dispatch skeleton (job records, sticky terminal claim, workspace reservation, boot-id reaper, env allowlist, redaction, timeout → group kill, 7-class `errorClass`) [see 00-current-architecture.md §1]. OpenCode-specific mapping (v1):

| Verb | Mapping |
|---|---|
| **profile config** | `profiles/<name>.json` (user-edited, no secrets): `{provider spec or catalog id, model, variant, agentRole→permission preset, timeoutMin}`. The wrapper renders `$S/<name>/opencode.json` with `$schema`, `enabled_providers:[id]`, `model`, `small_model` (same provider), `autoupdate:false`, `snapshot:false`, `share:"disabled"`, `instructions:[]`, no `lsp`/`formatter`/`mcp`/`plugin`, explicit `permission`, `agent.implementer` + `agent.reviewer`, and `provider.<id>.options.apiKey: "{file:$S/<name>/key}"` (0600) or an `auth.json` in the profile data dir |
| `api-key <profile> set\|clear` | user-only, key from stdin → profile key file or `auth.json` (never argv, never chat) |
| `task --background --profile P [--role implementer\|reviewer] [--resume-task ID\|--fresh] --prompt-file F --cwd W` | require a git tree (implementer) → reserve the workspace (skip for reviewer if the read-only preset is enforced) → spawn a detached runner → `opencode run --format json --title <jobId> --agent <role> -m <provider/model> [--variant v] [-s <sessionID>] --dir <W> < F` with the isolated env (§9). Record `pid`, `pgid`, `sessionID` (first JSONL line), `appVersion` (`opencode --version`). Print `OpenCode Task started in the background as oc-NNNN` |
| `status` | reaper + record. Optional progress: count `step_finish`, last `tool_use.part.tool`, summed cost/tokens from `events.jsonl` |
| `result` | completed → final text (last assistant message's text parts; fallback `opencode export <sessionID>` in the same env). Validate that `providerID/modelID` in the export equals the profile (family rule; no silent fallback) |
| exit → status | exit 0 + non-empty final text + no `auto-rejecting` on stderr → `completed`. Exit 0 + `auto-rejecting` → `failed/permission` (map to `crash` or a new `blocked` class). Exit 0 + empty text → `malformed`. Exit 1 → classify the last `error` event (§11), then the stderr tail. Wall-clock timeout → `timeout`. Spawn failure → `launch` |
| `cancel` | sticky `cancelled` → snapshot the descendant tree → SIGTERM the job pgid + descendant pgids → 5 s → SIGKILL (bash children are detached groups) |
| `resume` | `completed` + stored `sessionID` + same profile (provider/model) → `-s <sessionID>`. A failed/cancelled job → require `--fresh` (consistent with the GLM rule) |
| `doctor [--probe]` | `opencode --version` (major must be 1; warn on 2) → `opencode debug config` (secrets redacted) in profile env: assert `plugin` empty, no MCP, the `enabled_providers` match, the permission preset is present → `opencode models <provider>` contains the model → `opencode auth list` shows the provider (prints no values). `--probe`: one PONG run (`--title probe`, 120 s timeout); this hits the paid endpoint, so only on explicit invocation |
| `release-stale` | identical to ZCode |

**Server transport (optional v2 of the adapter):** `opencode serve --hostname 127.0.0.1 --port 0` per job (or per profile) with a random `OPENCODE_SERVER_PASSWORD` → `POST /session` `{title, permission:[…rules]}` → `GET /event` (SSE: `session.status` idle/retry, `session.error`, `permission.asked`, `message.part.updated`) → `POST /session/:id/prompt_async` `{parts, agent, model:{providerID,modelID}, variant, system?, format?}` → `GET /session/:id/message` for the final message → cancel = `POST /session/:id/abort` + close the server. Directory selection via the `x-opencode-directory` header [source:…@v1.19.3:packages/opencode/src/server/routes/instance/httpapi/groups/session.ts:29-60; …/groups/permission.ts:11-31; …/sdk/js/src/v2/client.ts:50-73; docs:https://opencode.ai/docs/server/]. Gains: retry visibility, graceful abort, per-session rules, schema verdicts. Cost: an SSE client in the runner and a long-lived listener per job.

**If v2 is targeted:** always `--standalone` (never the shared service), `-m p/m#variant`, no `--dir` (chdir in the runner), password env `OPENCODE_PASSWORD`, and a different reject semantics (the model continues, so policy violations show up only as tool errors).

## 17. Sources

| Source | Version / date |
|---|---|
| github.com/anomalyco/opencode @ `v1.19.3`: `packages/opencode/src/cli/cmd/run.ts`, `…/cli/cmd/{serve,providers,export,session}.ts`, `…/cli/{error,network,ui,upgrade}.ts`, `…/src/index.ts`, `…/config/{config,paths,variable,managed,plugin}.ts`, `…/auth/index.ts`, `…/agent/agent.ts`, `…/permission/index.ts`, `…/session/{prompt,processor,retry,overflow,instruction}.ts`, `…/provider/{provider,error}.ts`, `…/tool/shell.ts`, `…/tool/shell/id.ts`, `…/plugin/index.ts`, `…/plugin/openai/codex.ts`, `…/plugin/github-copilot/copilot.ts`, `…/skill/index.ts`, `…/snapshot/index.ts`, `…/share/session.ts`, `…/server/{server,auth}.ts`, `…/server/routes/instance/httpapi/groups/{session,permission,event}.ts`, `…/lsp/lsp.ts`, `…/format/index.ts`, `…/cli/cmd/debug/{config,redact}.ts`, `packages/opencode/bin/opencode`, `packages/opencode/script/build.ts`, `packages/core/src/{global,models-dev,npm,project,observability}.ts`, `packages/core/src/flag/flag.ts`, `packages/core/src/database/database.ts`, `packages/core/src/v1/session.ts`, `packages/core/src/v1/config/{config,provider,lsp,formatter}.ts`, `packages/schema/src/v1/session.ts`, `packages/sdk/js/src/v2/{server,client}.ts` | tag 2026-10-16 |
| same repo @ `v2.1.0`: `packages/cli/src/commands/commands.ts`, `…/commands/handlers/{run,serve,service/start}.ts`, `…/run/{run,noninteractive,v1}.ts`, `…/services/{server-connection,standalone}.ts`, `packages/util/src/global.ts`, `packages/core/src/database/migration/20260805200742_import_legacy_credentials.ts`, `packages/cli/package.json` | tag 2026-10-20 |
| GitHub releases (all 881, v0.0.45 → v1.19.3), esp. v1.3.0, v1.17.12, v1.18.20, v1.19.0–v1.19.3 | fetched 2026-10-20 |
| npm registry: `opencode-ai` (latest 1.19.3), `@opencode/cli` (latest 2.1.0, 2026-10-20T07:15Z), `@opencode-ai/sdk` (latest 1.19.3) | fetched 2026-10-20 |
| https://models.opencode.ai/api.json (231 providers) | fetched 2026-10-20 |
| Docs: https://opencode.ai/docs/ , /docs/cli/ , /docs/server/ , /docs/sdk/ , /docs/config/ , /docs/providers/ , /docs/permissions/ , /docs/agents/ , /docs/models/ , /docs/rules/ , /docs/go/ , /docs/zen/ , https://opencode.ai/v2/docs/cli/ | "Last updated Oct 19, 2026" where shown |
| GitHub issues: #2242, #48411, #52184, #56712, #57341, #57371, #56719, #50916 | state as of 2026-10-20 |
| Local machine: `which opencode` (absent); `ls ~/.config/opencode`, `~/.claude/skills`, `~/.agents/skills`, `~/.local/share/opencode` | 2026-10-20 |

### Open questions

- Exact exit code and final events when v1 stops on an auto-rejected permission. It is inferred as exit 0; it needs one local run with a stub provider (for example, a local OpenAI-compatible mock).
- Whether an invalid `--variant` is ignored silently or errors.
- Whether Z.ai coding-plan quota errors (code 1308 etc.) arrive as 429 with a `retry-after` header. If yes, the run can stall up to the reset time.
- Robustness of bash allow-patterns (tree-sitter parsing) against obfuscated commands, for the reviewer preset.
- The OpenCode 2 roadmap for the v1 line: how long `opencode-ai` 1.x keeps receiving releases now that Homebrew Core moved to v2.
- Whether any analytics exist beyond OTLP in code paths not read here (TUI/desktop).

## Fact-check log (2026-10-20)

Method: every key claim re-opened at the primary source (GitHub API / raw files at tags `v1.19.3` and `v2.1.0` of `anomalyco/opencode`, npm registry, formulae.brew.sh, `anomalyco/homebrew-tap`, opencode.ai docs pages fetched raw, `models.opencode.ai/api.json`, local `ls`/`getconf`). Nothing was installed or executed; OpenCode is absent on this machine, so runtime behaviour (exit codes) stays a source reading.

| Claim | Verdict | Evidence |
|---|---|---|
| Repo `anomalyco/opencode`, `sst/opencode` redirects, MIT, org Anomaly (anoma.ly) | confirmed | `gh api repos/sst/opencode` → full_name anomalyco/opencode, license MIT; `gh api orgs/anomalyco` |
| ~218k stars, ~29k forks, pushed 2026-10-20 | confirmed | `gh api repos/anomalyco/opencode`: 218351 / 29163 / 2026-10-20T11:29Z |
| "~3.8k open issues" | corrected | 3783 is `open_issues_count` (issues+PRs); search: 2617 open issues, 1163 open PRs |
| v1.19.3 GitHub release 2026-10-16; npm `opencode-ai@latest` 1.19.3; `@opencode-ai/sdk` 1.19.3 | confirmed | releases API (2026-10-16T12:31Z); `npm view` dist-tags/time |
| "15 releases between 2026-08-28 and 2026-10-16" | corrected | 16 (v1.18.24 and v1.18.25 both dated 2026-08-28) |
| 881 GitHub releases, v0.0.45 → v1.19.3, none for v2 | confirmed | paginated releases API (881 tags, 0 starting `v2`) |
| `@opencode/cli` 2.1.0 published 2026-10-20T07:15Z; 34 `v2.*` tags, v2.0.0 on 2026-09-11; no release object for v2 | confirmed | `npm view @opencode/cli time`; `git/matching-refs/tags/v2.` = 34; `releases/tags/v2.1.0` and `v2.0.0` → 404 |
| Issue #52184 about missing v2 release notes | confirmed | title "changelog: v2 releases have no published release notes", closed 2026-10-20 |
| Homebrew Core `opencode` = OpenCode 2; v1 via `anomalyco/tap` or npm | confirmed | formulae.brew.sh/api/formula/opencode.json stable 2.1.0; tap `opencode.rb` version 1.19.3; installation/index.ts@v1.19.3 comment "Homebrew Core's opencode formula is OpenCode 2" |
| v1 offers v2 "only through `opencode upgrade --major`" | corrected | release notes v1.19.0/v1.19.2: `opencode upgrade --major` or the TUI `/update` 2.0 offer |
| "can't be installed side by side" (quote) | corrected | docs text: "cannot be installed side by side under their default command" |
| `@opencode/cli` ships `opencode` + `opencode2` bins | confirmed | packages/cli/package.json@v2.1.0; `npm view @opencode/cli bin` |
| v1 run flags (`--format json`, `--variant`, `--dir`, `--title`, `-s`, `--fork`, `-c`, `--command`, `--attach`, `-p/-u`, `--thinking`, `--auto` + hidden `--yolo`/`--dangerously-skip-permissions`) | confirmed | run.ts@v1.19.3 lines 126-263 |
| `--port` declared but never read | confirmed | no `args.port` reference in run.ts@v1.19.3 |
| No `--attach` → in-process fetch shim `http://opencode.internal`, no listener | confirmed | run.ts@v1.19.3 lines 938-951 |
| JSONL shape `{type,timestamp,sessionID,…}`; types step_start/step_finish/text/tool_use/error/reasoning(--thinking) | confirmed | run.ts@v1.19.3 `emit()` line 668 and loop 692-790 |
| step_finish `cost` + `tokens{total?,input,output,reasoning,cache{read,write}}`; message field `structured` | confirmed | packages/schema/src/v1/session.ts@v1.19.3 lines 240-256, 482 |
| Warnings and agent-fallback messages go to stderr | confirmed | cli/ui.ts `println`/`print` write to `process.stderr` |
| Argv prompt "joined with spaces" | corrected | argv elements containing a space are wrapped in `"…"` (run.ts lines 289-291) |
| Empty message → "You must provide a message or a command", exit 1 | confirmed | run.ts line 422 |
| `-f` local = `file://` (dirs allowed), attach = data URL ≤10 MiB | confirmed | run.ts lines 358-414 |
| Unknown/subagent `--agent` falls back to default with a warning | confirmed | run.ts lines 585-609 |
| "ask" in run mode is auto-rejected with stderr `! permission requested: … auto-rejecting`; `--auto` replies `once` | confirmed | run.ts lines 791-811 |
| A reject stops the v1 loop unless `experimental.continue_loop_on_deny` | confirmed | processor.ts@v1.19.3 lines 200-201, 647, 694; permission/index.ts reply() |
| Blocked run exits 0 | unverifiable | consistent with source (no `session.error` on the blocked path), but not executed; report already labels it inference |
| Default ruleset `"*": "allow"`, doom_loop/external_directory ask, `.env` ask; docs say `.env` deny | confirmed | agent.ts@v1.19.3 lines 119-135; docs/permissions "`.env` files are denied by default" |
| Last match wins; no match → ask; `*`-deny hides tool | confirmed | permission/index.ts lines 28-37, 204-216; docs/permissions |
| `plan` agent denies edit except plan files, bash stays allow; top-level `permission` merged after; docs say ask | confirmed | agent.ts lines 156-180; docs/agents "By default, all of the following are set to ask" |
| `OPENCODE_CONFIG_DIR` additive; global config dir always included | confirmed | config/paths.ts `directories()`; config.ts loop 430-480; docs/config ("loaded after the global config") |
| `OPENCODE_DISABLE_PROJECT_CONFIG`, `_CLAUDE_CODE`, `_CLAUDE_CODE_PROMPT`, `_CLAUDE_CODE_SKILLS`, `_EXTERNAL_SKILLS`, `_DEFAULT_PLUGINS`, `_LSP_DOWNLOAD`, `_AUTOUPDATE`, `_MODELS_FETCH`, `OPENCODE_PURE`, `OPENCODE_CLIENT`, `OPENCODE_DB`, `OPENCODE_PERMISSION` exist | confirmed | packages/core/src/flag/flag.ts and effect/runtime-flags.ts@v1.19.3; docs/cli env table |
| `--pure` sets `OPENCODE_PURE=1`; pure drops config/dir plugins | confirmed | src/index.ts lines 62-71; plugin/index.ts line 181 |
| Global `AGENTS.md`, else `~/.claude/CLAUDE.md`; `~/.claude/skills` + `~/.agents/skills` | confirmed | session/instruction.ts lines 60-69, 115-120; skill/index.ts lines 21-23, 186-201 |
| Catalog env var auto-enables a provider; bash env = full `process.env` + plugin `shell.env` | confirmed | provider.ts lines 1636-1646; tool/shell.ts lines 415-424 |
| Catalog rows (ids, SDK, base URLs, env vars; 231 providers) | confirmed | models.opencode.ai/api.json fetched 2026-10-20 |
| Model ids and variants (glm-5.3 low/high/max; deepseek-v4-pro toggle+low/high/max; kimi-for-coding none/low/high/max; MiniMax-M3.1-Flash low…max) | confirmed | same catalog, `reasoning_options` |
| Local: Orca plugin in `~/.config/opencode/plugins` (2026-10-07), skills dirs present, no `~/.claude/CLAUDE.md`, no `~/.local/share/opencode`, no `opencode` binary | confirmed | `ls`, `test -e`, `which` |
| `auth.json` mode 0600; `OPENCODE_AUTH_CONTENT` replaces the file read, undocumented | confirmed | auth/index.ts lines 10, 59-64, 79, 88; absent from docs/cli and docs/config |
| `auth` is an alias of `providers`; `auth list` prints env var names only | confirmed | cli/cmd/providers.ts lines 240-296 |
| Anthropic OAuth plugin removed in v1.3.0 (2026-03-22), PR #18186 | confirmed | release v1.3.0 notes; PR #18186 "anthropic legal requests" |
| Docs: "Anthropic explicitly prohibits this", "no longer the case as of 1.3.0", stale Claude Pro/Max step, "select Z.AI Coding Plan" | confirmed | docs/providers raw text (verbatim) |
| Built-in plugins: Codex, Copilot, Modal, GitLab, Poe, Cloudflare×2, Azure, DigitalOcean, Snowflake, xAI, Cerebras; none for Anthropic | confirmed | plugin/index.ts lines 67-86 |
| Codex OAuth uses OpenAI's Codex client id, `originator: opencode`, UA `opencode/<ver>` | confirmed | plugin/openai/codex.ts lines 10, 99, 478, 561-562; same id as `CLIENT_ID` in openai/codex `codex-rs/login/src/auth/manager.rs` |
| Copilot device flow with its own client id | confirmed | plugin/github-copilot/copilot.ts line 9 (`Ov23li…`), line 21 device code URL; app ownership not independently checked |
| OpenCode Go $10 / Go Plus $40; 5h 20% / weekly 50% | confirmed | docs/go raw text |
| Go clients "must identify themselves…" | corrected | docs/go: "Your client should" … "Identify itself with its own user agent" |
| Zen/Console auto-reload $20 below $5 | confirmed | docs/zen raw text |
| No native sandbox in v1.19.3 / v2.1.0; bash spawned `detached: true` | confirmed | tree listings at both tags; code search (no seatbelt/bwrap/landlock); repo SECURITY.md "does not sandbox the agent"; shell.ts line 308 |
| Issues #2242, #48411 open; #56712, #56719, #50916 closed; #57341, #57371 open | confirmed | issues API |
| "opencode-sandbox" plugin exists | confirmed | `npm view opencode-sandbox` 0.6.0 |
| Retry: 5 retries, retry-after(-ms) honoured up to 2^31-1 ms, ≤30 s without headers | confirmed | session/retry.ts lines 26-31, 47-75, 183-205 (30 s cap applies only when the error carries no response headers at all) |
| Default bash timeout 2 min; abort/timeout kill with `forceKillAfter 3s` | confirmed | shell.ts lines 347, 540-556 |
| SQLite path, WAL, `busy_timeout=5000`, `OPENCODE_DB` | confirmed | packages/core/src/database/database.ts |
| Models cache 5 min TTL, 60 min refresh, cross-process flock | confirmed | packages/core/src/models-dev.ts lines 160-257 |
| `serve --port 0` tries 4096 then random; SDK `createOpencodeServer` passes `--port=4096` | confirmed | server/server.ts lines 116-122; cli/network.ts; sdk/js/src/v2/server.ts lines 21-35 |
| Header/chunk timeouts default 300000 ms | confirmed | core/v1/config/provider.ts lines 124-140 |
| Config side effects (`$schema` write, global file creation, `.gitignore` + npm install of `@opencode-ai/plugin` per config dir) | confirmed | config.ts lines 244-249, 260-271, 450-471 |
| Managed config dirs and MDM domain `ai.opencode.managed` | confirmed | config/managed.ts |
| Error strings (quota, auth gateway, provider init, model not found, header timeout, context overflow) | confirmed | provider/error.ts, cli/error.ts |
| Release notes cited (v1.17.15 Z.ai overflow, v1.18.20 subagent permissions, v1.18.34 session headers, v1.19.1 sharing discontinued, v1.19.3 reasoning variants) | confirmed | releases API |
| v2 `run`: `--standalone`/`--server`, `-m p/m#variant`, `-f` ≤100 data URLs ≤10 MiB, no `--variant/--dir/--attach/--command/--port` | confirmed | commands.ts@v2.1.0 run spec; run/run.ts `prepareFile` |
| v2 shared background service by default; standalone = `serve --stdio --port 0`, random password, inherited env, stdin lease | confirmed | services/server-connection.ts, services/standalone.ts@v2.1.0; opencode.ai/v2/docs/cli |
| v2 password env `OPENCODE_PASSWORD` | confirmed | packages/cli/src/env.ts@v2.1.0 (falls back to `OPENCODE_SERVER_PASSWORD`) |
| v2 `-s` wording | corrected | verbatim "Session ID to continue, or to create if it does not exist" |
| v2 reject-with-feedback and continue; exit 130 on interrupt; pre-session `{"type":"error","sessionID":""}` | confirmed | run/noninteractive.ts lines 70-75, 159-187, 534, 678-680; run/run.ts `reportRunError` |
| v2 `auth export` prints secrets; `auth login --answer` | confirmed | commands.ts@v2.1.0 auth spec |
| SDK docs use `info.structured_output` and `body.outputFormat` | confirmed | docs/sdk raw text |
| macOS `ARG_MAX` ≈ 1 MiB | confirmed | `getconf ARG_MAX` = 1048576 |

**Additional source findings (not in the report, source reading only, not executed):**
1. In v1, a provider `context_length_exceeded` publishes `session.error` even when auto-compaction then recovers (processor.ts@v1.19.3 lines 621-631). `run` accumulates every main-session `session.error` and sets exit 1 (run.ts lines 771-780, 829-833). A run that compacts and then finishes can therefore exit 1 with a valid final text. The adapter's "exit 1 → failed" mapping should check for a final text after the last `error` event.
2. Piped stdin is read only when stdin is not a TTY, and `Bun.stdin.text()` waits for EOF (run.ts line 417). The runner must close stdin (or redirect from a file, as recommended), or `run` hangs.
3. `OPENCODE_TEST_HOME` overrides OpenCode's own `home` (packages/core/src/global.ts@v1.19.3, also v2.1.0), which drives `~/.claude/CLAUDE.md`, `~/.claude/skills`, `~/.agents/skills` and `~/.opencode` lookup, without changing `HOME` for git. It is an undocumented test hook, so do not rely on it without pinning.
4. `~/.claude/CLAUDE.md` is a fallback: it is loaded only when `$XDG_CONFIG_HOME/opencode/AGENTS.md` is absent (instruction.ts lines 115-120). The bottom-line wording "merges … `~/.claude/CLAUDE.md`" is accurate for this machine, which has no global `AGENTS.md`.

**Reliability assessment:** high. Every code-level claim I checked matched the cited tag, usually at the cited line numbers: flags, event types, permission defaults and reject semantics, config-dir additivity, env flag names, retry constants, the auth store, the plugin list, the v2 run spec and the standalone service. Catalog data, npm/Homebrew versions, dates and issue states also matched their primary sources. Of the ToS and docs quotes, the Anthropic and Z.ai quotes were verbatim. The corrections are small: two quotes were paraphrased inside quotation marks (the side-by-side install line, and the OpenCode Go client guidance, which says "should", not "must"), plus a release count, an open-issue count, the v2 `-s` description, the v1→v2 upgrade routes, and a missed argv-quoting detail. The one material open item, the exit code of a v1 run stopped by an auto-rejected permission, is correctly labelled as inference. It needs one local run, which this fact-check could not do without installing OpenCode.
