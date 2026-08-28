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
- A failure can be debugged and fixed mid-run, then resumed from where it
  stopped, rather than closing the attempt and starting over.
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
  limitations analysis (`claims/limitations.md` R6) is about.
- It does not execute the target-event Collector query, the Rule query, or
  (Range B) the R-OBS-05 query against Elasticsearch. These are queries
  against live data whose raw response IS the retained evidence
  (`evidence-schema.md` §3) -- not something a script can fabricate. The
  runner writes each frozen query with `T0` substituted to `environment/` for
  copy/paste, and leaves the range **running** so they can still be executed
  when you get to them (see "Two-phase Range A/B" below).

## Two-phase Range A/B

`Run-K8ShakedownRange{A,B}.ps1` provisions the range, waits for readiness,
captures the image inventory and runtime-contract observation, resolves the
gateway interface, (Range B) applies the fault, captures, and fires the one
sender trigger -- then **stops with the range still running** and prints the
Collector/Rule (and Range B: R-OBS-05) queries to run against Elasticsearch
by hand. Only after you save those raw responses into `collector-output/`,
`rule-output/`, and (Range B) `contract-output/` do you run
`Complete-K8ShakedownRange.ps1 -Range a` (or `b`), which tears the range down
and runs `validate-evidence` / `finalize-evidence` / `verify-integrity`.

This split exists because `study01_collect.py validate-evidence` requires a
real retained file in every one of `ground-truth/`, `sensor-input/`,
`collector-output/`, `rule-output/`, and `contract-output/` -- and because
`evidence-schema.md`'s own cleanup ordering requires every required artifact
to be exported *before* the project is torn down. Tearing the range down
automatically, before those two live queries could be run, would make
target-event Collector/Rule evidence permanently unobtainable for that run.
`Complete-K8ShakedownRange.ps1` refuses to proceed (no teardown, no finalize)
while `collector-output/` or `rule-output/` is still empty.

## Layout

```text
shakedown/
├─ README.md                                  <- you are here
├─ tools/
│  ├─ K8ShakedownCommon.psm1                   <- pinned constants + shared functions
│  ├─ Start-K8Shakedown.ps1                    <- Setup
│  ├─ Run-K8ShakedownRangeA.ps1                <- phase 1: provision through capture/trigger; leaves the range UP
│  ├─ Run-K8ShakedownRangeB.ps1                <- same, + the fault
│  ├─ Complete-K8ShakedownRange.ps1            <- phase 2: teardown + finalize, AFTER you save the query responses
│  ├─ Run-K8ShakedownRangeC.ps1                <- Range C is one script; no live-query dependency
│  ├─ collector-query.template.json            <- frozen target-event Collector query, T0 substituted at runtime
│  ├─ rule-query.template.json                 <- frozen target-event Rule query, T0 substituted at runtime
│  └─ r-obs-05-query.template.json             <- frozen R-OBS-05 (Range B) query, T0 substituted at runtime
├─ tests/
│  └─ Test-K8ShakedownRegression.ps1           <- repo-side checks, see below
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

1. Executing the Collector query and Rule query against Elasticsearch, and
   saving the raw responses into `collector-output/` / `rule-output/`
   (queries are pre-filled with `T0`; running them and judging the result is
   not).
2. The Range B R-OBS-05 Elasticsearch correlation judgment (same: pre-filled,
   not executed).
3. `scoring-input.json` for Range A and Range B (README §6.2).
4. Range B's step4-fault-pilot nontriviality checks 2 ("one unrelated
   observed gateway interface still has a mirror filter") and 4 (sensor
   capture contains an unrelated frame) -- `contract-output/runtime-contract-record.md`
   marks these `REQUIRES MANUAL CONFIRMATION` rather than guessing at them,
   since they need generated-topology / pcap-content knowledge this tooling
   does not have.

## Status

Development in progress on branch `shakedown/k8-automation`. No formal
release/tag has been cut from this branch, and `k8-bootstrap-v4` (the current
formal, certified bootstrap) is untouched. Promotion of anything here into the
formal reproduction package is a separate, later decision made after
independent review of a completed Shakedown run.
