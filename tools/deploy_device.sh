#!/bin/sh
# Install AirBuild3G and its bootstrap payload on a jailbroken iPhone 3G/3GS.
#
# Usage: tools/deploy_device.sh [user@host] [password]
#
# The app deb is small and always re-copied. The payload is ~46 MB over
# 802.11g, so it is only copied when the device does not already have the
# same file (compared by size, since the 3G has no sha256sum until the
# payload itself installs coreutils).

set -e

DEVICE="$1"
PASSWORD="${2:-alpine}"
if [ -z "$DEVICE" ]; then
	echo "usage: $0 user@host [password] [ios4|ios6]" >&2
	exit 1
fi
# Which build environment this phone gets. bootstrap4 is armv6/iOS 4,
# bootstrap6 is armv7/iOS 5+; the two packages Conflict, so only one lands.
TARGET="${3:-ios4}"
BUILD="$(cd "$(dirname "$0")/.." && pwd)/build"

APP_DEB="$BUILD/com.apple.airbuild.oss_1.0.0_iphoneos-arm.deb"
PAYLOAD_DEB="$BUILD/com.apple.airbuild.oss.bootstrap${TARGET#ios}_1.0.0_iphoneos-arm.deb"

# iOS 4's dropbear/OpenSSH predates every algorithm a modern client offers.
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
	-o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 \
	-o ConnectTimeout=10 -o LogLevel=ERROR"

run() { sshpass -p "$PASSWORD" ssh $SSHOPT "$DEVICE" "$@"; }
put() { sshpass -p "$PASSWORD" scp $SSHOPT "$1" "$DEVICE:$2"; }

for f in "$APP_DEB" "$PAYLOAD_DEB"; do
	[ -f "$f" ] || { echo "missing $f — run make deb && make payload" >&2; exit 1; }
done

echo "== device =="
run 'echo "uname:  $(uname -srm)"
     echo "model:  $(uname -n)"
     echo "date:   $(date)"
     df -k / /private/var | sed "s/^/df:     /"'

echo
echo "== copying =="
put "$APP_DEB" /tmp/airbuild.deb

# A phone that has not run the payload yet has no wc, awk, cut or stat --
# coreutils arrives *in* the payload. ls and sed are all that can be assumed,
# so the size comes out of ls -l's fifth field.
SIZE_OF="ls -l /tmp/airbuild-bootstrap.deb 2>/dev/null | \
	sed -n 's/^[^ ][^ ]* *[^ ][^ ]* *[^ ][^ ]* *[^ ][^ ]* *\\([0-9][0-9]*\\).*/\\1/p'"

want=$(wc -c < "$PAYLOAD_DEB" | tr -d ' ')
have=$(run "$SIZE_OF" | tr -d ' \r')
[ -n "$have" ] || have=0
if [ "$want" = "$have" ]; then
	echo "payload already on device ($have bytes), skipping copy"
else
	echo "payload $want bytes (device has $have) — copying, this takes a while"
	put "$PAYLOAD_DEB" /tmp/airbuild-bootstrap.deb
fi

# TLSFix (from the payload cache) goes first, and only if the phone lacks it;
# one that is there at any version is left alone.
#
# Substrate is the app's other runtime dependency and this script does not
# install it: no third-party binary is shipped here, and every phone the
# Legacy-iOS-Kit jailbreaks has it already. See INSTALL.md.
SYSTEM_DEBS=""
for f in "$BUILD/payload/cache/com.skyglow.tlsfix_"*.deb; do
	[ -f "$f" ] || continue
	id=$(basename "$f" | sed 's/_.*//')
	if run "dpkg -s $id 2>/dev/null | grep -q '^Status: install ok installed'"; then
		echo "$id already installed, skipping"
	else
		put "$f" "/tmp/airbuild-$id.deb"
		SYSTEM_DEBS="$SYSTEM_DEBS /tmp/airbuild-$id.deb"
	fi
done
SYSTEM_LINE=""
[ -z "$SYSTEM_DEBS" ] || SYSTEM_LINE="dpkg -i $SYSTEM_DEBS 2>&1 || status=1"
# A running AirBuild is ended at the end so the next launch is the new binary.
# Nothing resprings: the app loads TLSFix itself before every request, and
# Substrate is not installed from here.

echo
echo "== installing =="

# Every $ inside the double-quoted sh -c is escaped so the *inner* shell
# expands it. Unescaped, the outer remote shell substitutes its own (empty)
# value and the status check silently tests nothing.
#
# dpkg runs detached, not as a child of this ssh session. Inflating 110 MB of
# gzip takes long enough on a 128 MB phone that the connection can drop first,
# and a dpkg killed by SIGHUP leaves the package half-unpacked. Detached by
# hand (trap HUP, stdin from /dev/null, output to the log), not with nohup:
# that is coreutils, and a phone that has never run the Environment page does
# not have it. We then poll the log.
run "rm -f /tmp/airbuild-install.log
     sh -c \"
        trap '' HUP
        status=0
        dpkg --configure -a 2>&1
        $SYSTEM_LINE
        dpkg -i /tmp/airbuild.deb 2>&1 || status=1
        dpkg -i /tmp/airbuild-bootstrap.deb 2>&1 || status=1
        su mobile -c uicache 2>&1 || status=1
        killall AirBuild3G 2>/dev/null && echo 'restarted AirBuild3G'
        [ \\\$status -eq 0 ] && rm -f $SYSTEM_DEBS /tmp/airbuild.deb /tmp/airbuild-bootstrap.deb
        echo AIRBUILD-INSTALL-DONE-\\\$status
     \" < /dev/null > /tmp/airbuild-install.log 2>&1 &
     echo started"

echo "installing in the background on the device; polling"
tries=0
while [ $tries -lt 180 ]; do
	out=$(run 'cat /tmp/airbuild-install.log 2>/dev/null' 2>/dev/null || true)
	case "$out" in
		*AIRBUILD-INSTALL-DONE-*) echo "$out"; break ;;
	esac
	tries=$((tries + 1))
	sleep 10
done
[ $tries -lt 180 ] || { echo "install did not finish in 30 minutes" >&2; exit 1; }
case "$out" in
	*AIRBUILD-INSTALL-DONE-0*) ;;
	*) echo "install failed on the device; see the log above" >&2; exit 1 ;;
esac

run 'echo "installed:"
     dpkg -l | grep -i airbuild
     echo
     echo "payload:"
     ls -l /var/airbuild/bootstrap/
     echo
     df -k / /private/var'

echo
echo "== launching =="
# uiopen takes a URL and nothing else; a bundle identifier gets the user an
# "unsupported URL" prompt on the phone. ab:// is the scheme the app registers.
run 'uiopen ab://'
echo "done"
