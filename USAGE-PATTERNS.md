# Sprint Skill — Usage Patterns

Extended usage patterns extracted from SKILL.md (Gotchas #9-14, v0.3.0).
For hard constraints and failure traps, see `SKILL.md § Known Limitations & Gotchas`.

---

## Pattern 1: Synthesis requires at least 1 iter-N.md

If all workers time out and no iterations complete, synthesis produces an empty report. The sprint is not retried automatically. Check `director.log` if synthesis is empty — the director may never have run.

---

## Pattern 2: Sprint data lives in data/sprints/ indefinitely

No auto-archiving or TTL. Archive manually after reviewing SPRINT-REPORT.md, or disk fills slowly. Suggested: archive sprints older than 30 days to `data/sprints/archive/`.

---

## Pattern 3: iter-N.md completion ≠ output quality

Workers mark goals "complete" and write iter files even when output is low-quality (e.g., sourced from web synthesis instead of the actual target artifact). The state machine cannot distinguish good output from bad.

For analysis tasks: always define explicit quality criteria in the goal (e.g., "must cite specific page numbers," "must include direct quotes"). Director-side section validation (v0.8+) now checks for required sections (`## Summary`, `## Artifacts`, `## Next`) and counts missing sections as stalls.

---

## Pattern 4: External preprocessing must happen before sprint init

File conversion, API calls, build steps — must be completed before sprint init, not inside worker prompts. Workers cannot reliably detect missing prerequisites (e.g., PDFs not yet rendered to PNG). A missing prerequisite causes silent fallback to web synthesis — indistinguishable from a successful run until you inspect file size and content.

Run all pre-flight steps in sprint-init or manually before launching. *Surfaced: DoDo Comic Deep Analysis Sprint, Mar 26 2026.*

---

## Pattern 5: Write a context handoff before ending a multi-session sprint

Without a handoff, session 2 starts cold and must reconstruct state from memory, re-inspect files, and determine what needs re-running. Estimated recovery cost: ~45 minutes.

After any session that doesn't complete the sprint, write a `context-handoff-YYYY-MM-DD.md` in the sprint dir covering:
- What's done (which goals, which iter files are good)
- What's bad and needs re-run (with specific quality failure reason)
- What's next (which goal to tackle, in what order)
- Any open questions or blockers

*Surfaced: DoDo Comic Deep Analysis Sprint, Mar 26 2026.*

---

## Pattern 6: Workers see only the current goal (v0.8+)

As of v0.8, each worker receives only the first pending goal (not the full list). This prevents workers from picking the easiest goal and skipping harder ones. Workers also receive a read-only list of completed goals to avoid re-doing finished work.

If you're running a sprint with interdependent goals, write goals in dependency order in goals.json — workers always tackle the first pending goal.
