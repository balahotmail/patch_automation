#!/usr/bin/bash
# ------------------------------------------------------
# Name   : listener_start.sh
# Purpose: Start the listener only.
# Notes  : Must run as the configured Oracle OS user.
# ------------------------------------------------------

set -u

WHOAMI=$(whoami)
EXPECTED_OS_USER="${EXPECTED_OS_USER:-oracle}"
if [ "$WHOAMI" != "$EXPECTED_OS_USER" ]; then
  echo "Aborting script execution. This script must be run as the ${EXPECTED_OS_USER} user."
  exit 4
fi

ORACLE_PROFILE="${ORACLE_PROFILE:-$HOME/.profile}"
if [ -f "$ORACLE_PROFILE" ]; then
  . "$ORACLE_PROFILE"
fi

ORACLE_HOME="${ORACLE_HOME:-}"
ORACLE_BASE="${ORACLE_BASE:-}"
ORAENV_PATH="${ORAENV_PATH:-/usr/local/bin/oraenv}"
ORATAB="${ORATAB:-/etc/oratab}"
TARGET_DB_SIDS="${TARGET_DB_SIDS:-}"
LISTENER_NAME="${LISTENER_NAME:-LISTENER}"
MANAGE_LISTENER="${MANAGE_LISTENER:-true}"

if [ -n "$ORACLE_HOME" ] && [ -x "$ORACLE_HOME/bin/sqlplus" ]; then
  export ORACLE_HOME ORACLE_BASE
  export PATH="$ORACLE_HOME/bin:$PATH"
else
  # Only source oraenv if ORACLE_SID is provided so oraenv can resolve ORACLE_HOME
  if [ -n "${ORACLE_SID:-}" ]; then
    ORAENV_ASK=NO
    export ORAENV_ASK
    # shellcheck source=/dev/null
    . "$ORAENV_PATH"
    export PATH="$ORACLE_HOME/bin:$PATH"
  else
    echo "ORACLE_HOME not provided and ORACLE_SID not set; skipping oraenv. ORACLE_HOME may be required for listener start." | tee -a "$LOGFILE"
  fi
fi

LOGDIR="$1"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/listener_start_$(date '+%d%b%Y_%H%M%S').log"

{
echo "=========================================="
echo "Starting listener..."
echo "=========================================="
} > "$LOGFILE"

if [ "$MANAGE_LISTENER" = "true" ]; then
  echo "Starting listener $LISTENER_NAME..." | tee -a "$LOGFILE"
  LSNRCTL_BIN=""
  if [ -n "${ORACLE_HOME:-}" ] && [ -x "$ORACLE_HOME/bin/lsnrctl" ]; then
    LSNRCTL_BIN="$ORACLE_HOME/bin/lsnrctl"
  elif command -v lsnrctl >/dev/null 2>&1; then
    LSNRCTL_BIN="$(command -v lsnrctl)"
  fi

  if [ -n "$LSNRCTL_BIN" ]; then
    "$LSNRCTL_BIN" start "$LISTENER_NAME" 2>&1 | tee -a "$LOGFILE"
    if [ $? -eq 0 ]; then
      echo "Listener started SUCCESSFULLY." | tee -a "$LOGFILE"
    else
      echo "ERROR starting listener. Check $LSNRCTL_BIN output." | tee -a "$LOGFILE"
    fi
  else
    echo "WARNING: lsnrctl not found. Skipping listener start." | tee -a "$LOGFILE"
  fi
fi
