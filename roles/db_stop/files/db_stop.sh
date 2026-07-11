#!/usr/bin/bash
# ------------------------------------------------------
# Name   : db_stop.sh
# Purpose: Stop selected Oracle DBs from the configured oratab,
#          then optionally stop the configured TNS listener.
# Notes  : Must run as the configured Oracle OS user.
# ------------------------------------------------------

set -u

WHOAMI=$(whoami)
EXPECTED_OS_USER="${EXPECTED_OS_USER:-oracle}"
if [ "$WHOAMI" != "$EXPECTED_OS_USER" ]; then
  echo "Aborting script execution. This script must be run as the ${EXPECTED_OS_USER} user."
  exit 4
fi

# shellcheck source=/dev/null
ORACLE_PROFILE="${ORACLE_PROFILE:-$HOME/.profile}"
if [ -f "$ORACLE_PROFILE" ]; then
  . "$ORACLE_PROFILE"
fi

DATE1=$(date '+%d%b%Y_%H%M%S')
LOGDIR="$1"
LOGFILE="$LOGDIR/status_of_all_db_stop_$DATE1.log"
ORATAB="${ORATAB:-/etc/oratab}"
HOSTNAME_UC=$(hostname -s | tr '[:lower:]' '[:upper:]')
# Do not auto-derive a listener name from the hostname.
# Require an explicit LISTENER_NAME (from Ansible variable `listener_name`).
# If left empty, listener management will be skipped unless `manage_listener`
# is set to false (in which case we also skip listener operations).
LISTENER_NAME="${LISTENER_NAME:-}"
MANAGE_LISTENER="${MANAGE_LISTENER:-true}"
TARGET_DB_SIDS="${TARGET_DB_SIDS:-}"
ORAENV_PATH="${ORAENV_PATH:-/usr/local/bin/oraenv}"
DBS_PROCESSED=0
DBS_STOPPED_OK=0
DBS_STOPPED_ERROR=0

mkdir -p "$LOGDIR"

{
echo "=========================================="
echo "DB shutdown initiated at $DATE1"
echo "=========================================="
} >> "$LOGFILE"

if [ ! -f "$ORATAB" ]; then
    echo "oratab file not found!" >> "$LOGFILE"
    exit 1
fi

should_process_sid() {
    [ -z "$TARGET_DB_SIDS" ] && return 0
    for sid in $TARGET_DB_SIDS; do
        [ "$sid" = "$1" ] && return 0
    done
    return 1
}

while IFS=: read -r ORACLE_SID ORACLE_HOME FLAG; do
    [ "$FLAG" = "Y" ] || continue
    should_process_sid "$ORACLE_SID" || continue

    {
    echo "------------------------------------------"
    echo "Processing DB: $ORACLE_SID"
    } >> "$LOGFILE"

    DBS_PROCESSED=$((DBS_PROCESSED + 1))
    export ORACLE_SID
    export ORACLE_HOME
    export ORACLE_BASE
    export PATH="$ORACLE_HOME/bin:$PATH"
    export ORAENV_ASK=NO
    # shellcheck source=/dev/null
    . "$ORAENV_PATH" >/dev/null 2>&1

    SQLPLUS_BIN="$ORACLE_HOME/bin/sqlplus"
    if [ ! -x "$SQLPLUS_BIN" ]; then
        echo "ERROR: sqlplus not found at $SQLPLUS_BIN" >> "$LOGFILE"
        DBS_STOPPED_ERROR=$((DBS_STOPPED_ERROR + 1))
        continue
    fi

    if ps -ef | grep "pmon_${ORACLE_SID}" | grep -v grep > /dev/null; then
        echo "DB $ORACLE_SID is RUNNING. Shutting down..." >> "$LOGFILE"

        "$SQLPLUS_BIN" -s / as sysdba <<EOF >> "$LOGFILE" 2>&1
shutdown immediate;
exit;
EOF

        if [ $? -eq 0 ]; then
            echo "DB $ORACLE_SID shutdown SUCCESSFUL." >> "$LOGFILE"
            DBS_STOPPED_OK=$((DBS_STOPPED_OK + 1))
        else
            echo "ERROR shutting down DB $ORACLE_SID" >> "$LOGFILE"
            DBS_STOPPED_ERROR=$((DBS_STOPPED_ERROR + 1))
        fi
    else
        echo "DB $ORACLE_SID already STOPPED." >> "$LOGFILE"
        DBS_STOPPED_OK=$((DBS_STOPPED_OK + 1))
    fi
done < <(grep -v '^#' "$ORATAB" | grep -v '^$')

{
echo "=========================================="
if [ -n "$LISTENER_NAME" ]; then
  echo "Checking listener: $LISTENER_NAME"
else
  echo "Checking listener: <none configured>"
fi
echo "=========================================="
} >> "$LOGFILE"

if [ "$MANAGE_LISTENER" != "true" ]; then
    echo "Listener management disabled. Skipping listener stop." >> "$LOGFILE"
elif [ -z "$LISTENER_NAME" ]; then
    echo "No listener name configured. Skipping listener stop." >> "$LOGFILE"
elif ps -ef | grep "[t]nslsnr.*${LISTENER_NAME}" > /dev/null; then
    echo "Stopping listener $LISTENER_NAME..." >> "$LOGFILE"
    LSNRCTL_BIN=""
    if [ -n "${ORACLE_HOME:-}" ] && [ -x "$ORACLE_HOME/bin/lsnrctl" ]; then
        LSNRCTL_BIN="$ORACLE_HOME/bin/lsnrctl"
    elif command -v lsnrctl >/dev/null 2>&1; then
        LSNRCTL_BIN="$(command -v lsnrctl)"
    fi

    if [ -n "$LSNRCTL_BIN" ]; then
        "$LSNRCTL_BIN" stop "$LISTENER_NAME" >> "$LOGFILE" 2>&1
        if [ $? -eq 0 ]; then
            if ps -ef | grep "[t]nslsnr.*${LISTENER_NAME}" > /dev/null; then
                echo "WARNING: listener stop command returned success but listener process is still running." >> "$LOGFILE"
            else
                echo "Listener stopped SUCCESSFULLY." >> "$LOGFILE"
            fi
        else
            if ps -ef | grep "[t]nslsnr.*${LISTENER_NAME}" > /dev/null; then
                echo "WARNING: listener stop failed but listener process is still running. Continuing." >> "$LOGFILE"
            else
                echo "Listener is not running after stop attempt." >> "$LOGFILE"
            fi
        fi
    else
        echo "WARNING: lsnrctl not found. Continuing without listener stop." >> "$LOGFILE"
    fi
else
    echo "Listener is not running." >> "$LOGFILE"
fi

if [ "$DBS_PROCESSED" -eq 0 ]; then
    echo "WARNING: no matching databases were found in $ORATAB for shutdown." >> "$LOGFILE"
fi

if [ "$DBS_STOPPED_ERROR" -gt 0 ]; then
    echo "ERROR: one or more databases failed to stop cleanly." >> "$LOGFILE"
    exit 3
fi

{
echo "=========================================="
echo "Script completed at $(date +"%Y%m%d_%H%M%S")"
echo "=========================================="
} >> "$LOGFILE"

# Surface the log content on stdout too, so Ansible's registered output
# (and the fail-on-ERROR check in tasks/main.yml) can see it.
cat "$LOGFILE"
