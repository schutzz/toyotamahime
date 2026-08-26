# Study 01 — K3 Cross-Document Consistency Review

**Review date:** 2026-08-23  
**Review state:** Pre-freeze  
**Scope:** Selected C2 DNP3 scenario and its K3 protocol materials  
**Method:** Compare the canonical selection, scenario, invariant, scoring, evidence, and freeze-decision records field by field. This review does not create experimental evidence or itself freeze the protocol.

## 1. Documents reviewed

- [Experiment Protocol](./experiment-protocol.md)
- [Scenario Selection Record](./scenario-selection.md)
- [C2 Scenario Draft](./c2-dnp3-scenario-draft.md)
- [Invariant Specification Draft](./invariant-specification.md)
- [Scoring and Classification Draft](./scoring.md)
- [Evidence Schema Draft](./evidence-schema.md)
- [Freeze Decision Table](./freeze-decision-table.md)
- [Canonical Sender Procedure](./c2-dnp3-sender-procedure.md)
- [C2 DNP3 Selected-Scenario Image Inventory](./c2-dnp3-image-inventory.md)
- [C2 Range Derivation and Cleanup](./c2-dnp3-range-derivation.md)
- [Dependency Freeze Record](./dependencies.md)
- [Amendment Log](./amendments.md)
- [Project Roadmap](../../../docs/roadmap.md)
- [Step 6 Candidate Comparison](../analysis/candidate-evaluations/comparison.md)

## 2. Consistency checklist

| Check | Canonical value | Result |
| --- | --- | --- |
| Selected candidate | C2 DNP3, conditional on K4 generic capability. | Pass |
| Host X / Asset Y | `sub_a_ied_02` (`10.1.20.11`) → `cc_scada_master` (`10.1.10.10:20000`). | Pass |
| Event | One Direct Operate request **per run**; DNP3 application function `5`; link `1024 → 1`. | Pass |
| Ground Truth | Sender record plus original-path capture at the interface resolved by `10.1.20.254/24`; mirror capture excluded from GT. | Pass |
| Sensor | Source request at `tap_observer` on `mirror_link`. | Pass |
| Collector | At least one uniquely correlatable structured DNP3 artifact; all matching hits retained. | Pass |
| Rule | `signal-1-zone-violation`, correlated through `source_dnp3_doc_id`. | Pass |
| Range B fault | Delete only the runtime-resolved ingress mirror qdisc for `sub_a_l2_lan`. | Pass |
| Range C contradiction | Required observation of `sub_a_l2_lan` plus instrumentation exclusion of the same segment. | Pass |
| Result classification | Range A: Valid detection result; Range B: Invalid negative result only when GT passes and runtime contract fails; Range C: static `REJECT` after K4. | Pass |
| Settle handling | 15-second operational bound, explicitly not a measured latency bound. | Pass |
| Query/correlation fields | Source/destination, TCP/20000, function `5`, link `1024 → 1`, time window, and rule-to-collector identifier correlation. | Pass |
| K4 acceptance | Valid required segment accepts; excluded/undefined required segment rejects; genericity excludes DNP3/IP/rule/scorer dependencies. | Pass |
| K4 version pin | Deferred by design until a generic K4 release exists; must be recorded before Pilot. | Pass |
| Evidence-schema internal consistency | Pilot/Main runtime paths are separate; non-provisioned Range C exists only under static validation and has no runtime artifact tree. | Pass |
| Settle wording | 15 seconds is a predefined operational wait bound with Pilot amendment triggers, not a measured sufficiency/latency claim. | Pass |
| Selector multi-hit rule | Collector retains the entire frozen-selector hit set; Rule Pass correlates to any member through `source_dnp3_doc_id`. | Pass |
| T0 window definition | `T0 - 5 seconds` is a pre-trigger guard/background window, not a clock-skew or latency measurement. | Pass |
| Range C terminology | Range C represents the segment-level observation precondition/blind spot, not static validation of the concrete DNP3 event. | Pass |
| K4 AC-04 genericity | API, generic-fixture behavior, and source/test coupling checks must all pass; AC-01–03 alone cannot satisfy K4. | Pass |
| Pilot entry K4 gate | K4 release/pin, acceptance, amendment/dependency records, inventory, and no unresolved K3 blocker are all required before Pilot. | Pass |
| Initial K4 pin procedure | Amendment records the research decision/rerun category; dependencies records exact versions/digests/provenance. | Pass |
| Rerun rule | REQUIRED / ASSESS-PARTIAL / NOT REQUIRED categories are defined in `amendments.md`. | Pass |
| Sender blocker wording | Blocker is canonical script/path/invocation/record/cleanup reproducibility, not an unknown event semantic. | Pass |
| Runtime evidence directory names | Range A/B use `contract-output/`; Range C alone uses `static-validations/range-c/<validation-id>/validator-output/`. | Pass |
| Pilot/Main/static separation | Pilot and Main runtime evidence trees are separate, and Range C has only static artifacts. | Pass |
| Canonical sender path | Version-controlled Kakuriyo asset is copied to a Compose-resolved `sub_a_ied_02` container; invocation, success predicate, failure retention, and range cleanup agree with scenario/scoring. | Pass |
| Selected-scenario images | Semantically relevant roles, immutable pulled digests or actual local build IDs, provenance, and per-run capture rule are recorded; K4 values are excluded and deferred. | Pass |
| Local-build reproducibility boundary | K3 freezes DNP3 build inputs/provenance, while every Pilot/Main run records actual image identity; mutable tag equality and bit-identical local-build claims are prohibited. Identity differences follow dependency/equivalence and rerun rules. | Pass |
| Range derivation | A/B use the same unmodified base manifest and fresh Compose project; B injects only the IP-resolved ingress-qdisc fault; C is a non-provisioned disposable static derivation. | Pass |
| Cleanup | A/B evidence is exported/hashed before `down -v --remove-orphans`; C removes only static temporary artifacts. | Pass |
| Cleanup policy boundary | Candidate validation may retain volumes for exploratory/diagnostic investigation; Pilot/Main removes volumes after evidence export/hashing to prevent state carry-over. Candidate evidence is not retroactively reinterpreted. | Pass |
| Range C patch limitation | Path retargeting is a known fixed-patch maintenance limitation, successfully checked against the pinned baseline; it does not change Range C semantics or add a K3 blocker. | Pass |
| Candidate evidence preservation | Existing candidate and invalid-run evidence is linked as historical selection evidence; no candidate artifact or interpretation is rewritten by the Pilot/Main procedure. | Pass |
| Canonical-state ownership | Sender, image, derivation, evidence, dependency, amendment, and roadmap records refer to one canonical source each; no duplicate dynamic state is introduced. | Pass |

## 3. Deliberate non-values

The following are deliberately unresolved, not missing conditions:

| Item | Why it is unresolved | Gate |
| --- | --- | --- |
| K4 release/tag/commit and output syntax | The generic capability does not yet exist. | Must be dependency-pinned before Pilot. |
| K4-specific image/build identifiers | Cannot be observed before K4 implementation. | Must be recorded with the K4 dependency change. |

## 4. Former freeze blockers resolved in this review

1. **Canonical sender procedure:** resolved by `c2-dnp3-sender-procedure.md`, with a version-controlled asset, baseline provenance, Compose-resolved placement, invocation, sender predicate, retained failure handling, and cleanup link.
2. **Selected-scenario image inventory:** resolved by `c2-dnp3-image-inventory.md`, including immutable pulled-image digests, actual candidate local-build IDs, provenance, and mandatory per-run image capture.
3. **Range A/B/C derivation and cleanup:** resolved by `c2-dnp3-range-derivation.md`, including common-base derivation, only one B fault, non-provisioned C, hashes, and cleanup.

## 5. Review decision

**Pass — K3 final pre-freeze materials are internally consistent.** No contradiction was found among the reviewed scenario semantics, evidence-chain definitions, scoring names, Range B/C relationship, K4 genericity boundary, sender execution, image provenance, local-build reproducibility boundary, or derivation/cleanup procedures. No unresolved K3 freeze blocker remains.

This review makes K3 Protocol Freeze ready for a separate, explicit review/commit/tag. It does not implement or pin K4, start a Pilot, run the Main Experiment, or convert the conditional C2 selection into an unconditional selection.
