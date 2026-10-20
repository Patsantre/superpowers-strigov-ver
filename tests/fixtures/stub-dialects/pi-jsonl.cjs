// The "pi-jsonl" dialect of tests/fixtures/agent-stub.cjs: pi 1.3.x (@earendil-works/pi-coding-agent) as
// docs/research/universal-dispatchers/03-pi.md documents it — never a model call.
//
// What it reproduces:
// - argv: pi's options with their arity. An unknown short option is pi's "Unknown option: -x" with exit 1 [03 §3.3,
//   §11]. What pi does with an unknown long option is not documented (unverified): the stub refuses it with a message
//   of its own (exit 1), only so that an adapter typo fails a test. Positional arguments would be extra turns: the stub
//   refuses them (exit 1), the adapter must never pass one.
// - `--mode json`: strict JSONL on stdout — line 1 the session header {"type":"session","version":3,"id","timestamp",
//   "cwd"}, then agent_start, turn_start / turn_end, message_start / message_update / message_end (user and assistant
//   messages; the assistant ones carry provider, model, usage, stopReason, errorMessage), tool_execution_*,
//   auto_retry_*, agent_end and agent_settled {aborted}. Without `--mode json` it is print mode [03 §3.2]: the final
//   text only; an assistant error or abort goes to stderr with exit 1; a truncated answer (stopReason "length") prints
//   its text, warns "Response was truncated…" on stderr and exits 1.
// - Provider errors end in exit 0 with stopReason "error" and errorMessage in the events; startup errors are one
//   stderr line and exit 1 ("No API key found for <p>.", "Model "<m>" not found. …", "Failed to load extension …").
// - Sessions: `--session-dir D --session-id X` resumes the file in D whose header has id X and cwd = this cwd;
//   otherwise it warns "No project session found with id 'X'; creating a new session with that id." on stderr and
//   creates D/<time>_X.jsonl at the first message. `--no-session` keeps nothing.
// - `-e <x>`: one of the adapter's BUILTIN_EXTENSIONS (bin/lib/adapters/pi.mjs, [03 §9]; loaded from there, so the
//   stub and doctor's check cannot drift) or an existing file; else "Failed to load extension".
// - `auth check --provider P --json`: AGENT_STUB_AUTH = ready | not_ready | invalid (default not_ready) → exit 0 / 1 /
//   2 with {"provider","status","authType"} (pi's JSON shape beyond authType is not documented: a guess). Every `auth`
//   call is appended to AGENT_STUB_AUTH_LOG as {argv, agentDir, keyVars}; `auth print-*` is refused (exit 3).
//
// Modes of this dialect (they win over the generic ones of agent-stub.cjs):
//   error-then-recover  an assistant error (429), auto_retry_start / auto_retry_end{success:true}, then the answer
//   retry-exhausted     three auto retries, auto_retry_end{success:false, finalError}, a final assistant error; exit 0
//   auth | model-not-found | unknown-provider   pi's startup errors: one stderr line, exit 1, no session
//   custom-model        pi's warning `Model "<id>" not found for provider "<p>". Using custom model id.` on stderr
//                       (pi runs on [03 §5.1]), then a 429 the retries do not cure; exit 0
//   auth-401 | quota | rate-limit | server | network | context   provider errors in the events, exit 0
//   truncated           the answer with stopReason "length"
//   ends-on-tool        the run ends on a tool result: the last assistant message has stopReason "toolUse"
//   aborted             the last assistant message is "aborted", agent_settled {aborted: true}
//   no-settle           the answer but no agent_settled, exit 0
//   late-events         the answer, then queue_update / entry_appended / session_info_changed after agent_settled
//   tool-blocked        a tool call that an extension refuses headless (isError), then the model's own answer
//   context-echo        the answer "DONE\nsession <id> resumed=<bool> prior=<n> stdin=<chars>"
//   lose-session        acts as if the session file of --session-id were not there (the warning, a new session)
//   leak-error          a bash tool turn whose output (`env`) prints the value of $AGENT_STUB_SECRET_VAR (default
//                       PLAIN_API_KEY) — in the events and as a toolResult entry of the session file — then a provider
//                       error (503); exit 0
//   leak-hang           the same tool turn, written to the session file and to stdout, then waits forever (cancel and
//                       timeout); SIGTERM ends it
//   stdin-wait          answers only once stdin reached EOF, with the number of characters read
//   pi-sigterm          starts a "bash tool" child in a process group of its own that ignores SIGTERM (its pid goes
//                       to AGENT_STUB_PIDS) and waits; on SIGTERM it SIGKILLs that group and exits 143, as pi does;
//                       SIGINT is not handled (Node's default ends the stub, the child is orphaned). Each signal is
//                       appended to AGENT_STUB_SIGNALS as "<SIGNAL> <epoch ms>", the exit as "exit 143"
//   term-ignore         a wedged pi: appends SIGTERM / SIGINT / SIGHUP to AGENT_STUB_SIGNALS with their time and
//                       ignores them; only SIGKILL ends it
// AGENT_STUB_RESPONSE, AGENT_STUB_MESSAGE as in agent-stub.cjs. AGENT_STUB_STDERR_LINES=<n>: a run prints n lines of
// extension chatter to stderr after its startup output (the "No project session found" warning included) — more than
// the core's 200-line stderr tail keeps. Install the signal handlers here, before the stub reads stdin and writes
// AGENT_STUB_RECORD (its readiness handshake).
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawn } = require("node:child_process");

const VERSION = "1.3.0";
// pi's options (src/cli/args.ts, [03 §2.3, §5.1, §7, §9]) with their arity: 1 takes a value.
const OPTIONS = {
  "--mode": 1, "--print": 0, "-p": 0, "--model": 1, "--provider": 1, "--models": 1, "--thinking": 1,
  "--session-dir": 1, "--session-id": 1, "--session": 1, "--no-session": 0, "--continue": 0, "-c": 0, "--fork": 1,
  "--approve": 0, "--no-approve": 0, "-na": 0, "-ne": 0, "-ns": 0, "-np": 0, "-nc": 0, "--no-mcp": 0, "--no-themes": 0,
  "--tools": 1, "-t": 1, "--exclude-tools": 1, "-xt": 1, "-nbt": 0, "-nt": 0, "-e": 1, "--skill": 1, "--prompt-template": 1,
  "--system-prompt": 1, "--append-system-prompt": 1, "--offline": 0, "--api-key": 1, "--list-models": 0,
};
// The adapter's list of built-in extensions, read only when a run names one (require() of an ES module: Node 20.19+ /
// 22.12+).
const builtinExtensions = () => require(path.join(__dirname, "..", "..", "..", "bin", "lib", "adapters", "pi.mjs")).BUILTIN_EXTENSIONS;
// The --help lines; AGENT_STUB_HELP_DROP removes some by their flag.
const HELP = [
  ["--mode", "--mode <mode>", "Output mode: text (default), json or rpc"],
  ["--print", "-p, --print", "Print the last assistant message and exit"],
  ["--model", "--model <pattern>", "Model: id, provider/id, optional :<thinking>"],
  ["--provider", "--provider <name>", "Restrict the model lookup to one provider"],
  ["--thinking", "--thinking <level>", "off, minimal, low, medium, high, xhigh, max"],
  ["--session-dir", "--session-dir <dir>", "Directory for session files"],
  ["--session-id", "--session-id <id>", "Open the session with this id, or create it"],
  ["--no-session", "--no-session", "Do not save the session"],
  ["--no-approve", "-na, --no-approve", "Do not load project resources (.pi/*)"],
  ["-ne", "-ne", "Disable extension discovery"],
  ["-ns", "-ns", "Disable skill discovery"],
  ["-np", "-np", "Disable prompt template discovery"],
  ["-nc", "-nc", "Disable context files (AGENTS.md, CLAUDE.md)"],
  ["--no-mcp", "--no-mcp", "Disable MCP servers"],
  ["--tools", "-t, --tools <list>", "Allowed tools, e.g. read,grep,find,ls"],
  ["-nt", "-nt, --no-tools", "Disable all tools"],
  ["-e", "-e <path|builtin:name>", "Load an extension (also under -ne)"],
  ["--offline", "--offline", "No automatic network activity"],
];
const FLAGS = HELP.map(([flag]) => flag);
const USAGE = { input: 1200, output: 80, cacheRead: 300, cacheWrite: 0, totalTokens: 1580, cost: { input: 0.0012, output: 0.0004, cacheRead: 0.00003, cacheWrite: 0, total: 0.00163 } };

const env = process.env;
const mode = env.AGENT_STUB_MODE || "ok";
const state = {
  json: false,
  sessionId: null,
  dir: null,
  file: null,
  persist: true,
  resumed: false,
  prior: 0,
  provider: "stub-provider",
  modelId: "stub-model",
  lastEntry: null,
  child: null,
  tools: true,
};

const line = (value) => `${JSON.stringify(value)}\n`;
const now = () => new Date().toISOString();
const fail = (message, code = 1) => {
  process.stderr.write(`${message}\n`);
  process.exit(code);
};
const appendTo = (file, text) => {
  if (file) fs.appendFileSync(file, `${text}\n`);
};

// ---------- non-run invocations ----------

function authCommand(args, write) {
  appendTo(
    env.AGENT_STUB_AUTH_LOG,
    JSON.stringify({ argv: args, agentDir: env.PI_CODING_AGENT_DIR ?? null, keyVars: Object.keys(env).filter((name) => /_API_KEY$/.test(name)).sort() }),
  );
  if (args[0] !== "check") fail(`agent-stub: pi auth ${args[0] ?? ""} is not reproduced (it would print a secret)`, 3);
  const at = args.indexOf("--provider");
  const provider = at >= 0 ? args[at + 1] : null;
  const status = env.AGENT_STUB_AUTH || "not_ready";
  const code = { ready: 0, not_ready: 1, invalid: 2 }[status] ?? 1;
  if (args.includes("--json")) write(line({ provider, status, authType: status === "not_ready" ? null : "api_key" }));
  else write(`${provider}: ${status}\n`);
  process.exit(code);
}

// ---------- a run: argv, extensions, the session ----------

function parseRun(argv) {
  const values = {};
  const extensions = [];
  const positionals = [];
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("-")) {
      positionals.push(arg);
      continue;
    }
    if (!(arg in OPTIONS)) {
      if (arg.startsWith("--")) fail(`agent-stub: unknown long option ${arg} (pi's handling of it is unverified; the stub refuses it)`);
      fail(`Unknown option: ${arg}`); // args.ts:263, short options only [03 §11]
    }
    if (OPTIONS[arg] === 0) {
      values[arg] = true;
      continue;
    }
    const value = argv[i + 1];
    if (value === undefined) fail(`Option ${arg} requires a value`);
    i += 1;
    if (arg === "-e") extensions.push(value);
    else values[arg] = value;
  }
  return { values, extensions, positionals };
}

// The header of the file in `dir` that holds session `id` for this cwd, with its entry count.
function findSession(dir, id) {
  let names = [];
  try {
    names = fs.readdirSync(dir).filter((name) => name.endsWith(".jsonl"));
  } catch {
    return null;
  }
  for (const name of names) {
    const file = path.join(dir, name);
    const lines = fs.readFileSync(file, "utf8").split("\n").filter(Boolean);
    let header = null;
    try {
      header = JSON.parse(lines[0]);
    } catch {
      continue;
    }
    if (header?.type === "session" && header.id === id && header.cwd === process.cwd()) {
      const last = lines.length > 1 ? JSON.parse(lines[lines.length - 1]) : null;
      return { file, header, prior: lines.length - 1, lastEntry: last?.id ?? null };
    }
  }
  return null;
}

function prepareRun(argv) {
  const { values, extensions, positionals } = parseRun(argv);
  if (positionals.length > 0) fail(`agent-stub: positional arguments are extra turns in pi; refusing ${positionals.length} of them`);
  if (values["--mode"] !== undefined && !["text", "json", "rpc"].includes(values["--mode"])) fail(`Invalid mode: ${values["--mode"]}`);
  state.json = values["--mode"] === "json";
  state.tools = !(values["-nt"] || values["--tools"] === ""); // -nt: no tools, so the model answers without a tool turn
  for (const extension of extensions) {
    const ok = extension.startsWith("builtin:") ? builtinExtensions().includes(extension) : fs.existsSync(extension);
    if (!ok) fail(`Failed to load extension "${extension}": ${extension.startsWith("builtin:") ? "unknown built-in extension" : "ENOENT: no such file or directory"}\nHint: check the path, or start pi with -ne to skip extensions`);
  }
  const model = values["--model"];
  if (typeof model === "string" && model.includes("/")) {
    state.provider = model.slice(0, model.indexOf("/"));
    state.modelId = model.slice(model.indexOf("/") + 1);
  } else if (typeof model === "string") state.modelId = model;
  const id = values["--session-id"];
  if (values["--no-session"]) {
    state.persist = false;
    state.sessionId = id ?? crypto.randomUUID();
    return;
  }
  state.dir = values["--session-dir"] ?? path.join(env.PI_CODING_AGENT_DIR || path.join(env.HOME || "/nonexistent", ".pi", "agent"), "sessions");
  state.sessionId = id ?? crypto.randomUUID();
  const found = id && mode !== "lose-session" ? findSession(state.dir, id) : null;
  if (found) {
    state.file = found.file;
    state.resumed = true;
    state.prior = found.prior;
    state.lastEntry = found.lastEntry;
    return;
  }
  if (id) process.stderr.write(`No project session found with id '${id}'; creating a new session with that id.\n`);
  state.file = path.join(state.dir, `${now().replace(/[:.]/g, "-")}_${state.sessionId}.jsonl`);
}

// Signal dispositions of the signal modes, set before stdin is read (see the header).
function installSignals() {
  const record = (signal) => appendTo(env.AGENT_STUB_SIGNALS, `${signal} ${Date.now()}`);
  if (mode === "pi-sigterm") {
    process.on("SIGTERM", () => {
      record("SIGTERM");
      if (state.child) {
        try {
          process.kill(-state.child, "SIGKILL"); // killTrackedDetachedChildren()
        } catch {
          // already gone
        }
      }
      appendTo(env.AGENT_STUB_SIGNALS, "exit 143");
      process.exit(143);
    });
    const onSigint = () => {
      record("SIGINT");
      process.removeListener("SIGINT", onSigint);
      process.kill(process.pid, "SIGINT"); // Node's default: the stub ends, its bash group lives on
    };
    process.on("SIGINT", onSigint);
  }
  if (mode === "term-ignore") for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(signal, () => record(signal));
}

// ---------- events and the session file ----------

const header = () => ({ type: "session", version: 3, id: state.sessionId, timestamp: now(), cwd: process.cwd() });

// Appends entries to the session file, created with its header at the first message (as pi's session manager does).
function persist(messages) {
  if (!state.persist || !state.file) return;
  if (!fs.existsSync(state.file)) {
    fs.mkdirSync(path.dirname(state.file), { recursive: true });
    fs.writeFileSync(state.file, line(header()), { flag: "wx" });
  }
  for (const message of messages) {
    const id = crypto.randomUUID().slice(0, 8);
    fs.appendFileSync(state.file, line({ type: "message", id, parentId: state.lastEntry, timestamp: now(), message }));
    state.lastEntry = id;
  }
}

const userMessage = () => ({ role: "user", content: [{ type: "text", text: "(the prompt read from stdin)" }], timestamp: Date.now() });
function assistantMessage({ text = null, thinking = null, toolCall = null, stopReason = "stop", errorMessage = null }) {
  const content = [];
  if (thinking) content.push({ type: "thinking", thinking });
  if (text !== null) content.push({ type: "text", text });
  if (toolCall) content.push({ type: "toolCall", id: toolCall.id, name: toolCall.name, arguments: toolCall.args });
  return {
    role: "assistant",
    content,
    api: "openai-completions",
    provider: state.provider,
    model: state.modelId,
    usage: USAGE,
    stopReason,
    ...(errorMessage ? { errorMessage } : {}),
    timestamp: Date.now(),
  };
}

const messageEvents = (message) => [
  { type: "message_start", message: { ...message, content: [] } },
  ...(message.role === "assistant" && textOf(message)
    ? [{ type: "message_update", message, usage: { ...USAGE, totalTokens: 0 }, assistantMessageEvent: { type: "text_delta", delta: textOf(message) } }]
    : []),
  { type: "message_end", message },
];
const textOf = (message) => message.content.filter((block) => block.type === "text").map((block) => block.text).join("\n");

// A tool turn: the assistant calls `read`, the tool answers. `toolError` makes the tool refuse.
function toolTurn({ toolError = null } = {}) {
  const call = { id: "call_1", name: toolError ? "bash" : "read", args: toolError ? { command: "rm -rf build" } : { path: "a.txt" } };
  const message = assistantMessage({ text: "Let me look at the repository first.", toolCall: call, stopReason: "toolUse" });
  const result = toolError ? { content: [{ type: "text", text: toolError }] } : { content: [{ type: "text", text: "x" }] };
  return {
    messages: [message],
    events: [
      { type: "turn_start" },
      ...messageEvents(message),
      { type: "tool_execution_start", toolCallId: call.id, toolName: call.name, args: call.args },
      { type: "tool_execution_end", toolCallId: call.id, toolName: call.name, result, isError: Boolean(toolError), durationMs: 3 },
      { type: "turn_end", message, toolResults: [result] },
    ],
  };
}

// A bash tool turn whose output prints the key, as `env` would: the tool result is a message of its own (role
// toolResult) in the events and in the session file [03 §4 "Format"].
function leakTurn() {
  const name = env.AGENT_STUB_SECRET_VAR || "PLAIN_API_KEY";
  const call = { id: "call_env", name: "bash", args: { command: "env | grep _KEY" } };
  const message = assistantMessage({ text: "Let me check the environment.", toolCall: call, stopReason: "toolUse" });
  const output = { content: [{ type: "text", text: `${name}=${env[name] ?? ""}\n` }] };
  const result = { role: "toolResult", toolCallId: call.id, toolName: call.name, ...output, isError: false, timestamp: Date.now() };
  return {
    messages: [message, result],
    events: [
      { type: "turn_start" },
      ...messageEvents(message),
      { type: "tool_execution_start", toolCallId: call.id, toolName: call.name, args: call.args },
      { type: "tool_execution_end", toolCallId: call.id, toolName: call.name, result: output, isError: false, durationMs: 4 },
      ...messageEvents(result),
      { type: "turn_end", message, toolResults: [result] },
    ],
  };
}

// The complete stdout of a run: header, the user's turn, `turns` (tool turns etc.), the last assistant message, and
// the closing events. Also writes the session file.
function run({ turns = [], last, settle = { aborted: false }, after = [], preface = [] }) {
  const user = userMessage();
  const messages = [user, ...turns.flatMap((turn) => turn.messages), ...(last ? [last] : [])];
  persist(messages);
  if (!state.json) {
    // print mode [03 §3.2]: the text of the last assistant message; an error or abort goes to stderr with exit 1; a
    // truncated answer is printed with a stderr warning and exit 1 (since 1.2.0)
    if (last && (last.stopReason === "error" || last.stopReason === "aborted")) {
      process.stderr.write(`${last.errorMessage ?? "aborted"}\n`);
      process.exitCode = 1;
      return "";
    }
    if (last && last.stopReason === "length") {
      process.stderr.write("Response was truncated: the model reached its output token limit.\n");
      process.exitCode = 1;
    }
    return last && last.stopReason !== "toolUse" ? `${textOf(last)}\n` : "";
  }
  const events = [
    header(),
    { type: "agent_start" },
    ...preface,
    { type: "turn_start" },
    ...messageEvents(user),
    ...turns.flatMap((turn) => turn.events),
    ...(last ? [{ type: "turn_start" }, ...messageEvents(last), { type: "turn_end", message: last, toolResults: [] }] : []),
    { type: "agent_end", messages, willRetry: false },
    ...(settle ? [{ type: "agent_settled", ...settle }] : []),
    ...after,
  ];
  return events.map(line).join("");
}

const answer = (text, extra = {}) => run({ turns: state.tools ? [toolTurn()] : [], last: assistantMessage({ text, thinking: "The user wants a report." }), ...extra });
const providerError = (message) => run({ last: assistantMessage({ text: null, stopReason: "error", errorMessage: message }) });
const startupError = (message) => fail(message);

// A failed attempt pi retries on its own (auto_retry_*) before the outcome.
function retried(message, { success }) {
  const failedAttempt = assistantMessage({ stopReason: "error", errorMessage: message });
  const attempts = success ? 1 : 3;
  const preface = [
    { type: "turn_start" },
    ...messageEvents(failedAttempt),
    { type: "turn_end", message: failedAttempt, toolResults: [] },
    { type: "agent_end", messages: [failedAttempt], willRetry: true },
  ];
  for (let attempt = 1; attempt <= attempts; attempt += 1) preface.push({ type: "auto_retry_start", attempt, maxAttempts: 3, delayMs: 2000, errorMessage: message });
  preface.push({ type: "auto_retry_end", success, attempt: attempts, ...(success ? {} : { finalError: message }) });
  return preface;
}

module.exports = {
  name: "pi-jsonl",
  version: VERSION,
  flags: FLAGS,
  help(flags) {
    const shown = HELP.filter(([flag]) => flags.includes(flag));
    return `pi - a minimal coding agent (agent-stub, pi-jsonl dialect)\n\nUsage: pi [options] [messages...]\n\nOptions:\n${shown.map(([, form, text]) => `  ${form.padEnd(28)}${text}`).join("\n")}\n  --version                   Print the version\n  --help                      Show this help\n\nCommands:\n  pi auth check --provider <name> [--json]\n`;
  },
  // Every invocation reaches this first: `auth …` is answered here; a run is validated (argv, extensions), its session
  // resolved and the signal modes armed; --version / --help go on to the generic stub.
  answer(argv, { write }) {
    if (argv[0] === "auth") return authCommand(argv.slice(1), write);
    if (argv.includes("--version") || argv.includes("--help") || argv.includes("--print-env")) return false;
    prepareRun(argv);
    installSignals();
    for (let i = 1; i <= Number(env.AGENT_STUB_STDERR_LINES || 0); i += 1) process.stderr.write(`[extension] chatter line ${i}\n`);
    return false;
  },
  sessionId() {
    return state.sessionId;
  },
  final({ text }) {
    return answer(text);
  },
  error({ message }) {
    return providerError(message);
  },
  modes: {
    "error-then-recover": ({ write }) =>
      write(run({ preface: retried("429 Too Many Requests: rate limit reached for requests", { success: true }), turns: [toolTurn()], last: assistantMessage({ text: env.AGENT_STUB_RESPONSE || "DONE\nrecovered after a retry" }) })),
    "retry-exhausted": ({ write }) => {
      const message = env.AGENT_STUB_MESSAGE || "429 Too Many Requests: rate limit reached for requests";
      write(run({ preface: retried(message, { success: false }), last: assistantMessage({ stopReason: "error", errorMessage: message }) }));
    },
    auth: () => startupError(`No API key found for ${state.provider}.\n\nSet ${state.provider.toUpperCase()}_API_KEY or run /login.`),
    "model-not-found": () => startupError(`Model "${state.provider}/${state.modelId}" not found. Use --list-models to see available models.`),
    "unknown-provider": () => startupError(`Unknown provider "${state.provider}". Use --list-models to see available providers.`),
    "custom-model": ({ write }) => {
      process.stderr.write(`Model "${state.modelId}" not found for provider "${state.provider}". Using custom model id.\n`);
      const message = "429 Too Many Requests: rate limit reached for requests";
      write(run({ preface: retried(message, { success: false }), last: assistantMessage({ stopReason: "error", errorMessage: message }) }));
    },
    "auth-401": ({ write }) => write(providerError('401 {"error":{"message":"Invalid API key provided","type":"authentication_error"}}')),
    quota: ({ write }) => write(providerError('429 {"error":{"code":"insufficient_quota","message":"You exceeded your current quota, please check your plan and billing details."}}')),
    "rate-limit": ({ write }) => {
      const message = "429 Too Many Requests: rate limit reached for requests";
      write(run({ preface: retried(message, { success: false }), last: assistantMessage({ stopReason: "error", errorMessage: message }) }));
    },
    server: ({ write }) => write(providerError("503 Service Unavailable: upstream connect error")),
    network: ({ write }) => write(providerError("TypeError: fetch failed (getaddrinfo ENOTFOUND api.example.com)")),
    context: ({ write }) => write(providerError("400 This model's maximum context length is 131072 tokens. However, your messages resulted in 140213 tokens.")),
    truncated: ({ write }) => write(run({ turns: [toolTurn()], last: assistantMessage({ text: "DONE\nthe report was cut", stopReason: "length" }) })),
    "ends-on-tool": ({ write }) => write(run({ turns: [toolTurn()] })),
    aborted: ({ write }) => write(run({ turns: [toolTurn()], last: assistantMessage({ text: "partial", stopReason: "aborted" }), settle: { aborted: true } })),
    "no-settle": ({ write }) => write(answer("DONE\nbut never settled", { settle: null })),
    "late-events": ({ write }) =>
      write(
        answer(env.AGENT_STUB_RESPONSE || "DONE\nwith late events", {
          after: [
            { type: "queue_update", steering: [], followUp: [] },
            { type: "entry_appended", entry: { type: "session_info", id: "late1" } },
            { type: "session_info_changed", name: "renamed late" },
          ],
        }),
      ),
    "tool-blocked": ({ write }) =>
      write(run({ turns: [toolTurn({ toolError: "Blocked: confirmation required, but no UI is available" })], last: assistantMessage({ text: env.AGENT_STUB_RESPONSE || "BLOCKED\nthe bash call was refused" }) })),
    "context-echo": ({ write, stdin }) => write(answer(`DONE\nsession ${state.sessionId} resumed=${state.resumed} prior=${state.prior} stdin=${stdin.trim().length}`)),
    "lose-session": ({ write }) => write(answer(env.AGENT_STUB_RESPONSE || "DONE\nanswered without the earlier context")),
    "leak-error": ({ write }) => write(run({ turns: [leakTurn()], last: assistantMessage({ stopReason: "error", errorMessage: "503 Service Unavailable: upstream connect error" }) })),
    "leak-hang": ({ write, forever }) => {
      const user = userMessage();
      const turn = leakTurn();
      persist([user, ...turn.messages]);
      if (state.json) write([header(), { type: "agent_start" }, { type: "turn_start" }, ...messageEvents(user), ...turn.events].map(line).join(""));
      forever();
    },
    "stdin-wait": ({ write, stdin }) => write(answer(`DONE\nstdin read to EOF: ${stdin.trim().length} chars`)),
    "pi-sigterm": ({ forever }) => {
      // A bash tool: pi spawns it detached (its own process group) and tracks its pid [03 §10].
      const script = `for (const s of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(s, () => {}); require("node:fs").appendFileSync(process.env.AGENT_STUB_PIDS, process.pid + "\\n"); setInterval(() => {}, 1 << 30);`;
      const child = spawn(process.execPath, ["-e", script, "agent-stub-descendant", env.AGENT_STUB_PIDS || ""], { detached: true, stdio: "ignore" });
      state.child = child.pid;
      child.unref();
      forever();
    },
    "term-ignore": ({ forever }) => forever(),
  },
};
