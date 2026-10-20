# Universal dispatchers: research synthesis and recommendation

Date: 2026-10-20 · Branch: `research/universal-dispatchers` (code snapshot `c1aa9e0`) · Inputs: 12 research reports, 4 design proposals and 3 judge verdicts (index in §7).

## Кратко

- **Ответ.** Да: несколько «универсальных диспетчеров» под роли сделать можно, и большая часть механики уже написана. `bin/lib/zcode-dispatch.mjs` примерно на 70 % не зависит от harness: журнал задач, блокировка дерева, таймауты, классы ошибок и doctor/probe выносятся в общее ядро, а под каждый harness пишется адаптер на 400–700 строк [00 §2; D1 §9]. Маршрутизируются имплементатор (включая risk-фазы) и ревьюеры, роль которых сейчас выполняет Codex Astra (ревью плана и контрольное ревью); автор плана, ревью Opus, гейт Sonnet и фронтенд-имплементатор остаются субагентами Claude [D1 §5.1].
- **Архитектура.** Один новый диспетчер `agent-dispatch` с реестром профилей (harness + эндпоинт + модель + ссылка на ключ + роли), ToS-политикой в виде таблицы (запрещено всё, что не разрешено явно) и выбором канала в коде (`route`) вместо прозы в SKILL.md.
- Первый адаптер — `claude -p` с Anthropic-совместимыми эндпоинтами: он один покрывает GLM (Coding Plan или API), DeepSeek, Kimi Platform, MiniMax, Qwen (Alibaba PAYG), OpenRouter и локальные серверы [01; 06 §1.1].
- Второй — `codex exec` с кастомными провайдерами: единственный путь, на котором сторонняя модель работает в OS-песочнице и, при допустимой политике данных провайдера (без хранения или без обучения на данных), может брать фазы SECURITY/DATA_LOSS; сейчас такие фазы получают только модели OpenAI, так что это отдельное решение (D13) [05; 09 §9]. OpenCode (ради подписок Copilot, OpenCode Go, ChatGPT Plus/Pro), pi и dsh подключаются позже, по запросу; ACP — лишь опциональный транспорт для dsh [10 §4.7].
- **Работает:** любые PAYG-ключи в любом harness (кроме OpenCode Zen вне OpenCode); GLM Coding Plan в ZCode, Claude Code, Codex, OpenCode и pi; OpenCode Go в его проверенных клиентах; Copilot в OpenCode; ChatGPT Plus/Pro в Codex (как сейчас), OpenCode и pi (в pi только через вход «OpenAI (ChatGPT subscription)»); локальные модели [07 §5].
- **Серая зона** (только по явному opt-in пользователя): подписка Kimi Code, MiniMax M Plan, OpenCode Zen вне OpenCode, Ollama Cloud [07 §5].
- **Запрещено:** Alibaba Coding Plan (запрет на неинтерактивное использование) и Token Plan (07 считает его серым, но до разъяснения Alibaba держим запрет); GLM Coding Plan в dsh, Qwen Code, Kimi CLI, а также через SDK или напрямую по API; подписка Claude Pro/Max вне самого Claude Code (диспетчер её не использует вовсе); потребительский вход Google; логины Anthropic и Copilot через pi; ChatGPT Business/Enterprise вне Codex [07 §5; 06 §1.2].
- **Локальные модели** подключаются тем же адаптером как эндпоинт-профиль, но на этом Mac (M4, 16 ГБ) имплементатор нежизнеспособен; на 32–48 ГБ — только тривиальные фазы и только по opt-in; никогда для ревью, планирования и SECURITY/DATA_LOSS [08 §9].
- **Безопасность без лишних церемоний:** ключ лежит в файле 0600 и вводится только из терминала пользователя; `claude -p` защищён от перенаправления ключа настройками репозитория и от чтения ключа моделью; после каждой задачи ключи ищутся в diff, отчёте и логах. Утечка ключа или изменение `.git/hooks` останавливает работу в этом дереве и задаёт ровно один вопрос [01 §9; 09 §7].
- **MVP** — инкременты 0–2, около двух недель: многопровайдерные имплементаторы в пайплайне при неизменном поведении по умолчанию.
- **Нужны ваши решения** (раздел 5): какие ключи подключать первыми; что строить после MVP — codex-exec (risk-фазы) или OpenCode (подписки); оставить ли ZCode каналом GLM по умолчанию или сравнить его с `claude -p` на той же подписке; пускать ли DeepSeek (данные хранятся в КНР) и серые планы; допускать ли сторонние модели к фазам SECURITY/DATA_LOSS; нужен ли dsh.

---

## 1. Question and scope

### 1.1 The request

Verbatim:

> Создай новую ветку, здесь мы исследуем возможность создать несколько «универсальных диспатчеров/инвокаторов» на имплементатора или другие роли. Ну то есть как сейчас есть кодекс через официальную реализацию для Клода, но что-то более многообразное, чтобы пользователь мог себе настроить возможность диспатчить клодом разные харнессы и/или подрубать в них разные апи или подписки, которые у него имеются. Типа: claude code -p с разными эндпоинтами (тот же GLM, DeepSeek, DSH, OpenCode с разными апи или их подпиской, pi с апишками. Типа, да хоть локальную модель подрубить таким макаром, хоть апи дипсика, хоть минимакс, хоть Квен

Clarification: «dsh — это deepseek harness».

Translation: "Create a new branch. Here we research whether we can build several 'universal dispatchers/invokers' for the implementer or other roles. Today we have Codex through its official integration for Claude; we want something more varied, so the user can configure Claude to dispatch different harnesses and/or plug into them the APIs or subscriptions they hold. For example: `claude code -p` with different endpoints (GLM, DeepSeek, DSH, OpenCode with different APIs or its subscription, pi with APIs). Even a local model could be hooked up this way, or the DeepSeek API, MiniMax or Qwen." Clarification: "dsh means DeepSeek Harness."

### 1.2 Scope

| In scope | Out of scope |
|---|---|
| Dispatching implementer and reviewer roles of `dev-orchestrator` to configurable (harness, endpoint, model, credential) channels | Replacing the Claude in-process subagents (plan writer, Opus reviews, Sonnet gate, frontend implementer) [D1 §5.1] |
| Harnesses: `claude -p`, Codex with custom providers, OpenCode, pi, dsh, the existing ZCode channel, plus a survey of ~20 others [04 §B] | Building any adapter in this research |
| Providers and plans: Z.ai, DeepSeek, Moonshot, MiniMax, Alibaba, OpenRouter, OpenCode Go/Zen, OpenAI, Copilot, local servers [06] | Windows support [D1 §11] |
| ToS, local models, sandboxing, key custody, ACP | Live quality benchmarking on this repo (deferred to LIVE validation, §4) |

### 1.3 Method

1. **Twelve research reports** (00–10, with 04 split into 04 and 04b), each written from primary sources: release tags read with `gh api`, `npm view`, official docs, and local read-only runs.
2. **An adversarial fact-check of each external report.** An independent checker re-opened the sources and edited the reports in place; reliability ratings are in §7. Superseded claims are not repeated here.
3. **Four design proposals:** D1 incremental, D2 user-config-first, D3 security-first, D4 abstraction-first.
4. **Three judges** (cited as [J1] feasibility, [J2] safety, [J3] user value) scored and critiqued the proposals. Summed scores: D1 22, D4 19.5, D2 18, D3 17 (§7). The architecture in §3 uses D1 as the skeleton, adds the grafts the judges named, and fixes every flaw they flagged.

### 1.4 Limits

- **No remote model endpoint was called, nothing was installed, and no credential store was read.** OpenCode, pi, dsh, srt and Ollama are not installed on this machine [09 Sources].
- **What was tested locally, all against stubs on 127.0.0.1 with dummy tokens:**
  - `claude -p` 2.1.302: experiments E1–E25, covering output shape, the repo-settings credential redirect, the env scrub, the error matrix, signals and resume [01 §18]. The fact-checker re-ran the high-stakes ones.
  - `codex exec` 0.163.0 against a loopback Responses stub: provider switching, `-s read-only`, key exposure, error classes and signals [05 App. A].
  - The existing test suite: `tests/test-zcode-dispatch.sh` gives 110 PASS, 0 FAIL [00 §5].
  - Nested `sandbox-exec` on macOS 26.5.2, which fails with exit 71 [09 Fact-check].
  - Harness request sizes captured by a capture-only mock [08 §4].
  - `--help` and `--version` output for `claude`, `codex` and the ZCode bundle [10].
- **Machine:** macOS 26.5.2, Apple M4, 16 GB, Node 26. Claude Code 2.1.302, Codex 0.163.0 and ZCode.app are installed.

---

## 2. Findings

### 2a. Harness matrix

**Contract and mechanics**

| Harness | Headless contract | Final message + session id | Resume | Providers / endpoints |
|---|---|---|---|---|
| **`claude -p`** (Claude Code 2.1.302) | `claude -p --output-format json`, prompt on stdin (capped at 10 MB). `stream-json` needs `--verbose` [01 §2, §15.13] | One JSON object: `result`, `session_id`, `usage`, `is_error`, `api_error_status`, `terminal_reason`. `--session-id <uuid>` pre-assigns the id [01 §3, §4] | `--resume <uuid>`, only with the same `CLAUDE_CONFIG_DIR`. Another dir gives exit 1 and "No conversation found" [01 Fact-check] | Any Anthropic Messages endpoint. Official Claude Code recipes exist for Z.ai, DeepSeek, Kimi Platform, MiniMax, Alibaba, OpenRouter, Ollama and LM Studio; llama-server also serves `/v1/messages` [01 §14; 08 §2] |
| **Codex `exec`** with custom providers (0.163.0) | `codex exec --json -o last.txt … -`, prompt on stdin. **Responses API only**: `wire_api="chat"` is a hard error [05 Bottom line] | JSONL events plus `-o last.txt`; `thread_id` arrives in the first event. An unknown model emits an `error` item but exits 0, so key on `turn.failed` or the exit code [05 §3] | `codex exec [flags] resume <thread_id>`, flags before `resume`, same `CODEX_HOME` and provider [05 §4] | Official Codex configs from DeepSeek, Z.ai (GLM Coding Plan, `api.z.ai/api/v1`), Kimi and MiniMax; Alibaba Model Studio serves Responses too, but its page does not mention Codex; also OpenRouter (stateless), Ollama ≥ 0.13.4, LM Studio, vLLM and llama-server [05 §5.3] |
| **OpenCode v1** (1.19.3) | `opencode run --format json`, JSONL, in-process with no TCP port. Pass the prompt by stdin redirect only (argv elements with spaces get quoted) and close stdin, or the run hangs [02 §2, Fact-check] | Text parts of the last message id, or `opencode export <id>`. Exit 1 can follow a recovered context overflow, so look for final text after the last error [02 Fact-check] | `-s <sessionID>` with the same XDG env [02 §4] | Catalog: `zai-coding-plan`, `deepseek`, Kimi, MiniMax, `opencode-go`, `github-copilot`, `openai` (ChatGPT login), LM Studio; any OpenAI, Anthropic or Responses endpoint [02 Bottom line] |
| **pi** (`@earendil-works/pi-coding-agent` 1.3.0) | `pi --mode json`, prompt on stdin, `--session-dir --session-id` [03 Bottom line] | JSONL: line 1 is the session header; the last assistant `message_end` carries `stopReason`. Exit codes in JSON mode do not reflect provider failure, so classify from events [03 §3.3] | `--session-id` with the same dir and cwd. **An unknown id silently creates a new session**, so the adapter checks that the file exists [03 §4] | 42 built-in providers, plus `models.json` (openai-completions, openai-responses, anthropic-messages) for any endpoint, local included [03 §5] |
| **dsh** (DeepSeek Harness 0.2.1-rc.2) | `dsh --profile headless --patch <yml> --json - < prompt` [04b §2] | NDJSON: `session` (the only place the id appears), `status`/`text`/`tool_call`/`tool_result`, then an uncapped `final` [04b §3] | `--session-id`, same cwd only; an id cannot be pre-assigned [04b §4] | A native DeepSeek route (Anthropic Messages) plus 42 vendored pi-ai providers. Model and effort are set by a YAML `--patch`, not by flags [04b §5] |
| **ZCode** (current GLM channel) | `zcode-dispatch task --background --prompt-file F`; ZCode CLI `-p` with JSON output. Prompt goes through argv, capped at 200 KiB on macOS and 120 KiB on Linux [00 §1.1; zcode-dispatch.mjs:37] | JSON `{response, sessionId, usage}` [00 §2] | `--resume-task zt-N`, only from a `completed` job [00 §1.6] | Z.ai built-in templates only; pinned `GLM-5.3-Flash$max` [07 §2 note; zcode-dispatch.mjs:31] |
| Survey: **Qwen Code**, **Kimi Code CLI**, **Antigravity `agy`** (04's top three) | `qwen -p`; `kimi -p`; `agy -p` [04 §B] | Qwen uses a Claude-style envelope; Kimi stream-json; agy JSON with an `AGY_ERROR` exit 3 [04 §B] | uuid / session id / conversation id [04 §B] | Their draw is the vendor subscription: Alibaba plans, Kimi Code membership, Google sign-in [04 §B.1] |

**Safety, maturity and verdict**

| Harness | Auth and isolation | Autonomy defaults; read-only mode | Native sandbox | Cancellation quirks | Maturity / pinning | Verdict |
|---|---|---|---|---|---|---|
| **`claude -p`** | Set exactly one credential, `ANTHROPIC_AUTH_TOKEN`; two variables, or `apiKeyHelper`, send two headers [01 Fact-check]. A fresh `CLAUDE_CONFIG_DIR` fails closed with no request [01 E5]. A repo `.claude/settings.json` can redirect the token, even under `--bare`; `--setting-sources "" --settings <file>` blocks it [01 §9]. The key is visible to Bash unless `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` or a sandbox `credentials` deny is set [01 E13]. An inherited `CLAUDE_CODE_ENTRYPOINT` misreports the client [01 E23] | Since 2.1.302, `-p` starts in manual mode: denials exit 0 and are listed in `permission_denials`. Auto mode on non-Claude models is **unproven, not ruled out** [01 Fact-check]. Read-only = `--tools "Read,Glob,Grep"` + `dontAsk`, a tool restriction [01 §16] | Bash/PowerShell/Monitor only (Seatbelt/bwrap via srt); Read/Edit go through permission rules. `failIfUnavailable`, `allowUnsandboxedCommands:false`, `allowedDomains` empty by default [01 §8] | SIGTERM gives exit 143 with empty stdout and kills Bash trees; SIGINT gives exit 0 with empty stdout. Empty stdout is always a failure. API errors come back as `is_error:true` with `subtype:"success"`. Default retries take about 3 min; set `CLAUDE_CODE_MAX_RETRIES` [01 §10, §11] | Proprietary; 13 releases in 15 days [01 §1]. Pin a minimum version and check required flags in `--help` | **Build first** (Inc 1). One adapter reaches every Anthropic-endpoint provider |
| **Codex `exec`** | `[model_providers.x]` with `env_key` or `auth.command` (`/bin/cat <0600 file>` worked); no login needed [05 §6]. Per-profile `CODEX_HOME` absorbs the `trust_level` write-back; project config cannot redirect the provider [05 §5.1, §9] | `-s workspace-write \| read-only`. Read-only blocked writes and network under a third-party provider [05 §7] | Tools-only Seatbelt/bwrap; the harness and key stay outside; network off. **Must set** `shell_environment_policy.ignore_default_excludes=false`, or the key leaks to tools [05; 09 §3] | SIGTERM orphans tools; SIGINT cleans them. Ladder: SIGINT, 10 s, SIGTERM, SIGKILL, sweep [05 §10] | 0.163.0. Must-fix defaults: requests carry the absolute workspace path, git HEAD and installation id; hosted `web_search`; a fresh home calls chatgpt.com and github.com unless `--disable plugins`. Never use `--oss`, which auto-pulls models [05 Bottom line, Fact-check] | **Build second** (Inc 4). The only route that meets the risk-phase bar with third-party models [09 §8–9] |
| **OpenCode v1** | `auth.json` (0600) or `{file:}`. `OPENCODE_CONFIG_DIR` is additive, so isolate with per-profile `XDG_*`, `OPENCODE_DISABLE_*`/`OPENCODE_PURE` and an env allowlist. Catalog env vars auto-enable providers (`GITHUB_TOKEN` enables Copilot) [02 Bottom line] | Default `"*":"allow"`. An ask in `run` is auto-rejected and the v1 loop stops, often with exit 0; `--auto` approves everything, `.env` included. The `plan` agent is **not** read-only; use a custom reviewer agent with an explicit deny-all [02 §7] | None [09 §3] | Bash children run in detached groups, so snapshot descendants before killing. `retry-after` can stall for hours, so a wall-clock timeout is required [02 §10] | v1.19.3. Homebrew installs v2, whose `run` uses a shared background service and continues after a reject. **Pin v1** and have doctor refuse v2 [02 Bottom line] | **On demand** (Inc 5), for the subscriptions it alone carries truthfully: Copilot, OpenCode Go, ChatGPT Plus/Pro [07 §5] |
| **pi** | `PI_CODING_AGENT_DIR`, `--no-approve -ne -ns -np --no-mcp`, `PI_OFFLINE=1`, `PI_TELEMETRY=0`, env allowlist [03 §9]. Its Anthropic OAuth impersonates Claude Code and its Copilot login impersonates VS Code: **refused** [07 §3] | No permission system. Read-only = `--tools read,grep,find,ls` (tool removal) [03 Bottom line] | None. The bash tool inherits the full env and `auth.json` is readable [03; 09 §3] | SIGTERM makes pi kill its bash groups (exit 143); then SIGKILL the pgid and sweep. SIGINT does not clean up [03 §10] | 1.0.0 shipped 2026-10-01 with seven releases since; pin exactly [03 Fact-check] | **On demand** (Inc 6): breadth, and ChatGPT through the "OpenAI (ChatGPT subscription)" flow |
| **dsh** | Keys come from env, then the cwd `.env`, then `$DSH_HOME/.env`; the model can read key files. Set `DSH_HOME`, an empty `DSH_AGENTS_HOME` and `DSH_TELEMETRY_DISABLED=1`. **Pin `baseURL`**: a repo `.env` `DEEPSEEK_BASE_URL` would redirect the key and the uploaded session log. Disable `session-log-deepseek` (up to 8 MiB with file contents), the plugin inventory and the title call [04b §5–9; 04 Fact-check] | Approvals fail closed in headless. `DSH_PERMISSION_MODE=read-only` is OS-enforced for writes [04b §7–8] | Seatbelt / bwrap+Landlock, **writes only**: reads, network and process visibility stay open. Linked-worktree `.git` sits outside the allow-list [04b §8; 04 Fact-check] | **SIGTERM exits 0.** Snapshot descendants, SIGINT, 7 s, SIGKILL, kill the PGIDs [04b §10] | Developer preview; all 31 releases are prereleases. Companion packages have a stale npm `latest`, so pin exact versions [04 Fact-check] | **On demand** (Inc 7), DeepSeek PAYG only. Reviewer first; implementer only under srt with its own sandbox off [J2] |
| **ZCode** | Key in plain text in the personal provider config (0600), no env indirection [09 §3] | `--mode yolo`; no read-only mode; `DISALLOWED_TOOLS = []` [00 §4.2; 09 Fact-check] | None (T0) | SIGTERM to the group, 5 s, SIGKILL [00 §1.1] | App pinned at 3.15.1; 110-test oracle [zcode-dispatch.mjs:32; 00 §5] | **Keep** as the built-in `glm` channel, grandfathered T0. Never risk phases or reviews |
| **Qwen Code / Kimi Code CLI / agy** | Per-harness homes exist (`QWEN_HOME`, `KIMI_CODE_HOME`); agy uses keyring auth [04 §B.2] | Kimi `-p` always runs under `auto`, with **no** headless read-only mode [04 Fact-check] | Qwen: Seatbelt/containers; Kimi: none; agy: terminal sandbox [04 §B] | Qwen exit codes 53/55/130 [04 §B] | Active; agy is closed source [04 §B] | **Never build.** Their unique draw is a plan that forbids or restricts headless use or wrapping: Alibaba Coding Plan (AL1; Token Plan AL2 held at `no`), Kimi Code (KI1 "interactive use only", gray), Google consumer (GO2). The PAYG equivalents are reachable through `claude -p` [07 §5; D4 §3.9] |
| Runners-up: Mistral Vibe, MiniMax Code, Factory Droid, Copilot CLI | — | Droid is read-only by default [04 §B] | Copilot CLI has a command sandbox [04 §B] | Vibe has the best exit-code contract (0–4) [04 §B] | MiniMax Code is v0.6.x with an undocumented exec contract [04 §B.1] | Not planned. Revisit only if you hold a Mistral, Factory or Copilot plan that needs its own harness |

### 2b. Providers and plans

| Provider | Endpoints (Anthropic / OpenAI / Responses) | Flagship coding models | Billing | Plan terms for headless use | Data policy |
|---|---|---|---|---|---|
| **Z.ai** (GLM) | `api.z.ai/api/anthropic` / Coding Plan chat `/api/coding/paas/v4` / `/api/v1`; China `open.bigmodel.cn` [06 §1.1] | `glm-5.3` (1M), `glm-5.3-flash` [06 §2.1] | PAYG: GLM-5.3 $1.40/$4.40, Flash $0.15/$0.50 per 1M tokens. Coding Plan Lite/Pro/Max on credits, from $18/month. **Typed keys since 2026-10-16**; an old key is "Compatible" only on an account that ever had a plan [06 §1.3, §2.1] | Coding Plan: listed tools only (ZCode, Claude Code, Codex, OpenCode, Pi, …). Bans direct API use from your own apps, the SDK, and "bulk or automated usage on behalf of others". **Headless self-use is not addressed.** Recommended parallel projects: Lite 1, Pro 1–2, Max 2+ [06 §1.2, §2.1; 07 ZA1–ZA3] | API DPA: content not stored; Singapore [06 §2.1] |
| **DeepSeek** | `api.deepseek.com/anthropic` / `api.deepseek.com` / Responses on the same host [06 §1.1] | `deepseek-v4-pro`, `deepseek-flash` (V4.1), both 1M [06 §2.2] | PAYG only, no subscription. Flash $0.30/$1.20 peak, half off-peak; V4 Pro $1.32/$3.96 peak, half off-peak. Peak is Mon–Fri 01–04 and 06–10 UTC. Concurrency 500 (Pro) / 2,500 (Flash) [06 §2.2] | No automation clause; a key must not be shared [07 DS1] | Stored in the PRC; **no no-training promise**; not on OpenRouter's ZDR list [06 §2.2] |
| **Moonshot** (Kimi) | Platform `api.moonshot.ai/anthropic` and `/v1`; Kimi Code `api.kimi.ai/coding/` [06 §1.1] | `kimi-k3` (1M, always thinks), `kimi-k2.7-code` [06 §2.3] | Platform PAYG: K3 $3/$15. Concurrency by recharge tier; Tier0 = 1. Kimi Code membership $19–199/month [06 §2.3] | Platform PAYG: clean. Kimi Code: "for interactive use only" → **gray** (KI1, against KI3, which shows `kimi -p` for scripts) [07 §5] | "May use Content" to improve services; ZDR for enterprise only [06 §2.3] |
| **MiniMax** | `api.minimax.io/anthropic`; Responses supported [06 §1.1] | `MiniMax-M3.1-Flash`, `MiniMax-M3` [06 §2.4] | PAYG M3.1-Flash $0.15/$0.60. M Plan $22/$55/$132. Subscription and API keys are not interchangeable [06 §1.3, §2.4] | PAYG clean. M Plan: "designed for individual, interactive developer use" → **gray** (MM1) [07 §5] | Nanonoble Pte. Ltd. (Singapore); may use inputs to improve services; personal data in a US data center [06 §2.4] |
| **Alibaba Model Studio** (Qwen; also hosts GLM, Kimi, DeepSeek, MiniMax) | PAYG `{WorkspaceId}.{region}.maas.aliyuncs.com/apps/anthropic`; Coding Plan `coding-intl.dashscope.aliyuncs.com`; Token Plan `token-plan.ap-southeast-1.maas.aliyuncs.com` [06 §1.1] | `qwen3.8-max`, `qwen3.8-flash` [06 §2.5] | PAYG qwen3.8-max $2/$6. Coding Plan keys start `sk-sp-`, PAYG keys `sk-` [06 §1.3, §2.5] | PAYG clean. **Coding Plan: no** (AL1). **Token Plan Personal: no.** Report 06 §1.2 quotes "must not be used for automation scripts", while 07 §5 files it as gray; this design takes the stricter reading (§2c) | "Will never use your data for model training". Only Qwen keeps a US-bounded scope (Virginia); DeepSeek and Kimi on Alibaba run under Global scope [06 §2.5, Fact-check] |
| **OpenRouter** | `openrouter.ai/api` (EU: `eu.openrouter.ai`) [06 §1.1] | Aggregator; many GLM/Kimi hosts are fp4/fp8 quantized, so pin a provider [06 §2.6] | 5.5% card fee; BYOK allowance [06 §2.6] | PAYG; comply with each model's terms (OR1) [07 §5] | No prompt storage unless opted in; ZDR routing [06 §2.6] |
| **OpenCode Go / Zen** | `opencode.ai/zen/go/v1` (Anthropic, Chat, Responses) [06 §3] | GLM-5.3, Kimi K3, DeepSeek V4, Qwen3.8, MiniMax M3 and others [06 §3] | Go $10 / Go Plus $40 per month; Zen is PAYG [06 §3] | Go: validated clients Claude Code, Codex, ZCode, pi, OpenCode, Kilo; dsh is "problematic" for a technical reason. A client **should** send its own User-Agent and `x-opencode-session` (guidance, not a must) [07 OC1; 02 Fact-check] | Per underlying model |
| **OpenAI** (ChatGPT) | via Codex (existing channel) | Luna, Sol, Astra | ChatGPT plan [06 §3] | Plus/Pro: Codex, OpenCode, pi (SIWC subscription flow). Business/Enterprise: Codex only [07 §5] | Status quo |
| **GitHub Copilot** | via OpenCode's own login | Copilot model set | Copilot plan | OpenCode: OK (GH1). pi login: no (PI3) [07 §5] | Copilot terms |
| **Local** (llama-server, Ollama, LM Studio) | All three serve `/v1/messages`, chat and `/v1/responses`; llama-server listens on **9931** by default [08 §2, Fact-check] | See §2d | none | No service terms; model licence only [08 §10 #14] | Stays on the machine |

**Price index per typical agent request** (same token mix for every model, list prices) [06 §4]: DeepSeek Flash $0.00035–0.0007 · MiniMax M3.1 Flash $0.0010 · GLM-5.3-Flash $0.0017 · DeepSeek V4 Pro $0.0019–0.0038 · GLM-5.3 $0.0152 · Qwen3.8 Max $0.0153 (with OpenRouter's cache price; Alibaba's own cache billing gives $0.0127–0.0231 [06 §4, Fact-check]) · Kimi K3 $0.0200.

**Quality evidence is thin and harness-dependent** [06 Bottom line 5]:
- Snorkel Agentic Coding 2.0: Kimi K3 26.1%, GLM 5.3 24.9%, DeepSeek V4 Pro 14.8%, Qwen 3.8 Max 14.7% (with 77.7% agent timeouts), against GPT-6 Astra 47.6% and Opus 5.5 40.4%.
- Terminal-Bench 4.0 (Claude Code harness): GLM-5.3 41.8%, GLM-5.3-Flash 35.8%, Qwen3.8-Max 27%. Terminal-Bench 3.0: GLM-5.3 32.4% [06 §5].
- SWE-bench CLI: Qwen 3.8 Max 4.9%, Kimi K3 4.1%, GLM 5.3 3.5%, DeepSeek V4 Pro 2.3%, against Opus 5.5 16.6%. Senior SWE-bench (mini-SWE-agent): DeepSeek V4.1 Flash 22.7%, MiniMax M3 21.1%, Kimi K3 20.2%. MiniMax M3.1 Flash has no published score [06 §5].
- Implication: Kimi K3 is the strongest cross-family reviewer candidate. Qwen3.8 Max (as a reviewer) and DeepSeek V4 Pro (as an implementer) need a local A/B first [06 §6].

### 2c. Terms of service

| Verdict | Pairs | Plugin handling |
|---|---|---|
| **Safe** | GLM Coding Plan in ZCode, `claude -p`, Codex, OpenCode and pi (ZA2). ChatGPT Plus/Pro in Codex, OpenCode and pi (pi only through the "OpenAI (ChatGPT subscription)" flow; OA1, PI4). Copilot in OpenCode (GH1). OpenCode Go in its validated clients (OC1). Any PAYG key in any harness, except OpenCode Zen outside OpenCode, which is gray (below). Local models [07 §5] | `ok` rows in `agent-policy.json` |
| **Gray** | Kimi Code membership (KI1 vs KI3); MiniMax M Plan (MM1); OpenCode Zen outside OpenCode (OC2); Ollama Cloud (OL2) [07 §5] | Refused unless the user sets `"allowGray": true` in the profile. `profiles check` prints the evidence once. Pay-as-you-go is recommended instead |
| **No-go** | Claude Pro/Max OAuth outside the unmodified `claude` (AN1, AN10, AN11). pi's Anthropic and Copilot logins (PI1–PI3). Google consumer OAuth, and wrapping `agy` (GO1–GO4). Alibaba Coding Plan (AL1). GLM Coding Plan in unlisted tools (dsh, Qwen Code, Kimi CLI, Gemini CLI) or through the SDK/raw API (ZA1–ZA3). ChatGPT Business/Enterprise in third-party harnesses (OA1). Pooling proxies and User-Agent rewriting (OA6, KI1, KI2) [07 §5] | Hard refusal in code: no flag, env var or profile field overrides it |
| **Resolved conflict** | Alibaba Token Plan Personal: "intended for interactive use only … must not be used for automation scripts" [06 §1.2] against gray [07 §5] | `no` until Alibaba clarifies (§6) |
| **Caveats** | Anthropic "doesn't support routing Claude Code to non-Claude models through any gateway": a support caveat, not a ban [01 §14]. Z.ai's proxy clause covers providing the plan "to any third party"; whether an srt header swap in front of a listed tool counts as use "outside such tools" is open [09 Fact-check] | No srt credential masking on subscription plan keys until clarified |

### 2d. Local models

| Finding | Evidence |
|---|---|
| Plumbing is solved: Ollama 0.40.6, LM Studio 0.4.1+ and llama-server b11753 serve Anthropic, Chat and Responses from one process, so `claude -p`, Codex, OpenCode and pi need no translation proxy | [08 Bottom line 1] |
| **16 GB M4 (this machine): a local implementer is not viable.** The Metal working set is 12,124 MiB, swap is already at 3.47 of 4 GB, decode runs at about 20 tok/s and prefill at about 220 tok/s. The models that fit (Qwen3.5-9B, Gemma 4 12B) publish no SWE score | [08 §1, Bottom line 2] |
| **32–48 GB: credible for trivial, well-specified phases**, opt-in: Qwen3.6-35B-A3B, Qwen3.8-27B, Laguna XS 2.1, Glimmer-30B. Vendor scores run 10–35 points above independent single-scaffold runs | [08 Bottom line 5] |
| Never: default implementer, SECURITY/DATA_LOSS, escalation, blocking review, planning. On 16 GB, only a non-authoritative log summarizer | [08 §9] |
| Traps: Ollama defaults to a 4k context below 24 GiB VRAM and silently drops messages. Claude Code assumes 200k for unknown ids unless `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is set. Default `claude -p` sends about 66 KB of prompt (not independently reproduced) against 4.3 KB for `--bare` (confirmed). llama-server pings every 30 s during prefill, so the binding limit is Claude Code's event-level watchdog; raise `CLAUDE_STREAM_IDLE_TIMEOUT_MS` | [08 Bottom line 3–4, Fact-check] |
| **Verdict:** local is an endpoint profile of the `claude-compat` adapter. It ships `enabled:false`, loopback only, with a dummy token and a hardware/context doctor. Server priority: llama-server, then Ollama, then LM Studio. Never `ollama launch --yes` | [08 Bottom line 6; §10] |

### 2e. Sandboxing and key custody

| Layer | Owner | Controls | Status |
|---|---|---|---|
| L0 pre-spawn | dispatcher | git-tree guard; write reservation; env allowlist; per-profile harness home; prompt and key never in argv; key read by the dispatcher from a 0600 store; refuse when already sandboxed (`SANDBOX_RUNTIME=1`) | mostly exists in zcode-dispatch [09 §7.1] |
| L1 OS boundary | harness-native (Codex, Claude Bash sandbox) **or** srt, never both on macOS | write allowlist and protected paths; read denies on credential stores and other profiles; strict egress allowlist; key masking | new [09 §7.1] |
| L2 harness policy | adapter | tool set, permission rules, tool-env scrub, housekeeping traffic off | partial [09 §7.1] |
| L3 post-run | dispatcher | hash of `.git/hooks`, `.git/config` and the worktree `.git` file before and after; secret scan of diff, report, result and logs; redaction | redaction exists; the rest is new [09 §7.1] |

Verdict points:
1. **Only Codex meets the SECURITY/DATA_LOSS bar (M1–M9) today without new work.** It is the only harness that combines tools-only confinement, network control and a key held outside the sandbox [09 §9, Fact-check]. Claude Code's Bash sandbox has the same shape for shell commands only; its Read/Edit tools stay under permission rules, so it fits non-risk implementers (T2) [09 §3].
2. **srt (`@anthropic-ai/sandbox-runtime` 0.0.81) can wrap harnesses that have no sandbox** (pi, OpenCode, ZCode, dsh with its own sandbox off). Its key masking keeps the real key outside the sandbox. But srt is a beta, masking needs the EXPERIMENTAL `tlsTerminate`, request bodies are rewritten with no response scrubbing, and file masks work only on Linux. So a ZCode file key cannot be masked on macOS, and a post-job secret scan is mandatory [09 Bottom line 1–2, §2.4].
3. **Never nest Seatbelt.** A nested profile fails with exit 71 on this macOS, so Codex, dsh and `claude` with its sandbox on must not run under srt [09 Fact-check].
4. **Loopback is the egress hole on this Mac.** The TUN client's proxy listens on 127.0.0.1:1082, so `allowLocalBinding` stays off and srt is spawned without proxy variables [09 §6].
5. **Key custody.** Keys go into a 0600 store, written only by the user from their own terminal. Delivery is env plus scrub (Claude) or `auth.command` reading a per-job 0600 file (Codex). Use per-profile homes. The post-run scan covers every stored key. No verb ever prints a key [09 §5; J2].

### 2f. ACP (Agent Client Protocol)

| Question | Verdict | Evidence |
|---|---|---|
| Mature enough? | Yes: stable v1 (schema 1.26.0). A v2 draft changes core shapes, so pin `protocolVersion` 1 | [10 Bottom line 1] |
| Coverage | dsh, OpenCode, Gemini, Qwen, Kimi, Goose and others are native. Claude Code, Codex and pi need third-party adapters; ZCode has none | [10 Bottom line 2] |
| Security boundary? | **No.** Permission requests are a MAY, they never fire in yolo or full-access modes, and v2 removes client fs/terminal | [10 Bottom line 4] |
| Best fit | dsh `--profile acp`: automation-only, with session list/resume/close, model and effort config options, and permission prompts from its sandbox's escalation path | [10 Bottom line 3] |
| Gaps | No quota or rate-limit error code; per-turn token usage is unstable | [10 §1.3–1.4] |
| **Recommendation** | `transport: acp` as one optional manifest value, used first for dsh guarded mode. Keep the native paths for `claude -p`, Codex and pi. Hand-roll a 400–600-line NDJSON client: the TS SDK 2.0.0 (2026-10-19) removed `ClientSideConnection` | [10 §4.6–4.7] |

### 2g. What the current code gives us

| Item | Fact | Evidence |
|---|---|---|
| Shared-core estimate | In `bin/lib/zcode-dispatch.mjs` (1,673 lines): about 900 lines are generic as written (CORE) and about 250 are generic mechanisms that take adapter values (CORE-P); about 470 lines are ZCode-specific. So roughly 1,150 lines move to a core and the ZCode adapter stays at roughly 450–500 | [00 §2] |
| Adapter hooks already present | `PROMPT_TRANSPORT`, `MODEL_ARGS`/`MODEL_ENV`, `REPORTED_MODEL_PATH`, `USAGE_FIELDS`, `PATTERNS`, `ENV_ALLOW`/`ENV_DENY` | [00 Bottom line 2] |
| Codex companion is the weaker base | No write lock, no task timeout, no reaper (a dead pid stays `running`), no errorClass; `result` exits 0 on a failed job; prunes to 50 jobs | [00 Bottom line 3; §1.4] |
| Contract the orchestrator relies on | `task --background [--cwd] [--resume-task\|--fresh] --prompt-file` → start line with the id last; `status <id> --json` → `job.status ∈ {completed, failed, cancelled}`; `result <id>` → final message with the status/verdict token on line 1 | [00 Bottom line 1] |
| Coupling | 25 points (C1–C25): state line, marker, kill switch, ladder, suffixes, checklist items, failure ladder, stale-reservation strings, gate allowlists (SKILL.md:46, :61–72), Astra-hardwired reviewer sites (including `brainstorming/SKILL.md:221` and `writing-plans/SKILL.md:59`). Most are enumerations of values, not logic | [00 §3; J1] |
| Already generic | verdict tokens and parsing, the operation/seq/dispatch-file scheme, `[REPORT_FILE]`, review packages, `risk_phases` | [00 §3] |
| Reviewer gap | zcode-dispatch has no read-only mode: every task takes the write reservation and runs yolo | [00 Bottom line 6] |
| Test oracle | `tests/test-zcode-dispatch.sh` + `tests/fixtures/zcode-stub.cjs`: 110 PASS. The env-selected fake binary and record mode generalize to every adapter | [00 §5] |
| Skill sizes | `dev-orchestrator/SKILL.md` 127,637 bytes; `zcode-invocation` 33,195; `codex-invocation` 20,446 | `wc -c` at `c1aa9e0` |

---

## 3. Recommended architecture

D1 is the skeleton: grow the working dispatcher, MVP first, today's routing as the default [J1]. The judges' grafts and fixes are folded in, and each section notes where an element comes from.

### 3.1 Components

| Component | File(s) | Status | Responsibility |
|---|---|---|---|
| Job core | `bin/lib/dispatch-core.mjs` | moved from zcode-dispatch (Inc 0) | Job records with sticky terminal claims; write reservation and per-profile/quota-group slot files (O_EXCL, pid + boot id, reaped) under **one shared locks root** [D3; J1]; timeouts; cancel ladders with descendant sweep; env allowlist; redaction; `reduce()` → errorClass → errorGroup + `downProfiles` [D4 §3.5]; L3 post-run checks; doctor/probe framework including the `requiredFlags` `--help` check [D4 §3.7]; key store reader; `release-stale` |
| ZCode adapter | `bin/lib/adapters/zcode.mjs` | moved (Inc 0) | App discovery, cli-home, personal provider config, argv build, output parse [00 §2] |
| ZCode entry | `bin/zcode-dispatch`, `bin/lib/zcode-dispatch.mjs` (~40 lines) | surface unchanged | Same verbs, `zt-` ids, strings, `api-key set` [D1 §8.1] |
| Agent entry | `bin/agent-dispatch`, `bin/lib/agent-dispatch.mjs` | new (Inc 1) | Profiles, policy, `route`/`explain`, `key set\|clear\|status`, `profile add`, `profiles [check]`, and the job verbs; ids `at-NNNN` |
| Adapters | `bin/lib/adapters/{claude-compat,codex-exec,opencode,pi,dsh}.mjs` | new, Inc 1 / 4 / 5 / 6 / 7 | Return data only; the core does every side effect [D4 §3.2] |
| srt layer | `bin/lib/srt.mjs` | new, Inc 5, opt-in | Per-job settings, fail-closed preflight, proxy-free spawn [09 §7.3–7.4] |
| ACP client | `bin/lib/acp-client.mjs` | optional, Inc 7+ | NDJSON JSON-RPC, `protocolVersion` 1 [10 §4.7] |
| Policy | `bin/lib/agent-policy.json` | shipped | Plans (class, hosts, key patterns, data use), (plan, harness) rows with evidence ids, family prefixes [07 §6] |
| Presets | `bin/lib/agent-presets/*.json` | shipped | Vendor recipes, no secrets |
| User data | `~/.claude/plugins/data/superpowers-strigov-ver-agents/` | new | `profiles.json`, `keys/<credential>` (0600), `homes/<profile>/` (0700), `state/<ws>/jobs/` |
| Locks root | `~/.claude/plugins/data/superpowers-strigov-ver-locks/` | new (Inc 1) | Reservations and slots shared by zcode-dispatch and agent-dispatch, so cross-wrapper overlap is enforced in code [J1; J2] |
| Companion overlay | `bin/codex-dispatch` | small change (Inc 2) | `result` exits 1 on a non-completed job; a dead worker pid reads as `failed`/`crash` [D2; D4; J2] |
| Skills | `skills/agent-invocation/SKILL.md` (new); edits to `dev-orchestrator`, `zcode-invocation`, `codex-invocation` and the reviewer templates | Inc 1–3 | §3.8 |

### 3.2 Adapter contract

```js
// bin/lib/adapters/<id>.mjs: default export, no top-level side effects
export default {
  id: "claude-compat", harness: "claude-code", displayName: "Claude Code",
  manifest: { /* section 3.3 */ },
  discover(ctx) {},                 // offline: { bin, version } via ctx.exec("--version")
  doctorChecks(profile, ctx) {},    // version range, requiredFlags in --help, home modes,
                                    // auth method, hardware/context for local endpoints
  prepareHome(profile, job, ctx) {},// -> { env, files: [{ path, mode, content }] }  (settings.<role>.json, system-append.md)
  invocation(req, ctx) {},          // req = { profile, role, phaseRisk, job, prompt:{path,bytes}, resume }
                                    // -> { argv, env, stdin, cwd, secretEnv: ["NAME"] | secretFile: true }
  reduce(io) {},                    // io = { stdout|events, stderrTail, exit:{code,signal}, timedOut, cancelled }
                                    // -> { ok, response, sessionId, usage, reportedModel, denials, errorClass|null }
  patterns: { "model-not-selected": [], auth: [], quota: [], context: [], blocked: [], transient: [] },
  resumeCheck(prev, profile, req) {},  // null | reason  (e.g. pi: session file must exist)
  probe(profile, ctx) {},           // invocation for "Reply with exactly: PONG", parsed by reduce()
};
```

Rules:
- **The core owns every side effect**: spawning, file writes, key reads, timeouts, signal ladders and policy. Adapters return data, which keeps them stub-testable [D4 §3.2].
- **`reduce()` alone decides success.** Exit codes are hints: several harnesses exit 0 on failure (Claude Code on SIGINT and denials, pi in JSON mode, Codex on an unknown model, dsh on SIGTERM), and OpenCode can exit 1 after a recovered failure. Empty or non-JSON stdout is always a failure [D4 §3.2; 01 §15].
- **Adapter env is applied after the allowlist.** The allowlist drops every inherited `ANTHROPIC_*`, `CLAUDE*`, `*_API_KEY`, `*_TOKEN`, `OPENAI_*`, `CODEX_*` and `GITHUB_TOKEN` [00 §4.1 I17; D3 §6.4].
- **No adapter sets identity.** No User-Agent, originator, `x-app` or client id; each harness identifies itself [07 §6.3].

### 3.3 Capability manifest

| Field | Values | Consumer |
|---|---|---|
| `transport` | `cli` \| `acp` | core runner |
| `output` | dialect id: `claude-json`, `codex-jsonl`, `opencode-jsonl`, `pi-jsonl`, `dsh-ndjson`, `zcode-json` | `reduce()`, recorded fixtures |
| `prompt` | `{ via: stdin\|argv, maxBytes }` (claude: stdin, 10 MB [01 §2]; zcode: argv, 200/120 KiB) | size guard; `route --prompt-bytes` |
| `sessionId` | `preassign` \| `first-event` \| `final` | record the handle early when possible |
| `resume` | `{ supported, bind: [home, cwd, provider] }` | `resumeCheck` |
| `readOnly` | `os` \| `tools` \| `none` | reviewer eligibility |
| `tier` | per role: `T0`–`T3` (§3.6) | role and risk gates |
| `nestsSeatbelt`, `srt` | bool; `compatible` \| `with-native-off` \| `no` | srt layer [09 §7.2] |
| `credential` | `{ delivery: env\|secret-file\|harness-file\|login, toolEnvScrub, maskable }` | key custody, doctor text |
| `cancel` | `{ ladder: [[signal, graceMs]…], sweepDescendants }` | core cancel and timeout |
| `model`, `effort` | `{ select, confirm }`, `{ via, vocab }` | no silent downgrade; refuse an effort outside the vocabulary [D4 §3.3] |
| `riskEligible` | bool, **static**, flipped only by a code change after LIVE canaries | `route --phase-risk` [D4; J2] |
| `version` | `{ tested, accept, outside: WARN\|FAIL, requiredFlags }` | doctor: FAIL for prereleases (dsh, pi, OpenCode), WARN for claude and codex [D4 §3.7] |

`claude-compat` values: `output: claude-json` (`--output-format json`; if `stream-json` is ever used, `--verbose` joins `requiredFlags` [01 §15.13; J1]); prompt via stdin with `maxBytes` 10 MB; `sessionId: preassign`; `resume.bind: [home, cwd]`; `readOnly: tools`; implementer T2, reviewer T1; `credential: env` with `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`; cancel ladder SIGTERM to the group (exit 143, kills Bash trees [01 §10]), 5 s, SIGKILL, sweep; `riskEligible: false`; `version.tested 2.1.302`, `accept >=2.1.302 <2.2.0`, `requiredFlags`: `--setting-sources --settings --session-id --tools --strict-mcp-config --disable-slash-commands --append-system-prompt-file --output-format --max-turns --permission-mode` [D4 §3.3]. The SIGTERM-first ladder and `--disable-slash-commands` follow D1 §3.4–3.5; D4 and 01 §16 start with SIGINT, which exits 0 with empty stdout; only SIGTERM is documented to kill Bash trees [01 §10].

### 3.4 `claude-compat`: invocation and generated settings

```
claude -p --output-format json \
  --setting-sources "" --settings <homes>/<p>/settings.<role>.json \
  --model <profile.model> --effort <profile.effort> \
  --tools "Bash,Read,Edit,Write,Glob,Grep" --permission-mode acceptEdits \   # reviewer: --tools "Read,Glob,Grep" --permission-mode dontAsk
  --strict-mcp-config --disable-slash-commands \
  --append-system-prompt-file <job>/system-append.md \                        # re-injects CLAUDE.md/AGENTS.md [01 §15.9]
  --session-id <uuid> [--resume <uuid>] --max-turns <n>          < <prompt file>
```

- **Env:** the allowlist, then `CLAUDE_CONFIG_DIR=<homes>/<p>`, `ANTHROPIC_AUTH_TOKEN=<key>` (the only credential variable) and `ANTHROPIC_API_KEY=""` [07 §6.2].
- **Bash approval:** `acceptEdits` approves only file edits and `mkdir/touch/mv/cp`; other shell commands need allow rules [01 §7]. The implementer relies on the sandbox's auto-allow of sandboxed Bash [01 §8], or passes `--allowedTools` for the role as 01 §16 sketches; the Inc 1 local-real test (a sandboxed test command runs with no prompt) settles which.
- **Profile home:** per profile, not per job, because resume binds to it and 4 parallel runs on one dir worked [01 §10].
- **Settings file:** 0600, rewritten at every task.

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
    "DISABLE_AUTOUPDATER": "1"
  },
  "permissions": {
    "deny": ["WebFetch", "WebSearch",
             "Read(<agents data root>/**)", "Read(<locks root>/**)", "Read(~/.ssh/**)", "Read(~/.aws/**)",
             "Read(~/.config/gh/**)", "Read(~/.codex/**)", "Read(~/.zcode/**)", "Read(~/.claude/**)",
             "Edit(.git/**)", "Write(.git/**)"]
  },
  "skipWebFetchPreflight": true,
  "disableAllHooks": true,
  "sandbox": {
    "enabled": true, "failIfUnavailable": true, "allowUnsandboxedCommands": false,
    "network": { "allowedDomains": [], "strictAllowlist": true },
    "filesystem": { "denyRead": ["<agents data root>", "<locks root>", "~/.ssh", "~/.aws", "~/.config/gh",
                                 "~/.codex", "~/.zcode", "~/.claude", "~/Library/Keychains"] },
    "credentials": { "envVars": [{ "name": "ANTHROPIC_AUTH_TOKEN", "mode": "deny" }] }
  }
}
```

The sandbox `denyRead` alongside the Read deny rules is the fix J2 required for D1. The exact rule syntax and the nesting of `network`/`filesystem` are confirmed by the Inc 1 local-real test, not assumed [D1 §3.5]. A profile's `env` may set only `API_TIMEOUT_MS`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS`, `CLAUDE_STREAM_IDLE_TIMEOUT_MS`, `API_FORCE_IDLE_TIMEOUT` and `CLAUDE_CODE_ATTRIBUTION_HEADER`. Any other key, `ANTHROPIC_BASE_URL` included, is refused at load [D1 §3.5].

**Classification** in `reduce()` [01 §11; D1 §3.5]:

| Signal | errorClass |
|---|---|
| `api_error_status` 401/403 | `auth` (keyed on the status, because the 401 text varies [01 Fact-check]) |
| 404, or "issue with the selected model" | `model-not-selected` |
| 429 with usage/limit/quota/balance/billing wording | `quota` |
| any other 429 | `rate-limit` (an unknown 429 retries; it does not take the channel down [D2 §3.3]) |
| 5xx, 529; `api_error_status:null` with `ECONNREFUSED`/`ENOTFOUND` | `server` / `transport` |
| `terminal_reason: prompt_too_long` | `context` |
| `error_max_turns` (`result:null`); empty or non-JSON stdout; empty `result` | `malformed` |
| non-empty `permission_denials` on a completed job | stored as `job.denials`, not a failure |

**Codex delivery (Inc 4):** `codex exec --json -o <job>/last.txt -C <worktree> -s workspace-write|read-only -c model_providers.<p>={…, auth={command="/bin/cat", args=["<job>/secret/key"]}} …`, with the hardening flags from 05 §9 (`--disable plugins`, `web_search="disabled"`, `shell_environment_policy.ignore_default_excludes=false`, `exclude_slash_tmp`, `check_for_update_on_startup=false`). The secret file is 0600, written per job, deleted at job end and by the reaper. A Codex permission profile marks `keys/`, `homes/*`, the job secret dirs and the credential stores unreadable [05 §6; 09 §7.3]. There is **no `__print-key` verb** [D3 §6.4; J1; J2].

### 3.5 Profile registry

- **Location:** `~/.claude/plugins/data/superpowers-strigov-ver-agents/profiles.json`. Plain JSON, because the wrappers are dependency-free Node [D1 §4.1; J1 rejects a TOML parser at MVP].
- **No repo-level config:** a worked-on repository can never add or redirect a profile [05 §5.1].
- **No secrets:** `credential` names a key-store entry, so profiles that share a key (for example the GLM plan through ZCode, Claude Code and Codex) go down together on `auth`. Cleartext keys and `env:` references are refused [D2; J2].
- **Profile names:** match `^[a-z][a-z0-9-]{1,15}$` and must not shadow a built-in (`glm`, `luna`, `sol`, `astra`, `claude`).

```json
{
  "version": 1,
  "profiles": {
    "glm-cc": {
      "displayName": "GLM-5.3-Flash via Claude Code",
      "adapter": "claude-compat", "plan": "zai-coding-plan", "credential": "zai-plan",
      "baseUrl": "https://api.z.ai/api/anthropic",
      "model": "glm-5.3-flash[1m]", "smallModel": "glm-5.3-flash", "effort": "max",
      "family": "glm", "roles": ["implementer"], "quotaGroup": "zai-coding-plan", "timeoutMin": 60,
      "env": { "API_TIMEOUT_MS": "3000000", "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "1000000" }
    },
    "ds-pro": {
      "displayName": "DeepSeek V4 Pro via Claude Code",
      "adapter": "claude-compat", "plan": "deepseek-payg", "credential": "deepseek",
      "baseUrl": "https://api.deepseek.com/anthropic",
      "model": "deepseek-v4-pro[1m]", "smallModel": "deepseek-flash", "effort": "high",
      "family": "deepseek", "roles": ["implementer"], "concurrency": 2,
      "env": { "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "786432" }
    },
    "kimi-k3": {
      "displayName": "Kimi K3 via Claude Code",
      "adapter": "claude-compat", "plan": "kimi-platform-payg", "credential": "moonshot",
      "baseUrl": "https://api.moonshot.ai/anthropic",
      "model": "kimi-k3[1m]", "smallModel": "kimi-k2.7-code", "effort": "max",
      "family": "kimi", "roles": ["reviewer.plan", "reviewer.control"], "concurrency": 1
    },
    "minimax-flash": {
      "displayName": "MiniMax M3.1 Flash via Claude Code",
      "adapter": "claude-compat", "plan": "minimax-payg", "credential": "minimax",
      "baseUrl": "https://api.minimax.io/anthropic",
      "model": "MiniMax-M3.1-Flash[1m]", "smallModel": "MiniMax-M3.1-Flash", "effort": "max",
      "family": "minimax", "roles": ["implementer"], "enabled": false,
      "env": { "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "524288" },
      "note": "no published benchmarks (06 §5)"
    },
    "glm-cx": {
      "displayName": "GLM-5.3 via Codex (OS sandbox)",
      "adapter": "codex-exec", "plan": "zai-coding-plan", "credential": "zai-plan",
      "baseUrl": "https://api.z.ai/api/v1", "model": "glm-5.3", "effort": "max",
      "family": "glm", "roles": ["implementer.risk", "implementer"], "quotaGroup": "zai-coding-plan"
    },
    "local-qwen": {
      "displayName": "Qwen3.6-35B-A3B on llama-server",
      "adapter": "claude-compat", "plan": "local", "credential": null,
      "baseUrl": "http://127.0.0.1:9931", "model": "qwen3.6-35b-a3b", "effort": "high",
      "family": "qwen", "roles": ["implementer"], "enabled": false, "timeoutMin": 120,
      "env": { "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "65536", "CLAUDE_STREAM_IDLE_TIMEOUT_MS": "1800000",
               "API_FORCE_IDLE_TIMEOUT": "0", "CLAUDE_CODE_ATTRIBUTION_HEADER": "0" },
      "note": "needs >= 32 GB; trivial phases only, opt-in (08 §9)"
    }
  },
  "quotaGroups": { "zai-coding-plan": 2 },
  "routing": {
    "implementer": ["glm", "ds-pro"],
    "implementer.risk": ["sol"],
    "reviewer.plan": ["astra"],
    "reviewer.control": ["astra"]
  }
}
```

Notes on the example:
- **Endpoints and tier models** are the vendors' own Claude Code and Codex recipes [06 §2.1–2.4; 05 §5.3].
- **`quotaGroups.zai-coding-plan: 2`** keeps today's GLM concurrency. The built-in `glm` channel counts against the same group. Lower it to 1 on a Lite plan [06 §2.1].
- **`kimi-k3` concurrency 1** matches Kimi Platform Tier0 [06 §2.3].
- **`glm-cx`** needs Inc 4. Its `implementer.risk` role is honoured only when the M9 data check passes. Z.ai's DPA says *API* content is not stored [06 §2.1]; whether that covers Coding Plan traffic is not stated, and M9 prefers PAYG keys [09 §9]. Giving GLM any SECURITY/DATA_LOSS phase also reverses today's rule that GLM never receives them (README, Guardrails), so the role stays out of the shipped defaults until decision D13 (§5).
- **Routing** defaults equal today's ladder plus `ds-pro`. `route` appends the built-in tails automatically: `luna` for `implementer`, `sol` for `implementer.risk`, `astra` for the reviewer roles.

**Shipped policy** (`bin/lib/agent-policy.json`, excerpt). It mirrors 07 §5 in full [D4 §6.5; J3] and binds each plan to hosts and key shapes [D1 §4.3; D3 §4.3].

```json
{
  "version": 1, "reviewed": "2026-10-20", "reviewDueDays": 90, "default": "no",
  "plans": {
    "zai-coding-plan":    { "class": "subscription", "provider": "zai", "hosts": ["api.z.ai", "open.bigmodel.cn"] },
    "zai-standard":       { "class": "payg", "provider": "zai", "hosts": ["api.z.ai", "open.bigmodel.cn"] },
    "deepseek-payg":      { "class": "payg", "provider": "deepseek", "hosts": ["api.deepseek.com"] },
    "kimi-platform-payg": { "class": "payg", "provider": "moonshot", "hosts": ["api.moonshot.ai", "api.moonshot.cn"] },
    "kimi-code":          { "class": "subscription", "provider": "moonshot", "hosts": ["api.kimi.ai", "api.kimi.com"] },
    "minimax-payg":       { "class": "payg", "provider": "minimax", "hosts": ["api.minimax.io", "api.minimaxi.com"] },
    "minimax-m-plan":     { "class": "subscription", "provider": "minimax", "hosts": ["api.minimax.io", "api.minimaxi.com"] },
    "alibaba-payg":       { "class": "payg", "provider": "alibaba",
                            "hostPattern": "^(?!token-plan\\.)[a-z0-9-]+\\.(ap-southeast-1|us-east-1|eu-central-1|ap-northeast-1|cn-beijing)\\.maas\\.aliyuncs\\.com$",
                            "rejectKeyPrefix": ["sk-sp-"] },
    "alibaba-coding-plan":{ "class": "subscription", "provider": "alibaba", "hosts": ["coding-intl.dashscope.aliyuncs.com"] },
    "alibaba-token-plan": { "class": "subscription", "provider": "alibaba", "hostPattern": "^token-plan\\." },
    "openrouter-payg":    { "class": "payg", "provider": "openrouter", "hosts": ["openrouter.ai", "eu.openrouter.ai"] },
    "opencode-go":        { "class": "subscription", "provider": "opencode", "hosts": ["opencode.ai"] },
    "copilot":            { "class": "subscription", "provider": "github", "auth": "harness-login" },
    "chatgpt-plus-pro":   { "class": "subscription", "provider": "openai", "auth": "harness-login" },
    "claude-subscription":{ "class": "subscription", "provider": "anthropic", "auth": "harness-login" },
    "local":              { "class": "local", "hosts": ["127.0.0.1", "::1", "localhost"], "credential": "none" }
  },
  "providers": {
    "zai": { "dataUse": "no-store" }, "alibaba": { "dataUse": "no-train" }, "openai": { "dataUse": "status-quo" },
    "deepseek": { "dataUse": "no-promise", "jurisdiction": "PRC" }, "moonshot": { "dataUse": "may-use" },
    "minimax": { "dataUse": "may-use" }, "openrouter": { "dataUse": "per-account-zdr" }
  },
  "rows": [
    { "plan": "zai-coding-plan", "harness": ["zcode", "claude-code", "codex", "opencode", "pi"], "status": "ok", "evidence": ["ZA2", "ZA3"] },
    { "plan": "zai-coding-plan", "harness": "*", "status": "no", "evidence": ["ZA1", "ZA2", "ZA3"] },
    { "planClass": "payg", "harness": "*", "status": "ok", "evidence": ["DS1", "MM1", "OR1"] },
    { "plan": "kimi-code", "harness": "*", "status": "gray", "evidence": ["KI1", "KI3"] },
    { "plan": "minimax-m-plan", "harness": "*", "status": "gray", "evidence": ["MM1"] },
    { "plan": "alibaba-coding-plan", "harness": "*", "status": "no", "evidence": ["AL1"] },
    { "plan": "alibaba-token-plan", "harness": "*", "status": "no", "evidence": ["AL2"], "note": "06 §1.2 not compliant; 07 §5 gray; held at no" },
    { "plan": "opencode-go", "harness": ["claude-code", "codex", "zcode", "pi", "opencode"], "status": "ok", "evidence": ["OC1"] },
    { "plan": "copilot", "harness": ["opencode"], "status": "ok", "evidence": ["GH1", "OCH2"] },
    { "plan": "chatgpt-plus-pro", "harness": ["companion", "codex", "opencode"], "status": "ok", "evidence": ["OA1", "OA3", "OCH1"] },
    { "plan": "chatgpt-plus-pro", "harness": ["pi"], "login": "openai-chatgpt-subscription", "status": "ok", "evidence": ["OA1", "PI4"] },
    { "plan": "claude-subscription", "harness": "*", "status": "no", "evidence": ["AN1", "AN10", "AN11"] },
    { "planClass": "local", "harness": ["claude-code", "codex", "opencode", "pi"], "status": "ok", "evidence": ["OL1"] }
  ],
  "families": { "glm": ["glm-", "z-ai/"], "deepseek": ["deepseek"], "kimi": ["kimi", "moonshotai/"],
                "minimax": ["minimax"], "qwen": ["qwen"], "openai": ["gpt-", "openai/"],
                "anthropic": ["claude", "anthropic/"], "google": ["gemini", "gemma", "google/"] }
}
```

**Checks at `profile add`, `profiles check`, `route` and `task`** (`task` is authoritative):
1. **Hard refusals in code**, whatever the policy says:
   - pi with an Anthropic or Copilot OAuth login;
   - `claude-compat` with a claude.ai login in its home, an inherited `CLAUDE_CODE_OAUTH_TOKEN`, or `api.anthropic.com` as the host;
   - a `local` profile with a non-loopback URL or a real key;
   - `codex --oss` [D4 §6.5; J2].
2. **Policy row**: `no` or no row is refused, with the evidence ids and the line of 07 §4 to read. `gray` is refused unless the profile has `"allowGray": true`.
3. **Plan-to-host binding**: the base-URL host must match the plan [D1 §6.3].
4. **Key shape**: `rejectKeyPrefix`/`keyPattern` is checked at `key set`. For Z.ai, where key shape cannot tell Standard from Coding Plan, `key set` asks which type the key is and refuses a mismatch with the profile's plan [06 §1.3; D2; J2].
5. **Staleness**: doctor WARNs once `reviewed` is more than 90 days old. It never blocks [07 §6.7].

**User flow** (one-time; the orchestrator never edits `profiles.json` and never runs `key set`):
1. `"$ADISPATCH" profile add ds-pro --from deepseek-v4-pro` copies a preset.
2. In the user's own terminal: `"$ADISPATCH" key set deepseek`, with a hidden prompt, or `! pbpaste | "$ADISPATCH" key set deepseek`.
3. `profiles check`, then `doctor --profile ds-pro`, then `--probe`: one paid PONG.
4. Add the name to `routing.implementer`.
5. For harness logins (OpenCode Copilot/ChatGPT, pi ChatGPT, Inc 5–6), `"$ADISPATCH" profile env <p>` prints the isolated-home variables. The user runs the harness's own login with them in their terminal, and doctor asserts the login type [D4 §4.5; D3 §6.5].

The `setup` wizard (discovery of harnesses and local ports 11434/1234/9931, `presets --for <role>`, `key list`/`where` showing refs only) is a post-MVP UX increment [D2 §4.5; J3; J1 rejects it at MVP].

### 3.6 Security tiers and ToS gating (low-ceremony)

| Tier | Meaning | Reached by | Allowed roles |
|---|---|---|---|
| **T0** none | harness runs as the user; only the git-tree guard and env allowlist apply | `zcode` (yolo) | non-risk implementer, **grandfathered for the built-in `glm` only**. No new T0 implementer channel is added [D1 §6.1] |
| **T1** tools | no write or exec tool exists in the run | `claude-compat` reviewer (`Read,Glob,Grep`); OpenCode deny-all reviewer agent with no bash; pi `--tools read,grep,find,ls` | non-risk reviewers |
| **T2** bash-os | shell under Seatbelt/bwrap with no network and the key scrubbed; file tools under deny rules; harness outside | `claude-compat` implementer; later, OpenCode/pi under srt with masking after the 09 §10 smoke matrix | non-risk implementer |
| **T3** os | harness and key outside; every tool command in an OS sandbox with network off | `codex-exec`, companion | everything, including SECURITY/DATA_LOSS and OS read-only reviewers |

**Risk phases** need all of the following [09 §9; D3 §5.1; J2]:
- a profile with `riskEligible` (static: `codex-exec` and the companion today);
- `--phase-risk SECURITY|DATA_LOSS`, a **mandatory** flag on every `agent-dispatch task`, copied from `risk_phases`;
- provider `dataUse` ∈ {`no-store`, `no-train`, `status-quo`} (M9);
- an OS read-only reviewer for the phase: Codex `-s read-only` or Astra (M8).

A risk phase is never moved to a lower tier.

**L3 post-run checks** (every job; milliseconds; no waits) [09 §7.1; D4 §6.3]:
1. Hash `.git/hooks/*`, `.git/config` and the worktree `.git` file before and after. A change is `sandbox-violation` (`stop`, §3.7) [D2 §3.3; D3 §6.6]. This is an in-job comparison: nothing is stored or bound across jobs.
2. For read-only jobs, require HEAD, the ref set and `git status --porcelain` unchanged [J2].
3. Scan the diff (against the reservation-time HEAD), the report file, the result and the logs for **every stored key** [J2].

**Doctor WARN, stated plainly:** the grandfathered T0 `glm` channel runs yolo as the user and can read `keys/` of other profiles [J2; 09 §3].

**What keeps it low-ceremony** (the user's standing rule):
- No receipts, hash bindings, provenance gates, persisted canary caches or per-run confirmations. D3's state-integrity hashing of `bin/` and its tier cache are rejected [J1].
- Gray opt-in and key entry are one-time user edits.
- Every refusal is exit 2 with one line and a `hint:`, and the orchestrator reacts in a fixed way.
- Questions are rare and asked once, with options: a security event (`stop`); `route: NONE`, when no eligible channel is left (for a risk phase, as soon as its risk-eligible channels are down); and a write slot still busy after a 10-minute wait. Today's stale-reservation escalation is unchanged. Everything else ends in an announced fallback.

### 3.7 Roles, routing, family rule, fallbacks, kill switch

**Roles:**

| Role (SKILL.md step) | Default list (= v0.11.1 behaviour) | Eligibility |
|---|---|---|
| `implementer` (Steps 3, 3.5 fix, 4 fix, 5 fix wave, integration repair; non-frontend) | `glm`, then `luna` | T0 only for built-in `glm`; profiles ≥ T2 |
| `implementer.risk` | `sol` | `riskEligible` + M9 data use |
| reasoning escalation | `sol` | unchanged (not routable at MVP) |
| `reviewer.plan` (Step 2) | `astra` | `readOnly` ∈ {tools, os}; family ≠ anthropic |
| `reviewer.control` (Step 4.2) | `astra` | `readOnly` ∈ {tools, os}; family ∉ writer families; `os` when the phase is risk-marked |
| Claude subagents (plan writer, 4.1, Step 5, gate, quickfix, frontend) | unchanged | not routable [D1 §11] |

Advisory-reviewer and utility roles [D4] are deferred until a provider ships and a need appears [J1]. Local models never take a blocking role [08 §9].

**`route`** is pure and offline: it reads `profiles.json`, the policy, the kill switches, slot state, key presence and the `--skip` list from the session marker [D4 §5.2; D3 §5.2]. It walks the role list and picks the first candidate that is not disabled, not down or off this session, allowed by policy, eligible for the role's tier and risk, not of a writer family, big enough for the prompt, with a free slot, a key present and a version inside `accept`. Every skip is printed with its reason [D2 `explain`; J1]. There is no inline probe: J1 rejected D2's 45-second probe inside `pick`.

```
$ "$ADISPATCH" route implementer --phase-risk none --prompt-bytes 61234 --skip glm
route: ds-pro via=agent-dispatch adapter=claude-compat family=deepseek tier=T2 resume=yes probe=needed preamble=headless-sandboxed
announce: implementer -> DeepSeek V4 Pro via Claude Code (ds-pro). Skipped glm: down (quota).

$ "$ADISPATCH" route implementer.risk --phase-risk SECURITY
route: NONE
skip: glm-cx (key missing; hint: run `agent-dispatch key set zai-plan` in your terminal)
skip: sol (down: auth; hint: run `codex login` in your terminal)
ask: Phase 4 is SECURITY and no risk-eligible channel is up. Options: 1) retry after fixing sol or glm-cx, 2) skip this phase and continue, 3) stop the plan here.
```

The orchestrator dispatches exactly the printed channel. On `probe=needed` it first runs `doctor --profile <p> --probe` once per session and writes the marker [00 §3 C15]. Built-in rows print `via=zcode-dispatch` or `via=codex-dispatch args=…`.

**Family rule** (model creator, not harness or host) [00 C10; 06 §6]:
- Family is derived from the model id by the policy's prefix table; a declared family that differs is refused.
- Writer families are the **union over the phase's sidecars**. A GLM phase escalated to Sol has {glm, openai}.
- Reviewer tasks carry `--writer-family glm,openai`, and the core refuses a reviewer in that set.
- `--same-family-ok` exists only for the two announced exceptions SKILL.md already has: the 4.2 Astra cross-check of Codex-written code, and the Step 5 Astra availability fallback [SKILL.md:176–178; D3 §5.3; J2].
- `route` never offers an anthropic-family implementer or an anthropic plan reviewer.

**Fallbacks:** the core computes `errorGroup` and `downProfiles`, so the orchestrator holds one table instead of per-harness ladders [D4 §3.5; D2 §3.3].

| errorGroup | Classes | Orchestrator action (announced in one line) |
|---|---|---|
| `down` | `auth`, `quota`, `model-not-selected`, `sandbox-start` | Mark every channel in `downProfiles` down: same credential for `auth`, same `quotaGroup` for `quota`. Relay `hint:` verbatim. Run the **same operation** FRESH on `route --skip …` |
| `retry` | `rate-limit`, `transport`, `server`, `timeout`, `launch`, `crash`, `malformed` | One `--fresh` retry on the same channel. A second failure goes to the next channel, marked down only if its class is in the `down` row (today's GLM rule [00 §1.5]) |
| `next` | `context`, `blocked`; exit 2 `prompt-too-large` | Next channel, FRESH, no mark. Never trim the prompt |
| `stop` | `credential-leak`, `sandbox-violation`, `read-only-violated` | Dispatch nothing more into this tree; the channel goes down and the response is quarantined. Ask **one** question: (1) restore the job's changed paths to BASE, rotate the key in your terminal, and re-dispatch on the next channel; (2) keep the files for inspection and stop the phase; (3) stop the plan [D2 §5.4; D3 §5.4; J2] |
| `route: NONE` | — | Relay the single `ask:` line once |
| `cancelled` | — | Report and wait, as today |
| exit 2 `refused (busy)` | — | Next channel. If none is left, wait in a Monitor loop of at most 10 minutes for a slot, then ask once [D1 §5.4] |
| exit 2 `refused (disabled)` / `refused (policy)` | — | The channel goes `off` for the session; next channel [D1 §5.4] |
| any other exit 2 | — | Fix the dispatch, as today for zcode exit 2 [D1 §5.4] |

Codex companion jobs have no errorClass. With the overlay they map to `retry`: one `--fresh` retry, as today. Today a second failure goes to the user [00 §1.5]; under `route` it goes to the next channel, and only `route: NONE` asks.

**Kill switch**: one mechanism with aliases. This resolves D1's overlapping switches [J3].
- **`SP_DISABLE_CHANNELS`**: a comma list of profile names, `family:<f>`, `plan:<p>`, `harness:<h>`, or `profiles`. `profiles` disables every agent-dispatch profile, so routing collapses to today's built-ins [D3 §5.5]. Both `route` and `task` check it; `task` refuses with exit 2 `disabled`.
- **`"enabled": false`** in `profiles.json`.
- **Session phrases** "без <channel>" and "через <channel>" are written to the channel marker.
- **Legacy, unchanged:** `SP_IMPLEMENTER=luna`, "через Luna" and "без GLM" [00 C6].
- **Policy-level:** a plugin update that flips a row to `no` disables that pair everywhere [07 §6.6].

**Concurrency**:
- one write task per working tree, enforced across both core wrappers by the shared locks root;
- the width cap of 2 write tasks counts every channel;
- per-profile and per-`quotaGroup` slots;
- one slot per local `baseUrl` on 16 GB [08 §10 #10–11; D4 §5.6];
- reviewer tasks take no reservation [00 R2].

### 3.8 Orchestrator and skill changes

| Coupling [00 §3] | Change |
|---|---|
| C1 resolution + **gate allowlists** (SKILL.md:46, :61–72) | Add the `$ADISPATCH` resolution snippet. Allow `"$ADISPATCH" status\|doctor\|doctor --probe\|profiles\|route` and `cat` of channel markers while the gate is armed. Add `"$ADISPATCH" task\|result\|cancel\|release-stale` wherever the `$ZDISPATCH` equivalents are listed (D1's omission [J1]) |
| C2 recovery prefix map | `at-` → `$ADISPATCH`, alongside `zt-` and `task-` |
| C3–C5 suffix, state line, marker | `.<channel>.md`/`.id`; `impl=<channel>:<id>`; `ch=<name>:<unprobed\|ok\|down\|off>[,…]`; marker `<scratchpad>/dev-orchestrator/channel-<name>` |
| C6, C7, C14, C20 kill switch, ladder, oversize, GLM concurrency | Replaced by `route` (§3.7). The ladder leaves prose. SKILL.md:368–376, :558 and :659 shrink to "run `route`, dispatch the printed line" |
| C9, C10 model split, family rule | Role rows name routing keys; family comes from the `route`/`profiles` output; reviewers pass `--writer-family` |
| C11 checklist items 5 and 10 | One item: the channel line comes from `route` this turn; flags copied verbatim; `--phase-risk` from `risk_phases`; the preamble `route` names (`headless-unsandboxed` for T0, `headless-sandboxed` otherwise [D3 §7.2]) |
| C12, C13 failure ladder, stale reservation | The errorGroup table; the stale-reservation procedure applies to both core wrappers, with `<dispatcher>:` string prefixes |
| C19 status discipline | `status` on `$ADISPATCH` (which also covers `zt-` jobs through the shared core state) and on `$DISPATCH` |
| C21 reviewer dispatches (Inc 3) | Channel-neutral dispatch lines in SKILL.md (:299–309, :514, :555), `codex-plan-reviewer-prompt.md`, `codex-control-review-prompt.md`, `final-review-prompt.md`, `brainstorming/spec-reviewer-prompt.md:8–21`, `requesting-code-review/SKILL.md:96`, `systematic-debugging/SKILL.md:276–278` [00 §3 C21], plus `brainstorming/SKILL.md:221` and `writing-plans/SKILL.md:59` [J1] |
| C17, C18 preamble, switch notice | "Headless preamble (every wrapper channel)"; `<displayName>` and `job <channel>:<id>` |
| C22 Red Flags | Generic: never bypass `route` or a dispatcher; never handle credentials in chat; never run `key set` or edit `profiles.json`/policy; never give a risk phase to a channel `route` did not print; never call a harness binary directly |
| New skill | `skills/agent-invocation/SKILL.md` (manual-only, about 170 lines): resolution, setup, verbs, refusal and errorGroup tables, Never-do. Added to `PIPELINE_SKILLS` in `tests/test-pipeline-context.sh` |
| **Byte budget** [D3; J1] | `dev-orchestrator/SKILL.md` must not grow beyond 127,637 bytes, enforced by a test. Moving the ladder into `route` should shrink it. `zcode-invocation` becomes a pointer plus its verified facts |

### 3.9 Migration of the GLM and Codex channels

**GLM (zcode-dispatch):**
- **Inc 0:** zero surface change: same verbs, `zt-` ids, `ZCODE_STATE_DIR`, `api-key set`, quoted strings and `SP_IMPLEMENTER=luna` refusal. Acceptance: 110 PASS unchanged [D1 §8.1].
- **Inc 1:** its reservations move to the shared locks root. A test proves that a `zt-` task and an `at-` task cannot hold the same tree.
- **Inc 2:** `glm` becomes a built-in route row (T0, quota group `zai-coding-plan`). The orchestrator treats it like any channel.
- **A `/dev` run already in progress** resumes across the upgrade. The built-in channel names stay `glm`, `luna` and `sol`, so `.glm.md`/`.luna.md` dispatch files, `glm:zt-…`/`luna:task-…` sidecars and the `zt-`/`task-` prefix map resolve as before [D2 §8.1]. The skill reads an existing `glm-channel` marker once and rewrites it as `channel-glm`, so a `down` state survives without a new probe [D3 §8.1].
- **Optional A/B:** `glm-cc` runs the same model on the same plan through Claude Code, which Z.ai lists (ZA2). It gains stdin transport (no 200 KiB cap), a T2 Bash sandbox and fast failure; it may lose ZCode's 1.5× usage bonus [06 §2.1]. Switching is the user's edit: `"implementer": ["glm-cc", "glm"]`.

**Codex (companion):**
- **OpenAI models stay on `bin/codex-dispatch`** with the ChatGPT login: Astra, Luna and Sol (sanctioned, OA3/OA5).
- **Inc 2 overlay:** `result` exits 1 on a non-completed job, and a dead worker pid reads as `failed`/`crash`.
- **Third-party models never go through the companion,** whose `clientInfo.name` would read "Claude Code" to the provider. They use `codex-exec` (Inc 4) [05 §14, §16].
- **Moving OpenAI channels onto the core** (lock, timeout, reaper, errorClass) is possible later, but not needed [D1 §8.2].

---

## 4. Delivery roadmap

**Test terms used below:**
- **Stub:** env-selected fake harness binaries with trap modes, as today [00 §5].
- **Local-real:** the real harness binary against a loopback stub with dummy tokens; opt-in through `AGENT_REAL_HARNESS=1` [D1 §9].
- **LIVE:** the user's own keys against real providers; the user runs `key set` and approves each paid call.

| Inc | Scope | Tests | Size | LIVE validation (the user's keys) |
|---|---|---|---|---|
| **0** Core extraction | `dispatch-core.mjs` (≈1,150 moved lines) and `adapters/zcode.mjs` (≈480 moved); zcode entry ≈40 lines; dispatcher-name-parameterized messages | `tests/test-zcode-dispatch.sh` unchanged, 110 PASS; `node --check`; no diff under `tests/` | ≈1,700 moved + ≈120 new; 1–2 days | `"$ZDISPATCH" doctor --probe` and one tiny task; the record matches a pre-refactor record field for field |
| **1** `agent-dispatch` + `claude-compat` (ad hoc, via `agent-invocation`) | Entry, policy (full 07 §5 rows), presets, `key set\|clear\|status`, `profile add`, `profiles check`, the `claude-compat` adapter, `reduce()`, the `requiredFlags` doctor, the shared locks root and slots, L3 checks with the all-keys scan | Stub dialect `claude-json` with trap modes: `exit0-error`, `sigint-empty`, `sigterm-143`, `auth401`, `quota429`, `throttle429`, `model404`, `too-long`, `max-turns`, `refused-conn`, `hang`, `leak`, `late-session` [D4 §9.2; J2]. Policy refusals: no row, `no`, gray without opt-in, host mismatch, `sk-sp-` key, Anthropic host, claude.ai login in home. Kill switches, slots, cross-wrapper lock. **Local-real:** repo `.claude/settings.json` redirect does not get the token (E9 replay); Bash cannot see the token (E13) or `cat keys/*` (the J2 canary); UA carries no `claude-desktop` (E23); a sandboxed test command runs and a write outside the tree is blocked; resume works; deny-rule and `sandbox.*` syntax pinned; recorded dialect fixture saved | ≈1,100 code + ≈900 tests + ≈170 skill; 5–6 days | (1) `key set` + `doctor --probe` for `ds-pro` (DeepSeek PAYG) and `glm-cc` (GLM plan). (2) One small implement job per profile in a scratch repo: line-1 token, report file written, no `permission_denials`. (3) Provider dashboards show the expected billing type (plan vs standard key [06 §1.3]). (4) A wrong key gives `auth` within a minute. (5) The provider accepts the single Bearer header |
| **2** Routing in the pipeline (**MVP complete**) | `route`/`explain`; the §3.8 SKILL.md edits except C21, including the gate allowlists; `implementer-prompt.md`; `glm` built-in row; companion overlay; byte-budget test | `test-pipeline-context.sh` gains `agent-invocation`; `test-channel-text.sh` fails on leftover hardcoded `glm=`/`.glm.md`; golden `route` output for no file, the default file and the §3.5 file; budget test | ≈150 lines touched + ≈150 test lines; 2–3 days | (1) A `/dev` run on a two-phase toy plan with `implementer = ["ds-pro"]`. (2) A forced wrong key: announced fallback to Luna, `ch=ds-pro:down` marker, recovery after `/compact`. (3) A default-routing run behaves identically to v0.11.1 |
| **3** Reviewer role | Core `--role reviewer` (no reservation), `--writer-family` union, `--same-family-ok`; `claude-compat` reviewer argv; L3 read-only ref check; C21 sites | Stub: a reviewer runs while an implementer holds the tree; argv has no Bash/Edit/Write; family refusal. **Local-real:** a reviewer told to write leaves the file unchanged with a non-empty `permission_denials`; reading a git-ignored review package by path works | ≈300 lines; 2 days | A Step 4.2 control review by `kimi-k3` on a GLM-written diff, side by side with Astra on the same package: verdict token, 4.2 item fields (`authorization_relation`, `why_now`, `minimal_fix`) [00 §4.2 R4]. One Step 2 plan review by `kimi-k3` |
| **3b** Setup UX (optional, parallel) | `add <preset>` wizard (TTY and `--key-stdin --yes`), `setup` discovery, `presets --for <role>`, `key list`/`where` (refs only), display names [D2 §4.5; J3] | Golden outputs; non-TTY path | ≈400 lines; 2–3 days | You add one profile end to end without reading docs |
| **4** `codex-exec` (T3) | Adapter (§3.4), per-job secret file + reaper cleanup, per-profile `CODEX_HOME`, permission profile, `riskEligible` + M9 gate, `--phase-risk` routing, OS read-only reviewer variant | Stub dialect `codex-jsonl` (`thread.started`, `turn.failed`, the exit-0 error item); flag order with `resume`; SIGINT-first ladder with sweep; the 05 §11 classes. **Local-real** (codex 0.163.0 + Responses stub): write outside the tree, `curl` and `cat keys/*` all fail; `printenv` shows no key; `-s read-only` blocks writes | ≈450 code + ≈600 tests; 3–4 days | (1) `glm-cx` probe and one ordinary phase. (2) The same canaries against the real provider. (3) With your explicit go-ahead, one SECURITY-tagged phase in a toy repo, reviewed by Opus and Astra. (4) You accept the data note: requests carry the workspace path and git HEAD [05 Bottom line] |
| **5** OpenCode v1 + shared srt layer (opt-in) | OpenCode adapter (XDG isolation, explicit permission ruleset, deny-all reviewer agent with no bash, v1 pin with v2 refusal, `profile env` for harness logins). srt layer: per-job settings, fail-closed preflight, no proxy env, `allowLocalBinding:false` | Stub dialect `opencode-jsonl` (auto-reject stop, exit 1 after recovered compaction, stdin close); srt preflight refusals | srt ≈300 + adapter 500–700 + tests; 1–1.5 weeks | (1) You install srt 0.0.81 globally, outside any workspace. (2) The 09 §10 smoke matrix: PONG under srt + mask, `printenv` shows the sentinel, streaming and SSE gaps survive, the reflection test is caught by the scan, the :1082 canary fails. (3) An OpenCode Go reviewer run. (4) A Copilot login in the isolated home; doctor confirms `enabled_providers` |
| **6** pi | Adapter (API keys; ChatGPT only through the subscription flow; Anthropic/Copilot logins refused; session-file check before resume) | Stub dialect `pi-jsonl` (exit 0 on provider error, unknown session id) | 500–700 + tests; 3–5 days | A pi reviewer on a PAYG key; a ChatGPT-subscription login in the isolated home, with doctor confirming the auth type; a pi implementer under srt passes the smoke matrix |
| **7** dsh (+ optional ACP) | Adapter (pinned `baseURL`, session log/inventory/title off, `DSH_AGENTS_HOME` empty, YAML patch for model/effort). Reviewer with native read-only first; implementer only under srt with its own sandbox off. ACP client only if guarded mode is wanted | Stub dialect `dsh-ndjson` (SIGTERM exit 0, late session event, detached children); ACP stub validated against the vendored v1 schema | 500–700 (+400–600 ACP); 4–6 days | Requests go only to `api.deepseek.com`; no session-log field is sent (request capture through the srt proxy log); one read-only review |

**MVP = Inc 0 + 1 + 2, about two weeks** [J1]. It delivers multi-provider implementers in the pipeline with today's defaults intact.

**Order after the MVP:**
- Inc 3 comes next, because it is cheap and reuses Inc 1.
- J1 and J2 put `codex-exec` (Inc 4) before OpenCode, for the risk path.
- J3 would put OpenCode first, for the subscription unlock.
- This is decision D2 in §5.

---

## 5. Decisions for the user

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | Which keys to set up first | (a) DeepSeek PAYG (cheapest, PRC data); (b) Kimi Platform PAYG (strongest cross-family reviewer evidence); (c) GLM plan via `glm-cc` (A/B against ZCode); (d) MiniMax/Qwen PAYG | **(a) + (c) for Inc 1, (b) for Inc 3.** That covers one new implementer family, the harness A/B on the model you already use, and a reviewer [06 §4, §6] |
| D2 | Order after the MVP | (a) `codex-exec` first (risk phases on GLM, OS read-only reviewers); (b) OpenCode first (Copilot, OpenCode Go, ChatGPT Plus/Pro subscriptions) | **(a)**, unless you hold Copilot or OpenCode Go and want them soon. Then (b), but its implementer role waits for the srt smoke matrix [J1; J3] |
| D3 | The GLM default channel | (a) keep ZCode `glm` first; (b) put `glm-cc` first; (c) A/B on real phases, then decide | **(c)**, keeping (a) until the A/B shows `glm-cc` is not worse on quota and quality [D1 §8.1] |
| D4 | DeepSeek (stored in the PRC, no no-training promise) | (a) allow for non-risk implementer phases with a doctor WARN; (b) refuse entirely | **(a)**. It is already excluded from risk phases by M9 [06 §2.2; 09 §9] |
| D5 | Gray plans (Kimi Code membership, MiniMax M Plan) | (a) ship the rows as gray, with a one-time user opt-in; (b) refuse them | **(a) shipped but off**; use PAYG keys for those providers instead [07 §5] |
| D6 | Alibaba Token Plan | (a) `no` until Alibaba clarifies; (b) gray | **(a)** [06 §1.2] |
| D7 | Local models on this Mac | (a) ship a disabled template only; (b) wire an advisory log summarizer | **(a)**. Revisit on a ≥32 GB machine [08 §9] |
| D8 | Default reviewers | (a) keep Astra first; Kimi K3 as an opt-in alternative; (b) Kimi K3 first for GLM-written code | **(a)**, until the Inc 3 side-by-side LIVE comparison [06 Bottom line 5] |
| D9 | dsh | (a) build on demand (Inc 7), reviewer first; (b) skip | **(a) on demand only.** `claude-compat` already reaches DeepSeek; dsh adds DeepSeek's own harness and a guarded ACP mode [04b; 10] |
| D10 | srt adoption | (a) opt-in with Inc 5, installed by you; (b) never; (c) in the MVP | **(a)**. It is a beta with an experimental `tlsTerminate`, and it is not needed for `claude-compat` or Codex [09; J1; J2] |
| D11 | Codex companion | (a) keep for OpenAI models with the small overlay; (b) migrate onto the core | **(a)** [D1 §8.2] |
| D12 | `claude-compat` key transport | (a) env + scrub + sandbox credentials deny; (b) `apiKeyHelper` | **(a)**. (a) was verified end to end [01 E13]; `apiKeyHelper` sends both auth headers [01 Fact-check] |
| D13 | Third-party models on SECURITY/DATA_LOSS phases (e.g. `glm-cx`: GLM through `codex-exec` in the OS sandbox) | (a) keep today's rule: risk phases only on OpenAI models through the companion (Sol); (b) allow `riskEligible` third-party profiles after the Inc 4 LIVE canaries, PAYG keys only; (c) as (b), subscription keys too | **(a) until Inc 4 is LIVE-validated, then (b)** if you want it. The sandbox bar is met by `codex-exec` [09 §9], but the data bar (M9) is clear for PAYG keys only: Z.ai's no-storage DPA names API content, not Coding Plan traffic [06 §2.1] |

---

## 6. Risks and open questions

| # | Risk or question | Mitigation or next step | Source |
|---|---|---|---|
| 1 | Claude Code ships near-daily; flags and settings keys can drift | `requiredFlags` doctor check, accepted version range, recorded dialect fixtures, local-real re-run on every bump | [01 §1; D4 §3.7] |
| 2 | Does `--setting-sources ""` plus `--settings` keep `sandbox`, `permissions` and `denyRead` in non-bare mode? E9, E13 and E18 cover the parts separately | Settled by the Inc 1 local-real test before any LIVE run | [01 §9; D1 §10] |
| 3 | Headless self-use of the GLM plan in a listed tool is not addressed in writing (ZA3 targets "on behalf of others") | Same exposure as today's ZCode channel; the policy row records it. A written answer from Z.ai support would close it | [07 §7; 06 §7 Q1] |
| 4 | T2 limits: tests that bind localhost or need the network fail inside the Bash sandbox (`allowLocalBinding` stays off because of the :1082 proxy) | The implementer reports `DONE_WITH_CONCERNS`; the Step 3.5 gate runs those tests outside | [09 §6; D1 §10] |
| 5 | The grandfathered T0 ZCode channel can read other profiles' keys | Doctor WARN; optionally run ZCode under srt later (needs the `ZCODE_HTTP_PROXY` userinfo check); macOS cannot mask its file key | [09 §7.3, §8; J2] |
| 6 | Quality of non-GLM implementers on this repo is unmeasured | A/B before reordering routing (Inc 2 and 3 LIVE runs) | [06 Bottom line 5] |
| 7 | Data jurisdiction: DeepSeek PRC; Moonshot and MiniMax may use inputs; Codex sends the workspace path and git HEAD | M9 gate for risk phases; doctor WARNs; per-profile `note` | [06 §2; 05 Bottom line; 09 §9] |
| 8 | srt: beta, `tlsTerminate` experimental, no response scrubbing, Keychain readability inside the sandbox unverified | Opt-in only; post-job scan; the 09 §10 smoke matrix before any T2 claim | [09 §2.4, §10] |
| 9 | srt masking a subscription key (Z.ai plan): is a local header swap use "outside such tools"? | No masking of subscription keys until clarified | [09 Fact-check] |
| 10 | OpenCode v2 is the Homebrew default and changes `run` semantics | Pin v1; doctor FAILs on v2 | [02 Bottom line] |
| 11 | dsh is a prerelease; the session-log upload and `baseURL` redirect are on by default | Exact pin, `baseURL` pin, features off, reviewer-first | [04b Bottom line 5; 04 Fact-check] |
| 12 | Provider quirks: Kimi Anthropic `tool_choice` has no `tool` type; K2.7 Code and M3.1-Flash cannot disable thinking; strict upstreams may reject beta fields | Per-preset capability flags; `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` is on the env allowlist | [06 §1.4, Fact-check; 01 Bottom line] |
| 13 | Auto permission mode on non-Claude models is unproven | Not used; implementers run in `acceptEdits` with explicit tools | [01 Fact-check] |
| 14 | `total_cost_usd` is meaningless for third-party endpoints | Records keep tokens only; `timeoutMin` is the only budget | [01 §13] |
| 15 | Open: Anthropic's "third-party apps" wording (AN4 vs AN8). Irrelevant here because no Claude subscription is routed, but it is recorded | — | [07 §7] |
| 16 | Open: DeepSeek server-side Search/Fetch are free from Claude Code only until 2026-10-31 | WebSearch and WebFetch are denied in every profile anyway | [06 §2.2] |
| 17 | Open: whether every provider accepts Claude Code's `role:"system"` entries and beta body fields | Each Inc 1 LIVE probe and small job confirms its provider | [01 §15.10] |
| 18 | Linux is untested here: every local run was on macOS. Known differences: harness sandboxes and srt use bwrap; nested user namespaces are refused, so the never-nest rule holds there too; the sandbox loopback is private, so the :1082 hole and the localhost-test limit of risk 4 do not apply; srt file masks work, though masking the ZCode plan key still waits on risk 9; zcode-dispatch caps the argv prompt at 120 KiB | Run the local-real tests of each increment on Linux before a Linux user enables a profile | [09 §2.2, §2.5, §6, Fact-check; 00 §1.1] |

---

## 7. Appendix: report and proposal index

| File | One line | Fact-check reliability |
|---|---|---|
| [00-current-architecture.md](universal-dispatchers/00-current-architecture.md) | The de-facto dispatcher contract, a function map of `zcode-dispatch.mjs` (≈70% generic), 25 coupling points, adapter requirements, the 110-test oracle | Code read plus a local test run; no separate fact-check log. Repo facts spot-checked by the judges |
| [01-claude-code-headless.md](universal-dispatchers/01-claude-code-headless.md) | `claude -p` against third-party endpoints: isolation, the repo-settings key redirect, env scrub, error matrix, signals, adapter sketch | High (30 confirmed, 8 corrected, 1 unverifiable) |
| [02-opencode.md](universal-dispatchers/02-opencode.md) | OpenCode v1 `run --format json`: catalog, permissive defaults, XDG isolation, the v1/v2 split | High (30 / 7 / 1) |
| [03-pi.md](universal-dispatchers/03-pi.md) | pi `--mode json`: 42 providers, no sandbox or permissions, impersonating logins to refuse | High (23 / 2 / 1) |
| [04-dsh-and-harness-survey.md](universal-dispatchers/04-dsh-and-harness-survey.md) | Identifies DSH; surveys about 20 other headless harnesses and their output and permission families | High (jointly with 04b: 36 / 10 / 1) |
| [04b-deepseek-harness.md](universal-dispatchers/04b-deepseek-harness.md) | dsh headless contract, fail-closed permissions, session-log upload and `baseURL` pinning, cancellation | High (see 04) |
| [05-codex-multi-provider.md](universal-dispatchers/05-codex-multi-provider.md) | Codex with custom Responses providers: stub experiments, must-fix defaults, the `codex exec` runner sketch | High (24 / 4 / 2) |
| [06-providers-and-plans.md](universal-dispatchers/06-providers-and-plans.md) | Endpoints, typed keys, plan terms, prices, benchmarks, data policy, role fit | High (36 / 8, 1 refuted: "TB 3.0 is the only independent score") |
| [07-tos-matrix.md](universal-dispatchers/07-tos-matrix.md) | Plan × harness ToS matrix with an evidence register; safe / gray / no-go verdicts | High (33 / 4) |
| [08-local-models.md](universal-dispatchers/08-local-models.md) | Local servers, the 16 GB hardware limit, memory tiers, role fit, failure modes | Medium (29 / 7, 1 refuted: "llama-server silent during prefill") |
| [09-sandboxing-and-credentials.md](universal-dispatchers/09-sandboxing-and-credentials.md) | srt, native sandboxes, key-custody patterns, egress, the L0–L3 layers, the M1–M9 risk bar | High (32 / 6 / 1) |
| [10-acp-universal-transport.md](universal-dispatchers/10-acp-universal-transport.md) | ACP v1 maturity, harness coverage, broker limits; the hybrid recommendation | High (21 / 6) |
| [design/D1-incremental.md](universal-dispatchers/design/D1-incremental.md) | Grow the working dispatcher, MVP first; `claude-compat`, then `codex-provider` | Judges: feasibility 8, safety 7.5, user value 6.5 (**skeleton of §3**) |
| [design/D2-user-config.md](universal-dispatchers/design/D2-user-config.md) | User-facing surface: presets, wizard, `pick`/`explain`, errorGroups | Judges: 5.5, 4.5, 8 (UX grafts) |
| [design/D3-security.md](universal-dispatchers/design/D3-security.md) | Security-first: tiers, srt, no key-returning verb, security-event question, data-use gate | Judges: 4.5, 8, 4.5 (invariant grafts) |
| [design/D4-abstraction.md](universal-dispatchers/design/D4-abstraction.md) | Abstraction-first: `reduce()`, manifest with `requiredFlags`, `downProfiles`/`quotaGroup`, full policy | Judges: 6.5, 5.5, 7.5 (core and policy grafts) |
| [J1]–[J3] judge verdicts — [design/judgments.md](universal-dispatchers/design/judgments.md) | Feasibility, safety and user-value scoring of D1–D4: scores, strengths, flaws, grafts, factual errors found | Saved verbatim from the design workflow |
