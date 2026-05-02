#!/bin/bash
# DICE Scoring Engine — scores all open issues across the portfolio
# Usage: ./score-issues.sh [--dry-run] [--repo <repo>]
# Output: data/scores/current.json + SQLite scoring_history + terminal summary

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Override CLAUDE_CMD via env to point at a non-PATH binary if needed.
CLAUDE="${CLAUDE_CMD:-claude}"
DB_PATH="$PROJECT_ROOT/data/orchestrator.db"
SCORES_DIR="$PROJECT_ROOT/data/scores"
PORTFOLIO_YAML="$PROJECT_ROOT/portfolio.yaml"
POLICY_YAML="$PROJECT_ROOT/policy.yaml"
TIMESTAMP=$(date +%Y-%m-%d)
CYCLE_ID="$TIMESTAMP"

# Optional monitoring (override via env). Leave unset to disable health pings + push notifications.
GATUS_URL="${GATUS_URL:-}"
GATUS_TOKEN="${GATUS_TOKEN:-}"
NTFY_URL="${NTFY_URL:-}"

# Flags
DRY_RUN=false
FILTER_REPO=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --repo) FILTER_REPO="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

mkdir -p "$SCORES_DIR"

# ── Helpers ──────────────────────────────────────────

push_gatus() {
  [ -z "$GATUS_URL" ] && return 0
  local success="$1"
  curl -s -X POST -o /dev/null \
    "${GATUS_URL}/api/v1/endpoints/head-of-ai_score-issues/external?success=${success}" \
    -H "Authorization: Bearer ${GATUS_TOKEN}" 2>/dev/null || true
}

notify() {
  [ -z "$NTFY_URL" ] && return 0
  local title="$1"
  local message="$2"
  local priority="${3:-3}"
  curl -s -o /dev/null \
    -H "Title: ${title}" \
    -H "Priority: ${priority}" \
    -H "Tags: bar_chart" \
    -d "${message}" \
    "${NTFY_URL}/head-of-ai-alerts" 2>/dev/null || true
}

# ── Ensure DB exists ─────────────────────────────────

if [ ! -f "$DB_PATH" ]; then
  echo "Initializing database..."
  bash "$PROJECT_ROOT/scripts/init-db.sh"
fi

# ── Parse portfolio.yaml ─────────────────────────────

echo "=== DICE Scoring Engine ==="
echo "Cycle: $CYCLE_ID"
echo ""

# Extract active/maintenance repos from portfolio.yaml using yq
REPOS_JSON=$(yq -o=json '.projects[] | select(.status != "paused" and .status != "archived" and .github != null) | {"repo": .github, "role": .role, "tier": .tier, "status": .status, "path": .path}' "$PORTFOLIO_YAML" | python3 -c "
import sys, json
# yq outputs one JSON object per line — collect into array
lines = sys.stdin.read().strip()
if not lines:
    print('[]')
else:
    objects = []
    decoder = json.JSONDecoder()
    pos = 0
    while pos < len(lines):
        while pos < len(lines) and lines[pos] in ' \n\r\t':
            pos += 1
        if pos >= len(lines):
            break
        obj, end = decoder.raw_decode(lines, pos)
        objects.append(obj)
        pos = end
    print(json.dumps(objects))
")

if [ -z "$REPOS_JSON" ] || [ "$REPOS_JSON" = "[]" ]; then
  echo "ERROR: No active repos found in portfolio.yaml"
  push_gatus false
  exit 1
fi

REPO_COUNT=$(echo "$REPOS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
echo "Found $REPO_COUNT active/maintenance repos"
echo ""

# ── Parse policy.yaml ────────────────────────────────

POLICY_JSON=$(yq -o=json '.' "$POLICY_YAML")

# ── Collect issues + activity per repo ───────────────

echo "=== Collecting Issues ==="

SEVEN_DAYS_AGO=$(date -v-7d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -d '7 days ago' +%Y-%m-%dT00:00:00Z)
THIRTY_DAYS_AGO=$(date -v-30d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -d '30 days ago' +%Y-%m-%dT00:00:00Z)
NINETY_DAYS_AGO=$(date -v-90d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -d '90 days ago' +%Y-%m-%dT00:00:00Z)

COLLECTION_FILE="$SCORES_DIR/raw-$CYCLE_ID.json"

export REPOS_JSON FILTER_REPO SEVEN_DAYS_AGO THIRTY_DAYS_AGO NINETY_DAYS_AGO CYCLE_ID COLLECTION_FILE

# Build the collection JSON using python to orchestrate gh calls
COLLECT_RESULT=$(python3 << 'COLLECT_SCRIPT'
import subprocess, json, sys, os

repos_json = json.loads(os.environ.get("REPOS_JSON", "[]"))
filter_repo = os.environ.get("FILTER_REPO", "")
seven_days_ago = os.environ.get("SEVEN_DAYS_AGO", "")
thirty_days_ago = os.environ.get("THIRTY_DAYS_AGO", "")
ninety_days_ago = os.environ.get("NINETY_DAYS_AGO", "")
cycle_id = os.environ.get("CYCLE_ID", "")
collection_file = os.environ.get("COLLECTION_FILE", "")

def run_gh(args, default="[]"):
    try:
        result = subprocess.run(
            ["gh"] + args,
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout.strip())
        return json.loads(default)
    except Exception as e:
        print(f"  Warning: gh command failed: {e}", file=sys.stderr)
        return json.loads(default)

def count_commits_since(repo, since):
    try:
        result = subprocess.run(
            ["gh", "api", f"repos/{repo}/commits",
             "-f", f"since={since}", "-f", "per_page=1",
             "--jq", "length"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0 and result.stdout.strip():
            return int(result.stdout.strip())
    except Exception:
        pass
    return 0

def get_last_commit_date(repo):
    try:
        result = subprocess.run(
            ["gh", "api", f"repos/{repo}/commits",
             "-f", "per_page=1",
             "--jq", ".[0].commit.committer.date // empty"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except Exception:
        pass
    return None

projects = []
total_issues = 0

for r in repos_json:
    repo = r["repo"]
    if filter_repo and repo != filter_repo:
        continue

    print(f"  Collecting: {repo} ({r['role']})...", file=sys.stderr)

    # Fetch open issues
    issues_raw = subprocess.run(
        ["gh", "issue", "list", "--repo", repo, "--state", "open",
         "--json", "number,title,body,labels,createdAt,updatedAt", "--limit", "200"],
        capture_output=True, text=True, timeout=60
    )
    issues = json.loads(issues_raw.stdout) if issues_raw.returncode == 0 and issues_raw.stdout.strip() else []

    # Truncate bodies to 500 chars, flatten labels
    for issue in issues:
        body = issue.get("body") or ""
        if len(body) > 500:
            issue["body"] = body[:500] + "..."
        labels = issue.get("labels", [])
        if labels and isinstance(labels[0], dict):
            issue["labels"] = [l.get("name", "") for l in labels]

    commits_7d = count_commits_since(repo, seven_days_ago)
    commits_30d = count_commits_since(repo, thirty_days_ago)
    commits_90d = count_commits_since(repo, ninety_days_ago)
    last_commit = get_last_commit_date(repo)

    project = {
        "repo": repo,
        "role": r["role"],
        "tier": r["tier"],
        "status": r["status"],
        "commits_7d": commits_7d,
        "commits_30d": commits_30d,
        "commits_90d": commits_90d,
        "last_commit_date": last_commit,
        "issues": issues
    }
    projects.append(project)
    total_issues += len(issues)
    print(f"    -> {len(issues)} open issues, {commits_7d} commits (7d)", file=sys.stderr)

collection = {
    "cycle_id": cycle_id,
    "total_issues": total_issues,
    "projects": projects
}

with open(collection_file, "w") as f:
    json.dump(collection, f, indent=2)

print(json.dumps({"total": total_issues, "repos": len(projects)}))
COLLECT_SCRIPT
)

TOTAL_ISSUES=$(echo "$COLLECT_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo "0")
echo ""
echo "Collected $TOTAL_ISSUES issues"
echo ""

if [ "$TOTAL_ISSUES" = "0" ]; then
  echo "No issues to score."
  push_gatus true
  exit 0
fi

# ── Score via Claude ─────────────────────────────────

echo "=== Scoring Issues (Claude Sonnet) ==="

if [ "$DRY_RUN" = true ]; then
  echo "[DRY RUN] Would send $(wc -c < "$COLLECTION_FILE") bytes to Claude for scoring."
  echo "[DRY RUN] Skipping Claude call and downstream writes."
  exit 0
fi

# Score per-repo to avoid timeout on large portfolios.
# Each repo gets its own Claude call — faster, partial results survive failures.
SCORES_RAW_FILE="$SCORES_DIR/scores-raw-$CYCLE_ID.json"
export SCORES_RAW_FILE
BATCH_DIR="$SCORES_DIR/batches-$CYCLE_ID"
mkdir -p "$BATCH_DIR"
export SCORES_RAW_FILE BATCH_DIR CLAUDE PROJECT_ROOT COLLECTION_FILE

# Score each repo separately using a Python orchestrator
python3 << 'SCORE_BATCH'
import json, subprocess, sys, os, glob

collection_file = os.environ["COLLECTION_FILE"]
batch_dir = os.environ.get("BATCH_DIR", "/tmp/batches")
claude_bin = os.environ.get("CLAUDE", "claude")
prompt_file = os.path.join(os.environ.get("PROJECT_ROOT", "."), "prompts", "score-issues.md")

with open(collection_file) as f:
    collection = json.load(f)

with open(prompt_file) as f:
    prompt_template = f.read()

scored_total = 0
failed = []

for project in collection["projects"]:
    repo = project["repo"]
    issues = project.get("issues", [])
    if not issues:
        continue

    repo_short = repo.split("/")[-1]
    print(f"  Scoring {repo_short} ({len(issues)} issues)...", file=sys.stderr)

    # Build per-repo input
    repo_data = json.dumps({
        "cycle_id": collection["cycle_id"],
        "projects": [project]
    }, indent=2)

    # Substitute into prompt
    prompt = prompt_template.replace("${ISSUES_JSON}", repo_data)

    # Call Claude CLI
    claude_raw = os.path.join(batch_dir, f"claude-raw-{repo_short}.json")
    try:
        result = subprocess.run(
            [claude_bin, "-p", "--model", "sonnet", "--output-format", "json"],
            input=prompt, capture_output=True, text=True, timeout=600
        )
        if result.returncode != 0:
            print(f"    WARNING: Claude call failed for {repo_short} (exit {result.returncode})", file=sys.stderr)
            failed.append(repo_short)
            continue

        with open(claude_raw, "w") as f:
            f.write(result.stdout)

        # Parse envelope
        envelope = json.loads(result.stdout)
        if envelope.get("is_error"):
            print(f"    WARNING: Claude returned error for {repo_short}: {envelope.get('result','')[:100]}", file=sys.stderr)
            failed.append(repo_short)
            continue

        result_text = envelope.get("result", "").strip()
        # Strip markdown code fences if present
        if result_text.startswith("```"):
            lines = result_text.split("\n")
            lines = [l for l in lines if not l.strip().startswith("```")]
            result_text = "\n".join(lines).strip()

        scores = json.loads(result_text)
        score_list = scores.get("scores", scores) if isinstance(scores, dict) else scores

        # Write batch scores
        batch_file = os.path.join(batch_dir, f"scores-{repo_short}.json")
        with open(batch_file, "w") as f:
            json.dump(score_list, f, indent=2)

        scored_total += len(score_list)
        print(f"    -> {len(score_list)} issues scored", file=sys.stderr)

    except subprocess.TimeoutExpired:
        print(f"    WARNING: Claude call timed out for {repo_short} (10m limit)", file=sys.stderr)
        failed.append(repo_short)
    except (json.JSONDecodeError, KeyError) as e:
        print(f"    WARNING: Failed to parse scores for {repo_short}: {e}", file=sys.stderr)
        failed.append(repo_short)

# Merge all batch files into combined scores
all_scores = []
for batch_file in sorted(glob.glob(os.path.join(batch_dir, "scores-*.json"))):
    with open(batch_file) as f:
        all_scores.extend(json.load(f))

scores_raw_file = os.environ["SCORES_RAW_FILE"]
with open(scores_raw_file, "w") as f:
    json.dump({"scores": all_scores}, f, indent=2)

# Output summary for bash to capture
print(json.dumps({"scored": scored_total, "failed": failed}))
SCORE_BATCH

# Read summary from the scores file
SCORED_COUNT=$(python3 -c "import json; print(len(json.load(open('$SCORES_RAW_FILE')).get('scores',[])))" 2>/dev/null || echo "0")

echo ""
echo "Scored $SCORED_COUNT issues total"

if [ "$SCORED_COUNT" = "0" ]; then
  echo "ERROR: No issues were scored"
  push_gatus false
  notify "DICE Scoring FAILED" "Zero issues scored for cycle $CYCLE_ID" 4
  exit 1
fi

echo "Scoring complete. Applying multipliers and persisting..."
echo ""

# ── Apply multipliers + persist ──────────────────────

export PROJECT_ROOT DB_PATH SCORES_DIR CYCLE_ID COLLECTION_FILE SCORES_RAW_FILE POLICY_JSON

python3 << 'APPLY_SCRIPT'
import json, sqlite3, sys, os
from datetime import datetime, timezone

project_root = os.environ.get("PROJECT_ROOT", ".")
db_path = os.environ.get("DB_PATH", f"{project_root}/data/orchestrator.db")
scores_dir = os.environ.get("SCORES_DIR", f"{project_root}/data/scores")
cycle_id = os.environ.get("CYCLE_ID", datetime.now().strftime("%Y-%m-%d"))
collection_file = os.environ.get("COLLECTION_FILE", "")
scores_raw_file = os.environ.get("SCORES_RAW_FILE", "")
policy_json_str = os.environ.get("POLICY_JSON", "{}")

# Load data
with open(collection_file) as f:
    collection = json.load(f)

with open(scores_raw_file) as f:
    scores_data = json.load(f)

policy = json.loads(policy_json_str)
scoring_policy = policy.get("scoring", {})
dispatch_policy = policy.get("dispatch", {})

# Build lookup: repo -> project info
project_lookup = {}
for p in collection["projects"]:
    project_lookup[p["repo"]] = p

# Effort map
effort_map = scoring_policy.get("effort_map", {"S": 1, "M": 3, "L": 5, "XL": 8, "default": 3})
tier_multipliers = scoring_policy.get("tier_multipliers", {1: 2.0, 2: 1.5, 3: 1.0, 4: 0.5})
status_multipliers = scoring_policy.get("status_multipliers", {"active": 1.0, "maintenance": 0.5})

# Activity decay rules
activity_decay_rules = scoring_policy.get("activity_decay", {
    "within_7_days": 1.0, "within_30_days": 0.7, "within_90_days": 0.4, "over_90_days": 0.1
})

# Dispatch buckets
buckets = dispatch_policy.get("buckets", {})

# Normalize scores (handle both {scores: [...]} and [...] formats)
scores_list = scores_data.get("scores", scores_data) if isinstance(scores_data, dict) else scores_data

# Build score lookup
score_lookup = {}
for s in scores_list:
    key = (s["repo"], s["issue_number"])
    score_lookup[key] = s

# Connect to DB
conn = sqlite3.connect(db_path)
cur = conn.cursor()

# Process each project and issue
all_scored = []
project_summaries = []
bucket_counts = {"auto_dispatch": 0, "dispatch_with_review": 0, "needs_planning": 0, "park": 0}

for project in collection["projects"]:
    repo = project["repo"]
    tier = project.get("tier", 3)
    status = project.get("status", "active")
    commits_7d = project.get("commits_7d", 0)
    commits_30d = project.get("commits_30d", 0)
    commits_90d = project.get("commits_90d", 0)

    # Calculate activity decay (4 tiers per policy.yaml)
    if commits_7d > 0:
        decay = activity_decay_rules.get("within_7_days", 1.0)
    elif commits_30d > 0:
        decay = activity_decay_rules.get("within_30_days", 0.7)
    elif commits_90d > 0:
        decay = activity_decay_rules.get("within_90_days", 0.4)
    else:
        decay = activity_decay_rules.get("over_90_days", 0.1)

    tier_mult = tier_multipliers.get(tier, tier_multipliers.get(str(tier), 1.0))
    status_mult = status_multipliers.get(status, 1.0)

    project_issues = []

    for issue in project.get("issues", []):
        key = (repo, issue["number"])
        score = score_lookup.get(key)
        if not score:
            continue

        d = max(0, min(10, score.get("delegability", 5)))
        i = max(0, min(10, score.get("impact", 5)))
        c = max(0, min(10, score.get("confidence", 5)))
        effort = score.get("effort", "M")
        e_divisor = effort_map.get(effort, effort_map.get("default", 3))

        raw = (d * i * c) / e_divisor if e_divisor > 0 else 0
        final = raw * tier_mult * status_mult * decay

        # Determine bucket
        bucket = "park"
        if final > 70 and d > 7:
            bucket = "auto_dispatch"
        elif final > 40 and d > 5:
            bucket = "dispatch_with_review"
        elif final > 20:
            bucket = "needs_planning"

        bucket_counts[bucket] = bucket_counts.get(bucket, 0) + 1

        labels = issue.get("labels", [])
        if isinstance(labels, list):
            labels_str = ",".join(labels)
        else:
            labels_str = str(labels)

        scored_issue = {
            "repo": repo,
            "number": issue["number"],
            "title": issue.get("title", ""),
            "labels": labels_str,
            "delegability": d,
            "impact": i,
            "confidence": c,
            "effort": effort,
            "effort_divisor": e_divisor,
            "raw_score": round(raw, 2),
            "tier_multiplier": tier_mult,
            "status_multiplier": status_mult,
            "activity_decay": decay,
            "final_score": round(final, 2),
            "bucket": bucket,
            "reasoning": score.get("reasoning", "")
        }
        all_scored.append(scored_issue)
        project_issues.append(scored_issue)

        # Insert into DB
        cur.execute("""
            INSERT OR REPLACE INTO scoring_history
            (cycle_id, repo, issue_number, issue_title, issue_labels,
             delegability, impact, confidence, effort, effort_divisor,
             raw_score, tier_multiplier, status_multiplier, activity_decay,
             final_score, dispatch_bucket, reasoning)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (cycle_id, repo, issue["number"], issue.get("title", ""), labels_str,
              d, i, c, effort, e_divisor, round(raw, 2),
              tier_mult, status_mult, decay, round(final, 2), bucket,
              score.get("reasoning", "")))

    # Project health
    avg_score = sum(si["final_score"] for si in project_issues) / len(project_issues) if project_issues else 0
    top_issue = max(project_issues, key=lambda x: x["final_score"])["number"] if project_issues else None

    cur.execute("""
        INSERT OR REPLACE INTO project_health
        (cycle_id, repo, role, tier, status, open_issues, closed_7d,
         commits_7d, commits_30d, last_commit_date, activity_decay,
         avg_score, top_issue_number)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (cycle_id, repo, project.get("role", ""), tier, status,
          len(project.get("issues", [])), project.get("closed_7d", 0),
          commits_7d, commits_30d, project.get("last_commit_date"),
          decay, round(avg_score, 2), top_issue))

    project_issues.sort(key=lambda x: x["final_score"], reverse=True)
    project_summaries.append({
        "repo": repo,
        "role": project.get("role", ""),
        "tier": tier,
        "status": status,
        "open_issues": len(project.get("issues", [])),
        "commits_7d": commits_7d,
        "activity_decay": decay,
        "avg_score": round(avg_score, 2),
        "issues": project_issues
    })

conn.commit()
conn.close()

# Sort: dispatch queue by final_score desc
all_scored.sort(key=lambda x: x["final_score"], reverse=True)
dispatch_queue = [
    {"repo": s["repo"], "issue": s["number"], "title": s["title"],
     "score": s["final_score"], "bucket": s["bucket"]}
    for s in all_scored[:50]
]

# Sort projects by tier asc, avg_score desc
project_summaries.sort(key=lambda x: (x["tier"], -x["avg_score"]))

# Write current.json
output = {
    "scored_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "cycle_id": cycle_id,
    "summary": {
        "total_issues": len(all_scored),
        **bucket_counts
    },
    "projects": project_summaries,
    "dispatch_queue": dispatch_queue
}

output_file = os.path.join(scores_dir, "current.json")
with open(output_file, "w") as f:
    json.dump(output, f, indent=2)

# Terminal summary
print(f"\n{'='*60}")
print(f"DICE Scoring Complete — {cycle_id}")
print(f"{'='*60}")
print(f"Total issues scored: {len(all_scored)}")
print(f"  Auto-dispatch:       {bucket_counts.get('auto_dispatch', 0)}")
print(f"  Dispatch w/ review:  {bucket_counts.get('dispatch_with_review', 0)}")
print(f"  Needs planning:      {bucket_counts.get('needs_planning', 0)}")
print(f"  Park:                {bucket_counts.get('park', 0)}")
print(f"\n{'─'*60}")
print(f"Top 15 — Dispatch Queue")
print(f"{'─'*60}")
print(f"{'#':>3}  {'Score':>6}  {'Bucket':<12}  {'Repo':<30}  Issue")
print(f"{'─'*60}")
for idx, item in enumerate(dispatch_queue[:15], 1):
    repo_short = item['repo'].split('/')[-1]
    print(f"{idx:>3}  {item['score']:>6.1f}  {item['bucket']:<12}  {repo_short:<30}  #{item['issue']} {item['title'][:50]}")
print(f"{'─'*60}")

# Decisions needed: high impact but low delegability
decisions = [s for s in all_scored if s["impact"] >= 7 and s["delegability"] < 5]
if decisions:
    print(f"\nDecisions Needed ({len(decisions)} issues — high impact, unclear spec):")
    for d in decisions[:10]:
        repo_short = d['repo'].split('/')[-1]
        print(f"  - {repo_short}#{d['number']}: {d['title'][:60]} (I={d['impact']}, D={d['delegability']})")

print(f"\nFull results: {output_file}")
print(f"Dashboard: http://127.0.0.1:4010")
APPLY_SCRIPT

if [ $? -eq 0 ]; then
  push_gatus true
  # Count buckets for notification
  AUTO_COUNT=$(python3 -c "import json; d=json.load(open('$SCORES_DIR/current.json')); print(d['summary'].get('auto_dispatch',0))" 2>/dev/null || echo "?")
  TOTAL=$(python3 -c "import json; d=json.load(open('$SCORES_DIR/current.json')); print(d['summary'].get('total_issues',0))" 2>/dev/null || echo "?")
  notify "DICE Scoring Complete" \
    "$TOTAL issues scored. $AUTO_COUNT ready for auto-dispatch. See http://127.0.0.1:4010" 3
else
  push_gatus false
  notify "DICE Scoring FAILED" "Multiplier/persist step failed for cycle $CYCLE_ID" 4
  exit 1
fi

echo ""
echo "=== Done ==="
