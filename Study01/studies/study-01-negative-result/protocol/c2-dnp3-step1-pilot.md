# C2 DNP3 Step 1 — Range A Ground-Truth Pilot

**Study:** Study 01 — Negative Detection Result Reliability / Observability Validation
**Candidate:** C2 — DNP3
**Status:** Pre-execution procedure
**Common procedure:** [Common Candidate Validation Procedure](./candidate-validation-common-procedure.md)
**Amenonuboco baseline:** `v0.12.0`, commit `78fc17746b5d663fafec9dffe563d79fe9ea02b7`

## 1. Purpose

This pilot determines only whether C2 can generate one repeatable DNP3/TCP event in the baseline power-grid range and establish it as Ground Truth without relying on mirror, collector, or rule output.

It does not evaluate `zone_violation`, establish sensor/collector output, select C2, or make a Study 01 detection claim.

## 2. Predeclared candidate event

| Field | Value |
| --- | --- |
| Host X | `sub_a_ied_02` (`sub_a_l2_lan`, `10.1.20.11`) |
| Asset Y | `cc_scada_master` (`cc_lan`, `10.1.10.10`) |
| Original communication path | `sub_a_ied_02` → `wan_router` → `cc_scada_master` |
| Protocol / port | DNP3 over TCP / `20000` |
| Exact operation | One `dnp3_zone_attack.py` TCP DNP3 frame with application function code `5` (Direct Operate); link-layer destination `1`, source `1024`, as constructed by the pinned baseline helper. |
| Bounded repetition count | `1` |
| Sender-side success predicate | The sender establishes TCP connection to `10.1.10.10:20000`, calls `sendall` for the generated frame without exception, and logs its local source IP, target, port, function code, and frame length. |
| Ground-truth condition | Sender-side success predicate **and** an independent capture on a pre-mirror original-path router interface both identify the predeclared TCP/DNP3 event. |

The event is selected for a discrete protocol-visible operation. Its suitability for a later alert/no-alert rule interpretation is not decided by this pilot.

## 3. Capture plan

Before executing the DNP3 operation, identify and record the router interface carrying the original traffic from `sub_a_l2_lan` or toward `cc_lan`. The chosen interface MUST NOT be `mirror_link` and MUST NOT depend on `tap_observer`, `log_structurer`, Elasticsearch, or a rule sidecar.

Capture filter:

```text
host 10.1.20.11 and host 10.1.10.10 and tcp port 20000
```

If an original-path interface cannot be identified and captured before triggering traffic, do not execute the event. Record `Fail` or `Unresolved` according to the Common Candidate Validation Procedure.

## 4. Procedure

1. Commit a result-free run registration and record its commit in the run metadata.
2. Use only a detached Amenonuboco checkout at the pinned baseline.
3. Generate/provision the power-grid manifest and start only the services necessary for this Ground Truth pilot.
4. Observe router IP/interface mapping and record the pre-mirror capture interface.
5. Start original-path capture and sender-side logging before copying/executing the pinned helper in `sub_a_ied_02`.
6. Run the helper once using `--target-ip 10.1.10.10 --target-port 20000 --function-code 5 --repeat 1`.
7. Stop the capture, preserve raw evidence and SHA-256, and decode DNP3 fields from the pcap.
8. Record `Pass`, `Fail`, `Unresolved`, or `Invalid` only for the Ground Truth stage.

## 5. Decision rules

| Outcome | C2 Step 1 meaning |
| --- | --- |
| Pass | Sender evidence and independent original-path capture confirm the same predeclared function-5 DNP3/TCP event. |
| Fail | Required Ground Truth evidence is absent. |
| Unresolved | Sender and capture evidence conflict, or capture placement/decoding is ambiguous. |
| Invalid | Simulated data, an unverified stand-in, or material procedure deviation was used. |

## 6. Evidence layout

```text
evidence/candidate-evaluations/c2-dnp3/run-<id>/
├── metadata.md
├── ground-truth/
├── sensor-input/
├── collector-output/
├── rule-output/
└── environment.md
```

Only Ground Truth is evaluated in this step. The remaining paths must remain empty or explicitly `Not evaluated` rather than being populated with inferred evidence.
