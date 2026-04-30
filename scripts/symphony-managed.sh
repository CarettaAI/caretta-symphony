#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
MODE="${1:-run}"
WORKFLOW_PATH="${SYMPHONY_WORKFLOW_PATH:-}"

if [ -z "$WORKFLOW_PATH" ]; then
  if [ -f "$ROOT/WORKFLOW.caretta-local.md" ]; then
    WORKFLOW_PATH="$ROOT/WORKFLOW.caretta-local.md"
  else
    WORKFLOW_PATH="$ROOT/WORKFLOW.md"
  fi
fi

die() {
  printf '%s\n' "$*" >&2
  exit 70
}

resolve_symphony() {
  if [ -n "${SYMPHONY_EXECUTABLE:-}" ]; then
    if [ -x "$SYMPHONY_EXECUTABLE" ]; then
      printf '%s\n' "$SYMPHONY_EXECUTABLE"
      return 0
    fi

    die "configured SYMPHONY_EXECUTABLE is not executable: $SYMPHONY_EXECUTABLE"
  fi

  for candidate in \
    "$ROOT/.symphony-self-heal/deploy/current/symphony" \
    "$ROOT/symphony"
  do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  die "no Symphony executable found; run mix escript.build or complete a self-heal deployment"
}

exec_symphony() {
  symphony_bin=$(resolve_symphony)
  exec "$symphony_bin" "$@"
}

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
    exec_symphony "$WORKFLOW_PATH"
    ;;
  watchdog)
    exec_symphony "$WORKFLOW_PATH" --watchdog
    ;;
  restart)
    exec_symphony "$WORKFLOW_PATH" --restart-managed
    ;;
  self-heal-once)
    shift
    exec_symphony "$WORKFLOW_PATH" --self-heal-once "$@"
    ;;
  *)
    echo "unknown Symphony managed mode: $MODE" >&2
    exit 64
    ;;
esac
