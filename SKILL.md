---
name: sprint
description: "Launch unattended work sprints with autonomous goal tracking, iterative worker spawning, stall detection, and synthesis. Use when you want focused deep work on a concrete topic with automated progress tracking and iteration management. NOT for open-ended exploration, work requiring frequent human decisions, or externally-facing actions (deployments, emails, posts)."
license: MIT
metadata:
  author: "jeremyknows"
  version: "0.2.0"
  status: "P0-scaffolding"
  category: "Automation"
  phase: "P0"
  requires_review: true
  supervised_only: true
---

# Sprint Skill

**Version:** 0.2.0 | **Status:** P0 Scaffolding (supervised only) | **Category:** Automation

## What This Skill Does

The Sprint Skill is a **self-driving automation framework** for running unattended work sessions. You provide a topic, goals, and a duration. The skill spawns autonomous workers across multiple iterations, detects stalls, tracks progress, and synthesizes final results—all hands-off.

It's designed for overnight deep work or focused research: set it up, walk away, come back to complete output and a synthesis report.

---

## When to Use This Skill

Use Sprint when you need:
- **Focused, iterative work** on a concrete, self-contained topic (research, analysis, documentation, design exploration)
- **Autonomous execution** without constant human intervention
- **Multiple iterations** with automated stall detection and recovery
- **Clear outcome tracking** with a final synthesis report
- **Structured goal management** with mutation capability mid-sprint

**Not for:**
- Open-ended exploration or rambling research
- Work requiring frequent human decision-making
- Destructive or externally-facing actions (deployments, posts, emails)
- Topics requiring extensive context or domain expertise not readily available

---

## Quickstart

### Basic Invocation

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/sprint-init.sh \
  --topic "Research React 19 performance patterns" \
  --duration "4h"
```

This creates a new sprint with:
- Auto-generated sprint ID
- 4-hour work window
- Default autonomy level (`medium`)
- Auto-created Discord thread for progress updates

### With Full Options

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/sprint-init.sh \
  --topic "Implement user authentication audit logging" \
  --duration "6h" \
  --autonomy-level "high" \
  --goals goals.json \
  --thread-id "1234567890"
```

---

## How It Works

### The Sprint Lifecycle

1. **Initialization (sprint-init.sh)**
   - Validates topic (concrete, self-contained, achievable in stated duration)
   - Generates sprint ID and creates directory structure
   - Registers sprint in state tracking
   - Creates Discord thread for iteration updates
   - Emits `sprint_started` event to bus

2. **Direction (sprint-director.sh, cron-driven)**
   - Runs every 20–30 minutes during sprint window
   - Acquires lock on state.json (flock protocol, 30s timeout)
   - Checks idempotency: if status is `worker_spawned`, exits (prevents duplicate work)
   - Sets status to `worker_spawned` and spawns a worker subagent
   - Waits 10 minutes for worker to produce `iter-N.md`
   - On completion: updates state, emits progress to bus, posts to Discord thread
   - **Stall detection:** If worker doesn't produce output in 610 seconds, increments stall counter

3. **Synthesis (sprint-synthesize.sh)**
   - Called when sprint window expires or manually triggered
   - Reads all `iter-N.md` files
   - Sets status to `synthesizing`
   - Emits `sprint_synthesis_requested` event
   - Writes telemetry to `data/sprint-runs.jsonl`
   - Generates final `SPRINT-REPORT.md`
   - Sets final status to `complete`

### State Management

The **state.json** file is the single source of truth:
```json
{
  "sprintId": "sprint-20260318-auth-audit",
  "status": "active|worker_spawned|synthesizing|complete",
  "autonomyLevel": "low|medium|high",
  "iterationCount": 3,
  "consecutiveStalls": 0,
  "totalStalls": 2,
  "startedAt": "ISO 8601 timestamp",
  "endsAt": "ISO 8601 timestamp",
  "completedGoals": ["G1", "G3"],
  "mutations": [{ "proposedBy": "director", "oldGoal": "G2", "newGoal": "..." }]
}
```

The director uses flock protocol to serialize access. Each iteration cycle:
1. Acquires lock (30s timeout)
2. Reads current state
3. Makes decisions (spawn worker? detect stall? escalate?)
4. Writes updated state
5. Releases lock

---

## Parameter Reference

### sprint-init.sh

```bash
--topic <string>              # Sprint topic (required, ≤200 chars, must be concrete)
--duration <string>           # Duration: "2h", "30m", "4h", "overnight" (required)
--autonomy-level <string>     # "low" | "medium" (default) | "high"
--goals <path>                # Path to goals.json (optional, defaults to placeholder)
--thread-id <id>              # Discord thread ID to use (optional, creates new if omitted)
--dry-run                      # Validate without creating sprint
```

### sprint-director.sh

Normally invoked by cron; can be run manually for testing:

```bash
--sprint-id <id>              # Sprint ID (required)
--force-synthesis             # Skip to synthesis phase immediately
--check-only                  # Report status without modifying state
```

### sprint-synthesize.sh

```bash
--sprint-id <id>              # Sprint ID (required)
--manual                      # Override timing checks, synthesize immediately
--archive                     # Move sprint to archive/ after synthesis
```

---

## Example Invocations

### Example 1: Research Sprint (2 Hours)

**Scenario:** You want to research emerging patterns in authentication for a product review meeting.

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/sprint-init.sh \
  --topic "Research OAuth 2.1 + passkey hybrid patterns for VeeFriends login" \
  --duration "2h" \
  --autonomy-level "medium"
```

**What happens:**
- Sprint ID: `sprint-20260318-oauth-passkey`
- Worker 1 (0–30 min): Searches for current OAuth 2.1 best practices, passkey adoption patterns, hybrid auth flows
- Worker 2 (30–60 min): Analyzes implementation options for VeeFriends' stack, security tradeoffs
- Worker 3 (60–90 min): Synthesizes findings into decision matrix with recommendations
- Final synthesis: Generates `SPRINT-REPORT.md` with executive summary, analysis, and next steps

---

### Example 2: Feature Implementation Sprint (6 Hours)

**Scenario:** You're implementing a feature (e.g., API rate limiting) and want autonomous iteration with mutation support.

```bash
cat > /tmp/goals.json << 'EOF'
{
  "meta_goal": "Implement Redis-backed API rate limiting for VeeFriends API",
  "goals": [
    {
      "id": "G1",
      "title": "Design rate limiting schema and Redis data structures",
      "status": "pending"
    },
    {
      "id": "G2",
      "title": "Implement core rate limiter middleware with per-endpoint config",
      "status": "pending"
    },
    {
      "id": "G3",
      "title": "Add monitoring, metrics, and dashboard integration",
      "status": "pending"
    },
    {
      "id": "G4",
      "title": "Write integration tests and deployment plan",
      "status": "pending"
    }
  ]
}
EOF

bash ${CLAUDE_SKILL_DIR}/scripts/sprint-init.sh \
  --topic "Implement Redis-backed API rate limiting with monitoring" \
  --duration "6h" \
  --autonomy-level "high" \
  --goals /tmp/goals.json
```

**What happens:**
- Sprint ID: `sprint-20260318-rate-limit`
- **Iteration 1:** Worker designs schema, creates Redis keys, proposes data structures
- **Iteration 2:** Director detects mutation opportunity ("Add performance caching layer?"), posts to Discord thread for operator ACK
- **Iteration 3:** Worker implements core middleware and per-endpoint config
- **Iteration 4:** Worker adds monitoring and metrics integration
- **Iteration 5:** Synthesis phase collects all iterations, validates goal completion
- Final output: `SPRINT-REPORT.md` with architecture, code snippets, test suite, and deployment checklist

---

## Autonomy Levels

The `autonomyLevel` field controls worker behavior and decision-making:

| Level | Worker Can | Worker Cannot | Use When |
|-------|-----------|---------------|----------|
| **low** | Read, research, analyze, propose changes | Make decisions without asking, commit code, send messages | You want careful exploration; you'll review before acting |
| **medium** | Read, research, analyze, implement, commit (non-prod) | Deploy, send external messages, make prod changes | Standard: balanced autonomy with safety gate on externals |
| **high** | All of the above | Deploy to prod without final approval | Research-only or fully tested code; use after supervised success |

See **GUIDE.md** for detailed autonomy behavior.

---

## Monitoring a Sprint

### Quick Status Check

```bash
cat ~/.openclaw/data/sprints/<sprint-id>/state.json | jq '.'
```

Shows:
- Current status (`active`, `worker_spawned`, `synthesizing`, `complete`)
- Iteration count
- Stall counter
- Completed goals
- Mutations pending operator ACK

### Read Iteration Results

```bash
cat ~/.openclaw/data/sprints/<sprint-id>/iter-N.md
```

Each iteration file contains:
- `## Summary` — What the worker did this iteration
- `## Artifacts` — Files created, code written, analysis performed
- `## Next` — Recommended next steps

### Watch Progress in Discord

The sprint automatically creates a Discord thread in `#watson-main` with:
- Iteration updates (posted after each worker completes)
- Mutation proposals (if autonomy level supports it)
- Stall escalations (if 3+ consecutive stalls detected)
- Final synthesis summary

---

## File Structure

```
~/.openclaw/
  data/
    sprints/
      <sprint-id>/
        state.json                # Live state (status, goals, mutations)
        goals.json                # Initial goals
        iter-1.md, iter-2.md...   # Worker iteration outputs
        director.log              # Director runs + state changes
        SPRINT-REPORT.md          # Final synthesis (created on completion)
```

---

## Key Constraints

1. **Topic must be concrete.** "Research security" ✗ | "Research OAuth 2.1 hybrid auth patterns" ✓
2. **Duration must be achievable.** "Overnight" is OK if topic is focused. "Implement a full API server" requires multiple days.
3. **Autonomy is progressive.** First sprint: `low`. After proving safe: `medium`. After 2 successful `medium` sprints: `high` (overnight).
4. **No external destructive actions** without explicit operator confirmation (even at `high` autonomy level for emails, tweets, prod deploys).
5. **Goal mutations require operator ACK.** If director proposes goal changes mid-sprint, they're added to `mutations[]` and need Discord reaction approval before acting.

---

## Known Limitations & Gotchas

1. **P0 scaffolding — not yet production-validated.** Run with `supervised_only: true` until at least 1 successful end-to-end sprint completes. Do not run overnight unsupervised yet.
2. **flock is macOS/Linux only.** If you're on a system without GNU flock, the director's lock protocol silently fails — concurrent director runs can corrupt state.json.
3. **Worker timeout is hard-coded at 610s.** If your topic requires long research chains (fetching many URLs, large codebases), workers will stall. Start with `--autonomy-level low` and small scopes.
4. **state.json corruption kills the sprint.** There's no automatic backup — if a director run crashes mid-write, state.json can be left in a broken state. Recovery is manual (see TROUBLESHOOTING.md § State File).
5. **Goal mutations require human ACK via Discord reaction.** If you're away from Discord, mutations queue and the sprint stalls waiting. For overnight sprints: pre-define goals.json fully or set autonomy to `high` to allow auto-mutation.
6. **Synthesis requires at least 1 iter-N.md.** If all workers time out and no iterations complete, synthesis produces an empty report. The sprint is not retried automatically.
7. **Sprint data lives in data/sprints/ indefinitely.** No auto-archiving or TTL. Archive manually after reviewing SPRINT-REPORT.md, or disk fills slowly.
8. **No cost ceiling.** A 6-hour high-autonomy sprint can spawn many subagents. Each spawns an LLM session. Uncapped cost risk on long sprints — monitor actively.

---

## Dependencies

- `sessions_spawn` — Worker subagent dispatch (required — Sprint will not function without it)
- `flock` (macOS/Linux) — Director lock protocol; install via `brew install util-linux` or verify availability with `which flock`
- `jq` — State JSON parsing in all 3 scripts; install via `brew install jq`
- `bash ~/.openclaw/scripts/emit-event.sh` — Bus event emission on sprint lifecycle events
- `bash ~/.openclaw/scripts/sub-agent-complete.sh` — Worker completion signal
- Discord channel access — Sprint init creates a thread in `#watson-main`; requires Discord plugin configured

---

## Failure Modes & Recovery

Quick reference — see `docs/TROUBLESHOOTING.md` for full step-by-step procedures:

| Symptom | Likely cause | Quick fix |
|---------|-------------|-----------|
| Stuck in `worker_spawned` >15 min | Worker crashed / timeout | Re-run `sprint-director.sh --sprint-id <id>` |
| No `iter-1.md` after init | Director cron not registered | Run director manually once |
| `flock: acquire timeout` | Stale lock file | `rm -f data/sprints/<id>/.*.lock` |
| `consecutiveStalls` rising | Worker systemic timeout | Reduce scope or trigger `--force-synthesis` |
| Synthesis produces empty report | No iter files found | Check `director.log` — director may never have run |
| state.json invalid JSON | Crash mid-write | Restore from `.bak` or edit manually |

---

## Autoresearch

**Status:** P0 scaffolding — not yet production-validated. Run at least 1 supervised sprint before scoring.

**Baseline score:** Not yet established (requires production run).

**Sprint quality scorecard** (use after each sprint to score output quality):

| # | Question | Y/N |
|---|----------|-----|
| 1 | Did the sprint complete at least 50% of stated goals? | |
| 2 | Did synthesis produce a usable SPRINT-REPORT.md? | |
| 3 | Were there ≤2 consecutive stalls in any 2-hour window? | |
| 4 | Did worker outputs have all 3 required sections (Summary/Artifacts/Next)? | |
| 5 | Did the sprint stay within its autonomy-level constraints? | |
| 6 | Was the final report useful without manual cleanup? | |

Score ≥5/6 = healthy. Score ≤3/6 = tune the worker prompt or tighten the topic scope.

**Mutation candidates** (improve after first production run):
1. Add `--budget-usd` ceiling to sprint-init.sh — cap max LLM spend per sprint
2. Add automatic state.json backup before every director write — prevent corruption loss
3. Add `iter-N.md` format validation in director before marking iteration complete

**Improvement log:**

| Version | Date | Change | Score |
|---------|------|--------|-------|
| 0.2.0 | 2026-03-18 | Added Dependencies, Gotchas, Autoresearch section | N/A (pre-run) |

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 0.2.0 | 2026-03-18 | Added Dependencies, Known Limitations & Gotchas, Autoresearch section; health score 8/14 |
| 0.1.0 | Mar 2026 | P0 scaffolding: init, director, synthesize scripts; basic state management; flock protocol |

---

## References

- **User Guide:** `skills/sprint/docs/GUIDE.md` — goals.json schema, autonomy levels, monitoring
- **Troubleshooting:** `skills/sprint/docs/TROUBLESHOOTING.md` — failure modes and recovery
- **Runbook:** `skills/sprint/scripts/sprint-runbook.md` — detailed procedures
- **Development Plan:** `plans/sprint-skill-v0.6.md`
