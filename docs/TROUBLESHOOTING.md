# Sprint Skill Troubleshooting Guide

This guide covers known failure modes, their causes, and recovery procedures.

**Table of Contents:**
1. [Worker Stuck in worker_spawned State](#worker-stuck-in-worker_spawned-state)
2. [Synthesis Failure](#synthesis-failure)
3. [Stale Lock Files](#stale-lock-files)
4. [Stall Counter Runaway](#stall-counter-runaway)
5. [Sprint Hangs in Active Status](#sprint-hangs-in-active-status)
6. [Director Not Running (Cron Issue)](#director-not-running-cron-issue)
7. [Manual Recovery Procedures](#manual-recovery-procedures)

---

## Worker Stuck in worker_spawned State

### Symptoms

- Sprint has been in `worker_spawned` status for >15 minutes
- No new `iter-N.md` file appears
- Director logs show "TIMEOUT: iter-N.md never received" repeatedly
- Stall counter incrementing

### Root Causes

1. **Worker crashed** — Subagent spawned but failed to initialize or complete
2. **Missing output file** — Worker completed but never wrote `iter-N.md`
3. **Slow worker** — Worker is running but taking longer than 610 seconds
4. **Filesystem permission issue** — Worker can't write to sprint directory
5. **Out of disk space** — Worker can't write output

### Diagnosis

```bash
# Check current state
cat ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/state.json | jq '.status'
# Should show: "worker_spawned"

# Check director log
tail -30 ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/director.log

# Check for partial iter-N.md
ls -lh ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/iter-*.md
# If iter-3.md has 0 bytes, worker created file but didn't write content

# Check directory permissions
ls -ld ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/
# Should show: drwx------ (owned by watson)

# Check disk space
df -h ~/.openclaw/agents/main/workspace/data/sprints/
# Ensure free space > 1 GB
```

### Recovery Procedure

#### Step 1: Validate Filesystem

```bash
# Fix permissions if needed
chmod 700 ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/
chmod 600 ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/state.json
chmod 600 ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/goals.json

# Ensure disk space
df -h ~/.openclaw/agents/main/workspace/
# If <500 MB free, delete old sprints from archive/
```

#### Step 2: Check Worker Logs

```bash
# Subagents write logs to ~/.openclaw/logs/
ls -lh ~/.openclaw/logs/ | grep sprint
tail -100 ~/.openclaw/logs/<latest-sprint-worker>.log
```

**Common worker log errors:**
- `EACCES: permission denied, open '/data/sprints/<id>/iter-N.md'` → Permissions issue (fix Step 1)
- `ENOSPC: no space left on device` → Disk full (clean up old sprints)
- `spawn ENOENT: no such file or directory` → Worker script not found
- `JSON parse error in state.json` → State file corrupted (fix Step 3)

#### Step 3: Validate State File

```bash
jq . ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/state.json
# Should output valid JSON without errors

# If invalid, check for trailing commas or bad escapes:
cat ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/state.json | tail -20
```

**If state.json is corrupted:**

```bash
# Restore from backup (if available)
cp ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/state.json.bak \
   ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/state.json

# Or manually fix JSON
nano ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/state.json
```

#### Step 4: Re-run Worker Manually

```bash
# Get sprint ID
SPRINT_ID=$(ls -t ~/.openclaw/agents/main/workspace/data/sprints/ | head -1)

# Re-run director to re-spawn worker
bash ~/.openclaw/agents/main/workspace/skills/sprint/scripts/sprint-director.sh \
  --sprint-id "$SPRINT_ID"

# Monitor for output
sleep 5
ls -lh ~/.openclaw/agents/main/workspace/data/sprints/$SPRINT_ID/iter-*.md | tail -1

# If new iter file appears, worker recovered
cat ~/.openclaw/agents/main/workspace/data/sprints/$SPRINT_ID/iter-*.md | tail -c 200
```

#### Step 5: If Worker Still Doesn't Produce Output

```bash
# Option A: Check if sprint deadline has passed
cat ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/state.json | jq '.endsAt'
# If current time > endsAt, manually trigger synthesis (see Sprint Hangs in Active Status)

# Option B: Mark iteration as failed and skip
python3 << 'PYEOF'
import json
from datetime import datetime

sprint_id = "<sprint-id>"
state_path = f"~/.openclaw/agents/main/workspace/data/sprints/{sprint_id}/state.json"

with open(state_path, 'r') as f:
    state = json.load(f)

# Increment iteration count
state['iterationCount'] += 1
state['totalStalls'] += 1
state['status'] = 'active'  # Reset to active for next iteration

with open(state_path, 'w') as f:
    json.dump(state, f, indent=2)

print(f"Reset sprint to iteration {state['iterationCount']}")
PYEOF
```

#### Step 6: If Multiple Stalls (>3)

```bash
# Check if sprint should abort
STALLS=$(cat ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/state.json | jq '.totalStalls')

if [ $STALLS -gt 3 ]; then
  echo "Sprint has $STALLS stalls. Recommend manual synthesis."
  bash ~/.openclaw/agents/main/workspace/skills/sprint/scripts/sprint-synthesize.sh \
    --sprint-id "<sprint-id>" \
    --manual
fi
```

---

## Synthesis Failure

### Symptoms

- Sprint time expires but status stays `active` or `synthesizing`
- No `SPRINT-REPORT.md` appears
- `synthesis.log` shows errors
- Synthesis event posted to Discord but never completed

### Root Causes

1. **Malformed iter-N.md files** — Missing required sections (## Summary, ## Artifacts, ## Next)
2. **No iter-N.md files exist** — Director never ran, or all workers failed silently
3. **Synthesis script crashed** — JSON write error, template error, or file permission issue
4. **Incomplete state.json** — Missing required fields, prevents synthesis

### Diagnosis

```bash
SPRINT_ID="<sprint-id>"
SPRINT_DIR=~/.openclaw/agents/main/workspace/data/sprints/$SPRINT_ID

# Check if any iter files exist
ls $SPRINT_DIR/iter-*.md
# If empty, director never ran successfully

# Check synthesis log
cat $SPRINT_DIR/synthesis.log 2>/dev/null || echo "No synthesis.log"

# Validate iter-N.md format
head -20 $SPRINT_DIR/iter-1.md
# Should contain: ## Summary, ## Artifacts, ## Next
```

### Recovery Procedure

#### Step 1: Check for iter Files

```bash
SPRINT_DIR=~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>

# Count iterations
ITER_COUNT=$(ls -1 $SPRINT_DIR/iter-*.md 2>/dev/null | wc -l)
echo "Found $ITER_COUNT iteration files"

if [ $ITER_COUNT -eq 0 ]; then
  echo "No iterations completed. Director may not have run."
  # See "Director Not Running" section below
fi
```

#### Step 2: Validate iter-N.md Format

Each iteration file MUST contain these sections:

```bash
for f in $SPRINT_DIR/iter-*.md; do
  echo "=== Checking $f ==="
  grep -c "## Summary" "$f" || echo "ERROR: Missing ## Summary"
  grep -c "## Artifacts" "$f" || echo "ERROR: Missing ## Artifacts"
  grep -c "## Next" "$f" || echo "ERROR: Missing ## Next"
done
```

**If sections are missing:**

```bash
# Edit the iter file to add missing sections
nano $SPRINT_DIR/iter-3.md
# Add minimal sections:
# ## Summary
# [Worker output summary]
# ## Artifacts
# [List of files/outputs]
# ## Next
# [Recommended next steps]
```

#### Step 3: Validate state.json

```bash
cat $SPRINT_DIR/state.json | jq 'keys'
# Should include: sprintId, status, iterationCount, startedAt, endsAt, goals, completedGoals

# Check for required fields
cat $SPRINT_DIR/state.json | jq '.sprintId, .status, .iterationCount'
```

#### Step 4: Manually Run Synthesis

```bash
SPRINT_ID="<sprint-id>"

bash ~/.openclaw/agents/main/workspace/skills/sprint/scripts/sprint-synthesize.sh \
  --sprint-id "$SPRINT_ID" \
  --manual

# Check for output
sleep 3
ls -la ~/.openclaw/agents/main/workspace/data/sprints/$SPRINT_ID/SPRINT-REPORT.md
cat ~/.openclaw/agents/main/workspace/data/sprints/$SPRINT_ID/SPRINT-REPORT.md | head -30
```

#### Step 5: If Synthesis Still Fails

```bash
# Check script logs
tail -50 ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/synthesis.log

# Verify script exists and is executable
test -x ~/.openclaw/agents/main/workspace/skills/sprint/scripts/sprint-synthesize.sh && echo "Script OK" || echo "Script not found"

# Run with verbose output
bash -x ~/.openclaw/agents/main/workspace/skills/sprint/scripts/sprint-synthesize.sh \
  --sprint-id "<sprint-id>" \
  --manual 2>&1 | tee /tmp/synthesis-debug.log

# Check error
cat /tmp/synthesis-debug.log | grep -i error
```

---

## Stale Lock Files

### Symptoms

- Director logs show: `flock: acquire timeout (30s exceeded)`
- Director exits without spawning worker
- `.state.lock` or `.director.lock` file exists but is hours old
- Sprint appears frozen (no progress for long time)

### Root Cause

A previous director process acquired a lock and crashed before releasing it. The lock file persists, blocking subsequent director runs.

### Recovery

```bash
SPRINT_ID="<sprint-id>"
SPRINT_DIR=~/.openclaw/agents/main/workspace/data/sprints/$SPRINT_ID

# Check lock files
ls -la $SPRINT_DIR/.*.lock

# Remove stale locks
rm -f $SPRINT_DIR/.state.lock $SPRINT_DIR/.director.lock

# Verify
ls -la $SPRINT_DIR/.*.lock 2>&1 | grep -q "No such file" && echo "Locks cleared"

# Next director run should succeed
bash ~/.openclaw/agents/main/workspace/skills/sprint/scripts/sprint-director.sh \
  --sprint-id "$SPRINT_ID"
```

---

## Stall Counter Runaway

### Symptoms

- `consecutiveStalls` incrementing every director iteration
- Director log shows repeated "TIMEOUT: iter-N.md never received"
- Sprint appears stuck (same iteration number for 30+ minutes)
- Potential escalation if `consecutiveStalls > 3`

### Root Causes

1. **Worker always times out** — systemic issue (script error, infinite loop, blocking operation)
2. **Iteration count not incrementing** — state.json not updating properly
3. **Lock contention** — concurrent director runs (rare, but possible with misconfigured cron)

### Diagnosis

```bash
SPRINT_ID="<sprint-id>"
SPRINT_DIR=~/.openclaw/agents/main/workspace/data/sprints/$SPRINT_ID

# Check stall count
cat $SPRINT_DIR/state.json | jq '.consecutiveStalls, .iterationCount'

# Read recent director log
tail -20 $SPRINT_DIR/director.log

# Check if iteration count advancing
cat $SPRINT_DIR/state.json | jq '.iterationCount'
sleep 120
cat $SPRINT_DIR/state.json | jq '.iterationCount'
# If same number after 2 min, iteration not advancing
```

### Recovery Procedure

#### Option 1: Reset Stall Counter (If Worker Is Actually Working)

```bash
SPRINT_ID="<sprint-id>"
SPRINT_DIR=~/.openclaw/agents/main/workspace/data/sprints/$SPRINT_ID

python3 << 'PYEOF'
import json

sprint_id = "<sprint-id>"
state_path = f"~/.openclaw/agents/main/workspace/data/sprints/{sprint_id}/state.json"

with open(state_path, 'r') as f:
    state = json.load(f)

# Reset consecutive stalls (but keep total count)
state['consecutiveStalls'] = 0

with open(state_path, 'w') as f:
    json.dump(state, f, indent=2)

print("Stall counter reset. Monitor next director iteration.")
PYEOF
```

#### Option 2: Skip This Iteration (If Worker is Broken)

```bash
python3 << 'PYEOF'
import json

sprint_id = "<sprint-id>"
state_path = f"~/.openclaw/agents/main/workspace/data/sprints/{sprint_id}/state.json"

with open(state_path, 'r') as f:
    state = json.load(f)

# Increment iteration count, reset status to active
current_iter = state['iterationCount']
state['iterationCount'] = current_iter + 1
state['status'] = 'active'
state['consecutiveStalls'] = 0
state['totalStalls'] += 1

with open(state_path, 'w') as f:
    json.dump(state, f, indent=2)

print(f"Skipped iteration {current_iter}. Now on iteration {state['iterationCount']}")
PYEOF
```

#### Option 3: Abort Sprint (If Unrecoverable)

```bash
SPRINT_ID="<sprint-id>"
bash ~/.openclaw/agents/main/workspace/skills/sprint/scripts/sprint-synthesize.sh \
  --sprint-id "$SPRINT_ID" \
  --manual
```

---

## Sprint Hangs in Active Status

### Symptoms

- Sprint duration has elapsed (current time > endsAt)
- Status is still `active` (should be `complete` or `synthesizing`)
- No synthesis has occurred
- Discord thread shows no final summary

### Root Cause

- Synthesis script never ran after sprint window expired
- Cron job might not have fired
- Manual synthesis trigger was forgotten

### Recovery

```bash
SPRINT_ID="<sprint-id>"
SPRINT_DIR=~/.openclaw/agents/main/workspace/data/sprints/$SPRINT_ID

# Verify sprint has ended
END_TIME=$(cat $SPRINT_DIR/state.json | jq -r '.endsAt')
echo "Sprint was supposed to end at: $END_TIME"
echo "Current time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Manually trigger synthesis
bash ~/.openclaw/agents/main/workspace/skills/sprint/scripts/sprint-synthesize.sh \
  --sprint-id "$SPRINT_ID" \
  --manual

# Verify status changed
sleep 3
cat $SPRINT_DIR/state.json | jq '.status'
# Should show: "complete"
```

---

## Director Not Running (Cron Issue)

### Symptoms

- Sprint initialized but no iterations ever started
- No `iter-1.md` appears
- Director logs are empty or very old
- Cron job may not be registered

### Diagnosis

```bash
# Check if cron jobs are running
grep -i sprint ~/.openclaw/cron/jobs.json | head -5

# Check last director.log
SPRINT_ID=$(ls -t ~/.openclaw/agents/main/workspace/data/sprints/ | head -1)
cat ~/.openclaw/agents/main/workspace/data/sprints/$SPRINT_ID/director.log

# Check system cron
crontab -l | grep sprint
```

### Recovery

```bash
# Re-register cron job
# (This is normally done by sprint-init.sh, but may need manual trigger)

SPRINT_ID="<sprint-id>"
SPRINT_DIR=~/.openclaw/agents/main/workspace/data/sprints/$SPRINT_ID

# Manually invoke director
bash ~/.openclaw/agents/main/workspace/skills/sprint/scripts/sprint-director.sh \
  --sprint-id "$SPRINT_ID"

# Wait for worker
sleep 30

# Check for iter-1.md
ls -l $SPRINT_DIR/iter-1.md
```

---

## Manual Recovery Procedures

### Procedure: Clear All Sprint State and Restart

Use only if sprint is completely broken and you want to start fresh.

```bash
SPRINT_ID="<sprint-id>"
SPRINT_DIR=~/.openclaw/agents/main/workspace/data/sprints/$SPRINT_ID

# Backup current state (just in case)
cp -r $SPRINT_DIR ${SPRINT_DIR}.backup

# Remove sprint
rm -rf $SPRINT_DIR

# Re-initialize with same topic
bash ~/.openclaw/agents/main/workspace/skills/sprint/scripts/sprint-init.sh \
  --topic "YOUR TOPIC HERE" \
  --duration "4h"
```

### Procedure: Manually Mark Goals Complete

If worker completed work but didn't update goals.json:

```bash
python3 << 'PYEOF'
import json

sprint_id = "<sprint-id>"
state_path = f"~/.openclaw/agents/main/workspace/data/sprints/{sprint_id}/state.json"

with open(state_path, 'r') as f:
    state = json.load(f)

# Mark specific goals complete
# state['completedGoals'].append('G1')
# state['completedGoals'].append('G2')

state['completedGoals'] = ['G1', 'G2', 'G3']  # Replace with actual completed goals

with open(state_path, 'w') as f:
    json.dump(state, f, indent=2)

print(f"Marked goals complete: {state['completedGoals']}")
PYEOF
```

### Procedure: Extract All Iteration Outputs

If you need to combine all iterations into a single document:

```bash
SPRINT_ID="<sprint-id>"
SPRINT_DIR=~/.openclaw/agents/main/workspace/data/sprints/$SPRINT_ID

# Combine all iter files
cat > /tmp/sprint-combined.md << 'EOF'
# Sprint Results: $SPRINT_ID

EOF

for f in $(ls -1 $SPRINT_DIR/iter-*.md | sort -V); do
  echo "## $(basename $f)" >> /tmp/sprint-combined.md
  cat "$f" >> /tmp/sprint-combined.md
  echo "" >> /tmp/sprint-combined.md
done

echo "Combined output: /tmp/sprint-combined.md"
cat /tmp/sprint-combined.md
```

---

## Prevention Best Practices

1. **Keep disk space >1 GB** in `~/.openclaw/agents/main/workspace/data/sprints/`
2. **Monitor director.log in real-time** during first few iterations
3. **Set reasonable durations** — don't exceed 8 hours for initial sprints
4. **Start with `low` autonomy** to catch issues early
5. **Check Discord thread** after each iteration to verify output quality
6. **Archive old sprints** manually (move to `archive/`) if `data/sprints/` grows beyond 2 GB

---

## Still Stuck?

If none of these procedures work:

1. **Collect diagnostics:**
```bash
SPRINT_ID="<sprint-id>"
SPRINT_DIR=~/.openclaw/agents/main/workspace/data/sprints/$SPRINT_ID

mkdir -p /tmp/sprint-diagnostics
cp -r $SPRINT_DIR /tmp/sprint-diagnostics/
tar -czf /tmp/sprint-diagnostics.tar.gz /tmp/sprint-diagnostics/
```

2. **Post to #watson-main in Discord** with:
   - Sprint ID
   - Last known status
   - Attached diagnostic tarball
   - Steps already taken

3. **Manual abort and new sprint:**
```bash
# If sprint is unsalvageable, start fresh
bash ~/.openclaw/agents/main/workspace/skills/sprint/scripts/sprint-init.sh \
  --topic "FRESH ATTEMPT: <original topic>" \
  --duration "4h"
```

---

## Reference

- **SKILL.md** — Full skill reference
- **GUIDE.md** — User guide and monitoring
- **sprint-runbook.md** — Detailed procedures (in scripts/)
