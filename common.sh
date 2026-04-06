#!/usr/bin/env bash
set -euo pipefail
# Common helpers shared by the split scripts

DTFMT="$(date +%Y%m%d-%H%M)"
LOGDIR="${LOGDIR:-./logs}"
MASTER_LOG="${MASTER_LOG:-$LOGDIR/Patching_${DTFMT}.log}"
STEP_LOG="${STEP_LOG:-$LOGDIR/step_${DTFMT}.log}"

mkdir -p "$LOGDIR"

log_message() {
  local msg="$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') - ${msg}" | tee -a "$MASTER_LOG"
}

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || { echo "[ERROR] Required variable '$name' not set" | tee -a "$MASTER_LOG"; exit 1; }
}

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "[ERROR] Command not found: $c" | tee -a "$MASTER_LOG"; exit 1; }
  done
}

init_logging_dirs() {
  mkdir -p "$LOGDIR"
  [[ -n "${BACKUP_DIR:-}" ]] && mkdir -p "$BACKUP_DIR"
}
