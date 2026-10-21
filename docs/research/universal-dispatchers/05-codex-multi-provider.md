# 05: Codex CLI as a multi-provider harness

Researcher key: `05-codex-multi-provider`. Date: 2026-10-20. Machine: macOS 26.5 (Darwin 25.5), Apple M4, codex-cli 0.163.0 (Homebrew cask).
Evidence tags: `[local-run]` = observed on this machine in the scratch experiment (Appendix A), `[source:openai/codex@rust-v0.163.0:<path>]`, `[docs:<url>]`, `[third-party:<url>]`, `[unverified]`.

## Bottom line

- **Yes, Codex can drive non-OpenAI models, but only through the OpenAI Responses API.** `wire_api = "chat"` is now a hard config error, so any backend must serve `POST {base_url}/responses` [source:openai/codex@rust-v0.163.0:codex-rs/model-provider-info/src/lib.rs] [local-run].
- **No OpenAI login is needed for a custom provider.** In the experiment, `codex exec` with a throwaway `CODEX_HOME`, a `[model_providers.stub]` entry and a dummy key in `env_key` sent exactly one `POST /v1/responses` to the local stub (Bearer = the env value) and exited 0 [local-run].
- **Vendors now support this route officially.** DeepSeek, Z.ai (GLM Coding Plan), Moonshot Kimi and MiniMax each publish a Codex `config.toml` with `wire_api = "responses"`. Alibaba Model Studio (Qwen and others), Ollama (≥0.13.3), LM Studio (≥0.3.29), vLLM and OpenRouter (stateless; the official OpenRouter pages do not label it beta) [corrected 2026-10-20: openrouter.ai/docs/api_reference/responses/basic-usage.md and /docs/api/api-reference/responses/create-a-response.md fetched, no "beta" label] expose `/responses`. llama.cpp `llama-server` documents `POST /v1/responses` in its official server README (converted to Chat Completions internally; PR ggml-org/llama.cpp#18486 "server: /v1/responses (partial)" merged 2026-01-21) [corrected 2026-10-20: gh api repos/ggml-org/llama.cpp contents tools/server/README.md and search/issues] (§5.3).
- **The path the plugin uses today (app-server via the companion) can switch providers per job.** One app-server process ran two threads against two different providers, each defined only in `thread/start {modelProvider, config:{"model_providers.<id>": {...}}}`, and `config.toml` was not touched [local-run]. The key is still read from the **app-server's environment** (`env_key`) or from a per-provider `auth.command`.
- **Recommended adapter:** a new generic runner around `codex exec --json` (reusing the zcode-dispatch job machinery) rather than patching the OpenAI-oriented companion. It gives one engine for DeepSeek, GLM, Kimi, MiniMax, Qwen, OpenRouter and local models, with Codex's Seatbelt sandbox still enforced [local-run].
- **Must-fix defaults for unattended third-party runs:**
  - The provider key in env is visible to model-run shell commands (`ignore_default_excludes` defaults to true) [local-run].
  - Every request carries the absolute workspace path, git HEAD and installation id to the provider [local-run].
  - `-s workspace-write` silently writes `trust_level="trusted"` into `$CODEX_HOME/config.toml` [local-run].
  - The default tool list includes a hosted `web_search` tool and a `namespace` tool, which some backends reject [local-run][docs:platform.kimi.ai].
  - SIGTERM orphans running tool processes; SIGINT cleans them [local-run].
  - A fresh home contacts chatgpt.com and github.com unless `--disable plugins` [local-run].

## 1. Identity

| Item | Value |
|---|---|
| Name / repo | OpenAI Codex CLI, `openai/codex` (Rust workspace `codex-rs`) [source:openai/codex@rust-v0.163.0:README.md] |
| License | Apache-2.0 (`gh api repos/openai/codex` → `license.spdx_id`) [local-run] |
| Maintainer | OpenAI |
| Latest stable | `rust-v0.163.0`, published 2026-10-15T21:30:38Z (`gh api repos/openai/codex/releases/latest`) [local-run]. Installed = latest. |
| Activity | Very high: `0.164.0-alpha.1` to `alpha.6` released between 2026-10-16 and 2026-10-19; last push 2026-10-20; about 130k stars [local-run] |
| OSes | macOS, Linux (x86_64/arm64 musl), Windows [source:openai/codex@rust-v0.163.0:README.md]. Sandboxes: Seatbelt on macOS (observed `"sandbox":"seatbelt"` in request metadata [local-run]), Linux helper, Windows sandbox crate (`codex-rs/windows-sandbox-rs`) [source] |
| Docs | Moved: `developers.openai.com/codex/*` now answers 308 to `learn.chatgpt.com/docs/*` [local-run, WebFetch] |

## 2. Headless invocation

```bash
# one-shot, prompt on stdin, JSONL events on stdout, final message to file
CODEX_HOME=<wrapper-owned-home> DEEPSEEK_API_KEY=... \
codex exec --json -o <job>/last.txt -C <worktree> -s workspace-write \
  -c model_provider='"deepseek"' -m deepseek-flash -c model_reasoning_effort='"high"' \
  -c web_search='"disabled"' --disable plugins --disable multi_agent --disable goals \
  -c shell_environment_policy.ignore_default_excludes=false - < <job>/prompt.md
```

| Aspect | Finding |
|---|---|
| Subcommands | `exec` (alias `e`), `exec resume`, `exec fork`, `exec review`; `app-server` (stdio/unix/ws JSON-RPC), `doctor`, `features`, `sandbox`, `login` [local-run: `codex --help`, `codex exec --help`] |
| Prompt transport | argv `[PROMPT]`; `-` or no argument reads stdin; if stdin is piped **and** a prompt is given, stdin is appended as a `<stdin>` block [local-run: help text]. Every run with non-TTY stdin prints `Reading additional input from stdin...` to stderr [local-run]. The runner must give `</dev/null` or the prompt on stdin, otherwise an open pipe can block. |
| Size limits | argv is bounded by macOS `ARG_MAX` = 1,048,576 bytes total (`getconf ARG_MAX`) [local-run]; stdin has no CLI limit (model context only). Use stdin. |
| Git requirement | Exits 1 with `Not inside a trusted directory and --skip-git-repo-check was not specified.` outside a git repo, unless `--skip-git-repo-check` or `--dangerously-bypass-approvals-and-sandbox` [source:…:codex-rs/exec/src/lib.rs] |
| Engine | `codex exec` runs an **in-process app-server** (`InProcessAppServerClient`) [source:…:codex-rs/exec/src/lib.rs], so exec and `codex app-server` share config loading and provider code. |
| Removed flags | `--full-auto` no longer exists; use `-s workspace-write` [docs:https://learn.chatgpt.com/docs/non-interactive-mode] [local-run: absent from help] |

## 3. Output and final-message extraction

| Mode | Behaviour |
|---|---|
| default | progress on stderr, final agent message on stdout [docs:non-interactive-mode] |
| `--json` | JSONL on stdout: `thread.started{thread_id}`, `turn.started`, `item.started/updated/completed{item}`, `turn.completed{usage}`, `turn.failed{error.message}`, `error{message}` [source:…:codex-rs/exec/src/exec_events.rs] [local-run] |
| item types | `agent_message{text}`, `reasoning{text}`, `command_execution{command,aggregated_output,exit_code,status}`, `file_change{changes[{path,kind}],status}`, `mcp_tool_call`, `collab_tool_call`, `web_search`, `todo_list`, `error{message}` [source:exec_events.rs] |
| `-o FILE` | writes the last agent message to FILE (and still prints it) [local-run] |
| Exit codes | 0 = turn completed; 1 = any non-retried `error` or a turn that failed or was interrupted, config error, or missing env key; 143 = SIGTERM [local-run]; SIGINT gives 1 [local-run] |
| Trap | With an unknown model slug, the stream starts with `item.completed {type:"error", message:"Model metadata for \`X\` not found. Defaulting to fallback metadata…"}` and **exit is still 0** [local-run]. The classifier must key on `turn.failed` or the exit code, not on any `error` item. Supplying `model_catalog_json` removes the warning [local-run]. |

## 4. Sessions and resume

| Item | Finding |
|---|---|
| Id | `thread.started.thread_id` (UUIDv7-like, e.g. `01a158ef-5a97-74c0-9772-d2210651d320`) [local-run] |
| Persistence | `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<thread_id>.jsonl` plus SQLite state (`state_5.sqlite`, `thread_history_1.sqlite`, `logs_2.sqlite`, …) [local-run] |
| Resume | `codex exec [parent flags] resume <thread_id> "<prompt>"` worked; the new request carried prior history (`input` = developer, developer, user, user, **assistant**, user) [local-run]. Parent-only flags (`-s`, `-p`) must come **before** `resume`: `codex exec resume -s …` is a parse error, while `codex exec -s workspace-write resume <id>` is accepted [local-run]. |
| Provider pinning on resume | Unless the resume overrides `model`, `model_provider` or `model_reasoning_effort`, the persisted model and **provider id** are reapplied [source:…:codex-rs/app-server/src/request_processors/thread_processor.rs `merge_persisted_resume_metadata`]. The provider *definition* is not persisted, so it must still exist (same `-c`, profile or home) at resume time. |
| Ephemeral | `--ephemeral` writes no rollout; a later resume fails with `thread/resume failed: no rollout found for thread id … (code -32600)`, exit 1 [local-run] |
| Listing | `thread/list` filters by the server's **default** `model_provider` unless `modelProviders: []` is passed [source:thread_processor.rs ~L5788]. The companion's `--resume-last` (`findLatestTaskThread`) would therefore miss threads started under a per-thread provider. DeepSeek's guide notes that sessions are grouped per provider [docs:https://api-docs.deepseek.com/quick_start/agent_integrations/codex]. |

## 5. Model and provider selection

### 5.1 Mechanisms

| Mechanism | Detail |
|---|---|
| `[model_providers.<id>]` | Fields: `name`, `base_url`, `env_key`, `env_key_instructions`, `experimental_bearer_token` (discouraged), `auth{command,args,timeout_ms,refresh_interval_ms,cwd}`, `wire_api`, `query_params`, `http_headers`, `env_http_headers`, `request_max_retries` (default 4, cap 100), `stream_max_retries` (default 5), `stream_idle_timeout_ms` (default 300000), `websocket_connect_timeout_ms`, `requires_openai_auth` (default false), `supports_websockets`, `supports_standalone_web_search`, `capabilities{external_web_access, remote_compaction}`, `model_catalog_url`, `aws{…}`, `gateway_oauth` [source:…:codex-rs/model-provider-info/src/lib.rs] |
| `wire_api` | Enum has **only** `Responses`. `"chat"` makes config loading fail: ``Error loading config.toml: `wire_api = "chat"` is no longer supported. How to fix: set `wire_api = "responses"` …`` (exit 1, no request sent) [local-run] [source]. Removal was announced 2025-12-09 for February 2026 [source: GitHub discussion openai/codex#7782 via `gh api`]. |
| Built-ins | `openai`, `amazon-bedrock`, `amazon-bedrock-runtime`, `ollama` (:11434/v1), `lmstudio` (:1234/v1). User entries cannot override built-ins except Bedrock (`entry().or_insert`) [source:lib.rs]; docs say custom providers cannot use the reserved ids `openai`, `ollama` or `lmstudio` [docs:https://learn.chatgpt.com/docs/config-file/config-advanced]. |
| Project config | `model_provider`/`model_providers` in a project `.codex/config.toml` are **ignored** with a warning [docs:config-advanced]. A repository cannot redirect the provider. |
| `-c key=value` | Dotted path, TOML-parsed value. Whole providers can be defined inline: `-c 'model_providers.cmdauth={name="CmdAuth",base_url="http://127.0.0.1:18765/v1",wire_api="responses",auth={command="/bin/cat",args=["<keyfile>"]}}' -c 'model_provider="cmdauth"'` worked [local-run]. |
| `--profile` (new semantics) | `-p NAME` layers `$CODEX_HOME/NAME.config.toml` over `config.toml` (since 0.134.0; `[profiles.x]` tables and `profile=` are legacy and are no longer read; they produce an error only when `-p` selects the same name, i.e. `[profiles.NAME]` or `profile = "NAME"` exists in `config.toml`) [corrected 2026-10-20: openai/codex@rust-v0.163.0:codex-rs/config/src/loader/mod.rs `legacy_profile_is_selected || legacy_profile_table_exists`; docs:config-advanced says the tables are "no longer" read] [docs:config-advanced] [local-run: `--profile stubprof` worked; a legacy table gave `--profile \`legacy\` cannot be used while … contains legacy …`]. `codex app-server` rejects `--profile` (`--profile only applies to runtime commands …`) [local-run]. |
| app-server per thread | `thread/start` and `thread/resume` accept `modelProvider` and `config` (a JSON map merged as extra `-c` overrides) [source:…:schema/typescript/v2/ThreadStartParams.ts, config_manager.rs `load_with_cli_overrides`]. Two threads in one app-server used providers `stubA`/`stubB` defined only in `config`, each with its own header and key; `wire_api:"chat"` in `config` returned JSON-RPC error -32600 [local-run]. `codex app-server -c model_provider="x"` for an undefined `x` fails at startup with ``Model provider `x` not found`` [local-run]. |
| `--oss` | `--oss --local-provider ollama|lmstudio` or `oss_provider` in config; `codex exec --oss` without either exits 1 (`No default OSS provider configured…`) [local-run]. Before running it probes `GET {base}/models`, and it **auto-pulls the selected model if missing**: whatever `-m`/`model` names, or the default (`gpt-oss:20b` for Ollama, `openai/gpt-oss-20b` for LM Studio) when none is set [corrected 2026-10-20: openai/codex@rust-v0.163.0:codex-rs/ollama/src/lib.rs and codex-rs/lmstudio/src/lib.rs `ensure_oss_ready` pull/download `config.model` falling back to `DEFAULT_OSS_MODEL`]. Ollama must be ≥0.13.4 [source:…:codex-rs/ollama/src/lib.rs, codex-rs/lmstudio/src/lib.rs] [local-run]. Base URL overrides: `CODEX_OSS_BASE_URL`, `CODEX_OSS_PORT` [source:lib.rs]. For unattended jobs, prefer a plain custom provider at `http://localhost:11434/v1` (no auto-pull). |
| Model metadata | Unknown slugs use fallback metadata (warning). `model_catalog_json = "<abs path>"` supplies per-model `context_window`, `supported_reasoning_levels`, `default_reasoning_level`, `apply_patch_tool_type`, `shell_type`, … (schema = `codex-rs/models-manager/models.json`) [source]. A copied-and-edited entry removed the warning and added the `apply_patch` freeform tool [local-run]. Vendors ship their own `models.json` (DeepSeek, Z.ai, MiniMax) [docs]. Per-thread `config` cannot re-apply `model_catalog_json`; it is "applied on startup only" [source:…:codex-rs/config/src/config_toml.rs]. |
| Model discovery | With `auth.command` providers, Codex called `GET {base_url}/models?client_version=0.163.0` (3×, logged ERROR on 404, run continued). The `env_key` provider made no such call [local-run]. |

### 5.2 Reasoning effort

- `model_reasoning_effort` (or `turn/start.effort`) is sent **verbatim** as `reasoning.effort`. The values `none`, `minimal`, `high`, `low`, `max` and even `foo` all reached the stub unchanged [local-run]. `ReasoningEffort` has a `Custom(String)` variant [source:…:openai_models/reasoning_effort.rs].
- Default request without effort: `reasoning:{summary:"auto"}`. With `model_reasoning_summary="none"` it becomes `reasoning:{}`. `include:["reasoning.encrypted_content"]` is always sent [local-run].
- Per-provider mapping belongs in the wrapper:
  - DeepSeek: low / high / max [docs:https://api-docs.deepseek.com/updates/]
  - Z.ai: low / high / max, default max [docs:https://docs.z.ai/devpack/tool/codex]
  - MiniMax: low…max, `none` returns 400 [docs:https://platform.minimax.io/docs/token-plan/codex]
  - Ollama: model-defined names [docs:https://docs.ollama.com/api/openai-compatibility]

### 5.3 Who serves an OpenAI Responses endpoint (required, since chat is gone)

| Backend | Responses endpoint for Codex | Evidence | Notes |
|---|---|---|---|
| DeepSeek | `base_url="https://api.deepseek.com/"`, `wire_api="responses"` | [docs:https://api-docs.deepseek.com/quick_start/agent_integrations/codex] [docs:https://api-docs.deepseek.com/guides/responses_api/] | Native since V4-Flash 2026-07-31 and V4-Pro 2026-08-13 ("specifically adapted for Codex"); current model `deepseek-flash` (2026-10-17) [docs:/updates]. Unsupported params are silently ignored; `custom` tools only `apply_patch`; `developer` role treated as `user`. |
| Z.ai GLM | `base_url="https://api.z.ai/api/v1"`, `wire_api="responses"`, model `glm-5.3`, `model_catalog_json` | [docs:https://docs.z.ai/devpack/tool/codex] | Written for **GLM Coding Plan** keys (Individual and Team); "Codex requires a dedicated OpenAI Responses protocol endpoint". This bears on the plugin's ToS rule (§14). |
| Moonshot Kimi | `base_url="https://api.moonshot.ai/v1"`, `env_key="KIMI_API_KEY"`, `wire_api="responses"`, `kimi-k3`, `model_context_window=1048576` | [docs:https://platform.kimi.ai/docs/guide/codex-kimi] | "natively supports the Responses API … no protocol conversion or local proxy". Returns 400 on `web_search.search_context_size`. Kimi Code subscription keys work only on `api.kimi.com/coding/v1` [third-party:https://www.morphllm.com/kimi-api][unverified]. |
| MiniMax | `base_url="https://api.minimax.io/v1"`, `wire_api="responses"`, `MiniMax-M3.1-Flash` | [docs:https://platform.minimax.io/docs/token-plan/codex] | Recommends Codex ≥0.146.0; `effort:"none"` gives 400. |
| Qwen / Alibaba Model Studio | `https://<region or workspace>/compatible-mode/v1/responses` | [docs:https://www.alibabacloud.com/help/en/model-studio/compatibility-with-openai-responses-api] (updated 2026-10-19) | Lists Qwen 3.5–3.8, DeepSeek v4.x, GLM 5.2/5.3, Kimi k3; `reasoning.effort` supported; does not mention Codex. |
| OpenRouter | `https://openrouter.ai/api/v1/responses` | [docs:https://openrouter.ai/docs/api_reference/responses/basic-usage.md] | Stateless; `store: true` and `previous_response_id` are rejected with 400. The official pages do not call it beta [corrected 2026-10-20: basic-usage.md and create-a-response.md fetched; "beta" came only from third-party mirrors]. |
| Ollama | `http://localhost:11434/v1/responses` | [docs:https://docs.ollama.com/api/openai-compatibility] | Since v0.13.3, stateless only; Codex itself requires ≥0.13.4 [source:ollama/src/lib.rs]. |
| LM Studio | `http://localhost:1234/v1/responses` | [third-party/docs search: lmstudio.ai/docs/integrations/codex, changelog 0.3.29 2025-10-06][unverified: page not fetched] [verified 2026-10-20: lmstudio.ai/docs/integrations/codex fetched, says Codex talks to LM Studio via `POST /v1/responses` and uses `codex --oss`; lmstudio.ai/changelog/lmstudio-v0.3.29 is dated October 6, 2025] | Codex integration page exists. |
| vLLM | `/v1/responses` (+ get/cancel) | [docs:https://docs.vllm.ai/en/latest/serving/online_serving/] | "Only applicable to text generation models". |
| llama.cpp `llama-server` | `/v1/responses` (translated to chat internally) | [third-party:https://www.simplified.guide/llama-cpp/server-call-responses-api] [third-party:https://jacar.es/?p=7642] | The official server README documents `POST /v1/responses` ("works by converting Responses request into Chat Completions request"); added by PR #18486 "server: /v1/responses (partial)", merged 2026-01-21; `/responses` alias by PR #19873 [corrected 2026-10-20: gh api ggml-org/llama.cpp tools/server/README.md, search/issues]. |
| Anthropic-only endpoints (e.g. Z.ai `/api/anthropic`) | Not usable by Codex | [source:lib.rs] | Codex has no Messages-API wire. |

## 6. Auth and credentials

| Item | Finding |
|---|---|
| Custom provider auth | `env_key` (read from the **Codex process** environment at request time, `std::env::var`) [source:lib.rs `api_key()`]; or `auth.command` (no stdin, prints the token, cached and refreshed every `refresh_interval_ms`, rerun after a 401). It cannot be combined with `env_key`, `experimental_bearer_token` or `requires_openai_auth` [source] [docs:config-advanced]. `auth.command=/bin/cat <0600 keyfile>` worked via `-c` [local-run]. |
| ChatGPT subscription | Tied to `requires_openai_auth=true` (the OpenAI provider or an OpenAI-model proxy); with that set, `env_key` is ignored [docs:https://learn.chatgpt.com/docs/auth]. Third-party models need their own API key or plan key. |
| Login prompt | None for custom providers: `requires_openai_auth` defaults to false, so the login screen is skipped [source:lib.rs] [local-run: no auth.json ever created]. `codex doctor` reports `auth is provided by the active model provider` [local-run]. |
| Missing key | ``Missing environment variable: `STUB_KEY`.`` as `error` + `turn.failed`, exit 1, zero HTTP requests [local-run] |
| Credential stores | OpenAI auth: `$CODEX_HOME/auth.json` or keyring (`cli_auth_credentials_store = file|keyring|auto|ephemeral`) [docs:auth]. `CODEX_API_KEY` works for `codex exec` (OpenAI) [docs:non-interactive-mode]. The experiment unset `OPENAI_API_KEY`/`CODEX_API_KEY` and never touched `~/.codex`. |
| Isolation | Point `CODEX_HOME` at a wrapper-owned directory: config, auth, sessions, logs, skills and state all live there [local-run: file listing]. `--ignore-user-config` skips `$CODEX_HOME/config.toml` but "auth still uses `CODEX_HOME`" [local-run: help]. |
| Leak risks | (1) **The provider key in env is inherited by model-run shell commands** (`env | grep -c ^STUB_KEY=` → 1); `-c shell_environment_policy.ignore_default_excludes=false` → 0 [local-run]. The default is `ignore_default_excludes = true`, so the `*KEY*/*SECRET*/*TOKEN*` filter is off by default [source:…:codex-rs/config/src/shell_environment_policy.rs, codex-rs/protocol/src/shell_environment.rs]. (2) Vendor guides put the key in `config.toml` via `experimental_bearer_token` (DeepSeek, Z.ai, MiniMax). Avoid this; use `auth.command`. (3) Request headers carry metadata (§14). |

## 7. Autonomy for unattended runs

| Item | Finding |
|---|---|
| Approval in exec | Exec forces a headless `approval_policy = never`. Server requests for command or file approval, `request_user_input` and dynamic tools are **rejected** with "… not supported in exec mode"; MCP elicitations are auto-cancelled [source:…:codex-rs/exec/src/lib.rs `handle_server_request`] |
| Modes | `-s read-only` (default) / `workspace-write` / `danger-full-access`; `--dangerously-bypass-approvals-and-sandbox`; `--approve-for-me` (guardian auto-review; behaviour with third-party models [unverified]) [local-run: help] |
| Escalation | The `exec_command` tool exposes `sandbox_permissions: "require_escalated"`. Under `never` this cannot be approved, so it fails back to the model [source; inferred from exec handler] |
| Reviewer roles | `-s read-only` blocked file writes (`operation not permitted`) and network (`curl` exit 7) under a third-party provider [local-run]. `--output-schema` gives a structured verdict (§12). |
| Exec policy / hooks | `--ignore-rules` skips `.rules`; hooks need persisted trust unless `--dangerously-bypass-hook-trust` [local-run: help] |

## 8. Sandboxing

- Native and **independent of the provider**: on macOS it is Seatbelt (`"sandbox":"seatbelt"` in the request metadata) [local-run].
- Results:

  | Sandbox mode | Write inside repo | Write to `../` (under /private/tmp) | Network (`curl` to 127.0.0.1) |
  |---|---|---|---|
  | read-only | blocked | blocked | blocked (exit 7) |
  | workspace-write (default roots) | ok | **ok** (because /tmp and `$TMPDIR` are writable roots) | blocked |
  | workspace-write + `sandbox_workspace_write.exclude_slash_tmp=true` + `exclude_tmpdir_env_var=true` | ok | blocked | not tested |

  All rows [local-run].
- Network can be opened with `sandbox_workspace_write.network_access=true` [docs:config-advanced]. The plugin rule "unsandboxed harnesses only inside a git tree" is satisfied, and Codex adds a real sandbox on top.

## 9. Config and state isolation; side effects

| Item | Finding |
|---|---|
| Config dir | `CODEX_HOME` (default `~/.codex`) holds everything. One wrapper-owned home per provider profile, or one home plus per-job `-c` [local-run] |
| Global config not read | Fresh `CODEX_HOME` → user's `~/.codex/config.toml`, AGENTS.md, skills, hooks, rules, MCP and plugins are not loaded [local-run: request had only `.system` skills] |
| Project layers | `.codex/config.toml`, hooks and rules in the repo load only when the project is trusted [docs:config-advanced]. **`codex exec -s workspace-write` itself appended `[projects."<repo>"] trust_level = "trusted"` to `$CODEX_HOME/config.toml`** (read-only runs did not) [local-run]. Later runs then load project-local layers. Use a disposable or per-job home, or accept it. |
| Files created in a fresh home | `installation_id`, `sessions/`, `*.sqlite` (state, logs, goals, memories, queue, thread_history), `skills/.system/*` (bundled skills installed), `shell_snapshots/`, `.tmp/plugins.sync.lock`, `.tmp/git-*`, `thread-writer-locks/` [local-run] |
| Network side effects | First run in a fresh home, custom provider, `analytics.enabled=false`, `check_for_update_on_startup=false`: CONNECT attempts to **chatgpt.com:443** and **github.com:443** (git UA). `--disable plugins` alone eliminated both; `--disable remote_plugin` or `--disable apps` alone did not [local-run, observed via a refusing local proxy sink, so only env-proxy-respecting traffic is seen]. `codex doctor` additionally contacts formulae.brew.sh and chatgpt.com [local-run]. |
| Telemetry | Analytics are on by default (anonymous usage/health); `[analytics] enabled=false`; OTel off by default; `[feedback] enabled=false` [docs:config-advanced]. `x-codex-turn-metadata` reported `"analytics_enabled":false` when disabled [local-run]. |
| Recommended hardening flags | `--disable plugins --disable multi_agent --disable goals -c web_search='"disabled"' -c analytics.enabled=false -c feedback.enabled=false -c check_for_update_on_startup=false -c shell_environment_policy.ignore_default_excludes=false` [local-run for each, except that the analytics/feedback/update keys were set via config.toml] |

## 10. Concurrency and cancellation

| Item | Finding |
|---|---|
| Parallel runs | 3 concurrent `codex exec` on one `CODEX_HOME` all exited 0 [local-run] |
| Process tree | `codex exec` → `/bin/zsh -c <cmd>` → command. **Each tool command gets its own process group** (pgid = the shell's pid) [local-run] |
| SIGTERM | codex exits 143 at once; the running tool (`sleep 47`) is **orphaned** (ppid 1) and keeps running [local-run] |
| SIGINT | codex interrupts the turn, **kills the tool process group**, exits 1; no terminal JSON event, only a stderr `failed to record rollout items` line [local-run] |
| Recommended cancel | SIGINT → wait about 10 s → SIGTERM → SIGKILL. Then sweep descendants recorded during the run (walk `ps` by ppid/pgid), because tool pgids differ from codex's. |
| Servers and ports | `codex exec`: none (in-process app-server). The companion's broker uses a unix socket per workspace [repo: vendor/codex-companion/scripts/lib/broker-lifecycle.mjs]. There is also a shared `codex app-server daemon` (feature `daemon_auto_start`), not used by exec [local-run: features list] |
| Idle stream | `stream_idle_timeout_ms` default 300000 ms, per provider [source:lib.rs] |

## 11. Error signatures for classification (stub, `request_max_retries=1`, `stream_max_retries=1`) [local-run]

| Class | Stub response | `turn.failed.error.message` / final `error` | Exit | HTTP attempts |
|---|---|---|---|---|
| auth | 401 JSON | `unexpected status 401 Unauthorized: <body message>, url: <url>` | 1 | 2 |
| rate limit (HTTP) | 429 `rate_limit_exceeded` | `exceeded retry limit, last status: 429 Too Many Requests` | 1 | 2 |
| rate limit (SSE `response.failed`) | `rate_limit_exceeded` | `rate limit exceeded: <message>` | 1 | 2 |
| quota | 429 `insufficient_quota` | `Quota exceeded. Check your plan and billing details.` | 1 | 1 (no retry) |
| server 5xx | 500 | `We’re currently experiencing high demand, which may cause temporary errors.` (**misleading** for third parties) | 1 | 4 |
| context overflow | SSE `response.failed` `context_length_exceeded` | `Codex ran out of room in the model's context window. Start a new thread or clear earlier history before retrying.` | 1 | 1 |
| model not found | 404 `model_not_found` | `unexpected status 404 Not Found: <message>, url: …` | 1 | 2 |
| missing key | – | ``Missing environment variable: `X`.`` | 1 | 0 |
| config | – | `Error loading config.toml: …` on stderr (no JSON) | 1 | 0 |
| network | – | not tested; transport errors retry (`retry_transport: true`) [source:lib.rs] | – | – |

- Intermediate retries appear as `{"type":"error","message":"Reconnecting... n/m (…)"}` before the final one [local-run].
- HTTP-level `retry_429` is false, but stream-level retry still re-sent the request once [source:lib.rs][local-run].
- `response.failed` codes mapped by Codex: `context_length_exceeded`, `insufficient_quota|credit_balance_exhausted|organization_spend_limit_exceeded|project_spend_limit_exceeded`, `usage_not_included`, `rate_limit_exceeded|slow_down`, `server_is_overloaded`, `invalid_prompt`, … [source:…:codex-rs/codex-api/src/sse/responses_error.rs]. Third-party vendors use their own codes, so the classifier should match HTTP status plus vendor text.

## 12. Structured output / verdict support

- `--output-schema schema.json` sends `text.format = {type:"json_schema", strict:true, schema, name:"codex_output_sch…"}`. The final message (and the `-o` file) was the JSON document [local-run].
- The backend must honour `text.format`:
  - DeepSeek: "fully supported" [docs:responses_api]
  - Ollama: not listed among supported fields [docs:ollama]
  - others: [unverified]
- Safer plugin protocol: keep the status token on line 1 of a plain final message, which works with any backend, and use `--output-schema` only where verified. app-server has the equivalent `turn/start.outputSchema` [source:TurnStartParams.ts].

## 13. Usage and cost reporting

- `turn.completed.usage = {input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens, reasoning_output_tokens}`, copied from the provider's `response.completed.response.usage` (`input_tokens_details.cached_tokens`, `output_tokens_details.reasoning_tokens`) [local-run][source:sse/responses.rs].
- No cost figure is given; the wrapper must price tokens per provider. Providers that omit usage give zeros or nothing [unverified].

## 14. ToS notes (brief)

- **Codex license** is Apache-2.0. OpenAI documents custom providers and does not bundle third parties by policy ("Users are encouraged to add to `model_providers`") [source:lib.rs].
- **Vendor-sanctioned use:** DeepSeek, Moonshot, MiniMax and Z.ai publish official Codex setup pages. **Z.ai documents Codex for GLM Coding Plan keys** [docs:https://docs.z.ai/devpack/tool/codex]. This may relax the plugin's "GLM only through Z.ai's own harness" rule. The ToS researcher must confirm against the Coding Plan terms; the page itself does not say "officially supported" [docs][unverified].
- **Client identification:**
  - `codex exec` sends `originator: codex_exec` and `user-agent: codex_exec/0.163.0 (Mac OS 26.5.2; arm64) …` [local-run]. This is truthful.
  - Through app-server, originator and UA are taken from `initialize.clientInfo.name` (`h5_probe` in the probe) [local-run]. The vendored companion's `DEFAULT_CLIENT_INFO.name = "Claude Code"` [repo: vendor/codex-companion/scripts/lib/app-server.mjs] would therefore present itself to third-party providers as "Claude Code". This is inferred from the probe and not tested with that exact name [unverified]. Use a truthful name.
- **Data sent to the provider:** `x-codex-turn-metadata` header and `client_metadata` body contain `installation_id`, `session_id`/`thread_id`, the **absolute workspace path**, **latest git commit hash** + `has_changes`, sandbox mode, and model [local-run]. The system prompt says "You are a coding agent running in the Codex CLI … led by OpenAI" [local-run].
- **No token extraction is involved.** Keys are the user's own API or plan keys.

## 15. Gotchas

1. The chat wire API is gone. A provider without `/responses` (e.g. Anthropic-only or chat-only plan endpoints such as Z.ai `/api/coding/paas/v4` or `/api/anthropic`) needs a translating proxy, which the plugin should not ship [source][third-party: openai/codex#9612].
2. The default tool list includes `{"type":"web_search","external_web_access":…}` (hosted) and `{"type":"namespace","name":"multi_agent_v1"}`. With a catalog entry it also includes the freeform `apply_patch` (`custom` tool) [local-run]. Strict backends may 400 (Kimi documents a 400 on `web_search.search_context_size`). Disable with `web_search="disabled"`, `--disable multi_agent`, `--disable goals` [local-run].
3. The body always has `store:false`, `include:["reasoning.encrypted_content"]`, `prompt_cache_key`, `parallel_tool_calls:true`, and developer-role system messages (no `instructions`) [local-run]. DeepSeek ignores unsupported parameters silently [docs]; others [unverified].
4. Effort strings are not validated (`foo` is sent). The wrapper must validate per provider [local-run].
5. An `error`-typed item for missing model metadata appears on successful runs [local-run].
6. The `-s workspace-write` trust write-back into `config.toml` [local-run].
7. `/tmp` and `$TMPDIR` are writable under workspace-write by default [local-run].
8. SIGTERM orphans tool processes [local-run].
9. `--oss` can trigger large model downloads [source].
10. `exec resume` rejects `-s` and `-p` after `resume` [local-run]. The provider id is pinned on resume [source].
11. The 5xx message suggests "high demand" even for a vendor's 500 [local-run].
12. The companion (if extended):
    - its broker is per workspace and inherits the **first** caller's env, so `env_key` values must be present when it spawns [repo: broker-lifecycle.mjs]
    - `--resume-last` filters by the default provider [source]
    - `setup` reports "not logged in" because `account/read` returns `requiresOpenaiAuth: true` for the default provider, even though custom-provider threads work [local-run]
13. Docs moved to learn.chatgpt.com; many third-party guides are stale (chat wire API, `[profiles.x]`).

## 16. Adapter sketch for this plugin

**Recommendation: a new `bin/codexmp-dispatch` (ids `cx-…`)** built on the zcode-dispatch job machinery (job records, per-workspace reservation lock, boot-id liveness, env allowlist, redaction, error classes), with `codex exec --json` as the engine. A *provider profile* registry is owned by the wrapper.

| Plugin op | Mapping |
|---|---|
| profile registry | `~/.claude/plugins/data/superpowers-strigov-ver-codexmp/profiles/<id>.json`: `{base_url, model, effort_map, catalog?, key_source, extra_headers?, family}`; key file `keys/<id>` (0600) written by `codexmp-dispatch api-key set <id>` (stdin, never chat); `CODEX_HOME` = `homes/<id>/` (or per job, to absorb the trust write-back) |
| task | Write the prompt to the job dir. Spawn detached `codex exec --json -o <job>/last.txt -C <cwd> -s workspace-write|read-only -c model_provider=… -c 'model_providers.<id>={…, auth={command="<node>", args=["<wrapper>","print-key","<id>"]}}' -m <model> -c model_reasoning_effort=<mapped> [hardening flags §9] -c sandbox_workspace_write.exclude_slash_tmp=true -c sandbox_workspace_write.exclude_tmpdir_env_var=true -` with stdin = prompt file. Record pid, start time and `thread_id` from the first JSONL line. |
| status | Tail JSONL: `turn.started` → running; last `item.*` → phase; `turn.completed` / `turn.failed` / process exit → terminal |
| result | `last.txt` line 1 = status token (DONE / …); usage from `turn.completed`; touched files from `file_change` items |
| cancel | SIGINT → 10 s → SIGTERM → SIGKILL, then sweep the recorded descendant pgids (§10) |
| resume | `codex exec -s <mode> -C <cwd> <same -c provider flags> resume <thread_id> -` (flags before `resume`) |
| doctor | `codex --version` ≥ pinned minimum, plus key-file presence (never print it), plus a wrapper-native, no-token TLS/HTTP reachability check of `base_url`. `codex doctor --json -c …` gives `config.load`, `auth.credentials` and `network.provider_reachability`, but it is noisy: its `/models` route probe is "required" (it fails on providers without `/models`), and it contacts formulae.brew.sh and chatgpt.com [local-run]. Use it only as an optional deep check. |
| probe | One real minimal turn (`"Reply with OK"`, low effort, `--ephemeral`) costs tokens. Classify with §11. |
| error classes | auth / quota / rate_limit / model_not_found / context_overflow / config / missing_key / network / crash / timeout from `turn.failed.message`, HTTP status text and exit code (§11) |
| family rule | Family = the **model vendor** (DeepSeek, GLM, Kimi, …), not "Codex". A Codex-harnessed GLM writer must not be reviewed by GLM. |

**Alternative (smaller diff, more caveats): extend the vendored companion.** Add `--provider <id>` → `thread/start|resume {modelProvider, config:{"model_providers.<id>":{… auth.command …}}}` (proven in the probe [local-run]).
- Use `auth.command` instead of `env_key`, because the shared broker's env is fixed at spawn.
- Pass `modelProviders: []` in `thread/list`.
- Set a truthful `clientInfo.name`.
- Skip the OpenAI login check when a provider is selected.
- The local patch set to re-apply on upstream bumps grows.

## 17. Sources

- Local: `codex --help`, `codex exec --help`, `codex exec resume --help`, `codex app-server --help`, `codex doctor --help`, `codex login --help`, `codex features list` (codex-cli 0.163.0) [local-run]
- `openai/codex@rust-v0.163.0` (tag object `129b8ec7…`, released 2026-10-15), all fetched with `gh api … contents/<path>?ref=rust-v0.163.0`:
  - `codex-rs/model-provider-info/src/lib.rs`, `…/capabilities.rs`
  - `codex-rs/exec/src/lib.rs`, `exec_events.rs`
  - `codex-rs/app-server/src/request_processors/thread_processor.rs`, `codex-rs/app-server/src/config_manager.rs`
  - `codex-rs/app-server-protocol/schema/typescript/v2/{ThreadStartParams,TurnStartParams,ThreadResumeParams}.ts`
  - `codex-rs/codex-api/src/sse/responses.rs`, `responses_error.rs`
  - `codex-rs/protocol/src/config_types.rs`, `openai_models/reasoning_effort.rs`, `shell_environment.rs`
  - `codex-rs/config/src/config_toml.rs`, `shell_environment_policy.rs`
  - `codex-rs/ollama/src/lib.rs`, `codex-rs/utils/oss/src/lib.rs`, `codex-rs/lmstudio/src/lib.rs`
  - `codex-rs/models-manager/models.json`, `README.md`
- GitHub discussion openai/codex#7782 "Deprecating `chat/completions` support in Codex" (created 2025-12-09) via `gh api repos/openai/codex/discussions/7782`
- Docs (fetched 2026-10-20):
  - https://learn.chatgpt.com/docs/config-file/config-advanced
  - https://learn.chatgpt.com/docs/non-interactive-mode
  - https://learn.chatgpt.com/docs/auth
  - https://api-docs.deepseek.com/guides/responses_api/
  - https://api-docs.deepseek.com/updates/
  - https://api-docs.deepseek.com/quick_start/agent_integrations/codex
  - https://docs.z.ai/devpack/tool/codex
  - https://platform.kimi.ai/docs/guide/codex-kimi
  - https://platform.minimax.io/docs/token-plan/codex
  - https://www.alibabacloud.com/help/en/model-studio/compatibility-with-openai-responses-api
  - https://openrouter.ai/docs/api_reference/responses/basic-usage.md
  - https://docs.ollama.com/api/openai-compatibility
  - https://docs.vllm.ai/en/latest/serving/online_serving/
- Third-party:
  - https://www.simplified.guide/llama-cpp/server-call-responses-api
  - https://jacar.es/?p=7642
  - https://www.morphllm.com/kimi-api
  - https://github.com/openai/codex/issues/9612
- This repo: `bin/codex-dispatch`, `vendor/codex-companion/{VERSION, scripts/lib/codex.mjs, scripts/lib/app-server.mjs, scripts/lib/broker-lifecycle.mjs, scripts/app-server-broker.mjs, scripts/codex-companion.mjs}` (companion v1.0.4 + local patches)

## Appendix A: Experiment log (trimmed)

Scratch: `/private/tmp/claude-501/…/scratchpad/h5-codex-stub/`. The stub (`stub.mjs`) is a Node HTTP server on 127.0.0.1:18765. It logs method, path, masked headers and body keys, and answers with Responses SSE (`response.created` → `output_item.added` → `output_text.delta` → `output_item.done` → `response.completed{usage}`). Modes: ok, 401, 429, 429-sse, quota, 500, ctx, badmodel, tool, schema, hang. A refusing proxy sink (`sinkproxy.mjs`, 127.0.0.1:18766) logged CONNECT targets. `CODEX_HOME` was always a fresh scratch dir, and `OPENAI_API_KEY`/`CODEX_API_KEY` were unset. No real endpoint was called. Both servers were killed afterwards.

Scratch `config.toml`:
```toml
model = "stub-model-1"
model_provider = "stub"
check_for_update_on_startup = false
[analytics]
enabled = false
[feedback]
enabled = false
[model_providers.stub]
name = "Local Stub"
base_url = "http://127.0.0.1:18765/v1"
env_key = "STUB_KEY"
wire_api = "responses"
request_max_retries = 1
stream_max_retries = 1
```

1. **Basic run.** Command: `cd repo && env -u OPENAI_API_KEY -u CODEX_API_KEY CODEX_HOME=$S/home STUB_KEY=dummy-stub-key-123456 codex exec --json -o last1.txt "Say hello"`. Exit 0.
   - Events: `thread.started` → `item.completed{type:error,"Model metadata … not found"}` → `turn.started` → `agent_message "DONE\nstub reply…"` → `turn.completed{usage:{input_tokens:123,…}}`.
   - Stub saw 1× `POST /v1/responses`.
   - Headers: `authorization: Bearer dum…(28 chars)`, `originator: codex_exec`, `user-agent: codex_exec/0.163.0 (Mac OS 26.5.2; arm64) …`, `x-codex-turn-metadata` (installation_id, workspace path, git hash, sandbox seatbelt, analytics_enabled:false).
   - Body keys: model, stream, input, tools, tool_choice, parallel_tool_calls, reasoning `{summary:auto}`, store `false`, include `[reasoning.encrypted_content]`, prompt_cache_key, client_metadata.
   - Tools: exec_command, write_stdin, request_user_input, view_image, multi_agent_v1 (namespace), get_goal, create_goal, update_goal, web_search (hosted).
2. **Fresh home with the proxy sink.** CONNECT `chatgpt.com:443` and `github.com:443` (UA git/2.50.1). With `--disable plugins` there were none. `--disable remote_plugin` alone and `--disable apps` alone did not stop them.
3. **Effort, schema and trimmed tools.** Flags: `-c model_reasoning_effort='"high"' -c web_search='"disabled"' --disable multi_agent --disable goals --output-schema schema.json`.
   - Request: `reasoning {effort:high, summary:auto}`, `text.format {type:json_schema, strict:true,…}`, tools reduced to exec_command, write_stdin, request_user_input, view_image.
   - Efforts `none`, `minimal`, `max` and `foo` were each sent verbatim.
4. **Errors.** See §11.
   - `-c 'model_providers.stub.wire_api="chat"'` → `Error loading config.toml: \`wire_api = "chat"\` is no longer supported…`, exit 1.
   - Unset `STUB_KEY` → ``Missing environment variable: `STUB_KEY`.``, exit 1, 0 requests.
5. **Sandbox.** The stub returned a `function_call exec_command`.
   - read-only: `operation not permitted` ×2, `net=000 curl=7`.
   - workspace-write: inside and `../` writes ok (under /private/tmp), curl 7.
   - Adding `exclude_slash_tmp` and `exclude_tmpdir_env_var`: `../` and `/private/tmp/...` blocked.
   - After workspace-write, `config.toml` gained `[projects."…/repo"] trust_level = "trusted"`.
6. **Resume.** `codex exec resume --json <tid> "second turn"` → exit 0, input included the prior assistant message. After `--ephemeral`, resume failed with `no rollout found … (code -32600)`.
7. **app-server probe** (`appserver-probe.mjs`). Spawned `codex app-server --disable plugins` with a scratch home that has **no** provider config, plus `STUB_KEY_A` and `STUB_KEY_B`.
   - `account/read` → `{"account":null,"requiresOpenaiAuth":true}`.
   - `thread/start{modelProvider:"stubA", config:{"model_providers.stubA":{…,"http_headers":{"x-probe-provider":"A"}}, web_search:"disabled", "features.multi_agent":false, "features.goals":false}}` + `turn/start{effort:"high"}` → completed. Same for stubB with `effort:"low"`.
   - Stub saw two requests: `x-probe=A, reasoning {effort:high}` and `x-probe=B, reasoning {effort:low}`, `originator: h5_probe`.
   - stubC with `wire_api:"chat"` → JSON-RPC `-32600 failed to load configuration: …chat is no longer supported…`.
   - `config.toml` was unchanged.
8. **`auth.command`.** `-c 'model_providers.cmdauth={…,auth={command="/bin/cat",args=["keyfile.txt"]}}'` → Bearer = file content (31 chars incl. "Bearer "). Before the turn: 3× `GET /v1/models?client_version=0.163.0`, which got 404, logged as ERROR, non-fatal.
9. **`--oss`.**
   - `--oss --local-provider ollama` with `CODEX_OSS_BASE_URL` = stub → `GET /v1/models` then `OSS setup failed: No running Ollama server detected…`, exit 1.
   - lmstudio → `…404 Not Found LM Studio is not responding…`, exit 1.
   - `--oss` alone → `No default OSS provider configured…`, exit 1.
10. **Profiles.**
    - `$HOME5/stubprof.config.toml` defining `pstub` + `codex exec -p stubprof` → ok, `model=profile-model`, `effort=low`.
    - A legacy `[profiles.legacy]` table → error.
    - `codex -p stubprof app-server` → `--profile only applies to runtime commands…`.
    - `codex app-server -c model_provider="pstub2"` → ``Model provider `pstub2` not found``.
11. **Cancel.** The tool command was `sleep 47`.
    - SIGTERM → codex exit 143; `/bin/zsh -c sleep 47` (own pgid) re-parented to 1 and still running.
    - SIGINT → codex exit 1 and the sleep was gone.
    - Orphans were killed manually.
12. **Env leak.** Tool `echo seen=$(env | grep -c ^STUB_KEY=)` → `seen=1` by default and `seen=0` with `-c shell_environment_policy.ignore_default_excludes=false`.
13. **Concurrency.** 3 parallel `codex exec` on one home → all exit 0.
14. **`codex doctor --json`.**
    - Overall `fail`. `network.provider_reachability`: `stub API inference URL … reachable (HTTP 200)`, `stub API route probe … returned HTTP 404 (required)`.
    - `auth.credentials`: `model provider requires OpenAI auth: false`, `provider auth env var: STUB_KEY (present)`.
    - The proxy sink saw `formulae.brew.sh:443` and `chatgpt.com:443`.

## Open questions

- Do strict third-party Responses servers accept Codex's full request shape? This covers `namespace` tools, the `custom` apply_patch tool, `include:["reasoning.encrypted_content"]`, `prompt_cache_key`, `store:false` and developer-role messages. It was not tested live, since remote calls were not allowed. Only DeepSeek documents "silently ignored" [docs].
- Do Z.ai Coding Plan terms allow Codex (an official Codex guide exists)? If yes, GLM could also run through Codex, and the plugin's "Z.ai harness only" rule would need revisiting.
- Does Codex make direct (non-env-proxy) connections that the sink could not see? TUN-mode routing hides them; a packet-level check is needed.
- What is the minimal valid `model_catalog_json` entry for a custom model? A copied `gpt-5.5` entry works, but the set of required fields is unknown.
- Behaviour of `--approve-for-me` (guardian auto-review) with third-party providers.
- llama.cpp `/v1/responses`: official confirmation and version; LM Studio's exact Codex page content. [corrected 2026-10-20: both now answered in §5.3: llama.cpp README documents it (PR #18486, merged 2026-01-21); the LM Studio page says `POST /v1/responses` via `codex --oss`]
- Kimi Code subscription key endpoint (`api.kimi.com/coding/v1`) and whether it serves `/responses`.

## Fact-check log (2026-10-20)

Method: primary sources opened independently of the report (`gh api` on `openai/codex@rust-v0.163.0`, vendor doc pages via WebFetch, local `codex` 0.163.0 help output). The local claims were re-run in a new scratch experiment (`scratchpad/fc05/`). It used fresh `CODEX_HOME`s, a new stub on 127.0.0.1:18799, a refusing proxy sink on 127.0.0.1:18798, dummy keys and no remote model endpoint. Both servers were killed afterwards and the one orphaned `sleep 47` was removed.

| Claim | Verdict | Evidence |
|---|---|---|
| `wire_api = "chat"` is a hard config error in 0.163.0 (config.toml and `-c`), exit 1, no request | confirmed | local-run: fresh `CODEX_HOME`, both forms print ``Error loading config.toml: `wire_api = "chat"` is no longer supported.`` and exit 1; `lib.rs` L100/L130 `CHAT_WIRE_API_REMOVED_ERROR`, enum has only `Responses` |
| Custom provider: one `POST /v1/responses`, Bearer = env value, `originator: codex_exec`, no login, exit 0 | confirmed | local-run: stub saw exactly 1 POST, `authorization: Bearer dum…`, `originator: codex_exec`, UA `codex_exec/0.163.0 (Mac OS 26.5.2; arm64)`, exit 0 |
| app-server `thread/start` takes `modelProvider` + `config`; two threads, two providers, config.toml untouched; wire chat gives -32600 | confirmed | `ThreadStartParams.ts`/`ThreadResumeParams.ts` have `modelProvider` and `config`; `config_manager.rs` `load_with_cli_overrides` merges request overrides as CLI overrides; local probe: threads stubA/stubB hit the stub with `x-probe-provider` A/B and effort high/low, `config.toml` diff empty, stubC chat → `-32600 failed to load configuration…` |
| originator/UA come from `initialize.clientInfo.name` | confirmed | local probe with name `fc05_probe` → `originator: fc05_probe`, `userAgent: fc05_probe/0.163.0 …`; companion `DEFAULT_CLIENT_INFO.name = "Claude Code"` (app-server.mjs:28). Not tested with that exact name |
| DeepSeek: native Responses "specifically adapted for Codex" (V4-Flash 2026-07-31, V4-Pro 2026-08-13); Codex config `base_url="https://api.deepseek.com/"`, `wire_api="responses"` | confirmed | api-docs.deepseek.com/updates/ and /quick_start/agent_integrations/codex; also effort low/high/max and `deepseek-flash` |
| DeepSeek Responses guide: unsupported params ignored, `custom` only `apply_patch`, developer→user, `format` fully supported | confirmed | api-docs.deepseek.com/guides/responses_api/ |
| Z.ai: `base_url="https://api.z.ai/api/v1"`, `wire_api="responses"`, `glm-5.3`, "dedicated OpenAI Responses protocol endpoint", GLM Coding Plan, effort default max | confirmed | docs.z.ai/devpack/tool/codex. The page has no "officially supported" statement |
| Kimi: `https://api.moonshot.ai/v1`, `KIMI_API_KEY`, `kimi-k3`, `model_context_window=1048576`, native Responses, 400 on `web_search.search_context_size` | confirmed | platform.kimi.ai/docs/guide/codex-kimi |
| MiniMax: `https://api.minimax.io/v1`, `wire_api="responses"`, `MiniMax-M3.1-Flash`, Codex ≥0.146.0 recommended, `effort:"none"` → 400 | confirmed | platform.minimax.io/docs/token-plan/codex |
| Alibaba Model Studio `/compatible-mode/v1/responses`; Qwen 3.5–3.8, DeepSeek V4.x, GLM 5.2/5.3, Kimi K3; `reasoning.effort`; no Codex mention; updated 2026-10-19 | confirmed | alibabacloud.com/help/en/model-studio/compatibility-with-openai-responses-api ("Last Updated:Oct 19, 2026") |
| Ollama `/v1/responses` since v0.13.3, stateless only | confirmed | docs.ollama.com/api/openai-compatibility |
| Codex requires Ollama ≥0.13.4 | confirmed | `codex-rs/ollama/src/lib.rs` `min_responses_version() = 0.13.4` |
| `--oss` auto-pulls the default model if missing | corrected | `ensure_oss_ready` pulls/downloads whatever model is configured (`-m`/`model`), with the defaults used only when none is set |
| LM Studio `/v1/responses`, ≥0.3.29 (2025-10-06), Codex page exists | confirmed | lmstudio.ai/docs/integrations/codex fetched; changelog v0.3.29 dated October 6, 2025 |
| vLLM `/v1/responses` (+ get/cancel), "Only applicable to text generation models" | confirmed | docs.vllm.ai/en/latest/serving/online_serving/ |
| OpenRouter Responses is "beta" | corrected | official basic-usage and create-a-response pages carry no beta label; stateless, `previous_response_id` rejected |
| llama.cpp `/v1/responses` confirmed only by third parties | corrected | official `tools/server/README.md` documents `POST /v1/responses`; PR #18486 merged 2026-01-21 |
| `model_reasoning_effort` sent verbatim (none, max, foo) | confirmed | local-run: `reasoning.effort` = `foo`, `max`, `none`, all exit 0; `ReasoningEffort::Custom(String)` exists (`protocol/src/openai_models.rs`) |
| Provider key leaks to model-run commands; `ignore_default_excludes=false` hides it; default true | confirmed | local-run: `seen=1` default, `seen=0` with override; `shell_environment_policy.rs` `unwrap_or(true)`, `shell_environment.rs` `*KEY*/*SECRET*/*TOKEN*` only when false |
| Requests carry installation_id, absolute workspace path, git HEAD, sandbox mode | confirmed | local-run: `x-codex-turn-metadata` and `client_metadata` contained `installation_id`, `workspaces{<abs path>:{latest_git_commit_hash,has_changes}}`, `sandbox:"seatbelt"`, `sandbox_mode`, `model`, `analytics_enabled:false` |
| `-s workspace-write` writes `trust_level = "trusted"` into `$CODEX_HOME/config.toml`; read-only does not | confirmed | local-run (read-only run left config unchanged; workspace-write appended `[projects."…/repo"] trust_level = "trusted"`); source `thread_processor.rs` ~L1376 `set_project_trust_level(... TrustLevel::Trusted)` when the effective sandbox can write cwd |
| Default tools include hosted `web_search` and `namespace multi_agent_v1`; trimming flags leave 4 function tools | confirmed | local-run: 9 tools incl. `{"type":"web_search","external_web_access":false}`; with `web_search="disabled" --disable multi_agent --disable goals` → exec_command, write_stdin, request_user_input, view_image |
| SIGTERM → exit 143, tool orphaned (ppid 1); SIGINT → exit 1, tool killed | confirmed | local-run: `sleep 47` (own pgid) re-parented to 1 after SIGTERM; after SIGINT gone, stderr `failed to record rollout items`; source: exec only installs `tokio::signal::ctrl_c()` |
| Fresh home contacts chatgpt.com/github.com; `--disable plugins` eliminates both | confirmed | local-run proxy sink: `CONNECT chatgpt.com:443`, `CONNECT github.com:443`; none with `--disable plugins` (env-proxy traffic only) |
| `-p` layers `<name>.config.toml`; legacy `[profiles.x]` error; app-server rejects `--profile` | corrected | layering since 0.134.0 confirmed (docs); legacy error fires only when `-p` names the legacy profile (`config/src/loader/mod.rs`); `--profile only applies to runtime commands…` string in `cli/src/main.rs` |
| `auth.command` fields; cannot combine with env_key/bearer/requires_openai_auth | confirmed | `protocol/src/config_types.rs` `ModelProviderAuthInfo{command,args,timeout_ms,refresh_interval_ms,cwd}`; `lib.rs` "provider auth cannot be combined with …"; docs:config-advanced |
| Retry defaults 4/5 (cap 100), idle 300000 ms, `retry_429:false`, `retry_transport:true` | confirmed | `model-provider-info/src/lib.rs` L66–75, L455–459 |
| Built-ins openai/amazon-bedrock(-runtime)/ollama/lmstudio; only Bedrock overridable; docs reserve openai/ollama/lmstudio | confirmed | `lib.rs` `built_in_model_providers`, `merge_configured_model_providers`; docs:config-advanced |
| Chat removal announced 2025-12-09 for Feb 2026 (discussion #7782) | confirmed | `gh api repos/openai/codex/discussions/7782` created 2025-12-09T17:22:42Z, "Full removal is slated for early February 2026" |
| rust-v0.163.0 published 2026-10-15T21:30:38Z; 0.164.0-alpha.1–6 2026-10-16..19; ~130k stars; Apache-2.0 | confirmed | `gh api` releases and repo: 130,089 stars, pushed 2026-10-20 |
| developers.openai.com/codex/* → 308 to learn.chatgpt.com | confirmed | `curl -w %{redirect_url}`: 308 → learn.chatgpt.com/docs/config-file/config-advanced, /docs/non-interactive-mode |
| `--full-auto` removed; default stdout/stderr split; `CODEX_API_KEY` for exec | confirmed | learn.chatgpt.com/docs/non-interactive-mode |
| `requires_openai_auth=true` → `env_key` ignored; credential store values | confirmed | learn.chatgpt.com/docs/auth |
| Git check message and `--skip-git-repo-check`/bypass exemption; exec uses `InProcessAppServerClient`; exec rejects approvals/user input | confirmed | `exec/src/lib.rs` L1013–1018, L22/L1022, L2103–2202 |
| `thread/list` filters by default provider unless `modelProviders: []`; companion `findLatestTaskThread` omits it | confirmed | `thread_processor.rs` ~L5788; `vendor/codex-companion/scripts/lib/codex.mjs:1038` |
| Resume reapplies persisted model/provider/effort unless overridden | confirmed | `thread_processor.rs` `merge_persisted_resume_metadata`, `has_model_resume_override` |
| `model_catalog_json` applied on startup only | confirmed | `config/src/config_toml.rs` L404–405 |
| Error-message strings (high demand, quota, context window) and `response.failed` codes | confirmed | `protocol/src/error.rs` (search hit), `codex-api/src/sse/responses_error.rs` code list |
| Exec subcommands/flags (`exec resume/fork/review`, `--ignore-user-config` text, `--approve-for-me`, `--dangerously-bypass-hook-trust`, `--ephemeral`, `--output-schema`); resume lacks `-s`/`-p` | confirmed | local `codex exec --help`, `codex exec resume --help` |
| `daemon_auto_start` feature exists | confirmed | local `codex features list` (stable, true) |
| ARG_MAX 1,048,576; macOS 26.5 | confirmed | `getconf ARG_MAX`; `sw_vers` 26.5.2 |
| System prompt "You are a coding agent running in the Codex CLI … led by OpenAI" | confirmed | local-run request body |
| `docs/` is gitignored (.gitignore:5) | confirmed | `git check-ignore -v` → `.gitignore:5:docs/` |
| Kimi Code subscription keys only on `api.kimi.com/coding/v1` | unverifiable | only a third-party page; the official Kimi Codex page does not mention it (left `[unverified]`) |
| Model discovery `GET /models?client_version=…` with `auth.command`; `codex doctor` contacts formulae.brew.sh | unverifiable | not re-run; left as the researcher's local-run |

Extra observation (not a correction): `codex app-server --help` says analytics are disabled by default for app-server unless `--analytics-default-enabled` is passed. The §9 "analytics on by default" statement comes from the general docs and applies to the CLI.

Reliability: high. Every high-stakes claim I could test held up when re-run independently. That covers the chat-wire hard error, per-thread providers in app-server, the trust write-back, the env-key leak, the SIGTERM orphan and SIGINT cleanup, effort passthrough, request metadata and the plugin-driven network calls. The vendor Codex configs from DeepSeek, Z.ai, Kimi and MiniMax match their official pages, including base URLs, model ids and quoted phrases. I made four corrections, and none of them changes the design. llama.cpp is officially documented, not third-party-only. OpenRouter is not labelled beta. `--oss` auto-pulls whatever model is selected, not only the default. Legacy `[profiles.x]` tables error only when `-p` selects that name.
