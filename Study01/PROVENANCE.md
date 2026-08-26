# Study 01 — provenance

Every file under `Study01/` was extracted from the private Kakuriyo research repository `schutzz/kakuriyo-cyber-range-research`, at commit **`f0df3e1`**, by reading **committed bytes** (`git show HEAD:<path>`) rather than a working tree. That distinction is not pedantic: hashing working-tree bytes that git then normalizes on commit is a failure this study hit three separate times, and it is why [`.gitattributes`](./.gitattributes) exists here.

[`provenance.json`](./provenance.json) is the machine-readable record: for each of the 71 extracted files it gives the Toyotamahime path, the Kakuriyo path, the **Kakuriyo blob id**, the SHA-256, the byte count, and whether the file carries CRLF.

## Verifying the frozen apparatus without access to Kakuriyo

The blob ids in `provenance.json` are git object ids, so they can be recomputed from the shipped bytes alone:

```powershell
git hash-object Study01/studies/study-01-negative-result/scripts/study01/frozen/semantics.py
```

The six files whose identity the study's own judgments rest on:

| File | Kakuriyo blob |
| --- | --- |
| `scripts/study01/frozen/semantics.py` | `4ae5f1f892df83b7911c9b958d2dcf79be6ffce9` |
| `scripts/study01/frozen/apparatus.py` | `d40c8708fdfee807a2f93a49ae3db6595ea3718e` |
| `scripts/study01/scorer.py` | `1a1132e6906c70dadff6f9bb590f38775f2f6733` |
| `protocol/scoring.md` | `191c1dcf6c507a17b7dc82911f1a047aa441dc88` |
| `protocol/experiment-protocol.md` | `41eda1688bf1821a7b60c0a1db0343080378dd64` |
| `scripts/study01/procedure_conformance.py` | `92bca65059358a28cd99d0d206fedc5e37776794` |

These are byte-identical to their state at the K6 start boundary `a772ea1`, at each accepted record's raw evidence commit, and at the Kakuriyo commit this kit was cut from. The judgments in [`claims/`](./claims/) verify that identity themselves and cite the same ids.

## Pinned external dependencies

| Pin | Value | How to obtain it |
| --- | --- | --- |
| Amenonuboco, range generation | `78fc17746b5d663fafec9dffe563d79fe9ea02b7` | fetchable by SHA from the public repository; see `README.md` §4.1 |
| Amenonuboco, contract validator | `v0.13.0` = `0378f8a32701b481e030f3db3d5f66ea471a4675` | public tag |
| Capture helper image | `corfr/tcpdump@sha256:3006b3bd9f041bf73f21e626b97cca5e78fd6ce271549ca95b8e6a508165512b` | pull by digest |
| Sender asset | SHA-256 `093FEFD5F1F36D715AAE4D7AB91DBAD2D7A93BFE212705D721C95B356A7C053B` | shipped; the preflight checks it |
| Kakuriyo K6 start boundary | `a772ea11b07b59208586846d76abe1d1841dddd9` | referenced by the judgments |

Both Amenonuboco pins were confirmed publicly reachable, anonymously, at extraction time.

## What was deliberately left behind

| Not extracted | Why |
| --- | --- |
| The evidence trees of the accepted runs — captures, queries, contract records | They are the *outputs* of the runs you are asked to reproduce. Their integrity manifests are shipped under `expected/` so you can see what a complete evidence tree contains. |
| Non-accepted attempts, Pilot records, and every review round | Kakuriyo history. They are not reproduction inputs, and none of them supplied evidence to an accepted record. |
| `scripts/study01/gate_b2.py`, `study01_gate_b2.py`, `study01_k6_index.py`, `study01_k7_normalize.py` and their tests | Post-run analysis tooling for the K6 equivalence check, the cross-range index, and the K7 normalization. None of it is needed to run or score a range, and `study01_k7_normalize.py` reads Kakuriyo-internal paths, so shipping it would ship a tool that cannot work here. |
| The K6 and K7 planning, review, and report documents | Kakuriyo carries the process record. What a reader needs to know about the conclusions is in `claims/`. |

The shipped `study01` package is therefore Kakuriyo's minus `gate_b2.py`. Every file that *is* shipped is byte-identical to its Kakuriyo counterpart.

## Cross-references inside `claims/`

The files in [`claims/`](./claims/) are the K7 outputs, shipped **verbatim**. They contain relative links written for Kakuriyo's directory layout, and those links do not resolve here. They were not rewritten, because rewriting them would mean the published judgments differ byte-for-byte from the accepted ones.

| Link target in `claims/` | Where it lives |
| --- | --- |
| `../../../../../docs/k7-analysis-claim-freeze-plan.md` | Kakuriyo — the plan that fixed the judgment rules before any judgment was made |
| `./README.md`, `./h-j*-judgment.md`, `./rq-synthesis.md`, `./limitations.md` | siblings in `claims/`, except `README.md`, which is the K7-1 observation normalization and stayed in Kakuriyo |
| `../range-a/…`, `../range-b/…`, `../gate-c/…` | Kakuriyo results directories |
| `../../../K6-*.md`, `../../../K7-*.md` | Kakuriyo study-root records |
| `protocol/…`, `scripts/…` | present here, under `studies/study-01-negative-result/` |

## Layout note

`Study01/studies/study-01-negative-result/` mirrors the Kakuriyo study root because the frozen apparatus pins the sender asset as a repo-root-relative path starting with that prefix, and frozen files may not be edited to make packaging tidier. `Study01/` is therefore the repo root as the apparatus sees it, which is also why `.gitattributes` sits at `Study01/.gitattributes` — the shipped test suite reads it from there to prove that finalized hashes survive a commit and a fresh clone.

A pleasant side effect: the literal commands printed in `protocol/` work verbatim when run from `Study01/`.
