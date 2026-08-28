#requires -Version 7.0
<#
.SYNOPSIS
    Closes the current K8-3 attempt in one short command.

.DESCRIPTION
    Run this exactly once per attempt, whether it succeeded or failed.
    The current attempt, its last recorded step, and its repository
    state are all resolved automatically -- you do not need to pass an
    attempt path, and if the attempt's last Invoke-K8Step.ps1 call
    failed, its command and exit code are filled in for you unless you
    override them.

    This does not judge Gate K8 and does not decide whether a
    reproduction "counts" -- it only closes the evidence record. Every
    finalization step is attempted independently, so a failure partway
    through (for example, an archive that already exists) does not erase
    evidence already collected.

    Default outcome is Failed, since closing a failed attempt is the
    common case this script exists to make short. Pass -Success to close
    a successful one instead.

.PARAMETER Reason
    Free-text explanation. The only thing you normally need to type.

.PARAMETER Success
    Close this attempt as Success rather than the default, Failed.

.PARAMETER FailingCommand
    Override the auto-detected failing step description. Leave unset to
    use the last recorded steps.jsonl entry, if it failed.

.PARAMETER FailingExitCode
    Override the auto-detected failing exit code. Leave unset to use the
    last recorded steps.jsonl entry, if it failed.

.PARAMETER AttemptDir
    Advanced/debug override. Normal use resolves the current attempt
    automatically; you should not need this.

.EXAMPLE
    .\tools\Stop-K8.ps1 'README did not expose attempt context'

.EXAMPLE
    .\tools\Stop-K8.ps1 -Success 'Range A/B/C completed and compared against expected/'
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Reason = '',
    [switch] $Success,
    [string] $FailingCommand = '',
    [Nullable[int]] $FailingExitCode = $null,
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

$Outcome =
    if ($Success) { 'Success' } else { 'Failed' }

# Auto-populate failing command/exit code from the last recorded step,
# if the caller didn't already say what they were. Only for a Failed
# close, and only if that last step actually failed -- never invented.
if ($Outcome -eq 'Failed' -and -not $FailingCommand -and $null -eq $FailingExitCode) {
    $LastStep = Get-K8LastStep -Paths $Paths

    if ($LastStep -and -not $LastStep.passed) {
        $FailingCommand  = $LastStep.description
        $FailingExitCode = $LastStep.exit_code
    }
}

Complete-K8Attempt -Paths $Paths -Outcome $Outcome -Reason $Reason `
    -FailingCommand $FailingCommand -FailingExitCode $FailingExitCode

Write-Host ''
Write-Host 'This attempt is now closed. Do not repair or retry it in place.'
Write-Host 'A retry, if any, is a new attempt with a new ID from Start-Study01.ps1.'
Write-Host 'This tool does not determine Gate K8; that is independent review.'
