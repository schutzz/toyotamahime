#requires -Version 7.0
<#
.SYNOPSIS
    Post-release binding check: confirms a pushed bootstrap release tag,
    bootstrap's own default -Ref, and Study01/README.md's pinned tag all
    name the same commit. Run once, right after pushing a commit and
    creating its tag -- not part of Test-Study01Packaging.ps1, which
    necessarily runs before that tag exists.

.DESCRIPTION
    Exists because pre-push package certification cannot see a tag that
    has not been created yet, and once, in this project's own history,
    that gap let a bootstrap release tag (`k8-bootstrap-v3`) end up
    pointing at a different commit than the one that was actually
    certified clean -- a follow-up commit landed right after tagging and
    was never re-tagged. See docs/k8-packaging-certification.md, "The v3
    incident", for the full account.

    This script checks three things against each other, mechanically,
    rather than trusting a maintainer's memory of what was just done:

      1. the named tag's peeled target on `origin` (fetched fresh --
         not a possibly-stale local tag),
      2. bootstrap/Start-Study01.ps1's own -Ref default, and
      3. the tag named in Study01/README.md's pinned fetch URL,

    all against -ExpectedCommit (or local HEAD, if not given). It also
    checks that README's pinned SHA-256 matches the actual git blob for
    bootstrap/Start-Study01.ps1 at -ExpectedCommit.

    Does not create, move, or delete any tag. Does not modify anything.
    Prints exactly which of the checks disagree and with what, not a
    bare pass/fail count.

.PARAMETER RepoRoot
    The Toyotamahime working tree to check. Defaults to the repo this
    script lives in.

.PARAMETER Tag
    The release tag to verify. Defaults to whatever
    bootstrap/Start-Study01.ps1's own -Ref default currently is -- so
    running this with no arguments checks "does the tag this script
    already claims to use actually exist and point where everything
    else agrees it should."

.PARAMETER ExpectedCommit
    The commit the tag, the bootstrap default, and the README pin must
    all agree on. Defaults to local HEAD (i.e. "the commit you just
    committed and are about to push/tag").

.EXAMPLE
    # Right after: git push origin main; git tag -a k8-bootstrap-v4 ...; git push origin k8-bootstrap-v4
    cd Study01
    .\tools\Test-K8ReleaseBinding.ps1 -Tag k8-bootstrap-v4 -ExpectedCommit (git rev-parse HEAD)
#>

[CmdletBinding()]
param(
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot | Split-Path -Parent),
    [string] $Tag = '',
    [string] $ExpectedCommit = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$ToolsPath = Join-Path $RepoRoot 'Study01\tools'
$ReadmePath = Join-Path $RepoRoot 'Study01\README.md'
$BootstrapPath = Join-Path $RepoRoot 'bootstrap\Start-Study01.ps1'

Import-Module (Join-Path $ToolsPath 'K8AttemptCommon.psm1') -Force

if (-not $ExpectedCommit) {
    $ExpectedCommit = (& git -C $RepoRoot rev-parse HEAD).Trim()
}

if (-not $Tag) {
    $Tag = Get-K8BootstrapDefaultRef -BootstrapPath $BootstrapPath
}

Write-Host 'K8-3 post-release binding check'
Write-Host "Repository      : $RepoRoot"
Write-Host "Tag             : $Tag"
Write-Host "Expected commit : $ExpectedCommit"
Write-Host ''

$Findings = [System.Collections.Generic.List[object]]::new()

function Add-BindingFinding {
    param(
        [Parameter(Mandatory)] [string] $Check,
        [Parameter(Mandatory)] [bool] $Passed,
        [string] $Detail = ''
    )
    $Findings.Add([pscustomobject]@{ check = $Check; passed = $Passed; detail = $Detail })
    if ($Passed) {
        Write-Host "PASS: $Check" -ForegroundColor Green
    }
    else {
        Write-Host "FAIL: $Check" -ForegroundColor Red
        if ($Detail) { Write-Host "  $Detail" -ForegroundColor Red }
    }
}

# 1. Fetch the tag fresh from origin -- not a possibly-stale local tag --
#    and read its peeled (commit) target. An explicit refspec forces the
#    local ref to match origin exactly, rather than trusting whatever a
#    prior `git fetch --tags` happened to leave lying around.
try {
    & git -C $RepoRoot fetch origin "+refs/tags/${Tag}:refs/tags/${Tag}" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "git fetch of tag '$Tag' from origin failed (exit $LASTEXITCODE) -- does it exist on origin?"
    }
    $TagTarget = (& git -C $RepoRoot rev-parse "$Tag^{commit}").Trim()
    Add-BindingFinding -Check "tag '$Tag' exists on origin and was fetched" -Passed $true
}
catch {
    Add-BindingFinding -Check "tag '$Tag' exists on origin and was fetched" -Passed $false -Detail $_.Exception.Message
    $TagTarget = $null
}

if ($TagTarget) {
    Add-BindingFinding -Check "tag '$Tag' (on origin) points at the expected commit" `
        -Passed ($TagTarget -eq $ExpectedCommit) `
        -Detail "tag target = $TagTarget; expected = $ExpectedCommit"
}

# 2. bootstrap's own default -Ref names this same tag.
try {
    $BootstrapDefaultRef = Get-K8BootstrapDefaultRef -BootstrapPath $BootstrapPath
    Add-BindingFinding -Check 'bootstrap/Start-Study01.ps1 -Ref default names this tag' `
        -Passed ($BootstrapDefaultRef -eq $Tag) `
        -Detail "bootstrap default = '$BootstrapDefaultRef'; expected = '$Tag'"
}
catch {
    Add-BindingFinding -Check 'bootstrap/Start-Study01.ps1 -Ref default names this tag' -Passed $false -Detail $_.Exception.Message
}

# 3. Study01/README.md's pinned fetch URL names this same tag.
try {
    $ReadmeSource = Get-Content -Path $ReadmePath -Raw
    if ($ReadmeSource -notmatch 'raw\.githubusercontent\.com/schutzz/toyotamahime/([^/]+)/bootstrap/Start-Study01\.ps1') {
        throw "Could not find the bootstrap fetch URL pin in $ReadmePath"
    }
    $ReadmePinnedTag = $Matches[1]
    Add-BindingFinding -Check 'Study01/README.md pinned fetch URL names this tag' `
        -Passed ($ReadmePinnedTag -eq $Tag) `
        -Detail "README pin = '$ReadmePinnedTag'; expected = '$Tag'"

    if ($ReadmeSource -notmatch "\`$Expected\s*=\s*'([0-9a-fA-F]{64})'") {
        throw "Could not find the pinned bootstrap SHA-256 in $ReadmePath"
    }
    $ReadmePinnedSha256 = $Matches[1].ToLowerInvariant()

    # Hash the exact committed blob bytes, not a PowerShell-string
    # reconstruction of `git show`'s output (encoding/newline round-trips
    # through the pipeline are not guaranteed byte-identical). Resolve
    # the blob object id, then let `git cat-file -p` write it straight to
    # a file via cmd.exe's raw `>` redirection, which does not pass
    # through PowerShell's text pipeline at all.
    $BlobId = (& git -C $RepoRoot rev-parse "${ExpectedCommit}:bootstrap/Start-Study01.ps1").Trim()
    $TempBlobFile = Join-Path $env:TEMP "k8-release-binding-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        & cmd.exe /c "git -C `"$RepoRoot`" cat-file -p $BlobId > `"$TempBlobFile`""
        $ActualSha256 = (Get-FileHash -Path $TempBlobFile -Algorithm SHA256).Hash.ToLowerInvariant()

        Add-BindingFinding -Check 'Study01/README.md pinned SHA-256 matches the commit blob (byte-exact)' `
            -Passed ($ActualSha256 -eq $ReadmePinnedSha256) `
            -Detail "README pin = $ReadmePinnedSha256; actual blob = $ActualSha256"
    }
    finally {
        Remove-Item -Path $TempBlobFile -Force -ErrorAction SilentlyContinue
    }
}
catch {
    Add-BindingFinding -Check 'Study01/README.md pinned fetch URL names this tag' -Passed $false -Detail $_.Exception.Message
}

$FailCount = @($Findings | Where-Object { -not $_.passed }).Count

Write-Host ''
if ($FailCount -eq 0) {
    Write-Host "RELEASE BINDING: PASS (tag '$Tag' == commit $ExpectedCommit)" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "RELEASE BINDING: FAIL ($FailCount of $($Findings.Count) checks failed)" -ForegroundColor Red
    exit 1
}
