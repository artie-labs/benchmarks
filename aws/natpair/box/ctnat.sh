#!/bin/bash
# Connection table helpers on a NAT, for jobs/ctsize.sh. Run as root with BUCKET and AWS_REGION set.
#
#   ctnat.sh resize <max>        sets max_connections by hand, as natpair bootstrap does at boot: the config file,
#                                nf_conntrack_max and nf_conntrack_buckets (a quarter), conntrackd's HashLimit and
#                                HashSize (a quarter), then restarts conntrackd
#   ctnat.sh buffers <bytes>     sets conntrackd's UDP RcvSocketBuffer and SndSocketBuffer, then restarts it
#   ctnat.sh snap                one line of memory and table figures, the time to dump each conntrackd cache, and
#                                the latest health round
#   ctnat.sh sample <name> <s>   samples once a second in the background for up to s seconds, or until
#                                `ctnat.sh stop`, then uploads s3://$BUCKET/runs/ctsize/<name>/<instance>.csv
#   ctnat.sh events <epoch>      natpair and conntrackd events since then: takeovers, step-downs, lease and copy
#                                warnings, table warnings, handoff steps
set -uo pipefail
conf=/var/lib/natpair/conntrackd.conf
ctd() { timeout "$1" conntrackd -C "$conf" "${@:2}"; }
# The daemon's process: `conntrackd -s` and similar commands, which natpair runs every round, have the same name.
main_pid() { systemctl show -p MainPID --value "$1"; }
rss() { local pid; pid=$(main_pid "$1") && awk -v p="$2" '$1 == p":" {print $2}' "/proc/$pid/status" 2> /dev/null || echo 0; }
mem() { awk -v k="$1:" '$1 == k {print $2}' /proc/meminfo; }
role() { [[ $(ls -d /sys/class/net/ens* | wc -l) -gt 1 ]] && echo owner || echo standby; }
# conntrackd -s: each cache's current entries, and the sync messages lost on the way from the peer.
caches() {
  ctd 5 -s 2> /dev/null | tr -s ' \t\n' ' ' |
    grep -o -E 'cache [a-z]+: current active connections: [0-9]+|[0-9]+ Lost msgs' |
    awk '$1 == "cache" {sub(":", "", $2); printf "%s=%s ", $2, $NF} $2 == "Lost" {printf "lost=%s ", $1}'
}

case $1 in
  resize)
    max=$2
    python3 -I -c '
import json, os, sys
path = "/etc/natpair/config.json"
config = json.load(open(path))
config["max_connections"] = int(sys.argv[1])
with open(path + ".tmp", "w") as f:
    json.dump(config, f, indent=2)
os.chmod(path + ".tmp", 0o600)
os.replace(path + ".tmp", path)' "$max" || exit 1
    natpair validate --config /etc/natpair/config.json > /dev/null || exit 1
    sysctl -qw "net.netfilter.nf_conntrack_max=$max" "net.netfilter.nf_conntrack_buckets=$((max / 4))" || exit 1
    sed -i -E "s/^( *HashSize ).*/\1$((max / 4))/; s/^( *HashLimit ).*/\1$max/" "$conf"
    systemctl restart conntrackd
    sleep 2
    echo "$(role) max $(sysctl -n net.netfilter.nf_conntrack_max) buckets $(sysctl -n net.netfilter.nf_conntrack_buckets)" \
      "$(grep -E 'Hash(Size|Limit)' "$conf" | xargs) conntrackd $(systemctl is-active conntrackd)"
    ;;
  buffers)
    # An experiment, not natpair's configuration: larger socket buffers for conntrackd's copies, so a full copy's
    # burst isn't dropped by the standby's 208 KB default receive buffer.
    bytes=$2
    sed -i -E '/^ *(Rcv|Snd)SocketBuffer /d' "$conf"
    sed -i -E "s/^( *)Checksum on/\1Checksum on\n\1RcvSocketBuffer $bytes\n\1SndSocketBuffer $bytes/" "$conf"
    systemctl restart conntrackd
    sleep 2
    echo "$(role) $(grep -E 'SocketBuffer' "$conf" | xargs) conntrackd $(systemctl is-active conntrackd)" \
      "$(ss -uanm 'sport = :3780' | grep -o 'rb[0-9]*,t[0-9]*,tb[0-9]*' | head -1)"
    ;;
  snap)
    # nf_conntrack's slab: active objects, objects, object size. Extensions (NAT, events) come from kmalloc slabs,
    # which only the total Slab figure shows.
    read -r active objs size < <(awk '$1 == "nf_conntrack" {print $2, $3, $4}' /proc/slabinfo)
    s=$(date +%s.%N); il=$(ctd 300 -i 2> /dev/null | wc -l); i_s=$(awk -v s="$s" -v e="$(date +%s.%N)" 'BEGIN {printf "%.2f", e - s}')
    s=$(date +%s.%N); el=$(ctd 300 -e 2> /dev/null | wc -l); e_s=$(awk -v s="$s" -v e="$(date +%s.%N)" 'BEGIN {printf "%.2f", e - s}')
    echo "role=$(role) count=$(cat /proc/sys/net/netfilter/nf_conntrack_count) max=$(cat /proc/sys/net/netfilter/nf_conntrack_max)" \
      "buckets=$(cat /proc/sys/net/netfilter/nf_conntrack_buckets) slab_active=$active slab_objs=$objs slab_objsize=$size" \
      "memtotal_kb=$(mem MemTotal) memavail_kb=$(mem MemAvailable) memfree_kb=$(mem MemFree) cached_kb=$(mem Cached)" \
      "slab_kb=$(mem Slab) sunreclaim_kb=$(mem SUnreclaim) vmalloc_kb=$(mem VmallocUsed)" \
      "ctd_rss_kb=$(rss conntrackd VmRSS) ctd_hwm_kb=$(rss conntrackd VmHWM) natpair_rss_kb=$(rss natpair VmRSS)" \
      "natpair_hwm_kb=$(rss natpair VmHWM) $(caches)dump_i_lines=$il dump_i_s=$i_s dump_e_lines=$el dump_e_s=$e_s" \
      "$(conntrack -S 2> /dev/null | tr ' ' '\n' | awk -F= '$1 == "drop" {d += $2} $1 == "early_drop" {e += $2} END {printf "ct_drop=%d ct_early_drop=%d", d, e}')"
    journalctl -u natpair -o cat | grep '"health round"' | tail -1 | cut -c1-700
    ;;
  sample)
    name=$2 seconds=$3
    rm -f /tmp/ctsample.stop
    instance=$(cat /var/lib/cloud/data/instance-id)
    (
      out=/tmp/ctsample-$name.csv
      echo "t,role,memavail_kb,slab_kb,count,ctd_rss_kb,natpair_rss_kb,busy_ticks,idle_ticks,ctd_ticks,natpair_ticks,ens5_rx_bytes,ens5_tx_bytes,ens5_rx_packets,ens5_tx_packets,ens6_rx_bytes,ens6_tx_bytes,ens6_rx_packets,ens6_tx_packets,ctd_internal,ctd_external,ct_drop" > "$out"
      end=$((SECONDS + seconds))
      while ((SECONDS < end)) && [[ ! -e /tmp/ctsample.stop ]]; do
        cpu=$(awk '$1 == "cpu" {print $2 + $3 + $4 + $7 + $8 + $9 "," $5 + $6}' /proc/stat)
        ticks() { local pid; pid=$(main_pid "$1") && awk '{sub(/.*\) /, ""); print $12 + $13}' "/proc/$pid/stat" 2> /dev/null || echo 0; }
        net() { local d=/sys/class/net/$1/statistics; [[ -d $d ]] && echo "$(cat $d/rx_bytes),$(cat $d/tx_bytes),$(cat $d/rx_packets),$(cat $d/tx_packets)" || echo 0,0,0,0; }
        c=$(caches)
        internal=$(grep -o 'internal=[0-9]*' <<< "$c" | cut -d= -f2)
        external=$(grep -o 'external=[0-9]*' <<< "$c" | cut -d= -f2)
        drop=$(conntrack -S 2> /dev/null | tr ' ' '\n' | awk -F= '$1 == "drop" {d += $2} END {print d + 0}')
        echo "$(date +%s.%N),$(role),$(mem MemAvailable),$(mem Slab),$(cat /proc/sys/net/netfilter/nf_conntrack_count),$(rss conntrackd VmRSS),$(rss natpair VmRSS),$cpu,$(ticks conntrackd),$(ticks natpair),$(net ens5),$(net ens6),${internal:-},${external:-},$drop" >> "$out"
        sleep 1
      done
      aws s3 cp --only-show-errors --region "$AWS_REGION" "$out" "s3://$BUCKET/runs/ctsize/$name/$instance.csv"
    ) > /dev/null 2>&1 &
    disown
    echo "sampling $name on $instance for up to $seconds s"
    ;;
  stop)
    touch /tmp/ctsample.stop
    ;;
  events)
    since=$2
    j=$(journalctl -u natpair -u conntrackd --since "@$since" -o short-iso-precise --no-pager)
    count() { grep -c -E "$1" <<< "$j"; }
    echo "acquired=$(count 'ownership acquired') ended=$(count 'ownership session ended') lease=$(count 'lease (store unreachable|renewal failed)')" \
      "not_answering=$(count 'conntrackd is not answering') incomplete=$(count 'copied connections are incomplete')" \
      "nearly_full=$(count 'connection table is nearly full') full=$(count 'connection table is full') path_alive=$(count 'path is alive')" \
      "handoff=$(count 'handoff step') unhealthy=$(grep '"health round"' <<< "$j" | grep -c '"healthy":false') not_ready=$(grep '"health round"' <<< "$j" | grep -c '"ready":false')" \
      "kernel_table_full=$(dmesg | grep -c 'table full')"
    grep -E 'ownership acquired|ownership session ended|handoff step|lease|not answering|incomplete|connection table is|copied connections|taking over|failed' <<< "$j" | cut -c1-330 | tail -20
    ;;
  *)
    echo "usage: ctnat.sh resize <max> | snap | sample <name> <seconds> | stop | events <epoch>" >&2
    exit 2
    ;;
esac
