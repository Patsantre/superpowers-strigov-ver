# 09 — Sandboxing and credential isolation for dispatched harnesses

Researched 2026-10-20. Read-only: nothing was installed or run except local presence checks (`sw_vers`, `whence`, `ls`, `docker version`). Primary versions read: `@anthropic-ai/sandbox-runtime` **v0.0.81** (GitHub tag and npm `latest`, 2026-10-20), Codex **rust-v0.163.0** (2026-10-15), OpenCode **v1.19.3** (2026-10-16), pi **v1.3.0**, Gemini CLI **v0.64.0** (2026-10-13), Qwen Code **v0.25.3** (2026-10-19), Apple `container` **1.6.0** (2026-10-20), Claude Code docs at code.claude.com (fetched 2026-10-20; installed CLI 2.1.302, latest release v2.1.304).

## Bottom line

1. **`srt` (Anthropic sandbox-runtime) can be the generic confinement layer for harnesses that have no sandbox of their own (pi, OpenCode, the ZCode CLI, DSH or Gemini/Qwen with their own sandbox off, `claude -p` with its Bash sandbox off).** It wraps any command in Seatbelt (macOS) or bubblewrap (Linux), adds a write allowlist, read denies and a domain allowlist enforced by a host-side proxy, and fails closed on a bad settings file. It is still a "Beta Research Preview" at 0.0.x, released about weekly. [source:anthropics/sandbox-runtime@v0.0.81:README.md:7,177-185] [local-run: npm view]
2. **srt can also keep the provider key out of the sandbox entirely.** With `credentials.envVars[].mode = "mask"` plus `network.tlsTerminate`, the harness sees only a `fake_value_<uuid>` sentinel, and the srt proxy, running outside the sandbox, swaps in the real key on egress to the key's `injectHosts`. Limits: `tlsTerminate` is EXPERIMENTAL, file masks work only on Linux, and srt substitutes in request **bodies** too. So a sentinel that enters the conversation (for example after the model runs `env`) reaches the provider as the real key and can be echoed back. The dispatcher must run a post-job secret scan. [source:…/src/sandbox/sandbox-config.ts:152-161,636-675,940; …/body-substitution.ts:1-15]
3. **Never nest Seatbelt.** A process that is already sandboxed cannot apply a second profile (`sandbox_apply: Operation not permitted`). Codex, DSH, `claude` with its Bash sandbox on, and Gemini/Qwen `-s` therefore must not run under srt on macOS, and a dispatcher started from a sandboxed Claude Bash call cannot start srt. Keep **Codex on its native sandbox**: it already uses the stronger shape, where the harness and its key stay outside the sandbox and only the tool commands run inside. [source:superpowers-strigov-ver@main:docs/zcode-sandbox-evaluation.md F2] [source:openai/codex@rust-v0.163.0:codex-rs/sandboxing/src/seatbelt_tests.rs:166-170]
4. **On this Mac, local loopback is the egress hole.** The TUN client's general-purpose proxy listens on 127.0.0.1:1082. srt's `allowLocalBinding: true` (needed for tests that start local servers, and naively for localhost model servers) lets the sandbox reach it, which removes the domain allowlist. Keep it off. Route local model servers through srt's proxy with an explicit `127.0.0.1:<port>` allow entry. Run local-server tests in the orchestrator's verification step instead. [source:…/sandbox-config.ts:726-743] [source:…/macos-sandbox-utils.ts:1280-1283] [source:docs/zcode-sandbox-evaluation.md F6,F7]
5. **Recommended split.** The dispatcher owns the boundary: env allowlist, a per-job srt settings file, key custody, egress allowlist, and post-run audits. The harness owns only tool policy (permission rules, its tool set, env scrub). Prose preambles are not a control.
6. **Minimum bar for SECURITY/DATA_LOSS phases on a third-party harness:** an OS-enforced write allowlist with protected paths, read denies over every credential store, a strict egress allowlist naming only the provider, a key that is unreadable inside the sandbox (srt mask or harness-outside-sandbox), fail-closed start, a passing canary probe for the pinned harness and srt versions, and a different-family reviewer (§9). Today only Codex meets this without new work. srt-wrapped pi/OpenCode with masking could meet it once the §10 smoke matrix passes.
7. **srt makes OS-enforced read-only reviewers possible on third-party harnesses:** `allowWrite` holds only the job's report directory and harness session state. This closes the "reviewer read-only is prose only" gap noted in 00-current-architecture R1/R2.

---

## 1. What has to be confined (threat model, in short)

| Asset | Threat from the dispatched model (prompt injection or error) | Control class |
|---|---|---|
| Files outside the job's worktree (home, other repos) | write or delete; plant persistence (`~/.zshrc`, harness config, git hooks) | OS write allowlist + protected paths |
| Credential stores (`~/.ssh`, `~/.aws`, `~/.config/gh`, `~/.codex`, `~/.zcode`, other channels' profile dirs, Keychain) | read, then exfiltrate | OS read denies + egress allowlist |
| The channel's own provider key | read from env, file or `/proc`; exfiltrate or write into the repo | key custody outside the sandbox (mask or harness-outside) + post-job scan |
| Network | exfiltration, downloading tools, pushing to remotes | default-deny egress, allowlisted hosts only |
| `.git/hooks`, `.git/config`, `.gitmodules` in the worktree | code that the orchestrator's later unsandboxed `git commit` runs | protected-path denies + pre/post hash check |
| Repo content run later (`package.json` scripts, `Makefile`, tests) | deferred execution as the user | **not sandboxable**: diff review is the gate [source:docs/zcode-sandbox-evaluation.md "Residual risks"] |

---

## 2. Anthropic sandbox-runtime (`srt`)

### 2.1 Identity and maturity

| Item | Value | Evidence |
|---|---|---|
| Repo / package / bin | `anthropics/sandbox-runtime` (the old `anthropic-experimental` path redirects); npm `@anthropic-ai/sandbox-runtime`; bin `srt` → `dist/cli.js` | [local-run: gh api, npm view] |
| License | Apache-2.0 | [local-run: gh api, npm view] |
| Version / cadence | 0.0.81 published 2026-10-20 (npm `latest`); 0.0.74 → 0.0.81 between 2026-08-25 and 2026-10-20 (8 releases in 8 weeks) | [local-run: gh api releases, npm view] |
| Status | "Beta Research Preview … APIs and configuration formats may evolve" | [source:anthropics/sandbox-runtime@v0.0.81:README.md:7-9] |
| Runtime deps | Node ≥ 22.12; deps `zod`, `commander`, `node-forge`, `@pondwader/socks5-server`. macOS needs no extra binary: the README still lists `rg`, but v0.0.81 runs and checks `rg` only on Linux; Linux needs `bwrap` (≥0.4, 0.5 recommended), `socat`, `rg` [corrected 2026-10-20: src/sandbox/sandbox-manager.ts:1643-1645 "ripgrep is Linux-only … rg is never invoked there"; only linux-sandbox-utils.ts imports ripGrep; code.claude.com/docs/en/sandbox-environments "On macOS you need no additional packages"] | [local-run: npm view] [source:README.md:682-735] |
| This machine | macOS 26.5.2 (25F84); `/usr/bin/sandbox-exec` present; `rg` at /opt/homebrew/bin; Node 26 at /opt/homebrew/bin; `srt` **not installed** | [local-run] |
| Used by | Claude Code's sandboxed Bash tool is built on this package | [docs:https://code.claude.com/docs/en/sandboxing] |

### 2.2 How it wraps an arbitrary command

- **CLI:** `srt [--settings <file>] [-d] [--control-fd <fd>] -- <cmd> [args…]`, or `srt -c '<shell string>'`. Argv mode shell-quotes each argument, and the wrapped string is run with `spawn(…, {shell:true})` and inherited stdio. The child's environment is srt's own environment plus the variables srt injects. [source:…/src/cli.ts:330-360,555-611]
- **Settings:** `~/.srt-settings.json` by default. A file that exists but is empty, unreadable or invalid, or a `--settings` path that is missing, makes srt **exit instead of falling back** (fail-closed). With no file at all, srt starts with defaults (no network, writes only to built-in paths), so the dispatcher must always pass `--settings`. [source:README.md:177-185] [docs:https://code.claude.com/docs/en/sandbox-environments]
- **macOS:** `/usr/bin/sandbox-exec -p <generated profile>`, with `(deny default)` as the base. It allows `process-exec`/`process-fork`, `process-info*` and `signal` only toward the **same sandbox**, a fixed list of mach services (including `com.apple.SecurityServer` and `com.apple.securityd.xpc`), and network outbound only to the proxy ports on localhost. [source:…/src/sandbox/macos-sandbox-utils.ts:1081-1114,1236,1317-1341]
- **Linux:** bubblewrap with the network namespace removed. Traffic reaches host-side proxies over bind-mounted Unix sockets bridged by `socat`. A seccomp layer blocks new `AF_UNIX` sockets and io_uring, and refuses new user/mount namespaces. The command gets a nested PID namespace, so it cannot see host processes or unfiltered helpers. [source:README.md:1048-1060,1192-1218,713-718]
- **Proxy:** srt runs HTTP and SOCKS5 proxies on the host, outside the sandbox. The child gets `HTTP(S)_PROXY`, `ALL_PROXY`, `GRPC_PROXY`, `NO_PROXY`, a per-run `TMPDIR`, `SANDBOX_RUNTIME=1`, and (with TLS termination) CA-trust variables. While srt owns the proxy, every proxy URL carries a random 16-byte **auth token** in its userinfo. [source:…/src/sandbox/sandbox-utils.ts:752-880] [source:…/src/sandbox/sandbox-manager.ts:1524-1530]
- **Policy decisions:** deny-list first, then the allow-list, then `strictAllowlist`. The CLI installs no ask callback, so any other host is **denied**. [source:…/sandbox-manager.ts:767-810]

### 2.3 Config surface a dispatcher needs

| Key | Semantics | Evidence |
|---|---|---|
| `network.allowedDomains` | allow-only; wildcards; optional `:port`; IPv6 bracketed. Empty = no network | [source:README.md:456-460] |
| `network.strictAllowlist` | no per-command widening and no ask; deterministic deny | [source:…/sandbox-config.ts:698-704] |
| `network.deniedResolvedAddresses` | extra CIDRs an allowed hostname must not resolve to. Built in: loopback, link-local, metadata IPs, the host's own interface addresses | [source:README.md:464-470] |
| `network.allowLocalBinding` | macOS: bind on, and connect to, **any** localhost port. "Every service listening on localhost becomes reachable, including any local proxy or forwarder that would carry traffic off the machine." [corrected 2026-10-20: the quote was cut mid-sentence; full text at sandbox-config.ts:739-742] Linux: ignored (private loopback) | [source:…/sandbox-config.ts:726-743] |
| `network.parentProxy` | upstream proxy for srt's own egress. **Falls back to `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` in srt's environment.** Connections through it skip the resolved-address check | [source:…/sandbox-config.ts:946-950] [source:README.md:468] |
| `network.tlsTerminate` | **[EXPERIMENTAL]** in-process MITM with an ephemeral CA (or one you supply). The child gets `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `CURL_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`, `GIT_SSL_CAINFO`, … pointing at the bundle. `excludeDomains` covers pinning/mTLS hosts | [source:…/sandbox-config.ts:840-945] [source:…/sandbox-utils.ts:752-770] |
| `filesystem.denyRead` / `allowRead` | reads are allowed by default; deny regions, re-allow inside them (allow wins, except a more specific deny) | [source:README.md:119,529-532] |
| `filesystem.allowWrite` / `denyWrite` | writes are denied by default; denyWrite wins. Always writable: stdio, `/tmp/claude`, `~/.npm/_logs`, `~/.claude/debug` | [source:README.md:534-539] |
| Mandatory write denies | `.bashrc .bash_profile .zshrc .zprofile .profile .gitconfig .gitmodules .ripgreprc .mcp.json`, dirs `.vscode/ .idea/ .claude/commands/ .claude/agents/ .git/hooks/`, `.git/config` (unless `allowGitConfig`). macOS checks at write time, nested repos included; Linux scans at wrap time to `mandatoryDenySearchDepth` (default 3) | [source:README.md:1142-1190] [docs:https://code.claude.com/docs/en/sandbox-environments] |
| `credentials.envVars[]` / `files[]` | `deny` withholds the value; `mask` injects a sentinel. Per-entry `injectHosts` defaults to `allowedDomains`. Optional `extract`/`decode:"jwt"`. `allowPlaintextInject` defaults to false | [source:…/sandbox-config.ts:152-161,276-535,636-675] |
| `allowUnixSockets` / `allowAllUnixSockets` | blocked by default. macOS allows by path; Linux is all-or-nothing | [source:README.md:513-523] |
| `allowAppleEvents`, `enableWeakerNetworkIsolation`, `allowPty`, `allowMachLookup` | all off by default. AppleEvents "removes code-execution isolation" | [source:README.md:594-602] |
| `--control-fd` | live updates to the network lists from the parent. The filesystem rules are fixed at wrap time | [source:README.md:187-255] |
| `srt proxy` | proxy-only mode with an external decider process, for a workload that runs elsewhere (for example a container) | [source:README.md:257-259] [source:anthropics/sandbox-runtime@v0.0.81:docs/srt-proxy.md] |

### 2.4 Credential masking: how it works and where it leaks

- The real value is read from **srt's own environment** (outside the sandbox). The child gets `fake_value_<uuid4>`, padded to the real value's length. The sentinel→real map lives "only in process memory — it is never written to disk and never logged" [corrected 2026-10-20: the quote dropped "it is"; credential-sentinel.ts:7-8]. Substitution is gated per credential by that credential's `injectHosts`, so one credential cannot be laundered through another's host. [source:…/src/sandbox/credential-sentinel.ts:1-62]
- Headers **and request bodies** are rewritten (a streaming byte scan). Bodies with a `Content-Encoding` pass through unchanged, which fails safe. [source:…/src/sandbox/body-substitution.ts:1-15,58-80]
- I found **no response-side scrubbing** of real values in `http-proxy.ts`, `tls-terminate-proxy.ts` or `credential-sentinel.ts`. [source: grep at v0.0.81; absence not proven, medium confidence]
- **Reflection path:** the model runs `env` → the sentinel lands in the transcript → the harness's next LLM request body carries it → srt substitutes the real key → the provider model sees its own key and may repeat it → the reply comes back unscrubbed. The real key can then be written into the worktree. The provider already holds its own key, so the main harm is the key landing in artifacts or logs. **Mitigation:** the dispatcher, which knows the real value, scans the diff, report and logs for it after each job and quarantines the result on a match. Where the harness supports it, also strip the variable from its tool env.
- Masking needs TLS termination, so the harness must trust srt's CA. srt sets the trust variables. Clients that pin certificates, or that ignore these variables, break unless excluded (and an excluded host gets no injection). [source:README.md:472-477,601]
- **macOS:** file masks degrade to **deny** (Seatbelt cannot redirect reads). A harness that keeps its key only in a file (the ZCode CLI) therefore cannot be masked on macOS. [source:…/sandbox-config.ts:156-160] [source:README.md:601]

### 2.5 Limitations that matter for dispatch

| Area | Behavior | Consequence for the dispatcher | Evidence |
|---|---|---|---|
| Nested Seatbelt | fails with `sandbox-exec: sandbox_apply: Operation not permitted` (exit 71) | do not wrap Codex/DSH/claude-with-sandbox/Gemini `-s` on macOS. If the dispatcher itself runs inside a sandbox, refuse with a clear message (detect `SANDBOX_RUNTIME=1`, or try a `srt -- /usr/bin/true` preflight) | [source:docs/zcode-sandbox-evaluation.md F2 (local-run on macOS 15.7.7)] [source:openai/codex@rust-v0.163.0:codex-rs/sandboxing/src/seatbelt_tests.rs:166-170] [source:…/sandbox-utils.ts:793] |
| Nested user namespaces (Linux) | refused by seccomp, so nested bwrap/srt, rootless podman and Chromium's namespace sandbox fail | headless browser tests need `allowNestedUserNamespaces` (which weakens the sandbox) or should run outside | [source:README.md:713-718] |
| Loopback | macOS allows only the proxy ports. `allowLocalBinding` opens all of localhost, including 127.0.0.1:1082 here | tests that start local servers and localhost model servers conflict with egress control (see §6) | [source:…/macos-sandbox-utils.ts:1280-1341] [source:docs/zcode-sandbox-evaluation.md F6,F7] |
| `NO_PROXY` | srt sets `NO_PROXY=localhost,127.0.0.1,::1,169.254/16,10/8,172.16/12,192.168/16` | a harness pointed at `http://127.0.0.1:11434` dials it directly, which Seatbelt blocks. Override `NO_PROXY=` inside the command and allow `127.0.0.1:11434` explicitly | [source:…/sandbox-utils.ts:822-838] |
| Proxy auth token | proxy URLs carry `user:token@localhost:port` | each harness HTTP client must support userinfo proxy auth (undici and Bun are expected to; the ZCode CLI is [unverified]) | [source:…/sandbox-manager.ts:1524-1530] |
| Unix sockets | blocked by default (docker.sock, ssh-agent, gpg-agent) | desired; a harness that needs its own socket must have it listed | [source:README.md:513-523] |
| git | `.git/hooks` and `.git/config` are write-denied. git over SSH goes through the proxy via an injected `GIT_SSH_COMMAND`. A linked worktree's gitdir lies outside the root, so index refreshes and `git add` fail unless that gitdir is writable | fine for implementers, who never stage (I10); reviewers stay read-only | [source:README.md:1064,1142-1166] [source:docs/zcode-sandbox-evaluation.md breakage table] |
| Package managers | caches under `~` are not writable (only `~/.npm/_logs`) | redirect caches (`npm_config_cache`, `YARN_CACHE_FOLDER`, `BUN_INSTALL_CACHE_DIR`, `GOCACHE`, `GOMODCACHE`, `CARGO_HOME`) into the job dir, and allow registries only for phases that install | [source:README.md:539] [source:docs/zcode-sandbox-evaluation.md] |
| Node `fetch` | on macOS/Linux srt does **not** set `NODE_USE_ENV_PROXY`, so plain Node `fetch()` ignores `HTTP_PROXY` and is blocked | harnesses must use a proxy-aware client (pi uses undici `EnvHttpProxyAgent`; Bun honors the env) | [source:README.md:1066] [source:earendil-works/pi@v1.3.0:packages/coding-agent/src/core/http-dispatcher.ts:45-48,87] |
| Exit status | srt exits **0** when the wrapped command dies from SIGINT/SIGTERM, and exits 1 on any other signal or its own errors | the dispatcher must classify cancel/timeout from its own records, never from srt's exit code. Distinguish srt start errors through stderr or a doctor preflight | [source:…/src/cli.ts:614-640] |
| Install location | a copy inside a writable project can be rewritten from inside and then runs unsandboxed next time | install it globally or in the plugin data dir, **never in a repo that may be a workspace** (this plugin dogfoods itself) | [source:README.md:1277] |
| Keychain | the base profile allows the `SecurityServer` and `securityd.xpc` mach lookups | Keychain items readable via `/usr/bin/security` may be readable inside the sandbox [unverified]. Don't rely on the Keychain for in-sandbox isolation (§5) | [source:…/macos-sandbox-utils.ts:1112,1236] |
| Domain fronting / broad domains | the hostname-based allowlist can be fronted, and broad allows (github.com) permit pushes | allow only exact provider API hosts; avoid broad CDN wildcards | [source:README.md:1267-1273] |
| Overhead | "Very low" per Anthropic. No local measurement | measure in the §10 smoke run | [docs:https://code.claude.com/docs/en/agent-sdk/secure-deployment] |

### 2.6 How Claude Code uses it (useful reference semantics)

- The built-in sandbox wraps **only Bash, PowerShell and Monitor** commands. Read/Edit/Write/WebFetch, hooks, MCP servers, status line and `apiKeyHelper` run outside it. [docs:https://code.claude.com/docs/en/sandboxing]
- `failIfUnavailable: true` stops startup when the sandbox cannot run. `allowUnsandboxedCommands: false` ignores `dangerouslyDisableSandbox`; in `bypassPermissions` that unsandboxed retry otherwise runs with no prompt. `strictAllowlist` denies hosts that are not allowlisted in every mode, while `bypassPermissions` without it lets them through. [docs:https://code.claude.com/docs/en/sandboxing]
- `sandbox.credentials` supports `deny`/`mask`. `mask` entries, `tlsTerminate` and `allowPlaintextInject` are honored only from user, managed or `--settings` scope, never from repo settings. `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` strips credentials from all subprocesses. [docs:https://code.claude.com/docs/en/sandboxing] [docs:https://code.claude.com/docs/en/env-vars]
- Anthropic's own guidance: run `--dangerously-skip-permissions` sessions "inside a container, a VM, or the sandbox runtime". `srt claude` is a documented launch. It needs writes to the project, `~/.claude`, `~/.claude.json` and `/private/tmp` (or `CLAUDE_CODE_TMPDIR`), plus the provider host. On a third-party provider it also needs `api.anthropic.com`, unless `skipWebFetchPreflight: true` is set. [docs:https://code.claude.com/docs/en/sandbox-environments]
- Deny rules hold in `bypassPermissions`. That mode skips protected-path checks; `acceptEdits` auto-approves edits and `mkdir/touch/rm/rmdir/mv/cp/sed` inside the cwd only. In `-p` without `--permission-prompt-tool`, calls that need approval are denied. [docs:https://code.claude.com/docs/en/permission-modes]

---

## 3. Native sandboxes per harness

| Harness | Native OS sandbox | Scope | Network control | Key exposure to the model's shell | Evidence |
|---|---|---|---|---|---|
| **Codex CLI** 0.163 | macOS Seatbelt; Linux bubblewrap + seccomp (legacy Landlock rejected for filesystem-restricted policies); Windows native | **tool commands only**; the harness runs outside | `workspace-write` network off by default (`sandbox_workspace_write.network_access`); a managed `codex-network-proxy` with per-profile domain allow/deny and MITM hooks; `codex sandbox [-P profile] -- <cmd>` wraps any command | default `shell_environment_policy` is `inherit=all`, `ignore_default_excludes=true`, so `*KEY*`/`*SECRET*`/`*TOKEN*` **are inherited** unless `ignore_default_excludes=false`. Permission profiles support deny-read globs (`"**/*.env" = "none"`) | [source:openai/codex@rust-v0.163.0:codex-rs/linux-sandbox/README.md] [source:…/codex-rs/network-proxy/README.md] [source:…/codex-rs/cli/src/main.rs:192,464-485] [source:…/codex-rs/config/src/shell_environment_policy.rs:135-136] [source:…/codex-rs/protocol/src/shell_environment.rs:138-146] [source:…/codex-rs/sandboxing/src/seatbelt.rs:624-660] |
| **Claude Code `-p`** | Seatbelt / bubblewrap via srt | Bash/PowerShell/Monitor only | proxy allowlist; `strictAllowlist` | the key (`ANTHROPIC_AUTH_TOKEN`) lives in Claude's env. Bash gets it unless `sandbox.credentials` denies it or `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` is set. The Read tool is unsandboxed (needs deny rules) | [docs:https://code.claude.com/docs/en/sandboxing] [docs:https://code.claude.com/docs/en/env-vars] |
| **OpenCode** 1.19.3 / 2.1.0 | **none** | — | none (honors `HTTP(S)_PROXY`, `NODE_EXTRA_CA_CERTS`) | bash inherits the full env; `auth.json` (0600) sits in `$XDG_DATA_HOME/opencode` | [source:anomalyco/opencode@v1.19.3:packages/opencode/src/auth/index.ts:10,79,88] [source:…/packages/web/src/content/docs/network.mdx] [source:docs/research/universal-dispatchers/02-opencode.md §8] |
| **pi** 1.3.0 | **none** (docs recommend containers; an example extension sandboxes only `bash` with srt 0.0.26) | — | none (undici `EnvHttpProxyAgent`) | the bash tool spawns with `{...process.env}`; `auth.json` 0600 | [source:earendil-works/pi@v1.3.0:packages/coding-agent/src/utils/shell.ts:138-150] [source:docs/research/universal-dispatchers/03-pi.md §7-8] |
| **ZCode CLI** | none in `--mode yolo` | — | own client: `ZCODE_HTTP_PROXY` only | the key sits in plain text in the personal provider config (0600) with **no env indirection**; Bash inherits the CLI env | [source:superpowers-strigov-ver@main:docs/zcode-cli-findings.md:243,301-303] |
| **DSH** (DeepSeek harness) | Seatbelt / bwrap+Landlock / Windows ACL, fail-closed | file writes only ("network and process visibility are outside this vocabulary"); `.git` stays writable | none | keys come from env / `.env` (headless) | [source:docs/research/universal-dispatchers/04-dsh-and-harness-survey.md §6-8] |
| **Gemini CLI** 0.64 | re-execs **the whole CLI** under `sandbox-exec` (profiles `permissive-/restrictive-/strict-` × `open/proxied`), or Docker/Podman/runsc/LXC; also "tool sandboxing" | whole process (or per tool) | `*-proxied` profiles allow only `localhost:8877`; the user supplies `GEMINI_SANDBOX_PROXY_COMMAND` | env | [source:google-gemini/gemini-cli@v0.64.0:docs/cli/sandbox.md:71-104,267-292] [source:…/packages/cli/src/utils/sandbox.ts:314-338] |
| **Qwen Code** 0.25.3 | Linux `tools.executionSandbox` (bwrap/Landlock, tools only; "model transport, authentication and session storage remain on the host"); macOS `sandbox-exec` profiles; Docker/Podman | tools (Linux) / whole CLI (macOS, containers) | `network: closed` with bwrap; proxied profiles via `QWEN_SANDBOX_PROXY_COMMAND` on :8877 | "Reads remain broad: this mode does not hide host secrets" | [source:QwenLM/qwen-code@v0.25.3:docs/users/features/sandbox.md:5-27,170-219] |

**Takeaway:** only Codex (and Qwen Code's Linux mode) has the **harness-outside / tools-inside** shape. [corrected 2026-10-20: Claude Code's own Bash sandbox has that shape too, for shell commands only (its Read/Edit tools stay unsandboxed, as the §3 row and the §7.3 "Alternative without srt" say), and Gemini CLI documents a "Tool sandboxing" mode that isolates "individual tool executions … instead of sandboxing the entire Gemini CLI process" (google-gemini/gemini-cli@v0.64.0:docs/cli/sandbox.md:267-275; its network and key handling are unverified). DSH sandboxes bash per command but confines writes only. It leaves process visibility and reads open, so the key-isolation argument below does not hold for it (deepseek-ai/deepseek-harness@dsh-v0.2.1-rc.2:docs/subsystems/sandbox.md:11). Codex remains the only one that combines tools-only confinement, network control and a key outside the sandbox.] There the sandboxed shell cannot inspect the harness process (macOS profiles allow `process-info*` only within the same sandbox; Linux uses PID namespaces), so the key can stay in harness memory. With whole-process wrapping (srt around pi, OpenCode or ZCode), the shell runs in the **same** sandbox as the harness. It can then read the harness's env (Linux `/proc/<pid>/environ`; on macOS probably through `ps eww` [unverified]) and any file the harness can read. That is why masking, not env scrubbing, is the credential control for those harnesses. [source:…/macos-sandbox-utils.ts:1091] [source:README.md:1212]

---

## 4. Containers and VMs

| Option | Isolation | Worktree mount | Egress control | Credentials | Cost / latency on this Mac | Evidence |
|---|---|---|---|---|---|---|
| **Docker Desktop** (installed: client 29.8.2) | Linux containers in one shared VM | bind mount (VirtioFS). A linked worktree also needs the main repo's `.git/worktrees/<n>` and common dir mounted at the same absolute path | default bridge = full egress. Options: `--network none` plus a mounted proxy socket, or `docker network create --internal` plus a proxy container. Anthropic's hardened example: `--cap-drop ALL --security-opt no-new-privileges --read-only --network none --user 1000:1000 -v proxy.sock` | `-e KEY` puts the key in the container env, visible to the model, unless a host-side injecting proxy is used | an always-on VM holding memory (16 GB host); an image per harness to maintain; first start pulls the image; bind-mount IO is slower for `node_modules`-heavy work [unverified] | [local-run: docker version] [docs:https://code.claude.com/docs/en/agent-sdk/secure-deployment] |
| **Dev container** (Claude Code reference) | Docker + iptables default-DROP firewall | `.devcontainer` mounts the workspace | allowlist built from GitHub meta IPs, `registry.npmjs.org`, `api.anthropic.com`, …; **also allows OUTPUT to the host's /24** | per container | as Docker | [source:anthropics/claude-code@d945a61bc6:.devcontainer/init-firewall.sh:27-119] |
| **Docker Sandboxes (`sbx`)** | microVM per sandbox, own kernel and Docker engine; agent has sudo inside | direct (rw), `--clone` (ro + private clone), or mountless | host-side proxy, **deny-by-default**, `sbx policy ls`; UDP/ICMP blocked | host-side proxy adds auth headers: "The raw credential values never enter the VM" | free local CLI; persistent VM state. Supported agents include OpenCode and a Shell agent; pi documents a `pi-kit` and `sbx exec <name> -- pi -p …` | [docs:https://docs.docker.com/ai/sandboxes/security/] [docs:https://docs.docker.com/ai/sandboxes/agents/] [source:docs/research/universal-dispatchers/03-pi.md §8] |
| **Apple `container`** 1.6.0 | a lightweight VM **per container** (Virtualization.framework); requires macOS 26 + Apple silicon (this machine qualifies); **not installed** | `-v` / `--mount …,readonly`, `--read-only`, `--tmpfs` | `container network create --internal` gives host-only networks; no domain allowlist built in, so a host proxy must listen on the vmnet gateway | `-e` / `--env-file` (visible inside); `--ssh` forwards the agent | freed guest memory is not returned to macOS (partial ballooning) | [source:apple/container@1.6.0:README.md] [source:…/docs/command-reference.md:29-78,818-837] [source:…/docs/technical-overview.md:26-30,55-59] |
| **gVisor / Firecracker** | user-space kernel / microVM | — | vsock to a host proxy | proxy injection | Linux only; gVisor file IO "up to 10-200× slower" for open/close-heavy patterns | [docs:https://code.claude.com/docs/en/agent-sdk/secure-deployment] |

**Containers on this Mac, one specific risk:** Docker Desktop's `host.docker.internal` may reach services bound to the host's 127.0.0.1, including the TUN client's proxy on :1082 [unverified]. The reference devcontainer firewall explicitly allows the host /24 [source above]. A container setup therefore needs the same check as srt's `allowLocalBinding`: from inside, `curl -x http://host.docker.internal:1082 https://example.com` must fail.

---

## 5. Credential-isolation patterns compared

| Pattern | Where the real key lives | Readable by the model's shell? | Works with | ToS notes | Verdict |
|---|---|---|---|---|---|
| **A. Env-only key + sandbox denies config files** | harness env | **yes**: inherited by bash (pi, OpenCode, ZCode), or readable via `/proc`/`ps` in the same sandbox. Claude `SUBPROCESS_ENV_SCRUB` and Codex `ignore_default_excludes=false` remove it from tool env; real isolation needs harness-outside | all | neutral | acceptable only for **PAYG keys with a spend cap and a dispatcher-dedicated key**, together with a strict egress allowlist |
| **B. srt `mask` (sentinel + proxy injection)** | srt process memory, outside the sandbox | no, except through the body-reflection path (§2.4) | env-keyed harnesses: pi, OpenCode, `claude -p` (`ANTHROPIC_AUTH_TOKEN`), DSH, Gemini/Qwen. Not the ZCode CLI on macOS (file key) | transparent: same request bytes and User-Agent, only the auth value swapped; TLS is re-originated by srt. Fine for PAYG. For the **Z.ai Coding Plan**, the terms ban "resale or proxying" without defining it, so whether a transparent local header swap counts is [unverified] and goes to the ToS researcher [corrected 2026-10-20: the terms never say "proxying". The §4 text reads "you may not resell, sub-resell, repackage, aggregate, proxy or otherwise provide the GLM Coding Plan to any third party", so the proxy ban is about giving the plan to third parties. Separately, the quota is limited to the supported tools, not "directly invoking model APIs from your own applications" (docs.z.ai/legal-agreement/subscription-terms.md §4, fetched 2026-10-20). A single-user local header swap in front of a listed tool is not named either way, so it stays a ToS question.] | **preferred for third-party harnesses**, plus a post-job secret scan |
| **C. Dispatcher-run localhost gateway** (dummy key in the harness; base URL `http://127.0.0.1:<p>/<job-token>`; the gateway adds the key and forwards over TLS) | gateway memory | no (header-only injection, no body reflection) | any harness with a base-URL setting | a re-originating or **protocol-translating** gateway (LiteLLM etc.) changes the client identity: PAYG only, never subscription plans (Z.ai bans "directly invoking model APIs from your own applications"; Kimi/Alibaba plans are interactive-only anyway) | viable, but needs the loopback route through srt (§6) and a per-job random path token so other local processes cannot use it; more code than B |
| **D. Per-profile config dirs, 0700/0600** | harness file | **yes** within the same job (the harness must read it); **no** for other profiles **if** srt denies reading the dispatcher state root apart from the current job | all | neutral | necessary hygiene (already in zcode-dispatch: `ensurePrivateDir`, `writePrivateJson`), not isolation |
| **E. macOS Keychain read by the wrapper** | Keychain (at rest) → passed to srt's env (B) or the gateway (C) | the wrapper reads it outside the sandbox. But srt's profile permits the securityd lookups, so an item whose ACL trusts `/usr/bin/security` may be readable from inside [unverified] | wrapper-side only | neutral | good **at rest**; never let the harness itself read the Keychain. Simpler alternative: a 0600 file under a state dir that srt `denyRead`s |
| **F. Harness-native custody** (Codex `auth.command`, Claude `apiKeyHelper`, pi `"!cmd"`) | harness memory | Codex: no, if the key file is a deny-read glob. Claude: `apiKeyHelper` runs outside the Bash sandbox. pi: **yes** (whole process in one sandbox; the model can rerun the command) | Codex, Claude | neutral | use for Codex (already the 05 report's design) |
| **G. Log/output redaction** | — | — | all | — | keep `keyRedactor`; add a **post-job scan of the diff, report and logs for the real key and the sentinel**; fail the job (`credential-leak`) on a match |

---

## 6. Network egress and the local TUN-mode proxy

| Fact | Evidence |
|---|---|
| Seatbelt cannot name hosts or IPs. Only `*` or `localhost:<port>` is accepted, so domain filtering requires a proxy | [source:docs/zcode-sandbox-evaluation.md F4] |
| On macOS, srt allows only its proxy ports on loopback. Its proxy, outside the sandbox, dials upstream, and that traffic follows the system route, so TUN mode keeps working transparently | [source:…/macos-sandbox-utils.ts:1317-1341] [source:docs/zcode-cli-findings.md:9 (198.18.x fake-IP DNS observed)] |
| If srt's own environment holds `HTTPS_PROXY=http://127.0.0.1:1082`, srt uses it as `parentProxy`, and the resolved-address check is then skipped for that hop | [source:…/sandbox-config.ts:946-950] [source:README.md:468] |
| `allowLocalBinding: true` (macOS) makes 127.0.0.1:1082 reachable from inside, so egress becomes unlimited | [source:…/sandbox-config.ts:735-743] [source:docs/zcode-sandbox-evaluation.md F7] |
| Fake-IP DNS (198.18.0.0/15) is not in srt's default denied set unless it equals an interface address, so allowed hostnames should still dial [unverified] | [source:README.md:466] |

**Rules for the dispatcher:**
1. Spawn srt **without** `HTTP(S)_PROXY`/`ALL_PROXY` in its environment; TUN carries srt's egress. Use explicit `network.parentProxy` (with `noProxy: "localhost,127.0.0.1"`) only when the user's client is not in TUN mode.
2. `allowLocalBinding: false` always on macOS. Tests that need local servers run in the orchestrator's gate step. On Linux the sandbox loopback is private, so the conflict does not exist there. [source:README.md:462]
3. Egress allowlist per role, as exact host + `:443`:
   - implementer: the provider API host(s), plus registries only when the phase plan says it installs dependencies;
   - reviewer: the provider host only;
   - SECURITY/DATA_LOSS: the provider host only, with dependencies preinstalled by the orchestrator.
   Always `strictAllowlist: true`, plus `deniedResolvedAddresses` for RFC1918/CGNAT/ULA.
4. **Local models** (Ollama, LM Studio, llama.cpp server): add an IP-literal entry such as `"127.0.0.1:11434"` (srt does not apply the resolved-address check to allowlisted literals), and run the harness with `NO_PROXY=` and `no_proxy=` cleared inside the `-c` command so the request goes through srt's proxy. Whether each client then proxies a plain-`http://` loopback URL is [unverified] (undici and Bun need a smoke test). [source:README.md:468] [source:…/sandbox-utils.ts:822-838]
5. Harness housekeeping traffic must be turned off or allowlisted deliberately:
   - OpenCode: `OPENCODE_DISABLE_AUTOUPDATE`, `OPENCODE_DISABLE_MODELS_FETCH` (with `OPENCODE_MODELS_PATH`), `OPENCODE_DISABLE_LSP_DOWNLOAD`;
   - Claude: `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, `skipWebFetchPreflight: true`, deny `WebFetch`/`WebSearch`;
   - pi: `PI_OFFLINE=1`, `PI_TELEMETRY=0`.

   [source:anomalyco/opencode@v1.19.3:packages/core/src/flag/flag.ts; packages/opencode/src/effect/runtime-flags.ts] [docs:https://code.claude.com/docs/en/env-vars] [docs:https://code.claude.com/docs/en/sandbox-environments] [source:docs/research/universal-dispatchers/03-pi.md]

---

## 7. Recommended layered design

### 7.1 Who enforces what

| Layer | Owner | Controls | Status today |
|---|---|---|---|
| L0 pre-spawn | dispatcher | git-tree guard; per-workspace reservation (write tasks only); **env allowlist** (`ENV_ALLOW`/`ENV_DENY`); per-job harness home built from a read-only template; prompt and key never in argv; key read from a 0600 store **by the dispatcher**; refuse when nested (`SANDBOX_RUNTIME=1`) | mostly exists in zcode-dispatch [source:bin/lib/zcode-dispatch.mjs:66-93,212-226,238-262] |
| L1 OS boundary | dispatcher (srt) **or** harness-native (Codex), never both on macOS | write allowlist (worktree, job session dir, job tmp); protected paths; read denies (credential stores, the dispatcher state root apart from this job, other profiles); strict egress allowlist; `credentials.envVars` mask; Unix sockets, AppleEvents and local binding off | new |
| L2 harness policy | harness flags/config written by the adapter | tool set (pi `--tools`, OpenCode `permission`, Claude `--permission-mode` + deny rules + `--disallowedTools`); tool env scrub (Claude `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`, Codex `shell_environment_policy.ignore_default_excludes=false`); housekeeping-traffic flags | partly (ZCode `DISALLOWED_TOOLS`) [corrected 2026-10-20: on main the hook exists but `DISALLOWED_TOOLS = []`, so no tool is disallowed today; bin/lib/zcode-dispatch.mjs:55,944] |
| L3 post-run | dispatcher | hash check of `.git/hooks`, `.git/config` and the worktree `.git` file (pre vs post); protected-path diff check; **secret scan** of the diff, report and logs for the real key and the sentinel; redaction; srt violation lines from stderr with `-d`, or `log stream` on macOS, appended to the job log; error classes `sandbox-start`, `sandbox-violation`, `credential-leak` | redaction exists; the rest is new (the hash check was flagged in docs/zcode-sandbox-evaluation.md) |

### 7.2 Channel-profile fields (additions to the 00 report's profile)

`sandbox: native | srt | container | none`; `sandbox.profile: implementer | reviewer | risk`; `egress: [host:port…]`; `credential: {source: store|keychain, var: NAME, mode: mask|env|native, injectHosts:[…]}`; `harnessHome: template dir`; `nestsSeatbelt: true|false` (Codex, DSH, claude-with-sandbox, Gemini/Qwen `-s` = true, so they are incompatible with `srt`).

### 7.3 srt invocation patterns (sketch; not run)

The dispatcher writes `<job>/srt.json` (0600) **outside every `allowWrite` path**, and spawns srt with a filtered environment, cwd = worktree, as a detached process group:

```bash
# env given to srt itself: allowlisted basics + the REAL key (srt reads it, the child gets the sentinel)
env -i PATH="$PATH" HOME="$HOME" LANG="$LANG" TERM=dumb \
    CLAUDE_CODE_TMPDIR="$JOB/tmp" \
    DEEPSEEK_API_KEY="$(dispatcher-read-key deepseek)" \
  srt --settings "$JOB/srt.json" -- \
    env PI_CODING_AGENT_DIR="$JOB/home/pi" PI_OFFLINE=1 PI_TELEMETRY=0 \
        npm_config_cache="$JOB/cache/npm" \
    pi --mode json --model deepseek/<model> --no-approve -ne -ns -np --no-mcp < "$JOB/prompt.md"
```

(`$(…)` stands for the runner reading the key in-process; the runner sets it in the child's `env` object, never on a command line.) `CLAUDE_CODE_TMPDIR` is the variable srt itself reads to choose the child's `TMPDIR` [source:…/sandbox-utils.ts:800-806].

**`<job>/srt.json`, implementer, strict tier (macOS paths are real paths):**

```json
{
  "network": {
    "allowedDomains": ["api.deepseek.com:443"],
    "deniedDomains": [],
    "strictAllowlist": true,
    "allowLocalBinding": false,
    "allowAllUnixSockets": false,
    "deniedResolvedAddresses": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "fc00::/7"],
    "tlsTerminate": {}
  },
  "filesystem": {
    "denyRead": ["~/"],
    "allowRead": ["<WORKTREE>", "<GIT_COMMON_DIR>", "<JOB>/home", "<JOB>/tmp", "<toolchain dirs under ~, e.g. ~/.bun, ~/.nvm, ~/.cargo, ~/go>"],
    "allowWrite": ["<WORKTREE>", "<JOB>/home/sessions", "<JOB>/tmp", "<JOB>/cache"],
    "denyWrite": ["<JOB>/home/config", "<WORKTREE>/.envrc", "<WORKTREE>/.claude"]
  },
  "credentials": {
    "envVars": [{ "name": "DEEPSEEK_API_KEY", "mode": "mask", "injectHosts": ["api.deepseek.com"] }]
  },
  "mandatoryDenySearchDepth": 5,
  "allowAppleEvents": false,
  "enableWeakerNetworkIsolation": false,
  "allowPty": false
}
```

- **Default tier** (lower breakage): replace `denyRead: ["~/"]` with an explicit list: `~/.ssh`, `~/.aws`, `~/.config/gh`, `~/.config/gcloud`, `~/.azure`, `~/.kube`, `~/.docker`, `~/.netrc`, `~/.git-credentials`, `~/.npmrc`, `~/.pypirc`, `~/.codex`, `~/.zcode`, `~/.claude`, `~/.claude.json`, `~/.local/share/opencode`, `~/.pi`, `~/Library/Keychains`, `<plugin state root>`, minus `allowRead` for `<JOB>`. The list comes from Anthropic's "files to exclude" table plus the harness stores. [docs:https://code.claude.com/docs/en/agent-sdk/secure-deployment]
- **Reviewer:** the same file with `"allowWrite": ["<WORKTREE>/.superpowers/sdd/<job>/", "<JOB>/home/sessions", "<JOB>/tmp"]` makes the repo **read-only at the OS level** (HEAD cannot move, the index cannot change). Such a task needs no write reservation.
- **Per harness** (inner command after `--`, or `-c` where shell expansion is needed):
  - **OpenCode:** `env XDG_CONFIG_HOME=$JOB/home/cfg XDG_DATA_HOME=$JOB/home/data XDG_STATE_HOME=$JOB/home/state XDG_CACHE_HOME=$JOB/cache OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_DISABLE_CLAUDE_CODE=1 opencode run --format json --model <p/m> …`. `run` uses an in-process fetch shim and opens no port, which suits `allowLocalBinding:false`. [source:anomalyco/opencode@v1.19.3:packages/opencode/src/cli/cmd/run.ts:1-15,899-951] [source:…/packages/core/src/global.ts:3-14,64]
  - **ZCode CLI:** use `-c` so the CLI's own client gets srt's proxy: `srt --settings F -c 'ZCODE_HTTP_PROXY="$HTTPS_PROXY" exec <node> <zcode.cjs> -p - --output-format json --mode yolo …'`. The CLI otherwise ignores `HTTP(S)_PROXY`. Whether its client accepts the userinfo token is [unverified]. The key cannot be masked on macOS (file only). [source:docs/zcode-cli-findings.md:9,301-303]
  - **`claude -p`** (third-party Anthropic-compatible endpoint): `srt … -- claude -p --output-format json --permission-mode bypassPermissions --disallowedTools WebFetch,WebSearch --settings '{"sandbox":{"enabled":false},"skipWebFetchPreflight":true}'`, with `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` (masked, `injectHosts` = the endpoint host), `CLAUDE_CONFIG_DIR=$JOB/home/claude` and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`. Add `denyWrite` for `$CLAUDE_CONFIG_DIR/settings.json` and its hooks/agents/commands. The inner Bash sandbox is off to avoid nesting.
    - **Alternative without srt:** `claude -p --permission-mode acceptEdits` + `sandbox{enabled, failIfUnavailable, allowUnsandboxedCommands:false, network.strictAllowlist, credentials.envVars:[ANTHROPIC_AUTH_TOKEN deny]}` + `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` + Read/Edit deny rules on credential paths. Here the harness sits outside and its tools inside; the Read/Edit tools are confined by permission rules, not the OS. [docs:https://code.claude.com/docs/en/sandboxing] [docs:https://code.claude.com/docs/en/permission-modes]
  - **Codex:** no srt. `codex exec -s workspace-write|read-only -c sandbox_workspace_write.network_access=false -c shell_environment_policy.ignore_default_excludes=false`, plus a permissions profile that marks the key file and the credential stores `"none"`. For tool-command egress, use `[permissions.<p>.network.domains]`. [source:openai/codex@rust-v0.163.0:codex-rs/linux-sandbox/README.md:80-86] [source:…/codex-rs/network-proxy/README.md]
  - **DSH / Gemini / Qwen:** under srt, switch their own sandbox off (`DSH_PERMISSION_MODE=danger-full-access`; no `-s`) and let srt confine them [inference; unverified]. Otherwise use their native mode without srt.

### 7.4 Fail-closed rules and `doctor` checks

- Refuse a task when: `srt` is missing or not the pinned version; a dry run `srt --settings <job>/srt.json -- /usr/bin/true` exits ≠0 or prints `sandbox_apply`; `SANDBOX_RUNTIME=1` is already set; `allowLocalBinding` is true on macOS; the settings file sits under an `allowWrite` path; or srt resolves from inside a workspace (`node_modules`).
- `doctor --probe-sandbox` per channel runs canaries inside the sandbox. Each must **fail**:
  - write `~/canary`;
  - `cat ~/.ssh/<canary>` (a planted file);
  - `curl https://example.com`;
  - `curl -x http://127.0.0.1:1082 https://example.com`;
  - `echo x >> .git/hooks/pre-commit`;
  - read the key store;
  - `printenv <KEY>` must print the sentinel, not the key.

  The provider call itself must succeed.
- Classify srt start failures separately (`sandbox-start`), and never treat srt's exit 0 as success after SIGTERM.

---

## 8. Per-harness feasibility

| Harness (key type) | Native sandbox | srt whole-process (macOS) | Proxy env honored | CA trust for mask | Key maskable | OS read-only reviewer | Default phases | SECURITY/DATA_LOSS |
|---|---|---|---|---|---|---|---|---|
| **Codex** (OpenAI login, or 3P provider via `auth.command`) | **yes** (tools-only, network off, domain proxy) | **no** (nested Seatbelt) | n/a | n/a | n/a (harness outside; deny-read the key file) | yes (`-s read-only`) | yes | **yes** (current Sol path); with third-party models the sandbox is unchanged [source:docs/research/universal-dispatchers/05-codex-multi-provider.md §7] |
| **`claude -p`** + 3P endpoint (PAYG token) | Bash only | yes, with the inner sandbox off (documented `srt claude`) | yes (`HTTPS_PROXY`) [docs] | `NODE_EXTRA_CA_CERTS` supported [docs] | yes (`ANTHROPIC_AUTH_TOKEN` env) | srt: yes. Native: via permission rules | yes | candidate (srt + mask, after canaries) |
| **OpenCode** run (PAYG env key, OpenCode Go/Zen key) | none | yes; no TCP listener [source] | yes [docs] | yes [docs] | yes (env) | srt: yes. Native: permission rules only | yes (srt) | candidate (srt + mask, after canaries) |
| **pi** -p (PAYG env key) | none | yes | yes (undici `EnvHttpProxyAgent`) [source] | `NODE_EXTRA_CA_CERTS` (Node) [unverified for pi specifically] | yes (env; leave `auth.json` empty) | srt: yes (`--tools read,grep,find,ls` is not OS-level) | yes (srt) | candidate (srt + mask, after canaries) |
| **ZCode CLI** (GLM Coding Plan key, file) | none (yolo) | yes, via `ZCODE_HTTP_PROXY="$HTTPS_PROXY"` [unverified: userinfo token] | own variable only [source] | `NODE_EXTRA_CA_CERTS` at Node startup [unverified: the CLI moves it from `process.env` after start] | **no on macOS** (file key, no env indirection); Linux: file mask with `extract` [fact-check 2026-10-20: also set `onExtractNoMatch: "deny"`. The default `"warn"` leaves the file readable as-is when the regex matches nothing (fail-open); sandbox-config.ts:224-227,291-316] | srt: yes | yes (srt write/egress confinement is a clear gain over today) | **no** (key readable in-sandbox on macOS; ToS question on mask) |
| **DSH** headless (DeepSeek env key) | writes only | only with its own sandbox off [inference] | [unverified] | [unverified] | yes (env) | native read-only mode exists | yes | after canaries |
| **Gemini CLI / Qwen Code** (PAYG keys) | whole-CLI Seatbelt/Docker; Qwen Linux tools-only | only with `-s` off | yes [unverified] | [unverified] | yes (env) | native profiles | yes | after canaries. Qwen Coding/Token plans are interactive-only per ToS [source:docs/research/universal-dispatchers/06-providers-and-plans.md §1.2] |
| **Local model** (no key) behind any of the above | — | yes, with `127.0.0.1:<port>` allowed and `NO_PROXY` cleared | client-dependent [unverified] | n/a (plain HTTP) | n/a | as harness | yes | yes if the harness qualifies (no key to leak; data stays local) |

---

## 9. Minimum bar for running a SECURITY/DATA_LOSS phase on a third-party harness

All of these must hold. Otherwise the phase stays on Codex Sol, as the dev-orchestrator SKILL requires today:

| # | Requirement | How it is met |
|---|---|---|
| M1 | OS-enforced write allowlist: the job worktree, the job session dir and the job tmp only, with protected paths denied (`.git/hooks`, `.git/config`, the worktree `.git` file, `.gitmodules`, shell rc, `.claude/`, `.mcp.json`, harness config) | srt `allowWrite` + mandatory denies + `denyWrite`; Codex `workspace-write` |
| M2 | OS-enforced read denial of every credential store and every other channel's profile; strict tier (`denyRead ~/` + allow-list) preferred | srt `denyRead`; Codex unreadable globs |
| M3 | Egress default-deny, `strictAllowlist`, only the provider API host(s); no registries (deps preinstalled); no `allowLocalBinding`; srt not chained to the local proxy | §6 rules |
| M4 | The provider key is **not readable inside the sandbox** | srt `mask` (env-keyed harnesses), or a harness-outside architecture (Codex) with tool-env scrub; plus the L3 post-job secret scan |
| M5 | Fail-closed start and no nesting | §7.4 |
| M6 | A canary probe passes for the **pinned** harness and srt versions; re-run on every version bump | `doctor --probe-sandbox` |
| M7 | Non-interactive, deterministic tool set; no MCP, no plugins or extensions, no web tools | harness flags (pi `-ne -ns -np --no-mcp`; OpenCode `OPENCODE_DISABLE_DEFAULT_PLUGINS`; Claude `--disallowedTools`) |
| M8 | Family rule: the reviewer of the phase is from a different model family, and runs read-only at the OS level | srt reviewer profile or Codex `read-only` |
| M9 | Provider terms allow automated use with this key type (PAYG preferred), and the provider's data terms are acceptable for the code under change | 06 report matrix |

---

## 10. To verify locally before adopting (smoke matrix; not run here)

1. Install `@anthropic-ai/sandbox-runtime@0.0.81` globally (outside every workspace). With a throwaway settings file, run `srt -- /usr/bin/true`, then confirm `printenv SANDBOX_RUNTIME` = 1, and that the `curl -x http://127.0.0.1:1082 …` canary fails.
2. Nesting on macOS 26.5 (the F2 result is from macOS 15.7.7): run `srt -- sandbox-exec -p '(version 1)(allow default)' /usr/bin/true`. [fact-check 2026-10-20, local-run without srt on macOS 26.5.2 (25F84): when the outer profile is `(deny default)` and allows only exec, fork and reads, like srt's, a nested `sandbox-exec` prints `sandbox_apply: Operation not permitted` and exits 71. The same happens with an `(allow default)` outer and a `(deny default)` inner. Only a trivial `(allow default)` inside `(allow default)` exited 0. F2 holds on 26.5; the srt run itself is still to do.]
3. Per harness (pi, OpenCode, `claude -p` + DeepSeek/Z.ai Anthropic endpoint, ZCode CLI), under srt with `tlsTerminate` + mask:
   - one PONG probe;
   - `printenv` shows the sentinel;
   - the provider accepts the swapped key;
   - streaming works through the terminated tunnel;
   - SSE idle gaps longer than 6 s do not break it.
4. The reflection test: ask the model to print its key variable, then check whether the real value appears in the transcript or a file. The dispatcher scan must catch it.
5. Local model: Ollama on 127.0.0.1:11434, allowlisted literal + cleared `NO_PROXY`, for pi (undici) and OpenCode (Bun).
6. Wall-clock overhead of srt per job: settings compile, proxy start, `rg` scan. [corrected 2026-10-20: the `rg` scan runs only on Linux. On macOS the mandatory denies are glob/regex rules in the Seatbelt profile, checked at write time (sandbox-manager.ts:1643-1645, macos-sandbox-utils.ts:998), so on this Mac measure profile generation, the `sandbox-exec` compile and proxy start.]
7. Keychain: inside srt, `security find-generic-password -s <item created by security add-generic-password> -w` should be denied.

## Open questions

- Does srt v0.0.81 scrub real credential values from **responses**? My grep found none; an upstream issue may be needed.
- Does a transparent sentinel→key header swap by a local proxy (srt mask) count as "proxying" under the Z.ai GLM Coding Plan terms? The same question applies to any other subscription plan. [corrected 2026-10-20: the Z.ai text is "resell, sub-resell, repackage, aggregate, proxy or otherwise provide the GLM Coding Plan to any third party" (subscription-terms.md §4). The open point is whether a single-user swap in front of a listed tool is "use outside such tools", not "proxying".]
- Can the ZCode CLI take its Coding Plan key from an env variable (for example the AI-SDK `ANTHROPIC_API_KEY` fallback when the personal rule has no `apiKey`) so that it becomes maskable on macOS?
- Does the ZCode CLI's HTTP client accept `http://user:token@localhost:port` in `ZCODE_HTTP_PROXY`?
- Does Bun (OpenCode) proxy plain-HTTP loopback requests when `NO_PROXY` is empty, or does it bypass localhost unconditionally?
- On Docker Desktop for Mac, can containers reach host-loopback-only services (the :1082 proxy) via `host.docker.internal`?
- Can a sandboxed shell on macOS read the environment of a same-sandbox, same-uid process (`ps eww`, `KERN_PROCARGS2`)?
- What does srt cost per job on this M4 / 16 GB machine, and does the macOS `rg` scan scale with large worktrees? [corrected 2026-10-20: srt v0.0.81 runs no `rg` scan on macOS (Linux only; sandbox-manager.ts:1643-1645). On macOS the question is how profile size and `sandbox-exec` compile time grow with the number of deny and allow entries.]

## Sources (versions and dates)

- anthropics/sandbox-runtime @ v0.0.81 (2026-10-20): `README.md`, `docs/srt-proxy.md`, `src/cli.ts`, `src/sandbox/{sandbox-config,sandbox-manager,sandbox-utils,macos-sandbox-utils,credential-sentinel,body-substitution,http-proxy,tls-terminate-proxy,mitm-ca}.ts`; npm metadata (`npm view`, 2026-10-20).
- openai/codex @ rust-v0.163.0 (2026-10-15): `codex-rs/linux-sandbox/README.md`, `codex-rs/network-proxy/README.md`, `codex-rs/network-proxy/src/credential_broker.rs`, `codex-rs/cli/src/{main.rs,lib.rs,debug_sandbox.rs}`, `codex-rs/sandboxing/src/{seatbelt.rs,seatbelt_tests.rs,seatbelt_network_policy.sbpl}`, `codex-rs/config/src/shell_environment_policy.rs`, `codex-rs/protocol/src/shell_environment.rs`.
- anomalyco/opencode @ v1.19.3 (2026-10-16): `packages/opencode/src/cli/cmd/run.ts`, `packages/opencode/src/auth/index.ts`, `packages/core/src/global.ts`, `packages/core/src/flag/flag.ts`, `packages/opencode/src/effect/runtime-flags.ts`, `packages/web/src/content/docs/{network,permissions}.mdx`.
- earendil-works/pi @ v1.3.0: `packages/coding-agent/src/utils/shell.ts`, `packages/coding-agent/src/core/http-dispatcher.ts`.
- google-gemini/gemini-cli @ v0.64.0 (2026-10-13): `docs/cli/sandbox.md`, `packages/cli/src/utils/sandbox.ts`, `packages/cli/src/utils/sandbox-macos-strict-proxied.sb`.
- QwenLM/qwen-code @ v0.25.3 (2026-10-19): `docs/users/features/sandbox.md`.
- apple/container @ 1.6.0 (2026-10-20): `README.md`, `docs/{command-reference,networking,technical-overview}.md`.
- anthropics/claude-code @ d945a61bc6 (2026-06-30): `.devcontainer/init-firewall.sh`.
- Claude Code docs (fetched 2026-10-20): https://code.claude.com/docs/en/sandboxing, …/sandbox-environments, …/agent-sdk/secure-deployment, …/permission-modes, …/env-vars.
- Docker docs (fetched 2026-10-20): https://docs.docker.com/ai/sandboxes/, …/security/, …/agents/.
- This repo (main): `docs/zcode-sandbox-evaluation.md` (local-run on 2026-10-14, macOS 15.7.7), `docs/zcode-cli-findings.md`, `bin/lib/zcode-dispatch.mjs`, `skills/zcode-invocation/SKILL.md`; sibling reports `00`, `02`, `03`, `04`, `05`, `06` in this directory.
- Local checks (2026-10-20): `sw_vers` → macOS 26.5.2 (25F84); `/usr/bin/sandbox-exec` present; `srt`, `container`, `podman`, `bwrap`, `opencode`, `pi`, `ollama` absent; Docker client 29.8.2; `rg` and Node present.

## Fact-check log (2026-10-20)

Sources were opened directly: `gh api` raw files at the cited tags, `gh api` releases and repo metadata, `npm view`, WebFetch of the cited docs pages, `codex --help` 0.163.0, `claude --help` 2.1.302, and three local `sandbox-exec` runs on macOS 26.5.2. No package was installed, and no model endpoint or credential store was touched.

| Claim | Verdict | Evidence |
|---|---|---|
| srt = `@anthropic-ai/sandbox-runtime` 0.0.81, npm `latest`, published 2026-10-20 | confirmed | npm time 0.0.81 = 2026-10-20T01:13Z; GitHub release v0.0.81 2026-10-20T01:01Z |
| Apache-2.0; Node ≥22.12; deps zod, commander, node-forge, @pondwader/socks5-server; bin `srt` → `dist/cli.js` | confirmed | `npm view`; `gh api repos/anthropics/sandbox-runtime` (license Apache-2.0) |
| `anthropic-experimental/sandbox-runtime` redirects to `anthropics/` | confirmed | `gh api repos/anthropic-experimental/sandbox-runtime` → `anthropics/sandbox-runtime` |
| 8 releases, 0.0.74 → 0.0.81, 2026-08-25 → 2026-10-20 | confirmed | GitHub releases v0.0.74 (2026-08-25) … v0.0.81; npm has 0.0.74 on 08-26 |
| README "Beta Research Preview … APIs and configuration formats may evolve" | confirmed (verbatim) | README.md:7-9 @v0.0.81 |
| Settings file fails closed (empty, unreadable or invalid file, or missing `--settings` path); no file means defaults | confirmed | README.md:177-185; code.claude.com/docs/en/sandbox-environments |
| macOS needs `rg` | corrected | README lists it, but code runs `rg` only on Linux (sandbox-manager.ts:1643-1645; only linux-sandbox-utils imports ripGrep); Claude docs: no extra packages on macOS |
| CLI syntax `srt [--settings] [-d] [--control-fd] -- cmd` / `-c`; argv shell-quoted; `spawn(…,{shell:true})` | confirmed | src/cli.ts:331-349,555-611 |
| CLI installs no ask callback, so unmatched hosts are denied ("host is not on the allow list") | confirmed | cli.ts:505 `initialize(runtimeConfig)`; sandbox-manager.ts:786-809 |
| Decision order: deny list, then allow list, then strictAllowlist | confirmed | sandbox-manager.ts:767-792 |
| `mask` puts a `fake_value_<uuid4>` sentinel in the child, padded to the real length; real value read from srt's env | confirmed | credential-sentinel.ts:1-38; credential-mask-env.ts:1-15 |
| Substitution gated per credential by its `injectHosts` (no laundering) | confirmed | credential-sentinel.ts:52-58 |
| Masking requires `tlsTerminate` unless `allowPlaintextInject` | confirmed | sandbox-config.ts:1524-1538; README.md:601 |
| `tlsTerminate` is `[EXPERIMENTAL]` | confirmed | sandbox-config.ts:940; README "(`network.tlsTerminate`, experimental)" |
| File masks are Linux-only and degrade to deny on macOS (and Windows) | confirmed | sandbox-config.ts:152-160,272-275; README.md:601 |
| Request bodies are substituted as well as headers; a Content-Encoding body passes unchanged | confirmed | body-substitution.ts:1-15,58-80 |
| No response-side scrubbing of real values | confirmed (absence, by grep) | grep of all 49 `src/**/*.ts` @v0.0.81 for response scrub or real→sentinel: no hits |
| Quote "only in process memory — never written to disk…" | corrected (verbatim) | credential-sentinel.ts:7-8 has "— it is never written…" |
| `allowLocalBinding` (macOS) lets the sandbox connect to any localhost port; Linux ignores it | confirmed | sandbox-config.ts:726-743; macos-sandbox-utils.ts:1280-1283 `(remote ip "localhost:*")` |
| allowLocalBinding quote | corrected (truncated) | sandbox-config.ts:739-741 ends "…forwarder that would carry traffic off the machine." |
| Without allowLocalBinding, macOS loopback is limited to the proxy ports | confirmed | macos-sandbox-utils.ts:1317-1341 |
| `NO_PROXY=localhost,127.0.0.1,::1,169.254/16,10/8,172.16/12,192.168/16` | confirmed | sandbox-utils.ts:822-838 |
| Random 16-byte proxy auth token in the proxy URLs' userinfo when srt owns the proxy | confirmed | sandbox-manager.ts:1524-1530 `randomBytes(16)`; sandbox-utils.ts:787-790,840-843 |
| Child env: `SANDBOX_RUNTIME=1`, `TMPDIR` from `CLAUDE_CODE_TMPDIR`, CA trust vars, proxy vars | confirmed | sandbox-utils.ts:752-850 |
| `parentProxy` falls back to `HTTP(S)_PROXY`/`NO_PROXY`; the resolved-address check is skipped through it | confirmed | sandbox-config.ts:707-713,946-950; README.md:468 |
| Allowlisted IP literals skip the resolved-address check; built-in denied set covers loopback, link-local, metadata IPs and the host's own interface addresses | confirmed | README.md:464-468 |
| Mandatory write denies (rc files, .gitconfig, .gitmodules, .ripgreprc, .mcp.json, .vscode, .idea, .claude/commands, .claude/agents, .git/hooks, .git/config) | confirmed | README.md:1142-1160; sandbox-config.ts:961-965; Claude sandbox-environments doc |
| `.git/config` deny lifted by `allowGitConfig`; Linux scan depth `mandatoryDenySearchDepth` default 3 | confirmed | sandbox-config.ts:985-990,1224-1234 (Linux-only key, so it has no effect in the macOS template) |
| Always-writable: stdio, `/tmp/claude`, `~/.npm/_logs`, `~/.claude/debug` | confirmed | README.md:539 |
| Seatbelt base: `(deny default)`, process-info/signal same-sandbox only, SecurityServer + securityd.xpc lookups | confirmed | macos-sandbox-utils.ts:1083-1112,1236 |
| Seatbelt cannot nest (`sandbox_apply: Operation not permitted`, exit 71) | confirmed | local-run macOS 26.5.2: a deny-default outer gives inner exit 71; Codex seatbelt_tests.rs:166-169 @rust-v0.163.0 "nested Seatbelt is unavailable" |
| Seatbelt network rules accept only `*` or `localhost` hosts | confirmed | local-run: `(remote ip "198.18.0.1:443")` → "host must be * or localhost in network address" |
| srt exits 0 when the child dies by SIGINT/SIGTERM, and 1 on other signals, a dead control channel or its own errors | confirmed | cli.ts:614-640 |
| srt does not set `NODE_USE_ENV_PROXY` on macOS/Linux | confirmed | README.md:1066; only windows-sandbox-utils sets it |
| A copy installed in a writable project can be rewritten from inside | confirmed | README.md:1277 |
| `GIT_SSH_COMMAND` routes git over SSH through the proxy | confirmed | README.md:1064 |
| Linux: no network namespace, socat bridges, seccomp blocks AF_UNIX and io_uring, nested PID namespace, user namespaces refused | confirmed | README.md:713-718,1212-1214 |
| Claude Code's sandbox is built on srt | confirmed | code.claude.com/docs/en/sandboxing: "Claude Code builds the sandbox on the open source `@anthropic-ai/sandbox-runtime` package" |
| Built-in sandbox covers Bash, PowerShell and Monitor; Read/Edit/Write/WebFetch, hooks, MCP, status line and apiKeyHelper run outside | confirmed | sandboxing doc "What runs outside the sandbox" |
| `sandbox.credentials` applies to sandboxed Bash only; `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` covers all subprocesses | confirmed | sandboxing doc; env-vars doc row |
| mask/tlsTerminate/allowPlaintextInject honored only from user, managed or `--settings` scope | confirmed | sandboxing doc "A trusted settings scope" |
| failIfUnavailable / allowUnsandboxedCommands / bypassPermissions retry / strictAllowlist semantics | confirmed | sandboxing doc (strict sandbox mode; hosts outside allowed domains) |
| "inside a container, a VM, or the sandbox runtime"; `srt claude` needs project, ~/.claude, ~/.claude.json, /private/tmp, api.anthropic.com unless `skipWebFetchPreflight` | confirmed | sandbox-environments doc; settings-reference (top-level key) |
| Deny rules hold in bypassPermissions; acceptEdits fs-command set; `-p` denies unapproved calls | confirmed | permission-modes doc |
| Claude Code installed 2.1.302, latest v2.1.304 | confirmed | `claude --version`; GitHub release v2.1.304 2026-10-19 |
| Codex rust-v0.163.0 (2026-10-15) default `ignore_default_excludes=true`, so `*KEY*/*SECRET*/*TOKEN*` are inherited | confirmed | config/src/shell_environment_policy.rs:135-136; protocol/src/shell_environment.rs:138-146 |
| Codex Linux: bwrap + seccomp; legacy Landlock rejected for filesystem-restricted policies; deny-read globs `"**/*.env" = "none"` | confirmed | linux-sandbox/README.md:47-49,79-86 |
| Codex `codex sandbox [-P profile] -- cmd`; `exec -s read-only|workspace-write`; network proxy with per-profile domains and MITM hooks | confirmed | `codex sandbox --help`, `codex exec --help` 0.163.0; network-proxy/README.md:25-81 |
| Codex Seatbelt process-info limited to same sandbox | confirmed | sandboxing/src/seatbelt_base_policy.sbpl:15-16 |
| pi v1.3.0: bash env is `{...process.env}`; no built-in sandbox; srt 0.0.26 example extension; undici `EnvHttpProxyAgent`; flags `-ne -ns -np --no-mcp --no-approve`; `PI_OFFLINE`, `PI_TELEMETRY` | confirmed | utils/shell.ts:138-150; docs/security.md:3,99; examples/extensions/sandbox/package.json; core/http-dispatcher.ts:80-87; cli/args.ts; docs/environment-variables.md |
| OpenCode v1.19.3 (2026-10-16): no OS sandbox; `run` uses in-process fetch shim (no listener); auth.json 0600 under XDG data; env flags | confirmed | cli/cmd/run.ts:899-951; auth/index.ts:10,79,88; core/global.ts; core/flag/flag.ts:23,29,46; effect/runtime-flags.ts:19-29; no sandbox code in tree |
| Gemini CLI v0.64.0 (2026-10-13): `-s` re-execs whole CLI under sandbox-exec; six profiles; proxied → localhost:8877; `GEMINI_SANDBOX_PROXY_COMMAND`; tool sandboxing | confirmed | docs/cli/sandbox.md:75-101,267-290; utils/sandbox.ts:298-338; sandbox-macos-strict-proxied.sb:129-132 |
| Qwen Code v0.25.3 (2026-10-19) quotes "model transport, authentication and session storage remain on the host" / "Reads remain broad: this mode does not hide host secrets" | confirmed (verbatim) | docs/users/features/sandbox.md:23; proxy :8877 at :212-215 |
| DSH: Seatbelt/bwrap+Landlock/ACL, fail-closed, "network and process visibility are outside this vocabulary" | confirmed | deepseek-harness@dsh-v0.2.1-rc.2 docs/subsystems/sandbox.md:11,154-172; sandbox-local/README.md:71-79 |
| "only Codex (and Qwen Linux) has the harness-outside/tools-inside shape" | corrected | Claude Bash sandbox and Gemini "Tool sandboxing" are also tools-only (sandboxing doc; gemini sandbox.md:267-271) |
| ZCode: key plain text in personal config, no env indirection; client uses only `ZCODE_HTTP_PROXY` | confirmed (repo doc) | docs/zcode-cli-findings.md:9,243,301-303 |
| ZCode `DISALLOWED_TOOLS` gives partial L2 | corrected | bin/lib/zcode-dispatch.mjs:55 `DISALLOWED_TOOLS = []` |
| Apple container 1.6.0 (2026-10-20): one VM per container, macOS 26 + Apple silicon, `network create --internal`, partial ballooning | confirmed | apple/container@1.6.0 README.md:6,18-20; docs/command-reference.md:825-834; docs/technical-overview.md:26-30,55-59 |
| Docker Sandboxes: microVM, deny-by-default egress, "The raw credential values never enter the VM", UDP/ICMP blocked, OpenCode + Shell agents | confirmed | docs.docker.com/ai/sandboxes/security/ and /agents/ |
| pi `pi-kit` and `sbx exec <name> -- pi -p` | confirmed | pi docs/containerization.md:110-116 |
| Devcontainer firewall allows OUTPUT to the host /24 | confirmed | anthropics/claude-code@d945a61bc6 .devcontainer/init-firewall.sh:99-104 |
| Secure-deployment: srt overhead "Very low"; gVisor "Up to 10-200× slower…"; hardened docker flags | confirmed | code.claude.com/docs/en/agent-sdk/secure-deployment |
| Z.ai terms ban "resale or proxying" | corrected | subscription-terms.md:40 "resell, sub-resell, repackage, aggregate, proxy or otherwise provide the GLM Coding Plan to any third party" |
| Z.ai bans "directly invoking model APIs from your own applications" | confirmed (verbatim) | subscription-terms.md:39 |
| Kimi / Alibaba coding plans are interactive-only | confirmed | kimi.com community-guidelines "for interactive use only"; alibabacloud coding-plan "Do not use the plan's API key for automated scripts, application backends, or other non-interactive scenarios" |
| macOS 26.5.2 (25F84) | confirmed | local `sw_vers` |
| Keychain readable inside srt; `ps eww` across same sandbox; host.docker.internal → :1082; Bun/undici loopback proxying; ZCode userinfo proxy | unverifiable (left [unverified]) | needs a local srt run, which was out of scope |

**Reliability assessment.** The report is highly reliable on the facts that drive its design. Every srt version, license, maturity label and config semantic I checked matches v0.0.81 source and README. That covers mask mode, the tlsTerminate requirement, Linux-only file masks, body substitution with no response scrubbing, allowLocalBinding, NO_PROXY, the proxy token, the mandatory denies and exit 0 on SIGTERM. Seatbelt nesting failure reproduces on this machine's macOS 26.5.2 with exit 71. The Claude Code, Codex, pi, OpenCode, Gemini, Qwen, DSH, Apple container and Docker Sandboxes claims also hold at the cited tags and pages.

The errors are of three kinds:
- **A not-quite-verbatim ToS quote.** The Z.ai clause is "proxy … to any third party", not "proxying". This narrows the mask-mode ToS concern but does not resolve it.
- **One overstated "only".** Codex is not the only harness with the harness-outside/tools-inside shape.
- **A stale README dependency.** srt does not use `rg` on macOS.

There were also two clipped quotes. None of the errors changes the recommended L0-L3 design, the M1-M9 bar or the per-harness verdicts. The remaining [unverified] items are honestly flagged and need the §10 local smoke run.
