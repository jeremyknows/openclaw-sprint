# Sprint Skill 🏃

**Autonomous deep-work sessions for OpenClaw.** Set a topic, a duration, and walk away. Sprint spawns workers iteratively, detects stalls, tracks goals, and delivers a final synthesis report — all hands-off.

> ⚠️ **Status: P0 Scaffolding.** Run supervised until you've completed at least one successful end-to-end sprint. Not ready for unsupervised overnight use yet.

---

## What It Does

- **Iterative worker spawning** — Director runs every 20–30 min, spawns a worker subagent, waits for output
- **Goal tracking** — Define goals upfront via `goals.json`; Sprint tracks completion across iterations
- **Stall detection** — If a worker doesn't produce output in 610s, stall counter increments; 3 consecutive stalls triggers escalation
- **Mutation support** — Director can propose goal changes mid-sprint; mutations queue for operator ACK before acting
- **Synthesis** — When the sprint window closes, synthesis script reads all `iter-N.md` files and produces a `SPRINT-REPORT.md`
- **Discord thread** — Sprint auto-creates a thread for live progress updates

---

## Install

```bash
# OpenClaw
git clone https://github.com/jeremyknows/openclaw-sprint ~/.openclaw/skills/sprint
```

---

## Setup

**Requirements:**
- OpenClaw runtime with `sessions_spawn` support
- `flock` — director lock protocol (`brew install util-linux` on macOS)
- `jq` — state JSON parsing (`brew install jq`)
- Discord plugin configured (for thread creation + iteration updates)

**Verify:**
```bash
which flock && echo "✅ flock" || echo "❌ missing — brew install util-linux"
which jq && echo "✅ jq" || echo "❌ missing — brew install jq"
```

---

## Usage

### Natural language

```
Run a 2-hour sprint on: research OAuth 2.1 hybrid auth patterns for VeeFriends
Sprint on implementing Redis rate limiting — 4 hours, high autonomy
Start a sprint: analyze our top 10 Discord messages from last week
```

### CLI

```bash
# Basic sprint
bash ${CLAUDE_SKILL_DIR}/scripts/sprint-init.sh \
  --topic "Research React 19 performance patterns" \
  --duration "2h"

# With goals file and autonomy level
bash ${CLAUDE_SKILL_DIR}/scripts/sprint-init.sh \
  --topic "Implement Redis-backed API rate limiting" \
  --duration "6h" \
  --autonomy-level "high" \
  --goals /path/to/goals.json
```

---

## Commands

| Script | Usage |
|--------|-------|
| `sprint-init.sh --topic <text> --duration <time>` | Initialize a new sprint |
| `sprint-director.sh --sprint-id <id>` | Run director manually (normally cron-driven) |
| `sprint-director.sh --sprint-id <id> --force-synthesis` | Skip to synthesis immediately |
| `sprint-director.sh --sprint-id <id> --check-only` | Status check without modifying state |
| `sprint-synthesize.sh --sprint-id <id> --manual` | Trigger synthesis manually |

---

## Autonomy Levels

| Level | Worker can | Worker cannot | Use when |
|-------|-----------|---------------|----------|
| `low` | Read, research, analyze, propose | Make decisions, commit, send messages | First sprint — review before acting |
| `medium` | Read, research, analyze, implement, commit (non-prod) | Deploy, send external messages | Standard — safety gate on externals |
| `high` | All of the above | Deploy to prod without final approval | Proven topic after successful medium sprints |

Start at `low`. Promote after 1 successful sprint at each level.

---

## Monitoring

```bash
# Quick status
cat ~/.openclaw/data/sprints/<sprint-id>/state.json | jq '{status, iterationCount, consecutiveStalls}'

# Read latest iteration
cat ~/.openclaw/data/sprints/<sprint-id>/iter-$(ls ~/.openclaw/data/sprints/<sprint-id>/iter-*.md | wc -l | tr -d ' ').md

# Watch director log
tail -f ~/.openclaw/data/sprints/<sprint-id>/director.log
```

---

## File Structure

```
~/.openclaw/
  data/
    sprints/
      <sprint-id>/
        state.json          # Live state (status, goals, stalls, mutations)
        goals.json          # Initial goals
        iter-1.md, ...      # Worker outputs per iteration
        director.log        # Director run history
        SPRINT-REPORT.md    # Final synthesis (on completion)

skills/sprint/
  SKILL.md
  scripts/
    sprint-init.sh          # Initialize sprint
    sprint-director.sh      # Cron-driven iteration controller
    sprint-synthesize.sh    # Final report generation
    sprint-worker-prompt.md # Worker subagent prompt template
    sprint-runbook.md       # Detailed operational procedures
  docs/
    GUIDE.md                # Goals schema, autonomy details, monitoring
    TROUBLESHOOTING.md      # Failure modes and recovery procedures
```

---

## Limitations

- **P0 scaffolding** — Not production-validated. Run supervised only.
- **flock required** — Lock protocol silently fails without it; concurrent directors corrupt state.json
- **No cost ceiling** — Long high-autonomy sprints can spawn many subagents. Monitor actively.
- **610s worker timeout** — Hard-coded. Long research tasks (many URLs, large codebases) will stall.
- **Manual archiving** — Sprint data accumulates in `data/sprints/` indefinitely. Archive manually.
- **Synthesis needs ≥1 iter** — If all workers time out, synthesis produces an empty report.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Stuck in `worker_spawned` >15 min | Worker crashed | Re-run `sprint-director.sh --sprint-id <id>` |
| No `iter-1.md` after init | Director cron not registered | Run director manually once |
| `flock: acquire timeout` | Stale lock file | `rm -f ~/.openclaw/data/sprints/<id>/.*.lock` |
| `consecutiveStalls` rising | Worker systemic timeout | Reduce scope or `--force-synthesis` |
| Synthesis empty report | No iter files | Check `director.log` — director may not have run |

Full procedures: `docs/TROUBLESHOOTING.md`

---

## Related Skills

| Skill | When to use |
|-------|-------------|
| `build-feature` | Guided 7-phase feature development with human checkpoints |
| `coding-agent` | Single focused coding task delegation |
| `skill-doctor` | Audit and improve this skill after production runs |

---

*v0.2.0 · MIT · jeremyknows*
