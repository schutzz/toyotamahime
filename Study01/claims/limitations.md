# K7-7 — Limitations, unexpected results, non-accepted runs, and deviations

This is the complete record of what Study 01 does **not** establish, what went differently than the design assumed, which runs were not accepted, and which deviations and corrections occurred. It is written after all four hypothesis judgments and the [RQ synthesis](./rq-synthesis.md), so that it records the limitations that actually bound the claims rather than the ones anticipated in advance.

Nothing here is a repair. No K6 evidence, result, protocol, or apparatus file is modified by this record, and no retention or apparatus improvement named below is applied to K6 — each is a requirement for future work.

## 1. Limitations that bound what may be claimed

### 1.1 The valid-`No alert` branch was never observed

The single largest limitation, and the one that caps RQ-J1. The accepted Range A rule output was `Alert`; the accepted Range B rule output was `No alert`. K6 produced

```text
Range A:  observation-valid evaluation   + Alert
Range B:  observation-invalid evaluation + No alert
```

and never `observation-valid + No alert`. The discrimination between a valid negative and an invalid negative was therefore **not observed**; it was demonstrated only as a property of the pre-registered scorer, by feeding it a counterfactual input. Every statement about that discrimination must carry the distinction between an observed run and a counterfactual rescoring.

This is a design limitation, not an execution failure: the frozen positive-control event is one the rule is expected to alert on, so no Main run could have produced an observation-valid `No alert`.

### 1.2 Range B's rule-stage zero is not anchored

The Range B rule query is complete in selector and window, was actually run, did not time out, and returned `hits.total {0, eq}` — but nothing in the retained record identifies the index or pattern it searched. `mapping.json` is `{}`, there are no hits so no `_index`, the query body carries no index, and `_shards.total` is `0`. That response shape is equally consistent with *no alert was ever written, so the daily signal index was never created* and with *the query went to a pattern that never existed*.

This is why [H-J1 is Inconclusive](./h-j1-judgment.md). It is **not** a finding that an alert existed: Range B's index-anchored collector query retains zero target documents, so there was no rule input to alert on. What is limited is the claim, not the outcome.

### 1.3 One of everything

Restated from the plan's per-hypothesis limitation blocks, which apply in full:

| Hypothesis | Limitation as fixed before judgment |
| --- | --- |
| H-J1 | one accepted run per range; one frozen event; one frozen fault of one kind (ingress mirror qdisc deletion); one scenario, one platform pin, one host. Negative results arising from other coverage failure modes are untested. R-OBS-05 demonstrates that the platform was still observing an unrelated flow; it does not enumerate every way coverage could fail. |
| H-J2 | a single event of a single function code on a single path; coverage confirmed for that event only; the Rule stage was evaluated as a positive control in Pilot and is not a performance measurement here. |
| H-J3 | exactly one contradiction shape was tested; the validator is a pinned third-party dependency evaluated as a black box against one negative asset; no positive-control asset set was run in K6 to characterise false rejections. |
| H-J4 | one classification instance; the procedure was exercised on one invalid case and one valid case; the byte-identity qualification on rescoring recorded in `K6-MAIN-EXPERIMENT-REPORT.md` §11 applies. |

### 1.4 The classification procedure was authored by this research

H-J4 shows that a pre-registered procedure, applied mechanically, produced `Invalid negative result`. It does **not** show that the distinction the taxonomy encodes is correct. No external standard, second procedure, or independent rater was applied. "正しく区別できるか" in RQ-J1 is therefore unanswered as a question about correctness; only pre-registration and mechanical application were demonstrated.

### 1.5 The Observability Contract's declarative surface is narrower than RQ-J2's wording

At the pin, the entire contract model is:

```python
class ObservabilityContract(BaseModel):
    required_segments: list[str] = Field(min_length=1)
```

RQ-J2 asks about declaring 「通信、sensor、collector、期待するevent」. Three of those four have no declarative surface in the pinned contract, and the Range C negative asset declares exactly one thing: `required_segments: [sub_a_l2_lan]`. RQ-J2 is answerable only for the segment-coverage element.

This is a limitation of the **question** as much as of the answer, and it is the item most directly actionable for follow-on work.

### 1.6 No positive control was run against the validator

K6 ran the validator against one negative asset only. A validator that rejected every manifest would have produced an identical observation. Nothing about selectivity, false rejections, soundness, or completeness is established. H-J3 remains Supported for what it claims — this one contradiction was rejected — but no generalisation follows.

### 1.7 Range C is static and was never provisioned

By design. Range C carries no Ground Truth, sensor, collector, or rule stage and no experiment classification. It bears on RQ-J2 and H-J3 only, never on RQ-J1, H-J1, H-J2, or H-J4. No runtime consequence of the declared contradiction was observed, because nothing was deployed.

### 1.8 No capability-delta was demonstrated

`protocol/c2-dnp3-step5-range-c-static-correspondence.md` §4 contemplates a v0.12.0 baseline that accepts the same asset, against a K4 capability that rejects it. K6 exercised `v0.13.0` only. A before/after comparison is not part of the Main Experiment evidence and is not claimed.

## 2. Retention and apparatus limitations

Each of these is a requirement for future runs. **None is applied to K6 evidence**, and none affects a retained observation or classification.

| # | Limitation | Requirement for future work | First surfaced |
| --- | --- | --- | --- |
| R1 | The rule stage does not retain the index or pattern its query was issued against, so a zero is unanchored. | Retain the searched index or pattern for every query whose zero is load-bearing — as the collector stage already does through `mapping.json`. | [H-J1](./h-j1-judgment.md) |
| R2 | The Range A alert's `source_dnp3_doc_id` is a bare document id, not index-qualified. | Record the source index alongside the id so the reference is self-contained. Here the binding held anyway, by id, millisecond timestamp, and endpoints. | [H-J2](./h-j2-judgment.md) |
| R3 | Range A does not retain the unrelated interface's filter state after the run, so K7-1 reports `unrelated_filter_present_after: null` rather than `true`. Range B retains it. | Retain the same post-run interface state in every range, so the mutation record is symmetric across comparison members. | [K7-1](./README.md) |
| R4 | Range A retains no post-run runtime-contract snapshot; its contract record is timestamped ~45 s before T0. With `fault_commands=0` nothing removed the mirror, and the sensor capture contains the target frame, so the mirror was demonstrably live at T0 — but the "after" state is inferred, not retained. | Capture the contract state after the observation window in every runtime range, not only where a mutation occurred. | [H-J2](./h-j2-judgment.md) |
| R5 | Range A does not retain R-OBS-05. It is not required for Range A — coverage there is established positively by the target event itself — but the asymmetry means the liveness control exists on one side of the comparison only. | Retain the liveness control in both members of a comparison, so its presence is not itself a difference between them. | [H-J2](./h-j2-judgment.md) |
| R6 | The stage-level scorer inputs are hand-transcribed by the operator. Only `procedure_conformance` is machine-enforced against the evidence tree. All eight fields were independently re-derived from committed bytes in K7-5 and agree, so this record is verified — but the apparatus does not itself enforce it. | Derive the scoring input from the evidence tree mechanically, so that classification has no hand-transcription step between evidence and scorer. | [H-J4](./h-j4-judgment.md) |
| R7 | Range C `001` cannot establish its own pre-validation clean state; `versions.json` records only a post-injection `worktree_clean: false`. Provenance was closed by the Gate C review-only reproduction. | Capture `git rev-parse HEAD`, `git status --porcelain`, and `git diff --stat HEAD` **before** any input is placed, as primary output. | [Gate C review](../../../K6-GATE-C-REVIEW.md), restated in [H-J3](./h-j3-judgment.md) |

## 3. Known non-blocking defects

Restated from `K6-MAIN-EXPERIMENT-REPORT.md` §11, unchanged and not fixed in K7.

| Defect | Status |
| --- | --- |
| `scripts/study01_score.py` writes its record with `Path.write_text` rather than the LF-only writer in `scripts/study01/evidence_io.py`, so fresh-clone rescoring reproduces the retained record content-identically but not byte-identically (12 CR bytes). | **Deferred by decision.** Changing shared apparatus between Range B and any later range would introduce an apparatus difference between comparison members. Affects no observation, stage outcome, or classification, and is symmetric across A and B. K7-5 compared parsed records, which are equal. |
| The K5 static validation `k5-range-c-20260824-001` does not verify against committed bytes on a fresh clone: two of its eight manifest entries were hashed as CRLF and normalized to LF on commit. | **Retained unrepaired.** Pilot-era record; not repaired, reinterpreted, or reused. The K6 Range C record closes the same path with an explicit `.gitattributes` pin. |
| `results/main/range-b/.../r-obs-05-correlation.json` stores `delta_ns` as a magnitude while its `comparison` field states the rule as `abs(delta) <= 1000000`; an independent signed recomputation returns the negated value. | Observation only. The tolerance decision is unaffected. |
| Range A and Range B `query.json` differ in JSON key order; parsed as objects with instantiated timestamps normalized they are identical. | Observation only. |

## 4. Unexpected results

Recorded because they were not anticipated by the design, not because they change any outcome.

**4.1 The two most complete non-accepted runs reproduce the accepted classifications exactly.** Range A `001` and Range B `001` are result-bearing: each produced the same classification as its range's accepted run, with a **byte-identical scoring record** (`1c895f06…` for A, `f2d455d4…` for B). Both were nonetheless non-accepted, for committed-byte integrity failure on a fresh clone, and the plan makes them inadmissible. They are not promoted, not cited, and not used to corroborate anything. The observation worth keeping is that the acceptance criterion that rejected them is an *integrity* criterion, not a result criterion — it rejected result-bearing records whose classifications matched the accepted runs. Nothing here says those classifications were **correct**: correctness of the taxonomy is not evaluated anywhere in this study (§1.4), and "正しく" is explicitly not evaluable in the [RQ synthesis](./rq-synthesis.md). What matches is the classification and the scoring record's bytes, not a correctness property.

**4.2 The frozen fault is directional, and the mirror capture is not empty.** Range B's mirror capture retains **3 frames, all in the response direction** `10.1.10.10 → 10.1.20.11`, and zero frames carrying the target selector. Deleting the ingress mirror qdisc on the target interface removed the request direction while responses still reached the tap by another path. The scoring criterion is *the target request is absent*, not *the capture is empty*, so the criterion held — but a design that had tested for an empty capture would have failed here. This is a substantive reason to keep selector-level criteria rather than volume-level ones.

**4.3 `_shards.total = 0` is a distinct response shape.** A wildcard pattern that matches no index returns `_shards {total: 0}` with a successful, non-timed-out response, whereas a concrete missing index returns an error. K7-1 recorded this without smoothing it into "searched an index and found nothing", and that decision is exactly what made H-J1's gap visible in K7-2.

**4.4 The CRLF/LF failure class recurred across three separate records.** K5 Range C (`k5-range-c-20260824-001`), K6 Range A `001` and Range B `001`, and the first K6 index implementation all failed for the same underlying reason: a digest was taken over working-tree bytes that `.gitattributes` then normalized on commit. The countermeasures — `-text -diff` pins on byte-exact artifacts and reading every digest through `git show HEAD:` — were added in response, not by foresight.

**4.5 The base manifest has two legitimate digests.** The pinned Amenonuboco base manifest is `cf0e5a20…` as committed (LF) and `013eb4b0…` as checked out (CRLF). The Range C record cites the second, because that is what the validator read. Both are correct; which one is meant must always be stated.

## 5. Failed, aborted, and non-accepted runs

No accepted record draws any evidence from these attempts, and none was repaired and retried under its own identifier — every retry took a new identifier.

They divide into two kinds, and the distinction matters because the second kind has nothing to retain:

- **Retained-artifact history.** The attempt produced artifacts, which remain **unmodified** and are indexed in [`k6-cross-range-index.json`](../k6-cross-range-index.json): Range A `001`–`003` and Range B `001`–`003`.
- **Record-only history.** The attempt produced no retained artifact, and exists only as a described event in another record's `deviations.md`: the discarded clean rebuild `k6-clean-rebuild-20260825-001` and the aborted Range C initial derivation. Neither is indexed as an attempt, because there is no artifact to index.

| Attempt | Kind | Disposition |
| --- | --- | --- |
| `k6-range-a-20260825-001` | retained artifacts | non-accepted — committed-byte integrity failed on a fresh clone (result-bearing; see 4.1) |
| `k6-range-a-20260825-002` | retained artifacts | non-accepted — stopped before an accepted preflight/provisioning boundary |
| `k6-range-a-20260825-003` | retained artifacts | non-accepted — stopped before an accepted preflight/provisioning boundary |
| `k6-range-b-20260825-001` | retained artifacts | non-accepted — committed-byte integrity failed on a fresh clone, CRLF normalization of an R-OBS-05 correlation JSON (result-bearing; see 4.1) |
| `k6-range-b-20260825-002` | retained artifacts | non-accepted — pre-event abort, provision output retention path failure |
| `k6-range-b-20260825-003` | retained artifacts | non-accepted — pre-event abort, fault-step host tokenization failure |
| `k6-clean-rebuild-20260825-001` | record only | **discarded** — its pre-rebuild residue was observed on the console only and never retained as primary output, the same record-level gap that withheld Gate C on first review. Torn down to zero residue; no artifact retained. Recorded in the accepted check's `deviations.md`, and the accepted check queries this project's residue too. |
| Range C initial derivation attempt | record only | aborted on its own assertion that the base manifest was LF-only, before writing any file or invoking the validator. No artifact, no validator invocation. Recorded in the Range C `deviations.md`. |

Pilot records under `evidence/pilot-runs/` are apparatus history. No Pilot artifact is a Study 01 finding, and the plan makes all of them inadmissible for hypothesis judgment.

## 6. Deviations

**Protocol amendment required: no. Semantic change: no.** No frozen event, selector, fault, time window, scoring rule, or evidence requirement changed during K6 or K7.

| Record | Deviation |
| --- | --- |
| Range A `004` | No execution-procedure deviation. Host `tshark` was unavailable after capture export; the already-running, provenance-inventoried `log_structurer` container decoded copies of the two exported pcaps after the observation window, altering neither retained pcap nor any live observation. |
| Range B `004` | Same shape: no procedure deviation; the running `log_structurer` decoded copies of the three exported pcaps after the window. |
| Range C `001` | None affecting the validation. The aborted first derivation attempt (see §5) and the K5 record's integrity observation are recorded there. |
| Clean rebuild `002` | None affecting the check; the discarded first attempt is recorded there. |

Two corrections were made during K6, both to review and comparison records rather than to evidence:

1. **Gate B2 normalization provenance** (`f799059`) — the equivalence record cited a normalized digest no reviewer could reproduce. Preimages were retained, the normalization rule was made executable, normalized artifacts were retained, and the digest was corrected with the superseded value kept for traceability. No run evidence was modified.
2. **Range C record wording** (`3a83d61`) — a sentence in `metadata.md` claimed more than the derivation established about non-reuse; it was tightened before any review, with the validated and captured bytes untouched.

No accepted Main record was repaired, reinterpreted, or re-executed at any point, in K6 or in K7.

## 7. Documentation imprecisions found during K7

Recorded, not corrected — K7 does not modify plan, protocol, or report files.

| Where | Imprecision | How it was resolved for judgment |
| --- | --- | --- |
| `docs/k7-analysis-claim-freeze-plan.md` §4 and `K6-MAIN-EXPERIMENT-REPORT.md` §12 | cite the frozen semantics module as `scripts/study01/semantics.py`; it is at `scripts/study01/frozen/semantics.py`. | verified at the correct path by blob identity across the K6 boundary, both accepted records, and HEAD |
| `protocol/c2-dnp3-step5-range-c-static-correspondence.md` §3 | describes the contract declaration as naming the segment "and the required mirror target"; the retained asset declares only `required_segments: [sub_a_l2_lan]`, with the mirror target expressed by `instrumentation.mirror_to` outside the contract. | the judgment describes what the asset actually declares |

## 8. What follow-on work would have to add

Not a plan and not a commitment — a statement of what would close the gaps above, so that the limitations are actionable rather than decorative.

1. An **observed** valid `No alert` — an event within the coverage chain that the rule genuinely does not alert on — so that the valid/invalid negative discrimination becomes an observation rather than a counterfactual (closes 1.1).
2. Full rule-stage zero provenance: the searched index or pattern retained with every zero (closes 1.2 / R1).
3. A **positive-control asset set** against the validator, so selectivity is characterised and not assumed (closes 1.6).
4. A contract declarative surface that actually covers what RQ-J2 names, or a research question narrowed to what the contract declares (closes 1.5).
5. Machine-derived scoring input, removing the hand-transcription step (closes R6).
6. More than one contradiction shape, more than one fault kind, more than one host (loosens 1.3).

## 9. What this record does not do

It judges nothing, revisits no hypothesis outcome, and changes no RQ answer. It freezes no claim wording — that is K7-8. It applies no retention or apparatus improvement to K6 evidence. It modifies no K6 evidence, result, protocol, apparatus, or report file, and nothing was re-executed, re-scored, or reinterpreted to produce it.
