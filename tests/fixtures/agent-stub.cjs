#!/usr/bin/env node
// Test stand-in for a coding-agent harness (claude -p, opencode, pi, dsh), started through a profile's `bin` or the
// test adapter's default. Never calls a model.
//
// AGENT_STUB_DIALECT: the output dialect, the module stub-dialects/<name>.cjs (default: plain). A dialect renders the
//   final and error output and may add modes of its own; its modes win over the generic ones below, so a dialect is
//   added as one new file, without touching this one. Its answer(argv, io) handles non-run calls (auth checks and the
//   like) and returns true for exit 0 or the exit code itself.
// AGENT_STUB_MODE (generic):
//   ok             a final answer (AGENT_STUB_RESPONSE or "DONE\nstub finished"), exit 0
//   slow           ok after AGENT_STUB_DELAY_MS (default 2000 ms)
//   resume         ok ("DONE\nresumed <session>"), but exit 1 unless --resume was passed
//   exit0-error    an error in the dialect's shape (AGENT_STUB_MESSAGE, AGENT_STUB_CLASS), exit 0
//   exit1-valid    a valid final answer, exit 1
//   fail           AGENT_STUB_MESSAGE on stderr, exit AGENT_STUB_EXIT (default 1)
//   malformed      "not json" on stdout, exit 0
//   crash          SIGKILL to itself
//   hang           waits forever with the default signal dispositions
//   ignore-term    waits forever and ignores SIGTERM
//   sigterm-exit0  waits; on SIGTERM prints a valid final answer and exits 0 (dsh does exit 0 on SIGTERM)
//   trap-signals   waits forever; appends each SIGINT / SIGTERM / SIGHUP it gets to AGENT_STUB_SIGNALS, ignores it
//   detached-child waits forever after starting a child in its own process group (a detached spawn is setsid),
//                  which starts a grandchild in yet another group; both ignore SIGINT / SIGTERM / SIGHUP and append
//                  their pids to AGENT_STUB_PIDS — the shape of a harness whose bash tools leave its process group
//   leave-behind   starts a child in its own process group (a member, as a backgrounded command would be) and,
//                  below it, a grandchild in a group of its own (both ignore the polite signals and append their pids
//                  to AGENT_STUB_PIDS), then prints a final answer and exits 0 while they live on
//   split-utf8     the final answer "Ответ: Привет ё" and a stderr line, each written in two chunks split inside a
//                  multi-byte character
//   leak-secret    prints the value of $AGENT_STUB_SECRET_VAR (default PLAIN_API_KEY) to stderr in two chunks split
//                  inside the value, then in the final answer, exit 0
// Always: `--version` prints "agent-stub <AGENT_STUB_VERSION or the dialect's version>"; `--help` prints the
// dialect's flags minus AGENT_STUB_HELP_DROP (comma-separated) and exits AGENT_STUB_HELP_EXIT (default 0);
// `--print-env NAME` prints that variable (what a second
// harness process such as `opencode export` sees). AGENT_STUB_CALL_LOG names a file that gets one line
// "<version|help> <$WRAPPED or ->" per --version / --help call. AGENT_STUB_RECORD names a file that gets
// {argv, stdin, cwd, env, pid, ppid} once stdin is read — after the signal dispositions are set, so it doubles as the
// readiness handshake of the signal tests. AGENT_STUB_DELAY_MS: wait before acting. Descendants carry the
// AGENT_STUB_PIDS path in their argv, so a test run can find (and kill) exactly its own.
// Tests list AGENT_STUB_* in AGENT_ENV_PASSTHROUGH, because the core filters the harness environment.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");

const argv = process.argv.slice(2);
const env = process.env;
const mode = env.AGENT_STUB_MODE || "ok";

function die(message) {
  process.stderr.write(`agent-stub: ${message}\n`);
  process.exit(2);
}

const dialectName = env.AGENT_STUB_DIALECT || "plain";
if (!/^[a-z0-9-]+$/.test(dialectName)) die(`invalid AGENT_STUB_DIALECT: ${dialectName}`);
let dialect;
try {
  dialect = require(path.join(__dirname, "stub-dialects", `${dialectName}.cjs`));
} catch (error) {
  die(`unknown AGENT_STUB_DIALECT ${dialectName}: ${error.message}`);
}

const flag = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};
const write = (text) => process.stdout.write(text);
const appendLine = (file, text) => {
  if (file) fs.appendFileSync(file, `${text}\n`);
};

// Non-run invocations first: the dialect's own (auth checks and the like), then --print-env, --version and --help.
// answer() returns true (handled, exit 0), an integer exit code (handled; 0 included), or false / undefined (not a
// non-run call). The stub sets the exit code and returns instead of process.exit(), so a pending stdout write to a
// pipe is not cut off.
const answered = typeof dialect.answer === "function" ? dialect.answer(argv, { env, write }) : false;
if (answered === true || Number.isInteger(answered)) {
  process.exitCode = answered === true ? 0 : answered;
  return;
}
if (flag("--print-env") !== undefined) {
  write(`${env[flag("--print-env")] ?? ""}\n`);
  process.exit(0);
}
for (const [option, verb] of [["--version", "version"], ["--help", "help"]]) {
  if (argv.includes(option)) appendLine(env.AGENT_STUB_CALL_LOG, `${verb} ${env.WRAPPED || "-"}`);
}
if (argv.includes("--version")) {
  write(`agent-stub ${env.AGENT_STUB_VERSION || dialect.version}\n`);
  process.exit(0);
}
if (argv.includes("--help")) {
  const drop = new Set((env.AGENT_STUB_HELP_DROP || "").split(",").filter(Boolean));
  write(dialect.help(dialect.flags.filter((name) => !drop.has(name))));
  process.exitCode = Number(env.AGENT_STUB_HELP_EXIT || 0);
  return;
}

const sessionId = dialect.sessionId(flag);
const final = (text) => write(dialect.final({ sessionId, text }));

// Signal dispositions are set before stdin is read and before AGENT_STUB_RECORD is written, so an early cancel
// already meets them and the record tells a test that they are in place.
const forever = () => setInterval(() => {}, 1 << 30);
if (mode === "ignore-term") process.on("SIGTERM", () => {});
if (mode === "trap-signals") {
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(signal, () => appendLine(env.AGENT_STUB_SIGNALS, signal));
}
if (mode === "sigterm-exit0") {
  process.on("SIGTERM", () => {
    final("DONE\nterminated politely");
    process.exitCode = 0;
    setTimeout(() => process.exit(0), 50);
  });
}

let stdin = "";
try {
  stdin = fs.readFileSync(0, "utf8");
} catch {
  stdin = "";
}
if (env.AGENT_STUB_RECORD) {
  fs.writeFileSync(env.AGENT_STUB_RECORD, JSON.stringify({ argv, stdin, cwd: process.cwd(), env: { ...process.env }, pid: process.pid, ppid: process.ppid }));
}

const io = { argv, env, flag, write, stdin, sessionId, dialect, forever, appendLine };

// A descendant script that ignores the polite signals, records its pid and waits forever. Its trailing arguments
// (a marker and the AGENT_STUB_PIDS path, which lies under the test run's temp root) let a run find its own.
const ignoring = (body) => `
  for (const s of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(s, () => {});
  ${body}
  require("node:fs").appendFileSync(process.env.AGENT_STUB_PIDS, process.pid + "\\n");
  setInterval(() => {}, 1 << 30);`;
const descendantArgv = (script) => ["-e", script, "agent-stub-descendant", env.AGENT_STUB_PIDS || ""];
const spawnGrandchild = (script) =>
  `require("node:child_process").spawn(process.execPath, ["-e", ${JSON.stringify(script)}, "agent-stub-descendant", process.env.AGENT_STUB_PIDS || ""], { detached: true, stdio: "ignore" });`;
// Resolves once `file` has `n` lines (or after 5 s).
const linesIn = (file, n) =>
  new Promise((resolve) => {
    const started = Date.now();
    const poll = () => {
      let count = 0;
      try {
        count = fs.readFileSync(file, "utf8").split("\n").filter(Boolean).length;
      } catch {
        count = 0;
      }
      if (count >= n || Date.now() - started > 5000) resolve();
      else setTimeout(poll, 20);
    };
    poll();
  });

const generic = {
  ok: () => final(env.AGENT_STUB_RESPONSE || "DONE\nstub finished"),
  slow: () => final(env.AGENT_STUB_RESPONSE || "DONE\nslow"),
  resume: () => {
    if (!flag("--resume")) {
      process.stderr.write("agent-stub: resume mode without --resume\n");
      process.exit(1);
    }
    final(`DONE\nresumed ${flag("--resume")}`);
  },
  "exit0-error": () => write(dialect.error({ sessionId, message: env.AGENT_STUB_MESSAGE || "Insufficient balance", errorClass: env.AGENT_STUB_CLASS || null })),
  "exit1-valid": () => {
    final(env.AGENT_STUB_RESPONSE || "DONE\nvalid despite exit 1");
    process.exitCode = 1;
  },
  fail: () => {
    process.stderr.write(`Error: ${env.AGENT_STUB_MESSAGE || "stub failure"}\n`);
    process.exitCode = Number(env.AGENT_STUB_EXIT || 1);
  },
  malformed: () => write("not json\n"),
  crash: () => process.kill(process.pid, "SIGKILL"),
  hang: forever,
  "ignore-term": forever,
  "trap-signals": forever,
  "sigterm-exit0": forever, // the SIGTERM handler is installed above, before stdin is read
  "detached-child": () => {
    const child = ignoring(spawnGrandchild(ignoring("")));
    spawn(process.execPath, descendantArgv(child), { detached: true, stdio: "ignore" });
    forever();
  },
  "leave-behind": async () => {
    const member = ignoring(spawnGrandchild(ignoring("")));
    spawn(process.execPath, descendantArgv(member), { stdio: "ignore" }).unref(); // not detached: stays in our group
    await linesIn(env.AGENT_STUB_PIDS, 2);
    final(env.AGENT_STUB_RESPONSE || "DONE\nleft some behind");
  },
  "split-utf8": () => {
    const out = Buffer.from(dialect.final({ sessionId, text: "Ответ: Привет ё" }));
    const outAt = out.indexOf(Buffer.from("ё")) + 1;
    const err = Buffer.from("прогресс: ёлка готова\n");
    const errAt = err.indexOf(Buffer.from("ё")) + 1;
    process.stdout.write(out.subarray(0, outAt));
    process.stderr.write(err.subarray(0, errAt));
    setTimeout(() => {
      process.stdout.write(out.subarray(outAt));
      process.stderr.write(err.subarray(errAt));
    }, 80);
  },
  "leak-secret": () => {
    const secret = env[env.AGENT_STUB_SECRET_VAR || "PLAIN_API_KEY"] || "";
    const half = Math.max(1, Math.floor(secret.length / 2));
    process.stderr.write(`leaked: ${secret.slice(0, half)}`);
    setTimeout(() => {
      process.stderr.write(`${secret.slice(half)} (end)\n`);
      final(`DONE\nkey=${secret}`);
    }, 80);
  },
};

function run() {
  const handler = dialect.modes?.[mode] ?? generic[mode];
  if (!handler) die(`unknown AGENT_STUB_MODE for dialect ${dialect.name}: ${mode}`);
  handler(io);
}

const delay = env.AGENT_STUB_DELAY_MS !== undefined ? Number(env.AGENT_STUB_DELAY_MS) : mode === "slow" ? 2000 : 0;
setTimeout(run, delay);
