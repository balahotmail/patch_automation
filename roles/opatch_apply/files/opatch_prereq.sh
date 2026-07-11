#!/usr/bin/bash
# ------------------------------------------------------
# Name   : opatch_prereq.sh
# Purpose: Run OPatch conflict/prerequisite checks for the combo (DBPSU)
#          and OJVM patches before attempting to apply them.
# Notes  : Must run as the configured Oracle OS user.
#
# Positional args:
#   $1 OH_ALIAS       - ORACLE_SID-style alias used to source oraenv
#   $2 PATCHSTAGE     - staging dir containing extracted patch subfolders
#   $3 COMBOPATCH     - combo patch number (for logging/masterlog only)
#   $4 DBPSUPATCH     - DBPSU/combo patch subfolder number under PATCHSTAGE
#   $5 OJVMPATCH      - OJVM patch subfolder number under PATCHSTAGE
#   $6 OPATCHVERSION  - expected `opatch version` string
#   $7 MASTERLOG      - shared status/audit log across all steps
#   $8 LOGDIR         - directory for this run's detailed log
#
# Env (optional, set by Ansible `environment:`):
#   NOTIFY_ENABLED    - "true"/"false" (default: true)
#   NOTIFY_EMAIL_TO   - comma-separated recipient list
#   NOTIFY_EMAIL_FROM - from address
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

SECONDS=0
OH_ALIAS="$1"
PATCHSTAGE="$2"
COMBOPATCH="$3"
DBPSUPATCH="$4"
OJVMPATCH="$5"
OPATCHVERSION="$6"
MASTERLOG="$7"
LOGDIR="$8"

DATE1=$(date +%d%m%Y_%H-%M-%S)
LOGFILE="$LOGDIR/opatch_prereq_${COMBOPATCH}_${DATE1}.log"

NOTIFY_ENABLED="${NOTIFY_ENABLED:-true}"
NOTIFY_EMAIL_TO="${NOTIFY_EMAIL_TO:-}"
NOTIFY_EMAIL_FROM="${NOTIFY_EMAIL_FROM:-}"

notify() {
  # notify "subject"  -- reads body from stdin
  local subject="$1"
  if [ "$NOTIFY_ENABLED" = "true" ] && [ -n "$NOTIFY_EMAIL_TO" ] && command -v mailx >/dev/null 2>&1; then
    mailx -s "$subject" -r "$NOTIFY_EMAIL_FROM" "$NOTIFY_EMAIL_TO"
  else
    cat >/dev/null   # discard body so callers can always pipe into notify
  fi
}

mkdir -p "$LOGDIR"

PREREQ_TIMEOUT_SECONDS="${PREREQ_TIMEOUT_SECONDS:-1800}"
run_opatch_prereq() {
  local patch_dir="$1"
  echo "Running OPatch prerequisite check for $patch_dir (timeout ${PREREQ_TIMEOUT_SECONDS}s)" | tee -a "$LOGFILE"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$PREREQ_TIMEOUT_SECONDS" "$OPATCH" prereq CheckConflictAgainstOHWithDetail -ph "$patch_dir" >> "$LOGFILE" 2>&1
  else
    "$OPATCH" prereq CheckConflictAgainstOHWithDetail -ph "$patch_dir" >> "$LOGFILE" 2>&1
  fi
}

ORACLE_SID="${ORACLE_SID:-$OH_ALIAS}"
export ORACLE_SID
ORAENV_PATH="${ORAENV_PATH:-/usr/local/bin/oraenv}"

if [ -n "${ORACLE_HOME:-}" ] && [ -x "$ORACLE_HOME/OPatch/opatch" ]; then
  export ORACLE_HOME
  if [ -n "${ORACLE_BASE:-}" ]; then
    export ORACLE_BASE
  fi
  export PATH="$ORACLE_HOME/bin:$ORACLE_HOME/OPatch:$PATH:/usr/ccs/bin"
else
  ORAENV_ASK=NO
  export ORAENV_ASK
  # shellcheck source=/dev/null
  . "$ORAENV_PATH"
  export PATH="$ORACLE_HOME/bin:$ORACLE_HOME/OPatch:$PATH:/usr/ccs/bin"
fi

HOST=$(hostname | tr '[:lower:]' '[:upper:]')

OPATCH="$ORACLE_HOME/OPatch/opatch"

{
date
echo '************************************************************************'
} > "$LOGFILE"

"$OPATCH" version | tee -a "$LOGFILE"

CHECKOPATCH=$("$OPATCH" version | grep Version | cut -d ' ' -f3)
if [ "$CHECKOPATCH" = "$OPATCHVERSION" ]; then
  echo "OPatch version $CHECKOPATCH is correct to proceed." | tee -a "$LOGFILE"
  echo "${HOST}:OPatchVersion-${CHECKOPATCH}:Date-$(date +'%m/%d/%Y-%H%M'):SUCCESS" | tee -a "$MASTERLOG"
else
  echo "OPatch version $CHECKOPATCH is NOT correct (expected $OPATCHVERSION)." | tee -a "$LOGFILE"
  echo "" | notify "${HOST} : OPatch version ${CHECKOPATCH} is not correct"
  echo "${HOST}:OPatchVersion-${CHECKOPATCH}:Date-$(date +'%m/%d/%Y-%H%M'):FAILED" | tee -a "$MASTERLOG"
  exit 1
fi

echo "------ inventory details before patch -----" | tee -a "$LOGFILE"
"$OPATCH" lspatches | tee -a "$LOGFILE"

if run_opatch_prereq "${PATCHSTAGE}/${COMBOPATCH}/${DBPSUPATCH}"; then
  echo "DBPSU prerequisite check completed successfully." | tee -a "$LOGFILE"
  echo "${HOST}:DBPSU-${DBPSUPATCH}-prerequisite-check:Date-$(date +'%m/%d/%Y-%H%M'):SUCCESS" | tee -a "$MASTERLOG"
else
  echo "DBPSU prerequisite check FAILED. See $LOGFILE." | tee -a "$LOGFILE"
  echo "${HOST}:DBPSU-${DBPSUPATCH}-prerequisite-check:Date-$(date +'%m/%d/%Y-%H%M'):FAILED" | tee -a "$MASTERLOG"
  echo "" | notify "${HOST}:DBPSU-${DBPSUPATCH}-prerequisite-check:FAILED"
  exit 1
fi

if run_opatch_prereq "${PATCHSTAGE}/${COMBOPATCH}/${OJVMPATCH}"; then
  echo "OJVM prerequisite check completed successfully." | tee -a "$LOGFILE"
  echo "${HOST}:OJVM-${OJVMPATCH}-prerequisite:Date-$(date +'%m/%d/%Y-%H%M'):SUCCESS" | tee -a "$MASTERLOG"
else
  echo "OJVM prerequisite check FAILED. See $LOGFILE." | tee -a "$LOGFILE"
  echo "${HOST}:OJVM-${OJVMPATCH}-prerequisite:Date-$(date +'%m/%d/%Y-%H%M'):FAILED" | tee -a "$MASTERLOG"
  echo "" | notify "${HOST}:OJVM-${OJVMPATCH}-prerequisite-check:FAILED"
  exit 1
fi

echo "All prerequisite checks completed." | tee -a "$LOGFILE"
echo "Total execution time: $(date -u -d @${SECONDS} +%H:%M:%S)" | tee -a "$LOGFILE"
