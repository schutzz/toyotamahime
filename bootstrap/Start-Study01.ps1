#requires -Version 7.0
<#
.SYNOPSIS
    K8-3 attempt bootstrap: creates the attempt evidence directory, starts
    its transcript, clones the public Toyotamahime repository, records the
    exact clone HEAD, and hands off to the repo-local harness.

.DESCRIPTION
    This script exists solely to solve one ordering problem: a K8-3
    attempt's ordered transcript should include `git clone` itself, but
    the repo-local harness (Study01/tools/K8AttemptCommon.psm1) does not
    exist on disk until after that clone completes. So this script
    duplicates, in minimal form, exactly the pre-clone steps that
    Study01/tools/K8AttemptCommon.psm1 also implements for later,
    repo-local use (New-K8AttemptId, Initialize-K8AttemptDirectory,
    Invoke-K8CloneToyotamahime). See that module for the canonical,
    documented implementation; this script's copies are intentionally
    minimal and exist only because they must run before the module is
    available.

    It does not run the reproduction itself. After a successful clone and
    environment capture, it prints where to go next (Study01/README.md)
    and leaves the transcript running so the manual reproduction that
    follows is captured in the same ordered log.

    Provenance and trust model for this file are documented in
    bootstrap/README.md and in Study01/README.md's "Before you clone"
    section. In short: this file is an ordinary tracked file in the
    public Toyotamahime repository, fetched via a URL pinned to an
    immutable tag, and verified by SHA-256 against the value printed in
    Study01/README.md before it is ever executed.

.PARAMETER AttemptRoot
    Where attempt evidence directories and archives are created.

.PARAMETER RepoUrl
    The Toyotamahime repository to clone. Defaults to the public repo.
    Reproduction input is the public repository only -- do not point this
    at a private fork or a local working copy as a substitute.

.PARAMETER Ref
    Optional branch/tag/commit to check out after cloning. Leave empty to
    reproduce against the default branch as it stands when you run this.
#>

[CmdletBinding()]
param(
    [string] $AttemptRoot = 'C:\K8\attempts',

    [string] $RepoUrl = 'https://github.com/schutzz/toyotamahime',

    [string] $Ref = ''
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
# 4. Hand off to the operator. Transcript keeps running.
# ----------------------------------------------------------------------

Write-Host ''
Write-Host '=== Bootstrap complete. Continue manually from here. ===' -ForegroundColor Cyan
Write-Host "Attempt directory : $AttemptDir"
Write-Host "Cloned repository : $ClonedRepoDir"
Write-Host ''
Write-Host 'Next: open the cloned root README.md, then Study01/README.md, and follow it.'
Write-Host 'The transcript above and below this line is one continuous ordered log.'
Write-Host ''
Write-Host 'Tools available from the cloned repo (run from anywhere, or cd into it first):'
Write-Host "  Import-Module '$ModulePath'"
Write-Host "  Invoke-K8Step -Paths `$Paths -Description '...' -Command { <command> }"
Write-Host "  or: .\Study01\tools\Invoke-K8Step.ps1 -AttemptDir '$AttemptDir' -Description '...' -Command { <command> }"
Write-Host "  .\Study01\tools\Record-K8KnowledgeLeak.ps1 -AttemptDir '$AttemptDir' -Reason '...'"
Write-Host "  .\Study01\tools\Finalize-K8Attempt.ps1 -AttemptDir '$AttemptDir' -Outcome Success|Failed -Reason '...'"
Write-Host ''
Write-Host 'Do not remediate a missing dependency or failed step from memory.'
Write-Host 'If the README does not tell you how, record it and close this attempt as Failed.'
