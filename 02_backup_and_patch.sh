#!/usr/bin/env bash
set -euo pipefail
# Usage: bash /oraprd/oracle_patching_script/02_backup_and_patch.sh [state_file]

STATE_FILE="${1:-/oraprd/oracle_patching_script/patch_state.env}"
source "$STATE_FILE"
source /oraprd/oracle_patching_script/scripts/common.sh

init_logging_dirs
log_message "=== Backup + Patch Phase: starting on host $(hostname) ==="

require_var ORACLE_HOME
require_var PATCH_BASE_DIR
require_var BACKUP_DIR
require_cmd tee awk grep du tar unzip

PATCH_DIR="${PATCH_BASE_DIR}/${PATCH_ID:-}"

# 1) Verify patch directory exists (when PATCH_ID is set)
if [[ -n "${PATCH_ID:-}" ]]; then
  if [[ -d "$PATCH_DIR" ]]; then
    log_message "Patch ID $PATCH_ID exists under $PATCH_BASE_DIR"
  else
    log_message "Patch ID $PATCH_ID not found under $PATCH_BASE_DIR"; exit 1
  fi
else
  log_message "PATCH_ID not set; will run 'opatch napply' on $PATCH_BASE_DIR"
fi

# 2) Backup Oracle Home (exact path)
backup_tar="${BACKUP_DIR}/oracle_home_backup_$(date +%Y%m%d-%H%M%S).tgz"
log_message "Backing up ORACLE_HOME ($ORACLE_HOME) to $backup_tar"
mkdir -p "$BACKUP_DIR"
(
  cd "$(dirname "$ORACLE_HOME")" && tar -zcvf "$backup_tar" "$(basename "$ORACLE_HOME")" >>"$MASTER_LOG" 2>&1
)
if [[ -f "$backup_tar" ]]; then
  size="$(du -h "$backup_tar" | cut -f1)"
  log_message "Oracle Home backup created (size: $size)"
else
  log_message "Backup file not found at $backup_tar"; exit 1
fi

# 3) Check current OPatch version
log_message "Checking current OPatch version"
if "$ORACLE_HOME/OPatch/opatch" version >>"$MASTER_LOG" 2>&1; then
  log_message "OPatch version check succeeded"
else
  log_message "OPatch version check returned non-zero"; exit 1
fi

# 4) Update OPatch (if LATEST_OPATCH_ZIP exists)
if [[ -n "${LATEST_OPATCH_ZIP:-}" && -f "$LATEST_OPATCH_ZIP" ]]; then
  log_message "Updating OPatch from $LATEST_OPATCH_ZIP"
  mv "$ORACLE_HOME/OPatch" "$ORACLE_HOME/OPatch_old_$(date +%s)" >>"$MASTER_LOG" 2>&1 || true
  (
    cd "$ORACLE_HOME" && unzip -q "$LATEST_OPATCH_ZIP" >>"$MASTER_LOG" 2>&1
  )
  if "$ORACLE_HOME/OPatch/opatch" version >>"$MASTER_LOG" 2>&1; then
    log_message "OPatch utility updated"
  else
    log_message "OPatch update failed"; exit 1
  fi
else
  log_message "LATEST_OPATCH_ZIP not provided or not found; skipping OPatch update"
fi

# 5) Check patch conflicts / layout (supports DBRU+OJVM under a single top folder)
OPATCH_BIN="$ORACLE_HOME/OPatch/opatch"
if [[ ! -x "$OPATCH_BIN" ]]; then
  log_message "OPatch not found/executable at $OPATCH_BIN"; exit 1
fi

child_patch_dirs=()
if [[ -n "${PATCH_ID:-}" ]]; then
  while IFS= read -r d; do child_patch_dirs+=("$d"); done < <(find "$PATCH_DIR" -mindepth 1 -maxdepth 1 -type d)

  if (( ${#child_patch_dirs[@]} > 0 )); then
    log_message "Detected ${#child_patch_dirs[@]} patch set(s) under $PATCH_DIR; running prereq at base dir"
    if "$OPATCH_BIN" prereq CheckConflictAgainstOHWithDetail -phBaseDir "$PATCH_DIR" >>"$MASTER_LOG" 2>&1; then
      if grep -q 'Prereq "checkConflictAgainstOHWithDetail" passed.' "$MASTER_LOG"; then
        log_message "No conflicts detected at base dir $PATCH_DIR"
      else
        log_message "Prereq did not report PASS; review $MASTER_LOG"; exit 1
      fi
    else
      log_message "Prereq returned non-zero for base dir $PATCH_DIR; review $MASTER_LOG"; exit 1
    fi
  else
    # Single patch layout in PATCH_DIR
    if [[ ! -f "$PATCH_DIR/patch.xml" && ! -f "$PATCH_DIR/etc/config/inventory.xml" && ! -d "$PATCH_DIR/files" ]]; then
      log_message "Invalid patch layout in $PATCH_DIR (no patch.xml/etc/files). Is the zip fully unzipped?"; exit 135
    fi
    log_message "Single patch detected in $PATCH_DIR; running prereq for the single patch"
    if "$OPATCH_BIN" prereq CheckConflictAgainstOHWithDetail -phBaseDir "$PATCH_DIR" >>"$MASTER_LOG" 2>&1; then
      if grep -q 'Prereq "checkConflictAgainstOHWithDetail" passed.' "$MASTER_LOG"; then
        log_message "No conflicts detected for $PATCH_DIR"
      else
        log_message "Prereq did not report PASS; review $MASTER_LOG"; exit 1
      fi
    else
      log_message "Prereq returned non-zero for $PATCH_DIR; review $MASTER_LOG"; exit 1
    fi
  fi
else
  log_message "PATCH_ID not set; will run napply across base dir $PATCH_BASE_DIR"
fi

# 6) Apply patch(es) — supports DBRU+OJVM under top-level PATCH_DIR
if [[ -n "${PATCH_ID:-}" ]]; then
  if (( ${#child_patch_dirs[@]} > 0 )); then
    log_message "Applying DBRU+OJVM via opatch napply -phBaseDir $PATCH_DIR"
    if ! ( cd "$PATCH_DIR" && "$OPATCH_BIN" napply -silent -oh "$ORACLE_HOME" -phBaseDir "$PATCH_DIR" >>"$MASTER_LOG" 2>&1 ); then
      log_message "OPatch napply failed under $PATCH_DIR"; exit 135
    fi
  else
    log_message "Applying single patch via opatch apply from $PATCH_DIR"
    "$OPATCH_BIN" apply -oh "$ORACLE_HOME" -report "$PATCH_DIR" >>"$MASTER_LOG" 2>&1 || { log_message "OPatch report failed for $PATCH_DIR"; exit 1; }
    if ! ( cd "$PATCH_DIR" && "$OPATCH_BIN" apply -silent -oh "$ORACLE_HOME" >>"$MASTER_LOG" 2>&1 ); then
      log_message "OPatch apply failed for $PATCH_DIR"; exit 135
    fi
  fi
else
  log_message "Applying patches (napply) from base dir $PATCH_BASE_DIR"
  if ! ( cd "$PATCH_BASE_DIR" && "$OPATCH_BIN" napply -silent >>"$MASTER_LOG" 2>&1 ); then
    log_message "OPatch napply failed under $PATCH_BASE_DIR"; exit 135
  fi
fi

# Verify success via OPatch output
if grep -Eq "OPatch completed successfully|OPatch succeeded" "$MASTER_LOG"; then
  log_message "Patch apply succeeded"
else
  log_message "Patch apply failed; see $MASTER_LOG"; exit 1
fi

# 7) List applied patches
log_message "Listing applied patches"
if "$OPATCH_BIN" lspatches >>"$MASTER_LOG" 2>&1; then
  log_message "Listed applied patches successfully"
else
  log_message "lspatches returned non-zero (check OPatch output)"
fi

log_message "=== Backup + Patch Phase: completed ==="

