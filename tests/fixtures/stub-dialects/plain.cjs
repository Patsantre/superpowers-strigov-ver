// The "plain" output dialect of tests/fixtures/agent-stub.cjs: newline-delimited JSON events, read by the test
// adapter tests/fixtures/adapters/plain.mjs. Events: {"type":"session","id"}, {"type":"final","text","model",
// "usage"} and {"type":"error","message","class"?}.
//
// A dialect module exports:
//   name, version     — the dialect id and the version `--version` prints by default;
//   flags             — the flags `--help` lists (AGENT_STUB_HELP_DROP removes some for tests);
//   help(flags)       — the help text;
//   answer?(argv, io) — optional: handle a non-run invocation (e.g. `auth status --json`), return true if handled;
//   sessionId(flag)   — the session id of this run, from the parsed flags;
//   final({ sessionId, text })                 — the complete stdout of a successful run;
//   error({ sessionId, message, errorClass })  — the complete stdout of a run that reports an error;
//   modes             — dialect-specific AGENT_STUB_MODE handlers ({ name(io) }), which win over the generic ones.
"use strict";

const FLAGS = ["--plain-json", "--session-id", "--resume", "--write", "--read-only", "--model"];
const line = (value) => `${JSON.stringify(value)}\n`;

module.exports = {
  name: "plain",
  version: "1.0.0",
  flags: FLAGS,
  help(flags) {
    return `usage: agent-stub [options] < prompt\noptions:\n${flags.map((flag) => `  ${flag}`).join("\n")}\n  --version\n  --help\n`;
  },
  sessionId(flag) {
    return flag("--resume") || flag("--session-id") || `stub-session-${process.pid}`;
  },
  final({ sessionId, text }) {
    return line({ type: "session", id: sessionId }) + line({ type: "final", text, model: "stub-model", usage: { input: 10, output: 2 } });
  },
  error({ sessionId, message, errorClass }) {
    return line({ type: "session", id: sessionId }) + line({ type: "error", message, ...(errorClass ? { class: errorClass } : {}) });
  },
  modes: {},
};
