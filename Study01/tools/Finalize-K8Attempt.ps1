#requires -Version 7.0
<#
.SYNOPSIS
    Closes out a K8-3 attempt: records the outcome, captures final
    repository state, stops the transcript, writes a manifest, and
    archives the attempt directory with a SHA-256 alongside it.

.DESCRIPTION
    Run this exactly once per attempt, whether it succeeded or failed.
    It does not judge Gate K8 and does not decide whether a reproduction
    "counts" -- it only closes the evidence record. Every step here is
    attempted independently (try/catch per step), so a failure partway
    through finalization does not erase evidence already collected.

.PARAMETER AttemptDir
    Path to an existing attempt directory.

.PARAMETER Outcome
    'Success' or 'Failed'. There is no in-between outcome this tool
    assigns; a partial/ambiguous run is 'Failed' with an explanatory
    -Reason -- do not invent a third status.

.PARAMETER Reason
    Free-text explanation. Mandatory in spirit, not just in syntax: an
    empty reason on a failed attempt is not acceptable review evidence.

.PARAMETER FailingCommand
    The step description or literal command that failed, if applicable.

.PARAMETER FailingExitCode
    The exit code observed, if applicable.

.EXAMPLE
    .\Study01\tools\Finalize-K8Attempt.ps1 -AttemptDir $AttemptDir -Outcome Failed `
        -Reason 'pytest not installed and README gave no install command at the mandatory apparatus test' `
        -FailingCommand 'python -m pytest tests -q' -FailingExitCode 1

.EXAMPLE
    .\Study01\tools\Finalize-K8Attempt.ps1 -AttemptDir $AttemptDir -Outcome Success `
        -Reason 'Range A/B/C completed; classifications recorded and compared per Sec6'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $AttemptDir,
    [Parameter(Mandatory)] [ValidateSet('Success', 'Failed')] [string] $Outcome,
    [Parameter(Mandatory)] [string] $Reason,
    [string] $FailingCommand = '',
    [Nullable[int]] $FailingExitCode = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'K8AttemptCommon.psm1') -Force

if (-not (Test-Path $AttemptDir)) {
    throw "Attempt directory does not exist: $AttemptDir"
}

$AttemptRoot = Split-Path -Parent $AttemptDir
$AttemptId   = Split-Path -Leaf $AttemptDir

$Paths = Get-K8AttemptPaths -AttemptRoot $AttemptRoot -AttemptId $AttemptId

Complete-K8Attempt -Paths $Paths -Outcome $Outcome -Reason $Reason `
    -FailingCommand $FailingCommand -FailingExitCode $FailingExitCode

Write-Host ''
Write-Host 'This attempt is now closed. Do not repair or retry it in place.'
Write-Host 'A retry, if any, is a new attempt with a new ID from Start-Study01.ps1.'
Write-Host 'This tool does not determine Gate K8; that is independent review.'
