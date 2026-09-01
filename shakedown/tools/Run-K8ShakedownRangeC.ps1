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

# Same run lifecycle as Range A/B -- one shared code path, not a third copy.
# The run ID and its provenance exist before any Range C step runs, and every
# failure below is caught by the same boundary.
$Run = Start-K8ShakedownRun -Range c -RepoRoot $state.repo_root
Invoke-K8ShakedownRunBoundary -Run $Run -ScriptBlock {
# ---- run boundary begins. Left at column 0 rather than re-indenting the whole
# ---- script; the matching end marker is at the bottom of the file.

$Study01 = Join-Path $state.repo_root 'Study01'
$PatchSource = Join-Path $Study01 'studies\study-01-negative-result\experiments\range-c-negative-manifest\power-grid-reference.range-c-negative.patch'

Set-K8ShakedownRunStage -Stage 'sequence-binding'
Assert-K8SequenceBinding -Run $Run

if (-not (Test-Path $PatchSource)) { throw "Frozen Range C patch not found at $PatchSource" }

$RunId = $Run.RunId
$RunEvidence = Join-Path $state.shakedown_root "runs\$RunId"

# Range C builds its own run directory (it never calls the frozen
# evidence_tree.create), so it gets an EXPLICIT evidence-init stage that does
# the same job at the same point in its own lifecycle as Range A/B's
# evidence-tree stage. Without it the provenance mirror happened at a timing
# the C-6 contract could not name, and `run-provenance.json` would have had to
# carry a per-range exception instead of a real producer stage.
Set-K8ShakedownRunStage -Stage 'evidence-init'
New-Item -ItemType Directory -Force -Path $RunEvidence | Out-Null
Copy-K8RunProvenanceIntoEvidence -Run $Run -RunEvidence $RunEvidence
Set-K8ShakedownRunEvidence -Path $RunEvidence | Out-Null

Write-K8ShakedownLog -Level STEP -Message "=== Shakedown Range C starting: $RunId ==="

# 1. Disposable worktree copied from the pinned v0.13.0 checkout; confirm clean before use.
Set-K8ShakedownRunStage -Stage 'source-worktree-check'
$rangeCSource = $state.amenonuboco_rangec_dir
$disposable = Join-Path $state.shakedown_root "runs\$RunId\worktree"
$sourceStatus = Get-K8ContractedNativeText -StepId 'C-46' -FilePath 'git' -ArgumentList @('-C', $rangeCSource, 'status', '--porcelain')
if ($sourceStatus) {
    throw "Range C source checkout $rangeCSource is not clean before copy:`n$sourceStatus`nNot proceeding -- this is a STOP condition, not something to auto-fix (e.g. from a leftover prior Shakedown run)."
}
Assert-K8PinnedCommit -WorktreePath $rangeCSource -ExpectedCommit (Get-K8ShakedownConstants).RangeCCommit -Label 'Range C source worktree (pre-copy)'

Set-K8ShakedownRunStage -Stage 'worktree-copy'
Write-K8ShakedownLog -Message "Copying $rangeCSource -> $disposable"
Copy-Item -Recurse -Force -Path $rangeCSource -Destination $disposable
Assert-K8PinnedCommit -WorktreePath $disposable -ExpectedCommit (Get-K8ShakedownConstants).RangeCCommit -Label 'Range C disposable worktree (post-copy)'

# 2. Derive the negative manifest: copy base manifest under the negative-manifest filename,
#    then apply the fixed patch retargeted to that filename via literal string substitution
#    (c2-dnp3-range-derivation.md SS4 -- a known maintenance limitation, not a second patch
#    mechanism; not changed here).
Set-K8ShakedownRunStage -Stage 'manifest-derivation'
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
# The derived patch is complete NOW, so this is the stage that owns it. The
# negative manifest deliberately is NOT retained here: at this instant it is
# still a byte copy of the BASE manifest, and the patch that makes it negative
# has not been applied yet. Retaining it here would preserve bytes the
# validator never reads.
Copy-Item -Path $derivedPatch -Destination (Join-Path $RunEvidence 'range-c-derived.patch')

Set-K8ShakedownRunStage -Stage 'patch-apply'
Push-Location $disposable
try {
    Invoke-K8ShakedownCommand -StepId 'F-33' -FilePath 'git' -ArgumentList @('apply', '--ignore-space-change', '--check', $derivedPatch) -Description 'derived patch check'
    Invoke-K8ShakedownCommand -StepId 'F-34' -FilePath 'git' -ArgumentList @('apply', '--ignore-space-change', $derivedPatch) -Description 'derived patch apply'
    # Retained HERE, immediately after `git apply` succeeded and before the
    # validator runs: these are exactly the bytes the validator is about to
    # read, and nothing modifies the file between this copy and that read.
    Copy-Item -Path $negativeManifest -Destination (Join-Path $RunEvidence 'power-grid-reference.range-c-negative.yaml')

    # 3. Exactly one command. Byte-exact stdout/stderr capture via cmd.exe redirection
    #    (PowerShell's own pipeline capture re-encodes text; this does not).
    Set-K8ShakedownRunStage -Stage 'validator-run'
    $stdoutPath = Join-Path $RunEvidence 'validate.stdout.txt'
    $stderrPath = Join-Path $RunEvidence 'validate.stderr.txt'
    Write-K8ShakedownLog -Level STEP -Message 'RUN: python platform/cli.py validate manifests/power-grid-reference.range-c-negative.yaml'
    # C-60: python must be runnable before the single permitted command. The
    # VERSION is retained, never gated; being executable IS gated.
    $pyVersionRecord = Get-K8RequiredToolVersion -StepId 'C-60' -FilePath 'python' -ArgumentList @('--version') `
        -Requirement 'python is required to run the pinned Range C validator'
    $pyVersion = $pyVersionRecord['value']

    $validatorArgv = @('cmd.exe', '/c', 'python', 'platform\cli.py', 'validate', 'manifests\power-grid-reference.range-c-negative.yaml')
    # F-35 PRE-EXECUTION gate. Not routed through Invoke-K8ContractedNative:
    # this call redirects both streams to files inside cmd.exe precisely so no
    # PowerShell re-encoding happens, and the row's stream_expectation is
    # file-backed to say so. The contract is applied around the call instead.
    [void](Assert-K8CommandContract -StepId 'F-35' -Argv $validatorArgv)
    $validatorStartedUtc = Get-K8UtcNow
    & cmd.exe /c "python platform\cli.py validate manifests\power-grid-reference.range-c-negative.yaml > `"$stdoutPath`" 2> `"$stderrPath`""
    $exitCode = $LASTEXITCODE
    Write-K8ShakedownLog -Message "validate exit code: $exitCode (exit 1 is the EXPECTED outcome per README SS5.3/SS6.1 -- not treated as failure)"
    # F-35 POST-OBSERVATION gate. The acceptance domain is @(0, 1) and BOTH
    # values pass: exit 1 is the frozen expected rejection, and exit 0 is the
    # scientific observation that the apparatus did NOT reject the negative
    # manifest. Turning exit 0 into a tooling STOP would convert a finding into
    # an error. Only >=2 (argparse/interpreter failure) stops here.
    [void](Assert-K8CommandObservation -StepId 'F-35' -ExitCode $exitCode -Argv $validatorArgv `
        -Diagnostic "stdout file: $stdoutPath; stderr file: $stderrPath")

    # C-4. This is the closed-world's only `direct cmd.exe` producer, and the
    # one whose emptiness matters most: a Range C stdout of 0 bytes is the
    # EXPECTED observation (README SS5.3/SS6.1), so an empty stream must be
    # retained as a described file, never silently skipped. `file-backed`
    # semantics: cmd.exe wrote both streams itself, so the descriptors hash
    # the files' raw bytes with no re-encoding in between.
    Write-K8CommandObservation -RunEvidence $RunEvidence `
        -ArtifactRelativePath 'validate.stdout.txt' -ObservationRelativePath 'validate.observation.json' `
        -Producer 'Run-K8ShakedownRangeC.ps1' -Stage 'validator-run' -Range 'c' -RunId $RunId `
        -Observations @(
            New-K8FileBackedCommandObservation -Label 'Range C static validation (the one permitted command)' `
                -Argv $validatorArgv -ExitCode $exitCode -TimestampUtc $validatorStartedUtc `
                -RunEvidence $RunEvidence -StdoutRelativePath 'validate.stdout.txt' -StderrRelativePath 'validate.stderr.txt'
        ) | Out-Null
}
finally { Pop-Location }

# 4. Retain the narrative record. The derived patch, the negative manifest and
#    the two stream files were each retained by the stage that produced them.
Set-K8ShakedownRunStage -Stage 'retention'
# C7-R2: typed references, existence-checked before they are named. The
# worktree paths below are host paths and are recorded as-is -- they are not
# resolvable as run-local artifacts and are not checked as such.
$cRefs = Get-K8NarrativeReferenceText -RunEvidence $RunEvidence -References @(
    (New-K8ArtifactReference -Kind 'run-local' -Path 'validate.stdout.txt')
    (New-K8ArtifactReference -Kind 'run-local' -Path 'validate.stderr.txt')
    (New-K8ArtifactReference -Kind 'run-local' -Path 'power-grid-reference.range-c-negative.yaml')
    (New-K8ArtifactReference -Kind 'run-local' -Path 'range-c-derived.patch')
    (New-K8ArtifactReference -Kind 'run-local' -Path 'validate.observation.json')
    (New-K8ArtifactReference -Kind 'host-path' -Path $rangeCSource)
    (New-K8ArtifactReference -Kind 'host-path' -Path $disposable)
)
# C7-R4: run identity from the authoritative structured source; the command
# fact (exit code) from the C-4 observation this run just retained, not from a
# loose local variable.
$cIdentity = Get-K8RunIdentityFacts -RunId $RunId
$cObservation = (Get-Content -LiteralPath (Join-Path $RunEvidence 'validate.observation.json') -Raw | ConvertFrom-Json).observations[0]
@"
# Range C validation record -- $RunId (Shakedown, NOT a formal K8-3 attempt, NOT Gate K8 evidence)

| Field | Value |
| --- | --- |
| Run ID | $($cIdentity.RunId) |
| Qualification sequence | $($cIdentity.SequenceId) |
| Tooling HEAD (locked for this sequence) | $($cIdentity.LockedHead) |
| Source worktree | $($cRefs[5]) (pinned $((Get-K8ShakedownConstants).RangeCCommit)) |
| Disposable worktree | $($cRefs[6]) |
| Command | $($cObservation.argv -join ' ') |
| Exit code | $($cObservation.exit_code) |
| Python | $pyVersion |
| Derived patch | $($cRefs[3]) (retained at manifest-derivation) |
| Validated manifest | $($cRefs[2]) (retained at patch-apply, after \`git apply\` succeeded -- these are the bytes the validator read) |
| stdout | $($cRefs[0]) -- $($cObservation.stdout.bytes) byte(s), sha256 $($cObservation.stdout.sha256) |
| stderr | $($cRefs[1]) -- $($cObservation.stderr.bytes) byte(s), sha256 $($cObservation.stderr.sha256) |
| Structured command observation | $($cRefs[4]) |

Expected, not forced (README SS5.3/SS6.1): exit 1, empty stdout, stderr naming
observability_contract.required_segments and sub_a_l2_lan. This record states
what was actually observed; compare it against expected/range-c/ yourself
before drawing a conclusion.

An empty stdout is a RETAINED observation, not a missing artifact: the file
exists and is described above with its byte count and hash.

Scope note: this run satisfies the Shakedown SS5.3 execution-retention
contract. It is NOT the frozen evidence-schema.md static-validation package
shape (\`static-validations/\`), and nothing here claims it is.
"@ | Set-Content -Path (Join-Path $RunEvidence 'metadata.md') -Encoding utf8NoBOM

Remove-Item -Recurse -Force $disposable
Write-K8ShakedownLog -Message "Disposable worktree removed after retention (README SS5.2: only the disposable worktree and generated static artifacts are removed; no Docker cleanup applies to Range C)."

# C-6 final gate, BEFORE the sequence is advanced. A Range C run must not be
# recorded as completed -- still less become the third leg of a
# c-2b-sequence-valid sequence -- while an artifact it contracted to retain is
# missing. Defense in depth over the per-stage gates above, from the same
# single contract.
# C-9 (B3B-04). Every producer stage has finished, so the hash domain is
# complete. The manifest is itself a required artifact of THIS stage, and it is
# not in its own hash domain -- two different memberships, kept apart.
Set-K8ShakedownRunStage -Stage 'retention-manifest'
Write-K8RangeCRetentionManifest -RunEvidence $RunEvidence | Out-Null

Set-K8ShakedownRunStage -Stage 'completeness-gate'
Assert-K8RunArtifactCompleteness -Range 'c' -RunEvidence $RunEvidence

# Only what passed a gate gets pinned -- Batch 2's ordering rule for the A/B
# finalize identity snapshot, applied to the Range C manifest.
Write-K8RangeCIdentitySnapshot -Run $Run -RunEvidence $RunEvidence | Out-Null

# Range C is single-phase, so the sequence advances here rather than in a
# separate Complete script. If this is the third run of an uninterrupted
# A -> B -> C at one locked HEAD, the sequence becomes c-2b-sequence-valid --
# which is NOT a K8-S2 authorization.
Complete-K8ShakedownRunInSequence -Run $Run | Out-Null
Set-K8ShakedownState -Updates @{ range_c_run_id = $RunId; range_c_evidence = $RunEvidence; range_c_exit_code = $exitCode; range_c_complete_utc = (Get-Date).ToUniversalTime().ToString('o') }

Write-K8ShakedownLog -Level STEP -Message "=== Shakedown Range C complete: $RunId (validator exit $exitCode) ==="
Write-Host ''
Write-Host "Range C evidence: $RunEvidence"
Write-Host 'Compare validate.stdout.txt / validate.stderr.txt / exit code against Study01/expected/range-c/ yourself.'

# ---- run boundary ends. GetNewClosure pins $Run/$state to this script's scope
# ---- so the boundary helper's own parameter names cannot rebind them.
}.GetNewClosure()
