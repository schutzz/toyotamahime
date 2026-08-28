#requires -Version 7.0
<#
.SYNOPSIS
    K8-3 attempt bootstrap: creates the attempt evidence directory, starts
    its transcript, clones the public Toyotamahime repository, records the
    exact clone HEAD, and hands off to the repo-local harness.

.DESCRIPTION
    This script exists solely to solve one ordering problem: a K8-3
    attempt's ordered transcript should include `git clone` itself, but
    the repo-local harness (Study01/tools/) does not exist on disk until
    after that clone completes. So this script duplicates, in minimal
    form, exactly the pre-clone steps that Study01/tools/K8AttemptCommon.psm1
    also implements for later, repo-local use (New-K8AttemptId,
    Initialize-K8AttemptDirectory, Invoke-K8CloneToyotamahime, and
    Set-K8CurrentAttempt). See that module for the canonical, documented
    implementation; this script's copies are intentionally minimal and
    exist only because they must run before the module is available.

    v2 change from k8-bootstrap-v1: this script now records the current
    attempt as $env:K8_ATTEMPT_DIR (a process environment variable, not a
    PowerShell scope variable -- it survives this script returning via
    `& $Dest`) and a pointer file under -AttemptRoot, so that no
    downstream tool needs an operator to type or remember an attempt
    path. v1 left $AttemptDir as a script-local variable, which did not
    survive `& $Dest` -- see Kakuriyo attempt k8-repro-20260828-001.

    v3 change from k8-bootstrap-v2: -Ref now defaults to this script's
    own release tag (see below) instead of an empty string. v2 cloned
    whatever the default branch's HEAD happened to be at clone time --
    which meant a commit landing on that branch *after* a commit was
    package-certified, but *before* a VM attempt actually ran, would be
    the commit the VM tested, silently, with no certification of its
    own. Pinning -Ref by default to this script's own tag closes that
    gap: the tag is only ever moved forward as part of certifying and
    re-tagging a new bootstrap release, so "the commit this script's tag
    points at" and "the commit that was certified" are the same act.

    It does not run the reproduction itself. After a successful clone and
    environment capture, it prints where to go next (Study01/README.md)
    and leaves the transcript running so the manual reproduction that
    follows is captured in the same ordered log.

    Provenance and trust model for this file are documented in
    bootstrap/README.md and in Study01/README.md's Sec3.2. In short: this
    file is an ordinary tracked file in the public Toyotamahime
    repository, fetched via a URL pinned to an immutable tag, and
    verified by SHA-256 against the value printed in Study01/README.md
    before it is ever executed.

.PARAMETER AttemptRoot
    Where attempt evidence directories and archives are created.

.PARAMETER RepoUrl
    The Toyotamahime repository to clone. Defaults to the public repo.
    Reproduction input is the public repository only -- do not point this
    at a private fork or a local working copy as a substitute.

.PARAMETER Ref
    Branch/tag/commit to check out after cloning. Defaults to this
    script's own release tag, `k8-bootstrap-v3` -- the same tag pinned
    in Study01/README.md Sec3.2 for fetching this file, and the exact
    commit that was package-certified before that tag was created. Pass
    an explicit value only if you have a specific, disclosed reason to
    test a different commit; doing so means you are no longer testing a
    certified commit; see Study01/README.md Sec3.3.

    NOTE FOR MAINTAINERS: this default must be updated, together with
    Study01/README.md's bootstrap SHA-256/tag and a new immutable tag,
    every time this script's content changes. See
    docs/k8-packaging-certification.md.
#>

[CmdletBinding()]
param(
    [string] $AttemptRoot = 'C:\K8\attempts',

    [string] $RepoUrl = 'https://github.com/schutzz/toyotamahime',

    [string] $Ref = 'k8-bootstrap-v3'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------
# Minimal, self-contained attempt-ID generation (pre-clone).
# Mirrors Study01/tools/K8AttemptCommon.psm1's New-K8AttemptId.
# ----------------------------------------------------------------------

function New-BootstrapAttemptId {
    param([Parameter(Mandatory)] [string] $AttemptRoot)

    $Prefix = "k8-repro-$(Get-Date -Format 'yyyyMMdd')-"

    $Existing = @()
    if (Test-Path $AttemptRoot) {
        $Existing = @(
            Get-ChildItem -Path $AttemptRoot -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "$Prefix*" } |
                ForEach-Object { ($_.BaseName -replace '\.zip$', '') } |
                Where-Object { $_ -match "^$([regex]::Escape($Prefix))(\d{3})$" } |
                ForEach-Object { [int]$Matches[1] }
        )
    }

    $Next = 1
    if ($Existing.Count -gt 0) {
        $Next = [int](($Existing | Measure-Object -Maximum).Maximum) + 1
    }

    $Id = '{0}{1:D3}' -f $Prefix, $Next

    if ((Test-Path (Join-Path $AttemptRoot $Id)) -or (Test-Path (Join-Path $AttemptRoot "$Id.zip"))) {
        throw "Computed attempt ID '$Id' already exists under '$AttemptRoot'. Refusing to reuse or overwrite."
    }

    return $Id
}

# ----------------------------------------------------------------------
# Minimal "current attempt" recording (pre-clone).
# Mirrors Study01/tools/K8AttemptCommon.psm1's Set-K8CurrentAttempt.
# This is the v2 fix: $env: is process-wide, so it survives this
# script returning to the caller via `& $Dest`, unlike a $variable.
# ----------------------------------------------------------------------

function Set-BootstrapCurrentAttempt {
    param([Parameter(Mandatory)] [string] $AttemptDir)

    $env:K8_ATTEMPT_DIR = $AttemptDir

    $AttemptRootPath = Split-Path -Parent $AttemptDir
    $PointerPath = Join-Path $AttemptRootPath 'current-attempt.txt'
    Set-Content -Path $PointerPath -Value $AttemptDir -Encoding utf8 -NoNewline
}

# ----------------------------------------------------------------------
# Minimal finalize, used only if the clone itself fails -- before the
# repo-local harness exists on disk to do this properly.
# ----------------------------------------------------------------------

function Complete-BootstrapFailure {
    param(
        [Parameter(Mandatory)] [string] $AttemptDir,
        [Parameter(Mandatory)] [string] $Reason
    )

    try {
        Set-Content -Path (Join-Path $AttemptDir 'stop-reason.txt') -Value "FAILED (bootstrap phase)`nReason: $Reason" -Encoding utf8
    } catch { Write-Warning "Failed to write stop-reason.txt: $($_.Exception.Message)" }

    try {
        $FinalStatus = [ordered]@{
            outcome           = 'Failed'
            phase             = 'BOOTSTRAP_CLONE'
            reason            = $Reason
            stop_time_utc     = (Get-Date).ToUniversalTime().ToString('o')
            gate_k8           = 'NOT DETERMINED BY THIS TOOL -- Gate K8 is independent review, not self-certified.'
        }
        $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $AttemptDir 'final-status.json'), (($FinalStatus | ConvertTo-Json -Depth 4) + "`n"), $Utf8NoBom)
    } catch { Write-Warning "Failed to write final-status.json: $($_.Exception.Message)" }

    try { Stop-Transcript | Out-Null } catch { }

    try {
        $ArchiveZip = "$AttemptDir.zip"
        if (-not (Test-Path $ArchiveZip)) {
            Compress-Archive -Path (Join-Path $AttemptDir '*') -DestinationPath $ArchiveZip -CompressionLevel Optimal
            $Hash = (Get-FileHash -Path $ArchiveZip -Algorithm SHA256).Hash.ToLowerInvariant()
            $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText("$ArchiveZip.sha256", "$Hash  $(Split-Path -Leaf $ArchiveZip)`n", $Utf8NoBom)
            Write-Host "Failed-attempt archive: $ArchiveZip"
            Write-Host "Archive SHA-256: $Hash"
        }
    } catch { Write-Warning "Failed to archive the failed attempt: $($_.Exception.Message)" }
}

# ----------------------------------------------------------------------
# 1. Attempt ID and directory.
# ----------------------------------------------------------------------

$AttemptId = New-BootstrapAttemptId -AttemptRoot $AttemptRoot
$AttemptDir = Join-Path $AttemptRoot $AttemptId
$ClonedRepoDir = Join-Path $AttemptDir 'toyotamahime'

New-Item -ItemType Directory -Force -Path $AttemptDir | Out-Null
Start-Transcript -Path (Join-Path $AttemptDir 'transcript.txt') -Force | Out-Null

Set-BootstrapCurrentAttempt -AttemptDir $AttemptDir

Write-Host "K8-3 attempt: $AttemptId"
Write-Host "Attempt directory: $AttemptDir"
Write-Host "Source: $RepoUrl$(if ($Ref) { " @ $Ref" })"
Write-Host 'Reproduction input is the public Toyotamahime repository only.'

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$Attempt = [ordered]@{
    attempt_id          = $AttemptId
    start_time_utc      = (Get-Date).ToUniversalTime().ToString('o')
    start_time_local    = (Get-Date).ToString('o')
    source_url          = $RepoUrl
    ref                 = $Ref
    reproduction_input  = 'public Toyotamahime repository only (root README -> Study01/README.md). No Kakuriyo, private history, or author memory is a reproduction input.'
    host_computer       = $env:COMPUTERNAME
}
[System.IO.File]::WriteAllText((Join-Path $AttemptDir 'attempt.json'), (($Attempt | ConvertTo-Json -Depth 4) + "`n"), $Utf8NoBom)

# ----------------------------------------------------------------------
# 2. Clone, with the transcript already running.
# ----------------------------------------------------------------------

try {
    Write-Host ''
    Write-Host '=== K8 STEP: git clone Toyotamahime ===' -ForegroundColor Cyan

    & git clone $RepoUrl $ClonedRepoDir 2>&1 | ForEach-Object { Write-Host $_ }
    $CloneExit = $LASTEXITCODE
    if ($CloneExit -ne 0) {
        throw "git clone failed with exit code $CloneExit"
    }

    if ($Ref) {
        & git -C $ClonedRepoDir checkout $Ref 2>&1 | ForEach-Object { Write-Host $_ }
        $CheckoutExit = $LASTEXITCODE
        if ($CheckoutExit -ne 0) {
            throw "git checkout '$Ref' failed with exit code $CheckoutExit"
        }
    }

    $Head = (& git -C $ClonedRepoDir rev-parse HEAD).Trim()
    $StatusShort = @(& git -C $ClonedRepoDir status --short)

    $Repository = [ordered]@{
        source_url      = $RepoUrl
        requested_ref   = $Ref
        head            = $Head
        status_short    = $StatusShort
        status_clean    = ($StatusShort.Count -eq 0)
        captured_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    }
    [System.IO.File]::WriteAllText((Join-Path $AttemptDir 'repository.json'), (($Repository | ConvertTo-Json -Depth 4) + "`n"), $Utf8NoBom)

    Write-Host "Cloned HEAD: $Head"
    Write-Host "git status --short clean: $($Repository.status_clean)"
}
catch {
    Write-Host "=== CLONE FAILED: $($_.Exception.Message) ===" -ForegroundColor Red
    Complete-BootstrapFailure -AttemptDir $AttemptDir -Reason $_.Exception.Message
    throw
}

# ----------------------------------------------------------------------
# 3. Hand off to the repo-local harness for environment capture. The
#    module now exists because the clone above succeeded.
# ----------------------------------------------------------------------

$ModulePath = Join-Path $ClonedRepoDir 'Study01\tools\K8AttemptCommon.psm1'

if (-not (Test-Path $ModulePath)) {
    $Reason = "Repo-local harness module not found after clone: $ModulePath"
    Write-Host "=== $Reason ===" -ForegroundColor Red
    Complete-BootstrapFailure -AttemptDir $AttemptDir -Reason $Reason
    throw $Reason
}

Import-Module $ModulePath -Force

$Paths = Get-K8AttemptPaths -AttemptRoot $AttemptRoot -AttemptId $AttemptId
Initialize-K8AttemptEnvironment -Paths $Paths | Out-Null

# ----------------------------------------------------------------------
# 4. Hand off to the operator. Transcript keeps running. Canonical cwd
#    from here on is Study01/ (see Study01/README.md Sec2) -- every
#    repo-local tool path below is written relative to that, with no
#    "Study01\" prefix, matching every protocol/ command in this kit.
# ----------------------------------------------------------------------

$Study01Dir = Join-Path $ClonedRepoDir 'Study01'

Write-Host ''
Write-Host '=== Bootstrap complete. Continue manually from here. ===' -ForegroundColor Cyan
Write-Host "Attempt directory : $AttemptDir"
Write-Host "Cloned repository : $ClonedRepoDir"
Write-Host ''
Write-Host 'Next:'
Write-Host "  cd '$Study01Dir'"
Write-Host '  Then open the repository root README.md, then Study01\README.md, and follow it.'
Write-Host '  The transcript above and below this line is one continuous ordered log.'
Write-Host ''
Write-Host 'From Study01\ (the canonical cwd -- do not prefix tool paths with Study01\ again):'
Write-Host "  .\tools\Invoke-K8Step.ps1 -Description '...' -Command { <command> }"
Write-Host "  .\tools\Record-K8KnowledgeLeak.ps1 '...'"
Write-Host "  .\tools\Stop-K8.ps1 '...'                 # closes as Failed"
Write-Host "  .\tools\Stop-K8.ps1 -Success '...'        # closes as Success"
Write-Host ''
Write-Host 'None of these need an -AttemptDir; this attempt is already the current one.'
Write-Host 'Do not remediate a missing dependency or failed step from memory.'
Write-Host 'If the README does not tell you how, record it and close this attempt as Failed.'
