# `bootstrap/` — K8-3 attempt bootstrap

This directory holds exactly one file, `Start-Study01.ps1`. It exists to solve one problem: a K8-3 attempt should have an ordered transcript starting from `git clone` itself, but the repo-local harness (`Study01/tools/`) does not exist on a clean machine until after that clone completes.

**This is not a general installer and not a mutable, unpinned download.** It is an ordinary file tracked in this repository, like any other. The authoritative instructions for fetching, verifying, and running it — including the exact pinned tag and the SHA-256 to check it against — are in [`Study01/README.md`](../Study01/README.md) §3.2, because that is the document K8-3 actually tests. This file exists so the script is reviewable next to itself, not as a second source of truth.

## What it does, in order

1. Generates a new attempt ID (`k8-repro-YYYYMMDD-NNN`) and creates its evidence directory under the `-AttemptRoot` you pass (default `C:\K8\attempts`). Refuses to reuse or overwrite an existing attempt.
2. Starts a transcript in that directory before doing anything else.
3. Clones the public Toyotamahime repository (default `https://github.com/schutzz/toyotamahime`; override with `-RepoUrl` only if you have a specific, disclosed reason — the reproduction input is the public repository) and records the exact clone `HEAD` and `git status --short`.
4. Imports `Study01/tools/K8AttemptCommon.psm1` from the freshly cloned repository and captures a small environment record (`environment.json`).
5. Prints where the attempt directory is and stops — it does **not** run Range A/B/C, does **not** install anything, and does **not** decide success or failure. That is yours to do by hand, following `Study01/README.md`, using `Study01/tools/Invoke-K8Step.ps1`, `Record-K8KnowledgeLeak.ps1`, and `Finalize-K8Attempt.ps1` from the clone as you go.

If the clone itself fails, this script records that failure (`stop-reason.txt`, `final-status.json`, an archive and its SHA-256) using a minimal, self-contained fallback, because the repo-local harness does not exist yet to do it for you.

## What it does not do

- It does not install or upgrade any dependency.
- It does not remediate a failure and continue.
- It does not judge Gate K8.
- It does not send anything anywhere; all output stays under `-AttemptRoot` on the machine you run it on.
