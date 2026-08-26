# K7-4 — H-J3 judgment

**Frozen hypothesis wording**, quoted verbatim from `protocol/experiment-protocol.md` §3:

> **H-J3:** 定義済みの観測矛盾は、Amenonubocoのvalidatorでdeployment前にrejectされる。

**Outcome: Supported.**

Judged against the accepted [K7 Analysis / Claim Freeze Plan](../../../../../docs/k7-analysis-claim-freeze-plan.md) §5 H-J3, using only admissible evidence: the accepted static validation `k6-range-c-20260825-001`, the [Gate C review](../../../K6-GATE-C-REVIEW.md) including its first-round provenance finding, and the [Gate C review-only reproduction](../gate-c/README.md). All six required observations are established from committed bytes, and no disconfirmation condition is met.

H-J3 is about **one defined contradiction, one pinned validator, one negative asset**. Supported licenses exactly that and nothing about validator completeness, soundness, or contradictions that were not tested.

## Required observations

| # | Required | Finding | Established |
| --- | --- | --- | --- |
| 1 | The negative asset embodies the **defined** contradiction, derived from the pinned base manifest, with the derivation retained | re-derived here from the pinned base and reproduced **byte-for-byte** (see below); `topology.segments` defines `sub_a_l2_lan`, `instrumentation.exclude` removes it, `observability_contract.required_segments` requires it | **yes** |
| 2 | `validate` was the only command invoked; no provisioning and no container execution | retained argv is `python platform/cli.py validate manifests/power-grid-reference.range-c-negative.yaml`; zero provisioning artifacts in the record; at the pin, `cmd_validate` calls `load_manifest` and nothing else — it writes no file and starts no container, `provision` is a separate subcommand, and even it never invokes `docker compose up` | **yes** |
| 3 | A non-zero exit — the rejection is real, not advisory | `exit-code.txt` is `1`; stdout is **0 bytes**, and at the pin the success path prints `valid: <path>` and returns `0`, so the success branch was provably not reached | **yes** |
| 4 | The rejection names the frozen contract requirement and the frozen segment, and is not a YAML syntax error, an `observability_contract` schema drift, an undefined segment, a missing file, or any other failure mode | the retained stderr carries both frozen strings and is traced below to one specific branch of the pinned validator — the contradiction branch, which is reached only *after* the segment is confirmed defined | **yes** |
| 5 | Validator provenance: the pinned `v0.13.0` / `0378f8a` with no tracked modification, established by primary pre-validation state, not by assertion | established by the Gate C review-only reproduction, which recorded `HEAD` at the pin with an empty `git status --porcelain` and an empty `git diff --stat HEAD` **before** the input was placed, retained per-file blob ids and digests for all ten validator files, and reproduced `001`'s stdout, stderr, and exit code byte-identically | **yes** — see the qualification below |
| 6 | Committed-byte integrity of the static record | 9/9 manifest entries verify against committed bytes, 0 mismatched | **yes** |

## The derivation, re-derived

Required observation #1 asks that the asset embody the **defined** contradiction and be derived from the pinned base. Rather than accept the record's own statement that it re-derived the frozen byte sequence, the derivation was repeated here from the pinned commit's own committed bytes, read by commit hash — not from any working tree.

```
pinned base, committed bytes (LF)   sha256 cf0e5a209abe4927db6f8090cb54fca5849f9e6d9bd99b6885c1b8b861e5a15e
same bytes with CRLF terminators    sha256 013eb4b09b35f4d73c2d1a2c06f8bd49622a15685e42c65fd8e5cf451382e0b2
                                           == the base digest the record cites
apply the one recorded substitution
re-derived negative manifest        sha256 60f9c43e7af171077b6999c8005dff2a1da6e2ff4c7a54ba811e857d78c228a3
                                           == the committed negative manifest, byte-for-byte
```

The substitution anchor `  exclude: []` occurs in the pinned base exactly once, as the derivation procedure required. The re-derived bytes are **equal**, not merely equal in digest, to the committed asset.

The two digests for the same base file are the study's own recurring failure class, not a discrepancy: the record hashed the CRLF bytes the validator actually read on the execution host, while git stores the file with LF. That is why `negative-manifest/` and `validator-output/` are pinned `-text -diff`, and it is why the committed bytes of this record are the validated bytes.

The contradiction in the derived asset, from committed bytes:

| Element | Location | Value |
| --- | --- | --- |
| the segment is **defined** | `topology.segments` | `- { name: sub_a_l2_lan, cidr: 10.1.20.0/24, kind: ot-l2 }`, referenced by two hosts |
| instrumentation **removes** it | `instrumentation.exclude` | `[sub_a_l2_lan]` |
| the contract **requires** it | `observability_contract.required_segments` | `- sub_a_l2_lan` |

## Why the rejection is the frozen contradiction and nothing else

The retained stderr is one pydantic validation error:

> `error: manifest manifests\power-grid-reference.range-c-negative.yaml failed validation:`
> `1 validation error for Manifest`
> `  Value error, observability_contract.required_segments requires segment 'sub_a_l2_lan', but it is not in the computed observed-segment set [type=value_error, ...]`

The pinned validator at `0378f8a`, `platform/schema/instrumentation.py`, raises two *different* messages from two *sequential* checks:

```python
for required_segment in contract.required_segments:
    if required_segment not in segment_names:
        raise ValueError("observability_contract.required_segments references undefined "
                         f"segment '{required_segment}'")
    if required_segment not in observed_segment_names:
        raise ValueError("observability_contract.required_segments requires segment "
                         f"'{required_segment}', but it is not in the computed observed-segment set")
```

The retained message is the **second**. The second is reachable only after the first has passed — that is, only after the validator has confirmed the segment *is* defined in `topology.segments`. So the undefined-segment failure mode is excluded by the validator's own control flow, independently of my reading of the manifest, and the two agree.

Each other excluded mode is excluded by a distinct property of the retained bytes:

| Excluded failure mode | Why it is excluded |
| --- | --- |
| YAML syntax error | the failure is a pydantic `ValidationError` on the `Manifest` model, which is reached only after the document has parsed |
| `observability_contract` schema drift | the error count is exactly **1** and its type is `value_error` — a validator raising `ValueError`, not a shape mismatch such as `missing`, `extra_forbidden`, or `list_type`. The `observability_contract` block itself conformed to the v0.13.0 schema |
| undefined segment | the validator's own earlier branch would have produced a different, distinguishable message; it did not |
| missing file | the manifest was loaded, and the error names the path it loaded |
| incidental mention of the segment | the message names the contract field *and* the segment *and* the observed-segment computation — it is the contradiction rule itself, not a message that merely mentions `sub_a_l2_lan` |

## Validator provenance, and its qualification

Observation #5 requires provenance established by **primary pre-validation state, not by assertion**. That is exactly the distinction the Gate C independent review raised as a first-round blocker, and the qualification belongs in this judgment rather than being smoothed over.

The `001` record alone does **not** establish it. Its `environment/versions.json` records `worktree_head: 0378f8a…` but `worktree_clean: false` — captured *after* the negative manifest was placed — and `validation-command.md` states the worktree was clean before derivation as prose. Neither is a primary pre-validation state.

The Gate C review-only reproduction closes that. It retained, as primary command output:

| Datum | Value |
| --- | --- |
| `git rev-parse HEAD` before anything was placed | `0378f8a32701b481e030f3db3d5f66ea471a4675` |
| `git status --porcelain` before anything was placed | empty |
| `git diff --stat HEAD` before anything was placed | empty |
| state immediately before the run | only `?? manifests/power-grid-reference.range-c-negative.yaml` |
| state after the run | unchanged — no tracked file modified |
| validator files | blob id at the pin **and** SHA-256 of the checked-out file, for all ten `platform/` files that ran |
| input | the committed `001` asset itself, `60f9c43e…`, not a re-derivation |
| output | exit `1`, stdout `e3b0c442…` (empty), stderr `166340b1…` — all three **byte-identical to `001`** |

So the pinned validator, demonstrably unmodified, produces exactly the bytes `001` recorded, from exactly the input `001` validated. Range C `001` was **not** re-run to obtain this; the reproduction is a review artifact under `results/main/gate-c/`, it replaces no Main record, and it carries no Experiment classification. The plan's "Evidence allowed" for H-J3 names it explicitly.

The version *label* is also bound: the tag `v0.13.0` in the Amenonuboco repository points at commit `0378f8a32701b481e030f3db3d5f66ea471a4675`. The operative identity throughout is the commit hash, which is what every artifact records.

## Disconfirmation conditions

None is met.

| Disconfirmation condition | Status |
| --- | --- |
| Rejection for any reason other than the defined contradiction, including a reason that merely mentions the segment incidentally | **not met** — traced to the contradiction branch of the pinned validator, with every alternative mode excluded above |
| Exit `0`, or acceptance followed by a runtime failure | **not met** — exit `1`, empty stdout, and the success path provably not reached |
| Any provisioning or container execution during the validation | **not met** — `validate` only; zero provisioning artifacts; at the pin `cmd_validate` writes nothing and starts nothing, and the reproduction's post-run worktree state shows no generated file |
| Validator provenance not established, or the validator differing from the pin | **not met** — established by primary pre-validation state in the reproduction, with per-file digests |
| The contradiction not actually present in the validated asset | **not met** — re-derived byte-for-byte and read directly from the validated bytes |

The **Inconclusive** condition — "the rejection reason is retained but cannot be attributed to the frozen contradiction from committed bytes" — does not apply: the reason is attributable to a single named branch of the pinned validator's source at the pinned commit.

## Outcome and its consequences

**H-J3 — Supported.**

What this outcome does mean:

- One defined observation contradiction — a topology segment simultaneously required by `observability_contract.required_segments` and removed by `instrumentation.exclude` — was **rejected before deployment** by the pinned Amenonuboco validator `v0.13.0` / `0378f8a`, with a non-zero exit and a rejection reason attributable to that contradiction.
- The rejection is genuinely pre-deployment: nothing was provisioned and no container ran, by the validator's construction as well as by the record.

What it does **not** mean, restating the plan's over-claim boundary:

- It does **not** establish "observation contradictions are rejected before deployment" as a general property. One contradiction shape was tested.
- It does **not** support any claim that the Observability Contract mechanism is novel. `protocol/experiment-protocol.md` §2 forbids asserting novelty without the prior-work delta table, and this judgment supplies no part of that table.
- It says nothing about contradictions that were not defined and tested.
- It says nothing about validator completeness, soundness, or absence of false negatives. No positive-control asset set was run in K6, so the false-rejection rate is uncharacterised; a validator that rejected everything would produce this same observation.

Carried forward to K7-6 and K7-8:

- H-J3 is the evidence base for **RQ-J2** only. Under the plan §6 it does not bear on RQ-J1, on H-J1, or on H-J4, and it must not be used to compensate for H-J1's Inconclusive outcome.
- Any RQ-J2 wording must carry "this one defined contradiction, this pinned validator" inside the claim itself, not in a footnote.

## Known limitations relevant to this hypothesis

Restated from the plan, unchanged: exactly one contradiction shape was tested; the validator is a pinned third-party dependency evaluated as a black box against one negative asset; no positive-control asset set was run in K6 to characterise false rejections. These go to K7-7 in full.

## What is not being done

Range C `k6-range-c-20260825-001` is not re-run, re-derived into the record, or supplemented. The re-derivation performed for this judgment is a verification computed from the pinned commit's committed bytes; it wrote nothing into any evidence tree, and the record's bytes are unchanged. Reading the pinned validator's source at `0378f8a` is likewise a read of a pinned external dependency by commit hash, not a change to the apparatus. H-J4, RQ-J1, and RQ-J2 are not judged here.
