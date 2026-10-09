#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export MF832S_SYS_USB_ROOT="$TMP/sys/bus/usb/devices"
export MF832S_SYS_TTY_ROOT="$TMP/sys/class/tty"
export MF832S_SYS_NET_ROOT="$TMP/sys/class/net"
export MF832S_DEV_ROOT="$TMP/dev"
export MF832S_RUN_DIR="$TMP/run"
export CHAT_CAPTURE="$TMP/chat-config"
mkdir -p "$MF832S_SYS_USB_ROOT" "$MF832S_DEV_ROOT" "$MF832S_RUN_DIR" "$TMP/bin"
. "$ROOT/usr/sbin/mf832s-monitor"

DEVICE="$MF832S_SYS_USB_ROOT/1-1"
mkdir -p "$DEVICE"
printf '19d2\n' >"$DEVICE/idVendor"
printf '0199\n' >"$DEVICE/idProduct"
printf '1\n' >"$DEVICE/busnum"
printf '4\n' >"$DEVICE/devnum"
: >"$MF832S_DEV_ROOT/ttyUSB2"
USB_ROOT=$(readlink -f "$DEVICE")
DEVICE_KEY="$USB_ROOT:1:4"
VENDOR=19d2
PRODUCT_ID=199
AT_PORT=/dev/ttyUSB2
APN=test.apn
CHAT_PID=
STOPPING=0

at_context_active() {
	return 2
}

cat >"$TMP/bin/chat" <<'EOF'
#!/bin/sh
cat "$2" >"$CHAT_CAPTURE"
exec sleep 30
EOF
chmod +x "$TMP/bin/chat"
PATH="$TMP/bin:$PATH"
export PATH

(
	sleep 1
	rm -rf "$DEVICE"
) &
REMOVE_PID=$!
if activate_pdp; then
	echo "PDP operation continued after USB removal" >&2
	exit 1
fi
wait "$REMOVE_PID"
[ ! -e "$DEVICE" ] || {
	echo "USB-removal fixture failed" >&2
	exit 1
}
grep -q 'AT+CGDCONT=1,"IPV4V6","test.apn"' "$CHAT_CAPTURE" || {
	echo "validated APN was not passed to chat" >&2
	exit 1
}
[ ! -e "$MF832S_RUN_DIR/connect.chat" ] || {
	echo "temporary chat configuration was not cleaned up" >&2
	exit 1
}
echo "ok - cancel in-flight chat on USB removal"
