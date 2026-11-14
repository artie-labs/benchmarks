#!/bin/bash
# natpair#16's cost below saturation: TCP uploads at a fixed rate (8 Gbps on the large, 4 on the medium) and 64-byte
# UDP at a fixed rate (400k and 300k packets a second), 45 s each, NATs sampled once a second, threaded NAPI on the
# owner off then on, 3 rounds. The same rates as phase 3's p3-cost.
#
# #16 has no off switch and turns threaded NAPI back on within 5 s. So "off" writes 0 to each ENI's real threaded
# file on the owner and bind-mounts a file holding 1 over it: the daemon reads 1 and writes nothing. A second sysfs
# mount at /run/bench-sys shows the real values, which host.sh records and the job log prints. "on" removes the
# mounts (mountinfo lists them under the resolved /sys/devices path), and the daemon turns threaded NAPI back on within 5 s.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
case $t in
  c7gn.large) tcp=250M udp=3.2M ;;
  *) tcp=125M udp=2.4M ;;
esac
napi_off() {
  on "$1" 60 'mkdir -p /run/bench-sys; mountpoint -q /run/bench-sys || mount -t sysfs sysfs /run/bench-sys
    for d in /sys/class/net/*; do
      [ -e "$d/device" ] || continue; n=${d##*/}; f=$(realpath "$d/threaded")
      grep -q " $f " /proc/self/mountinfo && continue
      echo 1 > /run/bench-threaded-$n; echo 0 > "$f"; mount --bind /run/bench-threaded-$n "$f"
    done
    grep -H . /run/bench-sys/class/net/ens*/threaded'
}
napi_on() {
  on "$1" 60 'for d in /sys/class/net/*; do f=$(realpath "$d/threaded"); grep -q " $f " /proc/self/mountinfo && umount "$f"; done
    mountpoint -q /run/bench-sys && umount /run/bench-sys; sleep 6; grep -H . /sys/class/net/ens*/threaded'
}
wait_standby_ready || exit 1
owner=$(owner_nat)
for k in 1 2 3; do
  for mode in off on; do
    if [[ $mode == off ]]; then napi_off "$owner"; else napi_on "$owner"; fi
    ./run.sh "$t-napi-cost-$mode-tcpfixed-$k" MODE=up PROCS=1 STREAMS=16 RATE=$tcp DURATION=45 POLL=1s
    ./run.sh "$t-napi-cost-$mode-udpfixed-$k" MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=$udp DURATION=45 POLL=1s
  done
done
napi_on "$owner"
[[ $(owner_nat) == "$owner" ]] || echo "owner moved during napi-cost: from $owner to $(owner_nat)"
