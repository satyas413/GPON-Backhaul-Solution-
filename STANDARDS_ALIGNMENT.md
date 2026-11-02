# Standards alignment: OpenConfig, BBF TR-383 / TR-385, ITU-T G.709, RFC 8345

The PoC ontology (`backend/config/topology.yaml`) is aligned with the data models an operator's controllers
use. Every entity carries a `std` block with its standard identities and YANG paths, and the backend exports
the topology as standard JSON instance documents (RFC 7951 encoding) that pass a schema check against the
published YANG modules.

| Standard | What it covers in this topology | Where |
|---|---|---|
| **BBF TR-385** (ITU-T PON YANG) | OLT PON ports, ODN trees, ONTs, Type-B protection, T-CONT / GEM QoS, PON defects | `bbf-xpon`, `bbf-xponvani`, `bbf-xponani`, `bbf-xpongemtcont`, `bbf-xpon-defects` |
| **BBF TR-383** (common access-node YANG) | OLT hardware tree, interface-to-hardware binding, interface stacking, L2 forwarding | `bbf-hardware(-types)`, `bbf-link-table`, `bbf-if-type`, `bbf-l2-forwarding` |
| **OpenConfig** | Routers, aggregation switches, CES gateway, BSC, PDH mux: components, interfaces, OTN logical channels, pseudowires, alarm types | `openconfig-platform`, `-interfaces`, `-terminal-device`, `-network-instance`, `-alarm-types` |
| **ITU-T G.709** (OTN) | Server layer of the inter-site 100GE core links: client → OPU4 (GMP) → ODU4 → OTU4 (FEC) → OCh, TTI, G.798 defects | `otn:` on core links, OpenConfig terminal-device, RFC 8345 `otn` layer |
| **IETF RFC 8345** | The whole graph as a multi-layer network topology: physical → otn → ip-eth, physical → xpon, xpon + ip-eth → tdm | `ietf-network`, `ietf-network-topology` |
| IETF / IANA / ITU-T X.733 | Interface types (`ianaift:gpon`, `ds1`, `ds3`, `sonet`, `ethernetCsmacd`, `ieee8023adLag`), hardware classes, alarm event types and severities | `iana-if-type`, `iana-hardware`, `ietf-alarms` (RFC 8632) |

Models used: BroadbandForum/yang `standard/` (commit 188a658, 2026-10-29), openconfig/public `release/models`
(commit 160da73, 2026-10-28), YangModels/yang IETF RFC + IANA modules (commit 7cb93ea, 2026-10-21).

## How it is built

* [`backend/config/standards.yaml`](../backend/config/standards.yaml): the mapping. One entry per ontology class
  (OpenConfig path and identity, BBF module and path, IETF/IANA type, G.709 note, RFC 8345 layer), G.709 rate
  tables, and the alarm mapping (X.733 event type, RFC 8632 / OpenConfig severity, BBF / OpenConfig / ITU-T alarm identity).
* [`backend/app/standards.py`](../backend/app/standards.py): derives the TR-385 interface stack and the G.709 stack,
  annotates every entity (`entity.std`), checks the standards rules and builds the export documents.
* `topology.yaml`: unchanged ids and classes (scenarios, playbooks and the autonomy policy still key on them). The
  only additions are the `otn:` server layer on the three inter-site core links and a pointer in the ontology header.

## Class mapping

| PoC class | OpenConfig | BBF TR-383 / TR-385 | IETF / IANA | G.709 / RFC 8345 |
|---|---|---|---|---|
| CoreRouter | `/components/component` CHASSIS; `/interfaces`; `/terminal-device/logical-channels` | – | `ianahw:chassis` | node in physical, otn, ip-eth |
| AggregationSwitch | as CoreRouter | `bbf-l2-forwarding` forwarders (OLT uplink VLANs) | `ianahw:chassis` | node in physical, otn, ip-eth |
| CESGateway | `/network-instances/network-instance[CES-…]` type `L2P2P`; interfaces `sonet`, `ds3` | – | `ianahw:chassis` | node in physical, ip-eth, tdm |
| BSC | CHASSIS; interface `sonet` | – | `ianahw:chassis` | node in physical, tdm |
| G702Mux | CHASSIS; interfaces `ds3` (E3 trunk), `ds1` (E1) | – | E1/E3 via `ds1`/`ds3` (RFC 4805 / RFC 3896) | node in physical, tdm |
| OLT | CHASSIS (no PON in OpenConfig) | `/hw:hardware/component` chassis → `bbf-hwt:board` → `cage` → `transceiver` → `bbf-hwt-xpon:transceiver-link-gpon` | `ianahw:chassis` | node in physical, ip-eth, xpon |
| PONPort | PORT + TRANSCEIVER | `channel-pair` (type `gpon`) + `channel-termination` (type `gpon`, location `inside-olt`, Type-B role), bound to the transceiver-link by `bbf-hardware:hardware-component/port-layer-if` | `ianaift:gpon` | termination point in xpon |
| Splitter (passive) | – | scope of one `channel-group` + `channel-partition`; sets `closest-onu-distance` and `maximum-differential-xpon-distance` from fibre lengths | – | node in physical |
| FiberSegment (passive) | – | – | – | link in physical; supports the xpon links |
| ONT | – | `v-ani` (onu-id, expected-serial-number, channel-partition, preferred/protection channel-pair), `ani`, `olt-v-enet` ↔ `onu-v-enet`, `bbf-link-table` entries, one T-CONT + GEM port per service | `bbf-hwt:xpon-nt` | node in physical, xpon, tdm |
| BTS | – (3GPP-managed via BSC) | – | – | node in physical, tdm |
| CoreLink | interface `ethernetCsmacd`; OTN logical channels | – | – | link in ip-eth over **G.709** ODU4/OTU4 |
| EthernetUplink | interface `ieee8023adLag` | OLT network port, VLAN sub-interfaces (`bbf-sub-interfaces`) | – | link in ip-eth |
| STM1Link | interface `sonet` | – | – | link in tdm (native G.707 on intra-office fibre) |
| E3Trunk / E1Circuit | interfaces `ds3` / `ds1` | ONT E1 UNI: `ianaift:ds1` interface (OMCI PPTP CES UNI, G.988) | – | link in tdm |
| Pseudowire | `connection-points/connection-point[PW-…]`, LOCAL (STM-1) + REMOTE (ONT IWF, `virtual-circuit-identifier`) | carried by the ONT's GEM port | `ianaift:ifPwType`, RFC 5086 CESoPSN | link in tdm supported by xpon + ip-eth links |
| Mobile / Ethernet / Enterprise service | – | – | `ietf-l2vpn-ntw` (RFC 9291) vpn-service | – |

### TR-385 instance naming

| Object | Name | Notes |
|---|---|---|
| channel-group / channel-partition | `CG-<splitter>` / `CPart-<splitter>` | one per ODN tree; a Type-B standby port joins the working port's tree |
| channel-pair / channel-termination | `CP-<pon port>` / `CT-<pon port>` | `meant-for-type-b-primary-role` false only on the standby port (PON-A1P) |
| hardware | `<olt>-board-0/1`, `<olt>-cage-0/1/1`, `<olt>-xcvr-0/1/1`, `<olt>-tl-0/1/1` | frame/slot/port parsed from the port name |
| v-ani / ani | `vANI-<ont>` / `ANI-<ont>` | onu-id 1.. per channel partition (G-PON range 0..253) |
| v-enets | `oltVENET-<ont>` / `onuVENET-<ont>` | linked in `bbf-link-table` (combined-NE mode) |
| T-CONT / GEM | `TCONT-<ont>-<service>` / `GEM-<ont>-<service>` | alloc-id and gemport-id 1024 + 16·onu-id + n (G-PON alloc-id 256..4095); profiles `TDP-CES-E1` (fixed 2.304 Mbit/s for an E1), `TDP-MBH-4G`, `TDP-ENT-L2VPN` |

### G.709 server layer

The three inter-site core links (`CL-CR1-CR2`, `CL-AGG1-CR1`, `CL-AGG2-CR2`) carry 100GBASE-R over OTN:

```
100GBASE-R (103.125 Gb/s) -> OPU4 (GMP, 104.356 Gb/s payload) -> ODU4 (104.794 Gb/s) -> OTU4 (111.810 Gb/s, RS(255,239) FEC) -> OCh
```

The TTI SAPI/DAPI name the two ends. In OpenConfig this becomes three linked logical channels per end
(client `PROT_100GE` → `PROT_ODU4` → `PROT_OTU4` → optical channel) with `tti-msg-transmit` / `tti-msg-expected`.
A `LINK_DOWN` on one of these links corresponds to the G.798 defects dLOS-P / dLOF / dLOM at the near end,
ODU4-AIS downstream and BDI upstream. The intra-office links (CR-1 to CES gateway, CES gateway to BSC) stay
native Ethernet / G.707 STM-1, as they would in a real central office.

### Alarm identities

| PoC alarm | BBF TR-385 defect | OpenConfig alarm type | ITU-T reference |
|---|---|---|---|
| PON_LOS | `bbf-xpon-def:los` | `LOS` | G.984.3 cl. 11.1.1 LOS |
| ONT_LOSi | `bbf-xpon-def:lobi` | `LOS` | G.984.3 LOSi (LOBi in TR-385) |
| ONT_SDi | `bbf-xpon-def:sdi` | – | G.984.3 SDi |
| ONT_DYING_GASP | `bbf-xpon-def:dgi` | – | G.984.3 DGi |
| E1_LOS / E1_AIS | – | `LOS` / `AIS` | G.775 |
| LINK_DOWN | – | `LOS` | on OTN links: G.798 dLOS-P / dLOF / dLOM, ODU-AIS, BDI |
| EQUIPMENT_FAIL, PON_PORT_FAIL | – | `EQPT` | – |

Every alarm category also maps to an X.733 event type (`communicationsAlarm`, `qualityOfServiceAlarm`,
`equipmentAlarm`), and every severity to RFC 8632 and OpenConfig severities. `GET /api/standards` returns the full table.

## API

| Endpoint | Returns |
|---|---|
| `GET /api/standards` | class mapping, alarm identities, topology rule findings, list of documents |
| `GET /api/standards/bbf-xpon/{OLT-A\|OLT-B}` | TR-385 + TR-383 configuration of the OLT (RFC 7951 JSON) |
| `GET /api/standards/openconfig/{device}` | OpenConfig components, interfaces, OTN logical channels, CES pseudowires |
| `GET /api/standards/ietf-network` | RFC 8345 topology with 5 layers (physical 42 nodes / 37 links, otn 4 / 3, ip-eth 7 / 6, xpon 18 / 16, tdm 17 / 16) |
| `GET /api/topology` | as before, plus `std` on every entity (shown in the dashboard's entity panel) |

Sample exports are in [`docs/standards-samples/`](standards-samples/).

## Validation

```
cd backend
python scripts/validate_standards.py                       # topology rules + writes docs/standards-samples
pip install pyang                                          # optional, for the schema check
python scripts/validate_standards.py --yang-root DIR       # DIR/bbf-yang, DIR/openconfig, DIR/yang (git clones)
```

**Topology rules** (always run): ONU serial numbers match `bbf-xpon-types:onu-serial-number` and are unique,
onu-id within the G-PON range, alloc-ids within 256..4095, ONT reach and ODN differential distance within 20 km
(G.984), Type-B working and standby ports on different line cards, OTN client rate fits the OPU payload,
OPU/ODU/OTU orders match, TTI names the link ends, every alarm category has an X.733 type.
Result: 0 errors, 0 warnings.

**YANG schema check** (pyang compiles the published modules including all augments): every node must exist,
config documents must not contain read-only nodes, list keys and mandatory leaves must be present, values must
match their types (ranges, patterns, enums, identityref bases, RFC 7951 number vs string encoding), `when`
conditions on interface types must hold, and absolute leafrefs (interface names, hardware names) must resolve.

```
[PASS] bbf-xpon_OLT-A.json              453 leaf values checked against bbf-xpon YANG
[PASS] bbf-xpon_OLT-B.json              442 leaf values checked against bbf-xpon YANG
[PASS] openconfig_CR-1.json             119 leaf values checked against openconfig YANG
[PASS] openconfig_CR-2.json             110 leaf values checked against openconfig YANG
[PASS] openconfig_AGG-1.json            65 leaf values checked against openconfig YANG
[PASS] openconfig_AGG-2.json            65 leaf values checked against openconfig YANG
[PASS] openconfig_CESGW-1.json          111 leaf values checked against openconfig YANG
[PASS] ietf-network_topology.json       896 leaf values checked against ietf-network YANG
   bbf-xpon: 92 'when' conditions evaluated
   bbf-xpon: uses optional YANG features bbf-hardware:interface-hardware-management, interface-hardware-reference,
             bbf-xponani:configurable-ani-onu-id, bbf-xpongemtcont:configurable-alloc-id, configurable-gemport-id,
             bbf-xponvani:configurable-v-ani-onu-id
```

The checker was itself tested by breaking a document on purpose: a wrong identity base, a missing mandatory
leaf, a channel-termination container on a channel-pair interface (`when` false), an unknown node, a bad ONU
serial, a dangling channel-pair reference, an out-of-range alloc-id and a uint64 written as a JSON number were
each reported. The first run also caught a real mistake: `system-id` on the channel group is an NG-PON2-only
5-hex-digit field, so it was removed for G-PON.

## Limits and gaps

* This is alignment with schema-valid configuration for the modelled subset, not a vendor conformance test.
  An OLT or controller may require further leaves (profiles, VLAN sub-interfaces, ONU vendor specifics).
* The checker does not evaluate YANG `must` expressions or the more complex OpenConfig `when` expressions
  (90 skipped). The values used respect the TR-385 traffic-descriptor `must` rules by construction.
* OpenConfig has no PON, PDH (E1/E3) or STM-1 tributary model (`PROT_STM16` is the lowest SDH rate): those
  parts use BBF or iana-if-type and are marked as gaps in `standards.yaml`.
* TR-385 has no splitter / ODN object and no CES UNI. The ODN shows up as the channel-group / partition scope and
  distance leaves; the E1 UNI is an `ianaift:ds1` interface (G.988 OMCI PPTP CES UNI in a real ONU).
* RFC 8345 identifiers are `urn:poc:<id>` because ietf-inet-types (RFC 9911) requires a URI scheme.
* The simulator still raises `LINK_DOWN` for a core link, not separate OTN defects; the G.709 defect set is
  attached to the link as metadata. Emitting OTUk/ODUk defects as their own alarms is a possible next step.
