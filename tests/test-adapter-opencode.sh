#!/usr/bin/env bash
# Tests for bin/lib/adapters/opencode.mjs, the OpenCode 1.19.x adapter of agent-dispatch (increment 4 of
# docs/superpowers/specs/2026-10-20-universal-dispatchers-design.md §8; facts from
# docs/research/universal-dispatchers/02-opencode.md). Zero model calls and no real OpenCode: the profiles point "bin"
# at tests/fixtures/agent-stub.cjs (linked as $TEST_ROOT/bin/opencode) in its opencode-jsonl dialect
# (tests/fixtures/stub-dialects/opencode-jsonl.cjs), which records argv, env, stdin and cwd (AGENT_STUB_RECORD). Jobs
# run through the real CLI (bin/lib/agent-dispatch.mjs) with a temp AGENT_DISPATCH_STATE_DIR and HOME; the pure parts
# of the adapter are unit-tested directly. Runs on macOS and Linux.
#
# Covered (spec §8 row 4 and the adapter contract): golden argv / env / stdin for each auth mode and role; the sp-
# agents in OPENCODE_CONFIG_CONTENT, the role's set in OPENCODE_PERMISSION, options.permission / options.plugins; the
# project's instructions; home isolated for a key and user for a login, with git still reading the caller's config;
# profile.env overriding the defaults and its own TMPDIR in external_directory; sandbox native changes nothing; stdin
# closed after the prompt (stdin-wait); exit 1 with a valid answer is success; the answer of the last message, only once
# its step finished (a narration before a crash or a kill is none); the export fallback, only for a finished message of
# this run; a surviving ask → blocked; "agent … not found" → launch; quota only with markers in the body; the error
# classes; resume with the same --dir and data dir, "Session not found" → resume-lost; the cancel ladder (SIGTERM,
# 5 s, SIGKILL) over detached descendants; timeout; secrets never in argv / config / logs; OpenCode 2 → launch;
# doctorChecks (the login from the credential rows of `auth list` only) and the probe.
#
# Every process a run starts carries the run's temp root in its argv (runners: their jobs dir; the stub: its link under
# the temp root; descendants: their pid file), so the cleanup and the leak check touch this run only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$REPO_ROOT/bin/lib/agent-dispatch.mjs"
CORE="$REPO_ROOT/bin/lib/agent-core.mjs"
ADAPTER="$REPO_ROOT/bin/lib/adapters/opencode.mjs"
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
    # Only this run's processes; SIGKILL, because some stubs and descendants ignore SIGTERM by design.
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

# rjs <stub-record> <js expression over r = {argv, stdin, cwd, env}> — print its value (objects as JSON).
rjs() {
    node -e '
const r = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
const v = new Function("r", `return (${process.argv[2]});`)(r);
process.stdout.write(v === undefined || v === null ? "" : typeof v === "object" ? JSON.stringify(v) : String(v));' -- "$1" "$2"
}

# canon <json> — the JSON re-serialized compactly, key order kept (golden comparisons are order-sensitive).
canon() { node -e 'process.stdout.write(JSON.stringify(JSON.parse(process.argv[1])))' -- "$1"; }

# jarr <args...> — the JSON array of the arguments.
jarr() { node -e 'process.stdout.write(JSON.stringify(process.argv.slice(1)))' -- "$@"; }

mode_of() { node -e 'console.log((require("node:fs").statSync(process.argv[1]).mode & 0o777).toString(8))' -- "$1"; }
now_ms() { node -e 'console.log(Date.now())'; }

# st_json <id> [status args...] — `status <id> --json`.
st_json() {
    local id="$1"
    shift
    ad status "$id" --json "$@" 2>/dev/null
}

# wait_status <id> <regex> <seconds> [status args...] — poll until the job's status matches; print it.
wait_status() {
    local id="$1" want="$2" limit="$3"
    shift 3
    local st="" i=0
    while ((i < limit * 5)); do
        st="$(st_json "$id" "$@" | jfield job.status || true)"
        if [[ "$st" =~ ^($want)$ ]]; then break; fi
        sleep 0.2
        i=$((i + 1))
    done
    echo "$st"
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

# start <profile> [task args...] — `task --background --profile P --prompt-file $PROMPT …` (env assignments as a
# prefix reach the runner and the stub); print the job id, or ERR:<exit code> with the stderr in $TEST_ROOT/start.err.
start() {
    local profile="$1" out rc
    shift
    out="$(ad task --background --profile "$profile" --prompt-file "$PROMPT" "$@" 2>"$TEST_ROOT/start.err")"
    rc=$?
    if ((rc != 0)); then
        echo "ERR:$rc"
        return
    fi
    echo "${out##* }"
}

# finish <id> [status args...] — wait (20 s) for a terminal status; print "<status> <errorClass|->".
finish() {
    local id="$1"
    shift
    local st cls
    st="$(wait_status "$id" 'completed|failed|cancelled' 20 "$@")"
    cls="$(st_json "$id" "$@" | jfield job.errorClass)"
    echo "$st ${cls:--}"
}

main() {
    echo "=== Test: OpenCode adapter ==="

    TEST_ROOT="$(mktemp -d)"
    trap cleanup EXIT
    umask 022

    export HOME="$TEST_ROOT/home"
    mkdir -p "$HOME" "$TEST_ROOT/bin" "$TEST_ROOT/rec" "$TEST_ROOT/tmp"
    export TMPDIR="$TEST_ROOT/tmp"
    export AGENT_DISPATCH_STATE_DIR="$TEST_ROOT/state"
    local STATE="$AGENT_DISPATCH_STATE_DIR"
    local REC="$TEST_ROOT/rec"
    ln -s "$STUB" "$TEST_ROOT/bin/opencode"
    local OC="$TEST_ROOT/bin/opencode"
    ln -s "$WSTUB" "$TEST_ROOT/bin/zcode-dispatch"
    ln -s "$WSTUB" "$TEST_ROOT/bin/codex-dispatch"
    export AGENT_DISPATCH_ZCODE="$TEST_ROOT/bin/zcode-dispatch"
    export AGENT_DISPATCH_CODEX="$TEST_ROOT/bin/codex-dispatch"
    export WRAPPER_STUB_DIR="$TEST_ROOT/wrappers"
    unset AGENT_DISPATCH_ADAPTER_DIR AGENT_TEST_BOOT_ID XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
    unset OPENCODE_CONFIG OPENCODE_CONFIG_DIR OPENCODE_CONFIG_CONTENT OPENCODE_PERMISSION GITHUB_TOKEN OPENAI_API_KEY DEEPSEEK_API_KEY
    unset AGENT_STUB_MODE AGENT_STUB_RECORD AGENT_STUB_DELAY_MS AGENT_STUB_MESSAGE AGENT_STUB_CLASS AGENT_STUB_EXIT AGENT_STUB_RESPONSE
    unset AGENT_STUB_SECRET_VAR AGENT_STUB_PIDS AGENT_STUB_SIGNALS AGENT_STUB_VERSION AGENT_STUB_HELP_DROP AGENT_STUB_CALL_LOG AGENT_STUB_EXPORT
    export AGENT_STUB_DIALECT=opencode-jsonl
    export AGENT_ENV_PASSTHROUGH="AGENT_STUB_DIALECT,AGENT_STUB_MODE,AGENT_STUB_RECORD,AGENT_STUB_DELAY_MS,AGENT_STUB_MESSAGE,AGENT_STUB_CLASS,AGENT_STUB_EXIT,AGENT_STUB_RESPONSE,AGENT_STUB_SECRET_VAR,AGENT_STUB_PIDS,AGENT_STUB_SIGNALS,AGENT_STUB_VERSION,AGENT_STUB_HELP_DROP,AGENT_STUB_CALL_LOG,AGENT_STUB_EXPORT"

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
    printf '# Rules\n' >"$repo/AGENTS.md"
    printf '# Claude rules\n' >"$repo/CLAUDE.md"
    PROMPT="$TEST_ROOT/prompt.md"
    printf '## Headless run\n\nImplement the thing.\n' >"$PROMPT"
    local prompt_bytes
    prompt_bytes="$(wc -c <"$PROMPT" | tr -d ' ')"
    cd "$repo"

    local KEY="oc-test-key-$RANDOM-$RANDOM-value"
    printf '%s\n' "$KEY" | ad key set deepseek >/dev/null

    mkdir -p "$STATE"
    cat >"$STATE/config.json" <<EOF
{
  "version": 1,
  "profiles": {
    "oc-key": { "harness": "opencode", "auth": { "key": "deepseek" }, "keyVar": "DEEPSEEK_API_KEY", "model": "deepseek/deepseek-v4-pro", "effort": "high", "bin": "$OC", "maxParallel": 30 },
    "oc-login": { "harness": "opencode", "auth": "login", "model": "github-copilot/gpt-6-mini", "bin": "$OC", "maxParallel": 30 },
    "oc-login-iso": { "harness": "opencode", "auth": "login", "home": "isolated", "model": "github-copilot/gpt-6-mini", "bin": "$OC" },
    "oc-key-user": { "harness": "opencode", "auth": { "key": "deepseek" }, "keyVar": "DEEPSEEK_API_KEY", "home": "user", "model": "deepseek/deepseek-v4-pro", "bin": "$OC" },
    "oc-opts": { "harness": "opencode", "auth": "login", "model": "openai/gpt-6-luna", "bin": "$OC", "options": { "permission": { "bash": { "git push*": "deny" }, "webfetch": "allow" }, "plugins": true } },
    "oc-native": { "harness": "opencode", "auth": "login", "model": "github-copilot/gpt-6-mini", "bin": "$OC", "sandbox": "native" },
    "oc-ask": { "harness": "opencode", "auth": "login", "model": "github-copilot/gpt-6-mini", "bin": "$OC", "options": { "permission": { "bash": { "npm *": "ask" } } } },
    "oc-conflict": { "harness": "opencode", "auth": "login", "model": "github-copilot/gpt-6-mini", "bin": "$OC", "env": { "OPENCODE_DISABLE_PROJECT_CONFIG": "0" } },
    "oc-nomodel": { "harness": "opencode", "auth": "login", "bin": "$OC" },
    "oc-badperm": { "harness": "opencode", "auth": "login", "model": "a/b", "bin": "$OC", "options": { "permission": { "bash": "maybe" } } },
    "oc-fast": { "harness": "opencode", "auth": "login", "model": "github-copilot/gpt-6-mini", "bin": "$OC", "timeoutMin": 0.03 },
    "oc-nobin": { "harness": "opencode", "auth": "login", "model": "github-copilot/gpt-6-mini", "bin": "$TEST_ROOT/bin/no-such-opencode" },
    "oc-override": { "harness": "opencode", "auth": "login", "model": "github-copilot/gpt-6-mini", "bin": "$OC", "env": { "OPENCODE_PURE": "0", "OPENCODE_DISABLE_AUTOUPDATE": null } },
    "oc-tmpdir": { "harness": "opencode", "auth": "login", "model": "github-copilot/gpt-6-mini", "bin": "$OC", "env": { "TMPDIR": "/profile-tmp" } },
    "oc-zen": { "harness": "opencode", "auth": "login", "home": "isolated", "model": "opencode/zen-model", "bin": "$OC" }
  }
}
EOF
    # From here on a failing command must not end the suite: FAILURES decides the exit code, and the summary prints.
    set +e

    local id id2 st rec want got sid ok t0 t1 line n

    # The golden permission sets (spec §3.6 А4) for a harness data dir: allowed outside the tree are this run's temp
    # dirs ($TMPDIR, /tmp) and OpenCode's truncation dir <data>/opencode/tool-output; on macOS also their /private
    # names (/tmp and /var are symlinks there).
    local READ='{"*":"allow","*.env":"deny","*.env.*":"deny","*.env.example":"allow"}'
    ext_rules() {
        local dirs=("$TMPDIR" /tmp "$1/opencode/tool-output") d rules='"*":"deny"'
        if [[ "$(uname -s)" == Darwin ]]; then
            for d in "${dirs[@]}"; do
                if [[ "$d" == /tmp || "$d" == /tmp/* || "$d" == /var || "$d" == /var/* ]]; then dirs+=("/private$d"); fi
            done
        fi
        for d in "${dirs[@]}"; do rules="$rules,\"$d/*\":\"allow\""; done
        echo "{$rules}"
    }
    impl_set() { canon "{\"*\":\"allow\",\"read\":$READ,\"external_directory\":$(ext_rules "$1"),\"doom_loop\":\"deny\",\"question\":\"deny\",\"webfetch\":\"deny\",\"websearch\":\"deny\"}"; }
    rev_set() { canon "{\"*\":\"deny\",\"read\":$READ,\"grep\":\"allow\",\"glob\":\"allow\",\"list\":\"allow\",\"edit\":\"deny\",\"task\":\"deny\",\"bash\":{\"*\":\"deny\",\"git show*\":\"allow\",\"git diff*\":\"allow\",\"git log*\":\"allow\",\"git status*\":\"allow\"},\"external_directory\":$(ext_rules "$1"),\"webfetch\":\"deny\",\"websearch\":\"deny\"}"; }
    local IMPL REV
    IMPL="$(impl_set "$STATE/homes/oc-key/data")"
    REV="$(rev_set "$STATE/homes/oc-key/data")"
    local OC_VARS="OPENCODE_CONFIG_CONTENT OPENCODE_DISABLE_AUTOUPDATE OPENCODE_DISABLE_CLAUDE_CODE_PROMPT OPENCODE_DISABLE_EXTERNAL_SKILLS OPENCODE_DISABLE_PROJECT_CONFIG OPENCODE_PERMISSION OPENCODE_PURE"
    local oc_vars='Object.keys(r.env).filter((k) => k.startsWith("OPENCODE_")).sort().join(" ")'
    local xdg='["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"].map((k) => r.env[k] ?? "-").join(" ")'
    local secrets='Object.keys(r.env).filter((k) => /(_KEY|_TOKEN|_SECRET)$/.test(k)).sort().join(" ")'

    # --- 1. refusals before any launch (exit 2, no job) ---
    run_ad task --profile oc-conflict --background --prompt-file "$PROMPT"
    [[ "$RC" -eq 2 && "$ERR" == *"env OPENCODE_DISABLE_PROJECT_CONFIG conflicts with a mandatory setting of the opencode adapter"* ]]
    verdict "1 profile.env touching a mandatory setting (OPENCODE_DISABLE_PROJECT_CONFIG) is refused: exit 2" $? "rc=$RC err: $ERR"
    run_ad task --profile oc-nomodel --background --prompt-file "$PROMPT"
    [[ "$RC" -eq 2 && "$ERR" == *'oc-nomodel: an opencode profile needs "model": "<provider>/<model>"'* ]]
    verdict "1 a profile without provider/model is refused (OpenCode would pick a model by itself): exit 2" $? "rc=$RC err: $ERR"
    run_ad task --profile oc-badperm --background --prompt-file "$PROMPT"
    [[ "$RC" -eq 2 && "$ERR" == *'options.permission.bash must be "allow", "deny", "ask"'* ]]
    verdict "1 an options.permission rule that is no OpenCode action is refused: exit 2" $? "rc=$RC err: $ERR"
    n="$(find "$STATE/state" -name 'oc-*.json' 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$n" -eq 0 ]]
    verdict "1 the refused tasks left no job record" $? "records: $n"

    # --- 2. writer, key, isolated home: golden argv / stdin / env (spec §2, §3.6 А4–А6, Б, §3.5) ---
    rec="$REC/writer.json"
    id="$(AGENT_STUB_RECORD="$rec" GITHUB_TOKEN=ghp-inherited OPENAI_API_KEY=sk-inherited start oc-key --write --role implementer)"
    st="$(finish "$id")"
    local writer_id="$id"
    run_ad result "$id"
    [[ "$id" == oc-0001 && "$st" == "completed -" && "$OUT" == $'DONE\nstub finished' ]]
    verdict "2 oc-key --write completes as oc-0001; result prints the answer" $? "id=$id st=$st out=$OUT err=$(cat "$TEST_ROOT/start.err")"
    # The stub records its arguments after the binary (process.argv.slice(2)).
    want="$(jarr run --format json --title oc-0001 --agent sp-implementer -m deepseek/deepseek-v4-pro --variant high --dir "$repo")"
    got="$(rjs "$rec" 'JSON.stringify(r.argv)')"
    [[ "$got" == "$want" ]]
    verdict "2 writer argv: run --format json --title <id> --agent sp-implementer -m <provider/model> --variant <effort> --dir <root>" $? "want: $want" "got:  $got"
    [[ "$(rjs "$rec" 'r.stdin')" == "$(cat "$PROMPT")" && "$(rjs "$rec" 'r.cwd')" == "$repo" ]]
    verdict "2 the prompt comes on stdin only (no message in argv); cwd is the workspace root" $? "stdin: $(rjs "$rec" 'r.stdin')" "cwd: $(rjs "$rec" 'r.cwd')"
    [[ "$(rjs "$rec" "$oc_vars")" == "$OC_VARS" && "$(rjs "$rec" '["OPENCODE_DISABLE_PROJECT_CONFIG","OPENCODE_DISABLE_CLAUDE_CODE_PROMPT","OPENCODE_DISABLE_AUTOUPDATE","OPENCODE_DISABLE_EXTERNAL_SKILLS","OPENCODE_PURE"].map((k) => r.env[k]).join("")')" == 11111 ]]
    verdict "2 OPENCODE_*: the mandatory CONFIG_CONTENT / PERMISSION / DISABLE_PROJECT_CONFIG / DISABLE_CLAUDE_CODE_PROMPT and the defaults AUTOUPDATE / EXTERNAL_SKILLS / PURE, nothing else" $? "got: $(rjs "$rec" "$oc_vars")"
    [[ "$(rjs "$rec" "$xdg")" == "$STATE/homes/oc-key/config $STATE/homes/oc-key/data $STATE/homes/oc-key/state $STATE/homes/oc-key/cache" \
        && "$(mode_of "$STATE/homes/oc-key")" == 700 && "$(mode_of "$STATE/homes/oc-key/data")" == 700 && "$(mode_of "$STATE/homes/oc-key/cache")" == 700 ]]
    verdict "2 a key profile runs in its isolated home: XDG_CONFIG/DATA/STATE/CACHE_HOME under homes/oc-key (0700)" $? "got: $(rjs "$rec" "$xdg")"
    # git under the isolated XDG_CONFIG_HOME still reads the caller's ~/.config/git/{config,ignore,attributes}.
    local gitcfg="$STATE/homes/oc-key/config/git/config"
    mkdir -p "$HOME/.config/git"
    printf '[user]\n\tname = xdg-user\n' >"$HOME/.config/git/config"
    [[ -f "$gitcfg" && "$(mode_of "$gitcfg")" == 600 \
        && "$(cd "$repo" && env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM XDG_CONFIG_HOME="$STATE/homes/oc-key/config" git config --get user.name)" == xdg-user \
        && "$(cd "$repo" && env -u GIT_CONFIG_GLOBAL XDG_CONFIG_HOME="$STATE/homes/oc-key/config" git config --get core.excludesFile)" == "$HOME/.config/git/ignore" ]]
    verdict "2 the isolated home's git config includes the caller's ~/.config/git/config and keeps its ignore file (0600)" $? "$(cat "$gitcfg" 2>/dev/null)"
    rm -rf "$HOME/.config"
    [[ "$(rjs "$rec" 'r.env.DEEPSEEK_API_KEY')" == "$KEY" && "$(rjs "$rec" "$secrets")" == DEEPSEEK_API_KEY ]]
    verdict "2 the key is in keyVar (DEEPSEEK_API_KEY) only; inherited GITHUB_TOKEN / OPENAI_API_KEY do not reach OpenCode" $? "secret-like: $(rjs "$rec" "$secrets")"
    want="$(canon "{\"agent\":{\"sp-implementer\":{\"mode\":\"primary\",\"permission\":$IMPL},\"sp-reviewer\":{\"mode\":\"primary\",\"permission\":$REV}},\"instructions\":[\"$repo/AGENTS.md\",\"$repo/CLAUDE.md\"]}")"
    got="$(rjs "$rec" 'r.env.OPENCODE_CONFIG_CONTENT')"
    [[ "$got" == "$want" ]]
    verdict "2 OPENCODE_CONFIG_CONTENT: primary agents sp-implementer / sp-reviewer with the complete sets of §3.6 А4 and the repo's AGENTS.md + CLAUDE.md as instructions" $? "want: $want" "got:  $got"
    [[ "$(rjs "$rec" 'r.env.OPENCODE_PERMISSION')" == "$IMPL" ]]
    verdict "2 OPENCODE_PERMISSION duplicates the writer's set" $? "got: $(rjs "$rec" 'r.env.OPENCODE_PERMISSION')"
    local sj
    sj="$(st_json "$id")"
    sid="$(jfield job.sessionId <<<"$sj")"
    [[ "$sid" == ses_* && -f "$STATE/homes/oc-key/data/opencode/stub-sessions/$sid.json" && "$(jfield title <"$STATE/homes/oc-key/data/opencode/stub-sessions/$sid.json")" == oc-0001 \
        && "$(jfield job.meta.agent <<<"$sj")" == sp-implementer && "$(jfield job.meta.dataDir <<<"$sj")" == "$STATE/homes/oc-key/data" && "$(jfield job.meta.dir <<<"$sj")" == "$repo" \
        && "$(jfield job.harnessVersion <<<"$sj")" == 1.19.3 && "$(jfield job.usage.input <<<"$sj")" == 120 && "$(jfield job.usage.cost <<<"$sj")" == 0.0012 ]]
    verdict "2 the record: sessionId from the events (first-event), meta {agent, dir, dataDir}, harnessVersion, usage from step_finish" $? "$sj"
    got="$(grep -rlF "$KEY" "$STATE" 2>/dev/null | tr '\n' ' ')"
    [[ "$got" == "$STATE/keys/deepseek " && "$(rjs "$rec" 'r.argv.join(" ")')" != *"$KEY"* && "$(rjs "$rec" 'r.env.OPENCODE_CONFIG_CONTENT + r.env.OPENCODE_PERMISSION')" != *"$KEY"* ]]
    verdict "2 the key is in no argv, no config, no record, no log: under the data root only keys/deepseek holds it" $? "files: $got"

    # --- 3. reviewer, login, the user's home, a repo without instruction files ---
    rec="$REC/reviewer.json"
    id="$(AGENT_STUB_RECORD="$rec" XDG_DATA_HOME="$TEST_ROOT/xdg-data" start oc-login --role plan-reviewer --cwd "$repo2")"
    st="$(finish "$id" --cwd "$repo2")"
    want="$(jarr run --format json --title "$id" --agent sp-reviewer -m github-copilot/gpt-6-mini --dir "$repo2")"
    got="$(rjs "$rec" 'JSON.stringify(r.argv)')"
    [[ "$st" == "completed -" && "$got" == "$want" ]]
    verdict "3 reviewer argv (no --write): --agent sp-reviewer, no --variant without effort" $? "st=$st" "want: $want" "got:  $got"
    [[ "$(rjs "$rec" "$xdg")" == "- $TEST_ROOT/xdg-data - -" && -z "$(rjs "$rec" "$secrets")" && "$(rjs "$rec" "$oc_vars")" == "$OC_VARS" ]]
    verdict "3 a login profile uses the user's home: the caller's XDG_DATA_HOME passes unchanged, no XDG_* is set, no key variable" $? "xdg: $(rjs "$rec" "$xdg")" "secret-like: $(rjs "$rec" "$secrets")"
    want="$(rev_set "$TEST_ROOT/xdg-data")"
    [[ "$(rjs "$rec" 'JSON.stringify(JSON.parse(r.env.OPENCODE_CONFIG_CONTENT).instructions)')" == "[]" && "$(rjs "$rec" 'r.env.OPENCODE_PERMISSION')" == "$want" \
        && "$(rjs "$rec" 'JSON.stringify(JSON.parse(r.env.OPENCODE_CONFIG_CONTENT).agent["sp-reviewer"].permission)')" == "$want" ]]
    verdict "3 no AGENTS.md / CLAUDE.md in the repo: instructions []; OPENCODE_PERMISSION is the reviewer's set (truncation dir under the user's data dir)" $? "want: $want" "got:  $(rjs "$rec" 'r.env.OPENCODE_PERMISSION')"
    [[ -n "$(find "$TEST_ROOT/xdg-data/opencode/stub-sessions" -name 'ses_*.json' 2>/dev/null)" && ! -d "$STATE/homes/oc-login" ]]
    verdict "3 the session lives in the user's data dir; no isolated home is created for a login profile" $? "$(find "$TEST_ROOT/xdg-data" "$STATE/homes" -maxdepth 1 2>/dev/null | tr '\n' ' ')"

    # --- 4. login in an isolated home; key in the user's home ---
    rec="$REC/login-iso.json"
    id="$(AGENT_STUB_RECORD="$rec" XDG_DATA_HOME="$TEST_ROOT/xdg-data" start oc-login-iso)"
    st="$(finish "$id")"
    local iso_xdg
    iso_xdg="$(rjs "$rec" "$xdg")"
    [[ "$st" == "completed -" && "$iso_xdg" == "$STATE/homes/oc-login-iso/config $STATE/homes/oc-login-iso/data $STATE/homes/oc-login-iso/state $STATE/homes/oc-login-iso/cache" && -z "$(rjs "$rec" "$secrets")" ]]
    verdict "4 login + home isolated: XDG_* under homes/oc-login-iso override the caller's; no key variable" $? "st=$st xdg: $iso_xdg"
    run_ad profile env oc-login-iso
    got="$(printf '%s\n' "$OUT" | sed -e "s/^export [A-Z_]*='//" -e "s/'\$//" | tr '\n' ' ')"
    [[ "$RC" -eq 0 && "$got" == "$iso_xdg " && "$(grep -c '^export XDG_' <<<"$OUT")" -eq 4 ]]
    verdict "4 profile env oc-login-iso exports the same four XDG dirs the job ran with (opencode auth login lands where the job looks)" $? "out: $OUT"
    rec="$REC/key-user.json"
    id="$(AGENT_STUB_RECORD="$rec" XDG_DATA_HOME="$TEST_ROOT/xdg-data" start oc-key-user)"
    st="$(finish "$id")"
    [[ "$st" == "completed -" && "$(rjs "$rec" "$xdg")" == "- $TEST_ROOT/xdg-data - -" && "$(rjs "$rec" 'r.env.DEEPSEEK_API_KEY')" == "$KEY" ]]
    verdict "4 key + home user: the key in keyVar, the caller's XDG_* unchanged" $? "st=$st xdg: $(rjs "$rec" "$xdg")"

    # --- 5. options: permission merged into the role's agent, plugins drop OPENCODE_PURE (spec §3.6 Б) ---
    rec="$REC/opts.json"
    id="$(AGENT_STUB_RECORD="$rec" start oc-opts --write)"
    st="$(finish "$id")"
    want="$(node -e '
const impl = JSON.parse(process.argv[1]);
impl.webfetch = "allow";
impl.bash = { "git push*": "deny" };
process.stdout.write(JSON.stringify(impl));' -- "$(impl_set "$HOME/.local/share")")"
    [[ "$st" == "completed -" && "$(rjs "$rec" 'r.env.OPENCODE_PERMISSION')" == "$want" \
        && "$(rjs "$rec" 'JSON.stringify(JSON.parse(r.env.OPENCODE_CONFIG_CONTENT).agent["sp-implementer"].permission)')" == "$want" \
        && "$(rjs "$rec" 'JSON.stringify(JSON.parse(r.env.OPENCODE_CONFIG_CONTENT).agent["sp-reviewer"].permission)')" == "$(rev_set "$HOME/.local/share")" ]]
    verdict "5 options.permission merges into the writer's set (webfetch replaced in place, bash patterns added last); the reviewer's set is untouched" $? "st=$st" "want: $want" "got:  $(rjs "$rec" 'r.env.OPENCODE_PERMISSION')"
    [[ "$(rjs "$rec" '"OPENCODE_PURE" in r.env')" == false && "$(rjs "$rec" 'r.env.OPENCODE_DISABLE_AUTOUPDATE + r.env.OPENCODE_DISABLE_EXTERNAL_SKILLS')" == 11 ]]
    verdict "5 options.plugins: true leaves OPENCODE_PURE unset; the other defaults stay" $? "$(rjs "$rec" "$oc_vars")"
    # profile.env overrides the defaults of §3.6 Б (a value, or null to drop one) — unlike the mandatory settings (test 1).
    rec="$REC/override.json"
    id="$(AGENT_STUB_RECORD="$rec" start oc-override)"
    st="$(finish "$id")"
    [[ "$st" == "completed -" && "$(rjs "$rec" 'r.env.OPENCODE_PURE')" == 0 && "$(rjs "$rec" '"OPENCODE_DISABLE_AUTOUPDATE" in r.env')" == false \
        && "$(rjs "$rec" 'r.env.OPENCODE_DISABLE_EXTERNAL_SKILLS + r.env.OPENCODE_DISABLE_PROJECT_CONFIG')" == 11 ]]
    verdict "5 profile.env overrides a default (OPENCODE_PURE=0) and drops one (OPENCODE_DISABLE_AUTOUPDATE: null); the rest stays" $? "st=$st $(rjs "$rec" "$oc_vars")"
    run_ad doctor --profile oc-override
    [[ "$OUT" == *"ok env oc-override: no conflict with the mandatory settings"* ]]
    verdict "5 doctor: overriding a default is no env conflict" $? "$OUT"
    # The temp dir allowed outside the tree is the harness's own: the profile's TMPDIR, not the caller's.
    rec="$REC/tmpdir.json"
    id="$(AGENT_STUB_RECORD="$rec" start oc-tmpdir)"
    st="$(finish "$id")"
    [[ "$st" == "completed -" && "$(rjs "$rec" 'r.env.TMPDIR')" == /profile-tmp \
        && "$(rjs "$rec" 'Object.keys(JSON.parse(r.env.OPENCODE_PERMISSION).external_directory).join(" ")')" == "* /profile-tmp/* /tmp/* $HOME/.local/share/opencode/tool-output/*"* ]]
    verdict "5 profile.env TMPDIR: external_directory allows /profile-tmp/*, not the caller's \$TMPDIR" $? "st=$st $(rjs "$rec" 'r.env.OPENCODE_PERMISSION')"

    # --- 6. sandbox native: OpenCode has none — the command is unchanged, doctor says so ---
    rec="$REC/native.json"
    id="$(AGENT_STUB_RECORD="$rec" start oc-native)"
    st="$(finish "$id")"
    [[ "$st" == "completed -" && "$(rjs "$rec" 'JSON.stringify(r.argv)')" == "$(jarr run --format json --title "$id" --agent sp-reviewer -m github-copilot/gpt-6-mini --dir "$repo")" \
        && "$(rjs "$rec" "$oc_vars")" == "$OC_VARS" ]]
    verdict "6 sandbox native: the same argv and OPENCODE_* as without it" $? "st=$st argv: $(rjs "$rec" 'r.argv')"
    run_ad doctor --profile oc-native
    [[ "$OUT" == *'WARN sandbox oc-native: opencode has no sandbox of its own; "sandbox": "native" does nothing — use "wrap"'* ]]
    verdict "6 doctor: one WARN line for sandbox native, pointing at wrap" $? "$OUT"

    # --- 7. stdin is closed after the prompt (stdin-wait) ---
    rec="$REC/stdin.json"
    t0="$(now_ms)"
    id="$(AGENT_STUB_MODE=stdin-wait AGENT_STUB_RECORD="$rec" start oc-login)"
    st="$(finish "$id")"
    t1="$(now_ms)"
    run_ad result "$id"
    [[ "$st" == "completed -" && "$OUT" == $'DONE\nread '"$prompt_bytes"' bytes from stdin: ## Headless run' && $((t1 - t0)) -lt 15000 ]]
    verdict "7 stdin-wait: OpenCode reads stdin to EOF and gets the whole prompt — the run does not hang ($((t1 - t0)) ms)" $? "st=$st out=$OUT"

    # --- 8. the outcome: success by the answer, not the exit code; blocked; launch; export (spec §3.6 А9, §3.8) ---
    local cases="exit1-valid error-then-recover multi-message late-session auto-reject agent-not-found text-then-error malformed fail model-not-found no-text-events export-fail tool-step-exit1 tool-step-killed silent-final-step"
    local ids="" c
    for c in $cases; do
        case "$c" in
            export-fail) id="$(AGENT_STUB_MODE=no-text-events AGENT_STUB_EXPORT=fail start oc-login)" ;;
            no-text-events) id="$(AGENT_STUB_MODE=no-text-events AGENT_STUB_CALL_LOG="$TEST_ROOT/export-calls.txt" start oc-key)" ;;
            *) id="$(AGENT_STUB_MODE="$c" start oc-login)" ;;
        esac
        ids="$ids $c=$id"
    done
    local entry exit_code text
    for entry in $ids; do
        c="${entry%%=*}"
        id="${entry#*=}"
        st="$(finish "$id")"
        sj="$(st_json "$id")"
        exit_code="$(jfield job.exitCode <<<"$sj")"
        text="$(jfield job.response <<<"$sj")"
        case "$c" in
            exit1-valid)
                [[ "$st" == "completed -" && "$exit_code" == 1 && "$text" == $'DONE\nvalid despite exit 1' ]]
                verdict "8 exit 1 with a valid answer is success (the exit code is informational)" $? "st=$st exit=$exit_code text=$text" ;;
            error-then-recover)
                [[ "$st" == "completed -" && "$exit_code" == 1 && "$text" == $'DONE\nrecovered after compaction' ]]
                verdict "8 a context overflow compacted away: error event, then the answer, exit 1 → completed" $? "st=$st exit=$exit_code text=$text" ;;
            multi-message)
                [[ "$st" == "completed -" && "$text" == $'DONE\nsecond part' ]]
                verdict "8 the answer is the text parts of the last messageID, in order (not the earlier message's text)" $? "st=$st text=$text" ;;
            late-session)
                sid="$(jfield job.sessionId <<<"$sj")"
                [[ "$st" == "completed -" && "$sid" == ses_* ]]
                verdict "8 late session: events without a session id first, the id from a later event" $? "st=$st sessionId=$sid" ;;
            auto-reject)
                [[ "$st" == "failed blocked" && "$exit_code" == 0 && "$(jfield job.errorText <<<"$sj")" == *"permission requested: bash (npm test); auto-rejecting"* ]]
                verdict "8 a surviving ask (auto-rejecting on stderr, exit 0, a text before it) → failed/blocked" $? "st=$st exit=$exit_code" "$(jfield job.errorText <<<"$sj")" ;;
            agent-not-found)
                [[ "$st" == "failed launch" && "$exit_code" == 0 && "$(jfield job.errorText <<<"$sj")" == *'agent "sp-reviewer" not found'*"fell back to its default agent"* ]]
                verdict "8 'agent … not found' → failed/launch, although OpenCode answered with its default agent" $? "st=$st" "$(jfield job.errorText <<<"$sj")" ;;
            text-then-error)
                [[ "$st" == "failed server" && "$exit_code" == 1 ]]
                verdict "8 an answer followed by an error event (503) → failed/server" $? "st=$st exit=$exit_code" ;;
            malformed)
                [[ "$st" == "failed malformed" ]]
                verdict "8 no events, exit 0 → failed/malformed" $? "st=$st" ;;
            fail)
                [[ "$st" == "failed crash" ]]
                verdict "8 an unrecognised error on stderr, exit 1 → failed/crash" $? "st=$st" ;;
            model-not-found)
                [[ "$st" == "failed model-not-selected" ]]
                verdict "8 'Model not found: p/m' on stderr → failed/model-not-selected" $? "st=$st" ;;
            no-text-events)
                sid="$(jfield job.sessionId <<<"$sj")"
                [[ "$st" == "completed -" && "$text" == $'DONE\nfrom the session export' && "$(jfield job.meta.export <<<"$sj")" == "final answer" \
                    && "$(jfield job.reportedModel <<<"$sj")" == deepseek/deepseek-v4-pro && "$(grep '^export' "$TEST_ROOT/export-calls.txt" 2>/dev/null)" == "export $sid key=unset" ]]
                verdict "8 no text event: finalize runs 'opencode export <session>' (in the job's env, without the key) and takes the last assistant message" $? "st=$st text=$text" "calls: $(cat "$TEST_ROOT/export-calls.txt" 2>/dev/null)" "$sj" ;;
            export-fail)
                [[ "$st" == "failed malformed" && "$(jfield job.meta.export <<<"$sj")" == "failed (exit 1)" ]]
                verdict "8 no text event and a failing export → failed/malformed" $? "st=$st" "$(jfield job.meta <<<"$sj")" ;;
            tool-step-exit1)
                [[ "$st" == "failed crash" && "$exit_code" == 1 && -z "$text" && "$(jfield job.meta.export <<<"$sj")" == "no final answer" ]]
                verdict "8 a narration before a tool call, then exit 1 mid-turn (no error event) → failed/crash, not its text; the unfinished exported message is no answer" $? "st=$st exit=$exit_code text=$text" "$(jfield job.meta <<<"$sj")" ;;
            tool-step-killed)
                [[ "$st" == "failed crash" && "$(jfield job.signal <<<"$sj")" == SIGKILL && -z "$text" && -z "$(jfield job.meta.export <<<"$sj")" ]]
                verdict "8 the same turn killed by SIGKILL → failed/crash, no export" $? "st=$st signal=$(jfield job.signal <<<"$sj") text=$text" ;;
            silent-final-step)
                [[ "$st" == "failed malformed" && "$exit_code" == 0 && -z "$text" && "$(jfield job.meta.export <<<"$sj")" == "no final answer" ]]
                verdict "8 a final step that ends 'stop' without text, after a narrated tool call → failed/malformed, not the narration" $? "st=$st text=$text" "$(jfield job.meta <<<"$sj")" ;;
        esac
    done

    # --- 9. error classes from the error event (spec §3.8): quota only with its markers ---
    local pairs="auth:auth auth-401:auth quota:quota quota-plan:quota quota-go:quota quota-free:quota rate-limit:rate-limit overloaded:rate-limit server:server context:context balance:crash unknown:crash"
    ids=""
    local pair cls
    for pair in $pairs; do
        id="$(AGENT_STUB_MODE=error AGENT_STUB_CLASS="${pair%%:*}" start oc-login)"
        ids="$ids $pair=$id"
    done
    id="$(AGENT_STUB_MODE=exit0-error AGENT_STUB_CLASS=auth start oc-login)"
    ids="$ids exit0:auth=$id"
    id="$(AGENT_STUB_MODE=quota start oc-login)"
    ids="$ids mode-quota:quota=$id"
    id="$(AGENT_STUB_MODE=rate-limit start oc-login)"
    ids="$ids mode-rate-limit:rate-limit=$id"
    id="$(AGENT_STUB_MODE=context start oc-login)"
    ids="$ids mode-context:context=$id"
    for entry in $ids; do
        pair="${entry%%=*}"
        id="${entry#*=}"
        cls="${pair%%:*}"
        want="${pair#*:}"
        st="$(finish "$id")"
        sj="$(st_json "$id")"
        case "$cls" in
            exit0)
                [[ "$st" == "failed auth" && "$(jfield job.exitCode <<<"$sj")" == 0 ]]
                verdict "9 an error event with exit 0 is still a failure: ProviderAuthError → auth" $? "st=$st exit=$(jfield job.exitCode <<<"$sj")" ;;
            *)
                [[ "$st" == "failed $want" && "$(jfield job.exitCode <<<"$sj")" == 1 ]]
                verdict "9 error ${cls} ($(jfield job.errorText <<<"$sj" | head -c 70)) → $want" $? "st=$st" ;;
        esac
    done

    # --- 10. resume: -s <session> with the same --dir and data dir (spec §3.6 А12) ---
    sid="$(st_json "$writer_id" | jfield job.sessionId)"
    rec="$REC/resume.json"
    id="$(AGENT_STUB_MODE=resume AGENT_STUB_RECORD="$rec" start oc-key --write --resume-task "$writer_id")"
    st="$(finish "$id")"
    run_ad result "$id"
    want="$(jarr run --format json --title "$id" --agent sp-implementer -m deepseek/deepseek-v4-pro --variant high -s "$sid" --dir "$repo")"
    [[ "$st" == "completed -" && "$(rjs "$rec" 'JSON.stringify(r.argv)')" == "$want" && "$OUT" == $'DONE\nresumed '"$sid" \
        && "$(st_json "$id" | jfield job.resumeOf)" == "$writer_id" && "$(st_json "$id" | jfield job.sessionId)" == "$sid" ]]
    verdict "10 --resume-task: -s <session id> before --dir, the same --dir and isolated home; the session continues" $? "st=$st out=$OUT" "want: $want" "got:  $(rjs "$rec" 'JSON.stringify(r.argv)')"
    local resumed="$id"
    rm -f "$STATE/homes/oc-key/data/opencode/stub-sessions/$sid.json"
    id="$(AGENT_STUB_MODE=resume start oc-key --write --resume-task "$resumed")"
    st="$(finish "$id")"
    [[ "$st" == "failed resume-lost" && "$(st_json "$id" | jfield job.exitCode)" == 1 ]]
    verdict "10 'Session not found' (exit 1) → failed/resume-lost" $? "st=$st"
    run_ad task --profile oc-login --background --prompt-file "$PROMPT" --resume-task "$writer_id"
    [[ "$RC" -eq 2 && "$ERR" == *"ran on profile oc-key, not oc-login"* ]]
    verdict "10 a session does not move to another profile: exit 2" $? "rc=$RC err: $ERR"
    id="$(XDG_DATA_HOME="$TEST_ROOT/xdg-a" start oc-login)"
    st="$(finish "$id")"
    run_ad task --profile oc-login --background --prompt-file "$PROMPT" --resume-task "$id"
    ok=$RC
    local errb="$ERR"
    id2="$(AGENT_STUB_MODE=resume XDG_DATA_HOME="$TEST_ROOT/xdg-a" start oc-login --resume-task "$id")"
    [[ "$st" == "completed -" && "$ok" -eq 2 && "$errb" == *"cannot resume $id on oc-login: its session lives in data dir $TEST_ROOT/xdg-a, not $HOME/.local/share (XDG_DATA_HOME); dispatch --fresh"* \
        && "$(finish "$id2")" == "completed -" ]]
    verdict "10 resumeCheck: another data dir (XDG_DATA_HOME) is refused with exit 2; the same one resumes" $? "rc=$ok err: $errb" "resume: $(finish "$id2")"
    # A resumed run that fails before any message of its own: the session's last assistant message is the previous
    # job's answer, which the export fallback must not take.
    id="$(AGENT_STUB_MODE=resume-error XDG_DATA_HOME="$TEST_ROOT/xdg-a" start oc-login --resume-task "$id2")"
    st="$(finish "$id")"
    sj="$(st_json "$id")"
    [[ "$st" == "failed crash" && -z "$(jfield job.response <<<"$sj")" && "$(jfield job.meta.export <<<"$sj")" == "no message of this run" ]]
    verdict "10 a resumed run that errs before its first message → failed/crash; export's previous answer is not this run's" $? "st=$st" "$(jfield job.meta <<<"$sj")"

    # --- 11. cancel: SIGTERM to the group and the detached descendants, 5 s, SIGKILL (spec §3.6 А8) ---
    local pids="$TEST_ROOT/pids.txt" child d1 d2 g1 g2
    rm -f "$pids"
    rec="$REC/cancel-tree.json"
    id="$(AGENT_STUB_MODE=detached-bash AGENT_STUB_PIDS="$pids" AGENT_STUB_RECORD="$rec" start oc-login)"
    wait_file "$rec" || true
    wait_lines "$pids" 2 || true
    child="$(rjs "$rec" 'r.pid')"
    d1="$(sed -n 1p "$pids")"
    d2="$(sed -n 2p "$pids")"
    g1="$(ps -o pgid= -p "$d1" | tr -d ' ')"
    g2="$(ps -o pgid= -p "$d2" | tr -d ' ')"
    t0="$(now_ms)"
    OUT="$(ad cancel "$id")"
    t1="$(now_ms)"
    local jobs_log
    jobs_log="$(find "$STATE/state" -name "$id.log" | head -1)"
    [[ -n "$child" && -n "$d1" && -n "$d2" && "$g1" != "$child" && "$g2" != "$child" && "$g1" != "$g2" && "$OUT" == "cancelled $id" ]] && gone "$child" "$d1" "$d2" \
        && [[ "$(st_json "$id" | jfield job.status)" == cancelled ]]
    verdict "11 cancel kills OpenCode and the bash tools it spawned detached (own process groups, SIGTERM ignored)" $? "harness=$child d1=$d1/$g1 d2=$d2/$g2 out=$OUT"
    grep -q "cancel: SIGTERM to groups" "$jobs_log" && grep -q "cancel: SIGKILL" "$jobs_log" && (((t1 - t0) >= 4500))
    verdict "11 the ladder: SIGTERM to every group of the snapshot, the 5 s step, then SIGKILL ($((t1 - t0)) ms)" $? "$(grep 'cancel' "$jobs_log")"
    local sigs="$TEST_ROOT/signals.txt"
    rm -f "$sigs"
    rec="$REC/cancel-trap.json"
    id="$(AGENT_STUB_MODE=trap-signals AGENT_STUB_SIGNALS="$sigs" AGENT_STUB_RECORD="$rec" start oc-login)"
    wait_file "$rec" || true
    child="$(rjs "$rec" 'r.pid')"
    t0="$(now_ms)"
    ad cancel "$id" >/dev/null
    t1="$(now_ms)"
    [[ "$(tr '\n' ' ' <"$sigs" 2>/dev/null)" == "SIGTERM " ]] && gone "$child" && (((t1 - t0) >= 4500))
    verdict "11 signal order as the harness sees it: one SIGTERM, never SIGINT or SIGHUP, then SIGKILL after 5 s ($((t1 - t0)) ms)" $? "signals: $(tr '\n' ' ' <"$sigs" 2>/dev/null)"
    rec="$REC/cancel-hang.json"
    id="$(AGENT_STUB_MODE=hang AGENT_STUB_RECORD="$rec" start oc-login)"
    wait_file "$rec" || true
    child="$(rjs "$rec" 'r.pid')"
    t0="$(now_ms)"
    OUT="$(ad cancel "$id")"
    t1="$(now_ms)"
    gone "$child" && [[ "$OUT" == "cancelled $id" && "$(st_json "$id" | jfield job.status)" == cancelled ]] && (((t1 - t0) < 4500))
    verdict "11 OpenCode without a SIGTERM handler ends on the first step: cancelled in $((t1 - t0)) ms" $? "out=$OUT"

    # --- 12. timeout ---
    id="$(AGENT_STUB_MODE=hang start oc-fast)"
    st="$(wait_status "$id" 'failed|completed|cancelled' 30)"
    [[ "$st" == failed && "$(st_json "$id" | jfield job.errorClass)" == timeout ]]
    verdict "12 the job's wall-clock limit (timeoutMin) → failed/timeout (OpenCode's own retries are invisible in run JSON)" $? "st=$st/$(st_json "$id" | jfield job.errorClass)"

    # --- 13. secrets: the key printed by the harness is redacted in the log, status and result (spec §3.6 А11) ---
    id="$(AGENT_STUB_MODE=leak-secret AGENT_STUB_SECRET_VAR=DEEPSEEK_API_KEY XDG_DATA_HOME="$TEST_ROOT/xdg-data" start oc-key-user)"
    st="$(finish "$id")"
    run_ad result "$id"
    got="$(grep -rlF "$KEY" "$STATE" 2>/dev/null | tr '\n' ' ')"
    [[ "$st" == "completed -" && "$OUT" == *"key=<redacted>"* && "$OUT" != *"$KEY"* && "$got" == "$STATE/keys/deepseek " ]] && grep -rqF "<redacted>" "$STATE/state"
    verdict "13 a key the harness prints reaches no result, record or log: <redacted>" $? "st=$st out=$OUT files: $got"

    # --- 14. discovery: version, OpenCode 2, flags, binary (spec §2, §3.2) ---
    id="$(AGENT_STUB_VERSION=2.1.0 start oc-login)"
    st="$(finish "$id")"
    sj="$(st_json "$id")"
    [[ "$st" == "failed launch" && "$(jfield job.note <<<"$sj")" == *"is OpenCode 2.1.0; the opencode adapter runs OpenCode 1.19.x"*"npm i -g opencode-ai@1.19.3"* ]]
    verdict "14 OpenCode 2 (by its version) → failed/launch with the hint to install v1" $? "st=$st note: $(jfield job.note <<<"$sj")"
    id="$(AGENT_STUB_VERSION=1.19.9 AGENT_STUB_HELP_DROP=--variant start oc-login)"
    st="$(finish "$id")"
    [[ "$st" == "failed launch" && "$(st_json "$id" | jfield job.note)" == *"\`run --help\` does not list the required flag(s) --variant"* ]]
    verdict "14 a required run flag missing from 'opencode run --help' → failed/launch" $? "st=$st note: $(st_json "$id" | jfield job.note)"
    id="$(start oc-nobin)"
    st="$(finish "$id")"
    [[ "$st" == "failed launch" && "$(st_json "$id" | jfield job.note)" == *"install OpenCode 1.19.x: npm i -g opencode-ai@1.19.3"* ]]
    verdict "14 no binary → failed/launch with the install line" $? "st=$st note: $(st_json "$id" | jfield job.note)"

    # --- 15. doctor (no model call) and the probe ---
    run_ad doctor --profile oc-login
    [[ "$RC" -eq 0 && "$OUT" == *"ok harness oc-login: $OC 1.19.3"* && "$OUT" != *"WARN version"* && "$OUT" == *"ok env oc-login: no conflict with the mandatory settings"* \
        && "$OUT" == *"WARN login oc-login: opencode auth list shows no login for github-copilot (it lists: none); the user logs in (opencode auth login)"* && "$(tail -1 <<<"$OUT")" == "doctor: ok" ]]
    verdict "15 doctor: binary and verified version, env, and no Copilot login in 'opencode auth list' → WARN" $? "rc=$RC" "$OUT"
    mkdir -p "$HOME/.local/share/opencode"
    printf '{"github-copilot":{"type":"oauth"}}\n' >"$HOME/.local/share/opencode/stub-auth.json"
    run_ad doctor --profile oc-login
    [[ "$RC" -eq 0 && "$OUT" == *"ok login oc-login: opencode auth list names github-copilot"* ]]
    verdict "15 doctor: the login listed by 'opencode auth list' (names only) → ok" $? "$OUT"
    rm -f "$TEST_ROOT/calls.txt"
    AGENT_STUB_CALL_LOG="$TEST_ROOT/calls.txt" run_ad doctor --profile oc-login-iso
    ok=$?
    [[ "$OUT" == *"WARN login oc-login-iso: opencode auth list shows no login for github-copilot (it lists: none); the user logs in in the isolated home (eval \"\$(agent-dispatch profile env oc-login-iso)\"; opencode auth login)"* \
        && "$(grep '^auth-list' "$TEST_ROOT/calls.txt")" == "auth-list $STATE/homes/oc-login-iso/data" ]]
    verdict "15 doctor of an isolated login runs 'opencode auth list' in that home (the user's login does not count)" $? "$OUT" "calls: $(cat "$TEST_ROOT/calls.txt" 2>/dev/null)"
    mkdir -p "$STATE/homes/oc-login-iso/data/opencode"
    printf '{"github-copilot":{"type":"oauth"}}\n' >"$STATE/homes/oc-login-iso/data/opencode/stub-auth.json"
    run_ad doctor --profile oc-login-iso
    [[ "$OUT" == *"ok login oc-login-iso: opencode auth list names github-copilot"* ]]
    verdict "15 … and a login in the isolated home → ok" $? "$OUT"
    # Provider `opencode` (Zen): the auth.json path in the header ("…/opencode/auth.json") and a set OPENCODE_API_KEY
    # in the Environment block are no stored login.
    mkdir -p "$STATE/homes/oc-zen/data/opencode"
    printf '{"opencode-go":{"type":"api"}}\n' >"$STATE/homes/oc-zen/data/opencode/stub-auth.json"
    AGENT_ENV_PASSTHROUGH="$AGENT_ENV_PASSTHROUGH,OPENCODE_API_KEY" OPENCODE_API_KEY=zen-stub-value run_ad doctor --profile oc-zen
    [[ "$OUT" == *"WARN login oc-zen: opencode auth list shows no login for opencode (it lists: OpenCode Go); the user logs in in the isolated home"* ]]
    verdict "15 doctor: only credential rows count — not the auth.json path, not the Environment block, not OpenCode Go for opencode" $? "$OUT"
    printf '{"opencode-go":{"type":"api"},"opencode":{"type":"api"}}\n' >"$STATE/homes/oc-zen/data/opencode/stub-auth.json"
    run_ad doctor --profile oc-zen
    [[ "$OUT" == *"WARN login oc-zen: opencode auth list shows no login for opencode (it lists: OpenCode Go, OpenCode Zen)"* ]]
    verdict "15 doctor: a provider listed under a display name other than its id is a WARN that names what is listed" $? "$OUT"
    run_ad doctor --profile oc-key-user
    [[ "$RC" -eq 0 && "$OUT" == *'WARN home oc-key-user: "home": "user" with a key: a deepseek login stored by opencode auth login in your data dir wins over DEEPSEEK_API_KEY'* && "$OUT" == *"ok key oc-key-user: deepseek in"* ]]
    verdict "15 doctor: a key with home user → WARN (a stored login of the provider would win)" $? "$OUT"
    run_ad doctor --profile oc-ask
    [[ "$OUT" == *"WARN permission oc-ask: options.permission asks for bash: a headless run auto-rejects an ask and ends blocked"* ]]
    verdict "15 doctor: an 'ask' in options.permission → WARN (it can only end blocked)" $? "$OUT"
    run_ad doctor --profile oc-conflict
    [[ "$RC" -eq 1 && "$OUT" == *"FAIL env oc-conflict: profile env OPENCODE_DISABLE_PROJECT_CONFIG conflicts with a mandatory setting"* ]]
    verdict "15 doctor: profile env against a mandatory setting → FAIL" $? "rc=$RC" "$OUT"
    AGENT_STUB_VERSION=1.19.4 run_ad doctor --profile oc-login
    [[ "$RC" -eq 0 && "$OUT" == *"WARN version oc-login: opencode 1.19.4 was not checked; checked: 1.19.3"* ]]
    verdict "15 doctor: an unverified version is one WARN line, not a refusal" $? "$OUT"
    AGENT_STUB_VERSION=2.1.0 run_ad doctor --profile oc-login
    [[ "$RC" -eq 1 && "$(grep -c 'OpenCode 2.1.0' <<<"$OUT")" -eq 1 && "$OUT" == *"FAIL harness oc-login: $OC is OpenCode 2.1.0; the opencode adapter runs OpenCode 1.19.x"* ]]
    verdict "15 doctor: OpenCode 2 is recognised by its version, in one FAIL line" $? "rc=$RC" "$OUT"
    rec="$REC/probe.json"
    AGENT_STUB_MODE=ok AGENT_STUB_RESPONSE=PONG AGENT_STUB_RECORD="$rec" run_ad doctor --profile oc-login --probe
    [[ "$RC" -eq 0 && "$(tail -1 <<<"$OUT")" == "ok probe oc-login: PONG in "* && "$(rjs "$rec" 'r.argv.slice(0, -1).join(" ")')" == "run --format json --title probe --agent sp-reviewer -m github-copilot/gpt-6-mini --dir" \
        && "$(rjs "$rec" 'r.argv.at(-1)')" == "$STATE/probe/oc-login-"* && "$(rjs "$rec" 'r.stdin')" == "Reply with exactly: PONG" ]]
    verdict "15 doctor --probe: one PONG turn on the read-only reviewer agent, title probe, in a scratch dir" $? "rc=$RC" "$OUT" "argv: $(rjs "$rec" 'r.argv' 2>/dev/null)"

    # --- 16. the pure parts of the adapter ---
    cat >"$TEST_ROOT/unit.mjs" <<'EOF'
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [adapterPath, corePath, root] = process.argv.slice(2);
const mod = await import(pathToFileURL(adapterPath).href);
const core = await import(pathToFileURL(corePath).href);
const oc = mod.default;
const results = [];
const check = (label, cond, detail = "") => results.push(cond ? `PASS ${label}` : `FAIL ${label}${detail ? ` :: ${detail}` : ""}`);
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// mergePermission / tempDirRules
const base = mod.basePermission(false, { tmpdir: "/t/" });
let m = mod.mergePermission(base, { bash: { "npm test*": "allow" } });
check("merge: patterns go after a key's patterns", eq(Object.keys(m.bash), ["*", "git show*", "git diff*", "git log*", "git status*", "npm test*"]) && m.bash["npm test*"] === "allow");
m = mod.mergePermission(base, { edit: { "docs/*": "allow" } });
check("merge: a plain action becomes the * pattern", eq(m.edit, { "*": "deny", "docs/*": "allow" }));
m = mod.mergePermission(base, { webfetch: "allow", lsp: "allow" });
check("merge: an action replaces in place, a new key goes last", m.webfetch === "allow" && Object.keys(m).at(-1) === "lsp" && Object.keys(m).indexOf("webfetch") === Object.keys(base).indexOf("webfetch"));
check("merge: the base set is not changed", base.webfetch === "deny" && base.edit === "deny" && !("npm test*" in base.bash));
check("tempDirRules: $TMPDIR, /tmp and the truncation dir under the data dir", eq(mod.tempDirRules({ tmpdir: "/t/", dataDir: "/d", platform: "linux" }), { "/t/*": "allow", "/tmp/*": "allow", "/d/opencode/tool-output/*": "allow" }) && eq(mod.tempDirRules({}), { "/tmp/*": "allow" }) && eq(mod.tempDirRules({ tmpdir: "/tmp/" }), { "/tmp/*": "allow" }) && eq(mod.tempDirRules({ tmpdir: "rel" }), { "/tmp/*": "allow" }));
check("tempDirRules: macOS adds the /private names of /tmp and /var dirs, nothing else", eq(Object.keys(mod.tempDirRules({ tmpdir: "/var/folders/x/T/", dataDir: "/Users/u/.local/share", platform: "darwin" })), ["/var/folders/x/T/*", "/tmp/*", "/Users/u/.local/share/opencode/tool-output/*", "/private/var/folders/x/T/*", "/private/tmp/*"]));

// classifyError: OpenCode error objects → classes (spec §3.8, [02 §11])
const api = (statusCode, message, responseBody) => ({ name: "APIError", data: { message, statusCode, isRetryable: false, ...(responseBody ? { responseBody } : {}) } });
const table = [
  [{ name: "ProviderAuthError", data: { providerID: "x", message: "bad key" } }, "auth"],
  [api(401, "Unauthorized"), "auth"],
  [api(403, "Forbidden"), "auth"],
  [{ name: "UnknownError", data: { message: "Unauthorized: request was blocked by a gateway" } }, "auth"],
  [{ name: "ProviderInitError", data: { message: 'Failed to initialize provider "x". Check credentials and configuration.' } }, "auth"],
  [api(429, "Quota exceeded. Check your plan and billing details.", '{"error":{"type":"insufficient_quota"}}'), "quota"],
  [api(429, "Quota exceeded. Check your plan and billing details."), "rate-limit"],
  [api(429, "Too Many Requests"), "rate-limit"],
  [api(403, "plan", '{"detail":{"code":"usage_not_included"}}'), "quota"],
  [{ name: "GoUsageLimitError", data: { message: "limit" } }, "quota"],
  [{ name: "FreeUsageLimitError", data: { message: "Free usage exceeded, subscribe to Go" } }, "quota"],
  [api(402, "Insufficient Balance"), null],
  [api(529, "Overloaded"), "rate-limit"],
  [api(503, "Service Unavailable"), "server"],
  [{ name: "ProviderHeaderTimeoutError", data: { message: "Provider response headers timed out after 300000ms" } }, "server"],
  [{ name: "UnknownError", data: { message: "fetch failed: ECONNREFUSED" } }, "server"],
  [{ name: "ContextOverflowError", data: { message: "Input exceeds context window of this model" } }, "context"],
  [api(400, "This model's maximum context length is exceeded", '{"error":{"code":"context_length_exceeded"}}'), "context"],
  [{ name: "ProviderModelNotFoundError", data: { providerID: "x", modelID: "y" } }, "model-not-selected"],
  [api(404, "Not Found"), "model-not-selected"],
  [{ name: "MessageAbortedError", data: { message: "aborted" } }, null],
  [{ name: "UnknownError", data: { message: "Session not found" } }, "resume-lost"],
];
for (const [error, want] of table) {
  const got = mod.classifyError(error);
  check(`classifyError ${mod.errorText(error).slice(0, 60)} → ${want}`, got === want, `got ${got}`);
}

// reduce
const ev = (type, sid, data) => ({ type, timestamp: 1, ...(sid === undefined ? {} : { sessionID: sid }), ...data });
const text = (sid, msg, id, t) => ev("text", sid, { part: { id, messageID: msg, type: "text", text: t } });
const err = (sid, error) => ev("error", sid, { error });
const fin = (sid, msg, input, output, cost) => ev("step_finish", sid, { part: { messageID: msg, type: "step-finish", reason: "stop", cost, tokens: { input, output, reasoning: 1, cache: { read: 2, write: 3 } } } });
let r = oc.reduce({ events: [ev("step_start", undefined, {}), ev("step_start", "", {}), text("s1", "m1", "p1", "first"), fin("s1", "m1", 10, 2, 0.5), text("s1", "m2", "p2", "A"), text("s1", "m2", "p3", "B"), text("s1", "m2", "p2", "A2"), fin("s1", "m2", 5, 1, 0.25)], stderrTail: "", exit: { code: 0 } });
check("reduce: the last message's parts in order (a part sent twice keeps its place and its last text)", r.ok === true && r.response === "A2\nB", JSON.stringify(r));
check("reduce: the first non-empty sessionID", r.sessionId === "s1");
check("reduce: usage sums the step_finish parts", eq(r.usage, { input: 15, output: 3, reasoning: 2, cacheRead: 4, cacheWrite: 6, cost: 0.75, steps: 2 }), JSON.stringify(r.usage));
r = oc.reduce({ events: [err("s1", api(400, "x", "context_length_exceeded")), text("s1", "m2", "p1", "DONE"), fin("s1", "m2", 1, 1, 0)], stderrTail: "", exit: { code: 1 } });
check("reduce: an answer after the last error is success, whatever the exit code", r.ok === true && r.response === "DONE");
// A narration before a tool call is no answer: the last message is the last one of any part, and its step must finish.
const step = (sid, msg) => ev("step_start", sid, { part: { messageID: msg, type: "step-start" } });
const tool = (sid, msg) => ev("tool_use", sid, { part: { messageID: msg, type: "tool", tool: "read", state: { status: "completed" } } });
const finR = (sid, msg, reason) => ev("step_finish", sid, { part: { messageID: msg, type: "step-finish", reason, cost: 0, tokens: { input: 1, output: 1, reasoning: 0, cache: { read: 0, write: 0 } } } });
const narrated = [step("s1", "m1"), text("s1", "m1", "p1", "Let me look at the tree first."), tool("s1", "m1"), finR("s1", "m1", "tool-calls"), step("s1", "m2")];
for (const exit of [{ code: null, signal: "SIGKILL" }, { code: 1, signal: null }, { code: 0, signal: null }]) {
  r = oc.reduce({ events: narrated, stderrTail: "", exit });
  check(`reduce: a narration, a tool call and the next step cut off (${exit.signal ?? `exit ${exit.code}`}) → no answer`, r.ok === false && r.response === null && r.errorClass === null && /did not finish/.test(r.errorText), JSON.stringify(r));
}
r = oc.reduce({ events: [...narrated, finR("s1", "m2", "stop")], stderrTail: "", exit: { code: 0 } });
check("reduce: a final step that ends 'stop' without text → no answer (not the narration)", r.ok === false && r.response === null);
r = oc.reduce({ events: [...narrated, text("s1", "m2", "p9", "DONE"), finR("s1", "m2", "stop")], stderrTail: "", exit: { code: null, signal: "SIGKILL" } });
check("reduce: a finished final message is the answer even if the process was killed afterwards", r.ok === true && r.response === "DONE");
for (const reason of ["tool-calls", "length", "error", "content-filter", "", undefined]) {
  r = oc.reduce({ events: [step("s1", "m1"), text("s1", "m1", "p1", "DONE"), finR("s1", "m1", reason)], stderrTail: "", exit: { code: 0 } });
  check(`reduce: a text whose step finished with ${JSON.stringify(reason)} is no answer`, r.ok === false);
}
r = oc.reduce({ events: [step("s1", "m1"), text("s1", "m1", "p1", "DONE")], stderrTail: "", exit: { code: 0 } });
check("reduce: a text without its step_finish is no answer", r.ok === false && /did not finish/.test(r.errorText));
r = oc.reduce({ events: [text("s1", "m1", "p1", "DONE"), err("s1", api(503, "x"))], stderrTail: "", exit: { code: 1 } });
check("reduce: an answer before the last error is not", r.ok === false && r.errorClass === "server" && r.errorText === "APIError 503: x");
r = oc.reduce({ events: [text("s1", "m1", "p1", "DONE")], stderrTail: "! permission requested: edit (a.txt); auto-rejecting\n", exit: { code: 0 } });
check("reduce: auto-rejecting → blocked, even after a text", r.ok === false && r.errorClass === "blocked");
r = oc.reduce({ events: [text("s1", "m1", "p1", "DONE")], stderrTail: 'Warning: agent "sp-reviewer" not found\n', exit: { code: 0 } });
check("reduce: agent … not found → launch, even with an answer", r.ok === false && r.errorClass === "launch");
r = oc.reduce({ events: [], stderrTail: "Error: Session not found\n", exit: { code: 1 } });
check("reduce: Session not found → resume-lost", r.errorClass === "resume-lost");
r = oc.reduce({ events: [text("s1", "m1", "p1", "  \n")], stderrTail: "", exit: { code: 0 } });
check("reduce: a blank answer is none", r.ok === false && r.errorClass === null);
r = oc.reduce({ events: [], stderrTail: "", exit: { code: 0 } });
check("reduce: no events → unclassified (the core makes it malformed)", r.ok === false && r.errorClass === null && r.sessionId === null && r.usage === null);

// the adapter's patterns over stderr-only failures, through the core's verdict
const outcome = (stderr, code = 1) => core.classifyOutcome({ io: { events: [], stdout: "", stderrTail: stderr, exit: { code, signal: null } }, reduced: oc.reduce({ events: [], stderrTail: stderr, exit: { code } }), patterns: oc.patterns }).errorClass;
check("patterns: Model not found → model-not-selected", outcome("Error: Model not found: x/y. Did you mean: x/z?\n") === "model-not-selected");
check("patterns: provider init → auth", outcome('Error: Failed to initialize provider "deepseek". Check credentials and configuration.\n') === "auth");
check("patterns: an invalid config → launch", outcome("Error: Config file at /x/opencode.json is not valid JSON(C)\n") === "launch");
check("patterns: ECONNREFUSED → server", outcome("Error: connect ECONNREFUSED 127.0.0.1:443\n") === "server");
check("patterns: anything else with exit 1 → crash", outcome("Error: something else\n") === "crash");

// finalize: export only when the stream had neither an answer nor a recognised error
const execs = [];
// The job: its stream had message m9 (this run's), it started at T0; an exported message is this run's by id or time.
const T0 = Date.parse("2026-10-21T10:00:00.000Z");
const runIo = (exit) => ({ exit, events: [{ type: "step_start", sessionID: "s1", part: { messageID: "m9", type: "step-start" } }] });
const fjob = (exit = { code: 0, signal: null }, events = undefined) => ({ reduced: { ok: false, errorClass: null, sessionId: "s1" }, record: { startedAt: new Date(T0).toISOString() }, io: events ? { exit, events } : runIo(exit) });
const exportOf = (assistantInfo, parts) => ({ status: 0, stdout: `${JSON.stringify({ info: { id: "s1" }, messages: [{ info: { role: "user" }, parts: [] }, { info: { id: "m9", time: { created: T0 + 5 }, role: "assistant", providerID: "p", modelID: "m", ...assistantInfo }, parts }] })}\n` });
const fctx = (reply) => ({ execHarness: (args) => (execs.push(args), reply) });
let f = await oc.finalize(fjob(), fctx(exportOf({ finish: "stop" }, [{ type: "text", text: "DONE" }])));
check("finalize: export s1 → the last assistant message's text", eq(execs.at(-1), ["export", "s1"]) && f.ok === true && f.response === "DONE" && f.reportedModel === "p/m", JSON.stringify(f));
f = await oc.finalize(fjob(), fctx(exportOf({ finish: "tool-calls" }, [{ type: "text", text: "half" }])));
check("finalize: a message that ended in tool calls is no answer", f.ok === undefined && f.meta.export === "no final answer");
f = await oc.finalize(fjob(), fctx(exportOf({}, [{ type: "text", text: "partial" }])));
check("finalize: a message without a finish reason (cut off mid-stream) is no answer", f.ok === undefined && f.meta.export === "no final answer");
f = await oc.finalize(fjob({ code: 1, signal: null }), fctx(exportOf({ error: { name: "ProviderAuthError", data: { message: "x" } } }, [])));
check("finalize: an error in the exported message is classified", f.errorClass === "auth");
f = await oc.finalize(fjob({ code: 1, signal: null }, [{ type: "error", sessionID: "s1", error: { name: "UnknownError", data: { message: "x" } } }]), fctx(exportOf({ id: "m1", time: { created: T0 - 60_000 }, finish: "stop" }, [{ type: "text", text: "DONE\nprevious job's answer" }])));
check("finalize: the previous job's message of a resumed session (not in the stream, created before the start) is no answer", f.ok === undefined && f.meta.export === "no message of this run", JSON.stringify(f));
f = await oc.finalize(fjob({ code: 0, signal: null }, []), fctx(exportOf({ id: "m1", time: { created: T0 + 1 }, finish: "stop" }, [{ type: "text", text: "DONE" }])));
check("finalize: a message created after the start counts when the stream named no message", f.ok === true && f.response === "DONE");
const before = execs.length;
for (const job of [
  { reduced: { ok: true, response: "x", sessionId: "s1" }, io: { exit: { code: 0 } } },
  { reduced: { ok: false, errorClass: "blocked", sessionId: "s1" }, io: { exit: { code: 0 } } },
  { reduced: { ok: false, errorClass: null, sessionId: null }, io: { exit: { code: 0 } } },
  { reduced: { ok: false, errorClass: null, sessionId: "s1" }, io: { exit: { code: null, signal: "SIGKILL" } } },
]) {
  f = await oc.finalize({ ...job, record: { startedAt: new Date(T0).toISOString() } }, fctx(exportOf({ finish: "stop" }, [{ type: "text", text: "DONE" }])));
  check(`finalize: no export for ${JSON.stringify(job.reduced).slice(0, 50)} ${job.io.exit.signal ?? ""}`, f === null);
}
check("finalize: those cases ran no process", execs.length === before);

// invocation / probe (pure): instruction files, roles, keyVar, refusals
const dir = path.join(root, "unit-repo");
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, "AGENTS.md"), "rules\n");
const ctx = core.makeCtx({ env: { TMPDIR: "/t", HOME: "/h", AGENT_DISPATCH_STATE_DIR: path.join(root, "unit-state") }, profile: {}, profileName: "u1" });
const req = (profile, extra = {}) => ({ profile, profileName: "u1", role: null, write: false, job: { id: "oc-0042", dir: path.join(root, "jobdir"), cwd: dir, workspaceRoot: dir }, prompt: { path: "/p.md", bytes: 3 }, sessionId: null, resume: null, harness: null, ...extra });
let inv = oc.invocation(req({ harness: "opencode", auth: "login", model: "openai/gpt-x", home: "user" }), ctx);
check("invocation: only the instruction files that exist", eq(JSON.parse(inv.mandatoryEnv.OPENCODE_CONFIG_CONTENT).instructions, [path.join(dir, "AGENTS.md")]));
check("invocation: default bin opencode, reviewer without --write, prompt on stdin", eq(inv.argv, ["opencode", "run", "--format", "json", "--title", "oc-0042", "--agent", "sp-reviewer", "-m", "openai/gpt-x", "--dir", dir]) && inv.stdinPath === "/p.md");
check("invocation: home user → dataDir $HOME/.local/share, no key", inv.meta.dataDir === "/h/.local/share" && inv.secretEnv.length === 0);
inv = oc.invocation(req({ harness: "opencode", auth: "login", model: "a/b", home: "user", env: { XDG_DATA_HOME: "/x" } }), ctx);
check("invocation: a profile's own XDG_DATA_HOME is where its sessions live", inv.meta.dataDir === "/x");
const extOf = (i) => Object.keys(JSON.parse(i.mandatoryEnv.OPENCODE_PERMISSION).external_directory);
check("invocation: external_directory allows the caller's TMPDIR and the truncation dir of the data dir", eq(extOf(inv).slice(0, 4), ["*", "/t/*", "/tmp/*", "/x/opencode/tool-output/*"]));
inv = oc.invocation(req({ harness: "opencode", auth: "login", model: "a/b", home: "user", env: { TMPDIR: "/profile-tmp" } }), ctx);
check("invocation: the profile's TMPDIR replaces the caller's in external_directory", extOf(inv).includes("/profile-tmp/*") && !extOf(inv).includes("/t/*"));
inv = oc.invocation(req({ harness: "opencode", auth: "login", model: "a/b", home: "user", env: { TMPDIR: null } }), ctx);
check("invocation: a profile that removes TMPDIR keeps only /tmp", !extOf(inv).includes("/t/*") && extOf(inv).includes("/tmp/*"));
const home = await oc.prepareHome({ home: "isolated" }, ctx);
check("prepareHome: isolated → XDG_* under homes/<profile>, dirs to create", home.env.XDG_DATA_HOME === path.join(root, "unit-state", "homes", "u1", "data") && home.dirs.length === 6 && eq(await oc.loginEnv({ home: "isolated" }, ctx), home.env));
check("prepareHome: isolated → config/git/config pointing git at the caller's ~/.config/git (0600)", home.files.length === 1 && home.files[0].path === path.join(home.env.XDG_CONFIG_HOME, "git", "config") && home.files[0].mode === 0o600 && home.files[0].content.includes('path = "/h/.config/git/config"') && home.files[0].content.includes('excludesFile = "/h/.config/git/ignore"') && home.dirs.includes(path.join(home.env.XDG_CONFIG_HOME, "git")));
const gctx = (env) => core.makeCtx({ env: { AGENT_DISPATCH_STATE_DIR: path.join(root, "unit-state"), ...env }, profile: {}, profileName: "u1" });
check("gitConfigOf: the caller's XDG_CONFIG_HOME wins over ~/.config", mod.gitConfigOf({ home: "isolated" }, gctx({ HOME: "/h", XDG_CONFIG_HOME: "/xdg" })).includes('path = "/xdg/git/config"'));
check("gitConfigOf: an XDG_CONFIG_HOME under homes/ (an eval'd profile env) is never included — ~/.config instead", mod.gitConfigOf({ home: "isolated" }, gctx({ HOME: "/h", XDG_CONFIG_HOME: path.join(root, "unit-state", "homes", "u1", "config") })).includes('path = "/h/.config/git/config"'));
check("gitConfigOf: quotes and backslashes are escaped; no HOME and no XDG → null", mod.gitConfigOf({ home: "isolated" }, gctx({ HOME: '/h "q\\' })).includes('path = "/h \\"q\\\\/.config/git/config"') && mod.gitConfigOf({ home: "isolated" }, gctx({})) === null);
check("prepareHome: user → nothing", eq(await oc.prepareHome({ home: "user" }, ctx), { env: {}, dirs: [], files: [] }));
inv = oc.probe(req({ harness: "opencode", auth: "login", model: "openai/gpt-x" }, { write: true, job: { id: null, dir: "/x", cwd: dir, workspaceRoot: null } }), ctx);
check("probe: the reviewer agent and title probe, even when write is asked", inv.argv.includes("sp-reviewer") && inv.argv[inv.argv.indexOf("--title") + 1] === "probe");
inv = oc.invocation(req({ harness: "opencode", auth: "login", model: "a/b" }, { resume: { sessionId: "ses_1", prev: null }, harness: { bin: "/opt/oc", version: "1.19.3" } }), ctx);
check("invocation: resume adds -s <id> before --dir; the discovered bin wins", eq(inv.argv.slice(-4), ["-s", "ses_1", "--dir", dir]) && inv.argv[0] === "/opt/oc");
for (const [label, profile, want] of [
  ["keyVar missing", { harness: "opencode", auth: { key: "k" }, model: "a/b" }, /needs keyVar/],
  ["keyVar the adapter sets", { harness: "opencode", auth: { key: "k" }, keyVar: "OPENCODE_PERMISSION", model: "a/b" }, /sets itself/],
  ["keyVar XDG_*", { harness: "opencode", auth: { key: "k" }, keyVar: "XDG_DATA_HOME", model: "a/b" }, /sets itself/],
  ["model without provider", { harness: "opencode", auth: "login", model: "gpt-x" }, /<provider>\/<model>/],
  ["the preset's model placeholder", { harness: "opencode", auth: "login", model: "<provider/model>" }, /<provider>\/<model>/],
  ["permission rule not an action", { harness: "opencode", auth: "login", model: "a/b", options: { permission: { bash: { "*": "maybe" } } } }, /options\.permission\.bash/],
]) {
  let error = null;
  try {
    oc.invocation(req(profile), ctx);
  } catch (e) {
    error = e;
  }
  check(`invocation refuses (UsageError): ${label}`, error instanceof core.UsageError && want.test(error.message), error?.message);
}
inv = oc.invocation(req({ harness: "opencode", auth: { keyEnv: "X" }, keyVar: "OPENCODE_API_KEY", model: "opencode-go/m" }), ctx);
check("invocation: keyVar OPENCODE_API_KEY (OpenCode Go's own provider variable) is accepted", eq(inv.secretEnv, ["OPENCODE_API_KEY"]));

// resumeCheck
check("resumeCheck: same --dir and data dir → null", oc.resumeCheck({ meta: { dir, dataDir: "/h/.local/share" } }, { home: "user" }, req({}), ctx) === null);
check("resumeCheck: another data dir", /data dir \/h\/\.local\/share, not \/other/.test(oc.resumeCheck({ meta: { dir, dataDir: "/h/.local/share" } }, { home: "user", env: { XDG_DATA_HOME: "/other" } }, req({}), ctx) ?? ""));
check("resumeCheck: another --dir", /--dir \/elsewhere/.test(oc.resumeCheck({ meta: { dir: "/elsewhere", dataDir: "/h/.local/share" } }, { home: "user" }, req({}), ctx) ?? ""));

// discover / parseVersion / manifest
check("parseVersion", eq(mod.parseVersion("1.19.3\n"), { version: "1.19.3", major: 1 }) && mod.parseVersion("opencode 2.1.0-beta.1").major === 2 && mod.parseVersion("x") === null);
const dctx = (reply) => ({ profile: { bin: "/b/opencode" }, exec: () => reply });
check("discover: v1 → {bin, version}", eq(oc.discover(dctx({ status: 0, stdout: "1.19.3\n" })), { bin: "/b/opencode", version: "1.19.3" }));
let derr = null;
try {
  oc.discover(dctx({ status: 0, stdout: "2.1.0\n" }));
} catch (e) {
  derr = e;
}
check("discover: v2 → errorClass launch", derr?.errorClass === "launch" && /OpenCode 2\.1\.0/.test(derr.message));
check("manifest: first-event session, SIGTERM 5 s then SIGKILL, run --help", oc.manifest.sessionId === "first-event" && eq(oc.manifest.cancel.ladder, [["SIGTERM", 5000], ["SIGKILL", 0]]) && eq(oc.manifest.helpArgv, ["run", "--help"]) && oc.idPrefix === "oc");

// authListNames: only the credential rows
const listing = "\u250c  Credentials \x1b[90m/home/u/.local/share/opencode/auth.json\n\u2502\n\u25cf  GitHub Copilot \x1b[90moauth\n\u2502\n\u25cf  Z.AI Coding Plan \x1b[90mapi\n\u2502\n\u2514  2 credentials\n\n\u250c  Environment\n\u2502\n\u25cf  OpenCode Zen \x1b[90mOPENCODE_API_KEY\n\u2502\n\u2514  1 environment variable\n";
check("authListNames: the rows of the Credentials block, without the type, the header path or the Environment block", eq(mod.authListNames(listing), ["GitHub Copilot", "Z.AI Coding Plan"]), JSON.stringify(mod.authListNames(listing)));
check("authListNames: an empty store or no Credentials header → none", eq(mod.authListNames("\u250c  Credentials /x/opencode/auth.json\n\u2502\n\u2514  0 credentials\n"), []) && eq(mod.authListNames("garbage"), []));

// doctorChecks shapes
const checks = await oc.doctorChecks({ harness: "opencode", auth: { key: "k" }, keyVar: "K", home: "user", model: "deepseek/x", options: { permission: { edit: "ask" }, plugins: true } }, { ...ctx, exec: () => { throw new Error("no process for a key profile"); } });
check("doctorChecks: [{name, level, hint}] — home WARN, permission WARN, plugins ok; no auth list for a key", eq(checks.map((c) => `${c.name}:${c.level}`), ["home:WARN", "permission:WARN", "plugins:ok"]) && checks.every((c) => typeof c.hint === "string" && c.hint));

console.log(results.join("\n"));
EOF
    local unit_out
    unit_out="$(node "$TEST_ROOT/unit.mjs" "$ADAPTER" "$CORE" "$TEST_ROOT" 2>&1)"
    if [[ -z "$unit_out" || "$unit_out" != PASS* && "$unit_out" != FAIL* ]]; then
        fail "16 unit checks ran"
        echo "    $unit_out"
    fi
    while IFS= read -r line; do
        case "$line" in
            "PASS "*) pass "16 ${line#PASS }" ;;
            "FAIL "*) fail "16 ${line#FAIL }" ;;
        esac
    done <<<"$unit_out"

    # --- leak check: nothing this run started is still running ---
    local left="" i=0
    while ((i < 50)); do
        left="$(pgrep -f "$TEST_ROOT" | tr '\n' ' ')"
        [[ -z "$left" ]] && break
        sleep 0.2
        i=$((i + 1))
    done
    [[ -z "$left" ]]
    verdict "no process of this run (runner, stub, descendant) outlives the suite" $? "left: $left"

    echo ""
    echo "PASS count: $PASSES"
    if [[ "$FAILURES" -ne 0 ]]; then
        echo "FAILED: $FAILURES assertion(s)."
        exit 1
    fi
    echo "PASS"
}

main "$@"
