#Requires -Version 7.0
<#
.SYNOPSIS
    Assembles a transfer bundle from completed Shakedown runs and writes the
    producer's transfer-manifest.json (C-9 / Batch 3B).

.DESCRIPTION
    RT-01 is why this exists. After the first Shakedown, the run evidence was
    moved into Kakuriyo by hand. Verified against the bytes as collected:
    423 OK / 0 missing / 0 mismatch. Verified against the bytes git actually
    commits: 97 OK / 326 MISMATCH -- 328 of 425 files contained CR and the
    destination applies `* text=auto eol=lf`. Both were called "manifest
    verification".

    It was closed by a human noticing at transfer time and hand-adding a
    bundle-local .gitattributes. Nothing made the next transfer get checked the
    same way: retrospective SS6 M-4 puts bundle assembly outside run tooling
    entirely, so the step existed only in somebody's memory.

    WHAT THIS DOES AND DOES NOT DECIDE

    It assembles bytes and states facts about them. It does NOT write a
    .gitattributes, and it does not tell the consumer what its retention
    policy should be (D-4). The manifest carries each file's sha256 and its
    byte class -- contains_cr / contains_nul / trailing_newline -- which is
    what a consumer needs in order to work out for itself whether its own
    policy would rewrite these bytes. "Contains CR" is an observation the
    producer can make about its own output; "therefore mark it -text" is not.

    WHICH RUNS GO IN is still a manual decision (SS6 M-4 / K-4) and is passed
    in by -RunId. What is NOT manual any more is whether that selection hangs
    together: the runs must belong to ONE completed sequence, at ONE locked
    HEAD, covering a/b/c exactly once, with no terminated run among them. The
    existing bundle's three "qualification runs" span different tooling HEADs
    and nothing caught it (U-8).

    README.md and .gitattributes are NOT created here. They are the operator's
    (README authoring is a manual boundary; .gitattributes is the consumer's
    policy). The script prints what is still owed rather than authoring either.

.PARAMETER RunId
    The runs to include. One completed sequence, a/b/c exactly once.

.PARAMETER Destination
    Directory to assemble into. Must not already exist -- a bundle is built
    once, and overwriting one silently would destroy a retained record.

.PARAMETER BundleId
    Identifier for this bundle. Used by the consumer as the staging branch and
    certification tag name, so it is fixed before any commit exists.

.EXAMPLE
    .\tools\New-K8TransferBundle.ps1 `
        -RunId k8shakedown-rangea-20260901-101010, k8shakedown-rangeb-20260901-111111, k8shakedown-rangec-20260901-121212 `
        -Destination C:\K8\transfer\k8-shakedown-20260901 `
        -BundleId k8-shakedown-20260901
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]] $RunId,
    [Parameter(Mandatory)][string] $Destination,
    [Parameter(Mandatory)][string] $BundleId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'K8ShakedownCommon.psm1') -Force

# The id becomes a staging branch AND a certification tag on the consumer side.
# Asked of git rather than pattern-matched: a character class accepts foo..bar,
# foo. and foo.lock, every one of which git refuses -- and the failure would
# then surface in the consumer, after a bundle already exists.
[void](Assert-K8BundleIdUsableAsRef -BundleId $BundleId)
if (Test-Path -LiteralPath $Destination) {
    throw "Destination $Destination already exists. A bundle is assembled once; overwriting one would destroy a retained record, and a re-attempt uses a NEW bundle id rather than reusing this one."
}

Write-K8ShakedownLog -Level STEP -Message "=== C-9 transfer bundle assembly: $BundleId ==="

# 1. The selection is the operator's; its consistency is not.
$consistency = Assert-K8BundleRunConsistency -RunIds $RunId
Write-K8ShakedownLog -Message "run selection accepted: sequence $($consistency.SequenceId) at locked HEAD $($consistency.ToolingHead), ranges a/b/c."

# 2. Copy each run's evidence tree, excluding pcap BODIES. Their hashes travel
#    in the per-run pcap-hashes.sha256 that the run itself retained; the bodies
#    never enter Git in this project.
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
foreach ($row in $consistency.Runs) {
    $src = Join-Path (Get-K8ShakedownRoot) "runs\$($row.run_id)"
    if (-not (Test-Path -LiteralPath $src)) { throw "C-9: evidence tree missing for $($row.run_id) at $src." }
    $dst = Join-Path $Destination $row.run_id
    Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
    Get-ChildItem -LiteralPath $dst -Recurse -File -Filter '*.pcap' | Remove-Item -Force
    Write-K8ShakedownLog -Message "copied $($row.run_id) (Range $($row.range)); pcap bodies excluded."
}

$exclusions = @(
    [ordered]@{
        pattern          = '*.pcap'
        reason           = 'pcap-body-never-in-git'
        retained_instead = '*/pcap-hashes.sha256'
        note             = 'Capture bodies are never committed in this project. Each run retained its own pcap-hashes.sha256 during the run, and that file is in the manifest.'
    }
)

# 3. The producer's claim.
# Deliberately passes the run IDs again rather than the object from step 1:
# the manifest builder re-runs the gate itself, so nothing it produces depends
# on a caller having done so.
$manifest = New-K8TransferManifest -RunIds $RunId -BundleRoot $Destination -Exclusions $exclusions
$manifestPath = Join-Path $Destination 'transfer-manifest.json'
Write-K8AtomicFile -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 12) + "`n")
Write-K8ShakedownLog -Message "transfer-manifest.json written over $(@($manifest.files).Count) file(s)."

# 4. Report what the operator still owes, and do not author any of it.
$withCr = @($manifest.files | Where-Object { $_.byte_class.contains_cr })
$closed = Test-K8BundleClosedWorld -BundleRoot $Destination -Manifest $manifest

Write-Host ''
Write-Host "Bundle assembled: $Destination" -ForegroundColor Green
Write-Host "  bundle_id      : $BundleId"
Write-Host "  sequence_id    : $($consistency.SequenceId)"
Write-Host "  locked HEAD    : $($consistency.ToolingHead)"
Write-Host "  data files     : $(@($manifest.files).Count)"
Write-Host "  files with CR  : $($withCr.Count)   <- the RT-01 condition, stated as an observation"
Write-Host "  control present: $(@($closed.PresentControlFiles) -join ', ')"
Write-Host ''
Write-Host 'STILL OWED BY THE OPERATOR (this tool does not author them):' -ForegroundColor Yellow
Write-Host '  README.md        -- what this bundle is. Authoring it is a manual boundary (SS6 M-4).'
Write-Host '  .gitattributes   -- the CONSUMER''S retention policy. The producer must not decide it (D-4);'
Write-Host '                      the byte_class field above is the fact you need in order to decide.'
Write-Host ''
Write-Host 'Then, on the consumer side, before committing anything:' -ForegroundColor Yellow
Write-Host '  CT-1 (pre-commit)  -- collected bytes AND index bytes, both, against this manifest.'
Write-Host ''
Write-Host 'Neither this bundle nor its manifest is Gate K8 evidence.' -ForegroundColor DarkGray
