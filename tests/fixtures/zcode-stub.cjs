#!/usr/bin/env node
// Test stand-in for ZCode's zcode.cjs, selected via ZCODE_BIN. Never calls a model.
// ZCODE_STUB_MODE: ok | pong | resume | record | model-not-selected | auth | quota |
//                  launch | hang | ignore-term | split-utf8 | crash | malformed
// ZCODE_STUB_RECORD: file the `record` mode writes; ZCODE_STUB_DELAY_MS: wait before
// acting; ZCODE_STUB_MESSAGE: stderr text for the four error modes; ZCODE_STUB_TERM_DELAY_MS:
// how long ignore-term waits after SIGTERM before exiting.
"use strict";
const fs = require("node:fs");

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

async function run() {
  switch (mode) {
    case "ok":
      return emit("DONE\nstub finished");
    case "pong":
      return emit("PONG");
    case "resume":
      if (!flag("--resume")) fail("stub resume mode: --resume is missing");
      return emit("DONE\nresumed");
    case "record": {
      const stdin = flag("-p") === "-" ? await readStdin() : null;
      let personalConfig = null; // the personal provider config as the wrapper left it for this run
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
          },
          personalConfig,
        }),
      );
      return emit("DONE\nrecorded");
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
