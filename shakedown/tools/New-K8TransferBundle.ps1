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

# 2. Copy each run's evidence tree, then exclude pcap BODIES -- but only after
#    proving, per body, that its identity is already retained. The bodies never
#    enter Git in this project; that is a reason to leave them out, not a
#    licence to drop them without checking what the drop costs.
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$boundCaptures = New-Object System.Collections.Generic.List[object]
foreach ($row in $consistency.Runs) {
    $src = Join-Path (Get-K8ShakedownRoot) "runs\$($row.run_id)"
    if (-not (Test-Path -LiteralPath $src)) { throw "C-9: evidence tree missing for $($row.run_id) at $src." }
    $dst = Join-Path $Destination $row.run_id
    Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force

    # Checked on the COPY, which is the tree the exclusion actually applies to,
    # and BEFORE the removal: after it, the body is gone and the question
    # cannot be asked at all.
    $bound = @(Assert-K8ExcludedCapturesAreRetained -RunEvidence $dst -Range $row.range -RunId $row.run_id)
    foreach ($b in $bound) { $boundCaptures.Add([ordered]@{ run_id = $row.run_id; path = $b.path; sha256 = $b.sha256; manifest = $b.manifest }) }

    Get-ChildItem -LiteralPath $dst -Recurse -File -Filter '*.pcap' | Remove-Item -Force
    Write-K8ShakedownLog -Message "copied $($row.run_id) (Range $($row.range)); $($bound.Count) pcap body/bodies excluded after binding."
}

$exclusions = @(
    [ordered]@{
        pattern          = '*.pcap'
        reason           = 'pcap-body-never-in-git'
        # The run's OWN retained integrity manifest, which is what actually
        # covers these bodies. An earlier version named `*/pcap-hashes.sha256`,
        # a file nothing in this repository has ever written.
        retained_instead = '*/hashes.sha256'
        note             = 'Capture bodies are never committed in this project. Every excluded body was checked against its own run''s retained manifest -- exact run-relative path and exact sha256 -- before removal; see bound_captures. Range A/B are covered by hashes.sha256 from the frozen finalize-evidence. Range C retains no capture body.'
        # What the exclusion COST, itemised. A declaration that says only "pcaps
        # were left out" leaves the consumer to take on trust that nothing was
        # lost; this says which body, and where its identity is now.
        bound_captures   = $boundCaptures.ToArray()
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

# 3b. The manifests that carry the excluded bodies' identities must themselves
#     have travelled. Checked rather than assumed: they are ordinary files in
#     the tree and nothing else in this script would notice their absence, and
#     a bundle whose exclusion points at a file it does not contain is the same
#     empty promise this fix exists to remove.
$manifestPaths = @($manifest.files | ForEach-Object { [string]$_.path })
foreach ($row in $consistency.Runs) {
    $carrier = "$($row.run_id)/" + (Get-K8RunIntegrityManifestName -Range $row.range)
    if ($manifestPaths -notcontains $carrier) {
        throw "C-9: '$carrier' is not among the bundle's data files, so the identities of $($row.run_id)'s excluded bodies did not travel with the bundle."
    }
}
Write-K8ShakedownLog -Message "retained integrity manifests present in the bundle for all $(@($consistency.Runs).Count) run(s)."

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
Write-Host "  pcaps excluded : $($boundCaptures.Count)   <- each bound to its run's retained manifest before removal"
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
