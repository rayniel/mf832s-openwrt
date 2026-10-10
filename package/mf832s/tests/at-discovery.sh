#!/bin/sh
# Exercise real discovery and bounded AT transport against a fake USB topology.
set -u
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
sed '/^\. \/lib\/functions.sh$/d; /^log .Starting MF832S monitor build=/,$d' \
	"$ROOT/package/mf832s/files/mf832s-monitor" |
	sed "s|/sys/|$TMP/sys/|g; s|candidate=/dev/|candidate=$TMP/dev/|" \
	>"$TMP/functions"
. "$TMP/functions"
RUN=$TMP/instance
STATUS_FILE=$TMP/status
TRACE=$TMP/trace
SELECTED_FILE=$TMP/selected
mkdir -p "$RUN" "$TMP/bin" "$TMP/dev" "$TMP/sys/bus/usb/devices" \
	"$TMP/sys/class/tty" "$TMP/sys/class/net"
export TRACE SELECTED_FILE
PATH=$TMP/bin:$PATH
export PATH
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log() { printf 'LOG %s\n' "$*" >>"$TRACE"; }
network_config() { return 0; }
network_status() { return 0; }
usb_fixture=$TMP/sys/bus/usb/devices/1-2
mkdir -p "$usb_fixture"
printf '19d2\n' >"$usb_fixture/idVendor"
printf '0199\n' >"$usb_fixture/idProduct"
printf '1\n' >"$usb_fixture/busnum"
printf '2\n' >"$usb_fixture/devnum"
mkdir -p "$TMP/sys/class/net/eth1"
ln -s "$usb_fixture" "$TMP/sys/class/net/eth1/device"
for entry in 'ttyUSB0 02' 'ttyUSB1 03' 'ttyUSB2 04' 'ttyACM0 01'; do
	set -- $entry
	mkdir -p "$usb_fixture/1-2:1.$2/$1" "$TMP/sys/class/tty/$1"
	printf '%s\n' "$2" >"$usb_fixture/1-2:1.$2/bInterfaceNumber"
	ln -s "$usb_fixture/1-2:1.$2/$1" "$TMP/sys/class/tty/$1/device"
	ln -s /dev/null "$TMP/dev/$1"
done
# An unrelated tty must never be probed, even if it responds.
mkdir -p "$TMP/sys/class/tty/ttyUSB9" "$TMP/other"
printf '19d2\n' >"$TMP/other/idVendor"
printf '0199\n' >"$TMP/other/idProduct"
ln -s "$TMP/other" "$TMP/sys/class/tty/ttyUSB9/device"
ln -s /dev/null "$TMP/dev/ttyUSB9"
cat >"$TMP/bin/stty" <<'EOF'
#!/bin/sh
printf 'STTY %s\n' "$*" >>"$TRACE"
printf '%s\n' "$2" >"$SELECTED_FILE"
EOF
cat >"$TMP/bin/chat" <<'EOF'
#!/bin/sh
[ "$*" = "-S -s -V -f $PROBE_RUN/query.chat" ] || exit 99
grep -Fx "'' 'AT'" "$PROBE_RUN/query.chat" >/dev/null || exit 99
grep -Fx "'\\r\\nOK\\r\\n' '\\c'" "$PROBE_RUN/query.chat" >/dev/null || exit 99
! grep -E 'ATE0|AT\+|\\+\+\+' "$PROBE_RUN/query.chat" >/dev/null || exit 99
port=$(cat "$SELECTED_FILE")
printf 'AT %s\n' "$port" >>"$TRACE"
printf 'PRIVATE-AT-CONTENT\n' >&2
[ "$SUCCESS_PORT" != stall ] || sleep 10
[ "$SUCCESS_PORT" != all ] || exit 0
[ "${port##*/}" = "$SUCCESS_PORT" ]
EOF
chmod +x "$TMP/bin/stty" "$TMP/bin/chat"
PROBE_RUN=$RUN SUCCESS_PORT=ttyUSB1
export PROBE_RUN SUCCESS_PORT
vid=19d2 pid=0199 usb_path='' serial='' at_interface='' at_device='' net_device=''
retry_initial=5 retry_max=120 backoff=5 query_timeout=2 transaction_timeout=20
event_listener=$$ event_reader=$$ event_guard=$$
printf '0\n' >"$RUN/iface-sequence"
: >"$TRACE"
discover || fail "discovery: $discovery_reason"
generation=$found_generation
[ -z "$at" ] || fail 'port chosen without AT confirmation'
select_at || fail "selection: $at_failure"
[ "$at" = "$TMP/dev/ttyUSB1" ] || fail "wrong selected port: $at"
[ "$(grep '^AT ' "$TRACE" | sed "s|$TMP/dev/||")" = "$(printf 'AT ttyACM0\nAT ttyUSB0\nAT ttyUSB1')" ] ||
	fail 'candidate order or same-parent restriction failed'
grep -F -- '-hupcl -crtscts' "$TRACE" >/dev/null || fail 'serial close may hang up modem'
! grep -F 'PRIVATE-AT-CONTENT' "$TRACE" >/dev/null || fail 'AT content leaked into logs'
printf 'ok - same-parent ttyACM/ttyUSB probing uses AT only and stable interface ordering\n'
before=$(grep -c '^AT ' "$TRACE")
discover && select_at || fail 'in-memory reuse failed'
auto_at='' auto_generation=''
discover && select_at || fail 'restart cache reuse failed'
[ "$(grep -c '^AT ' "$TRACE")" = "$before" ] || fail 'locked port was reprobed'
grep -F 'reason=cached-confirmed-port' "$TRACE" >/dev/null || fail 'cache reuse not logged'
printf 'ok - confirmed port reused in memory and across monitor restart\n'

# Explicit configuration must override an otherwise valid cached selection.
at_interface=04
discover && select_at || fail 'explicit interface failed'
[ "$at" = "$TMP/dev/ttyUSB2" ] || fail 'explicit interface did not win'
at_interface='' at_device=$TMP/dev/ttyUSB0
discover && select_at || fail 'explicit device failed'
[ "$at" = "$at_device" ] || fail 'explicit device did not win'
[ "$(grep -c '^AT ' "$TRACE")" = "$before" ] || fail 'explicit choice triggered auto probing'
at_interface=04
discover && fail 'conflicting explicit selectors accepted'
printf 'ok - explicit selectors take priority and never fall back\n'

at_interface='' at_device='' SUCCESS_PORT=ttyUSB2
printf '3\n' >"$usb_fixture/devnum"
discover || fail 'new generation discovery failed'
generation=$found_generation
select_at || fail 'new generation probe failed'
[ "$at" = "$TMP/dev/ttyUSB2" ] || fail 'old generation cache reused'
printf 'ok - USB enumeration change invalidates cached port\n'

SUCCESS_PORT=none
printf '4\n' >"$usb_fixture/devnum"
discover || fail 'failure fixture discovery failed'
generation=$found_generation
select_at && fail 'nonresponsive ports accepted'
[ -z "$at" ] && [ "$next_try" -gt "$(now)" ] || fail 'failure did not schedule retry'
before=$(grep -c '^AT ' "$TRACE")
discover && select_at && fail 'backoff accepted a port'
[ "$(grep -c '^AT ' "$TRACE")" = "$before" ] || fail 'backoff repeated serial traffic'
grep -F 'automatic AT probe failed' "$TRACE" >/dev/null || fail 'failure reason not logged'
next_try=0 SUCCESS_PORT=ttyUSB0
discover && select_at || fail 'retry did not recover'
printf 'ok - failure stays alive, backs off without serial traffic and later recovers\n'

SUCCESS_PORT=all
auto_at='' auto_generation=''
rm -f "$TMP/at-port"
next_try=0
discover && select_at || fail 'multiple responsive ports rejected'
[ "$at" = "$TMP/dev/ttyACM0" ] || fail 'first ordered responsive port not selected'
rm "$TMP/dev/ttyACM0"
SUCCESS_PORT=none
discover || fail 'disappeared-port topology failed'
select_at && fail 'nonresponsive replacement was accepted'
[ -z "$auto_at$auto_generation" ] && [ ! -e "$TMP/at-port" ] ||
	fail 'disappeared-port confirmation survived a failed probe'
ln -s /dev/null "$TMP/dev/ttyACM0"
before=$(grep -c '^AT ' "$TRACE")
discover && select_at && fail 'returned tty name bypassed backoff using stale confirmation'
[ "$(grep -c '^AT ' "$TRACE")" = "$before" ] || fail 'returned port bypassed backoff'
next_try=0 SUCCESS_PORT=all
discover && select_at || fail 'returned tty name was not reprobed'
[ "$(grep -c '^AT ' "$TRACE")" -gt "$before" ] || fail 'returned port reused stale confirmation'
rm "$TMP/dev/ttyACM0"
discover && select_at || fail 'disappeared cached port did not trigger detection'
[ "$at" = "$TMP/dev/ttyUSB0" ] || fail 'disappeared port was reused'
printf 'ok - multiple responders select first stable candidate; disappeared port invalidates lock\n'

rm -f "$TMP/at-port"
auto_at='' auto_generation='' next_try=0 SUCCESS_PORT=stall
query_timeout=1 transaction_timeout=3
discover || fail 'timeout fixture discovery failed'
started=$(now)
select_at && fail 'stalled chat accepted'
[ "$(( $(now) - started ))" -le 4 ] || fail 'probe round exceeded total deadline'
[ -z "$child" ] || fail 'timed out child was not reaped'
printf 'ok - stalled serial transaction is killed within bounded round deadline\n'

next_try=0
at_candidates=$(printf '00 %s\n' "$TMP/dev/ttyUSB0" | awk '{ for (i=0;i<9;i++) print }')
before=$(grep -c '^AT ' "$TRACE")
select_at && fail 'unbounded candidate list accepted'
[ "$at_failure" = too-many-serial-candidates ] || fail 'candidate cap not explained'
[ "$(grep -c '^AT ' "$TRACE")" = "$before" ] || fail 'over-limit topology was probed'
printf 'ok - candidate count is bounded before serial access\n'

# Probe-mode command guard must reject mutations before starting chat.
transaction_mode=probe
before=$(grep -c '^AT ' "$TRACE")
query 'AT+CFUN=0' && fail 'destructive probe command accepted'
[ "$at_failure" = unsafe-probe-command ] || fail 'unsafe command reason missing'
[ "$(grep -c '^AT ' "$TRACE")" = "$before" ] || fail 'unsafe command reached chat'
transaction_active=1 interrupted=0
at=$TMP/dev/ttyUSB0
attempt_event=$(interface_event)
printf '5\n' >"$usb_fixture/devnum"
configure_serial && fail 'changed USB generation opened for probing'
printf 'ok - destructive commands and stale-generation serial opens rejected\n'
