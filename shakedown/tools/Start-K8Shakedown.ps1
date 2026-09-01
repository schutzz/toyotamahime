#Requires -Version 7.0
<#
.SYNOPSIS
    Shakedown Setup. Not a formal K8-3 attempt; not Gate K8 evidence.

.DESCRIPTION
    Runs once per Shakedown workspace. Idempotent: safe to re-run after fixing
    a problem partway through -- each stage checks whether it already
    succeeded (pinned commit already checked out, dependency already
    importable, image digest already present) before doing the work again.

    On failure, this script does NOT attempt a repair or substitute a
    different version/asset. It logs the failure and stops. Fix the branch,
    `git pull`, and re-run this same command.

.EXAMPLE
    .\tools\Start-K8Shakedown.ps1
#>
[CmdletBinding()]
param(
    [string] $ShakedownRoot = $(if ($env:K8_SHAKEDOWN_ROOT) { $env:K8_SHAKEDOWN_ROOT } else { 'C:\K8\shakedown' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'K8ShakedownCommon.psm1') -Force

$env:K8_SHAKEDOWN_ROOT = $ShakedownRoot
New-Item -ItemType Directory -Force -Path $ShakedownRoot | Out-Null

$RepoRoot = Split-Path -Parent $PSScriptRoot           # .../toyotamahime/shakedown
$RepoRoot = Split-Path -Parent $RepoRoot               # .../toyotamahime
$Study01 = Join-Path $RepoRoot 'Study01'
if (-not (Test-Path (Join-Path $Study01 'README.md'))) {
    throw "Study01/README.md not found at $Study01. Run this from a clone of the shakedown/k8-automation branch; do not copy this tools/ directory out on its own."
}

$C = Get-K8ShakedownConstants

Write-K8ShakedownLog -Level STEP -Message "=== Shakedown Setup starting. Workspace: $ShakedownRoot ==="
Write-K8ShakedownLog -Message "This is a Shakedown run: no k8-repro-* attempt ID is allocated, and nothing here is Gate K8 evidence."

# --- 1. Prerequisite readiness (informational + hard gates on PowerShell/git/python/docker) ---

Write-K8ShakedownLog -Level STEP -Message '--- 1. Prerequisite readiness ---'

$prereqs = [ordered]@{}

$prereqs['PowerShell'] = $PSVersionTable.PSVersion.ToString()
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ required (Study01/README.md SS3.1); found $($PSVersionTable.PSVersion). Git Bash/MSYS/Windows PowerShell 5.1 are not supported -- they rewrite bare in-container paths."
}

# C-8: these five probes carry TWO responsibilities, and the batch keeps them
# apart. The version VALUE is retained and never gated -- no frozen source
# pins one. The tool being EXECUTABLE is gated, because the code below already
# gated it and C-8 must not delete an existing fail-close. Only `wsl` is
# optional, which is what the current WARN-and-continue already says.
$toolVersions = @()

$gitVersion = Get-K8RequiredToolVersion -StepId 'C-56' -FilePath 'git' -ArgumentList @('--version') `
    -Requirement 'git is required to check out the pinned Amenonuboco commits'
$prereqs['git'] = $gitVersion['value']; $toolVersions += $gitVersion

$pythonVersion = Get-K8RequiredToolVersion -StepId 'C-57' -FilePath 'python' -ArgumentList @('--version') `
    -Requirement 'python is required by the frozen apparatus and the Range C validator'
$prereqs['python'] = $pythonVersion['value']; $toolVersions += $pythonVersion

$dockerVersion = Get-K8RequiredToolVersion -StepId 'C-58' -FilePath 'docker' -ArgumentList @('--version') `
    -Requirement 'Docker Desktop is required (Study01/README.md SS3.1)'
$prereqs['docker'] = $dockerVersion['value']; $toolVersions += $dockerVersion

$composeVersion = Get-K8RequiredToolVersion -StepId 'C-59' -FilePath 'docker' -ArgumentList @('compose', 'version') `
    -Requirement "'docker compose' (v2, not the v1 docker-compose binary) is required"
$prereqs['docker compose'] = $composeVersion['value']; $toolVersions += $composeVersion

# I-05, the only cross-boundary process site in the contract. Start-K8Shakedown
# calls the FROZEN Study01 export Get-K8WslField, which reaches
# System.Diagnostics.Process.Start inside Study01/tools/K8AttemptCommon.psm1.
# Both the AST and the lexical inventory oracles missed this, because both
# match on known native names and known Shakedown wrapper names; the
# reachability oracle finds it by asking which functions can reach a launch
# primitive at all.
#
# Optional by design, and its observation fidelity is limited by frozen code
# this batch must not change: Get-K8WslField folds a non-zero exit into an
# "unavailable: exit N : ..." STRING, so exit_code and stderr cannot be
# recovered here. They are recorded as null rather than reconstructed.
$wslVersion = Get-K8CollapsedToolObservation -StepId 'I-05' -Probe {
    if (Get-Command Get-K8WslField -ErrorAction SilentlyContinue) {
        # Reuses the formal harness's UTF-16LE-safe wsl.exe capture -- a plain
        # `wsl --version | Out-String` mojibakes on this platform (confirmed
        # by an actual dry run: it decodes as garbled UTF-16-as-narrow text).
        Get-K8WslField -Arguments '--version'
    } else {
        'unavailable: Get-K8WslField not found (Study01/tools/K8AttemptCommon.psm1 not importable)'
    }
}
$prereqs['wsl'] = $(if ($wslVersion['value']) { $wslVersion['value'] } else { 'unavailable: no wsl observation' })
$toolVersions += $wslVersion
if ($wslVersion['status'] -ne 'succeeded') {
    Write-K8ShakedownLog -Level WARN -Message "wsl --version was not observed ($($wslVersion['status'])); recorded informationally, not treated as a hard gate (Docker Desktop's own readiness is what matters)."
}

foreach ($k in $prereqs.Keys) { Write-K8ShakedownLog -Message "prereq $k -> $($prereqs[$k])" }
Set-K8ShakedownState -Updates @{
    prereqs = $prereqs; shakedown_root = $ShakedownRoot; repo_root = $RepoRoot
    # Retained in the Shakedown state so each run can COPY it into its own
    # control-plane record without starting a second set of version probes.
    tool_versions = $toolVersions
}

# --- 2. pytest + apparatus integrity test (README SS3.1) ---

Write-K8ShakedownLog -Level STEP -Message '--- 2. pytest install + apparatus integrity test ---'
Invoke-K8ShakedownCommand -StepId 'C-47' -FilePath 'python' -ArgumentList @('-m', 'pip', 'install', 'pytest') -Description 'apparatus-test dependency'

Push-Location $Study01
try {
    $result = Invoke-K8ShakedownCommand -StepId 'C-48' -FilePath 'python' `
        -ArgumentList @('-m', 'pytest', 'studies/study-01-negative-result/scripts/tests', '-q') `
        -Description 'apparatus integrity test (README SS3.1) -- must show 69 passed'
    Set-K8ShakedownState -Updates @{ apparatus_integrity = 'PASS'; apparatus_integrity_output_tail = ($result.Output | Select-Object -Last 5) }
}
finally {
    Pop-Location
}

# --- 3. Amenonuboco Range A/B generator checkout (pinned commit) ---

Write-K8ShakedownLog -Level STEP -Message '--- 3. Amenonuboco Range A/B generator checkout ---'
$rangeGenDir = Join-Path $ShakedownRoot 'amenonuboco-gen'
# C-54: an EXPLORATION, not an assertion. The -and short-circuits, so this only
# runs when .git exists; the reachable non-zero state is an unborn HEAD left by
# an interrupted `git init` + fetch, where git exits 128 while printing "HEAD"
# on stdout. The comparison then fails and the else branch does a clean
# re-checkout, which is correct. The row accepts @(0, 128) for exactly that
# reason -- a blanket "non-zero STOPs" would break Setup. Observing the exit
# also puts on record that the current behaviour rests on git printing a
# non-SHA string, rather than on the exit code being checked.
if ((Test-Path (Join-Path $rangeGenDir '.git')) -and ((Get-K8ContractedNativeText -StepId 'C-54' -FilePath 'git' -ArgumentList @('-C', $rangeGenDir, 'rev-parse', 'HEAD')) -eq $C.RangeGenCommit)) {
    Write-K8ShakedownLog -Message "amenonuboco-gen already at pinned commit $($C.RangeGenCommit); skipping checkout."
}
else {
    if (Test-Path $rangeGenDir) {
        Write-K8ShakedownLog -Level WARN -Message "Removing incomplete/stale $rangeGenDir before a fresh checkout (not a repair of a failed run -- a clean re-checkout of the same pin)."
        Remove-Item -Recurse -Force $rangeGenDir
    }
    New-Item -ItemType Directory -Force -Path $rangeGenDir | Out-Null
    Invoke-K8ShakedownCommand -StepId 'C-49' -FilePath 'git' -ArgumentList @('init', $rangeGenDir)
    Invoke-K8ShakedownCommand -StepId 'C-50' -FilePath 'git' -ArgumentList @('-C', $rangeGenDir, 'remote', 'add', 'origin', $C.AmenonubocoUrl)
    Invoke-K8ShakedownCommand -StepId 'C-51' -FilePath 'git' -ArgumentList @('-C', $rangeGenDir, 'fetch', '--depth=1', 'origin', $C.RangeGenCommit)
    Invoke-K8ShakedownCommand -StepId 'C-52' -FilePath 'git' -ArgumentList @('-C', $rangeGenDir, 'checkout', 'FETCH_HEAD')
}
Assert-K8PinnedCommit -WorktreePath $rangeGenDir -ExpectedCommit $C.RangeGenCommit -Label 'amenonuboco-gen'

# --- 4. Amenonuboco Range C validator checkout (pinned tag/commit) ---

Write-K8ShakedownLog -Level STEP -Message '--- 4. Amenonuboco Range C validator checkout ---'
$rangeCDir = Join-Path $ShakedownRoot 'amenonuboco-v0.13.0'
# C-55: the same exploration as C-54, for the Range C validator worktree.
if ((Test-Path (Join-Path $rangeCDir '.git')) -and ((Get-K8ContractedNativeText -StepId 'C-55' -FilePath 'git' -ArgumentList @('-C', $rangeCDir, 'rev-parse', 'HEAD')) -eq $C.RangeCCommit)) {
    Write-K8ShakedownLog -Message "amenonuboco-v0.13.0 already at pinned commit $($C.RangeCCommit); skipping checkout."
}
else {
    if (Test-Path $rangeCDir) {
        Write-K8ShakedownLog -Level WARN -Message "Removing incomplete/stale $rangeCDir before a fresh checkout."
        Remove-Item -Recurse -Force $rangeCDir
    }
    Invoke-K8ShakedownCommand -StepId 'C-53' -FilePath 'git' -ArgumentList @('clone', '--branch', $C.RangeCTag, '--depth=1', $C.AmenonubocoUrl, $rangeCDir)
}
Assert-K8PinnedCommit -WorktreePath $rangeCDir -ExpectedCommit $C.RangeCCommit -Label 'amenonuboco-v0.13.0'

# --- 5. Range C dependency install (cp932-safe) ---

Write-K8ShakedownLog -Level STEP -Message '--- 5. Range C dependency install (locale-safe) ---'
Install-K8RangeCDependencies -RequirementsPath (Join-Path $rangeCDir 'requirements.txt')

# --- 6. tcpdump capture helper, pinned by digest ---

Write-K8ShakedownLog -Level STEP -Message '--- 6. tcpdump capture helper image (pinned digest) ---'
$imageRef = "$($C.TcpdumpImage)@$($C.TcpdumpDigest)"
Invoke-K8ShakedownCommand -StepId 'F-36' -FilePath 'docker' -ArgumentList @('pull', $imageRef) -Description 'pinned capture helper'
# F-37: this is the step that VERIFIES the frozen pinned digest, and before
# C-8 the verification itself left no argv and no exit code behind.
$inspected = Get-K8ContractedNativeText -StepId 'F-37' -FilePath 'docker' -ArgumentList @('inspect', '--format', '{{index .RepoDigests 0}}', $imageRef)
if ($inspected -notmatch [regex]::Escape($C.TcpdumpDigest)) {
    throw "tcpdump image digest mismatch after pull: expected $($C.TcpdumpDigest), docker inspect reported '$inspected'."
}
Write-K8ShakedownLog -Message "tcpdump digest verified: $inspected"

# --- Done ---

Set-K8ShakedownState -Updates @{
    setup_complete_utc = (Get-Date).ToUniversalTime().ToString('o')
    amenonuboco_gen_dir = $rangeGenDir
    amenonuboco_rangec_dir = $rangeCDir
    tcpdump_image_ref = $imageRef
}

Write-K8ShakedownLog -Level STEP -Message '=== Shakedown Setup PASS ==='
Write-Host ''
Write-Host 'Setup complete. Next:'
Write-Host '  .\tools\Run-K8ShakedownRangeA.ps1'
