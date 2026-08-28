#requires -Version 7.0
<#
.SYNOPSIS
    Captures (or re-captures) the K8-3 attempt environment record for the
    current attempt.

.DESCRIPTION
    Start-Study01.ps1 calls this automatically right after a successful
    clone. You normally do not need to run it yourself; it is provided
    as a standalone script so environment capture can be re-run or
    inspected without repeating the clone, and so it can be tested
    independently of the bootstrap flow. The current attempt is resolved
    automatically -- you do not need to pass its path.

.PARAMETER AttemptDir
    Advanced/debug override. Normal use resolves the current attempt
    automatically; you should not need this.

.PARAMETER AttemptRootHint
    Advanced/debug: where to look for the current-attempt pointer file
    in a fresh PowerShell session, if you ran Start-Study01.ps1 with a
    non-default -AttemptRoot. Normal use never needs this.

.EXAMPLE
    .\tools\Initialize-K8Attempt.ps1
#>

[CmdletBinding()]
param(
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

Initialize-K8AttemptEnvironment -Paths $Paths
