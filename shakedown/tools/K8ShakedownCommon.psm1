#Requires -Version 7.0
<#
    K8ShakedownCommon.psm1

    Shared constants and helpers for the K8-3 Shakedown environment.

    WHAT SHAKEDOWN IS NOT:
      - Not a formal K8-3 reproduction attempt (no k8-repro-* attempt ID is ever
        allocated here).
      - Not Gate K8 evidence. Nothing this module writes is scored, judged, or
        promoted into evidence/reproduction/ in Kakuriyo.
      - Not a change to Study01/ itself. Every function below either shells out
        to Study01's own frozen CLI scripts unmodified, or reproduces a literal
        command already written in Study01/studies/study-01-negative-result/protocol/*.md,
        with only the run ID / paths substituted. It does not reinterpret Range
        A/B/C science.

    WHAT IT IS:
      - A disposable, debuggable workspace (default C:\K8\shakedown) used to walk
        Setup -> Range A -> Range B -> Range C -> finalize/verify once, end to
        end, fixing packaging/runtime/operator-UX problems as they are found,
        before a formal, certified, tagged K8-3 attempt is spent on the same
        problems.

    Every pinned commit/tag/digest below is copied verbatim from
    Study01/README.md SS4.1/4.2 and Study01/studies/study-01-negative-result/protocol/
    c2-dnp3-range-derivation.md. If Study01/README.md's pins ever change, these
    must be re-copied by hand -- they are intentionally not derived by scraping
    the README at runtime, so that a Shakedown run always pins to a value a human
    read and committed, not to whatever the README happens to say this second.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Reuse the formal K8-3 harness's own UTF-16LE-safe wsl.exe capture
# (Get-K8WslField / Invoke-Utf16LEProcessCapture) rather than re-solving a
# problem that module's own history already fixed once (see its docstring:
# wsl.exe writes UTF-16LE to a redirected handle, which PowerShell's ordinary
# native-command pipeline decodes as mojibake). This is read-only reuse --
# Study01/tools/K8AttemptCommon.psm1 itself is never modified by Shakedown.
$script:K8AttemptCommonPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Study01\tools\K8AttemptCommon.psm1'
if (Test-Path $script:K8AttemptCommonPath) {
    Import-Module $script:K8AttemptCommonPath -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Pinned constants (copied verbatim from Study01/README.md SS4.1/4.2 and
# Study01/studies/study-01-negative-result/protocol/c2-dnp3-range-derivation.md,
# c2-dnp3-sender-procedure.md, c2-dnp3-capture-procedure.md)
# ---------------------------------------------------------------------------

$script:K8Shakedown = @{
    AmenonubocoUrl              = 'https://github.com/schutzz/ot-range-amenonuboco'
    RangeGenCommit               = '78fc17746b5d663fafec9dffe563d79fe9ea02b7'   # Range A/B generator (v0.12.0)
    RangeCTag                    = 'v0.13.0'
    RangeCCommit                 = '0378f8a32701b481e030f3db3d5f66ea471a4675'   # Range C validator
    TcpdumpImage                 = 'corfr/tcpdump'
    TcpdumpDigest                = 'sha256:3006b3bd9f041bf73f21e626b97cca5e78fd6ce271549ca95b8e6a508165512b'
    SenderAssetSha256            = '093FEFD5F1F36D715AAE4D7AB91DBAD2D7A93BFE212705D721C95B356A7C053B'
    SenderAssetInContainerPath   = '/study/traffic/send_direct_operate.py'
    GatewayCidr                  = '10.1.20.254/24'
}

function Get-K8ShakedownConstants { $script:K8Shakedown }

# ---------------------------------------------------------------------------
# Workspace / logging
# ---------------------------------------------------------------------------

function Get-K8ShakedownRoot {
    <# Root of the whole disposable Shakedown workspace. Never inside Study01/. #>
    if ($env:K8_SHAKEDOWN_ROOT) { return $env:K8_SHAKEDOWN_ROOT }
    return 'C:\K8\shakedown'
}

function Get-K8ShakedownStatePath { Join-Path (Get-K8ShakedownRoot) 'state.json' }

function Get-K8ShakedownState {
    $p = Get-K8ShakedownStatePath
    if (-not (Test-Path $p)) {
        throw "No Shakedown state found at $p. Run .\tools\Start-K8Shakedown.ps1 first."
    }
    return Get-Content $p -Raw | ConvertFrom-Json
}

function Set-K8ShakedownState {
    param([Parameter(Mandatory)][hashtable] $Updates)
    $root = Get-K8ShakedownRoot
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $p = Get-K8ShakedownStatePath
    $state = if (Test-Path $p) { Get-Content $p -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    foreach ($k in $Updates.Keys) { $state[$k] = $Updates[$k] }
    ($state | ConvertTo-Json -Depth 10) | Set-Content -Path $p -Encoding utf8NoBOM
    return $state
}

function Write-K8ShakedownLog {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'STEP')][string] $Level = 'INFO'
    )
    $root = Get-K8ShakedownRoot
    $logDir = Join-Path $root 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $logFile = Join-Path $logDir 'shakedown.log'
    $line = "[{0}] [{1}] {2}" -f (Get-Date).ToUniversalTime().ToString('o'), $Level, $Message
    Add-Content -Path $logFile -Value $line -Encoding utf8NoBOM
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'STEP'  { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
}

function New-K8ShakedownRunId {
    <#
        Shakedown run IDs are deliberately NOT k8-repro-* (that namespace is
        reserved for formal attempts) so a Shakedown run can never be mistaken
        for, or accidentally filed alongside, formal K8-3 evidence.
    #>
    param([Parameter(Mandatory)][ValidateSet('a', 'b', 'c')][string] $Range)
    $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    return "k8shakedown-range$Range-$ts"
}

function New-K8QualificationSequenceId {
    <#
        A sequence ID states WHICH SEQUENCE a run belongs to. It deliberately
        embeds NO part of the locked HEAD: `sequence_id` and `locked_head` are
        two different facts, and the whole point of the C-2b gate is to compare
        them. Binding the HEAD into the ID would make them indistinguishable
        and leave nothing to check.

        Same namespace rule as run IDs: k8shakedown-*, never k8-repro-*.

        The timestamp has one-second granularity, and closing a sequence and
        opening the next one can easily happen inside the same second, so a
        taken ID gets a `-2`, `-3`, ... suffix. That allocates a FRESH unused
        ID; it never reuses or overwrites an existing record, which stays a
        fail-closed condition. Must be called while holding the sequence lock.
    #>
    $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $base = "k8shakedown-seq-$ts"
    if (-not (Test-Path -LiteralPath (Get-K8SequenceRecordPath -SequenceId $base))) { return $base }
    for ($n = 2; $n -le 100; $n++) {
        $candidate = "$base-$n"
        if (-not (Test-Path -LiteralPath (Get-K8SequenceRecordPath -SequenceId $candidate))) { return $candidate }
    }
    throw "Could not allocate an unused sequence ID from '$base' after 100 attempts. Refusing to overwrite an existing control-plane record."
}

# ===========================================================================
# Qualification-sequence control plane (C-2b), per-run provenance (C-2) and
# termination records (C-1).
#
# WHY THIS EXISTS (K8-SHAKEDOWN-RETROSPECTIVE.md SS5 / SS7):
#   - Root causes for the first Shakedown were recoverable only because
#     somebody later wrote a commit message naming the run. SD-01/02/07 have
#     no such commit and stay unattributed to this day. C-1/C-2 remove that
#     dependency.
#   - The bundle's three "qualification runs" span DIFFERENT tooling HEADs and
#     nothing detected it. C-2b makes a single-HEAD, uninterrupted A -> B -> C
#     sequence machine-enforced rather than conventional.
#
# STRICT SEPARATION: everything this section writes is CONTROL-PLANE record
# under <root>/sequences/ and <root>/run-records/. The only thing that ever
# enters the frozen scientific evidence tree is run-provenance.json, mirrored
# once, early, long before study01_collect.py finalize-evidence hashes the
# tree. A termination record is NEVER written into the evidence tree: after
# `finalize-evidence` any added file would make `verify-integrity` disagree
# with hashes.sha256 for the rest of that run's life.
# ===========================================================================

$script:K8SequenceSchema           = 'k8shakedown-qualification-sequence/1'
$script:K8ProvenanceSchema         = 'k8shakedown-run-provenance/1'
$script:K8TerminationSchema        = 'k8shakedown-termination/1'
$script:K8LiveSequenceStatus       = @('initializing', 'open', 'ineligible')
$script:K8TerminalSequenceStatus   = @('complete', 'closed', 'abandoned')
$script:K8SequenceLockTimeoutSec   = 120
$script:K8TerminationPreviewChars  = 4096
$script:K8CaptureNote = 'bytes/sha256 describe the retained capture file, i.e. the full transcript this tooling captured. They are not a claim about the native process''s original stream bytes.'

# The current run, for stage tracking and termination attribution. Per-process
# and deliberately NOT persisted: the durable facts live in the sequence record
# and in run-records/.
$script:K8CurrentRun = $null

function Get-K8SequenceDir { Join-Path (Get-K8ShakedownRoot) 'sequences' }
function Get-K8RunRecordsDir { Join-Path (Get-K8ShakedownRoot) 'run-records' }
function Get-K8SequencePointerPath { Join-Path (Get-K8SequenceDir) 'current.txt' }
function Get-K8SequenceLockPath { Join-Path (Get-K8SequenceDir) '.lock' }
function Get-K8SequenceRecordPath { param([Parameter(Mandatory)][string] $SequenceId) Join-Path (Get-K8SequenceDir) "$SequenceId.json" }
function Get-K8RunRecordDir { param([Parameter(Mandatory)][string] $RunId) Join-Path (Get-K8RunRecordsDir) $RunId }
function Get-K8RunProvenancePath { param([Parameter(Mandatory)][string] $RunId) Join-Path (Get-K8RunRecordDir -RunId $RunId) 'run-provenance.json' }
function Get-K8TerminationRecordPath { param([Parameter(Mandatory)][string] $RunId) Join-Path (Get-K8RunRecordDir -RunId $RunId) 'termination.json' }

function Get-K8UtcNow { (Get-Date).ToUniversalTime().ToString('o') }

function Write-K8AtomicFile {
    <#
        Writes via a sibling temp file and an atomic replace, so a crash mid-
        write can never leave a half-written control-plane record that the next
        process would parse as truth. Same directory throughout, so the replace
        stays within one volume.
    #>
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Content
    )
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $tmp = "$Path.tmp-" + [guid]::NewGuid().ToString('N')
    [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding($false)))
    # Move-with-overwrite rather than File.Replace: Replace's third argument is
    # a nullable backup path, and PowerShell coerces $null to an empty string
    # for it, which fails with "The path is empty". Move(src, dst, overwrite)
    # handles both the create and the replace case in one call.
    [System.IO.File]::Move($tmp, $Path, $true)
}

function Invoke-K8WithSequenceLock {
    <#
        Inter-PROCESS exclusive lock. A same-process check is not enough: two
        shells running Start-K8ShakedownRun at the same moment would both read
        active_run == null and both reserve a run, which is exactly the
        single-active-run guarantee C-2b is supposed to make. Fails closed on
        timeout -- two processes must never both decide that a run may start.

        The parameter is deliberately NOT named $Body: PowerShell resolves a
        scriptblock's free variables against the CALLER's scope chain, so a
        caller whose scriptblock also refers to its own $Body would, inside this
        function, find THIS parameter instead -- and re-invoke the very
        scriptblock it is running. Callers additionally pin their captures with
        .GetNewClosure() so the binding cannot drift again.
    #>
    param([Parameter(Mandatory)][scriptblock] $Action)
    $dir = Get-K8SequenceDir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $lockPath = Get-K8SequenceLockPath
    $deadline = (Get-Date).AddSeconds($script:K8SequenceLockTimeoutSec)
    $stream = $null
    while ($true) {
        try {
            $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            break
        }
        catch [System.IO.IOException] {
            if ((Get-Date) -ge $deadline) {
                throw "Could not acquire the Shakedown sequence lock at $lockPath within $($script:K8SequenceLockTimeoutSec)s. Another Shakedown process is mutating the qualification sequence. This is fail-closed on purpose."
            }
            Start-Sleep -Milliseconds 100
        }
    }
    try { & $Action }
    finally { if ($stream) { $stream.Dispose() } }
}

function ConvertTo-K8CanonicalActiveRun {
    <# Guarantees every documented active_run field exists after a JSON round
       trip, so callers never have to guess whether a key is present. #>
    param($ActiveRun)
    if ($null -eq $ActiveRun) { return $null }
    $o = [ordered]@{}
    foreach ($k in @('run_id', 'range', 'state', 'reserved_utc', 'tooling_head', 'tree_clean',
                     'dirty_paths', 'tooling_repo_root', 'sequence_locked_head', 'observed_utc')) {
        $o[$k] = $(if ($ActiveRun.Contains($k)) { $ActiveRun[$k] } else { $null })
    }
    return $o
}

function ConvertTo-K8CanonicalSequenceRecord {
    <# Fixed field order on every write, so a sequence record diffs cleanly and
       every documented key always exists for readers. #>
    param($Record)
    $o = [ordered]@{}
    foreach ($k in @('schema', 'sequence_id', 'locked_head', 'started_utc', 'initial_tree_clean',
                     'tooling_repo_root', 'status', 'ineligible_reason', 'abandoned_reason',
                     'completion_claim', 'next_range', 'active_run', 'completed_runs',
                     'terminated_runs', 'closed_utc', 'closed_reason')) {
        $o[$k] = $(if ($Record.Contains($k)) { $Record[$k] } else { $null })
    }
    $o['active_run'] = ConvertTo-K8CanonicalActiveRun -ActiveRun $o['active_run']
    $o['completed_runs'] = @($o['completed_runs'])
    $o['terminated_runs'] = @($o['terminated_runs'])
    return $o
}

function New-K8SequenceRecordObject {
    param(
        [Parameter(Mandatory)][string] $SequenceId,
        [Parameter(Mandatory)][string] $LockedHead,
        [Parameter(Mandatory)][string] $RepoRoot
    )
    return [ordered]@{
        schema             = $script:K8SequenceSchema
        sequence_id        = $SequenceId
        locked_head        = $LockedHead
        started_utc        = (Get-K8UtcNow)
        initial_tree_clean = $true
        tooling_repo_root  = $RepoRoot
        status             = 'initializing'
        ineligible_reason  = $null
        abandoned_reason   = $null
        completion_claim   = $null
        next_range         = 'a'
        active_run         = $null
        completed_runs     = @()
        terminated_runs    = @()
        closed_utc         = $null
        closed_reason      = $null
    }
}

function Write-K8SequenceRecord {
    param([Parameter(Mandatory)] $Record)
    $canonical = ConvertTo-K8CanonicalSequenceRecord -Record $Record
    Write-K8AtomicFile -Path (Get-K8SequenceRecordPath -SequenceId $canonical['sequence_id']) -Content (($canonical | ConvertTo-Json -Depth 12) + "`n")
}

function Set-K8SequencePointer {
    param([Parameter(Mandatory)][string] $SequenceId)
    Write-K8AtomicFile -Path (Get-K8SequencePointerPath) -Content ($SequenceId + "`n")
}

function Remove-K8SequencePointer {
    $p = Get-K8SequencePointerPath
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}

function Complete-K8SequenceTerminalTransition {
    <#
        complete / closed / abandoned are IMMUTABLE TERMINAL states: nothing
        mutates a record once it reaches one. current.txt names only the
        current LIVE sequence, so a terminal transition retires the pointer in
        the same locked mutation that writes the terminal status -- never
        "reconciles" it later.
    #>
    param(
        [Parameter(Mandatory)] $Record,
        [Parameter(Mandatory)][ValidateSet('complete', 'closed', 'abandoned')][string] $Status
    )
    $Record['status'] = $Status
    Write-K8SequenceRecord -Record $Record
    Remove-K8SequencePointer
}

function Test-K8StaleInitializingSequence {
    <#
        An `initializing` record left by a crash between creation stages may be
        quarantined as `abandoned` ONLY when all four conditions below are
        machine-provable. Anything less is not "harmless garbage" -- it is an
        unexplained control-plane record, and this tooling fails closed on it.
    #>
    param([Parameter(Mandatory)] $Record, $Pointer, [string[]] $RunRecordSequenceIds)
    if ([string]::IsNullOrWhiteSpace([string]$Record['sequence_id'])) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Record['started_utc'])) { return $false }
    if ([string]$Record['locked_head'] -notmatch '^[0-9a-f]{40}$') { return $false }
    # The discriminator: a pointer still naming it means the crash happened
    # AFTER the pointer write, which needs an explicit operator close.
    if ($Pointer -eq [string]$Record['sequence_id']) { return $false }
    if ($null -ne $Record['active_run']) { return $false }
    if (@($Record['completed_runs']).Count -ne 0) { return $false }
    if (@($Record['terminated_runs']).Count -ne 0) { return $false }
    if (@($RunRecordSequenceIds) -contains [string]$Record['sequence_id']) { return $false }
    return $true
}

function Get-K8ControlPlaneState {
    <#
        Read-only scan of the whole control plane. sequences/*.json is the
        truth source; current.txt is a convenience pointer that is CROSS-CHECKED
        against it, never trusted as truth (a crash between the record write and
        the pointer write must not let a second "open" sequence be created).

        Orphan detection compares run-records/ against the run IDs referenced by
        EVERY sequence record regardless of status -- not only live ones, or a
        run belonging to an old closed sequence would be misreported as orphaned.
    #>
    $records = @()
    $seqDir = Get-K8SequenceDir
    if (Test-Path -LiteralPath $seqDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $seqDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $parsed = (Get-Content -LiteralPath $f.FullName -Raw) | ConvertFrom-Json -AsHashtable
            $records += , (ConvertTo-K8CanonicalSequenceRecord -Record $parsed)
        }
    }

    $pointer = $null
    $pp = Get-K8SequencePointerPath
    if (Test-Path -LiteralPath $pp) { $pointer = (Get-Content -LiteralPath $pp -Raw).Trim() }

    $known = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($r in $records) {
        if ($null -ne $r['active_run']) { [void]$known.Add([string]$r['active_run']['run_id']) }
        foreach ($c in @($r['completed_runs']))  { if ($null -ne $c) { [void]$known.Add([string]$c['run_id']) } }
        foreach ($t in @($r['terminated_runs'])) { if ($null -ne $t) { [void]$known.Add([string]$t['run_id']) } }
    }

    $runRecordIds = @()
    $runSeqIds = @()
    $rrd = Get-K8RunRecordsDir
    if (Test-Path -LiteralPath $rrd) {
        foreach ($d in @(Get-ChildItem -LiteralPath $rrd -Directory -ErrorAction SilentlyContinue)) {
            $runRecordIds += $d.Name
            $prov = Join-Path $d.FullName 'run-provenance.json'
            if (Test-Path -LiteralPath $prov) {
                try {
                    $p = (Get-Content -LiteralPath $prov -Raw) | ConvertFrom-Json -AsHashtable
                    if ($p.Contains('sequence_id')) { $runSeqIds += [string]$p['sequence_id'] }
                }
                catch { Write-K8ShakedownLog -Level WARN -Message "unreadable run provenance at ${prov}: $($_.Exception.Message)" }
            }
        }
    }
    $orphans = @($runRecordIds | Where-Object { -not $known.Contains($_) })

    $live = @($records | Where-Object { $script:K8LiveSequenceStatus -contains [string]$_['status'] })

    return [pscustomobject]@{
        Records              = $records
        Live                 = $live
        Pointer              = $pointer
        Orphans              = $orphans
        RunRecordIds         = @($runRecordIds)
        RunRecordSequenceIds = @($runSeqIds)
    }
}

function Test-K8ActiveRunHasTermination {
    param($ActiveRun)
    if ($null -eq $ActiveRun) { return $false }
    return (Test-Path -LiteralPath (Get-K8TerminationRecordPath -RunId ([string]$ActiveRun['run_id'])))
}

function Assert-K8SequenceOperationAllowed {
    <#
        OPERATION-AWARE transition gate. A single generic "is the control plane
        healthy?" test cannot work here, because two of the states it would
        reject are states this tooling itself creates on the way to a correct
        outcome:

          - active_run.state == 'initializing' is what ReserveRun leaves behind,
            and FinalizeRunInitialization is the operation that clears it;
          - termination.json present while status is still 'open' is what
            step 1 of a termination leaves behind, and RecordTermination is the
            operation that completes it.

        So the gate distinguishes an EXTERNAL new start from the INTERNAL
        continuation of an already-reserved run, by requiring -RunId to match
        the sequence's own active_run. Everything else still fails closed.

        Terminal records (complete/closed/abandoned) are immutable and are
        never live, so no operation can ever target one.
    #>
    param(
        [Parameter(Mandatory)][string] $Operation,
        [Parameter(Mandatory)] $State,
        [string] $RunId,
        [string] $SequenceId
    )
    $deny = {
        param([string] $Why)
        throw "Operation '$Operation' is not permitted by the qualification-sequence control plane: $Why"
    }
    $live = @($State.Live)

    if ($live.Count -eq 0) {
        if ($State.Pointer) {
            & $deny "current.txt names '$($State.Pointer)' but no live sequence exists. current.txt is a pointer, not evidence -- inspect $(Get-K8SequenceDir), remove the stale pointer by hand, then retry."
        }
        if ($Operation -eq 'NewSequence') { return }
        if ($Operation -eq 'CloseSequence') {
            & $deny 'no live qualification sequence exists. complete / closed / abandoned are immutable terminal states and are never re-closed.'
        }
        & $deny 'no live qualification sequence exists. Run .\tools\Start-K8QualificationSequence.ps1 first.'
    }

    if ($live.Count -ge 2) {
        $ids = @($live | ForEach-Object { [string]$_['sequence_id'] }) -join ', '
        if ($Operation -eq 'CloseSequence') {
            if (-not $SequenceId) { & $deny "control-plane corruption: $($live.Count) live sequences ($ids). Pass -SequenceId to say which one to close; this tooling never guesses." }
            return
        }
        & $deny "control-plane corruption: $($live.Count) live sequences ($ids). Close them one at a time with -SequenceId before anything else."
    }

    $s = $live[0]
    $sid = [string]$s['sequence_id']
    $status = [string]$s['status']
    $pointerMatches = ($State.Pointer -eq $sid)

    if ($status -eq 'initializing') {
        if ($Operation -eq 'CloseSequence') { return }
        if ($pointerMatches) {
            & $deny "sequence '$sid' was interrupted after its pointer was written but before it became open. Close it explicitly (.\tools\Close-K8QualificationSequence.ps1 -Reason ...) -- it is not provably-unused residue."
        }
        if ($Operation -eq 'NewSequence' -and (Test-K8StaleInitializingSequence -Record $s -Pointer $State.Pointer -RunRecordSequenceIds $State.RunRecordSequenceIds)) { return }
        & $deny "sequence '$sid' is still 'initializing' and cannot be proven unused. Close it explicitly before creating another."
    }

    if (@($State.Orphans).Count -gt 0) {
        if ($Operation -eq 'CloseSequence') { return }
        & $deny "orphan run record(s) exist that no sequence accounts for: $(@($State.Orphans) -join ', '). A started run whose lifecycle cannot be reconstructed is exactly what C-2 exists to prevent, so this is not ignored silently. run-records/<id>/ is control-plane record; its scientific counterpart, if any, is runs/<id>/. Resolving it is an operator judgment -- this tooling never deletes a record."
    }

    if (-not $pointerMatches) {
        if ($Operation -eq 'CloseSequence') { return }
        # Reported before the plain "a live sequence exists" refusal below,
        # because an inconsistent control plane is what the operator has to
        # resolve first -- and closing is the remedy for both.
        & $deny "current.txt ($(if ($State.Pointer) { "'$($State.Pointer)'" } else { '<absent>' })) disagrees with the live sequence '$sid'. Close the sequence explicitly to resolve it."
    }

    # Now that the control plane is known consistent, a NewSequence refusal can
    # state the real reason: a sequence is live and is never stepped over.
    if ($Operation -eq 'NewSequence') {
        & $deny "sequence '$sid' is still live (status '$status'). Close it explicitly with .\tools\Close-K8QualificationSequence.ps1 -Reason '...' before opening another; a sequence is never stepped over."
    }

    if ($status -eq 'ineligible') {
        if ($Operation -eq 'CloseSequence') { return }
        & $deny "sequence '$sid' is ineligible: $([string]$s['ineligible_reason']). A terminated run ends its sequence -- close it, fix, open a NEW sequence and restart from Range A. Retrying inside the same sequence is not permitted."
    }

    # status = open
    if ($Operation -eq 'CloseSequence') { return }
    $active = $s['active_run']

    if ($null -eq $active) {
        if ($Operation -eq 'ReserveRun') { return }
        & $deny "sequence '$sid' has no active run, so there is nothing for '$Operation' to act on."
    }

    $activeId = [string]$active['run_id']
    if ($Operation -eq 'ReserveRun') {
        & $deny "run '$activeId' is already active in sequence '$sid'. Only one run may be active at a time."
    }
    if ($RunId -ne $activeId) {
        & $deny "'$Operation' targets run '$RunId' but the active run is '$activeId'."
    }

    if (Test-K8ActiveRunHasTermination -ActiveRun $active) {
        # Authoritative termination already on disk; only completing the
        # open -> ineligible half of that transaction is left.
        if ($Operation -eq 'RecordTermination') { return }
        & $deny "run '$activeId' already has an authoritative termination record, so it can never be completed. Finish the transition (RecordTermination) or close the sequence."
    }

    if ([string]$active['state'] -eq 'initializing') {
        if ($Operation -eq 'FinalizeRunInitialization') { return }
        & $deny "run '$activeId' was reserved but its initialization never finished. Close the sequence -- a half-initialized run is not resumed."
    }

    if ($Operation -eq 'CompleteRun' -or $Operation -eq 'RecordTermination') { return }
    & $deny "unhandled state for '$Operation' on run '$activeId'."
}

function Invoke-K8SequenceMutation {
    <#
        The one entry point for every control-plane mutation: take the
        inter-process lock, RE-READ the control plane inside it (never trust a
        value read before the lock), check the operation against the transition
        gate, then let $Body write via the atomic helpers. $Body receives the
        freshly-read state.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('NewSequence', 'ReserveRun', 'FinalizeRunInitialization', 'RecordTermination', 'CompleteRun', 'CloseSequence')][string] $Operation,
        [string] $RunId,
        [string] $SequenceId,
        [Parameter(Mandatory)][scriptblock] $Body
    )
    # Pinned into a closure: the mutation body must stay the caller's, and the
    # operation/run identifiers must stay this call's, regardless of what names
    # exist in the scopes this ends up executing under.
    $mutation = $Body
    return Invoke-K8WithSequenceLock -Action {
        $state = Get-K8ControlPlaneState
        Assert-K8SequenceOperationAllowed -Operation $Operation -State $state -RunId $RunId -SequenceId $SequenceId
        & $mutation $state
    }.GetNewClosure()
}

function Get-K8ToolingIdentity {
    <#
        One observation of "what tooling is on disk right now": exact HEAD plus
        whether the worktree is clean. Untracked files count as dirty, matching
        the Range C source-cleanliness check this repo already uses.

        Streams are captured SEPARATELY -- a git hint on stderr must never be
        parsed as part of a commit SHA.
    #>
    param([Parameter(Mandatory)][string] $RepoRoot)
    $resolved = (Resolve-Path -LiteralPath $RepoRoot).Path
    $headCapture = Invoke-K8SeparatedNativeCapture -FilePath 'git' -ArgumentList @('-C', $resolved, 'rev-parse', 'HEAD')
    if ($headCapture.ExitCode -ne 0) { throw "git rev-parse HEAD failed in $resolved (exit $($headCapture.ExitCode)): $($headCapture.Stderr.Trim())" }
    $head = ((@($headCapture.Stdout) -join '') -replace '\s', '')
    if ($head -notmatch '^[0-9a-f]{40}$') { throw "git rev-parse HEAD in $resolved did not return a 40-hex commit: '$head'" }
    $statusCapture = Invoke-K8SeparatedNativeCapture -FilePath 'git' -ArgumentList @('-C', $resolved, 'status', '--porcelain')
    if ($statusCapture.ExitCode -ne 0) { throw "git status --porcelain failed in $resolved (exit $($statusCapture.ExitCode)): $($statusCapture.Stderr.Trim())" }
    $dirty = @(@($statusCapture.Stdout) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { "$_".TrimEnd() })
    return [pscustomobject]@{
        Head       = $head
        TreeClean  = ($dirty.Count -eq 0)
        DirtyPaths = $dirty
        RepoRoot   = $resolved
    }
}

function New-K8QualificationSequence {
    <#
        Opens a qualification sequence and LOCKS the tooling HEAD it commits to.
        Refuses on a dirty tree, and refuses while ANY live sequence exists --
        including an `ineligible` one, so a terminated sequence cannot be
        stepped over without an explicit close.

        Created in three stages inside the lock so a crash is always recoverable:
        record(initializing) -> pointer -> record(open).
    #>
    param([Parameter(Mandatory)][string] $RepoRoot)
    $identity = Get-K8ToolingIdentity -RepoRoot $RepoRoot
    if (-not $identity.TreeClean) {
        throw "Refusing to open a qualification sequence: the tooling worktree at $($identity.RepoRoot) is not clean. A sequence locks an exact commit, and a dirty tree means the running code is not that commit.`n$($identity.DirtyPaths -join "`n")"
    }
    return Invoke-K8SequenceMutation -Operation 'NewSequence' -Body {
        param($State)
        foreach ($residue in @($State.Live)) {
            # The gate above already proved this is quarantinable residue.
            $residue['abandoned_reason'] = "provably-unused 'initializing' residue quarantined at $(Get-K8UtcNow); no pointer, no runs, no run-record references it"
            Complete-K8SequenceTerminalTransition -Record $residue -Status 'abandoned'
            Write-K8ShakedownLog -Level WARN -Message "quarantined stale initializing sequence $([string]$residue['sequence_id']) as 'abandoned' (it is retained, not deleted)."
        }
        $id = New-K8QualificationSequenceId
        $path = Get-K8SequenceRecordPath -SequenceId $id
        if (Test-Path -LiteralPath $path) { throw "sequence ID collision: $path already exists. Refusing to overwrite an existing control-plane record." }
        $record = New-K8SequenceRecordObject -SequenceId $id -LockedHead $identity.Head -RepoRoot $identity.RepoRoot
        Write-K8SequenceRecord -Record $record          # stage 1
        Set-K8SequencePointer -SequenceId $id           # stage 2
        $record['status'] = 'open'
        Write-K8SequenceRecord -Record $record          # stage 3
        Write-K8ShakedownLog -Level STEP -Message "qualification sequence $id opened; locked_head=$($identity.Head); next_range=a"
        ConvertTo-K8CanonicalSequenceRecord -Record $record
    }.GetNewClosure()
}

function Get-K8QualificationSequence {
    <# The current live sequence. Resolved by scanning the records, not by
       trusting current.txt. #>
    $state = Get-K8ControlPlaneState
    $live = @($state.Live)
    if ($live.Count -eq 0) { throw 'No live qualification sequence exists. Run .\tools\Start-K8QualificationSequence.ps1 first.' }
    if ($live.Count -ge 2) { throw "Control-plane corruption: $($live.Count) live sequences. Close them one at a time with .\tools\Close-K8QualificationSequence.ps1 -SequenceId <id>." }
    return $live[0]
}

function Write-K8OperatorCloseTermination {
    <#
        A run closed by the operator still gets an authoritative, machine-
        readable termination record -- otherwise closing would manufacture
        exactly the unattributed termination C-1 exists to abolish.

        tooling_head comes from the run's OWN records: its provenance if it got
        that far, otherwise the reservation the sequence made durable at
        ReserveRun time. The head at close time is a different fact and is never
        substituted here.
    #>
    param(
        [Parameter(Mandatory)] $Sequence,
        [Parameter(Mandatory)] $ActiveRun,
        [Parameter(Mandatory)][string] $Reason
    )
    $runId = [string]$ActiveRun['run_id']
    $provPath = Get-K8RunProvenancePath -RunId $runId
    $head = $null
    $source = $null
    if (Test-Path -LiteralPath $provPath) {
        $prov = (Get-Content -LiteralPath $provPath -Raw) | ConvertFrom-Json -AsHashtable
        $head = [string]$prov['tooling_head']
        $source = 'run-provenance'
    }
    elseif ($null -ne $ActiveRun['tooling_head']) {
        $head = [string]$ActiveRun['tooling_head']
        $source = 'reservation'
    }
    else {
        throw "Cannot write an operator-close termination for $runId : neither its run-provenance.json nor its reservation records a tooling_head, and this tooling will not substitute the current HEAD."
    }
    $record = [ordered]@{
        schema       = $script:K8TerminationSchema
        run_id       = $runId
        sequence_id  = [string]$Sequence['sequence_id']
        tooling_head = $head
        tooling_head_source = $source
        stage        = 'operator-close'
        failure_kind = 'non-command'
        timestamp    = (Get-K8UtcNow)
        message      = $Reason
        exception    = $null
        command      = $null
    }
    Write-K8AtomicFile -Path (Get-K8TerminationRecordPath -RunId $runId) -Content (($record | ConvertTo-Json -Depth 12) + "`n")
    Write-K8ShakedownLog -Message "operator-close termination retained for $runId (tooling_head from $source)."
}

function Close-K8QualificationSequence {
    <#
        The only way out of a live sequence. Closing preserves an existing
        termination record byte-for-byte and synthesises one only when none
        exists, so no run ever ends up terminated-but-unrecorded.
    #>
    param(
        [Parameter(Mandatory)][string] $Reason,
        [string] $SequenceId
    )
    return Invoke-K8SequenceMutation -Operation 'CloseSequence' -SequenceId $SequenceId -Body {
        param($State)
        $live = @($State.Live)
        $target = $(if ($SequenceId) { @($live | Where-Object { [string]$_['sequence_id'] -eq $SequenceId })[0] } else { $live[0] })
        if ($null -eq $target) { throw "No live sequence named '$SequenceId'. Terminal records are immutable and are never re-closed." }
        $active = $target['active_run']
        if ($null -ne $active) {
            if (Test-K8ActiveRunHasTermination -ActiveRun $active) {
                Write-K8ShakedownLog -Message "run $([string]$active['run_id']) already has a termination record; preserving it unchanged."
            }
            else {
                Write-K8OperatorCloseTermination -Sequence $target -ActiveRun $active -Reason $Reason
            }
            $target['terminated_runs'] = @(@($target['terminated_runs']) + , ([ordered]@{
                range      = [string]$active['range']
                run_id     = [string]$active['run_id']
                closed_utc = (Get-K8UtcNow)
                reason     = $Reason
            }))
            $target['active_run'] = $null
        }
        $target['closed_utc'] = (Get-K8UtcNow)
        $target['closed_reason'] = $Reason
        Complete-K8SequenceTerminalTransition -Record $target -Status 'closed'
        Write-K8ShakedownLog -Level STEP -Message "qualification sequence $([string]$target['sequence_id']) closed: $Reason"
        ConvertTo-K8CanonicalSequenceRecord -Record $target
    }.GetNewClosure()
}

function Start-K8ShakedownRun {
    <#
        Allocates a run inside the sequence and makes its provenance durable
        BEFORE any scientific/runtime step. Three commits, in this order:

          1. ReserveRun -- writes active_run INCLUDING the tooling identity just
             observed. Doing this first is what lets a crash before step 2 still
             be closed out with a truthful tooling_head.
          2. run-provenance.json, built from those same observed values.
          3. FinalizeRunInitialization -- active_run.state = 'running'.

        The sequence-binding gate is deliberately NOT here: it belongs inside the
        run boundary, so a refused run still leaves a termination record.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('a', 'b', 'c')][string] $Range,
        [Parameter(Mandatory)][string] $RepoRoot
    )
    $identity = Get-K8ToolingIdentity -RepoRoot $RepoRoot
    $runId = New-K8ShakedownRunId -Range $Range
    $observedUtc = Get-K8UtcNow

    $sequence = Invoke-K8SequenceMutation -Operation 'ReserveRun' -RunId $runId -Body {
        param($State)
        $s = @($State.Live)[0]
        if ([string]$s['next_range'] -ne $Range) {
            throw "Sequence $([string]$s['sequence_id']) expects Range $([string]$s['next_range']) next, not Range $Range. A qualification sequence is one uninterrupted A -> B -> C at one locked HEAD."
        }
        if (Test-Path -LiteralPath (Get-K8RunRecordDir -RunId $runId)) {
            throw "run-record collision: $(Get-K8RunRecordDir -RunId $runId) already exists. Refusing to overwrite an existing control-plane record."
        }
        $s['active_run'] = [ordered]@{
            run_id               = $runId
            range                = $Range
            state                = 'initializing'
            reserved_utc         = $observedUtc
            tooling_head         = $identity.Head
            tree_clean           = $identity.TreeClean
            dirty_paths          = @($identity.DirtyPaths)
            tooling_repo_root    = $identity.RepoRoot
            sequence_locked_head = [string]$s['locked_head']
            observed_utc         = $observedUtc
        }
        Write-K8SequenceRecord -Record $s
        ConvertTo-K8CanonicalSequenceRecord -Record $s
    }.GetNewClosure()

    $provenance = [ordered]@{
        schema               = $script:K8ProvenanceSchema
        run_id               = $runId
        range                = $Range
        sequence_id          = [string]$sequence['sequence_id']
        tooling_head         = $identity.Head
        tree_clean           = $identity.TreeClean
        dirty_paths          = @($identity.DirtyPaths)
        started_utc          = $observedUtc
        tooling_repo_root    = $identity.RepoRoot
        sequence_locked_head = [string]$sequence['locked_head']
        observation_point    = 'run-initialization'
    }
    Write-K8AtomicFile -Path (Get-K8RunProvenancePath -RunId $runId) -Content (($provenance | ConvertTo-Json -Depth 12) + "`n")

    Invoke-K8SequenceMutation -Operation 'FinalizeRunInitialization' -RunId $runId -Body {
        param($State)
        $s = @($State.Live)[0]
        $s['active_run']['state'] = 'running'
        Write-K8SequenceRecord -Record $s
    }.GetNewClosure() | Out-Null

    $script:K8CurrentRun = [pscustomobject]@{
        RunId       = $runId
        Range       = $Range
        SequenceId  = [string]$sequence['sequence_id']
        ToolingHead = $identity.Head
        LockedHead  = [string]$sequence['locked_head']
        RepoRoot    = $identity.RepoRoot
        Stage       = 'run-initialization'
        # Set by Set-K8ShakedownRunEvidence once the tree exists; until then
        # the C-6 stage-boundary gate has nothing to check against.
        RunEvidence = $null
    }
    Write-K8ShakedownLog -Level STEP -Message "run $runId reserved in sequence $([string]$sequence['sequence_id']); provenance retained before any scientific/runtime step."
    return $script:K8CurrentRun
}

function Set-K8ShakedownRunStage {
    <# Call this IMMEDIATELY BEFORE the first fallible operation of the stage.
       Setting it afterwards would attribute that operation's failure to the
       previous stage.

       C-6: leaving a stage is also where that stage's own artifacts are
       checked. Doing it HERE rather than at each call site means the check
       cannot be forgotten when a new stage is added, and the throw happens
       while Stage still names the stage that owed the artifact -- so the
       termination record attributes it correctly. It is armed only once
       Set-K8ShakedownRunEvidence has been called; stages that precede the
       evidence tree have nothing to check. #>
    param([Parameter(Mandatory)][string] $Stage)
    if ($null -eq $script:K8CurrentRun) { throw "Set-K8ShakedownRunStage -Stage '$Stage' was called with no active run context." }
    $previous = $script:K8CurrentRun.Stage
    if ($script:K8CurrentRun.RunEvidence -and $previous -and $previous -ne $Stage) {
        Assert-K8StageArtifacts -Range $script:K8CurrentRun.Range -Stage $previous -RunEvidence $script:K8CurrentRun.RunEvidence
    }
    $script:K8CurrentRun.Stage = $Stage
    Write-K8ShakedownLog -Message "stage -> $Stage"
}

function Set-K8ShakedownRunEvidence {
    <# Arms the C-6 stage-boundary gate by telling the run context where its
       evidence tree is. Called as soon as that tree exists. #>
    param([Parameter(Mandatory)][string] $Path)
    if ($null -eq $script:K8CurrentRun) { throw "Set-K8ShakedownRunEvidence was called with no active run context." }
    $script:K8CurrentRun.RunEvidence = $Path
    return $script:K8CurrentRun
}

function Set-K8ShakedownRunContext {
    <# Re-establishes the run context for the second phase of an already-started
       run (Complete), so stage tracking and termination attribution work there
       too. #>
    param([Parameter(Mandatory)][string] $RunId, [Parameter(Mandatory)][string] $RepoRoot)
    $provPath = Get-K8RunProvenancePath -RunId $RunId
    if (-not (Test-Path -LiteralPath $provPath)) { throw "No run-provenance record for $RunId at $provPath." }
    $prov = (Get-Content -LiteralPath $provPath -Raw) | ConvertFrom-Json -AsHashtable
    $script:K8CurrentRun = [pscustomobject]@{
        RunId       = $RunId
        Range       = [string]$prov['range']
        SequenceId  = [string]$prov['sequence_id']
        ToolingHead = [string]$prov['tooling_head']
        LockedHead  = [string]$prov['sequence_locked_head']
        RepoRoot    = (Resolve-Path -LiteralPath $RepoRoot).Path
        Stage       = 'run-context-restore'
        RunEvidence = $null
    }
    return $script:K8CurrentRun
}

function Assert-K8SequenceBinding {
    <#
        The C-2b gate, run immediately before the first scientific/runtime step.

        It RE-OBSERVES git rather than comparing stored values against each
        other. run-provenance records the run-INITIALIZATION observation; the
        sequence lock does not lock the Git worktree, so a checkout or an edit
        between reservation and the first step is only visible here.
    #>
    param([Parameter(Mandatory)] $Run)
    $now = Get-K8ToolingIdentity -RepoRoot $Run.RepoRoot
    $provPath = Get-K8RunProvenancePath -RunId $Run.RunId
    if (-not (Test-Path -LiteralPath $provPath)) { throw "Sequence binding gate: no run-provenance record for $($Run.RunId) at $provPath." }
    $prov = (Get-Content -LiteralPath $provPath -Raw) | ConvertFrom-Json -AsHashtable
    $seq = Get-K8QualificationSequence

    $problems = @()
    if ($now.Head -ne [string]$prov['tooling_head']) { $problems += "current HEAD $($now.Head) != run-provenance tooling_head $([string]$prov['tooling_head']) (the tooling changed after this run was initialized)" }
    if ($now.Head -ne [string]$seq['locked_head'])   { $problems += "current HEAD $($now.Head) != sequence locked_head $([string]$seq['locked_head'])" }
    if ([string]$prov['tooling_head'] -ne [string]$seq['locked_head']) { $problems += "run-provenance tooling_head $([string]$prov['tooling_head']) != sequence locked_head $([string]$seq['locked_head'])" }
    if (-not $now.TreeClean) { $problems += "the tooling worktree is not clean now:`n$($now.DirtyPaths -join "`n")" }
    if ($prov['tree_clean'] -ne $true) { $problems += 'run-provenance records tree_clean=false at run initialization' }
    if ($now.RepoRoot -ne [string]$prov['tooling_repo_root']) { $problems += "repo root $($now.RepoRoot) != run-provenance tooling_repo_root $([string]$prov['tooling_repo_root'])" }
    if ($now.RepoRoot -ne [string]$seq['tooling_repo_root'])  { $problems += "repo root $($now.RepoRoot) != sequence tooling_repo_root $([string]$seq['tooling_repo_root'])" }
    if ([string]$prov['sequence_id'] -ne [string]$seq['sequence_id']) { $problems += "run belongs to sequence $([string]$prov['sequence_id']) but the live sequence is $([string]$seq['sequence_id'])" }

    if ($problems.Count -gt 0) {
        throw "Sequence binding gate FAILED for $($Run.RunId); no scientific or runtime step has been executed.`n - $($problems -join "`n - ")`nClose this sequence, fix, open a NEW sequence and restart from Range A."
    }
    Write-K8ShakedownLog -Message "sequence binding verified for $($Run.RunId): HEAD $($now.Head) == provenance == locked_head, tree clean."
}

function Copy-K8RunProvenanceIntoEvidence {
    <#
        Mirrors the pre-tree provenance into the run evidence tree, byte for
        byte, as soon as the frozen evidence_tree.create() has made the tree.

        It goes at the tree ROOT, never inside one of the eight schema
        directories: study01/preflight.py's evidence_tree() check requires those
        eight to be empty at preflight time and does not look at the root. Being
        at the root also means finalize-evidence hashes it, and it is never
        written again afterwards.
    #>
    param([Parameter(Mandatory)] $Run, [Parameter(Mandatory)][string] $RunEvidence)
    $src = Get-K8RunProvenancePath -RunId $Run.RunId
    if (-not (Test-Path -LiteralPath $src)) { throw "run-provenance record missing at $src; refusing to continue without it." }
    Copy-Item -LiteralPath $src -Destination (Join-Path $RunEvidence 'run-provenance.json') -Force
}

# ===========================================================================
# C-4  observation retention
# C-5  legitimate-absence axes (the observer side lives in
#      k8_shakedown_evidence.py; this file only consumes its records)
# C-6  stage-boundary artifact completeness
# C-7  narrative <-> artifact reference integrity
#
# WHY THIS EXISTS (K8-SHAKEDOWN-RETROSPECTIVE.md SS5 C-3..C-7): these are one
# group, not five fixes. Their shared subject is the evidence LIFECYCLE --
# preserve what was observed, without adding meaning, without dropping
# meaning, and early enough that a later stage cannot quietly paper over a
# gap:
#
#     observation -> existence state -> stage completeness -> narrative
#        C-4             C-5                 C-6                C-7
#
# and, at the far end, the human judgment boundary C-3 protects.
#
# NOTHING HERE SCORES ANYTHING. Every function below either retains what a
# command/observer produced, or checks that something the tooling itself
# promised to retain is actually present. None of them derive Pass/Fail,
# Alert/No alert, or any scored verdict, and none of them read expected/.
# ===========================================================================

$script:K8CommandObservationSchema = 'k8shakedown-command-observation/1'
$script:K8FinalizeIdentitySchema   = 'k8shakedown-finalize-identity/1'
$script:K8ObservationSuffix        = '.observation.json'

# C-7: the ONLY repository prefixes a machine-generated narrative may cite as
# a frozen protocol document. Left as "somewhere in the repo" this would be an
# implementer's judgment call, and a narrative writer could justify pointing at
# any file at all as a "frozen protocol reference". Measured against every
# frozen document the four narrative writers actually cite -- README SS5.x/SS6.x
# plus c2-dnp3-capture-procedure.md, c2-dnp3-image-inventory.md,
# c2-dnp3-range-derivation.md, evidence-schema.md, freeze-decision-table.md and
# c2-dnp3-step4-range-b-fault-pilot.md, all of which live under the protocol
# directory -- these two prefixes are closed. Widening them is a Plan revision,
# never a quiet code change.
$script:K8FrozenProtocolDocPrefixes = @(
    'Study01/README.md',
    'Study01/studies/study-01-negative-result/protocol/'
)

# ---------------------------------------------------------------------------
# C-4: observation envelope
#
# Capture METHOD is not forced into one shape -- the producers genuinely
# differ (separated native capture, a merged transcript, cmd.exe writing two
# files directly). What is forced is the RECORD: argv, exit code, timestamp,
# and an explicit statement of which capture semantics produced the streams.
#
# `combined` deliberately reports stdout/stderr as null rather than inventing
# per-stream emptiness flags. Once `2>&1` has merged them, per-stream
# emptiness is UNRECOVERABLE, and manufacturing it would be exactly the
# fabricated stream semantics Batch 1 already refused to write.
# ---------------------------------------------------------------------------

function Get-K8TextStreamDescriptor {
    <# bytes/sha256 over the UTF-8 encoding of the retained transcript text.
       `path` is null when the stream is retained inside a shared artifact
       rather than as its own file -- stating a path that does not hold
       exactly these bytes would be worse than stating none. #>
    param([AllowNull()][AllowEmptyString()][string] $Text)
    $body = $(if ($null -eq $Text) { '' } else { $Text })
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $sha.Dispose() }
    return [ordered]@{
        path   = $null
        bytes  = $bytes.Length
        sha256 = $digest
        empty  = ($bytes.Length -eq 0)
    }
}

function Get-K8FileStreamDescriptor {
    <# For a stream the producer wrote straight to a file: hash the FILE's raw
       bytes, never a re-encoded copy of them. Range C's validator redirects
       through cmd.exe precisely so no re-encoding happens, and this must not
       undo that. A zero-byte file is described, never treated as absent. #>
    param(
        [Parameter(Mandatory)][string] $RunEvidence,
        [Parameter(Mandatory)][string] $RelativePath
    )
    $full = Join-Path $RunEvidence $RelativePath
    if (-not (Test-Path -LiteralPath $full)) {
        throw "C-4 observation cannot describe '$RelativePath': the retained stream file does not exist under $RunEvidence. An empty stream must still be a file."
    }
    $length = (Get-Item -LiteralPath $full).Length
    return [ordered]@{
        path   = ($RelativePath -replace '\\', '/')
        bytes  = $length
        sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
        empty  = ($length -eq 0)
    }
}

function New-K8SeparatedCommandObservation {
    <# One command whose streams really were captured separately. #>
    param(
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][string[]] $Argv,
        [Parameter(Mandatory)][int] $ExitCode,
        [Parameter(Mandatory)][string] $TimestampUtc,
        [AllowNull()][AllowEmptyString()][string] $Stdout,
        [AllowNull()][AllowEmptyString()][string] $Stderr,
        [AllowNull()][string] $ContainingArtifact
    )
    return [ordered]@{
        label               = $Label
        argv                = @($Argv)
        exit_code           = $ExitCode
        timestamp_utc       = $TimestampUtc
        capture_semantics   = 'separated'
        containing_artifact = $(if ($ContainingArtifact) { $ContainingArtifact -replace '\\', '/' } else { $null })
        stdout              = (Get-K8TextStreamDescriptor -Text $Stdout)
        stderr              = (Get-K8TextStreamDescriptor -Text $Stderr)
        combined_output     = $null
        artifacts           = $null
        capture_note        = $script:K8CaptureNote
    }
}

function New-K8FileBackedCommandObservation {
    <# One command whose stdout and stderr the producer redirected straight to
       their own retained files. `artifacts` enumerates them with their role
       and channel; it is BUILT FROM the same two descriptors, so the
       enumeration and the addressed view cannot drift apart. #>
    param(
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][string[]] $Argv,
        [Parameter(Mandatory)][int] $ExitCode,
        [Parameter(Mandatory)][string] $TimestampUtc,
        [Parameter(Mandatory)][string] $RunEvidence,
        [Parameter(Mandatory)][string] $StdoutRelativePath,
        [Parameter(Mandatory)][string] $StderrRelativePath
    )
    $stdout = Get-K8FileStreamDescriptor -RunEvidence $RunEvidence -RelativePath $StdoutRelativePath
    $stderr = Get-K8FileStreamDescriptor -RunEvidence $RunEvidence -RelativePath $StderrRelativePath
    return [ordered]@{
        label               = $Label
        argv                = @($Argv)
        exit_code           = $ExitCode
        timestamp_utc       = $TimestampUtc
        capture_semantics   = 'file-backed'
        containing_artifact = $null
        stdout              = $stdout
        stderr              = $stderr
        combined_output     = $null
        artifacts           = @(
            [ordered]@{ role = 'stdout'; channel = 'stdout'; path = $stdout['path']; bytes = $stdout['bytes']; sha256 = $stdout['sha256']; empty = $stdout['empty'] }
            [ordered]@{ role = 'stderr'; channel = 'stderr'; path = $stderr['path']; bytes = $stderr['bytes']; sha256 = $stderr['sha256']; empty = $stderr['empty'] }
        )
        capture_note        = 'bytes/sha256 describe the retained files as the producer wrote them; no re-encoding was performed between the process and the file.'
    }
}

function New-K8CombinedCommandObservation {
    <# One command captured through `2>&1` / `*>`. stdout and stderr are null
       BY CONSTRUCTION: the merge destroyed the distinction, and this record
       will not invent it back. #>
    param(
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][string[]] $Argv,
        [Parameter(Mandatory)][int] $ExitCode,
        [Parameter(Mandatory)][string] $TimestampUtc,
        [AllowNull()][AllowEmptyString()][string] $CombinedOutput,
        [AllowNull()][string] $ContainingArtifact
    )
    return [ordered]@{
        label               = $Label
        argv                = @($Argv)
        exit_code           = $ExitCode
        timestamp_utc       = $TimestampUtc
        capture_semantics   = 'combined'
        containing_artifact = $(if ($ContainingArtifact) { $ContainingArtifact -replace '\\', '/' } else { $null })
        stdout              = $null
        stderr              = $null
        combined_output     = (Get-K8TextStreamDescriptor -Text $CombinedOutput)
        artifacts           = $null
        capture_note        = $script:K8CaptureNote
    }
}

function Get-K8CommandObservationPath {
    <# The structured sidecar for a retained command-observation artifact.
       A `.observation.json` beside the existing `.txt`: the frozen-required
       and already-established text artifacts are untouched, and NO new `.txt`
       is introduced. #>
    param([Parameter(Mandatory)][string] $ArtifactRelativePath)
    return ([System.IO.Path]::ChangeExtension($ArtifactRelativePath, $null).TrimEnd('.') + $script:K8ObservationSuffix)
}

function Write-K8CommandObservation {
    <#
        Writes the structured half of a retained command observation.

        Both halves come from ONE capture instance: this never re-parses the
        `.txt` to reconstruct what happened, and nothing downstream derives
        scientific meaning from this file. If either half cannot be written
        the stage fails -- a run must not proceed with half an observation.
    #>
    param(
        [Parameter(Mandatory)][string] $RunEvidence,
        [Parameter(Mandatory)][string] $ArtifactRelativePath,
        [Parameter(Mandatory)][string] $Producer,
        [Parameter(Mandatory)][string] $Stage,
        [Parameter(Mandatory)][string] $Range,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][object[]] $Observations,
        # Only for a producer whose single command owns SEVERAL retained
        # artifacts (Range C's validator writes stdout and stderr as two
        # files): one observation record covers the invocation, so its name is
        # given explicitly rather than derived from one of the two artifacts.
        [string] $ObservationRelativePath
    )
    $record = [ordered]@{
        schema             = $script:K8CommandObservationSchema
        run_id             = $RunId
        range              = $Range
        producer           = $Producer
        stage              = $Stage
        artifact           = ($ArtifactRelativePath -replace '\\', '/')
        observation_count  = @($Observations).Count
        observations       = @($Observations)
    }
    $relative = $(if ($ObservationRelativePath) { $ObservationRelativePath } else { Get-K8CommandObservationPath -ArtifactRelativePath $ArtifactRelativePath })
    $target = Join-Path $RunEvidence $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    ($record | ConvertTo-Json -Depth 12) + "`n" | Set-Content -LiteralPath $target -Encoding utf8NoBOM
    return $record
}

# ---------------------------------------------------------------------------
# C-6: ONE required-artifact contract
#
# `Test-K8ScoringInputArtifactCompleteness` used to carry the only list, and
# it ran once, at the very end. Two consequences: a missing artifact was
# reported far from the stage that should have produced it, and any stage-
# level check would have had to restate the list -- two lists that drift.
#
# So the contract is a single data structure with the producer stage on each
# row. The per-stage gate SELECTS from it; the final gate reads ALL of it.
# There is no second list anywhere.
#
# `required` is presence-only. A file being present is never asserted to make
# its CONTENT correct -- that is what the frozen validators and, ultimately,
# the operator's own transcription are for. Legitimate absence is never
# expressed by leaving an artifact out: it is recorded IN the artifact via
# C-5's `absence_admissible`, so "we observed nothing, admissibly" and "we
# retained nothing" stay distinguishable.
# ---------------------------------------------------------------------------

$script:K8ArtifactContract = @(
    # -- run identity, all three ranges -------------------------------------
    # A/B mirror provenance immediately after the frozen evidence_tree.create();
    # Range C has no create() call, so it gets its own explicit evidence-init
    # stage that does the same thing at the same point in its own lifecycle.
    # Two rows rather than one row with a per-range exception: each row then
    # states a real writer timing.
    @{ artifact = 'run-provenance.json'; ranges = 'ab'; stage = 'evidence-tree'; required = $true }
    @{ artifact = 'run-provenance.json'; ranges = 'c';  stage = 'evidence-init'; required = $true }

    # -- Range A/B primary artifacts (README SS5/SS6.2) ---------------------
    @{ artifact = 'environment\image-inventory.json'; ranges = 'ab'; stage = 'image-inventory'; required = $true }
    @{ artifact = 'contract-output\gateway-interface-resolution.txt'; ranges = 'ab'; stage = 'gateway-resolution'; required = $true }
    @{ artifact = 'contract-output\runtime-contract-record.md'; ranges = 'ab'; stage = 'runtime-contract-record'; required = $true }
    @{ artifact = 'ground-truth\independent-capture\capture-context.json'; ranges = 'ab'; stage = 'capture-start'; required = $true }
    @{ artifact = 'sensor-input\mirror-capture\capture-context.json'; ranges = 'ab'; stage = 'capture-start'; required = $true }
    @{ artifact = 'ground-truth\sender-record.txt'; ranges = 'ab'; stage = 'sender-trigger'; required = $true }
    @{ artifact = 'ground-truth\procedure-conformance.json'; ranges = 'ab'; stage = 'sender-trigger'; required = $true }
    @{ artifact = 'metadata-t0.txt'; ranges = 'ab'; stage = 'sender-trigger'; required = $true }
    @{ artifact = 'ground-truth\independent-capture\c2-original-path.pcap'; ranges = 'ab'; stage = 'capture-stop-export'; required = $true }
    @{ artifact = 'ground-truth\independent-capture\capture-lifecycle.json'; ranges = 'ab'; stage = 'capture-stop-export'; required = $true }
    @{ artifact = 'sensor-input\mirror-capture\c2-mirror-sensor.pcap'; ranges = 'ab'; stage = 'capture-stop-export'; required = $true }
    @{ artifact = 'sensor-input\mirror-capture\capture-lifecycle.json'; ranges = 'ab'; stage = 'capture-stop-export'; required = $true }
    @{ artifact = 'ground-truth\independent-capture\decoded-verification.json'; ranges = 'ab'; stage = 'target-decode'; required = $true }
    @{ artifact = 'sensor-input\mirror-capture\decoded-verification.json'; ranges = 'ab'; stage = 'target-decode'; required = $true }
    @{ artifact = 'environment\collector-query.json'; ranges = 'ab'; stage = 'queries'; required = $true }
    @{ artifact = 'environment\rule-query.json'; ranges = 'ab'; stage = 'queries'; required = $true }
    @{ artifact = 'collector-output\collector-response.json'; ranges = 'ab'; stage = 'queries'; required = $true }
    @{ artifact = 'collector-output\collector-index-mapping.json'; ranges = 'ab'; stage = 'queries'; required = $true }
    @{ artifact = 'collector-output\collector-selector-mapping-gate.json'; ranges = 'ab'; stage = 'queries'; required = $true }
    @{ artifact = 'collector-output\accepted-collector-hit-ids.json'; ranges = 'ab'; stage = 'queries'; required = $true }
    @{ artifact = 'rule-output\rule-response.json'; ranges = 'ab'; stage = 'queries'; required = $true }
    @{ artifact = 'rule-output\rule-index-mapping.json'; ranges = 'ab'; stage = 'queries'; required = $true }
    @{ artifact = 'rule-output\rule-selector-mapping-gate.json'; ranges = 'ab'; stage = 'queries'; required = $true }
    @{ artifact = 'rule-output\collector-rule-correlation.json'; ranges = 'ab'; stage = 'queries'; required = $true }
    @{ artifact = 'metadata.md'; ranges = 'ab'; stage = 'run-metadata'; required = $true }
    @{ artifact = 'deviations.md'; ranges = 'ab'; stage = 'run-metadata'; required = $true }

    # -- Range B: the frozen fault boundary (c2-dnp3-range-derivation.md SS3)
    # Each observation artifact now carries a C-4 structured sidecar produced
    # from the same capture instance.
    @{ artifact = 'contract-output\qdisc-pre-fault.txt'; ranges = 'b'; stage = 'fault-injection'; required = $true }
    @{ artifact = 'contract-output\qdisc-pre-fault.observation.json'; ranges = 'b'; stage = 'fault-injection'; required = $true }
    @{ artifact = 'contract-output\fault-injection-command.txt'; ranges = 'b'; stage = 'fault-injection'; required = $true }
    @{ artifact = 'contract-output\fault-injection-command.observation.json'; ranges = 'b'; stage = 'fault-injection'; required = $true }
    @{ artifact = 'contract-output\qdisc-post-fault.txt'; ranges = 'b'; stage = 'fault-injection'; required = $true }
    @{ artifact = 'contract-output\qdisc-post-fault.observation.json'; ranges = 'b'; stage = 'fault-injection'; required = $true }
    @{ artifact = 'contract-output\unrelated-mirror-filters.txt'; ranges = 'b'; stage = 'fault-injection'; required = $true }
    @{ artifact = 'contract-output\unrelated-mirror-filters.observation.json'; ranges = 'b'; stage = 'fault-injection'; required = $true }

    # -- Range B: R-OBS-05 (k6-r-obs-05-collector-query-contract.md SS4/SS5) --
    @{ artifact = 'contract-output\r-obs-05-liveness.pcap'; ranges = 'b'; stage = 'capture-stop-export'; required = $true }
    @{ artifact = 'contract-output\r-obs-05-capture-lifecycle.json'; ranges = 'b'; stage = 'capture-stop-export'; required = $true }
    @{ artifact = 'environment\r-obs-05-query.json'; ranges = 'b'; stage = 'queries'; required = $true }
    @{ artifact = 'contract-output\r-obs-05-mapping-response.json'; ranges = 'b'; stage = 'queries'; required = $true }
    @{ artifact = 'contract-output\r-obs-05-mapping-gate.json'; ranges = 'b'; stage = 'queries'; required = $true }
    @{ artifact = 'contract-output\r-obs-05-response.json'; ranges = 'b'; stage = 'queries'; required = $true }
    @{ artifact = 'contract-output\r-obs-05-contract-reference.txt'; ranges = 'b'; stage = 'queries'; required = $true }
    @{ artifact = 'contract-output\r-obs-05-pcap-rows.json'; ranges = 'b'; stage = 'queries'; required = $true }
    @{ artifact = 'contract-output\r-obs-05-liveness-decode.txt'; ranges = 'b'; stage = 'queries'; required = $true }
    @{ artifact = 'contract-output\r-obs-05-correlation.json'; ranges = 'b'; stage = 'queries'; required = $true }

    # -- Range C: Shakedown SS5.3 execution-retention completeness ONLY -------
    # This is NOT a claim that the run satisfies the frozen evidence-schema.md
    # static-validation package shape (`static-validations/`); it does not, and
    # nothing here asserts otherwise.
    #
    # The retain STAGES follow the real execution order. The negative manifest
    # only becomes negative when `git apply` succeeds in patch-apply -- at the
    # end of manifest-derivation the file is still a byte copy of the BASE
    # manifest, so retaining it there would preserve bytes the validator never
    # read.
    @{ artifact = 'range-c-derived.patch'; ranges = 'c'; stage = 'manifest-derivation'; required = $true }
    @{ artifact = 'power-grid-reference.range-c-negative.yaml'; ranges = 'c'; stage = 'patch-apply'; required = $true }
    @{ artifact = 'validate.stdout.txt'; ranges = 'c'; stage = 'validator-run'; required = $true }
    @{ artifact = 'validate.stderr.txt'; ranges = 'c'; stage = 'validator-run'; required = $true }
    @{ artifact = 'validate.observation.json'; ranges = 'c'; stage = 'validator-run'; required = $true }
    @{ artifact = 'metadata.md'; ranges = 'c'; stage = 'retention'; required = $true }
)

function Get-K8ArtifactContract { $script:K8ArtifactContract }

function Get-K8ContractArtifacts {
    <# The ONE selector. Both the per-stage gate and the final gate go through
       it, so neither can be checking a different list from the other. #>
    param(
        [Parameter(Mandatory)][ValidateSet('a', 'b', 'c')][string] $Range,
        [string] $Stage
    )
    return @($script:K8ArtifactContract | Where-Object {
        $_.ranges.Contains($Range) -and $_.required -and
        ($null -eq $Stage -or '' -eq $Stage -or $_.stage -eq $Stage)
    })
}

function Assert-K8StageArtifacts {
    <#
        The stage-boundary gate: everything this stage promised to produce
        must exist NOW, before the next stage begins. Fails closed at the
        stage that owns the artifact, not several stages later where the
        diagnostic no longer names a producer.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('a', 'b', 'c')][string] $Range,
        [Parameter(Mandatory)][string] $Stage,
        [Parameter(Mandatory)][string] $RunEvidence
    )
    $rows = Get-K8ContractArtifacts -Range $Range -Stage $Stage
    if ($rows.Count -eq 0) { return }
    $missing = @($rows | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RunEvidence $_.artifact)) } | ForEach-Object { $_.artifact })
    if ($missing.Count -gt 0) {
        throw "Stage completeness gate FAILED at stage '$Stage' (Range $($Range.ToUpper())): $($missing.Count) artifact(s) this stage is responsible for do not exist: $($missing -join ', '). The run stops here rather than at a later stage that did not produce them."
    }
    Write-K8ShakedownLog -Message "stage '$Stage' completeness: $($rows.Count) contracted artifact(s) present."
}

function Assert-K8RunArtifactCompleteness {
    <#
        The final gate. Defense in depth over the per-stage gates, reading the
        SAME contract: if it ever reports something the stage gates let past,
        that is a regression defect in the stage gates, not a new requirement
        discovered late.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('a', 'b', 'c')][string] $Range,
        [Parameter(Mandatory)][string] $RunEvidence
    )
    $rows = Get-K8ContractArtifacts -Range $Range
    $missing = @($rows | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RunEvidence $_.artifact)) })
    if ($missing.Count -gt 0) {
        $detail = ($missing | ForEach-Object { "$($_.artifact) (owed by stage '$($_.stage)')" }) -join ', '
        throw "Run artifact completeness gate FAILED for Range $($Range.ToUpper()) -- missing $($missing.Count) required artifact(s): $detail. Any artifact listed here whose producer stage already completed means that stage's own gate did not hold; treat it as a regression defect in the stage gate, not as a late discovery."
    }
    Write-K8ShakedownLog -Message "Run artifact completeness gate PASS: all $($rows.Count) contracted artifact(s) present for Range $($Range.ToUpper())."
}

# ---------------------------------------------------------------------------
# C-7: typed narrative references
#
# The defect class: a machine-generated narrative names an artifact, and
# nothing ever checks that the artifact is there. The fix is NOT to scan
# prose for path-shaped substrings -- that produced four false positives on a
# healthy run when measured -- but to require every reference to arrive as a
# TYPED value that says what kind of thing it points at.
#
# Only `run-local` and `frozen-protocol-doc` are existence-checked. An
# in-container path and a host path are not resolvable from here and are
# recorded as-is; an unknown kind fails closed rather than being waved
# through.
#
# The evidence tree's own eight schema DIRECTORIES are deliberately outside
# this: they are created by the frozen evidence_tree.create() and their
# presence is already required by the frozen validate-evidence, so a
# navigational sentence naming them is not an unverified artifact reference.
# ---------------------------------------------------------------------------

function New-K8ArtifactReference {
    param(
        [Parameter(Mandatory)][ValidateSet('run-local', 'frozen-protocol-doc', 'in-container', 'host-path')][string] $Kind,
        [Parameter(Mandatory)][string] $Path
    )
    return [pscustomobject]@{ Kind = $Kind; Path = $Path }
}

function Resolve-K8NarrativeReference {
    <#
        Validates one typed reference and returns the text the narrative may
        insert. Fails closed; never repairs a bad path and never searches for
        a near match.
    #>
    param(
        [Parameter(Mandatory)] $Reference,
        [Parameter(Mandatory)][string] $RunEvidence,
        [string] $RepoRoot
    )
    $kind = [string]$Reference.Kind
    $path = [string]$Reference.Path
    switch ($kind) {
        'run-local' {
            $normalized = ($path -replace '\\', '/').Trim()
            if ($normalized.StartsWith('/') -or ($normalized.Length -gt 1 -and $normalized[1] -eq ':')) {
                throw "C-7 narrative reference: run-local path '$path' must be run-relative, not absolute."
            }
            if (@($normalized.Split('/')) -contains '..') {
                throw "C-7 narrative reference: run-local path '$path' escapes the run evidence root."
            }
            $full = Join-Path $RunEvidence ($normalized -replace '/', '\')
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                throw "C-7 narrative reference: run-local artifact '$normalized' does not exist under $RunEvidence. A generated narrative must not cite an artifact that is not there."
            }
            return $normalized
        }
        'frozen-protocol-doc' {
            if (-not $RepoRoot) { throw "C-7 narrative reference: a frozen-protocol-doc reference needs -RepoRoot to resolve '$path'." }
            $normalized = ($path -replace '\\', '/').Trim()
            $allowed = @($script:K8FrozenProtocolDocPrefixes | Where-Object { $normalized -eq $_ -or $normalized.StartsWith($_) })
            if ($allowed.Count -eq 0) {
                throw "C-7 narrative reference: '$normalized' is not inside the frozen-protocol-doc allowlist ($($script:K8FrozenProtocolDocPrefixes -join ', ')). Widening the allowlist is a Plan revision, not a code change."
            }
            $full = Join-Path $RepoRoot ($normalized -replace '/', '\')
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                throw "C-7 narrative reference: frozen protocol document '$normalized' does not exist under $RepoRoot."
            }
            return $normalized
        }
        # Not resolvable from the host running this: a container filesystem
        # path, or a path outside the evidence tree. Recorded verbatim.
        'in-container' { return $path }
        'host-path'    { return $path }
        default { throw "C-7 narrative reference: unknown reference kind '$kind'." }
    }
}

function Get-K8NarrativeReferenceText {
    <# Convenience for narrative writers: resolve several references at once
       and get back the display strings, in order. #>
    param(
        [Parameter(Mandatory)][object[]] $References,
        [Parameter(Mandatory)][string] $RunEvidence,
        [string] $RepoRoot
    )
    return @($References | ForEach-Object { Resolve-K8NarrativeReference -Reference $_ -RunEvidence $RunEvidence -RepoRoot $RepoRoot })
}

function Get-K8RunIdentityFacts {
    <#
        C7-R4: run identity is drawn from the authoritative structured source
        -- the Batch 1 run-provenance record -- not retyped into prose from a
        local variable. Different fact classes have different authoritative
        sources (command facts come from the C-4 observation, observer facts
        from the C-5 record, pinned constants from the canonical constants);
        the shared rule is that no mechanical value is written freehand.
    #>
    param([Parameter(Mandatory)][string] $RunId)
    $path = Get-K8RunProvenancePath -RunId $RunId
    if (-not (Test-Path -LiteralPath $path)) { throw "run identity facts unavailable: no run-provenance record at $path." }
    $prov = (Get-Content -LiteralPath $path -Raw) | ConvertFrom-Json -AsHashtable
    return [pscustomobject]@{
        RunId       = [string]$prov['run_id']
        Range       = [string]$prov['range']
        SequenceId  = [string]$prov['sequence_id']
        ToolingHead = [string]$prov['tooling_head']
        LockedHead  = [string]$prov['sequence_locked_head']
        StartedUtc  = [string]$prov['started_utc']
    }
}

function Get-K8FinalizeIdentityPath {
    param([Parameter(Mandatory)][string] $RunId)
    Join-Path (Get-K8RunRecordDir -RunId $RunId) 'finalize-identity.json'
}

function Write-K8FinalizeIdentitySnapshot {
    <#
        Pins WHICH integrity manifest actually passed verify-integrity.

        Why this is needed at all: the frozen finalize-evidence regenerates
        hashes.sha256 from whatever the tree currently holds. So "this artifact
        is listed in hashes.sha256" cannot, on its own, distinguish evidence
        that was retained during the run from a file added afterwards and then
        re-manifested. Snapshotting the finalized manifest's own digest into
        the control plane closes that: C-3 can then check "was in the FINALIZED
        manifest", not merely "is in today's manifest".

        ORDERING IS THE POINT. This is written only after final-verify has
        SUCCEEDED, and before the sequence is advanced:

            evidence finalization -> integrity verification
                                  -> identity freeze -> run completion

        A manifest that finalize produced but verify-integrity rejected must
        never be snapshotted as a verified one.

        Control plane only. Nothing is written into the evidence tree here: a
        file added after finalize-evidence would leave that tree permanently
        inconsistent with its own manifest.
    #>
    param(
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)][string] $RunEvidence
    )
    $manifest = Join-Path $RunEvidence 'hashes.sha256'
    if (-not (Test-Path -LiteralPath $manifest)) {
        throw "finalize identity snapshot: hashes.sha256 not found at $manifest after final-verify reported success."
    }
    $record = [ordered]@{
        schema               = $script:K8FinalizeIdentitySchema
        run_id               = $Run.RunId
        sequence_id          = $Run.SequenceId
        tooling_head         = $Run.ToolingHead
        finalized_utc        = (Get-K8UtcNow)
        run_evidence         = $RunEvidence
        hashes_sha256_digest = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
        verified             = 'final-verify (study01_collect.py verify-integrity) succeeded before this snapshot was written'
    }
    Write-K8AtomicFile -Path (Get-K8FinalizeIdentityPath -RunId $Run.RunId) -Content (($record | ConvertTo-Json -Depth 8) + "`n")
    Write-K8ShakedownLog -Message "finalize identity snapshot retained for $($Run.RunId): hashes.sha256 = $($record['hashes_sha256_digest'])."
    return $record
}

function Write-K8ScoringInputTemplate {
    <#
        Emits the C-3 template into the CONTROL PLANE (never the evidence
        tree: it is written after finalize-evidence, and a new file in the
        tree would break verify-integrity for the rest of the run's life).

        The template is intentionally not scorable and intentionally not
        valid: every judgment slot holds a placeholder, so the tooling cannot
        be read as having chosen a default. Filling it in is the operator's
        work, and README SS6.2 still reserves the judgment.
    #>
    param(
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)][ValidateSet('a', 'b')][string] $Range
    )
    $target = Join-Path (Get-K8RunRecordDir -RunId $Run.RunId) 'scoring-input.template.json'
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @(
        (Join-Path $PSScriptRoot 'k8_scoring_input_contract.py'), 'emit-template',
        '--range', $Range, '--output', $target
    ) -Description 'emit the C-3 scoring-input template (intentionally incomplete)' | Out-Null
    return $target
}

function New-K8CommandFailure {
    <#
        Builds the exception for a genuine external/native-command failure and
        attaches the command context TO THE EXCEPTION INSTANCE ITSELF
        (Exception.Data), so the run boundary reads it from the error it is
        actually handling.

        No module-global "last failure" slot: that would need reference-equality
        bookkeeping to avoid grafting a stale, already-tolerated command failure
        onto a later unrelated internal throw, and would break under nested
        catch/rethrow.

        Only call this where a real argv AND a real exit code are in hand.
        Everything else is a non-command termination and must stay that way --
        SD-05 (missing artifact), SD-12 (ValueError on an HTTP 200 body), SD-13
        (zero-row decode) and SD-14 (completeness gate) had no command to
        describe, and inventing one would misrepresent them.
    #>
    param(
        [Parameter(Mandatory)][string[]] $Argv,
        [Parameter(Mandatory)][int] $ExitCode,
        [Parameter(Mandatory)][string] $Message,
        [AllowEmptyString()][string] $Stdout,
        [AllowEmptyString()][string] $Stderr,
        [AllowEmptyString()][string] $CombinedOutput,
        [switch] $StreamsSeparated,
        [string] $LogPath
    )
    $ex = New-Object System.Management.Automation.RuntimeException($Message)
    $ex.Data['k8_command_context'] = @{
        Argv             = @($Argv)
        ExitCode         = $ExitCode
        StreamsSeparated = [bool]$StreamsSeparated
        Stdout           = $Stdout
        Stderr           = $Stderr
        CombinedOutput   = $CombinedOutput
        LogPath          = $LogPath
    }
    return $ex
}

function Get-K8CommandFailureContext {
    <# Walks the InnerException chain of the error being handled. Nothing else
       is consulted, so an unrelated earlier failure can never be attributed. #>
    param([Parameter(Mandatory)] $Exception)
    $probe = $Exception
    while ($null -ne $probe) {
        if ($null -ne $probe.Data -and $probe.Data.Contains('k8_command_context')) { return $probe.Data['k8_command_context'] }
        $probe = $probe.InnerException
    }
    return $null
}

function Save-K8CapturedStream {
    <#
        Retains the FULL transcript this tooling captured, never truncated, and
        returns a descriptor for the JSON record. The `preview` is a reading
        convenience; the file is the retention.

        bytes/sha256 describe the retained capture FILE. For the merged-capture
        helpers PowerShell has already decoded the stream into text, so this is
        not a claim about the native process's original bytes -- see
        capture_note in the record.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $Name,
        [AllowNull()][AllowEmptyString()][string] $Text
    )
    $body = $(if ($null -eq $Text) { '' } else { $Text })
    $path = Join-Path (Get-K8RunRecordDir -RunId $RunId) $Name
    Write-K8AtomicFile -Path $path -Content $body
    $preview = $(if ($body.Length -gt $script:K8TerminationPreviewChars) { $body.Substring(0, $script:K8TerminationPreviewChars) } else { $body })
    return [ordered]@{
        path              = $Name
        bytes             = (Get-Item -LiteralPath $path).Length
        sha256            = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        preview           = $preview
        preview_truncated = ($preview.Length -lt $body.Length)
    }
}

function Write-K8TerminationRecord {
    <#
        The authoritative record of where and why a run stopped. Written to the
        CONTROL PLANE only -- run-records/<run_id>/termination.json -- and never
        into the run evidence tree, because a file added after finalize-evidence
        would leave that tree permanently inconsistent with its own manifest.

        failure_kind is a deliberately two-valued vocabulary:
        external-command / non-command. No taxonomy is guessed from the
        exception text; exception.type and stage carry the detail as fact. A
        non-command termination has command = null, with no argv or exit_code
        key present anywhere in the record.
    #>
    param([Parameter(Mandatory)] $ErrorRecord)
    $run = $script:K8CurrentRun
    if ($null -eq $run) { return $null }
    $runId = $run.RunId
    New-Item -ItemType Directory -Force -Path (Get-K8RunRecordDir -RunId $runId) | Out-Null

    $ex = $ErrorRecord.Exception
    $ctx = Get-K8CommandFailureContext -Exception $ex

    $command = $null
    if ($null -ne $ctx) {
        $command = [ordered]@{
            argv              = @($ctx.Argv)
            exit_code         = $ctx.ExitCode
            streams_separated = [bool]$ctx.StreamsSeparated
            capture_note      = $script:K8CaptureNote
            stdout            = $null
            stderr            = $null
            combined_output   = $null
            log_path          = $ctx.LogPath
        }
        if ($ctx.StreamsSeparated) {
            $command['stdout'] = Save-K8CapturedStream -RunId $runId -Name 'command-stdout.txt' -Text $ctx.Stdout
            $command['stderr'] = Save-K8CapturedStream -RunId $runId -Name 'command-stderr.txt' -Text $ctx.Stderr
        }
        else {
            # Merged at capture time: it is a combined transcript and is named
            # as one. Calling it stdout would misdescribe the observation.
            $command['combined_output'] = Save-K8CapturedStream -RunId $runId -Name 'command-combined.txt' -Text $ctx.CombinedOutput
        }
    }

    $record = [ordered]@{
        schema       = $script:K8TerminationSchema
        run_id       = $runId
        sequence_id  = $run.SequenceId
        tooling_head = $run.ToolingHead
        stage        = $run.Stage
        failure_kind = $(if ($null -ne $ctx) { 'external-command' } else { 'non-command' })
        timestamp    = (Get-K8UtcNow)
        message      = $ex.Message
        exception    = [ordered]@{
            type               = $ex.GetType().FullName
            message            = $ex.Message
            script_stack_trace = "$($ErrorRecord.ScriptStackTrace)"
        }
        command      = $command
    }
    Write-K8AtomicFile -Path (Get-K8TerminationRecordPath -RunId $runId) -Content (($record | ConvertTo-Json -Depth 12) + "`n")
    Write-K8ShakedownLog -Level ERROR -Message "termination record retained for $runId at stage '$($run.Stage)' (failure_kind=$($record['failure_kind']))."
    return $record
}

function Set-K8SequenceIneligible {
    <# Second half of the termination transaction. The record on disk is
       authoritative and is written first; if this half fails, the control plane
       recognises the partial state and permits only completing it or closing
       the sequence. #>
    param([Parameter(Mandatory)] $Run)
    Invoke-K8SequenceMutation -Operation 'RecordTermination' -RunId $Run.RunId -Body {
        param($State)
        $s = @($State.Live)[0]
        $s['status'] = 'ineligible'
        $s['ineligible_reason'] = "run $($Run.RunId) terminated at stage '$($Run.Stage)'"
        Write-K8SequenceRecord -Record $s
    }.GetNewClosure() | Out-Null
}

function Complete-K8ShakedownRunInSequence {
    <#
        Advances the sequence after a run genuinely completed. Refuses -- always,
        independently of the transition gate -- to complete a run that has an
        authoritative termination record.

        The final Range C advance sets status=complete only for an UNINTERRUPTED
        [a, b, c] at one locked HEAD, and stamps completion_claim to say exactly
        that much. It is NOT a K8-S2 authorization.
    #>
    param([Parameter(Mandatory)] $Run)
    return Invoke-K8SequenceMutation -Operation 'CompleteRun' -RunId $Run.RunId -Body {
        param($State)
        $s = @($State.Live)[0]
        $active = $s['active_run']
        if (Test-K8ActiveRunHasTermination -ActiveRun $active) {
            throw "Refusing to complete run $($Run.RunId): it has an authoritative termination record. A terminated run is never promoted to completed."
        }
        $range = [string]$active['range']
        $s['completed_runs'] = @(@($s['completed_runs']) + , ([ordered]@{
            range         = $range
            run_id        = [string]$active['run_id']
            completed_utc = (Get-K8UtcNow)
        }))
        $s['active_run'] = $null
        $s['next_range'] = $(switch ($range) { 'a' { 'b' } 'b' { 'c' } default { $null } })
        if ($null -eq $s['next_range']) {
            $completedRanges = @(@($s['completed_runs']) | ForEach-Object { [string]$_['range'] })
            if (@($s['terminated_runs']).Count -ne 0) {
                throw "Sequence $([string]$s['sequence_id']) completed Range C but carries $(@($s['terminated_runs']).Count) terminated run(s); it is not an uninterrupted A -> B -> C and must not be marked complete."
            }
            if (($completedRanges -join ',') -ne 'a,b,c') {
                throw "Sequence $([string]$s['sequence_id']) completed Range C but its completed runs are [$($completedRanges -join ', ')], not a, b, c in order."
            }
            $s['completion_claim'] = 'c-2b-sequence-valid'
            Complete-K8SequenceTerminalTransition -Record $s -Status 'complete'
            Write-K8ShakedownLog -Level STEP -Message "sequence $([string]$s['sequence_id']) is c-2b-sequence-valid (uninterrupted A -> B -> C at $([string]$s['locked_head'])). This is NOT a K8-S2 authorization."
        }
        else {
            Write-K8SequenceRecord -Record $s
        }
        ConvertTo-K8CanonicalSequenceRecord -Record $s
    }.GetNewClosure()
}

function Assert-K8RunSequenceInvariant {
    <#
        The whole-run invariant, enforced again at the start of a run's second
        phase. A run must not have its phase 1 and phase 2 executed at different
        tooling HEADs -- that is the same across-HEADs hazard C-2b exists for.
    #>
    param([Parameter(Mandatory)] $Run)
    Assert-K8SequenceBinding -Run $Run
    $seq = Get-K8QualificationSequence
    $active = $seq['active_run']
    if ($null -eq $active) { throw "Sequence $([string]$seq['sequence_id']) has no active run; $($Run.RunId) cannot be completed." }
    if ([string]$active['run_id'] -ne $Run.RunId) { throw "Sequence $([string]$seq['sequence_id']) has active run $([string]$active['run_id']), not $($Run.RunId)." }
    if ([string]$active['state'] -ne 'running') { throw "Run $($Run.RunId) is in state '$([string]$active['state'])', not 'running'." }
    if (Test-K8ActiveRunHasTermination -ActiveRun $active) { throw "Run $($Run.RunId) already has an authoritative termination record and cannot be completed." }
}

function Invoke-K8ShakedownRunBoundary {
    <#
        Top-level execution boundary. Every failure inside a run is caught HERE,
        recorded against the run ID and provenance already issued, and then
        re-thrown unchanged -- writing a record never converts a failure into a
        success.

        Both record-writing steps are individually guarded so that a failure to
        record can never destroy the original failure reason.
    #>
    param([Parameter(Mandatory)] $Run, [Parameter(Mandatory)][scriptblock] $ScriptBlock)
    try {
        & $ScriptBlock
    }
    catch {
        $original = $_
        try { Write-K8TerminationRecord -ErrorRecord $original | Out-Null }
        catch { Write-K8ShakedownLog -Level ERROR -Message "FAILED to write the termination record ($($_.Exception.Message)). The original failure is re-thrown below and is NOT lost." }
        try { Set-K8SequenceIneligible -Run $Run }
        catch { Write-K8ShakedownLog -Level ERROR -Message "FAILED to mark the sequence ineligible ($($_.Exception.Message)). The termination record on disk is authoritative; recover with .\tools\Close-K8QualificationSequence.ps1." }
        throw $original
    }
}

# ---------------------------------------------------------------------------
# Fail-closed helpers -- these throw rather than "fixing" anything, per the
# Shakedown rule: the runner records and stops, it does not repair.
# ---------------------------------------------------------------------------

function Invoke-K8ShakedownCommand {
    <#
        Runs an external command, logs its argv/exit code, and throws on a
        non-zero exit unless -AllowExitCodes lists it. Never retries and never
        substitutes a different command on failure.
    #>
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [string[]] $ArgumentList = @(),
        [int[]] $AllowExitCodes = @(0),
        [string] $Description = ''
    )
    $argvDisplay = ($ArgumentList | ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }) -join ' '
    Write-K8ShakedownLog -Level STEP -Message "RUN: $FilePath $argvDisplay $(if ($Description) { "  # $Description" })"
    # Assign directly rather than Tee-Object -Variable: Tee-Object never
    # creates its target variable when the pipeline emits zero objects (a
    # silent command, e.g. `git remote add`), which under Set-StrictMode
    # threw "the variable '$output' cannot be retrieved" -- found by an
    # actual dry run of this script, not assumed.
    $output = @(& $FilePath @ArgumentList 2>&1)
    $exit = $LASTEXITCODE
    $output | ForEach-Object { Write-K8ShakedownLog -Message "  | $_" }
    Write-K8ShakedownLog -Message "EXIT: $exit"
    if ($AllowExitCodes -notcontains $exit) {
        # This capture is `2>&1`, so what it holds is a COMBINED transcript.
        # It is recorded as combined_output, never as stdout.
        throw (New-K8CommandFailure `
            -Argv (@($FilePath) + @($ArgumentList)) -ExitCode $exit `
            -CombinedOutput ((@($output) | ForEach-Object { "$_" }) -join "`n") `
            -Message "Command failed (exit $exit, expected one of $($AllowExitCodes -join ',')): $FilePath $argvDisplay")
    }
    return [pscustomobject]@{ ExitCode = $exit; Output = $output }
}

function Invoke-K8SeparatedNativeCapture {
    <#
        Runs a native command with STDOUT and STDERR captured into SEPARATE
        values -- never merged via `2>&1` -- for exactly one purpose: this
        module parsing that command's stdout as machine-readable data (JSON,
        TSV, a bare container ID/SHA/HTTP status).

        Root cause this exists to fix (independent review, real VM run
        k8shakedown-rangea-20260829-033618): `docker exec ... tshark ...
        2>&1` merged tshark's own "Running as user root and group root.
        This could be dangerous." stderr warning into the captured stdout,
        which the caller then tried to parse as a 9-column TSV row and
        threw "unexpected tshark row shape." This was a Shakedown parser
        defect, not a scientific finding, and the fix is structural stream
        separation -- NOT a hardcoded exclusion of that one warning string,
        which would only mask the next tool's next unrelated stderr line.

        Cross-audited (same review round) for the same defect class across
        every OTHER call site in this module that parses stdout as
        structured data (JSON via ConvertFrom-Json, an exact single-value
        match, a fixed-column TSV row) and fixed at each -- see this
        function's callers. Call sites that only ever retain output as a
        raw text log for human review (never parsed for a machine
        decision) were deliberately left on `2>&1`, since merging stderr
        into a HUMAN-READ transcript is correct, not a defect.

        Exit code is always the real native exit code (never swallowed);
        stderr is always returned so a caller can put it in a fail-closed
        diagnostic rather than discarding it.
    #>
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [string[]] $ArgumentList = @()
    )
    $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-stderr-" + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        $stdout = @(& $FilePath @ArgumentList 2>$stderrFile)
        $exitCode = $LASTEXITCODE
        $stderr = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw } else { '' }
    }
    finally {
        Remove-Item $stderrFile -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ Stdout = $stdout; Stderr = $(if ($stderr) { $stderr } else { '' }); ExitCode = $exitCode }
}

function ConvertTo-K8PythonExecOneLiner {
    <#
        Flattens a multi-line `python3 -c` script into a single logical line
        with no embedded newline byte, by wrapping it in exec('...') and
        replacing real newlines with Python's own `\n` string escape (which
        exec()'s string literal decodes back into a real newline when the
        code actually runs) -- the same "let the consumer's own escape
        syntax do the work, never smuggle a raw control character through an
        argv boundary" principle as the curl `-w` `\n` fix elsewhere in this
        module.

        Found necessary during this round's own regression testing: this
        module's docker mock (tests/mock-docker) is invoked through a .cmd
        batch trampoline so it resolves as a real external process (the same
        Application-type resolution as real docker.exe, not the PS1
        Script-type resolution that would run it in-process and mask stderr
        behavior). cmd.exe is a line-oriented interpreter -- a literal
        embedded newline inside a single argument corrupts its OWN
        command-line parsing before the batch file's body ever runs,
        silently truncating/splitting the argument (confirmed by direct A/B
        testing: identical args survive intact through a raw native process,
        but not through a .cmd trampoline). Real docker.exe is a native
        binary and never has this problem, but flattening the source here
        removes the dependency on a raw control character surviving several
        stacked process boundaries at all, which is worth doing regardless
        of the mock.
    #>
    param([Parameter(Mandatory)][string] $Script)
    $escaped = $Script.Replace('\', '\\').Replace("'", "\'").Replace("`r`n", "`n").Replace("`n", '\n')
    return "exec('$escaped')"
}

function Invoke-K8ShakedownLoggedCommand {
    <# Runs a noisy native command with its complete combined output redirected
       to a per-run Shakedown runtime log outside the scientific evidence tree.
       Only failures echo a bounded tail to the console. #>
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [string[]] $ArgumentList = @(),
        [Parameter(Mandatory)][string] $LogPath,
        [string] $Description = '',
        [int] $FailureTailLines = 50
    )
    $argvDisplay = ($ArgumentList | ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }) -join ' '
    $parent = Split-Path -Parent $LogPath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Write-K8ShakedownLog -Level STEP -Message "RUN: $FilePath $argvDisplay $(if ($Description) { "  # $Description" }) (full output: $LogPath)"
    # Inspect the native exit code ourselves so a host-level preference cannot
    # throw before the bounded failure-tail/reporting path runs.
    $PSNativeCommandUseErrorActionPreference = $false
    & $FilePath @ArgumentList *> $LogPath
    $exit = $LASTEXITCODE
    Write-K8ShakedownLog -Message "EXIT: $exit (full output: $LogPath)"
    if ($exit -ne 0) {
        Write-K8ShakedownLog -Level ERROR -Message "Command failed; last $FailureTailLines log lines follow:"
        Get-Content -LiteralPath $LogPath -Tail $FailureTailLines | ForEach-Object {
            Write-K8ShakedownLog -Level ERROR -Message "  | $_"
        }
        # `*>` redirected every stream into one file, so this too is a COMBINED
        # transcript. The full log is retained whole; log_path keeps the pointer
        # to the original runtime log as well.
        throw (New-K8CommandFailure `
            -Argv (@($FilePath) + @($ArgumentList)) -ExitCode $exit `
            -CombinedOutput $(if (Test-Path -LiteralPath $LogPath) { Get-Content -LiteralPath $LogPath -Raw } else { '' }) `
            -LogPath $LogPath `
            -Message "Command failed (exit $exit): $FilePath $argvDisplay. Full Shakedown runtime log: $LogPath")
    }
    return [pscustomobject]@{ ExitCode=$exit; LogPath=$LogPath }
}

function Assert-K8PinnedCommit {
    <#
        Verifies a git worktree's HEAD equals the pinned commit. Never
        auto-corrects a mismatch (no re-checkout, no "close enough") -- a
        mismatch is a STOP condition for the caller to report.
    #>
    param(
        [Parameter(Mandatory)][string] $WorktreePath,
        [Parameter(Mandatory)][string] $ExpectedCommit,
        [Parameter(Mandatory)][string] $Label
    )
    $actual = (git -C $WorktreePath rev-parse HEAD).Trim()
    if ($actual -ne $ExpectedCommit) {
        throw "$Label`: expected pinned commit $ExpectedCommit, found $actual at $WorktreePath. Not proceeding -- this is a STOP condition, not something to auto-fix."
    }
    Write-K8ShakedownLog -Message "$Label pinned-commit check PASS ($actual)"
}

# ---------------------------------------------------------------------------
# The cp932 dependency-decode fix
#
# Root cause (verified against the real pinned artifacts, not assumed):
#   - amenonuboco-v0.13.0/requirements.txt is UTF-8 text with Japanese comment
#     lines, no BOM, and no PEP263 `# coding:` declaration on either of its
#     first two lines.
#   - pip 23.0.1's requirements-file decoder (pip/_internal/utils/encoding.py,
#     auto_decode()) checks only for a BOM or a PEP263 comment; failing both,
#     it decodes straight to locale.getpreferredencoding(False) with NO UTF-8
#     attempt at all. On a Japanese-locale Windows host that is cp932, and
#     cp932 cannot decode the file's UTF-8 multi-byte sequences.
#   - Newer pip (the vendored req_file._decode_req_file added after 23.0.1)
#     tries UTF-8 first and only falls back to the locale encoding on
#     UnicodeDecodeError, which is why this does not reproduce on every pip.
#   - Setting the environment variable PYTHONUTF8=1 makes CPython's own
#     locale.getpreferredencoding(False) return 'UTF-8' regardless of pip
#     version or OS locale (verified: sys.flags.utf8_mode true => this call
#     returns 'UTF-8'), which fixes pip's decode without upgrading pip and
#     without touching Amenonuboco or its requirements.txt in any way.
#   - Reproduced and the fix confirmed end-to-end with pip 23.0.1 (the exact
#     version recorded in evidence/reproduction/k8-repro-20260828-001-v4's
#     environment.json) against the real requirements.txt bytes, on a host
#     whose default locale.getpreferredencoding(False) is itself cp932:
#     without PYTHONUTF8=1 it fails with the exact observed
#     "'cp932' codec can't decode byte 0x81 in position 39" error; with it,
#     `pip install --dry-run -r requirements.txt` resolves pydantic and PyYAML
#     cleanly.
# ---------------------------------------------------------------------------

function Install-K8RangeCDependencies {
    param([Parameter(Mandatory)][string] $RequirementsPath)
    if (-not (Test-Path $RequirementsPath)) {
        throw "Range C requirements file not found: $RequirementsPath"
    }
    $previous = $env:PYTHONUTF8
    try {
        $env:PYTHONUTF8 = '1'
        Write-K8ShakedownLog -Message "Installing Range C dependencies with PYTHONUTF8=1 (cp932 decode fix) from $RequirementsPath"
        Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @('-m', 'pip', 'install', '-r', $RequirementsPath) `
            -Description 'Range C validator dependencies (locale-safe decode)'
    }
    finally {
        if ($null -eq $previous) { Remove-Item Env:\PYTHONUTF8 -ErrorAction SilentlyContinue } else { $env:PYTHONUTF8 = $previous }
    }
}

# ---------------------------------------------------------------------------
# Range A / B shared runner
#
# Range B is, by the frozen protocol's own framing (c2-dnp3-range-derivation.md
# SS3), "the exact Range A derivation and provisioning procedure with only the
# run ID and generated output filename changed" plus exactly one added fault
# (delete the ingress qdisc on the interface carrying 10.1.20.254/24). This
# function implements both from one body so the two cannot silently drift
# apart; -Range selects which literal filename/fault behavior applies. It does
# not change what either Range does -- it mechanically sequences the same
# frozen CLI scripts (study01_preflight.py / study01_capture.py /
# study01_sender.py / study01_collect.py), the fixed Collector/Rule/R-OBS-05
# queries against Elasticsearch (mechanical: fetching a mapping, running a
# fixed query, saving the raw response, and computing a mechanical
# correlation are automated; only the SCIENTIFIC judgment of what a result
# means is left to the operator at scoring-input time), and the same literal
# docker/tc commands already written in protocol/c2-dnp3-range-derivation.md,
# c2-dnp3-capture-procedure.md, and c2-dnp3-sender-procedure.md, with the run
# ID and paths substituted instead of hand-typed.
#
# What this function deliberately does NOT do (left for the operator, because
# doing it would change the frozen protocol's own epistemic discipline):
#   - It does not write scoring-input.json. README SS6.2 requires that to be
#     transcribed by hand from evidence, derived BEFORE looking at expected/ --
#     this is limitation R6, and auto-generating it would erase the exact
#     discipline the study's own limitations analysis is about. This function
#     stops after finalize/verify-integrity and prints the exact
#     study01_score.py command to run once scoring-input.json exists.
#   - It does not decide what a Collector/Rule/R-OBS-05 result MEANS
#     scientifically (Pass/Fail/Unresolved for scoring purposes). It runs the
#     fixed query, saves the raw response, and computes the fixed mechanical
#     correlation the freeze documents themselves define; the classification
#     of that into a scored field happens by hand at README SS6.2.
#
# LEAST-VERIFIED PART OF THIS FILE: the pcap-to-document nanosecond
# correlation in k8_shakedown_evidence.py, and the tshark `-T fields` names
# used by Write-K8UnrelatedPcapRows, have never been run against a real DNP3 capture
# or a real Elasticsearch response in this development environment (no
# Docker daemon / no live stack was available while writing this). Treat
# their output as provisional until the first real VM run confirms the
# field names and precision handling against actual retained bytes -- the
# raw tshark/ES output is always retained alongside the computed result
# specifically so a human can redo the exact SS4 decimal-nanosecond
# comparison by hand if this code's approximation is ever in doubt.
#
# CROSS-SERVICE STARTUP-RACE AUDIT (independent review round 2, after the
# curl-exit-7 failure): every generator in the pinned Amenonuboco commit
# (78fc17746b5d663fafec9dffe563d79fe9ea02b7) that runs an install step
# before its real payload was enumerated by grepping
# platform/generators/*.py for apt-get/apt/pip/apk install, at that exact
# commit -- not guessed. Exactly three exist:
#   1. structuring.py (log_structurer): apt-get tshark/python3, then the
#      tshark|bulk_loader.py DNP3 pipeline -- BLOCKER, gated by
#      Wait-K8LogStructurerReady.
#   2. plugins.py (zone_detector): pip install <requires>, then the
#      signal-1-zone-violation plugin -- BLOCKER, gated by
#      Wait-K8ZoneDetectorReady.
#   3. compose.py's _INSTALL_IPROUTE2 (any non-gateway asset needing
#      `ip route add`, and wan_router itself for its own mirror/qdisc
#      setup): `(command -v ip || apt-get install iproute2 || apk add
#      iproute2)`. NOT separately gated here, and deliberately so: unlike
#      the two above, this race fails LOUDLY rather than silently. Every
#      Shakedown command against wan_router that depends on `ip`/`tc`
#      (Resolve-K8GatewayInterface, the Range B fault) already throws
#      immediately if the binary is not yet present -- e.g.
#      Resolve-K8GatewayInterface's own "found $($gatewayMatches.Count)"
#      check throws on zero matches, which is exactly what an
#      `ip: not found` stderr line inside $addrOutput produces. A loud,
#      immediate STOP is not the silent-scientific-corruption shape the
#      other two gates exist to prevent, so no additional gate was added
#      for it; this is a recorded audit conclusion, not an oversight.
# No other generator (mirroring.py, impairment.py, attack.py, shell.py,
# visualization/*) contains an install-then-exec pattern at this pinned
# commit.
# ---------------------------------------------------------------------------

function Get-K8ExpectedServices {
    <# The Compose file's own declared service set -- not a hardcoded list,
       so a manifest variant with more/fewer services is still checked
       correctly against itself. STDOUT/STDERR captured separately: a
       Compose deprecation notice or similar warning on stderr must not be
       merged in and mistaken for a service name. #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath
    )
    $capture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'config', '--services')
    if ($capture.ExitCode -ne 0) {
        throw "'docker compose config --services' failed for $ComposePath (exit $($capture.ExitCode)). stderr: $($capture.Stderr.Trim())"
    }
    $services = @($capture.Stdout | Where-Object { $_ -and $_.Trim() })
    if ($services.Count -eq 0) {
        throw "Could not determine the expected service set via 'compose config --services' for $ComposePath; not proceeding without knowing what 'ready' means."
    }
    return ,$services
}

function ConvertFrom-K8ConcatenatedJson {
    <#
        Splits $Raw into one or more top-level JSON values (each a balanced
        `{...}` object or `[...]` array), tracking bracket depth and string
        literal/escape state -- NOT naive newline-splitting.

        Root cause this exists to fix (real VM run k8shakedown-rangea-
        20260829-071142, independent review): the prior ConvertFrom-K8ComposePsJson
        tried `$Raw | ConvertFrom-Json` once, and on ANY failure fell back to
        `$Raw -split "`n" | ForEach-Object { ConvertFrom-Json }` with no
        further diagnostic -- a strategy that assumes Compose's `ps --all
        --format json` is always either one compact single-line array, or
        compact one-object-per-line NDJSON, and gives up with a bare WARN
        (no persisted reason) on anything else, including a single stray
        non-JSON line accidentally sharing stdout with otherwise-valid rows.
        A real VM run's environment reported 21/21 services running with the
        two declared healthchecks healthy (confirmed by an operator's manual
        recheck immediately after the failure) yet Wait-K8ComposeReady still
        exhausted its full 120s timeout -- meaning readiness was blocked by
        this module's OWN parsing, not by Docker Compose's real state, and
        the retained evidence at the time gave no way to tell which of
        "parse failed" vs "genuinely not ready" had actually happened.

        This scanner is deliberately format-agnostic: it does not care
        whether the N rows are compact-NDJSON, or the whole document is one
        pretty-printed multi-line array, or any mix of the two, because it
        never splits on newlines at all -- only on where a top-level
        value's own brackets balance back to zero. A brace/bracket
        character INSIDE a JSON string (e.g. a container's Labels or Mounts
        field containing literal `{`/`[`) is correctly ignored because
        string state is tracked with escape-awareness. Any top-level
        non-whitespace byte that is not the start of `{` or `[` (a stray
        banner/warning line landing on stdout instead of stderr, for
        example) is a hard, fail-closed parse error with an exact offset and
        surrounding snippet -- real docker/compose/network JSON output never
        contains a bare top-level scalar, so this can never silently skip
        real data, and it can never silently accept corrupt data either.

        Returns the array of still-unparsed top-level substrings; callers
        parse each with ConvertFrom-Json and flatten arrays themselves (see
        ConvertFrom-K8ComposePsJson below) -- kept separate from JSON
        parsing itself so this scanner can be unit-tested purely as a
        string-splitting algorithm.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Raw)
    $values = New-Object System.Collections.Generic.List[string]
    $depth = 0
    $inString = $false
    $escape = $false
    $start = -1
    for ($i = 0; $i -lt $Raw.Length; $i++) {
        $ch = $Raw[$i]
        if ($inString) {
            if ($escape) { $escape = $false }
            elseif ($ch -eq '\') { $escape = $true }
            elseif ($ch -eq '"') { $inString = $false }
            continue
        }
        if ($ch -eq '"') { $inString = $true; continue }
        if ($ch -eq '{' -or $ch -eq '[') {
            if ($depth -eq 0) { $start = $i }
            $depth++
            continue
        }
        if ($ch -eq '}' -or $ch -eq ']') {
            $depth--
            if ($depth -lt 0) {
                $lo = [Math]::Max(0, $i - 40); $len = [Math]::Min(80, $Raw.Length - $lo)
                throw ('unbalanced JSON at offset {0} (unexpected closing bracket): ...{1}...' -f $i, $Raw.Substring($lo, $len))
            }
            if ($depth -eq 0) {
                $values.Add($Raw.Substring($start, $i - $start + 1))
                $start = -1
            }
            continue
        }
        if ($depth -eq 0 -and -not [char]::IsWhiteSpace($ch)) {
            $lo = [Math]::Max(0, $i - 20); $len = [Math]::Min(60, $Raw.Length - $lo)
            throw ('unexpected non-JSON content at top level, offset {0}: ...{1}...' -f $i, $Raw.Substring($lo, $len))
        }
    }
    if ($inString) { throw 'unterminated string literal in JSON output' }
    if ($depth -ne 0) { throw "unbalanced JSON: $depth unclosed bracket(s) at end of input" }
    # A single comma, NOT `,@(...)`: `@()` around an already-real array does
    # not change it, but the leading comma then wraps THAT into a further
    # 1-element array-of-array -- the exact double-wrap defect class this
    # whole round is about, self-inflicted here if both were combined. See
    # ConvertFrom-K8ComposePsJson's return statement for the same fix and
    # Get-K8ExpectedServices' callers for the caller-side half of this bug.
    return ,$values.ToArray()
}

function ConvertFrom-K8ComposePsJson {
    <#
        `compose ps --format json` / `compose images --format json` / `network
        ls --format json` etc. emit either one JSON array or newline-
        delimited JSON objects depending on Docker/Compose version -- and,
        per ConvertFrom-K8ConcatenatedJson's docstring, possibly other
        line-layout variants this module must not assume away. Delegates the
        splitting to that depth-aware scanner (fail-closed on anything not a
        clean top-level array/object), then flattens: a single top-level
        array is expanded to its elements; each top-level object is one row.
        This is also where the well-known ConvertFrom-Json single-element-
        array-unwrap quirk (a JSON array with exactly one element
        deserializes to a bare object, not a 1-element array) is handled
        explicitly via the `-is [array]` check below, rather than papered
        over with an `@()` wrap that would be correct for that one quirk but
        wrong for the many-rows-NDJSON case.
    #>
    param([string] $Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { throw 'empty output: no JSON value to parse' }
    $chunks = ConvertFrom-K8ConcatenatedJson -Raw $Raw
    if ($chunks.Count -eq 0) { throw 'no JSON value found in output' }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($chunk in $chunks) {
        $parsed = $chunk | ConvertFrom-Json
        if ($parsed -is [array]) { foreach ($item in $parsed) { $rows.Add($item) } }
        else { $rows.Add($parsed) }
    }
    # Single comma only (see ConvertFrom-K8ConcatenatedJson above) -- and
    # every CALLER of this function must NOT wrap it in @() either, for the
    # same reason: this already force-returns a real array for 1 row or N.
    return ,$rows.ToArray()
}

function Get-K8ObjectPropertyValue {
    param([Parameter(Mandatory)] $Object, [Parameter(Mandatory)][string] $Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Resolve-K8ComposeImageRows {
    <# Compose v5.4 `images --format json` omits Service. Resolve that shape
       only through an anchored Compose container name:
       <project>-<service>-<replica> (or legacy underscore separators).
       Substring/ambiguous matches are forbidden. #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string[]] $ExpectedServices,
        [Parameter(Mandatory)][object[]] $ImageRows
    )
    $resolved = @{}
    foreach ($service in $ExpectedServices) {
        $dashName = '^{0}-{1}-[0-9]+$' -f [regex]::Escape($RunId), [regex]::Escape($service)
        $underscoreName = '^{0}_{1}_[0-9]+$' -f [regex]::Escape($RunId), [regex]::Escape($service)
        $imageMatches = @($ImageRows | Where-Object {
            $declaredService = Get-K8ObjectPropertyValue -Object $_ -Name 'Service'
            if (-not [string]::IsNullOrWhiteSpace([string]$declaredService)) {
                return ([string]$declaredService -ceq $service)
            }
            $containerName = Get-K8ObjectPropertyValue -Object $_ -Name 'ContainerName'
            return (-not [string]::IsNullOrWhiteSpace([string]$containerName) -and
                (([string]$containerName -cmatch $dashName) -or ([string]$containerName -cmatch $underscoreName)))
        })
        if ($imageMatches.Count -ne 1) {
            throw "image inventory must resolve exactly one image for expected service '$service'; found $($imageMatches.Count)"
        }
        $resolved[$service] = $imageMatches[0]
    }
    return $resolved
}

function Test-K8ComposeServiceReadiness {
    <#
        Container-state readiness only: every expected service present,
        State 'running', and -- for a service that DOES declare a Docker
        healthcheck -- Health 'healthy'. A service with NO healthcheck
        (Health blank/absent) is deliberately treated as ready on State alone,
        because that is the only signal Docker itself exposes for it; this is
        a conscious scope limit, not an oversight, and it is exactly why
        Elasticsearch -- which is slow to actually accept HTTP connections
        after its container reaches 'running', and had no healthcheck in the
        generated manifest -- needed its OWN application-level gate
        (Wait-K8ElasticsearchReady) rather than being trusted on State alone.
        See that function's docstring.

        Uses Get-K8ObjectPropertyValue rather than direct .Service/.State/
        .Health property access: under Set-StrictMode, a `compose ps --format
        json` row that omits a key entirely (observed to vary across Compose
        versions -- Health in particular) would throw
        PropertyNotFoundException on direct access instead of evaluating to
        $null.
    #>
    param([Parameter(Mandatory)][string[]] $Expected, [Parameter(Mandatory)][object[]] $Services)
    $byService = @{}
    foreach ($service in $Services) {
        $name = Get-K8ObjectPropertyValue -Object $service -Name 'Service'
        if ([string]::IsNullOrWhiteSpace([string]$name)) { throw 'compose ps row has no Service field' }
        $byService[[string]$name] = $service
    }
    $missing = @($Expected | Where-Object { -not $byService.ContainsKey($_) })
    $notRunning = @($Expected | Where-Object {
        $byService.ContainsKey($_) -and (Get-K8ObjectPropertyValue -Object $byService[$_] -Name 'State') -ne 'running'
    })
    $notHealthy = @($Expected | Where-Object {
        if (-not $byService.ContainsKey($_)) { return $false }
        $health = Get-K8ObjectPropertyValue -Object $byService[$_] -Name 'Health'
        (-not [string]::IsNullOrWhiteSpace([string]$health)) -and $health -ne 'healthy'
    })
    return [pscustomobject]@{ Ready=($missing.Count -eq 0 -and $notRunning.Count -eq 0 -and $notHealthy.Count -eq 0); Missing=$missing; NotRunning=$notRunning; NotHealthy=$notHealthy }
}

function Wait-K8ElasticsearchReady {
    <#
        APPLICATION-level readiness gate for Elasticsearch, distinct from and
        in addition to Test-K8ComposeServiceReadiness's container-state check.

        ROOT CAUSE this exists to fix: a real VM Shakedown run
        (k8shakedown-rangea-20260829-010502) reached the fixed Collector
        request and got curl exit 7 (transport/connect failure) against
        http://localhost:9200 from inside the elasticsearch container.
        Wait-K8ComposeReady had already reported the container 'running'
        (Elasticsearch has no Docker healthcheck in the generated manifest,
        so Test-K8ComposeServiceReadiness's State-only fallback passed it).
        A JVM-backed service reaching container 'running' state proves the
        process started, not that it has finished initializing and is
        actually accepting HTTP connections on 9200 -- that gap is exactly
        what produced the transport failure, on whichever Range reached the
        query first (Range A here; Range B's Runtime Contract record used to
        run its own ad hoc, non-polling `curl` check after the fault, which
        would have caught this by accident on Range B but never gated Range A
        and was not a real finite-timeout readiness gate).

        Contract (all required by the K8-3 Shakedown audit that added this):
          - Runs BEFORE T0/the sender trigger, for BOTH Range A and Range B,
            from one shared call site -- not duplicated, not Range-B-only.
          - Finite timeout; never blocks forever.
          - Polls only $Endpoint ('_cluster/health'); never changes the
            endpoint, an index pattern, or any frozen selector to "make it
            work."
          - On timeout, throws (STOP before capture/sender/trigger) and
            retains every poll attempt's diagnostic -- never silently
            continues with an unconfirmed endpoint.
          - Retains its PASS result too, so a review can see the gate ran.
          - Never retried after the fact and never reused to retry a
            SCIENTIFIC request (the Collector/Rule/R-OBS-05 calls in
            Invoke-K8ElasticsearchRequest/Complete-K8ElasticsearchResponse
            remain exactly-once with no retry loop; grepping either of those
            two function bodies for a loop construct must find none -- see
            Test-K8ShakedownRegression.ps1).

        PASS condition (independent review round 2: HTTP 200 alone is an
        HTTP-listener check, not evidence the cluster can actually index/
        search -- a JVM that has bound the port but not yet formed a cluster
        can still answer HTTP before it can serve _search/_bulk correctly).
        The response BODY is retained and parsed, not discarded: PASS
        requires HTTP 2xx, a JSON body, and its "status" field to be
        "yellow" or "green". "red" means at least one primary shard is
        unassigned -- not accepted as ready. "yellow" (not "green") is
        accepted because this scenario is a single-node cluster with default
        replica settings, where "green" is not a normally reachable steady
        state; requiring it would make every run fail on a fully healthy
        single-node cluster, which is not what this gate is for.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence,
        [int] $TimeoutSeconds = 240,
        [int] $PollSeconds = 3
    )
    $envDir = Join-Path $RunEvidence 'environment'
    $container = (docker compose -p $RunId -f $ComposePath ps -q elasticsearch | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($container)) {
        throw 'Elasticsearch container could not be resolved for the application-readiness gate; not proceeding to capture/trigger.'
    }
    $marker = 'K8_HTTP_STATUS'
    $attempts = @()
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $attemptStart = (Get-Date).ToUniversalTime().ToString('o')
        # STDOUT/STDERR captured separately: curl's own stderr diagnostics
        # must never be merged into the body+marker text this regex parses.
        # The -w value uses curl's OWN literal `\n` escape (two characters,
        # backslash-then-n; curl expands it to a real newline when it writes
        # -w's output), not a raw embedded newline byte in the argument --
        # curl documents this escape specifically so callers never have to
        # smuggle a literal control character through a shell/argv boundary.
        $healthCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('exec', $container, 'curl', '-sS', '--max-time', '5', '-w', "\n${marker}:%{http_code}", 'http://localhost:9200/_cluster/health')
        $raw = ($healthCapture.Stdout | Out-String)
        $curlExit = $healthCapture.ExitCode
        $record = [ordered]@{ attempt_utc=$attemptStart; curl_exit=$curlExit; curl_stderr=$healthCapture.Stderr.Trim(); http_status=$null; cluster_status=$null; body_parsed=$false }
        if ($curlExit -eq 0 -and $raw -match "(?s)^(.*)\r?\n${marker}:(\d+)\s*$") {
            $bodyText = $Matches[1]
            $record.http_status = $Matches[2]
            if ($record.http_status -match '^2[0-9][0-9]$') {
                try {
                    $parsed = $bodyText | ConvertFrom-Json
                    $record.body_parsed = $true
                    $record.cluster_status = Get-K8ObjectPropertyValue -Object $parsed -Name 'status'
                    if ($record.cluster_status -in @('yellow', 'green')) {
                        $attempts += $record
                        [ordered]@{ gate='elasticsearch-application-readiness'; result='PASS'; container=$container; pass_condition='HTTP 2xx, parsed JSON body, cluster status in {yellow, green}'; final_body=$parsed; attempts=$attempts } |
                            ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $envDir 'elasticsearch-readiness.json') -Encoding utf8NoBOM
                        Write-K8ShakedownLog -Message "Elasticsearch application readiness PASS after $($attempts.Count) attempt(s) (HTTP $($record.http_status), cluster status '$($record.cluster_status)')."
                        return
                    }
                }
                catch { }
            }
        }
        $attempts += $record
        Start-Sleep -Seconds $PollSeconds
    }
    [ordered]@{ gate='elasticsearch-application-readiness'; result='TIMEOUT'; container=$container; pass_condition='HTTP 2xx, parsed JSON body, cluster status in {yellow, green}'; attempts=$attempts } |
        ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $envDir 'elasticsearch-readiness.json') -Encoding utf8NoBOM
    throw "Elasticsearch application-readiness gate timed out after ${TimeoutSeconds}s ($($attempts.Count) attempt(s); none returned HTTP 2xx with a parsed _cluster/health body whose status was yellow or green). Not proceeding to capture/trigger. See environment/elasticsearch-readiness.json. This is the pre-trigger gate for the curl-exit-7 class of failure; it is not retried here, and the fixed Collector/Rule/R-OBS-05 requests downstream are still never retried either."
}

function Get-K8Dnp3OperationalCanaryHits {
    <#
        PRE-TRIGGER READINESS CANARY -- not the scientific R-OBS-05 request.

        Independent review round 3 found that "log_structurer's tshark and
        bulk_loader.py processes are both alive" (round 2's fix) still does
        not prove documents are actually landing in ot-logs-dnp3-*:
        platform/generators/assets/bulk_loader.py's own flush() catches
        every _bulk POST failure (HTTPError and bare Exception alike),
        prints to stderr, and keeps running -- a process that is alive but
        silently failing every flush looks identical, from a process-table
        check alone, to one that is delivering correctly.

        This queries ot-logs-dnp3-* for the cc_scada_master (10.1.10.10,
        link source 1) <-> sub_c_rtu (10.1.40.10, link source 20) periodic
        DNP3 Integrity Poll -- genuine, pre-existing normal-operations
        traffic (an ~8s background interval; see
        k6-r-obs-05-collector-query-contract.md SS1/SS3, whose own frozen
        "unrelated flow" selector this reuses verbatim as VALUES only, for
        an entirely different purpose). No fixed selector/index pattern/
        query shape is invented here -- the field names and addresses are
        copied from that already-frozen contract, not guessed.

        This is deliberately NOT the scientific R-OBS-05 evidence request:
          - No T0 window (T0 does not exist yet -- this runs before the
            sender). Sorted `_doc desc` (insertion order) instead, exactly
            as scenarios/legacy-power-grid-signals/zone_violation.py itself
            does for the same "give me whatever is most recently indexed"
            need.
          - Result is NOT retained under contract-output/ and is not an
            R-OBS-05 artifact. It exists only to prove the pipeline is
            functionally delivering before the one scientific trigger.
          - Never touches, and is asserted never to match, the target
            attack selector (10.1.20.11 -> 10.1.10.10, fc=5, link
            1024->1): every returned hit's source IP/function code is
            checked against that tuple and this throws if it ever matches,
            rather than silently trusting the query filter alone to keep
            them disjoint.
          - Executed once per poll attempt by the caller's own loop; it is
            not itself retried past that caller's timeout, and it never
            substitutes for or is confused with the fixed, exactly-once
            Collector/Rule/R-OBS-05 requests in Invoke-K8ElasticsearchRequest.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath
    )
    $container = (docker compose -p $RunId -f $ComposePath ps -q elasticsearch | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($container)) {
        throw 'elasticsearch container could not be resolved for the operational-canary readiness check'
    }
    # Same cc_scada_master<->sub_c_rtu selector VALUES as
    # k6-r-obs-05-collector-query-contract.md SS3, no time window, sorted by
    # insertion order (matching zone_violation.py's own approach) rather
    # than by a T0 this check runs before.
    $query = '{"size":3,"track_total_hits":true,"sort":[{"_doc":"desc"}],"query":{"bool":{"minimum_should_match":1,"should":[{"bool":{"filter":[{"term":{"layers.ip.ip_ip_src.keyword":"10.1.10.10"}},{"term":{"layers.ip.ip_ip_dst.keyword":"10.1.40.10"}},{"term":{"layers.tcp.tcp_tcp_dstport.keyword":"20000"}},{"terms":{"layers.dnp3.dnp3_dnp3_al_func.keyword":["1","5"]}},{"term":{"layers.dnp3.dnp3_dnp3_src.keyword":"1"}},{"term":{"layers.dnp3.dnp3_dnp3_dst.keyword":"20"}}]}},{"bool":{"filter":[{"term":{"layers.ip.ip_ip_src.keyword":"10.1.40.10"}},{"term":{"layers.ip.ip_ip_dst.keyword":"10.1.10.10"}},{"term":{"layers.tcp.tcp_tcp_srcport.keyword":"20000"}},{"term":{"layers.dnp3.dnp3_dnp3_al_func.keyword":"129"}},{"term":{"layers.dnp3.dnp3_dnp3_src.keyword":"20"}},{"term":{"layers.dnp3.dnp3_dnp3_dst.keyword":"1"}}]}}]}}}'
    $marker = 'K8_HTTP_STATUS'
    # STDOUT/STDERR captured separately: curl's own stderr must not be
    # merged into the body+marker text this regex parses. As above, `\n` is
    # curl's OWN -w escape (expanded by curl itself), not a raw embedded
    # newline byte in the argument.
    $canaryCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('exec', $container, 'curl', '-sS', '--max-time', '5', '-X', 'POST', 'http://localhost:9200/ot-logs-dnp3-*/_search', '-H', 'Content-Type: application/json', '--data-binary', $query, '-w', "\n${marker}:%{http_code}")
    $raw = ($canaryCapture.Stdout | Out-String)
    $curlExit = $canaryCapture.ExitCode
    if ($curlExit -ne 0 -or $raw -notmatch "(?s)^(.*)\r?\n${marker}:(\d+)\s*$") {
        throw "operational-canary query transport failure (curl exit $curlExit): stdout=$raw stderr=$($canaryCapture.Stderr.Trim())"
    }
    $bodyText = $Matches[1]
    $httpStatus = $Matches[2]
    if ($httpStatus -notmatch '^2[0-9][0-9]$') {
        throw "operational-canary query returned HTTP ${httpStatus}: $bodyText"
    }
    $parsed = $bodyText | ConvertFrom-Json
    $hitsBlock = Get-K8ObjectPropertyValue -Object $parsed -Name 'hits'
    $hits = @(Get-K8ObjectPropertyValue -Object $hitsBlock -Name 'hits')
    $totalBlock = Get-K8ObjectPropertyValue -Object $hitsBlock -Name 'total'
    $total = [int](Get-K8ObjectPropertyValue -Object $totalBlock -Name 'value')
    foreach ($hit in $hits) {
        $source = Get-K8ObjectPropertyValue -Object $hit -Name '_source'
        $layers = Get-K8ObjectPropertyValue -Object $source -Name 'layers'
        $ipLayer = Get-K8ObjectPropertyValue -Object $layers -Name 'ip'
        $dnp3Layer = Get-K8ObjectPropertyValue -Object $layers -Name 'dnp3'
        $srcIp = Get-K8ObjectPropertyValue -Object $ipLayer -Name 'ip_ip_src'
        $func = Get-K8ObjectPropertyValue -Object $dnp3Layer -Name 'dnp3_dnp3_al_func'
        if ($srcIp -eq '10.1.20.11' -and $func -eq '5') {
            throw 'operational-canary query unexpectedly matched the TARGET scientific selector (src=10.1.20.11, fc=5) -- the canary selector must stay disjoint from the target attack flow by construction. STOP.'
        }
    }
    return [pscustomobject]@{ TotalHits = $total; Hits = $hits; RawBody = $bodyText }
}

function Wait-K8LogStructurerReady {
    <#
        APPLICATION-level readiness gate for log_structurer's DNP3
        tshark|bulk_loader.py pipeline -- the pipeline that actually feeds
        the ot-logs-dnp3-* index the fixed Collector request reads.

        Root cause this closes (independent review round 2, BLOCKER):
        Amenonuboco platform/generators/structuring.py, pinned
        78fc17746b5d663fafec9dffe563d79fe9ea02b7, generates log_structurer's
        OWN container startup script to run
        `apt-get update && apt-get install -y tshark python3` FIRST, and only
        after that succeeds does it launch, per declared protocol,
        `tshark -i $IF -T ek -Y "dnp3" -l | python3 /app/bulk_loader.py
        --index "ot-logs-dnp3-*" ...` as a background pipeline (source
        reviewed directly at the pinned commit, not assumed). Container
        'running' only proves that install step's shell started; a Collector
        query fired before the pipeline is actually live would not error --
        it would return zero/incomplete hits that look exactly like a
        legitimate negative scientific result. That silent-corruption shape
        (vs. wan_router's own iproute2 install, which fails LOUDLY when `ip`/
        `tc` are not yet present, because Resolve-K8GatewayInterface's own
        line-count check throws on zero matches) is why this one is a
        BLOCKER and wan_router's install race is not; see the cross-service
        audit note in this module's top-of-file comment.

        Mechanism: checked via /proc/*/cmdline (present on any Linux
        container regardless of whether ps/pgrep are installed -- this image
        installs only tshark/python3, not procps) for a live process whose
        argv contains BOTH 'tshark' and 'dnp3' (the launched tshark), and a
        second live process whose argv contains BOTH 'bulk_loader.py' and
        'dnp3' (the launched loader, `--index "ot-logs-dnp3-*"`). Sender
        argument quoting is stripped by the shell that execs these processes
        (compose.py wraps every generated command in `sh -c "..."`), so
        their real /proc/PID/cmdline never contains the source's own
        double-quote characters -- confirmed by reading compose.py's command
        assembly, not assumed.

        Process-alive is NECESSARY but not SUFFICIENT (independent review
        round 3, BLOCKER): platform/generators/assets/bulk_loader.py's own
        flush() catches every Elasticsearch _bulk POST failure (HTTPError
        and any other Exception alike), prints it to stderr, and keeps
        running -- so tshark+bulk_loader can both be alive while zero
        documents are actually reaching ot-logs-dnp3-*. PASS therefore also
        requires Get-K8Dnp3OperationalCanaryHits to find at least one
        real, pre-existing, non-target-selector DNP3 document -- proof the
        FULL observe -> structure -> index chain is functioning, not just
        that its processes started.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence,
        [int] $TimeoutSeconds = 240,
        [int] $PollSeconds = 3
    )
    $envDir = Join-Path $RunEvidence 'environment'
    $container = (docker compose -p $RunId -f $ComposePath ps -q log_structurer | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($container)) {
        throw 'log_structurer container could not be resolved for the application-readiness gate; not proceeding to capture/trigger.'
    }
    $probe = 'for p in /proc/[0-9]*/cmdline; do tr "\0" " " < "$p" 2>/dev/null; printf "\n"; done'
    $attempts = @()
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $attemptStart = (Get-Date).ToUniversalTime().ToString('o')
        $dump = @((docker exec $container sh -lc $probe 2>&1 | Out-String) -split "`n")
        $tsharkLive = [bool]($dump | Where-Object { $_ -match 'tshark' -and $_ -match 'dnp3' })
        $bulkLoaderLive = [bool]($dump | Where-Object { $_ -match 'bulk_loader\.py' -and $_ -match 'dnp3' })
        $canaryHitCount = 0
        $canaryError = $null
        try {
            $canary = Get-K8Dnp3OperationalCanaryHits -RunId $RunId -ComposePath $ComposePath
            $canaryHitCount = $canary.TotalHits
        }
        catch { $canaryError = $_.Exception.Message }
        $attempts += [ordered]@{
            attempt_utc=$attemptStart; tshark_dnp3_process_found=$tsharkLive; bulk_loader_dnp3_process_found=$bulkLoaderLive
            operational_canary_hit_count=$canaryHitCount; operational_canary_query_error=$canaryError
        }
        if ($tsharkLive -and $bulkLoaderLive -and $canaryHitCount -gt 0) {
            [ordered]@{ gate='log-structurer-dnp3-functional-readiness'; result='PASS'; container=$container; attempts=$attempts } |
                ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $envDir 'log-structurer-readiness.json') -Encoding utf8NoBOM
            Write-K8ShakedownLog -Message "log_structurer functional readiness PASS after $($attempts.Count) attempt(s): pipeline processes live AND $canaryHitCount operational-canary document(s) observed in ot-logs-dnp3-*."
            return
        }
        Start-Sleep -Seconds $PollSeconds
    }
    [ordered]@{ gate='log-structurer-dnp3-functional-readiness'; result='TIMEOUT'; container=$container; attempts=$attempts } |
        ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $envDir 'log-structurer-readiness.json') -Encoding utf8NoBOM
    throw "log_structurer's DNP3 tshark|bulk_loader pipeline did not reach functional readiness within ${TimeoutSeconds}s (process-alive and/or the operational-canary document check in ot-logs-dnp3-* never both held -- see environment/log-structurer-readiness.json for which). Not proceeding to capture/trigger -- a Collector query against a non-functional structuring pipeline would return an empty/incomplete result that looks like a legitimate negative finding rather than a startup race."
}

function Wait-K8ZoneDetectorReady {
    <#
        APPLICATION-level readiness gate for zone_detector's
        signal-1-zone-violation detection plugin process -- the process that
        actually populates ot-signals-zone-violation-*, which the fixed Rule
        request reads.

        Root cause this closes (independent review round 2, BLOCKER):
        Amenonuboco platform/generators/plugins.py, pinned
        78fc17746b5d663fafec9dffe563d79fe9ea02b7, generates the detection
        plugin host's startup script to run
        `pip install --quiet --no-cache-dir <requires>` FIRST, and only
        after that succeeds does it launch
        `python3 /app/plugins/signal-1-zone-violation.py &` (source reviewed
        directly at the pinned commit; plugin container path/name confirmed
        against c2-dnp3-step3-pilot.md's own record of the mount target).
        Container 'running' only proves the pip-install shell started, not
        that the detector process is live. A Rule query fired before it
        starts would return zero hits indistinguishable from a genuine
        'No alert' scientific result.

        Mechanism: same /proc/*/cmdline approach as
        Wait-K8LogStructurerReady, for the same reason (this image's own
        startup script installs only what `requires` declares, not procps).

        Process-alive is NECESSARY but not SUFFICIENT (independent review
        round 3, BLOCKER):
        scenarios/legacy-power-grid-signals/zone_violation.py's own
        poll_once() wraps its Elasticsearch search in
        `except requests.exceptions.RequestException: ... return 0` --
        "sidecar must not crash" is the stated design intent, so a plugin
        that cannot reach Elasticsearch at all keeps running forever,
        indistinguishable by process state alone from one that is actually
        polling successfully. PASS therefore also requires an HTTP
        connectivity check issued FROM WITHIN the zone_detector container
        itself (not from the elasticsearch container, not from the
        Shakedown host) against that container's own resolved $ES_URL (read
        from its actual environment, falling back to the script's own
        documented default only if unset) -- proving the same network path
        the real plugin process depends on, not a proxy for it. Uses
        `python3 -c` with stdlib `urllib.request` only, not curl: this
        image is python:3.11-slim with no guarantee curl was ever
        installed (only what `plugin.requires` declares is pip-installed;
        curl is not a Python package).

        Round 4 (BLOCKER, independent review): a bare `_cluster/health` 2xx
        proves TCP/HTTP reachability but not that the plugin's ACTUAL
        dependency -- `POST <ES_URL>/ot-logs-dnp3-*/_search` -- succeeds.
        poll_once() catches every requests.exceptions.RequestException on
        that search (a 400 from a query/mapping incompatibility included)
        and returns 0, so "process alive + generic ES reachable + this one
        specific search permanently failing" was a real, undetected PASS
        condition. This gate now also issues, FROM WITHIN the zone_detector
        container, the plugin's own literal query --
        `{"size": 50, "sort": [{"_doc": "desc"}], "query": {"wildcard":
        {"layers.frame.frame_frame_protocols": "*dnp3*"}}}` -- copied
        verbatim from scenarios/legacy-power-grid-signals/zone_violation.py
        poll_once() at the pinned commit, not reconstructed or
        approximated, against ot-logs-dnp3-* (already known to hold at
        least one document at this point in the pipeline, since
        Wait-K8LogStructurerReady's operational canary already required
        that). PASS requires HTTP 2xx AND a body that parses as JSON.

        Best-effort, non-blocking: the container's recent stderr is also
        checked for zone_violation's own "search failed"/"bulk write
        failed" lines and recorded (not gated on) -- a transient old error
        from before Elasticsearch itself became ready is expected and must
        not by itself fail a run that is otherwise functionally ready now.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence,
        [int] $TimeoutSeconds = 240,
        [int] $PollSeconds = 3
    )
    $envDir = Join-Path $RunEvidence 'environment'
    $container = (docker compose -p $RunId -f $ComposePath ps -q zone_detector | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($container)) {
        throw 'zone_detector container could not be resolved for the application-readiness gate; not proceeding to capture/trigger.'
    }
    $probe = 'for p in /proc/[0-9]*/cmdline; do tr "\0" " " < "$p" 2>/dev/null; printf "\n"; done'
    $attempts = @()
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $attemptStart = (Get-Date).ToUniversalTime().ToString('o')
        $dump = @((docker exec $container sh -lc $probe 2>&1 | Out-String) -split "`n")
        $pluginLive = [bool]($dump | Where-Object { $_ -match 'python3' -and $_ -match 'signal-1-zone-violation' })

        # Resolve the container's OWN configured ES_URL (zone_violation.py's
        # own default if unset), then check connectivity from inside it.
        $esUrlRaw = (docker exec $container sh -lc 'printf "%s" "${ES_URL:-http://elasticsearch:9200}"' 2>&1 | Out-String).Trim()
        $esUrl = if ($esUrlRaw) { $esUrlRaw } else { 'http://elasticsearch:9200' }
        # STDOUT/STDERR captured separately for both python3 checks below: a
        # stray interpreter warning on stderr (e.g. a DeprecationWarning)
        # merged into stdout would corrupt the exact `^2[0-9][0-9]$` match
        # even on an otherwise-successful request -- the same defect class
        # as the tshark stdout/stderr bug this round's review found.
        $connectivityScript = "import sys,urllib.request`ntry:`n r=urllib.request.urlopen('$esUrl/_cluster/health',timeout=5)`n sys.stdout.write(str(r.status))`nexcept Exception as e:`n sys.stdout.write('ERROR:'+str(e))`n sys.exit(1)`n"
        $connCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('exec', $container, 'python3', '-c', (ConvertTo-K8PythonExecOneLiner -Script $connectivityScript))
        $connOut = ($connCapture.Stdout | Out-String).Trim()
        $connExit = $connCapture.ExitCode
        $connectivityOk = ($connExit -eq 0 -and $connOut -match '^2[0-9][0-9]$')

        # The plugin's own literal search, from inside its own container,
        # against its own real dependency (not just a generic health check).
        $searchOk = $false
        $searchResult = $null
        if ($connectivityOk) {
            $searchScript = "import sys,json,urllib.request,urllib.error`nbody=b'{`"size`": 50, `"sort`": [{`"_doc`": `"desc`"}], `"query`": {`"wildcard`": {`"layers.frame.frame_frame_protocols`": `"*dnp3*`"}}}'`ntry:`n req=urllib.request.Request('$esUrl/ot-logs-dnp3-*/_search',data=body,headers={'Content-Type':'application/json'},method='POST')`n r=urllib.request.urlopen(req,timeout=5)`n raw=r.read()`n json.loads(raw)`n sys.stdout.write(str(r.status))`nexcept urllib.error.HTTPError as e:`n sys.stdout.write('HTTPERROR:'+str(e.code))`n sys.exit(1)`nexcept Exception as e:`n sys.stdout.write('ERROR:'+str(e))`n sys.exit(1)`n"
            $searchCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('exec', $container, 'python3', '-c', (ConvertTo-K8PythonExecOneLiner -Script $searchScript))
            $searchResult = ($searchCapture.Stdout | Out-String).Trim()
            $searchExit = $searchCapture.ExitCode
            $searchOk = ($searchExit -eq 0 -and $searchResult -match '^2[0-9][0-9]$')
        }

        $recentLog = (docker logs --tail 20 $container 2>&1 | Out-String)
        $recentLogHasError = [bool]($recentLog -match 'search failed|bulk write failed')

        $attempts += [ordered]@{
            attempt_utc=$attemptStart; signal1_plugin_process_found=$pluginLive
            es_url_used=$esUrl; zone_detector_to_es_connectivity_ok=$connectivityOk; zone_detector_to_es_result=$connOut
            zone_detector_source_index_search_ok=$searchOk; zone_detector_source_index_search_result=$searchResult
            # Recorded for review, not gated on: a transient old error from
            # before Elasticsearch itself became ready must not by itself
            # fail a run that is otherwise functionally ready now.
            recent_log_tail_error_seen_best_effort_non_blocking=$recentLogHasError
        }
        if ($pluginLive -and $connectivityOk -and $searchOk) {
            [ordered]@{ gate='zone-detector-functional-readiness'; result='PASS'; container=$container; attempts=$attempts } |
                ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $envDir 'zone-detector-readiness.json') -Encoding utf8NoBOM
            Write-K8ShakedownLog -Message "zone_detector functional readiness PASS after $($attempts.Count) attempt(s): plugin process live, HTTP $connOut to $esUrl, AND its own ot-logs-dnp3-*/_search query returned HTTP $searchResult with a parseable body."
            return
        }
        Start-Sleep -Seconds $PollSeconds
    }
    [ordered]@{ gate='zone-detector-functional-readiness'; result='TIMEOUT'; container=$container; attempts=$attempts } |
        ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $envDir 'zone-detector-readiness.json') -Encoding utf8NoBOM
    throw "zone_detector did not reach functional readiness within ${TimeoutSeconds}s (plugin-process-alive, its own container-to-Elasticsearch connectivity, and/or its own literal ot-logs-dnp3-*/_search query never all three held -- see environment/zone-detector-readiness.json for which). Not proceeding to capture/trigger -- a Rule query against a detector whose own search is failing (query/mapping incompatibility, a 400, etc.) would return zero hits indistinguishable from a genuine 'No alert' result."
}

function Complete-K8ElasticsearchResponse {
    <# Pure fail-closed response gate, split from Docker/curl so every outcome
       is regression-testable without a live VM. #>
    param(
        [Parameter(Mandatory)][int] $CurlExitCode,
        [string] $HttpStatus = '',
        [string] $RawBody = '',
        [string] $TransportDiagnostic = '',
        [Parameter(Mandatory)][string] $OutputPath,
        [Parameter(Mandatory)][string] $RequestLabel
    )
    $diagnosticPath = "$OutputPath.error-body.txt"
    if ($CurlExitCode -ne 0) {
        "transport_exit=$CurlExitCode`n$TransportDiagnostic`n$RawBody" | Set-Content -Path $diagnosticPath -Encoding utf8NoBOM
        throw "$RequestLabel transport/curl failure (exit $CurlExitCode); fixed request was not retried. Diagnostic: $diagnosticPath"
    }
    if ($HttpStatus -notmatch '^2[0-9][0-9]$') {
        $RawBody | Set-Content -Path $diagnosticPath -Encoding utf8NoBOM
        throw "$RequestLabel returned HTTP $HttpStatus; expected 2xx. Fixed request was not retried. Response body: $diagnosticPath"
    }
    try { $null = $RawBody | ConvertFrom-Json }
    catch {
        $RawBody | Set-Content -Path $diagnosticPath -Encoding utf8NoBOM
        throw "$RequestLabel returned invalid JSON with HTTP $HttpStatus. Diagnostic: $diagnosticPath"
    }
    $RawBody | Set-Content -Path $OutputPath -Encoding utf8NoBOM
}

function Invoke-K8ElasticsearchRequest {
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $Method,
        [Parameter(Mandatory)][string] $Endpoint,
        [string] $Body = '',
        [Parameter(Mandatory)][string] $OutputPath
    )
    $container = (docker compose -p $RunId -f $ComposePath ps -q elasticsearch | Out-String).Trim()
    if (-not $container) { throw 'Elasticsearch container could not be resolved' }
    if (Test-Path $OutputPath) { throw "refusing to overwrite existing Elasticsearch response: $OutputPath" }
    $remoteBody = "/tmp/k8-es-$([guid]::NewGuid().ToString('N')).body"
    # Old curl compatibility: one HTTP request writes the body separately and
    # emits only the status. No newer curl failure-body flag, retry, or resend.
    # STDOUT/STDERR captured SEPARATELY throughout: curl's own `-sS` still
    # shows real errors on stderr, and merging that into the expected
    # bare-3-digit-status stdout would corrupt every scientific ES request's
    # HTTP-status parse (Collector, Rule, mapping, R-OBS-05 all share this).
    $curlArgs = @('exec', $container, 'curl', '-sS', '-o', $remoteBody, '-w', '%{http_code}', '-X', $Method,
        "http://localhost:9200/$Endpoint", '-H', 'Content-Type: application/json')
    if ($Body) { $curlArgs += @('--data-binary', $Body) }
    $statusCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList $curlArgs
    $curlExit = $statusCapture.ExitCode
    $bodyCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('exec', $container, 'cat', $remoteBody)
    $bodyExit = $bodyCapture.ExitCode
    docker exec $container rm -f $remoteBody 2>&1 | Out-Null
    $rawBody = if ($bodyExit -eq 0) { $bodyCapture.Stdout | Out-String } else { '' }
    $effectiveExit = if ($curlExit -ne 0) { $curlExit } elseif ($bodyExit -ne 0) { 98 } else { 0 }
    $diagnostic = "stdout: $($statusCapture.Stdout -join ' ') | stderr: $($statusCapture.Stderr.Trim()) | body-read stderr: $($bodyCapture.Stderr.Trim())"
    Complete-K8ElasticsearchResponse -CurlExitCode $effectiveExit `
        -HttpStatus $(if ($curlExit -eq 0) { ($statusCapture.Stdout -join '').Trim() } else { '' }) `
        -RawBody $rawBody -TransportDiagnostic $diagnostic -OutputPath $OutputPath `
        -RequestLabel "Elasticsearch $Method $Endpoint"
}

function Invoke-K8FaultObservationCommand {
    <#
        Runs one Range B fault-boundary observation command and returns a
        complete record of it: exact argv, exit code, separated stdout and
        stderr, an explicit stdout_empty flag, and a UTC instant.

        ROOT CAUSE this exists to fix (real VM STOP
        k8shakedown-rangeb-20260829-134837, closed and not rescued): the
        previous implementation did `$post = docker exec ... 2>&1` and then
        `$post | Set-Content <path>`. PowerShell's Set-Content creates NO
        FILE when nothing is piped to it, and a successful fault leaves
        `tc filter show ... parent ffff:` with nothing to list -- so $post
        was $null and contract-output/qdisc-post-fault.txt was silently
        never written. The more correctly the frozen fault worked, the more
        certainly the artifact vanished. Confirmed by direct measurement:
        `$null | Set-Content` and `@() | Set-Content` create no file, while
        `-join`/ConvertTo-Json results always do.

        It also discarded the exit code and merged stderr into stdout, so
        "empty because no filter remains" (the frozen
        c2-dnp3-step4-range-b-fault-pilot.md SS4 check 2 success condition)
        was indistinguishable from "empty because tc failed".
    #>
    param([Parameter(Mandatory)][string[]] $Argv, [Parameter(Mandatory)][string] $Label)
    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    $capture = Invoke-K8SeparatedNativeCapture -FilePath $Argv[0] -ArgumentList @($Argv[1..($Argv.Count - 1)])
    $stdout = ($capture.Stdout | Out-String)
    return [pscustomobject]@{
        # Argv is the display string the retained artifact prints; ArgvList is
        # the real argument vector, kept so a failure record can report the
        # exact argv instead of re-splitting a joined string.
        Label = $Label; Argv = ($Argv -join ' '); ArgvList = @($Argv); ExitCode = $capture.ExitCode
        Stdout = $stdout; Stderr = $capture.Stderr
        StdoutEmpty = [string]::IsNullOrWhiteSpace($stdout); TimestampUtc = $timestamp
    }
}

function Write-K8FaultObservationArtifact {
    <#
        Writes a fault-boundary observation artifact. ALWAYS creates the
        file, including when every observation had empty stdout -- the
        emptiness is itself a retained observation, never a missing
        artifact.

        The final `-join` is load-bearing, not cosmetic: a joined string is
        a single pipeline item, so Set-Content always produces a file, which
        a bare (possibly $null / empty-array) command result does not.

        C-4: the same capture instance also produces a structured sidecar,
        `<artifact>.observation.json`. Both halves are written from these
        same in-memory observation objects -- the JSON is never re-parsed out
        of the text, and no scientific meaning is derived from either. If
        either write fails, the stage fails: a run must not continue with
        half an observation retained.
    #>
    param(
        [Parameter(Mandatory)][object[]] $Observations,
        [Parameter(Mandatory)][string] $RunEvidence,
        [Parameter(Mandatory)][string] $ArtifactRelativePath,
        [Parameter(Mandatory)][string] $Title,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $Range,
        [Parameter(Mandatory)][string] $Stage
    )
    $Path = Join-Path $RunEvidence $ArtifactRelativePath
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# $Title")
    $lines.Add('# Frozen basis: c2-dnp3-range-derivation.md SS3 -- "Preserve pre/post command output and the resolved interface in contract-output/".')
    $lines.Add('# An EMPTY stdout is a retained observation, not a missing artifact. For the post-fault')
    $lines.Add('# `tc filter show ... parent ffff:` it is exactly the frozen c2-dnp3-step4-range-b-fault-pilot.md')
    $lines.Add('# SS4 check 2 result ("shows no remaining target-segment mirror filter"). exit_code is what')
    $lines.Add('# distinguishes that from a command failure; this runner STOPs on any nonzero exit.')
    $lines.Add('# This record retains observation only. It computes no Pass/Fail and no scored verdict.')
    foreach ($o in $Observations) {
        $lines.Add('')
        $lines.Add("## $($o.Label)")
        $lines.Add("argv=$($o.Argv)")
        $lines.Add("exit_code=$($o.ExitCode)")
        $lines.Add("timestamp_utc=$($o.TimestampUtc)")
        $lines.Add("stdout_empty=$($o.StdoutEmpty.ToString().ToLowerInvariant())")
        $lines.Add('--- stdout ---')
        $lines.Add($o.Stdout.TrimEnd())
        $lines.Add('--- stderr ---')
        $lines.Add($o.Stderr.TrimEnd())
    }
    ($lines.ToArray() -join "`n") | Set-Content -Path $Path -Encoding utf8NoBOM

    Write-K8CommandObservation -RunEvidence $RunEvidence -ArtifactRelativePath $ArtifactRelativePath `
        -Producer 'Write-K8FaultObservationArtifact' -Stage $Stage -Range $Range -RunId $RunId `
        -Observations @($Observations | ForEach-Object {
            New-K8SeparatedCommandObservation -Label $_.Label -Argv $_.ArgvList -ExitCode $_.ExitCode `
                -TimestampUtc $_.TimestampUtc -Stdout $_.Stdout -Stderr $_.Stderr `
                -ContainingArtifact $ArtifactRelativePath
        }) | Out-Null
}

function Assert-K8FaultObservationsSucceeded {
    <# Fail-close on a nonzero exit. An empty stdout must never be read as
       success when the command that produced it actually failed. Callers
       write the artifact BEFORE calling this, so the diagnostic survives. #>
    param([Parameter(Mandatory)][object[]] $Observations, [Parameter(Mandatory)][string] $Stage)
    foreach ($o in $Observations) {
        if ($o.ExitCode -ne 0) {
            # Streams really were separated here, so both are recorded as
            # themselves.
            throw (New-K8CommandFailure `
                -Argv $o.ArgvList -ExitCode $o.ExitCode -StreamsSeparated `
                -Stdout $o.Stdout -Stderr $o.Stderr `
                -Message "Range B $Stage STOP: '$($o.Argv)' exited $($o.ExitCode). An empty stdout is never read as success when the command itself failed. stderr: $($o.Stderr.Trim())")
        }
    }
}

function Assert-K8UnrelatedMirrorFilter {
    <#
        Interface enumeration uses `ip -o link show` and extracts each name
        via an ANCHORED regex capture group (^\d+:\s+([^:@]+)), never a
        fixed whitespace-split column index -- this was already immune to
        the ip-br-addr-style positional-column defect audited and fixed in
        Resolve-K8GatewayInterface this round, but STDOUT/STDERR are now
        also captured separately (same audit) so a stray stderr line can
        never be mistaken for a real interface-listing line.

        C-4: this scan runs one enumeration command plus one `tc filter show`
        per interface, and the retained text kept only the per-interface
        stdout -- no argv, no exit code, no stderr, and no record of how many
        commands ran. All of that is now retained in the structured sidecar.

        Retaining an exit code is NOT the same as gating on it, and this does
        not start gating on it: the pass condition remains exactly "at least
        one unrelated interface retains a mirred egress mirror filter". A
        `tc filter show` that exits nonzero on some interface is now visible
        in the record instead of invisible, which is the whole point.
    #>
    param([Parameter(Mandatory)] $Gateway, [Parameter(Mandatory)][string] $RunEvidence,
          [string] $RunId = '', [string] $Range = 'b', [string] $Stage = 'fault-injection')
    $contractDir = Join-Path $RunEvidence 'contract-output'
    $observations = New-Object System.Collections.Generic.List[object]
    $linkArgv = @('docker', 'exec', $Gateway.Router, 'ip', '-o', 'link', 'show')
    $linkStartedUtc = Get-K8UtcNow
    $linksCapture = Invoke-K8SeparatedNativeCapture -FilePath $linkArgv[0] -ArgumentList @($linkArgv[1..($linkArgv.Count - 1)])
    $observations.Add((New-K8SeparatedCommandObservation -Label 'interface enumeration: ip -o link show' `
        -Argv $linkArgv -ExitCode $linksCapture.ExitCode -TimestampUtc $linkStartedUtc `
        -Stdout ((@($linksCapture.Stdout) | ForEach-Object { "$_" }) -join "`n") -Stderr $linksCapture.Stderr `
        -ContainingArtifact 'contract-output\unrelated-mirror-filters.txt'))
    if ($linksCapture.ExitCode -ne 0) {
        throw (New-K8CommandFailure `
            -Argv $linkArgv -ExitCode $linksCapture.ExitCode -StreamsSeparated `
            -Stdout ((@($linksCapture.Stdout) -join "`n")) -Stderr $linksCapture.Stderr `
            -Message "could not enumerate gateway interfaces for the unrelated mirror-filter gate (exit $($linksCapture.ExitCode)). stderr: $($linksCapture.Stderr.Trim())")
    }
    $links = @($linksCapture.Stdout)
    $records = @()
    $found = $false
    foreach ($line in $links) {
        if ($line -notmatch '^\d+:\s+([^:@]+)') { continue }
        $interface = $Matches[1]
        if ($interface -eq 'lo' -or $interface -eq $Gateway.Interface) { continue }
        $filterArgv = @('docker', 'exec', $Gateway.Router, 'tc', 'filter', 'show', 'dev', $interface, 'parent', 'ffff:')
        $filterStartedUtc = Get-K8UtcNow
        $filterCapture = Invoke-K8SeparatedNativeCapture -FilePath $filterArgv[0] -ArgumentList @($filterArgv[1..($filterArgv.Count - 1)])
        $filter = ($filterCapture.Stdout | Out-String)
        $observations.Add((New-K8SeparatedCommandObservation -Label "unrelated interface probe: $interface" `
            -Argv $filterArgv -ExitCode $filterCapture.ExitCode -TimestampUtc $filterStartedUtc `
            -Stdout $filter -Stderr $filterCapture.Stderr `
            -ContainingArtifact 'contract-output\unrelated-mirror-filters.txt'))
        $records += "### $interface`n$filter"
        if ($filter -match 'mirred\s+.*egress\s+mirror') { $found = $true }
    }
    $records -join "`n" | Set-Content -Path (Join-Path $contractDir 'unrelated-mirror-filters.txt') -Encoding utf8NoBOM
    # Written BEFORE the gate throws, so a failing scan still leaves the full
    # argv/exit/stderr record of every probe behind.
    Write-K8CommandObservation -RunEvidence $RunEvidence -ArtifactRelativePath 'contract-output\unrelated-mirror-filters.txt' `
        -Producer 'Assert-K8UnrelatedMirrorFilter' -Stage $Stage -Range $Range `
        -RunId $(if ($RunId) { $RunId } else { Split-Path -Leaf $RunEvidence }) `
        -Observations $observations.ToArray() | Out-Null
    if (-not $found) { throw 'Range B R-OBS-05 gate failed: no unrelated gateway interface retained a mirred egress mirror filter' }
}

function Invoke-K8TsharkFieldDecode {
    <#
        Shared low-level pcap decode: copies a retained pcap into the
        already-running log_structurer container (which already has tshark
        installed for its own DNP3 structuring pipeline -- no new install on
        the Windows host, no operator-run analysis), runs tshark there with
        a caller-supplied display filter against the SAME fixed field set
        every decode in this module uses, and returns the parsed rows. The
        remote copy is always removed afterward, success or failure.
    #>
    param(
        [Parameter(Mandatory)][string] $Container,
        [Parameter(Mandatory)][string] $LocalPcapPath,
        [Parameter(Mandatory)][string] $DisplayFilter,
        [Parameter(Mandatory)][string] $RemoteNameHint
    )
    if (-not (Test-Path $LocalPcapPath)) { throw "pcap not found for decode: $LocalPcapPath" }
    $remote = "/tmp/$RemoteNameHint.pcap"
    & docker cp $LocalPcapPath "${Container}:$remote" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not copy $LocalPcapPath into log_structurer for decode" }
    try {
        # STDOUT and STDERR captured SEPARATELY: tshark writes "Running as
        # user 'root' and group 'root'. This could be dangerous." (and
        # similar diagnostics) to stderr, which a merged `2>&1` capture
        # would hand to the TSV parser below as if it were a data row.
        #
        # `-E separator=/t`, NOT `separator=\t`: real VM run
        # k8shakedown-rangea-20260829-081151 showed a row delimited by a
        # literal backslash character instead of an actual tab byte -- `\t`
        # is a C-style/PowerShell escape, not tshark's own CLI syntax.
        # TShark's `-E separator=` documents exactly three forms: a single
        # literal character, `/t` for tab, or `/s` for space (never a
        # backslash escape) -- this module had been confusing PowerShell's
        # own string-escape convention with tshark's CLI contract. `/t` is
        # an instruction tshark itself expands into a real tab (0x09) byte
        # in ITS OWN output; the fix is entirely on this command-line
        # argument, so the `-split "`t"` below (an actual PowerShell tab
        # character, unrelated to this CLI syntax) is correct exactly as it
        # already was and needs no change once tshark is emitting real tabs.
        $capture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @(
            'exec', $Container, 'tshark', '-r', $remote, '-Y', $DisplayFilter, '-T', 'fields', '-E', 'separator=/t',
            '-e', 'frame.number', '-e', 'frame.time_epoch', '-e', 'ip.src', '-e', 'ip.dst',
            '-e', 'tcp.srcport', '-e', 'tcp.dstport', '-e', 'dnp3.al.func', '-e', 'dnp3.src', '-e', 'dnp3.dst'
        )
        if ($capture.ExitCode -ne 0) {
            throw "tshark decode failed (exit $($capture.ExitCode)) for $LocalPcapPath. stderr: $($capture.Stderr.Trim())"
        }
        $raw = $capture.Stdout
    }
    finally {
        docker exec $Container rm -f $remote 2>&1 | Out-Null
    }
    $rows = @()
    foreach ($line in $raw) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # NOT `-split "`t", -1`: a -1 limit to the -split operator does not
        # mean "unlimited" (it degenerately returns the whole line unsplit,
        # count 1) -- confirmed by direct testing, not assumed. Omitting the
        # limit (or passing 0) is what actually returns all 9 fields.
        $columns = @($line -split "`t")
        if ($columns.Count -ne 9) { throw "unexpected tshark row shape for $LocalPcapPath`: $line" }
        $rows += [ordered]@{ frame_number=$columns[0]; frame_time_epoch=$columns[1]; ip_src=$columns[2]; ip_dst=$columns[3]; tcp_srcport=$columns[4]; tcp_dstport=$columns[5]; dnp3_al_func=$columns[6]; dnp3_src=$columns[7]; dnp3_dst=$columns[8] }
    }
    # `,$rows` (not bare `$rows`): PowerShell unrolls an array onto the
    # output pipeline element-by-element, so a ONE-hit decode (the common
    # case) would otherwise hand the caller the bare [ordered] hashtable
    # instead of a one-element array -- confirmed by direct testing, not
    # assumed (a real invocation returned .Count=9, the FIELD count of that
    # single row, not the intended row count). The comma forces this
    # function to always return one array, whatever its length.
    return ,$rows
}

function Get-K8Robs05LivenessSpec {
    <#
        Acquisition parameters for the R-OBS-05 auxiliary liveness capture.
        EVERY value here is a fixed constant of this module: the operator
        supplies nothing, and there is no parameter, environment variable,
        or config file that can vary any of them per run. That mirrors the
        PURPOSE c2-dnp3-capture-procedure.md SS4 states for the two frozen
        stages ("the operator supplies only the run ID, evidence root,
        stage, and Compose file ... rather than from anything typed by
        hand").

        Namespace/interface are the frozen values from
        k6-r-obs-05-collector-query-contract.md SS4, which names the artifact
        this capture produces: "the separate R-OBS-05 `tap_observer:eth0`
        liveness pcap".

        THERE IS DELIBERATELY NO BPF FILTER. This is the single most
        important property of this spec and it is asserted, not incidental:
        a capture-time filter would be a selector, and no frozen constant
        defines one for this capture (the historical one is unrecoverable
        and must never be guessed). Capturing with no filter means the frame
        set that can become evidence is a pure function of frozen inputs
        only -- the frozen SS4 capture point, the frozen SS3 selector applied
        AFTER capture, and the frozen SS2/SS4 window -- with no non-frozen
        parameter able to influence it. Any filter, including the frozen
        target-scoped CAPTURE_FILTER, would reintroduce exactly the
        structural exclusion that made this gate unsatisfiable (the frozen
        filter requires host 10.1.20.11, which the unrelated flow
        10.1.10.10<->10.1.40.10 does not contain).

        This capture is NEITHER Ground Truth NOR Sensor. It produces
        liveness/control evidence only, per the frozen contract SS1 ("This
        query produces liveness evidence only. Its hits may never satisfy
        the target-event Sensor/Collector stages, rule correlation, or
        target complete-selector query."). The frozen Ground Truth and
        Sensor stages, apparatus.py's CAPTURE_FILTER, and study01_capture.py
        are all untouched and continue to own those two stages exclusively.
    #>
    param([Parameter(Mandatory)][string] $RunId)
    $C = Get-K8ShakedownConstants
    return [pscustomobject]@{
        HelperName       = "$RunId-r-obs-05-liveness-capture"
        HelperImage      = "$($C.TcpdumpImage)@$($C.TcpdumpDigest)"
        NamespaceService = 'tap_observer'
        Interface        = 'eth0'
        ContainerPcap    = '/data/r-obs-05-liveness.pcap'
        Artifact         = 'contract-output\r-obs-05-liveness.pcap'
        Decode           = 'contract-output\r-obs-05-liveness-decode.txt'
        Lifecycle        = 'contract-output\r-obs-05-capture-lifecycle.json'
        Rows             = 'contract-output\r-obs-05-pcap-rows.json'
    }
}

function Invoke-K8Robs05LifecycleStep {
    <# Runs one lifecycle command and returns the same shape the frozen
       capture_lifecycle.py retains per step: exact argv, exit code, output,
       and BOTH the start and completion UTC instants (they prove different
       things -- see c2-dnp3-capture-procedure.md SS5.1). #>
    param([Parameter(Mandatory)][string] $Step, [Parameter(Mandatory)][string[]] $Argv)
    $started = (Get-Date).ToUniversalTime().ToString('o')
    $capture = Invoke-K8SeparatedNativeCapture -FilePath $Argv[0] -ArgumentList @($Argv[1..($Argv.Count - 1)])
    $completed = (Get-Date).ToUniversalTime().ToString('o')
    return [ordered]@{
        step = $Step; argv = $Argv; exit_code = $capture.ExitCode
        stdout = ($capture.Stdout | Out-String).Trim(); stderr = $capture.Stderr.Trim()
        started_utc = $started; completed_utc = $completed
    }
}

function Start-K8Robs05LivenessCapture {
    <#
        Starts the auxiliary R-OBS-05 liveness capture and confirms it is
        listening. Range B only. Any failure is a reproduction-APPARATUS
        failure and STOPs the run (fresh run ID per
        c2-dnp3-capture-procedure.md SS6); it is never mapped onto an
        R-OBS-05 / Runtime Contract / classification value -- this function
        cannot and must not decide a scientific verdict.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence
    )
    $spec = Get-K8Robs05LivenessSpec -RunId $RunId
    $contractDir = Join-Path $RunEvidence 'contract-output'
    New-Item -ItemType Directory -Force -Path $contractDir | Out-Null
    $lifecyclePath = Join-Path $RunEvidence $spec.Lifecycle

    $nsCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'ps', '-q', $spec.NamespaceService)
    $namespaceContainer = ($nsCapture.Stdout | Out-String).Trim()
    if ($nsCapture.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($namespaceContainer)) {
        throw "R-OBS-05 liveness capture STOP (apparatus failure): namespace container for '$($spec.NamespaceService)' was not resolved (exit $($nsCapture.ExitCode)). stderr: $($nsCapture.Stderr.Trim())"
    }

    $record = [ordered]@{
        schema_version = 1; run_id = $RunId
        execution_run_root = (Resolve-Path $RunEvidence).Path
        role = 'r-obs-05-auxiliary-liveness'
        not_ground_truth = $true; not_sensor = $true
        helper_name = $spec.HelperName; helper_image = $spec.HelperImage
        helper_container_id = $null
        namespace_service = $spec.NamespaceService; namespace_container_id = $namespaceContainer
        interface = $spec.Interface
        capture_time_bpf_filter = $null
        capture_time_bpf_filter_note = 'No capture-time BPF filter by design: the frozen k6-r-obs-05 SS3 selector is the sole arbiter, applied after capture. See Get-K8Robs05LivenessSpec.'
        container_pcap = $spec.ContainerPcap; artifact = $spec.Artifact
        pcap_sha256 = $null; steps = @()
    }

    # Exactly the frozen helper argv shape (capture_lifecycle.py
    # expected_argv), MINUS the trailing filter argument.
    $startStep = Invoke-K8Robs05LifecycleStep -Step 'start' -Argv @(
        'docker', 'run', '-d', '--name', $spec.HelperName,
        '--network', "container:$namespaceContainer", '--cap-add', 'NET_RAW', $spec.HelperImage,
        '-i', $spec.Interface, '-nn', '-s', '0', '-w', $spec.ContainerPcap
    )
    $record.steps += $startStep
    if ($startStep.exit_code -ne 0) {
        $record | ConvertTo-Json -Depth 6 | Set-Content -Path $lifecyclePath -Encoding utf8NoBOM
        throw "R-OBS-05 liveness capture STOP (apparatus failure): helper did not start (exit $($startStep.exit_code)). stderr: $($startStep.stderr)"
    }
    $record.helper_container_id = $startStep.stdout.Trim()

    $listenStep = Invoke-K8Robs05LifecycleStep -Step 'listening-check' -Argv @('docker', 'logs', $spec.HelperName)
    $record.steps += $listenStep
    $record | ConvertTo-Json -Depth 6 | Set-Content -Path $lifecyclePath -Encoding utf8NoBOM
    if ($listenStep.exit_code -ne 0 -or "$($listenStep.stdout)`n$($listenStep.stderr)" -notmatch 'listening on') {
        throw "R-OBS-05 liveness capture STOP (apparatus failure): helper never reported 'listening on' (exit $($listenStep.exit_code)). stdout: $($listenStep.stdout) stderr: $($listenStep.stderr)"
    }
    Write-K8ShakedownLog -Message "R-OBS-05 auxiliary liveness capture listening on $($spec.NamespaceService):$($spec.Interface) (no capture-time BPF filter by design)."
}

function Complete-K8Robs05LivenessCapture {
    <#
        Window-end liveness check, stop, export, hash, remove -- the same
        six-step discipline the frozen stages retain, and the same
        window-coverage reasoning (SS5.1): the listening check must have
        COMPLETED at or before T0-5s, and the window-end liveness check must
        be timestamped at or after T0+15s and report `true`, before the
        helper may be stopped.

        Note on evidentiary standing: the frozen contract SS4 decides window
        validity from the FRAME and DOCUMENT timestamps at correlation time,
        not from this record. These checks are additional apparatus
        provenance. They can only cause a STOP, never a PASS -- the gate is
        positive-evidence (SS4 needs at least one correlating pair), so an
        under-covering capture can only fail to find evidence, never
        manufacture it.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $RunEvidence
    )
    $spec = Get-K8Robs05LivenessSpec -RunId $RunId
    $lifecyclePath = Join-Path $RunEvidence $spec.Lifecycle
    if (-not (Test-Path $lifecyclePath)) { throw "R-OBS-05 liveness capture STOP (apparatus failure): lifecycle record missing at $lifecyclePath; the capture was never started." }
    $record = Get-Content $lifecyclePath -Raw | ConvertFrom-Json

    $t0Path = Join-Path $RunEvidence 'metadata-t0.txt'
    if (-not (Test-Path $t0Path)) { throw "R-OBS-05 liveness capture STOP (apparatus failure): T0 record not found at $t0Path." }
    $t0 = [datetimeoffset]::Parse((Get-Content $t0Path -Raw).Trim())
    $windowStart = $t0.AddSeconds(-5); $windowEnd = $t0.AddSeconds(15)

    $steps = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @($record.steps)) { $steps.Add($s) }

    $listening = @($steps | Where-Object { $_.step -eq 'listening-check' })
    if ($listening.Count -ne 1) { throw 'R-OBS-05 liveness capture STOP (apparatus failure): listening-check step missing from the lifecycle record.' }
    if (([datetimeoffset]::Parse($listening[0].completed_utc)) -gt $windowStart) {
        throw "R-OBS-05 liveness capture STOP (apparatus failure): listening was confirmed at $($listening[0].completed_utc), after the frozen window start $($windowStart.ToString('o')); the capture cannot be shown to cover [T0-5s, T0+15s]."
    }

    $liveStep = Invoke-K8Robs05LifecycleStep -Step 'window-end-liveness-check' -Argv @('docker', 'inspect', '--format', '{{.State.Running}}', $spec.HelperName)
    $steps.Add($liveStep)
    if (([datetimeoffset]::Parse($liveStep.started_utc)) -lt $windowEnd) {
        throw "R-OBS-05 liveness capture STOP (apparatus failure): window-end liveness check ran at $($liveStep.started_utc), before the frozen window end $($windowEnd.ToString('o'))."
    }
    if ($liveStep.exit_code -ne 0 -or $liveStep.stdout.Trim() -ne 'true') {
        throw "R-OBS-05 liveness capture STOP (apparatus failure): helper was not running at the window end (exit $($liveStep.exit_code), reported '$($liveStep.stdout.Trim())'); the capture did not cover the window."
    }

    $stopStep = Invoke-K8Robs05LifecycleStep -Step 'stop' -Argv @('docker', 'stop', $spec.HelperName)
    $steps.Add($stopStep)
    $artifactPath = Join-Path $RunEvidence $spec.Artifact
    $exportStep = Invoke-K8Robs05LifecycleStep -Step 'export' -Argv @('docker', 'cp', "$($spec.HelperName):$($spec.ContainerPcap)", $artifactPath)
    $steps.Add($exportStep)
    $removeStep = Invoke-K8Robs05LifecycleStep -Step 'remove' -Argv @('docker', 'container', 'rm', $spec.HelperName)
    $steps.Add($removeStep)

    $record.steps = $steps.ToArray()
    if ($stopStep.exit_code -ne 0 -or $exportStep.exit_code -ne 0) {
        $record | ConvertTo-Json -Depth 6 | Set-Content -Path $lifecyclePath -Encoding utf8NoBOM
        throw "R-OBS-05 liveness capture STOP (apparatus failure): stop (exit $($stopStep.exit_code)) / export (exit $($exportStep.exit_code)) failed. export stderr: $($exportStep.stderr)"
    }
    if (-not (Test-Path $artifactPath)) {
        $record | ConvertTo-Json -Depth 6 | Set-Content -Path $lifecyclePath -Encoding utf8NoBOM
        throw "R-OBS-05 liveness capture STOP (apparatus failure): exported pcap not found at $artifactPath."
    }
    $record.pcap_sha256 = (Get-FileHash -Path $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $record | ConvertTo-Json -Depth 6 | Set-Content -Path $lifecyclePath -Encoding utf8NoBOM
    Write-K8ShakedownLog -Message "R-OBS-05 auxiliary liveness capture exported: $($spec.Artifact) (sha256 $($record.pcap_sha256))."
}

function Write-K8Robs05ContractReference {
    <# Frozen contract SS5: "a contract SHA-256/reference identifying this
       exact file at the K6 start commit." Retained, never interpreted. #>
    param([Parameter(Mandatory)][string] $RunEvidence, [Parameter(Mandatory)][string] $Study01Root)
    $contractFile = Join-Path $Study01Root 'studies\study-01-negative-result\protocol\k6-r-obs-05-collector-query-contract.md'
    if (-not (Test-Path $contractFile)) { throw "R-OBS-05 contract file not found for the frozen SS5 contract reference: $contractFile" }
    $sha = (Get-FileHash -Path $contractFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $path = Join-Path $RunEvidence 'contract-output\r-obs-05-contract-reference.txt'
    "protocol/k6-r-obs-05-collector-query-contract.md`nsha256=$sha`n" | Set-Content -Path $path -Encoding utf8NoBOM
    return $path
}

function Write-K8UnrelatedPcapRows {
    <#
        ROOT CAUSE this closes (real VM STOPs k8shakedown-rangeb-
        20260829-111026 / -115720, both closed and not rescued): this
        function previously decoded `sensor-input/mirror-capture/
        c2-mirror-sensor.pcap`. The frozen contract SS4 requires correlation
        against "the separate R-OBS-05 `tap_observer:eth0` liveness pcap",
        and the frozen CAPTURE_FILTER ("host 10.1.20.11 and host 10.1.10.10
        and tcp port 20000", enforced by capture_lifecycle.py) means the
        Sensor pcap can NEVER contain the unrelated flow
        (10.1.10.10<->10.1.40.10 has no 10.1.20.11). Reading the Sensor
        pcap was therefore both a frozen-contract non-conformance and a
        structurally unsatisfiable gate. Now reads the auxiliary liveness
        pcap this module captures for exactly this purpose.

        The SS3 display filter below is unchanged.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence
    )
    $spec = Get-K8Robs05LivenessSpec -RunId $RunId
    $pcap = Join-Path $RunEvidence $spec.Artifact
    if (-not (Test-Path $pcap)) {
        throw "R-OBS-05 STOP (apparatus failure): the auxiliary liveness pcap is missing at $pcap. The frozen contract SS4 correlates against this pcap; the Sensor pcap is never an acceptable substitute (its frozen BPF filter structurally excludes the unrelated flow)."
    }
    $container = (docker compose -p $RunId -f $ComposePath ps -q log_structurer | Out-String).Trim()
    if (-not $container) { throw 'log_structurer container could not be resolved for frozen pcap decode' }
    $display = '(ip.src == 10.1.10.10 && ip.dst == 10.1.40.10 && tcp.dstport == 20000 && (dnp3.al.func == 1 || dnp3.al.func == 5) && dnp3.src == 1 && dnp3.dst == 20) || (ip.src == 10.1.40.10 && ip.dst == 10.1.10.10 && tcp.srcport == 20000 && dnp3.al.func == 129 && dnp3.src == 20 && dnp3.dst == 1)'
    $rows = Invoke-K8TsharkFieldDecode -Container $container -LocalPcapPath $pcap -DisplayFilter $display -RemoteNameHint "$RunId-r-obs-05"
    $path = Join-Path $RunEvidence 'contract-output\r-obs-05-pcap-rows.json'
    ConvertTo-Json -InputObject @($rows) -Depth 4 | Set-Content -Path $path -Encoding utf8NoBOM
    # Frozen SS5 also requires the decoded unrelated-flow rows to be retained;
    # keep a human-readable form beside the machine-readable one, both
    # derived from the SAME decode of the SAME liveness pcap.
    $decodeLines = @("source_pcap=$($spec.Artifact)", "display_filter=$display", "decoded_row_count=$($rows.Count)")
    foreach ($r in $rows) { $decodeLines += (($r.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ') }
    $decodeLines -join "`n" | Set-Content -Path (Join-Path $RunEvidence $spec.Decode) -Encoding utf8NoBOM
    if ($rows.Count -eq 0) {
        throw "Range B R-OBS-05 gate failed: the auxiliary liveness pcap ($($spec.Artifact)) contains no frame matching the frozen k6-r-obs-05 SS3 unrelated-flow selector. The capture itself succeeded (see contract-output/r-obs-05-capture-lifecycle.json); this is an observed absence of the unrelated control flow, not a capture defect."
    }
    return $path
}

function Write-K8TargetCaptureDecode {
    <#
        README Study01/README.md SS5.1 step 6 requires "decode them" right
        after capture stop/export; c2-dnp3-capture-procedure.md SS5 requires
        retaining "decoded verification" alongside each stage's artifact;
        c2-dnp3-sender-procedure.md SS4 condition 3 requires the independent
        original-path pcap to satisfy the frozen Ground Truth selector in
        freeze-decision-table.md SS3, which also fixes the Sensor selector
        ("same tuple/function/link-address constraints ... in the
        mirror-side pcap"). A real VM run reached scoring-input with no
        machine-readable decode of either pcap at all -- this was entirely
        missing, not merely incomplete.

        Uses the EXACT frozen selector from freeze-decision-table.md SS3,
        copied verbatim, never approximated or independently invented:
        source 10.1.20.11, destination 10.1.10.10, TCP destination port
        20000, DNP3 function 5, link source 1024, link destination 1.
        Decoded via Invoke-K8TsharkFieldDecode -- the same log_structurer-
        container tshark mechanism as Write-K8UnrelatedPcapRows -- so no new
        tool install on the Windows host and no operator-run analysis.

        Retains the decoded hit count and every hit's fields/timestamp, and
        flags (informationally only) whether each frame's time falls inside
        the frozen [T0-5s, T0+15s] window -- this in-window flag is
        advisory, not a scientific gate: it does NOT use the same
        exact-integer-nanosecond comparison k8_shakedown_evidence.py uses
        for the R-OBS-05 correlation, because this artifact makes no
        pass/fail claim for it to gate. A decoded hit count of zero is
        retained exactly as observed and does NOT throw -- deciding whether
        the Ground Truth/Sensor predicate is satisfied remains the
        operator's scoring-input judgment (README SS6.2); this only removes
        the mechanical burden of running tshark and transcribing its output
        by hand. Must run while log_structurer is still up (before
        Complete's teardown) and before Complete's finalize-evidence, and
        writes into the same stage directory study01_capture.py itself
        writes into, so it is covered by validate-evidence's per-directory
        check and by the eventual hashes.sha256.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence,
        [Parameter(Mandatory)][ValidateSet('ground-truth', 'sensor')][string] $Stage,
        [Parameter(Mandatory)][string] $WindowStartIso,
        [Parameter(Mandatory)][string] $WindowEndIso
    )
    $stagePaths = @{
        'ground-truth' = @{ pcap = 'ground-truth\independent-capture\c2-original-path.pcap'; out = 'ground-truth\independent-capture\decoded-verification.json' }
        'sensor'       = @{ pcap = 'sensor-input\mirror-capture\c2-mirror-sensor.pcap'; out = 'sensor-input\mirror-capture\decoded-verification.json' }
    }
    $pcap = Join-Path $RunEvidence $stagePaths[$Stage].pcap
    $container = (docker compose -p $RunId -f $ComposePath ps -q log_structurer | Out-String).Trim()
    if (-not $container) { throw "log_structurer container could not be resolved for the $Stage capture decode" }
    # freeze-decision-table.md SS3, Ground Truth/Sensor row, verbatim.
    $display = 'ip.src==10.1.20.11 && ip.dst==10.1.10.10 && tcp.dstport==20000 && dnp3.al.func==5 && dnp3.src==1024 && dnp3.dst==1'
    $rows = Invoke-K8TsharkFieldDecode -Container $container -LocalPcapPath $pcap -DisplayFilter $display -RemoteNameHint "$RunId-$Stage-decode"

    $windowStart = [datetimeoffset]::Parse($WindowStartIso)
    $windowEnd = [datetimeoffset]::Parse($WindowEndIso)
    foreach ($row in $rows) {
        $inWindow = $false
        $parsedTime = 0.0
        if ([double]::TryParse($row.frame_time_epoch, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedTime)) {
            $frameInstant = [datetimeoffset]::FromUnixTimeMilliseconds([long]($parsedTime * 1000))
            $inWindow = ($frameInstant -ge $windowStart -and $frameInstant -le $windowEnd)
        }
        $row['in_frozen_window_advisory'] = $inWindow
    }
    $outPath = Join-Path $RunEvidence $stagePaths[$Stage].out
    [ordered]@{
        stage = $Stage
        selector = 'freeze-decision-table.md SS3: src=10.1.20.11 dst=10.1.10.10 tcp.dstport=20000 dnp3.al.func=5 dnp3.src=1024 dnp3.dst=1'
        window_start = $WindowStartIso; window_end = $WindowEndIso
        decoded_hit_count = $rows.Count
        hits_in_frozen_window_advisory = @($rows | Where-Object { $_.in_frozen_window_advisory }).Count
        rows = $rows
    } | ConvertTo-Json -Depth 6 | Set-Content -Path $outPath -Encoding utf8NoBOM
    Write-K8ShakedownLog -Message "$Stage capture decode retained: $($rows.Count) matching frame(s) at $outPath (zero is retained as observed, not treated as failure -- README SS6.2 governs the scoring judgment)."
}

function Get-K8CollectorHitIds {
    <#
        Extracts every hit's document _id from a retained Collector response
        (ot-logs-dnp3-* search result). Every _id here is, by construction,
        an ACCEPTED Collector hit: the Collector query itself already
        enforces the complete frozen Collector selector
        (freeze-decision-table.md SS3), so this never re-derives, narrows,
        or judges that -- it only reads back what the Collector query
        already decided. Returns the COMPLETE matching-hit set, never a
        post hoc single chosen document (frozen: "Multiple matching
        collector documents do not fail the criterion and may not be
        reduced to a post hoc chosen document"). Zero hits is a valid
        observed Collector state and returns an empty array, not a throw --
        deciding whether the Collector stage itself passes remains the
        operator's scoring-input judgment (README SS6.2); this function only
        reads IDs back for the Rule query filter.
    #>
    param([Parameter(Mandatory)][string] $CollectorResponsePath)
    $response = Get-Content $CollectorResponsePath -Raw | ConvertFrom-Json
    $hitsBlock = Get-K8ObjectPropertyValue -Object $response -Name 'hits'
    if (-not $hitsBlock) { throw "Collector response at $CollectorResponsePath has no 'hits' block; cannot resolve the accepted Collector hit set for the Rule selector." }
    $rows = Get-K8ObjectPropertyValue -Object $hitsBlock -Name 'hits'
    $ids = New-Object System.Collections.Generic.List[string]
    if ($null -ne $rows) {
        # `@($null)` is a 1-element array CONTAINING null, not an empty
        # array -- guard explicitly rather than iterate blindly.
        foreach ($row in @($rows)) {
            if ($null -eq $row) { continue }
            $id = Get-K8ObjectPropertyValue -Object $row -Name '_id'
            if (-not [string]::IsNullOrWhiteSpace([string]$id)) { $ids.Add([string]$id) }
        }
    }
    return ,$ids.ToArray()
}

function Invoke-K8AutomatedQueries {
    <#
        Root cause this closes (real VM run k8shakedown-rangea-20260829-084343,
        independent review): the Rule query used `term` directly on `signal`
        /`src_ip`/`dst_ip`, but the actual ot-signals-zone-violation-*
        mapping declares them `text` with a `.keyword` multi-field -- a
        `term` query against the analyzed `text` field does not reliably
        match the exact stored value, so the Rule stage silently came back
        "No alert" regardless of whether zone_violation.py had actually
        written a matching document. The query ALSO never constrained
        `source_dnp3_doc_id` at all, so even a successful match would not
        have mechanically enforced the frozen correlation requirement.

        Fix: `signal.keyword`/`src_ip.keyword`/`dst_ip.keyword` exact-match
        terms, AND a `terms` filter on `source_dnp3_doc_id.keyword` set to
        the COMPLETE accepted Collector hit-ID set (every _id the Collector
        query returned -- never a post hoc single chosen document, per
        freeze-decision-table.md SS3). This makes the frozen Rule selector's
        correlation requirement part of the query itself, not something
        checked only afterward. Both index mappings are gated (fail-closed,
        not just retained) BEFORE either query runs, so a future mapping
        drift STOPs here with a clear diagnostic instead of silently
        producing another false "No alert".
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('a','b')][string] $Range,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence,
        [Parameter(Mandatory)][string] $WindowStart,
        [Parameter(Mandatory)][string] $WindowEnd
    )
    $envDir = Join-Path $RunEvidence 'environment'
    $collectorResponse = Join-Path $RunEvidence 'collector-output\collector-response.json'
    $ruleResponse = Join-Path $RunEvidence 'rule-output\rule-response.json'
    $collectorMapping = Join-Path $RunEvidence 'collector-output\collector-index-mapping.json'
    $ruleMapping = Join-Path $RunEvidence 'rule-output\rule-index-mapping.json'
    # README SS5.1 step 6: "retain the Collector and Rule queries with their
    # responses and mappings."
    Invoke-K8ElasticsearchRequest -RunId $RunId -ComposePath $ComposePath -Method GET -Endpoint 'ot-logs-dnp3-*/_mapping' -OutputPath $collectorMapping
    Invoke-K8ElasticsearchRequest -RunId $RunId -ComposePath $ComposePath -Method GET -Endpoint 'ot-signals-zone-violation-*/_mapping' -OutputPath $ruleMapping

    # Mechanically verify the frozen selector's exact-match fields BEFORE
    # either query is trusted -- fail-closed on drift, for both ranges (not
    # only when Range B's R-OBS-05 happens to share the same ot-logs-dnp3-*
    # index and field set).
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $PSScriptRoot 'k8_shakedown_evidence.py'), 'collector-mapping-gate', '--mapping', $collectorMapping, '--output', (Join-Path $RunEvidence 'collector-output\collector-selector-mapping-gate.json')) -Description 'Collector selector exact-match mapping gate'
    # `rule-mapping-gate` PASSes (exit 0) both when the Rule index exists
    # with correct field types AND when it does not exist at all -- the
    # Rule alert index is created LAZILY by zone_violation.py only on its
    # first actual alert write (confirmed against the pinned Amenonuboco
    # source), so a genuinely negative run (Range B's frozen expected Rule
    # output is "No alert", scoring.md SS3) never creates it. Only a
    # real field/type drift on an EXISTING index still fails closed. The
    # retained gate file's own `index_present` field is the authoritative
    # record of which case occurred; log it here so the console transcript
    # states the same distinction the retained JSON does, not just PASS.
    $ruleMappingGatePath = Join-Path $RunEvidence 'rule-output\rule-selector-mapping-gate.json'
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $PSScriptRoot 'k8_shakedown_evidence.py'), 'rule-mapping-gate', '--mapping', $ruleMapping, '--output', $ruleMappingGatePath) -Description 'Rule selector exact-match mapping gate (signal/src_ip/dst_ip/source_dnp3_doc_id)'
    $ruleMappingGateResult = Get-Content $ruleMappingGatePath -Raw | ConvertFrom-Json
    if (Get-K8ObjectPropertyValue -Object $ruleMappingGateResult -Name 'index_present') {
        Write-K8ShakedownLog -Message 'Rule selector mapping gate PASS: ot-signals-zone-violation-* exists with the required signal/src_ip/dst_ip/source_dnp3_doc_id .keyword shape.'
    }
    else {
        Write-K8ShakedownLog -Message 'Rule selector mapping gate PASS: ot-signals-zone-violation-* does not exist yet (no alert has ever been written) -- this is a valid state, not a failure; the Rule query below will observe 0 hits, not an error.'
    }

    Invoke-K8ElasticsearchRequest -RunId $RunId -ComposePath $ComposePath -Method POST -Endpoint 'ot-logs-dnp3-*/_search' -Body (Get-Content (Join-Path $envDir 'collector-query.json') -Raw) -OutputPath $collectorResponse

    # The Rule query cannot be finalized until the Collector response is
    # known: it must filter on the COMPLETE accepted Collector hit-ID set,
    # read back mechanically, never a post hoc single chosen document.
    $collectorIds = Get-K8CollectorHitIds -CollectorResponsePath $collectorResponse
    # `ConvertTo-Json -AsArray` on an EMPTY input produces an empty STRING,
    # not the literal `[]` -- a zero-Collector-hit run is a valid observed
    # state (see Get-K8CollectorHitIds), and substituting an empty string
    # into the Rule query would produce invalid JSON, not a valid "match
    # nothing" terms filter. Must special-case zero explicitly.
    $collectorIdsJson = if ($collectorIds.Count -eq 0) { '[]' } else { ($collectorIds | ConvertTo-Json -AsArray -Compress -Depth 3) }
    $collectorIdsJson | Set-Content -Path (Join-Path $RunEvidence 'collector-output\accepted-collector-hit-ids.json') -Encoding utf8NoBOM
    $ruleQuery = (Get-Content (Join-Path $PSScriptRoot 'rule-query.template.json') -Raw).
        Replace('<WINDOW_START>', $WindowStart).Replace('<WINDOW_END>', $WindowEnd).
        Replace('"<COLLECTOR_HIT_IDS_JSON>"', $collectorIdsJson)
    $ruleQuery | Set-Content -Path (Join-Path $envDir 'rule-query.json') -Encoding utf8NoBOM
    Write-K8ShakedownLog -Message "Rule request finalized against $($collectorIds.Count) accepted Collector hit ID(s)."

    Invoke-K8ElasticsearchRequest -RunId $RunId -ComposePath $ComposePath -Method POST -Endpoint 'ot-signals-zone-violation-*/_search' -Body $ruleQuery -OutputPath $ruleResponse
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $PSScriptRoot 'k8_shakedown_evidence.py'), 'target-correlation', '--collector', $collectorResponse, '--rule', $ruleResponse, '--output', (Join-Path $RunEvidence 'rule-output\collector-rule-correlation.json')) -Description 'retain complete Collector hit IDs and mechanically verify every Rule hit correlates'
    if ($Range -eq 'b') {
        $mappingPath = Join-Path $RunEvidence 'contract-output\r-obs-05-mapping-response.json'
        $mappingDecision = Join-Path $RunEvidence 'contract-output\r-obs-05-mapping-gate.json'
        Invoke-K8ElasticsearchRequest -RunId $RunId -ComposePath $ComposePath -Method GET -Endpoint 'ot-logs-dnp3-*/_mapping' -OutputPath $mappingPath
        Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $PSScriptRoot 'k8_shakedown_evidence.py'), 'mapping-gate', '--mapping', $mappingPath, '--output', $mappingDecision) -Description 'R-OBS-05 exact mapping field/type gate'
        $response = Join-Path $RunEvidence 'contract-output\r-obs-05-response.json'
        Invoke-K8ElasticsearchRequest -RunId $RunId -ComposePath $ComposePath -Method POST -Endpoint 'ot-logs-dnp3-*/_search' -Body (Get-Content (Join-Path $envDir 'r-obs-05-query.json') -Raw) -OutputPath $response
        Write-K8Robs05ContractReference -RunEvidence $RunEvidence -Study01Root (Join-Path (Get-K8ShakedownState).repo_root 'Study01') | Out-Null
        $frames = Write-K8UnrelatedPcapRows -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence
        Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $PSScriptRoot 'k8_shakedown_evidence.py'), 'r-obs-05', '--response', $response, '--frames', $frames, '--window-start', $WindowStart, '--window-end', $WindowEnd, '--output', (Join-Path $RunEvidence 'contract-output\r-obs-05-correlation.json')) -Description 'R-OBS-05 exact integer-nanosecond pcap/document correlation'
    }
}

function Resolve-K8GatewayInterface {
    <#
        Frozen procedure: c2-dnp3-range-derivation.md SS3 resolves the
        unique wan_router interface carrying $C.GatewayCidr via
        `ip -o -4 addr show | awk '/<cidr>/ {print $2}' | head -n 1`. This
        is NOT the same procedure as c2-dnp3-capture-procedure.md's own
        `ip -br addr`-based capture-context resolution -- that is a
        different command, for a different purpose (Ground Truth/
        tap_observer capture context), executed by the frozen
        study01_capture.py `resolve` subcommand itself and never
        reimplemented here.

        Root cause this closes (real VM Range B fault STOP: "Cannot find
        device \"UP\""): this function's prior implementation borrowed
        `ip -br addr`'s column layout (<ifname> <state> <addr>...) instead
        of the actually-frozen `ip -o -4 addr show` oneline layout, and
        read column index [1] -- `ip -br addr`'s STATE field
        ("UP"/"DOWN"/"UNKNOWN"), not an interface name. Every `tc qdisc
        del` therefore targeted a Linux operstate token, never a real
        device -- confirmed against real iproute2 output shapes, not
        assumed.

        Fix: the actually-frozen `ip -o -4 addr show` (oneline format,
        field index [1] 0-based == the interface token, matching the
        frozen `awk '{print $2}'` 1-indexed field exactly), parsed IN
        POWERSHELL rather than through a nested `sh -lc '... | awk ... |
        head -n1'` pipeline -- this avoids the docker-exec/sh/awk quoting
        fragility entirely, and keeps stdout/stderr genuinely separated
        (Invoke-K8SeparatedNativeCapture) instead of merged via `2>&1`, so
        a stray container-startup stderr line can never be mistaken for a
        candidate address line. `head -n 1` in the frozen illustrative
        snippet silently takes the first of several candidates; this
        implementation instead requires EXACTLY ONE matching line and
        fails closed on zero or multiple, matching the frozen wording
        itself ("the UNIQUE wan_router interface", c2-dnp3-step4-range-b-
        fault-pilot.md) and the parallel zero-or-multiple-fails-closed rule
        already frozen for Ground Truth's own resolution.

        Beyond the frozen procedure (Shakedown-added defense, not a
        protocol change): the resolved token must not be empty and must
        not be one of the well-known Linux operstate tokens (UP/DOWN/
        UNKNOWN/etc. -- exactly the defect class that reached a real VM),
        AND a SEPARATE, independent `ip -o -4 addr show dev <token>` query
        must confirm the token names a real interface that actually
        carries the target CIDR, before this value is ever handed to `tc
        qdisc del`. This general-purpose re-verification is the real
        backstop: it would have caught "UP" (no such interface exists)
        even without the specific-token denylist, and it catches any other
        parsing anomaly this function's own author did not anticipate.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence
    )
    $C = Get-K8ShakedownConstants
    $router = (docker compose -p $RunId -f $ComposePath ps -q wan_router | Out-String).Trim()
    $observer = (docker compose -p $RunId -f $ComposePath ps -q tap_observer | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($router) -or [string]::IsNullOrWhiteSpace($observer)) {
        throw "wan_router or tap_observer container was not resolved for $RunId; not starting a helper, not triggering."
    }
    $contractDir = Join-Path $RunEvidence 'contract-output'
    New-Item -ItemType Directory -Force -Path $contractDir | Out-Null
    $evidencePath = Join-Path $contractDir 'gateway-interface-resolution.txt'

    # STDOUT/STDERR captured SEPARATELY: a stray stderr line must never be
    # treated as a candidate address line.
    $addrCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('exec', $router, 'ip', '-o', '-4', 'addr', 'show')
    $addrLines = @($addrCapture.Stdout)
    "exit $($addrCapture.ExitCode)`nstdout:`n$($addrLines -join "`n")`nstderr:`n$($addrCapture.Stderr.Trim())" |
        Set-Content -Path $evidencePath -Encoding utf8NoBOM
    if ($addrCapture.ExitCode -ne 0) {
        throw "'ip -o -4 addr show' failed inside wan_router (exit $($addrCapture.ExitCode)); not starting a helper, not triggering. See $evidencePath."
    }

    $gatewayMatches = @($addrLines | Where-Object { $_ -match [regex]::Escape($C.GatewayCidr) })
    if ($gatewayMatches.Count -ne 1) {
        throw "Gateway interface resolution: expected exactly 1 line containing $($C.GatewayCidr), found $($gatewayMatches.Count). Not starting a helper, not triggering. See $evidencePath."
    }
    $fields = @($gatewayMatches[0] -split '\s+' | Where-Object { $_ })
    if ($fields.Count -lt 2) {
        throw "Gateway interface resolution: matching line does not have the expected 'ip -o -4 addr show' field shape ('<idx>: <ifname> inet <addr>/<prefix> ...'): $($gatewayMatches[0]). See $evidencePath."
    }
    $token = $fields[1]
    $resolvedIf = ($token -split '@', 2)[0]

    $badTokens = @('UP', 'DOWN', 'UNKNOWN', 'LOWERLAYERDOWN', 'DORMANT', 'NOTPRESENT', 'TESTING', 'inet', 'inet6')
    if ([string]::IsNullOrWhiteSpace($resolvedIf) -or $badTokens -ccontains $resolvedIf) {
        throw "Gateway interface resolution produced an implausible value ('$resolvedIf') from token '$token' -- this looks like a state/address-family token, not an interface name. Not starting a helper, not triggering. See $evidencePath."
    }

    # Independent re-verification, BEFORE this value is trusted for fault
    # injection: query the resolved NAME directly and confirm it is a real
    # interface that actually carries the target CIDR.
    $verifyCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('exec', $router, 'ip', '-o', '-4', 'addr', 'show', 'dev', $resolvedIf)
    $verifyLines = @($verifyCapture.Stdout)
    $verifyOk = ($verifyCapture.ExitCode -eq 0) -and (@($verifyLines | Where-Object { $_ -match [regex]::Escape($C.GatewayCidr) }).Count -gt 0)
    "exit $($addrCapture.ExitCode)`nstdout:`n$($addrLines -join "`n")`nstderr:`n$($addrCapture.Stderr.Trim())`n`n--- independent re-verification: ip -o -4 addr show dev $resolvedIf ---`nexit $($verifyCapture.ExitCode)`nstdout:`n$($verifyLines -join "`n")`nstderr:`n$($verifyCapture.Stderr.Trim())" |
        Set-Content -Path $evidencePath -Encoding utf8NoBOM
    if (-not $verifyOk) {
        throw "Gateway interface resolution: resolved value '$resolvedIf' could not be independently re-verified as a real interface carrying $($C.GatewayCidr) (exit $($verifyCapture.ExitCode)). Not starting a helper, not triggering. See $evidencePath."
    }

    Write-K8ShakedownLog -Message "Resolved and independently re-verified gateway interface: $resolvedIf (from token '$token')"
    return [pscustomobject]@{ Router = $router; Observer = $observer; Interface = $resolvedIf }
}

# ---------------------------------------------------------------------------
# T0-relative timing gates (independent review round 5, BLOCKER)
#
# ROOT CAUSE, confirmed against the frozen source, not assumed: this module
# previously called `study01_capture.py stop-export` immediately after the
# sender, commented "covers the settle window internally per capture.py".
# That comment was simply wrong. Study01/studies/study-01-negative-result/
# scripts/study01_capture.py's own docstring says "Run `stop-export` only
# after `T0 + 15 s`" -- stop_export() itself contains no wait at all; the
# 15s wait is entirely the CALLER's responsibility. capture_lifecycle.py's
# validate() enforces this by requiring the window-end-liveness-check step's
# own START timestamp to be >= T0 + 15s. A real VM run
# (k8shakedown-rangea-20260829-021350) called stop-export ~13.465s too
# early and the frozen validator correctly rejected it:
#   "helper liveness was not observed at or after the window end
#    (2026-08-29T02:17:14.197604+00:00 < 2026-08-29T02:17:27.662946+00:00)"
#
# Auditing the SAME class of bug at the OTHER edge of the frozen window
# (the window-START requirement, capture_lifecycle.py: each stage's
# listening-check must COMPLETE at or before T0 - 5s) found it was ALSO
# only true "by luck" -- this runner's prior code relied on the sender-prep
# docker exec round trips (mkdir, docker cp, sha256sum) happening to take
# at least 5 seconds after the last listening-check, with no explicit
# guarantee. On a fast host that gap could plausibly be under 5 seconds,
# which would fail the SAME validator the SAME way, just at the other edge.
# Wait-K8CaptureWindowStart closes that proactively, before it was ever hit
# on a real run.
#
# Neither gate ever re-sends the sender, retries a capture step, or changes
# WINDOW_LEAD/WINDOW_TAIL (5s/15s) -- both are read from
# capture_lifecycle.py's own frozen values in spirit (hardcoded here as the
# same 5/15 since this is PowerShell, not importing Python), never widened,
# and both fail closed on a missing/malformed/offset-less timestamp rather
# than silently proceeding.
# ---------------------------------------------------------------------------

function Wait-K8CaptureWindowStart {
    <#
        Frozen requirement: capture_lifecycle.py's validate() requires each
        capture stage's OWN retained "listening-check" step to have
        COMPLETED (`completed_at`) at or before T0 - 5s. T0 does not exist
        yet at this point (it is stamped by study01_sender.py at the moment
        it actually sends), so this reads back the real retained completion
        timestamp for BOTH stages' listening-check (never a guessed
        wall-clock mark) and waits, if needed, until at least 5s (plus a
        small safety margin) have elapsed since the LATER of the two --
        guaranteeing that whenever the sender ends up stamping T0, the
        already-completed listening-checks are mechanically at or before
        T0 - 5s. Never retries a capture step and never touches the sender.
    #>
    param(
        [Parameter(Mandatory)][string] $RunEvidence,
        [double] $MarginSeconds = 0.5
    )
    $lifecyclePaths = @(
        (Join-Path $RunEvidence 'ground-truth\independent-capture\capture-lifecycle.json'),
        (Join-Path $RunEvidence 'sensor-input\mirror-capture\capture-lifecycle.json')
    )
    $latest = $null
    foreach ($path in $lifecyclePaths) {
        if (-not (Test-Path $path)) {
            throw "capture-lifecycle record not found at $path; cannot confirm the frozen window-start lead time before invoking the sender. Not proceeding."
        }
        $record = Get-Content $path -Raw | ConvertFrom-Json
        $step = $record.steps | Where-Object { $_.step -eq 'listening-check' } | Select-Object -First 1
        if (-not $step -or -not (Get-K8ObjectPropertyValue -Object $step -Name 'completed_at')) {
            throw "no 'listening-check' step with a completed_at timestamp found in $path. Not proceeding."
        }
        try { $completed = [datetimeoffset]::Parse($step.completed_at) }
        catch { throw "listening-check completed_at in $path ('$($step.completed_at)') could not be parsed: $($_.Exception.Message)" }
        if ($null -eq $latest -or $completed -gt $latest) { $latest = $completed }
    }
    $targetSenderNotBefore = $latest.AddSeconds(5).AddSeconds($MarginSeconds)
    $now = [datetimeoffset]::UtcNow
    $remaining = ($targetSenderNotBefore - $now).TotalSeconds
    if ($remaining -gt 0) {
        Write-K8ShakedownLog -Message "Waiting $([Math]::Round($remaining,3))s so both capture stages' listening-check (latest completion: $($latest.ToString('o'))) will be at least 5s before the sender fires (frozen window-start requirement)."
        Start-Sleep -Seconds $remaining
    }
    else {
        Write-K8ShakedownLog -Message "Capture listening-check (latest: $($latest.ToString('o'))) already more than 5s ago; no extra wait needed before the sender."
    }
    $envDir = Join-Path $RunEvidence 'environment'
    New-Item -ItemType Directory -Force -Path $envDir | Out-Null
    [ordered]@{
        latest_listening_check_completed_utc = $latest.ToString('o')
        target_sender_not_before_utc = $targetSenderNotBefore.ToString('o')
        waited_seconds = [Math]::Max(0, $remaining)
        sender_proceeding_utc = ([datetimeoffset]::UtcNow).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $envDir 'capture-window-start-wait.json') -Encoding utf8NoBOM
}

function Wait-K8CaptureWindowEnd {
    <#
        Frozen requirement: Study01/studies/study-01-negative-result/
        scripts/study01_capture.py's own docstring: "Run `stop-export` only
        after `T0 + 15 s`." stop_export() itself has no wait -- it is the
        caller's responsibility, and capture_lifecycle.py's validate()
        enforces it by requiring the window-end-liveness-check step's own
        START timestamp to be >= T0 + 15s.

        Computes T0+15s from the retained metadata-t0.txt (written by
        study01_sender.py at the run evidence root) and sleeps only the
        REMAINING wall-clock time -- never a fixed "sleep N seconds after
        the sender returns" (which would be wrong by exactly however long
        the sender invocation itself took), and never re-sends/retries the
        sender. If wall-clock time already exceeds T0+15s, returns
        immediately with no extra wait.

        Fail-closed on a missing, unparseable, or offset-less T0 artifact.
    #>
    param(
        [Parameter(Mandatory)][string] $RunEvidence,
        [double] $MarginSeconds = 0.5
    )
    $t0Path = Join-Path $RunEvidence 'metadata-t0.txt'
    if (-not (Test-Path $t0Path)) {
        throw "T0 record not found at $t0Path after the sender invocation; cannot compute the T0+15s window end. Not proceeding to stop-export."
    }
    $t0Raw = (Get-Content $t0Path -Raw).Trim()
    if ($t0Raw -notmatch 'Z$|[+-]\d{2}:\d{2}$') {
        throw "T0 record at $t0Path ('$t0Raw') does not carry an explicit UTC offset (no trailing Z or +hh:mm/-hh:mm). Not proceeding to stop-export."
    }
    try { $t0 = [datetimeoffset]::Parse($t0Raw) }
    catch { throw "T0 record at $t0Path could not be parsed as a timestamp ('$t0Raw'): $($_.Exception.Message). Not proceeding to stop-export." }

    $windowEnd = $t0.AddSeconds(15)
    $targetWait = $windowEnd.AddSeconds($MarginSeconds)
    $now = [datetimeoffset]::UtcNow
    $remaining = ($targetWait - $now).TotalSeconds
    if ($remaining -gt 0) {
        Write-K8ShakedownLog -Message "Waiting $([Math]::Round($remaining,3))s for the frozen T0+15s window end (T0=$($t0.ToString('o')), window_end=$($windowEnd.ToString('o'))) before stop-export."
        Start-Sleep -Seconds $remaining
    }
    else {
        Write-K8ShakedownLog -Message "T0+15s window end ($($windowEnd.ToString('o'))) already passed by $([Math]::Round(-$remaining,3))s; not waiting further before stop-export."
    }
    $envDir = Join-Path $RunEvidence 'environment'
    New-Item -ItemType Directory -Force -Path $envDir | Out-Null
    [ordered]@{
        t0 = $t0.ToString('o'); window_end = $windowEnd.ToString('o'); target_wait_with_margin = $targetWait.ToString('o')
        waited_seconds = [Math]::Max(0, $remaining)
        stop_export_proceeding_utc = ([datetimeoffset]::UtcNow).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $envDir 'capture-window-end-wait.json') -Encoding utf8NoBOM
}

function Test-K8CaptureLifecycleEarly {
    <#
        Runs the FROZEN capture_lifecycle.validate()/capture_context.validate()
        functions directly against both stages' already-retained records,
        right after stop-export and BEFORE this runner ever prints "runtime
        evidence PASS" -- so a capture-lifecycle timing violation (the exact
        class of bug this round's fix addresses) surfaces here, not three
        steps later inside Complete-K8ShakedownRange.ps1's pre-teardown
        validate-evidence.

        This is NOT a re-run of `study01_collect.py validate-evidence`: that
        full check also requires metadata.md, deviations.md, and non-empty
        collector-output/rule-output, none of which exist yet at this point
        in the pipeline (they are written later, and populated by the
        Elasticsearch queries that have not run yet). Rather than write
        those prematurely just to satisfy an unrelated check, this imports
        and calls the SAME two frozen validator functions
        study01_collect.py itself uses for the capture-lifecycle portion --
        so the semantics are identical, not reimplemented, just scoped to
        what is actually available this early. The remaining full
        validate-evidence still runs, unchanged, in
        Complete-K8ShakedownRangeAB before teardown.
    #>
    param(
        [Parameter(Mandatory)][string] $ScriptsDir,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $RunEvidence
    )
    $script = @'
import sys, json
sys.path.insert(0, sys.argv[3])
from pathlib import Path
from datetime import datetime
from study01 import capture_context as context
from study01 import capture_lifecycle as lifecycle
from study01.frozen import apparatus

run_evidence = Path(sys.argv[1])
run_id = sys.argv[2]

t0_path = run_evidence / apparatus.T0_ARTIFACT
if not t0_path.is_file():
    raise SystemExit(f"{apparatus.T0_ARTIFACT} not found at {t0_path}")
t0_value = datetime.fromisoformat(t0_path.read_text(encoding="utf-8").strip().replace("Z", "+00:00"))

for stage, spec in apparatus.CAPTURE_STAGES.items():
    context_path = run_evidence / spec["context"]
    lifecycle_path = run_evidence / spec["lifecycle"]
    if not context_path.is_file() or not lifecycle_path.is_file():
        raise SystemExit(f"{stage}: context or lifecycle record missing")
    ctx = context.validate(json.loads(context_path.read_text(encoding="utf-8")), run_id)
    record = json.loads(lifecycle_path.read_text(encoding="utf-8"))
    retained = lifecycle.validate(record, t0_value, ctx)
    if retained["run_id"] != run_id:
        raise SystemExit(f"{stage}: run_id does not match the evidence directory")

print("capture-lifecycle early check: PASS for ground-truth and sensor")
'@
    $tmpScript = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-early-lifecycle-" + [guid]::NewGuid().ToString('N') + '.py')
    Set-Content -Path $tmpScript -Value $script -Encoding utf8NoBOM
    try {
        Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @($tmpScript, $RunEvidence, $RunId, $ScriptsDir) `
            -Description 'early capture-lifecycle check (frozen capture_lifecycle.validate/capture_context.validate, before runtime PASS is reported)'
    }
    finally {
        Remove-Item $tmpScript -ErrorAction SilentlyContinue
    }
}

function Test-K8ScoringInputArtifactCompleteness {
    <#
        Shakedown-specific completeness gate (independent review round 6,
        BLOCKER): a real VM run reached scoring-input with runtime/
        validate-evidence/finalize/teardown/verify-integrity all already
        PASS, only to discover then that README SS5.1 step 6's "decode
        them" had never been implemented at all -- no per-stage
        machine-readable decode of either capture existed anywhere in the
        run. study01_collect.py's validate-evidence cannot catch this
        class of gap: it has no notion that README requires a pcap decode
        artifact, only that the schema-defined directories are non-empty
        and the capture-lifecycle/procedure-conformance records are
        internally consistent -- all of which were already true.

        C-6 CHANGED THE SHAPE OF THIS CHECK, NOT ITS PURPOSE. The list of
        required artifacts used to live here, inline, and this was the only
        place it was ever checked -- so a missing artifact surfaced far from
        the stage that owed it, and any per-stage check would have had to
        restate the list. The requirement now lives in ONE place,
        $script:K8ArtifactContract, with a producer stage on every row;
        Assert-K8StageArtifacts selects the current stage's rows during the
        run, and this function reads ALL of them at the end. There is no
        second list.

        It stays a Shakedown-side check, not a frozen-protocol validator: it
        never scores anything, never decides Pass/Fail for any stage, and a
        file's mere presence is not asserted to prove its content correct
        (that is what the frozen validators, and ultimately the operator's own
        scoring-input transcription, are for). It exists so a missing primary
        artifact is caught before "runtime evidence PASS" is ever printed,
        rather than much later when an operator reaches scoring-input on an
        already-closed, already-torn-down run.

        Because the stage gates now run first, anything this reports is by
        construction something a stage gate should already have caught: treat
        it as a regression defect in the stage gate, not as a late discovery.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('a', 'b')][string] $Range,
        [Parameter(Mandatory)][string] $RunEvidence
    )
    Assert-K8RunArtifactCompleteness -Range $Range -RunEvidence $RunEvidence
}

function Invoke-K8ShakedownRangeAB {
    <#
        Thin lifecycle shell around the Range A/B body.

        The run ID and its provenance are issued by Start-K8ShakedownRun BEFORE
        this enters the boundary, so a run that is refused -- or that dies at
        stage one -- still leaves a machine-readable record naming the tooling it
        ran under. The body itself never allocates a run ID.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('a', 'b')][string] $Range
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $state = Get-K8ShakedownState
    $run = Start-K8ShakedownRun -Range $Range -RepoRoot $state.repo_root
    return Invoke-K8ShakedownRunBoundary -Run $run -ScriptBlock {
        Invoke-K8ShakedownRangeABBody -Range $Range -Run $run
    }.GetNewClosure()
}

function Invoke-K8ShakedownRangeABBody {
    param(
        [Parameter(Mandatory)][ValidateSet('a', 'b')][string] $Range,
        [Parameter(Mandatory)] $Run
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $state = Get-K8ShakedownState
    $C = Get-K8ShakedownConstants
    $Study01 = Join-Path $state.repo_root 'Study01'
    $ScriptsDir = Join-Path $Study01 'studies\study-01-negative-result\scripts'
    $SenderAssetHost = Join-Path $ScriptsDir '..\experiments\shared\traffic\send_direct_operate.py' | Resolve-Path
    $WorktreeDir = $state.amenonuboco_gen_dir

    $RunId = $Run.RunId
    $RunEvidence = Join-Path $state.shakedown_root "runs\$RunId"
    $ComposeFile = "power-grid-reference.range-$Range.docker-compose.yml"
    $ComposePath = Join-Path $WorktreeDir "manifests\$ComposeFile"

    Write-K8ShakedownLog -Level STEP -Message "=== Shakedown Range $($Range.ToUpper()) starting: $RunId ==="

    # 0. C-2b binding gate, before ANY scientific or runtime step. It re-observes
    # git rather than comparing stored values, so a checkout or edit made after
    # this run was initialized is caught here and not later.
    Set-K8ShakedownRunStage -Stage 'sequence-binding'
    Assert-K8SequenceBinding -Run $Run

    # 1. Run evidence tree, via the frozen evidence_tree.create() -- not reimplemented here.
    Set-K8ShakedownRunStage -Stage 'evidence-tree'
    $createScript = "import sys; sys.path.insert(0, r'$ScriptsDir'); from pathlib import Path; from study01.evidence_tree import create; create(Path(r'$RunEvidence'))"
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @('-c', $createScript) -Description 'run evidence tree (frozen evidence_tree.create)'

    # 1a. Mirror the pre-tree provenance into the evidence tree the instant the
    # frozen creator has made it. At the tree ROOT: the frozen preflight requires
    # the eight schema directories to be empty, and finalize-evidence hashes the
    # root, so this file is covered by the manifest and never rewritten after.
    Copy-K8RunProvenanceIntoEvidence -Run $Run -RunEvidence $RunEvidence
    # C-6: the tree exists, so the stage-boundary gate can be armed. From here
    # on, leaving a stage checks that stage's contracted artifacts. Armed after
    # the provenance mirror so the evidence-tree stage's own row is satisfiable.
    Set-K8ShakedownRunEvidence -Path $RunEvidence | Out-Null

    # 2. Generate the Compose file fresh for this run (never reuse a stale one).
    Set-K8ShakedownRunStage -Stage 'compose-generate'
    Push-Location $WorktreeDir
    try {
        Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @('platform/cli.py', 'provision', 'manifests/power-grid-reference.yaml', '-o', "manifests/$ComposeFile") `
            -Description "generate Range $($Range.ToUpper()) Compose file"
    }
    finally { Pop-Location }
    $envDir = Join-Path $RunEvidence 'environment'
    $composeHash = (Get-FileHash -Path $ComposePath -Algorithm SHA256).Hash

    # 3. Execution preflight gate -- do not provision if this fails.
    Set-K8ShakedownRunStage -Stage 'preflight'
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @(
        (Join-Path $ScriptsDir 'study01_preflight.py'),
        '--run-id', $RunId, '--worktree', $WorktreeDir, '--compose', $ComposePath,
        '--run-evidence', $RunEvidence, '--project-name', $RunId, '--teardown-target', $RunId,
        '--shell-probe', $PSVersionTable.PSVersion.ToString(),
        '--path-probe', '/study/traffic/send_direct_operate.py', '/data/c2-original-path.pcap', '/data/c2-mirror-sensor.pcap'
    ) -Description 'execution preflight gate (Docker-free)' |
        ForEach-Object { (@($_.Output) -join "`n") | Set-Content -Path (Join-Path $envDir 'preflight.txt') -Encoding utf8NoBOM }

    # The frozen preflight requires every runtime evidence directory to be
    # empty at invocation time. Retain the generated Compose hash only after
    # that freshness gate has passed; writing it earlier invalidates the run.
    "generated compose SHA-256 (within-run integrity record only, per c2-dnp3-range-derivation.md SS2.2): $composeHash" |
        Set-Content -Path (Join-Path $envDir 'generated-compose-hash.txt') -Encoding utf8NoBOM

    # 3a. Network pool-conflict preflight -- BEFORE `compose up`, never
    # after. A leftover network from an older, abandoned k8shakedown-range*
    # run holding this run's same fixed subnet would otherwise only surface
    # as `docker compose up`'s own opaque "invalid pool request: Pool
    # overlaps with other one on this address space" failure. Read-only:
    # never removes/prunes a network itself.
    Set-K8ShakedownRunStage -Stage 'network-preflight'
    Test-K8ShakedownNetworkPreflight -RunId $RunId -ComposePath $ComposePath

    # 4. Provision. Compose build output is intentionally kept outside the
    # scientific evidence tree as a per-run Shakedown runtime/debug log.
    Set-K8ShakedownRunStage -Stage 'provision'
    $buildLog = Join-Path $state.shakedown_root "runtime-logs\$RunId\docker-compose-up-build.log"
    Invoke-K8ShakedownLoggedCommand -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'up', '-d', '--build') `
        -LogPath $buildLog -Description "provision Range $($Range.ToUpper())" | Out-Null

    # 4a. Environment readiness: wait for every defined service to report a
    # running state before doing anything else (README SS5.1 step 4:
    # "establish readiness ... before the event window opens"). Fails closed
    # on timeout rather than proceeding against a half-up stack.
    Set-K8ShakedownRunStage -Stage 'compose-readiness'
    Wait-K8ComposeReady -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence

    # 4a-2. APPLICATION readiness, shared identically by Range A and Range B,
    # run this early (before image inventory, the fault, capture, and the
    # sender trigger) precisely because container 'running' state proves
    # none of these three: that Elasticsearch's HTTP endpoint is accepting
    # connections and can serve a search (Wait-K8ElasticsearchReady), that
    # log_structurer's own apt-get-installed tshark|bulk_loader DNP3 pipeline
    # has actually started (Wait-K8LogStructurerReady), or that
    # zone_detector's own pip-installed signal-1-zone-violation plugin
    # process has actually started (Wait-K8ZoneDetectorReady). All three
    # services are present in BOTH Range A and Range B's generated manifest
    # (same base manifest per c2-dnp3-range-derivation.md SS1), so all three
    # gates run for both Ranges from these same three call sites -- not
    # duplicated, not Range-specific. See each function's own docstring for
    # the real VM failure / pinned-source root cause it closes.
    Set-K8ShakedownRunStage -Stage 'application-readiness'
    Wait-K8ElasticsearchReady -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence
    Wait-K8LogStructurerReady -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence
    Wait-K8ZoneDetectorReady -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence

    # 4b. Full image inventory (c2-dnp3-image-inventory.md SS4), before trigger:
    # per-service image reference/ID from `compose images`, THEN `docker image
    # inspect` on each resolved ID for its immutable Id + RepoDigests, exactly
    # as the frozen collection command specifies -- not just the compose-level
    # summary.
    Set-K8ShakedownRunStage -Stage 'image-inventory'
    Write-K8ImageInventory -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence

    # 5. Resolve gateway interface (needed for capture AND, on Range B, the fault).
    Set-K8ShakedownRunStage -Stage 'gateway-resolution'
    $gw = Resolve-K8GatewayInterface -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence

    # 6. Range B only: the sole permitted fault.
    if ($Range -eq 'b') {
        Set-K8ShakedownRunStage -Stage 'fault-injection'
        Write-K8ShakedownLog -Level STEP -Message '--- Range B fault: deleting ingress qdisc on the resolved gateway interface ---'
        $contractDir = Join-Path $RunEvidence 'contract-output'
        New-Item -ItemType Directory -Force -Path $contractDir | Out-Null

        # Frozen c2-dnp3-range-derivation.md SS3 command order, each observation
        # now retained with argv/exit/stdout/stderr/stdout_empty/timestamp.
        # The artifact is written BEFORE the exit-code assertion so a failing
        # command still leaves its own diagnostic behind.
        $preObservations = @(
            (Invoke-K8FaultObservationCommand -Label 'pre-fault: tc qdisc show' -Argv @('docker', 'exec', $gw.Router, 'tc', 'qdisc', 'show', 'dev', $gw.Interface))
            (Invoke-K8FaultObservationCommand -Label 'pre-fault: tc filter show parent ffff:' -Argv @('docker', 'exec', $gw.Router, 'tc', 'filter', 'show', 'dev', $gw.Interface, 'parent', 'ffff:'))
        )
        Write-K8FaultObservationArtifact -Observations $preObservations -RunEvidence $RunEvidence `
            -ArtifactRelativePath 'contract-output\qdisc-pre-fault.txt' -Title 'Range B pre-fault observation (target gateway interface)' `
            -RunId $RunId -Range $Range -Stage 'fault-injection'
        Assert-K8FaultObservationsSucceeded -Observations $preObservations -Stage 'pre-fault observation'

        # The sole permitted fault. Its own argv/exit/stdout/stderr are now
        # retained too (frozen SS3 "Preserve pre/post command output"); this
        # adds no new scientific acceptance condition.
        $faultObservations = @(
            (Invoke-K8FaultObservationCommand -Label 'fault: tc qdisc del ingress (the sole permitted fault)' -Argv @('docker', 'exec', $gw.Router, 'tc', 'qdisc', 'del', 'dev', $gw.Interface, 'ingress'))
        )
        Write-K8FaultObservationArtifact -Observations $faultObservations -RunEvidence $RunEvidence `
            -ArtifactRelativePath 'contract-output\fault-injection-command.txt' -Title 'Range B fault injection command' `
            -RunId $RunId -Range $Range -Stage 'fault-injection'
        Assert-K8FaultObservationsSucceeded -Observations $faultObservations -Stage 'fault injection'

        # Post-fault. An empty stdout here is the frozen SS4 check-2 success
        # shape ("no remaining target-segment mirror filter"), NOT a missing
        # artifact -- the file is always written and records stdout_empty.
        $postObservations = @(
            (Invoke-K8FaultObservationCommand -Label 'post-fault: tc filter show parent ffff:' -Argv @('docker', 'exec', $gw.Router, 'tc', 'filter', 'show', 'dev', $gw.Interface, 'parent', 'ffff:'))
        )
        Write-K8FaultObservationArtifact -Observations $postObservations -RunEvidence $RunEvidence `
            -ArtifactRelativePath 'contract-output\qdisc-post-fault.txt' -Title 'Range B post-fault observation (target gateway interface)' `
            -RunId $RunId -Range $Range -Stage 'fault-injection'
        Assert-K8FaultObservationsSucceeded -Observations $postObservations -Stage 'post-fault observation'
        if ($postObservations[0].StdoutEmpty) {
            Write-K8ShakedownLog -Message 'Range B post-fault: tc filter show returned exit 0 with no remaining filter on the target interface. Retained as an observation (stdout_empty=true); the scored Runtime Contract judgment remains the operator''s at scoring-input.'
        }

        Assert-K8UnrelatedMirrorFilter -Gateway $gw -RunEvidence $RunEvidence -RunId $RunId -Range $Range -Stage 'fault-injection'
    }

    # 6a. Runtime contract observational record (evidence-schema.md SS3: "Range
    # A/B runtime-invariant record in contract-output/"). This retains what is
    # mechanically observable; it is NOT the scored Runtime Contract
    # Pass/Fail/Unresolved verdict itself -- that is derived by the operator at
    # scoring-input time (README SS6.2), from this record plus the other
    # stages.
    Set-K8ShakedownRunStage -Stage 'runtime-contract-record'
    Write-K8RuntimeContractRecord -Range $Range -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence -Gateway $gw

    # 7. Capture: resolve then start, both stages, in this fixed order.
    Set-K8ShakedownRunStage -Stage 'capture-start'
    foreach ($stage in @('ground-truth', 'sensor')) {
        Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @(
            (Join-Path $ScriptsDir 'study01_capture.py'), 'resolve',
            '--run-id', $RunId, '--run-evidence', $RunEvidence, '--stage', $stage, '--compose', $ComposePath
        ) -Description "capture context resolve: $stage"
    }
    foreach ($stage in @('ground-truth', 'sensor')) {
        Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @(
            (Join-Path $ScriptsDir 'study01_capture.py'), 'start',
            '--run-id', $RunId, '--run-evidence', $RunEvidence, '--stage', $stage
        ) -Description "capture helper start: $stage"
    }
    # 7-aux. Range B only: the auxiliary R-OBS-05 liveness capture the frozen
    # contract SS4 requires. Started here so it covers the same
    # [T0-5s, T0+15s] window as the two frozen stages, and entirely AFTER the
    # Range B fault (step 6) so it witnesses post-fault mirror liveness --
    # which is exactly what R-OBS-05 is a control for. Passive capture only:
    # it injects no traffic and alters no routing, qdisc, filter, or service,
    # so the frozen Range B experimental condition is untouched. Range A's
    # runtime behavior is unchanged (this block never runs for Range A).
    if ($Range -eq 'b') {
        Start-K8Robs05LivenessCapture -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence
    }

    # 7a. Frozen window-start requirement: both stages' listening-check must
    # have COMPLETED at least 5s before T0 (which the sender is about to
    # stamp). Waits only the remaining time actually needed; never touches
    # the sender.
    Set-K8ShakedownRunStage -Stage 'window-start'
    Wait-K8CaptureWindowStart -RunEvidence $RunEvidence

    # 8. Sender: directory prep -> docker cp -> hash verify -> exactly one invocation.
    Set-K8ShakedownRunStage -Stage 'sender-trigger'
    $senderContainer = (docker compose -p $RunId -f $ComposePath ps -q sub_a_ied_02 | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($senderContainer)) { throw 'sub_a_ied_02 container was not resolved' }
    Invoke-K8ShakedownCommand -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'exec', '-T', 'sub_a_ied_02', 'sh', '-lc', 'mkdir -p /study/traffic') `
        -Description 'sender directory preparation'
    Invoke-K8ShakedownCommand -FilePath 'docker' -ArgumentList @('cp', $SenderAssetHost.Path, "${senderContainer}:$($C.SenderAssetInContainerPath)") `
        -Description 'sender asset placement (docker cp is the only permitted mechanism)'
    $shaOut = (docker compose -p $RunId -f $ComposePath exec -T sub_a_ied_02 sh -lc "sha256sum $($C.SenderAssetInContainerPath)" | Out-String)
    $inContainerSha = ($shaOut.Trim().Split()[0]).ToUpperInvariant()
    if ($inContainerSha -ne $C.SenderAssetSha256) {
        throw "sender hash mismatch: expected $($C.SenderAssetSha256), got $inContainerSha"
    }
    Write-K8ShakedownLog -Message "sender asset hash verified in-container: $inContainerSha"

    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @(
        (Join-Path $ScriptsDir 'study01_sender.py'), '--run-id', $RunId, '--run-evidence', $RunEvidence, '--',
        'docker', 'compose', '-p', $RunId, '-f', $ComposePath, 'exec', '-T', 'sub_a_ied_02',
        'python3', $C.SenderAssetInContainerPath, '--target-ip', '10.1.10.10', '--target-port', '20000', '--function-code', '5', '--repeat', '1'
    ) -Description 'the one frozen trigger invocation (T0)'

    # 8a. Frozen window-end requirement: `stop-export` must not run before
    # T0+15s (study01_capture.py's own docstring; stop_export() itself has
    # no wait). Waits only the remaining time actually needed; never
    # re-sends the sender.
    Set-K8ShakedownRunStage -Stage 'window-end'
    Wait-K8CaptureWindowEnd -RunEvidence $RunEvidence

    # 9. Stop/export both captures. The T0+15s wait is Wait-K8CaptureWindowEnd's
    # job (above), not this loop's or capture.py's own -- see that function's
    # docstring for the real VM failure this fixed.
    Set-K8ShakedownRunStage -Stage 'capture-stop-export'
    foreach ($stage in @('ground-truth', 'sensor')) {
        Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @(
            (Join-Path $ScriptsDir 'study01_capture.py'), 'stop-export',
            '--run-id', $RunId, '--run-evidence', $RunEvidence, '--stage', $stage
        ) -Description "capture stop/export: $stage"
    }
    # 9-aux. Range B only: window-end liveness check, stop, export, hash and
    # remove the auxiliary R-OBS-05 helper. Runs after Wait-K8CaptureWindowEnd
    # so its liveness check is genuinely at/after T0+15s, and before teardown
    # so no helper survives the range (c2-dnp3-capture-procedure.md SS5).
    if ($Range -eq 'b') {
        Complete-K8Robs05LivenessCapture -RunId $RunId -RunEvidence $RunEvidence
    }

    # 9a. Frozen capture-lifecycle check, reusing the same validator functions
    # study01_collect.py itself uses, scoped to what already exists at this
    # point (both stages' context+lifecycle records and T0) -- so a timing
    # violation surfaces here, before this runner ever reports "runtime
    # evidence PASS", not only later inside Complete's pre-teardown
    # validate-evidence. Full validate-evidence still cannot run yet
    # (metadata.md/deviations.md/collector-output/rule-output do not exist
    # until later steps); this is not a substitute for it, and
    # Complete-K8ShakedownRangeAB's own pre-teardown validate-evidence call
    # is unchanged.
    Set-K8ShakedownRunStage -Stage 'capture-lifecycle-check'
    Test-K8CaptureLifecycleEarly -ScriptsDir $ScriptsDir -RunId $RunId -RunEvidence $RunEvidence

    # 10. Resolve the frozen event window from retained T0. Its own stage: it
    # writes nothing, and the stage that follows must own what IT writes.
    # (Previously this was marked 'queries', then 'target-decode', then
    # 're-marked' back to 'queries' -- with the query artifacts actually being
    # written during the decode stage. C-6 needs a stage to own its artifacts,
    # so the sequence is now window-resolve -> target-decode -> queries with no
    # re-marking and no artifact written outside its owning stage.)
    Set-K8ShakedownRunStage -Stage 'window-resolve'
    $t0Path = Join-Path $RunEvidence 'metadata-t0.txt'
    if (-not (Test-Path $t0Path)) {
        throw "T0 record not found at $t0Path after stop-export; cannot window the Collector/Rule queries. This is a STOP condition -- do not proceed to teardown without it."
    }
    $t0 = (Get-Content $t0Path -Raw).Trim()
    $windowStart = ([datetimeoffset]::Parse($t0)).AddSeconds(-5).ToString('o')
    $windowEnd = ([datetimeoffset]::Parse($t0)).AddSeconds(15).ToString('o')

    # 9b. README SS5.1 step 6: "decode them" -- both retained pcaps, against
    # the frozen Ground Truth/Sensor selector (freeze-decision-table.md SS3).
    # Must run before Complete's teardown (log_structurer must still be up)
    # and before finalize-evidence (so the artifact is hashed).
    Set-K8ShakedownRunStage -Stage 'target-decode'
    Write-K8TargetCaptureDecode -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence -Stage 'ground-truth' -WindowStartIso $windowStart -WindowEndIso $windowEnd
    Write-K8TargetCaptureDecode -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence -Stage 'sensor' -WindowStartIso $windowStart -WindowEndIso $windowEnd

    # 10a. The query stage owns every request/response/gate artifact it writes.
    Set-K8ShakedownRunStage -Stage 'queries'
    $collectorQuery = (Get-Content (Join-Path $PSScriptRoot 'collector-query.template.json') -Raw).Replace('<WINDOW_START>', $windowStart).Replace('<WINDOW_END>', $windowEnd)
    $collectorQuery | Set-Content -Path (Join-Path $envDir 'collector-query.json') -Encoding utf8NoBOM
    # The Rule request is NOT finalized/written here: freeze-decision-
    # table.md SS3 requires its source_dnp3_doc_id filter to cover the
    # COMPLETE accepted Collector hit-ID set, which is only known once the
    # Collector query has actually run. Invoke-K8AutomatedQueries below
    # reads rule-query.template.json itself, resolves the real IDs from the
    # Collector response, and writes the one true environment/rule-query.json
    # -- writing an incomplete window-only version here first would leave a
    # stale, misleading artifact between this line and that one.
    Write-K8ShakedownLog -Message "Fixed Collector request retained with T0 window [$windowStart, $windowEnd]. Rule request will be retained once the accepted Collector hit-ID set is resolved."

    if ($Range -eq 'b') {
        $r0query = (Get-Content (Join-Path $PSScriptRoot 'r-obs-05-query.template.json') -Raw).Replace('<WINDOW_START>', $windowStart).Replace('<WINDOW_END>', $windowEnd)
        $r0query | Set-Content -Path (Join-Path $envDir 'r-obs-05-query.json') -Encoding utf8NoBOM
        Write-K8ShakedownLog -Message 'Fixed R-OBS-05 request retained; mapping/query/correlation gates will execute mechanically.'
    }

    Invoke-K8AutomatedQueries -Range $Range -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence -WindowStart $windowStart -WindowEnd $windowEnd

    # 10b. Range B check 4's artifacts did not exist when the runtime contract
    # record was written, so that record could only point forward at names.
    # C-7 forbids a generated narrative citing an artifact that is not there,
    # so the pointers are appended now, resolved as typed run-local references
    # against files that now exist.
    if ($Range -eq 'b') {
        Complete-K8RuntimeContractRecord -RunEvidence $RunEvidence
    }

    # 11. metadata.md / deviations.md -- required by study01_collect.py validate-evidence.
    # Templated from facts this runner already retained; free-text additions are still
    # the operator's -- this only removes the mechanical transcription of what the
    # machine-readable records already say. Cleanup is NOT YET performed (see below),
    # so this is updated again by Complete-K8ShakedownRangeAB once it is.
    Set-K8ShakedownRunStage -Stage 'run-metadata'
    # C7-R4: run identity comes from the authoritative structured source (the
    # Batch 1 provenance record), not retyped from a local variable; the pinned
    # Amenonuboco commit comes from the canonical constants; the remaining
    # mechanical values are the ones this run observed directly.
    $identity = Get-K8RunIdentityFacts -RunId $RunId
    @"
# Run metadata -- $RunId (Shakedown, NOT a formal K8-3 attempt, NOT Gate K8 evidence)

| Field | Value |
| --- | --- |
| Range | $($Range.ToUpper()) |
| Compose project / run ID | $($identity.RunId) |
| Qualification sequence | $($identity.SequenceId) |
| Tooling HEAD (locked for this sequence) | $($identity.LockedHead) |
| Compose file | $ComposePath |
| Generated compose SHA-256 (within-run only) | $composeHash |
| Amenonuboco worktree | $WorktreeDir (pinned $($C.RangeGenCommit)) |
| Gateway interface | $($gw.Interface) |
| Sender container | $senderContainer |
| Sender asset in-container SHA-256 | $inContainerSha |
| tcpdump helper image | $($state.tcpdump_image_ref) |
| Cleanup | NOT YET PERFORMED -- all runtime evidence has been exported; pre-teardown validation/hash remains before destruction. |

See environment/, ground-truth/, sensor-input/, contract-output/ for the machine-recorded per-step argv/exit-code/timestamp evidence this table summarizes. (Those are the frozen evidence-tree schema directories created by evidence_tree.create() and required by the frozen validate-evidence, not artifact references.)
"@ | Set-Content -Path (Join-Path $RunEvidence 'metadata.md') -Encoding utf8NoBOM

    $deviationsBody = if ($Range -eq 'b') {
        # C7-R1/R2: the two artifacts named below arrive as TYPED run-local
        # references and are existence-checked before the sentence that cites
        # them is written. Nothing scans this prose for path-shaped text.
        $faultRefs = Get-K8NarrativeReferenceText -RunEvidence $RunEvidence -References @(
            (New-K8ArtifactReference -Kind 'run-local' -Path 'contract-output/qdisc-pre-fault.txt')
            (New-K8ArtifactReference -Kind 'run-local' -Path 'contract-output/qdisc-post-fault.txt')
        )
        "# Deviations -- $RunId`n`nNo unplanned deviations recorded by this runner. The ingress-qdisc deletion on the resolved gateway interface is the frozen Range B experimental condition, not a deviation -- see $($faultRefs[0]) / $($faultRefs[1]).`n"
    } else {
        "# Deviations -- $RunId`n`nNo unplanned deviations recorded by this runner.`n"
    }
    $deviationsBody | Set-Content -Path (Join-Path $RunEvidence 'deviations.md') -Encoding utf8NoBOM

    # 11a. Shakedown-specific completeness gate: every primary artifact
    # README SS5/SS6.2 requires before scoring-input can even be started
    # must exist BEFORE this runner ever reports "runtime evidence PASS" --
    # not discovered only once the operator reaches scoring-input on an
    # already-closed run. study01_collect.py validate-evidence does not
    # catch this class of gap (it does not know README requires a pcap
    # decode at all); this is a Shakedown-side check on top of it.
    Set-K8ShakedownRunStage -Stage 'completeness-gate'
    Test-K8ScoringInputArtifactCompleteness -Range $Range -RunEvidence $RunEvidence

    # 12. Leave the range running only until Complete performs the mandatory
    # pre-teardown validate/finalize gate. No operator query/curl step remains.
    Set-K8ShakedownState -Updates @{
        "range_$($Range)_run_id"      = $RunId
        "range_$($Range)_evidence"    = $RunEvidence
        "range_$($Range)_compose"     = $ComposePath
        "range_$($Range)_stage"       = 'awaiting-completion'
    }

    Write-K8ShakedownLog -Level STEP -Message "=== Shakedown Range $($Range.ToUpper()) runtime evidence PASS, range left running for ordered finalize/teardown: $RunId ==="
    Write-Host ''
    Write-Host "Range $($Range.ToUpper()) run '$RunId' retained all automated runtime evidence. Next:"
    Write-Host "  .\tools\Complete-K8ShakedownRange.ps1 -Range $Range"
    return $RunEvidence
}

function ConvertTo-K8CidrRange {
    <# Returns @(networkAddress, broadcastAddress) as UInt32 for an IPv4
       CIDR string, for range-overlap comparison. Masking is done entirely
       in UInt64 before narrowing to UInt32, because `[uint32](0xFFFFFFFF
       -shl n)` overflows UInt32 directly for any n between 1 and 31 (the
       shift itself is computed in a wider type first). #>
    param([Parameter(Mandatory)][string] $Cidr)
    $parts = $Cidr -split '/'
    if ($parts.Count -ne 2) { throw "not a CIDR (expected address/prefix): '$Cidr'" }
    $ip = [System.Net.IPAddress]::Parse($parts[0].Trim())
    if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { throw "not an IPv4 CIDR: '$Cidr'" }
    $prefix = [int]$parts[1]
    if ($prefix -lt 0 -or $prefix -gt 32) { throw "invalid IPv4 prefix length in '$Cidr'" }
    $bytes = $ip.GetAddressBytes()
    if ([BitConverter]::IsLittleEndian) { [array]::Reverse($bytes) }
    $ipUInt = [BitConverter]::ToUInt32($bytes, 0)
    $fullMask = [uint64]4294967295
    $maskU64 = if ($prefix -eq 0) { [uint64]0 } else { ($fullMask -shl (32 - $prefix)) -band $fullMask }
    $mask = [uint32]$maskU64
    $network = $ipUInt -band $mask
    $broadcast = [uint32]($network -bor ($fullMask -band (-bnot [uint64]$mask)))
    return @($network, $broadcast)
}

function Test-K8CidrOverlap {
    param([Parameter(Mandatory)][string] $CidrA, [Parameter(Mandatory)][string] $CidrB)
    $ra = ConvertTo-K8CidrRange -Cidr $CidrA
    $rb = ConvertTo-K8CidrRange -Cidr $CidrB
    return ($ra[0] -le $rb[1]) -and ($rb[0] -le $ra[1])
}

function Get-K8ComposeDeclaredSubnets {
    <#
        Resolves the IPv4 subnet(s) THIS run's compose file declares via
        `docker compose config --format json` (the fully-resolved compose
        document -- name/services/networks/volumes as one JSON object,
        never NDJSON, since it is a single document, not a per-item list),
        never a hardcoded/assumed CIDR. Only networks with an explicit
        `ipam.config[].subnet` are returned; a network with no declared
        subnet (Docker assigns one from its default pool) is not a FIXED
        CIDR and cannot deterministically collide the way the reported UX
        defect requires, so it is intentionally excluded here.
    #>
    param([Parameter(Mandatory)][string] $RunId, [Parameter(Mandatory)][string] $ComposePath)
    $capture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'config', '--format', 'json')
    if ($capture.ExitCode -ne 0) {
        throw "'docker compose config --format json' failed (exit $($capture.ExitCode)); cannot resolve this run's declared network subnets for the pool-conflict preflight. stderr: $($capture.Stderr.Trim())"
    }
    $config = ($capture.Stdout | Out-String) | ConvertFrom-Json
    $subnets = New-Object System.Collections.Generic.List[string]
    $networks = Get-K8ObjectPropertyValue -Object $config -Name 'networks'
    if ($networks) {
        foreach ($netProp in $networks.PSObject.Properties) {
            $ipam = Get-K8ObjectPropertyValue -Object $netProp.Value -Name 'ipam'
            $ipamConfig = if ($ipam) { Get-K8ObjectPropertyValue -Object $ipam -Name 'config' } else { $null }
            # `@($null)` is a 1-element array CONTAINING null, not an empty
            # array -- must skip explicitly, not just iterate blindly, or a
            # network with no ipam/config at all throws on the null $entry.
            if ($null -ne $ipamConfig) {
                foreach ($entry in @($ipamConfig)) {
                    if ($null -eq $entry) { continue }
                    $subnet = Get-K8ObjectPropertyValue -Object $entry -Name 'subnet'
                    if (-not [string]::IsNullOrWhiteSpace([string]$subnet)) { $subnets.Add([string]$subnet) }
                }
            }
        }
    }
    return ,$subnets.ToArray()
}

function Get-K8LeftoverShakedownNetworks {
    <#
        Enumerates EXISTING docker networks that look like a leftover
        network from a PRIOR (not this) Shakedown run -- name matching
        `k8shakedown-range[abc]-<digits>...`, excluding $RunId's own -- and
        returns each with whatever IPv4 subnet(s) it actually has, via
        `docker network inspect`. Read-only: never removes, prunes, or
        otherwise mutates any network. That decision is the operator's, by
        design (see Test-K8ShakedownNetworkPreflight's docstring).
    #>
    param([Parameter(Mandatory)][string] $RunId)
    $lsCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('network', 'ls', '--format', 'json')
    if ($lsCapture.ExitCode -ne 0) {
        throw "'docker network ls --format json' failed (exit $($lsCapture.ExitCode)); cannot check for leftover Shakedown networks. stderr: $($lsCapture.Stderr.Trim())"
    }
    $raw = ($lsCapture.Stdout | Out-String)
    $networks = if ([string]::IsNullOrWhiteSpace($raw)) { @() } else { ConvertFrom-K8ComposePsJson -Raw $raw }
    $candidates = @($networks | Where-Object {
        $name = [string](Get-K8ObjectPropertyValue -Object $_ -Name 'Name')
        $name -match '^k8shakedown-range[abc]-\d' -and $name -ne $RunId -and -not $name.StartsWith("$RunId-") -and -not $name.StartsWith("${RunId}_")
    })
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($net in $candidates) {
        $name = [string](Get-K8ObjectPropertyValue -Object $net -Name 'Name')
        $inspectCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('network', 'inspect', $name, '--format', 'json')
        if ($inspectCapture.ExitCode -ne 0) { continue }  # network may have been removed between ls and inspect; not this preflight's concern
        $inspectRaw = ($inspectCapture.Stdout | Out-String)
        if ([string]::IsNullOrWhiteSpace($inspectRaw)) { continue }
        $inspected = ConvertFrom-K8ComposePsJson -Raw $inspectRaw
        foreach ($detail in $inspected) {
            $ipam = Get-K8ObjectPropertyValue -Object $detail -Name 'IPAM'
            $ipamConfig = if ($ipam) { Get-K8ObjectPropertyValue -Object $ipam -Name 'Config' } else { $null }
            $subnets = New-Object System.Collections.Generic.List[string]
            # See the matching guard in Get-K8ComposeDeclaredSubnets: `@($null)`
            # is a 1-element array containing null, not an empty array.
            if ($null -ne $ipamConfig) {
                foreach ($entry in @($ipamConfig)) {
                    if ($null -eq $entry) { continue }
                    $subnet = Get-K8ObjectPropertyValue -Object $entry -Name 'Subnet'
                    if (-not [string]::IsNullOrWhiteSpace([string]$subnet)) { $subnets.Add([string]$subnet) }
                }
            }
            if ($subnets.Count -gt 0) {
                $result.Add([pscustomobject]@{ Name = $name; Subnets = $subnets.ToArray() })
            }
        }
    }
    return ,$result.ToArray()
}

function Test-K8ShakedownNetworkPreflight {
    <#
        UX defect this exists to fix (real VM finding, reported alongside
        the readiness false-negative): a leftover docker network from an
        OLDER k8shakedown-rangea-* project, still holding a fixed subnet, is
        never torn down by an abandoned/non-rescued run -- a fresh
        `docker compose up` for a NEW run then fails with "invalid pool
        request: Pool overlaps with other one on this address space" during
        provisioning, with no earlier, clearer signal of why.

        Runs BEFORE `docker compose up` (never after -- the whole point is
        to fail before provisioning attempts anything). Compares THIS run's
        actually-declared subnet(s) (read from `compose config`, never
        hardcoded) against every discoverable leftover Shakedown network's
        actual subnet(s) (read from `docker network inspect`, never
        assumed). On overlap, STOPs with the exact conflicting network name
        and both subnets so the operator can decide what to do.

        Deliberately does NOT remove, prune, or otherwise touch any
        network -- `docker network prune`/`rm` are explicitly out of scope
        here. An old network may still be attached to a container the
        operator wants to inspect, or may belong to a run under active
        investigation; only the operator can safely judge that, never this
        preflight.
    #>
    param([Parameter(Mandatory)][string] $RunId, [Parameter(Mandatory)][string] $ComposePath)
    # NOT wrapped in @() -- both helpers already force-return a real array
    # via `,$X.ToArray()`; see their own return statements and the
    # Get-K8ExpectedServices comment earlier in this module for why
    # wrapping the call site AGAIN would double-wrap into an array-of-array.
    $ourSubnets = Get-K8ComposeDeclaredSubnets -RunId $RunId -ComposePath $ComposePath
    if ($ourSubnets.Count -eq 0) {
        Write-K8ShakedownLog -Message 'Network preflight: this run declares no fixed-subnet networks; nothing to check for pool conflicts.'
        return
    }
    $leftovers = Get-K8LeftoverShakedownNetworks -RunId $RunId
    $conflicts = New-Object System.Collections.Generic.List[string]
    foreach ($leftover in $leftovers) {
        foreach ($theirSubnet in $leftover.Subnets) {
            foreach ($ourSubnet in $ourSubnets) {
                if (Test-K8CidrOverlap -CidrA $ourSubnet -CidrB $theirSubnet) {
                    $conflicts.Add("network '$($leftover.Name)' holds subnet $theirSubnet, which overlaps this run's $ourSubnet")
                }
            }
        }
    }
    if ($conflicts.Count -gt 0) {
        $detail = $conflicts.ToArray() -join '; '
        throw "Network preflight STOP: a leftover Shakedown network's fixed subnet overlaps this run's intended network(s): $detail. This run will not proceed automatically -- Shakedown does not remove or prune docker networks. Inspect and, if it is safe to do so, remove the conflicting network yourself (docker network rm <name>), then retry with a fresh run ID."
    }
    Write-K8ShakedownLog -Message "Network preflight PASS: this run's subnet(s) ($($ourSubnets -join ', ')) do not overlap any of the $($leftovers.Count) leftover Shakedown network(s) found."
}

function New-K8ComposeReadinessRecord {
    <#
        Builds the structured readiness record Wait-K8ComposeReady retains,
        and writes it to $Path. Root cause this exists to fix: a real VM run
        (k8shakedown-rangea-20260829-071142) timed out after 120s with only
        an abstract "missing/not running/unhealthy or output could not be
        parsed" message, and environment/readiness.json held nothing but the
        LAST raw `compose ps` text dump -- an operator had to manually
        recompute expected/actual/missing counts by hand to discover the
        real 21/21/all-running/declared-healthchecks-healthy state had
        already been reached, meaning readiness itself, not Docker, was the
        false negative. This record makes that distinction mechanically
        explicit and persisted, every poll, not just reconstructible after
        the fact from a raw dump.
    #>
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string[]] $Expected,
        [string] $Decision,
        [string] $RawPsOutput,
        [string] $ParseDiagnostic,
        $Gate,
        [int] $Attempts = 0
    )
    $actualCount = 0
    $missing = @(); $notRunning = @(); $notHealthy = @()
    if ($Gate) {
        $missing = @($Gate.Missing); $notRunning = @($Gate.NotRunning); $notHealthy = @($Gate.NotHealthy)
        $actualCount = $Expected.Count - $missing.Count
    }
    $record = [ordered]@{
        decision              = $Decision
        expected_count        = $Expected.Count
        expected_services     = @($Expected)
        actual_present_count  = $actualCount
        missing               = $missing
        not_running           = $notRunning
        not_healthy           = $notHealthy
        parse_diagnostic      = $(if ($ParseDiagnostic) { $ParseDiagnostic } else { $null })
        poll_attempts         = $Attempts
        raw_ps_output         = $RawPsOutput
    }
    $record | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Encoding utf8NoBOM
    return $record
}

function Write-K8ComposeReadinessTimeoutDiagnostic {
    <# Prints the 5-10 line console summary a timeout must show: not just
       "timed out", but exactly what evaluation blocked PASS the last time
       it was actually checked. #>
    param([Parameter(Mandatory)][int] $TimeoutSeconds, [Parameter(Mandatory)] $Record)
    Write-Host ''
    Write-Host "Environment readiness timed out after ${TimeoutSeconds}s. Last poll result:" -ForegroundColor Yellow
    Write-Host "  Expected services : $($Record.expected_count)"
    if ($Record.parse_diagnostic) {
        Write-Host "  Actual services   : could not be determined (parse failed)"
        Write-Host "  Parse diagnostic  : $($Record.parse_diagnostic)"
    }
    else {
        Write-Host "  Actual present    : $($Record.actual_present_count)"
        Write-Host "  Missing           : $(if ($Record.missing.Count) { $Record.missing -join ', ' } else { '(none)' })"
        Write-Host "  Not running       : $(if ($Record.not_running.Count) { $Record.not_running -join ', ' } else { '(none)' })"
        Write-Host "  Not healthy       : $(if ($Record.not_healthy.Count) { $Record.not_healthy -join ', ' } else { '(none)' })"
    }
    Write-Host "  Poll attempts     : $($Record.poll_attempts)"
    Write-Host "  Full record       : environment/readiness.json"
    Write-Host ''
}

function Wait-K8ComposeReady {
    <#
        Polls `docker compose ps --format json` until every defined service
        reports a running state, or throws on timeout. README SS5.1 step 4
        requires readiness before capture context resolution; this makes that
        an explicit, fail-closed gate instead of an assumption.

        Never weakens the readiness condition itself: every expected service
        must be present, State 'running', and -- for a service that DOES
        declare a Docker healthcheck -- Health 'healthy' (see
        Test-K8ComposeServiceReadiness, unchanged). What changed (see
        New-K8ComposeReadinessRecord's docstring for the root cause) is that
        a parse failure is now tracked SEPARATELY from a genuine
        missing/not-running/unhealthy result across the whole polling loop,
        surfaced in both the persisted record and an explicit console
        diagnostic on timeout, rather than being indistinguishable WARN-and-
        retry noise with no persisted trace of which one actually happened.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence,
        [int] $TimeoutSeconds = 120,
        [int] $PollSeconds = 3
    )
    $envDir = Join-Path $RunEvidence 'environment'
    # NOT wrapped in @() here: Get-K8ExpectedServices already force-returns a
    # real array via `return ,$services` (correct for 1 element AND for many).
    # Wrapping ITS call site in @() as well double-wraps the result into a
    # 1-element array whose sole element is the real array -- Test-K8Compose
    # ServiceReadiness would then iterate exactly one pseudo-"expected
    # service" (the array object itself, not a service name string), which
    # can never match any real row, making Missing non-empty and Ready
    # false FOREVER regardless of actual Docker state. Root cause of the
    # real VM false negative (k8shakedown-rangea-20260829-071142): 21/21
    # services were genuinely running and healthy the whole time; this
    # double-wrap is what made Test-K8ComposeServiceReadiness never see them.
    $expected = Get-K8ExpectedServices -RunId $RunId -ComposePath $ComposePath
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastRaw = ''
    $lastGate = $null
    $lastParseDiagnostic = $null
    $attempts = 0
    while ((Get-Date) -lt $deadline) {
        $attempts++
        # STDOUT/STDERR captured separately: a Compose warning on stderr
        # must not be merged into the JSON this parses.
        $psCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'ps', '--all', '--format', 'json')
        $lastRaw = ($psCapture.Stdout | Out-String)
        if ($psCapture.ExitCode -ne 0) {
            $lastParseDiagnostic = "'docker compose ps' failed (exit $($psCapture.ExitCode)): $($psCapture.Stderr.Trim())"
            $lastGate = $null
            Write-K8ShakedownLog -Level WARN -Message "readiness poll: $lastParseDiagnostic"
        }
        else {
            try {
                # NOT wrapped in @() -- ConvertFrom-K8ComposePsJson already
                # force-returns a real array; see its own return statement.
                $services = ConvertFrom-K8ComposePsJson -Raw $lastRaw
                $gate = Test-K8ComposeServiceReadiness -Expected $expected -Services $services
                $lastGate = $gate
                $lastParseDiagnostic = $null
                if ($gate.Ready) {
                    New-K8ComposeReadinessRecord -Path (Join-Path $envDir 'readiness.json') -Expected $expected `
                        -Decision 'PASS' -RawPsOutput $lastRaw -Gate $gate -Attempts $attempts | Out-Null
                    Write-K8ShakedownLog -Message "Environment readiness PASS: all $($expected.Count) expected service(s) present/running and all reported healthchecks healthy (after $attempts poll(s))."
                    return
                }
            }
            catch {
                $lastParseDiagnostic = $_.Exception.Message
                $lastGate = $null
                Write-K8ShakedownLog -Level WARN -Message "readiness poll: could not parse 'compose ps --format json' output, retrying: $lastParseDiagnostic"
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }
    $record = New-K8ComposeReadinessRecord -Path (Join-Path $envDir 'readiness.json') -Expected $expected `
        -Decision $(if ($lastParseDiagnostic) { 'FAIL-PARSE' } else { 'FAIL-STATE' }) `
        -RawPsOutput $lastRaw -ParseDiagnostic $lastParseDiagnostic -Gate $lastGate -Attempts $attempts
    Write-K8ComposeReadinessTimeoutDiagnostic -TimeoutSeconds $TimeoutSeconds -Record $record
    throw "Environment readiness timed out after ${TimeoutSeconds}s; an expected service was missing/not running/unhealthy or output could not be parsed. See environment/readiness.json."
}

function Write-K8ImageInventory {
    <#
        c2-dnp3-image-inventory.md SS4's exact collection: `compose images
        --format json` for the effective per-service references, THEN
        `docker image inspect <id> --format '{{.Id}} {{json .RepoDigests}}'`
        on each -- not just the compose-level summary alone.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence
    )
    $envDir = Join-Path $RunEvidence 'environment'
    # NOT wrapped in @() here: Get-K8ExpectedServices already force-returns a
    # real array via `return ,$services` (correct for 1 element AND for many).
    # Wrapping ITS call site in @() as well double-wraps the result into a
    # 1-element array whose sole element is the real array -- Test-K8Compose
    # ServiceReadiness would then iterate exactly one pseudo-"expected
    # service" (the array object itself, not a service name string), which
    # can never match any real row, making Missing non-empty and Ready
    # false FOREVER regardless of actual Docker state. Root cause of the
    # real VM false negative (k8shakedown-rangea-20260829-071142): 21/21
    # services were genuinely running and healthy the whole time; this
    # double-wrap is what made Test-K8ComposeServiceReadiness never see them.
    $expected = Get-K8ExpectedServices -RunId $RunId -ComposePath $ComposePath
    # STDOUT/STDERR captured separately throughout: a stray Compose/Docker
    # stderr line merged into either JSON capture below would corrupt the
    # mandatory image inventory (a completeness-gate-required artifact).
    $imagesCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'images', '--format', 'json')
    if ($imagesCapture.ExitCode -ne 0) { throw "docker compose images failed (exit $($imagesCapture.ExitCode)); image inventory is mandatory. stderr: $($imagesCapture.Stderr.Trim())" }
    $psJson = $imagesCapture.Stdout
    # `-join` (not a bare pipeline): Set-Content creates NO FILE when nothing
    # is piped to it, so an exit-0 command that happened to emit nothing would
    # silently leave no artifact at all -- the same cause class as the Range B
    # post-fault retention defect.
    (@($psJson) -join "`n") | Set-Content -Path (Join-Path $envDir 'compose-images.json') -Encoding utf8NoBOM
    $composePsCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'ps')
    (@($composePsCapture.Stdout) -join "`n") | Set-Content -Path (Join-Path $envDir 'compose-ps.txt') -Encoding utf8NoBOM

    # NOT wrapped in @() -- ConvertFrom-K8ComposePsJson already force-returns
    # a real array; see its own return statement.
    try { $images = ConvertFrom-K8ComposePsJson -Raw ($psJson | Out-String) }
    catch { throw "could not parse mandatory compose image inventory JSON: $($_.Exception.Message)" }
    $resolvedRows = Resolve-K8ComposeImageRows -RunId $RunId -ExpectedServices $expected -ImageRows $images
    $inventory = @()
    foreach ($service in $expected) {
        $img = $resolvedRows[$service]
        $id = Get-K8ObjectPropertyValue -Object $img -Name 'ID'
        $repository = Get-K8ObjectPropertyValue -Object $img -Name 'Repository'
        $tag = Get-K8ObjectPropertyValue -Object $img -Name 'Tag'
        $ref = if ($id) { $id } elseif ($repository -and $tag) { "${repository}:$tag" } else { $null }
        if (-not $ref) { throw "image reference/ID missing for expected service '$service'" }
        $inspectCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('image', 'inspect', $ref)
        if ($inspectCapture.ExitCode -ne 0) { throw "docker image inspect failed for service '$service' image '$ref' (exit $($inspectCapture.ExitCode)). stderr: $($inspectCapture.Stderr.Trim())" }
        $raw = ($inspectCapture.Stdout | Out-String)
        $inspection = @($raw | ConvertFrom-Json)
        if ($inspection.Count -ne 1 -or -not $inspection[0].Id) { throw "inspect result for '$service' lacks an immutable image Id" }
        $digests = @($inspection[0].RepoDigests | Where-Object { $_ })
        $inventory += [ordered]@{ service=$service; resolved_reference=$ref; image_id=$inspection[0].Id; repo_digests=$digests; repo_digests_status=$(if ($digests.Count) {'present'} else {'absent-local-build'}) }
    }
    if ($inventory.Count -ne $expected.Count) { throw 'image inventory is incomplete' }
    $inventory | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $envDir 'image-inventory.json') -Encoding utf8NoBOM
    Write-K8ShakedownLog -Message "Image inventory PASS: all $($inventory.Count) expected service(s) inspected."
}

function Write-K8RuntimeContractRecord {
    <#
        evidence-schema.md SS3's "Range A/B runtime-invariant record." Retains
        what is mechanically observable. Does NOT compute the scored Runtime
        Contract Pass/Fail/Unresolved verdict -- README SS6.2 reserves that
        derivation for the operator, from this record plus the other stages.

        For Range B, c2-dnp3-step4-range-b-fault-pilot.md SS3 lists four
        required nontriviality checks. Checks 1-3 are mechanized here (service
        state via structured `compose ps --format json`, target-interface
        mirror filter removal, zone_detector liveness). Elasticsearch's own
        endpoint readiness is NOT re-checked here -- it already ran, shared
        identically for Range A and Range B, in
        Wait-K8ElasticsearchReady before this function is ever called;
        duplicating that curl call here (as an earlier revision did, with its
        own separate non-polling check) is exactly the kind of Range A/B
        readiness-logic inconsistency that let Range A reach the fixed
        Collector query with no Elasticsearch gate at all. Check 2's "one
        unrelated observed gateway interface still has a mirred egress mirror
        filter" is mechanized via Assert-K8UnrelatedMirrorFilter (called by
        the caller before this function). Check 4's sensor-capture
        unrelated-frame content is mechanized after capture export via
        Write-K8UnrelatedPcapRows.

        C-7: check 4's artifacts do not exist yet at this call site, and this
        record used to name them anyway -- a generated narrative citing files
        that were not there. It no longer does. The check-4 line is appended
        by Complete-K8RuntimeContractRecord once those artifacts exist, where
        each one is resolved as a typed run-local reference and fails closed
        if it is missing. Same content, stated only when it is true.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('a', 'b')][string] $Range,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence,
        [Parameter(Mandatory)] $Gateway
    )
    $contractDir = Join-Path $RunEvidence 'contract-output'
    $psText = (docker compose -p $RunId -f $ComposePath ps 2>&1 | Out-String)
    # STDOUT/STDERR captured separately: a stray stderr line must not be
    # merged into the JSON this parses for the Range B service-state gate.
    $psJsonCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'ps', '--all', '--format', 'json')
    if ($psJsonCapture.ExitCode -ne 0) { throw "docker compose ps --format json failed while building the runtime contract record (exit $($psJsonCapture.ExitCode)). stderr: $($psJsonCapture.Stderr.Trim())" }
    # NOT wrapped in @() -- ConvertFrom-K8ComposePsJson already force-returns
    # a real array; see its own return statement.
    $services = ConvertFrom-K8ComposePsJson -Raw ($psJsonCapture.Stdout | Out-String)
    $lines = @()
    $lines += "# Runtime contract observational record -- $RunId"
    $lines += ''
    $lines += 'This is a retained observation, not the scored Runtime Contract verdict (README SS6.2 derives that by hand).'
    $lines += ''
    $lines += '## docker compose ps'
    $lines += '```'
    $lines += $psText.TrimEnd()
    $lines += '```'

    if ($Range -eq 'b') {
        $requiredServices = @('wan_router', 'tap_observer', 'log_structurer', 'elasticsearch', 'zone_detector')
        # Structured lookup, not a text/substring match against `compose ps`
        # display output: a service name can appear as a substring of a
        # container/image name unrelated to whether that SERVICE row itself
        # is present and running.
        $readinessCheck = Test-K8ComposeServiceReadiness -Expected $requiredServices -Services $services
        $lines += ''
        $lines += '## c2-dnp3-step4-range-b-fault-pilot.md SS3 nontriviality checks'
        $lines += ''
        if (-not $readinessCheck.Ready) {
            throw "Range B service-state gate failed -- missing: $($readinessCheck.Missing -join ', '); not running: $($readinessCheck.NotRunning -join ', '); unhealthy: $($readinessCheck.NotHealthy -join ', ')"
        }
        # Typed run-local references, existence-checked before they are named.
        # All four artifacts below already exist at this point in the run.
        $refs = Get-K8NarrativeReferenceText -RunEvidence $RunEvidence -References @(
            (New-K8ArtifactReference -Kind 'run-local' -Path 'contract-output/qdisc-pre-fault.txt')
            (New-K8ArtifactReference -Kind 'run-local' -Path 'contract-output/qdisc-post-fault.txt')
            (New-K8ArtifactReference -Kind 'run-local' -Path 'contract-output/unrelated-mirror-filters.txt')
            (New-K8ArtifactReference -Kind 'run-local' -Path 'environment/elasticsearch-readiness.json')
        )
        $lines += "1. Required services present/running in structured \`compose ps\`: PASS (all of $($requiredServices -join ', ') found)"
        $lines += "2. Target-interface ($($Gateway.Interface)) mirror filter removed: see $($refs[0]) / $($refs[1]). Unrelated mirror-filter gate: see $($refs[2]) (runner stops unless another interface retains mirred egress mirror)."
        $lines += "3. Elasticsearch endpoint readiness: see $($refs[3]) (shared Wait-K8ElasticsearchReady gate, already PASS before this record was written -- not re-queried here). zone_detector service state: PASS (checked structurally above, not by text-matching \`compose ps\` display output)."
        $lines += '4. Sensor unrelated-flow frame and Collector correlation are checked after capture export. The artifacts do not exist yet at this point in the run, so they are NOT named here; the pointers are appended once they exist.'
    }

    $lines -join "`n" | Set-Content -Path (Join-Path $contractDir 'runtime-contract-record.md') -Encoding utf8NoBOM
    Write-K8ShakedownLog -Message 'Runtime contract observational record written to contract-output/runtime-contract-record.md.'
}

function Complete-K8RuntimeContractRecord {
    <#
        Appends the Range B check-4 pointers, after the artifacts they name
        actually exist.

        The old record named `r-obs-05-pcap-rows.json` and
        `r-obs-05-correlation.json` at a point in the run where neither file
        had been written -- exactly the C-7 defect class: a machine-generated
        narrative asserting an artifact reference nobody ever checked. They are
        resolved here as typed run-local references and fail closed if absent.

        C7-R4: the observer FACT (whether the correlation gate passed, and how
        many pairs it evaluated) is read back from the C-5 observer record --
        the authoritative structured source for that fact class -- rather than
        restated from a local variable or from prose. This record still states
        the observation only; the scored Runtime Contract verdict remains the
        operator's at scoring-input time.
    #>
    param([Parameter(Mandatory)][string] $RunEvidence)
    $record = Join-Path $RunEvidence 'contract-output\runtime-contract-record.md'
    if (-not (Test-Path -LiteralPath $record)) { throw "runtime contract record not found at $record; cannot append the R-OBS-05 pointers." }
    $refs = Get-K8NarrativeReferenceText -RunEvidence $RunEvidence -References @(
        (New-K8ArtifactReference -Kind 'run-local' -Path 'contract-output/r-obs-05-pcap-rows.json')
        (New-K8ArtifactReference -Kind 'run-local' -Path 'contract-output/r-obs-05-correlation.json')
    )
    $correlation = Get-Content -LiteralPath (Join-Path $RunEvidence 'contract-output\r-obs-05-correlation.json') -Raw | ConvertFrom-Json
    $gatePass = Get-K8ObjectPropertyValue -Object $correlation -Name 'r_obs_05_mechanical_gate_pass'
    $evaluated = Get-K8ObjectPropertyValue -Object $correlation -Name 'evaluated_count'
    $lines = @(
        ''
        '### check 4 -- retained artifacts (appended once they existed)'
        ''
        "Decoded unrelated-flow rows: $($refs[0])."
        "Pcap/document correlation record: $($refs[1])."
        "Mechanical gate result as retained by the observer: r_obs_05_mechanical_gate_pass=$($gatePass.ToString().ToLowerInvariant()) over $evaluated evaluated pcap/document comparison(s). This is the observer's retained result, not a scored Runtime Contract verdict."
    )
    Add-Content -LiteralPath $record -Value ($lines -join "`n") -Encoding utf8NoBOM
    Write-K8ShakedownLog -Message 'Runtime contract record: R-OBS-05 check-4 pointers appended against artifacts that now exist.'
}

function Complete-K8ShakedownRangeAB {
    <#
        Second half of a Range A/B Shakedown run: run this AFTER saving the
        Collector/Rule (and, for Range B, R-OBS-05) query responses into
        collector-output/ / rule-output/ / contract-output/. Tears down the
        range, updates metadata.md's cleanup row, and runs
        validate-evidence/finalize-evidence/verify-integrity. Never fills in a
        missing response itself -- an empty collector-output/ or rule-output/
        is a STOP condition here, exactly as it is for study01_collect.py.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('a', 'b')][string] $Range
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $state = Get-K8ShakedownState
    $stageKey = "range_$($Range)_stage"
    if (-not $state.PSObject.Properties[$stageKey] -or $state.$stageKey -ne 'awaiting-completion') {
        throw "No Range $($Range.ToUpper()) run is awaiting completion (state.$stageKey = $(if ($state.PSObject.Properties[$stageKey]) { $state.$stageKey } else { '<none>' })). Run .\tools\Run-K8ShakedownRange$($Range.ToUpper()).ps1 first."
    }
    $RunId = $state."range_$($Range)_run_id"
    # Re-establish the run context so this phase's stage tracking and
    # termination attribution work exactly as phase 1's did.
    $run = Set-K8ShakedownRunContext -RunId $RunId -RepoRoot $state.repo_root
    return Invoke-K8ShakedownRunBoundary -Run $run -ScriptBlock {
        Complete-K8ShakedownRangeABBody -Range $Range -Run $run
    }.GetNewClosure()
}

function Complete-K8ShakedownRangeABBody {
    param(
        [Parameter(Mandatory)][ValidateSet('a', 'b')][string] $Range,
        [Parameter(Mandatory)] $Run
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $state = Get-K8ShakedownState
    $stageKey = "range_$($Range)_stage"
    $RunId = $Run.RunId
    $RunEvidence = $state."range_$($Range)_evidence"
    $ComposePath = $state."range_$($Range)_compose"
    $Study01 = Join-Path $state.repo_root 'Study01'
    $ScriptsDir = Join-Path $Study01 'studies\study-01-negative-result\scripts'
    Set-K8ShakedownRunEvidence -Path $RunEvidence | Out-Null

    Write-K8ShakedownLog -Level STEP -Message "=== Completing Shakedown Range $($Range.ToUpper()): $RunId ==="

    # Whole-run invariant. Phase 2 must not execute at a different tooling HEAD
    # than phase 1 -- that is the same across-HEADs hazard C-2b exists for --
    # and the run being completed must be the one the sequence has active.
    Set-K8ShakedownRunStage -Stage 'complete-preconditions'
    Assert-K8RunSequenceInvariant -Run $Run

    foreach ($required in @('collector-output\collector-response.json', 'rule-output\rule-response.json', 'rule-output\collector-rule-correlation.json')) {
        if (-not (Test-Path (Join-Path $RunEvidence $required))) { throw "required automated runtime evidence missing: $required" }
    }
    if ($Range -eq 'b') {
        foreach ($required in @('r-obs-05-mapping-response.json','r-obs-05-mapping-gate.json','r-obs-05-response.json','r-obs-05-pcap-rows.json','r-obs-05-correlation.json','unrelated-mirror-filters.txt')) {
            if (-not (Test-Path (Join-Path $RunEvidence "contract-output\$required"))) { throw "Range B cannot complete: required R-OBS-05 evidence missing: $required" }
        }
        $mappingGate = Get-Content (Join-Path $RunEvidence 'contract-output\r-obs-05-mapping-gate.json') -Raw | ConvertFrom-Json
        $correlationGate = Get-Content (Join-Path $RunEvidence 'contract-output\r-obs-05-correlation.json') -Raw | ConvertFrom-Json
        if ($mappingGate.mapping_gate_pass -ne $true -or $correlationGate.r_obs_05_mechanical_gate_pass -ne $true) { throw 'Range B cannot complete: an R-OBS-05 mechanical gate is not PASS' }
    }

    # Frozen ordering: prove the runtime evidence is complete and hash it while
    # the project still exists. Only then may cleanup destroy project/volumes.
    Set-K8ShakedownRunStage -Stage 'pre-teardown-validate'
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $ScriptsDir 'study01_collect.py'), 'validate-evidence', $RunEvidence) -Description 'pre-teardown validate-evidence'
    Set-K8ShakedownRunStage -Stage 'pre-teardown-finalize'
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $ScriptsDir 'study01_collect.py'), 'finalize-evidence', $RunEvidence) -Description 'pre-teardown finalize/hash'
    if (-not (Test-Path (Join-Path $RunEvidence 'hashes.sha256'))) { throw 'pre-teardown finalize did not create hashes.sha256; refusing teardown' }

    Set-K8ShakedownRunStage -Stage 'teardown'
    Invoke-K8ShakedownCommand -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'down', '-v', '--remove-orphans') `
        -Description 'destroy project + volumes (prevent state carry-over)'
    $finalPs = (docker compose -p $RunId -f $ComposePath ps 2>&1 | Out-String)
    $finalPs | Add-Content -Path (Join-Path $RunEvidence 'environment\compose-ps.txt') -Encoding utf8NoBOM

    Set-K8ShakedownRunStage -Stage 'cleanup-record'
    # C7-R2: the artifact this row points at is resolved as a typed run-local
    # reference and existence-checked before the row is written.
    $psRef = Resolve-K8NarrativeReference -RunEvidence $RunEvidence -Reference (
        New-K8ArtifactReference -Kind 'run-local' -Path 'environment/compose-ps.txt')
    (Get-Content (Join-Path $RunEvidence 'metadata.md') -Raw) -replace `
        '\| Cleanup \| NOT YET PERFORMED.*\|', `
        "| Cleanup | destroyed via 'docker compose down -v --remove-orphans' at $((Get-Date).ToUniversalTime().ToString('o')); final ps: see $psRef |" |
        Set-Content -Path (Join-Path $RunEvidence 'metadata.md') -Encoding utf8NoBOM

    "cleanup_utc=$((Get-Date).ToUniversalTime().ToString('o'))`ncommand=docker compose -p $RunId -f $ComposePath down -v --remove-orphans`nresult=PASS" |
        Set-Content -Path (Join-Path $RunEvidence 'environment\cleanup-result.txt') -Encoding utf8NoBOM
    Set-K8ShakedownRunStage -Stage 'final-finalize'
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $ScriptsDir 'study01_collect.py'), 'finalize-evidence', $RunEvidence) -Description 'final finalize/hash including cleanup record'
    Set-K8ShakedownRunStage -Stage 'final-verify'
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $ScriptsDir 'study01_collect.py'), 'verify-integrity', $RunEvidence) -Description 'final verify-integrity'

    # C-3 (4). Ordering, and only this ordering:
    #     final-finalize -> final-verify -> identity freeze -> run completion.
    # The snapshot must pin a manifest that actually PASSED verify-integrity,
    # not merely one that finalize produced, so it is written after the line
    # above and before the sequence advances below.
    Set-K8ShakedownRunStage -Stage 'finalize-identity-snapshot'
    Write-K8FinalizeIdentitySnapshot -Run $Run -RunEvidence $RunEvidence | Out-Null

    # The C-3 template, into the control plane -- never into the evidence tree,
    # which is now finalized and hashed. It is intentionally incomplete and
    # intentionally not scorable; filling it in is the operator's work.
    $template = Write-K8ScoringInputTemplate -Run $Run -Range $Range

    # Only now does the sequence advance. A run that terminated anywhere above
    # never reaches this line, so next_range never moves past a failure.
    Complete-K8ShakedownRunInSequence -Run $Run | Out-Null
    Set-K8ShakedownState -Updates @{ $stageKey = 'complete'; "range_$($Range)_complete_utc" = (Get-Date).ToUniversalTime().ToString('o') }

    Write-K8ShakedownLog -Level STEP -Message "=== Shakedown Range $($Range.ToUpper()) complete: $RunId ==="
    Write-Host ''
    Write-Host "Range $($Range.ToUpper()) run '$RunId' finalized/verified. Remaining manual step (by protocol design, not automated):"
    Write-Host "  README SS6.2: derive scoring-input.json by hand from $RunEvidence BEFORE opening expected/."
    Write-Host "  A structural template (intentionally incomplete, deliberately not scorable) is at:"
    Write-Host "    $template"
    Write-Host "  Fill every <FILL-IN> and record in `"derivation`" which artifact each value came from, then:"
    Write-Host "  python `"$(Join-Path $PSScriptRoot 'k8_scoring_input_contract.py')`" validate --range $Range --input <your-scoring-input.json> --run-evidence `"$RunEvidence`" --finalize-snapshot `"$(Get-K8FinalizeIdentityPath -RunId $RunId)`""
    Write-Host "  python `"$(Join-Path $ScriptsDir 'study01_score.py')`" <path-to-scoring-input.json> --run-evidence `"$RunEvidence`" --output `"$RunEvidence\score.json`""
    return $RunEvidence
}

Export-ModuleMember -Function * -Variable K8Shakedown
