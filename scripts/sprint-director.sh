#!/bin/bash
# sprint-director.sh — Sprint Director (v0.8)
# Changes v0.8: C1 single-goal injection + completed list, C2 state.json auto-backup,
#               C3 iter-N.md section validation (## Summary/Artifacts/Next)
# Cron payload: 8,28,48 * * * * (avoids all Pulse slots: :00,:03,:05,:10,:15,:30,:35)
# Uses file-argument flock style (compatible with bash 3.2 / macOS).

set -euo pipefail

WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/agents/main/workspace}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPRINTS_DIR="$WORKSPACE/data/sprints"
EVENT_BUS="$HOME/.openclaw/events/bus.jsonl"
WORKER_TIMEOUT=600   # seconds before treating missing iter-N.md as stall
GRACE_SECONDS=10     # grace period on top of WORKER_TIMEOUT
POLL_INTERVAL=30     # seconds between iter-N.md existence checks

# Parse arguments
SPRINT_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sprint-id) SPRINT_ID="$2"; shift 2 ;;
    *)
      echo "Usage: sprint-director.sh --sprint-id <id>"
      exit 1 ;;
  esac
done

[[ -z "$SPRINT_ID" ]] && { echo "ERROR: --sprint-id required"; exit 1; }

SPRINT_PATH="$SPRINTS_DIR/$SPRINT_ID"
STATE_FILE="$SPRINT_PATH/state.json"
LOCK_FILE="$SPRINT_PATH/.state.lock"
DIRECTOR_LOCK="$SPRINT_PATH/.director.lock"  # H5: global per-sprint director lock
SYNTHESIZE_SCRIPT="$SKILL_DIR/scripts/sprint-synthesize.sh"

[[ -d "$SPRINT_PATH" ]] || { echo "ERROR: sprint $SPRINT_ID not found"; exit 1; }
[[ -f "$STATE_FILE"  ]] || { echo "ERROR: state.json missing for $SPRINT_ID"; exit 1; }

log() { echo "[$(date -u -Iseconds)] DIRECTOR [$SPRINT_ID]: $*" >> "$SPRINT_PATH/director.log"; }

# H5: Prevent concurrent director runs for the same sprint.
# If a prior director is still polling (MAX_WAIT=610s), a new cron fire skips immediately.
# flock -n (non-blocking): returns 1 instantly if lock is held rather than waiting.
exec 7>"$DIRECTOR_LOCK"
if ! flock -n 7; then
  echo "INFO: Director already running for $SPRINT_ID — skipping this cron fire"
  log "Concurrent fire detected — skipping (another director holds .director.lock)"
  exec 7>&-
  exit 0
fi
# Lock is held for the lifetime of this process; released automatically on exit.

# ── Locking helpers (file-argument style, bash 3.2 compatible) ───────────────
# acquire_lock: runs a command block under exclusive flock
# Usage: acquire_lock LOCKFILE CMD [args...]
# For state reads/writes, we use a temporary wrapper pattern.

read_state_locked() {
  flock -e -w 30 "$LOCK_FILE" jq -r "$1" "$STATE_FILE"
}

write_state_locked() {
  # $1 = jq expression, writes atomically under lock
  local expr="$1"
  flock -e -w 30 "$LOCK_FILE" bash -c "
    jq '$expr' '$STATE_FILE' > '$STATE_FILE.tmp' && mv '$STATE_FILE.tmp' '$STATE_FILE'
  "
}

# ── Schema validation ────────────────────────────────────────────────────────
flock -e -w 30 "$LOCK_FILE" jq -e '.sprintId and .status and .iterationCount and .autonomyLevel' \
  "$STATE_FILE" > /dev/null 2>&1 || {
  echo "ERROR: state.json schema invalid for $SPRINT_ID"
  exit 1
}

# ── Read state (single locked read for all fields) ───────────────────────────
STATE_SNAPSHOT=$(flock -e -w 30 "$LOCK_FILE" cat "$STATE_FILE")
STATUS=$(echo "$STATE_SNAPSHOT"          | jq -r '.status')

# ── Early-exit guard: if sprint is already completed, exit immediately ───────
if [[ "$STATUS" == "completed" ]]; then
  log "Sprint already completed, exiting"
  echo "INFO: Sprint $SPRINT_ID is completed — early exit"
  exit 0
fi

ITERATION=$(echo "$STATE_SNAPSHOT"       | jq -r '.iterationCount')
ENDS_AT=$(echo "$STATE_SNAPSHOT"         | jq -r '.endsAt')
THREAD_ID=$(echo "$STATE_SNAPSHOT"       | jq -r '.threadId // ""')
CONSECUTIVE_STALLS=$(echo "$STATE_SNAPSHOT" | jq -r '.consecutiveStalls // 0')
TOTAL_STALLS=$(echo "$STATE_SNAPSHOT"    | jq -r '.totalStalls // 0')
TOTAL_STALL_MIN=$(echo "$STATE_SNAPSHOT" | jq -r '.totalStallMinutes // 0')
ERROR_COUNT=$(echo "$STATE_SNAPSHOT"     | jq -r '.errorCount // 0')
DIRECTOR_CRON_ID=$(echo "$STATE_SNAPSHOT"| jq -r '.directorCronId // ""')
NOW=$(date -u -Iseconds)
NOW_EPOCH=$(date -u +%s)

log "Fired. status=$STATUS iteration=$ITERATION stalls=${CONSECUTIVE_STALLS}/${TOTAL_STALLS}"

# ── Step 3: Validate prior iter file (if exists) ────────────────────────────
# Check that the most recent iter file has required sections before proceeding.
PREV_ITER_FILE="$SPRINT_PATH/iter-${ITERATION}.md"
if [[ $ITERATION -gt 0 && -f "$PREV_ITER_FILE" ]]; then
  REQUIRED_SECTIONS=("## Summary" "## Artifacts" "## Next")
  ITER_VALIDATION_FAILED=false
  for section in "${REQUIRED_SECTIONS[@]}"; do
    if ! grep -q "$section" "$PREV_ITER_FILE"; then
      log "WARN: iter-${ITERATION}.md missing required section: '$section'"
      ITER_VALIDATION_FAILED=true
    fi
  done
  if [[ "$ITER_VALIDATION_FAILED" == "true" ]]; then
    log "iter-${ITERATION}.md failed section validation — counting as stall"
    NEW_CONSEC=$((CONSECUTIVE_STALLS + 1))
    NEW_TOTAL=$((TOTAL_STALLS + 1))
    cp "$STATE_FILE" "${STATE_FILE}.bak" 2>/dev/null || true
    flock -e -w 30 "$LOCK_FILE" bash -c "
      jq '.consecutiveStalls=$NEW_CONSEC | .totalStalls=$NEW_TOTAL | .log += [{\"at\":\"$NOW\",\"event\":\"iter_validation_failed\",\"iteration\":$ITERATION}]' \
        '$STATE_FILE' > '$STATE_FILE.tmp' && mv '$STATE_FILE.tmp' '$STATE_FILE'
    "
    # Update in-memory snapshot for stall checks below
    CONSECUTIVE_STALLS=$NEW_CONSEC
    TOTAL_STALLS=$NEW_TOTAL
  fi
fi

# ── Step 3.5: Max iterations guard ───────────────────────────────────────────
MAX_ITERATIONS=50
if [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  log "Max iterations ($MAX_ITERATIONS) reached — triggering synthesis"
  exec bash "$SYNTHESIZE_SCRIPT" --sprint-id "$SPRINT_ID" --trigger max_iterations
fi

# ── Step 4: Status gate (idempotency) ────────────────────────────────────────
case "$STATUS" in
  complete|invalidated|synthesis_failed|paused)
    log "Status='$STATUS' — no-op exit"
    echo "INFO: Sprint $SPRINT_ID status=$STATUS, no action"
    exit 0 ;;
  worker_spawned)
    # Stall-reset: if worker_spawned for > 25 min, auto-reset to active
    LAST_ITER_AT=$(echo "$STATE_SNAPSHOT" | jq -r '.lastIterationAt // ""')
    if [[ -n "$LAST_ITER_AT" && "$LAST_ITER_AT" != "null" ]]; then
      _iter_stripped="${LAST_ITER_AT%+*}"; _iter_stripped="${_iter_stripped%Z}"
      ITER_EPOCH=$(TZ=UTC0 date -j -f "%Y-%m-%dT%H:%M:%S" "$_iter_stripped" +%s 2>/dev/null || \
                   date -u -d "$LAST_ITER_AT" +%s 2>/dev/null || echo "$NOW_EPOCH")
      STALL_AGE=$(( NOW_EPOCH - ITER_EPOCH ))
      if [[ $STALL_AGE -ge 1500 ]]; then
        # 25 min = 1500s — worker likely crashed, reset state
        STALL_MIN=$(( STALL_AGE / 60 ))
        log "Worker stalled for ${STALL_MIN}min — auto-resetting to active"
        NEW_CONSEC=$((CONSECUTIVE_STALLS + 1))
        NEW_TOTAL=$((TOTAL_STALLS + 1))
        NEW_STALL_MIN=$((TOTAL_STALL_MIN + STALL_MIN))
        cp "$STATE_FILE" "${STATE_FILE}.bak" 2>/dev/null || true
        flock -e -w 30 "$LOCK_FILE" bash -c "
          jq '.status=\"active\" | .consecutiveStalls=$NEW_CONSEC | .totalStalls=$NEW_TOTAL | .totalStallMinutes=$NEW_STALL_MIN | .log += [{\"at\":\"$NOW\",\"event\":\"stall_auto_reset\",\"stall_minutes\":$STALL_MIN}]' \
            '$STATE_FILE' > '$STATE_FILE.tmp' && mv '$STATE_FILE.tmp' '$STATE_FILE'
        "
        # Fall through to continue this director cycle (don't exit)
      else
        log "Status='worker_spawned' (${STALL_AGE}s ago) — idempotency guard, waiting"
        echo "INFO: worker_spawned detected — waiting for worker (${STALL_AGE}s elapsed)"
        exit 0
      fi
    else
      log "Status='worker_spawned' — idempotency guard triggered"
      echo "INFO: worker_spawned detected — another director still running"
      exit 0
    fi ;;
  escalated)
    log "Status='escalated' — waiting for operator ✅"
    echo "INFO: Sprint escalated, awaiting operator ACK"
    exit 0 ;;
esac

# ── Step 5: Mutation ACK check ───────────────────────────────────────────────
PENDING_MUTATIONS=$(echo "$STATE_SNAPSHOT" | jq -r '
  .mutations[]?
  | select(.requires_ack == true and .acked == false)
  | .id // "unknown"
' 2>/dev/null || true)

if [[ -n "$PENDING_MUTATIONS" ]]; then
  OLDEST_PROPOSED=$(echo "$STATE_SNAPSHOT" | jq -r '
    [.mutations[]? | select(.requires_ack==true and .acked==false) | .proposed_at // ""] | sort | first // ""
  ')

  if [[ -n "$OLDEST_PROPOSED" ]]; then
    # H6: macOS date -j cannot parse +00:00 suffix — strip timezone before -j parse
    _proposed_stripped="${OLDEST_PROPOSED%+*}"; _proposed_stripped="${_proposed_stripped%Z}"
    PROPOSED_EPOCH=$(TZ=UTC0 date -j -f "%Y-%m-%dT%H:%M:%S" "$_proposed_stripped" +%s 2>/dev/null || \
                     date -u -d "$OLDEST_PROPOSED" +%s 2>/dev/null || echo 0)
    AGE_MIN=$(( (NOW_EPOCH - PROPOSED_EPOCH) / 60 ))
    if [[ $AGE_MIN -ge 120 ]]; then
      log "Mutation unACKed for ${AGE_MIN}min — auto-invalidating"
      cp "$STATE_FILE" "${STATE_FILE}.bak" 2>/dev/null || true
      flock -e -w 30 "$LOCK_FILE" bash -c "
        jq '.status=\"invalidated\" | .log += [{\"at\":\"$NOW\",\"event\":\"mutation_ack_timeout\",\"age_minutes\":$AGE_MIN}]' \
          '$STATE_FILE' > '$STATE_FILE.tmp' && mv '$STATE_FILE.tmp' '$STATE_FILE'
      "
      exec bash "$SYNTHESIZE_SCRIPT" --sprint-id "$SPRINT_ID" --trigger mutation_timeout
      exit 0
    fi
  fi

  log "Pending mutation ACKs — skipping iteration"
  echo "INFO: Pending mutation ACKs for $SPRINT_ID"
  exit 0
fi

# ── Step 6: endsAt check ─────────────────────────────────────────────────────
if [[ -n "$ENDS_AT" && "$ENDS_AT" != "null" ]]; then
  # H6: macOS date -j cannot parse +00:00 suffix — strip timezone before -j parse
  _ends_stripped="${ENDS_AT%+*}"; _ends_stripped="${_ends_stripped%Z}"
  ENDS_EPOCH=$(TZ=UTC0 date -j -f "%Y-%m-%dT%H:%M:%S" "$_ends_stripped" +%s 2>/dev/null || \
               date -u -d "$ENDS_AT" +%s 2>/dev/null || echo 9999999999)
  REMAINING=$(( ENDS_EPOCH - NOW_EPOCH ))
  if [[ $REMAINING -le 600 ]]; then
    log "Sprint at/near endsAt (${REMAINING}s remaining) — triggering synthesis"
    exec bash "$SYNTHESIZE_SCRIPT" --sprint-id "$SPRINT_ID" --trigger timeout
  fi
fi

# ── Step 7: Set worker_spawned ───────────────────────────────────────────────
NEXT_ITERATION=$((ITERATION + 1))
cp "$STATE_FILE" "${STATE_FILE}.bak" 2>/dev/null || true
flock -e -w 30 "$LOCK_FILE" bash -c "
  jq '.status=\"worker_spawned\" | .lastIterationAt=\"$NOW\" | .iterationCount=$NEXT_ITERATION' \
    '$STATE_FILE' > '$STATE_FILE.tmp' && mv '$STATE_FILE.tmp' '$STATE_FILE'
"
log "Set worker_spawned, iteration $NEXT_ITERATION"

# ── Step 8: Assemble context package (20KB hard cap) ─────────────────────────
CONTEXT_FILE="$SPRINT_PATH/worker-context-${NEXT_ITERATION}.txt"
BUDGET=20480

{
  # Component 1: topic + meta_goal
  TOPIC=$(echo "$STATE_SNAPSHOT" | jq -r .topic)
  META_GOAL=$(jq -r '.meta_goal // "Complete all goals"' "$SPRINT_PATH/goals.json" 2>/dev/null || echo "Complete all goals")
  AUTONOMY=$(echo "$STATE_SNAPSHOT" | jq -r .autonomyLevel)
  echo "# Sprint: $TOPIC"
  echo "Meta: $META_GOAL"
  echo "Iteration: $NEXT_ITERATION | Consecutive Stalls: $CONSECUTIVE_STALLS | Autonomy: $AUTONOMY"
  echo ""
  echo "## Goal This Iteration (focus here — complete this one goal)"
  jq -r '[.goals[] | select(.status=="pending")] | first | "[\(.id)] \(.title) — \(.success_criteria)"' \
    "$SPRINT_PATH/goals.json" 2>/dev/null || echo "(no pending goals)"
  echo ""
  echo "## Completed Goals (reference only — do NOT redo these)"
  COMPLETED=$(jq -r '.goals[] | select(.status=="complete") | "[\(.id)] \(.title) ✓"' \
    "$SPRINT_PATH/goals.json" 2>/dev/null)
  if [[ -n "$COMPLETED" ]]; then
    echo "$COMPLETED"
  else
    echo "(none yet)"
  fi
  echo ""

  # Component 2: last 2 iter files (5KB each max)
  for offset in 2 1; do
    iter_num=$(( NEXT_ITERATION - offset ))
    [[ $iter_num -le 0 ]] && continue
    iter_file="$SPRINT_PATH/iter-${iter_num}.md"
    [[ -f "$iter_file" ]] || continue
    echo "---"
    head -c 5120 "$iter_file"
    echo ""
  done

  # Component 3: worker instruction
  prompt_file="$SKILL_DIR/scripts/sprint-worker-prompt.md"
  [[ -f "$prompt_file" ]] && cat "$prompt_file"

} > "$CONTEXT_FILE.tmp"

# Enforce budget
CTX_SIZE=$(wc -c < "$CONTEXT_FILE.tmp")
if [[ $CTX_SIZE -gt $BUDGET ]]; then
  head -c $BUDGET "$CONTEXT_FILE.tmp" > "$CONTEXT_FILE"
  echo "" >> "$CONTEXT_FILE"
  echo "[CONTEXT TRUNCATED: $((CTX_SIZE - BUDGET)) bytes dropped to stay within 20KB cap]" >> "$CONTEXT_FILE"
else
  mv "$CONTEXT_FILE.tmp" "$CONTEXT_FILE"
fi
log "Context package: $(wc -c < "$CONTEXT_FILE") bytes"

# ── Step 9: Output SPAWN_WORKER for cron agent to call sessions_spawn ────────
ITER_FILE="$SPRINT_PATH/iter-${NEXT_ITERATION}.md"
log "Spawning worker subagent for iteration $NEXT_ITERATION"
# v2: Director is an agentTurn cron. The cron agent reads this output, reads
# the context_file, and calls sessions_spawn directly. No bus relay needed.

SPAWN_JSON=$(jq -c -n \
  --arg sprint_id "$SPRINT_ID" \
  --arg iteration "$NEXT_ITERATION" \
  --arg iter_file "$ITER_FILE" \
  --arg thread_id "$THREAD_ID" \
  --arg topic "$TOPIC" \
  --arg context_file "$CONTEXT_FILE" \
  --arg state_file "$STATE_FILE" \
  '{
    sprint_id: $sprint_id,
    iteration: ($iteration | tonumber),
    iter_file: $iter_file,
    thread_id: $thread_id,
    topic: $topic,
    context_file: $context_file,
    state_file: $state_file
  }')

echo "SPAWN_WORKER $SPAWN_JSON"
log "SPAWN_WORKER output for iteration $NEXT_ITERATION (v2 direct spawn)"

# ── Step 10: Exit cleanly — cron agent handles sessions_spawn ────────────────
log "Director cycle complete for $SPRINT_ID iteration $NEXT_ITERATION"
exit 0
