#!/usr/bin/env bash
set -euo pipefail
# Usage: bash 01_stop_db_services.sh [state_file]

STATE_FILE="${1:-/oraprd/oracle_patching_script/patch_state.env}"
source "$STATE_FILE"
source /oraprd/oracle_patching_script/scripts/common.sh

init_logging_dirs
log_message "=== Stop Phase: starting on host $(hostname) ==="

require_var ORACLE_HOME
require_var LOGDIR
require_cmd tee awk grep ps sqlplus

# Choose a reliable awk binary and ensure it's present
AWK_BIN="$(command -v gawk || command -v awk)"
require_cmd "$AWK_BIN"

# ------------------------------------------------------------------------------
# Helpers: GGSCI info snapshot, parser, per-group force stop, OS kill (last resort)
# ------------------------------------------------------------------------------

gg_info_all_snapshot() {
  local info_log="$LOGDIR/ggsci_info_all_$(hostname)_$(date +%F_%H%M%S).log"
  "$GG_HOME/ggsci" >"$info_log" 2>>"$MASTER_LOG" <<'EOI'
info all
exit
EOI
  cat "$info_log"
}

ensure_gg_info_parser() {
  GG_INFO_AWK="${LOGDIR}/parse_info_all.awk"
  cat >"$GG_INFO_AWK" <<'AWK'
BEGIN { wr=0; mgr="UNKNOWN" }
NF < 2 { next }
{
  prog=$1; stat=$2
}
(prog == "MANAGER") {
  mgr = toupper(stat)
  next
}
(prog ~ /^(EXTRACT|REPLICAT)$/ && stat == "RUNNING") { wr++ }
END { print wr, mgr }
AWK
  sed -i 's/\r$//' "$GG_INFO_AWK"
}

gg_parse_running_groups() {
  # Reads GGSCI "info all" text from stdin; prints "TYPE GROUP" for RUNNING
  LC_ALL=C "$AWK_BIN" -v IGNORECASE=1 '
    $1 ~ /^(EXTRACT|REPLICAT)$/ && $2=="RUNNING" { print $1, $3 }
  '
}

stop_running_workers_by_group() {
  local info_out
  info_out="$(gg_info_all_snapshot)"
  mapfile -t groups < <(echo "$info_out" | gg_parse_running_groups)
  if (( ${#groups[@]} > 0 )); then
    for line in "${groups[@]}"; do
      set -- $line
      local typ="$1" grp="$2"
      log_message "Stopping $typ $grp with force..."
      "$GG_HOME/ggsci" >>"$MASTER_LOG" 2>&1 <<EOF
stop $typ $grp !
exit
EOF
    done
  fi
}

kill_goldengate_workers_os() {
  ps -ef | awk -v gh="$GG_HOME" '
    BEGIN{IGNORECASE=1}
    ($8 ~ /extract|replicat/ && index($0, gh)) { print $2, $8 }
  ' | while read -r pid cmd; do
    log_message "Killing $cmd (PID $pid) with TERM, then KILL if needed..."
    kill -TERM "$pid" || true
    sleep 3
    kill -KILL "$pid" || true
  done
}

# ------------------------------------------------------------------------------
# 1) Backup crontab (optional)
# ------------------------------------------------------------------------------
if command -v crontab >/dev/null 2>&1; then
  if crontab -l > "${CRONTAB_BACKUP:-$LOGDIR/crontab_backup_$(date +%Y%m%d-%H%M).txt}" 2>>"$STEP_LOG"; then
    log_message "Crontab backed up to ${CRONTAB_BACKUP:-$LOGDIR/...}"
  else
    log_message "Failed to backup crontab (continuing)"
  fi
fi

# ------------------------------------------------------------------------------
# 2) Stop GoldenGate (if present) — graceful stop, settle, then validate
# ------------------------------------------------------------------------------
if [[ -d "${GG_HOME:-}" ]]; then
  if [[ ! -x "$GG_HOME/ggsci" ]]; then
    log_message "ggsci not executable at $GG_HOME/ggsci"
    exit 1
  fi

  log_message "Stopping GoldenGate services from $GG_HOME"

  # Graceful stop first
  "$GG_HOME/ggsci" >>"$MASTER_LOG" 2>&1 <<'EOF'
stop *
stop mgr !
exit
EOF

  # Settling wait
  SETTLE_WAIT_SECONDS="${SETTLE_WAIT_SECONDS:-15}"
  log_message "Waiting ${SETTLE_WAIT_SECONDS}s for GoldenGate processes to settle..."
  sleep "$SETTLE_WAIT_SECONDS"

  # Poll + validate
  TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"
  POLL_INTERVAL="${POLL_INTERVAL:-5}"
  end=$(( $(date +%s) + TIMEOUT_SECONDS ))

  ensure_gg_info_parser

  while true; do
    out="$(gg_info_all_snapshot)"
    echo "$out" >>"$MASTER_LOG"

    # Optional: flag ABENDED/DEAD
    if echo "$out" | grep -Eiq '^(EXTRACT|REPLICAT)[[:space:]]+(ABENDED|DEAD)'; then
      log_message "Detected ABENDED/DEAD processes—manual review may be required."
    fi

    read -r workers_running manager_status <<<"$(echo "$out" | LC_ALL=C "$AWK_BIN" -v IGNORECASE=1 -f "$GG_INFO_AWK")"
    [[ -z "$workers_running" ]] && workers_running=0
    [[ -z "$manager_status" ]] && manager_status="UNKNOWN"

    log_message "Snapshot: workers_running=${workers_running}, manager_status=${manager_status}"

    # If workers still RUNNING, try per-group force
    if (( workers_running > 0 )); then
      log_message "Workers still RUNNING; attempting explicit force stop per group..."
      stop_running_workers_by_group
      sleep "$POLL_INTERVAL"
    fi

    # If no workers RUNNING, ensure manager is stopped
    if (( workers_running == 0 )); then
      if [[ "$manager_status" == "RUNNING" ]]; then
        log_message "Manager still RUNNING; attempting force stop..."
        "$GG_HOME/ggsci" >>"$MASTER_LOG" 2>&1 <<'EOF'
stop mgr !
exit
EOF
        sleep 2
      fi

      # Final check
      out="$(gg_info_all_snapshot)"
      echo "$out" >>"$MASTER_LOG"
      # Count workers
      workers_running="$(echo "$out" | LC_ALL=C "$AWK_BIN" -v IGNORECASE=1 '
        $1 ~ /^(EXTRACT|REPLICAT)$/ && toupper($2)=="RUNNING" { c++ }
        END { print c+0 }
      ')"
      # Manager status
      manager_status="$(echo "$out" | LC_ALL=C "$AWK_BIN" -v IGNORECASE=1 '
        $1=="MANAGER"{print toupper($2)}
      ')"
      [[ -z "$manager_status" ]] && manager_status="UNKNOWN"

      if (( workers_running == 0 )) && [[ "$manager_status" == "STOPPED" || "$manager_status" == "UNKNOWN" ]]; then
        log_message "GoldenGate services fully stopped."
        break
      fi
    fi

    # Timeout fallback
    if (( $(date +%s) >= end )); then
      log_message "Timeout reached; issuing global force stop and per-group force stop."
      "$GG_HOME/ggsci" >>"$MASTER_LOG" 2>&1 <<'EOF'
stop * !
exit
EOF
      stop_running_workers_by_group
      sleep "$POLL_INTERVAL"

      out="$(gg_info_all_snapshot)"
      echo "$out" >>"$MASTER_LOG"
      workers_running="$(echo "$out" | LC_ALL=C "$AWK_BIN" -v IGNORECASE=1 '
        $1 ~ /^(EXTRACT|REPLICAT)$/ && toupper($2)=="RUNNING" { c++ }
        END { print c+0 }
      ')"

      if (( workers_running > 0 )); then
        log_message "Some processes still RUNNING after all stop attempts; killing at OS level."
        kill_goldengate_workers_os
        sleep 3
      fi

      log_message "GoldenGate stop sequence completed after timeout fallback."
      break
    fi
  done

else
  log_message "GoldenGate home not found; skipping GG stop"
fi

# ------------------------------------------------------------------------------
# 3) Stop Oracle DB instances (PMON discovery)
# ------------------------------------------------------------------------------
log_message "Stopping Oracle DB instances (PMON discovery)"
while read -r ORACLE_SID; do
  [[ -z "$ORACLE_SID" ]] && continue
  log_message "Stopping instance: $ORACLE_SID"
  export ORACLE_SID="$ORACLE_SID"
  "$ORACLE_HOME/bin/sqlplus" -s / as sysdba >>"$MASTER_LOG" 2>&1 <<'EOF'
shutdown immediate;
exit;
EOF
done < <(ps -ef | grep '[o]ra_pmon_' | awk -F_ '{print $3}')

# ------------------------------------------------------------------------------
# 4) Stop listener
# ------------------------------------------------------------------------------
log_message "Stopping Oracle Listener"
if "$ORACLE_HOME/bin/lsnrctl" stop >>"$MASTER_LOG" 2>&1; then
  log_message "Listener stop succeeded"
else
  log_message "Listener stop returned non-zero"
fi

log_message "=== Stop Phase: completed ==="

