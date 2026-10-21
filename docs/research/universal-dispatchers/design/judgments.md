# Design judgments (2026-10-20)

Three judges scored the four proposals in this directory, each under one lens. Saved verbatim from the design workflow so that the [J1]–[J3] citations in the final research document resolve.

## J1-feasibility

Ranking: D1-incremental > D4-abstraction > D2-user-config > D3-security

| Proposal | Score |
|---|---|
| D1-incremental | 8 |
| D4-abstraction | 6.5 |
| D2-user-config | 5.5 |
| D3-security | 4.5 |

### Recommendation

Build the final design on D1's increment plan, because it is the only one whose first increments are behaviour-neutral, oracle-gated and deliver the user's top request early.
- Inc 0: extract dispatch-core.mjs and adapters/zcode.mjs. Exit criterion: the existing 110-test zcode oracle still passes.
- Inc 1: claude-compat adapter. The implementer runs as T2 on the native Bash sandbox with allowedDomains:[] and a credentials deny; the reviewer runs as T1 with Read/Glob/Grep and no Bash. Pin settings with --setting-sources "" and --settings, and set CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1.
- Then implementer routing, then the reviewer role, then codex-provider. srt comes only later, as an opt-in tier for SECURITY/DATA_LOSS phases.

Graft in from D4:
- reduce() as the sole decider of status and errorClass, with a core-computed onFailure/downProfiles/quotaGroup table, so the failure ladder moves out of SKILL.md prose.
- A requiredFlags check against --help in doctor (include --verbose when using stream-json) and recorded dialect fixtures.
- The L3 ref check for read-only jobs.

Graft in from D2:
- read-only explain/route verbs that print skip reasons;
- errorGroup naming;
- the companion overlay that makes `result` exit 1 on failure;
- the gate-allowlist row edits at SKILL.md:46 and :61-72.

Graft in from D3:
- one shared reservation root from day one;
- a per-job 0600 secret file read via auth.command instead of a print-key verb;
- plan classes with keyPattern and dataUse in the shipped policy;
- a measured SKILL.md byte budget as an acceptance check.

Explicitly reject:
- D2's TOML parser and interactive wizard at MVP, its inline doctor/probe in pick, and its routing of in-process claude roles;
- D4's Inc 1 skill rewrite, new advisory and utility roles, and inproc adapter before any provider ships;
- D3's srt on the critical path, persisted canary state, and bin/ state hashing that can raise false security events.

Every failure path must end in an announced fallback to today's zcode/companion ladder or exactly one question to the user. Before shipping, fix the factual errors listed above, especially D4's dsh baseUrl and the reviewer-has-no-Bash rule.

### D1-incremental

**Strengths**

- Best fit to the existing code. Inc 0 moves the generic ~70% of bin/lib/zcode-dispatch.mjs (CORE ~900 lines, CORE-P ~250) into bin/lib/dispatch-core.mjs plus adapters/zcode.mjs, keeps zcode-dispatch's surface unchanged, and is gated by the existing tests/test-zcode-dispatch.sh oracle (110 PASS against zcode-stub.cjs). This is a real, low-risk, shippable increment.
- Delivers value in user-priority order. The claude-compat adapter is Inc 1, so the first new provider arrives in increment 1, not 4 or 5.
- Tiering is feasible today with no new binaries. The claude-compat implementer uses the native Bash sandbox with allowedDomains:[] and a credentials deny (the 09 'Alternative without srt'). The reviewer uses --tools Read,Glob,Grep with --permission-mode dontAsk and no Bash, matching 01 §16. srt stays off the critical path.
- Sizes are honest and itemised: Inc 0 ~1,700 lines moved plus ~120 new (1–2 days); Inc 1 ~1,100 code + ~900 tests + ~170 skill (4–5 days); MVP Inc 0+1+2 in ~2 weeks. It states SKILL.md growth (+25 net) rather than claiming savings.
- Provider and harness facts check out against the corpus: hosts and model ids, the Z.ai ZA2 harness list, llama-server port 9931, the E9 --setting-sources "" + --settings pin, E13 subprocess-env scrub, SIGTERM vs SIGINT semantics, and is_error with subtype:success.
- Low-ceremony. A kill switch and default routing reproduce today's behaviour exactly. Failures end in an announced fallback to the existing ladder. There are no persisted trust gates.
- Local-real tests against a loopback stub settle the open questions (deny-rule syntax, sandbox auto-allow of 127.0.0.1) before any remote use.

**Fatal or major flaws**

- There are three wrappers ($ZDISPATCH, $DISPATCH, $ADISPATCH), each with its own reservation store until a later reservationRoot option. Preventing cross-wrapper worktree overlap in the meantime depends on orchestrator discipline.
- The generic errorClass failure ladder (adding context and violation) stays as prose in SKILL.md. The 793-line, 127.6 KB orchestrator grows rather than shrinks.
- §7.1 omits the C1 gate-allowlist edits at SKILL.md:46 and :61-72, which must change for $ADISPATCH to be allowed. This is an omission that will bite at Inc 2 if not added.
- __print-key behind auth.command (Inc 4, codex-provider) exposes the key to any process that can run the wrapper. It is acceptable only because of the keys-dir deny and no model-side Bash access to the wrapper. A per-job secret file (D3) is tighter.

**Ideas to graft**

- Keep its increment order as the backbone: extract and run the oracle, then claude-compat, then implementer routing, then the reviewer role, then codex-provider.
- Keep its kill switch and identical-default routing, so Inc 0 and Inc 1 are behaviour-neutral until opted in.
- Keep its loopback-stub local-real tests for claude -p sandbox and deny-rule behaviour.
- Keep the claude-compat T2 implementer (native Bash sandbox + credentials deny) and the T1 reviewer (Read/Glob/Grep, no Bash) as the default confinement without srt.

### D4-abstraction

**Strengths**

- Cleanest dispatcher contract. A pure reduce() alone decides the terminal status and errorClass, the core computes onFailure and downProfiles, and quotaGroup ties profiles that share a plan.
- Version drift handling is well suited to the near-daily claude release cadence (01: 13 releases in 14 days). A requiredFlags check against --help, plus recorded dialect fixtures for replay tests.
- L3 ref check (no git ref or worktree change for read-only jobs) is cheap, verifiable by the coordinator, and low-ceremony.
- ACP is treated as an optional transport. This matches 10's hybrid recommendation, its hand-rolled NDJSON client pinned to protocolVersion 1, and the fact that TS SDK 2.0.0 removed ClientSideConnection.
- The companion parity run ends in exactly one question, which complies with the user's preference.

**Fatal or major flaws**

- Inc 1 bundles the registry, policy, route, the companion adapter with overlays, L3 and the full dev-orchestrator skill rewrite, including merging the invocation skills. All of that lands before any new provider exists. It is the riskiest change, with zero user value, and it touches the 793-line SKILL.md and the PIPELINE_SKILLS classification test (tests/test-pipeline-context.sh:14, :234).
- Scope creep: new roles (advisory-reviewer, utility) and an inproc adapter are not needed for the request and widen the test surface.
- Pass-through overlays on the vendored Codex companion's state and job files couple the plugin to the companion's internal format, which has no lock, timeout, reaper or errorClass.
- The dsh profile's baseUrl is wrong for the llm-deepseek route (see factual errors). Shipping as written would hit the wrong wire or upload the session log to an unpinned base.
- The claude manifest relies on stream-json, which needs --verbose with -p, but --verbose is absent from requiredFlags. The very check meant to catch drift would not guard it.
- The C21 rewrite list misses two Astra dispatch sites, so a 'complete' rewrite would leave stale model routing.

**Ideas to graft**

- The reduce()-only terminal decision and a core-computed onFailure/downProfiles table, so the ladder lives in code, not in SKILL.md prose.
- A requiredFlags check against `<bin> --help` in doctor, plus recorded dialect fixtures per harness version for replay tests.
- quotaGroup / downProfiles, so one 429 or quota-exhausted result marks all sibling profiles down for the run.
- The L3 ref check for read-only roles: the coordinator compares git refs and worktrees before and after.
- An ACP transport later and opt-in, first for dsh, with a hand-rolled v1 NDJSON client.

### D2-user-config

**Strengths**

- Best operator UX ideas: `explain` and `route` with per-profile skip reasons, quota_group, and errorGroups (down/retry/next/stop) mapping 429 to rate-limit.
- Fixes the companion's real defect, where `result` exits 0 on a failed job, by wrapping it so failure exits 1.
- Explicitly updates the gate allowlist rows (C1), which D1 forgets.
- Keys are typed by the user in their own terminal through a wizard, never in chat, which complies with the plugin's credential rule.

**Fatal or major flaws**

- Large up-front surface before the first new provider. A strict-TOML parser (~150 lines), an interactive add wizard, presets, port scanning, and ~15 verbs land in Inc 1. The ~2,500 lines of new code are underestimated relative to D1's itemised sizes.
- Inc 3 is a big-bang switch: the orchestrator routes every role, including in-process claude:opus/claude:sonnet pseudo-profiles, through `pick`, plus the companion wrapper and L3. This is the largest risk and is not reversible per role.
- `pick` runs doctor and a probe inline (up to 45 s) on the dispatch path. This adds latency and a stall point to every dispatch, against the low-ceremony preference.
- claude-code is rated T0 with key delivery via apiKeyHelper. Per 01 §6, apiKeyHelper sends both x-api-key and Bearer headers, and acceptance by third-party Anthropic-compatible endpoints is unverified.
- The reviewer gets 'read-only git Bash(...)', but git is not read-only (for example `git diff --output=<file>` writes files). 01 §16 gives the reviewer no Bash at all.
- Puts `local` in the utility list, which covers quickfix and the verification gate. 08 §9 limits a 16 GB local model to opt-in trivial phases or a non-authoritative summarizer.
- Removing zcode-invocation requires updating the PIPELINE_SKILLS list and its classification check (tests/test-pipeline-context.sh:14, :234). The proposal does not budget this.
- The claim that SKILL.md shrinks to about 720 lines (about 200 lines net of prose removed) is optimistic, given the new routing prose it adds.

**Ideas to graft**

- `explain`/`route` verbs that print the chosen profile and each skipped profile with its reason (read-only, no probe).
- An errorGroups naming (down/retry/next/stop) layered on the core errorClass.
- A companion wrapper overlay that makes `result` exit 1 on failed jobs.
- The gate-allowlist update rows for SKILL.md:46 and :61-72.
- quota_group in profile config.

### D3-security

**Strengths**

- The most thorough threat model. Plan classes with keyPattern and dataUse (M9), consistent with 07; exactly two ask-the-user situations.
- codex-exec reads a per-job secret file via /bin/cat rather than a print-key verb, which is a tighter key exposure than D1's __print-key.
- One shared reservation store from the start, avoiding cross-wrapper worktree overlap.
- Measured text budget: SKILL.md 127.6 KB, zcode-invocation 33.2 KB and codex-invocation 20.4 KB are accurate against the repo.

**Fatal or major flaws**

- srt 0.0.81 is a beta, not installed, whose key masking needs the EXPERIMENTAL tlsTerminate (09). D3 puts it on the critical path at Inc 3, so the user must install a beta before the first new provider ships.
- Delivery order delays the request. The first new provider value arrives at Inc 4 (codex-exec) and claude-code at Inc 5, although claude-compat is the user's top ask and feasible without srt (09 'Alternative without srt').
- L3 state integrity hashes channels.json, the policy, the plugin bin/ tree and the keys listing. A hand edit or a plugin auto-update mid-job raises false 'security events', a stalling gate the user explicitly rejected.
- The canary cache in tiers/<P>.json is persisted trust state that can go stale and block routing, again against the low-ceremony preference.
- It never specifies the claude-code implementer permission mode that lets Bash run under the sandbox, leaving the T1 claude path unimplementable as written.
- The thesis that every role runs in an OS sandbox tier contradicts its own T0 for zcode and native claude-code.
- Heaviest orchestrator text of the four, with the most new verbs and states to describe in SKILL.md.

**Ideas to graft**

- A per-job 0600 secret file read by the harness's auth.command (/bin/cat) instead of a print-key verb.
- Plan classes in the shipped policy with keyPattern and dataUse/M9 fields, so terms-of-service refusals are data, not prose.
- One reservation root shared by all wrappers from day one.
- Its measured SKILL.md and invocation-skill byte budget as an acceptance check (no net growth beyond a stated cap).
- srt as a later opt-in tier for SECURITY/DATA_LOSS phases only, never required.

### Factual errors found in the proposals

- D4: the dsh profile sets baseUrl https://api.deepseek.com, but the llm-deepseek route speaks Anthropic Messages only. Its default baseURL is https://api.deepseek.com/anthropic, and the session log uploads to the resolved baseURL, so the adapter must pin it (04b).
- D4: the policy marks chatgpt-plus-pro × pi as ok, while its own pi adapter refuses any OAuth authType. This is an internal contradiction; 07 §5 allows only the ChatGPT-subscription flow and rules out pi's Anthropic and Copilot logins.
- D4: the C21 rewrite list misses two Astra dispatch sites, skills/brainstorming/SKILL.md:221 and skills/writing-plans/SKILL.md:59. Both contain `--model gpt-6-astra --effort xhigh`.
- D4: the claude manifest uses --output-format stream-json, which requires --verbose with -p, but --verbose is not in its requiredFlags.
- D2: 'read-only git Bash(...) + dontAsk [01 §16]' misquotes 01 §16, which gives the reviewer --tools Read,Glob,Grep with no Bash. git is not read-only (`git diff --output=<file>` writes).
- D2: apiKeyHelper key delivery for claude-code omits that apiKeyHelper sends both x-api-key and Bearer headers (01 §6). Acceptance by third-party endpoints is unverified.
- D2: placing `local` (a 16 GB M4) in the utility role, which covers quickfix and the verification gate, contradicts 08 §9. On 16 GB, only opt-in trivial phases or a non-authoritative summarizer are allowed, never a gate.
- D2: its open question says the Alibaba Token Plan ships Personal=no and Team=gray, but its policy excerpt has no Token Plan row. 06 marks the Token Plan as not compliant.
- D3: the thesis that every role runs in an OS sandbox tier contradicts its own T0 (unconfined) rating for zcode and native claude-code. The ZCode key cannot be masked on macOS (09).
- D3: '86 lines mention GLM/ZCode/zt-' in SKILL.md. The measured count is 80 case-insensitive and 68 case-sensitive. This is minor.
- D1 (omission, not contradiction): §7.1 lists the SKILL.md edits but omits the C1 gate-allowlist changes at SKILL.md:46 and :61-72, which 00 lists as required for any new wrapper.

## J2-safety

Ranking: D3-security > D1-incremental > D4-abstraction > D2-user-config

| Proposal | Score |
|---|---|
| D3-security | 8 |
| D1-incremental | 7.5 |
| D4-abstraction | 5.5 |
| D2-user-config | 4.5 |

### Recommendation

Use D1 as the delivery skeleton. It is the most realistic sandboxing plan: the MVP needs only Claude Code's built-in Bash sandbox and Codex's native sandbox, with no beta srt. Its argv and settings close the E9, E13 and E23 holes, and it pins plan to host correctly, including the `token-plan.` exclusion.

Then graft D3's security invariants:
- no key-returning verb; the Codex key comes from a job-scoped secret file, with a permission-profile deny on keys/, homes/* and the credential stores, and the reaper deletes leftover secret files;
- login flows closed by construction, with doctor auth-method assertions;
- a security event (credential-leak or sandbox-violation) stops dispatch into that tree and asks exactly one question with a restore-to-BASE option; reject D4's down-and-continue;
- writer families checked as a union, with --same-family-ok;
- a mandatory --phase-risk flag;
- an M9 dataUse gate for risk profiles;
- OS read-only reviewers at least for risk phases (M8);
- srt only as a later opt-in tier with D3's fail-closed preflight and a proxy-free srt env.

From D4 take:
- reduce() as the only success decider, with stub modes for each exit-code trap;
- an L3 read-only check, extended so `git status --porcelain` must also be unchanged;
- downProfiles propagation by credential ref and quotaGroup;
- the requiredFlags `--help` doctor check;
- static riskEligible flipped only by a code change, instead of D3's forgeable tier cache;
- the companion overlay (result exits 1 on failure, dead pid → crash).

From D2 take:
- unknown 429 → retry;
- the stop-question options;
- rejection of cleartext and `env:` key references;
- the Z.ai key-type question.

Mandatory fixes to D1 itself:
- add `sandbox.filesystem.denyRead` for the agents data root and the harness credential stores, alongside the Read deny rules;
- add a local-real canary that sandboxed Bash cannot `cat keys/*`;
- scan every stored key, not only the job's own, in the post-run check;
- add a doctor WARN that the grandfathered T0 ZCode channel can read other profiles' keys;
- keep dsh off implementer roles until it runs under srt with its own sandbox off.

Do not adopt D2's apiKeyHelper key file or its codex-exec custody without the deny-read rules. Do not adopt D2's or D4's lack of plan-to-host binding.

### D3-security

**Strengths**

- Only design that closes impersonating login paths by construction. Adapters never run a login, every home starts fresh, and doctor checks the auth method: claude `auth status` must report `oauth_token` or `api_key_helper`, `pi auth check` must not report oauth, and OpenCode's `enabled_providers` must hold only the declared provider. It also refuses to have any key-returning verb (no print-key).
- Binds each plan to its hosts and key pattern. `no` rows cannot be overridden by any flag, env var or field, unknown triples are denied by default, and a gray pair needs a one-time consent typed at a TTY with the evidence text shown. Subscription plans are kept off srt masking (allowMask:false), consistent with the corrected Z.ai question of whether a local header swap counts as "use outside such tools".
- Reviewer read-only is OS-enforced in every reviewer role: the srt reviewer variant, or Codex `-s read-only`. That closes the 00 R1 gap the way 09 bottom line 7 describes.
- Turns the 09 §9 M1–M9 bar into code. Risk phases need T2, passed canaries and a provider dataUse of no-store or no-train. Those values match 06: Z.ai's DPA does not store content and Alibaba never trains, while DeepSeek, Moonshot and MiniMax are excluded.
- Its srt preflight follows 09 §7.4 exactly. It refuses when SANDBOX_RUNTIME=1, when srt is unpinned or sits inside a workspace, when allowLocalBinding is set, when the settings file is under allowWrite, or when a dry run fails. It spawns srt without proxy variables, so the :1082 parent proxy is never chained, and it classifies cancel and timeout from the job record because srt exits 0 on SIGTERM.
- Codex gets its key from a job-scoped 0600 secret file, and a permission profile marks keys/, <job>/secret, homes/* and the credential stores as "none". CODEX_HOME is per chain.
- Writer family is the union over the phase's sidecars, with an explicit --same-family-ok for the two existing announced exceptions. --phase-risk is a required flag, so leaving it out is an exit 2, not a silent default.
- The L3 audit checks plain, base64 and hex forms of the key and the srt sentinel, plus protected paths and a state-integrity hash. On a hit it quarantines the response and asks one question that includes restoring files to BASE. It also says plainly that T0 jobs can read other profiles' keys, and doctor warns about it.
- Per-harness cancellation matches the corpus: Codex SIGINT then sweep, pi SIGTERM then sweep, OpenCode snapshot and sweep, dsh snapshot then SIGINT, 7 s, SIGKILL, kill PGIDs. dsh patch settings are verified with --dump-config.

**Fatal or major flaws**

- Every capability above T0 for a non-Codex harness depends on srt 0.0.81: a beta with roughly weekly releases, not installed on this machine, whose masking needs the EXPERIMENTAL tlsTerminate. Until the user installs it and canaries pass, Claude Code, pi and OpenCode cannot serve any reviewer role, so diversity arrives late.
- The `alibaba-payg` host glob `*.maas.aliyuncs.com` also matches the Token Plan host `token-plan.ap-southeast-1.maas.aliyuncs.com` (06 §1.1). The host binding therefore cannot tell PAYG from the Token Plan that D3 itself marks `no`.
- Tier eligibility comes from a runtime cache, `tiers/<P>.json`, in the user state dir. That file is not covered by the L3 state-integrity hash, so a prompt-injected T0 job (ZCode yolo) could forge a passing canary record. It is also persisted trust state of the kind the low-ceremony preference avoids.
- The thesis says every role runs in an OS sandbox tier, yet zcode with sandbox none, dsh native and claude-code native remain T0 implementer options.
- The job-scoped `<job>/secret/key` is removed only at job end. A crash or SIGKILL leaves it on disk until something deletes it, and the reaper is not specified to do so.

**Ideas to graft**

- Close login flows by construction, with a doctor auth-method assertion in every adapter (claude, pi, OpenCode).
- No key-returning verb. Deliver the Codex key through a job-scoped 0600 secret file plus a permission profile that denies keys/, the job secret dir, homes/* and the credential stores, and have the reaper delete stale secret files.
- Bind plan to host and key pattern, using D1's `token-plan.` negative lookahead, and refuse any base URL that matches a different plan's hosts.
- Require OS read-only reviewers (Codex -s read-only now, the srt reviewer variant later) at least for risk-phase reviews, per M8.
- Gate risk profiles on provider dataUse (M9).
- Make --phase-risk a required flag. Check writer families as the union over sidecars, with --same-family-ok for the existing exceptions.
- Adopt the srt fail-closed preflight list and spawn srt with no proxy variables.
- L3 secret scan for raw, base64, hex and sentinel forms, quarantine on a hit, and a one-question security event with a restore-to-BASE option.
- A doctor WARN that T0 jobs can read other profiles' keys.
- Kill-switch tokens `family:`, `plan:` and `harness:`.

### D1-incremental

**Strengths**

- Closes both holes 01 found with concrete argv and settings. `--setting-sources ""` plus `--settings` stops the repo settings redirect (E9). Exactly one credential variable, CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 and a sandbox.credentials deny entry keep the token out of Bash (E13). The env allowlist strips CLAUDE_CODE_ENTRYPOINT (E23); I confirmed in bin/lib/zcode-dispatch.mjs that ENV_DENY plus ENV_ALLOW drop every ANTHROPIC_* and CLAUDE_* variable. Inc 1 replays E9, E13 and E23 locally with dummy tokens before any LIVE run.
- Pins plan to host in agent-policy.json, and its Alibaba PAYG pattern explicitly excludes `token-plan.` hosts. key set blacklists the `sk-sp-` prefix. Unknown pairs are denied by default. api.anthropic.com is refused, and so is any profile home that holds a claude.ai login (checked with `claude auth status --json`).
- Risk phases are gated to T3 in code: Codex native, with the harness and key outside the sandbox and network off. A Codex permissions profile makes the keys dir unreadable. Cancel ladders match the corpus: SIGINT then sweep for Codex (05 §10), SIGTERM first for claude, which kills Bash trees (01 §10).
- Realistic sandboxing. The MVP uses only Claude Code's built-in Bash sandbox (failIfUnavailable, allowUnsandboxedCommands:false, empty allowedDomains) and Codex's native sandbox, with no standalone srt. Nesting is acknowledged: doctor checks SANDBOX_RUNTIME, and a nested start ends as `launch` and falls back.
- A `violation` (key in the diff, report or result, or .git/hooks or .git/config changed) takes the channel down, stops further dispatch into that tree, and asks exactly one two-option question.
- Profile reviewers get no Bash, Edit or Write, run with dontAsk, strict MCP config and hooks off, and take no reservation. The never-build list covers every no-go in 07 (pi's Anthropic and Copilot logins, Google consumer OAuth, the Alibaba Coding Plan, Kimi membership, translating or pooling proxies).
- Low ceremony: each exit-2 refusal kind has one fixed reaction, and the line-1 token contract is unchanged.

**Fatal or major flaws**

- The keystore file can be read by the implementer's sandboxed Bash. The settings deny only the Read tool (`permissions.deny Read(<agents root>/**)`). 01 §8 says sandboxed Bash reads "most of the machine, including credential files" unless `denyRead` or `credentials` cover them, and 01 §16's own sketch sets `sandbox.filesystem.denyRead`. The §6.2 claim "not visible to Bash" covers the env var only, and no local-real canary checks `cat keys/*` from Bash.
- The post-run scan looks only for the job's own key. A T2 claude job, and the grandfathered T0 ZCode yolo GLM channel, can read every profile's key in the shared keys/ dir. The design does not acknowledge the cross-channel exposure it creates by putting a key store next to a T0 channel.
- The `__print-key` verb returns any key to any process that can run node as the user, including a T0 GLM job or an unsandboxed hook, without that process needing to know the file paths. It is redundant given a job-scoped secret file.
- The family check takes a single --writer-family. A phase written by GLM and then escalated to Sol has two writer families.
- Reviewers of risk phases are not required to be OS read-only (09 §9 M8): T1 tool-removal reviewers are accepted for every phase. Reviewer jobs get no L3 check that HEAD, refs and the worktree are unchanged.
- M9 (provider data terms) is left entirely to the user for T3 risk profiles.
- dsh is offered "on its native sandbox" in Inc 5, although D1 requires at least T2 for new implementer profiles and native dsh confines only writes, with no network or read confinement.

**Ideas to graft**

- Use D1 as the delivery skeleton: Inc 0 extraction against the 110-test oracle, then claude-compat, then implementer ladder routing, then the reviewer kind, then codex-provider at T3.
- agent-policy.json with plan-to-hosts mapping, a hostPattern that excludes `token-plan.`, and a key-prefix blacklist enforced at key set.
- The exact claude-compat argv and settings: --tools allowlist, --strict-mcp-config, --disable-slash-commands, disableAllHooks, skipWebFetchPreflight, every model alias pinned to a provider ID, WebFetch and WebSearch denied. Plus a profile-env allowlist that refuses ANTHROPIC_BASE_URL.
- Inc 1 local-real replays of E9, E13 and E23 on loopback with dummy tokens. Extend them with a Bash `cat keys/*` canary and add `sandbox.filesystem.denyRead` for the agents data root and the harness stores.
- `violation` → down, dispatch nothing more into the tree, ask one question.
- Per-profile concurrency slot files with O_EXCL creation and boot-id reaping.

### D4-abstraction

**Strengths**

- `reduce()` alone decides success. One stub mode exists for each exit-code trap: exit0-error, sigterm-exit0, error-then-recover, stdin-wait, detached-child, late-session. Recorded dialect fixtures make a harness upgrade a record, replay and bump of the tested version.
- Read-only reviewer jobs get an L3 check that HEAD and the ref set are unchanged.
- downProfiles propagation: an auth failure takes down every profile that shares the credential ref, and a quota failure takes down every profile in the same quotaGroup (glm-zcode and glm-cc share one plan).
- Every doctor run checks offline that each requiredFlags entry still appears in `--help`, and a version policy sets tested, accepted and outside values, with FAIL outside the range for prerelease harnesses.
- riskEligible is static and flips only through a reviewed code change after LIVE canaries, so there is no persisted trust state.
- Adapter hard refusals apply whatever the policy says: pi with any OAuth login, claude with a claude.ai login or inherited OAuth token on a non-Anthropic baseUrl, a local profile with a non-loopback baseUrl, and `--oss` never emitted. `task` re-checks everything, so `route` is never the security boundary.
- The companion overlay makes `result` exit 1 on a failed job and reports a dead pid as `crash`. ACP is treated as a transport, not as a security boundary.

**Fatal or major flaws**

- Security events do not stop work. `sandbox`-class failures (git-config-changed, credential-leak, read-only-violated) map to `down`, and the same operation is re-dispatched FRESH on the same tree with no question to the user. A modified .git/hooks stays in place for the orchestrator's later unsandboxed commit (09 §1), and a leaked key stays in the worktree.
- No plan-to-host binding anywhere: the registry checks only family against the model id. The plan is a user-declared label, so a no-go plan's endpoint behind a PAYG label passes the policy.
- The codex adapter is statically riskEligible, using env_key with ignore_default_excludes=false, but it does not deny the dispatcher keystore and credential stores through a permission profile (09 §7.3, M2). Codex's default sandbox allows reads, so tools can read every stored key.
- Native dsh (writes-only, called T1) is described as able to become riskEligible after canaries, contradicting 09 §3 (corrected): DSH leaves reads and process visibility open, so M2 and M4 cannot be met natively.
- A `permission-rules` read-only level (an OpenCode agent with git prefix allows) counts for blocking reviewers. The L3 check covers HEAD and refs but not worktree file writes, for example via `git diff --output=`. Risk-phase reviewers are not required to be OS read-only (M8).
- The claude implementer runs acceptEdits plus --allowedTools without narrowing --tools (M7), and the design does not state Read or Bash denies on the keystore.
- Escalation has no risk gate, and the parity run writes trust entries into the user's own ~/.codex config.

**Ideas to graft**

- reduce() as the only success decider, with stub modes for each trap and recorded dialect fixtures.
- L3 read-only check, extended so that `git status --porcelain` must also be unchanged for reviewer jobs.
- downProfiles keyed by credential ref and by quotaGroup.
- requiredFlags `--help` check and a tested/accept/outside version policy.
- Static riskEligible changed only by a code change, replacing D3's runtime tier cache.
- Companion overlay: result exits 1 on failure, dead pid → crash, and write jobs count toward the caps.
- An inproc pseudo-adapter so the in-process Claude roles are visible to the family rule.

### D2-user-config

**Strengths**

- errorGroup `stop` for credential-leak and sandbox-violation, ending in one three-option question. Its reasoning for mapping an unclassifiable 429 to retry rather than down is sound: a misread quota costs one retry, a misread throttle would take the profile down for the session.
- No `env:` key references and no cleartext keys. key set refuses argv input, refuses an `sk-sp-` key for alibaba-payg, and the wizard asks which Z.ai key type the user has.
- Policy is deny-by-default. accept_gray is written only by `add` after the user types the plan id. pi's anthropic and github-copilot logins are refused. dsh gets a pinned baseURL and its session-log upload is neutralized.
- Exit-code traps match the corpus: OpenCode exit 1 after a recovered compaction, OpenCode stdin must close, Codex unknown model exits 0, dsh SIGTERM exits 0. The companion `result` is fixed to exit 1 on failure.
- Identity stays truthful, and third-party models never go through the companion.

**Fatal or major flaws**

- claude-code key custody leaks. The apiKeyHelper reads keys/<ref>.key, but nothing denies that file to the unsandboxed Read tool or to sandboxed Bash (01 §8, 09 §2.6), so every claude-code job can read every stored key. apiKeyHelper also sends both auth headers (01 §6), which is unverified per provider.
- codex-exec is marked riskEligible with `auth.command /bin/cat <0600 file>` and no Codex permission-profile deny-read. 09 §5 F and §7.3 make that deny the condition for the key being unreadable, so M2 and M4 fail. Putting deepseek-cx in the risk list breaks the 09 §9 bar, and M9 is display-only for a PRC provider with no no-training promise.
- No plan-to-host binding: `plan` and `base_url` are overridable labels, so a mislabel defeats ToS gating, for example a Token Plan URL under alibaba-payg.
- Blocking reviewers may rely on tool or permission read-only that includes `Bash(git …)` patterns (claude-code, OpenCode); git's `--output=` writes files. There is no OS read-only even for risk phases (M8), and no check that a reviewer left the worktree and refs unchanged.
- The `utility` role includes the verification gate and quickfix and can be routed to a local 16 GB model, contradicting 08 §9 (only a non-authoritative summarizer on 16 GB).
- Escalation has no risk gate, so a T0 profile listed under `escalation` can receive a risk-marked phase.
- L3 checks arrive in Inc 3, after the claude-code adapter ships for ad-hoc tasks in Inc 2.
- The writer family comes only from the highest-seq sidecar. The claude-code manifest says nestsSeatbelt:false while turning Claude's Bash sandbox on.

**Ideas to graft**

- An unclassifiable 429 maps to retry, not down.
- The `stop` question options: discard the job's changes, keep them for inspection, or stop the plan.
- Reject cleartext and `env:` key references with a remedy message. `key list` shows refs only, and keys/<ref>.meta.json records the declared key type without key material.
- Ask for the Z.ai key type at setup.
- `explain <role>`, which prints why each candidate was skipped. It feeds the one-question rule.

### Factual errors found in the proposals

- D2 §3.4/§6.2: codex-exec key custody 'auth.command /bin/cat <0600 file> (F) [05 §6]' is presented as risk-eligible, but 09 §5 F says the key is unreadable to Codex tools only 'if the key file is a deny-read glob', and 09 §7.3 requires a permissions profile that marks the key file and credential stores 'none'. Without it M2 and M4 fail.
- D2 §3.2: the claude-code manifest declares nestsSeatbelt:false while D2 enables Claude's Bash sandbox. 09 §2.5 and §7.2 list 'claude with its Bash sandbox on' as nesting Seatbelt.
- D2 §4.5/§5.1: on 16 GB the local model gets the 'utility' role, which D2 defines to include the verification gate and quickfix. 08 §9 allows only a non-authoritative gate summarizer on 16 GB.
- D2 §4.6: the 'opencode-go × dsh = no (OC1)' row is stricter than the corpus. 07 §2 marks DSH '?' and says 'known problematic' is a technical header issue, not a terms issue. This errs in the safe direction.
- D3 §4.3: the alibaba-payg host glob '*.maas.aliyuncs.com' also matches 'token-plan.ap-southeast-1.maas.aliyuncs.com', the Token Plan host per 06 §1.1. The binding therefore cannot separate PAYG from the Token Plan that D3 marks no.
- D3 §1 thesis says 'Every role runs in an OS sandbox tier', but D3 §6.2 keeps zcode none, dsh native and claude-code native as T0 (unconfined) implementer tiers.
- D3 §4.3: 'anthropic-max × * = no', while 07 §5 lists Claude Pro/Max in the unmodified claude -p as a safe default (AN1-q4, AN3, AN5). This is stricter than the corpus and errs in the safe direction.
- D4 §3.4/§6.2: native dsh is said to become riskEligible 'after canaries' / 'on T1'. 09 §3 (corrected) says DSH confines writes only and leaves reads and process visibility open, so 09 §9 M2 and M4 cannot be met by native dsh.
- D4 §3.4/§6.1: codex riskEligible:true is defined with env_key plus ignore_default_excludes=false but without the keystore and credential-store deny-read that 09 §7.3 and M2 require.
- D1 §6.2: claims the claude-compat key is not visible to the model's Bash. That holds for the env var. For the key file in keys/, 01 §8 says sandboxed Bash reads credential files unless sandbox denyRead or credentials cover them. D1 sets only a permissions Read deny, which governs the Read tool, while 01 §16's sketch uses sandbox.filesystem.denyRead. The claim is unverified rather than proven wrong.
- D1 §3.7/§6.1: dsh is offered 'on its native sandbox' as an on-demand implementer, although D1 requires at least T2 (confined shell, no network, scrubbed key) for new implementer profiles, and native dsh has no network or read confinement (09 §3).

## J3-user-value

Ranking: D2-user-config > D4-abstraction > D1-incremental > D3-security

| Proposal | Score |
|---|---|
| D2-user-config | 8 |
| D4-abstraction | 7.5 |
| D1-incremental | 6.5 |
| D3-security | 4.5 |

### Recommendation

Under the user-value lens, build the user-facing surface from D2, deliver it in D1's order, and take policy completeness and the honest role set from D4.

1. **Delivery order (D1).** Extract the core with zero behaviour change, then ship claude-compat first, usable ad hoc before the orchestrator integration. That one adapter reaches GLM, DeepSeek, Kimi, MiniMax, Qwen PAYG, OpenRouter and local servers within about two weeks. Use D1's verified T2 settings for claude -p (Bash sandbox plus credentials deny plus env scrub) so the default is sandboxed with no srt install.

2. **User experience (D2).**
   - The `add <preset>` wizard with a hidden key prompt and role assignment, `setup` discovery, `presets --for <role>`, `explain <role>`, and `check`.
   - `pick` printing a ready-to-relay `announce:` line, plus exactly one `ask:` line when nothing is eligible.
   - Legacy aliases, so the old kill-switch phrases keep working.
   - The errorGroup table, with an unclassifiable 429 mapped to retry.

3. **Coverage (D4).**
   - Ship a policy.json that mirrors 07 §5 in full: GLM plan in zcode/claude/codex/pi/opencode; OpenCode Go in its validated clients; Copilot and ChatGPT Plus/Pro in OpenCode; ChatGPT Plus/Pro in pi only through the 'OpenAI (ChatGPT subscription)' flow, with the refusal limited to pi's Anthropic and Copilot logins.
   - Use the `login` ref plus `profile env`, so subscriptions are plugged in by the user's own harness login inside an isolated home.
   - Propagate auth and quota failures through `downProfiles` and quotaGroup.
   - Add `advisory-reviewer` and `utility` roles, read-only and non-authoritative.

4. **Adapter order after claude-compat.** OpenCode v1 next, since it is the unique subscription unlock. Then codex-exec (the only risk-eligible path for third-party models), then pi, then DSH (with session-log and baseURL neutralization).

5. **Keep honesty explicit.**
   - The local profile ships disabled. It uses llama-server on port 9931. On this 16 GB M4 it is limited to read-only log summarizing (08 §9), and the Ollama 4k-context pitfall is stated.
   - Unbenchmarked templates ship enabled:false with a note.
   - Gray plans need typed consent in the user's terminal. No-go plans are refused with a `hint:` that names the pay-as-you-go alternative.

6. **What not to adopt from D3.** Leave out the canary-tier cache and the state-integrity hashing (ceremony that risks false-positive stops) and srt as a prerequisite. Keep D3's per-refusal `hint:` codes, its family:/plan:/harness: kill-switch tokens, and its refusal of claude* model ids on non-Anthropic hosts.

### D2-user-config

**Strengths**

- The closest answer to the literal request. Section 4.5 walks through every case the user named: 'my DeepSeek key', 'my MiniMax plan' (it explains the gray status and offers pay-as-you-go first), 'my OpenCode subscription' (opencode-go preset, OC1 validated clients, v1 pin) and 'my local Ollama model'. The example profiles span zcode, claude-code, codex-exec, pi and opencode.
- The broadest role coverage: implementer, risk, escalation, plan_review, primary_review (claude:opus pseudo-profile), control_review, final_review and utility. It answers 'implementer AND other roles' directly, and the defaults reproduce v0.11.1 exactly.
- The easiest configuration of the four. One commented file, a terminal wizard (`add <preset>`) that stores the key behind a hidden prompt and asks which role to assign, `setup` that detects installed harnesses and local servers on the correct ports (11434/1234/9931), `presets --for <role>` with ToS, price and data notes, and `check` running doctor and probe in one step. The orchestrator never touches keys.
- The most understandable routing. `pick` prints a ready-to-relay `announce:` line that names skipped profiles and the reason ('Skipped glm-zcode: down (quota, 14:02)'). When nothing is eligible it prints exactly one `ask:` line with numbered options. `explain <role>` shows why each candidate is eligible or skipped. One errorGroup table (down/retry/next/stop).
- Legacy phrases ('без GLM', 'через Luna', SP_IMPLEMENTER=luna) keep working through aliases. `quota_group` models one Z.ai account used from two harnesses. An unclassifiable 429 maps to rate-limit rather than quota, so a misread cannot take a profile down for the whole session.
- Gray consent is a one-time act in the user's own terminal (typing the plan id). Data-jurisdiction notes are shown, not gated. This fits the low-ceremony preference.

**Fatal or major flaws**

- The policy.json in 4.6 conflicts with its own deny-by-default rule. Only zcode and claude-code are listed for zai-coding-plan, although 07 §2/§5 marks Codex, OpenCode and pi OK (ZA2). There are no ok rows for kimi-platform, minimax-payg, alibaba-payg, openrouter or opencode-go. Shipped as written, it would refuse its own example profiles (kimi-review, minimax, go). The table has to mirror 07 §5 in full.
- It overstates local models on 16 GB. The wizard allows the `utility` role there, and D2's utility covers quickfix and the verification gate. 08 §9 allows only a non-authoritative log summarizer on 16 GB, calls trivial implementer work an 'opt-in experiment', and rules advisory review out as too slow. It also picks Ollama as the local server without warning that Ollama defaults to 4k context below 24 GiB VRAM and silently drops messages (08 BL4). That pitfall would break a ~16-19k-token claude -p system prompt.
- DSH, one of the harnesses the user named, comes last among the adapters (Inc 7). The pipeline itself is not wired until Inc 3, so first in-pipeline value comes later than in D1.
- Shipping a hand-written TOML-subset parser adds maintenance and user-error surface. All three other proposals keep dependency-free JSON.

**Ideas to graft**

- The `add <preset>` wizard: hidden key prompt, role assignment, then an immediate check and PONG probe. Also the non-TTY form `! pbpaste | agent-dispatch add <preset> ... --key-stdin --yes`.
- `setup` that detects installed harnesses and loopback model servers and offers matching presets.
- `presets --for <role>` showing ToS status per harness, price index and data note. `explain <role>` showing why each candidate is eligible or skipped.
- `pick` printing a ready-made `announce:` line and, when the list is exhausted, exactly one `ask:` line with options. The orchestrator relays both verbatim.
- Aliases so legacy kill-switch phrases keep working, plus `display` names used in every announcement.
- A preset field and profile inheritance, so a user profile is 4-5 lines.
- The rule that an unclassifiable 429 maps to retry (rate-limit), not down (quota).
- `key list` and `where` verbs that show references and paths, never values.

### D4-abstraction

**Strengths**

- The most complete ToS policy. Its rows mirror 07 §5, including OpenCode Go in its validated clients, Copilot in OpenCode, ChatGPT Plus/Pro in OpenCode/pi and the GLM plan in zcode/claude/codex/pi/opencode. Of the four, it best answers 'OpenCode with its own subscription'.
- The `login` credential ref plus `profile env` lets the user run a harness's own login (opencode auth login, codex login) inside the profile's isolated home from their own terminal. Subscriptions plug in without the plugin ever handling the credential.
- The most honest treatment of local models. The profile is disabled by default and states that 16 GB is not viable as an implementer and that trivial phases need 32-48 GB. It uses llama-server on the corrected port 9931 and routes only to a read-only, non-authoritative `utility` role, which matches 08 §9 exactly.
- It adds `advisory-reviewer` and `utility` roles, which answers 'other roles' without touching the blocking pipeline. A weak reviewer such as Qwen3.8 Max is used only in advisory mode, which fits the 06 fact-check on its 77.7% timeouts.
- `downProfiles` widens one failure to every profile that shares the cause (same key on auth, same quotaGroup on quota). This avoids a cascade of identical failures the user would otherwise watch one by one.
- `route` prints the chosen profile with its skip reasons. `task --profile auto` saves a call. When routing runs out, the user gets one question that lists the dropped profiles with their reasons.
- Version churn stays manageable for the user. An offline `requiredFlags`-in-`--help` check costs zero tokens, every record carries `appVersion`, and a failed run's note says 'harness X differs from tested Y'.
- DSH arrives earlier than in any other proposal (Inc 4), with the session-log and baseURL neutralization the fact-check requires.

**Fatal or major flaws**

- Value arrives late. Inc 0 extracts the core, and Inc 1 is a large skill rewrite plus companion wrapping with no new provider. Third-party models arrive only in Inc 2. The scope also includes ACP, transports, dialect recordings and a companion-replacement parity run, which makes the plan heavy for a user who wants their keys working soon.
- Configuration is more manual than in D2. The user writes one JSON file per profile via `profile add --from ... --set k=v`, then hand-edits config.json in $EDITOR to put the profile into a role. There is no wizard, preset browser or discovery.
- The proposal contradicts itself on pi. The policy lists chatgpt-plus-pro x pi as ok, but the adapter hard-refuses any pi OAuth authType. 07 §5's safe 'OpenAI (ChatGPT subscription)' flow in pi is therefore unreachable.
- Minor: the claude manifest declares the prompt maxBytes as null, but 01 §2 documents a 10 MB stdin cap. The route size guard never fires for claude profiles.

**Ideas to graft**

- A complete policy.json that mirrors 07 §5, including the opencode-go, copilot x opencode and chatgpt-plus-pro x opencode/pi rows.
- `credential.ref: login` plus `profile env <name>`, so the user can run a harness's own login in the isolated home.
- `downProfiles` and quotaGroup propagation of auth and quota failures.
- The `advisory-reviewer` and `utility` roles (read-only, non-authoritative), with familyRule strength per role (required / preferred / required-or-announce).
- A local profile that ships disabled, uses llama-server on port 9931, and carries a RAM-tier note.
- The `requiredFlags` --help check, plus an `appVersion` note in the fallback announcement.
- `task --profile auto --role R --writer W` for reviewer dispatches.
- `reportedMatch`, to catch silent model downgrades.

### D1-incremental

**Strengths**

- The fastest route to real value. Inc 0 is a no-behaviour-change extraction. Inc 1 delivers claude-compat, which alone reaches GLM, DeepSeek, Kimi, MiniMax, Qwen PAYG, OpenRouter and local servers. The user can say 'dispatch this to ds-pro' ad hoc before any orchestrator change. The MVP (Inc 0-2, about 2 weeks) puts multi-provider implementers into /dev with today's defaults intact.
- Honest throughout. The MiniMax M3.1 Flash template ships enabled:false because it has no benchmarks. local-qwen is disabled with 'not viable on a 16 GB M4'. The proposal acknowledges unmeasured model quality and recommends an A/B before reordering routing. It also lists T2 limits (localhost and network tests fail inside the sandbox), the support caveat, the Token Plan conflict resolved to `no`, and a clear never-build list with reasons.
- Its claude-compat T2 tier is grounded in a verified experiment (01 E13). The sandbox credentials deny plus SUBPROCESS_ENV_SCRUB gives a sandboxed implementer without installing srt, which raises safety at no setup cost to the user.
- Clear one-line-per-channel `profiles` output (tier, maxPrompt, resume, conc, state). A doctor example includes a billing-type check, and the LIVE step asks the user to confirm the dashboard billing type (plan vs standard key).
- A generic failure ladder in which every outcome is either an announced next channel or exactly one question. Host pinning per plan and a key-prefix blacklist (sk-sp-) prevent billing surprises.

**Fatal or major flaws**

- It defers three of the user's explicitly named items to 'on demand' Inc 5, behind srt: OpenCode (and with it the OpenCode subscription), pi with API keys, and DSH. The policy has no opencode-go or copilot plan rows, so those subscriptions are refused by default until Inc 5.
- 'Other roles' coverage is limited to plan and control reviewers (Inc 3) and risk via codex-provider (Inc 4). There are no utility or advisory roles, and 'no new roles' is a stated non-goal.
- Routing is harder to follow. Three dispatchers coexist ($ZDISPATCH, $DISPATCH, $ADISPATCH) with separate write reservations until a later shared lock root, and there are several overlapping kill switches (SP_AGENT_DISPATCH, SP_DISABLE_CHANNELS, SP_IMPLEMENTER, enabled:false, session phrases).
- Configuration means editing profiles.json and its routing block by hand after `profile add --from`. There is no guided setup or discovery.

**Ideas to graft**

- The delivery order: core extraction first, claude-compat second, with ad-hoc single-profile use before orchestrator integration.
- The claude-compat T2 settings: a Bash sandbox with failIfUnavailable, a credentials envVars deny, SUBPROCESS_ENV_SCRUB, deny rules on key dirs and .git, and empty allowedDomains. This gives a sandboxed default with no srt install.
- Shipping unbenchmarked or risky templates as enabled:false, each with a `note` explaining why.
- The `profiles` one-line summary per channel, including the built-in rows and the resolved routing line.
- Host pinning per plan, the key-prefix blacklist at `key set`, and the LIVE billing-type check against the provider dashboard.
- The per-profile env-key allowlist (API_TIMEOUT_MS, CLAUDE_CODE_MAX_CONTEXT_TOKENS, ...), so that ANTHROPIC_BASE_URL can never be overridden.

### D3-security

**Strengths**

- The most rigorous ToS and credential story. Login paths are closed by construction, the evidence text is printed in refusals and gray consent, every refusal code carries a `hint:` next step, and corpus conflicts are resolved conservatively and listed explicitly.
- Kill-switch tokens are expressive (family:, plan:, harness:, third-party), which lets a user switch off a whole provider or harness in one setting.
- The data-use policy is surfaced as doctor WARNs (DeepSeek PRC with no training promise; Codex sends the workspace path and git HEAD), so the user is told plainly what leaves the machine.
- The adapter refuses claude* model ids on non-Anthropic hosts (DeepSeek maps claude-opus to its own model), which keeps the family labels honest.

**Fatal or major flaws**

- Value arrives slowest of the four. Inc 1 (core, policy, L3) and Inc 2 (routing) add no provider, Inc 3 is the srt runner, the first third-party model arrives in Inc 4 (codex-exec), and claude -p, the path every named provider documents, comes only in Inc 5.
- It requires the user to install a 0.0.x beta (srt) before any non-Codex reviewer role can be used and for the example glm-claude and minimax-pi profiles. Reviewer roles demand OS read-only, so Kimi or Qwen as a cheap cross-family reviewer is out of reach until srt and canaries pass.
- It drops subscription paths the user asked about that 07 §5 lists as safe defaults. All OpenCode and pi login flows are refused ('keys only'), which includes Copilot in OpenCode and ChatGPT Plus/Pro in OpenCode or pi. The opencode-go plan is missing from tos-policy.json, so OpenCode Go is refused by default. Of the four, D3 answers 'OpenCode with its own subscription' worst.
- It conflicts with the user's low-ceremony preference. It keeps a canary tier cache keyed by harness and srt versions, and state-integrity hashes of channels.json, policy/, the plugin bin/ tree and the keys/ listing, guarded by a generation counter. A hash change is treated as a security event that asks the user a question, so legitimate changes (for example a plugin update during a job) risk false-positive stops.
- Local models get only a policy row and role exclusions, with no profile, discovery or hardware guidance. There is no utility or advisory role.

**Ideas to graft**

- One refusal-code table where every exit-2 line carries a `hint:` with the exact next step for the user.
- SP_DISABLE_CHANNELS tokens by family:, plan:, harness: and third-party.
- The adapter-level refusal of claude* model ids on non-Anthropic hosts.
- Doctor WARN lines for data use and jurisdiction (shown, never gated).
- codex-exec as the path for third-party models into SECURITY/DATA_LOSS phases, kept as an optional later tier rather than a prerequisite.

### Factual errors found in the proposals

- D2 §4.6 policy.json lists the GLM Coding Plan as ok only for zcode and claude-code, while 07 §2/§5 (ZA2) marks Codex, OpenCode and pi OK as well. It also lists no ok rows for kimi-platform, minimax-payg, alibaba-payg, openrouter or opencode-go, which 07 §5 lists as safe. Under D2's own deny-by-default rule, these ToS-safe pairs, including D2's own example profiles, would be refused.
- D2 treats opencode-go x dsh as a ToS `no` on the strength of OC1. 07 §2 marks that cell '?' and states that OC1's 'known problematic' label is a technical session-header issue, not a terms issue. Denying the pair is a defensible conservative choice, but presenting it as an evidence-backed `no` mischaracterizes the corpus.
- D2 says a local Ollama model on 16 GB is allowed in the `utility` role, which D2 defines as quickfix, verification gate, review synthesis and integration check. 08 §9 allows only a non-authoritative log summarizer on 16 GB, calls trivial implementer work an 'opt-in experiment', and rules advisory review out as too slow. D2 also omits 08 BL4: Ollama defaults to 4k context on machines with less than 24 GiB VRAM and silently drops messages.
- D4's claude manifest sets prompt maxBytes to null, but 01 §2 documents a 10 MB cap on piped stdin (01 fact-check: confirmed).
- D4's policy marks chatgpt-plus-pro x pi as ok, yet D4's pi adapter hard-refuses any OAuth authType. The 'OpenAI (ChatGPT subscription)' flow that 07 §3/§5 lists as OK for pi is therefore unreachable. This is an internal contradiction against the corpus verdict.
- D3's tos-policy omits the opencode-go plan and, through its 'keys only' never-build row, refuses OpenCode's Copilot and ChatGPT logins and pi's ChatGPT subscription flow. 07 §5 lists all of these as safe defaults. This is not a misquote, but D3's statement that these login flows must be closed misrepresents what the ToS matrix requires: only the Anthropic and Copilot-via-pi logins are no-go (07 §3).
