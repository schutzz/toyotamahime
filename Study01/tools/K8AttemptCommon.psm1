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
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
        Generates k8-repro-YYYYMMDD-NNN. Scans $AttemptRoot for existing
        attempt directories and archives dated today and returns the next
        free sequence number. Never reuses or overwrites an existing ID:
        if the computed ID somehow already exists on disk, this throws
        rather than proceeding.
    #>
    param(
        [Parameter(Mandatory)] [string] $AttemptRoot
    )

    $Date =
        Get-Date -Format 'yyyyMMdd'

    $Prefix =
        "k8-repro-$Date-"

    $Existing =
        @()

    if (Test-Path $AttemptRoot) {
        $Existing =
            @(
                Get-ChildItem -Path $AttemptRoot -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "$Prefix*" } |
                    ForEach-Object {
                        # Strip a trailing .zip / .zip.sha256 so both the
                        # attempt directory and its archive count toward
                        # the same sequence.
                        ($_.BaseName -replace '\.zip$', '')
                    } |
                    Where-Object { $_ -match "^$([regex]::Escape($Prefix))(\d{3})$" } |
                    ForEach-Object { [int]$Matches[1] }
            )
    }

    $Next =
        1

    if ($Existing.Count -gt 0) {
        $Next = [int](($Existing | Measure-Object -Maximum).Maximum) + 1
    }

    $Id =
        '{0}{1:D3}' -f $Prefix, $Next

    $CandidateDir =
        Join-Path $AttemptRoot $Id

    $CandidateZip =
        Join-Path $AttemptRoot "$Id.zip"

    if ((Test-Path $CandidateDir) -or (Test-Path $CandidateZip)) {
        throw (
            "Computed attempt ID '$Id' already exists under " +
            "'$AttemptRoot'. Refusing to reuse or overwrite an existing " +
            'attempt. Investigate before retrying.'
        )
    }

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

function Initialize-K8AttemptDirectory {
    <#
        Creates the attempt directory and starts its transcript. Does not
        clone anything. Idempotent only in the sense that it refuses to
        run twice against the same ID (the directory must not already
        exist), matching the no-overwrite rule in New-K8AttemptId.
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
            wsl_version       = Get-K8ToolVersion { wsl.exe --version }
            wsl_status        = Get-K8ToolVersion { wsl.exe --status }
        }

    Write-K8Json -Object $Environment -Path $Paths.EnvironmentJson

    Write-Host 'environment.json written.'

    return $Environment
}

function Invoke-K8Step {
    <#
        Runs one reproduction command with structured, exit-code-aware
        capture, so a transcript reviewer never has to guess whether a
        step passed. Records every step (pass or fail) to steps.jsonl.

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

    $Start =
        Get-Date

    Write-Host ''
    Write-Host "=== K8 STEP: $Description ===" -ForegroundColor Cyan
    Write-Host "Command: $Command"

    $global:LASTEXITCODE =
        0

    & $Command 2>&1 |
        ForEach-Object { Write-Host $_ }

    $ExitCode =
        $LASTEXITCODE

    $Passed =
        $ExpectedExitCode -contains $ExitCode

    $Record =
        [ordered]@{
            timestamp    = $Start.ToUniversalTime().ToString('o')
            description  = $Description
            command      = $Command.ToString().Trim()
            exit_code    = $ExitCode
            expected     = $ExpectedExitCode
            passed       = $Passed
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
            "Finalize-K8Attempt.ps1 -AttemptDir '$($Paths.AttemptDir)' " +
            "-Outcome Failed -Reason `"<why>`" " +
            "-FailingCommand `"$Description`" -FailingExitCode $ExitCode"
        ) -ForegroundColor Yellow

        if (-not $ContinueOnFailure) {
            throw "K8 step failed: $Description (exit $ExitCode)"
        }
    }

    return $Record
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

    # 3. final-status.json.
    try {
        $FinalStatus =
            [ordered]@{
                attempt_id            = $Paths.AttemptId
                outcome               = $Outcome
                reason                = $Reason
                failing_command       = $FailingCommand
                failing_exit_code     = $FailingExitCode
                stop_time_utc         = (Get-Date).ToUniversalTime().ToString('o')
                final_head            = $FinalHead
                final_status_short    = $FinalStatusShort
                final_status_clean    = if ($null -ne $FinalStatusShort) { $FinalStatusShort.Count -eq 0 } else { $null }
                gate_k8               = 'NOT DETERMINED BY THIS TOOL -- Gate K8 is independent review, not self-certified.'
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
}

Export-ModuleMember -Function @(
    'Write-K8Json',
    'New-K8AttemptId',
    'Get-K8AttemptPaths',
    'Initialize-K8AttemptDirectory',
    'Invoke-K8CloneToyotamahime',
    'Get-K8ToolVersion',
    'Initialize-K8AttemptEnvironment',
    'Invoke-K8Step',
    'Add-K8KnowledgeLeak',
    'Complete-K8Attempt'
)
