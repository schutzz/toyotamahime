# K6 Main Range C Static Validation Metadata

| Field | Value |
| --- | --- |
| Validation ID | `k6-range-c-20260825-001` |
| Scope | K6-3 static validation only. Range C was never provisioned. |
| Kakuriyo commit at validation | `9daa67fba66d3b04f8d6000fe3226b84733ab7f5` |
| K6 start boundary | `a772ea11b07b59208586846d76abe1d1841dddd9` |
| Amenonuboco pin | `v0.13.0` / `0378f8a32701b481e030f3db3d5f66ea471a4675` |
| Isolated worktree | disposable, detached at the pinned commit, clean before derivation |
| Result | `REJECT` / exit `1` |
| Required error names | `observability_contract.required_segments`; `sub_a_l2_lan` |
| Container execution | None. `docker compose up` was never invoked. |
| Python / pydantic / PyYAML | Python 3.10.11 / pydantic 2.12.5 / PyYAML 6.0.3 |

Range C is a static validation. It has no Ground Truth, Sensor, Collector or Rule
stage and carries no Experiment classification.

## Frozen contradiction

The negative asset was re-derived from the pinned base manifest
`manifests/power-grid-reference.yaml` (SHA-256 `013eb4b09b35f4d73c2d1a2c06f8bd49622a15685e42c65fd8e5cf451382e0b2`)
at `0378f8a`, by requiring a segment that instrumentation excludes:

* `instrumentation.exclude: [sub_a_l2_lan]`
* `observability_contract.required_segments: [sub_a_l2_lan]`

No K4 or K5 output was reused. The derivation is retained as
`negative-manifest/range-c-derived.patch` and the derived asset as
`negative-manifest/power-grid-reference.range-c-negative.yaml`, SHA-256
`60f9c43e7af171077b6999c8005dff2a1da6e2ff4c7a54ba811e857d78c228a3`.

Re-deriving independently from the pinned base reproduced the byte sequence the
K5 record also reports for this frozen asset. That is a cross-check, not a reuse:
the derivation read only the pinned base manifest, and no K4 or K5 artifact was
copied into this record or used to produce any part of it. The K5 record was
consulted for its retention schema and separately checked for integrity before
this validation; see `deviations.md`.

## Outcome

`validate` exited `1` and produced no stdout (SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`). The
retained stderr (SHA-256 `166340b10d3be58923921ed30bf398a46f85f69d3a31a50c2da4857ddeaae8da`) names the contract requirement and the
segment:

> `observability_contract.required_segments requires segment 'sub_a_l2_lan', but it is not in the computed observed-segment set`

The rejection is therefore the frozen contract contradiction, not a YAML syntax
error, a schema drift, a missing file, or any other failure mode. The outcome was
recorded as produced; it was not re-run or adjusted toward the expected result.

## Byte retention

`negative-manifest/` and `validator-output/` hold the exact bytes the validator
read and produced, including their CRLF terminators as written on the execution
host. They are pinned `-text -diff` in `.gitattributes` so that no EOL heuristic
can alter them between hashing and commit, and `hashes.sha256` therefore
describes the committed bytes as well as the validated ones.
