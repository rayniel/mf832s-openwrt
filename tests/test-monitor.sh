#!/bin/sh

# shellcheck disable=SC2218 # The worker functions are loaded by sourcing the monitor.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export MF832S_SYS_USB_ROOT="$TMP/sys/bus/usb/devices"
export MF832S_SYS_TTY_ROOT="$TMP/sys/class/tty"
export MF832S_SYS_NET_ROOT="$TMP/sys/class/net"
export MF832S_DEV_ROOT="$TMP/dev"
export MF832S_RUN_DIR="$TMP/run"
mkdir -p "$MF832S_SYS_USB_ROOT" "$MF832S_SYS_TTY_ROOT" "$MF832S_SYS_NET_ROOT" "$MF832S_DEV_ROOT"
. "$ROOT/usr/sbin/mf832s-monitor"

fail() {
	printf 'not ok - %s\n' "$*" >&2
	exit 1
}

assert() {
	"$@" || fail "$*"
}

DEVICE="$MF832S_SYS_USB_ROOT/1-1"
USB_CALLS=
LEASE=0
REGISTRATION=1
PDP_RESULT=0
PDP_CALLS=0
CONFIG_ENABLED=1
CONFIG_APN=test.apn
INTERFACE_UP=0
STATUS_MODE=normal
NETWORK_PROTO=dhcp

reset_state() {
	DEVICE_KEY=
	NETWORK_REQUESTED=0
	DHCP_DEADLINE=0
	PDP_ATTEMPTED=0
	FAILURES=0
	RETRY_AT=0
	NEXT_HEALTH=0
}

make_device() {
	rm -rf "$DEVICE"
	mkdir -p "$DEVICE/1-1:1.2/ttyUSB2" "$DEVICE/1-1:1.0"
	printf '19d2\n' >"$DEVICE/idVendor"
	printf '0199\n' >"$DEVICE/idProduct"
	printf '1\n' >"$DEVICE/busnum"
	printf '%s\n' "${1:-4}" >"$DEVICE/devnum"
}

make_ports() {
	mkdir -p "$MF832S_SYS_TTY_ROOT/ttyUSB2" "$MF832S_SYS_NET_ROOT/wwan0"
	ln -sfn "$DEVICE/1-1:1.2/ttyUSB2" "$MF832S_SYS_TTY_ROOT/ttyUSB2/device"
	ln -sfn "$DEVICE/1-1:1.0" "$MF832S_SYS_NET_ROOT/wwan0/device"
	: >"$MF832S_DEV_ROOT/ttyUSB2"
}

uci_value() {
	case "$1" in
		enabled) printf '%s\n' "$CONFIG_ENABLED" ;;
		vendor) printf '19d2\n' ;;
		product) printf '0199\n' ;;
		at_port) printf '/dev/ttyUSB2\n' ;;
		network) printf 'cellular\n' ;;
		data_device) printf 'wwan0\n' ;;
		apn) printf '%s\n' "$CONFIG_APN" ;;
		*) return 1 ;;
	esac
}

uci() {
	case "$*" in
		*"network.cellular.proto"*) printf '%s\n' "$NETWORK_PROTO" ;;
		*"network.cellular.device"*) printf 'wwan0\n' ;;
		*) return 1 ;;
	esac
}

is_char_device() {
	[ -e "$1" ]
}

ubus() {
	case "$*" in
		*" status"*)
			if [ "$STATUS_MODE" = invalid ]; then
				printf 'not-json\n'
			elif [ "$LEASE" = 1 ]; then
				printf '{"up":true,"ipv4-address":[{"address":"192.0.2.2"}]}\n'
			elif [ "$INTERFACE_UP" = 1 ]; then
				printf '{"up":true,"ipv4-address":[]}\n'
			else
				printf '{"up":false,"ipv4-address":[]}\n'
			fi
			;;
		*" up") INTERFACE_UP=1; USB_CALLS="${USB_CALLS}up " ;;
		*" down") INTERFACE_UP=0; USB_CALLS="${USB_CALLS}down " ;;
		*) return 1 ;;
	esac
}

at_registration() {
	case "$REGISTRATION" in
		1|5) return 0 ;;
		0|2|3|4) return 2 ;;
		*) return 1 ;;
	esac
}

activate_pdp() {
	PDP_CALLS=$((PDP_CALLS + 1))
	return "$PDP_RESULT"
}

log() {
	:
}

load_config || fail "valid monitor configuration rejected"
network_config_ready || fail "valid DHCP netifd binding rejected"

# Ignore unrelated devices and do not touch netifd.
mkdir -p "$MF832S_SYS_USB_ROOT/2-1"
printf '1234\n' >"$MF832S_SYS_USB_ROOT/2-1/idVendor"
printf '5678\n' >"$MF832S_SYS_USB_ROOT/2-1/idProduct"
printf '1\n' >"$MF832S_SYS_USB_ROOT/2-1/busnum"
printf '2\n' >"$MF832S_SYS_USB_ROOT/2-1/devnum"
reset_state
process_once 100
[ -z "$USB_CALLS" ] || fail "unrelated USB device touched netifd"

# Multiple devices with the configured identity are ambiguous and fail closed.
make_device
mkdir -p "$MF832S_SYS_USB_ROOT/3-1"
printf '19d2\n' >"$MF832S_SYS_USB_ROOT/3-1/idVendor"
printf '0199\n' >"$MF832S_SYS_USB_ROOT/3-1/idProduct"
printf '1\n' >"$MF832S_SYS_USB_ROOT/3-1/busnum"
printf '8\n' >"$MF832S_SYS_USB_ROOT/3-1/devnum"
reset_state
process_once 105
[ -z "$USB_CALLS" ] || fail "ambiguous modem identity touched netifd"
rm -rf "$MF832S_SYS_USB_ROOT/3-1"

# Discover an already-inserted device and wait for late serial/network nodes.
reset_state
process_once 100
[ "$NETWORK_REQUESTED" = 0 ] || fail "worker acted before ports were ready"
make_ports
# Both configured endpoint names must resolve beneath the matching USB device.
ln -sfn "$MF832S_SYS_USB_ROOT/2-1" "$MF832S_SYS_TTY_ROOT/ttyUSB2/device"
process_once 105
[ "$NETWORK_REQUESTED" = 0 ] || fail "unrelated AT port was accepted"
make_ports
process_once 110
[ "$USB_CALLS" = "up " ] || fail "ready startup device did not request netifd"

# Duplicate scans/events are idempotent; DHCP delay does not trigger early AT setup.
process_once 120
[ "$PDP_CALLS" = 0 ] || fail "PDP setup ran before DHCP wait elapsed"
process_once 200
[ "$PDP_CALLS" = 1 ] || fail "registered modem was not recovered after DHCP timeout"
process_once 290
[ "$FAILURES" -eq 1 ] || fail "missing DHCP lease did not enter bounded retry"
[ "$PDP_CALLS" -eq 1 ] || fail "retry was not delayed"
process_once 320
[ "$PDP_CALLS" -eq 2 ] || fail "delayed PDP retry did not run"

# A healthy lease resets failures; roaming is accepted.
LEASE=1
REGISTRATION=5
process_once 350
[ "$FAILURES" -eq 0 ] || fail "healthy lease did not reset failure count"
STATUS_MODE=invalid
interface_has_lease && fail "malformed ubus status was treated as a lease"
STATUS_MODE=normal

# Unregistered or malformed AT status never causes destructive reinitialization.
LEASE=0
REGISTRATION=2
process_once 380
[ "$PDP_CALLS" -eq 2 ] || fail "unregistered modem was repeatedly activated"
REGISTRATION=error
process_once 410
[ "$PDP_CALLS" -eq 2 ] || fail "bad AT response caused an unsafe activation"

# Remove and reinsert with a new USB devnum; old identity cannot own the new unit.
rm -rf "$DEVICE"
process_once 420
[ "$NETWORK_REQUESTED" = 0 ] || fail "remove did not clear connection state"
case "$USB_CALLS" in *"down "*) ;; *) fail "remove did not take down managed interface" ;; esac
make_device 9
make_ports
process_once 430
[ "$NETWORK_REQUESTED" = 1 ] || fail "reinsert was not discovered"

# A malformed netifd status and a failed PDP chat are bounded and retried.
reset_state
DEVICE_KEY=
LEASE=0
REGISTRATION=1
PDP_RESULT=1
process_once 500
process_once 590 || :
[ "$FAILURES" -eq 1 ] || fail "failed activation was not counted"
assert test "$RETRY_AT" -gt 590

# Disabled configuration exits before acquiring the worker lock or touching netifd.
CONFIG_ENABLED=0
BEFORE_CALLS=$USB_CALLS
load_config && fail "disabled configuration was accepted"
worker_main
[ "$USB_CALLS" = "$BEFORE_CALLS" ] || fail "disabled configuration touched netifd"
CONFIG_ENABLED=1
NETWORK_PROTO=unmanaged
load_config && fail "unmanaged interface configuration was accepted"
NETWORK_PROTO=dhcp
CONFIG_APN='bad;command'
load_config && fail "unsafe APN was accepted"
CONFIG_APN=test.apn

# A live lock prevents a second worker from starting.
mkdir -p "$MF832S_RUN_DIR/worker.lock"
printf '%s\n' "$$" >"$MF832S_RUN_DIR/worker.lock/pid"
BEFORE_CALLS=$USB_CALLS
worker_main
[ "$USB_CALLS" = "$BEFORE_CALLS" ] || fail "second worker operated netifd"

# Stopping a worker that owns the interface cleans up only that configured interface.
NETWORK_REQUESTED=1
cleanup
case "$USB_CALLS" in *"down "*) ;; *) fail "stop did not clean up managed interface" ;; esac

# A dead PID lock can be reclaimed without deleting another worker's lock.
mkdir -p "$MF832S_RUN_DIR/worker.lock"
printf '99999999\n' >"$MF832S_RUN_DIR/worker.lock/pid"
POLL_INTERVAL=0
process_once() {
	STOPPING=1
}
worker_main
cleanup
[ ! -e "$MF832S_RUN_DIR/worker.lock" ] || fail "stale worker lock was not cleaned up"

printf 'ok - monitor state paths\n'
