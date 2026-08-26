# Study 01 Dependency Freeze Record

**Study:** Study 01 — Negative Detection Result Reliability / Observability Validation  
**Status:** K3 dependency freeze initiated  
**Repository:** `schutzz/kakuriyo-cyber-range-research`  
**Date:** 2026-08-23

## 1. Purpose

This document records the software and environment dependencies that govern Study 01 experiments.

The purpose of the dependency freeze is to ensure that experiment results can later be traced to the exact Amenonuboco implementation, manifest schema state, container images, and host/runtime environment that produced them.

Study 01 MUST NOT implicitly follow Amenonuboco `main` after the dependency baseline is fixed.

## 2. Amenonuboco Baseline

The initial Study 01 baseline is the following Amenonuboco state:

| Field | Frozen value / rule |
| --- | --- |
| Repository | `schutzz/ot-range-amenonuboco` |
| Release version | `0.12.0` |
| Release date | `2026-08-22` |
| DOI | `10.5281/zenodo.22051216` |
| Baseline commit | `78fc17746b5d663fafec9dffe563d79fe9ea02b7` |
| Baseline commit message | `Merge pull request #9 from schutzz/release/phase12-tier4` |
| Manifest/schema version | No independent schema version is recorded; the schema is therefore bound to the baseline commit |
| Schema path | `platform/schema/` |
| Reference environment class | Local Docker engine / Docker Compose; published Amenonuboco evidence uses Docker Desktop |
| Verified Python range | Python 3.10–3.12 |

The baseline commit above is the Study 01 dependency reference unless this document is amended before protocol freeze.

## 2.1 K4 Generic Observability Contract Pin

The generic Observability Contract capability required by the frozen K4 Acceptance Criteria ([Freeze Decision Table §4](./freeze-decision-table.md#4-k4-black-box-acceptance-criteria)) is now released and pinned, per the [initial K4 dependency amendment](./amendments.md#amendment-001--initial-k4-dependency-pin).

| Field | Value |
| --- | --- |
| Release version | `0.13.0` |
| Release date | `2026-08-24` |
| DOI | None (no Zenodo archival was performed for this release) |
| Pinned commit | `0378f8a32701b481e030f3db3d5f66ea471a4675` (annotated tag `v0.13.0`, tag object `3dd846cee0b0abd7b908b0e138c67be9cccfe879`) |
| Pinned commit message | `Merge pull request #10 from schutzz/research/k4-observability-contract` |
| Feature / release-notes PRs | [#10](https://github.com/schutzz/ot-range-amenonuboco/pull/10), [#11](https://github.com/schutzz/ot-range-amenonuboco/pull/11) |
| Manifest/schema state | `platform/schema/` at commit `0378f8a` (extends the §2 baseline; the §3 schema binding rule applies identically) |
| Validator output format | `platform/cli.py validate <manifest>`: exit `0` and `valid: <path>` on stdout for acceptance; exit `1`, empty stdout, and an `error: ...` line on stderr naming `observability_contract.required_segments` and the affected segment for rejection. |
| K4 acceptance evidence | [K4-5 acceptance verification](../platform-acceptance/k4-observability-contract/acceptance/k4-5-acceptance-verification.md), [K4-6 genericity review](../platform-acceptance/k4-observability-contract/genericity-review/k4-6-regression-and-genericity-review.md), [K4-7 upstream return](../platform-acceptance/k4-observability-contract/upstream-return/k4-7-upstream-return.md) and [release](../platform-acceptance/k4-observability-contract/release/k4-7-release.md), [K4-8 dependency pin](../platform-acceptance/k4-observability-contract/kakuriyo-pin/k4-8-dependency-pin.md) and [static integration verification](../platform-acceptance/k4-observability-contract/kakuriyo-pin/k4-8-static-integration-verification.md) |
| Image/build provenance | None new — the K4 capability is a pure `platform/` CLI and schema change; it introduces no new runtime container image. The §2 baseline image/build provenance and [C2 DNP3 Selected-Scenario Image Inventory](./c2-dnp3-image-inventory.md) are unaffected. |

This pin does not change the §2 Amenonuboco Baseline used for Range A/B/C provisioning and runtime evidence; it adds the generic static-validation capability the frozen protocol required before Pilot.

## 3. Schema Binding Rule

Amenonuboco currently represents the manifest schema as Python modules under `platform/schema/` rather than as a separately versioned schema release.

For Study 01:

> **Manifest/schema state = the contents of `platform/schema/` at the frozen Amenonuboco commit.**

A later Amenonuboco schema change MUST NOT be consumed by Study 01 merely because it exists on `main`.

If Study 01 requires a schema or validator change, the dependency record MUST be amended and affected experiments MUST be evaluated for rerun.

## 4. Generic Capability Boundary

Kakuriyo MAY depend on generic Amenonuboco capabilities required by the experiment, such as:

- topology and manifest validation;
- instrumentation definitions;
- traffic mirroring support;
- collector/structuring support;
- generic static validation;
- generic runtime observability checks;
- range provisioning and diagram generation.

Study-specific experimental logic remains in Kakuriyo, including:

- Research Questions and hypotheses;
- Range A/B/C experiment definitions;
- Study-specific fault injection;
- Study-specific scoring/classification;
- evidence and analysis;
- publication assets.

Study 01-specific behavior MUST NOT be added to Amenonuboco solely to force an expected experimental outcome.

## 5. Runtime Environment Record

The following fields MUST be captured for each pilot and main experimental run. Values not yet measured remain explicitly unresolved until execution.

| Field | Required record |
| --- | --- |
| Kakuriyo commit SHA/tag | Required |
| Study 01 protocol version | Required |
| Amenonuboco commit SHA | Required |
| Amenonuboco release version | Required |
| Host OS and version | Required |
| Docker engine / Docker Desktop version | Required |
| Docker Compose version | Required |
| Python version | Required |
| Container image references | Required |
| Container image digests | Required when the image participates in experiment semantics/evidence |
| Experiment/run identifier | Required |
| Experiment timestamp | Required |
| Relevant generated artifacts | Required |

No placeholder runtime value is to be treated as observed evidence.

## 6. Container Image Freeze

The selected-scenario C2 inventory is canonical in [C2 DNP3 Selected-Scenario Image Inventory](./c2-dnp3-image-inventory.md). It fixes the semantically relevant image references, inspected digests or local image IDs, and build provenance available before K4 exists.

Before K3 Protocol Freeze, Study 01 MUST create an inventory for each semantically relevant selected-scenario image containing:

```text
logical role
image reference
image tag
image digest (sha256)
source/build provenance when applicable
```

Mutable tags such as `latest` MUST NOT be relied upon as the sole identifier for a frozen experimental dependency.

For the local DNP3 image, Study 01 uses the [build-input / provenance freeze model](./c2-dnp3-image-inventory.md#2-build-input--provenance-freeze-model). K3 freezes build inputs and their provenance, not an unsupported claim that one locally built artifact will remain bit-identical across future runs. Each Pilot/Main run must preserve its actual local image ID, effective image references, build-context hashes, and relevant provenance before the sender trigger. A build identity difference requires dependency/equivalence assessment and, when it can affect semantic behavior or runtime evidence meaning, the amendment log's `Rerun REQUIRED` or `Rerun ASSESS / PARTIAL` classification.

K4-specific release/commit and any newly relevant image/build identifiers are **Deferred by design** until the generic capability exists. They are not K3 values to invent. They must be added through the initial K4 amendment/dependency-change procedure before Pilot.

## 7. Dependency Change Procedure

After this dependency baseline is adopted, any change that could affect experiment semantics or evidence requires explicit review.

For a dependency change:

1. identify the old and new Amenonuboco commit/release;
2. record the reason for the change;
3. identify changed schema/validator/runtime behavior relevant to Study 01;
4. record the change in the Study amendment log;
5. determine whether pilot/main runs performed under the old dependency remain valid;
6. rerun affected experiments when required;
7. update this dependency record to identify the new authoritative state.

For the initial K4 pin, the prior frozen state may be recorded as **`Deferred by design / not yet available`**. The corresponding amendment records the research-state decision and rerun category; this dependency record records the exact version/tag/commit, validator output format, and affected image inventory. Study 01 MUST NOT begin Pilot until both records exist and the K4 acceptance criteria frozen in `protocol/freeze-decision-table.md` have passed.

Documentation-only changes in Amenonuboco that provably do not affect the experiment MAY be ignored by Study 01, but the experiment MUST continue to reference its frozen baseline rather than a later moving `main`.

## 8. K3 Exit Criteria

K3 dependency freeze is complete when all of the following are true:

- [x] Amenonuboco repository is identified.
- [x] Amenonuboco release version is identified.
- [x] Amenonuboco baseline commit SHA is identified.
- [x] Manifest/schema state is bound to the baseline commit.
- [x] Dependency change rules are defined.
- [x] Final Study 01 protocol identifies its Amenonuboco dependencies, including the deferred generic K4 Observability Contract capability.
- [x] Selected-scenario Range A/B image inventory and available digests/local image IDs are recorded before K3 Protocol Freeze; Range C is non-provisioned and has no runtime image.
- [x] K4 release/commit and K4-related images are recorded through the initial dependency amendment before Pilot.
- [x] Pilot execution environment versions are recorded.

### 8.1 Pilot execution environment

Accepted K5 Range A/B execution used PowerShell 7.6.5, Python 3.10.11, Docker 29.6.2 (`dfc4efb`), and Docker Compose v5.3.1. Runtime Range A/B used Amenonuboco `v0.12.0` / `78fc17746b5d663fafec9dffe563d79fe9ea02b7`; Range C static validation used the K4-pinned validator `v0.13.0` / `0378f8a32701b481e030f3db3d5f66ea471a4675`. Per-run image IDs and full Docker inspect output are retained in the accepted evidence trees.

The selected-scenario inventory is a K3 freeze blocker and must not be guessed or filled from unrelated Amenonuboco evidence. The K4-specific value is deliberately deferred only because the generic capability does not yet exist; it is a Pilot entry blocker rather than a K3 value.

## 9. Current Baseline Summary

```text
Kakuriyo Study 01
    ↓ depends on (Range A/B/C provisioning, runtime evidence)
Amenonuboco v0.12.0
commit 78fc17746b5d663fafec9dffe563d79fe9ea02b7
    ↓ binds
platform/schema/ at that commit
    ↓ also depends on (generic Observability Contract, K4)
Amenonuboco v0.13.0
commit 0378f8a32701b481e030f3db3d5f66ea471a4675
    ↓ runtime specifics added at pilot freeze
Docker/Python/image digests/environment metadata
```

This file is the authoritative Study 01 dependency record until superseded by a documented amendment.
