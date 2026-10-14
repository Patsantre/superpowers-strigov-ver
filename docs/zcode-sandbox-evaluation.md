# `sandbox-exec` for the ZCode CLI — evaluation (not adopted)

- Date: 2026-10-14
- Machine: macOS 15.7.7 (Darwin 24.6), `/usr/bin/sandbox-exec` present
- Scope: should `zcode-dispatch` run the ZCode CLI (`--mode yolo`, unsandboxed — plan R9) under a macOS Seatbelt profile that limits writes to the workspace root plus the CLI's own state, and network to `zcode.z.ai` / `api.z.ai` and the local proxy?
- Method: experiments with throwaway commands (`/usr/bin/true`, `/bin/sh`, `nc`, a small Node loopback script) under hand-written profiles. The ZCode CLI was never run under a profile.
- Decision (user, 2026-10-14): report only; nothing is implemented. The environment allowlist (plan C5) is the enforced limit that shipped.
- Written before the CLI data home (plan Ф4a): where this report names `<HOME>/.zcode` as the CLI's write root (sessions, logs, credentials), wrapper runs now use `<ZCODE_STATE_DIR>/cli-home/.zcode`; the CLI still reads `~/.zcode/cli/config.json`.

## Verdict

- **Writes:** a writes-only profile works. It stops writes outside the repository and persistence in the user's account. Typical implementer work suffers moderate breakage: package-manager and build caches under `~` fail until redirected.
- **Network:** a domain-level limit to `zcode.z.ai` / `api.z.ai` cannot be expressed in Seatbelt. It needs a filtering proxy that the wrapper runs, and on this machine it conflicts with tests that start local servers.
- **Recommendation:** do not adopt now. If GLM's blast radius needs a real limit later, start with an opt-in writes-only profile (`ZCODE_SANDBOX=write`, off by default), or move network filtering to a maintained runtime (see "If adopted later").

## Verified facts

| # | Fact | Evidence |
|---|---|---|
| F1 | `sandbox-exec` works on this macOS. Its man page has called it deprecated for years, yet it still ships, and Codex CLI and Claude Code build their macOS sandboxes on it. | `sandbox-exec -p '(version 1)(allow default)' /usr/bin/true` → exit 0 |
| F2 | Profiles do not nest. A process already inside a sandbox cannot apply another one. If the caller of `zcode-dispatch` (Claude Code's Bash tool with its sandbox on, Codex `workspace-write`) is sandboxed, a sandboxed wrapper fails. It would need a clear refusal or an unsandboxed fallback. | nested `sandbox-exec … sandbox-exec …` → `sandbox_apply: Operation not permitted`, exit 71 |
| F3 | A write allowlist is enforced. | `(deny file-write*)(allow file-write* (subpath "<ws>"))`: a write inside succeeds; outside: `Operation not permitted` |
| F4 | A network rule cannot name a host or an IP address. Only `*` or `localhost` with a port is accepted. | `(remote ip "api.z.ai:443")` and `(remote ip "198.18.0.1:443")` → `host must be * or localhost in network address` |
| F5 | `(deny network*)` blocks direct egress. | `nc -z 1.1.1.1 443` under the profile → refused |
| F6 | When only the proxy port is allowed on loopback, a test that opens a local server on an ephemeral port cannot connect to it. | Node: `listen(0)` then `connect` → `EPERM` with `(remote ip "localhost:1082")` only; works with `localhost:*` |
| F7 | With `localhost:*` allowed, the machine's system proxy `127.0.0.1:1082` is reachable. That proxy forwards anywhere, so allowing it means allowing the whole internet. | `nc -z 127.0.0.1 1082` under `(allow network-outbound (remote ip "localhost:*"))` → succeeded |

## The profile that would be needed (sketch, not implemented)

SBPL: the last matching rule wins, and paths must be real paths (`/private/var/folders/…` for `TMPDIR`, `/private/tmp`).

```scheme
(version 1)
(allow default)                                    ; reads, process exec, mach lookups unchanged
(deny file-write*)
(allow file-write*
  (subpath "<workspace root>")
  (subpath "<HOME>/.zcode")                        ; sessions, logs, credential refresh, cli/exec
  (subpath "<ZCODE_STATE_DIR>")                    ; job records, personal provider config
  (subpath "<realpath of TMPDIR>") (subpath "/private/tmp")
  (literal "/dev/null") (literal "/dev/zero") (literal "/dev/tty") (regex #"^/dev/fd/") (regex #"^/dev/ttys"))
;; files that something unsandboxed executes later — writable roots must exclude them
(deny file-write*
  (literal "<workspace root>/.git")                ; a worktree's .git file can be re-pointed at another gitdir
  (subpath "<workspace root>/.git/hooks")
  (literal "<workspace root>/.git/config")         ; core.hooksPath, core.fsmonitor run commands
  (subpath "<workspace root>/.claude")             ; Claude Code project hooks and settings
  (literal "<workspace root>/.mcp.json"))
;; network, only together with a wrapper-run filtering proxy (see "Network"):
;; (deny network*)
;; (allow network-outbound (remote ip "localhost:<filter proxy port>"))
;; (allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))
```

The CLI and the Bash tool it spawns share one sandbox, because a sandbox is inherited by child processes. Whatever the CLI may write, GLM's shell commands may write too.

## Breakage risk for typical implementer work

| Work | Writes-only profile | + network limited to z.ai |
|---|---|---|
| Edit files in the repository; `git diff` / `git status` | works | works |
| Same in a parallel-track worktree | the worktree's gitdir lives in the main repository's `.git/worktrees/<name>`, outside the root, so index refreshes fail quietly and `git add` fails. The orchestrator commits, so this is noise rather than a blocker | same |
| `npm` / `pnpm` / `yarn` / `bun install` | fail on the caches `~/.npm/_cacache`, `~/Library/pnpm/store`, `~/.yarn/berry/cache`, `~/.bun/install/cache`. Redirecting each cache into the state root (`npm_config_cache`, `npm_config_store_dir`, `YARN_CACHE_FOLDER`, `BUN_INSTALL_CACHE_DIR`) fixes it, at the cost of a cold cache | fail: registries unreachable unless the proxy allowlists them (`registry.npmjs.org`, `registry.yarnpkg.com`, `codeload.github.com`, …) |
| `pip install` into a venv inside the repository | works; pip warns and runs without its cache (`~/Library/Caches/pip`) | fails (`pypi.org`, `files.pythonhosted.org`) |
| `go build` / `go test` | fail: `GOCACHE` (`~/Library/Caches/go-build`) and `GOMODCACHE` (`~/go/pkg/mod`); fixable by redirect | module downloads fail (`proxy.golang.org`, `sum.golang.org`) |
| `cargo build` / `cargo test` | `target/` works; fetching fails on `~/.cargo/registry` | fails (`index.crates.io`, `static.crates.io`) |
| jest / vitest / pytest / mocha | work: caches in `TMPDIR` or in the repository | tests with a local server: work only with `localhost:*`, which re-opens the system proxy (F7) |
| Xcode / SwiftPM | fail: `~/Library/Developer/Xcode/DerivedData`, `~/Library/Caches/org.swift.swiftpm` | — |
| node-gyp native builds, Playwright browser installs | fail: header and browser caches under `~/Library/Caches` | fail |
| The CLI's own WebFetch / WebSearch / `web_reader` tools | work | fail (arguably desired) |
| Homebrew, global installs | fail (desired) | fail |

## Network

- Seatbelt cannot filter by domain (F4). The only enforceable rule is "loopback ports only". Every allowed domain therefore has to pass a proxy that the wrapper runs on loopback. That proxy would filter `CONNECT` targets against an allowlist (`zcode.z.ai`, `api.z.ai`, plus package registries if installs must work) and chain to the user's upstream proxy.
- The ZCode CLI ignores `HTTP(S)_PROXY` for its own requests (findings header). The wrapper would point `ZCODE_HTTP_PROXY` at the filtering proxy. The CLI then also sets `HTTP(S)_PROXY` for its tools (findings "## Environment"), so `npm`, `pip` and `git` over HTTPS follow. Tools that open raw sockets (git over SSH, some native binaries) would fail.
- **This machine:** `127.0.0.1:1082` is a general-purpose proxy (F7), and DNS answers with `198.18.x` fake-IPs from a TUN-mode client.
  - Allowing the "local proxy" as such equals no network limit.
  - Allowing `localhost:*` for local-server tests re-opens it (F6, F7). Seatbelt has no port ranges or exclusions. A limited network and loopback-based tests cannot be had together.
- The CLI also contacts endpoints beyond the two model hosts: the builtin-provider CDN refresh (already failing on the read-only app bundle), telemetry and JWT refresh. A live trace (`log stream --predicate 'sender == "Sandbox"'`) would be needed before any network rule ships.

## Residual risks even with the profile

- **Reads stay open** (`allow default`): `~/.ssh`, `~/.aws`, `~/.config/gh`, `~/.zcode/v2/credentials.json`. With network open they can be exfiltrated; with the filtering proxy only to the allowlisted hosts. Denying reads of these paths is possible, but the CLI itself must read `~/.zcode`.
- **`~/.zcode` stays writable** for GLM's shell, because the CLI needs it. GLM could plant ZCode settings or plugins that the desktop app or a later unsandboxed CLI run executes. Narrowing to exact subdirectories needs the live trace above.
- **Repository contents are executed later by design:** `package.json` scripts, `Makefile`, `.envrc`, test files. The review of the diff is the gate there, not the sandbox.

### Flagged while evaluating, independent of the sandbox

Today, unsandboxed, GLM can write `.git/hooks/*` or `core.hooksPath` / `core.fsmonitor` in `.git/config`. These files are never part of the reviewed diff, and the orchestrator's next `git commit` runs them as the user. A cheap mitigation with no breakage: hash `.git/hooks`, `.git/config` (and, for a worktree, its `.git` file and the common dir's hooks/config) before the run and fail the job on any change. This is not implemented; it is a candidate follow-up.

## If adopted later

1. Opt-in `ZCODE_SANDBOX=write` (writes-only profile above, network open):
   - cache redirects into `<ZCODE_STATE_DIR>/cache/<workspace slug>`;
   - a `doctor` check that refuses inside an existing sandbox (F2);
   - stub tests (a stub mode that tries to write outside the workspace, and into `.git/hooks`);
   - one live acceptance run with a `log stream` trace to settle the `~/.zcode` subpaths.
2. Network filtering only through a maintained runtime, not hand-written SBPL plus an ad-hoc proxy. `@anthropic-ai/sandbox-runtime` (0.0.79 on 2026-10-14, pre-1.0) wraps a command with `sandbox-exec`, a write allowlist and a domain-filtering proxy. It would be the wrapper's first dependency, and the loopback conflict above still applies.
