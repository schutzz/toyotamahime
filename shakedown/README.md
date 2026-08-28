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
- It does not execute the Range B R-OBS-05 Elasticsearch query. That is a
  human correlation judgment against live data, not a mechanical step. The
  runner writes the frozen query with `T0` substituted for copy/paste and
  stops there.

## Layout

```text
shakedown/
├─ README.md                                  <- you are here
├─ tools/
│  ├─ K8ShakedownCommon.psm1                   <- pinned constants + shared functions
│  ├─ Start-K8Shakedown.ps1                    <- Setup
│  ├─ Run-K8ShakedownRangeA.ps1
│  ├─ Run-K8ShakedownRangeB.ps1
│  ├─ Run-K8ShakedownRangeC.ps1
│  └─ r-obs-05-query.template.json             <- frozen ES query, T0 substituted at runtime
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

1. `scoring-input.json` for Range A and Range B (README §6.2).
2. The Range B R-OBS-05 Elasticsearch correlation judgment (the query is
   pre-filled; running it against Elasticsearch and reading the result is
   not).

## Status

Development in progress on branch `shakedown/k8-automation`. No formal
release/tag has been cut from this branch, and `k8-bootstrap-v4` (the current
formal, certified bootstrap) is untouched. Promotion of anything here into the
formal reproduction package is a separate, later decision made after
independent review of a completed Shakedown run.
