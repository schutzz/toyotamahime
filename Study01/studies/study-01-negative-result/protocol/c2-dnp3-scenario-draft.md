# Study 01 — C2 DNP3 Scenario Draft for K3 Protocol Freeze

**Status:** Pre-freeze draft — derived from the conditional Step 6 selection; not an executable Study 01 protocol  
**Selection basis:** [Step 6 candidate comparison](../analysis/candidate-evaluations/comparison.md)  
**Amenonuboco baseline:** `v0.12.0`, commit `78fc17746b5d663fafec9dffe563d79fe9ea02b7`

## 1. Scope and decision boundary

This document turns the conditionally selected C2 candidate into a reviewable draft of one coherent Range A/B/C scenario. It does not freeze experimental conditions, supply the missing K4 capability, or establish any Study 01 result.

The candidate is usable only if K4 delivers a separately version-pinned **generic** Observability Contract capability. The capability must not encode the DNP3 protocol, the source/destination addresses, the `signal-1-zone-violation` rule, or Study 01 classification logic.

## 2. Shared semantic event

| Field | Draft value |
| --- | --- |
| Host X | `sub_a_ied_02` (`10.1.20.11`) |
| Asset Y | `cc_scada_master` (`10.1.10.10:20000`) |
| Source segment | `sub_a_l2_lan` |
| Destination segment | `cc_lan` |
| Protocol | DNP3 over TCP/20000 |
| Event | One Direct Operate request per run, DNP3 application function `5`, link source `1024`, link destination `1` |
| Sender predicate | The predeclared sender command exits successfully and records the target tuple/function. |
| Ground Truth | Sender record plus an original-path gateway capture on the runtime-resolved interface holding `10.1.20.254/24`; `mirror_link` capture is never Ground Truth. |

The [canonical sender procedure](./c2-dnp3-sender-procedure.md), [selected-scenario image inventory](./c2-dnp3-image-inventory.md), and [Range derivation and cleanup](./c2-dnp3-range-derivation.md) are now pre-freeze execution records. Per-run runtime environment values remain mandatory evidence rather than pre-invented values. The trigger count, retry rule, settle bound, selectors, and K4 acceptance criteria are canonical in the [Freeze Decision Table](./freeze-decision-table.md).

## 3. Range A — valid observable control

Range A uses the shared event without a deliberate observation fault.

| Evidence stage | Draft required observation |
| --- | --- |
| Ground Truth | Sender evidence and original-path pcap correlate on the declared tuple and DNP3 fields. |
| Sensor input | `tap_observer` on `mirror_link` captures the source request. |
| Collector output | A structured DNP3 document matches the declared source, destination, function, and link addresses. |
| Rule output | The existing `signal-1-zone-violation` positive-control output references the preserved structured DNP3 input document. |

The positive-control alert demonstrates an intact evaluated chain. It is not itself a general claim about DNP3 detection performance and does not predetermine the final Study 01 claim beyond the stated event.

## 4. Range B — runtime observation fault

Range B preserves the same shared event and changes only one runtime observation-path condition: delete the ingress `tc` qdisc on the runtime-resolved gateway interface for `sub_a_l2_lan`.

The fault is accepted only if all of the following are demonstrated in the Pilot and then frozen for the Main Experiment:

1. the original-path Ground Truth still passes;
2. the target source request is absent at the specified mirror-side sensor stage;
3. no matching collector document or rule output appears after the predeclared settle interval;
4. Elasticsearch, structurer, detector, an unrelated mirror filter, and unrelated DNP3 traffic remain observable; and
5. cleanup restores the deleted qdisc or discards the range without carrying state into another run.

An alert absence under these conditions is classified through the scoring rule as an **Invalid negative result**, not as evidence that the rule failed to detect an otherwise observable input.

## 5. Range C — static negative manifest

Range C is non-provisioned. It expresses the same **segment-level observation precondition/blind-spot condition** as Range B; it does not statically validate the concrete DNP3 Direct Operate event:

```text
observation contract requires: sub_a_l2_lan → mirror_link
instrumentation declaration: exclude sub_a_l2_lan
```

The pinned baseline accepts this contradiction; that acceptance is preserved as candidate evidence, not treated as validator success. K4 must define the generic contract representation and reject a required segment absent from `instrumentation.observed_segments()`.

The final K4 validation error code, message text, and remediation wording are unresolved until the platform interface is designed. The Protocol Freeze must identify their acceptance semantics without fabricating an implementation-specific string.

## 6. Invariants and scoring dependencies

The [Invariant Specification Draft](./invariant-specification.md) and [Scoring and Classification Draft](./scoring.md) define the required conditions and result classifications for this scenario. The [Evidence Schema Draft](./evidence-schema.md) defines what must be retained to support a later result. The [Freeze Decision Table](./freeze-decision-table.md) records which values are frozen, blocking, or deferred by design.

## 7. Freeze prerequisites

Before this draft can become the selected Study 01 protocol, the following must be reviewed and frozen together:

- canonical sender procedure and cleanup rules;
- Range A/B/C reproducible derivation and cleanup procedure;
- selected-scenario image inventory and per-run image-digest capture rule;
- evidence paths and hashing requirements;
- an amendment log initialized at the freeze point.

The K4 release/commit is deferred by design until the generic capability exists. It must be version-pinned through the dependency-change procedure before Pilot, not invented as a Protocol Freeze value. The candidate-selection evidence remains pre-freeze and is not retroactively rewritten by this future protocol.
