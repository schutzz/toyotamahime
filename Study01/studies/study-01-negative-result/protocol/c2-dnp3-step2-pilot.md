# C2 DNP3 Step 2 — Range A Observation-Chain Pilot

**Study:** Study 01 — Negative Detection Result Reliability / Observability Validation
**Candidate:** C2 — DNP3
**Status:** Pre-execution procedure
**Prerequisite:** C2 Step 1 `Pass` in `c2-step1-20260823-001`
**Common procedure:** [Common Candidate Validation Procedure](./candidate-validation-common-procedure.md)
**Amenonuboco baseline:** `v0.12.0`, commit `78fc17746b5d663fafec9dffe563d79fe9ea02b7`

## 1. Purpose and boundary

This pilot verifies the Range A observation chain for the same DNP3 Direct Operate semantics used in C2 Step 1:

```text
Ground Truth (sender + original path)
    ≠ Sensor input (mirror-link raw capture)
        ≠ Collector output (Elasticsearch structured event)
            ≠ Rule output (not evaluated)
```

## 2. Predeclared event and evidence stages

| Item | Value |
| --- | --- |
| Host X / Asset Y | `sub_a_ied_02` (`10.1.20.11`) → `cc_scada_master` (`10.1.10.10`) |
| Event | One DNP3/TCP function-5 Direct Operate; link source `1024`, destination `1`; TCP `20000` |
| Sender command | `dnp3_zone_attack.py --target-ip 10.1.10.10 --target-port 20000 --function-code 5 --repeat 1` |
| Ground Truth | Sender record plus `wan_router:eth2` original-path pcap. |
| Sensor input | `tap_observer:eth0` mirror-link pcap with the same host/port filter. |
| Collector output | A preserved Elasticsearch query/response from `ot-logs-dnp3-*` identifying the same host pair and DNP3 function. |
| Rule output | Not evaluated in Step 2. |

## 3. Procedure and decisions

Start both raw captures before the trigger, execute the predeclared command once, preserve sender output and pcap SHA-256 values, and query the collector after a bounded settle interval. Record Ground Truth, sensor-input, and collector-output decisions independently as `Pass`, `Fail`, `Unresolved`, or `Invalid` according to the Common Candidate Validation Procedure.

Collector output is `Pass` only when a preserved response from the actual collector schema identifies the event. A mirror pcap or container-health check cannot substitute for it.
