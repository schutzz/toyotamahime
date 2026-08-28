#Requires -Version 7.0
<#
.SYNOPSIS
    Shakedown Range B. Not a formal K8-3 attempt; not Gate K8 evidence.

.DESCRIPTION
    Thin wrapper: allocates a Shakedown run ID (k8shakedown-rangeb-*, never
    k8-repro-*) and calls the shared Range A/B mechanical sequencer in
    K8ShakedownCommon.psm1 with -Range b, which additionally applies the sole
    permitted fault (ingress qdisc deletion on the resolved gateway
    interface) and executes the fixed R-OBS-05 mapping/query/correlation gates. See that
    module for what is and is not automated.

    This is phase 1 of 2. It leaves the range RUNNING only for ordered
    pre-teardown hashing. Run Complete next.

.EXAMPLE
    .\tools\Run-K8ShakedownRangeB.ps1
    .\tools\Complete-K8ShakedownRange.ps1 -Range b
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'K8ShakedownCommon.psm1') -Force
Invoke-K8ShakedownRangeAB -Range b
