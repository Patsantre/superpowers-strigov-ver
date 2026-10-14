---
name: zcode-invocation
description: How to invoke GLM-5.3-Flash through Z.ai's ZCode CLI via the zcode-dispatch wrapper — background tasks + Monitor polling. Read this before the first GLM call in a session, including from dev-orchestrator.
---

# ZCode invocation (zcode-dispatch wrapper, background-only)

## What this is

ZCode is Z.ai's official coding-agent harness (`github.com/zai-org/ZCode`, Apache-2.0). `/Applications/ZCode.app` embeds its Agent CLI at `Contents/Resources/glm/zcode.cjs`; there is no `zcode` on `PATH`. This plugin drives that CLI headless through the `bin/zcode-dispatch` wrapper to run **GLM-5.3-Flash at reasoning effort `max`** — the dev-orchestrator default implementer for non-frontend phases — on the user's individual GLM Coding Plan. Codex Luna max is the fallback when this channel is down; Codex Sol 6.1 xhigh takes SECURITY / DATA_LOSS phases and reasoning escalations.

The plan's terms (docs.z.ai/devpack/usage-policy): the Coding Plan may be used only in officially supported tools; SDK-based access and unsupported tools lead to benefit restrictions; account sharing is prohibited; more than 3 violations → ban. Nothing official exists about headless or automated use of a supported tool, either way. Concurrency guidance: Lite = 1 project at a time, Pro = 1–2, Max = 2+.

> **Read before the first GLM dispatch.** GLM runs **unsandboxed**, as your user account, in ZCode's `yolo` mode — see "Sandbox warning". The plugin stays inside the official ZCode CLI with truthful client identification and never touches credentials or the API — see "Compliance". If either is not acceptable for a repository, set `SP_IMPLEMENTER=luna`.

## Verified facts (from `docs/zcode-cli-findings.md`)

- Model selection: wrapper
- Model confirmation: not required
- GLM resume: enabled
- GLM concurrency: 2
- Quota bonus (1.5× in ZCode): inconclusive — measured 2026-10-14 on ZCode 3.15.1; raw numbers in docs/zcode-cli-findings.md "Live acceptance".

dev-orchestrator reads these lines: `Model selection: wrapper` → the wrapper pins GLM-5.3-Flash at `max` in its own personal provider config before every run, and the user's only setup step is authenticating the CLI once — a Coding Plan API key (recommended for unattended runs) or the CLI's OAuth login ("One-time setup"); `Model confirmation: required` → one user confirmation per session, before the first GLM dispatch, that ZCode runs GLM-5.3-Flash with reasoning `max`; `GLM resume: disabled` → every GLM follow-up is a FRESH dispatch (dev-orchestrator Step 3); `GLM concurrency: 1` → at most one GLM track per parallel group.

## Working path

### 1. Resolve the wrapper once per session

```bash
ZDISPATCH="$(command -v zcode-dispatch || true)"
[ -z "$ZDISPATCH" ] && ZDISPATCH="$(ls -1d ~/.claude/plugins/cache/strigov-cc-plugins/superpowers-strigov-ver/*/bin/zcode-dispatch 2>/dev/null | sort -rV | head -1)"
[ -z "$ZDISPATCH" ] && ZDISPATCH="$(pwd)/bin/zcode-dispatch"
echo "ZDISPATCH=$ZDISPATCH"
```

Same idiom as `$DISPATCH` in `codex-invocation`: `command -v` when the marketplace install put `bin/` on `PATH`, the cache glob for a fresh session, `$(pwd)/bin/...` for local dev runs from the repo root.

### 2. One-time setup (user actions only — never run by the orchestrator)

1. Install ZCode.app into `/Applications`.
2. Authenticate the **CLI** — one of two ways, both run by the user:

   **a. Coding Plan API key (recommended; does not expire).** The user creates a key on Z.ai's key page `https://z.ai/manage-apikey/apikey-list`, copies it, and pipes it into the wrapper from their own shell — never as an argument, never pasted into the chat (with `$ZDISPATCH` replaced by the absolute path step 1 printed):

   ```
   ! pbpaste | "$ZDISPATCH" api-key set
   ```

   Copy the key last, right before running the line: copying the command itself replaces the key in the clipboard, and `api-key set` then refuses the command text (its error describes the input's shape, never its content). Run in a terminal without a pipe, `api-key set` prompts for the key with echo off — the simpler way when the user types in a terminal. Expected: `api-key: stored in <personal config> (mode 0600) as provider zai-api from ZCode's template zai-api; pinned to GLM-5.3-Flash$max; …`, exit 0. The key becomes a provider of ZCode's own built-in template "Z.ai Coding Plan" (`zai-api`: `https://api.z.ai/api/anthropic`, GLM-5.3 / GLM-5.3-Flash) in the wrapper's personal provider config; the CLI sends it itself, with no token exchange, so it stays valid until the user revokes it (`docs/zcode-cli-findings.md`, "CLI login lifetime"). `"$ZDISPATCH" api-key clear` removes it and returns to the OAuth login. The wrapper refuses (exit 2, nothing stored) a key given as an argument, an empty or multi-word stdin, and an app whose built-in config lacks the `zai-api` template.

   **b. OAuth login (expires about an hour after it is made).** Log the CLI in with Z.ai's own browser login (GLM Coding Plan account) through the wrapper: `zcode-dispatch login` runs the CLI's own `zcode login zai` with the same allowlisted environment as headless runs. The embedded CLI ships without its TUI, so there is no `/model` step. The user runs the line below, with `$ZDISPATCH` replaced by the absolute path step 1 printed (shell variables do not reach a `!` command — give the user the filled line); the `!` prefix makes it a user-shell command. It prints a URL and opens the browser; if the `!` prompt cannot host it, run the same line without `!` in a separate terminal window. `PATH` and `HOME` are passed so Node and browser login can run. The CLI ignores `HTTPS_PROXY` and the system proxy (`docs/zcode-cli-findings.md` header): if it needs a proxy on this machine, prefix the line with `ZCODE_HTTP_PROXY=<proxy url>`:

   ```
   ! "$ZDISPATCH" login
   ```

   Behind a local proxy, the CLI ignores `HTTP(S)_PROXY` and the macOS system proxy. Prefix the login command with `ZCODE_HTTP_PROXY=http://<host>:<port>`, and also export it for headless runs if those fail with a network error; the wrapper passes it via the allowlist.

   Expected: the CLI's own login output, then `login: ok — ZCode CLI login stored in <cli-home>; <personal config> re-pinned to GLM-5.3-Flash$max`, exit 0; on failure the exit code is the CLI's. The login stores the CLI's identity in the wrapper's own CLI home `~/.claude/plugins/data/superpowers-strigov-ver-zcode/cli-home` (passed to every CLI run as `ZCODE_DATA_BASE_DIR`), never in `~/.zcode`: the desktop app and the CLI write the same credential key with different token kinds and would log each other out (`docs/zcode-cli-findings.md`, "CLI data home"). The wrapper never reads that credential. The login also rewrites the default model in the wrapper's personal provider config; the wrapper re-pins GLM-5.3-Flash at `max` right after it and before every run. A plain `zcode login zai` made before this wrapper version went into `~/.zcode` and does not count — run this one once per machine.
3. Authentication missing, expired or rejected: the OAuth login keeps no refresh token and the CLI re-exchanges it before every request, so it stops working about an hour after the login (measured 2026-10-14: accepted at 59 min, rejected at 74 min; 2b); an API key fails only when revoked or mistyped (2a). `doctor --probe` then prints `model-selected: FAIL(model-not-selected)` or `FAIL(auth)` and a stderr `hint:` line for the active mode — `run: zcode-dispatch login` (OAuth, which also suggests `api-key set`) or `store a valid one: zcode-dispatch api-key set` (API key) — and a task fails with the same `errorClass`. Then `glm=down` and Luna max for the rest of the session (dev-orchestrator channel ladder, unchanged). Give the user the probe's remedy (2a for unattended runs); never run it yourself.

Login, API key and plugins belong to the user: the orchestrator asks, never does — and never asks for the key in the chat.

### 3. `doctor`, then `doctor --probe` — once per session

```bash
"$ZDISPATCH" doctor            # offline: app, cli, provider-config, node, app-version, git, state-dir, cli-home, personal-config, auth, kill-switch, env
"$ZDISPATCH" doctor --probe    # offline checks + ONE synchronous PONG request (spends a little quota)
```

`doctor` prints `ok | WARN | FAIL <check>: <detail>` per check, then `doctor: ok` or `doctor: FAIL` (exit 1 on any FAIL). Its `env` check reports how many caller variables pass the allowlist, returns `FAIL` for an invalid `ZCODE_ENV_PASSTHROUGH` name, and warns when `HTTP(S)_PROXY` / `ALL_PROXY` is set without `ZCODE_HTTP_PROXY` (the CLI uses only `ZCODE_HTTP_PROXY` for its own requests). Its `auth` check names the mode: `ok auth: Coding Plan API key …` (API key, no expiry), `WARN auth: OAuth login …` (works for about an hour after the login; GLM then falls back to Luna — suggest 2a to the user once), or `FAIL auth` when a key is configured but the app's built-in config lacks the `zai-api` template (the ZCode update changed it; `api-key clear` returns to OAuth). `WARN app-version` means ZCode.app updated past the verified version — the CLI may have moved or changed flags; tell the user to re-run the live acceptance (`docs/zcode-cli-findings.md`). `doctor --probe` adds:

```
model-selected: ok | FAIL(<errorClass>)
answers: ok | FAIL
reported-model: <model string from the JSON> | unreported
usage: input=<n|-> cached=<n|-> output=<n|->
probe: ok | FAIL
```

Exit 0 iff the model answered, the answer contains `PONG`, and `reported-model` is `unreported` or the pinned GLM-5.3-Flash. `model-selected: FAIL(model-not-selected)` or `FAIL(auth)` means the CLI's authentication is missing, expired or rejected; the probe then also prints the mode's stderr `hint:` line ("One-time setup", step 3). Any FAIL of either command means **Luna for the rest of the session** (dev-orchestrator sets `glm=down` and writes its session marker). After compaction the dev-orchestrator session marker (`<scratchpad>/dev-orchestrator/glm-channel`), not a new probe, restores the state.

### 4. Submit a task (ALWAYS `--background`, ALWAYS `--prompt-file`)

```bash
"$ZDISPATCH" task --background [--cwd <worktree-path>] [--resume-task zt-NNNN | --fresh] --prompt-file "$dir"/prompts/<op>-<phase>-r<N>.<seq>.glm.md
```

Expected output: `ZCode Task started in the background as zt-NNNN`. The dispatch file begins with the ZCode preamble (`dev-orchestrator/implementer-prompt.md`), so it never starts with `-` or `/` (the CLI would read those as an option or a slash command). There are no `--model` / `--effort` flags — the wrapper pins GLM-5.3-Flash at `max`.

### 5. Poll with terminal-only filter (via Monitor)

```bash
ZTASK=zt-XXXX
until
  st=$("$ZDISPATCH" status "$ZTASK" --json 2>/dev/null \
       | python3 -c "import json,sys; print(json.load(sys.stdin)['job']['status'])")
  case "$st" in
    completed|failed|cancelled) echo "zcode task terminal: $st"; true ;;
    *) false ;;
  esac
do
  sleep 25
done
```

Run this via the Monitor tool (add `--cwd <worktree-path>` to the `status` call for a worktree job). **The `case` guard is non-negotiable** — a monitor that prints every poll floods the chat and auto-stops.

### 6. Fetch the result

```bash
"$ZDISPATCH" result zt-XXXX
```

`completed` → the implementer's final message on stdout; machine-read line 1 for the status token. Any other status → exit 1 with `job zt-XXXX is <status> errorClass=<class>` and the log tail on stderr — see "Terminal status handling".

## Flag reference

Exit codes everywhere: **0** success · **1** runtime failure (failed job on `result`, failed checks on `doctor`, internal error) · **2** usage error or guard refusal. The one exception is `login`, which returns the CLI's own exit code (its argument refusals still exit 2).

| Verb | Behaviour |
|---|---|
| `task --background [--cwd <path>] [--resume-task zt-NNNN \| --fresh] --prompt-file <f>` | Starts a background job; prints `ZCode Task started in the background as zt-NNNN`. `--background` is mandatory (there is no foreground mode). `--resume-task` and `--fresh` are mutually exclusive; neither means `--fresh`. |
| `status [zt-NNNN] [--cwd <path>] [--all] [--json]` | With an id: `{"job":{…}}`. Without: `{"workspaceRoot":…,"running":[…],"recent":[…]}` — the 10 newest terminal jobs; `--all` lists every job. Text mode: one line per job. Runs the liveness check first. |
| `result zt-NNNN [--cwd <path>]` | `completed` → the stored response verbatim, exit 0; otherwise exit 1 with status, errorClass and the last 20 log lines on stderr. |
| `cancel zt-NNNN [--cwd <path>]` | Claims the sticky `cancelled` status, SIGTERM to the CLI's process group, 5 s grace, then SIGKILL to that group; does not signal the runner, which exits after the CLI exits and releases the workspace reservation; prints `cancelled zt-NNNN`. Already terminal → prints its status, exit 0. |
| `release-stale [--cwd <path>]` | Frees a stale workspace reservation (holder runner gone) — the only way one is freed; `task` never reclaims automatically. Refuses (exit 2, one-line reason on stderr) if the reservation is already released, the holder runner is alive, the job's CLI process group is alive, or the reservation changed while it checked; otherwise finalizes a non-terminal job as `failed` / `crash`, records the release and prints `released <workspace> generation <n>`, exit 0 (exit 1 on an I/O or internal error). Never signals, never deletes files. Single actor: run it once, never in parallel with any other dispatch for that workspace. |
| `doctor [--cwd <path>]` | Offline checks, no model call. |
| `doctor --probe [--cwd <path>]` | Offline checks, then ONE synchronous PONG request (120 s timeout). The only diagnostic that spends quota. |
| `login [zai]` | The user's CLI login — never run by the orchestrator. Runs the CLI's own `zcode login zai` in the foreground with the same allowlisted environment (credential in `cli-home`, never in `~/.zcode`), stdio inherited so the browser URL shows; after exit 0 re-pins the personal provider config and prints `login: ok — …`. Exit code = the CLI's (the one verb outside 0/1/2); exit 2 for an argument other than `zai`, an unreadable `Info.plist`, or a missing `zcode.cjs` / provider config. Never reads or prints a credential. |
| `api-key set` / `api-key clear` | The user's Coding Plan API key — never run by the orchestrator. `set` reads one key from stdin (a pipe, or a hidden prompt on a terminal, where only Enter accepts and Ctrl-C / Ctrl-D cancel), refuses an argument, an empty or multi-word stdin and an app without the `zai-api` template (exit 2, nothing stored, arguments never echoed), then stores it as the `zai-api` template rule in the personal provider config (mode 0600) and pins GLM-5.3-Flash `max` via `zai-api`. `clear` removes the rule and pins the OAuth account provider again. Neither runs the CLI or prints the key; a later `login` keeps the key, which stays in use until `clear`. An unreadable or unparseable personal config is reported (exit 1; `doctor`: `FAIL personal-config`), never reset; edits of that file take a short wrapper lock. |

Refusals (exit 2, nothing spawned): `--cwd` not inside a git work tree; missing or empty prompt file, or one larger than `MAX_PROMPT_BYTES` on the argv transport; `Info.plist` unreadable; `zcode.cjs` or the provider config missing; another job `running` in the same workspace, or a cancelled job whose CLI has not exited yet (the workspace stays reserved until it does); a stale workspace reservation whose holder runner is gone (the message contains `release-stale`; nothing is changed — see "Terminal status handling"); `SP_IMPLEMENTER=luna`; an invalid `ZCODE_ENV_PASSTHROUGH` name; a configured Coding Plan API key whose `zai-api` template the ZCode provider config lacks (treat as a `doctor` FAIL); a bad `--resume-task` (see "Resume semantics"); unknown verbs or flags; an unknown id on `status` / `result` / `cancel`.

Pins (not configurable): `--output-format json`, `--mode yolo`, `--surface terminal`, `--workflow-mode disabled`, `--cwd <workspace root>`; never `--target`, `--json` or `-c/--continue`; `--disallowedTools` only for the tools `docs/zcode-cli-findings.md` (U6) confirmed, never as a substitute for the preamble. Environment = the allowlisted caller variables in `ENV_ALLOW` (process basics including `HOME`, proxy/CA variables, selected ZCODE settings and toolchain locations), `LC_*` / `XDG_*` variables whose names do not match `ENV_DENY`, and any extra names explicitly listed in `ZCODE_ENV_PASSTHROUGH` (comma- or space-separated). Unlisted variables are dropped; secret-like variables are also dropped unless explicitly passed, with `ZCODE_CREDENTIAL_SECRET` kept in `ENV_ALLOW` for the CLI's credential key. The wrapper then sets `ZCODE_BUILTIN_PROVIDER_CONFIG_FILE` and `ZCODE_BUILTIN_PROVIDER_BUNDLED_CONFIG_FILE` (both the app's `zcode-builtin.json`), `ZCODE_APP_VERSION` from `Info.plist`, and `ZCODE_PERSONAL_PROVIDER_CONFIG_FILE` = its own `personal-provider-config.json` under the state root, where the model pin is written before every run. It also always sets `ZCODE_DATA_BASE_DIR` = its own `cli-home` under the state root (the CLI's credential store, `<cli-home>/.zcode/v2/credentials.json`) and, under it, `ZCODE_STORAGE_DIR` = `<cli-home>/.zcode` (plugins, rollouts, memories), `ZCODE_SESSION_DB_PATH` = `<cli-home>/.zcode/cli/db/db.sqlite` (sessions) and `ZCODE_LOG_DIR` = `<cli-home>/.zcode/cli/log` (logs); these wrapper-owned values override inherited or passed values, and `ZCODE_SESSION_DB` is always dropped because the CLI alias can override the session path. The CLI's user config `~/.zcode/cli/config.json` has no override: the CLI still reads it (and may migrate it in place once), as it does for the desktop app's embedded agent; the wrapper never edits it. `task`, `doctor --probe` and `login` all run the CLI with this environment.

Env overrides (tests and relocated installs only): `ZCODE_APP` (default `/Applications/ZCode.app`), `ZCODE_BIN` (default `$ZCODE_APP/Contents/Resources/glm/zcode.cjs`), `ZCODE_NODE` (default `node`), `ZCODE_STATE_DIR` (default `~/.claude/plugins/data/superpowers-strigov-ver-zcode`), `ZCODE_TASK_TIMEOUT_MIN` (default 60). User opt-in: `ZCODE_ENV_PASSTHROUGH` (explicit additional CLI environment names; see above). Nothing else — no override for the model, the mode, the surface or the app version.

## Resume semantics

`--resume-task zt-NNNN` resolves that job's stored `sessionId` and passes `--resume <sess_…>` to the CLI — the fixer continues its own GLM session.

- The referenced job must be `completed` and carry a `sessionId`. A `running` reference is refused (`job zt-NNNN is still running; wait for it to finish`); a `failed` or `cancelled` one, or a completed one without a session, is refused (`job zt-NNNN is <status> / has no session; dispatch --fresh`).
- Any id of the same chain works: every resumed record stores the same `sessionId`.
- Ids are per workspace: pass the same `--cwd` as the original task.
- `zt-` ids and Codex `task-` ids never cross dispatchers; each wrapper rejects the other's prefix.
- When the wrapper refuses a resume, dispatch the same operation `--fresh` at the next seq, composed per dev-orchestrator Step 3 ("Prompt files and the retry / channel-switch rule") for its operation type — the fresh-fallback re-brief only on fix-type operations, never on `implement`.
- `GLM resume: disabled` under "Verified facts" → do not use `--resume-task` at all: every GLM follow-up is a FRESH dispatch of the same operation (the mapping stays in the wrapper, unused).

## Parallel tasks and worktrees

- One write task per working tree, across **both** dispatchers: the wrapper refuses a second running ZCode job in the same workspace; check `"$DISPATCH" status` as well before dispatching.
- Dispatch into a worktree with `--cwd <worktree-path>`; the workspace is `git rev-parse --show-toplevel` of that path, so each worktree has its own job list and id counter. `status` / `result` / `cancel` for that job must pass the same `--cwd`.
- **Width cap: max 2 concurrent write tasks, counted across both dispatchers.**
- GLM concurrency: see "Verified facts" — `1` means at most one GLM track per parallel group (only when the ladder resolved **both** tracks to GLM does the second one take Luna max for the group; Claude and Sol tracks are never changed by this rule).

## Terminal status handling

| Terminal state | Action |
|---|---|
| `completed` | `result`; parse line 1; malformed token → re-dispatch once with `--resume-task <zt-id>`, then the user |
| `failed` / `quota`, `auth`, `model-not-selected` | `glm=down` for the session (state line + marker); announce; the **same operation** on Luna max FRESH — next-seq `.luna` dispatch file in the FRESH composition for its operation type, unchanged body. On `auth` / `model-not-selected`, also tell the user the CLI's authentication is likely missing, expired or rejected and give them the remedy themselves to run ("One-time setup", step 2: `api-key set` for unattended runs, or `login`; with a key already set — `doctor` says `ok auth: Coding Plan API key` — a new key via `api-key set`) |
| `failed` / `timeout`, `crash`, `launch`, `malformed` | one retry of the **same operation** on GLM: `--fresh`, next-seq `.glm` dispatch file in the FRESH composition, unchanged body; second failure → Luna as above (`glm=down` only if the second class is quota/auth/model-not-selected) |
| `cancelled` | report to the user, wait |
| `doctor --probe` FAIL (before any task) | `glm=down` (state line + marker); announce once; Luna for the session. On `FAIL(auth)` / `FAIL(model-not-selected)` the announcement also gives the user the probe's `hint:` remedy to run themselves ("One-time setup", step 2) |
| wrapper exit 1 on `task` with no start line and stderr `zcode-dispatch: failed to start the runner for <zt-id>` or `zcode-dispatch: workspace reservation was lost before the runner started for <zt-id>` | The wrapper finalizes the job as `failed/launch`; apply the `launch` rule above: one FRESH retry with `--fresh`, then announced Luna if it fails again |
| wrapper exit 2 on `task`: stderr `zcode-dispatch: prompt file is <bytes> bytes, above MAX_PROMPT_BYTES=204800 for the argv transport` | Deterministic guard; dispatch the same operation on Luna max FRESH and announce the switch. Do not trim the prompt |
| wrapper exit 2 on `task` with the stale message (contains `release-stale`) | Run `"$ZDISPATCH" release-stale` with the same `--cwd`; single actor, never in parallel with another task / release-stale / cancel for this workspace. First match on exact output: (1) stdout `released <workspace> generation <n>` or (2) stderr `zcode-dispatch: workspace reservation generation <n> is already released` → reservation free; re-dispatch the identical operation once on GLM. (3) Stderr `zcode-dispatch: workspace reservation generation <n> is held by live runner pid <pid>` or `zcode-dispatch: workspace reservation generation <n> still has live CLI process group <pid>` → dispatch nothing into this workspace (no GLM, Luna or Sol); use a Monitor loop up to 10 minutes total, every 30 s running `"$ZDISPATCH" status` then `"$ZDISPATCH" release-stale` (same `--cwd`; `status` reaps dead runners and kills orphaned CLI groups); on `released …` / already released, do the one GLM re-dispatch, on a changed-reservation refusal follow (4), and on any case (6) output follow (6). (4) Stderr `zcode-dispatch: workspace reservation changed while checking; retry release-stale` → another job holds the workspace; apply Durable Progress item 4, poll it and never dispatch a second task. (5) The single GLM task re-run is refused again or the wait remains refused at 10 minutes → stop dispatching into this workspace and escalate to the user with the exact wrapper output. (6) Exact stderr `zcode-dispatch: no workspace reservation to release` or `zcode-dispatch: workspace reservation generation <n> has no valid holder`, any other `release-stale` refusal, or `release-stale` exit 1 → the same stop-and-escalate action, quoting the output. Luna/Sol fallback is allowed only after release is confirmed and the accepted GLM re-dispatch then fails under the existing infrastructure-failure ladder |
| wrapper exit 2 on `task` (any other guard) | not a job failure — fix the dispatch (wrong cwd, missing prompt file, another job running, kill switch); if the guard names `Info.plist`, `zcode.cjs` or the provider config → treat as `doctor` FAIL |

Read the class with `"$ZDISPATCH" status zt-XXXX --json | python3 -c "import json,sys; print(json.load(sys.stdin)['job']['errorClass'])"`. The job log (`~/.claude/plugins/data/superpowers-strigov-ver-zcode/state/<workspace-slug>/jobs/zt-XXXX.log`) holds the CLI's stderr and `[zcode-dispatch]` lines (argv summary without the prompt, timestamps, classification reason, raw stdout when it failed to parse). Unrecognised errors classify as `crash` — a retry and a Luna fallback, never a false success.

## Sandbox warning

> GLM runs **unsandboxed**, as your user account, in ZCode's `yolo` mode: it can read and write any file you can and reach the network. Codex's `--write` tasks are sandboxed to the workspace; GLM's are not. Mitigations in this plugin: the wrapper refuses to start outside a git work tree; every prompt begins with the ZCode preamble (no credentials, no paths outside the repo, no network beyond plan-mandated installs, no git history operations); phases carrying SECURITY or DATA_LOSS risk never go to GLM — they run on Codex Sol inside its sandbox. These are instructions to a model, not an enforcement boundary. The same holds for the CLI's own authentication: GLM's shell could read the Coding Plan API key from the personal provider config (its path is in the CLI's environment as `ZCODE_PERSONAL_PROVIDER_CONFIG_FILE`) just as it could read the OAuth credential in `cli-home`; the preamble forbids touching credentials. The wrapper scrubs the stored key from the CLI output it logs, records or prints (`<redacted: Coding Plan API key>`), but cannot catch an encoded copy. If that is not acceptable for a repository, run it with `SP_IMPLEMENTER=luna`.

A real boundary — a permission broker over `zcode app-server` with `--mode guarded` — is future work.

## Compliance

The wrapper passes the real `ZCODE_APP_VERSION` from `Info.plist` and `--surface terminal`; it adds no headers, rewrites none, and never pretends to be the desktop app. The wrapper never reads or writes the user's `~/.zcode`; the CLI's credentials, sessions, logs and plugins live in the wrapper's `cli-home`, and the wrapper never reads the credential there. In API-key mode the user hands the wrapper their own Coding Plan API key from Z.ai's key page; the wrapper writes it only into the CLI's own personal provider config, as a provider of ZCode's built-in "Z.ai Coding Plan" template, and the CLI — Z.ai's harness — sends it to Z.ai's Coding Plan endpoint itself. The wrapper never prints, logs or sends the key anywhere else, and never extracts a credential from either credential store. The one shared file is the CLI's own user config `~/.zcode/cli/config.json`, which the CLI reads on every run (no override exists). If Z.ai ever declares headless use of the CLI unsupported, the kill switch (`SP_IMPLEMENTER=luna`) turns the channel off without code changes.

Kill switch: within a session, the user's "через Luna" or "без GLM" turns GLM off until the session ends; permanently, `SP_IMPLEMENTER=luna` in the environment (the wrapper refuses `task` too). Nothing else.

## Never do

- Extract tokens from `~/.zcode`, read `credentials.json`, or call the Z.ai API / SDK directly — it violates the Coding Plan terms. The ZCode CLI through `$ZDISPATCH` is the only channel.
- Read, print or copy the API key from the personal provider config; ask the user to paste a key into the chat, or pass one as an argument or variable — the user pipes it into `api-key set` in their own shell.
- Give GLM a SECURITY / DATA_LOSS phase — risk-marked phases run on Codex Sol in its sandbox.
- Run two write tasks in one working tree across both dispatchers, or more than 2 write tasks in total.
- Switch implementer channels silently — every fallback and escalation is one announced line.
- Call `zcode -p` or `node zcode.cjs` bypassing the wrapper — the wrapper guarantees the env, the identification headers, the git-tree guard and the job record.
- Change ZCode settings, plugins, login or API key on the user's behalf — logging in (`"$ZDISPATCH" login`, which runs the CLI's `zcode login zai`), storing or clearing the API key (`"$ZDISPATCH" api-key set|clear`), enabling or disabling plugins are user actions. The wrapper's own personal provider config (the model pin, and the API-key rule the user stored) is the only ZCode-format file it writes.
- Run `doctor --probe` when the dev-orchestrator session marker already exists — one probe per session; the marker carries the result across compaction, and the probe spends quota.
- Omit `--background`; print per-poll status from the Monitor loop.
- Delete reservation files (`active.lock.*`) by hand while a job might run — a stale reservation is freed only by `"$ZDISPATCH" release-stale`.

## Session paths (for debugging)

- Wrapper: `<plugin-root>/bin/zcode-dispatch` → `<plugin-root>/bin/lib/zcode-dispatch.mjs`
- State: `~/.claude/plugins/data/superpowers-strigov-ver-zcode/state/<workspace-slug>/jobs/` — `zt-NNNN.json` (the job record) and `zt-NNNN.log`; `<workspace-slug>` = `<basename of the git root>-<first 8 hex of sha1(root)>`
- Personal provider config (wrapper-owned, mode 0600; holds the model pin and, in API-key mode, the user's Coding Plan API key — never read by the orchestrator): `~/.claude/plugins/data/superpowers-strigov-ver-zcode/personal-provider-config.json`
- CLI home (`ZCODE_DATA_BASE_DIR` of every CLI run, mode 0700; written only by the CLI and never read by the wrapper): `~/.claude/plugins/data/superpowers-strigov-ver-zcode/cli-home` — credentials `.zcode/v2/credentials.json`, storage root `.zcode/cli/` (plugins, rollouts, memories), sessions `.zcode/cli/db/db.sqlite`, logs `.zcode/cli/log/`
- CLI user config (no override; the CLI's own shared file, never edited by the wrapper): `~/.zcode/cli/config.json`
- Constants in the `.mjs`, filled from `docs/zcode-cli-findings.md`: `PINNED_MODEL`, `PINNED_SELECTION`, `API_KEY_TEMPLATE_ID`, `API_KEY_PROVIDER_ID`, `API_KEY_ACCESS_TYPE`, `API_KEY_SELECTION`, `VERIFIED_APP_VERSION`, `VERIFIED_NODE_MAJOR`, `MAX_PROMPT_BYTES`, `PROMPT_TRANSPORT`, and the classifier `PATTERNS`
- Discovery facts and the live-acceptance results: `docs/zcode-cli-findings.md`
