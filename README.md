# head-of-ai-template

A personal AI control plane for running multiple agentic projects without losing the plot.

Four layers (Registry, Scoring, Dispatch, Scope), 162 lines of YAML, ~1,300 lines of bash and Python, one SQLite database, one static dashboard. The opinion is in the YAML; everything else is plumbing.

The framework is borrowed structurally from the Toyota Production System: a written `kata` (your `policy.yaml`) governs every job, just-in-time dispatch picks what runs tonight, an `andon` veto window keeps autonomy honest, and `genchi genbutsu` (the dashboard) lets you go and see for yourself instead of trusting status updates.

Built and used in production on an 18-project portfolio. Read the full Build Log: **["I Hired a Head of AI to Run My Agents"](https://doneyli.substack.com/)** (May 2026).

---

## What you get

- **Registry** (`portfolio.yaml`): the curated list of projects in your portfolio. The thing that doesn't exist here doesn't get scored.
- **Scoring** (`policy.yaml` + `scripts/score-issues.sh`): the DICE rubric that turns 100+ open issues into a ranked queue. `Score = (Delegability × Impact × Confidence) / Effort`, with tier, status, and activity-decay multipliers.
- **Dispatch buckets**: thresholds in `policy.yaml` that map scores to `auto-dispatch`, `dispatch with review`, `needs planning`, or `park`. (Phase 2: full dispatch script wires up to launchd.)
- **Scope enforcement** (`hooks/enforce-agent-scope.sh`): a 40-line bash hook that rejects file writes outside an agent's declared scope. Layer 4 of the control plane: `poka-yoke` at the file-write boundary.
- **Dashboard** (`dashboard/`): a static HTML page on `localhost:4010` that reads scoring history from SQLite and shows ranked issues, project health, and rolling cost. The `genchi genbutsu` view.

## Roadmap

| Component | Status |
|-----------|--------|
| Registry (`portfolio.yaml`) | ✅ Shipped |
| DICE scoring engine (`scripts/score-issues.sh`) | ✅ Shipped |
| SQLite schema (`scripts/init-db.sh`) | ✅ Shipped |
| Scoring prompt template (`prompts/score-issues.md`) | ✅ Shipped |
| Dashboard (`dashboard/`) | ✅ Shipped |
| Scope-enforcement hook (`hooks/enforce-agent-scope.sh`) | ✅ Shipped |
| Dispatch script (`scripts/dispatch.sh`) | 🚧 Wiring up (May 2026) |
| Morning report generator (`scripts/morning-report.sh`) | 🚧 Wiring up |
| Vacation-mode auto-expire | 🚧 Wiring up |
| Cost-loop / Langfuse integration | 🚧 Wiring up |
| Always-on Mac Studio launchd plists | 🚧 Wiring up |

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the order I recommend wiring these up.

---

## Quick start

You'll need: `bash`, `sqlite3`, `python3`, `gh` (GitHub CLI), and a working `claude` binary on your `PATH`.

```bash
# 1. Clone the template
git clone https://github.com/doneyli/head-of-ai-template.git
cd head-of-ai-template

# 2. Edit portfolio.yaml — replace the example projects with your own
$EDITOR portfolio.yaml

# 3. Edit policy.yaml — tune weights, multipliers, thresholds for your taste
$EDITOR policy.yaml

# 4. Initialize the SQLite database
./scripts/init-db.sh

# 5. Run the scoring engine (dry-run first to see what would happen)
./scripts/score-issues.sh --dry-run
./scripts/score-issues.sh

# 6. Launch the dashboard
./scripts/dashboard-server.sh
# Open http://localhost:4010 in your browser
```

That's the v0. About 90 minutes of work to get it running.

## Schedule it

Once you trust the scoring (give it two weeks), schedule it:

```bash
# Add a cron entry, or write a launchd plist (macOS)
0 8 * * * cd /path/to/head-of-ai-template && ./scripts/score-issues.sh
```

By the third week the dashboard will tell you something your gut wouldn't have. That's the point.

---

## File map

```
head-of-ai-template/
├── README.md                          # this file
├── LICENSE                            # MIT
├── portfolio.yaml                     # Layer 1: registry (your projects)
├── policy.yaml                        # Layer 2 + 3: kata + dispatch buckets
├── scripts/
│   ├── score-issues.sh                # the scoring engine (~600 lines)
│   ├── init-db.sh                     # SQLite schema bootstrap
│   └── dashboard-server.sh            # python http.server wrapper for the dashboard
├── prompts/
│   └── score-issues.md                # Claude prompt template for DICE scoring
├── hooks/
│   └── enforce-agent-scope.sh         # Layer 4: 40-line scope hook (poka-yoke)
├── dashboard/
│   ├── api.py                         # tiny SQLite-backed JSON API
│   └── index.html                     # static dashboard (vanilla JS)
└── docs/
    └── ROADMAP.md                     # Phase 1 vs Phase 2 wiring order
```

## Architecture

```
                   policy.yaml
                   (the kata: weights, thresholds, autonomy tiers)
                        │
                        ▼
  portfolio.yaml ──► score-issues.sh ──► SQLite ──► dashboard
  (registry)         (DICE engine)      (history)   (:4010)
                        │
                        ▼
                   data/scores/current.json
                        │
                        ▼
                   dispatch.sh (Phase 2)
                        │
                        ├──► AGENT_SCOPE=docs-only  ──► claude worktree
                        ├──► AGENT_SCOPE=source     ──► claude worktree (with hook)
                        └──► AGENT_SCOPE=full       ──► claude worktree (Tier 1 only)
                                                        │
                                                        ▼
                                              hooks/enforce-agent-scope.sh
                                              (rejects out-of-scope writes)
```

## Why bash + YAML + SQLite

The first version of this was a Next.js app with a Postgres backend and an OAuth flow. It took two weekends and got used twice. The CEO's office is config, not an app.

Toyota's `kanban` boards aren't software. They're laminated cards in clear pockets. The same logic applies here: the manual is the product. Once you've written down what good means, the implementation is plumbing.

---

## Optional: monitoring + push notifications

`scripts/score-issues.sh` supports two optional integrations via env vars:

- **Gatus** (status page): set `GATUS_URL` and `GATUS_TOKEN` to push success/failure pings.
- **ntfy** (push notifications): set `NTFY_URL` to receive push alerts on cost anomalies and dispatch events.

Both are optional. Leave the env vars unset to disable.

---

## Optional: Langfuse cost tracking

The cost-loop ceiling in `policy.yaml` (`budget_monthly_usd`, with 80% warning and 95% kill switch) reads from a Langfuse instance to track per-agent spend. If you don't run Langfuse, the cost loop is a no-op.

A self-hostable Langfuse template is at [doneyli/claude-code-langfuse-template](https://github.com/doneyli/claude-code-langfuse-template).

---

## Contributing

This is a template for personal control planes. The intended use is fork-and-customize, not pull-request-against-main. That said, if you find a bug in the shipped scripts or dashboard, open an issue.

If you're publishing your own variation: I'd love to see it. Tag [@doneyli](https://github.com/doneyli) on GitHub or share on the Build Log.

## License

MIT. See [LICENSE](LICENSE).

---

*Built by [Doneyli De Jesus](https://doneyli.substack.com/). Read the Build Log series **Signal Over Noise** for the full story behind this template and the rest of the agent stack.*
