#!/usr/bin/env bash
# Tests for bin/lib/agent-core.mjs, the shared job core of agent-dispatch (increment 0 of
# docs/superpowers/specs/2026-10-20-universal-dispatchers-design.md §8). Zero model calls: the core is driven through
# tests/fixtures/core-harness.mjs with the trivial adapter tests/fixtures/adapters/plain.mjs, whose harness is
# tests/fixtures/agent-stub.cjs; all state lives under a temp root (AGENT_DISPATCH_STATE_DIR). Runs on macOS and Linux.
#
# Every process a run starts carries the run's temp root in its argv — runners (their jobs dir), harness stubs (run
# through a per-run link, $AGENT_TEST_STUB), the stubs' descendants (their pid file) — so the leak check at the end and
# the cleanup touch this run's processes only, and parallel runs of the suite do not disturb each other.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE="$REPO_ROOT/bin/lib/agent-core.mjs"
FIX="$SCRIPT_DIR/fixtures"
HARNESS="$FIX/core-harness.mjs"
STUB="$FIX/agent-stub.cjs"

FAILURES=0
PASSES=0
TEST_ROOT=""
SLEEPERS=""

pass() {
    echo "  [PASS] $1"
    PASSES=$((PASSES + 1))
}
fail() {
    echo "  [FAIL] $1"
    FAILURES=$((FAILURES + 1))
}
# check <label> <command...> — PASS when the command succeeds.
check() {
    local label="$1"
    shift
    if "$@"; then pass "$label"; else fail "$label"; fi
}

cleanup() {
    # Only this run's processes (see the header). SIGKILL: some stubs and descendants ignore SIGTERM by design.
    if [[ -n "$TEST_ROOT" ]]; then pkill -KILL -f "$TEST_ROOT" 2>/dev/null || true; fi
    local pid
    for pid in $SLEEPERS; do kill "$pid" 2>/dev/null || true; done
    if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
        rm -rf "$TEST_ROOT"
    fi
}

ad() { node "$HARNESS" "$@"; }

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

# core_js <script> [args...] — run an ES module snippet with `core` = agent-core.mjs; args in process.argv.slice(1).
core_js() {
    local script="$1"
    shift
    CORE="$CORE" node --input-type=module -e "
const { pathToFileURL } = await import('node:url');
const core = await import(pathToFileURL(process.env.CORE).href);
$script" "$@"
}

# jobs_dir_of <repo> — the core's jobs directory of a work tree under the current state root.
jobs_dir_of() {
    core_js 'console.log(core.resolveWorkspace(process.argv[1]).jobsDir);' "$1"
}

# wait_status <id> <regex> <seconds> [status args...] — poll until the status matches; print it.
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

# wait_child <id> [status args...] — wait until the runner has recorded childPid; print it.
wait_child() {
    local id="$1"
    shift
    local child="" i=0
    while ((i < 75)); do
        child="$(ad status "$id" --json "$@" 2>/dev/null | jfield job.childPid || true)"
        if [[ -n "$child" ]]; then break; fi
        sleep 0.2
        i=$((i + 1))
    done
    echo "$child"
}

# wait_lines <file> <n> — wait up to 10 s until the file has n lines.
wait_lines() {
    local i=0
    while ((i < 50)); do
        if [[ -f "$1" && "$(wc -l <"$1" | tr -d ' ')" -ge "$2" ]]; then return 0; fi
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

# wait_file <file> — wait up to 10 s until the file exists and is not empty (the stub's readiness handshake).
wait_file() {
    local i=0
    while ((i < 50)); do
        if [[ -s "$1" ]]; then return 0; fi
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

# gone <pid...> — true once none of the processes exists (waits up to 5 s); false for no pid or an empty one, so a
# missing pid can never pass as a dead process.
gone() {
    local i=0 pid alive
    if (($# == 0)); then return 1; fi
    for pid in "$@"; do [[ -n "$pid" ]] || return 1; done
    while ((i < 25)); do
        alive=0
        for pid in "$@"; do
            if kill -0 "$pid" 2>/dev/null; then alive=1; fi
        done
        if ((alive == 0)); then return 0; fi
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

# start_task [task args...] — run `task --background`, print the new job id (the last word of the start line).
start_task() {
    local out
    out="$(ad task --background "$@")"
    echo "${out##* }"
}

now_ms() { node -e 'console.log(Date.now())'; }

# spawn_sleeper — a detached `sleep` leading its own process group (a stand-in for an unrelated process that reused
# a pid after a reboot); print its pid.
spawn_sleeper() {
    node -e 'const c = require("node:child_process").spawn("sleep", ["120"], { detached: true, stdio: "ignore" }); c.unref(); console.log(c.pid);'
}

# count_records <jobs-dir> — number of job records.
count_records() {
    local n=0 f
    for f in "$1"/*.json; do [[ -e "$f" ]] && n=$((n + 1)); done
    echo "$n"
}

# mode_of <path> — octal permission bits.
mode_of() { node -e 'console.log((require("node:fs").statSync(process.argv[1]).mode & 0o777).toString(8))' "$1"; }

# with_deadline <seconds> <command...> — run the command, but kill it (exit 124) if it still runs after that many
# seconds: a regression that hangs fails its check instead of blocking the suite (macOS has no `timeout`).
with_deadline() {
    local limit="$1" pid i=0 rc=0
    shift
    "$@" &
    pid=$!
    while ((i < limit * 10)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" || rc=$?
            return "$rc"
        fi
        sleep 0.1
        i=$((i + 1))
    done
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 124
}

# fixture_record <jobs-dir> <id> <json> — a `running` job record of the current boot without a runner, its fields
# overridden by the JSON object.
fixture_record() {
    core_js '
const fs = await import("node:fs");
const [dir, id, extra] = process.argv.slice(1);
fs.mkdirSync(dir, { recursive: true });
const record = { id, status: "running", errorClass: null, profile: "p1", harness: "plain", write: false, sessionId: "s-fixture",
  resumeOf: null, workspaceRoot: null, cwd: null, promptPath: null, promptBytes: 10, runnerPid: null, runnerStartedAt: null,
  childPid: null, childStartedAt: null, startedAt: new Date().toISOString(), bootId: core.bootId(), finishedAt: null,
  timeoutMin: 1, cancelLadder: [["SIGTERM", 200], ["SIGKILL", 0]], hasSecret: false, profileConfig: { harness: "plain" },
  note: null, ...JSON.parse(extra) };
fs.writeFileSync(`${dir}/${id}.json`, JSON.stringify(record));' "$@"
}

# spawn_family <file> — an unrelated process leading its own group, with a child in a group of its own (what may
# hold a dead runner's pid after reuse); writes "<parent> <child>" to the file once both run. Both carry the file's
# path (under the run's temp root) in their argv and keep the default signal dispositions.
spawn_family() {
    node -e '
const { spawn } = require("node:child_process");
const script = `
  const { spawn } = require("node:child_process");
  const c = spawn(process.execPath, ["-e", "setInterval(() => {}, 1 << 30)", "family-child", process.argv[1]], { detached: true, stdio: "ignore" });
  require("node:fs").writeFileSync(process.argv[1], process.pid + " " + c.pid);
  setInterval(() => {}, 1 << 30);`;
spawn(process.execPath, ["-e", script, process.argv[1]], { detached: true, stdio: "ignore" }).unref();' "$1"
    wait_file "$1"
}

main() {
    echo "=== Test: agent-core ==="

    TEST_ROOT="$(mktemp -d)"
    trap cleanup EXIT
    umask 022

    export HOME="$TEST_ROOT/home"
    mkdir -p "$HOME" "$TEST_ROOT/bin"
    export AGENT_DISPATCH_STATE_DIR="$TEST_ROOT/state"
    local STATE="$AGENT_DISPATCH_STATE_DIR"
    # The harness binary of this run: a link to the stub under the temp root (the plain adapter's default bin).
    ln -s "$STUB" "$TEST_ROOT/bin/agent-stub.cjs"
    export AGENT_TEST_STUB="$TEST_ROOT/bin/agent-stub.cjs"
    unset AGENT_TEST_BOOT_ID AGENT_TEST_PS_START AGENT_TEST_RUN_BARRIER CORE_HARNESS_RUN_BARRIER CLAUDE_CONFIG_DIR CORE_HARNESS_KEY_LOG TEST_SECRET
    unset AGENT_STUB_MODE AGENT_STUB_RECORD AGENT_STUB_DELAY_MS AGENT_STUB_MESSAGE AGENT_STUB_CLASS AGENT_STUB_EXIT
    unset AGENT_STUB_PIDS AGENT_STUB_SIGNALS AGENT_STUB_VERSION AGENT_STUB_HELP_DROP AGENT_STUB_RESPONSE AGENT_STUB_SECRET_VAR
    unset AGENT_STUB_CALL_LOG AGENT_STUB_HELP_EXIT AGENT_STUB_LAUNCH_LOG AGENT_STUB_VERSION_HANG WRAPPED
    export AGENT_ENV_PASSTHROUGH="AGENT_STUB_MODE,AGENT_STUB_RECORD,AGENT_STUB_DELAY_MS,AGENT_STUB_MESSAGE,AGENT_STUB_CLASS,AGENT_STUB_EXIT,AGENT_STUB_PIDS,AGENT_STUB_SIGNALS,AGENT_STUB_VERSION,AGENT_STUB_HELP_DROP,AGENT_STUB_RESPONSE,AGENT_STUB_SECRET_VAR,AGENT_STUB_CALL_LOG,AGENT_STUB_HELP_EXIT,AGENT_STUB_LAUNCH_LOG,AGENT_STUB_VERSION_HANG"

    local git_id=(-c user.email=t@example.com -c user.name=t -c commit.gpgsign=false)
    local r
    for r in repo repo2 repo3 repo4 repo5 repo6 repo7 repo8 repo9 repo10; do
        git init -q -b main "$TEST_ROOT/$r"
        printf 'x\n' >"$TEST_ROOT/$r/a.txt"
        (cd "$TEST_ROOT/$r" && git add a.txt && git "${git_id[@]}" commit -qm c0)
    done
    local repo repo2 repo3 repo4 repo5 repo6 repo7 repo8 repo9 repo10
    repo="$(cd "$TEST_ROOT/repo" && git rev-parse --show-toplevel)"
    repo2="$(cd "$TEST_ROOT/repo2" && git rev-parse --show-toplevel)"
    repo3="$(cd "$TEST_ROOT/repo3" && git rev-parse --show-toplevel)"
    repo4="$(cd "$TEST_ROOT/repo4" && git rev-parse --show-toplevel)"
    repo5="$(cd "$TEST_ROOT/repo5" && git rev-parse --show-toplevel)"
    repo6="$(cd "$TEST_ROOT/repo6" && git rev-parse --show-toplevel)"
    repo7="$(cd "$TEST_ROOT/repo7" && git rev-parse --show-toplevel)"
    repo8="$(cd "$TEST_ROOT/repo8" && git rev-parse --show-toplevel)"
    repo9="$(cd "$TEST_ROOT/repo9" && git rev-parse --show-toplevel)"
    repo10="$(cd "$TEST_ROOT/repo10" && git rev-parse --show-toplevel)"
    mkdir -p "$TEST_ROOT/notgit"
    local prompt="$TEST_ROOT/prompt.md"
    printf '## Headless run\n\nImplement the thing. Ünïcødé ok.\n' >"$prompt"
    cd "$repo"
    local JOBS
    JOBS="$(jobs_dir_of "$repo")"
    # From here on a failing command must not end the suite: FAILURES decides the exit code, and the summary prints.
    set +e

    local out out2 err rc id id2 st rec child runner t0 t1 pids d1 d2 before keylog

    # --- 1. ids: <prefix>-NNNN, one sequence per workspace, atomic under parallel tasks; the start line ---
    export AGENT_STUB_MODE=ok
    out="$(ad task --profile p1 --background --prompt-file "$prompt")"
    st="$(wait_status pt-0001 'completed|failed|cancelled' 20)"
    out2="$(ad task --profile p1 --background --prompt-file "$prompt")"
    wait_status pt-0002 'completed|failed|cancelled' 20 >/dev/null
    if [[ "$out" == "agent-dispatch: p1 task started in the background as pt-0001" \
        && "$out2" == "agent-dispatch: p1 task started in the background as pt-0002" && "$st" == completed ]]; then
        pass "1 task prints 'agent-dispatch: p1 task started in the background as pt-0001', the next id is pt-0002"
    else
        fail "1 task prints 'agent-dispatch: p1 task started in the background as pt-0001', the next id is pt-0002"
        echo "    out: $out | $out2 | status: $st"
    fi

    local par_ids="" k
    for k in 1 2 3 4 5; do
        (ad task --profile par --profile-json '{"harness":"plain","maxParallel":10}' --background --prompt-file "$prompt" >"$TEST_ROOT/par$k.out" 2>&1) &
    done
    wait
    for k in 1 2 3 4 5; do par_ids="$par_ids $(awk '{print $NF}' "$TEST_ROOT/par$k.out")"; done
    for id in $par_ids; do wait_status "$id" 'completed|failed|cancelled' 20 >/dev/null; done
    if [[ "$(tr ' ' '\n' <<<"$par_ids" | grep -cE '^pt-[0-9]{4}$')" -eq 5 && "$(tr ' ' '\n' <<<"$par_ids" | grep -E '^pt-' | sort -u | wc -l | tr -d ' ')" -eq 5 ]]; then
        pass "1 five parallel read-only tasks get five distinct ids (exclusive record creation)"
    else
        fail "1 five parallel read-only tasks get five distinct ids (exclusive record creation)"
        echo "    ids:$par_ids"; cat "$TEST_ROOT"/par*.out
    fi

    out="$(core_js '
const fs = await import("node:fs");
const dir = process.argv[1];
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(`${dir}/pt-0003.json`, "{}");
fs.writeFileSync(`${dir}/zt-0042.json`, "{}");
const a = core.allocateJob(dir, "ct", { status: "running" });
const b = core.allocateJob(dir, "oc", { status: "running" });
let refused = false;
try { core.allocateJob(dir, "zt", {}); } catch { refused = true; }
console.log([a, b, refused, core.isCoreJobId("zt-0001"), core.isCoreJobId("task-abc"), core.isCoreJobId("dt-0007")].join(" "));' "$TEST_ROOT/alloc-unit")"
    if [[ "$out" == "ct-0004 oc-0005 true false false true" ]]; then
        pass "1 allocateJob: one number sequence per workspace shared by all core prefixes (pt-0003 -> ct-0004, oc-0005); zt- is neither counted, allocated nor a core id"
    else
        fail "1 allocateJob: one number sequence per workspace shared by all core prefixes (pt-0003 -> ct-0004, oc-0005); zt- is neither counted, allocated nor a core id"
        echo "    got: $out"
    fi
    # 24 processes spin until one shared instant, then allocate at once: without the exclusive create they collide.
    local stress="$TEST_ROOT/alloc-stress" go_at
    mkdir -p "$stress/jobs"
    go_at=$(($(now_ms) + 2500))
    for ((k = 1; k <= 24; k++)); do
        core_js 'const go = Number(process.argv[2]); while (Date.now() < go) {} console.log(core.allocateJob(process.argv[1], "pt", {}));' \
            "$stress/jobs" "$go_at" >"$stress/out$k" 2>&1 &
    done
    wait
    if [[ "$(cat "$stress"/out* | grep -cE '^pt-[0-9]{4}$')" -eq 24 && "$(cat "$stress"/out* | sort -u | wc -l | tr -d ' ')" -eq 24 \
        && "$(count_records "$stress/jobs")" -eq 24 ]]; then
        pass "1 allocateJob under 24 simultaneous allocations: 24 distinct ids, 24 records"
    else
        fail "1 allocateJob under 24 simultaneous allocations: 24 distinct ids, 24 records"
        cat "$stress"/out* | sort | uniq -c | sort -rn | head -5
    fi

    # --- 2. status / result formats (spec §3.3) ---
    local sj
    sj="$(ad status pt-0001 --json)"
    if [[ "$(jfield job.id <<<"$sj")" == pt-0001 && "$(jfield job.status <<<"$sj")" == completed && -z "$(jfield job.errorClass <<<"$sj")" \
        && "$(jfield job.profile <<<"$sj")" == p1 && "$(jfield job.harness <<<"$sj")" == plain && "$(jfield job.write <<<"$sj")" == false \
        && "$(jfield job.harnessVersion <<<"$sj")" == 1.0.0 && "$(jfield job.workspaceRoot <<<"$sj")" == "$repo" ]]; then
        pass "2 status ID --json is {job:{…}} with id, status, errorClass, profile, harness, write, harnessVersion, workspaceRoot"
    else
        fail "2 status ID --json is {job:{…}} with id, status, errorClass, profile, harness, write, harnessVersion, workspaceRoot"
        echo "$sj" | head -40
    fi
    out="$(ad status pt-0001)"
    if [[ "$out" =~ ^pt-0001\ p1\ completed\ [0-9]+m[0-9]{2}s\ -\ [0-9a-f-]{36}$ ]]; then
        pass "2 status ID prints '<id> <profile> <state> <elapsed> <model> <session>'"
    else
        fail "2 status ID prints '<id> <profile> <state> <elapsed> <model> <session>'"
        echo "    got: $out"
    fi
    out="$(ad status)"
    out2="$(ad status --json)"
    if grep -Fqx "pt-0001 p1 completed write=no cwd=$repo" <<<"$out" \
        && OUT="$out2" ROOT="$repo" node -e '
const j = JSON.parse(process.env.OUT);
const e = j.jobs.find((x) => x.id === "pt-0001");
process.exit(Array.isArray(j.jobs) && e && e.profile === "p1" && e.status === "completed" && e.write === false && e.cwd === process.env.ROOT ? 0 : 1);'; then
        pass "2 status without ID: one line '<id> <profile> <status> write=<yes|no> cwd=<root>' per job; --json gives {jobs:[…]} with the same fields"
    else
        fail "2 status without ID: one line '<id> <profile> <status> write=<yes|no> cwd=<root>' per job; --json gives {jobs:[…]} with the same fields"
        echo "$out" | head -5
    fi
    rc=0
    out="$(ad result pt-0001)" || rc=$?
    if [[ "$rc" -eq 0 && "$out" == $'DONE\nstub finished' ]]; then
        pass "2 result of a completed job prints the response verbatim, exit 0"
    else
        fail "2 result of a completed job prints the response verbatim, exit 0"
        echo "    exit: $rc out: $out"
    fi

    # --- 3. reduce() alone decides success; patterns classify what it leaves open ---
    # expect_class <label> <want-status> <want-class> [env assignments...]
    expect_class() {
        local label="$1" want_status="$2" want_class="$3"
        shift 3
        local jid jst jec
        jid="$(env "$@" node "$HARNESS" task --background --profile p1 --prompt-file "$prompt" | awk '{print $NF}')"
        jst="$(wait_status "$jid" 'completed|failed|cancelled' 20)"
        jec="$(ad status "$jid" --json | jfield job.errorClass)"
        if [[ "$jst" == "$want_status" && "$jec" == "$want_class" ]]; then
            pass "$label"
        else
            fail "$label"
            echo "    $jid: $jst/$jec (want $want_status/$want_class)"
        fi
        LAST_ID="$jid"
    }
    LAST_ID=""
    expect_class "3 exit 0 with an error event reduce() leaves unclassified -> failed, class from the adapter's patterns (quota)" failed quota \
        AGENT_STUB_MODE=exit0-error AGENT_STUB_MESSAGE="Insufficient balance on the account"
    local quota_id="$LAST_ID"
    rc=0
    err="$(ad result "$quota_id" 2>&1 >/dev/null)" || rc=$?
    if [[ "$rc" -eq 1 && "$(head -1 <<<"$err")" == "job $quota_id is failed errorClass=quota" && "$err" == *"classified failed/quota"* ]]; then
        pass "3 result of a failed job: stderr 'job <id> is failed errorClass=quota' plus the log tail, exit 1"
    else
        fail "3 result of a failed job: stderr 'job <id> is failed errorClass=quota' plus the log tail, exit 1"
        echo "    exit: $rc err: $err"
    fi
    expect_class "3 exit 1 with a valid final answer -> completed (the exit code is informational)" completed "" AGENT_STUB_MODE=exit1-valid
    if [[ "$(ad status "$LAST_ID" --json | jfield job.exitCode)" == 1 && "$(ad result "$LAST_ID")" == $'DONE\nvalid despite exit 1' ]]; then
        pass "3 the completed exit-1 job keeps exitCode=1 in its record and result prints its answer"
    else
        fail "3 the completed exit-1 job keeps exitCode=1 in its record and result prints its answer"
    fi
    expect_class "3 the class reduce() reports wins (context), whatever the text" failed context \
        AGENT_STUB_MODE=exit0-error AGENT_STUB_CLASS=context AGENT_STUB_MESSAGE="401 would match auth"
    expect_class "3 a stderr pattern classifies a non-zero exit (401 -> auth)" failed auth AGENT_STUB_MODE=fail AGENT_STUB_MESSAGE="401 Unauthorized"
    expect_class "3 the adapter's 'transient' patterns map to the class server" failed server AGENT_STUB_MODE=fail AGENT_STUB_MESSAGE="read ECONNRESET"
    expect_class "3 rate-limit pattern (429)" failed rate-limit AGENT_STUB_MODE=fail AGENT_STUB_MESSAGE="HTTP 429 slow down"
    expect_class "3 resume-lost pattern" failed resume-lost AGENT_STUB_MODE=fail AGENT_STUB_MESSAGE="No conversation found with session ID x"
    expect_class "3 exit 0 without a final answer -> malformed" failed malformed AGENT_STUB_MODE=malformed
    expect_class "3 exit 0 with an unrecognised error event -> malformed" failed malformed AGENT_STUB_MODE=exit0-error AGENT_STUB_MESSAGE="something odd"
    expect_class "3 a non-zero exit without a recognised error -> crash" failed crash AGENT_STUB_MODE=fail AGENT_STUB_MESSAGE="segfault-ish"
    expect_class "3 death by signal -> crash" failed crash AGENT_STUB_MODE=crash

    out="$(core_js '
const c = (io, reduced, patterns) => { const v = core.classifyOutcome({ io: { exit: { code: 0, signal: null }, stdout: "", stderrTail: "", ...io }, reduced, patterns }); return `${v.status}/${v.errorClass}`; };
console.log([
  c({ timedOut: true }, { ok: true, response: "x" }),
  c({ spawnError: new Error("ENOENT") }, null),
  c({}, { ok: true, response: "" }),
  c({}, { ok: false, errorClass: "not-a-class", errorText: "quota hit" }, { quota: [/quota/] }),
  c({ stderrTail: "bad gateway 502" }, { ok: false }, { server: ["502"], auth: ["gateway"] }),
  core.ERROR_CLASSES.length,
].join(" "));')"
    if [[ "$out" == "failed/timeout failed/launch completed/null failed/quota failed/auth 12" ]]; then
        pass "3 classifyOutcome order: timeout > spawn error (launch) > reduce ok > reduce class > patterns in PATTERN_ORDER (RegExp too); 12 error classes"
    else
        fail "3 classifyOutcome order: timeout > spawn error (launch) > reduce ok > reduce class > patterns in PATTERN_ORDER (RegExp too); 12 error classes"
        echo "    got: $out"
    fi

    # --- 4. UTF-8 joined across chunk boundaries ---
    id="$(AGENT_STUB_MODE=split-utf8 start_task --profile p1 --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    if [[ "$st" == completed && "$(ad result "$id")" == "Ответ: Привет ё" ]] && grep -Fq "прогресс: ёлка готова" "$JOBS/$id.log"; then
        pass "4 stdout and stderr split inside multi-byte characters arrive intact (response and log)"
    else
        fail "4 stdout and stderr split inside multi-byte characters arrive intact (response and log)"
        echo "    status: $st result: $(ad result "$id" 2>&1 | head -3)"
    fi

    # --- 5. the environment allowlist (spec §3.6 А10) ---
    rec="$TEST_ROOT/env.json"
    rc=0
    out="$(env AGENT_STUB_MODE=ok AGENT_STUB_RECORD="$rec" \
        GITHUB_TOKEN=fake-gh ANTHROPIC_API_KEY=fake-anthropic ANTHROPIC_BASE_URL=https://evil.example OPENAI_API_KEY=fake-openai \
        CLAUDE_CODE_ENTRYPOINT=cli CLAUDECODE=1 MY_SERVICE_TOKEN=fake-svc DB_PASSWORD=fake-db SSH_AUTH_SOCK=/tmp/fake.sock \
        ZCODE_HTTP_PROXY=http://127.0.0.1:1082 ZCODE_CREDENTIAL_SECRET=fake-cred XDG_FAKE_TOKEN=fake-xdg UNLISTED_VAR=nope \
        LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 XDG_CACHE_HOME="$TEST_ROOT/xdg" TZ=UTC JAVA_HOME=/opt/fake-jdk \
        HTTPS_PROXY=http://proxy.example:8080 NODE_EXTRA_CA_CERTS="$TEST_ROOT/ca.pem" EXTRA_VAR=extra NPM_TOKEN=fake-npm \
        CLAUDE_CONFIG_DIR="$TEST_ROOT/claude-home" \
        AGENT_ENV_PASSTHROUGH="$AGENT_ENV_PASSTHROUGH,EXTRA_VAR,NPM_TOKEN" \
        node "$HARNESS" task --background --profile p1 --prompt-file "$prompt")" || rc=$?
    id="${out##* }"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    if [[ "$rc" -eq 0 && "$st" == completed ]] && REC="$rec" T="$TEST_ROOT" WANT_PATH="$PATH" WANT_HOME="$HOME" node -e '
const e = JSON.parse(require("node:fs").readFileSync(process.env.REC, "utf8")).env;
const dropped = ["GITHUB_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "OPENAI_API_KEY", "CLAUDE_CODE_ENTRYPOINT", "CLAUDECODE",
  "MY_SERVICE_TOKEN", "DB_PASSWORD", "SSH_AUTH_SOCK", "ZCODE_HTTP_PROXY", "ZCODE_CREDENTIAL_SECRET", "XDG_FAKE_TOKEN", "UNLISTED_VAR",
  "AGENT_ENV_PASSTHROUGH", "AGENT_DISPATCH_STATE_DIR"];
const want = { PATH: process.env.WANT_PATH, HOME: process.env.WANT_HOME, LANG: "en_US.UTF-8", LC_ALL: "en_US.UTF-8",
  XDG_CACHE_HOME: `${process.env.T}/xdg`, TZ: "UTC", JAVA_HOME: "/opt/fake-jdk", HTTPS_PROXY: "http://proxy.example:8080",
  NODE_EXTRA_CA_CERTS: `${process.env.T}/ca.pem`, EXTRA_VAR: "extra", NPM_TOKEN: "fake-npm", AGENT_STUB_MODE: "ok",
  CLAUDE_CONFIG_DIR: `${process.env.T}/claude-home` };
const leaked = dropped.filter((n) => n in e);
const wrong = Object.entries(want).filter(([n, v]) => e[n] !== v).map(([n]) => n);
if (leaked.length || wrong.length) console.error(`    leaked: ${leaked.join(" ")} | missing or wrong: ${wrong.join(" ")}`);
process.exit(leaked.length || wrong.length ? 1 : 0);'; then
        pass "5 allowlist: secrets, ANTHROPIC_*/CLAUDE*/ZCODE_* and unlisted names dropped; basics, LC_/XDG_, proxy/CA, toolchain and AGENT_ENV_PASSTHROUGH names pass; the adapter's home variable (CLAUDE_CONFIG_DIR) is re-admitted for home=user"
    else
        fail "5 allowlist: secrets, ANTHROPIC_*/CLAUDE*/ZCODE_* and unlisted names dropped; basics, LC_/XDG_, proxy/CA, toolchain and AGENT_ENV_PASSTHROUGH names pass; the adapter's home variable (CLAUDE_CONFIG_DIR) is re-admitted for home=user"
        echo "    exit=$rc status=$st"
    fi
    out="$(core_js 'console.log(JSON.stringify([core.ENV_ALLOW.filter((n) => n.startsWith("ZCODE_")), core.ENV_ALLOW_PREFIXES, core.ENV_PASSTHROUGH_VAR]));')"
    if [[ "$out" == '[[],["LC_","XDG_"],"AGENT_ENV_PASSTHROUGH"]' ]]; then
        pass "5 ENV_ALLOW has no ZCODE_* entries; prefixes LC_ and XDG_; passthrough variable AGENT_ENV_PASSTHROUGH"
    else
        fail "5 ENV_ALLOW has no ZCODE_* entries; prefixes LC_ and XDG_; passthrough variable AGENT_ENV_PASSTHROUGH"
        echo "    got: $out"
    fi
    id="$(CLAUDE_CONFIG_DIR="$TEST_ROOT/claude-home" AGENT_STUB_RECORD="$rec" start_task --profile iso --profile-json '{"harness":"plain","home":"isolated"}' --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    if [[ "$st" == completed ]] && REC="$rec" HOMEDIR="$STATE/homes/iso" node -e '
const e = JSON.parse(require("node:fs").readFileSync(process.env.REC, "utf8")).env;
process.exit(!("CLAUDE_CONFIG_DIR" in e) && e.PLAIN_HOME_DIR === process.env.HOMEDIR ? 0 : 1);' \
        && [[ "$(mode_of "$STATE/homes/iso/settings.json")" == 600 && "$(mode_of "$STATE/homes/iso")" == 700 \
            && -d "$STATE/homes/iso/sessions" && "$(mode_of "$STATE/homes/iso/sessions")" == 700 ]]; then
        pass "5 home=isolated: the home variable is not re-admitted; prepareHome's env reaches the harness, its dirs are created 0700 and its files written 0600"
    else
        fail "5 home=isolated: the home variable is not re-admitted; prepareHome's env reaches the harness, its dirs are created 0700 and its files written 0600"
        echo "    status=$st"
    fi
    before="$(count_records "$JOBS")"
    rc=0
    err="$(AGENT_ENV_PASSTHROUGH="AGENT_STUB_MODE,BAD-NAME" ad task --background --profile p1 --prompt-file "$prompt" 2>&1)" || rc=$?
    if [[ "$rc" -eq 2 && "$err" == *"AGENT_ENV_PASSTHROUGH holds invalid variable names: BAD-NAME"* && "$(count_records "$JOBS")" == "$before" ]]; then
        pass "5 an invalid name in AGENT_ENV_PASSTHROUGH is refused before any job exists (exit 2)"
    else
        fail "5 an invalid name in AGENT_ENV_PASSTHROUGH is refused before any job exists (exit 2)"
        echo "    exit=$rc err=$err"
    fi

    # --- 6. layering: allowlist → adapter defaults → profile.env → mandatory → key; mandatory names are refused ---
    id="$(env AGENT_STUB_RECORD="$rec" PLAIN_MODE=inherited PLAIN_TELEMETRY=inherited PLAIN_SAFE=evil PLAIN_DROPPED=inherited \
        AGENT_ENV_PASSTHROUGH="$AGENT_ENV_PASSTHROUGH,PLAIN_MODE,PLAIN_TELEMETRY,PLAIN_SAFE,PLAIN_DROPPED" \
        node "$HARNESS" task --background --profile layer --profile-json '{"harness":"plain","env":{"PLAIN_MODE":"profile","FROM_PROFILE":"p"}}' --prompt-file "$prompt" | awk '{print $NF}')"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    if [[ "$st" == completed ]] && REC="$rec" DIR="$JOBS/$id" node -e '
const e = JSON.parse(require("node:fs").readFileSync(process.env.REC, "utf8")).env;
const ok = e.PLAIN_MODE === "profile" && e.PLAIN_TELEMETRY === "0" && e.PLAIN_SAFE === "1" && !("PLAIN_DROPPED" in e)
  && e.FROM_PROFILE === "p" && e.PLAIN_JOB_DIR === process.env.DIR;
if (!ok) console.error(`    ${JSON.stringify({ m: e.PLAIN_MODE, t: e.PLAIN_TELEMETRY, s: e.PLAIN_SAFE, d: e.PLAIN_DROPPED, f: e.FROM_PROFILE, j: e.PLAIN_JOB_DIR })}`);
process.exit(ok ? 0 : 1);'; then
        pass "6 env layering: adapter default beats inherited, profile.env beats the default, mandatory beats inherited, a null mandatory value removes the name"
    else
        fail "6 env layering: adapter default beats inherited, profile.env beats the default, mandatory beats inherited, a null mandatory value removes the name"
    fi
    before="$(count_records "$JOBS")"
    rc=0
    err="$(ad task --background --write --profile clash --profile-json '{"harness":"plain","env":{"PLAIN_SAFE":"0"}}' --prompt-file "$prompt" 2>&1)" || rc=$?
    id="$(AGENT_STUB_MODE=ok start_task --write --profile p1 --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    if [[ "$rc" -eq 2 && "$err" == *"profile clash: env PLAIN_SAFE conflicts with a mandatory setting of the plain adapter"* \
        && "$(($(count_records "$JOBS") - 1))" == "$before" && "$st" == completed ]]; then
        pass "6 profile.env touching a mandatory name: task exit 2 naming it, refused before any reservation; no job record left; the next write task runs"
    else
        fail "6 profile.env touching a mandatory name: task exit 2 naming it, refused before any reservation; no job record left; the next write task runs"
        echo "    exit=$rc err=$err next=$st"
    fi
    rc=0
    keylog="$TEST_ROOT/keylog-clash.txt"
    err="$(CORE_HARNESS_KEY_LOG="$keylog" TEST_SECRET=sk-layer-0123456789 ad task --background --profile clash2 --profile-json '{"harness":"plain","auth":{"keyEnv":"TEST_SECRET"},"env":{"PLAIN_API_KEY":"x"}}' --prompt-file "$prompt" 2>&1)" || rc=$?
    if [[ "$rc" -eq 2 && "$err" == *"env PLAIN_API_KEY conflicts with a mandatory setting"* && ! -e "$keylog" ]]; then
        pass "6 profile.env setting the key variable (secretEnv) is a mandatory-name conflict too (exit 2); the key source is never read"
    else
        fail "6 profile.env setting the key variable (secretEnv) is a mandatory-name conflict too (exit 2); the key source is never read"
        echo "    exit=$rc err=$err keylog=$(cat "$keylog" 2>/dev/null)"
    fi
    id="$(AGENT_STUB_MODE=ok start_task --profile same --profile-json '{"harness":"plain","env":{"PLAIN_SAFE":"1"}}' --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    out="$(core_js 'console.log(JSON.stringify(core.envConflicts({ A: "1", B: "x", K: "v", N: null, O: "free" }, { mandatory: { A: "1", B: "y", N: null }, secretEnv: ["K"] })));')"
    if [[ "$st" == completed && "$out" == '["B","K"]' ]]; then
        pass "6 a profile.env value identical to the mandatory one changes nothing and runs; a key variable always conflicts"
    else
        fail "6 a profile.env value identical to the mandatory one changes nothing and runs; a key variable always conflicts"
        echo "    status=$st envConflicts=$out"
    fi
    out="$(ad env-conflicts --profile doc --profile-json '{"harness":"plain","auth":{"keyEnv":"TEST_SECRET"},"env":{"PLAIN_SAFE":"0","PLAIN_API_KEY":"y","PLAIN_MODE":"z"}}')"
    if [[ "$out" == "conflicts: PLAIN_API_KEY PLAIN_SAFE (mandatory: PLAIN_SAFE PLAIN_JOB_DIR PLAIN_DROPPED PLAIN_API_KEY)" ]]; then
        pass "6 doctor's env check without a job: mandatorySettings() names the mandatory and key variables, envConflicts() the clashes"
    else
        fail "6 doctor's env check without a job: mandatorySettings() names the mandatory and key variables, envConflicts() the clashes"
        echo "    got: $out"
    fi
    out="$(core_js '
const env = core.buildEnv({ source: { PATH: "/bin", A_TOKEN: "t", KEEP: "k" }, defaults: { D: "d", PATH: "/x" }, profileEnv: { D: "p", P: "1" }, mandatory: { M: "m", P: null }, secretEnv: ["S1", "S2"], secret: "v" });
let threw = false;
try { core.buildEnv({ source: {}, secretEnv: ["S"], secret: null }); } catch { threw = true; }
console.log(JSON.stringify(env), threw);')"
    if [[ "$out" == '{"PATH":"/x","D":"p","M":"m","S1":"v","S2":"v"} true' ]]; then
        pass "6 buildEnv: layers in order, null removes, every secretEnv name gets the key; a secretEnv without a key throws"
    else
        fail "6 buildEnv: layers in order, null removes, every secretEnv name gets the key; a secretEnv without a key throws"
        echo "    got: $out"
    fi

    # --- 7. the key: handed over in a 0600 file, removed after spawn, only in the harness env, redacted everywhere ---
    local SECRET="sk-test-$$-a1b2c3d4e5f6g7h8"
    local keyed='{"harness":"plain","auth":{"keyEnv":"TEST_SECRET"}}'
    rec="$TEST_ROOT/secret.json"
    # The key arrives padded, as a keyCmd's stdout would (spaces, a trailing newline): the core trims it, and the bare
    # key the harness prints is what the redactor must catch.
    id="$(TEST_SECRET="  $SECRET"$'\n' AGENT_STUB_MODE=leak-secret AGENT_STUB_RECORD="$rec" start_task --profile keyed --profile-json "$keyed" --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    local status_json result_out
    status_json="$(ad status "$id" --json)"
    result_out="$(ad result "$id")"
    if [[ "$st" == completed ]] && REC="$rec" S="$SECRET" node -e '
const r = JSON.parse(require("node:fs").readFileSync(process.env.REC, "utf8"));
process.exit(r.env.PLAIN_API_KEY === process.env.S && !("TEST_SECRET" in r.env) && !r.argv.some((a) => a.includes(process.env.S)) ? 0 : 1);'; then
        pass "7 the key reaches the harness trimmed and only in its secretEnv variable (PLAIN_API_KEY): not in argv, not under its source name"
    else
        fail "7 the key reaches the harness trimmed and only in its secretEnv variable (PLAIN_API_KEY): not in argv, not under its source name"
        echo "    status=$st"
    fi
    if ! grep -Fq "$SECRET" "$JOBS/$id.log" && grep -Fq "leaked: <redacted> (end)" "$JOBS/$id.log" \
        && [[ "$status_json" != *"$SECRET"* && "$result_out" != *"$SECRET"* && "$result_out" == *"key=<redacted>"* ]] \
        && ! grep -rFq "$SECRET" "$STATE"; then
        pass "7 a key printed by the harness (split across stderr chunks, inside a JSON event) is redacted in the log, status, result and every state file"
    else
        fail "7 a key printed by the harness (split across stderr chunks, inside a JSON event) is redacted in the log, status, result and every state file"
        grep -n "leaked" "$JOBS/$id.log" | head -3
    fi
    if [[ ! -e "$JOBS/$id/secret" && "$(jfield job.hasSecret <<<"$status_json")" == true ]]; then
        pass "7 the handoff file is gone once the job ran"
    else
        fail "7 the handoff file is gone once the job ran"
    fi
    id="$(TEST_SECRET="$SECRET" AGENT_STUB_MODE=hang start_task --profile keyed --profile-json "$keyed" --prompt-file "$prompt")"
    child="$(wait_child "$id")"
    ps -A -o args= >"$TEST_ROOT/ps-args.txt"
    if [[ -n "$child" && ! -e "$JOBS/$id/secret" ]] && ! grep -Fq "$SECRET" "$TEST_ROOT/ps-args.txt" && grep -Fq "$JOBS" "$TEST_ROOT/ps-args.txt"; then
        pass "7 while the harness runs: the handoff file is already removed and no process argv (runner, harness) holds the key"
    else
        fail "7 while the harness runs: the handoff file is already removed and no process argv (runner, harness) holds the key"
        echo "    child=$child secret-file=$([[ -e "$JOBS/$id/secret" ]] && echo present || echo absent)"
    fi
    ad cancel "$id" >/dev/null
    # The key refusals are the core's (the harness hands the raw value over): exit 2, errorClass=auth, no job left.
    key_refusal() {
        local label="$1" needle="$2" pj="$3"
        shift 3
        local krc=0 kerr kbefore
        kbefore="$(count_records "$JOBS")"
        kerr="$(env "$@" node "$HARNESS" task --background --profile keyed --profile-json "$pj" --prompt-file "$prompt" 2>&1)" || krc=$?
        if [[ "$krc" -eq 2 && "$kerr" == *"keyed: key unavailable ($needle) errorClass=auth"* && "$(count_records "$JOBS")" == "$kbefore" ]]; then
            pass "$label"
        else
            fail "$label"
            echo "    exit=$krc err=$kerr"
        fi
    }
    key_refusal "7 an empty key: the core refuses 'key unavailable (resolved to an empty value) … errorClass=auth' (exit 2), no job" \
        "resolved to an empty value" "$keyed" TEST_SECRET=
    key_refusal "7 a key of blanks is empty once trimmed: the same refusal" "resolved to an empty value" "$keyed" "TEST_SECRET=   "
    key_refusal "7 whitespace inside the key: refused, the value is not echoed" "the resolved value contains whitespace" "$keyed" "TEST_SECRET=sk-a b"
    key_refusal "7 a keyed adapter and nothing resolved (an auth this harness has no source for): refused naming the key variable" \
        "nothing resolved for PLAIN_API_KEY" '{"harness":"plain","auth":{"key":"x"}}'
    before="$(count_records "$JOBS")"
    rc=0
    err="$(TEST_SECRET="$SECRET" ad task --background --profile keyed --profile-json "{\"harness\":\"plain\",\"auth\":{\"keyEnv\":\"TEST_SECRET\"},\"model\":\"$SECRET\"}" --prompt-file "$prompt" 2>&1)" || rc=$?
    if [[ "$rc" -eq 2 && "$err" == *"profile keyed: a profile field holds the key itself"* && "$err" != *"$SECRET"* && "$(count_records "$JOBS")" == "$before" ]] \
        && ! grep -rFq "$SECRET" "$STATE"; then
        pass "7 a profile field holding the key (model = the key): refused (exit 2) without echoing it; no record or other state file keeps it"
    else
        fail "7 a profile field holding the key (model = the key): refused (exit 2) without echoing it; no record or other state file keeps it"
        echo "    exit=$rc err=$err"
        grep -rlF "$SECRET" "$STATE" | head -3
    fi
    # An adapter that leaks the key (tests/fixtures/adapters/plain.mjs, plain-leak): the runner refuses or redacts.
    leak_case() {
        local label="$1" leak="$2" needle="$3" lid lsj lrec="$TEST_ROOT/leak-$2.json"
        rm -f "$lrec"
        lid="$(TEST_SECRET="$SECRET" AGENT_STUB_MODE=ok AGENT_STUB_RECORD="$lrec" start_task --profile leaky \
            --profile-json "{\"harness\":\"plain-leak\",\"auth\":{\"keyEnv\":\"TEST_SECRET\"},\"leak\":\"$leak\"}" --prompt-file "$prompt")"
        wait_status "$lid" 'completed|failed|cancelled' 20 >/dev/null
        lsj="$(ad status "$lid" --json)"
        if [[ "$(jfield job.status <<<"$lsj")" == failed && "$(jfield job.errorClass <<<"$lsj")" == launch && "$(jfield job.note <<<"$lsj")" == *"$needle"* \
            && ! -e "$lrec" && "$lsj" != *"$SECRET"* ]] && grep -Fq "$needle" "$JOBS/$lid.log" && ! grep -rFq "$SECRET" "$STATE"; then
            pass "$label"
        else
            fail "$label"
            echo "    $lid: $(jfield job.status <<<"$lsj")/$(jfield job.errorClass <<<"$lsj") note=$(jfield job.note <<<"$lsj")"
        fi
    }
    leak_case "7 an adapter that puts the key into argv: failed/launch, the harness never runs, the key is in no state file" \
        argv "the adapter put the key into argv; refusing to start"
    leak_case "7 an adapter that puts the key into a file it asks for: failed/launch, the file is never written" \
        file "the adapter put the key into a file it asked for"
    leak_case "7 an adapter error that carries the key (discover): failed/launch, the key redacted in the note and the log" \
        discover "cannot start with key <redacted>"
    # The same leak through the probe (doctor --probe): its discover() runs in the foreground, so the probe resolves the
    # key before it, as the runner of a job has it before discover().
    rc=0
    out="$(TEST_SECRET="$SECRET" ad probe --profile leaky --profile-json '{"harness":"plain-leak","auth":{"keyEnv":"TEST_SECRET"},"leak":"discover"}' 2>&1)" || rc=$?
    if [[ "$rc" -eq 1 && "$out" == *"cannot start with key <redacted>"* && "$out" != *"$SECRET"* ]] && ! grep -rFq "$SECRET" "$STATE"; then
        pass "7 a probe whose adapter error carries the key (discover): the error is redacted (the probe knows the key before discover runs)"
    else
        fail "7 a probe whose adapter error carries the key (discover): the error is redacted (the probe knows the key before discover runs)"
        echo "    exit=$rc out=${out//$SECRET/<SECRET>}"
    fi
    rc=0
    err="$(TEST_SECRET= ad task --background --write --profile keyed --profile-json "$keyed" --prompt-file "$prompt" 2>&1)" || rc=$?
    id="$(AGENT_STUB_MODE=ok start_task --write --profile p1 --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    if [[ "$rc" -eq 2 && "$err" == *"key unavailable (resolved to an empty value) errorClass=auth"* && "$st" == completed ]]; then
        pass "7 a write task refused for its key after it took the reservation releases the reservation: the next write task runs"
    else
        fail "7 a write task refused for its key after it took the reservation releases the reservation: the next write task runs"
        echo "    exit=$rc err=$err next=$st"
    fi
    # A record that expects a handed-over key whose file is missing: the runner refuses to start the harness.
    rec="$TEST_ROOT/nokey.json"
    rm -f "$rec"
    REPO="$repo" JOBS="$JOBS" PROMPT="$prompt" node -e '
const fs = require("node:fs");
const id = "pt-0500";
fs.mkdirSync(`${process.env.JOBS}/${id}`, { recursive: true });
fs.copyFileSync(process.env.PROMPT, `${process.env.JOBS}/${id}/prompt.md`);
fs.writeFileSync(`${process.env.JOBS}/${id}.json`, JSON.stringify({ id, status: "running", errorClass: null, profile: "keyed", harness: "plain",
  write: false, sessionId: "s", resumeOf: null, workspaceRoot: process.env.REPO, cwd: process.env.REPO,
  promptPath: `${process.env.JOBS}/${id}/prompt.md`, promptBytes: 10, runnerPid: null, childPid: null,
  startedAt: new Date().toISOString(), timeoutMin: 1, cancelLadder: [["SIGTERM", 1000], ["SIGKILL", 0]], hasSecret: true,
  profileConfig: { harness: "plain", auth: { keyEnv: "TEST_SECRET" } } }));'
    rc=0
    AGENT_STUB_MODE=ok AGENT_STUB_RECORD="$rec" ad __run pt-0500 "$JOBS" - >/dev/null 2>&1 || rc=$?
    sj="$(ad status pt-0500 --json)"
    if [[ "$rc" -eq 1 && "$(jfield job.status <<<"$sj")" == failed && "$(jfield job.errorClass <<<"$sj")" == auth && "$(jfield job.note <<<"$sj")" == *"handoff"* && ! -e "$rec" ]]; then
        pass "7 hasSecret without a handoff file: failed/auth and the harness is never started"
    else
        fail "7 hasSecret without a handoff file: failed/auth and the harness is never started"
        echo "    exit=$rc $(jfield job.status <<<"$sj")/$(jfield job.errorClass <<<"$sj") note=$(jfield job.note <<<"$sj")"
    fi
    out="$( (umask 000 && core_js '
const fs = await import("node:fs");
const f = core.writeSecretFile(process.argv[1], "pt-0001", "abc");
const r = core.redactor(["k\"ey\\x", "short"]);
const text = r(`a k"ey\\x b ${JSON.stringify("k\"ey\\x")} c short d`);
console.log((fs.statSync(f).mode & 0o777).toString(8), (fs.statSync(`${process.argv[1]}/pt-0001`).mode & 0o777).toString(8), text);' "$TEST_ROOT/secret-unit") )"
    if [[ "$out" == '600 700 a <redacted> b "<redacted>" c <redacted> d' ]]; then
        pass "7 writeSecretFile is 0600 in a 0700 job dir even under umask 000; redactor catches raw and JSON-escaped forms"
    else
        fail "7 writeSecretFile is 0600 in a 0700 job dir even under umask 000; redactor catches raw and JSON-escaped forms"
        echo "    got: $out"
    fi

    # --- 8. one write job per working tree; read-only jobs run beside it ---
    local wa
    wa="$(AGENT_STUB_MODE=hang start_task --write --profile p1 --prompt-file "$prompt")"
    child="$(wait_child "$wa")"
    runner="$(ad status "$wa" --json | jfield job.runnerPid)"
    rc=0
    err="$(AGENT_STUB_MODE=ok ad task --background --write --profile p2 --prompt-file "$prompt" 2>&1)" || rc=$?
    id="$(AGENT_STUB_MODE=ok start_task --profile p2 --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    if [[ -n "$child" && "$rc" -eq 2 && "$err" == *"job $wa is still running in this workspace; one write task per working tree"* && "$st" == completed \
        && "$(ad status "$wa" --json | jfield job.status)" == running ]]; then
        pass "8 a second write job in the same tree is refused (exit 2) naming the holder; a read-only job runs and completes beside it"
    else
        fail "8 a second write job in the same tree is refused (exit 2) naming the holder; a read-only job runs and completes beside it"
        echo "    exit=$rc err=$err read-only=$st"
    fi
    ad cancel "$wa" >/dev/null
    local after_cancel=exited
    if kill -0 "$runner" 2>/dev/null; then after_cancel=alive; fi
    rc=0
    err="$(AGENT_STUB_MODE=ok ad task --background --write --profile p1 --prompt-file "$prompt" 2>&1)" || rc=$?
    id="${err##* }"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    if [[ -n "$runner" && "$after_cancel" == exited && "$rc" -eq 0 && "$st" == completed ]] && grep -q "cancel: SIGTERM to groups" "$JOBS/$wa.log" \
        && ! grep -q "cancel stops the tree itself" "$JOBS/$wa.log"; then
        pass "8 cancel waits while the holder's runner stops the tree, releases the reservation and exits: a write task sent right after it runs"
    else
        fail "8 cancel waits while the holder's runner stops the tree, releases the reservation and exits: a write task sent right after it runs"
        echo "    runner $runner when cancel returned: $after_cancel; exit=$rc out=$err status=$st"; grep cancel "$JOBS/$wa.log"
    fi

    # --- 9. maxParallel counts running jobs of a profile across all workspaces ---
    local m1 JOBS2
    JOBS2="$(jobs_dir_of "$repo2")"
    m1="$(AGENT_STUB_MODE=hang start_task --profile mp --profile-json '{"harness":"plain","maxParallel":1}' --prompt-file "$prompt")"
    wait_child "$m1" >/dev/null
    before="$(count_records "$JOBS2")"
    keylog="$TEST_ROOT/keylog-mp.txt"
    rc=0
    err="$(CORE_HARNESS_KEY_LOG="$keylog" TEST_SECRET="$SECRET" ad task --background --cwd "$repo2" --profile mp \
        --profile-json '{"harness":"plain","maxParallel":1,"auth":{"keyEnv":"TEST_SECRET"}}' --prompt-file "$prompt" 2>&1)" || rc=$?
    out="$(ad count-running --profile mp)"
    id="$(AGENT_STUB_MODE=ok start_task --cwd "$repo2" --profile other --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20 --cwd "$repo2")"
    if [[ "$rc" -eq 2 && "$err" == *"profile mp is at maxParallel=1 (running: $m1)"* && "$out" == "1 $m1" && "$st" == completed \
        && "$(($(count_records "$JOBS2") - 1))" == "$before" && ! -e "$keylog" ]]; then
        pass "9 maxParallel=1: a task of the same profile in another tree is refused (exit 2) naming the running job, leaves no record and never reads its key; the counter sees it; other profiles run"
    else
        fail "9 maxParallel=1: a task of the same profile in another tree is refused (exit 2) naming the running job, leaves no record and never reads its key; the counter sees it; other profiles run"
        echo "    exit=$rc err=$err count=$out other=$st keylog=$(cat "$keylog" 2>/dev/null)"
    fi
    ad cancel "$m1" >/dev/null
    id="$(AGENT_STUB_MODE=ok start_task --cwd "$repo2" --profile mp --profile-json '{"harness":"plain","maxParallel":1}' --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20 --cwd "$repo2")"
    if [[ "$(ad count-running --profile mp | cut -d' ' -f1)" =~ ^[01]$ && "$st" == completed ]]; then
        pass "9 once the running job is cancelled the profile has a free slot again"
    else
        fail "9 once the running job is cancelled the profile has a free slot again"
    fi
    # Two tasks of a maxParallel=1 profile at the same moment, each seeing the other's fresh record: one runs, one is
    # refused (never both refused).
    local pa
    for pa in a b; do
        (
            prc=0
            AGENT_STUB_MODE=hang ad task --background --cwd "$([[ $pa == a ]] && echo "$repo" || echo "$repo2")" --profile duo \
                --profile-json '{"harness":"plain","maxParallel":1}' --prompt-file "$prompt" >"$TEST_ROOT/duo-$pa.out" 2>&1 || prc=$?
            echo "$prc" >"$TEST_ROOT/duo-$pa.rc"
        ) &
    done
    wait
    out="$(cat "$TEST_ROOT/duo-a.rc" "$TEST_ROOT/duo-b.rc" | sort | tr '\n' ' ')"
    local duo_id
    duo_id="$(grep -ho 'as pt-[0-9]*' "$TEST_ROOT/duo-a.out" "$TEST_ROOT/duo-b.out" | awk '{print $2}')"
    if [[ "$out" == "0 2 " ]] && grep -q "profile duo is at maxParallel=1 (running: $duo_id)" "$TEST_ROOT/duo-a.out" "$TEST_ROOT/duo-b.out"; then
        pass "9 two simultaneous tasks on a maxParallel=1 profile: exactly one runs, the other is refused naming it"
    else
        fail "9 two simultaneous tasks on a maxParallel=1 profile: exactly one runs, the other is refused naming it"
        echo "    exit codes: $out"; cat "$TEST_ROOT"/duo-*.out
    fi
    for pa in a b; do
        if grep -q "as $duo_id" "$TEST_ROOT/duo-$pa.out" 2>/dev/null; then
            ad cancel "$duo_id" --cwd "$([[ $pa == a ]] && echo "$repo" || echo "$repo2")" >/dev/null
        fi
    done
    out="$(core_js '
const fs = await import("node:fs");
const [a, b] = [`${process.argv[1]}/a/jobs`, `${process.argv[1]}/b/jobs`];
for (const d of [a, b]) fs.mkdirSync(d, { recursive: true });
const t0 = Date.now();
const [sa, sb] = [new Date(t0).toISOString(), new Date(t0 + 5).toISOString()];
const rec = (dir, id, startedAt) => fs.writeFileSync(`${dir}/${id}.json`, JSON.stringify({ id, status: "running", profile: "tie", startedAt, runnerPid: null, bootId: core.bootId() }));
rec(a, "pt-0001", sa);
rec(b, "pt-0001", sb);
const env = { ...process.env, AGENT_DISPATCH_STATE_DIR: process.argv[2] };
const count = (self) => core.runningJobsOfProfile("tie", { env, self }).length;
console.log(count({ jobsDir: a, id: "pt-0001", startedAt: sa }), count({ jobsDir: b, id: "pt-0001", startedAt: sb }), count(null));' \
        "$TEST_ROOT/tie-state/state" "$TEST_ROOT/tie-state")"
    if [[ "$out" == "0 1 2" ]]; then
        pass "9 runningJobsOfProfile: a pending job (no runner yet) counts against the caller only if allocated first; without self every running job counts"
    else
        fail "9 runningJobsOfProfile: a pending job (no runner yet) counts against the caller only if allocated first; without self every running job counts"
        echo "    got: $out"
    fi

    # --- 10. cancel kills the whole tree, including descendants in process groups of their own ---
    pids="$TEST_ROOT/pids.txt"
    rm -f "$pids"
    id="$(AGENT_STUB_MODE=detached-child AGENT_STUB_PIDS="$pids" start_task --profile p1 --prompt-file "$prompt")"
    child="$(wait_child "$id")"
    if wait_lines "$pids" 2; then :; fi
    local d1 d2 g1 g2
    d1="$(sed -n 1p "$pids")"
    d2="$(sed -n 2p "$pids")"
    g1="$(ps -o pgid= -p "$d1" | tr -d ' ')"
    g2="$(ps -o pgid= -p "$d2" | tr -d ' ')"
    t0="$(now_ms)"
    out="$(ad cancel "$id")"
    t1="$(now_ms)"
    if [[ -n "$child" && -n "$d1" && -n "$d2" && "$g1" != "$child" && "$g2" != "$child" && "$g1" != "$g2" ]] && gone "$child" "$d1" "$d2" \
        && [[ "$out" == "cancelled $id" && "$(ad status "$id" --json | jfield job.status)" == cancelled ]]; then
        pass "10 cancel: SIGTERM ladder over the snapshot kills the harness and a child and grandchild that each setsid'd into their own group"
    else
        fail "10 cancel: SIGTERM ladder over the snapshot kills the harness and a child and grandchild that each setsid'd into their own group"
        echo "    harness=$child d1=$d1/$g1 d2=$d2/$g2 out=$out"
        ps -o pid,ppid,pgid,command -p "$child,$d1,$d2" 2>/dev/null || true
    fi
    if (((t1 - t0) >= 1400)) && grep -q "cancel: SIGKILL" "$JOBS/$id.log" && ! grep -q "cancel stops the tree itself" "$JOBS/$id.log"; then
        pass "10 the runner runs the ladder: descendants that ignore SIGTERM get SIGKILL after the step's wait; cancel returns after it ($((t1 - t0)) ms)"
    else
        fail "10 the runner runs the ladder: descendants that ignore SIGTERM get SIGKILL after the step's wait; cancel returns after it ($((t1 - t0)) ms)"
        grep "cancel" "$JOBS/$id.log" || true
    fi
    rc=0
    err="$(ad result "$id" 2>&1)" || rc=$?
    out="$(ad cancel "$id")"
    if [[ "$rc" -eq 1 && "$(head -1 <<<"$err")" == "job $id is cancelled errorClass=null" && "$out" == "$id is cancelled" ]]; then
        pass "10 result of a cancelled job exits 1 ('job <id> is cancelled errorClass=null'); a second cancel prints '<id> is cancelled'"
    else
        fail "10 result of a cancelled job exits 1 ('job <id> is cancelled errorClass=null'); a second cancel prints '<id> is cancelled'"
        echo "    exit=$rc err=$(head -1 <<<"$err") cancel=$out"
    fi

    # --- 11. the per-adapter ladder: SIGINT first (dsh's shape) vs SIGTERM first ---
    # The stub writes AGENT_STUB_RECORD once its signal dispositions are in place: the handshake before each cancel.
    local sigs="$TEST_ROOT/sigint.txt"
    rm -f "$sigs"
    rec="$TEST_ROOT/ready-11a.json"
    id="$(AGENT_STUB_MODE=trap-signals AGENT_STUB_SIGNALS="$sigs" AGENT_STUB_RECORD="$rec" start_task --profile si --profile-json '{"harness":"plain-sigint"}' --prompt-file "$prompt")"
    child="$(wait_child "$id")"
    wait_file "$rec" || true
    t0="$(now_ms)"
    ad cancel "$id" >/dev/null
    t1="$(now_ms)"
    if [[ -n "$child" && "$(head -1 "$sigs" 2>/dev/null)" == SIGINT ]] && ! grep -q SIGTERM "$sigs" && gone "$child" && (((t1 - t0) >= 1400)); then
        pass "11 a SIGINT-first ladder sends SIGINT (never SIGTERM), waits its step, then SIGKILL ($((t1 - t0)) ms)"
    else
        fail "11 a SIGINT-first ladder sends SIGINT (never SIGTERM), waits its step, then SIGKILL ($((t1 - t0)) ms)"
        echo "    signals: $(tr '\n' ' ' <"$sigs" 2>/dev/null) child=$child"
    fi
    sigs="$TEST_ROOT/sigterm.txt"
    rm -f "$sigs"
    rec="$TEST_ROOT/ready-11b.json"
    id="$(AGENT_STUB_MODE=trap-signals AGENT_STUB_SIGNALS="$sigs" AGENT_STUB_RECORD="$rec" start_task --profile p1 --prompt-file "$prompt")"
    child="$(wait_child "$id")"
    wait_file "$rec" || true
    ad cancel "$id" >/dev/null
    if [[ "$(head -1 "$sigs" 2>/dev/null)" == SIGTERM ]] && ! grep -q SIGINT "$sigs" && gone "$child"; then
        pass "11 the default-shaped ladder sends SIGTERM and never SIGINT"
    else
        fail "11 the default-shaped ladder sends SIGTERM and never SIGINT"
        echo "    signals: $(tr '\n' ' ' <"$sigs" 2>/dev/null)"
    fi

    # --- 12. cancelled by the dispatcher's record, whatever the harness exits with ---
    rec="$TEST_ROOT/ready-12.json"
    id="$(AGENT_STUB_MODE=sigterm-exit0 AGENT_STUB_RECORD="$rec" start_task --profile p1 --prompt-file "$prompt")"
    child="$(wait_child "$id")"
    wait_file "$rec" || true
    runner="$(ad status "$id" --json | jfield job.runnerPid)"
    ad cancel "$id" >/dev/null
    local finished=no
    if [[ -n "$runner" ]] && ! kill -0 "$runner" 2>/dev/null && grep -Fq "finish $id: cancelled" "$JOBS/$id.log"; then finished=yes; fi
    sj="$(ad status "$id" --json)"
    if [[ "$finished" == yes && "$(jfield job.status <<<"$sj")" == cancelled && -z "$(jfield job.response <<<"$sj")" ]] && grep -Fq "terminated politely" "$JOBS/$id.log"; then
        pass "12 a harness that answers SIGTERM with a valid answer and exit 0 still ends cancelled (its output stays in the log; the runner has finished when cancel returns)"
    else
        fail "12 a harness that answers SIGTERM with a valid answer and exit 0 still ends cancelled (its output stays in the log; the runner has finished when cancel returns)"
        echo "    status=$(jfield job.status <<<"$sj") response=$(jfield job.response <<<"$sj")"
    fi

    # --- 13. the whole-job timeout runs the ladder over the tree ---
    pids="$TEST_ROOT/pids-timeout.txt"
    rm -f "$pids"
    id="$(AGENT_STUB_MODE=detached-child AGENT_STUB_PIDS="$pids" start_task --profile to --profile-json '{"harness":"plain","timeoutMin":0.04}' --prompt-file "$prompt")"
    child="$(wait_child "$id")"
    wait_lines "$pids" 2 || true
    d1="$(sed -n 1p "$pids" 2>/dev/null)"
    d2="$(sed -n 2p "$pids" 2>/dev/null)"
    st="$(wait_status "$id" 'completed|failed|cancelled' 25)"
    if [[ -n "$child" && -n "$d1" && -n "$d2" && "$st" == failed && "$(ad status "$id" --json | jfield job.errorClass)" == timeout ]] \
        && grep -q "timeout after 2400 ms" "$JOBS/$id.log" && gone "$child" "$d1" "$d2"; then
        pass "13 timeoutMin elapsed: failed/timeout, and the harness and both its detached descendants (recorded before the timeout) are gone"
    else
        fail "13 timeoutMin elapsed: failed/timeout, and the harness and both its detached descendants (recorded before the timeout) are gone"
        echo "    status=$st harness=$child d1=$d1 d2=$d2"; grep timeout "$JOBS/$id.log" || true
    fi

    # --- 14. a dead runner is reaped; its stale reservation needs release-stale ---
    local dead
    dead="$(AGENT_STUB_MODE=hang start_task --write --profile p1 --prompt-file "$prompt")"
    child="$(wait_child "$dead")"
    runner="$(ad status "$dead" --json | jfield job.runnerPid)"
    kill -9 "$runner"
    gone "$runner" || true
    # release-stale reaps nothing: while the dead runner's harness still lives, the reservation is not stale.
    rc=0
    err="$(ad release-stale 2>&1)" || rc=$?
    if [[ -n "$child" && "$rc" -eq 2 && "$err" == *"still has live harness process group $child"* ]] && kill -0 "$child" 2>/dev/null; then
        pass "14 runner dead but its harness alive: release-stale is refused (exit 2) naming the live harness group"
    else
        fail "14 runner dead but its harness alive: release-stale is refused (exit 2) naming the live harness group"
        echo "    exit=$rc err=$err harness=$child"
    fi
    sj="$(ad status "$dead" --json)"
    if [[ "$(jfield job.status <<<"$sj")" == failed && "$(jfield job.errorClass <<<"$sj")" == crash && "$(jfield job.note <<<"$sj")" == "runner died" ]] \
        && gone "$child" && grep -q "runner died; liveness check marked the job failed/crash; SIGKILL to process groups" "$JOBS/$dead.log"; then
        pass "14 runner killed: status reaps the job (failed/crash, 'runner died') and SIGKILLs the harness tree"
    else
        fail "14 runner killed: status reaps the job (failed/crash, 'runner died') and SIGKILLs the harness tree"
        echo "    $(jfield job.status <<<"$sj")/$(jfield job.errorClass <<<"$sj") note=$(jfield job.note <<<"$sj") child=$child"
    fi
    rc=0
    err="$(AGENT_STUB_MODE=ok ad task --background --write --profile p1 --prompt-file "$prompt" 2>&1)" || rc=$?
    if [[ "$rc" -eq 2 && "$err" == *"is stale (runner pid $runner is not alive); run agent-dispatch release-stale --cwd \"$repo\""* ]]; then
        pass "14 the dead runner's reservation refuses the next write task (exit 2) with the release-stale hint"
    else
        fail "14 the dead runner's reservation refuses the next write task (exit 2) with the release-stale hint"
        echo "    exit=$rc err=$err"
    fi
    rc=0
    out="$(ad release-stale)" || rc=$?
    local rc2=0 err2
    err2="$(ad release-stale 2>&1)" || rc2=$?
    id="$(AGENT_STUB_MODE=ok start_task --write --profile p1 --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    if [[ "$rc" -eq 0 && "$out" =~ ^released\ $repo\ generation\ [0-9]+$ && "$rc2" -eq 2 && "$err2" == *"is already released"* && "$st" == completed ]]; then
        pass "14 release-stale prints 'released <root> generation <n>'; a second one is refused; the next write task runs"
    else
        fail "14 release-stale prints 'released <root> generation <n>'; a second one is refused; the next write task runs"
        echo "    rs=$rc:$out rs2=$rc2:$err2 next=$st"
    fi
    rc=0
    err="$(ad release-stale --cwd "$repo4" 2>&1)" || rc=$?
    if [[ "$rc" -eq 2 && "$err" == *"no workspace reservation to release"* ]]; then
        pass "14 release-stale without a reservation: exit 2 'no workspace reservation to release'"
    else
        fail "14 release-stale without a reservation: exit 2 'no workspace reservation to release'"
        echo "    exit=$rc err=$err"
    fi

    # --- 15. boot ids: state from an earlier boot is dead without a pid check and never signalled ---
    local JOBS3 sleeper
    JOBS3="$(jobs_dir_of "$repo3")"
    mkdir -p "$JOBS3"
    sleeper="$(spawn_sleeper)"
    SLEEPERS="$SLEEPERS $sleeper"
    printf '{"id":"pt-0001","status":"running","errorClass":null,"profile":"p1","harness":"plain","write":true,"sessionId":null,"workspaceRoot":"%s","startedAt":"%s","bootId":"boot-old","finishedAt":null,"runnerPid":%s,"childPid":%s,"note":null}\n' \
        "$repo3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sleeper" "$sleeper" >"$JOBS3/pt-0001.json"
    printf '{"holderPid":%s,"jobId":"pt-0001","token":"tok-0","generation":0,"createdAt":"x","bootId":"boot-new"}\n' "$sleeper" >"$(dirname "$JOBS3")/active.lock.0"
    rc=0
    err="$(AGENT_TEST_BOOT_ID=boot-new ad release-stale --cwd "$repo3" 2>&1)" || rc=$?
    local rc_task=0 err_task
    err_task="$(AGENT_TEST_BOOT_ID=boot-new AGENT_STUB_MODE=ok ad task --background --write --cwd "$repo3" --profile p1 --prompt-file "$prompt" 2>&1)" || rc_task=$?
    if [[ "$rc" -eq 2 && "$err" == *"is held by live runner pid $sleeper"* && "$rc_task" -eq 2 && "$err_task" == *"job pt-0001 is still running in this workspace"* ]]; then
        pass "15 a reservation of the current boot with a live holder: release-stale and write tasks are refused"
    else
        fail "15 a reservation of the current boot with a live holder: release-stale and write tasks are refused"
        echo "    rs=$rc:$err task=$rc_task:$err_task"
    fi
    sj="$(AGENT_TEST_BOOT_ID=boot-new ad status pt-0001 --cwd "$repo3" --json)"
    if [[ "$(jfield job.status <<<"$sj")" == failed && "$(jfield job.errorClass <<<"$sj")" == crash && "$(jfield job.note <<<"$sj")" == "system rebooted since the job started" ]] \
        && kill -0 "$sleeper" 2>/dev/null; then
        pass "15 a running record from an earlier boot: failed/crash 'system rebooted since the job started', its (reused) pids are not signalled"
    else
        fail "15 a running record from an earlier boot: failed/crash 'system rebooted since the job started', its (reused) pids are not signalled"
        echo "    $(jfield job.status <<<"$sj")/$(jfield job.errorClass <<<"$sj") note=$(jfield job.note <<<"$sj")"
    fi
    printf '{"holderPid":%s,"jobId":"pt-0001","token":"tok-0","generation":0,"createdAt":"x","bootId":"boot-old"}\n' "$sleeper" >"$(dirname "$JOBS3")/active.lock.0"
    rc=0
    err="$(AGENT_TEST_BOOT_ID=boot-new AGENT_STUB_MODE=ok ad task --background --write --cwd "$repo3" --profile p1 --prompt-file "$prompt" 2>&1)" || rc=$?
    rc2=0
    out="$(AGENT_TEST_BOOT_ID=boot-new ad release-stale --cwd "$repo3" 2>&1)" || rc2=$?
    id="$(AGENT_TEST_BOOT_ID=boot-new AGENT_STUB_MODE=ok start_task --write --cwd "$repo3" --profile p1 --prompt-file "$prompt")"
    st="$(AGENT_TEST_BOOT_ID=boot-new wait_status "$id" 'completed|failed|cancelled' 20 --cwd "$repo3")"
    if [[ "$rc" -eq 2 && "$err" == *"is stale (the system rebooted since it was taken)"* && "$rc2" -eq 0 && "$out" == "released $repo3 generation 0" \
        && "$st" == completed ]] && kill -0 "$sleeper" 2>/dev/null; then
        pass "15 a reservation from an earlier boot: write task refused as stale (rebooted), release-stale releases it although the old pid lives, then a write task runs"
    else
        fail "15 a reservation from an earlier boot: write task refused as stale (rebooted), release-stale releases it although the old pid lives, then a write task runs"
        echo "    task=$rc:$err rs=$rc2:$out next=$st"
    fi
    # The current boot, a dead runner, and a harness pid that now leads an unrelated group (another start time): the
    # reaper finalizes the job but never signals that group.
    local deadpid boot_now
    deadpid="$(sh -c 'echo $$')"
    boot_now="$(core_js 'console.log(core.bootId() ?? "")')"
    printf '{"id":"pt-0100","status":"running","errorClass":null,"profile":"p1","harness":"plain","write":false,"sessionId":null,"workspaceRoot":"%s","startedAt":"%s","bootId":"%s","finishedAt":null,"runnerPid":%s,"childPid":%s,"childStartedAt":"Thu Jan 1 00:00:00 1970","note":null}\n' \
        "$repo3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$boot_now" "$deadpid" "$sleeper" >"$JOBS3/pt-0100.json"
    sj="$(ad status pt-0100 --cwd "$repo3" --json)"
    if [[ -n "$boot_now" && "$(jfield job.status <<<"$sj")" == failed && "$(jfield job.errorClass <<<"$sj")" == crash && "$(jfield job.note <<<"$sj")" == "runner died" ]] \
        && kill -0 "$sleeper" 2>/dev/null && grep -q "harness process group $sleeper not signalled: its leader pid now belongs to another process" "$JOBS3/pt-0100.log"; then
        pass "15 a dead runner whose harness pid now belongs to another process (start time differs): failed/crash, that process is not signalled"
    else
        fail "15 a dead runner whose harness pid now belongs to another process (start time differs): failed/crash, that process is not signalled"
        echo "    $(jfield job.status <<<"$sj")/$(jfield job.errorClass <<<"$sj") note=$(jfield job.note <<<"$sj") boot=$boot_now"
        cat "$JOBS3/pt-0100.log" 2>/dev/null || true
    fi

    # --- 16. resume: completed + session + same profile + bound fields + adapter's resumeCheck ---
    local r1 sess
    r1="$(AGENT_STUB_MODE=ok start_task --profile rp --profile-json '{"harness":"plain","model":"m1"}' --prompt-file "$prompt")"
    wait_status "$r1" 'completed|failed|cancelled' 20 >/dev/null
    sess="$(ad status "$r1" --json | jfield job.sessionId)"
    rec="$TEST_ROOT/resume.json"
    id="$(AGENT_STUB_MODE=resume AGENT_STUB_RECORD="$rec" start_task --profile rp --profile-json '{"harness":"plain","model":"m1"}' --resume-task "$r1" --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    sj="$(ad status "$id" --json)"
    if [[ -n "$sess" && "$st" == completed && "$(jfield job.resumeOf <<<"$sj")" == "$r1" && "$(jfield job.sessionId <<<"$sj")" == "$sess" \
        && "$(ad result "$id")" == "DONE"$'\n'"resumed $sess" ]] && REC="$rec" S="$sess" node -e '
const a = JSON.parse(require("node:fs").readFileSync(process.env.REC, "utf8")).argv;
process.exit(a.some((x, i) => x === "--resume" && a[i + 1] === process.env.S) ? 0 : 1);'; then
        pass "16 --resume-task of a completed job: req.resume carries its session (--resume <uuid>), the record keeps resumeOf and the session"
    else
        fail "16 --resume-task of a completed job: req.resume carries its session (--resume <uuid>), the record keeps resumeOf and the session"
        echo "    status=$st session=$sess"
    fi
    # expect_refusal <label> <needle> <task args...>
    expect_refusal() {
        local label="$1" needle="$2"
        shift 2
        local erc=0 eerr
        eerr="$(ad task --background --prompt-file "$prompt" "$@" 2>&1)" || erc=$?
        if [[ "$erc" -eq 2 && "$eerr" == *"$needle"* ]]; then pass "$label"; else
            fail "$label"
            echo "    exit=$erc err=$eerr"
        fi
    }
    expect_refusal "16 resume on another profile: exit 2" "ran on profile rp, not p1" --profile p1 --resume-task "$r1"
    expect_refusal "16 resume after the profile's model changed: exit 2" "ran with another model of profile rp" \
        --profile rp --profile-json '{"harness":"plain","model":"m2"}' --resume-task "$r1"
    expect_refusal "16 resume of a failed job: exit 2" "is failed / has no session; dispatch --fresh" --profile p1 --resume-task "$quota_id"
    expect_refusal "16 resume of a zt- id: exit 2" "zt- and task- ids resume through their own wrappers" --profile p1 --resume-task zt-0001
    # The adapter's meta (its config dir, recorded at the start) reaches resumeCheck: another CLAUDE_CONFIG_DIR is refused.
    if [[ "$(ad status "$r1" --json | jfield job.meta)" == '{"homeDir":null}' ]]; then
        pass "16 the adapter's meta from invocation() is kept in the record"
    else
        fail "16 the adapter's meta from invocation() is kept in the record"
        echo "    meta=$(ad status "$r1" --json | jfield job.meta)"
    fi
    CLAUDE_CONFIG_DIR="$TEST_ROOT/other-config" expect_refusal "16 resume under another CLAUDE_CONFIG_DIR: the adapter's resumeCheck reads the recorded meta (exit 2)" \
        "session lives in config dir (default), not $TEST_ROOT/other-config" --profile rp --profile-json '{"harness":"plain","model":"m1"}' --resume-task "$r1"
    REC_FILE="$JOBS/$r1.json" node -e '
const fs = require("node:fs");
for (const f of [process.env.REC_FILE, `${process.env.REC_FILE}.terminal`]) {
  const r = JSON.parse(fs.readFileSync(f, "utf8")); r.cwd = "/elsewhere"; fs.writeFileSync(f, JSON.stringify(r));
}'
    expect_refusal "16 the adapter's resumeCheck refuses (exit 2, 'dispatch --fresh')" "cannot resume $r1 on rp: session was started in /elsewhere" \
        --profile rp --profile-json '{"harness":"plain","model":"m1"}' --resume-task "$r1"

    # --- 17. discover and the required-flag check (cached per bin and version) ---
    rec="$TEST_ROOT/noflag.json"
    rm -f "$rec"
    id="$(AGENT_STUB_VERSION=9.9.9 AGENT_STUB_HELP_DROP=--plain-json AGENT_STUB_RECORD="$rec" start_task --profile p1 --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    sj="$(ad status "$id" --json)"
    if [[ "$st" == failed && "$(jfield job.errorClass <<<"$sj")" == launch && "$(jfield job.note <<<"$sj")" == *"9.9.9"*"--plain-json"* && ! -e "$rec" ]] \
        && compgen -G "$STATE/cache/help-*.txt" >/dev/null; then
        pass "17 a required flag missing from --help: failed/launch naming the version and the flag, harness not run; help is cached under cache/"
    else
        fail "17 a required flag missing from --help: failed/launch naming the version and the flag, harness not run; help is cached under cache/"
        echo "    $st/$(jfield job.errorClass <<<"$sj") note=$(jfield job.note <<<"$sj")"
    fi
    # The same version again, now listing the flag: the cached text lacks it, so --help is read once more (fresh) and
    # the job runs; a third job reads the refreshed cache and does not call --help at all.
    local calls="$TEST_ROOT/calls-17.txt"
    rm -f "$calls"
    id="$(AGENT_STUB_VERSION=9.9.9 AGENT_STUB_CALL_LOG="$calls" start_task --profile p1 --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    local help1 help2
    help1="$(grep -c '^help' "$calls" 2>/dev/null)"
    id2="$(AGENT_STUB_VERSION=9.9.9 AGENT_STUB_CALL_LOG="$calls" start_task --profile p1 --prompt-file "$prompt")"
    out="$(wait_status "$id2" 'completed|failed|cancelled' 20)"
    help2="$(grep -c '^help' "$calls" 2>/dev/null)"
    if [[ "$st" == completed && "$out" == completed && "$help1" == 1 && "$help2" == 1 && "$(grep -c '^version' "$calls")" == 2 ]]; then
        pass "17 a cached help text that lacks a required flag is re-read once before the verdict; the refreshed cache is then read without calling --help"
    else
        fail "17 a cached help text that lacks a required flag is re-read once before the verdict; the refreshed cache is then read without calling --help"
        echo "    jobs=$st/$out help calls after the 1st: $help1, after the 2nd: $help2"; cat "$calls" 2>/dev/null
    fi
    # A --help that exits non-zero but lists the flags serves this check only and is never cached.
    rm -f "$calls"
    id="$(AGENT_STUB_VERSION=9.9.8 AGENT_STUB_HELP_EXIT=3 AGENT_STUB_CALL_LOG="$calls" start_task --profile p1 --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    id2="$(AGENT_STUB_VERSION=9.9.8 AGENT_STUB_HELP_EXIT=3 AGENT_STUB_CALL_LOG="$calls" start_task --profile p1 --prompt-file "$prompt")"
    out="$(wait_status "$id2" 'completed|failed|cancelled' 20)"
    if [[ "$st" == completed && "$out" == completed && "$(grep -c '^help' "$calls" 2>/dev/null)" == 2 ]]; then
        pass "17 a --help with a non-zero exit is used for the check but not cached: the next job calls --help again"
    else
        fail "17 a --help with a non-zero exit is used for the check but not cached: the next job calls --help again"
        echo "    jobs=$st/$out"; cat "$calls" 2>/dev/null
    fi

    # --- 18. wrap, adapter files, the prompt on stdin ---
    rec="$TEST_ROOT/wrap.json"
    calls="$TEST_ROOT/calls-18.txt"
    rm -f "$calls"
    id="$(AGENT_STUB_VERSION=7.7.7 AGENT_STUB_CALL_LOG="$calls" AGENT_STUB_RECORD="$rec" start_task --profile wr --profile-json '{"harness":"plain","wrap":["env","WRAPPED=yes"]}' --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    if [[ "$st" == completed && "$(sort "$calls" 2>/dev/null | tr '\n' ' ')" == "help yes version yes " ]]; then
        pass "18 discover's --version and the --help check run behind profile.wrap, as the harness does"
    else
        fail "18 discover's --version and the --help check run behind profile.wrap, as the harness does"
        echo "    status=$st calls: $(tr '\n' ' ' <"$calls" 2>/dev/null)"
    fi
    if [[ "$st" == completed ]] && REC="$rec" PROMPT="$prompt" node -e '
const fs = require("node:fs");
const r = JSON.parse(fs.readFileSync(process.env.REC, "utf8"));
process.exit(r.env.WRAPPED === "yes" && r.stdin === fs.readFileSync(process.env.PROMPT, "utf8") ? 0 : 1);' \
        && grep -q "start $id: \"env\" \"WRAPPED=yes\"" "$JOBS/$id.log" \
        && [[ "$(mode_of "$JOBS/$id")" == 700 && "$(mode_of "$JOBS/$id/plain.cfg")" == 600 && "$(mode_of "$JOBS/$id/prompt.md")" == 600 && "$(mode_of "$STATE")" == 700 ]]; then
        pass "18 profile.wrap prefixes the argv; the prompt arrives on stdin (copied 0600 into the 0700 job dir); adapter files are written 0600; the data root is 0700"
    else
        fail "18 profile.wrap prefixes the argv; the prompt arrives on stdin (copied 0600 into the 0700 job dir); adapter files are written 0600; the data root is 0700"
        echo "    status=$st"
    fi
    # finalize() runs a second harness process (as opencode export would) through ctx.execHarness: behind the wrap,
    # with the harness environment minus the key; what it returns as meta lands in the record.
    id="$(TEST_SECRET="$SECRET" start_task --profile fin --profile-json '{"harness":"plain","checkFinalize":true,"wrap":["env","WRAPPED=yes"],"auth":{"keyEnv":"TEST_SECRET"}}' --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    out="$(ad status "$id" --json | jfield job.meta)"
    if [[ "$st" == completed && "$out" == '{"homeDir":null,"finalize":{"wrapped":"yes","safe":"1","key":"","envHasKey":false,"wrap":["env","WRAPPED=yes"]}}' ]]; then
        pass "18 finalize() gets the harness env without the key and the wrap (job.env, job.wrap, ctx.execHarness); its meta joins invocation()'s in the record"
    else
        fail "18 finalize() gets the harness env without the key and the wrap (job.env, job.wrap, ctx.execHarness); its meta joins invocation()'s in the record"
        echo "    status=$st meta=$out"
    fi

    # --- 19. exit codes: 2 for refusals without launch ---
    expect_exit() {
        local want="$1" label="$2" needle="$3"
        shift 3
        local erc=0 eerr
        eerr="$("$@" 2>&1 >/dev/null)" || erc=$?
        if [[ "$erc" -eq "$want" && "$eerr" == *"$needle"* ]]; then pass "$label"; else
            fail "$label"
            echo "    exit: $erc (want $want) err: $eerr"
        fi
    }
    printf '  \n' >"$TEST_ROOT/empty.md"
    expect_exit 2 "19 task without --prompt-file: exit 2" "task requires --prompt-file" ad task --background --profile p1
    expect_exit 2 "19 task with an empty prompt file: exit 2" "prompt file is empty" ad task --background --profile p1 --prompt-file "$TEST_ROOT/empty.md"
    expect_exit 2 "19 task outside a git work tree: exit 2" "not inside a git work tree" ad task --background --profile p1 --cwd "$TEST_ROOT/notgit" --prompt-file "$prompt"
    expect_exit 2 "19 an invalid profile timeoutMin: exit 2" "timeoutMin must be a positive number" ad task --background --profile p1 --profile-json '{"harness":"plain","timeoutMin":-1}' --prompt-file "$prompt"
    expect_exit 2 "19 an invalid profile name: exit 2" "invalid profile name" ad task --background --profile Bad_Name --prompt-file "$prompt"
    expect_exit 2 "19 status of an unknown job: exit 2" "unknown job pt-0999 in this workspace" ad status pt-0999
    expect_exit 2 "19 result of a zt- id: exit 2 naming zcode-dispatch" "zt- ids belong to zcode-dispatch" ad result zt-0001
    expect_exit 2 "19 cancel of a task- id: exit 2" "task- ids to codex-dispatch" ad cancel task-mvgk3up4-yo2np5

    # --- 20. process-tree snapshot (unit) ---
    out="$(core_js '
const table = [
  { pid: 1, ppid: 0, pgid: 1 }, { pid: 100, ppid: 1, pgid: 100 }, { pid: 101, ppid: 100, pgid: 100 },
  { pid: 102, ppid: 101, pgid: 102 }, { pid: 103, ppid: 102, pgid: 103 }, { pid: 104, ppid: 1, pgid: 102 },
  { pid: 105, ppid: 104, pgid: 105 }, { pid: 200, ppid: 1, pgid: 200 }, { pid: 201, ppid: 200, pgid: 200 },
];
console.log([...core.treeGroups([100], table)].sort((a, b) => a - b).join(","), [...core.treeGroups([1], table)].join(","));')"
    if [[ "$out" == "100,102,103,105 " ]]; then
        pass "20 treeGroups: the root group, descendants' groups via ppid, and orphaned members of a known group with their descendants; never pid 1"
    else
        fail "20 treeGroups: the root group, descendants' groups via ppid, and orphaned members of a known group with their descendants; never pid 1"
        echo "    got: '$out'"
    fi
    # A step that does not end the tree is followed by SIGKILL to the survivors (the re-sweep), even without a SIGKILL
    # step in the ladder.
    out="$(core_js '
const fs = await import("node:fs");
const { spawn } = await import("node:child_process");
const ready = `${process.argv[1]}/resweep.ready`;
const c = spawn(process.execPath, ["-e", "process.on(\"SIGTERM\", () => {}); require(\"node:fs\").writeFileSync(process.argv[1], \"1\"); setInterval(() => {}, 1 << 30);", ready], { detached: true, stdio: "ignore" });
const exited = new Promise((resolve) => c.on("exit", (code, signal) => resolve(signal)));
for (let i = 0; i < 200 && !fs.existsSync(ready); i += 1) await new Promise((r) => setTimeout(r, 50));
const lines = [];
const r = await core.terminateTree(c.pid, [["SIGTERM", 200]], { log: (line) => lines.push(line) });
const how = await Promise.race([exited, new Promise((resolve) => setTimeout(() => resolve("still running"), 3000))]);
console.log(r.survivors.length, lines.some((line) => line.startsWith("SIGTERM to groups")), lines.some((line) => line.startsWith("SIGKILL (re-sweep) to groups")), how);' "$TEST_ROOT")"
    if [[ "$out" == "0 true true SIGKILL" ]]; then
        pass "20 terminateTree: a process that ignores the ladder's only step (SIGTERM) is killed by the re-sweep's SIGKILL"
    else
        fail "20 terminateTree: a process that ignores the ladder's only step (SIGTERM) is killed by the re-sweep's SIGKILL"
        echo "    got: $out"
    fi

    # --- 21. the runner owns the stop: one runner per job; a bare terminal claim stops the tree; leftovers swept ---
    rec="$TEST_ROOT/ready-21.json"
    id="$(AGENT_STUB_MODE=hang AGENT_STUB_RECORD="$rec" start_task --profile p1 --prompt-file "$prompt")"
    child="$(wait_child "$id")"
    wait_file "$rec" || true
    runner="$(ad status "$id" --json | jfield job.runnerPid)"
    rc=0
    ad __run "$id" "$JOBS" - >/dev/null 2>&1 || rc=$?
    if [[ -n "$child" && "$rc" -eq 1 && "$(ad status "$id" --json | jfield job.runnerPid)" == "$runner" ]] && kill -0 "$child" 2>/dev/null \
        && grep -q "__run refused for $id in pid [0-9]*: runner pid $runner owns the job" "$JOBS/$id.log"; then
        pass "21 a second __run for a job that has a runner exits 1 and touches nothing (runnerPid unchanged, harness running)"
    else
        fail "21 a second __run for a job that has a runner exits 1 and touches nothing (runnerPid unchanged, harness running)"
        echo "    exit=$rc runner=$runner now=$(ad status "$id" --json | jfield job.runnerPid)"
    fi
    # A terminal claim and nothing else, as a cancel that died right after claiming, or that claimed before the
    # runner recorded childPid: the runner sees it and stops its harness itself.
    core_js 'core.finalizeRecord(process.argv[1], { status: "cancelled", errorClass: null, note: "claimed by the test" });' "$JOBS/$id.json"
    if gone "$child" "$runner" && [[ "$(ad status "$id" --json | jfield job.status)" == cancelled ]] && grep -q "cancel: SIGTERM to groups" "$JOBS/$id.log" \
        && grep -Fq "finish $id: cancelled" "$JOBS/$id.log"; then
        pass "21 a terminal claim alone (nobody signals): the runner runs the ladder over its harness tree and exits; the job stays cancelled"
    else
        fail "21 a terminal claim alone (nobody signals): the runner runs the ladder over its harness tree and exits; the job stays cancelled"
        echo "    harness=$child runner=$runner"; tail -5 "$JOBS/$id.log"
    fi
    pids="$TEST_ROOT/pids-leave.txt"
    rm -f "$pids"
    id="$(AGENT_STUB_MODE=leave-behind AGENT_STUB_PIDS="$pids" start_task --profile p1 --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    d1="$(sed -n 1p "$pids" 2>/dev/null)"
    d2="$(sed -n 2p "$pids" 2>/dev/null)"
    if [[ "$st" == completed && "$(ad result "$id")" == "DONE"$'\n'"left some behind" ]] && gone "$d1" "$d2" \
        && grep -q "cleanup: the harness exited and left processes in its group" "$JOBS/$id.log" && grep -q "cleanup: SIGKILL" "$JOBS/$id.log"; then
        pass "21 a harness that exits leaving a member of its group (and that member's own-group child) behind: completed, both swept by the ladder"
    else
        fail "21 a harness that exits leaving a member of its group (and that member's own-group child) behind: completed, both swept by the ladder"
        echo "    status=$st d1=$d1 d2=$d2"; grep cleanup "$JOBS/$id.log" || true
    fi
    # Unknown boot (the boot id unreadable): cancel claims the record but signals no stored pid; the runner, which
    # knows its own child, still stops it — here only once it runs again.
    rec="$TEST_ROOT/ready-21u.json"
    id="$(AGENT_TEST_BOOT_ID=unknown AGENT_STUB_MODE=hang AGENT_STUB_RECORD="$rec" start_task --profile p1 --prompt-file "$prompt")"
    child="$(wait_child "$id")"
    wait_file "$rec" || true
    runner="$(ad status "$id" --json | jfield job.runnerPid)"
    kill -STOP "$runner" 2>/dev/null
    out="$(AGENT_TEST_BOOT_ID=unknown ad cancel "$id")"
    if [[ -n "$child" && "$out" == "cancelled $id (harness process group $child not signalled: the boot it was started in cannot be confirmed"* ]] \
        && kill -0 "$child" 2>/dev/null; then
        pass "21 cancel under an unknown boot: the record is cancelled, no stored pid is signalled, the note says so"
    else
        fail "21 cancel under an unknown boot: the record is cancelled, no stored pid is signalled, the note says so"
        echo "    out=$out harness=$child"
    fi
    kill -CONT "$runner" 2>/dev/null
    if gone "$child" "$runner" && [[ "$(ad status "$id" --json | jfield job.status)" == cancelled ]]; then
        pass "21 unknown boot: the runner, running again, sees the claim and stops its own harness"
    else
        fail "21 unknown boot: the runner, running again, sees the claim and stops its own harness"
    fi
    rec="$TEST_ROOT/ready-21r.json"
    id="$(AGENT_TEST_BOOT_ID=unknown AGENT_STUB_MODE=hang AGENT_STUB_RECORD="$rec" start_task --profile p1 --prompt-file "$prompt")"
    child="$(wait_child "$id")"
    wait_file "$rec" || true
    runner="$(ad status "$id" --json | jfield job.runnerPid)"
    kill -9 "$runner" 2>/dev/null
    gone "$runner" || true
    sj="$(ad status "$id" --json)"
    if [[ -n "$child" && "$(jfield job.status <<<"$sj")" == failed && "$(jfield job.errorClass <<<"$sj")" == crash && "$(jfield job.note <<<"$sj")" == "runner died" ]] \
        && kill -0 "$child" 2>/dev/null \
        && grep -q "runner died; liveness check marked the job failed/crash; harness process group $child not signalled: the boot it was started in cannot be confirmed" "$JOBS/$id.log"; then
        pass "21 unknown boot, dead runner: the reaper marks failed/crash and leaves the harness group unsignalled, saying so in the log"
    else
        fail "21 unknown boot, dead runner: the reaper marks failed/crash and leaves the harness group unsignalled, saying so in the log"
        echo "    $(jfield job.status <<<"$sj")/$(jfield job.errorClass <<<"$sj") harness=$child"; tail -3 "$JOBS/$id.log"
    fi
    if [[ -n "$child" ]]; then kill -KILL -- "-$child" 2>/dev/null || true; fi

    # --- 22. the probe (doctor --probe): one run, no record, the key resolved and redacted ---
    rc=0
    out="$(AGENT_STUB_MODE=ok AGENT_STUB_RESPONSE=PONG ad probe --profile pr 2>&1)" || rc=$?
    if [[ "$rc" -eq 0 && "$out" == 'probe pr: completed response="PONG"' && -d "$STATE/probe" && -z "$(/bin/ls -A "$STATE/probe")" ]]; then
        pass "22 probe: a completed run prints its response; its scratch dir is removed"
    else
        fail "22 probe: a completed run prints its response; its scratch dir is removed"
        echo "    exit=$rc out=$out left: $(/bin/ls -A "$STATE/probe" 2>/dev/null)"
    fi
    rc=0
    out="$(TEST_SECRET="$SECRET" AGENT_STUB_MODE=leak-secret ad probe --profile pk --profile-json "$keyed" 2>&1)" || rc=$?
    if [[ "$rc" -eq 0 && "$out" == 'probe pk: completed response="DONE\nkey=<redacted>"' ]]; then
        pass "22 probe with a key: the harness gets it, the response that echoes it is redacted"
    else
        fail "22 probe with a key: the harness gets it, the response that echoes it is redacted"
        echo "    exit=$rc out=${out//$SECRET/<SECRET>}"
    fi
    rc=0
    out="$(AGENT_STUB_MODE=exit0-error ad probe --profile pr 2>&1)" || rc=$?
    local rc3=0 out3
    out3="$(TEST_SECRET= ad probe --profile pk --profile-json "$keyed" 2>&1)" || rc3=$?
    if [[ "$rc" -eq 1 && "$out" == "probe pr: failed/quota response=null" && "$rc3" -eq 2 && "$out3" == *"pk: key unavailable (resolved to an empty value) errorClass=auth"* ]]; then
        pass "22 probe: a failed run is classified like a job (failed/quota, exit 1); an empty key is refused (exit 2)"
    else
        fail "22 probe: a failed run is classified like a job (failed/quota, exit 1); an empty key is refused (exit 2)"
        echo "    exit=$rc out=$out / exit=$rc3 out=$out3"
    fi

    # --- 23. bounded stdout (unit) ---
    out="$(core_js '
const run = (head, tail, chunks) => {
  const b = core.boundedText(head, tail);
  for (const chunk of chunks) b.push(chunk);
  return b.result();
};
console.log(JSON.stringify([
  run(10, 12, ["aaa\nbbb\n", "ccc\nddd\neee\n", "fff\nggg\n", "hhh\niii\njjj\n", "kkk\n"]),
  run(4, 6, ["ab\ncd\nef", "gh\nij\n"]),
  run(100, 100, ["short\n", "text"]),
]));')"
    if [[ "$out" == '[{"text":"aaa\nbbb\nhhh\niii\njjj\nkkk\n","dropped":20},{"text":"ab\nij\n","dropped":8},{"text":"short\ntext","dropped":0}]' ]]; then
        pass "23 boundedText keeps a head and a tail of whole lines and counts what it dropped between them"
    else
        fail "23 boundedText keeps a head and a tail of whole lines and counts what it dropped between them"
        echo "    got: $out"
    fi

    # --- 24. a relative AGENT_DISPATCH_STATE_DIR is the caller's, also for the runner in the workspace root ---
    (
        cd "$TEST_ROOT/notgit" || exit 1
        export AGENT_DISPATCH_STATE_DIR=rel-state
        rid="$(AGENT_STUB_MODE=ok start_task --cwd "$repo4" --profile iso --profile-json '{"harness":"plain","home":"isolated"}' --prompt-file "$prompt")"
        echo "$(wait_status "$rid" 'completed|failed|cancelled' 20 --cwd "$repo4")" >"$TEST_ROOT/rel-state.out"
    )
    if [[ "$(cat "$TEST_ROOT/rel-state.out" 2>/dev/null)" == completed && -d "$TEST_ROOT/notgit/rel-state/homes/iso/sessions" && ! -e "$repo4/rel-state" ]]; then
        pass "24 a relative state dir resolves against the caller's cwd: the job completes and the runner writes under the same root"
    else
        fail "24 a relative state dir resolves against the caller's cwd: the job completes and the runner writes under the same root"
        echo "    status=$(cat "$TEST_ROOT/rel-state.out" 2>/dev/null) repo4: $(/bin/ls -A "$repo4")"
    fi

    # --- 25. a runner pid reused within one boot: identity (pid + start time) decides, never the pid alone ---
    # The family stands in for whatever got a dead runner's pid: a group leader with a child in a group of its own,
    # both with default signal dispositions, so any signal that reaches them shows.
    local JOBS5 fam fam_p fam_c bogus="Thu Jan 1 00:00:00 1970"
    JOBS5="$(jobs_dir_of "$repo5")"
    fam="$TEST_ROOT/family.txt"
    spawn_family "$fam"
    fam_p="$(cut -d' ' -f1 "$fam")"
    fam_c="$(cut -d' ' -f2 "$fam")"
    fixture_record "$JOBS5" pt-0001 "{\"workspaceRoot\":\"$repo5\",\"cwd\":\"$repo5\",\"runnerPid\":$fam_p,\"runnerStartedAt\":\"$bogus\"}"
    t0="$(now_ms)"
    out="$(with_deadline 30 ad cancel pt-0001 --cwd "$repo5")"
    t1="$(now_ms)"
    sj="$(ad status pt-0001 --cwd "$repo5" --json)"
    if [[ -n "$fam_p" && -n "$fam_c" && "$out" == "pt-0001 is failed" && "$(jfield job.errorClass <<<"$sj")" == crash && "$(jfield job.note <<<"$sj")" == "runner died" ]] \
        && (((t1 - t0) < 4000)) && kill -0 "$fam_p" 2>/dev/null && kill -0 "$fam_c" 2>/dev/null \
        && grep -q "runner died (pid $fam_p now belongs to another process)" "$JOBS5/pt-0001.log"; then
        pass "25 cancel of a job whose runner pid now belongs to an unrelated process (same boot, another start time): the runner counts as dead (failed/crash), no wait for it, and neither that process nor its child's group is signalled ($((t1 - t0)) ms)"
    else
        fail "25 cancel of a job whose runner pid now belongs to an unrelated process (same boot, another start time): the runner counts as dead (failed/crash), no wait for it, and neither that process nor its child's group is signalled ($((t1 - t0)) ms)"
        echo "    out=$out $(jfield job.status <<<"$sj")/$(jfield job.errorClass <<<"$sj") parent=$fam_p child=$fam_c"
        cat "$JOBS5/pt-0001.log" 2>/dev/null
    fi
    # The reservation holder's identity: a holder pid reused by another process is not the holder.
    fixture_record "$JOBS5" pt-0002 "{\"workspaceRoot\":\"$repo5\",\"cwd\":\"$repo5\",\"write\":true,\"runnerPid\":$fam_p,\"runnerStartedAt\":\"$bogus\"}"
    printf '{"holderPid":%s,"holderStartedAt":"%s","jobId":"pt-0002","token":"tok-25","generation":0,"createdAt":"x","bootId":"%s"}\n' \
        "$fam_p" "$bogus" "$boot_now" >"$(dirname "$JOBS5")/active.lock.0"
    rc=0
    err="$(AGENT_STUB_MODE=ok ad task --background --write --cwd "$repo5" --profile p1 --prompt-file "$prompt" 2>&1)" || rc=$?
    rc2=0
    out2="$(ad release-stale --cwd "$repo5" 2>&1)" || rc2=$?
    id="$(AGENT_STUB_MODE=ok start_task --write --cwd "$repo5" --profile p1 --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20 --cwd "$repo5")"
    if [[ "$rc" -eq 2 && "$err" == *"is stale (runner pid $fam_p is not alive (the pid now belongs to another process))"* && "$rc2" -eq 0 \
        && "$out2" == "released $repo5 generation 0" && "$st" == completed ]] && kill -0 "$fam_p" 2>/dev/null && kill -0 "$fam_c" 2>/dev/null; then
        pass "25 a reservation whose holder pid now belongs to another process: the write task is refused as stale, release-stale releases it, the next write task runs; nothing signalled"
    else
        fail "25 a reservation whose holder pid now belongs to another process: the write task is refused as stale, release-stale releases it, the next write task runs; nothing signalled"
        echo "    task=$rc:$err release-stale=$rc2:$out2 next=$st"
    fi
    # A pending cleanup (terminal record, no marker) whose runner pid was reused: resumed without signalling it.
    fixture_record "$JOBS5" pt-0050 "{\"workspaceRoot\":\"$repo5\",\"cwd\":\"$repo5\",\"runnerPid\":$fam_p,\"runnerStartedAt\":\"$bogus\"}"
    core_js 'core.finalizeRecord(process.argv[1], { status: "cancelled", errorClass: null, note: "claimed by the test" });' "$JOBS5/pt-0050.json"
    local pending_before=no
    if core_js 'process.exit(core.cleanupPending(process.argv[1], core.readRecord(`${process.argv[1]}/pt-0050.json`)) ? 0 : 1);' "$JOBS5"; then pending_before=yes; fi
    out="$(with_deadline 30 ad cancel pt-0050 --cwd "$repo5")"
    if [[ "$pending_before" == yes && "$out" == "pt-0050 is cancelled" && -e "$JOBS5/pt-0050.json.cleaned" ]] && kill -0 "$fam_p" 2>/dev/null && kill -0 "$fam_c" 2>/dev/null \
        && grep -q "cancel: runner pid $fam_p not signalled: the pid now belongs to another process" "$JOBS5/pt-0050.log"; then
        pass "25 cancel resuming a pending cleanup whose runner pid was reused: no descendant of that process is searched or signalled; the cleanup is then done"
    else
        fail "25 cancel resuming a pending cleanup whose runner pid was reused: no descendant of that process is searched or signalled; the cleanup is then done"
        echo "    pending before: $pending_before out=$out"
    fi
    # A start time that was never recorded (an older record; ps failing at the claim) makes a live pid "unknown" too —
    # never signalled, never gone — and the notes say why: not "cannot be read", which would send one hunting for ps.
    fixture_record "$JOBS5" pt-0051 "{\"workspaceRoot\":\"$repo5\",\"cwd\":\"$repo5\",\"runnerPid\":$fam_p}"
    core_js '
const fs = await import("node:fs");
const file = process.argv[1];
const r = JSON.parse(fs.readFileSync(file, "utf8"));
fs.writeFileSync(`${file}.terminal`, JSON.stringify({ ...r, status: "cancelled", note: "claimed long ago",
  finishedAt: new Date(Date.now() - 3600e3).toISOString() }));' "$JOBS5/pt-0051.json"
    out="$(with_deadline 30 ad cancel pt-0051 --cwd "$repo5")"
    local lock_gen
    lock_gen="$(/bin/ls "$(dirname "$JOBS5")" | grep -cE '^active\.lock\.[0-9]+$')"
    printf '{"holderPid":%s,"jobId":"pt-0052","token":"tok-25b","generation":%s,"createdAt":"x","bootId":"%s"}\n' \
        "$fam_p" "$lock_gen" "$boot_now" >"$(dirname "$JOBS5")/active.lock.$lock_gen"
    rc=0
    err="$(ad release-stale --cwd "$repo5" 2>&1)" || rc=$?
    if [[ "$out" == "pt-0051 is cancelled (cleanup resumed: runner pid $fam_p not signalled: it is alive, but no start time was recorded for it to confirm it is the job's)" \
        && ! -e "$JOBS5/pt-0051.json.cleaned" && "$rc" -eq 2 \
        && "$err" == *"generation $lock_gen is held by live runner pid $fam_p (no start time was recorded for it to confirm whether it is still the job's runner)"* ]] \
        && kill -0 "$fam_p" 2>/dev/null && kill -0 "$fam_c" 2>/dev/null; then
        pass "25 a live runner / reservation holder pid without a recorded start time: not signalled, the cleanup stays pending, release-stale refuses — and both say the start time was never recorded"
    else
        fail "25 a live runner / reservation holder pid without a recorded start time: not signalled, the cleanup stays pending, release-stale refuses — and both say the start time was never recorded"
        echo "    cancel=$out release-stale=$rc:$err"
    fi
    kill -KILL "$fam_p" "$fam_c" 2>/dev/null

    # --- 26. a terminal claim whose cleanup was interrupted (the claiming cancel and the runner both gone) ---
    # The runner is stopped, the claim written, the runner killed: the harness lives on under a cancelled record.
    rec="$TEST_ROOT/ready-26a.json"
    id="$(AGENT_STUB_MODE=hang AGENT_STUB_RECORD="$rec" start_task --profile p1 --prompt-file "$prompt")"
    child="$(wait_child "$id")"
    wait_file "$rec" || true
    runner="$(ad status "$id" --json | jfield job.runnerPid)"
    kill -STOP "$runner" 2>/dev/null
    # As a cancel that claimed before the runner recorded its harness leaves it: the claim does not name the harness.
    core_js '
const fs = await import("node:fs");
const file = process.argv[1];
const r = JSON.parse(fs.readFileSync(file, "utf8"));
fs.writeFileSync(`${file}.terminal`, JSON.stringify({ ...r, status: "cancelled", errorClass: null, note: "claimed by an interrupted cancel",
  childPid: null, childStartedAt: null, finishedAt: new Date().toISOString() }));' "$JOBS/$id.json"
    kill -KILL "$runner" 2>/dev/null
    gone "$runner" || true
    local alive_before=no
    if [[ -n "$child" ]] && kill -0 "$child" 2>/dev/null; then alive_before=yes; fi
    out="$(with_deadline 30 ad cancel "$id")"
    out2="$(ad cancel "$id")"
    if [[ "$alive_before" == yes && "$out" == "$id is cancelled (cleanup resumed)" && "$out2" == "$id is cancelled" ]] && gone "$child" \
        && [[ "$(ad status "$id" --json | jfield job.status)" == cancelled ]] && grep -q "cancel: SIGTERM to groups $child" "$JOBS/$id.log"; then
        pass "26 a repeated cancel resumes the cleanup: the runner's claim file names the harness the record does not; the adapter's ladder stops it, the job stays cancelled; a third cancel has nothing left to do"
    else
        fail "26 a repeated cancel resumes the cleanup: the runner's claim file names the harness the record does not; the adapter's ladder stops it, the job stays cancelled; a third cancel has nothing left to do"
        echo "    harness=$child (alive before: $alive_before) out=$out / $out2"; tail -5 "$JOBS/$id.log"
    fi
    rec="$TEST_ROOT/ready-26b.json"
    id="$(AGENT_STUB_MODE=hang AGENT_STUB_RECORD="$rec" start_task --profile p1 --prompt-file "$prompt")"
    child="$(wait_child "$id")"
    wait_file "$rec" || true
    runner="$(ad status "$id" --json | jfield job.runnerPid)"
    kill -STOP "$runner" 2>/dev/null
    core_js 'core.finalizeRecord(process.argv[1], { status: "cancelled", errorClass: null, note: "claimed by an interrupted cancel" });' "$JOBS/$id.json"
    kill -KILL "$runner" 2>/dev/null
    gone "$runner" || true
    alive_before=no
    if [[ -n "$child" ]] && kill -0 "$child" 2>/dev/null; then alive_before=yes; fi
    sj="$(ad status "$id" --json)"
    if [[ "$alive_before" == yes && "$(jfield job.status <<<"$sj")" == cancelled && "$(jfield job.note <<<"$sj")" == "claimed by an interrupted cancel" ]] && gone "$child" \
        && grep -q "cleanup resumed: the job is cancelled but its runner pid $runner is gone and harness process group $child was alive; SIGKILL to process groups" "$JOBS/$id.log"; then
        pass "26 the reaper (any status) resumes the cleanup of a cancelled job whose runner died before stopping the harness: SIGKILL to the verified tree, the verdict unchanged"
    else
        fail "26 the reaper (any status) resumes the cleanup of a cancelled job whose runner died before stopping the harness: SIGKILL to the verified tree, the verdict unchanged"
        echo "    harness=$child (alive before: $alive_before) $(jfield job.status <<<"$sj") note=$(jfield job.note <<<"$sj")"; tail -3 "$JOBS/$id.log"
    fi

    # --- 27. auxiliary commands (discover's --version) run under a hard deadline and stop on cancel ---
    pids="$TEST_ROOT/pids-27a.txt"
    rm -f "$pids"
    t0="$(now_ms)"
    id="$(AGENT_STUB_VERSION_HANG=ignore-term AGENT_STUB_PIDS="$pids" start_task --profile dh --profile-json '{"harness":"plain","discoverTimeoutMs":300}' --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 15)"
    t1="$(now_ms)"
    d1="$(sed -n 1p "$pids" 2>/dev/null)"
    sj="$(ad status "$id" --json)"
    if [[ "$st" == failed && "$(jfield job.errorClass <<<"$sj")" == launch && "$(jfield job.note <<<"$sj")" == *"--version"* && -n "$d1" ]] && (((t1 - t0) < 8000)) && gone "$d1"; then
        pass "27 a --version that ignores SIGTERM past its 300 ms deadline is SIGKILLed after the grace: the job fails launch in bounded time ($((t1 - t0)) ms), nothing left"
    else
        fail "27 a --version that ignores SIGTERM past its 300 ms deadline is SIGKILLed after the grace: the job fails launch in bounded time ($((t1 - t0)) ms), nothing left"
        echo "    status=$st note=$(jfield job.note <<<"$sj") stub=$d1"
    fi
    pids="$TEST_ROOT/pids-27b.txt"
    rm -f "$pids"
    id="$(AGENT_STUB_VERSION_HANG=ignore-term AGENT_STUB_PIDS="$pids" start_task --write --cwd "$repo6" --profile dh --profile-json '{"harness":"plain","discoverTimeoutMs":60000}' --prompt-file "$prompt")"
    wait_lines "$pids" 1 || true
    d1="$(sed -n 1p "$pids" 2>/dev/null)"
    t0="$(now_ms)"
    out="$(with_deadline 30 ad cancel "$id" --cwd "$repo6")"
    t1="$(now_ms)"
    rc=0
    err="$(AGENT_STUB_MODE=ok ad task --background --write --cwd "$repo6" --profile p1 --prompt-file "$prompt" 2>&1)" || rc=$?
    id2="${err##* }"
    st="$(wait_status "$id2" 'completed|failed|cancelled' 20 --cwd "$repo6")"
    if [[ -n "$d1" && "$out" == "cancelled $id" && "$rc" -eq 0 && "$st" == completed ]] && (((t1 - t0) < 5000)) && gone "$d1"; then
        pass "27 cancel during a discovery that hangs (and ignores SIGTERM): the runner's --version is stopped at once, cancel returns in bounded time ($((t1 - t0)) ms) and the write reservation is free"
    else
        fail "27 cancel during a discovery that hangs (and ignores SIGTERM): the runner's --version is stopped at once, cancel returns in bounded time ($((t1 - t0)) ms) and the write reservation is free"
        echo "    stub=$d1 out=$out next=$rc:$err/$st"
    fi

    # --- 28. a start time that cannot be read is "unknown": never signalled, never released as gone ---
    local JOBS7 sleeper2 sleeper2_start
    JOBS7="$(jobs_dir_of "$repo7")"
    rec="$TEST_ROOT/ready-28.json"
    id="$(AGENT_STUB_MODE=hang AGENT_STUB_RECORD="$rec" start_task --write --cwd "$repo7" --profile p1 --prompt-file "$prompt")"
    child="$(wait_child "$id" --cwd "$repo7")"
    wait_file "$rec" || true
    runner="$(ad status "$id" --cwd "$repo7" --json | jfield job.runnerPid)"
    kill -KILL "$runner" 2>/dev/null
    gone "$runner" || true
    rc=0
    err="$(AGENT_TEST_PS_START=unavailable ad release-stale --cwd "$repo7" 2>&1)" || rc=$?
    if [[ -n "$child" && "$rc" -eq 2 && "$err" == *"still has harness process group $child alive, unconfirmed (its start time cannot be read)"* ]] && kill -0 "$child" 2>/dev/null; then
        pass "28 runner dead, its harness alive but its start time unreadable (ps): release-stale refuses (exit 2), the reservation stays"
    else
        fail "28 runner dead, its harness alive but its start time unreadable (ps): release-stale refuses (exit 2), the reservation stays"
        echo "    exit=$rc err=$err harness=$child"
    fi
    sj="$(AGENT_TEST_PS_START=unavailable ad status "$id" --cwd "$repo7" --json)"
    rc=0
    err="$(AGENT_TEST_PS_START=unavailable ad release-stale --cwd "$repo7" 2>&1)" || rc=$?
    if [[ "$(jfield job.status <<<"$sj")" == failed && "$(jfield job.note <<<"$sj")" == "runner died" && "$rc" -eq 2 ]] && kill -0 "$child" 2>/dev/null \
        && grep -q "harness process group $child not signalled: it is alive, but its start time cannot be read" "$JOBS7/$id.log"; then
        pass "28 the reaper with the start time unreadable: failed/crash, the harness group is not signalled (said in the log), and release-stale still refuses"
    else
        fail "28 the reaper with the start time unreadable: failed/crash, the harness group is not signalled (said in the log), and release-stale still refuses"
        echo "    $(jfield job.status <<<"$sj") note=$(jfield job.note <<<"$sj") release-stale=$rc:$err"
    fi
    # Readable again: the next status resumes the pending cleanup; then the reservation can go.
    ad status "$id" --cwd "$repo7" >/dev/null
    local swept=no
    if gone "$child"; then swept=yes; fi
    rc=0
    out="$(ad release-stale --cwd "$repo7" 2>&1)" || rc=$?
    id2="$(AGENT_STUB_MODE=ok start_task --write --cwd "$repo7" --profile p1 --prompt-file "$prompt")"
    st="$(wait_status "$id2" 'completed|failed|cancelled' 20 --cwd "$repo7")"
    if [[ "$swept" == yes && "$rc" -eq 0 && "$out" =~ ^released\ $repo7\ generation\ [0-9]+$ && "$st" == completed ]] \
        && grep -q "cleanup resumed: the job is failed but its runner pid $runner is gone" "$JOBS7/$id.log"; then
        pass "28 once the start time is readable again, a status call stops the left-over harness tree; release-stale then releases, the next write task runs"
    else
        fail "28 once the start time is readable again, a status call stops the left-over harness tree; release-stale then releases, the next write task runs"
        echo "    harness=$child release-stale=$rc:$out next=$st"
    fi
    # A live runner whose start time cannot be read keeps its job (it may be ours); a provably reused pid does not.
    sleeper2="$(spawn_sleeper)"
    SLEEPERS="$SLEEPERS $sleeper2"
    sleeper2_start="$(core_js 'console.log(core.processStart(Number(process.argv[1])) ?? "")' "$sleeper2")"
    fixture_record "$JOBS7" pt-0900 "{\"workspaceRoot\":\"$repo7\",\"cwd\":\"$repo7\",\"runnerPid\":$sleeper2,\"runnerStartedAt\":\"$sleeper2_start\"}"
    out="$(AGENT_TEST_PS_START=unavailable ad status pt-0900 --cwd "$repo7" --json | jfield job.status)"
    out2="$(ad status pt-0900 --cwd "$repo7" --json | jfield job.status)"
    if [[ -n "$sleeper2_start" && "$out" == running && "$out2" == running ]] && kill -0 "$sleeper2" 2>/dev/null; then
        pass "28 a live runner whose start time is unreadable (unknown) or matches (ours) keeps its job running; nothing is signalled"
    else
        fail "28 a live runner whose start time is unreadable (unknown) or matches (ours) keeps its job running; nothing is signalled"
        echo "    unreadable=$out readable=$out2 start=$sleeper2_start"
    fi
    core_js 'core.finalizeRecord(process.argv[1], { status: "failed", errorClass: "crash", note: "fixture done" });' "$JOBS7/pt-0900.json"
    kill "$sleeper2" 2>/dev/null

    # --- 29. cancel before the runner entered runJob: the runner still releases the reservation it was handed ---
    local barrier="$TEST_ROOT/run-barrier-29" launches="$TEST_ROOT/launches-29.txt"
    rm -f "$barrier" "$launches"
    id="$(CORE_HARNESS_RUN_BARRIER="$barrier" AGENT_STUB_MODE=ok AGENT_STUB_LAUNCH_LOG="$launches" start_task --write --cwd "$repo8" --profile p1 --prompt-file "$prompt")"
    rm -f "$TEST_ROOT/cancel-29.rc"
    (
        crc=0
        ad cancel "$id" --cwd "$repo8" >"$TEST_ROOT/cancel-29.out" 2>&1 || crc=$?
        echo "$crc" >"$TEST_ROOT/cancel-29.rc"
    ) &
    local cancel_pid=$!
    st="$(wait_status "$id" 'cancelled|completed|failed' 10 --cwd "$repo8")"
    touch "$barrier" # the runner enters runJob only now, its job already cancelled
    wait_file "$TEST_ROOT/cancel-29.rc" || true
    wait "$cancel_pid" 2>/dev/null
    rc=0
    err="$(AGENT_STUB_MODE=ok ad task --background --write --cwd "$repo8" --profile p1 --prompt-file "$prompt" 2>&1)" || rc=$?
    id2="${err##* }"
    out="$(wait_status "$id2" 'completed|failed|cancelled' 20 --cwd "$repo8")"
    if [[ "$st" == cancelled && "$(cat "$TEST_ROOT/cancel-29.rc" 2>/dev/null)" == 0 && "$(cat "$TEST_ROOT/cancel-29.out")" == "cancelled $id" && ! -s "$launches" \
        && "$rc" -eq 0 && "$out" == completed ]] && grep -q "job $id is cancelled already; nothing started" "$(jobs_dir_of "$repo8")/$id.log"; then
        pass "29 cancel wins before the runner enters runJob: no harness starts, the runner releases the write reservation, the next write task runs without release-stale"
    else
        fail "29 cancel wins before the runner enters runJob: no harness starts, the runner releases the write reservation, the next write task runs without release-stale"
        echo "    status=$st cancel=$(cat "$TEST_ROOT/cancel-29.rc" 2>/dev/null):$(cat "$TEST_ROOT/cancel-29.out" 2>/dev/null) launches=$(wc -l <"$launches" 2>/dev/null) next=$rc:$err/$out"
    fi

    # --- 30. one runner per job, also for two __run released into the claim at the same moment ---
    barrier="$TEST_ROOT/claim-barrier-30"
    launches="$TEST_ROOT/launches-30.txt"
    rm -f "$barrier"* "$launches" "$TEST_ROOT"/run30-*.rc
    mkdir -p "$JOBS/pt-9000"
    cp "$prompt" "$JOBS/pt-9000/prompt.md"
    fixture_record "$JOBS" pt-9000 "{\"workspaceRoot\":\"$repo\",\"cwd\":\"$repo\",\"promptPath\":\"$JOBS/pt-9000/prompt.md\"}"
    for k in 1 2; do
        (
            krc=0
            AGENT_TEST_RUN_BARRIER="$barrier" AGENT_STUB_MODE=ok AGENT_STUB_LAUNCH_LOG="$launches" ad __run pt-9000 "$JOBS" - >/dev/null 2>&1 || krc=$?
            echo "$krc" >"$TEST_ROOT/run30-$k.rc"
        ) &
    done
    local ready=0
    for ((k = 0; k < 100; k++)); do
        ready="$(compgen -G "$barrier.ready-*" | wc -l | tr -d ' ')"
        if ((ready >= 2)); then break; fi
        sleep 0.1
    done
    touch "$barrier" # both runners passed the pre-claim check; now both claim at once
    wait
    out="$(cat "$TEST_ROOT"/run30-*.rc 2>/dev/null | sort | tr '\n' ' ')"
    st="$(wait_status pt-9000 'completed|failed|cancelled' 20)"
    if [[ "$ready" -eq 2 && "$out" == "0 1 " && "$(wc -l <"$launches" | tr -d ' ')" == 1 && "$st" == completed ]] \
        && grep -q "__run refused for pt-9000 in pid [0-9]*: runner pid [0-9]* owns the job" "$JOBS/pt-9000.log"; then
        pass "30 two __run that both passed the pre-claim check claim at once: exactly one wins (exit 0, one harness launch), the other is refused (exit 1)"
    else
        fail "30 two __run that both passed the pre-claim check claim at once: exactly one wins (exit 0, one harness launch), the other is refused (exit 1)"
        echo "    ready=$ready exit codes: $out launches=$(wc -l <"$launches" 2>/dev/null) status=$st"
    fi

    # --- 31. a process's identity does not move with the wall clock (Linux: /proc ticks, not procps' lstart) ---
    out="$(core_js '
const line = (comm, ticks = "987654") => `4242 (${comm}) S 1 4242 4242 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 1 0 ${ticks} 1000 10 0`;
console.log(JSON.stringify([core.parseProcStat(line("node")), core.parseProcStat(line("a b) (c")), core.parseProcStat("garbage"), core.parseProcStat(line("x", "-"))]));')"
    if [[ "$out" == '["987654","987654",null,null]' ]]; then
        pass "31 parseProcStat reads field 22 (start ticks) after the last ')' of the command name, whatever the name holds"
    else
        fail "31 parseProcStat reads field 22 (start ticks) after the last ')' of the command name, whatever the name holds"
        echo "    got: $out"
    fi
    local sleeper3
    sleeper3="$(spawn_sleeper)"
    SLEEPERS="$SLEEPERS $sleeper3"
    out="$(core_js '
const fs = await import("node:fs");
const pid = Number(process.argv[1]);
const own = core.processStart(pid);
const linux = process.platform === "linux";
const source = linux ? own === `ticks:${core.parseProcStat(fs.readFileSync(`/proc/${pid}/stat`, "utf8"))}` : /^[A-Z][a-z]{2} [A-Z][a-z]{2} \d+ \d\d:\d\d:\d\d \d{4}$/.test(own ?? "");
console.log([source, core.processStart(pid) === own, core.processIdentity(pid, own), core.processIdentity(pid, "Thu Jan 1 00:00:00 1970"),
  core.processIdentity(pid, "ticks:1"), linux ? "linux" : "other"].join(" "));' "$sleeper3")"
    if [[ "$out" == "true true ours foreign foreign linux" || "$out" == "true true ours foreign unknown other" ]]; then
        pass "31 processStart: /proc start ticks on Linux, lstart elsewhere; a stored value is compared in its own format (lstart via ps, ticks via /proc — never one with the other)"
    else
        fail "31 processStart: /proc start ticks on Linux, lstart elsewhere; a stored value is compared in its own format (lstart via ps, ticks via /proc — never one with the other)"
        echo "    got: $out"
    fi
    kill "$sleeper3" 2>/dev/null
    if [[ "$(uname -s)" == Linux ]]; then
        # procps prints lstart as /proc/stat btime + start ticks, and btime moves with every wall-clock step: a ps that
        # prints another lstart for every process is what a live job meets after one. Its identity must not care.
        local shim="$TEST_ROOT/ps-shim" real_ps
        real_ps="$(command -v ps)"
        mkdir -p "$shim"
        printf '#!/bin/bash\ncase " $* " in *lstart*) "%s" "$@" >/dev/null || exit $?; echo "Mon Jan  1 00:00:00 2001"; exit 0 ;; esac\nexec "%s" "$@"\n' "$real_ps" "$real_ps" >"$shim/ps"
        chmod +x "$shim/ps"
        rec="$TEST_ROOT/ready-31.json"
        id="$(AGENT_STUB_MODE=hang AGENT_STUB_RECORD="$rec" start_task --write --cwd "$repo9" --profile p1 --prompt-file "$prompt")"
        child="$(wait_child "$id" --cwd "$repo9")"
        wait_file "$rec" || true
        runner="$(ad status "$id" --cwd "$repo9" --json | jfield job.runnerPid)"
        st="$(PATH="$shim:$PATH" ad status "$id" --cwd "$repo9" --json | jfield job.status)"
        rc=0
        err="$(PATH="$shim:$PATH" ad release-stale --cwd "$repo9" 2>&1)" || rc=$?
        rc2=0
        out2="$(PATH="$shim:$PATH" AGENT_STUB_MODE=ok ad task --background --write --cwd "$repo9" --profile p1 --prompt-file "$prompt" 2>&1)" || rc2=$?
        sleep 1 # a runner that met a terminal claim would have started its ladder by now
        local alive_after=no
        if [[ -n "$child" ]] && kill -0 "$child" 2>/dev/null && kill -0 "$runner" 2>/dev/null; then alive_after=yes; fi
        out="$(with_deadline 30 ad cancel "$id" --cwd "$repo9")"
        if [[ "$st" == running && "$rc" -eq 2 && "$err" == *"is held by live runner pid $runner"* && "$rc2" -eq 2 && "$out2" == *"job $id is still running"* \
            && "$alive_after" == yes && "$out" == "cancelled $id" ]] && gone "$child"; then
            pass "31 Linux: with every lstart reading differently (a wall-clock step), a live write job stays running — status, release-stale and a second write task all see its runner — and cancel still stops it"
        else
            fail "31 Linux: with every lstart reading differently (a wall-clock step), a live write job stays running — status, release-stale and a second write task all see its runner — and cancel still stops it"
            echo "    status=$st release-stale=$rc:$err second=$rc2:$out2 alive=$alive_after cancel=$out"
        fi
    else
        echo "  [SKIP] 31 Linux only: a wall-clock step under a live job (macOS's lstart is the start time stored at fork; no step moves it)"
    fi

    # --- 32. cancel before the runner claimed a read-only job: the cleanup marker is left to that runner ---
    barrier="$TEST_ROOT/run-barrier-32"
    launches="$TEST_ROOT/launches-32.txt"
    id="$(CORE_HARNESS_RUN_BARRIER="$barrier" AGENT_STUB_MODE=ok AGENT_STUB_LAUNCH_LOG="$launches" start_task --profile p1 --prompt-file "$prompt")"
    runner="$(pgrep -f "__run $id " | head -1)"
    out="$(with_deadline 30 ad cancel "$id")"
    local marked_early=no
    if [[ -e "$JOBS/$id.json.cleaned" ]]; then marked_early=yes; fi
    touch "$barrier"
    gone "$runner" || true
    if [[ -n "$runner" && "$out" == "cancelled $id" && "$marked_early" == no && -e "$JOBS/$id.json.cleaned" && ! -s "$launches" ]] \
        && grep -q "job $id is cancelled already; nothing started" "$JOBS/$id.log"; then
        pass "32 cancel of a read-only job whose runner has not claimed it yet: no cleanup marker while that runner lives; it finds the job cancelled, starts nothing and writes the marker itself"
    else
        fail "32 cancel of a read-only job whose runner has not claimed it yet: no cleanup marker while that runner lives; it finds the job cancelled, starts nothing and writes the marker itself"
        echo "    runner=$runner cancel=$out marked early: $marked_early launches=$(wc -l <"$launches" 2>/dev/null)"
    fi

    # --- 33. a job id stays taken while anything of the job is left, not only its record ---
    out="$(core_js '
const fs = await import("node:fs");
const dir = process.argv[1];
fs.mkdirSync(`${dir}/pt-0008`, { recursive: true });
for (const name of ["pt-0003.json", "pt-0007.json.runner", "pt-0009.log", "pt-0010.json.cleaned", "pt-0011.json.terminal", "zt-0099.json.runner"]) fs.writeFileSync(`${dir}/${name}`, "{}");
const a = core.allocateJob(dir, "pt", { status: "running" });
fs.rmSync(`${dir}/${a}.json`);
fs.writeFileSync(`${dir}/${a}.json.runner`, "{}");
console.log(a, core.allocateJob(dir, "oc", { status: "running" }));' "$TEST_ROOT/alloc-traces")"
    id="$(AGENT_STUB_MODE=ok start_task --profile p1 --prompt-file "$prompt")"
    st="$(wait_status "$id" 'completed|failed|cancelled' 20)"
    # The record alone, as a hand or a prune might remove it: its .terminal, .runner and .cleaned stay.
    core_js '(await import("node:fs")).rmSync(process.argv[1]);' "$JOBS/$id.json"
    id2="$(AGENT_STUB_MODE=ok start_task --profile p1 --prompt-file "$prompt")"
    out2="$(wait_status "$id2" 'completed|failed|cancelled' 20)"
    if [[ "$out" == "pt-0012 oc-0013" && "$st" == completed && "$id2" != "$id" && "$out2" == completed ]]; then
        pass "33 allocateJob counts every trace of a job (side files, log, job dir): a record removed alone never hands its runner claim or cleanup marker to a new job under its id"
    else
        fail "33 allocateJob counts every trace of a job (side files, log, job dir): a record removed alone never hands its runner claim or cleanup marker to a new job under its id"
        echo "    unit=$out first=$id/$st next=$id2/$out2"
    fi

    # --- 34. the probe asks invocation() (the contract's harness-less hook) whether a key is needed, not probe() ---
    rec="$TEST_ROOT/probe-34.json"
    keylog="$TEST_ROOT/keylog-34.txt"
    rc=0
    out="$(CORE_HARNESS_KEY_LOG="$keylog" TEST_SECRET="$SECRET" AGENT_STUB_MODE=ok AGENT_STUB_RESPONSE=PONG AGENT_STUB_RECORD="$rec" \
        ad probe --profile pp --profile-json '{"harness":"plain-probe","auth":{"keyEnv":"TEST_SECRET"}}' 2>&1)" || rc=$?
    if [[ "$rc" -eq 0 && "$out" == 'probe pp: completed response="PONG"' && "$(jfield argv <"$rec" 2>/dev/null)" == *'"--model","probe-of-1.0.0"'* \
        && "$(jfield env.PLAIN_API_KEY <"$rec" 2>/dev/null)" == "$SECRET" && "$(cat "$keylog" 2>/dev/null)" == "resolved TEST_SECRET" ]]; then
        pass "34 a probe() hook that reads req.harness runs only once the harness is known; the key is still resolved once, before discovery"
    else
        fail "34 a probe() hook that reads req.harness runs only once the harness is known; the key is still resolved once, before discovery"
        echo "    exit=$rc out=${out//$SECRET/<SECRET>} keylog=$(cat "$keylog" 2>/dev/null)"
    fi

    # --- 35. ctx.exec keeps spawnSync's calling convention: errors, Buffer input, timeoutMs 0 ---
    out="$(core_js '
const { spawnSync } = await import("node:child_process");
const exec = core.makeCtx({}).exec;
const fields = (e) => JSON.stringify(e && { message: e.message, errno: e.errno, code: e.code, syscall: e.syscall, path: e.path, spawnargs: e.spawnargs });
const missing = `${process.argv[1]}/no-such-binary`;
const same = fields(exec(missing, ["x"]).error) === fields(spawnSync(missing, ["x"]).error);
const echo = exec(process.execPath, ["-e", "process.stdin.pipe(process.stdout)"], { input: Buffer.from("bytes-in") });
const typed = exec(process.execPath, ["-e", "process.stdin.pipe(process.stdout)"], { input: new Uint8Array([104, 105]) });
const t0 = Date.now();
const slow = exec(process.execPath, ["-e", "setTimeout(() => {}, 400)"], { timeoutMs: 0 });
const t1 = Date.now();
const late = exec(process.execPath, ["-e", "setTimeout(() => {}, 5000)"], { timeoutMs: 200 });
console.log([same, echo.stdout, typed.stdout, slow.status, slow.error === null, slow.timedOut, t1 - t0 >= 350, late.error?.code,
  late.error?.syscall === `spawnSync ${process.execPath}`, late.timedOut].join(" "));' "$TEST_ROOT")"
    if [[ "$out" == "true bytes-in hi 0 true false true ETIMEDOUT true true" ]]; then
        pass "35 ctx.exec: a spawn error has spawnSync's fields (code, errno, syscall, path, spawnargs); Buffer / typed-array input; timeoutMs 0 is no deadline; a deadline is ETIMEDOUT"
    else
        fail "35 ctx.exec: a spawn error has spawnSync's fields (code, errno, syscall, path, spawnargs); Buffer / typed-array input; timeoutMs 0 is no deadline; a deadline is ETIMEDOUT"
        echo "    got: $out"
    fi

    # --- 36. a SIGKILL to the runner's whole process group does not orphan an auxiliary command ---
    pids="$TEST_ROOT/pids-36.txt"
    id="$(AGENT_STUB_VERSION_HANG=ignore-term AGENT_STUB_PIDS="$pids" start_task --write --cwd "$repo10" --profile dh --profile-json '{"harness":"plain","discoverTimeoutMs":60000}' --prompt-file "$prompt")"
    wait_lines "$pids" 1 || true
    d1="$(sed -n 1p "$pids" 2>/dev/null)"
    runner="$(ad status "$id" --cwd "$repo10" --json | jfield job.runnerPid)"
    if [[ -n "$runner" ]]; then kill -KILL -- "-$runner" 2>/dev/null; fi # startJob makes the runner a group leader
    local aux_gone=no
    if gone "$d1"; then aux_gone=yes; fi
    sj="$(ad status "$id" --cwd "$repo10" --json)"
    rc=0
    out="$(ad release-stale --cwd "$repo10" 2>&1)" || rc=$?
    id2="$(AGENT_STUB_MODE=ok start_task --write --cwd "$repo10" --profile p1 --prompt-file "$prompt")"
    st="$(wait_status "$id2" 'completed|failed|cancelled' 20 --cwd "$repo10")"
    if [[ -n "$d1" && "$aux_gone" == yes && "$(jfield job.status <<<"$sj")" == failed && "$(jfield job.note <<<"$sj")" == "runner died" \
        && -e "$(jobs_dir_of "$repo10")/$id.json.cleaned" && "$rc" -eq 0 && "$st" == completed ]]; then
        pass "36 SIGKILL to the runner's process group during a discovery that hangs (and ignores SIGTERM): its supervisor, in a group of its own, ends the --version; the job is reaped, release-stale frees the worktree"
    else
        fail "36 SIGKILL to the runner's process group during a discovery that hangs (and ignores SIGTERM): its supervisor, in a group of its own, ends the --version; the job is reaped, release-stale frees the worktree"
        echo "    stub=$d1 gone=$aux_gone $(jfield job.status <<<"$sj") note=$(jfield job.note <<<"$sj") release-stale=$rc:$out next=$st"
    fi

    # --- leak check: nothing this run started is still running ---
    local left="" i=0
    while ((i < 50)); do
        left="$(pgrep -f "$TEST_ROOT" | tr '\n' ' ')"
        [[ -z "$left" ]] && break
        sleep 0.2
        i=$((i + 1))
    done
    if [[ -z "$left" ]]; then
        pass "no process of this run (runner, harness, descendant) outlives the suite"
    else
        fail "no process of this run (runner, harness, descendant) outlives the suite"
        ps -o pid,ppid,pgid,command -p "$(tr ' ' ',' <<<"${left% }")" 2>/dev/null || true
    fi

    echo ""
    echo "PASS count: $PASSES"
    if [[ "$FAILURES" -ne 0 ]]; then
        echo "FAILED: $FAILURES assertion(s)."
        exit 1
    fi
    echo "PASS"
}

main "$@"
