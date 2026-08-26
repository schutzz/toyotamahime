# Study 01 — K5 Phase 0 Scoring-Semantics Cross-Review

**Status:** Complete — resolved by `AMEND-002` before Pilot/Main evidence

## Scope and method

This record independently cross-checks Amendment 002 items #1–#6 against the K3 Protocol Freeze (`study-01-protocol-v1.0` / `9d57d1e63d6cf16dcc37e8f60d560d30da5f4835`). It does not redesign the study or evaluate Amendment items concerning evidence format or procedure.

| # | Disposition | K3 basis | Resolution |
| --- | --- | --- | --- |
| 1 | A — Clarification | `scoring.md` defines Invalid as preventing evaluation of “that run”; its Inconclusive row covers an unresolved mandatory stage, Ground Truth failure, or uncorrelatable evidence; the closing sentence requires a **demonstrated** observation-contract failure for Invalid negative. | Precedence is `Invalid run` → `Inconclusive experiment` → R1/R2. The mandatory evidence-chain stages are Ground Truth, Sensor input, Collector output, and Rule output; Runtime contract remains an R1/R2 condition, not a newly added stage. |
| 2 | B — Pre-Pilot semantic addition | `scoring.md` enumerates Rule `Error`, but no classification row matches it. | `Error` → `Inconclusive experiment`, except that an independently satisfied Invalid-run condition takes precedence. |
| 3 | A — Clarification | `scoring.md` assigns Range C `Not applicable` runtime fields and a static-contract / validator result; `evidence-schema.md` gives it no runtime evidence directories; `invariant-specification.md` says it is static-only and never provisioned. | Range C emits no Experiment classification. |
| 4 | B — Pre-Pilot semantic addition | K3 requires Range B `R-OBS-05 Pass` but does not map its failure to an experiment classification. | `R-OBS-05 Fail` → Runtime contract `Unresolved` → `Inconclusive experiment`; never `Invalid negative result`. |
| 5 | A — Clarification | `scoring.md` directly assigns evidence that cannot be correlated to Inconclusive; `freeze-decision-table.md` fixes the any-member Collector-hit correlation; `invariant-specification.md` requires Rule output tied to its Collector input. | An uncorrelatable Alert → `Inconclusive experiment`. |
| 6 | B — Pre-Pilot semantic addition | The empty sensor-capture → Unresolved rule is explicit only in the Range B fault procedure. | Apply the same liveness guard to Range A: completely empty capture without liveness evidence → Sensor `Unresolved` → `Inconclusive experiment`. |

## Consistency conclusion

The six resolutions are jointly total for their specified cases. They introduce no conflict with K3 and leave no result-dependent choice among Invalid, Inconclusive, or Invalid negative for these cases. The B items are explicitly new pre-Pilot semantics, rather than retrospective claims about K3.
