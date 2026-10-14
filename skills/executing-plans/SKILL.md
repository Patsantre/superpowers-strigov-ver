---
name: executing-plans
description: Use ONLY for legacy upstream-style plans — plain markdown without YAML frontmatter, flat Task 1..N structure (no phases). For phased plans with YAML frontmatter (Ф1, Ф2, …), use dev-orchestrator instead (`/dev`; manual-only) — it honors phase boundaries, auto-commits per phase, and routes BE/FE phases to the right implementer.
disable-model-invocation: true
---

# Executing Plans

> **Manual-only pipeline skill (superpowers-strigov-ver).** It starts only from the user (`/dev`, `/superpowers-strigov-ver:<skill>`), from another skill of this plugin, or when resuming an in-progress plan — never on your own initiative. The Skill tool refuses it by design, so this plugin's pipeline skills are loaded with `Read`, never through the Skill tool. This file: `${CLAUDE_SKILL_DIR}/SKILL.md` (if the variable shows unexpanded, it is the path you just read). Another skill named below (`writing-plans`, `codex-invocation`, `zcode-invocation`, `dev-orchestrator`, …) is `../<name>/SKILL.md` relative to this skill's directory — `Read` it there. After a context compaction, re-`Read` this file before your next step.

## Overview

Load plan, review critically, execute all tasks, report when complete.

**Announce at start:** "I'm using the executing-plans skill to implement this plan."

**Scope (this fork):** This skill is for **legacy upstream-style plans** — plain markdown without YAML frontmatter, flat `Task 1..N` structure (no phases). Plans produced by this fork's `writing-plans` are phased (YAML frontmatter + `## Ф1`, `## Ф2`, …) and should go through `/dev` or `Read` `../dev-orchestrator/SKILL.md` (manual-only — never through the Skill tool) — it honors phase boundaries, auto-commits per phase, and routes BE/FE phases to the right implementer.

**Note:** Tell your human partner that Superpowers works much better with access to subagents. The quality of its work will be significantly higher if run on a platform with subagent support (such as Claude Code or Codex). If subagents are available, `Read` `../dev-orchestrator/SKILL.md` and follow it (manual-only — never through the Skill tool) instead of this skill.

## The Process

### Step 1: Load and Review Plan
1. Read plan file
2. Review critically - identify any questions or concerns about the plan
3. If concerns: Raise them with your human partner before starting
4. If no concerns: Create TodoWrite and proceed

### Step 2: Execute Tasks

For each task:
1. Mark as in_progress
2. Follow each step exactly (plan has bite-sized steps)
3. Run verifications as specified
4. Mark as completed

### Step 3: Complete Development

After all tasks complete and verified:
- Announce: "I'm moving to the finishing-a-development-branch step to complete this work."
- **REQUIRED SUB-SKILL:** `Read` `../finishing-a-development-branch/SKILL.md` and follow it (manual-only — never through the Skill tool)
- Follow that skill to verify tests, present options, execute choice

## When to Stop and Ask for Help

**STOP executing immediately when:**
- Hit a blocker (missing dependency, test fails, instruction unclear)
- Plan has critical gaps preventing starting
- You don't understand an instruction
- Verification fails repeatedly

**Ask for clarification rather than guessing.**

## When to Revisit Earlier Steps

**Return to Review (Step 1) when:**
- Partner updates the plan based on your feedback
- Fundamental approach needs rethinking

**Don't force through blockers** - stop and ask.

## Remember
- Review plan critically first
- Follow plan steps exactly
- Don't skip verifications
- Reference skills when plan says to
- Stop when blocked, don't guess
- Never start implementation on main/master branch without explicit user consent

## Integration

**Required workflow skills:**
- **using-git-worktrees** - REQUIRED: Set up isolated workspace before starting
- **finishing-a-development-branch** - Complete development after all tasks

**Note on plan source.** In this fork `writing-plans` produces phased plans for `dev-orchestrator`, not for this skill. Plans handled here come from upstream `superpowers` (where the upstream `writing-plans` produces flat Task 1..N), from external imports, or from pre-fork files.
