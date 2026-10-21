# Knowledge Transfer: GPON · G.702 Backhaul AI Fault Management PoC

This guide is for a developer who is new to telecom, new to fault management, and new to this codebase. Read it top to
bottom once. By the end you should be able to run the system, explain what every part does, follow one fault through the
code from the network to the screen, and make common changes safely.

**Contents**

1. What this project is, in one page
2. Telecom basics you need (GPON, G.702/E1, mobile backhaul)
3. Fault-management basics (alarms, incidents, RCA, MTTD/MTTR, closed loop)
4. Set up and run it (step by step)
5. A guided tour of the dashboard
6. Repository map
7. The architecture in one picture
8. Follow one fault end to end through the code
9. Module-by-module deep dive
10. Configuration files explained
11. The API
12. Testing and verification
13. How to make common changes (recipes)
14. Debugging and troubleshooting
15. Known limits and the path to production
16. Glossary
17. Your first week: suggested exercises

---

## 1. What this project is, in one page

Telecom operators run large networks that constantly produce **alarms**: messages from equipment saying "something is wrong
here". One physical fault (say, a fibre cut by a digger) causes dozens of alarms from different devices, because everything
downstream of the cut also fails. A human operator in a Network Operations Centre (NOC) has to work out which alarms belong
together, what really broke, who is affected, and what to do. That is slow: in our baseline history the average time to
resolve is about two hours.

This project is a **proof of concept (PoC)** that automates that work for one kind of network: a **mobile backhaul** built
from **GPON** fibre access and **G.702** E1/E3 TDM circuits. It:

1. **Ingests** alarms and telemetry in the formats real equipment uses (SNMP traps, syslog, event streams, performance counters).
2. **Correlates** related alarms into a single **incident** using the network topology and timing.
3. **Finds the root cause** with a probabilistic (Bayesian) model, even when the broken thing cannot report (a fibre).
4. **Assesses impact**: which services, cell sites and how many subscribers are affected.
5. **Decides and acts** in a **closed loop** (detect → analyze → decide → act → verify), within configurable autonomy limits.
6. **Verifies** the fix against fresh telemetry and **escalates** to a human when the fix fails or is too risky.
7. **Survives its own failures**: alarm storms, duplicate/out-of-order messages, a crashed correlation engine, the AI being down, unreachable devices.
8. **Shows everything** on a web dashboard with KPIs such as MTTD and MTTR.

The network itself is **simulated**, so the demo runs on a laptop. The important design rule is that the simulator only talks to
the rest of the system through raw messages, exactly as real equipment would. Everything after ingestion is "real" logic that
does not know it is talking to a simulator.

**Tech stack:** Python 3.10+ (FastAPI, asyncio, NumPy, scikit-learn, PyYAML, SQLite) for the backend; React 18 + Vite +
Recharts for the dashboard. No Docker: a Python virtual environment and npm.

---

## 2. Telecom basics you need

You do not need to be a network engineer. You need these concepts.

### 2.1 Mobile backhaul

A mobile phone talks over radio to a **cell site** (a base station). The cell site must then be connected to the operator's
core network. That connection is called **backhaul**. In our model there are two generations of cell sites:

* **2G sites (BTS)** speak old-style **TDM** (time-division multiplexing) over **E1** circuits to a controller called the **BSC**
  (Base Station Controller). The link between BTS and BSC is called **Abis**.
* **4G sites (eNB)** and **enterprise customers** use ordinary Ethernet/IP.

### 2.2 GPON (the fibre access network)

GPON (Gigabit Passive Optical Network, ITU-T G.984) brings fibre to many endpoints by **splitting light passively**:

```
OLT  ──PON port──feeder fibre──► SPLITTER (1:8) ──drop fibre──► ONT  (at the cell site / customer)
(in the exchange)                (in a street cabinet)                 (box at the site)
```

| Term | Meaning |
|---|---|
| **OLT** (Optical Line Terminal) | The active box in the operator's building. Has many **PON ports**. |
| **PON port** | One optical port on the OLT; one fibre tree hangs off it. |
| **Feeder fibre** | Fibre from the PON port to the splitter. Cutting it kills everything behind the splitter. |
| **Splitter** | Passive glass device that divides light 1→8 (or 2→8). **Has no power, cannot send alarms.** |
| **Drop fibre** | Fibre from the splitter to one ONT. |
| **ONT** (Optical Network Terminal) | Box at the site. Cell-site ONTs also have **E1 ports** (see below). |
| **ODN** | Optical Distribution Network: all the passive fibre and splitters between OLT and ONTs. |
| **Type-B protection** | A splitter fed by two feeders from two PON ports; if the working feeder breaks, the OLT switches to the standby feeder. |

Key GPON alarms (from G.984.3) you will see: **PON_LOS** (the port receives no light), **ONT_LOSi** (the OLT lost contact
with ONT i), **ONT_SDi** (signal degraded for ONT i), **PON_BER_SD** (bit-error-rate too high on the port), **ONT_DYING_GASP**
(the ONT lost power and sent a last message).

Optical **receive power** is measured in dBm (negative numbers; −18 dBm is healthy, below −27 dBm the ONT can no longer
decode the signal for "class B+" optics). Our prediction model watches this number drift down.

### 2.3 G.702 and E1 (the TDM side)

ITU-T **G.702** defines the classic digital hierarchy bit rates. The two we use:

* **E1 = 2048 kbit/s**: the basic circuit carrying 2G Abis traffic (framing from G.704).
* **E3 = 34368 kbit/s**: carries 16 E1s, produced by a **PDH multiplexer** (our `G702Mux`).

Because the GPON network is packet-based, E1 circuits are carried across it using **circuit emulation (CES)**: the ONT turns
the E1 into packets, a **pseudowire** (CESoPSN, RFC 5086) carries them across the network, and a **CES gateway** in the core
turns them back into E1s and hands them to the BSC over a channelized **STM-1** link.

Key G.702-side alarms: **E1_LOS** (no signal on the E1), **E1_AIS** (an "all ones" signal meaning "something upstream
failed"), **E1_FRAME_SLIP** (clock mismatch, G.822), **E1_ERRORED_SECONDS** (bit errors, G.826), **PW_DOWN** (pseudowire
down), **PW_JITTER_BUFFER_UNDERRUN** (packets arrive too irregularly), **ABIS_LINK_DOWN** (BSC lost the cell).

### 2.4 Layers

The network is described in three layers plus services:

* **access**: OLT, PON ports, fibres, splitters, ONTs, BTS, E1 circuits
* **aggregation**: aggregation switches, OLT uplinks, the PDH mux and its E3 trunk
* **core**: core routers, the CES gateway, the BSC, pseudowires, STM-1
* **service**: the end-to-end products (2G Abis backhaul, 4G backhaul, enterprise L2VPN)

### 2.5 Why one fault makes many alarms

If feeder fibre F-A1 is cut:

* the OLT sees no light on PON-A1 → **PON_LOS** (SNMP trap from OLT-A)
* the OLT loses four ONTs → 4 × **ONT_LOSi**
* two of those ONTs carried E1s → the CES gateway reports 2 × **PW_DOWN** and 2 × **E1_AIS** (syslog)
* the BSC loses two cells → 2 × **ABIS_LINK_DOWN** (event stream)
* service assurance sees 4G/enterprise services down → 3 × **SERVICE_SLA_BREACH**

About 14–15 alarms, from three different systems, in three different formats, and **none of them is on the fibre**, because a
fibre cannot report. Turning those into "one incident, root cause F-A1, 5 services and 2 cell sites affected, switch to the
standby feeder" is the core job of this system.

---

## 3. Fault-management basics

| Concept | Meaning in this project |
|---|---|
| **Alarm** | One normalised fault message: type, severity, entity, reporter, timestamps, state (active/cleared). |
| **Raise / clear** | Devices send a "raise" when a condition starts and a "clear" when it ends. |
| **Severity** | critical > major > minor > warning > info. |
| **Category** | link_down, signal_degradation, timing_sync, equipment, configuration, performance. |
| **Incident** | A group of alarms believed to have one cause. The unit the closed loop works on. |
| **Correlation** | Deciding which incident a new alarm belongs to. |
| **Compression** | raw alarms ÷ incidents. Higher is better (less noise for humans). |
| **RCA** | Root-cause analysis: which entity actually failed. |
| **Impact / blast radius** | Everything downstream of the root cause; we count services. |
| **Enrichment** | Adding context to an alarm: where it is in the topology, device metadata, history. |
| **Playbook** | A scripted remediation (one or more steps) for a kind of fault. |
| **Closed loop** | The system acts on its own analysis and then checks whether it worked. |
| **Autonomy level** | advisory (only recommend), supervised (prepare, wait for approval), autonomous (just do it). |
| **Guardrail** | A limit that stops autonomous action (too risky, too many services, low confidence, too frequent). |
| **Escalation** | Handing an incident to a human with a ticket and full context. |
| **MTTD** | Mean Time To Detect: fault start → incident created. |
| **MTTR** | Mean Time To Resolve: fault start → service restored. |

---

## 4. Set up and run it (step by step)

### 4.1 Prerequisites

* **Python 3.10 or newer** (`python3 --version`). Tested on 3.13.
* **Node.js 18 or newer** with npm (`node --version`). Tested on Node 22.
* Internet access the first time, to install Python and npm packages.
* Ports **8000** (backend), **5173** (dashboard) and optionally **5514/UDP** (syslog listener) free.

### 4.2 Unzip

```bash
unzip gpon-fault-poc.zip
cd gpon-fault-poc
```

### 4.3 Start the backend (terminal 1)

```bash
./run_backend.sh
```

What the script does (read `run_backend.sh`, it is short):

1. `cd backend`
2. If `backend/.venv` does not exist: `python3 -m venv .venv` and `pip install -r requirements.txt`
3. `uvicorn app.main:app --host 0.0.0.0 --port 8000`

On start-up the backend:

* seeds `backend/data/history.db` (SQLite) with 30 days of synthetic history, the first time only
* trains the anomaly and prediction models (about 1 second)
* starts all background loops (simulator, ingestion, correlation engines, closed loop)

Check it: open http://localhost:8000/api/health. You should see `{"status":"ok", ...}`. Interactive API docs are at
http://localhost:8000/docs.

**Windows:** `.\run_backend.ps1` in PowerShell.

### 4.4 Start the dashboard (terminal 2)

```bash
./run_frontend.sh
```

This runs `npm install` the first time, then `npm run dev` (Vite on port 5173). Vite proxies every `/api/...` request to
`http://localhost:8000` (see `frontend/vite.config.js`). Open **http://localhost:5173**.

**Windows:** `.\run_frontend.ps1`. **Both at once:** `./run_all.sh`.

### 4.5 Optional: single port

```bash
cd frontend && npm run build      # creates frontend/dist
# restart the backend; it now also serves the built dashboard at http://localhost:8000
```

### 4.6 Reset to a clean state

* In the UI: **Repair network** (removes injected faults) or **Reset all** (also clears incidents).
* Fully fresh history: stop the backend, delete `backend/data/history.db*`, start again.

---

## 5. A guided tour of the dashboard

**Header chips** show the health of the platform itself: dashboard link, which correlation engine is active, whether the AI is
online, ingestion state and queue depth. Banners appear for safe mode, failover and a lost backend connection.

**KPI strip**: MTTD, MTTR (with the rule-based baseline), alarm compression, % resolved autonomously, open incidents, waiting
approvals, escalations, predicted faults.

**Scenario bar**: buttons that inject faults into the simulator. Hover a button to read its story. *Guided demo* runs four
scenarios plus an engine crash. *show simulator ground truth* marks where faults were really injected (⚡), useful to check
the AI.

**Tab 1, Operations**

* *Topology*: rows are Core, Aggregation, OLT, PON port, Splitter, ONT, Cell site. Colours: blue = GPON, purple = G.702, grey = IP.
  Alarmed nodes are filled with their severity colour; a pulsing red ring marks the AI's root cause; "RC" on a link marks an
  inferred passive fault (e.g. a fibre); dashed feeder = standby. Click anything for its ontology record.
* *Correlated incidents*: open first, then recently resolved. Click one to open the **incident drawer**.
* *Real-time alarm feed*: newest first; click a row to open its incident.
* *System activity*: platform events (scenarios, drills, actions, escalations, failovers).

**Incident drawer**: phase stepper (Detect → Analyze → Decide → Act → Verify → Resolved/Escalated); operator buttons
(Approve / Reject / Execute / Acknowledge / Resolve); metrics; RCA hypotheses with confidence bars and evidence; impact;
the policy decision and why; ranked playbooks with historical success; actions with verification checks; correlated alarms
(click one for its enrichment); full timeline.

**Tab 2, Closed loop**: a board with four columns (awaiting approval, advisory, executing/verifying/watching, escalated) and
the action log.

**Tab 3, Autonomy & resilience**: the editable autonomy matrix and guardrails; fault-tolerance drill buttons; ingestion pipeline
gauges and counters; correlation engine instances and failovers; AI component status and active anomalies/predictions;
circuit breakers; dead-letter queue.

**Tab 4, Trends & KPIs**: comparison table (rule-based history vs AI history vs this session), live charts (ingest vs alarm rate,
queue depth, active alarms vs open incidents) and 30-day history charts.

**Try this first:** click *Cascading fibre cut*, wait 5 seconds, click the incident, read the RCA section, press *Approve*,
and watch the stepper move to Resolved.

---

## 6. Repository map

```
gpon-fault-poc/
├── README.md                    quick start, demo script, API summary
├── run_backend.sh / .ps1        create venv + start backend
├── run_frontend.sh / .ps1       npm install + start dashboard
├── run_all.sh                   both
├── backend/
│   ├── requirements.txt
│   ├── config/                  ALL behaviour knobs (YAML) - section 10
│   │   ├── topology.yaml        ontology + every network element
│   │   ├── alarm_catalog.yaml   alarm types, categories, RCA evidence weights
│   │   ├── playbooks.yaml       remediation playbooks
│   │   ├── policy.yaml          autonomy matrix + guardrails
│   │   └── settings.yaml        timings, queue sizes, thresholds
│   ├── app/
│   │   ├── main.py              FastAPI routes (thin layer)
│   │   ├── runtime.py           builds everything, background loops, scenarios, drills, KPIs
│   │   ├── ontology.py          Topology graph + AlarmCatalog
│   │   ├── simulator.py         the fake network
│   │   ├── sources.py           wire formats + retrying senders
│   │   ├── ingestion.py         gateway, de-dup, re-order, event log
│   │   ├── correlation.py       correlation engine + active/standby supervisor
│   │   ├── enrichment.py        alarm enrichment
│   │   ├── ai.py                ML models, RCA, ranking, rule-based fallback
│   │   ├── closed_loop.py       policy, device adapter, closed-loop controller
│   │   └── history.py           SQLite: history, learned stats, checkpoints
│   ├── scripts/verify_demo.py   end-to-end test against a running backend
│   └── data/                    history.db (created at runtime)
├── frontend/
│   ├── package.json, vite.config.js, index.html
│   └── src/
│       ├── main.jsx, App.jsx    entry + page layout, tabs, polling
│       ├── api.js               fetch helper, usePoll hook, formatters
│       ├── styles.css           dark NOC theme
│       └── components/          TopologyView, IncidentDetail, Panels, ClosedLoopBoard, AutonomyResilience, Trends
└── docs/                        ARCHITECTURE, TOPOLOGY_ONTOLOGY, AI_LOGIC, CLOSED_LOOP, FAULT_TOLERANCE, METRICS, screenshots
```

Rule of thumb: **behaviour lives in YAML, mechanics live in Python, presentation lives in React.** Most changes a product
person asks for are YAML edits.

---

## 7. The architecture in one picture

```
 ┌──────────── simulator.py ────────────┐
 │ faults → status propagation → alarms │  + telemetry every 2 s, + background noise
 └───────────────┬──────────────────────┘
                 │ raw messages (SNMP trap dict / syslog line / JSON event / telemetry batch)
                 ▼
 sources.py   SourceClient ×4  (buffer, delay jitter, retry with exponential backoff + full jitter)
                 ▼  submit()
 ingestion.py IngestionGateway: parse → validate (DLQ) → admission control (bounded queue, watermark shedding)
                 ▼  run() loop, 450 ev/s
              de-dup by event id → re-order buffer (1 s, by device time) → EventLog (offset-addressed)
                 ▼  read(offset)
 correlation.py  EngineSupervisor ── leader CorrelationEngine (corr-a)   standby (corr-b)
                 │                    alarm lifecycle, enrichment, correlation, merge
                 │                    telemetry → ai.analyze_telemetry → AI_ANOMALY / PREDICTED_FAULT alarms
                 │                    checkpoint state+offset to SQLite every 1 s
                 ▼  incidents (dicts inside the leader's state)
 closed_loop.py  ClosedLoopController.tick() every 0.5 s:
                 detected → analyze (ai.rca, impact, playbooks) → decide (policy+guardrails)
                 → act (DeviceAdapter → simulator.apply_action) → verify → resolved / escalated
                 ▼
 runtime.py   Runtime.snapshot()  ──►  main.py  GET /api/snapshot  ──► React dashboard (polls every 1 s)
```

Everything runs in **one Python process** on one asyncio event loop. Each box is written so it could become its own service
(see `docs/ARCHITECTURE.md`, section "From PoC process to deployed services").

### Background tasks started by `Runtime.start()` (runtime.py)

| Task | Period | Job |
|---|---|---|
| `_sim_loop` | 0.5 s | `sim.tick()`, render alarm events, hand them to sources (with occasional SNMP retransmits) |
| `_telemetry_loop` | 2 s | `sim.telemetry()` → telemetry source |
| `_noise_loop` | 12–25 s | random realistic transients |
| `_sampler` | 2 s | records points for the live charts |
| `gateway.run` | 50 ms | drains the ingestion queue into the event log |
| `supervisor.run` | 0.25 s | leader processes the log, heartbeats, checkpoints; failover logic |
| `loop.run` | 0.5 s | closed-loop controller tick |
| `SourceClient.run` ×4 | continuous | deliver buffered messages with retry |
| UDP endpoint | on packet | real syslog on :5514 |

---

## 8. Follow one fault end to end through the code

Scenario: you click **Cascading fibre cut**. Follow along in the files.

**Step 1: the button** (`frontend/src/App.jsx`, `run('/scenarios/cascade_fiber_cut')`) → `POST /api/scenarios/cascade_fiber_cut`
(`backend/app/main.py`, `run_scenario`) → `Runtime.run_scenario` (`runtime.py`) → `sim.inject("F-A1", "cut")`.

**Step 2: the simulator notices** (`simulator.py`). Within 0.5 s `_sim_loop` calls `NetworkSim.tick()`:

* `_recompute()` evaluates each entity's status: an entity is down if it has its own "down" fault or any `depends_on`
  parent is down. F-A1 is down → SPL-A1 → drops → ONTs → E1s → BTS, pseudowires, services are all down.
* `_expected_alarms()` turns statuses into the alarms each element would report, for example the PON-port rule: "port is up
  but its active feeder is down → OLT reports `PON_LOS` with `laser_tx=ok`". Each alarm key is `(reporter, entity, type)`.
* `tick()` diffs expected vs previously active keys → produces `raise` events (and `clear` events for keys that went away).

**Step 3: wire formats** (`sources.py`, `render`). Reporter class decides format: OLT → SNMP trap dict (trap OID +
varbinds), CES gateway / mux / IP → RFC 5424 syslog line, BSC/NMS/SA → JSON stream event. `SourceClient.send` buffers it with
a random delivery delay (so messages arrive out of order on purpose).

**Step 4: ingestion** (`ingestion.py`).

* `SourceClient.run` calls `IngestionGateway.submit(source, raw)`.
* `parse()` normalises any of the four formats to one dict:
  `{kind:"alarm", id, reporter, entity, type, severity, state, ts, source, detail, priority}`.
  Bad input → `dlq`, response `invalid`.
* Admission: queue full → `rejected` (+retry_after); above the 60 % watermark and low priority → `rejected` (shed).
  Otherwise appended to the queue. Rejected messages are retried by the source with backoff.
* `run()` drains the queue at `process_rate_per_s`. `_dedup_and_buffer` drops ids already seen and pushes the event into a
  heap ordered by device timestamp. `_release` pops events older than `now − reorder_window_s` and appends them to the
  `EventLog`, which gives each one an **offset**.

**Step 5: correlation** (`correlation.py`). The supervisor's `step()` lets the leader engine call `process(log)`:

* `_alarm(ev)`: stale check (older than the last event for this entity+type → ignore); clear handling; repeat handling;
  otherwise create an alarm record `ALM-xxxxx`, run `enrich()` (`enrichment.py`), then `_correlate()`.
* `_correlate`: score against each open incident with `_score()`
  (`0.6·topology affinity + 0.25·time proximity + 0.15·co-occurrence`). Best ≥ 0.5 → `_attach`; several matches → `_merge`;
  none → `_new_incident` (this sets `onset_ts` and `metrics.mttd_s`).
* The first ONT_LOSi opens `INC-0001`; the PON_LOS, the other ONTs, PW_DOWN, E1_AIS, ABIS and SLA alarms all attach to it
  because they are upstream/downstream of each other in `topology.yaml`.

**Step 6: analyze** (`closed_loop.py`). `ClosedLoopController.tick()` → `step()`: the incident is in phase `detected`; once no
new alarm arrived for `holddown_s` (3 s) it calls `analyze()`:

* `ai.rca(active_alarms)` (`ai.py`) scores ~26 candidates; F-A1 wins (~89 %) because `PON_LOS` with `laser_tx=ok` implicates the
  feeder fibre (weight 1.0) while the port gets 0.2, fibres are a common root cause historically, and F-A1 has no healthy
  dependents. OLT-A loses because ONTs on PON-A2 are healthy and because OLT-A is itself reporting (so it is alive).
* `topo.impacted("F-A1")` → 5 services, 2 cell sites, subscriber count.
* `_category()` → `link_down` (from the PON_LOS evidence).
* `_match_playbooks()` → `pon_type_b_switchover` (fibre + link_down, and SPL-A1 is protected) and `noc_investigation`;
  `ai.rank_playbooks()` orders them by historical success.

**Step 7: decide** (`decide()`): root F-A1 has policy class `ODN`; `policy.yaml` says `ODN × link_down = supervised`. So the
phase becomes `awaiting_approval` and `loop.pending` holds the exact step (`pon_protection_switch` on target `PON-A1`). Even if
you set the cell to autonomous, the blast radius (5 > 4) would escalate it.

**Step 8: act**: you press *Approve* → `POST /api/incidents/INC-0001/approve` → `operator()` → `act()` records `ACT-0001`, sets
phase `acting` and schedules `_execute` → `DeviceAdapter.execute()`: resolves the managing element (`topo.manager_of` → OLT-A),
checks the circuit breaker, simulates protocol latency, checks reachability, calls `sim.apply_action("pon_protection_switch",
"PON-A1")`, which re-points SPL-A1's `depends_on` from F-A1 to F-A1P. The result is queued in `pending_results` and applied on
the next tick by `_apply_result` → phase `verifying` with an 8 s window.

**Step 9: the network heals**: next `sim.tick()`: SPL-A1 is up again via the standby feeder, so all those alarms are no longer
expected → `clear` events flow through the same pipeline → the engine marks the alarms cleared. The OLT also raises
`PON_PROTECTION_UNAVAILABLE` (warning): protection is now lost until the fibre is fixed.

**Step 10: verify** (`verify()`): every second it checks "no service-affecting (critical/major/minor, non-AI) alarm active" and
the playbook KPI if any. It remembers when it first became OK (`first_ok_ts`) and counts relapses. At the deadline it passes →
`resolve(inc, "operator", first_ok_ts)` → MTTR computed, follow-up field ticket `FLD-xxxx` opened (repair the fibre), incident
appended to history (`history.record_incident`).

**Step 11: the screen** (`Runtime.snapshot()` → `GET /api/snapshot` every second → `App.jsx` re-renders). The entity view
(`Runtime.entity_view`) marks F-A1 as root and its descendants as impacted, which `TopologyView.jsx` draws.

If you understand these 11 steps you understand the system. The other scenarios take different branches of the same code:

* *E1 timing slips*: `decide()` finds `G702 × timing_sync = autonomous` → `act()` immediately → verify checks `slips ≤ 0` on
  fresh telemetry.
* *PON optics*: autonomous re-calibration → the simulator makes the fault vanish for 2.5 s then come back → verification sees
  a relapse → `decide(step 2)` → step risk `high` > guardrail `medium` → `escalate()`.
* *Rx drift*: no device alarm; `ai.analyze_telemetry` → `_predict` raises `PREDICTED_FAULT` → predictive incident → advisory.

---

## 9. Module-by-module deep dive

### 9.1 `ontology.py`: the network model

* `Topology.__init__` reads `topology.yaml`, copies class properties (layer, kind, domain, policy_class, observable) onto each
  entity, and builds the reverse index `dependents`.
* `ancestors(eid)` / `descendants(eid)`: breadth-first closures with hop distances (cached; cache is rebuilt by
  `set_dependencies`, used for protection switching).
* `affinity(a, b)`: correlation strength (see section 8 step 5 and `docs/AI_LOGIC.md`). Siblings only count when they share a
  "shared-risk" ancestor such as a splitter or PON port, not merely the same OLT chassis (`NON_SHARED_RISK`).
* `impacted(eid)`: descendants grouped into services, devices, cell sites, subscriber total.
* `manager_of(eid)`: which element executes an action (ONT/E1 → its OLT via OMCI, pseudowire → CES gateway, link → its upstream end).
* `layout()`: computes x/y for the topology view (fixed rows per class, leaves spread evenly, parents centred).
* `AlarmCatalog`: lookups into `alarm_catalog.yaml`; `implicates(type, detail)` returns the RCA evidence weights, with
  `when:` overrides depending on alarm details (e.g. `laser_tx: ok`).

### 9.2 `simulator.py`: the fake network

* State: `faults` (entity → `Fault(type, since, params, until)`), `mgmt_unreachable` (devices whose management plane is down),
  `extra_alarms` (noise), `active` (alarms currently emitted).
* Fault types: `cut`, `fail`, `power` (down); `optics_degraded`, `timing`, `rx_drift` (degraded; rx_drift turns into down
  below sensitivity − 2.5 dB).
* `_recompute` propagates the worst status down the dependency tree.
* `_expected_alarms` is the **observer model**: one block per entity class saying which element reports what. If the reporter
  itself is down, it cannot report (this is why an OLT failure produces `NE_UNREACHABLE` from the NMS instead of ONT alarms).
* `telemetry()`: per-OLT batches (OLT CPU/temp, PON BER/laser bias/utilisation, ONT Rx power/temp/BER, E1 ES/SES/slips) and a
  CES-gateway batch (pseudowire underruns/loss). Faults shape the numbers.
* `apply_action`: how each remediation changes the network. This is the only place where "actions" have effects.
* `noise_event`: customer power loss on an enterprise ONT, PDH microwave fade on E1-301/302, CPU spike on an aggregation switch.
* `truth_onset`: used **only** for KPI measurement (MTTD/MTTR), never for analysis.

### 9.3 `sources.py`: wire formats and senders

* `render(ev)` produces the native format. SNMP uses a private enterprise OID `1.3.6.1.4.1.64999` with a trap OID per alarm type
  (`TRAP_OID`). Syslog uses RFC 5424 with structured data `[alarm@64999 id=... entity=... state=... severity=... seq=...]`.
* `SourceClient`: bounded buffer, random delivery delay, retry loop with exponential backoff and full jitter, and
  latest-value-wins for telemetry (stale samples are dropped, not retried). `recent` keeps sent payloads for the replay drill.

### 9.4 `ingestion.py`: the front door

* `EventLog`: an append-only list with offsets (a stand-in for a Kafka topic); keeps the last 60k events.
* `IngestionGateway.parse`: four parsers, one normalised output. Unknown entity or format → `ValueError` → DLQ.
* `submit`: admission control. Priority 2 = critical/major or any clear; priority 1 = everything else; telemetry = 0.
* `run` / `_dedup_and_buffer` / `_release`: de-duplicate, re-order, append to the log; counts `duplicates`, `reordered`, `late`.
* `snapshot()`: what the resilience panel shows.

### 9.5 `correlation.py`: the brain's memory

* The engine's whole state is one JSON-serialisable dict (`empty_state()`): `offset`, `alarms` (id → record), `index`
  (entity|type → current alarm id), `incidents`, `last_ts` (per-key newest timestamp), `telemetry` (latest metrics per
  entity), `stats`. Keeping it plain data is what makes checkpoints and failover trivial.
* Alarm lifecycle in `_alarm`: stale → ignore; clear → mark cleared; repeat of active → count++; re-raise of a cleared alarm in
  an open incident → reactivate (flap); else new alarm → enrich → correlate.
* `_score` ignores non-service-affecting warnings as anchors (a CPU spike must not glue unrelated faults together) and falls back
  to a strict rule in safe mode.
* `_new_incident` sets `kind` = reactive / anomaly / predictive.
* `EngineSupervisor`: `start`, `crash` (drill), `step` (leader work, heartbeat, checkpoint; or failover: load checkpoint →
  replay from its offset → promote standby), `snapshot`.

### 9.6 `enrichment.py`

`enrich(ctx, alarm)` returns `topology` (class, layer, OLT, PON port, splitter, path to core, managing element, site), `device`
(vendor, model, software, install date, serial...), `impact` (services, cell sites, subscribers) and `history` (incidents in 30
days, MTBF, last incident). It is computed once when the alarm is created.

### 9.7 `ai.py`: models

* `train(sampler)`: IsolationForest per telemetry family on healthy samples from the simulator; LogisticRegression for
  prediction on synthetic windows.
* `analyze_telemetry(ev)`: returns derived alarm events (`AI_ANOMALY` raise/clear, `PREDICTED_FAULT` raise/clear). Note the
  consecutive-sample logic to avoid flapping.
* `observe_alarm` / `update_rate`: alarm-storm detection (EWMA z-score).
* `cooccurrence`: NPMI from history.
* `rca(alarms)`: the Bayesian scorer. Read it together with `docs/AI_LOGIC.md` section 3; the table of likelihoods there
  maps one-to-one to the `if/elif` chain in the code.
* `rank_playbooks`: success rate × specificity, with similar-incident stats.
* `rule_based_rca`: the safe-mode fallback.
* Every public method calls `check()` first, which raises `AIUnavailable` when `up` is False. Callers catch it.

### 9.8 `closed_loop.py`: deciding and acting

* `Policy`: loads `policy.yaml`; `level(class, category)`; live edits via `set_level` / `set_guardrail`.
* `CircuitBreaker`: closed → open after N failures → half-open after the reset time.
* `DeviceAdapter.execute`: no-device actions (watch, ticket, dispatch) skip the network; device actions resolve the manager,
  check the breaker, retry with timeout, call `sim.apply_action`.
* `ClosedLoopController`: `tick` → `step` per incident (the phase machine), `analyze`, `decide`, `act`, `_apply_result`, `verify`,
  `escalate`, `resolve`, and `operator` (the human actions from the UI).
* All loop state is stored inside the incident dict (`incident["loop"]`), which lives in the engine state, so it survives failover.

### 9.9 `history.py`

SQLite with two tables: `incidents` (history, seeded + live) and `checkpoints`. `seed()` generates 30 days (days 1–15
`mode=rule`, 16–30 `mode=ai`) from `ROOT_MIX`. `refresh_stats()` derives priors, co-occurrence and playbook success.
`daily_trends()` feeds the trend charts.

### 9.10 `runtime.py` and `main.py`

`Runtime` is the composition root: it constructs every component in dependency order, owns the background tasks, implements
scenarios (`SCENARIOS`, `run_scenario`, `guided_demo`), drills (`DRILLS`, `drill`, `_storm`, `_replay`), KPIs (`kpis`), the
topology status overlay (`entity_view`) and the dashboard payload (`snapshot`). `main.py` is a thin FastAPI layer; all routes
are `async` so they run on the same event loop as the background tasks (no thread-safety issues).

### 9.11 Frontend

* `api.js`: `api()` fetch helper; `usePoll(path, ms)` keeps the last good value and reports errors (the "link lost" banner);
  colour and time formatters.
* `App.jsx`: polls `/api/snapshot` every 1 s and `/api/topology` every 4 s; holds UI state (tab, selected incident/entity,
  focus); renders the header, KPIs, scenario bar and tabs.
* `TopologyView.jsx`: pure SVG from `layout` + `entity_view`.
* `IncidentDetail.jsx`: the drawer; also fetches `/api/incidents/{id}` for enriched alarm records.
* `Panels.jsx`: incident cards and list, alarm feed, event log, entity panel.
* `ClosedLoopBoard.jsx`, `AutonomyResilience.jsx`, `Trends.jsx`: the other tabs (Recharts for charts).

There is no client-side state store and no router; the backend snapshot is the single source of truth.

---

## 10. Configuration files explained

All under `backend/config/`. Restart the backend after editing (policy can also be edited live in the UI, but those edits are
not written back to the file).

### `topology.yaml`

```yaml
ontology:            # classes, layers, relationships (documentation + class properties used by code)
devices:             # boxes and ports:  id, class, name, depends_on, meta
links:               # fibres, E1s, uplinks, pseudowires: id, class, a, b, depends_on, attributes
services:            # end-to-end services: id, class, name, depends_on (every element on the path), meta
```

`depends_on` always points **upstream**. A splitter may have `protection: {type, working, standby}`.

### `alarm_catalog.yaml`

Per alarm type: `category`, `severity`, `domain`, `ref` (standard), `implicates` (RCA evidence weights by entity class) and
optional `when` overrides keyed on alarm details.

### `playbooks.yaml`

Per playbook: `match` (either `alarm_types`, or `root_classes` + `categories`, `"*"` = wildcard), `steps` (action, target
[`root` | `protected_port` | `root_pw`], risk, protocol, description, optional rollback), `verify` (`window_s`, optional
`kpi: {metric, max|min}`), optional `follow_up`.

### `policy.yaml`

`matrix[device_class][fault_category] = advisory | supervised | autonomous` and `guardrails` (max risk, max blast radius,
min RCA confidence, rate limit, safe-mode ceiling).

### `settings.yaml`

| Section | Notable keys |
|---|---|
| simulation | `tick_s`, `telemetry_interval_s`, `background_noise`, `trap_retransmit_ratio`, `network_jitter_s` |
| ingestion | `queue_capacity`, `high_watermark`, `process_rate_per_s`, `reorder_window_s`, retry base/cap, `syslog_udp_port` |
| correlation | `window_s`, `join_threshold`, `min_topology_affinity`, `holddown_s`, heartbeat/failover/checkpoint timings |
| closed_loop | `verify_window_s`, `action_timeout_s`, `action_retries`, breaker settings |
| ai | `anomaly_quantile`, `anomaly_consecutive`, `prediction_horizon_s`, `rx_sensitivity_dbm` |

---

## 11. The API

Full interactive docs: http://localhost:8000/docs. The important endpoints:

| Endpoint | Use |
|---|---|
| `GET /api/health` | liveness + component status |
| `GET /api/snapshot` | everything the UI shows |
| `GET /api/topology` | ontology, entities, layout |
| `GET /api/incidents/{id}` | one incident with enriched alarm records |
| `POST /api/incidents/{id}/approve \| execute \| reject \| ack \| resolve` | operator actions, body `{"note": "..."}` optional |
| `GET /api/policy`, `PUT /api/policy/matrix`, `PUT /api/policy/guardrails`, `POST /api/policy/reset` | autonomy |
| `GET /api/scenarios`, `POST /api/scenarios/{name}` | scenarios (`guided_demo` too) |
| `POST /api/drills/{name}` | `alarm_storm`, `duplicates_out_of_order`, `crash_correlation_engine`, `ai_outage`, `device_unreachable` |
| `POST /api/reset` body `{"full": true}` | repair network (and clear incidents) |
| `POST /api/noise/on \| off` | background noise |
| `GET /api/history/trends` | 30-day daily KPIs |
| `POST /api/ingest/{snmp\|syslog\|stream\|telemetry}` | push external events; 202 / 429 + Retry-After / 400 |

Examples:

```bash
# inject a fault and look at incidents
curl -X POST localhost:8000/api/scenarios/autonomous_e1_timing
curl -s localhost:8000/api/snapshot | python3 -m json.tool | less

# push your own event (it must reference an entity id from topology.yaml)
curl -X POST localhost:8000/api/ingest/stream -H 'content-type: application/json' -d '{
  "event_id":"my-1","producer":"BSC-1","type":"CALL_DROP_RATE_HIGH","entity":"SVC-2G-201",
  "state":"raise","severity":"minor","event_time":"2026-10-20T12:00:00Z"}'

# send a real syslog datagram to the UDP listener
echo '<132>1 2026-10-20T12:00:00Z AGG-2 fmd - HIGH_CPU [alarm@64999 id="x1" entity="AGG-2" state="raise" severity="warning" seq="1"] cpu' \
  | nc -u -w1 localhost 5514
```

---

## 12. Testing and verification

`backend/scripts/verify_demo.py` is an end-to-end test that drives the running backend through every scenario and drill and
asserts the outcome (17 checks). Run it after any change:

```bash
./run_backend.sh            # terminal 1
cd backend && .venv/bin/python scripts/verify_demo.py     # terminal 2, takes about 4-5 minutes
```

It turns background noise off during the run and back on at the end. Exit code 0 means all checks passed. When a check fails
the script prints which wait timed out; open the dashboard to see the state it got stuck in.

Quick manual smoke test: start both servers, click each scenario button, confirm the expected phase from the README demo
script, run each drill once.

There are no unit tests yet. Good first candidates: `Topology.affinity`, `AIService.rca` on fixed alarm sets,
`IngestionGateway.parse` per format, `CircuitBreaker` state transitions, `Policy` guardrail decisions.

---

## 13. How to make common changes (recipes)

### Add a new ONT and cell site

1. In `topology.yaml` add a drop fibre link (`a: SPL-xx`, `b: ONT-new`, `depends_on: [SPL-xx]`), the ONT
   (`depends_on: [D-new]`), and if it carries 2G: an `E1Circuit`, a `BTS`, a `Pseudowire` (`depends_on: [E1-x, CESGW-1]`) and
   a service (`depends_on: [BTS-x, PW-x, BSC-1]`).
2. Restart. The layout, simulator, telemetry, RCA and impact pick it up automatically.
3. If you want a fresh history that includes the new element, delete `backend/data/history.db*`.

### Add a new alarm type

1. Add it to `alarm_catalog.yaml` with category, severity, ref and (if it is evidence for a root cause) `implicates`.
2. Make something emit it: a rule in `NetworkSim._expected_alarms` (simulator) or send it via `/api/ingest`.
3. If it comes by SNMP, add it to `TRAP_TYPES` in `sources.py` so it gets a trap OID.

### Add a new playbook / remediation action

1. Add the playbook to `playbooks.yaml` with a `match` and `steps`.
2. Implement the action's effect in `NetworkSim.apply_action` (and, for a real network, in `DeviceAdapter.execute`).
3. If the action needs no device (ticket, workforce), add it to `DeviceAdapter.NO_DEVICE`.
4. Optionally add history rows for it in `history.py` `ROOT_MIX` so it gets a success rate.

### Change autonomy

Edit `policy.yaml` (permanent) or use the matrix in the UI (until restart).

### Add a new demo scenario

1. Add an entry to `SCENARIOS` in `runtime.py` (title, story, expect).
2. Add a branch in `Runtime.run_scenario` that injects the fault(s).
3. Add a button in `SCENARIO_BUTTONS` in `App.jsx`.
4. Add a check to `verify_demo.py`.

### Add a new telemetry metric to anomaly detection

1. Emit it in `NetworkSim.telemetry` and in `normal_samples` (the training data).
2. Add it to the family's feature list in `FAMILIES` in `ai.py` (and to `LOG_FEATURES` if it spans orders of magnitude).

### Connect a real data source (first step toward production)

* Syslog: point devices at UDP 5514 using the structured-data format shown in section 11, or adapt `SYSLOG_RE` /
  `IngestionGateway.parse` to your vendor's format.
* SNMP: run a trap receiver (e.g. pysnmp or snmptrapd) that converts traps to the dict shape in `sources.render` and POSTs
  them to `/api/ingest/snmp`, mapping your vendor's MIB OIDs in `OID_TRAP`.
* Event streams: a Kafka consumer that POSTs to `/api/ingest/stream`.
* Disable the simulator's emissions (stop `_sim_loop` / `_telemetry_loop` in `Runtime.start`) and replace
  `NetworkSim.apply_action` calls in `DeviceAdapter` with real NETCONF/OMCI/TL1 clients.

---

## 14. Debugging and troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Dashboard shows "Backend not reachable" | Backend not running or not on :8000. Check terminal 1; `curl localhost:8000/api/health`. |
| `Address already in use` | Another process on 8000/5173. Stop it, or `PORT=8001 ./run_backend.sh` and set `VITE_BACKEND=http://localhost:8001` before `npm run dev`. |
| "UDP syslog listener disabled" in the activity log | Port 5514 busy; harmless, or change `syslog_udp_port` (0 disables). |
| pip install fails | Need Python ≥ 3.10 and internet/proxy access; delete `backend/.venv` and retry. |
| Nothing happens after clicking a scenario | Wait ~4 s (hold-down). Check *System activity*. Run *Repair network* if a previous fault is still active. |
| Incident stuck in a phase | Open the drawer: the timeline and decision explain why (e.g. awaiting approval). |
| Prediction did not appear | It needs ~16–40 s of telemetry; the drift scenario must be running; AI must be online. |
| Odd correlations | Tick *show simulator ground truth*; background noise can coincide with your scenario; switch noise off. |
| Want to see raw events | `GET /api/snapshot` → `ingestion`, `engine_stats`; or add `print()` in `IngestionGateway.parse`. Uvicorn logs go to terminal 1. |

Debugging tips:

* The whole engine state is one dict: `rt.supervisor.leader.state`. In a debugger or a temporary endpoint you can inspect
  any alarm or incident directly.
* Every phase change writes to `incident["timeline"]`; read that first.
* Timings are in `settings.yaml`; slowing `tick_s` or raising `holddown_s` makes behaviour easier to watch.

---

## 15. Known limits and the path to production

| Limit (PoC) | Production approach |
|---|---|
| Simulated network and actions | Real collectors and southbound clients (NETCONF/RESTCONF, OMCI via OLT EMS, TL1), ticketing and workforce APIs |
| SNMP traps arrive pre-decoded | Trap receiver with vendor MIBs feeding `/api/ingest/snmp` |
| One process, in-memory event log | Separate services; Kafka for the log; leader election via Kubernetes lease or etcd |
| SQLite history and checkpoints | PostgreSQL/TimescaleDB; object storage for checkpoints |
| Synthetic 30-day history | Train on the operator's real alarm/incident/ticket history; periodic retraining and model monitoring |
| No authentication, single user | SSO, role-based approvals (who may approve which risk level), audit log of every automated action |
| UI polls every second | WebSocket/SSE push for large deployments |
| Policy edits in the UI are not persisted | Store policy in a database with change history and approvals |
| No unit tests, one E2E script | Unit tests per module, contract tests for parsers, chaos tests for fault tolerance |

---

## 16. Glossary

| Term | Meaning |
|---|---|
| Abis | Interface between a 2G BTS and the BSC |
| ACR | Adaptive clock recovery, how a CES port derives timing |
| AIS | Alarm Indication Signal; "upstream failure" filler on E1 |
| BER | Bit error rate |
| BSC | Base Station Controller (2G) |
| BTS | Base Transceiver Station (2G cell site) |
| CES / CESoPSN | Circuit emulation (carrying E1 over packets) / the RFC 5086 method |
| Circuit breaker | Stops calling a failing dependency for a while |
| dBm | Optical power in decibels relative to 1 mW |
| DLQ | Dead-letter queue for unparseable messages |
| E1 / E3 | 2048 kbit/s / 34368 kbit/s TDM rates (G.702) |
| EWMA | Exponentially weighted moving average |
| G.702 / G.703 / G.704 | ITU-T standards for bit-rate hierarchy / electrical interface / framing |
| G.775 / G.822 / G.826 | ITU-T standards for LOS/AIS criteria / slip objectives / error performance |
| G.984 | ITU-T GPON standard |
| IsolationForest | Unsupervised anomaly-detection algorithm |
| LOS / LOF | Loss of signal / loss of frame |
| MTBF | Mean time between failures |
| MTTD / MTTR | Mean time to detect / resolve |
| NETCONF | Network configuration protocol (RFC 6241) |
| NMS / EMS | Network / element management system |
| NOC | Network Operations Centre |
| NPMI | Normalised pointwise mutual information (co-occurrence strength) |
| ODN | Optical distribution network (passive fibre plant) |
| OLT / ONT | Optical line terminal / optical network terminal |
| OMCI | ONT management and control interface (OLT manages ONTs through it) |
| OTDR | Optical time-domain reflectometer; locates fibre breaks |
| PDH | Plesiochronous digital hierarchy (E1/E2/E3 multiplexing) |
| PON | Passive optical network |
| PW | Pseudowire |
| RCA | Root-cause analysis |
| SA | Service assurance system |
| SDH / STM-1 | Synchronous digital hierarchy / its 155.52 Mbit/s level |
| SFP | Pluggable optical transceiver |
| Slip | A dropped/repeated frame caused by clock mismatch |
| TL1 | Text-based management language used by TDM equipment |
| Type-B protection | GPON protection with duplicated feeder fibre and OLT ports |

---

## 17. Your first week: suggested exercises

1. **Day 1:** run the system, do the five-minute demo from the README, read sections 1–5 of this guide.
2. **Day 2:** follow section 8 with the code open; put a breakpoint or `print` in `CorrelationEngine._new_incident` and in
   `ClosedLoopController.decide` and watch a scenario hit them.
3. **Day 3:** change `ODN × link_down` to `autonomous` in the UI and run the fibre cut. Explain why it still asks for approval
   (blast radius guardrail). Then raise `max_blast_radius_autonomous` to 10 and run it again.
4. **Day 4:** add a fifth ONT under SPL-B1 with an enterprise service (recipe in section 13), restart, cut its drop fibre via
   a new scenario, and check the RCA names the drop fibre.
5. **Day 5:** run `verify_demo.py`; then write your first unit test for `Topology.affinity` and one for `AIService.rca` using
   the cascade alarm set.

Further reading inside the repo: `docs/ARCHITECTURE.md`, `docs/AI_LOGIC.md`, `docs/CLOSED_LOOP.md`,
`docs/FAULT_TOLERANCE.md`, `docs/METRICS.md`, `docs/TOPOLOGY_ONTOLOGY.md`.
