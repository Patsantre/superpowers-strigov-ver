# Implementer Prompt (GLM-5.3-Flash via ZCode · Codex Luna max · Codex Sol xhigh)

Use for every non-frontend implementer dispatch; the channel ladder in SKILL.md Step 3 picks the channel: GLM-5.3-Flash at `max` through Z.ai's ZCode CLI (default), Codex Luna max (availability fallback, kill switch), Codex Sol 6.1 xhigh (risk-marked SECURITY / DATA_LOSS phases, reasoning escalation). Luna always runs at `max`, Sol at `xhigh`. The templates below are the same on every channel; a GLM dispatch file additionally begins with the ZCode preamble, and a retry or channel switch adds the channel-switch notice.

## Invocation

GLM (default):

```bash
"$ZDISPATCH" task --background [--cwd <worktree-path>] [--resume-task zt-NNNN | --fresh] --prompt-file "$dir"/prompts/<op>-<phase>-r<N>.<seq>.glm.md
```

`$ZDISPATCH` is the `zcode-dispatch` wrapper — first `Read` `../zcode-invocation/SKILL.md` (manual-only; never through the Skill tool), then resolve it once per session. The wrapper pins the model (GLM-5.3-Flash at `max`); there are no `--model` / `--effort` flags. The dispatch file's first block is the ZCode preamble below. Fix rounds use `--resume-task <this phase's zt-id>`.

Codex — Luna (availability fallback) shown; for Sol (risk-marked phases, reasoning escalation) use `--model gpt-6.1-sol --effort xhigh` instead:

```bash
"$DISPATCH" task \
  --background \
  --write \
  --model gpt-6-luna \
  --effort max \
  [--cwd <worktree-path>] \
  [--resume-task task-NNNN | --fresh] \
  --prompt-file "$dir"/prompts/<op>-<phase>-r<N>.<seq>.<luna|sol>.md
```

`$DISPATCH` is the `codex-dispatch` wrapper — first `Read` `../codex-invocation/SKILL.md` (manual-only; never through the Skill tool), then resolve it once per session.

**Prompt files** (both dispatchers — SKILL.md Step 3, "Prompt files and the retry / channel-switch rule"): write the filled template once as the operation's body file `$dir/prompts/<op>-<phase>-r<N>.md` (`$dir = $(sdd-workspace <plan-file>)`; operations `implement`, `fix`, `gatefix`, `final-fix`, `repair`); every dispatch goes out as its own dispatch file `<same name>.<seq>.<glm|luna|sol>.md`, composed per operation type and dispatch kind; the dispatched id goes into the sidecar `<same name>.<seq>.<glm|luna|sol>.id`. Never inline multi-line text; prompts no longer live in the session scratchpad. For a parallel-track phase, add `--cwd <worktree-path>` so the implementer works in that track's worktree (and use the same `--cwd` on `status` / `result`), and run `sdd-workspace` inside the worktree.

Both templates take a `[REPORT_FILE]` placeholder — the implementer writes its full report there so the detail never transits your context. Resolve it once per phase as `$(sdd-workspace <plan-file>)/phase-<id>-report.md` and substitute the absolute path (`sdd-workspace` resolves the same way as `$DISPATCH` — see SKILL.md). For a parallel-track phase, run `sdd-workspace` inside the track's worktree so the report lands in that track's workspace. Fix rounds append to the same file — never mint a new report path for round 2+.

For follow-up rounds after the fused review (Step 4) and gate-fix rounds (Step 3.5), resume the implementer's own thread or session on the phase's channel: same flags plus `--resume-task <this phase's id>` (`zt-…` on `$ZDISPATCH`, `task-…` on `$DISPATCH` — ids never cross dispatchers), with the fix-round template below (it carries the authorized blockers; the thread already knows the plan and the phase). Addressed resume is safe even though the control reviewer ran in between — see `../codex-invocation/SKILL.md` / `../zcode-invocation/SKILL.md` "Resume semantics"; `Read` the relevant manual-only skill. Never `--resume-last`. The same id also serves `NEEDS_CONTEXT` re-dispatches in Step 3 and the Luna → Sol escalation, which resumes the Luna thread. When `zcode-invocation` records `GLM resume: disabled`, GLM follow-ups are FRESH dispatches instead (SKILL.md Step 3).

**Fresh fallback**: if a fix-type round cannot resume the implementer thread (phase implemented by a Claude subagent, id lost, stale job record forcing `--fresh`, a GLM ↔ Codex channel switch, a GLM → Sol escalation, or a wrapper-refused resume), the fix-round template's opening paragraph is **replaced** by the re-brief block from the template's "fresh fallback" note so the new session has full context; the channel-switch notice follows it whenever an earlier dispatch of the same operation exists. A first-round (`implement`) dispatch never carries the re-brief — it is self-contained; a retry or channel switch of it only adds the channel-switch notice after its opening paragraph.

Poll with Monitor using the terminal-only filter from `../codex-invocation/SKILL.md` (GLM: the same loop from `../zcode-invocation/SKILL.md`, `zt-` ids); `Read` the relevant manual-only skill. Fetch via `"$DISPATCH" result task-XXXX` or `"$ZDISPATCH" result zt-XXXX`.

## ZCode preamble (GLM dispatches only)

Prepend this block verbatim to **every** GLM dispatch file — first round, fix rounds, gate-fix rounds, `NEEDS_CONTEXT` follow-ups, the Step 5 wave and integration repair. Replace `[REPORT_FILE]` with the same absolute path the template uses. Never send it to Codex or Claude implementers.

```
## ZCode headless run — read this first

- This is a headless, non-interactive run. Nobody can answer questions. Do not ask. If something is unclear, stop and finish with the status token `NEEDS_CONTEXT` (first round) or `BLOCKED`, with the specific question in your final message.
- Do not invoke skills, plugins, dynamic workflows, sub-agents, browser or computer-use tools, or goal mode. Use only file reads, file edits and shell commands.
- No git operations that change history, refs or the index: no `git commit`, `git push`, `git branch`, `git checkout`, `git switch`, `git stash`, `git reset`, `git rebase`, `git add`. Read-only git (`git status`, `git diff`, `git log`, `git show`) is fine.
- Stay inside the repository root named below. Never read or write `~/.zcode`, `~/.ssh`, `~/.aws`, keychains, or any credential store, and never read `.env` files outside the repository.
- Network only for package installs the plan explicitly requires (for example an `npm install` / `pip install` of a dependency the plan names). No other downloads, no API calls.
- Write the full report to [REPORT_FILE] (create parent directories if needed). Your final message is at most 15 lines; line 1 is the bare status token and nothing else.
```

## Channel-switch notice (retries and channel switches)

Insert this block whenever a phase moves between channels or a channel retries after an infrastructure failure (Luna fallback, Sol escalation, `--fresh` retry). Placement is fixed by SKILL.md Step 3 ("Prompt files and the retry / channel-switch rule"): on an `implement` dispatch it follows the first-round template's opening paragraph and there is **no** re-brief (that block declares a fix round); on a FRESH fix-type dispatch the fresh-fallback re-brief keeps its role — it **replaces** the fix-round template's opening paragraph — and this notice follows it; on a thread resume neither block appears. Fill the angle-bracket choices with the previous attempt's channel, job id and status. For a `--fresh` retry on the same channel, the first sentence names the same model: "A previous run of this implementer (<GLM-5.3-Flash via ZCode | Codex Luna | Codex Sol>, job <zt-NNNN | task-NNNN>, status failed/<errorClass>) worked on this same task before you."

```
## Previous attempt

A previous run on another implementer (<GLM-5.3-Flash via ZCode | Codex Luna>, job <zt-NNNN | task-NNNN>, status <failed/<errorClass> | BLOCKED | review stall after round 3 | gate stall>) worked on this same task before you. It may have left uncommitted partial changes in the working tree and a report at [REPORT_FILE]. Before anything else: `git status --porcelain` and `git diff <base-sha>`; read [REPORT_FILE] if it exists (including every `## Fix round` section). Your task and its scope are exactly what the sections after this notice say — a fix round stays a fix round: fix only its AUTHORIZED_BLOCKERS and append to the same [REPORT_FILE] under the same `## Fix round <N>` heading. Keep partial work that falls inside that scope and matches the plan, redo what does not, and say in your report what you kept.
```

## First-round prompt template

```
You are implementing one phase of an approved plan. Follow it exactly — do not expand scope beyond the named phase.

## Approved plan (authoritative — read it)

Path: `<repo-root>/docs/plans/<slug>.md`

Read the entire file including YAML frontmatter. Your task: implement phase **`<id>`** only (scope: `<one-line scope from frontmatter>`). Do not touch files or functionality belonging to other phases.

## Context

- Repository root: [path — may be a git worktree when this phase runs as a parallel track; treat it as the entire universe and never touch paths outside it]
- Style / patterns to follow: [e.g., "match existing module X", "use repository's existing logger"]
- If `docs/ARCHI.md` exists, read it before exploring the source — it is the maintained architecture memory. If the plan's steps for your phase include updating it, do so; otherwise do not touch it.
- Other phases already done (for context, do not modify): [list of done phase ids + their commits, if any]
- Parallel track note (include only when applicable): another phase is being implemented concurrently in a separate worktree. Its files are NOT in your scope; if your phase seems to need changes in them, stop and report `BLOCKED` — do not improvise the other phase's side.

## Before you begin

If any of these are unclear, STOP and report status `NEEDS_CONTEXT` with a specific question:
- Requirements or acceptance criteria
- Approach, dependencies, or assumptions
- Anything ambiguous in the plan

Do not guess.

## Your job

1. Implement exactly what the plan specifies — nothing more.
2. Write tests that verify behavior (not that mirror the implementation).
3. Run tests / typecheck / linters; confirm they pass.
4. Self-review (see below) and fix issues before reporting.
5. Write your full report to [REPORT_FILE], then emit the short final message (see Report format below).

## Discipline

- **YAGNI**: build only what the plan asks for. No speculative abstractions, extra flags, or "nice to haves".
- **File responsibility**: follow the file layout from the plan. If a file grows beyond the plan's intent, stop and report `DONE_WITH_CONCERNS` — do not split files on your own.
- **Existing patterns**: match established conventions in the repo. Improve code you're touching, but do not restructure anything outside your task.
- **No unrelated commits**: do not modify files outside the plan's scope, even for "cleanups".
- **Git**: do NOT run `git commit`, `git push`, or any history-modifying git command — leave all changes uncommitted in the working tree. The orchestrator reviews the diff and handles git itself. (If the plan's last step says "Commit the phase", skip that step and note it in your report.)

## Self-review before reporting

- Completeness: every requirement implemented? edge cases?
- YAGNI: built anything not requested? remove it.
- Names: accurate (match what things do, not how)?
- Tests: prove behavior, or just mock-match the implementation?

Fix anything you find before reporting.

## Escalate when stuck

It is OK to stop and say "this is too hard." Bad work is worse than no work.

STOP and escalate (`BLOCKED`) when:
- The task needs architectural decisions with multiple valid approaches.
- You need codebase knowledge beyond what was provided and cannot derive clarity.
- You're reading file after file without progress.
- The plan itself appears wrong.

## Report format (strict)

Write your full report to [REPORT_FILE]:
- What you implemented (or what you attempted, if blocked)
- What you tested and test results (commands + output summary)
- TDD Evidence (if TDD was required for this phase):
  - RED: command run, relevant failing output before implementation, and why the failure was expected
  - GREEN: command run and relevant passing output after implementation
- Files changed (paths)
- Self-review findings (if any)
- Concerns / questions / blockers (if status ≠ DONE)

Then emit your final message with ONLY (under 15 lines — the detail lives in the report file). Line 1 is the bare status token — no preamble, no markdown formatting:

`DONE` | `DONE_WITH_CONCERNS` | `BLOCKED` | `NEEDS_CONTEXT`

Then:
- One-line test summary (e.g. "14/14 passing")
- Number of files changed (you do not commit — the diff stays in the working tree)
- Your concerns, if any
- The report file path

If BLOCKED or NEEDS_CONTEXT, put the specifics in the final message itself — the orchestrator acts on it directly.

Do NOT silently produce work you're unsure about — use `DONE_WITH_CONCERNS`.
```

## Fix-round prompt (round 2+ — `--resume-task <implementer-task-id>`)

```
You are in the fix round of a review loop, continuing the thread in which you implemented this phase. The fused review (Opus + Astra control) found blocking issues in your diff. Fix ONLY the AUTHORIZED_BLOCKERS below, re-test, re-report.

Re-inspect your current diff first — `git diff <base-sha>` plus `git status --porcelain` (files you CREATED are untracked, invisible to `git diff` against a commit — read them directly) — the tree may have moved since your last turn. Your report from the previous round is at [REPORT_FILE]; you will append your fix results to that same file.

## Git

Do NOT run `git commit` / `git push` / history-modifying git commands. Leave all changes uncommitted — the orchestrator handles git.

## AUTHORIZED_BLOCKERS

<paste open ACCEPTED / PARTIALLY_ACCEPTED ledger items inline; orchestrator pulls these from `<repo-root>/docs/plans/<slug>.ledger.json` — see dev-orchestrator/SKILL.md "## Authorized Change Ledger">

Format per item:

1. `<ledger id>` — `<reviewer: opus-review | codex-control>` — `<file:line>` — `<authorized change>`
2. ...

Items not in this list are NOT authorized — do not act on them, even if you remember them from a prior round.

## Fix-round scope

You are in a review/fix loop. This is NOT a new implementation pass.

You may only change code/tests/docs necessary to fix the AUTHORIZED_BLOCKERS above.

Forbidden without explicit authorization:

- fixing NITs;
- opportunistic cleanup or refactors;
- broad consistency passes;
- adding new guards / flags / diagnostics / dependencies / tests not required by an authorized blocker;
- touching files outside the phase plan unless the blocker cannot be fixed otherwise.

If a blocker requires broader scope than the ledger lists, stop and return:
`NEEDS_AUTHORIZATION: <ledger id> requires <extra change> because <reason>`
so the orchestrator can extend the ledger before you continue.

## Required output

First, append a section `## Fix round <N>` to [REPORT_FILE] (the same report file — do not overwrite it, do not create a new one). N is the number of the fused-review round whose blockers you are fixing — the first fix round writes `## Fix round 1`. The section must contain ALL THREE of:

1. The names of the tests covering each fixed blocker
2. The exact test command(s) you ran
3. The relevant output

All three are mandatory — a fix-round report missing any of them is returned to you before re-review. Reviewers will not re-run the full suite for you — your report is the test evidence.

Then emit your final message with ONLY (under 15 lines — the detail lives in the report file). Line 1 is the bare status token — no preamble, no markdown formatting:

`DONE` | `DONE_WITH_CONCERNS` | `NEEDS_AUTHORIZATION` | `BLOCKED`

Then emit the structured fields:

- `blockers_fixed: [<ledger ids>]`
- `files_changed_by_blocker:`
  - `<ledger id>: [<file paths>]`
- `unauthorized_changes: []`   — MUST be empty; if not empty, each entry MUST explain why the change was unavoidable
- `nits_applied: false`        — MUST be `false` unless the orchestrator explicitly authorized a NIT in the ledger
- One-line test summary (e.g. "3/3 covering tests passing")
- Concerns / questions / remaining ledger items not yet fixed (if status ≠ `DONE`)
- The report file path

If NEEDS_AUTHORIZATION or BLOCKED, put the specifics in the final message itself — the orchestrator acts on it directly.

Re-run the tests that cover the amended code after fixes. Every change in the diff must trace back either to an entry in AUTHORIZED_BLOCKERS or to `unauthorized_changes` (with justification).
```

**Fresh fallback re-brief block** — when the fix round cannot resume the implementer thread (phase implemented by a Claude subagent, id lost, stale job record forcing `--fresh`, a GLM ↔ Codex channel switch, a GLM → Sol escalation, or a wrapper-refused resume), replace the opening paragraph above with:

```
You are in the fix round of a review loop. A previous run implemented one phase of an approved plan; the fused review (Opus + Astra control) found blocking issues. You are a fresh session with no memory of that run — re-read the context below, then fix ONLY the AUTHORIZED_BLOCKERS, re-test, re-report.

## Plan + phase (authoritative — read it)

Path: `<repo-root>/docs/plans/<slug>.md`. Your phase: **`<id>`** (scope: `<one-line scope from frontmatter>`). The phase's implementation is the un-committed diff in the working tree — inspect it via `git diff <base-sha>` plus `git status --porcelain`: files the previous round CREATED are untracked and invisible to `git diff` against a commit — read them directly. The previous round's full report is at [REPORT_FILE] — read it to see what was implemented and tested; you will append your fix results to that same file.
```

## Step 5 fix wave (adapting the fix-round template)

When the orchestrator dispatches the final-review fix wave (SKILL.md Step 5) — on the channel Step 5 picks (GLM, Luna or Sol; a GLM dispatch file begins with the ZCode preamble) — the fix-round template above is reused as a **FRESH task with the fresh-fallback re-brief** (the whole-plan fix wave has no single implementer thread to resume), with these substitutions:

- **Scope** is the WHOLE plan, not one phase: fill "Your phase" with `the whole plan (Step 5 final-review fix wave)` and drop the phase-scope line.
- **Base** is MERGE_BASE (the branch start), and the implementation is COMMITTED — inspect it via `git diff <merge-base-sha>..HEAD`, not an uncommitted worktree diff.
- **AUTHORIZED_BLOCKERS reviewer values** may also be `opus-final` (Step 5 findings), in addition to `opus-review | codex-control`.
- **[REPORT_FILE]** = `$dir/final-fix-report.md` and does not exist yet — create it fresh and skip "read the previous round's report"; write your fix results as `## Fix round 1`.
