[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Baseline = '0774d7a88cc4b7632408a624ed48dec6d85d528f'

$changed = @(& git -C $Repo diff --name-only "$Baseline..HEAD" -- `
    Study01/studies/study-01-negative-result/claims `
    Study01/studies/study-01-negative-result/expected `
    Study01/studies/study-01-negative-result/protocol `
    Study01/studies/study-01-negative-result/scripts/study01_score.py `
    Study01/studies/study-01-negative-result/scripts/study01/frozen)
if ($LASTEXITCODE -ne 0) { throw 'git semantic-path comparison failed' }

$allowed = 'Study01/studies/study-01-negative-result/scripts/study01/frozen/r-obs-05-query.template.json'
$unexpected = @($changed | Where-Object { $_ -and $_ -ne $allowed })
if ($unexpected.Count) { throw "scientific/scoring/expected path changed: $($unexpected -join ', ')" }

$formalQuery = Get-Content -LiteralPath (Join-Path $Repo $allowed) -Raw | ConvertFrom-Json -Depth 30 | ConvertTo-Json -Depth 30 -Compress
$qualifiedQuery = Get-Content -LiteralPath (Join-Path $Repo 'shakedown/tools/r-obs-05-query.template.json') -Raw | ConvertFrom-Json -Depth 30 | ConvertTo-Json -Depth 30 -Compress
if ($formalQuery -cne $qualifiedQuery) { throw 'formal R-OBS-05 query is not the qualified Shakedown query semantics' }

$actions = Get-Content -LiteralPath (Join-Path $Repo 'Study01/studies/study-01-negative-result/scripts/study01_formal_actions.py') -Raw
if ($actions -notmatch 'k8_scoring_input_contract\.py' -or $actions -notmatch 'emit-template') {
    throw 'manual scoring-input boundary is not preserved'
}

Write-Output 'SEMANTIC NEUTRALITY: PASS'
Write-Output 'Scientific semantics changed: NO'
Write-Output 'Scoring semantics changed: NO'
Write-Output 'Expected results changed: NO'
Write-Output 'Manual epistemic boundaries changed: NO'
