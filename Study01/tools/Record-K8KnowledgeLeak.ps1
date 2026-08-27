#requires -Version 7.0
<#
.SYNOPSIS
    Records one knowledge-leak-log entry for the current K8-3 attempt in
    a single short command.

.DESCRIPTION
    Plan Sec6.2 requires a knowledge-leak log: one entry each time an
    action is taken, or needed, that the README did not license -- a
    path known from memory, a flag known from experience, a fix applied
    by reflex. This script appends one entry without requiring you to
    hand-author a markdown file (as Attempt 001 had to).

.PARAMETER AttemptDir
    Path to an existing attempt directory.

.PARAMETER Reason
    What was needed, and why the README did not license it.

.PARAMETER ActionTaken
    What you actually did about it. Leave empty if you stopped instead
    of acting -- that is a legitimate and expected answer.

.PARAMETER LicensedByReadme
    Pass this switch only if, on reflection, the README did license the
    action after all (e.g. you initially thought it did not, but found
    the step). Default is "not licensed."

.PARAMETER PriorKnowledgeUsed
    Pass this switch if you used knowledge from outside the README to
    proceed. Default is "no."

.EXAMPLE
    .\Study01\tools\Record-K8KnowledgeLeak.ps1 -AttemptDir $AttemptDir `
        -Reason 'README did not specify a pytest install command before the mandatory apparatus test'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $AttemptDir,
    [Parameter(Mandatory)] [string] $Reason,
    [string] $ActionTaken = '',
    [switch] $LicensedByReadme,
    [switch] $PriorKnowledgeUsed
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

Add-K8KnowledgeLeak -Paths $Paths -Reason $Reason -ActionTaken $ActionTaken `
    -LicensedByReadme:$LicensedByReadme -PriorKnowledgeUsed:$PriorKnowledgeUsed
