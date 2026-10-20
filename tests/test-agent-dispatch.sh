#!/usr/bin/env bash
# Tests for bin/agent-dispatch and bin/lib/agent-dispatch.mjs, the CLI of the universal dispatchers (increment 1 of
# docs/superpowers/specs/2026-10-20-universal-dispatchers-design.md §8). Zero model calls and no real wrapper: the
# pass-through profiles reach tests/fixtures/wrapper-stub.cjs, linked as zcode-dispatch / codex-dispatch under the temp
# root ($AGENT_DISPATCH_ZCODE / $AGENT_DISPATCH_CODEX), which records every argv; the core path runs the stand-in
# claude adapter tests/fixtures/dispatch-adapters/claude.mjs ($AGENT_DISPATCH_ADAPTER_DIR) over
# tests/fixtures/agent-stub.cjs. All state lives under a temp root (AGENT_DISPATCH_STATE_DIR, HOME). Runs on macOS and
# Linux.
#
# The golden reference is the table "Сквозные вызовы" of spec §3.3: for every role of the built-in scheme and every
# profile of its chain, the argv the wrapper receives must equal it.
#
# Every process a run starts carries the run's temp root in its argv (runners: their jobs dir; harness stubs: the
# per-run link $AGENT_TEST_STUB; wrapper stubs: their link), so the cleanup and the leak check touch this run only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$REPO_ROOT/bin/lib/agent-dispatch.mjs"
LAUNCHER="$REPO_ROOT/bin/agent-dispatch"
DEFAULTS_JSON="$REPO_ROOT/bin/lib/agents-defaults.json"
FIX="$SCRIPT_DIR/fixtures"
STUB="$FIX/agent-stub.cjs"
WSTUB="$FIX/wrapper-stub.cjs"

FAILURES=0
PASSES=0
TEST_ROOT=""
OUT=""
ERR=""
RC=0

pass() {
    echo "  [PASS] $1"
    PASSES=$((PASSES + 1))
}
fail() {
    echo "  [FAIL] $1"
    FAILURES=$((FAILURES + 1))
}
# verdict <label> <condition-status> [detail...] — PASS when the status is 0, else FAIL with the details.
verdict() {
    local label="$1" ok="$2"
    shift 2
    if [[ "$ok" -eq 0 ]]; then
        pass "$label"
    else
        fail "$label"
        local line
        for line in "$@"; do echo "    $line"; done
    fi
}

cleanup() {
    if [[ -n "$TEST_ROOT" ]]; then pkill -KILL -f "$TEST_ROOT" 2>/dev/null || true; fi
    if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then rm -rf "$TEST_ROOT"; fi
}

ad() { node "$CLI" "$@"; }

# run_ad <args...> — run agent-dispatch; OUT = stdout, ERR = stderr, RC = exit code.
run_ad() {
    OUT="$(ad "$@" 2>"$TEST_ROOT/stderr.txt")"
    RC=$?
    ERR="$(cat "$TEST_ROOT/stderr.txt")"
}

# jfield <dot.path> — read JSON on stdin, print the field ('' when missing; objects as JSON).
jfield() {
    node -e '
let s = "";
process.stdin.on("data", (d) => (s += d)).on("end", () => {
  let v = JSON.parse(s);
  for (const k of process.argv[1].split(".")) v = v == null ? undefined : v[k];
  process.stdout.write(v === undefined || v === null ? "" : typeof v === "object" ? JSON.stringify(v) : String(v));
});' "$1"
}

# jarr <args...> — the JSON array of the arguments (the shape the wrapper stub records).
jarr() { node -e 'process.stdout.write(JSON.stringify(process.argv.slice(1)))' -- "$@"; }

# jwords <json-array> — its items, space-separated.
jwords() { node -e 'process.stdout.write(JSON.parse(process.argv[1]).join(" "))' -- "$1"; }

# reset_wrappers — forget every recorded wrapper call and canned reply.
reset_wrappers() {
    rm -rf "$WRAPPER_STUB_DIR"
    mkdir -p "$WRAPPER_STUB_DIR"
}

# can <wrapper> <verb> <stdout|stderr|exit> <content> — a canned reply of the wrapper stub.
can() { printf '%s' "$4" >"$WRAPPER_STUB_DIR/$1.$2.$3"; }

# last_call <wrapper> <verb> — the argv (JSON) of the wrapper's last call of that verb.
last_call() { grep "^\[\"$2\"" "$WRAPPER_STUB_DIR/$1.argv" 2>/dev/null | tail -1 || true; }

# calls_of <wrapper> <verb> — how many calls of that verb the wrapper got.
calls_of() {
    local n
    n="$(grep -c "^\[\"$2\"" "$WRAPPER_STUB_DIR/$1.argv" 2>/dev/null || true)"
    echo "${n:-0}"
}

write_config() { mkdir -p "$AGENT_DISPATCH_STATE_DIR" && cat >"$AGENT_DISPATCH_STATE_DIR/config.json"; }
no_config() { rm -f "$AGENT_DISPATCH_STATE_DIR/config.json"; }

# wait_status <id> <regex> <seconds> [status args...] — poll until the core job's status matches; print it.
wait_status() {
    local id="$1" want="$2" limit="$3"
    shift 3
    local st="" i=0
    while ((i < limit * 5)); do
        st="$(ad status "$id" --json "$@" 2>/dev/null | jfield job.status || true)"
        if [[ "$st" =~ ^($want)$ ]]; then break; fi
        sleep 0.2
        i=$((i + 1))
    done
    echo "$st"
}

# count_records <jobs-dir> — number of core job records.
count_records() {
    local n=0 f
    for f in "$1"/*.json; do [[ -e "$f" ]] && n=$((n + 1)); done
    echo "$n"
}

mode_of() { node -e 'console.log((require("node:fs").statSync(process.argv[1]).mode & 0o777).toString(8))' -- "$1"; }

jobs_dir_of() {
    CORE="$REPO_ROOT/bin/lib/agent-core.mjs" node --input-type=module -e "
const { pathToFileURL } = await import('node:url');
const core = await import(pathToFileURL(process.env.CORE).href);
console.log(core.resolveWorkspace(process.argv[1]).jobsDir);" -- "$1"
}

main() {
    echo "=== Test: agent-dispatch ==="

    TEST_ROOT="$(mktemp -d)"
    trap cleanup EXIT
    umask 022

    export HOME="$TEST_ROOT/home"
    mkdir -p "$HOME" "$TEST_ROOT/bin"
    export AGENT_DISPATCH_STATE_DIR="$TEST_ROOT/state"
    local STATE="$AGENT_DISPATCH_STATE_DIR"
    local CONFIG="$STATE/config.json"
    ln -s "$STUB" "$TEST_ROOT/bin/agent-stub.cjs"
    export AGENT_TEST_STUB="$TEST_ROOT/bin/agent-stub.cjs"
    ln -s "$WSTUB" "$TEST_ROOT/bin/zcode-dispatch"
    ln -s "$WSTUB" "$TEST_ROOT/bin/codex-dispatch"
    export AGENT_DISPATCH_ZCODE="$TEST_ROOT/bin/zcode-dispatch"
    export AGENT_DISPATCH_CODEX="$TEST_ROOT/bin/codex-dispatch"
    export WRAPPER_STUB_DIR="$TEST_ROOT/wrappers"
    export AGENT_DISPATCH_ADAPTER_DIR="$FIX/dispatch-adapters"
    unset AGENT_TEST_BOOT_ID CLAUDE_CONFIG_DIR TEST_KEY_VAR SP_IMPLEMENTER CODEX_COMPANION_SESSION_ID
    unset AGENT_STUB_MODE AGENT_STUB_RECORD AGENT_STUB_DELAY_MS AGENT_STUB_MESSAGE AGENT_STUB_CLASS AGENT_STUB_EXIT
    unset AGENT_STUB_RESPONSE AGENT_STUB_SECRET_VAR AGENT_STUB_DIALECT
    export AGENT_ENV_PASSTHROUGH="AGENT_STUB_MODE,AGENT_STUB_RECORD,AGENT_STUB_DELAY_MS,AGENT_STUB_MESSAGE,AGENT_STUB_CLASS,AGENT_STUB_EXIT,AGENT_STUB_RESPONSE,AGENT_STUB_SECRET_VAR"
    reset_wrappers

    local git_id=(-c user.email=t@example.com -c user.name=t -c commit.gpgsign=false)
    local r
    for r in repo repo2; do
        git init -q -b main "$TEST_ROOT/$r"
        printf 'x\n' >"$TEST_ROOT/$r/a.txt"
        (cd "$TEST_ROOT/$r" && git add a.txt && git "${git_id[@]}" commit -qm c0)
    done
    local repo repo2
    repo="$(cd "$TEST_ROOT/repo" && git rev-parse --show-toplevel)"
    repo2="$(cd "$TEST_ROOT/repo2" && git rev-parse --show-toplevel)"
    local prompt="$TEST_ROOT/prompt.md"
    printf '## Headless run\n\nImplement the thing.\n' >"$prompt"
    cd "$repo"
    local JOBS
    JOBS="$(jobs_dir_of "$repo")"
    # From here on a failing command must not end the suite: FAILURES decides the exit code, and the summary prints.
    set +e

    local ok want got id id2 role prof chain wrapper other line expected roles st n before key

    # --- 1. the launcher resolves the local tree and pins the data dir ---
    run_ad route implementer
    local direct="$OUT"
    OUT="$(bash "$LAUNCHER" route implementer 2>&1)"
    [[ "$OUT" == "$direct" && -n "$direct" ]]
    verdict "1 bin/agent-dispatch runs bin/lib/agent-dispatch.mjs of this tree (no marketplace cache under the test HOME)" $? "launcher: $OUT" "direct: $direct"
    OUT="$(printf 'launcher-key-1\n' | env -u AGENT_DISPATCH_STATE_DIR bash "$LAUNCHER" key set lk 2>&1)"
    local pinned="$HOME/.claude/plugins/data/superpowers-strigov-ver-agents"
    [[ -f "$pinned/keys/lk" && "$(cat "$pinned/keys/lk")" == launcher-key-1 && "$(mode_of "$pinned")" == 700 ]]
    verdict "1 without AGENT_DISPATCH_STATE_DIR the launcher keeps data in ~/.claude/plugins/data/superpowers-strigov-ver-agents (0700)" $? "out: $OUT" "files: $(find "$HOME/.claude" 2>/dev/null | tr '\n' ' ')"

    # --- 2. no config.json: the owner's scheme, route by route ---
    no_config
    run_ad route --all
    [[ "$RC" -eq 0 && "$OUT" == "routes: default" && -z "$ERR" ]]
    verdict "2 route --all without config.json prints exactly 'routes: default'" $? "rc=$RC out: $OUT err: $ERR"
    run_ad route --all --json
    [[ "$RC" -eq 0 && "$(jfield default <<<"$OUT")" == true && "$(jfield routes <<<"$OUT")" == '[]' && "$(node -e 'console.log(Object.keys(JSON.parse(process.argv[1])).join(","))' -- "$OUT")" == default,routes ]]
    verdict "2 route --all --json without config.json: {\"default\": true, \"routes\": []}" $? "rc=$RC out: $OUT"

    expected="$(cat <<'EOF'
route plan-writer: opus-xhigh harness=inproc model=opus effort=xhigh readOnly=- maxParallel=- (chain: opus-xhigh)
route plan-reviser: opus-high harness=inproc model=opus effort=high readOnly=- maxParallel=- (chain: opus-high)
route plan-reviewer: astra harness=codex model=gpt-6-astra effort=xhigh readOnly=os maxParallel=2 (chain: astra)
route spec-reviewer: astra harness=codex model=gpt-6-astra effort=xhigh readOnly=os maxParallel=2 (chain: astra)
route implementer: glm harness=zcode model=GLM-5.3-Flash effort=max readOnly=none maxParallel=2 (chain: glm, luna)
route implementer.risk: sol harness=codex model=gpt-6.1-sol effort=xhigh readOnly=os maxParallel=2 (chain: sol)
route implementer.escalation: sol harness=codex model=gpt-6.1-sol effort=xhigh readOnly=os maxParallel=2 (chain: sol)
route frontend.new-ui: opus-high harness=inproc model=opus effort=high readOnly=- maxParallel=- (chain: opus-high)
route frontend.tweak: sonnet-medium harness=inproc model=sonnet effort=medium readOnly=- maxParallel=- (chain: sonnet-medium)
route gate: sonnet-medium harness=inproc model=sonnet effort=medium readOnly=- maxParallel=- (chain: sonnet-medium)
route phase-review: opus-high harness=inproc model=opus effort=high readOnly=- maxParallel=- (chain: opus-high)
route phase-review.escalated: opus-xhigh harness=inproc model=opus effort=xhigh readOnly=- maxParallel=- (chain: opus-xhigh)
route control-review: astra-high harness=codex model=gpt-6-astra effort=high readOnly=os maxParallel=2 (chain: astra-high)
route synthesis: sonnet-medium harness=inproc model=sonnet effort=medium readOnly=- maxParallel=- (chain: sonnet-medium)
route final-review: opus-xhigh harness=inproc model=opus effort=xhigh readOnly=- maxParallel=- (chain: opus-xhigh, astra)
route diagnosis: opus-high harness=inproc model=opus effort=high readOnly=- maxParallel=- (chain: opus-high)
route quickfix: sonnet-medium harness=inproc model=sonnet effort=medium readOnly=- maxParallel=- (chain: sonnet-medium)
route integration-check: sonnet-medium harness=inproc model=sonnet effort=medium readOnly=- maxParallel=- (chain: sonnet-medium)
route adhoc-review: astra-high harness=codex model=gpt-6-astra effort=high readOnly=os maxParallel=2 (chain: astra-high)
EOF
)"
    roles="$(node -e 'console.log(Object.keys(require(process.argv[1]).roles).join(" "))' -- "$DEFAULTS_JSON")"
    got=""
    for role in $roles; do got="$got$(ad route "$role")"$'\n'; done
    [[ "${got%$'\n'}" == "$expected" ]]
    verdict "2 route ROLE for all 19 built-in roles prints the Model split of SKILL.md in the §3.3 format" $? "$(diff <(echo "$expected") <(echo "${got%$'\n'}"))"

    # --- 3. the golden table: every role of the built-in scheme, every profile of its chain ---
    golden_want() { # <role:profile> → the wrapper argv (JSON), REFUSE for an in-session profile, or MISSING
        case "$1" in
            implementer:glm) jarr task --background --prompt-file "$prompt" ;;
            implementer:luna) jarr task --background --write --model gpt-6-luna --effort max --prompt-file "$prompt" ;;
            implementer.risk:sol | implementer.escalation:sol) jarr task --background --write --model gpt-6.1-sol --effort xhigh --prompt-file "$prompt" ;;
            plan-reviewer:astra | spec-reviewer:astra | final-review:astra) jarr task --background --model gpt-6-astra --effort xhigh --prompt-file "$prompt" ;;
            control-review:astra-high | adhoc-review:astra-high) jarr task --background --model gpt-6-astra --effort high --prompt-file "$prompt" ;;
            *:opus-xhigh | *:opus-high | *:sonnet-medium) echo REFUSE ;;
            *) echo MISSING ;;
        esac
    }
    local cases=0 write_flag
    for role in $roles; do
        chain="$(jwords "$(ad route "$role" --json | jfield chain)")"
        write_flag=""
        [[ "$role" == implementer* ]] && write_flag="--write"
        for prof in $chain; do
            cases=$((cases + 1))
            want="$(golden_want "$role:$prof")"
            reset_wrappers
            run_ad task --profile "$prof" --role "$role" --background $write_flag --prompt-file "$prompt"
            if [[ "$want" == REFUSE ]]; then
                [[ "$RC" -eq 2 && "$ERR" == *"Agent tool"* && "$(calls_of zcode-dispatch task)" -eq 0 && "$(calls_of codex-dispatch task)" -eq 0 ]]
                verdict "3 golden $role → $prof: in-session profile, task refused (exit 2, Agent tool), no wrapper called" $? "rc=$RC err: $ERR"
                continue
            fi
            if [[ "$prof" == glm ]]; then
                wrapper=zcode-dispatch other=codex-dispatch line="ZCode Task started in the background as zt-0001"
            else
                wrapper=codex-dispatch other=zcode-dispatch line="Codex Task started in the background as task-stub-0001. Check /codex:status task-stub-0001 for progress."
            fi
            got="$(last_call "$wrapper" task)"
            [[ "$want" != MISSING && "$RC" -eq 0 && "$got" == "$want" && "$OUT" == "$line" && "$(calls_of "$wrapper" task)" -eq 1 && "$(calls_of "$other" task)" -eq 0 ]]
            verdict "3 golden $role → $prof: $wrapper gets $(jwords "$want" | sed "s|$prompt|F|")" $? "rc=$RC want: $want" "got:  $got" "out: $OUT" "err: $ERR"
        done
    done
    [[ "$cases" -eq 21 ]]
    verdict "3 the golden table covered every profile of every built-in chain (21 role/profile pairs)" $? "cases=$cases"

    # Variants of the table: --cwd, --resume-task, --fresh pass through in the table's order.
    golden_variant() { # <label> <wrapper> <want-json> -- <task args...>
        local label="$1" wrapper="$2" want="$3"
        shift 4
        reset_wrappers
        run_ad task "$@"
        local got
        got="$(last_call "$wrapper" task)"
        [[ "$RC" -eq 0 && "$got" == "$want" ]]
        verdict "3 golden $label" $? "rc=$RC want: $want" "got:  $got" "err: $ERR"
    }
    golden_variant "glm --cwd W --resume-task zt-0007 → task --background --cwd W --resume-task zt-0007 --prompt-file F" zcode-dispatch \
        "$(jarr task --background --cwd "$repo2" --resume-task zt-0007 --prompt-file "$prompt")" \
        -- --profile glm --role implementer --background --write --cwd "$repo2" --resume-task zt-0007 --prompt-file "$prompt"
    golden_variant "glm --fresh → task --background --fresh --prompt-file F" zcode-dispatch \
        "$(jarr task --background --fresh --prompt-file "$prompt")" \
        -- --profile glm --background --write --fresh --prompt-file "$prompt"
    golden_variant "luna --cwd W --resume-task task-… → task --background --write --model gpt-6-luna --effort max --cwd W --resume-task task-… --prompt-file F" codex-dispatch \
        "$(jarr task --background --write --model gpt-6-luna --effort max --cwd "$repo2" --resume-task task-mf3abc-x1y2z3 --prompt-file "$prompt")" \
        -- --profile luna --role implementer --background --write --cwd "$repo2" --resume-task task-mf3abc-x1y2z3 --prompt-file "$prompt"
    golden_variant "sol --fresh → task --background --write --model gpt-6.1-sol --effort xhigh --fresh --prompt-file F" codex-dispatch \
        "$(jarr task --background --write --model gpt-6.1-sol --effort xhigh --fresh --prompt-file "$prompt")" \
        -- --profile sol --role implementer.escalation --background --write --fresh --prompt-file "$prompt"
    golden_variant "astra --cwd W (reviewer, no --write) → task --background --model gpt-6-astra --effort xhigh --cwd W --prompt-file F" codex-dispatch \
        "$(jarr task --background --model gpt-6-astra --effort xhigh --cwd "$repo2" --prompt-file "$prompt")" \
        -- --profile astra --role plan-reviewer --background --cwd "$repo2" --prompt-file "$prompt"

    reset_wrappers
    run_ad task --profile glm --role implementer --background --prompt-file "$prompt"
    [[ "$RC" -eq 0 && "$(last_call zcode-dispatch task)" == "$(jarr task --background --prompt-file "$prompt")" && "$(grep -c 'WARN' <<<"$ERR")" -eq 1 && "$ERR" == *"glm has no read-only mode"* ]]
    verdict "3 glm without --write: the same argv (no --write reaches zcode-dispatch) and exactly one WARN line" $? "rc=$RC err: $ERR" "argv: $(last_call zcode-dispatch task)"

    reset_wrappers
    can zcode-dispatch task stderr "zcode-dispatch: SP_IMPLEMENTER=luna is set: the GLM channel is switched off (kill switch)"$'\n'
    can zcode-dispatch task exit 2
    can zcode-dispatch task stdout ""
    run_ad task --profile glm --background --write --prompt-file "$prompt"
    [[ "$RC" -eq 2 && -z "$OUT" && "$ERR" == "zcode-dispatch: SP_IMPLEMENTER=luna is set: the GLM channel is switched off (kill switch)" ]]
    verdict "3 a wrapper's refusal passes through unchanged: its stderr and exit 2" $? "rc=$RC out: $OUT err: $ERR"

    reset_wrappers
    run_ad task --profile glm --background --write --resume-task task-abc --prompt-file "$prompt"
    local rc1="$RC" err1="$ERR"
    run_ad task --profile luna --background --write --resume-task zt-0001 --prompt-file "$prompt"
    local rc2="$RC" err2="$ERR"
    run_ad task --profile luna --background --write --resume-task ct-0001 --prompt-file "$prompt"
    [[ "$rc1" -eq 2 && "$err1" == "agent-dispatch: task-abc cannot resume on profile glm: ids do not move between harnesses (zcode resumes zt- ids only); dispatch --fresh" \
        && "$rc2" -eq 2 && "$err2" == *"zt-0001 cannot resume on profile luna: ids do not move between harnesses"*"dispatch --fresh" \
        && "$RC" -eq 2 && "$ERR" == *"ct-0001 cannot resume on profile luna"*"dispatch --fresh" \
        && "$(calls_of zcode-dispatch task)" -eq 0 && "$(calls_of codex-dispatch task)" -eq 0 ]]
    verdict "3 --resume-task with another harness's id (task- on glm, zt- / ct- on luna): exit 2 '… dispatch --fresh' before any wrapper runs" $? "glm: rc=$rc1 err: $err1" "luna zt-: rc=$rc2 err: $err2" "luna ct-: rc=$RC err: $ERR"

    # --- 4. status / result / cancel route by id prefix and pass the wrappers through unchanged ---
    reset_wrappers
    can zcode-dispatch result stdout $'DONE\nthe GLM report\n'
    can zcode-dispatch result stderr $'a zcode note\n'
    can zcode-dispatch result exit 1
    run_ad result zt-0004 --cwd "$repo"
    [[ "$RC" -eq 1 && "$OUT" == $'DONE\nthe GLM report' && "$ERR" == "a zcode note" && "$(last_call zcode-dispatch result)" == "$(jarr result zt-0004 --cwd "$repo")" && "$(calls_of codex-dispatch result)" -eq 0 ]]
    verdict "4 result zt-… goes to zcode-dispatch with the same argv; stdout, stderr and exit 1 unchanged" $? "rc=$RC out: $OUT err: $ERR argv: $(last_call zcode-dispatch result)"
    can codex-dispatch cancel stdout $'Cancelled task-mf3abc-x1y2z3.\n'
    can codex-dispatch cancel exit 3
    run_ad cancel task-mf3abc-x1y2z3
    [[ "$RC" -eq 3 && "$OUT" == "Cancelled task-mf3abc-x1y2z3." && "$(last_call codex-dispatch cancel)" == "$(jarr cancel task-mf3abc-x1y2z3)" && "$(calls_of zcode-dispatch cancel)" -eq 0 ]]
    verdict "4 cancel task-… goes to codex-dispatch; stdout and exit 3 unchanged" $? "rc=$RC out: $OUT argv: $(last_call codex-dispatch cancel)"
    can zcode-dispatch status stdout '{"job":{"id":"zt-0002","status":"running"}}'$'\n'
    run_ad status zt-0002 --json
    [[ "$RC" -eq 0 && "$OUT" == '{"job":{"id":"zt-0002","status":"running"}}' && "$(last_call zcode-dispatch status)" == "$(jarr status zt-0002 --json)" ]]
    verdict "4 status zt-… --json is zcode-dispatch's output as is" $? "rc=$RC out: $OUT"
    can codex-dispatch result stdout $'APPROVED\nastra says fine\n'
    run_ad result task-abc123
    [[ "$RC" -eq 0 && "$OUT" == $'APPROVED\nastra says fine' && "$(last_call codex-dispatch result)" == "$(jarr result task-abc123)" ]]
    verdict "4 result task-… is codex-dispatch's output as is" $? "rc=$RC out: $OUT"

    # --- 5. config.json: merge, in-session roles, --skip and linked profiles ---
    write_config <<'EOF'
{
  "version": 1,
  "profiles": {
    "claude-sub": { "harness": "claude", "auth": "login", "model": "opus", "effort": "xhigh" },
    "sonnet-high": { "harness": "inproc", "model": "sonnet", "effort": "high" },
    "glm-api": {
      "harness": "claude", "auth": { "key": "zai" }, "shares": "zai-coding-plan",
      "endpoint": "https://api.z.ai/api/anthropic", "model": "glm-5.3[1m]", "effort": "max",
      "env": { "API_TIMEOUT_MS": "3000000", "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "1000000" }
    },
    "deepseek-claude": {
      "harness": "claude", "auth": { "key": "deepseek" }, "endpoint": "https://api.deepseek.com/anthropic",
      "model": "deepseek-v4-pro[1m]", "effort": "high", "env": { "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "786432" }
    },
    "deepseek-dsh": { "harness": "dsh", "auth": { "key": "deepseek" }, "model": "deepseek-v4-pro", "effort": "high" },
    "oc-deepseek": { "harness": "opencode", "auth": { "key": "deepseek" }, "keyVar": "DEEPSEEK_API_KEY", "model": "deepseek/deepseek-v4-pro" },
    "pi-glm": { "harness": "pi", "auth": { "key": "zai" }, "keyVar": "ZAI_API_KEY", "shares": "zai-coding-plan", "model": "zai/glm-5.3", "effort": "high" },
    "local-qwen": {
      "harness": "claude", "auth": "none", "endpoint": "http://127.0.0.1:9931", "model": "qwen3.8-27b",
      "env": { "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "131072", "CLAUDE_CODE_ATTRIBUTION_HEADER": "0" }, "maxParallel": 1
    }
  },
  "roles": {
    "plan-writer": ["sonnet-high"],
    "implementer": ["glm", "glm-api", "pi-glm", "deepseek-dsh"],
    "control-review": ["deepseek-claude", "glm-api"],
    "phase-review": ["claude-sub"]
  }
}
EOF
    run_ad route --all
    expected="$(cat <<'EOF'
route plan-writer: sonnet-high harness=inproc model=sonnet effort=high readOnly=- maxParallel=- (chain: sonnet-high)
route implementer: glm harness=zcode model=GLM-5.3-Flash effort=max readOnly=none maxParallel=2 (chain: glm, glm-api, pi-glm, deepseek-dsh)
route control-review: deepseek-claude harness=claude model=deepseek-v4-pro[1m] effort=high readOnly=tools maxParallel=2 (chain: deepseek-claude, glm-api)
EOF
)"
    [[ "$RC" -eq 0 && "$OUT" == "$expected" ]]
    verdict "5 route --all prints only the roles that differ from the built-in scheme (user roles replace the built-in chain)" $? "rc=$RC" "$(diff <(echo "$expected") <(echo "$OUT"))"
    run_ad route --all --json
    [[ "$RC" -eq 0 && "$(jfield default <<<"$OUT")" == false \
        && "$(node -e 'const j = JSON.parse(process.argv[1]); console.log(j.routes.map((r) => `${r.role}:${r.profile}:${r.chain.join("+")}`).join(" "))' -- "$OUT")" \
            == "plan-writer:sonnet-high:sonnet-high implementer:glm:glm+glm-api+pi-glm+deepseek-dsh control-review:deepseek-claude:deepseek-claude+glm-api" ]]
    verdict "5 route --all --json: {\"default\": false, \"routes\": [route objects of the differing roles]}" $? "rc=$RC out: $(head -c 400 <<<"$OUT")"
    run_ad route plan-reviewer
    [[ "$RC" -eq 0 && "$OUT" == "route plan-reviewer: astra harness=codex model=gpt-6-astra effort=xhigh readOnly=os maxParallel=2 (chain: astra)" ]]
    verdict "5 a role config.json does not name keeps its built-in chain" $? "out: $OUT"
    run_ad route plan-writer --json
    [[ "$RC" -eq 0 && "$(jfield profile <<<"$OUT")" == sonnet-high && "$(jfield model <<<"$OUT")" == sonnet && "$(jfield effort <<<"$OUT")" == high && "$(jfield inSession <<<"$OUT")" == true ]]
    verdict "5 route plan-writer returns the user's inproc profile sonnet-high (model sonnet, effort high for the Agent tool)" $? "out: $OUT"
    run_ad route phase-review
    [[ "$RC" -eq 0 && "$OUT" == "route phase-review: opus-high harness=inproc model=opus effort=high readOnly=- maxParallel=- (chain: opus-high)" \
        && "$(grep -c . <<<"$ERR")" -eq 1 && "$ERR" == *"note: route phase-review:"*"increment 6"*"claude-sub"* ]]
    verdict "5 an in-session role bound to an external profile still runs on its default profile, with one note line" $? "out: $OUT" "err: $ERR"

    run_ad route implementer --skip glm:quota
    [[ "$RC" -eq 0 && "$OUT" == "route implementer: deepseek-dsh harness=dsh model=deepseek-v4-pro effort=high readOnly=os maxParallel=2 (chain: deepseek-dsh; skipped: glm=quota, glm-api=quota(via glm), pi-glm=quota(via glm))" ]]
    verdict "5 --skip glm:quota also skips the profiles labelled zai-coding-plan (glm-api, pi-glm) and lists them in skipped" $? "rc=$RC out: $OUT"
    run_ad route implementer --skip glm:auth
    [[ "$RC" -eq 0 && "$OUT" == "route implementer: deepseek-dsh harness=dsh model=deepseek-v4-pro effort=high readOnly=os maxParallel=2 (chain: deepseek-dsh; skipped: glm=auth, glm-api=auth(via glm), pi-glm=auth(via glm))" ]]
    verdict "5 --skip glm:auth takes the linked profiles out too (auth links like quota)" $? "rc=$RC out: $OUT"
    run_ad route implementer --skip glm
    [[ "$RC" -eq 0 && "$OUT" == "route implementer: glm-api harness=claude model=glm-5.3[1m] effort=max readOnly=tools maxParallel=2 (chain: glm-api, pi-glm, deepseek-dsh; skipped: glm=down)" ]]
    verdict "5 --skip glm (no class: down) skips glm alone" $? "out: $OUT"
    run_ad route implementer --skip glm:timeout
    [[ "$RC" -eq 0 && "$OUT" == *"route implementer: glm-api "*"skipped: glm=timeout)" ]]
    verdict "5 --skip glm:timeout does not take the linked profiles out (only auth and quota do)" $? "out: $OUT"
    run_ad route implementer --skip deepseek-claude:quota --skip glm:server
    [[ "$RC" -eq 0 && "$OUT" == "route implementer: glm-api harness=claude model=glm-5.3[1m] effort=max readOnly=tools maxParallel=2 (chain: glm-api, pi-glm; skipped: glm=server, deepseek-dsh=quota(via deepseek-claude))" ]]
    verdict "5 a shared key links profiles: deepseek-claude:quota takes deepseek-dsh out (repeated --skip accumulate)" $? "out: $OUT"
    run_ad route control-review --skip deepseek-claude:quota,glm-api:auth
    [[ "$RC" -eq 2 && "$OUT" == "route control-review: no profile left (skipped: deepseek-claude=quota, glm-api=auth)" ]]
    verdict "5 an exhausted chain: exit 2 and 'route <role>: no profile left (skipped: …)'" $? "rc=$RC out: $OUT"
    run_ad route implementer --skip glm:quota --json
    [[ "$RC" -eq 0 && "$(jfield profile <<<"$OUT")" == deepseek-dsh && "$(jfield skipped.1.via <<<"$OUT")" == glm && "$(jfield chain <<<"$OUT")" == '["deepseek-dsh"]' ]]
    verdict "5 route --json carries profile, chain and skipped (with via)" $? "out: $OUT"
    run_ad route implementer --skip glm:nonsense
    ok=$RC
    run_ad route no-such-role
    [[ "$ok" -eq 2 && "$RC" -eq 2 ]]
    verdict "5 route refuses an unknown --skip class and an unknown role (exit 2)" $? "rc=$ok/$RC"

    no_config
    run_ad route implementer.risk --skip luna:quota
    [[ "$RC" -eq 2 && "$OUT" == "route implementer.risk: no profile left (skipped: sol=quota(via luna))" ]]
    verdict "5 the codex login links luna, sol, astra and astra-high: luna:quota leaves implementer.risk without a profile" $? "rc=$RC out: $OUT"

    write_config <<'EOF'
{ "version": 1, "roles": { "control-review": ["glm", "astra-high"] } }
EOF
    run_ad route control-review
    [[ "$RC" -eq 0 && "$OUT" == "route control-review: glm harness=zcode model=GLM-5.3-Flash effort=max readOnly=none maxParallel=2 (chain: glm, astra-high)" \
        && "$(grep -c . <<<"$ERR")" -eq 1 && "$ERR" == *"WARN route control-review: glm has no read-only mode"* ]]
    verdict "5 a reviewer role on glm: the route stands, with one WARN line (no read-only mode)" $? "rc=$RC out: $OUT err: $ERR"

    # final-review runs in the session first, then externally (spec §5.1): until increment 6 its chain starts in-session.
    write_config <<'EOF'
{
  "version": 1,
  "profiles": {
    "csub": { "harness": "claude", "auth": "login", "model": "opus", "effort": "xhigh" },
    "sonnet-high": { "harness": "inproc", "model": "sonnet", "effort": "high" }
  },
  "roles": { "final-review": ["csub", "astra"], "spec-reviewer": ["csub", "sonnet-high"] }
}
EOF
    run_ad route final-review
    [[ "$RC" -eq 0 && "$OUT" == "route final-review: opus-xhigh harness=inproc model=opus effort=xhigh readOnly=- maxParallel=- (chain: opus-xhigh, csub, astra)" \
        && "$(grep -c . <<<"$ERR")" -eq 1 && "$ERR" == "agent-dispatch: note: route final-review: final-review still starts in-session until increment 6: it runs on opus-xhigh first, then on csub, astra as the external fallback" ]]
    verdict "5 final-review whose chain starts on an external profile still starts in-session (built-in opus-xhigh), the external profiles follow, one note" $? "rc=$RC out: $OUT" "err: $ERR"
    run_ad route final-review --skip opus-xhigh
    [[ "$RC" -eq 0 && "$OUT" == "route final-review: csub harness=claude model=opus effort=xhigh readOnly=tools maxParallel=2 (chain: csub, astra; skipped: opus-xhigh=down)" ]]
    verdict "5 with the in-session stage skipped, final-review routes to the user's external fallback" $? "rc=$RC out: $OUT"
    run_ad route spec-reviewer
    [[ "$RC" -eq 0 && "$OUT" == "route spec-reviewer: csub harness=claude model=opus effort=xhigh readOnly=tools maxParallel=2 (chain: csub, sonnet-high)" && -z "$ERR" ]]
    verdict "5 an external role keeps its chain as written (no in-session guard)" $? "rc=$RC out: $OUT err: $ERR"
    write_config <<'EOF'
{ "version": 1, "profiles": { "sonnet-high": { "harness": "inproc", "model": "sonnet", "effort": "high" } },
  "roles": { "final-review": ["sonnet-high", "astra"] } }
EOF
    run_ad route final-review
    [[ "$RC" -eq 0 && "$OUT" == "route final-review: sonnet-high harness=inproc model=sonnet effort=high readOnly=- maxParallel=- (chain: sonnet-high, astra)" && -z "$ERR" ]]
    verdict "5 final-review on the user's own inproc profile first: as written, no note" $? "rc=$RC out: $OUT err: $ERR"

    # An opencode login is one login per provider: different providers are not linked (spec §3.5 "one login").
    write_config <<'EOF'
{
  "version": 1,
  "profiles": {
    "oc-copilot": { "harness": "opencode", "auth": "login", "model": "github-copilot/gpt-6-mini" },
    "oc-chatgpt": { "harness": "opencode", "auth": "login", "model": "openai/gpt-6-luna" },
    "oc-chatgpt2": { "harness": "opencode", "auth": "login", "model": "openai/gpt-6-sol" }
  },
  "roles": { "control-review": ["oc-copilot", "oc-chatgpt"] }
}
EOF
    run_ad route control-review --skip oc-copilot:quota
    ok=$RC
    local oc_route="$OUT"
    run_ad channels
    [[ "$ok" -eq 0 && "$oc_route" == "route control-review: oc-chatgpt harness=opencode model=openai/gpt-6-luna effort=- readOnly=rules maxParallel=2 (chain: oc-chatgpt; skipped: oc-copilot=quota)" \
        && "$OUT" == *"oc-copilot harness=opencode model=github-copilot/gpt-6-mini effort=- auth=login linked=- source=config"* \
        && "$OUT" == *"oc-chatgpt harness=opencode model=openai/gpt-6-luna effort=- auth=login linked=oc-chatgpt2 source=config"* ]]
    verdict "5 opencode logins of different providers are not linked (oc-copilot:quota leaves oc-chatgpt); the same provider is" $? "route rc=$ok: $oc_route" "$OUT"

    # A config that spells out the built-in scheme (and adds an unused profile) changes nothing.
    node -e '
const d = require(process.argv[1]);
const cfg = { version: 1, profiles: { "spare-sub": { harness: "claude", auth: "login", model: "opus" } }, roles: d.roles };
require("node:fs").writeFileSync(process.argv[2], JSON.stringify(cfg, null, 2));' -- "$DEFAULTS_JSON" "$CONFIG"
    run_ad route --all
    [[ "$RC" -eq 0 && "$OUT" == "routes: default" ]]
    verdict "5 route --all with a config.json equal to the built-in scheme prints 'routes: default'" $? "rc=$RC out: $OUT err: $ERR"

    # --- 6. config refusals: exit 2 and 'agent-dispatch: config: <path>: <problem>' ---
    # The config comes as an argument, not on a pipe: a function at the end of a pipe runs in a subshell, and its
    # verdict would not reach PASSES / FAILURES.
    refuse_config() { # <label> <expected problem substring> <config.json text>
        write_config <<<"$3"
        run_ad route implementer
        [[ "$RC" -eq 2 && "$ERR" == "agent-dispatch: config: $CONFIG: "*"$2"* ]]
        verdict "6 refused: $1" $? "rc=$RC err: $ERR"
    }
    local refusals_before="$PASSES"
    refuse_config "a broken config.json (invalid JSON)" "invalid JSON" '{ "version": 1, "profiles": {'
    refuse_config '"version": 1 missing' '"version": 1 is required' '{ "profiles": {} }'
    refuse_config "version 2" "unsupported version 2" '{ "version": 2 }'
    refuse_config "an unknown field, named (efort)" 'profile x: unknown field "efort"' \
        '{ "version": 1, "profiles": { "x": { "harness": "claude", "auth": "login", "efort": "high" } } }'
    refuse_config "an unknown option, named (toolz)" 'unknown option "toolz"' \
        '{ "version": 1, "profiles": { "x": { "harness": "claude", "options": { "toolz": "Read" } } } }'
    refuse_config "overriding the built-in glm" "profile glm is built in and cannot be overridden; copy it under a new name" \
        '{ "version": 1, "profiles": { "glm": { "harness": "zcode" } } }'
    refuse_config "the reserved name default" "profile name default is reserved" \
        '{ "version": 1, "profiles": { "default": { "harness": "claude" } } }'
    refuse_config "a name outside ^[a-z][a-z0-9-]{0,31}\$" 'invalid profile name "Bad_Name"' \
        '{ "version": 1, "profiles": { "Bad_Name": { "harness": "claude" } } }'
    refuse_config "a role naming a missing profile" 'roles.implementer: unknown profile "nope"' \
        '{ "version": 1, "roles": { "implementer": ["glm", "nope"] } }'
    refuse_config "an unknown role name" 'roles: unknown role "implementor"' \
        '{ "version": 1, "roles": { "implementor": ["glm"] } }'
    refuse_config 'a claude API profile with "home": "user"' "always uses its isolated home" \
        '{ "version": 1, "profiles": { "x": { "harness": "claude", "auth": { "key": "k" }, "home": "user" } } }'
    refuse_config "a field of another harness (endpoint on pi)" 'field "endpoint" does not apply to harness pi' \
        '{ "version": 1, "profiles": { "x": { "harness": "pi", "auth": "login", "endpoint": "https://e.example" } } }'
    refuse_config "an unfilled placeholder" "unfilled placeholder <model>" \
        '{ "version": 1, "profiles": { "x": { "harness": "opencode", "auth": "login", "model": "openai/<model>" } } }'
    refuse_config "a codex profile without effort" "needs model and effort" \
        '{ "version": 1, "profiles": { "x": { "harness": "codex", "model": "gpt-6-luna" } } }'
    refuse_config "an inproc profile without effort (the Agent tool needs both)" "an inproc profile needs model and effort" \
        '{ "version": 1, "profiles": { "x": { "harness": "inproc", "model": "sonnet" } } }'
    # spec §3.6 A1: the claude.ai login never meets a third-party endpoint.
    refuse_config "a claude login profile with an endpoint" "profile x: endpoint applies to claude API profiles only" \
        '{ "version": 1, "profiles": { "x": { "harness": "claude", "auth": "login", "endpoint": "https://api.deepseek.com/anthropic", "model": "deepseek-v4-pro" } } }'
    refuse_config "a claude profile with an endpoint and no auth (the default is login)" "profile x: endpoint applies to claude API profiles only" \
        '{ "version": 1, "profiles": { "x": { "harness": "claude", "endpoint": "https://api.deepseek.com/anthropic", "model": "deepseek-v4-pro", "authHeader": "x-api-key" } } }'
    refuse_config "a claude login profile with authHeader" "profile x: authHeader applies to claude API profiles only" \
        '{ "version": 1, "profiles": { "x": { "harness": "claude", "auth": "login", "authHeader": "bearer" } } }'
    [[ "$((PASSES - refusals_before))" -eq 18 ]]
    verdict "6 every config refusal above counted in this shell (18)" $? "counted: $((PASSES - refusals_before))"

    # A key pasted where its name belongs (auth.key, auth.keyEnv, keyVar) or unquoted into config.json is never echoed:
    # config problems reach stderr and, through the orchestrator, the chat (spec §3.5, §3.6 А11).
    local fake="sk-Test-$RANDOM-LEAKCHECK-0123456789abcdef" leaks=0 cfg
    for cfg in \
        "{ \"version\": 1, \"profiles\": { \"ds\": { \"harness\": \"claude\", \"auth\": { \"key\": \"$fake\" }, \"endpoint\": \"https://api.deepseek.com/anthropic\" } } }" \
        "{ \"version\": 1, \"profiles\": { \"ds\": { \"harness\": \"claude\", \"auth\": { \"keyEnv\": \"$fake\" }, \"endpoint\": \"https://api.deepseek.com/anthropic\" } } }" \
        "{ \"version\": 1, \"profiles\": { \"oc\": { \"harness\": \"opencode\", \"auth\": { \"key\": \"deepseek\" }, \"keyVar\": \"$fake\", \"model\": \"deepseek/x\" } } }" \
        "{ \"version\": 1, \"profiles\": { \"ds\": { \"harness\": \"claude\", \"auth\": { \"key\": $fake }, \"endpoint\": \"https://api.deepseek.com/anthropic\" } } }"; do
        write_config <<<"$cfg"
        for v in "route implementer" "status" "channels" "doctor" "profile list"; do
            # shellcheck disable=SC2086
            run_ad $v
            if [[ "$OUT$ERR" == *"sk-Test-"* || "$OUT$ERR" == *LEAKCHECK* || "$OUT$ERR" != *"config"* ]]; then
                leaks=1
                echo "    $v → rc=$RC out: $(head -c 300 <<<"$OUT") err: $ERR"
            fi
        done
    done
    write_config <<<"{ \"version\": 1, \"profiles\": { \"ds\": { \"harness\": \"claude\", \"auth\": { \"key\": \"$fake\" }, \"endpoint\": \"https://api.deepseek.com/anthropic\" } } }"
    run_ad route implementer
    [[ "$leaks" -eq 0 && "$RC" -eq 2 && "$ERR" == "agent-dispatch: config: $CONFIG: profile ds: auth.key is not a key name (expected "*"; the value is not echoed — auth.key names a key in the store; the key itself goes there with: agent-dispatch key set <name>)" ]]
    verdict "6 a key in auth.key / auth.keyEnv / keyVar or unquoted in the file is never echoed (route, status, channels, doctor, profile list)" $? "err: $ERR"
    no_config
    run_ad profile add ds --from claude-deepseek --key "$fake"
    local add_rc=$RC add_out="$OUT$ERR"
    run_ad profile add ds "$fake" --from claude-deepseek
    local add2_rc=$RC add2_out="$OUT$ERR"
    run_ad profile add ds --from claude-deepseek --set "auth.keyEnv=$fake"
    [[ "$add_rc" -eq 2 && "$add_out" == *"auth.key is not a key name"*"nothing written"* && "$add_out" != *LEAKCHECK* \
        && "$add2_rc" -eq 2 && "$add2_out" != *LEAKCHECK* && "$RC" -eq 2 && "$OUT$ERR" == *"auth.keyEnv is not a variable name"* && "$OUT$ERR" != *LEAKCHECK* && ! -e "$CONFIG" ]]
    verdict "6 profile add with a key in --key, as a stray argument or in --set auth.keyEnv: refused, the key not echoed, nothing written" $? "--key: rc=$add_rc $add_out" "stray: rc=$add2_rc $add2_out" "--set: rc=$RC $OUT$ERR"

    write_config <<<'{ "version": 1, "profiles": { "x": { "harness": "claude", "efort": "high" } } }'
    local verbs_ok=0 v
    for v in "task --profile glm --background --write --prompt-file $prompt" "status" "status ct-0001" "result zt-0001" "cancel task-abc" "release-stale" "route --all" "channels"; do
        # shellcheck disable=SC2086
        run_ad $v
        if [[ "$RC" -ne 2 || "$ERR" != "agent-dispatch: config: $CONFIG: profile x: unknown field \"efort\"" ]]; then
            verbs_ok=1
            echo "    $v → rc=$RC err: $ERR"
        fi
    done
    verdict "6 with a broken config.json task, status, result, cancel, release-stale, route and channels exit 2 with the config line" $verbs_ok
    run_ad doctor
    ok=$RC
    local doctor_err="$OUT"
    run_ad profile list
    local plist_rc=$RC plist="$OUT" plist_err="$ERR"
    run_ad key list
    [[ "$ok" -eq 1 && "$doctor_err" == *"FAIL config: $CONFIG: profile x: unknown field \"efort\""* && "$doctor_err" == *"doctor: FAIL"* \
        && "$plist_rc" -eq 0 && "$plist" == *"glm harness=zcode"* && "$plist_err" == *"config: $CONFIG"* && "$RC" -eq 0 ]]
    verdict "6 doctor (FAIL config, exit 1), profile list (built-ins + one stderr line) and key list still work with a broken config" $? "doctor rc=$ok" "profile list rc=$plist_rc err: $plist_err" "key list rc=$RC"

    # --- 7. key set / list / rm (spec §3.5) ---
    no_config
    rm -rf "$STATE/keys"
    OUT="$(printf 'sk-test-123\n' | ad key set zai 2>&1)"
    RC=$?
    [[ "$RC" -eq 0 && "$(cat "$STATE/keys/zai")" == sk-test-123 && "$(mode_of "$STATE/keys/zai")" == 600 && "$(mode_of "$STATE/keys")" == 700 && "$(mode_of "$STATE")" == 700 && "$OUT" == "key zai: stored in $STATE/keys/zai (mode 0600)" ]]
    verdict "7 key set reads one line from a pipe: keys/zai is 0600 in a 0700 dir, the newline is dropped" $? "rc=$RC out: $OUT mode: $(mode_of "$STATE/keys/zai")"
    run_ad key set zai sk-arg-999
    [[ "$RC" -eq 2 && "$ERR" == *"never as an argument"* && "$ERR" != *"sk-arg-999"* && "$(cat "$STATE/keys/zai")" == sk-test-123 ]]
    verdict "7 key set refuses a key given as an argument, without echoing it; nothing stored" $? "rc=$RC err: $ERR"
    OUT="$(printf 'pbpaste | key set\n' | ad key set k2 2>&1)"
    RC=$?
    [[ "$RC" -eq 2 && "$OUT" == *"is not one key"* && "$OUT" != *pbpaste* && ! -e "$STATE/keys/k2" ]]
    verdict "7 key set refuses input with spaces (a pasted command), describing only its shape" $? "rc=$RC out: $OUT"
    OUT="$(printf '' | ad key set k3 2>&1)"
    RC=$?
    [[ "$RC" -eq 2 && ! -e "$STATE/keys/k3" ]]
    verdict "7 key set refuses empty input" $? "rc=$RC out: $OUT"
    run_ad key set Bad_Name
    [[ "$RC" -eq 2 && "$ERR" != *Bad_Name* ]]
    verdict "7 key set refuses an invalid name without echoing it" $? "rc=$RC err: $ERR"
    printf 'sk-other-456\n' | ad key set deepseek >/dev/null 2>&1
    run_ad key list
    [[ "$RC" -eq 0 && "$OUT" == $'deepseek\nzai' && "$OUT" != *sk-* ]]
    verdict "7 key list prints the names only" $? "out: $OUT"
    run_ad key rm deepseek
    ok=$RC
    run_ad key rm deepseek
    [[ "$ok" -eq 0 && "$RC" -eq 2 && ! -e "$STATE/keys/deepseek" && "$(ad key list)" == zai ]]
    verdict "7 key rm removes a key; removing it again is refused" $? "rc=$ok/$RC"

    # --- 8. core tasks through the stand-in claude adapter: keys, redaction, refusals ---
    write_config <<'EOF'
{
  "version": 1,
  "profiles": {
    "ct-api": { "harness": "claude", "auth": { "key": "tkey" }, "endpoint": "http://127.0.0.1:9", "model": "stub-model" },
    "ct-env": { "harness": "claude", "auth": { "keyEnv": "TEST_KEY_VAR" }, "endpoint": "http://127.0.0.1:9" },
    "ct-cmd": { "harness": "claude", "auth": { "keyCmd": ["node", "-e", "process.stdout.write(['cmd', 'key', 'value', '777'].join('-') + '\\n')"] }, "endpoint": "http://127.0.0.1:9" },
    "ct-literal": { "harness": "claude", "auth": { "keyCmd": ["node", "-e", "process.stdout.write('lit-key-value-555')"] }, "endpoint": "http://127.0.0.1:9" },
    "ct-cmdfail": { "harness": "claude", "auth": { "keyCmd": ["node", "-e", "process.exit(3)"] }, "endpoint": "http://127.0.0.1:9" },
    "ct-sub": { "harness": "claude", "auth": "login", "maxParallel": 1 },
    "ct-w": { "harness": "claude", "auth": "login", "maxParallel": 4 },
    "ct-conflict": { "harness": "claude", "auth": "login", "env": { "PLAIN_SAFE": "0" } },
    "oc-x": { "harness": "opencode", "auth": "login", "model": "a/b" },
    "dsh-x": { "harness": "dsh", "auth": { "key": "dkey" }, "model": "deepseek-v4-pro" }
  }
}
EOF
    run_ad task --profile ct-api --background --prompt-file "$prompt"
    [[ "$RC" -eq 2 && "$ERR" == "agent-dispatch: ct-api: key unavailable (no key tkey is stored; the user stores it: agent-dispatch key set tkey) errorClass=auth" && "$(count_records "$JOBS")" -eq 0 ]]
    verdict "8 a missing stored key: exit 2 'agent-dispatch: ct-api: key unavailable (…) errorClass=auth', no job left" $? "rc=$RC err: $ERR records: $(count_records "$JOBS")"
    key="tkey-secret-$RANDOM-value"
    printf '%s\n' "$key" | ad key set tkey >/dev/null 2>&1
    reset_wrappers
    run_ad task --profile ct-api --role control-review --background --prompt-file "$prompt"
    id="${OUT##* }"
    local api_id="$id"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    [[ "$RC" -eq 0 && "$OUT" == "agent-dispatch: ct-api task started in the background as ct-0001" && "$st" == completed ]]
    verdict "8 a core task prints 'agent-dispatch: <P> task started in the background as ct-0001' and completes" $? "rc=$RC out: $OUT err: $ERR status: $st"
    run_ad status "$id" --json
    [[ "$(jfield job.profile <<<"$OUT")" == ct-api && "$(jfield job.harness <<<"$OUT")" == claude && "$(jfield job.role <<<"$OUT")" == control-review ]]
    verdict "8 status <ct-id> --json carries job.profile and job.harness" $? "out: $(head -c 300 <<<"$OUT")"

    export AGENT_STUB_MODE=leak-secret
    run_ad task --profile ct-api --background --prompt-file "$prompt"
    id="${OUT##* }"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    run_ad result "$id"
    unset AGENT_STUB_MODE
    [[ "$st" == completed && "$OUT" == *"<redacted>"* && "$OUT" != *"$key"* ]] && ! grep -rqF "$key" "$STATE" --exclude-dir=keys
    verdict "8 the stored key never shows: the harness echoed it, result and every file under the data root hold <redacted>" $? "status: $st out: $OUT" "hits: $(grep -rlF "$key" "$STATE" --exclude-dir=keys | tr '\n' ' ')"

    run_ad task --profile ct-env --background --prompt-file "$prompt"
    ok=$RC
    local env_err="$ERR"
    export TEST_KEY_VAR="env-key-$RANDOM-x"
    run_ad task --profile ct-env --background --prompt-file "$prompt"
    id="${OUT##* }"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    unset TEST_KEY_VAR
    [[ "$ok" -eq 2 && "$env_err" == *'ct-env: key unavailable ($TEST_KEY_VAR is not set'*'errorClass=auth' && "$RC" -eq 0 && "$st" == completed ]]
    verdict "8 auth keyEnv: unset → key unavailable errorClass=auth; set → the task runs" $? "rc=$ok err: $env_err" "rc=$RC status: $st"

    export AGENT_STUB_MODE=leak-secret
    run_ad task --profile ct-cmd --background --prompt-file "$prompt"
    id="${OUT##* }"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    run_ad result "$id"
    unset AGENT_STUB_MODE
    [[ "$st" == completed && "$OUT" == *"<redacted>"* && "$OUT" != *cmd-key-value-777* ]] && ! grep -rqF cmd-key-value-777 "$STATE"
    verdict "8 auth keyCmd: its stdout is the key (trimmed), redacted everywhere" $? "status: $st out: $OUT"
    run_ad task --profile ct-literal --background --prompt-file "$prompt"
    [[ "$RC" -eq 2 && "$ERR" == *"ct-literal: a profile field holds the key itself"* && "$ERR" != *lit-key-value-555* ]]
    verdict "8 a key that also appears literally in the profile (here in the keyCmd argv) is refused without echoing it" $? "rc=$RC err: $ERR"
    run_ad task --profile ct-cmdfail --background --prompt-file "$prompt"
    [[ "$RC" -eq 2 && "$ERR" == "agent-dispatch: ct-cmdfail: key unavailable (keyCmd node exited 3) errorClass=auth" ]]
    verdict "8 a failing keyCmd: exit 2 key unavailable errorClass=auth, no launch" $? "rc=$RC err: $ERR"

    run_ad task --profile oc-x --background --prompt-file "$prompt"
    ok=$RC
    local oc_err="$ERR"
    run_ad task --profile dsh-x --background --prompt-file "$prompt"
    [[ "$ok" -eq 2 && "$oc_err" == *"harness opencode is not available in this version"* && "$RC" -eq 2 && "$ERR" == *"harness dsh is not available in this version"* ]]
    verdict "8 opencode and dsh profiles: 'harness <h> is not available in this version' (exit 2)" $? "oc: $oc_err" "dsh: $ERR"
    run_ad task --profile opus-high --role frontend.new-ui --background --prompt-file "$prompt"
    [[ "$RC" -eq 2 && "$ERR" == *"runs in-session (harness inproc)"*"Agent tool"*"model=opus effort=high"* ]]
    verdict "8 an inproc profile: task refused (exit 2), pointing at the Agent tool with model and effort" $? "err: $ERR"
    run_ad task --profile ct-w --role no-such-role --background --prompt-file "$prompt"
    ok=$RC
    run_ad task --profile ct-w --prompt-file "$prompt"
    [[ "$ok" -eq 2 && "$RC" -eq 2 && "$ERR" == *"requires --background"* ]]
    verdict "8 task refuses an unknown --role and a missing --background" $? "rc=$ok/$RC err: $ERR"

    # Resume through the CLI (spec §3.6 А12, §5.3 item 6): a core id resumes on its own profile only.
    run_ad task --profile ct-w --background --prompt-file "$prompt"
    local r1="${OUT##* }" sess sj
    wait_status "$r1" 'completed|failed|cancelled' 20 >/dev/null
    sess="$(ad status "$r1" --json | jfield job.sessionId)"
    export AGENT_STUB_MODE=resume
    run_ad task --profile ct-w --background --resume-task "$r1" --prompt-file "$prompt"
    unset AGENT_STUB_MODE
    id="${OUT##* }"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    sj="$(ad status "$id" --json)"
    [[ -n "$sess" && "$id" == ct-* && "$st" == completed && "$(jfield job.resumeOf <<<"$sj")" == "$r1" && "$(jfield job.sessionId <<<"$sj")" == "$sess" \
        && "$(ad result "$id")" == "DONE"$'\n'"resumed $sess" ]]
    verdict "8 task --profile P --resume-task <ct-id of P> reaches the core: the job resumes that session (job.resumeOf)" $? "first=$r1 session=$sess" "resumed=$id status=$st resumeOf=$(jfield job.resumeOf <<<"$sj")"
    n="$(count_records "$JOBS")"
    run_ad task --profile ct-w --background --resume-task zt-0001 --prompt-file "$prompt"
    local rc_z="$RC" err_z="$ERR"
    run_ad task --profile ct-w --background --resume-task task-abc --prompt-file "$prompt"
    local rc_t="$RC" err_t="$ERR"
    run_ad task --profile ct-w --background --resume-task "$api_id" --prompt-file "$prompt"
    [[ "$rc_z" -eq 2 && "$err_z" == *"zt-0001"*"dispatch --fresh" && "$rc_t" -eq 2 && "$err_t" == *"task-abc"*"dispatch --fresh" \
        && "$RC" -eq 2 && "$ERR" == "agent-dispatch: job $api_id ran on profile ct-api, not ct-w; ids do not move between profiles; dispatch --fresh" \
        && "$(count_records "$JOBS")" -eq "$n" ]]
    verdict "8 a core profile refuses a zt- / task- id and a ct- id of another profile (exit 2, 'dispatch --fresh', no job)" $? "zt-: rc=$rc_z err: $err_z" "task-: rc=$rc_t err: $err_t" "ct-api id: rc=$RC err: $ERR"

    # --- 9. maxParallel (spec §3.9) ---
    export AGENT_STUB_MODE=slow AGENT_STUB_DELAY_MS=20000
    run_ad task --profile ct-sub --background --prompt-file "$prompt"
    id="${OUT##* }"
    run_ad task --profile ct-sub --background --cwd "$repo2" --prompt-file "$prompt"
    unset AGENT_STUB_MODE AGENT_STUB_DELAY_MS
    [[ "$RC" -eq 2 && "$ERR" == "agent-dispatch: profile ct-sub is at maxParallel=1 (running: $id)" ]]
    verdict "9 maxParallel=1: a second task of the profile (any tree) is refused, naming the running one" $? "rc=$RC err: $ERR first: $id"
    run_ad cancel "$id"
    [[ "$RC" -eq 0 && "$OUT" == "cancelled $id" && "$(wait_status "$id" 'cancelled' 10)" == cancelled ]]
    verdict "9 cancel <ct-id> goes to the core: the job is cancelled" $? "rc=$RC out: $OUT"

    # --- 10. one write task per working tree, across the three stores (spec §3.9) ---
    export AGENT_STUB_MODE=slow AGENT_STUB_DELAY_MS=20000
    run_ad task --profile ct-w --background --write --prompt-file "$prompt"
    id="${OUT##* }"
    unset AGENT_STUB_MODE AGENT_STUB_DELAY_MS
    reset_wrappers
    run_ad task --profile ct-w --background --write --prompt-file "$prompt"
    [[ "$RC" -eq 2 && "$ERR" == "agent-dispatch: job $id is still running in this workspace; one write task per working tree" ]]
    verdict "10 a second core write task in the same tree is refused, naming the first" $? "rc=$RC err: $ERR"
    run_ad task --profile luna --background --write --prompt-file "$prompt"
    ok=$RC
    local luna_err="$ERR"
    run_ad task --profile glm --background --write --prompt-file "$prompt"
    [[ "$ok" -eq 2 && "$luna_err" == "agent-dispatch: job $id (ct-w) is still running in this workspace; one write task per working tree" \
        && "$RC" -eq 2 && "$ERR" == *"job $id (ct-w) is still running"* && "$(calls_of codex-dispatch task)" -eq 0 && "$(calls_of zcode-dispatch task)" -eq 0 ]]
    verdict "10 luna --write and glm are refused while a core write job runs in the tree; no wrapper task is started" $? "luna: $luna_err" "glm: $ERR"
    run_ad task --profile glm --background --prompt-file "$prompt"
    [[ "$RC" -eq 2 && "$ERR" == "agent-dispatch: job $id (ct-w) is still running in this workspace; one write task per working tree" && "$(calls_of zcode-dispatch task)" -eq 0 ]]
    verdict "10 glm without --write takes the write check too (zcode-dispatch always writes): refused, no zcode-dispatch task" $? "rc=$RC err: $ERR"
    run_ad task --profile astra --role plan-reviewer --background --prompt-file "$prompt"
    ok=$RC
    run_ad task --profile ct-w --background --cwd "$repo2" --write --prompt-file "$prompt"
    id2="${OUT##* }"
    [[ "$ok" -eq 0 && "$(calls_of codex-dispatch task)" -eq 1 && "$RC" -eq 0 && "$id2" == ct-* ]]
    verdict "10 a read-only reviewer and a write task in another tree are not blocked" $? "astra rc=$ok, repo2 rc=$RC out: $OUT err: $ERR"
    ad cancel "$id" >/dev/null 2>&1
    ad cancel "$id2" --cwd "$repo2" >/dev/null 2>&1
    wait_status "$id" cancelled 10 >/dev/null
    wait_status "$id2" cancelled 10 --cwd "$repo2" >/dev/null

    reset_wrappers
    can zcode-dispatch status stdout "{\"workspaceRoot\":\"$repo\",\"running\":[{\"id\":\"zt-0009\",\"status\":\"running\",\"workspaceRoot\":\"$repo\",\"runnerPid\":1}],\"recent\":[]}"
    run_ad task --profile ct-w --background --write --prompt-file "$prompt"
    ok=$RC
    local zt_err="$ERR"
    run_ad task --profile luna --background --write --prompt-file "$prompt"
    [[ "$ok" -eq 2 && "$zt_err" == "agent-dispatch: job zt-0009 (glm) is still running in this workspace; one write task per working tree" \
        && "$RC" -eq 2 && "$ERR" == *"job zt-0009 (glm) is still running"* && "$(calls_of codex-dispatch task)" -eq 0 ]]
    verdict "10 a running ZCode job (zcode-dispatch status --json) blocks a core and a codex write task" $? "core: $zt_err" "luna: $ERR"

    # One write task per working TREE: each wrapper is asked about the task's tree (status --json --cwd <root>; the
    # stub answers for that tree only, like the wrappers), so a ZCode job in repo2 blocks repo2 and not repo.
    reset_wrappers
    can zcode-dispatch status stdout "{\"workspaceRoot\":\"$repo2\",\"running\":[{\"id\":\"zt-0010\",\"status\":\"running\",\"workspaceRoot\":\"$repo2\",\"runnerPid\":1}],\"recent\":[]}"
    run_ad task --profile luna --background --write --prompt-file "$prompt"
    local luna_rc=$RC luna_wc
    luna_wc="$(last_call zcode-dispatch status)"
    run_ad task --profile ct-w --background --write --prompt-file "$prompt"
    local core_rc=$RC core_id="${OUT##* }"
    st="$(wait_status "$core_id" 'completed|failed|cancelled' 20)"
    [[ "$luna_rc" -eq 0 && "$luna_wc" == "$(jarr status --json --cwd "$repo")" && "$(calls_of codex-dispatch task)" -eq 1 && "$core_rc" -eq 0 && "$st" == completed ]]
    verdict "10 a ZCode write job in repo2 does not block a luna or a core write task in repo (the write check asks 'status --json --cwd <repo>')" $? "luna rc=$luna_rc check argv: $luna_wc" "core rc=$core_rc id=$core_id status=$st"
    run_ad task --profile luna --background --write --cwd "$repo2" --prompt-file "$prompt"
    local luna2_rc=$RC luna2_err="$ERR"
    run_ad task --profile ct-w --background --write --cwd "$repo2" --prompt-file "$prompt"
    [[ "$luna2_rc" -eq 2 && "$luna2_err" == "agent-dispatch: job zt-0010 (glm) is still running in this workspace; one write task per working tree" \
        && "$RC" -eq 2 && "$ERR" == "$luna2_err" && "$(last_call zcode-dispatch status)" == "$(jarr status --json --cwd "$repo2")" && "$(calls_of codex-dispatch task)" -eq 1 ]]
    verdict "10 the same ZCode job blocks luna and core write tasks with --cwd repo2 (asked with 'status --json --cwd <repo2>')" $? "luna: rc=$luna2_rc $luna2_err" "core: rc=$RC $ERR" "check argv: $(last_call zcode-dispatch status)"

    reset_wrappers
    node -e 'setTimeout(() => {}, 120000)' -- "$TEST_ROOT/live-worker" &
    local live=$!
    node -e 'process.exit(0)' -- "$TEST_ROOT/dead-worker" &
    local dead=$!
    wait "$dead" 2>/dev/null
    can codex-dispatch status stdout "{\"workspaceRoot\":\"$repo\",\"running\":[{\"id\":\"task-live1\",\"status\":\"running\",\"write\":true,\"pid\":$live,\"workspaceRoot\":\"$repo\",\"request\":{\"model\":\"gpt-6-luna\",\"effort\":\"max\"}}],\"latestFinished\":null,\"recent\":[]}"
    run_ad task --profile ct-w --background --write --prompt-file "$prompt"
    ok=$RC
    local live_err="$ERR"
    run_ad task --profile glm --background --write --prompt-file "$prompt"
    [[ "$ok" -eq 2 && "$live_err" == "agent-dispatch: job task-live1 (luna) is still running in this workspace; one write task per working tree" \
        && "$RC" -eq 2 && "$ERR" == *"task-live1 (luna)"* && "$(calls_of zcode-dispatch task)" -eq 0 ]]
    verdict "10 a companion write job whose worker pid lives blocks a core and a glm write task" $? "core: $live_err" "glm: $ERR"
    kill "$live" 2>/dev/null
    wait "$live" 2>/dev/null
    can codex-dispatch status stdout "{\"workspaceRoot\":\"$repo\",\"running\":[{\"id\":\"task-dead1\",\"status\":\"queued\",\"write\":true,\"pid\":$dead,\"workspaceRoot\":\"$repo\"}],\"latestFinished\":null,\"recent\":[]}"
    run_ad task --profile glm --background --write --prompt-file "$prompt"
    [[ "$RC" -eq 0 && "$(calls_of zcode-dispatch task)" -eq 1 && "$(grep -c . <<<"$ERR")" -eq 1 && "$ERR" == *"WARN write check: task-dead1"*"not alive; not blocking"* ]]
    verdict "10 a companion write job with a dead worker does not block: one warning line, the task starts" $? "rc=$RC err: $ERR"

    # A live companion write job of ANOTHER Claude session. The companion (and the stub) filters `status --json` by
    # $CODEX_COMPANION_SESSION_ID: the write check queries the store without it; merged status, real dispatches and
    # id-addressed pass-through keep it (merged status lists what `codex-dispatch status` lists).
    reset_wrappers
    node -e 'setTimeout(() => {}, 120000)' -- "$TEST_ROOT/live-worker-a" &
    local live_a=$!
    can codex-dispatch status stdout "{\"workspaceRoot\":\"$repo\",\"running\":[{\"id\":\"task-sessa1\",\"status\":\"running\",\"write\":true,\"pid\":$live_a,\"sessionId\":\"sess-A\",\"workspaceRoot\":\"$repo\",\"request\":{\"model\":\"gpt-6-luna\",\"effort\":\"max\"}}],\"latestFinished\":null,\"recent\":[]}"
    export CODEX_COMPANION_SESSION_ID=sess-B
    local filtered
    filtered="$("$AGENT_DISPATCH_CODEX" status --json --cwd "$repo" | jfield running)"
    : >"$WRAPPER_STUB_DIR/codex-dispatch.session"
    run_ad task --profile glm --background --write --prompt-file "$prompt"
    ok=$RC
    local sess_err="$ERR"
    run_ad status
    local sess_status="$OUT" sess_status_rc=$RC
    run_ad task --profile luna --background --write --prompt-file "$prompt"
    local luna_rc=$RC
    run_ad status task-sessa1
    run_ad result task-sessa1
    run_ad cancel task-sessa1
    unset CODEX_COMPANION_SESSION_ID
    [[ "$filtered" == '[]' && "$ok" -eq 2 && "$sess_err" == "agent-dispatch: job task-sessa1 (luna) is still running in this workspace; one write task per working tree" \
        && "$(calls_of zcode-dispatch task)" -eq 0 ]]
    verdict "10 a live companion write job of another session (CODEX_COMPANION_SESSION_ID differs) blocks a glm write task" $? "stub's own filtered view: $filtered" "rc=$ok err: $sess_err"
    [[ "$sess_status_rc" -eq 0 && "$sess_status" != *task-sessa1* ]]
    verdict "10 merged status stays scoped to this session, like codex-dispatch status: the other session's job is not listed" $? "$sess_status"
    local expected_sessions
    expected_sessions="$(printf '%s\n' 'status -' 'status sess-B' 'task sess-B' 'status sess-B' 'result sess-B' 'cancel sess-B')"
    [[ "$luna_rc" -eq 0 && "$(cat "$WRAPPER_STUB_DIR/codex-dispatch.session")" == "$expected_sessions" ]]
    verdict "10 only the write check drops CODEX_COMPANION_SESSION_ID; merged status, the codex task and status/result/cancel <task-…> keep it" $? "luna rc=$luna_rc" "$(cat "$WRAPPER_STUB_DIR/codex-dispatch.session")"
    kill "$live_a" 2>/dev/null
    wait "$live_a" 2>/dev/null

    # --- 11. status without an id merges the three stores ---
    reset_wrappers
    can zcode-dispatch status stdout "{\"workspaceRoot\":\"$repo\",\"running\":[{\"id\":\"zt-0009\",\"status\":\"running\",\"workspaceRoot\":\"$repo\"}],\"recent\":[{\"id\":\"zt-0008\",\"status\":\"failed\",\"errorClass\":\"quota\",\"workspaceRoot\":\"$repo\"}]}"
    can codex-dispatch status stdout "{\"workspaceRoot\":\"$repo\",\"running\":[{\"id\":\"task-run1\",\"status\":\"running\",\"write\":true,\"workspaceRoot\":\"$repo\",\"request\":{\"model\":\"gpt-6.1-sol\",\"effort\":\"xhigh\"}}],\"latestFinished\":{\"id\":\"task-done1\",\"status\":\"completed\",\"write\":false,\"workspaceRoot\":\"$repo\",\"request\":{\"model\":\"gpt-6-astra\",\"effort\":\"high\"}},\"recent\":[]}"
    run_ad status
    ok=0
    # $core_id is this tree's newest core job (section 10): `status` without --all lists the 10 newest finished ones.
    for line in "zt-0009 glm running write=yes cwd=$repo" "task-run1 sol running write=yes cwd=$repo" "zt-0008 glm failed write=yes cwd=$repo" \
        "task-done1 astra-high completed write=no cwd=$repo" "$core_id ct-w completed write=yes cwd=$repo"; do
        grep -qxF "$line" <<<"$OUT" || { ok=1; echo "    missing: $line"; }
    done
    n="$(grep -c . <<<"$OUT")"
    [[ "$RC" -eq 0 && "$ok" -eq 0 && "$(head -2 <<<"$OUT" | grep -c ' running ')" -eq 2 && -z "$ERR" ]]
    verdict "11 status lists core, zcode and companion jobs as '<id> <profile> <status> write=<yes|no> cwd=<root>', running first" $? "rc=$RC lines=$n" "$OUT" "err: $ERR"
    [[ "$(last_call zcode-dispatch status)" == '["status","--json"]' && "$(last_call codex-dispatch status)" == '["status","--json"]' ]]
    verdict "11 the stores are read through '<wrapper> status --json'" $? "z: $(last_call zcode-dispatch status) c: $(last_call codex-dispatch status)"
    run_ad status --all
    [[ "$RC" -eq 0 && "$(last_call zcode-dispatch status)" == '["status","--json","--all"]' && "$(last_call codex-dispatch status)" == '["status","--json","--all"]' \
        && "$OUT" == *"$api_id ct-api completed write=no cwd=$repo"* ]]
    verdict "11 status --all reaches both wrappers as 'status --json --all' and lists every core job (the first one included)" $? "z: $(last_call zcode-dispatch status) c: $(last_call codex-dispatch status)" "$OUT"
    run_ad status --json
    [[ "$RC" -eq 0 && "$(node -e 'const j = JSON.parse(process.argv[1]); console.log(j.jobs.map((x) => `${x.id}:${x.profile}:${x.harness}:${x.write}`).sort().join(" "))' -- "$OUT")" == *"task-done1:astra-high:codex:false"*"zt-0009:glm:zcode:true"* ]]
    verdict "11 status --json prints {\"jobs\": […]} with id, profile, harness, status, write, cwd" $? "out: $(head -c 400 <<<"$OUT")"
    can zcode-dispatch status stdout ""
    can zcode-dispatch status stderr "boom"$'\n'
    can zcode-dispatch status exit 1
    run_ad status --cwd "$repo"
    [[ "$RC" -eq 0 && "$ERR" == "agent-dispatch: status: zcode-dispatch store skipped (zcode-dispatch status --json exited 1: boom)" && "$OUT" == *"task-run1 sol running"* && "$OUT" != *zt-0009* \
        && "$(last_call codex-dispatch status)" == "$(jarr status --json --cwd "$repo")" ]]
    verdict "11 a store whose wrapper fails is one stderr line, not fatal; --cwd reaches the wrappers" $? "rc=$RC err: $ERR" "$OUT"

    reset_wrappers
    export AGENT_STUB_MODE=exit0-error AGENT_STUB_CLASS=quota AGENT_STUB_MESSAGE="insufficient balance"
    run_ad task --profile ct-w --background --prompt-file "$prompt"
    id="${OUT##* }"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    unset AGENT_STUB_MODE AGENT_STUB_CLASS AGENT_STUB_MESSAGE
    run_ad result "$id"
    [[ "$st" == failed && "$RC" -eq 1 && -z "$OUT" && "$ERR" == "job $id is failed errorClass=quota"* ]]
    verdict "11 result of a failed core job: exit 1, 'job <id> is failed errorClass=<class>' and the log tail on stderr" $? "status=$st rc=$RC err: $(head -2 <<<"$ERR")"
    run_ad release-stale
    [[ "$RC" -eq 2 && "$ERR" == "agent-dispatch: workspace reservation generation "*" is already released" ]]
    verdict "11 release-stale reaches the core (the last reservation is already released: exit 2)" $? "rc=$RC err: $ERR"
    mkdir -p "$TEST_ROOT/fresh" && git init -q -b main "$TEST_ROOT/fresh"
    run_ad release-stale --cwd "$TEST_ROOT/fresh"
    [[ "$RC" -eq 2 && "$ERR" == "agent-dispatch: no workspace reservation to release" ]]
    verdict "11 release-stale in a tree that never had a write job: 'no workspace reservation to release' (exit 2)" $? "rc=$RC err: $ERR"

    # --- 12. channels, profile, preset ---
    run_ad channels
    [[ "$RC" -eq 0 && "$OUT" == *"luna harness=codex model=gpt-6-luna effort=max auth=login linked=astra,astra-high,sol source=built-in"* \
        && "$OUT" == *"ct-api harness=claude model=stub-model effort=- auth=key:tkey linked=- source=config"* \
        && "$OUT" == *"glm harness=zcode model=GLM-5.3-Flash effort=max auth=native linked=- source=built-in"* ]]
    verdict "12 channels: every profile with harness, model, key or login source and its linked profiles" $? "$OUT"
    run_ad channels --json
    [[ "$RC" -eq 0 && "$(node -e '
const j = JSON.parse(process.argv[1]);
const luna = j.profiles.find((p) => p.name === "luna");
const api = j.profiles.find((p) => p.name === "ct-api");
const keys = Object.keys(j).join(",") + "|" + Object.keys(luna).join(",");
console.log([keys, JSON.stringify(luna.linked), luna.auth, luna.source, api.auth, api.harness, String(api.shares)].join(" "));' -- "$OUT")" \
        == 'profiles|name,harness,model,effort,auth,shares,linked,source ["astra","astra-high","sol"] login built-in key:tkey claude null' ]]
    verdict "12 channels --json: {\"profiles\": [{name, harness, model, effort, auth, shares, linked, source}]}" $? "rc=$RC out: $(head -c 400 <<<"$OUT")"

    run_ad preset list
    n="$(grep -c . <<<"$OUT")"
    [[ "$RC" -eq 0 && "$n" -eq 12 && "$OUT" == *"claude-zai harness=claude auth=key:zai model=glm-5.3[1m] endpoint=https://api.z.ai/api/anthropic shares=zai-coding-plan"* \
        && "$OUT" == *"opencode-key harness=opencode auth=key:<name> model=<provider/model> keyVar=<VAR> (fill: <name> <VAR> <provider/model>)"* ]]
    verdict "12 preset list: the 12 presets of §4.2 with their placeholders" $? "lines=$n" "$OUT"

    no_config
    run_ad profile add glm-api --from claude-zai --set effort=max
    [[ "$RC" -eq 0 && "$(mode_of "$CONFIG")" == 600 && "$(jfield version <"$CONFIG")" == 1 && "$(jfield profiles.glm-api.endpoint <"$CONFIG")" == "https://api.z.ai/api/anthropic" && "$(jfield profiles.glm-api.effort <"$CONFIG")" == max ]]
    verdict "12 profile add --from claude-zai writes config.json (version 1, mode 0600) with the preset and the --set" $? "rc=$RC out: $OUT err: $ERR"
    run_ad profile show glm-api
    [[ "$RC" -eq 0 && "$(jfield profile.home <<<"$OUT")" == isolated && "$(jfield profile.sandbox <<<"$OUT")" == off && "$(jfield profile.timeoutMin <<<"$OUT")" == 60 \
        && "$(jfield profile.maxParallel <<<"$OUT")" == 2 && "$(jfield linked <<<"$OUT")" == '["glm"]' && "$(jfield source <<<"$OUT")" == config ]]
    verdict "12 profile show: the §3.4 defaults (home isolated for a claude key, sandbox off, timeoutMin 60, maxParallel 2) and glm linked by zai-coding-plan" $? "$OUT"
    before="$(cat "$CONFIG")"
    run_ad profile add oc1 --from opencode-key
    [[ "$RC" -eq 2 && "$ERR" == *"fill the placeholder(s) <name> <VAR> <provider/model>"*"nothing written"* && "$(cat "$CONFIG")" == "$before" ]]
    verdict "12 profile add with unfilled <…> is refused (exit 2) and nothing is written" $? "rc=$RC err: $ERR"
    run_ad profile add oc1 --from opencode-key --key deepseek --set keyVar=DEEPSEEK_API_KEY --model deepseek/deepseek-v4-pro
    [[ "$RC" -eq 0 && "$(jfield profiles.oc1.auth.key <"$CONFIG")" == deepseek && "$(jfield profiles.oc1.keyVar <"$CONFIG")" == DEEPSEEK_API_KEY ]]
    verdict "12 profile add fills the placeholders through --key, --set and --model" $? "rc=$RC err: $ERR"
    run_ad profile add lq --from claude-local --model qwen3.8-27b --set endpoint=http://127.0.0.1:9931 --set maxParallel= --set timeoutMin= \
        --set options.maxTurns=5 --set options.maxTurns= --set env.ANTHROPIC_API_KEY=
    [[ "$RC" -eq 0 && "$(node -e '
const p = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).profiles.lq;
console.log(["maxParallel" in p, "timeoutMin" in p, "options" in p, p.env.ANTHROPIC_API_KEY === "", p.endpoint].join(" "));' -- "$CONFIG")" == "false false false true http://127.0.0.1:9931" ]]
    verdict "12 profile add --set k= removes the field or option (the preset's maxParallel included); env.X= stays an empty string" $? "rc=$RC err: $ERR" "$(jfield profiles.lq <"$CONFIG")"
    run_ad profile add glm --from claude-zai
    ok=$RC
    run_ad profile add x1 --from no-such-preset
    local rc_np=$RC
    run_ad profile add x2 --from claude-sub --set efort=high
    [[ "$ok" -eq 2 && "$rc_np" -eq 2 && "$RC" -eq 2 && "$ERR" == *'unknown field "efort"'* ]]
    verdict "12 profile add refuses a built-in name, an unknown preset and an unknown field" $? "rc=$ok/$rc_np/$RC err: $ERR"
    run_ad profile env glm-api
    [[ "$RC" -eq 0 && "$OUT" == "export CLAUDE_CONFIG_DIR='$STATE/homes/glm-api/claude'" && "$(mode_of "$STATE/homes/glm-api/claude")" == 700 ]]
    verdict "12 profile env prints the export lines of the profile's isolated home (created 0700)" $? "rc=$RC out: $OUT"
    run_ad profile env oc1
    [[ "$RC" -eq 0 && "$(grep -c '^export XDG_' <<<"$OUT")" -eq 4 ]]
    verdict "12 profile env of an opencode key profile exports XDG_CONFIG/DATA/STATE/CACHE_HOME" $? "$OUT"
    run_ad profile env glm
    ok=$RC
    run_ad profile list
    [[ "$ok" -eq 2 && "$RC" -eq 0 && "$OUT" == *"glm-api harness=claude model=glm-5.3[1m] effort=max source=config"* && "$OUT" == *"luna harness=codex model=gpt-6-luna effort=max source=built-in"* ]]
    verdict "12 profile env refuses a pass-through profile; profile list shows built-in and config profiles" $? "rc=$ok/$RC" "$OUT"
    run_ad profile list --json
    [[ "$RC" -eq 0 && "$(node -e '
const j = JSON.parse(process.argv[1]);
const g = j.profiles.find((p) => p.name === "glm-api");
console.log(Object.keys(j).join(",") + "|" + Object.keys(g).join(",") + " " + [g.harness, g.model, g.effort, g.source].join(" "));' -- "$OUT")" \
        == "profiles|name,harness,model,effort,source claude glm-5.3[1m] max config" ]]
    verdict "12 profile list --json: {\"profiles\": [{name, harness, model, effort, source}]}" $? "rc=$RC out: $(head -c 300 <<<"$OUT")"
    run_ad route --all
    [[ "$RC" -eq 0 && "$OUT" == "routes: default" ]]
    verdict "12 profiles added without roles leave the routes at 'routes: default'" $? "out: $OUT"

    # --- 13. doctor (no model call) and doctor --probe (stub) ---
    write_config <<'EOF'
{
  "version": 1,
  "profiles": {
    "ct-api": { "harness": "claude", "auth": { "key": "tkey" }, "endpoint": "http://127.0.0.1:9" },
    "ct-nokey": { "harness": "claude", "auth": { "key": "absent" }, "endpoint": "http://127.0.0.1:9" },
    "ct-cmd": { "harness": "claude", "auth": { "keyCmd": ["node", "-e", "process.stdout.write(['cmd', 'key', 'value', '777'].join('-'))"] }, "endpoint": "http://127.0.0.1:9" },
    "ct-sub": { "harness": "claude", "auth": "login" },
    "ct-conflict": { "harness": "claude", "auth": "login", "env": { "PLAIN_SAFE": "0" } },
    "dsh-x": { "harness": "dsh", "auth": { "key": "dkey" }, "model": "deepseek-v4-pro" }
  }
}
EOF
    reset_wrappers
    run_ad doctor
    [[ "$RC" -eq 1 && "$OUT" == *"FAIL profile dsh-x: harness dsh is not available in this version"* && "$OUT" == *"FAIL key ct-nokey: no key absent is stored"* \
        && "$OUT" == *"FAIL env ct-conflict: profile env PLAIN_SAFE conflicts with a mandatory setting"* && "$OUT" == *"ok key ct-cmd: keyCmd node exited 0 with a value"* \
        && "$OUT" != *cmd-key-value-777* && "$OUT" == *"ok profile glm: pass-through to $AGENT_DISPATCH_ZCODE"* && "$(tail -1 <<<"$OUT")" == "doctor: FAIL" ]]
    verdict "13 doctor: harness availability, keys (value never printed), env conflicts, pass-through wrappers; 'doctor: FAIL' exits 1" $? "rc=$RC" "$OUT"
    [[ "$OUT" == *"ok profile luna: pass-through to $AGENT_DISPATCH_CODEX (--model gpt-6-luna --effort max; the model is not checked)"* \
        && "$OUT" == *"ok harness luna: codex codex-cli 0.0.0-stub"* && "$OUT" == *"ok auth sol: codex login (chatgpt)"* && "$OUT" != *"stub-user@example.com"* \
        && "$(last_call codex-dispatch setup)" == '["setup","--json"]' && "$(calls_of codex-dispatch setup)" -eq 1 ]]
    verdict "13 doctor checks codex and its login once through 'codex-dispatch setup --json' (no model call); the account e-mail is not printed" $? "setup calls: $(calls_of codex-dispatch setup)" "$(grep -E ' (luna|sol):' <<<"$OUT")"
    can codex-dispatch setup stdout '{"codex":{"available":true,"detail":"codex-cli 0.1.0"},"auth":{"loggedIn":false,"detail":"not authenticated","requiresOpenaiAuth":true}}'
    run_ad doctor --profile luna
    ok=$RC
    local nologin="$OUT"
    can codex-dispatch setup stdout '{"codex":{"available":false,"detail":"not found"},"auth":{"loggedIn":false,"detail":"not found"}}'
    run_ad doctor --profile astra
    local nocodex_rc=$RC nocodex="$OUT"
    rm -f "$WRAPPER_STUB_DIR/codex-dispatch.setup.stdout"
    can codex-dispatch setup stderr "boom"$'\n'
    can codex-dispatch setup exit 1
    run_ad doctor --profile sol
    [[ "$ok" -eq 1 && "$nologin" == *"FAIL auth luna: codex is not logged in (not authenticated); the user logs in: codex login"* && "$(tail -1 <<<"$nologin")" == "doctor: FAIL" \
        && "$nocodex_rc" -eq 1 && "$nocodex" == *"FAIL harness astra: codex is not available (not found); install it: npm install -g @openai/codex"* \
        && "$RC" -eq 0 && "$OUT" == *"WARN auth sol: codex and its login were not checked: codex-dispatch setup --json exited 1: boom"* && "$(tail -1 <<<"$OUT")" == "doctor: ok" ]]
    verdict "13 doctor --profile <codex>: not logged in → FAIL (codex login); codex missing → FAIL (install); setup failing → WARN, not checked" $? "no login: rc=$ok" "$nologin" "no codex: rc=$nocodex_rc" "$nocodex" "setup fails: rc=$RC" "$OUT"
    rm -f "$WRAPPER_STUB_DIR"/codex-dispatch.setup.*
    can codex-dispatch setup stdout '{"codex":{"available":true,"detail":"codex-cli 0.1.0"},"auth":{"loggedIn":false,"detail":"not authenticated","requiresOpenaiAuth":true}}'
    write_config <<'EOF'
{ "version": 1, "roles": {
  "plan-reviewer": ["glm"], "spec-reviewer": ["glm"], "implementer": ["glm"], "implementer.risk": ["glm"],
  "implementer.escalation": ["glm"], "control-review": ["glm"], "final-review": ["opus-xhigh"], "adhoc-review": ["glm"] } }
EOF
    run_ad doctor
    [[ "$RC" -eq 0 && "$OUT" == *"WARN auth luna: codex is not logged in (not authenticated); the user logs in: codex login (no role uses this profile)"* \
        && "$OUT" != *"FAIL"* && "$(tail -1 <<<"$OUT")" == "doctor: ok" ]]
    verdict "13 with every role routed away from codex, a codex login problem of the unused built-in profiles is a WARN: doctor: ok" $? "rc=$RC" "$OUT"
    rm -f "$WRAPPER_STUB_DIR"/codex-dispatch.setup.*
    write_config <<'EOF'
{
  "version": 1,
  "profiles": {
    "ct-api": { "harness": "claude", "auth": { "key": "tkey" }, "endpoint": "http://127.0.0.1:9" },
    "ct-sub": { "harness": "claude", "auth": "login" }
  }
}
EOF
    run_ad doctor --profile ct-api
    [[ "$RC" -eq 0 && "$OUT" == *"ok key ct-api: tkey in $STATE/keys/tkey (mode 0600)"* && "$OUT" == *"ok harness ct-api: $AGENT_TEST_STUB 1.0.0"* && "$(tail -1 <<<"$OUT")" == "doctor: ok" ]]
    verdict "13 doctor --profile checks one profile: key, harness binary and version" $? "rc=$RC" "$OUT"
    run_ad doctor --profile glm
    [[ "$RC" -eq 0 && "$OUT" == *"ok profile glm: pass-through"*"zcode-dispatch doctor --probe"* ]]
    verdict "13 doctor --profile glm points at zcode-dispatch doctor --probe" $? "$OUT"
    run_ad doctor --probe
    [[ "$RC" -eq 2 && "$ERR" == *"--probe needs --profile"* ]]
    verdict "13 doctor --probe without --profile is refused (each probe is a paid request)" $? "rc=$RC err: $ERR"
    export AGENT_STUB_MODE=ok AGENT_STUB_RESPONSE=PONG
    run_ad doctor --profile ct-sub --probe
    unset AGENT_STUB_MODE AGENT_STUB_RESPONSE
    [[ "$RC" -eq 0 && "$(tail -1 <<<"$OUT")" == "ok probe ct-sub: PONG in "*" s (model stub-model)" ]]
    verdict "13 doctor --profile P --probe runs one PONG turn through the core (stub)" $? "rc=$RC" "$OUT" "err: $ERR"
    run_ad doctor --profile luna --probe
    [[ "$RC" -eq 0 && "$(tail -1 <<<"$OUT")" == "WARN probe luna: agent-dispatch does not probe pass-through profiles;"* ]]
    verdict "13 doctor --probe on a pass-through profile does not call it (one WARN line)" $? "$OUT"

    run_ad no-such-verb
    [[ "$RC" -eq 2 && "$ERR" == *"usage: agent-dispatch"* ]]
    verdict "13 an unknown verb is a usage error (exit 2)" $? "rc=$RC err: $ERR"

    # --- leak check: nothing this run started is still running ---
    local left="" i=0
    while ((i < 50)); do
        left="$(pgrep -f "$TEST_ROOT" | tr '\n' ' ')"
        [[ -z "$left" ]] && break
        sleep 0.2
        i=$((i + 1))
    done
    [[ -z "$left" ]]
    verdict "no process of this run (runner, harness, wrapper stub) outlives the suite" $? "left: $left"

    echo ""
    echo "PASS count: $PASSES"
    if [[ "$FAILURES" -ne 0 ]]; then
        echo "FAILED: $FAILURES assertion(s)."
        exit 1
    fi
    echo "PASS"
}

main "$@"
