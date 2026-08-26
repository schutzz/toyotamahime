# Study 01 — Invariant Specification Draft

**Status:** Pre-freeze draft — no validator implementation or final acceptance claim  
**Applies to:** Conditionally selected C2 DNP3 scenario  
**Related:** [C2 scenario draft](./c2-dnp3-scenario-draft.md), [Step 5 static correspondence](./c2-dnp3-step5-range-c-static-correspondence.md), [Freeze Decision Table](./freeze-decision-table.md)

## 1. Principle

Configuration correctness does not establish observation correctness. Static invariants identify contradictions that can be rejected before deployment; runtime invariants establish whether the selected event actually traversed the evidence chain in a particular run.

## 2. Contract subject

`C2-OBS-01` is the draft contract identifier for the selected C2 event:

```text
required source segment: sub_a_l2_lan
required mirror destination: mirror_link
required event path: sub_a_ied_02 → cc_scada_master
```

The identifier is Study-specific evidence vocabulary. K4 must expose a generic platform representation rather than adopting this identifier or any DNP3-specific field as platform behavior.

## 3. Static invariants

| ID | Required property | Evidence/decision basis | Range C expectation |
| --- | --- | --- | --- |
| S-OBS-01 | The contract-required segment is a declared topology segment. | Manifest topology. | Reject if undefined. |
| S-OBS-02 | A mirror target is declared and is a valid topology segment. | Instrumentation declaration and existing baseline checks. | Reject if absent or unresolved. |
| S-OBS-03 | A route/gateway attachment exists for the required observed segment and mirror target. | Generated topology/mirroring prerequisites. | Reject if unavailable to generate. |
| S-OBS-04 | A collector destination/structurer path is declared for the mirror target. | Collector and instrumentation declarations. | Reject if absent for a contract that requires structured output. |
| S-OBS-05 | Every contract-required segment belongs to the computed observed-segment set. | Generic K4 comparison against `instrumentation.observed_segments()`. | Reject when `sub_a_l2_lan` is excluded. |

S-OBS-05 is the identified K4 dependency. The v0.12.0 baseline does not perform this comparison. Existing baseline structural checks must not be overstated as a complete Observability Contract validator.

## 4. Runtime invariants

| ID | Required property | Required evidence |
| --- | --- | --- |
| R-OBS-01 | The shared DNP3 event exists independently of the evaluated observation path. | Sender record plus original-path gateway pcap. |
| R-OBS-02 | The target source request arrives at the specified mirror-side sensor stage. | Sensor pcap on `tap_observer` with declared tuple/function. |
| R-OBS-03 | The collector emits at least one uniquely correlatable matching structured DNP3 artifact; every matching hit is retained. | Preserved collector query/output linked to the source request and the frozen selector set. |
| R-OBS-04 | The rule/analytic stage emits a preserved result tied to its collector input. | Rule output and input-document correlation. |
| R-OBS-05 | The observation platform remains non-trivially available during a Range B fault. | Service health plus unrelated mirror traffic/filter and nonempty applicable collector evidence. |

Range A requires R-OBS-01 through R-OBS-04. Range B is designed to retain R-OBS-01 while R-OBS-02 through R-OBS-04 fail for the target source request and R-OBS-05 passes. Range C is evaluated only against the static invariants and is never provisioned: it expresses the same **segment-level observation precondition/blind spot** as Range B, not the concrete DNP3 event itself.

## 5. Boundary

This draft does not claim that the listed invariants prove all possible observation paths, all packet loss causes, or all protocol semantics. In particular, static satisfaction never substitutes for runtime evidence, and runtime evidence does not turn an unsupported static contradiction into a deployment-time validator result.

The identifiers, conditions, accepted evidence, and K4 error semantics are governed by the Freeze Decision Table. K4 must still be implemented and version-pinned before Pilot evidence is treated as Study 01 evidence.
