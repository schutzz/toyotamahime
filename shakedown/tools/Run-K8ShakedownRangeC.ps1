#Requires -Version 7.0
<#
.SYNOPSIS
    Shakedown Range C. Not a formal K8-3 attempt; not Gate K8 evidence.

.DESCRIPTION
    Mechanically sequences Study01/README.md SS5.3 and
    protocol/c2-dnp3-range-derivation.md SS4: a disposable worktree copied
    from the pinned Range C validator checkout, the frozen negative-manifest
    patch applied via a literal string substitution against the fixed patch,
    then exactly one command:

        python platform/cli.py validate manifests/power-grid-reference.range-c-negative.yaml

    Range C is never provisioned. This script never calls `docker compose up`
    for Range C, in any form.

    A validator exit code of 1 is the EXPECTED outcome (README SS5.3/SS6.1),
    not a failure this script raises on. Every exit code is retained as an
    observation; the runner does not force, retry toward, or editorialize
    about a particular result.

.EXAMPLE
    .\tools\Run-K8ShakedownRangeC.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'K8ShakedownCommon.psm1') -Force

$state = Get-K8ShakedownState
$Study01 = Join-Path $state.repo_root 'Study01'
$PatchSource = Join-Path $Study01 'studies\study-01-negative-result\experiments\range-c-negative-manifest\power-grid-reference.range-c-negative.patch'
if (-not (Test-Path $PatchSource)) { throw "Frozen Range C patch not found at $PatchSource" }

$RunId = New-K8ShakedownRunId -Range c
$RunEvidence = Join-Path $state.shakedown_root "runs\$RunId"
New-Item -ItemType Directory -Force -Path $RunEvidence | Out-Null

Write-K8ShakedownLog -Level STEP -Message "=== Shakedown Range C starting: $RunId ==="

# 1. Disposable worktree copied from the pinned v0.13.0 checkout; confirm clean before use.
$rangeCSource = $state.amenonuboco_rangec_dir
$disposable = Join-Path $state.shakedown_root "runs\$RunId\worktree"
$sourceStatus = (git -C $rangeCSource status --porcelain | Out-String).Trim()
if ($sourceStatus) {
    throw "Range C source checkout $rangeCSource is not clean before copy:`n$sourceStatus`nNot proceeding -- this is a STOP condition, not something to auto-fix (e.g. from a leftover prior Shakedown run)."
}
Assert-K8PinnedCommit -WorktreePath $rangeCSource -ExpectedCommit (Get-K8ShakedownConstants).RangeCCommit -Label 'Range C source worktree (pre-copy)'

Write-K8ShakedownLog -Message "Copying $rangeCSource -> $disposable"
Copy-Item -Recurse -Force -Path $rangeCSource -Destination $disposable
Assert-K8PinnedCommit -WorktreePath $disposable -ExpectedCommit (Get-K8ShakedownConstants).RangeCCommit -Label 'Range C disposable worktree (post-copy)'

# 2. Derive the negative manifest: copy base manifest under the negative-manifest filename,
#    then apply the fixed patch retargeted to that filename via literal string substitution
#    (c2-dnp3-range-derivation.md SS4 -- a known maintenance limitation, not a second patch
#    mechanism; not changed here).
$baseManifest = Join-Path $disposable 'manifests\power-grid-reference.yaml'
$negativeManifest = Join-Path $disposable 'manifests\power-grid-reference.range-c-negative.yaml'
if (-not (Test-Path $baseManifest)) { throw "Base manifest not found at $baseManifest" }
Copy-Item -Path $baseManifest -Destination $negativeManifest
# Preserve the base manifest's own CRLF line terminators: Copy-Item is a byte copy, not a text
# rewrite, so this does not normalize newlines. Confirmed by the byte-count check below.
if ((Get-Item $baseManifest).Length -ne (Get-Item $negativeManifest).Length) {
    throw "Negative manifest copy is not byte-identical in size to the base manifest; newline translation may have occurred. Not proceeding."
}

$patchRaw = Get-Content -Raw -Path $PatchSource
$derivedPatch = Join-Path $disposable 'range-c-derived.patch'
$patchRaw.Replace('power-grid-reference.yaml', 'power-grid-reference.range-c-negative.yaml') | Set-Content -NoNewline -Path $derivedPatch -Encoding utf8NoBOM

Push-Location $disposable
try {
    Invoke-K8ShakedownCommand -FilePath 'git' -ArgumentList @('apply', '--ignore-space-change', '--check', $derivedPatch) -Description 'derived patch check'
    Invoke-K8ShakedownCommand -FilePath 'git' -ArgumentList @('apply', '--ignore-space-change', $derivedPatch) -Description 'derived patch apply'

    # 3. Exactly one command. Byte-exact stdout/stderr capture via cmd.exe redirection
    #    (PowerShell's own pipeline capture re-encodes text; this does not).
    $stdoutPath = Join-Path $RunEvidence 'validate.stdout.txt'
    $stderrPath = Join-Path $RunEvidence 'validate.stderr.txt'
    Write-K8ShakedownLog -Level STEP -Message 'RUN: python platform/cli.py validate manifests/power-grid-reference.range-c-negative.yaml'
    $pyVersion = (python --version 2>&1 | Out-String).Trim()
    & cmd.exe /c "python platform\cli.py validate manifests\power-grid-reference.range-c-negative.yaml > `"$stdoutPath`" 2> `"$stderrPath`""
    $exitCode = $LASTEXITCODE
    Write-K8ShakedownLog -Message "validate exit code: $exitCode (exit 1 is the EXPECTED outcome per README SS5.3/SS6.1 -- not treated as failure)"
}
finally { Pop-Location }

# 4. Retain: derived manifest, derivation, command, stdout, stderr, exit code, tool versions.
Copy-Item -Path $negativeManifest -Destination (Join-Path $RunEvidence 'power-grid-reference.range-c-negative.yaml')
Copy-Item -Path $derivedPatch -Destination (Join-Path $RunEvidence 'range-c-derived.patch')
@"
# Range C validation record -- $RunId (Shakedown, NOT a formal K8-3 attempt, NOT Gate K8 evidence)

| Field | Value |
| --- | --- |
| Source worktree | $rangeCSource (pinned $((Get-K8ShakedownConstants).RangeCCommit)) |
| Disposable worktree | $disposable |
| Command | python platform/cli.py validate manifests/power-grid-reference.range-c-negative.yaml |
| Exit code | $exitCode |
| Python | $pyVersion |
| stdout | validate.stdout.txt (raw bytes, no newline translation) |
| stderr | validate.stderr.txt (raw bytes, no newline translation) |

Expected, not forced (README SS5.3/SS6.1): exit 1, empty stdout, stderr naming
observability_contract.required_segments and sub_a_l2_lan. This record states
what was actually observed; compare it against expected/range-c/ yourself
before drawing a conclusion.
"@ | Set-Content -Path (Join-Path $RunEvidence 'metadata.md') -Encoding utf8NoBOM

Remove-Item -Recurse -Force $disposable
Write-K8ShakedownLog -Message "Disposable worktree removed after retention (README SS5.2: only the disposable worktree and generated static artifacts are removed; no Docker cleanup applies to Range C)."

Set-K8ShakedownState -Updates @{ range_c_run_id = $RunId; range_c_evidence = $RunEvidence; range_c_exit_code = $exitCode; range_c_complete_utc = (Get-Date).ToUniversalTime().ToString('o') }

Write-K8ShakedownLog -Level STEP -Message "=== Shakedown Range C complete: $RunId (validator exit $exitCode) ==="
Write-Host ''
Write-Host "Range C evidence: $RunEvidence"
Write-Host 'Compare validate.stdout.txt / validate.stderr.txt / exit code against Study01/expected/range-c/ yourself.'
