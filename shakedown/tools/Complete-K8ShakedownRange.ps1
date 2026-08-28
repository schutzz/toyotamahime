#Requires -Version 7.0
<#
.SYNOPSIS
    Second half of a Shakedown Range A or B run. Not a formal K8-3 attempt;
    not Gate K8 evidence.

.DESCRIPTION
    Run-K8ShakedownRange{A,B}.ps1 leaves the range running after capture and
    the sender trigger, because the Collector query (ot-logs-dnp3-*) and Rule
    query (ot-signals-zone-violation-*) -- and, for Range B, the R-OBS-05
    liveness query -- can only be executed against a still-running
    Elasticsearch, and evidence-schema.md's own cleanup ordering requires
    every required artifact to be exported before the project is torn down.

    Run this ONLY after saving the real query responses:
      <run-evidence>\collector-output\  (from environment\collector-query.json)
      <run-evidence>\rule-output\       (from environment\rule-query.json)
      <run-evidence>\contract-output\   (Range B: from environment\r-obs-05-query.json)

    This script refuses to proceed (does not fill anything in, does not
    tear down) if collector-output/ or rule-output/ is still empty.

.PARAMETER Range
    'a' or 'b' -- which run to complete. Required: this script never guesses
    which range you mean.

.EXAMPLE
    .\tools\Complete-K8ShakedownRange.ps1 -Range a
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('a', 'b')][string] $Range
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'K8ShakedownCommon.psm1') -Force
Complete-K8ShakedownRangeAB -Range $Range
