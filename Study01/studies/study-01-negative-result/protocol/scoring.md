# Study 01 — Scoring and Classification Draft

**Status:** Pre-freeze draft  
**Applies to:** Conditionally selected C2 DNP3 scenario

## 1. Required fields

Every evaluable run records these fields separately:

| Field | Values |
| --- | --- |
| Ground Truth | `Pass` / `Fail` / `Unresolved` / `Invalid` |
| Sensor input | `Pass` / `Fail` / `Unresolved` / `Invalid` |
| Collector output | `Pass` / `Fail` / `Unresolved` / `Invalid` |
| Rule output | `Alert` / `No alert` / `Error` / `Unresolved` / `Invalid` |
| Static contract | `Pass` / `Fail` / `Unresolved` / `Not applicable` |
| Runtime contract | `Pass` / `Fail` / `Unresolved` / `Not applicable` |
| Experiment classification | `Valid detection result` / `Invalid negative result` / `Inconclusive experiment` / `Invalid run` |

`Fail` means the predeclared criterion was evaluated and not met. `Unresolved` means the available evidence cannot support either conclusion. `Invalid` means a procedure deviation, simulated fallback, unusable capture, or similar condition prevents evaluation of that run.

## 2. Classification rules

| Conditions | Classification |
| --- | --- |
| Ground Truth Pass, Sensor Pass, Collector Pass, Runtime contract Pass, and Rule output is `Alert` or `No alert` | Valid detection result |
| Ground Truth Pass, Rule output is `No alert`, and Runtime contract Fail because a required target observation stage is absent | Invalid negative result |
| Any mandatory stage is Unresolved, or Ground Truth fails, or evidence cannot be correlated | Inconclusive experiment |
| Any required stage is Invalid because of a procedure deviation or unusable evidence | Invalid run |

The distinction between `Invalid negative result` and `Inconclusive experiment` is deliberate: the former requires positive Ground Truth and a demonstrated observation-contract failure; the latter lacks enough evidence to make even that causal classification.

## 3. Intended Range mappings

| Range | Expected Ground Truth | Expected runtime contract | Expected rule output | Expected classification |
| --- | --- | --- | --- | --- |
| A | Pass | Pass | Alert for the selected positive-control event | Valid detection result |
| B | Pass | Fail at target source-request observation stage | No alert | Invalid negative result |
| C | Not applicable; non-provisioned | Not applicable; static validator only | Not applicable | Static contract `Fail` / validator `REJECT` after K4 |

These are acceptance expectations, not observed Study 01 results. A divergent Pilot or Main Experiment outcome must be retained and classified under the rules above rather than changing the table silently.

## 4. Retry and timeout draft

- Resolve dynamic gateway interfaces by the expected gateway IP before capture; interface ordinal alone is not a valid selector.
- Use one trigger event per run and the 15-second operational settle bound before classifying target collector/rule absence. The pre-trigger guard, selector, amendment triggers, and bound limitation are canonical in the [Freeze Decision Table](./freeze-decision-table.md); this is not a measured latency percentile or maximum.
- A retry may follow only an `Invalid` or `Unresolved` run, must receive a new run ID, and must preserve the earlier run and its deviation record.
- A failed Ground Truth or static validation result is not deleted to obtain a more favorable outcome.

## 5. Freeze requirement

The field-level query selectors, correlation keys, and K4 acceptance semantics are defined in [Freeze Decision Table](./freeze-decision-table.md). This draft must not be retrospectively changed after Pilot results are seen without an amendment and rerun assessment.
