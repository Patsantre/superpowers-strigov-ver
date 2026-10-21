#!/usr/bin/env bash
# Static checks that the pipeline keeps its built-in defaults after the
# universal-dispatchers rework: with no config.json the orchestrator must run
# exactly as before — same models and efforts per role, same $ZDISPATCH /
# $DISPATCH command lines and flags, same GLM failure classes, same caps,
# family rule, markers and kill-switch phrases.
#
# Every expected value below is hardcoded from commit df96a8a, the last commit
# before the skills were generalized. When git can see that commit, the test
# also checks that each expectation really is present there (so a typo in this
# file fails loudly instead of passing vacuously).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_REV=df96a8a
ORCH=skills/dev-orchestrator/SKILL.md

FAILURES=0
pass() { echo "  [PASS] $1"; }
fail() {
    echo "  [FAIL] $1"
    FAILURES=$((FAILURES + 1))
}

HAVE_BASE=0
if git -C "$REPO_ROOT" cat-file -e "$BASE_REV^{commit}" 2>/dev/null; then
    HAVE_BASE=1
fi

# count_of <haystack> <needle> — number of non-overlapping occurrences of a
# single-line needle (grep -o prints each match on its own line).
count_of() {
    local n
    n=$({ grep -oF -- "$2" <<<"$1" || true; } | wc -l)
    echo $((n))
}

current() { cat "$REPO_ROOT/$1"; }
at_base() { git -C "$REPO_ROOT" show "$BASE_REV:$1" 2>/dev/null || true; }

# expect_text <file> <needle> <description> — needle present now (and at base).
expect_text() {
    local file=$1 needle=$2 desc=$3 now
    now="$(current "$file")"
    if [[ "$now" == *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc — missing from $file: $needle"
    fi
    if [[ $HAVE_BASE == 1 ]]; then
        local base
        base="$(at_base "$file")"
        if [[ "$base" != *"$needle"* ]]; then
            fail "self-check: expectation not found in $BASE_REV:$file: $needle"
        fi
    fi
}

# expect_count <file> <needle> <min> <description> [exact] — at least <min>
# occurrences (the count at df96a8a), so no built-in command line was dropped;
# with "exact", exactly <min>, so a copy added later cannot hide a changed
# original (bump the number on purpose when a line is added).
expect_count() {
    local file=$1 needle=$2 min=$3 desc=$4 mode=${5:-min} n
    n="$(count_of "$(current "$file")" "$needle")"
    if [[ $mode == exact ]]; then
        if (( n == min )); then
            pass "$desc ($n == $min)"
        else
            fail "$desc — $file has $n occurrence(s) of $needle, expected exactly $min"
        fi
    elif (( n >= min )); then
        pass "$desc ($n >= $min)"
    else
        fail "$desc — $file has $n occurrence(s) of $needle, expected at least $min"
    fi
    if [[ $HAVE_BASE == 1 ]]; then
        local b
        b="$(count_of "$(at_base "$file")" "$needle")"
        if [[ "$b" != "$min" ]]; then
            fail "self-check: $BASE_REV:$file has $b occurrence(s) of $needle, the test hardcodes $min"
        fi
    fi
}

# expect_row <label> <step> <model cell> — the Model split row with this label
# still has this step and this model · effort cell (a `route` role column may
# sit between label and step).
expect_row() {
    local label=$1 step=$2 model=$3 line found=0
    while IFS= read -r line; do
        if [[ "$line" == "| $label | "* && "$line" == *" | $step | $model |" ]]; then
            found=1
            break
        fi
    done < "$REPO_ROOT/$ORCH"
    if [[ $found == 1 ]]; then
        pass "Model split: $label"
    else
        fail "Model split row changed: $label (want step '$step', model '$model')"
    fi
    if [[ $HAVE_BASE == 1 ]]; then
        local base
        base="$(at_base "$ORCH")"
        if [[ "$base" != *"| $label | $step | $model |"* ]]; then
            fail "self-check: row not found in $BASE_REV:$ORCH: $label"
        fi
    fi
}

# expect_new <file> <needle> <description> — a rule written after df96a8a to
# keep the no-config behaviour of df96a8a (no self-check against the base).
expect_new() {
    local file=$1 needle=$2 desc=$3
    if [[ "$(current "$file")" == *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc — missing from $file: $needle"
    fi
}

# expect_new_count <file> <needle> <n> <description> — exactly <n> occurrences
# of a rule written after df96a8a.
expect_new_count() {
    local file=$1 needle=$2 want=$3 desc=$4 n
    n="$(count_of "$(current "$file")" "$needle")"
    if (( n == want )); then
        pass "$desc ($n == $want)"
    else
        fail "$desc — $file has $n occurrence(s) of $needle, expected exactly $want"
    fi
}

# expect_absent <file> <needle> <description> — a wording that changed the
# no-config pipeline must not come back.
expect_absent() {
    local file=$1 needle=$2 desc=$3
    if [[ "$(current "$file")" == *"$needle"* ]]; then
        fail "$desc — $file still contains: $needle"
    else
        pass "$desc"
    fi
}

echo "Model split — every role keeps its built-in model and effort"
expect_row 'Main thread (orchestrator)' 'all' 'Sonnet · `medium` (intended default — the rules hold whatever model the user runs)'
expect_row 'Plan writer' '1' 'Claude `opus` · `xhigh`'
expect_row 'Plan reviser — Mode B revisions, pre-flight edits, sub-phase splits, legacy frontmatter retrofit' '2, 2.5, 3' 'Claude `opus` · `high`'
expect_row 'Plan reviewer' '2' 'Codex `gpt-6-astra` · `xhigh`'
expect_row 'Implementer — phases, fix rounds, gate-fix rounds, Step 5 fix wave, integration repair' '3, 3.5, 4, 5' '**GLM `GLM-5.3-Flash` · `max` via `$ZDISPATCH`** (ZCode CLI)'
expect_row 'Implementer of SECURITY / DATA_LOSS phases (risk-marked, Step 2.5)' '3, 3.5, 4, 5' 'Codex `gpt-6.1-sol` · `xhigh` · `--write`'
expect_row 'Availability fallback (GLM channel down or failed, kill switch)' '3, 3.5, 4, 5' 'Codex `gpt-6-luna` · `max` · `--write` — the **same operation** re-dispatched FRESH in the Step 3 composition for its operation type (channel-switch notice; re-brief only on fix-type operations), **announced**'
expect_row 'Reasoning escalation (BLOCKED + "needs more reasoning"; fused-review round 3 still BLOCKING; gate diagnosis `CODE`) — on GLM **and** Luna phases' '3, 3.5, 4' 'Codex `gpt-6.1-sol` · `xhigh` · `--write` — GLM phase: FRESH, composed per the Step 3 rules for the operation type (`implement`: first-round body + notice, no re-brief; fix-type: re-brief opening + notice + body); Luna phase: `--resume-task` of the Luna thread. From then on Sol is the phase'"'"'s channel; on a phase already on Sol these points go to the user.'
expect_row 'Frontend implementer' '3' 'Claude `opus` · `high` (new UI / redesign); Claude `sonnet` · `medium` (simple tweaks)'
expect_row 'Verification gate' '3.5' 'Claude `sonnet` · `medium`'
expect_row 'Primary review' '4.1' 'Claude `opus` · `high`; `xhigh` when the phase is risk-marked (`risk_phases`, Step 2.5) or in round 4 (the last round before the cap)'
expect_row 'Control review' '4.2' 'Codex `gpt-6-astra` · `high`'
expect_row 'Review synthesis' '4.5' 'Claude `sonnet` · `medium`'
expect_row 'Final whole-branch review' '5' 'Claude `opus` · `xhigh`; Opus unavailable → Codex `gpt-6-astra` · `xhigh`, announced'
expect_row 'Diagnosis (BLOCKED, gate stall) and impasse summaries' '3, 3.5, escalations' 'Claude `opus` · `high`'
expect_row 'Quickfix' 'trivial path' 'Claude `sonnet` · `medium`'
expect_row 'Integration check' 'parallel groups' 'Claude `sonnet` · `medium`'

echo ""
echo "dev-orchestrator — built-in \$ZDISPATCH command lines"
expect_text "$ORCH" '`"$ZDISPATCH" task --background --prompt-file "$dir"/prompts/<op>-<phase>-r<N>.<seq>.glm.md`' 'GLM implement dispatch'
expect_text "$ORCH" '`"$ZDISPATCH" task --background --fresh --prompt-file "$dir"/prompts/<name>.<seq>.glm.md`' 'GLM --fresh retry'
expect_text "$ORCH" '`"$ZDISPATCH" task --background [--cwd …] --resume-task <zt-id> --prompt-file "$dir"/prompts/fix-<id>-r<N>.<seq>.glm.md`' 'GLM fix round resume'
expect_text "$ORCH" '`"$ZDISPATCH" task --background --resume-task <zt-id> --prompt-file "$dir"/prompts/gatefix-<id>-r<N>.<seq>.glm.md`' 'GLM gate-fix resume'
expect_text "$ORCH" '`"$ZDISPATCH" task --background --resume-task <that job'"'"'s zt-id>`' 'GLM malformed-output resume'
expect_text "$ORCH" '`"$ZDISPATCH" status <zt-id> --json | python3 -c "import json,sys; print(json.load(sys.stdin)['"'"'job'"'"']['"'"'errorClass'"'"'])"`' 'GLM error-class read'
expect_count "$ORCH" '"$ZDISPATCH" task --background' 8 'GLM task lines kept' exact
expect_count "$ORCH" '"$ZDISPATCH" doctor --probe' 5 'GLM probe lines kept' exact
expect_count "$ORCH" '"$ZDISPATCH" release-stale' 3 'GLM release-stale lines kept' exact
expect_count "$ORCH" '"$ZDISPATCH" status' 9 'GLM status lines kept'
expect_count "$ORCH" '--resume-task <zt-id>' 6 'GLM resume ids kept' exact
expect_count "$ORCH" '.glm.md' 8 'GLM dispatch-file names kept' exact

echo ""
echo "dev-orchestrator — built-in Codex flags"
expect_count "$ORCH" '--write --model gpt-6-luna --effort max' 2 'Luna max --write' exact
expect_count "$ORCH" '--model gpt-6-luna --effort max' 3 'Luna max' exact
expect_count "$ORCH" '--write --model gpt-6.1-sol --effort xhigh' 5 'Sol xhigh --write' exact
expect_count "$ORCH" '--model gpt-6.1-sol --effort xhigh' 6 'Sol xhigh' exact
expect_count "$ORCH" '--model gpt-6-astra --effort xhigh' 2 'Astra xhigh' exact
expect_count "$ORCH" '--model gpt-6-astra --effort high' 2 'Astra high' exact
expect_count "$ORCH" '"$DISPATCH" task' 2 'Codex task lines kept' exact
expect_count "$ORCH" '"$DISPATCH" status' 7 'Codex status lines kept'
expect_text "$ORCH" '`--write --model gpt-6-luna --effort max --resume-task <task-id>`' 'Luna resume flags'
expect_text "$ORCH" '`--write --model gpt-6.1-sol --effort xhigh --resume-task <task-id>`' 'Sol resume flags'

echo ""
echo "dev-orchestrator — failure classes, caps, family rule, markers, kill switch"
expect_text "$ORCH" 'errorClass ∈ {quota, auth, model-not-selected}' 'GLM non-retryable classes'
expect_text "$ORCH" 'errorClass ∈ {timeout, crash, launch, malformed}` → ONE retry of the same operation on GLM' 'GLM transient classes: one retry'
expect_text "$ORCH" '(`<n>` is 204800 on macOS, 122880 on Linux' 'MAX_PROMPT_BYTES values'
expect_text "$ORCH" 'when `zcode-invocation` records `GLM concurrency: 1` (two ZCode processes cannot run at once), a group runs at most **one** GLM track' 'GLM concurrency rule'
expect_text "$ORCH" 'Cap 2 repair rounds, then escalate.' 'integration-repair cap'
expect_text "$ORCH" '### Step 2 — Codex Astra xhigh reviews the plan (loop, cap=4)' 'plan review cap=4'
expect_text "$ORCH" '### Step 4 — Fused review (Opus + Astra control, cap=4)' 'fused review cap=4'
expect_text "$ORCH" '### Step 5 — Final whole-branch review (once per plan, cap=2)' 'final review cap=2'
expect_text "$ORCH" 'round 5 (cap=4 exhausted)' 'fused loop exhaustion'
expect_text "$ORCH" 'Loop past cap=4 (Step 5: cap=2) without escalating.' 'Red Flag on caps'
expect_text "$ORCH" 'Step 4 hit cap=4 without both-clean' 'pause on fused cap'
expect_text "$ORCH" 'Step 5 hit cap=2 still blocking' 'pause on final cap'
expect_text "$ORCH" 'writer and reviewer of the same artifact are never from the same model family.' 'family rule'
expect_text "$ORCH" 'one line `<ok|down|off> <reason> <ISO time>`' 'glm-channel marker format'
expect_text "$ORCH" '"через Luna" or "без GLM"' 'kill-switch phrases'
expect_text "$ORCH" 'Luna always runs at `max`' 'Luna effort pin'

echo ""
echo "Prompt files — built-in dispatch blocks"
IMPL=skills/dev-orchestrator/implementer-prompt.md
expect_text "$IMPL" '"$ZDISPATCH" task --background [--cwd <worktree-path>] [--resume-task zt-NNNN | --fresh] --prompt-file "$dir"/prompts/<op>-<phase>-r<N>.<seq>.glm.md' 'implementer: GLM command'
expect_text "$IMPL" '"$DISPATCH" task \
  --background \
  --write \
  --model gpt-6-luna \
  --effort max \
  [--cwd <worktree-path>] \
  [--resume-task task-NNNN | --fresh] \
  --prompt-file "$dir"/prompts/<op>-<phase>-r<N>.<seq>.<luna|sol>.md' 'implementer: Luna command'
expect_text "$IMPL" 'for Sol (risk-marked phases, reasoning escalation) use `--model gpt-6.1-sol --effort xhigh` instead' 'implementer: Sol flags'
expect_text "$IMPL" '## ZCode headless run — read this first

- This is a headless, non-interactive run. Nobody can answer questions. Do not ask. If something is unclear, stop and finish with the status token `NEEDS_CONTEXT` (first round) or `BLOCKED`, with the specific question in your final message.
- Do not invoke skills, plugins, dynamic workflows, sub-agents, browser or computer-use tools, or goal mode. Use only file reads, file edits and shell commands.
- No git operations that change history, refs or the index: no `git commit`, `git push`, `git branch`, `git checkout`, `git switch`, `git stash`, `git reset`, `git rebase`, `git add`. Read-only git (`git status`, `git diff`, `git log`, `git show`) is fine.
- Stay inside the repository root named below. Never read or write `~/.zcode`, `~/.ssh`, `~/.aws`, keychains, or any credential store, and never read `.env` files outside the repository.
- Network only for package installs the plan explicitly requires (for example an `npm install` / `pip install` of a dependency the plan names). No other downloads, no API calls.
- Write the full report to [REPORT_FILE] (create parent directories if needed). Your final message is at most 15 lines; line 1 is the bare status token and nothing else.' 'implementer: ZCode preamble verbatim'
expect_text skills/dev-orchestrator/codex-plan-reviewer-prompt.md '"$DISPATCH" task \
  --background \
  --model gpt-6-astra \
  --effort xhigh \
  --prompt-file <scratch>/plan-review-<slug>-r<k>.md' 'plan reviewer: Astra xhigh command'
expect_text skills/dev-orchestrator/codex-control-review-prompt.md '"$DISPATCH" task \
  --background \
  --model gpt-6-astra \
  --effort high \
  [--cwd <worktree-path>] \
  --prompt-file <scratch>/control-review.md' 'control review: Astra high command'
expect_text skills/dev-orchestrator/final-review-prompt.md '`"$DISPATCH" task --background --model gpt-6-astra --effort xhigh --prompt-file <scratch>/final-review-r<k>.md`' 'final review: Astra xhigh fallback command'
expect_text skills/brainstorming/spec-reviewer-prompt.md '"$DISPATCH" task \
  --background \
  --model gpt-6-astra \
  --effort xhigh \
  --prompt-file <scratch>/spec-review.md' 'spec reviewer: Astra xhigh command'
expect_text skills/brainstorming/SKILL.md '`--model gpt-6-astra --effort xhigh`' 'brainstorming: Astra xhigh flags'
expect_text skills/writing-plans/SKILL.md '--model gpt-6-astra --effort xhigh' 'writing-plans: Astra xhigh flags'
expect_text skills/requesting-code-review/SKILL.md '`--model gpt-6-astra --effort high`, no `--write`' 'requesting-code-review: Astra high flags'
expect_text skills/systematic-debugging/SKILL.md '`--model gpt-6-astra --effort high`, no `--write`, no `--resume-last`, cap=1' 'systematic-debugging: Astra high flags'

# Scenario pins: the transitions the review of f6332f1 found changed with no
# config.json. Each pins the rule sentence that keeps df96a8a's behaviour.
echo ""
echo "Scenario pins — no-config transitions stay as at $BASE_REV"
# 1. Frontend phases never escalate to implementer.escalation (Sol).
expect_text "$ORCH" 'For a frontend-only phase, dispatch the Claude frontend implementer'"'"'s follow-up template instead (fresh Agent call, same ledger-derived list, same `[REPORT_FILE]` rules) — never GLM or Codex.' 'frontend fix rounds stay with the Claude frontend implementer'
expect_text "$ORCH" 'Claude path: upgrade from Sonnet `medium` to Opus `high`; if already Opus, hand back to user.' 'frontend BLOCKED: Sonnet → Opus upgrade, then the user'
expect_text "$ORCH" '**Frontend-only phases** keep the old cap: 2 consecutive gate-fix rounds without `GATE_OK` → escalate to the user' 'frontend gate stall: the user, no diagnosis escalation'
expect_new "$ORCH" '5. **Escalation** — non-frontend phases only' 'Routing item 5 is limited to non-frontend phases'
expect_new "$ORCH" 'A frontend-only phase never escalates here: its fixes stay with the Claude frontend implementer' 'Routing item 5 names the frontend exception'
expect_new "$ORCH" '**Review stall (non-frontend phases not yet on an escalation profile — built-in: GLM and Luna phases):**' 'review stall escalation only on non-frontend phases'
expect_new "$ORCH" 'A frontend-only phase has no review-stall escalation: its fix rounds stay with the Claude frontend implementer up to the round cap.' 'frontend review stall: fix rounds up to the cap'
expect_absent "$ORCH" 'any phase not yet on an escalation profile' 'no review-stall escalation for "any phase"'
# 2. A switch follows the chain the ladder selected: under the kill switch never implementer.risk.
expect_new "$ORCH" 'An implementer switches only inside the **phase'"'"'s chain** — the one the ladder actually selected, re-derived each time from inputs that survive compaction (kill switch, `risk_phases`, the highest-seq sidecar'"'"'s profile)' 'switches follow the phase'"'"'s derived chain'
expect_new "$ORCH" '"через Luna" / an `SP_IMPLEMENTER` profile: that profile alone (never `implementer.risk`, even on a risk-marked phase)' 'kill switch: the named profile alone'
expect_new "$ORCH" 'Luna, Sol and Astra stand last — a failed Codex job plus one `--fresh` retry → the user, never an implicit Luna → Sol hop.' 'built-in Codex channels: retry once, then the user'
expect_absent "$ORCH" 'A kill-switch profile outside the chain stands before all of it' 'no kill-switch profile prepended to the risk chain'
expect_new "$ORCH" 'then the next profile of the phase'"'"'s chain ("## Routing" item 4 — the chain the ladder selected, never `implementer.risk` under the kill switch)' 'Codex failure rule: never implementer.risk under the kill switch'
# 3. SP_IMPLEMENTER: with no config.json only luna activates the kill switch (df96a8a: "no other values of
#    SP_IMPLEMENTER"), silently ignoring the rest; a config.json profile opts in. The same rule in recovery.
expect_new "$ORCH" 'empty or `glm` → no kill switch; `luna` → the kill switch, as always; the name of a profile that the user'"'"'s `config.json` defines (a `source=config` row of `"$AD" channels`) whose harness is not `inproc` → the kill switch on that profile for every non-frontend phase' 'SP_IMPLEMENTER rule: empty/glm, luna, a config.json profile outside the session'
expect_new "$ORCH" 'any other value — a built-in profile other than `luna` (`sol`, `astra`, …), an unknown name, an `inproc` profile, garbage, or `$AD` not running — is ignored, as before 0.12.0: no kill switch, GLM stays.' 'SP_IMPLEMENTER rule: built-in sol/astra and any other value are ignored'
expect_new "$ORCH" 'Silently when `"$AD" channels` lists no `source=config` profile or `$AD` does not run (no `config.json`: exactly as before); otherwise one announcement line at skill start, never repeated after compaction.' 'SP_IMPLEMENTER rule: silent without config.json, never re-announced after compaction'
expect_new "$ORCH" '`SP_IMPLEMENTER=<p>` (a `config.json` profile — the rule below) → profile `p`' 'ladder item 1: SP_IMPLEMENTER=<p> only for a config.json profile'
expect_new "$ORCH" '`echo "${SP_IMPLEMENTER:-}"`, and the `SP_IMPLEMENTER` rule (Step 3 "Kill switch") activates the kill switch → `off`' 'compaction recovery applies the SP_IMPLEMENTER rule'
expect_new "$ORCH" 'at skill start, `echo "${SP_IMPLEMENTER:-}"` → the `SP_IMPLEMENTER` rule' 'skill start applies the SP_IMPLEMENTER rule'
expect_absent "$ORCH" 'the name of a known profile other than `luna` / `glm` whose harness is not `inproc`' 'built-in sol/astra do not activate the kill switch'
expect_absent "$ORCH" 'built-in or `config.json`, as `"$AD" channels` lists it' 'no built-in profile names the SP_IMPLEMENTER implementer'
expect_absent "$ORCH" 'one announcement line at skill start, no kill switch, GLM stays.' 'no unconditional announcement for an ignored SP_IMPLEMENTER'
expect_absent "$ORCH" 'non-empty value other than `glm`' 'no kill switch for every non-empty SP_IMPLEMENTER'
expect_absent "$ORCH" 'non-empty `SP_IMPLEMENTER` other than `glm`' 'Durable copies: no off re-write for every non-empty SP_IMPLEMENTER'
expect_absent "$ORCH" '`SP_IMPLEMENTER` is non-empty and not `glm`' 'ladder item 1 does not fire on any non-empty SP_IMPLEMENTER'
expect_absent skills/zcode-invocation/SKILL.md 'non-empty `SP_IMPLEMENTER` other than `glm`' 'zcode-invocation: same SP_IMPLEMENTER rule'
expect_absent skills/zcode-invocation/SKILL.md 'another known profile whose harness is not `inproc`' 'zcode-invocation: no built-in profile activates the kill switch'
expect_new skills/zcode-invocation/SKILL.md 'the name of a profile the user'"'"'s agent-dispatch `config.json` defines whose harness is not `inproc`' 'zcode-invocation: a config.json profile opts in'
expect_absent PLUGIN_README.md 'any non-empty value other than `glm`' 'PLUGIN_README: no kill switch for every non-empty SP_IMPLEMENTER'
expect_absent PLUGIN_README.md 'another known profile' 'PLUGIN_README: no built-in profile activates the kill switch'
expect_new PLUGIN_README.md '(`luna`, or a profile of the user'"'"'s agent-dispatch `config.json` that does not run in the session; other values are ignored, as before;' 'PLUGIN_README: luna or a config.json profile'
expect_absent README.md 'makes that profile the implementer for every phase.' 'README: SP_IMPLEMENTER is not the implementer for every phase'
expect_absent README.md 'built-in or yours' 'README: no built-in profile activates the kill switch'
expect_new README.md '`SP_IMPLEMENTER=<profile>`, where the profile is one you defined in `config.json` and it runs outside the session' 'README: a config.json profile opts in'
expect_new README.md 'Any other value is ignored, as before: a built-in name such as `sol`' 'README: built-in sol is ignored'
expect_absent README.ru.md 'делает этот профиль имплементером для всех фаз.' 'README.ru: SP_IMPLEMENTER is not the implementer for every phase'
expect_absent README.ru.md 'встроенным или вашим' 'README.ru: no built-in profile activates the kill switch'
expect_new README.ru.md '`SP_IMPLEMENTER=<профиль>` с профилем, который вы сами задали в `config.json`' 'README.ru: a config.json profile opts in'
expect_new README.ru.md 'Любое другое значение, как и раньше, игнорируется: встроенное имя вроде `sol`' 'README.ru: built-in sol is ignored'
# 4. The GLM doctor/probe runs only for a glm candidate.
expect_new "$ORCH" 'When the state line still shows `glm=unprobed` and the candidate — item 5'"'"'s profile, the first non-down profile of the `implementer` chain (built-in: `glm`) — is `glm`, run item 4 above now' 'ladder item 3 probes only a glm candidate'
expect_new "$ORCH" '(only when the ladder'"'"'s candidate at item 3 is `glm` with `glm=unprobed`, or a route answers `glm` while `glm=unprobed`; a chain without `glm` never probes GLM)' 'Step 3 probe condition'
expect_new_count "$ORCH" 'the candidate — the first non-down `implementer` profile — is `glm` (built-in: it is; a chain without `glm` never probes GLM)' 2 'Step 5 fix wave and integration repair probe only a glm candidate'
# 6. In-session roles: in-session profiles first; route --all compares effective chains.
expect_new "$ORCH" '`"final-review": ["astra"]` alone prints `routes: default` plus a stderr note' 'route --all compares effective chains (SKILL.md)'
expect_new skills/agent-invocation/SKILL.md '`"final-review": ["astra"]` alone prints `routes: default` plus a stderr note' 'route --all compares effective chains (agent-invocation)'
expect_absent skills/agent-invocation/SKILL.md 'is not filtered' 'agent-invocation: no unrestricted final-review order'
expect_absent README.md 'its chain runs in order' 'README: no unrestricted final-review order'
expect_absent README.ru.md 'его цепочка идёт по порядку' 'README.ru: no unrestricted final-review order'
expect_new skills/agent-invocation/SKILL.md 'A chain whose order this changes gets one note line on stderr' 'agent-invocation: the note comes with every reordered final-review chain'
expect_absent skills/agent-invocation/SKILL.md 'A chain that does not start in-session gets one note line' 'agent-invocation: no note promise narrower than the CLI'
# 5. Merged status lists what the wrappers' own status lists (df96a8a ran "$DISPATCH" status and "$ZDISPATCH" status).
expect_new skills/agent-invocation/SKILL.md 'The ZCode and Codex lines are what that wrapper'"'"'s own `status` lists (Codex: only this session'"'"'s jobs while `$CODEX_COMPANION_SESSION_ID` is set).' 'agent-invocation: merged status keeps the wrappers'"'"' session scope'
# Under routes: default no route call and the built-in announcements, word for word.
expect_text "$ORCH" 'use the template'"'"'s Codex Astra xhigh fallback' 'Step 5: Opus unavailable → the Astra xhigh fallback'
expect_new "$ORCH" 'under `routes: default` (no `route` call — "## Routing" item 1), use the template'"'"'s Codex Astra xhigh fallback' 'Step 5 fallback: no route call under routes: default'
expect_new skills/dev-orchestrator/codex-plan-reviewer-prompt.md 'skipped under `routes: default`' 'plan-reviewer template: no route call under routes: default'
expect_new skills/dev-orchestrator/codex-control-review-prompt.md 'skipped under `routes: default`' 'control-review template: no route call under routes: default'
expect_new skills/dev-orchestrator/final-review-prompt.md '(under `routes: default` no call' 'final-review template: no route call under routes: default'
expect_text "$ORCH" '`ZCode doctor failed (<first FAIL line>) — implementer for this session: Luna max.`' 'failed doctor: the built-in announcement'
expect_text "$ORCH" '`GLM channel failed (errorClass=<class>) — Ф<id> falls back to Luna max; GLM is off for this session.`' 'GLM job down: the built-in announcement'
expect_absent "$ORCH" '<next implementer profile; built-in Luna max>' 'no profile-name placeholder in the doctor announcement'
expect_absent "$ORCH" 'falls back to <profile> (built-in: Luna max)' 'no profile-name placeholder in the GLM-down announcement'
expect_new "$ORCH" 'between built-in profiles, word for word the built-in line of "## Reporting cadence"' 'built-in switches: the old line, no Channel line beside it'
# "без <profile>": GLM keeps its own kill switch; any other profile is a switch only with the user's own routing.
expect_new "$ORCH" '("без GLM" is the GLM kill switch above and writes no `channels` line)' '"без GLM" writes no channels line'
expect_new "$ORCH" 'only when `route --all` did not print `routes: default`' '"без <profile>" needs the user'"'"'s own routing'
expect_new "$ORCH" 'Under `routes: default` no such switch exists, as before 0.12.0.' 'no "без <profile>" switch under routes: default'
expect_new "$ORCH" 'are skipped for the session: the Model split table' 'Routing item 1: the routes: default shortcut holds for the session'

echo ""
echo "Documented route examples (bin/agent-dispatch)"
if command -v node >/dev/null 2>&1 && [[ -x "$REPO_ROOT/bin/agent-dispatch" ]]; then
    ex_dir="$(mktemp -d)"
    # HOME in the temp dir: the launcher would prefer an installed marketplace copy under the real HOME.
    ex_out="$(HOME="$ex_dir" AGENT_DISPATCH_STATE_DIR="$ex_dir" "$REPO_ROOT/bin/agent-dispatch" route --all 2>"$ex_dir/stderr")" && ex_rc=0 || ex_rc=$?
    ex_err="$(cat "$ex_dir/stderr")"
    if [[ $ex_rc -eq 0 && "$ex_out" == "routes: default" && -z "$ex_err" ]]; then
        pass 'no config.json → route --all prints exactly routes: default (the per-dispatch route calls are skipped)'
    else
        fail "no config.json → route --all: rc=$ex_rc out: $ex_out err: $ex_err"
    fi
    printf '%s\n' '{ "version": 1, "roles": { "final-review": ["astra"] } }' >"$ex_dir/config.json"
    ex_out="$(HOME="$ex_dir" AGENT_DISPATCH_STATE_DIR="$ex_dir" "$REPO_ROOT/bin/agent-dispatch" route --all 2>"$ex_dir/stderr")" && ex_rc=0 || ex_rc=$?
    ex_err="$(cat "$ex_dir/stderr")"
    rm -rf "$ex_dir"
    if [[ $ex_rc -eq 0 && "$ex_out" == 'route final-review: astra harness=codex model=gpt-6-astra effort=xhigh readOnly=os maxParallel=2 (chain: astra)' && -z "$ex_err" ]]; then
        pass '"final-review": ["astra"] → route --all names astra: the chain runs as configured'
    else
        fail "\"final-review\": [\"astra\"] → route --all: rc=$ex_rc out: $ex_out err: $ex_err"
    fi
else
    echo "  [SKIP] node or bin/agent-dispatch not available"
fi

# The built-in route table, when the CLI side ships it, must match the table
# above role for role (spec §5.1). Skipped while the file is absent.
echo ""
echo "Built-in routes (bin/lib/agents-defaults.json)"
DEFAULTS="$REPO_ROOT/bin/lib/agents-defaults.json"
if [[ -f "$DEFAULTS" ]]; then
    if out="$(node --input-type=module -e '
import { readFileSync } from "node:fs";
const d = JSON.parse(readFileSync(process.argv[1], "utf8"));
const wantRoles = {
  "plan-writer": ["opus-xhigh"], "plan-reviser": ["opus-high"],
  "plan-reviewer": ["astra"], "spec-reviewer": ["astra"],
  "implementer": ["glm", "luna"], "implementer.risk": ["sol"], "implementer.escalation": ["sol"],
  "frontend.new-ui": ["opus-high"], "frontend.tweak": ["sonnet-medium"],
  "gate": ["sonnet-medium"], "phase-review": ["opus-high"], "phase-review.escalated": ["opus-xhigh"],
  "control-review": ["astra-high"], "synthesis": ["sonnet-medium"],
  "final-review": ["opus-xhigh", "astra"], "diagnosis": ["opus-high"],
  "quickfix": ["sonnet-medium"], "integration-check": ["sonnet-medium"], "adhoc-review": ["astra-high"],
};
const wantProfiles = {
  glm: { harness: "zcode" },
  luna: { harness: "codex", model: "gpt-6-luna", effort: "max" },
  sol: { harness: "codex", model: "gpt-6.1-sol", effort: "xhigh" },
  astra: { harness: "codex", model: "gpt-6-astra", effort: "xhigh" },
  "astra-high": { harness: "codex", model: "gpt-6-astra", effort: "high" },
  "opus-xhigh": { harness: "inproc", model: "opus", effort: "xhigh" },
  "opus-high": { harness: "inproc", model: "opus", effort: "high" },
  "sonnet-medium": { harness: "inproc", model: "sonnet", effort: "medium" },
};
const bad = [];
for (const [r, chain] of Object.entries(wantRoles)) {
  if (JSON.stringify(d.roles?.[r]) !== JSON.stringify(chain)) bad.push(`role ${r}: ${JSON.stringify(d.roles?.[r])}`);
}
for (const r of Object.keys(d.roles ?? {})) if (!(r in wantRoles)) bad.push(`unexpected role ${r}`);
for (const [p, want] of Object.entries(wantProfiles)) {
  for (const [k, v] of Object.entries(want)) {
    if (d.profiles?.[p]?.[k] !== v) bad.push(`profile ${p}.${k}: ${d.profiles?.[p]?.[k]}`);
  }
}
if (bad.length) { console.log(bad.join("; ")); process.exit(1); }
' "$DEFAULTS" 2>&1)"; then
        pass "agents-defaults.json routes and profiles match the built-in scheme"
    else
        fail "agents-defaults.json differs from the built-in scheme: $out"
    fi
    # Every `route` role the orchestrator's table names exists in the defaults.
    missing=""
    while IFS= read -r role; do
        if ! grep -q "\"$role\"" "$DEFAULTS"; then
            missing="$missing $role"
        fi
    done < <(grep '^| ' "$REPO_ROOT/$ORCH" | grep -o '`[a-z][a-z.-]*`' | tr -d '`' \
        | grep -E '^(plan-|spec-|implementer|frontend\.|gate$|phase-review|control-review|synthesis|final-review|diagnosis|quickfix|integration-check|adhoc-review)' | sort -u)
    if [[ -z "$missing" ]]; then
        pass "every route role in the Model split table exists in agents-defaults.json"
    else
        fail "route roles missing from agents-defaults.json:$missing"
    fi
else
    echo "  [SKIP] bin/lib/agents-defaults.json not present"
fi

if [[ $HAVE_BASE == 0 ]]; then
    echo ""
    echo "  [SKIP] self-check against $BASE_REV (commit not available)"
fi

echo ""
if [[ $FAILURES -eq 0 ]]; then
    echo "PASS"
else
    echo "FAIL: $FAILURES check(s) failed"
    exit 1
fi
