# Study 01 Amendment Log

**Status:** Operative (K3 Protocol Freeze complete: `study-01-protocol-v1.0` / `9d57d1e63d6cf16dcc37e8f60d560d30da5f4835`)  
**Current entries:** 3

## Purpose

After the K3 Protocol Freeze, any change to a research-significant condition is recorded here before the changed condition is used as authoritative. This includes changes to the selected event, Range A/B/C conditions, invariants, scoring, evidence requirements, K4 dependency, or claim boundary.

## Required entry format

| Field | Required content |
| --- | --- |
| Amendment ID and date | Unique identifier and date/timezone |
| Prior frozen state | Commit/tag and affected canonical files |
| Change and rationale | What changes and why |
| Affected evidence/claims | What prior result or claim may be affected |
| Rerun decision | Required / not required, with justification |
| New authoritative state | Commit/tag after the amendment |

Pre-freeze drafting and candidate selection are recorded in their ordinary commit history, not retrospectively represented as amendments. This log becomes operative at the Protocol Freeze.

## Initial K4 dependency pin

The first K4 release/commit pin is an amendment/dependency-change event even though its prior value at Protocol Freeze is **`Deferred by design / not yet available`**.

- `amendments.md` records the research decision: why K4 is introduced, the prior deferred state, affected protocol/claims, K4 acceptance outcome, and rerun category.
- `dependencies.md` is the authoritative record of the operational value: exact release/tag/commit, validator output format, affected image tags/digests, and platform provenance.

The two records have different roles and may link to each other; neither substitutes for the other.

## Amendment log

### Amendment 003 — K6 R-OBS-05 Collector correlation query envelope

| Field | Content |
| --- | --- |
| Amendment ID and date | `AMEND-003`, 2026-08-25 (JST) |
| Prior frozen state | K3 Protocol Freeze plus AMEND-002 required Range B R-OBS-05 service health, unrelated mirror traffic/filter, and nonempty applicable Collector evidence, but did not fix an exact unrelated-flow Collector query or pcap/document timestamp-correlation bound. The accepted K6 plan initially required same-window direction/tuple/function/link correlation without an executable numeric boundary. |
| Change and rationale | Before any Main evidence, add the prospective exact query/evidence envelope in `k6-r-obs-05-collector-query-contract.md`: actual mapped fields, bidirectional unrelated DNP3 selector, complete-hit fail-closed rule, retained query/response/correlation record, and exact integer-nanosecond `abs(delta) <= 1,000,000 ns` pcap/document bound. The 1 ms value is precommitted from K5-observed capture/document deltas (`0.002439 ms` maximum) and stored precision, not chosen from K6 results. It operationalizes the existing same-flow correlation requirement but is recorded as an amendment because it creates a prospective evidence-acceptance boundary. |
| Affected evidence/claims | K6 Main evidence count is zero. K5 Pilot and candidate records are historical apparatus/candidate evidence; this amendment is not applied retroactively, does not rescore them, and does not promote them to Main evidence. No frozen target selector, event, Range B fault, window, R-OBS-05 purpose, scoring precedence, or classification changes. |
| Rerun decision | **Rerun ASSESS / PARTIAL.** Assessment found zero K6 Main runs or artifacts to re-evaluate or partially rerun. Therefore the concrete rerun set is empty. K5/candidate records remain unchanged and outside the prospective K6 contract. This is not recategorized as `Rerun NOT REQUIRED`; the ASSESS / PARTIAL category is retained because query and evidence formats and an acceptance boundary were added. |
| New authoritative state | The repository commit containing AMEND-003, `protocol/k6-r-obs-05-collector-query-contract.md`, and its accepted targeted independent review. These govern prospective K6 Range B execution only. |

### Amendment 002 — K5 Phase 0 scoring-semantics closure

| Field | Content |
| --- | --- |
| Amendment ID and date | `AMEND-002`, 2026-08-24 (JST) |
| Prior frozen state | K3 Protocol Freeze (`study-01-protocol-v1.0` / `9d57d1e63d6cf16dcc37e8f60d560d30da5f4835`), in particular `scoring.md`, `freeze-decision-table.md`, `invariant-specification.md`, `evidence-schema.md`, and the Range A/B/C procedures. |
| Change and rationale | An independent K5 Phase 0 cross-review found six scorer-totality cases. **Part A — clarifications of existing frozen semantics:** (1) apply classification precedence `Invalid run` → `Inconclusive experiment` → `Valid detection result` / `Invalid negative result`; for Range A/B, “mandatory stage” in the `Inconclusive experiment` row means the four existing evidence-chain stages Ground Truth, Sensor input, Collector output, and Rule output. Runtime contract remains the existing required condition in the R1/R2 rows; this clarification does not create a fifth mandatory stage. R1 and R2 are mutually exclusive because they require Runtime contract `Pass` and `Fail`, respectively. (3) Range C is static validation only and emits no Experiment classification; it retains only its static-contract / validator result. (5) an Alert that cannot correlate, by the frozen `source_dnp3_doc_id` rule, to any member of the retained accepted Collector-hit set is “evidence cannot be correlated” and therefore `Inconclusive experiment`. **Part B — pre-Pilot semantic additions:** the K3-frozen text did not decide (2) `Rule output = Error`, (4) Range B `R-OBS-05 Fail`, or (6) Range A sensor liveness. Before any Pilot/Main result was obtained, the researcher decides: (2) `Rule output = Error` → `Inconclusive experiment`, unless an independently satisfied Invalid-run condition takes precedence; Error alone is not converted to Invalid. (4) Range B `R-OBS-05 Fail` → Runtime contract `Unresolved` → `Inconclusive experiment`; it must not be `Invalid negative result`. (6) apply the Range B empty-capture liveness rule to Range A: a completely empty sensor capture without the prescribed liveness evidence → Sensor input `Unresolved` → `Inconclusive experiment`. |
| Affected evidence/claims | No Pilot or Main Experiment run exists. No result-bearing evidence has been obtained under these cases. Candidate-evaluation and K4 platform-acceptance evidence are historical records and are not rescored or changed by this amendment. |
| Rerun decision | **Rerun NOT REQUIRED.** Pilot run count is 0 and Main Experiment run count is 0. This amendment is recorded before any result-bearing Pilot/Main evidence is obtained; there is therefore no such evidence to invalidate or rerun. |
| New authoritative state | The repository commit containing `AMEND-002`, together with [the K5 Phase 0 cross-review record](./scoring-semantics-cross-review.md). Protocol documents plus this amendment remain normative; a future executable scorer is a transcription, not a source of semantics. |

### Amendment 001 — Initial K4 dependency pin

| Field | Content |
| --- | --- |
| Amendment ID and date | `AMEND-001`, 2026-08-24 (JST/session-local; recorded in UTC as `2026-08-23T22:36:34Z` in the linked K4-8 evidence) |
| Prior frozen state | K3 Protocol Freeze (`study-01-protocol-v1.0` / `9d57d1e63d6cf16dcc37e8f60d560d30da5f4835`) recorded the K4 dependency as **`Deferred by design / not yet available`** in `dependencies.md` §6 and `c2-dnp3-image-inventory.md` §3, because the generic Observability Contract capability did not yet exist. No Kakuriyo canonical file previously named a concrete K4 release/tag/commit. |
| Change and rationale | The generic Observability Contract capability was implemented in an isolated Amenonuboco worktree (K4-0–K4-4), independently acceptance-verified (K4-5), regression- and genericity-reviewed (K4-6), merged to Amenonuboco canonical `main` and released as tag `v0.13.0` / commit `0378f8a32701b481e030f3db3d5f66ea471a4675` (K4-7), and re-verified against that pinned release plus a static Range C integration check (K4-8). This amendment records the transition from "deferred" to "pinned" now that the capability exists, has passed every frozen K4-AC, and has a durable released reference. |
| Affected evidence/claims | None. No Pilot or Main Experiment run has occurred under any K4 state — Pilot has been blocked since K3 Protocol Freeze pending exactly this capability. Candidate-evaluation evidence (C1/C2 Steps 1–5) was produced entirely against the Amenonuboco `v0.12.0` baseline without any K4 dependency and is unaffected. The C2 Range C static asset's `observability_contract` declaration shape was corrected from a pre-implementation placeholder (object list) to the schema Amenonuboco actually shipped (`list[str]`); this is a representation correction of an asset that had never been used to support a passed/failed claim, not a change to the frozen semantic condition (`sub_a_l2_lan` required-and-excluded) — see [K4-8 static integration verification](../platform-acceptance/k4-observability-contract/kakuriyo-pin/k4-8-static-integration-verification.md) §2. |
| Rerun decision | **Rerun NOT REQUIRED.** No prior Pilot/Main run exists to invalidate; this is the initial establishment of a previously-deferred dependency, not a change to a dependency already used to produce evidence. The Range C asset correction in §"Affected evidence/claims" also requires no rerun: the corrected asset was never provisioned, never generated a claim, and its only prior use (Step 5, `run-c2-step5-20260823-001`) tested the pre-K4 baseline's *acceptance* behavior, which is unaffected by the shape of a field that baseline does not parse at all. |
| New authoritative state | Amenonuboco `v0.13.0` / commit `0378f8a32701b481e030f3db3d5f66ea471a4675`, recorded in [`dependencies.md` §2.1](./dependencies.md#21-k4-generic-observability-contract-pin). Full K4 gate evidence: [`platform-acceptance/k4-observability-contract/`](../platform-acceptance/k4-observability-contract/). |

## Rerun decision rules

Every amendment must assign one category and state its rationale.

| Category | Required use |
| --- | --- |
| **Rerun REQUIRED** | Selected event semantics, frozen selector, scoring/classification, Range B fault mechanism, Observability Contract/K4 acceptance semantics, or a platform change that affects the meaning of the runtime evidence chain changes. |
| **Rerun ASSESS / PARTIAL** | Evidence format changes, metadata is added, image rebuilds occur while semantic equivalence is claimed, or query/export format changes. Record which runs/artefacts require re-evaluation or partial rerun. |
| **Rerun NOT REQUIRED** | Typo, link, formatting, or explanatory-only correction that does not change research meaning or evidence interpretation. |

An amendment must not use a `NOT REQUIRED` classification merely because rerunning would be inconvenient.
