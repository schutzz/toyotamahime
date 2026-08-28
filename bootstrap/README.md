# `bootstrap/` — K8-3 attempt bootstrap

This directory holds exactly one file, `Start-Study01.ps1`. It exists to solve one problem: a K8-3 attempt should have an ordered transcript starting from `git clone` itself, but the repo-local harness (`Study01/tools/`) does not exist on a clean machine until after that clone completes.

**This is not a general installer and not a mutable, unpinned download.** It is an ordinary file tracked in this repository, like any other. The authoritative instructions for fetching, verifying, and running it — including the exact pinned tag and the SHA-256 to check it against — are in [`Study01/README.md`](../Study01/README.md) §3.2, because that is the document K8-3 actually tests. This file exists so the script is reviewable next to itself, not as a second source of truth.

## What it does, in order

1. Generates a new attempt ID (`k8-repro-YYYYMMDD-NNN`) and creates its evidence directory under the `-AttemptRoot` you pass (default `C:\K8\attempts`). Refuses to reuse or overwrite an existing attempt.
2. Starts a transcript in that directory before doing anything else.
3. Clones the public Toyotamahime repository (default `https://github.com/schutzz/toyotamahime`; override with `-RepoUrl` only if you have a specific, disclosed reason — the reproduction input is the public repository) and records the exact clone `HEAD` and `git status --short`.
4. Imports `Study01/tools/K8AttemptCommon.psm1` from the freshly cloned repository and captures a small environment record (`environment.json`). Also records the attempt as `$env:K8_ATTEMPT_DIR` (a process environment variable, not a PowerShell scope variable — it survives this script returning to the caller via `& $Dest`) and in a `current-attempt.txt` pointer file, so nothing downstream ever needs an operator to type or remember the attempt path. (v1 of this script left `$AttemptDir` as a script-scoped variable, which did not survive `& $Dest` — see the v2 changelog note in the script's own header.)

`-Ref` defaults to this script's own release tag (`k8-bootstrap-v4` as of this writing, see the v4 changelog note in the script's own header), not a moving branch, so the commit `git clone` actually fetches is the same commit that was package-certified — even if the default branch has advanced by the time a VM attempt runs. After pushing and tagging a new release, run `Study01/tools/Test-K8ReleaseBinding.ps1` to confirm the tag, this default, and the README pin actually agree before treating it as usable — see `docs/k8-packaging-certification.md`, including the v3 incident where they silently did not.
5. Prints where the attempt directory is and stops — it does **not** run Range A/B/C, does **not** install anything, and does **not** decide success or failure. That is yours to do by hand, following `Study01/README.md`, using `.\tools\Invoke-K8Step.ps1`, `Record-K8KnowledgeLeak.ps1`, and `Stop-K8.ps1` from `Study01/` in the clone as you go — none of them take an attempt path.

If the clone itself fails, this script records that failure (`stop-reason.txt`, `final-status.json`, an archive and its SHA-256) using a minimal, self-contained fallback, because the repo-local harness does not exist yet to do it for you.

## What it does not do

- It does not install or upgrade any dependency.
- It does not remediate a failure and continue.
- It does not judge Gate K8.
- It does not send anything anywhere; all output stays under `-AttemptRoot` on the machine you run it on.
