# Sprint Design Guide

> **Read this before writing goals.json.** Mechanics are in SKILL.md. This is about judgment.

Sprint quality is determined almost entirely by design decisions made before `sprint-init` runs. Workers are powerful but blind — they execute exactly what you hand them with exactly the context you provide. This guide covers how to make those decisions well.

---

## The Core Mental Model

A sprint is not "tell an agent to figure it out." It's closer to commissioning a graded test.

Each goal is a test question handed to a worker with no memory of prior conversation, no access to your intent, and no ability to ask clarifying questions. The worker will produce *something* — the question is whether that something is what you needed.

**Workers are not judged on effort. They're judged on output.** Design accordingly.

---

## Step 1: Is This Sprint-Worthy?

Sprint is the right tool when all three are true:
1. **The work is concrete and bounded** — you can describe the done state in one sentence
2. **You want unattended execution** — you don't need to make decisions mid-run
3. **The work is decomposable** — it can be split into 3-6 independent tasks

Sprint is the wrong tool when:
- You're exploring ("figure out what's interesting about X")
- Each step depends on interpreting the previous one
- You need judgment calls that only you can make
- The work is primarily external actions (emails, deployments, posts)

If you're unsure: write the first goal. If you can't make it concrete, the topic isn't ready.

---

## Step 1.5: Can You Write the Goals Yet? (Discovery Goals)

If you can't write the done state in one concrete sentence, the topic isn't ready for a standard sprint. Don't force it — use a **discovery goal** instead.

A discovery goal (`"type": "discovery"`) is a special first goal that lets a worker scope the sprint for you:

```json
{
  "id": "G0",
  "type": "discovery",
  "title": "Scan the codebase for tech debt and write goal-proposals.json with 3-4 specific actionable goals",
  "status": "pending"
}
```

The worker scans/researches and writes `goal-proposals.json` to the sprint directory. The director reads it on the next cycle and merges the proposed goals into `state.json` with `"depends_on": ["G0"]` automatically set.

**When to use discovery:**
- Topic is vague ("improve security", "reduce tech debt", "analyze performance")
- You know the domain but not the specific problems
- You want the first cycle to surface what's worth doing

**When NOT to use discovery:**
- You already know the specific deliverables — write them directly
- You need output by a hard deadline — discovery burns one cycle
- The topic is self-contained enough to write 3+ concrete goals right now

---

## Step 2: Define the Done State First

Before writing any goals, write this sentence:

> "This sprint is successful when ___."

Examples:
- ✅ "...we have a complete character index for CB#1-7 with page citations for every entry"
- ✅ "...sprint-director.sh passes 3 control runs without stalling or corrupting state.json"
- ❌ "...we understand the comic better"
- ❌ "...we've researched the topic thoroughly"

The done state becomes your synthesis goal (always the last goal). Everything before it is the work to get there.

---

## Step 3: Write Goals That Pass the Verification Test

For each goal, ask: **"Can I verify success without reading the iter file?"**

If the answer is no, the goal is too vague.

### The Verification Test in practice

| Goal | Verifiable? | Why |
|------|------------|-----|
| "Analyze CB#1 deeply" | ❌ | "Deeply" is not a state |
| "Extract all named characters from CB#1 with first appearance page and one-sentence description" | ✅ | Count the names, check a page number |
| "Research performance patterns" | ❌ | No output format, no scope |
| "Find 5 React 19 performance patterns, cite the source URL and one concrete code example per pattern" | ✅ | Count to 5, check for code + URL |

### Goal writing formula

```
[Action verb] + [specific artifact] + [scope] + [output format] + [verification criteria]
```

Example:
> "Read all pages of CB#3. Extract every named character who speaks at least one line of dialogue. For each: name, first page they appear, first line of dialogue (exact quote), and whether they appear in CB#1 or CB#2 (yes/no). Output as a markdown table."

---

## Step 4: Resolve All Prerequisites Before Launch

Workers cannot recover from missing inputs. If your goals require:

- A file in a specific format → convert it before `sprint-init`
- An API response → fetch and cache it before `sprint-init`
- A build artifact → build it before `sprint-init`
- A prior sprint's output → confirm the files exist and are complete

Write a **pre-flight checklist** at the top of your goals.json comments or in a `PREFLIGHT.md` in the sprint directory. Run it manually before launching.

**The signal that you missed a prerequisite:** workers produce clean-looking output with no direct quotes, no page citations, and suspiciously small file sizes. Silent fallback to web synthesis is indistinguishable from real work until you inspect the output.

---

## Step 5: Structure Goals for Independence

Workers now receive one goal at a time (v0.8+). That means:

- **Each goal must be completable without reading any other iter file** (unless you explicitly reference it)
- **Goals with dependencies must state them explicitly:**
  > "Using the character list in `iter-1.md` under `## Artifacts`, cross-reference against..."
- **Order goals by dependency**, not by importance — the director always takes the first pending goal

### Goal independence checklist
- [ ] Can this goal be handed to a worker with zero context beyond the sprint topic?
- [ ] Does it reference any other iter file? If yes, is that file guaranteed to exist first?
- [ ] Does it require a specific input file? Is that file confirmed present?

---

## Step 6: Always End with a Validation Goal

Workers cannot catch their own bad output. Without a validation goal, a sprint can complete with 4 of 6 iterations producing fabricated web synthesis and call it done.

**Last goal template:**
> "Review all iter files in this sprint directory (iter-1.md through iter-N.md). For each: confirm it contains the required sections (## Summary, ## Artifacts, ## Next). Flag any that appear to be web synthesis rather than direct analysis (indicators: no direct quotes, no page numbers, generic language, file under 3KB). List any goals that appear to need re-running and why."

Adjust the validation criteria to match what your specific goals were supposed to produce.

---

## Step 7: Choose Autonomy Level Intentionally

| Level | When to use | What it means |
|-------|------------|---------------|
| `low` | First sprint on a new topic; unfamiliar territory | Director pings for approval before mutating goals |
| `medium` | Default; known topic, defined goals | Director can mutate low-risk goals, flags high-risk |
| `high` | Overnight; fully pre-defined goals.json | Director mutates autonomously; no human ACK required |

**If you're going overnight:** set `high` AND pre-define every goal in goals.json. Goal mutations blocked on human ACK + away from Discord = stalled sprint.

---

## The Goals.json Template

```json
{
  "topic": "One sentence describing what this sprint produces",
  "done_state": "This sprint is successful when ___",
  "preflight": [
    "File X exists at path Y",
    "API response cached at Z"
  ],
  "goals": [
    {
      "id": "g1",
      "title": "Short label",
      "prompt": "Full goal text. Action + artifact + scope + output format + verification criteria.",
      "success_criteria": "One sentence: how you'll verify this is done correctly"
    },
    {
      "id": "g2",
      "title": "Short label",
      "prompt": "...",
      "success_criteria": "..."
    },
    {
      "id": "gN",
      "title": "Validate all iterations",
      "prompt": "Review all iter files. Flag any missing required sections or appearing to be web synthesis rather than direct analysis. List any goals needing re-run.",
      "success_criteria": "All iters reviewed, clear pass/fail verdict per iter"
    }
  ]
}
```

---

## Red Flags: Signs Your Design Will Fail

| Signal | Problem | Fix |
|--------|---------|-----|
| Goal contains the word "explore" or "research broadly" | No verification criteria | Rewrite with specific output format |
| Goals list more than 6 items | Too broad; sprint will run long | Scope down or split into two sprints |
| No final validation goal | Bad output will ship undetected | Add validation as last goal |
| Goals reference files not yet confirmed to exist | Silent fallback to web synthesis | Run pre-flight checks first |
| Done state is a feeling ("understand X better") | Unverifiable | Rewrite as a concrete artifact |
| First goal is "research background" | Too vague, burns an iteration | Skip background — workers can look things up inline |

---

## Quick Reference

```
Before launch:
  1. Write the done state in one sentence
  2. Write goals as graded tests (verifiable by counting/checking)
  3. Confirm all prerequisites exist
  4. Make goals independent (or explicit about dependencies)
  5. Add a validation goal as the last goal
  6. Choose autonomy level based on your availability

During sprint:
  - Check director.log if workers seem to be stalling
  - Don't take over mid-sprint without setting state.json status: "paused"

After sprint:
  - Read the validation iter first
  - Check any flagged iters against success_criteria
  - Archive the sprint dir after review
```
