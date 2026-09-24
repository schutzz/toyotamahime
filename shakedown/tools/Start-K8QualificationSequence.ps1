#Requires -Version 7.0
<#
.SYNOPSIS
    Opens a K8 Shakedown qualification sequence. Not a formal K8-3 attempt; not
    Gate K8 evidence.

.DESCRIPTION
    A qualification sequence is the unit that Range A, B and C must all belong
    to. It records, once, at sequence start:

        sequence_id          which sequence this is
        locked_head          the exact Toyotamahime commit it commits to
        started_utc
        initial_tree_clean

    `sequence_id` and `locked_head` are deliberately SEPARATE facts. Each run
    independently records the tooling_head it actually ran under, and the gate
    at the start of every run compares the two. Binding the HEAD into the ID
    would make them indistinguishable and leave nothing to check.

    This script refuses to open a sequence when:

      - the tooling worktree is not clean (a sequence locks an exact commit, and
        a dirty tree means the running code is not that commit);
      - any LIVE sequence still exists -- including an `ineligible` one left by
        a terminated run. Closing is a separate, explicit act:
        .\tools\Close-K8QualificationSequence.ps1 -Reason '...'
      - the control plane is inconsistent (two live sequences, a pointer that
        disagrees with the records, an interrupted creation, or a run record no
        sequence accounts for).

    Nothing here is repaired automatically and no record is ever deleted.

.EXAMPLE
    .\tools\Start-K8QualificationSequence.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'K8ShakedownCommon.psm1') -Force

$RepoRoot = Split-Path -Parent $PSScriptRoot           # .../toyotamahime/shakedown
$RepoRoot = Split-Path -Parent $RepoRoot               # .../toyotamahime
if (-not (Test-Path (Join-Path $RepoRoot 'Study01\README.md'))) {
    throw "Study01/README.md not found under $RepoRoot. Run this from a clone of the shakedown/k8-automation branch; do not copy this tools/ directory out on its own."
}

$sequence = New-K8QualificationSequence -RepoRoot $RepoRoot

Write-Host ''
Write-Host "Qualification sequence opened."
Write-Host "  sequence_id  : $($sequence['sequence_id'])"
Write-Host "  locked_head  : $($sequence['locked_head'])"
Write-Host "  started_utc  : $($sequence['started_utc'])"
Write-Host "  next_range   : $($sequence['next_range'])"
Write-Host ''
Write-Host 'Every run in this sequence must execute at that exact HEAD with a clean tree.'
Write-Host 'If a fix becomes necessary at any point, close this sequence, fix, open a NEW'
Write-Host 'one and restart from Range A. Retrying inside the same sequence is not permitted.'
Write-Host ''
Write-Host 'Next:'
Write-Host '  .\tools\Start-K8Shakedown.ps1        (if setup has not run in this workspace)'
Write-Host '  .\tools\Run-K8ShakedownRangeA.ps1'
