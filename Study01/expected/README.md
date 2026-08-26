# Expected results

The comparison targets from the original runs. Read [`../README.md`](../README.md) §6 first — in particular §6.2, which asks you to derive your own scoring input **before** opening this directory.

| Path | What it is |
| --- | --- |
| `range-a/scoring-record.json` | what the frozen scorer returned for the accepted Range A run |
| `range-a/scoring-input.json` | the input it was given — a comparison target, **not** something to copy into your run |
| `range-a/hashes.sha256` | the accepted run's integrity manifest, 34 entries |
| `range-b/…` | the same three files for Range B, with 44 manifest entries |
| `range-c/` | the accepted Range C static validation in full: the derived negative manifest, the derivation, the command record, stdout, stderr, exit code, versions, deviations, and a 9-entry manifest |

The A and B manifests list artifacts that are **not** shipped — the captures, queries, and contract records those runs produced. They are here so you can see what a complete evidence tree contains and check that yours has the same shape.

## Range C is a validation outcome, not a third classification

Range A and Range B produce experiment classifications. Range C produces a validator exit code and its output. They are compared differently and must not be collapsed into one another.

Range C's comparison targets are byte-exact:

| Artifact | SHA-256 |
| --- | --- |
| `range-c/negative-manifest/power-grid-reference.range-c-negative.yaml` | `60f9c43e7af171077b6999c8005dff2a1da6e2ff4c7a54ba811e857d78c228a3` |
| `range-c/validator-output/validate.stdout` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` (empty) |
| `range-c/validator-output/validate.stderr` | `166340b10d3be58923921ed30bf398a46f85f69d3a31a50c2da4857ddeaae8da` |

Those three files are **CRLF**, as written on the original execution host, and `../.gitattributes` pins them so no end-of-line heuristic can touch them between hashing and commit. If you re-derive the manifest and get a different digest, check your line terminators before concluding anything: the pinned base manifest is CRLF in a checked-out worktree and LF as git stores it, and both digests are legitimate for different byte sequences of the same file.

## What must match, and what may differ

Summarised from [`../README.md`](../README.md) §6.1 and §6.3, which are authoritative.

**Must match:** both classifications, every stage outcome, the Range C validation outcome, procedure conformance, and the integrity of your own evidence against your own manifest.

**May differ:** timestamps, T0 and the derived window, container and network identifiers, interface ordinals, document ids, frame counts and frame numbers, pcap digests, and the exact nanosecond correlation deltas so long as each stays inside ±1,000,000 ns.

A run that matches the classifications but differs on a stage outcome, on procedure conformance, or on integrity has **not** reproduced this study. Matching classifications are not sufficient.
