#!/usr/bin/env bash
set -euo pipefail
# Usage: bash /oraprd/oracle_patching_script/03_start_db_services.sh [state_file]

STATE_FILE="${1:-/oraprd/oracle_patching_script/patch_state.env}"
source "$STATE_FILE"
source /oraprd/oracle_patching_script/scripts/common.sh

init_logging_dirs
log_message "=== Start Phase: starting on host $(hostname) ==="

require_var ORACLE_HOME
require_var LOGDIR
require_cmd tee awk grep sqlplus lsnrctl

# --- Select awk binary ---
AWK_BIN="$(command -v gawk || command -v awk)"
require_cmd "$AWK_BIN"

GG_HOME="${GG_HOME:-}"
GG_REQUIRE_WORKERS="${GG_REQUIRE_WORKERS:-true}"  # Configurable: true or false
SETTLE_WAIT_SECONDS="${SETTLE_WAIT_SECONDS:-15}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-900}"  # Increased default timeout to 15 min

# Function to parse GG status
ensure_gg_start_parser() {
  GG_START_AWK="${LOGDIR}/parse_info_all_start.awk"
  cat >"$GG_START_AWK" <<'AWK'
BEGIN { wr=0; mgr="UNKNOWN" }
NF < 2 { next }
{
  prog=$1; stat=$2
}
(prog == "MANAGER") { mgr = toupper(stat); next }
(prog ~ /^(EXTRACT|REPLICAT|DATAPUMP|PEER|SERVER)$/ && toupper(stat)=="RUNNING") { wr++ }
END { print wr, mgr }
AWK
  sed -i 's/$//' "$GG_START_AWK"
}

gg_info_all_snapshot() {
  local info_log="$LOGDIR/ggsci_info_all_$(hostname)_$(date +%F_%H%M%S).log"
  "$GG_HOME/ggsci" >"$info_log" 2>>"$MASTER_LOG" <<'EOI'
info all
exit
EOI
  cat "$info_log"
}

# 1) Start listener
log_message "Starting Oracle Listener"
if "$ORACLE_HOME/bin/lsnrctl" start >>"$MASTER_LOG" 2>&1; then
  log_message "Listener start succeeded"
else
  log_message "Listener start returned non-zero" # continuing
fi

# 2) Start DB instances via /etc/oratab
log_message "Starting DB instances from /etc/oratab"
if [[ -f /etc/oratab ]]; then
  while IFS=: read -r ORATAB_SID ORATAB_HOME ORATAB_FLAG; do
    [[ -z "$ORATAB_SID" || "$ORATAB_SID" =~ ^# ]] && continue
    [[ "$ORATAB_HOME" != "$ORACLE_HOME" ]] && continue
    [[ ! "$ORATAB_FLAG" =~ ^Y ]] && continue
    log_message "Starting instance: $ORATAB_SID"
    export ORACLE_SID="$ORATAB_SID"
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba >>"$MASTER_LOG" 2>&1 <<'EOF'
startup;
exit;
EOF
  done < /etc/oratab
else
  log_message "/etc/oratab not found; cannot auto-start instances"; exit 1
fi

# 3) Restart GoldenGate (if present)
if [[ -d "${GG_HOME}" && -x "$GG_HOME/ggsci" ]]; then
  log_message "Restarting GoldenGate services from $GG_HOME"
  "$GG_HOME/ggsci" >>"$MASTER_LOG" 2>&1 <<'EOF'
start mgr
start *
exit
EOF
  log_message "GoldenGate start commands issued; verifying status..."

  sleep "$SETTLE_WAIT_SECONDS"
  ensure_gg_start_parser
  end=$(( $(date +%s) + TIMEOUT_SECONDS ))

  while true; do
    out="$(gg_info_all_snapshot)"
    echo "$out" >>"$MASTER_LOG"

    if echo "$out" | grep -Eiq '^(EXTRACT|REPLICAT|DATAPUMP|PEER|SERVER)[[:space:]]+(ABENDED|DEAD)'; then
      log_message "Warning: Detected ABENDED/DEAD processes after start—manual review may be required."
    fi

    read -r workers_running manager_status <<<"$(echo "$out" | LC_ALL=C "$AWK_BIN" -f "$GG_START_AWK")"
    [[ -z "$workers_running" ]] && workers_running=0
    [[ -z "$manager_status" ]] && manager_status="UNKNOWN"

    log_message "Snapshot: workers_running=${workers_running}, manager_status=${manager_status}"

    if [[ "$manager_status" == "RUNNING" ]]; then
      if [[ "$GG_REQUIRE_WORKERS" == "true" && "$workers_running" -lt 1 ]]; then
        log_message "Manager is running but no workers started yet (GG_REQUIRE_WORKERS=true)."
      else
        log_message "GoldenGate services are running as per configuration."
        break
      fi
    fi

    if (( $(date +%s) >= end )); then
      if [[ "$manager_status" == "RUNNING" ]]; then
        log_message "Timeout reached: Manager is running but workers did not start. Proceeding with warning."
        break
      else
        log_message "Timeout reached: Manager did not start. Failing Start Phase."
        exit 1
      fi
    fi

    sleep "$POLL_INTERVAL"
  done
else
  log_message "GoldenGate home not found or ggsci not executable; skipping GG start"
fi

log_message "=== Start Phase: completed ==="
