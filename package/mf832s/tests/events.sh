#!/bin/sh
# Test the production FIFO listener and event fences using local ubus/JSON shims.
case "${0##*/}" in
	ubus)
		case "$*" in
			'-S listen network.interface mf832s.fence')
				exec cat "$SIM_FEED";;
			'-t 1 send mf832s.fence '*)
				printf '{ "mf832s.fence": %s }\n' "$5" >"$SIM_FEED";;
			*) exit 1;;
		esac
		exit
		;;
	jsonfilter)
		case "$4" in
			'@["network.interface"].interface') key=interface;;
			'@["network.interface"].action') key=action;;
			'@["mf832s.fence"].token') key=token;;
			*) exit 1;;
		esac
		printf '%s\n' "$2" | sed -n "s/.*\"$key\": *\"\\{0,1\\}\\([^\",} ]*\\).*/\\1/p"
		exit
		;;
esac
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d)
sed '/^\. \/lib\/functions.sh$/d; /^load_config ||/,$d' \
	"$ROOT/package/mf832s/files/mf832s-monitor" >"$TMP/functions"
. "$TMP/functions"
RUN=$TMP/run
mkdir "$RUN" "$TMP/bin"
cp "$ROOT/package/mf832s/tests/events.sh" "$TMP/bin/ubus"
cp "$ROOT/package/mf832s/tests/events.sh" "$TMP/bin/jsonfilter"
chmod +x "$TMP/bin/ubus" "$TMP/bin/jsonfilter"
PATH=$TMP/bin:$PATH
SIM_FEED=$TMP/feed
export SIM_FEED
mkfifo "$SIM_FEED"
# Keep the fake event transport open across individual send clients.
exec 8<>"$SIM_FEED"
trap 'stop_events || :; rm -rf "$TMP"' EXIT HUP INT TERM
trap ':' USR1
monitor_pid=$$
interface=modem
ensure_events || exit 1
initial=$(interface_event)
printf '{ "network.interface": {"interface":"wan","action":"ifdown"} }\n' >&8
event_barrier || exit 1
[ "$(interface_event)" = "$initial" ]
printf '{ "network.interface": {"interface":"modem","action":"ifdown"} }\n' >&8
printf '{ "network.interface": {"interface":"modem","action":"ifup"} }\n' >&8
event_barrier || exit 1
[ "$(interface_event)" != "$initial" ]
[ "$(cat "$RUN/iface-sequence")" = 1 ]
printf 'ok - real FIFO reader/fences preserve fast target edges and ignore other interfaces\n'
old_listener=$event_listener old_reader=$event_reader old_epoch=$event_epoch
kill "$event_listener"
wait "$event_listener" 2>/dev/null || :
ensure_events || exit 1
[ "$event_epoch" -gt "$old_epoch" ]
! kill -0 "$old_listener" 2>/dev/null
! kill -0 "$old_reader" 2>/dev/null
listener=$event_listener reader=$event_reader
stop_events || exit 1
! kill -0 "$listener" 2>/dev/null
! kill -0 "$reader" 2>/dev/null
printf 'ok - listener restart changes epoch and cleanup reaps both children\n'
printf 'All event-listener regression tests passed\n'
