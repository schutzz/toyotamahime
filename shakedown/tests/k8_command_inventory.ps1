#Requires -Version 7.0
<#
    k8_command_inventory.ps1 -- the AST oracle for C-8's closed-world claim.

    WHY THIS EXISTS AS A SEPARATE ORACLE

    The first inventory of external commands was produced by a single lexical
    scanner, and that scanner had a defect: it discarded any line containing
    `-Description`, which silently removed the `docker pull` and
    `study01_collect.py` call sites. It exited cleanly and reported a
    confident total. That is the same defect class C-8 exists to close --
    a broken observer whose output still looks correct -- so the inventory
    generator must not be a single oracle.

    THIS oracle never looks at line text. It walks CommandAst nodes from the
    PowerShell parser and classifies each by what GetCommandName() resolves
    to. It is compared against an independent lexical audit and against the
    contract rows.

    WHAT IT DELIBERATELY CANNOT DO

    It matches on KNOWN NAMES -- known native binaries and known Shakedown
    wrappers. That is a real blind spot, and it is not hypothetical: this
    oracle and the lexical audit agreed on 97 sites while BOTH missed
    Start-K8Shakedown.ps1's call to the frozen Get-K8WslField, which reaches
    System.Diagnostics.Process.Start. Two oracles asking the same question
    share their blind spot, so agreement between them is not evidence of
    closure. k8_command_reachability.ps1 asks a different question and covers
    exactly that gap; the two are unioned, never summed.

    DYNAMIC INVOCATION IS NEVER DROPPED

    `& $variable` cannot be resolved statically. It is emitted as
    UNRESOLVED-DYNAMIC rather than skipped, because skipping it would let a
    process launch disappear from a "complete" inventory. Whether each one is
    a scriptblock call or a real process start is a HUMAN adjudication, and
    the regression suite pins that adjudication so a newly added `& $var`
    cannot inherit it silently.

    Output: one record per site as an object, so the caller does the set
    algebra. Printing a count would invite the count-equality comparison that
    B3A-01 explicitly rejects.
#>
param(
    [Parameter(Mandatory)][string] $ToolsDir,
    [switch] $AsText
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Known native binaries this codebase starts.
$script:InvNative = @(
    'docker', 'git', 'python', 'python3', 'tshark', 'tcpdump', 'curl',
    'cmd', 'cmd.exe', 'pwsh', 'powershell', 'sh', 'awk'
)
# Shakedown's own process-starting helpers. The real tool is in -FilePath.
$script:InvWrappers = @(
    'Invoke-K8ShakedownCommand', 'Invoke-K8ShakedownLoggedCommand', 'Invoke-K8SeparatedNativeCapture',
    # C-8 added these two as the conversion target for the formerly bare
    # sites. They MUST be listed: a helper that starts a process and is not
    # known to this oracle is invisible to it, which is how the previous
    # inventory lost Get-K8WslField.
    'Invoke-K8ContractedNative', 'Get-K8ContractedNativeText',
    # Also process-starting helpers: one gates a required prerequisite while
    # retaining its version value (C-56..C-60), the other retains a runtime
    # tool identity without gating anything (I-07, I-08).
    'Get-K8RequiredToolVersion', 'Get-K8OptionalToolObservation'
)
# Helpers layered ON TOP of those. Their BODIES are implementations, not call
# sites, and are excluded below so a site is not counted twice.
$script:InvSubWrappers = @(
    'Invoke-K8FaultObservationCommand', 'Invoke-K8Robs05LifecycleStep'
)
# Scopes whose body contains a wrapper call that IS the helper's own
# implementation. Distinct from InvSubWrappers because these are not
# themselves counted as sites when called.
$script:InvImplementationScopes = @(
    'Invoke-K8FaultObservationCommand', 'Invoke-K8Robs05LifecycleStep',
    'Invoke-K8ContractedNative', 'Get-K8ContractedNativeText', 'Get-K8RequiredToolVersion',
    'Get-K8OptionalToolObservation'
)

function Get-K8InvEnclosingScope {
    <# Innermost enclosing function, or <script-toplevel>. This is half of the
       locator: `producer_function` alone cannot separate the six sites inside
       Wait-K8ZoneDetectorReady. #>
    param($Node, $Functions)
    $best = $null
    foreach ($f in $Functions) {
        if ($f.Extent.StartOffset -le $Node.Extent.StartOffset -and $Node.Extent.EndOffset -le $f.Extent.EndOffset) {
            if ($null -eq $best -or $f.Extent.StartOffset -gt $best.Extent.StartOffset) { $best = $f }
        }
    }
    if ($best) { return $best.Name }
    return '<script-toplevel>'
}

function Get-K8CommandInventory {
    param([Parameter(Mandatory)][string] $ToolsDir)

    $sites = New-Object System.Collections.Generic.List[object]
    $dynamic = New-Object System.Collections.Generic.List[object]

    foreach ($file in (Get-ChildItem (Join-Path $ToolsDir '*') -Include *.ps1, *.psm1 -File | Sort-Object Name)) {
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
        if ($errors -and @($errors).Count -gt 0) {
            throw "k8_command_inventory: $($file.Name) failed to parse; the inventory cannot be claimed complete over a file it could not read."
        }
        $functions = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $commands = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)

        foreach ($c in $commands) {
            $name = $c.GetCommandName()
            $scope = Get-K8InvEnclosingScope -Node $c -Functions $functions

            if ($null -eq $name) {
                # NEVER dropped. Surfaced for human adjudication.
                $dynamic.Add([pscustomobject]@{
                    file = $file.Name; line = $c.Extent.StartLineNumber; column = $c.Extent.StartColumnNumber
                    scope = $scope; expression = $c.CommandElements[0].Extent.Text
                })
                continue
            }

            $kind = $null; $callee = $null
            if ($script:InvWrappers -contains $name) {
                $filePath = $null
                for ($i = 1; $i -lt $c.CommandElements.Count; $i++) {
                    $e = $c.CommandElements[$i]
                    if ($e -is [System.Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -eq 'FilePath') {
                        if (($i + 1) -lt $c.CommandElements.Count) { $filePath = $c.CommandElements[$i + 1].Extent.Text }
                    }
                }
                if ($null -eq $filePath) {
                    throw "k8_command_inventory: a wrapper call at $($file.Name):$($c.Extent.StartLineNumber) has no -FilePath; the tool it starts cannot be determined and must not be guessed."
                }
                # A wrapper call INSIDE a helper's own body is that helper's
                # implementation, not a distinct call site: the callers are
                # already counted at their own lines.
                if ($script:InvImplementationScopes -contains $scope) { continue }
                $kind = $(if ($filePath -match "^'") { 'wrapped-static' } else { 'wrapped-dynamic' })
                $callee = $filePath
            }
            elseif ($script:InvSubWrappers -contains $name) { $kind = 'sub-wrapper'; $callee = $name }
            elseif ($script:InvNative -contains $name) { $kind = 'bare-native'; $callee = $name }
            else { continue }

            $sites.Add([pscustomobject]@{
                file = $file.Name; line = $c.Extent.StartLineNumber; column = $c.Extent.StartColumnNumber
                scope = $scope; kind = $kind; callee = $callee
            })
        }
    }

    # ordinal_in_line disambiguates two starts on one physical line.
    $byLine = @{}
    $ordered = @($sites | Sort-Object file, line, column)
    foreach ($s in $ordered) {
        $key = "$($s.file)|$($s.line)"
        if (-not $byLine.ContainsKey($key)) { $byLine[$key] = 0 }
        $byLine[$key]++
        $s | Add-Member -NotePropertyName ordinal_in_line -NotePropertyValue $byLine[$key] -Force
        $s | Add-Member -NotePropertyName key -NotePropertyValue "$($s.file)|$($s.line)|$($byLine[$key])" -Force
    }

    return [pscustomobject]@{ Sites = $ordered; Dynamic = @($dynamic | Sort-Object file, line) }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Get-K8CommandInventory -ToolsDir $ToolsDir
    if ($AsText) {
        $result.Sites | ForEach-Object { '{0}:{1}#{2}  {3}  {4}  {5}' -f $_.file, $_.line, $_.ordinal_in_line, $_.scope, $_.kind, $_.callee }
        '--- UNRESOLVED-DYNAMIC (adjudicated by hand, never dropped) ---'
        $result.Dynamic | ForEach-Object { '{0}:{1}  {2}  {3}' -f $_.file, $_.line, $_.scope, $_.expression }
    }
    else { $result }
}
