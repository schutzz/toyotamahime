# K7-3 — H-J2 judgment

**Frozen hypothesis wording**, quoted verbatim from `protocol/experiment-protocol.md` §3:

> **H-J2:** Range Aでは同一のground-truth network eventに対し、対象sensorのpacket/event到達とcollector出力を確認できるため、対象ruleのalertあり／なしを有効な検知評価結果として扱える。

**Outcome: Supported.**

Judged against the accepted [K7 Analysis / Claim Freeze Plan](../../../../../docs/k7-analysis-claim-freeze-plan.md) §5 H-J2, using only admissible evidence and the [K7-1 normalization](./README.md). All seven required observations are established from committed bytes, and no disconfirmation condition is met.

H-J2 is an **admissibility** hypothesis. Supported means the Range A rule outcome may be treated as a valid detection-evaluation result — nothing more. It is not a statement that the rule detects correctly, and §6 of the plan bars presenting H-J2 as having tested both branches.

The accepted record is `k6-range-a-20260825-004` at raw evidence commit `284d25a`.

## Required observations

| # | Required | Finding | Established |
| --- | --- | --- | --- |
| 1 | Ground Truth **Pass** — the frozen event present, full selector, exactly one | 8 frames retained in the independent capture on `wan_router` `eth4`; exactly **1** carries the complete frozen selector (`10.1.20.11 → 10.1.10.10`, dport `20000`, `dnp3.al.func` 5, link `1024 → 1`), frame 4 at `1787653454.686508000` | **yes** |
| 2 | Sensor **Pass** — the same target request present in the mirror capture | 8 frames retained on `tap_observer` `eth0`; exactly **1** carries the complete frozen selector, frame 4 at `1787653454.686527000`, in the request direction | **yes** |
| 3 | Collector **Pass** — a complete hit for the frozen selector inside the frozen window | `query.json` retains 7 filter clauses: the frozen window plus all six frozen selector terms; `size: 10000`, `track_total_hits: true`; response `timed_out: false`, `_shards {total: 1, successful: 1, failed: 0}`, `hits.total {value: 1, relation: eq}`; the single hit is `R5RzOKABtVAmZGaZEXGy` in `ot-logs-dnp3-2026.08.25`, and its own fields carry the complete selector | **yes** |
| 4 | Correlation to the captured frames by exact tuple, function code and link addresses, integer ns deltas inside ±1,000,000 ns | recomputed here from committed bytes (see below): **+16,541 ns** from Ground Truth and **−2,459 ns** from Sensor | **yes** |
| 5 | The Rule stage evaluated **to completion**, with the outcome established on whichever branch occurred | the branch that occurred is **`Alert`**. `query.json` retains 4 filter clauses (frozen window, `signal.keyword`, `src_ip.keyword`, `dst_ip.keyword`), `size: 10000`, `track_total_hits: true`; response `timed_out: false`, `_shards {total: 1, successful: 1, failed: 0}`, `hits.total {value: 1, relation: eq}`; alert `SpRzOKABtVAmZGaZFnHu` in `ot-signals-zone-violation-2026.08.25`, whose `source_dnp3_doc_id` is `R5RzOKABtVAmZGaZEXGy` — the accepted Collector document | **yes** |
| 6 | Runtime contract **Pass** with `fault_commands = 0`; the target ingress mirror retained | `runtime-contract-record.txt` records `fault_commands=0`, `target_match_count=1`, target interface `eth4@if6706`, with `qdisc ingress` and a `mirred (Egress Mirror to device eth3)` filter present; scored `runtime_contract: Pass` | **yes** |
| 7 | Cross-cutting conditions of plan §4 | 34/34 manifest entries verify against committed bytes; procedure schema 2, `invocation_count` 1, exit `0`, `same_run_retry` false, `procedure_invalid` false; frozen semantics, scorer, scoring and protocol byte-unchanged; deviations retained | **yes** |

## The correlation, recomputed

Required observation #4 is the one the plan makes disconfirming if it is *not recomputable from retained bytes*, so it was recomputed here rather than carried over from the Gate A acceptance review.

The Collector document retains both an ISO time and a decimal epoch for the same frame. They were converted independently and agree exactly:

```
frame_frame_time        2026-08-25T10:24:14.686524541Z   ->  1787653454686524541 ns
frame_frame_time_epoch  1787653454.686524541             ->  1787653454686524541 ns
```

Conversion is exact decimal-string to arbitrary-precision integer nanoseconds — no floating point — the same method the frozen R-OBS-05 contract fixes for Range B.

| Capture | Target frame | Frame epoch (ns) | Delta to the Collector document | Inside ±1,000,000 ns |
| --- | --- | --- | --- | --- |
| Ground Truth (`wan_router` `eth4`) | 4 | `1787653454686508000` | **+16,541 ns** | yes |
| Sensor mirror (`tap_observer` `eth0`) | 4 | `1787653454686527000` | **−2,459 ns** | yes |

Both magnitudes reproduce the values cited in the Gate A acceptance review. The Collector document was captured at a third observation point (its own `eth1`, frame number 605 in that stream), so frame numbers are not comparable across points and the correlation is by tuple, function code, link addresses and time — exactly as the plan requires.

Each capture's lifecycle record binds its pcap by SHA-256, and both hashes match the committed pcap bytes and the run manifest. Both captures were confirmed listening before the window opened (`10:23:45`, `10:23:50`) and confirmed still running after it closed (`10:24:41`, `10:24:42`), against a frozen window of `[2026-08-25T10:24:09.527147Z, 2026-08-25T10:24:29.527147Z]` derived from that run's own T0 `2026-08-25T10:24:14.527147+00:00`. Both queries carry exactly those window bounds.

## The `Alert` binding

Required observation #5's `Alert` branch asks that the retained alert be bound to the accepted Collector document. Three retained fields agree, each independently checkable:

| Binding | Alert | Collector document |
| --- | --- | --- |
| document reference | `source_dnp3_doc_id: R5RzOKABtVAmZGaZEXGy` | `_id: R5RzOKABtVAmZGaZEXGy` |
| millisecond timestamp | `timestamp: "1787653454686"` | `timestamp: "1787653454686"` |
| endpoints | `src_ip 10.1.20.11`, `dst_ip 10.1.10.10` | `ip_ip_src 10.1.20.11`, `ip_ip_dst 10.1.10.10` |

Both stages are index-anchored: each retained `mapping.json` names a concrete index, and each returned hit carries its `_index`. This is the anchoring that Range B's rule stage lacked, and it is present here.

One retention observation, which is not a gap in this judgment: the alert's reference is a bare document id and is not index-qualified. Under the retained mappings there is one DNP3 log index and one signal index, and the id, millisecond timestamp and endpoints all agree, so the binding is established. Recording the source index alongside the id would make the reference self-contained. This goes to K7-7 as a retention observation for future runs; it is **not** applied to K6 evidence.

## Cross-cutting conditions (§4)

| Condition | Finding |
| --- | --- |
| Accepted Main record at its raw evidence commit | `k6-range-a-20260825-004` at `284d25a`; independently reviewed and **ACCEPTED** with no findings |
| Integrity from committed bytes | 34/34 manifest entries verified, 0 mismatched |
| Exactly one sender invocation, exit `0`, no same-run retry, `procedure_invalid` false | schema 2, `invocation_count` 1, exit `0`, `same_run_retry` false, `procedure_invalid` false |
| Frozen event, selector, fault, window and scoring transcription unchanged for that record | blob-identical at the K6 start boundary `a772ea1`, at the accepted record `284d25a`, and at HEAD: `scripts/study01/frozen/semantics.py` `4ae5f1f`, `scripts/study01/frozen/apparatus.py` `d40c870`, `scripts/study01/scorer.py` `1a1132e`, `protocol/scoring.md` `191c1dc`, `protocol/experiment-protocol.md` `41eda16` |
| Deviations recorded in the record's own `deviations.md` | present: no execution-procedure deviation; host `tshark` unavailable after capture export, decoding performed by the already-running provenance-inventoried `log_structurer` container after the observation window, altering neither pcap nor any live observation |

Plan §4 cites the frozen semantics module as `scripts/study01/semantics.py`. The module is at `scripts/study01/frozen/semantics.py`; it was verified there by blob identity across all three commits. This is a path citation in the plan, not a difference in what was checked. The plan is accepted and frozen, so it is not edited.

## Disconfirmation conditions

None is met. Each was checked against the admissible evidence rather than assumed.

| Disconfirmation condition | Status |
| --- | --- |
| The target request absent from the Sensor capture, or no complete Collector hit | **not met** — present in the mirror capture; one complete-hit Collector document under complete-hit settings |
| Correlation outside the frozen bound, or not recomputable from retained bytes | **not met** — recomputed here from committed bytes; both deltas inside the bound by more than an order of magnitude |
| Any fault command executed in Range A | **not met** — `fault_commands=0`, and no `fault-injection.txt` exists in the record |
| On the `Alert` branch: the retained alert cannot be bound to the accepted Collector document | **not met** — bound by document id, millisecond timestamp and endpoints |
| On the `No alert` branch: no retained complete-selector zero-result query, or a truncated, incomplete or differently scoped one | **not applicable** — this branch did not occur in the accepted record |
| `procedure_invalid` true, or other than exactly one sender invocation | **not met** |

## Outcome and its consequences

**H-J2 — Supported.**

What this outcome does mean:

- For the frozen event, the observation chain is complete and recomputable end to end: the event exists on the wire, the same event reaches the target sensor, the collector emits a document that correlates to it within the frozen bound, and the rule stage was evaluated to completion against that document.
- The Range A rule outcome is therefore **admissible as a detection-evaluation result** — the coverage precondition that Range B fails is satisfied here.

What it does **not** mean, restating the plan's over-claim boundary:

- It is **not** a claim that the rule detects correctly, performs well, or is validated. That the Range A rule output was `Alert` is an observation, not a performance claim.
- No detection rate, accuracy, precision, recall, or comparison against another detector follows from it.
- It does not generalise beyond this scenario, event, sensor placement and collector configuration, and one admissible evaluation does not establish that evaluations are generally admissible on this platform.
- It must **not** be presented as having tested both branches. Only the `Alert` branch occurred. No Main run produced an observation-valid `No alert`, and K7 may not present that branch as observed.

Carried forward to K7-6 and K7-8:

- H-J2 Supported establishes the admissibility of the Range A evaluation. It does **not** repair H-J1, which stays **Inconclusive**; H-J1 is not revisited, and the RQ-J1 synthesis must be weakened accordingly rather than strengthened by this outcome.
- The A/B contrast that H-J2 underwrites is a contrast between an admissible evaluation (A) and a coverage failure (B). It is **not** an empirical comparison of a valid negative against an invalid negative, which §6 of the plan bars.

## Not required, and not treated as required

R-OBS-05 is not retained in Range A (`r_obs_05.retained: false` in K7-1). It is not among H-J2's required observations and is not a disconfirmation condition for it: H-J2's coverage is established positively, by the target event itself being observed at every stage, so an unrelated-flow liveness control is not needed here. R-OBS-05 is a Range B requirement, where the target observation is absent and liveness must be shown some other way; it is retained and established there.

Range A also does not retain the unrelated interface's filter state, so K7-1 reports `unrelated_filter_present_after: null` for Range A. H-J2 requires only that the **target** ingress mirror was retained, which the contract record establishes. The asymmetry is recorded for K7-7.

## What is not being done

Range A `k6-range-a-20260825-004` is not re-run, re-queried, re-scored, or supplemented. No K6 evidence, result, or protocol byte is changed by this judgment. H-J3, H-J4, RQ-J1 and RQ-J2 are not judged here.
