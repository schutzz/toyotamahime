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

try {
    $prereqs['git'] = (git --version).Trim()
} catch { throw "git not found on PATH." }

try {
    $prereqs['python'] = (python --version 2>&1).Trim()
} catch { throw "python not found on PATH." }

try {
    $prereqs['docker'] = (docker --version).Trim()
} catch { throw "docker not found on PATH. Docker Desktop is required (Study01/README.md SS3.1)." }

try {
    $prereqs['docker compose'] = (docker compose version).Trim()
} catch { throw "'docker compose' (v2, not docker-compose) not found." }

try {
    if (Get-Command Get-K8WslField -ErrorAction SilentlyContinue) {
        # Reuses the formal harness's UTF-16LE-safe wsl.exe capture -- a plain
        # `wsl --version | Out-String` mojibakes on this platform (confirmed
        # by an actual dry run: it decodes as garbled UTF-16-as-narrow text).
        $prereqs['wsl'] = (Get-K8WslField -Arguments '--version')
    } else {
        $prereqs['wsl'] = 'unavailable: Get-K8WslField not found (Study01/tools/K8AttemptCommon.psm1 not importable)'
    }
} catch {
    $prereqs['wsl'] = "unavailable: $($_.Exception.Message)"
    Write-K8ShakedownLog -Level WARN -Message "wsl --version failed; recorded informationally, not treated as a hard gate (Docker Desktop's own readiness is what matters)."
}

foreach ($k in $prereqs.Keys) { Write-K8ShakedownLog -Message "prereq $k -> $($prereqs[$k])" }
Set-K8ShakedownState -Updates @{ prereqs = $prereqs; shakedown_root = $ShakedownRoot; repo_root = $RepoRoot }

# --- 2. pytest + apparatus integrity test (README SS3.1) ---

Write-K8ShakedownLog -Level STEP -Message '--- 2. pytest install + apparatus integrity test ---'
Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @('-m', 'pip', 'install', 'pytest') -Description 'apparatus-test dependency'

Push-Location $Study01
try {
    $result = Invoke-K8ShakedownCommand -FilePath 'python' `
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
if ((Test-Path (Join-Path $rangeGenDir '.git')) -and ((git -C $rangeGenDir rev-parse HEAD 2>$null).Trim() -eq $C.RangeGenCommit)) {
    Write-K8ShakedownLog -Message "amenonuboco-gen already at pinned commit $($C.RangeGenCommit); skipping checkout."
}
else {
    if (Test-Path $rangeGenDir) {
        Write-K8ShakedownLog -Level WARN -Message "Removing incomplete/stale $rangeGenDir before a fresh checkout (not a repair of a failed run -- a clean re-checkout of the same pin)."
        Remove-Item -Recurse -Force $rangeGenDir
    }
    New-Item -ItemType Directory -Force -Path $rangeGenDir | Out-Null
    Invoke-K8ShakedownCommand -FilePath 'git' -ArgumentList @('init', $rangeGenDir)
    Invoke-K8ShakedownCommand -FilePath 'git' -ArgumentList @('-C', $rangeGenDir, 'remote', 'add', 'origin', $C.AmenonubocoUrl)
    Invoke-K8ShakedownCommand -FilePath 'git' -ArgumentList @('-C', $rangeGenDir, 'fetch', '--depth=1', 'origin', $C.RangeGenCommit)
    Invoke-K8ShakedownCommand -FilePath 'git' -ArgumentList @('-C', $rangeGenDir, 'checkout', 'FETCH_HEAD')
}
Assert-K8PinnedCommit -WorktreePath $rangeGenDir -ExpectedCommit $C.RangeGenCommit -Label 'amenonuboco-gen'

# --- 4. Amenonuboco Range C validator checkout (pinned tag/commit) ---

Write-K8ShakedownLog -Level STEP -Message '--- 4. Amenonuboco Range C validator checkout ---'
$rangeCDir = Join-Path $ShakedownRoot 'amenonuboco-v0.13.0'
if ((Test-Path (Join-Path $rangeCDir '.git')) -and ((git -C $rangeCDir rev-parse HEAD 2>$null).Trim() -eq $C.RangeCCommit)) {
    Write-K8ShakedownLog -Message "amenonuboco-v0.13.0 already at pinned commit $($C.RangeCCommit); skipping checkout."
}
else {
    if (Test-Path $rangeCDir) {
        Write-K8ShakedownLog -Level WARN -Message "Removing incomplete/stale $rangeCDir before a fresh checkout."
        Remove-Item -Recurse -Force $rangeCDir
    }
    Invoke-K8ShakedownCommand -FilePath 'git' -ArgumentList @('clone', '--branch', $C.RangeCTag, '--depth=1', $C.AmenonubocoUrl, $rangeCDir)
}
Assert-K8PinnedCommit -WorktreePath $rangeCDir -ExpectedCommit $C.RangeCCommit -Label 'amenonuboco-v0.13.0'

# --- 5. Range C dependency install (cp932-safe) ---

Write-K8ShakedownLog -Level STEP -Message '--- 5. Range C dependency install (locale-safe) ---'
Install-K8RangeCDependencies -RequirementsPath (Join-Path $rangeCDir 'requirements.txt')

# --- 6. tcpdump capture helper, pinned by digest ---

Write-K8ShakedownLog -Level STEP -Message '--- 6. tcpdump capture helper image (pinned digest) ---'
$imageRef = "$($C.TcpdumpImage)@$($C.TcpdumpDigest)"
Invoke-K8ShakedownCommand -FilePath 'docker' -ArgumentList @('pull', $imageRef) -Description 'pinned capture helper'
$inspected = (docker inspect --format '{{index .RepoDigests 0}}' $imageRef 2>&1 | Out-String).Trim()
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
