#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
# /oraprd/oracle_patching_script/patch_orchestrator.sh \
#   -s /oraprd/oracle_patching_script/patch_state.env \
#   -p 38273545
#
# -s: path to patch_state.env (defaults inside each phase script)
# -p: PATCH_ID (e.g., 38273545; optional if you use base-dir napply)

# ------------------------------------------------------------------------------
# Parse args
# ------------------------------------------------------------------------------
STATE_FILE=""
PATCH_ID_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--state) STATE_FILE="$2"; shift 2 ;;
    -p|--patch-id) PATCH_ID_ARG="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ------------------------------------------------------------------------------
# Load state + common
# ------------------------------------------------------------------------------
STATE_FILE="${STATE_FILE:-/oraprd/oracle_patching_script/patch_state.env}"
source "$STATE_FILE"
source /oraprd/oracle_patching_script/scripts/common.sh

# If a patch-id was passed, override PATCH_ID from state
if [[ -n "$PATCH_ID_ARG" ]]; then
  export PATCH_ID="$PATCH_ID_ARG"
fi

init_logging_dirs
log_message "=== Orchestration started ==="

require_var ORACLE_HOME
require_var LOGDIR
require_cmd tee awk grep sed find env bash

# ------------------------------------------------------------------------------
# Pre-flight: normalize all phase scripts (CRLF, HTML entities, shebangs, exec)
# ------------------------------------------------------------------------------
ensure_unix_line_endings_and_shebangs_and_entities() {
  local ROOT_DIR="/oraprd/oracle_patching_script"
  local -a files
  local fixed_crlf=0 fixed_bom=0 fixed_shebang=0 made_exec=0 fixed_entities=0

  # Verify required tools
  for c in bash env sed awk grep find od head chmod; do
    command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing command: $c"; exit 1; }
  done

  # Resolve bash via env
  command -v bash >/dev/null 2>&1 || { echo "ERROR: bash not found in PATH"; exit 1; }
  command -v env  >/dev/null 2>&1 || { echo "ERROR: env not found"; exit 1; }

  mapfile -t files < <(find "$ROOT_DIR" -type f \( -name "*.sh" -o -name "patch_orchestrator.sh" \))

  for f in "${files[@]}"; do
    # Convert CRLF -> LF
    if grep -q $'\r' "$f"; then
      sed -i 's/\r$//' "$f"; ((fixed_crlf++))
    fi

    # Remove UTF-8 BOM (if any)
    if head -c 3 "$f" | od -An -t x1 | awk '{print $1$2$3}' | grep -qi '^efbbbf$'; then
      sed -i '1s/^\xEF\xBB\xBF//' "$f"; ((fixed_bom++))
    fi

    # Replace HTML entities (common copy/paste artifacts)
    if grep -Eq '&amp;|<|>' "$f"; then
      sed -i -e 's/&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;/&&/g' -e 's/</</g' -e 's/>/>/g' "$f"
      ((fixed_entities++))
    fi

    # Ensure proper bash shebang
    first_line="$(head -n1 "$f" || true)"
    if [[ "$first_line" != "#!/usr/bin/env bash" ]]; then
      if [[ "$first_line" =~ ^#! ]]; then
        awk 'NR==1{print "#!/usr/bin/env bash"; next} {print}' "$f" >"${f}.tmp" && mv "${f}.tmp" "$f"
      else
        printf '%s\n' "#!/usr/bin/env bash" | cat - "$f" >"${f}.tmp" && mv "${f}.tmp" "$f"
      fi
      ((fixed_shebang++))
    fi

    # Ensure executable bit
    [[ -x "$f" ]] || { chmod +x "$f"; ((made_exec++)); }
  done

  log_message "Pre-flight normalization summary:"
  log_message " - Files processed:        ${#files[@]}"
  log_message " - CRLF -> LF conversions: $fixed_crlf"
  log_message " - BOM removals:           $fixed_bom"
  log_message " - HTML entity fixes:      $fixed_entities"
  log_message " - Shebang fixes:          $fixed_shebang"
  log_message " - Executable bits set:    $made_exec"

  # Optional: syntax check
  local syntax_errors=0
  for f in "${files[@]}"; do
    if ! bash -n "$f" 2>/dev/null; then
      log_message "WARNING: bash -n reported a syntax issue in: $f"
      ((syntax_errors++))
    fi
  done
  if (( syntax_errors > 0 )); then
    log_message "WARNING: ${syntax_errors} file(s) have syntax warnings—review before proceeding."
  fi
}

ensure_unix_line_endings_and_shebangs_and_entities

# ------------------------------------------------------------------------------
# Phase runner helper
# ------------------------------------------------------------------------------
run_phase() {
  local phase_name="$1"
  local phase_script="$2"
  local phase_state="${3:-$STATE_FILE}"

  log_message "=== ${phase_name}: starting ==="
  local start_ts="$(date +%s)"

  if ! "$phase_script" "$phase_state"; then
    log_message "ERROR: ${phase_name} failed (script: $phase_script)"
    exit 1
  fi

  local end_ts="$(date +%s)"
  local dur=$(( end_ts - start_ts ))
  log_message "=== ${phase_name}: completed in ${dur}s ==="
}

# ------------------------------------------------------------------------------
# Run phases in order
# ------------------------------------------------------------------------------
run_phase "Stop Phase"     "/oraprd/oracle_patching_script/01_stop_db_services.sh"
run_phase "Backup+Patch"   "/oraprd/oracle_patching_script/02_backup_and_patch.sh"
run_phase "Start Phase"    "/oraprd/oracle_patching_script/03_start_db_services.sh"
run_phase "Datapatch Phase" "/oraprd/oracle_patching_script/04_run_datapatch.sh"

log_message "=== Orchestration completed successfully ==="

