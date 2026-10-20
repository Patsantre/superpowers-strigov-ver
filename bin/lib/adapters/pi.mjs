// adapters/pi.mjs — the core adapter of the `pi` harness (Mario Zechner's minimal coding agent,
// @earendil-works/pi-coding-agent 1.3.x) on agent-dispatch's job core (agent-core.mjs, spec §3.2): headless runs as
// `pi --mode json`, one detached process per turn, the job's id as pi's session id
// (docs/superpowers/specs/2026-10-20-universal-dispatchers-design.md §2, §3.4–§3.8; the facts:
// docs/research/universal-dispatchers/03-pi.md, cited below as [03 §n]).
//
// The command (spec §2):
//   pi --mode json [--model <provider/id>] [--thinking <effort>] --session-dir <D> --session-id <job id>
//      --no-approve -ne -ns -np --no-mcp --tools <role set> [-e <extension>]… < prompt
// - `--mode json` always: without a TTY pi otherwise falls into print mode, which has no session id, no usage and
//   prints nothing when a run ends on a tool result [03 §2.1, §3.2, §15 item 2].
// - The session id is preassigned (the job id, manifest.sessionIdFormat "job-id") and the session files live flat in
//   <job dir of the first job of the chain>/sessions; a resume passes the same dir and id from the same cwd
//   [03 §4]. pi never reports a lost session: it warns "No project session found with id …" and starts a new one,
//   so resumeCheck looks for the session file before a resume and finalize() turns that warning into resume-lost.
// - Read-only reviewer = `--tools read,grep,find,ls` (no bash, so no git; spec §3.6 A4) with `--no-mcp` (MCP tools
//   survive `--tools` otherwise [03 §15 item 18]); the writer gets pi's defaults plus grep/find/ls [03 §16.2].
// - `--no-approve` keeps the repository's `.pi/*` (settings, models, extensions, MCP) out (spec §3.6 A5);
//   `-ne -ns -np --no-mcp` and PI_TELEMETRY=0 / PI_SKIP_VERSION_CHECK=1 / PI_OFFLINE=1 are the defaults of §3.6 Б
//   (the env ones overridable through profile.env). Context files (AGENTS.md / CLAUDE.md) stay on: `-nc` is not
//   passed (spec §3.6 A6). options.extensions adds one `-e <x>` each; they load even under `-ne` [03 §9].
// - The key goes only into the variable named by `keyVar` (spec §3.5). With a key from agent-dispatch the home is
//   isolated by default (PI_CODING_AGENT_DIR = <data>/homes/<profile>/pi, the same dir `profile env` prints): pi
//   prefers a credential stored in its own auth.json over the environment, so a key saved in the user's pi would
//   silently win over ours [03 §6]. With "home": "user" the caller's PI_CODING_AGENT_DIR passes (manifest.homeEnv).
// - pi exits 0 when the provider fails: reduce() reads the events — the last assistant `message_end` (its text,
//   stopReason, errorMessage) and `agent_settled` (the terminal marker, `aborted`) [03 §3.1, §3.3].
// - Cancel: SIGTERM, which pi answers by SIGKILLing the process groups of its bash tools and exiting 143; never
//   SIGINT, which pi does not handle, so those groups would be orphaned [03 §3.3, §10]. 5 s later, SIGKILL.
// - pi has no permission system and no sandbox: nothing is ever auto-rejected (no `blocked` signature), and
//   "sandbox": "native" changes nothing (doctor says so and points at `wrap`, spec §3.7).
// Never run: `pi auth print-api-key` / `print-bearer-token` (they print secrets) and `--api-key` (visible in ps)
// [03 §5.1, §6].
//
// Pure data, as the contract asks: processes and files only through ctx.exec / ctx.fs.

import path from "node:path";
import { filterEnv, parseEvents } from "../agent-core.mjs";

// The version the facts were read from (pi itself was not run, [03] header); doctor names any other one.
export const VERIFIED_VERSIONS = ["1.3.0"];
export const INSTALL_HINT = "npm i -g --ignore-scripts @earendil-works/pi-coding-agent@1.3.0 (Node >= 22.19)";
export const WRITER_TOOLS = "read,bash,edit,write,grep,find,ls";
export const REVIEWER_TOOLS = "read,grep,find,ls";
// spec §3.6 Б: overridable through profile.env (e.g. PI_OFFLINE=0 lets grep/find download fd and rg).
export const DEFAULT_ENV = { PI_TELEMETRY: "0", PI_SKIP_VERSION_CHECK: "1", PI_OFFLINE: "1" };
export const HOME_VAR = "PI_CODING_AGENT_DIR";
// pi's warning when --session-id names no session of this cwd in the session dir [03 §4, src/main.ts:436-448]. It is
// printed on every fresh job as well (its id is new), so only a resumed job reads it as a lost session.
export const LOST_SESSION_RE = /No project session found with id/;

const isObject = (value) => Boolean(value) && typeof value === "object" && !Array.isArray(value);
const keyed = (profile) => isObject(profile?.auth) && ["key", "keyEnv", "keyCmd"].some((source) => source in profile.auth);
const isolated = (profile) => profile?.home === "isolated";
const binOf = (req) => req.harness?.bin ?? req.profile?.bin ?? "pi";
const extensionsOf = (profile) => (Array.isArray(profile?.options?.extensions) ? profile.options.extensions : []);
const extensionArgs = (profile) => extensionsOf(profile).flatMap((extension) => ["-e", extension]);
const modelArgs = (profile) => [...(profile?.model ? ["--model", profile.model] : []), ...(profile?.effort ? ["--thinking", profile.effort] : [])];
// `--model <provider/id>`: the provider is what `pi auth check --provider` asks about; a bare pattern names none.
export const providerOf = (model) => (typeof model === "string" && model.indexOf("/") > 0 ? model.slice(0, model.indexOf("/")) : null);

// The agent dir pi runs with: the profile's own under the data root ("isolated"); with "home": "user" the one
// profile.env sets (null removes it), which wins over the caller's PI_CODING_AGENT_DIR as in the job env (buildEnv);
// null for pi's default ~/.pi/agent.
export function agentDirOf(profile, ctx) {
  if (isolated(profile)) return path.join(ctx.paths.homes, ctx.profileName, "pi");
  if (isObject(profile?.env) && Object.hasOwn(profile.env, HOME_VAR)) {
    const value = profile.env[HOME_VAR];
    return value === null || value === undefined ? null : String(value) || null;
  }
  return ctx.env?.[HOME_VAR] || null;
}

function secretEnvOf(profile) {
  if (!keyed(profile)) return []; // "login": pi's own auth.json / models.json / provider env of its home
  if (typeof profile.keyVar !== "string" || !profile.keyVar) {
    throw new Error("a pi profile with a key needs keyVar, the variable pi reads the key from (zai → ZAI_API_KEY, deepseek → DEEPSEEK_API_KEY, openrouter → OPENROUTER_API_KEY)");
  }
  return [profile.keyVar];
}

// Where the session of a job lives: a fresh job starts <its job dir>/sessions; a resumed one returns to the dir its
// chain started in, recorded in the previous job's meta.
function sessionDirOf(req) {
  if (!req.resume) return path.join(req.job.dir, "sessions");
  const prev = req.resume.prev;
  if (typeof prev?.meta?.sessionDir === "string" && prev.meta.sessionDir) return prev.meta.sessionDir;
  return prev?.id ? path.join(path.dirname(req.job.dir), prev.id, "sessions") : path.join(req.job.dir, "sessions");
}

// ---------- reduce: the outcome from the JSON event stream [03 §3.1] ----------

// The final text: the text blocks of an assistant message, thinking and tool calls skipped, one per line as print
// mode writes them.
export function textOf(message) {
  if (typeof message?.content === "string") return message.content;
  if (!Array.isArray(message?.content)) return "";
  return message.content.filter((block) => block?.type === "text" && typeof block.text === "string").map((block) => block.text).join("\n");
}

const USAGE_FIELDS = ["input", "output", "cacheRead", "cacheWrite", "totalTokens"];

// Tokens and USD cost summed over every assistant message_end (each carries its own usage; message_update holds only
// a running count of the same response) and every compaction [03 §13]. Null when no usage was seen.
function sumUsage(usages) {
  const seen = usages.filter(isObject);
  if (seen.length === 0) return null;
  const total = Object.fromEntries(USAGE_FIELDS.map((field) => [field, 0]));
  let costUsd = 0;
  for (const usage of seen) {
    for (const field of USAGE_FIELDS) if (Number.isFinite(usage[field])) total[field] += usage[field];
    if (Number.isFinite(usage.cost?.total)) costUsd += usage.cost.total;
  }
  return { ...total, costUsd: Math.round(costUsd * 1e6) / 1e6 };
}

export function reduce(io) {
  const events = Array.isArray(io?.events) ? io.events : parseEvents(io?.stdout);
  let header = null;
  let last = null; // the last assistant message (message_end is authoritative)
  let settled = null; // agent_settled: pi does no more automatic work
  let retryError = null;
  const usages = [];
  for (const event of events) {
    if (!isObject(event)) continue;
    if (event.type === "session" && !header && typeof event.id === "string") header = event; // line 1
    else if (event.type === "message_end" && event.message?.role === "assistant") {
      last = event.message;
      usages.push(event.message.usage);
    } else if (event.type === "agent_settled") settled = event;
    else if (event.type === "auto_retry_end" && event.success === false) retryError = event.finalError ?? event.errorMessage ?? null;
    else if (event.type === "compaction_end") usages.push(event.result?.usage);
  }
  const stopReason = typeof last?.stopReason === "string" ? last.stopReason : null;
  const response = last ? textOf(last) : "";
  const base = {
    sessionId: typeof header?.id === "string" ? header.id : null,
    usage: sumUsage(usages),
    reportedModel: typeof last?.model === "string" ? (typeof last.provider === "string" ? `${last.provider}/${last.model}` : last.model) : null,
    meta: stopReason ? { stopReason } : null,
  };
  const failed = (errorClass, errorText) => ({ ok: false, response: null, ...base, errorClass, errorText });
  const aborted = settled?.aborted === true || stopReason === "aborted";
  if (settled && !aborted && stopReason === "stop" && response.trim() !== "") return { ok: true, response, ...base, errorClass: null, errorText: null };
  // Unclassified failures leave errorClass null: the core matches `patterns` against errorText and the stderr tail,
  // and falls back to malformed (exit 0) or crash (a non-zero exit or a signal).
  if (stopReason === "error") return failed(null, last.errorMessage ?? retryError ?? "pi reported an assistant error without a message");
  if (stopReason === "length") return failed("malformed", "Response was truncated: the model reached its output token limit.");
  if (aborted) return failed(null, "pi aborted the run");
  if (!last) return failed(null, retryError ?? (header ? "pi ended before any assistant message" : null));
  if (!settled) return failed(null, "pi ended without agent_settled");
  return failed(null, `pi settled without a final answer (stopReason ${stopReason ?? "-"})`);
}

// ---------- resume [03 §4; spec §3.6 A12] ----------

// The header of the session file with this id for this cwd in `dir` — what pi itself must find for --session-id to
// resume rather than start over. Files whose name carries the id are read first (pi names them <time>_<id>.jsonl).
export function findSessionHeader(fsApi, dir, sessionId, cwd) {
  const names = (fsApi.readdir(dir) ?? []).filter((name) => name.endsWith(".jsonl"));
  const ordered = [...names.filter((name) => name.includes(sessionId)), ...names.filter((name) => !name.includes(sessionId))];
  for (const name of ordered) {
    const text = fsApi.readFile(path.join(dir, name));
    if (typeof text !== "string") continue;
    let header = null;
    try {
      header = JSON.parse(text.slice(0, text.indexOf("\n") >= 0 ? text.indexOf("\n") : text.length));
    } catch {
      continue;
    }
    if (header?.type === "session" && header.id === sessionId && header.cwd === cwd) return header;
  }
  return null;
}

// ---------- doctor (spec §5.4: no model call) ----------

function onPath(fsApi, searchPath, command) {
  return String(searchPath ?? "")
    .split(path.delimiter)
    .filter(Boolean)
    .some((dir) => {
      const stat = fsApi.stat(path.join(dir, command));
      return Boolean(stat?.isFile?.() && stat.mode & 0o111);
    });
}

// The environment of a doctor-time pi command: the core's allowlist, the adapter defaults, profile.env and the home —
// never the key, so a credential pi reports is one pi holds itself.
function doctorEnv(profile, ctx) {
  const env = { ...filterEnv(ctx.env, { inherit: isolated(profile) ? [] : [HOME_VAR] }), ...DEFAULT_ENV };
  for (const [name, value] of Object.entries(isObject(profile.env) ? profile.env : {})) {
    if (value === null || value === undefined) delete env[name];
    else env[name] = String(value);
  }
  if (isolated(profile)) env[HOME_VAR] = agentDirOf(profile, ctx);
  return env;
}

const firstLine = (text) => String(text ?? "").trim().split("\n")[0].slice(0, 160);

// `pi auth check --provider <p> --json` (spec §5.4): exit 0 ready · 1 not_ready · 2 invalid, without a network call
// for API keys [03 §3.3, §16.2]. The JSON shape beyond `authType` / `status` is not documented, so the exit code
// decides. A login profile needs "ready"; a keyed one needs pi to hold nothing for the provider, because pi prefers its
// own credential to the key in the environment [03 §6].
function authCheck(profile, ctx) {
  const name = ctx.profileName ?? "<profile>";
  const provider = providerOf(profile.model);
  const login = !keyed(profile);
  if (!provider) {
    return { name: "pi-auth", level: login ? "WARN" : "ok", hint: `model ${JSON.stringify(profile.model ?? null)} names no <provider>/ prefix; pi auth check not run` };
  }
  const agentDir = agentDirOf(profile, ctx);
  const where = agentDir ?? "~/.pi/agent";
  const loginHint = `the user logs in: ${isolated(profile) ? `eval "$(agent-dispatch profile env ${name})"; ` : ""}pi, then /login ${provider}`;
  if (isolated(profile) && !ctx.fs.exists(agentDir)) {
    return login
      ? { name: "pi-auth", level: "FAIL", hint: `the isolated home ${agentDir} does not exist yet, so pi holds no login for ${provider}; ${loginHint}` }
      : { name: "pi-auth", level: "ok", hint: `the isolated home ${agentDir} is created on the first task; nothing there overrides the key in ${profile.keyVar}` };
  }
  let r;
  try {
    const cmd = [...(Array.isArray(profile.wrap) ? profile.wrap : []), profile.bin ?? "pi"];
    r = ctx.exec(cmd[0], [...cmd.slice(1), "auth", "check", "--provider", provider, "--json"], { env: doctorEnv(profile, ctx) });
  } catch (error) {
    return { name: "pi-auth", level: "WARN", hint: `pi auth check not run: ${error?.message ?? error}` };
  }
  if (r.error) return { name: "pi-auth", level: "WARN", hint: `cannot run pi auth check: ${r.error.code ?? r.error.message}` };
  let report = null;
  try {
    report = JSON.parse(r.stdout);
  } catch {
    report = null;
  }
  const authType = typeof report?.authType === "string" ? ` (${report.authType})` : "";
  if (login) {
    if (r.status === 0) return { name: "pi-auth", level: "ok", hint: `pi auth check --provider ${provider}: ready${authType} in ${where}` };
    if (r.status === 1) return { name: "pi-auth", level: "FAIL", hint: `pi holds no credential for ${provider} in ${where}; ${loginHint}` };
    if (r.status === 2) return { name: "pi-auth", level: "FAIL", hint: `the credential pi holds for ${provider} in ${where} is invalid${authType}; ${loginHint}` };
  } else {
    const fix = isolated(profile) ? `remove it from ${where} (pi /logout ${provider})` : `use "home": "isolated" or remove it (pi /logout ${provider})`;
    if (r.status === 0) {
      return { name: "pi-auth", level: "WARN", hint: `pi already holds a credential for ${provider} in ${where}${authType}; pi prefers it to the key in ${profile.keyVar}, so the key from agent-dispatch is not used — ${fix}` };
    }
    if (r.status === 1) return { name: "pi-auth", level: "ok", hint: `pi holds no credential of its own for ${provider} in ${where}; the key goes in through ${profile.keyVar}` };
    if (r.status === 2) {
      return { name: "pi-auth", level: "FAIL", hint: `pi holds an invalid credential for ${provider} in ${where}${authType}; it owns the provider, so the key in ${profile.keyVar} is not used — ${fix}` };
    }
  }
  return { name: "pi-auth", level: "WARN", hint: `pi auth check exited ${r.status ?? r.signal}${r.stderr?.trim() ? `: ${firstLine(r.stderr)}` : ""}` };
}

export function doctorChecks(profile, ctx) {
  const checks = [];
  // grep / find run fd / rg; under PI_OFFLINE=1 pi does not download them, and the tools fail [03 §9].
  const searchPath = isObject(profile.env) && typeof profile.env.PATH === "string" ? profile.env.PATH : ctx.env?.PATH;
  const missing = ["fd", "rg"].filter((command) => !onPath(ctx.fs, searchPath, command));
  checks.push(
    missing.length === 0
      ? { name: "pi-tools", level: "ok", hint: "fd and rg are on PATH (pi's find and grep tools)" }
      : {
          name: "pi-tools",
          level: "WARN",
          hint: `${missing.join(" and ")} not on PATH: pi's ${missing.map((command) => (command === "fd" ? "find" : "grep")).join(" and ")} tool fails under PI_OFFLINE=1 (the reviewer's only search tools); install them (brew install fd ripgrep; on Debian/Ubuntu fd-find installs fdfind — link it as fd)`,
        },
  );
  const extensions = extensionsOf(profile);
  const absent = extensions.filter((extension) => path.isAbsolute(extension) && !ctx.fs.exists(extension));
  const unchecked = extensions.filter((extension) => !extension.startsWith("builtin:") && !path.isAbsolute(extension));
  for (const extension of absent) {
    checks.push({ name: "pi-extension", level: "FAIL", hint: `${extension} does not exist; pi would stop with "Failed to load extension" (errorClass launch)` });
  }
  for (const extension of unchecked) {
    checks.push({ name: "pi-extension", level: "WARN", hint: `${extension} is not checked: pi resolves it at run time, a relative path against the task's workspace root; prefer an absolute path` });
  }
  if (extensions.length > 0 && absent.length === 0 && unchecked.length === 0) {
    checks.push({ name: "pi-extension", level: "ok", hint: extensions.map((extension) => `-e ${extension}`).join(" ") });
  }
  checks.push(authCheck(profile, ctx));
  return checks;
}

// ---------- the adapter ----------

const pi = {
  id: "pi",
  idPrefix: "pi",
  manifest: {
    sessionId: "preassign",
    sessionIdFormat: "job-id", // spec §3.2: the job id is pi's --session-id (letters, digits, - : valid [03 §4])
    cancel: { ladder: [["SIGTERM", 5000], ["SIGKILL", 0]] },
    helpArgv: ["--help"],
    // Flags whose absence would silently change the run (print mode, a lost session, project resources, a writable
    // reviewer); an unknown short flag fails loudly anyway ("Unknown option", launch). pi's --help text itself was not
    // run; the flags are those of src/cli/args.ts [03 §2.3, fact-check log].
    requiredFlags: ["--mode", "--session-dir", "--session-id", "--no-approve", "--no-mcp", "--tools"],
    homeEnv: [HOME_VAR],
    verifiedVersions: VERIFIED_VERSIONS,
  },

  discover(ctx) {
    const bin = ctx.profile?.bin ?? "pi";
    const r = ctx.exec(bin, ["--version"]);
    if (r.error) {
      const why = r.error.code === "ENOENT" ? "not found" : `cannot run (${r.error.code ?? r.error.message})`;
      throw Object.assign(new Error(`pi ${why}: ${bin}; install it: ${INSTALL_HINT}`), { errorClass: "launch" });
    }
    if (r.status !== 0) {
      throw Object.assign(new Error(`${bin} --version exited ${r.status ?? r.signal}${r.stderr?.trim() ? `: ${firstLine(r.stderr)}` : ""}`), { errorClass: "launch" });
    }
    // The --version format was not seen [03 header]; the first x.y.z token is the version.
    return { bin, version: /\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?/.exec(`${r.stdout}\n${r.stderr}`)?.[0] ?? null };
  },

  // "isolated": the profile's own agent dir (settings, auth.json, models.json, sessions by default, fd/rg downloads)
  // [03 §6 "Profile isolation"]. Nothing is written into it: pi keeps its own state there (a ChatGPT login's deviceId
  // lives in settings.json [03 §15 item 17]).
  prepareHome(profile, ctx) {
    if (!isolated(profile)) return { env: {}, dirs: [], files: [] };
    const dir = agentDirOf(profile, ctx);
    return { env: { [HOME_VAR]: dir }, dirs: [dir], files: [] };
  },

  // `agent-dispatch profile env P` for "home": "isolated": where `pi` → /login must run to log this profile in.
  loginEnv(profile, ctx) {
    return { [HOME_VAR]: path.join(ctx.paths.homes, ctx.profileName, "pi") };
  },

  invocation(req, ctx) {
    const profile = req.profile ?? {};
    // A job-less request (doctor's env check) has no session to keep.
    const jobLess = !req.job?.id || !req.sessionId;
    const sessionDir = jobLess ? null : sessionDirOf(req);
    return {
      argv: [
        binOf(req),
        "--mode",
        "json",
        ...modelArgs(profile),
        ...(jobLess ? ["--no-session"] : ["--session-dir", sessionDir, "--session-id", req.sessionId]),
        "--no-approve",
        "-ne",
        "-ns",
        "-np",
        "--no-mcp",
        "--tools",
        req.write ? WRITER_TOOLS : REVIEWER_TOOLS,
        ...extensionArgs(profile),
      ],
      env: { ...DEFAULT_ENV },
      mandatoryEnv: {},
      secretEnv: secretEnvOf(profile),
      stdinPath: req.prompt?.path ?? null, // read to EOF and trimmed by pi [03 §2.2]; never argv (extra args are turns)
      cwd: req.job.cwd,
      dirs: sessionDir ? [sessionDir] : [],
      files: [],
      meta: jobLess ? null : { sessionDir, agentDir: agentDirOf(profile, ctx) },
    };
  },

  // One "Reply with exactly: PONG" turn: no session, no tools (-nt), no context files (the probe runs in a scratch dir
  // under the data root, whose ancestors may hold AGENTS.md / CLAUDE.md) [03 §16.2 doctor --probe]. The profile's own
  // --thinking stays (not §16.2's `off`): the probe checks the model and effort the jobs use.
  probe(req, ctx) {
    const profile = req.profile ?? {};
    return {
      argv: [binOf(req), "--mode", "json", ...modelArgs(profile), "--no-session", "--no-approve", "-ne", "-ns", "-np", "-nc", "--no-mcp", "-nt", ...extensionArgs(profile)],
      env: { ...DEFAULT_ENV },
      mandatoryEnv: {},
      secretEnv: secretEnvOf(profile),
      stdinPath: req.prompt?.path ?? null,
      cwd: req.job.cwd,
      dirs: [],
      files: [],
      meta: null,
    };
  },

  reduce,

  // A resumed job whose stderr carries pi's "No project session found with id …" ran in a new, empty session: the
  // answer lacks the earlier context, so the job is resume-lost (spec §3.6 A12) and the orchestrator re-briefs FRESH.
  // Only here, because the same warning opens every fresh job. (The stderr tail keeps the last 200 lines; pi prints
  // the warning at startup and is quiet on stderr in JSON mode.)
  finalize(job) {
    if (!job?.record?.resumeOf) return null;
    const line = String(job.io?.stderrTail ?? "")
      .split("\n")
      .find((text) => LOST_SESSION_RE.test(text));
    return line ? { ok: false, response: null, errorClass: "resume-lost", errorText: line.trim() } : null;
  },

  // spec §3.6 A12: the same cwd (pi's lookup in a --session-dir filters by the header cwd) and a session file whose
  // header id matches; otherwise pi would silently start fresh [03 §4, §15 items 6, 8].
  resumeCheck(prev, profile, req, ctx) {
    if (prev.cwd !== req.job.cwd) return `the pi session of ${prev.id} was started in ${prev.cwd}, not ${req.job.cwd}`;
    const dir = prev.meta?.sessionDir;
    if (typeof dir !== "string" || !dir) return `job ${prev.id} recorded no pi session dir`;
    if (!findSessionHeader(ctx.fs, dir, prev.sessionId, req.job.cwd)) {
      return `no pi session file with id ${prev.sessionId} for ${req.job.cwd} in ${dir}; pi would start a new session`;
    }
    return null;
  },

  // Matched by the core (PATTERN_ORDER) against reduce()'s errorText and the stderr tail when reduce() left the class
  // open. Sources: pi's own classifiers in @earendil-works/pi-ai (utils/retry.ts, utils/overflow.ts) and its startup
  // errors [03 §11]; the 402 / insufficient balance and 529 entries follow spec §3.8.
  patterns: {
    // Not a pattern: the warning also opens every fresh job (see finalize).
    "resume-lost": [],
    // Only the fatal `Model "x" not found. Use --list-models …`: the warning `Model "x" not found for provider "p".
    // Using custom model id.` lets pi run on [03 §5.1, §11, §15 item 9], and it stays in the stderr tail the core
    // matches, so it must not turn a later 429 / 401 / quota into model-not-selected. A wrong id then fails as a 404.
    "model-not-selected": [/Model "[^"]*" not found(?! for provider)/i, /Unknown provider/i, /is ambiguous across providers/i, /No model selected/i, /model[_ ]not[_ ]found/i, /\b404\b/],
    auth: [/No API key found for/i, /No models available/i, /refresh_token_invalidated/i, /\b401\b/, /\b403\b/, /unauthori[sz]ed/i, /forbidden/i, /invalid[_ ]?api[_ ]?key/i, /incorrect api key/i, /authentication/i],
    quota: [
      /GoUsageLimitError/,
      /FreeUsageLimitError/,
      /Monthly usage limit reached/i,
      /available balance/i,
      /insufficient[_ ]quota/i,
      /insufficient balance/i,
      /out of budget/i,
      /quota exceeded/i,
      /\bbilling\b/i,
      /subscription_sharing_usage_limit_exceeded/i,
      /\b402\b/,
      // spec §3.8: a 429 that says a limit is used up is quota, not rate-limit (as claude.mjs and zcode-dispatch read
      // it). Z.ai Coding Plan's "Usage limit reached for 5 hour" / "Weekly/Monthly Limit Exhausted" are not in [03].
      /usage limit/i,
      /limit exhausted/i,
    ],
    context: [
      /prompt is too long/i,
      /request_too_large/i,
      /exceeds the context window/i,
      /maximum context length is \d+ tokens/i,
      /context window exceeds limit/i,
      /exceeded model token limit/i,
      /range of input length should be/i,
      /exceeds the available context size/i,
      /greater than the context length/i,
      /prompt too long; exceeded .*context length/i,
      /context_length_exceeded/i,
      /too many tokens/i,
      /token limit exceeded/i,
    ],
    blocked: [], // no permission system: a refused tool is a tool error inside the run, never a stop
    "rate-limit": [/rate.?limit/i, /too many requests/i, /\b429\b/, /\b529\b/, /overloaded/i, /server_busy/i, /model is at capacity/i, /ResourceExhausted/],
    server: [
      /\b50[0-4]\b/,
      /\b52[04]\b/,
      /service (temporarily )?unavailable/i,
      /internal server error/i,
      /bad gateway/i,
      /provider returned an error/i,
      /fetch failed/i,
      /getaddrinfo/i,
      /ENOTFOUND/,
      /EAI_AGAIN/,
      /ECONNREFUSED/,
      /ECONNRESET/,
      /connection (refused|lost|error)/i,
      /socket hang up/i,
      /other side closed/i,
      /websocket closed/i,
      /timed out/i,
      /\btimeout\b/i,
      /\bterminated\b/i,
    ],
    launch: [/Failed to load extension/i, /Unknown option/i],
  },

  doctorChecks,
};

export default pi;
