# Runbook: Memory Convention

## Overview

Every bot in Cantrip maintains daily transcript files as persistent memory. This allows bots to retrieve context from previous sessions without loading everything into the context window.

## File Locations

| Bot | Memory Location |
|-----|----------------|
| Manager | `docs/memory/manager/YYYY-MM-DD.md` |
| Workers (per project) | `projects/<name>/.memory/YYYY-MM-DD.md` |

## File Format

Each daily file contains timestamped entries appended after every interaction:

```markdown
# 2026-03-28 — project-name (Worker-1)

## 09:15 — Initial setup

### Input
Build a Next.js landing page with a hero section and contact form.

### Actions
- Ran `npx create-next-app .`
- Created `src/components/Hero.tsx`
- Created `src/components/ContactForm.tsx`
- Committed: "feat: initial landing page with hero and contact form"
- Pushed to `feature/initial-build`
- Created PR #1

### Output
[DONE] PR ready: https://github.com/user/landing-page/pull/1
Reply [MERGE] to merge and deploy.

### Files Changed
- src/components/Hero.tsx (created)
- src/components/ContactForm.tsx (created)
- src/app/page.tsx (modified)
- package.json (modified)

---

## 09:32 — Merge and deploy

### Input
[MERGE]

### Actions
- Merged PR #1
- Ran `vercel --prod --token $VERCEL_TOKEN`
- Deployment successful

### Output
[DONE] Deployed: https://landing-page.vercel.app

### Files Changed
- None (merge + deploy only)
```

## Handoff Notes

When a worker is reassigned, it appends a handoff section:

```markdown
---

## 10:00 — HANDOFF

### Current State
- Landing page is deployed and live
- Hero section and contact form complete
- No open PRs

### Uncommitted Changes
None

### Open PRs
None

### Recommendations for Next Worker
- Contact form submissions are not wired to a backend yet
- Consider adding form validation
- The Vercel project is linked as "landing-page"
```

## How Bots Use Memory

### On Startup (New Session)
1. Read CLAUDE.md for project context
2. Check `.memory/` for the most recent file
3. Look for a HANDOFF section at the end
4. Summarize the current state and report to Discord

### During Work
- Append to today's file after each completed interaction
- Use the file as a running log, not a polished document

### When Asked About Past Work
1. List files in `.memory/`: `ls .memory/`
2. Read only the specific date(s) relevant to the question
3. Scan headers (`## HH:MM — description`) to find the right section
4. Read just that section

**Do NOT load all memory files at once.** Load selectively by date.

### When Being Reassigned
1. Write the handoff section
2. Respond with `[HANDOFF] Saved. Ready for reassignment.`

## Manager Memory

The manager bot follows the same convention in `docs/memory/manager/YYYY-MM-DD.md`, logging:
- Worker assignments and reassignments
- Project creation
- Status updates
- Cross-project coordination decisions

The manager also maintains:
- `docs/STATUS.md` — current state dashboard
- `docs/ACTIVITY.md` — running activity log (summary, not full transcripts)
