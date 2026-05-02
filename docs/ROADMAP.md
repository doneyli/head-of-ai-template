# Roadmap

The Personal Control Plane has two phases. Phase 1 is shipped in `main`. Phase 2 is wiring up over May 2026 and lands here as commits.

## Phase 1: The Brain (shipped)

The scoring engine + dashboard. This is the layer that turns 100+ open issues into a ranked queue and a visual portfolio overview. It runs on a schedule (cron or launchd) and writes scoring history to SQLite.

**Files in `main`:**
- `portfolio.yaml` — Layer 1: project registry
- `policy.yaml` — Layers 2 + 3: DICE rubric + dispatch bucket thresholds
- `scripts/score-issues.sh` — DICE scoring engine
- `scripts/init-db.sh` — SQLite schema bootstrap
- `scripts/dashboard-server.sh` — dashboard launcher
- `prompts/score-issues.md` — Claude prompt template
- `dashboard/api.py` + `dashboard/index.html` — control plane dashboard
- `hooks/enforce-agent-scope.sh` — Layer 4: scope-enforcement hook (paired with Phase 2 dispatch but ships now because the hook is small and the cost of having it ahead of dispatch is zero)

**What you get from Phase 1 alone:** a daily-refreshed prioritized work list across your portfolio, a dashboard that surfaces stale projects and quality-gate violations, and a `kata` (`policy.yaml`) you can iterate on. This replaces a Sunday spreadsheet.

## Phase 2: The Hands (wiring up)

The execution layer. This is the layer that takes the top N scored issues and actually dispatches agents to work them overnight, with scope-enforced file writes, a morning report, vacation mode, and a cost ceiling.

**Files coming in May 2026 (in dependency order):**

### Step 2: Night-shift dispatch
- `scripts/dispatch.sh` — reads `data/scores/current.json`, picks the top N auto-dispatch issues, spawns `claude` worktrees with the right `AGENT_SCOPE` env vars set
- `scripts/cleanup-worktrees.sh` — orphan recovery (cron every 6h)
- `launchd/com.example.head-of-ai.dispatch.plist` — launchd job at 22:00 local time

**Why this ships before scope hook activation:** so you can manually invoke dispatch for a few cycles before turning on automation. Trust the queue first.

### Step 3: Scope hook activation
- `hooks/enforce-agent-scope.sh` (already shipped) — symlink it into `~/.claude/hooks/` and verify with a synthetic test before wiring dispatch.

**Why this ships next:** dispatch without scope enforcement is the trap. Wire the hook before raising the concurrent-agent ceiling above 1.

### Step 4: Morning report
- `scripts/morning-report.sh` — reads last 24 hours of `dispatch_log` from SQLite, fetches PR statuses via `gh`, writes a Markdown brief
- `launchd/com.example.head-of-ai.morning-report.plist` — launchd job at 08:00 local time

### Step 5: Cost loop
- `scripts/cost-check.sh` — reads recent Langfuse traces, sums per-agent spend, projects month-end total, compares to ceiling
- Wired into `dispatch.sh` so the 80% warning reduces the per-night batch and the 95% critical pauses auto-dispatch

### Step 6: Vacation mode auto-expire
- Logic added to `score-issues.sh` and `dispatch.sh` to read the `vacation_mode` block from `policy.yaml`
- Auto-expire: if `expires` date is in the past, the flag is treated as off
- This is the LAST feature on the roadmap because vacation mode is the test of whether the rest of the system is mature enough that you can leave it alone.

## How to follow along

- Watch the repo for releases (each Phase 2 step lands as a tagged release)
- Subscribe to the Build Log series **Signal Over Noise**: https://doneyli.substack.com/
