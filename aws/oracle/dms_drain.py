#!/usr/bin/env python3
"""Times AWS DMS draining an Oracle backlog into S3, the way bench.py drain times Reader and Debezium.

Runs where Terraform runs, with AWS credentials for the bench account. It writes the backlog on the bench instance
over SSM (bench.py dms-load), starts a CDC task at the SCN from before the load, and stops the clock when DMS's table
statistics count every change applied to the S3 target. The task is deleted afterwards.

    ./dms_drain.py --mode logminer
    ./dms_drain.py --mode binary --changes 2000000
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mode", choices=["logminer", "binary"], required=True, help="DMS's LogMiner reader, or Binary Reader")
    parser.add_argument("--changes", type=int, default=2_000_000)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--commit-rows", type=int, default=1000)
    parser.add_argument("--mix", default="insert=30,update=50,delete=20")
    parser.add_argument("--poll-seconds", type=float, default=5)
    parser.add_argument("--stall-seconds", type=float, default=600)
    args = parser.parse_args()

    outputs = json.loads(run(["terraform", f"-chdir={HERE / 'tf'}", "output", "-json"]))
    dms = outputs["dms"]["value"]
    if dms is None:
        sys.exit("DMS isn't deployed. Set enable_dms = true and apply.")
    aws = AWS(profile_from_tfvars(), region_from_outputs(outputs))
    instance = outputs["instance_id"]["value"]

    log(f"Writing {args.changes:,} changes on {instance}")
    loaded = json.loads(aws.on_box(instance, f"./bench.py dms-load --changes {args.changes} --workers {args.workers} --commit-rows {args.commit_rows} --mix {args.mix}").strip().splitlines()[-1])

    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    task_id = f"benchmark-oracle-{args.mode}-{stamp.lower()}"
    source = dms["logminer_endpoint_arn"] if args.mode == "logminer" else dms["binary_endpoint_arn"]
    mappings = {"rules": [{"rule-type": "selection", "rule-id": "1", "rule-name": "orders", "object-locator": {"schema-name": "BENCH", "table-name": "ORDERS"}, "rule-action": "include"}]}
    settings = {"Logging": {"EnableLogging": True}}
    task_arn = aws.dms("create-replication-task", "--replication-task-identifier", task_id, "--source-endpoint-arn", source,
                       "--target-endpoint-arn", dms["target_endpoint_arn"], "--replication-instance-arn", dms["replication_instance_arn"],
                       "--migration-type", "cdc", "--cdc-start-position", str(loaded["start_scn"]),
                       "--table-mappings", json.dumps(mappings), "--replication-task-settings", json.dumps(settings))["ReplicationTask"]["ReplicationTaskArn"]
    try:
        wait_for_status(aws, task_arn, {"ready"})
        log(f"Starting {task_id} at SCN {loaded['start_scn']}")
        started, started_at = time.monotonic(), utc_now()
        aws.dms("start-replication-task", "--replication-task-arn", task_arn, "--start-replication-task-type", "start-replication")
        applied, moved, first = 0, started, None
        while applied < args.changes:
            time.sleep(args.poll_seconds)
            status = task_status(aws, task_arn)
            if status in ("failed", "stopped"):
                sys.exit(f"{task_id} is {status}; see its CloudWatch log group dms-tasks-benchmark-oracle")
            now, current = time.monotonic(), applied_changes(aws, task_arn)
            if current > applied:
                applied, moved = current, now
                first = first or now
                log(f"{current:,} of {args.changes:,} changes applied after {now - started:,.0f} s")
            if now - moved >= args.stall_seconds:
                log(f"No new changes for {args.stall_seconds:.0f} s, stopping")
                break
        ended_at = utc_now()
    finally:
        if task_status(aws, task_arn) in ("running", "starting"):
            aws.dms("stop-replication-task", "--replication-task-arn", task_arn)
            wait_for_status(aws, task_arn, {"stopped", "failed"})
        aws.dms("delete-replication-task", "--replication-task-arn", task_arn)

    seconds = moved - started
    result = {
        "status": "complete" if applied >= args.changes else "incomplete",
        "mode": args.mode,
        "started_at": started_at,
        "ended_at": ended_at,
        "seconds": round(seconds, 1),
        "seconds_to_first_change": round(first - started, 1) if first else None,
        "changes": args.changes,
        "applied": applied,
        "changes_per_second": round(applied / seconds) if seconds > 0 else None,
        "redo_gb_per_hour": round(loaded["load"]["redo_bytes"] / seconds * 3600 / 1e9, 2) if seconds > 0 else None,
        "load": loaded["load"],
        "start_scn": loaded["start_scn"],
        "instance_class": aws.dms("describe-replication-instances", "--filters", f"Name=replication-instance-arn,Values={dms['replication_instance_arn']}")["ReplicationInstances"][0]["ReplicationInstanceClass"],
    }
    path = HERE / "results-dms" / f"{args.mode}-{stamp}.json"
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    log(f"Saved {path}")


class AWS:
    def __init__(self, profile: str | None, region: str) -> None:
        self.base = ["aws", "--region", region] + (["--profile", profile] if profile else [])

    def dms(self, *args: str) -> dict:
        return json.loads(run(self.base + ["dms", *args, "--output", "json"]) or "{}")

    def on_box(self, instance: str, command: str) -> str:
        """Runs command in /opt/oracle-bench as root on the bench instance and returns its output."""
        params = json.dumps({"commands": [f"cd /opt/oracle-bench && {command}"], "executionTimeout": ["3600"]})
        command_id = json.loads(run(self.base + ["ssm", "send-command", "--instance-ids", instance, "--document-name", "AWS-RunShellScript", "--parameters", params, "--output", "json"]))["Command"]["CommandId"]
        while True:
            time.sleep(5)
            result = subprocess.run(self.base + ["ssm", "get-command-invocation", "--command-id", command_id, "--instance-id", instance, "--output", "json"], capture_output=True, text=True)
            if result.returncode != 0:
                continue
            invocation = json.loads(result.stdout)
            if invocation["Status"] in ("Pending", "InProgress", "Delayed"):
                continue
            if invocation["Status"] != "Success":
                sys.exit(f"{command} on {instance} ended {invocation['Status']}: {invocation['StandardErrorContent'][-2000:]}")
            return invocation["StandardOutputContent"]


def applied_changes(aws: AWS, task_arn: str) -> int:
    stats = aws.dms("describe-table-statistics", "--replication-task-arn", task_arn)["TableStatistics"]
    return sum(s["Inserts"] + s["Updates"] + s["Deletes"] for s in stats if s["SchemaName"] == "BENCH" and s["TableName"] == "ORDERS")


def task_status(aws: AWS, task_arn: str) -> str:
    return aws.dms("describe-replication-tasks", "--filters", f"Name=replication-task-arn,Values={task_arn}")["ReplicationTasks"][0]["Status"]


def wait_for_status(aws: AWS, task_arn: str, wanted: set[str]) -> None:
    deadline = time.monotonic() + 900
    while (status := task_status(aws, task_arn)) not in wanted:
        if time.monotonic() > deadline:
            sys.exit(f"task stayed {status} for 15 minutes, waiting for {sorted(wanted)}")
        time.sleep(5)


def profile_from_tfvars() -> str | None:
    path = HERE / "tf" / "terraform.tfvars"
    for line in path.read_text().splitlines() if path.exists() else []:
        key, _, value = line.partition("=")
        if key.strip() == "aws_profile" and value.strip().strip('"'):
            return value.strip().strip('"')
    return None


def region_from_outputs(outputs: dict) -> str:
    # The connect output is "aws ssm start-session ... --region <region> --target ...".
    words = outputs["connect"]["value"].split()
    return words[words.index("--region") + 1]


def run(command: list[str]) -> str:
    return subprocess.run(command, check=True, capture_output=True, text=True).stdout


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(message: str) -> None:
    print(f"{dt.datetime.now().strftime('%H:%M:%S')} {message}", flush=True)


if __name__ == "__main__":
    main()
