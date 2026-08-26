# C2 DNP3 Step 5 — Range C Static Correspondence

**Study:** Study 01 — Negative Detection Result Reliability / Observability Validation  
**Candidate:** C2 — DNP3  
**Status:** Pre-execution static-correspondence procedure  
**Prerequisite:** C2 Step 4 Range B mirror-fault feasibility `Pass` (`c2-step4-20260823-001`)  
**Amenonuboco baseline:** `v0.12.0`, commit `78fc17746b5d663fafec9dffe563d79fe9ea02b7`

## 1. Purpose and boundary

This step maps the single runtime fault demonstrated in C2 Step 4 to a non-provisioned manifest-level contradiction. Range C expresses the same segment-level observation precondition/blind spot that affects the selected event in Range B; it does not statically validate or replay the concrete DNP3 event. It does not rerun traffic, provision a Range B environment, or retroactively alter the fixed baseline.

```text
Range B runtime fault
  remove only sub_a_l2_lan ingress mirror
        ↓
Range C declaration contradiction
  C2 request from sub_a_l2_lan is required observable
        +
  instrumentation excludes sub_a_l2_lan
        ↓
Expected generic validator result: REJECT
```

## 2. Promised observation property

The contract is deliberately stated at the boundary the static platform can reason about. It does **not** claim that static validation alone proves packet delivery, parser behavior, or rule execution.

| Property | Required declaration |
| --- | --- |
| Contract identifier | `c2-dnp3-source-request-observable` |
| Required segment | `sub_a_l2_lan` |
| Event scope | A DNP3/TCP request sent from `sub_a_ied_02` (`10.1.20.11`) to `cc_scada_master` (`10.1.10.10:20000`) |
| Static observation boundary | `sub_a_l2_lan` must be included in `instrumentation.observed_segments()` and mirror to `mirror_link`. |
| Runtime evidence still required | The C2 Ground Truth, sensor input, collector output, and rule output stages remain separate runtime checks. |

## 3. Negative manifest construction

The Range C asset is a patch against the exact pinned `manifests/power-grid-reference.yaml`, not a second hand-maintained copy of the complete Amenonuboco manifest. It is applied only in a disposable worktree, where that source file becomes the non-provisioned negative manifest. For the present Windows baseline, apply it with `git apply --ignore-space-change` because the checked-out YAML uses CRLF.

It performs exactly two semantic declarations:

1. changes `instrumentation.exclude` from `[]` to `[sub_a_l2_lan]`; and
2. adds an `observability_contract.required_segments` declaration naming `sub_a_l2_lan` and the required mirror target.

The first declaration is the static counterpart of Step 4's removed ingress mirror. The second makes explicit the observation premise that is otherwise only implicit in a detection experiment.

## 4. Expected decisions

| Validator state | Expected result | Interpretation |
| --- | --- | --- |
| Fixed v0.12.0 baseline | **Accept / no contract evaluation** | The baseline accepts a declared blind spot because `exclude` is a supported opt-out and has no Observability Contract schema or cross-layer check. This is evidence of a generic capability gap, not a Range C pass. |
| K4 generic capability | **Reject** | A generic validator must reject a required observed segment that appears in `instrumentation.exclude`, with an error naming the contract, segment, and exclusion. |

The negative manifest must never be provisioned. A baseline acceptance is recorded as an expected pre-K4 result; it must not be mislabeled as validation success.

## 5. Generic capability boundary

The needed capability is generic because it compares reusable concepts:

```text
declared required observation segment
    ↔ instrumentation observed-segment set / exclude list
```

It does not encode DNP3 addresses, `signal-1-zone-violation`, Study 01 scoring, or the C2 fault command. Those remain Kakuriyo-specific context and evidence. The eventual Amenonuboco schema/API name is not frozen by this Step 5 record; `observability_contract` in the negative asset is a proposed semantic representation for this evaluation, not a claim that the pinned baseline implements it.

## 6. Evidence to preserve

1. the negative patch and its base-manifest SHA-256;
2. the derived non-provisioned YAML SHA-256;
3. the exact baseline `provision` command and observed exit/result;
4. source references showing how baseline `exclude` is accepted and used to omit mirroring; and
5. the K4 classification and no-rerun decision for the already-collected Step 4 evidence.
