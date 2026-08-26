# C2 DNP3 Step 4 — Range B Mirror-Fault Feasibility Pilot

**Study:** Study 01 — Negative Detection Result Reliability / Observability Validation  
**Candidate:** C2 — DNP3  
**Status:** Pre-execution procedure  
**Prerequisites:** C2 Steps 1–3 `Pass`; Step 3 positive control replicated  
**Common procedure:** [Common Candidate Validation Procedure](./candidate-validation-common-procedure.md)  
**Amenonuboco baseline:** `v0.12.0`, commit `78fc17746b5d663fafec9dffe563d79fe9ea02b7`

## 1. Purpose and boundary

This candidate-validation probe tests whether one nontrivial, isolated observation-path fault can make the C2 DNP3 positive-control event absent from the detection path while leaving the communication itself and unrelated platform health intact.

It is **not** a Study 01 Range B result, a selected scenario, or a final interpretation of rule performance. It is evidence only for C2 Step 4 fault feasibility.

```text
same DNP3 event and original routed path
        │
        ├── unchanged → sender evidence + independent Ground Truth capture
        │
        └── changed once → gateway ingress mirror for sub_a_l2_lan removed
                              │
                              ├── target mirror-side sensor input absent
                              ├── target collector artifact absent
                              └── target rule output absent
```

## 2. Predeclared event and single fault

| Item | Fixed value |
| --- | --- |
| Host X / Asset Y | `sub_a_ied_02` (`10.1.20.11`) → `cc_scada_master` (`10.1.10.10`) |
| Event | One DNP3/TCP function-5 Direct Operate; link source `1024`, destination `1`; TCP `20000` |
| Sender command | `dnp3_zone_attack.py --target-ip 10.1.10.10 --target-port 20000 --function-code 5 --repeat 1` |
| Normal observation condition | The generated gateway configuration mirrors ingress traffic from `sub_a_l2_lan` to `mirror_link`. |
| Injected fault | After the range has started, resolve the unique `wan_router` interface carrying `10.1.20.254/24` and remove **only its ingress qdisc** with `tc qdisc del dev <resolved-interface> ingress`. Do not alter routing, IP forwarding, the mirror-link egress rewrite, any other source-segment ingress qdisc, or any container service. |
| Expected missing stage | Target-event **sensor input** on `tap_observer:eth0` is absent. Consequently, no target collector document or target rule-output document should be produced after their bounded settle intervals. |
| Independent Ground Truth | Sender record plus an original-path capture on the same pre-trigger-resolved `wan_router` interface. This capture is local ingress capture and remains independent of the removed mirror action. |

The fault is deliberately scoped to the `sub_a_l2_lan` ingress mirror. It does not stop `log_structurer`, Elasticsearch, `zone_detector`, `tap_observer`, the gateway, or the DNP3 endpoints. It also leaves the independent original path intact: deleting an ingress `tc` qdisc removes the mirror filter but does not remove normal packet forwarding.

## 3. Required nontriviality checks

Before the DNP3 trigger, preserve all of the following after fault injection:

1. `docker compose ps` shows the gateway, `tap_observer`, `log_structurer`, Elasticsearch, and `zone_detector` running.
2. `tc filter show dev <resolved-interface> parent ffff:` shows no remaining target-segment mirror filter, while one unrelated observed gateway interface still has a `mirred egress mirror` filter.
3. Elasticsearch accepts a health/count query and `zone_detector` remains running.
4. The sensor capture includes at least one unrelated frame during the capture window, or the run is marked `Unresolved`; an empty sensor capture cannot distinguish a target-specific observation failure from a failed capture process.

The unrelated frame is a health observation only. It must not be substituted for target-event sensor input.

## 4. Evidence and decision rules

| Stage | Required preserved evidence | Expected decision for a successful fault probe |
| --- | --- | --- |
| Ground Truth | Sender output and original-path pcap match the predeclared request. | `Pass` |
| Sensor input | `tap_observer:eth0` pcap is running and contains unrelated traffic, but contains no target tuple/function-5 request during the bounded window. | `Fail` for target-event arrival |
| Collector output | Preserved actual-schema query returns zero target documents after the bounded settle interval. | `Fail` for target-event output |
| Rule output | Preserved query returns zero matching `signal-1-zone-violation` documents after the bounded settle interval. | `Fail` for target-event output |
| Platform/nontriviality | Service health and an unrelated mirror filter/traffic remain observable. | `Pass` |

Wait at least 15 seconds after the trigger before final collector and rule queries. Preserve explicit zero-result responses; do not infer absence from an omitted query. If Ground Truth fails, if a required service is unavailable, if an unrelated mirror filter cannot be demonstrated, or if the sensor capture has no unrelated frame, record `Fail`, `Unresolved`, or `Invalid` as appropriate rather than promoting the run to a fault-feasibility pass.

## 5. Static correspondence boundary

The prospective Range C expression is not implemented or validated in this step. Its intended semantic contradiction is:

```text
Study/manifest promises that sub_a_l2_lan DNP3 traffic is observable
    +
instrumentation excludes sub_a_l2_lan from mirroring
    =
Observability Contract violation
```

At the pinned baseline, `instrumentation.exclude` is a valid opt-out mechanism and there is no Study 01 Observability Contract validator that knows the promised DNP3 event. Step 5 must therefore determine whether this requires a generic K4 capability. This Step 4 runtime probe must not be represented as a baseline `validate` rejection.
