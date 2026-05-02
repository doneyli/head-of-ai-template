#!/usr/bin/env python3
"""
Dashboard API server — reads orchestrator SQLite and serves JSON + static files.
Usage: python3 api.py [--port 4010] [--db ../data/orchestrator.db]
"""

import argparse
import json
import os
import sqlite3
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

DEFAULT_PORT = 4010
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DB = os.path.join(SCRIPT_DIR, "..", "data", "orchestrator.db")
STATIC_DIR = SCRIPT_DIR  # dashboard/ is the static root

DB_PATH = DEFAULT_DB  # overridden by --db at startup


# ---------------------------------------------------------------------------
# DB helpers
# ---------------------------------------------------------------------------

def get_conn():
    if not os.path.exists(DB_PATH):
        return None
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def db_503():
    return (503, {"error": "Database not found", "path": DB_PATH})


# ---------------------------------------------------------------------------
# Endpoint handlers
# ---------------------------------------------------------------------------

def handle_scores():
    conn = get_conn()
    if conn is None:
        return db_503()

    try:
        cur = conn.cursor()

        # Latest cycle
        cur.execute("SELECT MAX(cycle_id) AS cycle_id, MAX(scored_at) AS scored_at FROM scoring_history")
        row = cur.fetchone()
        if row is None or row["cycle_id"] is None:
            return (200, {"cycle_id": None, "scored_at": None, "summary": {}, "projects": [], "dispatch_queue": []})

        cycle_id = row["cycle_id"]
        scored_at = row["scored_at"]

        # Summary counts
        cur.execute("""
            SELECT
                COUNT(*) AS total_issues,
                SUM(CASE WHEN dispatch_bucket = 'auto_dispatch' THEN 1 ELSE 0 END) AS auto_dispatch,
                SUM(CASE WHEN dispatch_bucket = 'dispatch_with_review' THEN 1 ELSE 0 END) AS dispatch_with_review,
                SUM(CASE WHEN dispatch_bucket = 'needs_planning' THEN 1 ELSE 0 END) AS needs_planning,
                SUM(CASE WHEN dispatch_bucket = 'park' THEN 1 ELSE 0 END) AS park
            FROM scoring_history
            WHERE cycle_id = ?
        """, (cycle_id,))
        summary_row = cur.fetchone()
        summary = {
            "total_issues": summary_row["total_issues"] or 0,
            "auto_dispatch": summary_row["auto_dispatch"] or 0,
            "dispatch_with_review": summary_row["dispatch_with_review"] or 0,
            "needs_planning": summary_row["needs_planning"] or 0,
            "park": summary_row["park"] or 0,
        }

        # Project health for this cycle
        cur.execute("""
            SELECT repo, role, tier, status, open_issues, commits_7d, activity_decay, avg_score
            FROM project_health
            WHERE cycle_id = ?
            ORDER BY tier ASC, avg_score DESC
        """, (cycle_id,))
        health_rows = {r["repo"]: dict(r) for r in cur.fetchall()}

        # All issues for this cycle
        cur.execute("""
            SELECT repo, issue_number, issue_title, issue_labels,
                   delegability, impact, confidence,
                   effort, effort_divisor, raw_score, final_score,
                   dispatch_bucket, reasoning
            FROM scoring_history
            WHERE cycle_id = ?
            ORDER BY repo, final_score DESC
        """, (cycle_id,))
        issue_rows = cur.fetchall()

        # Group issues by repo
        issues_by_repo = {}
        for r in issue_rows:
            repo = r["repo"]
            if repo not in issues_by_repo:
                issues_by_repo[repo] = []
            issues_by_repo[repo].append({
                "number": r["issue_number"],
                "title": r["issue_title"],
                "labels": r["issue_labels"],
                "delegability": r["delegability"],
                "impact": r["impact"],
                "confidence": r["confidence"],
                "effort": r["effort"],
                "effort_divisor": r["effort_divisor"],
                "raw_score": r["raw_score"],
                "final_score": r["final_score"],
                "bucket": r["dispatch_bucket"],
                "reasoning": r["reasoning"],
            })

        # Build projects list — merge health + issues
        # Repos that appear in scoring_history but not project_health still get listed
        all_repos = set(list(health_rows.keys()) + list(issues_by_repo.keys()))

        projects = []
        for repo in all_repos:
            h = health_rows.get(repo, {})
            projects.append({
                "repo": repo,
                "role": h.get("role"),
                "tier": h.get("tier"),
                "status": h.get("status"),
                "open_issues": h.get("open_issues"),
                "commits_7d": h.get("commits_7d"),
                "activity_decay": h.get("activity_decay"),
                "avg_score": h.get("avg_score"),
                "issues": issues_by_repo.get(repo, []),
            })

        # Sort projects: tier ASC (None last), avg_score DESC (None last)
        projects.sort(key=lambda p: (
            p["tier"] if p["tier"] is not None else 999,
            -(p["avg_score"] or 0),
        ))

        # dispatch_queue — flat top-50 sorted by final_score DESC
        all_issues = []
        for repo, repo_issues in issues_by_repo.items():
            for issue in repo_issues:
                all_issues.append(dict(issue, repo=repo))
        all_issues.sort(key=lambda i: -(i["final_score"] or 0))
        dispatch_queue = all_issues[:50]

        return (200, {
            "scored_at": scored_at,
            "cycle_id": cycle_id,
            "summary": summary,
            "projects": projects,
            "dispatch_queue": dispatch_queue,
        })

    finally:
        conn.close()


def handle_history(query_params):
    conn = get_conn()
    if conn is None:
        return db_503()

    try:
        repo = query_params.get("repo", [None])[0]
        days_raw = query_params.get("days", ["90"])[0]
        try:
            days = int(days_raw)
        except ValueError:
            days = 90

        cur = conn.cursor()

        if repo:
            cur.execute("""
                SELECT cycle_id, scored_at, avg_score,
                       COUNT(s.id) AS issue_count
                FROM project_health ph
                LEFT JOIN scoring_history s
                    ON s.cycle_id = ph.cycle_id AND s.repo = ph.repo
                WHERE ph.repo = ?
                  AND ph.scored_at >= datetime('now', ? || ' days')
                GROUP BY ph.cycle_id, ph.scored_at, ph.avg_score
                ORDER BY ph.cycle_id ASC
            """, (repo, f"-{days}"))
        else:
            cur.execute("""
                SELECT cycle_id, MIN(scored_at) AS scored_at,
                       AVG(final_score) AS avg_score,
                       COUNT(*) AS issue_count
                FROM scoring_history
                WHERE scored_at >= datetime('now', ? || ' days')
                GROUP BY cycle_id
                ORDER BY cycle_id ASC
            """, (f"-{days}",))

        rows = cur.fetchall()
        data = [dict(r) for r in rows]
        return (200, {"repo": repo, "days": days, "history": data})

    finally:
        conn.close()


def handle_dispatch():
    conn = get_conn()
    if conn is None:
        return db_503()

    try:
        cur = conn.cursor()
        # Return empty list if table has no rows yet
        cur.execute("""
            SELECT id, dispatched_at, cycle_id, repo, issue_number,
                   agent_scope, agent_model, agent_tier,
                   status, completed_at, pr_number, pr_url, outcome,
                   cost_usd, error_message
            FROM dispatch_log
            ORDER BY dispatched_at DESC
            LIMIT 100
        """)
        rows = cur.fetchall()
        return (200, {"dispatch_log": [dict(r) for r in rows]})

    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Request handler
# ---------------------------------------------------------------------------

class DashboardHandler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        print(f"[{self.log_date_time_string()}] {self.address_string()} {fmt % args}")

    def send_json(self, status, payload):
        body = json.dumps(payload, indent=2, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(body)

    def serve_static(self, path):
        # Normalize path and prevent directory traversal
        safe_path = os.path.normpath(os.path.join(STATIC_DIR, path.lstrip("/")))
        if not safe_path.startswith(STATIC_DIR):
            self.send_error(403, "Forbidden")
            return

        # Default to index.html for directory requests
        if os.path.isdir(safe_path):
            safe_path = os.path.join(safe_path, "index.html")

        if not os.path.isfile(safe_path):
            self.send_error(404, f"Not found: {path}")
            return

        ext = os.path.splitext(safe_path)[1].lower()
        mime_types = {
            ".html": "text/html",
            ".css": "text/css",
            ".js": "application/javascript",
            ".json": "application/json",
            ".png": "image/png",
            ".ico": "image/x-icon",
            ".svg": "image/svg+xml",
        }
        content_type = mime_types.get(ext, "application/octet-stream")

        with open(safe_path, "rb") as f:
            body = f.read()

        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == "/api/scores":
            status, payload = handle_scores()
            self.send_json(status, payload)

        elif path == "/api/history":
            status, payload = handle_history(query)
            self.send_json(status, payload)

        elif path == "/api/dispatch":
            status, payload = handle_dispatch()
            self.send_json(status, payload)

        elif path.startswith("/api/"):
            self.send_json(404, {"error": f"Unknown endpoint: {path}"})

        else:
            self.serve_static(path if path != "/" else "/index.html")


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Head-of-AI dashboard API server")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Port to bind (default: 4010)")
    parser.add_argument("--db", default=DEFAULT_DB, help="Path to orchestrator.db")
    args = parser.parse_args()

    DB_PATH = os.path.abspath(args.db)

    server = HTTPServer(("127.0.0.1", args.port), DashboardHandler)
    print(f"Dashboard API running on http://127.0.0.1:{args.port}")
    print(f"DB path: {DB_PATH}")
    print(f"Static dir: {STATIC_DIR}")
    if not os.path.exists(DB_PATH):
        print(f"WARNING: DB not found at {DB_PATH} — /api/* will return 503 until it exists")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()
        sys.exit(0)
