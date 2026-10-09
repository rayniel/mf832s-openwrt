#!/bin/sh

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/run"
cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	*"mf832s.main.enabled"*) printf '%s\n' "${ENABLED:-1}" ;;
	*"mf832s.main.vendor"*) printf '%s\n' 19d2 ;;
	*"mf832s.main.product"*) printf '%s\n' 0199 ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/uci"
export PATH="$TMP/bin:$PATH"
export MF832S_RUN_DIR="$TMP/run"

run_event() {
	ACTION=$1 PRODUCT=$2
	export ACTION PRODUCT
	sh "$ROOT/etc/hotplug.d/usb/20-mf832s.sh"
}

run_event add 19d2/199/100
[ -e "$TMP/run/event" ] || {
	echo "matching hotplug add was not signalled" >&2
	exit 1
}
rm -f "$TMP/run/event"
run_event remove 19d2/999/100
[ ! -e "$TMP/run/event" ] || {
	echo "unrelated USB product was signalled" >&2
	exit 1
}
ENABLED=0
export ENABLED
run_event add 19d2/199/100
[ ! -e "$TMP/run/event" ] || {
	echo "disabled service received a hotplug signal" >&2
	exit 1
}
echo "ok - hotplug filtering"
