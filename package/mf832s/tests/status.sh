#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir "$TMP/bin"
cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	'-q get mf832s.main.interface') echo mf832s;;
	'-q get mf832s.main.enabled') echo 1;;
	'-q get mf832s.main.at_interface'|'-q get mf832s.main.at_device') echo;;
	'-q get network.4G') echo interface;;
	'-q get network.4G.proto') echo dhcp;;
	'-q get network.4G.device') echo eth1;;
	'-q get network.4G.ifname') echo;;
	*) exit 1;;
esac
EOF
chmod +x "$TMP/bin/uci"
sed \
	-e "s|PATH=/usr/sbin:/usr/bin:/sbin:/bin|PATH=$TMP/bin:/usr/sbin:/usr/bin:/sbin:/bin|" \
	-e "s|STATUS_FILE=/var/run/mf832s/status|STATUS_FILE=$TMP/status|" \
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
grep -F 'no explicit AT port selected' "$TMP/check" >/dev/null
printf 'ok - status JSON is escaped, stale instances cannot report IPv4, and 4G diagnostics are explicit\n'
