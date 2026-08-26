# C1 Modbus/TCP Step 2 — Range A Observation-Chain Pilot

**Study:** Study 01 — Negative Detection Result Reliability / Observability Validation
**Candidate:** C1 — Modbus/TCP
**Status:** Completed; see recorded C1 Step 2 evidence
**Prerequisite:** C1 Step 1 `Pass` in run `c1-step1-20260823-001`
**Amenonuboco baseline:** `v0.12.0`, commit `78fc17746b5d663fafec9dffe563d79fe9ea02b7`

## 1. Purpose and boundary

This pilot tests the Range A observation chain for the same semantic Modbus event demonstrated in C1 Step 1. It independently preserves Ground Truth, sensor input, and collector output:

```text
Ground Truth (sender + original path)
    ≠ Sensor input (mirror-link packet capture)
        ≠ Collector output (Elasticsearch structured event)
            ≠ Rule output (not evaluated in this step)
```

The pilot does not evaluate a detection rule and does not establish final C1 eligibility.

## 2. Predeclared event and evidence stages

| Item | Predeclared value |
| --- | --- |
| Host X / Asset Y | `wtp_scada_master` (`10.2.10.10`) → `pump_a_plc` (`10.2.20.10`) |
| Event | One Modbus/TCP function-6 write, reference/address `1` (holding register `40002`), value `1`, device ID `1` |
| Sender command | Baseline `modbus_overflow_attack.py --target 10.2.20.10 --port 502 --duration 1 --interval 0.5` |
| Ground Truth | Sender record plus capture on `wan_router:eth2`; neither may be replaced by mirror/collector evidence. |
| Sensor input | Capture on `tap_observer:eth0` in `mirror_link`, filter `host 10.2.10.10 and host 10.2.20.10 and tcp port 502`. |
| Collector output | Elasticsearch documents in `ot-logs-modbus-*` that identify the same host pair and Modbus function/reference, collected after the trigger. |
| Rule output | Not evaluated; no result is inferred from absence of an alert. |

## 3. Procedure

1. Create a run record before starting traffic and record the Kakuriyo pre-registration commit, Amenonuboco baseline, runtime versions, and image identifiers.
2. Provision the fixed-baseline water range and wait until the `log_structurer` Modbus tshark process is running.
3. Start two raw packet captures before the trigger:
   - independent Ground Truth capture on `wan_router:eth2`;
   - sensor-input capture on `tap_observer:eth0`.
4. Execute the predeclared sender command once; preserve its output and exit status.
5. Stop both captures and preserve their pcaps with SHA-256 digests.
6. Decode both pcaps and verify the predeclared request and reply without treating the sensor capture as Ground Truth.
7. Query Elasticsearch after an explicit bounded settle interval. Preserve the exact query and raw response used to identify collector output.
8. Record a separate decision for Ground Truth, sensor input, and collector output. Stop the range without deleting volumes after evidence export.

## 4. Decision rules

| Stage | Pass | Fail | Unresolved | Invalid |
| --- | --- | --- | --- | --- |
| Ground Truth | Sender and original-path capture confirm the event | Required evidence absent | Evidence conflicts | Simulated fallback or material deviation |
| Sensor input | Mirror-side capture confirms the same event | Mirror-side capture lacks the event while GT passes | Capture placement/readiness cannot be established | Sensor evidence replaced with a non-sensor source |
| Collector output | Preserved Elasticsearch response identifies the event | No relevant document after the predeclared settle/query procedure while sensor input passes | Query/schema correlation cannot determine whether the event was emitted | Collector result substituted with a log assertion rather than preserved output |

The present candidate pilot may record a stage failure or unresolved outcome without interpreting it as a Study 01 negative detection result.

## 5. Evidence locations

```text
evidence/candidate-evaluations/c1-modbus/run-<id>/
├── metadata.md
├── ground-truth/
├── sensor-input/
├── collector-output/
├── rule-output/
└── environment.md
```

No synthetic or placeholder packet, document, or alert may be used to populate these paths.

## 6. Recorded execution

Run [`c1-step2-20260823-001`](../evidence/candidate-evaluations/c1-modbus/run-c1-step2-20260823-001/metadata.md) passed its Ground Truth, sensor-input, and collector-output decisions. It deliberately did not evaluate rule output. This procedure remains the historical C1-specific record; subsequent cross-candidate work is governed by the [Common Candidate Validation Procedure](./candidate-validation-common-procedure.md).
