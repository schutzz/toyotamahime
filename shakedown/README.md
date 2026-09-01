# K8-3 Shakedown environment

**This directory is not part of the Study 01 reproduction kit.** Nothing under
`shakedown/` is read by `Study01/tools/Test-Study01Packaging.ps1`, nothing here
is fetched by `bootstrap/Start-Study01.ps1`, and no Shakedown run ever
allocates a `k8-repro-*` attempt ID. If you are trying to reproduce Study 01,
start at [`../Study01/README.md`](../Study01/README.md) instead.

## What Shakedown is

A disposable, debuggable workspace for walking **Setup → Range A → Range B →
Range C → evidence finalize/verify** once, end to end, on a Windows host,
*before* spending a formally certified, tagged K8-3 attempt on the same
runtime/packaging/operator-UX problems a clean VM would otherwise discover one
at a time.

Unlike a formal K8-3 attempt:

- Commands can be re-run.
- A failure can be debugged and fixed, then the whole sequence restarted at the
  fixed commit, rather than closing a formal attempt and starting over.
  (Note: inside a *qualification sequence* a terminated run is not resumed --
  see "Qualification sequences" below.)
- Nothing produced here is scored, judged for Gate K8, or written into
  Kakuriyo's `evidence/reproduction/`.
- A result that differs from `Study01/expected/` is retained as a Shakedown
  observation, not evaluated as a research outcome.

## What Shakedown is not allowed to do

- It does not modify anything under `../Study01/`. Every script here either
  calls Study01's own frozen CLI scripts (`study01_preflight.py`,
  `study01_capture.py`, `study01_sender.py`, `study01_collect.py`) unmodified,
  or reproduces a literal command already written in
  `Study01/studies/study-01-negative-result/protocol/*.md`, with only the run
  ID and paths substituted.
- It does not change fault conditions, sender conditions, the capture window,
  scoring semantics, the Range B experimental condition, or the Range C
  negative-manifest semantics. If a problem is found that can only be solved
  by changing one of those, the runner stops and the problem is reported for
  a human decision -- it is not "fixed" by this tooling.
- It does not write `scoring-input.json`. README §6.2 requires that to be
  transcribed by hand from evidence, derived before looking at `expected/`;
  auto-generating it would erase the exact discipline the study's own
  limitations analysis (`claims/limitations.md` R6) is about. It does emit a
  **template** (see "Scoring-input structural contract" below), which is
  deliberately not scorable: every judgment slot holds a placeholder, so the
  tooling cannot be read as having chosen a default.
- It does not decide whether an absence is acceptable. Where an observer finds
  nothing, the record now separates *what was observed* from *whether a frozen
  source permits it* -- but which of those two an absent index is remains
  frozen policy transcribed into the tooling, never a judgment made by it.
- It executes the fixed Elasticsearch requests and mechanical correlations,
  retaining the instantiated requests and full raw responses. It does not
  change selectors after seeing results or assign scientific scores.

## Qualification sequences

The first full Shakedown's three "qualification runs" turned out to span
*different* tooling commits, and nothing detected it. A **qualification
sequence** makes the single-HEAD, uninterrupted `A → B → C` property
machine-enforced instead of conventional.

`Start-K8QualificationSequence.ps1` records, once:

| field | meaning |
| --- | --- |
| `sequence_id` | which sequence this is |
| `locked_head` | the exact commit it commits to |
| `started_utc`, `initial_tree_clean` | when, and that the tree was clean |

`sequence_id` and `locked_head` are deliberately **separate facts**. Every run
independently records the `tooling_head` it actually ran under, and the gate at
the start of each run compares the two, re-reading git at that moment rather
than trusting a stored value. Binding the HEAD into the ID would make them
indistinguishable and leave nothing to check.

The sequence also enforces the order: a run starts only if it is the range the
sequence expects next and no other run is active.

**A terminated run ends its sequence.** There is no retry inside the same
sequence and no resuming a failed run. The only way forward is
`Close-K8QualificationSequence.ps1 -Reason '...'` → fix → *new* sequence →
restart from Range A. Close before fixing: opening a sequence locks whatever
HEAD is checked out.

Reaching `status = complete` stamps `completion_claim = "c-2b-sequence-valid"`,
which means exactly one thing — an uninterrupted `A → B → C` at one locked HEAD.
It is **not** a K8-S2 authorization.

### Control plane vs. scientific evidence

These are kept strictly apart:

```text
<workspace>/sequences/<sequence_id>.json    what the sequence committed to
<workspace>/sequences/current.txt           pointer to the live sequence
<workspace>/run-records/<run_id>/           provenance, termination, captured streams
<workspace>/runs/<run_id>/                  the scientific evidence tree
```

`run-provenance.json` is written to `run-records/` the moment a run ID is issued
— before any scientific or runtime step — and mirrored, byte for byte, into the
evidence tree as soon as the frozen `evidence_tree.create()` has made it. It
goes at the tree *root*: the frozen preflight requires the eight schema
directories to be empty, and the root is what `finalize-evidence` hashes.

A **termination record** is written only to `run-records/`, never into the
evidence tree. After `finalize-evidence` has hashed a tree, any file added to it
would leave that tree permanently inconsistent with its own `hashes.sha256`.

A termination record carries `stage`, `failure_kind`, `timestamp`, `message`,
`exception`, `tooling_head` and `sequence_id` always — and `argv`, `exit_code`
and the retained streams **only when the failure actually came from an external
command**. A gate that failed on a missing artifact, a `ValueError` on a
successfully-retrieved response, a zero-row decode or a completeness assertion
has no argv and no exit code, and none is invented for it. Where the capturing
helper merged the streams, the transcript is recorded as `combined_output` — not
as `stdout`.

## Two-phase Range A/B

`Run-K8ShakedownRange{A,B}.ps1` provisions the range, waits for readiness,
captures the image inventory and runtime-contract observation, resolves the
gateway interface, (Range B) applies the fault, captures, fires the one sender
trigger, executes the fixed queries, and retains mechanical correlations. It
then leaves the range running for `Complete-K8ShakedownRange.ps1 -Range a`
(or `b`), which validates and hashes before teardown, destroys the project,
records cleanup, re-hashes, and verifies integrity.

This split exists because `study01_collect.py validate-evidence` requires a
real retained file in every one of `ground-truth/`, `sensor-input/`,
`collector-output/`, `rule-output/`, and `contract-output/` -- and because
`evidence-schema.md`'s own cleanup ordering requires every required artifact
to be exported *before* the project is torn down. Tearing the range down
before live evidence was retained would make it permanently unobtainable.
`Complete-K8ShakedownRange.ps1` refuses teardown if any required automated
artifact or Range B R-OBS-05 gate is missing or failed.

## Artifact completeness, per stage

Every artifact a run is required to retain is declared once, in
`$script:K8ArtifactContract` (`tools/K8ShakedownCommon.psm1`), with the stage
that produces it and the ranges it applies to. There is no second list.

- **Leaving a stage checks that stage.** `Set-K8ShakedownRunStage` asserts the
  outgoing stage's artifacts before the next stage begins, so a missing file
  stops the run at the stage that owed it rather than several stages later.
- **The end-of-run gate reads the same contract.** It is defense in depth: if
  it ever reports something the stage gates let past, that is a regression
  defect in the stage gates, not a requirement discovered late.
- **Legitimate absence is never expressed by omitting an artifact.** It is
  recorded *inside* the artifact (`absence_admissible`), so "we observed
  nothing, admissibly" and "we retained nothing" stay distinguishable.

Range C has its own `evidence-init` stage so that `run-provenance.json` has a
real producer stage in all three ranges rather than a per-range exception, and
its completeness gate runs **before** the sequence is advanced.

Range C's scope here is the Shakedown §5.3 execution-retention contract only.
It is **not** the frozen `evidence-schema.md` static-validation package shape
(`static-validations/`), and nothing claims it is.

## Retained command observations

Every Shakedown-owned command whose output is retained as an observation also
gets a structured `<artifact>.observation.json` beside its existing text
artifact -- same capture instance, no re-parsing of the text, and no new `.txt`
files. Each record states its `capture_semantics`:

| | what it means |
| --- | --- |
| `separated` | stdout and stderr really were captured apart and are described as themselves |
| `combined` | `2>&1` merged them; `stdout`/`stderr` are `null`, because per-stream emptiness is unrecoverable and will not be invented |
| `file-backed` | the producer redirected each stream straight to a file; the descriptors hash those files' raw bytes |

A zero-byte stream is retained and described, never skipped: Range C's empty
`validate.stdout.txt` is the frozen *expected* observation, so it must exist as
a file with a stated byte count and hash.

## External command contract

Every call site that starts an external process has one row in a single
declarative table, `$script:K8CommandContract`. A row names the site
(`source_file`, `producer_scope`, `callee`, `call_ordinal`), the argv shape it
is allowed to run, the streams it captures, and the exit codes it accepts.

Rows fall into three classes, decided by **what the call site is responsible
for** -- not by whether the command is internal or external:

| class | when | what it carries |
| --- | --- | --- |
| `F` frozen-governed | a specific frozen document governs the command's scientific or artifact-acquisition semantics | `governing_sources`: an array of frozen paths, each with a pinned SHA-256 and a human-readable clause |
| `C` control-plane | readiness, discovery, orchestration, internal tool CLIs | an observation contract only -- **no** `governing_sources`, because declaring a frozen basis that does not exist would fabricate authority |
| `I` informational | version and environment provenance that never gates anything | `accepted_exit_codes = $null`, meaning explicitly *not gated* |

### Two facts, never inferred from each other

`source_identity_match` asks whether the frozen document this contract was
written against is still the same bytes. `contract_conformance` asks whether
the implementation still matches its **own** declared contract. Both being true
means only this:

> the implementation matches a contract that was authored against a document
> which has not changed.

Whether that contract *transcribes the document correctly* is a human
judgment. It is recorded, never derived. Treating `source_identity_match` as
evidence of frozen conformance would reproduce SD-11 -- using a different
procedure's command while believing oneself compliant -- with machine
authority behind it.

The frozen prose is never parsed at runtime. Only the file's SHA-256 is
compared, because a prose parser would itself become a new semantic
interpreter, which is the thing being removed.

### Exit codes have no default

There is no module-wide acceptance domain, and `Invoke-K8ShakedownCommand` no
longer takes `-AllowExitCodes`. A default of `@(0)` would hand every call site
the receipt condition "non-zero is failure", which no frozen source states and
which is wrong in **both** directions here:

| site | domain | why |
| --- | --- | --- |
| `F-35` Range C validator | `@(0, 1)` | exit 1 is the frozen *expected* rejection; exit 0 is the scientific observation that the apparatus did **not** reject the negative manifest. Neither is a tooling error -- only `>=2` is. |
| `C-54` / `C-55` `git rev-parse HEAD` | `@(0, 128)` | 128 means an unborn HEAD from an interrupted checkout, and the `else` branch answers it correctly with a fresh clone. |
| readiness probes | `poll-any` | inside a deadline-bounded loop a non-zero exit is the ordinary "not ready yet"; the gate is the loop deadline, which still fails closed on timeout. |

What `accepted_exit_codes` bounds is *"the command ran and returned a
CLI-meaningful result"* -- never *"the science passed"*.

### Version values are retained, availability is gated

No frozen source pins a tool version, so no version is ever an acceptance
condition. Five host probes (`C-56`..`C-60`) additionally gate on the tool
being **executable**, which is a different fact and one the tooling already
enforced. `wsl` (`I-05`) is optional and continues on failure.

Container-internal tools split by how they are supplied: `curl` and `tcpdump`
come from pinned images and are fixed by image identity, while `tshark` and
`ip`/`tc` are installed by `apt-get` at container startup and are **not** --
so they are observed per run (`I-07`, `I-08`) and recorded as provenance only.

### Caller roles

One process site can serve several scientific roles. `Invoke-K8TsharkFieldDecode`
produces a byte-identical argv for both of its callers, and in the code both
hold their pcap in a variable called `$pcap`; only the **provenance** of that
value differs. So caller-role rows bind to the assignment's origin
(`artifact_provenance_anchor`), not to a name and not to a blacklist of the
wrong artifact. That is the layer SD-13 lives in.

## Narrative artifact references

Where a generated narrative (`metadata.md`, `deviations.md`,
`runtime-contract-record.md`) names an artifact, that reference arrives as a
typed value and is checked before the sentence is written. Nothing scans prose
for path-shaped text -- measured, a naive path regex produced four false
positives on a healthy run.

| kind | checked? |
| --- | --- |
| `run-local` | must resolve inside the run evidence and exist |
| `frozen-protocol-doc` | must be inside the allowlist below and exist |
| `in-container`, `host-path` | recorded as-is; not resolvable from here |
| anything else | fails closed |

The frozen-protocol-doc allowlist is one **exact file**, `Study01/README.md`,
plus one **directory**, `Study01/studies/study-01-negative-result/protocol/`.
They are held apart on purpose: a single list forces one comparison to serve
both, and the only comparison that works for a directory -- a prefix test -- is
wrong for a file, since `Study01/README.md` would then also admit
`README.md.bak`, `README.md.tmp` and `README.md/anything`. `..`, `.`, empty
segments and absolute paths are refused before any path is built, so a spelling
like `.../protocol/../scripts/study01_collect.py` -- which begins with the
allowlisted directory as a *string* while naming a file in the frozen
apparatus -- cannot reach the allowlist at all. Both kinds are then re-checked
against the canonical resolved location, so string matching is never the whole
authority. Widening the allowlist is a Plan revision, not a code change.

## Scoring-input structural contract

`tools/k8_scoring_input_contract.py` is the single source of truth for the
shape of a Range A/B `scoring-input.json`. Frozen value domains are imported
from `study01/frozen/semantics.py`; the presence rules, derivation addressing
and token domains are Batch 2 structural additions. The template, the
validator, and the regression tests are all derived from it.

After `Complete-K8ShakedownRange.ps1` finishes, it writes an intentionally
incomplete template into the run's control-plane record directory and prints
the command to check your completed file. That check is **shape only**:

- every field the frozen scorer will read is present for this Range;
- every value is inside its frozen (or contract-fixed) token domain;
- every such field records which artifact it was read from and what value was
  read, and that recorded value matches the input;
- that artifact exists, is inside the run evidence, is covered by the finalized
  integrity manifest, still hashes to what the manifest says, and the manifest
  itself is the one that actually passed `verify-integrity`.

Whether you read the artifact *correctly* is not checked and cannot be: that is
the judgment README §6.2 reserves for you. The tool never opens `expected/`.

One token is deliberately refused: `"r_obs_05": "Unresolved"`. It is a valid
R-OBS-05 *query outcome*, but no frozen source fixes what it propagates to in
scoring -- the frozen scorer special-cases only `== "Fail"` -- so accepting it
would let a structurally valid input carry a value the scorer silently ignores.
It is retained in the observer record instead, and the scoring value is yours
to resolve.

## Layout

```text
shakedown/
├─ README.md                                  <- you are here
├─ tools/
│  ├─ K8ShakedownCommon.psm1                   <- pinned constants + shared functions
│  ├─ Start-K8QualificationSequence.ps1        <- opens a sequence and locks the tooling HEAD
│  ├─ Close-K8QualificationSequence.ps1        <- the only way out of a live sequence
│  ├─ Start-K8Shakedown.ps1                    <- Setup
│  ├─ Run-K8ShakedownRangeA.ps1                <- phase 1: provision through capture/trigger; leaves the range UP
│  ├─ Run-K8ShakedownRangeB.ps1                <- same, + the fault
│  ├─ Complete-K8ShakedownRange.ps1            <- phase 2: pre-hash + teardown + cleanup re-hash/verify
│  ├─ k8_shakedown_evidence.py                  <- mapping, hit-ID, and integer-ns correlation checks
│  ├─ k8_scoring_input_contract.py              <- ONE source for the scoring-input template, validator and tests
│  ├─ Run-K8ShakedownRangeC.ps1                <- Range C is one script; no live-query dependency
│  ├─ collector-query.template.json            <- frozen target-event Collector query, T0 substituted at runtime
│  ├─ rule-query.template.json                 <- frozen target-event Rule query, T0 substituted at runtime
│  └─ r-obs-05-query.template.json             <- frozen R-OBS-05 (Range B) query, T0 substituted at runtime
├─ tests/
│  ├─ Test-K8ShakedownRegression.ps1           <- repo-side checks, see below
│  └─ k8_synthetic_evidence_tree.py            <- test fixture: a Range A/B tree the FROZEN collector accepts
└─ operator/
   └─ shakedown-commands.txt                   <- copy/paste reference; calls the scripts above, does not restate their contents
```

Pinned values (Amenonuboco commits/tag, tcpdump digest, sender asset SHA-256)
live in exactly one place, `tools/K8ShakedownCommon.psm1`, copied by hand from
`Study01/README.md` §4.1/4.2 and the `protocol/` documents it cites. If those
pins ever change, `K8ShakedownCommon.psm1` must be re-copied by hand; it does
not scrape the README at runtime, so that a run always pins to a value a human
read and committed.

## Workspace

Everything Shakedown writes lives under `C:\K8\shakedown\` by default
(override with `$env:K8_SHAKEDOWN_ROOT`), entirely separate from
`C:\K8\attempts\` (the formal K8-3 attempt harness's workspace). The two must
never be confused, and Shakedown never writes into `C:\K8\attempts\`.

## The cp932 dependency-install fix

`Study01/studies/study-01-negative-result` evidence
(`k8-repro-20260828-001-v4` in Kakuriyo) recorded
`pip install -r amenonuboco-v0.13.0/requirements.txt` failing with
`UnicodeDecodeError: 'cp932' codec can't decode byte 0x81 in position 39` on
clean Windows. This was root-caused (not assumed) against the real pinned
`requirements.txt` and the real `pip 23.0.1` recorded in that evidence: pip
23.0.1's requirements-file decoder falls back straight to
`locale.getpreferredencoding(False)` with no UTF-8 attempt when a file has
neither a BOM nor a PEP263 `# coding:` line, and that call returns `cp932` on
a Japanese-locale Windows host. Setting `PYTHONUTF8=1` makes that same call
return `UTF-8` instead, on any pip version, without upgrading pip and without
touching Amenonuboco's `requirements.txt` or its pin.

Verified end to end on a real Japanese-locale Windows host, with the real
`amenonuboco-v0.13.0/requirements.txt` bytes and a real `pip 23.0.1`: the
unmodified `pip install -r requirements.txt` fails with the exact recorded
error without the fix, and succeeds (resolving `pydantic`/`PyYAML` from the
unmodified file) with `PYTHONUTF8=1` set. See
`Install-K8RangeCDependencies` in `tools/K8ShakedownCommon.psm1` for the
implementation and full reasoning, and
`tests/Test-K8ShakedownRegression.ps1` for the regression test.

## Residual manual steps

Even once Shakedown completes end to end, these remain manual by design (see
"What Shakedown is not allowed to do" above):

1. `scoring-input.json` for Range A and Range B (README §6.2), including the
   scientific interpretation of retained mechanical evidence. A structural
   template is emitted for you and a shape-only validator is available (see
   "Scoring-input structural contract"), but neither supplies a value, and
   both refuse to run against `expected/`.
2. Resolving any `r_obs_05` outcome the frozen sources do not map to a scoring
   token. The observer record retains what was observed; the scoring value is
   yours.

## Source identity, and where a bundle goes afterwards (C-9)

`Get-K8ToolingIdentity` used to observe HEAD and whether the worktree was
clean. Neither says the commit was ever published, and a qualification
sequence is the act of *locking* a HEAD -- so it now also observes whether
that HEAD is an ancestor of the pinned ref on the canonical remote.

The answer is three-valued and stays that way:

    confirmed        published there
    not-an-ancestor  observed, and it is not
    not-observed     the remote could not be observed at all

The last two both STOP at sequence open, and there is no override. "Let it
through offline" is the same request as "open a qualification sequence on a
commit that exists only on this disk". Sequence open is also the first command
you run after cloning or pulling, so having no network at that moment is not
the ordinary case.

Two details that look like implementation trivia and are not:

* The canonical **repository** is pinned, not just the ref. Ancestry alone
  would only prove HEAD is an ancestor of *some* remote's ref -- add a local
  remote and it is trivially true. You may choose the remote NAME; what counts
  as the right repository is not a per-run choice.
* `git ls-remote` runs before `git fetch`, because a fetch returns 128 both
  when the ref is missing and when the host is unreachable (measured). Those
  are different answers and the run must not lose the difference.

The observation is recorded once per sequence and mirrored into every run's
evidence tree as `source-identity.txt`, before `finalize-evidence`, so the
manifest covers it.

### Transfer bundles

    .\tools\New-K8TransferBundle.ps1 -RunId <a>,<b>,<c> -Destination <dir> -BundleId <id>

This exists because of RT-01: the first bundle verified 423/423 against the
bytes as collected and 97 OK / 326 MISMATCH against the bytes git actually
commits. It was closed by a person noticing and hand-adding a
`.gitattributes`; nothing made the next transfer get checked at all.

What the assembler does: copies the selected runs (pcap bodies excluded --
their hashes travel in each run's own `pcap-hashes.sha256`), checks that the
selection is one *completed* sequence at one locked HEAD covering a/b/c
exactly once, and writes `transfer-manifest.json` with each file's SHA-256 and
its **byte class** (`contains_cr`, `contains_nul`, `trailing_newline`).

What it deliberately does not do: write a `.gitattributes`, or tell the
consumer what its retention policy should be. "This file contains CR" is a
fact about the producer's own bytes. "Therefore mark it `-text`" is the
consumer's decision, and building it in here would make this repository
depend on how another one stores things.

`README.md` and `.gitattributes` are left for you; the script prints what is
still owed rather than authoring either. Verification of the transferred bytes
happens on the consumer side and is not part of this repository.

### Range C now has an identity mechanism

Range A/B carry `hashes.sha256` from the frozen `finalize-evidence`. Range C
has no such producer and had nothing at all, so it now writes
`shakedown-retention.sha256` over the artifacts its C-6 contract declares.

It is not named like the frozen manifest on purpose, and it is not a claim to
satisfy `evidence-schema.md`'s static-validation package shape. The manifest
is a *required artifact* and is *not in its own hash domain* -- two different
memberships, which is what makes the obvious circularity disappear rather than
having to be worked around.

### The frozen-path check no longer uses a moving ref

Criterion 11(a) asks for a byte comparison against a fixed immutable base. The
check that existed compared against a moving branch and silenced its own fetch
failure, so a failed fetch compared against an arbitrarily old ref and still
passed. It now compares against a pinned commit, resolved locally with no
network call, and the pin itself is checked (a real commit object, and an
ancestor of HEAD -- an unrelated commit with coincidentally identical frozen
paths is not a base).

## Status

Development in progress on branch `shakedown/k8-automation`. No formal
release/tag has been cut from this branch, and `k8-bootstrap-v4` (the current
formal, certified bootstrap) is untouched. Promotion of anything here into the
formal reproduction package is a separate, later decision made after
independent review of a completed Shakedown run.
