# Sprint Runbook — Failure Recovery Guide (P0)

**Version:** 0.1.0 | **Date:** 2026-03-18

This runbook covers common failure modes for the Sprint Skill (P0). Each mode includes diagnosis, root cause, and recovery procedure.

---

## Failure Mode 1: Director Keeps Firing After Completion

**Symptom:** `sprint-director.sh` continues running even after `sprint-synthesize.sh` has completed and set status to `complete`.

**Root Cause:** Cron job registered but cleanup event (`cron_delete_request`) was not processed, or cron delete failed.

**Diagnosis:**
```bash
# Check state.json status
jq '.status' ~/.openclaw/agents/main/workspace/data/sprints/sprint-*/state.json

# Check if status is "complete" but cron is still firing
grep "sprint-director_iteration" ~/.openclaw/events/bus.jsonl | tail -5

# Check cron job exists
openclaw cron list | grep sprint
```

**Recovery:**
1. If status is `complete`: manually delete cron job with `openclaw cron delete <jobId>`
2. Verify deletion: `openclaw cron list | grep -c sprint` should return 0
3. Check synthesis actually ran: `ls ~/.openclaw/agents/main/workspace/data/sprints/<id>/SPRINT-REPORT.md`

**Permanent Fix (P1):** Synthesis emits `cron_delete_request` to bus. Main agent's heartbeat reads event and deletes job.

---

## Failure Mode 2: state.json Has status=worker_spawned for >20 Minutes

**Symptom:** State file shows `"status": "worker_spawned"` but hasn't changed in >20 minutes. Director doesn't proceed to next iteration.

**Root Cause:** 
- Worker crashed without writing `iter-N.md`
- Worker is still running but hung (not producing output)
- Lock file is stale and director is waiting on it

**Diagnosis:**
```bash
# Check state.json
jq '.status, .lastIterationAt' ~/.openclaw/agents/main/workspace/data/sprints/<id>/state.json

# Check lock file exists and is old
ls -la ~/.openclaw/agents/main/workspace/data/sprints/<id>/.state.lock

# Check if iter-N.md exists
ls -la ~/.openclaw/agents/main/workspace/data/sprints/<id>/iter-*.md

# Check for orphan processes
ps aux | grep -i sprint
```

**Recovery:**
1. If lock file is stale (older than 20 min): `rm ~/.openclaw/agents/main/workspace/data/sprints/<id>/.state.lock`
2. Manually set status back to `active`: `jq '.status = "active"' state.json > state.json.tmp && mv state.json.tmp state.json`
3. Next director run should proceed
4. If orphan worker process exists: `kill -9 <PID>`

**Prevention (P1):** Director implements a 10-minute timeout on lock acquisition and auto-releases stale locks.

---

## Failure Mode 3: Synthesis Never Runs

**Symptom:** Sprint duration has passed (endsAt reached) but sprint is still in `active` status. `SPRINT-REPORT.md` doesn't exist.

**Root Cause:**
- Director's endsAt check (step 6) didn't trigger synthesis
- Cron job stopped running before endsAt
- Synthesis was called but failed silently

**Diagnosis:**
```bash
# Check state.json
jq '.status, .endsAt, .completedAt' ~/.openclaw/agents/main/workspace/data/sprints/<id>/state.json

# Check if synthesis.log exists
cat ~/.openclaw/agents/main/workspace/data/sprints/<id>/synthesis.log

# Check bus for synthesis event
grep "sprint_synthesis_requested" ~/.openclaw/events/bus.jsonl | grep <sprint-id>
```

**Recovery:**
1. Manually trigger synthesis: `bash ~/.openclaw/agents/main/workspace/skills/sprint/scripts/sprint-synthesize.sh --sprint-id <id>`
2. Verify SPRINT-REPORT.md was created: `ls -la ~/.openclaw/agents/main/workspace/data/sprints/<id>/SPRINT-REPORT.md`
3. Check telemetry was logged: `tail -1 ~/.openclaw/agents/main/workspace/data/sprints/sprint-runs.jsonl`

**Prevention (P1):** Main agent's heartbeat monitors active sprints and triggers synthesis if endsAt is reached.

---

## Failure Mode 4: status=synthesis_failed (Synthesis Crashed)

**Symptom:** State shows `"status": "synthesis_failed"`. SPRINT-REPORT.md is empty or malformed.

**Root Cause:**
- Corruption in one or more iter-N.md files
- Disk full or permission error writing SPRINT-REPORT.md
- Unexpected jq error in synthesize.sh

**Diagnosis:**
```bash
# Check state.json
jq '.status' ~/.openclaw/agents/main/workspace/data/sprints/<id>/state.json

# Check synthesis.log for error
tail -20 ~/.openclaw/agents/main/workspace/data/sprints/<id>/synthesis.log

# Validate all iter files
for f in ~/.openclaw/agents/main/workspace/data/sprints/<id>/iter-*.md; do
  echo "=== $f ===" && head -5 "$f"
done

# Check disk space
df -h ~/.openclaw/agents/main/workspace/
```

**Recovery:**
1. Inspect iter-N.md files for corruption (missing headers, malformed JSON, etc.)
2. If a file is corrupt, manually repair or delete it
3. Re-run synthesis: `bash ~/.openclaw/agents/main/workspace/skills/sprint/scripts/sprint-synthesize.sh --sprint-id <id>`
4. Check SPRINT-REPORT.md was created

**Prevention (P1):** Worker validates output before writing. Synthesis includes error handlers with detailed logging.

---

## Failure Mode 5: Stale Lock File (.state.lock)

**Symptom:** Director fails with "Lock timeout on .../.state.lock". No progress despite repeated director runs.

**Root Cause:** Process holding lock died without cleanup. Lock file persists indefinitely.

**Diagnosis:**
```bash
# Find stale lock files
find ~/.openclaw/agents/main/workspace/data/sprints -name ".state.lock" -type d

# Check when it was created
stat ~/.openclaw/agents/main/workspace/data/sprints/<id>/.state.lock

# Check if any process is actively using it
lsof ~/.openclaw/agents/main/workspace/data/sprints/<id>/.state.lock 2>/dev/null || echo "No active locks"
```

**Recovery:**
1. Remove stale lock: `rmdir ~/.openclaw/agents/main/workspace/data/sprints/<id>/.state.lock`
2. Verify removal: `ls ~/.openclaw/agents/main/workspace/data/sprints/<id>/.state.lock` should fail
3. Next director run should proceed

**Prevention (P1):** Use PID-based lock files with cleanup on process exit. Implement lock timeout with auto-release.

---

## Failure Mode 6: active-threads.json Has Stale Sprint Entry

**Symptom:** `config/active-threads.json` lists a completed sprint with `"status": "active"` or missing `sprint_complete` marker. Retire-thread.sh skips it.

**Root Cause:** Synthesis didn't update active-threads.json, or update failed silently.

**Diagnosis:**
```bash
# Check active-threads.json
jq '.[] | select(.sprint_id | contains("sprint-"))' ~/.openclaw/agents/main/workspace/config/active-threads.json

# Check if SPRINT-REPORT.md exists (indicates synthesis ran)
ls -la ~/.openclaw/agents/main/workspace/data/sprints/<id>/SPRINT-REPORT.md

# Check sprint state
jq '.status' ~/.openclaw/agents/main/workspace/data/sprints/<id>/state.json
```

**Recovery:**
1. Manually update active-threads.json: set thread's `"status": "sprint_complete"`
2. Then use retire-thread.sh to finalize: `bash ~/.openclaw/agents/main/workspace/scripts/retire-thread.sh --thread-id <id>`
3. Verify: `jq '.[] | select(.sprint_id == "<id>")' ~/.openclaw/agents/main/workspace/config/active-threads.json` should show empty

**Prevention (P1):** Synthesis writes to active-threads.json with flock protection. Verify update before setting synthesis status to `complete`.

---

## Worker Spawn Architecture

**Version:** v0.7 (async emit model) | Added: 2026-03-18

### Overview

The Sprint Director **cannot** call `sessions_spawn` directly — that is a Watson tool available only inside agent sessions. Instead, the director uses a bus-based handoff:

```
Director (bash)
  → emits agent_wake to bus.jsonl
    → agent-wake-consumer cron (every 10 min)
      → posts to sprint Discord thread
        → Watson reads thread, spawns worker subagent manually
          → worker writes iter-N.md
            → Watson sets state.json status back to "active"
              → next director cron fire proceeds to next iteration
```

### What the Director Does (v0.7)

1. Prepares context package at `$SPRINT_PATH/context-N.txt`
2. Sets `status: "worker_spawned"` in state.json
3. Base64-encodes the context file
4. Emits `agent_wake` bus event with:
   - `action: "spawn_worker"`
   - `sprint_id`, `iteration`, `iter_file`, `thread_id`, `topic`
   - `context_b64` (full context, base64-encoded)
5. Exits cleanly (`exit 0`)

### What Watson Does (Manual Step — v0.8 will automate)

When Watson sees an `agent_wake` event in the sprint thread (posted by agent-wake-consumer), or reads the bus directly:

1. Decode context: `base64 -d <<< "$context_b64" > /tmp/sprint-context.txt`
2. Read the context file to understand goals, prior iterations, artifacts
3. Spawn a worker subagent via `sessions_spawn`:
   ```
   runtime: "acp"
   mode: "run"
   task: "<decoded context>"
   runTimeoutSeconds: 1800
   ```
4. Worker writes `iter-N.md` to the sprint path with sections:
   - `## Summary` — what was done
   - `## Artifacts` — files created/modified
   - `## Next` — recommended next iteration focus
5. After `iter-N.md` is confirmed written, reset state:
   ```bash
   jq '.status = "active"' state.json > state.json.tmp && mv state.json.tmp state.json
   ```
6. Next director cron fire (every 20 min) detects `active` status and proceeds

### Why worker_spawned Is an Idempotency Gate

While `status: "worker_spawned"`, subsequent director cron fires exit immediately without emitting a second `agent_wake`. This prevents duplicate worker spawns. Watson must reset to `active` before the next iteration begins.

### agent-wake-consumer Cron

- **Cron ID:** `05013b18-1354-46bb-8eb8-1990cc7fd9fe`
- **Schedule:** every 10 min (8 AM–10 PM ET)
- **What it does:** reads new `agent_wake` events from bus.jsonl, posts to the `thread_id` in the event payload
- **Token used:** `DISCORD_BOT_TOKEN_CLUE_MASTER` (Pulse bot)
- **Must be enabled** — was accidentally disabled and re-enabled 2026-03-18

### v0.8 Automation Plan

In v0.8, a dedicated `sprint-worker-spawn.sh` cron will:
1. Poll bus.jsonl for `agent_wake` events with `action: "spawn_worker"`
2. Decode the context package
3. Call `openclaw agent --agent main --message "spawn_worker: ..."` to trigger Watson
4. Watson's session handles the actual `sessions_spawn` call

This removes the manual step entirely.

---

## Stall Recovery Procedure (Director Escalation)

**When stall counter reaches 3:**
1. Director sets `status: "escalated"`
2. Posts alert to Discord thread + #watson-main with ✅ resume instruction
3. Main agent watches for ✅ reaction on alert message
4. On ✅: main agent sets `stallCount: 0` and `status: "active"` in state.json
5. Next director run proceeds normally

**Manual recovery:**
```bash
# Check current stall count
jq '.stallCount' ~/.openclaw/agents/main/workspace/data/sprints/<id>/state.json

# Reset if needed
jq '.stallCount = 0 | .status = "active"' state.json > state.json.tmp && mv state.json.tmp state.json

# Next director run should proceed
```

---

## Mutation ACK Gate Explanation

**What is a mutation?**
A mutation is a proposal to change a goal during the sprint. Example:
- Original goal: "Research polymarket CLI"
- Mutation: "Expand to include comparison with dYdX API" (goal evolved based on discovery)

**How mutations work:**
1. Worker proposes mutation in `iter-N.md`: `## Mutation Proposal: [...]`
2. Director reads proposal, adds to `mutations[]` with `requires_ack: true, acked: false`
3. Director posts Discord alert with ✅ react instruction
4. Operator reviews and reacts ✅
5. Main agent detects reaction, sets `acked: true` in state.json
6. Next director run checks for pending ACKs — if none, spawns next iteration with mutated goals
7. If operator reacts ❌: mutation is discarded, goal reverts to original

**Why mutations require ACK:**
- Prevents goal drift (topic changing to something unrelated)
- Gives operator visibility into scope changes
- Enables quick pause-and-review if mutation seems wrong

**Manual ACK recovery:**
```bash
# Check pending mutations
jq '.mutations[] | select(.acked == false)' ~/.openclaw/agents/main/workspace/data/sprints/<id>/state.json

# If approved by operator: manually set acked: true
jq '.mutations[0].acked = true' state.json > state.json.tmp && mv state.json.tmp state.json

# Next director run will proceed
```

---

## Quick Reference: Common Commands

```bash
# Check sprint status
jq '.status, .iterationCount, .stallCount' \
  ~/.openclaw/agents/main/workspace/data/sprints/<id>/state.json

# Manual director iteration
bash ~/.openclaw/agents/main/workspace/skills/sprint/scripts/sprint-director.sh \
  --sprint-id <id>

# Manual synthesis
bash ~/.openclaw/agents/main/workspace/skills/sprint/scripts/sprint-synthesize.sh \
  --sprint-id <id>

# Check telemetry
tail -5 ~/.openclaw/agents/main/workspace/data/sprints/sprint-runs.jsonl

# List all active sprints
ls -d ~/.openclaw/agents/main/workspace/data/sprints/sprint-* | \
  xargs -I{} jq -r '.status + ": " + .sprintId' {}/state.json 2>/dev/null

# Check bus events for a sprint
grep '<sprint-id>' ~/.openclaw/events/bus.jsonl | jq '.type' | sort | uniq -c
```

---

## When to Escalate to Main Agent

If any of these occur, post to #watson-main or contact Jeremy directly:

1. Multiple sprints in `synthesis_failed` status simultaneously
2. Corrupt state.json that can't be repaired
3. Loss of entire sprint directory (not in archive)
4. Cron job spawning duplicate workers (director idempotency failing)
5. Any situation requiring code changes to sprint scripts

---

## Contact & Debugging

For detailed logs:
- Director logs: `~/.openclaw/agents/main/workspace/data/sprints/<id>/director.log`
- Synthesis logs: `~/.openclaw/agents/main/workspace/data/sprints/<id>/synthesis.log`
- Bus events: `~/.openclaw/events/bus.jsonl`
- Sprint state: `~/.openclaw/agents/main/workspace/data/sprints/<id>/state.json`

Questions? Post to #watson-main with the sprint ID and relevant log snippets.
