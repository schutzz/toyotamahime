[CmdletBinding()]
param([string] $InventoryPath = '')
$ErrorActionPreference = 'Stop'
$Study01 = Split-Path $PSScriptRoot -Parent
$Repo = Split-Path $Study01 -Parent
if (-not $InventoryPath) { $InventoryPath = Join-Path $Study01 'docs\k8-formal-actions.json' }
$Inventory = Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json -Depth 20
$ReadmeText = Get-Content -LiteralPath (Join-Path $Study01 'README.md') -Raw
if ($Inventory.schema -ne 'k8-formal-action-inventory/1') { throw "unexpected inventory schema: $($Inventory.schema)" }
$Actions = @($Inventory.actions)
$ById = @{}
$Gaps = [System.Collections.Generic.List[string]]::new()
foreach ($a in $Actions) {
    foreach ($field in @('action_id','classification','authority','executable_mechanism','input_origin','retained_output')) {
        if (-not $a.PSObject.Properties[$field] -or -not $a.$field) { $Gaps.Add("$($a.action_id): missing $field") }
    }
    if ($ById.ContainsKey($a.action_id)) { $Gaps.Add("duplicate action_id: $($a.action_id)") } else { $ById[$a.action_id] = $a }
    if ($a.classification -notin @('EXECUTABLE','INTENTIONALLY_HUMAN_JUDGED')) { $Gaps.Add("$($a.action_id): invalid classification") }
    if ($a.classification -eq 'EXECUTABLE') {
        if ($a.executable_mechanism -match '^(prose|human):') { $Gaps.Add("$($a.action_id): executable action is prose/human-only") }
        $first = ($a.executable_mechanism -split ' ')[0]
        if ($first -match '^(Study01|shakedown|bootstrap)/') {
            $path = Join-Path $Repo ($first -replace '/', '\')
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $Gaps.Add("$($a.action_id): mechanism path missing: $first") }
        }
        elseif ($first -match '^README:k8-test:(.+)$') {
            $blockId = $Matches[1]
            if ($ReadmeText -notmatch "(?m)<!--\s*k8-test:id=$([regex]::Escape($blockId))\s") {
                $Gaps.Add("$($a.action_id): README executable block missing: $blockId")
            }
        }
        elseif ($first -match '^protocol:(.+\.md)$') {
            $protocol = Join-Path $Study01 "studies\study-01-negative-result\protocol\$($Matches[1])"
            if (-not (Test-Path -LiteralPath $protocol -PathType Leaf)) {
                $Gaps.Add("$($a.action_id): protocol mechanism missing: $($Matches[1])")
            }
        }
        elseif ($first -notmatch '^(Study01|shakedown|bootstrap)/') {
            $Gaps.Add("$($a.action_id): ambiguous executable mechanism locator: $first")
        }
    }
}
$Disconnected = [System.Collections.Generic.List[string]]::new()
foreach ($a in $Actions) {
    $depsValue = @(if ($a.PSObject.Properties['depends_on']) { @($a.depends_on) } else { @() })
    if ($a.PSObject.Properties['conditional_dependencies']) {
        foreach ($property in $a.conditional_dependencies.PSObject.Properties) {
            if ($property.Name -notin @('A','B','C')) { $Disconnected.Add("$($a.action_id): invalid conditional range $($property.Name)") }
            $depsValue += @($property.Value)
        }
    }
    foreach ($depId in @($depsValue | Where-Object { $_ })) {
        if (-not $ById.ContainsKey($depId)) { $Disconnected.Add("$depId -> $($a.action_id): dependency missing"); continue }
        $shared = @($ById[$depId].retained_output | Where-Object { $_ -in @($a.input_origin) })
        if ($shared.Count -eq 0) { $Disconnected.Add("$depId -> $($a.action_id): no retained_output/input_origin connection") }
    }
}
foreach ($d in $Disconnected) { $Gaps.Add($d) }
$Reachable = [System.Collections.Generic.HashSet[string]]::new()
$Changed = $true
while ($Changed) {
    $Changed = $false
    foreach ($a in $Actions) {
        $deps = @(if ($a.PSObject.Properties['depends_on']) { @($a.depends_on | Where-Object { $_ }) } else { @() })
        if ($a.PSObject.Properties['conditional_dependencies']) {
            foreach ($property in $a.conditional_dependencies.PSObject.Properties) { $deps += @($property.Value) }
        }
        if ($deps.Count -eq 0 -or @($deps | Where-Object { -not $Reachable.Contains($_) }).Count -eq 0) {
            if ($Reachable.Add([string]$a.action_id)) { $Changed = $true }
        }
    }
}
foreach ($a in $Actions) { if (-not $Reachable.Contains([string]$a.action_id)) { $Gaps.Add("$($a.action_id): unreachable from an inventory root") } }
$CanReachCloseout = [System.Collections.Generic.HashSet[string]]::new()
[void]$CanReachCloseout.Add('F04-closeout')
$Changed = $true
while ($Changed) {
    $Changed = $false
    foreach ($a in $Actions) {
        $consumers = @($Actions | Where-Object {
            ($_.PSObject.Properties['depends_on'] -and @($_.depends_on) -contains $a.action_id) -or
            ($_.PSObject.Properties['conditional_dependencies'] -and @($_.conditional_dependencies.PSObject.Properties.Value) -contains $a.action_id)
        })
        if (@($consumers | Where-Object { $CanReachCloseout.Contains([string]$_.action_id) }).Count -gt 0) {
            if ($CanReachCloseout.Add([string]$a.action_id)) { $Changed = $true }
        }
    }
}
foreach ($a in $Actions) { if (-not $CanReachCloseout.Contains([string]$a.action_id)) { $Gaps.Add("$($a.action_id): output cannot reach F04-closeout") } }

# Prove each executable range graph independently. Range-B-only nodes and
# edges must not become hidden prerequisites for Range A.
foreach ($range in @('A','B','C')) {
    $rangeActions = @($Actions | Where-Object {
        if ($range -eq 'C') { $_.action_id -match '^(F0[0-2]|C)' }
        elseif ($range -eq 'A') { $_.action_id -match '^(F0[0-2]|A)' }
        else { $_.action_id -match '^(F0[0-2]|A|B)' }
    })
    $rangeIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($a in $rangeActions) { [void]$rangeIds.Add([string]$a.action_id) }
    $rangeReachable = [System.Collections.Generic.HashSet[string]]::new()
    $rangeChanged = $true
    while ($rangeChanged) {
        $rangeChanged = $false
        foreach ($a in $rangeActions) {
            $deps = @(if ($a.PSObject.Properties['depends_on']) { @($a.depends_on | Where-Object { $rangeIds.Contains([string]$_) }) } else { @() })
            if ($a.PSObject.Properties['conditional_dependencies'] -and $a.conditional_dependencies.PSObject.Properties[$range]) {
                $deps += @($a.conditional_dependencies.$range)
            }
            if (@($deps | Where-Object { -not $rangeReachable.Contains([string]$_) }).Count -eq 0) {
                if ($rangeReachable.Add([string]$a.action_id)) { $rangeChanged = $true }
            }
        }
    }
    foreach ($a in $rangeActions) {
        if (-not $rangeReachable.Contains([string]$a.action_id)) { $Gaps.Add("$range/$($a.action_id): unreachable in range-specific graph") }
    }
    if ($range -in @('A','B')) {
        $ancestors = [System.Collections.Generic.HashSet[string]]::new()
        $pending = [System.Collections.Generic.Queue[string]]::new()
        $pending.Enqueue('A15-teardown')
        while ($pending.Count) {
            $id = $pending.Dequeue(); $node = $ById[$id]
            $deps = @(if ($node.PSObject.Properties['depends_on']) { @($node.depends_on) } else { @() })
            if ($node.PSObject.Properties['conditional_dependencies'] -and $node.conditional_dependencies.PSObject.Properties[$range]) {
                $deps += @($node.conditional_dependencies.$range)
            }
            foreach ($dep in $deps) { if ($ancestors.Add([string]$dep)) { $pending.Enqueue([string]$dep) } }
        }
        $requiredBeforeTeardown = @('A10-target-decode','A11-collector-rule','A12-runtime-observation')
        if ($range -eq 'B') { $requiredBeforeTeardown += @('B03-robs05-observation') }
        foreach ($required in $requiredBeforeTeardown) {
            if (-not $ancestors.Contains($required)) { $Gaps.Add("$range/A15-teardown: may precede required runtime action $required") }
        }
    }
}
$Executable = @($Actions | Where-Object classification -eq 'EXECUTABLE').Count
$Human = @($Actions | Where-Object classification -eq 'INTENTIONALLY_HUMAN_JUDGED').Count
[pscustomobject]@{ required_actions=$Actions.Count; executable=$Executable; intentionally_human_judged=$Human; gaps=$Gaps.Count; disconnected_edges=$Disconnected.Count; findings=@($Gaps) } | ConvertTo-Json -Depth 5
if ($Gaps.Count) { Write-Error "EXECUTION COMPLETENESS: FAIL ($($Gaps.Count) GAP)"; exit 1 }
Write-Output "EXECUTION COMPLETENESS: PASS ($($Actions.Count) actions; GAP=0; disconnected=0)"
exit 0
