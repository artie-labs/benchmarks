#!/usr/bin/env python3
"""Measures how fast Reader drains an Oracle CDC backlog into Kafka.

A drain stops Reader, writes a fixed number of changes to BENCH.ORDERS, then starts Reader and times how long it
takes for every change to reach Kafka. With the load already in the redo logs, the time measures how fast LogMiner and
Reader can go, not how fast the load was written.

    ./bench.py setup      # once: database settings, users, table and seed rows; writes Reader's config
    ./bench.py prime      # once: lets Reader save a starting offset, so later drains resume from it
    ./bench.py drain      # repeat: one measured run, saved to results/
    ./bench.py rds-cpu --start <iso> --end <iso>   # database CPU and I/O for a drain's window (RDS only)

See ../README.md for the full method.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import secrets
import string
import subprocess
import sys
import threading
import time
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from itertools import zip_longest
from pathlib import Path

import oracledb

HERE = Path(__file__).resolve().parent
STATE = HERE / "state"
RESULTS = HERE / "results"
SCHEMA, TABLE = "BENCH", "ORDERS"


class Engine:
    """A CDC engine the bench drives: its Compose service, the topic it writes, and the offset file it saves."""

    def __init__(self, name: str, topic: str, offsets: Path, offset_flush_seconds: int) -> None:
        self.name, self.service, self.topic, self.offsets = name, name, topic, offsets
        # How long to wait before stopping the engine, so the offset it saves covers everything it sent. Otherwise it
        # sends the rest again when it next starts, inside the next drain's timing.
        self.offset_flush_seconds = offset_flush_seconds


ENGINES = {
    # Reader saves its offset after Kafka confirms each batch.
    "reader": Engine("reader", f"benchmark.{SCHEMA}.{TABLE}", STATE / "offsets", 0),
    # Debezium names topics <topic.prefix>.<schema>.<table>; write_debezium_config sets the prefix to dbz. It saves
    # its offset every 60 s (offset.flush.interval.ms in production's properties).
    "debezium": Engine("debezium", f"dbz.{SCHEMA}.{TABLE}", STATE / "debezium" / "offsets" / "offsets.dat", 65),
}
# The engine this run drives, from --engine.
ENGINE = ENGINES["reader"]
KINDS = ("insert", "update", "delete")

# The grants in Artie's RDS setup guide (https://artie.com/docs/sources/oracle/amazon-rds), plus EXECUTE on
# DBMS_LOGMNR and SELECT on V$THREAD, which Reader's LogMiner session uses.
RDS_GRANTS = [
    "GRANT CREATE SESSION TO {user}",
    "GRANT LOGMINING TO {user}",
    "GRANT FLASHBACK ANY TABLE TO {user}",
    "GRANT SELECT ANY TRANSACTION TO {user}",
    "GRANT SELECT_CATALOG_ROLE TO {user}",
    "GRANT EXECUTE_CATALOG_ROLE TO {user}",
    "GRANT CREATE TABLE TO {user}",
    "GRANT CREATE SEQUENCE TO {user}",
    "GRANT SELECT ANY TABLE TO {user}",
]
RDS_SYS_GRANTS = [
    ("V_$DATABASE", "SELECT"),
    ("V_$LOG", "SELECT"),
    ("V_$LOG_HISTORY", "SELECT"),
    ("V_$LOGMNR_LOGS", "SELECT"),
    ("V_$LOGMNR_CONTENTS", "SELECT"),
    ("V_$LOGMNR_PARAMETERS", "SELECT"),
    ("V_$LOGFILE", "SELECT"),
    ("V_$ARCHIVED_LOG", "SELECT"),
    ("V_$ARCHIVE_DEST_STATUS", "SELECT"),
    ("V_$TRANSACTION", "SELECT"),
    ("V_$THREAD", "SELECT"),
    ("DBMS_LOGMNR", "EXECUTE"),
]

# Reader reads NUMBER(18) as int64. Text uses VARCHAR2 because LogMiner writes CLOBs as separate LOB operations.
CREATE_TABLE = f"""CREATE TABLE {TABLE} (
    id          NUMBER(18) PRIMARY KEY,
    customer_id NUMBER(18) NOT NULL,
    status      VARCHAR2(16) NOT NULL,
    quantity    NUMBER(18) NOT NULL,
    price       NUMBER(18,4) NOT NULL,
    revision    NUMBER(18) NOT NULL,
    note        VARCHAR2(4000),
    created_at  TIMESTAMP(6) NOT NULL,
    updated_at  TIMESTAMP(6) NOT NULL
)"""
INSERT_ROWS = f"""INSERT {{hint}} INTO {TABLE} (id, customer_id, status, quantity, price, revision, note, created_at, updated_at)
SELECT :base + LEVEL, MOD(:base + LEVEL, 100000), 'NEW', 1, 9.99, 0, RPAD('n', :note_bytes, 'n'), SYSTIMESTAMP, SYSTIMESTAMP
FROM dual CONNECT BY LEVEL <= :n"""
UPDATE_ROWS = f"""UPDATE {TABLE} SET revision = revision + 1, quantity = quantity + 1, status = 'UPDATED',
updated_at = SYSTIMESTAMP WHERE id BETWEEN :lo AND :hi"""
DELETE_ROWS = f"DELETE FROM {TABLE} WHERE id BETWEEN :lo AND :hi"


class Shape:
    """A table of one Oracle type family, or one row shape, for comparing per-type costs with ORDERS (--shape).

    columns are (name, DDL type, insert expression, update expression). Expressions are SQL over the row's key, id,
    and the column itself. Updates set the first `updates` columns, or every column with an update expression.
    changes is a drain size that keeps a drain's redo near ORDERS' 2M-change drains.
    """

    def __init__(self, note: str, columns: list[tuple[str, str, str, str]], updates: int | None = None, changes: int = 2_000_000) -> None:
        self.note, self.columns, self.changes = note, columns, changes
        self.updates = [c for c in columns if c[3]][: updates or len(columns)]


def family(prefix: str, count: int, ddl: str, insert: str, update: str) -> list[tuple[str, str, str, str]]:
    """count columns named <prefix>1..<prefix>N. In the DDL and expressions, {k} is the column's number, {p} a prime
    that varies values between columns, and {c} its name."""
    primes = [7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97, 101, 103, 107, 109, 113, 127, 131, 137]
    columns = []
    for k in range(1, count + 1):
        values = {"k": k, "p": primes[(k - 1) % len(primes)] + 30 * ((k - 1) // len(primes)), "c": f"{prefix}{k}"}
        columns.append((f"{prefix}{k}", ddl.format(**values), insert.format(**values), update.format(**values)))
    return columns


SHAPE_TS = "TIMESTAMP '2020-01-01 00:00:00' + NUMTODSINTERVAL(MOD(id * {p}, 100000000000) / 1000000, 'SECOND')"
SHAPE_INT = ("NUMBER(18)", "MOD(id * {p}, 1000000000000)", "{c} + 1")
SHAPE_DEC = ("NUMBER(18,4)", "MOD(id * {p}, 100000000000) / 10000", "{c} + 0.0001")
SHAPE_VC = ("VARCHAR2(32)", "'v' || id || '-{k}-abcdefghij'", "'u' || SUBSTR({c}, 2)")
SHAPE_TSCOL = ("TIMESTAMP(6)", SHAPE_TS, "{c} + INTERVAL '1' SECOND")
# Braces would break INSERT_ROWS.format, so JSON text spells them with CHR.
SHAPE_JSON = "CHR(123) || '\"id\":' || id || ',\"name\":\"customer ' || id || '\",\"tags\":[\"a\",\"b\"],\"price\":9.99,\"path\":\"C:\\\\x\\\\y\"' || CHR(125)"
SHAPES = {
    "int": Shape("NUMBER(18), which Reader sends as int64", family("I", 20, *SHAPE_INT)),
    "dec": Shape("NUMBER(18,4), a Kafka Connect decimal", family("D", 20, *SHAPE_DEC)),
    "bigdec": Shape("NUMBER(38,10) with 30-odd digits", family("B", 20, "NUMBER(38,10)", "MOD(id * {p}, 1000000000000000) * 1000000000 + id / 7", "{c} + 1")),
    "numvar": Shape("NUMBER without precision, a variable-scale decimal", family("V", 20, "NUMBER", "id * {p} / 1000", "{c} + 1")),
    "float": Shape("BINARY_FLOAT and BINARY_DOUBLE", family("F", 10, "BINARY_FLOAT", "TO_BINARY_FLOAT(id) / {p}", "{c} + 1") + family("D", 10, "BINARY_DOUBLE", "TO_BINARY_DOUBLE(id) / {p}", "{c} + 1")),
    "vc32": Shape("short VARCHAR2", family("S", 20, *SHAPE_VC)),
    "vc4000": Shape("one full VARCHAR2(4000), so SQL_REDO continues on CSF rows", family("L", 1, "VARCHAR2(4000)", "RPAD(id || '-', 4000, 'abcdefghij')", "'u' || SUBSTR({c}, 2)"), changes=500_000),
    "longrow": Shape("two full VARCHAR2(4000), a row near the 8 KB block size; updates set one", family("L", 2, "VARCHAR2(4000)", "RPAD(id || '-{k}-', 4000, 'abcdefghij')", "'u' || SUBSTR({c}, 2)"), updates=1, changes=300_000),
    "mb": Shape("VARCHAR2 of multibyte text: Latin-1 accents and CJK", family("M", 4, "VARCHAR2(1000 CHAR)", "RPAD('Grüße aus München 東京 ' || id, 300, ' Ünïcödé 中文')", "'u' || SUBSTR({c}, 2)"), changes=1_000_000),
    "nvc": Shape("NVARCHAR2 of ASCII text, which LogMiner writes as quoted strings", family("N", 20, "NVARCHAR2(32)", "TO_NCHAR('v' || id || '-{k}-abcdefghij')", "TO_NCHAR('u' || SUBSTR({c}, 2))")),
    "nvcu": Shape("NVARCHAR2 of non-ASCII text, which LogMiner writes as UNISTR", family("N", 20, "NVARCHAR2(32)", "TO_NCHAR('é' || id || '-{k}-中文')", "TO_NCHAR('ü' || SUBSTR({c}, 2))")),
    "jsontext": Shape("VARCHAR2 IS JSON, 19c's JSON, full of quotes and backslashes", family("J", 4, "VARCHAR2(1000) CHECK ({c} IS JSON)", SHAPE_JSON, "REPLACE({c}, 'customer', 'client')"), changes=1_000_000),
    "date": Shape("DATE", family("T", 20, "DATE", "DATE '2020-01-01' + MOD(id * {p}, 2000000) / 1000", "{c} + 1 / 24")),
    "ts": Shape("TIMESTAMP(6)", family("T", 20, *SHAPE_TSCOL)),
    "tstz": Shape("TIMESTAMP(6) WITH TIME ZONE, offsets and regions", family("Z", 20, "TIMESTAMP(6) WITH TIME ZONE", "FROM_TZ(" + SHAPE_TS + ", DECODE(MOD({k}, 4), 0, '+00:00', 1, '-07:00', 2, '+05:30', 'America/New_York'))", "{c} + INTERVAL '1' SECOND")),
    "tsltz": Shape("TIMESTAMP(6) WITH LOCAL TIME ZONE", family("Z", 20, "TIMESTAMP(6) WITH LOCAL TIME ZONE", SHAPE_TS, "{c} + INTERVAL '1' SECOND")),
    "interval": Shape("INTERVAL DAY TO SECOND and YEAR TO MONTH", family("DS", 10, "INTERVAL DAY(3) TO SECOND(6)", "NUMTODSINTERVAL(MOD(id * {p}, 10000000000) / 1000000, 'SECOND')", "{c} + INTERVAL '1' SECOND") + family("YM", 10, "INTERVAL YEAR(3) TO MONTH", "NUMTOYMINTERVAL(MOD(id * {p}, 1200), 'MONTH')", "{c} + INTERVAL '1' MONTH")),
    "raw": Shape("RAW(16), the shape of SYS_GUID keys", family("R", 20, "RAW(16)", "SYS_GUID()", "SYS_GUID()")),
    "clob": Shape("two small CLOBs, stored in the row", family("C", 2, "CLOB", "TO_CLOB(RPAD(id || '-', 200, 'clob text '))", "TO_CLOB('u' || id)"), changes=1_000_000),
    "blob": Shape("two small BLOBs, stored in the row", family("B", 2, "BLOB", "TO_BLOB(HEXTORAW(RPAD(TO_CHAR(id, 'FMXXXXXXXXXX'), 200, 'AB')))", "TO_BLOB(HEXTORAW('ABCD'))"), changes=1_000_000),
    "lobbig": Shape("a 16 KB CLOB, stored out of the row; updates set a NUMBER beside it", [("C1", "CLOB", "TO_CLOB(RPAD(id || '-', 4000, 'x')) || RPAD('y', 4000, 'y') || RPAD('z', 4000, 'z') || RPAD('w', 4000, 'w')", "")] + family("N", 1, *SHAPE_INT), changes=300_000),
    "xml": Shape("XMLTYPE; updates set a NUMBER beside it", [("X1", "XMLTYPE", "XMLTYPE('<r><id>' || id || '</id><v>' || RPAD('x', 100, 'x') || '</v></r>')", "")] + family("N", 1, *SHAPE_INT), changes=500_000),
    "wide": Shape("180 columns, updates set one", family("I", 60, *SHAPE_INT) + family("S", 60, *SHAPE_VC) + family("T", 30, *SHAPE_TSCOL) + family("D", 30, *SHAPE_DEC), updates=1, changes=300_000),
    "narrow": Shape("one NUMBER(18) beside the key", family("I", 1, *SHAPE_INT)),
}
# The --shape this run uses, or None for ORDERS.
SHAPE: Shape | None = None


def use_shape(name: str) -> None:
    """Points the bench at BENCH.SH_<NAME> instead of ORDERS: its own topic, Reader offset, and load and engine state."""
    global SHAPE, TABLE, CREATE_TABLE, INSERT_ROWS, UPDATE_ROWS, DELETE_ROWS
    SHAPE, TABLE = SHAPES[name], f"SH_{name.upper()}"
    names = ", ".join(c[0] for c in SHAPE.columns)
    CREATE_TABLE = f"CREATE TABLE {TABLE} (id NUMBER(18) PRIMARY KEY, " + ", ".join(f"{c[0]} {c[1]}" for c in SHAPE.columns) + ")"
    # :note_bytes is unused, but every caller binds it.
    INSERT_ROWS = f"INSERT {{hint}} INTO {TABLE} (id, {names}) SELECT id, " + ", ".join(c[2] for c in SHAPE.columns) + " FROM (SELECT :base + LEVEL AS id FROM dual CONNECT BY LEVEL <= :n AND :note_bytes > 0)"
    UPDATE_ROWS = f"UPDATE {TABLE} SET " + ", ".join(f"{c[0]} = {c[3]}" for c in SHAPE.updates) + " WHERE id BETWEEN :lo AND :hi"
    DELETE_ROWS = f"DELETE FROM {TABLE} WHERE id BETWEEN :lo AND :hi"
    ENGINES["reader"] = Engine("reader", f"benchmark.{SCHEMA}.{TABLE}", STATE / f"offsets.{TABLE}", 0)
    ENGINES["debezium"] = Engine("debezium", f"dbz.{SCHEMA}.{TABLE}", ENGINES["debezium"].offsets, 65)


def state_file(name: str) -> str:
    """A shape keeps its own load and engine state, so ORDERS' survives a shape's runs."""
    if SHAPE is not None and name in ("load.json", "engines.json"):
        return name.replace(".json", f".{TABLE}.json")
    return name


def run_capture(cfg: Config, args: argparse.Namespace) -> None:
    """Writes a small load and saves the V$LOGMNR_CONTENTS rows Reader's query returns for it, as gzipped JSON lines in
    results/captures/<table>.jsonl.gz, for offline replay benches. The load is the bench's synthetic rows only."""
    import gzip

    require_setup()
    stop_engines()
    with cfg.admin() as admin:
        start_scn = current_scn(admin)
    write_load(cfg, parse_mix(args.mix, args.changes), 1, args.commit_rows, quiet=True)
    end_scn, logs = archive_through(cfg, start_scn)
    password = read_state("passwords.json")["artie"]
    service, pdb_clause = (cfg.service, "") if cfg.mode == "rds" else ("FREE", " AND SRC_CON_NAME = 'FREEPDB1'")
    first, last = max(start_scn + 1, logs[0][0]), min(end_scn, logs[-1][1] - 1)
    columns = ["SCN", "TIMESTAMP", "OPERATION_CODE", "OPERATION", "SEG_OWNER", "TABLE_NAME", "SQL_REDO", "ROW_ID", "XIDUSN", "XIDSLT", "XIDSQN", "RS_ID", "SSN", "CSF", "ROLLBACK"]
    RESULTS.joinpath("captures").mkdir(parents=True, exist_ok=True)
    path = RESULTS / "captures" / f"{TABLE.lower()}.jsonl.gz"
    rows = size = 0
    with oracledb.connect(user=cfg.artie_user, password=password, dsn=f"{cfg.oracle_host}:1521/{service}") as connection, gzip.open(path, "wt") as out:
        cursor = connection.cursor()
        cursor.execute("ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS' NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF9' NLS_TIMESTAMP_TZ_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF9 TZH:TZM'")
        for i, (_, _, name) in enumerate(logs):
            option = "DBMS_LOGMNR.NEW" if i == 0 else "DBMS_LOGMNR.ADDFILE"
            cursor.execute(f"BEGIN DBMS_LOGMNR.ADD_LOGFILE(LOGFILENAME => :name, OPTIONS => {option}); END;", name=name)
        cursor.execute(f"BEGIN DBMS_LOGMNR.START_LOGMNR(STARTSCN => {first}, ENDSCN => {last}, OPTIONS => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG + DBMS_LOGMNR.NO_ROWID_IN_STMT); END;")
        try:
            # Reader's filter, without other sessions' commits: only transactions that changed the table.
            where = f"WHERE SCN > :scn AND OPERATION_CODE IN (1, 2, 3, 7, 36) AND (SEG_OWNER = '{SCHEMA}' AND TABLE_NAME = '{TABLE}' OR OPERATION_CODE IN (7, 36)){pdb_clause}"
            cursor.execute(f"SELECT {', '.join(columns)} FROM V$LOGMNR_CONTENTS {where}", scn=first - 1)
            ours: set[tuple] = set()
            chained = False
            for row in cursor:
                record = dict(zip(columns, row))
                xid = (record["XIDUSN"], record["XIDSLT"], record["XIDSQN"])
                if record["OPERATION_CODE"] in (7, 36) and xid not in ours:
                    continue
                ours.add(xid)
                record["TIMESTAMP"] = record["TIMESTAMP"].isoformat() if record["TIMESTAMP"] else None
                line = json.dumps(record, ensure_ascii=False)
                # Stop at a limit only between statements, so the last SQL_REDO's CSF chain is whole.
                if not chained and (rows >= args.max_rows or size + len(line) > args.max_bytes):
                    break
                out.write(line + "\n")
                rows, size, chained = rows + 1, size + len(line) + 1, record["CSF"] == 1
        finally:
            cursor.execute("BEGIN DBMS_LOGMNR.END_LOGMNR; END;")
    log(f"Saved {rows} rows, {size:,} bytes before gzip, to {path} ({path.stat().st_size:,} bytes)")


def run_shape_drop(cfg: Config, args: argparse.Namespace) -> None:
    """Drops the --shape table and forgets its state, to free the database's space after a shape's runs."""
    if SHAPE is None:
        sys.exit("shape-drop needs --shape")
    with cfg.bench() as bench:
        cursor = bench.cursor()
        if cursor.execute("SELECT COUNT(*) FROM user_tables WHERE table_name = :name", name=TABLE).fetchone()[0]:
            cursor.execute(f"DROP TABLE {TABLE} PURGE")
    for name in ("load.json", "engines.json"):
        (STATE / state_file(name)).unlink(missing_ok=True)
    ENGINES["reader"].offsets.unlink(missing_ok=True)
    log(f"Dropped {SCHEMA}.{TABLE}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--engine", choices=sorted(ENGINES), default="reader", help="the CDC engine prime, drain and logminer drive")
    parser.add_argument("--shape", choices=sorted(SHAPES), help="use the table of one type family or row shape, BENCH.SH_<SHAPE>, instead of ORDERS")
    commands = parser.add_subparsers(dest="command", required=True)

    setup = commands.add_parser("setup", help="prepare the database and write Reader's and Transfer's configs")
    setup.add_argument("--seed-rows", type=int, default=5_000_000, help="rows written before Reader starts; updates use the lower half and deletes consume the upper half")
    setup.add_argument("--note-bytes", type=int, default=200, help="width of each row's VARCHAR2 note, up to 4000")
    setup.add_argument("--redo-mb", type=int, default=1024, help="size of each online redo log (RDS only)")
    setup.add_argument("--archive-hours", type=int, default=6, help="hours RDS keeps archived logs; must cover a drain's load and catch-up")
    setup.add_argument("--reader-batch-size", type=int, default=25_000, help="Reader's streaming batch size; 25,000 matches quest.com's R12RPT_CN")
    setup.add_argument("--raw-messages", action="store_true", help="Reader writes Transfer raw records (BSON) instead of Debezium JSON, the kafka.rawMessages setting companies turn on with useRawKafkaMessages")
    setup.add_argument("--reset", action="store_true", help="drop and reseed the table and forget every engine's offset")

    commands.add_parser("prime", help="start Reader until it saves an offset, then stop it")

    load = commands.add_parser("load", help="write changes without starting Reader")
    add_load_arguments(load)

    drain = commands.add_parser("drain", help="write changes with Reader stopped, then time Reader catching up")
    add_load_arguments(drain)
    drain.add_argument("--poll-seconds", type=float, default=5, help="how often to read the topic's end offset")
    drain.add_argument("--settle-seconds", type=float, default=20, help="how long the offset must hold still after reaching the expected count")
    drain.add_argument("--stall-seconds", type=float, default=300, help="give up when the offset hasn't moved for this long")
    drain.add_argument("--profile-seconds", type=int, default=0, help="after the first message, save a CPU profile this long and then a heap profile; profiling slows Reader, so don't report a profiled drain's rate")
    drain.add_argument("--open-transaction", choices=("other", "orders"), help="keep a transaction open from before the load until the drain ends, then roll it back: one row inserted into BENCH.SIDE, which Reader doesn't stream, or into BENCH.ORDERS")

    undo = commands.add_parser("undo-check", help="with Reader streaming, write savepoint rollbacks to a table of rows wider than a block under the load, and check Reader sent exactly what committed")
    add_load_arguments(undo)
    undo.add_argument("--settle-seconds", type=float, default=30, help="how long the topics must hold still after the load")
    undo.add_argument("--wide-seconds", type=float, default=120, help="the least time to write WIDE's transactions for, past the end of the load if it's shorter")

    miner = commands.add_parser("logminer", help="write changes, then time LogMiner alone mining them, without Reader")
    add_load_arguments(miner)
    miner.add_argument("--sessions", default="1", help="comma-separated session counts to try, such as 1,2,4; sessions split the archived logs between them")
    miner.add_argument("--modes", default="server,client", help="server counts rows in Oracle; client also fetches every row to this machine")
    miner.add_argument("--fetch-rows", type=int, default=25_000, help="rows per client fetch, like Reader's batch size")

    transfer = commands.add_parser("transfer-drain", help="time Transfer writing the engine's last drain from Kafka to S3")
    transfer.add_argument("--poll-seconds", type=float, default=5, help="how often to read Transfer's committed offset")
    transfer.add_argument("--stall-seconds", type=float, default=300, help="give up when the committed offset hasn't moved for this long")

    dms_setup = commands.add_parser("setup-dms", help="create DMS_USER with AWS's RDS grants, and Binary Reader's log directories")
    dms_setup.add_argument("--secret-arn", required=True, help="the DMS secret, from terraform output dms")
    dms_load = commands.add_parser("dms-load", help="stop every engine, write changes, and print the SCN a DMS task should start from")
    add_load_arguments(dms_load)

    cpu = commands.add_parser("rds-cpu", help="print the database's CPU and I/O per minute")
    cpu.add_argument("--start", required=True, help="UTC start, such as 2026-11-07T18:00:00Z")
    cpu.add_argument("--end", required=True, help="UTC end")
    commands.add_parser("shape-drop", help="drop the --shape table and forget its state")
    capture = commands.add_parser("capture", help="write a small load and save the LogMiner rows Reader's query returns for it to results/captures/")
    add_load_arguments(capture)
    capture.set_defaults(changes=200, commit_rows=10)
    capture.add_argument("--max-rows", type=int, default=400, help="most rows to save")
    capture.add_argument("--max-bytes", type=int, default=700_000, help="most JSON bytes to save, before gzip, which keeps files near 100 KB")

    args = parser.parse_args()
    global ENGINE
    if args.shape:
        use_shape(args.shape)
    ENGINE = ENGINES[args.engine]
    cfg = Config.load()
    handlers = {"setup": run_setup, "prime": run_prime, "load": run_load_command, "drain": run_drain, "logminer": run_logminer, "transfer-drain": run_transfer_drain, "setup-dms": run_setup_dms, "dms-load": run_dms_load, "rds-cpu": run_rds_cpu, "undo-check": run_undo_check, "shape-drop": run_shape_drop, "capture": run_capture}
    handlers[args.command](cfg, args)


def add_load_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--changes", type=int, default=2_000_000, help="total row changes to write")
    parser.add_argument("--workers", type=int, default=8, help="concurrent sessions writing changes")
    parser.add_argument("--commit-rows", type=int, default=1000, help="rows per statement and per commit")
    parser.add_argument("--mix", default="insert=30,update=50,delete=20", help="percent of changes of each kind")


class Config:
    """Settings from .env, which Terraform's user data writes on the instance. Environment variables override it."""

    def __init__(self, values: dict[str, str]) -> None:
        self.mode = values.get("BENCH_MODE", "rds")
        if self.mode not in ("rds", "local"):
            sys.exit(f"BENCH_MODE must be rds or local, got {self.mode!r}")
        self.region = values.get("AWS_REGION", "")
        self.oracle_host = values.get("ORACLE_HOST", "localhost")
        self.master_secret_arn = values.get("MASTER_SECRET_ARN", "")
        self.db_instance_id = values.get("DB_INSTANCE_ID", "")
        self.bucket = values.get("BUCKET", "")
        self.transfer_role_arn = values.get("TRANSFER_ROLE_ARN", "")
        self.local_password = values.get("LOCAL_ORACLE_PASSWORD", "fixture-only")
        if self.mode == "rds":
            missing = [key for key in ("AWS_REGION", "ORACLE_HOST", "MASTER_SECRET_ARN", "DB_INSTANCE_ID") if not values.get(key)]
            if missing:
                sys.exit(f"{HERE / '.env'} is missing {', '.join(missing)}")

    @classmethod
    def load(cls) -> Config:
        values: dict[str, str] = {}
        path = HERE / ".env"
        if path.exists():
            for line in path.read_text().splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    values[key.strip()] = value.strip()
        values.update({key: value for key, value in os.environ.items() if key in values or key == "BENCH_MODE"})
        return cls(values)

    @property
    def artie_user(self) -> str:
        # Oracle Free is a multi-tenant database, where LogMiner runs in the CDB root, so Reader needs a common user.
        return "ARTIE" if self.mode == "rds" else "C##ARTIE"

    @property
    def service(self) -> str:
        return "ORCL" if self.mode == "rds" else "FREEPDB1"

    def admin(self) -> oracledb.Connection:
        """Connects as the master user on RDS, or SYS on Oracle Free's pluggable database."""
        if self.mode == "rds":
            secret = json.loads(output(["aws", "secretsmanager", "get-secret-value", "--region", self.region, "--secret-id", self.master_secret_arn, "--query", "SecretString", "--output", "text"]))
            return oracledb.connect(user=secret["username"], password=secret["password"], dsn=f"{self.oracle_host}:1521/{self.service}")
        return oracledb.connect(user="sys", password=self.local_password, dsn=f"{self.oracle_host}:1521/{self.service}", mode=oracledb.AUTH_MODE_SYSDBA)

    def local_root(self) -> oracledb.Connection:
        return oracledb.connect(user="sys", password=self.local_password, dsn=f"{self.oracle_host}:1521/FREE", mode=oracledb.AUTH_MODE_SYSDBA)

    def bench(self) -> oracledb.Connection:
        """Connects as BENCH, which owns the table. The load writes as BENCH, as an application would."""
        return oracledb.connect(user=SCHEMA, password=read_state("passwords.json")["bench"], dsn=f"{self.oracle_host}:1521/{self.service}")


def run_setup(cfg: Config, args: argparse.Namespace) -> None:
    if not 1 <= args.note_bytes <= 4000:
        sys.exit("--note-bytes must be between 1 and 4000")
    STATE.mkdir(exist_ok=True)
    passwords = read_state("passwords.json", default={})
    passwords.setdefault("artie", new_password())
    passwords.setdefault("bench", new_password())
    write_state("passwords.json", passwords)
    if cfg.mode == "local":
        log("Starting Oracle Free. Its first start creates the database, which takes a few minutes")
        compose("up", "-d", "--wait", "oracle")

    with cfg.admin() as admin:
        cursor = admin.cursor()
        if cfg.mode == "rds":
            log(f"Keeping archived logs for {args.archive_hours} hours and turning on minimal supplemental logging")
            cursor.execute("BEGIN rdsadmin.rdsadmin_util.set_configuration('archivelog retention hours', :hours); END;", hours=str(args.archive_hours))
            cursor.execute("BEGIN rdsadmin.rdsadmin_util.alter_supplemental_logging(p_action => 'ADD'); END;")
            admin.commit()
            resize_redo_logs(cursor, args.redo_mb)
            create_user(cursor, cfg.artie_user, passwords["artie"])
            for grant in RDS_GRANTS:
                cursor.execute(grant.format(user=cfg.artie_user))
            for name, privilege in RDS_SYS_GRANTS:
                cursor.execute("BEGIN rdsadmin.rdsadmin_util.grant_sys_object(:name, :grantee, :privilege); END;", name=name, grantee=cfg.artie_user, privilege=privilege)
            # Debezium keeps a LogMiner flush table in the user's default tablespace. These are the guide's steps.
            if cursor.execute("SELECT COUNT(*) FROM dba_tablespaces WHERE tablespace_name = 'ARTIE_LOGMINER_TBS'").fetchone()[0] == 0:
                cursor.execute("CREATE TABLESPACE ARTIE_LOGMINER_TBS DATAFILE SIZE 25M AUTOEXTEND ON MAXSIZE UNLIMITED")
            cursor.execute(f"ALTER USER {cfg.artie_user} DEFAULT TABLESPACE ARTIE_LOGMINER_TBS QUOTA UNLIMITED ON ARTIE_LOGMINER_TBS")
        else:
            with cfg.local_root() as root:
                root_cursor = root.cursor()
                create_user(root_cursor, cfg.artie_user, passwords["artie"], " CONTAINER=ALL")
                root_cursor.execute(f"GRANT DBA, LOGMINING, SET CONTAINER TO {cfg.artie_user} CONTAINER=ALL")
        create_user(cursor, SCHEMA, passwords["bench"], " QUOTA UNLIMITED ON USERS")
        cursor.execute(f"GRANT CREATE SESSION, CREATE TABLE TO {SCHEMA}")

    with cfg.bench() as bench:
        cursor = bench.cursor()
        exists = cursor.execute("SELECT COUNT(*) FROM user_tables WHERE table_name = :name", name=TABLE).fetchone()[0] > 0
        if exists and args.reset:
            log(f"Dropping {SCHEMA}.{TABLE}")
            cursor.execute(f"DROP TABLE {TABLE} PURGE")
            exists = False
        if not exists:
            log(f"Creating {SCHEMA}.{TABLE} and seeding {args.seed_rows:,} rows")
            cursor.execute(CREATE_TABLE)
            # Log every column, so updates carry the whole row, as Artie's setup guide asks customers to.
            cursor.execute(f"ALTER TABLE {TABLE} ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS")
            chunk = 100_000
            for base in range(0, args.seed_rows, chunk):
                cursor.execute(INSERT_ROWS.format(hint="/*+ APPEND */"), base=base, note_bytes=args.note_bytes, n=min(chunk, args.seed_rows - base))
                bench.commit()
            write_state("load.json", {"seed_rows": args.seed_rows, "note_bytes": args.note_bytes, "next_insert": args.seed_rows + 1, "next_update": 1, "next_delete": args.seed_rows // 2 + 1, "changes_written": 0})
            if SHAPE is not None:
                # Row bytes per change, for MB/s of row data. Drains copy load.json into their results.
                cursor.execute(f"BEGIN DBMS_STATS.GATHER_TABLE_STATS(USER, '{TABLE}', estimate_percent => 1); END;")
                avg_row_len = cursor.execute("SELECT avg_row_len FROM user_tables WHERE table_name = :name", name=TABLE).fetchone()[0]
                write_state("load.json", {**read_state("load.json"), "shape": args.shape, "avg_row_len": avg_row_len})
            # Every engine's position is for the dropped table, so each needs priming again.
            for engine in ENGINES.values():
                engine.offsets.unlink(missing_ok=True)
            (STATE / "debezium" / "offsets" / "schema_history.txt").unlink(missing_ok=True)
            (STATE / state_file("engines.json")).unlink(missing_ok=True)
        elif not (STATE / state_file("load.json")).exists():
            sys.exit(f"{SCHEMA}.{TABLE} exists but state/load.json doesn't, so the load can't tell which keys are free. Rerun with --reset.")

    write_reader_config(cfg, passwords["artie"], args.reader_batch_size, args.raw_messages)
    write_debezium_config(cfg, passwords["artie"])
    if cfg.mode == "rds":
        write_transfer_config(cfg)
    log("Setup done. Next: ./bench.py prime")


def resize_redo_logs(cursor: oracledb.Cursor, size_mb: int) -> None:
    """Replaces online redo logs smaller than size_mb with four of size_mb.

    RDS starts with four 128 MB logs. Each switch starts a checkpoint and an archive copy, and gives LogMiner one more
    file to add, so small logs slow both the load and the drain. Oracle drops a group only once it is inactive and
    archived, so this switches until every small group is.
    """
    target = size_mb * 1024 * 1024
    groups = cursor.execute("SELECT group#, bytes FROM v$log").fetchall()
    small = {group for group, size in groups if size < target}
    if not small:
        return
    log(f"Replacing {len(small)} redo logs with {size_mb} MB logs")
    for _ in range(4 - (len(groups) - len(small))):
        cursor.execute("BEGIN rdsadmin.rdsadmin_util.add_logfile(p_size => :size); END;", size=f"{size_mb}M")
    deadline = time.monotonic() + 600
    while small:
        if time.monotonic() > deadline:
            sys.exit(f"redo groups {sorted(small)} didn't become inactive within 10 minutes")
        cursor.execute("BEGIN rdsadmin.rdsadmin_util.switch_logfile; END;")
        cursor.execute("BEGIN rdsadmin.rdsadmin_util.checkpoint; END;")
        for group, status, archived in cursor.execute("SELECT group#, status, archived FROM v$log").fetchall():
            if group in small and status == "INACTIVE" and archived == "YES":
                cursor.execute("BEGIN rdsadmin.rdsadmin_util.drop_logfile(grp => :grp); END;", grp=group)
                small.discard(group)
        time.sleep(2)
    # Reader adds every online log to its LogMiner session, and LogMiner rejects a log that has never been written
    # with ORA-01281. Switch until no new group is still unused.
    for _ in range(8):
        if cursor.execute("SELECT COUNT(*) FROM v$log WHERE status = 'UNUSED'").fetchone()[0] == 0:
            return
        cursor.execute("BEGIN rdsadmin.rdsadmin_util.switch_logfile; END;")
    sys.exit("new redo logs are still UNUSED after 8 switches")


def create_user(cursor: oracledb.Cursor, user: str, password: str, options: str = "") -> None:
    """Creates user, or resets its password to the one in state/passwords.json."""
    exists = cursor.execute("SELECT COUNT(*) FROM all_users WHERE username = :name", name=user).fetchone()[0] > 0
    cursor.execute(f'{"ALTER" if exists else "CREATE"} USER {user} IDENTIFIED BY "{password}"' + ("" if exists else options))


def write_reader_config(cfg: Config, password: str, batch_size: int, raw_messages: bool) -> None:
    """Writes Reader's config. JSON is YAML, so Reader reads it as is."""
    streaming = {"enabled": True, "offsetFile": f"/state/{ENGINES['reader'].offsets.name}", "batchSize": batch_size}
    host = cfg.oracle_host
    if cfg.mode == "local":
        streaming["logMinerServiceName"] = "FREE"
        host = "oracle"
    reader = {
        "source": "oracle",
        "destination": "kafka",
        # The Kafka settings of quest.com's R12RPT_CN, the production pipeline that streams Oracle through Reader.
        "kafka": {"bootstrapServers": "kafka:9092", "topicPrefix": "benchmark", "disableTLS": True, "maxRequestSize": 2_097_152, "messageCompression": "gzip", "rawMessages": raw_messages},
        "oracle": {
            "host": host,
            "port": 1521,
            "username": cfg.artie_user,
            "password": password,
            "serviceName": cfg.service,
            "tables": [{"schema": SCHEMA, "name": TABLE}],
            "streamingSettings": streaming,
        },
    }
    write_state("reader.yaml", reader)


def reader_settings() -> dict:
    """The Reader settings a drain's speed depends on, for its result."""
    reader = read_state("reader.yaml")
    streaming = {key: value for key, value in reader["oracle"]["streamingSettings"].items() if key != "offsetFile"}
    return {**streaming, "rawMessages": reader["kafka"].get("rawMessages", False), "messageCompression": reader["kafka"].get("messageCompression")}


def write_debezium_config(cfg: Config, password: str) -> None:
    """Writes Debezium Server's application.properties as production does: the dashboard's base properties
    (subchart_template/templates/cm.yaml) and the connector properties it generates for Oracle
    (generated_deployment/debezium). Kafka here is plaintext, so the SASL and TLS properties are left out, and the
    request size matches the 2 MB quest.com sets for its producers."""
    properties = {
        "debezium.source.offset.storage.file.filename": "/debezium/offsets/offsets.dat",
        "debezium.source.offset.flush.interval.ms": "60000",
        "debezium.sink.type": "kafka",
        "debezium.sink.kafka.producer.bootstrap.servers": "kafka:9092",
        "debezium.sink.kafka.producer.compression.type": "gzip",
        "debezium.sink.kafka.producer.group.id": "dbz",
        "debezium.sink.kafka.producer.key.converter": "org.apache.kafka.connect.storage.StringConverter",
        "debezium.sink.kafka.producer.value.converter": "org.apache.kafka.connect.json.JsonConverter",
        "debezium.sink.kafka.producer.key.converter.schemas.enable": "false",
        "debezium.sink.kafka.producer.value.converter.schemas.enable": "true",
        "debezium.sink.kafka.producer.key.serializer": "org.apache.kafka.common.serialization.StringSerializer",
        "debezium.sink.kafka.producer.key.serializer.schemas.enable": "false",
        "debezium.sink.kafka.producer.value.serializer": "org.apache.kafka.common.serialization.StringSerializer",
        "debezium.sink.kafka.producer.request.timeout.ms": "20000",
        "debezium.sink.kafka.producer.retry.backoff.ms": "500",
        "debezium.sink.kafka.producer.max.request.size": "2097152",
        "debezium.source.plugin.name": "pgoutput",
        "debezium.source.decimal.handling.mode": "precise",
        "debezium.source.include.schema.changes": "false",
        "debezium.source.schema.history.internal.file.filename": "/debezium/offsets/schema_history.txt",
        "debezium.source.include.unknown.datatypes": "true",
        "debezium.source.topic.prefix": "dbz",
        "debezium.source.connector.class": "io.debezium.connector.oracle.OracleConnector",
        "debezium.source.database.hostname": cfg.oracle_host if cfg.mode == "rds" else "oracle",
        "debezium.source.database.port": "1521",
        "debezium.source.database.user": cfg.artie_user,
        "debezium.source.database.password": password,
        "debezium.source.database.dbname": cfg.service if cfg.mode == "rds" else "FREE",
        "debezium.source.snapshot.mode": "schema_only",
        "debezium.source.schema.history.internal": "io.debezium.storage.file.history.FileSchemaHistory",
        "debezium.source.snapshot.locking.mode": "none",
        "debezium.source.schema.history.internal.store.only.captured.tables.ddl": "true",
        "debezium.source.table.include.list": f"{SCHEMA}.{TABLE}",
    }
    if cfg.mode == "local":
        properties["debezium.source.database.pdb.name"] = "FREEPDB1"
    conf = STATE / "debezium" / "conf"
    offsets = STATE / "debezium" / "offsets"
    for directory in (conf, offsets):
        directory.mkdir(parents=True, exist_ok=True)
    # Debezium runs as a non-root user in its container, so it must be able to write its offsets and read its config.
    offsets.chmod(0o777)
    path = conf / "application.properties"
    path.write_text("".join(f"{key}={value}\n" for key, value in sorted(properties.items())))
    path.chmod(0o644)


def write_transfer_config(cfg: Config, group: str = "oracle-bench", folder: str = "transfer") -> None:
    """Writes Transfer's config for ENGINE's topic. The buffer and flush size are the dashboard's defaults
    (core/constants/flush_rules.go). The flush interval is the dashboard's minimum, 10 s, rather than its 180 s
    default, so a drain's last partial flush doesn't wait out three minutes inside the timing."""
    transfer = {
        "outputSource": "s3",
        "queue": "kafka",
        "mode": "replication",
        "flushIntervalSeconds": 10,
        "bufferRows": 1_000_000,
        "flushSizeKb": 128_000,
        "kafka": {
            "bootstrapServer": "kafka:9092",
            "groupID": group,
            "disableTLS": True,
            "topicConfigs": [{"referenceID": "orders", "topic": ENGINE.topic, "cdcFormat": "debezium.relational", "cdcKeyFormat": "org.apache.kafka.connect.json.JsonConverter", "db": "bench", "schema": "bench", "tableName": TABLE.lower()}],
        },
        "s3": {"bucket": cfg.bucket, "folderName": folder, "awsRegion": cfg.region, "roleARN": cfg.transfer_role_arn, "outputFormat": "parquet", "tableNameSeparator": "."},
    }
    write_state("transfer.yaml", transfer)


def run_prime(cfg: Config, args: argparse.Namespace) -> None:
    """An engine starts from the current SCN when it has no offset. Priming saves one, so a drain's load lands after
    it, and records where the engine's topic stood against the bench's count of changes written."""
    require_setup()
    compose("up", "-d", "--wait", "kafka")
    stop_engines()
    ENGINE.offsets.unlink(missing_ok=True)
    compose("up", "-d", ENGINE.service)
    base = end_offset()
    deadline = time.monotonic() + 900
    # The engine only sees rows written after it starts mining, so keep writing a few until they arrive.
    while end_offset() < base + 10:
        if time.monotonic() > deadline:
            fail_with_logs(f"{ENGINE.name} didn't publish primer rows within 15 minutes")
        require_running()
        write_load(cfg, {"insert": 10, "update": 0, "delete": 0}, workers=1, commit_rows=10, quiet=True)
        time.sleep(10)
    # Debezium saves its offset once a minute, Reader after each batch.
    while not ENGINE.offsets.exists() or ENGINE.offsets.stat().st_size == 0:
        if time.monotonic() > deadline:
            fail_with_logs(f"{ENGINE.name} published rows but didn't save an offset")
        time.sleep(2)
    # Rows sent before the offset was saved, and any primer rows still on their way, are sent again or late. Both
    # only push the topic past what expected_offset counts, which drains and catch-ups accept.
    stop_engines()
    engines = read_state("engines.json", default={})
    engines[ENGINE.name] = {"offset": end_offset(), "changes_written": read_state("load.json").get("changes_written", 0)}
    write_state("engines.json", engines)
    log(f"Primed {ENGINE.name}. Next: ./bench.py --engine {ENGINE.name} drain")


def expected_offset() -> int:
    """The message count ENGINE's topic reaches once the engine has sent every change the bench has written."""
    primed = read_state("engines.json", default={}).get(ENGINE.name)
    if primed is None:
        sys.exit(f"{ENGINE.name} hasn't been primed since setup. Run ./bench.py --engine {ENGINE.name} prime first.")
    return primed["offset"] + read_state("load.json").get("changes_written", 0) - primed["changes_written"]


def stop_engines() -> None:
    """Stops every engine, so only the one being measured mines and the others don't compete for the database."""
    compose("stop", "-t", "60", *(engine.service for engine in ENGINES.values()))


def run_load_command(cfg: Config, args: argparse.Namespace) -> None:
    require_setup()
    print(json.dumps(write_load(cfg, parse_mix(args.mix, args.changes), args.workers, args.commit_rows), indent=2))


def run_drain(cfg: Config, args: argparse.Namespace) -> None:
    require_setup()
    counts = parse_mix(args.mix, args.changes)
    compose("up", "-d", "--wait", "kafka")
    # Changes written while this engine was stopped, by another engine's drains or logminer, would land in this
    # drain's backlog. Send them first, untimed.
    if end_offset() < expected_offset():
        catch_up(expected_offset())
    stop_engines()
    base_partitions, base_bytes = partition_offsets(), topic_bytes()
    base_offset = sum(base_partitions.values())

    held = open_transaction(cfg, args.open_transaction) if args.open_transaction else None
    load = write_load(cfg, counts, args.workers, args.commit_rows)
    expected = base_offset + args.changes

    log(f"Starting {ENGINE.name} to drain {args.changes:,} changes")
    started = time.monotonic()
    started_at = utc_now()
    compose("up", "-d", ENGINE.service)
    sampler = ContainerSampler(container_id(ENGINE.service))
    sampler.start()
    RESULTS.mkdir(exist_ok=True)
    stamp = started_at.replace(":", "")
    profiler = None
    offset, moved, first_message, first_count, reached = base_offset, started, None, 0, None
    try:
        while True:
            time.sleep(args.poll_seconds)
            require_running()
            now, current = time.monotonic(), end_offset()
            if current > offset:
                if first_message is None:
                    first_message, first_count = now, current - base_offset
                    if args.profile_seconds and ENGINE.name == "reader":
                        profiler = ReaderProfiler(args.profile_seconds, RESULTS / f"drain-{stamp}")
                        profiler.start()
                offset, moved = current, now
                log(f"{current - base_offset:,} of {args.changes:,} messages after {now - started:,.0f} s")
            if reached is None and current >= expected:
                reached = now
            if reached is not None and now - moved >= args.settle_seconds:
                break
            if now - moved >= args.stall_seconds:
                log(f"No new messages for {args.stall_seconds:.0f} s, stopping")
                break
    finally:
        sampler.stop()
        if profiler:
            profiler.join(timeout=args.profile_seconds + 120)
        ended_at = utc_now()
        time.sleep(ENGINE.offset_flush_seconds)
        stop_engines()
        if held:
            held["connection"].rollback()
            held["connection"].close()

    # Time to the last poll that saw the offset move, so messages past the expected count, such as tombstones, count.
    produced = offset - base_offset
    seconds = moved - started
    kafka_bytes = topic_bytes() - base_bytes
    result = {
        "status": "complete" if produced >= args.changes else "incomplete",
        "started_at": started_at,
        "ended_at": ended_at,
        "drain_seconds": round(seconds, 1),
        "seconds_to_first_message": round(first_message - started, 1) if first_message else None,
        "poll_seconds": args.poll_seconds,
        "changes": args.changes,
        "messages": produced,
        "changes_per_second": round(args.changes / seconds) if seconds > 0 else None,
        # Leaves out Reader's startup, about 12 s locally, which matters for short drains. Accurate to a poll.
        "changes_per_second_after_first_message": round((produced - first_count) / (moved - first_message)) if first_message and moved > first_message else None,
        "redo_bytes": load["redo_bytes"],
        "redo_gb_per_hour": gb_per_hour(load["redo_bytes"], seconds),
        "kafka_bytes": kafka_bytes,
        "kafka_gb_per_hour": gb_per_hour(kafka_bytes, seconds),
        "engine": ENGINE.name,
        "engine_container": sampler.summary(),
        "open_transaction": {key: value for key, value in held.items() if key != "connection"} if held else None,
        "logminer_sessions": logminer_sessions(started_at) if ENGINE.name == "reader" else None,
        "profiles": profiler.files if profiler else [],
        "load": load,
        "setup": read_state("load.json"),
        "reader_config": reader_settings() if ENGINE.name == "reader" else None,
        "images": image_digests(),
        "database": database_class(cfg),
    }
    engines = read_state("engines.json")
    # Per partition too, so transfer-drain can start Transfer at this drain's first message in each.
    engines[ENGINE.name]["last_drain"] = {"from": base_offset, "to": offset, "from_partitions": base_partitions, "to_partitions": partition_offsets(), "changes": args.changes, "redo_bytes": load["redo_bytes"], "started_at": started_at}
    write_state("engines.json", engines)
    path = RESULTS / f"drain-{stamp}.json"
    path.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    log(f"Saved {path}")
    if produced < args.changes:
        log(f"Only {produced:,} of {args.changes:,} messages arrived, so the rate above is not a full drain")
    if cfg.mode == "rds":
        log(f"Database CPU and I/O for this window, a few minutes from now: ./bench.py rds-cpu --start {started_at} --end {ended_at}")


def open_transaction(cfg: Config, table: str) -> dict:
    """Opens a transaction that inserts one row, into BENCH.SIDE or BENCH.ORDERS, and returns its connection, left open,
    with the SCN before it started. The ORDERS row's key is far above the keys the load inserts."""
    connection = cfg.bench()
    cursor = connection.cursor()
    if table == "other" and cursor.execute("SELECT COUNT(*) FROM user_tables WHERE table_name = 'SIDE'").fetchone()[0] == 0:
        cursor.execute("CREATE TABLE SIDE (id NUMBER(18) PRIMARY KEY, note VARCHAR2(100))")
    with cfg.admin() as admin:
        before = current_scn(admin)
    if table == "other":
        cursor.execute("INSERT INTO SIDE VALUES (:id, 'open')", id=time.time_ns() // 1000)
    else:
        cursor.execute(INSERT_ROWS.format(hint=""), base=900_000_000_000_000 + time.time_ns() % 10**14, note_bytes=10, n=1)
    log(f"Opened a transaction on {'BENCH.SIDE' if table == 'other' else f'{SCHEMA}.{TABLE}'} after SCN {before}, left open until the drain ends")
    return {"connection": connection, "table": table, "scn_before": before}


def logminer_sessions(since: str) -> dict:
    """Totals the SCN ranges of Reader's LogMiner sessions since since, from its debug log (READER_DEBUG=true): how many
    SCNs they mined, and how many of those no earlier session had. Empty without the debug log."""
    logs = compose("logs", "--no-log-prefix", "--since", since, ENGINE.service, capture=True, check=False).stdout
    ranges = [(int(a), int(b)) for a, b in re.findall(r'Started LogMiner session.*?startSCN="?(\d+)"?.*?endSCN="?(\d+)"?', logs)]
    if not ranges:
        return {}
    mined = sum(end - start + 1 for start, end in ranges)
    new, highest = 0, ranges[0][0] - 1
    for start, end in ranges:
        new += max(0, end - max(highest, start - 1))
        highest = max(highest, end)
    return {"sessions": len(ranges), "scns_mined": mined, "scns_new": new, "mined_per_new": round(mined / new, 3) if new else None}


WIDE = "WIDE"
# Four full VARCHAR2(4000) columns: a row takes more than one 8 KB block, so LogMiner builds each change to it from
# several pieces of redo.
CREATE_WIDE = f"""CREATE TABLE {WIDE} (id NUMBER(18) PRIMARY KEY, a VARCHAR2(4000), b VARCHAR2(4000), c VARCHAR2(4000),
d VARCHAR2(4000), n NUMBER(18))"""
INSERT_WIDE = f"INSERT INTO {WIDE} VALUES (:id, RPAD(:a, 4000, :a), RPAD('b', 4000, 'b'), RPAD('c', 4000, 'c'), RPAD('d', 4000, 'd'), :n)"


def run_undo_check(cfg: Config, args: argparse.Namespace) -> None:
    """Streams, with Reader running, the load on BENCH.ORDERS and, from one more session, transactions on BENCH.WIDE that
    roll back to a savepoint, fail a statement, delete an earlier row, and sometimes roll back. Then it reads WIDE's
    topic and checks it holds exactly the changes that committed, in commit order."""
    require_setup()
    compose("up", "-d", "--wait", "kafka")
    if end_offset() < expected_offset():
        catch_up(expected_offset())
    stop_engines()
    with cfg.bench() as bench:
        cursor = bench.cursor()
        if cursor.execute("SELECT COUNT(*) FROM user_tables WHERE table_name = :name", name=WIDE).fetchone()[0]:
            cursor.execute(f"DROP TABLE {WIDE} PURGE")
        cursor.execute(CREATE_WIDE)
        cursor.execute(f"ALTER TABLE {WIDE} ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS")
    reader_config = read_state("reader.yaml")
    streamed = dict(reader_config)
    streamed["oracle"] = {**reader_config["oracle"], "tables": [*reader_config["oracle"]["tables"], {"schema": SCHEMA, "name": WIDE}]}
    write_state("reader.yaml", streamed)
    # Debezium streams the tables in its include list, so add WIDE there too, and put the file back afterwards.
    dbz_properties = STATE / "debezium" / "conf" / "application.properties"
    dbz_config = dbz_properties.read_text() if dbz_properties.exists() else None
    if dbz_config is not None:
        dbz_properties.write_text(re.sub(r"^(debezium\.source\.table\.include\.list=.*)$", rf"\1,{SCHEMA}.{WIDE}", dbz_config, flags=re.M))
    # WIDE's topic beside ENGINE's: benchmark.BENCH.WIDE for Reader, dbz.BENCH.WIDE for Debezium.
    wide_topic = f"{ENGINE.topic.rsplit('.', 1)[0]}.{WIDE}"
    # Keys of this run start here, so the topic's messages from earlier runs are told apart.
    base = time.time_ns() // 1000 * 10
    started_at = utc_now()
    try:
        compose("up", "-d", ENGINE.service)
        time.sleep(30)
        require_running()
        stop = threading.Event()
        expected: list[tuple] = []
        wide_started = time.monotonic()
        with ThreadPoolExecutor(max_workers=1) as pool:
            wide = pool.submit(write_wide, cfg, base, stop, expected)
            load = write_load(cfg, parse_mix(args.mix, args.changes), args.workers, args.commit_rows)
            time.sleep(max(0, args.wide_seconds - (time.monotonic() - wide_started)))
            stop.set()
            transactions = wide.result()
        target = expected_offset()
        log(f"Waiting for {ENGINE.name} to send the load and {len(expected):,} changes to {WIDE}")
        last, moved = (-1, -1), time.monotonic()
        while True:
            time.sleep(5)
            require_running()
            current = (end_offset(), topic_offset(wide_topic))
            if current != last:
                last, moved = current, time.monotonic()
            if time.monotonic() - moved >= args.settle_seconds and current[0] >= target:
                break
            if time.monotonic() - moved >= 300:
                log("No new messages for 300 s, stopping")
                break
    finally:
        ended_at = utc_now()
        # Let Debezium save an offset past this run, so the next run doesn't mine this one's WIDE changes again.
        time.sleep(ENGINE.offset_flush_seconds)
        stop_engines()
        write_state("reader.yaml", reader_config)
        if dbz_config is not None:
            dbz_properties.write_text(dbz_config)
    got = wide_changes(wide_topic, base)
    mismatches = [{"position": i, "want": list(w) if w else None, "got": list(g) if g else None} for i, (w, g) in enumerate(zip_longest(expected, got)) if w != g]
    # One lost or extra change shifts every position after it, so also list what differs regardless of order.
    want_counts, got_counts = Counter(expected), Counter(got)
    result = {
        "status": "pass" if not mismatches and end_offset() >= target else "fail",
        "started_at": started_at,
        "ended_at": ended_at,
        "wide_transactions": transactions,
        "wide_changes_expected": len(expected),
        "wide_changes_got": len(got),
        "orders_messages": end_offset(),
        "orders_expected": target,
        "mismatches": mismatches[:20],
        "mismatch_count": len(mismatches),
        "first_mismatch_context": {"want": [list(w) for w in expected[max(0, mismatches[0]["position"] - 3):mismatches[0]["position"] + 4]], "got": [list(g) for g in got[max(0, mismatches[0]["position"] - 3):mismatches[0]["position"] + 4]]} if mismatches else None,
        "missing": [list(w) for w in (want_counts - got_counts).elements()][:50],
        "unexpected": [list(g) for g in (got_counts - want_counts).elements()][:50],
        "engine": ENGINE.name,
        "wide_topic": wide_topic,
        "load": load,
        "logminer_sessions": logminer_sessions(started_at),
        "images": image_digests(),
    }
    RESULTS.mkdir(exist_ok=True)
    path = RESULTS / f"undo-check-{started_at.replace(':', '')}.json"
    path.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "load"}, indent=2))
    log(f"Saved {path}")
    if result["status"] != "pass":
        sys.exit("undo-check failed")


def write_wide(cfg: Config, base: int, stop: threading.Event, expected: list[tuple]) -> dict:
    """Writes transactions on WIDE until stop is set, and appends the changes each committed one sends, as wide_changes
    describes them, to expected in commit order. Each one inserts a row, rolls back an update of it and another insert to
    a savepoint, and updates it. Every 4th also fails an insert of a duplicate key, every 3rd deletes the row of 3
    transactions before if it committed, and every 5th rolls back."""
    counts = {"committed": 0, "rolled_back": 0}
    exists: set[int] = set()
    with cfg.bench() as connection:
        cursor = connection.cursor()
        i = 0
        while not stop.is_set():
            key, changes = base + 2 * i, []
            cursor.execute(INSERT_WIDE, id=key, a="a", n=1)
            changes.append(("c", key, 1, "a"))
            time.sleep(0.01)
            cursor.execute("SAVEPOINT s1")
            cursor.execute(f"UPDATE {WIDE} SET n = -1, a = RPAD('x', 4000, 'x') WHERE id = :id", id=key)
            cursor.execute(INSERT_WIDE, id=key + 1, a="x", n=-1)
            time.sleep(0.01)
            cursor.execute("ROLLBACK TO SAVEPOINT s1")
            if i % 4 == 0:
                try:
                    cursor.execute(INSERT_WIDE, id=key, a="x", n=-2)
                    raise RuntimeError(f"inserting {WIDE} key {key} twice didn't fail")
                except oracledb.IntegrityError:
                    pass
            cursor.execute(f"UPDATE {WIDE} SET n = 2 WHERE id = :id", id=key)
            changes.append(("u", key, 2, "a"))
            deleted = key - 6 if i % 3 == 0 and key - 6 in exists else None
            if deleted:
                cursor.execute(f"DELETE FROM {WIDE} WHERE id = :id", id=deleted)
                changes.append(("d", deleted, 2, "a"))
            time.sleep(0.01)
            if i % 5 == 4:
                connection.rollback()
                counts["rolled_back"] += 1
            else:
                connection.commit()
                counts["committed"] += 1
                expected.extend(changes)
                exists.add(key)
                if deleted:
                    exists.discard(deleted)
            i += 1
    return counts


def wide_changes(topic: str, base: int) -> list[tuple]:
    """Reads topic from the start and returns its changes to keys from base on, as (operation, key, N, A's first
    character), skipping a change with a column that isn't its full 4,000 characters, which counts as a mismatch."""
    result = compose("exec", "-T", "kafka", "/opt/kafka/bin/kafka-console-consumer.sh", "--bootstrap-server", "localhost:9092", "--topic", topic, "--from-beginning", "--timeout-ms", "30000", capture=True, check=False)
    changes = []
    for line in result.stdout.splitlines():
        if not line.startswith("{"):
            continue
        payload = json.loads(line)
        payload = payload.get("payload", payload)
        row = payload.get("after") or payload.get("before") or {}
        key = int(row.get("id", row.get("ID", 0)) or 0)
        if key < base:
            continue
        values = {name.lower(): value for name, value in row.items()}
        full = all(isinstance(values.get(column), str) and len(values[column]) == 4000 for column in "abcd")
        changes.append((payload.get("op"), key, int(values.get("n") or 0), values["a"][0] if full else f"partial {[len(values.get(c) or '') for c in 'abcd']}"))
    return changes


def topic_offset(topic: str) -> int:
    result = compose("exec", "-T", "kafka", "/opt/kafka/bin/kafka-get-offsets.sh", "--bootstrap-server", "localhost:9092", "--topic", topic, capture=True, check=False)
    return sum(int(parts[2]) for parts in (line.strip().split(":") for line in result.stdout.splitlines()) if len(parts) == 3 and parts[2].isdigit())


def write_load(cfg: Config, counts: dict[str, int], workers: int, commit_rows: int, quiet: bool = False) -> dict:
    """Writes counts[kind] rows of each kind from workers sessions and returns what it wrote and the redo it made.

    Inserts take new keys. Updates cycle through the lower half of the seeded keys, and deletes consume the upper
    half, so the two never touch the same row. state/load.json keeps the next free key of each kind across runs.
    """
    keys = KeyAllocator(read_state("load.json"))
    keys.check(counts, commit_rows)
    with cfg.admin() as admin:
        redo_before = redo_size(admin)
        plans = [interleave(share(counts, workers, w), commit_rows) for w in range(workers)]
        if not quiet:
            log(f"Writing {sum(counts.values()):,} changes from {workers} sessions, {commit_rows:,} rows per commit")
        started = time.monotonic()
        with ThreadPoolExecutor(max_workers=workers) as pool:
            done = list(pool.map(lambda plan: apply_plan(cfg, keys, plan), plans))
        seconds = time.monotonic() - started
        redo_bytes = redo_size(admin) - redo_before
    written = {kind: sum(d[kind] for d in done) for kind in KINDS}
    keys.state["changes_written"] = keys.state.get("changes_written", 0) + sum(written.values())
    write_state("load.json", keys.state)
    if written != counts:
        sys.exit(f"load wrote {written}, expected {counts}")
    result = {"rows": written, "workers": workers, "commit_rows": commit_rows, "seconds": round(seconds, 1), "changes_per_second": round(sum(written.values()) / seconds) if seconds else None, "redo_bytes": redo_bytes}
    if not quiet:
        log(f"Wrote {sum(written.values()):,} changes in {seconds:,.1f} s, {redo_bytes / 1e9:,.2f} GB of redo")
    return result


def apply_plan(cfg: Config, keys: KeyAllocator, plan: list[tuple[str, int]]) -> dict[str, int]:
    note_bytes = keys.state["note_bytes"]
    done = dict.fromkeys(KINDS, 0)
    with cfg.bench() as connection:
        cursor = connection.cursor()
        for kind, n in plan:
            lo = keys.take(kind, n)
            if kind == "insert":
                cursor.execute(INSERT_ROWS.format(hint=""), base=lo - 1, note_bytes=note_bytes, n=n)
            else:
                cursor.execute(UPDATE_ROWS if kind == "update" else DELETE_ROWS, lo=lo, hi=lo + n - 1)
            if cursor.rowcount != n:
                raise RuntimeError(f"{kind} of keys {lo} to {lo + n - 1} changed {cursor.rowcount} rows, expected {n}")
            connection.commit()
            done[kind] += n
    return done


class KeyAllocator:
    """Hands out key ranges to the load's sessions. One lock keeps two sessions from taking the same range."""

    def __init__(self, state: dict) -> None:
        self.state = dict(state)
        self.lock = threading.Lock()

    def check(self, counts: dict[str, int], commit_rows: int) -> None:
        seed = self.state["seed_rows"]
        free = seed - self.state["next_delete"] + 1
        if counts["delete"] > free:
            sys.exit(f"{counts['delete']:,} deletes requested but only {free:,} seeded rows are left to delete. Rerun setup with --reset or a larger --seed-rows.")
        if counts["update"] and commit_rows > seed // 2:
            sys.exit("--commit-rows is larger than the half of the seeded keys that updates cycle through")

    def take(self, kind: str, n: int) -> int:
        with self.lock:
            if kind == "insert":
                lo = self.state["next_insert"]
                self.state["next_insert"] = lo + n
            elif kind == "delete":
                lo = self.state["next_delete"]
                self.state["next_delete"] = lo + n
            else:
                lo = self.state["next_update"]
                if lo + n - 1 > self.state["seed_rows"] // 2:
                    lo = 1
                self.state["next_update"] = lo + n
            return lo


def parse_mix(mix: str, changes: int) -> dict[str, int]:
    percents = dict.fromkeys(KINDS, 0)
    for part in mix.split(","):
        kind, _, value = part.partition("=")
        if kind.strip() not in percents:
            sys.exit(f"--mix kinds are {', '.join(KINDS)}, got {kind!r}")
        percents[kind.strip()] = int(value)
    if sum(percents.values()) != 100:
        sys.exit(f"--mix must add up to 100, got {sum(percents.values())}")
    counts = {kind: changes * percent // 100 for kind, percent in percents.items()}
    counts[max(percents, key=percents.get)] += changes - sum(counts.values())
    return counts


def share(counts: dict[str, int], workers: int, worker: int) -> dict[str, int]:
    """Splits counts evenly across workers, giving the remainder to the first ones."""
    return {kind: count // workers + (1 if worker < count % workers else 0) for kind, count in counts.items()}


def interleave(counts: dict[str, int], commit_rows: int) -> list[tuple[str, int]]:
    """Orders one session's commits so each kind is spread evenly across the run instead of written in phases."""
    chunks = {kind: [commit_rows] * (count // commit_rows) + ([count % commit_rows] if count % commit_rows else []) for kind, count in counts.items()}
    taken = dict.fromkeys(chunks, 0)
    plan = []
    for _ in range(sum(len(c) for c in chunks.values())):
        kind = max((k for k in chunks if taken[k] < len(chunks[k])), key=lambda k: (len(chunks[k]) - taken[k]) / len(chunks[k]))
        plan.append((kind, chunks[kind][taken[kind]]))
        taken[kind] += 1
    return plan


def redo_size(admin: oracledb.Connection) -> int:
    """Redo the whole instance has written since startup, in bytes."""
    return int(admin.cursor().execute("SELECT value FROM v$sysstat WHERE name = 'redo size'").fetchone()[0])


class ReaderProfiler(threading.Thread):
    """Saves Reader's CPU profile for seconds, then its heap and allocations, from the pprof port compose publishes."""

    def __init__(self, seconds: int, prefix: Path) -> None:
        super().__init__(daemon=True)
        self.seconds = seconds
        self.prefix = prefix
        self.files: list[str] = []

    def run(self) -> None:
        for name, query in (("cpu", f"profile?seconds={self.seconds}"), ("heap", "heap"), ("allocs", "allocs")):
            path = Path(f"{self.prefix}.{name}.pprof")
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:8081/debug/pprof/{query}", timeout=self.seconds + 60) as response:
                    path.write_bytes(response.read())
                self.files.append(path.name)
            except OSError as err:
                log(f"Couldn't save Reader's {name} profile: {err}")


def run_logminer(cfg: Config, args: argparse.Namespace) -> None:
    """Times LogMiner mining a fresh load by itself, with Reader's session options and query.

    Server mode counts the rows and the bytes of SQL_REDO in Oracle, so LogMiner still builds every row but nothing is
    sent. Client mode also fetches every row here, as Reader does. With several sessions, each mines its own run of
    archived logs at the same time; a transaction can span two runs, which doesn't matter for counting.
    """
    require_setup()
    stop_engines()
    modes = [mode.strip() for mode in args.modes.split(",")]
    if not set(modes) <= {"server", "client"}:
        sys.exit("--modes takes server and client")
    session_counts = [int(count) for count in args.sessions.split(",")]

    with cfg.admin() as admin:
        start_scn = current_scn(admin)
    load = write_load(cfg, parse_mix(args.mix, args.changes), args.workers, args.commit_rows)
    end_scn, logs = archive_through(cfg, start_scn)
    log(f"Mining SCNs {start_scn + 1} to {end_scn} in {len(logs)} archived logs")

    runs = []
    for mode in modes:
        for sessions in session_counts:
            groups = split_logs(logs, sessions)
            started = time.monotonic()
            with ThreadPoolExecutor(max_workers=len(groups)) as pool:
                parts = list(pool.map(lambda group: mine_logs(cfg, group, start_scn, end_scn, mode, args.fetch_rows), groups))
            seconds = time.monotonic() - started
            changes = sum(part["changes"] for part in parts)
            run = {
                "mode": mode,
                "sessions": len(groups),
                "seconds": round(seconds, 1),
                "setup_seconds_max": max(part["setup_seconds"] for part in parts),
                "changes": changes,
                "rows": sum(part["rows"] for part in parts),
                "sql_redo_bytes": sum(part["sql_redo_bytes"] for part in parts),
                "changes_per_second": round(changes / seconds) if seconds else None,
                "redo_gb_per_hour": gb_per_hour(load["redo_bytes"], seconds),
            }
            runs.append(run)
            log(f"{mode}, {run['sessions']} sessions: {changes:,} changes in {seconds:,.1f} s, {run['changes_per_second']:,} changes/s, {run['redo_gb_per_hour']} redo GB/h")
            if changes < args.changes:
                log(f"Mined {changes:,} changes but the load wrote {args.changes:,}")

    stamp = utc_now().replace(":", "")
    result = {"start_scn": start_scn, "end_scn": end_scn, "archived_logs": len(logs), "runs": runs, "load": load, "setup": read_state("load.json"), "database": database_class(cfg)}
    RESULTS.mkdir(exist_ok=True)
    path = RESULTS / f"logminer-{stamp}.json"
    path.write_text(json.dumps(result, indent=2) + "\n")
    log(f"Saved {path}. Each engine's next drain sends this load first, untimed.")


def catch_up(target: int) -> None:
    """Lets ENGINE send changes written while it was stopped, untimed, so a drain's backlog is only its own."""
    log(f"Letting {ENGINE.name} catch up on {target - end_offset():,} changes written while it was stopped")
    stop_engines()
    compose("up", "-d", ENGINE.service)
    deadline = time.monotonic() + 3600
    while end_offset() < target:
        if time.monotonic() > deadline:
            fail_with_logs(f"{ENGINE.name} didn't catch up within an hour")
        require_running()
        time.sleep(10)
    time.sleep(ENGINE.offset_flush_seconds + 15)
    stop_engines()


def current_scn(connection: oracledb.Connection) -> int:
    return int(connection.cursor().execute("SELECT current_scn FROM v$database").fetchone()[0])


def archive_through(cfg: Config, start_scn: int) -> tuple[int, list[tuple[int, int, str]]]:
    """Archives the current redo log and returns the SCN the load ended at and the archived logs after start_scn,
    as (first SCN, next SCN, name) in sequence order."""
    with cfg.admin() as admin:
        end_scn = current_scn(admin)
        if cfg.mode == "rds":
            admin.cursor().execute("BEGIN rdsadmin.rdsadmin_util.switch_logfile; END;")
        else:
            with cfg.local_root() as root:
                root.cursor().execute("ALTER SYSTEM ARCHIVE LOG CURRENT")
        query = """SELECT DISTINCT sequence#, first_change#, next_change#, name FROM v$archived_log
            WHERE next_change# > :start_scn AND first_change# <= :end_scn AND deleted = 'NO' AND standby_dest = 'NO'
                AND name IS NOT NULL AND resetlogs_change# = (SELECT resetlogs_change# FROM v$database)
            ORDER BY sequence#"""
        deadline = time.monotonic() + 300
        while True:
            logs = admin.cursor().execute(query, start_scn=start_scn, end_scn=end_scn).fetchall()
            if logs and logs[-1][2] > end_scn and logs[0][1] <= start_scn + 1:
                return end_scn, [(int(first), int(next_), name) for _, first, next_, name in logs]
            if time.monotonic() > deadline:
                sys.exit(f"the archived logs don't cover SCNs {start_scn + 1} to {end_scn} after 5 minutes")
            time.sleep(3)


def split_logs(logs: list[tuple[int, int, str]], sessions: int) -> list[list[tuple[int, int, str]]]:
    """Splits logs into at most sessions contiguous runs of nearly equal length."""
    sessions = max(1, min(sessions, len(logs)))
    size, extra = divmod(len(logs), sessions)
    groups, start = [], 0
    for i in range(sessions):
        end = start + size + (1 if i < extra else 0)
        groups.append(logs[start:end])
        start = end
    return groups


def mine_logs(cfg: Config, logs: list[tuple[int, int, str]], start_scn: int, end_scn: int, mode: str, fetch_rows: int) -> dict:
    """Mines the redo in logs between start_scn and end_scn in one LogMiner session, as Reader's ARTIE user."""
    password = read_state("passwords.json")["artie"]
    # On Oracle Free, LogMiner runs in the CDB root and sees every PDB's redo, as Reader's logMinerServiceName does.
    service, pdb_clause = (cfg.service, "") if cfg.mode == "rds" else ("FREE", " AND SRC_CON_NAME = 'FREEPDB1'")
    first, last = max(start_scn + 1, logs[0][0]), min(end_scn, logs[-1][1] - 1)
    with oracledb.connect(user=cfg.artie_user, password=password, dsn=f"{cfg.oracle_host}:1521/{service}") as connection:
        cursor = connection.cursor()
        started = time.monotonic()
        cursor.execute("ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS' NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF9' NLS_TIMESTAMP_TZ_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF9 TZH:TZM'")
        for i, (_, _, name) in enumerate(logs):
            option = "DBMS_LOGMNR.NEW" if i == 0 else "DBMS_LOGMNR.ADDFILE"
            cursor.execute(f"BEGIN DBMS_LOGMNR.ADD_LOGFILE(LOGFILENAME => :name, OPTIONS => {option}); END;", name=name)
        cursor.execute(f"BEGIN DBMS_LOGMNR.START_LOGMNR(STARTSCN => {first}, ENDSCN => {last}, OPTIONS => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG + DBMS_LOGMNR.NO_ROWID_IN_STMT); END;")
        setup_seconds = round(time.monotonic() - started, 2)
        # Reader's filter: the table's inserts, deletes and updates, plus every commit and rollback.
        where = f"WHERE SCN > :scn AND ((OPERATION_CODE IN (1, 2, 3) AND SEG_OWNER = '{SCHEMA}' AND TABLE_NAME = '{TABLE}') OR OPERATION_CODE IN (7, 36)){pdb_clause}"
        try:
            if mode == "server":
                changes, rows, size = cursor.execute(f"SELECT NVL(SUM(CASE WHEN OPERATION_CODE IN (1, 2, 3) AND CSF = 0 THEN 1 END), 0), COUNT(*), NVL(SUM(LENGTHB(SQL_REDO)), 0) FROM V$LOGMNR_CONTENTS {where}", scn=first - 1).fetchone()
            else:
                cursor.arraysize = cursor.prefetchrows = fetch_rows
                cursor.execute(f"SELECT SCN, TIMESTAMP, OPERATION_CODE, SEG_OWNER, TABLE_NAME, SQL_REDO, ROW_ID, XIDUSN || '.' || XIDSLT || '.' || XIDSQN, RS_ID, CSF, ROLLBACK FROM V$LOGMNR_CONTENTS {where}", scn=first - 1)
                changes = rows = size = 0
                while batch := cursor.fetchmany():
                    rows += len(batch)
                    for row in batch:
                        if row[2] in (1, 2, 3):
                            # Count each change once: SQL_REDO over 4000 bytes continues on rows with CSF = 1.
                            changes += row[9] == 0
                            size += len(row[5] or "")
        finally:
            cursor.execute("BEGIN DBMS_LOGMNR.END_LOGMNR; END;")
    return {"changes": int(changes), "rows": int(rows), "sql_redo_bytes": int(size), "setup_seconds": setup_seconds}


class ContainerSampler(threading.Thread):
    """Samples a container's CPU and memory with docker stats while a drain runs."""

    def __init__(self, container: str) -> None:
        super().__init__(daemon=True)
        self.container = container
        self.cpu: list[float] = []
        self.memory: list[float] = []
        self.stopping = threading.Event()

    def run(self) -> None:
        while not self.stopping.is_set():
            sample = subprocess.run(["docker", "stats", "--no-stream", "--format", "{{.CPUPerc}}|{{.MemUsage}}", self.container], capture_output=True, text=True)
            if sample.returncode == 0 and "|" in sample.stdout:
                cpu, memory = sample.stdout.strip().split("|", 1)
                self.cpu.append(float(cpu.rstrip("%")) / 100)
                self.memory.append(parse_bytes(memory.split("/")[0]))
            self.stopping.wait(5)

    def stop(self) -> None:
        self.stopping.set()
        self.join(timeout=30)

    def summary(self) -> dict:
        if not self.cpu:
            return {"samples": 0}
        return {"samples": len(self.cpu), "cpu_cores_avg": round(sum(self.cpu) / len(self.cpu), 2), "cpu_cores_max": round(max(self.cpu), 2), "memory_bytes_max": int(max(self.memory))}


def parse_bytes(text: str) -> float:
    match = re.fullmatch(r"\s*([\d.]+)\s*([KMGT]?i?B)\s*", text)
    if not match:
        return 0
    units = {"B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "KiB": 2**10, "MiB": 2**20, "GiB": 2**30, "TiB": 2**40}
    return float(match.group(1)) * units.get(match.group(2), 1)


def end_offset() -> int:
    """The topic's message count: the sum of its partitions' end offsets, or 0 before the engine creates it."""
    return sum(partition_offsets().values())


def partition_offsets() -> dict[str, int]:
    """Each partition's end offset on ENGINE's topic, keyed by partition number as text (JSON keys are text)."""
    result = compose("exec", "-T", "kafka", "/opt/kafka/bin/kafka-get-offsets.sh", "--bootstrap-server", "localhost:9092", "--topic", ENGINE.topic, capture=True, check=False)
    offsets = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split(":")
        if len(parts) == 3 and parts[0] == ENGINE.topic and parts[1].isdigit() and parts[2].isdigit():
            offsets[parts[1]] = int(parts[2])
    return offsets


def topic_bytes() -> int:
    """Bytes the topic holds on the broker's disk. Reader gzips each message, so this is the compressed size."""
    result = compose("exec", "-T", "kafka", "/opt/kafka/bin/kafka-log-dirs.sh", "--bootstrap-server", "localhost:9092", "--describe", "--topic-list", ENGINE.topic, capture=True, check=False)
    for line in result.stdout.splitlines():
        if line.startswith("{"):
            brokers = json.loads(line).get("brokers", [])
            return sum(p["size"] for b in brokers for d in b.get("logDirs", []) for p in d.get("partitions", []))
    return 0


def run_transfer_drain(cfg: Config, args: argparse.Namespace) -> None:
    """Times Transfer writing ENGINE's last drain, from its first message to its last, to Parquet in S3. Transfer
    commits a message's offset only after the flush that wrote it, so the clock stops when the committed offset
    reaches the drain's end."""
    if cfg.mode != "rds":
        sys.exit("transfer-drain writes to the bench bucket, so it needs BENCH_MODE=rds")
    drain = read_state("engines.json", default={}).get(ENGINE.name, {}).get("last_drain")
    if drain is None:
        sys.exit(f"No drain to replay. Run ./bench.py --engine {ENGINE.name} drain first.")
    stamp = utc_now().replace(":", "")
    group = f"oracle-bench-{ENGINE.name}-{stamp}"
    write_transfer_config(cfg, group=group, folder=f"transfer/{ENGINE.name}-{stamp}")
    compose("up", "-d", "--wait", "kafka")
    compose("stop", "-t", "60", "transfer")
    # A new group starts at the drain's first message in every partition.
    starts = drain.get("from_partitions") or {"0": drain["from"]}
    for partition, start in sorted(starts.items()):
        compose("exec", "-T", "kafka", "/opt/kafka/bin/kafka-consumer-groups.sh", "--bootstrap-server", "localhost:9092", "--group", group, "--topic", f"{ENGINE.topic}:{partition}", "--reset-offsets", "--to-offset", str(start), "--execute", capture=True)
    total = drain["to"] - drain["from"]
    log(f"Starting Transfer to write {total:,} messages from {ENGINE.topic} to S3")
    started, started_at = time.monotonic(), utc_now()
    compose("up", "-d", "transfer")
    sampler = ContainerSampler(container_id("transfer"))
    sampler.start()
    committed, moved = drain["from"], started
    try:
        while committed < drain["to"]:
            time.sleep(args.poll_seconds)
            now, current = time.monotonic(), committed_offset(group)
            if current > committed:
                committed, moved = current, now
                log(f"{current - drain['from']:,} of {total:,} messages written after {now - started:,.0f} s")
            if now - moved >= args.stall_seconds:
                log(f"Transfer committed nothing for {args.stall_seconds:.0f} s, stopping")
                break
    finally:
        sampler.stop()
        ended_at = utc_now()
        compose("logs", "--tail", "5", "transfer", check=False)
        compose("stop", "-t", "60", "transfer")
    seconds = moved - started
    written = committed - drain["from"]
    result = {
        "status": "complete" if committed >= drain["to"] else "incomplete",
        "engine": ENGINE.name,
        "started_at": started_at,
        "ended_at": ended_at,
        "seconds": round(seconds, 1),
        "messages": written,
        "messages_per_second": round(written / seconds) if seconds > 0 else None,
        # The source redo behind these messages, so Transfer's rate compares with the engines' and LogMiner's.
        "redo_gb_per_hour": gb_per_hour(drain["redo_bytes"], seconds),
        "transfer_container": sampler.summary(),
        "drain": drain,
        "partitions": len(drain.get("from_partitions") or {"0": 0}),
        "transfer_config": {key: value for key, value in read_state("transfer.yaml").items() if key in ("flushIntervalSeconds", "bufferRows", "flushSizeKb")},
        "images": {"transfer": output(["docker", "inspect", "--format", "{{.Config.Image}}", container_id("transfer")]).strip()},
    }
    RESULTS.mkdir(exist_ok=True)
    path = RESULTS / f"transfer-{stamp}.json"
    path.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    log(f"Saved {path}")


def committed_offset(group: str) -> int:
    """The sum of the offsets group has committed on ENGINE's topic's partitions, or 0 before its first commit."""
    result = compose("exec", "-T", "kafka", "/opt/kafka/bin/kafka-consumer-groups.sh", "--bootstrap-server", "localhost:9092", "--describe", "--group", group, capture=True, check=False)
    total = 0
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[1] == ENGINE.topic and fields[3].isdigit():
            total += int(fields[3])
    return total


# AWS's grants for a DMS user on RDS for Oracle (https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Source.Oracle.html),
# for LogMiner and for Binary Reader, without the ones for standbys, TDE and serverless replication.
DMS_GRANTS = [
    "GRANT CREATE SESSION TO DMS_USER",
    "GRANT SELECT ANY TRANSACTION TO DMS_USER",
    "GRANT SELECT ANY TABLE TO DMS_USER",
    "GRANT LOGMINING TO DMS_USER",
    "GRANT EXECUTE ON rdsadmin.rdsadmin_util TO DMS_USER",
]
DMS_SYS_GRANTS = [(name, "SELECT") for name in (
    "DBA_TABLESPACES", "ALL_VIEWS", "ALL_TAB_PARTITIONS", "ALL_INDEXES", "ALL_OBJECTS", "ALL_TABLES", "ALL_USERS",
    "ALL_CATALOG", "ALL_CONSTRAINTS", "ALL_CONS_COLUMNS", "ALL_TAB_COLS", "ALL_IND_COLUMNS", "ALL_LOG_GROUPS",
    "V_$ARCHIVED_LOG", "V_$LOG", "V_$LOGFILE", "V_$DATABASE", "V_$THREAD", "V_$PARAMETER", "V_$NLS_PARAMETERS",
    "V_$TIMEZONE_NAMES", "V_$TRANSACTION", "V_$CONTAINERS", "DBA_REGISTRY", "OBJ$", "ALL_ENCRYPTED_COLUMNS",
    "REGISTRY$SQLPATCH", "V_$LOGMNR_LOGS", "V_$LOGMNR_CONTENTS", "DBA_DIRECTORIES",
)] + [("DBMS_LOGMNR", "EXECUTE"), ("DBMS_CRYPTO", "EXECUTE")]


def run_setup_dms(cfg: Config, args: argparse.Namespace) -> None:
    if cfg.mode != "rds":
        sys.exit("setup-dms needs BENCH_MODE=rds")
    secret = json.loads(output(["aws", "secretsmanager", "get-secret-value", "--region", cfg.region, "--secret-id", args.secret_arn, "--query", "SecretString", "--output", "text"]))
    with cfg.admin() as admin:
        cursor = admin.cursor()
        create_user(cursor, secret["username"], secret["password"])
        for grant in DMS_GRANTS:
            cursor.execute(grant)
        for name, privilege in DMS_SYS_GRANTS:
            cursor.execute("BEGIN rdsadmin.rdsadmin_util.grant_sys_object(:name, 'DMS_USER', :privilege); END;", name=name, privilege=privilege)
        # Binary Reader reads redo files as BFILEs through these directories.
        cursor.execute("BEGIN rdsadmin.rdsadmin_master_util.create_archivelog_dir; END;")
        cursor.execute("BEGIN rdsadmin.rdsadmin_master_util.create_onlinelog_dir; END;")
        cursor.execute("GRANT READ ON DIRECTORY ONLINELOG_DIR TO DMS_USER")
        cursor.execute("GRANT READ ON DIRECTORY ARCHIVELOG_DIR TO DMS_USER")
    log("DMS_USER is ready")


def run_dms_load(cfg: Config, args: argparse.Namespace) -> None:
    """Writes a backlog for a DMS task and prints, as JSON on the last line, the SCN to start it from."""
    require_setup()
    stop_engines()
    with cfg.admin() as admin:
        start_scn = current_scn(admin)
    load = write_load(cfg, parse_mix(args.mix, args.changes), args.workers, args.commit_rows, quiet=True)
    print(json.dumps({"start_scn": start_scn, "changes": args.changes, "load": load}))


def run_rds_cpu(cfg: Config, args: argparse.Namespace) -> None:
    if cfg.mode != "rds":
        sys.exit("rds-cpu needs BENCH_MODE=rds")
    metrics = ["CPUUtilization", "ReadThroughput", "WriteThroughput", "ReadIOPS", "WriteIOPS"]
    rows: dict[str, dict[str, float]] = {}
    for metric in metrics:
        response = json.loads(output(["aws", "cloudwatch", "get-metric-statistics", "--region", cfg.region, "--namespace", "AWS/RDS", "--metric-name", metric, "--dimensions", f"Name=DBInstanceIdentifier,Value={cfg.db_instance_id}", "--start-time", args.start, "--end-time", args.end, "--period", "60", "--statistics", "Maximum", "--output", "json"]))
        for point in response["Datapoints"]:
            rows.setdefault(point["Timestamp"], {})[metric] = point["Maximum"]
    print(f"{'minute (UTC)':<26}{'CPU %':>8}{'read MB/s':>12}{'write MB/s':>12}{'read IOPS':>11}{'write IOPS':>12}")
    for minute in sorted(rows):
        r = rows[minute]
        print(f"{minute:<26}{r.get('CPUUtilization', 0):>8.1f}{r.get('ReadThroughput', 0) / 1e6:>12.1f}{r.get('WriteThroughput', 0) / 1e6:>12.1f}{r.get('ReadIOPS', 0):>11.0f}{r.get('WriteIOPS', 0):>12.0f}")
    if not rows:
        print("No datapoints yet. CloudWatch publishes RDS metrics a minute or two late.")


def database_class(cfg: Config) -> str:
    if cfg.mode != "rds":
        return "oracle-free (local)"
    return output(["aws", "rds", "describe-db-instances", "--region", cfg.region, "--db-instance-identifier", cfg.db_instance_id, "--query", "DBInstances[0].DBInstanceClass", "--output", "text"]).strip()


def image_digests() -> dict[str, str]:
    images = {}
    for service in ("kafka", ENGINE.service):
        cid = container_id(service)
        image = output(["docker", "inspect", "--format", "{{.Config.Image}}", cid]).strip() if cid else ""
        digest = subprocess.run(["docker", "image", "inspect", "--format", "{{index .RepoDigests 0}}", image], capture_output=True, text=True).stdout.strip() if image else ""
        images[service] = digest or image
    return images


def require_setup() -> None:
    if not (STATE / "reader.yaml").exists():
        sys.exit("Run ./bench.py setup first.")


def require_running() -> None:
    cid = container_id(ENGINE.service)
    state = output(["docker", "inspect", "--format", "{{.State.Status}}", cid]).strip() if cid else "missing"
    if state != "running":
        fail_with_logs(f"{ENGINE.name} is {state}")


def fail_with_logs(message: str) -> None:
    compose("logs", "--tail", "40", ENGINE.service, check=False)
    sys.exit(message)


def container_id(service: str) -> str:
    return compose("ps", "-a", "-q", service, capture=True, check=False).stdout.strip()


def compose(*args: str, capture: bool = False, check: bool = True) -> subprocess.CompletedProcess:
    # Run from this folder, so Compose reads .env, including COMPOSE_FILE for the local override.
    return subprocess.run(["docker", "compose", *args], cwd=HERE, check=check, text=True, capture_output=capture)


def output(command: list[str]) -> str:
    return subprocess.run(command, check=True, text=True, capture_output=True).stdout


def read_state(name: str, default: dict | None = None) -> dict:
    path = STATE / state_file(name)
    if not path.exists():
        if default is not None:
            return default
        sys.exit(f"{path} is missing. Run ./bench.py setup first.")
    return json.loads(path.read_text())


def write_state(name: str, value: dict) -> None:
    STATE.mkdir(exist_ok=True)
    path = STATE / state_file(name)
    path.write_text(json.dumps(value, indent=2) + "\n")
    path.chmod(0o600)


def new_password() -> str:
    # Oracle passwords must start with a letter and hold at most 30 characters.
    alphabet = string.ascii_letters + string.digits
    return secrets.choice(string.ascii_letters) + "".join(secrets.choice(alphabet) for _ in range(23))


def gb_per_hour(size: int, seconds: float) -> float | None:
    return round(size / seconds * 3600 / 1e9, 2) if seconds > 0 else None


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(message: str) -> None:
    print(f"{dt.datetime.now().strftime('%H:%M:%S')} {message}", flush=True)


if __name__ == "__main__":
    main()
