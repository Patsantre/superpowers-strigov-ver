# 04b — DeepSeek Harness (`dsh`, the user's "DSH"): deep dive for a dispatcher adapter

Researcher key: `04b-deepseek-harness`. Date: 2026-10-20. Read-only research. Sources were read through `gh api` (repo contents at a release tag), `npm view`, official DeepSeek API docs and arXiv. Nothing was installed or run, and no model endpoint was called.

Evidence tags: `[local-run]`, `[source:<repo>@<ref>:<path>]`, `[docs:<url>]`, `[third-party:<url>]`, `[unverified]`.

Abbreviations:
- **`DSH@rc2`** = `deepseek-ai/deepseek-harness@dsh-v0.2.1-rc.2`, the latest release (2026-10-17). Every `source:` tag without another repo uses this.
- **PI@1.1.0** = `earendil-works/pi@v1.1.0`, which provides `@earendil-works/pi-ai`, the library that dsh embeds.

This report goes deeper than the sibling survey `04-dsh-and-harness-survey.md` and corrects some of the leads.

## Bottom line

1. **Identity.** DSH is the official, MIT-licensed `deepseek-ai/deepseek-harness`. Its npm package is `@deepseek-ai/dsh`; the `latest` tag is the prerelease `0.2.1-rc.2`. It is a **developer preview**: every release is a prerelease, breaking changes are announced, and there was no security audit. It runs on macOS, Linux and Windows and needs Node `^22.19 || >=24`.
2. **Headless contract.** It is usable today: `dsh --profile headless --patch <wrapper.yml> --json - < prompt`.
   - Output is NDJSON events: `session`, then `status`/`text`/`thinking`/`tool_call`/`tool_result`, then a lossless `final`.
   - Exit codes: 0 means a turn completed, 1 means anything else.
   - `--session-id` resumes a session (same cwd only).
   - There are no model or effort flags. These are set in a YAML patch (`agent-default-model`, `llm-deepseek`).
3. **Unattended permissions fail closed.** Base profiles start in `workspace-write` with approval `ask`. Headless has no approval answerer, so every escalation is denied (`unavailable`). `DSH_PERMISSION_MODE=read-only` gives a real read-only reviewer: Seatbelt on macOS, bwrap/Landlock on Linux.
   - Reads and network access are never confined.
   - `danger-full-access` (or the `sdk-minimal` profile) is fully unconfined.
4. **Providers.** dsh is multi-provider, not DeepSeek-only.
   - A native DeepSeek route speaks Anthropic Messages to `api.deepseek.com/anthropic`. Models: `deepseek-flash` (V4.1 Flash), `deepseek-v4-pro`. Effort levels: `off|low|high|max`; the default is `high`.
   - The embedded pi-ai catalog has 42 providers (Anthropic, OpenAI, Z.ai coding endpoint, Kimi, MiniMax, Qwen token plans, OpenRouter and others).
   - Custom OpenAI Chat, OpenAI Responses or Anthropic Messages endpoints are supported, including local servers.
   - DeepSeek has **no subscription plan**. The optional "DeepSeek account" sign-in bills the same pay-as-you-go Platform wallet as an API key, and headless ignores it by default.
5. **The adapter must neutralize these defaults:**
   - **Session-log upload.** By default dsh uploads the full canonical session log to whatever `baseURL` the DeepSeek route uses (`dsh_session_log`, up to 8 MiB per request). That log includes tool arguments and results, file contents and the cwd. A plugin-package inventory and a stable anonymous user-id header are sent too.
   - **Endpoint override from the repo.** A target repo's `.env` can override `DEEPSEEK_BASE_URL`, which would send the user's key and logs elsewhere. Pin `baseURL` explicitly.
   - **Shared skills and instructions.** dsh reads the shared `~/.agents` root (this machine has 4 skills there) and project `AGENTS.md`/`CLAUDE.md`.
   - **SIGTERM exits 0.**
   - **Orphaned tools on macOS.** Tool subprocesses run in detached process groups, so a hard kill can leave orphans.
6. **Claude Code compatibility is opt-in and narrow.** By default dsh does not read `~/.claude` or the repo's `.claude/`. Hooks run only if `@deepseek-ai/dsh-hooks-claude-code` is installed and pointed at one `hooks.json`, and that bridge supports 7 of 30 events. This plugin's own hooks therefore **cannot leak into a dispatched run** unless someone wires that up deliberately.
7. **Transport choice.**
   - Use the **headless CLI** for v1. It is one process per job and maps 1:1 onto the zcode-dispatch job runner.
   - Use the **ACP server** (`dsh --profile acp`) for the future "guarded" mode. It is the only transport with a programmatic permission broker (`session/request_permission`) and an in-band `session/cancel`.
   - Skip the **JSON-RPC SDK** for job running. It has no cancel, no per-prompt result and no approval flow.
8. **Cost lever.** Reasoning effort is the main one. An arXiv study on dsh 0.1.0rc7 measured −74.7% cost from tuning effort alone, with the same 15/15 success. Pin effort per role and disable the extra session-title LLM call.

---

## 1. Identity

| Field | Value | Evidence |
|---|---|---|
| Name | DeepSeek Harness, CLI `dsh`, "Everything is a Plugin" | [source:DSH@rc2:README.md] |
| Repo | `github.com/deepseek-ai/deepseek-harness`, default branch `master`, TypeScript | [local-run: `gh api repos/deepseek-ai/deepseek-harness`] |
| License | MIT; third-party notices in `THIRD_PARTY_NOTICES.md` | [source:DSH@rc2:README.md] [local-run: gh api] |
| Maintainer | DeepSeek-AI. npm maintainers: `imccyu`, `tianyicui-deepseek <tianyi@deepseek.com>` | [local-run: `npm view @deepseek-ai/dsh --json`] |
| Framework | Cordis (`@deepseek-ai/cordis ~4.0.5`), described in arXiv 2608.25512 (Peking Univ. + DeepSeek-AI, 2026-08-26) | [source:DSH@rc2:README.md] [docs:https://arxiv.org/abs/2608.25512] |
| Created / first publish | Repo created 2026-08-13T11:56Z. First npm publish was `0.0.1-rc.1` on 2026-08-10, then `0.1.0-rc.2/.3/.6` on 2026-08-13 (the "developer preview" launch) | [local-run: gh api; npm view time] |
| Latest | npm `latest` = `next` = `0.2.1-rc.2` (2026-10-17T08:36Z); `alpha` = `0.2.1-alpha.5`. GitHub release `dsh-v0.2.1-rc.2` (2026-10-17). **Every GitHub release is marked prerelease** | [local-run: npm view; `gh api .../releases`] |
| Cadence | 36 npm versions in about 10 weeks, the 0.1.x then 0.2.x lines. 22,395 commits, 44 contributors, last push 2026-10-17 | [local-run: gh api commits/contributors] |
| Popularity | About 255k stars, about 30.8k forks. Issues are **disabled**; feedback goes through GitHub Discussions and Discord | [local-run: gh api] [source:DSH@rc2:README.md] |
| Status | "developer preview … THERE WILL BE COMPATIBILITY-BREAKING CHANGES"; SAFETY.md says it is not security-audited | [source:DSH@rc2:README.md] [source:DSH@rc2:SAFETY.md] |
| OS | Sandbox backends exist for Linux (bwrap, then Landlock), macOS (Seatbelt) and Windows (ACL restricted token) | [source:DSH@rc2:packages/sandbox/sandbox-local/README.md] |
| Native addon | Prebuilt `@deepseek-ai/node-addon-system` packages for darwin-arm64/x64 and linux-x64/arm64; it provides the session `flock` | [local-run: `npm view @deepseek-ai/node-addon-system`] |
| Python SDK | `deepseek-harness-sdk`, a wheel bundling the runtime. Platforms: Linux x64/arm64, macOS 14+ arm64, Windows x64 | [source:DSH@rc2:docs/user/guide/python-sdk.md] |
| Node | Root `engines.node: ^22.19.0 \|\| >=24.0.0`. This machine has Node v26.11.1 | [source:DSH@rc2:package.json] [local-run: `node --version`] |
| Surfaces (profiles) | `web` (UI on 127.0.0.1:3080), `headless`, `sdk` (stdio JSON-RPC), `sdk-minimal`, `acp` (stdio ACP); `desktop` is reserved. A TUI is **out-of-tree only** (example `github:deepseek-harness/turtle-ui`) | [source:DSH@rc2:docs/cli-help.md] [source:DSH@rc2:apps/cli/reference/README.md] |
| Docs site | `deepseek-harness.github.io/deepseek-harness/`, a JS-rendered site that could not be fetched; the repo `docs/` folder is the primary source | [docs:https://deepseek-harness.github.io/deepseek-harness/] |
| Listed by DeepSeek | The API docs sidebar "Agent Integrations" lists DeepSeek Harness first, then Claude Code, Codex, OpenCode and others | [docs:https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code] |
| Local status | Not installed (`dsh not found`). **Name collision:** Homebrew formula `dsh` 0.25.10 is "Dancer's shell" | [local-run: `which -a dsh`; `brew info dsh`] |

**Lead corrections.**
- The ACP server is "automation-only" and deliberately omits editor/UI features (modes, plans, terminals, elicitation). It is not an editor integration.
- The hooks bridge exists but is opt-in.
- The cost paper uses dsh only in an appendix, with Claude Sonnet 5 as the model.

## 2. Headless invocation

| Item | Detail | Evidence |
|---|---|---|
| Command | `dsh --profile headless [--patch <yml>]... [--json] [--session-id <id>] [task... \| -]`; the shorthand is `dsh headless "…"` | [source:DSH@rc2:docs/cli-help.md] |
| Argument grammar | Launcher flags (`--profile`, `--patch`, `--from-default-profile`, `--dump-*`) come first. The first unrecognized token starts the app args (`--json`, `--session-id`, task). The launcher consumes one `--` | [source:DSH@rc2:apps/cli/reference/README.md] |
| Prompt transport | Positional words joined by spaces, or stdin when the task is omitted or is a lone `-`. A positional task means stdin is **not** read. A piped task is sent verbatim, trailing newline included. A blank positional or an empty pipe is a usage error and exits 1 | [source:DSH@rc2:packages/bundle/headless/README.md] |
| Size limits | No dsh-specific limit is documented. Argv is bounded by OS `ARG_MAX`, so **use stdin**. The model side is bounded by context: 1M tokens for DeepSeek models | [docs:https://api-docs.deepseek.com/quick_start/pricing/] [unverified: no explicit dsh prompt cap] |
| Model/effort selection | **No CLI flags.** Use a `--patch` overlay on the `agent-default-model` row (`provider`, `model`, `reasoningEffort`) and on the adapter row (`llm-deepseek` / `llm-pi-ai`) | [source:DSH@rc2:docs/config-catalog.md] [source:DSH@rc2:packages/bundle/base/cordis.patch.yml] |
| Layer order | Bundle patches, then `$DSH_HOME/profiles/headless/cordis.patch.yml`, then `$DSH_HOME/cordis.patch.yml` (home layer outranks profile), then each `--patch` in argv order. A row patch **replaces the row's whole `config`** and does not deep-merge | [source:DSH@rc2:apps/cli/reference/README.md] |
| Workspace | The invoking cwd is the workspace root and the `workspace-write` boundary (`sandbox-policy.workspaceRoot = process.cwd()`) | [source:DSH@rc2:packages/bundle/base/cordis.patch.yml] |
| First use | The `headless` profile auto-initializes from the shipped template (`dsh-base` + `dsh-headless`, startup-only patches, HMR off). `--dump-config` also initializes missing profile files without booting | [source:DSH@rc2:apps/cli/reference/README.md] |
| Ports/servers | Headless opens **no** listening port and mounts no web server or browser | [source:DSH@rc2:packages/bundle/headless/README.md] |
| Must use launcher | Booting the headless profile another way fails, because only the launcher can request exit | [source:DSH@rc2:packages/bundle/headless/README.md] |

Example (v1 adapter):

```sh
cd "$WORKTREE" && env -i PATH=... HOME=... TMPDIR=... DSH_HOME=$WRAP/home DSH_AGENTS_HOME=$WRAP/agents-empty \
  DSH_TELEMETRY_DISABLED=1 DSH_PERMISSION_MODE=workspace-write DEEPSEEK_API_KEY=… \
  dsh --profile headless --patch "$JOB/dsh.patch.yml" --json - < "$JOB/prompt.md" > "$JOB/events.ndjson" 2> "$JOB/stderr.log"
```

## 3. Output and final-message extraction

**Default mode:**
- stdout holds only the final assistant text.
- stderr carries `dsh: reasoning:` sections that stream provider reasoning deltas, plus `dsh: <code>: <message>` on failure.
- A run with no assistant message prints an empty line and exits 1.

[source:DSH@rc2:packages/bundle/headless/README.md]

**`--json` mode (use this).** stdout is NDJSON and stderr keeps only `dsh:` diagnostics. The event set comes from [source:DSH@rc2:packages/bundle/headless/src/json-stream.ts]:

| `type` | Fields | Notes |
|---|---|---|
| `session` | `sessionId`, `cwd` | Always first. It is the **only place the new session id appears** |
| `status` | `phase: turn_start\|step_start\|step_end\|turn_end`, `turn`, `step`; `step_end` adds `usage{inputTokens,outputTokens,totalTokens?,cacheReadTokens?,cacheWriteTokens?,reasoningTokens?}`; `turn_end` adds `reason` | `usage` is omitted if any retried attempt lacked a sample. `reason.kind ∈ completed\|aborted\|blocked\|error{error:{code,message}}\|max-tokens\|interrupted` ([source:DSH@rc2:docs/subsystems/session.md]) |
| `text` / `thinking` | `text` | Emitted when the step's assistant message commits, not per token; retried or discarded attempts never appear |
| `tool_call` | `callId`, `tool`, `input` | Malformed argument JSON keeps its raw text |
| `tool_result` | `callId`, `status: completed\|error`, `result` | Only `append` results; compaction replays are skipped |
| `final` | `text` | Lossless and **not capped**; same as the default stdout |
| `error` | `message` | Runner failure outside a turn, or usage error. **No `final` follows** |

**Caps.** Every string except `final` is capped at 8 KiB, with a `truncated` flag. Each line is capped at 32 KiB, and nesting is cut at depth 64.

**Exit codes:**
- 0: final `turn/end` is `completed`.
- 1: anything else (aborted, error, blocked, max-tokens, no turn), usage errors, plugin load failures.
- 130: SIGINT.
- **0 on SIGTERM.**
- An in-turn failure still ends with `final` (often empty) and no `error` event, so **treat exit 1 plus `turn_end.reason` as the failure signal**.

[source:DSH@rc2:packages/bundle/headless/README.md] [source:DSH@rc2:apps/cli/src/profile-boot.ts]

**Boot failures.** A required-plugin activation failure prints a report and `Full diagnostics: $DSH_HOME/logs/startup-<ts>-<uuid>.log`, then exits 1 before any `session` event. Values in that log are **not redacted**. [source:DSH@rc2:apps/cli/reference/README.md]

## 4. Sessions and resume

| Item | Detail | Evidence |
|---|---|---|
| Id | `session-<uuid>` by default; opaque. The new id appears only in the `--json` `session` event. An unknown id passed to `--session-id` is an error, so the caller cannot preassign a fresh id | [source:DSH@rc2:packages/bundle/headless/README.md] |
| Resume | `dsh --profile headless --json --session-id <id> "continue"` adopts the persisted session. It refuses a session recorded in **another cwd**, with no cwd, a subagent or fork session, a preset this profile does not compose, or one live in-process | [source:DSH@rc2:packages/bundle/headless/README.md] |
| Storage | `$DSH_HOME/sessions/--<normalized-cwd>--/<encoded-id>/session.v<N>.jsonl.zstd` (zstd checksummed frames by default; `compression: none` gives raw JSONL) | [source:DSH@rc2:packages/session/session-persistence-jsonl/README.md] [source:DSH@rc2:packages/bundle/base/cordis.patch.yml] |
| Locking | One writer per session: in-process claim plus non-blocking `flock(2)` on `session.lock`. A crashed holder's lock dies with it | [source:DSH@rc2:packages/session/session-persistence-jsonl/README.md] |
| Crash repair | A resumed log whose last turn never ended gets a synthetic `turn/end {kind:'interrupted'}` | [source:DSH@rc2:docs/subsystems/session.md] |
| Other surfaces | SDK: `session/resume {sessionId}`. ACP: `session/list`, `session/resume`, `session/close` (no `session/load`, fork or delete) | [source:DSH@rc2:packages/sdk/server/README.md] [source:DSH@rc2:packages/acp/acp/README.md] |
| Background-job caveat | In headless, final background-job settlement may be absent from the persisted history because teardown can close the writer first | [source:DSH@rc2:packages/bundle/headless/README.md] |

## 5. Model and provider selection

**Two adapters.** Both are mounted in every base profile and can coexist. [source:DSH@rc2:packages/bundle/base/cordis.patch.yml]

| Adapter (row id) | Route(s) | Protocol | Notes |
|---|---|---|---|
| `llm-deepseek` (`@deepseek-ai/dsh-llm-deepseek-api-key`) | `deepseek-official` | Anthropic **Messages** only; `protocol` is not configurable | `baseURL` precedence: explicit config, then `$DEEPSEEK_BASE_URL` from **any** launch layer, including the repo `.env`, then `https://api.deepseek.com/anthropic`. Model ids pass through. Default catalog: `deepseek-flash` (text+image) and `deepseek-v4-pro` (text), each with a 1M context window. Defaults: `maxTokens` 256,000, `streamIdleTimeoutMs` 300,000, retry "normal, 5" [source:DSH@rc2:packages/llm/llm-deepseek/README.md] [source:DSH@rc2:packages/llm/llm-deepseek/src/config.ts] |
| `llm-deepseek-account` | `deepseek-account` | Messages with `x-dsh-auth-token` | Catalog from `GET https://api.deepseek.com/models`, version-gated (`CLIENT_UPGRADE_REQUIRED`). Never falls back to an API key [source:DSH@rc2:packages/llm/llm-deepseek-account/README.md] |
| `llm-pi-ai` (`@deepseek-ai/dsh-llm-pi-ai`, wrapping `@earendil-works/pi-ai ^1.1.0`) | Any key in `providers:` | `openai-completions`, `openai-responses`, `anthropic-messages` for custom routes; catalog routes keep their native protocol (Bedrock, Vertex, Azure, Codex reachable via catalog) | Dormant until `providers` is set [source:DSH@rc2:packages/llm/llm-pi-ai/README.md] [source:DSH@rc2:packages/llm/llm-pi-ai/src/provider.ts] |

**Default model.**
- Base row: `agent-default-model: {provider: deepseek-official, model: deepseek-flash}` [source:DSH@rc2:packages/bundle/base/cordis.patch.yml].
- The ACP bundle instead uses `deepseek-v4-flash`, a **retired legacy alias** that DeepSeek routes to V4.1 Flash and bills at the Flash price [source:DSH@rc2:packages/bundle/acp-app/cordis.patch.yml] [docs:https://api-docs.deepseek.com/].

**Current DeepSeek API models** (official pricing page, fetched 2026-10-20) [docs:https://api-docs.deepseek.com/quick_start/pricing/]:

| Model id | Served by | Context / max out | Vision | Concurrency/account | USD per 1M tokens (off-peak / peak): cache-hit in, cache-miss in, out |
|---|---|---|---|---|---|
| `deepseek-flash` | DeepSeek-V4.1-Flash-1017 | 1M / 384K | yes | 2,500 | 0.003/0.006, 0.15/0.3, 0.6/1.2 |
| `deepseek-v4-pro` | DeepSeek-V4-Pro-0813 | 1M / 384K | no | 500 | 0.022/0.044, 0.66/1.32, 1.98/3.96 |

Peak hours are Mon–Fri 01–04 and 06–10 UTC; off-peak rates are half. Legacy `deepseek-v4-flash` / `deepseek-v4-flash-vision-exp` are still accepted but routed to V4.1 Flash. [docs:https://api-docs.deepseek.com/quick_start/pricing/]

**Reasoning effort:**
- **dsh on the DeepSeek route** offers `off | low | high | max`; the default `reasoningEffort` is `high`.
- `thinking: disabled` locks the route to `off`.
- `off` sends `thinking.type: disabled`. Other levels send `output_config.effort`.
- An unsupported value fails pre-network with `UNSUPPORTED_REASONING_EFFORT`.

[source:DSH@rc2:packages/llm/llm-deepseek/README.md] [source:DSH@rc2:docs/user/guide/providers.md]

**DeepSeek API side:**
- Thinking is on by default with default effort `high`.
- OpenAI format: `reasoning_effort` `low|high|max`. Anthropic format: `output_config.effort`.
- Mapping: `minimal→low`, `medium→high`, `xhigh→high`, `ultra→max`.
- Tool-call turns must pass `reasoning_content` back.

[docs:https://api-docs.deepseek.com/guides/thinking_mode]

**Where effort is set.** Per run, use `agent-default-model.reasoningEffort` or `llm-deepseek.reasoningEffort`. For pi-ai routes, use the per-model `reasoningEfforts` map (wire spelling) plus the route `reasoning` default, and `compat.thinkingFormat: deepseek` for V4 behind OpenAI-compatible gateways. [source:DSH@rc2:docs/user/guide/providers.md]

**Custom endpoints:**
- **OpenAI-compatible:** `api: openai-completions`. Common fixes are `compat.supportsDeveloperRole: false` and `compat.maxTokensField: max_tokens`. Model discovery uses `GET {baseURL}/models`.
- **Responses:** `api: openai-responses`; `supportsMaxOutputTokens: false` is available.
- **Anthropic-compatible:** `api: anthropic-messages`, discovered via `GET /v1/models`.

[source:DSH@rc2:packages/llm/llm-pi-ai/README.md] [source:DSH@rc2:docs/user/guide/providers.md]

**Local models:**
- A pi-ai custom route works with a local `baseURL` such as an OpenAI-compatible server on 127.0.0.1. A keyless local server still needs a placeholder `apiKeyEnv` or an `Authorization` header.
- `thinkingTokenBudgetField` and `vllmPriority` are available for self-hosted Chat Completions.
- Loopback always bypasses the proxy.
- On this 16 GB machine, only small local models are practical [unverified: no local model test].

[source:DSH@rc2:packages/llm/llm-pi-ai/README.md] [source:DSH@rc2:docs/user/guide/network-proxy.md]

**Example wrapper patch (DeepSeek, implementer):**

```yaml
- id: agent-default-model
  config: { provider: deepseek-official, model: deepseek-v4-pro, reasoningEffort: high }
- id: llm-deepseek
  config: { apiKeyEnv: DEEPSEEK_API_KEY, baseURL: https://api.deepseek.com/anthropic, reasoningEffort: high }
- id: session-log-deepseek
  config: { enabled: false }
- id: plugin-package-inventory-deepseek
  config: { enabled: false }
- id: session-title-llm
  disabled: true
```

The row ids come from [source:DSH@rc2:apps/cli/composition.md]. Exact field acceptance is to be confirmed with `--dump-config` [unverified: not executed].

## 6. Auth and credentials

| Topic | Detail | Evidence |
|---|---|---|
| DeepSeek API key | Env `DEEPSEEK_API_KEY` (row `apiKeyEnv`); sent as `x-api-key`. Web search and fetch reuse the same key | [source:DSH@rc2:packages/llm/llm-deepseek-api-key/README.md] [source:DSH@rc2:packages/bundle/base/cordis.patch.yml] |
| Headless resolution | Headless **disables** the `credentials`, `authorization` and `deepseek-account` rows. Keys come from the inherited env, then `<invocation cwd>/.env`, then `$DSH_HOME/.env`. An exported empty variable shadows the `.env` fallbacks. `.credentials.yaml` is never read or written. Implemented 2026-10-12, so it applies to versions ≥ 0.2.1-alpha.3 | [source:DSH@rc2:packages/bundle/headless/README.md] [source:DSH@rc2:.agents/notes/implemented/architecture/2026-10-12-headless-environment-auth.md] |
| Other profiles (web, sdk, acp) | Stored-first: `$DSH_HOME/.credentials.yaml` (written by the Models page, write-only in the UI), then env and `.env` | [source:DSH@rc2:docs/user/guide/providers.md] [source:DSH@rc2:apps/cli/reference/README.md] |
| DeepSeek account sign-in | Browser OAuth+PKCE against `https://platform.deepseek.com` (default `platformOrigin`). The grant is stored in the credential store. Inference bills the account's **normal and bonus wallets**, so it is pay-as-you-go; a top-up error maps to `ACCOUNT_QUOTA`. Tokens have no expiry or refresh. It needs the web server, so in practice it is web or desktop only | [source:DSH@rc2:packages/credentials/deepseek-account-platform/README.md] [source:DSH@rc2:packages/credentials/deepseek-account-platform/src/index.ts] [source:DSH@rc2:packages/llm/llm-deepseek-account/README.md] |
| Subscription / plan | **None for DeepSeek.** Pricing is per token, deducted from topped-up or granted balance | [docs:https://api-docs.deepseek.com/quick_start/pricing/] |
| pi-ai sign-ins | OAuth or interactive key for any pi-ai provider that ships a login, **except `openai`** (ChatGPT sign-in is deliberately not offered). pi-ai 1.1.0 ships OAuth modules for `anthropic`, `github-copilot`, `kimi-coding`, `meta`, `openai-chatgpt`, `openai-codex`, `openrouter`, `radius`, `xai`. Records are stored at `llm-pi-ai/<provider>` in the store, which **headless ignores** | [source:DSH@rc2:packages/llm/llm-pi-ai/src/login.ts] [source:PI@1.1.0:packages/ai/src/auth/oauth/] |
| Ambient discovery | A pi-ai catalog route with no `apiKeyEnv` falls back to provider-native env variables, e.g. `anthropic`: `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`, …; also AWS and Google ADC files | [source:DSH@rc2:packages/llm/llm-pi-ai/src/provider-data.generated.ts] [source:DSH@rc2:packages/llm/llm-pi-ai/README.md] |
| Isolation | Set `DSH_HOME` to a wrapper-owned directory (it holds profiles, `.credentials.yaml`, `.env`, sessions, logs, `.anonymous-user-id`, `AGENTS.md`, skills). Set `DSH_AGENTS_HOME` to an empty directory (the default `~/.agents` is shared with other tools). Pass the key only via the process env, which outranks every `.env` | [source:DSH@rc2:packages/util/home-paths/README.md] [source:DSH@rc2:packages/util/launch-environment/README.md] |
| Child-process scrub | Subprocesses (bash tool) start from an env with names matching `*KEY*`, `*PASSWORD*`, `*SECRET*`, `*TOKEN*` removed. Differently named secrets pass through | [source:DSH@rc2:packages/subprocess/subprocess-local/README.md] |

**Leak risks:**
1. **Repo `.env` redirects the endpoint.** `DEEPSEEK_BASE_URL` in the target repo's `.env` is honored ("the product trusts the project it is launched in"). The key (`x-api-key`) and the uploaded session log would go to that URL. **Pin `baseURL` in the wrapper patch**; explicit config wins. Proxy variables from a project `.env` are refused: dsh will not start. [source:DSH@rc2:packages/llm/llm-deepseek/src/config.ts] [source:DSH@rc2:docs/user/guide/network-proxy.md]
2. **Reads are unconfined**, so the agent can `cat` any key file it can find, including a wrapper key store on disk. Prefer env injection plus a key file outside obvious paths, or the macOS Keychain read by the wrapper [source:DSH@rc2:apps/cli/reference/README.md].
3. **Logs are unredacted.** Startup diagnostics logs and stderr reasoning are not redacted [source:DSH@rc2:apps/cli/reference/README.md] [source:DSH@rc2:packages/bundle/headless/README.md].
4. **Every layer reaches `process.env`.** All launch `.env` layers are copied into `process.env`; the subprocess scrub is name-based only [source:DSH@rc2:packages/util/launch-environment/README.md].
5. **Proxy credentials leak to tools.** A proxy URL that contains credentials is visible to every tool command [source:DSH@rc2:docs/user/guide/network-proxy.md]. This machine uses TUN mode, so no proxy variables are needed [local-run: task facts].

## 7. Autonomy for unattended runs

| Mechanism | Detail | Evidence |
|---|---|---|
| Knobs | `sandbox/mode` ∈ `read-only \| workspace-write \| danger-full-access` and `approval/policy` ∈ `ask \| never`. Presets: `read-only`(ro+ask), `workspace-write`(ww+ask), `danger-full-access`(dfa+never) | [source:DSH@rc2:packages/bundle/base/cordis.patch.yml] [source:DSH@rc2:docs/subsystems/permission-presets.md] |
| Default | `DSH_PERMISSION_MODE ?? 'workspace-write'`; approval is `never` only when the mode is `danger-full-access`, otherwise `ask` | [source:DSH@rc2:packages/bundle/base/cordis.patch.yml] |
| Unattended asks | Outcomes are closed and fail closed: `allowed-once \| rejected \| cancelled \| unavailable`. With `ask` and **no answerer** (headless and SDK compose none), the outcome is `unavailable`, which means denial. "missing approval support turns `ask` into denial." With `never`, every ask is `rejected` deterministically | [source:DSH@rc2:docs/subsystems/approval.md] [source:DSH@rc2:docs/subsystems/tools.md] [source:DSH@rc2:packages/sdk/protocol/README.md] |
| What asks | A sandbox **escalation**: after a denial, the model may retry the exact command once with `sandbox_permissions` (a wider mode) plus a `justification`, and that retry requests approval. The fs tools (`write`/`edit`) behave the same. Headless therefore never escalates | [source:DSH@rc2:packages/shell/tool-bash/README.md] [source:DSH@rc2:packages/fs/tool-fs/README.md] |
| Never asks | `web_fetch` and `web_search` run in every mode without confirmation (fetch is public destinations only). MCP servers and hooks run unsandboxed when configured. Reads are never gated | [source:DSH@rc2:apps/cli/reference/README.md] |
| Read-only reviewer | `DSH_PERMISSION_MODE=read-only`: bash runs under Seatbelt `(deny file-write*)` except `/dev/null`, and fs `write`/`edit` return `FS_SANDBOX_DENIED`. Optionally disable `tool-web` to remove an exfiltration channel | [source:DSH@rc2:docs/subsystems/sandbox.md] [source:DSH@rc2:packages/fs/fs-sandbox/README.md] |
| Allow/deny lists | No per-tool allowlist knob in shipped config. Tools can be removed by disabling rows (`tool-web`, `tool-bash`, …). A custom plugin can deny on the `tools/pre-execute` waterfall | [source:DSH@rc2:docs/subsystems/tools.md] [unverified: no shipped allowlist config found] |
| Plan mode | `plan-mode` plugin with an `exit_plan_mode` tool. Plan mode is a session mode (not the default); exiting it needs approval, which fails closed in headless | [source:DSH@rc2:packages/bundle/base/cordis.patch.yml] |
| Unconfined profiles | `danger-full-access` bypasses the sandbox provider entirely. The `sdk-minimal` profile **pins `danger-full-access`** and mounts no approval service | [source:DSH@rc2:packages/shell/bash-sandbox/README.md] [source:DSH@rc2:apps/cli/reference/README.md] |
| Broker path | ACP `session/request_permission` (one-shot allow/reject) lets an automation client answer escalations. This is the analogue of the planned "permission broker" | [source:DSH@rc2:packages/acp/acp/README.md] |

## 8. Sandboxing

| Aspect | Detail | Evidence |
|---|---|---|
| Native | Yes. `dsh-sandbox-local`: Linux bwrap (read-only root, fresh `/dev`, private PID namespace), then Landlock. **macOS Seatbelt** via `/usr/bin/sandbox-exec` with profile `(allow default)(deny file-write*)` plus write allow-lists. Windows ACL restricted token, enforcement `partial` | [source:DSH@rc2:packages/sandbox/sandbox-local/README.md] [source:DSH@rc2:packages/sandbox/sandbox-local/src/profiles.ts] [local-run: `/usr/bin/sandbox-exec` present, macOS 26.5.2] |
| Covers | **File writes only**: bash and pwsh subprocesses (OS sandbox) and fs tool mutations (`fs-sandbox` path fence). `workspace-write` allows the session cwd plus temp areas (`/tmp`, `os.tmpdir()`) | [source:DSH@rc2:docs/subsystems/sandbox.md] [source:DSH@rc2:packages/fs/fs-sandbox/README.md] |
| Not covered | Network ("outside this vocabulary"); file reads; process visibility (Seatbelt leaves host processes visible); the dsh Node process itself; MCP servers; hook commands; Claude Code mods ("No sandbox is applied to mods") | [source:DSH@rc2:docs/subsystems/sandbox.md] [source:DSH@rc2:apps/cli/reference/README.md] [source:DSH@rc2:docs/subsystems/claude-code-mods.md] |
| Fail closed | No usable runner gives `SANDBOX_UNAVAILABLE`; it never silently runs unconfined. Runner failure and denial are classified separately (`denialSignatures`, `runnerFailureRules`) | [source:DSH@rc2:packages/sandbox/sandbox-local/README.md] |
| Vendor stance | "Sandboxing, approval prompts, and permission controls can reduce risk, but they do not guarantee isolation"; use a VM or container | [source:DSH@rc2:SAFETY.md] |

Implications for this plugin:
- Git **worktrees** keep metadata outside the worktree (`<main>/.git/worktrees/...`). That is outside the workspace root, so `git commit` from a worktree should be denied under `workspace-write` with no escalation in headless [unverified: inferred from the write fence; test before relying on it].
- Writes to `~/.npm`, `~/.cache` and similar paths are denied too. Point caches into the workspace or `$TMPDIR`.

## 9. Config/state isolation

**What dsh reads by default (base and headless profiles):**

| Source | Path(s) | Disable / redirect | Evidence |
|---|---|---|---|
| Harness home | `$DSH_HOME` or `~/.dsh`: `profiles/<p>/{package.json,cordis.yml,cordis.patch.yml}`, `cordis.patch.yml` (home layer), `.env`, `.credentials.yaml` (not in headless), `sessions/`, `storages/`, `logs/`, `.anonymous-user-id`, `cache/` | `DSH_HOME=<wrapper dir>` | [source:DSH@rc2:packages/util/home-paths/README.md] [source:DSH@rc2:packages/bundle/base/cordis.patch.yml] |
| Instructions | `$DSH_HOME/AGENTS.md`, then `$DSH_AGENTS_HOME/AGENTS.md` (`~/.agents`), then the project chain from the `.git` root down to cwd: `AGENTS.md`, `CLAUDE.md`, then `AGENTS.local.md`, `CLAUDE.local.md`. Budget 65,536 bytes. **Not read:** `~/.claude/CLAUDE.md`, `.claude/rules/`, `@path` imports | Row `agent-instructions` (`disabled: true` or replace `instructionFileCandidates`); `DSH_AGENTS_HOME` | [source:DSH@rc2:packages/context/agent-instructions/README.md] |
| Skills | `<root>/.dsh/skills`, `<root>/.agents/skills`, `customSkillDirs`, `$DSH_HOME/skills`, `$DSH_AGENTS_HOME/skills`, `$DSH_BUNDLED_SKILL_DIR`; watched live. **Not read:** `.claude/skills`, `~/.claude/skills` | `skill-filesystem.includeDefaultRoots: false`, or `DSH_AGENTS_HOME` | [source:DSH@rc2:packages/skill/skill-filesystem/README.md] [source:DSH@rc2:packages/skill/skill-filesystem/src/index.ts] |
| `~/.agents` on this machine | `~/.agents/skills/` has 4 entries (autoglm-browser-agent, notebooklm, orca-cli, orchestration), and these **would load into a dsh run** | Set `DSH_AGENTS_HOME` | [local-run: `/bin/ls ~/.agents/skills`] |
| Claude Code hooks | **Not read by default.** `@deepseek-ai/dsh-hooks-claude-code` (published 0.2.1-rc.2, not installed with the CLI) [corrected 2026-10-20: 0.2.1-rc.2 is the `next` dist-tag. npm `latest` still points to the stale `0.0.1-rc.5`, so an unpinned `dsh plugin add` would install that old build. The same `latest`-is-stale pattern holds for `dsh-hooks-codex`, `dsh-subagent-*` and `dsh-mcp-client` (all `latest: 0.0.1-rc.1`); `npm view <pkg> dist-tags`] must be added via `dsh plugin add` and mounted with an explicit `configPath` to one `hooks.json` or settings file. It supports SessionStart, UserPromptSubmit, PreToolUse (deny/ask only), PostToolUse, Stop, SubagentStart, SubagentStop: 7 of 30 events | Don't install it | [source:DSH@rc2:packages/experimental/hooks-claude-code/README.md] [local-run: `npm view @deepseek-ai/dsh-hooks-claude-code`] |
| Claude Code mods | Experimental `dsh-experimental-claude-code-mods`. `plugin.json`/`hooks.json` are not read; a mod must be wrapped with `defineMod` and mounted | n/a | [source:DSH@rc2:docs/subsystems/claude-code-mods.md] |
| `.claude` anywhere | A code search finds `'.claude'` only in a repo script spec | n/a | [local-run: `gh search code --repo deepseek-ai/deepseek-harness "'.claude'"`] (searches the default branch, not the tag) |
| MCP | `dsh-mcp-client` ships, but **no MCP server is enabled by default**. dsh does not read `.mcp.json` [unverified: none found in docs] | n/a | [source:DSH@rc2:apps/cli/reference/README.md] |
| Repo `.env` | The invocation-dir `.env` is a launch environment layer (credentials, `DEEPSEEK_BASE_URL`; proxy variables are refused) | Pin config; export empty variables to shadow | [source:DSH@rc2:packages/util/launch-environment/README.md] |

**Side effects:**

| Side effect | Default | Control | Evidence |
|---|---|---|---|
| **Session-log upload** `dsh_session_log` | **On.** Each DeepSeek-adapter request carries the unaccepted log suffix (≤ 8 MiB): cwd, system prompts, user and assistant content, tool arguments and results, compaction summaries, feedback. It is sent to the configured `baseURL`, gateways included | `session-log-deepseek: {config: {enabled: false}}` | [source:DSH@rc2:docs/deepseek-llm-api-wire-extensions.md] [source:DSH@rc2:packages/session/session-log-deepseek/README.md] |
| Plugin inventory `dsh_plugin_packages` | On (DeepSeek adapter only) | `plugin-package-inventory-deepseek: {config: {enabled: false}}` | [source:DSH@rc2:packages/llm/plugin-package-inventory-deepseek/README.md] |
| Identity headers | `user-agent`, `x-deepseek-harness-user-id` (stable UUID in `$DSH_HOME/.anonymous-user-id`), `x-deepseek-harness-session-id`, `x-deepseek-harness-compact`. No documented off switch; a per-wrapper `DSH_HOME` scopes the id | Isolated `DSH_HOME` | [source:DSH@rc2:docs/deepseek-llm-api-wire-extensions.md] |
| OTel session telemetry | `FEEDBACK_ONLY`: uploads only after explicit feedback, to `dsh-otel-collector.deepseeksvc.com` | `DSH_TELEMETRY_DISABLED=1` (any non-empty value); `DSH_TELEMETRY_MODE=DISABLED`. Config cannot disable the row | [source:DSH@rc2:packages/bundle/base/cordis.patch.yml] [source:DSH@rc2:apps/cli/reference/README.md] |
| Product analytics | Desktop only | n/a | [source:DSH@rc2:docs/subsystems/product-telemetry.md] |
| Extra LLM call | `session-title-llm` titles each fresh session from the first prompt: one auxiliary request on the same route, ≤ 4,096 input bytes and ≤ 4,096 output tokens. Headless keeps it; ACP and SDK disable it | `session-title-llm: {disabled: true}` | [source:DSH@rc2:packages/bundle/base/cordis.patch.yml] [source:DSH@rc2:packages/session/session-title-first-prompt-llm/README.md] |
| Web tools | `web_search` (DeepSeek Search API; currently free via dsh, **$0.75/1k from 2026-11-01**) and `web_fetch` | Disable `tool-web` | [source:DSH@rc2:packages/bundle/base/cordis.patch.yml] [docs:https://api-docs.deepseek.com/quick_start/pricing/] |
| Auto-updates | None found in the launcher. Plugin installs go through `pnpm` only on `dsh plugin` | n/a | [source:DSH@rc2:apps/cli/src/args.ts] [local-run: grep of CLI sources] |
| Downloads | None at headless runtime. The Python runtime and Office payloads are explicit build-time downloads | n/a | [source:DSH@rc2:packages/skill/tool-workspace-dependencies/README.md] |
| Disk writes | Profile auto-init and session logs under `$DSH_HOME`. Spill files: per-process `0700` directory, completed spills kept | n/a | [source:DSH@rc2:packages/subprocess/subprocess-local/README.md] |

## 10. Concurrency and cancellation

| Topic | Detail | Evidence |
|---|---|---|
| Process model | Headless is one Node process per run, with no ports. Tool commands are children. **On macOS, managed ranges use detached process groups (fallback)**; Linux uses user-systemd scopes; Windows uses Job objects | [source:DSH@rc2:packages/subprocess/subprocess-local/README.md] |
| Signals | First SIGINT or SIGTERM starts graceful disposal (kills managed tool ranges, flushes the session) with a **5 s** bound, then forced exit. A second signal forces an immediate exit. **SIGTERM exits 0**, SIGINT exits 130 | [source:DSH@rc2:apps/cli/src/process-shutdown.ts] [source:DSH@rc2:apps/cli/src/profile-boot.ts] |
| Hard kill | SIGKILL, OOM or a crash skips cleanup, and detached tool groups **survive** ("need an external supervisor") | [source:DSH@rc2:packages/subprocess/subprocess-local/README.md] |
| Locks | Per-session `flock`. **No workspace lock**: two runs in one cwd will race on files, so keep the plugin's per-workspace reservation | [source:DSH@rc2:packages/session/session-persistence-jsonl/README.md] |
| Background jobs | The bash tool promotes long commands to background jobs. Headless waits for child work and settlement before finishing | [source:DSH@rc2:packages/shell/tool-bash/README.md] [source:DSH@rc2:packages/bundle/headless/README.md] |
| Subagents | In-process `subagent` (spawn, model-selectable) and `subagent_fork`. Out-of-process Codex, Claude Code and ACP providers are optional bundles, not installed | [source:DSH@rc2:packages/bundle/base/cordis.patch.yml] [source:DSH@rc2:apps/cli/reference/README.md] |
| ACP | Multiple sessions per connection, one prompt in flight per session. `session/cancel` and `session/close` drain descendants. stdin EOF means bounded shutdown | [source:DSH@rc2:packages/acp/acp/README.md] [source:DSH@rc2:packages/bundle/acp-app/README.md] |
| SDK | **No cancel and no session close**; the only abort is killing the process | [source:DSH@rc2:packages/sdk/protocol/README.md] |
| Provider concurrency | DeepSeek allows 2,500 concurrent requests per account for flash and 500 for pro; beyond that, HTTP 429. Inference that has not started within 10 min closes the connection | [docs:https://api-docs.deepseek.com/quick_start/rate_limit] |

**Recommended cancel sequence:**
1. Snapshot descendants (`ps -o pid,ppid,pgid`).
2. Send SIGINT to dsh.
3. Wait at least 7 s.
4. SIGKILL dsh.
5. `kill -KILL -<pgid>` for each recorded descendant group.
6. Record `cancelled` in the job record, whatever the exit code.

## 11. Error signatures for classification

Read the failure from the `--json` `status.turn_end.reason.error.code` or from the stderr line `dsh: <CODE>: <message>`. Retryable codes (`EMPTY_RESPONSE`, `RATE_LIMIT`, `SERVER`, `TIMEOUT`, `TRANSPORT`) are retried 5 times with 0.5–10 s backoff before they surface. [source:DSH@rc2:packages/llm/llm-retry/README.md] [source:DSH@rc2:packages/bundle/headless/README.md]

| Class (plugin) | dsh code(s) | Source condition | Evidence |
|---|---|---|---|
| auth | `AUTH` (401/403), `MISSING_CREDENTIAL`, `INVALID_CREDENTIAL`, `ACCOUNT_SIGN_IN_REQUIRED`, `ACCOUNT_TOKEN_INVALID` | DeepSeek 401 "Authentication Fails" | [source:DSH@rc2:packages/llm/llm-deepseek/README.md] [source:DSH@rc2:packages/llm/llm-deepseek-account/README.md] [docs:https://api-docs.deepseek.com/quick_start/error_codes] |
| quota/balance | `QUOTA` (API key; HTTP 402 or an in-band SSE error), `ACCOUNT_QUOTA` (account route) | DeepSeek 402 "Insufficient Balance" | [source:DSH@rc2:packages/llm/llm-deepseek-account/README.md] [docs:https://api-docs.deepseek.com/quick_start/error_codes] |
| rate limit | `RATE_LIMIT` (after retries) | 429, concurrency or QPS | [docs:https://api-docs.deepseek.com/quick_start/rate_limit] |
| model-not-selected / not found | `UNKNOWN_MODEL` (pi-ai), `MODEL_UNSUPPORTED`, `CLIENT_UPGRADE_REQUIRED`, `UNSUPPORTED_REASONING_EFFORT`. **`INVALID_REQUEST` (400/422)** for an id the gateway doesn't serve | Ids pass through unvalidated on `deepseek-official` | [source:DSH@rc2:packages/llm/llm-deepseek/README.md] [source:DSH@rc2:docs/user/guide/providers.md] |
| context overflow | `CONTEXT_WINDOW_EXCEEDED`; `turn_end.reason.kind = max-tokens` for an output cap | n/a | [source:DSH@rc2:packages/llm/llm-deepseek/README.md] [source:DSH@rc2:docs/subsystems/session.md] |
| network / server / timeout | `TRANSPORT`, `TIMEOUT` (stream idle 300 s), `SERVER` (5xx), `HTTP_<status>`, `STREAM_CLOSED`, `MALFORMED_RESPONSE`, `EMPTY_RESPONSE` | 500 / 503 overloaded | [source:DSH@rc2:packages/llm/llm-deepseek/README.md] [docs:https://api-docs.deepseek.com/quick_start/error_codes] |
| sandbox infra | `SANDBOX_UNAVAILABLE`, runner-failure line `Runner failure: …` | n/a | [source:DSH@rc2:packages/shell/bash-sandbox/README.md] |
| launch | Exit 1 before any `session` event; stderr contains `Full diagnostics: …/logs/startup-*.log`; refusal of proxy variables from a project `.env`; usage errors (JSON `error` event) | n/a | [source:DSH@rc2:apps/cli/reference/README.md] [source:DSH@rc2:docs/user/guide/network-proxy.md] |
| aborted / cancelled | `turn_end.reason.kind = aborted`; exit 130 (SIGINT) or **0 (SIGTERM)** | n/a | [source:DSH@rc2:apps/cli/src/profile-boot.ts] |
| malformed | Exit 0 but `final.text` lacks the status token on line 1 (a plugin rule) | n/a | n/a |

## 12. Structured output / verdict support

- **No JSON-schema / `--output-schema` mode** in headless, SDK or ACP. `tool_choice` is not mapped either [source:DSH@rc2:packages/llm/llm-deepseek/README.md]. The DeepSeek API itself supports JSON output, but dsh does not expose it [docs:https://api-docs.deepseek.com/quick_start/pricing/].
- The plugin's line-1 status token convention (`DONE`, `DONE_WITH_CONCERNS`, …) works on `final.text`, which is lossless and uncapped.
- For machine-checkable verdicts, the prompt must demand a fenced JSON block, and the wrapper parses it from `final.text`.
- Reasoning arrives in `thinking` events, or on stderr in default mode. Keep it out of the verdict.

## 13. Usage and cost reporting

| What | Where | Evidence |
|---|---|---|
| Tokens | `--json` `status.step_end.usage`: input, output, total?, cacheRead?, cacheWrite?, reasoning?. Retried attempts are included. Omitted if any attempt lacked a sample. Sum across steps for the job | [source:DSH@rc2:packages/bundle/headless/src/json-stream.ts] |
| Cache | DeepSeek cache-hit metrics map to `cacheReadTokens` | [source:DSH@rc2:packages/llm/llm-deepseek/README.md] |
| Money | **Not reported.** The token meter "price" is token pressure, not currency. The wrapper must price tokens with the pricing table, and peak vs off-peak (2×) depends on the request time | [source:DSH@rc2:docs/subsystems/token-meter.md] [docs:https://api-docs.deepseek.com/quick_start/pricing/] |
| Hidden extra calls | Session title (see §9), compaction, web search ($0.75/1k after 2026-11-01), subagents | [source:DSH@rc2:packages/bundle/base/cordis.patch.yml] [docs:https://api-docs.deepseek.com/quick_start/pricing/] |
| Balance | Account route only: `getBalance` (normal and bonus wallets) via Platform; not available in headless | [source:DSH@rc2:packages/credentials/deepseek-account-platform/README.md] |

**arXiv 2608.01347** (Weinberger & Hozez, "Prompt-Induced Waste in Coding Agents", v1 2026-08-02, v6 2026-09-10). The general finding is that efficiency should be measured as cost per successful task, and that prompt, effort and harness interact. [docs:https://arxiv.org/abs/2608.01347]

Its dsh extension (Section 6.1 and Appendix O) [docs:https://arxiv.org/html/2608.01347]:
- **Setup.** dsh **0.1.0rc7**, via the bundled `dsh-jsonrpc-agent` composition, unattended. The model was **Claude Sonnet 5** through a LiteLLM gateway, not DeepSeek. [corrected 2026-10-20: Appendix O describes "a local OpenAI-compatible chain to the first-party Anthropic API" with a body shim, where LiteLLM maps `reasoning_effort` to the Anthropic thinking budget. The model is right; "LiteLLM gateway" simplifies that setup] Five fixtures × 3 repetitions × 5 arms, $20 cap, 600 s timeout.
- **Default behavior.** Wire inspection found the shipped composition "enabled aggressive reasoning on every normal request".
- **Cost per run** (all arms 15/15 success): baseline $0.2753; effort-only $0.0696 (**−74.7%**); full stack $0.0490 (−82.2%). Effort accounts for about 91% of the reduction.
- **Comparison.** Under Claude Code the same effort arm saved only about 19%.

**Takeaway:** pin `reasoningEffort` per role, e.g. `low`/`off` for mechanical edits, `high` for implementation and `max` only for hard review.

## 14. ToS notes

| Topic | Finding | Evidence |
|---|---|---|
| DeepSeek API terms | The Open Platform ToS fetched (release 2026-04-22, effective 2026-04-29) treats programmatic API use as the core grant; there is **no clause against automated or agentic use**. §2.2: keep API keys secret, do not share them, do not expose them client-side. You are responsible for downstream apps and end users (§3.2, §3.3, §7.1). §4.2(3) allows using outputs to train other models. Input-training and retention policy is deferred to the Privacy Policy | [docs:https://cdn.deepseek.com/policies/en-US/deepseek-open-platform-terms-of-service.html] |
| Operator | Hangzhou DeepSeek AI Co. and Beijing DeepSeek AI Co. and affiliates (US ToS variant) [corrected 2026-10-20: the fetched en-US Open Platform ToS (release 2026-04-22) says the platform "is owned and operated by Hangzhou DeepSeek Artificial Intelligence Co., Ltd." and defines that company alone as "DeepSeek". "Beijing" does not appear anywhere; affiliates are mentioned only generically (§7.7)] | [docs:https://cdn.deepseek.com/policies/en-US/deepseek-open-platform-terms-of-service.html] |
| dsh license | MIT; "no warranty or liability" | [source:DSH@rc2:SAFETY.md] |
| Data sharing beyond inference | The default `dsh_session_log` upload sends far more than the prompt: tool outputs, file contents, cwd. Under a strict ToS/privacy posture, **disable it explicitly**. How DeepSeek uses these logs is not documented in the ToS | [source:DSH@rc2:docs/deepseek-llm-api-wire-extensions.md] [unverified: DeepSeek retention/training use of `dsh_session_log`] |
| Multi-provider? | **Yes.** The pi-ai catalog has **42 providers**: amazon-bedrock, ant-ling, anthropic, azure, baseten, cerebras, cloudflare-ai-gateway, cloudflare-workers-ai, deepseek, fireworks, github-copilot, google, google-vertex, groq, huggingface, kimi-coding, meta, minimax(+cn), mistral, moonshotai(+cn), nvidia, openai, openai-codex, opencode, opencode-go, openrouter, qwen-token-plan(+cn, +individual), radius, together, typesafe, vercel-ai-gateway, xai, xiaomi(+3 token-plan regions), zai, zai-coding-cn. Custom OpenAI Chat, Responses or Anthropic Messages endpoints are also supported | [source:DSH@rc2:packages/llm/llm-pi-ai/src/provider-data.generated.ts] |
| Subscription-backed routes in the catalog | `zai` (default base URL is the **GLM Coding Plan** endpoint `api.z.ai/api/coding/paas/v4`), `kimi-coding`, `qwen-token-plan*`, `xiaomi-token-plan*`, `opencode-go`, `github-copilot` (OAuth), `openai-codex` (ChatGPT OAuth), `anthropic` (OAuth or `ANTHROPIC_OAUTH_TOKEN`) | [source:DSH@rc2:packages/llm/llm-pi-ai/src/provider-data.generated.ts] [source:PI@1.1.0:packages/ai/src/auth/oauth/] |
| Plugin policy implication | Restrict dsh dispatch to **API-key routes** (DeepSeek API, or other vendors' API keys whose terms allow third-party harnesses). **Never** route a consumer subscription (Claude Pro/Max OAuth, ChatGPT/Codex OAuth, Copilot) through dsh. Coding-plan endpoints (Z.ai, Kimi, Qwen, Xiaomi) need a per-vendor ToS check before use (see the sibling report `06-providers-and-plans.md`) | [unverified: per-vendor plan terms not re-checked here] |
| Family rule | The model family comes from the **route/model** (`deepseek-official/deepseek-v4-pro` means the DeepSeek family), not from the harness. The job record must store provider and model from the patch | Design note |

## 15. Gotchas

1. **Prerelease only.** The `latest` dist-tag is an `-rc`, and several breaking changes landed within weeks (for example, the headless credential behavior changed 2026-10-12). **Pin an exact version** and re-verify per upgrade [local-run: npm view] [source:DSH@rc2:.agents/notes/implemented/architecture/2026-10-12-headless-environment-auth.md].
2. **Session-log upload on by default**, including to custom DeepSeek-adapter gateways (§9).
3. **The repo `.env` can redirect `DEEPSEEK_BASE_URL`**, taking the key and logs with it. Pin `baseURL` [source:DSH@rc2:packages/llm/llm-deepseek/src/config.ts].
4. **A repo `.env` with proxy variables makes dsh refuse to start.** Classify that as launch [source:DSH@rc2:docs/user/guide/network-proxy.md].
5. **SIGTERM exits 0.** Never infer success from the exit code alone after a cancel [source:DSH@rc2:apps/cli/src/profile-boot.ts].
6. **macOS tool orphans** after a hard kill (detached PGIDs) [source:DSH@rc2:packages/subprocess/subprocess-local/README.md].
7. **The session id is printed only in `--json` mode**, and `--session-id` cannot create an id. Resume must happen in the **same cwd** [source:DSH@rc2:packages/bundle/headless/README.md].
8. **Patches replace a row's whole `config`.** Restate every field you need [source:DSH@rc2:apps/cli/reference/README.md].
9. **`~/.agents` is shared and read by default.** Skills and `AGENTS.md` from other tools leak in. Set `DSH_AGENTS_HOME` [local-run] [source:DSH@rc2:packages/util/home-paths/README.md].
10. **Project `CLAUDE.md` is loaded**, which may suit the target repo but means different instructions than Claude Code sees: no `~/.claude/CLAUDE.md`, no `.claude/rules`, no `@imports` [source:DSH@rc2:packages/context/agent-instructions/README.md].
11. **`workspace-write` is cwd-scoped**, not git-root-scoped. Worktree `.git` metadata and global caches sit outside it, and headless cannot escalate (§8).
12. **The extra title LLM call per session** in headless [source:DSH@rc2:packages/session/session-title-first-prompt-llm/README.md].
13. **Reasoning defaults are high or aggressive**, which drives cost (§13).
14. **The ACP default model is the retired alias `deepseek-v4-flash`.** It is still served, but text-only in the dsh catalog [source:DSH@rc2:packages/bundle/acp-app/cordis.patch.yml] [docs:https://api-docs.deepseek.com/].
15. **`sdk-minimal` is unconfined** (`danger-full-access`, no approvals) [source:DSH@rc2:apps/cli/reference/README.md].
16. **Name collision:** Homebrew `dsh` is Dancer's shell. In `doctor`, check that `dsh --version` returns the expected semver [local-run: brew info dsh].
17. **stderr may hold sensitive reasoning** in default mode, and startup logs are unredacted [source:DSH@rc2:packages/bundle/headless/README.md] [source:DSH@rc2:apps/cli/reference/README.md].
18. **Web fetch/search run without approval in every mode.** Prompt-injection exfiltration is possible. arXiv 2608.16393 measured indirect-injection full success of about 5–6% overall, with **skills 14–16%**, hidden Unicode in files 25.5% and fake-completion 17% [docs:https://arxiv.org/html/2608.16393].

**arXiv 2608.16393** (Ying et al., "Security Assessment of DeepSeek Harness with A.I.G", v1 2026-08-17, v2 2026-08-18):
- **Setup.** DSH commit `47f943859bef` (2026-08-13), model `deepseek-v4-flash`, 14,560 executions, 16 channels × text/file modes, 35 payload objectives, 12 attack methods. Sinks were local fixtures, so sandbox and approval were **not** evaluated.
- **Recommendations:**
  - Keep provenance and trust tier on tool results.
  - Authorize sensitive sinks independently of the model (allowlists, argument checks, approval).
  - Treat skills and integrations as code.
  - Rerun the test matrix after changes.

[docs:https://arxiv.org/abs/2608.16393] [docs:https://arxiv.org/html/2608.16393]

## 16. Adapter sketch for this plugin

**Transport decision:**

| Transport | Job-runner fit | Pros | Cons | Verdict |
|---|---|---|---|---|
| **Headless CLI** `dsh --profile headless --json` | One detached process per job, like the zcode-dispatch runner | Simple; NDJSON events; exit code; resume by id; no ports; fail-closed approvals; ignores the GUI credential store | No in-band cancel (signals only); no escalation broker; session id only from `--json` | **v1** |
| **ACP** `dsh --profile acp` (stdio JSON-RPC, ACP v1, `@agentclientprotocol/sdk` 1.4.0) | A broker process per job (or a pooled one), like the Codex app-server broker | `session/request_permission` for a **guarded permission broker**; `session/cancel`/`close`; `session/set_config_option` (model, reasoning_effort); MCP per session; multi-session | Keeps the stored-first credential store (fine with an isolated `DSH_HOME`); default model is a legacy alias; needs a long-lived broker | **v2 "guarded" mode** |
| **SDK** `dsh --profile sdk` (stdio JSON-RPC) | Poor | Python and TS clients exist | No cancel, no close, no per-prompt result, no approval flow (server-to-client requests unused) | Not recommended |

Evidence: [source:DSH@rc2:packages/bundle/headless/README.md] [source:DSH@rc2:packages/acp/acp/README.md] [source:DSH@rc2:packages/sdk/protocol/README.md] [local-run: npm view devDependencies `@agentclientprotocol/sdk 1.4.0`]

**`bin/dsh-dispatch`** mirrors `bin/zcode-dispatch` (job ids `dt-…`, job records, per-workspace reservation lock, boot-id liveness, env allowlist, key redaction).

| Verb | Mapping onto dsh |
|---|---|
| `task --background` | Reserve the workspace. Write `prompt.md` and `dsh.patch.yml` (role preset: provider/model/effort, pinned `baseURL`, session-log off, inventory off, title off, optionally `tool-web` off). Spawn detached, cwd = worktree: `dsh --profile headless --patch <job>/dsh.patch.yml --json -`, stdin from the prompt file, stdout to `events.ndjson`, stderr to `stderr.log`. Env is allowlist-only: `PATH HOME TMPDIR LANG TERM USER`, plus `DSH_HOME=<plugin-state>/dsh-home`, `DSH_AGENTS_HOME=<empty dir>`, `DSH_TELEMETRY_DISABLED=1`, `DSH_PERMISSION_MODE=<role>`, `DEEPSEEK_API_KEY` (or `<VENDOR>_API_KEY` for a pi-ai route). Record pid, pgid, start time and boot id |
| `status` | Parse `events.ndjson` incrementally: last `status.phase`, turn and step counters, summed usage, last `tool_call`. Liveness from pid plus start time |
| `result` | After exit: `sessionId` from the first `session` event, `final.text` (line-1 status token), `turn_end.reason`, exit code, usage totals, an estimated USD figure (pricing table × peak/off-peak window), and stderr `dsh: CODE:` for the error class (§11). The `malformed` class applies when exit is 0 but the token is missing |
| `cancel` | Snapshot descendants; SIGINT; wait 7 s; SIGKILL; kill the recorded descendant PGIDs; mark the job `cancelled` explicitly (SIGTERM would read as 0) |
| `resume` | Same cwd and same patch: `dsh --profile headless --patch … --json --session-id <id> -`. Reject when the cwd differs. The new run streams into a new job record linked to the old one |
| `doctor` | `dsh --version` must equal the pinned semver (catches Dancer's shell); `node --version` ≥ 22.19 or ≥ 24; `/usr/bin/sandbox-exec` present on macOS; `dsh --profile headless --patch <tmpl> --dump-config` succeeds (offline, initializes the wrapper `DSH_HOME` profile) and shows `session-log-deepseek` with `enabled: false` and pinned `baseURL`; key present (never printed); `DSH_HOME` permissions `0700`; warn if the target repo has a `.env` |
| `doctor --probe` | One real call: model `deepseek-flash`, `reasoningEffort: off`, prompt `Reply with exactly: OK`, `DSH_PERMISSION_MODE=read-only`, `tool-web` disabled. Classify via §11. Costs a fraction of a cent |
| `release-stale` | Same as zcode: dead pid or reboot means finalize the record as `crash`, then sweep orphan PGIDs |
| `api-key` | The user stores the DeepSeek key in a wrapper-owned file (`0600`) or the macOS Keychain, outside any repo. Never in chat. The wrapper injects it via env only |

**Role presets.** Pass every value explicitly; never trust dsh defaults.

| Role | `DSH_PERMISSION_MODE` | Model / effort | Extra rows |
|---|---|---|---|
| implementer | `workspace-write` | `deepseek-v4-pro`/`high` (or `deepseek-flash`/`high` for cheap tasks) | Session-log, inventory and title off; pinned `baseURL`; caches redirected into `$TMPDIR` |
| reviewer (other family) | `read-only` | `deepseek-v4-pro`/`max` | Plus `tool-web` disabled |
| mechanical | `workspace-write` | `deepseek-flash`/`low` or `off` | Same as implementer |

**What the job runner must do around dsh:**
- Keep the plugin's per-workspace lock; dsh has none.
- Run only inside a git tree, which is already the plugin rule.
- Treat target-repo `.env` files as untrusted.
- Never use `danger-full-access` or `sdk-minimal`.
- Capture usage for cost reporting.
- For the "guarded" future mode, build an ACP broker that answers `session/request_permission` from a policy (deny network-heavy escalations, allow writes to `.git/worktrees/<name>`, and so on).

## 17. Sources

| Source | Version / date | Accessed |
|---|---|---|
| GitHub `deepseek-ai/deepseek-harness`, tag `dsh-v0.2.1-rc.2` (files cited inline) | Release 2026-10-17; commit `687f282e8625` is the master head on 2026-10-17 | 2026-10-20 via `gh api` |
| npm `@deepseek-ai/dsh` (`npm view --json`) | 0.2.1-rc.2; plus `dsh-hooks-claude-code`, `dsh-experimental-claude-code-mods`, `dsh-subagent-{claude-code,codex,acp}`, `dsh-mcp-client` (all 0.2.1-rc.2) [corrected 2026-10-20: 0.2.1-rc.2 for these is the `next` dist-tag; their `latest` tags are stale (0.0.1-rc.x, and 0.2.1-alpha.1 for `dsh-experimental-claude-code-mods`)]; `@deepseek-ai/node-addon-system` 0.1.2; `@earendil-works/pi-ai` 1.1.0 | 2026-10-20 |
| GitHub `earendil-works/pi` tag `v1.1.0`, `packages/ai/src/auth/oauth/` | v1.1.0 (v1.3.0 is the latest upstream; dsh pins `^1.1.0`) | 2026-10-20 |
| https://api-docs.deepseek.com/ | Fetched 2026-10-20 | n/a |
| https://api-docs.deepseek.com/quick_start/pricing/ | Fetched 2026-10-20 | n/a |
| https://api-docs.deepseek.com/guides/thinking_mode | Fetched 2026-10-20 | n/a |
| https://api-docs.deepseek.com/quick_start/error_codes | Fetched 2026-10-20 | n/a |
| https://api-docs.deepseek.com/quick_start/rate_limit | Fetched 2026-10-20 | n/a |
| https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code | Fetched 2026-10-20 | n/a |
| https://cdn.deepseek.com/policies/en-US/deepseek-open-platform-terms-of-service.html | Release 2026-04-22, effective 2026-04-29 (as fetched) | 2026-10-20 |
| arXiv 2608.01347 (abs and html) | v6, 2026-09-10 | 2026-10-20 |
| arXiv 2608.16393 (abs and html) | v2, 2026-08-18 | 2026-10-20 |
| arXiv 2608.25512 (Cordis) | v1, 2026-08-26 | 2026-10-20 |
| Local checks | `which -a dsh`, `brew info dsh`, `node --version`, `sw_vers`, `/bin/ls ~/.agents/skills`, `/usr/bin/sandbox-exec` | 2026-10-20 |

### Open questions

1. Does `git commit` from a linked worktree fail under `workspace-write` (worktree metadata under the main `.git`)? This needs a local test once dsh is installed.
2. How does DeepSeek use and retain uploaded `dsh_session_log` data? The ToS defers to the Privacy Policy, which was not checked.
3. Exact field acceptance of the wrapper patch: does `agent-default-model.reasoningEffort` override `llm-deepseek.reasoningEffort` in headless? Is `session-title-llm: disabled: true` clean in headless? Verify with `--dump-config` and a probe.
4. Is concurrent first-use auto-initialization of the same `DSH_HOME` profile race-safe across parallel jobs? Pre-initialize it in `doctor`.
5. Do Z.ai, Kimi, Qwen and Xiaomi coding/token plans permit use through a third-party harness like dsh (pi-ai routes)? Cross-check with `06-providers-and-plans.md`.
6. Exact HTTP-to-code mapping for `CONTEXT_WINDOW_EXCEEDED` versus `INVALID_REQUEST` on DeepSeek 400 bodies (adapter source not read).
7. Does a headless task starting with `/feedback` trigger the feedback command and an OTel upload? This is moot if `DSH_TELEMETRY_DISABLED=1` is set.

## Fact-check log (2026-10-20)

Method: opened every primary source myself. DSH files were read at tag `dsh-v0.2.1-rc.2` with `gh api` (raw contents, git tree, releases, tags, commits, contributors). Other evidence: `npm view` metadata, `earendil-works/pi@v1.1.0`, the DeepSeek API docs and ToS pages, arXiv abs/html pages, and local read-only checks. Nothing was installed or run, and no model endpoint was called.

| Claim | Verdict | Evidence |
|---|---|---|
| npm `latest` = `next` = 0.2.1-rc.2 (2026-10-17T08:36Z), `alpha` = 0.2.1-alpha.5; every GitHub release is a prerelease; developer preview; not security-audited | confirmed | `npm view @deepseek-ai/dsh --json`; `gh api …/releases` (31, all prerelease); README.md and SAFETY.md@rc.2 |
| Repo created 2026-08-13T11:56Z; first npm publish 0.0.1-rc.1 2026-08-10; 0.1.0-rc.2/.3/.6 on 2026-08-13; 36 npm versions | confirmed | `gh api repos/…` `created_at`; `npm view … time`. First *GitHub* release is `dsh-v0.1.0-rc.7` on 2026-08-17 |
| 22,395 commits, 44 contributors, master head `687f282e8625` = rc.2 commit | confirmed | `gh api` commits/contributors pagination `Link` headers; `commits/master` and `commits/dsh-v0.2.1-rc.2` |
| About 255k stars / 30.8k forks; issues disabled; maintainers `imccyu`, `tianyicui-deepseek` | confirmed | 255,226 stars, 30,869 forks, `has_issues: false`; `npm view` maintainers |
| Cordis, arXiv 2608.25512 (PKU + DeepSeek-AI, 2026-08-26) | confirmed | arxiv.org/abs/2608.25512 (v1, 26 Aug 2026; affiliations Peking University and DeepSeek-AI) |
| Headless command and grammar; NDJSON `session`…`final`; `error` without `final`; exit 0 only for `completed`, else 1 | confirmed | docs/cli-help.md; packages/bundle/headless/README.md; src/json-stream.ts (`write({ type: 'session', sessionId, cwd })`, uncapped `final`) |
| `turn_end.reason.kind` set incl. `blocked`, `max-tokens`, `interrupted` | confirmed | docs/subsystems/session.md `TurnEndReasonMap` (also has `forked`) |
| SIGTERM → 0, SIGINT → 130, 5 s bounded disposal | confirmed | apps/cli/src/profile-boot.ts; process-shutdown.ts; reference README "`SIGTERM` … exits 0 on every surface" |
| `DSH_PERMISSION_MODE ?? 'workspace-write'` + `ask`; no answerer → `unavailable` → denial | confirmed | base cordis.patch.yml; docs/subsystems/approval.md; docs/subsystems/tools.md ("missing approval support turns `ask` into denial"). That headless composes no answerer is consistent with the sources (answerers exist only in the ACP bridge, client UI and Web remotes) |
| Sandbox confines only file writes; reads and network unconfined; `web_fetch` runs without approval in every mode | confirmed | apps/cli/reference/README.md ("reads and network access are not confined"; "Enabled fetch calls run in every sandbox and approval mode without per-call confirmation"); docs/subsystems/sandbox.md |
| Seatbelt profile `(allow default)(deny file-write*)` + `/dev/null` + write roots; bwrap read-only root, fresh `/dev`, private PID | confirmed | packages/sandbox/sandbox-local/src/profiles.ts |
| `sdk-minimal` pins `danger-full-access` with no approval service | confirmed | packages/bundle/sdk-minimal/cordis.patch.yml; reference README |
| `dsh_session_log` (cwd, prompts, tool args/results, ≤ 8 MiB) and `dsh_plugin_packages` are sent to the resolved `baseURL`, gateways included; both on by default | confirmed | docs/deepseek-llm-api-wire-extensions.md ("A gateway selected through `baseURL` receives the same values as the official endpoint") |
| `baseURL` = explicit config, then `DEEPSEEK_BASE_URL` from any launch layer incl. cwd `.env`, then `https://api.deepseek.com/anthropic` | confirmed | packages/llm/llm-deepseek/src/config.ts:300 and its doc comment ("Every layer may supply an endpoint: the product trusts the project it is launched in") |
| Headless credential resolution (env, then cwd `.env`, then `$DSH_HOME/.env`); applies from ≥ 0.2.1-alpha.3 | confirmed | headless README "Credentials"; `.agents/notes/implemented/architecture/2026-10-12-headless-environment-auth.md`; patch rows absent at alpha.2, present at alpha.3 |
| llm-deepseek defaults: `maxTokens` 256,000, stream idle 300,000 ms, effort `high`, `off` → `thinking.type: disabled`, other levels → `output_config.effort`, `x-api-key` | confirmed | src/defaults.ts; llm-deepseek README |
| Unlisted model ids pass through as text-only routes; ACP default `deepseek-v4-flash`; ACP and SDK disable `session-title-llm` | confirmed | llm-deepseek README; packages/bundle/acp-app and sdk-app cordis.patch.yml |
| pi-ai catalog = 42 providers; `zai` default base URL `api.z.ai/api/coding/paas/v4` | confirmed | packages/llm/llm-pi-ai/src/provider-data.generated.ts (42 keys counted) |
| pi-ai 1.1.0 OAuth modules (anthropic, github-copilot, kimi-coding, meta, openai-chatgpt, openai-codex, openrouter, radius, xai); `openai` sign-in not offered; pi latest v1.3.0 | confirmed | `gh api repos/earendil-works/pi/contents/packages/ai/src/auth/oauth?ref=v1.1.0`; llm-pi-ai/src/login.ts `UNSERVED_OAUTH = new Set(['openai'])`; pi releases (v1.3.0, 2026-10-15) |
| DeepSeek models, prices, peak hours, concurrency 2,500/500, legacy aliases, Search/Fetch $0.75/1k from 2026-11-01, no subscription | confirmed | api-docs.deepseek.com pricing and rate_limit pages. The billing start is 00:00 Beijing time on 2026-11-01 |
| Thinking: default on, effort `high`; `low\|high\|max`; mapping minimal→low, medium/xhigh→high, ultra→max; `reasoning_content` passback | confirmed | api-docs.deepseek.com/guides/thinking_mode |
| "Agent Integrations" sidebar lists DeepSeek Harness first | confirmed | api-docs.deepseek.com/quick_start/agent_integrations/claude_code |
| ToS release 2026-04-22 / effective 2026-04-29; §2.2 key secrecy; §4.2(3) training other models; no anti-automation clause; retention deferred to the Privacy Policy | confirmed | cdn.deepseek.com en-US Open Platform ToS |
| ToS operator "Hangzhou … and Beijing DeepSeek AI Co. and affiliates" | corrected | Only Hangzhou DeepSeek Artificial Intelligence Co., Ltd. is named; "Beijing" does not occur |
| Claude Code hooks bridge: opt-in, explicit `configPath`, 7 of 30 events | confirmed | packages/experimental/hooks-claude-code/README.md ("Unsupported hook events (23 of Claude Code's current 30)") |
| `dsh-hooks-claude-code` "published 0.2.1-rc.2" (and siblings "all 0.2.1-rc.2") | corrected | Those versions sit under `next`; `latest` is stale (`0.0.1-rc.5` / `0.0.1-rc.1`) |
| Skills roots (`.dsh/skills`, `.agents/skills`, custom, `$DSH_HOME/skills`, agents-home skills); `.claude/skills` not read | confirmed | packages/skill/skill-filesystem/README.md roots table |
| Subprocess model: macOS detached PGIDs, Linux user-systemd scopes, Windows Job objects; SIGKILL leaves groups; name-based env scrub | confirmed | packages/subprocess/subprocess-local/README.md |
| Per-session `flock(2)` on `session.lock`; zstd by default; path layout `--<normalized-cwd>--/…` | confirmed | packages/session/session-persistence-jsonl/README.md |
| Retry: 5 retries of `EMPTY_RESPONSE`/`RATE_LIMIT`/`SERVER`/`TIMEOUT`/`TRANSPORT`, 500 ms–10 s | confirmed | packages/llm/llm-retry/README.md |
| ACP: `session/request_permission`, `session/cancel`, `session/close`, `set_config_option` (model, `reasoning_effort`); no `session/load`, modes, terminals or elicitation; `@agentclientprotocol/sdk` 1.4.0. SDK: no cancel or close; server→client requests unused | confirmed | packages/acp/acp/README.md; packages/sdk/protocol/README.md; `npm view @deepseek-ai/dsh@0.2.1-rc.2 devDependencies` |
| Account route: OAuth+PKCE against `https://platform.deepseek.com`, tokens with no expiry or refresh, needs Host webServer; `ACCOUNT_QUOTA` | confirmed | packages/credentials/deepseek-account-platform/src/index.ts (`platformOrigin` default) and README; llm-deepseek-account README |
| arXiv 2608.01347: dsh 0.1.0rc7, `dsh-jsonrpc-agent`, Claude Sonnet 5, $20 cap, 600 s, $0.2753 → $0.0696 (−74.7%) → $0.0490 (−82.2%), ~91% from effort, Claude Code ~19% | confirmed (gateway wording corrected) | arxiv.org/html/2608.01347 §6.1 and Appendix O; versions v1 2026-08-02 … v6 2026-09-10 |
| arXiv 2608.16393: 14,560 executions, 16 channels, 35 objectives, 12 methods, overall 5.6%/5.3%, skills 14.3–16.0%, Unicode 25.5%, fake-completion 17.0%, commit `47f943859bef`, `deepseek-v4-flash`, fixtures-only sinks | confirmed | arxiv.org/abs and html/2608.16393 (v1 2026-08-17, v2 2026-08-18) |
| Local: `dsh` not installed; Homebrew `dsh` = Dancer's shell 0.25.10; Node v26.11.1; macOS 26.5.2; `/usr/bin/sandbox-exec`; 4 skills in `~/.agents/skills` | confirmed | `which -a dsh`, `brew info dsh`, `node --version`, `sw_vers`, `/bin/ls` |

**Reconciliation with 04-dsh-and-harness-survey.md.**
- **Session-log destination.** 04 said "official DeepSeek API"; this report said "configured baseURL, gateways included". This report is correct, and 04 is corrected.
- **Tool process groups.** 04 had this as unverified; this report says detached PGIDs on macOS. This report is correct; 04's §10, cancel row and open question 4 are corrected.
- **Cancel sequence.** 04's single group kill misses detached tool groups on macOS. The PGID-sweep sequence here is the one to keep, and 04 is annotated.
- **Secrets.** 04's "the model never sees secrets" contradicted "reads are unconfined" here. This report is correct, and 04 is corrected.
- **`.git` writability.** 04's "stays writable" is qualified by this report's worktree caveat.
- **Headless approval answerer.** 04 called "no answerer" an inference; this report asserts it. The sources support it, and no change was needed.
- **Agreements.** Stars (~255k), license, dist-tags, sandbox scope (writes only), exit codes and the headless credential order agree and are confirmed.

**Reliability assessment.** This report is highly reliable. Every repository path it cites exists at the tag. Every number I checked matches the primary source: versions, dates, commit and contributor counts, caps, timeouts, prices, concurrency limits, provider count and arXiv figures. The key quotes are verbatim. Two statements were wrong:
- the ToS operator (a non-existent Beijing entity was added);
- the companion-package version (stated as published 0.2.1-rc.2 while npm `latest` is stale 0.0.1-rc.x, which matters for an unpinned `dsh plugin add`).

One paper's setup was simplified. No hallucinated flags, env vars or endpoints were found. The remaining `[unverified]` items (git commit from a worktree, `.mcp.json`, exact patch-field acceptance) are honestly marked and need a local run of an installed dsh.
