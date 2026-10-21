#!/usr/bin/env bash
# Tests for bin/lib/adapters/pi.mjs, the core adapter of the pi harness (increment 5 of
# docs/superpowers/specs/2026-10-20-universal-dispatchers-design.md §8). Zero model calls and no real pi: profiles
# point "bin" at a per-run link to tests/fixtures/agent-stub.cjs in its pi-jsonl dialect
# (tests/fixtures/stub-dialects/pi-jsonl.cjs), which reproduces pi 1.3.x as docs/research/universal-dispatchers/03-pi.md
# documents it and records argv, env and stdin. Jobs go through the real CLI (bin/lib/agent-dispatch.mjs) with all
# state under a temp root (AGENT_DISPATCH_STATE_DIR, HOME); the pure adapter functions are also called directly.
# Runs on macOS and Linux.
#
# Every process a run starts carries the run's temp root in its argv (runners: their jobs dir; the stub: the link
# under the temp root; its descendants: their pid file), so the cleanup and the leak check touch this run only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$REPO_ROOT/bin/lib/agent-dispatch.mjs"
CORE="$REPO_ROOT/bin/lib/agent-core.mjs"
ADAPTER="$REPO_ROOT/bin/lib/adapters/pi.mjs"
STUB="$SCRIPT_DIR/fixtures/agent-stub.cjs"

FAILURES=0
PASSES=0
TEST_ROOT=""
OUT=""
ERR=""
RC=0
ID=""

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
    # Only this run's processes (see the header). SIGKILL: some stub modes ignore SIGTERM by design.
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

# run_env <VAR=value | -u NAME>... -- <agent-dispatch args...> — run_ad with these variables changed.
run_env() {
    local -a vars=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        vars+=("$1")
        shift
    done
    shift
    OUT="$(env ${vars[@]+"${vars[@]}"} node "$CLI" "$@" 2>"$TEST_ROOT/stderr.txt")"
    RC=$?
    ERR="$(cat "$TEST_ROOT/stderr.txt")"
}

# start <VAR=value | -u NAME>... -- <task args...> — `task --background` with these variables; ID = the new job id
# ('' when refused).
start() {
    local -a vars=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        vars+=("$1")
        shift
    done
    shift
    run_env ${vars[@]+"${vars[@]}"} -- task --background "$@"
    ID=""
    if [[ "$RC" -eq 0 ]]; then ID="${OUT##* }"; fi
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

# jarr <args...> — the JSON array of the arguments (the shape the stub records argv in).
jarr() { node -e 'process.stdout.write(JSON.stringify(process.argv.slice(1)))' -- "$@"; }

# env_names <record> <regex> — the names of the recorded harness environment that match, sorted, space-separated.
env_names() {
    node -e 'const r = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
console.log(Object.keys(r.env).filter((n) => new RegExp(process.argv[2]).test(n)).sort().join(" "));' -- "$1" "$2"
}

# wait_status <id> <regex> <seconds> — poll until the core job's status matches; print it.
wait_status() {
    local id="$1" want="$2" limit="$3"
    local st="" i=0
    while ((i < limit * 5)); do
        st="$(ad status "$id" --json 2>/dev/null | jfield job.status || true)"
        if [[ "$st" =~ ^($want)$ ]]; then break; fi
        sleep 0.2
        i=$((i + 1))
    done
    echo "$st"
}

# job <id> <field> — a field of the job record (status --json).
job() { ad status "$1" --json 2>/dev/null | jfield "job.$2"; }

# outcome <id> — "<status>/<errorClass>" once terminal (waits up to 20 s).
outcome() {
    local st
    st="$(wait_status "$1" 'completed|failed|cancelled' 20)"
    echo "$st/$(job "$1" errorClass)"
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

# gone <pid...> — true once none of the processes exists (waits up to 5 s); false for no pid or an empty one.
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

now_ms() { node -e 'console.log(Date.now())'; }

mode_of() { node -e 'console.log((require("node:fs").statSync(process.argv[1]).mode & 0o777).toString(8))' -- "$1"; }

# pi_js <script> [args...] — an ES module snippet with `core` (agent-core.mjs), `pi` (the adapter's default export) and
# `mod` (all its exports); the args are process.argv.slice(1).
pi_js() {
    local script="$1"
    shift
    CORE="$CORE" ADAPTER="$ADAPTER" node --input-type=module -e "
const { pathToFileURL } = await import('node:url');
const core = await import(pathToFileURL(process.env.CORE).href);
const mod = await import(pathToFileURL(process.env.ADAPTER).href);
const pi = mod.default;
$script" "$@"
}

jobs_dir_of() { pi_js 'console.log(core.resolveWorkspace(process.argv[1]).jobsDir);' "$1"; }

main() {
    echo "=== Test: pi adapter ==="

    TEST_ROOT="$(mktemp -d)"
    trap cleanup EXIT
    umask 022

    export HOME="$TEST_ROOT/home"
    mkdir -p "$HOME" "$TEST_ROOT/bin" "$TEST_ROOT/rec" "$TEST_ROOT/fdrg" "$TEST_ROOT/nodeonly" "$TEST_ROOT/user-pi" "$TEST_ROOT/ext"
    export AGENT_DISPATCH_STATE_DIR="$TEST_ROOT/state"
    local STATE="$AGENT_DISPATCH_STATE_DIR"
    local CONFIG="$STATE/config.json"
    local PI="$TEST_ROOT/bin/pi"
    ln -s "$STUB" "$PI"
    ln -s "$STUB" "$TEST_ROOT/bin/pi-drop"
    ln -s "$(command -v node)" "$TEST_ROOT/nodeonly/node"
    ln -s "$(command -v node)" "$TEST_ROOT/fdrg/node"
    printf '#!/bin/sh\nexit 0\n' >"$TEST_ROOT/fdrg/fd"
    printf '#!/bin/sh\nexit 0\n' >"$TEST_ROOT/fdrg/rg"
    chmod +x "$TEST_ROOT/fdrg/fd" "$TEST_ROOT/fdrg/rg"
    local EXT="$TEST_ROOT/ext/provider.ts"
    printf 'export default function (pi) {}\n' >"$EXT"
    unset AGENT_TEST_BOOT_ID AGENT_DISPATCH_ADAPTER_DIR CLAUDE_CONFIG_DIR WRAPPED
    unset AGENT_STUB_MODE AGENT_STUB_RECORD AGENT_STUB_DELAY_MS AGENT_STUB_MESSAGE AGENT_STUB_CLASS AGENT_STUB_EXIT AGENT_STUB_RESPONSE
    unset AGENT_STUB_SECRET_VAR AGENT_STUB_PIDS AGENT_STUB_SIGNALS AGENT_STUB_VERSION AGENT_STUB_HELP_DROP AGENT_STUB_CALL_LOG
    unset AGENT_STUB_AUTH AGENT_STUB_AUTH_LOG AGENT_STUB_HELP_EXIT AGENT_STUB_STDERR_LINES
    export AGENT_STUB_DIALECT=pi-jsonl
    export AGENT_ENV_PASSTHROUGH="AGENT_STUB_DIALECT,AGENT_STUB_MODE,AGENT_STUB_RECORD,AGENT_STUB_DELAY_MS,AGENT_STUB_MESSAGE,AGENT_STUB_EXIT,AGENT_STUB_RESPONSE,AGENT_STUB_SECRET_VAR,AGENT_STUB_PIDS,AGENT_STUB_SIGNALS,AGENT_STUB_VERSION,AGENT_STUB_HELP_DROP,AGENT_STUB_AUTH,AGENT_STUB_AUTH_LOG,AGENT_STUB_STDERR_LINES"
    # The caller's environment carries a pi home and provider credentials: none of them may reach a keyed profile.
    export PI_CODING_AGENT_DIR="$TEST_ROOT/user-pi"
    export OPENAI_API_KEY="caller-openai-key-1" ZAI_API_KEY="caller-zai-key-2" ANTHROPIC_BASE_URL="https://caller.example"
    export PI_TEST_KEY="env-key-value-5150"
    local ZKEY="zai-key-value-424242"

    local git_id=(-c user.email=t@example.com -c user.name=t -c commit.gpgsign=false)
    git init -q -b main "$TEST_ROOT/repo"
    printf 'x\n' >"$TEST_ROOT/repo/a.txt"
    (cd "$TEST_ROOT/repo" && git add a.txt && git "${git_id[@]}" commit -qm c0)
    local repo
    repo="$(cd "$TEST_ROOT/repo" && git rev-parse --show-toplevel)"
    local prompt="$TEST_ROOT/prompt.md"
    printf '## Headless run\n\nImplement the thing.\n\n' >"$prompt"
    cd "$repo"
    local JOBS
    JOBS="$(jobs_dir_of "$repo")"
    printf '%s\n' "$ZKEY" | ad key set zai >/dev/null

    local base="\"harness\": \"pi\", \"bin\": \"$PI\""
    local zai="$base, \"auth\": { \"key\": \"zai\" }, \"keyVar\": \"ZAI_API_KEY\", \"shares\": \"zai-coding-plan\", \"model\": \"zai/glm-5.3\", \"effort\": \"high\""
    local login="$base, \"auth\": \"login\", \"model\": \"openai/gpt-6-luna\", \"effort\": \"xhigh\""
    mkdir -p "$STATE"
    cat >"$CONFIG" <<EOF
{
  "version": 1,
  "profiles": {
    "pi-key": { $zai },
    "pi-key-user": { $zai, "home": "user" },
    "pi-env": { $base, "auth": { "keyEnv": "PI_TEST_KEY" }, "keyVar": "DEEPSEEK_API_KEY", "model": "deepseek/deepseek-v4-pro", "effort": "max" },
    "pi-cmd": { $base, "auth": { "keyCmd": ["node", "-e", "process.stdout.write('cmd-key-' + 'value-31337' + '\\\\n')"] }, "keyVar": "OPENROUTER_API_KEY", "model": "openrouter/qwen/qwen3.8-coder" },
    "pi-login": { $login },
    "pi-login-iso": { $login, "home": "isolated" },
    "pi-bare": { $base, "auth": "login" },
    "pi-ext": { $login, "options": { "extensions": ["builtin:llama.cpp", "$EXT"] } },
    "pi-ext-bad": { $login, "options": { "extensions": ["$TEST_ROOT/ext/missing.ts"] } },
    "pi-ext-rel": { $login, "options": { "extensions": ["ext/provider.ts"] } },
    "pi-ext-typo": { $login, "options": { "extensions": ["builtin:llamacpp"] } },
    "pi-key-fast": { $zai, "timeoutMin": 0.02 },
    "pi-native": { $zai, "sandbox": "native" },
    "pi-offline0": { $zai, "env": { "PI_OFFLINE": "0" } },
    "pi-clash-home": { $zai, "env": { "PI_CODING_AGENT_DIR": "$TEST_ROOT/elsewhere" } },
    "pi-clash-key": { $zai, "env": { "ZAI_API_KEY": "profile-env-value" } },
    "pi-many": { $login, "maxParallel": 40 },
    "pi-fdrg": { $login, "env": { "PATH": "$TEST_ROOT/fdrg" } },
    "pi-nofdrg": { $login, "env": { "PATH": "$TEST_ROOT/nodeonly" } },
    "pi-nobin": { "harness": "pi", "auth": "login", "model": "openai/x", "bin": "$TEST_ROOT/bin/no-such-pi" },
    "pi-drop": { "harness": "pi", "auth": "login", "model": "openai/x", "bin": "$TEST_ROOT/bin/pi-drop" },
    "pi-fast": { $login, "timeoutMin": 0.02 },
    "pi-wrap": { $login, "wrap": ["env", "WRAPPED=yes"] }
  }
}
EOF
    # From here on a failing command must not end the suite: FAILURES decides the exit code, and the summary prints.
    set +e

    local ok want got rec st id1 id2 dir t0 t1 tterm stub_pid child line n

    # --- 1. the adapter contract (spec §3.2) and its loading by the CLI ---
    got="$(pi_js 'const m = pi.manifest;
console.log(JSON.stringify([pi.id, pi.idPrefix, m.sessionId, m.sessionIdFormat, m.cancel.ladder, m.helpArgv, m.requiredFlags, m.homeEnv, m.verifiedVersions,
  ["discover", "prepareHome", "invocation", "probe", "reduce", "finalize", "scrub", "resumeCheck", "doctorChecks"].every((k) => typeof pi[k] === "function"), "loginEnv" in pi,
  Object.keys(pi.patterns).sort()]));')"
    want='["pi","pi","preassign","job-id",[["SIGTERM",5000],["SIGKILL",0]],["--help"],["--mode","--session-dir","--session-id","--no-approve","--no-mcp","--tools"],["PI_CODING_AGENT_DIR"],["1.3.0"],true,false,["auth","blocked","context","launch","model-not-selected","quota","rate-limit","resume-lost","server"]]'
    [[ "$got" == "$want" ]]
    verdict "1 contract: id/prefix pi, preassigned job-id session, ladder SIGTERM 5 s → SIGKILL (no SIGINT), required flags, home var, every hook (scrub too; no loginEnv: profile env exports prepareHome's env)" $? "got:  $got" "want: $want"
    got="$(CLI="$CLI" node --input-type=module -e "
const { pathToFileURL } = await import('node:url');
const cli = await import(pathToFileURL(process.env.CLI).href);
const a = await cli.loadCoreAdapter('pi');
console.log(a?.id, a?.idPrefix);")"
    [[ "$got" == "pi pi" ]]
    verdict "1 agent-dispatch loads bin/lib/adapters/pi.mjs for harness pi (no 'not available in this version')" $? "got: $got"

    # --- 2. golden argv and env per auth mode and role (the stub records them) ---
    start AGENT_STUB_RECORD="$TEST_ROOT/rec/key-w.json" -- --profile pi-key --role implementer --write --prompt-file "$prompt"
    id1="$ID"
    st="$(outcome "$id1")"
    rec="$TEST_ROOT/rec/key-w.json"
    want="$(jarr --mode json --model zai/glm-5.3 --thinking high --session-dir "$JOBS/$id1/sessions" --session-id "$id1" --no-approve -ne -ns -np --no-mcp --tools read,bash,edit,write,grep,find,ls)"
    got="$(jfield argv <"$rec")"
    [[ "$OUT" == "agent-dispatch: pi-key task started in the background as $id1" && "$id1" == pi-0001 && "$st" == completed/ && "$got" == "$want" ]]
    verdict "2 writer, auth key: pi --mode json --model --thinking --session-dir <job>/sessions --session-id <job id> --no-approve -ne -ns -np --no-mcp --tools read,bash,edit,write,grep,find,ls" $? "out: $OUT st: $st" "got:  $got" "want: $want"
    [[ "$(jfield env.ZAI_API_KEY <"$rec")" == "$ZKEY" && "$(jfield env.PI_CODING_AGENT_DIR <"$rec")" == "$STATE/homes/pi-key/pi" && "$(mode_of "$STATE/homes/pi-key/pi")" == 700 \
        && "$(jfield env.PI_TELEMETRY <"$rec")" == 0 && "$(jfield env.PI_SKIP_VERSION_CHECK <"$rec")" == 1 && "$(jfield env.PI_OFFLINE <"$rec")" == 1 \
        && "$(env_names "$rec" '_(API_)?KEY$|^ANTHROPIC_|^OPENAI_')" == ZAI_API_KEY ]]
    verdict "2 auth key: the stored key only in keyVar (not the caller's ZAI_API_KEY), isolated PI_CODING_AGENT_DIR=homes/<p>/pi (0700), PI_TELEMETRY=0 PI_SKIP_VERSION_CHECK=1 PI_OFFLINE=1, no caller credentials" $? \
        "ZAI_API_KEY=$(jfield env.ZAI_API_KEY <"$rec") PI_CODING_AGENT_DIR=$(jfield env.PI_CODING_AGENT_DIR <"$rec")" "names: $(env_names "$rec" '_(API_)?KEY$|^ANTHROPIC_|^OPENAI_|^PI_')"
    [[ "$(jfield stdin <"$rec")" == "$(cat "$prompt")" && "$(jfield cwd <"$rec")" == "$repo" && "$(jfield argv <"$rec")" != *"$ZKEY"* && "$(jfield argv <"$rec")" != *Implement* ]]
    verdict "2 the prompt reaches pi on stdin (never argv: extra positionals are extra turns), cwd = the workspace root, no key in argv" $? "stdin: $(jfield stdin <"$rec")" "cwd: $(jfield cwd <"$rec")"
    line="$(grep ' start pi-0001: ' "$JOBS/$id1.log")"
    [[ "$line" == *"\"$PI\" \"--mode\" \"json\""* && "$(grep -c 'key in: ZAI_API_KEY' "$JOBS/$id1.log")" -eq 1 ]]
    verdict "2 the job log names the binary and argv, and only the name of the key variable" $? "$line"

    start AGENT_STUB_RECORD="$TEST_ROOT/rec/key-r.json" -- --profile pi-key --role control-review --prompt-file "$prompt"
    st="$(outcome "$ID")"
    want="$(jarr --mode json --model zai/glm-5.3 --thinking high --session-dir "$JOBS/$ID/sessions" --session-id "$ID" --no-approve -ne -ns -np --no-mcp --tools read,grep,find,ls)"
    got="$(jfield argv <"$TEST_ROOT/rec/key-r.json")"
    [[ "$st" == completed/ && "$got" == "$want" ]]
    verdict "2 reviewer (no --write): --tools read,grep,find,ls — no bash, so no git; --no-mcp keeps MCP tools out" $? "st: $st" "got:  $got" "want: $want"

    # pi prefers a credential it stores itself (auth.json) to the key in keyVar [03 §6]: a keyed profile runs only in its
    # isolated home, and only while that home holds no auth.json.
    n="$(/bin/ls "$JOBS" | wc -l | tr -d ' ')"
    : >"$TEST_ROOT/rec/key-user.json"
    run_env AGENT_STUB_RECORD="$TEST_ROOT/rec/key-user.json" -- task --profile pi-key-user --background --prompt-file "$prompt"
    [[ "$RC" -eq 2 && "$OUT" == "" && "$ERR" == "agent-dispatch: profile pi-key-user: a keyed pi profile runs only in its isolated home (the default with a key): in $TEST_ROOT/user-pi a credential pi stored itself (auth.json, /login) would win over ZAI_API_KEY; remove \"home\": \"user\"" \
        && "$(/bin/ls "$JOBS" | wc -l | tr -d ' ')" == "$n" && ! -s "$TEST_ROOT/rec/key-user.json" && ! -d "$STATE/homes/pi-key-user" ]]
    verdict "2 auth key + home user: refused (exit 2, no job, pi never started) — a credential in the user's pi home would win over the key" $? "rc=$RC err: $ERR"
    printf '{}\n' >"$STATE/homes/pi-key/pi/auth.json"
    run_ad task --profile pi-key --background --prompt-file "$prompt"
    ok=$RC
    got="$ERR"
    line="$(/bin/ls "$JOBS" | wc -l | tr -d ' ')"
    rm -f "$STATE/homes/pi-key/pi/auth.json"
    start -- --profile pi-key --prompt-file "$prompt"
    st="$(outcome "$ID")"
    [[ "$ok" -eq 2 && "$got" == "agent-dispatch: profile pi-key: $STATE/homes/pi-key/pi/auth.json exists: a credential stored there (pi /login) wins over ZAI_API_KEY; remove that file (a keyed profile needs no login)" \
        && "$line" == "$n" && "$st" == completed/ ]]
    verdict "2 auth key + an auth.json in the isolated home (a /login there): refused (exit 2, no job) until the file is gone" $? "rc=$ok err: $got" "after rm: $st"
    # A models.json in the isolated home is how a keyed profile reaches a custom endpoint ("apiKey": "$ZAI_API_KEY",
    # [03 §5.3]): the task runs on the key; one whose apiKey is a literal is doctor's pi auth check's to report.
    printf '{}\n' >"$STATE/homes/pi-key/pi/models.json"
    start AGENT_STUB_RECORD="$TEST_ROOT/rec/key-models.json" -- --profile pi-key --prompt-file "$prompt"
    st="$(outcome "$ID")"
    rm -f "$STATE/homes/pi-key/pi/models.json"
    [[ "$st" == completed/ && "$(env_names "$TEST_ROOT/rec/key-models.json" '^ZAI_API_KEY$')" == "ZAI_API_KEY" ]]
    verdict "2 auth key + a models.json in the isolated home (a custom endpoint): runs on the key" $? "status: $st"
    start -u PI_CODING_AGENT_DIR AGENT_STUB_RECORD="$TEST_ROOT/rec/login-unset.json" -- --profile pi-login --prompt-file "$prompt"
    st="$(outcome "$ID")"
    [[ "$st" == completed/ && "$(env_names "$TEST_ROOT/rec/login-unset.json" '^PI_CODING_AGENT_DIR$')" == "" && ! -d "$STATE/homes/pi-login" ]]
    verdict "2 home user with the caller's PI_CODING_AGENT_DIR unset: none in the harness env (pi's default ~/.pi/agent), no isolated home" $? "st: $st"

    start AGENT_STUB_RECORD="$TEST_ROOT/rec/env.json" -- --profile pi-env --prompt-file "$prompt"
    st="$(outcome "$ID")"
    start AGENT_STUB_RECORD="$TEST_ROOT/rec/cmd.json" -- --profile pi-cmd --prompt-file "$prompt"
    got="$(outcome "$ID")"
    [[ "$st" == completed/ && "$got" == completed/ \
        && "$(jfield env.DEEPSEEK_API_KEY <"$TEST_ROOT/rec/env.json")" == env-key-value-5150 && "$(env_names "$TEST_ROOT/rec/env.json" '_KEY$')" == DEEPSEEK_API_KEY \
        && "$(jfield env.OPENROUTER_API_KEY <"$TEST_ROOT/rec/cmd.json")" == cmd-key-value-31337 && "$(env_names "$TEST_ROOT/rec/cmd.json" '_KEY$')" == OPENROUTER_API_KEY \
        && "$(jfield env.PI_CODING_AGENT_DIR <"$TEST_ROOT/rec/env.json")" == "$STATE/homes/pi-env/pi" \
        && "$(jfield argv <"$TEST_ROOT/rec/cmd.json")" == "$(jarr --mode json --model openrouter/qwen/qwen3.8-coder --session-dir "$JOBS/$ID/sessions" --session-id "$ID" --no-approve -ne -ns -np --no-mcp --tools read,grep,find,ls)" ]]
    verdict "2 auth keyEnv / keyCmd: the key in their keyVar (DEEPSEEK_API_KEY / OPENROUTER_API_KEY, trimmed), isolated home, no --thinking without effort" $? "st: $st/$got" "cmd argv: $(jfield argv <"$TEST_ROOT/rec/cmd.json")"

    start AGENT_STUB_RECORD="$TEST_ROOT/rec/login.json" -- --profile pi-login --write --prompt-file "$prompt"
    st="$(outcome "$ID")"
    rec="$TEST_ROOT/rec/login.json"
    want="$(jarr --mode json --model openai/gpt-6-luna --thinking xhigh --session-dir "$JOBS/$ID/sessions" --session-id "$ID" --no-approve -ne -ns -np --no-mcp --tools read,bash,edit,write,grep,find,ls)"
    [[ "$st" == completed/ && "$(jfield argv <"$rec")" == "$want" && "$(env_names "$rec" '_(API_)?KEY$|_TOKEN$|^ANTHROPIC_|^OPENAI_')" == "" && "$(jfield env.PI_CODING_AGENT_DIR <"$rec")" == "$TEST_ROOT/user-pi" ]]
    verdict "2 auth login: pi's own login in the user's home (caller's PI_CODING_AGENT_DIR), no key variable at all, no caller credentials" $? "st: $st argv: $(jfield argv <"$rec")" "names: $(env_names "$rec" '_KEY$|^PI_')"

    start AGENT_STUB_RECORD="$TEST_ROOT/rec/login-iso.json" -- --profile pi-login-iso --prompt-file "$prompt"
    st="$(outcome "$ID")"
    got="$(jfield env.PI_CODING_AGENT_DIR <"$TEST_ROOT/rec/login-iso.json")"
    run_ad profile env pi-login-iso
    # One source of truth (prepareHome's env): 'profile env' prints the very dir the job ran with.
    [[ "$st" == completed/ && "$got" == "$STATE/homes/pi-login-iso/pi" && "$RC" -eq 0 && "$OUT" == "export PI_CODING_AGENT_DIR='$got'" ]]
    verdict "2 auth login + home isolated: PI_CODING_AGENT_DIR=homes/<p>/pi, and 'profile env' prints the same dir the job ran with" $? "st: $st job: $got" "profile env: rc=$RC $OUT $ERR"

    start AGENT_STUB_RECORD="$TEST_ROOT/rec/bare.json" -- --profile pi-bare --prompt-file "$prompt"
    st="$(outcome "$ID")"
    want="$(jarr --mode json --session-dir "$JOBS/$ID/sessions" --session-id "$ID" --no-approve -ne -ns -np --no-mcp --tools read,grep,find,ls)"
    [[ "$st" == completed/ && "$(jfield argv <"$TEST_ROOT/rec/bare.json")" == "$want" ]]
    verdict "2 no model, no effort: no --model / --thinking (pi's own defaults), still --mode json" $? "st: $st argv: $(jfield argv <"$TEST_ROOT/rec/bare.json")"

    start AGENT_STUB_RECORD="$TEST_ROOT/rec/ext.json" -- --profile pi-ext --prompt-file "$prompt"
    st="$(outcome "$ID")"
    want="$(jarr --mode json --model openai/gpt-6-luna --thinking xhigh --session-dir "$JOBS/$ID/sessions" --session-id "$ID" --no-approve -ne -ns -np --no-mcp --tools read,grep,find,ls -e builtin:llama.cpp -e "$EXT")"
    [[ "$st" == completed/ && "$(jfield argv <"$TEST_ROOT/rec/ext.json")" == "$want" ]]
    verdict "2 options.extensions: one -e per extension (builtin:llama.cpp, a path), loaded although -ne" $? "st: $st argv: $(jfield argv <"$TEST_ROOT/rec/ext.json")"
    start -- --profile pi-ext-bad --prompt-file "$prompt"
    st="$(outcome "$ID")"
    [[ "$st" == failed/launch && "$(job "$ID" exitCode)" == 1 ]] && grep -q 'Failed to load extension' "$JOBS/$ID.log"
    verdict "2 a missing extension: pi stops with 'Failed to load extension' (exit 1) → failed/launch" $? "st: $st"

    start AGENT_STUB_RECORD="$TEST_ROOT/rec/native.json" -- --profile pi-native --prompt-file "$prompt"
    st="$(outcome "$ID")"
    want="$(jarr --mode json --model zai/glm-5.3 --thinking high --session-dir "$JOBS/$ID/sessions" --session-id "$ID" --no-approve -ne -ns -np --no-mcp --tools read,grep,find,ls)"
    [[ "$st" == completed/ && "$(jfield argv <"$TEST_ROOT/rec/native.json")" == "$want" && "$(env_names "$TEST_ROOT/rec/native.json" '^PI_|_KEY$|SANDBOX')" == "PI_CODING_AGENT_DIR PI_OFFLINE PI_SKIP_VERSION_CHECK PI_TELEMETRY ZAI_API_KEY" ]]
    verdict "2 sandbox native: pi has no sandbox — the same argv and env as sandbox off" $? "st: $st names: $(env_names "$TEST_ROOT/rec/native.json" '^PI_|_KEY$|SANDBOX')"

    start AGENT_STUB_RECORD="$TEST_ROOT/rec/off0.json" -- --profile pi-offline0 --prompt-file "$prompt"
    st="$(outcome "$ID")"
    [[ "$st" == completed/ && "$(jfield env.PI_OFFLINE <"$TEST_ROOT/rec/off0.json")" == 0 && "$(jfield env.PI_TELEMETRY <"$TEST_ROOT/rec/off0.json")" == 0 ]]
    verdict "2 profile env overrides a default of §3.6 Б (PI_OFFLINE=0); the others stay" $? "st: $st"
    n="$(/bin/ls "$JOBS" | wc -l | tr -d ' ')"
    run_ad task --profile pi-clash-home --background --prompt-file "$prompt"
    ok=$RC
    got="$ERR"
    run_ad task --profile pi-clash-key --background --prompt-file "$prompt"
    [[ "$ok" -eq 2 && "$got" == *"env PI_CODING_AGENT_DIR conflicts with a mandatory setting of the pi adapter"* && "$RC" -eq 2 && "$ERR" == *"env ZAI_API_KEY conflicts with a mandatory setting"* \
        && "$(/bin/ls "$JOBS" | wc -l | tr -d ' ')" == "$n" ]]
    verdict "2 profile env cannot touch the isolated PI_CODING_AGENT_DIR or the key variable (exit 2, no job)" $? "home: rc=$ok $got" "key: rc=$RC $ERR"

    start AGENT_STUB_RECORD="$TEST_ROOT/rec/wrap.json" -- --profile pi-wrap --prompt-file "$prompt"
    st="$(outcome "$ID")"
    [[ "$st" == completed/ && "$(jfield env.WRAPPED <"$TEST_ROOT/rec/wrap.json")" == yes && "$(jfield argv <"$TEST_ROOT/rec/wrap.json")" == *'"--mode","json"'* ]] && grep -q "start $ID: \"env\" \"WRAPPED=yes\" \"$PI\" \"--mode\"" "$JOBS/$ID.log"
    verdict "2 wrap: the core runs <wrap> pi … unchanged (the prefix before the binary)" $? "st: $st"

    # --- 3. sessions and resume (spec §3.6 A12) ---
    dir="$JOBS/$id1/sessions"
    got="$(head -1 "$dir"/*_"$id1".jsonl 2>/dev/null)"
    [[ "$(job "$id1" sessionId)" == "$id1" && "$(jfield id <<<"$got")" == "$id1" && "$(jfield cwd <<<"$got")" == "$repo" && "$(jfield meta.sessionDir <<<"$(ad status "$id1" --json | jfield job)")" == "$dir" ]] \
        && grep -q "No project session found with id '$id1'" "$JOBS/$id1.log"
    verdict "3 a fresh job: session id = job id, the session file <job>/sessions/<time>_<id>.jsonl (header id, cwd), its dir in meta; pi's 'No project session found' warning does not fail it" $? "header: $got"
    start AGENT_STUB_MODE=context-echo AGENT_STUB_RECORD="$TEST_ROOT/rec/resume1.json" -- --profile pi-key --write --resume-task "$id1" --prompt-file "$prompt"
    id2="$ID"
    st="$(outcome "$id2")"
    run_ad result "$id2"
    want="$(jarr --mode json --model zai/glm-5.3 --thinking high --session-dir "$dir" --session-id "$id1" --no-approve -ne -ns -np --no-mcp --tools read,bash,edit,write,grep,find,ls)"
    # prior = the entries already in the session file (user, assistant tool turn, tool result, final assistant…);
    # stdin = the trimmed prompt's length (37).
    [[ "$st" == completed/ && "$(jfield argv <"$TEST_ROOT/rec/resume1.json")" == "$want" && "$RC" -eq 0 && "$OUT" == "DONE"$'\n'"session $id1 resumed=true prior=3 stdin=37" \
        && "$(job "$id2" sessionId)" == "$id1" && "$(job "$id2" resumeOf)" == "$id1" ]] && ! grep -q 'No project session found' "$JOBS/$id2.log"
    verdict "3 --resume-task: the same --session-dir and --session-id from the same cwd; pi reopens the session (no warning), the job completes" $? "st: $st result: $OUT" "argv: $(jfield argv <"$TEST_ROOT/rec/resume1.json")"
    start AGENT_STUB_MODE=context-echo AGENT_STUB_STDERR_LINES=250 AGENT_STUB_RECORD="$TEST_ROOT/rec/resume2.json" -- --profile pi-key --resume-task "$id2" --prompt-file "$prompt"
    st="$(outcome "$ID")"
    run_ad result "$ID"
    [[ "$st" == completed/ && "$(jfield argv <"$TEST_ROOT/rec/resume2.json")" == *"\"--session-dir\",\"$dir\",\"--session-id\",\"$id1\""* && "$OUT" == *"resumed=true prior=6"* \
        && "$(job "$ID" meta.sessionFilesBefore)" == "[\"$(basename "$dir"/*_"$id1".jsonl)\"]" && "$(/bin/ls "$dir" | wc -l | tr -d ' ')" == 1 ]]
    verdict "3 a resumed job resumes again: the chain keeps the first job's session dir and id; its meta lists the session file it started with, no new one appeared (stderr chatter or not)" $? "st: $st result: $OUT" "before: $(job "$ID" meta.sessionFilesBefore)"
    local chain_last="$ID"

    start AGENT_STUB_MODE=lose-session -- --profile pi-key --resume-task "$chain_last" --prompt-file "$prompt"
    st="$(outcome "$ID")"
    run_ad result "$ID"
    [[ "$st" == failed/resume-lost && "$RC" -eq 1 && "$ERR" == *"errorClass=resume-lost"* && "$(job "$ID" errorText)" == "No project session found with id '$id1'; creating a new session with that id." ]]
    verdict "3 a resume where pi still warns 'No project session found with id …' (it answered in a new session): failed/resume-lost, result exit 1" $? "st: $st err: $(head -1 <<<"$ERR")"
    # The warning comes at startup; 250 lines of extension chatter push it out of the core's 200-line stderr tail. The
    # new session file pi created still tells.
    start AGENT_STUB_MODE=lose-session AGENT_STUB_STDERR_LINES=250 -- --profile pi-key --resume-task "$chain_last" --prompt-file "$prompt"
    st="$(outcome "$ID")"
    got="$(job "$ID" errorText)"
    [[ "$st" == failed/resume-lost && "$got" == "pi started a new session file "*"_$id1.jsonl in $dir instead of resuming session $id1" && "$(/bin/ls "$dir" | wc -l | tr -d ' ')" == 3 \
        && "$(grep -c '\[extension\] chatter line' "$JOBS/$ID.log")" -ge 250 ]] && grep -q "No project session found with id '$id1'" "$JOBS/$ID.log"
    verdict "3 a lost resume whose warning fell out of the 200-line stderr tail: still failed/resume-lost, from the new session file pi created" $? "st: $st errorText: $got"

    start -- --profile pi-key --prompt-file "$prompt"
    local fresh="$ID"
    st="$(outcome "$fresh")"
    mv "$JOBS/$fresh/sessions" "$JOBS/$fresh/sessions.gone"
    n="$(/bin/ls "$JOBS" | wc -l | tr -d ' ')"
    run_ad task --profile pi-key --background --resume-task "$fresh" --prompt-file "$prompt"
    [[ "$st" == completed/ && "$RC" -eq 2 && "$ERR" == "agent-dispatch: cannot resume $fresh on pi-key: no pi session file with id $fresh for $repo in $JOBS/$fresh/sessions; pi would start a new session; dispatch --fresh" \
        && "$(/bin/ls "$JOBS" | wc -l | tr -d ' ')" == "$n" ]]
    verdict "3 resume refused before launch when the session file is gone (exit 2, 'dispatch --fresh', no job)" $? "rc=$RC err: $ERR"
    mv "$JOBS/$fresh/sessions.gone" "$JOBS/$fresh/sessions"
    local sfile
    sfile="$(/bin/ls "$JOBS/$fresh/sessions/"*.jsonl)"
    node -e 'const fs = require("node:fs"); const f = process.argv[1]; const lines = fs.readFileSync(f, "utf8").split("\n");
const h = JSON.parse(lines[0]); h.cwd = "/somewhere/else"; lines[0] = JSON.stringify(h); fs.writeFileSync(f, lines.join("\n"));' -- "$sfile"
    run_ad task --profile pi-key --background --resume-task "$fresh" --prompt-file "$prompt"
    [[ "$RC" -eq 2 && "$ERR" == *"no pi session file with id $fresh for $repo"* ]]
    verdict "3 resume refused when the session file belongs to another cwd (pi filters a --session-dir by the header cwd)" $? "rc=$RC err: $ERR"
    run_ad task --profile pi-key-user --background --resume-task "$id1" --prompt-file "$prompt"
    [[ "$RC" -eq 2 && "$ERR" == *"ran on profile pi-key, not pi-key-user"* ]]
    verdict "3 a pi job resumes only on its own profile (exit 2)" $? "rc=$RC err: $ERR"

    start AGENT_STUB_MODE=exit0-error AGENT_STUB_MESSAGE="something odd happened" -- --profile pi-key --prompt-file "$prompt"
    st="$(outcome "$ID")"
    [[ "$st" == failed/malformed ]] && grep -q 'No project session found' "$JOBS/$ID.log"
    verdict "3 a fresh job that fails is never resume-lost, although pi's stderr carries the warning" $? "st: $st"

    # --- 4. the outcome from the events: pi exits 0 on provider errors (spec §3.6 A9) ---
    start AGENT_STUB_RECORD="$TEST_ROOT/rec/ok.json" -- --profile pi-key --prompt-file "$prompt"
    st="$(outcome "$ID")"
    run_ad result "$ID"
    got="$(ad status "$ID" --json | jfield job)"
    [[ "$st" == completed/ && "$RC" -eq 0 && "$OUT" == $'DONE\nstub finished' && "$(jfield exitCode <<<"$got")" == 0 && "$(jfield reportedModel <<<"$got")" == zai/glm-5.3 \
        && "$(jfield usage <<<"$got")" == '{"input":2400,"output":160,"cacheRead":600,"cacheWrite":0,"totalTokens":3160,"costUsd":0.00326}' && "$(jfield meta.stopReason <<<"$got")" == stop ]]
    verdict "4 completed: the text of the last assistant message_end (not the tool turn's, not thinking), usage and cost summed, model from the message" $? "st: $st result: $OUT" "usage: $(jfield usage <<<"$got") model: $(jfield reportedModel <<<"$got")"

    # Every mode below runs in parallel on one profile; each pair is <mode> <expected status/class> <exit code>.
    local -a cases=(
        exit0-error failed/quota 0
        auth-401 failed/auth 0
        quota failed/quota 0
        rate-limit failed/rate-limit 0
        server failed/server 0
        network failed/server 0
        context failed/context 0
        auth failed/auth 1
        model-not-found failed/model-not-selected 1
        unknown-provider failed/model-not-selected 1
        error-then-recover completed/ 0
        late-events completed/ 0
        tool-blocked completed/ 0
        stdin-wait completed/ 0
        truncated failed/malformed 0
        ends-on-tool failed/malformed 0
        no-settle failed/malformed 0
        aborted failed/malformed 0
        malformed failed/malformed 0
        crash failed/crash ''
        custom-model failed/rate-limit 0
    )
    local -a ids=()
    local i
    for ((i = 0; i < ${#cases[@]}; i += 3)); do
        start AGENT_STUB_MODE="${cases[i]}" AGENT_STUB_MESSAGE="insufficient_quota: the account is out of credit" -- --profile pi-many --prompt-file "$prompt"
        ids+=("$ID")
    done
    for ((i = 0; i < ${#cases[@]}; i += 3)); do
        id1="${ids[i / 3]}"
        st="$(outcome "$id1")"
        got="$(job "$id1" exitCode)"
        [[ -n "$id1" && "$st" == "${cases[i + 1]}" && "$got" == "${cases[i + 2]}" ]]
        verdict "4 mode ${cases[i]}: ${cases[i + 1]} (pi exit ${cases[i + 2]:-signal})" $? "id: $id1 st: $st exit: $got errorText: $(job "$id1" errorText)"
    done
    run_ad result "${ids[11]}"
    ok="$OUT"
    run_ad result "${ids[12]}"
    got="$OUT"
    run_ad result "${ids[13]}"
    [[ "$ok" == $'DONE\nwith late events' && "$got" == $'BLOCKED\nthe bash call was refused' && "$OUT" == $'DONE\nstdin read to EOF: 37 chars' ]]
    verdict "4 late events after agent_settled change nothing; a refused tool is the model's to report (no blocked class); stdin is read to EOF" $? "late: $ok" "blocked: $got" "stdin: $OUT"
    [[ "$(job "${ids[3]}" errorText)" == "429 Too Many Requests: rate limit reached for requests" && "$(job "${ids[1]}" errorText)" == *"Invalid API key provided"* ]]
    verdict "4 errorText is pi's errorMessage of the final assistant message (after its own retries)" $? "rate: $(job "${ids[3]}" errorText)"

    # --- 5. cancel: SIGTERM, 5 s, SIGKILL — never SIGINT (spec §3.6 A8) ---
    start AGENT_STUB_MODE=pi-sigterm AGENT_STUB_PIDS="$TEST_ROOT/pids.term" AGENT_STUB_SIGNALS="$TEST_ROOT/sig.term" AGENT_STUB_RECORD="$TEST_ROOT/rec/term.json" -- --profile pi-many --prompt-file "$prompt"
    id1="$ID"
    wait_lines "$TEST_ROOT/pids.term" 1
    wait_file "$TEST_ROOT/rec/term.json"
    stub_pid="$(jfield pid <"$TEST_ROOT/rec/term.json")"
    child="$(head -1 "$TEST_ROOT/pids.term")"
    t0="$(now_ms)"
    run_ad cancel "$id1"
    t1="$(now_ms)"
    got="$(cut -d' ' -f1 "$TEST_ROOT/sig.term" | tr '\n' ' ')"
    [[ "$OUT" == "cancelled $id1" && "$got" == "SIGTERM exit " && "$(job "$id1" status)" == cancelled && $((t1 - t0)) -lt 4500 \
        && "$(job "$id1" cancelLadder)" == '[["SIGTERM",5000],["SIGKILL",0]]' ]] && gone "$stub_pid" "$child" && ! grep -q SIGINT "$JOBS/$id1.log" && grep -q 'cancel: SIGTERM to groups' "$JOBS/$id1.log"
    verdict "5 cancel: SIGTERM only; pi kills its bash groups and exits 143 well before the 5 s step; no SIGINT ever" $? "out: $OUT signals: $got took: $((t1 - t0)) ms" "$(grep cancel "$JOBS/$id1.log")"

    start AGENT_STUB_MODE=term-ignore AGENT_STUB_SIGNALS="$TEST_ROOT/sig.ignore" AGENT_STUB_RECORD="$TEST_ROOT/rec/ignore.json" -- --profile pi-many --prompt-file "$prompt"
    id1="$ID"
    wait_file "$TEST_ROOT/rec/ignore.json"
    stub_pid="$(jfield pid <"$TEST_ROOT/rec/ignore.json")"
    run_ad cancel "$id1"
    t1="$(now_ms)"
    tterm="$(cut -d' ' -f2 "$TEST_ROOT/sig.ignore" | head -1)"
    got="$(cut -d' ' -f1 "$TEST_ROOT/sig.ignore" | tr '\n' ' ')"
    [[ "$OUT" == "cancelled $id1" && "$got" == "SIGTERM " && -n "$tterm" && $((t1 - tterm)) -ge 4500 && $((t1 - tterm)) -lt 15000 && "$(job "$id1" status)" == cancelled ]] \
        && gone "$stub_pid" && grep -q 'cancel: SIGKILL to groups' "$JOBS/$id1.log" && ! grep -q SIGINT "$JOBS/$id1.log"
    verdict "5 a pi that ignores SIGTERM gets SIGKILL after the 5 s wait (observed by the stub: one SIGTERM, then death ≥ 4.5 s later)" $? "signals: $got after SIGTERM: $((t1 - ${tterm:-0})) ms" "$(grep cancel "$JOBS/$id1.log")"

    start AGENT_STUB_MODE=hang -- --profile pi-fast --prompt-file "$prompt"
    st="$(outcome "$ID")"
    [[ "$st" == failed/timeout ]] && grep -q 'timeout after 1200 ms: SIGTERM, 5000 ms → SIGKILL' "$JOBS/$ID.log"
    verdict "5 timeoutMin: the same ladder stops pi; failed/timeout" $? "st: $st" "$(grep timeout "$JOBS/$ID.log")"

    # --- 6. secrets never in argv, logs, records, results or pi's own session files (spec §3.5, §3.6 A11) ---
    # pi writes each message into its session file as it is (<session dir>/<time>_<id>.jsonl), beyond the core's stream
    # redaction; after every run the core writes back what the adapter's scrub() returns: those files through the
    # job's redactor. So outside keys/zai nothing under the data root may hold the key, on any path.
    # leaks_of <id> — the files under the data root (keys/ aside) that hold the key, once the job's runner finished.
    leaks_of() {
        local i=0
        while ((i < 50)) && ! grep -q "finish $1: " "$JOBS/$1.log" 2>/dev/null; do
            sleep 0.2
            i=$((i + 1))
        done
        grep -rlF "$ZKEY" "$STATE" | grep -v "^$STATE/keys/" | tr '\n' ' '
    }
    start AGENT_STUB_MODE=leak-secret AGENT_STUB_SECRET_VAR=ZAI_API_KEY AGENT_STUB_RECORD="$TEST_ROOT/rec/leak.json" -- --profile pi-key --prompt-file "$prompt"
    local leak="$ID"
    st="$(outcome "$leak")"
    run_ad result "$leak"
    got="$(leaks_of "$leak")"
    rec="$(/bin/ls "$JOBS/$leak/sessions/"*.jsonl)"
    [[ "$st" == completed/ && "$OUT" == $'DONE\nkey=<redacted>' && -z "$got" && ! -e "$JOBS/$leak/secret" && "$(jfield argv <"$TEST_ROOT/rec/leak.json")" != *"$ZKEY"* \
        && "$(grep -c 'key=<redacted>' "$rec")" -ge 1 && "$(mode_of "$rec")" == 644 ]] && grep -q 'leaked: <redacted>' "$JOBS/$leak.log" \
        && node -e 'for (const l of require("node:fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean)) JSON.parse(l);' -- "$rec"
    # 644: the mode pi's session file was created with (umask 022 here), kept by the rewrite.
    verdict "6 a key the model prints is redacted everywhere outside keys/zai: log, record, result and pi's own session file (<redacted>, valid JSONL, its mode kept); the handoff file is gone" $? "st: $st result: $OUT mode: $(mode_of "$rec")" "files with the key: $got"
    start AGENT_STUB_MODE=context-echo -- --profile pi-key --resume-task "$leak" --prompt-file "$prompt"
    st="$(outcome "$ID")"
    run_ad result "$ID"
    [[ "$st" == completed/ && "$OUT" == "DONE"$'\n'"session $leak resumed=true prior=3 stdin=37" ]]
    verdict "6 the redacted session still resumes (pi reads the header's id and cwd, which redaction leaves alone)" $? "st: $st result: $OUT"
    start AGENT_STUB_MODE=leak-error AGENT_STUB_SECRET_VAR=ZAI_API_KEY -- --profile pi-key --prompt-file "$prompt"
    st="$(outcome "$ID")"
    got="$(leaks_of "$ID")"
    [[ "$st" == failed/server && -z "$got" ]] && grep -qF 'ZAI_API_KEY=<redacted>' "$JOBS/$ID/sessions/"*.jsonl
    verdict "6 a failed job: the key a bash tool printed (a toolResult entry) is redacted in its session file too" $? "st: $st files with the key: $got"
    start AGENT_STUB_MODE=leak-hang AGENT_STUB_SECRET_VAR=ZAI_API_KEY AGENT_STUB_RECORD="$TEST_ROOT/rec/leak-hang.json" -- --profile pi-key --prompt-file "$prompt"
    id1="$ID"
    wait_file "$TEST_ROOT/rec/leak-hang.json"
    i=0
    while ((i < 50)) && ! grep -qF "$ZKEY" "$JOBS/$id1/sessions/"*.jsonl 2>/dev/null; do
        sleep 0.2
        i=$((i + 1))
    done
    run_ad cancel "$id1"
    got="$(leaks_of "$id1")"
    [[ "$OUT" == "cancelled $id1" && "$(job "$id1" status)" == cancelled && -z "$got" ]] && grep -qF 'ZAI_API_KEY=<redacted>' "$JOBS/$id1/sessions/"*.jsonl
    verdict "6 a cancelled job: its session file is redacted once the runner stopped pi" $? "out: $OUT files with the key: $got"
    start AGENT_STUB_MODE=leak-hang AGENT_STUB_SECRET_VAR=ZAI_API_KEY -- --profile pi-key-fast --prompt-file "$prompt"
    st="$(outcome "$ID")"
    got="$(leaks_of "$ID")"
    [[ "$st" == failed/timeout && -z "$got" ]] && grep -qF 'ZAI_API_KEY=<redacted>' "$JOBS/$ID/sessions/"*.jsonl
    verdict "6 a timed-out job: its session file is redacted too" $? "st: $st files with the key: $got"

    # --- 7. two read-only jobs at once: distinct sessions ---
    start AGENT_STUB_MODE=slow AGENT_STUB_DELAY_MS=600 AGENT_STUB_RECORD="$TEST_ROOT/rec/par1.json" -- --profile pi-many --prompt-file "$prompt"
    id1="$ID"
    start AGENT_STUB_MODE=slow AGENT_STUB_DELAY_MS=600 AGENT_STUB_RECORD="$TEST_ROOT/rec/par2.json" -- --profile pi-many --prompt-file "$prompt"
    id2="$ID"
    st="$(outcome "$id1") $(outcome "$id2")"
    [[ "$st" == "completed/ completed/" && "$id1" != "$id2" && "$(jfield argv <"$TEST_ROOT/rec/par1.json")" == *"\"--session-id\",\"$id1\""* && "$(jfield argv <"$TEST_ROOT/rec/par2.json")" == *"\"--session-id\",\"$id2\""* ]]
    verdict "7 parallel read-only jobs run with their own --session-id and session dir (never --continue)" $? "st: $st ids: $id1 $id2"

    # --- 8. doctor (no model call) and the probe ---
    export AGENT_STUB_AUTH_LOG="$TEST_ROOT/auth-all.log"
    run_env AGENT_STUB_AUTH_LOG="$TEST_ROOT/auth.log" -- doctor --profile pi-key
    [[ "$RC" -eq 0 && "$OUT" == *"ok harness pi-key: $PI 1.3.0"* && "$OUT" == *"ok key pi-key: zai in $STATE/keys/zai (mode 0600)"* \
        && "$OUT" == *"ok env pi-key: no conflict with the mandatory settings (2 names)"* \
        && "$OUT" == *"ok pi-auth pi-key: pi holds no credential of its own for zai in $STATE/homes/pi-key/pi; the key goes in through ZAI_API_KEY"* \
        && "$(tail -1 <<<"$OUT")" == "doctor: ok" && "$OUT" != *"$ZKEY"* ]]
    verdict "8 doctor --profile <keyed pi>: harness and version, key, env names, pi auth check (nothing stored overrides the key)" $? "rc=$RC" "$OUT"
    got="$(tail -1 "$TEST_ROOT/auth.log")"
    [[ "$(jfield argv <<<"$got")" == '["check","--provider","zai","--json"]' && "$(jfield agentDir <<<"$got")" == "$STATE/homes/pi-key/pi" && "$(jfield keyVars <<<"$got")" == '[]' ]]
    verdict "8 the auth check runs 'pi auth check --provider zai --json' in the profile's home, without the key in its environment" $? "$got"
    : >"$TEST_ROOT/auth.log"
    run_env AGENT_STUB_AUTH=ready AGENT_STUB_AUTH_LOG="$TEST_ROOT/auth.log" -- doctor --profile pi-key-user
    ok=$RC
    got="$OUT"
    printf '{}\n' >"$STATE/homes/pi-key/pi/auth.json"
    run_env AGENT_STUB_AUTH=not_ready AGENT_STUB_AUTH_LOG="$TEST_ROOT/auth.log" -- doctor --profile pi-key
    rm -f "$STATE/homes/pi-key/pi/auth.json"
    [[ "$ok" -eq 1 && "$got" == *"ok env pi-key-user: no conflict"* \
        && "$got" == *"FAIL pi-auth pi-key-user: a keyed pi profile runs only in its isolated home (the default with a key): in $TEST_ROOT/user-pi a credential pi stored itself (auth.json, /login) would win over ZAI_API_KEY; remove \"home\": \"user\"; task refuses the profile (exit 2)"* \
        && "$RC" -eq 1 && "$OUT" == *"FAIL pi-auth pi-key: $STATE/homes/pi-key/pi/auth.json exists: a credential stored there (pi /login) wins over ZAI_API_KEY; remove that file (a keyed profile needs no login); task refuses the profile (exit 2)"* \
        && ! -s "$TEST_ROOT/auth.log" ]]
    verdict "8 doctor FAILs a keyed profile that task refuses — home user, an auth.json in its isolated home — without running pi" $? "home user rc=$ok: $(grep -E 'pi-auth|env' <<<"$got")" "auth.json rc=$RC: $(grep pi-auth <<<"$OUT")"
    # A models.json there is not refused: pi auth check decides — not ready (its apiKey is `$ZAI_API_KEY`, absent from
    # doctor's env) is ok, ready (a literal key of its own) is the FAIL below.
    printf '{}\n' >"$STATE/homes/pi-key/pi/models.json"
    : >"$TEST_ROOT/auth.log"
    run_env AGENT_STUB_AUTH=not_ready AGENT_STUB_AUTH_LOG="$TEST_ROOT/auth.log" -- doctor --profile pi-key
    rm -f "$STATE/homes/pi-key/pi/models.json"
    [[ "$OUT" == *"ok pi-auth pi-key: pi holds no credential of its own for zai"* && "$OUT" != *"models.json exists"* && -s "$TEST_ROOT/auth.log" ]]
    verdict "8 doctor on a keyed profile whose isolated home holds a models.json: pi auth check runs and decides (not ready → ok)" $? "rc=$RC: $(grep pi-auth <<<"$OUT")"
    run_env AGENT_STUB_AUTH=ready -- doctor --profile pi-key
    ok=$RC
    got="$OUT"
    run_env AGENT_STUB_AUTH=invalid -- doctor --profile pi-key
    [[ "$ok" -eq 1 && "$got" == *"FAIL pi-auth pi-key: pi already holds a credential for zai in $STATE/homes/pi-key/pi (api_key); pi prefers it to the key in ZAI_API_KEY, so the key from agent-dispatch is not used — remove it from $STATE/homes/pi-key/pi"$'\n'* \
        && "$RC" -eq 1 && "$OUT" == *"FAIL pi-auth pi-key: pi holds an invalid credential for zai"* ]]
    verdict "8 a credential pi reports for a keyed profile (auth check ready or invalid) overrides our key: FAIL" $? "ready rc=$ok: $(grep pi-auth <<<"$got")" "invalid rc=$RC: $(grep pi-auth <<<"$OUT")"
    run_env AGENT_STUB_AUTH=ready -- doctor --profile pi-login
    ok=$RC
    got="$OUT"
    run_env AGENT_STUB_AUTH=not_ready -- doctor --profile pi-login
    [[ "$ok" -eq 0 && "$got" == *"ok pi-auth pi-login: pi auth check --provider openai: ready (api_key) in $TEST_ROOT/user-pi"* && "$got" == *"ok auth pi-login: login: the pi login"* \
        && "$RC" -eq 1 && "$OUT" == *"FAIL pi-auth pi-login: pi holds no credential for openai in $TEST_ROOT/user-pi; the user logs in: pi, then /login openai"* ]]
    verdict "8 auth login: pi auth check ready → ok; not_ready → FAIL with the /login hint" $? "ready rc=$ok: $(grep pi-auth <<<"$got")" "not ready rc=$RC: $(grep pi-auth <<<"$OUT")"
    rm -rf "$STATE/homes/pi-login-iso"
    : >"$TEST_ROOT/auth.log"
    run_env AGENT_STUB_AUTH=ready AGENT_STUB_AUTH_LOG="$TEST_ROOT/auth.log" -- doctor --profile pi-login-iso
    [[ "$RC" -eq 1 && "$OUT" == *"FAIL pi-auth pi-login-iso: the isolated home $STATE/homes/pi-login-iso/pi does not exist yet"*"the user logs in: agent-dispatch profile env pi-login-iso -- pi, then /login openai"* && ! -s "$TEST_ROOT/auth.log" ]]
    verdict "8 a login profile with a missing isolated home: FAIL with the 'profile env P -- pi' hint (no eval), pi not even run" $? "rc=$RC $(grep pi-auth <<<"$OUT")"
    run_ad doctor --profile pi-fdrg
    ok=$RC
    got="$OUT"
    run_ad doctor --profile pi-nofdrg
    [[ "$got" == *"ok pi-tools pi-fdrg: fd and rg are on PATH"* && "$OUT" == *"WARN pi-tools pi-nofdrg: fd and rg not on PATH: pi's find and grep tool fails under PI_OFFLINE=1"* ]]
    verdict "8 doctor checks fd and rg on the harness PATH (WARN when missing: PI_OFFLINE=1 stops the download)" $? "$(grep pi-tools <<<"$got")" "$(grep pi-tools <<<"$OUT")"
    run_env AGENT_STUB_AUTH=ready -- doctor --profile pi-ext
    ok=$RC
    got="$OUT"
    run_env AGENT_STUB_AUTH=ready -- doctor --profile pi-ext-bad
    line="$OUT"
    n=$RC
    run_env AGENT_STUB_AUTH=ready -- doctor --profile pi-ext-rel
    [[ "$ok" -eq 0 && "$got" == *"ok pi-extension pi-ext: -e builtin:llama.cpp -e $EXT"* && "$n" -eq 1 && "$line" == *"FAIL pi-extension pi-ext-bad: $TEST_ROOT/ext/missing.ts does not exist"* \
        && "$RC" -eq 0 && "$OUT" == *"WARN pi-extension pi-ext-rel: ext/provider.ts is not checked"* ]]
    verdict "8 doctor checks options.extensions: present → ok, a missing absolute path → FAIL, a relative one → WARN" $? "rc: $ok $n $RC" "$(grep -h extension <<<"$got"$'\n'"$line"$'\n'"$OUT")"
    run_env AGENT_STUB_AUTH=ready -- doctor --profile pi-ext-typo
    ok=$RC
    got="$OUT"
    start -- --profile pi-ext-typo --prompt-file "$prompt"
    st="$(outcome "$ID")"
    [[ "$ok" -eq 0 && "$got" == *"WARN pi-extension pi-ext-typo: builtin:llamacpp is not one of pi's built-in extensions (builtin:mcp, builtin:llama.cpp, builtin:codemode, builtin:tool-search); pi would stop with \"Failed to load extension\""* \
        && "$got" != *"ok pi-extension"* && "$st" == failed/launch ]] && grep -q 'Failed to load extension "builtin:llamacpp": unknown built-in extension' "$JOBS/$ID.log"
    verdict "8 an unknown builtin: extension (a typo) → WARN naming pi's built-in set; the task stops with 'Failed to load extension' (failed/launch, the stub reads the same set)" $? "doctor rc=$ok: $(grep extension <<<"$got")" "task: $st"
    run_ad doctor --profile pi-native
    [[ "$OUT" == *'WARN sandbox pi-native: pi has no sandbox of its own; "sandbox": "native" does nothing — use "wrap"'* ]]
    verdict "8 sandbox native on pi: doctor says it does nothing and points at wrap" $? "$(grep sandbox <<<"$OUT")"
    run_ad doctor --profile pi-clash-home
    [[ "$RC" -eq 1 && "$OUT" == *"FAIL env pi-clash-home: profile env PI_CODING_AGENT_DIR conflicts with a mandatory setting of the pi adapter"* ]]
    verdict "8 doctor: profile env on a mandatory name is FAIL" $? "$(grep 'env pi' <<<"$OUT")"
    run_env AGENT_STUB_VERSION=1.4.0 -- doctor --profile pi-login
    [[ "$OUT" == *"WARN version pi-login: pi 1.4.0 was not checked; checked: 1.3.0"* && "$OUT" == *"ok harness pi-login: $PI 1.4.0"* ]]
    verdict "8 another pi version: one WARN line, never a refusal" $? "$(grep -E 'version|harness' <<<"$OUT")"
    run_env AGENT_STUB_HELP_DROP=--session-id -- doctor --profile pi-drop
    ok=$RC
    got="$OUT"
    start AGENT_STUB_HELP_DROP=--session-id -- --profile pi-drop --prompt-file "$prompt"
    st="$(outcome "$ID")"
    [[ "$ok" -eq 1 && "$got" == *"FAIL harness pi-drop: $TEST_ROOT/bin/pi-drop 1.3.0: \`--help\` does not list the required flag(s) --session-id"* && "$st" == failed/launch ]]
    verdict "8 a pi whose --help lacks a required flag: doctor FAIL, task failed/launch" $? "doctor rc=$ok: $(grep harness <<<"$got")" "task: $st"
    run_ad doctor --profile pi-nobin
    ok=$RC
    got="$OUT"
    start -- --profile pi-nobin --prompt-file "$prompt"
    st="$(outcome "$ID")"
    [[ "$ok" -eq 1 && "$got" == *"FAIL harness pi-nobin: pi not found: $TEST_ROOT/bin/no-such-pi; install it: npm i -g --ignore-scripts @earendil-works/pi-coding-agent@1.3.0"* && "$st" == failed/launch ]]
    verdict "8 no pi binary: doctor FAIL with the install line, task failed/launch" $? "doctor: $(grep harness <<<"$got")" "task: $st"
    # Every pi auth call any doctor run above made (AGENT_STUB_AUTH_LOG exported before section 8, except where a
    # check pointed it elsewhere): all of them `auth check`, none with a key variable in its environment.
    got="$(node -e 'const lines = require("node:fs").readFileSync(process.argv[1], "utf8").trim().split("\n").map((l) => JSON.parse(l));
console.log(lines.length, lines.filter((l) => l.argv[0] !== "check" || l.keyVars.length > 0).length);' -- "$TEST_ROOT/auth-all.log")"
    [[ "${got% *}" -ge 8 && "${got#* }" == 0 ]]
    verdict "8 doctor only ever runs 'pi auth check' without a key (never 'auth print-api-key' / 'print-bearer-token', which print secrets)" $? "calls, bad: $got"

    run_env AGENT_STUB_RESPONSE=PONG AGENT_STUB_RECORD="$TEST_ROOT/rec/probe.json" -- doctor --profile pi-key --probe
    rec="$TEST_ROOT/rec/probe.json"
    want="$(jarr --mode json --model zai/glm-5.3 --thinking high --no-session --no-approve -ne -ns -np -nc --no-mcp -nt)"
    [[ "$RC" -eq 0 && "$(tail -1 <<<"$OUT")" == "ok probe pi-key: PONG in "*" s (model zai/glm-5.3)" && "$(jfield argv <"$rec")" == "$want" && "$(jfield env.ZAI_API_KEY <"$rec")" == "$ZKEY" \
        && "$(jfield stdin <"$rec")" == "Reply with exactly: PONG" && ! -e "$STATE/probe/$(basename "$(jfield cwd <"$rec")")" ]]
    verdict "8 doctor --probe: one PONG turn — --no-session, -nc, no tools (-nt), the profile model and effort, the key in keyVar; its scratch dir removed" $? "rc=$RC $(tail -1 <<<"$OUT")" "argv: $(jfield argv <"$rec")"
    run_env AGENT_STUB_MODE=quota -- doctor --profile pi-key --probe
    [[ "$RC" -eq 1 && "$(tail -1 <<<"$OUT")" == "FAIL probe pi-key: failed/quota: 429 "*insufficient_quota* ]]
    verdict "8 a failed probe is classified from the events like a job" $? "rc=$RC $(tail -1 <<<"$OUT")"
    rm -f "$TEST_ROOT/rec/probe-user.json"
    run_env AGENT_STUB_RESPONSE=PONG AGENT_STUB_RECORD="$TEST_ROOT/rec/probe-user.json" -- doctor --profile pi-key-user --probe
    # doctor stops at the FAIL row; probe() itself refuses too (section 9).
    [[ "$RC" -eq 1 && "$OUT" == *"FAIL pi-auth pi-key-user: a keyed pi profile runs only in its isolated home"* && "$OUT" != *"ok probe"* && ! -e "$TEST_ROOT/rec/probe-user.json" ]]
    verdict "8 doctor --probe on a keyed profile task refuses: FAIL, no PONG from a credential pi holds itself, pi not started" $? "rc=$RC out: $(tail -2 <<<"$OUT") err: $ERR"

    # --- 9. the pure hooks, called directly ---
    got="$(pi_js 'const ev = [
  { type: "session", version: 3, id: "pi-0007", cwd: "/w" },
  { type: "message_end", message: { role: "user", content: [{ type: "text", text: "USER PROMPT" }] } },
  { type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "first" }, { type: "toolCall", id: "1", name: "read" }], stopReason: "toolUse",
    usage: { input: 10, output: 2, cacheRead: 1, cacheWrite: 0, totalTokens: 13, cost: { total: 0.001 } }, provider: "zai", model: "glm-5.3" } },
  { type: "compaction_end", result: { usage: { input: 5, output: 1, totalTokens: 6, cost: { total: 0.0005 } } } },
  { type: "message_update", message: {}, usage: { input: 999 } },
  { type: "message_end", message: { role: "assistant", content: [{ type: "thinking", thinking: "hmm" }, { type: "text", text: "DONE" }, { type: "text", text: "second block" }],
    stopReason: "stop", usage: { input: 20, output: 4, cacheRead: 0, cacheWrite: 2, totalTokens: 26, cost: { total: 0.002 } }, provider: "zai", model: "glm-5.3" } },
  { type: "agent_settled", aborted: false },
];
const r = pi.reduce({ events: ev });
const print = pi.reduce({ stdout: "DONE\nstub finished\n" });
const retry = pi.reduce({ events: [ev[0], { type: "auto_retry_end", success: false, finalError: "529 overloaded" }, { type: "message_end", message: { role: "assistant", content: [], stopReason: "error" } }, { type: "agent_settled", aborted: false }] });
const aborted = pi.reduce({ events: [ev[0], ev[5], { type: "agent_settled", aborted: true }] });
console.log(JSON.stringify([r.ok, r.response, r.sessionId, r.usage, r.reportedModel, print.ok, print.errorClass, retry.errorText, retry.errorClass, aborted.ok]));')"
    want='[true,"DONE\nsecond block","pi-0007",{"input":35,"output":7,"cacheRead":1,"cacheWrite":2,"totalTokens":45,"costUsd":0.0035},"zai/glm-5.3",false,null,"529 overloaded",null,false]'
    [[ "$got" == "$want" ]]
    verdict "9 reduce: last assistant message only, text blocks joined, thinking skipped, usage over message_end + compaction (not message_update); print-mode output is no answer; auto_retry finalError; aborted settle" $? "got:  $got" "want: $want"

    # The stderr tail of every case carries pi's two startup warnings that let it run on: the fresh session and the
    # custom model id ([03 §5.1]); neither may decide the class.
    got="$(pi_js 'const warn = "No project session found with id '"'"'pi-0003'"'"'; creating a new session with that id.\nModel \"glm-9\" not found for provider \"zai\". Using custom model id.";
const ev = (msg) => [{ type: "session", id: "pi-0003" }, { type: "message_end", message: { role: "assistant", content: [], stopReason: "error", errorMessage: msg } }, { type: "agent_settled", aborted: false }];
const viaEvents = (msg) => { const io = { events: ev(msg), stderrTail: warn, exit: { code: 0, signal: null } }; return core.classifyOutcome({ io, reduced: pi.reduce(io), patterns: pi.patterns }).errorClass; };
const viaStderr = (msg, code = 1) => { const io = { events: [], stdout: "", stderrTail: `${warn}\n${msg}`, exit: { code, signal: null } }; return core.classifyOutcome({ io, reduced: pi.reduce(io), patterns: pi.patterns }).errorClass; };
const table = {
  auth: [viaStderr("No API key found for zai."), viaEvents("401 Unauthorized"), viaEvents("403 Forbidden: access denied"), viaEvents("Authentication Fails (no such user)"), viaStderr("No models available."), viaEvents("refresh_token_invalidated")],
  "model-not-selected": [viaStderr("Model \"zai/glm-9\" not found. Use --list-models to see available models."), viaStderr("Unknown provider \"foo\"."), viaStderr("Model \"glm\" is ambiguous across providers: zai, zai-coding-cn"), viaEvents("404 The model glm-9 does not exist")],
  quota: [viaEvents("GoUsageLimitError: weekly limit"), viaEvents("FreeUsageLimitError"), viaEvents("Monthly usage limit reached"), viaEvents("402 Insufficient Balance"), viaEvents("429 insufficient_quota"), viaEvents("quota exceeded for this key"), viaEvents("your available balance is too low"),
    viaEvents("429 Usage limit reached for 5 hour. Your limit will reset at 2026-10-21 18:00:00"), viaEvents("429 Weekly/Monthly Limit Exhausted. Your limit will reset at 2026-10-28 00:00:00")],
  "rate-limit": [viaEvents("429 Too Many Requests"), viaEvents("Rate limit reached"), viaEvents("529 overloaded_error: Overloaded"), viaEvents("model is at capacity"), viaEvents("ResourceExhausted")],
  server: [viaEvents("503 Service Unavailable"), viaEvents("500 Internal Server Error"), viaEvents("fetch failed"), viaEvents("connect ECONNREFUSED 127.0.0.1:8080"), viaEvents("socket hang up"), viaEvents("getaddrinfo ENOTFOUND api.z.ai"), viaEvents("Request timed out"), viaEvents("provider returned an error")],
  context: [viaEvents("prompt is too long: 250000 tokens > 200000 maximum"), viaEvents("request_too_large"), viaEvents("This model'"'"'s maximum context length is 131072 tokens"), viaEvents("context window exceeds limit"), viaEvents("exceeded model token limit"), viaEvents("Range of input length should be [1, 98304]"), viaEvents("the request exceeds the available context size"), viaEvents("tokens greater than the context length"), viaEvents("prompt too long; exceeded max context length by 10 tokens"), viaEvents("context_length_exceeded"), viaEvents("too many tokens"), viaEvents("token limit exceeded")],
  launch: [viaStderr("Failed to load extension \"/x.ts\": ENOENT"), viaStderr("Unknown option: -x")],
};
const wrong = Object.entries(table).flatMap(([want, got]) => got.map((g, i) => (g === want ? null : `${want}[${i}]=${g}`))).filter(Boolean);
console.log(JSON.stringify([wrong, viaStderr("", 0), viaStderr("", 1), viaEvents("something odd")]));')"
    [[ "$got" == '[[],"malformed","crash","malformed"]' ]]
    verdict "9 patterns: pi's startup errors and its retry / overflow classifier texts land in auth, model-not-selected, quota (a 429 'usage limit' too), rate-limit, server, context, launch; the fresh-session and custom-model-id warnings are never a class" $? "got: $got"

    got="$(pi_js 'const warn = "x\nNo project session found with id '"'"'pi-0001'"'"'; creating a new session with that id.\n";
console.log(JSON.stringify([
  pi.finalize({ record: { resumeOf: null }, io: { stderrTail: warn } }),
  pi.finalize({ record: { resumeOf: "pi-0001" }, io: { stderrTail: warn } }),
  pi.finalize({ record: { resumeOf: "pi-0001" }, io: { stderrTail: "all fine" } }),
]));')"
    [[ "$got" == '[null,{"ok":false,"response":null,"errorClass":"resume-lost","errorText":"No project session found with id '"'"'pi-0001'"'"'; creating a new session with that id."},null]' ]]
    verdict "9 finalize: the lost-session warning means resume-lost only for a resumed job" $? "got: $got"

    # Without the warning (gone from the 200-line tail): a session file of this id and cwd that was not there when the
    # job started (meta.sessionFilesBefore) is the new session pi started instead.
    got="$(pi_js 'const head = (cwd) => JSON.stringify({ type: "session", version: 3, id: "pi-0001", cwd }) + "\n{}\n";
const [f0, f1, f2] = ["2026-10-21T00-00-00-000Z_pi-0001.jsonl", "2026-10-21T01-00-00-000Z_pi-0001.jsonl", "2026-10-21T02-00-00-000Z_pi-0001.jsonl"];
const files = { "/d": [f2, f0, "notes.txt", f1], [`/d/${f0}`]: head("/w"), [`/d/${f1}`]: head("/w"), [`/d/${f2}`]: head("/elsewhere") };
const ctx = { fs: { readdir: (d) => files[d] ?? null, readFile: (f) => files[f] ?? null } };
const job = (before, extra = {}) => ({ cwd: "/w", record: { resumeOf: "pi-0001", sessionId: "pi-0001", meta: { sessionDir: "/d", ...(before ? { sessionFilesBefore: before } : {}) }, ...extra }, io: { stderrTail: "[extension] chatter line 250" } });
console.log(JSON.stringify([pi.finalize(job([f0]), ctx), pi.finalize(job([f0, f1]), ctx), pi.finalize(job(null), ctx), pi.finalize(job([f0], { resumeOf: null }), ctx), pi.finalize(job([f0]))]));')"
    want='[{"ok":false,"response":null,"errorClass":"resume-lost","errorText":"pi started a new session file 2026-10-21T01-00-00-000Z_pi-0001.jsonl in /d instead of resuming session pi-0001"},null,null,null,null]'
    [[ "$got" == "$want" ]]
    verdict "9 finalize: a new session file of the id and cwd (not in meta.sessionFilesBefore) → resume-lost; one of another cwd, a record without the list, a fresh job → not" $? "got:  $got" "want: $want"

    # scrub(): the session dir's text files that hold a registered value, redacted, with their mode — what the core
    # writes back (writeAdapterFiles: atomic, the given mode, under the data root). Real files under the run's temp root.
    got="$(pi_js 'const fs = await import("node:fs");
const path = await import("node:path");
const root = fs.mkdtempSync(path.join(process.argv[1], "scrub-"));
const env = { AGENT_DISPATCH_STATE_DIR: root };
const key = "zai-key-value-424242", key2 = "q\"uoted\\key-77";
const dir = path.join(root, "jobs", "pi-0001", "sessions");
fs.mkdirSync(path.join(dir, "nested"), { recursive: true });
const put = (name, content, mode) => { const f = path.join(dir, name); fs.writeFileSync(f, content); fs.chmodSync(f, mode); return f; };
const entry = (text) => JSON.stringify({ type: "message", id: "a1", parentId: null, message: { role: "toolResult", content: [{ type: "text", text }] } });
const session = put("2026-10-21T00-00-00-000Z_pi-0001.jsonl", [JSON.stringify({ type: "session", version: 3, id: "pi-0001", cwd: "/w" }), entry(`ZAI_API_KEY=${key}\n`), entry(`the other: ${key2}`)].join("\n") + "\n", 0o640);
const clean = put("other.jsonl", entry("nothing secret") + "\n", 0o600);
const nested = put("nested/notes.txt", `raw ${key}\n`, 0o600);
const blob = put("blob.bin", Buffer.concat([Buffer.from([0xff, 0x00]), Buffer.from(key)]), 0o600);
const inode = (f) => fs.statSync(f).ino;
const before = [inode(clean), inode(blob)];
const ctx = { fs: core.makeCtx({ env }).fs, redact: core.redactor([key, key2]) };
const job = { dir: path.join(root, "jobs", "pi-0001"), record: { meta: { sessionDir: dir } } };
const plan = pi.scrub(job, ctx);
core.writeAdapterFiles({ files: plan }, env);
const text = fs.readFileSync(session, "utf8");
const holds = (f) => fs.readFileSync(f).includes(key);
console.log(JSON.stringify([plan.map((e) => [path.relative(dir, e.path), e.mode.toString(8)]), [session, nested].map((f) => (fs.statSync(f).mode & 0o777).toString(8)),
  holds(session) || holds(nested) || text.includes("uoted"), text.split("<redacted>").length - 1, text.trim().split("\n").every((l) => JSON.parse(l)), fs.readFileSync(nested, "utf8"),
  [inode(clean), inode(blob)].every((n, i) => n === before[i]), holds(blob),
  pi.resumeCheck({ id: "pi-0001", cwd: "/w", sessionId: "pi-0001", meta: { sessionDir: dir } }, {}, { job: { cwd: "/w" } }, ctx), pi.scrub(job, ctx), pi.scrub(job, { fs: ctx.fs })]));' "$TEST_ROOT")"
    want='[[["2026-10-21T00-00-00-000Z_pi-0001.jsonl","640"],["nested/notes.txt","600"]],["640","600"],false,2,true,"raw <redacted>\n",true,true,null,[],[]]'
    [[ "$got" == "$want" ]]
    verdict "9 scrub: every text file of the session dir holding a key (raw or JSON-escaped, nested too) comes back redacted with its mode; clean and binary files untouched; still valid JSONL that resumes; nothing left on a second pass or without a redactor" $? "got:  $got" "want: $want"

    # A symlink in the session dir (pi's bash tool can make one) is never followed: the core checks only that a path lies
    # under the data root as written, so a symlinked directory would take the rewrite (and the chmod of its parent) to
    # its target. Symlinked directories (nested too, the session dir itself, a loop) and files are skipped; real files
    # beside them are still scrubbed.
    got="$(pi_js 'const fs = await import("node:fs");
const path = await import("node:path");
const base = fs.mkdtempSync(path.join(process.argv[1], "scrub-link-"));
const env = { AGENT_DISPATCH_STATE_DIR: path.join(base, "data") };
const key = "zai-key-value-424242";
const outside = path.join(base, "outside");
fs.mkdirSync(path.join(outside, "deeper"), { recursive: true });
fs.chmodSync(outside, 0o755);
fs.writeFileSync(path.join(outside, "notes.txt"), `user file ${key}\n`, { mode: 0o644 });
fs.writeFileSync(path.join(outside, "deeper", "x.jsonl"), `${key}\n`, { mode: 0o644 });
const jobDir = path.join(env.AGENT_DISPATCH_STATE_DIR, "jobs", "pi-0001");
const dir = path.join(jobDir, "sessions");
fs.mkdirSync(path.join(dir, "nested"), { recursive: true });
fs.writeFileSync(path.join(dir, "s_pi-0001.jsonl"), `${key}\n`);
fs.writeFileSync(path.join(dir, "nested", "n.txt"), `${key}\n`);
const links = { linkdir: outside, "link.txt": path.join(outside, "notes.txt"), "nested/inner": outside, "nested/inner.jsonl": path.join(outside, "deeper", "x.jsonl"), loop: dir };
for (const [name, target] of Object.entries(links)) fs.symlinkSync(target, path.join(dir, name));
const job2 = path.join(env.AGENT_DISPATCH_STATE_DIR, "jobs", "pi-0002");
fs.mkdirSync(job2, { recursive: true });
fs.symlinkSync(outside, path.join(job2, "sessions"));
const ctx = { fs: core.makeCtx({ env }).fs, redact: core.redactor([key]) };
const plan = pi.scrub({ dir: jobDir, record: { meta: { sessionDir: dir } } }, ctx);
const plan2 = pi.scrub({ dir: job2, record: { meta: { sessionDir: path.join(job2, "sessions") } } }, ctx);
core.writeAdapterFiles({ files: [...plan, ...plan2] }, env);
const holds = (f) => fs.readFileSync(f, "utf8").includes(key);
const isLink = (f) => fs.lstatSync(f).isSymbolicLink();
console.log(JSON.stringify([plan.map((e) => path.relative(dir, e.path)), plan2.length, holds(path.join(outside, "notes.txt")) && holds(path.join(outside, "deeper", "x.jsonl")),
  (fs.statSync(outside).mode & 0o777).toString(8), Object.keys(links).every((name) => isLink(path.join(dir, name))) && isLink(path.join(job2, "sessions")),
  holds(path.join(dir, "s_pi-0001.jsonl")) || holds(path.join(dir, "nested", "n.txt"))]));' "$TEST_ROOT")"
    want='[["nested/n.txt","s_pi-0001.jsonl"],0,true,"755",true,false]'
    [[ "$got" == "$want" ]]
    verdict "9 scrub never follows a symlink: a symlinked dir (nested too, the session dir itself, a loop) or file is skipped — the files outside keep their content, their dir its mode, the links stay links; real files beside them are still redacted" $? "got:  $got" "want: $want"

    got="$(pi_js 'const files = {
  "/d": ["2026-10-21T00-00-00-000Z_pi-0001.jsonl", "other.jsonl", "notes.txt"],
  "/d/2026-10-21T00-00-00-000Z_pi-0001.jsonl": JSON.stringify({ type: "session", version: 3, id: "pi-0001", cwd: "/w" }) + "\n{}\n",
  "/d/other.jsonl": JSON.stringify({ type: "session", version: 3, id: "pi-0009", cwd: "/w" }) + "\n",
};
const ctx = { fs: { readdir: (d) => files[d] ?? null, readFile: (f) => (typeof files[f] === "string" ? files[f] : null), exists: (f) => f in files, stat: () => null } };
const prev = { id: "pi-0001", cwd: "/w", sessionId: "pi-0001", meta: { sessionDir: "/d" } };
const check = (p, cwd) => pi.resumeCheck(p, {}, { job: { cwd } }, ctx);
console.log(JSON.stringify([check(prev, "/w"), check({ ...prev, sessionId: "pi-0009" }, "/w"), check({ ...prev, cwd: "/x" }, "/w"), check({ ...prev, meta: null }, "/w"),
  check({ ...prev, sessionId: "pi-0002" }, "/w"), check({ ...prev, cwd: "/v" }, "/v")]));')"
    want='[null,null,"the pi session of pi-0001 was started in /x, not /w","job pi-0001 recorded no pi session dir","no pi session file with id pi-0002 for /w in /d; pi would start a new session","no pi session file with id pi-0001 for /v in /d; pi would start a new session"]'
    [[ "$got" == "$want" ]]
    verdict "9 resumeCheck: same cwd, a recorded session dir, and a file whose header id and cwd match (any file name)" $? "got:  $got" "want: $want"

    got="$(pi_js 'const calls = [];
let status = 1;
const ctx = { profileName: "p", env: { PATH: "/b1:/b2", HOME: "/h", OPENAI_API_KEY: "leak", PI_CODING_AGENT_DIR: "/user-pi" }, paths: { homes: "/data/homes" },
  fs: { stat: (f) => (["/b2/fd", "/b1/rg"].includes(f) ? { isFile: () => true, mode: 0o755 } : null), exists: (f) => ["/data/homes/p/pi", "/ext/ok.ts"].includes(f), readdir: () => null, readFile: () => null },
  exec: (cmd, args, opts) => { calls.push({ cmd, args, env: opts.env, timeoutMs: opts.timeoutMs }); return { status, stdout: JSON.stringify({ status: "x", authType: "api_key" }), stderr: "", error: null }; } };
const keyed = { harness: "pi", auth: { key: "zai" }, keyVar: "ZAI_API_KEY", model: "zai/glm-5.3", home: "isolated", options: { extensions: ["builtin:llama.cpp", "/ext/ok.ts"] }, wrap: ["srt", "--"] };
const short = (list) => list.map((c) => `${c.name}:${c.level}`).join(",");
const a = short(pi.doctorChecks(keyed, ctx));
status = 0; const b = short(pi.doctorChecks(keyed, ctx));
status = 2; const c = short(pi.doctorChecks(keyed, ctx));
const login = { harness: "pi", auth: "login", model: "openai/gpt-6-luna", home: "user" };
status = 0; const d = short(pi.doctorChecks(login, ctx));
status = 1; const e = short(pi.doctorChecks(login, ctx));
const before = calls.length;
const f = short(pi.doctorChecks({ ...login, model: "gpt-6-luna" }, ctx));
const g = short(pi.doctorChecks({ ...login, home: "isolated", options: { extensions: ["/ext/none.ts", "rel/x.ts", "builtin:llamacpp", "builtin:mcp"] } }, { ...ctx, profileName: "q" }));
const h = short(pi.doctorChecks({ ...keyed, home: "user" }, ctx));
const i = short(pi.doctorChecks(keyed, { ...ctx, fs: { ...ctx.fs, exists: (file) => ["/data/homes/p/pi", "/data/homes/p/pi/auth.json", "/ext/ok.ts"].includes(file) } }));
const noExec = calls.length === before;
const typo = pi.doctorChecks({ ...login, options: { extensions: ["builtin:"] } }, ctx).find((c) => c.name === "pi-extension");
const first = calls[0];
console.log(JSON.stringify([a, b, c, d, e, f, g, h, i, noExec, typo.level, typo.hint, first.cmd, first.args, first.env.PI_CODING_AGENT_DIR, first.env.PI_OFFLINE, "ZAI_API_KEY" in first.env, "OPENAI_API_KEY" in first.env,
  calls[3].env.PI_CODING_AGENT_DIR, mod.BUILTIN_EXTENSIONS, first.timeoutMs]));')"
    want='["pi-tools:ok,pi-extension:ok,pi-auth:ok","pi-tools:ok,pi-extension:ok,pi-auth:FAIL","pi-tools:ok,pi-extension:ok,pi-auth:FAIL","pi-tools:ok,pi-auth:ok","pi-tools:ok,pi-auth:FAIL","pi-tools:ok,pi-auth:WARN","pi-tools:ok,pi-extension:FAIL,pi-extension:WARN,pi-extension:WARN,pi-auth:FAIL","pi-tools:ok,pi-extension:ok,pi-auth:FAIL","pi-tools:ok,pi-extension:ok,pi-auth:FAIL",true,"WARN","builtin: is not one of pi'"'"'s built-in extensions (builtin:mcp, builtin:llama.cpp, builtin:codemode, builtin:tool-search); pi would stop with \"Failed to load extension\" (errorClass launch)","srt",["--","pi","auth","check","--provider","zai","--json"],"/data/homes/p/pi","1",false,false,"/user-pi",["builtin:mcp","builtin:llama.cpp","builtin:codemode","builtin:tool-search"],30000]'
    [[ "$got" == "$want" ]]
    verdict "9 doctorChecks: [{name, level, hint}] — fd/rg, extensions (an unknown builtin: → WARN naming the set), pi auth check (through wrap, the profile home, no key, no caller credentials, 30 s; a credential pi holds for a keyed profile → FAIL); no exec without a provider or home, nor for a keyed profile task refuses" $? "got:  $got" "want: $want"

    got="$(pi_js 'const ctx = { profileName: "p", env: {}, paths: { homes: "/data/homes" } };
const profile = { harness: "pi", auth: { key: "zai" }, keyVar: "ZAI_API_KEY", model: "zai/glm-5.3", effort: "low", home: "isolated", options: { extensions: ["builtin:llama.cpp"] } };
const req = { profile, role: null, write: false, job: { id: null, dir: "/data/state/doctor", cwd: "/scratch" }, prompt: { path: "/scratch/prompt.md" }, sessionId: null, resume: null, harness: { bin: "/opt/pi" } };
const doctorPlan = pi.invocation(req, ctx);
const probe = pi.probe({ ...req, sessionId: "0f0f" }, ctx);
let refused = null;
try { pi.invocation({ ...req, profile: { ...profile, keyVar: undefined } }, ctx); } catch (error) { refused = error.message.slice(0, 32); }
const home = pi.prepareHome(profile, ctx);
console.log(JSON.stringify([doctorPlan.argv, doctorPlan.dirs, doctorPlan.meta, probe.argv, probe.secretEnv, probe.stdinPath, refused, home, pi.prepareHome({ ...profile, home: "user" }, ctx)]));')"
    want='[["/opt/pi","--mode","json","--model","zai/glm-5.3","--thinking","low","--no-session","--no-approve","-ne","-ns","-np","--no-mcp","--tools","read,grep,find,ls","-e","builtin:llama.cpp"],[],null,["/opt/pi","--mode","json","--model","zai/glm-5.3","--thinking","low","--no-session","--no-approve","-ne","-ns","-np","-nc","--no-mcp","-nt","-e","builtin:llama.cpp"],["ZAI_API_KEY"],"/scratch/prompt.md","a pi profile with a key needs ke",{"env":{"PI_CODING_AGENT_DIR":"/data/homes/p/pi"},"dirs":["/data/homes/p/pi"],"files":[]},{"env":{},"dirs":[],"files":[]}]'
    [[ "$got" == "$want" ]]
    verdict "9 invocation without a job (doctor): --no-session, nothing to create; probe(): -nc, -nt; a keyed profile without keyVar is refused; prepareHome (also what profile env exports)" $? "got:  $got" "want: $want"

    # A stored credential would win over the key [03 §6]: invocation (with a job) and probe() refuse a keyed profile
    # with "home": "user" or with an auth.json in its isolated home (UsageError: exit 2 at task time); a job-less
    # request (doctor's env check) and a login profile are not refused. A resume records the session files of its id.
    got="$(pi_js 'const ctx = { profileName: "p", env: { PI_CODING_AGENT_DIR: "/user-pi" }, paths: { homes: "/data/homes" },
  fs: { exists: (f) => f === "/data/homes/p/pi/auth.json", readdir: (d) => (d === "/data/jobs/pi-0001/sessions" ? ["x_pi-0009.jsonl", "2026-10-21T00-00-00-000Z_pi-0001.jsonl", "notes.txt"] : null), readFile: () => null, stat: () => null } };
const keyed = { harness: "pi", auth: { key: "zai" }, keyVar: "ZAI_API_KEY", model: "zai/glm-5.3" };
const login = { harness: "pi", auth: "login", model: "openai/x" };
const req = (profile, extra = {}) => ({ profile, profileName: "p", write: false, job: { id: "pi-0002", dir: "/data/jobs/pi-0002", cwd: "/w" }, prompt: { path: "/w/p.md" }, sessionId: "pi-0002", resume: null, harness: null, ...extra });
const err = (fn) => { try { fn(); return null; } catch (error) { return `${error instanceof core.UsageError ? "UsageError" : "Error"}: ${error.message}`; } };
const resume = { sessionId: "pi-0001", resume: { sessionId: "pi-0001", prev: { id: "pi-0001", meta: { sessionDir: "/data/jobs/pi-0001/sessions" } } } };
console.log(JSON.stringify([
  err(() => pi.invocation(req({ ...keyed, home: "user" }), ctx)),
  err(() => pi.invocation(req({ ...keyed, home: "isolated" }), ctx)),
  err(() => pi.probe(req({ ...keyed, home: "user" }), ctx)),
  err(() => pi.invocation(req({ ...keyed, home: "user" }, { job: { id: null, dir: "/d", cwd: "/d" }, sessionId: null }), ctx)),
  err(() => pi.invocation(req({ ...login, home: "isolated" }), ctx)),
  pi.invocation(req(login, resume), ctx).meta,
  pi.invocation(req(login), ctx).meta,
]));')"
    want='["UsageError: profile p: a keyed pi profile runs only in its isolated home (the default with a key): in /user-pi a credential pi stored itself (auth.json, /login) would win over ZAI_API_KEY; remove \"home\": \"user\"","UsageError: profile p: /data/homes/p/pi/auth.json exists: a credential stored there (pi /login) wins over ZAI_API_KEY; remove that file (a keyed profile needs no login)","UsageError: profile p: a keyed pi profile runs only in its isolated home (the default with a key): in /user-pi a credential pi stored itself (auth.json, /login) would win over ZAI_API_KEY; remove \"home\": \"user\"",null,null,{"sessionDir":"/data/jobs/pi-0001/sessions","agentDir":"/user-pi","sessionFilesBefore":["2026-10-21T00-00-00-000Z_pi-0001.jsonl"]},{"sessionDir":"/data/jobs/pi-0002/sessions","agentDir":"/user-pi"}]'
    [[ "$got" == "$want" ]]
    verdict "9 a keyed profile on a stored credential: invocation and probe refuse it (UsageError) — home user, an auth.json in its isolated home — not doctor's job-less request nor a login profile; a resume's meta lists its id's session files" $? "got:  $got" "want: $want"

    # A models.json in a keyed profile's isolated home is a custom endpoint (its apiKey `$<keyVar>`, [03 §5.3]):
    # invocation and probe take it, never reading it; an auth.json beside it is still refused.
    got="$(pi_js 'const reads = [];
const present = new Set(["/data/homes/p/pi/models.json"]);
const ctx = { profileName: "p", env: { PATH: "" }, paths: { homes: "/data/homes" },
  fs: { exists: (f) => present.has(f), readFile: (f) => { reads.push(f); return null; }, readdir: () => null, stat: () => null },
  exec: () => { throw new Error("pi was run"); } };
const keyed = { harness: "pi", auth: { key: "zai" }, keyVar: "ZAI_API_KEY", model: "zai/glm-5.3", home: "isolated" };
const req = (profile) => ({ profile, profileName: "p", write: false, job: { id: "pi-0002", dir: "/data/jobs/pi-0002", cwd: "/w" }, prompt: { path: "/w/p.md" }, sessionId: "pi-0002", resume: null, harness: null });
const err = (fn) => { try { fn(); return null; } catch (error) { return `${error instanceof core.UsageError ? "UsageError" : "Error"}: ${error.message}`; } };
const models = [err(() => pi.invocation(req(keyed), ctx)), err(() => pi.probe(req(keyed), ctx))];
present.add("/data/homes/p/pi/auth.json");
console.log(JSON.stringify([...models, err(() => pi.invocation(req(keyed), ctx)), reads]));')"
    want='[null,null,"UsageError: profile p: /data/homes/p/pi/auth.json exists: a credential stored there (pi /login) wins over ZAI_API_KEY; remove that file (a keyed profile needs no login)",[]]'
    [[ "$got" == "$want" ]]
    verdict "9 a models.json in a keyed profile's isolated home (a custom endpoint): invocation and probe take it without reading it; an auth.json beside it is refused" $? "got:  $got" "want: $want"

    # The stub keeps a copy of the adapter's built-in extensions instead of require()-ing the ES module adapter (Node
    # 20.19+ / 22.12+ only): the two lists match, and a run naming one works where require() cannot load ES modules.
    got="$(pi_js 'const { createRequire } = await import("node:module");
const stub = createRequire(process.argv[1])(process.argv[1]);
console.log(JSON.stringify([stub.BUILTIN_EXTENSIONS, mod.BUILTIN_EXTENSIONS]));' "$SCRIPT_DIR/fixtures/stub-dialects/pi-jsonl.cjs")"
    line="$(cd "$TEST_ROOT" && printf 'hi\n' | NODE_OPTIONS=--no-experimental-require-module AGENT_STUB_RESPONSE=PONG "$PI" --mode json --no-session -nt -e builtin:llama.cpp 2>&1; echo "rc=$?")"
    [[ "$got" == '[["builtin:mcp","builtin:llama.cpp","builtin:codemode","builtin:tool-search"],["builtin:mcp","builtin:llama.cpp","builtin:codemode","builtin:tool-search"]]' \
        && "$line" == *'"type":"agent_settled"'* && "$line" == *'PONG'* && "$line" == *$'\nrc=0' ]]
    verdict "9 the stub's BUILTIN_EXTENSIONS equal the adapter's; with require(esm) off a run with -e builtin:llama.cpp still answers" $? "lists: $got" "run: $(tail -3 <<<"$line")"

    # "home": "user" with PI_CODING_AGENT_DIR in profile.env (allowed: not mandatory there): pi runs in that dir, so the
    # auth check, its hints and meta.agentDir name it; null removes it (pi's default ~/.pi/agent).
    got="$(pi_js 'const calls = [];
const ctx = { profileName: "p", env: { PATH: "/b", PI_CODING_AGENT_DIR: "/user-pi" }, paths: { homes: "/data/homes" },
  fs: { stat: () => null, exists: () => false, readdir: () => null, readFile: () => null },
  exec: (cmd, args, opts) => { calls.push(opts.env.PI_CODING_AGENT_DIR ?? null); return { status: 1, stdout: JSON.stringify({ authType: null }), stderr: "", error: null }; } };
const login = { harness: "pi", auth: "login", model: "zai/glm-5.3", home: "user" };
const own = { ...login, env: { PI_CODING_AGENT_DIR: "/profile-pi" } };
const none = { ...login, env: { PI_CODING_AGENT_DIR: null } };
const auth = (profile) => pi.doctorChecks(profile, ctx).find((c) => c.name === "pi-auth");
const req = (profile) => ({ profile, write: false, job: { id: "pi-0001", dir: "/data/jobs/pi-0001", cwd: "/w" }, prompt: { path: "/w/p.md" }, sessionId: "pi-0001", resume: null, harness: null });
const hints = [own, none, login].map((profile) => { const c = auth(profile); return `${c.level} ${/ in (\S+);/.exec(c.hint)?.[1]}`; });
console.log(JSON.stringify([hints, calls, [own, none, login].map((profile) => pi.invocation(req(profile), ctx).meta.agentDir)]));')"
    want='[["FAIL /profile-pi","FAIL ~/.pi/agent","FAIL /user-pi"],["/profile-pi",null,"/user-pi"],["/profile-pi",null,"/user-pi"]]'
    [[ "$got" == "$want" ]]
    verdict "9 home user + profile.env PI_CODING_AGENT_DIR: pi auth check runs there and its hint and meta.agentDir name it (not the caller's); null → ~/.pi/agent" $? "got:  $got" "want: $want"

    # The stub keeps to what [03] documents: an unknown short option is pi's "Unknown option: -x"; an unknown long one is
    # refused by the stub in its own words (unverified in pi); print mode exits 1 on a truncated answer, text printed.
    got="$(cd "$TEST_ROOT" && "$PI" --mode json -x </dev/null 2>&1; echo "rc=$?")"
    ok="$(cd "$TEST_ROOT" && "$PI" --mode json --frobnicate </dev/null 2>&1; echo "rc=$?")"
    line="$(cd "$TEST_ROOT" && AGENT_STUB_MODE=truncated "$PI" --no-session -nt </dev/null 2>"$TEST_ROOT/stub-err.txt"; echo "rc=$?")"
    [[ "$got" == $'Unknown option: -x\nrc=1' && "$ok" == "agent-stub: unknown long option --frobnicate"*$'\nrc=1' && "$ok" != *"Unknown option"* \
        && "$line" == $'DONE\nthe report was cut\nrc=1' && "$(cat "$TEST_ROOT/stub-err.txt")" == "Response was truncated: the model reached its output token limit." ]]
    verdict "9 the stub: 'Unknown option' for short flags only; print mode prints a truncated answer, warns, exits 1" $? "short: $got" "long: $ok" "print: $line / $(cat "$TEST_ROOT/stub-err.txt")"

    # --- leak check: nothing this run started is still running ---
    local left="" i=0
    while ((i < 50)); do
        left="$(pgrep -f "$TEST_ROOT" | tr '\n' ' ')"
        [[ -z "$left" ]] && break
        sleep 0.2
        i=$((i + 1))
    done
    [[ -z "$left" ]]
    verdict "no process of this run (runner, stub, its bash-tool children) outlives the suite" $? "left: $left"

    echo ""
    echo "PASS count: $PASSES"
    if [[ "$FAILURES" -ne 0 ]]; then
        echo "FAILED: $FAILURES assertion(s)."
        exit 1
    fi
    echo "PASS"
}

main "$@"
