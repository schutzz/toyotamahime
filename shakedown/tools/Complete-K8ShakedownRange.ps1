#Requires -Version 7.0
<#
.SYNOPSIS
    Second half of a Shakedown Range A or B run. Not a formal K8-3 attempt;
    not Gate K8 evidence.

.DESCRIPTION
    The Range runner has already retained all fixed query responses and
    mechanical correlations. This script validates and hashes that complete
    runtime evidence before teardown, destroys project/volumes, records the
    cleanup result, then re-hashes and verifies the final evidence tree. It
    refuses teardown when a required artifact or Range B gate is absent.

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
