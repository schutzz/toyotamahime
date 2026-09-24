#Requires -Version 7.0
<#
.SYNOPSIS
    Closes a K8 Shakedown qualification sequence. Not a formal K8-3 attempt; not
    Gate K8 evidence.

.DESCRIPTION
    Closing is the ONLY way out of a live sequence, and it is deliberately a
    separate act from opening one. The recovery order after any failure is:

        Close-K8QualificationSequence.ps1 -Reason '...'
        (fix on the dev machine, push)
        git pull on the VM
        run the Shakedown regression suite
        confirm `git status` is clean
        Start-K8QualificationSequence.ps1        <- new sequence, new locked_head
        Run-K8ShakedownRangeA.ps1                <- restart from Range A

    Splitting close from start is what makes that order possible: opening
    immediately after closing would lock a HEAD that the fix is about to change.

    If the sequence still has an active run, this script FIRST makes sure that
    run has a machine-readable termination record:

      - an existing termination record is preserved byte for byte, never
        overwritten;
      - otherwise an operator-close record is written, with
        stage = "operator-close", failure_kind = "non-command", command = null,
        and tooling_head taken from the run's own provenance -- or, if the run
        died before its provenance was written, from the reservation the
        sequence made durable. The HEAD at close time is a different fact and is
        never substituted.

    complete / closed / abandoned are immutable terminal states: this script
    refuses to act on a record that already reached one.

.PARAMETER Reason
    Why the sequence is being closed. Required, and retained verbatim in the
    sequence record and in any operator-close termination it writes.

.PARAMETER SequenceId
    Only needed when the control plane holds more than one live sequence. This
    tooling never guesses which one you meant.

.EXAMPLE
    .\tools\Close-K8QualificationSequence.ps1 -Reason 'Range B terminated at fault-injection; fixing SD-xx'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Reason,
    [string] $SequenceId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'K8ShakedownCommon.psm1') -Force

$sequence = Close-K8QualificationSequence -Reason $Reason -SequenceId $SequenceId

Write-Host ''
Write-Host "Qualification sequence closed."
Write-Host "  sequence_id     : $($sequence['sequence_id'])"
Write-Host "  locked_head     : $($sequence['locked_head'])"
Write-Host "  completed_runs  : $(@($sequence['completed_runs']).Count)"
Write-Host "  terminated_runs : $(@($sequence['terminated_runs']).Count)"
Write-Host "  closed_reason   : $($sequence['closed_reason'])"
Write-Host ''
Write-Host 'This record is now immutable. Retained run evidence and termination records are'
Write-Host 'untouched -- closing a sequence never modifies, resumes, re-queries or deletes a run.'
Write-Host ''
Write-Host 'Next: fix, push, git pull on the VM, run the regression suite, confirm a clean tree,'
Write-Host 'then .\tools\Start-K8QualificationSequence.ps1 and restart from Range A.'
