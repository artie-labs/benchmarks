#!/bin/bash
# Installs another natpair build on both NATs without replacing them, the standby first, then the owner, whose restart
# hands over to the standby. Prepend KEY=<archive name under natpair/builds/ in the bucket>, SHA=<its sha256> and
# IRQBALANCE=on|off. off disables and stops irqbalance, as natpair#10's install script and the reboot after it leave
# a new NAT. on enables and starts it, as the AMI leaves a NAT without #10.
. ./lib.sh
case ${IRQBALANCE:?} in
  on) irqcmd="systemctl enable --now irqbalance" ;;
  off) irqcmd="systemctl disable --now irqbalance" ;;
esac
install_on() {
  on "$1" 180 "set -e; aws s3 cp --only-show-errors s3://$BUCKET/natpair/builds/${KEY:?} /tmp/np.tgz
    echo '${SHA:?}  /tmp/np.tgz' | sha256sum -c; rm -rf /tmp/np; mkdir /tmp/np; tar -C /tmp/np -xzf /tmp/np.tgz
    $irqcmd 2>&1; install -m 0755 /tmp/np/natpair /usr/local/bin/natpair; systemctl restart natpair
    echo \"binary \$(sha256sum /usr/local/bin/natpair | cut -c1-8) irqbalance \$(systemctl is-active irqbalance) \$(systemctl is-enabled irqbalance)\""
}
wait_standby_ready || exit 1
for nat in "$NAT_A" "$NAT_B"; do
  on "$nat" 30 "pkill -TERM -f irqwatch.sh; true" > /dev/null
done
owner=$(owner_nat)
standby=$(other_nat "$owner")
install_on "$standby"
# The last health round in the journal may still be the old process's, so give the new one time to report.
sleep 30
wait_standby_ready || exit 1
install_on "$owner"
sleep 20
wait_standby_ready || exit 1
echo "owner now $(owner_nat)"
