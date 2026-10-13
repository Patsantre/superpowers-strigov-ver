# Review: glm-zcode-implementer — Ф2

- **Date**: 2026-10-14
- **Phase scope**: bin/zcode-dispatch shim + bin/lib/zcode-dispatch.mjs job wrapper, stubbed unit tests tests/test-zcode-dispatch.sh
- **Base commit**: 001e318
- **Rounds**: 5 (Opus 4.1 + Codex Astra 4.2 control)
- **Outcome**: CLEAN (after a user decision at the round-4 cap)

Outcome context: at the round-4 cap the user chose option C (remove automatic stale reclaim; explicit `release-stale` verb, F4-B1-Ф2) and authorized an extra round 5, which ended with Opus REVIEW_OK (SPEC OK / QUALITY OK) and Codex REVIEW_OK.

History by round: R1 — 4.2 found two plan-mandated defects (TOCTOU workspace guard + cancel admitting next task early; per-chunk UTF-8 decoding), user authorized both fixes; R2 — regression: concurrent stale reclaimers could delete a successor's reservation; R3 — regression: dead reclaim-marker recovery race; R4 (cap) — regression: automatic reclaim raced the task-to-runner handoff, user chose option C; R5 — both clean.

## Findings history

| id | reviewer | finding | decision | final status |
|---|---|---|---|---|
| F1-B1-Ф2 | Codex 4.2 (R1) | TOCTOU in one-write-task-per-workspace guard; cancel admits next task before CLI exits (atomic workspace reservation required) | ACCEPTED | fixed |
| F1-B2-Ф2 | Codex 4.2 (R1) | per-chunk UTF-8 decoding corrupts multibyte chars split across chunks (setEncoding utf8 required) | ACCEPTED | fixed |
| Ф2-F1-D1 | Opus 4.1 (R1) | PID reuse not handled: stale running record after reboot — isAlive treats EPERM as alive (workspace guard blocks forever), reaper SIGKILLs -childPid group, cancel SIGTERMs reused runnerPid; cheap fix:... | DEFER | deferred |
| Ф2-F1-D2 | Opus 4.1 (R1) | classifier haystack = whole stderr tail + stdout, not just the final Error line; tool/progress noise on stderr can misclassify (covered by accepted risk R5) | DEFER | deferred |
| Ф2-F1-D3 | Opus 4.1 (R1) | CLI process group not killed after normal exit (yolo background processes survive the job, :366); Ctrl-C on doctor --probe orphans the detached probe CLI | DEFER | deferred |
| Ф2-F1-N1 | Opus 4.1 (R1) | ZCODE_TASK_TIMEOUT_MIN > 35791 overflows setTimeout → instant failed/timeout | NIT | deferred |
| Ф2-F1-N2 | Opus 4.1 (R1) | per-chunk utf8 decoding can split multibyte chars in response/log; use setEncoding('utf8') | NIT | deferred |
| Ф2-F1-N3 | Opus 4.1 (R1) | resolveResume duplicates requireJob's first three lines (plan-verbatim) | NIT | deferred |
| Ф2-F1-N4 | Opus 4.1 (R1) | Step 8 constants block lost trailing comments; USAGE_FIELDS/PATTERNS compact JSON formatting | NIT | deferred |
| Ф2-F1-N5 | Opus 4.1 (R1) | test 2 records stub cwd but never asserts it equals repo root (C5) | NIT | deferred |
| Ф2-F1-N6 | Opus 4.1 (R1) | allocateRecord ignores orphan .json.terminal files → id reuse shadowed by stale terminal | NIT | deferred |
| Ф2-F1-N7 | Opus 4.1 (R1) | shim word-splits glob/ls on HOME with spaces (same as codex-dispatch) | NIT | deferred |
| Ф2-F1-N8 | Opus 4.1 (R1) | several C1 guard paths untested (invalid timeout, missing ZCODE_BIN/provider config, resume cancelled/session-less, non-zt id, whitespace prompt) | NIT | deferred |
| F2-B1-Ф2 | Codex 4.2 (R2) | regression from F1-B1: concurrent stale reclaimers could delete a successor reservation (exclusive reclaim marker added) | ACCEPTED | fixed |
| Ф2-F2-N1 | Opus 4.1 (R2) | job id computed before the reservation (nextJobId :633 then acquireReservation :634) and the allocateRecord EEXIST retry removed (:209-223): during a stale-lock reclaim a competitor can take the same ... | NIT | deferred |
| Ф2-F2-N2 | Opus 4.1 (R2) | updateReservation rewrites the lock in place (ftruncate+write); SIGKILL between them leaves an empty active.lock read as held forever (:304-328, :347-348) — treat old unparsable lock as stale | NIT | deferred |
| Ф2-F2-N3 | Opus 4.1 (R2) | stale-lock reclaim read-then-unlink not atomic (:367-373); covered in practice by claimRunnerReservation + running-record check → escalated by codex-control round 2 to F2-B1-Ф2 | NIT | deferred |
| Ф2-F2-N4 | Opus 4.1 (R2) | concurrent-tasks test is timing-dependent; deterministic variant: pre-create active.lock with live holder pid and non-running jobId, assert exit 2 | NIT | deferred |
| Ф2-F2-N5 | Opus 4.1 (R2) | stale-lock reclaim SIGKILLs previous.childPid group even when the record is terminal (:360-365) — PID-reuse path, same family as Ф2-F1-D1 | NIT | deferred |
| Ф2-F2-N6 | Opus 4.1 (R2) | plan Ф3 zcode-invocation verb table still says cancel '…SIGKILL, stops the runner' (plan:2626); as built cancel no longer signals the runner | NIT | deferred |
| F3-B1-Ф2 | Codex 4.2 (R3) | regression from F2-B1: dead reclaim-marker recovery race (replaced by generation-numbered reservation files) | ACCEPTED | fixed |
| Ф2-F3-N1 | Opus 4.1 (R3) | dead reclaim-marker recovery is itself read-check-unlink (:354-360): two reclaimers can both enter the critical section under triple preconditions; harden later via atomic rename-claim + token check o... | NIT | deferred |
| Ф2-F3-N2 | Opus 4.1 (R3) | acquireReclaimMarker waits on a live marker holder with no deadline (:350-353); PID reuse/EPERM → task loops forever instead of exit 2 (same family as Ф2-F1-D1) | NIT | deferred |
| Ф2-F3-N3 | Opus 4.1 (R3) | plan text not updated for F2-B1: Non-goals (:60), C3 (:182), R7 (:269) mention only the reservation file; as built there is also active.lock.reclaim | NIT | deferred |
| Ф2-F3-N4 | Opus 4.1 (R3) | staleToken written into the marker but never read; createReservation/releaseReservation names only describe the reservation (cosmetic) | NIT | deferred |
| F4-B1-Ф2 | Codex 4.2 (R4) | regression from F3-B1 (round-4 cap): automatic reclaim raced the normal task-to-runner handoff; user chose option C: remove automatic reclaim, add explicit release-stale verb | ACCEPTED | fixed |
| Ф2-F4-D1 | Opus 4.1 (R4) | plan sync edited Ф3 cancel/Refusals rows to match as-built cmdCancel; resolves Ф2-F2-N6 (informational) | DEFER | deferred |
| Ф2-F4-N1 | Opus 4.1 (R4) | narrow transfer race on a task SIGKILLed between spawn and updateReservation with 3-way interleaving; mitigated by onSpawn SIGTERM; hardening: runner checks its generation is still highest before spaw... | NIT | deferred |
| Ф2-F4-N2 | Opus 4.1 (R4) | updateRunning throw in onSpawn (ENOSPC/EACCES) → runJob finally releases the reservation while the detached CLI runs, childPid unrecorded | NIT | deferred |
| Ф2-F4-N3 | Opus 4.1 (R4) | early cancel before onSpawn leaves childPid unrecorded; dead-holder reclaim cannot find a SIGTERM-ignoring CLI group (R7 family) | NIT | deferred |
| Ф2-F4-N4 | Opus 4.1 (R4) | updateReservation rewrites the generation file in place (ftruncate+write, :352) — crash/ENOSPC leaves an empty highest generation → workspace fails closed; temp+rename would fix (same as Ф2-F2-N2) | NIT | deferred |
| Ф2-F4-N5 | Opus 4.1 (R4) | test dead code: realLink saved/restored but fs.linkSync never patched | NIT | deferred |
| Ф2-F4-N6 | Opus 4.1 (R4) | misleading test label '…the loser cannot affect it through cancel' | NIT | deferred |
| Ф2-F4-N7 | Opus 4.1 (R4) | plan Step 6 runtime says ~20 s; observed ~33 s | NIT | deferred |
| Ф2-F5-N1 | Opus 4.1 (R5) | test 'release-stale finalizes a dead-holder job…' passes via the status reaper even without release-stale's finalize; assert note == 'stale reservation released' or read .terminal before status | NIT | deferred |
| Ф2-F5-N2 | Opus 4.1 (R5) | release-stale's CLI-process-group-alive refusal (:419-422) has no test | NIT | deferred |
| Ф2-F5-N3 | Opus 4.1 (R5) | in-place updateReservation (ftruncate+write, :373) → unparsable highest generation permanently refused by task and release-stale; runner's one-shot reservationFileForToken read can hit the truncate wi... | NIT | deferred |
| Ф2-F5-N4 | Opus 4.1 (R5) | C1 says no other task refusal contains 'release-stale' — refusals echoing user input (prompt path :658, cwd :98, parseArgs :644) can; a fixed sentinel prefix would make the Ф3 match exact (Ф3 concern) | NIT | deferred |
| Ф2-F5-N5 | Opus 4.1 (R5) | plan C2 note values omit 'stale reservation released' | NIT | deferred |
| Ф2-F5-N6 | Opus 4.1 (R5) | test 7 label omits its new release-stale assertion | NIT | deferred |
| Ф2-F5-N7 | Opus 4.1 (R5) | job can be terminal a moment before the runner writes .released; an immediate next task can get the guard refusal (back-to-back tests rely on node startup time) | NIT | deferred |

## Deferred

DEFER items from the final verdicts and ledger (acknowledged follow-up candidates):

- Ф2-F1-D1: PID reuse not handled: stale running record after reboot — isAlive treats EPERM as alive (workspace guard blocks forever), reaper SIGKILLs -childPid group, cancel SIGTERMs reused runnerPid; cheap fix:...
- Ф2-F1-D2: classifier haystack = whole stderr tail + stdout, not just the final Error line; tool/progress noise on stderr can misclassify (covered by accepted risk R5)
- Ф2-F1-D3: CLI process group not killed after normal exit (yolo background processes survive the job, :366); Ctrl-C on doctor --probe orphans the detached probe CLI
- Ф2-F4-D1: plan sync edited Ф3 cancel/Refusals rows to match as-built cmdCancel; resolves Ф2-F2-N6 (informational)

## Nits (informational)

Opus NITS recorded in the ledger (no action required; status deferred):

- Ф2-F1-N1: ZCODE_TASK_TIMEOUT_MIN > 35791 overflows setTimeout → instant failed/timeout
- Ф2-F1-N2: per-chunk utf8 decoding can split multibyte chars in response/log; use setEncoding('utf8')
- Ф2-F1-N3: resolveResume duplicates requireJob's first three lines (plan-verbatim)
- Ф2-F1-N4: Step 8 constants block lost trailing comments; USAGE_FIELDS/PATTERNS compact JSON formatting
- Ф2-F1-N5: test 2 records stub cwd but never asserts it equals repo root (C5)
- Ф2-F1-N6: allocateRecord ignores orphan .json.terminal files → id reuse shadowed by stale terminal
- Ф2-F1-N7: shim word-splits glob/ls on HOME with spaces (same as codex-dispatch)
- Ф2-F1-N8: several C1 guard paths untested (invalid timeout, missing ZCODE_BIN/provider config, resume cancelled/session-less, non-zt id, whitespace prompt)
- Ф2-F2-N1: job id computed before the reservation (nextJobId :633 then acquireReservation :634) and the allocateRecord EEXIST retry removed (:209-223): during a stale-lock reclaim a competitor can take the same ...
- Ф2-F2-N2: updateReservation rewrites the lock in place (ftruncate+write); SIGKILL between them leaves an empty active.lock read as held forever (:304-328, :347-348) — treat old unparsable lock as stale
- Ф2-F2-N3: stale-lock reclaim read-then-unlink not atomic (:367-373); covered in practice by claimRunnerReservation + running-record check → escalated by codex-control round 2 to F2-B1-Ф2
- Ф2-F2-N4: concurrent-tasks test is timing-dependent; deterministic variant: pre-create active.lock with live holder pid and non-running jobId, assert exit 2
- Ф2-F2-N5: stale-lock reclaim SIGKILLs previous.childPid group even when the record is terminal (:360-365) — PID-reuse path, same family as Ф2-F1-D1
- Ф2-F2-N6: plan Ф3 zcode-invocation verb table still says cancel '…SIGKILL, stops the runner' (plan:2626); as built cancel no longer signals the runner
- Ф2-F3-N1: dead reclaim-marker recovery is itself read-check-unlink (:354-360): two reclaimers can both enter the critical section under triple preconditions; harden later via atomic rename-claim + token check o...
- Ф2-F3-N2: acquireReclaimMarker waits on a live marker holder with no deadline (:350-353); PID reuse/EPERM → task loops forever instead of exit 2 (same family as Ф2-F1-D1)
- Ф2-F3-N3: plan text not updated for F2-B1: Non-goals (:60), C3 (:182), R7 (:269) mention only the reservation file; as built there is also active.lock.reclaim
- Ф2-F3-N4: staleToken written into the marker but never read; createReservation/releaseReservation names only describe the reservation (cosmetic)
- Ф2-F4-N1: narrow transfer race on a task SIGKILLed between spawn and updateReservation with 3-way interleaving; mitigated by onSpawn SIGTERM; hardening: runner checks its generation is still highest before spaw...
- Ф2-F4-N2: updateRunning throw in onSpawn (ENOSPC/EACCES) → runJob finally releases the reservation while the detached CLI runs, childPid unrecorded
- Ф2-F4-N3: early cancel before onSpawn leaves childPid unrecorded; dead-holder reclaim cannot find a SIGTERM-ignoring CLI group (R7 family)
- Ф2-F4-N4: updateReservation rewrites the generation file in place (ftruncate+write, :352) — crash/ENOSPC leaves an empty highest generation → workspace fails closed; temp+rename would fix (same as Ф2-F2-N2)
- Ф2-F4-N5: test dead code: realLink saved/restored but fs.linkSync never patched
- Ф2-F4-N6: misleading test label '…the loser cannot affect it through cancel'
- Ф2-F4-N7: plan Step 6 runtime says ~20 s; observed ~33 s
- Ф2-F5-N1: test 'release-stale finalizes a dead-holder job…' passes via the status reaper even without release-stale's finalize; assert note == 'stale reservation released' or read .terminal before status
- Ф2-F5-N2: release-stale's CLI-process-group-alive refusal (:419-422) has no test
- Ф2-F5-N3: in-place updateReservation (ftruncate+write, :373) → unparsable highest generation permanently refused by task and release-stale; runner's one-shot reservationFileForToken read can hit the truncate wi...
- Ф2-F5-N4: C1 says no other task refusal contains 'release-stale' — refusals echoing user input (prompt path :658, cwd :98, parseArgs :644) can; a fixed sentinel prefix would make the Ф3 match exact (Ф3 concern)
- Ф2-F5-N5: plan C2 note values omit 'stale reservation released'
- Ф2-F5-N6: test 7 label omits its new release-stale assertion
- Ф2-F5-N7: job can be terminal a moment before the runner writes .released; an immediate next task can get the guard refusal (back-to-back tests rely on node startup time)

## Open at accept

None — outcome was clean.
