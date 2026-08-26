# Study 01 — K3 Freeze Decision Table

**Status:** Pre-freeze review record  
**Scope:** Conditionally selected C2 DNP3 scenario  
**Decision rule:** `Frozen` means ready to enter the K3 Protocol Freeze. `Must resolve before freeze` blocks the freeze. `Deferred by design` is intentionally unavailable until a later, versioned dependency exists.

## 1. Freeze decisions

Before the table, **uniquely correlatable** has the following frozen meaning: Collector evidence retains every hit matching the complete frozen selector; it never requires exactly one document. A Rule pass occurs when `source_dnp3_doc_id` references any member of that retained matching-hit set. The term therefore identifies the retained relationship between stages, not a cardinality claim about Collector documents.

| Item | Proposed freeze content | State | Basis / remaining action |
| --- | --- | --- | --- |
| Event | One DNP3 Direct Operate request, application function `5`, link source `1024`, destination `1`. | Frozen | C2 Steps 1–4 used this semantic event. |
| Host X / Asset Y | `sub_a_ied_02` (`10.1.20.11`) → `cc_scada_master` (`10.1.10.10:20000`). | Frozen | C2 candidate evidence. |
| Event count | One trigger event per run. | Frozen | Study 01 evaluates result validity, not delivery rate or detection rate. |
| Retry | A retry is a new run ID; it never extends or overwrites the original run. | Frozen | Retained invalid C2 Step 2 run establishes the precedent. |
| Ground Truth | Sender record plus independent original-path pcap at the gateway interface resolved by `10.1.20.254/24`. | Frozen | C2 Steps 1–4. |
| Sensor stage | `tap_observer` / `mirror_link` pcap of the source request; never used as Ground Truth. | Frozen | C2 Steps 2–4. |
| Collector stage | At least one uniquely correlatable structured DNP3 artifact; preserve every matching hit. | Frozen | The study proves arrival, not exactly-once collection. |
| Rule stage | `signal-1-zone-violation` positive-control output correlated by `source_dnp3_doc_id` to the retained collector document. | Frozen | C2 Step 3 and its replication. |
| Range B fault | Delete only the source-segment ingress mirror qdisc on the runtime-resolved `sub_a_l2_lan` gateway interface. | Frozen | C2 Step 4. |
| Range C contradiction | Contract requires `sub_a_l2_lan` observation while instrumentation excludes that segment. | Frozen | C2 Step 5. |
| Query selectors | Field-level selectors and run time window in §3. | Frozen | Derived from preserved C2 actual-schema queries. |
| Settle bound | Wait **15 seconds** after the trigger before classifying target collector/rule absence. | Frozen | Predefined operational wait bound: existing C2 Step 3 procedure and three 5-second rule-poll periods. It is subject to the Pilot amendment triggers in §2 and is not a statistical latency estimate. |
| K4 validator behavior | Generic valid contract → ACCEPT; required-but-unobserved or undefined segment → REJECT; criteria in §4. | Frozen | Must govern K4 implementation before it exists. |
| K4 genericity | No DNP3 field, IP address, `signal-1-zone-violation`, or Study 01 scorer dependency. | Frozen | Amenonuboco/Kakuriyo responsibility boundary. |
| K4 release/commit | Exact release/tag/commit and validator output format. | Deferred by design | Record in dependency amendment before Pilot; no future value is invented now. |
| Final image inventory | All semantically relevant selected-scenario images with tags/digests or local IDs and build provenance. | Frozen | [C2 image inventory](./c2-dnp3-image-inventory.md) records inspected pulled-image digests, actual candidate local-build IDs, and the per-run image capture rule. K4-specific values remain deferred. |
| Local DNP3 build identity | Freeze build inputs/provenance; preserve each run's actual local image ID and assess any identity difference. | Frozen | Build-input / provenance freeze model; no mutable-tag-only equivalence or bit-identical build claim. |
| Canonical sender procedure | Version-controlled script path, reproducible container/worktree placement and invocation, expected sender-record format, and cleanup procedure. | Frozen | [Canonical sender procedure](./c2-dnp3-sender-procedure.md) fixes the Kakuriyo asset, baseline provenance, `docker cp` placement, invocation, predicate, failure retention, and range-level cleanup. |
| Generated-manifest procedure | Exact Range A/B/C source/derivation paths and cleanup command. | Frozen | [Range derivation and cleanup](./c2-dnp3-range-derivation.md) fixes the common base, generated paths, IP-based Range B fault preparation, Range C static derivation, hashing, and carry-over prevention. |

## 2. Settle-bound evidence and limitation

The two C2 Step 3 runs provide source-event timestamps, collector frame timestamps, and rule documents whose stored `@timestamp` equals the event timestamp. They do **not** preserve an independent rule-poll completion timestamp. The observed packet-event offsets from sender start were approximately 645 ms (`run-c2-step3-20260823-001`) and 600 ms (`run-c2-step3-20260823-002`), but those values are not end-to-end ingestion or rule-evaluation latency measurements.

The 15-second bound is therefore frozen as a predefined operational waiting budget already used by the candidate procedure: the zone detector states that it polls every 5 seconds, and the budget spans three poll periods before an explicit zero-result query. Study 01 will not describe this value as a measured latency percentile, maximum, or statistically validated bound.

**Pilot amendment triggers:** Before Main Experiment, create an amendment and re-freeze the affected protocol condition if (a) a normal Range A run cannot obtain stable rule output within 15 seconds, or (b) platform delay leaves the result unclassifiable at 15 seconds. A later change to this bound is not permitted silently.

## 3. Frozen query and correlation selectors

For every Range A/B run, record `T0` immediately before the sender trigger in UTC and query the event window `[T0 - 5 seconds, T0 + 15 seconds]`. The five seconds before `T0` are a fixed pre-trigger guard/background window, not a clock-skew measurement or latency allowance. Event identity is determined by the frozen tuple/function/link-address selector; preserve raw responses for all matching hits.

| Stage | Required selector / correlation |
| --- | --- |
| Ground Truth | Sender record plus original-path pcap: source `10.1.20.11`, destination `10.1.10.10`, TCP destination port `20000`, DNP3 application function `5`, DNP3 link source `1024`, link destination `1`, and the event window. The TCP source port is recorded but not fixed. |
| Sensor | Same tuple/function/link-address constraints in the mirror-side pcap, with the event window. |
| Collector | `layers.ip.ip_ip_src=10.1.20.11`, `layers.ip.ip_ip_dst=10.1.10.10`, `layers.tcp.tcp_tcp_dstport=20000`, `layers.dnp3.dnp3_dnp3_al_func=5`, `layers.dnp3.dnp3_dnp3_src=1024`, `layers.dnp3.dnp3_dnp3_dst=1`, and `layers.frame.frame_frame_time` in the event window. Pass requires one or more hits matching this entire frozen selector; retain the complete hit set. |
| Rule | `signal=signal-1-zone-violation`, `src_ip=10.1.20.11`, `dst_ip=10.1.10.10`, `@timestamp` in the event window, and `source_dnp3_doc_id` equal to any member of the accepted collector-hit set. |

Multiple matching collector documents do not fail the criterion and may not be reduced to a post hoc chosen document. If the actual schema no longer exposes a listed field under the version-pinned platform, do not silently weaken the selector. Record an amendment and determine whether affected evidence must be rerun.

## 4. K4 black-box acceptance criteria

K4 is accepted for Study 01 only when the following tests pass against its version-pinned Amenonuboco release. These are platform acceptance tests, not Study 01 results.

| ID | Input condition | Required outcome |
| --- | --- | --- |
| K4-AC-01 | A contract requires a declared segment that is present in the computed observed-segment set. | `validate` accepts the manifest. |
| K4-AC-02 | A contract requires a declared segment that is excluded from the computed observed-segment set. | `validate` rejects before provisioning and identifies the contract requirement and segment. |
| K4-AC-03 | A contract requires an undefined segment. | `validate` rejects before provisioning and identifies the undefined requirement. |
| K4-AC-04a | The K4 schema/API accepts generic required-segment contract input without requiring a DNP3-specific field. | Pass only if no DNP3-specific input is required. |
| K4-AC-04b | AC-01 through AC-03 behavior is exercised with generic segment names and generic fixtures. | Pass only if the equivalent accept/reject outcomes occur. |
| K4-AC-04c | K4 implementation and tests are inspected for study-specific coupling. | Pass only if they contain no Study 01 identifier, DNP3 address, `signal-1-zone-violation`, or Study scorer dependency. |

**K4-AC-04 passes only when AC-04a, AC-04b, and AC-04c all pass.** AC-01 through AC-03 passing while AC-04 is unresolved or fails is not an intermediate acceptance: the K4 dependency remains unmet, C2 stays conditionally selected, and Pilot remains blocked. If AC-04 cannot pass, apply the existing [Step 6 comparison](../analysis/candidate-evaluations/comparison.md) rule and transition to **no selection** rather than introducing a Study-specific validator.

K4-AC-02 is the future validation of the C2 Range C negative manifest. Range C represents the same **segment-level observation precondition/blind-spot condition** that affects the selected event in Range B; it does not statically validate the concrete DNP3 event. Existing v0.12.0 acceptance remains the preserved baseline behavior and is not retroactively changed.

## 5. Review exit condition

K3 Protocol Freeze may proceed only after this table, the scenario draft, invariant draft, scoring draft, evidence schema, experiment protocol, sender procedure, image inventory, derivation/cleanup procedure, and scenario-selection record have passed a cross-document consistency review. The deferred K4 release/commit is permitted only because Pilot and Main Experiment remain blocked until it is version-pinned through the dependency-change process.
