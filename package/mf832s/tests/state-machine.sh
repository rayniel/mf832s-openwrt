#!/bin/sh
# Hardware-free regression tests: exercise the production functions with fake AT/netifd.
set -u
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
sed '/^\. \/lib\/functions.sh$/d; /^log .Starting MF832S monitor build=/,$d' \
	"$ROOT/package/mf832s/files/mf832s-monitor" >"$TMP/functions" || exit 1
. "$TMP/functions"
sed -n '/^ensure_events() {/,/^}/p; /^event_barrier() {/,/^}/p' \
	"$TMP/functions" >"$TMP/real-events"
RUN=$TMP
TRACE=$TMP/trace

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_count() {
	actual=$(grep -Fxc "$1" "$TRACE" || :)
	[ "$actual" = "$2" ] || fail "$1: expected $2, got $actual"
}
assert_order() {
	awk '
		/^AT\+ZGACT=1,1$/ { activated=1 }
		/^UP modem$/ { if (!activated) exit 1; activated=0 }
	' "$TRACE" || fail 'DHCP started without a fresh ZTE activation'
}
log() { printf 'LOG %s\n' "$*" >>"$TRACE"; }
now() { printf '%s\n' "$clock"; }
config_load() { config=$1; }
config_get_bool() { eval "$1=\$cfg_enabled"; }
config_get() {
	case "$config:$3" in
		mf832s:interface) value=$cfg_interface;;
		mf832s:apn) value=$cfg_apn;;
		mf832s:pdp_type) value=$cfg_pdp_type;;
		mf832s:cid) value=$cfg_cid;;
		mf832s:vid) value=$cfg_vid;;
		mf832s:pid) value=$cfg_pid;;
		mf832s:usb_path) value=$cfg_usb_path;;
		mf832s:serial) value=$cfg_serial;;
		mf832s:at_interface) value=$cfg_at_interface;;
		mf832s:at_device) value=$cfg_at_device;;
		mf832s:net_device) value=$cfg_net_device;;
		mf832s:query_timeout) value=$cfg_query_timeout;;
		mf832s:transaction_timeout) value=$cfg_transaction_timeout;;
		mf832s:poll_interval) value=$cfg_poll_interval;;
		mf832s:retry_initial) value=$cfg_retry_initial;;
		mf832s:retry_max) value=$cfg_retry_max;;
		mf832s:dhcp_timeout) value=$cfg_dhcp_timeout;;
		mf832s:health_interval) value=$cfg_health_interval;;
		mf832s:health_failures) value=$cfg_health_failures;;
		mf832s:recover_mode) value=$cfg_recover_mode;;
		mf832s:recover_threshold) value=$cfg_recover_threshold;;
		mf832s:recover_cooldown) value=$cfg_recover_cooldown;;
		network:TYPE) value=interface;;
		network:proto) value=$cfg_proto;;
		network:device) value=$cfg_device;;
		*) fail "unexpected config lookup $config:$3";;
	esac
	eval "$1=\$value"
}
uci() {
	case "$*" in
		'-q get mf832s.main.enabled') printf '%s\n' "$cfg_enabled";;
		'-q get mf832s.main.interface') printf '%s\n' "$cfg_interface";;
		*) fail "unexpected UCI operation: $*";;
	esac
}
usb_parent() { printf '%s\n' "$physical_usb"; }
stamp() { printf '%s\n' "$physical_generation"; }
discover() {
	case "$discovery" in
		good) :;;
		missing) discovery_reason=usb-vid-pid-not-found; return 1;;
		no-at) discovery_reason=selected-at-port-not-ready; return 1;;
		multiple) discovery_reason=multiple-matching-usb-modems; return 1;;
		no-net) discovery_reason=usb-network-device-not-ready; return 1;;
	esac
	usb=/usb/modem at=/dev/ttyUSB0 net=usb0
	found_generation=$physical_generation
}
ensure_events() { [ "$events_ok" = 1 ]; }
event_barrier() {
	[ "$events_ok" = 1 ] && [ "$barrier_ok" = 1 ] || return 1
	# A fence drains events queued by the service's own down.
	if [ "$queued_down" = 1 ]; then
		sequence=$((sequence + 1))
		printf '%s\n' "$sequence" >"$RUN/iface-sequence"
		queued_down=0
	fi
}
jsonfilter() {
	line=$2 expr=$4
	case "$expr" in
		'@["ipv4-address"][0].address') printf '%s\n' "$fake_ipv4"; return;;
		'@["network.interface"].interface') key=interface;;
		'@["network.interface"].action') key=action;;
		'@["mf832s.fence"].token') key=token;;
		'@.'*) key=${expr#@.};;
		*) fail "unexpected JSON expression $expr";;
	esac
	printf '%s\n' "$line" | sed -n "s/.*\"$key\": *\"\\{0,1\\}\\([^\",} ]*\\).*/\\1/p"
}
ubus() {
	case "$*" in
		'-t 2 call network.interface.modem status')
			[ "$status_ok" = 1 ] || return 1
			# Simulate a lease completing between pending detection and coordination.
			if [ "$online_on_check" -gt 0 ]; then
				count=$(cat "$RUN/status-count")
				count=$((count + 1))
				printf '%s\n' "$count" >"$RUN/status-count"
				[ "$count" -ne "$online_on_check" ] || fake_up=true
			fi
			printf '{"up":%s,"pending":%s,"available":%s,"device":"%s","l3_device":"%s","ipv4-address":[{"address":"%s"}]}\n' \
				"$fake_up" "$fake_pending" "$fake_available" "$fake_device" "$fake_l3" "$fake_ipv4"
			;;
		'-t 2 call network.interface.modem down')
			printf 'DOWN modem\n' >>"$TRACE"
			[ "$down_ok" = 1 ] || return 1
			fake_up=false fake_pending=false queued_down=1
			if [ "$real_events" = 1 ]; then
				printf '{ "network.interface": {"interface":"modem","action":"ifdown"} }\n' >"$SIM_FEED"
			fi
			;;
		'-t 2 call network.interface.modem up')
			printf 'UP modem\n' >>"$TRACE"
			fake_pending=true
			;;
		'-t 1 call service signal '*)
			printf 'WAKE\n' >>"$TRACE";;
		'-t 1 send mf832s.fence '*)
			printf '{ "mf832s.fence": %s }\n' "$5" >"$SIM_FEED";;
		*) fail "unexpected ubus operation: $*";;
	esac
}
begin_transaction() { transaction_end=$((clock + transaction_timeout)); query AT; }
query() {
	transaction_valid || return 1
	printf '%s\n' "$1" >>"$TRACE"
	[ "$1" != "$fail_at" ] || return 1
	case "$1" in
		'AT+CFUN?') printf '+CFUN: 1\n';;
		'AT+CPIN?') printf '+CPIN: READY\n';;
		'AT+CEREG?') printf '+CEREG: 0,1\n';;
		'AT+CGATT?') printf '+CGATT: 1\n';;
		'AT+CGACT?') printf '+CGACT: 1,%s\n' "$pdp_active";;
		'AT+ZGACT?') printf '+ZGACT: 1,%s\n' "$pdp_active";;
		*) printf 'OK\n';;
	esac >"$RUN/response"
	if [ "$1" = "$change_at" ]; then
		case "$change_kind" in
			usb) physical_generation=usb:2;;
			pending) fake_pending=true;;
			binding) cfg_device=lan0;;
			event)
				sequence=$((sequence + 1))
				printf '%s\n' "$sequence" >"$RUN/iface-sequence"
				;;
		esac
	fi
	transaction_valid
}
reset() {
	: >"$TRACE"
	STATUS_FILE=$RUN/status
	interface=modem cfg_interface=modem cfg_enabled=1 cfg_proto=dhcp cfg_device=usb0
	config=mf832s
	cfg_apn='' cfg_pdp_type=IPV4V6 cfg_cid=1 cfg_vid=19d2 cfg_pid=0199
	cfg_usb_path='' cfg_serial='' cfg_at_interface=00 cfg_at_device=''
	cfg_net_device='' cfg_query_timeout=5 cfg_transaction_timeout=45 cfg_poll_interval=10
	cfg_retry_initial=5 cfg_retry_max=120 cfg_dhcp_timeout=60 cfg_health_interval=30
	cfg_health_failures=3 cfg_recover_mode=none cfg_recover_threshold=3 cfg_recover_cooldown=120
	physical_usb=/usb/modem physical_generation=usb:1 generation=usb:1 discovery=good
	usb=/usb/modem at=/dev/ttyUSB0 net=usb0
	fake_up=false fake_pending=false fake_available=true fake_device=usb0 fake_l3=usb0 fake_ipv4=''
	status_ok=1 down_ok=1 pdp_active=1 events_ok=1 barrier_ok=1 queued_down=0
	real_events=0
	online_on_check=0
	printf '0\n' >"$RUN/status-count"
	clock=100 sequence=0 event_epoch=1
	printf '0\n' >"$RUN/iface-sequence"
	event_listener=$$ event_reader=$$ event_guard=$$
	owned_device='' owned_usb='' owned_generation='' owned_event='' owned_online=0
	next_try=0 lease_deadline=0 interrupted=0 transaction_active=0 health_next=0
	health_bad=0 recover_bad=0 recover_next=0 diagnostic='' at_failure=unknown-response
	retry_initial=5 retry_max=120 backoff=5 dhcp_timeout=60 health_interval=30
	health_failures=3 recover_threshold=3 recover_mode=none recover_cooldown=120
	transaction_timeout=45 query_timeout=5 cid=1 pdp_type=IPV4V6 apn=''
	fail_at='' change_at='' change_kind=''
}
connect() { reconcile; assert_count 'UP modem' 1; assert_order; }
online() { fake_up=true fake_pending=false fake_ipv4=192.0.2.2; clock=$((clock + 30)); reconcile; }
retry_time() { clock=$next_try; interrupted=0; reconcile; }

reset
fake_pending=true
connect
assert_count 'DOWN modem' 1
assert_count 'AT+ZGACT=1,1' 1
assert_count 'AT+CGDCONT=1,"IPV4V6",""' 0
assert_count 'AT+CGACT=1,1' 0
printf 'ok - cold unowned pending, active PDP preserved, fresh ZTE before DHCP\n'

reset
connect
online
fake_up=false fake_pending=true
sequence=1; printf '1\n' >"$RUN/iface-sequence"
reconcile
retry_time
assert_count 'UP modem' 2
assert_count 'AT+ZGACT=1,1' 2
assert_order
printf 'ok - manual interface restart creates a new attempt\n'

reset
connect
clock=$((clock + 60))
reconcile
assert_count 'DOWN modem' 1
assert_count 'AT+ZGACT=1,1' 1
reconcile
assert_count 'AT+ZGACT=1,1' 1
retry_time
assert_count 'AT+ZGACT=1,1' 2
assert_order
printf 'ok - DHCP timeout and backoff re-activate before retry\n'

reset
fake_pending=true
connect
# Simulate process restart: no in-memory ownership survives.
owned_device='' owned_usb='' owned_generation='' owned_event=''
connect_count=$(grep -Fxc 'UP modem' "$TRACE")
reconcile
assert_count 'UP modem' "$((connect_count + 1))"
assert_count 'AT+ZGACT=1,1' 2
assert_order
printf 'ok - monitor restart coordinates pending again\n'

reset
connect
online
clock=$((clock + 30)); reconcile
clock=$((clock + 30)); reconcile
assert_count 'AT+ZGACT=1,1' 1
assert_count 'DOWN modem' 0
assert_order
printf 'ok - normal online health never repeats activation\n'
[ "$(grep -Fc 'netifd IPv4 lease acquired' "$TRACE")" = 1 ] || fail 'lease acquisition log was not transition-limited'

reset
fake_up=true
clock=130
reconcile
assert_count 'AT+CEREG?' 0
grep -F 'IPv4 lease present' "$TRACE" && fail 'up without IPv4 was logged as online'
[ "$has_ipv4" = false ] || fail 'up without IPv4 was recorded as leased'
grep -F 'no IPv4 lease' "$TRACE" >/dev/null || fail 'up without IPv4 stage was not observable'
printf 'ok - netifd up without IPv4 is not online and skips health lease state\n'

reset
fake_up=true
reconcile
fail_at='AT+CEREG?'
clock=200; reconcile
clock=300; reconcile
clock=400; reconcile
assert_count 'DOWN modem' 0
assert_count 'UP modem' 0
assert_count 'AT+ZGACT=1,1' 0
assert_count 'AT+CFUN=0' 0
printf 'ok - unowned online interface remains protected on health failure\n'

for rejected in proto device physical status l3 disabled selected unavailable discovery; do
	reset
	fake_pending=true
	case "$rejected" in
		proto) cfg_proto=static;;
		device) cfg_device=lan0;;
		physical) physical_usb=/usb/other;;
		status) fake_device=lan0;;
		l3) fake_l3=lan0;;
		disabled) cfg_enabled=0;;
		selected) cfg_interface=wan;;
		unavailable) fake_pending=false fake_available=false;;
		discovery) discovery=missing;;
	esac
	reconcile
	reconcile
	assert_count 'DOWN modem' 0
	assert_count 'UP modem' 0
	assert_count 'AT+ZGACT=1,1' 0
done
printf 'ok - wrong protocol, device, USB, status, delegation and discovery are rejected\n'

reset
cfg_proto=static
network_config usb0 && fail 'non-DHCP configuration was accepted'
[ "$validation_reason" = target-protocol-not-dhcp ] || fail "wrong protocol reason: $validation_reason"
cfg_proto=dhcp cfg_device=eth1
network_config usb0 && fail 'mismatched 4G/eth1 binding was accepted'
[ "$validation_reason" = target-device-not-discovered-usb-net ] || fail "wrong device reason: $validation_reason"
printf 'ok - configuration rejection includes specific protocol and USB-device reasons\n'

reset
cfg_enabled=0
load_config && fail 'disabled monitor config was accepted'
[ "$config_error" = disabled ] || fail "disabled config reason: $config_error"
cfg_enabled=1 cfg_at_interface=''
load_config && fail 'missing explicit AT selection was accepted'
[ "$config_error" = at-port-not-explicitly-selected ] || fail "AT selector reason: $config_error"
cfg_at_device=/dev/ttyUSB0 cfg_interface='bad/name'
load_config && fail 'invalid target interface was accepted'
[ "$config_error" = invalid-target-interface ] || fail "target config reason: $config_error"
printf 'ok - disabled, missing AT selection and invalid target configs have distinct reasons\n'

reset
log() { printf 'LOG %s\n' "$*" >>"$TRACE"; }
set_stage registration 'checking network registration'
set_stage registration 'checking network registration'
[ "$(grep -Fc 'stage=registration:' "$TRACE")" = 1 ] || fail 'unchanged progress stage was logged repeatedly'
apn='private.example'
log "stage=AT-failure: safe failure"
grep -F "$apn" "$TRACE" && fail 'APN appeared in logged output'
printf 'ok - stage logs are transition-limited and contain no APN\n'

reset
connect
online
# Several down notices coalesce into one invalidated owned attempt; ifup is already visible.
sequence=3; printf '3\n' >"$RUN/iface-sequence"
reconcile
reconcile
retry_time
assert_count 'DOWN modem' 1
assert_count 'AT+ZGACT=1,1' 2
assert_order
printf 'ok - fast down/up and duplicate events do not reuse activation or bypass backoff\n'

for race in usb pending binding event; do
	reset
	change_at='AT+CGATT?' change_kind=$race
	reconcile
	assert_count 'UP modem' 0
	assert_count 'AT+ZGACT=1,1' 0
done
printf 'ok - generation, pending, binding and down-edge races cancel AT\n'

reset
connect
physical_generation=usb:2
fake_pending=true
clock=200
reconcile
assert_count 'AT+ZGACT=1,1' 2
assert_count 'DOWN modem' 1
assert_order
printf 'ok - USB re-enumeration starts a fresh connection generation\n'

for command in AT 'AT+CPIN?' 'AT+CEREG?' 'AT+CGATT?' 'AT+ZGACT=1,1'; do
	reset
	fail_at=$command
	reconcile
	assert_count 'UP modem' 0
done
printf 'ok - AT failures never start DHCP\n'

reset
pdp_active=0
connect
assert_count 'AT+CGDCONT=1,"IPV4V6",""' 1
assert_count 'AT+CGACT=1,1' 1
assert_count 'AT+ZGACT=1,1' 1
printf 'ok - inactive context keeps existing safe initialization\n'

reset
fake_pending=true down_ok=0
reconcile
assert_count 'AT+ZGACT=1,1' 0
assert_count 'UP modem' 0
reset
events_ok=0
reconcile
assert_count 'AT+ZGACT=1,1' 0
assert_count 'UP modem' 0
printf 'ok - failed teardown or listener never permits activation/DHCP\n'

reset
events_ok=1 barrier_ok=0
reconcile
assert_count 'AT+ZGACT=1,1' 0
assert_count 'UP modem' 0
grep -F 'event barrier failed before activation' "$TRACE" >/dev/null ||
	fail 'event listener startup failure did not include a diagnostic'
printf 'ok - event barrier failure explains refusal and never permits activation\n'

for discovery_case in missing no-at multiple no-net; do
	reset
	discovery=$discovery_case
	reconcile
	grep -F "stage=usb-discovery: $discovery_reason" "$TRACE" >/dev/null ||
		fail "$discovery_case discovery failure was not identified"
done
printf 'ok - USB, AT, ambiguous modem and data-device discovery failures are distinct\n'

reset
fake_pending=true online_on_check=3
reconcile
assert_count 'DOWN modem' 0
assert_count 'UP modem' 0
[ -z "$owned_device" ] || fail 'coordination claimed an interface that became online'
printf 'ok - pending that becomes online during recheck is never adopted or stopped\n'

reset
INTERFACE=wan ACTION=ifdown
# BusyBox accepts signal names here; the host's dash builtin does not.
kill() {
	[ "$*" != '-l USR1' ] || { printf '10\n'; return; }
	command kill "$@"
}
. "$ROOT/package/mf832s/files/20-mf832s-iface"
assert_count 'WAKE' 0
INTERFACE=modem
. "$ROOT/package/mf832s/files/20-mf832s-iface"
assert_count 'WAKE' 1
cfg_enabled=0
. "$ROOT/package/mf832s/files/20-mf832s-iface"
assert_count 'WAKE' 1
printf 'ok - packaged iface hook only wakes the enabled configured target\n'

reset
recover_mode=cfun_cycle recover_threshold=1
fail_at='AT+CPIN?'
reconcile
assert_count 'AT+CFUN=0' 1
assert_count 'AT+CFUN=1' 1
retry_time
assert_count 'AT+CFUN=0' 1
assert_count 'UP modem' 0
printf 'ok - radio recovery remains rate-limited and cannot start DHCP on AT failure\n'

reset
transaction_mode=activate attempt_event=$(interface_event)
sleep 30 &
child=$!
fake_pending=true
await_child 999 && fail 'child survived concurrent external DHCP'
[ -z "$child" ] || fail 'cancelled AT child was not reaped'
printf 'ok - in-flight serial child is cancelled when target state changes\n'

# Combine real listener restart/epoch handling with the production reconcile logic.
mkdir "$TMP/bin" "$TMP/reconcile-events"
cp "$ROOT/package/mf832s/tests/events.sh" "$TMP/bin/ubus"
chmod +x "$TMP/bin/ubus"
PATH=$TMP/bin:$PATH
SIM_FEED=$TMP/integration-feed
export SIM_FEED
mkfifo "$SIM_FEED"
exec 8<>"$SIM_FEED"
RUN=$TMP/reconcile-events
reset
real_events=1 monitor_pid=$$
event_listener='' event_reader='' event_guard=''
. "$TMP/real-events"
trap wake USR1
connect
online
kill "$event_listener"
wait "$event_listener" 2>/dev/null || :
reconcile
assert_count 'DOWN modem' 1
assert_count 'AT+ZGACT=1,1' 1
reconcile
assert_count 'AT+ZGACT=1,1' 1
retry_time
reconcile
assert_count 'DOWN modem' 1
assert_count 'AT+ZGACT=1,1' 2
assert_order
stop_events
exec 8>&-
trap - USR1
RUN=$TMP
printf 'ok - real listener restart invalidates owned online attempt once, with backoff\n'

# Exercise the actual event reader with the one-line ubus listen envelope.
reset
monitor_pid=$$
kill() { printf 'SIGNAL %s\n' "$*" >>"$TRACE"; }
read_events <<EOF
{ "network.interface": {"interface":"wan","action":"ifdown"} }
{ "network.interface": {"interface":"modem","action":"ifup"} }
{ "network.interface": {"interface":"modem","action":"ifdown"} }
{ "network.interface": {"interface":"modem","action":"ifup"} }
{ "mf832s.fence": {"token":42} }
EOF
[ "$(cat "$RUN/iface-sequence")" = 1 ] || fail 'target down edge not retained'
[ "$(cat "$RUN/fence")" = 42 ] || fail 'event fence not acknowledged'
assert_count "SIGNAL -USR1 $$" 1
printf 'ok - event reader filters other interfaces and preserves down/up before fence\n'
printf 'All state-machine regression tests passed\n'
