# Study 01 — Negative-result validity in an OT/ICS cyber range

Reproduction kit. Everything needed to re-run the experiment and compare against what it produced is in this directory.

**What you will produce:** a Range A classification, a Range B classification, and a Range C validation outcome. Expected values are in [`expected/`](./expected/), and §6 says which differences matter and which do not.

**Time and cost:** three runs on one machine. Ranges A and B provision containers; Range C does not.

---

## 1. Before anything else — the two rules that make this kit meaningful

**The apparatus is frozen, and you must not fix it.** Two known defects are shipped unfixed. How they behave in your reproduction is **observed, not assumed** — see §6.3. Neither is to be repaired:

- `scripts/study01_score.py` writes its record with a Windows-native newline call, so a scoring record is content-identical but not byte-identical to a fresh-clone rescoring. See [`claims/limitations.md`](./claims/limitations.md) §3.
- The Range B rule-stage query does not record which index it searched. That is why the study's headline hypothesis is *Inconclusive*, and it is reproduced as-is. See [`claims/h-j1-judgment.md`](./claims/h-j1-judgment.md).

Seven further apparatus improvements are known and deliberately **not** applied here — they are listed as R1–R7 in [`claims/limitations.md`](./claims/limitations.md) §2. Applying any of them would produce a better apparatus than the one that ran, and this would stop being a reproduction of Study 01.

**Do not adjust anything to reach the expected result.** If your run classifies differently, that is a result. Keep it. §7 says what to do with it.

## 2. Why the directory layout looks like this

`Study01/studies/study-01-negative-result/` is not an accident of copying. The frozen apparatus pins the sender asset as a repo-root-relative path beginning with `studies/study-01-negative-result/`, and frozen files may not be edited for packaging convenience. So the apparatus world is mirrored at exactly that path, and **`Study01/` is the repo root as far as the apparatus is concerned**.

The practical consequences:

- Run every command **from `Study01/`**.
- The canonical commands printed in `protocol/` work verbatim from there.
- `Study01/.gitattributes` must stay where it is; the test suite reads it from that location.

```text
Study01/
├─ README.md                                  <- you are here
├─ PROVENANCE.md, provenance.json             <- where every file came from, with blob ids
├─ .gitattributes                             <- EOL policy; load-bearing, see §2
├─ expected/                                  <- comparison targets, §6
├─ claims/                                    <- what the study concluded, and what it did not
└─ studies/study-01-negative-result/
   ├─ protocol/                               <- the canonical, frozen procedures
   ├─ scripts/                                <- the apparatus
   └─ experiments/                            <- the sender asset and the Range C patch
```

## 3. Execution platform and prerequisites

**Execution platform.** Study 01 is reproduced using the public [Amenonuboco](https://github.com/schutzz/ot-range-amenonuboco) repository at the pinned commits in §4.1. Ranges A and B use it for range generation and execution; Range C uses its pinned validator for pre-deployment contract validation and provisions nothing. Both roles are pinned to specific commits, and neither is a moving dependency.

### 3.1 Prerequisites

| Requirement | Value used by the original runs |
| --- | --- |
| Shell | **PowerShell 7**. The apparatus rejects other shells at preflight — Git Bash / MSYS rewrites bare in-container paths, which silently breaks capture and sender steps. This is enforced, not advisory. |
| OS | Windows with Docker Desktop. The original runs used Windows 11. |
| Docker | Docker Engine with Compose v2 (`docker compose`, not `docker-compose`). |
| Python | 3.10 or later. `pytest` is required — §3.1's apparatus-integrity check is mandatory, not optional, before you use the apparatus. Range C additionally needs `pydantic` 2.x and `PyYAML`; §4.1 installs them from the validator's own declared requirements. |
| `git` | any recent version |

Record your own versions before you start; the original runs used Python 3.10.11, pydantic 2.12.5, PyYAML 6.0.3.

Install `pytest`, then confirm the apparatus is intact before using it. **You are already at `Study01/`** per §2 — do not prefix the path below with `Study01/` again:

```powershell
python -m pip install pytest
cd studies/study-01-negative-result/scripts
python -m pytest tests -q
```

69 tests should pass. If they do not, stop and record the failure; do not continue. If you started this attempt from §3.2's bootstrap, run this through `Invoke-K8Step.ps1` instead of typing it directly, so the exit code and failure are recorded automatically:

```powershell
.\Study01\tools\Invoke-K8Step.ps1 -AttemptDir $AttemptDir -Description 'apparatus integrity test' `
    -Command { python -m pytest tests -q }
```

### 3.2 Clean-host bootstrap and attempt evidence (optional, recommended)

You are presumably reading this from *some* clone of Toyotamahime already — that is fine, and expected: this is documentation, read once to learn the procedure. A **recorded attempt** is a separate thing. `Start-Study01.ps1` performs its own, fresh `git clone` inside the attempt directory it creates, independent of whatever copy you are reading this from, so that attempt's transcript and recorded `HEAD` cover a clone it controls end to end. Run it from a clean starting point when you want a properly recorded attempt, not merely to read ahead.

This section adds an **optional harness** that automates the bookkeeping around a K8-3 attempt — creating the evidence directory, starting a transcript before `git clone`, recording the exact clone `HEAD`, capturing a small environment record, and closing the attempt out on success or failure — so you are not hand-assembling that from scratch, especially after a failure. It changes nothing about what you run for Range A/B/C; it only records it.

**What it is and is not.** The harness is infrastructure for attempt lifecycle and evidence acquisition. It does not run Range A/B/C for you, does not install or fix anything you are missing, does not decide whether your attempt succeeded, and does not determine Gate K8 — Gate K8 is independent review. If a step fails, the harness's job is to make sure that failure is recorded and the attempt is closed cleanly, not to work around it.

**What is downloaded, from where, and how it is verified.** `bootstrap/Start-Study01.ps1` is an ordinary file tracked in this repository (see [`bootstrap/README.md`](../bootstrap/README.md)). Fetch it from a tag-pinned URL — not a branch, which can move — and verify its SHA-256 before running it:

```powershell
$Url      = 'https://raw.githubusercontent.com/schutzz/toyotamahime/k8-bootstrap-v1/bootstrap/Start-Study01.ps1'
$Dest     = Join-Path $env:TEMP 'Start-Study01.ps1'
$Expected = '03e086fc35e2091f4f73379c2ca8cb3bb9e4f6e1fcc8f8eaa972ce2cfc9c0262'

Invoke-WebRequest -Uri $Url -OutFile $Dest
$Actual = (Get-FileHash -Path $Dest -Algorithm SHA256).Hash.ToLower()
if ($Actual -ne $Expected) {
    throw "SHA-256 mismatch: expected $Expected, got $Actual. Do not run this file."
}

& $Dest
```

The tag `k8-bootstrap-v1` points at a specific commit in this repository's history, the same way §4.1 pins Amenonuboco by tag rather than by a moving branch. If you would rather read the script before running it, it is right there in the repository you are about to clone: [`bootstrap/Start-Study01.ps1`](../bootstrap/Start-Study01.ps1).

**What it executes and where it writes.** `Start-Study01.ps1` creates a new attempt directory under `C:\K8\attempts\<attempt-id>\` (override with `-AttemptRoot`), starts a transcript there, clones `https://github.com/schutzz/toyotamahime` into it, records the exact clone `HEAD`, and captures a small environment record. It writes only under `-AttemptRoot`; it does not touch anything outside it, and it does not send anything over the network beyond the clone itself.

**What you get back**, printed at the end and available under the attempt directory:

```text
C:\K8\attempts\k8-repro-YYYYMMDD-NNN\
  transcript.txt             one ordered log, from before the clone onward
  attempt.json                \
  repository.json              small, machine-readable identity records
  environment.json            /
  steps.jsonl                 one line per Invoke-K8Step.ps1 call, with exit codes
  knowledge-leak-log.md        \  Sec6.2 knowledge-leak log, human + machine forms
  knowledge-leak-log.jsonl     /
  stop-reason.txt             written by Finalize-K8Attempt.ps1
  final-status.json           outcome, reason, final HEAD/status -- not a Gate K8 verdict
  manifest.sha256             sha256 of every file above, before archiving

C:\K8\attempts\k8-repro-YYYYMMDD-NNN.zip           the attempt directory, archived
C:\K8\attempts\k8-repro-YYYYMMDD-NNN.zip.sha256    sha256 of that archive
```

**Using it while you follow this README:**

- Run a command with recorded exit-code capture: `.\Study01\tools\Invoke-K8Step.ps1 -AttemptDir $AttemptDir -Description '...' -Command { <command> }`. If a step's protocol expects a non-zero exit code (the Range C validator does — §5.3, §6.1), pass `-ExpectedExitCode 1` rather than treating it as a failure.
- Record a knowledge-leak entry in one line: `.\Study01\tools\Record-K8KnowledgeLeak.ps1 -AttemptDir $AttemptDir -Reason '...'`.
- Close the attempt when you are done, success or failure: `.\Study01\tools\Finalize-K8Attempt.ps1 -AttemptDir $AttemptDir -Outcome Success|Failed -Reason '...'`.

**When something fails:** a critical step run through `Invoke-K8Step.ps1` stops there by default and tells you to finalize as `Failed`. Do that — do not install the missing thing from memory and re-run the same step. §7 of this README already tells you how to classify what happened; the harness only makes sure the attempt is closed and archived either way, with its own attempt ID, never repaired or reused in place.

## 4. Dependencies you must fetch

### 4.1 Amenonuboco — the range generator and the contract validator

Two different pinned commits of the same public repository, `https://github.com/schutzz/ot-range-amenonuboco`.

**Range generation** (Ranges A and B), pinned to `78fc17746b5d663fafec9dffe563d79fe9ea02b7`:

```powershell
git init amenonuboco-gen
cd amenonuboco-gen
git remote add origin https://github.com/schutzz/ot-range-amenonuboco
git fetch --depth=1 origin 78fc17746b5d663fafec9dffe563d79fe9ea02b7
git checkout FETCH_HEAD
cd ..
```

**Contract validation** (Range C), pinned to tag `v0.13.0` = `0378f8a32701b481e030f3db3d5f66ea471a4675`:

```powershell
git clone --branch v0.13.0 --depth=1 https://github.com/schutzz/ot-range-amenonuboco amenonuboco-v0.13.0
python -m pip install -r amenonuboco-v0.13.0/requirements.txt
```

That installs `pydantic` and `PyYAML` at the versions the validator's own repository declares (`pydantic>=2.0,<3.0`, `PyYAML>=6.0` as of `v0.13.0`) — do not pin different versions here.

Keep them as two separate checkouts. Do not reuse one for both.

### 4.2 Images

The capture helper is pinned by digest and must be pulled by digest:

```powershell
docker pull corfr/tcpdump@sha256:3006b3bd9f041bf73f21e626b97cca5e78fd6ce271549ca95b8e6a508165512b
```

Range A and Range B build their service images from the generated Compose file; `protocol/c2-dnp3-image-inventory.md` records what the original runs used. Record the digests you end up with.

## 5. Running the three ranges

The canonical procedures are in `protocol/`, and they are the authority — this section sequences them and tells you what each step must leave behind. **Where a protocol document gives a literal command, use that command.**

### 5.1 Range A — the observation-valid control

1. Choose a fresh run ID. Use it as the Compose project name, the run-evidence directory name, and nowhere else. Never reuse one.
2. Generate the Compose file into a run workspace **exactly one level below the Amenonuboco worktree root** — `protocol/c2-dnp3-range-derivation.md` §2.1 explains why this is load-bearing and what fails if it is not.
3. Create the empty evidence tree, then run the **execution preflight** (`protocol/c2-dnp3-range-derivation.md` §2.3). It starts no container. Do not provision until it exits 0.
4. Provision, establish readiness, resolve the capture contexts, and start the capture helpers before the event window opens — `protocol/c2-dnp3-capture-procedure.md`.
5. Place and hash the sender asset, then invoke it **exactly once** through `study01_sender.py` — `protocol/c2-dnp3-sender-procedure.md`. The invocation defines T0, and the frozen window is `[T0 − 5 s, T0 + 15 s]`.
6. Cover the window, stop and export both captures, decode them, and retain the Collector and Rule queries with their responses and mappings.
7. Retain the runtime contract record, image inventory, environment, and deviations; tear down.
8. `study01_collect.py validate-evidence`, then `finalize-evidence`, then `verify-integrity`.
9. Score offline with `study01_score.py`. See §6.2 first — derive the scoring input from **your** evidence before you look at the expected values.

Expected, not forced: Ground Truth / Sensor / Collector Pass, runtime contract Pass, rule output `Alert`, classification `Valid detection result`.

### 5.2 Range B — the same run with one fault

Identical to Range A, under a **new** run ID, with exactly one difference: before the capture and trigger, delete the ingress qdisc on the interface carrying `10.1.20.254/24`. Resolve that interface by address, never by ordinal.

Additionally, Range B must capture and retain the R-OBS-05 unrelated-flow liveness evidence end to end — the contract is `protocol/k6-r-obs-05-collector-query-contract.md`. Without it the run is `Inconclusive experiment`, not `Invalid negative result`.

Expected, not forced: Ground Truth Pass; Sensor and Collector Fail; rule output `No alert`; R-OBS-05 Pass; runtime contract Fail; classification `Invalid negative result`.

### 5.3 Range C — static validation only

Range C is **never provisioned**. `docker compose up` is not part of this step in any form.

1. Create a disposable worktree from the `v0.13.0` checkout, detached at `0378f8a`, and confirm it is clean **before** placing anything into it.
2. Derive the negative manifest from the pinned base manifest by the substitution recorded in `experiments/range-c-negative-manifest/` — a segment required by `observability_contract.required_segments` while `instrumentation.exclude` removes it. Preserve the base manifest's own line terminators; the original base is CRLF in the worktree.
3. Run only `python platform/cli.py validate manifests/power-grid-reference.range-c-negative.yaml`.
4. Retain the derived manifest, the derivation, the command, stdout, stderr, the exit code, and tool versions as raw bytes without newline translation.

Expected, not forced: exit `1`, empty stdout, and a stderr naming `observability_contract.required_segments` and `sub_a_l2_lan`.

## 6. Comparing what you got

### 6.1 Must match

| Element | Expected |
| --- | --- |
| Range A classification | `Valid detection result` |
| Range A stages | Ground Truth Pass, Sensor Pass, Collector Pass, runtime contract Pass, rule output `Alert` |
| Range B classification | `Invalid negative result` |
| Range B stages | Ground Truth Pass, Sensor Fail, Collector Fail, runtime contract Fail, rule output `No alert` |
| Range C | non-zero exit, empty stdout, stderr naming `observability_contract.required_segments` and `sub_a_l2_lan` |
| Procedure conformance, A and B | schema 2, one sender invocation, exit `0`, no same-run retry, `procedure_invalid` false |
| Integrity | your own manifest verifies against your own committed bytes |

### 6.2 Derive your input before you look at the answer

The scoring input is transcribed by hand from the evidence; only its `procedure_conformance` block is machine-checked against the evidence tree. That is limitation R6 in [`claims/limitations.md`](./claims/limitations.md), and it interacts badly with already knowing the expected classification.

So, in this order:

1. Collect your evidence and finalize its integrity manifest.
2. Write your scoring input, recording **for each field the artifact and value you derived it from**.
3. Run the scorer.
4. *Then* open `expected/`.

`expected/range-a/scoring-input.json` and `expected/range-b/scoring-input.json` are the original runs' inputs. They are comparison targets. **Do not copy them into your run.**

### 6.3 May legitimately differ

Timestamps, T0 and the derived window, container and network identifiers, interface ordinals, Elasticsearch document ids, capture frame counts and frame numbers, pcap digests, and the exact nanosecond correlation deltas — provided each stays inside the frozen ±1,000,000 ns bound. **This is not a byte-for-byte replay and is not evaluated as one.**

**The CRLF defect from §1 is not assumed to recur.** If it does — your scoring record is content-identical but not byte-identical to a fresh-clone rescoring — retain that as evidence that the behaviour reproduces outside the original execution host. Its presence is **not** a reproduction failure. If it does not recur, retain that as an unenumerated difference and evaluate it under the outcome rules in §7. Do not repair either result, and do not explain either away.

## 7. When something does not match

Classify it before you change anything.

**If the kit is at fault** — a missing or ambiguous step here, a wrong path, a missing file, a dependency this README does not name — record it, keep the failed attempt exactly as it is, fix the kit, and start again under a **new** run ID. Never repair an attempt in place, and never quietly supply a missing step from your own knowledge and then call the run successful. An issue or a pull request against this repository is the right response.

**If the study is at fault** — the protocol, the scorer, the evidence criteria, or a claim would have to change — stop. That is a finding about the research, not about the packaging, and it belongs in an issue describing what you observed and what you think it implies. Do not work around it.

**If the outcome simply differs** — you completed the run and got a different classification — keep it and report it. A failed reproduction is a legitimate research result. It is not something to delete, retry away, or explain away.

## 8. What this study claims, and what it does not

Read [`claims/claim-wording.md`](./claims/claim-wording.md) before quoting anything from here. In short:

- The observation chain that has to hold before a "no alert" can be read at all **was verified end to end** for one frozen event.
- One fault broke that chain, and the break is visible in primary evidence.
- A procedure fixed before the run classified the resulting `No alert` as an invalid experimental result rather than a detection failure — **though the `No alert` input it acted on comes from a rule query that does not record which index it searched, so zero target alerts in Range B is not established.**
- One defined contract contradiction was rejected before deployment by the pinned validator — one contradiction, one validator, with no positive control, so nothing follows about the validator's selectivity.
- **No observation-valid `No alert` ever occurred.** The study does not claim to have compared two negative outcomes.

Nothing here is a statement about detection performance, and nothing here is a novelty claim.

## 9. Provenance

Every file in this directory was extracted from a named commit of the private Kakuriyo research repository, by reading committed bytes. [`provenance.json`](./provenance.json) records, per file, the source path, the Kakuriyo blob id, and the SHA-256. [`PROVENANCE.md`](./PROVENANCE.md) explains what was deliberately left behind and why.
