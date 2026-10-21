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
# fences — the lines of the fenced blocks of stdin, the fence lines included
# (for a file whose fences do not nest, such as SKILL.md).
fences() { awk '/^[[:space:]]*```/{f=!f; print; next} f{print}'; }
# review_text — the same for a review template, which nests a bare ``` output-format
# block inside its bare ``` prompt-template block (fences() would count that block
# as outside): the fenced blocks before the `## Prompt template` heading, then
# every line from the heading through its last fence line.
review_text() { awk '/^## Prompt template$/{t=1} t{b=b $0 "\n"; if (/^[[:space:]]*```/) {printf "%s", b; b=""}; next} /^[[:space:]]*```/{f=!f; print; next} f{print}'; }

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
# 6. In-session roles on any profile (increment 6); route --all compares the configured chains.
expect_new "$ORCH" 'Every configured chain counts as written, in-session roles included (`"final-review": ["astra"]` alone is a difference).' 'Routing item 1: chains as configured'
expect_absent "$ORCH" 'alone prints `routes: default` plus a stderr note' 'SKILL.md: no in-session guard'
expect_absent skills/agent-invocation/SKILL.md 'alone prints `routes: default` plus a stderr note' 'agent-invocation: no in-session guard'
expect_absent skills/agent-invocation/SKILL.md 'comes in a later release' 'agent-invocation: external execution ships'
expect_absent skills/agent-invocation/SKILL.md 'is not filtered' 'agent-invocation: no unrestricted final-review order (kept)'
expect_new skills/agent-invocation/SKILL.md $'\n## In-session roles on an external profile\n' 'agent-invocation: the recipe heading (a line of its own, not a quoted cross-reference)'
expect_new skills/agent-invocation/SKILL.md '`--write` for every role except `diagnosis` and `final-review` (`roleKinds` in `agents-defaults.json`;' 'recipe: the write classes (= roleKinds; mirrored by SESSION_READ_ROLES in test-agent-dispatch.sh)'
expect_new skills/agent-invocation/SKILL.md 'the implementers and every in-session role except `diagnosis` and `final-review` ("## In-session roles on an external profile" item 2)' 'step 3: --write for every in-session role but the read kinds'
expect_new skills/agent-invocation/SKILL.md '4. **No-edit check** — every `gate`, `phase-review`, `phase-review.escalated` and `integration-check` job, and every `diagnosis` or `final-review` job whose route line says `readOnly=none`, runs inside "## No-edit check" below' 'recipe: item 4 points at the no-edit check'
# The no-edit check has a section of its own: every run-kind job on an external profile and every read-kind job on
# readOnly=none (final review F2), reached from the recipe and from every reviewer dispatch.
expect_new skills/agent-invocation/SKILL.md $'\n## No-edit check\n' 'agent-invocation: the no-edit check heading (a line of its own)'
expect_new skills/agent-invocation/SKILL.md 'Every job of a `run` role (`gate`, `phase-review`, `phase-review.escalated`, `integration-check`) on an external profile, and every job of a `read` role (`plan-reviewer`, `spec-reviewer`, `control-review`, `final-review`, `diagnosis`, `adhoc-review`) whose route line says `readOnly=none`' 'no-edit check: every run role and every read role on readOnly=none (F2)'
expect_new skills/agent-invocation/SKILL.md 'never under `routes: default`, whose chains keep these roles in the session or the Codex sandbox' 'no-edit check: never under routes: default (F2)'
expect_new skills/agent-invocation/SKILL.md 'a reviewer or `diagnosis`, is allowed, `route` adds a one-line warning on stderr, and "## No-edit check" brackets the job' 'readOnly=none: the route format points at the no-edit check (F2)'
expect_new skills/agent-invocation/SKILL.md '`gate`, `phase-review`, `phase-review.escalated` and `control-review` — the verification gate (dev-orchestrator Step 3.5)' 'no-edit check: control-review restarts from the gate (F2)'
expect_new skills/agent-invocation/SKILL.md '`plan-reviewer` / `spec-reviewer` — a fresh review of the plan / spec as it now stands, at the same round number, with nothing from the voided verdict in the ledger; a checked review'"'"'s `APPROVED` is committed (`docs(plans): add …` / `docs(specs): add …`) only after its `unchanged` line' 'no-edit check: plan / spec review restart, commit only after unchanged (F2)'
expect_new skills/agent-invocation/SKILL.md '`adhoc-review` — the verdict is void and the review re-runs' 'no-edit check: adhoc-review restart (F2)'
expect_new_count "$ORCH" 'A route line with `readOnly=none` puts the job inside `agent-invocation` "No-edit check".' 2 'Step 2 and Step 4.2 point at the no-edit check (F2)'
for f in skills/dev-orchestrator/codex-plan-reviewer-prompt.md skills/dev-orchestrator/codex-control-review-prompt.md \
         skills/brainstorming/spec-reviewer-prompt.md skills/dev-orchestrator/final-review-prompt.md; do
    expect_new "$f" '`route` warns, and the job runs inside `../agent-invocation/SKILL.md` "No-edit check"' "$f: glm points at the no-edit check (F2)"
done
for f in skills/requesting-code-review/SKILL.md skills/systematic-debugging/SKILL.md; do
    expect_new "$f" 'with its reviewer preamble on `zcode` and core harnesses; a route line with `readOnly=none` puts the job inside that skill'"'"'s "No-edit check"' "$f: adhoc-review points at the no-edit check (F2)"
done
for f in skills/writing-plans/SKILL.md skills/brainstorming/SKILL.md; do
    expect_new "$f" 'route line with `readOnly=none` puts the job inside `../agent-invocation/SKILL.md` "No-edit check"' "$f: the reviewer loop points at the no-edit check (F2)"
done
expect_new skills/agent-invocation/SKILL.md 'right before the dispatch: `"$AD" tree-state [--cwd W] > <prompt-file>.tree`' 'recipe: the no-edit baseline lives in a file, so a compaction cannot lose it'
expect_new skills/agent-invocation/SKILL.md 'A checked dispatch always writes a new prompt file' 'no-edit check: one baseline per prompt file'
expect_new skills/agent-invocation/SKILL.md 'as soon as the job ends, whatever its status — after the `result` of a `completed` job, before any retry or switch of a `failed` or `cancelled` one' 'recipe: a failed or cancelled job is compared too'
expect_new skills/agent-invocation/SKILL.md '`unchanged` → `: > <prompt-file>.tree.done`, go on. Anything else voids that run'"'"'s verdict and nothing is committed' 'recipe: only unchanged lets a checked verdict count (fail closed); it settles the check (.tree.done)'
expect_new skills/agent-invocation/SKILL.md 'Then ask the user exactly one question, naming the paths — keep them or revert them' 'recipe: the no-edit check ends in one question'
expect_new skills/agent-invocation/SKILL.md '(neither you nor a subagent reverts): `git diff-tree -p --binary <after> "$(cut -c6- <prompt-file>.tree)" | git apply`' 'recipe: the user reverts the job edits only, keeping the phase work'
expect_new skills/agent-invocation/SKILL.md 'First `route <role> --skip <skips>,<that profile and every profile before it in the chain>`' 'recipe: the no-edit re-run keeps the session skips'
expect_new skills/agent-invocation/SKILL.md 'that round'"'"'s package rebuilt in WORKTREE mode in either round' 'recipe: a final-review re-run sees kept paths and the fix wave'
expect_new skills/agent-invocation/SKILL.md 'the same question also asks where the step runs again (that profile again, or one the user names) — never a second question' 'recipe: an exhausted chain folds into the one question'
expect_new skills/agent-invocation/SKILL.md 'or no such line (a non-zero exit — a missing or empty `.tree` exits 2 — or another line)' 'recipe: a failed --since call voids the verdict (fail closed)'
expect_new skills/agent-invocation/SKILL.md 'The call fails → dispatch nothing' 'recipe: no dispatch without a baseline tree'
expect_new skills/agent-invocation/SKILL.md 'the tree fails there, not the profile' 'recipe: a failed baseline is not a profile failure'
# Nested repositories: the revert command cannot reach them, the question names them apart (final review F5).
expect_new skills/agent-invocation/SKILL.md 'it undoes that job'"'"'s edits to the tree'"'"'s own files and keeps the phase'"'"'s uncommitted work' 'recipe: the revert covers the tree'"'"'s own files (F5)'
expect_absent skills/agent-invocation/SKILL.md 'undoes exactly that job' 'recipe: no claim that the revert is exact (F5)'
expect_new skills/agent-invocation/SKILL.md 'A path marked `(nested repository)` is beyond that command: name it apart — the user reverts inside that repository by hand (`git -C <path> status` / `diff`, `log` if its HEAD moved) or keeps it; never suggest `checkout -- .`, `clean` or `reset --hard` there.' 'recipe: nested repositories are reverted by hand (F5)'
expect_new skills/agent-invocation/SKILL.md 'The user reverted → item 2'"'"'s command once more against the same `.tree`; anything but `unchanged` → one status line `Not reverted: <paths> — kept.`, and those paths count as kept (no second question)' 'recipe: a revert is checked once, then kept (F5)'
expect_new skills/agent-invocation/SKILL.md 'a submodule or nested repository first, as `<path> (nested repository)`' 'tree-state verb row: the nested-repository marker (F5)'
expect_new skills/agent-invocation/SKILL.md '7. **Failures** — for a job item 4 checks, its `--since` check comes first (a changed tree → "## No-edit check", never a retry on that profile)' 'recipe: failures come after the no-edit check'
# A job that ended unchecked before a compaction is checked before the step runs again (final review F11).
expect_new skills/agent-invocation/SKILL.md '[--cwd W] | tee -a <prompt-file>.tree.since` (the record tells a later compaction this job was checked)' 'no-edit check: every check is recorded in .tree.since (F11)'
expect_new skills/agent-invocation/SKILL.md '   - A `.tree` with neither → the job'"'"'s check never finished. No `.tree.since` → it was never checked' 'no-edit check: after a compaction an unchecked or unsettled job is found by its record (F11)'
expect_new skills/agent-invocation/SKILL.md 'A `.tree.since` → it was checked but never settled: run item 2 against that same `.tree` once more (the same baseline, so the check repeats); that job'"'"'s verdict stays void.' 'no-edit check: a changed check whose question was never settled is repeated after a compaction'
# A voided job gets its own marker, so a compaction after the answer still restarts the step (Astra round 2, finding 1).
expect_new skills/agent-invocation/SKILL.md 'Then `: > <prompt-file>.tree.void` — `: > <prompt-file>.tree.void.<profile>` when the answer named the profile (item 3'"'"'s `route` exited `no profile left`) — not `.tree.done` (names only: this job'"'"'s verdict is void and its step restarts from its role'"'"'s point below — item 5 finds it after a compaction).' 'no-edit check: the answer marks the job void (.tree.void, with the profile the user named), not done (r2-1)'
# A void stays pending until its restart has dispatched: a prepared but undispatched prompt file no longer hides it (Astra round 3, finding 1).
expect_new skills/agent-invocation/SKILL.md 'The restart'"'"'s dispatch of that role — an Agent call too, with the prompt it passes — writes a new prompt file (item 1'"'"'s naming); once that dispatch has started (an external job: in its dispatch'"'"'s own Bash command, `<dispatch command> && : > <the voided prompt-file>.tree.restarted`; an Agent call: in the same message, right after the call), `: > <the voided prompt-file>.tree.restarted` (names only) — after the dispatch, never before, so a compaction in between repeats the restart rather than losing it' 'no-edit check: the restart marks the void spent only after its dispatch (r3-1)'
expect_new_count skills/agent-invocation/SKILL.md '.tree.restarted` (names only) — after the dispatch, never before' 1 'no-edit check: one place writes the restarted marker, after the dispatch (r3-1)'
expect_absent skills/agent-invocation/SKILL.md 'an Agent call: the call made' 'no-edit check: an inproc restart marks the void spent in the call'"'"'s own message, so no compaction falls between (r3-1)'
expect_new skills/agent-invocation/SKILL.md '(a running job of that role, found by "## In-session roles on an external profile" item 8, is that dispatch: write the marker and poll it, never dispatch it twice)' 'no-edit check: a restart job found running after a compaction is polled, not dispatched twice (r3-1)'
expect_absent skills/agent-invocation/SKILL.md 'so the marker stops being the role'"'"'s newest once the restart has dispatched it' 'no-edit check: a newer prompt file no longer retires the void marker (r3-1)'
expect_new skills/agent-invocation/SKILL.md 'The step runs again on item 3'"'"'s profile (the one a `.tree.void.<profile>` names), from:' 'no-edit check: the restart list follows the void marker, on the profile it names (r2-1)'
expect_absent skills/agent-invocation/SKILL.md 'Then `: > <prompt-file>.tree.done`, and the step runs again' 'no-edit check: the answer no longer marks a voided job done (r2-1)'
expect_new_count skills/agent-invocation/SKILL.md ': > <prompt-file>.tree.done' 1 'no-edit check: .tree.done only after an unchanged check (r2-1)'
expect_new skills/agent-invocation/SKILL.md 'look at the prompt files (names only) of that role and of every role sharing its restart point (item 4) among those whose name carries this step'"'"'s phase id or plan slug (a parallel track: its own phase; Step 5: the plan slug) — dev-orchestrator Steps 3.5–4: `gate`, `phase-review`, `phase-review.escalated`, `control-review`; Step 5: `final-review` and its check-6 `integration-check`' 'no-edit check: after a compaction every role sharing the restart point is looked at, for this step only (r2-1)'
# Round 2 review: the void check does not depend on the profile the role routes to now, and every checked prompt file has one directory and a step-scoped name.
expect_new skills/agent-invocation/SKILL.md '5. **After a compaction**, before a result of any role item 4 lists counts or its step is dispatched — on whatever profile it routes to now, `inproc` and a read-only one included (item 4'"'"'s skip can move it to one that needs no check) —' 'no-edit check: item 5 runs whatever profile the role routes to now (r2-1)'
expect_absent skills/agent-invocation/SKILL.md 'before a result of a checked role counts' 'no-edit check: item 5 no longer depends on the current route (r2-1)'
expect_new skills/agent-invocation/SKILL.md 'A checked dispatch always writes a new prompt file, `<scratchpad>/dev-orchestrator/<role>-<phase id or plan slug>-r<round>-<n>.md` whatever name its recipe gives ("## In-session roles on an external profile" item 1; `spec-reviewer`: the spec slug; `adhoc-review`: `adhoc`; no scratchpad: the directory `"$WS"` prints without an argument), with a new `<n>` each time: the baseline beside it outlives a compaction, a marker never passes to another job, and one names-only `ls` of that directory finds every marker.' 'no-edit check: every checked prompt file has one directory and a step-scoped name (r2-1)'
expect_absent skills/agent-invocation/SKILL.md 'where the template'"'"'s file name would repeat' 'no-edit check: no recipe-named checked prompt file (r2-1)'
expect_new skills/agent-invocation/SKILL.md 'item 1). First a pending restart, then each role'"'"'s newest prompt file (a pending restart still sets where the step runs):' 'no-edit check: a pending restart is looked for before the newest prompt files, which never cancel it (r3-1)'
expect_new skills/agent-invocation/SKILL.md '   - `.tree.void` or `.tree.void.<profile>` and no `.tree.restarted`, beside any of them → the restart is pending, whatever newer prompt files exist: no verdict of that job counts; the step runs again from item 4'"'"'s restart point for its role, with no new question (the answer was given); with `<profile>`, the role'"'"'s restart dispatch runs there, not on a `route` answer. A void with `.tree.restarted` is spent.' 'no-edit check: a void without .tree.restarted restarts the step after a compaction, whatever newer prompt files exist, no second question, on the profile it names (r2-1, r3-1)'
expect_absent skills/agent-invocation/SKILL.md 'the role'"'"'s own newest prompt file keeps that marker until then' 'no-edit check: the void is no longer looked for on the newest prompt file only (r3-1)'
expect_new skills/agent-invocation/SKILL.md '   - `.tree.done` → the check passed; nothing to do here.' 'no-edit check: a done marker lets the step go on (r2-1)'
expect_new skills/agent-invocation/SKILL.md '   - No `.tree` beside it → that job needed no check (the restart'"'"'s own dispatch, or one on a profile that needs none); nothing to do here.' 'no-edit check: a newest file without a baseline needs nothing (r2-1)'
expect_absent skills/agent-invocation/SKILL.md 'newest prompt file with a `.tree` but no `.tree.done`' 'no-edit check: recovery no longer skips a settled newest file for an older one (r2-1)'
expect_new skills/agent-invocation/SKILL.md 'whose prompt file names the plan slug (a parallel group'"'"'s names its group id: "## In-session roles on an external profile" item 1)' 'no-edit check: the prompt file name tells a check-6 integration-check from a group one (r2-1)'
expect_new skills/agent-invocation/SKILL.md '(`integration-check`: a parallel group'"'"'s names its group id, Step 5'"'"'s check 6 the plan slug;' 'recipe: integration-check prompt files name the group or the plan slug (r2-1)'
# The profile that edited stays skipped for its role (the no-edit marker), and a kept final-review edit is committed.
expect_new skills/agent-invocation/SKILL.md 'append `<role> <the profile that edited> <ISO time>` to `<scratchpad>/dev-orchestrator/no-edit`: every later `route <role>` adds that role'"'"'s profiles from it to `--skip`' 'no-edit check: the profile that edited is recorded per role'
expect_new skills/agent-invocation/SKILL.md 'plus, for this role, the profiles its lines in the `no-edit` marker name ("## No-edit check" item 4)' 'route --skip: the no-edit marker'
expect_new "$ORCH" 'plus this role'"'"'s profiles in the `no-edit` marker (`agent-invocation` "No-edit check" item 4)' 'Routing item 2: the no-edit marker joins the skips'
expect_new skills/agent-invocation/SKILL.md 'a kept edit is committed with the fixes at dev-orchestrator Step 5 item 7' 'no-edit check: a kept final-review edit is committed'
expect_new "$ORCH" 'if the fixer — or an edit kept at an `agent-invocation` "No-edit check" — changed anything, auto-commit those changes' 'Step 5 item 7: a kept no-edit edit is committed'
expect_new "$ORCH" 'the original dispatch'"'"'s preamble (the ZCode preamble for an implementer; for a reviewer or an in-session role the one `agent-invocation` "Headless preambles" names)' 'Verdict parsing: a glm re-dispatch keeps its role preamble'
expect_new skills/agent-invocation/SKILL.md '`unchanged` → the result of a job polled to its end counts when its `job.promptFile` (`status <id> --json`) is that file; otherwise dispatch the step FRESH.' 'no-edit check: after a compaction a checked job is compared before its result counts (F11)'
expect_new skills/agent-invocation/SKILL.md 'A step whose role "## No-edit check" item 4 lists then goes through its item 5 before any result counts or any FRESH dispatch, whatever profile it now routes to' 'recipe: compaction recovery goes through the no-edit check whatever the route (F11, r2-1)'
expect_absent skills/agent-invocation/SKILL.md 'A step item 4 checks then goes through' 'recipe: compaction recovery no longer depends on the current route (r2-1)'
expect_absent skills/agent-invocation/SKILL.md 'nothing ties that job to a baseline' 'recipe: an unmatched zcode / codex job is tied to its baseline (F11)'
expect_new "$ORCH" 'its `--since` line appended to `.tree.since` with `tee -a`, and the empty markers `: > <prompt-file>.tree.done`, `: > <prompt-file>.tree.void[.<profile>]` and `: > <prompt-file>.tree.restarted`; `ls` of that prompt file'"'"'s directory, names only' 'Rule 2: the .tree.since record, the .tree.done / .tree.void / .tree.restarted markers and their listing are allowed (F11, r2-1, r3-1)'
expect_new "$ORCH" '`: > <prompt-file>.tree.done`, `: > <prompt-file>.tree.void[.<profile>]`, `: > <prompt-file>.tree.restarted` and `ls` of a checked job'"'"'s prompt-file directory (names only)' 'pre-flight gate (c): the .tree.done / .tree.void / .tree.restarted markers and the prompt-file listing after a compaction (F11, r2-1, r3-1)'
expect_new "$ORCH" 'Scratch prompt files for `--prompt-file` dispatches, and for the Agent call that redispatches a voided role (`agent-invocation` "No-edit check" item 4) — `Write` to the scratchpad or workspace' 'Rule 1: a voided role'"'"'s restart writes its Agent-call prompt file (r2-1)'
expect_new "$ORCH" 'unless it printed `routes: default`, also `ls` the checked prompt-file directory (`agent-invocation` "No-edit check" item 1; names only) and, before the step resumes, apply that section'"'"'s item 5 whatever profile the step'"'"'s roles route to now: a pending `.tree.void` there restarts the step from its item-4 point, not from the newest package (Durable Progress item 3).' 'recovery: the void check runs whatever the role routes to now; only a pending void restarts (r2-1, r3-1)'
expect_new "$ORCH" 'Not `ls` (outside the printed `"$WS"` directory and that prompt-file directory)' 'pre-flight gate: the Nothing-else line agrees with (c)'
# The external gate's base checkout is removed before the gate and after it (final review F15).
expect_new skills/agent-invocation/SKILL.md '`gate`: open its instructions with "Before anything else: if `<dir>/gate-base` exists or `git worktree list` names it, run `git worktree remove -f -f <dir>/gate-base`"' 'recipe: an external gate starts by removing a leftover gate-base, locked or not (F15)'
expect_absent skills/agent-invocation/SKILL.md 'names it, run `git worktree remove --force' 'recipe: a leftover gate-base is removed with double force (a killed add leaves it locked)'
expect_new skills/agent-invocation/SKILL.md 'After a `gate` job'"'"'s check: if `<dir>/gate-base`' 'no-edit check: a leftover gate-base is removed after the gate (F15)'
expect_absent skills/agent-invocation/SKILL.md 'if the add says the path already exists' 'recipe: no cleanup that waits for the next add (F15)'
expect_new "$ORCH" 'after an external gate, `git worktree remove -f -f <dir>/gate-base`' 'Rule 1: the gate-base cleanup is an allowed git operation (F15)'
expect_new "$ORCH" 'plus that recipe'"'"'s `git worktree remove -f -f <dir>/gate-base`' 'pre-flight gate (c): the gate-base cleanup (F15)'
expect_new skills/agent-invocation/SKILL.md 'add the line `Repository root: <absolute path>`' 'recipe: diagnosis and quickfix prompts name a repository root'
expect_new skills/agent-invocation/SKILL.md '- Create, edit or delete only the files the instructions below tell you to write; running the project'"'"'s tests, linters and builds is fine. No git operations' 'recipe: the session-role preamble'
expect_absent skills/agent-invocation/SKILL.md 'the orchestrator checks the working tree afterwards' 'recipe: the preamble promises no check a writer role does not get (F10)'
# Final review F6, F7, F12, F14.
expect_new "$ORCH" 'each a `route` call — none under `routes: default` while the `channels` marker holds no `off` line, "## Routing" item 1, where the built-in names below apply' 'Step 5 final-fix / repair: no route call under routes: default (F6)'
expect_absent "$ORCH" 'each a `route` call; built-in profiles named' 'Step 5 final-fix / repair: no unconditional route call (F6)'
expect_new skills/requesting-code-review/SKILL.md 'the role here is `adhoc-review`, not `control-review`' 'requesting-code-review: the reused template runs as adhoc-review (F7)'
expect_new "$ORCH" 'a staged one included (`git commit` commits the whole index)' 'auto-commit: a staged unrelated change skips the commit (F12)'
expect_new skills/agent-invocation/SKILL.md '`profile <p> is at maxParallel=<n> (running: <id> cwd=<root>, …)` | run the step-4 Monitor loop on the named jobs, each with `status <id> --cwd <root>`' 'Refusals: maxParallel jobs are polled in their own workspace (F14)'
expect_new skills/agent-invocation/SKILL.md '`frontend.*`: replace the `## Use the frontend-design skill` section with the "Design quality" block below' 'recipe: frontend adaptation is external-only'
expect_new skills/agent-invocation/SKILL.md 'every frontend dispatch except item 2'"'"'s verdict re-dispatch is FRESH' 'recipe: a frontend verdict re-dispatch resumes (item 2)'
expect_new skills/agent-invocation/SKILL.md 'no plan file — a pure frontend task from Triage: `$dir` is `"$WS"` without an argument' 'recipe: a triage frontend task has no plan file'
expect_new skills/agent-invocation/SKILL.md 'The Step 2.5 compaction-safe guards and admission condition (dev-orchestrator Pre-dispatch checklist item 5) are not checked for it' 'recipe: no admission condition for a frontend dispatch'
expect_new skills/agent-invocation/SKILL.md 'A frontend sidecar'"'"'s chain is its `frontend.*` role — the one whose chain lists the sidecar'"'"'s profile, `frontend.new-ui` first — never `implementer.escalation`.' 'recipe: a frontend sidecar never escalates to implementer.escalation'
expect_new skills/agent-invocation/SKILL.md '| `tree-state [--cwd W] [--since TREE]` |' 'agent-invocation: tree-state verb row'
expect_new "$ORCH" '`"$AD" tree-state [--cwd W] [--since <id>]` (the no-edit check, `agent-invocation` "No-edit check": its baseline redirected to the `.tree` file beside the job'"'"'s prompt file' 'Rule 2: tree-state is an allowed main-thread read'
expect_new "$ORCH" '`"$AD" tree-state [--cwd W] [--since <id>]` (where that recipe asks for it) — workspace/package/dispatch bookkeeping' 'pre-flight gate (c): tree-state, a confirmed resume included'
expect_new "$ORCH" 'An in-session role whose route line names an external profile runs as a background job per `agent-invocation`' 'Routing item 2: pointer to the recipe'
expect_new "$ORCH" '; where this skill names its Agent call, read that dispatch.' 'Routing item 2: an Agent call this skill names reads as the routed dispatch'
expect_new "$ORCH" 'or a pure frontend task'"'"'s `frontend.*` dispatch (Triage), routed to an external profile' 'pre-flight gate: a triage frontend task on an external profile'
expect_new "$ORCH" '`Write` of its prompt file to the scratchpad (no scratchpad: the directory `"$WS"` prints without an argument;' 'pre-flight gate: the prompt file without a scratchpad'
expect_new "$ORCH" 'its `task` call on the dispatcher its route line'"'"'s `harness=` names' 'pre-flight gate: an external first dispatch (no wrapper literal)'
expect_new "$ORCH" 'for that job (`agent-invocation` "In-session roles on an external profile"). **The `task` call disarms the gate.**' 'pre-flight gate: the external task call disarms the gate'
expect_new "$ORCH" 'outside the confirmed-resume and external-dispatch allowances above' 'pre-flight gate: the external-dispatch writes are allowances'
expect_new "$ORCH" 'or reviewer preamble (reviewers); an in-session role there: the preamble `agent-invocation` "In-session roles on an external profile" names' 'checklist item 5: the preamble for in-session roles'
expect_new "$ORCH" '; an in-session role on an external profile takes `--write` as that recipe says' 'checklist item 5: --write for in-session roles'
expect_new "$ORCH" '10. **GLM implementer dispatches only** (' 'checklist item 10: implementer scope; in-session roles on glm follow the recipe'
expect_new "$ORCH" 'when `route final-review` names an external profile first (the user'"'"'s chain starts there, or its in-session profiles are down/off), that path is taken directly' 'Step 5: a user chain may start external'
expect_absent "$ORCH" 'when the in-session `final-review` profiles are already skipped' 'SKILL.md: no skipped-only external final review'
expect_new skills/dev-orchestrator/final-review-prompt.md 'or when `"$AD" route final-review` names an external profile first (the user'"'"'s `final-review` chain starts there, or its in-session profiles are down/off)' 'final-review: a user chain may start external'
expect_absent skills/dev-orchestrator/final-review-prompt.md 'when the in-session `final-review` profiles are already skipped' 'final-review: no skipped-only external path'
expect_new skills/dev-orchestrator/final-review-prompt.md 'it is the `integration-check` role' 'final-review: check 6 is the integration-check role'
expect_new skills/dev-orchestrator/final-review-prompt.md 'confirm the file holds that `Check 6 was run by the orchestrator; result:` line with step 1'"'"'s token — missing → fix the file; never dispatch without it.' 'final-review: no external dispatch without the check-6 result'
expect_new skills/writing-plans/SKILL.md 'After `"$AD" route --all` printed `routes: default` (`../agent-invocation/SKILL.md` steps 1–2 — run it once, before the first writer dispatch) it is this Agent call as written, with no `route` call, and so it is when `$AD` does not run at all (say so once and keep the built-in scheme); otherwise `"$AD" route plan-writer` (`plan-reviser`) first' 'writing-plans: no route call under routes: default or without $AD (F1)'
expect_new_count skills/writing-plans/SKILL.md '"$AD" route plan-writer' 1 'writing-plans: route plan-writer only behind the routes: default check (F1)'
expect_new skills/writing-plans/SKILL.md '(check 1 keeps only its no-`ultrathink` part; the profile is the one the route line named)' 'writing-plans: an external writer keeps the no-ultrathink check'
expect_new skills/writing-plans/SKILL.md 'precisely, the profile of the `plan-reviewer` role (`"$AD" route plan-reviewer`, per `../agent-invocation/SKILL.md`); by default Astra, the same command.' 'writing-plans: the plan-reviewer route sentence unchanged'
expect_text skills/writing-plans/SKILL.md 'Agent(subagent_type="general-purpose", model="opus", effort="xhigh", prompt=<assembled prompt>)' 'writing-plans: the Agent call as written'
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
# 7. The in-session dispatch text keeps its built-in wording (external adaptations live in agent-invocation).
expect_text "$ORCH" 'Dispatch the Opus plan writer per `./opus-plan-writer-prompt.md` Mode A: `Agent(subagent_type="general-purpose", model="opus", effort="xhigh", prompt=...)`.' 'Step 1 Agent call'
expect_text "$ORCH" 'A FRESH Opus subagent (`model: "opus"`, `effort: "high"`), using `./opus-plan-writer-prompt.md` Mode B' 'Step 2 reviser Agent call'
expect_text "$ORCH" 'Dispatch Claude frontend implementer subagent using `./claude-frontend-implementer-prompt.md`.' 'frontend Agent call'
expect_text "$ORCH" 'dispatch an Opus subagent to assess (`model: "opus"`, `effort: "high"`; pass BLOCKED report + plan-file path)' 'BLOCKED diagnosis'
expect_text "$ORCH" '**How:** dispatch `Agent(subagent_type="general-purpose", model="sonnet", effort="medium")` with `./verification-gate-prompt.md`' 'gate Agent call'
expect_text "$ORCH" 'Dispatch with `./opus-review-prompt.md` (`model: "opus"`, `effort: "high"`).' '4.1 Agent call'
expect_text "$ORCH" 'Dispatch `Agent(subagent_type="general-purpose", model="sonnet", effort="medium")` with `./synthesize-review-prompt.md`' 'synthesis Agent call'
expect_text "$ORCH" '**Dispatch ONE Opus subagent** per `./final-review-prompt.md` (`model: "opus"`, `effort: "xhigh"`)' 'Step 5 Agent call'
expect_text "$ORCH" 'Dispatch `Agent(subagent_type="general-purpose", model="sonnet", effort="medium")`:' 'integration-check Agent call'
expect_text "$ORCH" 'Do not modify any files. Report line 1 exactly `INTEGRATION_OK` or `INTEGRATION_FAIL`' 'integration-check prompt'
expect_text "$ORCH" 'Sonnet quickfix **subagent** via `Agent(subagent_type="general-purpose", model="sonnet", effort="medium", ...)`' 'quickfix Agent call'
expect_count "$ORCH" 'Subagent is instructed to use the `frontend-design` skill.' 2 'frontend: the design skill in the session (role list and Step 3)' exact
expect_text "$ORCH" '`--write` ONLY on implementation dispatches — no Codex role in the plan stage writes files any more' 'checklist item 5: original --write rule kept'
expect_text "$ORCH" '(the Claude frontend subagent has no handle; `—` before the first dispatch)' 'state line: in-session frontend has no handle'
expect_text skills/dev-orchestrator/claude-frontend-implementer-prompt.md '## Use the frontend-design skill' 'frontend template keeps the skill (in-session)'
expect_text skills/dev-orchestrator/verification-gate-prompt.md '`git stash` + rerun + `git stash pop`' 'gate template unchanged (in-session)'
expect_text skills/dev-orchestrator/sonnet-quickfix-prompt.md 'If you need to clarify anything, stop and ask — do not guess.' 'quickfix template unchanged'
expect_text skills/dev-orchestrator/final-review-prompt.md 'run check 6 as a dispatched Sonnet subagent' 'final-review check 6 default'
if [[ $HAVE_BASE == 1 ]]; then
    for f in opus-plan-writer-prompt.md verification-gate-prompt.md synthesize-review-prompt.md \
             sonnet-quickfix-prompt.md claude-frontend-implementer-prompt.md; do
        if git -C "$REPO_ROOT" diff --quiet "$BASE_REV" -- "skills/dev-orchestrator/$f"; then pass "$f unchanged since $BASE_REV"
        else fail "$f changed since $BASE_REV — external adaptations belong in agent-invocation"; fi
    done
else
    echo "  [SKIP] five templates unchanged since $BASE_REV ($BASE_REV not available)"
fi
# 8. Fenced blocks (Agent calls, command lines, prompt templates with their output formats) byte for byte
#    as at the start of increment 6.
FENCE_REV=8ca4bfb   # the commit increment 6 started from
if git -C "$REPO_ROOT" cat-file -e "$FENCE_REV^{commit}" 2>/dev/null; then
    for f in "$ORCH" skills/dev-orchestrator/opus-review-prompt.md skills/dev-orchestrator/final-review-prompt.md; do
        digest=review_text; [[ $f == "$ORCH" ]] && digest=fences
        if [[ "$($digest <"$REPO_ROOT/$f" | cksum)" == "$(git -C "$REPO_ROOT" show "$FENCE_REV:$f" | $digest | cksum)" ]]; then
            pass "$f: fenced blocks unchanged since $FENCE_REV"
        else
            fail "$f: a fenced block changed since $FENCE_REV — the in-session dispatch text stays as written"
        fi
    done
else
    echo "  [SKIP] fenced-block digests ($FENCE_REV not available)"
fi
n=$(wc -l <"$REPO_ROOT/$ORCH" | tr -d ' ')
if (( n <= 823 )); then pass "SKILL.md growth within budget ($n <= 823; spec §6.2: about 30 over $BASE_REV's 793)"
else fail "SKILL.md grew to $n lines (> 823)"; fi

# 9. Docs: in-session roles on any profile; no stale "later releases" text.
expect_absent README.md 'Running these roles on external harnesses comes in a later release.' 'README: external execution ships'
expect_absent README.md 'come in the next releases' 'README: adapters ship'
expect_absent README.md 'until that harness'"'"'s adapter ships' 'README: presets work'
expect_absent README.md 'its chain runs in order' 'README: no unrestricted final-review order (kept)'
expect_absent README.ru.md 'Запуск этих ролей на внешних харнессах появится' 'README.ru: external execution ships'
expect_absent README.ru.md 'появятся в следующих выпусках' 'README.ru: adapters ship'
expect_absent README.ru.md 'когда выйдет адаптер этого харнесса' 'README.ru: presets work'
expect_absent README.ru.md 'его цепочка идёт по порядку' 'README.ru: no unrestricted final-review order (kept)'
expect_absent PLUGIN_README.md 'arrive in later releases' 'PLUGIN_README: adapters ship'
expect_absent skills/agent-invocation/SKILL.md 'no adapter for that harness yet' 'agent-invocation: all four core adapters ship'
expect_absent .claude-plugin/plugin.json 'arrive in later releases' 'plugin.json: adapters ship'
expect_new README.md '`route --all` lists every role whose chain differs, `"final-review": ["astra"]` included.' 'README: in-session roles on any profile'
expect_new README.ru.md '`route --all` показывает каждую роль, чья цепочка отличается от встроенной, включая `"final-review": ["astra"]`.' 'README.ru: in-session roles on any profile'
expect_new README.md 'If your tests leave files that are not in `.gitignore`, add them there.' 'README: the .gitignore advice'
expect_new README.ru.md 'Если тесты оставляют файлы, которых нет в `.gitignore`, добавьте их туда.' 'README.ru: the .gitignore advice'
expect_new PLUGIN_README.md 'any role — the in-session ones included — can run on any profile (`tree-state` checks that no-edit roles left the tree alone).' 'PLUGIN_README: in-session roles on any profile'
expect_new .claude-plugin/plugin.json 'any role, the in-session ones included, can run on any of them.' 'plugin.json: in-session roles on any profile'
# 10. Docs after the final review (fixes F1–F5, F8, F9, F14): the README pair says the same, the spec agrees.
SPEC=docs/superpowers/specs/2026-10-20-universal-dispatchers-design.md
# F1: a pi models.json apiKey other than $<keyVar> / ${<keyVar>} refuses the task, not only doctor.
expect_new README.md '`task` refuses the profile (exit 2) and `doctor` FAILs `pi-auth` (with `--probe`, before any request)' 'README: pi models.json apiKey refused by task and doctor, no probe request (F1)'
expect_absent README.md 'a literal key there would win over `keyVar` (`doctor` FAIL `pi-auth`)' 'README: no doctor-only pi models.json check (F1)'
expect_new README.ru.md '`task` отклоняет профиль (exit 2), а `doctor` даёт FAIL `pi-auth` (с `--probe` — до всякого запроса)' 'README.ru: pi models.json apiKey refused by task and doctor, no probe request (F1)'
expect_absent README.ru.md 'ключ, записанный там текстом, перекрыл бы `keyVar`' 'README.ru: no doctor-only pi models.json check (F1)'
expect_new "$SPEC" 'отличный от ровно `$<keyVar>` или `${<keyVar>}`' 'spec: pi models.json apiKey check (F1)'
# doctor --probe stops at the doctor FAIL row (exit 1) and never reaches the adapter probe: no exit 2 is promised for it.
expect_absent README.md '`doctor --probe` refuse the profile (exit 2)' 'README: no exit 2 promised for doctor --probe (F1)'
expect_absent README.ru.md '`doctor --probe` отклоняют профиль (exit 2)' 'README.ru: no exit 2 promised for doctor --probe (F1)'
expect_absent "$SPEC" 'exit 2 у `task` и `--probe`' 'spec: no exit 2 promised for --probe, pi (F1)'
expect_absent "$SPEC" '`task` и `--probe` — exit 2' 'spec: no exit 2 promised for --probe, pi and OpenCode (F1, F9)'
expect_absent "$SPEC" '`task` файл не читает' 'spec: task reads the pi models.json (F1)'
# F2: every read role on glm (readOnly=none) is bracketed by the no-edit check.
expect_new README.md 'a read-only role there — these two or a reviewer (`plan-reviewer`, `spec-reviewer`, `control-review`, `adhoc-review`) — gets write access (`route` warns), and the same before/after check runs' 'README: every read role on glm gets the no-edit check (F2)'
expect_new README.ru.md 'роль только для чтения там — эти две или ревьюер (`plan-reviewer`, `spec-reviewer`, `control-review`, `adhoc-review`) — получает право записи (`route` предупреждает) и проходит ту же проверку до и после' 'README.ru: every read role on glm gets the no-edit check (F2)'
expect_new "$SPEC" 'а также задачу любой `read`-роли на профиле с `readOnly=none`' 'spec: every read role on readOnly=none is checked (F2)'
expect_absent "$SPEC" 'задачу `read`-роли (`diagnosis`, `final-review`) на профиле с `readOnly=none`' 'spec: no diagnosis/final-review-only check (F2)'
# F3: a resume runs on the current profile; auth, keyVar and authHeader are bound.
expect_new README.md 'A resumed job runs on the profile as `config.json` has it now' 'README: a resume runs on the current profile (F3)'
expect_new README.md '`--resume-task` refuses (`dispatch --fresh`) a record whose harness, model, endpoint, home, `bin`, `wrap`, `sandbox`, `auth`, `keyVar` or `authHeader` differ from `config.json`' 'README: resume bound fields (F3)'
expect_new README.ru.md 'Продолжение задачи идёт на профиле в том виде, в каком он сейчас записан в `config.json`' 'README.ru: a resume runs on the current profile (F3)'
expect_new README.ru.md '`--resume-task` отказывает (`dispatch --fresh`), если харнесс, модель, эндпоинт, каталог, `bin`, `wrap`, `sandbox`, `auth`, `keyVar` или `authHeader`' 'README.ru: resume bound fields (F3)'
expect_new "$SPEC" 'Продолжение идёт на профиле из текущего `config.json`' 'spec: a resume runs on the current profile (F3)'
expect_new "$SPEC" '`bin`, `wrap`, `sandbox`, `auth`, `keyVar`, `authHeader`, — exit 2' 'spec: resume bound fields (F3)'
# F4: the scrub runs when the runner finishes the job; a dead runner leaves the session files.
expect_absent README.md 'redacted after every run' 'README: no after-every-run scrub promise (F4)'
expect_new README.md 'If the runner process itself dies (killed, a crash, a power loss), the job is reaped as `failed` / `crash`' 'README: a dead runner leaves pi session files (F4)'
expect_new README.md '`~/.claude/plugins/data/superpowers-strigov-ver-agents/state/<workspace>/jobs/<id>/`' 'README: the job directory to delete (F4)'
expect_absent README.ru.md 'после каждого запуска перезаписываются' 'README.ru: no after-every-run scrub promise (F4)'
expect_new README.ru.md 'Если погиб сам процесс раннера (его убили, сбой, отключение питания), задача помечается `failed` / `crash`' 'README.ru: a dead runner leaves pi session files (F4)'
expect_new README.ru.md '`~/.claude/plugins/data/superpowers-strigov-ver-agents/state/<workspace>/jobs/<id>/`' 'README.ru: the job directory to delete (F4)'
expect_absent "$SPEC" 'после каждого запуска с ключом они перезаписываются' 'spec: no after-every-run scrub promise (F4)'
expect_new "$SPEC" 'Если погиб сам процесс раннера (его убили, сбой, отключение питания), уборка помечает задачу `failed` / `crash`' 'spec: a dead runner leaves pi session files (F4)'
# Round 2, finding 3: the reaper closes a dead job's record as the job left it, so its meta.sessionDir names no directory
# to delete; the chain's job ids do, and a recorded dir is only a hint in the adapter's shape.
expect_absent README.md 'gives the exact directory: the parent of `job.meta.sessionDir`' 'README: a dead job meta.sessionDir is not the directory to delete (R2-3)'
expect_new README.md 'delete `jobs/<id>/` of each job of the chain (the ids passed to `--resume-task`, back to the first)' 'README: a dead resumed job: delete the dir of each job of its chain (R2-3)'
expect_new README.md 'trust it only when it is `<that jobs directory>/<an id of this chain>/sessions`' 'README: a recorded session dir is only a hint (R2-3)'
expect_absent README.ru.md 'точный каталог печатает' 'README.ru: a dead job meta.sessionDir is not the directory to delete (R2-3)'
expect_new README.ru.md 'удалите `jobs/<id>/` каждой задачи цепочки (id, переданные в `--resume-task`, до первой)' 'README.ru: a dead resumed job: delete the dir of each job of its chain (R2-3)'
expect_new README.ru.md 'доверяйте ей, только если это `<этот каталог jobs>/<id задачи этой цепочки>/sessions`' 'README.ru: a recorded session dir is only a hint (R2-3)'
expect_absent "$SPEC" 'точный путь — каталог над `job.meta.sessionDir`' 'spec: a dead job meta.sessionDir is not the directory to delete (R2-3)'
expect_new "$SPEC" 'Каталог берётся по номерам задач, а не из записи погибшей задачи' 'spec: the directory to delete comes from the job ids (R2-3)'
# F5: nested repositories in tree-state and the revert.
expect_new "$SPEC" 'печатается как `<путь> (nested repository)` и стоит раньше остальных' 'spec: tree-state marks nested repositories first (F5)'
expect_new "$SPEC" 'иначе одна строка `Not reverted: <пути> — kept.`' 'spec: a failed revert is kept without a second question (F5)'
# F8: a launch that never spawned a runner leaves no key handoff file.
expect_new "$SPEC" 'Так у задачи, отменённой до старта раннера, копии ключа не остаётся.' 'spec: no handoff file after a launch without a runner (F8)'
# F9: a provider entry in ~/.opencode refuses a keyed opencode profile.
expect_new README.md 'OpenCode also reads `~/.opencode/opencode.json` and `opencode.jsonc` in your real home' 'README: ~/.opencode provider entry refused (F9)'
expect_new README.ru.md 'OpenCode читает ещё и `~/.opencode/opencode.json` и `opencode.jsonc`' 'README.ru: ~/.opencode provider entry refused (F9)'
expect_new "$SPEC" '`~/.opencode/opencode.json` и `opencode.jsonc` OpenCode читает при любой изоляции' 'spec: ~/.opencode provider entry refused (F9)'
# Round 2, finding 2: those files are read as JSONC, and only the fields that pick the key or the endpoint refuse.
expect_new README.md 'For a keyed profile they are read as JSONC (comments and trailing commas are fine)' 'README: ~/.opencode and the managed config are read as JSONC (R2-2)'
expect_new README.md 'A harmless entry (empty, a `name`, `whitelist`/`blacklist`, timeouts, model limits and reasoning variants) and a file without that entry run.' 'README: a harmless provider entry runs (R2-2)'
expect_absent README.md 'A file there that is not plain JSON (comments, trailing commas)' 'README: comments no longer refuse a keyed opencode profile (R2-2)'
expect_new README.ru.md 'У профиля с ключом они читаются как JSONC (комментарии и висячие запятые допустимы)' 'README.ru: ~/.opencode and the managed config are read as JSONC (R2-2)'
expect_new README.ru.md 'Безобидная запись (пустая, `name`, `whitelist`/`blacklist`, тайм-ауты, лимиты модели и варианты рассуждения) и файл без такой записи работают.' 'README.ru: a harmless provider entry runs (R2-2)'
expect_absent README.ru.md 'который не разбирается как обычный JSON (комментарии, висячие запятые)' 'README.ru: comments no longer refuse a keyed opencode profile (R2-2)'
expect_new "$SPEC" 'и, как сам OpenCode, разбирает их как JSONC' 'spec: ~/.opencode and the managed config are read as JSONC (R2-2)'
expect_new "$SPEC" 'отказ вызывает поле, которое меняет ключ или адрес запросов' 'spec: only key or endpoint fields refuse (R2-2)'
expect_absent "$SPEC" 'Файл разбирается как обычный JSON' 'spec: comments no longer refuse a keyed opencode profile (R2-2)'
# F14: the maxParallel refusal names each running job with its workspace root.
expect_new "$SPEC" '`agent-dispatch: profile <p> is at maxParallel=<n> (running: <id> cwd=<корень>, …)`' 'spec: maxParallel refusal names the workspace (F14)'

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
