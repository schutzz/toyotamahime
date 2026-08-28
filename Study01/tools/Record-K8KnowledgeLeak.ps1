#requires -Version 7.0
<#
.SYNOPSIS
    Records one knowledge-leak-log entry for the current K8-3 attempt in
    a single short command.

.DESCRIPTION
    Plan Sec6.2 requires a knowledge-leak log: one entry each time an
    action is taken, or needed, that the README did not license -- a
    path known from memory, a flag known from experience, a fix applied
    by reflex. The current attempt is resolved automatically -- you do
    not need to know or pass its path.

.PARAMETER Reason
    What was needed, and why the README did not license it. The only
    thing you normally need to type.

.PARAMETER ActionTaken
    What you actually did about it. Leave empty if you stopped instead
    of acting -- that is a legitimate and expected answer.

.PARAMETER LicensedByReadme
    Pass this switch only if, on reflection, the README did license the
    action after all. Default is "not licensed."

.PARAMETER PriorKnowledgeUsed
    Pass this switch if you used knowledge from outside the README to
    proceed. Default is "no."

.PARAMETER AttemptDir
    Advanced/debug override. Normal use resolves the current attempt
    automatically; you should not need this.

.EXAMPLE
    .\tools\Record-K8KnowledgeLeak.ps1 'README did not specify a pytest install command before the mandatory apparatus test'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)] [string] $Reason,
    [string] $ActionTaken = '',
    [switch] $LicensedByReadme,
    [switch] $PriorKnowledgeUsed,
    [string] $AttemptDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'K8AttemptCommon.psm1') -Force

$ResolvedAttemptDir =
    Resolve-K8AttemptDir -Explicit $AttemptDir

$AttemptRoot = Split-Path -Parent $ResolvedAttemptDir
$AttemptId   = Split-Path -Leaf $ResolvedAttemptDir

$Paths = Get-K8AttemptPaths -AttemptRoot $AttemptRoot -AttemptId $AttemptId

Add-K8KnowledgeLeak -Paths $Paths -Reason $Reason -ActionTaken $ActionTaken `
    -LicensedByReadme:$LicensedByReadme -PriorKnowledgeUsed:$PriorKnowledgeUsed
