#requires -Version 7.0
<#
.SYNOPSIS
    Captures (or re-captures) the K8-3 attempt environment record for an
    already-created attempt directory.

.DESCRIPTION
    bootstrap/Start-Study01.ps1 calls this automatically right after a
    successful clone. You normally do not need to run it yourself; it is
    provided as a standalone script so environment capture can be re-run
    or inspected without repeating the clone, and so it can be tested
    independently of the bootstrap flow.

.PARAMETER AttemptDir
    Path to an existing attempt directory, e.g. C:\K8\attempts\k8-repro-20260828-001

.EXAMPLE
    .\Study01\tools\Initialize-K8Attempt.ps1 -AttemptDir 'C:\K8\attempts\k8-repro-20260828-001'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $AttemptDir
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

Initialize-K8AttemptEnvironment -Paths $Paths
