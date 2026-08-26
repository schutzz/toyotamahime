# K7-2 — H-J1 judgment

**Frozen hypothesis wording**, quoted verbatim from `protocol/experiment-protocol.md` §3:

> **H-J1:** Range Bではground-truth network eventが通信実在を示し、対象ruleはalertなしでも、対象sensorへの観測coverageが不成立であるため、このnegative resultは検知性能を支持しない。

**Outcome: Inconclusive.**

Judged against the accepted [K7 Analysis / Claim Freeze Plan](../../../../../docs/k7-analysis-claim-freeze-plan.md) §5 H-J1, using only admissible evidence and the [K7-1 normalization](./README.md). One required observation is not established from the admissible evidence, and **no disconfirmation condition is affirmatively met**, which under §3 is Inconclusive rather than Not supported.

This is not a finding that the hypothesis is false, and not a finding that a target alert existed. It is a finding that the retained record does not establish one of the observations the plan required before judgment.

## Required observations

| # | Required | Finding | Established |
| --- | --- | --- | --- |
| 1 | Ground Truth **Pass** — exactly one full-selector `dnp3.al.func` 5, link `1024 → 1` | 8 frames retained, **1** carrying the complete frozen selector | **yes** |
| 2 | Sensor **Fail** — the target request absent from the mirror capture | 3 frames retained, **0** carrying the selector, all in the response direction `10.1.10.10 → 10.1.20.11` | **yes** |
| 3 | Collector **Fail** — a retained complete-selector query establishing **zero** target documents in the frozen window | query retains 7 filter clauses matching the frozen selector and the window `[T0−5 s, T0+15 s]` computed from that run's own T0; `track_total_hits: true`, `size: 10000`, `timed_out: false`, `_shards {total: 1, successful: 1, failed: 0}`, `hits.total {value: 0, relation: eq}`; the stage's retained `mapping.json` names the searched index `ot-logs-dnp3-2026.08.25` | **yes** |
| 4 | Rule **No alert** — a retained complete-selector query establishing **zero** target alerts for the frozen selector and window | the query body carries the complete frozen selector (`signal: signal-1-zone-violation`, `src_ip`, `dst_ip`) and the exact frozen window, `track_total_hits: true`, `timed_out: false`, `hits.total {value: 0, relation: eq}` — but **nothing in the retained record identifies the index or pattern the query was issued against** | **no — see below** |
| 5 | R-OBS-05 **Pass** | 6 complete Collector hits for the unrelated flow correlated one-to-one with 6 unique pcap frames by exact tuple, function and link, deltas 8,408–25,791 ns, all inside ±1,000,000 ns, retained total `eq` 6 | **yes** |
| 6 | Gate B2 **PASS** | independently re-reviewed and PASS; the two runs' generated Compose files are byte-identical after workspace-prefix substitution | **yes** (with one sub-claim noted below) |
| 7 | Exactly one permitted mutation; target qdisc/filter absent afterwards; unrelated mirror retained | `fault_commands=1`, one mutation argv, exit `0`; target qdisc and filter absent afterwards; unrelated interface's `mirred` filter retained unchanged | **yes** |
| 8 | Cross-cutting conditions of plan §4 | accepted record at raw commit `e6073f2`; 44/44 hash-manifest entries verify against committed bytes; procedure schema 2, `invocation_count` 1, exit `0`, no same-run retry, `procedure_invalid` false; scoring transcription and protocol byte-unchanged since the K6 start boundary; deviations retained | **yes** |

Seven of the eight are established. The judgment turns on #4.

## Why #4 is not established

The Range B Rule query is complete in its selector fields and in its window, and its response is a real response — it did not time out and it reports a complete-hit total of `0 eq`. What it does not carry, anywhere in the retained record, is **what it searched**.

| Stage | Index identified by retained bytes? | How |
| --- | --- | --- |
| Range A Collector | yes | `mapping.json` names `ot-logs-dnp3-2026.08.25`; the returned hit carries `_index` |
| Range A Rule | yes | `mapping.json` names `ot-signals-zone-violation-2026.08.25`; the returned alert carries `_index` |
| Range B Collector | yes | `mapping.json` names `ot-logs-dnp3-2026.08.25`; `_shards {total: 1}` shows an index was searched |
| **Range B Rule** | **no** | `mapping.json` is `{}`; there are no hits, so no `_index`; `query.json` is a body with no index; `_shards {total: 0}` |

The four artifacts the stage retains are `query.json`, `sample-search.json`, `mapping.json`, and `query-and-response.md`. None of them names an index or a pattern for this stage in Range B, and the prose record states only that the query "returned `total.value: 0`".

This matters because `_shards.total = 0` is exactly the response shape produced when a wildcard pattern matches no index at all. That is consistent with the intended reading — no alert document was ever written, so the daily signal index was never created — and it is equally consistent with a query issued against a pattern that never existed. **The retained record cannot distinguish the two**, and the datum that would distinguish them is the one thing it does not contain.

The plan fixed, before any judgment, that "a zero is only established by a complete query that was actually run; an absence noticed, a truncated result, or a **differently scoped** query does not establish it." The search target is part of a query's scope. A query whose target is unrecorded does not establish zero *target* alerts, however complete its field selector.

Three lines of argument were considered and none closes the gap from admissible evidence:

1. **The protocol fixes the pattern.** `protocol/c2-dnp3-step3-pilot.md` fixes Rule output to `ot-signals-zone-violation-*`. That establishes where an alert *would be written*. It does not establish where this query *was sent*.
2. **Range A used that pattern.** Range A's retained bytes do name it. That is evidence about Range A's execution, and the plan admits Range A into H-J1 only through Gate B2, as the controlled counterpart — not as a substitute for a Range B observation.
3. **Gate B2 records "Same index".** The Gate B2 matrix's Target Rule row does state the same index for both runs. On inspection that sub-claim is not itself anchored: the query bodies carry no index, and the Gate B2 re-review verified the queries as *parsed objects with timestamps normalized*, which cannot see an index. Resting #4 on it would be resting a judgment on an unverified link in exactly the way this study has repeatedly refused.

The narrow inference that *is* available: an empty `{}` from a mapping request is the response to a wildcard that matched nothing, since a concrete missing index returns an error instead. So a pattern was almost certainly used, and it matched nothing. Which pattern remains unrecorded.

## Disconfirmation conditions

None is affirmatively met. Each was checked against the admissible evidence rather than assumed.

| Disconfirmation condition | Status |
| --- | --- |
| R-OBS-05 Fail, absent, or resting on Sensor-only liveness or service health | **not met** — retained, nonempty, tuple- and time-correlated Collector evidence for the unrelated flow |
| A/B equivalence not established, or an unexplained semantically relevant difference | **not met** — Gate B2 PASS on independent re-review |
| Ground Truth not Pass | **not met** — the frozen event is present exactly once |
| More than one mutation, or a mutation other than the frozen one | **not met** — exactly one, and it is the frozen one |
| `procedure_invalid` true, more than one invocation, or a same-run retry | **not met** |
| Target request present in Sensor, or a target Collector document or Rule alert present | **not met** — none present |
| A zero asserted without a retained complete-selector query behind it, or from a query truncated, incomplete, or scoped differently from the frozen selector and window | **not met** — a complete-selector query and a real response are retained; the scope is *unrecorded*, which is not the same as *shown to differ* |

The last row is the crux of the outcome. Under plan §3 and §4, an affirmatively violated condition gives **Not supported**; an unverifiable or indeterminate one leaves the judgment undetermined. This is the second case.

## Outcome and its consequences

**H-J1 — Inconclusive.**

What this outcome does mean:

- The retained Range B record does not establish, from committed bytes, that zero target alerts were produced in the canonical rule output index over the frozen window.
- Therefore the record does not carry the full set of observations the plan required before H-J1 could be judged Supported.

What it does **not** mean:

- It is **not** a finding that a target alert existed. No retained artifact shows one, and Range B's Collector stage — which is fully index-anchored — retains zero target documents, so there was no rule input to alert on.
- It is **not** a finding that the experiment was executed incorrectly. The gap is in one artifact's retention, not in the execution: the query was run, the selector and window were exactly the frozen ones, and the response is genuine.
- It is **not** a disconfirmation of the hypothesis, and it does not license any statement that the negative result *does* support detection performance.

Consequences for claim wording, carried forward to K7-6 and K7-8:

- No claim may state that Range B produced zero alerts *as an established observation*; the established observations are zero target **Collector documents** and an absent target **Sensor** request.
- The over-claim boundaries fixed for H-J1 continue to apply in full, and an Inconclusive outcome tightens rather than loosens them.
- Under `protocol/experiment-protocol.md` §3, a hypothesis that is not supported is retained as such and the claim is reduced to match: 「H-J1〜H-J4のいずれかが支持されなかった場合も、結果を保持し、CFP・スライドの主張を結果に合わせて縮小する。」

## What is not being done about it

Range B `k6-range-b-20260825-004` is **not** re-run, re-queried, re-scored, or supplemented. The plan and the governance constraints forbid reaching a claim by re-executing or repairing a retained record, and an Inconclusive outcome is a legitimate result to retain.

For future runs this is a retention requirement rather than a procedural change: the rule stage should retain the index or pattern the query was issued against, so that a zero is anchored the way Range B's Collector zero already is. That is recorded here as an observation for K7-7 limitations and for any later procedure work; it is **not** applied to K6 evidence.

## Retention asymmetry noted

Range A does not retain the unrelated interface's filter state after its run, so K7-1 reports `unrelated_filter_present_after: null` for Range A rather than `true`. This does not bear on H-J1, whose mutation requirements are Range B observations and are established there. It is recorded for K7-7 limitations as a retention asymmetry between the two runs.
