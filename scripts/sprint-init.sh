#!/bin/bash
# sprint-init.sh — Sprint Initializer (v0.7)
# Creates sprint directory, state.json, goals.json, registers thread, schedules director cron
# Crash-safe: EXIT trap rolls back Discord thread + active-threads entry on failure

set -euo pipefail

WORKSPACE="$HOME/.openclaw/agents/main/workspace"
SPRINTS_DIR="$WORKSPACE/data/sprints"
ACTIVE_THREADS="$WORKSPACE/config/active-threads.json"
SPRINT_REGISTRY="$WORKSPACE/data/sprint-registry.json"
EVENT_BUS="$HOME/.openclaw/events/bus.jsonl"

# Parse arguments
TOPIC=""
DURATION="2h"
GOALS_JSON=""   # --goals-json: skip clarifying questions (required for unattended/overnight)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topic)     TOPIC="$2";      shift 2 ;;
    --duration)  DURATION="$2";   shift 2 ;;
    --goals-json) GOALS_JSON="$2"; shift 2 ;;
    *)
      echo "Usage: sprint-init.sh --topic \"<string>\" [--duration \"<string>\"] [--goals-json <path>]"
      exit 1 ;;
  esac
done

if [[ -z "$TOPIC" ]]; then
  echo "ERROR: --topic is required"
  exit 1
fi

# ── Input sanitization ──────────────────────────────────────────────────────
# Strict whitelist: alphanumeric, spaces, hyphens, underscores, basic punctuation
# Block LLM prompt injection vectors: newlines, backticks, $(), angle brackets, etc.
if [[ ${#TOPIC} -gt 200 ]]; then
  echo "ERROR: topic exceeds 200 characters (${#TOPIC} given)"; exit 1
fi
if [[ "$TOPIC" =~ [^a-zA-Z0-9\ \-_.,!?:\[\]\(\)] ]]; then
  echo "ERROR: topic contains illegal characters. Allowed: a-z A-Z 0-9 space - _ . , ! ? : [ ] ( )"; exit 1
fi
# Block newline injection
if printf '%s' "$TOPIC" | grep -qP '\n|\r' 2>/dev/null; then
  echo "ERROR: topic contains newlines"; exit 1
fi

# ── Sprint ID ────────────────────────────────────────────────────────────────
DATE=$(date -u +%Y%m%d)
SLUG=$(echo "$TOPIC" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-' | cut -c1-20)
SPRINT_ID="sprint-${DATE}-${SLUG}"

# Collision avoidance
if [[ -d "$SPRINTS_DIR/$SPRINT_ID" ]]; then
  SUFFIX=$(printf '%03d' $((RANDOM % 1000)))
  SPRINT_ID="${SPRINT_ID}-${SUFFIX}"
fi

SPRINT_PATH="$SPRINTS_DIR/$SPRINT_ID"
mkdir -p "$SPRINT_PATH"

# ── Duration → endsAt ───────────────────────────────────────────────────────
SECONDS_TO_ADD=7200  # default 2h
if   [[ "$DURATION" =~ ^([0-9]+)h([0-9]+)m$ ]]; then
  SECONDS_TO_ADD=$(( ${BASH_REMATCH[1]}*3600 + ${BASH_REMATCH[2]}*60 ))
elif [[ "$DURATION" =~ ^([0-9]+)h$ ]]; then
  SECONDS_TO_ADD=$(( ${BASH_REMATCH[1]}*3600 ))
elif [[ "$DURATION" =~ ^([0-9]+)m$ ]]; then
  SECONDS_TO_ADD=$(( ${BASH_REMATCH[1]}*60 ))
fi

START_TIME=$(date -u -Iseconds)
# macOS vs GNU date
if date -v+1S -Iseconds &>/dev/null 2>&1; then
  END_TIME=$(date -u -v+${SECONDS_TO_ADD}S -Iseconds)
else
  END_TIME=$(date -u -d "+${SECONDS_TO_ADD} seconds" -Iseconds)
fi

# ── Crash-safe rollback state ────────────────────────────────────────────────
THREAD_ID=""
REGISTRY_WRITTEN=false
STATE_WRITTEN=false
THREAD_CREATED=false    # C3: initialize alongside other flags (set -u guard)

cleanup_and_unlock() {
  local exit_code=$?
  # Always release flock if held (safe to call even if lock not acquired)
  flock -u 9 2>/dev/null || true
  exec 9>&- 2>/dev/null || true

  if [[ $exit_code -ne 0 ]]; then
    if [[ "$STATE_WRITTEN" == "false" ]]; then
      # Failed before state.json was fully written — hard rollback
      echo "ROLLBACK: init failed before state written (exit $exit_code), cleaning up..."
      # Revert active-threads entry (FD 9 is already released; use FD 8 on the same lockfile)
      if [[ "$REGISTRY_WRITTEN" == "true" && -n "$THREAD_ID" && "$THREAD_CREATED" == "true" ]]; then
        exec 8>"$ACTIVE_THREADS.lock"
        flock -e -w 10 8 2>/dev/null && \
          jq --arg tid "$THREAD_ID" 'del(.[$tid])' "$ACTIVE_THREADS" > "$ACTIVE_THREADS.tmp" && \
          mv "$ACTIVE_THREADS.tmp" "$ACTIVE_THREADS" || true
        flock -u 8; exec 8>&-
      fi
      # Delete Discord thread if it was created (best effort)
      if [[ "$THREAD_CREATED" == "true" && -n "$THREAD_ID" && ! "$THREAD_ID" =~ placeholder$ ]]; then
        bash -c "message action=delete channel=discord messageId='$THREAD_ID' target='$THREAD_ID'" 2>/dev/null || \
          echo "MANUAL CLEANUP NEEDED: delete Discord thread $THREAD_ID"
      fi
      # Clean up partial sprint dir
      rm -rf "$SPRINT_PATH"
    else
      # C2: Failed after state.json was written — mark init_failed instead of deleting
      # Zombie prevention: state exists but init didn't complete; director will see init_failed and skip
      echo "ROLLBACK: init failed after state written (exit $exit_code) — marking init_failed"
      jq '.status = "init_failed"' "$SPRINT_PATH/state.json" > "$SPRINT_PATH/state.json.tmp" && \
        mv "$SPRINT_PATH/state.json.tmp" "$SPRINT_PATH/state.json" || true
      echo "MANUAL CLEANUP NEEDED: sprint dir $SPRINT_PATH has status=init_failed"
    fi
  fi
}
# C1: Single trap set once — handles both lock release and rollback
trap cleanup_and_unlock EXIT

# ── Goals ────────────────────────────────────────────────────────────────────
if [[ -n "$GOALS_JSON" ]]; then
  # Unattended mode: load goals from file
  if [[ ! -f "$GOALS_JSON" ]]; then
    echo "ERROR: --goals-json file not found: $GOALS_JSON"; exit 1
  fi
  # Validate it's valid JSON with expected structure
  jq -e '.goals and (.goals | length > 0)' "$GOALS_JSON" > /dev/null || {
    echo "ERROR: goals.json must have .goals array with at least one entry"; exit 1
  }
  cp "$GOALS_JSON" "$SPRINT_PATH/goals.json"
  echo "INFO: Goals loaded from $GOALS_JSON (unattended mode)"
else
  # Interactive mode: create placeholder goals (clarifying questions via Discord — P1)
  cat > "$SPRINT_PATH/goals.json" << EOF
{
  "goals": [
    {
      "id": "g1",
      "title": "$(echo "$TOPIC" | sed 's/"/\\"/g')",
      "success_criteria": "Produce meaningful output on the topic",
      "status": "pending",
      "priority": 1
    }
  ],
  "meta_goal": "When all goals complete, generate 3 next sprint options and post to thread. Operator decides."
}
EOF
  echo "INFO: Goals placeholder created (interactive clarification: P1)"
fi

# ── state.json ───────────────────────────────────────────────────────────────
# NOTE: STATE_WRITTEN is set to true only after Discord thread + active-threads + cron
# all succeed. Until then, rollback deletes the sprint dir entirely.
cat > "$SPRINT_PATH/state.json" << EOF
{
  "sprintId": "$SPRINT_ID",
  "topic": "$(echo "$TOPIC" | sed 's/"/\\"/g')",
  "threadId": null,
  "directorCronId": null,
  "autonomyLevel": "medium",
  "status": "active",
  "iterationCount": 0,
  "consecutiveStalls": 0,
  "totalStalls": 0,
  "totalStallMinutes": 0,
  "errorCount": 0,
  "startedAt": "$START_TIME",
  "endsAt": "$END_TIME",
  "lastIterationAt": null,
  "completedAt": null,
  "completedGoals": [],
  "mutations": [],
  "log": []
}
EOF

# C2: Do NOT set STATE_WRITTEN=true here — Discord thread, active-threads, and cron
# must all succeed first. STATE_WRITTEN=true is set after cron scheduling below.

# ── P1: Create Discord thread ───────────────────────────────────────────────
# If SPRINT_THREAD_ID is pre-set (passed via env), use it directly — no creation needed
# This allows supervised sprints to run inside an existing thread
if [[ -n "${SPRINT_THREAD_ID:-}" ]]; then
  THREAD_ID="$SPRINT_THREAD_ID"
  THREAD_CREATED=true
  echo "INFO: Using pre-set thread ID: $THREAD_ID"
else
  # Attempt thread creation via openclaw message CLI
  THREAD_CREATION_OUTPUT=$(openclaw message thread create --channel discord --target 1483794224909520978 \
    --thread-name "Sprint: $(echo "$TOPIC" | cut -c1-80)" --auto-archive-min 1440 --json 2>/dev/null || echo "")

  # H2: message tool returns top-level .id
  THREAD_ID=$(echo "$THREAD_CREATION_OUTPUT" | jq -r '.id // ""' 2>/dev/null || echo "")

  # Fallback
  if [[ -z "$THREAD_ID" || "$THREAD_ID" == "null" ]]; then
    THREAD_ID="$SPRINT_ID-placeholder"
    echo "WARN: Discord thread creation failed — using placeholder: $THREAD_ID"
    echo "WARN: For production use, set SPRINT_THREAD_ID env var or fix Discord connectivity"
  fi

  THREAD_CREATED=true
  echo "INFO: Discord thread: $THREAD_ID"
fi

# Update state.json with real threadId
jq --arg tid "$THREAD_ID" '.threadId = $tid' "$SPRINT_PATH/state.json" > "$SPRINT_PATH/state.json.tmp" && \
  mv "$SPRINT_PATH/state.json.tmp" "$SPRINT_PATH/state.json"

# ── active-threads.json registration ────────────────────────────────────────
# Uses real schema (object keyed by threadId)

# Backup before write
cp "$ACTIVE_THREADS" "$ACTIVE_THREADS.bak" 2>/dev/null || true

exec 9>"$ACTIVE_THREADS.lock"
flock -e -w 30 9 || { echo "ERROR: active-threads lock timeout"; exit 1; }
# C1: No second trap here — cleanup_and_unlock (set once above) already handles lock release

jq --arg tid "$THREAD_ID" --arg sid "$SPRINT_ID" \
   --arg topic "$(echo "$TOPIC" | sed 's/"/\\"/g')" \
   --arg created "$(date -u +%Y-%m-%d)" \
   '.threads += [{
     "id": $tid,
     "name": ("Sprint: " + $topic),
     "project": "sprint",
     "sprint_id": $sid,
     "status": "active",
     "created": $created,
     "description": ("Overnight sprint: " + $topic)
   }]' \
   "$ACTIVE_THREADS" > "$ACTIVE_THREADS.tmp" && mv "$ACTIVE_THREADS.tmp" "$ACTIVE_THREADS"

# Post-write validation
jq empty "$ACTIVE_THREADS" || {
  echo "ERROR: active-threads.json corrupted after write; reverting"
  cp "$ACTIVE_THREADS.bak" "$ACTIVE_THREADS"
  exit 1
}

flock -u 9; exec 9>&-
REGISTRY_WRITTEN=true

# ── sprint-registry.json ─────────────────────────────────────────────────────
if [[ ! -f "$SPRINT_REGISTRY" ]]; then echo '{}' > "$SPRINT_REGISTRY"; fi
jq --arg sid "$SPRINT_ID" --arg topic "$(echo "$TOPIC" | sed 's/"/\\"/g')" \
   --arg started "$START_TIME" \
   '.[$sid] = {"topic": $topic, "thread_id": null, "started_at": $started, "status": "active"}' \
   "$SPRINT_REGISTRY" > "$SPRINT_REGISTRY.tmp" && mv "$SPRINT_REGISTRY.tmp" "$SPRINT_REGISTRY"

# ── P1: Schedule director cron (v2: agentTurn, direct sessions_spawn) ──────
# Fixed schedule: 8,28,48 minutes past each hour (avoids Pulse slots)
CRON_SCHEDULE="8,28,48 * * * *"
DIRECTOR_CMD="bash $WORKSPACE/skills/sprint/scripts/sprint-director.sh --sprint-id $SPRINT_ID"

# v2: Director runs as agentTurn (not system-event). The cron agent runs the
# bash script, and if it outputs SPAWN_WORKER, calls sessions_spawn directly.
# No bus relay, no consumer cron — direct spawn path.
DIRECTOR_MESSAGE="$(cat <<AGENT_MSG
Run: $DIRECTOR_CMD

Check the output and act on the FIRST matching pattern:

1. If output contains "SPAWN_WORKER":
   - The JSON after SPAWN_WORKER has fields: sprint_id, iteration, context_file, iter_file, state_file, thread_id, topic
   - Read the file at context_file path to get the worker context
   - Call sessions_spawn with this task:

     You are a sprint worker for: {topic}
     Sprint ID: {sprint_id} | Iteration: {iteration}

     CRITICAL: Write your output to exactly this path: {iter_file}

     ---
     {contents of context_file}
     ---

     ## Post-Completion Steps (MANDATORY — do ALL after writing output)

     1. Reset sprint state (use flock for safety):
     flock -e -w 30 {state_file}.lock bash -c "jq '.status=\"active\"' '{state_file}' > '{state_file}.tmp' && mv '{state_file}.tmp' '{state_file}'"

     2. Signal completion:
     bash $HOME/.openclaw/agents/main/workspace/scripts/sub-agent-complete.sh "sprint-worker-{sprint_id}-iter-{iteration}" "na" "Completed iteration {iteration}" "{thread_id}"

     3. Post iteration summary to Discord thread:
     Use the message tool: action=thread-reply, channel=discord, target={thread_id}, threadId={thread_id}
     Post a short summary (3-5 lines max) of what you produced.

   - Reply: SPAWN_OK

2. If output contains "Director cycle complete" without SPAWN_WORKER: reply DIRECTOR_OK
3. If output contains "INFO:" or "no action": reply DIRECTOR_SKIP
4. If output contains "ERROR": reply DIRECTOR_ERROR
AGENT_MSG
)"

CRON_ADD_OUTPUT=$(openclaw cron add --json --cron "$CRON_SCHEDULE" \
  --message "$DIRECTOR_MESSAGE" \
  --model "anthropic/claude-sonnet-4-5" \
  --timeout-seconds 300 \
  --session isolated \
  --agent main \
  --no-deliver \
  --name "sprint-director-$SPRINT_ID" \
  2>&1 || echo "")
# Strip any leading config warning lines before parsing JSON (grep for first '{' line onward)
CRON_ADD_JSON=$(echo "$CRON_ADD_OUTPUT" | grep -A1000 '^{' | head -1000 || echo "")
DIRECTOR_CRON_ID=$(echo "$CRON_ADD_JSON" | jq -r '.id // ""' 2>/dev/null || echo "")

if [[ -z "$DIRECTOR_CRON_ID" || "$DIRECTOR_CRON_ID" == "null" ]]; then
  echo "ERROR: Could not parse cron job ID from output: $CRON_ADD_JSON"
  echo "ERROR: Director cron not scheduled — cannot safely initialize sprint without it"
  # Escalate to bus before exiting (cleanup_and_unlock will handle state rollback)
  if [[ -f "$EVENT_BUS" ]]; then
    printf '{"timestamp":"%s","agent":"sprint-init","type":"escalation","message":"sprint-init failed: could not schedule director cron for %s","data":{"sprint_id":"%s"}}\n' \
      "$(date -u -Iseconds)" "$SPRINT_ID" "$SPRINT_ID" >> "$EVENT_BUS"
  fi
  exit 1   # triggers cleanup_and_unlock — since STATE_WRITTEN is still false, full rollback
else
  echo "INFO: Director cron scheduled: $DIRECTOR_CRON_ID"
fi

# Update state.json with cron ID
if [[ -n "$DIRECTOR_CRON_ID" ]]; then
  jq --arg cid "$DIRECTOR_CRON_ID" '.directorCronId = $cid' "$SPRINT_PATH/state.json" > "$SPRINT_PATH/state.json.tmp" && \
    mv "$SPRINT_PATH/state.json.tmp" "$SPRINT_PATH/state.json"
fi

# C2: All three setup steps (Discord thread, active-threads, cron) complete — now safe to commit
STATE_WRITTEN=true

# ── Logging ──────────────────────────────────────────────────────────────────
echo "[$(date -u -Iseconds)] INIT: sprint_id=$SPRINT_ID topic=$(echo "$TOPIC" | head -c 80) duration=$DURATION thread_id=$THREAD_ID cron_id=$DIRECTOR_CRON_ID" \
  >> "$SPRINT_PATH/director.log"

# ── Bus event ────────────────────────────────────────────────────────────────
if [[ -f "$EVENT_BUS" ]]; then
  printf '{"timestamp":"%s","agent":"sprint-init","type":"task_complete","label":"sprint-%s-init","data":{"sprint_id":"%s","topic":"%s","thread_id":"%s","autonomy_level":"medium"}}\n' \
    "$(date -u -Iseconds)" "$SPRINT_ID" "$SPRINT_ID" "$(echo "$TOPIC" | sed 's/"/\\"/g')" "$THREAD_ID" \
    >> "$EVENT_BUS"
fi

echo ""
echo "✅ Sprint initialized"
echo "   Sprint ID       : $SPRINT_ID"
echo "   Topic           : $TOPIC"
echo "   Duration        : $DURATION (ends $END_TIME)"
echo "   Thread ID       : $THREAD_ID"
echo "   Director Cron   : $DIRECTOR_CRON_ID"
echo "   Autonomy        : medium"
echo "   State file      : $SPRINT_PATH/state.json"
echo ""
echo "Next steps:"
echo "  1. Director will fire at :08, :28, :48 on each hour"
echo "  2. Run: sprint-director.sh --sprint-id $SPRINT_ID (or wait for first cron)"
echo "  3. Monitor progress in Discord thread: $THREAD_ID"
