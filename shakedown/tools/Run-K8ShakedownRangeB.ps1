#Requires -Version 7.0
<#
.SYNOPSIS
    Shakedown Range B. Not a formal K8-3 attempt; not Gate K8 evidence.

.DESCRIPTION
    Thin wrapper: allocates a Shakedown run ID (k8shakedown-rangeb-*, never
    k8-repro-*) and calls the shared Range A/B mechanical sequencer in
    K8ShakedownCommon.psm1 with -Range b, which additionally applies the sole
    permitted fault (ingress qdisc deletion on the resolved gateway
    interface) and writes the R-OBS-05 query for manual execution. See that
    module for what is and is not automated.

.EXAMPLE
    .\tools\Run-K8ShakedownRangeB.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'K8ShakedownCommon.psm1') -Force
Invoke-K8ShakedownRangeAB -Range b
