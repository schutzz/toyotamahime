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
- Docker runtime (§4.2's `docker pull` is `parse`-only)
- The Amenonuboco remote (§4.1's clones are `parse`-only)
- Range A/B/C runtime execution (out of scope for this certification entirely — it governs K8-3 packaging, not Amenonuboco-provisioned range behavior)

**Not mocked, and worth calling out because it is easy to assume otherwise:** pip/PyPI network access. `apparatus-check` genuinely runs `pip install pytest` against whatever package index the certifying machine is configured for, and then runs the real 69-test suite. A machine with no route to PyPI fails Layer C for that reason — correctly, since a clean VM without one would fail identically.

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

## What "certified commit" actually means

Two review findings against the first version of this gate were both about the same underlying gap: a certification result naming commit X did not actually guarantee X was what got tested, or what a VM would later clone.

**The commit under test must be committed and clean.** `Test-Study01Packaging.ps1` runs `git status --porcelain` on `-RepoRoot` before anything else. A dirty tree (or a directory that is not a git repository at all) is refused outright unless `-AllowDirty` is passed explicitly; passing it relabels the entire run as a `DEVELOPMENT CHECK -- NOT ELIGIBLE FOR VM GATE` and the script never prints the `PACKAGE CERTIFICATION: PASS/FAIL (commit X)` line for that run. `package-certification.json`'s `gate_eligible` field records the same distinction machine-readably. This exists because certifying a working tree and reporting the result under the last *commit's* SHA is not certifying that commit.

**The commit `git clone` will actually fetch must be the one that was certified.** This is `bootstrap/Start-Study01.ps1`'s `-Ref` default: rather than defaulting to empty (whatever the default branch's HEAD happens to be *when a VM runs it*, which can be a different commit than whatever was certified earlier), it defaults to this script's own release tag (`k8-bootstrap-v4` as of this writing). That tag is only ever created pointing at a commit that has already passed certification, so "the commit the tag names" and "the commit that was certified" are the same act, not two things that can drift apart. `Test-Study01Packaging.ps1` builds its local git fixture with that same tag on its single commit (`Get-K8BootstrapDefaultRef` reads the pin out of the bootstrap script's own source, so there is exactly one place that name lives) and includes a dedicated regression check: add a further commit to the fixture's default branch *after* tagging (simulating "someone pushed to `main` after this commit was certified, before a VM ran"), then run bootstrap with its default, un-overridden `-Ref`, and assert the cloned `HEAD` is the *tagged* commit, not the drifted branch tip.

### The v3 incident: certification testing the release process still missed one step

`k8-bootstrap-v3` was tagged at the commit that introduced the `-Ref` pin above. A follow-up commit, fixing an unrelated bug in `Test-Study01Packaging.ps1`'s own dirty-tree detection, landed immediately after — and was never re-tagged. The clean-tree, gate-eligible certification run that actually printed `PACKAGE CERTIFICATION: PASS` ran on that follow-up commit, not on the commit `k8-bootstrap-v3` names. So for a time, the published tag and the certified commit were two different commits — precisely the failure mode this whole mechanism exists to prevent, reintroduced by a maintainer process gap rather than a code defect, and only caught because an external reviewer checked the tag's actual target on GitHub rather than trusting the reported SHA.

**Certification cannot catch this by construction**: it necessarily runs *before* a tag exists for the commit under test (see "What is mocked" — the fixture's tag simulates a release, it is not the release), so nothing in the three layers above can verify a tag that has not been created yet. The fix is a fourth, separate, *post-release* check — see below — plus the discipline it exists to enforce: after any additional commit, however small, the release sequence (certify → push → tag) starts over from certify. `k8-bootstrap-v3` is left exactly as it was (an immutable tag is never moved, including to correct a mistake); `k8-bootstrap-v4` is the fresh commit/certify/tag cycle done correctly, and per this same discipline, any further edit after v4 is tagged — even one byte — starts a v5 cycle rather than retroactively describing v4.

## Post-release binding check

`Study01/tools/Test-K8ReleaseBinding.ps1` is deliberately separate from `Test-Study01Packaging.ps1` and is not run as part of it, for the reason above: it only makes sense *after* pushing a commit and creating its tag. Run it once, right after tagging:

```powershell
cd Study01
.\tools\Test-K8ReleaseBinding.ps1 -Tag k8-bootstrap-v4 -ExpectedCommit <the commit SHA you just pushed>
```

It fetches the named tag from `origin` (not merely a local tag — the v3 incident was invisible locally too, since the local tag was created correctly; it is the combination of tag-vs-intended-commit that must be checked against what was actually pushed) and asserts, mechanically, that all three of the following name the same commit:

1. the tag's peeled target on `origin` (`git rev-parse "$Tag^{commit}"` after fetching it),
2. `bootstrap/Start-Study01.ps1`'s own `-Ref` default (same extraction `Test-Study01Packaging.ps1` uses), and
3. the tag named in `Study01/README.md`'s pinned fetch URL,

against `-ExpectedCommit` (or `HEAD`, if not given). Any mismatch is a specific, named finding (which of the three disagrees, and with what), not a generic failure. This is intentionally small — it is a release-sequencing check, not a second certification suite.

Cutting a new bootstrap version means updating, together, in one commit: the script's own `$Ref` default, `Study01/README.md` §3.2's pinned tag name and SHA-256 (verified against the actual git blob, not the working-tree file — see the project's own commit history for why), and creating the new tag after that commit lands and has been certified. `Test-Study01Packaging.ps1`'s "default -Ref is non-empty" check catches the case where a future edit reverts the default to blank; it cannot catch a maintainer tagging the wrong commit (including "the right commit at the time, then one more commit landed and the tag was never moved to it" — see the v3 incident above), since certification necessarily runs before the tag exists. `Test-K8ReleaseBinding.ps1`, run once after pushing and tagging, is what closes that specific gap; it does not eliminate the release sequence being a real sequence a maintainer must run in order.

## Closed-attempt immutability

A closed attempt (`final-status.json` exists) is treated as immutable. `Invoke-K8Step`, `Add-K8KnowledgeLeak`, and `Complete-K8Attempt` itself all refuse to run against one (`Assert-K8AttemptOpen`, and an explicit re-entry guard in `Complete-K8Attempt`), regardless of whether the attempt path came from auto-resolution or an explicit `-AttemptDir` override. `Complete-K8Attempt` also clears `$env:K8_ATTEMPT_DIR` (if it still points at the attempt being closed) and deletes the current-attempt pointer file (same condition) on a successful close, so nothing downstream can auto-resolve back into a just-closed attempt by accident. Layer C certifies this directly: after each lifecycle pass closes, it spawns real child processes that attempt `Record-K8KnowledgeLeak.ps1`, `Invoke-K8Step.ps1`, and a second `Stop-K8.ps1` against the now-closed attempt (via explicit `-AttemptDir`, since auto-resolution should already find nothing) and asserts all three fail, then re-hashes `manifest.sha256` to confirm the directory was not actually touched.

## Output

Console output names every check as `PASS`/`FAIL`/`SKIP` with `[Layer] check` and, on failure, the specific reason (never a bare "N assertions failed"). `SKIP` (not a silent pass, not a failure) is reserved for a check whose precondition genuinely does not hold on the certifying machine — currently only the WSL unit check on a machine with no `wsl.exe` at all. A machine-readable `package-certification.json` (path via `-ResultPath`, default under `$env:TEMP`) records `commit`, `timestamp_utc`, `gate_eligible`, per-layer pass booleans, the full findings list, and `overall`. This file is runtime evidence about *a certification run*, not repository content — it is not committed, and `.gitignore` backstops that.

## Running it

```powershell
cd Study01
.\tools\Test-Study01Packaging.ps1
```

Refuses to run as a gate-eligible certification against a dirty working tree (see above); pass `-AllowDirty` for a development check that is explicitly not eligible to authorize a clean-VM attempt.

`-SkipUnit` / `-SkipIntegration` / `-SkipRunbook` exist for fast iteration while developing a change to the harness itself; a certification that is allowed to gate a clean-VM attempt does not use them.

## Extending it

Adding a new README-documented harness command or a new reproduction-critical command block: add the `<!-- k8-test:id=... mode=... cwd=... -->` marker immediately above its fenced block, then reference that `id` from `Test-Study01Packaging.ps1`'s Layer C section if it belongs in the ordered lifecycle sequence — or do nothing further if the static parse/prefix/hygiene checks are sufficient coverage for it (that is normal for `parse`-mode external-dependency blocks).

## Known limitations

- Layer A's WSL check is skipped (not failed) on a certifying machine without `wsl.exe` present at all; it does not fabricate a pass.
- pip network access is not mocked — Layer C's `apparatus-check` blocks genuinely `pip install pytest` and run the real 69-test suite against the fixture's copy of the frozen apparatus. A certifying machine without Python/pip/network to PyPI will fail Layer C for that reason, correctly, since a clean VM needs exactly the same thing to succeed.
- This certification governs K8-3 **packaging** — bootstrap, harness, README interface, documentation consistency. It does not and cannot certify Range A/B/C scientific behavior, which requires Amenonuboco and Docker and is explicitly out of scope (see "What is mocked" above).
