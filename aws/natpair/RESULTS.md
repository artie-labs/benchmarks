# natpair limits: phase 1 results

Measured 2026-11-11 on AWS in us-west-2 (zone us-west-2a) with natpair v0.1.1 on c7gn.medium, then c7gn.large NATs,
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

# Phase 2: pacing A/B

**Pacing (natpair#8) is parked** as of 2026-11-13. The next design gives natpair's own work priority over
forwarding instead (see [Phase 3](#phase-3-control-plane-priority)). These results stay as the record of what pacing
did.

Measured 2026-11-12 and 2026-11-13 on AWS in us-west-2 with natpair v0.1.99, built from the natpair branch
bench/v0.1.99, and the module from the same commit. NATs booted with `pacing = { enabled = true }` and no start
caps. Each run switched pacing with `natpair pacing-off` or `pacing-on` on both NATs first, alternating off and on
within each round, 3 rounds. irqbalance was off.

**Kernel.** Through 081f24b (2026-11-12) both NATs ran kernel 6.18.56. The 2026-11-13 deploy (5f72e81 and b43be20)
booted kernel 6.1.190 (`al2023-ami-2023.12.20261112.0-kernel-6.1-arm64`): the module's AMI filter
`al2023-ami-2023.*-kernel-*-arm64` with `most_recent` picks whichever kernel line AWS published last, and the 6.1
image came out after the 6.18 one. The module has no AMI input, so the bench couldn't pin it. Compare numbers across
that line with care. Within a day, off and on ran on the same NATs.

Six builds ran. Each fixed what the one before it showed (see [Bugs](#bugs-found-in-the-pacing-build)):

| Build | What it adds | Results |
| --- | --- | --- |
| 87179fc | pacing (natpair#8), interrupt spreading (natpair#10) | [results/p2-build-87179fc](results/p2-build-87179fc) |
| c2b3980 | fix A: the CPU cap cuts only when forwarded traffic fills the CPU, floor 250k pps per CPU | [results/p2-build-c2b3980](results/p2-build-c2b3980) |
| b9f46d9 | fix B: AWS caps cut only for drops forwarded traffic causes, floor 100k pps; conntrackd copies through each NAT's own ENI (natpair#11) | [results/p2-build-b9f46d9](results/p2-build-b9f46d9) |
| 081f24b | the NAT's own traffic skips conntrack, 90%-full warning, pacing follows interfaces by index (natpair#12) | [results/p2-build-081f24b](results/p2-build-081f24b) |
| 5f72e81 | tighter firewall for untracked traffic, worker map bounded at 65,536 | [results/p2-build-5f72e81](results/p2-build-5f72e81) |
| b43be20 | CPU cap starts uncapped, averages CPU over 300 ms, cuts above 80% busy, rises 10%/s below 70%, forgets past cuts. AWS caps start uncapped and re-probe 10 s after a cut. `cap_cuts` in the status | [results/p2-build-b43be20](results/p2-build-b43be20) |

## Scenarios

Each build folder has its run summaries and a `summary.json` with medians and ranges. This table covers the
2026-11-12 builds on c7gn.medium. [2026-11-13](#2026-11-13-5f72e81-and-b43be20) has the later builds and the
c7gn.large.

Medians of 3 runs per side, range in parentheses. "Takeovers" counts per run.

| Scenario | Build | Pacing off | Pacing on | Bar | Verdict |
| --- | --- | --- | --- | --- | --- |
| 1. Overhead, fixed rates (TCP 2 Gbps, UDP 200k pps) | 081f24b | 2.0 Gbps / 200k pps forwarded; 0.235 / 0.386 cores | same throughput; 0.307 / 0.508 cores (+31%) | under 5% loss | pass on throughput, costs about 0.35 µs more CPU a packet |
| 1. Overhead, as fast as it goes (TCP) | c2b3980 | 8.6 Gbps (8.5 to 9.5), 1 takeover | 3.25 Gbps (3.2 to 3.5), 0 takeovers | under 5% loss | fail: on the medium pacing's CPU cap holds near 300k pps; off is not stable either |
| 1. BPF run time per packet | b9f46d9 | | `natpair_mark` 29 to 34 ns, `natpair_pace` 122 to 132 ns | | recorded |
| 2. Fairness, 1 heavy and 4 light workers | c2b3980 | light 0.146 to 0.199 Gbps, RTT 3.4 ms (to 129 ms), 1 takeover | light 0.200 Gbps each, RTT 0.90 ms, ping p90 0.95 ms, 0 takeovers | | pass |
| 3. CPU overload, 88-byte TCP segments | 081f24b | 932k pps, 1 to 2 takeovers, 13 lease failures | 267k pps, 0 takeovers | zero takeovers | pass (also on c2b3980 and b9f46d9) |
| 4. Burst cliff | b9f46d9 | 6.2 Gbps until the burst ran out, then 3.1 Gbps with no counter moving | 2.9 to 3.2 Gbps throughout, 0 drops: the CPU cap stays under the baseline, so no burst is used | | inconclusive, see below |
| 5. Churn, 3,000 connections a second | 081f24b | 3,000/s, p99 1.9 ms, conntrackd 24% | 3,000/s, p99 1.9 ms, conntrackd 25% | | pass (failed on c2b3980, bug 2) |
| 5. Forced full copy at 3,000/s for 120 s | 081f24b | | copies leave ens5 unfragmented (15,206 in 3 s), nothing to 3780 on the shared ENI, `pps_allowance_exceeded` 0; table filled, 90% warning logged, 2 step-downs | no step-down | fail (bug 4 not fixed by 081f24b) |
| 6. Handover while saturated, pacing on | 081f24b | | ping gap 9.7 s (8.5 to 10.8), receiver gap 15.6 s, no connection lost, 1 takeover as requested | | pass; phase 1 receiver gap was 13.7 s |
| 6. `pacing-off` while saturated | 081f24b | | the CPU fills and the pair takes over (1 a run), as without pacing; `pacing-on` restarts from the configured caps | | expected |
| 7. Large: interrupt spreading | | | | | not run |

Notes:

- Scenario 4: in the b9f46d9 spend run, both directions fell from 6.25 to 3.1 Gbps at 1,372 s with no
  allowance counter moving on any host, and the generators' TCP slowed from 3.2 to 1.5 Gbps each. Phase 1's cliff
  was counted in `bw_out_allowance_exceeded`. If AWS can shape without counting, pacing can't see it.
- Pacing on the medium settles its CPU cap near 280k pps (about 3 Gbps of full-size packets) with the busiest CPU
  near 55%, so it never uses the burst allowance and gives up 60 to 70% of the unpaced peak. It does keep the pair
  from flapping, which pacing off doesn't at that peak.
- UDP at 500k pps (c2b3980) still flapped with pacing on: the CPU spends its time receiving before pacing drops.

## 2026-11-13: 5f72e81 and b43be20

A new deploy on kernel 6.1.190 (see the kernel note above). 5f72e81 ran the checks that don't depend on the CPU cap
on c7gn.medium. b43be20 then replaced both NATs (same v0.1.99 path, new sha256 8464525b…ad75) and ran the throughput
and overload scenarios on c7gn.medium. Pacing was parked before the c7gn.large runs, which ran with pacing off
([Phase 3](#phase-3-control-plane-priority)). Medians of 3 runs, range in parentheses, unless a
row says otherwise. The owner's CPU is the share of its busiest CPU in use. "ns per packet" divides the owner's busy
CPU by the packets it received on both ENIs. The bench now samples pacing's limits map once a second on each NAT
(`pacing_limits` in each summary), so the caps show over time, not only in the once-a-minute status line.

### 5f72e81 on c7gn.medium

| Check | Result | Bar | Verdict |
| --- | --- | --- | --- |
| Smoke | TCP off 8.73 Gbps at 100% CPU, on 4.49 Gbps. Fairness, churn and a pacing-off/on toggle ran clean | runs complete | pass |
| Churn, 3,000 connections a second, off and on | 3,000/s completed both ways, copies leave ens5 unfragmented, conntrackd 26 to 28% CPU. p99 latency 1.4 to 3.2 s in 5 of 6 runs from the second run on (max 9.4 s: SYN retries at 1, 3 and 7 s), against 1.6 to 1.9 ms in every run on 081f24b and kernel 6.18 | | pass on rate, latency regressed (bug 9) |
| Forced full copy at 3,000/s for 120 s | Table reached 262,133 of 262,144. 90% warning logged at 238,137 (`the connection table is nearly full`). No DNS or lease failures, but the path probes, which go out through the shared Elastic IP and so need a table entry, timed out: owner stepped down at 95 s, the new owner inherited a full copied table and stepped down 26 s later. 2 takeovers. Copies: 16,526 datagrams in 3 s on ens5, 0 fragments, 0 to 3780 on the shared ENI | no step-down, no own DNS or probe drops | fail (bug 4 remains for probes) |
| Takeover with pacing on, 2 Gbps, 3 rounds | The new owner logged `pacing interface ens6` 6.5 to 7 s after `ownership acquired`, no `eth0`, 0 `failed to read allowance counters` on either NAT. Ping gap 9.5 s (9.5 to 10.0), receiver gap 13.0 s | right interface, no counter errors | pass |
| ACK probes from the receiver | Every probe got a reset (nmap `unfiltered`, `reset ttl 127`): the shared address, NAT a and NAT b, ports 22, 8080 and 61500 (outside 32768-60999) and 40000 and 50000 (inside). On the owner, 87 packets hit `ACCEPT tcp dpts:32768:60999 flags:!SYN ctstate UNTRACKED` to its own address (the kernel resets them, no socket) and 11 hit `REJECT --reject-with tcp-reset` | resets inside the range, the same reset outside | pass: all ports answer alike, as intended |
| Handover while saturated, pacing on (TCP as fast as it goes) | Ping gap 10.8 s (10.2 to 10.9), receiver gap 14.35 s (14.2 to 14.4), exactly 1 takeover a run, 0 lease failures, 1 to 2 `shared Elastic IP not working yet` retries on the new owner | | pass |
| `pacing-off` for 20 s while saturated | 0 takeovers, longest ping gap 0.05 to 0.07 s, 5.5 Gbps | | pass (081f24b took over every run) |

Raw ACK-probe output: [c7gn.medium-p2-ext-probe.txt](results/p2-build-5f72e81/c7gn.medium-p2-ext-probe.txt). Resync
evidence: [c7gn.medium-p2-resync-diag.txt](results/p2-build-5f72e81/c7gn.medium-p2-resync-diag.txt).

### b43be20 on c7gn.medium

| Scenario | Pacing off | Pacing on | Bar | Verdict |
| --- | --- | --- | --- | --- |
| Highest stable unpaced rate, TCP uploads at 7, 8 and 9 Gbps offered, 60 s | stable at all three: 7.0 Gbps at 82% CPU, 7.98 at 91%, 8.70 (8.68 to 8.71) at 100%, 0 takeovers in 9 runs | 4.17 (3.99 to 4.41), 4.23 (4.22 to 4.26), and at 9 Gbps either 4.12 or 7.92 (2 of 3 runs) | | the bar for scenario 1 is 8.70 Gbps |
| 1. TCP as fast as 32 flows go | 8.69 Gbps (8.66 to 8.92), 100% CPU, 0 takeovers | 4.18 Gbps (4.07 to 4.64), 70% CPU, 0 takeovers | paced at least 90% of 8.70 (7.83 Gbps), 0 takeovers | fail: 48% |
| 1. UDP 64-byte at 500k pps | 488k pps forwarded at 95% CPU, 0 takeovers | 398k pps (383k to 412k), 1 to 2 takeovers in every run | | fail: pacing on flaps where off doesn't (bug 7) |
| 1b. Overhead at fixed rates, TCP 2 Gbps | 2.0 Gbps, 1,374 ns per packet, 25% CPU | 2.0 Gbps, 1,778 ns (+29%), 33% CPU | under 5% throughput loss | pass on throughput |
| 1b. UDP 200k pps | 200k, 2,295 ns, 46% CPU | 200k, 2,525 ns (+10%), 51% CPU | under 5% throughput loss | pass |
| 3. CPU overload, 88-byte TCP segments, 64 flows | 881k pps at 100% CPU, 0 takeovers | 447k pps at 71% CPU, 0 takeovers | 0 takeovers | pass (off also had none on this kernel) |
| 4. Burst: does pacing use it, and what happens at the cliff (one spend run, then 2 idle minutes and 240 s at 8 Gbps, 3 runs before the stop) | cliff runs: 8.38 Gbps, then the cliff to 3.08 Gbps inside the 240 s, about 243k `bw_out` drops a second after it | spend run: the CPU cap gave up 4 times, so it forwarded 8.3 Gbps, then 6.7 Gbps under a 632 kpps cap left over from the last give-up, for 907 s until the burst ran out. At the cliff the allowance cap cut once, to 4.88 Gbps, and gave up 59 ms later. AWS then dropped about 247k packets a second at 3.1 Gbps, unpaced. Cliff run: 4.44 Gbps under the CPU cap, still inside the refilled burst, 0 drops | | fail: pacing uses the burst only when its CPU cap gives up, and doesn't follow the cliff (bug 12) |

- **The CPU cap holds the medium near 400k pps at about 70% busy, half the unpaced rate.** It cuts whenever the
  300 ms average passes 80% and climbs back 10% a second below 70%, so the limits map swings between about 250k and
  480k pps (median 390k to 420k) and never settles near the 80% it cuts at. With pacing on, each forwarded packet
  costs about 550 ns more CPU at this load (1,776 to 1,814 ns against 1,225 to 1,244), so 70% busy is about 400k
  pps. `cap_cuts` stayed 0: it counts allowance cuts only, not CPU cuts.
- **Sometimes it gives up instead.** If the CPU stays full for one 300 ms window after the first cut, it logs `a CPU
  stayed full after pacing forwarded less, so pacing restored the packet cap and stopped cutting it` and runs uncapped
  until the CPU drops below 80%. Under steady overload that never happens, so pacing stays off in effect: 7.92 Gbps
  at 100% CPU in 2 of 3 runs at 9 Gbps offered, and in the UDP runs, where the full CPU then flapped the pair.
- **AWS caps:** no allowance counter moved in scenarios 1 to 3, so only the burst run shows the allowance cap.

### Where pacing's CPU goes (b43be20, c7gn.medium)

TCP uploads at a fixed rate, 45 s, 3 rounds, four setups on the owner's two ENIs: pacing off (the default fq_codel),
pacing's fq root qdisc only, fq plus pacing's own mark and pace programs attached as natpair attaches them but with a
limits value of no caps that never expires, and full pacing. The third setup pins a second reference to the programs
natpair loaded, turns pacing off, and attaches them by hand
([jobs/p2-overhead-parts.sh](jobs/p2-overhead-parts.sh)). 8 Gbps is the highest rate the unpaced medium forwards
stably with CPU to spare. At 9 Gbps its CPU is full, where CPU per packet can't be compared.

| Setup | 4 Gbps: ns per packet | busiest CPU | 8 Gbps: ns per packet | busiest CPU | forwarded at 8 Gbps |
| --- | --- | --- | --- | --- | --- |
| off (fq_codel) | 1,245 (1,225 to 1,264) | 46% | 1,196 (1,190 to 1,213) | 90% | 748k pps, 7.99 Gbps |
| fq qdisc only | 1,308 (1,245 to 1,344) | 49% | 1,202 (1,197 to 1,202) | 89% | 742k, 7.99 |
| fq + BPF programs, no caps | 1,304 (1,294 to 1,317) | 48% | 1,252 (1,221 to 1,282) | 93% | 743k, 7.99 |
| full pacing | 1,466 (1,386 to 1,567) | 53% | 1,635 (1,352 to 1,727) | 72% | 440k (414k to 732k), 4.69 (4.45 to 7.88) |

- The qdisc and the programs together cost 0 to 60 ns a packet. The programs measure 31 to 33 ns (`natpair_mark`)
  and 105 to 125 ns (`natpair_pace`) a run, partly on the packets' existing path.
- The rest comes with pacing actually running. The daemon uses 4 to 6.5% of the CPU instead of 1 to 2% (about
  100 ns a packet at 400k pps). When the cap binds (8 Gbps), softirq time per packet rises from 1,116 to 1,351 ns
  as fq holds packets (8M packets waited a run) and TCP backs off. At 4 Gbps, where the cap bound only in round 1,
  full pacing cost 1,386 to 1,466 ns in the rounds with no waiting packets.
- One 8 Gbps run gave up cutting (7.88 Gbps, 99% CPU), the same bimodal outcome as above.

The c7gn.large pacing runs (scenario 7) did not run: pacing was parked first. The large's unpaced baselines are in
[Phase 3](#phase-3-control-plane-priority).

## Bugs found in the pacing build

1. **The CPU cap spiraled down (87179fc, fixed in c2b3980).** Under TCP overload the NAT's CPU stayed busy
   receiving packets that pacing then held or dropped, while the cap was cut to 80%, then 50%, of the falling
   forwarded rate: 400 → 320 → 296 → 144 kpps in 6 s, then 19.5 kpps at `busiest_cpu` 1 with 24 kpps forwarded.
   The low cap also survived `pacing-off` and `pacing-on` (`"pacing on","cpu_cap_kpps":18.65`). Uploads fell to
   0.17 Gbps and UDP forwarding to 9.8k pps. Logs: `.runs/20261112T0[23]*-c7gn.medium-p2-*/<owner>/journal.txt`,
   kept locally and in [results/p2-build-87179fc](results/p2-build-87179fc).
2. **Drops from the NAT's own traffic cut the worker cap to its floor (c2b3980, fixed in b9f46d9).** Under
   connection churn, conntrackd's copies tripped `pps_allowance_exceeded` (113,728 in one 10 ms poll). Pacing cut
   the worker packet cap to its 10 kpps floor and kept it there (`cap_kpps` 10, `worker_share_kpps` 4.85, 0.8 to
   1M packets dropped by pacing a minute). At 3,000 connections a second, workers completed 353 a second (309 to
   3,000) instead of 3,000. Runs `20261112T062049Z` and `062816Z` `c7gn.medium-p2-s5-churn3000-on`.
3. **conntrackd's copies left through the shared ENI as IP fragments (all builds before b9f46d9, and v0.1.1).**
   conntrackd's sending socket is bound to 0.0.0.0, and the route to the peer went `dev ens6 src 10.40.0.99`, the
   shared ENI, whose MTU is 1500 (the own ENI's is 9001). Its 8.9 KB datagrams left as fragments from the shared
   address. After a full copy request (`copied connections are incomplete`), the shared ENI sent 125k to 134k
   packets a second while receiving 34k to 47k, and `pps_allowance_exceeded` rose 85k to 98k a second, about the
   excess. Only 4 resets and 5 INVALID rejects showed in the same window. This is the likely cause of production's
   `pps_allowance_exceeded` at about 360k packets a second. Evidence:
   [diag](results/p2-build-c2b3980), `c7gn.medium-p2-diag2-churn-2-diag.txt`. b9f46d9 adds a host route to the
   peer through the own ENI: copies now leave ens5 with no fragments (12,263 datagrams in 3 s, 16,373 during a
   forced full copy), the shared ENI sends nothing to port 3780, and the counter stays at zero
   ([resync check](results/c7gn.medium-p2-resync-diag.txt)).
4. **A full connection table drops the NAT's own traffic (b9f46d9 and earlier).** At 3,000 connections a second,
   TIME_WAIT entries (120 s) fill the 262,144-entry table after about 90 s. The kernel then drops the owner's DNS
   lookups and probes too (`nf_conntrack: table full`), and it steps down: 2 takeovers in the 120 s resync run, 1
   per run at 15,000 a second. The NAT's own traffic could skip conntrack, or the table could be larger or the
   TIME_WAIT timeout shorter.
5. **Minor: a new owner paces `eth0` before udev renames the shared ENI.** It logs `pacing interface eth0`, about
   25 `failed to read allowance counters ... no such device` lines, then paces ens6 0.27 s later.
6. **Path probes still need a connection table entry (5f72e81).** 081f24b and 5f72e81 take the NAT's own DNS,
   lease and AWS API traffic out of conntrack, and in the 120 s forced-copy run none of it failed. But the path
   probes leave through the shared Elastic IP from 198.18.0.6, translated like worker traffic, so a full table
   drops them, and the owner steps down. The new owner inherits the same full table from the copy and steps down
   too:

   ```
   02:14:34 owner   WARN the connection table is nearly full ... "connections":238137,"max_connections":262144
   02:14:46 owner   health round "healthy":false, "probe_error":"failed to connect to probe receiver 44.238.153.130:443:
                    dial tcp4 198.18.0.6:0->44.238.153.130:443: i/o timeout", "tracked_connections":262133
   02:14:49 owner   ownership session ended "reason":"stepped down after corroborated path failure"
   02:15:15 standby ownership session ended "reason":"stepped down after corroborated path failure"
   ```

   With the table full, new worker connections fail too (42,364 dial timeouts in that run), so the probe is right
   that the path is broken. But the takeover doesn't help, because the peer's table is the same. Run
   `20261113T021248Z-c7gn.medium-p2-resync`.
7. **The CPU cap can give up and leave the CPU full (b43be20).** After a cut, if one 300 ms window still shows
   the CPU full, the cap goes back to uncapped and stops cutting until the CPU falls below 80%, which steady
   overload never allows. At 9 Gbps of TCP this happened in 2 of 3 runs (7.92 Gbps, 100% CPU). With 64-byte UDP at
   500k pps it happened in all 3 runs, and the full CPU then cost the owner its path probes: 1 to 2 takeovers a
   run, while pacing off forwarded 488k pps with none.

   ```
   03:44:33 WARN a CPU stayed full after pacing forwarded less, so pacing restored the packet cap and stopped
            cutting it "busiest_cpu":1,"forwarded_kpps":334.1
   03:45:23 WARN ownership session ended "reason":"stepped down after corroborated path failure"
   ```

8. **The CPU cap settles at half the unpaced rate (b43be20).** It cuts above 80% and rises below 70%, but pacing
   itself adds about 550 ns a packet when it binds, so the medium sits at about 400k pps and 70% busy: 4.2 Gbps
   where the unpaced pair forwards 8.7 Gbps without a takeover. See [Where pacing's CPU goes](#where-pacings-cpu-goes-b43be20-c7gnmedium).
9. **Churn latency regressed on the 2026-11-13 deploy (cause unknown).** At 3,000 connections a second, p99 rose to
   1.4 to 3.2 s (SYN retries) from the second run on, with pacing off and on alike, no conntrack drops, and the
   table at about 224k. Both the build (5f72e81) and the kernel (6.1.190) differ from 081f24b's clean runs, so this
   bench can't tell which.
10. **The module's AMI choice changes the kernel line.** `al2023-ami-2023.*-kernel-*-arm64` with `most_recent`
    picked kernel 6.1 on 2026-11-13 and 6.18 the day before. A NAT replaced on another day can boot a different
    kernel than its peer. An `ami_id` input or a pinned kernel line in the filter would fix it.
11. **Minor: pacing doesn't notice its qdisc and filters were removed.** A bench cleanup step deleted them on the
    owner while pacing was on. natpair kept reporting pacing on, and `natpair pacing-on` did nothing, until
    `pacing-off` and `pacing-on` re-attached them.
12. **The allowance cap gives up at the burst cliff (b43be20).** When the medium's burst ran out at 6.7 Gbps, one
    cut to 80% (4.88 Gbps) could not get under the 3.1 Gbps baseline, so the next poll still saw drops, and the cap
    restored itself and stopped cutting. AWS then dropped about 247k packets a second for the rest of the run.

    ```
    05:19:52.119 WARN the instance exceeded its network allowance, so pacing cut its cap
                 "bw_out_allowance_exceeded":2509,"forwarded_mbps":6101.8,"cap_mbps":4881.4
    05:19:52.178 WARN AWS kept dropping after pacing forwarded less, so pacing restored its cap and stopped cutting
                 it "bw_out_allowance_exceeded":2895,"cap_mbps":0
    ```

    Run `20261113T050419Z-c7gn.medium-p2-s4b-spend-on`.

## What's left

- Pacing is parked, so its open items (bugs 7, 8 and 12, and the large's pacing runs) wait on a decision.
- Bugs 6, 9 and 10 don't depend on pacing.

# Phase 3: control-plane priority

The next natpair design gives natpair's own work (the daemon, conntrackd and the primary ENI's receive thread)
priority over the shared ENI's forwarding thread, with threaded NAPI, so a CPU-saturated owner keeps its lease, DNS
and probes. These are the baselines it has to beat: b43be20 with pacing off (`natpair pacing-off` on both NATs),
kernel 6.1.190, measured 2026-11-13. Runs: [results/p3-baseline-b43be20](results/p3-baseline-b43be20)
([jobs/p3-baseline.sh](jobs/p3-baseline.sh)) for the large, and the pacing-off sides of the b43be20 medium runs in
[results/p2-build-b43be20](results/p2-build-b43be20). Medians of 3 runs, range in parentheses.

| Load, pacing off | c7gn.medium | c7gn.large |
| --- | --- | --- |
| TCP uploads as fast as 32 flows go | 8.69 Gbps (8.66 to 8.92), CPU 100%, 0 takeovers in 3 runs | 17.96 Gbps (17.91 to 18.14), both CPUs 100%, 0 takeovers in 3 runs, ping through the NAT lost 3.6%, longest gap 0.06 s |
| TCP with 88-byte segments, 64 flows (90 s) | 881k pps forwarded, CPU 100%, 0 takeovers, 0 lease or DNS failures in 3 runs | 1.91M pps (1.90M to 1.92M), both CPUs 100%, 0 takeovers in 3 runs, ping lost 5.4%, longest gap 0.07 s |
| TCP at fixed 9 Gbps (60 s) | 8.70 Gbps at 100%, 0 takeovers in 3 runs | |
| UDP 64-byte at 500k pps | 488k pps at 95%, 0 takeovers in 3 runs | |

**Interrupt spreading (natpair#10) holds after takeovers.** On every new owner of 3 takeovers on the large, the
shared ENI's two queue interrupts went to different CPUs (`ens6-Tx-Rx-0` on CPU 0, `ens6-Tx-Rx-1` on CPU 1), as
did the primary ENI's, with irqbalance off. Each takeover at 2 Gbps cost a ping gap of 8.0 s (7.5 to 10.0) and a
receiver gap of 13.0 s, with 1 to 2 probe retries on the new owner.

**Spread interrupts nearly double the large's forwarding.** Unlimited TCP reached 17.96 Gbps with both CPUs full,
against 9.6 Gbps in phase 1 with both shared-ENI interrupts on one CPU and 14.7 Gbps once irqbalance had spread them.
That phase 1 run used 16 flows on kernel 6.18 and this one 32 flows on kernel 6.1, so part of the gain may be the
setup. It is far inside the large's 30 Gbps burst, and no allowance counter moved.

**No flapping in this baseline.** Saturated for 60 to 90 s, neither type lost a lease, a DNS lookup or a probe, and
no run took over. That differs from phase 1 (v0.1.1, kernel 6.18), where every unlimited UDP run flapped, and from
081f24b on 6.18, where the same 88-byte overload took 1 to 2 takeovers a run with 13 lease failures. Since then the
NAT's own traffic left conntrack (081f24b, 5f72e81) and the kernel changed to 6.1, and this bench can't separate the
two. Small UDP above the CPU limit does still flap on kernel 6.1: see the bench/simple runs below.

## bench/simple and natpair#13 (2026-11-13)

Build 3438994 from natpair's bench/simple branch (natpair#9 to #12 merged, plus #13, no pacing; sha256
4c1b7152…cbd0, still tagged v0.1.99), module from the same commit, kernel 6.1.190 on every run. #13 gives natpair's
own work priority over forwarding: threaded NAPI on every interface, `natpair.slice` at CPUWeight=1000, and the
primary ENI's receive threads at nice -10. While `/var/lib/natpair/receive-threads-off` exists, threaded NAPI is
off, which is how the bench turns #13 off (`rx_switch` in [box/lib.sh](box/lib.sh)). Each summary records the
interfaces' `threaded` value and the receive threads' nice values. Runs: [results/p3-simple-3438994](results/p3-simple-3438994).
Medians of 3 runs, range in parentheses.

The module's AMI filter matched three kernel lines (6.1, 6.12, 6.18) with the same creation time, so the bench
pinned `kernel-6.1` in its local module checkout (bug 10). Starvation reproduced on 6.1, so the 6.18 repeat was
skipped.

| Step | Check | Result | Verdict |
| --- | --- | --- | --- |
| 1 | Starvation with #13 off, c7gn.large | UDP 64 B at 1.2M pps (both CPUs full): failed probes in every run (6 to 18 health rounds), 3 takeovers in 1 of 3 runs, 5 DNS or probe timeouts, ping loss 38.5% (1.9 to 61%). UDP 800k (84% CPU), 88 B TCP and full-size TCP (18.4 Gbps) at 100% CPU: 0 takeovers, 1 to 2 failed probes a run | reproduced |
| 1 | Starvation with #13 off, c7gn.medium | UDP 800k pps: 2 to 3 takeovers in every run, 17 to 22 failed probes, ping loss 64%. UDP 1.2M: 3 to 4 takeovers in every run, 13 to 21 DNS or probe timeouts, ping loss 85%. 88 B TCP (890k pps) and full-size TCP (8.74 Gbps) at 100% CPU: 0 takeovers, 1 failed probe a run | reproduced, strongly |
| 2 | Same cases with #13 on, c7gn.large | UDP 1.2M: 0 takeovers in 3 runs, but failed probes in every run (11 to 13 health rounds), ping loss 24.9% (19 to 28%). Other cases: 0 takeovers, 1 to 3 failed probes a run | partial: no takeovers in 3 runs, probes still fail |
| 2 | Same cases with #13 on, c7gn.medium | UDP 800k: 2 to 3 takeovers in every run, ping loss 67%. UDP 1.2M: 3 to 4 takeovers in every run, ping loss 87%. TCP cases: 0 takeovers, 2 to 4 failed probes a run | fail: no improvement |
| 3 | Cost below saturation, c7gn.large | TCP at 8 Gbps: 1,201 to 1,248 ns per packet (+4%). UDP 64 B at 400k pps: 2,020 to 2,100 ns (+4%). Most TCP: 18.65 Gbps (18.58 to 18.70) off, 18.02 (18.00 to 18.03) on (-3.4%) | small cost |
| 3 | Cost below saturation, c7gn.medium | Not run: the instances auto-stopped during a session outage before the job finished | not measured |
| 4 | 1M pps flood of the owner's own address, c7gn.large, while forwarding TCP at 10 Gbps | No flood: 9.97 Gbps off, 9.98 on. UDP flood: 7.75 Gbps (7.55 to 7.75) off, 4.17 (4.08 to 4.17) on. SYN flood: 8.02 (8.00 to 8.05) off, 5.06 (4.95 to 5.06) on. Off: 1 to 4 `lease store unreachable` a run. On: no lease failures, 2 to 5 failed probes. 0 takeovers either way | fail: with #13 on, a flood to the NAT's own address takes 37 to 46% more of forwarding |
| 4 | The same flood, c7gn.medium, while forwarding TCP at 4.5 Gbps | No flood: 4.48 Gbps both ways. UDP flood: 3.69 Gbps (3.62 to 4.05) off, 0.73 (0.73 to 0.77) on. SYN flood: 3.74 (3.12 to 4.46) off, 0.79 (0.75 to 0.79) on. Off: 1 to 9 `lease store unreachable` a run, and 1 takeover in each SYN run. On: 2 to 5 lease failures, 0 takeovers | fail: with #13 on, the flood cuts forwarding by 80% |
| 5 | 3,000 connections a second, 3 runs, c7gn.large | 3,000/s, 0 failures, p99 7.0 to 16.7 ms. The table held about 100k entries (TIME_WAIT 30 s) | pass: bug 9's seconds-long p99 is gone |
| 5 | Forced full copy at 3,000/s for 120 s | Table 97.5k of 262,144 before and 97.7k after the copy, 0 step-downs, p99 6.2 ms. The table never filled, so no `connection table is full` line to check | pass on step-down; the full-table alert was not reached |
| 5 | Takeover at 2 Gbps, 3 rounds | 1 takeover a run as requested, ping gap 9.8 s (8.2 to 9.9), receiver gap 13.0 s | pass |
| 5 | SYN and ACK probes from the receiver to the shared address and both own addresses, ports 22, 8080, 61500 and 40000, 50000 | SYN: no response from any address or port. ACK: no response from the own addresses, a reset from the shared address on every port | pass, as expected |

- **On the single-CPU medium, #13 changed nothing.** It was active (`threaded` 1 on both ENIs, the primary ENI's
  receive thread at nice -10), and the pair flapped 2 to 4 times a run under small UDP either way. The step-downs
  come from the path probe, which leaves through the shared Elastic IP like worker traffic and so sits in the same
  saturated queue. Lease and DNS traffic does get through with #13, but the probe correctly reports that the
  forwarding path is failing:

  ```
  18:30:00 owner   health round "healthy":false, "probe_error":"failed to connect to probe receiver ..."
  18:30:02 owner   ownership session ended "reason":"stepped down after corroborated path failure"
  18:30:20 standby ownership session ended "reason":"stepped down after corroborated path failure"
  ```

- **What #13 bought.** At the load that starved the owner (1.2M pps of small UDP on the large), #13 kept every run
  free of takeovers where off had a 3-takeover run, and ping loss through the NAT fell from 38.5% to 25% (medians). But the owner still failed
  probes in every run: the probes go out through the shared Elastic IP, translated like worker traffic, so they wait
  behind the same forwarding queue #13 deprioritizes. One flapping run in three is thin evidence either way.
- **What #13 costs.** About 4% CPU per packet below saturation and 3% of the large's top TCP rate.
- **The risk is real.** A flood to the owner's own address now outranks forwarding: at 1M pps it cut forwarding to
  4.2 to 5.1 Gbps with #13 on, against 7.8 to 8.0 Gbps off, on the large, and to 0.7 to 0.8 Gbps against 3.7 Gbps
  on the medium. With #13 off the same flood starved the lease instead
  (1 to 9 `lease store unreachable` a run), which #13 fixed on the large and reduced on the medium (2 to 5). Only sources inside the VPC or a peered network reach the
  own address: the bench flooded from the peered receiver. SYN and ACK probes got no answer from the own addresses,
  but the flood still costs CPU before the firewall drops it.

### Recommendation on #13: drop it

- On the medium, where starvation reproduced every run, #13 made no difference: 2 to 4 takeovers a run either way.
- On the large, it removed the one flapping run of three at 1.2M pps, but probes still failed in every run.
- It costs about 4% CPU per packet and 3% of top throughput.
- It lets anyone who can reach the owner's own address take forwarding capacity: 37 to 46% on the large and 80% on
  the medium at 1M pps.
- The flaps come from the path probe, which shares the forwarding queue by design. Raising the control plane's
  priority can't fix that. Worth trying instead: corroborating a probe failure against the forwarding rate, so a
  saturated but working owner doesn't step down to a peer that will saturate the same way.

# Release candidate (2026-11-14)

Build 671d06f from natpair's bench/release branch: master faaac9a plus natpair#9 (b52453a), #10 (a31cd73), #11
(05bd6f9), #12 (69485d3) and #14 (f68fd49), without #8 (pacing) or #13 (control-plane priority). Tagged v0.1.99,
tarball sha256 6e907cec5479281f65eb7d9eb736c2a1d1d1e279dba6109823ffc606316957fc, binary 071590de. Module from the same
commit, so the NATs boot #14's default kernel line: 6.18.62-127.179 on both. c7gn.large NATs, irqbalance off. Jobs:
[rc-validate](jobs/rc-validate.sh), [rc-udp](jobs/rc-udp.sh). Runs: [results/rc-671d06f](results/rc-671d06f). Medians
of 3 runs, range in parentheses.

| Check | Result | Verdict |
| --- | --- | --- |
| Smoke, kernel | Both NATs 6.18.62, v0.1.99, binary 071590de. 20 s of TCP: 19.27 Gbps. 20 s of churn: 3,000/s, p99 1.9 ms | pass |
| Interrupt spreading after 3 handovers | Each new owner had `ens6-Tx-Rx-0` on CPU 0 and `ens6-Tx-Rx-1` on CPU 1, the primary ENI's the same, irqbalance inactive | pass |
| TCP as fast as 32 flows go (60 s) | 18.94 Gbps (18.93 to 18.97), both CPUs full, against 17.96 on 6.1 in phase 3. 0 takeovers. But 8 (7 to 10) `lease store unreachable` and 28 (28 to 30) DNS or probe timeouts a run | takeovers pass, lease and DNS fail |
| TCP with 88-byte segments, 64 flows (90 s) | 2.10M pps, 0 takeovers. 11 (11 to 14) lease failures and 40 (35 to 41) DNS or probe timeouts a run | takeovers pass, lease and DNS fail |
| UDP 64 B at 800k pps (60 s) | 800k forwarded, 0 takeovers, no lease, DNS or probe failures, ping loss 0.12% | pass |
| UDP 64 B at 1.2M pps (60 s) | 3 takeovers (2 to 3) in every run, ping loss 70.5% (38.6 to 73.2), longest ping gap 13.1 s (5.5 to 16.3) | fail: worse than 6.1, where 1 run of 3 flapped (phase 3) |
| 3,000 connections a second, 3 consecutive 60 s runs | 3,000/s, 0 failures, p99 1.98 ms (1.96 to 2.02), table about 100k | pass |
| 120 s churn with a forced full copy 60 s in | Table 97.9k before, 99.6k after, p99 1.99 ms, 0 step-downs | pass |
| SYN probes from the receiver to the shared and both own addresses, ports 22, 8080, 40000, 50000, 61000, 61500, 62000, 65000, 3 rounds | No answer anywhere | pass |
| ACK probes, same addresses and ports | Own addresses: no answer. Shared address: a reset on 8080, 40000 and 50000 only, no answer on 22 and 61000 to 65000 | pass |
| 200 ACKs at 2,000/s to the shared address's port 40000 from one source, then 50/s for 10 s, 3 rounds | 51 resets in the burst, then 14 in the first second and 10 a second after (0.5 s of refill before the tail) | pass |
| Planned handover at 2 Gbps (`natpair maintenance`, then `natpair resume`), 3 rounds | 1 takeover each, ping gap 8.7 s (6.1 to 9.9), receiver gap 13.0 s (6.0 to 13.0), no lease failures | pass |

**Kernel 6.18 starves the NAT's own traffic at full CPU.** With both CPUs full of TCP, the owner's lease renewals time
out (`DynamoDB: PutItem ... context deadline exceeded`) and its DNS lookups fail (`lookup ...lambda-url...: i/o
timeout`). It never stepped down, because the lease survives a few missed renewals. The natpair daemon used 26 to 30%
of a CPU, almost all system time, against 1.2% with the same features on 6.1, and enapoll on the owner missed 18 to
23 s of each run's samples (0.06 s on 6.1). The kernel seems to charge forwarding work to the daemon's own system calls, and user space starves.

The same build on 6.1 shows the kernel is the cause. With the fix build below (which changes only what a timed-out
probe does), kernel 6.1.190 via the module's `kernel` input, c7gn.large, [rc-kernel-ab](jobs/rc-kernel-ab.sh):

| Load, c7gn.large | 6.18.62 (release candidate) | 6.1.190 (fix build) |
| --- | --- | --- |
| TCP as fast as 32 flows go | 18.94 Gbps, 7 to 10 lease failures and 28 to 30 DNS or probe timeouts a run | 18.57 Gbps (18.41 to 18.62), 0 lease failures, 0 DNS timeouts, 0 to 1 failed probe |
| TCP with 88-byte segments | 1.19 Gbps, 11 to 14 lease failures and 35 to 41 DNS or probe timeouts | 1.11 Gbps, 0 lease failures, 0 DNS timeouts, 1 failed probe |

6.18 forwards 2 to 7% more, but at full CPU the pair can't renew its lease or resolve the probe receiver. A longer
overload would likely end in lease loss and a takeover, so #14's default of 6.18 needs a second look before release.

## natpair#15: a congested path keeps its owner (2026-11-14)

Build 7f4124b from natpair's bench/release-udp branch: bench/release plus natpair#15. When the owner's probe times out,
it tries 40 TCP handshakes with the probe receiver through the shared Elastic IP. If some complete and some don't,
the path is congested, and the round doesn't count toward stepping down. Tarball sha256
2220b753da60c1d9ec2fc750a3466d125ce545b0295910fad27844b44f2815db, binary 420c8fed, still tagged v0.1.99, kernel 6.18.62.
`analyze.py` counts `path_alive` (`the health probe failed, but the path is alive`), `congested_rounds` (health rounds
with `"congested":true`) and `path_check_failed`. Runs: [results/fix-7f4124b](results/fix-7f4124b).

| Load, 60 s, 3 runs | Release candidate, c7gn.large | #15, c7gn.large | #15, c7gn.medium |
| --- | --- | --- | --- |
| UDP 64 B at 800k pps | 0 takeovers, ping loss 0.12% | 0 takeovers, ping loss 0.07% (0 to 0.16) | 4 takeovers in every run, ping loss 77.1% (70.1 to 83.0), 213k pps forwarded. Phase 3 on 6.1 (#13 off): 2 to 3 takeovers a run |
| UDP 64 B at 1.2M pps | 3 takeovers (2 to 3) a run, ping loss 70.5%, longest gap 13.1 s, 288k pps forwarded | 0 takeovers in 3 runs, ping loss 40.7% (27.8 to 50.5), longest gap 0.19 s (0.17 to 0.23), 1.02M pps forwarded. `path is alive` once a run (it logs at most once a minute), 2 to 4 congested rounds, 0 to 11 lease failures | 3 to 4 takeovers in every run, ping loss 89.0% (87.5 to 89.8), 183k pps forwarded. Phase 3 on 6.1: 3 to 4 a run |

- **The handshakes reach the probe receiver.** In congested rounds on AWS, 1 to 37 of the 40 handshakes completed with
  the Lambda function URL's addresses on port 443 through the shared address (`"handshakes":33,"attempts":40`).
- **A dead path still fails over.** With TCP at 2 Gbps, the owner dropped everything it sent through the shared ENI
  outside the VPC from 03:54:25. Its rounds reported `"congested":false`, it stepped down at 03:54:31 (`stepped down
  after corroborated path failure`), and the standby owned the ENI at 03:54:37. Ping gap 12.4 s, 1 takeover.
  [jobs/fix-failover.sh](jobs/fix-failover.sh).
- **One handshake out of 40 keeps the owner.** Three of the large's congested rounds had `"handshakes":1`. That's right
  for a saturated owner, whose peer would saturate the same way. But a path that loses 97% of packets for another
  reason also counts as alive.
- **On the medium, #15 changes nothing, because the medium loses its lease.** Of the 23 ownership sessions that ended
  in the 6 runs, 20 ended on the lease (`lease lost: forwarding permission expired` 8 times, `another owner took the
  lease while the store was unavailable` 6, `takeover failed: failed to verify the shared Elastic IP: lease lost` 6)
  and 3 on a path failure. 21 health rounds reported 0 of 40 handshakes completed, which counts as a dead path, and
  only a few reported 39 or 40. The
  single vCPU on 6.18 is too saturated for the daemon to renew its lease or finish a handshake. Whether 6.1 helps the
  medium too wasn't measured.
- Harness bug (fixed): the fail-over job's timer that removes the blackhole rules failed, because systemd reads a `;`
  in a transient unit's command as a separator. The rules were removed by hand 3 minutes later, while that NAT was the
  standby.

# Kernel 6.18 and XDP (2026-11-14)

Build 7f4124b (bench/release-udp, natpair#15, sha256 2220b753…15db, binary 420c8fed), module from the same commit, on
a fresh deploy. All five instances registered with SSM on the first boot, so no NAT was replaced for the SSM quirk.
c7gn.large NATs on 6.18.62-127.179, then both replaced onto 6.1.190-237.442, then resized in place to c7gn.medium on
6.1. Jobs: [k-prof](jobs/k-prof.sh), [xdp-ena](jobs/xdp-ena.sh), [b-medium](jobs/b-medium.sh). Runs, profile and XDP
summaries: [results/k618-xdp-7f4124b](results/k618-xdp-7f4124b). Profiles come from [box/prof.sh](box/prof.sh) and
[scripts/prof-summary.py](scripts/prof-summary.py). Single runs unless a range is given.

## Why 6.18 starves the daemon

**The daemon does the NAT's forwarding.** Under full-rate TCP on 6.18, 96.7% of the daemon's perf samples are
forwarding softirq work (`net_rx_action`, `ena_io_poll`, the firewall, `ena_start_xmit`) run on the daemon's own
thread, and 3.6% are its own code. 94% of those samples entered softirq through `do_softirq` from
`__local_bh_enable_ip`: whenever the daemon's kernel code re-enabled bottom halves, the kernel ran the pending
receive work right there. Half of all its samples come from one place: `fpsimd_restore_current_state` on the return to
user mode after a system call. On arm64 that restore runs with bottom halves off, so every system call of a thread that
was switched out ends in up to 2 ms of forwarding. The rest come from socket locks in TCP send and receive
(`lock_sock_nested`, `release_sock`), the firewall's counters and the daemon's own transmits. enapoll and conntrackd
show the same pattern: 87% of their samples are forwarding, 81% entered through `__local_bh_enable_ip`.

| Full-rate TCP, 32 flows, c7gn.large, same build | 6.18.62 | 6.1.190 |
| --- | --- | --- |
| Unprofiled 60 s run | 20.1 Gbps on the shared ENI. Daemon 31.5% of a CPU (30.9% system). 11 `lease store unreachable`, 35 DNS or probe timeouts, enapoll missed 18.8 s | 19.1 Gbps. Daemon 1.3%. 0 lease failures, 0 DNS timeouts, enapoll missed 0.06 s |
| Profiled 90 s run | 7 lease failures, 28 DNS or probe timeouts, and 1 takeover: `lease lost: another owner took the lease while the store was unavailable` | 0 lease failures, 0 DNS timeouts, 2 failed probes |
| Share of all perf samples (2 CPUs, 20 s) | ksoftirqd 66.7%, daemon 15.2%, enapoll 10.8% | ksoftirqd 97.1%, daemon 0.4%, enapoll 1.5% |
| Daemon samples in forwarding softirq | 96.7% | 5.1% |
| ksoftirqd/0 and /1 running | 66% of each CPU | 94% of each CPU |
| Daemon threads, their run time and runqueue wait (summed) | 46 threads, 30% of a CPU running, 258% waiting | 8 threads, 1.2% running, 3.5% waiting |
| CPU pressure (`/proc/pressure/cpu` some avg10) | 94.5 | 8.9 |
| Daemon system calls in 20 s (perf trace) | 9,236. Average `close` 1.38 ms, `read` 0.45 ms, `clone` 11.4 ms | 13,096. Average `close` 0.002 ms, `read` 0.004 ms, `clone` 0.32 ms |
| Idle | Daemon 0.4% of a CPU, no softirq in its samples | |

**natpair isn't doing anything expensive.** Idle, the daemon uses 0.4% of a CPU. Its system calls are few and cheap on
6.1. In 3 s of strace on the 6.18 owner they were: HTTPS reads and writes to the lease store on port 443 (42 in 3 s),
DNS to the VPC resolver, one conntrack netlink socket (`NETLINK_NETFILTER`), and child processes: `sysctl -n
net.ipv4.ip_forward` twice a second (`keepForwardingEnabled`), and once a health round `conntrackd -s`, `-i` and
`-e`, `conntrack -S` and `sysctl` of the connection count. Over 20 s, perf trace counted mostly futex (1,521),
epoll_pwait (1,769), nanosleep (1,217), epoll_ctl (887), close (648), read (639), setsockopt (310), write (233) and 52
clones. On 6.18 the same calls take 100 to 700 times longer because each one absorbs forwarding, and the Go runtime
then starts more threads (46 against 8), each of which absorbs it too.

**It's a kernel behavior change.** Both kernels have the same relevant configuration: `PREEMPT_NONE`, HZ 100, and no
`IRQ_TIME_ACCOUNTING`. ENA is 2.17.4g on both. In 6.1, `do_softirq()` and the interrupt exit path skip pending
softirqs while ksoftirqd is runnable ("softirq: Let ksoftirqd do its job", 4cd13c21), so under sustained load
ksoftirqd does all the forwarding and the scheduler shares each CPU between it and the daemon. That's the 6.1 profile.
Upstream reverted it in 2023 (d15121be, "Revert 'softirq: Let ksoftirqd do its job'"), so on 6.18 any task that
re-enables bottom halves or takes an interrupt runs the forwarding inline. Without `IRQ_TIME_ACCOUNTING`, that time
counts as the task's own system time and scheduler runtime, which is why the daemon shows 30% system CPU, and why the
scheduler then also makes it wait behind ksoftirqd (258% runqueue wait across its threads).

**Threaded NAPI on the owner fixes it on 6.18.** With `echo 1 > /sys/class/net/ens*/threaded` on the owner for one
60 s run, receive processing moved into `napi/` threads the scheduler shares the CPU with, like ksoftirqd on 6.1:
19.6 Gbps on the shared ENI (-2.7% against the 20.1 Gbps baseline), daemon 0.9% of a CPU, 0 lease failures, 0 DNS
timeouts, 4 failed probes (1 congested round, path alive). Reading the ENA counters once a second instead of every
10 ms (enapoll's `POLL=1s`) only helped a little: 3 lease failures and 14 DNS or probe timeouts, daemon still 30.6%.
So the bench's 10 ms counter reads add to the starvation but don't cause it.

**The minimal natpair-side fix**, not made here: turn on threaded NAPI (`/sys/class/net/<interface>/threaded` = 1) for
the shared ENI, and the primary ENI, when natpair configures them, on every kernel. Only that part of #13: no nice
-10, no `CPUWeight`, which were what let a flood to the own address take forwarding capacity. The shared ENI's
setting must be applied again after each takeover, because the attached ENI is a new network device. One run is thin
evidence, so it needs the rc-validate and rc-udp checks on both kernel lines. The other option is #14's default kernel
going back to 6.1. Replacing the twice-a-second `sysctl` child with a read of `/proc/sys/net/ipv4/ip_forward` would
cut the daemon's exposure a little but doesn't fix it.

## natpair#15 on c7gn.medium, kernel 6.1

Same build, both NATs c7gn.medium (1 vCPU) on 6.1.190. Medians of 3 runs of 60 s, range in parentheses. The 6.18
column is the natpair#15 section above.

| Load | 6.1.190 | 6.18.62 (natpair#15 section) |
| --- | --- | --- |
| UDP 64 B at 800k pps | 1 takeover (0 to 1) a run, 525k pps forwarded (517k to 527k), 0 lease failures, 4 (0 to 7) DNS or probe timeouts, 22 (21 to 23) failed probes, ping loss 56.0% (54.8 to 60.2), longest gap 10.1 s (0.2 to 14.3). 1 to 2 `path is alive` lines, 7 to 12 congested rounds | 4 takeovers in every run, 213k pps forwarded, ping loss 77.1% |
| UDP 64 B at 1.2M pps | 1 takeover (1 to 2) a run, 524k pps forwarded (232k to 545k, the low run had 2 takeovers), 0 lease failures, 4 (2 to 7) DNS or probe timeouts, 28 (25 to 32) failed probes, ping loss 79.1% (76.0 to 81.8), longest gap 14.0 s (0.5 to 15.2). 1 to 2 `path is alive` lines, 11 to 19 congested rounds | 3 to 4 takeovers in every run, 183k pps forwarded, ping loss 89.0% |
| TCP as fast as 32 flows go | 8.71 Gbps received (8.60 to 8.74), 9.0 Gbps on the shared ENI, 0 takeovers, 0 lease failures, 0 DNS timeouts, 1 failed probe a run, ping loss 3.6% (3.5 to 4.5), longest gap 0.05 s | not run |

- **On 6.1 the medium never lost its lease.** All 6 ownership sessions that ended in the UDP runs ended `stepped down
  after corroborated path failure`, against 20 of 23 on the lease on 6.18. The daemon used 0.6 to 1.2% of the CPU
  (5.5 to 7.3% on 6.18), and the medium forwarded about 2.5 times as many small packets.
- **#15 kept the owner in about half of the failed rounds.** Of 142 health rounds with a failed probe, 72 were
  congested (1 to 34 of 40 handshakes completed) and didn't count. 61 had 0 of 40, which counts as a dead path, and
  those led to the 6 step-downs. 2 had 40 of 40 and 7 tried no handshakes. A single saturated vCPU still drops every
  handshake for seconds at a time, so the medium still flaps under small UDP above its CPU limit: 6 takeovers in 6 runs,
  against 23 on 6.18.

## ENA XDP limits

A minimal XDP program ([xdp/pass.c](xdp/pass.c), `XDP_PASS` only) and one that drops UDP from the receiver's VPC
([xdp/drop.c](xdp/drop.c)), attached natively (`ip link set dev ens5 xdpdrv obj ...`) to the standby's primary ENI,
never to the owner. ENA 2.17.4g, c7gn.large, 2 queues. [box/xdp.sh](box/xdp.sh) pinged the owner 100 times a
second throughout and the receiver flooded the standby's address with 64-byte UDP from random ports.
[scripts/xdp-summary.py](scripts/xdp-summary.py) has the arithmetic. The standby ended both runs with no program, MTU
9001 and 2 channels, checked after each job.

| Check | 6.18.62 | 6.1.190 |
| --- | --- | --- |
| Attach at the primary ENI's MTU 9001 | Refused: `the current MTU (9001) is larger than the maximum allowed MTU (3502) while xdp is on` | Same |
| MTU with a program attached | Up to 3502. The driver lowers `max_mtu` from 9216 to 3502 while one is attached. 3499 and 3498 attached | Same |
| Queues | 2 of 2 combined before, during and after. ENA needed no channel change | Same |
| Attach and detach | Each one restarts the interface (ENA's `interface_down` and `interface_up` rise by 1), and the command takes 10 to 44 ms. No ping reply gap over 40 ms at 100 a second and no lost replies, in 3 attaches and 3 detaches | Same, gaps up to 30 ms |
| 1M pps flood, dropped by the kernel's firewall | 72% of the 2 CPUs, 1,437 ns per packet | 72%, 1,452 ns |
| 2.07M pps offered, kernel drop | 1.43M pps received, both CPUs full, 1,403 ns per packet | 1.28M pps, both CPUs full, 1,561 ns |
| 1M pps flood, `XDP_DROP` | 6.6% of the 2 CPUs, 132 ns per packet | 7.6%, 152 ns |
| 2.07M pps offered, `XDP_DROP` | All 2.07M received and dropped, 9.0% busy, 87 ns per packet | 2.05M, 5.5% busy, 54 ns |

- **XDP drops a packet 10 to 25 times more cheaply** than the kernel's firewall path: 50 to 150 ns a packet against
  1,400 to 1,560 ns. The flood tool topped out at about 2.07M pps from one c7gn.xlarge, so XDP's own ceiling wasn't
  reached. At these costs two CPUs would drop well past 10M pps, beyond what AWS's packet allowance lets in. No
  allowance counter moved at 2.07M pps.
- **What natpair would have to accept.** The shared ENI's MTU of 1500 is fine. The primary ENI would have to drop from
  9001 to at most 3502, which changes conntrackd's copies to the peer: natpair routes them over the primary ENI because
  its 9001 MTU fits the 8.9 KB datagrams in one packet. Every attach or detach restarts the interface, so on the shared
  ENI it belongs before forwarding opens at a takeover, not on a serving owner. The restart cost no measurable ping gap
  here, but it was measured on an idle interface.

# Threaded NAPI on 6.18 (2026-11-14)

Build 707894d from natpair's bench/release-napi branch: bench/release-udp (7f4124b, natpair#15) plus natpair#16,
which writes 1 to `/sys/class/net/<interface>/threaded` for every ENI at start, right after the shared ENI comes up
during a takeover, and every 5 s. No nice values, CPU weights or slices. Tagged v0.1.99, tarball sha256
e77b7052c145c9ff84809e1fdb7de1991a35f97a83ca0301a62df1672d9e9a96, binary 06d2f17e. Module from the same commit,
fresh deploy, both NATs on 6.18.62-127.179. All five instances registered with SSM on the first boot. c7gn.large
first, then both NATs resized in place to c7gn.medium. Jobs: [napi-sat](jobs/napi-sat.sh),
[napi-flood](jobs/napi-flood.sh), [napi-cost](jobs/napi-cost.sh), [fix-failover](jobs/fix-failover.sh). Runs:
[results/napi-707894d](results/napi-707894d). Medians of 3 runs of 60 s, range in parentheses. Every summary's
`threaded` shows 1 on both ENIs except napi-cost's off runs.

The comparisons are the release candidate (671d06f, [Release candidate](#release-candidate-2026-11-14)) and natpair#15
(7f4124b, the base of this build, [natpair#15](#natpair15-a-congested-path-keeps-its-owner-2026-11-14)), both on
6.18.62, and for the medium also 7f4124b on 6.1.190 ([natpair#15 on c7gn.medium, kernel
6.1](#natpair15-on-c7gnmedium-kernel-61)). The RC's 88-byte runs lasted 90 s, these 60 s.

| Load | #16, c7gn.large | RC or #15, c7gn.large, 6.18 | #16, c7gn.medium | c7gn.medium references |
| --- | --- | --- | --- | --- |
| TCP as fast as 32 flows go | 18.17 Gbps (18.06 to 18.21), 0 takeovers, 0 lease failures, 0 DNS timeouts, 0 to 4 failed probes, daemon 1.0% of a CPU | RC: 18.94 Gbps, 0 takeovers, 7 to 10 lease failures, 28 to 30 DNS or probe timeouts, daemon 26 to 29% | 8.92 Gbps (8.86 to 8.98), 0 takeovers, 0 lease, 0 DNS, 1 to 3 failed probes, daemon 0.6% | 6.1: 8.71 Gbps, 0 lease, 0 DNS |
| TCP with 88-byte segments, 64 flows | 1.97M pps (1.96M to 1.99M), 0 takeovers, 0 lease, 0 DNS, 1 to 3 failed probes, daemon 0.9% | RC (90 s): 2.10M pps, 11 to 14 lease failures, 35 to 41 DNS or probe timeouts | 940k pps (930k to 943k), 0 takeovers, 0 lease, 0 DNS, 2 to 4 failed probes | Phase 3, 6.1: 881k pps |
| UDP 64 B at 800k pps | 795k forwarded, 0 takeovers, 0 lease, 0 DNS, 0 to 2 failed probes, ping loss 1.8% (1.6 to 2.0) | #15: 800k, 0 takeovers, ping loss 0.07% | Takeovers 1, 2, 0. 515k forwarded (71k to 517k), 0 lease, 0 to 7 DNS, 18 to 27 failed probes, ping loss 51.7% (26.8 to 63.0) | #15 on 6.18: 4 takeovers every run, 213k, 77.1%. 6.1: 0 to 1 a run, 525k, 56.0% |
| UDP 64 B at 1.2M pps | 965k forwarded (892k to 1.01M), 0 takeovers, 0 lease, 0 DNS, 1 to 14 failed probes, ping loss 24.6% (1.7 to 28.7), longest gap 0.18 s | #15: 1.02M, 0 takeovers, 0 to 11 lease failures, ping loss 40.7%. RC: 2 to 3 takeovers a run | Takeovers 2, 1, 0. 516k forwarded (213k to 536k), 0 lease, 0 to 19 DNS, 19 to 28 failed probes, ping loss 65.6% (27.0 to 84.0) | #15 on 6.18: 3 to 4 a run, 183k, 89.0%. 6.1: 1 to 2 a run, 524k, 79.1% |
| 1M pps flood of the owner's own address over the peering, TCP at 10 Gbps (large) or 4.5 Gbps (medium) | No flood 9.98 Gbps. UDP flood 8.36 (8.35 to 8.37), SYN flood 8.43 (8.34 to 8.72). 1 to 5 lease failures a run, 0 DNS, 0 takeovers | Phase 3, 6.1: UDP 7.75 off and 4.17 with #13, SYN 8.02 and 5.06. 1 to 4 lease failures off, 0 with #13 | No flood 4.48 Gbps. UDP 4.30 (4.15 to 4.32), SYN 4.39 (4.30 to 4.48). 5 to 12 lease failures a run, 1 takeover in 6 runs | Phase 3, 6.1: UDP 3.69 off and 0.73 with #13, SYN 3.74 and 0.79. 1 to 9 lease failures off |
| CPU per forwarded packet below saturation, threaded NAPI off then on, same NAT | TCP at 8 Gbps: 1,108 ns (1,098 to 1,115) off, 1,191 (1,172 to 1,223) on, +7.5%. UDP at 400k pps: 1,907 (1,835 to 2,160) off, 1,818 (1,802 to 2,217) on, within the noise | | TCP at 4 Gbps: 1,155 (1,146 to 1,165) off, 1,202 (1,191 to 1,211) on, +4.1%. UDP at 300k pps: 1,923 (1,922 to 1,940) off, 2,005 (1,987 to 2,009) on, +4.3% | Phase 3, 6.1, large, #13: +4% |

- **It fixes the 6.18 starvation.** In all 24 saturated runs, the owner never failed a lease renewal and, except under
  small UDP on the medium, never timed out a DNS lookup. The daemon used 0.6 to 1.7% of a CPU, against 26 to 31% on the
  RC. In the TCP runs enapoll on the owner missed no samples (the RC missed 18 to 26 s a run). The large took no takeover in 12 runs,
  where the RC took 2 to 3 in every 1.2M pps UDP run.
- **What it costs.** At full load the large forwards 4% less TCP (18.17 against 18.94 Gbps) and 6% fewer 88-byte
  packets. Below saturation each packet costs 4 to 7.5% more CPU, except UDP on the large, whose spread hid any change.
  That is close to #13's +4% on 6.1, so most of #13's cost was threaded NAPI itself, not its priority changes.
- **Measuring the cost on one build.** #16 has no off switch, so napi-cost's off runs wrote 0 to each ENI's `threaded`
  on the owner and bind-mounted a file holding 1 over it, so the daemon read 1 and wrote nothing. A second sysfs mount
  showed the real value, 0, which each summary records. Removing the mounts let the daemon turn it back on within 5 s.
  The owner didn't change during the job.
- **The medium still flaps under small UDP.** 6 takeovers in 6 runs, the same as 6.1 and far fewer than #15's 23 on
  6.18. All 6 ended sessions were path failures (5 `stepped down after corroborated path failure`, 1 `takeover failed:
  failed to verify the shared Elastic IP`), none a lost lease. The medium forwarded about 516k pps, as on 6.1, against
  183k to 213k for #15 on 6.18. So on one vCPU the remaining flaps come from the path probe sharing the saturated
  forwarding path, as phase 3 found on 6.1: the owner's probe and #15's handshakes fail for seconds at a time, and the
  standby saturates the same way when it takes over. Fixing that needs the owner to shed load before the probe's
  packets, such as an XDP overload guard on the shared ENI, or a probe that doesn't count local overload.
- **A flood of the own address no longer outranks forwarding.** Forwarding kept 84 to 87% of its rate on the large
  and 93 to 100% on the medium, better than 6.1 without #13 and far better than #13. But the owner still failed 1 to 5
  lease renewals a run on the large and 5 to 12 on the medium, and one medium run lost its lease (`another owner took
  the lease while the store was unavailable`). The daemon used under 1.3% of a CPU, so this isn't starvation: the
  lease replies arrive on the primary ENI with the flood. An XDP drop of traffic the host firewall would drop anyway,
  on the primary ENI, would protect them.
- **A dead path still fails over.** With TCP at 2 Gbps on the large, the owner dropped everything it sent through the
  shared ENI outside the VPC from 08:57:45. It stepped down at 08:57:49 (`stepped down after corroborated path
  failure`). The new owner turned on threaded NAPI for the shared ENI at 08:57:57 and opened forwarding at 08:58:00.
  Ping gap 15.9 s, 1 takeover, both rules removed afterwards.
- **The shared ENI gets threaded NAPI at every takeover.** Each new owner logged `turned on threaded receive
  processing` within a second of the ENI coming up, before `forwarding open`, and every summary showed 1 on both ENIs.

# XDP overload guard (2026-11-14)

natpair#17 adds an overload guard for the shared ENI. The final build is ccbc006 from natpair's bench/release-xdp
branch: bench/release-napi (707894d, natpair#16 on #15) plus natpair#17 at b973c97, tagged v0.1.99, tarball sha256
c005814f62d374678631fa9458723be37d8d212e4c61caa4b7b9723ba37ec1b6, binary 19fd8d4d. The guard changed during the bench
(see [Why it ended up like this](#why-it-ended-up-like-this)), so each row names the build it ran. After the bench, the branch
moved to 446ea59 (natpair#17 at e723adb, tarball sha256 26582d7050b2bcd95e8ae54c207d3a6482aa234b492b43a475c4c9ff7d5e6a98):
it also finds receive threads whose names a kernel cut at 15 characters (not the case for ens6) and installs ethtool,
which the AMI already has. Neither ran here. Module from the same
branch, fresh deploy at 10:45 UTC, both NATs c7gn.medium on 6.18.62-127.179, then resized in place to c7gn.large for the
sanity runs. All five instances registered with SSM on the first boot. Jobs: [xdp-sat](jobs/xdp-sat.sh) (`SIDES` and
`CASES` pick the side and loads), [xdp-flood](jobs/xdp-flood.sh), [fix-failover](jobs/fix-failover.sh),
[xdp-takeover](jobs/xdp-takeover.sh), [xdp-attached-cost](jobs/xdp-attached-cost.sh), and
[xdp-install](jobs/xdp-install.sh), which installs a new build on both NATs without replacing them. `run.sh` takes
`GUARD=on|off` (natpair's off switch, `/var/lib/natpair/overload-guard-off`), and each NAT now records its ENIs'
`rx_packets`, `rx_dropped`, `rx_over_errors` and XDP program at the start and end (`nic` in the summary). Runs:
[results/xdp-ccbc006](results/xdp-ccbc006). 3 runs of 60 s per cell unless noted, median and range.

**What the guard does in the final build.** The daemon watches the busiest CPU and the shared ENI's `rx_over_errors`
every 100 ms, with nothing attached. When the busiest CPU has been at least 95% busy for 300 ms and the NIC dropped at
least 5% of what reached the shared ENI in the last second, it raises the shared ENI's receive ring to its maximum
(2,048 on the medium, default 1,024), attaches the XDP program, measures for 200 ms and sets a per-CPU budget of 90% of
the busiest CPU's rate per 2^20 ns tick. While limiting, it runs the shared ENI's `napi/` receive threads at nice -10,
and while the CPU stays full and the NIC still drops 5%, it cuts the budget to 90% of itself once a second, down to half
the measured rate. Past the budget the program drops worker packets but passes non-IPv4 and up to 128 probe replies per
CPU per 16.8 ms. It detaches and restores the ring and nice values once it sheds under 5% and the NIC keeps up.

## c7gn.medium, guard on and off

The off side ran first (11:35 to 12:12) and is the same on every build: the off switch keeps nothing attached. The UDP
rows' on side ran on a5dd3ec (12:46 to 13:01), which is the final build without b973c97, so each of its runs also cut
the budget once more as the flood ended, at idle CPU. The TCP and flood rows' on side ran on 8ff1873, which lacks the
budget cut and the NIC-aware clear. Neither engaged, so the rest of the guard didn't run.

| Load | Guard off | Guard on |
| --- | --- | --- |
| UDP 64 B at 800k pps | Takeovers 0, 0, 2. 515k forwarded (476k to 515k). 23 to 28 failed probes a run. Ping loss 53.8% (52.4 to 57.6). NIC dropped 35.6% | Takeovers 0, 0, 0. 400k forwarded (398k to 429k). 0 failed probes. Ping loss 75.9% (62.9 to 77.4). NIC dropped 0.3%. Engaged once and cleared once a run, 0 or 1 budget cuts while the CPU was full |
| UDP 64 B at 1.2M pps | Takeovers 0, 0, 0. 516k forwarded (515k to 517k). 31 to 38 failed probes. Ping loss 73.7% (59.3 to 73.9). NIC dropped 57.0% | Takeovers 0, 0, 0. 363k forwarded (358k to 400k). 0 to 2 failed probes. Ping loss 86.6% (79.2 to 87.1). NIC dropped 1.2%. 1 or 2 budget cuts while the CPU was full |
| TCP as fast as 32 flows go | 8.91 Gbps (8.91 to 8.93). NIC dropped 2.0%. 1,206 ns a packet | 8.90 Gbps (8.89 to 9.02). Never engaged (NIC 2.0%, under the 5% line). 1,210 ns a packet |
| TCP with 88-byte segments, 64 flows | 0.524 Gbps, 859k pps. NIC 2.8%. 1,060 ns a packet | 0.521 Gbps, 856k pps. Never engaged. 1,064 ns a packet |
| 1M pps UDP flood of the owner's own address, TCP at 4.5 Gbps | 4.32 Gbps (4.26 to 4.36). 10 lease failures every run. 0 takeovers | 4.28 Gbps (4.10 to 4.32). 8 to 11 lease failures. 0 takeovers. Never engaged |

No run on either side failed a lease renewal except under the own-address flood, which the guard can't see (it arrives
on the primary ENI), and no guard-on run took a takeover. The daemon used 0.9 to 1.0% of the CPU with the guard on.

- **The guard keeps the owner's probe working, at the cost of forwarding.** Off, the owner failed 23 to 38 probes a run
  and still handed over twice in 6 UDP runs (#15 kept it in place for most failed rounds). On, it failed at most 2. It
  forwards 22% fewer packets at 800k and 30% fewer at 1.2M, and ping, which is worker traffic, loses more. That is the
  budget: it holds the CPU below full so the NIC stops dropping at random, and the probe's replies, which it exempts,
  get through.
- **TCP isn't affected.** Full-rate TCP fills the medium's CPU too, but its NIC drop share stays at 2.0 to 2.8%, so the
  guard never engaged, and nothing is attached while it watches.

## Why it ended up like this

Four builds ran before the final one. Each was installed on both NATs with xdp-install, the standby first.

- **The NIC counts ring overflow in `rx_over_errors`, not `rx_dropped`.** The first build (6e8b84d) read `rx_dropped`,
  which stayed at 0 while the medium received 515k of 800k pps, so it never engaged. ENA puts the overflow in
  `rx_over_errors` (12.4M after one run) and adds XDP drops to `rx_dropped`.
- **Shedding load alone didn't save the probe.** With the budget on (8d8792c), the medium's CPU sat at 86 to 87%, the
  NIC delivered 775k of 800k pps, and the owner still failed most probes and handed over. Plain TCP connects from the
  shared canary to the same receiver addresses succeeded 38 to 40 of 40 at the same moments, so the loss followed the
  daemon's own health rounds: they held the single CPU for longer than the 1,024-slot ring lasts at 800k pps (1.3 ms),
  and the NIC dropped the probe's replies. A live A/B on the engaged owner, natpair's probe errors per 30 s: 5 to 6 at
  the defaults, 1 with `napi/ens6-0` at nice -10, 0 at nice -10 with the 2,048-slot ring (ring overflow 93 a second,
  from 25,000).
- **The budget's own drops need a smaller budget at 1.2M.** With a fixed 90% budget (8ff1873), 1.2M pps still filled the
  CPU in 2 of 3 runs and the probe failed 24 and 29 times. The budget cut fixed it.
- **The clear rule.** "Busiest CPU below 80% for 1 s" took the budget off 2 s after it went on, because the budget kept
  the CPU near 80%. "The program drops under 5%" was fooled once at 100% CPU, when the budget was more than the CPU
  could pass and the NIC dropped the rest. The final rule needs both under 5%. A late `rx_over_errors` step after a
  flood also cut the budget once at idle CPU in a5dd3ec, which b973c97 stops.

## What attaching costs

With any XDP program on the shared ENI, ENA's receive path costs more, which is why the final build attaches only while
it sheds. [xdp-attached-cost](jobs/xdp-attached-cost.sh) attached [xdp/pass.c](xdp/pass.c) (`XDP_PASS` only) to the
owner's shared ENI, with natpair's guard off, during full-rate TCP, 2 runs: 7.80 Gbps (7.74 to 7.86) at 1,385 ns a
packet, against 8.91 Gbps at 1,206 ns with nothing attached (the off side above). An earlier build that kept the guard
attached at budget 0 measured the same: 7.68 Gbps at 1,396 ns, and 88-byte TCP 10% slower. The program's own fast path
is about 1 ns: in `BPF_PROG_TEST_RUN` with 10M repeats in a Linux 7.0 VM, 6 ns a run at budget 0 against 6 ns for a bare
`XDP_PASS` program, and 17 to 23 ns with a budget, mostly `bpf_ktime_get_ns`.

## Fail-over, takeover and c7gn.large

- **A dead path still fails over.** [fix-failover](jobs/fix-failover.sh) on the medium, a5dd3ec, with TCP at 2 Gbps: the
  owner dropped everything it sent through the shared ENI outside the VPC from 13:02:08, stepped down at 13:02:14
  (`stepped down after corroborated path failure`) and the ENI moved at 13:02:21. Rules removed afterwards.
- **A takeover during a flood.** a5dd3ec, `natpair maintenance` 20 s into 64-byte UDP at 1.2M pps: the new owner logged
  `overload guard watching` for ens6 at 13:06:47, attached and engaged at 13:06:49 while its fence was still closed (the
  flood alone filled the CPU), and opened forwarding at 13:06:50. The old owner stopped watching. No program ended up on
  the old owner or on any primary ENI.
- **c7gn.large, final build ccbc006, guard on, one run each.** Full-rate TCP 18.72 Gbps, never engaged, 0 takeovers
  (#16: 18.17). 64-byte UDP at 1.2M pps: engaged once and cleared once, 864k forwarded (#16: 965k), 0 failed probes
  (#16: 1 to 14), ping loss 46.4% (#16: 24.6%), 0 takeovers.

Cost of this deploy: 10:45 to 13:24 UTC, about $1.79 (medium 2.50 h, large 0.16 h, S3, DynamoDB and Lambda).

## Status

Destroyed on 2026-11-14 at 13:24 UTC after the XDP overload guard runs (deploy at 10:45, about $1.79), and verified
empty with direct describe calls (instances, Elastic IPs, ENIs, volumes, VPCs, peering, endpoints, the bucket,
DynamoDB, Lambda, IAM). Only the unrelated benchmark-oracle instance and its own resources remain. To rerun, follow the
README's Deploy section with the build and module of choice. `tf/natpair.tf` points at a local checkout of the module,
here `natpair.worktrees/release-xdp`, and `nat_kernel` picks the NATs' kernel line.

# Final release candidate (2026-11-14)

Build c3c3b5a from natpair's bench/final branch: master faaac9a with the merge-ready PR heads merged in the order they
will land: #9 (8f467a1), #10 (4fb6494), #11 (b4e2ec9), #12 (0116724), #15 (b1187ff), #16 (a977169), #14 (a1f8eee) and
#17 (7219dcb). No #8 (pacing) or #13. Built like the release workflow (goreleaser with the repository's config, Go
1.26.0 from go.mod), tagged v0.1.99, tarball sha256 2ec679075399b0f53772031f9c30b08ed8aec4e3c2b4cef8ba24ea5089efcfed,
binary cad16c9e. Module from the same commit (`natpair.worktrees/final`), default kernel line, fresh deploy at 16:00
UTC. All five instances registered with SSM on the first boot (16:02:29), with no NAT replacement (#9). Both NATs ran
6.18.62-127.179 (#14's default), irqbalance inactive, threaded NAPI on every ENI. c7gn.medium first, then both NATs
resized in place to c7gn.large, the standby first. Job: [final-rc](jobs/final-rc.sh), one section per queued job, plus
[fix-failover](jobs/fix-failover.sh). Runs: [results/final-c3c3b5a](results/final-c3c3b5a). 60 s runs, 3 per cell
unless noted, median and range. Throughput is iperf3's received total, packet rates are the shared ENI's.

References: the release candidate (RC, 671d06f, [Release candidate](#release-candidate-2026-11-14)), #16
([Threaded NAPI on 6.18](#threaded-napi-on-618-2026-11-14)) and #17 ([XDP overload guard](#xdp-overload-guard-2026-11-14)),
all on 6.18.62.

| Check | c7gn.medium | c7gn.large | Verdict |
| --- | --- | --- | --- |
| First boot (#9), kernel (#14) | All five SSM Online by 16:02:29 on the first boot. 6.18.62-127.179, binary cad16c9e, `"release":"v0.1.99"`, natpair and conntrackd active, irqbalance inactive | Same kernel and binary after the in-place resize | pass |
| Smoke | 20 s TCP 8.98 Gbps. 20 s churn 3,000/s, p99 3.3 ms, 0 failures | 18.14 Gbps. Churn 3,000/s, p99 2.3 ms | pass |
| Interrupt spreading after 3 takeovers (#10) | 1 queue per ENI, on CPU 0 | Each new owner logged `spread network queue interrupts across the CPUs` (`moved`:2) within 1 s of its takeover. After the third: `ens5-Tx-Rx-0` and `ens6-Tx-Rx-0` on CPU 0, `-1` on CPU 1, the standby's ENI the same | pass |
| Threaded NAPI on every ENI, also after a takeover (#16) | Every summary shows `threaded` 1 on both ENIs. Each new owner logged `turned on threaded receive processing` 5 to 8 s after `ownership acquired` and before `forwarding open` | Same, all 3 takeovers | pass |
| TCP as fast as 32 flows go | 8.82 Gbps (8.80 to 8.99). #16: 8.92, #17: 8.90. 0 takeovers, 0 lease failures, 0 DNS timeouts, 0 to 2 failed probes, guard never engaged (NIC drop 2.0%) | 18.53 Gbps (18.29 to 18.63). #16: 18.17, #17: 18.72, RC: 18.94. 0 takeovers, 0 lease, 0 DNS, 0 to 2 failed probes, never engaged (NIC drop 0.9%) | pass |
| TCP with 88-byte segments, 64 flows | 928k pps (922k to 930k). #16: 940k. 0 takeovers, 0 lease, 0 DNS, 2 to 5 failed probes, never engaged | 1.98M pps (1.97M to 1.99M). #16: 1.97M, RC (90 s): 2.10M. 0 takeovers, 0 lease, 0 DNS, 4 to 6 failed probes, never engaged | pass |
| UDP 64 B at 800k pps | 0, 0, 0 takeovers. 0 lease, 0 DNS, 0 failed probes. Engaged and cleared once a run. 396k pps forwarded (394k to 427k), ping loss 76.1%. #17: 0 takeovers, 400k, 75.9% | 0, 0, 0 takeovers, 0 failed probes, never engaged (CPU not full), 795k forwarded, ping loss 1.6% | pass |
| UDP 64 B at 1.2M pps | 0, 0, 0 takeovers. 0 lease, 0 DNS, 0 to 2 failed probes. Engaged and cleared once a run. 427k forwarded (396k to 429k), ping loss 49.2% (48.3 to 81.6). #17: 0 takeovers, 0 to 2 failed probes, 363k | 0, 0, 0 takeovers. 0 lease, 0 DNS, 0 to 2 failed probes. Engaged and cleared once a run. 861k forwarded (851k to 866k), ping loss 47.7%. #17 (1 run): 864k, 46.4% | pass |
| Ring, nice and program after the guard clears | After all 7 engaged runs (incl. the congested handover): shared ENI ring 1,024 (2,048 while engaged), `napi/ens6-*` at nice 0, no XDP program | After all 3 engaged runs: ring 1,024, both `napi/ens6-*` threads at nice 0, no XDP program | pass |
| 3,000 connections a second, 3 x 60 s | 3,000/s, 0 failures, p99 5.1 ms (4.5 to 6.1), table about 100k | 3,000/s, 0 failures, p99 9.9 ms (7.3 to 21.1), table about 100k. RC: 1.98 ms (1.96 to 2.02) | pass, but the large's p99 is 4 to 10 times the RC's (see below) |
| 120 s churn with a forced full copy 60 s in | Table 97.6k before, 99.7k after, p99 7.1 ms, 0 failures, no step-down | 98.1k before, 99.7k after, p99 20.2 ms, 0 failures, no step-down | pass |
| 1M pps UDP flood of the owner's own address, TCP at 4.5 (medium) or 10 Gbps (large) | 4.22 Gbps (3.59 to 4.43) against 4.48 without a flood (#16). 4 to 9 lease failures a run, and 2 of 3 runs lost the lease: `lease lost: another owner took the lease while the store was unavailable`, 1 takeover each. #16: 1 takeover in 6 runs, #17: 0 in 3 | 7.84 Gbps (7.84 to 8.09) against 9.98 without (#16: 8.36). 2 to 3 lease failures a run, 0 takeovers | large pass. Medium fail: known limit, see below |
| SYN probes from the receiver to the shared and both own addresses (22, 8080, 40000, 50000, 61000, 61500, 62000, 65000), 3 rounds | No answer anywhere | No answer anywhere | pass |
| ACK probes, same addresses and ports | Own addresses: no answer. Shared: a reset on 8080, 40000 and 50000 only | Same | pass |
| 200 ACKs at 2,000/s to the shared address's port 40000 from one source, then 50/s for 10 s, 3 rounds | 51 resets in the burst, then 14 and 10 a second | Same | pass |
| Planned handover at 2 Gbps (`natpair maintenance`, then `natpair resume`), 3 rounds | 1 takeover each, ping gap 9.2 s (9.1 to 10.5), 0 lease failures, 1 to 2 DNS timeouts | 1 takeover each, ping gap 8.0 s (7.4 to 11.5), 0 lease failures, 1 to 2 DNS timeouts. RC: 8.7 s (6.1 to 9.9) | pass |
| Congested-owner handover: `natpair maintenance` 20 s into 1.2M pps UDP, guard engaged | Completed, 1 takeover, ping gap 9.3 s. The new owner turned on threaded NAPI, watched ens6, attached (ring 2,048) and engaged while its fence was still closed, then opened forwarding 8.7 s after acquiring. The old owner logged `overload guard stopped watching`. No program on either NAT afterwards | not run | pass |
| Blackhole fail-over at 2 Gbps (fix-failover) | Blackhole 16:56:47, `stepped down after corroborated path failure` 16:56:52, standby acquired 16:56:52 and opened forwarding 16:57:02. Ping gap 15.2 s | Blackhole 18:23:25, stepped down 18:23:30, forwarding open on the standby 18:23:39. Ping gap 13.9 s | pass |
| CPU per forwarded packet below saturation, 45 s, sampled once a second | TCP at 4 Gbps: 1,218 ns (1,209 to 1,318). #16: 1,202, before #16: 1,155. UDP at 300k pps: 2,034 (1,988 to 2,042). #16: 2,005, before #16: 1,923. Guard never engaged | TCP at 8 Gbps: 1,214 ns (1,192 to 1,285). #16: 1,191, before #16: 1,108. UDP at 400k pps: 1,980 (1,945 to 2,295). #16: 1,818 (1,802 to 2,217), before #16: 1,907 (1,835 to 2,160). Never engaged | pass: within 1 to 2% of #16 for TCP. The large's UDP is 9% over #16's median but inside both builds' spread |

- **The merges change nothing the PR benches didn't show.** Every number lands within a few percent of the PR it
  belongs to: full-rate TCP within 1 to 2% of #16 and #17 on both sizes, the guard's UDP behaviour as on #17's bench,
  the firewall answers exactly as on the RC. The one code interaction found while merging, #17's guard step in the
  takeover after #16's threaded NAPI step, ran in all 11 takeovers (7 on the medium, 4 on the large) and failed none.
  The congested handover's log shows the order: threaded NAPI on, then the guard watching the shared ENI, then
  forwarding open.
- **The medium still loses its lease under a 1M pps flood of its own address.** 2 of 3 runs on the medium ended in a
  takeover, against 1 in 6 on #16 and 0 in 3 on #17's bench, with the same mechanism each time: the flood arrives on the
  primary ENI with the lease replies, renewals time out (`lease store unreachable, forwarding on while the shared ENI
  stays here`, 4 to 9 a run), the lease expires, and the standby takes it (`lease lost: another owner took the lease
  while the store was unavailable` at 16:46:27 and 16:50:26). Neither threaded NAPI nor the guard, which watches only
  the shared ENI, covers that ENI, and the large rode it out. Fixing it needs a cheap drop on the primary ENI of what the
  host firewall drops anyway, such as XDP, as the #16 section suggested. The
  mechanism is the same as before the merges.
- **The large's churn p99 is higher than the RC's.** 3,000 connections a second never failed, but p99 was 7.3 to 21.1 ms
  against 1.9 to 2.0 on the RC (671d06f, no #16), while p50 rose only from 1.25 to 1.30 to 1.51 ms. The RC's maximum
  was about 1 s (a SYN retransmit) in 3 of its 6 generator streams, and this build's never passed 99 ms. The forwarding
  softirq time moved into the `napi/` threads (the owner's softirq share was 8 to 9% on the RC and 0 here), so the likely
  cause is threaded NAPI's scheduling, which #16 accepted for the 6.18 starvation fix. Phase 3 measured 7 to 17 ms on
  the large before the RC. Worth a look for pairs with connection-heavy workers, not a blocker.
- **Small notes.** Each planned handover logged 1 to 2 DNS timeouts, as the RC's did. The resize to c7gn.large took
  longer than it needed: a readiness check in the local resize script piped into `grep -q`, which made it loop for
  about 18 minutes while both NATs were already healthy (the bench sat idle on a medium and a large NAT, about $0.15).

**Conflicts while merging, in merge order** (the same ones the PRs will hit when they land in this order):

- #9: none.
- #10, #11, #14: CHANGELOG only. Keep every entry, sections in Keep a Changelog order (Added, Changed, Fixed, Security).
- #12: CHANGELOG, and both #11 and #12 add a function at the same spot in `internal/network/network.go`,
  `network_linux_test.go` and `export_test.go`. Keep both.
- #15: none (it is stacked on #12).
- #16: CHANGELOG, `cmd/natpair/nat.go` and `main_test.go`. Keep #10's interrupt loop and #16's threaded NAPI loop as
  separate goroutines, both imports, and both sets of tests.
- #17: CHANGELOG, `nat.go`, `docs/architecture.md`, `docs/operations.md`, `network_test.go` and `test.Dockerfile`. Keep
  both everywhere. `ActivateShared` runs #16's threaded NAPI step, returns if it fails, then `guard.Ensure`, since the
  guard sets the nice value of the threads threaded NAPI creates. In the SNAT test, #17's shared-canary rule comes first.
  The Dockerfile takes #17's package list (it adds iputils). One change beyond the conflicts: #16's two takeover tests
  build `localSteps` without a guard, which panics on Linux once `ActivateShared` calls `guard.Ensure`
  (`TestActivateSharedTurnsOnThreadedReceive`: nil pointer dereference), so they get a guard whose off switch exists.

Cost of this deploy: 15:59 to 18:38 UTC, 2.65 h, about $1.91 (generators, receiver, IPv4 and EBS 1.40, NATs 0.49:
medium 1.2 h, one of each 0.3 h, large 1.1 h, plus S3, DynamoDB and Lambda 0.02).

## Status

Destroyed on 2026-11-14 at 18:38 UTC after the final release candidate runs, and verified empty with direct describe
calls on AWS in us-west-2: no bench instances (5 terminated), Elastic IPs, bench ENIs, volumes, VPCs, peering, endpoints,
the bucket, DynamoDB tables, Lambda functions or IAM roles, profiles and policies. Only the unrelated benchmark-oracle
instance and its own volume and ENIs remain. `tf/natpair.tf` points at `natpair.worktrees/final`.

# Is #10 needed with #16? (2026-11-15)

natpair#10 pins ENA queue n's interrupt to CPU n every 5 s and turns irqbalance off, because in phase 1 irqbalance put
both of the shared ENI's interrupts on one CPU and a c7gn.large forwarded 9.6 Gbps instead of about 18. That was
v0.1.1, where forwarding ran in softirq on the CPU that took the interrupt. natpair#16 moves receive processing into
threaded NAPI kernel threads (`napi/<interface>-<id>`) that the scheduler places. Every build benched so far had both,
so this measures #16 alone.

Builds, tagged v0.1.99 and built like the release workflow (goreleaser, Go 1.26.0):

- **A**, natpair bench/napi-only 32be1de: master b9d2c47 (with #9) plus #16 at a977169. Tarball sha256
  30ee6173f3e1f03518e86f53f524374c9165f10f947fb40412eb6b4c6254f522, binary 49740a87. irqbalance on, as the AMI ships it.
- **B**, natpair bench/napi-irq 0c08f31: A plus #10 at b91c83b. Tarball sha256
  b67ab709eea8d491732952f980abfb9aa25c5a16626feb239b389895061b95c8, binary 8130afd3. irqbalance off.

Fresh deploy at 07:55 UTC with A on c7gn.large NATs, module from `natpair.worktrees/napi-only` (the same Terraform as
napi-irq). That module predates #14, whose kernel input it lacks, and its AMI filter picked kernel 6.1, so the
worktree's filter was pinned to 6.18 for the deploy only (uncommitted, as #14 does). Both NATs ran 6.18.62-127.179,
and all five instances were SSM Online by 07:57. [irq-swap](jobs/irq-swap.sh) switched builds on the running NATs,
the standby first: it installs the other binary and runs `systemctl disable --now irqbalance` (B, the state #10's
install script and the reboot after it leave) or `systemctl enable --now irqbalance` (A). Order: large A, B, then
both NATs resized in place to c7gn.xlarge (4 vCPUs, 4 queues per ENI), then xlarge B, A, so a drift over the session
would favour opposite builds on the two sizes.

For the xlarge, the generators went from c7gn.large to c7gn.xlarge and the receiver from c7gn.xlarge to c7gn.2xlarge.
At 18.6 Gbps through a large NAT, a c7gn.large generator used 1.2 of its 2 cores and the c7gn.xlarge receiver 2.4 of
4, so they couldn't feed the roughly 36 Gbps an xlarge's CPUs forward. Upsized, no generator CPU passed 56% busy and
no receiver CPU 70%.

Job: [irq-ab](jobs/irq-ab.sh), one per build and size: 3 rounds of 60 s TCP as fast as 32 flows go and TCP with 88-byte
segments from 64 flows, then 3 takeovers (`natpair maintenance`, `natpair resume` once the other NAT owns), the layout
65 s (A, irqbalance's minute) or 15 s (B, #10's 5 s loop) after the last, and one full-rate TCP run on the new owner.
Each NAT now samples, once a second during a run, where each queue interrupt goes and the CPU each `napi/` thread last
ran on and its CPU time (`placement` in the summary), and [box/irqwatch.sh](box/irqwatch.sh) recorded the same every
2 s on both NATs for each job's whole 15 to 16 minutes, idle gaps and takeovers included. Runs, layouts, watch files
and job logs: [results/irq-ab](results/irq-ab). [scripts/irq-table.py](scripts/irq-table.py) prints one line per run.
Medians of 3 runs, range in parentheses. Throughput is iperf3's received total, packet rates the shared ENI's.

| Load | c7gn.large, A (#16 only) | c7gn.large, B (#16 + #10) | c7gn.xlarge, A | c7gn.xlarge, B |
| --- | --- | --- | --- | --- |
| TCP as fast as 32 flows go | 18.24 Gbps (18.17 to 18.30), 1.67M pps. Both CPUs 100% | 18.27 Gbps (18.07 to 18.28), 1.67M pps. Both CPUs 100% | 15.62 Gbps (14.76 to 16.09), 1.47M pps. CPUs 52 to 68%. AWS dropping 42 to 99 a second | 16.23 Gbps (15.69 to 18.17), 1.50M pps. CPUs 57 to 66%. AWS dropping 78 to 197 a second |
| TCP with 88-byte segments, 64 flows | 1.976M pps (1.971M to 1.978M). Both CPUs 100% | 1.965M pps (1.963M to 1.969M). Both CPUs 100% | 4.159M pps (4.142M to 4.174M). All 4 CPUs 98 to 100% | 4.161M pps (4.140M to 4.171M). All 4 CPUs 99 to 100% |
| Shared ENI queue interrupts sharing a CPU, share of 1 s samples in each run | 100% in all 6 runs | 0% (queue n on CPU n) | 38 to 100% | 0% |
| Full-rate TCP on the owner after 3 takeovers, one run | 17.76 Gbps, all four queue interrupts (both ENIs) on CPU 0 | 17.86 Gbps, spread | 25.09 Gbps, AWS dropping 351 a second, shared queues 1 and 2 on CPU 1 | 15.77 Gbps, AWS dropping 34 a second, spread |
| Health in the 7 runs | 0 takeovers, 0 lease failures, 0 DNS timeouts, 0 to 2 failed probes a run | 0, 0, 0, 0 to 3 | 0, 0, 0, 0 to 1 | 0, 0, 0, 0 to 2 |
| 3 takeovers | 3 ownership changes, 0 lease failures, 5 DNS or probe timeouts over both NATs | the same: 3, 0, 5 | the same: 3, 0, 5 | the same: 3, 0, 5 |

- **irqbalance piles the shared ENI's queues onto one CPU most of the time, and it costs nothing with #16.** In A's
  watch on the large, the owner had both of the shared ENI's interrupts on one CPU in 443 of 460 samples (96%), and
  after the takeovers irqbalance put all four queue interrupts, both ENIs, on CPU 0. On the xlarge, two or more shared
  queues shared a CPU in 343 of 460 owner samples (75%), all four on one CPU in 14. Throughput didn't move: the
  large forwarded 18.24 Gbps with the queues piled against 18.27 spread, the same with all four on CPU 0 after the
  takeovers (17.76 against 17.86, both under the sat runs and inside run-to-run spread), and the xlarge's 88-byte runs,
  which fill all 4 CPUs, came out at 4.159M against 4.161M pps. The per-second rates show no dip either: the slowest
  second of each large TCP run was 1.25M to 1.49M pps in A and 1.31M to 1.48M in B.
- **Why: the interrupt no longer says where the work runs.** With threaded NAPI the interrupt only wakes the queue's
  `napi/` thread, and the scheduler moves those threads across every CPU in both builds. No shared ENI thread spent
  more than 71% of a run's samples on one CPU on the large, or 62% on the xlarge, whether its interrupt was pinned
  (B) or piled (A). Each shared ENI thread used about 60% of a CPU on the large in both builds, and in every large run
  both CPUs were 100% busy. Phase 1's 9.6 Gbps came from v0.1.1 doing all forwarding in softirq on the interrupt's
  CPU, which #16 removes.
- **The limiters.** The large and the xlarge's 88-byte runs are CPU-bound on every CPU in both builds, which is where
  a bad placement would show. The xlarge's full-rate TCP is not: its CPUs sat at 52 to 68% while AWS dropped on the
  shared ENI (`bw_out_allowance_exceeded` and `pps_allowance_exceeded`, 34 to 351 a second), and throughput wandered
  from 14.8 to 25.1 Gbps in both builds, so those rows say nothing about placement either way. The 88-byte gap on the
  large, 0.6% in A's favour, is the only one outside the ranges and goes against #10.
- **#10 does what it says.** Each B takeover logged `spread network queue interrupts across the CPUs` (`moved`:2)
  within 5 s of `turned on threaded receive processing`, and B's watches never saw two queues on one CPU.
- **Limits of the method.** 3 runs per side, not alternated within a size. The build order flipped between sizes
  instead. Builds were switched on the running NATs, not by booting new ones. The 6.18 pin was a local change to the
  module, not #14 itself.

**Verdict: close #10.** With #16, where the queue interrupts sit makes no measurable difference on a 2- or 4-vCPU
NAT, even with irqbalance stacking the shared ENI's queues on one CPU most of the time. #10 then only adds a 5 s loop
and turns irqbalance off for good (a rollback leaves it off).

Cost of this deploy: 07:54 to 09:09 UTC, 1.25 h, about $1.45 (c7gn.large phase 0.6 h at $0.78 an hour, c7gn.xlarge
phase with the larger generators and receiver 0.63 h at $1.53 an hour, S3, DynamoDB and Lambda 0.02).

## Status

Destroyed on 2026-11-15 at 09:08 UTC and verified empty with direct describe calls on AWS in us-west-2: 5 bench
instances terminated, no Elastic IPs, bench ENIs, volumes, bench VPCs, peering, endpoints, the bucket, DynamoDB
tables, Lambda functions or IAM roles, profiles and policies. Only the unrelated benchmark-oracle instance and its own
volume and ENIs remain. `tf/natpair.tf` points at `natpair.worktrees/napi-only` without the `kernel` input, which
modules from #14 on take again.

# Final release candidate (round 2, 2026-11-15)

Build 9664703 from natpair's bench/final2 branch: master b9d2c47 (which has #9) with the PR heads merged in the order
they will land: #11 (fd4a561), #12 (1e35e2b), #15 (cdebb1f, which contains #12), #16 (a977169), #14 (d2c6c25) and
#17 (6fb518c). No #8, #10 or #13. Built like the release workflow (goreleaser with the repository's config, Go 1.26.0
from go.mod), tagged v0.1.99, tarball sha256 6711be543646a688623abb09e984217a6500b03916b3d38b1b636c00aa2b233b,
binary 2a4aa1eb. Before AWS: `go vet` (linux, darwin, test tags), `go test -race ./...`, golangci-lint v2.13.2 (CI's
pin) with and without the test tags, `make test-privileged`, the fault campaign (`make test-campaign`, 19 of 19
cases), `terraform validate` for the module and both examples, and the module's `terraform test` (5 of 5).

For the #15 A/B, a second build without #15: bench/final2-no15 21d74a8, master plus #11, #12, #16, #14 and #17 with
the same conflict resolutions. Its tree differs from 9664703 only in #15's 13 files. Tarball sha256
196cba009bd33482f9c40edfd387448ff860d058a2dcb6a8acb619080d3a1c41, binary eb5a772a. Same checks, minus the campaign.

Module from `natpair.worktrees/final2` (bench/final2's Terraform, identical in both builds), `kernel` 6.18 (#14's
default). Fresh deploy at 20:50 UTC. All five instances were SSM Online by 20:51:15 on the first boot, with no NAT
replacement (#9). Both NATs ran 6.18.62-127.179, irqbalance inactive, threaded NAPI on every ENI. c7gn.medium first,
then both NATs resized in place to c7gn.large, the standby first. Builds were switched on the running NATs with
[build-swap](jobs/build-swap.sh), the standby first. Jobs: [final-rc](jobs/final-rc.sh) and
[fix-failover](jobs/fix-failover.sh) as in round 1, and [final2-checks](jobs/final2-checks.sh) for the new checks and
the A/B. `run.sh` gained `PATTERN=step STEP_AT= RATE2=`, which changes a load's rate partway through. Runs:
[results/final2-9664703](results/final2-9664703). 60 s runs, 3 per cell unless noted, median and range.

## Does the build without #15 flap?

64-byte UDP through the NAT, 3 runs of 60 s at each rate, and one 10-minute run at 1.2M packets a second, per build
and size. "Failed rounds" are health rounds that count toward stepping down. "In a row" is the longest run of them on
the serving NAT. Two in a row make the owner step down once the standby confirms the failure. "Path alive" counts
#15's check finding a congested path, so the round doesn't count. Forwarded is the shared ENI's transmit rate.

| Load | c7gn.medium, final2 (with #15) | c7gn.medium, no15 | c7gn.large, final2 | c7gn.large, no15 |
| --- | --- | --- | --- | --- |
| UDP 800k pps, 3 x 60 s | Takeovers 0, 0, 0. Failed rounds 0, 0, 0. Guard engaged once a run. 386k forwarded (384k to 387k), ping loss 77.5% | Takeovers 0, 0, 0. Failed 0, 0, 0. Engaged once a run. 380k (379k to 384k), ping loss 78.9% | Takeovers 0, 0, 0. Failed 0, 0, 0 (path alive 0, 1, 1). Engaged in 1 run. 786k (784k to 786k), ping loss 4.5% | Takeovers 0, 0, 0. Failed 3, 0, 0, **2 in a row** in run 1. Never engaged. 786k, ping loss 2.7% |
| UDP 1.2M pps, 3 x 60 s | Takeovers 0, 0, 0. Failed 0, 0, 0. Engaged once a run. 417k (415k to 417k), ping loss 49.5% | Takeovers 0, 0, 0. Failed 1, 0, 1, never 2 in a row. Engaged once a run. 395k (348k to 413k), ping loss 56.3% | Takeovers 0, 0, 0. Failed 1, 1, 0, never 2 in a row. Engaged once a run. 789k (761k to 820k), ping loss 58.8% | Takeovers 0, 0, 0. Failed 1, 0, 0. Engaged once a run. 781k (777k to 783k), ping loss 55.6% |
| UDP 1.2M pps, 10 minutes | **0 takeovers.** 0 failed rounds, 6 path alive. Guard engaged once and held. 337k forwarded, ping loss 93.8% | **1 takeover** 9 min 46 s in. 10 failed rounds, **3 in a row**. Guard engaged twice and cleared twice during the flood. 328k, ping loss 92.7% | **0 takeovers.** 1 failed round, 3 path alive. Engaged once and held. 783k, ping loss 54.4% | **1 takeover** 1 min 52 s in. 8 failed rounds, **3 in a row**. Engaged 3 times, cleared 3 times during the flood. 859k, ping loss 18.1% |
| TCP as fast as 32 flows go, 1 run | 8.28 Gbps (8.28 to 8.54 over sat's 3 runs), 0 failed | 8.42 Gbps, 1,298 ns a packet (final2: 1,259 to 1,296), 1 failed | 17.70 Gbps, 2 failed in a row once (no step-down: the standby didn't confirm) | 17.74 Gbps, 2 failed, never in a row |

**Verdict: yes, the build without #15 flaps under a sustained flood, so keep #15.** In 10 minutes of 64-byte UDP at
1.2M packets a second, no15 lost ownership once on each size, and final2 never did. In 60 s runs neither build
took over, but no15 counted 6 failed rounds over its 12 runs (2 in a row once, on the large at 800k) against 2 for
final2, which never had 2 in a row in a UDP run.

- **Both no15 takeovers followed the guard clearing in the middle of the flood.** On the medium, 8.5 minutes in, the
  guard raised its budget 4 times in 4 s and then cleared at a busiest CPU of 0.91. The NIC dropped probe replies at
  random again, the guard only re-engaged 61 s later and cleared again 9 s after that, and three failed rounds in a
  row ended the session:

  ```
  23:20:46-49 overload guard raised its budget (4 times)
  23:20:50    overload guard cleared              "busiest_cpu":0.912,"dropped":389601733
  23:21:51    overload guard engaged
  23:22:00    overload guard cleared              "busiest_cpu":0.929
  23:22:05-12 health round "healthy":false (4 rounds, 3 counted in a row)
  23:22:12    ownership session ended             "reason":"stepped down after corroborated path failure"
  ```

  On the large, the guard cleared 7 s after engaging (00:23:53, `"busiest_cpu":1`), and 3 failed rounds in a row
  ended the session at 00:24:18. With #15, the same failed probes found the path alive (handshakes partly completed),
  so they didn't count. The guard's behaviour is the same in both builds (#15 doesn't touch it): on final2's medium
  run it alternated `raised` and `lowered` every 1 to 2 s from 9 minutes in, without clearing.
- **#15's limit showed once.** In final2's first full-rate TCP run on the large, two uploads in a row timed out while
  all 40 handshakes completed, which #15 counts as failed by design. The standby didn't confirm, so the owner kept
  serving. The same pattern can make a slightly overloaded owner step down.
- **Forwarding and loss are the same within run-to-run spread.** #15 costs nothing measurable: full-rate TCP on the
  same hosts was 8.42 against 8.28 to 8.54 Gbps (medium) and 17.74 against 17.61 to 17.70 Gbps (large).
- **The medium's 1.2M pps runs reach the shared ENI at about 600k** in both builds and both rounds: one generator's
  iperf3 clients exit early with `unable to read from stream socket: Resource temporarily unavailable`. The
  10-minute runs and the large aren't affected. Round 1's medium numbers had the same error, so the rounds compare.

Counts come from the NATs' journals ([scripts/failed-rounds.py](scripts/failed-rounds.py), journals in
[results/final2-9664703/journals](results/final2-9664703/journals)). Each counted failure is logged, and so is the
next passing round.

## Checks

References: round 1 ([Final release candidate](#final-release-candidate-2026-11-14), c3c3b5a, which had #10 and
older PR heads). Rows marked "not run (budget)" were cut on the large to keep the session under $4 after the A/B was
added. Each of them passed on the large in round 1, and nothing they test differs between sizes.

| Check | c7gn.medium | c7gn.large | Verdict |
| --- | --- | --- | --- |
| First boot (#9), kernel (#14) | All five SSM Online by 20:51:15 on the first boot. 6.18.62-127.179, binary 2a4aa1eb, `"release":"v0.1.99"`, natpair and conntrackd active, irqbalance inactive | Same kernel after the in-place resize, binary 2a4aa1eb after swapping back from no15 | pass |
| #14: `terraform plan` with `release = "v0.1.1"` and kernel 6.18 (local, no apply) | Fails with `kernel 6.18 needs a natpair release with threaded NAPI, and v0.1.1 doesn't have it. Set release to a version after v0.1.1, or set kernel = "6.1".` | (same module) | pass |
| Threaded NAPI on every ENI, also after a takeover (#16) | `threaded` 1 on every ENI. Each new owner logged `turned on threaded receive processing` 4.6 to 7.5 s after `ownership acquired` and before `forwarding open` (3 handovers, the congested handover, the fail-over) | 4.5 to 7.9 s, before `forwarding open` (3 handovers, 2 kills, the fail-over) | pass |
| #11: delete the owner's route to the peer during 3,000 connections a second | 3 rounds 62 s apart: put back after 4.1, 1.9 and 4.5 s, each with `the route to the peer was missing or wrong and has been restored` (`checks`:1). In the 15 s after each: 94k to 101k copies to port 3780 on ens5, 0 on ens6, 0 fragments on either interface, `FragCreates` 0 | 1 round (budget): 3.6 s, same warning, 190k copies on ens5, 0 on ens6, 0 fragments | pass |
| #12: fill the connection table at 15,000 connections a second, then SIGKILL the owner's daemon and keep it down | 3 rounds. Table 262,144 of 262,144 about 20 s in. The owner logged `the connection table is full` and `the health probe failed because this NAT's connection table is full`, and kept serving. After the kill, the standby acquired once, opened forwarding 8.8 to 11.7 s later, ended no session, and forwarded 5k to 84k packets a second until the load ended (new connections limited by its own full table) | 2 rounds (budget): same. Acquired with `copied_state_ready` false, forwarding open 8.3 and 11.5 s later, 3k to 107k packets a second after | pass |
| #17: SIGKILL the daemon while the guard limits under 1.2M pps | 3 rounds and 1 with the off switch created just before the kill. Before: ring 2,048, `napi/ens6` at nice -10, XDP attached. The program and the nice value went at once (ENA restarts the interface when the XDP link closes). systemd restarted the daemon 1.2 to 1.4 s after the kill, and the ring was back at 1,024 by +1.2 to +1.6 s, record removed, in all 4. The off-switch round logged `overload guard switched` (`on`:false) and restored the same way | 2 rounds and the off-switch round (budget): ring 1,024 at +1.5 s in all 3, threads at nice 0 | pass |
| #17: 1.2M pps until the guard limits, then a steady rate above the cut budget | Step to 458k pps (115% of the 399k calibration, while the runs cut to 351k to 360k): raised 2 to 3 times, but in 2 of 3 runs cleared only when the load ended, shedding 9 to 12% at 80 to 85% CPU for 40 s. A 180 s run held at 433k shedding 7 to 15% until the end. Step to 419k pps (105%): raised and cleared 1 to 2 s after the step in 3 of 3 | Not run: a harness bug (the calibration read the budget from a log line it had cut short), fixed in the job afterwards | partial, see findings |
| Smoke | 20 s TCP 9.64 Gbps. 20 s churn 3,000/s, p99 3.9 ms, 0 failures | not run (budget, sat and churn cover it) | pass |
| TCP as fast as 32 flows go | 8.53 Gbps (8.28 to 8.54). Round 1: 8.82. 0 takeovers, 0 lease failures, 0 DNS timeouts, 0 to 3 failed probes, never engaged (NIC drop 2.1%) | 17.69 Gbps (17.61 to 17.70). Round 1: 18.53. 0 takeovers, 0 lease, 0 DNS, 0 to 4 failed probes (2 in a row once, see above), never engaged (NIC drop 1.0%) | pass, 3 to 5% under round 1 on both sizes and the same on no15 on these hosts |
| TCP with 88-byte segments, 64 flows | 890k pps (876k to 891k). Round 1: 928k. 0 takeovers, never engaged | 1.936M pps (1.919M to 1.939M). Round 1: 1.98M. 0 takeovers, never engaged | pass |
| UDP 64 B at 800k and 1.2M pps | See the A/B table: 0 takeovers in 6 runs, 0 failed rounds | 0 takeovers in 6 runs, never 2 failed rounds in a row | pass |
| Ring, nice and program after the guard clears | After all 7 engaged runs (UDP and the congested handover): ring 1,024, `napi/ens6` at nice 0, no XDP program | After all 6: same | pass |
| 3,000 connections a second | 3 x 60 s: 0 failures, p99 per generator 4.3 to 7.1 ms. Round 1: 5.1 | 1 x 60 s (budget): 0 failures, p99 12.6 and 19.6 ms. Round 1: 9.9 (7.3 to 21.1) | pass |
| 120 s churn with a forced full copy 60 s in | Table 97.6k before, 99.5k after, p99 4.7 and 5.6 ms, 0 failures, no step-down | 99.9k before, 101.9k after, p99 23.8 and 29.2 ms, 0 failures, no step-down | pass |
| 1M pps UDP flood of the owner's own address, TCP at 4.5 Gbps | 3.65 to 4.47 Gbps. 1 to 8 lease failures a run, and 2 of 3 runs lost the lease (`lease lost: another owner took the lease while the store was unavailable`), as in round 1 | not run (budget) | medium: known limit, unchanged |
| SYN probes from the receiver to the shared and both own addresses, 8 ports, 3 rounds | No answer anywhere | not run (budget) | pass |
| ACK probes, same addresses and ports | Own addresses: no answer. Shared: a reset on 8080, 40000 and 50000 only | not run (budget) | pass |
| 200 ACKs at 2,000/s to the shared address's port 40000, then 50/s for 10 s, 3 rounds | 51 resets in the burst, then 14 and 10 a second | not run (budget) | pass |
| Planned handover at 2 Gbps, 3 rounds | 1 takeover each, ping gap 8.8 s (8.3 to 10.5), 0 lease failures, 1 to 2 DNS timeouts | 1 each, ping gap 7.3 s (7.0 to 10.7), 0 lease, 1 to 2 DNS | pass |
| Congested-owner handover, `natpair maintenance` 20 s into 1.2M pps | Completed, 1 takeover, ping gap 8.9 s. The new owner turned on threaded NAPI, watched ens6, attached and engaged (22:12:38.1) while its fence was still closed, then opened forwarding (22:12:39.2). The old owner logged `overload guard stopped watching` | not run (as in round 1) | pass |
| Blackhole fail-over at 2 Gbps (fix-failover) | Blackhole 22:23:56, `stepped down after corroborated path failure` 22:24:01, forwarding open on the standby 22:24:08, ping gap 12.4 s | Blackhole 01:51:46, stepped down 01:51:52, forwarding open 01:52:00, ping gap 13.5 s | pass |
| CPU per forwarded packet below saturation, 45 s | TCP at 4 Gbps: 1,353 ns (1,312 to 1,432). Round 1: 1,218. UDP at 300k pps: 2,159 (2,154 to 2,164). Round 1: 2,034. Never engaged | not run (budget) | pass with a note: 6 to 11% over round 1, but not from #15 (full-rate TCP cost the same per packet on no15) |

## Findings

- **#17: the guard can clear while a flood still fills the NIC (bug).** Its clear rule takes the program off once it
  drops under 5% for a second, unless the busiest CPU is still full, and the raise rule lifts the budget 10% a
  second while the CPU is under 85%. Under a sustained 1.2M pps flood the raises pushed the budget up until the
  program barely dropped, and it cleared at 91 to 100% CPU (excerpt above). Off again, the NIC dropped probe replies
  at random, and on the medium the guard only re-engaged 61 s later, since engaging needs the CPU at 95% for 300 ms
  and the CPU sat at 91 to 93% with the NIC shedding the rest. That cost no15 a takeover on each size. final2 rode it
  out only because #15 counted those rounds as congested. A tighter rule would keep the program on, or re-engage it,
  while the NIC itself drops at least 5%, whatever the CPU reads.
- **#17: steady traffic between about 85% and 95% CPU stays shed after a flood (limit).** After a flood, the guard
  raises its budget only while the busiest CPU is under 85%. A steady 458k pps on the medium (after a cut budget of 351k
  to 360k) put the CPU at 80 to 85% on the raised budget, so the guard raised twice and then held, dropping 7 to 15%
  of traffic the CPU could carry, for as long as it lasted (3 minutes in the long run, ended by the load). Without a
  flood first, the same rate would never engage it (that needs 95% CPU). A steady 419k pps cleared within 2 s.
  Same fix direction as above: decide on the NIC's own drops rather than the CPU alone.
- **#15 counts a timed-out upload with all 40 handshakes completing as a failure.** It did so twice in a row once on
  the large during full-rate TCP. Documented in #15, and harmless here because the standby didn't confirm.
- **No bug in #11, #12, #14 or #16.** The merges behaved like the PR benches: every takeover a run's journal caught to the
  end (10 on the medium, 6 on the large, kills included) ran #16's threaded NAPI step and then #17's guard step
  before forwarding opened. The crash rounds' takeovers finished after their runs' journals ended.
- **Bench notes, all mine, none in natpair.** The receiver and generators auto-stopped 4 hours after boot
  (`auto_stop_minutes`) at about 00:50 and killed the large sat job, so it ran again from 01:08. The resize to
  c7gn.large lost about 30 minutes: my script ran `natpair resume` only after its readiness check, and a NAT in
  maintenance never reports ready (the flag survives the restart). The stack sat idle from 02:06 to 02:24 after the
  last job, about $0.23.

**Conflicts while merging, in merge order** (the PRs will hit the same ones when they land in this order):

- #11: none.
- #12: both #11 and #12 add functions at the same spot in `internal/network/network.go`, `export_test.go` and
  `network_linux_test.go`. Keep both.
- #15: none (it contains #12).
- #16: CHANGELOG, and `cmd/natpair/nat.go`, where #11's peer route check and #16's threaded NAPI check each add a
  goroutine at the same spot. Keep both goroutines. #16's changelog entry goes last under Fixed, before #12's Security
  section.
- #14: none.
- #17: CHANGELOG, `nat.go`, `docs/architecture.md`, `docs/operations.md`, `internal/network/network_test.go`,
  `test.Dockerfile`, and `internal/probe/probe.go`. Keep both sides in the docs. In `nat.go`, `ActivateShared` turns
  on threaded NAPI, returns if that fails, then calls `guard.Ensure`, since the guard renices the threads threaded
  NAPI creates. The guard gets its own goroutine. In `probe.go`, #15's private `receiverPort` and #17's exported
  `Port` are the same function, so `Port` stays and #15's callers use it. In the SNAT test, #17's shared-canary rule
  (ports 61000 to 65535) comes first, then #12's worker port rules. The Dockerfile takes #17's package list (it adds
  iputils). Changelog sections in Keep a Changelog order: Added, Changed, Fixed, Security. Round 1's extra test fix
  for `localSteps` without a guard is no longer needed: #17's 978f1d4 makes `Ensure` on a nil guard do nothing.
- Without #15 (bench/final2-no15): the same, minus `probe.go`.

Cost of this deploy: 20:49 to 02:27 UTC, 5.6 h, about $3.92: medium phase 2.67 h, about 1.76. Resize 0.65 h, 0.47. Large
2.0 h, 1.58, of which 0.3 h with the generators and receiver stopped. S3, DynamoDB and Lambda 0.03.

## Status

Destroyed on 2026-11-16 at 02:26 UTC and verified empty with direct describe calls on AWS in us-west-2: 5 bench
instances terminated, no Elastic IPs, bench ENIs, volumes, bench VPCs, peering, endpoints, the bucket, DynamoDB
tables, Lambda functions or IAM roles, profiles and policies. Only the unrelated benchmark-oracle instance and its own
volume and ENIs remain. `tf/natpair.tf` points at `natpair.worktrees/final2` with `kernel = var.nat_kernel`.

# Final release candidate (round 3, 2026-11-16)

Build 8221edc from natpair's bench/final3 branch: round 2's bench/final2 (9664703) with #17 moved to its new head
96627eb. #17's commits since round 2's 6fb518c are applied as the merge of 96627eb: 1d8d07a (the guard decides on the
NIC's own drops: it clears only once the NIC dropped under 5% over the last 1.5 s, cuts at 85% busy, raises only while
the NIC keeps up and not for 30 s after a cut, and for a minute after clearing engages again at 85% busy), fe8b599 (NIC
drops count as unknown after a counter reset) and 96627eb (a comment). #17's own merge of master brings #11 as the
squashed 3c89445, whose tree matches fd4a561, already merged. Built like round 2 (goreleaser with the repository's
config, Go 1.26.0), tagged v0.1.99, tarball sha256 1b046728c8261ee7967103e1361711312bcaa8914fce107c6242088e0a53ec5f,
binary 46db580a. Without #15: bench/final3-no15 62f647b (round 2's final2-no15 21d74a8 plus the same commits), tarball
sha256 d77bbed0846e88133902d0e84321afc422c0f19a106ab9762068a68ce46feb02, binary e9e034c3. Before AWS, on both: `go
vet` (darwin, linux, linux with the test tags), `go test -race ./...`, golangci-lint v2.13.2 (CI's pin) with and
without the test tags, and `make test-privileged`. The fault campaign wasn't rerun.

Module from `natpair.worktrees/final3`, `kernel` 6.18 (6.18.62-127.179). Fresh deploy at 04:24 UTC, all five instances
SSM Online on the first boot by 04:27. c7gn.medium, then both NATs resized in place to c7gn.large, the standby first
(05:30 to 05:33). Builds switched on the running NATs with [build-swap](jobs/build-swap.sh). Jobs: the `udp` section of
[final-rc](jobs/final-rc.sh) and the `budget`, `sustained` and `tcp1` sections of
[final2-checks](jobs/final2-checks.sh), whose `budget` gained `STEP_PPS` (a step to a fixed rate). Run summaries and
journals stay out of the repository this round. Rates below are per-second averages from the NATs' ENA counters, since
a run's `steady` figure came out wrong for the step runs.

## The guard on final3

64-byte UDP through the NAT. "Counted" is health rounds that count toward stepping down, "in a row" the longest run of
them, and "path alive" #15's check finding a congested path. Busiest CPU and NIC drops are whole-run figures on the
owner (NIC drops: `rx_over_errors` over packets received on the shared ENI). Forwarded is the shared ENI's transmit rate.

| Load | c7gn.medium | c7gn.large |
| --- | --- | --- |
| UDP 800k pps, 3 x 60 s | Takeovers 0, 0, 0. Counted 1, 0, 0, never 2 in a row. Engaged once a run and held until the load ended. Busiest CPU 93 to 96%, NIC drops 0.4 to 0.8%. 401k to 403k forwarded (run 1 reached only 595k). Ping loss 54 to 76% | Takeovers 0, 0, 0. Counted 0, 0, 0. Never engaged. Busiest 81 to 82%, NIC drops 1.2 to 1.4%. 789k to 790k forwarded, everything that arrived. Ping loss 0.9 to 1.8% |
| UDP 1.2M pps, 3 x 60 s | Takeovers 0, 0, 0. Counted 0, 0, 0 (path alive once a run). Engaged once a run and held. Busiest 95 to 97%, NIC drops 1.4 to 2.3%. 351k to 393k forwarded of 883k to 1.17M. Ping loss 78 to 87% | Takeovers 0, 0, 0. Counted 0, 0, 0. Engaged once a run. Runs 1 and 2: held until the load ended, 807k and 834k forwarded of 1.19M, ping loss 52 and 70%. Run 3 reached only 880k (a generator's iperf3 failed at start): engaged for 4 s at a 6% NIC drop, raised 3 times and cleared, 871k forwarded |
| 1.2M pps until the guard limits, then a lower steady rate for 180 s | 420k (arrived as 407k): cleared 9 s after the step, once the 30 s hold after its last cut ended (2 raises). 99.6% forwarded over the step. One more engagement 68 s after it cleared, at 97% busy and 20% NIC drops, cleared 2.4 s later after 2 raises (85k dropped). 460k (arrived as 443k): cleared 1 s after the step, then engaged 10 more times for 1 to 4 s each, each cleared right after a raise (see findings). 70k to 280k dropped each, 1.3M in all, 98.3% forwarded, busiest 91%. 0 takeovers, 0 counted in both. Round 2: 458k held 7 to 15% dropped for 3 minutes | 780k (arrived as 771k): cleared 1 s after the step, 100% forwarded. 840k (828k): cleared 9 s after the step, once the 30 s hold ended (1 raise), 99.8% forwarded. Neither engaged again. 0 takeovers, 0 counted. The large's cut budget (2 queues x 402k to 445k) sits above the roughly 830k its CPUs carry, so these steps are at or under it. Steps at 117% and 128% of the cut budget arrived as about 1.02M, more than the CPUs carry (84 and 87% forwarded): at 128% the guard held all 180 s, at 117% it cleared twice right after a raise and engaged again about 1 s later |
| UDP 1.2M pps, 10 minutes | **0 takeovers, 0 counted** (22 failed rounds, all found congested, 7 path-alive checks). Engaged once and held to the end, with 16 raise-then-cut pairs (a raise 30 s after each cut, cut again a second later). Busiest 91%, NIC drops 2.6%. 368k forwarded of 867k. Ping loss 83% | **0 takeovers.** 3 counted, never 2 in a row (2 path-alive checks). Engaged once and held to the end, with 10 raises and 9 cuts. Busiest 89%, NIC drops 3.9%. 816k forwarded of 1.15M. Ping loss 28% |

## Does the build without #15 flap now?

One 10-minute run of 64-byte UDP at 1.2M packets a second per build and size, and one 60 s TCP run.

| Run | c7gn.medium, final3 | c7gn.medium, no15 | c7gn.large, final3 | c7gn.large, no15 |
| --- | --- | --- | --- | --- |
| UDP 1.2M pps, 10 minutes | 0 takeovers. 0 counted, 0 in a row. Engaged once, held, cleared after the load. 368k forwarded, ping loss 83% | 0 takeovers. **32 counted, 2 in a row 4 times** (the standby never confirmed). Engaged once, held, cleared after the load. 343k forwarded of 1.15M, ping loss 90% | 0 takeovers. 3 counted, never 2 in a row. Engaged once, held, cleared after the load. 816k forwarded of 1.15M, ping loss 28% | 0 takeovers. 5 counted, never 2 in a row. Engaged 3 times: cleared twice in the flood (4 and 5 min in), each within a second of a raise at a busiest CPU of 1, and engaged again 1.2 s later each time. 731k forwarded of 1.15M (about 490k for the last 100 s, see findings), ping loss 49% |
| TCP as fast as 32 flows go, 60 s | 8.58 Gbps, 0 counted, never engaged | 8.66 Gbps, 1 counted, never engaged | 17.99 Gbps, 1 counted, never engaged | 17.82 Gbps, 1 counted, never engaged |

**Verdict: the build without #15 no longer takes over, but keep #15.** With #17's fix, no15 rode out the 10-minute
flood on both sizes with 0 takeovers. In round 2 it took over once on each size, both times right after the guard
cleared mid-flood and stayed off for up to 61 s. On the medium, no15 still counted 32 failed rounds with 2 in a row 4
times. Each time, only the standby's refusal to confirm kept the owner from stepping down. final3 counted none in the
same run, since #15 found the path congested. On the large the two builds are close (5 counted against 3, never 2 in
a row). TCP is the same within run-to-run spread on both sizes (round 2: 8.28 to 8.54 and 17.61 to 17.70 Gbps).

## Findings

- **#17's fix works.** On final3 the guard held through every 10-minute flood: one engagement per size, cleared only
  after the load ended, with 0 counted rounds on the medium and 3 (never 2 in a row) on the large. After a flood,
  steady traffic the CPU carries went back to full forwarding within 1 to 9 s of the step on both sizes. In round 2 a
  steady 458k pps on the medium stayed 7 to 15% dropped for 3 minutes.
- **#17: a raise can clear the guard before the NIC shows the overflow it causes (bug, minor).** The clear rule reads
  the program's shed share over the last second and the NIC's drops over the last 1.5 s. ENA refreshes
  `rx_over_errors` only once a second. When a raise lifts the budget above what arrives under a load the CPU can't
  carry, the shed share falls under 5%. The guard then clears 0.2 to 1.6 s after the raise, at a busiest CPU of 0.93
  to 1, before the new overflow is counted. It engages again 1 to 2 s later through the 1-minute 85% rule (5 to 60 s
  on the medium at 443k). This happened twice in the large no15 flood, twice in the large 117% step and at all 10 of
  the medium's re-engagements at 443k. Each cycle detaches and re-attaches the program (ENA restarts the interface each
  time), lets the NIC drop at random for about a second, and costs about 100k packets a second for 1 to 2 s. No
  takeover or counted round came from it here. Large, 117% step:

  ```
  06:05:18.2  overload guard raised its budget   "busiest_cpu":0.949,"shed_share":0.132,"budget_pps_per_cpu":531196
  06:05:18.9  overload guard cleared             "busiest_cpu":1,"dropped":26275410
  06:05:20.2  overload guard engaged             "busiest_cpu":1,"nic_drop_share":0.083
  ```

  A fix would hold off clearing until a full NIC window (1.5 s) has passed since the last raise.
- **Unexplained: the last 100 s of the large no15 flood.** At 8 min 19 s the shared ENI's arrivals fell from 1.19M to
  about 950k a second and forwarding from about 780k to 490k, with both CPUs only 65 to 70% busy. The guard held its
  budget (432k a CPU) with no raise, cut or clear until the load ended, and 4 of the run's 5 counted rounds fell in
  this stretch. The bench records no per-queue counters, so it can't show whether the remaining flows sat on one
  receive queue. final3's runs didn't show it.
- **Generators.** One iperf3 process still fails at the start of some runs with `unable to read from stream socket:
  Resource temporarily unavailable` (medium 800k run 1 reached 595k, large 1.2M run 3 reached 880k). The other
  medium 1.2M runs reached 883k to 1.17M, more than round 2's 600k.
- **Bench notes, mine.** The queue sat idle from 06:37 to 06:53 after the last job because my wait loop missed the end,
  about $0.21. The large steps at 117% and 128% of the cut budget overshot what the large carries, so 780k and 840k
  were added.

## Cost and status

Deploy 04:24 to destroy 06:54 UTC, 2.5 h, about $1.84: medium 1.1 h, about 0.73. Large 1.4 h, 1.09, of which 0.27 h
idle after the last job. S3, DynamoDB and Lambda 0.02. The in-place resize took 3 minutes.

Destroyed on 2026-11-16 at 06:54 UTC and verified empty with direct describe calls on AWS in us-west-2: 5 bench
instances terminated, no Elastic IPs, bench ENIs, volumes, bench VPCs, peering, endpoints, the bucket, DynamoDB
tables, Lambda functions or IAM roles, profiles and policies. Only the unrelated benchmark-oracle instance and its own
volume and network interfaces remain. `tf/natpair.tf` points at `natpair.worktrees/final3`.

# 2-vCPU without the guard: is #15 needed? (2026-11-16)

natpair#17 (the XDP overload guard) is closed, and natpair will require 2 or more vCPUs instead. This round asks two
questions on c7gn.large NATs (2 vCPUs) without the guard: does a large stay stable when flooded beyond what it
forwards, and is #15 (a congested path keeps its owner, plus the 10-minute congestion cap) still needed? The rule set
before the run: if the build without #15 shows no takeovers and never 2 failed rounds in a row under any flood, #15 is
not needed on 2-vCPU NATs.

Builds, both from natpair's master 3c89445 (which has #9 and #11):

- N, bench/no-guard-no15 f69dc6d: the merges of #11 (fd4a561, no change since master has it squashed), #12
  (1e35e2b), #16 (a977169) and #14 (d2c6c25). Its tree is round 3's bench/final3-no15 before #17 (bf45658). Tarball
  sha256 f8530007ecdb4ef88f4fdc9be21c160d2b1883f32d2bba43b86294db05b97a31, binary 425a30e0.
- W, bench/no-guard-15 7f3cc62: N plus #15 at 2e90e68, which has the congestion cap (`congestion_handover_minutes`,
  default 10). The only conflict was the list of settings that need new NATs in `docs/operations.md` (keep both
  additions). Tarball sha256 b9ca2afa635fddd6c94ed7b124f9ae9892d0a09bb17565854e824355c8bc050c, binary 0a59aac1.

Both built with `go build -trimpath -ldflags "-s -w -X main.release=v0.1.99"` (the release workflow's flags) and Go
1.27.3, then packed with `deploy/` as the release archive is. Before AWS: `go vet` (darwin and linux) and `go test
-race ./...` on both. Not run this round: golangci-lint, `make test-privileged` and the fault campaign.

Module from `natpair.worktrees/noguard-no15` (W's Terraform only adds the optional `congestion_handover_minutes`,
left unset), `kernel` 6.18 (6.18.62-127.179). Fresh deploy at 09:18 UTC, all five instances SSM Online on the first
boot by 09:20. NATs c7gn.large with irqbalance active and threaded NAPI on every ENI. Generators c7gn.xlarge (4
vCPUs, up from c7gn.large) and receiver c7gn.xlarge. N ran first, then W was installed on both NATs with
[build-swap](jobs/build-swap.sh). Jobs: [noguard](jobs/noguard.sh). Run summaries and journals stay out of the
repository.

## The load: fixed UDP flows without iperf3

A large forwards about 0.98M small UDP packets a second. To offer 2.5M and 4M, each generator sends 64-byte UDP
payloads (92-byte packets, as iperf3 `-l 64` sends) over 64 fixed flows, 128 in all, with [flood](flood)'s new
`-flows` mode (`run.sh MODE=raw`). Each generator's own ENA transmit counter confirmed the rate: 1.2M, 2.5M and 3.97M
to 4.0M packets a second. iperf3 couldn't do it here. Each client exchanges setup messages with its server through
the same NAT, and once the first clients fill the NAT past what it forwards, later clients' setup fails (`unable to
read from stream socket`). Even with a retry for clients that never started, iperf3 sent only 1.4M to 1.7M packets a
second when asked for 2.5M or 4M. AWS's `pps_allowance_exceeded` never moved on either NAT, so every drop in this
round is the NAT's own receive ring.

"Takeovers" counts ownership acquisitions, including ones that never opened forwarding. "Counted" is failed health
rounds that count toward stepping down, and "in a row" the longest run of them on the serving NAT. "Dark" is the
seconds of the 57 measured in which the pair forwarded under 10k packets a second in total. "Forwarded" is the shared
ENI's transmit rate summed over both NATs, since the ENI moves. "EIP retries" counts `shared Elastic IP not working
yet` from a new owner that can't yet prove the shared Elastic IP through the flood. The busiest CPU was 100% in every
UDP and flood run of both builds, measured over the seconds a NAT forwarded.

| Load | N, without #15 | W, with #15 |
| --- | --- | --- |
| UDP 1.2M pps, 3 x 60 s | Takeovers 2, 2, 0. Counted 15, 12, 9, **3 in a row**. Dark 11, 18, 0 s. Forwarded 764k, 620k, 991k. Ping loss 32, 43, 21%. EIP retries 2, 4, 0 | Takeovers 0, 0, 0. Counted 0, 0, 0. Dark 0 s. Forwarded 967k, 972k, 992k. Ping loss 24, 23, 23% |
| UDP 2.5M pps, 3 x 60 s | Takeovers 4, 3, 4. Counted 21, 15, 16, **8 in a row**. Dark 36, 41, 40 s. Forwarded 295k, 206k, 205k. Ping loss 85 to 87%. EIP retries 12 to 20 | Takeovers 0, 0, 0. Counted 0, 1, 0. Dark 0 s. Forwarded 975k, 973k, 996k. Ping loss 72, 77, 73% |
| UDP 4M pps, 3 x 60 s | Takeovers 2, 2, 2, two of which never opened forwarding. Counted 11, 4, 4, **4 in a row**. Dark 47, 56, 55 s. Forwarded 132k, 2k, 22k. Ping loss 91 to 92%. EIP retries 29 to 36 | Takeovers 0, 0, 1 (the congestion cap, below). Counted 3, 2, 1, never 2 in a row. Dark 0, 0, 12 s. Forwarded 978k, 973k, 753k. Ping loss 86, 86, 87% |
| UDP 2.5M pps, 10 minutes | iperf3, which sent 2.03M (5 of 16 clients failed setup). **27 takeovers**, 2 of which never opened forwarding. 146 counted, 7 in a row. Dark 291 of 597 s. Forwarded 421k. Ping loss 88%, longest gap 38 s. EIP retries 115 | 1 takeover: the congestion cap 6 min 17 s in (below), forwarding open 12.5 s after the handover. 4 counted, never 2 in a row. Dark 12 s. Forwarded 977k. Ping loss 79%, longest gap 13 s |
| 1M pps UDP to the owner's own address over the peering, TCP at 10 Gbps, 2 x 60 s | Takeovers 0, 0. Counted 4 and 6, 2 in a row once in each (the standby didn't confirm). Lease failures 1 and 3, lease kept. 8.29 and 8.41 Gbps. Ping loss 19, 22% | Takeovers 0, 0. Counted 1 and 3, never 2 in a row. Lease failures 8 and 4, lease kept. 7.27 and 7.29 Gbps on NAT a (see TCP). Ping loss 20, 18% |
| TCP as fast as 32 flows go, 60 s | 17.99 Gbps, 1,216 ns a packet, 0 counted (owner NAT b) | 16.11 Gbps, 1,355 ns a packet with NAT a as owner. Again with NAT b as owner: 17.98 Gbps, 1,218 ns, 0 counted |

No lease failures and no failed DNS lookups in any UDP run of either build. The own-address flood arrived at about
710k packets a second on the owner's own ENI.

**Verdict: keep #15. Without it, a 2-vCPU NAT is not stable past what it forwards.** N took over in 8 of 9 one-minute
runs and 27 times in the 10-minute run, with up to 8 failed rounds in a row, so it fails the rule on every flood rate.
Flapping wasn't the worst of it. At 2.5M and 4M the pair forwarded under 10k packets a second for 60 to 98% of each
run. Each new owner opened forwarding, failed its probes and stepped down within about 15 s of taking over. At 4M a new owner
couldn't prove the shared Elastic IP through the flood for 29 s, so its takeover failed and the other NAT tried and
failed the same way. N's 10-minute run, which offered less (2.03M), changed owner about every 22 s:

```
09:33:01.2  NAT a  ownership session ended  "stepped down after corroborated path failure"
09:33:01.5  NAT b  ownership acquired
09:33:09.0  NAT b  forwarding open
09:33:10.2  NAT b  health round "healthy":false  (then 13.2, 14.3, 15.3)
09:33:15.3  NAT b  ownership session ended  "stepped down after corroborated path failure"
09:33:15.7  NAT a  ownership acquired
09:33:26.7  NAT a  forwarding open
```

**With #15, a large is stable beyond its capacity.** At 1.2M, 2.5M and 4M offered, W held ownership through every run
apart from the cap, never counted 2 failed rounds in a row and forwarded its CPU ceiling, 967k to 996k packets a
second, at every rate. The NIC drops the excess at random, so every flow, pings included, loses about the excess
share: 23%, 73% and 86% ping loss against 19%, 61% and 76% offered over the ceiling. That ceiling is the hardware: both
CPUs are full, and nothing in natpair raises it. It only decides whether the pair keeps forwarding at it.

## The congestion cap

- **Cap check, `congestion_handover_minutes` 1.** Set on both NATs in `/etc/natpair/config.json`, daemons restarted
  standby first. With no load, an iptables rule dropped 85% of the packets leaving the owner's shared ENI (the NATs
  have no `tc` for netem): `-t mangle -I POSTROUTING 1 -o ens6 -m statistic --mode random --probability 0.85 -j DROP`.
  The first round found the path congested 3 s later, the owner handed over 61 s after that, and the peer opened
  forwarding 9.8 s later. No round counted as a path failure. **Pass.**

  ```
  11:20:48    drop rule on the owner
  11:20:51.8  the health probe failed, but the path is alive, so forwarding is congested ...
  11:21:52.4  handing over because this NAT's path has been congested for longer than congestion_handover_minutes ...  "congested_for":60565448726
  11:21:52.5  peer: ownership acquired  "copied_state_ready":false
  11:22:02.4  peer: forwarding open
  ```

- **The 10-minute cap fired twice in the flood runs, as designed.** Once in the third 4M run (10:44:43,
  `congested_for` 600.7 s) and once 6 min 17 s into the 10-minute run (10:56:51, 600.5 s). Each congestion run
  spanned several back-to-back runs: a run ends only after a minute without congestion, and the gaps between runs were
  about 50 s. So the cap fired about 10 minutes after continuous flooding began, not 10 minutes into one run. Each
  time the flood followed the shared ENI to the new owner, which retried the Elastic IP check 4 to 6 times and opened
  forwarding 12.5 s after the handover, then held.
- **Risk, not seen here: a cap handover can fail under a heavier flood.** #15 doesn't change the takeover's check of
  the shared Elastic IP, which needs an upload through it to pass. Under N's 4M floods that check failed for 29 s and
  the takeover failed. Under W's 4M flood it took 12 s. If a flood keeps the new owner's check failing longer, a cap
  handover leaves the pair dark until a takeover gets through. A check that accepts a congested path, as #15's health
  check does, would close this.

## Findings

- **No bug in #11, #12, #14, #15 or #16.** Every forwarding open the journals caught (79) followed #16's threaded
  NAPI step, and W's lease and DNS were clean in every UDP run.
- **NAT a forwards about 11% fewer packets per CPU than NAT b**, on the same type and kernel: TCP 16.11 Gbps at 1,355
  ns a packet against 17.98 Gbps at 1,218 ns for the same build. The own-address flood runs on W (7.27 and 7.29 Gbps,
  NAT a) against N (8.29 and 8.41 Gbps, NAT b) carry the same host difference. #15 itself costs nothing measurable,
  as in round 2.
- **Bench notes, mine.** The first N UDP job (09:20 to 09:32) is discarded: `PROCS` is per generator, so it ran 256
  flows at twice the asked rate, and 4 to 9 of 16 iperf3 clients failed setup. After that, N's 60 s runs with iperf3
  (0.75M to 1.7M sent) took over 0 to 3 times each, 8 of 9 runs at least once, and are not in the table. N's
  10-minute run is the iperf3 one at 2.03M, not repeated with flood. It fails on a lighter load than W carried. The
  first cap job failed because the NATs have no `tc`. [box/host.sh](box/host.sh) now retries iperf3 clients that fail
  before sending.

## Cost and status

Bucket at 09:17, destroy 11:23 to 11:24 UTC, 2.1 h at about $1.03 an hour (NATs 0.25, generators 0.50, receiver
0.25, addresses and volumes 0.03), about $2.17, plus S3, DynamoDB and Lambda 0.02: about $2.19.

Destroyed on 2026-11-16 at 11:24 UTC and verified empty with direct describe calls on AWS in us-west-2: no bench
instances, Elastic IPs, bench ENIs, volumes, bench VPCs, peering, endpoints, the bucket, DynamoDB tables, Lambda
functions or IAM roles, profiles and policies. Only the unrelated benchmark-oracle instance and its own volume,
network interfaces and VPC remain. `tf/natpair.tf` points at `natpair.worktrees/noguard-no15`.

# Connection table sizing (2026-11-16)

natpair sets the kernel's connection table (`nf_conntrack_max`) to `max_connections`, 262,144 by default, with a
quarter as many hash buckets, and conntrackd copies up to the same number to the standby. A full table drops new
worker connections, so the size must hold the pair's peak with headroom. This round measures what each size costs and
holds on the 2-vCPU NATs natpair will require: memory, forwarding, a full copy to the standby, a takeover, and churn.

Build: natpair bench/no-guard-15 7f3cc62 (master with #9 and #11, plus #12, #16, #14 and #15), the release candidate,
tarball sha256 b9ca2afa635fddd6c94ed7b124f9ae9892d0a09bb17565854e824355c8bc050c, module from
`natpair.worktrees/noguard-15`, kernel 6.18. NATs c7g.large (4 GiB, 3.8 GiB usable), then c7gn.large (4 GiB).
Generators c7gn.large, receiver c7gn.xlarge. Job: [ctsize](jobs/ctsize.sh), NAT side [box/ctnat.sh](box/ctnat.sh),
copy timings [scripts/ctsize-summary.py](scripts/ctsize-summary.py). Run summaries, samples and journals stay out of
the repository.

**Sizes were set by hand on the running NATs, not by replacing them.** [box/ctnat.sh](box/ctnat.sh) `resize` makes
the same changes natpair bootstrap makes at boot: `max_connections` in `/etc/natpair/config.json`,
`nf_conntrack_max` and `nf_conntrack_buckets` (a quarter) with sysctl, conntrackd's `HashLimit` and `HashSize` (a
quarter) in its configuration, then a conntrackd restart, the standby first. Bootstrap also sets the two sysctls on a
running kernel, so the kernel side is the same. Replacing both NATs per size would have cost about 4 minutes each.

## How the table was filled

[hold](hold) opens real TCP connections through the owner and leaves them idle, without a socket at either end, so
millions fit on small hosts. Each is a full handshake (SYN, SYN-ACK, ACK) through the NAT, which the NAT's table marks
established and assured, as it does a worker's idle keep-alive connection, and conntrackd copies it. A raw socket
sends, a packet socket with a BPF filter sees the answers, and each end drops the other's packets in its `raw` table
before its kernel would answer with a reset. The connections came from all 8 generator addresses (4 on each
generator) to 256 ports on the receiver, so no destination address and port took more than about 16,000 of the
shared address's 64,000 ports. hold opened 20,000 connections a second in chunks of up to 524,288, checking both NATs'
MemAvailable between chunks, and closed them with resets afterwards.

The generators' and receiver's security groups track connections, and AWS's tracking allowance per instance is far
below a million. Churn at 8,000 new connections a second already exceeded the receiver's (`conntrack_allowance_exceeded`
4,576 a second at 10,000). hold's ports and churn's ports are now untracked on those hosts (both directions allow TCP
from and to 0.0.0.0/0, see [tf/network.tf](tf/network.tf)), with the receiver's own firewall dropping churn traffic
from outside the test VPC. natpair's own security group is untracked already, so this limit never applies to a pair.

## Results

"Held" is the owner's table at the measurement: the job filled to 95% of each size, but every takeover lost entries
(below), so on c7g.large the 512k and 1M rows held what survived plus a new fill. Memory is from `/proc/meminfo`,
`/proc/slabinfo` and each daemon's resident set. "Kernel" is the growth of the slab caches (the `nf_conntrack` slab
is 256 bytes an entry, and its extensions add about 130). "Available" is MemAvailable out of 3.8 GB. natpair's
resident set swings by hundreds of MB from one health round to the next, so the table shows the reading and its high
mark. TCP is 16 flows from each generator as fast as they go, 20 s. "Copy" is the standby's copy after its conntrackd
restarted and asked for the whole table, as a share of the owner's table. "Kept" is the new owner's table after
`natpair maintenance`, as a share of the old owner's.

| Type, size | Held | Owner: available, kernel, conntrackd, natpair (high) | Standby: conntrackd, natpair (high) | TCP, ns a packet | Churn near full, p99 | Copy | Kept | Old owner's lowest available in the takeover |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| c7g.large, empty | 66 | 3,429 MB, 0, 6 MB, 19 MB | 6 MB, 18 MB | 10.55 Gbps, 1,627 | 1,000/s, 1.2 ms | | | |
| c7g.large, 262,144 | 248,013 | 2,857 MB, +104 MB, 142 MB, 194 (271) MB | 98 MB, 123 (183) MB | 10.45 Gbps, 1,756 to 1,762 | 327/s, 3 to 79 ms | 80% | 80% | 2,727 MB |
| c7g.large, 524,288 | 448,021 | 2,466 MB, +174 MB, 245 MB, 321 (493) MB | 198 MB, 190 (271) MB | 10.09 Gbps, 1,962 | 655/s, 61 ms | 72% | 72% | 2,103 MB |
| c7g.large, 1,048,576 | 819,541 | 1,870 MB, +311 MB, 446 MB, 468 (509) MB | 351 MB, 469 (601) MB | 10.21 Gbps, 1,890 | 1,310/s, 81 ms | 69% | 69% | 1,316 MB |
| c7g.large, 2,097,152 | 1,991,197 | conntrackd **killed by the kernel's out-of-memory killer 5 times** at 1.15 GB, kernel +716 MB, natpair 490 (612) MB | 845 MB, 453 (583) MB | 10.10 Gbps, 1,919 | 2,621/s, 72 ms | not run | not run | |
| c7gn.large, empty | 29 | 3,470 MB, 0, 6 MB, 18 MB | 6 MB, 18 MB | 19.00 Gbps, 1,209 | 1,000/s, 1.4 ms | | | |
| c7gn.large, 262,144 | 249,049 | 2,879 MB, +99 MB, 143 MB, 193 (263) MB | 122 MB, 115 (167) MB | **15.64 Gbps**, 1,463 | 327/s, 22 ms | 87% | 90% | 2,747 MB |
| c7gn.large, 524,288 | 498,073 | 2,368 MB, +191 MB, 271 MB, 248 (512) MB | 217 MB, 237 (324) MB | **13.81 Gbps**, 1,648 | 655/s, 45 ms | 73% | 76% | 2,132 MB |

4,194,304 was not tried: 2,097,152 already doesn't fit in 4 GiB. Hash buckets cost 8 bytes each, 4 MB at 2,097,152
(VmallocUsed didn't move), so they don't matter. The copies above are with natpair's configuration. With conntrackd's
socket buffers raised to 16 MB (below), the copy at 995,788 was 93%.

### Memory

- **The docs' 160 MB per 262,144 entries is about a third of the real cost.** At 262,144 the owner's MemAvailable
  fell 570 MB: the kernel's table about 100 MB (0.4 KB an entry), conntrackd's own copy 140 MB (0.55 KB), and
  natpair 175 to 250 MB. Per entry, the owner pays about 1.9 KB at 1M (1.56 GB for 819,541) and the standby 1.6 KB
  (conntrackd 0.47 KB a copied entry, plus natpair).
- **natpair's own memory is the surprise.** Every health round (each second on the owner, each 5 s on the standby)
  it runs `conntrackd -i` or `conntrackd -e`, reads the whole cache as text into memory, and parses it. Its resident
  set reached 270 MB at 262,144 and about 600 MB from 512k up, where its 2 s command limit cuts the dumps short.
- **A takeover is the peak.** The old owner keeps its whole kernel table until conntrackd's scheduled flush (60 s)
  while it takes in the new owner's full copy: at 818,124 entries its conntrackd reached 676 MB and MemAvailable fell
  to 1,316 MB (2.6 KB an entry). conntrackd doesn't give memory back: after the table drained, it stayed at 565 MB.
- **2,097,152 doesn't fit in 4 GiB.** At 1.99M entries the owner's conntrackd grew to 1.15 GB and the kernel killed
  it 5 times in 2 minutes. Forwarding continued (the kernel table is independent), but nothing was copied. Its
  restarts also left the standby with a stale copy of 1.83M entries.

### Copies and takeovers

- **A full copy to the standby loses 13 to 31% of the table, at every size, and natpair doesn't notice.** A
  restarted standby conntrackd asks for the whole table, and the owner sends it at once: 26 MB in 3,000 jumbo
  datagrams at 262,144, 71 MB at 1M, in 1 to 3 s. The standby's UDP socket has the default 208 KB receive buffer and
  drops part of the burst. conntrackd's resend recovers part of it, then stops: the copy stayed at 80%, 72% and 69%
  (c7g.large, 262k, 512k, 1M), 87% and 73% (c7gn.large) for minutes. natpair checks a copy by the peer's 16 oldest
  connections and its recent probe flows, which the first datagrams usually carry, so the standby reported
  `"copied":true` and `"ready":true` throughout.
- **A takeover then loses the same share.** The standby commits what it has, so after `natpair maintenance` the new
  owner held 80%, 72% and 69% of the old owner's connections on c7g.large and 90% and 76% on c7gn.large. The rest get
  resets on their next packet. Every takeover logged `"copied_state_ready":true`. The handover itself took 9 to 13 s
  from the request, and natpair's commit step took 1.7 to 4.9 s, within its 10 s limit per conntrackd command.
- **Larger socket buffers fix most of it.** With `RcvSocketBuffer` and `SndSocketBuffer` 16777216 in conntrackd's
  UDP section on both NATs (set by hand, not natpair's configuration), the copy at 995,788 entries reached 93%,
  against 69% at 827,041 without. Not complete, so natpair should also check a copy by its size against the peer's
  table (each health report already carries both counts).
- **From about 800,000 entries, natpair's checks time out and planned maintenance stops working.** `conntrackd -i`
  took 3.3 s at 819,541 entries and 7.3 s at 1.99M, and `conntrackd -e` on the standby 2.0 s at 752,064 and 5.1 s
  at 1.83M, against natpair's 2 s limit. At 996,175 entries the standby reported `"ready":false` for over 20
  minutes, and `natpair maintenance` waited the whole time without handing over. A takeover after a failure doesn't
  need a ready standby, but wasn't tested at this size.

### Forwarding and churn

- **A full table costs CPU per packet: 8 to 21% on c7g.large, 21 to 36% on c7gn.large.** On c7gn.large, where both
  CPUs are the limit, TCP fell from 19.0 Gbps empty to 15.6 Gbps at 249,049 entries and 13.8 Gbps at 498,073. On
  c7g.large, AWS's allowance (about 10.5 Gbps, `bw_out_allowance_exceeded` in every run) is the limit, so throughput
  held and only CPU per packet rose (1,627 to 1,962 ns). natpair's dump parsing explains part of it: 8 to 15% of a
  CPU with a full table, against 1% empty. The rest is the kernel's lookups in a bigger, fuller table (about 4 entries
  a hash bucket at 95%).
- **Churn near full stayed clean but slower.** No failures at any size, p99 from 1.2 ms empty to 20 to 80 ms with
  the table at 95%.
- **Each new connection a second holds about 30 entries** (TIME_WAIT is 30 s with #12): 6,000 a second held 181,000.
  So a table holds about 0.9 x size / 30 new connections a second before natpair's 90% warning, about 7,900 at
  262,144. Measured on c7g.large at 262,144: 7,000 a second held 81%, 8,000 held 91% (warnings, no failures), and
  10,000 filled it: 231,000 packets dropped, 7% of connections timed out, p99 3.2 s.
- **Past about 20,000 new connections a second, the NAT is the limit, not the table.** On c7g.large with an empty
  4,194,304 table, 20,000 a second held 580,000 entries with the owner at 1.76 of 2 CPUs busy, p99 1.1 s and 0.05%
  failures. Asked for 40,000, it completed 23,000 with 6% failures.
- **A full table behaves as #12 intends.** With 262,144 established connections held and more offered, the kernel
  dropped new connections (15,134 drops, and 5,992 of 6,000 churn connections timed out), natpair logged the 90% warning
  and `the connection table is full ... dropped`, and its failed probes counted as "table full", not path failures:
  no step-down, no takeover, no lease warnings. The owner's probe through the shared address needs a table entry,
  so its health rounds fail while the table is full, but none count.
- **The NAT tops out at about 20,000 new connections a second on either type.** With an empty 1,048,576 table on
  c7gn.large, 20,000 a second completed 19,981 with 0.09% failures and p99 1.1 to 1.3 s. Asked for 30,000, it
  completed 21,108 with 7.7% failures. The 262,144 runs on c7gn.large matched c7g.large: 8,000 a second held 91%
  with 1 failure, and 10,000 filled the table and 7% of connections timed out. No step-down in any churn run on
  either type.

## Recommendation

**Use a fixed default of 524,288 for now, up from 262,144, and keep `max_connections` as an explicit override. Size
automatically from memory only after natpair stops dumping whole caches every round.**

- **A rule from memory.** The peak cost is a takeover: the old owner holds its kernel table, its own conntrackd copy
  and the incoming full copy, with natpair parsing dumps on top. That measured 2.6 KB an entry (MemAvailable 1,316
  MB left at 818,124 entries on a 3.8 GB NAT). The rule: the largest allowed power of two whose entries at 2.6 KB
  each stay under 50% of MemTotal. 50% leaves what the NAT needed beyond the table here: about 400 MB for the OS,
  page cache and idle daemons, conntrackd's memory it never returns (565 MB after a 1M table drained), natpair's dump
  parsing swinging by up to 400 MB a round, and a second full copy when natpair finds a copy incomplete. At 818,124
  entries on 4 GiB (55% at the peak) the NAT ran with 1.3 GB left, and at 1.99M (about 135%) conntrackd was killed.
- **What it gives.** c7g.large and c7gn.large (3.8 GB): 730,000 entries, so 524,288. c7g.xlarge and c7gn.xlarge
  (7.7 GB): 1.48M, so 1,048,576.
- **Why not automatic yet.** From about 800,000 entries natpair's 2 s dump limit breaks the standby's readiness and
  `natpair maintenance` hangs, so every size natpair supports today has to stop at 524,288 anyway, and the rule gives
  one number. At 524,288 the dumps took 1.6 to 2.1 s with the table at 95%, right at the limit, and the standby
  stayed ready. Once the health check stops dumping caches (for example, sample the oldest entries with `conntrack`
  instead of `conntrackd -i`, and count copies from `conntrackd -s`), switch to the rule, which then gives the xlarges
  1,048,576.
- **Keep the override, and have natpair warn past the rule.** An explicit `max_connections` above what the rule
  allows should log a warning at boot naming the memory it needs.
- **The churn each size sustains** (TIME_WAIT 30 s, below the 90% warning): 262,144 about 7,900 new connections a
  second (8,000 measured at 91%), 524,288 about 15,700, and 1,048,576 the NAT's own limit, about 20,000, on both
  types. Long-lived connections take room from that one for one: a pair holding 300,000 idle connections at 524,288
  sustains about 5,700 a second.
- **What a bigger limit costs while unused: nothing.** Memory and CPU follow the entries held, not the limit. The
  hash buckets are 8 bytes each (2 MB at 1M), and more buckets for the same entries make lookups cheaper.

## Risks and fixes for natpair

- **A full copy silently loses 13 to 31% of the connections, and a takeover then drops them** (above). This applies
  to every size, including today's default. Fix: set conntrackd's UDP `RcvSocketBuffer` and `SndSocketBuffer` (16 MB
  gave 93% at 1M, against 69%), and count a copy as complete only when its size is near the peer's tracked count,
  not only by the 16 oldest entries.
- **natpair's dumps.** Each health round reads conntrackd's whole cache into memory: up to 600 MB of natpair's
  memory, 8 to 15% of a CPU, and from about 800,000 entries past the 2 s limit, which blocks planned maintenance.
- **The docs' memory figure is low.** Each 262,144 connections in the table costs about 0.6 GB on the owner and
  0.35 GB on the standby with this build, not 160 MB.
- **A full table costs throughput on c7gn.large:** 19.0 Gbps empty against 15.6 Gbps at 249,049 entries and 13.8 Gbps
  at 498,073. A pair that carries both many idle connections and line-rate traffic forwards less.
- **Not covered:** long-lived connections and churn at the limit together, the xlarge types (the rule's
  numbers there are extrapolated from the larges), and a failure takeover with a 1M table.

## Cost and status

Bucket at 11:43, destroy 15:35 to 15:36 UTC. c7g.large NATs 11:43 to 14:01 (2.3 h at about $0.68 an hour), c7gn.large
NATs 14:01 to 15:36 (1.6 h at about $0.78, including the nftables A/B below), S3, DynamoDB and Lambda about $0.03:
about $2.80 in all, of which sizing about $2.05. The queue sat idle from 11:52 to 12:21 while a Terraform apply and
job uploads of mine hung, and three of my job fixes cost reruns (stall detection, maintenance with an unready
standby, the receiver's SSM permissions).

Destroyed on 2026-11-16 at 15:36 UTC and verified empty with direct describe calls on AWS in us-west-2: the 5
bench instances terminated, and no Elastic IPs, bench ENIs, volumes, bench VPCs, peering, endpoints, the bucket,
DynamoDB tables, Lambda functions or IAM roles, profiles and policies. Only the unrelated benchmark-oracle instance and
its own volume, network interfaces and VPC remain. `tf/natpair.tf` points at `natpair.worktrees/noguard-15`.

# nftables vs iptables (2026-11-16)

natpair feat/nftables-prototype 04e062f (master with #11, #12 and #16, without #14 and #15) adds a native nftables
backend behind `"firewall": "nftables"` (default iptables): the same firewall, SNAT and fence as native tables, where
the iptables backend runs through `iptables-nft` and its compatibility layer for `conntrack`, `socket`, `hashlimit`
and the fence's `bpf` matches. The nftables fence renews a timed set element by running `nft` on every 500 ms
renewal. Tarball sha256 f1cfbcf0f06eb030f532e4ec0c5fd51102f819aedc54a0cbb3ddc9f302d096f8 (binary 97550d8d).

Both backends ran the same build on the same c7gn.large NATs, kernel 6.18, installed on the running pair and
switched by editing the configuration and rebooting each NAT, the standby first, as natpair's operations guide
describes. [info](jobs/nftab.sh) confirmed each state: iptables had 20 `NATPAIR` chains, nftables had only the `ip
natpair` and `ip natpair_fence` tables and a grant element expiring in under 4 s. Job: [nftab](jobs/nftab.sh). 3
rounds per backend of TCP as fast as 32 flows go and 64-byte UDP at 1.2M and 2.5M packets a second over 128 fixed
flows (run.sh `MODE=raw`), 30 s each. Forwarded is the shared ENI's transmit rate summed over both NATs.

| Load, 3 runs | iptables | nftables |
| --- | --- | --- |
| TCP | 18.82, 18.63, 18.02 Gbps. 1,215, 1,229, 1,266 ns a packet. Busiest CPU 100%. 0 takeovers | 18.58, 18.59, 18.38 Gbps. 1,229, 1,228, 1,243 ns. Busiest CPU 100%. 0 takeovers |
| UDP 1.2M pps | Forwarded 1,013k, 1,016k, 1,019k. 1,974, 1,968, 1,963 ns. Takeovers 0, 1, 0. Ping loss 17 to 21% | Forwarded 1,085k, 1,075k, 1,033k. 1,842, 1,861, 1,598 ns (the last with a takeover). Takeovers 0, 0, 1. Ping loss 9 to 20% |
| UDP 2.5M pps | Takeovers 2, 2, 2. Forwarded 9k, 809k, 822k. Shared Elastic IP retries 9, 6, 1 | Takeovers 2, 2, 2. Forwarded 784k, 605k, 958k. Retries 5, 7, 3 |

No lease renewal failures, no lease store warnings and no failed DNS lookups in any run of either backend. Every
step-down was `stepped down after corroborated path failure`, the overload flapping #15 fixes, which this build
doesn't have. None came from the fence: a missed renewal would end the session with a fence error or let the grant
expire, and neither happened, even under the 2.5M floods with both CPUs full.

Fence test, 2 rounds per backend: during light TCP and pings through the NAT, the owner's daemon was frozen with
SIGSTOP, and the owner's shared ENI was watched every 50 ms. Times from the freeze:

| | Forwarding stops | Peer acquires | Peer forwards |
| --- | --- | --- | --- |
| iptables | 3.96 s, 3.89 s | 6.3 s, 6.1 s | 17.5 s, 13.2 s |
| nftables | 3.51 s, 3.96 s | 5.9 s, 6.2 s | 17.0 s, 13.7 s |

Both hold for the 4 s grant and take over in about 6 s. The 7 to 11 s from acquiring to forwarding is the takeover's
own steps, the same for both. Each frozen daemon, once resumed, ended its session with `lease lost: forwarding
permission expired`.

**Verdict: nftables is as good as iptables, and slightly faster where the CPU is the limit.** TCP is the same within
run-to-run spread (18.5 Gbps either way). At 1.2M small packets a second, with both CPUs full, nftables forwarded
about 6% more (1,080k against 1,016k in the clean runs) at 6% less CPU a packet. Its fence stopped forwarding and
handed over on the same schedule, and running `nft` every 500 ms caused no missed renewal even when flooded. Not
covered: kernel 6.1, a 1-vCPU NAT, and a build with #15, where the 2.5M runs wouldn't be dominated by flapping.

# Copy completeness and sizing fixes (2026-11-16)

The sizing round above found that a full copy to the standby lost 13 to 31% of the table, that natpair still called
the standby ready, and that from about 800,000 connections natpair's checks timed out so planned maintenance never
handed over. This round checks the fixes: natpair#18 (conntrackd's socket buffers and resend queue sized for a full
copy, a standby ready only with 95% of the owner's table, default `max_connections` 524,288, one hash bucket per
entry), natpair#19 (the health rounds no longer read whole conntrackd caches; bounded passes run outside them) and
natpair#20 (a warning when one destination uses 70% of the shared address's ports).

Build: natpair bench/ctfix 0a24298, the release candidate bench/no-guard-15 7f3cc62 merged with the #18, #19 and #20
stack, with #20's port count taken from #12's worker range (1024 to 60999, 59,976 ports). Tagged v0.1.99, tarball
sha256 0abab4dc72aec21a9f7403bad3fde1416d5df38439c9e171debb6a29d50cdb28, module from the same commit, kernel 6.18.
NATs c7g.large (3.8 GB usable), generators c7gn.large, receiver c7gn.xlarge. Jobs: [ctsize](jobs/ctsize.sh) sections
`ports` and `fix`, with `ctnat.sh resizefix` for 1,048,576 (the same settings the build's bootstrap writes:
`max_connections`, both hash tables at one bucket per entry, `ResendQueueSize`, 64-byte-an-entry socket and netlink
buffers), then a conntrackd restart on each NAT, the standby first. 524,288 is the build's default, so it needed no
change. The table was filled with [hold](hold) as before.

## Copies, readiness and takeovers

"Restart" restarts the standby's conntrackd, which asks the owner for the whole table. "Reboot" reboots the standby,
as every self-update does. "Ready" is the time from the restart or reboot command to the standby's first health round
with `"ready":true`. "Kept" is the new owner's table after `natpair maintenance` against the old owner's.

| Size, held | Copy after restart | Ready | Copy after reboot | Ready | Handover, kept |
| --- | --- | --- | --- | --- | --- |
| 524,288, 498,078 | 498,080 of 498,097 in 8 s | 28 s | 498,082 of 498,077 by 73 s | 26 s | 11 s, 498,087 of 498,079 |
| 1,048,576, 996,151 | 995,914 of 995,992 in 9 s | 10 s | 995,915 of 995,962 by 73 s | 28 s | 16 s, 995,931 of 995,922 |
| Before the fixes, 524,288 | 72% | ready while short | | | 72% |
| Before the fixes, 996,175 | 69% | not ready for 20 minutes | | | no handover |

- **A full copy is now complete.** Every copy landed at 99.99% or more of the owner's table, against 69 to 80%
  before on the same type. The small gaps are connections opened or closed while the count was read. The standby's
  conntrackd counted 4,854 lost messages while the 996k fill arrived at 20,000 connections a second, and its copy
  still matched the owner's afterwards, so the resends now cover what the burst drops.
- **The standby is ready within half a minute, at 1M too.** Ready follows the copy by up to 20 s because the pass
  that confirms the owner's oldest connections waits up to 15 s after a copy is emptied. Before, at 996,175 entries,
  the standby stayed not ready for over 20 minutes.
- **Planned maintenance hands over at 1M, and takeovers keep every connection.** Both handovers kept the whole table,
  and the new standby's copy of the new owner was 99.98% or more within 25 s.

## Memory

From `/proc/meminfo` and each daemon's resident set (job snapshots, and once a second during each copy and
takeover). The owner started at 3,515 MB available.

| Size, held | natpair, owner and standby (high) | Owner: available, kernel slab, conntrackd | Standby conntrackd | After the takeover |
| --- | --- | --- | --- | --- |
| 524,288, 498,078 | 20 and 19 MB (21) | 3,043 MB, +187 MB, 292 MB | 261 MB | new owner 2,630 MB available, conntrackd 542 MB |
| 1,048,576, 996,151 | 20 and 20 MB (21) | 2,396 MB, +359 MB, 605 MB | 520 MB | new owner 1,264 MB available, conntrackd 1,089 MB |

- **natpair's memory no longer grows with the table.** It stayed at 18 to 21 MB at every size and through every
  copy and takeover, against 194 to 601 MB before.
- **The owner costs about 1 KB a connection** (0.95 KB at 512k, 1.1 KB at 1M once settled): 0.37 KB of kernel slab,
  0.55 KB in conntrackd and buffers. Before, 1.9 KB.
- **The peak is now right after a takeover**, when conntrackd holds both its own table and the copy and keeps the
  memory: about 1.8 KB a connection at 512k and 2.3 KB at 1M. 1,048,576 on the 3.8 GB NAT left 1.26 GB available,
  above the "under half of memory" rule but stable. The rule with 2.3 KB still gives 524,288 for 4 GiB and 1,048,576
  for 8 GiB.
- conntrackd itself still takes seconds to write a whole cache (`conntrackd -i` 1.9 to 2.0 s at 498k, 3.5 to 4.2 s at
  996k), but natpair now does that outside its health rounds, once a minute, with a 2-minute limit.

## Hash buckets

20 s of TCP, 16 flows from each generator, with the kernel's `nf_conntrack_buckets` at one per entry and at a quarter,
switched on the running NATs, alternating, two rounds each. c7g.large is held by AWS's bandwidth allowance (about
10.9 Gbps, `bw_out_allowance_exceeded` 1,400 to 2,600 a second in every run), so CPU per packet is the measure.

| Size, held | One bucket per entry, ns a packet | A quarter, ns a packet |
| --- | --- | --- |
| 524,288, 498,078 | 1,523 and 1,679 | 1,524 and 1,660 |
| 1,048,576, 996,151 | 2,018 and 1,576 | 1,542 and 1,889 |

No measurable difference: the spread between rounds is larger than any effect. Against the sizing round's 1,962 ns at
512k, CPU per packet is about 15% lower, which matches natpair no longer parsing dumps every round. The extra buckets
cost about 15 MB at 524,288. A c7gn.large, where the CPUs rather than the allowance limit TCP, wasn't tested.

## Shared-port warning

[ctsize](jobs/ctsize.sh) `ports` held 45,000 idle connections from the 8 generator addresses to one receiver port,
75% of the 59,976 ports the shared address offers a destination. Within a minute the owner logged
`worker connections to one destination use most of the shared address's ports for it ...` with
`"destination":"tcp <receiver>:7000","connections":45000,"ports":59976,"percent":75`, and its health rounds reported
`"shared_ports_used":0.7503001200480192` while the connections were held. Two minutes later, after they were reset, it
logged `worker connections to a destination are back under 70% of the shared address's ports` once, and the share went
back to 0.00003. The standby, which doesn't count, reported 0. The first attempt held nothing because that version of
the section didn't install iptables on the generators, whose kernels then reset the handshakes.

## Cost and status

Deployed 22:50 UTC, jobs 22:55 to 23:31. Results came back, but my session then stalled for about 8 hours before
the teardown: the generators and receiver stopped themselves after 4 hours (`auto_stop_minutes`), while the NATs ran
until the destroy at 08:00 to 08:01 UTC on 2026-11-17. About $3.60 in all: NATs 9.1 h at $0.145 an hour ($1.32),
generators and receiver 4 h at $0.50 ($2.00), public addresses, volumes, S3, DynamoDB and Lambda about $0.26. Without
the stall it would have been about $1.10.

Destroyed (72 resources) and verified empty with direct describe calls on AWS in us-west-2: no bench instances,
Elastic IPs, natpair network interfaces, bench VPCs, peering, bucket, DynamoDB tables, Lambda functions or IAM roles
and profiles. Only an unrelated instance and its volume remain. `tf/natpair.tf` points at
`natpair.worktrees/bench-ctfix`.

Not covered: c7gn.large, churn near a full table with these builds, a failure takeover (not planned maintenance) at
1M, and 2,097,152, which the memory rule already rules out on 4 GiB.

# Release regression battery (2026-11-17)

The live release, v0.1.1, against exactly what will land, on the same pairs: each pair started on v0.1.1 with
v0.1.1's module, ran the core set, updated itself in place to the candidate under traffic, as production pairs will,
and ran the set again. Two pairs at once: L with c7gn.large NATs (2 vCPUs, 4 GiB) and M with c7g.medium NATs (1 vCPU,
2 GiB), on AWS in us-west-2. v0.1.1's module boots whatever kernel line is newest, here 6.1.190 on all four NATs, and
an in-place update keeps it, so every candidate result below is on 6.1. Generators c7gn.large, receivers c7gn.xlarge
(L) and c7gn.large (M). Job: [regress](jobs/regress.sh), queued with [scripts/submit-regress.sh](scripts/submit-regress.sh),
which puts [ctsize](jobs/ctsize.sh)'s helpers in front. `TF_DIR=tf-m` points the scripts at a second stack beside
`tf`.

Builds (natpair), all built with `go build -trimpath -ldflags "-s -w -X main.release=<tag>"` and packed with `deploy/`
as the release archive is. vet and `go test -race` pass on each, and natpair's fault campaign on v0.1.1 and on the
final candidate:

| Tag | Branch, commit | What | sha256 |
| --- | --- | --- | --- |
| v0.1.1 | the release, faaac9a | baseline | 68d771ed...a48ab |
| v0.1.99 | bench/regress 359da36 | master 4849a69 + #15 86bbe20, #16 44bef14, #18 6e2b221, #19 542359a, #20 a2d42d1, #21 ba219c9 | 4792be9e...0c3c (not run on AWS) |
| v0.1.98 | bench/regress2 ef415f5 | + #15 1f6d53d (congestion window fixed at 10 minutes), #18 de0610a (connection limit from memory), #19 1823cc5, #20 f2551b6 | 7476408a...833e |
| v0.1.97 | bench/regress3 40e5cbf (tree 00f249b) | + #18 cb19ef6, #19 2e3b696, #20 8d0c55a. **The final candidate** | 100665e7...0a39 |

Not in any candidate: #22 (security group), #6, #7, #8.

## Results

L ran v0.1.1, then v0.1.98 (from an in-place update), then v0.1.97 (a second in-place update). M ran v0.1.1, then
v0.1.97. Gaps are the longest run of lost pings (100 a second through the NAT). Light TCP is 32 flows at 2 Gbit/s in
all (L) or 400 Mbit/s (M, under its 500 Mbit/s baseline). "Flows broke" counts iperf3 clients that failed.

| Test | v0.1.1 | Candidate | Result |
| --- | --- | --- | --- |
| natpair campaign (local) | 17/17 | 21/21 on v0.1.97, planned-maintenance alone 3/3. v0.1.99 failed planned-maintenance once (the standby wasn't ready within the campaign's 20 s), then passed 22/22 | Pass |
| Planned handover under light TCP, 20,000 idle connections (A6) | L gap 9.6, 11.5, 7.8 s. M 12.5, 10.0 s. 0 flows broke | L 11.3, 11.7 s (v0.1.97), 7.8, 8.8 s (v0.1.98). M 9.0, 10.8 s. 0 flows broke, every idle entry kept | Pass, same |
| SIGKILL to the owner's daemon (A2) | L 13.8, 14.4, 16.3, 13.7, 13.2, 17.7 s. M 14.0, 13.4, 17.9, 16.2, 16.5, 14.0 s | L 15.5, 17.0, 13.7, 17.3, 13.1, 12.7 s. M 13.8, 18.0 and the 4 runs below | Pass, same (below) |
| Owner's shared path blackholed (B1) | Steps down, L gap 11.1 s, M 15.7 s | Steps down, L 16.8 s (v0.1.98), M 12.2 s | Pass |
| Forced full copy under churn: idle connections (L 100,000, M 50,000), churn (L 3,000/s, M 1,000/s), the standby's conntrackd restarted, a handover 80 s later | L: the table filled (TIME_WAIT 120 s), the copy fell to 44,436 of 261,943 and the standby still said ready, `pps_allowance_exceeded` 126,765/s, 208,577 churn connections timed out. M: copy kept up, ready 10 s | L (v0.1.98): copy 214,843 of 205,173 within 10 s, ready 9 s, 0 allowance drops, 23,890 timeouts (the 9 s handover pause at 3,000/s). M: copy complete within 10 s, ready 8 s | Pass, better |
| Full connection table, churn into it, then the owner killed (D4) | L 262,144 and M 262,144: the owner flapped (L 3 acquired, 4 ended, a lease failure). natpair 90 to 190 MB | L 524,288 (v0.1.98), M 262,144 (sized from memory): 1 clean takeover each, "table full" rounds not counted. natpair 18 MB. M lowest available 1.27 GB (v0.1.1 1.0 GB) | Pass, better |
| 64-byte UDP through the shared address, 2 x 60 s (L 2.5M, M 1.2M a second) | L 3 takeovers a run, 13k to 24k forwarded. M 3 takeovers a run, 71k to 124k forwarded | L 0 takeovers, 1.007M to 1.018M forwarded. M 0 takeovers, 505k to 507k | Pass, much better |
| 1.2M UDP for 10 minutes | M 28 takeovers, 68k forwarded | L 0 takeovers, 1.021M forwarded, 76 congested rounds. M 514k forwarded, 1 handover from #15's congestion window (287 of 389 rounds in the last 10 minutes congested or failed), the new owner's Elastic IP check accepted the congested path and forwarding opened 7.5 s later, gap 7.9 s | Pass, much better |
| Handover and SIGKILL during 1.2M UDP | M: the handover worked (gap 11.3 s), the kill caused 3 takeovers | L gap 9.6 s and 15.4 s. M 9.8 s and 14.7 s. 1 takeover each | Pass, better |
| TCP as fast as 32 flows go, 30 s | L 9.3 Gbps. M 4.8 and 5.8 Gbps | L 17.0 to 17.8 Gbps. M 5.8 Gbps | Pass, better |
| In-place update under light TCP and 100,000 idle connections (L), 50,000 (M) | | L v0.1.1 -> v0.1.98: 1 handover, gap 8.2 s, 0 flows broke, each standby re-copied 99,500 within about 20 s of booting. M v0.1.1 -> v0.1.97: gap 9.9 s, 0 broke. L v0.1.98 -> v0.1.97: handed over 25 s after the standby was ready (below), 1 of 2 iperf3 control connections broke, data flows survived | Pass, one unexplained break |
| Rollback v0.1.97 -> v0.1.1 in place (M) | | Soaked 3 min 13 s, 500 of 500 idle connections kept | Pass |

ENA allowance counters: L's `pps_allowance_exceeded` stayed 0 in every candidate run, against 13 to 157 a second
during v0.1.1's handovers and kills and 126,765 a second during its churn copy (conntrackd's fragmented copies, fixed by
#11). M's c7g.medium exceeds its packet allowance under any load on both builds (15k to 23k a second at 400 Mbit/s,
838k a second at full TCP). No lease renewal failure in any candidate run.

## The updater skips its 2-minute soak

Pre-existing: `internal/update` is unchanged since v0.1.1, so tomorrow's v0.1.1 owners have it. The owner hands over
once "the peer runs the pinned release and is ready" has held for 2 minutes, checked once a minute. Before a new pin,
that already holds for the current release, and the timer isn't reset when the pin changes. If the standby installs,
reboots and reports ready between two of the owner's passes, the old timer carries over and the owner hands over at
once. On L's second update the standby rebooted at 11:38:48, was ready at 11:39:14, and the owner handed over at its
11:39:39 pass. On the first update the owner's pass caught the standby not ready yet and waited the full time.

**Operator procedure that keeps the soak with v0.1.1's code**, verified 3 times (L twice, M's rollback once): (1)
`natpair maintenance` on the standby, whose updater then waits ("maintenance was requested by hand"); (2) pin the
release; (3) wait for the owner's next `update` line, "waiting for the peer to run the pinned release and be ready",
at most a minute; (4) `natpair resume` on the standby. The owner then soaked 3 min 33 s, 3 min 32 s and 3 min 13 s
after the standby was ready. While the standby is in maintenance, about 1 to 2 minutes, it doesn't offer to take over.

**Does an early handover lose idle connections? Not found.** [box/idle.py](box/idle.py) holds idle TCP connections with
a socket at each end and checks each with an echo. On L (v0.1.97), with about 100,400 entries in the table: 500 idle
connections, the standby rebooted as an update does (ready 26 to 28 s later), `natpair maintenance` 0 s (3 rounds),
25 s and 120 s (2 rounds) after ready: 3,000 of 3,000 echoed, and the new owner held all 500 entries each time. The new
owner's table was 8 to 30 entries smaller than the old owner's in every round, soaked or not: short-lived entries that
aren't copied. In the procedure runs, batches of 100 opened 30 s and 10 s before the standby's reboot, during it, and 5
s and 20 s after ready (L), and 13 s and 4 s before, during, 5 s and 20 s after (M's rollback), plus 500 older ones:
2,000 of 2,000 survived. The broken iperf3 control connection on L's second update (opened 13 s before the standby
rebooted, idle for 20 minutes, "unable to send control message: Broken pipe" at the end) wasn't reproduced and isn't
explained.

## Is the kill gap longer on the candidate?

No. 4 more SIGKILL runs per version per size, with each takeover split from the new owner's journal. natpair's
service closes the fence when its daemon dies, so forwarding stops at the kill, and the gap is the time to the new
owner's `forwarding open`.

| | Kill to lease acquired | Acquired to forwarding open | Kill to open, s |
| --- | --- | --- | --- |
| L v0.1.1 | 5.9, 6.3, 6.4, 6.3 | 10.4, 7.3, 6.8, 11.5 | 16.3, 13.7, 13.2, 17.7 |
| L v0.1.97 | 6.1, 6.1, 6.1, 6.0 | 7.6, 11.2, 7.0, 6.7 | 13.7, 17.3, 13.1, 12.7 |
| M v0.1.1 | 6.1, 6.0, 6.4, 5.7 | 11.8, 10.1, 10.1, 8.3 | 17.9, 16.2, 16.5, 14.0 |
| M v0.1.97 | 6.1, 5.9, 5.8, 5.8 | 10.1, 11.5, 9.6, 10.0 | 16.2, 17.4, 15.4, 15.8 |

Means over all 6 kills per pair: L 14.9 s on both builds, M 15.3 s on v0.1.1 and 16.1 s on v0.1.97, inside each
pair's run-to-run spread (L 12.7 to 17.7 s, M 13.4 to 18.0 s). Detection and the lease take 6 s on both. The spread is in the takeover, from two steps the candidate doesn't change:
EC2 detaching the shared ENI from the dead owner's instance (between the detach request and the attach request: 2 to
7 s), and the check of the shared Elastic IP, which needs 1 or 2 retries of 1.2 s until the new path works. The
candidate's own steps (installing copied connections 0.0 to 0.1 s, against v0.1.1's 0.5 to 1.0 s, and turning on
threaded receive processing) are faster or negligible.

## Other measurements

- **`conntrack -L` near a full table (L, v0.1.97, 497,600 entries, 524,288 limit).** 3.9 and 4.5 s, 1.7 s of CPU
  (1.1 user, 0.6 system), 1.7 MB resident. During 40 s of TCP as fast as 32 flows go, with the dump 10 s in: 15.8 Gbps
  against 16.9 without, the owner's probes timed out 2 to 5 times (counted as congested, not failures), 0 takeovers.
  With the full table, TCP held 16.9 Gbps, against 13.8 Gbps at 498k in the sizing round before natpair stopped
  parsing dumps.
- **Connection limit from memory (#18).** Both c7g.medium NATs set 262,144 and logged it at start. Both c7gn.large NATs
  logged `"connection limit","max_connections":524288,"reason":"the largest whose peak memory fits in half of the
  instance's"`.

## Bench notes

- v0.1.1's NAT role has only Session Manager's channels, and its NATs boot before the module attaches even those, so
  [tf/natpair.tf](tf/natpair.tf) attaches `AmazonSSMManagedInstanceCore` to the NAT role for the bench. One M NAT
  still never registered and was replaced.
- My `full` section restarted the wrong NAT's daemon after its kill (a variable set in a piped subshell), which left
  one M NAT down from 10:54 to 11:47. Its v0.1.1 flood runs then had no standby and are discarded (rerun above), and
  the owner correctly refused to update with a dead standby for 20 minutes. Fixed.
- One planned handover in L's first v0.1.1 set never happened: SSM throttled the send of `natpair maintenance`.
  [box/lib.sh](box/lib.sh) now retries sends. Rerun above.

## Cost and status

L ran 09:46 to 14:02 UTC (4.3 h at about $0.78 an hour, $3.33), M about 4.6 h at about $0.47 an hour ($2.16), S3,
DynamoDB, Lambda and addresses about $0.15: about $5.65. Running two stacks at once needed more internet gateways and
Elastic IPs than the region's defaults allowed.

Both stacks destroyed (74 resources each, L at 14:02 and M at 14:24 UTC) and verified empty with direct describe calls:
no bench instances, Elastic IPs, natpair network interfaces, bench VPCs or internet gateways, peering, volumes,
endpoints, buckets, DynamoDB tables, Lambda functions or IAM roles and profiles. Only an unrelated instance and its
volume remain. `tf/natpair.tf` points at `natpair.worktrees/regress-cand3`.
