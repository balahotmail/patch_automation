#!/usr/bin/bash
# ------------------------------------------------------
# Name   : opatch_apply.sh
# Purpose: Apply the combo (DBPSU) and OJVM patches to the Oracle Home,
#          then run datapatch and validate against dba_registry_sqlpatch
#          for every DB in oratab.
# Notes  : Must run as the configured Oracle OS user. All target DBs must already
#          be shut down (this script refuses to datapatch a running DB
#          it didn't expect to be up).
#
# *** FIX vs. original script ***
# The original had the actual `$OPATCH apply -silent` calls commented
# out, so it only ever *checked* whether a patch was present via
# `opatch lspatches` without ever applying it. That's restored below.
#
# Positional args: same 8 as opatch_prereq.sh
# Env (optional): NOTIFY_ENABLED / NOTIFY_EMAIL_TO / NOTIFY_EMAIL_FROM
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
TMPFILE1=$(mktemp)
TMPFILE2=$(mktemp)
LOGFILE="$LOGDIR/opatch_apply_${COMBOPATCH}_${DATE1}.log"
ORATAB="${ORATAB:-/etc/oratab}"
TARGET_DB_SIDS="${TARGET_DB_SIDS:-}"
ORAENV_PATH="${ORAENV_PATH:-/usr/local/bin/oraenv}"

NOTIFY_ENABLED="${NOTIFY_ENABLED:-true}"
NOTIFY_EMAIL_TO="${NOTIFY_EMAIL_TO:-}"
NOTIFY_EMAIL_FROM="${NOTIFY_EMAIL_FROM:-}"

APPLY_TIMEOUT_SECONDS="${APPLY_TIMEOUT_SECONDS:-1800}"
run_opatch_apply() {
  local patch_dir="$1"
  echo "Running OPatch apply for $patch_dir (timeout ${APPLY_TIMEOUT_SECONDS}s)" | tee -a "$LOGFILE"
  if command -v timeout >/dev/null 2>&1; then
    (
      cd "$patch_dir" || exit 1
      timeout "$APPLY_TIMEOUT_SECONDS" "$OPATCH" apply -silent
    ) >> "$LOGFILE" 2>&1
  else
    (
      cd "$patch_dir" || exit 1
      "$OPATCH" apply -silent
    ) >> "$LOGFILE" 2>&1
  fi
}

notify() {
  local subject="$1"
  if [ "$NOTIFY_ENABLED" = "true" ] && [ -n "$NOTIFY_EMAIL_TO" ] && command -v mailx >/dev/null 2>&1; then
    mailx -s "$subject" -r "$NOTIFY_EMAIL_FROM" "$NOTIFY_EMAIL_TO"
  else
    cat >/dev/null
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
if [ "$CHECKOPATCH" != "$OPATCHVERSION" ]; then
  echo "OPatch version $CHECKOPATCH is NOT correct (expected $OPATCHVERSION)." | tee -a "$LOGFILE"
  echo "" | notify "${HOST} : OPatch version ${CHECKOPATCH} is not correct"
  echo "${HOST}:OPatchVersion-${CHECKOPATCH}:Date-$(date +'%m/%d/%Y-%H%M'):FAILED" | tee -a "$MASTERLOG"
  exit 1
fi

echo "------ inventory details before patch -----" | tee -a "$LOGFILE"
"$OPATCH" lspatches | tee -a "$LOGFILE"

# ---- DBPSU / combo patch ----
if ! run_opatch_apply "${PATCHSTAGE}/${COMBOPATCH}/${DBPSUPATCH}"; then
  echo "DBPSU patch $DBPSUPATCH installation FAILED." | tee -a "$LOGFILE"
  echo "" | notify "${HOST} : DBPSU patch apply failed"
  echo "${HOST}:DBPSUpatch-${DBPSUPATCH}-install:Date-$(date +'%m/%d/%Y-%H%M'):FAILED" | tee -a "$MASTERLOG"
  exit 1
fi

CHECKDBPSUPATCH=$("$OPATCH" lspatches | grep "$DBPSUPATCH" | cut -d ';' -f1)
if [ "$CHECKDBPSUPATCH" = "$DBPSUPATCH" ]; then
  echo "DBPSU patch $DBPSUPATCH installed successfully in Oracle Home." | tee -a "$LOGFILE"
  echo "${HOST}:DBPSUpatch-${DBPSUPATCH}-install:Date-$(date +'%m/%d/%Y-%H%M'):SUCCESS" | tee -a "$MASTERLOG"
else
  echo "DBPSU patch $DBPSUPATCH installation FAILED." | tee -a "$LOGFILE"
  echo "" | notify "${HOST} : DBPSU patch apply failed"
  echo "${HOST}:DBPSUpatch-${DBPSUPATCH}-install:Date-$(date +'%m/%d/%Y-%H%M'):FAILED" | tee -a "$MASTERLOG"
  exit 1
fi

# ---- OJVM patch ----
if ! run_opatch_apply "${PATCHSTAGE}/${COMBOPATCH}/${OJVMPATCH}"; then
  echo "OJVM patch $OJVMPATCH installation FAILED." | tee -a "$LOGFILE"
  echo "" | notify "${HOST} : OJVM patch apply failed"
  echo "${HOST}:OJVMpatch-${OJVMPATCH}-install:Date-$(date +'%m/%d/%Y-%H%M'):FAILED" | tee -a "$MASTERLOG"
  exit 1
fi

CHECKOJVMPATCH=$("$OPATCH" lspatches | grep "$OJVMPATCH" | cut -d ';' -f1)
if [ "$CHECKOJVMPATCH" = "$OJVMPATCH" ]; then
  echo "OJVM patch $OJVMPATCH installed successfully in Oracle Home." | tee -a "$LOGFILE"
  echo "${HOST}:OJVMpatch-${OJVMPATCH}-install:Date-$(date +'%m/%d/%Y-%H%M'):SUCCESS" | tee -a "$MASTERLOG"
else
  echo "OJVM patch $OJVMPATCH installation FAILED." | tee -a "$LOGFILE"
  echo "" | notify "${HOST} : OJVM patch apply failed"
  echo "${HOST}:OJVMpatch-${OJVMPATCH}-install:Date-$(date +'%m/%d/%Y-%H%M'):FAILED" | tee -a "$MASTERLOG"
  exit 1
fi

echo "------ inventory details after Oracle Home patch -----" | tee -a "$LOGFILE"
"$OPATCH" lspatches | tee -a "$LOGFILE"
"$OPATCH" lsinventory | tee -a "$LOGFILE"

# ---- Post-patch datapatch run for every DB in oratab ----
echo "Performing post-patch datapatch for all databases..." | tee -a "$LOGFILE"

if [ -n "$TARGET_DB_SIDS" ]; then
  SIDS="$TARGET_DB_SIDS"
else
  SIDS=$(grep -v '^#' "$ORATAB" | awk -F: '$3 == "Y" {print $1}')
fi
echo "SID list: $SIDS" | tee -a "$LOGFILE"

for DBNAME in $SIDS; do
  echo "DBNAME: $DBNAME" | tee -a "$LOGFILE"
  ORACLE_SID="$DBNAME"
  export ORACLE_SID
  ORAENV_ASK=NO
  export ORAENV_ASK
  # shellcheck source=/dev/null
  . "$ORAENV_PATH"

  dbprocess=$(ps -ef | grep "$DBNAME" | grep pmon | grep -v grep | cut -d '_' -f3)
  echo "DB process check for $DBNAME: ${dbprocess:-<none>}" | tee -a "$LOGFILE"

  if [ -n "$dbprocess" ]; then
    echo "DB $DBNAME is running. Aborting - datapatch requires the DB to be started fresh by this script, not left running from before." | tee -a "$LOGFILE"
    echo "" | notify "${HOST} ${DBNAME} : DB is online during patching. Aborting patching"
    echo "${HOST}:${DBNAME}:DBstatus-onlineDuringPatch:Date-$(date +'%m/%d/%Y-%H%M'):FAILED" | tee -a "$MASTERLOG"
    exit 1
  fi

  echo "DB $DBNAME is stopped as expected. Starting it up to run datapatch..." | tee -a "$LOGFILE"
  echo "startup" | sqlplus -s / as sysdba

  cd "$ORACLE_HOME/OPatch" || exit 1
  ./datapatch -verbose | tee -a "$LOGFILE"

  QUERY1="SELECT PATCH_ID, PATCH_TYPE, ACTION, STATUS, ACTION_TIME, DESCRIPTION FROM dba_registry_sqlpatch WHERE PATCH_ID = '$DBPSUPATCH';"
  QUERY2="SELECT PATCH_ID, PATCH_TYPE, ACTION, STATUS, ACTION_TIME, DESCRIPTION FROM dba_registry_sqlpatch WHERE PATCH_ID = '$OJVMPATCH';"

  status_output1=$("$ORACLE_HOME/bin/sqlplus" -s "/ as sysdba" <<EOF
set line 200
column ACTION_TIME format a30
column STATUS format a10
column DESCRIPTION format a85
set heading off
set echo off
spool $LOGFILE APPEND
$QUERY1
spool off
quit;
EOF
)

  status_output2=$("$ORACLE_HOME/bin/sqlplus" -s "/ as sysdba" <<EOF
set line 200
column ACTION_TIME format a30
column STATUS format a10
column DESCRIPTION format a85
set heading off
set echo off
spool $LOGFILE APPEND
$QUERY2
spool off
quit;
EOF
)

  echo "status_output1: $status_output1" | tee -a "$LOGFILE"
  echo "status_output2: $status_output2" | tee -a "$LOGFILE"

  DBPATCH1=$(echo "$status_output1" | awk '{for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' | head -n 1)
  DBPATCH2=$(echo "$status_output2" | awk '{for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' | head -n 1)

  if [ "$DBPATCH1" = "$DBPSUPATCH" ]; then
    echo "DBPSU patch $DBPSUPATCH confirmed applied in DB $DBNAME." | tee -a "$LOGFILE"
    echo "${HOST}:${DBNAME}:DBPSUpostPatch-${DBPSUPATCH}:Date-$(date +'%m/%d/%Y-%H%M'):SUCCESS" | tee -a "$MASTERLOG"
  else
    echo "DBPSU patch $DBPSUPATCH NOT found applied in DB $DBNAME." | tee -a "$LOGFILE"
    echo "" | notify "${HOST} ${DBNAME} : DBPSU DB post-patch failed"
    echo "${HOST}:${DBNAME}:DBPSUpostPatch-${DBPSUPATCH}-install:Date-$(date +'%m/%d/%Y-%H%M'):FAILED" | tee -a "$MASTERLOG"
    exit 1
  fi

  if [ "$DBPATCH2" = "$OJVMPATCH" ]; then
    echo "OJVM patch $OJVMPATCH confirmed applied in DB $DBNAME." | tee -a "$LOGFILE"
    echo "${HOST}:${DBNAME}:OJVMpostPatch-${OJVMPATCH}-install:Date-$(date +'%m/%d/%Y-%H%M'):SUCCESS" | tee -a "$MASTERLOG"
  else
    echo "OJVM patch $OJVMPATCH NOT found applied in DB $DBNAME." | tee -a "$LOGFILE"
    echo "" | notify "${HOST} ${DBNAME} : OJVM DB post-patch failed"
    echo "${HOST}:${DBNAME}:OJVMpostPatch-${OJVMPATCH}-install:Date-$(date +'%m/%d/%Y-%H%M'):FAILED" | tee -a "$MASTERLOG"
    exit 1
  fi
done

echo "All patching actions completed." | tee -a "$LOGFILE"
echo "Total execution time: $(date -u -d @${SECONDS} +%H:%M:%S)" | tee -a "$LOGFILE"

{
echo "****************************** POST VALIDATION **************************************"
echo
"$OPATCH" lsinventory | grep applied
"$OPATCH" lspatches
echo
echo "**********************************************************************"
} > "$TMPFILE2"

cp "$LOGFILE" "$TMPFILE1"
cat "$TMPFILE2" "$TMPFILE1" > "$LOGFILE"

cat "$LOGFILE" | notify "${HOST} : Oracle DB patch ${COMBOPATCH} apply ${DATE1}"

rm -f "$TMPFILE1" "$TMPFILE2"
