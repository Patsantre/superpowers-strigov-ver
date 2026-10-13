# Review: glm-zcode-implementer — Ф3

- **Date**: 2026-10-14
- **Phase scope**: Protocol: dev-orchestrator SKILL.md + implementer-prompt.md + new zcode-invocation skill + codex-invocation + reviewer prompts
- **Base commit**: 1965798
- **Rounds**: 3 (Opus 4.1 + Codex Astra 4.2 control)
- **Outcome**: CLEAN

## Findings history

| id | reviewer | finding (one line) | decision | final status |
|---|---|---|---|---|
| F1-B1-Ф3 | Opus 4.1 | Pre-dispatch item 10 (`--resume-task zt-…`) contradicts FRESH-dispatch rules; plan-wide operations (final-fix, repair) lack an item 10 definition (plan-mandated; user authorized) | ACCEPTED | fixed |
| F1-N1-Ф3 | Opus 4.1 | Step 5 fixer / integration repairer need the `doctor --probe` step when `glm=unprobed` so item 10's `glm=ok` is reachable | ACCEPTED | fixed |
| F1-N2-Ф3 | Opus 4.1 | `risk_phases` placement within the `Read limit: 30` window unspecified; YAML example misses Ф4 (plan structural-check line updated too) | ACCEPTED | fixed |
| F1-N3-Ф3 | Opus 4.1 | Two unlisted `task` outcomes (exit 1 with no id; exit 2 for prompt above MAX_PROMPT_BYTES) lack mechanical actions | ACCEPTED | fixed |
| F1-N4-Ф3 | Opus 4.1 | Confirmed-resume pre-flight allowances omit `$ZDISPATCH release-stale` / `cancel` | ACCEPTED | fixed |
| F1-N5-Ф3 | Opus 4.1 | Fresh-fallback re-brief case list in implementer-prompt.md :225 differs from the list at :36 | ACCEPTED | fixed |
| F1-N6-Ф3 | Opus 4.1 | zcode-invocation probe usage line does not match wrapper / contract C1 (`input= cached= output=`) | ACCEPTED | fixed |
| F1-D1-Ф3 | Opus 4.1 | Ladder order can move a Sol-escalated phase down to Luna across sessions; .id sidecar restore only after compaction (spec §5.2 order) | DEFER | deferred |
| F1-D2-Ф3 | Opus 4.1 | Implementer report lacks the RED (pre-edit) run of the structural check (process only) | NIT | deferred |
| F2-N1-Ф3 | Opus 4.1 | Item 10 admission parenthetical reads as if "plan file is clean" applies only to plan-wide ops | NIT | deferred |
| F2-N2-Ф3 | Opus 4.1 | Step 3 item 4 probe trigger text omits Step 5 / repair invocations | NIT | deferred |
| F2-N3-Ф3 | Opus 4.1 | Other `task` exit 1 cases (I/O, internal before handoff) have no mechanical rule | NIT | deferred |
| F2-N4-Ф3 | Opus 4.1 | "Any other wrapper exit 2 … fix the dispatch" precedes the stale-reservation block without excluding it; first-match misrouting possible | NIT | deferred |
| F2-N5-Ф3 | Opus 4.1 | Pre-flight allowances permit reading the GLM session marker but not writing it | NIT | deferred |
| F2-N6-Ф3 | Opus 4.1 | implementer-prompt fresh-fallback lists omit the same-channel `--fresh` infrastructure retry (cosmetic) | NIT | deferred |
| F2-N7-Ф3 | Opus 4.1 | Plan as-built note inaccurate on E33 / need line / E29 wording (accuracy only) | NIT | deferred |
| F2-B1-Ф3 | Codex Astra 4.2 control | release-stale refusal → Luna fallback could put two writers in one tree (plan-mandated); user chose autonomous wait-then-continue rule with catch-all escalation (case 6) | ACCEPTED | fixed |
| F3-N1-Ф3 | Opus 4.1 | zcode-invocation release-stale row still says "Single actor: run it once", contradicting the 30 s wait loop | NIT | deferred |
| F3-N2-Ф3 | Opus 4.1 | Plan as-built note F2-B1-Ф3 bullet omits case (6) immediate escalation | NIT | deferred |
| F3-N3-Ф3 | Opus 4.1 | "Luna/Sol fallback allowed only after step 1 or 2…" lacks a blank line, renders as part of list item 6 | NIT | deferred |
| F3-N4-Ф3 | Opus 4.1 | Wait loop should make `status --cwd …` explicit for worktree tracks, else orphan CLIs in tracks are never reaped | NIT | deferred |
| F3-N5-Ф3 | Opus 4.1 | 10-minute wait loop is prose only; add a Monitor snippet with a terminal-only guard | NIT | deferred |
| F3-D1-Ф3 | Codex Astra 4.2 control | `status` reaps orphaned CLI groups only for `running` records; for a terminal record the loop may time out and escalate after 10 min (safe: no-second-writer rule holds) | DEFER | deferred |

## Deferred

- **F1-D1-Ф3** (Opus 4.1): ladder order (kill switch / glm=down before "already handed to Luna/Sol") can move a Sol-escalated phase down to Luna across sessions; implementer restore from .id sidecars only "after compaction". Follows spec §5.2 order; design change deferred.
- **F3-D1-Ф3** (Codex Astra 4.2 control): wait-loop wording — `status` reaps orphaned CLI groups only for `running` records (SKILL.md:415, zcode-dispatch.mjs:460); for a terminal record the loop may time out and escalate after 10 min. Safe because the no-second-writer rule holds.

## Nits (informational)

- F1-D2-Ф3: implementer report lacks the RED (pre-edit) run of the structural check (process only).
- F2-N1-Ф3: say "in both cases the plan file is clean" in item 10's admission parenthetical (SKILL.md:209).
- F2-N2-Ф3: Step 3 item 4 probe trigger text should also mention Step 5 / repair (SKILL.md:348 vs :536, :637).
- F2-N3-Ф3: no mechanical rule for other `task` exit 1 cases (SKILL.md:410; zcode-invocation:153).
- F2-N4-Ф3: "Any other wrapper exit 2" should exclude the stale-reservation message (SKILL.md:410-412).
- F2-N5-Ф3: pre-flight allowances should permit writing the GLM session marker (SKILL.md:67).
- F2-N6-Ф3: add the same-channel `--fresh` infrastructure retry to implementer-prompt fresh-fallback lists.
- F2-N7-Ф3: plan as-built note accuracy (E33 / need line updated; E29 wording vs as-built item 10).
- F3-N1-Ф3: reword the release-stale flag-table row to "never in parallel with any other task/release-stale/cancel for that workspace" (zcode-invocation SKILL.md:116).
- F3-N2-Ф3: plan as-built note F2-B1-Ф3 bullet should mention case (6) immediate escalation (plan :2465).
- F3-N3-Ф3: add a blank line before the "Luna/Sol fallback is allowed only after…" paragraph (SKILL.md:419).
- F3-N4-Ф3: make `"$ZDISPATCH" status --cwd …` explicit for worktree tracks (SKILL.md:415; zcode-invocation:155).
- F3-N5-Ф3: add a Monitor snippet with a terminal-only guard for the 10-minute wait loop (SKILL.md:415; zcode-invocation:155).

## Open at accept

None — outcome was clean.
