#!/bin/sh
# tests/test-e2e.sh -- end-to-end smoke of the whole chain in network
# namespaces. Runs ROOTLESS: everything happens inside one throw-away
# user+mount namespace (unshare -rmn); inside it we hold real root, so named
# netns, veth, bridges, nft bridge-family and ebtables all work without the
# host needing anything but the ip/nft/ebtables/tcpdump tools installed.
#
# Exercises: ARP discovery via a software port-mirror (tc mirred), the
# ebtables arpreply answer carrying the client's real MAC to the FritzBox,
# the bridge-family nft MAC rewrite, no NAT (client IP visible on the fb
# link), and reboot persistence via restore_hosts.
#
# Usage:  sh tests/test-e2e.sh            [recommended; self-unshares]
#         SKIP_PERSIST=1 sh tests/test-e2e.sh
# (Debug: IP4PT_E2E_INNER=1 sh tests/test-e2e.sh  -- skip the unshare wrapper)
#
# Layout:
#   fb  (FritzBox, 192.168.178.1) -- veth -- eth0 [dut] eth1 -- veth -- wan [r2] lan -- veth -- [cl]
#                                                 eth2 <--- tc mirred mirror of r2:lan (ingress+egress)

set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

if [ "${IP4PT_E2E_INNER:-0}" != 1 ]; then
	command -v unshare >/dev/null || { echo "need unshare(1)"; exit 2; }
	# userns+mount+net; inside it we throw a private tmpfs over /run so
	# `ip netns add` can create its bind-mount targets (the real /run is
	# read-only for an unprivileged bind). --propagation private keeps
	# every mount, netns and interface throw-away: vanish with the script.
	exec unshare -rmn --propagation private sh -c '
		mount -t tmpfs tmpfs /run && mkdir -p /run/netns
		exec env IP4PT_E2E_INNER=1 PATH="/sbin:/usr/sbin:'"$PATH"'" sh "'"$0"'" "$@"
	' sh "$@"
	exit 127  # unreachable unless exec failed
fi

# ---------------- now running with uid=0 inside the throwaway ns ------------

missing=""
for t in ip nft ebtables tcpdump tc; do
	command -v "$t" >/dev/null || missing="$missing $t"
done
[ -z "$missing" ] || { echo "missing tools:$missing"; exit 2; }

sh "$ROOT/tests/lib/cleanup.sh" 2>/dev/null   # wipe debris from earlier runs
trap 'sh "$ROOT/tests/lib/cleanup.sh" 2>/dev/null' EXIT

IP4PT_FAKE_NET=0
. "$ROOT/tests/lib/env.sh"

echo "== building lab: namespaces + veth + bridge + mirror (rootless) =="

# MAC/IP scheme (deterministic). The FritzBox side keeps its factory-default
# LAN 192.168.178.0/24 (FritzBox at .1, Router2 WAN at .2); Router2's LAN with
# the clients is the distinct 10.10.10.0/24 (gateway at .1) per SPEC §1.
FB_MAC=02:00:00:00:00:f0      # FritzBox LAN port
R2WAN_MAC=02:00:00:00:00:02   # Router2 WAN  == ROUTER2_MAC in the test conf
R2LAN_MAC=02:00:00:00:00:01   # Router2 LAN (gateway for the client)
CL_MAC=02:00:00:00:00:0a      # the one client behind Router2
FB_IP=192.168.178.1
R2WAN_IP=192.168.178.2
GW_IP=10.10.10.1              # Router2's LAN gateway address
CL_IP=10.10.10.10             # the one client behind Router2

ip netns add ip4pt_fb;  ip netns add ip4pt_dut
ip netns add ip4pt_r2;  ip netns add ip4pt_cl

# Build every veth pair from *inside* one of the two namespaces it connects --
# mixing "create in the init ns, then move one end" with "create by netns exec
# from the other end" leaves a peer unnamed in some kernel builds, and the
# link then silently never comes up. Always: create at one end, move the other.
ip netns exec ip4pt_dut ip link add eth0 type veth peer name v-fb
ip netns exec ip4pt_dut ip link set v-fb netns ip4pt_fb
ip netns exec ip4pt_fb  ip link set v-fb address $FB_MAC
ip netns exec ip4pt_dut ip link add eth1 type veth peer name wan
ip netns exec ip4pt_dut ip link set wan netns ip4pt_r2
ip netns exec ip4pt_r2  ip link set wan address $R2WAN_MAC
ip netns exec ip4pt_r2  ip link add lan type veth peer name ceth
ip netns exec ip4pt_r2  ip link set ceth netns ip4pt_cl
ip netns exec ip4pt_r2  ip link set lan address $R2LAN_MAC
ip netns exec ip4pt_cl  ip link set ceth address $CL_MAC
# the mirror pair: mir lives in r2, eth2 in the DUT (discovery only)
ip netns exec ip4pt_r2  ip link add mir type veth peer name eth2
ip netns exec ip4pt_r2  ip link set eth2 netns ip4pt_dut

# DUT: the bridge (eth0+eth1 only; eth2 must NOT be a bridge port -- NFR-8).
# Every veth pair is created before anything joins br-ip4pt so the bridge
# learns the topology from real traffic rather than inheriting stale fdb
# entries from the setup sequence.
ip -n ip4pt_dut link set lo up
ip -n ip4pt_dut link set eth2 up
ip -n ip4pt_dut link add br-ip4pt type bridge
ip -n ip4pt_dut link set eth0 master br-ip4pt
ip -n ip4pt_dut link set eth1 master br-ip4pt
ip -n ip4pt_dut link set eth0 up
ip -n ip4pt_dut link set eth1 up
ip -n ip4pt_dut link set br-ip4pt up

# fb: FritzBox-side config on its factory LAN. The on-link route for the
# client subnet is what makes it ARP for the client directly (the behavior
# this project emulates).
ip -n ip4pt_fb link set lo up
ip -n ip4pt_fb link set v-fb up
ip -n ip4pt_fb addr add $FB_IP/24 dev v-fb
ip -n ip4pt_fb route add 10.10.10.0/24 dev v-fb

# r2: Router2, NAT-less forwarding
ip -n ip4pt_r2 link set lo up
ip -n ip4pt_r2 link set wan up
ip -n ip4pt_r2 link set lan up
ip -n ip4pt_r2 link set mir up
ip -n ip4pt_r2 addr add $R2WAN_IP/24 dev wan
ip -n ip4pt_r2 addr add $GW_IP/24 dev lan
ip netns exec ip4pt_r2 sysctl -q -w net.ipv4.ip_forward=1

# cl: the client
ip -n ip4pt_cl link set lo up
ip -n ip4pt_cl link set ceth up
ip -n ip4pt_cl addr add $CL_IP/24 dev ceth
ip -n ip4pt_cl route add default via $GW_IP

# The port mirror: everything on r2:lan (ingress+egress) is copied to mir,
# which terminates on dut:eth2. `protocol all` is essential -- the default is
# `ip`, which would silently skip ARP frames and discovery would see nothing.
ip netns exec ip4pt_r2 tc qdisc replace dev lan clsact
ip netns exec ip4pt_r2 tc filter add dev lan ingress protocol all \
	matchall action mirred egress mirror dev mir
ip netns exec ip4pt_r2 tc filter add dev lan egress protocol all \
	matchall action mirred egress mirror dev mir

# Static ARP on r2's WAN side so inter-router traffic never depends on the
# DUT (which must only ever ARP-reply for *client* IPs, per FR-4). Without it
# r2 ARPs out wan for the FritzBox, gets no reply once the bridge fdb entry
# ages out between phases, and fb<->client traffic dies.
ip netns exec ip4pt_r2 ip neigh replace $FB_IP lladdr $FB_MAC dev wan nud permanent

# --- install the bridge-family nft rules in the dut ns ----------------------
# Render the template exactly like ip4pt-gen-nft.sh does (minus the boot
# loading done by the init script, which doesn't exist in a bare namespace).
# The interface names go in as literals here because the test harness's
# conf uses eth0/eth1/eth2 by design. Direct `nft -f` load (the fw4
# /etc/nftables.d include path would be a syntax error inside `table inet
# fw4` -- see ip4pt-gen-nft.sh).
sed -e "s/@ROUTER2_MAC@/$R2WAN_MAC/" -e "s/@UPLINK@/eth0/" -e "s/@DOWNLINK@/eth1/" \
	"$ROOT/10-ip4pt.nft.tmpl" > "$TESTS_TMP/etc/ip4pt/10-ip4pt.nft"
check "nft table loads (bridge family + arpreply-capable kernel)" \
	ip netns exec ip4pt_dut nft -f "$TESTS_TMP/etc/ip4pt/10-ip4pt.nft"

# The load path must never touch fw4's include dir: prove the table survives
# a firewall reload (fw4 recreates *its own* table only, never ours).
check "table survives an fw4 reload (never in fw4's include dir)" sh -c '
	before=$(ip netns exec ip4pt_dut nft list set bridge ip4pt ip2mac 2>/dev/null | sha256sum)
	ip netns exec ip4pt_dut nft add table inet fw4_probe_reload 2>/dev/null
	ip netns exec ip4pt_dut nft delete table inet fw4_probe_reload 2>/dev/null
	after=$(ip netns exec ip4pt_dut nft list set bridge ip4pt ip2mac 2>/dev/null | sha256sum)
	[ "$before" = "$after" ]'

check "ebtables accepts an arpreply rule (README item 1 probe)" sh -c '
	ip netns exec ip4pt_dut ebtables -t nat -A PREROUTING -i eth0 -p 0x0806 \
		--arp-opcode Request --arp-ip-dst 203.0.113.99 \
		-j arpreply --arpreply-mac 02:00:00:00:00:99 --arpreply-target DROP &&
	ip netns exec ip4pt_dut ebtables -t nat -D PREROUTING -i eth0 -p 0x0806 \
		--arp-opcode Request --arp-ip-dst 203.0.113.99 \
		-j arpreply --arpreply-mac 02:00:00:00:00:99 --arpreply-target DROP'

# --- start the production daemons inside the dut namespace ------------------
# They must see the harness's fake `logger` (TESTS_TMP is exported so the
# shim finds its log file) while nft/ebtables stay the real tools.
start_daemons() {
	ip netns exec ip4pt_dut setsid sh -c \
		"export PATH='$PATH' IP4PT_CONF='$IP4PT_CONF' IP4PT_LIB='$IP4PT_LIB' TESTS_TMP='$TESTS_TMP'; \
			{ echo \"env: PATH=\$PATH IP4PT_LIB=\$IP4PT_LIB\"; \
			  echo \"tools: nft=\$(command -v nft) tcpdump=\$(command -v tcpdump)\"; \
			  timeout 120 sh '$ROOT/ip4pt-discover.sh'; echo \"discover exited \$?\"; } \
			>\"$TESTS_TMP/log/discover.out\" 2>&1" &
	ip netns exec ip4pt_dut setsid sh -c \
		"export PATH='$PATH' IP4PT_CONF='$IP4PT_CONF' IP4PT_LIB='$IP4PT_LIB' TESTS_TMP='$TESTS_TMP'; \
			timeout 120 sh '$ROOT/ip4pt-gc.sh' \
			>\"$TESTS_TMP/log/gc.out\" 2>&1" &
}
start_daemons
# tcpdump needs a moment to attach the live capture before any ARP can appear;
# and the cl<->r2 neighbor caches must be flushed, or the first pings run on
# warm caches and no ARP is ever generated for the mirror to see.
sleep 2
ip netns exec ip4pt_cl ip neigh flush dev ceth 2>/dev/null || true
ip netns exec ip4pt_r2 ip neigh flush dev lan  2>/dev/null || true

# ===========================================================================
echo "== scenario 1: discovery via the mirrored port (FR-7) =="
# ===========================================================================
# Several short pings over a few seconds: each one forces a fresh ARP exchange
# on r2:lan once its cache entry is flushed, and the mirror shows both the
# request and the reply. A single ping is not enough -- the daemon may still
# be attaching its capture when it happens.
for i in 1 2 3 4 5; do
	ip netns exec ip4pt_cl ping -c 1 -W 1 $GW_IP >/dev/null 2>&1 || true
	ip netns exec ip4pt_cl ip neigh flush dev ceth 2>/dev/null || true
	sleep 1
done

check "binding for client learned" poll 10 have_binding $CL_IP $CL_MAC
check "nft map gained the client element" \
	poll 10 sh -c "ip netns exec ip4pt_dut nft list map bridge ip4pt ip2mac | grep -q '$CL_IP : $CL_MAC'"
check "ebtables gained the arpreply rule on eth0" \
	sh -c "ip netns exec ip4pt_dut ebtables -t nat -L PREROUTING | grep -q -- '--arp-ip-dst $CL_IP.*--arpreply-mac $CL_MAC'"

# ===========================================================================
echo "== scenario 2: FritzBox ARP + data path (FR-1..FR-4) =="
# ===========================================================================
# Snapshot how many client-MAC frames the fb link had seen BEFORE fb ever
# asked for the client -- any such frame would be an unsolicited-ARP
# violation of FR-5. Count with a short capture window so this doesn't block.
cnt_client_frames() {
	ip netns exec ip4pt_fb timeout 2 tcpdump -Z root -i v-fb -n -e \
		"ether src $CL_MAC" 2>/dev/null | grep -c '>'
}
before=$(cnt_client_frames)

check "fb can ping the client behind the other router (round trip, no NAT)" \
	ip netns exec ip4pt_fb ping -c 2 -W 3 $CL_IP
check "fb's ARP cache maps the client IP to the client's REAL MAC" \
	sh -c "ip netns exec ip4pt_fb ip neigh show $CL_IP | grep -qi 'lladdr $CL_MAC'"
check "fb's ARP cache does NOT hold Router2's WAN MAC for the client" \
	sh -c "! ip netns exec ip4pt_fb ip neigh show $CL_IP | grep -qi 'lladdr $R2WAN_MAC'"

# prove the rewrite + no-NAT on the wire: frames from the client seen on the
# fb link must carry the client's real source MAC and the un-NATted client IP.
ip netns exec ip4pt_fb timeout 4 tcpdump -Z root -i v-fb -n -e -c 6 \
	"src host $CL_IP" > "$TESTS_TMP/log/fb-cap.txt" 2>&1 &
cappid=$!
ip netns exec ip4pt_cl ping -c 2 -W 2 $FB_IP >/dev/null 2>&1 || true
wait $cappid 2>/dev/null
check "captured frames show client real src MAC + un-NATted client IP" \
	sh -c "grep -q '$CL_MAC >' '$TESTS_TMP/log/fb-cap.txt'"
check "captured frames never use Router2's WAN MAC as source" \
	sh -c "! grep -q '$R2WAN_MAC >' '$TESTS_TMP/log/fb-cap.txt'"

# ===========================================================================
echo "== scenario 3: no unsolicited ARP from the DUT (FR-5) =="
# ===========================================================================
# Any client-MAC frame on the fb link *before* fb asked for it would be a
# violation. Count from before scenario 2 (nothing happened yet on that link).
check "zero client frames on the fb link before fb ever ARPed for it" \
	sh -c "[ '$before' -eq 0 ]"

# ===========================================================================
echo "== scenario 4: persistence + restore at startup (FR-8, FR-9) =="
# ===========================================================================
if [ "${SKIP_PERSIST:-0}" = 1 ]; then
	echo "skip - persistence scenario (SKIP_PERSIST=1)"
else
	# Simulate a reboot of the DUT: wipe all kernel state (nft map +
	# ebtables chain), stop the daemons, keep only the files under state/.
	ip netns exec ip4pt_cl ip neigh flush dev ceth 2>/dev/null || true
	ip netns exec ip4pt_fb ip neigh flush $CL_IP 2>/dev/null || true
	ip netns pids ip4pt_dut | xargs -r kill 2>/dev/null; sleep 1
	# Orphan regression (bug 8): SIGTERM to the daemon pids must have taken
	# the capture pipeline down with them -- procd only ever signals those
	# pids, so any surviving tcpdump here would mean the trap-based
	# supervision regressed and stop/restart leaks children again.
	check "no capture orphan survives daemon SIGTERM" \
		sh -c "! ip netns pids ip4pt_dut | xargs -r ps -o comm= 2>/dev/null | grep -q tcpdump"
	ip netns exec ip4pt_dut nft flush map bridge ip4pt ip2mac
	ip netns exec ip4pt_dut ebtables -t nat -F PREROUTING
	check "kernel state really empty before restore" \
		sh -c "! ip netns exec ip4pt_dut nft list map bridge ip4pt ip2mac | grep -q $CL_IP"

	# Watch eth2 during the whole restore: if restore needed even one ARP
	# to relearn the binding, this capture shows it and the test fails.
	ip netns exec ip4pt_dut timeout 9 tcpdump -Z root -i eth2 -n arp -c 5 \
		> "$TESTS_TMP/log/eth2-restore-cap.txt" 2>&1 &
	restorecap=$!

	ip netns exec ip4pt_dut setsid sh -c \
		"PATH='$PATH' IP4PT_CONF='$IP4PT_CONF' IP4PT_LIB='$IP4PT_LIB' TESTS_TMP='$TESTS_TMP' \
			sh '$ROOT/ip4pt-discover.sh' >'$TESTS_TMP/log/discover2.out' 2>&1" &
	sleep 2

	check "restore repopulated the nft map from disk alone" \
		sh -c "ip netns exec ip4pt_dut nft list map bridge ip4pt ip2mac | grep -q '$CL_IP : $CL_MAC'"
	check "restore re-added the ebtables arpreply rule" \
		sh -c "ip netns exec ip4pt_dut ebtables -t nat -L PREROUTING | grep -q $CL_IP"

	check "fb->client still pingable with kernel-restored state only" \
		ip netns exec ip4pt_fb ping -c 1 -W 3 $CL_IP

	wait $restorecap 2>/dev/null
	# The capture WILL contain a gateway re-ARP (we flushed cl's cache for
	# the gateway as part of the simulated reboot, so its final ping re-asks
	# "who has $GW_IP"). What FR-9 forbids is a relearn of the *client*
	# binding $CL_IP -- the whole point is that the restored-on-disk entry
	# answers fb's ARP for $CL_IP without the client being contacted at all.
	check "no client ARP ($CL_IP) was re-learned on eth2 during restore" \
		sh -c "! grep -Eq 'who-has $CL_IP tell|Reply $CL_IP is-at' '$TESTS_TMP/log/eth2-restore-cap.txt'"
fi

# ===========================================================================
echo "== scenario 5: offline propagation + recovery (FR-13) =="
# ===========================================================================
# A host that goes silent on the mirror must stop being ANSWERED by the DUT:
# GC suspends its arpreply rule, so the FritzBox's probe gets no reply and
# the host goes offline in its overview. The binding must SURVIVE (nft map
# + state file), and one fresh ARP from the client must bring it back.

# Scenario 4 killed every process in the DUT ns and restarted only
# discovery; the GC is what drives the suspension, so start it again.
start_gc() {
	ip netns exec ip4pt_dut setsid sh -c \
		"export PATH='$PATH' IP4PT_CONF='$IP4PT_CONF' IP4PT_LIB='$IP4PT_LIB' TESTS_TMP='$TESTS_TMP'; \
			timeout 120 sh '$ROOT/ip4pt-gc.sh' \
			>'$TESTS_TMP/log/gc2.out' 2>&1" &
}
start_gc

# Make the client look silent: backdate its state mtime well past
# OFFLINE_SECS (45) so the 1s GC cycle suspends it deterministically.
silent=$(( $(date +%s) - 90 ))
state_file="$TESTS_TMP/etc/ip4pt/state/hosts/$CL_IP"
touch -t "$(date -d "@$silent" +%Y%m%d%H%M.%S)" "$state_file" 2>/dev/null || \
	touch -d "@$silent" "$state_file"

check "rule suspended after silence (arpreply gone, binding kept)" \
	poll 12 sh -c "! ip netns exec ip4pt_dut ebtables -t nat -L PREROUTING | grep -q -- '--arp-ip-dst $CL_IP '"
check "binding survived suspension (state file kept)"            test -f "$state_file"
check "binding survived suspension (map element kept)" \
	sh -c "ip netns exec ip4pt_dut nft list map bridge ip4pt ip2mac | grep -q '$CL_IP : $CL_MAC'"
check "suspend logged exactly once (no per-cycle re-log)" \
	sh -c '[ "$(grep -c "suspended $CL_IP" "$TESTS_TMP/log/syslog.log")" -eq 1 ]'

# The FritzBox's probe must now go unanswered: flush its cache entry, force
# an ARP exchange, and prove no reply came back for the suspended host.
ip netns exec ip4pt_fb ip neigh flush $CL_IP 2>/dev/null
ip netns exec ip4pt_fb timeout 6 tcpdump -Z root -i v-fb -n -e arp \
	> "$TESTS_TMP/log/fb-offline-cap.txt" 2>&1 &
probecap=$!
ip netns exec ip4pt_fb ping -c 1 -W 1 $CL_IP >/dev/null 2>&1 || true
wait $probecap 2>/dev/null
check "fb's ARP probe for the suspended host goes unanswered" \
	sh -c "grep -q 'who-has $CL_IP' '$TESTS_TMP/log/fb-offline-cap.txt' && \
		! grep -q 'Reply $CL_IP is-at' '$TESTS_TMP/log/fb-offline-cap.txt'"
check "suspended host not pingable from fb (probe window)" \
	sh -c "! ip netns exec ip4pt_fb ping -c 1 -W 2 $CL_IP"

# Recovery: one fresh ARP from the client (it re-asks for its gateway after
# a cache flush) restores the rule, and the host is reachable again.
ip netns exec ip4pt_dut timeout 12 tcpdump -Z root -i eth2 -n -e arp \
	> "$TESTS_TMP/log/eth2-recovery-cap.txt" 2>&1 &
reccap=$!
sleep 2   # let the capture attach BEFORE any ARP can be missed
ip netns exec ip4pt_cl ip neigh flush dev ceth 2>/dev/null
[ -n "${E2E_DEBUG:-}" ] && { echo "DBG client neigh after flush:"; ip netns exec ip4pt_cl ip neigh show dev ceth; }
ip netns exec ip4pt_cl ping -c 1 -W 3 $GW_IP >/dev/null 2>&1 || true
[ -n "${E2E_DEBUG:-}" ] && { echo "DBG client neigh after ping:"; ip netns exec ip4pt_cl ip neigh show dev ceth; echo "DBG r2 neigh:"; ip netns exec ip4pt_r2 ip neigh show dev lan; }
sleep 2
check "arpreply rule restored after one fresh client ARP" \
	sh -c "ip netns exec ip4pt_dut ebtables -t nat -L PREROUTING | grep -q -- '--arp-ip-dst $CL_IP .*--arpreply-mac $CL_MAC'"
check "suspended host is reachable again after recovery" \
	ip netns exec ip4pt_fb ping -c 1 -W 3 $CL_IP
kill $reccap 2>/dev/null

summary
