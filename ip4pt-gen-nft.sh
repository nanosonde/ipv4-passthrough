#!/bin/sh
# ip4pt-gen-nft.sh — renders 10-ip4pt.nft.tmpl into
# /etc/ip4pt/10-ip4pt.nft, substituting ROUTER2_MAC / UPLINK / DOWNLINK from
# ip4pt.conf, and loads it directly via `nft -f`.
#
# Run this once at install time, and again any time ROUTER2_MAC changes
# in ip4pt.conf. Not run automatically at boot -- the init script (which
# applies the rendered file itself) handles that; this tool is for static
# config changes.
#
# Why direct `nft -f` and NOT a drop into /etc/nftables.d/: fw4 includes
# those files *inside* `table inet fw4 { ... }`, where a full `table bridge
# ip4pt` declaration is a syntax error that breaks every firewall reload.
# A directly-loaded bridge table lives outside fw4's table and is untouched
# by fw4 reloads (a probe table survives `/etc/init.d/firewall reload`).

. "${IP4PT_CONF:-/etc/ip4pt/ip4pt.conf}"

# Template dir is overridable so the package layout (/usr/lib/ip4pt) and the
# test harness can point elsewhere; the rendered ruleset goes to /etc/ip4pt
# (next to the state dir; both survive sysupgrade via keep.d).
TMPL="${IP4PT_TMPL:-/etc/ip4pt/10-ip4pt.nft.tmpl}"
OUT=/etc/ip4pt/10-ip4pt.nft

if [ ! -f "$TMPL" ]; then
	logger -t ip4pt "template $TMPL not found -- is the package installed?"
	exit 1
fi

# Substitute every site-specific value from the single source of truth
# (ip4pt.conf) so interfaces never drift between config and ruleset (NFR-6).
sed -e "s/@ROUTER2_MAC@/$ROUTER2_MAC/" \
    -e "s/@UPLINK@/$UPLINK/" \
    -e "s/@DOWNLINK@/$DOWNLINK/" "$TMPL" >"$OUT"

# Check-then-load: never apply a ruleset that doesn't parse. `nft -f` is
# additive on an existing table (duplicate chains/rules), so delete the table
# first -- the reload below then re-creates it from scratch. A nonexistent
# table is not an error we care about (`2>/dev/null`).
nft -c -f "$OUT" || { logger -t ip4pt "rendered ruleset failed nft -c; not applying"; exit 1; }
nft delete table bridge ip4pt 2>/dev/null
# Belt and braces: if the delete failed for any real reason, loading would
# append duplicate chains/rules to the surviving table -- abort instead.
nft list table bridge ip4pt >/dev/null 2>&1 && {
	logger -t ip4pt "failed to delete existing table bridge ip4pt; aborting"
	exit 1
}
nft -f "$OUT"

# Loading the full table recreates it from the rendered file and *drops all
# runtime ip2mac elements*. Re-assert every persisted binding immediately,
# otherwise the map stays empty until each client sends another packet (the
# same-MAC self-heal in ip4pt-lib.sh is only the safety net for refreshes
# triggered by something other than this tool).
if [ -d "$STATE_DIR/hosts" ]; then
	for f in "$STATE_DIR"/hosts/*; do
		[ -f "$f" ] || continue
		nft add element bridge ip4pt ip2mac "{ $(basename "$f") : $(cat "$f") }" 2>/dev/null
	done
fi

logger -t ip4pt "loaded $OUT for ROUTER2_MAC=$ROUTER2_MAC"
