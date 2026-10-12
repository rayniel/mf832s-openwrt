#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TMP=$ROOT/package/mf832s/tests/.status.$$
mkdir "$TMP"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir "$TMP/bin"
cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	'-q get mf832s.main.interface') echo "${TEST_SELECTOR-mf832s}";;
	'-q get mf832s.main.enabled') echo 1;;
	'-q get mf832s.main.at_interface'|'-q get mf832s.main.at_device') echo;;
	'-q get network.4G') echo interface;;
	'-q get network.4G.proto') echo dhcp;;
	'-q get network.4G.device') echo eth1;;
	'-q get network.4G.ifname') echo;;
	'-q get network.Second') echo interface;;
	'-q get network.Second.proto') echo dhcp;;
	'-q get network.Second.device') echo eth1;;
	'-q show network')
		[ "${TEST_BINDINGS-single}" != none ] || exit 0
		echo network.4G=interface
		[ "${TEST_BINDINGS-single}" != multiple ] || echo network.Second=interface;;
	*) exit 1;;
esac
EOF
chmod +x "$TMP/bin/uci"
mkdir -p "$TMP/sys/bus/usb/devices/1-2" "$TMP/sys/class/net/eth1" "$TMP/sys/class/tty"
printf '19d2\n' >"$TMP/sys/bus/usb/devices/1-2/idVendor"
printf '0199\n' >"$TMP/sys/bus/usb/devices/1-2/idProduct"
ln -s "$TMP/sys/bus/usb/devices/1-2" "$TMP/sys/class/net/eth1/device"
sed \
	-e "s|PATH=/usr/sbin:/usr/bin:/sbin:/bin|PATH=$TMP/bin:/usr/sbin:/usr/bin:/sbin:/bin|" \
	-e "s|STATUS_FILE=/var/run/mf832s/status|STATUS_FILE=$TMP/status|" \
	-e "s|/sys/|$TMP/sys/|g" \
	"$ROOT/package/mf832s/files/mf832s-status" >"$TMP/status-cli"
chmod +x "$TMP/status-cli"
sh -n "$TMP/status-cli"
cat >"$TMP/status" <<'EOF'
service=failed
pid=99999999
instance=/var/run/mf832s/instance.old
target=mf832s
configured_net=
target_device=eth1
usb=
at=
net=
stage=online
reason=quote " slash \\
stage_started=100
updated=200
retry_at=0
lease_deadline=0
has_ipv4=true
health=healthy
EOF
"$TMP/status-cli" --json >"$TMP/json"
grep -F '"service":"failed"' "$TMP/json" >/dev/null
grep -F '"has_ipv4":false' "$TMP/json" >/dev/null
grep -F 'quote \" slash' "$TMP/json" >/dev/null
grep -F 'slash \\\\' "$TMP/json" >/dev/null
"$TMP/status-cli" --check 4G >"$TMP/check"
grep -F 'MISMATCH: service targets mf832s, not 4G' "$TMP/check" >/dev/null
grep -F 'network.4G device=eth1' "$TMP/check" >/dev/null
grep -F 'AUTO: AT-only discovery' "$TMP/check" >/dev/null
TEST_SELECTOR='' "$TMP/status-cli" --check >"$TMP/check-auto"
grep -F 'AUTO: no logical interface name is required' "$TMP/check-auto" >/dev/null
grep -F 'OK: automatic target is 4G (device=eth1)' "$TMP/check-auto" >/dev/null
grep -F 'Configuration diagnostics for candidate 4G' "$TMP/check-auto" >/dev/null
! grep -F 'MISMATCH:' "$TMP/check-auto" >/dev/null
! grep -F 'BLOCKED: no explicit AT' "$TMP/check-auto" >/dev/null
TEST_SELECTOR='' TEST_BINDINGS=none "$TMP/status-cli" --check >"$TMP/check-none"
grep -F 'WAITING: no unique USB data device with a matching DHCP binding' "$TMP/check-none" >/dev/null
TEST_SELECTOR='' TEST_BINDINGS=multiple "$TMP/status-cli" --check >"$TMP/check-multiple"
grep -F 'BLOCKED: multiple matching DHCP interfaces' "$TMP/check-multiple" >/dev/null
TEST_SELECTOR=4G TEST_BINDINGS=multiple "$TMP/status-cli" --check >"$TMP/check-explicit"
grep -F 'OK: service target matches 4G' "$TMP/check-explicit" >/dev/null
! grep -F 'BLOCKED: multiple matching DHCP interfaces' "$TMP/check-explicit" >/dev/null
mkdir "$TMP/sys/bus/usb/devices/1-3"
printf '19d2\n' >"$TMP/sys/bus/usb/devices/1-3/idVendor"
printf '0199\n' >"$TMP/sys/bus/usb/devices/1-3/idProduct"
TEST_SELECTOR='' "$TMP/status-cli" --check >"$TMP/check-usb-multiple"
! grep -F 'OK: automatic target' "$TMP/check-usb-multiple" >/dev/null
grep -F '2 matching devices' "$TMP/check-usb-multiple" >/dev/null
printf 'ok - status JSON is escaped, stale instances cannot report IPv4, and 4G diagnostics are explicit\n'
printf 'ok - automatic diagnostics cover unique/absent/ambiguous DHCP binding and physical USB ambiguity\n'
