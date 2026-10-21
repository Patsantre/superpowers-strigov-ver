# 04 — "DSH" identified + headless coding-harness survey (Oct 2026)

Researcher key: `04-dsh-and-harness-survey`. Date: 2026-10-20. Read-only research: nothing installed or executed beyond `gh api` / `npm view` metadata reads.
Evidence tags: `[local-run]`, `[source:<owner/repo>@<ref>:<path>]`, `[docs:<url>]`, `[third-party:<url>]`, `[unverified]`.
Abbreviation used below: `DSH@tag` = `deepseek-ai/deepseek-harness@dsh-v0.2.1-rc.2`.

## Bottom line

1. **"DSH" = DeepSeek Harness (`dsh`)**: DeepSeek's own open-source agent harness, `deepseek-ai/deepseek-harness`, MIT, created 2026-08-13, ~255k stars, npm `@deepseek-ai/dsh` (latest `0.2.1-rc.2`, 2026-10-17). It is in **developer preview**, every GitHub release so far is a prerelease, and the README warns of breaking changes. Nothing else comes close (see A.1).
2. DSH has a usable headless contract: `dsh --profile headless [--json] [--session-id <id>] [task | -]`. It prints the final text to stdout (or an NDJSON event stream ending in `final`), exits 0/1, and supports resume by session id. The model is chosen through a `--patch` YAML overlay, not a `--model` flag. It has a native OS sandbox (Seatbelt / bwrap+Landlock / Windows ACL) with `read-only | workspace-write | danger-full-access` modes, set by `DSH_PERMISSION_MODE`.
3. DSH can reach any **OpenAI Chat Completions, OpenAI Responses or Anthropic Messages** endpoint, including local servers, through the vendored pi-ai library (`@earendil-works/pi-ai`). The headless profile deliberately **ignores the GUI credential store**: keys come from env, then `<cwd>/.env`, then `$DSH_HOME/.env`. That fits the plugin's no-credentials-in-chat rule.
4. DSH gotchas that an adapter must neutralize:
   - By default it **uploads the canonical Session log to the official DeepSeek API** (`dsh_session_log`, up to 8 MiB per request). [corrected 2026-10-20: the field rides on every `deepseek-official` (llm-deepseek adapter) request and goes to that route's resolved `baseURL`, including a configured gateway or a `DEEPSEEK_BASE_URL` taken from the repo `.env`; pi-ai routes do not carry it. Source: deepseek-ai/deepseek-harness@dsh-v0.2.1-rc.2:docs/deepseek-llm-api-wire-extensions.md, "The adapter sends the additions to its resolved `baseURL`, including a configured gateway"]
   - It reads project `CLAUDE.md`/`AGENTS.md` and `~/.agents`.
   - It makes an extra LLM call to title each session.
   - `SIGTERM` exits **0**.
   - Approval asks have no answerer in headless mode and fail closed.
5. Survey (B): about 20 headless-capable harnesses. Since 2026 most model vendors ship an **official harness bound to their subscription**:
   - Alibaba → Qwen Code
   - Moonshot → Kimi Code CLI
   - Google → Antigravity CLI (Gemini CLI stopped serving AI Pro/Ultra on 2026-06-18)
   - MiniMax → MiniMax Code
   - Mistral → Vibe
   - DeepSeek → DSH
   - Z.ai → ZCode
6. **Recommended extra adapters (max 3, beyond Claude Code / OpenCode / pi / Codex / ZCode):** (1) **Qwen Code**, (2) **Kimi Code CLI**, (3) **Antigravity CLI**. Runners-up: Mistral Vibe (best CI contract), MiniMax Code (young), Factory Droid (read-only default, closed source). Kilo CLI is an OpenCode fork, so an OpenCode adapter covers it with little extra work.
7. Design implication: output formats cluster into a **Claude-Code-style result envelope** (`type/result/session_id/usage`) and several bespoke NDJSON formats. Headless permission defaults range from "fail-closed" (DSH, Droid read-only) to **"auto-approve everything"** (Crush `run`, Kimi `-p`, Cline default). A universal dispatcher must set the mode explicitly per role and never trust a harness default.

---

## A. Identifying "DSH"

### A.1 Candidates ranked

| Rank | Candidate | Evidence | Likelihood |
|---|---|---|---|
| 1 | **DeepSeek Harness (`dsh`)**, `deepseek-ai/deepseek-harness` | README: "DeepSeek Harness (`dsh`) is an open-source agent harness developed by DeepSeek AI" [source:DSH@tag:README.md]. Binary `dsh` (`bin = { dsh: 'lib/bin.js' }`) [local-run: `npm view @deepseek-ai/dsh bin`]. 255,152 stars; topic `dsh`; large `awesome-dsh-plugin` ecosystem [local-run: `gh api repos/deepseek-ai/deepseek-harness`, `gh search repos "DeepSeek Harness"`] | **~97%** |
| 2 | Codewhale (formerly `deepseek-tui`), `codewhale-hq/Codewhale` | Community DeepSeek-oriented Rust TUI, now provider-neutral; "began as `deepseek-tui`" [source:codewhale-hq/Codewhale@v0.10.1:README.md]. Never abbreviated "DSH" | ~2% |
| 3 | "Deep Shell", `gokul6350/dsh-shell` | 28-star hobby chat/terminal app [local-run: `gh search repos "dsh shell"`] | <1% |
| 4 | `dsh` (dancer's/distributed shell) | Classic parallel-SSH utility; not an agent [unverified, from memory] | <1% |
| 5 | Dictation slip for Droid / Crush / "DeepSeek" | No need: an exact match exists | <1% |

### A.2 DSH, harness template (sections 1–17)

#### 1. Identity

| Field | Value |
|---|---|
| Repo | `deepseek-ai/deepseek-harness` (default branch `master`), TypeScript, built on the Cordis plugin framework, "everything is a plugin" [source:DSH@tag:README.md] |
| License | MIT [local-run: gh api license = MIT] |
| Maintainer | DeepSeek-AI [source:DSH@tag:README.md] |
| Created / last push | 2026-08-13 / 2026-10-17 [local-run] |
| Latest | `dsh-v0.2.1-rc.2` (2026-10-17, **prerelease**). **No non-prerelease release exists** (`releases/latest` → 404). npm dist-tags `latest: 0.2.1-rc.2`, `alpha: 0.2.1-alpha.5` [local-run] |
| Cadence | about 30 tags from 2026-08-19 to 2026-10-17 (rc/alpha every few days) [local-run] [corrected 2026-10-20: 32 tags / 31 GitHub releases, from `dsh-v0.1.0-rc.7` (2026-08-17) to `dsh-v0.2.1-rc.2` (2026-10-17); `gh api repos/deepseek-ai/deepseek-harness/tags` and `/releases`] |
| Activity | 255k stars, 30.8k forks [local-run] |
| Status | "developer preview … THERE WILL BE COMPATIBILITY-BREAKING CHANGES" [source:DSH@tag:README.md]. "not undergone a security audit" [source:DSH@tag:SAFETY.md] |
| OS | Linux, macOS and Windows sandbox backends [source:DSH@tag:packages/sandbox/sandbox-local/README.md]. Desktop app, Web UI, Python SDK wheel `deepseek-harness-sdk` [source:DSH@tag:docs/user/guide/python-sdk.md] |
| Runtime | Node `^22.19.0 \|\| >=24.0.0` [source:DSH@tag:package.json]. The local Node 26.11 satisfies this |
| Install | `npx @deepseek-ai/dsh <profile>` or from source [source:DSH@tag:README.md] |

#### 2. Headless invocation

- **Launcher grammar:** `dsh [--profile] <name> [--patch <yml>]… [--from-default-profile <tpl>] [app-args…]`. The first token the launcher does not recognize starts the app arguments [source:DSH@tag:docs/cli-help.md] [source:DSH@tag:apps/cli/README.md].
- **One-shot command:**
  ```sh
  dsh --profile headless [--json] [--session-id <id>] "task text"
  echo "task" | dsh --profile headless          # or a lone "-" reads stdin
  dsh --profile headless --patch /abs/job.patch.yml --json -   # recommended form for an adapter
  ```
  Sources: [source:DSH@tag:docs/cli-help.md] [source:DSH@tag:packages/bundle/headless/README.md].
- **Prompt transport:**
  - The task comes from argv (words joined with spaces) or stdin. Use stdin when there is no positional argument or a lone `-`.
  - A positional task means stdin is not read.
  - A blank positional task or an empty pipe is a usage error, exit 1 [source:DSH@tag:packages/bundle/headless/README.md].
  - There is no documented size limit. argv is bounded by the OS ARG_MAX, so use stdin [unverified].
- **Other surfaces:**
  - `dsh --profile acp`: Agent Client Protocol over stdio. Supports session new/list/resume/close, `set_config_option` for `model`/`reasoning_effort`, and machine approval decisions.
  - `dsh --profile sdk` / `sdk-minimal`: stdio JSON-RPC.
  - `dsh web`: listens on 127.0.0.1:3080.
  
  Sources: [source:DSH@tag:packages/acp/acp/README.md] [source:DSH@tag:docs/cli-help.md].
- **Launcher constraint:** headless must be started through the `dsh` launcher. Other entry paths fail at startup [source:DSH@tag:packages/bundle/headless/README.md].

#### 3. Output and final-message extraction

| Mode | stdout | stderr | Notes |
|---|---|---|---|
| default | final answer text only | `dsh: reasoning:` sections (live reasoning deltas); on failure `dsh: <code>: <message>` | A run with no assistant message prints an empty line and exits 1 [source:DSH@tag:packages/bundle/headless/README.md] |
| `--json` | NDJSON events: `session` (first; `sessionId`, `cwd`), `status` (`phase` = `turn_start`/`step_start`/`step_end`/`turn_end`, with `reason` on `turn_end` and `usage` on `step_end`), `text`, `thinking`, `tool_call`, `tool_result` (`status: completed\|error`), `final` (last; full text, uncapped), `error` (out-of-turn failure; no `final`) | `dsh:` diagnostics only | Every string except `final` is capped at 8 KiB (`truncated:true`); each event line ≤ 32 KiB. `text`/`thinking` are emitted at commit points, not per token [source:DSH@tag:packages/bundle/headless/src/json-stream.ts] [source:DSH@tag:packages/bundle/headless/README.md] |

- **Exit codes:**
  - 0 means the final `turn/end` completed. 1 means aborted, error, no turn, usage error or startup failure.
  - An in-turn failure still ends with `final` (often empty), so **use the exit code plus the `turn_end` reason as the failure signal** [source:DSH@tag:packages/bundle/headless/README.md].
  - `SIGTERM` → graceful drain, **exit 0**. `SIGINT` → 130. A second signal forces immediate exit. Grace period is 5 s [source:DSH@tag:apps/cli/reference/README.md].
- **Startup failure:** exit 1, with a `Full diagnostics:` line naming `$DSH_HOME/logs/startup-<ts>-<uuid>.log` [source:DSH@tag:apps/cli/reference/README.md].

#### 4. Sessions and resume

- Every run gets a fresh `session-<uuid>`, reported by the `session` event. Resume with `--session-id <id>`; an unknown id fails before the run starts [source:DSH@tag:packages/bundle/headless/README.md].
- **Resume is refused when** any of these hold:
  - the recorded cwd differs (compared after provider-resolved path canonicalization);
  - the session is a subagent or fork;
  - it was made under a preset the profile does not compose;
  - the id is already live in another process.
  
  Source: [source:DSH@tag:packages/bundle/headless/README.md].
- **Storage:** `$DSH_HOME/sessions/<project>/<session>/`, JSONL, Zstandard-compressed by default [source:DSH@tag:packages/bundle/base/cordis.patch.yml] [source:DSH@tag:docs/config-catalog.md#dsh-session-persistence-jsonl]. `$DSH_HOME` defaults to `~/.dsh` [source:DSH@tag:docs/config-catalog.md].
- **Limitation:** the final settlement of a background job may be missing from persisted history at process exit [source:DSH@tag:packages/bundle/headless/README.md].

#### 5. Model and provider selection

- **No `--model` flag in headless.** The run uses the shared `agent-default-model` row (`provider`, `model`, `reasoningEffort`). The base default is `deepseek-official / deepseek-flash` [source:DSH@tag:packages/bundle/base/cordis.patch.yml] [source:DSH@tag:docs/config-catalog.md#dsh-agent-default-model].
  - To override per job, use a `--patch` overlay. The layer order is bundle patches → profile `cordis.patch.yml` → `$DSH_HOME/cordis.patch.yml` → `--patch` (last wins, and a patch replaces the whole row `config`) [source:DSH@tag:apps/cli/reference/README.md]:
  ```yaml
  - id: agent-default-model
    config: { provider: my-gw, model: some-model, reasoningEffort: high }
  ```
- **Native DeepSeek route** `llm-deepseek` (Messages transport):
  - API key reference `DEEPSEEK_API_KEY`.
  - Reasoning levels `off/low/high/max`.
  - Built-in catalog `deepseek-flash`, `deepseek-v4-pro`; rc.2 adds "DeepSeek-V4.1-Flash-1017". [corrected 2026-10-20: the rc.2 release note says "Add support for DeepSeek-V4.1-Flash-1017", but no new catalog id was added. `packages/llm/llm-deepseek/src/models.ts` still lists only `deepseek-flash` (display name "DeepSeek-V4.1-Flash") and `deepseek-v4-pro`. The DeepSeek pricing page says `deepseek-flash` is served by DeepSeek-V4.1-Flash-1017]
  
  Sources: [source:DSH@tag:docs/config-catalog.md] [source:DSH@tag:docs/user/guide/providers.md] [local-run: release notes dsh-v0.2.1-rc.2].
- **Third-party and custom routes** go through `llm-pi-ai`, which wraps `@earendil-works/pi-ai` [source:DSH@tag:docs/config-catalog.md#dsh-llm-pi-ai]:
  - Catalog providers include `anthropic`, `openai`, `moonshotai`, `zai`.
  - Custom routes take `api: openai-completions | openai-responses | anthropic-messages`, plus `baseURL`, `apiKeyEnv`, `models`, `compat` switches (`supportsDeveloperRole`, `maxTokensField`, `thinkingFormat: deepseek`), and per-model `reasoningEfforts` mapped onto the `reasoning_effort` wire field [source:DSH@tag:docs/user/guide/providers.md].
  - Local models: any OpenAI-compatible base URL (vLLM priority/budget fields are documented) [source:DSH@tag:packages/llm/llm-pi-ai/README.md].
- **DeepSeek account route** `llm-deepseek-account`:
  - Uses an account token in `x-dsh-auth-token`. Model listing comes from `https://api.deepseek.com/models`, and models are version-gated (`CLIENT_UPGRADE_REQUIRED`).
  - It never falls back to an API key [source:DSH@tag:packages/llm/llm-deepseek-account/README.md].
  - **This route is disabled in headless** (see 6).

#### 6. Auth and credentials

- **GUI and SDK profiles:** saved keys live in `$DSH_HOME/.credentials.yaml` (write-only via the UI) and take precedence over the environment [source:DSH@tag:docs/user/guide/providers.md] [source:DSH@tag:docs/upgrade-guide/v0.2.1-alpha.2/stored-credentials-precedence/guide.md].
- **Headless profile** disables the `credentials`, `authorization` and `deepseek-account` rows:
  - Keys resolve from launch env, then `<invocation cwd>/.env`, then `$DSH_HOME/.env`.
  - GUI-saved keys, pi-ai OAuth grants (e.g. `openai-codex`) and the DeepSeek account sign-in are **ignored**.
  - External chains such as AWS profiles still work.
  
  Sources: [source:DSH@tag:packages/bundle/headless/cordis.patch.yml] [source:DSH@tag:.agents/notes/implemented/architecture/2026-10-12-headless-environment-auth.md].
- **Isolation:** set `DSH_HOME=<adapter-owned dir>` and pass only the needed key variable in the env.
- **Leak and override risks:**
  1. A repository's `.env` can supply provider keys to headless (the cwd `.env` layer). An exported variable always wins, so export an explicit value for the key you use.
  2. A project `.env` that sets proxy variables makes DSH **refuse to start** [source:DSH@tag:docs/user/guide/network-proxy.md].
  3. In default mode, reasoning goes to stderr, so logs may hold sensitive model output [source:DSH@tag:packages/bundle/headless/README.md].
  4. The model never sees secrets; the credentials controller exposes no read path [source:DSH@tag:docs/subsystems/credentials.md]. [corrected 2026-10-20: "no read path" only means the remote credentials API never returns a stored value to UI clients. In headless, every launch `.env` layer is copied into `process.env`, and tool subprocesses get only a name-based scrub (`*KEY*`/`*PASSWORD*`/`*SECRET*`/`*TOKEN*`). File reads are unconfined, so the agent can still `cat` a `.env` or key file. Sources: packages/util/launch-environment/README.md, packages/subprocess/subprocess-local/README.md, apps/cli/reference/README.md ("reads and network access are not confined")]

#### 7. Autonomy for unattended runs

- **Knobs:** `DSH_PERMISSION_MODE` sets the sandbox mode for new sessions (default `workspace-write`). The approval policy is `never` when the mode is `danger-full-access`, otherwise `ask` [source:DSH@tag:packages/bundle/base/cordis.patch.yml].
- **Preset table** [source:DSH@tag:packages/bundle/base/cordis.patch.yml]:
  - `read-only` → read-only + ask
  - `workspace-write` → workspace-write + ask
  - `danger-full-access` → full + never
- **Approval semantics:** `ask` delegates to the composed answerers. With none composed it returns `unavailable`, and callers **fail closed**. `never` returns `rejected` deterministically [source:DSH@tag:docs/subsystems/approval.md].
  - The headless bundle mounts no UI, so escalation requests (for example a sandbox-escape retry) should be denied. The agent sees `[sandbox: file access denied under <mode> mode]` [source:DSH@tag:packages/fs/fs-sandbox/README.md].
  - That headless composes *no* answerer at all is inferred from the bundle patch [unverified; confirm with `--dump-config`].
- **Reviewer role:** `DSH_PERMISSION_MODE=read-only`. File tools reject every mutation (`FS_SANDBOX_DENIED`) and bash runs under a read-only Seatbelt profile [source:DSH@tag:packages/fs/fs-sandbox/README.md] [source:DSH@tag:docs/subsystems/sandbox.md].
- **Allow and deny lists:** no simple CLI flag. Tool rows can be disabled in the patch (e.g. `tool-web`) [source:DSH@tag:packages/bundle/base/cordis.patch.yml].

#### 8. Sandboxing

- **Native, fail-closed.** macOS Seatbelt (allow-default + `deny file-write*` except workspace and temp); Linux bwrap then Landlock; Windows ACL restricted token [source:DSH@tag:packages/sandbox/sandbox-local/README.md].
- **Scope:**
  - Covers file writes only. "Network and process visibility are outside this vocabulary" [source:DSH@tag:docs/subsystems/sandbox.md].
  - `workspace-write` permits the session cwd and temp, so `.git` stays writable [source:DSH@tag:packages/fs/fs-sandbox/README.md]. [corrected 2026-10-20: this holds only when `.git` sits under the cwd. A linked git worktree keeps its metadata in `<main>/.git/worktrees/…`, which is outside the write allow-list (see 04b §8). The Seatbelt profile allows writes only to `/dev/null`, the workspace root and temp: packages/sandbox/sandbox-local/src/profiles.ts]
  - Enforcement is reported as `full` or `partial`. Seatbelt depends on the deprecated `sandbox-exec` [source:DSH@tag:packages/sandbox/sandbox-local/README.md].
- SAFETY.md: sandboxing "do[es] not guarantee isolation" [source:DSH@tag:SAFETY.md].

#### 9. Config and state isolation; side effects

| Item | Behavior | Control |
|---|---|---|
| Home | `$DSH_HOME` or `~/.dsh`: profiles, sessions, logs, `.env`, `.anonymous-user-id` | export `DSH_HOME` [source:DSH@tag:docs/upgrade-guide/v0.2.1-alpha.1/instruction-home-override/guide.md] |
| Profile auto-init | `headless`, `web`, `sdk`, `acp` profiles auto-initialize from shipped templates on first use | — [source:DSH@tag:apps/cli/README.md] |
| Instruction files | Loads `$DSH_HOME/AGENTS.md`, `$DSH_AGENTS_HOME` (default `~/.agents`)`/AGENTS.md`, then project-chain `AGENTS.md`, `CLAUDE.md`, `AGENTS.local.md`, `CLAUDE.local.md` (root marker `.git`), capped by `maxBytes: 65536` | point `DSH_AGENTS_HOME` at an empty dir; patch `agent-instructions` [source:DSH@tag:packages/context/agent-instructions/README.md] [source:DSH@tag:packages/bundle/base/cordis.patch.yml] |
| Skills | Project roots + `$DSH_HOME` + `~/.agents` skill roots, watched | `includeDefaultRoots: false` on `skill-filesystem` [source:DSH@tag:docs/config-catalog.md] |
| **Session-log upload** | `session-log-deepseek` (base row, default `enabled: true`) sends canonical Session-log events (incl. tool events) as `dsh_session_log` alongside **official DeepSeek API** requests, ≤ 8 MiB per request, at-least-once [corrected 2026-10-20: it is sent with every `deepseek-official` route request (agent, compaction and session-title calls) to that route's resolved `baseURL`, gateways included; docs/deepseek-llm-api-wire-extensions.md] | patch `- id: session-log-deepseek\n  config: { enabled: false }` [source:DSH@tag:packages/session/session-log-deepseek/README.md] |
| Extra LLM call | `session-title-llm` (first-prompt title, `maxOutputTokens 4096`, 60 s timeout) runs on every new session | disable the row in the patch [source:DSH@tag:packages/bundle/base/cordis.patch.yml]; that disabling it does not break headless is [unverified] |
| Telemetry | OTel session telemetry `mode: FEEDBACK_ONLY` (exports only after explicit user feedback) to `dsh-otel-collector.deepseeksvc.com`; carries the anonymous id | `DSH_TELEMETRY_DISABLED=<any>` [source:DSH@tag:packages/bundle/base/cordis.patch.yml] |
| Web tools | `web_search` / `web_fetch` enabled in base (DeepSeek search uses `DEEPSEEK_API_KEY`) | disable `tool-web` [source:DSH@tag:packages/bundle/base/cordis.patch.yml] |
| Hooks / CC mods | `dsh-hooks-claude-code`, `dsh-hooks-codex` and `claude-code-mods` exist as **experimental, opt-in** plugins | not in base [source:DSH@tag:docs/config-catalog.md]; absence from the headless default tree is [unverified] |
| Proxy | Honors `HTTP(S)_PROXY`/`ALL_PROXY`; no SOCKS; ignores the OS proxy; TUN mode works transparently | the user's TUN mode is fine [source:DSH@tag:docs/user/guide/network-proxy.md] |

#### 10. Concurrency and cancellation

- **Process model:** one process per run; opens no listening port and leaves nothing running [source:DSH@tag:packages/bundle/headless/README.md].
- **Signals:** `SIGINT`/`SIGTERM` dispose the plugin tree (5 s budget) [source:DSH@tag:apps/cli/reference/README.md].
- **Child processes:** bash tool children are killed with escalation after `graceMs` [source:DSH@tag:docs/config-catalog.md#dsh-bash-local]. Whether DSH places children in their own process group is [unverified]. The adapter should spawn detached and kill the whole group. [corrected 2026-10-20: packages/subprocess/subprocess-local/README.md@rc.2 settles this. On macOS, tool commands run in **detached process groups** (the fallback); Linux uses user-systemd scopes and Windows uses Job objects. SIGKILL, OOM or a crash of dsh leaves those groups running ("need an external supervisor"). So killing dsh's own process group does not reach tool children on macOS; record and kill the descendant PGIDs (see 04b §10)]
- **Shared state:**
  - Storage units do not serialize concurrent writes ("ordering belongs to the caller") [source:DSH@tag:docs/subsystems/storage.md].
  - Two headless processes sharing one `DSH_HOME` probably write separate session dirs, but they could race on shared JSON units such as the projection cache or settings [unverified].
  - Use a per-workspace lock (as zcode-dispatch does) and refuse concurrent `--session-id` reuse; DSH refuses that case only within one process.

#### 11. Error signatures

- **Form:** stderr `dsh: <CODE>: <message>` (in-turn) or `dsh: <message>` (driver failure). `--json` also emits an `{"type":"error","message":…}` event for out-of-turn failures [source:DSH@tag:packages/bundle/headless/src/index.ts].
- **Codes are stable**; route on the code, never the message text [source:DSH@tag:packages/llm/llm/README.md] [source:DSH@tag:packages/llm/llm-deepseek/README.md] [source:DSH@tag:packages/llm/llm-pi-ai/README.md] [source:DSH@tag:packages/llm/llm-deepseek-account/README.md]:

| Plugin class | DSH codes |
|---|---|
| auth | `AUTH` (401/403), `INVALID_CREDENTIAL`, `MISSING_CREDENTIAL`, `ACCOUNT_SIGN_IN_REQUIRED` |
| quota | `QUOTA`, `ACCOUNT_QUOTA` |
| rate limit | `RATE_LIMIT` (retried first by `dsh-llm-retry`) |
| model-not-selected | `UNKNOWN_MODEL`, `NO_ADAPTER`, `MODEL_UNSUPPORTED`, `CLIENT_UPGRADE_REQUIRED`, `UNSUPPORTED_REASONING_EFFORT` |
| context | `CONTEXT_WINDOW_EXCEEDED`, `IMAGE_OFFLOAD_REQUIRED` (auto-handled) |
| network / transient | `TRANSPORT`, `TIMEOUT`, `SERVER`, `HTTP_<status>`, `STREAM_CLOSED`, `MALFORMED_RESPONSE`, `EMPTY_RESPONSE` |
| launch | exit 1 + `Full diagnostics:` startup log; `SANDBOX_UNAVAILABLE`; proxy-in-project-`.env` refusal |

#### 12. Structured output and verdict support

- No `--json-schema` or structured-output flag in headless [source:DSH@tag:docs/cli-help.md]. Use the plugin's line-1 status token in the `final` text.
- The `final` event carries the lossless answer [source:DSH@tag:packages/bundle/headless/README.md].

#### 13. Usage and cost reporting

- `status/step_end` carries `usage{inputTokens, outputTokens, totalTokens?, cacheReadTokens?, cacheWriteTokens?, reasoningTokens?}`. It is omitted when any attempt in the step lacked usage [source:DSH@tag:packages/bundle/headless/src/json-stream.ts].
- No cost figure. Account balance is GUI-only (`getBalance`) [source:DSH@tag:docs/subsystems/credentials.md].

#### 14. ToS notes (brief)

- **First-party fit:** DSH is DeepSeek's own client, so using a DeepSeek API key through it is the first-party path. DeepSeek Open Platform terms themselves were not reviewed here [unverified].
- **Session-log upload:** the default `dsh_session_log` upload sends more than the prompt. Treat it as an explicit data-sharing opt-in.
- **GLM:** do **not** use DSH's `zai` route with a GLM Coding Plan key. That conflicts with the plugin rule "GLM only through Z.ai's own harness".
- **Subscription OAuth:** keep pi-ai OAuth routes (e.g. `openai-codex`) disabled. Headless already ignores stored grants.
- **Tokens:** never extract the DeepSeek account token (`x-dsh-auth-token`).

#### 15. Gotchas

1. Every release is a prerelease. `docs/upgrade-guide/` holds 42 migration guides for v0.1.7-rc.2 through v0.2.1-alpha.4, 40 of them from v0.2.0-rc.2 onward [source:DSH@tag:docs/upgrade-guide/]. **Pin an exact version** (`@deepseek-ai/dsh@0.2.1-rc.2`) and re-validate on bump.
2. No model flag. A `--patch` YAML replaces the *whole* row `config` (no deep merge) [source:DSH@tag:apps/cli/reference/README.md].
3. `SIGTERM` exits 0. The job runner must record "cancelled" itself.
4. `--json` can end with an empty `final` and exit 1 after an in-turn failure.
5. Resume is cwd-bound. A worktree moved or re-created at a different path cannot be resumed.
6. Session-log upload and title LLM call are on by default (see 9).
7. Reads `CLAUDE.md` and `AGENTS.md` (incl. `.local`) from the target repo and `~/.agents`. That is usually desirable for an implementer, but it is a cross-harness instruction leak to be aware of.
8. `<cwd>/.env` is a credential source in headless. A project `.env` with proxy variables blocks startup.
9. Reasoning goes to stderr in default mode. Prefer `--json` and route stderr to a private log.
10. No pre-token heartbeat. A liveness monitor must not treat silence as hang too early [source:DSH@tag:packages/bundle/headless/README.md].

#### 16. Adapter sketch (maps onto the zcode-dispatch job model)

| Op | Mapping |
|---|---|
| `task --background` | Spawn detached: `dsh --profile headless --patch <job>.patch.yml --json -`; prompt on stdin; `cwd` = workspace (must be inside a git tree). Env allowlist: `DSH_HOME=<wrapper-home>`, `DSH_AGENTS_HOME=<empty dir>`, `DSH_TELEMETRY_DISABLED=1`, `DSH_PERMISSION_MODE=workspace-write` (implementer) or `read-only` (reviewer), one key var (`DEEPSEEK_API_KEY` or a route's `apiKeyEnv`) from the wrapper-owned store, proxy vars, `PATH`, `HOME`. Job patch: `agent-default-model` (provider/model/effort), `session-log-deepseek: {enabled:false}` (unless the user opts in), optional `llm-pi-ai.providers` for custom endpoints, optionally disable `session-title-llm` and `tool-web`. stdout → `events.ndjson`, stderr → `stderr.log` (redact) |
| `status` | PID/boot-id liveness + last `status` event (`phase`, `turn`, `step`); `sessionId` from the first `session` event |
| `result` | `final.text` (line 1 = plugin status token); success iff exit 0 **and** last `turn_end.reason` = completed; usage = sum of `step_end.usage` |
| `cancel` | Mark the job cancelled first, then `SIGTERM` the process group, wait 5 s, send a second signal (immediate exit), then `SIGKILL` the group [corrected 2026-10-20: on macOS, tool children live in their own detached PGIDs, so one group kill misses them once dsh is gone. Snapshot the descendant PGIDs before signalling and kill each one after dsh exits (04b §10; packages/subprocess/subprocess-local/README.md)] |
| `resume` | `--session-id <sid>` with the **same canonical cwd**; hold the per-workspace lock |
| `doctor` | `dsh --version` == pinned version; Node engine check; `dsh --profile headless --patch <job> --dump-config` validates composition with no model call; check `sandbox-exec` exists on macOS |
| `probe` | Tiny read-only run (`DSH_PERMISSION_MODE=read-only`, "reply OK") to classify auth/quota/model; costs tokens |
| error map | Section 11 table; out-of-turn `error` event → launch/crash; exit 1 with no events → launch |

#### 17. Sources (DSH)

- github.com/deepseek-ai/deepseek-harness @ `dsh-v0.2.1-rc.2` (2026-10-17). Files: `README.md`, `SAFETY.md`, `package.json`, `docs/cli-help.md`, `docs/config-catalog.md`, `docs/user/guide/{providers,network-proxy,python-sdk}.md`, `docs/subsystems/{approval,sandbox,permission-presets,credentials,storage,jobs}.md`, `packages/bundle/{base,headless}/…`, `packages/llm/{llm,llm-deepseek,llm-pi-ai,llm-deepseek-account}/README.md`, `packages/fs/fs-sandbox/README.md`, `packages/sandbox/sandbox-local/README.md`, `packages/session/session-log-deepseek/README.md`, `packages/context/agent-instructions/README.md`, `packages/acp/acp/README.md`, `apps/cli/{README.md,reference/README.md}`, `.agents/notes/implemented/architecture/2026-10-12-headless-environment-auth.md`.
- npm `@deepseek-ai/dsh` (created 2026-08-10; 0.2.1-rc.2 published 2026-10-17) [local-run: npm view].
- Docs site https://deepseek-harness.github.io/deepseek-harness/ renders client-side only; WebFetch got only the title.

---

## B. Survey of other headless-capable harnesses (October 2026)

Stars and dates come from `gh api` on 2026-10-20 [local-run]. Rows are verified against the cited source unless tagged [unverified].

| Harness (repo) | Headless | JSON out | Resume by id | Custom endpoints / local | Official subscription logins | Yolo / permission modes | Native sandbox | Read-only mode | License | Latest release / stars | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **DSH** (deepseek-ai/deepseek-harness) | `dsh --profile headless` | `--json` NDJSON | `--session-id` | OpenAI Chat/Responses, Anthropic Messages, local | DeepSeek account (GUI only; off in headless) | `DSH_PERMISSION_MODE`; approvals fail closed | Seatbelt / bwrap+Landlock / Win ACL | `read-only` | MIT | dsh-v0.2.1-rc.2 2026-10-17 (all prerelease) / 255k | see A.2 |
| **Qwen Code** (QwenLM/qwen-code) | `qwen -p` (stdin ok) | `-o json\|stream-json`, Claude-style `system/assistant/result` with `session_id`, `usage`; `--json-schema` | `--resume <uuid>`, `--continue` | OpenAI / Anthropic / Gemini-compatible providers in `settings.json`; env keys; local | **Alibaba Cloud Coding Plan** (`sk-sp-`, models incl. qwen3.x, glm-5, kimi-k2.5, MiniMax-M2.5), Token Plan; Qwen OAuth free tier **discontinued 2026-04-15** | `--approval-mode plan\|default\|auto-edit\|auto\|yolo`; `--yolo` | Seatbelt, Docker/Podman, bwrap `executionSandbox` | `plan` | Apache-2.0 | v0.25.3 2026-10-19 / 28.6k | budgets `--max-wall-time/--max-tool-calls` exit 55, turn cap 53, SIGINT 130; `QWEN_HOME`, `QWEN_RUNTIME_DIR`; `--safe-mode` [source:QwenLM/qwen-code@v0.25.3:docs/users/features/headless.md] [source:…:docs/users/configuration/auth.md] [source:…:docs/users/configuration/settings.md] |
| **Kimi Code CLI** (MoonshotAI/kimi-code; legacy kimi-cli archived) | `kimi -p` | `--output-format stream-json` (no thinking in JSONL) | `-S/--session <id>`, `-c` | providers `kimi`, `anthropic`, `openai`, `openai_responses` in `config.toml`; models.dev import | **Kimi Code OAuth** (`kimi login`, device code; `api.kimi.com/coding/v1`) | **`-p` runs under the `auto` policy: no human approval; static deny rules only**; `--yolo`, `--auto` | none documented | `--plan` [corrected 2026-10-20: "`--prompt` cannot be used with `--yolo`, `--auto`, or `--plan`"; non-interactive mode always uses `auto`. So headless `-p` has **no** read-only/plan mode (MoonshotAI/kimi-code@@moonshot-ai/kimi-code@2.2.0:docs/en/reference/kimi-command.md)] | MIT | @moonshot-ai/kimi-code@2.2.0 2026-10-14 / 7.9k | `KIMI_CODE_HOME`, `KIMI_DISABLE_TELEMETRY`; session index `session_index.jsonl` [source:MoonshotAI/kimi-code@@moonshot-ai/kimi-code@2.2.0:docs/en/reference/kimi-command.md] [source:…:docs/en/configuration/{providers,env-vars,data-locations}.md] |
| **Antigravity CLI `agy`** (google-antigravity/antigravity-cli; issues + changelog only) | `agy -p/--print` | `--output-format json\|stream-json`, `--json-schema`; envelope `conversation_id/status/response/usage` [third-party]; `AGY_ERROR {…}` stderr + exit 3 on API failure | `--conversation <id>` | Gemini API key (`modelProvider: gemini`, `GEMINI_API_KEY`, `GOOGLE_GEMINI_BASE_URL`); OpenAI/Anthropic [unverified: none] | **Google sign-in** (AI Pro/Ultra after the Gemini CLI cutoff; GCP enterprise) | `--mode auto`, `--dangerously-skip-permissions`, review/strict/always-proceed modes | terminal sandbox (`--sandbox`; macOS/Linux; Win11 24H2+) | plan mode | **closed source** | 1.4.3 2026-10-20 / 2.6k | keyring auth; interactions-data collection on by default; `--print-timeout` [source:google-antigravity/antigravity-cli@HEAD:CHANGELOG.md] [source:…:README.md] [third-party:https://computingforgeeks.com/antigravity-cli-cheat-sheet/] |
| Gemini CLI (google-gemini/gemini-cli) | `gemini -p` | `-o json\|stream-json` (`response`, `stats`) | `--resume <uuid\|latest\|index>` | Gemini API / Vertex only [unverified] | **AI Pro/Ultra and free Code Assist stopped being served 2026-06-18**; paid API keys and Code Assist Standard/Enterprise remain | `--approval-mode default\|auto_edit\|yolo\|plan` | Seatbelt, docker, podman, runsc, lxc | `plan` | Apache-2.0 | v0.64.0 2026-10-13 / 107k | exit 0/1/42/53 [source:google-gemini/gemini-cli@v0.64.0:docs/cli/{cli-reference,headless,sandbox,session-management}.md] [docs:https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/] |
| Crush (charmbracelet/crush) | `crush run [prompt]` (stdin ok), `-q` | **none** | `-s/--session <id>`, `-C` | openai-compat, anthropic, ollama / lmstudio / llamacpp / litellm, Bedrock, Vertex | `crush login hyper\|copilot\|openai(chatgpt)\|grok` | **`run` auto-approves every permission for its session** (`AutoApproveSession`); `--yolo` | none | none | **FSL-1.1-MIT** (source-available) | v0.98.1 2026-10-09 / 28.7k | Catwalk provider auto-update (`CRUSH_DISABLE_PROVIDER_AUTO_UPDATE`); pseudonymous metrics; `-D/--data-dir`, `CRUSH_GLOBAL_CONFIG/DATA` [source:charmbracelet/crush@v0.98.1:internal/cmd/{run,root,login}.go] [source:…:internal/app/app.go] [source:…:README.md] |
| Goose (aaif-goose/goose, ex block/goose) | `goose run -t/-i`, `-q` | `--output-format json\|stream-json` | `--name` + `--resume` (by name) | 40+ providers, OpenAI-compatible, Ollama, LM Studio, Docker Model Runner | ChatGPT Codex OAuth (Plus/Pro), GitHub Copilot device flow; `claude-acp`/`codex-acp` pass-through (CLI providers deprecated) | `GOOSE_MODE` auto / approve / smart_approve / chat | none (`--container` runs extensions in Docker) | chat mode | Apache-2.0 | v1.55.0 2026-10-16 / 55.5k | `GOOSE_PATH_ROOT`, `GOOSE_DISABLE_KEYRING`, `GOOSE_TELEMETRY_ENABLED` [source:aaif-goose/goose@v1.55.0:documentation/docs/guides/{goose-cli-commands,cli-providers,environment-variables}.md] [source:…:documentation/docs/guides/managing-tools/goose-permissions.md] |
| Aider (Aider-AI/aider) | `aider --message/-m`, `--message-file` | none | none (`--restore-chat-history`) | LiteLLM; `--openai-api-base`; local | none | `--yes-always` | none | — | Apache-2.0 | v0.86.0 **2025-08-09** (last push 2026-05-22) / 49.7k | auto-commits on by default; stale [docs:https://aider.chat/docs/config/options.html] |
| Factory Droid (closed) | `droid exec [prompt]`, `-f`, stdin | `-o json\|stream-jsonrpc`; JSON `type, subtype, is_error, duration_ms, num_turns, result, session_id` | `-s/--session-id`, `--fork` | BYOK `customModels`: anthropic, openai (Responses), generic-chat-completion-api, bedrock; Ollama / LM Studio | Factory plan | **default read-only**; `--auto low\|medium\|high`; `--skip-permissions-unsafe` | none documented | default | proprietary | n/a | `--cwd`, `-w` worktree; whether BYOK needs a Factory login is [unverified] [docs:https://docs.factory.com/cli/droid-exec/overview] [docs:https://docs.factory.com/cli/byok/overview] |
| Cursor CLI `agent` (closed) | `agent -p` | `--output-format text\|json\|stream-json` | `--resume [chatId]`, `--continue` | none found (Cursor-hosted models; `-H` custom headers only) | Cursor plan (`agent login`, `CURSOR_API_KEY`) | `-f/--force` (`--yolo`), `--trust`, `--approve-mcps` | `--sandbox enabled\|disabled` | `--mode plan\|ask` | proprietary | n/a | JSON field names [unverified] [docs:https://cursor.com/docs/cli/reference/parameters] |
| GitHub Copilot CLI (github/copilot-cli) | `copilot -p` (stdin ok) | `--output-format json` | `--resume=<id>` | **BYOK**: `COPILOT_PROVIDER_BASE_URL/TYPE(openai\|azure\|anthropic)/API_KEY`, `COPILOT_MODEL`, `COPILOT_OFFLINE`; Ollama / vLLM | GitHub Copilot plan | `--allow-all-tools/-paths/-urls`, `--yolo` | command sandbox (`--sandbox`, all users) | — | LICENSE "NOASSERTION" (proprietary terms) | v1.0.100 2026-10-19 / 11.3k | `COPILOT_HOME`; `--disable-client-telemetry`; whether BYOK needs a GitHub login is [unverified] [source:github/copilot-cli@HEAD:changelog.md] [docs:https://docs.github.com/en/enterprise-cloud@latest/copilot/how-tos/copilot-cli/customize-copilot/use-byok-models] |
| Kilo CLI (Kilo-Org/kilocode) | `kilo run` | `--format json` (raw events) | `-s/--session`, `-c`, `--fork` | 500+ models via Kilo Gateway + providers | Kilo account (gateway credits) | `--auto` | none documented | — | MIT | v7.8.15 2026-10-19 / 27.7k | **OpenCode fork**: reuse an OpenCode adapter [source:Kilo-Org/kilocode@v7.8.15:README.md] [source:…:packages/kilo-docs/pages/code-with-ai/platforms/cli-reference.md] |
| Cline CLI (cline/cline) | `cline "task"` | `--json` | `--id <session-id>` | `-P provider -k key -m model`; `cline auth -b baseurl` | Cline account (default provider `cline`) | **`--auto-approve` default `true`** | none (`--data-dir` = isolated state, not a process sandbox) | `-p/--plan` | Apache-2.0 | cli-v3.0.73 2026-10-17 / 70.6k | `CLINE_DIR`, `CLINE_DATA_DIR`; `--thinking`, `-t` timeout [source:cline/cline@cli-v3.0.73:docs/cli/cli-reference.mdx] |
| Amp (Sourcegraph/Amp Inc., closed) | `amp -x/--execute` | `--stream-json` (init `session_id` = `T-<uuid>`) | `amp threads continue <id> -x` | none found [unverified] | Amp account (`AMP_API_KEY`); ChatGPT Plus/Pro for OpenAI models | `--dangerously-allow-all` [third-party] | [unverified] | [unverified] | proprietary | n/a | [docs:https://ampcode.com/manual] [docs:https://ampcode.com/docs/cli] [third-party:https://ampcode.com/news/streaming-json] |
| OpenHands CLI (OpenHands/OpenHands-CLI) | `openhands --headless -t/-f` | `--json` | `--resume <id>`, `--resume --last` | LiteLLM via `LLM_BASE_URL/LLM_MODEL/LLM_API_KEY` (needs `--override-with-envs`) | OpenHands Cloud | `--always-approve` (`--yolo`), `--llm-approve` | Cloud sandboxes; local none | — | MIT | 1.16.0 **2026-05-08** / 266 (CLI repo) | slow cadence; config `~/.openhands` [source:OpenHands/OpenHands-CLI@1.16.0:README.md] |
| mini-swe-agent (SWE-agent/mini-swe-agent) | `mini -t "task" -y` | trajectory file | none | LiteLLM, OpenRouter, Portkey | none | `-y/--yolo` (default confirm) | exec envs: docker / podman / singularity / bwrap | — | MIT | v2.4.6 2026-07-23 / 8.7k | bash-only research agent [source:SWE-agent/mini-swe-agent@v2.4.6:docs/usage/mini.md] |
| Mistral Vibe (mistralai/mistral-vibe) | `vibe -p/--prompt`, `--prompt-file` | `--output text\|json\|streaming`; `--output-dir` → `export.json` with **usage and cost** | `--resume <id>`, `--continue` | backends `mistral`, `generic` (OpenAI-compatible), `anthropic`, `openai_responses`, `vertex` | Mistral browser sign-in [unverified scope] | `--auto-approve`/`--yolo`; agent profiles | experimental `--agent-socket` remote sandbox | `ask` agent [unverified] | Apache-2.0 | v3.0.0 2026-10-19 / 5.2k | **exit 0 finished, 1 usage, 2 infra, 3 limits/refusal, 4 aborted**; `--max-price`, `--time-limit`, SIGTERM resumable; `VIBE_HOME` [source:mistralai/mistral-vibe@v3.0.0:README.md] [source:…:vibe/core/llm/backend/] |
| MiniMax Code `mcode` (MiniMax-AI/minimax-code) | `mcode exec [prompt]` | [unverified] | [unverified] | `custom_provider`, OpenAI- or Anthropic-compatible; BYOK without login | **MiniMax account / Token Plan** | "permissions and sandboxing" [unverified detail] | [unverified] | [unverified] | MIT | v0.6.5 2026-10-09 / 2.1k [corrected 2026-10-20: v0.6.5 is the latest *GitHub release*, but npm `@minimax-ai/code` `latest` is 0.6.12 (published 2026-10-15); `npm view @minimax-ai/code time`] | npm `@minimax-ai/code`; `MINIMAX_DATA_DIR`; ACP [source:MiniMax-AI/minimax-code@HEAD:README.md] [source:…@v0.6.5:docs/examples.md] |
| Codewhale (codewhale-hq/Codewhale, ex deepseek-tui) | `codewhale exec "…"` | streaming JSON | [unverified] | 40+ routes, any OpenAI-compatible, Ollama / vLLM / SGLang | Codewhale account key sync | approval postures | Seatbelt (macOS), bwrap opt-in | Plan mode [unverified] | MIT | v0.10.1 2026-10-08 / 41.1k | local runtime HTTP API [source:codewhale-hq/Codewhale@v0.10.1:README.md] |
| Hermes Agent (NousResearch/hermes-agent) | `hermes -z "<prompt>"`, `hermes chat --oneshot -q` | `--format stream-json`, `--usage-file` | [unverified] | many providers + custom endpoint | Nous Portal OAuth subscription | `--yolo` | terminal backends local / Docker / SSH / Modal / Daytona / … | — | MIT | v0.22.2 2026-10-15 / 255k | general personal agent, not coding-first; `--ignore-user-config`, `--safe-mode` [docs:https://hermes-agent.nousresearch.com/docs/reference/cli-commands] |

(Claude Code, OpenCode, pi, Codex and ZCode are covered by other reports. Note: pi now lives at `earendil-works/pi`, and DSH vendors its `pi-ai` package [local-run] [source:DSH@tag:docs/config-catalog.md].)

### B.1 Recommendation: at most 3 extra adapters

| # | Harness | Why | Main risks |
|---|---|---|---|
| 1 | **Qwen Code** | Official harness for **Alibaba Cloud Coding Plan / Token Plan**; the Coding Plan's `/model` list also includes GLM-5, Kimi-K2.5 and MiniMax-M2.5, so one subscription covers several model families. Most complete headless contract in the survey: Claude-style `json/stream-json` with `session_id` + `usage`, `--resume <uuid>`, `--json-schema`, budget flags with distinct exit codes (53/55/130), `plan` for reviewers, `QWEN_HOME`/`QWEN_RUNTIME_DIR` isolation, Seatbelt sandbox. Apache-2.0, very active | Whether Alibaba's plan terms allow routing GLM/Kimi/MiniMax for the family rule needs ToS review; `--yolo` without a sandbox runs on the host |
| 2 | **Kimi Code CLI** | Official harness for the **Kimi Code** subscription (OAuth device login), MIT, `-p` + `stream-json`, resume by id, `--plan`, `KIMI_CODE_HOME`, telemetry opt-out [corrected 2026-10-20: `--plan` cannot be combined with `-p`/`--prompt` (kimi-command.md@2.2.0), so it is not available to a headless reviewer] | **`-p` never asks: the `auto` policy runs everything except static deny rules**, and there is no native sandbox, so it is git-tree-only with deny rules for reviewers; session id is not in documented stream-json (read `session_index.jsonl`) |
| 3 | **Antigravity CLI (`agy`)** | The only route for **Google AI Pro/Ultra** since Gemini CLI stopped serving those tiers on 2026-06-18. Strong CI contract: json/stream-json, `--json-schema`, structured `AGY_ERROR` + exit 3, `--conversation`, terminal sandbox, auto mode | **Closed source**; earlier non-TTY print bugs (#76, #318, now closed); interactions-data collection on by default; Google sign-in is keyring-based (an isolation story is still needed) |

- **Runners-up:**
  - **Mistral Vibe**: best exit-code and cost contract, Apache-2.0; pick it if the user holds a Mistral plan.
  - **MiniMax Code**: official for MiniMax Token Plan, but young (v0.6.x) with an undocumented exec contract.
  - **Factory Droid**: read-only by default, which suits reviewers; closed source and paid.
  - **Copilot CLI**: BYOK + Copilot plan + sandbox.
- **Not recommended:**
  - Crush (FSL licence; `run` auto-approves; no JSON).
  - Aider (stale, no JSON or resume).
  - Cline (auto-approve default `true`).
  - Gemini CLI (consumer subscription gone; use agy).
  - Kilo (cover via the OpenCode adapter).
  - Hermes (not coding-first).

### B.2 Cross-cutting findings for the universal dispatcher

1. **Two output families.**
   - (a) **Claude-Code-style envelope** `{type:"result", result, session_id, is_error, usage}`: documented for Qwen Code [source:QwenLM/qwen-code@v0.25.3:docs/users/features/headless.md] and Factory droid [docs:https://docs.factory.com/cli/droid-exec/overview], with similar shapes reported for Amp [third-party]. One parser can serve all of them.
   - (b) **Bespoke NDJSON**: DSH, Goose, OpenCode/Kilo, agy, Vibe (`export.json`), Kimi (OpenAI-message-shaped JSONL). Each needs its own extractor for final text, session id and error code.
2. **Headless permission defaults are unsafe to assume.**
   - Auto-approve everything: Crush `run` [source:charmbracelet/crush@v0.98.1:internal/app/app.go], Kimi `-p` [source:MoonshotAI/kimi-code@…:docs/en/reference/kimi-command.md], Cline default [source:cline/cline@cli-v3.0.73:docs/cli/cli-reference.mdx].
   - Read-only by default: Droid.
   - Fail closed: DSH.
   - The adapter must pass an explicit mode per role.
3. **Per-harness home/config env var** exists for most:

   | Harness | Home/config control |
   |---|---|
   | DSH | `DSH_HOME` (+ `DSH_AGENTS_HOME`) |
   | Qwen Code | `QWEN_HOME` |
   | Kimi Code | `KIMI_CODE_HOME` |
   | Goose | `GOOSE_PATH_ROOT` |
   | Copilot CLI | `COPILOT_HOME` |
   | Vibe | `VIBE_HOME` |
   | Cline | `CLINE_DIR` |
   | Crush | `-D` / `CRUSH_GLOBAL_*` |
   | MiniMax Code | `MINIMAX_DATA_DIR` |

   Use these to keep wrapper-owned credentials away from the user's global login. Keyring-only auth (agy, Goose default) is the hard case.
4. **Most harnesses also read `AGENTS.md`/`CLAUDE.md`**: DSH explicitly; Crush reads `~/.config/AGENTS.md`. The plugin's own repo instructions will leak into dispatched runs unless suppressed (e.g. `DSH_AGENTS_HOME`, Qwen `--safe-mode`, Hermes `--ignore-rules`).

---

## Open questions

1. Does DSH headless compose *any* approval answerer, or do all escalations resolve `unavailable`? Check with `dsh --profile headless --dump-config` on an installed copy.
2. Can `session-title-llm` (and `tool-web`) be disabled in headless without startup warnings or failures?
3. Is concurrent use of one `DSH_HOME` by several headless processes race-free (projection cache, storage-json units)?
4. Does DSH spawn tool subprocesses in their own process group? This decides the cancellation approach. [corrected 2026-10-20: answered. On macOS, yes: detached process groups. Linux uses systemd scopes, Windows uses Job objects. Source: packages/subprocess/subprocess-local/README.md@dsh-v0.2.1-rc.2]
5. DeepSeek Open Platform terms for `dsh_session_log` uploads and for DSH use with non-DeepSeek providers. To be checked by the ToS researcher.
6. Do the Alibaba Coding Plan terms permit use from Qwen Code headless/CI and the non-Qwen models (GLM/Kimi/MiniMax) for "different family" reviews?
7. Kimi Code: how is a new session's id exposed in `-p` mode (stdout/stderr/`session_index.jsonl` only)? Is there any sandbox?
8. Antigravity CLI: exact `--output-format json` field names (third-party only so far), whether auth can be isolated from the keyring, and the terms for automated/CI use of AI Pro/Ultra.
9. MiniMax Code `mcode exec`: output format, permission flags and resume. The docs found do not specify them.
10. Do Copilot CLI and Factory Droid BYOK runs still require a GitHub or Factory login?

## Sources (survey)

- **DeepSeek Harness:** see A.2 §17.
- **Qwen Code:** QwenLM/qwen-code @ v0.25.3 (2026-10-19): `docs/users/features/{headless,approval-mode,sandbox,structured-output}.md`, `docs/users/configuration/{auth,settings,model-providers}.md`.
- **Kimi Code CLI:** MoonshotAI/kimi-code @ `@moonshot-ai/kimi-code@2.2.0` (2026-10-14): `docs/en/reference/kimi-command.md`, `docs/en/configuration/{providers,env-vars,data-locations}.md`, `docs/en/guides/sessions.md`. Legacy MoonshotAI/kimi-cli is archived (repo description).
- **Antigravity CLI:** google-antigravity/antigravity-cli HEAD (release 1.4.3, 2026-10-20): `README.md`, `CHANGELOG.md`; issues #76 and #318 (closed 2026-07-12 and 2026-09-03).
- **Gemini CLI:**
  - Google announcement (2026-05-19): https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/
  - google-gemini/gemini-cli @ v0.64.0 (2026-10-13): `docs/cli/{cli-reference,headless,sandbox,session-management}.md`.
- **Crush:** charmbracelet/crush @ v0.98.1 (2026-10-09): `README.md`, `LICENSE.md` (FSL-1.1-MIT), `internal/cmd/{run,root,login}.go`, `internal/app/app.go`.
- **Goose:** aaif-goose/goose @ v1.55.0 (2026-10-16): `documentation/docs/guides/{goose-cli-commands,cli-providers,environment-variables}.md`, `documentation/docs/guides/managing-tools/goose-permissions.md`, `documentation/docs/getting-started/providers.md`.
- **Aider:** https://aider.chat/docs/config/options.html; Aider-AI/aider release v0.86.0 (2025-08-09).
- **Factory Droid:** https://docs.factory.com/cli/droid-exec/overview, https://docs.factory.com/cli/byok/overview (no version or date on the pages).
- **Cursor CLI:** https://cursor.com/docs/cli/reference/parameters
- **GitHub Copilot CLI:** github/copilot-cli `changelog.md` (top entry 1.0.100, 2026-10-19); https://docs.github.com/en/enterprise-cloud@latest/copilot/how-tos/copilot-cli/customize-copilot/use-byok-models
- **Kilo CLI:** Kilo-Org/kilocode @ v7.8.15: `README.md`, `packages/kilo-docs/pages/code-with-ai/platforms/cli-reference.md`.
- **Cline CLI:** cline/cline @ cli-v3.0.73: `docs/cli/cli-reference.mdx`.
- **Amp:** https://ampcode.com/manual, https://ampcode.com/docs/cli, https://ampcode.com/news/streaming-json (via search snippet).
- **OpenHands CLI:** OpenHands/OpenHands-CLI @ 1.16.0: `README.md`.
- **mini-swe-agent:** SWE-agent/mini-swe-agent @ v2.4.6: `README.md`, `docs/usage/mini.md`.
- **Mistral Vibe:** mistralai/mistral-vibe @ v3.0.0: `README.md`, `vibe/core/llm/backend/*` (tree listing).
- **MiniMax Code:** MiniMax-AI/minimax-code (`README.md` HEAD, `docs/examples.md` @ v0.6.5).
- **Codewhale:** codewhale-hq/Codewhale @ v0.10.1: `README.md`.
- **Hermes Agent:** https://hermes-agent.nousresearch.com/docs/reference/cli-commands; NousResearch/hermes-agent release v0.22.2.
- **Third-party:** https://computingforgeeks.com/antigravity-cli-cheat-sheet/ (agy envelope fields).

## Fact-check log (2026-10-20)

Method: opened every primary source myself. DSH files were read at tag `dsh-v0.2.1-rc.2` with `gh api` (raw contents, git tree, releases, tags, commits). Other evidence: `npm view` metadata, the other harnesses' repos at the cited tags, the official web pages listed below, and local read-only checks (`which`, `brew info`, `node --version`, `sw_vers`, `ls`). Nothing was installed or run, and no model endpoint was called.

| Claim | Verdict | Evidence |
|---|---|---|
| "DSH" = `deepseek-ai/deepseek-harness`, MIT, created 2026-08-13, ~255k stars, bin `dsh`, npm `@deepseek-ai/dsh` `latest` = 0.2.1-rc.2 | confirmed | `gh api repos/deepseek-ai/deepseek-harness`: 255,226 stars, 30,869 forks, MIT, created 2026-08-13T11:56:32Z, topics `dsh`, `dsh-plugin`, issues disabled. `npm view`: bin `{dsh: lib/bin.js}`, dist-tags `latest`/`next` 0.2.1-rc.2, `alpha` 0.2.1-alpha.5 |
| All GitHub releases are prereleases; `releases/latest` → 404; README says developer preview | confirmed | `gh api …/releases`: 31 releases, all `prerelease: true`; `/releases/latest` HTTP 404. README@rc.2: "THERE WILL BE COMPATIBILITY-BREAKING CHANGES" |
| Cadence "about 30 tags from 2026-08-19" | corrected | 32 tags / 31 releases, from `dsh-v0.1.0-rc.7` (2026-08-17) to rc.2 (2026-10-17) |
| Headless grammar `dsh --profile headless [--json] [--session-id] [task\|-]`; no `--model`; exit 0 only for a completed final turn, else 1 | confirmed | docs/cli-help.md (generated help); packages/bundle/headless/README.md "Exit mapping" |
| Headless disables `credentials`/`authorization`/`deepseek-account`; keys come from env, then cwd `.env`, then `$DSH_HOME/.env` | confirmed | packages/bundle/headless/cordis.patch.yml@rc.2. The rows are present from `dsh-v0.2.1-alpha.3` and absent at alpha.2 |
| `DSH_PERMISSION_MODE ?? 'workspace-write'`; approval `never` only for `danger-full-access`; ask without an answerer → `unavailable` → fail closed | confirmed | packages/bundle/base/cordis.patch.yml; docs/subsystems/approval.md ("callers deny on `rejected`, `cancelled`, and `unavailable`") |
| Headless composes no approval answerer | unverified (left as is; consistent with sources) | A repo code search finds `approval/request` answerers only in the ACP bridge, `client/ui-approval` and Web remote forwarding. Headless mounts no Host or UI |
| `session-log-deepseek` is on by default, ≤ 8 MiB per request, sent "with official DeepSeek API requests" | corrected | Default `enabled: true` and `maxBytes` 8 MiB confirmed (package README). Destination is the route's **resolved `baseURL`, gateways included** (docs/deepseek-llm-api-wire-extensions.md) |
| SIGTERM → exit 0, SIGINT → 130, second signal forces exit, 5 s grace | confirmed | apps/cli/src/profile-boot.ts (`process.on('SIGTERM', () => { interrupt(0) })`); process-shutdown.ts `PROCESS_SHUTDOWN_TIMEOUT_MS = 5_000`; apps/cli/reference/README.md |
| Third-party routes go via `@earendil-works/pi-ai`; custom `api` is `openai-completions\|openai-responses\|anthropic-messages` | confirmed | packages/llm/llm-pi-ai/package.json (`^1.1.0`); docs/user/guide/providers.md |
| Base default model `deepseek-official/deepseek-flash`; `agent-default-model` has `provider/model/reasoningEffort` | confirmed | base cordis.patch.yml; docs/config-catalog.md |
| "rc.2 adds DeepSeek-V4.1-Flash-1017" | corrected | The release note adds *support*; the catalog ids are unchanged (src/models.ts) |
| Layer order bundle → profile → home → `--patch`; a patch replaces the whole row `config` | confirmed | apps/cli/reference/README.md |
| `--json` caps: 8 KiB per string, 32 KiB per line, depth 64; `final` uncapped | confirmed | packages/bundle/headless/src/json-stream.ts (`MAX_STRING_BYTES`, `MAX_EVENT_BYTES`, `MAX_DEPTH`) |
| Sandbox covers file writes only: "Network and process visibility are outside this vocabulary" | confirmed (verbatim) | docs/subsystems/sandbox.md. bwrap additionally hides host processes (private PID namespace) |
| Seatbelt depends on the deprecated `sandbox-exec`; fails closed with `SANDBOX_UNAVAILABLE` | confirmed | packages/sandbox/sandbox-local/README.md |
| "`.git` stays writable" under `workspace-write` | corrected (qualified) | True only when `.git` is under the cwd; linked worktrees fall outside (src/profiles.ts write roots) |
| "The model never sees secrets" | corrected | launch-environment README (every `.env` layer is copied into `process.env`); subprocess-local README (name-based scrub only); reads are unconfined |
| Project `.env` with proxy variables makes DSH refuse to start | confirmed | docs/user/guide/network-proxy.md |
| Instruction chain and 65,536-byte budget; `DSH_AGENTS_HOME` defaults to `~/.agents` | confirmed | packages/context/agent-instructions/README.md; packages/util/home-paths/README.md |
| Telemetry `FEEDBACK_ONLY` to `dsh-otel-collector.deepseeksvc.com`; `DSH_TELEMETRY_DISABLED` = any non-empty value | confirmed | base cordis.patch.yml comments and config |
| `session-title-llm` (4,096 output tokens, 60 s) on every new session | confirmed | base cordis.patch.yml. Disabled in the acp-app and sdk-app bundles, kept in headless |
| Process groups of tool children [unverified] | corrected | packages/subprocess/subprocess-local/README.md: macOS uses detached PGIDs, Linux user-systemd scopes, Windows Job objects |
| 42 upgrade guides, 40 from v0.2.0-rc.2 onward | confirmed | git tree: 2 (v0.1.7-rc.2) + 6 + 22 + 10 + 1 + 1 |
| Rank-4 `dsh` = Dancer's/distributed shell [unverified] | confirmed | `brew info dsh`: "Dancer's shell, or distributed shell" 0.25.10 |
| `gokul6350/dsh-shell` 28 stars; `awesome-dsh-plugin` ecosystem | confirmed | `gh api`; `gh search repos` (awesome-dsh-plugin/awesome-dsh-plugin, 19.6k stars) |
| Google: Gemini CLI stops serving AI Pro/Ultra (and free Code Assist individuals) on 2026-06-18; announced 2026-05-19; paid API keys and Code Assist Standard/Enterprise remain | confirmed | developers.googleblog.com post (dated May 19, 2026) |
| Antigravity CLI (`agy`) exists, closed source, 1.4.3 (2026-10-20), keyring auth, interactions data collected by default, `AGY_ERROR` + exit 3, `--print-timeout`, `--mode auto`, `GEMINI_API_KEY`/`GOOGLE_GEMINI_BASE_URL`/`modelProvider: gemini`; issues #76/#318 closed 2026-07-12/2026-09-03 | confirmed | google-antigravity/antigravity-cli README.md and CHANGELOG.md; repo has no license and holds only README, CHANGELOG, examples and a GIF; `gh api …/issues/76`, `…/318` |
| Qwen OAuth free tier discontinued 2026-04-15; Coding Plan `sk-sp-` keys; `/model` list includes glm-5, kimi-k2.5, MiniMax-M2.5 | confirmed | QwenLM/qwen-code@v0.25.3:docs/users/configuration/auth.md |
| Qwen headless `-p`, `-o json\|stream-json`, `--resume`, `--json-schema`, budget exit 55, turn cap 53, SIGINT 130, `QWEN_HOME`/`QWEN_RUNTIME_DIR`, `--safe-mode` | confirmed | docs/users/features/headless.md; docs/users/configuration/settings.md |
| Kimi `-p` runs under `auto` (no human approval, static deny rules), `text\|stream-json` | confirmed | MoonshotAI/kimi-code@@moonshot-ai/kimi-code@2.2.0:docs/en/reference/kimi-command.md |
| Kimi `--plan` as a headless read-only mode | corrected | Same file: "`--prompt` cannot be used with `--yolo`, `--auto`, or `--plan`" |
| Kimi: `kimi login` device code, `api.kimi.com/coding/v1`, `KIMI_CODE_HOME`, `KIMI_DISABLE_TELEMETRY`, `session_index.jsonl`; legacy kimi-cli archived | confirmed | kimi-command.md (RFC 8628), configuration/env-vars.md, data-locations.md; `gh api repos/MoonshotAI/kimi-cli` (`archived: true`) |
| Crush `run` auto-approves its session; no JSON flag; FSL-1.1-MIT; reads `~/.config/AGENTS.md` | confirmed | charmbracelet/crush@v0.98.1: internal/app/app.go:391 `AutoApproveSession`; internal/cmd/run.go flags; LICENSE.md; README.md |
| Droid read-only by default; `--auto low\|medium\|high`; JSON fields | confirmed | docs.factory.com/cli/droid-exec/overview |
| Kilo `run --auto`, `--format json`, OpenCode fork | confirmed | Kilo-Org/kilocode@v7.8.15 cli-reference.md; README.md ("Kilo CLI is a fork of OpenCode") |
| Cline `--auto-approve` default `true`, `CLINE_DIR` | confirmed | cline/cline@cli-v3.0.73:docs/cli/cli-reference.mdx |
| Mistral Vibe v3.0.0: exit 0/1/2/3/4, `--max-price`, `--time-limit`, SIGTERM, `--output-dir` export with cost, `VIBE_HOME`, backends | confirmed | mistralai/mistral-vibe@v3.0.0 README.md; `vibe/core/llm/backend/` listing |
| MiniMax Code v0.6.5 | corrected | GitHub release is v0.6.5, but npm `latest` is 0.6.12 (2026-10-15). `mcode exec`, `MINIMAX_DATA_DIR`, BYOK `custom_provider` confirmed in the README |
| Gemini CLI v0.64.0 2026-10-13 / 107k; approval modes; exit 42/53; sandbox incl. runsc/lxc | confirmed | `gh api` releases; google-gemini/gemini-cli@v0.64.0 docs/cli/* |
| Copilot BYOK env vars (`COPILOT_PROVIDER_BASE_URL/TYPE/API_KEY`, `COPILOT_MODEL`, `COPILOT_OFFLINE`) | confirmed | docs.github.com BYOK page (types `openai`/`azure`/`anthropic`) |
| Cursor CLI flags (`-p`, `--output-format`, `--resume`, `-f/--yolo`, `--trust`, `--sandbox enabled\|disabled`, `--mode plan\|ask`, `-H`) | confirmed | cursor.com/docs/cli/reference/parameters |
| Goose `run` flags; OpenHands; mini-swe-agent; Hermes (`-z`, `--oneshot`, `--usage-file`, `--ignore-rules`, `--safe-mode`; 255,428 stars); Codewhale "began as `deepseek-tui`"; Aider v0.86.0 2025-08-09 | confirmed | Repo docs at the cited tags; `gh api` metadata and releases |

**Reliability assessment.** This report is reliable. Every DSH repository fact I checked is real and matches the cited tag, including the suspicious ~255k star count (255,226; Hermes Agent also has ~255k). That covers license, dates, npm dist-tags, flags, env vars, exit codes, event names, caps, quotes and paths. The survey's version numbers, star counts and flags also match the primary sources. The errors are of interpretation, not fabrication:
- The session-log upload goes to whatever `baseURL` the DeepSeek route resolves to, not only to the official API.
- "The model never sees secrets" is too strong.
- Kimi `--plan` cannot be used in headless `-p` mode, which weakens Kimi as a reviewer adapter.
- The process-group question was left open although the source answers it.
- There were two small date and version slips (cadence start; MiniMax npm version).

All are corrected inline. The Antigravity CLI JSON envelope fields remain third-party only, and the report flags this itself.
