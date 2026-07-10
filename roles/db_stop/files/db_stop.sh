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
LISTENER_NAME="${LISTENER_NAME:-LISTENER_${HOSTNAME_UC}}"
MANAGE_LISTENER="${MANAGE_LISTENER:-true}"
TARGET_DB_SIDS="${TARGET_DB_SIDS:-}"
ORAENV_PATH="${ORAENV_PATH:-/usr/local/bin/oraenv}"

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

    export ORACLE_SID
    export ORACLE_HOME
    export PATH="$ORACLE_HOME/bin:$PATH"
    export ORAENV_ASK=NO
    # shellcheck source=/dev/null
    . "$ORAENV_PATH" >/dev/null 2>&1

    if ps -ef | grep "pmon_${ORACLE_SID}" | grep -v grep > /dev/null; then
        echo "DB $ORACLE_SID is RUNNING. Shutting down..." >> "$LOGFILE"

        sqlplus -s / as sysdba <<EOF >> "$LOGFILE"
shutdown immediate;
exit;
EOF

        if [ $? -eq 0 ]; then
            echo "DB $ORACLE_SID shutdown SUCCESSFUL." >> "$LOGFILE"
        else
            echo "ERROR shutting down DB $ORACLE_SID" >> "$LOGFILE"
        fi
    else
        echo "DB $ORACLE_SID already STOPPED." >> "$LOGFILE"
    fi
done < <(grep -v '^#' "$ORATAB" | grep -v '^$')

{
echo "=========================================="
echo "Checking listener: $LISTENER_NAME"
echo "=========================================="
} >> "$LOGFILE"

if [ "$MANAGE_LISTENER" != "true" ]; then
    echo "Listener management disabled. Skipping listener stop." >> "$LOGFILE"
elif ps -ef | grep "[t]nslsnr.*${LISTENER_NAME}" > /dev/null; then
    echo "Stopping listener $LISTENER_NAME..." >> "$LOGFILE"
    lsnrctl stop "$LISTENER_NAME" >> "$LOGFILE"
    if [ $? -eq 0 ]; then
        echo "Listener stopped SUCCESSFULLY." >> "$LOGFILE"
    else
        echo "ERROR stopping listener." >> "$LOGFILE"
    fi
else
    echo "Listener is not running." >> "$LOGFILE"
fi

{
echo "=========================================="
echo "Script completed at $(date +"%Y%m%d_%H%M%S")"
echo "=========================================="
} >> "$LOGFILE"

# Surface the log content on stdout too, so Ansible's registered output
# (and the fail-on-ERROR check in tasks/main.yml) can see it.
cat "$LOGFILE"
