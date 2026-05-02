#!/bin/bash
# Launch the Head of AI control plane dashboard
# Usage: ./dashboard-server.sh [--port PORT]

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${1:-4010}"
DB_PATH="$PROJECT_ROOT/data/orchestrator.db"

# Ensure DB exists
if [ ! -f "$DB_PATH" ]; then
  echo "Initializing database..."
  bash "$PROJECT_ROOT/scripts/init-db.sh"
fi

echo "Starting Head of AI Control Plane on http://127.0.0.1:${PORT}"
echo "Database: $DB_PATH"
echo "Press Ctrl+C to stop"
echo ""

exec python3 "$PROJECT_ROOT/dashboard/api.py" --port "$PORT" --db "$DB_PATH"
