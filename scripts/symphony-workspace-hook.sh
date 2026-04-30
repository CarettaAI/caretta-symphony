#!/bin/zsh
set -euo pipefail

HOOK_NAME="${1:-unknown}"
LOG_PATH="${SYMPHONY_HOOK_LOG:-/var/tmp/caretta-symphony-workspace-hooks.log}"
WORKSPACE_PATH="$(pwd -P)"
ISSUE_KEY="$(basename "$WORKSPACE_PATH")"
STAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

printf "%s hook=%s issue=%s workspace=%s\n" "$STAMP" "$HOOK_NAME" "$ISSUE_KEY" "$WORKSPACE_PATH" >> "$LOG_PATH"
