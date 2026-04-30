#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
MODE="${1:-run}"

case "$MODE" in
  -h|--help|help)
    cat <<'USAGE'
Usage:
  scripts/symphony-managed.sh run
  scripts/symphony-managed.sh watchdog
  scripts/symphony-managed.sh restart
  scripts/symphony-managed.sh self-heal-once --reason "reason"
USAGE
    ;;
  run)
    exec "$ROOT/symphony" "$ROOT/WORKFLOW.md"
    ;;
  watchdog)
    exec "$ROOT/symphony" "$ROOT/WORKFLOW.md" --watchdog
    ;;
  restart)
    exec "$ROOT/symphony" "$ROOT/WORKFLOW.md" --restart-managed
    ;;
  self-heal-once)
    shift
    exec "$ROOT/symphony" "$ROOT/WORKFLOW.md" --self-heal-once "$@"
    ;;
  *)
    echo "unknown Symphony managed mode: $MODE" >&2
    exit 64
    ;;
esac
