# ZCode CLI findings — discovery for the GLM implementer channel

- ZCode.app: 3.15.1 (3.15.1.8093)
- Embedded CLI: zcode 0.16.9
- Source tag read: v3.15.1 (`gh api -H 'Accept: application/vnd.github.raw' repos/zai-org/ZCode/contents/<path>?ref=v3.15.1`)
- Node: v26.11.0 (`/opt/homebrew/bin/node`)
- Date: 2026-10-13
- Method: source reading at the tag above, plus direct CLI runs (discovery-only exception — the wrapper did not exist yet) against throwaway git repos. Nothing under `~/.zcode` was read; the executor made no login/logout, settings or plugin change. The user ran the one-time `zcode login zai` (U1), with the personal provider config pointed at a probe-owned file.
- Network (this machine): the CLI's own HTTP client takes a proxy only from its config `network.httpProxy` or the env variable `ZCODE_HTTP_PROXY`. It ignores `HTTPS_PROXY`/`HTTP_PROXY` and the macOS system proxy, which is 127.0.0.1:1082 here; the desktop app (Chromium) uses that system proxy. The user's `zcode login zai` failed with `Error: fetch failed` (`HttpClientPortError` in the `POST https://zcode.z.ai/api/v1/oauth/cli/init` call) until `ZCODE_HTTP_PROXY=http://127.0.0.1:1082` was added. All model runs in this spike went from Claude Code's Bash straight to `https://api.z.ai/api/anthropic` and worked without it: DNS answers with a 198.18.x fake-IP, the address a TUN-mode proxy client uses for interception. Whether a given shell needs `ZCODE_HTTP_PROXY` therefore depends on the machine's proxy client; the CLI never picks the system proxy up by itself.

## Go / no-go

VERDICT: GO

## U1 — how a headless `-p` run receives the model
- Answer: A fresh headless run takes the `defaultModelSelection` stored under `config` in the personal provider config file named by `ZCODE_PERSONAL_PROVIDER_CONFIG_FILE` (default `~/.zcode/v2/provider_config.json`). The selection only counts if the provider is entitled, and the standalone CLI's Coding Plan provider is entitled only after the CLI's own `zcode login zai`. That login writes `account-provider:<id>:identity` into ZCode's credential store; the desktop app's login does not do this for the CLI. With no valid default, the CLI silently falls back to the first registry model at its highest reasoning level. With no entitled model at all, it fails with `Error: Model creation failed`.
  - No headless model selection exists besides this file: no `--model`/`--effort` flag and no model env variable. The embedded CLI ships without its TUI (`Cannot find package '@zcode/tui'`), and headless `-p '/model …'` is sent as plain prompt text.
  - The user ran `zcode login zai` once, with `ZCODE_PERSONAL_PROVIDER_CONFIG_FILE` pointing at a probe-owned file. The login wrote `{"schemaVersion":1,"config":{"providerConfigRules":{"providerRules":[]},"modelConfigRules":{"providerModelRules":[],"manualProviderModelRules":[]},"defaultModelSelection":{"providerId":"account:zai-individual-coding-plan","modelId":"GLM-5.3"}}}`. Its shape is `schemaVersion:number, config:{providerConfigRules:{providerRules:array}, modelConfigRules:{providerModelRules:array, manualProviderModelRules:array}, defaultModelSelection:{providerId:string, modelId:string}}`, with no credential-like value.
  - The default was then pinned to `{"providerId":"account:zai-individual-coding-plan","modelId":"GLM-5.3-Flash","options":{"reasoningLevel":"max"}}`. That matches the bundle's strict selection schema `{providerId, modelId, options?:{reasoningLevel?}}`.
  - Probe 2 then ran a fresh PONG. It exited 0, `response` was `PONG`, and the session was `sess_aa3d8b5a-…`. The model evidence comes from the stream run (`--output-format stream-json --verbose`): the only model-identifying matches are 3× `"modelId":"GLM-5.3-Flash"`. Each sits under `"providerId":"account:zai-individual-coding-plan"` in the `session.updated` / `model_request_started` / `model_request_completed` events. Those events carry `"baseURL":"https://api.z.ai/api/anthropic"` and `"reasoning":{"capability":"unknown","requestedControl":"provider_default","requestedState":"provider_default","requestedLevel":"max","effectiveControl":"unknown","effectiveState":"unknown","effectiveLevel":"unknown"}`. So the run used GLM-5.3-Flash, and its only reasoning level was the requested `max`. The CLI does not report an effective level (`unknown`), and the request control is `provider_default`.
- How verified:
  - Source at v3.15.1:
    - `arguments.ts` uses strict `parseArgs` and has no model flag.
    - `prompt-command.ts` passes `configuredDefaultModelSelection` and `resume` to `createApp`.
    - `provider-runtime-env.ts` defines the personal config path and `ZCODE_PERSONAL_PROVIDER_CONFIG_FILE`.
    - `runtime-model.ts` holds the `Select a model before continuing` throw.
    - In `command-center/handlers/model.ts`, `/model` saves the default, but only in the TUI command center. Headless, only `/expert` and `/goal` route there.
  - Bundle `zcode.cjs`:
    - Initial resolution (`Yoc` / `oQe`): `if(e.resume)return;` and then `configured-default` → `registry-fallback` → `none`.
    - `NodeModelSelectionConfigRepository.read()` returns `defaultModelSelection`.
    - Account entitlement (`FNn`) needs the `account-provider:<id>:identity` credential.
    - The login (`jNn`) saves the provider's first `builtinModelIds` entry as the default.
  - Live runs:
    - Probe 1, before the login: exit 1, `Error: Model creation failed (traceId: …)`; `--verbose` adds `Cause: Error: Select a model before continuing`.
    - Headless `-p '/model'` failed the same way.
    - The user's login printed `Model: account:zai-individual-coding-plan/GLM-5.3`.
    - Probe 2 (`pong2.out`) and its stream counterpart (`pong2s.out`) ran on the pin and gave the evidence above.
- Holds for: ZCode 3.15.1 (zcode 0.16.9)
- Design consequence: `MODEL_MECHANISM = personal-config`.
  - The wrapper owns its personal provider config, `<ZCODE_STATE_DIR>/personal-provider-config.json`. It passes the file as `ZCODE_PERSONAL_PROVIDER_CONFIG_FILE`, and before every run it writes `PERSONAL_CONFIG_BASE` with `PINNED_SELECTION` at `SELECTION_PATH`.
  - The user's one-time `zcode login zai` is a prerequisite (on this machine with `ZCODE_HTTP_PROXY=http://127.0.0.1:1082`). The login should also point `ZCODE_PERSONAL_PROVIDER_CONFIG_FILE` away from `~/.zcode/v2/provider_config.json` so the desktop app's selection is untouched.
  - A PONG alone does not prove the pin, because an invalid pin silently falls back to `GLM-5.3`. Only the stream events name the model, and the JSON summary does not (U3). Doctor/probe can therefore confirm entitlement, but it cannot confirm the model from the `json` output.
  - The effective reasoning level is not observable (`effectiveLevel:"unknown"`).

## U2 — does `--resume` keep model and effort
- Answer: Yes.
  - Live: `--resume sess_aa3d8b5a-…` exited 0 with the same `sessionId` and `response` `PONG2`. A resume probe after SIGTERM also exited 0 (U7).
  - Source: a resumed run skips the configured default (`if(e.resume)return;` in `Yoc`) and uses the session's own bound selection. `runtime-unbound-resume.test.ts` shows two things. A resumed session without a bound selection is not given one from history and fails with `Select a model before continuing`. Once a session has a selection, `getSessionModelSelection()` returns the full object including `options.reasoningLevel`.
  - So a successful resume means the session's bound selection, GLM-5.3-Flash with reasoning `max`, was restored. A later change of the default does not affect resumed sessions.
- How verified: `resume.ts`, `runtime-unbound-resume.test.ts` and the bundle's `Yoc` read at v3.15.1. Live run `zc -p 'Reply with exactly one word: PONG2' … --resume sess_aa3d8b5a-28a3-4f73-aff0-d4ceb88e4e72` → exit 0, same `sessionId`.
- Holds for: ZCode 3.15.1 (zcode 0.16.9)
- Design consequence: fix rounds may resume the GLM session (`--resume <sessionId>`). The model and effort are those bound when the session started; they are not re-read from the pin.

## U3 — effective model in the JSON; `usage` field names and semantics
- Answer: The `--output-format json` summary has the keys `sessionId traceId turnId response usage eventCount projection`. `turnResponses` appears only for multi-turn runs and `workspaceHookTrust` only when a project hook is blocked. **No model field.** `usage` is `{"source":"provider","modelRequestCount":1,"inputTokens":14011,"outputTokens":35,"totalTokens":14046,"cacheReadTokens":7872,"cacheWriteTokens":0,"reasoningTokens":0,"webFetchRequests":0,"webSearchRequests":0}`. How the counts relate:
  - `inputTokens` already includes cache read and cache write; `cacheReadTokens` is a subset of it.
  - `reasoningTokens` is a breakdown inside `outputTokens`, not an extra counter. The AI SDK v6 adapter in the bundle sets `outputTokens = outputTokens.total` and `reasoningTokens = outputTokens.reasoning`.
  - `totalTokens = inputTokens + outputTokens`. Every run confirms it: 14011+35=14046, 14057+20=14077, 33200+14=33214.
  - The model id appears only in the stream-json events (`payload.modelId` / `payload.providerId` of `model_request_started`).
- How verified: `prompt-command.ts` JSON summary at v3.15.1. `turn-model-step-usage.ts`: "AI SDK v6 已把 Anthropic cache read/write 并入 inputTokens", with hit rate = `cacheReadTokens / inputTokens`. The bundle's usage adapter (`outputTokenDetails.reasoningTokens` = `reasoningTokens` = `outputTokens.reasoning`). Live `pong2.out`, `resume.out`, `p150.out`.
- Holds for: ZCode 3.15.1 (zcode 0.16.9)
- Design consequence:
  - `REPORTED_MODEL_PATH = null` (`reportedModel` stays null; `doctor --probe` prints `reported-model: unreported`).
  - `USAGE_FIELDS = {input: "inputTokens", cached: "cacheReadTokens", output: "outputTokens"}`.
  - Reasoning is billed inside output, so the Ф5 measurement needs no separate reasoning counter. Every probe so far reported `reasoningTokens: 0` even at requested `max`.

## U4 — error strings and exit codes (auth, model-not-selected, quota, hang)
- Answer: Every failure prints `Error: <message> (traceId: <uuid>)` on stderr and exits 1. `--verbose` adds `Cause:` and a stack.
  - **Model not selected / no entitled model:** `Error: Model creation failed (traceId: …)`. The cause, `Select a model before continuing`, is printed only with `--verbose`.
  - **SIGTERM:** exit code 143, stderr `Error: Turn was cancelled. (traceId: …)`, and stream event `model_request_failed`.
  - **Empty prompt:** `--prompt requires non-empty text.`, exit 1.
  - **Auth** (bundle, not provoked): HTTP 401/403 → `Provider authentication failed.`
  - **Quota/rate** (bundle, not provoked):
    - 429 → `Provider rate limited the model request.`
    - Quota provider codes are mapped to non-retryable rate limiting: `insufficient_quota`, `credit_balance_exhausted`, `organization_spend_limit_exceeded`, `project_spend_limit_exceeded`, `organization_usage_limit_exceeded`, `exceeded_current_quota_error`, and Z.ai codes `2056`, `20097`, `1316`–`1321`.
    - Account-level: `quota_exceeded`, `coding_plan_required`.
  - **Server:** 529 → `Provider is overloaded.`; 5xx → `Provider returned a server error.`
  - **Startup** (source): `Failed to load environment file: <path>`, `ZCode app factory is unavailable.`, `Provider Registry runtime is unavailable.`. The TUI-less bundle yields `Cannot find package '@zcode/tui' …`.
  - **Network:** `Error: fetch failed` (login, see header).
  - Retries: the CLI retries provider calls itself (`maxAttempts: 11` in `model_request_started`).
  - **Benign stderr on every run, including successful ones:** `ZCode Built-in 刷新失败: EPERM: operation not permitted, mkdir '/Applications/ZCode.app/Contents/Resources/config/provider/zcode-builtin-refresh.json.lock'`. It appears because `ZCODE_BUILTIN_PROVIDER_CONFIG_FILE` points into the read-only app bundle, so the CDN refresh cannot take its lock. The run still succeeds on the bundled config.
  - The bundle has no `not logged in` / `token expired` literal. Auth and quota failures were not provoked: no logout, no quota exhaustion.
- How verified: `prompt-command.ts` (catch → `Error: …`, return 1), `runtime-model.ts`, `process-errors.ts` at v3.15.1. Bundle greps of the provider error table and the quota code lists. Live probe 1, `-p '/model'`, the 6 s SIGTERM probe (`long6.out.err`), and the stderr of every live run.
- Holds for: ZCode 3.15.1 (zcode 0.16.9)
- Design consequence: classify on the exit code first, and use stderr patterns only for failed runs. Two cautions:
  - Before matching, strip the ` (traceId: <uuid>)` suffix: a uuid can contain digit runs such as `401` or `429`.
  - Never treat the `ZCode Built-in 刷新失败 … EPERM … .lock` line as a failure. It contains `EPERM`/`lock`, and none of the patterns below match it.

  Unknown strings stay `crash`.

## U5 — can two `zcode -p` processes run concurrently
- Answer: Yes. Two simultaneous PONG runs in two worktrees of one repo both exited 0 with `PONG`, in separate sessions (`sess_bc2503de-…`, `sess_3a484b16-…`). The plan's `grep -il 'lock\|busy\|sqlite'` matched both stderr files, but the only stderr line in each was the benign `ZCode Built-in 刷新失败: EPERM … zcode-builtin-refresh.json.lock`. That same line appears in every serial run (`pong2.err`, `resume.err`), so it is not a concurrency lock error.
- How verified: Ф1 Step 9 live (`conc.txt`: `wt2 exit=0`, `wt1 exit=0`; `wt1.err` / `wt2.err` contain only the refresh warning).
- Holds for: ZCode 3.15.1 (zcode 0.16.9)
- Design consequence: `GLM concurrency: 2`; two parallel tracks may both run on GLM.

## U6 — what `--disallowedTools` applies to
- Answer: It removes whole tools by name for that run, including plugin-provided MCP tools. The headless tool list was `Agent AskUserQuestion Bash Edit EnterPlanMode ExitPlanMode Read Skill TaskOutput TaskStop TodoRead TodoWrite WebFetch WebSearch Write SendMessage ReadSessionContext ReplyToChannel mcp__node_repl__js mcp__web_reader__webReader`. With `--disallowedTools mcp__node_repl__js` the same list came back without `mcp__node_repl__js`.
  - Headless exposes no browser-use, computer-use or presentations tools. Those plugins contribute only skills here: `plugins list` shows `mcp: none` for every plugin, and Browser Use needs `--browser-use headless`.
  - The two non-built-in tools, a JS REPL and a web reader, are general-purpose rather than "irrelevant to implementation".
- How verified: `arguments.ts` `extractDisallowedToolsArgs` (comma/space-separated, `web_search` → `WebSearch`, passed as `runtimeConfig.toolDisallowlist`) at v3.15.1. Live `tools1.out` vs `tools2.out`.
- Holds for: ZCode 3.15.1 (zcode 0.16.9)
- Design consequence: `DISALLOWED_TOOLS = none`, and the wrapper passes no `--disallowedTools`. The mechanism is verified to cover plugin tools, so a list can be added if a later app version exposes browser/computer-use/presentation tools headless. The preamble stays the restriction.

## U7 — is the session saved on SIGTERM
- Answer: Yes. A SIGTERM to the CLI mid-stream ended it with exit code 143 and `Error: Turn was cancelled.`; the session id `sess_06d2ef73-…` was visible in the stream. `--resume sess_06d2ef73-…` with the PONG prompt then exited 0, with the same `sessionId` and `response` `PONG`.
  - The plan's 20 s probe was not a test: the "count to 300" run finished in under 20 s (exit 0, `result` event), so its SIGTERM hit an exited process. It was re-run with the timer at 6 s (`sigterm-probe6.mjs`).
- How verified: Ф1 Step 10 live (`long.out`, then `long6.out` + `long6.out.err`, then `resume-sigterm.out`).
- Holds for: ZCode 3.15.1 (zcode 0.16.9)
- Design consequence: none. A retry after a timeout is still `--fresh`, and a cancelled job is never resumed.

## U8 — which plugins load headless; any auto-activation
- Answer: `zcode plugins list` (read-only) shows 13 plugins, all from `zcode-plugins-official`, every one with `hooks: 0, mcp: none`.
  - Enabled: visualize, node-repl-host, browser-use, documents, pdf, presentations, spreadsheets, image-search, plugin-creator, skill-creator, zcode-guide.
  - Disabled: ios-simulator, computer-use.

  A `--verbose` headless PONG with `--workflow-mode disabled` printed no plugin, hook or workflow line; the only stderr line was the benign built-in refresh warning. Plugins contribute skills (the `Skill` tool) and the `mcp__node_repl__js` tool, but nothing auto-activates.
- How verified: source `plugins-command.ts` (`list [--json] [--available]`; `zcode plugins --help` prints only the global help) at v3.15.1. Live `plugins-list.txt`, `verbose.err`.
- Holds for: ZCode 3.15.1 (zcode 0.16.9)
- Design consequence: `INTERFERING_PLUGINS = none`; no user action needed.

## U9 — is the 1.5× ZCode quota bonus active
- Answer: Deferred to the live acceptance (plan Ф5, spec §8.2 step 4).
- How verified: —
- Holds for: —
- Design consequence: none for the protocol; measured in Ф5.

## U10 — prompt-size limit of `-p`; does `-p -` read stdin
- Answer: `-p` is a plain string option. Nothing reads stdin for `-p -`, so `-` would be sent as a literal one-character prompt. A 153,492-byte prompt (150 KiB) passed in argv answered `PONG` (exit 0, `inputTokens` 33200). The OS argv check printed `status 0 len 307200`.
- How verified: `arguments.ts` and `run.ts` at v3.15.1: `parsed.values.prompt` goes straight to `runPrompt`, and stdin is read only by the app-server/protocol paths. Live `p150.out` and the spawnSync argv check (`argv-check.txt`).
- Holds for: ZCode 3.15.1 (zcode 0.16.9)
- Design consequence: `PROMPT_TRANSPORT = argv`, `MAX_PROMPT_BYTES = 204800`.

## U11 — what the desktop app sets as `ZCODE_APP_VERSION`
- Answer: The short version, `3.15.1`.
  - In `app.asar`, the `"ZCODE_APP_VERSION"` constant sits in the module that defines the build constant `yh="3.15.1"` (commit `f18d6db7`, built `2026-10-10T06:47:14.105Z`).
  - The main process uses `appVersion: Y||j.getVersion()`.
  - The only `3.15.1…` literal in the 341 MB asar is `"3.15.1"` (6×); `3.15.1.8093` never occurs.
  - The desktop app also sends `X-ZCode-App-Version: <appVersion>`.
  - The app was not running, so there was no `ps` sample.
- How verified: Ф1 Step 3 greps of `/Applications/ZCode.app/Contents/Resources/app.asar` (`ZCODE_APP_VERSION` context; literal count of `3.15.1.<n>` = 0). `plutil` gives `CFBundleShortVersionString` = `3.15.1` and `CFBundleVersion` = `3.15.1.8093`.
- Holds for: ZCode 3.15.1 (zcode 0.16.9)
- Design consequence: `APP_VERSION_PLIST_KEY = CFBundleShortVersionString`, `VERIFIED_APP_VERSION = 3.15.1`.

## Inputs for later phases

| Key | Value | Evidence |
|---|---|---|
| VERDICT | GO | U1 |
| MODEL_MECHANISM | personal-config | U1 |
| SELECTION_PATH | config.defaultModelSelection | U1 |
| PERSONAL_CONFIG_BASE | {"schemaVersion":1,"config":{"providerConfigRules":{"providerRules":[]},"modelConfigRules":{"providerModelRules":[],"manualProviderModelRules":[]}}} | U1 |
| PINNED_SELECTION | {"providerId":"account:zai-individual-coding-plan","modelId":"GLM-5.3-Flash","options":{"reasoningLevel":"max"}} | U1 |
| RESUME_KEEPS_MODEL | yes | U2 |
| REPORTED_MODEL_FIELD | none | U3 |
| USAGE_INPUT_FIELD | inputTokens | U3 |
| USAGE_CACHED_FIELD | cacheReadTokens | U3 |
| USAGE_OUTPUT_FIELD | outputTokens | U3 |
| USAGE_REASONING_FIELD | none | U3 |
| CACHED_IS_SUBSET_OF_INPUT | yes | U3 |
| PROMPT_TRANSPORT | argv | U10 |
| MAX_PROMPT_BYTES | 204800 | U10 |
| VERIFIED_APP_VERSION | 3.15.1 | header |
| VERIFIED_NODE_MAJOR | 26 | header |
| APP_VERSION_PLIST_KEY | CFBundleShortVersionString | U11 |
| DISALLOWED_TOOLS | none | U6 |
| GLM_CONCURRENCY | 2 | U5 |
| SESSION_SAVED_ON_SIGTERM | yes | U7 |
| INTERFERING_PLUGINS | none | U8 |
| PATTERN_MODEL_NOT_SELECTED | Select a model before continuing;Model creation failed | U4 |
| PATTERN_AUTH | 401;unauthorized;not logged in;login;token expired;credential;authentication failed | U4 |
| PATTERN_QUOTA | 429;quota;rate limit;usage limit;insufficient;balance;usage_limit_exceeded;spend_limit_exceeded;coding_plan_required | U4 |
| PATTERN_LAUNCH | ZCODE_BUILTIN_PROVIDER;provider config;Cannot find module;Cannot find package;Failed to load environment file;ZCode app factory is unavailable;Provider Registry runtime is unavailable | U4 |
