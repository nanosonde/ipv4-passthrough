#!/bin/sh
# ip4pt-lib.sh — shared functions, sourced by ip4pt-discover.sh and
# ip4pt-gc.sh. Not meant to be run directly.
#
# eth0+eth1 are a plain bridge (br-ip4pt), which is also why IPv6 needs
# nothing here -- a bridge never touches the Ethernet header, so whatever
# already makes v6 work upstream keeps working as-is. For IPv4: an
# nftables bridge-family rule rewrites the data-plane MAC (see
# 10-ip4pt.nft.tmpl), and a per-client ebtables rule answers ARP
# requests on demand -- no interfaces, no gratuitous ARP.
#
# Two-tier host lifecycle, both counted from the host's last ARP observed
# on the mirror (the state files' mtimes, refreshed by discovery):
#   >OFFLINE_SECS silent -> suspend (FR-13): only the arpreply rule is
#     removed, so the FritzBox stops getting answers and flips the host
#     to offline at its own probe cadence. Everything else is kept.
#   >STALE_SECS silent   -> deprovision (FR-10): the whole binding goes.
# OFFLINE_SECS=0 (or unset) disables the suspend tier -- silent hosts then
# stay online on the FritzBox until the full STALE_SECS removal.

. "${IP4PT_CONF:-/etc/ip4pt/ip4pt.conf}"

mkdir -p "$STATE_DIR/hosts" "$STATE_DIR/names"

# The one arpreply rule shape, factored out so the add/delete callers
# can never drift apart (NFR-6 in spirit). `-p 0x0806`: numeric EtherType
# for ARP -- stock OpenWrt ships no /etc/ethertypes, so the symbolic `ARP`
# name is unusable there.
#
# The rule-layer helpers below use ONLY their positional parameters, never
# named variables: POSIX sh has no `local`, so an assignment here would
# clobber the caller's same-named variable. Not hypothetical -- the old
# `mac="$2"` in remove_host_rules stomped update_host's new-MAC value
# before it reached the state file, so an IP that changed devices could
# never re-bind; it flapped deprovision/provision on every ARP instead.
ebt_arpreply_add() {   # <ip> <mac>
	ebtables -t nat -A PREROUTING -i "$UPLINK" -p 0x0806 \
		--arp-opcode Request --arp-ip-dst "$1" \
		-j arpreply --arpreply-mac "$2" --arpreply-target DROP
}

ebt_arpreply_del() {   # <ip> <mac>
	ebtables -t nat -D PREROUTING -i "$UPLINK" -p 0x0806 \
		--arp-opcode Request --arp-ip-dst "$1" \
		-j arpreply --arpreply-mac "$2" --arpreply-target DROP
}

# ebtables-nft has NO rule-check verb (-C is "change rule N" there, unlike
# iptables) -- a `-C <spec>` invocation always errors, so it can not be used
# for idempotency. Kernel truth is read from the chain listing instead:
# exit 0 iff this host's exact rule is installed. The trailing space after
# the IP anchors the match (10.10.10.1 must not match 10.10.10.10).
arpreply_present() {   # <ip> <mac>
	ebtables -t nat -L PREROUTING 2>/dev/null | \
		grep -q -- "--arp-ip-dst $1 .*--arpreply-mac $2"
}

add_host_rules() {   # <ip> <mac>
	# Idempotent: the nft map add is quiet when the element exists
	# (`2>/dev/null`), and the arpreply rule is only appended when the
	# listing says it is absent -- procd respawn re-runs restore_hosts(),
	# and legacy ebtables would happily stack duplicate -A rules.
	nft add element bridge ip4pt ip2mac "{ $1 : $2 }" 2>/dev/null
	arpreply_present "$1" "$2" || ebt_arpreply_add "$1" "$2" 2>/dev/null
	logger -t ip4pt "provisioned $1 via $2"
}

remove_host_rules() {   # <ip> <mac>
	nft delete element bridge ip4pt ip2mac "{ $1 }" 2>/dev/null
	ebt_arpreply_del "$1" "$2" 2>/dev/null
	logger -t ip4pt "deprovisioned $1"
}

# FR-13: stop answering ARP for a host that has gone quiet on the mirror, so
# the FritzBox's own probes get no reply and it flips the host to offline.
# Only the rule goes away -- binding, map element and state file all stay,
# so the host is back online within a second of its next observed ARP.
suspend_host_rules() {   # <ip> <mac>
	ebt_arpreply_del "$1" "$2" 2>/dev/null
	logger -t ip4pt "suspended $1 -- no ARP for >${OFFLINE_SECS}s; FritzBox will mark it offline"
}

update_host() {
	ip="$1"; mac="$2"
	file="$STATE_DIR/hosts/$ip"

	if [ -f "$file" ]; then
		oldmac=$(cat "$file")
		if [ "$oldmac" = "$mac" ]; then
			touch "$file"
			# Re-assert BOTH rule layers, quietly: this branch lifts a GC
			# suspension when a silent host comes back (FR-13), and it is the
			# self-heal path when anything recreated the `bridge ip4pt` table
			# and dropped runtime map elements. `2>/dev/null` keeps the nft
			# re-assert quiet when the element is already present.
			nft add element bridge ip4pt ip2mac "{ $ip : $mac }" 2>/dev/null
			arpreply_present "$ip" "$mac" || ebt_arpreply_add "$ip" "$mac" 2>/dev/null
			return
		fi
		remove_host_rules "$ip" "$oldmac"
	fi

	echo "$mac" >"$file"
	add_host_rules "$ip" "$mac"
}

deprovision_host() {
	ip="$1"
	mac=$(cat "$STATE_DIR/hosts/$ip" 2>/dev/null)
	[ -z "$mac" ] && return
	remove_host_rules "$ip" "$mac"
	rm -f "$STATE_DIR/hosts/$ip"
}

# Client hostnames, learned from DHCP requests on the same mirrored port
# (see ip4pt-discover.sh's DHCP parser) and keyed by the client's MAC --
# at DHCP-request time the client may not even hold an IP yet, and the
# MAC identity survives IP churn, so this is deliberately a separate
# namespace from the ip-keyed bindings. Display-only: never used for
# discovery (FR-7 stays ARP-only), never removed by the GC or the LuCI
# Remove actions -- a returning client just refreshes its name file.
# Names are small and bounded by the distinct-client count (A4), so
# they accumulate without GC on purpose.
store_client_name() {   # <mac> <name>
	# Hostname sanity: RFC 952/1123 letters, digits, dots, hyphens only,
	# capped at 63 chars. Everything else (spaces, quotes, UTF-8, an
	# embedded quote smuggled in through tcpdump's quoted string) is
	# rejected BEFORE it ever becomes a filename content or a JSON token.
	case "$2" in
	""|*[!A-Za-z0-9._-]*)
		return 0
		;;
	esac
	name=$(printf '%s' "$2" | cut -c 1-63)
	# Write-if-changed only: lease renewals re-send the same option 12
	# every few hours, and rewriting on every request would both wear the
	# flash (NFR-4) and spam the log (NFR-9).
	if [ -f "$STATE_DIR/names/$1" ] && [ "$(cat "$STATE_DIR/names/$1")" = "$name" ]; then
		return 0
	fi
	printf '%s\n' "$name" >"$STATE_DIR/names/$1"
	logger -t ip4pt "learned name $name for $1"
}

# Re-apply every persisted (ip, mac) pair at startup -- the nft map and
# ebtables rules are runtime kernel state and don't survive a reboot on
# their own, even though the state files under $STATE_DIR do.
restore_hosts() {
	n=0
	for f in "$STATE_DIR"/hosts/*; do
		[ -f "$f" ] || continue
		ip=$(basename "$f")
		mac=$(cat "$f")
		[ -n "$mac" ] && add_host_rules "$ip" "$mac" && n=$((n + 1))
	done
	logger -t ip4pt "restored $n persisted host(s) from $STATE_DIR"
}
