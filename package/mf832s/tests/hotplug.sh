#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d /tmp/mf832s-hotplug.XXXXXX) || exit 1
mkdir -p "$TMP/sys/devices/target/port/tty" "$TMP/sys/devices/other/port/net" \
	"$TMP/sys/devices/target/port/net" "$TMP/sys/devices/other/port/tty"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
sed "s|/sys|$TMP/sys|g" "$ROOT/package/mf832s/files/hotplug.sh" >"$TMP/helper"
for hook in 20-mf832s 20-mf832s-net 20-mf832s-tty; do
	sed "s|/usr/share/mf832s/hotplug.sh|$TMP/helper|" "$ROOT/package/mf832s/files/$hook" >"$TMP/$hook"
done
TRACE=$TMP/trace
uci() {
	case "$*" in
		'-q get mf832s.main.vid') printf '%s\n' "${TEST_VID:-19d2}";;
		'-q get mf832s.main.pid') printf '%s\n' "${TEST_PID:-0199}";;
		*) return 1;;
	esac
}
kill() { [ "$*" = '-l USR1' ] && printf '10\n'; }
ubus() { printf '%s\n' "$*" >>"$TRACE"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_hook() {
	: >"$TRACE"
	vid=outer-vid pid=outer-pid signal=outer-signal path=outer-path
	. "$TMP/$hook"
	[ "$vid:$pid:$signal:$path" = outer-vid:outer-pid:outer-signal:outer-path ] ||
		fail 'sourced hook leaked helper variables'
	! command -v mf832s_target_event >/dev/null 2>&1 ||
		fail 'sourced hook leaked helper function'
	actual=$(wc -l <"$TRACE")
	[ "$actual" = "$1" ] || fail "$hook $ACTION PRODUCT=$PRODUCT DEVPATH=$DEVPATH: expected $1 wake, got $actual"
}
printf '19d2\n' >"$TMP/sys/devices/target/idVendor"
printf '0199\n' >"$TMP/sys/devices/target/idProduct"
printf '1234\n' >"$TMP/sys/devices/other/idVendor"
printf '5678\n' >"$TMP/sys/devices/other/idProduct"
for hook in 20-mf832s 20-mf832s-net 20-mf832s-tty; do
	ACTION=add PRODUCT=19D2/199/0 DEVPATH=''
	expect_hook 1
	PRODUCT=1234/5678/0
	expect_hook 0
	PRODUCT=''
	for kind in tty net; do
		DEVPATH=/devices/target/port/$kind
		expect_hook 1
		DEVPATH=/devices/other/port/$kind
		expect_hook 0
	done
	ACTION=remove DEVPATH=/devices/already-removed/port
	expect_hook 1
	PRODUCT=1234/5678/0
	expect_hook 0
	ACTION=change PRODUCT=19d2/0199/0
	expect_hook 0
done
TEST_VID=ABCD TEST_PID=00EF ACTION=add PRODUCT=abcd/ef/0 DEVPATH=''
expect_hook 1
PRODUCT=19d2/199/0
expect_hook 0
printf 'ok - USB/net/tty hooks share padded VID/PID and sysfs-ancestor filtering; unknown removal wakes conservatively\n'
printf 'ok - sourced hooks preserve caller variables, functions and control flow\n'

# Execute the actual package install recipe without requiring the OpenWrt SDK.
sed -n '/^define Package\/mf832s\/install$/,/^endef$/p' "$ROOT/package/mf832s/Makefile" |
	sed "1d; \$d; s|\$(INSTALL_DIR)|install -d|g; s|\$(INSTALL_DATA)|install -m 644|g; s|\$(INSTALL_BIN)|install -m 755|g; s|\$(1)|$TMP/image|g" \
	>"$TMP/install"
( cd "$ROOT/package/mf832s" && sh "$TMP/install" )
for mapping in \
	'hotplug.sh usr/share/mf832s/hotplug.sh' \
	'20-mf832s etc/hotplug.d/usb/20-mf832s' \
	'20-mf832s-net etc/hotplug.d/net/20-mf832s' \
	'20-mf832s-tty etc/hotplug.d/tty/20-mf832s' \
	'20-mf832s-iface etc/hotplug.d/iface/20-mf832s'; do
	set -- $mapping
	cmp "$ROOT/package/mf832s/files/$1" "$TMP/image/$2" ||
		fail "package did not install $1 at $2"
done
printf 'ok - package install recipe installs shared helper and all four hotplug classes\n'
