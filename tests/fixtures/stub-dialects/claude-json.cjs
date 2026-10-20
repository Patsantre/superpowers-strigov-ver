// The "claude-json" dialect of tests/fixtures/agent-stub.cjs: Claude Code 2.1.302 in print mode (`claude -p
// --output-format json`) as docs/research/universal-dispatchers/01-claude-code-headless.md records it — never a model
// call. Cited as [01 §n] / [01 E<n>] (its experiments).
//
// What it reproduces:
// - argv: claude's options with their arity (--allowedTools takes one or more values); anything else is
//   "Error: unknown option '<x>'" with exit 1 [01 E24]; `--output-format stream-json` without --verbose is refused with
//   claude's text [01 E12]. Checks of the adapter's contract — -p and --output-format json present, no positional
//   prompt, a UUID --session-id, never --session-id together with --resume, a readable --settings JSON file and
//   --append-system-prompt-file, known --effort / --permission-mode / --setting-sources values — end with
//   "agent-stub: …" on stderr and exit 2 (not claude's text).
// - Output: one JSON object on one line: type "result", subtype, is_error, duration_ms, duration_api_ms, num_turns,
//   result, stop_reason, session_id, total_cost_usd, usage, modelUsage, permission_denials, terminal_reason,
//   api_error_status, uuid [01 §3]. API errors: is_error true with subtype "success", terminal_reason "api_error"
//   ("prompt_too_long" for the 400 "prompt is too long"), api_error_status and claude's text for that status, exit 1
//   [01 §11; the parts the report elides with "…" are paraphrased]. Max turns: subtype "error_max_turns", result null,
//   exit 1 [01 E14]. Permission denials: exit 0, is_error false, permission_denials listed [01 E14].
// - Settings: `env` of the user settings ($CONFIG/settings.json under --setting-sources user), of the project
//   (<cwd>/.claude/settings.json under "project", also the default when the flag is absent) and of --settings, in that
//   order, applied over the process environment [01 §9, E9, E18].
// - Credentials by claude's precedence [01 §6]: ANTHROPIC_AUTH_TOKEN (Bearer; with ANTHROPIC_API_KEY also set, both
//   headers [E3]) › ANTHROPIC_API_KEY (x-api-key) › apiKeyHelper (both headers) › a claude.ai login. The login is the marker file stub-login.json in the config dir
//   ($CLAUDE_CONFIG_DIR, else ~/.claude): the stub never reads a real credential store. No credential: result
//   "Not logged in · Please run /login", api_error_status null, exit 1, no request [01 E5].
// - Model: --model, else ANTHROPIC_MODEL, else the opus alias; an alias (opus, sonnet, haiku, fable) resolves through
//   ANTHROPIC_DEFAULT_<ALIAS>_MODEL, else to claude-<alias>-stub [01 §5, E17]. A model id that does not start with
//   "claude-" prints "[claude-code:unrecognized_model] {…}" on stderr on every run [01 §3].
// - Effort: CLAUDE_CODE_EFFORT_LEVEL (after the settings env) beats --effort; the default is high [01 §5, E10].
// - Sessions: $CONFIG/projects/<cwd with non-alphanumerics as "-">/<sid>.jsonl gets one line per run [01 §4, E6];
//   --resume of an id without that file prints "No conversation found with session ID: <id>" on stderr and exits 1
//   with an empty stdout [01 E7]. --no-session-persistence writes nothing.
// - Signals: SIGTERM → exit 143, SIGINT → exit 0, stdout empty either way [01 §10, E21]; each is appended to
//   AGENT_STUB_SIGNALS as "<SIGNAL> <epoch ms>". The handlers are installed when the stub loads this module, before it
//   reads stdin and writes AGENT_STUB_RECORD (its readiness handshake). The generic ignore-term / trap-signals /
//   sigterm-exit0 modes keep their own handlers.
// - `--version`: "<AGENT_STUB_VERSION or 2.1.302> (Claude Code)" (the report records the version only), logged to
//   AGENT_STUB_CALL_LOG like the generic one. `--help`: the generic one, with claude-like lines.
// - `auth status --json`: {loggedIn, authMethod, apiKeySource, configDirectory, analyticsDisabled} [01 §6, E20]:
//   oauth_token for ANTHROPIC_AUTH_TOKEN, api_key for ANTHROPIC_API_KEY (spec §3.6 A1; not in [01]), api_key_helper for
//   an apiKeyHelper, claude.ai for the login marker (a guess), else loggedIn false with authMethod none and exit 1 (the
//   exit code is a guess). The `env` and apiKeyHelper of $CONFIG/settings.json and of the cwd's .claude/settings.json
//   count (the default setting sources). Each call is appended to AGENT_STUB_AUTH_LOG as {argv, wrapped ($WRAPPED of a
//   test wrap, else null), cwd, configDirectory, authMethod, keys: {<key var>: sha256 prefix of its value | null}}.
// - Permissions: the allow / deny rules of the loaded settings and of --allowedTools / --disallowedTools add up; see
//   bashVerdict() for how a Bash command is judged.
//
// Observation: every run of a dialect mode writes <AGENT_STUB_RECORD>.claude.json before it answers: {settings (the
// --settings file), system (the --append-system-prompt-file text), settingSources, model, effort, baseUrl, headers
// (names only), credential, sessionFile, resumed, priorRuns, permissions ({allow, deny} as loaded), bash ({<command>:
// allow | deny | no-tool} for each command of AGENT_STUB_BASH_PROBE, a JSON array)}. A test sees there what claude
// would have used, also after the probe's scratch dir is gone.
//
// Modes of this dialect (they win over the generic ones; the generic exit0-error renders error() below, exit 0):
//   ok | slow     the answer (AGENT_STUB_RESPONSE or "DONE\nstub finished"), exit 0; slow after AGENT_STUB_DELAY_MS
//   api-error     AGENT_STUB_STATUS: 401 402 403 404 429 5xx 529, toolong (400 prompt_too_long) or refused (status
//                 null, ECONNREFUSED); default 500. AGENT_STUB_MESSAGE is the provider's text; exit AGENT_STUB_EXIT
//                 (default 1)
//   max-turns     error_max_turns, result null, exit 1
//   denied        the answer plus two permission_denials (Bash, Write), exit 0 — what dontAsk does [01 E14]
//   denied-empty  permission_denials and an empty result, exit 0
//   empty         an empty result without denials, exit 0
//   wait          waits forever with claude's signal behaviour
//   term-ignore   a wedged claude: appends SIGTERM / SIGINT / SIGHUP to AGENT_STUB_SIGNALS and ignores them
// AGENT_STUB_BG_TOKENS=1 adds a small haiku-tier entry to modelUsage (a background call) next to the main model.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

const VERSION = "2.1.302";
const MODE = process.env.AGENT_STUB_MODE || "ok";
const LOGIN_MARKER = "stub-login.json";
const ALIASES = ["opus", "sonnet", "haiku", "fable"];
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const KEY_VARS = ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"];

// claude's options [01 §2–§9, `claude --help`] with their arity: 0 a switch, 1 one value, "*" one or more values.
const OPTIONS = {
  "-p": 0, "--print": 0, "--output-format": 1, "--verbose": 0, "--bare": 0, "--setting-sources": 1, "--settings": 1,
  "--model": 1, "--fallback-model": 1, "--effort": 1, "--tools": 1, "--allowedTools": "*", "--allowed-tools": "*",
  "--disallowedTools": "*", "--disallowed-tools": "*", "--strict-mcp-config": 0, "--disable-slash-commands": 0,
  "--system-prompt": 1, "--system-prompt-file": 1, "--append-system-prompt": 1, "--append-system-prompt-file": 1,
  "--session-id": 1, "--resume": 1, "-r": 1, "--continue": 0, "-c": 0, "--fork-session": 0,
  "--no-session-persistence": 0, "--permission-mode": 1, "--dangerously-skip-permissions": 0, "--max-turns": 1,
  "--json-schema": 1, "--add-dir": "*",
};
// `--help` lines: [flag, metavar, text]; AGENT_STUB_HELP_DROP removes lines by their flag.
const HELP = [
  ["--print", "", "Print the response and exit (non-interactive); also -p"],
  ["--output-format", "<format>", 'Output format with --print: "text", "json" or "stream-json"'],
  ["--verbose", "", "Verbose output (required by stream-json)"],
  ["--bare", "", "Minimal mode: no hooks, skills, plugins, MCP, auto-memory or CLAUDE.md"],
  ["--setting-sources", "<sources>", "Comma-separated setting sources to load (user, project, local)"],
  ["--settings", "<file-or-json>", "Additional settings from a JSON file or string"],
  ["--model", "<model>", "Model for the session: an alias or a full model id"],
  ["--fallback-model", "<models>", "Fallback models on overload"],
  ["--effort", "<level>", "Effort level (low, medium, high, xhigh, max)"],
  ["--tools", "<tools>", 'Built-in tools available to the model ("" for none)'],
  ["--allowedTools", "<tools...>", 'Tools allowed without a prompt, e.g. "Bash(git diff:*)"'],
  ["--disallowedTools", "<tools...>", "Tools that are denied"],
  ["--strict-mcp-config", "", "Use only MCP servers from --mcp-config"],
  ["--disable-slash-commands", "", "Disable all skills"],
  ["--system-prompt-file", "<file>", "Replace the system prompt with a file"],
  ["--append-system-prompt-file", "<file>", "Append a file to the system prompt"],
  ["--session-id", "<uuid>", "Use this session id (a UUID)"],
  ["--resume", "[value]", "Resume a conversation by session id; also -r"],
  ["--continue", "", "Continue the most recent conversation in this directory; also -c"],
  ["--fork-session", "", "With --resume or --continue, start a new session id"],
  ["--no-session-persistence", "", "Do not save the session (it cannot be resumed)"],
  ["--permission-mode", "<mode>", "Permission mode (acceptEdits, auto, bypassPermissions, default, dontAsk, plan)"],
  ["--dangerously-skip-permissions", "", "Bypass all permission checks"],
  ["--max-turns", "<turns>", "Maximum number of agentic turns with --print"],
  ["--json-schema", "<schema>", "JSON Schema for structured output"],
  ["--add-dir", "<directories...>", "Additional directories tools may access"],
];
const EFFORTS = new Set(["low", "medium", "high", "xhigh", "max"]);
const PERMISSION_MODES = new Set(["acceptEdits", "auto", "bypassPermissions", "default", "dontAsk", "plan"]);
const SOURCES = new Set(["user", "project", "local"]);

const appendTo = (file, text) => {
  if (file) fs.appendFileSync(file, `${text}\n`);
};
const readJson = (file) => {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
};
const isObject = (value) => Boolean(value) && typeof value === "object" && !Array.isArray(value);
const sha = (value) => crypto.createHash("sha256").update(value).digest("hex").slice(0, 16);
// Output that must be complete before an explicit process.exit(): synchronous writes.
const outSync = (text) => fs.writeSync(1, text);
const errSync = (text) => fs.writeSync(2, text);
const stubRefuse = (message) => {
  errSync(`agent-stub: ${message}\n`);
  process.exit(2);
};

// ---- signals: claude -p ends with 143 on SIGTERM and with 0 on SIGINT, printing nothing [01 §10, E21] ----
const stamp = (signal) => appendTo(process.env.AGENT_STUB_SIGNALS, `${signal} ${Date.now()}`);
if (MODE === "term-ignore") {
  for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(signal, () => stamp(signal));
} else if (!["ignore-term", "trap-signals", "sigterm-exit0"].includes(MODE)) {
  process.on("SIGTERM", () => {
    stamp("SIGTERM");
    process.exit(143);
  });
  process.on("SIGINT", () => {
    stamp("SIGINT");
    process.exit(0);
  });
}

// ---- argv ----

function parseArgs(argv) {
  const opts = {};
  const positional = [];
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("-") || arg === "-") {
      positional.push(arg);
      continue;
    }
    const eq = arg.startsWith("--") ? arg.indexOf("=") : -1;
    const name = eq > 0 ? arg.slice(0, eq) : arg;
    const inline = eq > 0 ? arg.slice(eq + 1) : undefined;
    if (!Object.hasOwn(OPTIONS, name)) return { unknown: name };
    const arity = OPTIONS[name];
    if (arity === 0) {
      opts[name] = true;
    } else if (arity === 1) {
      const value = inline ?? argv[(i += 1)];
      if (value === undefined) return { missing: name };
      opts[name] = value;
    } else {
      const values = inline !== undefined ? [inline] : [];
      while (i + 1 < argv.length && !argv[i + 1].startsWith("-")) values.push(argv[(i += 1)]);
      if (values.length === 0) return { missing: name };
      opts[name] = [...(opts[name] ?? []), ...values];
    }
  }
  return { opts, positional };
}

// The checks before a run: claude's own refusals with its text, the adapter's contract as stub refusals.
function checkRun(argv) {
  const parsed = parseArgs(argv);
  if (parsed.unknown) {
    errSync(`Error: unknown option '${parsed.unknown}'\n`);
    process.exit(1);
  }
  if (parsed.missing) stubRefuse(`${parsed.missing} needs a value`);
  const { opts, positional } = parsed;
  if (opts["--output-format"] === "stream-json" && !opts["--verbose"]) {
    errSync("Error: When using --print, --output-format=stream-json requires --verbose\n");
    process.exit(1);
  }
  if (!opts["-p"] && !opts["--print"]) stubRefuse("a run without -p (the interactive TUI is not reproduced)");
  if (opts["--output-format"] !== "json") stubRefuse(`the claude-json dialect needs --output-format json, got ${JSON.stringify(opts["--output-format"])}`);
  if (positional.length > 0) stubRefuse(`a positional prompt ${JSON.stringify(positional)}: the prompt must come on stdin`);
  const sid = opts["--session-id"];
  if (sid !== undefined && !UUID_RE.test(sid)) stubRefuse(`--session-id ${JSON.stringify(sid)} is not a UUID`);
  if (sid !== undefined && (opts["--resume"] || opts["-r"]) && !opts["--fork-session"]) stubRefuse("--session-id together with --resume");
  if (opts["--effort"] !== undefined && !EFFORTS.has(opts["--effort"])) stubRefuse(`unknown --effort ${opts["--effort"]}`);
  if (opts["--permission-mode"] !== undefined && !PERMISSION_MODES.has(opts["--permission-mode"])) stubRefuse(`unknown --permission-mode ${opts["--permission-mode"]}`);
  if (opts["--setting-sources"] !== undefined) {
    const bad = opts["--setting-sources"].split(",").filter((s) => s && !SOURCES.has(s));
    if (bad.length > 0) stubRefuse(`unknown --setting-sources ${bad.join(",")}`);
  }
  if (opts["--settings"] !== undefined && !isObject(readJson(opts["--settings"]))) stubRefuse(`--settings ${opts["--settings"]} is not a readable JSON object file`);
  for (const name of ["--append-system-prompt-file", "--system-prompt-file"]) {
    if (opts[name] !== undefined && !fs.existsSync(opts[name])) stubRefuse(`${name} ${opts[name]} does not exist`);
  }
  if (opts["--max-turns"] !== undefined && !/^[1-9]\d*$/.test(opts["--max-turns"])) stubRefuse(`--max-turns ${opts["--max-turns"]} is not a positive integer`);
}

// ---- what claude would use for this run ----

const configDirOf = (env) => env.CLAUDE_CONFIG_DIR || path.join(env.HOME || "/nonexistent", ".claude");

function credentialOf(env, { helper, dir }) {
  // Both variables set: both headers go out, AUTH_TOKEN still decides the method [01 §6, E3, gotcha 2].
  if (env.ANTHROPIC_AUTH_TOKEN && env.ANTHROPIC_API_KEY) return { method: "oauth_token", source: "ANTHROPIC_AUTH_TOKEN", headers: ["authorization", "x-api-key"] };
  if (env.ANTHROPIC_AUTH_TOKEN) return { method: "oauth_token", source: "ANTHROPIC_AUTH_TOKEN", headers: ["authorization"] };
  if (env.ANTHROPIC_API_KEY) return { method: "api_key", source: "ANTHROPIC_API_KEY", headers: ["x-api-key"] };
  if (helper) return { method: "api_key_helper", source: "apiKeyHelper", headers: ["authorization", "x-api-key"] };
  if (fs.existsSync(path.join(dir, LOGIN_MARKER))) return { method: "claude.ai", source: "none", headers: ["authorization"] };
  return null;
}

// ---- permissions: which Bash command would run ----
// Rules of every loaded source add up; deny wins over allow, whatever the source (Claude Code's permission docs; not
// an experiment in [01]). A call no rule matches runs when an enabled sandbox auto-allows Bash (autoAllowBashIfSandboxed
// defaults to true, Claude Code's sandbox docs; assumed to hold under dontAsk too, unverified) or under
// bypassPermissions; otherwise it is denied: dontAsk, and in -p default / acceptEdits, where no one answers the prompt
// [01 E14]. The matcher is a simplification: `Bash` / `Bash(*)` match everything, `Bash(<prefix>:*)` the prefix as a
// word, `*` elsewhere any text (`Bash(git diff *)` also the bare `git diff`), anything else the exact command.
const listOf = (settings, kind) => (isObject(settings.permissions) && Array.isArray(settings.permissions[kind]) ? settings.permissions[kind].filter((rule) => typeof rule === "string") : []);
const escapeRe = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

function bashMatches(rule, command) {
  const match = /^Bash(?:\((.*)\))?$/s.exec(rule.trim());
  if (!match) return false;
  const body = match[1];
  if (body === undefined || body === "*") return true;
  if (body.endsWith(":*")) return command === body.slice(0, -2) || command.startsWith(`${body.slice(0, -2)} `);
  if (body.includes("*")) return new RegExp(`^${body.split("*").map(escapeRe).join(".*")}$`, "s").test(command) || (body.endsWith(" *") && command === body.slice(0, -2));
  return command === body;
}

function bashVerdict(ctx, command) {
  const tools = ctx.opts["--tools"];
  if (tools !== undefined && !tools.split(",").map((tool) => tool.trim()).includes("Bash")) return "no-tool";
  if (ctx.permissions.deny.some((rule) => bashMatches(rule, command))) return "deny";
  if (ctx.permissions.allow.some((rule) => bashMatches(rule, command))) return "allow";
  if (ctx.sandbox.enabled === true && ctx.sandbox.autoAllowBashIfSandboxed !== false) return "allow";
  return ctx.opts["--permission-mode"] === "bypassPermissions" ? "allow" : "deny";
}

function runContext(argv, env) {
  const { opts = {} } = parseArgs(argv);
  const dir = configDirOf(env);
  const sources = opts["--setting-sources"] !== undefined ? opts["--setting-sources"].split(",").filter(Boolean) : ["user", "project", "local"];
  const user = sources.includes("user") ? (readJson(path.join(dir, "settings.json")) ?? {}) : {};
  const project = sources.includes("project") ? (readJson(path.join(process.cwd(), ".claude", "settings.json")) ?? {}) : {};
  const flag = opts["--settings"] ? (readJson(opts["--settings"]) ?? {}) : {};
  const loaded = [user, project, flag];
  const permissions = {
    allow: [...loaded.flatMap((settings) => listOf(settings, "allow")), ...(opts["--allowedTools"] ?? []), ...(opts["--allowed-tools"] ?? [])],
    deny: [...loaded.flatMap((settings) => listOf(settings, "deny")), ...(opts["--disallowedTools"] ?? []), ...(opts["--disallowed-tools"] ?? [])],
  };
  const sandbox = Object.assign({}, ...loaded.map((settings) => (isObject(settings.sandbox) ? settings.sandbox : {})));
  const eff = { ...env, ...(isObject(user.env) ? user.env : {}), ...(isObject(project.env) ? project.env : {}), ...(isObject(flag.env) ? flag.env : {}) };
  const helper = flag.apiKeyHelper ?? project.apiKeyHelper ?? user.apiKeyHelper ?? null;
  const asked = opts["--model"] ?? eff.ANTHROPIC_MODEL ?? "opus";
  const alias = ALIASES.includes(asked.toLowerCase()) ? asked.toLowerCase() : null;
  const model = alias ? eff[`ANTHROPIC_DEFAULT_${alias.toUpperCase()}_MODEL`] || `claude-${alias}-stub` : asked;
  const haiku = eff.ANTHROPIC_DEFAULT_HAIKU_MODEL || "claude-haiku-stub";
  const resumeId = opts["--resume"] ?? opts["-r"] ?? null;
  const sid = resumeId ?? opts["--session-id"] ?? null;
  return {
    opts,
    dir,
    sources,
    flag,
    eff,
    permissions,
    sandbox,
    model,
    haiku,
    effort: eff.CLAUDE_CODE_EFFORT_LEVEL || opts["--effort"] || "high",
    baseUrl: eff.ANTHROPIC_BASE_URL || "https://api.anthropic.com",
    credential: credentialOf(eff, { helper, dir }),
    resumeId,
    ephemeral: opts["--no-session-persistence"] === true,
    sessionFile: sid ? path.join(dir, "projects", process.cwd().replace(/[^A-Za-z0-9]/g, "-"), `${sid}.jsonl`) : null,
  };
}

const host = (url) => {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
};

const zeroUsage = () => ({
  input_tokens: 0,
  cache_creation_input_tokens: 0,
  cache_read_input_tokens: 0,
  output_tokens: 0,
  output_tokens_details: { thinking_tokens: 0 },
  server_tool_use: { web_search_requests: 0, web_fetch_requests: 0 },
});

function modelUsageOf(ctx) {
  const entry = (input, output, cost) => ({
    inputTokens: input,
    outputTokens: output,
    cacheReadInputTokens: 0,
    cacheCreationInputTokens: 0,
    webSearchRequests: 0,
    costUSD: cost,
    contextWindow: 200000,
    maxOutputTokens: 32000,
    ...(ctx.model.startsWith("claude-") ? {} : { costBasis: "unknown" }),
  });
  const usage = { [ctx.model]: entry(42, 7, 0.000308) };
  if (process.env.AGENT_STUB_BG_TOKENS === "1" && ctx.haiku !== ctx.model) usage[ctx.haiku] = entry(5, 1, 0.00001);
  return usage;
}

// One `--output-format json` object [01 §3]. terminal_reason on success is not recorded in [01]; the adapter does not
// read it there.
function resultLine(ctx, sessionId, fields) {
  return `${JSON.stringify({
    type: "result",
    subtype: "success",
    is_error: false,
    duration_ms: 812,
    duration_api_ms: 640,
    num_turns: 1,
    result: "",
    stop_reason: "end_turn",
    session_id: sessionId,
    total_cost_usd: 0.000308,
    usage: { ...zeroUsage(), input_tokens: 42, output_tokens: 7 },
    modelUsage: modelUsageOf(ctx),
    permission_denials: [],
    terminal_reason: "completed",
    api_error_status: null,
    uuid: crypto.randomUUID(),
    ...fields,
  })}\n`;
}

const DEFAULT_MESSAGES = {
  401: "Invalid bearer token",
  402: "Insufficient balance",
  403: "Forbidden",
  404: "model not found",
  429: "Rate limit exceeded",
  529: "Overloaded",
};

// claude's result text for an API error [01 §11].
function apiErrorText(status, message, ctx) {
  if (status === 401) return /invalid x-api-key/i.test(message) ? "Not logged in · Please run /login" : `Failed to authenticate. API Error: 401 ${message}`;
  if (status === 403) return `Failed to authenticate. API Error: 403 ${message}`;
  if (status === 404) return `There's an issue with the selected model (${ctx.model}). It may not exist or you may not have access to it. Run --model to pick a different model.`;
  if (status === 429) return `API Error: Request rejected (429) · ${message}`;
  if (status === 529) return `API Error: 529 ${message}. This is a server-side issue, usually temporary. If it persists, check your inference gateway (${host(ctx.baseUrl)}).`;
  if (status >= 500) return `API Error: ${status} ${message}. This is a server-side issue, usually temporary.`;
  return `API Error: ${status} ${message}`; // 402 and the rest: the text is not recorded in [01]
}

function apiError(ctx, sessionId, kind, message) {
  const error = { is_error: true, subtype: "success", terminal_reason: "api_error", stop_reason: null, total_cost_usd: 0, usage: zeroUsage(), modelUsage: {} };
  if (kind === "toolong") {
    return resultLine(ctx, sessionId, { ...error, terminal_reason: "prompt_too_long", api_error_status: 400, result: "Prompt is too long · the request is ~250000 tokens (limit 200000); shorten it or start a new session" });
  }
  if (kind === "refused") {
    return resultLine(ctx, sessionId, { ...error, api_error_status: null, result: "API Error: Connection refused — a firewall or proxy may be blocking it (ECONNREFUSED)" });
  }
  if (kind === "nologin") return resultLine(ctx, sessionId, { ...error, api_error_status: null, result: "Not logged in · Please run /login" });
  const status = Number(kind);
  return resultLine(ctx, sessionId, { ...error, api_error_status: status, result: apiErrorText(status, message || DEFAULT_MESSAGES[status] || "Internal server error", ctx) });
}

// The common start of a run: observation, the resume lookup, the model notice, the credential, the session file.
// Returns the context, or null when the run already ended (exit code set).
function begin(io) {
  const ctx = runContext(io.argv, io.env);
  if (io.env.AGENT_STUB_RECORD) {
    let prior = 0;
    try {
      prior = ctx.sessionFile ? fs.readFileSync(ctx.sessionFile, "utf8").split("\n").filter(Boolean).length : 0;
    } catch {
      prior = 0;
    }
    const systemFile = ctx.opts["--append-system-prompt-file"];
    let commands = [];
    try {
      commands = io.env.AGENT_STUB_BASH_PROBE ? JSON.parse(io.env.AGENT_STUB_BASH_PROBE) : [];
    } catch {
      stubRefuse("AGENT_STUB_BASH_PROBE is not a JSON array of commands");
    }
    fs.writeFileSync(
      `${io.env.AGENT_STUB_RECORD}.claude.json`,
      JSON.stringify({
        settings: ctx.flag,
        system: systemFile ? fs.readFileSync(systemFile, "utf8") : null,
        settingSources: ctx.sources,
        model: ctx.model,
        effort: ctx.effort,
        baseUrl: ctx.baseUrl,
        headers: ctx.credential?.headers ?? [],
        credential: ctx.credential?.method ?? null,
        configDir: ctx.dir,
        sessionFile: ctx.sessionFile,
        resumed: Boolean(ctx.resumeId),
        priorRuns: prior,
        permissions: ctx.permissions,
        bash: Object.fromEntries(commands.map((command) => [command, bashVerdict(ctx, command)])),
      }),
    );
  }
  if (ctx.resumeId && !(ctx.sessionFile && fs.existsSync(ctx.sessionFile))) {
    process.stderr.write(`No conversation found with session ID: ${ctx.resumeId}\n`);
    process.exitCode = 1;
    return null;
  }
  if (!ctx.model.startsWith("claude-")) process.stderr.write(`[claude-code:unrecognized_model] ${JSON.stringify({ model: ctx.model, query_source: "sdk" })}\n`);
  if (!ctx.credential) {
    io.write(apiError(ctx, io.sessionId, "nologin"));
    process.exitCode = 1;
    return null;
  }
  if (!ctx.ephemeral && ctx.sessionFile) {
    fs.mkdirSync(path.dirname(ctx.sessionFile), { recursive: true });
    fs.appendFileSync(ctx.sessionFile, `${JSON.stringify({ type: "user", sessionId: io.sessionId, at: Date.now() })}\n`);
  }
  return ctx;
}

const DENIALS = [
  { tool_name: "Bash", tool_use_id: "toolu_stub_01", tool_input: { command: "npm test" } },
  { tool_name: "Write", tool_use_id: "toolu_stub_02", tool_input: { file_path: "notes.md", content: "x" } },
];

const answerText = (io) => io.env.AGENT_STUB_RESPONSE || "DONE\nstub finished";
const okMode = (io) => {
  const ctx = begin(io);
  if (ctx) io.write(resultLine(ctx, io.sessionId, { result: answerText(io) }));
};

// `claude auth status --json` [01 §6, E20].
function authStatus(argv, env) {
  if (argv[1] !== "status" || !argv.includes("--json")) stubRefuse(`claude ${argv.join(" ")} is not reproduced (only auth status --json)`);
  const dir = configDirOf(env);
  // No --setting-sources: the default sources, so the user settings and the cwd's .claude/settings.json, env and
  // apiKeyHelper, as a run would load them [01 §9, E9, E18] (assumed for auth status; E20 recorded env and a helper).
  const user = readJson(path.join(dir, "settings.json")) ?? {};
  const project = readJson(path.join(process.cwd(), ".claude", "settings.json")) ?? {};
  const eff = { ...env, ...(isObject(user.env) ? user.env : {}), ...(isObject(project.env) ? project.env : {}) };
  const credential = credentialOf(eff, { helper: project.apiKeyHelper ?? user.apiKeyHelper ?? null, dir });
  const status = credential ? { loggedIn: true, authMethod: credential.method, apiKeySource: credential.source } : { loggedIn: false, authMethod: "none", apiKeySource: "none" };
  const keys = Object.fromEntries(KEY_VARS.map((name) => [name, env[name] === undefined ? null : sha(env[name])]));
  appendTo(env.AGENT_STUB_AUTH_LOG, JSON.stringify({ argv, wrapped: env.WRAPPED || null, cwd: process.cwd(), configDirectory: dir, authMethod: status.authMethod, keys }));
  outSync(`${JSON.stringify({ ...status, configDirectory: dir, analyticsDisabled: true })}\n`);
  if (!status.loggedIn) process.exit(1);
  return true;
}

module.exports = {
  name: "claude-json",
  version: VERSION,
  flags: HELP.map(([flag]) => flag),
  help(flags) {
    const keep = new Set(flags);
    const lines = HELP.filter(([flag]) => keep.has(flag)).map(([flag, meta, text]) => {
      const head = `${flag === "--print" ? "-p, " : flag === "--resume" ? "-r, " : flag === "--continue" ? "-c, " : ""}${flag}${meta ? ` ${meta}` : ""}`;
      return `  ${head.padEnd(44)} ${text}`;
    });
    return `Usage: claude [options] [command] [prompt]\n\nClaude Code (agent-stub claude-json dialect)\n\nOptions:\n${lines.join("\n")}\n  -v, --version${" ".repeat(32)}Output the version number\n  -h, --help${" ".repeat(35)}Display help for command\n\nCommands:\n  auth                                         Manage authentication\n`;
  },
  // Every invocation reaches this first: --version and `auth status` are answered here; a run is checked (argv, the
  // adapter's contract) and goes on to the stub.
  answer(argv, { env }) {
    if (argv.includes("--print-env") || argv.includes("--help")) return false;
    if (argv.includes("--version")) {
      appendTo(env.AGENT_STUB_CALL_LOG, `version ${env.WRAPPED || "-"}`);
      outSync(`${env.AGENT_STUB_VERSION || VERSION} (Claude Code)\n`);
      return true;
    }
    if (argv[0] === "auth") return authStatus(argv, env);
    checkRun(argv);
    return false;
  },
  sessionId(flag) {
    return flag("--resume") || flag("-r") || flag("--session-id") || crypto.randomUUID();
  },
  final({ sessionId, text }) {
    return resultLine(runContext(process.argv.slice(2), process.env), sessionId, { result: text });
  },
  error({ sessionId, message, errorClass }) {
    const kind = { auth: "401", quota: "402", "model-not-selected": "404", "rate-limit": "429", server: "500", context: "toolong" }[errorClass] ?? "500";
    return apiError(runContext(process.argv.slice(2), process.env), sessionId, kind, message);
  },
  modes: {
    ok: okMode,
    slow: okMode,
    "api-error": (io) => {
      const ctx = begin(io);
      if (!ctx) return;
      io.write(apiError(ctx, io.sessionId, io.env.AGENT_STUB_STATUS || "500", io.env.AGENT_STUB_MESSAGE));
      process.exitCode = Number(io.env.AGENT_STUB_EXIT || 1);
    },
    "max-turns": (io) => {
      const ctx = begin(io);
      if (!ctx) return;
      // is_error and terminal_reason of a max-turns stop are not recorded in [01]; subtype and result null are [E14].
      io.write(resultLine(ctx, io.sessionId, { subtype: "error_max_turns", is_error: true, result: null, num_turns: 3, stop_reason: "tool_use", terminal_reason: "max_turns" }));
      process.exitCode = 1;
    },
    denied: (io) => {
      const ctx = begin(io);
      if (ctx) io.write(resultLine(ctx, io.sessionId, { result: io.env.AGENT_STUB_RESPONSE || "DONE\nreviewed with what was allowed", permission_denials: DENIALS, num_turns: 3 }));
    },
    "denied-empty": (io) => {
      const ctx = begin(io);
      if (ctx) io.write(resultLine(ctx, io.sessionId, { result: "", permission_denials: DENIALS, num_turns: 3 }));
    },
    empty: (io) => {
      const ctx = begin(io);
      if (ctx) io.write(resultLine(ctx, io.sessionId, { result: "" }));
    },
    wait: (io) => {
      if (begin(io)) io.forever();
    },
    "term-ignore": (io) => {
      if (begin(io)) io.forever();
    },
  },
};
