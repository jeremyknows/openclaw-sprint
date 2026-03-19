# Sprint Skill User Guide

**Table of Contents:**
1. [goals.json Schema](#goalsjson-schema)
2. [Autonomy Levels](#autonomy-levels)
3. [Duration Format](#duration-format)
4. [Monitoring a Running Sprint](#monitoring-a-running-sprint)
5. [Mutation Proposals](#mutation-proposals)
6. [Common Patterns](#common-patterns)

---

## goals.json Schema

The `goals.json` file defines what the sprint is trying to accomplish. It has two parts: **metadata** and **goal list**.

### Schema Definition

```json
{
  "meta_goal": "string (100–500 chars, human-readable description of sprint objective)",
  "goals": [
    {
      "id": "string (G1, G2, ... required for tracking)",
      "title": "string (short goal title, ≤100 chars)",
      "description": "string (optional, detailed explanation, ≤500 chars)",
      "status": "pending|active|complete|blocked|mutated",
      "success_criteria": "string (how do you know this goal is done?)",
      "priority": "p0|p1|p2 (optional, defaults to p0)"
    }
  ]
}
```

### Annotated Example

```json
{
  "meta_goal": "Implement and test Stripe webhook event processing for VeeFriends invoice management",
  
  "goals": [
    {
      "id": "G1",
      "title": "Design webhook schema and event types",
      "description": "Map Stripe webhook events to VeeFriends domain model. Cover invoice.created, invoice.updated, payment_intent.succeeded, charge.refunded.",
      "status": "pending",
      "success_criteria": "Webhook schema document with all event types, required/optional fields, and error handling strategy",
      "priority": "p0"
    },
    {
      "id": "G2",
      "title": "Implement webhook receiver + signature verification",
      "description": "Build Express middleware for /webhooks/stripe endpoint. Implement HMAC signature verification per Stripe docs.",
      "status": "pending",
      "success_criteria": "Webhook receiver code with passing signature verification tests. Handles 100+ req/sec without latency issues.",
      "priority": "p0"
    },
    {
      "id": "G3",
      "title": "Implement event handlers (invoice, payment, refund)",
      "description": "Write handlers for invoice state transitions, payment confirmation, and refund processing. Integrate with existing billing service.",
      "status": "pending",
      "success_criteria": "All three handlers implemented. 10+ integration tests passing. End-to-end Stripe → VeeFriends flow verified.",
      "priority": "p1"
    },
    {
      "id": "G4",
      "title": "Add monitoring, alerts, and admin dashboard",
      "description": "Webhook delivery stats, retry logic, failed event queue. Dashboard shows status, recent events, error rate.",
      "status": "pending",
      "success_criteria": "Admin dashboard deployed. Monitoring alerts configured for delivery failures. SLA: 99% delivery success.",
      "priority": "p1"
    },
    {
      "id": "G5",
      "title": "Write deployment plan and runbook",
      "description": "Procedure for deploying to staging, prod sign-off, rollback plan. Runbook for webhook debugging.",
      "status": "pending",
      "success_criteria": "Deployment doc + runbook. Reviewed by ops. Ready for prod deployment.",
      "priority": "p2"
    }
  ]
}
```

### Best Practices

1. **Break goals into atomic chunks.** Each goal = 1–2 hours of work. "Implement authentication" is too broad; "Implement JWT token generation and verification" is better.
2. **Write clear success criteria.** "Done" is ambiguous. "Unit tests passing + integrated into main service + API working" is clear.
3. **Use priority levels.** P0 = must complete this iteration. P1 = nice to have. P2 = future.
4. **Update status during sprint.** Director reads your updates and adjusts iteration planning. Mark goals `active` when worker starts them.

---

## Autonomy Levels

### low (Default for First Sprint)

**Worker behavior:**
- Reads and analyzes documents, code, APIs
- Generates detailed proposals and recommendations
- Creates analysis documents and design plans
- Proposes code changes but does NOT commit them
- Asks for operator approval before any action

**What it means:**
- Every iteration ends with a recommendation, not an action
- Operator reads output and decides next step
- Useful for research, design exploration, risk analysis
- Safe default when testing a new domain

**Example iteration output (low autonomy):**
```
## Summary
Researched OAuth 2.1 spec and analyzed VeeFriends current auth stack.

## Artifacts
- oauth-2.1-analysis.md (5 KB)
- vf-auth-current-state.md (3 KB)
- recommendation-hybrid-flow.md (7 KB)

## Next
Recommend: Propose OAuth 2.1 + passkey hybrid flow. Awaiting approval to design implementation.
```

---

### medium (Balanced Autonomy)

**Worker behavior:**
- Does everything at `low` level
- Implements non-destructive changes (new features, internal refactors, non-prod deployments)
- Commits code to non-main branches
- Sends internal messages (Discord, logs) but NOT external emails/tweets
- Proposes goal mutations via state.json if direction needs to shift mid-sprint

**What it means:**
- Worker can "ship" internally (commit code, merge feature branches, update internal docs)
- Cannot touch production or send outbound messages without approval
- Can be left alone for 4–8 hours with acceptable risk
- Use after first `low` autonomy sprint proves successful

**Example iteration output (medium autonomy):**
```
## Summary
Implemented OAuth 2.1 flow with passkey fallback. Integration tests passing.

## Artifacts
- /src/auth/oauth-client.ts (180 lines, new)
- /src/auth/passkey-handler.ts (140 lines, new)
- /tests/auth.integration.test.ts (200 lines, new)
- Committed to branch feature/oauth-2.1-hybrid (PR #247)

## Next
Ready for code review. Recommend next iteration: database migration for passkey storage + user signup flow.
```

---

### high (Autonomous Overnight)

**Worker behavior:**
- Does everything at `medium` level
- Can deploy code to production (if tests passing and no rollback risk detected)
- Can send external communications (Slack announcements, emails to small teams)
- Has wider decision-making authority

**What it means:**
- Minimal oversight — checks happen at synthesis time, not during execution
- Expect to wake up to completed work
- Use ONLY after 2+ successful `medium` sprints with >80% goal completion
- Still cannot: post to Twitter/X, send major announcements, delete data, modify billing systems

**Example iteration output (high autonomy):**
```
## Summary
Implemented and deployed rate limiting middleware. Rolled out to 5% of traffic, monitoring healthy.

## Artifacts
- src/middleware/rate-limiter.ts (250 lines)
- tests/rate-limiter.test.ts (180 lines)
- Merged to main, deployed to prod-staging
- Monitoring dashboard: https://monitoring.vf/rate-limit

## Next
Ramping traffic to 100%. Stalling rate limiter status check — recommend human review before full rollout.
```

---

## Duration Format

Sprints accept flexible duration syntax. Format: `<value><unit>`

### Supported Units

| Unit | Meaning | Example |
|------|---------|---------|
| `m` | Minutes | `30m` (30 minutes) |
| `h` | Hours | `4h` (4 hours) |
| `d` | Days | `2d` (48 hours) |
| `overnight` | 8 hours, aligned to tomorrow morning | `overnight` |

### Examples

```bash
# Quick research sprint
--duration "2h"

# Standard feature work
--duration "4h"

# Extended session
--duration "8h"

# Overnight deep work
--duration "overnight"

# Multi-day project
--duration "2d"

# Precise: 90 minutes
--duration "90m"
```

---

## Monitoring a Running Sprint

### 1. Check Status

```bash
cat ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/state.json | jq '.'
```

**Key fields to watch:**

```json
{
  "status": "active",           // active|worker_spawned|synthesizing|complete
  "iterationCount": 3,          // How many iterations have run
  "consecutiveStalls": 0,       // Consecutive timeouts. >3 escalates.
  "completedGoals": ["G1", "G2"],
  "mutations": [],              // Proposed goal changes (pending ACK)
  "startedAt": "ISO timestamp",
  "endsAt": "ISO timestamp"
}
```

**Interpretation:**
- `status = "active"` → working normally
- `status = "worker_spawned"` → waiting for iteration output
- `consecutiveStalls = 2` → watch closely, worker may be stuck
- `completedGoals = ["G1"]` → goal progress visible (good sign)

---

### 2. Read Latest Iteration

```bash
cat ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/iter-3.md
```

**Expected structure:**
```markdown
## Summary
[What the worker did this iteration]

## Artifacts
[Files created, code written, analysis performed]

## Next
[Recommended next steps or blockers]
```

**Watch for:**
- Artifacts getting created (file size increasing)
- Clear summaries (worker is making progress)
- Blockers in "Next" section (may need human intervention)

---

### 3. Watch Progress Timeline

Director creates iteration files on schedule:
- Iteration N starts → `iter-N-start.log` created
- Worker runs for ~10 minutes
- Director waits for `iter-N.md` (610 second timeout)
- File appears → iteration complete, state updated

**Timeline interpretation:**
```
iter-1.md (100 bytes)   ← Iteration 1 complete
iter-2.md (250 bytes)   ← Iteration 2 larger, more work done
iter-3.md (2000 bytes)  ← Iteration 3 much larger—productive iteration
(no iter-4 yet, director.log shows consecutiveStalls=1)
```

Growing file sizes = accumulating outputs. Stable sizes = refining existing work.

---

### 4. Read Discord Thread Updates

Sprint automatically posts to `#watson-main`:
- **Iteration N complete:** Timestamp + summary of what got done
- **Mutation proposed:** Goal change suggestion + waiting for operator ✅ reaction
- **Stall escalated:** Iteration N timed out, manual intervention recommended
- **Sprint complete:** Final summary + link to SPRINT-REPORT.md

**Discord reactions you can use:**
- ✅ (check mark) = ACK the mutation, worker will proceed
- ❌ (X mark) = Reject the mutation, worker will ignore it
- 🔄 (refresh) = Re-run last iteration (if stuck)

---

### 5. Monitor Stall Counter

Check `director.log`:

```bash
tail -20 ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/director.log
```

**Healthy log:**
```
[2026-03-18T12:00:00Z] Iteration 1: spawned worker, waiting for iter-1.md
[2026-03-18T12:10:30Z] Iteration 1: complete (iter-1.md received, 183 bytes)
[2026-03-18T12:20:00Z] Iteration 2: spawned worker, waiting for iter-2.md
[2026-03-18T12:30:15Z] Iteration 2: complete (iter-2.md received, 527 bytes)
```

**Concerning log:**
```
[2026-03-18T12:00:00Z] Iteration 1: spawned worker, waiting for iter-1.md
[2026-03-18T12:10:30Z] Iteration 1: TIMEOUT (iter-1.md never received) — stall count: 1
[2026-03-18T12:20:00Z] Iteration 2: spawned worker, waiting for iter-2.md
[2026-03-18T12:30:30Z] Iteration 2: TIMEOUT (iter-1.md never received) — stall count: 2
```

**Action:**
- Stall count = 1–2: Monitor. May be normal slowness.
- Stall count = 3: Escalated to Discord. Check worker logs.
- Stall count > 5: Sprint may be invalidated. Manual recovery needed.

---

## Mutation Proposals

A **mutation** is a goal change proposed mid-sprint by the director. Example:

- Original goal G3: "Implement caching layer"
- Worker discovers: Caching is blocked on database schema change
- Director proposes mutation: "Shift G3 to G3b: Design new database schema for caching support"

### How Mutations Work

1. **Director proposes mutation** → Added to `state.json.mutations[]`
2. **Posted to Discord** → Thread shows "Goal G3 mutation proposed: [details]"
3. **Operator reacts** → ✅ (ACK) or ❌ (reject)
4. **Next iteration** → Worker sees mutation, updates goals.json accordingly

### Proposing a Manual Mutation

If you want to change goals mid-sprint:

1. Edit `goals.json` directly:
```json
{
  "id": "G3",
  "title": "OLD TITLE",
  "status": "mutated",
  "mutation": {
    "proposedBy": "operator",
    "reason": "Blocked on schema design—deferring to next sprint",
    "newGoal": {
      "id": "G3b",
      "title": "Assess caching feasibility with current schema"
    }
  }
}
```

2. Post to Discord: `@watson Mutation ACK: Replace G3 with G3b (deferring schema work)`
3. Director picks it up at next iteration

---

## Common Patterns

### Pattern 1: Research Sprint (No Code)

**Goal:** Understand a topic deeply in 2–3 hours.

```json
{
  "meta_goal": "Research and recommend password-less auth patterns for VeeFriends",
  "goals": [
    {
      "id": "G1",
      "title": "Research WebAuthn / FIDO2 standards and adoption",
      "success_criteria": "Report on spec, browser support, user experience tradeoffs"
    },
    {
      "id": "G2",
      "title": "Analyze VeeFriends current auth + identify migration path",
      "success_criteria": "Migration strategy document with risk assessment"
    },
    {
      "id": "G3",
      "title": "Compare solutions: Passkeys vs. OTP vs. Magic links",
      "success_criteria": "Decision matrix with security, cost, and UX scores"
    }
  ]
}
```

**Settings:**
```bash
--autonomy-level "low"
--duration "3h"
```

**Expected output:**
- Iteration 1: Analysis of standards + research findings
- Iteration 2: Assessment of VeeFriends fit
- Iteration 3: Comparison matrix + recommendation
- Synthesis: Executive summary with decision ready for review

---

### Pattern 2: Implementation Sprint (Feature)

**Goal:** Implement a feature end-to-end in 6 hours.

```json
{
  "meta_goal": "Implement Redis-backed session caching for API auth",
  "goals": [
    {
      "id": "G1",
      "title": "Design session schema and Redis key structure",
      "priority": "p0"
    },
    {
      "id": "G2",
      "title": "Implement session store (read/write/delete/TTL)",
      "priority": "p0"
    },
    {
      "id": "G3",
      "title": "Integrate into auth middleware + test",
      "priority": "p0"
    },
    {
      "id": "G4",
      "title": "Add monitoring and cache invalidation logic",
      "priority": "p1"
    }
  ]
}
```

**Settings:**
```bash
--autonomy-level "medium"
--duration "6h"
```

**Expected output:**
- Iteration 1: Schema design, Redis setup
- Iteration 2: Store implementation + unit tests
- Iteration 3: Auth middleware integration
- Iteration 4: Monitoring + cache invalidation
- Iteration 5: E2E testing + deployment plan
- Synthesis: PR ready for review, deployment checklist

---

### Pattern 3: Analysis Sprint (High-Risk Decision)

**Goal:** Assess a major decision (e.g., tech migration, vendor choice) in 4 hours.

```json
{
  "meta_goal": "Assess feasibility and risk of migrating from MongoDB to Postgres",
  "goals": [
    {
      "id": "G1",
      "title": "Map current MongoDB schema to Postgres relational model",
      "priority": "p0"
    },
    {
      "id": "G2",
      "title": "Identify data migration challenges and risk areas",
      "priority": "p0"
    },
    {
      "id": "G3",
      "title": "Estimate effort, timeline, and resource requirements",
      "priority": "p0"
    },
    {
      "id": "G4",
      "title": "Create executive summary with recommendation",
      "priority": "p0"
    }
  ]
}
```

**Settings:**
```bash
--autonomy-level "low"
--duration "4h"
```

**Expected output:**
- Detailed analysis doc
- Risk matrix
- Timeline estimate
- Clear recommendation (migrate / stay / hybrid approach)
- Ready for executive review

---

## Troubleshooting Basics

**Sprint not starting?**
```bash
cat ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/init.log
```

**Worker not producing output?**
```bash
ls -la ~/.openclaw/agents/main/workspace/data/sprints/<sprint-id>/
# Should see iter-1.md after 10 minutes
```

**Stalled and need to restart?**
See **TROUBLESHOOTING.md** for recovery procedures.

---

## Next Steps

- **See TROUBLESHOOTING.md** for failure recovery
- **See SKILL.md** for quickstart and full reference
- **Check discord.com in #watson-main** for sprint thread updates
