# Study 01 — Evidence Schema Draft

**Status:** Pre-freeze draft  
**Purpose:** Preserve the C2 evidence chain without collapsing Ground Truth, sensor input, collector output, and rule output.

## 1. Run directory

```text
evidence/
  pilot-runs/
    range-a/<run-id>/
      metadata.md
      environment/
      ground-truth/
      sensor-input/
      collector-output/
      rule-output/
      contract-output/
      hashes.sha256
      deviations.md
    range-b/<run-id>/
      ...
  main-runs/
    range-a/<run-id>/
      metadata.md
      environment/
      ground-truth/
      sensor-input/
      collector-output/
      rule-output/
      contract-output/
      hashes.sha256
      deviations.md
    range-b/<run-id>/
      metadata.md
      environment/
      ground-truth/
      sensor-input/
      collector-output/
      rule-output/
      contract-output/
      hashes.sha256
      deviations.md
  static-validations/
    range-c/<validation-id>/
      metadata.md
      negative-manifest/
      validation-command.md
      validator-output/
      hashes.sha256
      deviations.md
```

Pilot and Main Experiment records are intentionally separate. Range C is non-provisioned and belongs only under `static-validations/`; it contains the negative manifest, validation command/output, hashes, and deviations, and it has no runtime Ground Truth, sensor, collector, or rule artifact directories.

## 2. Mandatory metadata

Each run records, without placeholders:

- run ID, range, start/end time with timezone, and executor;
- Kakuriyo commit/tag and protocol freeze version;
- Amenonuboco release/commit and K4 release/commit where applicable;
- host OS, Docker engine, Compose, Python, and image inventory/digests;
- exact manifest source and generated artifact hashes;
- declared event, sender predicate, capture locations, filters, correlation keys, timeout, and cleanup result; and
- field-level score plus final classification from `scoring.md`.

The field-level selectors, event time window, and rule-to-collector correlation requirements are canonical in the [Freeze Decision Table](./freeze-decision-table.md). This schema defines retention, not an alternate query definition. In particular, a Collector `Pass` retains the complete matching-hit set; it is not an instruction to select one favorable document.

## 3. Stage artifacts

| Stage | Required retained artifact |
| --- | --- |
| Ground Truth | Sender stdout/stderr or structured sender record, original-path capture, and correlation verification. |
| Sensor input | Mirror-side pcap/log and a verification record for the target request. |
| Collector output | Raw query/response or immutable export containing every frozen-selector hit, plus the accepted matching-hit identifier set. |
| Rule output | Raw query/log export and `source_dnp3_doc_id` correlation to any member of the accepted collector-hit set when one exists. |
| Contract | Range A/B runtime-invariant record in `contract-output/`. Range C static-validator output is retained separately in `static-validations/range-c/<validation-id>/validator-output/`; static and runtime results remain separate. |

## 4. Integrity and retained failures

Every retained evidence file receives a SHA-256 entry after collection. Invalid, failed, empty, or hypothesis-disconfirming runs remain under their original run ID with their classification and deviation explanation. A retry is a new run and never overwrites earlier evidence.

## 5. Freeze and later-release requirements

The runtime/static path naming, hashing rule, selected-scenario image inventory, and per-run image capture rule are fixed for the K3 review. Permitted redaction procedure, public retention/release policy, and public-release review remain later K8/K10 work and are not implied by this private evidence schema.
