#!/bin/sh
# tests/lib/cleanup.sh -- teardown for the E2E lab: kill daemon process
# groups (so piped tcpdump never lingers), then remove every namespace, which
# also removes the veth pairs anchored inside them.

for ns in ip4pt_fb ip4pt_dut ip4pt_r2 ip4pt_cl; do
	ip netns pids "$ns" 2>/dev/null | xargs -r kill 2>/dev/null
done
sleep 1
for ns in ip4pt_fb ip4pt_dut ip4pt_r2 ip4pt_cl; do
	ip netns del "$ns" 2>/dev/null
done

# best-effort: drop the bridge-family table the test created in the dut ns
ip netns exec ip4pt_dut nft delete table bridge ip4pt 2>/dev/null || true
