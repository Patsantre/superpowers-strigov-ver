// adapters/opencode.mjs — the core adapter of the `opencode` harness: OpenCode 1.19.x (npm `opencode-ai`) run headless
// as one `opencode run --format json` per job (docs/superpowers/specs/2026-10-20-universal-dispatchers-design.md §2,
// §3.2, §3.6 А4–А6, А9, А12, Б, §3.8; the facts come from docs/research/universal-dispatchers/02-opencode.md, cited
// [02 §n]). Adapters return data; agent-core.mjs owns processes, files, signals and the key.
//
// The command (spec §2):
//   opencode run --format json --title <job id> --agent sp-implementer|sp-reviewer -m <provider/model>
//                [--variant <effort>] [-s <session id>] --dir <workspace root> < prompt
// The prompt comes on stdin from the job's prompt file, so stdin is closed after it: `run` reads stdin to EOF before
// it starts and would wait forever on an open one [02 §2, fact-check note 2]. --auto and --attach are never used
// [02 §7, §3]. The agent follows --write: sp-implementer writes, sp-reviewer only reads.
//
// Environment, on top of the core's allowlist (spec §3.2 order: defaults → profile.env → mandatory → key):
//   mandatory (§3.6 А) OPENCODE_CONFIG_CONTENT  the sp-implementer / sp-reviewer primary agents with complete explicit
//                                               permission sets (А4; options.permission merged into sp-implementer,
//                                               only its deny rules into sp-reviewer) and `instructions`: the repo's
//                                               AGENTS.md / CLAUDE.md that exist (А6) — config source 6, after the
//                                               global and project ones [02 §9]
//                      OPENCODE_PERMISSION      the role's set again (it overrides top-level `permission` of other
//                                               configs, not agent.<name>.permission, so alone it guarantees nothing)
//                      OPENCODE_DISABLE_PROJECT_CONFIG=1     a repo's opencode.json / .opencode/ cannot change the
//                                                            provider, the agents or the rules (А5)
//                      OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1 a personal ~/.claude/CLAUDE.md does not replace the
//                                                            project's rules (А6)
//                      XDG_CONFIG_HOME / XDG_DATA_HOME / XDG_STATE_HOME / XDG_CACHE_HOME = <data root>/homes/<P>/
//                                               {config,data,state,cache} with "home": "isolated" (prepareHome); with
//                                               "home": "user" the caller's XDG_* pass the allowlist unchanged. The
//                                               model's tools see that XDG_CONFIG_HOME too: prepareHome writes
//                                               config/git/config pointing git back at the caller's git config,
//                                               ignore and attributes; other XDG configs (gh's hosts.yml) stay hidden
//   defaults (§3.6 Б)  OPENCODE_DISABLE_AUTOUPDATE=1, OPENCODE_DISABLE_EXTERNAL_SKILLS=1, OPENCODE_PURE=1 (not with
//                      options.plugins: true; PURE leaves the built-in Copilot / ChatGPT logins alone [02 §6])
//   the key            in profile.keyVar for auth {key | keyEnv | keyCmd} (§3.5); never in argv or the config.
//                      OpenCode's bash tool sees it (spec §3.5: documented, `wrap` is the remedy). A login stored by
//                      `opencode auth login` for the same provider wins over the variable [02 §5], so a keyed profile
//                      runs only in its isolated home, and only while that home holds no auth.json (exit 2 otherwise).
//
// Outcome (§3.6 А9, §3.8): reduce() reads the JSONL events — the session id from any event's sessionID, the answer
// from the text parts of the last message (the last messageID of any part, not the last one with text), usage from
// step_finish — and stderr: "agent … not found" (OpenCode fell back to its default agent, which may write) is launch;
// "auto-rejecting" (a surviving `ask`) is blocked; "Session not found" is resume-lost. The answer counts only when its
// step finished (a step_finish other than tool-calls / length / error / content-filter): a narration before a tool
// call, cut off by a crash or a kill, is no answer. Then it is success whatever the exit code, if it came after the
// last error event (a context overflow can be compacted away and still exit 1 [02 fact-check note 1]). Without an
// answer in the stream, finalize() runs `opencode export <session>` in the job's environment and takes the last
// assistant message — only a finished one of this run (a resumed session also holds the earlier jobs' messages).
// quota needs insufficient_quota / usage_not_included / GoUsageLimitError / FreeUsageLimitError in the error, or a 402
// (DeepSeek's "Insufficient Balance"); any other 429 ("Quota exceeded…" after five retries included) is rate-limit.
//
// Resume (§3.6 А12): -s <session> with the same --dir and the same data dir (sessions live in SQLite under
// XDG_DATA_HOME [02 §4]); resumeCheck compares both with the original job's meta. Cancel (§3.6 А8): SIGTERM to the
// group and the descendant groups of the snapshot (no handler in the run path; bash tools are spawned detached
// [02 §10]), 5 s, SIGKILL. OpenCode 2 (`@opencode/cli`, another CLI under the same command name) is launch with a hint
// to install v1 (spec §2).

import path from "node:path";
import { UsageError, filterEnv } from "../agent-core.mjs";

export const IMPLEMENTER = "sp-implementer";
export const REVIEWER = "sp-reviewer";
const DEFAULT_BIN = "opencode";
const INSTALL_V1 = "npm i -g opencode-ai@1.19.3 (or brew install anomalyco/tap/opencode; `brew install opencode` installs OpenCode 2)";
const ACTIONS = new Set(["allow", "deny", "ask"]);
const ENV_NAME_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;
// provider/model, split by OpenCode on the first "/" [02 §2]; the preset's "<provider/model>" placeholder is refused.
const MODEL_RE = /^[^\s/<>]+\/[^\s<>]+$/;
const VERSION_RE = /(\d+)\.(\d+)\.(\d+)[^\s]*/;
// Signals of the outcome on stderr [02 §3, §7, §11]. The wording of the agent fallback warning is not pinned in [02].
const AGENT_NOT_FOUND = /\bagent\b[^\n]*\bnot found\b/i;
const AUTO_REJECTING = /auto-rejecting/i;
const SESSION_NOT_FOUND = /Session not found/i;
// quota only with a sign of an exhausted quota in the error itself (spec §3.8).
export const QUOTA_MARKERS = ["insufficient_quota", "usage_not_included", "GoUsageLimitError", "FreeUsageLimitError"];
// HTTP 402 Payment Required: an exhausted balance, as DeepSeek reports it [04b §11] — unlike a 429, never ambiguous.
const INSUFFICIENT_BALANCE = /insufficient[ _]balance/i;
const NETWORK = /ECONNREFUSED|ECONNRESET|ETIMEDOUT|fetch failed|socket hang up/i;
// A step that ended for one of these reasons is not a final answer (export fallback).
const UNFINISHED = new Set(["tool-calls", "length", "error", "content-filter"]);

const isObject = (value) => Boolean(value) && typeof value === "object" && !Array.isArray(value);
const keyed = (profile) => isObject(profile?.auth);
const launchError = (message) => Object.assign(new Error(message), { errorClass: "launch" });

// ---------- permissions (spec §3.6 А4) ----------

const readRules = () => ({ "*": "allow", "*.env": "deny", "*.env.*": "deny", "*.env.example": "allow" });

// external_directory: everything outside the tree is denied, the temp dirs stay allowed as in OpenCode's own default
// set (spec §3.6 А4). [02 §7] does not pin that list (tmp, truncation, skill dirs), so the dirs are named here, as
// "<dir>/*" patterns: $TMPDIR of the harness environment (`tmpdir`: the profile's own when profile.env sets it), /tmp,
// and OpenCode's truncation dir under its data dir — unverified (not in [02]): <data>/opencode/tool-output, where
// OpenCode 1.x keeps the full output of a truncated tool result and tells the model to read it; auth.json next to it
// stays denied. On macOS /tmp and /var are symlinks into /private, so the real names are allowed too, in case
// OpenCode resolves a path first (unverified): the same directories, nothing wider.
export function tempDirRules({ tmpdir = null, dataDir = null, platform = null } = {}) {
  const tmp = typeof tmpdir === "string" ? tmpdir.replace(/\/+$/, "") : "";
  const dirs = [...(tmp.startsWith("/") ? [tmp] : []), "/tmp"];
  if (typeof dataDir === "string" && dataDir.startsWith("/")) dirs.push(path.join(dataDir, "opencode", "tool-output"));
  if (platform === "darwin") dirs.push(...dirs.filter((dir) => /^\/(tmp|var)(\/|$)/.test(dir)).map((dir) => `/private${dir}`));
  return Object.fromEntries([...new Set(dirs)].map((dir) => [`${dir}/*`, "allow"]));
}

// The reviewer's bash: OpenCode matches a pattern against the whole command text, `*` is any run of characters (no
// word boundary) and a trailing " *" also matches nothing, so "git diff *" matches `git diff` and `git diff HEAD`, not
// `git difftool` or `git diff-tree` ("git diff*" did). Each command comes alone too, in case a version lacks that
// trailing rule. Then the arguments that make the four commands write a file (--output), run a configured program
// (--ext-diff, --textconv) or read outside the tree (--no-index; external_directory does not check git's arguments),
// denied after the allows: the last match wins [02 §7]. They match anywhere in the raw text, with no space before
// them, so a quote (`"--output=f"`), a tab or a backslash-newline in front does not slip past. Open, as rules over
// the text cannot express them: a split-quote spelling (`--out''put=f`), and the no-index git switches to by itself
// for a path outside the work tree (`git diff /abs/o.txt /dev/null`): a read outside the tree, never a write.
const REVIEWER_GIT = ["git show", "git diff", "git log", "git status"];
const REVIEWER_GIT_DENY = ["*--output*", "*--ext-diff*", "*--textconv*", "*--no-index*"];

// The complete explicit rule set of a role's agent: explicit `deny` comes back to the model as a tool error and the
// loop goes on; only an `ask` left over ends the run (blocked) [02 §7]. `temp` is tempDirRules()'s input.
export function basePermission(write, temp = {}) {
  const external = { "*": "deny", ...tempDirRules(temp) };
  if (write) {
    return { "*": "allow", read: readRules(), external_directory: external, doom_loop: "deny", question: "deny", webfetch: "deny", websearch: "deny" };
  }
  return {
    "*": "deny",
    read: readRules(),
    grep: "allow",
    glob: "allow",
    list: "allow",
    edit: "deny",
    task: "deny",
    bash: {
      "*": "deny",
      ...Object.fromEntries(REVIEWER_GIT.flatMap((command) => [[command, "allow"], [`${command} *`, "allow"]])),
      ...Object.fromEntries(REVIEWER_GIT_DENY.map((pattern) => [pattern, "deny"])),
    },
    external_directory: external,
    webfetch: "deny",
    websearch: "deny",
  };
}

// options.permission merged into a rule set (spec §3.6 Б): an action replaces the key; an object of patterns is
// merged into the key's patterns (a plain action there becomes its "*" pattern). Key order is kept, new keys and
// patterns go last: OpenCode flattens the rules in order and the last match wins [02 §7]. An object whose patterns
// all deny, "*" among them, is the action "deny" and replaces the key too: merged, that "*" would keep the first place
// of the key's patterns and the allows after it (the reviewer's git commands) would still win.
export function mergePermission(base, extra) {
  const merged = structuredClone(base);
  for (const [name, value] of Object.entries(extra ?? {})) {
    const current = merged[name];
    const denyAll = isObject(value) && value["*"] === "deny" && Object.values(value).every((action) => action === "deny");
    merged[name] = denyAll ? "deny" : isObject(value) && current !== undefined ? { ...(isObject(current) ? current : { "*": current }), ...value } : structuredClone(value);
  }
  return merged;
}

// What a reviewer takes from options.permission: its deny rules only — a plain "deny", and the "deny" patterns of an
// object (a key left with none is dropped). An allow or an ask would widen sp-reviewer past read-only (spec §3.6 А4),
// as an allow rule past the four git commands would widen claude's reviewer. Merged, a deny only narrows the set.
export function denyRules(extra) {
  const rules = {};
  for (const [name, rule] of Object.entries(extra ?? {})) {
    if (rule === "deny") rules[name] = rule;
    else if (isObject(rule)) {
      const patterns = Object.entries(rule).filter(([, action]) => action === "deny");
      if (patterns.length > 0) rules[name] = Object.fromEntries(patterns);
    }
  }
  return rules;
}

function checkPermissionOption(value, profileName) {
  if (value === undefined) return {};
  const bad = (name) => new UsageError(`profile ${profileName}: options.permission.${name} must be "allow", "deny", "ask" or an object of patterns to those`);
  if (!isObject(value)) throw new UsageError(`profile ${profileName}: options.permission must be an object of OpenCode permission rules`);
  for (const [name, rule] of Object.entries(value)) {
    if (typeof rule === "string" ? !ACTIONS.has(rule) : !isObject(rule) || Object.values(rule).some((action) => !ACTIONS.has(action))) throw bad(name);
  }
  return value;
}

// The two primary agents and the set of the job's role: options.permission in full for the writer, its deny rules for
// the reviewer.
export function agentConfig({ write, options = {}, temp = {}, profileName = "-" }) {
  const extra = checkPermissionOption(options.permission, profileName);
  const sets = {
    [IMPLEMENTER]: mergePermission(basePermission(true, temp), extra),
    [REVIEWER]: mergePermission(basePermission(false, temp), denyRules(extra)),
  };
  const role = write ? IMPLEMENTER : REVIEWER;
  return {
    role,
    permission: sets[role],
    agent: Object.fromEntries(Object.entries(sets).map(([name, permission]) => [name, { mode: "primary", permission }])),
  };
}

// ---------- homes (spec §3.4 homes/<profile>, §3.10) ----------

function isolatedHome(ctx) {
  if (!ctx?.profileName) throw new Error("opencode adapter: no profile name for the isolated home");
  return path.join(ctx.paths.homes, ctx.profileName);
}

const xdgOf = (home) => ({
  XDG_CONFIG_HOME: path.join(home, "config"),
  XDG_DATA_HOME: path.join(home, "data"),
  XDG_STATE_HOME: path.join(home, "state"),
  XDG_CACHE_HOME: path.join(home, "cache"),
});

const homeEnvOf = (profile, ctx) => (profile?.home === "isolated" ? xdgOf(isolatedHome(ctx)) : {});

// A variable as the harness gets it: the profile's own (null removes it), else the caller's.
const effectiveEnv = (profile, ctx, name) => (isObject(profile?.env) && Object.hasOwn(profile.env, name) ? profile.env[name] : ctx?.env?.[name]);

// Where the profile's sessions live (the SQLite DB under XDG_DATA_HOME [02 §4]), for resumeCheck; null = unknown.
export function dataDirOf(profile, ctx) {
  if (profile?.home === "isolated") return xdgOf(isolatedHome(ctx)).XDG_DATA_HOME;
  const xdg = effectiveEnv(profile, ctx, "XDG_DATA_HOME");
  if (typeof xdg === "string" && xdg) return xdg;
  const home = effectiveEnv(profile, ctx, "HOME");
  return typeof home === "string" && home ? path.join(home, ".local", "share") : null;
}

// The provider of profile.model ("deepseek" of deepseek/deepseek-v4-pro), or null.
const providerOf = (profile) => (typeof profile?.model === "string" && profile.model.includes("/") ? profile.model.split("/")[0] : null);

// The credential store `opencode auth login` writes in the isolated home [02 §5].
const authFileOf = (ctx) => path.join(xdgOf(isolatedHome(ctx)).XDG_DATA_HOME, "opencode", "auth.json");

// Why a keyed profile would not run on its key, or null. A credential stored by `opencode auth login` for the
// provider wins over keyVar [02 §5]: the job would bill that login while `channels` names the key. The user's own data
// dir may hold one at any time, so a keyed profile runs in its isolated home only (spec §3.4); there, an auth.json
// (left by a login profile of the same name, or a login through `profile env`) refuses the run. Only its existence is
// checked: the adapter never reads a credential store.
function storedLoginProblem(profile, ctx) {
  if (!keyed(profile)) return null;
  const keyVar = profile.keyVar ?? "keyVar";
  if (profile.home !== "isolated") {
    return `a keyed opencode profile runs in its isolated home (the default): in your own home a stored ${providerOf(profile) ?? "provider"} login would win over ${keyVar}`;
  }
  const file = authFileOf(ctx);
  if (ctx?.fs?.exists?.(file) !== true) return null;
  return `${file} exists: a login stored there by opencode auth login wins over ${keyVar}; remove that file (a keyed profile needs no login)`;
}

// With XDG_CONFIG_HOME set, git reads $XDG_CONFIG_HOME/git/{config,ignore,attributes} instead of the caller's
// (~/.gitconfig still applies), so in an isolated home the model's git commands would lose the user's identity, global
// ignores and attributes. This file restores git's own defaults: the caller's XDG config dir, or ~/.config — never
// a dir under homes/ (a caller running with the variables of `agent-dispatch profile env P` would make the include
// point at itself). git skips a missing include target and a missing excludes or attributes file. null when nothing to
// name.
export function gitConfigOf(profile, ctx) {
  const absolute = (value) => typeof value === "string" && path.isAbsolute(value) && !/[\n\r\0]/.test(value);
  const underHomes = (dir) => `${path.resolve(dir)}${path.sep}`.startsWith(`${path.resolve(ctx.paths.homes)}${path.sep}`);
  const caller = ctx?.env?.XDG_CONFIG_HOME;
  const home = effectiveEnv(profile, ctx, "HOME");
  const dir = absolute(caller) && !underHomes(caller) ? caller : absolute(home) ? path.join(home, ".config") : null;
  if (!dir) return null;
  const quoted = (file) => `"${path.join(dir, "git", file).replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
  return [
    "# agent-dispatch, opencode adapter: XDG_CONFIG_HOME points at this isolated home; git reads the caller's files.",
    "[core]",
    `\texcludesFile = ${quoted("ignore")}`,
    `\tattributesFile = ${quoted("attributes")}`,
    "[include]",
    `\tpath = ${quoted("config")}`,
    "",
  ].join("\n");
}

// ---------- the command ----------

function modelOf(profile, profileName) {
  if (typeof profile?.model !== "string" || !MODEL_RE.test(profile.model)) {
    throw new UsageError(`profile ${profileName}: an opencode profile needs "model": "<provider>/<model>" (the -m of opencode run; the ids: opencode models <provider>)`);
  }
  return profile.model;
}

const MANDATORY_NAMES = ["OPENCODE_CONFIG_CONTENT", "OPENCODE_PERMISSION", "OPENCODE_DISABLE_PROJECT_CONFIG", "OPENCODE_DISABLE_CLAUDE_CODE_PROMPT"];
const DEFAULT_NAMES = ["OPENCODE_DISABLE_AUTOUPDATE", "OPENCODE_DISABLE_EXTERNAL_SKILLS", "OPENCODE_PURE"];

function keyVarOf(profile, profileName) {
  if (!keyed(profile)) return null;
  const name = profile.keyVar;
  if (typeof name !== "string" || !ENV_NAME_RE.test(name)) {
    throw new UsageError(`profile ${profileName}: an opencode profile with a key needs keyVar (the provider's variable, e.g. DEEPSEEK_API_KEY)`);
  }
  if ([...MANDATORY_NAMES, ...DEFAULT_NAMES].includes(name) || name.startsWith("XDG_")) {
    throw new UsageError(`profile ${profileName}: keyVar ${name} is a variable the opencode adapter sets itself`);
  }
  return name;
}

function invocation(req, ctx) {
  const profile = req.profile ?? {};
  const profileName = req.profileName ?? ctx?.profileName ?? "-";
  const model = modelOf(profile, profileName);
  const keyVar = keyVarOf(profile, profileName);
  const stored = storedLoginProblem(profile, ctx);
  if (stored) throw new UsageError(`profile ${profileName}: ${stored}`);
  const options = isObject(profile.options) ? profile.options : {};
  const write = req.write === true;
  const temp = { tmpdir: effectiveEnv(profile, ctx, "TMPDIR"), dataDir: dataDirOf(profile, ctx), platform: ctx?.platform ?? null };
  const { role, permission, agent } = agentConfig({ write, options, temp, profileName });
  const root = req.job.workspaceRoot ?? req.job.cwd;
  const instructions = ["AGENTS.md", "CLAUDE.md"].map((name) => path.join(root, name)).filter((file) => ctx?.fs?.exists?.(file) === true);
  if (req.resume && (typeof req.resume.sessionId !== "string" || !req.resume.sessionId)) throw new Error("opencode adapter: resume without a session id");
  const bin = req.harness?.bin ?? profile.bin ?? DEFAULT_BIN;
  return {
    argv: [
      bin,
      "run",
      "--format",
      "json",
      "--title",
      req.job.id ?? "probe",
      "--agent",
      role,
      "-m",
      model,
      ...(typeof profile.effort === "string" && profile.effort ? ["--variant", profile.effort] : []),
      ...(req.resume ? ["-s", req.resume.sessionId] : []),
      "--dir",
      req.job.cwd,
    ],
    env: {
      OPENCODE_DISABLE_AUTOUPDATE: "1",
      OPENCODE_DISABLE_EXTERNAL_SKILLS: "1",
      ...(options.plugins === true ? {} : { OPENCODE_PURE: "1" }),
    },
    mandatoryEnv: {
      OPENCODE_CONFIG_CONTENT: JSON.stringify({ agent, instructions }),
      OPENCODE_PERMISSION: JSON.stringify(permission),
      OPENCODE_DISABLE_PROJECT_CONFIG: "1",
      OPENCODE_DISABLE_CLAUDE_CODE_PROMPT: "1",
    },
    secretEnv: keyVar ? [keyVar] : [],
    stdinPath: req.prompt.path,
    cwd: req.job.cwd,
    meta: { agent: role, dir: req.job.cwd, dataDir: dataDirOf(profile, ctx) },
  };
}

// ---------- the outcome ----------

const errorName = (error) => (typeof error?.name === "string" ? error.name : "");
const errorData = (error) => (isObject(error?.data) ? error.data : {});

export function errorText(error) {
  if (typeof error === "string") return error;
  const data = errorData(error);
  const status = Number.isInteger(data.statusCode) ? ` ${data.statusCode}` : "";
  const message = typeof data.message === "string" ? data.message : typeof error?.message === "string" ? error.message : "";
  return `${errorName(error) || "error"}${status}: ${message}`.trim();
}

// The class of an OpenCode error object (a NamedError {name, data: {message, statusCode?, …}}) [02 §11], or null.
export function classifyError(error) {
  if (error === null || error === undefined) return null;
  const name = errorName(error);
  const data = errorData(error);
  const status = Number.isInteger(data.statusCode) ? data.statusCode : null;
  const text = typeof error === "string" ? error : JSON.stringify(error);
  const has = (needle) => text.toLowerCase().includes(needle.toLowerCase());
  if (SESSION_NOT_FOUND.test(text)) return "resume-lost";
  if (name === "ContextOverflowError" || has("context_length_exceeded") || has("Input exceeds context window")) return "context";
  if (QUOTA_MARKERS.some((marker) => name === marker || has(marker))) return "quota";
  if (status === 402 || INSUFFICIENT_BALANCE.test(text)) return "quota";
  if (name === "ProviderAuthError" || name === "ProviderInitError" || status === 401 || status === 403 || has("Unauthorized: request was blocked by a gateway") || has("Failed to initialize provider")) return "auth";
  if (name === "ProviderModelNotFoundError" || has("Model not found") || status === 404) return "model-not-selected";
  if (status === 429 || status === 529 || has("Quota exceeded") || /too many requests|rate limit|overloaded/i.test(text)) return "rate-limit";
  if ((status !== null && status >= 500) || name === "ProviderHeaderTimeoutError" || name === "ProviderResponseStreamError" || NETWORK.test(text)) return "server";
  return null;
}

const stderrLines = (stderr, pattern) => String(stderr ?? "").split("\n").map((line) => line.trim()).filter((line) => pattern.test(line));

function addUsage(usage, part) {
  const tokens = isObject(part?.tokens) ? part.tokens : {};
  const num = (value) => (typeof value === "number" && Number.isFinite(value) ? value : 0);
  usage.input += num(tokens.input);
  usage.output += num(tokens.output);
  usage.reasoning += num(tokens.reasoning);
  usage.cacheRead += num(tokens.cache?.read);
  usage.cacheWrite += num(tokens.cache?.write);
  usage.cost += num(part?.cost);
  usage.steps += 1;
}

// The messageID a part event belongs to ("" for a part without one), or null for an event without a part.
const messageIdOf = (event) => (isObject(event?.part) ? (typeof event.part.messageID === "string" ? event.part.messageID : "") : null);

// A step_finish reason that ends a message with its final answer (spec §3.6 А9).
const finished = (reason) => typeof reason === "string" && reason !== "" && !UNFINISHED.has(reason);

function reduce(io) {
  const events = Array.isArray(io?.events) ? io.events : [];
  const stderr = String(io?.stderrTail ?? "");
  let sessionId = null;
  // The assistant messages in stream order: messageID → { texts: part id → text, textIndex, finish }. The last one is
  // the message of the last part event of any type (step_start, text, tool_use, step_finish).
  const messages = new Map();
  let last = null;
  let lastError = null;
  let lastErrorIndex = -1;
  const usage = { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, cost: 0, steps: 0 };
  events.forEach((event, index) => {
    if (!isObject(event)) return;
    if (sessionId === null && typeof event.sessionID === "string" && event.sessionID) sessionId = event.sessionID;
    if (event.type === "error") {
      lastError = event.error ?? { name: "UnknownError", data: { message: "error event without an error" } };
      lastErrorIndex = index;
      return;
    }
    const messageID = messageIdOf(event);
    if (messageID === null) return;
    if (!messages.has(messageID)) messages.set(messageID, { texts: new Map(), textIndex: -1, finish: null });
    last = messages.get(messageID);
    if (event.type === "text" && typeof event.part.text === "string") {
      last.texts.set(event.part.id ?? `#${index}`, event.part.text); // a part reported twice keeps its last text
      last.textIndex = index;
    } else if (event.type === "step_finish") {
      addUsage(usage, event.part);
      last.finish = typeof event.part.reason === "string" ? event.part.reason : "";
    }
  });
  const base = { ok: false, response: null, sessionId, usage: usage.steps > 0 ? usage : null, reportedModel: null, errorClass: null, errorText: null };
  // The answer: the text parts of the last message, in order — only once that message's step finished.
  const response = last && last.texts.size > 0 ? [...last.texts.values()].join("\n") : null;
  const answered = response !== null && response.trim() !== "" && finished(last.finish);
  const agentMissing = stderrLines(stderr, AGENT_NOT_FOUND);
  if (agentMissing.length > 0) {
    // OpenCode ran its default agent instead of the sp- agent (spec §3.8): its rules, not ours.
    return { ...base, errorClass: "launch", errorText: `${agentMissing[0]} (OpenCode fell back to its default agent)` };
  }
  const rejected = stderrLines(stderr, AUTO_REJECTING);
  if (rejected.length > 0) return { ...base, errorClass: "blocked", errorText: rejected.slice(0, 3).join("\n") };
  if (SESSION_NOT_FOUND.test(stderr) || classifyError(lastError) === "resume-lost") return { ...base, errorClass: "resume-lost", errorText: "Session not found" };
  if (answered && last.textIndex > lastErrorIndex) return { ...base, ok: true, response };
  if (lastError) return { ...base, errorClass: classifyError(lastError), errorText: errorText(lastError) };
  const tail = stderr.split("\n").map((line) => line.trim()).filter(Boolean).at(-1) ?? null;
  const unfinished = last && !finished(last.finish) ? `no final answer: the last message ${last.finish ? `ended with ${last.finish}` : "did not finish"}` : null;
  return { ...base, errorText: tail ?? unfinished };
}

// Whether an exported assistant message belongs to this run: one of the stream's messageIDs, or created after the
// job started (info.time.created, epoch ms — the v1 message schema; not pinned in [02]).
function ofThisRun(info, job) {
  const ids = new Set((Array.isArray(job.io?.events) ? job.io.events : []).map(messageIdOf).filter(Boolean));
  if (typeof info.id === "string" && ids.has(info.id)) return true;
  const started = Date.parse(job.record?.startedAt ?? "");
  const created = info.time?.created;
  return Number.isFinite(started) && typeof created === "number" && created >= started;
}

// `opencode export <session>` when the stream held no answer and no recognised error (spec §3.6 А9): the last
// assistant message of the session, in the job's environment without the key — when it is this run's and finished.
async function finalize(job, ctx) {
  const reduced = job.reduced;
  if (!reduced || reduced.ok === true || reduced.errorClass || typeof reduced.sessionId !== "string" || !reduced.sessionId) return null;
  if (job.io?.exit?.signal) return null; // killed from outside: a partial session is no answer
  // 60 s, not ctx.exec's 10: a cold start of opencode loads its plugins and session database first.
  const r = await ctx.execHarness(["export", reduced.sessionId], { timeoutMs: 60_000 });
  if (r.error || r.status !== 0) return { meta: { export: `failed (${r.error?.code ?? `exit ${r.status}`})` } };
  let data = null;
  try {
    const text = String(r.stdout ?? "");
    data = JSON.parse(text.slice(Math.max(0, text.indexOf("{"))));
  } catch {
    return { meta: { export: "no JSON" } };
  }
  const messages = Array.isArray(data?.messages) ? data.messages : [];
  const last = [...messages].reverse().find((message) => message?.info?.role === "assistant");
  if (!last) return { meta: { export: "no assistant message" } };
  const info = last.info;
  if (!ofThisRun(info, job)) return { meta: { export: "no message of this run" } };
  const reportedModel = typeof info.providerID === "string" && typeof info.modelID === "string" ? `${info.providerID}/${info.modelID}` : null;
  if (info.error) return { errorClass: classifyError(info.error), errorText: errorText(info.error), reportedModel, meta: { export: "error" } };
  const text = (Array.isArray(last.parts) ? last.parts : []).filter((p) => p?.type === "text" && typeof p.text === "string").map((p) => p.text).join("\n");
  if (!text.trim() || !finished(info.finish)) return { reportedModel, meta: { export: "no final answer" } };
  return { ok: true, response: text, errorClass: null, errorText: null, reportedModel, meta: { export: "final answer" } };
}

// ---------- discovery, resume, doctor ----------

export function parseVersion(text) {
  const match = VERSION_RE.exec(String(text ?? ""));
  return match ? { version: match[0], major: Number(match[1]) } : null;
}

function discover(ctx) {
  const bin = ctx.profile?.bin ?? DEFAULT_BIN;
  const r = ctx.exec(bin, ["--version"]);
  if (r.error) throw launchError(`cannot run ${bin} --version (${r.error.code ?? r.error.message}); install OpenCode 1.19.x: ${INSTALL_V1}`);
  if (r.status !== 0) throw launchError(`${bin} --version exited ${r.status ?? r.signal}`);
  const found = parseVersion(r.stdout);
  if (found && found.major >= 2) {
    throw launchError(`${bin} is OpenCode ${found.version}; the opencode adapter runs OpenCode 1.19.x (OpenCode 2 has another CLI): install v1: ${INSTALL_V1}`);
  }
  return { bin, version: found?.version ?? null };
}

function resumeCheck(prev, profile, req, ctx) {
  const then = isObject(prev?.meta) ? prev.meta : {};
  if (typeof then.dir === "string" && then.dir !== req.job.cwd) return `its session belongs to --dir ${then.dir}, not ${req.job.cwd}`;
  const now = dataDirOf(profile, ctx);
  if ((then.dataDir ?? null) !== now) return `its session lives in data dir ${then.dataDir ?? "(unknown)"}, not ${now ?? "(unknown)"} (XDG_DATA_HOME)`;
  return null;
}

// The provider names of the stored credentials in `opencode auth list` output [02 §6]: the rows of its
// "Credentials <path to auth.json>" block ("●  GitHub Copilot oauth": name, then the type), up to the "N credentials"
// line — not the header's path, not the "Environment" block of provider variables that happen to be set.
export function authListNames(stdout) {
  const lines = String(stdout ?? "").replace(/\x1b\[[0-9;]*[A-Za-z]/g, "").split("\n");
  const start = lines.findIndex((line) => /\bCredentials\b/.test(line));
  const names = [];
  if (start < 0) return names;
  for (const raw of lines.slice(start + 1)) {
    const line = raw.replace(/^[\s│|┌└◇◆●•*-]+/u, "").trim();
    if (!line) continue;
    if (/^\d+ credentials?$/i.test(line) || /^Environment\b/.test(line)) break;
    const words = line.split(/\s+/);
    names.push((words.length > 1 ? words.slice(0, -1) : words).join(" "));
  }
  return names;
}

const providerKey = (text) => String(text).toLowerCase().replace(/[^a-z0-9]/g, "");

// `opencode auth list` in the profile's home and environment (its wrap, the core's allowlist, profile.env, the
// isolated XDG_*): { bin, r, names } — the provider names of the stored credentials, never values [02 §6].
async function storedLogins(profile, ctx) {
  const bin = profile.bin ?? DEFAULT_BIN;
  const wrap = Array.isArray(profile.wrap) ? profile.wrap : [];
  const env = filterEnv(ctx.env ?? {});
  for (const [name, value] of Object.entries(isObject(profile.env) ? profile.env : {})) {
    if (value === null) delete env[name];
    else env[name] = String(value);
  }
  Object.assign(env, homeEnvOf(profile, ctx));
  const argv = [...wrap, bin, "auth", "list"];
  const r = await ctx.exec(argv[0], argv.slice(1), { env, timeoutMs: 30_000 }); // a cold start of opencode, not ctx.exec's 10 s
  return { bin, r, names: r.error || r.status !== 0 ? null : authListNames(r.stdout) };
}

// Model-free checks for `doctor` (spec §5.4): the login through `opencode auth list`, a stored login that would win
// over the key (FAIL, as the run refuses it), and rules that end a run or never reach the reviewer.
async function doctorChecks(profile, ctx) {
  const checks = [];
  const add = (name, level, hint) => checks.push({ name, level, hint });
  const provider = providerOf(profile);
  // Display names ("GitHub Copilot" for github-copilot, the id when the catalog has no name): equal to the provider
  // id without case and punctuation. A provider listed under another name costs a WARN for a login and goes unseen
  // for a key; the auth.json check still refuses that.
  const lists = (names) => names.some((name) => providerKey(name) === providerKey(provider));
  const stored = storedLoginProblem(profile, ctx);
  if (stored) add("home", "FAIL", stored);
  if (keyed(profile) && profile.home === "isolated" && provider && ctx?.fs?.exists?.(isolatedHome(ctx)) === true) {
    const { bin, r, names } = await storedLogins(profile, ctx);
    const keyVar = profile.keyVar ?? "keyVar";
    if (!names) add("login", "WARN", `cannot run ${bin} auth list (${r.error?.code ?? `exit ${r.status}`}); a stored ${provider} login in the isolated home was not checked`);
    // Not `opencode auth logout`: it rewrites auth.json to {}, and the run refuses the file whatever it holds.
    else if (lists(names)) add("login", "FAIL", `opencode auth list in the isolated home names ${provider}: that stored login wins over ${keyVar}; remove ${authFileOf(ctx)}: a keyed profile needs no login (opencode auth logout leaves the file, which the run still refuses)`);
    else add("login", "ok", `no stored ${provider} login in the isolated home; the key goes in through ${keyVar}`);
  }
  if (profile?.auth === "login" && provider) {
    const { bin, r, names } = await storedLogins(profile, ctx);
    const where = profile.home === "isolated" ? `in the isolated home (agent-dispatch profile env ${ctx.profileName} -- opencode auth login)` : "(opencode auth login)";
    if (!names) add("login", "WARN", `cannot run ${bin} auth list (${r.error?.code ?? `exit ${r.status}`}); the login of ${provider} was not checked`);
    else if (lists(names)) add("login", "ok", `opencode auth list names ${provider}`);
    else add("login", "WARN", `opencode auth list shows no login for ${provider} (it lists: ${names.join(", ") || "none"}); the user logs in ${where}`);
  }
  const permission = Object.entries(isObject(profile?.options?.permission) ? profile.options.permission : {});
  const having = (action) => permission.filter(([, rule]) => rule === action || (isObject(rule) && Object.values(rule).includes(action))).map(([name]) => name);
  if (having("ask").length > 0) add("permission", "WARN", `options.permission asks for ${having("ask").join(", ")}: a headless run auto-rejects an ask and ends blocked; use allow or deny`);
  if (having("allow").length > 0) add("reviewer", "WARN", `options.permission allows ${having("allow").join(", ")} for sp-implementer only: sp-reviewer takes only its deny rules (spec §3.6 А4)`);
  if (profile?.options?.plugins === true) add("plugins", "ok", "options.plugins: external OpenCode plugins load (OPENCODE_PURE is not set)");
  return checks;
}

export default {
  id: "opencode",
  idPrefix: "oc",
  manifest: {
    sessionId: "first-event",
    cancel: { ladder: [["SIGTERM", 5000], ["SIGKILL", 0]] },
    helpArgv: ["run", "--help"],
    requiredFlags: ["--format", "--title", "--agent", "--model", "--variant", "--session", "--dir"],
    // XDG_* pass the core's allowlist by prefix; OpenCode has no other home variable (spec §3.6 А10).
    homeEnv: [],
    verifiedVersions: ["1.19.3"],
  },
  discover,
  // The isolated home: its XDG_* are the job's and what `agent-dispatch profile env P` exports, so `opencode auth
  // login` lands where the job looks (spec §4.3).
  prepareHome(profile, ctx) {
    if (profile?.home !== "isolated") return { env: {}, dirs: [], files: [] };
    const env = homeEnvOf(profile, ctx);
    const git = gitConfigOf(profile, ctx);
    const gitDir = path.join(env.XDG_CONFIG_HOME, "git");
    return {
      env,
      dirs: [isolatedHome(ctx), ...Object.values(env), ...(git ? [gitDir] : [])],
      files: git ? [{ path: path.join(gitDir, "config"), mode: 0o600, content: git }] : [],
    };
  },
  invocation,
  // One read-only "PONG" turn: the reviewer agent, title "probe".
  probe: (req, ctx) => invocation({ ...req, write: false }, ctx),
  reduce,
  finalize,
  resumeCheck,
  doctorChecks,
  patterns: {
    "resume-lost": ["Session not found"],
    "model-not-selected": ["Model not found:", "ProviderModelNotFoundError"],
    auth: ["ProviderAuthError", "Failed to initialize provider", "Unauthorized: request was blocked by a gateway"],
    quota: [...QUOTA_MARKERS, INSUFFICIENT_BALANCE],
    context: ["ContextOverflowError", "context_length_exceeded", "Input exceeds context window"],
    blocked: ["auto-rejecting"],
    "rate-limit": ["Quota exceeded", "Too Many Requests", "rate limit"],
    server: [NETWORK, "Provider response headers timed out", "ProviderResponseStreamError"],
    launch: [AGENT_NOT_FOUND, "is not valid JSON", "Configuration is invalid", "You must provide a message or a command"],
  },
};
