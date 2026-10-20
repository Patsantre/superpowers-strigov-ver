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
