// adapters/codex.mjs — the pass-through adapter of the `codex` harness (the built-in profiles luna, sol, astra,
// astra-high and any user profile with "harness": "codex"): agent-dispatch runs the existing bin/codex-dispatch
// wrapper (the vendored Codex companion) and hands its stdout, stderr and exit code back unchanged
// (docs/superpowers/specs/2026-10-20-universal-dispatchers-design.md §3.1, §3.3 "Сквозные вызовы").
//
// The profile's model and effort go to the companion as they are: agent-dispatch never checks a codex model (§1.1
// item 3). The companion has no workspace reservation, no timeout and no errorClass — that stays so.

const ID_RE = /^task-[A-Za-z0-9-]+$/;

export default {
  id: "codex",
  kind: "pass-through",
  wrapper: { name: "codex-dispatch", envVar: "AGENT_DISPATCH_CODEX" },
  idPrefix: "task-",
  // Without --write the companion runs Codex in its read-only sandbox.
  readOnly: "os",
  alwaysWrites: false,

  resumeIdOk: (id) => ID_RE.test(id),

  // codex-dispatch task --background [--write] --model <model> --effort <effort> [--cwd W]
  //                    [--resume-task task-… | --fresh] --prompt-file F
  taskArgv({ profile, write, cwd, resumeTaskId, fresh, promptFile }) {
    return [
      "task",
      "--background",
      ...(write ? ["--write"] : []),
      "--model",
      profile.model,
      "--effort",
      profile.effort,
      ...(cwd !== undefined ? ["--cwd", cwd] : []),
      ...(resumeTaskId !== undefined ? ["--resume-task", resumeTaskId] : fresh ? ["--fresh"] : []),
      "--prompt-file",
      promptFile,
    ];
  },

  taskWarnings: () => [],

  // `codex-dispatch status --json` → { workspaceRoot, running, latestFinished, recent, … }. A companion job names no
  // profile: it is matched to the first codex profile with the same model and effort (`profiles`: [{ name, model,
  // effort }]), else "-". "queued" counts as running.
  statusJobs(data, { profiles = [] } = {}) {
    const records = [
      ...(Array.isArray(data?.running) ? data.running : []),
      ...(data?.latestFinished ? [data.latestFinished] : []),
      ...(Array.isArray(data?.recent) ? data.recent : []),
    ];
    const seen = new Set();
    const jobs = [];
    for (const record of records) {
      if (!record || typeof record.id !== "string" || seen.has(record.id)) continue;
      seen.add(record.id);
      const model = record.request?.model ?? record.model ?? null;
      const effort = record.request?.effort ?? record.effort ?? null;
      const match = profiles.find((profile) => profile.model === model && profile.effort === effort);
      jobs.push({
        id: record.id,
        profile: match ? match.name : "-",
        harness: "codex",
        status: record.status === "queued" ? "running" : (record.status ?? "-"),
        errorClass: null,
        write: record.write === true,
        cwd: record.workspaceRoot ?? data?.workspaceRoot ?? null,
        pid: Number.isInteger(record.pid) ? record.pid : null,
      });
    }
    return jobs;
  },
};
