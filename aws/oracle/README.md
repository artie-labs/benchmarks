# Oracle CDC throughput

Measures the fastest rate Reader can stream Oracle changes into Kafka, using RDS for Oracle SE2 and one EC2
instance that runs Kafka, Reader and, optionally, Transfer.

Each drain stops Reader, writes a fixed number of changes, then starts Reader and times how long it takes for every
change to reach Kafka. The changes are already in the redo logs when Reader starts, so the time measures how fast
LogMiner and Reader read them, not how fast the load was written.

## Cost

About $1.35 an hour while running, at us-west-2 on-demand prices:

| Item | $/hour |
| --- | --- |
| RDS Oracle SE2 db.m8i.xlarge (4 vCPU, 16 GiB), license included | 0.88 |
| 400 GB of gp3 for RDS and 100 GB for the instance | 0.07 |
| m7i.2xlarge running Kafka, Reader and Transfer | 0.40 |

db.m8i.2xlarge costs $1.75 an hour. Stopping the database and the instance between sessions leaves only storage,
about $0.07 an hour. AWS restarts a stopped database after seven days.

## Prerequisites

- Terraform and the AWS CLI with the
  [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).
- An AWS profile that can create IAM roles and delete RDS instances, such as the customer sandbox account's
  `OrganizationAccountAccessRole` (see [the sandbox README](https://github.com/artie-labs/ops/blob/master/customer_sandbox/README.md)).
- A default VPC in the region.

## Deploy

```sh
cp tf/terraform.tfvars.example tf/terraform.tfvars   # set aws_profile
terraform -chdir=tf init
terraform -chdir=tf apply   # about 20 minutes, mostly RDS
```

The instance installs Docker and copies [box](box) to `/opt/oracle-bench` on first boot. Connect with the
`connect` output, then switch to root:

```sh
$(terraform -chdir=tf output -raw connect)
sudo -i
cd /opt/oracle-bench
```

After changing files in `box`, run `terraform -chdir=tf apply` and then `oracle-bench-sync` on the instance.

## Run

```sh
./bench.py setup    # once: archive log retention, supplemental logging, 1 GB redo logs, users, table, 5M seed rows
./bench.py prime    # once: Reader saves a starting offset
./bench.py drain    # repeat: 2M changes from 8 sessions, saved to results/
```

- `setup` creates `ARTIE` with the grants in [Artie's RDS guide](https://artie.com/docs/sources/oracle/amazon-rds),
  plus `EXECUTE` on `DBMS_LOGMNR` and `SELECT` on `V$THREAD`. Reader connects as `ARTIE`, and the load writes as
  `BENCH`, which owns `BENCH.ORDERS`. The table logs all columns, as the guide asks customers to set up.
- Reader runs with quest.com's R12RPT_CN settings: batch size 25,000, gzip messages and 2 MB requests.
- `drain` takes `--changes`, `--workers`, `--commit-rows` and `--mix` (default `insert=30,update=50,delete=20`).
  Deletes consume seeded rows. When they run out, rerun `setup --reset`, then `prime`.
- Each result has the drain time, changes per second, redo and Kafka GB per hour, Reader's CPU and memory, and the
  image digests. `changes_per_second_after_first_message` leaves out Reader's startup.
- `./bench.py rds-cpu --start <started_at> --end <ended_at>` prints the database's CPU and I/O per minute for a
  drain. CloudWatch publishes them a minute or two late.

Read each result against its limits. If the database's CPU is pinned, LogMiner is the limiter, so try a larger class.
If Reader's CPU is near the instance's cores, Reader is. Storage tops out at 500 MiB/s. Run at least five drains per
setting and report the median and range.

To test another build, set `READER_IMAGE` or `TRANSFER_IMAGE` in `.env`. To write to S3 as well, start
`docker compose up -d transfer`. It writes Parquet under `transfer/` in the bench bucket and adds CPU on the same
instance, so leave it off when measuring Reader.

## Job queue and the replay box

Several people or agents can share the instance through a queue instead of running on it directly.
[`scripts/QUEUE.md`](scripts/QUEUE.md) has the rules.

- `scripts/bench-queue.sh` runs on the instance as a systemd unit. It runs one job at a time, oldest first, from
  `images/queue/` in the bench bucket.
- `scripts/submit-job.sh <name> <script> [queue]` queues a job from your machine.
- Set `replay_box = true` to create a second instance with no database. It runs `images/queue-replay/` for work that
  doesn't need RDS, such as Oracle Free integration tests and the demos LogMiner replay.
- `scripts/disk-guard.sh` runs every 10 minutes and prunes Docker when the disk passes 75%. Kafka also keeps at most
  12 GB per partition for 6 hours. Before those limits, old topics filled the 100 GB disk.
- Install both after a reboot, since they run as transient systemd units.
- The other scripts are the A/B jobs this bench used: Reader builds, parallel sessions, Transfer, and the direct redo
  reader kit.

## Pause and tear down

```sh
aws rds stop-db-instance --db-instance-identifier benchmark-oracle
aws ec2 stop-instances --instance-ids $(terraform -chdir=tf output -raw instance_id)
terraform -chdir=tf destroy
```

## Local smoke test

The same flow runs on a laptop against Oracle Free, which is capped at two CPUs and 2 GB of RAM. Use it to check
changes, not to measure throughput.

```sh
cd box
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
cp local.env .env
.venv/bin/python bench.py setup --seed-rows 400000
.venv/bin/python bench.py prime
.venv/bin/python bench.py drain --changes 300000 --workers 4
docker compose down
```
