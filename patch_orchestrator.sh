#!/usr/bin/env bash
# Debug mode: export ORCHESTRATOR_DEBUG=1 to see command tracing
if [[ "${ORCHESTRATOR_DEBUG:-0}" == "1" ]]; then
  set -xeuo pipefail
else
  set -euo pipefail
fi

# ------------------------------------------------------------------------------
# Args
# ------------------------------------------------------------------------------
STATE_FILE=""
PATCH_ID_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--state)     STATE_FILE="$2"; shift 2 ;;
    -p|--patch-id)  PATCH_ID_ARG="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ------------------------------------------------------------------------------
# Load state + common
# ------------------------------------------------------------------------------
STATE_FILE="${STATE_FILE:-/oraprd/oracle_patching_script/patch_state.env}"
source "$STATE_FILE"
source /oraprd/oracle_patching_script/scripts/common.sh || { echo "Failed to source common.sh"; exit 1; }

# If a patch-id was passed, override PATCH_ID from state
if [[ -n "${PATCH_ID_ARG:-}" ]]; then export PATCH_ID="$PATCH_ID_ARG"; fi

init_logging_dirs
log_message "=== Orchestration started ==="

require_var ORACLE_HOME
require_var LOGDIR
# include all tools used in pre-flight & runner
require_cmd tee awk grep sed find env bash head od chmod

# ------------------------------------------------------------------------------
# Pre-flight: normalize all shell scripts (CRLF, BOM, HTML entities, shebang, exec)
# ------------------------------------------------------------------------------
ensure_unix_line_endings_and_shebangs_and_entities() {
  local ROOT_DIR="/oraprd/oracle_patching_script"
  local -a files
  local fixed_crlf=0 fixed_bom=0 fixed_shebang=0 made_exec=0 fixed_entities=0

  # Verify required tools
  for c in bash env sed awk grep find od head chmod; do
    command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing command: $c"; return 1; }
  done

  # Resolve bash via env
  command -v bash >/dev/null 2>&1 || { echo "ERROR: bash not found in PATH"; return 1; }
  command -v env  >/dev/null 2>&1 || { echo "ERROR: env not found"; return 1; }

  mapfile -t files < <(find "$ROOT_DIR" -type f \( -name "*.sh" -o -name "patch_orchestrator.sh" \))

  for f in "${files[@]}"; do
    # 1) CRLF -> LF
    if grep -q $'\r' "$f"; then
      sed -i 's/\r$//' "$f"
      ((fixed_crlf++))
    fi

    # 2) Strip UTF-8 BOM (if present)
    if head -c 3 "$f" | od -An -t x1 | awk '{print $1$2$3}' | grep -qi '^efbbbf$'; then
      sed -i '1s/^\xEF\xBB\xBF//' "$f"
      ((fixed_bom++))
    fi

    # 3) Replace HTML entities (fix common copy/paste artifacts)
    if grep -Eq '&amp;|<|>' "$f"; then
      sed -i -e 's/&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;&amp;/&&/g' -e 's/</</g' -e 's/>/>/g' "$f"
      ((fixed_entities++))
    fi

    # 4) Ensure proper bash shebang
    local first_line
    first_line="$(head -n1 "$f" || true)"
    if [[ "$first_line" != "#!/usr/bin/env bash" ]]; then
      if [[ "$first_line" =~ ^#! ]]; then
        awk 'NR==1{print "#!/usr/bin/env bash"; next} {print}' "$f" >"${f}.tmp" && mv "${f}.tmp" "$f"
      else
        printf '%s\n' "#!/usr/bin/env bash" | cat - "$f" >"${f}.tmp" && mv "${f}.tmp" "$f"
      fi
      ((fixed_shebang++))
    fi

    # 5) Ensure executable bit
    if [[ ! -x "$f" ]]; then
      chmod +x "$f"
      ((made_exec++))
    fi
  done

  log_message "Pre-flight normalization summary:"
  log_message " - Files processed:        ${#files[@]}"
  log_message " - CRLF -> LF conversions: $fixed_crlf"
  log_message " - BOM removals:           $fixed_bom"
  log_message " - HTML entity fixes:      $fixed_entities"
  log_message " - Shebang fixes:          $fixed_shebang"
  log_message " - Executable bits set:    $made_exec"

  # Optional: syntax check (won't abort orchestrator)
  local syntax_errors=0
  for f in "${files[@]}"; do
    if ! bash -n "$f" 2>/dev/null; then
      log_message "WARNING: bash -n reported a syntax issue in: $f"
      ((syntax_errors++))
    fi
  done
  if (( syntax_errors > 0 )); then
    log_message "WARNING: $syntax_errors file(s) have syntax warnings."
  fi
}

# Wrap pre-flight to log failure instead of silent exit
if ! ensure_unix_line_endings_and_shebangs_and_entities; then
  log_message "ERROR: Pre-flight normalization failed"
  exit 1
fi

# ------------------------------------------------------------------------------
# Phase runner helper
# ------------------------------------------------------------------------------
run_phase() {
  local phase_name="$1"; shift
  local phase_script="$1"; shift
  local phase_state="${1:-$STATE_FILE}"

  # Check existence and executable
  if [[ ! -x "$phase_script" ]]; then
    log_message "ERROR: Phase script not found/executable: $phase_script"
    return 1
  fi

  log_message "=== ${phase_name}: starting ==="
  local start_ts="$(date +%s)"

  # Execute with bash to avoid shebang/PATH surprises
  if ! bash "$phase_script" "$phase_state" >>"$MASTER_LOG" 2>&1; then
    local rc=$?
    log_message "ERROR: ${phase_name} failed with rc=${rc} (script: $phase_script). See $MASTER_LOG"
    return $rc
  fi

  local dur=$(( $(date +%s) - start_ts ))
  log_message "=== ${phase_name}: completed in ${dur}s ==="
  return 0
}

# ------------------------------------------------------------------------------
# Run phases in order
# ------------------------------------------------------------------------------
run_phase "Stop Phase"      "/oraprd/oracle_patching_script/01_stop_db_services.sh"    || exit 1
run_phase "Backup+Patch"    "/oraprd/oracle_patching_script/02_backup_and_patch.sh"    || exit 1
run_phase "Start Phase"     "/oraprd/oracle_patching_script/03_start_db_services.sh"   || exit 1
run_phase "Datapatch Phase" "/oraprd/oracle_patching_script/04_run_datapatch.sh"       || exit 1

log_message "=== Orchestration completed successfully ==="

