# 08 — Local models as dispatch targets

Research date: 2026-10-20. Researcher key: `08-local-models`. Scope: local inference servers, their API surfaces, the harnesses that can drive them, models that fit 16/32/64/128 GB of unified memory, and which pipeline roles a local model can realistically fill.

## Bottom line

1. **Plumbing is solved; the hardware is the constraint.** Ollama (v0.40.6), LM Studio (0.4.1+) and llama.cpp `llama-server` (b11753) all expose Anthropic `/v1/messages`, OpenAI `/v1/chat/completions` and OpenAI `/v1/responses` from one local process. So Claude Code, Codex, OpenCode and pi can each reach a local model without a translation proxy [docs:https://docs.ollama.com/api/anthropic-compatibility; docs:https://lmstudio.ai/docs/developer/api-changelog; source:ggml-org/llama.cpp@b11753:tools/server/README.md]. `mlx_lm.server` speaks OpenAI chat only [source:ml-explore/mlx-lm@v0.32.2:mlx_lm/server.py].
2. **On this machine (M4, 16 GB) a local implementer channel is not viable.** Metal's GPU working set is 12,124 MiB [local-run]. The machine already runs with 3.47 GB of 4 GB swap used and the compressor holding ~19.7 GiB of data, before any model loads [local-run]. The models that fit (Qwen3.5-9B, Gemma 4 12B) publish no SWE-bench score. They run at about 20 tok/s decode and 220 tok/s prefill on an M4 [third-party:https://omlx.ai/benchmarks/nw2dhnfb].
3. **Default `claude -p` is expensive to prefill locally.** It sends 66,034 bytes (system prompt plus 20 tool schemas, ~16–19k tokens) [unverified by fact-check: the non-bare capture was not re-run, because non-bare mode may read the keychain] before our 20–120 KB dispatch prompt. `claude --bare` cuts that to 4.3 KB [local-run; reproduced by fact-check on 2.1.302: 4,385 bytes, and 4,285 with attribution off]. At ~220 tok/s, the first prefill alone takes ~1.5–4 min. That approaches Claude Code's 300-second stream watchdog for custom base URLs [docs:https://code.claude.com/docs/en/network-config]. llama-server sends HTTP 200 headers as soon as a slot starts processing the prompt. During prefill it then sends an SSE comment ping (`:`) every 30 s by default. So prefill is not silent on the wire, but no SSE event arrives until the first token. Claude Code's docs say pings reset the byte-level watchdog. They reset the event-level watchdog only "for up to about five minutes without a parsed event" [corrected 2026-10-20: llama.cpp@b11753 server-context.cpp:3924-3932 sends an `is_begin` partial "to send the headers (i.e. 200 status)", server-task.cpp:1020-1022, ping loop at server-context.cpp:5088-5104, README `sse_ping_interval` "during long prompt processing"; code.claude.com/docs/en/network-config].
4. **The classic pitfall is real and current.** Ollama defaults to a 4k context on machines with less than 24 GiB of VRAM [docs:https://docs.ollama.com/context-length]. Its chat path silently drops older messages that do not fit [source:ollama/ollama@v0.40.6:server/prompt.go]. Claude Code assumes a 200k window for unknown model IDs unless `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is set [local-run; docs:https://code.claude.com/docs/en/env-vars].
5. **On 32–48 GB, local becomes credible for small phases.** Candidates: Qwen3.6-35B-A3B (vendor SWE-bench Verified 73.4), Qwen3.8-27B (evaluated by Qwen inside the Claude Code harness), Poolside Laguna XS 2.1 (33B-A3B, vendor 70.9) and Meta Muse Glimmer-30B (vendor 76.0). On **64–128 GB Max-class Macs**, the same models run at Q8, or Qwen3.5-122B-A10B / gpt-oss-120b, with roughly 4–8× this M4's prefill. Vendor numbers run 10–35 points above independent single-scaffold runs (Devstral Small 2: vendor 68.0 vs 56.4 on the SWE-bench leaderboard) [source:SWE-bench/swe-bench.github.io@master:data/leaderboards.json].
6. **Recommendation.** Build "local" as an *endpoint profile* of the generic adapter (it is the same `ANTHROPIC_BASE_URL` / OpenAI-compatible mechanism as the DeepSeek, MiniMax and Qwen API profiles). Gate it as opt-in, with a hardware/context doctor, and route it only to trivial phases or **advisory** (non-blocking) roles. Never use it for SECURITY/DATA_LOSS phases, planning or blocking review.

---

## 1. Machine facts (this Mac)

| Fact | Value | Evidence |
|---|---|---|
| Chip, GPU | Apple M4, 10 GPU cores, 4P+6E CPU, Metal 4 | [local-run] `system_profiler`, `sysctl` |
| RAM | 17,179,869,184 B (16 GiB) | [local-run] |
| Metal `recommendedMaxWorkingSetSize` | **12,124 MiB** (~74% of RAM); `iogpu.wired_limit_mb = 0` (system default) | [local-run] Swift `MTLCreateSystemDefaultDevice()` |
| Memory state with Claude Desktop + Claude Code running, no model | swap 3,470.88 MB used of 4,096 MB; compressor stores 1,291,142 pages (~19.7 GiB) in ~6.6 GiB; wired 3.0 GiB; `memory_pressure` reports 37% free | [local-run] `vm_stat`, `sysctl vm.swapusage`, `memory_pressure` |
| Resident memory of Claude/Codex processes | Claude Code binaries ~0.78 GB (4 procs), `claude` CLI ~0.38 GB, Claude Desktop helpers ~0.76 GB, codex ~0.19 GB | [local-run] `ps` |
| Memory bandwidth, M4 base | 120 GB/s | [third-party:https://github.com/ggml-org/llama.cpp/discussions/4167] |
| Local inference servers installed | none (`ollama`, `lms`, `llama-server`, `mlx_lm.server`, `vllm`, `litellm`, `ccr` not on PATH) | [local-run] |

A GPU-resident model is wired memory: it cannot be compressed or swapped. On this machine, every GiB a model takes comes straight out of what the orchestrating Claude session already competes for [inference from the local-run figures above].

## 2. Local servers: API surfaces and operational traits

| Server (version, date) | Anthropic `/v1/messages` | OpenAI chat | OpenAI `/v1/responses` | Tool calling | Context default / config | Concurrency | Health / warm-up |
|---|---|---|---|---|---|---|---|
| **Ollama** v0.40.6 (2026-10-16) [source:gh releases] | Yes (since v0.14, Jan 2026 [third-party:https://dev.classmethod.jp/en/articles/claude-code-ollama-local/]). No `tool_choice`, `metadata`, `count_tokens` or `cache_control`; errors arrive as HTTP status, not stream events [docs:https://docs.ollama.com/api/anthropic-compatibility] | Yes; no `tool_choice` | Yes, **stateless only** (no `previous_response_id`), since v0.13.3 [docs:https://docs.ollama.com/api/openai-compatibility] | Per-family parsers: qwen35, qwen3coder, gemma4, glm47, ministral, nemotron3nano, deepseek3, laguna, glimmer, … [source:ollama/ollama@v0.40.6:model/parsers/] | **4k if VRAM < 24 GiB**, 32k for 24–48 GiB, 256k for ≥ 48 GiB. Set with `OLLAMA_CONTEXT_LENGTH` (server-wide) or a Modelfile `num_ctx`. The OpenAI API cannot set it per request [docs:https://docs.ollama.com/context-length; docs:https://docs.ollama.com/api/openai-compatibility] | `OLLAMA_NUM_PARALLEL` default 1; memory scales with parallel × ctx; queue 512 [docs:https://docs.ollama.com/faq; source:ollama/ollama@v0.40.6:envconfig/config.go] | `keep_alive` default 5 min, then unload; preload with an empty request; `-1` keeps it loaded; `OLLAMA_LOAD_TIMEOUT` default 5 min [docs:https://docs.ollama.com/faq; source:…/envconfig/config.go] |
| **LM Studio** (0.4.x; Bionic agent app 1.1.8, 2026-10-12) | Yes since 0.4.1 (2026-01-30); accepts `x-api-key` or Bearer [docs:https://lmstudio.ai/docs/developer/api-changelog; docs:https://lmstudio.ai/docs/integrations/claude-code] | Yes | Yes since 0.3.29 (2025-10-06), **stateful** via `previous_response_id` [docs:https://lmstudio.ai/docs/developer/api-changelog] | `tool_choice` since 0.3.15; tool-arg streaming [same] | `lms load --context-length N`; `--estimate-only` prints a memory estimate; `--ttl` auto-unload [docs:https://lmstudio.ai/docs/cli/local-models/load]. Default context on JIT load: [unverified] | 0.4.0: continuous batching, up to 4 concurrent by default (llama.cpp engine); MLX engine later [docs:https://lmstudio.ai/blog/0.4.0 (search summary)] | `llmster` headless daemon: `lms daemon up`, `lms server start` [docs:https://lmstudio.ai/docs/developer] |
| **llama.cpp `llama-server`** b11753 (2026-10-20) | Yes, plus `/v1/messages/count_tokens`; tools need `--jinja` (now on by default) [source:ggml-org/llama.cpp@b11753:tools/server/README.md] | Yes | Yes; "works by converting Responses request into Chat Completions" (stateless) [same] | Jinja chat templates; may need `--chat-template-file` [same] | `-c 0` = the model's trained context (262,144 for Qwen3.5/3.6). `--fit on` (default) shrinks unset args to fit memory, down to a minimum ctx of 4096 [same] | `-np -1` (auto) = **4 slots with a unified KV pool** [source:…@b11753:tools/server/server.cpp:169-174] | `GET /health` returns **503 "Loading model"** until ready, then 200; `GET /props` reports `n_ctx`, `total_slots`, `is_sleeping`; `--sleep-idle-seconds`; router mode loads and unloads models via `/models/load` [source:…/README.md] |
| **mlx-lm `mlx_lm.server`** v0.32.2 (2026-10-16) | **No** | Yes (`/v1/chat/completions`, `/v1/completions`) | **No** | Parsers: qwen3_coder, glm47, gemma4, minimax_m2, kimi_k2/k3, mistral, laguna, … [source:ml-explore/mlx-lm@v0.32.2:mlx_lm/server.py; …/tool_parsers/] | Model max; `--kv-bits` quantized KV disables batching [source:…/SERVER.md] | BatchGenerator; LRU prompt cache with nearest-prefix reuse [source:…/server.py] | "not recommended for production" [source:…/SERVER.md] |
| **vLLM** v0.32.0 (2026-10-18) / **vllm-metal** (v0.28.0 first release, 2026-09-22) [corrected 2026-10-20: the blog post of 2026-09-22 calls v0.28.0 the "first official release". The GitHub release is dated 2026-09-01 and earlier v0.1.0/v0.2.0 tags exist. The latest is v0.31.0 (2026-10-13)] | Upstream vLLM: yes (`vllm/entrypoints/anthropic`, `/v1/messages`, `/count_tokens`) [source:vllm-project/vllm@v0.32.0:vllm/entrypoints/anthropic/api_router.py]. The vllm-metal post names only `/v1/chat/completions` [docs:https://vllm.ai/blog/2026-09-22-vllm-metal-v0-28-0] | Yes | Yes (upstream) | `--tool-call-parser qwen3_coder` etc. | `--max-model-len` | Real continuous batching. vllm-metal used `--gpu-memory-utilization 0.7` on 64 GB; benchmarked on M5 Pro 64 GB [docs:same blog] | Warm-up pass, then a fixed KV pool [docs:same] |
| **LiteLLM proxy** v1.106.0 | Unified `/v1/messages` over "all LiteLLM supported providers" [docs:https://docs.litellm.ai/docs/anthropic_unified] | Yes | Passthrough exists | Translated | n/a | n/a | Extra hop; useful only to put Claude Code in front of an OpenAI-only server such as mlx-lm |
| **claude-code-router** v3.1.3 (2026-10-09) | Gateway on `127.0.0.1:3456`; translates OpenAI Chat/Responses ↔ Anthropic Messages ↔ Gemini; agent profiles for Claude Code, Codex, OpenCode, Pi, ZCode, … [source:musistudio/claude-code-router@v3.1.3:README.md] | | | | | | Also advertises "local login import" and "credential pools", which conflict with this plugin's provider-terms rules (see §10) |

**Ollama on Apple Silicon now has an MLX engine** (preview in 0.19, 2026-03-30). Ollama reported 1,810 tok/s prefill and 112 tok/s decode for Qwen3.5-35B-A3B; the chip is not named and M5 chips are emphasized. The preview needed "more than 32GB of unified memory" [docs:https://ollama.com/blog/mlx]. In v0.40.6, MLX models skip the chat-history truncation path (`if m.IsMLX() { truncate = false }`) [source:ollama/ollama@v0.40.6:server/routes.go:3244-3247].

**`ollama launch`** (v0.15+) configures and starts Claude Code, Codex, OpenCode, Pi, Droid, Cline, Copilot, Hermes, Kimi, Qwen, OpenClaw, Poolside and **DeepSeek Harness (`dsh`, npm `@deepseek-ai/dsh`)** [source:ollama/ollama@v0.40.6:cmd/launch/]. For Claude Code it sets:
- `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY=""` and `ANTHROPIC_AUTH_TOKEN=ollama`;
- `ENABLE_CLAUDEAI_MCP_SERVERS=false` and `CLAUDE_CODE_ATTRIBUTION_HEADER=0`;
- all model tiers plus `CLAUDE_CODE_SUBAGENT_MODEL` to the chosen model.

It sets `CLAUDE_CODE_MAX_CONTEXT_TOKENS` **only for cloud models**, not local ones [source:…/cmd/launch/claude.go:69-77,171-190]. `--yes` auto-pulls a missing model, and the launcher can install Claude Code via `curl … | bash` [source:…/cmd/launch/launch.go:91-93,405; …/claude.go:161-165]. Headless form: `ollama launch claude --model X --yes -- -p "…"` [docs:https://docs.ollama.com/integrations/claude-code]. An adapter should **not** shell out to `ollama launch --yes`: downloads and installs need user consent. It should set the same variables itself.

## 3. Harness ↔ local-server compatibility

| Harness | Wire protocol it needs | Local route | Notes |
|---|---|---|---|
| Claude Code 2.1.302 (`claude -p`) | Anthropic Messages | `ANTHROPIC_BASE_URL` → Ollama `:11434`, LM Studio `:1234`, llama-server `:9931` [corrected 2026-10-20: the default port is 9931 since llama.cpp PR #30159 (2026-10-09); README@b11753 "`--port PORT` … (default: 9931)", common.h `port = 9931`], vLLM; or LiteLLM/CCR in front of mlx-lm | Unknown model ID → warning "assumes a context window of 200k tokens" and default `max_tokens` 32000 [local-run]. Background tasks use `ANTHROPIC_DEFAULT_HAIKU_MODEL` [docs:https://code.claude.com/docs/en/env-vars], so every tier must point at a model the server knows. Qwen evaluates Qwen3.8 SWE-bench Pro/DeepSWE "with the Claude Code harness" [docs:https://huggingface.co/Qwen/Qwen3.8-27B] |
| Codex CLI 0.163.0 | OpenAI **Responses** only: `wire_api = "chat"` is "no longer supported" [source:openai/codex@rust-v0.163.0:codex-rs/model-provider-info/src/lib.rs:100,130] | `codex exec --oss --local-provider ollama\|lmstudio` [local-run `codex exec --help`]; built-in OSS providers use ports 11434 and 1234 with `WireApi::Responses` [source:…/lib.rs:653-686]; or a custom `model_providers.X` for llama-server | Default OSS model `gpt-oss:20b` / `openai/gpt-oss-20b` [source:openai/codex@main:codex-rs/ollama/src/lib.rs; …/lmstudio/src/lib.rs]. Provider `stream_idle_timeout_ms` defaults to 300,000 [source:…/lib.rs:66]. Unknown model → "Model metadata … not found. Defaulting to fallback metadata" [local-run] |
| OpenCode | OpenAI chat via `@ai-sdk/openai-compatible` | `baseURL` `…:11434/v1`, `…:1234/v1`, `…:9931/v1` [corrected 2026-10-20: llama-server default port at b11753 is 9931, not 8080]; set `limit.context/output` | The docs advise raising Ollama `num_ctx` to 16k–32k "if tool calls fail" [docs:https://opencode.ai/docs/providers/] |
| pi (`@earendil-works/pi-coding-agent`) | OpenAI chat (`api: "openai-completions"`) via `~/.pi/agent/models.json` | `baseUrl`; `contextWindow` default 128000, which must be lowered to the real server ctx; `compat.supportsDeveloperRole:false` for Ollama/vLLM; `maxTokensField` | Keyless servers still need a dummy key [docs:https://app.unpkg.com/@earendil-works/pi-coding-agent@0.83.0/files/docs/models.md] |
| DeepSeek Harness (DSH) | Ollama provider | `ollama launch dsh` | Only the Ollama integration file was inspected [source:ollama/ollama@v0.40.6:cmd/launch/deepseek_harness.go]; DSH itself is out of scope here |

## 4. What the harnesses actually send (measured against a local capture-only mock)

Method: a Python server on `127.0.0.1` recorded request bodies (never headers) and answered HTTP 400. It ran with an empty temp `CLAUDE_CONFIG_DIR`/`CODEX_HOME`, an empty git repo as cwd, and the prompt "Reply with the word ok." No remote model endpoint was called [local-run].

| Invocation | Request bytes | System prompt | Tools | Messages | Other fields sent |
|---|---|---|---|---|---|
| `claude -p` (default) | **66,034** [unverified by fact-check: not re-run] | 3 blocks, 6,087 chars; block 0 = `x-anthropic-billing-header: cc_version=2.1.302.<fingerprint>; …` | **20 tools, 48,860 chars JSON** (largest: SendMessage 5.8 KB, Workflow 5.5 KB, ScheduleWakeup 5.0 KB) | 11,519 chars | `thinking:{type:adaptive}`, `output_config:{effort:high}`, `context_management`, `metadata`, `max_tokens:32000`, `stream:true` |
| `claude -p` with a different prompt | 66,051 | fingerprint changed `…2fe` → `…8bf` | same | | |
| `claude -p`, `CLAUDE_CODE_ATTRIBUTION_HEADER=0` | 65,944 | 2 blocks: the billing block is gone | same | | |
| `claude --bare -p` | **4,395** | 3 blocks, 334 chars (identity, CWD, date); billing block still present | **3 tools: Bash, Edit, Read** (3,488 chars) | 124 chars | same Anthropic-specific fields |
| `claude --bare --tools "Bash,Read,Edit,Write,Glob,Grep" -p`, attribution off, `CLAUDE_CODE_MAX_CONTEXT_TOKENS=65536` | **4,288** | 2 blocks, 253 chars | still only Bash, Edit, Read | 124 chars | the 200k-window warning disappears |
| `codex exec` (custom Responses provider) | **42,332** | developer text inside `input` | 9 tools (exec_command, write_stdin, multi_agent_v1, web_search, …), 17,767 chars | `input` 23,677 chars | `store:false`, `include:[reasoning.encrypted_content]`, `prompt_cache_key`, `parallel_tool_calls:true` |

All rows [local-run]. The tool set in the default row partly reflects feature flags inherited from this session's environment; a user's dispatch would add its own MCP tools, skills listing and CLAUDE.md on top [inference].

Consequences:
- **Prefill budget.** At ~3.5–4 bytes/token [estimate], default Claude Code costs ~16–19k tokens before the task, and `--bare` costs ~1.1k. Our dispatch prompts (20–120 KB) add ~5–34k tokens. First-turn prefill is therefore ~21–53k tokens by default, or ~6–35k with `--bare` [derived].
- **Prefix-cache killer (across dispatches only).** The attribution block sits at the very start of the system prompt. Its fingerprint differs between conversations, but it is stable for every turn of one conversation [corrected 2026-10-20: Claude Code docs, llm-gateway-protocol "System prompt attribution block": "From Claude Code v2.1.181, the block is stable for the lifetime of a conversation when requests route through a custom base URL". A fact-check stub run on 2.1.302 confirmed it: turn 1 and a `--continue` turn 2 both carried `cc_version=2.1.302.2fe`, while a new conversation carried `…28b`]. So it does not force re-prefill on every turn. It does stop separate `claude -p` dispatches from reusing the shared system-plus-tools prefix. Claude Code's docs say it carries "the client version and a prompt fingerprint" and that `0` omits it [docs:https://code.claude.com/docs/en/env-vars]. LM Studio's and Ollama's Claude Code setups both set `CLAUDE_CODE_ATTRIBUTION_HEADER=0` [docs:https://lmstudio.ai/docs/integrations/claude-code; source:ollama/ollama@v0.40.6:cmd/launch/claude.go:73]. Third-party reports blame it for re-prefill on every turn with llama.cpp [third-party:https://www.roborhythms.com/stop-claude-code-slowing-local-llm/]. [corrected 2026-10-20: that article is dated 2026-04-23, before v2.1.181 (npm, 2026-06-17). It describes the old per-request token, not 2.1.302 behaviour.] `--bare` does **not** remove it [local-run].
- **`--bare` caveats.** It skips hooks, plugins, CLAUDE.md, keychain and OAuth. Auth must come from `ANTHROPIC_API_KEY` or `apiKeyHelper` [local-run `claude --help`], which is fine for a local server with a dummy key. The toolset shrinks to Bash/Edit/Read, and `--tools` did not add Write/Glob/Grep in bare mode [local-run]. The plugin's implementer instructions would have to travel in the prompt or `--append-system-prompt-file`.

## 5. Timeouts and watchdogs (long local prefill vs harness deadlines)

| Component | Behaviour | Evidence |
|---|---|---|
| Claude Code → custom `ANTHROPIC_BASE_URL` | Byte-level watchdog **300 s** with no bytes on the wire; event-level watchdog 300 s; "body idle timeout" 5 min counting the wait for headers on non-direct providers; the first-byte deadline does **not** run for a gateway base URL. Tunables: `CLAUDE_STREAM_IDLE_TIMEOUT_MS` (min 5 min, byte watchdog capped at 30 min), `CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS`, `API_FORCE_IDLE_TIMEOUT=0`, `API_TIMEOUT_MS` (default 600,000) | [docs:https://code.claude.com/docs/en/network-config; docs:https://code.claude.com/docs/en/env-vars] |
| llama-server streaming | Waits for the first slot result (`rd.next`) before sending HTTP headers, so that an early error can become a non-stream error. When a slot starts processing the prompt, it emits an `is_begin` result, so headers go out at prefill **start**. SSE comment pings (`--sse-ping-interval`, default 30 s) then run during prefill. The first SSE event arrives with the first token. Headers are delayed only while the request waits for a free slot [corrected 2026-10-20: server-context.cpp:3924-3932 at b11753 says "signal HTTP to send the headers (i.e. 200 status)"; the README describes `sse_ping_interval` as "keeping the connection observable during long prompt processing"; the begin/ping behaviour arrived in PR #25241 (2026-07-03)]. HTTP read/write timeout defaults to 3600 s | [source:ggml-org/llama.cpp@b11753:tools/server/server-context.cpp:5005-5040; common/common.h:632-634; common/arg.cpp:3593-3606] |
| Ollama Anthropic streaming | Sets SSE headers, then writes `message_start`; whether bytes reach the wire before prefill ends: [unverified] | [source:ollama/ollama@v0.40.6:middleware/anthropic.go:561-575,810-814] |
| Codex | `stream_idle_timeout_ms` default 300,000 per provider | [source:openai/codex@rust-v0.163.0:codex-rs/model-provider-info/src/lib.rs:66,513-516] |

Implication: on an M4, a default-Claude-Code dispatch with a 120 KB prompt (~53k tokens) at ≤220 tok/s needs ≥4 min of silent prefill. Prefill throughput also falls as context grows. The harness can therefore abort at 300 s and retry, re-sending the whole prompt [derived]. [corrected 2026-10-20: against llama-server the 30 s pings keep the byte-level watchdog alive. The event-level watchdog still fires once pings stop extending it, about five minutes without a parsed event per the Claude Code network-config docs. The risk starts at roughly 5–10 min of prefill, not 300 s. Against an unknown server, the 300 s figure stands.] A local adapter must raise these watchdogs (for example `CLAUDE_STREAM_IDLE_TIMEOUT_MS=1800000`, `API_FORCE_IDLE_TIMEOUT=0`) and use `--bare`.

## 6. Context length: where it silently goes wrong

| Layer | Pitfall | Evidence |
|---|---|---|
| Ollama server | On this Mac (GPU working set 11.8 GiB < 24 GiB) the default context is **4k**. Claude Code's default request alone is ~16–19k tokens | [docs:https://docs.ollama.com/context-length; local-run] |
| Ollama chat truncation | `truncate` defaults to true (`req.Truncate == nil`). `chatPrompt` drops the oldest non-system messages until the prompt fits and logs only at **Debug** level. If the system prompt plus the last message still exceed `NumCtx`, the runner returns HTTP 400 "the prompt is longer than the context length…", unless context shift is enabled, in which case it token-truncates with a Warn | [source:ollama/ollama@v0.40.6:server/routes.go:3244; server/prompt.go:21-92; llm/llama_server.go:299-336,2630] |
| llama-server | `-c 0` means the trained context, but `--fit on` (default) silently lowers unset parameters to fit memory, down to 4096. Read the real value from `GET /props` (`n_ctx`), divided across `total_slots` (4 by default, unified KV) | [source:ggml-org/llama.cpp@b11753:tools/server/README.md; server.cpp:169-174] |
| Claude Code | Unknown model ID → assumes 200k and compacts too late. `CLAUDE_CODE_MAX_CONTEXT_TOKENS` overrides it. `CLAUDE_CODE_AUTO_COMPACT_WINDOW` accepts only 100,000–1,000,000 | [local-run warning text; docs:https://code.claude.com/docs/en/env-vars] |
| pi / OpenCode | pi `contextWindow` defaults to 128,000; OpenCode `limit` is optional | [docs:pi models.md; docs:https://opencode.ai/docs/providers/] |
| Model guidance | Qwen3.5/3.6 cards advise "at least 128K tokens to preserve thinking capabilities"; Ollama advises ≥ 64k for coding tools; LM Studio advises > ~25k | [docs:https://huggingface.co/Qwen/Qwen3.6-35B-A3B; docs:https://docs.ollama.com/context-length; docs:https://lmstudio.ai/docs/integrations/claude-code] |

**KV-cache cost per token (f16, K+V)**, computed from each model's `config.json` [derived from docs:https://huggingface.co/<model>/raw/main/config.json]:

| Model | Attention layout | KV per token | At 64k ctx |
|---|---|---|---|
| Qwen3.5-9B | 8 full-attention of 32 layers (rest Gated DeltaNet), 4 KV heads × 256 | 32 KiB | 2.0 GiB |
| Qwen3.6-35B-A3B | 10 full of 40, 2 KV heads × 256 | 20 KiB | 1.25 GiB |
| Qwen3.8-27B | 16 full of 64, 4 KV heads × 256 | 64 KiB | 4.0 GiB |
| Gemma 4 12B | 8 global (1 KV head × 512) + 40 sliding (window 1024) | 16 KiB + ~320 MiB fixed | ~1.3 GiB |
| gpt-oss-20b | 12 full (8 KV × 64) + 12 sliding (window 128) | 24 KiB | 1.5 GiB |
| Devstral Small 2 (24B) | 40 full, 8 KV × 128 | 160 KiB | **10 GiB** |
| GLM-4.7-Flash (MLA) | 47 layers × (512+64) latent | ~54 KB | ~3.3 GiB (if the server stores the latent cache) |

Hybrid and sliding-window models (Qwen3.5/3.6/3.8, Gemma 4, gpt-oss) are cheap in KV but **harder to prefix-cache** in llama.cpp. Recurrent state is restored only from context checkpoints (`--ctx-checkpoints`, default 32 per slot) [source:…/README.md]. One user log reports KV reuse rejected for a hybrid model even with the attribution header off [third-party:https://deepseek.csdn.net/6a31fc5b10ee7a33f27e3b2b.html].

## 7. Models (October 2026) by memory tier

Sizes are GGUF files listed on Hugging Face [docs:https://huggingface.co/api/models/<repo>/tree/main]. Benchmarks are **vendor-reported** from each model card unless marked otherwise. "Fit" assumes a GPU working set of ~74% of RAM (measured here for 16 GB, assumed for the other tiers), a 64k context and f16 KV [derived].

| Model (release, license) | Total / active | Quant size | Vendor agentic-coding numbers | 16 GB M4 | 32 GB | 64 GB | 128 GB |
|---|---|---|---|---|---|---|---|
| Qwen3.5-9B (2026-02-27, Apache-2.0) | 9.65B dense (hybrid attn) | Q4_K_M 5.7 GB | none for SWE; BFCL-V4 66.1, TAU2 79.1 [docs:https://huggingface.co/Qwen/Qwen3.5-9B] | **fits** (~7.5 GiB) | ✓ | ✓ | ✓ |
| Gemma 4 12B (2026-05-23, Apache-2.0) | 12.0B dense | Q4_K_M 7.1 GB | LiveCodeBench v6 72.0, Tau2 69.0; no SWE [docs:https://huggingface.co/google/gemma-4-12B-it] | **fits** (~8 GiB) | ✓ | ✓ | ✓ |
| gpt-oss-20b (2025-08, Apache-2.0) | 21B / 3.6B, MXFP4, harmony format | 12.1 GB | Z.ai's table: SWE-bench Verified 34.0 [docs:https://huggingface.co/zai-org/GLM-4.7-Flash] | **does not fit** (11.3 GiB weights + 1.5 GiB KV > 11.8 GiB) | ✓ | ✓ | ✓ |
| Qwen3.6-35B-A3B (2026-04-15, Apache-2.0) | 36B / 3B | UD-Q4_K_M 22.1 GB; UD-IQ4_XS 17.7 GB; UD-IQ2_M 11.5 GB | SWE-bench Verified **73.4**, SWE-Pro 49.5, Terminal-Bench 2.0 51.5 [docs:https://huggingface.co/Qwen/Qwen3.6-35B-A3B] | no | tight at Q4_K_M; ✓ at IQ4_XS | ✓ (Q8) | ✓ |
| Qwen3.6-27B (2026-04-21, Apache-2.0) | 27.8B dense | Q4_K_M 16.8 GB | SWE-V **77.2**, TB2.0 59.3 [docs:https://huggingface.co/Qwen/Qwen3.6-27B] | no | ✓ (~20 GiB) | ✓ | ✓ |
| Qwen3.8-27B (2026-08-05, Apache-2.0) | 27.8B dense | UD-Q4_K_M 16.5 GB | SWE-Pro **61.7** (Claude Code harness, 256K ctx) and TB2.1 73.0 [corrected 2026-10-20: the card labels the TB2.1 row "Terminal Bench 2.1 (Terminus)". Only SWE-bench Pro, DeepSWE, NL2Repo and QwenSWEBench are stated as run in the Claude Code harness] [docs:https://huggingface.co/Qwen/Qwen3.8-27B] | no | ✓ (~19.5 GiB) | ✓ | ✓ |
| Muse Glimmer-30B (Meta, 2026-08-09, Apache-2.0) | 29.6B dense (incl. vision) | Q4_K_M 16.8 GB [corrected 2026-10-20: huggingface.co/api/models/meta-models/Muse-Glimmer-30B-GGUF/tree/main lists `Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf` at 16.76 GB; unsloth UD-Q4_K_XL is 15.9 GB] | SWE-V 76.0, SWE-Pro 51.2, TB2.1 51.7 (TB2.1 "with terminus2") [docs:https://huggingface.co/meta-models/Muse-Glimmer-30B] | no | likely ✓ at Q4 (16.8 GB weights; per its card, 13 of 52 layers are global with 2 KV heads × 128, so about 0.8 GiB KV at 64k) [derived by fact-check] | ✓ | ✓ |
| Laguna XS 2.1 (Poolside, 2026-06-20, OpenMDW-1.1) | 33B / 3B | Q4_K_M 20.3 GB [corrected 2026-10-20: the official poolside/Laguna-XS-2.1-GGUF repo lists `Laguna-XS-2.1-Q4_K_M.gguf` at 20.27 GB] | SWE-V 70.9, TB2.0 37.5 (own harness); "run on a Mac with 36 GB" [docs:https://huggingface.co/poolside/Laguna-XS-2.1]. The card also warns that `ollama run` "may currently return empty output on Apple Silicon" because of a Metal f16 overflow. The card names the fix as llama.cpp#25389, which GitHub shows closed without merge, so whether the bug is fixed is unknown [fact-check note] | no | tight | ✓ | ✓ |
| Devstral Small 2 (2025-12, Apache-2.0) | 24B dense | Q4_K_M 14.3 GB | vendor SWE-V 68.0; **independent mini-SWE-agent 56.4** [docs:https://huggingface.co/mistralai/Devstral-Small-2-24B-Instruct-2512; source:SWE-bench/swe-bench.github.io@master:data/leaderboards.json] | no | tight (10 GiB KV at 64k; use q8 KV) | ✓ | ✓ |
| GLM-4.7-Flash (2026-01-19, MIT) | 31B / ~3B (MLA) | Q4_K_M 18.3 GB | SWE-V 59.2 [docs:https://huggingface.co/zai-org/GLM-4.7-Flash] | no | ✓ | ✓ | ✓ |
| Nemotron 3.5 Bolt 74B-A9B "24GB" (NVIDIA, 2026-10, OpenMDW-1.1) | 74B / 9B, native 2-bit | GGUF 22.0 GB | TB2.1 50.98 (24GB variant) vs 44.38 for Qwen3.6-35B-A3B, NVIDIA's table [docs:https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-BF16] | no | tight | ✓ | ✓ |
| Qwen3-Coder-Next (2026-01-30, Apache-2.0) | 80B / 3B | Q4_K_M 48.4 GB | charts only on the card | no | no | tight | ✓ |
| gpt-oss-120b (Apache-2.0) | 117B / 5.1B | MXFP4 63.4 GB | independent mini-SWE-agent 26.0 (2025-08-07) [source:SWE-bench leaderboard data] | no | no | no | ✓ |
| Qwen3.5-122B-A10B (2026-02-24, Apache-2.0) | 125B / 10B | Q4_K_M 76.5 GB; UD-IQ4_XS 60.2 GB | SWE-V 72.0, TB2 49.4 [docs:https://huggingface.co/Qwen/Qwen3.5-122B-A10B] | no | no | no | ✓ |
| Mistral Small 4 119B-2603 (Apache-2.0) | 119B / 6.5B | UD-Q4_K_M 73.8 GB | LiveCodeBench claims only | no | no | no | ✓ |
| MiniMax-M2.7 (2026-04-09, custom license) | 229B / ~10B [unverified active] | UD-Q3_K_M 101 GB; UD-IQ4_XS 108 GB | M2.5: independent 75.8 (mini-SWE-agent) | no | no | no | only with a raised wired limit and small ctx |

Not local-class: **GLM-5.3-Flash** is "320B total parameters and just 18B active" [docs:https://huggingface.co/zai-org/GLM-5.3-Flash], so the model the plugin already uses through Z.ai cannot be replicated locally below ~256 GB. Qwen3.8-Flash-Next is 180B total (125B MoE + 51B n-gram embedding + 4B MTP; 6B activated) [docs:https://huggingface.co/Qwen/Qwen3.8-Flash-Next].

**Vendor numbers vs independent ones.** On the SWE-bench Verified leaderboard (bash-only mini-SWE-agent, one attempt):
- Devstral Small 2512: 56.4, against Mistral's own 68.0.
- gpt-oss-120b: 26.0, against Qwen's 62.0 for it in a different scaffold.
- MiniMax M2.5: 75.8 [source:SWE-bench/swe-bench.github.io@master:data/leaderboards.json, last commit 2026-09-01].

Small models are especially scaffold-sensitive. No independent single-scaffold result exists for Qwen3.5-9B or Gemma 4 12B [inference from the data].

## 8. Speed on an M4 and on bigger Macs

| Measurement | PP (prefill) tok/s | TG (decode) tok/s | Evidence |
|---|---|---|---|
| Llama-2 7B Q4_0, llama.cpp, **M4 10-core** | 221 | 24.1 | [third-party:https://github.com/ggml-org/llama.cpp/discussions/4167] |
| same, M4 Pro 20-core / M4 Max 40-core | 440 / 886 | 50.7 / 83.1 | [same] |
| **Qwen3.5-9B 4-bit, oMLX v0.2.6, M4 16 GB** | 223 (1k) / 221 (4k) | 20.4 / 20.2 | [third-party:https://omlx.ai/benchmarks/nw2dhnfb; …/k9z96zfi] |
| gpt-oss-20b 8-bit, oMLX, M4 32 GB | 277 (1k) / 309 (4k) | 23.5 / 22.4 | [third-party:https://omlx.ai/benchmarks/dfpevyi1] |
| Qwen3.5-35B-A3B, Ollama 0.19 MLX (chip unstated, M5-oriented) | 1,810 | 112 | [docs:https://ollama.com/blog/mlx] |

What this means for our dispatch sizes on this M4 [derived; PP measured only at ≤4k and expected to fall at longer contexts]:

| Harness mode | First-turn tokens | Prefill at ~220 tok/s |
|---|---|---|
| default `claude -p` + 20 KB prompt | ~21k | ~1.6 min |
| default `claude -p` + 120 KB prompt | ~53k | ~4.0 min (watchdog risk) |
| `claude --bare` + 20 KB prompt | ~6k | ~0.5 min |
| `claude --bare` + 120 KB prompt | ~35k | ~2.7 min |

After the first turn, each tool round adds tool output (typically 1–5k tokens, ~5–25 s of prefill if the prefix cache holds) plus 200–1,000 output tokens at ~20 tok/s (10–50 s). A 40-turn implementer phase is therefore ~20–50 min on this machine, against minutes on a cloud channel [derived estimate]. On an M4 Max, both rates are ~4× higher [derived from the 7B table].

## 9. Which pipeline roles a local model can fill

| Role | 16 GB M4 (this machine) | 32–48 GB (M4 Pro / M-Max) | 64–128 GB (Max/Ultra) |
|---|---|---|---|
| Default implementer (replace GLM in the ladder) | **No** | No | No: keep cloud channels as default |
| Implementer for trivial, well-specified phases (docs, config, renames, one-file edits with given tests) | Opt-in experiment only (Qwen3.5-9B / Gemma 4 12B); expect slowness and malformed results | **Yes, opt-in** (Qwen3.6-35B-A3B IQ4_XS, Qwen3.8-27B Q4, Laguna XS 2.1) | Yes (same models at Q8; Qwen3.5-122B-A10B / gpt-oss-120b) |
| SECURITY/DATA_LOSS phases, reasoning escalation | No | No | No |
| Offline or quota-exhausted fallback (end of the ladder) | Last resort, small phases only | Reasonable | Reasonable |
| Blocking reviewer | No | No | No (Opus stays) |
| Advisory second reviewer from another family (non-blocking findings) | No (too slow for 20–120 KB packages) | Possible | Possible |
| Verification-gate summarizer (condense test logs) | Possible but **non-authoritative**: exit codes and raw output remain the evidence | Yes (advisory) | Yes (advisory) |
| Planner | No | No | No |

Family rule: a local model belongs to its *vendor* family (Qwen, Gemma, Mistral, Meta, NVIDIA, Poolside), not to a "local" family. A local GLM-4.7-Flash shares the GLM family with the Z.ai channel [inference from the plugin's family rule].

## 10. Failure modes and what a local adapter must handle

| # | Failure mode | Adapter handling |
|---|---|---|
| 1 | Server not running or still loading | Doctor/preflight: llama-server `GET /health` (503 while loading, 200 when ready); Ollama `/api/version` and `/api/ps`; LM Studio `/v1/models` or `lms ps` [source/docs above]. Map "connection refused" → `launch` and "still loading past deadline" → `timeout` |
| 2 | Model not loaded or unloaded after idle | Preload: Ollama `keep_alive:-1` or long; LM Studio `lms load --ttl`; llama-server stays resident unless `--sleep-idle-seconds` is set. Budget load time; Ollama's load-stall limit is 5 min [docs:https://docs.ollama.com/faq] |
| 3 | Context too small, or silent truncation | Read the real ctx: `/props` `n_ctx`/`total_slots`; `ollama ps` CONTEXT; `lms ps`. Refuse to launch (new errorClass `context`) if ctx < overhead + prompt + output headroom. Export `CLAUDE_CODE_MAX_CONTEXT_TOKENS=<ctx>` |
| 4 | Silent prefill longer than the harness watchdog | Prefer `claude --bare`; set `CLAUDE_STREAM_IDLE_TIMEOUT_MS` / `CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS` (≤ 30 min), `API_FORCE_IDLE_TIMEOUT=0`, a high `API_TIMEOUT_MS`; Codex `stream_idle_timeout_ms`. Scale the wrapper's wall-clock timeout (`*_TASK_TIMEOUT_MIN`) per profile |
| 5 | Prefix-cache invalidation | `CLAUDE_CODE_ATTRIBUTION_HEADER=0`; optionally `--exclude-dynamic-system-prompt-sections` (default system prompt only) [local-run `claude --help`]; llama-server `--cache-reuse`/checkpoints |
| 6 | Tool-call format errors and chat-template drift | Pin server-side parsers (Ollama per-family parsers; llama-server `--jinja` + a correct template; mlx-lm `tool_parsers`; vLLM `--tool-call-parser qwen3_coder`). Treat a missing line-1 status token or a harness exit without a final message as `malformed` → one fresh retry, then fall through the ladder |
| 7 | Unknown or Anthropic-only request fields (`thinking:adaptive`, `context_management`, `output_config`, `cache_control`, `tool_choice`) | Ollama ignores `tool_choice` and `cache_control` [docs]. Behaviour on other servers: [unverified]. Keep a per-server compatibility smoke test in `doctor --probe` (tiny prompt, one tool call) |
| 8 | Claude Code calls haiku/opus/subagent tiers by name | Set `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` and `CLAUDE_CODE_SUBAGENT_MODEL` to the local ID, as `ollama launch` does [source:ollama/ollama@v0.40.6:cmd/launch/claude.go:174-177] |
| 9 | User settings override shell env | Ollama warns that Claude settings can override exported variables [docs:https://docs.ollama.com/integrations/claude-code]. Use a dedicated `CLAUDE_CONFIG_DIR` and/or `--bare` / `--setting-sources`. This also keeps the user's Anthropic OAuth out of a local run |
| 10 | Memory pressure, swap, an OOM-killed server | Doctor reads `memory_pressure` and swap. Refuse or warn on 16 GB when free memory is below the model size plus KV. Treat a server crash as `crash`. Per-server concurrency semaphore (1 on 16 GB; = slots elsewhere), in addition to the per-workspace lock |
| 11 | Concurrent local jobs share one GPU | Ollama default `NUM_PARALLEL=1` queues; llama-server splits a unified KV across 4 slots by default. The adapter must serialize or size slots explicitly |
| 12 | Auto-download or auto-install side effects | Never call `ollama launch --yes` (auto-pull) or let a launcher run `curl … \| bash`. Downloads need explicit user consent |
| 13 | Exposure | Bind to `127.0.0.1`. Local servers accept any key (Ollama "does not validate API keys" [docs]), so the dummy token is not a credential and must never be a real one. Also reject `ANTHROPIC_BASE_URL` values that are not loopback for "local" profiles |
| 14 | Terms of service | Local inference has no provider ToS. Model licenses (Apache-2.0, MIT, OpenMDW-1.1, MiniMax custom) govern [docs: HF cardData]. CCR's "local login import / credential pools" features conflict with the plugin's no-token-extraction rule; do not depend on them |

### Minimal Claude Code environment for a local profile (no credentials involved)

```
ANTHROPIC_BASE_URL=http://127.0.0.1:<port>        # loopback only
ANTHROPIC_API_KEY=local-dummy                     # with --bare (bare reads only API key / apiKeyHelper)
ANTHROPIC_MODEL / ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL / CLAUDE_CODE_SUBAGENT_MODEL=<local id>
CLAUDE_CODE_MAX_CONTEXT_TOKENS=<server n_ctx per slot>
CLAUDE_CODE_ATTRIBUTION_HEADER=0
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
ENABLE_CLAUDEAI_MCP_SERVERS=false
CLAUDE_STREAM_IDLE_TIMEOUT_MS=1800000  API_FORCE_IDLE_TIMEOUT=0
claude --bare -p --model <local id> --append-system-prompt-file <implementer rules> < prompt.md
```

These are the variables verified in [docs:https://code.claude.com/docs/en/env-vars] and [source:ollama/ollama@v0.40.6:cmd/launch/claude.go]. The combination was exercised only against the capture mock [local-run], never against a real local model.

### Recommended server priority for the adapter

1. **llama-server**: one binary serves all three wire protocols, has an explicit loading state (`/health` 503), introspection (`/props`), idle sleep and router mode. Install is the user's job.
2. **Ollama**: the most common install; `ollama launch` shows the right env set. Requires `OLLAMA_CONTEXT_LENGTH` ≥ 64k and a check of `ollama ps`. Responses is stateless, which suits Codex (`store:false` was observed [local-run]).
3. **LM Studio**: all three protocols; stateful Responses; `lms load --context-length`.
4. **mlx-lm / vllm-metal**: OpenAI chat only (vllm-metal per its post), so they need LiteLLM or CCR in front for Claude Code and Codex. Defer.

## 11. Open questions

1. No end-to-end local measurement was possible: no server or model is installed, and installing was out of scope. Real numbers for Claude Code `--bare` + Qwen3.5-9B on this M4 (TTFT for a 20/120 KB prompt, turns per phase, malformed-tool-call rate, status-token compliance) are unknown.
2. Does Ollama (and LM Studio) send response headers or `message_start` before prefill finishes? [corrected 2026-10-20: llama-server is not silent. It sends headers at prefill start and SSE comment pings every 30 s, but no SSE event until the first token (see §5).] This decides whether the 300 s Claude Code watchdog fires on long prefills.
3. How effective is prefix-cache reuse across Claude Code turns for hybrid-attention models (Qwen3.5/3.6/3.8, Gemma 4) in llama.cpp, Ollama-MLX and mlx-lm?
4. Is `--bare`'s Bash/Edit/Read toolset sufficient for implementer phases? `--tools` did not add Write/Glob/Grep in bare mode. Is the non-bare default (66 KB) workable with `--tools` alone? (Not measured.)
5. How does each server treat Claude Code's `thinking:{type:"adaptive"}`, `output_config.effort` and `context_management`? Only Ollama's handling of `enabled`/`disabled` thinking was read.
6. GPU working-set fraction on 32/64/128 GB Macs: assumed ~74–75% from the 16 GB measurement; not verified.
7. Independent (single-scaffold) SWE-bench or Terminal-Bench results for Qwen3.6-35B-A3B, Qwen3.8-27B, Laguna XS 2.1 and Muse Glimmer-30B: none found in the leaderboard data (last commit 2026-09-01).
8. LM Studio's default context when a model is JIT-loaded by an API request: not documented on the pages read.

## Fact-check log (2026-10-20)

How the checks were done: the GitHub API was read at the cited tags (`gh api … ?ref=<tag>`), plus the Hugging Face model API, model cards and GGUF trees. Vendor docs were read through WebFetch. Two local runs were made: a Swift `MTLCreateSystemDefaultDevice()` probe, and a capture stub on 127.0.0.1. The stub run used `claude --bare` 2.1.302 with a fresh `CLAUDE_CONFIG_DIR` and `HOME` in scratch and a dummy API key. The stub was killed afterwards. Non-bare `claude -p` was not run, because it may read the keychain.

| Claim | Verdict | Evidence |
|---|---|---|
| Metal `recommendedMaxWorkingSetSize` 12,124 MiB, `iogpu.wired_limit_mb=0`, swap ~3.47 of 4 GB used | confirmed | Re-measured: 12,713,115,648 B = 12,124.17 MiB on Apple M4 with 10 GPU cores and Metal 4; `iogpu.wired_limit_mb: 0`; swap 3,462.88 MB used of 4,096 MB |
| `claude --bare -p` sends ~4.3 KB with only Bash/Edit/Read; `--tools` does not add Write/Glob/Grep; `CLAUDE_CODE_MAX_CONTEXT_TOKENS` removes the 200k warning; `max_tokens` 32000, `thinking:adaptive`, `output_config.effort:high` | confirmed | Stub run: 4,385 B, and 4,285 B with attribution off and `--tools "Bash,Read,Edit,Write,Glob,Grep"`. Tools stayed `['Bash','Edit','Read']` |
| Default `claude -p` sends 66,034 B with 20 tools | unverifiable | Not re-run (keychain risk in non-bare mode); researcher's local-run only |
| The attribution block's fingerprint varies per prompt and so breaks prefix caching unless `CLAUDE_CODE_ATTRIBUTION_HEADER=0`; `--bare` keeps it | corrected | The observations hold: the block is present in `--bare` and `=0` removes it. But the docs (llm-gateway-protocol) say that from v2.1.181 the block "is stable for the lifetime of a conversation" on custom base URLs. The stub run showed `…2fe` on turn 1 and on the `--continue` turn 2, and `…28b` on a new conversation. Only cross-dispatch prefix reuse is lost |
| Third-party report of re-prefill on every turn (roborhythms) | corrected | The article is dated 2026-04-23. Claude Code 2.1.181 was published 2026-06-17 (`npm view @anthropic-ai/claude-code time`) |
| Ollama default context 4k / 32k / 256k by VRAM; `OLLAMA_CONTEXT_LENGTH`; the OpenAI API cannot set `num_ctx` | confirmed | ollama@v0.40.6 `server/routes.go:2541-2550` (47/23 GiB thresholds → 262144/32768/4096); `docs/context-length.mdx`; `docs/api/openai-compatibility.mdx` "The OpenAI API does not have a way of setting the context size" |
| Ollama chat `truncate` defaults to true; `chatPrompt` drops the oldest non-system messages and logs at Debug; HTTP 400 or a Warn token-truncate in the runner; MLX skips truncation | confirmed | `server/routes.go:3244-3247`, `server/prompt.go:23-77`, `llm/llama_server.go:299-336,2630` |
| Ollama v0.40.6 serves `/v1/messages`, `/v1/chat/completions`, `/v1/responses` (stateless, since v0.13.3) | confirmed | `server/routes.go:2403,2408,2414`; the openai-compatibility doc says "Only the non-stateful flavor"; release v0.14.0 (2026-01-10) says "support for the `/v1/messages` API" |
| Ollama Anthropic gaps (no `tool_choice`, `metadata`, `count_tokens`, `cache_control`; errors as HTTP status; keys not validated) | confirmed | `docs/api/anthropic-compatibility.mdx` "Not supported" table and "Behavior differences" |
| Ollama defaults: `NUM_PARALLEL` 1, `MAX_QUEUE` 512, `KEEP_ALIVE` 5m, `LOAD_TIMEOUT` 5m | confirmed | `envconfig/config.go:277,281,325,327` |
| `ollama launch claude` env (BASE_URL, empty API_KEY, AUTH_TOKEN=ollama, attribution 0, all tiers and subagent); MAX_CONTEXT_TOKENS only for cloud models; `--yes` auto-pulls; curl-pipe-bash installer | confirmed | `cmd/launch/claude.go:67-77,161-165,171-190`; `cmd/launch/launch.go:89-93,405`; `docs/integrations/claude-code.mdx:116-122,171` |
| `ollama launch dsh` installs npm `@deepseek-ai/dsh` | confirmed | `cmd/launch/deepseek_harness.go:20-21` |
| Ollama parsers include laguna and glimmer | confirmed | `model/parsers/` listing at v0.40.6 (`laguna.go`, `glimmer.go`, `qwen35.go`, `gemma4.go`, …) |
| Ollama MLX blog: 1,810 / 112 tok/s, chip not named, "more than 32GB" | confirmed | ollama.com/blog/mlx (2026-03-30; Qwen3.5-35B-A3B at NVFP4); release v0.19.0 published 2026-03-27 |
| llama-server b11753 serves `/v1/messages` (tools need `--jinja`, on by default), `count_tokens`, chat, and `/v1/responses` via conversion; `/health` returns 503 "Loading model" | confirmed | `tools/server/README.md@b11753` lines 234, 479-490, 1494-1534, 1630-1690 |
| llama-server sends no headers until the first token, and pings only after that, so long prefills are silent | refuted | `server-context.cpp@b11753:3924-3932` sends an `is_begin` partial at prefill start, "signal HTTP to send the headers (i.e. 200 status)"; `server-task.cpp:1020-1022`; the ping loop at 5087-5104 runs during prefill; PR #25241 (2026-07-03) |
| llama-server default port 8080 | corrected | 9931 since PR #30159 (2026-10-09); README@b11753 line 194; `common/common.h` `port = 9931` |
| llama-server `-np -1` = 4 slots with unified KV; `--fit` min ctx 4096; `--ctx-checkpoints` 32; timeout 3600 s; SSE ping 30 s | confirmed | `server.cpp:169-174`; README lines 89-91, 166, 177, 220-221; `common/common.h` |
| Claude Code byte-level watchdog 300 s on a custom `ANTHROPIC_BASE_URL`; event-level 300 s; body idle 5 min; no first-byte deadline for gateways; `CLAUDE_STREAM_IDLE_TIMEOUT_MS` min 5 min and byte cap 30 min; `CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS` 10 s–30 min; `API_TIMEOUT_MS` 600000 | confirmed | code.claude.com/docs/en/network-config "Streaming idle watchdogs"; docs/en/env-vars |
| Codex 0.163.0 rejects `wire_api="chat"`; ollama (11434) and lmstudio (1234) providers use Responses; `stream_idle_timeout_ms` 300,000; `--oss --local-provider` | confirmed | openai/codex@rust-v0.163.0 `model-provider-info/src/lib.rs:66,100,653-686`; local `codex exec --help` |
| Codex default OSS models `gpt-oss:20b` / `openai/gpt-oss-20b` | confirmed | codex@main `ollama/src/lib.rs:16`, `lmstudio/src/lib.rs:7` |
| LM Studio `/v1/messages` in 0.4.1 (2026-01-30); `/v1/responses` stateful in 0.3.29 (2025-10-06); `tool_choice` in 0.3.15 | confirmed | lmstudio.ai/docs/developer/api-changelog; lmstudio.ai/changelog/lmstudio-v0.4.1 (January 30, 2026) |
| LM Studio Claude Code setup: `CLAUDE_CODE_ATTRIBUTION_HEADER=0`, x-api-key or Bearer, more than ~25k context | confirmed | lmstudio.ai/docs/integrations/claude-code |
| LM Studio 0.4.0: continuous batching, 4 parallel slots by default, llama.cpp engine only; `lms daemon up` | confirmed | lmstudio.ai/blog/0.4.0 (2026-01-28) |
| LM Studio Bionic 1.1.8 dated 2026-10-12 | confirmed | lmstudio.ai/changelog |
| `lms load --context-length / --estimate-only / --ttl`; JIT default context undocumented | confirmed | lmstudio.ai/docs/cli/local-models/load |
| mlx_lm.server v0.32.2 serves OpenAI chat/completions only, "not recommended for production", `--kv-bits` disables batching; parsers include laguna | confirmed | ml-explore/mlx-lm@v0.32.2 `server.py:1243-1247`, `SERVER.md:8,50-51`, `tool_parsers/` |
| vLLM v0.32.0 serves `/v1/messages` and `/count_tokens` | confirmed | vllm@v0.32.0 `entrypoints/anthropic/api_router.py:51-52,89-90` |
| vllm-metal v0.28.0 was the first release, on 2026-09-22 | corrected | The blog (2026-09-22) says "first official release". The GitHub release is dated 2026-09-01 and v0.1.0/v0.2.0 came earlier |
| Release versions and dates: Ollama v0.40.6 2026-10-16, llama.cpp b11753 2026-10-20, mlx-lm v0.32.2 2026-10-16, vLLM v0.32.0 2026-10-18, CCR v3.1.3 2026-10-09, LiteLLM v1.106.0 | confirmed | `gh api repos/<o>/<r>/releases` |
| CCR on `127.0.0.1:3456`; "local login import", "credential pools" | confirmed | musistudio/claude-code-router@v3.1.3 README lines 36, 175, 229 |
| Qwen3.5-9B exists (2026-02-27, Apache-2.0, 9.65B); BFCL-V4 66.1, TAU2 79.1; Q4_K_M 5.7 GB | confirmed | HF API createdAt and safetensors total; model card table; unsloth GGUF tree |
| Gemma 4 12B exists (2026-05-23, Apache-2.0, 12.0B); LiveCodeBench v6 72.0, Tau2 69.0; Q4_K_M 7.1 GB | confirmed | HF API; card lines 95, 98; unsloth/gemma-4-12b-it-GGUF 7.12 GB |
| Qwen3.6-35B-A3B: SWE-V 73.4, SWE-Pro 49.5, TB2.0 51.5; UD-Q4_K_M 22.1 GB (IQ4_XS 17.7, IQ2_M 11.5); 128K advice | confirmed | Model card table and line 557; unsloth GGUF tree |
| Qwen3.6-27B SWE-V 77.2, TB2.0 59.3; Q4_K_M 16.8 GB | confirmed | Model card; unsloth GGUF tree |
| Qwen3.8-27B exists (2026-08-05); SWE-Pro 61.7 in the Claude Code harness; UD-Q4_K_M 16.5 GB | confirmed | HF API; card table and notes; unsloth GGUF tree |
| Qwen3.8-27B TB2.1 73.0 "(Claude Code harness)" | corrected | The card row reads "Terminal Bench 2.1 (Terminus)" |
| Muse Glimmer-30B exists (Meta Superintelligence Lab, 2026-08-09, Apache-2.0, 29.6B incl. vision); SWE-V 76.0, SWE-Pro 51.2, TB2.1 51.7 | confirmed | huggingface.co/meta-models/Muse-Glimmer-30B (API and card lines 9-10, 29-32, 100-102); Ollama `cmd/launch/muse.go` |
| Muse Glimmer GGUF size | corrected (filled in) | meta-models/Muse-Glimmer-30B-GGUF Q4_K_M 16.76 GB |
| Laguna XS 2.1 exists (Poolside, 2026-06-20, OpenMDW-1.1, 33B/3B); SWE-V 70.9, TB2.0 37.5, own harness; "Mac with 36 GB" | confirmed | huggingface.co/poolside/Laguna-XS-2.1 (API; card lines 26, 40, 63-65, 79) |
| Laguna quant size "n/a" | corrected (filled in) | poolside/Laguna-XS-2.1-GGUF Q4_K_M 20.27 GB |
| GLM-5.3-Flash has 320B total / 18B active; the plugin's default implementer | confirmed | HF card line 25 (API total 321.3B); repo README.md:38,125 |
| GLM-4.7-Flash SWE-V 59.2, gpt-oss-20b 34.0; Q4_K_M 18.3 GB | confirmed | HF card line 39; unsloth GGUF tree |
| Devstral Small 2 vendor 68.0 vs mini-SWE-agent 56.4; gpt-oss-120b 26.0 (2025-08-07); MiniMax M2.5 75.8; last commit 2026-09-01 | confirmed | SWE-bench/swe-bench.github.io@master `data/leaderboards.json` (Verified board); commit "Drop bash-only board" 2026-09-01; Devstral card line 44 |
| gpt-oss-120b 62.0 in Qwen's table; Qwen3.5-122B-A10B SWE-V 72.0, TB2 49.4; Q4_K_M 76.5 / UD-IQ4_XS 60.2 GB | confirmed | Qwen3.5-122B-A10B card table header and rows; unsloth GGUF tree |
| Nemotron 3.5 Bolt 24GB TB2.1 50.98 vs 44.38; OpenMDW-1.1; GGUF 22.0 GB | confirmed | nvidia card lines 4, 69, 123-126; 24GB-GGUF tree |
| Qwen3.8-Flash-Next is 180B (125B + 51B n-gram + 4B MTP; 6B active) | confirmed | Card line 46; HF API total 179.99B |
| Other GGUF sizes (Qwen3-Coder-Next Q4_K_M 48.4, gpt-oss-120b 63.4, MiniMax-M2.7 UD-Q3_K_M 101 / UD-IQ4_XS 108) | confirmed | HF trees: 48.5, 63.4, 101.2, 108.4 GB |
| KV per token: Qwen3.5-9B 32 KiB, Qwen3.6-35B-A3B 20 KiB, Qwen3.8-27B 64 KiB, Gemma 4 12B 16 KiB + ~320 MiB | confirmed | Recomputed from each `config.json` (`layer_types`, KV heads, `head_dim`, `sliding_window`) |
| oMLX Qwen3.5-9B 4-bit on M4 16 GB: 223/221 PP, 20.4/20.2 TG (v0.2.6) | confirmed | omlx.ai/benchmarks/nw2dhnfb and k9z96zfi |
| oMLX gpt-oss-20b 8-bit on M4 32 GB: 277/309 PP, 23.5/22.4 TG | confirmed | omlx.ai/benchmarks/dfpevyi1 (oMLX v0.2.13) |
| llama.cpp M4 / Pro / Max Q4_0: 221/24.1, 440/50.7, 886/83.1; M4 120 GB/s | confirmed | github.com/ggml-org/llama.cpp/discussions/4167 |
| pi `contextWindow` default 128000, `openai-completions`, `supportsDeveloperRole`, dummy key | confirmed | unpkg @earendil-works/pi-coding-agent@0.83.0 docs/models.md lines 26-39, 199-207 |
| OpenCode: raise Ollama `num_ctx` to 16k–32k if tool calls fail | confirmed | opencode.ai/docs/providers |

**Reliability assessment.** The factual base is strong. Every version, release date, model name, parameter count, license, benchmark figure and GGUF size checked matches a primary source. That includes the two names that looked suspicious: "Laguna XS 2.1" (Poolside) and "Muse Glimmer-30B" (Meta) are real Hugging Face repos with the stated numbers. Two mechanism-level conclusions were wrong, and both affect the adapter design:

- **llama-server is not silent during prefill.** At b11753 it sends headers when prefill starts and SSE comment pings every 30 s. The byte-level watchdog does not fire. Only the event-level watchdog (about 5–10 min without a parsed event) bounds very long prefills.
- **The attribution fingerprint is stable within a conversation** from Claude Code 2.1.181 on. It costs cross-dispatch prefix reuse, not per-turn re-prefill.

Smaller fixes: the llama-server default port is now 9931, not 8080. Qwen3.8-27B's TB2.1 score was measured with Terminus, not Claude Code. The vllm-metal release date was off. The default `claude -p` request size (66 KB) was not independently reproduced.
