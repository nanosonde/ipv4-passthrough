#!/bin/sh
# tests/test-parser.sh -- root-free parser test. Feeds recorded tcpdump
# ARP lines (tests/fixtures/arp-lines.txt) through ip4pt-discover.sh with
# TCPCAP="cat <fixture>" and every external command stubbed out, then checks
# which (ip, mac) pairs reached update_host / the rule layer.
#
# Usage: sh tests/test-parser.sh      (run in a fresh login shell or via
#                                      `env -i sh ...` for full isolation;
#                                      we sanitize env below anyway)

set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

# Sanitize anything that could leak in from a user login shell (e.g. if
# the real /etc/ip4pt/ip4pt.conf exists with GC_INTERVAL etc.): the env
# harness re-exports canonical values after this unset.
unset UPLINK DOWNLINK DISCOVER_IF STATE_DIR STALE_SECS GC_INTERVAL OFFLINE_SECS ROUTER2_MAC

. "$ROOT/tests/lib/env.sh"

echo "== parser fixture test =="

# Drive the discovery daemon against the fixture; it exits when the fixture
# is exhausted (cat terminates), so no timeout wrapper needed. The ARP
# fixture feeds the ARP reader, the DHCP fixture the DHCP reader -- the
# canned-DHCP path proves the hostname capture works without a real DHCP
# exchange.
#
# The DHCP feed is wrapped in a script that sleeps AFTER cat: a bare
# `cat fixture` closes the FIFO immediately, and the DHCP reader's
# death-of-capture signal (its `kill -TERM $$`) would then tear the daemon
# down before the ARP fixture finished parsing -- the EOF bounce is
# production semantics (a dead capture must bounce the daemon), so the
# TEST has to model a long-lived capture instead.
cat >"$TESTS_TMP/bin/cat-dhcp-fixture" <<'FAKE_CAP'
#!/bin/sh
cat "$1"
sleep 5
FAKE_CAP
chmod +x "$TESTS_TMP/bin/cat-dhcp-fixture"
TCPCAP="cat $ROOT/tests/fixtures/arp-lines.txt" \
TCPCAP_DHCP="$TESTS_TMP/bin/cat-dhcp-fixture $ROOT/tests/fixtures/dhcp-lines.txt" \
	sh "$ROOT/ip4pt-discover.sh"

# --- the bindings that MUST be learned -----------------------------------
check "request-path: 10.10.10.10 learned from who-has tell"        have_binding 10.10.10.10 02:00:00:00:00:0a
check "request-path: 10.10.10.11 learned (2nd client)"             have_binding 10.10.10.11 02:00:00:00:00:0b
check "request-path: 10.10.10.12 learned from LIVE timestamped line" have_binding 10.10.10.12 02:00:00:00:00:0c

# --- and nothing else -----------------------------------------------------
# The gateway's own `is-at` reply is a self-announce (payload MAC == frame
# source) and must not be bound. That said, a who-has *request sent by* the
# gateway is NOT filtered -- see ip4pt-discover.sh's known-limitation note;
# the fixture deliberately contains no such request, so this asserts exactly
# what the parser promises, no more.
check_not "gateway 10.10.10.1 is not learned from its self-announce reply" \
	test -f "$TESTS_TMP/etc/ip4pt/state/hosts/10.10.10.1"
check_not "no binding for the FritzBox-side junk IP 192.168.178.1"  test -f "$TESTS_TMP/etc/ip4pt/state/hosts/192.168.178.1"
check_not "ARP probe (tell 0.0.0.0) yields no state file"             test -f "$TESTS_TMP/etc/ip4pt/state/hosts/0.0.0.0"
check_not "ARP probe never reaches the nft map"                      grep -q "0.0.0.0 :" "$TESTS_TMP/log/map.log"
check "exactly 4 state files (clients only) from the whole fixture" sh -c '[ "$(ls -A "$TESTS_TMP/etc/ip4pt/state/hosts" | wc -l)" -eq 4 ]'

# --- idempotency / dedup at the rule layer --------------------------------
# Each distinct *client* must be PROVISIONED exactly once (one logger line
# each) even though the fixture sees each several times across both tcpdump
# dialects. nft adds may legitimately re-occur (map self-heal re-assert), so
# what matters is the final map state, not the raw count.
check "each stable client logged as provisioned exactly once"       sh -c '[ "$(grep -c "provisioned 10.10.10.10 " "$TESTS_TMP/log/syslog.log")" -eq 1 ] && [ "$(grep -c "provisioned 10.10.10.11 " "$TESTS_TMP/log/syslog.log")" -eq 1 ] && [ "$(grep -c "provisioned 10.10.10.12 " "$TESTS_TMP/log/syslog.log")" -eq 1 ]'
check "nft map: exactly the 4 expected elements, no duplicates"     sh -c '[ "$(sort -u "$TESTS_TMP/log/map.log" | wc -l)" -eq 4 ]'
check "nft map contains the third (live-dialect) client binding"    grep -q "10.10.10.12 : 02:00:00:00:00:0c" "$TESTS_TMP/log/map.log"
check "nft map contains the client binding"                         grep -q "10.10.10.10 : 02:00:00:00:00:0a" "$TESTS_TMP/log/map.log"
check "nft map contains the second client binding"                  grep -q "10.10.10.11 : 02:00:00:00:00:0b" "$TESTS_TMP/log/map.log"
check "the only map delete is the MAC-change old element"           sh -c '[ "$(grep -c "^delete element" "$TESTS_TMP/log/nft.log")" -eq 1 ] && grep -q "delete element bridge ip4pt ip2mac { 10.10.10.13 }" "$TESTS_TMP/log/nft.log"'
check_not "no suspension happened while parsing (OFFLINE_SECS unset)" grep -qi "^suspended " "$TESTS_TMP/log/syslog.log"

# --- MAC change: an IP that moves to a different device -------------------
# (Regression: POSIX sh has no `local`; remove_host_rules' old `mac="$2"`
# clobbered update_host's new-MAC variable, so the binding could never
# flip -- it flapped deprovision/provision with the OLD mac on every ARP.)
check "MAC change: state file holds the NEW device's mac"           have_binding 10.10.10.13 02:00:00:00:00:0e
check "MAC change: nft map holds the NEW mac"                       grep -q "10.10.10.13 : 02:00:00:00:00:0e" "$TESTS_TMP/log/map.log"
check_not "MAC change: OLD mac is gone from the nft map"            grep -q "10.10.10.13 : 02:00:00:00:00:0d" "$TESTS_TMP/log/map.log"
check "MAC change: old owner provisioned exactly once (first learn)" sh -c '[ "$(grep -c "provisioned 10.10.10.13 via 02:00:00:00:00:0d" "$TESTS_TMP/log/syslog.log")" -eq 1 ]'
check "MAC change: new owner provisioned exactly once (the flip)"   sh -c '[ "$(grep -c "provisioned 10.10.10.13 via 02:00:00:00:00:0e" "$TESTS_TMP/log/syslog.log")" -eq 1 ]'

# --- lifecycle logging (FR-11 spot check) ---------------------------------
check "startup banner logged"                                       grep -q "discovery starting on eth2" "$TESTS_TMP/log/syslog.log"
check "restore line logged (0 hosts)"                               grep -q "restored 0 persisted host(s)" "$TESTS_TMP/log/syslog.log"

# --- DHCP hostname capture (FR-14) ----------------------------------------
# The DHCP fixture feeds names/<mac>; the binding side must be completely
# untouched by it -- which the host-file count above ("exactly 4 state
# files") already pins. Here: the name side only.
N="$TESTS_TMP/etc/ip4pt/state/names"

check "dhcp: name file learned for the first client"                 sh -c '[ "$(cat "$1")" = "livingroom" ]' x "$N/02:00:00:00:00:0a"
check "dhcp: name file learned for the second client"               sh -c '[ "$(cat "$1")" = "android-tv" ]' x "$N/02:00:00:00:00:0b"
# DHCP-only client (02:...:0f): a name, but never a binding.
check "dhcp: DHCP-only client got its name"                         sh -c '[ "$(cat "$1")" = "nas-box" ]' x "$N/02:00:00:00:00:0f"
check_not "dhcp: DHCP-only client never became a host binding"       test -f "$TESTS_TMP/etc/ip4pt/state/hosts/10.10.10.15"
# No option 12 in its request -> no name file, no matter what.
check_not "dhcp: request without option 12 learns no name"           test -f "$N/02:00:00:00:00:0c"
# Invalid charset (spaces) -> rejected before ever touching state.
check_not "dhcp: invalid name (spaces) is rejected"                 test -f "$N/02:00:00:00:00:11"
# Server Reply echoing a name: no "Request from" -> no client -> nothing
# learned, and certainly nothing attributed to the PREVIOUS requester.
# Exactly the 3 expected name files, nothing more.
check "dhcp: server ACK never teaches a name"                       sh -c '[ "$(ls -A "$1" | wc -l)" -eq 3 ]' x "$N"
# write-if-changed: the re-request at the end of the fixture re-sends
# "livingroom", which must not produce a second log line.
check "dhcp: name re-request logs the name exactly once"            sh -c '[ "$(grep -c "learned name livingroom" "$TESTS_TMP/log/syslog.log")" -eq 1 ]'

summary
