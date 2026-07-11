# Oracle DB Patching with Ansible

This project stages Oracle patch media, refreshes OPatch, runs OPatch
prerequisite checks, applies DBPSU and OJVM patches, runs datapatch, and
starts the listener and database services again.

The important rule: do not edit playbooks or shell scripts for each new
environment. Put environment differences in inventory variables.

## Layout

```text
oracle_patching/
|-- ansible.cfg
|-- inventory/
|   |-- hosts.ini
|   |-- hosts.ini.example
|   `-- group_vars/
|       `-- all.yml
|-- playbooks/
|   |-- db_stop.yml
|   |-- db_patch.yml
|   `-- site.yml
`-- roles/
    |-- db_stop/
    |-- listener_start/
    `-- opatch_apply/
```

## Environment Model

This project uses a single inventory file plus one shared variables file:
`inventory/group_vars/all.yml`.

Put all environment-specific settings, Oracle Home paths, patch IDs, patch
media locations, and notification settings in that one file.

Example inventory:

```ini
[oracle_db_hosts]
proddb01 ansible_user=oracle
proddb02 ansible_user=oracle
```

The single variable file is:

```text
inventory/group_vars/all.yml
```

## Common Variables

Set shared defaults in `inventory/group_vars/all.yml`.

Useful defaults now include:

```yaml
oracle_os_user: oracle
oracle_profile: ""
oraenv_path: /usr/local/bin/oraenv
oratab_path: /etc/oratab

# Single target-side work folder. Scripts, logs, master logs, and patch
# staging/backups are created below this path.
oracle_work_dir: /opt/oracle/ansible_work
backup_oracle_home: false  # Set to true to tar/gzip ORACLE_HOME before patching

# Empty means all DBs flagged Y in oratab.
target_db_sids: []

# Empty listener_name means LISTENER_<short hostname>.
manage_listener: true
listener_name: ""
```

Override these in `host_vars/<hostname>.yml` when needed. For example, if a
host has a different work location and only one SID should be patched:

```yaml
oracle_work_dir: /u01/app/oracle/ansible_work
target_db_sids:
  - CDBQA
listener_name: LISTENER_QA
```

## Patch Profile Variables

Each patch profile should define at least:

```yaml
oracle_base: /u01/app/oracle
oracle_home: /u01/app/oracle/product/19.0.0/dbhome_1

oh_alias: cdbprd

opatch_version: 12.2.0.1.51

combo_patch: 39062931
dbpsu_patch: 39034528
ojvm_patch: 38906621

patch_file: p39062931_190000_Linux-x86-64.zip
opatch_file: p6880880_190000_Linux-x86-64.zip
patch_repo: /home/bala/ansible/oracle/patches/19c/2026-Apr
patch_env_label: PROD_19C_APR2026
masterlog: "{{ masterlog_dir }}/patch_{{ combo_patch }}_{{ patch_env_label }}_master.log"
```

## Running

Run a syntax check first:

```bash
ansible-playbook playbooks/site.yml -l oracle_db_hosts --syntax-check
```

Run the full maintenance-window flow, one host at a time:

```bash
ansible-playbook playbooks/site.yml -l oracle_db_hosts
```

Or run phases independently:

```bash
ansible-playbook playbooks/db_stop.yml -l oracle_db_hosts
ansible-playbook playbooks/db_patch.yml -l oracle_db_hosts
```

You can patch more than one host at a time after testing:

```bash
ansible-playbook playbooks/site.yml -l oracle_db_hosts -e patch_serial=2
```

## Safety Notes

- Test against dev or a throwaway host before production.
- Confirm backups exist outside this automation.
- Confirm `oh_alias` resolves to the intended Oracle Home through oraenv.
- If a host has multiple Oracle Homes, use inventory groups or host_vars so
  each run targets the correct Home and SID list.
- RAC, Data Guard, and OPatchAuto rolling patch flows are not handled by
  this playbook structure yet.
- `mailx` notification requires working mail relay setup on target hosts.
  Set `notify_enabled: false` if you want to rely on Ansible output only.
