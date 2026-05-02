#!/usr/bin/env bash
# Reject file writes outside the agent's declared scope.
#
# Usage: symlink this from ~/.claude/hooks/enforce-agent-scope.sh
# Reads AGENT_SCOPE from the agent's environment (set at dispatch time).
# Exits 1 to block the write; 0 to allow.
#
# Scopes:
#   docs-only - agent may edit only .md, .txt, .yaml, .yml
#   source    - agent may edit code but not infrastructure files
#   full      - no restrictions beyond the global deny list
#
# This is layer 4 of the Personal Control Plane: poka-yoke (mistake-proofing)
# applied at the file-write boundary. About 40 lines of bash. You don't need
# a policy engine. You need a hook and a list of globs.

set -euo pipefail

scope="${AGENT_SCOPE:-full}"
target="${1:-}"

# Global deny list (applies to ALL scopes, including full).
# Add to this list: anything containing secrets, credentials, or PII.
case "$target" in
  *.env|*.env.*|*/secrets/*|*/credentials.json|*/.aws/*|*/.ssh/*) exit 1 ;;
esac

case "$scope" in
  docs-only)
    case "$target" in
      *.md|*.txt|*.yaml|*.yml) exit 0 ;;
      *) exit 1 ;;
    esac ;;
  source)
    # Source can edit code, not infrastructure.
    case "$target" in
      docker-compose*.yml|*.plist|CLAUDE.md|ports.json|.env*) exit 1 ;;
      *) exit 0 ;;
    esac ;;
  full)
    # Full has no additional restrictions beyond the global deny list above.
    exit 0 ;;
  *)
    # Unknown scope = block. Fail-closed.
    exit 1 ;;
esac
