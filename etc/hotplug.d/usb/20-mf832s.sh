#!/bin/sh

uci -q get mf832s.main.enabled 2>/dev/null | grep -qx 1 || exit 0

VENDOR=$(uci -q get mf832s.main.vendor 2>/dev/null)
PRODUCT_ID=$(uci -q get mf832s.main.product 2>/dev/null)
case "$ACTION" in
	add|remove) ;;
	*) exit 0 ;;
esac

EVENT_VENDOR=${PRODUCT%%/*}
EVENT_PRODUCT=${PRODUCT#*/}
EVENT_PRODUCT=${EVENT_PRODUCT%%/*}
VENDOR=$(printf '%s' "$VENDOR" | tr 'A-F' 'a-f')
PRODUCT_ID=$(printf '%s' "$PRODUCT_ID" | tr 'A-F' 'a-f')
EVENT_VENDOR=$(printf '%s' "$EVENT_VENDOR" | tr 'A-F' 'a-f')
EVENT_PRODUCT=$(printf '%s' "$EVENT_PRODUCT" | tr 'A-F' 'a-f')
case "$VENDOR:$PRODUCT_ID" in
	[0-9a-f][0-9a-f][0-9a-f][0-9a-f]:[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
	*) exit 0 ;;
esac
case "$EVENT_VENDOR" in
	[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
	*) exit 0 ;;
esac
case "$EVENT_PRODUCT" in
	''|*[!0-9a-f]*) exit 0 ;;
esac
[ "${#EVENT_PRODUCT}" -le 4 ] || exit 0
EVENT_PRODUCT=$(printf '%s' "$EVENT_PRODUCT" | sed 's/^0*//')
PRODUCT_ID=$(printf '%s' "$PRODUCT_ID" | sed 's/^0*//')
[ "$PRODUCT_ID" = "" ] && PRODUCT_ID=0
[ "$EVENT_PRODUCT" = "" ] && EVENT_PRODUCT=0
[ "$VENDOR" = "$EVENT_VENDOR" ] && [ "$PRODUCT_ID" = "$EVENT_PRODUCT" ] || exit 0

RUN_DIR=${MF832S_RUN_DIR:-/var/run/mf832s}
mkdir -p "$RUN_DIR" 2>/dev/null || exit 0
touch "$RUN_DIR/event"
exit 0
