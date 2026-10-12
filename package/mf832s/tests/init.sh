#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TMP=$ROOT/package/mf832s/tests/.init.$$
mkdir "$TMP"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
sed '1d' "$ROOT/package/mf832s/files/mf832s.init" >"$TMP/init"
TRACE=$TMP/trace
. "$TMP/init"
procd_open_instance() { echo open >>"$TRACE"; }
procd_set_param() { echo "PARAM $*" >>"$TRACE"; }
procd_close_instance() { echo close >>"$TRACE"; }
procd_add_reload_trigger() { echo "RELOAD $*" >>"$TRACE"; }
procd_add_config_trigger() { echo "TRIGGER $*" >>"$TRACE"; }
kill() { [ "$*" = '-l USR1' ] && echo 10; }
ubus() { echo "UBUS $*" >>"$TRACE"; }
stop() { echo STOP >>"$TRACE"; }
start() { echo START >>"$TRACE"; }
start_service
grep -Fx 'PARAM command /usr/sbin/mf832s-monitor' "$TRACE" >/dev/null
service_triggers
grep -Fx 'RELOAD mf832s' "$TRACE" >/dev/null
grep -Fx 'TRIGGER config.change network /etc/init.d/mf832s network_changed' "$TRACE" >/dev/null
network_changed
grep -F '"signal":10' "$TRACE" >/dev/null
! grep -Fx STOP "$TRACE" >/dev/null
reload_service
grep -Fx STOP "$TRACE" >/dev/null
grep -Fx START "$TRACE" >/dev/null
printf 'ok - init delegates validation to monitor; network config wakes without restart, plugin reload restarts\n'
