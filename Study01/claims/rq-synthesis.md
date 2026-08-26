# K7-6 — RQ-J1 / RQ-J2 synthesis

This folds the four completed hypothesis judgments into answers to the two research questions, under the synthesis rules of the accepted [K7 Analysis / Claim Freeze Plan](../../../../../docs/k7-analysis-claim-freeze-plan.md) §6, the prohibited claims of §7, and the permissible envelope of §8.

No hypothesis is revisited here. No claim wording is frozen here — that is K7-8.

## The judgments this rests on

| Hypothesis | Outcome | What it licenses |
| --- | --- | --- |
| [H-J1](./h-j1-judgment.md) | **Inconclusive** | nothing affirmative about Range B's rule-stage zero; the retained rule query does not record which index it searched |
| [H-J2](./h-j2-judgment.md) | **Supported** | admissibility of the Range A evaluation only; the `Alert` branch only |
| [H-J3](./h-j3-judgment.md) | **Supported** | one defined contradiction, one pinned validator, rejected pre-deployment |
| [H-J4](./h-j4-judgment.md) | **Supported** | behaviour of the pre-registered procedure only; not the validity of the taxonomy, and not a substantiated characterisation of the Range B result |

Under §6, RQ-J1 draws only on H-J1, H-J2, and H-J4; RQ-J2 draws only on H-J3 and Range C's role as fixed in `protocol/experiment-protocol.md` §4.3. An RQ answer may not be stronger than the weakest hypothesis it rests on.

---

## RQ-J1

**Frozen wording**, quoted verbatim from `protocol/experiment-protocol.md` §3:

> ground-truth network eventが実在し、検知結果が「alertなし」である場合、事前定義した評価手順は、検知ruleの有効なnegative resultと観測coverage不成立による無効な実験結果を正しく区別できるか。

### Answer: not answered as asked — qualified down to a narrower statement about the procedure

The question asks whether the pre-defined procedure can **correctly distinguish** a valid negative result from an invalid experimental result. K6 does not answer that question. Three independent reasons each block it, and any one of them would be enough.

**1. The valid negative was never observed.** The accepted Range A rule output was `Alert`; the accepted Range B rule output was `No alert`. What K6 produced is

```text
Range A:  observation-valid evaluation   + Alert
Range B:  observation-invalid evaluation + No alert
```

and not

```text
observation-valid   + No alert
vs
observation-invalid + No alert
```

A distinction between two negative results cannot be shown by an experiment in which only one negative result occurred. This is not an experimental failure — H-J2 is an admissibility hypothesis and was judgeable on the branch that occurred — but it fixes a ceiling on what RQ-J1 may say.

**2. H-J1 is Inconclusive.** Even the one negative that did occur does not have a fully established rule-stage zero: the Range B rule query is complete in selector and window and returned `0 eq`, but nothing in the retained record identifies the index or pattern it searched. So "検知結果が「alertなし」である場合" is, for Range B, a recorded stage outcome rather than an established observation.

**3. "正しく" is not evaluable here.** The procedure was authored by this same research. H-J4's over-claim boundary, fixed before judgment, bars treating the procedure's behaving as written as evidence that the distinction it encodes is *correct*. Pre-registration and mechanical application are what were shown; correctness of the taxonomy was not evaluated against anything external.

### What may be said instead

Within the §8 envelope — the frozen C2 DNP3 scenario, one frozen event and selector, the frozen apparatus, the pre-defined procedure as transcribed at the start boundary, one accepted record per range on one host with one frozen fault — the following is established and traceable:

| Statement | Resting on |
| --- | --- |
| The observation chain that is the precondition for reading any negative result **can be established and verified end to end** for the frozen event: wire → target sensor → collector document → rule evaluation, with the collector document correlated to the captured frames within ±1,000,000 ns and the alert bound to that document. | H-J2 Supported |
| When that chain is broken by the frozen fault, the break is **demonstrable from primary evidence**: the mirror capture retains zero target frames and the index-anchored collector query retains zero target documents, while an unrelated flow remains observed (R-OBS-05). | Range B accepted record, via H-J1's established observations and H-J4's re-derived inputs |
| The pre-registered procedure, applied mechanically to the recorded stage outcomes, classified the Range B `No alert` as **`Invalid negative result`** and not as a detection failure; its taxonomy contains no detection-failure value. | H-J4 Supported |
| That classification **turns on the coverage evidence**: with `rule_output` held at `No alert`, restoring the coverage stages yields `Valid detection result` instead. | H-J4, by counterfactual rescoring of the frozen scorer |

The fourth row must always carry its qualifier. It is a property of the pre-registered procedure's code, demonstrated by feeding it a hypothetical input. **It is not an observation.** No run with an observation-valid `No alert` exists, so the procedure's branch for that case has been exercised only counterfactually.

### The answer, stated as a sentence

*For the frozen scenario, the study establishes that the observation chain underwriting a negative result can be verified end to end, and that when that chain is broken the pre-registered procedure classifies the resulting `No alert` as an invalid experimental result rather than as a detection failure. It does not establish that the procedure correctly distinguishes a valid negative result from an invalid one, and it did not observe a valid negative result at all.*

### 日本語形（plan §6 の固定文言に従う）

> **Range AではNo alertを観測していないため、「valid negativeとinvalid negativeの二種類を実測して識別した」とは主張しない。Range Aが実証するのは評価結果のadmissibilityであり、valid-No-alert branch自体の実測ではない。**

これに加えて、H-J1がInconclusiveであるため、**Range Bについても「対象alertがゼロであった」ことを確立したとは書かない**。確立されているのは、mirror captureにtarget frameが存在しないこと、index固定済みのcollector queryにtarget documentが存在しないこと、そして事前登録手順がその記録に対して`Invalid negative result`を返したことである。

### The anticipated challenge, rewritten from the actual judgments

The plan anticipated the question *"you say the study distinguishes a valid negative — so where is the valid negative?"* and required the answer be rewritten from the judgments rather than reused as drafted. Rewritten:

> There is none. No valid negative occurred in the Main Experiment. Range A establishes that the observation chain which is the precondition for reading a negative at all can be built and verified; Range B establishes that this chain can be broken in a way that is visible in primary evidence, and that the pre-registered procedure classifies the `No alert` recorded under that broken chain as an invalid experimental result. The study does not claim to have empirically compared two negative outcomes, and it does not claim to have established that Range B produced zero target alerts — its rule-stage query does not record what it searched.

---

## RQ-J2

**Frozen wording**, quoted verbatim from `protocol/experiment-protocol.md` §3:

> 評価対象の通信、sensor、collector、期待するeventをObservability Contractとして宣言することで、指定した観測矛盾をdeployment前に検出またはrejectできるか。

### Answer: yes, for the one contradiction that was defined and tested — and only for the segment-coverage element of the contract

H-J3 is Supported, so an affirmative answer is available. Two scope reductions apply, and the second is a narrowing of the question itself.

**Scope reduction 1 — one contradiction, one validator.** What was shown is that a segment simultaneously required by `observability_contract.required_segments` and removed by `instrumentation.exclude` is rejected by the pinned validator `v0.13.0` / `0378f8a` with a non-zero exit, before any provisioning, for a reason attributable to that contradiction. No positive-control asset set was run in K6, so false rejections are uncharacterised: a validator that rejected everything would have produced the same observation. Nothing is established about other contradiction shapes, about validator completeness, or about soundness.

**Scope reduction 2 — the contract surface that exists is narrower than the question.** RQ-J2 asks about declaring 「通信、sensor、collector、期待するevent」 as an Observability Contract. At the pin, the contract model is:

```python
class ObservabilityContract(BaseModel):
    required_segments: list[str] = Field(min_length=1)
```

That is its entire declarative surface. There is no sensor declaration, no collector declaration, and no expected-event declaration in the pinned contract, and the Range C negative asset declares exactly one thing: `required_segments: [sub_a_l2_lan]`. The traffic, sensor, collector and event are pinned elsewhere — in the scenario, the topology, and the instrumentation — and are bound to the contract only through the segment name.

So RQ-J2 is answerable **only for the segment-coverage element**. The four-part declaration its wording names was not exercised, because three of those four parts are not part of the contract mechanism as pinned. Any claim phrased in the RQ's own four-part vocabulary would assert more declarative surface than exists.

`protocol/c2-dnp3-step5-range-c-static-correspondence.md` §3 describes the second declaration as naming the segment "and the required mirror target". The retained asset names only the segment; the mirror target is expressed by `instrumentation.mirror_to`, outside the contract. This is a prose imprecision in a protocol document, recorded here rather than corrected, since K7 does not modify protocol files.

### The answer, stated as a sentence

*For the frozen scenario and the pinned validator, declaring a required observed segment in an Observability Contract is sufficient to have a manifest that excludes that same segment rejected before deployment, with a non-zero exit and a reason attributable to the contradiction. This is established for one contradiction shape and for the segment-requirement element of the contract only; the sensor, collector, and expected-event declarations named in the question do not exist in the pinned contract and were not tested, and no false-rejection behaviour was characterised.*

### What RQ-J2 does not carry

- No capability-delta claim. The Range C static correspondence protocol contemplates a v0.12.0 baseline that accepts the same asset, but K6 exercised only `v0.13.0`. A before/after capability comparison is not part of the Main Experiment evidence and is not claimed here.
- No novelty. `protocol/experiment-protocol.md` §2 forbids asserting novelty without the prior-work delta table, and none of this supplies it.
- No general property that "observation contradictions are rejected before deployment".

---

## Prohibited-claim self-check (§7)

Each prohibited claim, checked against every statement made above.

| # | Prohibited claim | Present? |
| --- | --- | --- |
| 1 | That this method generally guarantees or ensures negative-result validity in Cyber Ranges | **no** — every statement is scoped to the frozen scenario, event, apparatus, and one record per range |
| 2 | That the Observability Contract is novel | **no** — novelty is explicitly disclaimed under protocol §2 |
| 3 | That IDS performance was improved | **no** — no performance statement appears; H-J2's boundary is restated wherever the Range A `Alert` is mentioned |
| 4 | That a general detection rate was shown from one A/B pair | **no** — no rate, accuracy, precision, or recall appears |
| 5 | That the Range B `No alert` was an IDS false negative | **no** — it is stated as an invalid experimental result, and H-J1's Inconclusive outcome is carried with it |
| 6 | That the study empirically compared a valid negative against an invalid negative, or observed a valid negative at all | **no** — stated affirmatively in the negative twice, in both languages, and the counterfactual demonstration is labelled as such wherever it appears |

## Envelope check (§8)

| Envelope element | How the answers stay inside it |
| --- | --- |
| the frozen C2 DNP3 scenario, single frozen event and selector | every observation cited is the single `dnp3.al.func` 5 request, link `1024 → 1`, `10.1.20.11 → 10.1.10.10:20000` |
| the frozen apparatus — Kakuriyo `a772ea1`, Amenonuboco range generation `78fc177`, validator `v0.13.0` / `0378f8a` | the scoring and protocol files are blob-identical across the boundary and the accepted records; the validator is pinned by commit and verified by the Gate C reproduction |
| the pre-defined procedure as transcribed at the start boundary | RQ-J1's fourth row and the whole of RQ-J2 name the procedure and validator explicitly rather than speaking of "the method" |
| one accepted record per range, one host, one frozen fault | no statement aggregates across runs, and non-accepted attempts contribute nothing |

Traceability: every statement above names the judgment it rests on, and each judgment names the committed artifacts it read.

## What this document does not do

It does not draft or freeze claim wording — that is K7-8, after the limitations record in K7-7. It does not revisit any hypothesis outcome. It modifies no K6 evidence, result, protocol, or apparatus file, and nothing was re-executed, re-scored, or reinterpreted to produce it. It does not issue Gate K7, which is for independent review.

Two items are added to the K7-7 limitations queue by this synthesis:

1. The Observability Contract's declarative surface at the pin is a single `required_segments` list, narrower than RQ-J2's four-part wording — a scope limit on the question, not only on the answer.
2. K6 exercised no positive-control asset against the validator, so false-rejection behaviour is uncharacterised.
