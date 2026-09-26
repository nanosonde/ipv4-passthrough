#!/bin/sh
# ip4pt-gc.sh — two-tier lifecycle on per-host silence, both counted from
# the host's last ARP observed on the mirror (state-file mtimes):
#   >OFFLINE_SECS (default 900s): suspend -- drop only the arpreply rule,
#     so the FritzBox stops getting answers and flips the host to offline
#     on its own (FR-13). Everything else is kept for instant recovery.
#   >STALE_SECS (30 days): deprovision -- the whole binding goes (FR-10).
# The FritzBox entry itself just flips to "offline" once its own ARP cache
# ages out or its probes go unanswered.

. "${IP4PT_LIB:-/etc/ip4pt/ip4pt-lib.sh}"

logger -t ip4pt "garbage collector starting"

# GC_INTERVAL is tunable via ip4pt.conf (default 60s) so tests can use a
# short cycle instead of waiting out the full minute.
GC_INTERVAL="${GC_INTERVAL:-60}"
# 0/unset disables the suspend tier (hosts then stay online until STALE_SECS
# removal). Kept numeric: "unset" must disable, not crash the comparisons.
OFFLINE_SECS="${OFFLINE_SECS:-0}"

while true; do
	sleep "$GC_INTERVAL"
	now=$(date +%s)
	for f in "$STATE_DIR"/hosts/*; do
		[ -f "$f" ] || continue
		ip=$(basename "$f")
		mac=$(cat "$f")
		[ -z "$mac" ] && continue
		mtime=$(date -r "$f" +%s 2>/dev/null || echo "$now")
		age=$((now - mtime))
		if [ "$STALE_SECS" -gt 0 ] && [ "$age" -gt "$STALE_SECS" ]; then
			deprovision_host "$ip"
		elif [ "$OFFLINE_SECS" -gt 0 ] && [ "$age" -gt "$OFFLINE_SECS" ] && \
			     arpreply_present "$ip" "$mac"; then
			# Only suspend hosts that are actually answering: an already-
			# suspended host has no rule, so this logs once per silence
			# event, not once per GC cycle.
			suspend_host_rules "$ip" "$mac"
		fi
	done
done
