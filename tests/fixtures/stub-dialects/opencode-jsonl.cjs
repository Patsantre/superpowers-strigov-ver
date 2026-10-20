// The "opencode-jsonl" output dialect of tests/fixtures/agent-stub.cjs: OpenCode 1.19.x as `opencode run --format json`
// prints it (docs/research/universal-dispatchers/02-opencode.md, cited as [02 §n]), for tests/test-adapter-opencode.sh
// and bin/lib/adapters/opencode.mjs. Never calls a model.
//
// What it reproduces:
//   - stdout: one JSON object per line, {type, timestamp, sessionID, ...data}; types step_start / text / tool_use /
//     step_finish ({part}) and error ({error: {name, data: {message, statusCode?, responseBody?}}}) [02 §3]. Without
//     `--format json` it prints the bare answer text instead (the default format).
//   - stderr: warnings and errors only ("! permission requested: …; auto-rejecting", the agent fallback warning,
//     "Error: Session not found", "Error: Model not found: …") [02 §3, §7, §11].
//   - exit codes: 0 when the session goes idle without a session error, 1 on any session error (also when a valid
//     answer follows it), 0 after an auto-rejected permission ends the loop (inferred in [02 §3], unverified).
//   - sessions: a run without -s/--session creates a session; with one, the session must exist in the same data dir
//     ($XDG_DATA_HOME, else $HOME/.local/share — sessions live in the SQLite DB there [02 §4]) for the same --dir, or
//     the run exits 1 with "Session not found". The store is <data dir>/opencode/stub-sessions/<id>.json; it also
//     holds the last assistant message (its id, creation time, finish reason, text or error), which
//     `opencode export <id>` prints as {info, messages: [{info, parts}]}.
//   - the agent: with --agent <name> not defined as a primary agent in $OPENCODE_CONFIG_CONTENT, OpenCode warns on
//     stderr and falls back to its default agent [02 §2]; the wording of the warning is not pinned in [02].
//   - `opencode --version` prints the bare version (AGENT_STUB_VERSION, default 1.19.3); `opencode run --help` lists
//     the run flags (the generic --help path, minus AGENT_STUB_HELP_DROP).
//   - `opencode auth list` prints provider names and auth types only, from <data dir>/opencode/stub-auth.json (a test
//     fixture {provider id: {type}} — deliberately not auth.json, so the stub never reads a real credential store),
//     under the header "Credentials <data dir>/opencode/auth.json", then an "Environment" block naming the providers
//     whose catalog variable (ENV_VARS below) is set — as `providers list` does [02 §6].
//
// Modes (AGENT_STUB_MODE; these win over the generic ones of agent-stub.cjs, which render through final() / error()):
//   ok                  the agent check, then a final answer (AGENT_STUB_RESPONSE or "DONE\nstub finished"), exit 0
//   error               an error event of AGENT_STUB_CLASS (table ERRORS below; default unknown), exit 1
//   quota | rate-limit | context   the error mode with that class
//   model-not-found     "Error: Model not found: <-m>. Did you mean …" on stderr, nothing on stdout, exit 1
//   error-then-recover  a ContextOverflowError, then (after compaction) a valid answer: exit 1 [02 fact-check note 1]
//   text-then-error     an answer, then an error event of AGENT_STUB_CLASS (default server): exit 1
//   multi-message       two assistant messages; the last one has two text parts ("DONE", "second part")
//   tool-step-exit1     a narration ("Let me look at the tree first."), a tool call and step_finish tool-calls, then
//                       the next message's step_start, and exit 1 without an error event: a crash mid-turn (the
//                       session keeps the next message with partial text and no finish)
//   tool-step-killed    the same, then SIGKILL to itself
//   silent-final-step   the same narration and tool call, then a final step that ends "stop" with no text, exit 0
//   resume-error        with -s: an error event of AGENT_STUB_CLASS (default unknown) before any message of this run,
//                       exit 1; the session keeps the previous run's answer (export shows it)
//   auto-reject         a text, a tool call rejected in run mode, the stderr line "! permission requested: bash
//                       (npm test); auto-rejecting", no final answer, exit 0 [02 §7]
//   agent-not-found     the agent fallback warning on stderr, then a valid answer, exit 0
//   stdin-wait          reads stdin to EOF (as `Bun.stdin.text()` does) and answers with its size; an empty stdin is
//                       "You must provide a message or a command", exit 1 [02 §2]
//   resume              a valid answer "DONE\nresumed <id>" when -s was given, else exit 1
//   late-session        the first events carry no session id; later ones do
//   no-text-events      steps and a tool call but no text event; the answer reaches only the session (export)
//   detached-bash       a step and a running bash tool: a child in its own process group (OpenCode spawns bash tools
//                       detached [02 §10]) and a grandchild in another, both ignoring SIGINT / SIGTERM / SIGHUP and
//                       appending their pids to AGENT_STUB_PIDS; the stub itself keeps the default dispositions
//                       (OpenCode has no SIGTERM handler in the run path) and waits forever
// Export (`opencode export <id>`): the stored answer as the last assistant message; AGENT_STUB_EXPORT=fail exits 1.
// AGENT_STUB_CALL_LOG gets "version <$WRAPPED|->", "export <id> key=<set|unset>" (the variable named by
// AGENT_STUB_SECRET_VAR, default DEEPSEEK_API_KEY) and "auth-list <data dir>".
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");

const VERSION = "1.19.3";
// The flags of `opencode run --help` (v1.19.3, [02 §2]); short aliases as yargs prints them.
const FLAGS = [
  "--command", "--continue", "--session", "--fork", "--model", "--agent", "--format", "--file", "--title", "--attach",
  "--password", "--username", "--dir", "--port", "--variant", "--thinking", "--auto",
];
const ALIASES = { "--continue": "-c", "--session": "-s", "--model": "-m", "--file": "-f", "--password": "-p", "--username": "-u" };
// Display names `auth list` prints for a few provider ids (it prints names, never ids or values [02 §6]).
const PROVIDER_NAMES = { "github-copilot": "GitHub Copilot", openai: "OpenAI", opencode: "OpenCode Zen", "opencode-go": "OpenCode Go", "zai-coding-plan": "Z.AI Coding Plan", deepseek: "DeepSeek" };
// Catalog variables that enable a provider, for the Environment block of `auth list`.
const ENV_VARS = { OPENCODE_API_KEY: "opencode", DEEPSEEK_API_KEY: "deepseek", GITHUB_TOKEN: "github-copilot" };

const argv = process.argv.slice(2);
const flag = (...names) => {
  for (const name of names) {
    const i = argv.indexOf(name);
    if (i >= 0) return argv[i + 1];
  }
  return undefined;
};
const json = () => flag("--format") === "json";
const line = (value) => `${JSON.stringify(value)}\n`;
let seq = 0;
const nextId = (prefix) => `${prefix}_${process.pid.toString(36)}${Date.now().toString(36)}${(seq += 1).toString(36).padStart(3, "0")}`;
const appendLine = (file, text) => {
  if (file) fs.appendFileSync(file, `${text}\n`);
};
const readJson = (file) => {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
};
// Synchronous writes: an answer() that exits must not lose its output on a pipe.
const out = (text) => fs.writeSync(1, text);
const err = (text) => fs.writeSync(2, text);

const dataDir = (env) => env.XDG_DATA_HOME || path.join(env.HOME || os.homedir(), ".local", "share");
const storeFile = (env, id) => path.join(dataDir(env), "opencode", "stub-sessions", `${id}.json`);
function remember(id, patch) {
  const file = storeFile(process.env, id);
  const current = readJson(file);
  if (!current) return;
  fs.writeFileSync(file, JSON.stringify({ ...current, ...patch }));
}

// ---- events ----
const event = (type, sessionID, data) => line({ type, timestamp: Date.now(), sessionID, ...data });
const part = (sessionID, messageID, type, extra) => ({ id: nextId("prt"), sessionID, messageID, type, ...extra });
const stepStart = (sid, msg) => event("step_start", sid, { part: part(sid, msg, "step-start", {}) });
const textEvent = (sid, msg, text) => event("text", sid, { part: part(sid, msg, "text", { text, time: { start: Date.now() - 5, end: Date.now() } }) });
const stepFinish = (sid, msg, reason = "stop") =>
  event("step_finish", sid, { part: part(sid, msg, "step-finish", { reason, cost: 0.0012, tokens: { input: 120, output: 30, reasoning: 4, cache: { read: 10, write: 0 } } }) });
const toolUse = (sid, msg, tool, status, extra = {}) =>
  event("tool_use", sid, { part: part(sid, msg, "tool", { tool, callID: nextId("call"), state: { status, input: extra.input ?? {}, ...extra.state } }) });

// ---- errors: a NamedError per class (AGENT_STUB_CLASS) [02 §11] ----
const apiError = (statusCode, message, responseBody) => ({ name: "APIError", data: { message, statusCode, isRetryable: false, responseBody } });
const ERRORS = {
  auth: (m) => ({ name: "ProviderAuthError", data: { providerID: "deepseek", message: m ?? "Invalid API key" } }),
  "auth-401": (m) => apiError(401, m ?? "Unauthorized", '{"error":{"message":"invalid api key"}}'),
  quota: (m) => apiError(429, m ?? "Quota exceeded. Check your plan and billing details.", '{"error":{"type":"insufficient_quota","message":"You exceeded your current quota"}}'),
  "quota-plan": (m) => apiError(429, m ?? "Quota exceeded. Check your plan and billing details.", '{"detail":{"code":"usage_not_included"}}'),
  "quota-go": (m) => ({ name: "GoUsageLimitError", data: { message: m ?? "Monthly usage limit reached" } }),
  "quota-free": (m) => ({ name: "FreeUsageLimitError", data: { message: m ?? "Free usage exceeded, subscribe to Go" } }),
  // After five retried 429s OpenCode reports "Quota exceeded…" also without any sign of an exhausted quota (spec §3.8).
  "rate-limit": (m) => apiError(429, m ?? "Quota exceeded. Check your plan and billing details.", '{"error":{"message":"Rate limit reached for requests"}}'),
  overloaded: (m) => apiError(529, m ?? "Overloaded", '{"type":"error","error":{"type":"overloaded_error"}}'),
  server: (m) => apiError(503, m ?? "Service Unavailable", "upstream connect error"),
  context: (m) => ({ name: "ContextOverflowError", data: { message: m ?? "Input exceeds context window of this model" } }),
  balance: (m) => apiError(402, m ?? "Insufficient Balance", '{"error":{"message":"Insufficient Balance"}}'),
  unknown: (m) => ({ name: "UnknownError", data: { message: m ?? "stub failure" } }),
};
const errorShape = (cls, message) => (ERRORS[cls] ?? ERRORS.unknown)(message || undefined);

// The session's last assistant message as the store keeps it (what `export` prints).
const stored = (messageId, fields) => ({ messageId, created: Date.now(), text: null, error: null, finish: null, ...fields });

function finalText(sessionId, text) {
  const msg = nextId("msg");
  remember(sessionId, stored(msg, { text, finish: "stop" }));
  if (!json()) return `${text}\n`;
  return stepStart(sessionId, msg) + textEvent(sessionId, msg, text) + stepFinish(sessionId, msg);
}

function errorEvents(sessionId, cls, message) {
  const error = errorShape(cls, message);
  const msg = nextId("msg");
  remember(sessionId, stored(msg, { error }));
  if (!json()) return "";
  return stepStart(sessionId, msg) + event("error", sessionId, { error });
}

// A narration and a tool call in m1 (step_finish tool-calls), then m2's step_start: the turn goes on.
function toolStep(sid) {
  const m1 = nextId("msg");
  const m2 = nextId("msg");
  return {
    m2,
    text:
      stepStart(sid, m1) + textEvent(sid, m1, "Let me look at the tree first.") +
      toolUse(sid, m1, "read", "completed", { input: { filePath: "a.txt" }, state: { output: "x" } }) + stepFinish(sid, m1, "tool-calls") +
      stepStart(sid, m2),
  };
}

// OpenCode falls back to its default agent, with a warning, when --agent names no primary agent [02 §2, §15 item 4].
function agentWarning(env, force = false) {
  const name = flag("--agent");
  if (name === undefined) return;
  let agent = null;
  try {
    agent = JSON.parse(env.OPENCODE_CONFIG_CONTENT || "{}")?.agent?.[name] ?? null;
  } catch {
    agent = null;
  }
  if (force || !agent || agent.mode !== "primary") process.stderr.write(`! agent "${name}" not found. Falling back to default agent\n`);
}

const fail = (io, cls) => {
  io.write(errorEvents(io.sessionId, cls, io.env.AGENT_STUB_MESSAGE));
  process.exitCode = 1;
};

// A descendant that ignores the polite signals, records its pid and waits; the AGENT_STUB_PIDS path in its argv lets
// a test run find (and kill) exactly its own.
const ignoring = (body) => `
  for (const s of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(s, () => {});
  ${body}
  require("node:fs").appendFileSync(process.env.AGENT_STUB_PIDS, process.pid + "\\n");
  setInterval(() => {}, 1 << 30);`;

const modes = {
  ok: (io) => {
    agentWarning(io.env);
    io.write(finalText(io.sessionId, io.env.AGENT_STUB_RESPONSE || "DONE\nstub finished"));
  },
  error: (io) => fail(io, io.env.AGENT_STUB_CLASS || "unknown"),
  quota: (io) => fail(io, "quota"),
  "rate-limit": (io) => fail(io, "rate-limit"),
  context: (io) => fail(io, "context"),
  "model-not-found": () => {
    process.stderr.write(`Error: Model not found: ${flag("-m", "--model") ?? "-"}. Did you mean: deepseek/deepseek-v4-flash?\n`);
    process.exitCode = 1;
  },
  "error-then-recover": (io) => {
    const sid = io.sessionId;
    const m1 = nextId("msg");
    const m2 = nextId("msg");
    const error = errorShape("context");
    io.write(stepStart(sid, m1) + event("error", sid, { error }) + stepStart(sid, m2) + textEvent(sid, m2, io.env.AGENT_STUB_RESPONSE || "DONE\nrecovered after compaction") + stepFinish(sid, m2));
    remember(sid, stored(m2, { text: io.env.AGENT_STUB_RESPONSE || "DONE\nrecovered after compaction", finish: "stop" }));
    process.exitCode = 1;
  },
  "text-then-error": (io) => {
    const sid = io.sessionId;
    const m1 = nextId("msg");
    const error = errorShape(io.env.AGENT_STUB_CLASS || "server", io.env.AGENT_STUB_MESSAGE);
    io.write(stepStart(sid, m1) + textEvent(sid, m1, "DONE\nan answer before the failure") + stepFinish(sid, m1) + event("error", sid, { error }));
    remember(sid, stored(m1, { error }));
    process.exitCode = 1;
  },
  "multi-message": (io) => {
    const sid = io.sessionId;
    const m1 = nextId("msg");
    const m2 = nextId("msg");
    io.write(
      stepStart(sid, m1) + textEvent(sid, m1, "Let me look at the tree first.") + toolUse(sid, m1, "read", "completed", { input: { filePath: "a.txt" }, state: { output: "x" } }) + stepFinish(sid, m1, "tool-calls") +
        stepStart(sid, m2) + textEvent(sid, m2, "DONE") + textEvent(sid, m2, "second part") + stepFinish(sid, m2),
    );
    remember(sid, stored(m2, { text: "DONE\nsecond part", finish: "stop" }));
  },
  "tool-step-exit1": (io) => {
    const step = toolStep(io.sessionId);
    io.write(step.text);
    remember(io.sessionId, stored(step.m2, { text: "I found" }));
    process.exitCode = 1;
  },
  "tool-step-killed": (io) => {
    const step = toolStep(io.sessionId);
    out(step.text);
    remember(io.sessionId, stored(step.m2, { text: "I found" }));
    process.kill(process.pid, "SIGKILL");
  },
  "silent-final-step": (io) => {
    const step = toolStep(io.sessionId);
    io.write(step.text + stepFinish(io.sessionId, step.m2, "stop"));
    remember(io.sessionId, stored(step.m2, { finish: "stop" }));
  },
  "resume-error": (io) => {
    if (flag("-s", "--session") === undefined) {
      process.stderr.write("agent-stub: resume-error mode without -s\n");
      process.exitCode = 1;
      return;
    }
    // No message of this run reaches the session: its last assistant message is still the previous run's answer.
    io.write(event("error", io.sessionId, { error: errorShape(io.env.AGENT_STUB_CLASS || "unknown", io.env.AGENT_STUB_MESSAGE) }));
    process.exitCode = 1;
  },
  "auto-reject": (io) => {
    const sid = io.sessionId;
    const m1 = nextId("msg");
    io.write(
      stepStart(sid, m1) + textEvent(sid, m1, "I will run the test suite first.") +
        toolUse(sid, m1, "bash", "error", { input: { command: "npm test" }, state: { error: "The user rejected permission to use this specific tool call." } }) +
        stepFinish(sid, m1, "tool-calls"),
    );
    process.stderr.write("! permission requested: bash (npm test); auto-rejecting\n");
  },
  "agent-not-found": (io) => {
    agentWarning(io.env, true);
    io.write(finalText(io.sessionId, io.env.AGENT_STUB_RESPONSE || "DONE\nanswered by the default agent"));
  },
  "stdin-wait": (io) => {
    if (!io.stdin.trim()) {
      process.stderr.write("Error: You must provide a message or a command\n");
      process.exitCode = 1;
      return;
    }
    io.write(finalText(io.sessionId, `DONE\nread ${Buffer.byteLength(io.stdin)} bytes from stdin: ${io.stdin.split("\n")[0]}`));
  },
  resume: (io) => {
    if (flag("-s", "--session") === undefined) {
      process.stderr.write("agent-stub: resume mode without -s\n");
      process.exitCode = 1;
      return;
    }
    io.write(finalText(io.sessionId, `DONE\nresumed ${io.sessionId}`));
  },
  "late-session": (io) => {
    const sid = io.sessionId;
    const m0 = nextId("msg");
    const m1 = nextId("msg");
    io.write(line({ type: "step_start", timestamp: Date.now(), part: { id: nextId("prt"), messageID: m0, type: "step-start" } }));
    io.write(line({ type: "step_finish", timestamp: Date.now(), sessionID: "", part: { id: nextId("prt"), messageID: m0, type: "step-finish", reason: "stop", cost: 0, tokens: { input: 1, output: 0, reasoning: 0, cache: { read: 0, write: 0 } } } }));
    io.write(stepStart(sid, m1) + textEvent(sid, m1, "DONE\nlate session") + stepFinish(sid, m1));
    remember(sid, stored(m1, { text: "DONE\nlate session", finish: "stop" }));
  },
  "no-text-events": (io) => {
    const sid = io.sessionId;
    const m1 = nextId("msg");
    io.write(stepStart(sid, m1) + toolUse(sid, m1, "read", "completed", { input: { filePath: "a.txt" }, state: { output: "x" } }) + stepFinish(sid, m1));
    remember(sid, stored(m1, { text: io.env.AGENT_STUB_RESPONSE || "DONE\nfrom the session export", finish: "stop" }));
  },
  "detached-bash": (io) => {
    io.write(stepStart(io.sessionId, nextId("msg")));
    const grandchild = ignoring("");
    const child = ignoring(
      `require("node:child_process").spawn(process.execPath, ["-e", ${JSON.stringify(grandchild)}, "agent-stub-descendant", process.env.AGENT_STUB_PIDS || ""], { detached: true, stdio: "ignore" }).unref();`,
    );
    spawn(process.execPath, ["-e", child, "agent-stub-descendant", io.env.AGENT_STUB_PIDS || ""], { detached: true, stdio: "ignore" }).unref();
    io.forever();
  },
};

// `opencode export <id>`: {info, messages: [{info, parts}]} on stdout [02 §3].
function exportSession(env, id) {
  appendLine(env.AGENT_STUB_CALL_LOG, `export ${id} key=${env[env.AGENT_STUB_SECRET_VAR || "DEEPSEEK_API_KEY"] ? "set" : "unset"}`);
  const record = readJson(storeFile(env, id));
  if (!record) {
    err("Error: Session not found\n");
    process.exit(1);
  }
  if (env.AGENT_STUB_EXPORT === "fail") {
    err("Error: export failed\n");
    process.exit(1);
  }
  const [providerID, ...rest] = String(record.model ?? "stub/stub-model").split("/");
  const assistant = {
    info: {
      id: record.messageId ?? nextId("msg"), sessionID: id, role: "assistant", time: { created: record.created ?? Date.now() }, providerID, modelID: rest.join("/"),
      cost: 0.0012, tokens: { input: 120, output: 30, reasoning: 0, cache: { read: 0, write: 0 } },
      ...(record.error ? { error: record.error } : {}), ...(record.finish ? { finish: record.finish } : {}),
    },
    parts: record.text ? [{ id: nextId("prt"), type: "step-start" }, { id: nextId("prt"), type: "text", text: record.text }] : [],
  };
  const user = { info: { id: nextId("msg"), sessionID: id, role: "user", time: { created: (record.created ?? Date.now()) - 1 } }, parts: [{ id: nextId("prt"), type: "text", text: "(prompt)" }] };
  out(`${JSON.stringify({ info: { id, title: record.title ?? null, directory: record.dir }, messages: [user, assistant] }, null, 2)}\n`);
}

// `opencode auth list`: provider names and auth types, never values, then the provider variables that are set (names
// only) [02 §6]; the type and the variable name come dimmed (an ANSI escape), as OpenCode prints them.
function authList(env) {
  const dir = path.join(dataDir(env), "opencode");
  appendLine(env.AGENT_STUB_CALL_LOG, `auth-list ${dataDir(env)}`);
  const dim = "\x1b[90m";
  const block = (rows) => rows.map((row) => `●  ${row}\n│\n`).join("");
  const creds = readJson(path.join(dir, "stub-auth.json")) ?? {};
  const rows = Object.entries(creds).map(([id, entry]) => `${PROVIDER_NAMES[id] ?? id} ${dim}${entry?.type ?? "api"}`);
  out(`┌  Credentials ${dim}${path.join(dir, "auth.json")}\n│\n${block(rows)}└  ${rows.length} credentials\n`);
  const vars = Object.entries(ENV_VARS).filter(([name]) => env[name]).map(([name, id]) => `${PROVIDER_NAMES[id] ?? id} ${dim}${name}`);
  if (vars.length > 0) out(`\n┌  Environment\n│\n${block(vars)}└  ${vars.length} environment variable${vars.length === 1 ? "" : "s"}\n`);
}

module.exports = {
  name: "opencode-jsonl",
  version: VERSION,
  flags: FLAGS,
  help(flags) {
    const rows = flags.map((name) => `  ${ALIASES[name] ? `${ALIASES[name]}, ` : "    "}${name}`);
    return `opencode run [message..]\n\nrun opencode with a message\n\nPositionals:\n  message  message to send\n\nOptions:\n  -h, --help\n  -v, --version\n${rows.join("\n")}\n`;
  },
  answer(args, { env }) {
    if (args.includes("--version") && !args.includes("--print-env")) {
      appendLine(env.AGENT_STUB_CALL_LOG, `version ${env.WRAPPED || "-"}`);
      out(`${env.AGENT_STUB_VERSION || VERSION}\n`);
      return true;
    }
    if ((args[0] === "auth" || args[0] === "providers") && args[1] === "list") {
      authList(env);
      return true;
    }
    if (args[0] === "export" && args[1]) {
      exportSession(env, args[1]);
      return true;
    }
    return false;
  },
  // The session of this run (and OpenCode's session store): -s must name a session of this data dir and --dir.
  sessionId(get) {
    const env = process.env;
    const dir = path.resolve(get("--dir") ?? process.cwd());
    const given = get("-s") ?? get("--session");
    if (given !== undefined) {
      const record = readJson(storeFile(env, given));
      if (!record || record.dir !== dir) {
        err("Error: Session not found\n");
        process.exit(1);
      }
      return given;
    }
    const id = nextId("ses");
    try {
      fs.mkdirSync(path.dirname(storeFile(env, id)), { recursive: true });
      fs.writeFileSync(storeFile(env, id), JSON.stringify({ id, dir, title: get("--title") ?? null, model: get("-m") ?? get("--model") ?? null, text: null, error: null }));
    } catch {
      // an unwritable data dir only loses the session for resume and export
    }
    return id;
  },
  final({ sessionId, text }) {
    return finalText(sessionId, text);
  },
  error({ sessionId, message, errorClass }) {
    return errorEvents(sessionId, errorClass || "unknown", message);
  },
  modes,
};
