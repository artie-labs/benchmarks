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

# Phase 2: pacing A/B

**Pacing (natpair#8) is parked** as of 2026-11-13. The next design gives natpair's own work priority over
forwarding instead (see [Phase 3](#phase-3-control-plane-priority)). These results stay as the record of what pacing
did.

Measured 2026-11-12 and 2026-11-13 in the same sandbox with natpair v0.1.99, built from the natpair branch
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

## Status

Destroyed on 2026-11-14 at 07:42 UTC after the kernel 6.18 and XDP runs (deploy at 06:46), and verified empty with
direct describe calls (instances, Elastic IPs, ENIs, volumes, VPCs, peering, endpoints, the bucket, DynamoDB, Lambda,
IAM). To rerun, follow the README's Deploy section with the build and module of choice. `tf/natpair.tf` points at a
local checkout of the module, and `nat_kernel` picks the NATs' kernel line.
