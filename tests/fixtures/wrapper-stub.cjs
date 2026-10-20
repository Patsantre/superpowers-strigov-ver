#!/usr/bin/env node
// Test stand-in for the wrappers bin/zcode-dispatch and bin/codex-dispatch, for tests/test-agent-dispatch.sh. Never
// runs ZCode or Codex. The test links it under the wrapper's name (…/zcode-dispatch, …/codex-dispatch) and points
// $AGENT_DISPATCH_ZCODE / $AGENT_DISPATCH_CODEX at the links; the link name is the stub's identity <name>.
//
// $WRAPPER_STUB_DIR (required):
//   <name>.argv            gets one JSON array per call: the argv agent-dispatch passed (the golden-table check)
//   <name>.<verb>.stdout   printed as is for that verb (task, status, result, cancel, …), when present
//   <name>.<verb>.stderr   written to stderr as is, when present
//   <name>.<verb>.exit     the exit code for that verb (default 0)
// Without a canned stdout: `task` prints the wrapper's start line with a fresh id (zt-NNNN, task-stub-NNNN),
// `status --json` prints an empty store of the wrapper's shape, and codex-dispatch's `setup --json` prints a ready
// report (codex found, a ChatGPT login whose detail names an e-mail); other verbs print nothing.
//
// Like the real wrappers, `status --json` answers for one workspace: the tree of --cwd, else of the stub's own cwd.
// A canned store ({ running, recent, latestFinished }) may hold records of several trees: only the records whose
// workspaceRoot is that tree are printed, under that tree's workspaceRoot.
"use strict";
const fs = require("node:fs");
const path = require("node:path");

const name = path.basename(process.argv[1] || "");
const argv = process.argv.slice(2);
const dir = process.env.WRAPPER_STUB_DIR;
if (!dir) {
  process.stderr.write("wrapper-stub: WRAPPER_STUB_DIR is not set\n");
  process.exit(99);
}
if (name !== "zcode-dispatch" && name !== "codex-dispatch") {
  process.stderr.write(`wrapper-stub: unknown identity ${name}\n`);
  process.exit(99);
}
fs.mkdirSync(dir, { recursive: true });
fs.appendFileSync(path.join(dir, `${name}.argv`), `${JSON.stringify(argv)}\n`);

const verb = argv[0] ?? "";
const canned = (suffix) => {
  try {
    return fs.readFileSync(path.join(dir, `${name}.${verb}.${suffix}`), "utf8");
  } catch {
    return null;
  }
};
const stdout = canned("stdout");
const stderr = canned("stderr");
const exit = Number((canned("exit") ?? "0").trim()) || 0;

function nextSeq() {
  const file = path.join(dir, `${name}.seq`);
  let n = 0;
  try {
    n = Number(fs.readFileSync(file, "utf8")) || 0;
  } catch {
    n = 0;
  }
  fs.writeFileSync(file, String(n + 1));
  return String(n + 1).padStart(4, "0");
}

const real = (file) => {
  try {
    return fs.realpathSync(file);
  } catch {
    return path.resolve(file);
  }
};

// The workspace a status call asks about: --cwd, else the stub's own cwd (a test tree's root; no git lookup).
function askedRoot() {
  const i = argv.indexOf("--cwd");
  return real(i >= 0 ? argv[i + 1] : process.cwd());
}

// A canned store filtered to the asked tree; any other canned text as is.
function statusOf(text) {
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    return text;
  }
  if (!data || typeof data !== "object" || !(Array.isArray(data.running) || Array.isArray(data.recent))) return text;
  const root = askedRoot();
  const here = (record) => record && (typeof record.workspaceRoot !== "string" || real(record.workspaceRoot) === root);
  const store = { ...data, workspaceRoot: root };
  for (const list of ["running", "recent"]) if (Array.isArray(data[list])) store[list] = data[list].filter(here);
  if ("latestFinished" in data) store.latestFinished = here(data.latestFinished) ? data.latestFinished : null;
  return `${JSON.stringify(store, null, 2)}\n`;
}

if (stdout !== null) process.stdout.write(verb === "status" && argv.includes("--json") ? statusOf(stdout) : stdout);
else if (verb === "task") {
  const seq = nextSeq();
  if (name === "zcode-dispatch") process.stdout.write(`ZCode Task started in the background as zt-${seq}\n`);
  else process.stdout.write(`Codex Task started in the background as task-stub-${seq}. Check /codex:status task-stub-${seq} for progress.\n`);
} else if (verb === "status" && argv.includes("--json")) {
  const root = askedRoot();
  const empty = name === "zcode-dispatch" ? { workspaceRoot: root, running: [], recent: [] } : { workspaceRoot: root, running: [], latestFinished: null, recent: [] };
  process.stdout.write(`${JSON.stringify(empty, null, 2)}\n`);
} else if (verb === "setup" && name === "codex-dispatch" && argv.includes("--json")) {
  const report = {
    ready: true,
    codex: { available: true, detail: "codex-cli 0.0.0-stub; advanced runtime available" },
    auth: { available: true, loggedIn: true, detail: "ChatGPT login active for stub-user@example.com", authMethod: "chatgpt", requiresOpenaiAuth: true },
  };
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
}
if (stderr !== null) process.stderr.write(stderr);
process.exit(exit);
