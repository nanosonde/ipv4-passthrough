#!/bin/sh
# tests/lib/env.sh -- shared test harness: assert helpers + a fake ip4pt.conf
# + config/lib overrides so the scripts run against $TESTS_TMP instead of
# touching /etc/ip4pt or the real firewall. Sourced by both test scripts.

# $0 inside a sourced file still belongs to the caller, so anchor everything
# at the caller's path: <repo>/tests/test-*.sh -> TESTS_DIR=<repo>/tests.
TESTS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)           # <repo>/tests
IP4PT_REPO=$(CDPATH= cd -- "$TESTS_DIR/.." && pwd -P)               # <repo>
export TESTS_TMP="$TESTS_DIR/tmp"
rm -rf "$TESTS_TMP"
mkdir -p "$TESTS_TMP/etc/ip4pt/state/hosts" \
         "$TESTS_TMP/etc/ip4pt" \
         "$TESTS_TMP/bin" \
         "$TESTS_TMP/log"

# Fake binaries that log their invocations instead of acting. nft also
# appends map elements to a small "table" file so add/delete assertions work.
# IP4PT_FAKE_NET=0 (set before sourcing) skips the nft/ebtables fakes --
# the E2E test needs the real tools and only keeps the logger shim.
if [ "${IP4PT_FAKE_NET:-1}" = 1 ]; then
cat >"$TESTS_TMP/bin/nft" <<'FAKE_NFT'
#!/bin/sh
printf '%s\n' "$*" >>"$TESTS_TMP/log/nft.log"
case "$*" in
"add element "*)
	elem=$(printf '%s' "$*" | sed 's/.*{[[:space:]]*\([^}]*\)[[:space:]]*}.*/\1/')
	printf '%s\n' "$elem" >>"$TESTS_TMP/log/map.log"
	;;
"delete element "*)
	elem=$(printf '%s' "$*" | sed 's/.*{[[:space:]]*\([^}]*\)[[:space:]]*}.*/\1/' | awk '{print $1}')
	sed -i "/^$elem /d" "$TESTS_TMP/log/map.log" 2>/dev/null
	;;
esac
exit 0
FAKE_NFT

cat >"$TESTS_TMP/bin/ebtables" <<'FAKE_EBT'
#!/bin/sh
printf '%s\n' "$*" >>"$TESTS_TMP/log/ebtables.log"
exit 0
FAKE_EBT
fi

cat >"$TESTS_TMP/bin/logger" <<'FAKE_LOG'
#!/bin/sh
printf '%s\n' "$*" >>"$TESTS_TMP/log/syslog.log"
exit 0
FAKE_LOG

chmod +x "$TESTS_TMP/bin/"* 2>/dev/null
export PATH="$TESTS_TMP/bin:$PATH"

# A conf shaped like /etc/ip4pt/ip4pt.conf, rooted at $TESTS_TMP. IP4PT_CONF
# is honoured by ip4pt-lib.sh / ip4pt-gen-nft.sh so the tests never touch
# the real /etc/ip4pt or the live firewall.
cat >"$TESTS_TMP/etc/ip4pt/ip4pt.conf" <<EOF
UPLINK=eth0
DISCOVER_IF=eth2
ROUTER2_MAC=02:00:00:00:00:02
STATE_DIR=$TESTS_TMP/etc/ip4pt/state
# Long enough that GC can't drop a still-active client mid-test, but small
# enough that the GC scenario exercises a real expiry via backdated mtime.
STALE_SECS=120
# Two-tier lifecycle: comfortably above the wall-clock span of scenarios
# 1-4 (so nothing suspends mid-test by accident); scenario 5 backdates the
# mtime far past it to trigger the suspension deterministically.
OFFLINE_SECS=45
GC_INTERVAL=1
EOF

export IP4PT_CONF="$TESTS_TMP/etc/ip4pt/ip4pt.conf"
export IP4PT_LIB="$IP4PT_REPO/ip4pt-lib.sh"
# The discovery daemon's capture FIFO lives under /var/run in production;
# rootless tests must point it into the scratch dir instead.
export IP4PT_FIFO="$TESTS_TMP/ip4pt-discover.fifo"
: >"$TESTS_TMP/log/map.log"

# --- tiny assert helpers ---------------------------------------------------
fail_count=0
pass_count=0

ok()   { echo "ok   - $1"; pass_count=$((pass_count + 1)); }
fail() { echo "FAIL - $1"; fail_count=$((fail_count + 1)); }

# check <description> <command...>   (runs the command; ok if exit 0)
# check_not <description> <command...> (ok if exit != 0)
check()     { desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi; }
check_not() { desc="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$desc"; else ok "$desc"; fi; }

# poll <seconds> <command...> -- silently retries until success or timeout
poll() { secs="$1"; shift; i=0; while [ "$i" -lt "$secs" ]; do "$@" >/dev/null 2>&1 && return 0; sleep 1; i=$((i + 1)); done; return 1; }

have_binding() { [ "$(cat "$TESTS_TMP/etc/ip4pt/state/hosts/$1" 2>/dev/null)" = "$2" ]; }

summary() {
	echo "---------------------------------------------------"
	echo "$pass_count passed, $fail_count failed"
	[ "$fail_count" -eq 0 ]
}
