#!/bin/bash
# Initialize orchestrator SQLite database
# Idempotent — safe to run multiple times (CREATE TABLE IF NOT EXISTS)

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DB_PATH="$PROJECT_ROOT/data/orchestrator.db"

mkdir -p "$(dirname "$DB_PATH")"

sqlite3 "$DB_PATH" <<'SQL'
-- Scoring results per issue per cycle
CREATE TABLE IF NOT EXISTS scoring_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    scored_at TEXT NOT NULL DEFAULT (datetime('now')),
    cycle_id TEXT NOT NULL,
    repo TEXT NOT NULL,
    issue_number INTEGER NOT NULL,
    issue_title TEXT NOT NULL,
    issue_labels TEXT,
    delegability REAL NOT NULL,
    impact REAL NOT NULL,
    confidence REAL NOT NULL,
    effort TEXT NOT NULL,
    effort_divisor REAL NOT NULL,
    raw_score REAL NOT NULL,
    tier_multiplier REAL NOT NULL,
    status_multiplier REAL NOT NULL,
    activity_decay REAL NOT NULL,
    final_score REAL NOT NULL,
    dispatch_bucket TEXT NOT NULL,
    reasoning TEXT,
    UNIQUE(cycle_id, repo, issue_number)
);

-- Project-level health per scoring cycle
CREATE TABLE IF NOT EXISTS project_health (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    scored_at TEXT NOT NULL DEFAULT (datetime('now')),
    cycle_id TEXT NOT NULL,
    repo TEXT NOT NULL,
    role TEXT,
    tier INTEGER,
    status TEXT,
    open_issues INTEGER,
    closed_7d INTEGER,
    commits_7d INTEGER,
    commits_30d INTEGER,
    last_commit_date TEXT,
    activity_decay REAL,
    avg_score REAL,
    top_issue_number INTEGER,
    UNIQUE(cycle_id, repo)
);

-- Dispatch log (Phase 2 populates)
CREATE TABLE IF NOT EXISTS dispatch_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    dispatched_at TEXT NOT NULL DEFAULT (datetime('now')),
    cycle_id TEXT NOT NULL,
    repo TEXT NOT NULL,
    issue_number INTEGER NOT NULL,
    agent_scope TEXT,
    agent_model TEXT,
    agent_tier INTEGER,
    worktree_path TEXT,
    status TEXT NOT NULL DEFAULT 'queued',
    completed_at TEXT,
    pr_number INTEGER,
    pr_url TEXT,
    outcome TEXT,
    cost_usd REAL,
    error_message TEXT
);

-- Learnings (Phase 3 populates)
CREATE TABLE IF NOT EXISTS learnings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    category TEXT NOT NULL,
    project TEXT,
    content TEXT NOT NULL,
    source TEXT,
    reinforced_at TEXT,
    expires_at TEXT
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_scoring_cycle ON scoring_history(cycle_id);
CREATE INDEX IF NOT EXISTS idx_scoring_repo ON scoring_history(repo);
CREATE INDEX IF NOT EXISTS idx_scoring_bucket ON scoring_history(dispatch_bucket);
CREATE INDEX IF NOT EXISTS idx_health_cycle ON project_health(cycle_id);
CREATE INDEX IF NOT EXISTS idx_dispatch_status ON dispatch_log(status);
CREATE INDEX IF NOT EXISTS idx_dispatch_cycle ON dispatch_log(cycle_id);
SQL

echo "Database initialized at $DB_PATH"
echo "Tables: scoring_history, project_health, dispatch_log, learnings"
