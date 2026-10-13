#!/usr/bin/env bash
# Tests for bin/zcode-dispatch, the ZCode CLI job wrapper. Zero model calls:
# ZCODE_BIN points at tests/fixtures/zcode-stub.cjs, ZCODE_APP at
# tests/fixtures/FakeZCode.app, and all job state lives under a temp root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZD="$REPO_ROOT/bin/zcode-dispatch"
MJS="$REPO_ROOT/bin/lib/zcode-dispatch.mjs"
FIX="$SCRIPT_DIR/fixtures"

FAILURES=0
TEST_ROOT=""

pass() { echo "  [PASS] $1"; }
fail() {
    echo "  [FAIL] $1"
    FAILURES=$((FAILURES + 1))
}

cleanup() {
    pkill -f "$FIX/zcode-stub.cjs" 2>/dev/null || true
    if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
        rm -rf "$TEST_ROOT"
    fi
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

# const_of <NAME> — print an exported constant of the wrapper module (objects as JSON).
const_of() {
    ZD_MJS="$MJS" node --input-type=module -e '
const { pathToFileURL } = await import("node:url");
const m = await import(pathToFileURL(process.env.ZD_MJS).href);
const v = m[process.argv[1]];
console.log(typeof v === "object" ? JSON.stringify(v) : String(v));' "$1"
}

# first_pattern <errorClass> — the first classifier pattern of a class.
first_pattern() {
    ZD_MJS="$MJS" node --input-type=module -e '
const { pathToFileURL } = await import("node:url");
const m = await import(pathToFileURL(process.env.ZD_MJS).href);
console.log(m.PATTERNS[process.argv[1]][0]);' "$1"
}

# wait_status <id> <regex> <seconds> [status args...] — poll until the status matches; print it.
wait_status() {
    local id="$1" want="$2" limit="$3"
    shift 3
    local st="" i=0
    while ((i < limit * 5)); do
        st="$("$ZD" status "$id" --json "$@" 2>/dev/null | jfield job.status || true)"
        if [[ "$st" =~ ^($want)$ ]]; then break; fi
        sleep 0.2
        i=$((i + 1))
    done
    echo "$st"
}

# wait_child <id> [status args...] — wait until the runner has recorded childPid; print it.
wait_child() {
    local id="$1"
    shift
    local child="" i=0
    while ((i < 50)); do
        child="$("$ZD" status "$id" --json "$@" 2>/dev/null | jfield job.childPid || true)"
        if [[ -n "$child" ]]; then break; fi
        sleep 0.2
        i=$((i + 1))
    done
    echo "$child"
}

# gone <pid> — true once the process no longer exists (waits up to 3 s).
gone() {
    local i=0
    while ((i < 15)); do
        if ! kill -0 "$1" 2>/dev/null; then return 0; fi
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

# start_task [task args...] — run `task --background`, print the new job id.
start_task() {
    local out
    out="$("$ZD" task --background "$@")"
    echo "${out##* }"
}

# latest_reservation_generation <state-dir> — highest active.lock.<gen> file, or -1.
latest_reservation_generation() {
    local directory="$1" latest=-1 file generation
    for file in "$directory"/active.lock.[0-9]*; do
        [[ -e "$file" ]] || continue
        if [[ "$file" =~ /active\.lock\.([0-9]+)$ ]]; then
            generation="${BASH_REMATCH[1]}"
            if ((10#$generation > latest)); then latest=$((10#$generation)); fi
        fi
    done
    echo "$latest"
}

# expect_exit <code> <label> <command...>
expect_exit() {
    local want="$1" label="$2"
    shift 2
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq "$want" ]]; then
        pass "$label"
    else
        fail "$label"
        echo "    exit: $rc (want $want)"
    fi
}

main() {
    echo "=== Test: zcode-dispatch ==="

    TEST_ROOT="$(mktemp -d)"
    trap cleanup EXIT

    # No marketplace cache under this HOME, so the shim must resolve the dev-tree .mjs.
    export HOME="$TEST_ROOT/home"
    mkdir -p "$HOME"
    export ZCODE_APP="$FIX/FakeZCode.app"
    export ZCODE_BIN="$FIX/zcode-stub.cjs"
    export ZCODE_STATE_DIR="$TEST_ROOT/state"
    unset ZCODE_NODE ZCODE_TASK_TIMEOUT_MIN SP_IMPLEMENTER ZCODE_DATA_BASE_DIR
    unset ZCODE_STUB_MODE ZCODE_STUB_RECORD ZCODE_STUB_DELAY_MS ZCODE_STUB_MESSAGE

    git init -q -b main "$TEST_ROOT/repo"
    local repo
    repo="$(cd "$TEST_ROOT/repo" && git rev-parse --show-toplevel)"
    local git_id=(-c user.email=t@example.com -c user.name=t -c commit.gpgsign=false)
    printf 'x\n' > "$repo/a.txt"
    (cd "$repo" && git add a.txt && git "${git_id[@]}" commit -qm c0)
    mkdir -p "$TEST_ROOT/notgit"
    local prompt="$TEST_ROOT/prompt.md"
    printf '## ZCode headless run — read this first\n\nImplement the thing.\n' > "$prompt"
    cd "$repo"

    local out rc id st ec rec child runner

    # --- 13. shim resolution ---
    rc=0
    out="$("$ZD" 2>&1)" || rc=$?
    if [[ "$rc" -eq 2 && "$out" == *"usage: zcode-dispatch"* ]]; then
        pass "13 shim resolves the dev-tree .mjs when no marketplace cache exists"
    else
        fail "13 shim resolves the dev-tree .mjs when no marketplace cache exists"
        echo "    exit: $rc out: $out"
    fi

    # --- 1. task prints the start line; ids increment ---
    export ZCODE_STUB_MODE=ok
    out="$("$ZD" task --background --prompt-file "$prompt")"
    st="$(wait_status zt-0001 'completed|failed|cancelled' 20)"
    local out2
    out2="$("$ZD" task --background --prompt-file "$prompt")"
    wait_status zt-0002 'completed|failed|cancelled' 20 >/dev/null
    if [[ "$out" == "ZCode Task started in the background as zt-0001" \
        && "$out2" == "ZCode Task started in the background as zt-0002" && "$st" == completed ]]; then
        pass "1 task prints 'ZCode Task started in the background as zt-0001', next is zt-0002"
    else
        fail "1 task prints 'ZCode Task started in the background as zt-0001', next is zt-0002"
        echo "    out: $out | $out2 | status: $st"
    fi

    # --- 2. pinned argv and environment ---
    export ZCODE_STUB_MODE=record ZCODE_STUB_RECORD="$TEST_ROOT/record.json"
    id="$(start_task --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    local transport plist_key want_version cfg
    transport="$(const_of PROMPT_TRANSPORT)"
    plist_key="$(const_of APP_VERSION_PLIST_KEY)"
    want_version="$(plutil -extract "$plist_key" raw -o - "$ZCODE_APP/Contents/Info.plist")"
    cfg="$ZCODE_APP/Contents/Resources/config/provider/zcode-builtin.json"
    if [[ "$st" == completed ]] && REC="$TEST_ROOT/record.json" PROMPT="$prompt" ROOT="$repo" \
        TRANSPORT="$transport" CFG="$cfg" VER="$want_version" \
        MODEL_ARGS="$(const_of MODEL_ARGS)" DISALLOWED="$(const_of DISALLOWED_TOOLS)" node -e '
const fs = require("node:fs");
const r = JSON.parse(fs.readFileSync(process.env.REC, "utf8"));
const a = r.argv;
const pair = (f, v) => a.some((x, i) => x === f && a[i + 1] === v);
const prompt = fs.readFileSync(process.env.PROMPT, "utf8");
const promptOk = process.env.TRANSPORT === "stdin" ? pair("-p", "-") && r.stdin === prompt : pair("-p", prompt);
const modelArgs = JSON.parse(process.env.MODEL_ARGS);
const at = a.indexOf(modelArgs[0]);
const modelOk = modelArgs.length === 0 || (at >= 0 && modelArgs.every((x, k) => a[at + k] === x));
const disallowed = JSON.parse(process.env.DISALLOWED);
const disallowedOk = disallowed.length === 0 ? !a.includes("--disallowedTools") : pair("--disallowedTools", disallowed.join(","));
const ok = pair("--output-format", "json") && pair("--mode", "yolo") && pair("--surface", "terminal")
  && pair("--workflow-mode", "disabled") && pair("--cwd", process.env.ROOT)
  && !a.includes("--target") && !a.includes("--json") && !a.includes("-c") && !a.includes("--continue")
  && promptOk && modelOk && disallowedOk
  && r.env.ZCODE_BUILTIN_PROVIDER_CONFIG_FILE === process.env.CFG
  && r.env.ZCODE_BUILTIN_PROVIDER_BUNDLED_CONFIG_FILE === process.env.CFG
  && r.env.ZCODE_APP_VERSION === process.env.VER
  && r.env.ZCODE_DATA_BASE_DIR === null;
process.exit(ok ? 0 : 1);'; then
        pass "2 CLI argv pins json/yolo/terminal/workflow-disabled/--cwd root, prompt per PROMPT_TRANSPORT, env = provider config x2 + app version, no ZCODE_DATA_BASE_DIR"
    else
        fail "2 CLI argv pins json/yolo/terminal/workflow-disabled/--cwd root, prompt per PROMPT_TRANSPORT, env = provider config x2 + app version, no ZCODE_DATA_BASE_DIR"
        echo "    status: $st record: $(cat "$TEST_ROOT/record.json" 2>/dev/null | head -c 600)"
    fi

    # --- 2. personal provider config: wrapper-owned, pinned before every run, passed by env ---
    local pcfg sel_path pinned
    pcfg="$ZCODE_STATE_DIR/personal-provider-config.json"
    sel_path="$(const_of SELECTION_PATH)"
    pinned="$(const_of PINNED_SELECTION)"
    if [[ "$st" == completed ]] && REC="$TEST_ROOT/record.json" PCFG="$pcfg" SEL_PATH="$sel_path" PINNED="$pinned" node -e '
const fs = require("node:fs");
const r = JSON.parse(fs.readFileSync(process.env.REC, "utf8"));
const at = (o) => process.env.SEL_PATH.split(".").reduce((a, k) => (a == null ? undefined : a[k]), o);
process.exit(r.env.ZCODE_PERSONAL_PROVIDER_CONFIG_FILE === process.env.PCFG && r.personalConfig !== null
  && JSON.stringify(at(r.personalConfig)) === process.env.PINNED ? 0 : 1);'; then
        pass "2 the CLI gets ZCODE_PERSONAL_PROVIDER_CONFIG_FILE=<state root>/personal-provider-config.json, created before the run with SELECTION_PATH = PINNED_SELECTION"
    else
        fail "2 the CLI gets ZCODE_PERSONAL_PROVIDER_CONFIG_FILE=<state root>/personal-provider-config.json, created before the run with SELECTION_PATH = PINNED_SELECTION"
        echo "    status: $st file: $(head -c 400 "$pcfg" 2>/dev/null)"
    fi
    PCFG="$pcfg" SEL_PATH="$sel_path" node -e '
const fs = require("node:fs");
const o = JSON.parse(fs.readFileSync(process.env.PCFG, "utf8"));
const keys = process.env.SEL_PATH.split(".");
keys.slice(0, -1).reduce((a, k) => a[k], o)[keys.at(-1)] = { providerId: "p", modelId: "GLM-5.3" };
o.keptByWrapper = true;
fs.writeFileSync(process.env.PCFG, JSON.stringify(o));'
    id="$(start_task --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    if [[ "$st" == completed ]] && REC="$TEST_ROOT/record.json" SEL_PATH="$sel_path" PINNED="$pinned" node -e '
const fs = require("node:fs");
const r = JSON.parse(fs.readFileSync(process.env.REC, "utf8"));
const at = (o) => process.env.SEL_PATH.split(".").reduce((a, k) => (a == null ? undefined : a[k]), o);
process.exit(r.personalConfig?.keptByWrapper === true && JSON.stringify(at(r.personalConfig)) === process.env.PINNED ? 0 : 1);'; then
        pass "2 a changed selection is re-pinned before the next run; other content of the file is kept"
    else
        fail "2 a changed selection is re-pinned before the next run; other content of the file is kept"
        echo "    status: $st record: $(head -c 600 "$TEST_ROOT/record.json" 2>/dev/null)"
    fi
    unset ZCODE_STUB_RECORD

    # --- 3. status running -> completed; result; stored fields; recent cap ---
    export ZCODE_STUB_MODE=ok ZCODE_STUB_DELAY_MS=1500
    id="$(start_task --prompt-file "$prompt")"
    local st1
    st1="$("$ZD" status "$id" --json | jfield job.status)"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    unset ZCODE_STUB_DELAY_MS
    local res line1 sid usage
    res="$("$ZD" result "$id")"
    line1="$(printf '%s\n' "$res" | head -1)"
    rec="$("$ZD" status "$id" --json)"
    sid="$(jfield job.sessionId <<<"$rec")"
    usage="$(jfield job.usage <<<"$rec")"
    if [[ "$st1" == running && "$st" == completed && "$line1" == DONE \
        && "$sid" == sess_stub_* && "$usage" == *inputTokens* ]]; then
        pass "3 status running then completed; result prints the response; sessionId and usage stored"
    else
        fail "3 status running then completed; result prints the response; sessionId and usage stored"
        echo "    st1=$st1 st=$st line1=$line1 sid=$sid usage=$usage"
    fi

    local i
    for i in 1 2 3 4 5 6 7 8; do
        id="$(start_task --prompt-file "$prompt")"
        wait_status "$id" 'completed|failed|cancelled' 20 >/dev/null
    done
    local n_recent n_all
    n_recent="$("$ZD" status --json | jfield recent | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).length))')"
    n_all="$("$ZD" status --json --all | jfield recent | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).length))')"
    if [[ "$n_recent" -eq 10 && "$n_all" -eq 13 ]]; then
        pass "3 status without id lists the 10 newest terminal jobs; --all lists every job"
    else
        fail "3 status without id lists the 10 newest terminal jobs; --all lists every job"
        echo "    recent=$n_recent all=$n_all"
    fi

    # --- 6. failure classes ---
    local mode want crash_id=""
    for mode in crash malformed model-not-selected auth quota launch; do
        export ZCODE_STUB_MODE="$mode"
        case "$mode" in
            crash | malformed) unset ZCODE_STUB_MESSAGE ;;
            *) export ZCODE_STUB_MESSAGE="$(first_pattern "$mode")" ;;
        esac
        id="$(start_task --prompt-file "$prompt")"
        st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
        ec="$("$ZD" status "$id" --json | jfield job.errorClass)"
        [[ "$mode" == crash ]] && crash_id="$id"
        if [[ "$st" == failed && "$ec" == "$mode" ]]; then
            pass "6 stub mode $mode -> failed/$mode"
        else
            fail "6 stub mode $mode -> failed/$mode"
            echo "    got $st/$ec"
        fi
    done
    # ZCode suffixes errors with " (traceId: <uuid>)" (findings U4); its digit runs must not match auth.
    export ZCODE_STUB_MODE=quota
    export ZCODE_STUB_MESSAGE="$(first_pattern quota) (traceId: 5e401b7c-1429-4d2a-9c3e-0f4012ab7c11)"
    id="$(start_task --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    ec="$("$ZD" status "$id" --json | jfield job.errorClass)"
    if [[ "$st" == failed && "$ec" == quota ]]; then
        pass "6 traceId suffix containing 401/429 is stripped before matching -> failed/quota, not auth"
    else
        fail "6 traceId suffix containing 401/429 is stripped before matching -> failed/quota, not auth"
        echo "    got $st/$ec"
    fi
    unset ZCODE_STUB_MESSAGE
    export ZCODE_STUB_MODE=ok
    id="$(ZCODE_NODE=/nonexistent/node start_task --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    ec="$("$ZD" status "$id" --json | jfield job.errorClass)"
    if [[ "$st" == failed && "$ec" == launch ]]; then
        pass "6 ZCODE_NODE=/nonexistent/node (spawn ENOENT) -> failed/launch"
    else
        fail "6 ZCODE_NODE=/nonexistent/node (spawn ENOENT) -> failed/launch"
        echo "    got $st/$ec"
    fi
    rc=0
    "$ZD" result "$id" >/dev/null 2>"$TEST_ROOT/result-err.txt" || rc=$?
    if [[ "$rc" -eq 1 ]] && grep -q "^job $id is failed errorClass=launch$" "$TEST_ROOT/result-err.txt"; then
        pass "result on a failed job: stderr 'job <id> is failed errorClass=<class>', exit 1"
    else
        fail "result on a failed job: stderr 'job <id> is failed errorClass=<class>', exit 1"
        echo "    exit: $rc stderr: $(head -3 "$TEST_ROOT/result-err.txt")"
    fi

    # --- 4. resume mapping ---
    local sid1
    sid1="$("$ZD" status zt-0001 --json | jfield job.sessionId)"
    export ZCODE_STUB_MODE=resume
    id="$(start_task --resume-task zt-0001 --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    rec="$("$ZD" status "$id" --json)"
    if [[ "$st" == completed && "$(jfield job.resumeOf <<<"$rec")" == zt-0001 \
        && "$(jfield job.sessionId <<<"$rec")" == "$sid1" ]]; then
        pass "4 --resume-task zt-0001 passes --resume <job 1 session>; record has resumeOf and the same sessionId"
    else
        fail "4 --resume-task zt-0001 passes --resume <job 1 session>; record has resumeOf and the same sessionId"
        echo "    st=$st rec=$(printf '%s' "$rec" | head -c 400)"
    fi
    expect_exit 2 "4 resuming a failed job is refused (exit 2)" "$ZD" task --background --resume-task "$crash_id" --prompt-file "$prompt"
    expect_exit 2 "4 --resume-task together with --fresh is refused (exit 2)" "$ZD" task --background --resume-task zt-0001 --fresh --prompt-file "$prompt"
    expect_exit 2 "4 a Codex task- id is refused (exit 2)" "$ZD" task --background --resume-task task-0001 --prompt-file "$prompt"

    # --- 5. timeout ---
    export ZCODE_STUB_MODE=hang ZCODE_TASK_TIMEOUT_MIN=0.05
    id="$(start_task --prompt-file "$prompt")"
    child="$(wait_child "$id")"
    local started=$SECONDS
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    local elapsed=$((SECONDS - started))
    ec="$("$ZD" status "$id" --json | jfield job.errorClass)"
    unset ZCODE_TASK_TIMEOUT_MIN
    if [[ "$st" == failed && "$ec" == timeout && "$elapsed" -le 15 && -n "$child" ]] && gone "$child"; then
        pass "5 ZCODE_TASK_TIMEOUT_MIN=0.05 + hang -> failed/timeout within 15 s, stub gone"
    else
        fail "5 ZCODE_TASK_TIMEOUT_MIN=0.05 + hang -> failed/timeout within 15 s, stub gone"
        echo "    got $st/$ec after ${elapsed}s child=$child"
    fi

    # --- 7. dead runner ---
    export ZCODE_STUB_MODE=hang
    id="$(start_task --prompt-file "$prompt")"
    child="$(wait_child "$id")"
    runner="$("$ZD" status "$id" --json | jfield job.runnerPid)"
    kill -9 "$runner"
    sleep 0.5
    rec="$("$ZD" status "$id" --json)"
    local dead_release_rc=0 dead_release_out
    dead_release_out="$("$ZD" release-stale --cwd "$repo" 2>&1)" || dead_release_rc=$?
    if [[ "$(jfield job.status <<<"$rec")" == failed && "$(jfield job.errorClass <<<"$rec")" == crash \
        && "$(jfield job.note <<<"$rec")" == "runner died" && -n "$child" ]] && gone "$child" \
        && [[ "$dead_release_rc" -eq 0 && "$dead_release_out" == "released $repo generation "* ]]; then
        pass "7 runner killed -> status marks failed/crash note 'runner died', stub child gone"
    else
        fail "7 runner killed -> status marks failed/crash note 'runner died', stub child gone"
        echo "    rec=$(printf '%s' "$rec" | head -c 400) release=$dead_release_rc/$dead_release_out"
    fi

    # --- 8. cancel (plus guards that need a running job) ---
    id="$(start_task --prompt-file "$prompt")"
    child="$(wait_child "$id")"
    expect_exit 2 "4 resuming a running job is refused (exit 2)" "$ZD" task --background --resume-task "$id" --prompt-file "$prompt"
    expect_exit 2 "10 a second task while one is running in the workspace is refused (exit 2)" "$ZD" task --background --prompt-file "$prompt"
    out="$("$ZD" cancel "$id")"
    st="$("$ZD" status "$id" --json | jfield job.status)"
    if [[ "$out" == "cancelled $id" && "$st" == cancelled && -n "$child" ]] && gone "$child"; then
        pass "8 cancel prints 'cancelled <id>', record cancelled, CLI process group gone"
    else
        fail "8 cancel prints 'cancelled <id>', record cancelled, CLI process group gone"
        echo "    out=$out st=$st child=$child"
    fi
    sleep 1
    st="$("$ZD" status "$id" --json | jfield job.status)"
    out="$("$ZD" cancel "$id")"
    if [[ "$st" == cancelled && "$out" == "$id is cancelled" ]]; then
        pass "8 cancelled stays cancelled; cancel on a terminal job prints its status, exit 0"
    else
        fail "8 cancelled stays cancelled; cancel on a terminal job prints its status, exit 0"
        echo "    st=$st out=$out"
    fi

    # --- 8. atomic per-workspace reservation ---
    export ZCODE_STUB_MODE=hang
    local c1out="$TEST_ROOT/concurrent-1.out" c1err="$TEST_ROOT/concurrent-1.err" c1rc="$TEST_ROOT/concurrent-1.rc"
    local c2out="$TEST_ROOT/concurrent-2.out" c2err="$TEST_ROOT/concurrent-2.err" c2rc="$TEST_ROOT/concurrent-2.rc"
    (
        local task_rc=0
        "$ZD" task --background --prompt-file "$prompt" > "$c1out" 2> "$c1err" || task_rc=$?
        printf '%s\n' "$task_rc" > "$c1rc"
    ) &
    local c1pid=$!
    (
        local task_rc=0
        "$ZD" task --background --prompt-file "$prompt" > "$c2out" 2> "$c2err" || task_rc=$?
        printf '%s\n' "$task_rc" > "$c2rc"
    ) &
    local c2pid=$!
    wait "$c1pid"
    wait "$c2pid"
    local c1status c2status winner_id="" loser_err="" winner_child="" winner_runner="" concurrent_ok=0
    c1status="$(cat "$c1rc")"
    c2status="$(cat "$c2rc")"
    if [[ "$c1status" == 0 && "$c2status" == 2 ]]; then
        winner_id="$(cat "$c1out")"; winner_id="${winner_id##* }"; loser_err="$c2err"
    elif [[ "$c2status" == 0 && "$c1status" == 2 ]]; then
        winner_id="$(cat "$c2out")"; winner_id="${winner_id##* }"; loser_err="$c1err"
    else
        winner_id=""
        loser_err=""
    fi
    if [[ -n "$winner_id" ]]; then
        winner_child="$(wait_child "$winner_id")"
        winner_runner="$("$ZD" status "$winner_id" --json | jfield job.runnerPid)"
        if [[ -n "$winner_child" && -n "$winner_runner" ]] \
            && grep -Fq "job $winner_id is still running in this workspace; one write task per working tree" "$loser_err"; then
            concurrent_ok=1
        fi
        "$ZD" cancel "$winner_id" >/dev/null
        if ! gone "$winner_child" || ! gone "$winner_runner"; then concurrent_ok=0; fi
    fi
    if [[ "$concurrent_ok" -eq 1 ]]; then
        pass "8 concurrent tasks in one workspace: exactly one starts; the other exits 2 with the one-write-task guard"
    else
        fail "8 concurrent tasks in one workspace: exactly one starts; the other exits 2 with the one-write-task guard"
        echo "    exits=$c1status/$c2status winner=$winner_id child=$winner_child runner=$winner_runner"
        echo "    stderr1=$(cat "$c1err") stderr2=$(cat "$c2err")"
    fi

    local slug reservation_dir latest_gen stale_gen
    slug="$(ROOT="$repo" node -e 'const path=require("node:path");const {createHash}=require("node:crypto");const root=process.env.ROOT;process.stdout.write(`${path.basename(root)}-${createHash("sha1").update(root).digest("hex").slice(0,8)}`)')"
    reservation_dir="$ZCODE_STATE_DIR/state/$slug"

    # Cancellation claims the sticky status immediately, while the reservation stays held until the CLI exits.
    export ZCODE_STUB_MODE=ignore-term ZCODE_STUB_TERM_DELAY_MS=2500
    id="$(start_task --prompt-file "$prompt")"
    child="$(wait_child "$id")"
    runner="$("$ZD" status "$id" --json | jfield job.runnerPid)"
    latest_gen="$(latest_reservation_generation "$reservation_dir")"
    local live_release_rc=0 live_release_out live_holder
    live_holder="$(jfield holderPid < "$reservation_dir/active.lock.$latest_gen")"
    live_release_out="$("$ZD" release-stale --cwd "$repo" 2>&1)" || live_release_rc=$?
    if [[ "$live_release_rc" -eq 2 && "$live_release_out" == *"live runner pid"* \
        && "$live_holder" == "$runner" && ! -e "$reservation_dir/active.lock.$latest_gen.released" ]]; then
        pass "8 release-stale refuses while the reservation holder runner is alive"
    else
        fail "8 release-stale refuses while the reservation holder runner is alive"
        echo "    exit=$live_release_rc holder=$live_holder runner=$runner out=$live_release_out"
    fi
    local cancel_out="$TEST_ROOT/cancel.out" cancel_rc=0 cancel_pid blocked_out blocked_rc=0 blocked_ok=0
    "$ZD" cancel "$id" > "$cancel_out" 2>&1 &
    cancel_pid=$!
    st=""
    local wait_i=0
    while ((wait_i < 50)); do
        st="$("$ZD" status "$id" --json | jfield job.status)"
        [[ "$st" == cancelled ]] && break
        sleep 0.05
        wait_i=$((wait_i + 1))
    done
    if [[ "$st" == cancelled && -n "$child" ]] && kill -0 "$child" 2>/dev/null; then
        blocked_out="$("$ZD" task --background --prompt-file "$prompt" 2>&1)" || blocked_rc=$?
        if [[ "$blocked_rc" -eq 2 && "$blocked_out" == *"one write task per working tree"* ]]; then blocked_ok=1; fi
    fi
    wait "$cancel_pid" || cancel_rc=$?
    local child_gone=0 runner_gone=0 admitted_rc=2 admitted_out="" admitted_status=""
    if [[ -n "$child" ]] && gone "$child"; then child_gone=1; fi
    if [[ -n "$runner" ]] && gone "$runner"; then runner_gone=1; fi
    unset ZCODE_STUB_TERM_DELAY_MS
    export ZCODE_STUB_MODE=ok
    local admit_i=0
    while ((admit_i < 30)); do
        admitted_rc=0
        admitted_out="$("$ZD" task --background --prompt-file "$prompt" 2>&1)" || admitted_rc=$?
        if [[ "$admitted_rc" -eq 0 ]]; then break; fi
        if [[ "$admitted_rc" -ne 2 || "$admitted_out" != *"one write task per working tree"* ]]; then break; fi
        sleep 0.1
        admit_i=$((admit_i + 1))
    done
    if [[ "$admitted_rc" -eq 0 ]]; then
        local admitted_id="${admitted_out##* }"
        admitted_status="$(wait_status "$admitted_id" 'completed|failed|cancelled' 20)"
    fi
    if [[ "$st" == cancelled && "$cancel_rc" -eq 0 && "$blocked_ok" -eq 1 && "$child_gone" -eq 1 \
        && "$runner_gone" -eq 1 && "$admitted_rc" -eq 0 && "$admitted_status" == completed ]]; then
        pass "8 cancel keeps the reservation while an ignoring CLI lives; after CLI exit the next task is admitted"
    else
        fail "8 cancel keeps the reservation while an ignoring CLI lives; after CLI exit the next task is admitted"
        echo "    status=$st cancel_rc=$cancel_rc child_live_refusal=$blocked_rc blocked_ok=$blocked_ok child_gone=$child_gone runner_gone=$runner_gone"
        echo "    next_exit=$admitted_rc next_status=$admitted_status next_out=$admitted_out"
    fi
    unset ZCODE_STUB_TERM_DELAY_MS

    # A stale reservation blocks task without changing either its lock or the job record.
    mkdir -p "$reservation_dir/jobs"
    latest_gen="$(latest_reservation_generation "$reservation_dir")"
    stale_gen=$((latest_gen + 1))
    local stale_file="$reservation_dir/active.lock.$stale_gen" stale_job="zt-0300"
    local stale_job_file="$reservation_dir/jobs/zt-0300.json" stale_lock_copy="$TEST_ROOT/stale-lock.copy" stale_job_copy="$TEST_ROOT/stale-job.copy"
    printf '{"holderPid":2147483647,"jobId":"%s","token":"dead-holder","generation":%s}\n' "$stale_job" "$stale_gen" > "$stale_file"
    printf '{"id":"%s","status":"running","errorClass":null,"runnerPid":2147483647,"childPid":null}\n' "$stale_job" > "$stale_job_file"
    cp "$stale_file" "$stale_lock_copy"
    cp "$stale_job_file" "$stale_job_copy"
    rc=0
    local stale_task_out
    stale_task_out="$("$ZD" task --background --prompt-file "$prompt" 2>&1)" || rc=$?
    if [[ "$rc" -eq 2 && "$stale_task_out" == *"stale"* && "$stale_task_out" == *"release-stale"* \
        && ! -e "$stale_file.released" ]] && cmp -s "$stale_file" "$stale_lock_copy" \
        && cmp -s "$stale_job_file" "$stale_job_copy"; then
        pass "8 task refuses a dead-holder stale reservation and leaves lock and job record untouched"
    else
        fail "8 task refuses a dead-holder stale reservation and leaves lock and job record untouched"
        echo "    exit=$rc out=$stale_task_out lock_unchanged=$(cmp -s "$stale_file" "$stale_lock_copy" && echo yes || echo no) job_unchanged=$(cmp -s "$stale_job_file" "$stale_job_copy" && echo yes || echo no)"
    fi

    # Explicit release finalizes the abandoned non-terminal job, then allows a new task.
    local release_out next_out next_id next_status stale_status stale_error release_rc=0
    release_out="$("$ZD" release-stale --cwd "$repo" 2>&1)" || release_rc=$?
    stale_status="$("$ZD" status "$stale_job" --json | jfield job.status)"
    stale_error="$("$ZD" status "$stale_job" --json | jfield job.errorClass)"
    next_out="$("$ZD" task --background --prompt-file "$prompt" 2>&1)" || release_rc=$?
    next_id="${next_out##* }"
    next_status="$(wait_status "$next_id" 'completed|failed|cancelled' 20)"
    if [[ "$release_rc" -eq 0 && "$release_out" == "released $repo generation $stale_gen" \
        && -e "$stale_file.released" && "$stale_status" == failed && "$stale_error" == crash \
        && "$next_status" == completed ]]; then
        pass "8 release-stale finalizes a dead-holder job and the next task is admitted and completes"
    else
        fail "8 release-stale finalizes a dead-holder job and the next task is admitted and completes"
        echo "    release_exit=$release_rc release_out=$release_out job=$stale_status/$stale_error next=$next_out/$next_status"
    fi

    # Concurrent release-stale calls contend deterministically for the same exclusive marker.
    latest_gen="$(latest_reservation_generation "$reservation_dir")"
    stale_gen=$((latest_gen + 1))
    stale_file="$reservation_dir/active.lock.$stale_gen"
    printf '{"holderPid":2147483647,"jobId":"zt-9999","token":"concurrent-release","generation":%s}\n' "$stale_gen" > "$stale_file"
    local race_release_json race_release_file="$stale_file.released"
    race_release_json="$(STALE_FILE="$stale_file" RELEASE_FILE="$race_release_file" ROOT="$repo" GEN="$stale_gen" MJS="$MJS" node --input-type=module -e '
import fs from "node:fs";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
const m = await import(pathToFileURL(process.env.MJS).href);
const realLink = fs.linkSync;
let injected = false;
let second;
let firstOut = "";
let firstErr = "";
const stdout = process.stdout.write;
const stderr = process.stderr.write;
fs.linkSync = (from, to) => {
  if (!injected && to === process.env.RELEASE_FILE) {
    injected = true;
    second = spawnSync(process.execPath, [process.env.MJS, "release-stale", "--cwd", process.env.ROOT], {
      cwd: process.env.ROOT,
      env: process.env,
      encoding: "utf8",
    });
  }
  return realLink(from, to);
};
process.stdout.write = (chunk) => { firstOut += chunk.toString(); return true; };
process.stderr.write = (chunk) => { firstErr += chunk.toString(); return true; };
const firstRc = await m.main(["release-stale", "--cwd", process.env.ROOT]);
fs.linkSync = realLink;
process.stdout.write = stdout;
process.stderr.write = stderr;
process.stdout.write(JSON.stringify({
  injected, firstRc, firstOut, firstErr, secondStatus: second?.status,
  secondOut: second?.stdout ?? "", secondErr: second?.stderr ?? "",
  marker: fs.existsSync(process.env.RELEASE_FILE), generation: Number(process.env.GEN),
}) + "\n");')"
    if [[ "$(jfield injected <<<"$race_release_json")" == true \
        && "$(jfield firstRc <<<"$race_release_json")" == 2 \
        && "$(jfield secondStatus <<<"$race_release_json")" == 0 \
        && "$(jfield firstErr <<<"$race_release_json")" == *"already released"* \
        && "$(jfield secondOut <<<"$race_release_json")" == "released $repo generation $stale_gen" \
        && "$(jfield marker <<<"$race_release_json")" == true ]]; then
        pass "8 concurrent release-stale calls create one release record and exactly one succeeds"
    else
        fail "8 concurrent release-stale calls create one release record and exactly one succeeds"
        echo "    result=$race_release_json"
    fi

    # --- 8. split multibyte UTF-8 output ---
    export ZCODE_STUB_MODE=split-utf8
    id="$(start_task --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    out="$("$ZD" result "$id")"
    rec="$("$ZD" status "$id" --json)"
    if [[ "$st" == completed && "$out" == "Ответ: Привет ё" && "$(jfield job.response <<<"$rec")" == "Ответ: Привет ё" ]]; then
        pass "8 split multibyte Cyrillic stdout is decoded intact by result"
    else
        fail "8 split multibyte Cyrillic stdout is decoded intact by result"
        echo "    status=$st result=$out record=$(jfield job.response <<<"$rec")"
    fi

    printf '{"id":"zt-0500","status":"cancelled","errorClass":null}\n' > "$TEST_ROOT/sticky.json"
    if STICKY="$TEST_ROOT/sticky.json" ZD_MJS="$MJS" node --input-type=module -e '
const { pathToFileURL } = await import("node:url");
const m = await import(pathToFileURL(process.env.ZD_MJS).href);
m.finalizeRecord(process.env.STICKY, { status: "failed", errorClass: "crash" });
process.exit(m.readRecord(process.env.STICKY).status === "cancelled" ? 0 : 1);'; then
        pass "8 finalizeRecord never overwrites a terminal status (a late runner write keeps cancelled)"
    else
        fail "8 finalizeRecord never overwrites a terminal status (a late runner write keeps cancelled)"
    fi
    mkdir -p "$TEST_ROOT/race"
    printf '{"id":"zt-0501","status":"running","errorClass":null,"runnerPid":null,"childPid":null}\n' > "$TEST_ROOT/race/zt-0501.json"
    if RACE="$TEST_ROOT/race" ZD_MJS="$MJS" node --input-type=module -e '
const { pathToFileURL } = await import("node:url");
const fs = (await import("node:fs")).default;
const path = await import("node:path");
const m = await import(pathToFileURL(process.env.ZD_MJS).href);
const file = `${process.env.RACE}/zt-0501.json`;
const realRename = fs.renameSync;
let injected = false;
// The runner has read `running`; cancel lands before the runner renames its stale copy into place.
fs.renameSync = (from, to) => {
  if (!injected && to === file) {
    injected = true;
    m.finalizeRecord(file, { status: "cancelled", errorClass: null, note: "cancelled by zcode-dispatch cancel" });
  }
  return realRename(from, to);
};
const token = "race-reservation-0501";
fs.writeFileSync(`${path.dirname(process.env.RACE)}/active.lock.0`, JSON.stringify({ holderPid: process.pid, jobId: "zt-0501", token, generation: 0 }));
const rc = await m.main(["__run", "zt-0501", process.env.RACE, token]);
fs.renameSync = realRename;
const main = JSON.parse(fs.readFileSync(file, "utf8"));
const ok = injected && rc === 0 && main.status === "running" && Number.isInteger(main.runnerPid)
  && m.readRecord(file).status === "cancelled";
process.exit(ok ? 0 : 1);'; then
        pass "8 race: a runner renaming a stale running copy over a cancellation leaves the job cancelled"
    else
        fail "8 race: a runner renaming a stale running copy over a cancellation leaves the job cancelled"
    fi
    printf '{"id":"zt-0502","status":"running","errorClass":null,"runnerPid":null,"childPid":null}\n' > "$TEST_ROOT/race/zt-0502.json"
    if RACE="$TEST_ROOT/race" ZD_MJS="$MJS" node --input-type=module -e '
const { pathToFileURL } = await import("node:url");
const fs = (await import("node:fs")).default;
const m = await import(pathToFileURL(process.env.ZD_MJS).href);
const file = `${process.env.RACE}/zt-0502.json`;
const realLink = fs.linkSync;
let injected = false;
// The runner finalizes from a stale `running` read; cancel claims the terminal record first.
fs.linkSync = (from, to) => {
  if (!injected) {
    injected = true;
    m.finalizeRecord(file, { status: "cancelled", errorClass: null, note: "cancelled by zcode-dispatch cancel" });
  }
  return realLink(from, to);
};
const runner = m.finalizeRecord(file, { status: "completed", errorClass: null, response: "DONE" });
fs.linkSync = realLink;
process.exit(injected && runner.status === "cancelled" && m.readRecord(file).status === "cancelled" ? 0 : 1);'; then
        pass "8 race: a runner finalizing from a stale running read loses to a cancel that claimed first"
    else
        fail "8 race: a runner finalizing from a stale running read loses to a cancel that claimed first"
    fi

    # --- 9. worktree isolation ---
    (cd "$repo" && git worktree add -q "$TEST_ROOT/wt" -b wt-feature)
    local wt_root
    wt_root="$(cd "$TEST_ROOT/wt" && git rev-parse --show-toplevel)"
    export ZCODE_STUB_MODE=ok
    out="$("$ZD" task --background --cwd "$wt_root" --prompt-file "$prompt")"
    wait_status zt-0001 'completed|failed|cancelled' 20 --cwd "$wt_root" >/dev/null
    local main_roots wt_ws
    main_roots="$("$ZD" status --json --all)"
    wt_ws="$("$ZD" status zt-0001 --cwd "$wt_root" --json | jfield job.workspaceRoot)"
    if [[ "$out" == "ZCode Task started in the background as zt-0001" && "$wt_ws" == "$wt_root" \
        && "$main_roots" != *"\"workspaceRoot\": \"$wt_root\""* ]]; then
        pass "9 a --cwd <worktree> job is zt-0001 in its own workspace, invisible without --cwd"
    else
        fail "9 a --cwd <worktree> job is zt-0001 in its own workspace, invisible without --cwd"
        echo "    out=$out wt_ws=$wt_ws"
    fi

    # --- 10. refusals (exit 2) ---
    expect_exit 2 "10 outside a git work tree" "$ZD" task --background --cwd "$TEST_ROOT/notgit" --prompt-file "$prompt"
    expect_exit 2 "10 missing --prompt-file" "$ZD" task --background
    expect_exit 2 "10 prompt file does not exist" "$ZD" task --background --prompt-file "$TEST_ROOT/nope.md"
    : > "$TEST_ROOT/empty.md"
    expect_exit 2 "10 empty prompt file" "$ZD" task --background --prompt-file "$TEST_ROOT/empty.md"
    if [[ "$transport" == argv ]]; then
        local max
        max="$(const_of MAX_PROMPT_BYTES)"
        head -c $((max + 1)) /dev/zero | tr '\0' 'a' > "$TEST_ROOT/big.md"
        expect_exit 2 "10 prompt file larger than MAX_PROMPT_BYTES ($max)" "$ZD" task --background --prompt-file "$TEST_ROOT/big.md"
    else
        # stdin transport: the size guard does not apply (C1), so the big prompt starts a task.
        local max
        max="$(const_of MAX_PROMPT_BYTES)"
        head -c $((max + 1)) /dev/zero | tr '\0' 'a' > "$TEST_ROOT/big.md"
        rc=0
        out="$("$ZD" task --background --prompt-file "$TEST_ROOT/big.md" 2>&1)" || rc=$?
        st=""
        if [[ "$rc" -eq 0 && "$out" == "ZCode Task started in the background as zt-"* ]]; then
            st="$(wait_status "${out##* }" 'completed|failed|cancelled' 20)"
        fi
        if [[ "$st" == completed ]]; then
            pass "10 prompt file larger than MAX_PROMPT_BYTES ($max) is accepted on the stdin transport"
        else
            fail "10 prompt file larger than MAX_PROMPT_BYTES ($max) is accepted on the stdin transport"
            echo "    exit: $rc out: $out status: $st"
        fi
    fi
    expect_exit 2 "10 SP_IMPLEMENTER=luna" env SP_IMPLEMENTER=luna "$ZD" task --background --prompt-file "$prompt"
    mkdir -p "$TEST_ROOT/NoPlist.app/Contents"
    expect_exit 2 "10 ZCODE_APP without a readable Info.plist" env ZCODE_APP="$TEST_ROOT/NoPlist.app" "$ZD" task --background --prompt-file "$prompt"
    expect_exit 2 "10 missing --background" "$ZD" task --prompt-file "$prompt"
    expect_exit 2 "10 unknown flag" "$ZD" task --background --bogus --prompt-file "$prompt"
    expect_exit 2 "10 unknown id on status" "$ZD" status zt-9999
    expect_exit 2 "10 unknown id on result" "$ZD" result zt-9999
    expect_exit 2 "10 unknown id on cancel" "$ZD" cancel zt-9999

    # --- 11. doctor (offline) ---
    rc=0
    out="$("$ZD" doctor)" || rc=$?
    local checks=0 c
    for c in app cli provider-config node app-version git state-dir personal-config kill-switch; do
        if grep -Eq "^(ok|WARN) $c: " <<<"$out"; then checks=$((checks + 1)); fi
    done
    if [[ "$rc" -eq 0 && "$checks" -eq 9 && "$(tail -1 <<<"$out")" == "doctor: ok" ]] && ! grep -q '^FAIL' <<<"$out"; then
        pass "11 doctor against the fixtures: 9 checks ok/WARN, 'doctor: ok', exit 0"
    else
        fail "11 doctor against the fixtures: 9 checks ok/WARN, 'doctor: ok', exit 0"
        echo "    exit: $rc"
        echo "$out" | sed 's/^/    /'
    fi
    rc=0
    out="$(ZCODE_BIN=/nonexistent/zcode.cjs "$ZD" doctor)" || rc=$?
    if [[ "$rc" -eq 1 && "$out" == *"FAIL cli: "* && "$(tail -1 <<<"$out")" == "doctor: FAIL" ]]; then
        pass "11 doctor: missing zcode.cjs -> FAIL cli, exit 1"
    else
        fail "11 doctor: missing zcode.cjs -> FAIL cli, exit 1"
        echo "    exit: $rc"
    fi
    mkdir -p "$TEST_ROOT/NoCfg.app/Contents"
    cp "$ZCODE_APP/Contents/Info.plist" "$TEST_ROOT/NoCfg.app/Contents/Info.plist"
    rc=0
    out="$(ZCODE_APP="$TEST_ROOT/NoCfg.app" "$ZD" doctor)" || rc=$?
    if [[ "$rc" -eq 1 && "$out" == *"FAIL provider-config: "* ]]; then
        pass "11 doctor: missing provider config -> FAIL provider-config, exit 1"
    else
        fail "11 doctor: missing provider config -> FAIL provider-config, exit 1"
        echo "    exit: $rc"
    fi
    rc=0
    out="$("$ZD" doctor --cwd "$TEST_ROOT/notgit")" || rc=$?
    if [[ "$rc" -eq 1 && "$out" == *"FAIL git: "* ]]; then
        pass "11 doctor: outside a git tree -> FAIL git, exit 1"
    else
        fail "11 doctor: outside a git tree -> FAIL git, exit 1"
        echo "    exit: $rc"
    fi

    # --- 12. doctor --probe ---
    rc=0
    out="$(ZCODE_STUB_MODE=pong "$ZD" doctor --probe)" || rc=$?
    if [[ "$rc" -eq 0 && "$out" == *"model-selected: ok"* && "$out" == *"answers: ok"* \
        && "$out" == *"reported-model: unreported"* && "$out" == *"usage: input="* && "$(tail -1 <<<"$out")" == "probe: ok" ]]; then
        pass "12 doctor --probe with pong: probe ok, reported-model unreported, exit 0"
    else
        fail "12 doctor --probe with pong: probe ok, reported-model unreported, exit 0"
        echo "    exit: $rc"
        echo "$out" | sed 's/^/    /'
    fi
    rc=0
    out="$(ZCODE_STUB_MODE=model-not-selected ZCODE_STUB_MESSAGE="$(first_pattern model-not-selected)" "$ZD" doctor --probe 2>/dev/null)" || rc=$?
    if [[ "$rc" -eq 1 && "$out" == *"model-selected: FAIL(model-not-selected)"* && "$(tail -1 <<<"$out")" == "probe: FAIL" ]]; then
        pass "12 doctor --probe with model-not-selected: FAIL(model-not-selected), exit 1"
    else
        fail "12 doctor --probe with model-not-selected: FAIL(model-not-selected), exit 1"
        echo "    exit: $rc"
        echo "$out" | sed 's/^/    /'
    fi

    echo ""
    if [[ "$FAILURES" -ne 0 ]]; then
        echo "FAILED: $FAILURES assertion(s)."
        exit 1
    fi
    echo "PASS"
}

main "$@"
