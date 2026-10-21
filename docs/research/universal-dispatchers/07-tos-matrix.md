# 07 — Terms-of-service matrix: which plan in which harness, and is headless dispatch allowed

Research date: 2026-10-20. All web pages fetched on that date. Machine: Claude Code 2.1.302, Codex CLI 0.163.0 [local-run].

## Bottom line

1. **Three kinds of (plan, harness) pair are clean.** (a) A provider's subscription in that provider's own harness: Claude Pro/Max in `claude -p`, ChatGPT in `codex exec`, Copilot in `copilot -p`, Google AI Pro/Ultra in `gemini -p`, GLM Coding Plan in ZCode. (b) A coding plan in a harness the provider lists by name, when the provider has no non-interactive clause: GLM Coding Plan in Claude Code, Codex, OpenCode, pi, Crush, Kilo or Cline; ChatGPT Plus/Pro in OpenCode, pi or Kilo Code; Copilot in OpenCode; OpenCode Go in its validated clients. (c) Any pay-as-you-go API key, or a local model, in any harness.
2. **Hard no-go.** Claude Pro/Max OAuth outside Claude Code. pi 1.3.0 still ships this login, using Claude Code's OAuth client ID and Claude Code identity headers. Google consumer OAuth (Gemini CLI or Antigravity login) outside Google's tools, and wrapping `agy` inside a third-party agent. The Alibaba Coding Plan for any non-interactive run. The GLM Coding Plan in tools Z.ai does not list (Qwen Code, Kimi CLI). pi's Copilot login, which sends VS Code Copilot Chat identity headers. Any proxy that pools a subscription or rewrites client identity.
3. **Gray.** Kimi Code membership in background dispatch: Kimi's guidelines say "for interactive use only", yet Kimi's own CLI docs show `kimi -p` for scripts. MiniMax M Plan: any compatible tool is allowed, but the plan is "designed for individual, interactive developer use". Also gray: Alibaba/QwenCloud Token Plan headless, Copilot in Crush/Kilo/Cline, ChatGPT plans in harnesses OpenAI does not list, and Ollama Cloud, whose terms bar "automated means … without permission".
4. **`claude -p` against third-party endpoints is legal but unsupported by Anthropic.** The real risk is credentials, not terms. With only `ANTHROPIC_BASE_URL` set, the saved claude.ai login stays active and goes to that endpoint. The dispatcher must set `ANTHROPIC_AUTH_TOKEN` and run with an isolated `CLAUDE_CONFIG_DIR` that holds no claude.ai login.
5. **Recommendation.** The universal dispatcher should take an explicit allowlist of (plan, harness, mode) triples, each with an evidence ID and a review date. It should deny every other triple by default. A gray triple is enabled only through a user-set config flag, never from chat.

## Legend and method

- Cell codes: **OK**: provider explicitly allows this harness (by name or "any compatible tool") and does not restrict non-interactive use. **OK\***: allowed, but the provider states an interactive or individual design intent without prohibiting automation (gray for background dispatch). **INT**: allowed interactively, but non-interactive or automated use is explicitly forbidden, so no-go for this plugin's background dispatch. **?**: not addressed (harness not named, no "any tool" clause). **NO**: explicitly forbidden, or possible only through client impersonation. **—**: the harness cannot use this plan (no auth path); any hack to make it work is NO.
- "Headless" means: a script launches the harness non-interactively in the background on the user's own machine, for the user's own work (this plugin's model).
- Evidence IDs (e.g. `AN1`) point to the register in section 4. Each register entry carries its tag, link, date and short quotes (≤15 words).
- Primary sources were preferred: official docs and help pages, GitHub source at release tags via `gh api`. Third-party reports are used only for dated events with no primary text found and are tagged `[third-party:…]`.

## 1. 2026 timeline (events that changed the matrix)

| Date | Event | Evidence |
|---|---|---|
| 2026-01-09 | Anthropic adds server-side checks; subscription OAuth stops working outside Claude Code/Claude.ai (OpenCode and others break) | [third-party:https://falcao.org/posts/anthropic-claude-access-crackdown-ecosystem-fallout/] |
| 2026-01-16 | GitHub officially supports Copilot Pro/Pro+/Business/Enterprise in OpenCode | GH1 |
| 2026-02-18/19 | Anthropic's legal page is updated: subscription OAuth only for Claude Code and native apps; Agent SDK developers must use API keys. Thariq Shihipar (Anthropic) says local Agent SDK and `claude -p` use stays encouraged | AN1, AN12 |
| 2026-02-23 → 02-27 | Google restricts Antigravity accounts used through OpenCode/OpenClaw OAuth plugins; on 02-27 it restores them and restates the rule | GO4 |
| 2026-03-19 | OpenCode PR #18186 "anthropic legal requests" merged; Claude Pro/Max plugins no longer bundled since OpenCode 1.3.0 | AN10, AN11 |
| 2026-04-04 | Anthropic: third-party harnesses (OpenClaw first) draw from paid "extra usage", not subscription limits | AN8 |
| 2026-04-15 | Qwen OAuth free tier (Qwen Code) discontinued | QW1 |
| 2026-05-13 | Anthropic announces a separate Agent SDK/`claude -p` credit from 2026-06-15 | [third-party:https://techsy.io/en/blog/claude-agent-sdk-credit] |
| 2026-06-15 | Anthropic pauses that change; Agent SDK, `claude -p` and third-party app usage stay on subscription limits | AN4 |
| 2026-08-21 | OpenAI's Codex lead (as paraphrased by a third party): subscription-to-API pooling ("sub2api") unsupported; Sign in with ChatGPT through official or open-source clients (Pi, OpenCode) is the supported path | OA6 |
| 2026-09-29 | OpenAI DevDay: "Use your ChatGPT plan" permission in Sign in with ChatGPT; open-source integrations OpenCode, Pi, OpenClaw, T3; plan-usage partners include Kilo Code | OA1, [third-party:https://flaviocopes.com/sign-in-with-chatgpt.md] |
| 2026-10-07 | Anthropic: Max/Team get monthly API credits (cover Agent SDK and `claude -p` only when run with a Console API key) | AN3, AN4 |
| 2026-10-11 | Alibaba Model Studio Coding Plan page (last updated): plan key banned for "non-interactive scenarios" | AL1 |
| 2026-10-16 | Z.ai separates Standard API keys from Coding Plan keys; key type decides billing | ZA4 |

## 2. Matrix — subscriptions and plans × harnesses

Columns: CC = Claude Code (`claude -p`, incl. pointed at third-party endpoints); Codex = Codex CLI (`codex exec`); OC = OpenCode; pi = pi (earendil-works/pi); ZC = ZCode CLI; QC = Qwen Code; KC = Kimi Code CLI (`kimi`); GC = Gemini CLI; CKC = Crush / Kilo / Cline; DSH = DeepSeek Harness. The last column is the provider's rule on headless or automated use.

| Plan | CC | Codex | OC | pi | ZC | QC | KC | GC | CKC | DSH | Headless / automation rule |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **Anthropic Claude Pro/Max (consumer OAuth)** | **OK** AN1,AN3,AN5 | — | **NO** AN1,AN10,AN11 | **NO** AN1,PI1,PI2 | — | — | — | — | **NO** AN1 (a wrapper that runs the *unmodified* `claude` binary is covered by AN1-q4) | **NO** AN1 | `claude -p` on the plan is sanctioned (AN3); `setup-token` is documented for scripts/CI (AN5); limits assume "ordinary, individual usage" (AN1); third-party harnesses bill to extra usage (AN8) |
| **Anthropic API key (Console, Commercial Terms)** | OK AN1,AN7 | ? | OK | OK PI6 | — | ? | OK KI5 | — | OK | ? | API keys are the path Anthropic prescribes for developers and automation (AN1, AN7) |
| **OpenAI ChatGPT Plus/Pro** | — (only via proxies → NO) | **OK** OA3,OA5 | **OK** OA1,OCH1 | **OK** OA1,PI4 | — | — | — | — | Kilo Code **OK** OA1; Crush, Cline **?** (OA2: any open-source local app may adopt Sign in with ChatGPT) | ? | `codex exec` reuses ChatGPT login by default, but API keys are "the right default for automation" (OA3, OA4); third-party plan use draws Codex/ChatGPT Work limits (OA1) |
| **OpenAI ChatGPT Business / Enterprise / Edu** | — | **OK** OA5 | **NO** (plan usage Plus/Pro only, OA1) | **NO** OA1 | — | — | — | — | **NO** OA1 | — | as Codex docs (OA3); not eligible for third-party plan usage |
| **OpenAI API key** | ? (AN6: non-Claude models unsupported) | OK OA4 | OK | OK | — | OK | OK | — | OK | ? | recommended for programmatic Codex (OA4) |
| **GitHub Copilot Pro/Pro+/Business/Enterprise** | **NO** (only reverse-engineered proxies, GH4) | ? (only the Codex *VS Code extension* has "Sign in with Copilot", Pro+/Max, GH5) | **OK** GH1,OCH2 | **NO** by plugin standard (spoofs VS Code Copilot Chat, PI3) | — | — | — | — | **?** | — | Copilot CLI `copilot -p` is official for "scripts, CI/CD pipelines, and automation" (GH2); AUP bans "excessive automated bulk activity" (GH3) |
| **Google AI Pro/Ultra, Gemini Code Assist (Google-account login)** | **NO** GO2 | **NO** GO1 | **NO** GO1,GO4 | **NO** GO1 | **NO** | **NO** | **NO** | **OK** GO5,GO6 | **NO** GO1 | **NO** | `gemini -p` is official (GO5); accessing Code Assist via third-party software → "suspension or termination" (GO1) |
| **Google Antigravity (consumer login)** | **NO** GO2 | **NO** | **NO** GO2 | **NO** | **NO** | **NO** | **NO** | — | **NO** | **NO** | `agy -p` "intended for direct scripting and CI"; wrapping `agy` in third-party agents "not supported under consumer plans" (GO2) |
| **Gemini API key / Vertex / Gemini Enterprise** | ? (AN6) | ? | OK | OK PI6 | — | OK (Vertex) | ? | OK | OK | ? | Google recommends "a Gemini Enterprise or Google AI Studio API key" for third-party coding agents; Vertex is not named (GO2) [corrected 2026-10-20: antigravity.google/docs/faq names only Gemini Enterprise and Google AI Studio keys] |
| **Z.ai GLM Coding Plan (individual)** | **OK** ZA2 | **OK** ZA2 | **OK** ZA2 | **OK** ZA2 | **OK** ZA2 | **NO** (not listed, ZA1) | **NO** (not listed, ZA1) | — | **OK** (Crush, Kilo Code, Cline all listed, ZA2) | **NO** (not listed) | not addressed for self-use; flags "bulk or automated usage on behalf of others", SDK access and direct API calls (ZA3) |
| **Moonshot Kimi Code membership ("Kimi For Coding")** | **INT** KI1,KI4 | **INT** KI4 | **INT** KI1,KI4 | **INT/?** (not listed; pi reuses Kimi CLI's OAuth client ID, PI5) | ? | ? | **INT** (conflict: KI3 shows `kimi -p` in scripts) | — | ? | ? | "for interactive use only"; "Don't use Kimi Code for non-interactive automation" (KI1) |
| **MiniMax M Plan (ex Coding/Token Plan)** | **OK\*** MM1,MM2 | **OK\*** MM2 | **OK\*** MM2 | **OK\*** MM2 | OK\* (any compatible tool) | **OK\*** MM2 | OK\* | — | **OK\*** (Kilo listed; any compatible tool) | OK\* | not prohibited; "designed for individual, interactive developer use"; pay-as-you-go "recommended for production use" (MM1) |
| **Alibaba Model Studio Coding Plan** | **INT** AL1,AL3 | **INT** AL3 | **INT** AL3 | **INT** AL2 | INT AL2 | **INT** AL3,QW1 | INT AL2 | — | **INT** (Cline, Kilo CLI listed, AL3) | INT | "Do not use the plan's API key for automated scripts" / "non-interactive scenarios" (AL1) |
| **Alibaba / QwenCloud Token Plan (Personal, Team)** | OK\* AL4 | OK\* AL4 | OK\* | OK\* PI6 | ? | OK\* AL4 | ? | — | OK\* | ? | "only AI programming tools and OpenClaw-type agents"; "automated scripts" listed as unsupported (AL2) |
| **DeepSeek API (pay-as-you-go; no coding subscription found)** | **OK** DS2 | **OK** DS2 | **OK** DS2 | OK PI6 | — | OK QW1 | OK KI5 | — | OK | **OK** DS2,DS3 | not addressed; key must not be shared (DS1) |
| **OpenRouter** | **OK** OR2 | OK | OK | OK PI6 | — | OK | OK | — | OK | ? | comply with each model's terms; no resale (OR1) |
| **OpenCode Zen (pay-as-you-go gateway)** | ? | ? | **OK** OC2 | OK? (pi ships `OPENCODE_API_KEY`, PI6) | ? | ? | ? | — | ? | ? | not addressed |
| **OpenCode Go / Go Plus (subscription)** | **OK** OC1 | **OK** OC1 | **OK** | **OK** OC1 | **OK** OC1 | ? | ? ("known problematic" technically, OC1) | — | Kilo Code CLI **OK** OC1; Crush, Cline ? | ? ("known problematic", OC1) | not addressed; client must use "its own user agent" (OC1) |
| **Ollama Cloud** | **OK** OL1 (incl. `-p`) | **OK** OL1 | **OK** OL1 | **OK** OL3 | ? | ? | ? | — | Cline **OK** OL3 | **OK** OL3 | docs show headless `-p`; terms ban "automated means … without permission" (OL2) → OK\* |
| **Local model (Ollama/LM Studio/llama.cpp on localhost)** | OK OL1 | OK | OK | OK | ? | OK | OK | — | OK | OK | no service terms; model licence only |

Notes on harness columns:
- ZCode's built-in provider templates are Z.ai-only (`zai-api`, `zai-standard-api`, `bigmodel-api`) [source:this repo docs/zcode-cli-findings.md]. OpenCode Go nevertheless lists ZCode as a validated client (OC1), so ZCode accepts some custom endpoint. The ZCode cells other than Z.ai and OpenCode Go are therefore "?".
- Gemini CLI speaks only Google's Gemini API and Vertex AI protocols, so every non-Google row is "—". GO1 itself does not say this. Gemini CLI v0.64.0 does accept a custom endpoint through `GOOGLE_GEMINI_BASE_URL` (with `gemini-api-key` auth) and `GOOGLE_VERTEX_BASE_URL`, so "—" means that no provider in this matrix documents a Gemini-format endpoint. It does not mean that no auth path exists. [corrected 2026-10-20: google-gemini/gemini-cli@v0.64.0:docs/reference/configuration.md documents GOOGLE_GEMINI_BASE_URL "Overrides the default base URL for Gemini API requests"; tos-privacy.md (GO1) says nothing about which endpoints the CLI can use]
- DSH: DeepSeek's integration docs list "DeepSeek Harness" (DS2). Ollama documents it (OL3). OpenCode Go calls it a "known problematic" client, which is a technical session-header issue, not a terms issue (OC1).

## 3. Harness-side findings (truthful identification, impersonation)

| Harness / login | What it sends | Verdict vs plugin standard | Evidence |
|---|---|---|---|
| pi 1.3.0 "Anthropic (Claude Pro/Max)" | Claude Code's OAuth client ID `9d1c250a-e61b-44d9-88ed-5944d1962f5e` (base64 in source; the same string is in the installed Claude Code 2.1.302 binary), scope `user:sessions:claude_code`, `user-agent: claude-cli/<ver>`, `x-app: cli`, beta `claude-code-20250219` | **NO**: impersonates Claude Code, and Anthropic forbids the use itself | PI1, PI2, [local-run] |
| pi 1.3.0 GitHub Copilot | GitHub OAuth client `Iv1.b507a08c87ecfe98`, `User-Agent: GitHubCopilotChat/0.35.0`, `Editor-Version: vscode/1.107.0`, `Copilot-Integration-Id: vscode-chat` | **NO**: claims to be VS Code Copilot Chat | PI3 |
| pi 1.3.0 "OpenAI (ChatGPT subscription)" | dynamic client registration (`dynamic_agent_client`), i.e. OpenAI's Sign in with ChatGPT open-source flow | **OK** (prefer this over pi's "OpenAI (ChatGPT Plus/Pro)" flow) | PI4, OA2 |
| pi 1.3.0 "OpenAI (ChatGPT Plus/Pro)" | Codex CLI's OAuth client `app_EMoamEEZ73f0CkXaXp7hrann`, `originator=pi` | OK-ish: truthful originator, and OpenAI lists Pi | PI4, OA1 |
| pi 1.3.0 Kimi Code (subscription) | Kimi Code CLI's own OAuth client ID `17e5f671-…` (same constant as `MoonshotAI/kimi-code` `packages/oauth/src/constants.ts`) | gray: Kimi does not list pi, and the client ID is borrowed | PI5 |
| OpenCode 1.19.3 ChatGPT login | Codex CLI's client ID, `originator: opencode`, `User-Agent: opencode/<ver>` | OK: truthful, and OpenAI lists OpenCode | OCH1, OA1 |
| OpenCode 1.19.3 Copilot login | its own GitHub OAuth app `Ov23li8tweQw6odWQebz`, `User-Agent: opencode/<ver>` | OK: truthful; formal GitHub partnership | OCH2, GH1 |
| Claude Code → third-party endpoint | if only `ANTHROPIC_BASE_URL` is set, "a saved claude.ai login remains the active credential" and goes to that URL | **must** set `ANTHROPIC_AUTH_TOKEN` (it ranks above `/login`) and isolate `CLAUDE_CONFIG_DIR` | AN6, AN5 |

## 4. Evidence register

| ID | Source | Date | Key text (≤15 words per quote) |
|---|---|---|---|
| AN1 | [docs:https://code.claude.com/docs/en/legal-and-compliance] | page undated; content updated 2026-02-19 per [third-party:https://gigazine.net/gsc_news/en/20260220-anthropic-third-party-block] | "designed to support ordinary use of Claude Code and other native Anthropic applications" · "Anthropic does not permit third-party developers to offer Claude.ai login into their own applications" · "route requests through Free, Pro, or Max plan credentials on behalf of their users" · (q4) "Nor does it prevent an end user from signing in to the unmodified Claude Code binary" · "Advertised usage limits for Pro and Max plans assume ordinary, individual usage" · "may not collect, store, or intermediate Claude.ai credentials or session tokens" |
| AN2 | [docs:https://www.anthropic.com/legal/consumer-terms] §3 | effective 2025-10-08 | bars access "through automated or non-human means, whether through a bot, script" · exception: "or where we otherwise explicitly permit it" |
| AN3 | [docs:https://support.claude.com/en/articles/17154008-monthly-api-credits-for-max-and-team-plans] | updated 2026-10-20 | "claude -p and Agent SDK usage still draw from your plan's usage limits" (when signed in with the plan) |
| AN4 | [docs:https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan] | updates 2026-06-15, 2026-10-07 | "We've paused the previously-announced changes to Claude Agent SDK usage." · "still use the Claude Agent SDK, claude -p, and third-party apps with your subscription limits" |
| AN5 | [docs:https://code.claude.com/docs/en/authentication] | undated | `claude setup-token`: "For CI pipelines, scripts, or other environments where interactive browser login isn't available" · precedence: `ANTHROPIC_AUTH_TOKEN` (2) above subscription `/login` (7); `--bare` ignores `CLAUDE_CODE_OAUTH_TOKEN` |
| AN6 | [docs:https://code.claude.com/docs/en/llm-gateway] | undated | "doesn't support routing Claude Code to non-Claude models through any gateway" · "a saved claude.ai login remains the active credential" |
| AN7 | [docs:https://code.claude.com/docs/en/agent-sdk/overview] | undated | "Anthropic does not allow third party developers to offer claude.ai login or rate limits" |
| AN8 | [third-party:https://www.infoworld.com/article/4154435/anthropic-cuts-openclaw-access-from-claude-subscriptions-offers-credits-to-ease-transition.html] (quotes Anthropic email) | 2026-04-06 | "third-party harnesses like OpenClaw connected to your Claude account will draw from extra usage" |
| AN10 | [source:anomalyco/opencode PR #18186 via gh api] | merged 2026-03-19 | title "anthropic legal requests" |
| AN11 | [source:anomalyco/opencode@v1.19.3:packages/web/src/content/docs/providers.mdx] | tag 2026-10-16 | "Anthropic explicitly prohibits this." · bundled plugins removed: "no longer the case as of 1.3.0" |
| AN12 | [third-party:https://gigazine.net/gsc_news/en/20260220-anthropic-third-party-block] quoting Thariq Shihipar on X | 2026-02-18 | "We want to encourage local development and experimentation with the Agent SDK and claude -p." |
| OA1 | [docs:https://learn.chatgpt.com/docs/sign-in-with-chatgpt.md] | undated (launch 2026-09-29 per third-party) | "eligible ChatGPT Plus and Pro subscribers can also choose to use their ChatGPT plan" · open-source integrations: OpenClaw, OpenCode, Pi (earendil-works/pi), T3 · plan-usage partners incl. Kilo Code · "App usage counts toward your existing plan limits." |
| OA2 | [docs:https://developers.openai.com/siwc/token-sharing-open-source.md] | undated | "These docs explain ChatGPT plan usage for open-source and locally hosted apps." · paid or remotely hosted apps must use an interest form |
| OA3 | [docs:https://learn.chatgpt.com/docs/non-interactive-mode.md] | undated | "`codex exec` reuses saved CLI authentication by default." · "API keys are the right default for automation" · ChatGPT auth in CI: "Do not use this workflow for public or open-source repositories." |
| OA4 | [docs:https://learn.chatgpt.com/docs/auth.md] | undated | "Use API key authentication for programmatic Codex CLI workflows, such as CI/CD jobs." |
| OA5 | [docs:https://developers.openai.com/codex/llms.txt] → Pricing entry | undated | Codex "included in your ChatGPT Free, Go, Plus, Pro, Business, Edu, or Enterprise plan" |
| OA6 | [third-party:https://explainx.ai/blog/codex-usage-limits-sub2api-sign-in-chatgpt-august-2026] (paraphrase of Tibo Sottiaux) | 2026-08-21 | "Sign in With ChatGPT via official or OSS clients is the supported path." (article's summary; staff wording unverified) |
| GH1 | [docs:https://github.blog/changelog/2026-01-16-github-copilot-now-supports-opencode/] | 2026-01-16 | "officially supporting using your Copilot Pro, Pro+, Business, or Enterprise subscription with OpenCode" |
| GH2 | [docs:https://docs.github.com/en/copilot/how-tos/copilot-cli/automate-copilot-cli/run-cli-programmatically] | undated | "use the CLI programmatically in scripts, CI/CD pipelines, and automation workflows" |
| GH3 | [docs:https://docs.github.com/en/site-policy/acceptable-use-policies/github-acceptable-use-policies] §4 | undated | "using our servers for any form of excessive automated bulk activity" |
| GH4 | [third-party:https://community.wappler.io/t/copilot-github-problems/61983] (GitHub message as quoted by a user) | n/d | restriction for "usage through a proxy that interferes with how Copilot works" |
| GH5 | [docs:https://docs.github.com/en/copilot/concepts/agents/about-third-party-coding-agents] | undated | Codex VS Code "Sign in with Copilot" "is only available to GitHub Copilot Pro+ and Copilot Max subscribers" |
| GO1 | [source:google-gemini/gemini-cli@v0.64.0:docs/resources/tos-privacy.md] | tag 2026-10-13 | "(for example, using OpenClaw with Gemini CLI OAuth) is a violation of applicable terms" · "may be grounds for suspension or termination of your account" |
| GO2 | [docs:https://antigravity.google/docs/faq] | undated | "third-party software, tools, or services to access Antigravity is a violation" (names Claude Code, OpenClaw, OpenCode) · "Antigravity CLI headless mode (agy -p) is intended for direct scripting and CI workflows." · "Wrapping agy inside third-party coding agents or applications" … "is not supported under consumer plans" · "we recommend using a Gemini Enterprise or Google AI Studio API key" |
| GO3 | [docs:https://antigravity.google/terms] §6 | undated | "using the Service in connection with products not provided by us" · "suspension or termination of your Antigravity and/or Gemini CLI accounts" |
| GO4 | [third-party:https://deepakness.com/raw/google-bans-accounts/] relaying @antigravity on X | 2026-02-27 | "using third-party tools with your Antigravity login remains against our terms" |
| GO5 | [source:google-gemini/gemini-cli@v0.64.0:README.md] | 2026-10-13 | "Run non-interactively in scripts for workflow automation" (`gemini -p`) |
| GO6 | [source:google-gemini/gemini-cli@v0.64.0:docs/resources/quota-and-pricing.md] | 2026-10-13 | AI Pro 1,500 / AI Ultra 2,000 requests per user per day; "Google AI Plus, are not supported" |
| ZA1 | [docs:https://docs.z.ai/devpack/usage-policy] | undated | "GLM Coding Plan may only be used within officially supported tools and products." · "Account sharing or multi-user access is prohibited." · >3 violations may lead to ban |
| ZA2 | [docs:https://docs.z.ai/devpack/tool/others] | undated (fetched 2026-10-20) | "users may not use their subscription benefits for tools or scenarios outside of this scope" · coding tools: ZCode, Claude Code, Claude for IDE, Codex, OpenCode, Pi, Cursor, Cline, TRAE, Qoder, Droid, Kilo Code, Roo Code, Crush, Goose, Eigent; general agents: AutoClaw, OpenClaw, Hermes Agent, SillyTavern |
| ZA3 | [docs:https://docs.z.ai/legal-agreement/subscription-terms] §4 | undated | "(such as SDK-based access or other third-party integrations)" · "directly invoking model APIs from your own applications, bots, websites, SaaS products" · "bulk or automated usage on behalf of others" · "aggregate, proxy or otherwise provide the GLM Coding Plan to any third party" |
| ZA4 | [docs:https://docs.z.ai/devpack/notice/api-key-management] | 2026-10-16 | Standard vs Coding Plan keys separate; "the key type determines how calls are billed" |
| KI1 | [docs:https://www.kimi.com/code/docs/en/kimi-code/community-guidelines.html] | undated | "Kimi Code subscriptions are for interactive use only." · "Don't use Kimi Code for non-interactive automation" · "such as scripted batch execution or data annotation pipelines" · "Accessing Kimi through a forward proxy (like a VPN or company network) is fine." · "Sharing your account with others through a reverse proxy is a violation." · "Don't spoof or alter client identity information" · compatible: "(Kimi CLI, VS Code, Claude Code, OpenCode, OpenClaw, etc.)" |
| KI2 | [docs:https://www.kimi.com/en/help/kimi-code/membership-guide] | undated | "Tampering with the client identifier (User-Agent) is considered a violation" |
| KI3 | [source:MoonshotAI/kimi-code@@moonshot-ai/kimi-code@2.2.0:docs/en/reference/kimi-command.md] | tag 2026-10-14 | "When running a single prompt in a script or CI environment, use `-p`" · example `kimi -m kimi-code/kimi-for-coding -p …` |
| KI4 | [docs:https://www.kimi.com/en/help/kimi-code/third-party-agents] + Kimi Code docs sidebar | undated | third-party guides: Claude Code, OpenCode, Codex, Hermes Agent |
| KI5 | [source:MoonshotAI/kimi-code@@moonshot-ai/kimi-code@2.2.0:docs/en/configuration/providers.md] | 2026-10-14 | provider types `kimi`, `anthropic` ("connecting Claude with an Anthropic API key"), `openai` ("DeepSeek, Qwen, etc."), `openai_responses` |
| HX1 | [source:anomalyco/opencode@v1.19.3:packages/web/src/content/docs/cli.mdx], [source:earendil-works/pi@v1.3.0:packages/coding-agent/docs/cli.md] | 2026-10-16 / 2026-10-15 | headless modes: `opencode run` "Run opencode in non-interactive mode"; `pi -p/--print` "Run the supplied prompts … then exit" |
| MM1 | [docs:https://platform.minimax.io/docs/m-plan/faq.md] | undated | "Any AI tool that supports the OpenAI-compatible or Anthropic-compatible protocol" · "M Plan is designed for individual, interactive developer use" · "Pay-as-you-go is recommended for production use." |
| MM2 | [docs:https://platform.minimax.io/docs/llms.txt] + m-plan/other-tools.md | undated | M Plan guides: MiniMax Code, Claude Code, Codex, Cursor, OpenCode, Pi, Hermes, OpenClaw; other tools incl. Kilo Code, Droid, Qwen Code, Grok CLI |
| MM3 | [docs:https://platform.minimax.io/protocol/terms-of-service] | effective 2026-03-30 | no clause specific to plans or harnesses; bars access that "circumvents fees or otherwise evades usage restrictions" |
| AL1 | [docs:https://www.alibabacloud.com/help/en/model-studio/coding-plan] | last updated 2026-10-11 | "This plan is for interactive use in programming tools" · "Do not use the plan's API key for automated scripts" · "or other non-interactive scenarios" · "may result in subscription suspension or API key revocation" · "The plan is for your use only and must not be shared." |
| AL2 | [docs:https://www.alibabacloud.com/help/en/model-studio/more-tools] | last updated 2026-10-11 | "supports any third-party programming tool compatible with OpenAI or Anthropic API protocols" · plans "support only AI programming tools and OpenClaw-type agents" · unsupported: "Custom applications: automated scripts, application backends calling the API directly" |
| AL3 | AL1 page, integration list | 2026-10-11 | OpenClaw, Hermes Agent, Claude Code, OpenCode, Cursor, Codex, Qwen Code, QwenPaw, Cherry Studio, Chatbox, Cline, Qoder, Lingma, Kilo CLI, WorkBuddy |
| AL4 | [docs:https://docs.qwencloud.com/token-plan/overview.md] | undated | "Any tool that supports a custom **Base URL** and **API Key** can be integrated." |
| QW1 | [source:QwenLM/qwen-code@v0.25.3:docs/users/configuration/auth.md] | tag 2026-10-19 | "The Qwen OAuth free tier was discontinued on 2026-04-15." · built-in third-party providers: DeepSeek, Grok, MiniMax, Z.AI, Kimi, Idealab, ModelScope, OpenRouter, Requesty [corrected 2026-10-20: auth.md line 7 at v0.25.3 also lists Idealab] |
| DS1 | [docs:https://cdn.deepseek.com/policies/en-US/deepseek-open-platform-terms-of-service.html] | released 2026-04-22, effective 2026-04-29 | "do not share or publicly disclose your API key with others"; automation and third-party tools not addressed |
| DS2 | [docs:https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code] | undated | `ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic`, `ANTHROPIC_AUTH_TOKEN=<key>`; sidebar: DeepSeek Harness, Codex, OpenCode, OpenClaw, Hermes, Reasonix, WorkBuddy/CodeBuddy, Qoder |
| DS3 | [source:deepseek-ai/deepseek-harness@dsh-v0.2.1-rc.2] | 2026-10-17 | MIT; README carries no terms or provider list |
| OR1 | [docs:https://openrouter.ai/terms] | last updated 2026-08-31 | "to comply with the applicable terms for each Model" (the source reads "you agree, and will ensure that your Authorized Users and customers agree, to comply…") [corrected 2026-10-20: openrouter.ai/terms; the earlier quote spliced two non-adjacent phrases] · no resale of "API access to Models" |
| OR2 | [docs:https://openrouter.ai/docs/cookbook/coding-agents/claude-code-integration] | undated | Claude Code via `ANTHROPIC_BASE_URL=https://openrouter.ai/api` + `ANTHROPIC_AUTH_TOKEN` |
| OC1 | [source:anomalyco/opencode@v1.19.3:packages/web/src/content/docs/go.mdx] | tag 2026-10-16 | "designed for OpenCode and other coding agents that produce similar types of requests" · "Identify itself with its own user agent" · validated: Hermes, Claude Code, Codex, ZCode, Pi, jcode, Kilo Code CLI; problematic: DeepSeek Harness, Copilot Chat, Kimi Code, MiMo Code |
| OC2 | [source:anomalyco/opencode@v1.19.3:packages/web/src/content/docs/zen.mdx] | 2026-10-16 | "OpenCode Zen is an AI gateway that gives you access to these models." (pay-as-you-go) |
| OCH1 | [source:anomalyco/opencode@v1.19.3:packages/opencode/src/plugin/openai/codex.ts] | 2026-10-16 | `CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"`, `originator: "opencode"`, `User-Agent: opencode/${ver}` |
| OCH2 | [source:anomalyco/opencode@v1.19.3:packages/opencode/src/plugin/github-copilot/copilot.ts] | 2026-10-16 | `CLIENT_ID = "Ov23li8tweQw6odWQebz"`, `User-Agent: opencode/${ver}` |
| PI1 | [source:earendil-works/pi@v1.3.0:packages/ai/src/auth/oauth/anthropic.ts] | tag 2026-10-15 | `name: "Anthropic (Claude Pro/Max)"`; base64 client ID decodes to `9d1c250a-e61b-44d9-88ed-5944d1962f5e`; same string found in `/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe` 2.1.302 [local-run] |
| PI2 | [source:earendil-works/pi@v1.3.0:packages/ai/src/api/anthropic-messages.ts] | 2026-10-15 | comment "OAuth: Bearer auth, Claude Code identity headers"; `"user-agent": claude-cli/${claudeCodeVersion}`, `"x-app": "cli"`, beta `claude-code-20250219` |
| PI3 | [source:earendil-works/pi@v1.3.0:packages/ai/src/auth/oauth/github-copilot.ts] | 2026-10-15 | `User-Agent: GitHubCopilotChat/0.35.0`, `Editor-Version: vscode/1.107.0`, `Copilot-Integration-Id: vscode-chat` |
| PI4 | [source:earendil-works/pi@v1.3.0:packages/ai/src/auth/oauth/openai-chatgpt.ts, openai-codex.ts] | 2026-10-15 | "OpenAI (ChatGPT subscription)" uses `dynamic_agent_client`; "OpenAI (ChatGPT Plus/Pro)" uses Codex client ID with `originator = "pi"` |
| PI5 | [source:earendil-works/pi@v1.3.0:packages/ai/src/auth/oauth/kimi-coding.ts] vs [source:MoonshotAI/kimi-code@2.2.0:packages/oauth/src/constants.ts] | 2026-10-15 / 2026-10-14 | same `clientId: '17e5f671-d194-4dfb-9706-5516cb48c098'` |
| PI6 | [source:earendil-works/pi@v1.3.0:packages/coding-agent/docs/providers.md] | 2026-10-15 | env keys incl. ZAI Coding Plan, Kimi For Coding, MiniMax, Qwen Token Plan, OpenCode Zen and Go, DeepSeek, OpenRouter, GitHub Copilot |
| OL1 | [docs:https://docs.ollama.com/integrations/claude-code.md], [docs:https://docs.ollama.com/cloud.md] | undated | `ollama launch claude --model gemma4:cloud --yes -- -p "…"`; `ollama launch codex` / `opencode`; local `ANTHROPIC_BASE_URL=http://localhost:11434` |
| OL2 | [docs:https://ollama.com/terms] §4 | last updated May 2026 | "Use automated means to access our services without permission" (prohibited) |
| OL3 | [docs:https://docs.ollama.com/llms.txt] | undated | integrations incl. Claude Code, OpenCode, DeepSeek Harness, Cline CLI, Codex CLI, Copilot CLI, Droid, Goose, Pi, Roo Code |

## 5. Verdicts for this plugin

### Safe defaults (ship as built-in channels)

| Plan | Harness / mode | Why safe | Caveats |
|---|---|---|---|
| Z.ai GLM Coding Plan | ZCode CLI (status quo), Claude Code `claude -p`, Codex `exec`, OpenCode `run`, pi `--print` (HX1) | all on Z.ai's list (ZA2); self-use automation not restricted (ZA3) | concurrency per tier (ZA1); never SDK/raw API; for `claude -p` use the plan key with `ANTHROPIC_AUTH_TOKEN` against `https://api.z.ai/api/anthropic` |
| ChatGPT Plus/Pro/Business | Codex CLI (status quo) | official (OA3, OA5) | OpenAI calls API keys "the right default for automation" (OA3) |
| ChatGPT Plus/Pro | OpenCode, pi ("OpenAI (ChatGPT subscription)" flow) | listed by OpenAI (OA1) | draws the same Codex/ChatGPT Work limits; Business/Enterprise not eligible |
| Claude Pro/Max | unmodified `claude -p` with the user's own login | sanctioned (AN1-q4, AN3, AN5) | same model family as the plugin's Opus reviewers (family rule); "ordinary, individual usage" (AN1) |
| Copilot paid plans | OpenCode; Copilot CLI `copilot -p` | formal partnership (GH1); official programmatic mode (GH2) | AUP bulk-automation clause (GH3) |
| Google AI Pro/Ultra, Code Assist | Gemini CLI `gemini -p` only | official (GO5) | daily request caps (GO6) |
| Pay-as-you-go keys: Anthropic, OpenAI, DeepSeek, OpenRouter, Z.ai Standard, Kimi Platform, MiniMax PAYG, Model Studio PAYG, Gemini API/Vertex | any harness | API terms do not restrict the client (AN1, OA4, DS1, OR1, GO2, MM1) | keep keys out of chat and logs; OpenRouter passes through each model's terms |
| OpenCode Go | Claude Code, Codex, ZCode, pi, OpenCode, Kilo Code CLI | validated clients (OC1) | truthful user agent required (OC1) |
| Ollama Cloud / local models | Claude Code (`-p`), Codex, OpenCode, pi, Cline | documented integrations incl. `-p` (OL1, OL3) | Ollama terms clause on "automated means" (OL2); local: no service terms |

### Gray (off by default; user-set config flag only, with the quote shown at setup)

- **Kimi Code membership, any harness, background dispatch.** Guidelines forbid "non-interactive automation" (KI1), while `kimi -p` is documented for scripts (KI3). Prefer a Kimi Platform pay-as-you-go key.
- **MiniMax M Plan, headless.** Allowed tools are broad (MM1), but the plan is "designed for individual, interactive developer use". Pay-as-you-go is recommended for heavier use.
- **Alibaba/QwenCloud Token Plan, headless.** "Automated scripts" are unsupported, and it is unclear whether a script-launched coding tool counts (AL2).
- **ChatGPT Plus/Pro in Crush/Cline** (not listed, OA1) and **Copilot in Crush/Kilo/Cline** (no GitHub statement).
- **OpenCode Zen outside OpenCode** (not addressed, OC2).
- **Ollama Cloud** under its "without permission" clause (OL2), mitigated by Ollama's own `-p` docs (OL1).

### No-go (refuse in the dispatcher, even on request)

- Claude Pro/Max OAuth or `setup-token` tokens in any non-Anthropic harness: OpenCode, pi, Crush, Kilo, Cline, Qwen Code, DSH (AN1, AN7, AN8, AN10, AN11).
- pi's "Anthropic (Claude Pro/Max)" and GitHub Copilot logins, both of which impersonate other clients (PI1–PI3).
- Google consumer OAuth (Gemini CLI, Code Assist, Antigravity) in any third-party harness, and wrapping `agy` in this plugin under a consumer plan (GO1–GO4).
- Alibaba Model Studio Coding Plan for any non-interactive dispatch (AL1).
- GLM Coding Plan in tools Z.ai does not list (Qwen Code, Kimi CLI, DSH, Gemini CLI), or through the SDK or raw API (ZA1–ZA3).
- ChatGPT Business/Enterprise in third-party harnesses (OA1).
- Copilot through reverse-engineered proxies into Claude Code (GH4); subscription-to-API pooling proxies (OA6); reverse proxies sharing an account (KI1); User-Agent rewriting (KI2, OC1).

## 6. Design implications for a universal dispatcher

1. **Policy table, not code paths.** Ship `policy.json` with rows `{plan, harness, mode: interactive|headless, status: ok|gray|no, evidence: [IDs], reviewed: date}`. Dispatch only `ok` rows, plus `gray` rows the user enabled in a config file. `no` rows are hard-refused with the evidence quote.
2. **Credential isolation for `claude -p` on third-party endpoints.** Use a dedicated `CLAUDE_CONFIG_DIR` with no claude.ai login. Set `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` (and `ANTHROPIC_API_KEY=""`), and check that no `CLAUDE_CODE_OAUTH_TOKEN` is inherited (AN5, AN6). Otherwise the user's Claude credential can reach a third-party host.
3. **Truthful identity.** Never set `User-Agent`, `originator`, `x-app` or client IDs; let each harness identify itself (KI1, KI2, OC1, ZA2). For pi, pin the provider and refuse `anthropic` OAuth and `github-copilot`; for ChatGPT, require the "OpenAI (ChatGPT subscription)" flow.
4. **Keys stay out of chat.** The existing `zcode-dispatch api-key set` stdin pattern generalises: one keystore per channel, written by the user's own shell.
5. **Concurrency and quota classes per plan.** Z.ai tier guidance (ZA1), Kimi "concurrent request limit" (KI1), Gemini daily caps (GO6), Copilot AI credits.
6. **Kill switches per channel**, as `SP_IMPLEMENTER=luna` does today, so a provider terms change can be applied without code changes.
7. **Re-verify on a schedule.** Six of the governing pages changed in 2026; the evidence register records dates.
8. **Proxies.** A forward proxy (the machine's TUN client) is explicitly fine for Kimi (KI1) and is not addressed elsewhere. Never add a local reverse proxy that converts one plan into an API for another harness (OA6, ZA3, KI1).

## 7. Open questions

- Anthropic: what "third-party apps" means in "You can still use … third-party apps with your subscription limits" (AN4, 2026-10-07), set against the 2026-04-04 extra-usage rule for third-party harnesses (AN8). The working assumption is that it means apps that run the unmodified Claude Code binary/Agent SDK with the user's own sign-in (AN1-q4). [unverified]
- Anthropic: whether a plugin that spawns several background `claude -p` implementers stays "ordinary, individual usage" (AN1) or triggers throttling. [unverified]
- Z.ai: no statement on headless use of a supported tool. ZA3 targets only automation "on behalf of others". [unverified either way]
- Kimi: the guidelines (KI1) and the CLI docs (KI3) conflict on `-p`. Ask Moonshot before enabling.
- MiniMax: whether background dispatch for personal work counts as "production use" (MM1).
- Alibaba: whether the Token Plan "automated scripts" exclusion (AL2) covers a script-launched coding tool.
- Google: whether wrapping `gemini -p` (not `agy`) from a third-party agent under a consumer plan is treated like wrapping `agy` (GO2). Gemini CLI docs are silent; the Antigravity terms name "Gemini CLI accounts" (GO3).
- GitHub: no statement on Copilot in Crush/Kilo/Cline/pi; whether Copilot CLI `-p` in a background loop meets the AUP (GH3).
- OpenAI: whether SIWC-listed OSS harnesses (OpenCode, pi) may be driven headless by another agent; the docs do contemplate self-hosted VMs (OA2).
- DeepSeek: no official coding subscription was found. [unverified] DSH's provider list and terms are not documented in its README (DS3).
- Primary text for the 2026-01-09 block, the 2026-04-04 Anthropic email and the 2026-02-27 Google post was only available through third parties (AN8, AN12, GO4).

## Fact-check log (2026-10-20)

Every source below was opened again on 2026-10-20 by an independent checker. Web pages were fetched as raw Markdown or HTML and grepped for the exact quote. GitHub sources were read at the cited tag with `gh api`. Local evidence comes from `claude --help` (2.1.302) and `codex --help` (0.163.0), run with empty scratch config dirs, and from `grep -a` on the installed binaries. Rows marked "third-party" had no primary text available.

| Claim | Verdict | Evidence |
|---|---|---|
| AN1: no Claude.ai login or plan routing for third-party developers; an end user may sign in to the unmodified Claude Code binary. All six AN1 quotes. | confirmed | code.claude.com/docs/en/legal-and-compliance.md: every quoted fragment matches verbatim |
| AN3: when signed in with the plan, `claude -p` and Agent SDK usage draw from plan limits. Page updated 2026-10-20 | confirmed | support.claude.com article 17154008 (FAQ "Does this cover claude -p?"); the page shows "Updated today" |
| AN4: 2026-06-15 pause; 2026-10-07 note saying third-party apps keep subscription limits | confirmed | support.claude.com article 15036540: both dated updates and both quotes match verbatim |
| AN5: `setup-token` documented for CI and scripts; precedence `ANTHROPIC_AUTH_TOKEN` (2) above `/login` (7); `--bare` ignores `CLAUDE_CODE_OAUTH_TOKEN` | confirmed | authentication.md (precedence list items 2, 5 and 7; bare-mode note); `claude --help` 2.1.302 lists `setup-token`, and `--bare` says "OAuth and keychain are never read" |
| AN6: non-Claude models are unsupported through a gateway; with only `ANTHROPIC_BASE_URL` set, the saved claude.ai login stays the active credential and still goes to the gateway | confirmed | llm-gateway.md ("Requests still route through the gateway, but a saved claude.ai login remains the active credential"). Second source: llm-gateway-connect.md, where the credential variable takes precedence over the saved login |
| AN7: Agent SDK overview quote | confirmed | agent-sdk/overview.md line 44. The sentence begins "Unless previously approved," |
| AN2: consumer terms §3, effective 2025-10-08: the automated-access bar and its "explicitly permit it" exception | confirmed | anthropic.com/legal/consumer-terms, section "3. Use of our Services" |
| AN8: the April email says third-party harnesses draw from extra usage starting April 4 | confirmed (third-party only) | InfoWorld 4154435, dated 2026-04-06, carries the quote. Computerworld, gigazine 20260405 and HN copies of the email corroborate it. No Anthropic-hosted text exists. AN4 (June 15 and Oct 7) now says third-party app usage draws from subscription limits; see the open question |
| AN12 and the 2026-02-18/19 timeline row | confirmed (third-party) | gigazine 20260220 prints Thariq's post of Feb 18 verbatim and dates the docs update to Feb 19, 2026 |
| 2026-01-09 server-side block | confirmed (third-party) | falcao.org timeline gives "January 9, 2026"; several independent blogs agree; no Anthropic post exists |
| 2026-05-13 Agent SDK credit announcement | confirmed (third-party) | techsy.io says "announced the change on May 13, 2026". The New Stack places it on a Wednesday (May 13, 2026 was a Wednesday). gaugr says May 14 |
| AN10/AN11: PR #18186 "anthropic legal requests" merged 2026-03-19; providers.mdx says "Anthropic explicitly prohibits this", with plugins removed as of 1.3.0 | confirmed | `gh api` pulls/18186: merged_at 2026-03-19T04:45:24Z. providers.mdx@v1.19.3 lines 357–361. v1.19.3 was published 2026-10-16 and v1.3.0 on 2026-03-22 |
| PI1/PI2: pi 1.3.0 Anthropic OAuth uses Claude Code's client ID and identity headers | confirmed | anthropic.ts@v1.3.0: base64 decodes to `9d1c250a-…2f5e`, scope includes `user:sessions:claude_code`. anthropic-messages.ts lines 1049, 1061–1062, 1142. `grep -a -c` finds the ID twice in the local claude.exe 2.1.302. Tag published 2026-10-15 |
| PI3 and OCH2: pi's Copilot login sends VS Code Copilot Chat headers; OpenCode uses its own app and UA | confirmed | github-copilot.ts@v1.3.0 lines 11–17 (client ID decodes to `Iv1.b507a08c87ecfe98`). copilot.ts@v1.19.3 has `CLIENT_ID = "Ov23li8tweQw6odWQebz"` and `opencode/${InstallationVersion}`, with no Editor-Version or Integration-Id headers |
| PI4, PI5, PI6, HX1, OCH1 | confirmed | openai-chatgpt.ts (`dynamic_agent_client`, a SIWC token-sharing flow); openai-codex.ts (`app_EMoamEEZ73f0CkXaXp7hrann`, `originator = "pi"`). The same Codex ID appears in the local codex 0.163.0 binary. kimi-coding.ts and kimi-code `packages/oauth/src/constants.ts`@`@moonshot-ai/kimi-code@2.2.0` share the same clientId. providers.md env table; cli.md `-p`, `--print`; OpenCode cli.mdx line 341 |
| OA1: SIWC lists OpenClaw, OpenCode, Pi, T3 as open source and Kilo Code among plan-usage apps; Plus and Pro only | confirmed | learn.chatgpt.com/docs/sign-in-with-chatgpt.md: lists and quotes are verbatim. A second source, developers.openai.com/siwc/llms-full.txt, says "Eligible ChatGPT Plus and Pro users can use their ChatGPT plan…". help.openai.com 20001542 still returns 403 |
| OA2–OA5 quotes | confirmed | token-sharing-open-source.md line 9; non-interactive-mode.md lines 133, 159, 166; auth.md line 149; codex/llms.txt line 268 |
| OA6 (sub2api) and the 2026-09-29 DevDay row | confirmed (third-party, paraphrase) | explainx.ai, dated 2026-08-21, labels the post "paraphrased for clarity". flaviocopes (2026-10-02) gives DevDay as September 29, 2026 |
| GH1: Copilot Pro/Pro+/Business/Enterprise officially supported in OpenCode, 2026-01-16 | confirmed | github.blog changelog: datetime 2026-01-16, quote verbatim, "formal partnership" present |
| GH2, GH3 (§4), GH5 | confirmed | docs.github.com run-cli-programmatically; AUP section "4. Spam and Inauthentic Activity"; about-third-party-coding-agents (Pro+ and Copilot Max note) |
| GH4: proxy restriction | confirmed (third-party) | community.wappler.io post dated 2025-03-12 |
| GO1: third-party access to Code Assist, e.g. OpenClaw with Gemini CLI OAuth, is a violation | confirmed | gemini-cli@v0.64.0 docs/resources/tos-privacy.md lines 10–14; tag published 2026-10-13 |
| GO2: Antigravity FAQ (third-party login is a violation; `agy -p` is for scripting and CI; wrapping `agy` is unsupported on consumer plans; API key recommendation) | confirmed | antigravity.google/docs/faq (gzip HTML decoded): all four quotes are verbatim, and the question heading names Claude Code, OpenClaw and OpenCode |
| GO3: Antigravity terms quotes | confirmed; "§6" unverifiable | antigravity.google/terms: both quotes are verbatim. The section number is not visible in the page text |
| GO4: @antigravity post of 2026-02-27 | confirmed (third-party) | deepakness.com relays it verbatim; restrictions on Feb 23, restoration on Feb 27 |
| GO5/GO6: `gemini -p`; AI Pro 1,500 and AI Ultra 2,000 requests a day; AI Plus not supported | confirmed | README.md line 122, 241; quota-and-pricing.md lines 20–21, 98 at v0.64.0 |
| Section 2 note: Gemini CLI "authenticates only against Google services (GO1)" | corrected | GO1 does not say this, and `GOOGLE_GEMINI_BASE_URL` and `GOOGLE_VERTEX_BASE_URL` exist (configuration.md@v0.64.0). Edited in place |
| Gemini API key / Vertex row: "Google recommends these keys" | corrected | The FAQ names only Gemini Enterprise and Google AI Studio keys; Vertex is not named. Edited in place |
| ZA1–ZA4: supported-tools list (ZCode, Claude Code, Claude for IDE, Codex, OpenCode, Pi, Cursor, Cline, TRAE, Qoder, Droid, Kilo Code, Roo Code, Crush, Goose, Eigent, plus AutoClaw, OpenClaw, Hermes Agent, SillyTavern); not Qwen Code, Kimi CLI or Gemini CLI; usage-rule quotes; key split on 2026-10-16 | confirmed | docs.z.ai/*.md: the list matches exactly, every quote is verbatim, and api-key-management gives "Publication date: October 16, 2026". The Claude Code guide uses `ANTHROPIC_AUTH_TOKEN` with `https://api.z.ai/api/anthropic` |
| KI1/KI2/KI4: "for interactive use only", the non-automation, proxy and spoofing rules, the compatible-tools list, the third-party guides | confirmed | kimi.com community-guidelines.html: all quotes verbatim. The membership-guide gives the User-Agent sentence. third-party-agents lists Claude Code, OpenCode, Codex and Hermes Agent |
| KI3/KI5: `kimi -p` for scripts and CI with `kimi-code/kimi-for-coding`; provider types | confirmed | kimi-code@2.2.0 (published 2026-10-14) kimi-command.md lines 112–123; providers.md lines 3, 13–14 |
| AL1/AL2/AL3: interactive use only; no automated scripts or non-interactive use; tool list; updated 2026-10-11 | confirmed | alibabacloud.com coding-plan and more-tools pages: "Last Updated:Oct 11, 2026", all quotes verbatim, the integration list matches exactly |
| AL4: Token Plan, "Any tool that supports a custom Base URL and API Key" | confirmed | docs.qwencloud.com/token-plan/overview.md line 13 |
| MM1/MM2/MM3: any compatible tool; "designed for individual, interactive developer use"; PAYG for production; guide lists; ToS effective 2026-03-30 | confirmed | platform.minimax.io m-plan/faq.md lines 154 and 196; llms.txt lines 89–97; other-tools.md sections. The ToS JSON reads "Effective Date: March 30, 2026" and has the fees clause verbatim. The "ex Token Plan" lineage is confirmed by token-plan-notice.md; "ex Coding Plan" was not checked |
| QW1: Qwen OAuth free tier discontinued on 2026-04-15; built-in providers | quote confirmed; list corrected | qwen-code@v0.25.3 (published 2026-10-19) auth.md lines 7, 97. The list also includes Idealab. Edited in place |
| DS1/DS2/DS3 | confirmed | DeepSeek ToS released April 22, 2026 and effective April 29, 2026, with the key-sharing quote; it has no automation clause. The api-docs Claude Code page gives the base URL and auth token, and its sidebar list matches. deepseek-harness dsh-v0.2.1-rc.2 was published 2026-10-17; the README has only the MIT licence and no terms or provider list |
| OR1: "agree to comply with the applicable terms for each Model" | corrected (quote splice) | The openrouter.ai/terms wording is non-contiguous. The page shows "Last Updated: August 31, 2026", and the resale clause is verbatim. Edited in place |
| OR2 | confirmed | OpenRouter Claude Code guide: `ANTHROPIC_BASE_URL="https://openrouter.ai/api"`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY=""` |
| OC1/OC2: Go "designed for OpenCode and other coding agents…", "its own user agent", validated and problematic clients; the Zen gateway | confirmed | go.mdx and zen.mdx at v1.19.3: both lists match exactly |
| OL1/OL2/OL3 | confirmed | docs.ollama.com claude-code.md line 147 (`ollama launch claude --model gemma4:cloud --yes -- -p`); cloud.md; llms.txt integrations list. ollama.com/terms is "Last updated: May 2026" and the clause sits in section 4 |
| Repo facts: `.gitignore` line 5 is `docs/`; ZCode templates; `SP_IMPLEMENTER=luna`; `zcode-dispatch api-key set` | confirmed | `.gitignore`; docs/zcode-cli-findings.md line 278; bin/lib/zcode-dispatch.mjs line 1168; PLUGIN_README.md line 36 |
| Local versions: Claude Code 2.1.302, Codex CLI 0.163.0 | confirmed | `claude --version`, `codex --version` |

**Reliability assessment.** High. Every key claim and every evidence-register entry was re-opened at its primary source, or at the third-party source the report already labels as third-party. All ToS quotes that drive the no-go and gray verdicts match their sources verbatim: Anthropic legal, support and gateway pages, OpenAI SIWC, GitHub, Gemini CLI, Antigravity, Z.ai, Kimi, Alibaba and MiniMax. So do the dates (OpenCode PR, GitHub changelog, Z.ai key split, Alibaba last-updated, release tags) and the source-code identifiers (pi's Claude Code client ID and identity headers, its VS Code Copilot Chat headers, and OpenCode's own Copilot app). The 2026-01-09, 2026-04-04, 2026-05-13 and 2026-02-27 events rest only on third-party reporting; the report already says so. I made four small corrections: an over-broad Gemini CLI note, a recommendation attributed to Vertex that the source does not make, one spliced OpenRouter quote, and one incomplete provider list. None changes a matrix verdict or a design rule. The main open risk is unchanged: Anthropic's June and October support notes say third-party apps still draw from subscription limits, while the April email moved third-party harnesses to extra usage. The report keeps Claude-plan OAuth in non-Anthropic harnesses as no-go on the strength of AN1, and that position stands either way.
