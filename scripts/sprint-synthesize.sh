#!/bin/bash
# sprint-synthesize.sh — Sprint Synthesis Agent (v0.7)
# Triggered by: timeout, natural completion, stall invalidation, or manual call.
# Double-trigger guard. Crash-safe (ERR trap). Directly deletes director cron via openclaw.

set -euo pipefail

WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/agents/main/workspace}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPRINTS_DIR="$WORKSPACE/data/sprints"
ACTIVE_THREADS="$WORKSPACE/config/active-threads.json"
SPRINT_REGISTRY="$WORKSPACE/data/sprint-registry.json"
SPRINT_RUNS="$WORKSPACE/data/sprint-runs.jsonl"
EVENT_BUS="$HOME/.openclaw/events/bus.jsonl"

# Parse arguments
SPRINT_ID=""
TRIGGER="manual"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sprint-id) SPRINT_ID="$2"; shift 2 ;;
    --trigger)   TRIGGER="$2";   shift 2 ;;
    *)
      echo "Usage: sprint-synthesize.sh --sprint-id <id> [--trigger timeout|stall|natural|manual]"
      exit 1 ;;
  esac
done

[[ -z "$SPRINT_ID" ]] && { echo "ERROR: --sprint-id required"; exit 1; }

SPRINT_PATH="$SPRINTS_DIR/$SPRINT_ID"
STATE_FILE="$SPRINT_PATH/state.json"
REPORT_FILE="$SPRINT_PATH/SPRINT-REPORT.md"

[[ -d "$SPRINT_PATH" ]] || { echo "ERROR: sprint $SPRINT_ID not found"; exit 1; }
[[ -f "$STATE_FILE"  ]] || { echo "ERROR: state.json missing"; exit 1; }

log() { echo "[$(date -u -Iseconds)] SYNTHESIS [$SPRINT_ID]: $*" >> "$SPRINT_PATH/director.log"; }

# ── Double-trigger guard ──────────────────────────────────────────────────────
STATUS=$(jq -r .status "$STATE_FILE")
if [[ "$STATUS" == "complete" ]]; then
  log "Already complete — no-op"
  echo "INFO: Sprint $SPRINT_ID already complete"; exit 0
fi

# ── ERR trap for crash-safe handling ─────────────────────────────────────────
handle_synthesis_failure() {
  local line=$1 code=$2
  log "SYNTHESIS FAILED at line $line (exit $code)"
  jq '.status = "synthesis_failed"' "$STATE_FILE" > "$STATE_FILE.tmp" \
    && mv "$STATE_FILE.tmp" "$STATE_FILE" || true

  # H4: Delete director cron on synthesis failure to prevent infinite cron-fires on frozen sprint
  local failed_cron_id
  failed_cron_id=$(jq -r '.directorCronId // ""' "$STATE_FILE" 2>/dev/null || echo "")
  if [[ -n "$failed_cron_id" && "$failed_cron_id" != "null" ]]; then
    if command -v openclaw &>/dev/null; then
      if openclaw cron delete "$failed_cron_id" 2>/dev/null; then
        log "Director cron $failed_cron_id deleted on synthesis failure"
      else
        log "WARN: Failed to delete director cron $failed_cron_id — MANUAL: openclaw cron delete $failed_cron_id"
        echo "⚠️ Manual action required: openclaw cron delete $failed_cron_id"
      fi
    else
      log "WARN: openclaw CLI not found — MANUAL: openclaw cron delete $failed_cron_id"
    fi
  fi

  # Emit escalation to bus
  if [[ -f "$EVENT_BUS" ]]; then
    printf '{"timestamp":"%s","agent":"sprint-synthesize","type":"escalation","message":"Sprint synthesis failed: %s (trigger=%s, line=%s). Director cron deleted.","data":{"sprint_id":"%s","cron_id":"%s"}}\n' \
      "$(date -u -Iseconds)" "$SPRINT_ID" "$TRIGGER" "$line" "$SPRINT_ID" "${failed_cron_id:-none}" >> "$EVENT_BUS"
  fi

  # H4: Post operator alert to Discord #watson-main so failure is visible
  bash -c "message action=send channel=discord target=1024127507055775808 message='🚨 **Sprint synthesis failed** — \`$SPRINT_ID\` (line $line, exit $code). Director cron deleted. State: \`synthesis_failed\`. Manual recovery needed.'" 2>/dev/null || \
    echo "🚨 SYNTHESIS FAILED for $SPRINT_ID — manual intervention required. Check #watson-main."
  exit "$code"
}
set -E  # inherit ERR trap in subshells
trap 'handle_synthesis_failure "$LINENO" "$?"' ERR

log "Starting synthesis (trigger=$TRIGGER)"
START_EPOCH=$(date -u +%s)

# ── Collect iter files ────────────────────────────────────────────────────────
ITER_COUNT=0
ITER_CONTENT=""
for iter_file in "$SPRINT_PATH"/iter-*.md; do
  [[ -f "$iter_file" ]] || continue
  ITER_CONTENT+="$(cat "$iter_file")"$'\n\n---\n\n'
  ITER_COUNT=$((ITER_COUNT + 1))
done

log "Collected $ITER_COUNT iteration files"

# ── Read state metadata ───────────────────────────────────────────────────────
TOPIC=$(jq -r .topic "$STATE_FILE")
THREAD_ID=$(jq -r '.threadId // ""' "$STATE_FILE")
DIRECTOR_CRON_ID=$(jq -r '.directorCronId // ""' "$STATE_FILE")
AUTONOMY=$(jq -r .autonomyLevel "$STATE_FILE")
STARTED_AT=$(jq -r .startedAt "$STATE_FILE")
TOTAL_STALLS=$(jq -r '.totalStalls // 0' "$STATE_FILE")
CONSECUTIVE_STALLS=$(jq -r '.consecutiveStalls // 0' "$STATE_FILE")
TOTAL_STALL_MIN=$(jq -r '.totalStallMinutes // 0' "$STATE_FILE")
ERROR_COUNT=$(jq -r '.errorCount // 0' "$STATE_FILE")
MUTATIONS_COUNT=$(jq -r '.mutations | length' "$STATE_FILE")
GOALS_TOTAL=$(jq -r '.goals | length' "$SPRINT_PATH/goals.json" 2>/dev/null || echo 0)
GOALS_COMPLETED=$(jq -r '.completedGoals | length' "$STATE_FILE")
NOW=$(date -u -Iseconds)
NOW_EPOCH=$(date -u +%s)

# ── Write SPRINT-REPORT.md ────────────────────────────────────────────────────
cat > "$REPORT_FILE.tmp" << REPORT
# Sprint Report: $TOPIC
**Sprint ID:** $SPRINT_ID
**Trigger:** $TRIGGER
**Started:** $STARTED_AT
**Completed:** $NOW
**Iterations:** $ITER_COUNT
**Goals:** $GOALS_COMPLETED / $GOALS_TOTAL completed
**Stalls:** $TOTAL_STALLS total ($TOTAL_STALL_MIN min stall time)
**Mutations:** $MUTATIONS_COUNT proposed
**Autonomy:** $AUTONOMY

---

## Executive Summary

$(if [[ $ITER_COUNT -eq 0 ]]; then
  echo "Sprint ended with no completed iterations."
elif [[ "$TRIGGER" == "stall" || "$TRIGGER" == "mutation_timeout" ]]; then
  echo "Sprint was invalidated after $TOTAL_STALLS stalls or mutation timeout."
else
  echo "Sprint completed $ITER_COUNT iterations on topic: $TOPIC."
fi)

---

## Iteration Output

$ITER_CONTENT

---

## Goal Status

$(jq -r '.goals[] | "- [\(.status)] \(.id): \(.title)"' "$SPRINT_PATH/goals.json" 2>/dev/null || echo "(no goals defined)")

---

## Mutations

$(jq -r '.mutations[]? | "- Iter \(.at_iteration): [\(.goal_id)] \(.old_title) → \(.new_title) (acked: \(.acked))"' "$STATE_FILE" 2>/dev/null || echo "(none)")

---

## Next Sprint Options

1. Continue: Deepen work on "$TOPIC" — focus on unfinished goals
2. Pivot: Apply findings to a related problem area
3. Archive: Work is complete; no follow-up needed

*(Operator decides — no auto-scheduling)*

---

## Artifacts

$(find "$SPRINT_PATH" -maxdepth 1 -name "iter-*.md" -exec basename {} \; | sort 2>/dev/null || echo "(none)")
REPORT

mv "$REPORT_FILE.tmp" "$REPORT_FILE"
log "SPRINT-REPORT.md written ($(wc -c < "$REPORT_FILE") bytes)"

# ── Memory digest (≤512 bytes) ────────────────────────────────────────────────
MEMORY_FILE="$WORKSPACE/memory/$(date -u +%Y-%m-%d).md"
mkdir -p "$(dirname "$MEMORY_FILE")"
DIGEST="Sprint $SPRINT_ID on \"$TOPIC\" — $ITER_COUNT iterations, $GOALS_COMPLETED/$GOALS_TOTAL goals. Report: data/sprints/$SPRINT_ID/SPRINT-REPORT.md"
# Truncate digest to 512 bytes
DIGEST="${DIGEST:0:512}"
echo "" >> "$MEMORY_FILE"
echo "## [$(date -u +%H:%M)] sprint-synthesize — Sprint complete: $TOPIC" >> "$MEMORY_FILE"
echo "- $DIGEST" >> "$MEMORY_FILE"
log "Memory digest written to $MEMORY_FILE"

# ── P1: Post full report to Discord thread ───────────────────────────────────
DISCORD_SCRIPT="$WORKSPACE/scripts/discord/discord-send-message.js"

if [[ -n "$THREAD_ID" && "$THREAD_ID" != "null" && -f "$REPORT_FILE" ]]; then
  REPORT_CONTENT=$(cat "$REPORT_FILE")
  # Truncate to Discord message limit if needed (4000 char for thread reply safety)
  REPORT_DISPLAY="${REPORT_CONTENT:0:3800}"
  if [[ ${#REPORT_CONTENT} -gt 3800 ]]; then
    REPORT_DISPLAY+=$'\n\n[Report truncated — full report saved to disk]'
  fi
  DISCORD_BOT_TOKEN="$DISCORD_BOT_TOKEN_CLUE_MASTER" node "$DISCORD_SCRIPT" "$THREAD_ID" \
    "$(printf '📋 **Sprint Complete: %s**\n\n%s' "$TOPIC" "$REPORT_DISPLAY")" 2>/dev/null || true
fi

# ── P1: Post next sprint suggestions to Discord thread ──────────────────────
if [[ -n "$THREAD_ID" && "$THREAD_ID" != "null" ]]; then
  DISCORD_BOT_TOKEN="$DISCORD_BOT_TOKEN_CLUE_MASTER" node "$DISCORD_SCRIPT" "$THREAD_ID" \
    "$(printf '🎯 **Next Sprint Options** — No auto-scheduling. Operator decides:\n\n1. **Continue:** Deepen work on \"%s\"\n2. **Pivot:** Apply findings to related problem\n3. **Archive:** Work complete; no follow-up needed' "$TOPIC")" 2>/dev/null || true
fi

# ── Bus: agent_done ───────────────────────────────────────────────────────────
if [[ -f "$EVENT_BUS" ]]; then
  printf '{"timestamp":"%s","agent":"sprint-synthesize","type":"agent_done","label":"sprint-%s","data":{"sprint_id":"%s","thread_id":"%s","goals_completed":%d,"iterations":%d}}\n' \
    "$(date -u -Iseconds)" "$SPRINT_ID" "$SPRINT_ID" "$THREAD_ID" "$GOALS_COMPLETED" "$ITER_COUNT" \
    >> "$EVENT_BUS"
  log "agent_done emitted to bus"
fi

# ── P1: Cron cleanup (direct via openclaw CLI, not via bus) ──────────────────
if [[ -n "$DIRECTOR_CRON_ID" && "$DIRECTOR_CRON_ID" != "null" ]]; then
  if command -v openclaw &>/dev/null; then
    if openclaw cron delete "$DIRECTOR_CRON_ID" 2>/dev/null; then
      log "Director cron $DIRECTOR_CRON_ID deleted"
    else
      log "WARN: cron delete failed for $DIRECTOR_CRON_ID — manual: openclaw cron delete $DIRECTOR_CRON_ID"
      echo "⚠️ Manual action required: openclaw cron delete $DIRECTOR_CRON_ID" 2>&1
    fi
  else
    log "WARN: openclaw CLI not found — manually delete cron $DIRECTOR_CRON_ID"
    echo "⚠️ Manual action required: openclaw cron delete $DIRECTOR_CRON_ID" 2>&1
  fi
else
  log "No directorCronId found — skipping cron cleanup"
fi

# ── Update active-threads.json (real schema, keyed by threadId) ───────────────
# H1: Fixed double-flock deadlock. Acquire lock once, check return code, then do work.
if [[ -n "$THREAD_ID" && "$THREAD_ID" != "null" ]]; then
  exec 9>"$ACTIVE_THREADS.lock"
  if flock -e -w 30 9; then
    jq --arg tid "$THREAD_ID" '(.threads[] | select(.id == $tid)).status = "sprint_complete"' \
      "$ACTIVE_THREADS" > "$ACTIVE_THREADS.tmp" && mv "$ACTIVE_THREADS.tmp" "$ACTIVE_THREADS"
    flock -u 9; exec 9>&-
    log "active-threads.json updated: $THREAD_ID → sprint_complete"
  else
    log "WARN: active-threads lock timeout — skipping status update"
    exec 9>&-
  fi
fi

# Update sprint-registry.json
if [[ -f "$SPRINT_REGISTRY" ]]; then
  jq --arg sid "$SPRINT_ID" '.[$sid].status = "complete"' \
    "$SPRINT_REGISTRY" > "$SPRINT_REGISTRY.tmp" && mv "$SPRINT_REGISTRY.tmp" "$SPRINT_REGISTRY"
fi

# ── Telemetry ─────────────────────────────────────────────────────────────────
END_EPOCH=$(date -u +%s)
ELAPSED_MIN=$(( (END_EPOCH - START_EPOCH) / 60 ))

mkdir -p "$(dirname "$SPRINT_RUNS")"
printf '{"sprint_id":"%s","topic":"%s","autonomy_level":"%s","synthesis_trigger":"%s","started_at":"%s","ended_at":"%s","iterations":%d,"consecutive_stalls_max":%d,"total_stalls":%d,"total_stall_minutes":%d,"errors":%d,"goals_total":%d,"goals_completed":%d,"mutations_proposed":%d,"director_cron_deleted":%s,"cost_estimate_tokens":null}\n' \
  "$SPRINT_ID" \
  "$(echo "$TOPIC" | sed 's/"/\\"/g')" \
  "$AUTONOMY" \
  "$TRIGGER" \
  "$STARTED_AT" \
  "$NOW" \
  "$ITER_COUNT" \
  "$CONSECUTIVE_STALLS" \
  "$TOTAL_STALLS" \
  "$TOTAL_STALL_MIN" \
  "$ERROR_COUNT" \
  "$GOALS_TOTAL" \
  "$GOALS_COMPLETED" \
  "$MUTATIONS_COUNT" \
  "$([ -n "$DIRECTOR_CRON_ID" ] && echo true || echo false)" \
  >> "$SPRINT_RUNS"

log "Telemetry written to sprint-runs.jsonl"

# ── Final state update ────────────────────────────────────────────────────────
exec 9>"$SPRINT_PATH/.state.lock"
flock -e -w 30 9 || { log "WARN: could not acquire lock for final state write"; }
jq ".status = \"complete\" | .completedAt = \"$NOW\"" \
  "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
flock -u 9; exec 9>&-

log "Sprint marked complete"
echo ""
echo "✅ Sprint $SPRINT_ID complete"
echo "   Trigger       : $TRIGGER"
echo "   Iterations    : $ITER_COUNT"
echo "   Stalls        : $TOTAL_STALLS ($TOTAL_STALL_MIN min)"
echo "   Goals         : $GOALS_COMPLETED / $GOALS_TOTAL"
echo "   Report        : $REPORT_FILE"
echo "   Telemetry     : $SPRINT_RUNS"
