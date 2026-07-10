#!/usr/bin/bash
# ------------------------------------------------------
# Name   : listener_start.sh
# Purpose: Start the TNS listener if it is not already running.
# Notes  : Must run as the configured Oracle OS user.
#
# FIX vs. original tnsagent_start.sh: the original checked
# `if ps -ef | grep tnslsnr` (listener IS running) and then tried to
# START it in that branch, and did nothing when it was actually down.
# That's backwards. This version starts it only when it's NOT running,
# and is a no-op (with a log line) if it's already up.
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
LOGFILE="$LOGDIR/listener_start_$DATE1.log"
HOSTNAME_UC=$(hostname -s | tr '[:lower:]' '[:upper:]')
LISTENER_NAME="${LISTENER_NAME:-LISTENER_${HOSTNAME_UC}}"
MANAGE_LISTENER="${MANAGE_LISTENER:-true}"

mkdir -p "$LOGDIR"

{
echo "=========================================="
echo "Checking listener: $LISTENER_NAME"
echo "=========================================="
} >> "$LOGFILE"

if [ "$MANAGE_LISTENER" != "true" ]; then
    echo "Listener management disabled. Skipping listener start." >> "$LOGFILE"
elif ps -ef | grep "[t]nslsnr.*${LISTENER_NAME}" > /dev/null; then
    echo "Listener $LISTENER_NAME is already running. Nothing to do." >> "$LOGFILE"
else
    echo "Starting listener $LISTENER_NAME..." >> "$LOGFILE"
    lsnrctl start "$LISTENER_NAME" >> "$LOGFILE"
    if [ $? -eq 0 ]; then
        echo "Listener started SUCCESSFULLY." >> "$LOGFILE"
    else
        echo "ERROR starting listener." >> "$LOGFILE"
    fi
fi

{
echo "=========================================="
echo "Script completed at $(date +"%Y%m%d_%H%M%S")"
echo "=========================================="
} >> "$LOGFILE"

cat "$LOGFILE"
