#!/bin/bash
# Runs once, when gvenzl/oracle-free creates the database. Turns on the two settings Reader's LogMiner check
# requires: ARCHIVELOG mode, which needs a restart, and minimal supplemental logging.
set -euo pipefail

mkdir -p /opt/oracle/oradata/archive

sqlplus -s / as sysdba <<'SQL'
WHENEVER SQLERROR EXIT FAILURE
ALTER SYSTEM SET log_archive_dest_1 = 'LOCATION=/opt/oracle/oradata/archive' SCOPE=BOTH;
SHUTDOWN IMMEDIATE
STARTUP MOUNT
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
ALTER PLUGGABLE DATABASE ALL OPEN;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
SQL
