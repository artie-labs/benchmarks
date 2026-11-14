#!/bin/bash
# Installs the natpair build pinned in the bench bucket on both NATs without replacing them: the standby first, then
# the owner, whose restart hands over to the standby. SHA is the archive's sha256.
. ./lib.sh
install_on() {
  on "$1" 120 "set -e; aws s3 cp --only-show-errors s3://$BUCKET/natpair/v0.1.99/natpair_linux_arm64.tar.gz /tmp/np.tgz
    echo '$SHA  /tmp/np.tgz' | sha256sum -c; rm -rf /tmp/np; mkdir /tmp/np; tar -C /tmp/np -xzf /tmp/np.tgz
    install -m 0755 /tmp/np/natpair /usr/local/bin/natpair; systemctl restart natpair; sha256sum /usr/local/bin/natpair | cut -c1-8"
}
wait_standby_ready || exit 1
owner=$(owner_nat)
standby=$(other_nat "$owner")
install_on "$standby"
wait_standby_ready || exit 1
install_on "$owner"
sleep 20
wait_standby_ready || exit 1
echo "owner now $(owner_nat)"
on "$(owner_nat)" 60 "ip -d link show ens6 | grep -o 'prog/xdp id [0-9]* name [a-z_]*'; ethtool -g ens6 | sed -n 8p; journalctl -u natpair -o cat --since '-2min' | grep -E 'overload guard|forwarding open' | cut -c1-220"
