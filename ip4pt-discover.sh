#!/bin/sh
# ip4pt-discover.sh — watches ARP on eth2 (Router2's LAN) to learn real
# IPv4<->MAC bindings, and provisions/refreshes the corresponding
# nftables map entry + ebtables arpreply rule on the FritzBox-facing side.
# IPv6 needs no equivalent here -- see ip4pt-lib.sh for why.
#
# Requires the full `tcpdump` package (not tcpdump-mini) and `ebtables`
# (the package declares both as DEPENDS; installing by hand needs them too).
#
# Known limitation: a who-has request *sent by* the gateway itself also
# teaches the gateway's own IP->MAC binding. That entry is the identity
# mapping (Router2's LAN MAC), so it is harmless -- and it ages out through
# the normal GC path once the gateway goes quiet. It is not filtered out
# because the device cannot tell "the gateway" from "a client" without
# hard-coding the subnet, which NFR-6 forbids.

. "${IP4PT_LIB:-/etc/ip4pt/ip4pt-lib.sh}"

restore_hosts
logger -t ip4pt "discovery starting on $DISCOVER_IF"

# Extract (ip, mac) from one `tcpdump -l -n -e arp` line; on success calls
# update_host. Separated so it can be exercised directly by the parser test.
# Exact tcpdump wording/spacing varies by version -- run
# `tcpdump -i $DISCOVER_IF -l -n -e arp` by hand once and adjust the
# sed patterns below if your output doesn't match.
parse_arp_line() {
	line="$1"
	# In `tcpdump -e` output the Ethernet header ("<srcmac> > <dstmac>,
	# ethertype ...") may or may not be preceded by a timestamp -- live tcpdump
	# prints "<ts> <srcmac> > ...", while canned fixtures strip the timestamp.
	# So the sender MAC is the first field (within the leading header fields)
	# that IS a MAC, not a fixed position: the old field-1 assumption silently
	# killed the whole request path against real timestamped output, and the
	# field-2 guess before it broke the fixture dialect. Both are pinned by
	# tests now.
	src_mac=$(printf '%s\n' "$line" | awk '
		{ for (i = 1; i <= 4; i++)
			if ($i ~ /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/) { print $i; exit } }')

	case "$line" in
	*' is-at '*)
		ip=$(printf '%s\n' "$line" | sed -n 's/.*Reply \([0-9.]*\) is-at \([0-9a-f:]*\).*/\1/p')
		mac=$(printf '%s\n' "$line" | sed -n 's/.*Reply \([0-9.]*\) is-at \([0-9a-f:]*\).*/\2/p')
		# Self-announce (advertised MAC == frame source): never LEARN a new
		# binding from it (that is Router2 announcing a MAC it terminates
		# itself -- noise), but a client answering the gateway's unicast
		# probe is provably online, so an EXISTING identical binding is
		# refreshed -- otherwise a quiet-but-online client (one that never
		# initiates anything within OFFLINE_SECS) would be suspended and
		# falsely shown offline on the FritzBox (FR-13 false positive).
		if [ -n "$src_mac" ] && [ "$mac" = "$src_mac" ]; then
			# refresh an existing identical binding (quiet-but-online client
			# answering a unicast probe), never learn a new one
			if [ -f "$STATE_DIR/hosts/$ip" ] && [ "$(cat "$STATE_DIR/hosts/$ip")" = "$mac" ]; then
				update_host "$ip" "$mac"
			fi
			return 0
		fi
		;;
	*'Request who-has'*' tell '*)
		ip=$(printf '%s\n' "$line" | sed -n 's/.*tell \([0-9.]*\).*/\1/p')
		mac="$src_mac"
		;;
	*)
		return 0
		;;
	esac

	# An ARP probe (ACD/DAD, pre-DHCP) announces its sender as 0.0.0.0
	# ("who-has X tell 0.0.0.0"); a binding for the unspecified address is
	# never meaningful -- it would sit in the map and state forever (observed
	# on production as a stray 0.0.0.0 entry created by a probing client).
	[ "$ip" = "0.0.0.0" ] && return 0

	[ -n "$ip" ] && [ -n "$mac" ] && update_host "$ip" "$mac"
}

# Client hostnames from DHCP requests on the same mirrored port (FR-14).
# With `-v` tcpdump prints one DHCP packet as SEVERAL lines: the
# "BOOTP/DHCP, Request from <mac>" header names the client (its chaddr),
# and the options that follow arrive as separate continuation lines --
# including `Hostname (12), length 9: "phone"`. So this parser is stateful
# across lines (dhcp_mac holds the client whose packet is being printed),
# and every new BOOTP/DHCP header RESETS it: a Reply header carries no
# "Request from", matches nothing in the sed, and thereby clears any
# stale client -- a server ACK can never have its echoed options (or a
# canonicalized name) attributed to the previous requester. Only names
# the CLIENT itself sent are learned, which is exactly what the FritzBox
# shows too.
#
# The MAC captured here is the chaddr from the payload (identical to the
# frame source for Ethernet clients, and the key dnsmasq leases by) and
# tcpdump prints it in the same lowercase form as the ARP MACs, so it
# joins the hosts/<ip> content directly as the names/<mac> key.
#
# Deliberately its own parser variables -- never ip/mac/src_mac -- so the
# two line streams can never clobber each other's parse state.
parse_dhcp_line() {
	line="$1"

	case "$line" in
	*"BOOTP/DHCP, "*)
		# header line of a new packet: the one place "Request from
		# <mac>" appears. Also the state reset for every packet.
		dhcp_mac=$(printf '%s\n' "$line" | \
			sed -n 's/.*BOOTP\/DHCP, Request from \([0-9a-fA-F:]*\).*/\1/p')
		;;
	*"Hostname (12), length "*)
		# option line: 'Hostname (12), length 9: "phone"'. The case
		# gate matches only the unambiguous prefix -- a literal " in a
		# case pattern needs shell-quote escaping that trips up some
		# POSIX shells, so the exact anchored shape (double-quoted
		# value) is enforced by the sed instead, which leaves
		# dhcp_name empty for anything malformed.
		dhcp_name=$(printf '%s\n' "$line" | \
			sed -n 's/.*Hostname (12), length [0-9]*: "\(.*\)".*/\1/p')
		if [ -n "$dhcp_mac" ] && [ -n "$dhcp_name" ]; then
			store_client_name "$dhcp_mac" "$dhcp_name"
		fi
		# one header -> one name: a second (malformed) hostname line in
		# the same packet must not re-fire.
		dhcp_mac=""
		;;
	esac
}

# TCPCAP / TCPCAP_DHCP can be overridden (tests: feed canned lines via
# `cat fixture`). `-Z root` keeps tcpdump from trying to drop privileges to
# a host `tcpdump` user that does not exist (or isn't mapped) inside the
# userns the test harness runs in; on OpenWrt the daemon runs as root
# anyway, so it's a no-op there.
#
# Capture structure -- WHY this is not a plain `tcpdump | while read` pipeline:
# procd (and `stop`/`restart` generally) signals only the tracked pid, i.e.
# THIS shell, never the pipeline children. In a pipeline both tcpdump and
# the reader subshell get reparented to init on our death and keep
# provisioning as invisible orphans (observed on production: duplicate
# tcpdumps + stale readers kept writing nft/ebtables state). Instead THIS
# shell is a supervisor that blocks in `wait` -- the one place every POSIX
# shell (dash, busybox ash, bash alike) runs a pending trap immediately on
# a caught signal -- and the trap takes all the children down:
#   - procd stop/restart/respawn -> SIGTERM -> trap kills tcpdumps + readers.
#   - either tcpdump dying on its own -> its FIFO write end closes -> its
#     reader hits EOF -> the reader signals the supervisor -> this script
#     exits -> procd `respawn` brings the whole chain back.
# A plain `read` loop in THIS shell would not do: whether a blocked read is
# interrupted by a trapped signal is shell-dependent, so the trap could be
# deferred indefinitely -- the supervisor/wait shape is the portable one.
#
# DHCP runs as a SECOND capture with its own FIFO, never `-v` on the ARP
# one: `-v` changes the ARP wording ("Request, who-has" with an inserted
# comma and a hardware/proto preamble) and the seds above would silently
# stop matching -- the exact class of dialect bug that already killed the
# request path twice in this project's history. Two FIFOs (not one shared)
# also keep the death-detection below honest: with two writers on one
# FIFO the reader sees EOF only when BOTH close, so a silently dead
# capture would go unnoticed and procd would never respawn it.
FIFO="${IP4PT_FIFO:-/var/run/ip4pt-discover.fifo}"
FIFO_DHCP="${IP4PT_FIFO_DHCP:-$FIFO-dhcp}"
[ -p "$FIFO" ] || mkfifo "$FIFO" 2>/dev/null
[ -p "$FIFO_DHCP" ] || mkfifo "$FIFO_DHCP" 2>/dev/null
${TCPCAP:-tcpdump -Z root -i "$DISCOVER_IF" -l -n -e arp} >"$FIFO" 2>/dev/null &
cap_pid=$!
# No -e here: the client MAC is the chaddr tcpdump prints in the payload
# ("Request from <mac>"), so the Ethernet header would only add lines to
# skip. `-v` is what makes tcpdump print the options (hostname) at all.
${TCPCAP_DHCP:-tcpdump -Z root -i "$DISCOVER_IF" -l -n -v 'udp dst port 67'} >"$FIFO_DHCP" 2>/dev/null &
cap_dhcp_pid=$!

# The readers run as children (subshells reset non-ignored traps to
# default, so they die on a plain SIGTERM); THIS shell stays the
# supervisor. Each reader ends with an explicit `kill -TERM $$`: in a
# subshell `$$` is the PARENT's pid, i.e. the supervisor itself -- so a
# reader whose capture died gets EOF and wakes the supervisor out of its
# `wait`, exactly like a child dying in place would. That keeps the
# "either capture death bounces the daemon" invariant for BOTH captures,
# without which a dead DHCP tcpdump would linger unnoticed.
(
	while IFS= read -r line; do
		parse_arp_line "$line"
	done <"$FIFO"
	kill -TERM $$
) &
reader_pid=$!
(
	while IFS= read -r line; do
		parse_dhcp_line "$line"
	done <"$FIFO_DHCP"
	kill -TERM $$
) &
reader_dhcp_pid=$!

cleanup_capture() {
	kill "$reader_pid" "$cap_pid" "$reader_dhcp_pid" "$cap_dhcp_pid" 2>/dev/null
	wait "$reader_pid" 2>/dev/null
	wait "$cap_pid" 2>/dev/null
	wait "$reader_dhcp_pid" 2>/dev/null
	wait "$cap_dhcp_pid" 2>/dev/null
	rm -f "$FIFO" "$FIFO_DHCP"
}
trap cleanup_capture TERM INT

# Block here for the daemon's whole life. procd's SIGTERM interrupts this
# wait and runs the trap (every POSIX shell runs pending traps immediately
# in wait), which reaps ALL the children. If either child dies on its own
# instead (tcpdump crash -> EOF -> reader exits and signals us), wait
# returns, the explicit cleanup below finishes the others off, and this
# script exits so procd `respawn` brings the whole chain back. Killing an
# already-dead pid and re-waiting are silent no-ops, so the double cleanup
# is harmless.
wait "$reader_pid" 2>/dev/null
cleanup_capture
exit 0
