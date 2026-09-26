#!/bin/sh
# tests/test-status.sh -- root-free test of the luci-app-ip4pt status
# helper. Everything external is stubbed (same harness as the parser
# test): ip4pt-lib.sh is sourced via IP4PT_LIB, the conf via IP4PT_CONF,
# and ebtables is replaced by a fake that answers "-t nat -L PREROUTING"
# with a canned rule listing, so arpreply_present() -- the kernel-truth
# check the helper borrows from the lib -- sees real-shaped lines.
#
# The assertions pin the JSON the LuCI view consumes: host fields, the
# online/suspended classification, and both countdown values against the
# harness conf's OFFLINE_SECS=45 / STALE_SECS=120 thresholds. Ages are
# backdated, so exact seconds can drift by 1-2 across a boundary; numeric
# assertions use small regex ranges instead of equality.
#
# Usage: sh tests/test-status.sh

set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

# Same sanitization as the parser test: nothing may leak in from the
# caller's login environment (a real /etc/ip4pt/ip4pt.conf exports
# these too). The harness re-exports canonical values right after.
unset UPLINK DOWNLINK DISCOVER_IF STATE_DIR STALE_SECS GC_INTERVAL OFFLINE_SECS ROUTER2_MAC

. "$ROOT/tests/lib/env.sh"

echo "== status helper test =="

HELPER="$ROOT/package/luci-app-ip4pt/root/usr/libexec/ip4pt-status"
REMOVER="$ROOT/package/luci-app-ip4pt/root/usr/libexec/ip4pt-remove"
H="$TESTS_TMP/etc/ip4pt/state/hosts"
OUT="$TESTS_TMP/status.json"

# The harness' stock ebtables fake only logs invocations; arpreply_present
# greps the LISTING, so give it a fake that prints rules for two of the
# three fixture hosts (the third is the suspended one).
cat >"$TESTS_TMP/bin/ebtables" <<'FAKE_EBT'
#!/bin/sh
printf '%s\n' "$*" >>"$TESTS_TMP/log/ebtables.log"
case "$*" in
"-t nat -L PREROUTING")
	cat <<'RULES'
Bridge table: nat

Bridge chain: PREROUTING, entries: 2, policy: ACCEPT
-p 0x0806 --arp-op Request --arp-ip-dst 10.10.10.10 -j arpreply --arpreply-mac 02:00:00:00:00:0a --arpreply-target DROP
-p 0x0806 --arp-op Request --arp-ip-dst 10.10.10.11 -j arpreply --arpreply-mac 02:00:00:00:00:0b --arpreply-target DROP
RULES
	exit 0
	;;
esac
exit 0
FAKE_EBT

# Deterministic service_running: the helper pgrep-finds the discovery
# daemon; fake it as running (exit 0). The daemon-down variant is covered
# by the missing-pgrep sub-case at the end.
cat >"$TESTS_TMP/bin/pgrep" <<'FAKE_PGREP'
#!/bin/sh
exit 0
FAKE_PGREP

chmod +x "$TESTS_TMP/bin/ebtables" "$TESTS_TMP/bin/pgrep"

# --- fixture: three hosts, backdated to distinct ages ---------------------
# Harness conf: OFFLINE_SECS=45, STALE_SECS=120. Ages chosen to exercise
# every classification: 0s (online, fresh), 30s (online, suspends soon),
# 200s (suspended: age > OFFLINE_SECS and no rule in the fake listing).
mkdir -p "$H"
echo "02:00:00:00:00:0a" >"$H/10.10.10.10"
echo "02:00:00:00:00:0b" >"$H/10.10.10.11"
echo "02:00:00:00:00:0c" >"$H/10.10.10.12"
touch -d "-30 seconds"  "$H/10.10.10.11"
touch -d "-200 seconds" "$H/10.10.10.12"

# Hostnames (the DHCP capture's names/<mac> state): two of the three
# hosts have one, the third must render as null in the JSON.
HN="$TESTS_TMP/etc/ip4pt/state/names"
mkdir -p "$HN"
echo "livingroom" >"$HN/02:00:00:00:00:0a"
echo "android-tv"  >"$HN/02:00:00:00:00:0b"

"$HELPER" >"$OUT" 2>"$TESTS_TMP/status.err"

# --- JSON shape -------------------------------------------------------------
check "output is a JSON object with the hosts array"             grep -q '"hosts":\[' "$OUT"
check "top-level field: service_running true (fake pgrep)"      grep -q '"service_running":true' "$OUT"
check "top-level field: offline_secs from conf (45)"             grep -q '"offline_secs":45' "$OUT"
check "top-level field: stale_secs from conf (120)"              grep -q '"stale_secs":120' "$OUT"
check "exactly 3 host entries"                                  sh -c '[ "$(grep -o "\"ip\":" "$1" | wc -l)" -eq 3 ]' x "$OUT"

# --- per-host fields ---------------------------------------------------------
# Name is the FIRST field of each host object: asserted before the rest.
check "named host: DHCP hostname joined by MAC (fresh host)"    grep -Eq '"name":"livingroom","ip":"10.10.10.10"' "$OUT"
check "named host: DHCP hostname joined by MAC (aging host)"    grep -Eq '"name":"android-tv","ip":"10.10.10.11"' "$OUT"
check "unnamed host: name renders as null"                      grep -Eq '"name":null,"ip":"10.10.10.12"' "$OUT"

# Fresh host: age 0-1, online via its rule in the listing.
check "fresh host: online"                                      grep -Eq '"ip":"10.10.10.10","mac":"02:00:00:00:00:0a","age":[01],"online":true' "$OUT"
# Aging host: backdated 30s -> age 30-32, suspend_in 45-age (13-15),
# remove_in 120-age (88-90).
check "aging host: age reads the backdated mtime (30s)"          grep -Eq '"ip":"10.10.10.11","mac":"02:00:00:00:00:0b","age":3[0-2],' "$OUT"
check "aging host: still online (rule present)"                  grep -Eq '"ip":"10.10.10.11"[^}]*"online":true' "$OUT"
check "aging host: suspend_in counts down (45-30)"               grep -Eq '"ip":"10.10.10.11"[^}]*"suspend_in":1[345]' "$OUT"
check "aging host: remove_in counts down (120-30)"                grep -Eq '"ip":"10.10.10.11"[^}]*"remove_in":8[89]|90' "$OUT"

# --- suspension classification (kernel truth via arpreply_present) ----------
# The 200s host has no rule in the listing: suspended, and both
# countdowns are clamped at 0 (age > both thresholds).
check "silent host without rule: suspended (online false)"      grep -Eq '"ip":"10.10.10.12"[^}]*"online":false' "$OUT"
check "silent host: suspend_in clamped to 0"                    grep -Eq '"ip":"10.10.10.12"[^}]*"suspend_in":0' "$OUT"
check "silent host: remove_in clamped to 0 (age>STALE too)"     grep -Eq '"ip":"10.10.10.12"[^}]*"remove_in":0' "$OUT"

# --- empty state dir ---------------------------------------------------------
check "empty state dir yields empty hosts array"                sh -c 'o=$1; d=$2; rm -f "$d"/*; "$3" >"$o" 2>/dev/null; grep -q "\"hosts\":\[\]}" "$o"' x "$TESTS_TMP/status2.json" "$H" "$HELPER"

# --- disabled suspend tier -> null counter -----------------------------------
# Sub-conf with OFFLINE_SECS=0: suspend_in must be null while remove_in
# still counts (fresh file -> age 0-2 -> 118-120).
CONF2="$TESTS_TMP/etc/ip4pt/ip4pt-off.conf"
sed 's/^OFFLINE_SECS=.*/OFFLINE_SECS=0/' "$IP4PT_CONF" >"$CONF2"
echo "02:00:00:00:00:0a" >"$H/10.10.10.10"
check "disabled suspend tier: suspend_in null, remove_in counted" sh -c 'c=$1; h=$2; IP4PT_CONF="$c" "$3" 2>/dev/null | grep -Eq "\"ip\":\"10.10.10.10\"[^}]*\"suspend_in\":null,\"remove_in\":1(1[89]|20)"' x "$CONF2" "$H" "$HELPER"

# --- daemon-down flag --------------------------------------------------------
# No pgrep in PATH: the helper must not crash and must report
# not-running while still emitting valid JSON. Keep the system dirs in
# PATH -- the helper itself needs date/basename/cat from them.
rm -f "$TESTS_TMP/bin/pgrep"
check "missing pgrep: service_running false, JSON still valid"  sh -c 'o=$1; p=$2; PATH="$p:/usr/bin:/bin" "$3" >"$o" 2>/dev/null; grep -q "\"service_running\":false" "$o" && grep -q "\"hosts\":\[" "$o"' x "$TESTS_TMP/status3.json" "$TESTS_TMP/bin" "$HELPER"
# --- ip4pt-remove (the LuCI Remove button's backend) -------------------------
# Restores the fake pgrep so the status output is deterministic again.
cat >"$TESTS_TMP/bin/pgrep" <<'FAKE_PGREP'
#!/bin/sh
exit 0
FAKE_PGREP
chmod +x "$TESTS_TMP/bin/pgrep"

# Rebuild the fixture: two online hosts with rules in the listing, one
# silent/suspended host without.
echo "02:00:00:00:00:0a" >"$H/10.10.10.10"
echo "02:00:00:00:00:0b" >"$H/10.10.10.11"
echo "02:00:00:00:00:0c" >"$H/10.10.10.12"

# Usage / validation: anything that is not a strict dotted quad must be
# rejected BEFORE it is ever used as a path (exit 2).
check "remove: rejects a missing argument"                sh -c '"$1" >/dev/null 2>&1; [ $? -eq 2 ]' x "$REMOVER"
check "remove: rejects a path-traversal arg"             sh -c '"$1" ../../etc >/dev/null 2>&1; [ $? -eq 2 ]' x "$REMOVER"
check "remove: rejects an oversized octet (10.10.10.256)" sh -c '"$1" 10.10.10.256 >/dev/null 2>&1; [ $? -eq 2 ]' x "$REMOVER"
check "remove: rejects a short address (10.10.10)"        sh -c '"$1" 10.10.10 >/dev/null 2>&1; [ $? -eq 2 ]' x "$REMOVER"
check "remove: rejects an empty octet (10.10..10)"        sh -c '"$1" 10.10..10 >/dev/null 2>&1; [ $? -eq 2 ]' x "$REMOVER"

# Not-found: a well-formed IP with no state file exits 1, state intact.
check "remove: unknown IP exits 1, state untouched"       sh -c '"$1" 10.10.10.99 >/dev/null 2>&1; [ $? -eq 1 ] && [ -f "$2/10.10.10.10" ]' x "$REMOVER" "$H"

# Success: the full deprovision path runs (nft map delete + ebtables
# delete + state file removal) for the SUSPENDED host, whose rule is
# absent from the listing (matching the fake's contents) so only the
# delete calls must appear in the logs.
check "remove: suspended host exits 0"                    sh -c '"$1" "$2" >/dev/null 2>&1' x "$REMOVER" 10.10.10.12
check_not "remove: state file is gone"                    test -f "$H/10.10.10.12"
check "remove: nft map element deleted"                  grep -q "delete element bridge ip4pt ip2mac { 10.10.10.12 }" "$TESTS_TMP/log/nft.log"
check "remove: ebtables rule deleted"                    grep -q -- "-D PREROUTING.*10.10.10.12" "$TESTS_TMP/log/ebtables.log"
check "remove: deprovision logged"                       grep -q "deprovisioned 10.10.10.12" "$TESTS_TMP/log/syslog.log"

# Success on an ONLINE host: same path, plus the rule delete call for
# the host whose rule IS in the listing.
check "remove: online host exits 0"                      sh -c '"$1" "$2" >/dev/null 2>&1' x "$REMOVER" 10.10.10.10
check "remove: online host's rule delete recorded"       grep -q -- "-D PREROUTING.*10.10.10.10" "$TESTS_TMP/log/ebtables.log"

# --- ip4pt-remove --suspended (bulk mode) -----------------------------------
# Reset the state and rule-layer logs so the bulk assertions see only
# what the sweep itself did.
: >"$TESTS_TMP/log/nft.log"
: >"$TESTS_TMP/log/ebtables.log"
: >"$TESTS_TMP/log/syslog.log"
echo "02:00:00:00:00:0a" >"$H/10.10.10.10"   # online  (rule in listing)
echo "02:00:00:00:00:0b" >"$H/10.10.10.11"   # online  (rule in listing)
echo "02:00:00:00:00:0c" >"$H/10.10.10.12"   # suspended (no rule)
echo "02:00:00:00:00:0d" >"$H/10.10.10.13"   # suspended (no rule)

out=$("$REMOVER" --suspended 2>/dev/null); rc=$?
check "bulk: exits 0 and reports the count"                sh -c '[ "$1" = 0 ] && [ "$2" = "removed 2 suspended binding(s)" ]' x "$rc" "$out"
check "bulk: both suspended state files are gone"         sh -c '[ ! -f "$1/10.10.10.12" ] && [ ! -f "$1/10.10.10.13" ]' x "$H"
check "bulk: online hosts survive the sweep"              sh -c '[ -f "$1/10.10.10.10" ] && [ -f "$1/10.10.10.11" ]' x "$H"
check "bulk: both suspended IPs nft-deleted"              sh -c 'grep -q "delete element bridge ip4pt ip2mac { 10.10.10.12 }" "$1" && grep -q "delete element bridge ip4pt ip2mac { 10.10.10.13 }" "$1"' x "$TESTS_TMP/log/nft.log"
check "bulk: both suspended IPs ebtables-deleted"         sh -c 'grep -q -- "-D PREROUTING.*10.10.10.12" "$1" && grep -q -- "-D PREROUTING.*10.10.10.13" "$1"' x "$TESTS_TMP/log/ebtables.log"
check_not "bulk: online IPs never deprovisioned"          grep -q "deprovisioned 10.10.10.1[01]" "$TESTS_TMP/log/syslog.log"

# Usage guard: --suspended tolerates no extra arguments.
check "bulk: rejects extra arguments"                     sh -c '"$1" --suspended --extra >/dev/null 2>&1; [ $? -eq 2 ]' x "$REMOVER"

# Empty sweep: with only online hosts left, exits 0 and reports zero.
rm -f "$H/10.10.10.12" "$H/10.10.10.13"
out=$("$REMOVER" --suspended 2>/dev/null); rc=$?
check "bulk: nothing suspended reports removed 0"          sh -c '[ "$1" = 0 ] && [ "$2" = "removed 0 suspended binding(s)" ]' x "$rc" "$out"

summary