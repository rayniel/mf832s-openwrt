#!/bin/sh
# Real FIFO waits and fake sysfs exercise idle without modem hardware.
set -u
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
if [ "${1:-}" = worker ]; then
	TMP=$2
	. "$TMP/functions"
	RUN=$TMP/run STATUS_FILE=$TMP/status TRACE=$TMP/trace
	mkdir "$RUN"
	vid=19d2 pid=0199 usb_path='' serial='' at_interface='' at_device='' net_device=''
	poll_interval=1 retry_initial=5 backoff=5 retry_max=120
	log() { printf 'LOG %s\n' "$*" >>"$TRACE"; }
	network_down() { :; }
	resolve_target() {
		printf 'TARGET %s %s\n' "$at_candidates" "$net" >>"$TRACE"
		validation_reason=test-no-binding
		return 1
	}
	reconcile() {
		printf 'SCAN\n' >>"$TRACE"
		reconcile_once
	}
	write_state() {
		if [ "${STARTUP_WAKE:-0}" = 1 ]; then
			STARTUP_WAKE=0
			kill -USR1 "$$"
		fi
	}
	[ "${STARTUP_EARLY_WAKE:-0}" = 0 ] || kill -USR1 "$$"
	. "$TMP/main"
	exit
fi
TMP=$(mktemp -d /tmp/mf832s-idle.XXXXXX) || exit 1
mkdir -p "$TMP/sys/bus/usb/devices" "$TMP/sys/class/tty" "$TMP/sys/class/net"
worker=
cleanup_test() {
	[ -z "$worker" ] || { kill -TERM "$worker" 2>/dev/null || :; wait "$worker" 2>/dev/null || :; }
	rm -rf "$TMP"
}
trap cleanup_test EXIT
trap 'exit 1' HUP INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
sed '/^\. \/lib\/functions.sh$/d; /^log .Starting MF832S monitor build=/,$d' \
	"$ROOT/package/mf832s/files/mf832s-monitor" |
	sed "s|/sys/|$TMP/sys/|g; s|candidate=/dev/|candidate=$TMP/dev/|; s/^reconcile() {/reconcile_once() {/" >"$TMP/functions"
sed -n '/^monitor_pid=\$\$/,$p' "$ROOT/package/mf832s/files/mf832s-monitor" >"$TMP/main"
. "$TMP/functions"
TRACE=$TMP/unit-trace RUN=$TMP/unit STATUS_FILE=$TMP/status
mkdir "$RUN" "$TMP/dev"
log() { printf '%s\n' "$*" >>"$TRACE"; }
clock=100
now() { printf '%s\n' "$clock"; }
network_down() { :; }
resolve_target() { validation_reason=test-no-binding; return 1; }
vid=19d2 pid=0199 usb_path='' serial='' at_interface='' at_device='' net_device=''
poll_interval=7 retry_initial=5
usb_fixture=$TMP/sys/bus/usb/devices/1-2
add_usb() {
	mkdir -p "$usb_fixture"
	printf '19d2\n' >"$usb_fixture/idVendor"
	printf '0199\n' >"$usb_fixture/idProduct"
	printf '1\n' >"$usb_fixture/busnum"
	printf '%s\n' "$1" >"$usb_fixture/devnum"
}
add_tty() {
	mkdir -p "$TMP/sys/class/tty/$1"
	ln -s "$usb_fixture" "$TMP/sys/class/tty/$1/device"
	ln -s /dev/null "$TMP/dev/$1"
}
add_net() {
	mkdir -p "$TMP/sys/class/net/$1"
	ln -s "$usb_fixture" "$TMP/sys/class/net/$1/device"
}
reconcile_once
[ "$(wait_delay)" = 0 ] || fail 'absent modem has an idle timer'
reconcile_once
[ "$(wc -l <"$TRACE")" = 1 ] || fail 'duplicate absence repeated discovery log'
add_usb 2
add_net eth1
reconcile_once
[ "$discovery_reason" = serial-ports-not-ready ] || fail 'automatic no-tty topology was accepted'
[ "$enumeration_deadline" = 160 ] && [ "$(wait_delay)" = 7 ] || fail 'enumeration window not started'
clock=159
reconcile_once
[ "$enumeration_deadline" = 160 ] && [ "$(wait_delay)" = 1 ] || fail 'duplicate reset enumeration window'
clock=160
reconcile_once
[ "$(wait_delay)" = 0 ] || fail 'enumeration did not become event-only'
add_tty ttyUSB4
reconcile_once
[ "$discovery_ready" = 1 ] && [ "$(wait_delay)" = 7 ] || fail 'late tty notification did not recover'
rm -rf "$TMP/sys/class/tty/ttyUSB4" "$TMP/sys/class/net/eth1"
rm "$TMP/dev/ttyUSB4"
add_usb 3
add_tty ttyACM2
clock=200
reconcile_once
[ "$discovery_reason" = usb-network-device-not-ready ] && [ "$enumeration_deadline" = 260 ] ||
	fail 'tty-first replug did not get a fresh bounded window'
clock=260
reconcile_once
[ "$(wait_delay)" = 0 ] || fail 'tty-first missing net kept polling'
add_net eth9
reconcile_once
[ "$net" = eth9 ] && [ "$discovery_ready" = 1 ] || fail 'late renamed net did not recover'
printf 'ok - absent logging, automatic no-tty, both enumeration orders, bounded windows and renamed replug\n'

# Repeated calls emulate a flood of delivered traps without signal coalescing.
kill -USR1 "$$"
[ "$startup_wake" = 1 ] || fail 'early startup signal was not retained'
arm_wake || fail 'wake FIFO open failed'
[ "$wake_pending" = 1 ] || fail 'early startup signal was not queued on arm'
wait_wake 0
trap wake USR1
i=0
while [ "$i" -lt 10000 ]; do wake; i=$((i + 1)); done
[ "$wake_pending" = 1 ] || fail 'wake not retained'
wait_wake 0
[ "$wake_pending" = 0 ] || fail 'wake not consumed'
wake
wait_wake 0
# Signal at timer child startup, racing publication of its PID in the parent.
cat >"$TMP/timer" <<'EOF'
#!/bin/sh
kill -USR1 "$monitor_pid"
exec sleep "$1"
EOF
chmod +x "$TMP/timer"
sed -n '/^wait_wake() {/,/^}/p' "$TMP/functions" |
	sed "s|exec sleep |exec $TMP/timer |" >"$TMP/wait-timer"
. "$TMP/wait-timer"
monitor_pid=$$
export monitor_pid
started=$(date +%s)
wait_wake 30
[ "$(( $(date +%s) - started ))" -lt 3 ] || fail 'timer child startup signal was lost'
[ -z "$child" ] && [ "$wake_pending" = 0 ] || fail 'timer boundary wake was lost'
trap - USR1
exec 8>&-
wake_ready=0
printf 'ok - queued boundary wake, 10000-event coalescing and timed-wait child race\n'

wait_scans() {
	end=$(( $(date +%s) + 5 ))
	while [ "$(grep -c '^SCAN$' "$TMP/trace" 2>/dev/null || :)" -lt "$1" ]; do
		[ "$(date +%s)" -lt "$end" ] || fail 'worker did not reconcile'
		command sleep 0.05
	done
}
start_worker() {
	: >"$TMP/trace"
	if [ "${TEST_SHELL:-sh}" = ash ]; then
		busybox ash "$0" worker "$TMP" &
	else
		sh "$0" worker "$TMP" &
	fi
	worker=$!
}
stop_worker() {
	kill -TERM "$worker"
	end=$(( $(date +%s) + 3 ))
	while kill -0 "$worker" 2>/dev/null; do
		[ "$(date +%s)" -lt "$end" ] || fail 'TERM did not stop blocked reader'
		command sleep 0.05
	done
	wait "$worker" || fail 'worker failed'
	worker=
	[ ! -d "$TMP/run" ] || fail 'private wake directory leaked'
}
start_worker
wait_scans 1
grep -F eth9 "$TMP/trace" >/dev/null || fail 'initial attached modem was not reconciled'
stop_worker
rm -rf "$TMP/sys/bus/usb/devices/1-2"
STARTUP_WAKE=1
export STARTUP_WAKE
start_worker
wait_scans 2
command sleep 2
[ "$(grep -c '^SCAN$' "$TMP/trace")" = 2 ] || fail 'absent idle performed recurring scan'
kill -USR1 "$worker"
wait_scans 3
command sleep 2
[ "$(grep -c '^SCAN$' "$TMP/trace")" = 3 ] || fail 'event did not return to blocking idle'
stop_worker
STARTUP_WAKE=0 STARTUP_EARLY_WAKE=1
export STARTUP_WAKE STARTUP_EARLY_WAKE
start_worker
wait_scans 2
command sleep 2
[ "$(grep -c '^SCAN$' "$TMP/trace")" = 2 ] || fail 'early startup wake was lost or caused polling'
stop_worker
printf 'ok - startup wake armed before first reconcile, initial attached startup, true blocking idle and prompt TERM\n'
printf 'ok - signal before FIFO creation survives startup and is queued when armed\n'
