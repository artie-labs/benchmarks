#!/bin/bash
# Profiles a NAT for the kernel 6.18 investigation (RESULTS.md, "Kernel 6.18 and XDP"). Started through SSM by
# jobs/k-prof.sh. Usage: env BUCKET=... AWS_REGION=... LABEL=<name> PHASE=setup|load|idle AT=<epoch> bash prof.sh
#
# setup installs perf and strace and records the kernel's settings. load and idle wait until AT, then take
# snapshots of /proc (the daemon's status, schedstat and threads, ksoftirqd, softirqs, stat), record PERF_SECS of
# perf on every CPU with call stacks, snapshot, summarize the daemon's system calls for TRACE_SECS with perf trace,
# log STRACE_SECS of them with strace (socket types included), and snapshot again. Reports are made REPORT_DELAY
# seconds after AT, once the load is over. Files go to s3://$BUCKET/runs/prof/$LABEL/$PHASE/.
set -u
PERF_SECS=${PERF_SECS:-20} TRACE_SECS=${TRACE_SECS:-20} STRACE_SECS=${STRACE_SECS:-3} REPORT_DELAY=${REPORT_DELAY:-0}
out=/tmp/natpair-bench-prof/$LABEL/$PHASE
rm -rf "$out"
mkdir -p "$out"
cd "$out" || exit 1
exec > log.txt 2>&1

if [[ $PHASE == setup ]]; then
  command -v perf > /dev/null || dnf install -y -q perf
  command -v strace > /dev/null || dnf install -y -q strace
  {
    uname -a
    cat /proc/cmdline
    perf --version
    strace -V | head -1
    cat /sys/kernel/debug/sched/preempt 2> /dev/null || echo "no sched/preempt"
    grep -E 'CONFIG_(PREEMPT|IRQ_TIME_ACCOUNTING|VIRT_CPU_ACCOUNTING|TICK_CPU_ACCOUNTING|HZ|NO_HZ|SCHED_|RCU_BOOST|SOFTIRQ|NET_RX_BUSY_POLL|ENA_ETHERNET|CONTEXT_TRACKING)' "/boot/config-$(uname -r)"
    for d in /sys/class/net/ens*; do
      i=${d##*/}
      echo "== $i"
      ethtool -i "$i"
      ethtool -l "$i"
      ethtool -c "$i" 2> /dev/null
      echo "threaded $(cat "$d/threaded" 2> /dev/null)"
    done
    sysctl net.core.netdev_budget net.core.netdev_budget_usecs net.core.dev_weight net.core.busy_poll \
      net.core.busy_read kernel.sched_autogroup_enabled 2> /dev/null
    grep -H . /sys/kernel/debug/sched/{base_slice_ns,latency_ns,min_granularity_ns,wakeup_granularity_ns} 2> /dev/null
    systemctl show natpair -p CPUWeight -p Nice -p CPUSchedulingPolicy -p Slice
  } > facts.txt 2>&1
  aws s3 cp --only-show-errors --recursive . "s3://$BUCKET/runs/prof/$LABEL/$(hostname)-setup/"
  exit 0
fi

pid=$(systemctl show -p MainPID --value natpair)
echo "natpair pid $pid"
now() { date +%s.%N; }
sleep_until() {
  local d
  d=$(awk -v t="$1" -v n="$(now)" 'BEGIN { d = t - n; if (d < 0) d = 0; print d }')
  sleep "$d"
}
# stat fields 14 and 15 are utime and stime in clock ticks. Thread and ksoftirqd names have no spaces.
proc_line() { echo "$1 $(cat "$2/comm") $(cat "$2/schedstat") $(cut -d' ' -f14,15 "$2/stat")"; }
snap() {
  local d=snap-$1 t k
  mkdir -p "$d"
  now > "$d/time"
  cat /proc/softirqs > "$d/softirqs"
  cat /proc/stat > "$d/stat"
  cat /proc/interrupts > "$d/interrupts"
  cat /proc/net/softnet_stat > "$d/softnet_stat"
  cat /proc/pressure/cpu > "$d/pressure_cpu" 2> /dev/null
  cat "/proc/$pid/status" > "$d/status"
  cat "/proc/$pid/schedstat" > "$d/schedstat"
  cat "/proc/$pid/sched" > "$d/sched" 2> /dev/null
  cat "/proc/$pid/stat" > "$d/pidstat"
  for t in /proc/"$pid"/task/*; do proc_line "${t##*/}" "$t"; done > "$d/tasks"
  for k in $(pgrep '^ksoftirqd/'); do proc_line "$k" "/proc/$k"; done > "$d/ksoftirqd"
  for k in $(pgrep '^napi/'); do proc_line "$k" "/proc/$k"; done > "$d/napi" 2> /dev/null
  for k in $(pgrep -x conntrackd); do proc_line "$k" "/proc/$k"; done > "$d/conntrackd"
}

sleep_until "$AT"
ls -l "/proc/$pid/fd" > fds.txt 2>&1
cat /proc/net/netlink > netlink.txt
ss -tuanp 2> /dev/null | grep "pid=$pid," > sockets.txt
snap 0
perf record -e cpu-clock -F 499 -a -g -o perf.data -- sleep "$PERF_SECS" 2> perf-record.err
snap 1
timeout -s INT "$TRACE_SECS" perf trace -s -p "$pid" -o trace-summary.txt 2> perf-trace.err
snap 2
timeout -s INT "$STRACE_SECS" strace -f -yy -tt -T -p "$pid" -o strace.txt 2> strace.err
snap 3

sleep_until "$(awk -v a="$AT" -v d="$REPORT_DELAY" 'BEGIN { print a + d }')"
perf report -i perf.data --stdio --no-children --sort comm -g none > report-comm.txt 2>&1
perf report -i perf.data --stdio --no-children --comm natpair --sort sym -g none --percent-limit 0.5 > report-natpair-self.txt 2>&1
perf report -i perf.data --stdio --children --comm natpair --sort sym -g none --percent-limit 2 > report-natpair-children.txt 2>&1
perf report -i perf.data --stdio --no-children --sort comm,sym -g none --percent-limit 0.5 > report-all-self.txt 2>&1
perf script -i perf.data -F comm,pid,tid,cpu,time,ip,sym 2> /dev/null | gzip > script.txt.gz
rm -f perf.data
gzip -f strace.txt
aws s3 cp --only-show-errors --recursive . "s3://$BUCKET/runs/prof/$LABEL/$PHASE/"
