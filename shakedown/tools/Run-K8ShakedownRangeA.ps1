#Requires -Version 7.0
<#
.SYNOPSIS
    Shakedown Range A. Not a formal K8-3 attempt; not Gate K8 evidence.

.DESCRIPTION
    Thin wrapper: allocates a Shakedown run ID (k8shakedown-rangea-*, never
    k8-repro-*) and calls the shared Range A/B mechanical sequencer in
    K8ShakedownCommon.psm1. See that module for what is and is not automated.

    This is phase 1 of 2. It executes and retains the fixed Collector/Rule
    requests and mechanical ID correlation, then leaves the range RUNNING for
    ordered pre-teardown hashing. Run Complete next.

.EXAMPLE
    .\tools\Run-K8ShakedownRangeA.ps1
    .\tools\Complete-K8ShakedownRange.ps1 -Range a
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'K8ShakedownCommon.psm1') -Force
Invoke-K8ShakedownRangeAB -Range a
