# K8-3 package certification — developer reference

This is the internal-implementation counterpart to `Study01/README.md` §3.3. That section tells a reproducer *that* certification is required before a clean-VM attempt and how to run it; this document explains *how* it works, for anyone maintaining it.

## Why this exists

Every clean-VM K8-3 attempt so far found a defect that a clean VM was not actually needed to find:

| Attempt / review | Defect | VM needed to find it? |
| --- | --- | --- |
| `k8-repro-20260827-001` | No install command for a mandatory dependency (`pytest`) | No — a static README read would have found it |
| Review of the same attempt | `Study01/README.md` §2/§3.1 cwd inconsistency (`cd Study01\...` while already at `Study01\`) | No — static path analysis |
| `k8-repro-20260828-001` | `$AttemptDir` did not survive `& $Dest` across the bootstrap's scope boundary | No — this reproduces identically outside a VM, in any PowerShell session |
| Same attempt's evidence review | `wsl.exe` redirected output decoded as mojibake | No — reproduces on any Windows host with WSL, VM or not |
| Same attempt's evidence review | 13 tracked `__pycache__/*.pyc` files in a "reproduction kit" | No — `git ls-files` finds it instantly |

None of these needed Docker, a hypervisor, or a clean Windows install to discover. They needed someone (or something) to actually run the packaging's own documented commands, in the packaging's own documented order, from the packaging's own documented starting state, and check what happened. That is what `Study01/tools/Test-Study01Packaging.ps1` does, mechanically, before a VM is ever touched.

## The rule

**A clean-VM K8-3 attempt MUST NOT start unless `Test-Study01Packaging.ps1` prints `PACKAGE CERTIFICATION: PASS` and exits `0`, on the exact commit under test.** A stale "it passed on an earlier commit" is not certification. See `Study01/README.md` §3.3.

## Three layers

### Layer A — Unit

`K8AttemptCommon.psm1`'s functions, imported and called directly, in-process. Fast, and the right place to test pure logic in isolation: attempt-ID generation and its collision refusal, `Get-K8AttemptPaths`, `Resolve-K8AttemptDir`'s three resolution paths (explicit / env var / pointer file) and its failure message, `Invoke-K8Step`'s pass / expected-nonzero / fail-closed / `-ContinueOnFailure` behavior, `Get-K8LastStep`, `Add-K8KnowledgeLeak`, `Complete-K8Attempt` (including that a secondary failure such as an archive collision does not erase `stop-reason.txt` / `final-status.json`), paths containing spaces, and the WSL UTF-16LE decode (`Invoke-Utf16LEProcessCapture` / `Get-K8WslField`) against the **real** `wsl.exe` on the certifying machine when present, asserting no embedded NUL and no `unavailable:` result.

### Layer B — Integration

The **real** `bootstrap/Start-Study01.ps1` and `Study01/tools/*.ps1`, invoked as **real, separate `pwsh` child processes** (`Invoke-K8CertChildProcess`) against a **temporary local git repository** built from the current working tree (`New-K8PackagingFixtureRepo` — `robocopy` the tree minus `.git`, then `git init && git add -A && git commit` in the copy). `git clone`/`checkout`/`rev-parse`/`status` all run against that fixture using the real `git.exe`; nothing about git itself is mocked.

This is deliberately **not** "call the module functions in the same process" — the `$AttemptDir` defect this whole effort responds to lived exactly in a scope boundary that an in-process call cannot reproduce. Layer B's first check spawns a real child process, runs the real bootstrap script inside it via `& $Dest` (the same invocation form the README documents), and only after that process returns checks whether `$env:K8_ATTEMPT_DIR` is set and points at an existing directory — the literal regression test for the original bug.

### Layer C — Executable Runbook

`K8ReadmeRunbook.psm1` parses `Study01/README.md` for HTML-comment markers immediately preceding a fenced code block:

```text
<!-- k8-test:id=<short-id> mode=exec|parse|display cwd=repo-root|Study01 -->
```

- `exec` — the block's text is executed **literally**, unmodified, inside a real child `pwsh` process, `Set-Location`'d to the declared `cwd` first.
- `parse` — the block is only PowerShell-parsed (`[System.Management.Automation.Language.Parser]::ParseInput`), never executed. Used for blocks whose execution needs a mocked external dependency this certification does not stand up (the bootstrap's own `Invoke-WebRequest` fetch from `raw.githubusercontent.com`, and every Amenonuboco/Docker command in §4).
- `display` — not certification input; explanatory text only. `Test-Study01Packaging.ps1` flags a `display` block whose text pattern-matches a real command (`git `, `python `, `docker `, `.\tools\`) as a finding rather than letting it pass silently, so `display` cannot be used to dodge certification for something that is actually a reproduction-critical command.

**The command text is never re-typed in test code.** `Test-Study01Packaging.ps1` builds its child-process scripts by concatenating `Get-K8ReadmeBlockById` results; if `Study01/README.md` changes a command, the next certification run tests the new text automatically. Two things it must inject that are *not* README text, by design, because the README documents no such example: (1) a synthetic failing step (`cmd.exe /c exit 9`) via the real `Invoke-K8Step.ps1` wrapper, to exercise the failure-lifecycle path; (2) which of the two `Stop-K8.ps1` example blocks (`stop-k8-failure-example` / `stop-k8-success-example`) to run in which of the two lifecycle passes. Both are orchestration decisions, not duplicated commands.

Layer C runs the full lifecycle twice — once ending in `Stop-K8.ps1 -Success`, once ending in `Stop-K8.ps1` (Failed) — asserting in both cases that the transcript closed, `final-status.json` is correct, `manifest.sha256` exists, and the archive's SHA-256 matches its actual bytes.

## What is mocked, and what never is

Mocked (external dependencies a clean VM still has to prove for itself, and that this certification does not claim to):

- GitHub network (the local fixture repo stands in for `https://github.com/schutzz/toyotamahime`)
- pip network (Python packages still install for real, from whatever index is configured on the certifying machine — not mocked further)
- Docker runtime (§4.2's `docker pull` is `parse`-only)
- The Amenonuboco remote (§4.1's clones are `parse`-only)
- Range A/B/C runtime execution (out of scope for this certification entirely — it governs K8-3 packaging, not Amenonuboco-provisioned range behavior)

Never mocked, per the original defect classes this exists to catch:

- The PowerShell process/scope boundary (`& $Dest` runs in a real separate `pwsh` process)
- `cwd` and relative-path resolution (real `Set-Location`, real relative paths, from the README's own declared `cwd`)
- `$env:` variable handoff across that boundary
- Actual CLI parameter parsing (real script invocation, not a module function call with parameters pre-bound)
- README code text (extracted, not re-implemented)
- Attempt directory lifecycle, transcript open/close, archive creation, SHA-256 generation (all real files, real `Compress-Archive`, real `Get-FileHash`)
- `git` itself (real `git.exe` against a real, if temporary, repository)

## Static checks

Two checks need no execution at all and run over every extracted block regardless of mode:

- **Double `Study01\` prefix detection**: any block declaring `cwd=Study01` whose text still references `Study01\tools` or `Study01\studies` is flagged — the exact defect class found during review, now caught even in a block that is never executed (a `parse`-mode example could still carry this mistake).
- **`display` block hygiene**: a `display`-mode block whose text looks like a real command is flagged as a finding, not silently accepted.

## Output

Console output names every check as `PASS`/`FAIL` with `[Layer] check` and, on failure, the specific reason (never a bare "N assertions failed"). A machine-readable `package-certification.json` (path via `-ResultPath`, default under `$env:TEMP`) records `commit`, `timestamp_utc`, per-layer pass booleans, the full findings list, and `overall`. This file is runtime evidence about *a certification run*, not repository content — it is not committed, and `.gitignore` backstops that.

## Running it

```powershell
cd Study01
.\tools\Test-Study01Packaging.ps1
```

`-SkipUnit` / `-SkipIntegration` / `-SkipRunbook` exist for fast iteration while developing a change to the harness itself; a certification that is allowed to gate a clean-VM attempt does not use them.

## Extending it

Adding a new README-documented harness command or a new reproduction-critical command block: add the `<!-- k8-test:id=... mode=... cwd=... -->` marker immediately above its fenced block, then reference that `id` from `Test-Study01Packaging.ps1`'s Layer C section if it belongs in the ordered lifecycle sequence — or do nothing further if the static parse/prefix/hygiene checks are sufficient coverage for it (that is normal for `parse`-mode external-dependency blocks).

## Known limitations

- Layer A's WSL check is skipped (not failed) on a certifying machine without `wsl.exe` present at all; it does not fabricate a pass.
- pip network access is not mocked — Layer C's `apparatus-check` blocks genuinely `pip install pytest` and run the real 69-test suite against the fixture's copy of the frozen apparatus. A certifying machine without Python/pip/network to PyPI will fail Layer C for that reason, correctly, since a clean VM needs exactly the same thing to succeed.
- This certification governs K8-3 **packaging** — bootstrap, harness, README interface, documentation consistency. It does not and cannot certify Range A/B/C scientific behavior, which requires Amenonuboco and Docker and is explicitly out of scope (see "What is mocked" above).
