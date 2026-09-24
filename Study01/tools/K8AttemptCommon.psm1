#requires -Version 7.0
<#
K8-3 attempt lifecycle harness -- shared functions.

Scope discipline (read before editing this file):
  - This module manages ATTEMPT LIFECYCLE and EVIDENCE ACQUISITION only.
    It must never decide, score, or interpret a reproduction outcome, and
    it must never modify frozen apparatus, protocol, scorer, or claims.
  - It must never remediate a failed dependency or command. If something
    the README needed is missing, that is recorded (Add-K8KnowledgeLeak /
    Complete-K8Attempt -Outcome Failed), not silently fixed and retried.
  - It never issues, checks, or claims Gate K8. Gate K8 is independent
    review, over evidence this module only helps collect.
  - A failed attempt is retained under its own ID. Nothing here repairs
    or reuses an existing attempt directory.

Operator-facing functions in this module take an explicit -Paths object
(from Get-K8AttemptPaths) -- that keeps the module's own API unambiguous
and easy to unit-test. The convenience of *not* having to know or type
an attempt path lives one layer up, in the thin tools/*.ps1 CLI wrappers,
which call Resolve-K8AttemptDir before calling into this module. See
Resolve-K8AttemptDir below for exactly what an operator does and does
not need to provide.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# G7 v5 evidence-generation/validation primitives (accepted authority --
# see K8G7Evidence.psm1's own header for the full boundary/provenance
# note). Imported here because attempt lifecycle now generates and
# validates that evidence at the points marked below; K8G7Evidence.psm1
# itself has no dependency back on this module.
Import-Module (Join-Path $PSScriptRoot 'K8G7Evidence.psm1') -Force

function Write-K8Json {
    <#
        Writes an object as UTF-8 (no BOM) JSON. Used for every *.json
        evidence file so encoding is consistent across the attempt.
    #>
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)] [string] $Path
    )

    $Json =
        $Object | ConvertTo-Json -Depth 8

    $Utf8NoBom =
        [System.Text.UTF8Encoding]::new($false)

    [System.IO.File]::WriteAllText($Path, $Json + "`n", $Utf8NoBom)
}

function New-K8AttemptId {
    <#
        Generates k8-repro-YYYYMMDD-NNN. Scans $AttemptRoot -- and, if
        given, every -CanonicalInventoryRoot -- for existing attempt
        directories/archives dated today, and returns the next free
        sequence number. Never reuses or overwrites an existing ID: if
        the computed ID collides anywhere in that combined inventory,
        this throws rather than proceeding.

        -CanonicalInventoryRoots exists because $AttemptRoot alone is
        this VM's own local disk, which is exactly what a VM snapshot
        rollback resets -- the failure class that produced
        k8-repro-20260828-001-v4's same-ID violation (plan section 9(3),
        HISTORICAL-SAME-ID-VIOLATION.md). A rollback cannot un-happen; the
        defense is checking against an inventory that a rollback does not
        reset -- e.g. a mounted/synced copy of Kakuriyo's
        evidence/reproduction/ tree, or any other retained-archive
        location outside the rolled-back volume. See
        K8G7Evidence.psm1's Test-K8AttemptIdAvailable for the actual
        collision check both the sequence-number scan and the final
        safety check below share.
    #>
    param(
        [Parameter(Mandatory)] [string] $AttemptRoot,
        [string[]] $CanonicalInventoryRoots = @()
    )

    $Date =
        Get-Date -Format 'yyyyMMdd'

    $Prefix =
        "k8-repro-$Date-"

    $InventoryRoots =
        @($AttemptRoot) + @($CanonicalInventoryRoots)

    $Existing =
        @(
            foreach ($Root in $InventoryRoots) {
                Get-K8CanonicalAttemptIds -Root $Root |
                    Where-Object { $_ -like "$Prefix*" } |
                    Where-Object { $_ -match "^$([regex]::Escape($Prefix))(\d{3})$" } |
                    ForEach-Object { [int]$Matches[1] }
            }
        )

    $Next =
        1

    if ($Existing.Count -gt 0) {
        $Next = [int](($Existing | Measure-Object -Maximum).Maximum) + 1
    }

    $Id =
        '{0}{1:D3}' -f $Prefix, $Next

    # Final safety check against the same combined inventory -- fail-closed
    # on collision, never a silent suffix repair (plan section 9).
    Test-K8AttemptIdAvailable -AttemptId $Id -AttemptRoot $AttemptRoot `
        -CanonicalInventoryRoots $CanonicalInventoryRoots

    return $Id
}

function Get-K8AttemptPaths {
    <#
        Single source of truth for the attempt evidence layout, so every
        tool agrees on where each file lives.
    #>
    param(
        [Parameter(Mandatory)] [string] $AttemptRoot,
        [Parameter(Mandatory)] [string] $AttemptId
    )

    $Dir =
        Join-Path $AttemptRoot $AttemptId

    [pscustomobject]@{
        AttemptRoot         = $AttemptRoot
        AttemptId           = $AttemptId
        AttemptDir          = $Dir
        Transcript          = Join-Path $Dir 'transcript.txt'
        AttemptJson         = Join-Path $Dir 'attempt.json'
        RepositoryJson      = Join-Path $Dir 'repository.json'
        EnvironmentJson     = Join-Path $Dir 'environment.json'
        StepsLog            = Join-Path $Dir 'steps.jsonl'
        StepsRawDir         = Join-Path $Dir 'steps-raw'
        ExpectationsJsonl   = Join-Path $Dir 'expectations.jsonl'
        KnowledgeLeakMd     = Join-Path $Dir 'knowledge-leak-log.md'
        KnowledgeLeakJsonl  = Join-Path $Dir 'knowledge-leak-log.jsonl'
        StopReasonTxt       = Join-Path $Dir 'stop-reason.txt'
        FinalStatusJson     = Join-Path $Dir 'final-status.json'
        ManifestSha256      = Join-Path $Dir 'manifest.sha256'
        ArchiveZip          = Join-Path $AttemptRoot "$AttemptId.zip"
        ArchiveSha256       = Join-Path $AttemptRoot "$AttemptId.zip.sha256"
        ClonedRepoDir       = Join-Path $Dir 'toyotamahime'
    }
}

function Get-K8CurrentAttemptPointerPath {
    <#
        Path to the small pointer file that records "the current attempt"
        across a fresh PowerShell process/session -- $env:K8_ATTEMPT_DIR
        alone only survives within one process.
    #>
    param(
        [Parameter(Mandatory)] [string] $AttemptRoot
    )

    Join-Path $AttemptRoot 'current-attempt.txt'
}

function Set-K8CurrentAttempt {
    <#
        Records which attempt is "current" two ways, so no tool ever
        needs an operator to type or remember an attempt path:

        1. $env:K8_ATTEMPT_DIR -- a process *environment* variable, not a
           PowerShell scope variable. Setting it here, even from inside a
           script invoked as `& $Dest`, is visible to the caller after
           that script returns, because environment variables belong to
           the whole process, not to a PowerShell scope. This is what
           fixes the original defect: Start-Study01.ps1 no longer needs
           to export a $AttemptDir *variable* across a scope boundary --
           it sets an *environment* variable instead, which was never
           scope-bound in the first place.
        2. A one-line pointer file under $AttemptRoot, for the case where
           the operator closes and reopens their terminal (a fresh
           process has no inherited $env: from the old one either, on
           Windows, once the parent process is gone).
    #>
    param(
        [Parameter(Mandatory)] [string] $AttemptDir
    )

    $env:K8_ATTEMPT_DIR =
        $AttemptDir

    $AttemptRoot =
        Split-Path -Parent $AttemptDir

    $PointerPath =
        Get-K8CurrentAttemptPointerPath -AttemptRoot $AttemptRoot

    Set-Content -Path $PointerPath -Value $AttemptDir -Encoding utf8 -NoNewline
}

function Resolve-K8AttemptDir {
    <#
        Resolves "the current attempt directory" without requiring an
        operator to have typed, copied, or remembered it. Priority:

        1. -Explicit, if given and non-empty -- an advanced/debug escape
           hatch. Normal README-documented usage never needs this.
        2. $env:K8_ATTEMPT_DIR, if set and it still exists -- the normal
           case within the PowerShell session Start-Study01.ps1 was run
           in.
        3. The current-attempt pointer file under -AttemptRootHint -- the
           normal case in a fresh session/process.

        Throws with an actionable message if none of the above resolves,
        rather than silently guessing at a path.
    #>
    param(
        [string] $Explicit = '',
        [string] $AttemptRootHint = 'C:\K8\attempts'
    )

    if ($Explicit) {
        if (-not (Test-Path $Explicit)) {
            throw "Explicit -AttemptDir does not exist: $Explicit"
        }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }

    if ($env:K8_ATTEMPT_DIR -and (Test-Path $env:K8_ATTEMPT_DIR)) {
        return (Resolve-Path -LiteralPath $env:K8_ATTEMPT_DIR).Path
    }

    $PointerPath =
        Get-K8CurrentAttemptPointerPath -AttemptRoot $AttemptRootHint

    if (Test-Path $PointerPath) {
        $Pointed =
            (Get-Content -Path $PointerPath -Raw).Trim()

        if ($Pointed -and (Test-Path $Pointed)) {
            return (Resolve-Path -LiteralPath $Pointed).Path
        }
    }

    throw (
        'Could not resolve the current K8-3 attempt directory. Neither ' +
        '$env:K8_ATTEMPT_DIR nor the current-attempt pointer file under ' +
        "'$AttemptRootHint' point at an existing directory. If you " +
        'know the path, pass it explicitly with -AttemptDir. Otherwise, ' +
        'this session likely never ran Start-Study01.ps1, the attempt ' +
        'was already closed (Stop-K8.ps1 clears the pointer on close), ' +
        'or the pointed-at attempt was moved or deleted.'
    )
}

function Assert-K8AttemptOpen {
    <#
        Closed-attempt immutability guard. A "closed" attempt is one
        whose final-status.json already exists -- i.e. Complete-K8Attempt
        has already run for it. Every operation that mutates attempt
        evidence (a new step, a new knowledge-leak entry, or a second
        close) calls this first and refuses to proceed if the attempt is
        closed, regardless of how its path was obtained (auto-resolved
        or an explicit -AttemptDir override). This is what stops a
        stray or automated call from silently drifting an already-
        archived attempt's directory out of sync with its own manifest
        and ZIP.
    #>
    param(
        [Parameter(Mandatory)] $Paths,
        [Parameter(Mandatory)] [string] $Operation
    )

    if (Test-Path $Paths.FinalStatusJson) {
        throw (
            "Attempt '$($Paths.AttemptId)' is already closed " +
            "(final-status.json exists) -- refusing to $Operation. " +
            'A closed attempt is immutable. If you need a new attempt, ' +
            'start one with Start-Study01.ps1; it gets its own ID.'
        )
    }
}

function Clear-K8CurrentAttempt {
    <#
        Called by Complete-K8Attempt right after a successful close, so
        that nothing -- $env:K8_ATTEMPT_DIR in this process, or the
        pointer file for a fresh one -- keeps resolving to a now-closed
        attempt as "the current one". Only clears the pointer file if it
        still points at *this* attempt, so closing attempt A never
        clobbers a pointer that something else has since pointed at
        attempt B.
    #>
    param(
        [Parameter(Mandatory)] [string] $AttemptDir
    )

    if ($env:K8_ATTEMPT_DIR -and
        (Resolve-Path -LiteralPath $env:K8_ATTEMPT_DIR -ErrorAction SilentlyContinue).Path -eq
        (Resolve-Path -LiteralPath $AttemptDir -ErrorAction SilentlyContinue).Path) {
        $env:K8_ATTEMPT_DIR = ''
    }

    $AttemptRoot =
        Split-Path -Parent $AttemptDir

    $PointerPath =
        Get-K8CurrentAttemptPointerPath -AttemptRoot $AttemptRoot

    if (Test-Path $PointerPath) {
        $Pointed =
            (Get-Content -Path $PointerPath -Raw).Trim()

        if ((Resolve-Path -LiteralPath $Pointed -ErrorAction SilentlyContinue).Path -eq
            (Resolve-Path -LiteralPath $AttemptDir -ErrorAction SilentlyContinue).Path) {
            Remove-Item -Path $PointerPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Initialize-K8AttemptDirectory {
    <#
        Creates the attempt directory, starts its transcript, and marks
        it as the current attempt (Set-K8CurrentAttempt) so nothing
        downstream needs the operator to supply its path. Does not clone
        anything. Refuses to run twice against the same ID, matching the
        no-overwrite rule in New-K8AttemptId.
    #>
    param(
        [Parameter(Mandatory)] [string] $AttemptRoot,
        [Parameter(Mandatory)] [string] $AttemptId,
        [Parameter(Mandatory)] [string] $RepoUrl,
        [string] $Ref = ''
    )

    $Paths =
        Get-K8AttemptPaths -AttemptRoot $AttemptRoot -AttemptId $AttemptId

    if (Test-Path $Paths.AttemptDir) {
        throw "Attempt directory already exists: $($Paths.AttemptDir)"
    }

    New-Item -ItemType Directory -Force -Path $Paths.AttemptDir |
        Out-Null

    Start-Transcript -Path $Paths.Transcript -Force |
        Out-Null

    Set-K8CurrentAttempt -AttemptDir $Paths.AttemptDir

    Write-Host "K8-3 attempt: $AttemptId"
    Write-Host "Attempt directory: $($Paths.AttemptDir)"
    Write-Host "Source: $RepoUrl$(if ($Ref) { " @ $Ref" })"

    $Attempt =
        [ordered]@{
            attempt_id      = $AttemptId
            start_time_utc  = (Get-Date).ToUniversalTime().ToString('o')
            start_time_local = (Get-Date).ToString('o')
            source_url      = $RepoUrl
            ref             = $Ref
            reproduction_input = 'public Toyotamahime repository only (root README -> Study01/README.md). No Kakuriyo, private history, or author memory is a reproduction input.'
            host_computer   = $env:COMPUTERNAME
        }

    Write-K8Json -Object $Attempt -Path $Paths.AttemptJson

    return $Paths
}

function Initialize-K8ExpectationManifest {
    <#
        SECTION A.1a.2: builds expectations.jsonl from a pre-authored step
        plan and pins its SHA-256 into attempt.json.expectation_manifest_sha256
        -- before any step executes.

        The accepted authority's own words are "written once, at
        attempt-open time, alongside start_time_utc". In this harness,
        attempt.json is actually written twice for a formal attempt: once
        pre-clone, by bootstrap/Start-Study01.ps1's minimal duplicate (the
        Study01/tools/ module this function lives in does not exist on
        disk yet at that point -- see that script's own header), and this
        call folds the expectation-manifest field in as an *additive*
        second write, immediately after the clone and before the operator
        runs the README's first documented command. That is still
        strictly before any step executes, which is the property this
        binding exists to prove; it is not the same single write the
        accepted text pictures, and that gap between "attempt.json first
        exists" and "this field is pinned" is deliberately disclosed here
        rather than silently treated as identical.

        -StepPlanPath is a JSON file: an array of objects with
        `description`, `command`, `output_class`, `stdout_expectation`,
        `stderr_expectation` -- one per step this attempt plans to run, in
        order. An illegal output_class/channel combination for any step
        throws (SECTION A.1a.1b, schema-reject before execution) and
        leaves attempt.json untouched.
    #>
    param(
        [Parameter(Mandatory)] $Paths,
        [Parameter(Mandatory)] [string] $StepPlanPath
    )

    Assert-K8AttemptOpen -Paths $Paths -Operation 'bind an expectation manifest'

    if (-not (Test-Path $Paths.AttemptJson)) {
        throw "attempt.json does not exist yet at $($Paths.AttemptJson) -- call this after Initialize-K8AttemptDirectory (or the bootstrap-phase equivalent)."
    }

    if (Test-Path $Paths.ExpectationsJsonl) {
        throw "expectations.jsonl already exists at $($Paths.ExpectationsJsonl) -- refusing to overwrite a pre-execution-bound manifest."
    }

    $StepPlan =
        Get-Content -Path $StepPlanPath -Raw | ConvertFrom-Json

    $Expectations =
        for ($i = 0; $i -lt $StepPlan.Count; $i++) {
            $Step = $StepPlan[$i]
            New-K8StepExpectation -AttemptId $Paths.AttemptId -StepIndex $i `
                -Command $Step.command -OutputClass $Step.output_class `
                -StdoutExpectation $Step.stdout_expectation `
                -StderrExpectation $Step.stderr_expectation
        }

    $ManifestSha256 =
        Write-K8ExpectationsManifest -Path $Paths.ExpectationsJsonl -Expectations @($Expectations)

    $Attempt =
        Get-Content -Path $Paths.AttemptJson -Raw | ConvertFrom-Json -AsHashtable

    $Attempt['expectation_manifest_sha256'] = $ManifestSha256

    Write-K8Json -Object $Attempt -Path $Paths.AttemptJson

    Write-Host "expectations.jsonl written: $($Expectations.Count) step(s) planned."
    Write-Host "expectation_manifest_sha256: $ManifestSha256"

    return $ManifestSha256
}

function Get-K8BootstrapDefaultRef {
    <#
        Extracts bootstrap/Start-Study01.ps1's own default -Ref value by
        reading its source text -- the single source of truth for which
        release tag the bootstrap self-pins to by default. Used by:
        Test-Study01Packaging.ps1 (to tag its certification fixture the
        same way a default, un-overridden bootstrap invocation expects)
        and Test-K8ReleaseBinding.ps1 (to confirm this default actually
        agrees with the pushed tag and the README pin after a release).
        One implementation, so the two can never read it differently.
    #>
    param(
        [Parameter(Mandatory)] [string] $BootstrapPath
    )

    $Source = Get-Content -Path $BootstrapPath -Raw

    if ($Source -notmatch "\[string\]\s*\`$Ref\s*=\s*'([^']*)'") {
        throw "Could not find a `$Ref default in $BootstrapPath"
    }

    return $Matches[1]
}

function Invoke-K8CloneToyotamahime {
    <#
        Clones the public Toyotamahime repository into the attempt
        directory and records its exact HEAD and working-tree status.
        This is deliberately git-only (no repo-local tooling exists yet
        at this point in the lifecycle).
    #>
    param(
        [Parameter(Mandatory)] $Paths,
        [Parameter(Mandatory)] [string] $RepoUrl,
        [string] $Ref = ''
    )

    Write-Host ''
    Write-Host '=== K8 STEP: git clone Toyotamahime ===' -ForegroundColor Cyan

    $CloneArgs =
        @('clone', $RepoUrl, $Paths.ClonedRepoDir)

    & git @CloneArgs 2>&1 |
        ForEach-Object { Write-Host $_ }

    $CloneExit =
        $LASTEXITCODE

    if ($CloneExit -ne 0) {
        throw "git clone failed with exit code $CloneExit"
    }

    if ($Ref) {
        & git -C $Paths.ClonedRepoDir checkout $Ref 2>&1 |
            ForEach-Object { Write-Host $_ }

        $CheckoutExit =
            $LASTEXITCODE

        if ($CheckoutExit -ne 0) {
            throw "git checkout '$Ref' failed with exit code $CheckoutExit"
        }
    }

    $Head =
        (& git -C $Paths.ClonedRepoDir rev-parse HEAD).Trim()

    $StatusShort =
        @(& git -C $Paths.ClonedRepoDir status --short)

    $Repository =
        [ordered]@{
            source_url        = $RepoUrl
            requested_ref     = $Ref
            head              = $Head
            status_short      = $StatusShort
            status_clean      = ($StatusShort.Count -eq 0)
            captured_at_utc   = (Get-Date).ToUniversalTime().ToString('o')
        }

    Write-K8Json -Object $Repository -Path $Paths.RepositoryJson

    Write-Host "Cloned HEAD: $Head"
    Write-Host "git status --short clean: $($Repository.status_clean)"

    return $Repository
}

function Get-K8ToolVersion {
    <#
        Runs a version-probe command and returns its trimmed output, or
        an explicit "unavailable: <reason>" string. Never throws -- a
        missing optional tool must not abort environment capture.

        Do not use this for wsl.exe -- its redirected output requires
        explicit UTF-16LE decoding on this platform. Use Get-K8WslField.
    #>
    param(
        [Parameter(Mandatory)] [scriptblock] $Probe
    )

    try {
        $global:LASTEXITCODE =
            0

        $Output =
            @(& $Probe 2>&1)

        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            return "unavailable: exit $LASTEXITCODE : $($Output -join ' ')"
        }

        return ($Output -join "`n").Trim()
    }
    catch {
        return "unavailable: $($_.Exception.Message)"
    }
}

function Invoke-Utf16LEProcessCapture {
    <#
        Runs a native command and decodes its redirected stdout/stderr as
        UTF-16LE, returning an ordinary .NET string.

        Some Windows-native console binaries -- wsl.exe, confirmed on
        this platform -- write UTF-16LE to a redirected/piped output
        handle even though they print correctly to a real console.
        Capturing that through PowerShell's ordinary native-command
        pipeline (`& cmd args`) produces mojibake with embedded NUL
        characters, exactly as Kakuriyo's K8-2 evidence documented (see
        evidence/reproduction/k8-environment/README.md, "WSL redirection
        encoding", and the Kakuriyo bootstrap's Invoke-WslUtf16Capture,
        which this mirrors). Setting the child process's
        Standard*Encoding to UTF-16LE before starting it makes .NET
        decode the stream correctly at the source, rather than after the
        fact.

        Never throws on a non-zero exit code or a capture failure --
        returns an "unavailable: ..." string instead, matching
        Get-K8ToolVersion, since this is used for optional environment
        identification, not a gating step.
    #>
    param(
        [Parameter(Mandatory)] [string] $FileName,
        [Parameter(Mandatory)] [string] $Arguments
    )

    try {
        $Psi =
            [System.Diagnostics.ProcessStartInfo]::new()

        $Psi.FileName               = $FileName
        $Psi.Arguments              = $Arguments
        $Psi.RedirectStandardOutput = $true
        $Psi.RedirectStandardError  = $true
        $Psi.StandardOutputEncoding = [System.Text.Encoding]::Unicode
        $Psi.StandardErrorEncoding  = [System.Text.Encoding]::Unicode
        $Psi.UseShellExecute        = $false
        $Psi.CreateNoWindow         = $true

        $Proc =
            [System.Diagnostics.Process]::new()

        $Proc.StartInfo = $Psi

        [void]$Proc.Start()

        $StdOut = $Proc.StandardOutput.ReadToEnd()
        $StdErr = $Proc.StandardError.ReadToEnd()

        $Proc.WaitForExit()

        $ExitCode =
            $Proc.ExitCode

        $Text =
            ($StdOut + $StdErr).Trim()

        if ($Text.Contains([char]0)) {
            # Should never happen once decoded correctly. Surfaced
            # explicitly rather than silently written into JSON with an
            # embedded NUL.
            throw 'decoded text still contains a NUL character'
        }

        if ($ExitCode -ne 0) {
            return "unavailable: exit $ExitCode : $Text"
        }

        return $Text
    }
    catch {
        return "unavailable: $($_.Exception.Message)"
    }
}

function Get-K8WslField {
    <#
        wsl.exe, decoded correctly. See Invoke-Utf16LEProcessCapture.
    #>
    param(
        [Parameter(Mandatory)] [string] $Arguments
    )

    Invoke-Utf16LEProcessCapture -FileName 'wsl.exe' -Arguments $Arguments
}

function Initialize-K8AttemptEnvironment {
    <#
        Captures the minimal K8-3 attempt-identity environment record.
        Deliberately smaller than the K8-2 frozen clean-environment
        inventory (evidence/reproduction/k8-environment/ in Kakuriyo) --
        this is attempt-identity and troubleshooting context, not a
        second copy of that record.
    #>
    param(
        [Parameter(Mandatory)] $Paths
    )

    Write-Host ''
    Write-Host '=== K8 STEP: environment capture ===' -ForegroundColor Cyan

    $Environment =
        [ordered]@{
            captured_at_utc   = (Get-Date).ToUniversalTime().ToString('o')
            powershell        = $PSVersionTable.PSVersion.ToString()
            os                = Get-K8ToolVersion { [System.Environment]::OSVersion.VersionString }
            windows_build     = Get-K8ToolVersion { (Get-CimInstance Win32_OperatingSystem).Version }
            python            = Get-K8ToolVersion { python --version }
            pip               = Get-K8ToolVersion { python -m pip --version }
            pytest            = Get-K8ToolVersion { python -m pytest --version }
            git               = Get-K8ToolVersion { git --version }
            docker            = Get-K8ToolVersion { docker --version }
            docker_compose    = Get-K8ToolVersion { docker compose version }
            wsl_version       = Get-K8WslField -Arguments '--version'
            wsl_status        = Get-K8WslField -Arguments '--status'
        }

    Write-K8Json -Object $Environment -Path $Paths.EnvironmentJson

    Write-Host 'environment.json written.'

    return $Environment
}

function Invoke-K8Step {
    <#
        Runs one reproduction command with structured, exit-code-aware
        capture, so a transcript reviewer never has to guess whether a
        step passed. Records every step (pass or fail) to steps.jsonl,
        now including a 0-based step_index, its canonical command_identity
        (SECTION A.1a.1a), and -- always -- a separately-retained,
        per-channel raw capture under steps-raw/ (SECTION A.2's
        "steps-raw/NNNN.log" evidence, split per channel here because
        SECTION A's expectation model is itself per-channel). stdout and
        stderr are told apart from one `2>&1`-merged pipeline by
        PowerShell's own convention of wrapping stderr content in
        ErrorRecord objects when merged this way -- confirmed for both
        native executables and PowerShell-native Write-Error content.

        If expectations.jsonl has a pre-execution-bound record for this
        step_index (Initialize-K8ExpectationManifest), this additionally
        records the command_identity binding result and each channel's
        SECTION A.3 verdict -- as retained data, never as a throw. A
        fail-closed verdict here means the attempt cannot later be
        certified "complete transcript" (SECTION B); it does not itself
        abort execution, matching this module's own scope discipline
        (evidence recording, not gate enforcement -- see the file header).

        This does NOT retry, does NOT remediate, and by default treats
        any exit code other than 0 as a failure and throws. Pass
        -ExpectedExitCode for a step the protocol itself expects to be
        non-zero (for example the Range C validator) so that existing
        protocol semantics are not broken by this wrapper.
    #>
    param(
        [Parameter(Mandatory)] $Paths,
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [scriptblock] $Command,
        [int[]] $ExpectedExitCode = @(0),
        [switch] $ContinueOnFailure
    )

    Assert-K8AttemptOpen -Paths $Paths -Operation 'record a new step'

    $StepIndex =
        if (Test-Path $Paths.StepsLog) { @(Get-Content -Path $Paths.StepsLog).Count } else { 0 }

    $Start =
        Get-Date

    Write-Host ''
    Write-Host "=== K8 STEP: $Description ===" -ForegroundColor Cyan
    Write-Host "Command: $Command"

    $global:LASTEXITCODE =
        0

    $StdOutLines = [System.Collections.Generic.List[string]]::new()
    $StdErrLines = [System.Collections.Generic.List[string]]::new()

    & $Command 2>&1 |
        ForEach-Object {
            $Line = $_.ToString()
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $StdErrLines.Add($Line)
            }
            else {
                $StdOutLines.Add($Line)
            }
            Write-Host $Line
        }

    $ExitCode =
        $LASTEXITCODE

    $Passed =
        $ExpectedExitCode -contains $ExitCode

    if (-not (Test-Path $Paths.StepsRawDir)) {
        New-Item -ItemType Directory -Force -Path $Paths.StepsRawDir | Out-Null
    }

    $StdOutRawPath = Join-Path $Paths.StepsRawDir ('{0:D4}.stdout.log' -f $StepIndex)
    $StdErrRawPath = Join-Path $Paths.StepsRawDir ('{0:D4}.stderr.log' -f $StepIndex)

    $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    # Written unconditionally, even when empty -- a 0-byte capture is
    # itself the retained fact "this channel produced nothing" (SECTION
    # A.4's zero-byte-capture case), never a missing file.
    $StdOutContent = if ($StdOutLines.Count -gt 0) { ($StdOutLines -join "`n") + "`n" } else { '' }
    $StdErrContent = if ($StdErrLines.Count -gt 0) { ($StdErrLines -join "`n") + "`n" } else { '' }
    [System.IO.File]::WriteAllText($StdOutRawPath, $StdOutContent, $Utf8NoBom)
    [System.IO.File]::WriteAllText($StdErrRawPath, $StdErrContent, $Utf8NoBom)

    $CommandText =
        $Command.ToString().Trim()

    $CommandIdentity =
        Get-K8CommandIdentity -Command $CommandText

    $Record =
        [ordered]@{
            timestamp         = $Start.ToUniversalTime().ToString('o')
            step_index        = $StepIndex
            description       = $Description
            command           = $CommandText
            command_identity  = $CommandIdentity
            exit_code         = $ExitCode
            expected          = $ExpectedExitCode
            passed            = $Passed
        }

    $Expectation =
        Get-K8ExpectationForStep -ExpectationsPath $Paths.ExpectationsJsonl -StepIndex $StepIndex

    if ($null -ne $Expectation) {
        $Record['expectation_command_identity_bound'] = ($Expectation.command_identity -eq $CommandIdentity)

        $StdOutBytes = [System.IO.File]::ReadAllBytes($StdOutRawPath)
        $StdErrBytes = [System.IO.File]::ReadAllBytes($StdErrRawPath)

        $Record['stdout_verdict'] = Get-K8ChannelVerdict -Expectation $Expectation.stdout_expectation `
            -CapturePresent $true -CaptureBytes $StdOutBytes -StepChronologyProven $true -HasExpectationRecord $true
        $Record['stderr_verdict'] = Get-K8ChannelVerdict -Expectation $Expectation.stderr_expectation `
            -CapturePresent $true -CaptureBytes $StdErrBytes -StepChronologyProven $true -HasExpectationRecord $true
    }

    ($Record | ConvertTo-Json -Compress) |
        Add-Content -Path $Paths.StepsLog -Encoding utf8

    if ($Passed) {
        Write-Host "=== STEP OK (exit $ExitCode) ===" -ForegroundColor Green
    }
    else {
        Write-Host (
            "=== STEP FAILED (exit $ExitCode, expected " +
            "$($ExpectedExitCode -join ',')) ==="
        ) -ForegroundColor Red
        Write-Host (
            'Do not work around this from memory. Close this attempt: ' +
            "Stop-K8.ps1 `"<why>`""
        ) -ForegroundColor Yellow

        if (-not $ContinueOnFailure) {
            throw "K8 step failed: $Description (exit $ExitCode)"
        }
    }

    return $Record
}

function Get-K8LastStep {
    <#
        The last recorded steps.jsonl entry, or $null if none exists yet.
        Used by Stop-K8.ps1 to auto-populate failure context so an
        operator closing a failed attempt does not have to retype the
        command or exit code the harness already recorded.
    #>
    param(
        [Parameter(Mandatory)] $Paths
    )

    if (-not (Test-Path $Paths.StepsLog)) {
        return $null
    }

    $LastLine =
        Get-Content -Path $Paths.StepsLog -Tail 1

    if (-not $LastLine) {
        return $null
    }

    return ($LastLine | ConvertFrom-Json)
}

function Add-K8KnowledgeLeak {
    <#
        Records one knowledge-leak-log entry (plan Sec6.2): an action
        taken, or needed, that the README did not license. Appends to
        both a human-readable log and a machine-parseable one. Never
        overwrites a previous entry.
    #>
    param(
        [Parameter(Mandatory)] $Paths,
        [Parameter(Mandatory)] [string] $Reason,
        [string] $ActionTaken = '',
        [switch] $LicensedByReadme,
        [switch] $PriorKnowledgeUsed
    )

    Assert-K8AttemptOpen -Paths $Paths -Operation 'record a knowledge-leak entry'

    $Timestamp =
        (Get-Date).ToUniversalTime().ToString('o')

    $Entry =
        [ordered]@{
            timestamp             = $Timestamp
            reason                = $Reason
            action_taken          = $ActionTaken
            licensed_by_readme    = [bool]$LicensedByReadme
            prior_knowledge_used  = [bool]$PriorKnowledgeUsed
        }

    ($Entry | ConvertTo-Json -Compress) |
        Add-Content -Path $Paths.KnowledgeLeakJsonl -Encoding utf8

    $MdBlock = @"

## $Timestamp

**Reason:** $Reason
**Action taken:** $(if ($ActionTaken) { $ActionTaken } else { '(none recorded)' })
**Licensed by README:** $([bool]$LicensedByReadme)
**Prior/operator knowledge used:** $([bool]$PriorKnowledgeUsed)
"@

    if (-not (Test-Path $Paths.KnowledgeLeakMd)) {
        "# Knowledge-leak log -- $($Paths.AttemptId)`n" |
            Set-Content -Path $Paths.KnowledgeLeakMd -Encoding utf8
    }

    Add-Content -Path $Paths.KnowledgeLeakMd -Value $MdBlock -Encoding utf8

    Write-Host "Knowledge-leak entry recorded: $Reason"

    return $Entry
}

function Complete-K8Attempt {
    <#
        Runs on both success and failure. Always attempts every step
        below even if an earlier one throws, so a secondary failure
        during finalization cannot erase evidence that was already
        collected. Does not judge Gate K8 -- it only closes the record.
    #>
    param(
        [Parameter(Mandatory)] $Paths,
        [Parameter(Mandatory)] [ValidateSet('Success', 'Failed')] [string] $Outcome,
        [string] $Reason = '',
        [string] $FailingCommand = '',
        [Nullable[int]] $FailingExitCode = $null
    )

    if (Test-Path $Paths.FinalStatusJson) {
        throw (
            "Attempt '$($Paths.AttemptId)' is already closed " +
            '(final-status.json exists) -- refusing a second close. ' +
            'A closed attempt is immutable; a retry is a new attempt ' +
            'with a new ID from Start-Study01.ps1.'
        )
    }

    Write-Host ''
    Write-Host "=== K8 STEP: finalize attempt ($Outcome) ===" -ForegroundColor Cyan

    # 1. Stop reason (best-effort first, in case everything after this fails).
    try {
        $StopReasonText =
            if ($Outcome -eq 'Success') {
                "SUCCESS`n$Reason"
            }
            else {
                (
                    "FAILED`n" +
                    "Reason: $Reason`n" +
                    "Failing command: $FailingCommand`n" +
                    "Failing exit code: $FailingExitCode"
                )
            }

        Set-Content -Path $Paths.StopReasonTxt -Value $StopReasonText -Encoding utf8
    }
    catch {
        Write-Warning "Failed to write stop-reason.txt: $($_.Exception.Message)"
    }

    # 2. Final repository state, if the clone exists.
    $FinalHead        = $null
    $FinalStatusShort = $null

    try {
        if (Test-Path $Paths.ClonedRepoDir) {
            $FinalHead =
                (& git -C $Paths.ClonedRepoDir rev-parse HEAD).Trim()

            $FinalStatusShort =
                @(& git -C $Paths.ClonedRepoDir status --short)
        }
    }
    catch {
        Write-Warning "Failed to capture final repository state: $($_.Exception.Message)"
    }

    # 3. final-status.json, including SECTION D.1's canonical knowledge_leak
    #    object -- always generated, never lazy-create-only, so a zero-leak
    #    attempt retains positive contemporaneous evidence of that zero
    #    (this is the gap k8-repro-20260922-001's historical record exposed:
    #    absence of a standalone log is not evidence of zero). Also verifies
    #    the SECTION A.1a.2 expectation-manifest binding, if one was made.
    #    Neither of these throws -- a fail-closed/insufficient verdict here
    #    is retained as data for an independent reviewer to certify against
    #    later, not a crash of the close sequence that would destroy
    #    evidence already collected (this function's own stated contract).
    try {
        $GeneratedAtUtc =
            (Get-Date).ToUniversalTime().ToString('o')

        $ExpectationBinding = $null
        if (Test-Path $Paths.AttemptJson) {
            $AttemptRecord = Get-Content -Path $Paths.AttemptJson -Raw | ConvertFrom-Json
            $PinnedSha256 =
                if ($AttemptRecord.PSObject.Properties.Name -contains 'expectation_manifest_sha256') {
                    $AttemptRecord.expectation_manifest_sha256
                } else { $null }

            if ($null -ne $PinnedSha256) {
                $ExpectationBinding =
                    Test-K8ExpectationManifestBinding -ExpectationsPath $Paths.ExpectationsJsonl `
                        -PinnedSha256 $PinnedSha256
            }
        }

        # ConvertFrom-K8JsonLine, not the ConvertFrom-Json cmdlet: the
        # cmdlet silently upgrades an ISO-8601-shaped JSON string (this
        # entry's own `timestamp` field) to a .NET [DateTime], which is
        # not the string value SECTION D.1a.1 requires re-serializing.
        $JsonlEntries = @()
        if (Test-Path $Paths.KnowledgeLeakJsonl) {
            $JsonlEntries = @(
                Get-Content -Path $Paths.KnowledgeLeakJsonl |
                    Where-Object { $_.Trim() } |
                    ForEach-Object { ConvertFrom-K8JsonLine -Line $_ }
            )
        }

        $MdEntries =
            Get-K8KnowledgeLeakMdEntries -Path $Paths.KnowledgeLeakMd

        $KnowledgeLeak =
            New-K8KnowledgeLeakZeroState -Entries $JsonlEntries -GeneratedAtUtc $GeneratedAtUtc -Finalized $true

        $KnowledgeLeakConsistency =
            Test-K8KnowledgeLeakCrossRepresentation -Canonical $KnowledgeLeak -MdEntries $MdEntries -JsonlEntries $JsonlEntries

        $FinalStatus =
            [ordered]@{
                attempt_id            = $Paths.AttemptId
                outcome               = $Outcome
                reason                = $Reason
                failing_command       = $FailingCommand
                failing_exit_code     = $FailingExitCode
                stop_time_utc         = $GeneratedAtUtc
                final_head            = $FinalHead
                final_status_short    = $FinalStatusShort
                final_status_clean    = if ($null -ne $FinalStatusShort) { $FinalStatusShort.Count -eq 0 } else { $null }
                gate_k8               = 'NOT DETERMINED BY THIS TOOL -- Gate K8 is independent review, not self-certified.'
                knowledge_leak                    = $KnowledgeLeak
                knowledge_leak_consistency        = $KnowledgeLeakConsistency
                expectation_manifest_present      = if ($null -ne $ExpectationBinding) { $ExpectationBinding.Present } else { $false }
                expectation_manifest_bound        = if ($null -ne $ExpectationBinding) { $ExpectationBinding.Bound } else { $null }
            }

        Write-K8Json -Object $FinalStatus -Path $Paths.FinalStatusJson
    }
    catch {
        Write-Warning "Failed to write final-status.json: $($_.Exception.Message)"
    }

    # 4. Stop transcript (after this, no more Write-Host output is captured
    #    by it, so do it after the console-visible steps above).
    try {
        Stop-Transcript | Out-Null
    }
    catch {
        Write-Warning "Failed to stop transcript (may not have been running): $($_.Exception.Message)"
    }

    # 5. Manifest: sha256 of every file now in the attempt directory,
    #    computed before archiving.
    try {
        $Files =
            Get-ChildItem -Path $Paths.AttemptDir -Recurse -File |
                Where-Object { $_.FullName -ne $Paths.ManifestSha256 }

        $ManifestLines =
            foreach ($File in $Files) {
                $Hash =
                    (Get-FileHash -Path $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()

                $RelativePath =
                    $File.FullName.Substring($Paths.AttemptDir.Length + 1) -replace '\\', '/'

                "$Hash  $RelativePath"
            }

        [System.IO.File]::WriteAllText(
            $Paths.ManifestSha256,
            (($ManifestLines -join "`n") + "`n"),
            [System.Text.UTF8Encoding]::new($false)
        )
    }
    catch {
        Write-Warning "Failed to write manifest.sha256: $($_.Exception.Message)"
    }

    # 6. Archive the attempt directory, then hash the archive itself.
    try {
        if (Test-Path $Paths.ArchiveZip) {
            throw "Archive already exists, refusing to overwrite: $($Paths.ArchiveZip)"
        }

        Compress-Archive -Path (Join-Path $Paths.AttemptDir '*') -DestinationPath $Paths.ArchiveZip -CompressionLevel Optimal

        $ArchiveHash =
            (Get-FileHash -Path $Paths.ArchiveZip -Algorithm SHA256).Hash.ToLowerInvariant()

        $ArchiveName =
            Split-Path -Leaf $Paths.ArchiveZip

        [System.IO.File]::WriteAllText(
            $Paths.ArchiveSha256,
            "$ArchiveHash  $ArchiveName`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        Write-Host ''
        Write-Host "Attempt closed: $Outcome" -ForegroundColor $(if ($Outcome -eq 'Success') { 'Green' } else { 'Red' })
        Write-Host "Archive: $($Paths.ArchiveZip)"
        Write-Host "Archive SHA-256: $ArchiveHash"
    }
    catch {
        Write-Warning "Failed to create archive/hash: $($_.Exception.Message)"
        Write-Warning "Evidence directory is still intact and unarchived at: $($Paths.AttemptDir)"
    }

    # 7. Clear "current attempt" state -- $env:K8_ATTEMPT_DIR in this
    #    process and the pointer file, if either still points here --
    #    so nothing downstream auto-resolves back into a closed attempt.
    #    Best-effort: a failure here does not un-close the attempt.
    try {
        Clear-K8CurrentAttempt -AttemptDir $Paths.AttemptDir
    }
    catch {
        Write-Warning "Failed to clear current-attempt state: $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function @(
    'Write-K8Json',
    'New-K8AttemptId',
    'Get-K8AttemptPaths',
    'Get-K8CurrentAttemptPointerPath',
    'Set-K8CurrentAttempt',
    'Clear-K8CurrentAttempt',
    'Resolve-K8AttemptDir',
    'Assert-K8AttemptOpen',
    'Get-K8BootstrapDefaultRef',
    'Initialize-K8AttemptDirectory',
    'Initialize-K8ExpectationManifest',
    'Invoke-K8CloneToyotamahime',
    'Get-K8ToolVersion',
    'Invoke-Utf16LEProcessCapture',
    'Get-K8WslField',
    'Initialize-K8AttemptEnvironment',
    'Invoke-K8Step',
    'Get-K8LastStep',
    'Add-K8KnowledgeLeak',
    'Complete-K8Attempt'
)
