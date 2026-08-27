#requires -Version 7.0
<#
.SYNOPSIS
    Runs one reproduction command with structured, exit-code-aware
    capture, and records it to this attempt's steps.jsonl.

.DESCRIPTION
    A thin wrapper around K8AttemptCommon.psm1's Invoke-K8Step, for
    operators who would rather call a script than import the module and
    manage a $Paths variable by hand.

    This does not remediate a failure. By default, any exit code other
    than 0 is treated as a failed step and stops the script (throws).
    If the protocol you are following expects a non-zero exit code for
    this specific command (for example the Range C validator), pass
    -ExpectedExitCode to match it -- do not treat that as a harness bug.

.PARAMETER AttemptDir
    Path to an existing attempt directory.

.PARAMETER Description
    Short human-readable label for this step, recorded in steps.jsonl
    and shown in the failure banner if it fails.

.PARAMETER Command
    A script block containing the command to run, e.g. { python -m pytest tests -q }

.PARAMETER ExpectedExitCode
    Exit codes that count as this step passing. Defaults to @(0).

.EXAMPLE
    .\Study01\tools\Invoke-K8Step.ps1 -AttemptDir 'C:\K8\attempts\k8-repro-20260828-001' `
        -Description 'apparatus integrity test' -Command { python -m pytest tests -q }

.EXAMPLE
    # Range C's validator is expected to fail; say so explicitly.
    .\Study01\tools\Invoke-K8Step.ps1 -AttemptDir $AttemptDir -Description 'Range C validation' `
        -Command { python platform/cli.py validate manifests/power-grid-reference.range-c-negative.yaml } `
        -ExpectedExitCode 1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $AttemptDir,
    [Parameter(Mandatory)] [string] $Description,
    [Parameter(Mandatory)] [scriptblock] $Command,
    [int[]] $ExpectedExitCode = @(0),
    [switch] $ContinueOnFailure
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

Invoke-K8Step -Paths $Paths -Description $Description -Command $Command `
    -ExpectedExitCode $ExpectedExitCode -ContinueOnFailure:$ContinueOnFailure
