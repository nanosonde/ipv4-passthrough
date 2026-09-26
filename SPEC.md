# ipv4-passthrough — Specification

## 1. Background and Problem Statement

The network consists of two cascaded routers:

- **Router 1 (FritzBox)**: ISP-facing, provides the primary LAN and
  offers native passthrough for IPv6 to devices behind a second router.
- **Router 2**: a second, NAT-less router kept in place for reasons
  independent of this project. It supports passthrough for **IPv6**
  only — its WAN-side implementation for IPv6 preserves clients' real
  link-layer addresses end-to-end, so the FritzBox already sees them as
  ordinary local devices. **No equivalent passthrough mode exists for
  IPv4** on this hardware: IPv4 is plain-routed, which means normal
  Ethernet forwarding rewrites the source MAC at the WAN hop, and
  clients live on a distinct IPv4 subnet from the FritzBox's LAN.

As a result, on IPv4, the FritzBox's network overview shows Router 2 as
a single routed device, not the individual clients behind it.

**Goal**: eliminate this asymmetry by making Router 2 "go away" from
the FritzBox's point of view on IPv4 too — i.e., emulate the IPv4
passthrough mode that the hardware itself doesn't support. If Router 2
supported real IPv4 passthrough, this project would not be necessary.

## 2. Scope

In scope: an intermediate OpenWrt device, physically placed between the
FritzBox and Router 2, that makes Router 2's IPv4 clients visible to the
FritzBox as ordinary local devices (correct real MAC, correct real IP,
no NAT), by observation and Ethernet-layer manipulation only.

Out of scope:
- Any change to Router 2's own configuration or firmware.
- IPv6 (already solved natively; see §5, FR-6).
- DHCP-based discovery (see §7, non-goals).
- Handling of clients using rotating/randomized MAC addresses (excluded
  by policy — see §7).
- Forcing the first router's UI to a specific offline state on demand:
  FR-13 only stops answering ARP so the first router concludes offline by
  itself, at its own probe cadence; actively spoofing an "offline" state
  into the first router is not attempted.

## 3. Actors / Components

- **FritzBox**: DHCP/gateway for its own LAN; the device whose network
  overview is the target of this project.
- **Router 2**: NAT-less second router; its WAN port connects to the
  intermediate device; its LAN hosts the actual clients.
- **Intermediate device**: an OpenWrt box with three physical
  interfaces (`eth0` to the FritzBox, `eth1` to Router 2's WAN, `eth2`
  to a mirrored port on Router 2's LAN) — the subject of this
  specification.
- **Clients**: end-user devices on Router 2's LAN.

## 4. Assumptions and Constraints

- A1: Router 2's IPv4 WAN routing is NAT-less — client IP addresses are
  preserved unchanged end-to-end.
- A2: Router 2's IPv6 WAN behavior already preserves clients' real MAC
  addresses end-to-end (existing passthrough), independent of this
  project.
- A3: A free physical port on Router 2 can be configured to mirror
  (ingress + egress) its main LAN-facing port.
- A4: The client population on Router 2's LAN changes infrequently.
- A5: MAC address rotation/randomization is disabled on all clients on
  the home network (an operational policy this project depends on, not
  something it enforces).
- A6: The intermediate device runs OpenWrt (25.x or later) with its
  standard nftables (fw4) firewall stack; no Python interpreter is
  available on it.
- A7: The FritzBox's device-recognition mechanism is driven by observed
  ARP (IPv4) / NDP (IPv6) traffic, not exclusively by DHCP leases (an
  empirically observed behavior this design relies on).

## 5. Functional Requirements

| ID | Requirement |
|---|---|
| FR-1 | The system MUST preserve each client's original IPv4 address end-to-end; it MUST NOT perform NAT or any other address translation on the client's IPv4 traffic. |
| FR-2 | The system MUST rewrite the source MAC address of client-originated IPv4 frames, on the segment facing the FritzBox, to the client's real MAC address. |
| FR-3 | The system MUST rewrite the destination MAC address of FritzBox-originated IPv4 frames, on the segment facing Router 2, to Router 2's real MAC address. |
| FR-4 | The system MUST answer ARP requests from the FritzBox for a known client's IPv4 address with that client's real MAC address. |
| FR-5 | The system MUST NOT send gratuitous or otherwise unsolicited ARP announcements; it MUST reply only in direct response to an actual incoming ARP request. |
| FR-6 | The system MUST NOT alter IPv6 traffic in any way; native IPv6 passthrough behavior (per A2) MUST continue to function unmodified. |
| FR-7 | The system MUST discover clients' real IPv4-to-MAC bindings by passively observing traffic mirrored from Router 2's LAN; it MUST NOT rely on actively scanning or probing the client subnet as the primary discovery mechanism. |
| FR-8 | The system MUST persist discovered IPv4-to-MAC bindings such that they survive a reboot of the intermediate device. |
| FR-9 | On startup, the system MUST automatically re-apply all persisted bindings without requiring them to be relearned. |
| FR-10 | The system MUST remove a binding, and the rules derived from it, after a configurable period during which no corresponding traffic has been observed. |
| FR-11 | The system MUST log key lifecycle events (binding learned, binding removed, bindings restored at startup) to the system log. |
| FR-12 | All logic implementing this specification MUST be implemented without a dependency on Python or any other runtime not present in a stock OpenWrt install beyond explicitly documented package dependencies. |
| FR-13 | When a client has been silent on the mirrored port for a configurable period (shorter than the FR-10 removal period), the system MUST stop answering ARP requests for it, so that the first router marks it offline on its own; the binding itself MUST be retained so a returning client is answered again immediately. |
| FR-14 | The system SHOULD passively capture client hostnames from DHCP requests observed on the mirror port (no DHCP interaction of its own), retain them per client MAC, and expose them for display (status views); it MUST NOT use them for discovery or provisioning. |

## 6. Non-Functional Requirements

| ID | Category | Requirement |
|---|---|---|
| NFR-1 | Performance | Answering an ARP request for an already-known client MUST incur no observable added latency (i.e., must be handled by kernel-level packet processing, not a userspace round-trip per request). |
| NFR-2 | Reliability | Discovery MUST NOT depend on timing races (e.g., winning against a retry timeout); a passive, always-on observation mechanism is required (this requirement drove the shift away from earlier reactive-probing and active-sweep designs once mirroring became available). |
| NFR-3 | Durability | The persisted binding table MUST survive power loss or an unclean reboot without data loss beyond bindings not yet flushed at the moment of failure. |
| NFR-4 | Resource usage | Persistent storage writes MUST be infrequent enough not to meaningfully shorten the flash lifespan of a typical home-router device. |
| NFR-5 | Portability | The implementation MUST run on a stock OpenWrt 25.x nftables (fw4) install, plus explicitly documented additional packages (`tcpdump`, `ebtables`) — no out-of-tree kernel modules. |
| NFR-6 | Maintainability | Every site-specific value (interface names, Router 2's MAC address, timers) MUST be defined in exactly one place; no value may be hard-coded in more than one file such that the two could drift out of sync. |
| NFR-7 | Minimal footprint | The implementation MUST NOT create a proliferation of virtual network interfaces (e.g., one per client); the number of long-lived kernel objects created MUST NOT scale linearly with the number of clients beyond simple table/rule entries. |
| NFR-8 | Isolation | The mechanism MUST NOT enable NAT/masquerading anywhere on the cascaded traffic path, and the discovery interface MUST NOT be used as a forwarding path under any circumstance. |
| NFR-9 | Observability | Routine operation MUST be diagnosable from system logs alone, without requiring a packet capture. |
| NFR-10 | Simplicity | Given a choice between an equally-correct bridge-based and virtual-interface-based (macvlan) design, the bridge-based design MUST be preferred (explicit design preference). |

## 7. Non-Goals

- **DHCP-based discovery**: technically possible (DHCP is visible on
  the same mirrored port and would bind IP+MAC faster, at lease time),
  but not required — ARP-based discovery via a genuinely mirrored port
  already satisfies FR-7 and NFR-2. What IS taken from DHCP, since it
  comes for free on the same mirror, is each client's option-12
  hostname (FR-14) — retained per MAC purely for display. Parsing DHCP
  otherwise (leases, options beyond the hostname) stays out of scope.
- **Rotating/randomized client MAC addresses**: explicitly excluded by
  operational policy (A5) rather than handled by the system. A client
  that rotates its MAC will reappear as a new device on the FritzBox on
  every rotation; this is accepted, not solved.

## 8. Known Risks / Open Validation Items

See the README's "Things to validate" section for the concrete items. Two
of the original four are now settled and are guarded by tests rather than
left open: ebtables `arpreply` availability (declared as a package
dependency against `kmod-ebtables-ipv4`, probed by the E2E preflight) and
the nftables map-miss semantics (verified by the E2E data-path checks).
Still worth a look on the actual device: tcpdump output-format sensitivity
(pinned against recorded fixtures, but a different tcpdump build can still
vary) and flash-wear headroom. These are implementation-level risks
against the requirements above, not requirements themselves.
