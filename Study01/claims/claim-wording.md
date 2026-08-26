# K7-8 — Claim wording draft

The wording Study 01 is permitted to use, drafted from the four judgments, the [RQ synthesis](./rq-synthesis.md), and the [limitations record](./limitations.md). It follows 「CFPを実験に合わせる。実験をCFPに合わせない。」

Every claim below carries the judgment it rests on. Nothing here is new evidence, and no claim is stronger than the judgment under it. This document is a **draft for independent claim review**; it does not issue Gate K7, and it does not yet modify `publication/jsac/cfp.md` or `publication/jsac/slides.md` — §5 lists the changes those files will need once this wording is accepted.

## 1. The claim set

Nine claims. Six affirmative, three negative. The negative ones are claims, not disclaimers: they are things the study established that it cannot say, and they must travel with the affirmative ones rather than sit in a footnote.

### C1 — the observation chain can be verified end to end

> **日本語:** 凍結した単一のDNP3 eventについて、通信の実在からsensor到達、collector出力、rule評価までの観測連鎖を、保存されたバイト列から端から端まで検証できた。collector documentは捕捉フレームと整数ナノ秒で相関し（Ground Truthから +16,541 ns、Sensorから −2,459 ns、いずれも凍結境界 ±1,000,000 ns 内）、生成されたalertはそのcollector documentに紐付いている。
>
> **English:** For one frozen DNP3 event, the observation chain — wire, target sensor, collector document, rule evaluation — was verified end to end from committed bytes, with the collector document correlated to the captured frames using integer-nanosecond timestamp deltas — both inside the frozen ±1,000,000 ns bound — and the alert bound to that document.

**Rests on:** [H-J2 — Supported](./h-j2-judgment.md).
**Boundary:** one event, one function code, one path, one host. Not a statement that the rule detects correctly, performs well, or is validated. The Range A rule output happening to be `Alert` is an observation, not a performance result.

### C2 — the chain can be broken, and the break is visible in primary evidence

> **日本語:** 同一の通信要件のもとで、単一の凍結した故障注入（対象interfaceのingress mirror qdisc削除）により観測連鎖を破壊できた。破壊は一次証拠で確認できる ― mirror captureに対象requestが存在せず、index固定済みのcollector queryは対象documentを0件で返し、同runの中では無関係flowについてSensor/Collectorの相関が6件保持された。
>
> **English:** Under the same traffic requirement, one frozen fault broke the observation chain, and the break is visible in primary evidence: the target request is absent from the mirror capture, the index-anchored collector query returns zero target documents, and six correlated observations of an unrelated flow were retained during the same run.

**Rests on:** the Range B accepted record, through the established observations of [H-J1](./h-j1-judgment.md) and the inputs re-derived in [H-J4](./h-j4-judgment.md).
**Boundary:** one fault of one kind. Negative results arising from other coverage failure modes are untested. The six retained R-OBS-05 correlations show the platform was still observing an unrelated flow during that run — they are **not** a measurement of continuous observability across the window, and they do not enumerate every way coverage can fail.

### C3 — a pre-registered procedure classified the result without a detection-failure category

> **日本語:** 実験実行より前に固定され、K6開始境界・受理記録・現在のHEADでバイト同一であった評価手順が、Range Bで**記録された**「alertなし」を、検知失敗ではなく `Invalid negative result` と機械的に分類した。手順の分類語彙には検知失敗に相当する値が存在しない。offline再採点は保存記録を決定論的に再現する。**ただしこの分類は、検索先indexを保持していないrule queryから転記された `rule_output = No alert` に依存しており、Range Bで対象alertがゼロだったことの実証ではない。**
>
> **English:** A scoring procedure fixed before the run — byte-identical across the K6 start boundary, the accepted record, and HEAD — mechanically classified the **recorded** Range B `No alert` as `Invalid negative result`, not as a detection failure; its taxonomy contains no detection-failure value, and offline rescoring reproduces the retained record deterministically. **That classification depends on a `rule_output = No alert` input transcribed from a rule query that does not record which index it searched, so it is not a demonstration that zero target alerts occurred in Range B.**

**Rests on:** [H-J4 — Supported](./h-j4-judgment.md).

**Boundary — inseparable, both parts.** First, this is a statement about **procedure behaviour**. The procedure was authored by this research, so its behaving as written is evidence of pre-registration and mechanical application — **not** evidence that the distinction it encodes is correct. One classification instance.

Second, the classification's load-bearing input is the one observation the study could not establish. H-J4 fixed the consequence before judgment: the wording **must not present `Invalid negative result` as a substantiated characterisation of the Range B result**. The permissible form therefore names three things together — **who** classified it, under **which pre-registered rule**, and on **which unestablished input** it depends. Dropping the third makes C3 a prohibited claim, exactly as dropping C4's second sentence does. C7 restates the same limitation independently, but C7 standing later in the document does not discharge C3's obligation to carry it.

### C4 — the classification turns on coverage, shown counterfactually

> **日本語:** その分類はcoverage証拠に依存している ― `rule_output` を「alertなし」に固定したまま観測連鎖の各段をPassへ戻すと、凍結scorerの出力は `Valid detection result` へ変わる。**これは凍結scorerに仮想入力を与えて示した手順の性質であって、観測ではない。** 観測可能な形でのvalid `No alert` はK6では発生していない。
>
> **English:** That classification turns on the coverage evidence: holding `rule_output` at `No alert` and restoring the coverage stages makes the frozen scorer return `Valid detection result` instead. **This is a property of the procedure demonstrated on a counterfactual input, not an observation.**

**Rests on:** [H-J4](./h-j4-judgment.md), by counterfactual rescoring.
**Boundary:** the qualifier is part of the claim and may never be dropped, shortened away, or moved to a footnote. C4 without its second sentence becomes a prohibited claim (§2.1 below).

### C5 — one defined contradiction was rejected before deployment

> **日本語:** 1つの定義済み観測矛盾 ― `observability_contract.required_segments` が要求するsegmentを `instrumentation.exclude` が除外する状態 ― を、pinnedされたAmenonuboco validator `v0.13.0` / `0378f8a` が非ゼロexitでdeployment前にrejectした。rejection理由はvalidator sourceの当該分岐に帰属でき、負のassetはpinned base manifestからバイト単位で再導出できる。provisioningもcontainer実行も発生していない。
>
> **English:** One defined observation contradiction was rejected before deployment by the pinned Amenonuboco validator, with a non-zero exit, a reason attributable to a named branch of the validator's source, and no provisioning or container execution.

**Rests on:** [H-J3 — Supported](./h-j3-judgment.md).
**Boundary:** one contradiction shape, one pinned validator, evaluated as a black box. No positive-control asset was run, so selectivity and false rejections are uncharacterised. No novelty claim — `protocol/experiment-protocol.md` §2 forbids asserting novelty without the prior-work delta table.

### C6 — no valid negative was observed

> **日本語:** 本研究のMain Experimentでは、観測が成立した状態での「alertなし」は**一度も発生していない**。Range Aは `Alert`、Range Bは `No alert` であり、得られたのは「観測成立＋Alert」と「観測不成立＋alertなし」の2件である。したがって本研究は、**有効なnegative resultと無効なnegative resultという2種類のnegative outcomeを実測して比較したとは主張しない**。
>
> **English:** No observation-valid `No alert` occurred in the Main Experiment. The study does not claim to have empirically compared two negative outcomes.

**Rests on:** [RQ synthesis](./rq-synthesis.md) §RQ-J1, [limitations](./limitations.md) §1.1.
**Note:** this is a design limitation, not an execution failure — the frozen event is a positive control the rule is expected to alert on, so no Main run could have produced a valid `No alert`.

### C7 — Range B's zero-alert observation is not established

> **日本語:** Range Bのrule queryはselectorとwindowが凍結値と厳密に一致し、timeoutせず `0 eq` を返したが、**どのindexまたはpatternへ発行されたかを記録していない**。したがって本研究は「Range Bで対象alertが0件であった」ことを確立したとは主張しない。これはalertが存在したという認定ではない ― index固定済みのcollector queryは対象documentを0件で保持しており、ruleへの入力自体が存在しなかった。
>
> **English:** The Range B rule query does not record which index it searched, so the study does not claim to have established zero target alerts there. This is not a finding that an alert existed.

**Rests on:** [H-J1 — Inconclusive](./h-j1-judgment.md).

### C8 — the contract declares segments, not sensors, collectors, or events

> **日本語:** pinnedされたObservability Contractの宣言面は `required_segments`（segment名のリスト）**のみ**である。sensor、collector、期待するeventを宣言する面はこの実装には存在せず、Range Cの負のassetが宣言しているのも1件の必須segmentだけである。したがって「通信・sensor・collector・期待するeventをContractとして宣言した」とは書けない。
>
> **English:** The pinned Observability Contract declares required segments only. It has no sensor, collector, or expected-event declaration, so claims phrased in that four-part vocabulary assert more declarative surface than exists.

**Rests on:** [RQ synthesis](./rq-synthesis.md) §RQ-J2, [limitations](./limitations.md) §1.5.

### C9 — the research-question answers

> **RQ-J1 —** 問われた形では答えない。「事前定義した評価手順が有効なnegative resultと無効な実験結果を**正しく**区別できるか」には、K6は答えられない。理由は独立に3つある ― valid `No alert` が未観測（C6）、Range Bのrule-stage zeroが未確立（C7）、そして手順の正しさは自研究著の手順が書かれたとおり動いたことからは評価できない。言えるのはC1〜C4までである。
>
> **RQ-J2 —** yes。ただし2重に狭い ― 矛盾1形 × pinned validator 1本（C5）で、かつcontractのsegment coverage要素についてのみ（C8）。

**Rests on:** [RQ synthesis](./rq-synthesis.md), which is itself bounded by the four judgments.

## 2. Wording that may not be used, and the correction for each

§7 of the plan lists six prohibited claims. The risk at wording time is not that someone writes them verbatim — it is that a natural paraphrase reintroduces one. Each row below is a phrasing that would, with the wording that carries the same content legitimately.

### 2.1 The valid/invalid negative comparison

| ✗ Do not write | Why | ✓ Write instead |
| --- | --- | --- |
| 「valid negativeとinvalid negativeを区別できることを示した」 | §7-6. Only one negative occurred. | 「観測連鎖が成立していることを検証でき（C1）、それが壊れた状態で得られた『alertなし』を事前登録手順が無効な実験結果として分類した（C3）」 |
| 「有効なnegative resultと無効なnegative resultを比較した」 | §7-6, directly. | 「観測成立＋Alertと、観測不成立＋alertなしの2件を比較した」 |
| 「同じ『alertなし』でもcoverage次第で分類が変わることを実証した」 | Presents C4's counterfactual as an observation. | 「…を凍結scorerに仮想入力を与えて示した。観測ではない」 |
| 「Range Aがvalid negativeの対照である」 | Range A produced `Alert`. | 「Range Aは観測連鎖が成立した評価の対照であり、その出力はAlertであった」 |

### 2.2 Detection performance and false negatives

| ✗ Do not write | Why | ✓ Write instead |
| --- | --- | --- |
| 「Range Bのalertなしは誤検知/false negativeではなかった」 | §7-5. Asserts a fact about the detector. | 「事前登録手順はそれを検知失敗として分類しなかった」— a fact about the procedure |
| 「ruleが正しく検知したことを確認した」 | §7-3. Range A's `Alert` is an observation, not a performance result. | 「Range Aのrule出力はAlertであり、それは観測であって性能評価ではない」 |
| 「検知率」「精度」「再現率」「他検知器との比較」 | §7-4. One A/B pair yields no rate. | omit entirely — no such quantity exists in this study |
| 「IDSの評価精度を改善した」 | §7-3. | 「negative resultを読む前提条件を検証可能にした」 |

### 2.3 Generality, novelty, and the contract surface

| ✗ Do not write | Why | ✓ Write instead |
| --- | --- | --- |
| 「観測矛盾はdeployment前にrejectされる」 | §7-1. A general property from one contradiction. | 「定義した1つの観測矛盾が、pinnedしたvalidatorによってdeployment前にrejectされた」 |
| 「Observability Contractは新しい」「従来にない」 | §7-2 and protocol §2 — novelty requires the prior-work delta table. | omit; if positioning is needed, 「既存研究のcredibility／measurement accuracyをOT/ICS Cyber Rangeの検知評価へ具体化する実践的検証」 |
| 「本手法はCyber Rangeのnegative resultの妥当性を保証する」 | §7-1, the strongest form. | 「本手法はこのscenarioにおいて、negative resultを読むための観測前提を検証可能にした」 |
| 「通信・sensor・collector・期待eventをContractとして宣言する」 | C8 — three of the four have no declarative surface. | 「必須の観測segmentをContractとして宣言する」 |
| 「validatorが観測矛盾を検出できることを検証した」 | Implies selectivity, which no positive control established. | 「validatorがこの負のassetをrejectしたことを確認した。positive controlは実施しておらず、false rejectionは未評価である」 |

### 2.4 The procedure and its correctness

C3's boundary has two inseparable parts, and the second is the one that goes missing first: **which unestablished input the classification depends on**. Every corrected wording below carries it.

| ✗ Do not write | Why | ✓ Write instead |
| --- | --- | --- |
| 「事前定義手順が**正しく**区別することを示した」 | Correctness of the taxonomy was never evaluated. | 「事前登録した手順が、記録された段階結果に対して機械的にこの分類を返した」 |
| 「この分類体系は妥当である／標準的である／推奨できる」 | H-J4 boundary. | omit |
| 「Range Bは無効な実験であったと結論した」 | Presents a procedure output as a substantiated characterisation, which H-J1's Inconclusive outcome forbids. | 「事前登録手順は、記録された段階結果に対して `Invalid negative result` を返した。その入力のうち `No alert` は検索先index未記録のqueryに依存する」 |
| 「手順はその「alertなし」を無効な実験結果として分類した」とだけ書く | C3の不可分boundaryの第2部を落としている。依存先が欠けると、手順出力がRange Bの裏付けられた性格規定として読めてしまう。 | 「…分類した。ただしその `No alert` 入力は検索先indexを記録していないrule queryに依存するため、Range Bのzero-alert observation自体は確立していない」 |

The first row's corrected wording is safe because it states only what the procedure returned for the recorded inputs and makes no claim about Range B. As soon as a sentence names the classification **and** Range B in the same breath, the dependency clause becomes mandatory.

### 2.5 Range C's scope

| ✗ Do not write | Why | ✓ Write instead |
| --- | --- | --- |
| 「Range Cが観測不備の実害を示した」 | Range C was never provisioned; it has no runtime stage. | 「Range Cは静的検証であり、宣言矛盾がdeployment前にrejectされることのみを示す」 |
| 「Range Cの結果がH-J1/H-J4を裏付ける」 | protocol §4.3 — Range C bears on RQ-J2 and H-J3 only. | keep Range C in the RQ-J2 line of argument only |
| 「validatorが改善したことを示した」 | No capability delta; v0.12.0 was never run in K6. | omit |

## 3. Traceability

| Claim | Judgment | Primary artifacts the judgment reads |
| --- | --- | --- |
| C1 | H-J2 Supported | `evidence/main-runs/range-a/k6-range-a-20260825-004/` at `284d25a`; 34/34 manifest entries verified |
| C2 | Range B accepted record | `evidence/main-runs/range-b/k6-range-b-20260825-004/` at `e6073f2`; 44/44 manifest entries verified |
| C3 | H-J4 Supported | `results/main/range-b/k6-range-b-20260825-004/scoring-{input,record}.json`; frozen scorer at blob `1a1132e` |
| C4 | H-J4, counterfactual | the same frozen scorer, run on a modified input in a scratch directory; nothing written to any record |
| C5 | H-J3 Supported | `evidence/static-validations/range-c/k6-range-c-20260825-001/` (9/9 verified) and `results/main/gate-c/` |
| C6 | RQ synthesis §RQ-J1 | the two accepted rule outputs: `Alert` (A), `No alert` (B) |
| C7 | H-J1 Inconclusive | `evidence/main-runs/range-b/.../rule-output/` — `mapping.json` `{}`, `_shards.total` `0` |
| C8 | RQ synthesis §RQ-J2 | `platform/schema/instrumentation.py` at Amenonuboco `0378f8a` |
| C9 | all four judgments | as above |

Envelope check (§8): every claim names the frozen scenario or the pinned apparatus explicitly; none aggregates across runs; none uses a non-accepted attempt; none speaks of "the method" in the abstract.

## 4. The one-paragraph version

For an abstract or a closing slide, this is the whole claim, and it is the version to reuse rather than re-compress:

> **日本語:** Cyber Rangeの検知実験で「alertが出なかった」を読む前に、その通信が本当にsensor・collectorへ到達していたかを検証できる形にした。凍結した1つのDNP3 eventについて観測連鎖を端から端まで検証し、単一の故障注入でそれを壊し、破壊を一次証拠で確認し、実験前に固定した評価手順が、記録されたその「alertなし」を検知失敗ではなく無効な実験結果として機械的に分類した ― ただしこの分類の「alertなし」入力は検索先indexを記録していないrule queryに依存するため、**Range Bのzero-alert observation自体は確立していない**。同じ矛盾を宣言として書いたmanifestは、pinnedしたvalidatorがdeployment前にrejectした ― これは矛盾1形×pinned validator 1本の範囲であり、false rejectionを規定するpositive controlは実施していない。**そして、観測が成立した状態での「alertなし」は一度も発生していないため、有効なnegative resultと無効なnegative resultを実測して比較したとは主張しない。**

Every sentence of result carries its own limit in the same sentence rather than deferring it: the classification sentence carries C7's dependency, the static-validation sentence carries C5's scope, and the unobserved valid negative (C6) gets a sentence of its own. That is deliberate — C6, C7, and C8 are not hedges appended to the claim, they are part of it, and a compressed version that drops them is not a shorter version of this claim but a different and prohibited one.

## 5. Changes required in `publication/jsac/` (not applied here)

Listed so the alignment step is mechanical. These files are **not** edited by this draft; they are edited after this wording is accepted, before Gate K7 can pass its exit criterion 10.

| Location | Current text | Required change |
| --- | --- | --- |
| header | 「実験実施前の応募原稿案」「Range A/Bの数値は…完了後にのみ記載する」 | update to post-experiment status and point at the frozen claim set |
| §3 abstract | describes the comparison prospectively | rewrite to C1–C5 plus C6 and C7; the abstract must contain the "no valid negative was observed" sentence |
| §7 | 「Observability Contractとして観測可能性をレンジ定義の性質へ明示し」 | narrow to required segments per C8 |
| §10 takeaway 2 | 「対象通信がsensor、collector、ruleへ到達したというObservability Contractの検証が必要」 | separate the *principle* (coverage must be verified) from the *mechanism* (the contract declares segments) — C8 |
| §13 point 2 | same four-part framing | same correction |
| §12 主張境界 | already narrow and close to correct | add C6 and C7 explicitly; they are currently absent |
| §6 classification table | presents the taxonomy | add that the taxonomy is the study's own pre-registered procedure and was not validated against an external standard — C3 boundary |
| §9 outline, 36–39分 | 「実験結果と限界」 | this slot must carry C6 and C7, not only scope limits |
| `slides.md` | its own header states it is a transfer record of the **old Amenonuboco JSAC assets**, to be redesigned once the measured results and claim boundary are fixed; its 36 slides are about range provisioning and Digital Twin, and carry no Study 01 detection claim | not a line-by-line correction. It is redesigned from C1–C9, and the redesign is checked against the §2 tables — in particular that Part 5 「品質保証」 does not restate the taxonomy as validated, and that a slot exists for C6 and C7 |

## 6. What this document does not do

It judges nothing and revisits no hypothesis outcome or RQ answer. It freezes nothing — freezing is Gate K7, issued by independent review and never self-certified. It modifies no K6 evidence, result, protocol, apparatus, or report file, and no `publication/` file. Nothing was re-executed, re-scored, or reinterpreted to produce it.
