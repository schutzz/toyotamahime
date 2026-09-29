# Study 01 — C2 DNP3 Collector and Rule Query Procedure

**Status:** Formal K8-3 correction basis — literal executable transcription of an already-frozen selector; no new research condition.

## 1. Gap this closes

[`freeze-decision-table.md`](./freeze-decision-table.md) §3 and [`evidence-schema.md`](./evidence-schema.md) §3 fix the frozen field-level selectors, index patterns, and required retained artifacts for the Range A/B target-event Collector and Rule stages, but no document published a literal, executable query an operator could run without synthesizing one from outside knowledge — the same class of executable-transcription gap already closed once for the Range A/B pcap decode command ([`c2-dnp3-capture-procedure.md`](./c2-dnp3-capture-procedure.md) §5.2) and once for Range C's execution authority (`Study01/README.md` §5.3).

Formal K8-3 attempt `k8-repro-20260929-001` found this gap at exactly this step — Range A provisioning, capture, sender invocation, and pcap decode verification (§5.1 steps 1–6) had all already passed — and closed `Failed` rather than inventing a query, per `Study01/README.md` §7. This document, `studies/study-01-negative-result/scripts/study01_query.py`, and `study01/frozen/collector-query.template.json` / `rule-query.template.json` are the fix.

**Provenance.** The frozen query bodies and the mechanism that executes them are not new: they are promoted, byte-for-byte and mechanism-for-mechanism, from the already-qualified `shakedown/tools/collector-query.template.json`, `shakedown/tools/rule-query.template.json`, and `shakedown/tools/K8ShakedownCommon.psm1`'s `Invoke-K8ElasticsearchRequest`. Shakedown itself remains out of formal-procedure authority (`shakedown/README.md`); this document is what gives the formal procedure its own, in-authority copy. No frozen event, selector, window, index pattern, evidence-schema path, or scoring rule changes.

## 2. Fixed data source and mechanism

| Item | Fixed value |
| --- | --- |
| Collector index pattern | `ot-logs-dnp3-*` |
| Rule index pattern | `ot-signals-zone-violation-*` |
| Query window | `[T0 − 5 seconds, T0 + 15 seconds]`, read from the run's own `metadata-t0.txt` |
| Transport | `docker exec <elasticsearch-container> curl ... http://localhost:9200/<endpoint>` — the run's own `elasticsearch` service, resolved by `docker compose ... ps -q elasticsearch`; never a host-published port |
| Collector request body | `study01/frozen/collector-query.template.json`, frozen selectors per [`freeze-decision-table.md`](./freeze-decision-table.md) §3 |
| Rule request body | `study01/frozen/rule-query.template.json`, frozen selectors per §3, `source_dnp3_doc_id` filtered against the Collector stage's own retained accepted hit IDs |

## 3. Canonical ordering and commands

Run after Range A/B's pcap decode verification (`c2-dnp3-capture-procedure.md` §5.2) and before evidence collection (`study01_collect.py`). The Collector query must run first: the Rule query reads its retained `accepted-collector-hit-ids.json` and refuses to run without it.

```powershell
python studies/study-01-negative-result/scripts/study01_query.py collector `
  --run-id <run-id> --run-evidence <run-evidence> --compose <range-a-or-b-compose.yml>
if ($LASTEXITCODE -ne 0) { throw 'collector query failed (transport/apparatus anomaly, not a negative scientific result)' }

python studies/study-01-negative-result/scripts/study01_query.py rule `
  --run-id <run-id> --run-evidence <run-evidence> --compose <range-a-or-b-compose.yml>
if ($LASTEXITCODE -ne 0) { throw 'rule query failed (transport/apparatus anomaly, not a negative scientific result)' }
```

Both subcommands retain, under `<run-evidence>/collector-output/` and `<run-evidence>/rule-output/` respectively:

- `<stage>-query.json` — the instantiated request body actually sent;
- `<stage>-response.json` — the complete raw response;
- `<stage>-http-status.txt` — the HTTP status curl reported; and, for the Collector stage only,
- `collector-output/accepted-collector-hit-ids.json` — every `_id` in the retained hit set, which the Rule query reads.

## 4. Pass condition and failure handling

**A well-formed response with zero matching hits is not a script failure.** `study01_query.py` exits non-zero only on a transport or apparatus-level anomaly: the `elasticsearch` container could not be resolved, curl or the response read failed, a non-200 HTTP status, an unparseable body, or — Collector stage only — a `hits.total` that is not a clean, unambiguous count (`relation` other than `eq`, `value` not equal to the retained hit count, or `value ≥ 10000`; see `freeze-decision-table.md` §3's "do not silently weaken the selector" instruction). Any of these is a kit/apparatus fault: record it and close the run per `Study01/README.md` §7, exactly as any other formal-command failure.

A clean, well-formed response — including zero hits — exits `0` and is retained as-is. Whether zero hits (or zero correlated Rule hits) makes the *run* `Pass`, `Fail`, or `Invalid` is `study01_score.py`'s decision under [`scoring.md`](./scoring.md), not this script's: Range B's Collector and Rule stages are *expected* to fail (`Study01/README.md` §6.1), and that expectation must reach the scorer as retained evidence, not be pre-judged here.

Collector Pass requires the retained hit set to be non-empty; a Rule Pass requires at least one retained Rule hit whose `source_dnp3_doc_id` is a member of the Collector stage's accepted hit-ID set (`freeze-decision-table.md` §3). Multiple matching Collector documents do not fail the criterion; retain the complete set.

## 5. Amendment assessment

This is an executable-transcription fix, not a semantic one: it fixes only which literal command performs an already-required, already-frozen query, using the request bodies and transport already qualified in Shakedown. It changes no frozen event, selector, window, index pattern, evidence-schema path, K4 criterion, or scoring rule, and requires no Protocol Amendment — the same classification `c2-dnp3-capture-procedure.md` §5.2 gives the pcap-decode command fix. `k8-repro-20260929-001`'s retained evidence and `steps.jsonl` are unmodified by this correction; this document did not exist when that attempt ran.
