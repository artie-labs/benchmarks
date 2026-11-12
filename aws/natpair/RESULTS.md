# natpair limits: phase 1 results

Measured 2026-11-11 in the customer sandbox (us-west-2a) with natpair v0.1.1 on c7gn.medium, then c7gn.large NATs,
both on Amazon Linux 2023 kernel 6.18.56. Load came from 2 c7gn.large generators through the NAT to a c7gn.xlarge
receiver over same-zone VPC peering, with a 1500-byte MTU. Every run checked that the receiver saw only the shared
ENI's private address. The summaries are in [results/](results), one JSON per run, and
[results/summary.json](results/summary.json) groups repeats. "Forwarded pps" counts packets the owner received on
both ENIs, so each is forwarded once. "In plus out" is the rate AWS's packets-per-second allowance counts.

## The short version

- **The allowance counters are live.** While AWS dropped, the bandwidth and link-local counters changed at every
  sample, at 10 ms and at 1 ms polling, on both types. After the load stopped, the last change came within one
  sample (under 0.7 ms at 1 ms polling). One read takes about 0.2 ms and about 40 µs of CPU. An adaptive cap can see
  drops within a millisecond or two of AWS starting them. See [Counter refresh](#counter-refresh).
- **The NAT's CPU binds first on packet rate.** Both types forwarded about 600k packets a second (1.2M in plus out)
  with zero allowance drops before one CPU ran out. On the c7gn.large, both of the shared ENI's queue interrupts were
  pinned to the same CPU, so its second CPU barely helped.
- **Past that point the pair flaps.** A CPU-saturated owner can't resolve DNS, renew its lease or probe its path, so
  it steps down. The standby takes over, saturates and hands back. This happened in every unlimited UDP run on both
  types.
- **Bandwidth is a burst that ends in a cliff.** A c7gn.medium forwarded 8.4 Gbps for 11 to 14 minutes, then dropped
  to 3.06 Gbps within one second. A c7gn.large forwarded 9.6 Gbps for 42 minutes, then dropped to 6.18 Gbps. Only
  `bw_out_allowance_exceeded` moved. Both ENIs count drops: the owner's own ENI, which carries ACKs back to workers,
  lost about 40% of them.
- **No packet-rate allowance drops at all.** 10 minutes at 842k packets a second in plus out on a c7gn.medium, 1.2M
  for 30 s, and 900k for 60 s through the internet gateway never moved `pps_allowance_exceeded`. Production dropped
  at about 360k. See [Open questions](#open-questions).

## Limits per instance type

Medians, with the range in parentheses where a measurement ran 3 times. "One run" marks single runs.

| | c7gn.medium (1 vCPU) | c7gn.large (2 vCPU) |
| --- | --- | --- |
| AWS baseline and burst bandwidth | 3.125 and 25 Gbps | 6.25 and 30 Gbps |
| Most packets forwarded, 64-byte UDP | 594k/s (1.19M in plus out) at 100% CPU, one run | 600k to 660k/s with one CPU full (16 and 64 flows) |
| What gave out first | the CPU | one CPU: both of the shared ENI's IRQs on it |
| `pps_allowance_exceeded` | never moved: 842k in plus out for 10 min, 1.19M for 30 s | never moved: 1.2M in plus out for 30 s; 900k through the internet gateway for 60 s |
| Bandwidth within the burst, uploads | 8.35 Gbps each way at 77% CPU (one run); 4.685 Gbps out at 4.5 Gbps offered (all 3 runs) | 9.6 Gbps with one CPU full; 14.7 Gbps once the IRQs were spread |
| Bandwidth within the burst, downloads | 4.685 Gbps out of the own ENI at 4.5 Gbps offered (all 3 runs) | not measured |
| Bandwidth after the burst, out | 3.04 to 3.12 Gbps a second, one run | 6.11 to 6.25 Gbps a second, one run |
| Burst before the fall | 855 s at 8.35 Gbps, partly refilled; one run | 2,521 s at 9.6 Gbps, fresh; one run |
| Counter that moves | `bw_out_allowance_exceeded` on both ENIs | the same |
| UDP 450k/s up (one ENI in and out) | 0.79 cores (0.78 to 0.80), no drops | |
| UDP 450k/s down (in on the shared ENI, out on the own) | 0.68 cores (0.68 to 0.70), no drops | |

Uploads enter and leave through the shared ENI. Downloads enter through the shared ENI and leave through the owner's
own ENI, as natpair's routing rules send only worker-sourced traffic through the shared ENI's table. During uploads
the own ENI carries the ACKs back to workers, 19k to 103k packets a second, and AWS drops those too once the burst is
spent. The large's limits job was cut short to make room for its 1 ms drop-phase run, so it has no download numbers.

## Counter refresh

The question is how fast a pacer can see AWS start dropping. enapoll reads the counters with the same ioctl as
`ethtool -S` (`SIOCETHTOOL` with `ETHTOOL_GSTATS`), which asks the ENA device for its statistics on each call, and
records the time of every read.

| Test | Poll | Runs | Counter changed every | Last change after load stopped |
| --- | --- | --- | --- | --- |
| Link-local flood, c7gn.medium standby | 10 ms | 3 | 10.33 ms median (each sample) | 0.1 to 8.1 ms median, 9.7 ms max |
| Link-local flood, c7gn.medium standby | 1 ms | 3 | 1.30 ms median (each sample, 1.27 ms apart) | 0 ms median, 0.7 ms max |
| Link-local flood, c7gn.large standby | 1 ms | 3 | 1.065 ms median (each sample) | 0 ms median, 0.5 ms max |
| Bandwidth drop phase, c7gn.medium owner | 10 ms | 1 (12,786 changes) | 9.97 ms median (each sample), p90 10.8 ms | 0 ms median, 50 ms max over 4 stops |
| Bandwidth drop phase, c7gn.large owner | 10 ms | 1 (3,684 changes) | 21.5 ms median, p10 9.6, p90 24.4 ms | 0 ms |
| Bandwidth drop phase, c7gn.large owner | 1 ms | 1 (40 s, 37,805 changes per ENI) | 1.04 ms median (each sample), max 4.8 ms | not measured |

- **Refresh rate: at least every 1 ms**, for both the link-local and the bandwidth counters, on both types. Every 1 ms
  sample saw a new value whenever AWS was dropping. The 21.5 ms gaps in the large's 10 ms run were moments with no
  drop, not stale reads: the 1 ms sample a few minutes later, with the same traffic, changed at every read.
- **Staleness: under one sample.** When the load stopped, the counter stopped moving within the next sample.
- **Bursts before drops.** Link-local drops started 519 ms into each 3,000-a-second flood (518.6 to 528.1 ms over 36
  bursts), the 1,024-a-second limit with about a 1,000-packet bucket. The bandwidth allowance has no such short
  bucket after the burst is spent: drops start in the same second the rate passes the baseline.

Cost of one read:

| Where | Median | p90 | p99 | Max |
| --- | --- | --- | --- | --- |
| ioctl, idle c7gn.medium owner, per ENI (2,000 reads) | 256 to 270 µs | 389 to 402 µs | 504 to 579 µs | 946 µs |
| ioctl, idle c7gn.large owner, per ENI (2,000 reads) | 206 µs | 219 to 220 µs | 251 to 262 µs | 685 µs |
| ioctl, c7gn.medium owner at 77% CPU, 10 ms polling | 443 µs | 1.7 ms | | 62 ms |
| ioctl, c7gn.large owner in drop phase, 1 ms polling | 230 to 241 µs | 344 to 357 µs | | |
| `ethtool -S` as a process, idle owner | 986 to 1,010 µs | | | |

The read waits on the device, so it costs less CPU than its latency. enapoll's own process CPU, reading one ENI, was
0.5% of a vCPU at 10 ms and 3.3% at 1 ms (about 40 µs of CPU a read). Counting the kernel's share too, idle runs on a
c7gn.medium used 3.4 points more of its single vCPU polling both ENIs every 10 ms than every second (one run each).

## CPU per packet

Owner CPU at fixed offered rates, below every limit, 30 s each, 3 rounds. Busy is the share of all CPUs not idle,
in cores. Per packet divides it by forwarded packets, and covers everything the NAT does in that time, including
softirq, natpair, conntrackd and the sampler polling once a second.

| Offered | Forwarded pps | c7gn.medium busy cores | per packet | c7gn.large busy cores | per packet |
| --- | --- | --- | --- | --- | --- |
| TCP, 0.5 Gbps | 45k | 0.066 (0.066 to 0.071) | 1,459 ns (1,452 to 1,565) | 0.084 (0.080 to 0.088) | 1,861 ns (1,765 to 1,942) |
| TCP, 1 Gbps | 90k | 0.107 (0.105 to 0.109) | 1,182 ns (1,159 to 1,202) | 0.105 (0.097 to 0.115) | 1,169 ns (1,071 to 1,276) |
| TCP, 2 Gbps | 180k | 0.213 (0.201 to 0.218) | 1,170 ns (1,113 to 1,201) | 0.200 (0.199 to 0.207) | 1,108 ns (1,107 to 1,150) |
| TCP, 3 Gbps | 270k | 0.290 (0.286 to 0.323) | 1,073 ns (1,058 to 1,154) | 0.291 (0.272 to 0.300) | 1,081 ns (1,010 to 1,111) |
| UDP 64 bytes, 100k pps | 100k | 0.158 (0.126 to 0.177) | 1,580 ns (1,260 to 1,770) | 0.192 (0.105 to 0.204) | 1,920 ns (1,050 to 2,040) |
| UDP 64 bytes, 200k pps | 200k | 0.314 (0.227 to 0.316) | 1,570 ns (1,135 to 1,580) | 0.327 (0.302 to 0.351) | 1,635 ns (1,510 to 1,755) |
| UDP 64 bytes, 300k pps | 300k | 0.473 (0.465 to 0.536) | 1,578 ns (1,550 to 1,787) | 0.448 (0.403 to 0.456) | 1,493 ns (1,343 to 1,520) |

- About 1.1 µs per forwarded packet for full-size TCP and 1.5 to 1.6 µs for small UDP, the same on both types: on
  the large, one CPU did nearly all of it. So one CPU forwards about 600k small packets, or about 9 Gbps of
  full-size ones, a second.
- 84 to 95% of it is softirq. conntrackd used under 0.3% of a CPU and natpair about 1%, with 32 long-lived flows.
  At the medium's saturation point natpair itself rose to 21.5%, as its own requests timed out and retried.
- Production on 2026-11-10 showed conntrackd at up to 27% user CPU. That load comes from connection churn, which these
  runs don't have, and it comes out of the same single CPU.
- Idle, the large's two CPUs together used 0.033 cores with the sampler polling once a second and 0.046 cores with it
  polling every 10 ms (one run each). The medium used 0.025 and 0.059.

## Burst

Both types burst far above their baseline, then fall to it within one second. AWS drops what is over the baseline
and counts it only in `bw_out_allowance_exceeded`: inbound carried the same rate, and `bw_in_allowance_exceeded` never
moved. The drops land on both ENIs, so the allowance covers the whole instance: the owner's own ENI, which carries the ACKs
and replies back to workers, dropped a large share of them.

| | c7gn.medium | c7gn.large |
| --- | --- | --- |
| Baseline (AWS) | 3.125 Gbps | 6.25 Gbps |
| Burst rate tested | 8.35 Gbps (CPU 77%) | 9.6 Gbps (one CPU full) |
| Time to fall back | 855 s, from a partly refilled allowance | 2,521 s (42 min), from a fresh one |
| Spent before the fall | about 4.5 Tbit (855 s at 5.2 Gbps over baseline), at least 6 Tbit from full | about 8.6 Tbit (2,521 s at 3.4 Gbps over) |
| Rate after the fall, out of the shared ENI, per second | 3.04 to 3.12 Gbps | 6.11 to 6.25 Gbps |
| Drops after the fall, shared ENI | about 241k packets/s | about 500k packets/s |
| Drops after the fall, own ENI (ACKs) | 68k/s of 171k/s offered (40%) | 120k/s of 273k/s offered (44%) |
| `bw_in_allowance_exceeded` | 0 | 0 |

- The transition is a cliff: on the medium, 8.07 Gbps at 854 s, 4.54 Gbps at 855 s and 3.07 Gbps from 856 s on. On
  the large, 9.44 Gbps at 2,520 s, 8.27 Gbps at 2,521 s and 6.18 Gbps from 2,522 s on.
- Idle time refills the allowance. Right after the medium fell back, the next runs, after about 2 idle minutes,
  forwarded 4.7 Gbps for 60 s with no drops. So short tests ran inside a burst, and the drop phase only shows at the
  end of a long run.
- The first medium attempt ran about 1,650 s at 4.68 Gbps without falling back. Its NAT samples after 570 s were
  lost to a harness bug (fixed), so it only bounds the allowance from below.

## Pair health under overload

**CPU overload makes the pair flap.** Offered more 64-byte UDP packets than one CPU forwards, the owner's own
traffic starves: DNS lookups of the probe receiver time out, lease renewals to DynamoDB time out (`lease store
unreachable`), and its path probes fail. It steps down ("stepped down after corroborated path failure"), the standby
takes over, inherits the same overload and does the same.

| Unlimited UDP, 60 s runs | Runs | Takeovers per run | Other journal lines |
| --- | --- | --- | --- |
| c7gn.medium | 3 | 3 to 4 | `lease store unreachable` once per run, DNS and probe timeouts, conntrackd full resyncs |
| c7gn.large, 16 flows | 3 | 1 to 3 | DNS and probe timeouts (2 to 9 a run), conntrackd resyncs |
| c7gn.large, 64 flows, 800k pps or more offered, 30 s runs | 8 | 0 to 2, in 6 of 8 runs | the same |
| c7gn.large, 900k pps offered for 10 minutes | 1 | 7 | 15 to 17 DNS and probe timeouts per NAT, 35 conntrackd resyncs |

Each takeover pauses forwarding for 6 to 11 s (see the handover table below), so a pair offered more than its CPU forwards loses far more than the
excess. The first owner in production on 2026-11-10 sat at 0 to 6% idle, which is this regime.

**AWS dropping alone doesn't hurt the pair.** Through the medium's 120 s drop phase at 77% CPU (about 241k drops a
second) and the large's 72 s drop phase (about 500k a second), the owner logged no lease, probe or conntrackd warnings
and kept ownership. In the large's 42 minutes of burst before that, with one CPU at 100%, it logged 13 DNS and probe
timeouts in three clusters (at 428 s, 1,093 s and 1,856 s) but never stepped down.

**A handover while saturated works.** `natpair maintenance` on an owner forwarding TCP uploads offered at 8 Gbps
(c7gn.medium) or 14 Gbps (c7gn.large), 120 s into the load, 3 runs each with alternating owners. Medians, with the
range in parentheses:

| | c7gn.medium, owner at 8.3 Gbps, 77% CPU | c7gn.large, owner at 9.5 Gbps |
| --- | --- | --- |
| Ping gap (100 a second through the NAT) | 8.7 s (7.6 to 10.7) | 8.2 s (6.3 to 10.5) |
| Receiver gap, no data, including TCP backoff | 13.7 s (13.6 to 13.7) | 13.7 s (6.8 to 13.7) |
| Gap starts after the request | 1.15 s (0.9 to 1.2) | 0.78 s (0.77 to 0.79) |
| New owner's `lease store unreachable` lines | 7 (7 to 8) | 0 (0 to 2) |
| New owner's DNS and probe timeouts | 25 (22 to 25) | 1 (1 to 12) |
| conntrackd lost netlink events | 0 | 0 |
| Flapped back | never | never |

The new owner takes the full load at once, on top of the takeover work. On the single-CPU medium that cost it its
DynamoDB and DNS path for a few seconds every time. In these runs the old owner had not yet spent its burst, so the
handovers ran under heavy load, not during AWS drops.

## Open questions

- **Why production hit the packet-rate allowance at about 360k packets a second.** Over peering, a c7gn.medium
  forwarded 421k a second each way (842k in plus out) for 10 minutes, and a c7gn.large took 1.2M in plus out for
  30 s, without `pps_allowance_exceeded` moving. The one run through the internet gateway, the path production takes, carried 450k a second each way (900k in plus
out) from the shared Elastic IP for 60 s with no allowance counter moving on any host. Other differences from production remain untested: thousands
  of short connections instead of 32 long ones (conntrackd used under 1% of a CPU here, 27% in production), and a
  mix of packet sizes.
- **The c7gn.large's IRQ placement.** irqbalance put both of the shared ENI's queue interrupts on one CPU for most of
  the large's runs, and later spread them (ENA IRQs 59 and 60 on CPUs 1 and 0). With them on one CPU the large
  forwarded 9.6 Gbps with that CPU full. Spread, it forwarded 14.7 Gbps. natpair could pin queue n of the shared
  ENI to CPU n when it attaches the ENI. The ramp and CPU numbers for the large below mostly reflect one CPU.
- **TCP retransmits without drops.** TCP runs retransmitted about 1% of segments while no allowance counter moved on
  any host and the owner showed no softnet or ENA driver drops. Where these packets went is unknown.

## Method notes

- Each repeated measurement ran at least 3 times, except the burst and drop-phase runs (one each per type: each
  takes 15 to 45 minutes and spends the allowance it measures) and the packet-rate ramp (one run per step, repeated
  by the CPU job at three of its rates).
- Runs started on a shared clock over SSM. Steady rates leave out the first 3 s of load. Counters were sampled on both
  NATs, both generators and the receiver.
- The generators' own allowance counters never moved, and the receiver's neither, so the limits above are the NAT's.
- The NATs ran natpair v0.1.1 as released, from the module at `ref=v0.1.1`, with no Datadog agent. The bench added an
  IAM policy to the NATs' role so they could fetch enapoll and upload samples.
- On a first apply, the NATs' SSM agent registered before the module attached their policy and never came online.
  Replacing each NAT once fixed it (see the README). That is a natpair module issue worth a fix: attach the policy
  before the instances boot, or restart the agent from the boot script.
- Harness bugs found and fixed during the run, which cost some data: hosts reused a cached enapoll without the flush
  on stop, losing the tail of the first medium burst run; and the receiver waited until half a long run's duration
  before its source check.
