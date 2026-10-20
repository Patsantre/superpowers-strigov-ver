#!/usr/bin/env node
// A tiny CLI over bin/lib/agent-core.mjs for tests/test-agent-core.sh, so the core is tested before agent-dispatch
// exists. It wires the test adapters (tests/fixtures/adapters/plain.mjs) and nothing else: no config.json, no key
// store — the profile comes as JSON on the command line, and `auth: {"keyEnv": VAR}` is the only key source. Its
// value goes to the core unchecked (the core trims it and refuses an empty one); any other `auth` object resolves to
// nothing. CORE_HARNESS_KEY_LOG names a file that gets one line per key resolution, so tests see when it ran.
//
// Usage: core-harness.mjs task --profile NAME [--profile-json JSON] [--role R] --background [--write] [--cwd W]
//                                [--resume-task ID | --fresh] --prompt-file F
//        core-harness.mjs status [ID] [--cwd W] [--json] [--all] | result ID [--cwd W] | cancel ID [--cwd W]
//        core-harness.mjs release-stale [--cwd W] | count-running --profile NAME | __run <id> <jobs-dir> <token>
//        core-harness.mjs probe --profile NAME [--profile-json JSON] | env-conflicts --profile NAME [--profile-json JSON]
// Exit codes as agent-dispatch: 0 success · 1 runtime failure · 2 refusal without launch.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs } from "node:util";

const SELF = fileURLToPath(import.meta.url);
const core = await import(pathToFileURL(path.join(path.dirname(SELF), "..", "..", "bin", "lib", "agent-core.mjs")).href);
const { default: plain, plainSigint, plainLeak } = await import(pathToFileURL(path.join(path.dirname(SELF), "adapters", "plain.mjs")).href);

const ADAPTERS = { [plain.id]: plain, [plainSigint.id]: plainSigint, [plainLeak.id]: plainLeak };

// The profile of --profile / --profile-json, its adapter and its key resolver.
function profileOf(values) {
  if (!values.profile) throw new core.UsageError("requires --profile <name>");
  let profile;
  try {
    profile = JSON.parse(values["profile-json"] ?? '{"harness":"plain"}');
  } catch (error) {
    throw new core.UsageError(`--profile-json: ${error.message}`);
  }
  const adapter = ADAPTERS[profile.harness];
  if (!adapter) throw new core.UsageError(`profile ${values.profile}: unknown harness ${profile.harness}`);
  const keyEnv = profile.auth?.keyEnv;
  const resolveSecret = keyEnv
    ? () => {
        if (process.env.CORE_HARNESS_KEY_LOG) fs.appendFileSync(process.env.CORE_HARNESS_KEY_LOG, `resolved ${keyEnv}\n`);
        return process.env[keyEnv] ?? "";
      }
    : null;
  return { profileName: values.profile, profile, adapter, resolveSecret };
}

function parse(args, options, maxPositionals, minPositionals = 0) {
  let parsed;
  try {
    parsed = parseArgs({ args, options, allowPositionals: true, strict: true });
  } catch (error) {
    throw new core.UsageError(error.message);
  }
  const count = parsed.positionals.length;
  if (count > maxPositionals || count < minPositionals) throw new core.UsageError(`unexpected arguments: ${args.join(" ")}`);
  return parsed;
}

async function cmdTask(args) {
  const { values } = parse(
    args,
    {
      profile: { type: "string" },
      "profile-json": { type: "string" },
      role: { type: "string" },
      background: { type: "boolean" },
      write: { type: "boolean" },
      cwd: { type: "string" },
      "resume-task": { type: "string" },
      fresh: { type: "boolean" },
      "prompt-file": { type: "string" },
    },
    0,
  );
  if (!values.background) throw new core.UsageError("task requires --background (there is no foreground mode)");
  if (values["resume-task"] !== undefined && values.fresh) throw new core.UsageError("--resume-task and --fresh are mutually exclusive");
  const { profileName, profile, adapter, resolveSecret } = profileOf(values);
  const { id } = await core.startJob({
    adapter,
    profileName,
    profile,
    role: values.role ?? null,
    write: values.write === true,
    cwd: values.cwd,
    promptFile: values["prompt-file"],
    resumeTaskId: values["resume-task"] ?? null,
    resolveSecret,
    cliPath: SELF,
  });
  process.stdout.write(`${core.startLine(profileName, id)}\n`);
  return 0;
}

// doctor --probe in miniature: one line `probe <profile>: <status>[/<class>] response=<json>`, exit 0 when completed.
async function cmdProbe(args) {
  const { values } = parse(args, { profile: { type: "string" }, "profile-json": { type: "string" }, cwd: { type: "string" } }, 0);
  const { profileName, profile, adapter, resolveSecret } = profileOf(values);
  const r = await core.runProbe({ adapter, profileName, profile, resolveSecret, cwd: values.cwd ?? null });
  process.stdout.write(`probe ${profileName}: ${r.status}${r.errorClass ? `/${r.errorClass}` : ""} response=${JSON.stringify(r.response)}\n`);
  return r.status === "completed" ? 0 : 1;
}

// doctor's env check in miniature: the profile.env names that conflict with the adapter's mandatory settings.
async function cmdEnvConflicts(args) {
  const { values } = parse(args, { profile: { type: "string" }, "profile-json": { type: "string" } }, 0);
  const { profileName, profile, adapter } = profileOf(values);
  const ctx = core.makeCtx({ profile, profileName });
  const owned = await core.mandatorySettings(adapter, profile, ctx);
  process.stdout.write(`conflicts: ${core.envConflicts(profile.env, owned).join(" ") || "-"} (mandatory: ${owned.names.join(" ")})\n`);
  return 0;
}

async function main(argv) {
  const [verb, ...rest] = argv;
  try {
    switch (verb) {
      case "task":
        return await cmdTask(rest);
      case "status": {
        const { values, positionals } = parse(rest, { cwd: { type: "string" }, json: { type: "boolean" }, all: { type: "boolean" } }, 1);
        return core.statusCommand({ cwd: values.cwd, id: positionals[0] ?? null, json: values.json === true, all: values.all === true });
      }
      case "result": {
        const { values, positionals } = parse(rest, { cwd: { type: "string" } }, 1, 1);
        return core.resultCommand({ cwd: values.cwd, id: positionals[0] });
      }
      case "cancel": {
        const { values, positionals } = parse(rest, { cwd: { type: "string" } }, 1, 1);
        return await core.cancelCommand({ cwd: values.cwd, id: positionals[0] });
      }
      case "release-stale": {
        const { values } = parse(rest, { cwd: { type: "string" } }, 0);
        return core.releaseStaleCommand({ cwd: values.cwd });
      }
      case "count-running": {
        const { values } = parse(rest, { profile: { type: "string" } }, 0);
        const jobs = core.runningJobsOfProfile(values.profile ?? "");
        process.stdout.write(`${jobs.length}${jobs.length > 0 ? ` ${jobs.map((job) => job.id).join(",")}` : ""}\n`);
        return 0;
      }
      case "probe":
        return await cmdProbe(rest);
      case "env-conflicts":
        return await cmdEnvConflicts(rest);
      case core.RUN_VERB:
        return await core.runJob({ id: rest[0], jobsDir: rest[1], token: rest[2], adapters: ADAPTERS });
      default:
        throw new core.UsageError(`usage: core-harness <task|status|result|cancel|release-stale|count-running|probe|env-conflicts> [args...]${verb ? ` (unknown verb: ${verb})` : ""}`);
    }
  } catch (error) {
    process.stderr.write(`${core.CLI_NAME}: ${error.message}\n`);
    return core.exitCodeOf(error);
  }
}

const invokedDirectly = (() => {
  try {
    return Boolean(process.argv[1]) && fs.realpathSync(process.argv[1]) === fs.realpathSync(SELF);
  } catch {
    return false;
  }
})();
if (invokedDirectly) process.exitCode = await main(process.argv.slice(2));
