#!/bin/sh

mf832s_hex_id() {
	case "$1" in ''|*[!0-9a-fA-F]*) return 1;; esac
	[ "${#1}" -le 4 ] || return 1
	printf '%04x' "0x$1"
}

mf832s_target_event() {
	local vid pid product_vid product_rest product_pid event_vid event_pid path
	vid=$(uci -q get mf832s.main.vid 2>/dev/null)
	pid=$(uci -q get mf832s.main.pid 2>/dev/null)
	vid=$(mf832s_hex_id "${vid:-19d2}") || return 0
	pid=$(mf832s_hex_id "${pid:-0199}") || return 0
	case "${PRODUCT:-}" in
		*/*/*)
			product_vid=${PRODUCT%%/*}
			product_rest=${PRODUCT#*/}
			product_pid=${product_rest%%/*}
			if event_vid=$(mf832s_hex_id "$product_vid") &&
			   event_pid=$(mf832s_hex_id "$product_pid"); then
				[ "$event_vid" = "$vid" ] && [ "$event_pid" = "$pid" ]
				return
			fi
			;;
	esac
	# Removal may have no sysfs entry left; unknown events still wake discovery.
	case "${DEVPATH:-}" in
		*/../*|*/..) return 0;;
		/devices/*) path=$(readlink -f "/sys$DEVPATH") || return 0;;
		*) return 0;;
	esac
	[ -d "$path" ] || return 0
	while [ -n "$path" ] && [ "$path" != /sys ]; do
		if [ -r "$path/idVendor" ] && [ -r "$path/idProduct" ]; then
			event_vid=$(mf832s_hex_id "$(cat "$path/idVendor")") || return 0
			event_pid=$(mf832s_hex_id "$(cat "$path/idProduct")") || return 0
			[ "$event_vid" = "$vid" ] && [ "$event_pid" = "$pid" ]
			return
		fi
		path=${path%/*}
	done
	return 0
}

mf832s_signal() {
	local signal
	signal=$(kill -l USR1 2>/dev/null)
	case "$signal" in
		''|*[!0-9]*) :;;
		*) ubus -t 1 call service signal "{\"name\":\"mf832s\",\"signal\":$signal}" >/dev/null 2>&1;;
	esac
}
