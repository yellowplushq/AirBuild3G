#!/bin/sh
# Copy hello_on_device.sh to the phone and run it: compile, sign, package,
# install and launch a UIKit app using only the toolchain AirBuild installed.
#
# Usage: tools/hello_device.sh [user@host] [password]

set -e

DEVICE="$1"
PASSWORD="${2:-alpine}"
if [ -z "$DEVICE" ]; then
	echo "usage: $0 user@host [password]" >&2
	exit 1
fi
HERE="$(cd "$(dirname "$0")" && pwd)"

# iOS 4's ssh predates every algorithm a current client offers by default.
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
	-o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 \
	-o ConnectTimeout=10 -o LogLevel=ERROR"

sshpass -p "$PASSWORD" scp $SSHOPT "$HERE/hello_on_device.sh" "$DEVICE:/tmp/"

# \$? is escaped so the *inner* sh expands it. Unescaped, the outer remote
# shell substituted the status of the preceding rm -f, which is always 0, and
# this script reported PASS for every possible build failure.
#
# Detached, like the installer: compiling on a 128 MB single-core phone takes
# long enough that the connection can drop first, and a build killed by SIGHUP
# tells you nothing about whether the toolchain works.
sshpass -p "$PASSWORD" ssh $SSHOPT "$DEVICE" \
	'rm -f /tmp/hello.log
	 sh -c "trap \"\" HUP; sh /tmp/hello_on_device.sh 2>&1; echo HELLO-DONE-\$?" < /dev/null > /tmp/hello.log 2>&1 &
	 echo started'

echo "building on the device; polling"
tries=0
while [ $tries -lt 90 ]; do
	out=$(sshpass -p "$PASSWORD" ssh $SSHOPT "$DEVICE" 'cat /tmp/hello.log 2>/dev/null' 2>/dev/null || true)
	case "$out" in
		*HELLO-DONE-*) echo "$out"; break ;;
	esac
	tries=$((tries + 1))
	sleep 10
done
[ $tries -lt 90 ] || { echo "build did not finish in 15 minutes" >&2; exit 1; }

case "$out" in
	*HELLO-DONE-0*) echo "PASS: built and installed an app on the phone" ;;
	*) echo "FAIL: see the log above" >&2; exit 1 ;;
esac
