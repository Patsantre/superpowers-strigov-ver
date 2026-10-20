# 10 — ACP (Agent Client Protocol) as a universal transport for the dispatcher

- **Key:** `10-acp-universal-transport` · **Date:** 2026-10-20 · **Method:** primary sources only: the ACP spec repo at tag `schema-v1.26.0` (docs, JSON schema, changelogs, RFDs), the agents' and clients' source at release tags via `gh api`, npm registry metadata, and three local read-only checks (`claude --help`, `codex --help`, and a string search of the ZCode bundle). No adapter was installed. No model endpoint was called.
- **Tags:**
  - `[source:<owner/repo>@<tag>:<path>]` for repository source.
  - `[docs:<url>]` and `[third-party:<url>]` for web pages.
  - `[npm]` for `npm view` output.
  - `[local-run]` for checks run on this machine.
  - `[unverified]` for claims not confirmed.
- **Short names:**
  - `ACP@1.26` = `agentclientprotocol/agent-client-protocol@schema-v1.26.0`
  - `CAA` = `agentclientprotocol/claude-agent-acp@v0.94.0`
  - `CXA` = `agentclientprotocol/codex-acp@v2.2.2`
  - `DSH` = `deepseek-ai/deepseek-harness@dsh-v0.2.1-rc.2`
  - `OC` = `anomalyco/opencode@v1.19.3`
  - `GEM` = `google-gemini/gemini-cli@v0.64.0`
  - `QW` = `QwenLM/qwen-code@v0.25.3`
  - `KIMI` = `MoonshotAI/kimi-cli@1.52.0`
  - `GOOSE` = `block/goose@v1.55.0`
  - `PIA` = `svkozak/pi-acp@v0.0.34`
  - `ACPX` = `openclaw/acpx@v0.19.6`

## Bottom line

1. **ACP v1 is mature and stable enough to build on.** The stable v1 surface covers `initialize`, `authenticate`, `session/new|load|resume|close|list|delete`, `session/prompt`, `session/cancel`, `session/set_config_option`, `session/request_permission`, `usage_update`, and `$/cancel_request`. The JSON schema is at v1.26.0 (2026-10-16). The TypeScript, Rust and Python SDKs are official. A **v2 draft** is in progress and changes core shapes, so implementations must **pin protocolVersion 1**.
2. **One ACP client can drive DeepSeek Harness, OpenCode, Gemini, Qwen, Kimi, Goose, Cline, Cursor, Copilot and MiniMax natively.** Claude Code, Codex and pi need third-party adapters: `claude-agent-acp`, `codex-acp` and `pi-acp`. ZCode does not speak ACP at all [local-run].
3. **dsh is the best fit by far.** Its ACP server (`dsh --profile acp`) is *explicitly automation-only*. It supports session list, resume and close, model and effort config options, `usage_update`, and one-shot permission prompts that come from its own Seatbelt sandbox's escalation path [source:DSH].
4. **ACP is not a security boundary.**
   - Permission requests are optional for the agent ("Agent **MAY** request permission"). They fire only when the harness's own policy says "ask", and never in yolo, bypass or full-access modes.
   - The client fs and terminal methods are used only by a minority of agents. Claude's adapter stopped using them in v0.18.0. Gemini falls back to local fs outside the workspace root.
   - ACP v2 **removes** the client fs and terminal methods.
   - A policy broker is therefore an *escalation gate on top of the harness's own OS sandbox* (Codex, dsh, Claude's Bash sandbox), not a replacement for one.
5. **ACP fits the dispatcher's verb contract cleanly.**
   - A detached runner holds the stdio session for up to 60 minutes. There is no protocol keepalive.
   - The prompt travels over stdin, which removes the argv size cap.
   - `cancel` maps to `session/cancel` with a group-kill fallback, and `resume` maps to `session/resume` or `session/load`.
   - The line-1 token must be rebuilt from `agent_message_chunk`s (grouped by `messageId` where the agent sends it).
   - Gaps: there is no standard quota/rate-limit error and no stable per-turn token usage.
6. **Recommendation: hybrid, not "ACP everywhere".**
   - Add `acp` as **one transport kind** in the generic core. Use it first for dsh, then optionally for OpenCode, Kimi and Goose.
   - Keep the native headless paths for `claude -p`, Codex and pi:
     - `claude -p` already has a host permission channel (`--permission-prompts host`).
     - Codex: `codex-acp` wraps the same app-server as the vendored companion.
     - pi: `pi-acp` adds no tool gating.
   - Hand-roll a small NDJSON client pinned to v1 instead of taking the TS SDK, whose 2.0.0 (2026-10-19) removed `ClientSideConnection`.

---

## 1. The protocol as of October 2026

### 1.1 Versions, governance, SDKs

| Item | Fact | Evidence |
|---|---|---|
| Home | `github.com/agentclientprotocol/agent-client-protocol` (originally Zed). Lead maintainers since 2026-02-18: Ben Brandt (Zed) and Sergey Ignatov (JetBrains). | [source:ACP@1.26:README.md] [source:ACP@1.26:docs/announcements/sergey-ignatov-lead-maintainer.mdx] |
| Wire version | `protocolVersion` is a single integer (major only), currently **1**. Features arrive as capabilities; omitted capabilities = unsupported | [source:ACP@1.26:docs/protocol/v1/initialization.mdx] |
| Schema releases | `schema-v1.26.0` and `schema-v2.0.0-alpha.9` on 2026-10-16. The schema crate `agent-client-protocol-schema` v1.12.0 (spec-repo tag `v1.12.0`) shipped the same day; the `agent-client-protocol` SDK crate is versioned separately in `rust-sdk` (v3.4.0) [corrected 2026-10-20: spec repo `Cargo.toml@v1.12.0` pins `agent-client-protocol-schema` 1.12.0; `gh api repos/agentclientprotocol/rust-sdk/releases` shows v3.4.0]. ~weekly cadence | `gh api …/releases` [source:ACP@1.26:schema/v1/CHANGELOG.md] |
| v2 | Draft since 2026-07-20. "various pieces can, and will, change". Implementers should gate it behind version negotiation **and** feature flags, and keep v1 | [source:ACP@1.26:docs/announcements/acp-v2-draft.mdx] |
| TS SDK | `@agentclientprotocol/sdk` **2.0.0** (2026-10-19): **breaking**. `ClientSideConnection`/`AgentSideConnection` were removed in favour of `agent()`/`client()` apps. Unstable features move to `/unstable`. Peer dep `zod`, 7.9 MB unpacked. 1.0.0 was 2026-06-24. The old `@zed-industries/agent-client-protocol` is deprecated | [npm] [source:agentclientprotocol/typescript-sdk:CHANGELOG.md] |
| Rust SDK | crate `agent-client-protocol`; `rust-sdk` release v3.4.0 (2026-10-16) | [docs:agentclientprotocol.com/libraries/rust] `gh api` |
| Python SDK | `pip install agent-client-protocol`; repo at **1.0.0rc3** (2026-10-12, pre-release) | [source:ACP@1.26:docs/libraries/python.mdx] `gh api` |
| Agent registry | Curated `registry.json` (CDN) with `npx`/`uvx`/binary distributions, 43 agents | [source:agentclientprotocol/registry@main] |

### 1.2 Method surface (stable v1 vs unstable vs v2 draft)

| Direction | Stable v1 (`schema/v1/meta.json`) | Unstable v1 only (`meta.unstable.json`) | v2 draft changes |
|---|---|---|---|
| Client→Agent | `initialize`, `authenticate`, `logout`, `session/new`, `session/load`, `session/resume`, `session/close`, `session/list`, `session/delete`, `session/prompt`, `session/cancel` (notif.), `session/set_mode`, `session/set_config_option` | `providers/list`, `providers/set`, `providers/disable`, `session/fork`, `mcp/message` | `session` capability ⇒ list, resume and close are **required**. Dedicated modes/models APIs are removed. Prompt lifecycle is decoupled from the turn. |
| Agent→Client | `session/update` (notif.), `session/request_permission`, `fs/read_text_file`, `fs/write_text_file`, `terminal/create\|output\|release\|wait_for_exit\|kill`, `elicitation/create\|complete` | `mcp/message` | **`fs/*` and `terminal/*` removed** ("not widely adopted … many Agents are moving toward their own sandboxing"). `request_permission` gets `title` plus an optional `subject` (`tool_call` \| `command{command,cwd}`). |
| Both | `$/cancel_request` (stable since 2026-06-29) | — | — |

Evidence: [source:ACP@1.26:schema/v1/meta.json], [source:ACP@1.26:schema/v1/meta.unstable.json], [source:ACP@1.26:docs/rfds/v2/required-session-methods.mdx], [source:ACP@1.26:docs/rfds/v2/client-filesystem-terminal-capabilities.mdx], [source:ACP@1.26:docs/rfds/v2/permission-requests.mdx].

`session/set_model` **no longer exists**. The unstable session-model API was removed in 0.13.5 (2026-06-01) [source:ACP@1.26:CHANGELOG.md:274]. Model selection is now a config option with `category: "model"`. Gemini (`unstable_setSessionModel`) and pi-acp still use the old method name [source:GEM:docs/cli/acp-mode.md] [source:PIA:src/acp/agent.ts:1153].

### 1.3 Initialization, auth, sessions

| Aspect | Spec | Evidence |
|---|---|---|
| Baseline | Every agent MUST support `session/new`, `session/prompt`, `session/cancel` and `session/update`, and accept `text` and `resource_link` prompt blocks. Everything else is capability-gated. | [source:ACP@1.26:docs/protocol/v1/initialization.mdx:236,277] |
| Client capabilities | `fs.readTextFile`, `fs.writeTextFile`, `terminal`, `auth.terminal`, `elicitation`, `session.{notices,compaction,configOptions.boolean}`, `_meta` | [source:ACP@1.26:schema/v1/schema.json#ClientCapabilities] |
| Agent capabilities | `loadSession`, `promptCapabilities{image,audio,embeddedContext}`, `mcpCapabilities{http,sse}`, `sessionCapabilities{list,delete,additionalDirectories,resume,close}`, `auth{logout}` | same `#AgentCapabilities`, `#SessionCapabilities` |
| Auth | `authMethods` are `agent` (client sends only `methodId`) or `terminal` (client runs the agent's own interactive login). **No secret crosses `authenticate`.** Error `-32000` = auth required. | [source:ACP@1.26:docs/protocol/v1/authentication.mdx] `#AuthMethod`, `#ErrorCode` |
| `session/new` | `{cwd (absolute), mcpServers[], additionalDirectories?}` → `{sessionId, modes?, configOptions?}` | [source:ACP@1.26:docs/protocol/v1/session-setup.mdx] |
| `session/load` | Needs `loadSession`. The agent **replays the full history** as `session/update`s, then responds. | same |
| `session/resume` | Needs `sessionCapabilities.resume`. It restores context **without replay**. | same |
| `session/close` | Cancels in-flight work and frees resources (stable since 2026-04-23) | same; [source:ACP@1.26:docs/updates.mdx] |
| Errors | JSON-RPC codes only: -32700/-32600/-32601/-32602/-32603, -32800 request cancelled, -32000 auth required, -32002 resource not found. **No quota or rate-limit code.** | `#ErrorCode` |

### 1.4 Prompt turn, updates, stop reasons, cancel

- `session/update` kinds (complete stable set) [source:ACP@1.26:docs/protocol/v1/prompt-turn.mdx:14-29]:
  - `user_message_chunk`, `agent_message_chunk` and `agent_thought_chunk`, with an optional `messageId` (stable 2026-06-05).
  - `tool_call` and `tool_call_update`, carrying `toolCallId`, `title`, optional `name`, `kind` and `status` (pending/in_progress/completed/failed), plus `content` (text, `diff{path,oldText,newText}`, `terminal`), `locations`, `rawInput` and `rawOutput`.
  - `plan`, `available_commands_update`, `current_mode_update`, `config_option_update` and `session_info_update`.
  - `usage_update{used,size,cost?{amount,currency}}`.
  - `notice` and `compaction_*`, both capability-gated.
- **StopReason:** `end_turn | max_tokens | max_turn_requests | refusal | cancelled` [schema `#StopReason`]. There is no `error` stop reason in v1. Failures come back as a JSON-RPC error on `session/prompt`. An `error` stop reason exists only for unstable subagent state [schema.unstable `#ErrorStopReason`].
- **Cancel:**
  - The client sends the `session/cancel` notification. It MUST answer pending permission requests with `cancelled`.
  - The agent MUST end the prompt with `stopReason: cancelled`, not an error.
  - Late `tool_call_update`s may still arrive [source:ACP@1.26:docs/protocol/v1/prompt-turn.mdx:549-582].
- **Usage:** `usage_update` (context used/size plus optional cumulative cost) is stable. Per-turn token usage (`PromptResponse.usage{inputTokens,outputTokens,…}`) is **unstable**: that RFD is "intentionally kept in Draft" [source:ACP@1.26:docs/rfds/end-turn-token-usage.mdx:14].

### 1.5 Permissions

- **Request:** `session/request_permission{sessionId, toolCall: ToolCallUpdate, options[]}`. Each option is `{optionId, name, kind}`, where `kind` is one of `allow_once | allow_always | reject_once | reject_always`.
- **Response:** `{outcome: {outcome:"selected", optionId} | {outcome:"cancelled"}}` [source:ACP@1.26:docs/protocol/v1/tool-calls.mdx].
- **Normative strength:**
  - "The Agent **MAY** request permission."
  - "Clients **MAY** automatically allow or reject permission requests according to the user settings." Machine brokering is therefore spec-sanctioned.
  - Tool `name` is "opaque, informational metadata: they do not advertise a capability or grant authorization" (the spec says "Names are opaque, …"; the sentence is about `name` only) [corrected 2026-10-20: ACP@1.26 docs/protocol/v1/tool-calls.mdx:41-43].
  - `kind` is a UX hint ("help Clients choose appropriate icons", tool-calls.mdx:68).
  - `rawInput` is agent-specific.
  - So a broker can only decide reliably with **per-agent parsers**.

### 1.6 Client file system and terminal

- `fs/read_text_file{path,line?,limit?}` and `fs/write_text_file{path,content}` are opt-in by the client. The tool-calls doc says agents "**MAY** leverage" them [source:ACP@1.26:docs/protocol/v1/file-system.mdx, prompt-turn.mdx:491].
- `terminal/*` lets the agent ask the **client** to run a command [source:ACP@1.26:docs/protocol/v1/terminals.mdx].
- The v2 RFD removes both and says that in practice agents' tools "most stuck to their standard implementations" [corrected 2026-10-20: verbatim wording in the RFD is "most stuck", not "mostly stuck"] [source:ACP@1.26:docs/rfds/v2/client-filesystem-terminal-capabilities.mdx].

### 1.7 Modes, config options, model selection, endpoints

- **Session Config Options** (stable) are the preferred mechanism. `configOptions[]` entries have `{id, name, category: mode|model|model_config|thought_level|_custom, type: select|boolean, currentValue, options}`.
- `session/set_config_option` returns the **complete** state. The agent pushes changes via `config_option_update`, for example a "fallback to a different model due to rate limits".
- `session/set_mode` still works but "will be removed in a future version" [source:ACP@1.26:docs/protocol/v1/session-config-options.mdx, session-modes.mdx].
- Option ids and values are agent-specific. Examples:
  - CAA: `model`, `effort`, `mode`.
  - OC: `model`, `effort`, `mode`.
  - dsh: `model`, `reasoning_effort`.
- Evidence: [source:CAA:src/session-config-ids.ts] [source:OC:packages/opencode/src/acp/config-option.ts] [source:DSH:packages/acp/acp/README.md].
- **Unstable `providers/*`:** `providers/set{providerId, apiType: anthropic|openai|azure|vertex|bedrock|_x, baseUrl, headers}` lets a client reroute an agent's LLM traffic to a gateway or self-hosted model [source:ACP@1.26:docs/rfds/custom-llm-endpoint.mdx]. Headers (and with them API keys) **cross the wire in plaintext JSON**.

### 1.8 Extensibility and transport

- **`_meta` and `_`-methods:** `_meta` is allowed on most objects; root keys `traceparent`, `tracestate` and `baggage` are reserved. Methods prefixed with `_` are custom requests or notifications, and an unknown request returns -32601. Custom capabilities are advertised in `capabilities._meta` [source:ACP@1.26:docs/protocol/v1/extensibility.mdx].
- **Transport:** only **stdio** is specified. The client spawns the agent; messages are newline-delimited JSON with no embedded newlines; stdout is protocol-only and stderr is free logging. Streamable HTTP/WebSocket is "in discussion" (working group since 2026-04-22) [source:ACP@1.26:docs/protocol/v1/transports.mdx]. **A live session is bound to the process that owns the pipes.**

---

## 2. Which harnesses speak ACP, and how well

### 2.1 Matrix

| Harness | ACP entry (command) | Native / adapter; version | load / resume / close | Model & effort via ACP | Who executes edits / shell | When `request_permission` reaches the client | Own OS sandbox | Endpoint / key plug-in |
|---|---|---|---|---|---|---|---|---|
| **DeepSeek Harness (dsh)** | `dsh --profile acp` (stdout = ACP only) | **native**, "automation-only"; `dsh-v0.2.1-rc.2`. All 31 GH releases (dsh-v0.1.0-rc.7, 2026-08-17, through dsh-v0.2.1-rc.2, 2026-10-17) are prereleases [corrected 2026-10-20: `gh api --paginate repos/deepseek-ai/deepseek-harness/releases` returns 31 releases, 0 non-prerelease; there are not 100]. | load ✗, resume ✓, close ✓, list ✓ | config options `model` (provider/model from the live catalog) and `reasoning_effort`; the prompt pins the route for the whole turn | agent internal; no client fs/terminal ("outside this automation surface") | the harness's `approval/request` events (sandbox escalations) → one-shot `allow-once`/`reject-once`; "never infers a durable grant" | **yes**: `read-only`/`workspace-write`/`danger-full-access`, Seatbelt on macOS; "network … outside this vocabulary" | profile config `provider` (default `deepseek-official`), `model`; `authenticate` = no-op |
| **Claude Code** | `claude-agent-acp` | **adapter** (Apache-2.0, ACP org; was `zed-industries/claude-code-acp`); v0.94.0; wraps `@anthropic-ai/claude-agent-sdk` 0.3.303 and its bundled `claude` binary unless `CLAUDE_CODE_EXECUTABLE` is set | load ✓, resume ✓, close ✓, list/delete/fork ✓ | options `model`/`effort`/`mode`; env `ANTHROPIC_MODEL`, `ANTHROPIC_CUSTOM_MODEL_OPTION`, `CLAUDE_MODEL_CONFIG` | **agent internal**: "won't use client capabilities for files or terminals" since 0.18.0 | SDK `canUseTool` → client. In `bypassPermissions` Claude Code bypasses *before* `canUseTool`; only "bypass-immune" safety or ask-rule prompts still arrive. Bypass is clamped to `default` as root. | Bash sandbox via settings (`sandbox.*`, Seatbelt); file tools are governed by permission rules, not the sandbox | env is passed through (`{...process.env, ..._meta env, ...providerEnv}`), so **`ANTHROPIC_BASE_URL` works**; unstable `providers/set` (anthropic/bedrock/vertex + headers); `--hide-claude-auth` refuses claude.ai-subscription billing |
| **Codex** | `codex-acp` | **adapter** (ACP org, TS, starts the Codex App Server); v2.2.2; bundles `@openai/codex` ^0.160.1; `CODEX_PATH` overrides | load ✓, resume/close/list/delete/fork ✓ | model, reasoning effort, fast mode, mode | agent internal (Codex app-server) | modes: `read-only` (asks for edits and network), `workspace-write` (asks outside the workspace or for network), `agent` (auto-review), `agent-full-access` (never asks) | **yes**: Codex sandbox, `networkAccess:false` except full access | ChatGPT login, `CODEX_API_KEY`/`OPENAI_API_KEY`, `MODEL_PROVIDER`, `CODEX_CONFIG`, gateway auth, `providers` |
| **OpenCode** | `opencode acp [--cwd]` (also starts an internal local HTTP server) | **native**; v1.19.3 | load ✓, resume/close/fork/list ✓ | `model`, `effort`, `mode` | agent internal; after an approved `edit` it *also* mirrors the patched content via `fs/write_text_file` | only rules that resolve to `"ask"`. **Defaults are permissive**: most are `allow`, only `doom_loop`/`external_directory` ask, and `.env` reads are denied. Options `once`/`always`/`reject`; an RPC error → reject. | none built in [unverified] | OpenCode's own provider config and `opencode auth login` (any OpenAI-compatible endpoint, local models) |
| **Gemini CLI** | `gemini --acp` | native; v0.64.0 (registry) | load ✓ | modes `default`/`autoEdit`/`yolo`/`plan`; `unstable_setSessionModel` (no longer in the schema) | **client fs for paths inside the root** when advertised, but **falls back to local fs** for out-of-root paths and `~/.gemini`; shell internal | `default` asks; `yolo` never | optional (Seatbelt/containers) [unverified] | Gemini auth / API key |
| **Qwen Code** | `qwen --acp` (registry adds `--experimental-skills`) | native; v0.25.3; large daemon/bridge subsystem | load ✓, list ✓, resume ✓ | [unverified] | client fs when advertised, local fallback on some errors | approval modes (Gemini fork) [unverified details] | [unverified] | Qwen/DashScope or OpenAI-compatible [unverified] |
| **Kimi CLI** | `kimi acp` (multi-session) | native; 1.52.0 | load ✓ (**no replay**), list ✓ | ✗ (no set_mode/set_model) | **client fs** (`ACPKaos`) and **client terminal** (`Shell` replaced by the ACP `Terminal`) when advertised | core approvals → `allow-once`/`allow-always`/`reject` | ✗ [unverified] | `kimi login`; `-32000` if not logged in |
| **Goose** | `goose acp` | native (ACP is now goose's server architecture); v1.55.0 | [unverified] | [unverified] | **client fs and terminal** used by the developer extension when advertised | goose approval modes [unverified] | ✗ [unverified] | goose providers, including local llama.cpp (`goose-local-inference`); goose can also *drive* ACP agents as an LLM provider (`AcpProvider`) |
| **pi** | `pi-acp` → spawns `pi --mode rpc` | **community adapter** (MIT, 1 release in 60 days); v0.0.34; "MVP … expect minor breaking changes" | load ✓, list/delete ✓; **only one live session per connection** (`closeAllExcept`) | config options and `unstable_setSessionModel` | agent internal ("No ACP filesystem delegation … no terminal delegation") | **never for tools**: only pi extension-UI confirms | ✗ | pi's own provider config (API keys) |
| **MiniMax Code** | `mcode acp` | native; npm `@minimax-ai/code` 0.6.12 (registry pins 0.2.7); no public repo | [unverified] | [unverified] | [unverified] | [unverified] | [unverified] | MiniMax |
| **GLM** | `glm-acp-agent` (community, stefandevo) | third-party agent "that uses the Z.AI … GLM Coding Plan"; 1.15.0 | [unverified] | | | | | **ToS risk**: not an official Z.ai tool [unverified] |
| **ZCode** | — | **no ACP**: 0 hits for `agentclientprotocol`/`session/request_permission` in `glm/zcode.cjs` and `app.asar` of ZCode 3.15.1 [local-run] | | | | | | |
| Cline / Augment / Cursor / Copilot | `cline --acp`, `auggie --acp`, `cursor-agent acp`, `copilot --acp` | native (registry) | [unverified] | | | | | proprietary accounts |

Evidence by row:

- **dsh**:
  - [source:DSH:packages/acp/acp/README.md]
  - [source:DSH:packages/acp/acp/src/index.ts:156-190] (permission bridge, capabilities `close/list/resume`, `mcpCapabilities.http`)
  - [source:DSH:packages/bundle/acp-app/cordis.patch.yml] (default `deepseek-v4-flash`)
  - [source:DSH:docs/subsystems/sandbox.md:11,79-90]
- **Claude (CAA)**:
  - [source:CAA:README.md]
  - [source:CAA:CHANGELOG.md:1158] (0.18.0, built-in tools)
  - [source:CAA:src/acp-agent.ts:2952-2992] (capabilities)
  - [source:CAA:src/acp-agent.ts:10115-10120] (bypass before `canUseTool`)
  - [source:CAA:src/acp-agent.ts:11166-11203,12236-12293] (env and provider routing)
  - [source:CAA:src/permissions/modes.ts]
  - [source:CAA:src/hide-claude-auth.ts]
  - [source:CAA:docs/model-configuration.md]
  - [npm]
- **Codex (CXA)**: [source:CXA:README.md] [source:CXA:src/AgentMode.ts] [source:CXA:src/CodexAcpServer.ts:474-504] [npm]
- **OpenCode (OC)**: [source:OC:packages/opencode/src/cli/cmd/acp.ts] [source:OC:packages/opencode/src/acp/service.ts:97-131] [source:OC:packages/opencode/src/acp/permission.ts:17-115] [source:OC:packages/web/src/content/docs/permissions.mdx:168-174]
- **Gemini (GEM)**: [source:GEM:docs/cli/acp-mode.md] [source:GEM:packages/cli/src/acp/acpFileSystemService.ts] [source:GEM:packages/cli/src/acp/acpUtils.ts:224-252]
- **Qwen (QW)**: [source:QW:packages/cli/src/acp-integration/service/filesystem.ts] [source:QW:packages/cli/src/acp-integration/acpAgent.ts:5530-5538]
- **Kimi (KIMI)**: [source:KIMI:src/kimi_cli/acp/AGENTS.md] [source:KIMI:docs/en/reference/kimi-acp.md]
- **Goose**: [source:GOOSE:crates/goose/src/acp/fs.rs] [source:GOOSE:crates/goose/src/acp/provider.rs]
- **pi (PIA)**: [source:PIA:README.md] [source:PIA:src/acp/agent.ts:250-270] [source:PIA:src/acp/session.ts:59-64,201-206,999-1010]
- **Registry commands**: [source:agentclientprotocol/registry@main:*/agent.json]

### 2.2 What the matrix means

- **Native and automation-first:** dsh is the only harness whose ACP server is designed for scripts rather than editors. It runs several sessions per connection, says "your client can answer automatically", promises quiescence before settlement, and has no UI extensions. dsh's own out-of-process ACP client, `dsh-subagent-acp`, is close prior art for this plugin:
  - auto-answers permissions with `allow` or `reject`;
  - scrubs credential-shaped env;
  - uses an isolated `DSH_HOME`;
  - returns "the child's final streamed assistant text";
  - maps stop reasons to `completed`/`max-tokens`/`refusal`/`aborted`/`error`.

  Source: [source:DSH:packages/subagent/subagent-acp/README.md].
- **Adapters add a layer and churn.**
  - `claude-agent-acp` shipped **29 releases in the last 60 days**, `codex-acp` 15, `acpx` 15 (`gh api` count since 2026-08-21).
  - CAA already depends on SDK 2.0.0, released about 35 minutes before CAA 0.94.0 on the same day (2026-10-19) [corrected 2026-10-20: npm `time` shows @agentclientprotocol/sdk 2.0.0 at 2026-10-19T20:56Z and @agentclientprotocol/claude-agent-acp 0.94.0 at 2026-10-19T21:31Z; CAA `package.json@v0.94.0` pins `@agentclientprotocol/sdk` "2.0.0"].
  - For Codex, `codex-acp` drives the same Codex App Server that the vendored companion already drives [source:CXA:README.md], so it adds no capability.
- **Claude endpoints:**
  - CAA forwards `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_MODEL` from its env to the SDK's Claude Code process. GLM, DeepSeek or any Anthropic-compatible gateway therefore works through ACP exactly as through `claude -p`.
  - Gotcha (adapter source comment): "Claude Code applies env from settings.json after the subprocess env". The user's `~/.claude/settings.json` `env` can override the endpoint unless the config home is isolated or the route is set with `providers/set` [source:CAA:src/acp-agent.ts:11185-11193].
  - Whether third-party endpoints and subscriptions are ToS-compliant is a separate question (§5).
- **Model and effort confirmation** works through `configOptions[].currentValue` (model category) after `session/new`/`set_config_option`. dsh "advertises only mounted support" and pins the admitted route for the turn [source:DSH:packages/acp/acp/README.md]. Values are opaque, so the profile must map them per agent.

---

## 3. Headless ACP clients and orchestrators

| Project | What it is | Background / jobs | Cancel | Permissions | Output / logging | Notes |
|---|---|---|---|---|---|---|
| **acpx** (`openclaw/acpx` 0.19.6, MIT, pre-1.0, Node ≥22.13) | the reference headless ACP CLI; 25+ built-in agent profiles plus `--agent '<cmd>'` | persistent per-cwd sessions in `~/.acpx/`. A **detached "queue owner" process holds the live ACP connection**, takes prompts over a Unix socket (`--no-wait` queues and returns) and has an idle TTL (300 s). `exec` = one-shot. | `acpx <agent> cancel` via IPC; cooperative descendant cleanup (SIGTERM → SIGKILL, 8 s budget, birth-identity checks) | `--approve-all \| --approve-reads (default) \| --deny-all`; `--permission-policy` JSON (`autoApprove`, `autoDeny`, `escalate`, `defaultAction`) matched on tool kind, title or raw tool name; `--non-interactive-permissions deny\|fail` | `--format json` = NDJSON ACP events; `quiet` = final text; exit codes 0/1/2/3 timeout/4 no session/**5 all permissions denied**/130 | Its own docs: fs guardrails are "best-effort … not an OS sandbox" and `--no-terminal` "does not prevent the adapter from running its own native tools". The built-in profiles for the adapters (`claude`, `codex`, `opencode`, `kilocode`) launch via **`npx -y …`** and `pi` via `npx pi-acp`; most of the other 26 built-in profiles call a locally installed binary (`gemini --acp`, `kimi acp`, `qwen --acp`, …) [corrected 2026-10-20: ACPX docs/agents.md "Built-in registry" table]. |
| **dsh-subagent-acp** | dsh provider that spawns any ACP agent as a subagent | one run = spawn → initialize → newSession → prompt → final text | provider disposal, EOF window, termination escalation | `permission: reject \| allow` | stop-reason mapping; fixed-shape diagnostics with no stderr or paths | prior art for env scrub and an isolated home |
| goose `AcpProvider` | goose uses an ACP agent *as its LLM provider* | in-process | — | — | — | shows ACP used as a model-provider shim |
| Hydra, Raven, Remote Agent Server, Kronos, AgentConnect, CompozyOS | daemons and orchestrators listed on the ACP clients page (Raven: DAG host; Remote Agent Server: "asynchronous Task API" for Codex and Claude Code) | various | — | — | — | small or young projects; leads only |

Evidence:

- acpx: [source:ACPX:README.md] [source:ACPX:docs/permissions.md] [source:ACPX:docs/exit-codes.md] [source:ACPX:docs/sessions.md:172-195] [source:ACPX:docs/runtime-process-lifecycle.md] [source:ACPX:docs/agents.md] [npm]
- dsh-subagent-acp: [source:DSH:packages/subagent/subagent-acp/README.md]
- goose `AcpProvider`: [source:GOOSE:crates/goose/src/acp/provider.rs:61,274,1480]
- The other daemons: [source:ACP@1.26:docs/get-started/clients.mdx]

**Takeaway.** acpx already implements the plugin's background model:

- a detached owner holding stdio;
- IPC submit, status and cancel;
- a policy file for permissions;
- stable exit codes.

It is a design reference rather than a dependency for three reasons. Its `npx` launches conflict with this plugin's no-runtime-download stance. It is pre-1.0. It has no errorClass taxonomy, write reservation or boot-id reaper.

---

## 4. Fit for this plugin

### 4.1 Verb mapping (generic core plus an `acp` transport adapter)

| Dispatcher verb | ACP realisation | Reused from today's core (see `00-current-architecture.md` §2) |
|---|---|---|
| `task --background --prompt-file F [--cwd]` | The CLI allocates a record and spawns a detached `__run`. The runner then:<br>1. spawns `<agent cmd>` in its own process group with the filtered env and an isolated home;<br>2. sends `initialize{protocolVersion:1, clientCapabilities:{fs:false, terminal:false}}`, then checks `agentInfo.version` against the pin and the required capabilities;<br>3. sends `session/new{cwd: worktree, mcpServers: []}`;<br>4. applies the profile's config options via `set_config_option` and **verifies `currentValue`**;<br>5. sends `session/prompt{prompt:[{type:"text", text:<file>}]}`. | record allocation, reservation, `runCli` group spawn, env allowlist, redaction, timeout |
| prompt size | carried over **stdin** inside a JSON string, so there is no argv cap. This removes the `MAX_PROMPT_BYTES` → "route to Luna" rule (00 §C14) for ACP channels. | — |
| `status <id> --json` | unchanged `job.status`. In addition, the runner can write live progress from updates: last `tool_call` title, kind and status, plan entries, `usage_update.used/size/cost`. | reaper, boot id |
| `result <id>` | `completed` ⇒ the stored **final agent message** text (§4.4). Line 1 = token. | unchanged |
| errorClass | `stopReason` `max_tokens`/`max_turn_requests` → new class (e.g. `truncated`); `refusal` → `refusal`. A JSON-RPC error on `session/prompt` gives `-32000` → `auth`; otherwise the existing `PATTERNS` run over `error.message` plus the stderr tail (quota and model patterns per agent). Agent exit before the response → `crash`. A capability or version mismatch at `initialize` → `launch`. | `classifyFailure` |
| `cancel <id>` | SIGTERM to the runner. The runner sends `session/cancel`, answers open permission requests with `cancelled`, and waits ≤N s for `stopReason: cancelled`. Then `session/close` if advertised, close stdin, and kill the group after a grace period. `cancelled` stays sticky. | `killGroup`, sticky terminal |
| `--resume-task <id>` | The record stores `sessionId`, agent id/version and cwd. The new runner sends `initialize`, then `session/resume` (when `sessionCapabilities.resume`), else `session/load` (discarding replayed updates until the response), else exit 2 "dispatch --fresh". A prompt that was in flight when the old runner died **cannot be re-attached**; only the persisted session can be continued. | `resolveResume` |
| read-only reviewer task | Per-agent profile:<br>- Codex mode `read-only`;<br>- Claude `plan` mode, or `default` plus a deny-all broker;<br>- dsh sandbox `read-only` [unverified how to select it per session over ACP];<br>- Gemini `plan`.<br>The broker answers `reject_once` to every edit/execute request. This is enforced only as far as the agent asks (§4.3). | new: skips the reservation (00 R2) |
| `doctor` | binary and version pin; spawn + `initialize` only (no session, no model call); print protocolVersion, agentInfo, capabilities and authMethods. A missing capability is a FAIL with a `hint:`. | doctor framework |
| `doctor --probe` | `session/new` → model check through config options → one PONG prompt → `usage_update` and stop reason | `runProbe` |

### 4.2 Can a detached runner hold an ACP session for 60 minutes?

**Yes.** Nothing in v1 times out on its own:

- stdio has no keepalive [source:ACP@1.26:docs/protocol/v1/transports.mdx];
- `session/prompt` simply stays pending until a stop reason arrives;
- dsh settles a prompt only after descendants and output drain [source:DSH:packages/acp/acp/README.md].

The runner is today's `__run` with the CLI exec replaced by a JSON-RPC loop. It has five duties:

1. Hold the pipes.
2. Append every message (redacted) to `<id>.log.ndjson`.
3. Answer `session/request_permission` within milliseconds, so the agent never blocks waiting on a human.
4. Answer `fs/*`/`terminal/*` with -32601 (not advertised).
5. Write the final record.

Risk: if the runner dies, the agent's stdin hits EOF and the turn is lost. The existing reaper marks the job `crash`, and the session can be continued with `--resume-task`. A second risk is the adapter's own timeouts; for example, CAA force-cancels with a 30 s grace [source:CAA:src/acp-agent.ts:425-437].

### 4.3 The permission broker: what it can enforce, versus an OS sandbox

**Broker inputs** per request:

- `toolCall.{toolCallId, title, kind?, name?, rawInput?, locations?, content?}`.
- `options[].kind`.
- From v2 also `subject.command{command, cwd}`.

`rawInput` shapes differ per agent:

- Claude: `{file_path}`, `{command}`.
- OpenCode: `metadata.filepath/diff`.
- Codex: command plus cwd.

So the policy needs **per-agent extractors**. Example policy:

```text
edit|delete|move: allow_once iff every path ∈ realpath(worktree) and ∉ {.git/, credential globs}
read|search:      allow_once iff path ∉ credential globs (~/.ssh, ~/.aws, ~/.claude/.credentials*, ~/.codex/auth.json, ~/.zcode, keychains, .env*)
execute:          allow_once iff argv[0] ∈ allowlist (test runners, git read-only, build tools) and no network verbs; else reject_once
fetch / unknown:  reject_once
any "escalation" (sandbox retry, outside workspace, network): reject_once
```

**How much protection, by harness class:**

| Class | Harnesses (mode) | Who decides what runs | Broker effect | Real boundary |
|---|---|---|---|---|
| A. Harness sandbox plus escalation prompts | Codex `workspace-write` (on-request); dsh `workspace-write`; Claude with `sandbox.enabled`, `allowUnsandboxedCommands:false` | the OS sandbox enforces writes (Codex and Claude also network); prompts arrive only for escalations | **deny all escalations** ⇒ writes stay inside the worktree, enforced by Seatbelt | **Yes, from the harness sandbox.** Claude's file tools are outside its sandbox and follow permission rules; dsh's sandbox does not cover network [source:DSH:docs/subsystems/sandbox.md:11]; [docs:code.claude.com/docs/en/sandboxing] |
| B. Agent executes, prompts per tool, no sandbox | OpenCode with `"*":"ask"`; Gemini `default`; Claude `default` without sandbox | agent tools | per-call allow/deny on parsed input. Reads are usually auto-allowed and never asked. Shell is only an allowlist heuristic, bypassable via `python -c`, `bash -c`, a script the agent just wrote, or `git` hooks. | **No.** A guardrail, comparable to prompt rules |
| C. Client executes (fs/terminal) | Goose developer extension; Kimi (`ACPKaos`, `Terminal`); Gemini fs inside the root | **the dispatcher itself**: it could run `terminal/create` under its own `sandbox-exec` profile and enforce paths on `fs/*` | strong for those tools only | **Partial.** MCP tools, web tools and Gemini's local fallback for out-of-root and `~/.gemini` paths bypass it; the capability disappears in v2 |
| D. No prompts | pi-acp; any agent in `yolo`/`bypassPermissions`/`agent-full-access`; OpenCode defaults | agent | none | **No.** The only boundary is an OS sandbox around the whole agent process (transport-independent) |

**Conclusion.** ACP gives a uniform *policy channel*, not containment. Containment comes from three places:

- the harness's own sandbox (Codex, dsh, Claude Bash), with the broker denying escalations;
- the dispatcher running client-side tools under its own sandbox (Goose and Kimi only, v1 only);
- wrapping the whole agent in `sandbox-exec`. That works for any transport, including today's ZCode yolo.

### 4.4 Line-1 token from the final message

- **Accumulate** `agent_message_chunk` text.
  - With `messageId`, the final message is the last id's chunks. CAA, OC and DSH send `messageId` (37, 12 and 6 references in source); pi-acp sends none [source grep].
  - Without `messageId`, take the text after the last `tool_call`/`tool_call_update`.
- **Ignore** `agent_thought_chunk`. pi-acp has **no separate thought stream** ("Assistant streaming is currently sent as `agent_message_chunk`") [source:PIA:README.md:203], so reasoning text can precede the token. The orchestrator's "first non-empty line" rule could then fail. Mitigation: use the final message only, or have the agent echo the token on its own line.
- **Stop reason:** `stopReason` alone is not the verdict. `end_turn` plus a malformed line 1 stays `malformed` per today's rule.

### 4.5 Credentials, environment, isolation

- **Stable path (preferred).** ACP `authenticate` carries **no secrets**: `methodId` only, or the agent's own `terminal` login. Keys stay in the harness's own login or env. The dispatcher's adapter-owned env (applied after the allowlist filter, as `ZCODE_*` is today) supplies them for:
  - `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` for CAA;
  - `CODEX_API_KEY`;
  - the dsh profile.
- **Unstable path (avoid unless needed).** `providers/set` puts keys into JSON-RPC `headers`. The dispatcher would hold the key in memory and must redact it from the NDJSON log.
- **Isolate the harness home** for every ACP agent, as `cli-home` does for ZCode: `CLAUDE_CONFIG_DIR`, `DSH_HOME`, `CODEX_HOME`, an OpenCode config dir [names partly unverified]. Without it, user settings can override routing (CAA's settings-env gotcha) or leak the user's sessions and MCP servers.
- **No `npx` at runtime.** The registry and acpx use `npx -y <pkg>@<ver>`. This plugin should require a user-installed, version-pinned adapter binary and check it in `doctor`.

### 4.6 ACP versus the native headless CLIs

| Harness | Native headless path | What ACP **gains** over it | What ACP **loses or costs** |
|---|---|---|---|
| Claude Code | `claude -p --output-format json\|stream-json`, `--resume`, `--permission-mode`, `--permission-prompts host\|none` (the SDK host or `--permission-prompt-tool` answers prompts), `--restricted`, `--allowedTools`/`--disallowedTools`, `--max-budget-usd` [local-run: `claude --help`, 2.1.302; 0 hits for "acp"] | uniform event schema; config options; session list/close | a **third-party adapter** (29 releases in 60 days) between you and the official CLI; a bundled `claude` binary version unless pinned; the native stream-json already exposes a host permission channel; a single JSON `result` (with cost) becomes reconstruction from chunks |
| Codex | vendored companion → app-server (today), or `codex exec --json` | uniform client; `read-only`/`workspace-write` as modes | `codex-acp` wraps **the same app-server** with a bundled codex ^0.160.1 (installed 0.163.0 [local-run]); no new capability |
| dsh | `dsh --profile headless` (native) [other report] | **native, automation-only**: session list/resume/close, model and effort verified via config options, `usage_update`, permission channel from sandbox escalations | prerelease only; no `session/load` (resume only); single workspace |
| OpenCode | `opencode run --format json [--auto]` | session resume/fork/list; per-tool `ask` routed to the broker; config options | an extra local HTTP server; defaults are permissive, so the broker sees almost nothing unless the config says `"ask"` |
| pi | `pi --mode json` / `--mode rpc` | uniform client | `pi-acp` is community (0.0.x) and spawns `pi --mode rpc` anyway; no tool permission prompts; no thought separation; one session per connection |
| Gemini / Qwen / Kimi / Goose | each has its own headless flags [unverified] | one client covers all four, with real client-mediated fs and terminal for Kimi and Goose | per-agent quirks (Gemini fs fallback, Kimi has no model selection over ACP) |

Net effect:

- ACP removes per-harness **output parsing and session plumbing**: one NDJSON JSON-RPC client instead of N output dialects.
- It does **not** remove per-harness profiles: commands, env, home isolation, config-option ids, `rawInput` extractors, error patterns, ToS notes.
- It adds no isolation beyond what the harness already has.

### 4.7 Recommendation and size

1. **Add `transport: acp` to the channel-profile registry proposed in 00 §3.**
   - Profile fields: `command`, `args`, `minAgentVersion`, `requiredCaps`, `configOptions{model, effort, mode}`, `readOnlyMode`, `permissionExtractor`, `policy`, `homeEnv`, `patterns`, `family`.
   - First profile: **dsh** (DeepSeek family).
   - Optional profiles: OpenCode, Kimi, Goose, Qwen and Gemini, gated by a per-profile `sandbox:` declaration. ACP-unsandboxed profiles stay off risk-marked phases.
2. **Keep native paths** for `claude -p` (GLM and DeepSeek via `ANTHROPIC_BASE_URL`), Codex (companion) and pi (`--mode json`). Revisit CAA only if its permission channel is needed headless; `claude -p --permission-prompts host` should be evaluated first.
3. **Client implementation.**
   - Hand-roll about 400–600 lines in plain Node (estimate): NDJSON framing, id-correlated requests, three inbound handlers (`session/update`, `session/request_permission`, and -32601 for the rest), cancel logic and the final-message reducer. This keeps the wrappers dependency-free (00 §2).
   - Test against a **stub ACP agent fixture** (the same pattern as `zcode-stub.cjs`), and validate every message against the vendored `schema/v1/schema.json`.
   - Avoid the TS SDK for now: 2.0.0 broke client APIs one day before this report.
4. **Treat the broker as defence in depth.**
   - Default policy: "deny every escalation, network fetch and unknown kind; allow worktree edits; reads by deny-glob".
   - Count denials; acpx-style "all denied" becomes a `NEEDS_AUTHORIZATION`-like signal.
   - Real containment for unsandboxed harnesses is a separate `sandbox-exec` wrapper project. It applies to ZCode yolo as well.

---

## 5. Risks

| Risk | Detail | Evidence |
|---|---|---|
| Not a sandbox | Permission prompts are a MAY. Most agents execute tools internally. Gemini's fs proxy falls back to local fs for out-of-root paths. v2 removes client fs and terminal. | §1.5–1.6, §4.3 |
| Version churn | v2 draft; TS SDK 2.0.0 breaking (2026-10-19); CAA ~weekly releases; the model API was removed mid-2026; adapters still call `unstable_setSessionModel` | §1.1, §2.2 |
| Adapter trust and ToS | CAA and CXA are not Anthropic or OpenAI products. CAA ships `--hide-claude-auth` because some integrations "must never bill a claude.ai subscription". A secondary source says Anthropic restricted subscription OAuth in third-party tools in April 2026. The community `glm-acp-agent` uses the Z.ai Coding Plan outside Z.ai's tools. | [source:CAA:src/hide-claude-auth.ts] [third-party:https://cookbook.solomonneas.dev/ai-stack/claude-cli-to-acp-migration/] [unverified ToS] |
| dsh maturity | The ACP package `agentInfo.version` is `0.0.1`; all recent releases are prereleases | [source:DSH:packages/acp/acp/src/index.ts:186] `gh api` |
| Error semantics | No standard quota or rate-limit code; per-turn token usage is unstable; failures are free-text JSON-RPC errors, so errorClass stays pattern-based per agent | §1.3–1.4 |
| Process trees | adapter → CLI → app-server or internal HTTP server (OpenCode). Cancel and timeout must kill the whole group (existing `killGroup`). | [source:CXA:README.md] [source:OC:…/cli/cmd/acp.ts] |
| Final-message ambiguity | pi-acp mixes reasoning into message chunks; agents without `messageId` need heuristics | §4.4 |
| Runtime downloads | The registry and acpx default to `npx -y`, which conflicts with the plugin's pinned-install stance | §3 |

## 6. Open questions

1. Does `dsh --profile acp` let a client choose the sandbox mode (`read-only` for reviewers) per session over ACP? Is it a config option, a profile patch, or neither? Which tool calls raise `approval/request` under the default ACP profile?
2. CAA with `sandbox.enabled` passed via `_meta.claudeCode.options.settings`: do Bash's unsandboxed-retry prompts reach `canUseTool` (and so the broker) in SDK mode, and does `sandbox.failIfUnavailable` work there? [unverified]
3. Exact env names for isolating OpenCode's and Goose's config and data homes, and whether `opencode acp` honours a config injected via env (to force `"*":"ask"`).
4. ToS:
   - Is driving Claude Code through CAA against GLM or DeepSeek Anthropic-compatible endpoints with the user's API key compliant for each provider?
   - Is any subscription (Claude, ChatGPT, Z.ai Coding Plan) permitted through an ACP adapter?
5. Does `initialize` or `session/new` make network or model calls for each agent? This decides whether `doctor` (offline) can include `initialize`. CAA runs `claude auth status`; dsh probes image capability against the route.
6. Gemini, Qwen, Goose, MiniMax, Cline, Augment, Cursor, Copilot: session resume support and permission behaviour in their headless or yolo equivalents. These were not verified here.
7. Should ACP v2's `subject.command{command,cwd}` (draft) be targeted, since it would let the broker see shell commands uniformly? It is gated on v2 stabilization.

## Sources (primary unless marked)

- ACP spec, schema and RFDs: https://github.com/agentclientprotocol/agent-client-protocol (tag `schema-v1.26.0`); site https://agentclientprotocol.com
- Registry: https://github.com/agentclientprotocol/registry
- SDKs: https://github.com/agentclientprotocol/typescript-sdk · https://github.com/agentclientprotocol/python-sdk · https://github.com/agentclientprotocol/rust-sdk
- Adapters and agents:
  - https://github.com/agentclientprotocol/claude-agent-acp (v0.94.0)
  - https://github.com/agentclientprotocol/codex-acp (v2.2.2)
  - https://github.com/deepseek-ai/deepseek-harness (dsh-v0.2.1-rc.2)
  - https://github.com/anomalyco/opencode (v1.19.3)
  - https://github.com/google-gemini/gemini-cli (v0.64.0)
  - https://github.com/QwenLM/qwen-code (v0.25.3)
  - https://github.com/MoonshotAI/kimi-cli (1.52.0)
  - https://github.com/block/goose (v1.55.0)
  - https://github.com/svkozak/pi-acp (v0.0.34)
- Clients: https://github.com/openclaw/acpx (v0.19.6)
- Claude Code sandbox docs: https://code.claude.com/docs/en/sandboxing
- Secondary (leads only): https://zed.dev/blog/claude-code-via-acp · https://cookbook.solomonneas.dev/ai-stack/claude-cli-to-acp-migration/ · https://codex.danielvaughan.com/2026/06/10/agent-client-protocol-microsoft-intelligent-terminal-codex-cli-multi-agent-ide-ecosystem/

## Fact-check log (2026-10-20)

Each row was checked by opening the primary source myself: `gh api` raw content at the cited tag, `gh api` releases and repo metadata, `npm view --json`, the local `--help` output of claude 2.1.302 and codex 0.163.0, and a read-only string count over the ZCode 3.15.1 bundle. No package was installed, no adapter was run, and no model endpoint was called.

| Claim | Verdict | Evidence |
|---|---|---|
| `schema-v1.26.0` and `schema-v2.0.0-alpha.9` were released on 2026-10-16; wire `protocolVersion` is the integer 1 | confirmed | `gh api repos/agentclientprotocol/agent-client-protocol/releases`: schema-v1.26.0 at 2026-10-16T10:03:24Z, schema-v2.0.0-alpha.9 at 10:03:30Z (prerelease); schema/v1/CHANGELOG.md "1.26.0 … 2026-10-16"; initialization.mdx:86 "a single integer that identifies a MAJOR protocol version" |
| "Rust crate v1.12.0 the same day" | corrected | Tag `v1.12.0` (2026-10-16) is the spec repo's `agent-client-protocol-schema` crate (Cargo.toml@v1.12.0). The `agent-client-protocol` SDK crate is in rust-sdk, at v3.4.0 (2026-10-16) |
| Stable v1 methods: initialize, authenticate, logout, session/new, load, resume, close, list, delete, prompt, cancel, set_mode, set_config_option. providers/* and session/fork are unstable only | confirmed | ACP@1.26 schema/v1/meta.json `agentMethods` (13 entries, exact match); meta.unstable.json adds providers_list/set/disable, session_fork, mcp_message |
| Agent→client methods, including elicitation/create\|complete; `$/cancel_request` is a protocol method | confirmed | meta.json `clientMethods` and `protocolMethods` |
| No `session/set_model`; the unstable session model API was removed in 0.13.5 (2026-06-01) | confirmed | CHANGELOG.md:274 under "0.13.5 … 2026-06-01"; PR #1325 merged 2026-06-01T11:56Z; 0 hits for `set_model`/`SetSessionModel` in schema.json and schema.unstable.json |
| Stop reasons are only end_turn, max_tokens, max_turn_requests, refusal, cancelled; `error` exists only in unstable subagent state | confirmed | schema.json `#StopReason` (5 consts); schema.unstable.json `ErrorStopReason` is referenced only from `IdleStateUpdate` (the subagent/child state) |
| Error codes -32700/-32600/-32601/-32602/-32603/-32800/-32000/-32002, with no quota or rate-limit code | confirmed | schema.json `#ErrorCode` |
| The v2 draft removes client `fs/*`, `terminal/*` and the `fs`/`terminal` capabilities | confirmed | docs/rfds/v2/client-filesystem-terminal-capabilities.mdx "Remove the following standard v2 Client methods" |
| RFD quote "mostly stuck to their standard implementations" | corrected | The verbatim text is "most stuck to their standard implementations" |
| v2: `session` capability makes list/resume/close required; `request_permission` gets `title` plus `subject` (`tool_call` \| `command{command,cwd}`) | confirmed | docs/rfds/v2/required-session-methods.mdx; docs/rfds/v2/permission-requests.mdx:11,53-68 |
| v2 draft since 2026-07-20; quote "various pieces can, and will, change"; gate behind version negotiation AND feature flags | confirmed | docs/announcements/acp-v2-draft.mdx:9,59,61 |
| Lead maintainers since 2026-02-18: Ben Brandt and Sergey Ignatov | confirmed | docs/announcements/sergey-ignatov-lead-maintainer.mdx ("Published: February 18, 2026") |
| `@agentclientprotocol/sdk` 2.0.0 was published 2026-10-19, is breaking, and removes ClientSideConnection/AgentSideConnection; 1.0.0 was 2026-06-24; zod peer dependency; 7.9 MB unpacked | confirmed | npm `time` 2.0.0 = 2026-10-19T20:56:04Z, 1.0.0 = 2026-06-24; unpackedSize 7,923,444; peer zod ^3.25.76 \|\| ^4.0.0; typescript-sdk CHANGELOG.md@v2.0.0 "BREAKING CHANGES: AgentSideConnection, ClientSideConnection … have been removed" |
| `@zed-industries/agent-client-protocol` is deprecated | confirmed | npm deprecation message "renamed to @agentclientprotocol/sdk" |
| Python SDK repo at 1.0.0rc3 (2026-10-12, pre-release) | confirmed | `gh api repos/agentclientprotocol/python-sdk/releases` |
| Registry has 43 agents, served from a CDN | confirmed | 43 `*/agent.json` in registry@main; README lists cdn.agentclientprotocol.com/registry/v1/latest/registry.json |
| Stabilization dates: session/close 2026-04-23, messageId 2026-06-05, `$/cancel_request` 2026-06-29, transports WG 2026-04-22 | confirmed | the matching docs/announcements/*.mdx "Published" lines |
| `session/update` kinds; baseline MUST methods; `session/set_mode` "will be removed in a future version"; config-option categories; "Falling back to a different model due to rate limits" | confirmed | prompt-turn.mdx:14-29; initialization.mdx:236,277; session-modes.mdx:8; session-config-options.mdx:193-210,351-355 |
| "The Agent MAY request permission"; "Clients MAY automatically allow or reject …" | confirmed | tool-calls.mdx:135,191 |
| Tool `name` **and** `kind` are "opaque, informational metadata" | corrected | tool-calls.mdx:41-43: the sentence covers `name` only; `kind` "help[s] Clients choose appropriate icons" (line 68) |
| Per-turn token usage RFD is "intentionally kept in Draft" | confirmed | docs/rfds/end-turn-token-usage.mdx |
| stdio only, newline-delimited, stdout protocol-only; Streamable HTTP "in discussion" | confirmed | docs/protocol/v1/transports.mdx; WebSockets and HTTP appear in transports-working-group.mdx |
| Unstable `providers/set{providerId, apiType, baseUrl, headers}`, with apiType anthropic\|openai\|azure\|vertex\|bedrock\|custom | confirmed | schema.unstable.json `SetProviderRequest`, `LlmProtocol` |
| claude-agent-acp v0.94.0: Apache-2.0, deps claude-agent-sdk 0.3.303 and ACP SDK 2.0.0; built-in tools since 0.18.0 ("won't use client capabilities for files or terminals") | confirmed | CAA package.json@v0.94.0; CHANGELOG.md 0.18.0 entry; repo license via `gh api` |
| CAA spreads `process.env` into the SDK env; settings.json env is applied after the subprocess env | confirmed | CAA src/acp-agent.ts:11185-11203, with the comment "Claude Code applies env from settings.json after the subprocess env" and `env = {...process.env, ...userProvidedOptions?.env, ...providerEnv, …}` |
| CAA: Claude Code applies bypassPermissions before canUseTool; only bypass-immune requests reach the callback | confirmed | CAA src/acp-agent.ts:10115-10120 (verbatim comment) |
| CAA bypass is clamped to `default` as root; capabilities load/resume/close/list/delete/fork; 30 s force-cancel grace; `--hide-claude-auth` ("must never bill a claude.ai subscription") | confirmed | src/permissions/modes.ts; acp-agent.ts:2950-2995, 427; src/hide-claude-auth.ts:1-6 |
| CAA was `zed-industries/claude-code-acp`; 29 releases since 2026-08-21 | confirmed | `gh api repos/zed-industries/claude-code-acp` redirects to agentclientprotocol/claude-agent-acp; 29 releases counted |
| CAA 0.94.0 released one day after SDK 2.0.0 | corrected | Both shipped on 2026-10-19: SDK at 20:56Z, CAA at 21:31Z |
| codex-acp v2.2.2 starts the Codex App Server; modes read-only/workspace-write (on-request, networkAccess false), agent (auto_review), agent-full-access ("never", dangerFullAccess); bundles @openai/codex ^0.160.1; env CODEX_PATH, CODEX_API_KEY, OPENAI_API_KEY, CODEX_CONFIG, MODEL_PROVIDER; 15 releases in 60 days | confirmed | CXA src/AgentMode.ts, README.md:7,42-75, package.json@v2.2.2, src/CodexAcpServer.ts:474-504; release count |
| dsh ships a native automation-only ACP server (`dsh --profile acp`): close/list/resume but no session/load; `model`/`reasoning_effort` options; approval/request bridged to one-shot allow-once/reject-once; agentInfo version 0.0.1 | confirmed | DSH packages/acp/acp/README.md; src/index.ts:156-190 (version '0.0.1' at :186); subagent-acp README.md:55-56 (`command: dsh`, `args: ['--profile','acp',…]`); dsh-tool-bash README.md:70 (approval comes from the sandbox-escalation retry) |
| dsh: "The 100 newest GH releases are all prereleases" | corrected | Only 31 releases exist, and all are prereleases |
| dsh defaults deepseek-official / deepseek-v4-flash; sandbox modes read-only/workspace-write/danger-full-access; "Network … outside this vocabulary"; dsh-subagent-acp env scrub, DSH_HOME, stop-reason mapping | confirmed | DSH packages/bundle/acp-app/cordis.patch.yml; docs/subsystems/sandbox.md:5,11; packages/subagent/subagent-acp/README.md:41-65,97-101 |
| Gemini's ACP fs proxy falls back to the local fs outside the workspace root and under ~/.gemini | confirmed | GEM packages/cli/src/acp/acpFileSystemService.ts `shouldUseFallback` (`!isWithinRoot(root) \|\| isWithinRoot(~/.gemini)`) |
| Gemini modes default/autoEdit/yolo/plan; `unstable_setSessionModel` in the docs | confirmed | GEM acpUtils.ts `buildAvailableModes` (plan only when enabled); docs/cli/acp-mode.md:92 |
| OpenCode: request_permission only for `ask` (`permission.asked` events); defaults mostly allow, only doom_loop/external_directory ask, .env denied; once/always/reject; RPC error → reject; mirrors edits via fs/write_text_file; starts a local HTTP server | confirmed | OC permissions.mdx:166-180; src/acp/permission.ts; src/cli/cmd/acp.ts (`Server.listen`); src/acp/service.ts:97-131 |
| pi-acp v0.0.34 spawns `pi --mode rpc`; no fs/terminal delegation; permission requests only for extension-UI confirms; no thought stream; `unstable_setSessionModel`; `closeAllExcept`; 1 release in 60 days | confirmed | PIA README.md:5,9-11,201-203; src/acp/session.ts:1002 (`extensionUiToolCall`); agent.ts:1153, 381; releases (v0.0.34 on 2026-09-24) |
| Kimi multi-session; load without replay; ACPKaos/Terminal; no set_mode/set_model; -32000 when not logged in | confirmed | KIMI src/kimi_cli/acp/AGENTS.md; docs/en/reference/kimi-acp.md:23 |
| Qwen fs local fallback on some errors; capabilities load/list/resume | confirmed | QW service/filesystem.ts:32-170; acpAgent.ts:5529-5538 |
| Goose client fs/terminal use; `AcpProvider` | confirmed | GOOSE crates/goose/src/acp/fs.rs (imports CreateTerminalRequest, ReadTextFileRequest, …), provider.rs |
| Registry commands and versions (gemini --acp 0.64.0, qwen --acp --experimental-skills 0.25.3, minimax-code pins 0.2.7, glm-acp-agent 1.15.0, cline/auggie/copilot --acp, cursor-agent acp) | confirmed | registry@main */agent.json; npm `@minimax-ai/code` 0.6.12 with bin `mcode`; npm glm-acp-agent author stefandevo |
| ZCode 3.15.1 bundle has no ACP strings; local claude 2.1.302 and codex 0.163.0 help contain no "acp" | confirmed | local-run: Info.plist 3.15.1; `grep -a -c` = 0 for `agentclientprotocol`, `session/request_permission` and `session/prompt` in glm/zcode.cjs and app.asar; `claude --help`/`codex --help` 0 hits for "acp" (case-insensitive) |
| claude flags `--permission-prompts host\|none`, `--permission-prompt-tool`, `--restricted`, `--max-budget-usd`, `--allowedTools`/`--disallowedTools` | confirmed | local `claude --help` (2.1.302) |
| Claude sandbox settings `sandbox.enabled`, `allowUnsandboxedCommands:false`, `failIfUnavailable`, Seatbelt; file tools run outside the sandbox | confirmed | code.claude.com/docs/en/sandboxing |
| acpx v0.19.6: MIT, Node ≥22.13, detached queue owner holding the ACP connection, Unix socket, `--no-wait`, idle TTL 300 s; SIGTERM→SIGKILL with an 8 s budget and birth-identity checks; exit codes 0/1/2/3/4/5/130 with 5 = every permission request denied; permission flags and policy keys; "not an OS sandbox"; `--no-terminal` caveat; 15 releases in 60 days | confirmed | ACPX package.json, docs/sessions.md:172-191, docs/runtime-process-lifecycle.md:53-80, docs/exit-codes.md, docs/permissions.md:14-42,129-135,164-184, README.md:77; release count |
| acpx "Built-in profiles launch adapters via `npx -y`" | corrected | docs/agents.md: only claude/codex/opencode/kilocode use `npx -y` and pi uses `npx pi-acp`; most of the 26 built-ins call local binaries |
| ACP clients page lists Hydra, Raven (DAG), Remote Agent Server ("asynchronous Task API"), Kronos, AgentConnect, CompozyOS | confirmed | ACP@1.26 docs/get-started/clients.mdx |
| Secondary source: Anthropic restricted subscription OAuth in third-party tools in April 2026 | confirmed (as a secondary-source statement only) | The cookbook.solomonneas.dev URL now 308-redirects to escoffierlabs.dev/cookbook/ai-stack/claude-cli-to-acp-migration. That page says Anthropic "blocked subscription OAuth from third-party harnesses in April 2026" and refers to Claude Max only. Anthropic's own ToS text was not checked |
| messageId reference counts (CAA 37, DSH 6) and pi-acp none | confirmed | `grep -c messageId`: CAA acp-agent.ts 37 lines; DSH acp src session.ts 4 + updates.ts 2; pi-acp src 0 |

**Reliability assessment.** I checked every one of the 15 key claims against the primary source at the cited tag, plus more than 30 further statements. All 15 key claims hold. The six errors I found and corrected are all peripheral:

- a mislabelled Rust crate version;
- a one-word misquote ("mostly" for "most");
- a quote extended from `name` to `kind`;
- "100 newest releases" where only 31 exist;
- "one day before" where the SDK and CAA shipped about 35 minutes apart on the same day;
- an over-broad "built-in profiles use `npx -y`" for acpx.

None of these changes the report's design conclusions. Those conclusions are: ACP is not a security boundary; dsh is the best ACP fit; keep the native paths for claude, Codex and pi; hand-roll a v1 client instead of taking TS SDK 2.0.0. The ToS questions stay open, as the report itself says. The only evidence for the April 2026 subscription-OAuth restriction is a secondary blog, now redirected, and it covers Claude Max only. Overall reliability is high.
