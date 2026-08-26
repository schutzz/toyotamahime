# K7-5 — H-J4 judgment

**Frozen hypothesis wording**, quoted verbatim from `protocol/experiment-protocol.md` §3:

> **H-J4:** 事前定義した評価手順は、Range Bの「alertなし」を検知失敗と分類せず、Observability Contract不成立による**Invalid negative result**と分類する。

**Outcome: Supported.**

Judged against the accepted [K7 Analysis / Claim Freeze Plan](../../../../../docs/k7-analysis-claim-freeze-plan.md) §5 H-J4, using only admissible evidence: the frozen scoring transcription and protocol, the Range B accepted record's scoring input and retained scoring record, and the [Gate B1 acceptance review](../range-b/k6-range-b-20260825-004/acceptance-review.md) with its [addendum](../range-b/k6-range-b-20260825-004/acceptance-review-addendum.md). All six required observations are established from committed bytes, and no disconfirmation condition is met.

H-J4 is a claim about **procedure behaviour**, not about taxonomy validity, and it carries the circularity risk the plan named before judging: the procedure was authored by this same research. Two sections below — the H-J1 dependency and the over-claim boundary — are load-bearing parts of this judgment, not caveats appended to it.

The accepted record is `k6-range-b-20260825-004` at raw evidence commit `e6073f2`.

## Required observations

| # | Required | Finding | Established |
| --- | --- | --- | --- |
| 1 | The scoring procedure was **pre-defined** — transcription and protocol byte-unchanged between the K6 start boundary and the accepted record | blob-identical at boundary `a772ea1`, accepted `e6073f2`, and HEAD: `scorer.py` `1a1132e`, `frozen/semantics.py` `4ae5f1f`, `frozen/apparatus.py` `d40c870`, `procedure_conformance.py` `92bca65`, `protocol/scoring.md` `191c1dc`, `protocol/experiment-protocol.md` `41eda16` | **yes** |
| 2 | The scorer input is derived from the retained evidence, not composed by hand to reach an outcome | every one of the eight input fields was re-derived independently from committed bytes and agrees (table below); `procedure_conformance` is byte-equal to the retained evidence file, and the CLI itself refuses to score if it is not | **yes**, by verification — see the qualification |
| 3 | The retained classification for Range B is exactly `Invalid negative result` | `scoring-record.json` carries `"experiment_classification": "Invalid negative result"` | **yes** |
| 4 | That classification is **not** "detection failure" or any equivalent, and the taxonomy distinguishes the two | the frozen taxonomy has **no** detection-failure value; holding `rule_output` fixed at `No alert` and changing only the coverage evidence flips the classification (demonstration below) | **yes** |
| 5 | Offline rescoring from the retained inputs, after teardown, reproduces the classification deterministically | the frozen scorer, extracted from committed bytes, returns a record **equal in full** to the retained one, on five repetitions; the Gate B1 reviewer independently reproduced it from a detached clone | **yes**, with the §11 byte-identity qualification |
| 6 | The classification follows mechanically from the recorded stage outcomes, without manual override or post-hoc selection | the frozen scorer and its CLI contain no override, force, expected, or manual path; every field of the matched branch is load-bearing, and off-branch inputs raise rather than default; the retained record's keys are exactly the scorer's return keys | **yes** |

## The scorer input, re-derived field by field

Required observation #2 is where a pre-registered procedure can be defeated without any code change — by feeding it a hand-composed input. So each field was re-derived from committed evidence rather than accepted as transcribed.

| Input field | Value | Independently re-derived basis |
| --- | --- | --- |
| `stages.ground_truth` | `Pass` | independent capture retains **1** frame carrying the complete frozen selector |
| `stages.sensor` | `Fail` | mirror capture retains **0** selector frames — 3 frames, all in the response direction |
| `stages.collector` | `Fail` | complete-selector query, 7 filter clauses, `_shards {total: 1}`, `hits.total {0, eq}` |
| `rule_output` | `No alert` | rule query returns `hits.total {0, eq}`, `_shards {total: 0}` — **the index searched is not recorded**; see the H-J1 dependency |
| `runtime_contract` | `Fail` | `fault_commands=1`, one mutation argv, exit `0`; target qdisc and target filter both absent afterwards |
| `r_obs_05` | `Pass` | 6 unrelated-flow correlations, 6 unique documents to 6 unique frames, deltas 8,408–25,791 ns, all inside ±1,000,000 ns |
| `target_observation_absent` | `true` | mirror capture retains 0 target-selector frames |
| `evidence_correlatable` | `true` | both capture lifecycles validate against that run's own T0; R-OBS-05 correlates retained frames to retained documents |
| `procedure_conformance` | schema 2, 1 invocation, exit `0` | **byte-equal** to `ground-truth/procedure-conformance.json` in the evidence tree |

**The qualification.** Only `procedure_conformance` is *enforced* against the evidence tree — `scripts/study01_score.py` compares it to the retained file and raises `UncoveredSemanticState` if they differ. The eight stage-level fields are transcribed by the operator from the retained evidence; the apparatus does not itself re-derive them. Every one of them agrees with an independent recomputation from committed bytes, so #2 is established here by **verification**, not by enforcement. That distinction is recorded for K7-7 as an apparatus observation: a future scoring tool could derive the stage fields from the evidence tree the way it already does for `procedure_conformance`, closing a hand-transcription step that currently sits between evidence and classification. It is **not** applied to K6 evidence, and it changes nothing about this record, whose transcription is verified correct.

## Why it is not a detection failure

The frozen semantics enumerate the entire taxonomy:

```python
CLASSIFICATIONS = {
    "Valid detection result", "Invalid negative result",
    "Inconclusive experiment", "Invalid run",
}
```

There is no "detection failure" value. The only way this taxonomy can express *the detector saw the event and did not alert* is `Valid detection result` with `rule_output: No alert` — that is, a negative result that survives the coverage checks. So the distinction H-J4 asserts is structural in the taxonomy, not a matter of naming.

It is also demonstrable mechanically. Holding `rule_output` fixed at `No alert` and changing only the coverage evidence:

| Input | Classification |
| --- | --- |
| as retained — sensor `Fail`, collector `Fail`, runtime contract `Fail` | **`Invalid negative result`** |
| coverage intact — sensor `Pass`, collector `Pass`, runtime contract `Pass` | **`Valid detection result`** |

The same absent alert is classified two different ways depending on whether the observation chain held. That is precisely the discrimination the hypothesis claims the pre-defined procedure makes, and the procedure makes it without seeing which range it is scoring.

The matched branch is:

```python
elif (out_stages["ground_truth"] == "Pass" and rule == "No alert"
      and out_runtime == "Fail" and record.get("target_observation_absent") is True):
    classification = "Invalid negative result"
```

which is `protocol/scoring.md` §2 row 2 verbatim in effect: *Ground Truth Pass, Rule output `No alert`, and Runtime contract Fail because a required target observation stage is absent.* Each of the four conditions is load-bearing: changing `rule_output` to `Alert`, `runtime_contract` to `Pass`, or `target_observation_absent` to `false` does not produce a different classification — it raises `UncoveredSemanticState`, because the frozen semantics decline to classify a state K3 and AMEND-002 do not cover. The scorer fails closed rather than defaulting.

One pre-registered safeguard is worth naming because it did not fire: AMEND-002 #4 rewrites the Range B runtime contract to `Unresolved` when `r_obs_05` is `Fail`, which would have made the run `Inconclusive experiment` instead. `r_obs_05` is `Pass`, so the branch that could have downgraded this classification was live and simply not triggered.

## Rescoring

The frozen scorer was extracted from committed bytes into a scratch package and run against the committed scoring input. It returned a record **equal in full** to the retained `scoring-record.json` — not merely the same classification — and did so identically on five repetitions. The Gate B1 reviewer independently reproduced the same classification from a no-hardlink detached clone.

The §11 qualification applies and is restated rather than omitted: `scripts/study01_score.py` writes its record with `Path.write_text` instead of the LF-only writer in `scripts/study01/evidence_io.py`, so a fresh-clone rescoring that writes to a file reproduces the retained record **content-identically but not byte-identically** (12 CR bytes). The comparison performed here is of parsed records, which are equal. That defect was deferred by decision during K6 — changing shared apparatus between Range B and a later range would have introduced an apparatus difference between comparison members — and it affects no observation, stage outcome, or classification, symmetrically across A and B.

## The H-J1 dependency

This is the part of H-J4 that must not be presented cleanly, because it is not clean.

The `Invalid negative result` branch turns on `rule_output == "No alert"`. That input is a faithful transcription of the Range B rule query's retained result — `hits.total {0, eq}`, not timed out, complete frozen selector. But [H-J1](./h-j1-judgment.md) found that this same retained query **does not record which index or pattern it searched**, and therefore does not establish zero target alerts. H-J1 is **Inconclusive** for exactly that reason.

So the load-bearing input to the classification is the one observation the study could not establish. What follows, and what does not:

- H-J4 is still **Supported**: the plan's Inconclusive condition for H-J4 is "rescoring cannot be performed from committed bytes", and rescoring can. The plan also anticipated this interaction in advance and fixed the answer: H-J4 "may still be Supported as a statement about the procedure's behaviour". Applying that rule as written, without inventing a new disconfirmation condition after seeing the result, gives Supported.
- The plan's accompanying wording constraint was written for "if H-J1 is Not supported". H-J1 came out **Inconclusive**, which is not the enumerated case, and the constraint is applied here anyway. Its stated rationale is that "the classification's admissibility depends on H-J1's required observations" — those are not all established under Inconclusive either, so the constraint applies with at least equal force. This is a fixed rule applied conservatively to an anticipated neighbouring case, not a new rule.
- Therefore: **the claim wording must not present `Invalid negative result` as a substantiated characterisation of the Range B result.** It is what the pre-registered procedure returns for the recorded stage outcomes. It is not an established finding that Range B produced zero target alerts.

What *is* established about Range B's negativity, independent of the rule stage, is stronger than the rule query alone: the mirror capture retains zero target frames, and the index-anchored Collector query retains zero target documents. There was no rule input to alert on. That supports the classification's substance without resting on the unanchored query — but it is an argument about the observation chain, not about the rule stage, and it does not convert H-J1's Inconclusive into an establishment.

## Disconfirmation conditions

None is met.

| Disconfirmation condition | Status |
| --- | --- |
| Any change to the scoring transcription or protocol between the start boundary and the record | **not met** — six files blob-identical across boundary, accepted record, and HEAD |
| The classification produced by manual entry, override, or a hand-edited scorer input rather than from retained evidence | **not met** — no override path exists in the scorer or its CLI; every input field was re-derived from committed evidence and agrees; `procedure_conformance` is machine-enforced |
| Rescoring not reproducing the retained classification | **not met** — full record equality, five repetitions, plus the independent Gate B1 reproduction |
| The retained classification being a detection failure, or the taxonomy not distinguishing invalid from negative | **not met** — the taxonomy has no detection-failure value, and the same `No alert` classifies differently by coverage |

## Outcome and its consequences

**H-J4 — Supported.**

What this outcome does mean:

- A scoring procedure fixed **before** the run, byte-unchanged across the K6 boundary and the accepted record, applied mechanically to inputs that are verifiably transcriptions of the retained evidence, classified Range B as `Invalid negative result` and not as a detection failure — and the taxonomy it applies has no detection-failure category to fall into.
- The classification is reproducible offline and deterministic, and every condition of the branch that produced it is load-bearing.

What it does **not** mean, restating the plan's over-claim boundary in full:

- It does **not** establish that "the procedure correctly distinguishes invalid negatives" as an evaluated property of the taxonomy. The procedure was authored by this same research; that it behaves as written is evidence of pre-registration and mechanical application, **not** independent evidence that the distinction it encodes is valid.
- It does **not** license any claim that other evaluation procedures would, should, or do classify similarly.
- It does **not** license any claim that this classification scheme is general, standard, or recommended practice.
- The classification is a statement about **the experiment's validity**, not a finding about the detector. It must not be presented as one.
- Given H-J1's Inconclusive outcome, it must not be presented as a substantiated characterisation of the Range B result.

Carried forward to K7-6 and K7-8:

- H-J4 enters RQ-J1 as evidence about the **procedure**, alongside H-J1 (Inconclusive) and H-J2 (Supported, admissibility only). Under plan §6 it may not be used to strengthen H-J1, and the RQ-J1 wording must carry both the pre-registration meaning and the H-J1 limitation.
- Any sentence of the form "Range B was classified as an invalid negative result, therefore the negative result does not indicate detection failure" is barred in that bare form: it presents a procedure output as a substantiated characterisation. The permissible form states who classified it, under what pre-registered rule, and on which unestablished input the classification turns.

## Known limitations relevant to this hypothesis

Restated from the plan, unchanged: one classification instance; the procedure was exercised on one invalid case and one valid case; the byte-identity qualification on rescoring recorded in `K6-MAIN-EXPERIMENT-REPORT.md` §11 applies. Added here for K7-7: the stage-level scorer inputs are hand-transcribed and verified rather than machine-derived.

## What is not being done

Range B `k6-range-b-20260825-004` is not re-run, re-queried, re-scored into its record, or supplemented. The rescoring performed for this judgment ran the frozen scorer from committed bytes in a scratch directory and wrote nothing into any evidence tree or results record. The deferred `study01_score.py` CRLF defect is **not** fixed here; K7 is not the place to change apparatus that K6 used. RQ-J1 and RQ-J2 are not answered here — all four hypotheses are now judged, and the synthesis is K7-6.
