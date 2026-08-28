#requires -Version 7.0
<#
.SYNOPSIS
    K8-3 pre-VM package certification. PASS/FAIL gate for whether this
    Toyotamahime commit's packaging is fit to take into a clean VM.

.DESCRIPTION
    See docs/k8-packaging-certification.md for the architecture. In short,
    three layers, none of which may be skipped by a normal run:

      Layer A -- Unit: individual K8AttemptCommon.psm1 functions, called
      in-process.

      Layer B -- Integration: the real bootstrap/Start-Study01.ps1 and
      Study01/tools/*.ps1 scripts, invoked as real child `pwsh` processes
      against a temporary local git fixture repository built from this
      working tree. Process/scope/cwd boundaries are never mocked --
      this is exactly where the original $AttemptDir defect lived.

      Layer C -- Runbook: fenced code blocks extracted verbatim from
      Study01/README.md (via K8ReadmeRunbook.psm1), for blocks marked
      `mode=exec`, executed literally inside the same kind of real child
      process, in the README's own documented cwd. This is what keeps
      the README itself under test, not a hand-copied paraphrase of it.

    What gets mocked: GitHub network (a local git fixture stands in for
    it) and, by not executing them, Docker runtime, Amenonuboco remote,
    and range runtime. pip/PyPI network is NOT mocked -- Layer C's
    apparatus-check blocks genuinely `pip install pytest` and run the
    real 69-test suite; a machine with no route to PyPI correctly fails
    Layer C, the same way a clean VM without one would. Everything else
    (git, PowerShell process/scope boundaries, cwd, environment-variable
    handoff, CLI parameter parsing, transcript open/close, archive/hash)
    is the real thing.

    Does not remediate anything it finds broken, and never will --
    fixture/test setup here is not the same thing as production-attempt
    remediation, which stays fail-closed.

.PARAMETER RepoRoot
    The Toyotamahime working tree to certify. Defaults to the repo this
    script lives in (two levels up from Study01/tools/).

.PARAMETER SkipUnit
.PARAMETER SkipIntegration
.PARAMETER SkipRunbook
    Advanced/debug: skip one layer. A normal certification run before a
    clean-VM attempt should not use these.

.PARAMETER ResultPath
    Where to write the machine-readable package-certification.json.
    Defaults to a file under $env:TEMP -- this is scratch runtime
    evidence about the certification run, not repository content, and
    is not committed.

.EXAMPLE
    cd Study01
    .\tools\Test-Study01Packaging.ps1
#>

[CmdletBinding()]
param(
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot | Split-Path -Parent),
    [switch] $SkipUnit,
    [switch] $SkipIntegration,
    [switch] $SkipRunbook,
    [switch] $AllowDirty,
    [string] $ResultPath = (Join-Path $env:TEMP "package-certification-$(Get-Date -Format yyyyMMddHHmmssfff).json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$Study01Path = Join-Path $RepoRoot 'Study01'
$ToolsPath = Join-Path $Study01Path 'tools'
$ReadmePath = Join-Path $Study01Path 'README.md'
$BootstrapPath = Join-Path $RepoRoot 'bootstrap\Start-Study01.ps1'

Import-Module (Join-Path $ToolsPath 'K8AttemptCommon.psm1') -Force
Import-Module (Join-Path $ToolsPath 'K8ReadmeRunbook.psm1') -Force

# ======================================================================
# Commit identity and dirty-tree gating.
#
# "PACKAGE CERTIFICATION: PASS (commit X)" is a claim about commit X
# specifically. It must never be printed for a working tree that has
# uncommitted changes on top of X -- that would certify bytes that were
# never actually committed as X. A dirty tree can still be checked (for
# fast iteration while developing a harness change), but its result is
# labeled DEVELOPMENT CHECK and is explicitly not eligible to gate a
# clean-VM attempt, and -AllowDirty must be passed to acknowledge that
# on purpose.
# ======================================================================

$CommitSha =
    try { (& git -C $RepoRoot rev-parse HEAD 2>$null).Trim() } catch { $null }

$IsGitRepo = [bool]$CommitSha

$PorcelainStatus =
    # The outer @() matters: `$x = if (...) { @(...) } else { @() }` still
    # collapses to $null when the chosen branch's array is empty --
    # PowerShell unwraps a zero-element pipeline output at the if/else
    # statement boundary regardless of how the branch itself was wrapped.
    # Wrapping the whole if/else expression is what actually survives.
    @(if ($IsGitRepo) { & git -C $RepoRoot status --porcelain 2>$null })

$IsDirty = ($PorcelainStatus.Count -gt 0) -or (-not $IsGitRepo)

if ($IsDirty -and -not $AllowDirty) {
    Write-Host 'K8-3 package certification' -ForegroundColor Cyan
    Write-Host "Repository : $RepoRoot"
    Write-Host ''
    Write-Host 'REFUSING TO RUN: the working tree has uncommitted changes (or is not a git repository).' -ForegroundColor Red
    Write-Host 'A certification run against a dirty tree cannot say PASS/FAIL "for commit X" honestly,' -ForegroundColor Red
    Write-Host 'because commit X on disk is not what would actually be cloned into a clean VM.' -ForegroundColor Red
    Write-Host ''
    Write-Host 'Commit your changes first, then re-run this script -- that is the certification-eligible path.'
    Write-Host 'To run anyway for fast local iteration on a harness change in progress (NOT eligible for the'
    Write-Host 'clean-VM gate), pass -AllowDirty explicitly.'
    exit 2
}

if (-not $CommitSha) { $CommitSha = '(uncommitted working tree -- not eligible for the VM gate)' }

$GateEligible = $IsGitRepo -and -not $IsDirty

Write-Host "K8-3 package certification"
Write-Host "Repository : $RepoRoot"
Write-Host "Commit     : $CommitSha"
if (-not $GateEligible) {
    Write-Host 'Mode       : DEVELOPMENT CHECK -- NOT ELIGIBLE FOR VM GATE (dirty working tree, -AllowDirty)' -ForegroundColor Yellow
}
Write-Host ''

# ======================================================================
# Findings collection
# ======================================================================

$Findings = [System.Collections.Generic.List[object]]::new()

function Add-Finding {
    param(
        [Parameter(Mandatory)] [string] $Layer,
        [Parameter(Mandatory)] [string] $Check,
        [Parameter(Mandatory)] [ValidateSet('PASS', 'FAIL', 'SKIP')] [string] $Status,
        [string] $Detail = ''
    )

    $Findings.Add([pscustomobject]@{
        layer  = $Layer
        check  = $Check
        status = $Status
        detail = $Detail
    })

    switch ($Status) {
        'PASS' { Write-Host "PASS: [$Layer] $Check" -ForegroundColor Green }
        'SKIP' { Write-Host "SKIP: [$Layer] $Check -- $Detail" -ForegroundColor Yellow }
        default {
            Write-Host "FAIL: [$Layer] $Check" -ForegroundColor Red
            if ($Detail) {
                Write-Host "  reason: $Detail" -ForegroundColor Red
            }
        }
    }
}

function Invoke-Check {
    <#
        Runs $Body, records PASS if it returns/completes without
        throwing (and does not itself call Add-Finding), FAIL with the
        exception message if it throws. Keeps each check's failure
        isolated from the rest of the suite.

        A body that wants to report "not applicable on this machine"
        rather than a failure -- the WSL check on a machine with no
        wsl.exe, for example -- throws a message starting with
        "SKIPPED:"; that is recorded as SKIP, which does not count
        toward the overall FAIL total, and is never silently treated as
        a pass either.
    #>
    param(
        [Parameter(Mandatory)] [string] $Layer,
        [Parameter(Mandatory)] [string] $Check,
        [Parameter(Mandatory)] [scriptblock] $Body
    )

    try {
        & $Body
        Add-Finding -Layer $Layer -Check $Check -Status 'PASS'
    }
    catch {
        if ($_.Exception.Message -match '^SKIPPED:\s*(.*)$') {
            Add-Finding -Layer $Layer -Check $Check -Status 'SKIP' -Detail $Matches[1]
        }
        else {
            Add-Finding -Layer $Layer -Check $Check -Status 'FAIL' -Detail $_.Exception.Message
            if ($env:K8_CERT_DEBUG) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
        }
    }
}

function Assert {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

# ======================================================================
# Layer A -- Unit
# ======================================================================

if (-not $SkipUnit) {
    Write-Host ''
    Write-Host '--- Layer A: Unit ---' -ForegroundColor Cyan

    $UnitRoot = Join-Path $env:TEMP "k8-cert-unit-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $UnitRoot | Out-Null

    try {
        Invoke-Check -Layer 'Unit' -Check 'attempt ID generation (first, dated, sequence 001)' -Body {
            $Id = New-K8AttemptId -AttemptRoot (Join-Path $UnitRoot 'a1')
            Assert ($Id -match '^k8-repro-\d{8}-001$') "unexpected id: $Id"
        }

        Invoke-Check -Layer 'Unit' -Check 'attempt ID generation increments and never collides' -Body {
            $Root = Join-Path $UnitRoot 'a2'
            $Id1 = New-K8AttemptId -AttemptRoot $Root
            New-Item -ItemType Directory -Force -Path (Join-Path $Root $Id1) | Out-Null
            $Id2 = New-K8AttemptId -AttemptRoot $Root
            Assert ($Id1 -ne $Id2) 'second id equals first id'
            Assert ($Id2 -match '^k8-repro-\d{8}-002$') "unexpected second id: $Id2"
        }

        Invoke-Check -Layer 'Unit' -Check 'path resolution: Get-K8AttemptPaths is internally consistent' -Body {
            $Paths = Get-K8AttemptPaths -AttemptRoot (Join-Path $UnitRoot 'a3') -AttemptId 'k8-repro-19700101-001'
            Assert ($Paths.AttemptDir -eq (Join-Path $Paths.AttemptRoot $Paths.AttemptId)) 'AttemptDir mismatch'
            Assert ($Paths.ArchiveZip -eq (Join-Path $Paths.AttemptRoot "$($Paths.AttemptId).zip")) 'ArchiveZip mismatch'
        }

        Invoke-Check -Layer 'Unit' -Check 'Resolve-K8AttemptDir: explicit override wins and must exist' -Body {
            $Dir = Join-Path $UnitRoot 'a4-explicit'
            New-Item -ItemType Directory -Force -Path $Dir | Out-Null
            $Resolved = Resolve-K8AttemptDir -Explicit $Dir
            Assert ((Resolve-Path $Resolved).Path -eq (Resolve-Path $Dir).Path) 'explicit path not honored'

            $Threw = $false
            try { Resolve-K8AttemptDir -Explicit (Join-Path $UnitRoot 'a4-does-not-exist') | Out-Null }
            catch { $Threw = $true }
            Assert $Threw 'explicit nonexistent path should throw'
        }

        Invoke-Check -Layer 'Unit' -Check 'Resolve-K8AttemptDir: env var resolution (operator never provides AttemptDir)' -Body {
            $OldEnv = $env:K8_ATTEMPT_DIR
            try {
                $Dir = Join-Path $UnitRoot 'a5-env'
                New-Item -ItemType Directory -Force -Path $Dir | Out-Null
                $env:K8_ATTEMPT_DIR = $Dir
                $Resolved = Resolve-K8AttemptDir -AttemptRootHint (Join-Path $UnitRoot 'unused')
                Assert ((Resolve-Path $Resolved).Path -eq (Resolve-Path $Dir).Path) 'env-based resolution failed'
            }
            finally { $env:K8_ATTEMPT_DIR = $OldEnv }
        }

        Invoke-Check -Layer 'Unit' -Check 'Resolve-K8AttemptDir: pointer-file fallback (fresh-session case)' -Body {
            $OldEnv = $env:K8_ATTEMPT_DIR
            try {
                $env:K8_ATTEMPT_DIR = ''
                $Root = Join-Path $UnitRoot 'a6-pointer'
                $Dir = Join-Path $Root 'k8-repro-19700101-001'
                New-Item -ItemType Directory -Force -Path $Dir | Out-Null
                Set-K8CurrentAttempt -AttemptDir $Dir
                $env:K8_ATTEMPT_DIR = ''   # simulate a fresh process: env gone, pointer file remains
                $Resolved = Resolve-K8AttemptDir -AttemptRootHint $Root
                Assert ((Resolve-Path $Resolved).Path -eq (Resolve-Path $Dir).Path) 'pointer-file resolution failed'
            }
            finally { $env:K8_ATTEMPT_DIR = $OldEnv }
        }

        Invoke-Check -Layer 'Unit' -Check 'Resolve-K8AttemptDir: throws with an actionable message when nothing resolves' -Body {
            $OldEnv = $env:K8_ATTEMPT_DIR
            try {
                $env:K8_ATTEMPT_DIR = ''
                $Threw = $false
                try { Resolve-K8AttemptDir -AttemptRootHint (Join-Path $UnitRoot 'a7-nothing-here') | Out-Null }
                catch { $Threw = $true; Assert ($_.Exception.Message -match 'Start-Study01') 'error message not actionable' }
                Assert $Threw 'should have thrown'
            }
            finally { $env:K8_ATTEMPT_DIR = $OldEnv }
        }

        Invoke-Check -Layer 'Unit' -Check 'Invoke-K8Step: passing step recorded, exit 0' -Body {
            $Paths = Initialize-K8AttemptDirectory -AttemptRoot (Join-Path $UnitRoot 'a8') -AttemptId 'k8-repro-19700101-001' -RepoUrl 'unit-test'
            try {
                $Rec = Invoke-K8Step -Paths $Paths -Description 'ok' -Command { & cmd.exe /c "exit 0" }
                Assert ($Rec.passed -eq $true) 'expected passed'
                Assert ($Rec.exit_code -eq 0) 'expected exit 0'
            } finally { try { Stop-Transcript | Out-Null } catch {} }
        }

        Invoke-Check -Layer 'Unit' -Check 'Invoke-K8Step: expected-nonzero step (Range C style) passes' -Body {
            $Paths = Initialize-K8AttemptDirectory -AttemptRoot (Join-Path $UnitRoot 'a9') -AttemptId 'k8-repro-19700101-001' -RepoUrl 'unit-test'
            try {
                $Rec = Invoke-K8Step -Paths $Paths -Description 'expected fail' -Command { & cmd.exe /c "exit 1" } -ExpectedExitCode @(1)
                Assert ($Rec.passed -eq $true) 'expected-nonzero step should pass'
            } finally { try { Stop-Transcript | Out-Null } catch {} }
        }

        Invoke-Check -Layer 'Unit' -Check 'Invoke-K8Step: unexpected failure is fail-closed (throws)' -Body {
            $Paths = Initialize-K8AttemptDirectory -AttemptRoot (Join-Path $UnitRoot 'a10') -AttemptId 'k8-repro-19700101-001' -RepoUrl 'unit-test'
            try {
                $Threw = $false
                try { Invoke-K8Step -Paths $Paths -Description 'unexpected' -Command { & cmd.exe /c "exit 5" } | Out-Null }
                catch { $Threw = $true }
                Assert $Threw 'unexpected nonzero exit should throw by default'
            } finally { try { Stop-Transcript | Out-Null } catch {} }
        }

        Invoke-Check -Layer 'Unit' -Check 'Get-K8LastStep: null before any step, correct after' -Body {
            $Paths = Initialize-K8AttemptDirectory -AttemptRoot (Join-Path $UnitRoot 'a11') -AttemptId 'k8-repro-19700101-001' -RepoUrl 'unit-test'
            try {
                Assert ($null -eq (Get-K8LastStep -Paths $Paths)) 'expected null before any step'
                Invoke-K8Step -Paths $Paths -Description 'x' -Command { & cmd.exe /c "exit 3" } -ContinueOnFailure | Out-Null
                $Last = Get-K8LastStep -Paths $Paths
                Assert ($Last.exit_code -eq 3) 'last step exit code mismatch'
                Assert ($Last.passed -eq $false) 'last step should be recorded as failed'
            } finally { try { Stop-Transcript | Out-Null } catch {} }
        }

        Invoke-Check -Layer 'Unit' -Check 'Add-K8KnowledgeLeak: one-line recording, no AttemptDir retyping needed at this layer' -Body {
            $Paths = Initialize-K8AttemptDirectory -AttemptRoot (Join-Path $UnitRoot 'a12') -AttemptId 'k8-repro-19700101-001' -RepoUrl 'unit-test'
            try {
                Add-K8KnowledgeLeak -Paths $Paths -Reason 'unit test reason' | Out-Null
                Assert (Test-Path $Paths.KnowledgeLeakMd) 'md not written'
                Assert (Test-Path $Paths.KnowledgeLeakJsonl) 'jsonl not written'
                Assert ((Get-Content $Paths.KnowledgeLeakMd -Raw) -match 'unit test reason') 'reason not found in md'
            } finally { try { Stop-Transcript | Out-Null } catch {} }
        }

        Invoke-Check -Layer 'Unit' -Check 'Complete-K8Attempt: success finalize produces archive + matching SHA-256' -Body {
            $Paths = Initialize-K8AttemptDirectory -AttemptRoot (Join-Path $UnitRoot 'a13') -AttemptId 'k8-repro-19700101-001' -RepoUrl 'unit-test'
            Complete-K8Attempt -Paths $Paths -Outcome 'Success' -Reason 'unit test'
            Assert (Test-Path $Paths.ArchiveZip) 'archive missing'
            $Recorded = (Get-Content $Paths.ArchiveSha256 -Raw).Split(' ')[0]
            $Actual = (Get-FileHash -Path $Paths.ArchiveZip -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert ($Recorded -eq $Actual) 'archive sha256 mismatch'
        }

        Invoke-Check -Layer 'Unit' -Check 'Complete-K8Attempt: archive-collision does not erase stop-reason/final-status' -Body {
            $Paths = Initialize-K8AttemptDirectory -AttemptRoot (Join-Path $UnitRoot 'a14') -AttemptId 'k8-repro-19700101-001' -RepoUrl 'unit-test'
            Complete-K8Attempt -Paths $Paths -Outcome 'Failed' -Reason 'first close'
            Remove-Item $Paths.StopReasonTxt, $Paths.FinalStatusJson -Force
            Complete-K8Attempt -Paths $Paths -Outcome 'Failed' -Reason 'second close, archive already exists'
            Assert (Test-Path $Paths.StopReasonTxt) 'stop-reason.txt lost on secondary failure'
            Assert (Test-Path $Paths.FinalStatusJson) 'final-status.json lost on secondary failure'
        }

        Invoke-Check -Layer 'Unit' -Check 'paths with spaces are handled end to end' -Body {
            $SpacedRoot = Join-Path $UnitRoot 'a15 with spaces'
            $Paths = Initialize-K8AttemptDirectory -AttemptRoot $SpacedRoot -AttemptId 'k8-repro-19700101-001' -RepoUrl 'unit-test'
            Invoke-K8Step -Paths $Paths -Description 'ok' -Command { & cmd.exe /c "exit 0" } | Out-Null
            Complete-K8Attempt -Paths $Paths -Outcome 'Success' -Reason 'spaces test'
            Assert (Test-Path $Paths.ArchiveZip) 'archive missing under spaced path'
        }

        Invoke-Check -Layer 'Unit' -Check 'WSL field capture: real wsl.exe, human-readable, no NUL/mojibake' -Body {
            $HaveWsl = [bool](Get-Command wsl.exe -ErrorAction SilentlyContinue)
            if (-not $HaveWsl) {
                throw 'SKIPPED: wsl.exe not present on this machine -- cannot exercise the real fix here.'
            }
            $Version = Get-K8WslField -Arguments '--version'
            Assert (-not $Version.Contains([char]0)) 'wsl_version contains a NUL character'
            Assert ($Version -notmatch 'unavailable:') "wsl --version reported unavailable: $Version"
            Assert ($Version.Length -gt 0) 'wsl_version is empty'
        }

        Invoke-Check -Layer 'Unit' -Check 'WSL field capture: unknown binary fails closed to "unavailable", never throws' -Body {
            $Result = Invoke-Utf16LEProcessCapture -FileName 'this-binary-does-not-exist-k8-cert.exe' -Arguments '--version'
            Assert ($Result -match '^unavailable:') "expected graceful unavailable, got: $Result"
        }

        Invoke-Check -Layer 'Unit' -Check 'Initialize-K8AttemptEnvironment: environment.json has no NUL in WSL fields' -Body {
            $Paths = Initialize-K8AttemptDirectory -AttemptRoot (Join-Path $UnitRoot 'a16') -AttemptId 'k8-repro-19700101-001' -RepoUrl 'unit-test'
            $Env = Initialize-K8AttemptEnvironment -Paths $Paths
            Assert (-not $Env.wsl_version.Contains([char]0)) 'wsl_version has embedded NUL'
            Assert (-not $Env.wsl_status.Contains([char]0)) 'wsl_status has embedded NUL'
            $RawJson = Get-Content $Paths.EnvironmentJson -Raw
            Assert (-not $RawJson.Contains([char]0)) 'environment.json file contains a raw NUL byte'
        }
    }
    finally {
        try { Stop-Transcript | Out-Null } catch {}
        Remove-Item -Recurse -Force $UnitRoot -ErrorAction SilentlyContinue
    }
}
else {
    Write-Host 'Layer A (Unit) skipped by -SkipUnit.' -ForegroundColor Yellow
}

# ======================================================================
# Fixture repository, shared by Layer B and Layer C
# ======================================================================

function New-K8PackagingFixtureRepo {
    <#
        Builds a real, local git repository from the CURRENT working tree
        (including uncommitted changes when -AllowDirty is in play --
        certification must reflect what is about to be committed, not
        necessarily the last commit), so Layer B/C's `git clone` is a
        real git operation against a real repo, per the "do not mock
        git" rule, without depending on network access to GitHub or on
        this change already being pushed.

        Also tags that single commit with bootstrap's own default -Ref
        value (see Get-K8BootstrapDefaultRef), so a default,
        un-overridden bootstrap invocation against this fixture resolves
        a tag exactly the way it will against the real, released repo --
        this is what makes the "-Ref pin" checks below meaningful rather
        than accidentally passing because the fixture has no tags to get
        wrong.
    #>
    param(
        [Parameter(Mandatory)] [string] $SourceRoot,
        [Parameter(Mandatory)] [string] $DefaultRefTag
    )

    $FixtureRoot = Join-Path $env:TEMP "k8-cert-fixture-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $FixtureRoot | Out-Null

    # robocopy exit codes 0-7 are all "succeeded" (they encode what was
    # copied/skipped, not failure); only >=8 is a real error.
    & robocopy $SourceRoot $FixtureRoot /MIR /XD '.git' /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed building the certification fixture (exit $LASTEXITCODE)"
    }

    & git -C $FixtureRoot init -q 2>&1 | Out-Null
    & git -C $FixtureRoot config user.email 'k8-cert@example.invalid' 2>&1 | Out-Null
    & git -C $FixtureRoot config user.name 'K8 Certification' 2>&1 | Out-Null
    & git -C $FixtureRoot add -A 2>&1 | Out-Null
    & git -C $FixtureRoot commit -q -m 'k8 packaging certification fixture' 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0 -and -not (Test-Path (Join-Path $FixtureRoot '.git'))) {
        throw 'Failed to initialize the certification fixture repository.'
    }

    if ($DefaultRefTag) {
        & git -C $FixtureRoot tag $DefaultRefTag 2>&1 | Out-Null
    }

    return $FixtureRoot
}

$FixtureRepo = $null
$IntegrationAttemptRoot = $null
$FailureAttemptRoot = $null
$SuccessAttemptRoot = $null
$BootstrapDefaultRef = $null

if (-not $SkipIntegration -or -not $SkipRunbook) {
    Invoke-Check -Layer 'Integration' -Check 'bootstrap: default -Ref is a specific, non-empty pin (not a floating branch)' -Body {
        $script:BootstrapDefaultRef = Get-K8BootstrapDefaultRef -BootstrapPath $BootstrapPath
        Assert ([bool]$BootstrapDefaultRef) 'bootstrap default -Ref is empty -- it would clone whatever the default branch HEAD is at clone time, not a certified commit'
    }

    if (-not $BootstrapDefaultRef) {
        throw (
            'Cannot continue Layer B/C: bootstrap has no default -Ref pin, so ' +
            'there is nothing to certify against a fixed commit. Fix BLOCKER 1 first.'
        )
    }

    Write-Host ''
    Write-Host '--- Building local git fixture repository (mocks GitHub network only; git itself is real) ---' -ForegroundColor Cyan
    $FixtureRepo = New-K8PackagingFixtureRepo -SourceRoot $RepoRoot -DefaultRefTag $BootstrapDefaultRef
    Write-Host "Fixture repo: $FixtureRepo (tagged '$BootstrapDefaultRef')"
}

# ======================================================================
# Shared child-process runner
# ======================================================================

function Invoke-K8CertChildProcess {
    <#
        Runs $ScriptText as a REAL, separate `pwsh` child process (not an
        in-process scriptblock) and returns its exit code and captured
        output. This is the real process boundary the $AttemptDir defect
        lived in -- Layer B/C must never substitute an in-process call
        for this.

        -TimeoutSeconds is enforced for real: uses Process.WaitForExit(ms)
        rather than an unbounded `&` invocation, and kills the process
        tree (Stop-Process -Id ... -ErrorAction; taskkill /T as a
        backstop for any grandchildren, e.g. a hung pip/pytest) on
        timeout, returning ExitCode -1 with TimedOut = $true rather than
        hanging the whole certification run.
    #>
    param(
        [Parameter(Mandatory)] [string] $ScriptText,
        [int] $TimeoutSeconds = 300
    )

    $ScriptFile = Join-Path $env:TEMP "k8-cert-child-$([guid]::NewGuid().ToString('N')).ps1"
    $StdOutFile = "$ScriptFile.out.txt"
    $StdErrFile = "$ScriptFile.err.txt"
    Set-Content -Path $ScriptFile -Value $ScriptText -Encoding utf8

    try {
        $Proc = Start-Process -FilePath 'pwsh' `
            -ArgumentList @('-NoProfile', '-File', $ScriptFile) `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $StdOutFile `
            -RedirectStandardError $StdErrFile

        # Redirecting to files (rather than pipes/events) avoids both the
        # classic pipe-buffer deadlock on chatty children and the
        # cross-runspace flakiness of event-based async stream reads --
        # simple, and reliable enough for a certification runner.
        $Finished = $Proc.WaitForExit($TimeoutSeconds * 1000)

        $ReadOutput = {
            $Out = if (Test-Path $StdOutFile) { Get-Content $StdOutFile -Raw -ErrorAction SilentlyContinue } else { '' }
            $Err = if (Test-Path $StdErrFile) { Get-Content $StdErrFile -Raw -ErrorAction SilentlyContinue } else { '' }
            "$Out$Err"
        }

        if (-not $Finished) {
            try { & taskkill /PID $Proc.Id /T /F 2>&1 | Out-Null } catch {}
            try { if (-not $Proc.HasExited) { $Proc.Kill() } } catch {}
            return [pscustomobject]@{
                ExitCode = -1
                TimedOut = $true
                Output   = (& $ReadOutput) + "`n[k8-cert] TIMED OUT after $TimeoutSeconds seconds; process killed."
            }
        }

        return [pscustomobject]@{
            ExitCode = $Proc.ExitCode
            TimedOut = $false
            Output   = & $ReadOutput
        }
    }
    finally {
        Remove-Item -Path $ScriptFile, $StdOutFile, $StdErrFile -Force -ErrorAction SilentlyContinue
    }
}

# ======================================================================
# Layer B -- Integration (real bootstrap process, real git, real fs)
# ======================================================================

if (-not $SkipIntegration) {
    Write-Host ''
    Write-Host '--- Layer B: Integration (real pwsh process, real git, real bootstrap script) ---' -ForegroundColor Cyan

    $IntegrationAttemptRoot = Join-Path $env:TEMP "k8-cert-integration-$([guid]::NewGuid().ToString('N'))"

    Invoke-Check -Layer 'Integration' -Check 'bootstrap: fresh clone + env-var handoff survives `& $Dest` scope boundary' -Body {
        $ResultPath1 = Join-Path $env:TEMP "k8-cert-b1-$([guid]::NewGuid().ToString('N')).json"
        $Script = @"
`$ErrorActionPreference = 'Stop'
& '$BootstrapPath' -AttemptRoot '$IntegrationAttemptRoot' -RepoUrl '$FixtureRepo' | Out-Null
`$Result = [ordered]@{
    env_attempt_dir = `$env:K8_ATTEMPT_DIR
    env_exists      = [bool](`$env:K8_ATTEMPT_DIR -and (Test-Path `$env:K8_ATTEMPT_DIR))
}
`$Result | ConvertTo-Json | Set-Content -Path '$ResultPath1' -Encoding utf8
"@
        $Run = Invoke-K8CertChildProcess -ScriptText $Script
        Assert ($Run.ExitCode -eq 0) "bootstrap child process failed (exit $($Run.ExitCode)):`n$($Run.Output)"
        Assert (Test-Path $ResultPath1) 'bootstrap result file not written'
        $R = Get-Content $ResultPath1 -Raw | ConvertFrom-Json
        Assert ([bool]$R.env_attempt_dir) '$env:K8_ATTEMPT_DIR was empty after `& $Dest` returned -- the original defect'
        Assert ([bool]$R.env_exists) '$env:K8_ATTEMPT_DIR did not point at an existing directory'
        Remove-Item $ResultPath1 -Force -ErrorAction SilentlyContinue
    }

    Invoke-Check -Layer 'Integration' -Check 'bootstrap: -Ref pin survives the default branch advancing past the certified commit (BLOCKER 1 regression test)' -Body {
        # Simulate exactly the scenario the review flagged: a commit
        # lands on the fixture's default branch AFTER the commit that
        # was tagged/certified, before any VM attempt runs. A
        # default (un-overridden) bootstrap invocation must still check
        # out the TAGGED commit -- not whatever the branch tip has since
        # become.
        $TaggedHead = (& git -C $FixtureRepo rev-parse $BootstrapDefaultRef).Trim()

        $DriftMarker = Join-Path $FixtureRepo 'k8-cert-drift-marker.txt'
        Set-Content -Path $DriftMarker -Value 'commit landed after certification/tagging' -Encoding utf8
        & git -C $FixtureRepo add -A 2>&1 | Out-Null
        & git -C $FixtureRepo commit -q -m 'simulated post-certification commit (tag must not follow this)' 2>&1 | Out-Null
        $AdvancedHead = (& git -C $FixtureRepo rev-parse HEAD).Trim()

        try {
            Assert ($AdvancedHead -ne $TaggedHead) 'test setup error: advancing commit did not change HEAD'

            $DriftRoot = Join-Path $env:TEMP "k8-cert-drift-$([guid]::NewGuid().ToString('N'))"
            $Run = Invoke-K8CertChildProcess -ScriptText "& '$BootstrapPath' -AttemptRoot '$DriftRoot' -RepoUrl '$FixtureRepo' | Out-Null"
            Assert ($Run.ExitCode -eq 0) "bootstrap failed against the drifted fixture:`n$($Run.Output)"

            $Dirs = @(Get-ChildItem -Path $DriftRoot -Directory -ErrorAction SilentlyContinue)
            Assert ($Dirs.Count -eq 1) "expected exactly one attempt directory, got $($Dirs.Count)"
            $Repository = Get-Content (Join-Path $Dirs[0].FullName 'repository.json') -Raw | ConvertFrom-Json

            Assert ($Repository.head -eq $TaggedHead) (
                "pin did NOT hold: cloned HEAD ($($Repository.head)) should equal the tagged/" +
                "certified commit ($TaggedHead), not the drifted branch tip ($AdvancedHead). " +
                'This is exactly the failure mode BLOCKER 1 described.'
            )

            Remove-Item -Recurse -Force $DriftRoot -ErrorAction SilentlyContinue
        }
        finally {
            # Reset the shared fixture back to the tagged commit so later
            # checks in this run see the intended (untampered) fixture.
            & git -C $FixtureRepo reset -q --hard $TaggedHead 2>&1 | Out-Null
            Remove-Item -Path $DriftMarker -Force -ErrorAction SilentlyContinue
        }
    }

    Invoke-Check -Layer 'Integration' -Check 'bootstrap: duplicate invocation allocates a distinct, non-colliding attempt' -Body {
        $Before = @(Get-ChildItem -Path $IntegrationAttemptRoot -Directory -ErrorAction SilentlyContinue).Count
        $Run = Invoke-K8CertChildProcess -ScriptText "& '$BootstrapPath' -AttemptRoot '$IntegrationAttemptRoot' -RepoUrl '$FixtureRepo' | Out-Null"
        Assert ($Run.ExitCode -eq 0) "second bootstrap run failed:`n$($Run.Output)"
        $After = @(Get-ChildItem -Path $IntegrationAttemptRoot -Directory).Count
        Assert ($After -eq $Before + 1) "expected one new attempt directory, before=$Before after=$After"
    }

    Invoke-Check -Layer 'Integration' -Check 'bootstrap: clone failure is retained, archived, and reported non-zero' -Body {
        $BadRoot = Join-Path $env:TEMP "k8-cert-badclone-$([guid]::NewGuid().ToString('N'))"
        $Run = Invoke-K8CertChildProcess -ScriptText "& '$BootstrapPath' -AttemptRoot '$BadRoot' -RepoUrl 'C:\this\path\does\not\exist-k8-cert'"
        Assert ($Run.ExitCode -ne 0) 'bootstrap should exit non-zero on a clone failure'
        $Dirs = @(Get-ChildItem -Path $BadRoot -Directory -ErrorAction SilentlyContinue)
        Assert ($Dirs.Count -eq 1) "expected exactly one retained failed attempt, got $($Dirs.Count)"
        $Dir = $Dirs[0].FullName
        Assert (Test-Path (Join-Path $Dir 'stop-reason.txt')) 'stop-reason.txt missing on clone failure'
        Assert (Test-Path (Join-Path $Dir 'final-status.json')) 'final-status.json missing on clone failure'
        Assert (Test-Path "$Dir.zip") 'archive missing on clone failure'
        Assert (Test-Path "$Dir.zip.sha256") 'archive sha256 missing on clone failure'
        Remove-Item -Recurse -Force $BadRoot -ErrorAction SilentlyContinue
    }

    Invoke-Check -Layer 'Integration' -Check 'real CLI wrapper: Invoke-K8Step.ps1 invoked as an actual script' -Body {
        $Run = Invoke-K8CertChildProcess -ScriptText @"
`$ErrorActionPreference = 'Stop'
& '$BootstrapPath' -AttemptRoot '$IntegrationAttemptRoot' -RepoUrl '$FixtureRepo' | Out-Null
Set-Location (Join-Path `$env:K8_ATTEMPT_DIR 'toyotamahime\Study01')
& '.\tools\Invoke-K8Step.ps1' -Description 'cli wrapper test' -Command { & cmd.exe /c "exit 0" }
"@
        Assert ($Run.ExitCode -eq 0) "real CLI wrapper invocation failed:`n$($Run.Output)"
    }
}
else {
    Write-Host 'Layer B (Integration) skipped by -SkipIntegration.' -ForegroundColor Yellow
}

# ======================================================================
# Layer C -- Runbook: literal README blocks, real process, real cwd
# ======================================================================

if (-not $SkipRunbook) {
    Write-Host ''
    Write-Host '--- Layer C: Executable Runbook (README blocks, literal, real process) ---' -ForegroundColor Cyan

    $Blocks = Get-K8ReadmeBlocks -Path $ReadmePath

    Invoke-Check -Layer 'Runbook' -Check 'every exec/parse block PowerShell-parses cleanly' -Body {
        foreach ($Block in ($Blocks | Where-Object { $_.Mode -in @('exec', 'parse') })) {
            $ParseErrors = $null
            $Tokens = $null
            [System.Management.Automation.Language.Parser]::ParseInput($Block.Code, [ref]$Tokens, [ref]$ParseErrors) | Out-Null
            if ($ParseErrors.Count -gt 0) {
                throw "block '$($Block.Id)' ($($Block.Cwd)): $($ParseErrors[0].Message)"
            }
        }
    }

    Invoke-Check -Layer 'Runbook' -Check 'no double Study01\ prefix in any Study01-cwd block' -Body {
        foreach ($Block in ($Blocks | Where-Object { $_.Cwd -eq 'Study01' })) {
            if ($Block.Code -match '(?i)\.?\\?Study01\\(tools|studies)') {
                throw "block '$($Block.Id)' references a Study01\ prefix while its own declared cwd is already Study01 -- double prefix"
            }
        }
    }

    Invoke-Check -Layer 'Runbook' -Check 'a display-mode block is not standing in for an untested critical command' -Body {
        $Suspicious = $Blocks | Where-Object {
            $_.Mode -eq 'display' -and $_.Code -match '(?m)^(git |python |docker |\.\\tools\\)'
        }
        if ($Suspicious) {
            throw "block(s) marked display look like real commands: $($Suspicious.Id -join ', ')"
        }
    }

    function New-K8RunbookChildScript {
        param(
            [Parameter(Mandatory)] [string] $AttemptRoot,
            [Parameter(Mandatory)] [string[]] $BlockIds,
            [switch] $InjectFailingStep
        )

        $Sb = [System.Text.StringBuilder]::new()
        [void]$Sb.AppendLine("`$ErrorActionPreference = 'Stop'")
        [void]$Sb.AppendLine("& '$BootstrapPath' -AttemptRoot '$AttemptRoot' -RepoUrl '$FixtureRepo' | Out-Null")
        [void]$Sb.AppendLine("if (-not `$env:K8_ATTEMPT_DIR) { throw 'K8_ATTEMPT_DIR not set after bootstrap' }")
        [void]$Sb.AppendLine("`$ClonedRepo = Join-Path `$env:K8_ATTEMPT_DIR 'toyotamahime'")
        [void]$Sb.AppendLine("`$Study01Dir = Join-Path `$ClonedRepo 'Study01'")
        # Captured now, not read again later: Stop-K8.ps1 clears
        # $env:K8_ATTEMPT_DIR on a successful close (by design -- see
        # Clear-K8CurrentAttempt), so anything needed after closing must
        # be saved before that point, not re-read from the environment.
        [void]$Sb.AppendLine("`$CapturedAttemptDir = `$env:K8_ATTEMPT_DIR")

        foreach ($Id in $BlockIds) {
            $Block = Get-K8ReadmeBlockById -Blocks $Blocks -Id $Id
            $CwdVar = if ($Block.Cwd -eq 'Study01') { '$Study01Dir' } else { '$ClonedRepo' }
            [void]$Sb.AppendLine("Set-Location $CwdVar")
            [void]$Sb.AppendLine("# ----- k8-test block: $Id -----")
            [void]$Sb.AppendLine($Block.Code)
        }

        if ($InjectFailingStep) {
            # Not README-sourced by design: the README documents no
            # "make this fail on purpose" example, so there is nothing to
            # extract here. This models an unexpected failure the way a
            # real attempt would hit one -- via the real Invoke-K8Step.ps1
            # CLI wrapper, not an in-process module call.
            [void]$Sb.AppendLine("Set-Location `$Study01Dir")
            [void]$Sb.AppendLine("& '.\tools\Invoke-K8Step.ps1' -Description 'certification-injected failure (not from README)' -Command { & cmd.exe /c `"exit 9`" } -ContinueOnFailure")
        }

        return $Sb.ToString()
    }

    # --- Failure lifecycle pass -----------------------------------------
    $FailureAttemptRoot = Join-Path $env:TEMP "k8-cert-runbook-fail-$([guid]::NewGuid().ToString('N'))"
    $FailureAttemptDirForAssertions = $null

    Invoke-Check -Layer 'Runbook' -Check 'failure lifecycle: bootstrap -> apparatus-check -> injected failure -> Stop-K8 (Failed), literally from README text' -Body {
        $Script = New-K8RunbookChildScript -AttemptRoot $FailureAttemptRoot `
            -BlockIds @('apparatus-check', 'apparatus-check-via-harness') -InjectFailingStep
        $Script += "`nSet-Location `$Study01Dir`n"
        $StopBlock = Get-K8ReadmeBlockById -Blocks $Blocks -Id 'stop-k8-failure-example'
        $Script += "# ----- k8-test block: stop-k8-failure-example -----`n" + $StopBlock.Code + "`n"
        $Script += "`$CapturedAttemptDir | Set-Content -Path (Join-Path '$FailureAttemptRoot' 'winning-attempt.txt') -NoNewline`n"

        $Run = Invoke-K8CertChildProcess -ScriptText $Script -TimeoutSeconds 600
        Assert ($Run.ExitCode -eq 0) "failure-lifecycle runbook script itself errored (exit $($Run.ExitCode)):`n$($Run.Output)"

        $Pointer = Join-Path $FailureAttemptRoot 'winning-attempt.txt'
        Assert (Test-Path $Pointer) 'runbook did not record which attempt it used'
        $script:FailureAttemptDirForAssertions = (Get-Content $Pointer -Raw).Trim()
    }

    if ($FailureAttemptDirForAssertions) {
        Invoke-Check -Layer 'Runbook' -Check 'failure lifecycle: transcript closed, final-status Failed, auto-populated from last step' -Body {
            $Dir = $FailureAttemptDirForAssertions
            Assert (Test-Path (Join-Path $Dir 'transcript.txt')) 'transcript.txt missing'
            $Final = Get-Content (Join-Path $Dir 'final-status.json') -Raw | ConvertFrom-Json
            Assert ($Final.outcome -eq 'Failed') "expected Failed, got $($Final.outcome)"
            Assert ($Final.failing_exit_code -eq 9) "expected auto-populated exit 9, got $($Final.failing_exit_code)"
            Assert ($Final.failing_command -match 'certification-injected failure') 'failing_command not auto-populated from last step'
        }

        Invoke-Check -Layer 'Runbook' -Check 'failure lifecycle: manifest + archive + archive SHA-256 all correct' -Body {
            $Dir = $FailureAttemptDirForAssertions
            $Manifest = Join-Path $Dir 'manifest.sha256'
            Assert (Test-Path $Manifest) 'manifest.sha256 missing'
            $Zip = "$Dir.zip"
            $ZipSha = "$Dir.zip.sha256"
            Assert (Test-Path $Zip) 'archive .zip missing'
            Assert (Test-Path $ZipSha) 'archive .zip.sha256 missing'
            $Recorded = (Get-Content $ZipSha -Raw).Split(' ')[0]
            $Actual = (Get-FileHash -Path $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert ($Recorded -eq $Actual) 'archive SHA-256 does not match archive bytes'
        }

        Invoke-Check -Layer 'Runbook' -Check 'closed-attempt immutability: Record-K8KnowledgeLeak / Invoke-K8Step / Stop-K8 all refuse a closed attempt' -Body {
            $Dir = $FailureAttemptDirForAssertions
            $ManifestBefore = (Get-FileHash -Path (Join-Path $Dir 'manifest.sha256') -Algorithm SHA256).Hash

            $RecordRun = Invoke-K8CertChildProcess -ScriptText @"
`$ErrorActionPreference = 'Stop'
Set-Location (Join-Path '$Dir' 'toyotamahime\Study01')
& '.\tools\Record-K8KnowledgeLeak.ps1' -AttemptDir '$Dir' 'attempted mutation of a closed attempt'
"@
            Assert ($RecordRun.ExitCode -ne 0) 'Record-K8KnowledgeLeak.ps1 on a closed attempt should fail, but exited 0'

            $StepRun = Invoke-K8CertChildProcess -ScriptText @"
`$ErrorActionPreference = 'Stop'
Set-Location (Join-Path '$Dir' 'toyotamahime\Study01')
& '.\tools\Invoke-K8Step.ps1' -AttemptDir '$Dir' -Description 'attempted mutation' -Command { & cmd.exe /c "exit 0" }
"@
            Assert ($StepRun.ExitCode -ne 0) 'Invoke-K8Step.ps1 on a closed attempt should fail, but exited 0'

            $StopAgainRun = Invoke-K8CertChildProcess -ScriptText @"
`$ErrorActionPreference = 'Stop'
Set-Location (Join-Path '$Dir' 'toyotamahime\Study01')
& '.\tools\Stop-K8.ps1' -AttemptDir '$Dir' 'attempted second close'
"@
            Assert ($StopAgainRun.ExitCode -ne 0) 'Stop-K8.ps1 called a second time should fail, but exited 0'

            $ManifestAfter = (Get-FileHash -Path (Join-Path $Dir 'manifest.sha256') -Algorithm SHA256).Hash
            Assert ($ManifestBefore -eq $ManifestAfter) 'manifest.sha256 changed after refused mutation attempts -- the attempt was not actually left untouched'
        }
    }

    # --- Success lifecycle pass -----------------------------------------
    $SuccessAttemptRoot = Join-Path $env:TEMP "k8-cert-runbook-success-$([guid]::NewGuid().ToString('N'))"
    $SuccessAttemptDirForAssertions = $null

    Invoke-Check -Layer 'Runbook' -Check 'success lifecycle: bootstrap -> apparatus-check -> knowledge-leak example -> Stop-K8 -Success, literally from README text' -Body {
        $Script = New-K8RunbookChildScript -AttemptRoot $SuccessAttemptRoot `
            -BlockIds @('apparatus-check', 'apparatus-check-via-harness', 'harness-oneliners')
        $Script += "`nSet-Location `$Study01Dir`n"
        $StopBlock = Get-K8ReadmeBlockById -Blocks $Blocks -Id 'stop-k8-success-example'
        $Script += "# ----- k8-test block: stop-k8-success-example -----`n" + $StopBlock.Code + "`n"
        $Script += "`$CapturedAttemptDir | Set-Content -Path (Join-Path '$SuccessAttemptRoot' 'winning-attempt.txt') -NoNewline`n"

        $Run = Invoke-K8CertChildProcess -ScriptText $Script -TimeoutSeconds 600
        Assert ($Run.ExitCode -eq 0) "success-lifecycle runbook script itself errored (exit $($Run.ExitCode)):`n$($Run.Output)"

        $Pointer = Join-Path $SuccessAttemptRoot 'winning-attempt.txt'
        Assert (Test-Path $Pointer) 'runbook did not record which attempt it used'
        $script:SuccessAttemptDirForAssertions = (Get-Content $Pointer -Raw).Trim()
    }

    if ($SuccessAttemptDirForAssertions) {
        Invoke-Check -Layer 'Runbook' -Check 'success lifecycle: transcript closed, final-status Success, archive + SHA-256 correct' -Body {
            $Dir = $SuccessAttemptDirForAssertions
            Assert (Test-Path (Join-Path $Dir 'transcript.txt')) 'transcript.txt missing'
            $Final = Get-Content (Join-Path $Dir 'final-status.json') -Raw | ConvertFrom-Json
            Assert ($Final.outcome -eq 'Success') "expected Success, got $($Final.outcome)"
            $Zip = "$Dir.zip"
            $ZipSha = "$Dir.zip.sha256"
            Assert (Test-Path $Zip) 'archive .zip missing'
            $Recorded = (Get-Content $ZipSha -Raw).Split(' ')[0]
            $Actual = (Get-FileHash -Path $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert ($Recorded -eq $Actual) 'archive SHA-256 does not match archive bytes'
            Assert (Test-Path (Join-Path $Dir 'knowledge-leak-log.md')) 'knowledge-leak-log.md missing from the README-literal one-liner'
        }

        Invoke-Check -Layer 'Runbook' -Check 'closed-attempt immutability (success case): Stop-K8 refuses a second close' -Body {
            $Dir = $SuccessAttemptDirForAssertions
            $ManifestBefore = (Get-FileHash -Path (Join-Path $Dir 'manifest.sha256') -Algorithm SHA256).Hash

            $StopAgainRun = Invoke-K8CertChildProcess -ScriptText @"
`$ErrorActionPreference = 'Stop'
Set-Location (Join-Path '$Dir' 'toyotamahime\Study01')
& '.\tools\Stop-K8.ps1' -AttemptDir '$Dir' -Success 'attempted second close'
"@
            Assert ($StopAgainRun.ExitCode -ne 0) 'Stop-K8.ps1 -Success called a second time should fail, but exited 0'

            $ManifestAfter = (Get-FileHash -Path (Join-Path $Dir 'manifest.sha256') -Algorithm SHA256).Hash
            Assert ($ManifestBefore -eq $ManifestAfter) 'manifest.sha256 changed after a refused second close'
        }
    }
}
else {
    Write-Host 'Layer C (Runbook) skipped by -SkipRunbook.' -ForegroundColor Yellow
}

# ======================================================================
# Cleanup fixture / scratch roots (best-effort; certification result
# does not depend on this succeeding)
# ======================================================================

foreach ($Path in @($FixtureRepo, $IntegrationAttemptRoot, $FailureAttemptRoot, $SuccessAttemptRoot)) {
    if ($Path -and (Test-Path $Path)) {
        Remove-Item -Recurse -Force $Path -ErrorAction SilentlyContinue
    }
}

# ======================================================================
# Result
# ======================================================================

$FailCount = @($Findings | Where-Object { $_.status -eq 'FAIL' }).Count
$Overall = if ($FailCount -eq 0) { 'PASS' } else { 'FAIL' }

$Result = [ordered]@{
    commit            = $CommitSha
    gate_eligible     = $GateEligible
    timestamp_utc     = (Get-Date).ToUniversalTime().ToString('o')
    unit_pass         = -not ($Findings | Where-Object { $_.layer -eq 'Unit' -and $_.status -eq 'FAIL' })
    integration_pass  = -not ($Findings | Where-Object { $_.layer -eq 'Integration' -and $_.status -eq 'FAIL' })
    runbook_pass      = -not ($Findings | Where-Object { $_.layer -eq 'Runbook' -and $_.status -eq 'FAIL' })
    findings          = $Findings
    overall           = $Overall
}

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($ResultPath, (($Result | ConvertTo-Json -Depth 6) + "`n"), $Utf8NoBom)

Write-Host ''
Write-Host "Findings: $($Findings.Count) total, $FailCount failed"
Write-Host "Result written to: $ResultPath"
Write-Host ''

$Label = if ($GateEligible) { 'PACKAGE CERTIFICATION' } else { 'DEVELOPMENT CHECK -- NOT ELIGIBLE FOR VM GATE' }

if ($Overall -eq 'PASS') {
    Write-Host "${Label}: PASS (commit $CommitSha)" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "${Label}: FAIL (commit $CommitSha)" -ForegroundColor Red
    foreach ($F in ($Findings | Where-Object { $_.status -eq 'FAIL' })) {
        Write-Host "  FAIL: [$($F.layer)] $($F.check)" -ForegroundColor Red
        if ($F.detail) { Write-Host "    $($F.detail)" -ForegroundColor Red }
    }
    exit 1
}
