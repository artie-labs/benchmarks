#!/bin/bash
# Installs another natpair build on both NATs without replacing them, the standby first, then the owner, whose restart
# hands over to the standby. Prepend KEY=<archive name under natpair/builds/ in the bucket> and SHA=<its sha256>.
. ./lib.sh
install_on() {
  on "$1" 180 "set -e; aws s3 cp --only-show-errors s3://$BUCKET/natpair/builds/${KEY:?} /tmp/np.tgz
    echo '${SHA:?}  /tmp/np.tgz' | sha256sum -c; rm -rf /tmp/np; mkdir /tmp/np; tar -C /tmp/np -xzf /tmp/np.tgz
    install -m 0755 /tmp/np/natpair /usr/local/bin/natpair; systemctl restart natpair
    echo \"$1 binary \$(sha256sum /usr/local/bin/natpair | cut -c1-8)\""
}
wait_standby_ready || exit 1
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
