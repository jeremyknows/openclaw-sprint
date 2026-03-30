# Sprint Skill — Gotchas & Lessons Learned

Compiled from the VeeFriends Comic Deep Analysis Sprint (2026-03-26). These are real problems that burned real time. Read before running your first sprint.

---

## Gotcha 1: Manual `sprint-director.sh` Doesn't Actually Spawn Workers

**What happened:** DoDo ran `sprint-director.sh` manually from its session. The script output `SPAWN_WORKER` JSON to stdout — but nothing happened. The worker was never created. 22 minutes wasted waiting for a worker that didn't exist.

**Why:** The `SPAWN_WORKER` signal is meant to be *caught by Watson's cron agent turn*, which calls `sessions_spawn`. When run in a shell or a non-Watson session, the signal prints to stdout and is ignored. Only the cron agent has permission to spawn subagent sessions.

**Fix:** Never run `sprint-director.sh` manually to start a sprint. Use `sprint-init.sh` which registers the cron, then let the cron handle all worker spawning. If the first cron tick hasn't fired yet, wait — don't try to trigger manually.

**Prevention:** Add a check at the top of `sprint-director.sh`: if not running inside a cron agent context, warn and exit.

---

## Gotcha 2: Thread ID is a Placeholder String, Not a Real Discord Thread

**What happened:** `sprint-init.sh` set `threadId` in state.json to `sprint-20260326-veefriends-canon-com-placeholder` — a literal string, not a Discord thread ID. All sprint progress notifications (iteration complete, stall alerts, final report) were posted to a non-existent thread. Nobody saw them.

**Why:** The init script doesn't create a Discord thread. It writes a placeholder expecting the first director run to create the thread. But if the director doesn't handle thread creation, the placeholder persists forever.

**Fix:** After running `sprint-init.sh`, immediately create a real Discord thread and patch the thread ID into `state.json` and `active-threads.json`:
```bash
# Create thread in the agent's home channel, then:
jq '.threadId = "<real-thread-id>"' state.json > tmp && mv tmp state.json
```

**Prevention:** `sprint-init.sh` should create the Discord thread as part of initialization, not defer to the director.

---

## Gotcha 3: Workers Ignore Instructions When Content is Hard to Access

**What happened:** Workers were instructed to read PNG page images from `/tmp/vf-comic-<KEY>/page-NN.png`. Instead, they defaulted to web search and blog sources because the PDFs "seemed hard to read." This happened on 4 consecutive iterations (CB#1-5) despite increasingly forceful instructions.

**Why:** LLM agents have a training prior: when content seems inaccessible (large binary files, images), fall back to web search for authoritative sources. Written instructions can't always override this behavior. The worker "rationalized around" the instructions — it acknowledged them but chose the easier path.

**Fix:** Pre-read the content yourself and embed it directly into the worker context. Don't ask the worker to access difficult content — give it to them pre-digested. DoDo eventually switched to reading all pages directly and writing the analysis itself, bypassing the worker entirely.

**Prevention:** For sprints involving file-reading tasks (PDFs, images, large files):
1. Pre-extract the content before the sprint starts
2. Embed extracted text directly in the worker context file
3. Or have the director agent do the reading and pass content to the worker as inline text

---

## Gotcha 4: `meta_goal` in goals.json Gets Stale After Strategy Changes

**What happened:** The initial `meta_goal` said "read ONE PDF per issue." After discovering PDFs were image-only, the strategy changed to "read PNGs." But the meta_goal was already baked into all pre-generated worker context files. Workers kept following the stale instruction.

**Why:** `goals.json` is read once during init. Worker context files are pre-generated. Updating the strategy mid-sprint requires patching both `goals.json` AND all already-generated `worker-context-N.txt` files.

**Fix:** After any strategy change:
1. Update `goals.json` meta_goal
2. Check and patch ALL existing `worker-context-*.txt` files
3. Update `WORKER-INSTRUCTIONS.md` for future workers

**Prevention:** Keep `meta_goal` generic. Put specific instructions in `WORKER-INSTRUCTIONS.md` which is read fresh each iteration, not baked in at init time.

---

## Gotcha 5: Cron Idempotency Guard Blocks Recovery

**What happened:** After the false worker spawn (Gotcha 1), state was stuck at `worker_spawned`. The next cron tick saw this status and backed off (correct idempotency behavior). But the worker didn't exist — so the sprint was stuck indefinitely.

**Why:** The idempotency guard prevents duplicate workers but doesn't verify the worker actually exists. If a spawn fails silently, the guard permanently blocks progress.

**Fix:** Manually reset state to `active` and iteration count to the last completed:
```bash
jq '.status = "active" | .iterationCount = 0' state.json > tmp && mv tmp state.json
```

**Prevention:** The director should verify the worker session exists (via `sessions_list`) before accepting `worker_spawned` status. If no matching session found after 5 minutes, auto-reset to `active`.

---

## Gotcha 6: Skill Scope Not Configured for Non-Watson Agents

**What happened:** DoDo couldn't find the sprint skill in its system prompt. The skill was at `~/.openclaw/skills/sprint/` but DoDo's skill injection scope only covered `~/.openclaw/agents/dodo/workspace/`. DoDo had to read the skill manually instead of auto-discovering it.

**Why:** OpenClaw's skill injection is configured per-agent. New skills added to the global `~/.openclaw/skills/` directory aren't automatically available to all agents — each agent needs its scope updated.

**Fix:** Add `~/.openclaw/skills/` to each agent's skill injection path in the gateway config. Or copy the skill to the agent's workspace.

**Prevention:** When publishing a skill to `~/.openclaw/skills/`, also update `agents.defaults.skillPaths` in `openclaw.json` to include the global skills directory.

---

## Gotcha 7: Large Attachments (>25MB) Cause Worker Timeouts

**What happened:** Jeremy sent a 124MB zip file via Discord. DoDo's inbound worker tried to process it for 30 minutes (1800s timeout) and timed out. DoDo went non-responsive.

**Why:** The gateway's Discord inbound handler tries to download and process all attachments before passing the message to the agent. Large files exceed the timeout.

**Fix:** Don't send large files via Discord. Place them directly on disk and tell the agent the file path in a text message.

**Prevention:** If a sprint requires large file inputs, stage them in the agent's workspace BEFORE starting the sprint. Reference file paths in `goals.json`, not Discord attachments.

---

## Gotcha 8: `[DETAIL NEEDED FROM PANELS]` Placeholders Slip Through

**What happened:** Workers wrote analysis files with `[DETAIL NEEDED FROM PANELS]` placeholder tags — admitting they couldn't read the content but submitting the file anyway. The recall test passed (the file existed and contained keywords), so the iteration was marked "complete" despite having gaps.

**Why:** The recall test checks findability, not completeness. A file full of placeholders is "findable" but useless.

**Fix:** Add a completeness check to the director's post-iteration validation:
```bash
if grep -q "\[DETAIL NEEDED" "$ANALYSIS_FILE"; then
  echo "FAIL: placeholders found"
  # Reset iteration, don't advance
fi
```

**Prevention:** Add to `WORKER-INSTRUCTIONS.md`: "Any occurrence of `[DETAIL NEEDED FROM PANELS]` in your output = automatic iteration failure. You must attempt to read the content. If genuinely unreadable, write what you CAN determine and mark as [UNREADABLE] with an explanation."

---

## Gotcha 9: Sprint Duration Needs Buffer

**What happened:** Initial duration was "overnight" (until 6PM ET). After burning 22 minutes on the false start plus debugging, the effective sprint time was shorter than planned. Had to extend to midnight.

**Why:** Sprints encounter unexpected problems. The initial estimate assumes everything works first try.

**Fix:** Always add 50% buffer to estimated duration. If you think 13 iterations × 20 minutes = 4.3 hours, set duration to 8 hours.

**Prevention:** `sprint-init.sh` should default to generous durations. Better to finish early than run out of time.

---

## Gotcha 10: Director Cron Keeps Spawning Workers After You Take Over

**What happened:** After DoDo took over manually (reading pages directly instead of using workers), the director cron kept firing every 20 minutes and spawning new workers. These workers tried to write to the same analysis files DoDo was already writing — creating conflicts mid-session.

**Why:** The director has no concept of "the agent took over." It sees `status: active` and spawns workers on schedule regardless of whether someone is already doing the work.

**Fix:** When taking over from workers, immediately set sprint status to `paused` or update state to skip the current iteration:
```bash
jq '.status = "paused"' state.json > tmp && mv tmp state.json
```
Resume when you're done with the manual iteration.

**Prevention:** The director should check if the current iteration's output file already exists before spawning a worker.

---

## Gotcha 11: State Machine Can't Judge Output Quality

**What happened:** Workers produced analysis files with placeholder tags, blog-synthesized content instead of panel reads, and incomplete coverage. The sprint state machine marked these iterations as "complete" because the file existed and the worker session ended. No quality check occurred.

**Why:** The director's completion check is binary: did the worker finish? Did it write a file? It doesn't verify content quality, check for placeholder tags, or validate against success criteria.

**Fix:** Add post-iteration quality gates in the director:
- Check for `[DETAIL NEEDED FROM PANELS]` or `[UNREADABLE]` markers
- Verify minimum file size (e.g., >5KB for a comic analysis)
- Optionally: run a quick LLM check against the goal's success criteria

**Prevention:** Build quality validation into `sprint-director.sh` as a mandatory step between worker completion and state advancement.

---

## Gotcha 12: No Context Handoff Between Sessions = Expensive Cold Restart

**What happened:** DoDo's session hit context limits and had to restart mid-sprint. The new session had no knowledge of what was already done, what strategies worked/failed, or the current sprint state. ~45 minutes spent reconstructing context that could have been preserved.

**Why:** The sprint skill doesn't write a checkpoint file when a session ends. The next session starts from scratch, reading state.json but missing all the learned context (which workers failed, why, what strategy changes were made).

**Fix:** Add a mandatory checkpoint at session end (or before compaction):
```bash
# Write sprint-checkpoint.md with:
# - Current iteration + what's been done
# - Strategy changes made mid-sprint
# - Known issues with remaining goals
# - What worked vs what didn't
```

**Prevention:** Add a `checkpoint` command to the guard/director that writes a markdown file. Make it part of the session end trap. New sessions read the checkpoint first.

---

## Gotcha 13: Vague Goals Produce Bad Output — Specificity is Everything

**What happened:** Early iterations used generic goals like "analyze this comic." Workers produced surface-level summaries from blog posts. When goals were rewritten with explicit questions ("Does the comic address Gary Bee's connection to GaryVee explicitly or implicitly?") and citation requirements ("all claims must reference page numbers"), output quality jumped dramatically.

**Why:** LLM workers optimize for "completing the task." A vague task is easy to complete badly. A specific task with testable criteria forces deeper work.

**Fix:** Every goal in `goals.json` should read like a test:
- Ask specific questions the worker must answer
- Require page/panel citations for every claim
- Define minimum output length
- List what "done" looks like concretely

**Prevention:** Before launching a sprint, review each goal and ask: "Could a lazy worker mark this complete with a 200-word blog summary?" If yes, the goal isn't specific enough.

---

## Summary: The Three Rules

1. **Don't manually trigger what cron should handle.** The sprint skill is designed for cron-driven execution. Manual intervention causes state mismatches.

2. **Don't ask workers to access difficult content — give it to them.** Pre-extract, pre-read, embed inline. Workers will take the easy path every time.

3. **Verify, don't trust.** Check thread IDs are real. Check workers actually spawned. Check output doesn't have placeholders. The sprint framework has no built-in validation for these — you have to add it.
