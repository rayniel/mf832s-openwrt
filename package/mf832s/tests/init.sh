#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
sed -n '/^start_service() {/,/^}/p' "$ROOT/package/mf832s/files/mf832s.init" >"$TMP/start-service"
cat >>"$TMP/start-service" <<'EOF'
logger() { printf 'LOG %s\n' "$*" >>"$TRACE"; }
config_load() { :; }
config_get_bool() { eval "$1=\$cfg_enabled"; }
config_get() { eval "$1=\$cfg_target"; }
procd_open_instance() { echo open >>"$TRACE"; }
procd_set_param() { echo "PARAM $*" >>"$TRACE"; }
procd_close_instance() { echo close >>"$TRACE"; }
EOF
fail() { echo "FAIL: $*" >&2; exit 1; }
TRACE=$TMP/trace
cfg_enabled=0 cfg_target=mf832s
. "$TMP/start-service"
start_service
grep -F 'Not starting' "$TRACE" >/dev/null || fail 'disabled configuration did not explain why service was skipped'
! grep -F 'PARAM command' "$TRACE" >/dev/null || fail 'disabled service created a procd instance'
: >"$TRACE"
cfg_enabled=1 cfg_target='bad/name'
start_service
grep -F 'invalid target interface' "$TRACE" >/dev/null || fail 'invalid target did not produce an explanation'
! grep -F 'PARAM command' "$TRACE" >/dev/null || fail 'invalid target created a procd instance'
: >"$TRACE"
cfg_enabled=1 cfg_target=4G
start_service
grep -F 'build=1.0.0-r3 for target interface=4G' "$TRACE" >/dev/null || fail 'startup target/build not logged'
grep -F 'PARAM stdout 1' "$TRACE" >/dev/null || fail 'procd stdout forwarding missing'
grep -F 'PARAM stderr 1' "$TRACE" >/dev/null || fail 'procd stderr forwarding missing'
printf 'ok - init logs disabled/invalid starts and forwards stdout/stderr through procd\n'
