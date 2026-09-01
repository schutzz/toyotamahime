#Requires -Version 7.0
<#
    k8_command_reachability.ps1 -- the cross-boundary oracle for C-8.

    WHY A THIRD ORACLE, AND WHY IT MUST NOT LOOK LIKE THE OTHER TWO

    The AST oracle and the independent lexical audit agreed on 97 sites. That
    agreement was not evidence: both decide by matching KNOWN NAMES -- known
    native binaries, known Shakedown wrappers -- so both missed the same site.

        Start-K8Shakedown.ps1   Get-K8WslField -Arguments '--version'
              |                 (neither a native name nor a Shakedown wrapper)
        Get-K8WslField                       [frozen Study01/tools/K8AttemptCommon.psm1]
              |
        Invoke-Utf16LEProcessCapture
              |
        System.Diagnostics.Process.Start()
              |
        wsl.exe --version

    Adding a second oracle that asks the SAME question cannot remove a shared
    blind spot. This one asks a different question:

        which FUNCTIONS can reach a process-start primitive at all?

    It carries no list of tool names. A primitive is recognised structurally:
    a CommandAst whose resolved name is neither a defined function nor a known
    cmdlet (therefore a native binary), a System.Diagnostics.Process /
    ProcessStartInfo type reference, or Start-Process / Invoke-Expression. The
    call graph is then closed transitively across the import boundary, so a
    launcher implemented in frozen code is still attributed to the Shakedown
    call site that invokes it.

    THE BOUNDARY THIS ENFORCES

    Responsibility, not file location. If shakedown/tools/ code causes a
    process to start, the site belongs in the contract even when the launch
    itself lives in Study01/. Study01/ is never modified to satisfy this.
#>
param(
    [Parameter(Mandatory)][string] $RepoRoot,
    [switch] $AsText
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-K8ReachabilityReport {
    param([Parameter(Mandatory)][string] $RepoRoot)

    $toolsDir = Join-Path (Join-Path $RepoRoot 'shakedown') 'tools'
    $frozenModule = Join-Path (Join-Path (Join-Path $RepoRoot 'Study01') 'tools') 'K8AttemptCommon.psm1'

    $shakedownFiles = @(Get-ChildItem (Join-Path $toolsDir '*') -Include *.ps1, *.psm1 -File)
    $allFiles = @($shakedownFiles)
    if (Test-Path -LiteralPath $frozenModule) { $allFiles += Get-Item -LiteralPath $frozenModule }

    $parsed = @{}
    $funcs = @{}
    foreach ($f in $allFiles) {
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
        if ($errors -and @($errors).Count -gt 0) { throw "k8_command_reachability: $($f.Name) failed to parse." }
        $parsed[$f.Name] = $ast
        foreach ($d in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $funcs[$d.Name] = @{ File = $f.Name; Ast = $d }
        }
    }

    # A name is a "known cmdlet" only if the host resolves it AND it is not one
    # of this project's own functions -- otherwise a loaded K8 module would
    # make our own launchers look like built-ins.
    $cmdletCache = @{}
    function Test-IsHostCmdlet([string] $Name) {
        if (-not $cmdletCache.ContainsKey($Name)) {
            $cmd = Get-Command $Name -ErrorAction SilentlyContinue
            $cmdletCache[$Name] = ($null -ne $cmd -and $Name -notlike '*-K8*' -and $Name -notlike 'Invoke-Utf16*')
        }
        return $cmdletCache[$Name]
    }

    function Get-DirectEdges($FnAst) {
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($c in $FnAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $c.GetCommandName()
            if ($null -eq $name) { $out.Add(@{ Kind = 'dynamic' }); continue }
            if ($name -in 'Start-Process', 'Invoke-Expression', 'iex') { $out.Add(@{ Kind = 'primitive'; Name = $name }); continue }
            if ($funcs.ContainsKey($name)) { $out.Add(@{ Kind = 'call'; Name = $name }); continue }
            if (Test-IsHostCmdlet $name) { continue }
            $out.Add(@{ Kind = 'native'; Name = $name })
        }
        foreach ($t in $FnAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeExpressionAst] }, $true)) {
            if ($t.TypeName.FullName -match 'Diagnostics\.(Process|ProcessStartInfo)') {
                $out.Add(@{ Kind = 'primitive'; Name = $t.TypeName.FullName })
            }
        }
        return $out
    }

    $direct = @{}
    foreach ($k in $funcs.Keys) { $direct[$k] = Get-DirectEdges $funcs[$k].Ast }

    $canLaunch = @{}
    foreach ($k in $funcs.Keys) {
        $canLaunch[$k] = @($direct[$k] | Where-Object { $_.Kind -in 'primitive', 'native', 'dynamic' }).Count -gt 0
    }
    # Transitive closure. Bounded so a cycle cannot spin.
    for ($pass = 0; $pass -lt 32; $pass++) {
        $changed = $false
        foreach ($k in $funcs.Keys) {
            if ($canLaunch[$k]) { continue }
            foreach ($e in $direct[$k]) {
                if ($e.Kind -eq 'call' -and $canLaunch[$e.Name]) { $canLaunch[$k] = $true; $changed = $true; break }
            }
        }
        if (-not $changed) { break }
    }

    $shakedownNames = @($shakedownFiles.Name)
    $foreignLaunchers = @($funcs.Keys | Where-Object { $funcs[$_].File -notin $shakedownNames -and $canLaunch[$_] } | Sort-Object)

    # Cross-boundary sites: a shakedown/tools/ call site invoking a
    # launch-capable function DEFINED OUTSIDE shakedown/tools/.
    $cross = New-Object System.Collections.Generic.List[object]
    foreach ($f in $shakedownFiles) {
        $ast = $parsed[$f.Name]
        $functions = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $c.GetCommandName()
            if ($null -eq $name -or $name -notin $foreignLaunchers) { continue }
            $scope = '<script-toplevel>'
            $best = $null
            foreach ($fn in $functions) {
                if ($fn.Extent.StartOffset -le $c.Extent.StartOffset -and $c.Extent.EndOffset -le $fn.Extent.EndOffset) {
                    if ($null -eq $best -or $fn.Extent.StartOffset -gt $best.Extent.StartOffset) { $best = $fn }
                }
            }
            if ($best) { $scope = $best.Name }
            $cross.Add([pscustomobject]@{
                file = $f.Name; line = $c.Extent.StartLineNumber; column = $c.Extent.StartColumnNumber
                scope = $scope; callee = $name
            })
        }
    }

    $ordered = @($cross | Sort-Object file, line, column)
    $byLine = @{}
    foreach ($s in $ordered) {
        $key = "$($s.file)|$($s.line)"
        if (-not $byLine.ContainsKey($key)) { $byLine[$key] = 0 }
        $byLine[$key]++
        $s | Add-Member -NotePropertyName ordinal_in_line -NotePropertyValue $byLine[$key] -Force
        $s | Add-Member -NotePropertyName key -NotePropertyValue "$($s.file)|$($s.line)|$($byLine[$key])" -Force
    }

    return [pscustomobject]@{
        ForeignLaunchers  = $foreignLaunchers
        CrossBoundarySites = $ordered
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $r = Get-K8ReachabilityReport -RepoRoot $RepoRoot
    if ($AsText) {
        '--- launch-capable functions defined OUTSIDE shakedown/tools/ ---'
        $r.ForeignLaunchers | ForEach-Object { "  $_" }
        '--- cross-boundary call sites in shakedown/tools/ ---'
        $r.CrossBoundarySites | ForEach-Object { '{0}:{1}#{2}  {3}  {4}' -f $_.file, $_.line, $_.ordinal_in_line, $_.scope, $_.callee }
    }
    else { $r }
}
