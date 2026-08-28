#requires -Version 7.0
<#
.SYNOPSIS
    Runs one reproduction command with structured, exit-code-aware
    capture, and records it to the current attempt's steps.jsonl.

.DESCRIPTION
    A thin wrapper around K8AttemptCommon.psm1's Invoke-K8Step. The
    current attempt is resolved automatically (Resolve-K8AttemptDir) --
    you do not need to know or pass its path in normal use.

    This does not remediate a failure. By default, any exit code other
    than 0 is treated as a failed step and stops the script (throws).
    If the protocol you are following expects a non-zero exit code for
    this specific command (for example the Range C validator), pass
    -ExpectedExitCode to match it -- do not treat that as a harness bug.

.PARAMETER Description
    Short human-readable label for this step, recorded in steps.jsonl
    and shown in the failure banner if it fails.

.PARAMETER Command
    A script block containing the command to run, e.g. { python -m pytest tests -q }

.PARAMETER ExpectedExitCode
    Exit codes that count as this step passing. Defaults to @(0).

.PARAMETER AttemptDir
    Advanced/debug override. Normal use resolves the current attempt
    automatically; you should not need this.

.PARAMETER AttemptRootHint
    Advanced/debug: where to look for the current-attempt pointer file
    in a fresh PowerShell session, if you ran Start-Study01.ps1 with a
    non-default -AttemptRoot. Normal use (the default -AttemptRoot)
    never needs this.

.EXAMPLE
    .\tools\Invoke-K8Step.ps1 -Description 'apparatus integrity test' `
        -Command { python -m pytest tests -q }

.EXAMPLE
    # Range C's validator is expected to fail; say so explicitly.
    .\tools\Invoke-K8Step.ps1 -Description 'Range C validation' `
        -Command { python platform/cli.py validate manifests/power-grid-reference.range-c-negative.yaml } `
        -ExpectedExitCode 1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Description,
    [Parameter(Mandatory)] [scriptblock] $Command,
    [int[]] $ExpectedExitCode = @(0),
    [switch] $ContinueOnFailure,
    [string] $AttemptDir = '',
    [string] $AttemptRootHint = 'C:\K8\attempts'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'K8AttemptCommon.psm1') -Force

$ResolvedAttemptDir =
    Resolve-K8AttemptDir -Explicit $AttemptDir -AttemptRootHint $AttemptRootHint

$AttemptRoot = Split-Path -Parent $ResolvedAttemptDir
$AttemptId   = Split-Path -Leaf $ResolvedAttemptDir

$Paths = Get-K8AttemptPaths -AttemptRoot $AttemptRoot -AttemptId $AttemptId

Invoke-K8Step -Paths $Paths -Description $Description -Command $Command `
    -ExpectedExitCode $ExpectedExitCode -ContinueOnFailure:$ContinueOnFailure
