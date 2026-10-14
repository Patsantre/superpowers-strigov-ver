#!/usr/bin/env node
// Test stand-in for ZCode's zcode.cjs, selected via ZCODE_BIN. Never calls a model.
// ZCODE_STUB_MODE: ok | pong | resume | record | login | leak | model-not-selected | auth | quota |
//                  launch | hang | ignore-term | split-utf8 | crash | malformed
// ZCODE_STUB_RECORD: file the `record` mode (and `login`, when set) writes, including envAll and
// `resolved`, the stub's model of where the CLI keeps its state; ZCODE_STUB_DELAY_MS: wait before acting;
// ZCODE_STUB_MESSAGE: stderr text for the four error modes; ZCODE_STUB_TERM_DELAY_MS: how long ignore-term waits after SIGTERM before exiting;
// ZCODE_STUB_EXIT: the exit code of the `login` and `leak` modes (default 0).
// Tests explicitly list ZCODE_STUB_* in ZCODE_ENV_PASSTHROUGH because the wrapper filters the CLI env.
"use strict";
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const argv = process.argv.slice(2);
const mode = process.env.ZCODE_STUB_MODE || "ok";
if (mode === "ignore-term") {
  process.on("SIGTERM", () => setTimeout(() => process.exit(0), Number(process.env.ZCODE_STUB_TERM_DELAY_MS || 2000)));
}
const flag = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};
const sessionId = flag("--resume") || `sess_stub_${process.pid}`;

function emit(response) {
  process.stdout.write(
    `${JSON.stringify({
      sessionId,
      traceId: "trace_stub",
      turnId: "turn_stub",
      response,
      usage: { inputTokens: 100, cacheReadTokens: 40, outputTokens: 7, reasoningTokens: 3 },
      eventCount: 1,
    })}\n`,
  );
}

function fail(defaultMessage) {
  process.stderr.write(`Error: ${process.env.ZCODE_STUB_MESSAGE || defaultMessage}\n`);
  process.exit(1);
}

function readStdin() {
  return new Promise((resolve) => {
    let text = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => (text += chunk));
    process.stdin.on("end", () => resolve(text));
  });
}

// Where the real CLI (zcode.cjs 3.15.1) would put its state with this environment — a model of its
// resolvers (docs/zcode-cli-findings.md, "CLI data home"): the credential store (Vta: ZCODE_DATA_BASE_DIR,
// else HOME), the storage root (storage.dir: ZCODE_STORAGE_DIR, else ~/.zcode), the session database
// (storage.sessionDbPath: ZCODE_SESSION_DB_PATH or its alias ZCODE_SESSION_DB, else
// ~/.zcode/cli/db/db.sqlite) and the logs (JB: ZCODE_LOG_DIR, else ~/.zcode/cli/log).
function resolvedPaths() {
  const env = process.env;
  const home = os.homedir();
  return {
    credentials: path.join(env.ZCODE_DATA_BASE_DIR || home, ".zcode", "v2", "credentials.json"),
    storageDir: env.ZCODE_STORAGE_DIR || path.join(home, ".zcode"),
    sessionDb: env.ZCODE_SESSION_DB_PATH || env.ZCODE_SESSION_DB || path.join(home, ".zcode", "cli", "db", "db.sqlite"),
    logDir: env.ZCODE_LOG_DIR || path.join(home, ".zcode", "cli", "log"),
  };
}

// Writes $ZCODE_STUB_RECORD: argv, stdin, cwd, selected wrapper env, all variables the CLI received
// (envAll), where it would resolve its state (resolvedPaths), and the personal provider config.
function writeStubRecord(stdin) {
  let personalConfig = null;
  try {
    personalConfig = JSON.parse(fs.readFileSync(process.env.ZCODE_PERSONAL_PROVIDER_CONFIG_FILE, "utf8"));
  } catch {
    personalConfig = null;
  }
  fs.writeFileSync(
    process.env.ZCODE_STUB_RECORD,
    JSON.stringify({
      argv,
      stdin,
      cwd: process.cwd(),
      env: {
        ZCODE_BUILTIN_PROVIDER_CONFIG_FILE: process.env.ZCODE_BUILTIN_PROVIDER_CONFIG_FILE ?? null,
        ZCODE_BUILTIN_PROVIDER_BUNDLED_CONFIG_FILE: process.env.ZCODE_BUILTIN_PROVIDER_BUNDLED_CONFIG_FILE ?? null,
        ZCODE_APP_VERSION: process.env.ZCODE_APP_VERSION ?? null,
        ZCODE_PERSONAL_PROVIDER_CONFIG_FILE: process.env.ZCODE_PERSONAL_PROVIDER_CONFIG_FILE ?? null,
        ZCODE_DATA_BASE_DIR: process.env.ZCODE_DATA_BASE_DIR ?? null,
        ZCODE_STORAGE_DIR: process.env.ZCODE_STORAGE_DIR ?? null,
        ZCODE_SESSION_DB_PATH: process.env.ZCODE_SESSION_DB_PATH ?? null,
        ZCODE_SESSION_DB: process.env.ZCODE_SESSION_DB ?? null,
        ZCODE_LOG_DIR: process.env.ZCODE_LOG_DIR ?? null,
        ZCODE_HTTP_PROXY: process.env.ZCODE_HTTP_PROXY ?? null,
      },
      envAll: { ...process.env },
      resolved: resolvedPaths(),
      personalConfig,
    }),
  );
}

async function run() {
  switch (mode) {
    case "ok":
      return emit("DONE\nstub finished");
    case "pong":
      return emit("PONG");
    case "resume":
      if (!flag("--resume")) fail("stub resume mode: --resume is missing");
      return emit("DONE\nresumed");
    case "record":
      writeStubRecord(flag("-p") === "-" ? await readStdin() : null);
      return emit("DONE\nrecorded");
    case "login": {
      // Stand-in for `zcode login zai`: records the run (when ZCODE_STUB_RECORD is set), then writes
      // what the real login writes — a credential into the store the CLI resolves (resolvedPaths:
      // ZCODE_DATA_BASE_DIR, else HOME) and its GLM-5.3 default selection into the personal provider
      // config, keeping the file's other content as the real saveConfiguredDefault does
      // (update(o => ({...o, defaultModelSelection}))) — prints a login URL, and exits with ZCODE_STUB_EXIT.
      if (argv.length !== 2 || argv[0] !== "login" || argv[1] !== "zai") fail(`stub login mode: expected argv "login zai", got ${JSON.stringify(argv)}`);
      if (process.env.ZCODE_STUB_RECORD) writeStubRecord(null);
      const store = resolvedPaths().credentials;
      fs.mkdirSync(path.dirname(store), { recursive: true });
      fs.writeFileSync(store, JSON.stringify({ "oauth:zai:access_token": "stub-secret-token-0123" }));
      let personal = null;
      try {
        personal = JSON.parse(fs.readFileSync(process.env.ZCODE_PERSONAL_PROVIDER_CONFIG_FILE, "utf8"));
      } catch {
        personal = null;
      }
      if (!personal || typeof personal !== "object" || Array.isArray(personal)) personal = { schemaVersion: 1 };
      personal.config = { ...(personal.config ?? {}), loginWrote: true, defaultModelSelection: { providerId: "account:zai-individual-coding-plan", modelId: "GLM-5.3" } };
      fs.writeFileSync(process.env.ZCODE_PERSONAL_PROVIDER_CONFIG_FILE, JSON.stringify(personal));
      process.stdout.write("Open this URL to log in: https://example.invalid/stub-login\nModel: account:zai-individual-coding-plan/GLM-5.3\n");
      return process.exit(Number(process.env.ZCODE_STUB_EXIT || 0));
    }
    case "leak": {
      // Stand-in for GLM's shell printing the personal provider config (in api-key mode it holds the key):
      // the text goes to stderr in two chunks split inside the key value, then to the response (exit 0)
      // or raw to stdout with exit ZCODE_STUB_EXIT.
      const text = fs.readFileSync(process.env.ZCODE_PERSONAL_PROVIDER_CONFIG_FILE, "utf8").replace(/\s+/g, " ");
      const at = text.indexOf('"apiKey":');
      const splitAt = at >= 0 ? text.indexOf('"', at + 9) + 6 : Math.floor(text.length / 2);
      process.stderr.write(`leaked: ${text.slice(0, splitAt)}`);
      setTimeout(() => {
        process.stderr.write(`${text.slice(splitAt)}\n`);
        const code = Number(process.env.ZCODE_STUB_EXIT || 0);
        if (code === 0) return emit(`DONE\n${text}`);
        process.stdout.write(`${text}\n`);
        return process.exit(code);
      }, 50);
      return undefined;
    }
    case "split-utf8": {
      const value = {
        sessionId,
        traceId: "trace_stub",
        turnId: "turn_stub",
        response: "Ответ: Привет ё",
        usage: { inputTokens: 100, cacheReadTokens: 40, outputTokens: 7, reasoningTokens: 3 },
        eventCount: 1,
      };
      const output = Buffer.from(`${JSON.stringify(value)}\n`);
      const splitAt = output.indexOf(Buffer.from("ё")) + 1;
      process.stdout.write(output.subarray(0, splitAt));
      setTimeout(() => process.stdout.write(output.subarray(splitAt)), 50);
      return undefined;
    }
    case "model-not-selected":
      return fail("Model creation failed — Select a model before continuing");
    case "auth":
      return fail("401 Unauthorized");
    case "quota":
      return fail("429 usage limit reached");
    case "launch":
      return fail("Cannot find module '@zcode/bootstrap'");
    case "hang":
      setTimeout(() => {}, 600_000);
      return undefined;
    case "ignore-term":
      setTimeout(() => {}, 600_000);
      return undefined;
    case "crash":
      process.kill(process.pid, "SIGKILL");
      return undefined;
    case "malformed":
      process.stdout.write("not json\n");
      return undefined;
    default:
      return fail(`unknown ZCODE_STUB_MODE: ${mode}`);
  }
}

setTimeout(run, Number(process.env.ZCODE_STUB_DELAY_MS || 0));
