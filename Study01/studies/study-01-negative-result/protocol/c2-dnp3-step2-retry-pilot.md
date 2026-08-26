# C2 DNP3 Step 2 Retry — Range A Observation-Chain Pilot

**Study:** Study 01 — Negative Detection Result Reliability / Observability Validation  
**Candidate:** C2 — DNP3  
**Status:** Pre-execution procedure  
**Supersedes for new execution:** the capture-placement portion of [C2 DNP3 Step 2 Pilot](./c2-dnp3-step2-pilot.md)  
**Prior run:** `c2-step2-20260823-001` retained as Ground Truth `Invalid`  
**Common procedure:** [Common Candidate Validation Procedure](./candidate-validation-common-procedure.md)  
**Amenonuboco baseline:** `v0.12.0`, commit `78fc17746b5d663fafec9dffe563d79fe9ea02b7`

## 1. Reason for retry

The prior Step 2 registration fixed `wan_router:eth2` from a previous runtime observation. In run `c2-step2-20260823-001`, `eth2` had `172.18.0.254/24` and did not carry the predeclared DNP3 traffic; the expected `sub_a_l2_lan` gateway address `10.1.20.254/24` was on `eth5`. The preserved run remains evidence and is not overwritten.

Docker interface ordinal assignment is therefore treated as runtime-specific. This retry fixes the **selection rule**, rather than an interface ordinal: before any capture or event trigger, resolve the unique `wan_router` interface holding `10.1.20.254/24`, record the command and result in the result-free registration, commit and push it, then use that resolved interface for the original-path capture.

## 2. Event and evidence stages

| Item | Value |
| --- | --- |
| Host X / Asset Y | `sub_a_ied_02` (`10.1.20.11`) → `cc_scada_master` (`10.1.10.10`) |
| Event | One DNP3/TCP function-5 Direct Operate; link source `1024`, destination `1`; TCP `20000` |
| Sender command | `dnp3_zone_attack.py --target-ip 10.1.10.10 --target-port 20000 --function-code 5 --repeat 1` |
| Ground Truth | Sender record plus a `wan_router` capture on the runtime-resolved interface whose address is `10.1.20.254/24`, before mirror delivery. |
| Sensor input | `tap_observer:eth0` mirror-link pcap with the same host/port filter. |
| Collector output | A preserved Elasticsearch query/response from `ot-logs-dnp3-*` identifying the same host pair and DNP3 function. |
| Rule output | Not evaluated in this retry. |

## 3. Required pre-trigger registration

After the compose environment starts, but before either capture or event trigger, run and preserve:

```text
ip -br addr
```

inside `wan_router`. Determine the interface by the exact address `10.1.20.254/24`; do not infer it from `ethN` numbering. A registration is eligible for the event trigger only when exactly one interface matches and the observed output plus selected interface are committed and pushed to the Kakuriyo canonical repository.

If zero or multiple interfaces match, do not trigger traffic. Record `Unresolved` or `Invalid` according to the Common Candidate Validation Procedure.

## 4. Execution and decisions

Start both raw captures before the one-time trigger. Preserve sender output and both pcap SHA-256 values, wait a bounded collector-settle interval, and preserve an actual-schema Elasticsearch query/response. Record Ground Truth, sensor-input, and collector-output decisions independently as `Pass`, `Fail`, `Unresolved`, or `Invalid`. Do not interpret rule output in this Step.
