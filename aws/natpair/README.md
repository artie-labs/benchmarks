# natpair limits

Measures what a [natpair](https://github.com/artie-labs/natpair) pair forwards before AWS's network allowances drop
packets: bandwidth and packets per second per instance type, the NAT's CPU per packet, the burst allowance, how fast
the ENA allowance counters refresh, and whether the pair stays healthy and can hand over while saturated.
[RESULTS.md](RESULTS.md) has the findings.

## Layout

```
test VPC 10.40.0.0/16                                  receiver VPC 10.50.0.0/16
  worker subnet 10.40.1.0/24                             receiver subnet 10.50.0.0/24
    2 load generators ── 0.0.0.0/0 ──> shared ENI          receiver: iperf3 servers, job queue
  public subnet 10.40.0.0/24                                   ^
    natpair NAT a, NAT b (shared ENI on the owner)             |
    public route table: 10.50.0.0/16 ──> VPC peering ──────────┘
```

Workers reach the receiver only through the NAT: the worker route table has just the default route to the shared
ENI, and only the NATs' public route table routes the receiver's CIDR over the peering. natpair translates every
worker packet to the shared ENI's private address, whatever the destination, so this loads the NAT the way internet
traffic does. Each run checks that the receiver sees only that address. Everything is in one zone, where peering
carries no transfer charge. Generators and the receiver use a 1500-byte MTU, as internet paths do.

Uploads (`MODE=up`) enter and leave the owner through the shared ENI. Replies to workers (`MODE=down`) enter through
the shared ENI and leave through the owner's own ENI, because natpair's routing rules send only traffic from the
worker CIDRs through the shared ENI's table.

## Cost

About $0.66 an hour with c7gn.medium NATs, at us-west-2 on-demand prices:

| Item | $/hour |
| --- | --- |
| 2 c7gn.medium NATs (c7gn.large: 0.25) | 0.12 |
| 2 c7gn.large load generators | 0.25 |
| c7gn.xlarge receiver | 0.25 |
| 4 public IPv4 addresses: the shared Elastic IP, each NAT's own, the receiver's | 0.02 |
| 5 8 GB gp3 volumes, DynamoDB, Lambda probes, S3 | 0.01 |

Generators and the receiver stop 4 hours after each boot (`auto_stop_minutes`). The NATs don't, so destroy the
stack when done.

## Prerequisites

- Terraform 1.6 or later, Go, and the AWS CLI with the
  [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).
- An AWS profile that can create VPCs, IAM roles and instances, such as the customer sandbox account's
  `OrganizationAccountAccessRole`.

## Deploy

```sh
cp tf/terraform.tfvars.example tf/terraform.tfvars   # set aws_profile
./scripts/build.sh                                   # builds box/bin/enapoll for arm64
terraform -chdir=tf init
terraform -chdir=tf apply
```

On a first apply, the NATs boot before the module attaches their IAM policy, and their SSM agent never registers.
Replace each NAT once, the standby first, so they boot with the policy in place (see natpair's
[Replace a NAT](https://github.com/artie-labs/natpair/blob/master/docs/operations.md#replace-a-nat)):

```sh
terraform -chdir=tf apply -replace='module.natpair.aws_instance.nat["b"]'
# wait for the new NAT's health round with "ready":true, then
terraform -chdir=tf apply -replace='module.natpair.aws_instance.nat["a"]'
```

Check that all five instances are online:

```sh
aws ssm describe-instance-information --filters Key=tag:bench,Values=natpair \
  --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output text
```

After changing files in `box`, run `terraform -chdir=tf apply`. The queue syncs them before each job.

## Run

Never run benchmarks on the instances by hand. Queue a job:

```sh
./scripts/submit-job.sh medium-1-refresh jobs/1-refresh.sh
./scripts/fetch-results.sh   # copies summaries and job logs into results/
```

The receiver runs jobs one at a time, oldest first, so queue the next jobs before one ends and the instances never
sit idle. A job is a bash script that runs in `/opt/natpair-bench` on the receiver and calls `./run.sh` once per
measured run. `run.sh` lists its settings at the top. Each run starts `enapoll` on both NATs, each generator and the
receiver at the same moment, runs iperf3 from the generators, gathers every host's files from
`s3://<bucket>/runs/<run>/` and writes a summary to `results/<run>.json`. Job logs are in `results/queue/`.

| Job | Measures |
| --- | --- |
| [1-refresh](jobs/1-refresh.sh) | Cost of one counter read, the packets-per-second ramp over 16 flows, 3 runs offered more than the CPU forwards |
| [1b-ramp-64flows](jobs/1b-ramp-64flows.sh) | The ramp over 64 flows, to spread them over a larger NAT's queues |
| [2-burst](jobs/2-burst.sh) | Full-speed uploads until the NAT falls back to its baseline bandwidth, sampled every 10 ms |
| [2c-drop-10ms](jobs/2c-drop-10ms.sh) | The same with 120 s of AWS dropping before the stop |
| [2d-drop-1ms](jobs/2d-drop-1ms.sh), [2e-drop-1ms-window](jobs/2e-drop-1ms-window.sh) | The drop phase sampled every 1 ms. 2e samples only once the burst is spent, to keep the data small |
| [3-limits](jobs/3-limits.sh) | Downloads, and small UDP packets up and down, at capped rates |
| [4-cpu](jobs/4-cpu.sh) | The NAT's CPU at fixed rates below its limits |
| [5-health](jobs/5-health.sh) | `natpair maintenance` on a saturated owner: forwarding gap, lease renewals, conntrackd |
| [6-pps-sustained](jobs/6-pps-sustained.sh) | 10 minutes of small UDP packets below the CPU limit, for a packet-rate burst |
| [7-igw](jobs/7-igw.sh) | One 60 s run through the internet gateway. Set `igw_check = true` first. About 5 GB of public transfer |

[lib.sh](box/lib.sh) sets each type's rates: `TCP_CAP`, `UDP_CAP` and `BURST_CAP` stay below what the NAT's CPU
forwards, so AWS's allowance is the limit, not the CPU. Offered more, a NAT's own lease and probe traffic starves and
the pair flaps (see RESULTS.md).

To measure the counters' refresh without loading the owner, [box/linklocal.sh](box/linklocal.sh) floods the VPC
resolver from one NAT, usually the standby, past AWS's 1,024 packets a second link-local limit, and samples that NAT:

```sh
./scripts/onbox.sh <standby id> 300 "aws s3 cp s3://<bucket>/box/linklocal.sh /tmp/ && \
  env BUCKET=<bucket> AWS_REGION=us-west-2 RUN=$(date -u +%Y%m%dT%H%M%SZ)-<type>-linklocal-1 \
  bash /tmp/linklocal.sh 3000 2 3 12 1ms"
```

`box/bin/enapoll` (source in [enapoll](enapoll)) reads the ENA counters with the ethtool ioctl that `ethtool -S`
uses, every 10 ms by default, and records how long each read took. It also samples `/proc/stat` per CPU, and the CPU
time of conntrackd, natpair and iperf3, once a second. Each summary has, per host and interface, the steady rates
(the load minus its first 3 s), the last 30 s, a per-second timeline for the NATs, every allowance counter change
with the gaps between changes, CPU per forwarded packet, iperf3 totals, the ping gap and natpair's journal lines that
matter.

To compare instance types, change `nat_instance_type` and apply it to one NAT at a time, the standby first, as
natpair's operations guide describes. The jobs read the NAT type from the bench, so they rerun unchanged.

## Phase 2: pacing builds

[RESULTS.md](RESULTS.md#phase-2-pacing-a-b) lists the `jobs/p2-*` jobs and how to resume. `run.sh` takes
`PACING=on|off` (it runs `natpair pacing-on` or `pacing-off` on both NATs first), `TOGGLE_AT`, `MODE=fair` and
`MODE=churn` (the [churn](churn) tool: a new connection per request). [scripts/replace-nats.sh](scripts/replace-nats.sh)
replaces both NATs, the standby first, with a handover in between. On a first apply, use it once so the NATs
register with SSM.

Each NAT also samples pacing's limits map once a second (`limits.txt`, `pacing_limits` in the summary).
[jobs/p2-s1-stable.sh](jobs/p2-s1-stable.sh) finds the highest stable unpaced TCP rate,
[jobs/p2-overhead-parts.sh](jobs/p2-overhead-parts.sh) splits pacing's CPU cost into its qdisc, its programs and the
pacing itself, [jobs/p2-s4b-burst-on.sh](jobs/p2-s4b-burst-on.sh) spends the burst with pacing on, and
[jobs/p2-takeover.sh](jobs/p2-takeover.sh) checks which interface a new owner paces.
[jobs/p3-baseline.sh](jobs/p3-baseline.sh) records the unpaced overload and takeover baselines for phase 3.

Phase 3 tests natpair#13 (control-plane priority). `run.sh` takes `RXTHREADS=on|off` (or a job calls `rx_switch`
from [box/lib.sh](box/lib.sh)), and `FLOOD=udp|syn FLOOD_PPS=...`, which floods the owner's own address from the
receiver with [flood](flood) during the load. Jobs: [p3-starve](jobs/p3-starve.sh) (`RX=off` or `RX=on` on its first
line), [p3-cost](jobs/p3-cost.sh), [p3-flood](jobs/p3-flood.sh) and [p3-checks](jobs/p3-checks.sh).

The release candidate checks are [rc-validate](jobs/rc-validate.sh) (smoke, handovers, saturation, churn, external
probes) and [rc-udp](jobs/rc-udp.sh) (small-UDP overload). [box/ackburst.py](box/ackburst.py) sends a burst of ACKs
without a connection and counts the resets that come back. [rc-kernel-ab](jobs/rc-kernel-ab.sh) repeats the
saturation runs on another kernel line (`nat_kernel` in `terraform.tfvars`), and [fix-failover](jobs/fix-failover.sh)
blackholes the owner's shared path to check that it still steps down.

After a stop and start, the receiver's queue, iperf3 and churn services don't come back (their units have no
`[Install]` section), so start them by hand:

```sh
./scripts/onbox.sh <receiver id> 60 'systemctl start churn-server natpair-bench-queue; for p in $(seq 5201 5232); do systemctl start iperf3@$p; done'
```

## A natpair dev build

NATs download their release at first boot, so the archive must be in the bucket before they start. Create the bucket
first, upload the build as `natpair/<tag>/natpair_linux_arm64.tar.gz`, then apply the rest. The tag must be the one
the build embeds, or the NATs' updater keeps trying to move to the pinned one.

```hcl
natpair_release_url    = "s3://<bucket>/natpair"
natpair_release        = "<tag>"
natpair_release_sha256 = "<sha256 of the archive>"
```

```sh
terraform -chdir=tf apply -target=aws_s3_bucket.bench -target=aws_s3_bucket_public_access_block.bench
aws s3 cp natpair_linux_arm64.tar.gz "s3://$(terraform -chdir=tf output -raw bucket)/natpair/<tag>/"
terraform -chdir=tf apply
```

If the build needs a newer module, such as one with new inputs, change the `?ref=` of the module source in
[tf/natpair.tf](tf/natpair.tf) as well. The module gives the NATs read access to an `s3://` release prefix.

## Tear down

```sh
terraform -chdir=tf destroy
aws resourcegroupstaggingapi get-resources --tag-filters Key=bench,Values=natpair \
  --query 'ResourceTagMappingList[].ResourceARN'
```

The tagging API can list deleted resources for a while. Check instances, addresses, network interfaces and peering
connections directly if it shows any.
