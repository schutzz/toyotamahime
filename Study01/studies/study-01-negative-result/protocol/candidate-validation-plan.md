# Study 01 Candidate Validation Plan

**Study:** Study 01 — Negative Detection Result Reliability / Observability Validation  
**Status:** Pre-freeze execution plan — no candidate result recorded  
**Related records:** [Scenario Selection Record](./scenario-selection.md), [Dependency Freeze Record](./dependencies.md), [Experiment Protocol](./experiment-protocol.md), [Common Candidate Validation Procedure](./candidate-validation-common-procedure.md)
**Amenonuboco baseline:** `v0.12.0`, commit `78fc17746b5d663fafec9dffe563d79fe9ea02b7`

## 1. Purpose and Boundary

This plan defines how Study 01 will reduce the unresolved candidate judgments in `scenario-selection.md` using repository inspection and controlled pilot observations.

It does not select a protocol, create a frozen Range A/B/C specification, or establish a research result. A candidate becomes selected only through the final selection record and the K3 Protocol Freeze commit.

The evaluation order is:

```text
Modbus/TCP candidate validation
    → DNP3 candidate validation
        → worksheet update with evidence
            → comparison and selection decision
                → K3 Protocol Freeze
```

Range A, Range B, and Range C must remain variants of one selected communication event and one evaluated rule/analytic. They must not be implemented as unrelated protocol scenarios.

## 2. Baseline Handling

All inspection and pilot work must identify the Amenonuboco baseline commit rather than relying on the current working-tree `main`.

The evidence requirements and decision procedure for both C1 and C2 are fixed in [Common Candidate Validation Procedure](./candidate-validation-common-procedure.md). Protocol-specific commands may differ; the meaning and preservation requirements of the measurement do not.

| Rule | Required handling |
| --- | --- |
| Source inspection | Record the repository path and the baseline commit for every implementation claim. |
| Local setup | Use a worktree, detached checkout, archive, or equivalent mechanism that resolves to `78fc17746b5d663fafec9dffe563d79fe9ea02b7`. |
| Generic capability gap | Record it as a K4 candidate; do not silently test against a later Amenonuboco feature. |
| Runtime observation | Record actual image references, digests, Docker/Compose versions, Python version, host information, and run ID. |
| Candidate evidence | Keep source-inspection evidence distinct from runtime evidence. A readable source file does not prove runtime behavior. |

## 3. Candidate Evaluation Sequence

Apply the same sequence to C1 (Modbus/TCP) and C2 (DNP3). Do not begin a Range B fault injection before the corresponding Range A evidence path has been demonstrated.

### Step 0 — Baseline implementation inventory

Inspect the frozen Amenonuboco source for each candidate and record only facts found at the baseline commit.

| Check | Evidence to collect | Result category |
| --- | --- | --- |
| Manifest/topology representation | Relevant manifest, schema, generator, or test path | Available / unavailable / unresolved |
| Traffic generation or service endpoint | Relevant image, service, script, or fixture path | Available / unavailable / unresolved |
| Sensor and mirror placement | Instrumentation, mirror, interface, or topology path | Available / unavailable / unresolved |
| Collector/structuring path | Collector configuration and expected output path | Available / unavailable / unresolved |
| Candidate detection rule/analytic | Rule source, loading path, and expected output location | Available / unavailable / unresolved |
| Static validation extension point | Validator/schema path and current behavior | Existing / K4 candidate / unresolved |

This step may reject a candidate only when a mandatory requirement is demonstrably unavailable at the frozen baseline and no narrowly scoped K4 generic capability can address it.

### Step 1 — Range A connectivity and ground truth pilot

For each candidate that passes Step 0, run the smallest baseline-compatible normal scenario and record:

1. sender-side execution evidence of the intended communication;
2. an independent capture point on the communication path;
3. logical Host X, Asset Y, protocol, operation, and segment;
4. the precise condition that counts as a successful ground-truth event.

If sender evidence and independent capture disagree, classify the candidate as unresolved. Do not use sensor, collector, or rule output as a substitute for ground truth.

The independent capture MUST be taken on the actual communication path before traffic enters the mirror-delivery path: for example, at the sender, receiver, or routing gateway interface carrying the original traffic. A capture node attached only to `mirror_link` (including a `tap_observer` placed there) is observation-path evidence, not independent ground truth. Otherwise the Range B mirror fault and the proposed ground-truth source share a common failure mode.

### Step 2 — Range A observation-chain pilot

Using the same event from Step 1, verify each stage independently.

| Stage | Required observation | Failure meaning during candidate evaluation |
| --- | --- | --- |
| Sensor input | Target packet/flow/protocol input arrives at the specified sensor interface or capture point | Candidate cannot yet support a valid detection evaluation. |
| Collector output | Target-related artifact is emitted by the collector/structuring path | Collector-path design is incomplete or unresolved. |
| Rule output | Rule/analytic execution produces a recorded outcome, including an explicit no-alert outcome where applicable | Rule is not yet evaluable as a separate stage. |

A positive-control rule or equivalent input confirmation may be used to establish that traffic reaches the detection path. It must be recorded separately from the rule/analytic eventually used to interpret the Study 01 negative result.

### Step 3 — Detection-rule feasibility and positive control

Establish whether the candidate can support a deterministic evaluation of one rule or analytic.

- Record rule identifier, source/loading path, input preconditions, and output artifact.
- Test a positive control that confirms the target traffic reaches the detection path.
- Record whether the intended normal event produces an alert or no alert; neither outcome is interpreted as a Study result at this stage.
- Reject or defer the candidate if rule behavior cannot be tied to preserved input and output artifacts.

The purpose is not to select the rule that produces the most favorable result. The purpose is to ensure that later alert absence can be interpreted only after its input path has been independently verified.

### Step 4 — Range B fault feasibility

For a candidate with a complete Range A chain, propose one isolated observation-path fault.

The proposal must demonstrate, before adoption, that it can meet all of the following:

- the same semantic communication event remains present according to the Step 1 ground truth;
- only one observation-path condition changes relative to Range A;
- the selected fault is not a collector, parser, Elasticsearch, or equivalent obvious service stop;
- unrelated service/container health remains observable enough that the target-segment absence is not trivially explained;
- the expected missing stage is stated in advance: sensor input, collector output, or another specific observability condition.

This step may use a small controlled probe, but any probe result is candidate-selection evidence, not a Study 01 Range B result.

### Step 5 — Range C static correspondence

For the proposed Range B fault, identify a manifest-level contradiction that expresses the same semantic problem.

Record:

- the promised observation property (for example, an observable segment and its required sensor/collector path);
- the missing or contradictory declaration;
- the expected validator decision and error semantics;
- whether the frozen baseline already supports this check or whether it is a K4 generic-capability candidate.

Range C must remain a non-provisioned validation case. A runtime-only fault that cannot be expressed statically is not automatically disqualifying, but it must be documented as outside the static-prevention claim.

### Step 6 — Candidate classification and comparison

After Steps 0–5, update the candidate worksheet with evidence paths and classify each candidate.

| Classification | Meaning |
| --- | --- |
| Eligible | All mandatory criteria are evidenced; candidate can enter final scenario selection. |
| Eligible with K4 dependency | All research requirements are evidenced, but a specifically identified generic Amenonuboco capability is needed before protocol/pilot freeze. |
| Deferred | One or more mandatory criteria remain unresolved; no conclusion about unsuitability. |
| Rejected | A mandatory criterion demonstrably fails, with evidence and rationale recorded. |

Only after both C1 and C2 have completed this sequence may a candidate be selected. A missing or failed candidate remains part of the decision record.

## 4. Result and Evidence Recording Plan

Candidate evaluation is pre-protocol exploratory work, but its decisions must remain reconstructable. Store results using the following layout when execution begins:

```text
evidence/
  candidate-evaluations/
    c1-modbus/
      run-<id>/
        metadata.md
        ground-truth/
        sensor-input/
        collector-output/
        rule-output/
        environment/
    c2-dnp3/
      run-<id>/
        ...
analysis/
  candidate-evaluations/
    c1-modbus.md
    c2-dnp3.md
    comparison.md
```

No result file should be created with fabricated placeholder packets, logs, alerts, hashes, timestamps, image digests, or environment versions. Empty directories may be retained with `.gitkeep` until a real run produces evidence.

### 4.1 Per-run metadata

Each `metadata.md` must include:

| Field | Required value |
| --- | --- |
| Candidate ID and run ID | Unique identifiers |
| Kakuriyo commit | Exact commit at execution |
| Amenonuboco commit/release | Exact baseline or documented amended version |
| Protocol selection state | Candidate, not selected / selected after freeze |
| Host and runtime environment | OS, Docker engine/Desktop, Docker Compose, Python |
| Images | Reference, tag, digest, and build provenance when relevant |
| Command/procedure reference | Repository path and command log or script reference |
| Start/end time | Observed timestamps with timezone |
| Outcome | Observed result; unknowns remain explicit |

### 4.2 Candidate analysis summary

Each candidate analysis file must keep these sections separate:

1. source-inspection findings at the fixed baseline;
2. observed Range A ground truth;
3. observed sensor input;
4. observed collector output;
5. observed rule output;
6. Range B fault feasibility;
7. Range C static correspondence;
8. mandatory-criterion decision and unresolved points.

`analysis/candidate-evaluations/comparison.md` must compare C1 and C2 using the worksheet criteria and state why the chosen candidate was selected. It must preserve the non-selected candidate's evidence and rejection/deferment reason.

## 5. Decision Gates and Handoffs

| Gate | Entry condition | Output |
| --- | --- | --- |
| G1 — Inspection complete | Step 0 records exist for C1 and C2 | Candidate inventory with baseline paths and identified K4 gaps |
| G2 — Range A chain complete | Steps 1–3 evidence exists for a candidate | Four-stage evidence assessment and rule feasibility |
| G3 — Fault correspondence complete | Steps 4–5 are recorded | Range B fault proposal and Range C mapping |
| G4 — Scenario selection | Step 6 completed for C1 and C2 | Updated `scenario-selection.md` final selection record |
| G5 — K3 Protocol Freeze | All K3 protocol requirements are finalized | Tagged/committed protocol, invariant, scoring, and amendment state |

K2 literature work continues independently until its freeze conditions are met. Its status must not cause candidate evidence to be written as literature-supported novelty or prevent a candidate evaluation from recording an unresolved implementation fact.

## 6. Stop Conditions

Stop and record the reason instead of proceeding when:

- the work would require silently using an Amenonuboco commit later than the frozen baseline;
- ground truth cannot be separated from the evaluated sensor/collector path;
- the proposed Range B fault is a trivial service outage;
- Range A cannot preserve distinct sensor, collector, and rule artifacts;
- a needed generic capability has not been classified for K4;
- candidate evidence contains a secret, organizational identifier, or third-party material that cannot be retained or redistributed.

An unsuccessful candidate is a useful decision result. It must be recorded rather than discarded.

## 7. Execution-state authority

The canonical current execution state, latest confirmed results, and next action are maintained in [Study 01 Status](../STATUS.md).

This document defines the candidate-validation procedure, evidence requirements, decision vocabulary, and gates. It does not maintain a duplicate execution-state record. Record candidate-specific rationale in `analysis/` and observations in `evidence/`; update `STATUS.md` in the same commit as a completed step, candidate decision, amendment, or freeze.
