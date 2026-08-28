#Requires -Version 7.0
<#
.SYNOPSIS
    Repo-side Shakedown regression checks. Not a certification framework --
    these run without Docker/VM and without a real Amenonuboco checkout; they
    catch drift and typos in the tooling, not runtime behavior.

.DESCRIPTION
    Checks:
      1. cp932/UTF-8 dependency-decode fix, against a synthetic file with the
         same decode-hazard shape as the real requirements.txt (no network
         dependency on the real file).
      2. Pinned commits/tag/digest in K8ShakedownCommon.psm1 match
         Study01/README.md (catches copy-paste drift between the two).
      3. cwd/path: Start-K8Shakedown.ps1 refuses to run outside a real
         Toyotamahime checkout.
      4. Runner argument coverage: every --required flag the real frozen CLI
         scripts declare (via their own -h) is present in the ArgumentList
         this tooling builds for them.
      5. Range C runner does not throw on validator exit 1 (the expected,
         not-forced outcome).
      6. Study01/ is byte-for-byte unmodified on this branch versus origin/main.

    Exits 0 if all checks pass, 1 otherwise. Prints PASS/FAIL per check.

.EXAMPLE
    pwsh -File .\tests\Test-K8ShakedownRegression.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # .../toyotamahime
$ShakedownDir = Join-Path $RepoRoot 'shakedown'
$ToolsDir = Join-Path $ShakedownDir 'tools'
$Study01 = Join-Path $RepoRoot 'Study01'
$SenderProcedureDoc = Join-Path $Study01 'studies\study-01-negative-result\protocol\c2-dnp3-sender-procedure.md'

$failures = @()
function Assert-K8Test {
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][scriptblock] $Body)
    try {
        & $Body
        Write-Host "PASS  $Name" -ForegroundColor Green
    }
    catch {
        Write-Host "FAIL  $Name -- $($_.Exception.Message)" -ForegroundColor Red
        $script:failures += $Name
    }
}

# --- 1. cp932/UTF-8 dependency-decode fix -----------------------------------

Assert-K8Test 'cp932 fix: PYTHONUTF8=1 makes locale.getpreferredencoding(False) return UTF-8' {
    $withoutFlag = (python -c "import sys,locale; sys.stdout.write('1' if sys.flags.utf8_mode else '0')")
    $withFlag = (python -X utf8 -c "import sys,locale; sys.stdout.write(locale.getpreferredencoding(False))")
    if ($withFlag -ne 'UTF-8') {
        throw "expected 'UTF-8' with -X utf8 / PYTHONUTF8=1, got '$withFlag' (utf8_mode without flag: $withoutFlag). Python version/behavior may have changed -- do not assume the fix still holds."
    }
}

Assert-K8Test 'cp932 fix: reproduces + resolves on a synthetic file with the real decode-hazard shape (no BOM, no PEP263 line, UTF-8 non-ASCII)' {
    $tmp = New-TemporaryFile
    # Same shape as amenonuboco-v0.13.0/requirements.txt: a leading '#' comment
    # line with Japanese text (so it can never be mistaken for a PEP263
    # `# coding:` line), CRLF line endings, UTF-8 bytes, no BOM.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("# Amenonuboco プロビジョナ本体の実行時依存。`r`npydantic>=2.0,<3.0`r`n")
    [System.IO.File]::WriteAllBytes($tmp.FullName, $bytes)
    $checkScript = @"
import sys, locale
locale_enc = locale.getpreferredencoding(False)
with open(r'$($tmp.FullName)', 'rb') as f:
    data = f.read()
try:
    data.decode(locale_enc)
    sys.stdout.write('DECODED:' + locale_enc)
except UnicodeDecodeError as e:
    sys.stdout.write('FAILED:' + locale_enc)
"@
    $result = python -c $checkScript
    # This assertion only bites on a host whose default locale can't decode
    # UTF-8 (e.g. cp932); elsewhere it degrades to an informational skip
    # rather than a false failure, since the underlying pip decode-order bug
    # is orthogonal to whether *this* host's locale happens to reproduce it.
    if ($result -like 'FAILED:*') {
        $withFix = python -X utf8 -c $checkScript
        if ($withFix -notlike 'DECODED:*') {
            throw "host locale ($result) fails to decode as expected, but -X utf8 did not fix it either ($withFix)"
        }
    }
    else {
        Write-Host "  (informational: this host's default locale is $result, which already decodes the synthetic file -- the cp932 hazard does not reproduce here, but the fix mechanism above is still verified independently)" -ForegroundColor DarkGray
    }
    Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
}

Assert-K8Test 'Install-K8RangeCDependencies sets and restores PYTHONUTF8 around the pip call' {
    $src = Get-Content (Join-Path $ToolsDir 'K8ShakedownCommon.psm1') -Raw
    if ($src -notmatch "function Install-K8RangeCDependencies") { throw 'function not found' }
    if ($src -notmatch "\`$env:PYTHONUTF8 = '1'") { throw 'PYTHONUTF8=1 not set' }
    if ($src -notmatch 'Remove-Item Env:\\PYTHONUTF8') { throw 'PYTHONUTF8 not restored/cleaned up in a finally block' }
}

# --- 2. Pinned values match Study01/README.md --------------------------------

Assert-K8Test 'Pinned Amenonuboco/tcpdump values match Study01/README.md' {
    $readme = Get-Content (Join-Path $Study01 'README.md') -Raw
    $common = Get-Content (Join-Path $ToolsDir 'K8ShakedownCommon.psm1') -Raw
    $pins = @(
        '78fc17746b5d663fafec9dffe563d79fe9ea02b7',
        '0378f8a32701b481e030f3db3d5f66ea471a4675',
        'v0.13.0',
        'sha256:3006b3bd9f041bf73f21e626b97cca5e78fd6ce271549ca95b8e6a508165512b'
    )
    foreach ($pin in $pins) {
        if ($readme -notlike "*$pin*") { throw "pin '$pin' not found in Study01/README.md -- test's own pin list is stale" }
        if ($common -notlike "*$pin*") { throw "pin '$pin' is in Study01/README.md but missing from K8ShakedownCommon.psm1 -- drift" }
    }
}

Assert-K8Test 'Pinned sender asset SHA-256 matches c2-dnp3-sender-procedure.md' {
    $senderDoc = Get-Content $SenderProcedureDoc -Raw
    $common = Get-Content (Join-Path $ToolsDir 'K8ShakedownCommon.psm1') -Raw
    $pin = '093FEFD5F1F36D715AAE4D7AB91DBAD2D7A93BFE212705D721C95B356A7C053B'
    if ($senderDoc -notlike "*$pin*") { throw "pin '$pin' not found in c2-dnp3-sender-procedure.md -- test's own pin is stale" }
    if ($common -notlike "*$pin*") { throw "pin '$pin' is in c2-dnp3-sender-procedure.md but missing from K8ShakedownCommon.psm1 -- drift" }
}

# --- 3. cwd/path guard --------------------------------------------------------

Assert-K8Test 'Start-K8Shakedown.ps1 refuses to run when Study01/README.md is not found beside it' {
    $src = Get-Content (Join-Path $ToolsDir 'Start-K8Shakedown.ps1') -Raw
    if ($src -notmatch "README\.md.*not found") { throw 'no guard for a missing Study01/README.md found in source' }
}

# --- 4. Runner argument coverage against the real scripts' own argparse ------
#
# Per-invocation, not whole-module: a whole-file substring search cannot tell
# apart two different Invoke-K8ShakedownCommand call sites for the same
# script, so a flag required by one call but only ever typed near a *different*
# call would have passed. This parses the module's AST, finds every actual
# Invoke-K8ShakedownCommand call site, classifies which frozen script/
# subcommand each one targets by inspecting that call's own source text, and
# checks that call's own argument text (not the rest of the file) contains
# every flag its target's real -h output marks required.

$ScriptsDir = Join-Path $Study01 'studies\study-01-negative-result\scripts'
$CommonPath = Join-Path $ToolsDir 'K8ShakedownCommon.psm1'

function Get-K8RequiredFlags {
    param([string] $HelpText)
    # argparse prints required options bare ("--flag VALUE") and optional ones
    # bracketed ("[--flag VALUE]"); a flag is required here only if it never
    # appears inside [...] anywhere in the help text.
    $all = [regex]::Matches($HelpText, '--[a-z0-9-]+') | ForEach-Object { $_.Value } | Sort-Object -Unique
    $bracketed = [regex]::Matches($HelpText, '\[--[a-z0-9-]+') | ForEach-Object { $_.Value.TrimStart('[') } | Sort-Object -Unique
    return $all | Where-Object { $bracketed -notcontains $_ -and $_ -ne '--help' }
}

function Get-K8InvocationCallSites {
    <#
        Returns one object per actual Invoke-K8ShakedownCommand call site in
        K8ShakedownCommon.psm1: { Text = <that call's own source>,
        Target = '<script.py>[:subcommand]' or $null if unrecognized }.
    #>
    param([string] $Path)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "parse errors in $Path`: $($errors -join '; ')" }
    $calls = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.CommandElements.Count -gt 0 -and
        $node.CommandElements[0].Extent.Text -eq 'Invoke-K8ShakedownCommand'
    }, $true)
    $known = @(
        @{ Script = 'study01_preflight.py'; Sub = $null },
        @{ Script = 'study01_sender.py';    Sub = $null },
        @{ Script = 'study01_collect.py';   Sub = $null },
        @{ Script = 'study01_capture.py';   Sub = 'resolve' },
        @{ Script = 'study01_capture.py';   Sub = 'start' },
        @{ Script = 'study01_capture.py';   Sub = 'stop-export' }
    )
    foreach ($call in $calls) {
        $text = $call.Extent.Text
        $target = $null
        foreach ($k in $known) {
            if ($text -notmatch [regex]::Escape($k.Script)) { continue }
            if ($null -eq $k.Sub -or $text -match "'$([regex]::Escape($k.Sub))'") {
                $target = if ($k.Sub) { "$($k.Script):$($k.Sub)" } else { $k.Script }
                break
            }
        }
        [pscustomobject]@{ Text = $text; Target = $target }
    }
}

$callSites = Get-K8InvocationCallSites -Path $CommonPath

$checks = @(
    @{ Target = 'study01_preflight.py';            Script = 'study01_preflight.py'; Args = @() },
    @{ Target = 'study01_capture.py:resolve';      Script = 'study01_capture.py';   Args = @('resolve') },
    @{ Target = 'study01_capture.py:start';        Script = 'study01_capture.py';   Args = @('start') },
    @{ Target = 'study01_capture.py:stop-export';  Script = 'study01_capture.py';   Args = @('stop-export') },
    @{ Target = 'study01_sender.py';               Script = 'study01_sender.py';    Args = @() }
)
foreach ($c in $checks) {
    Assert-K8Test "Runner passes every required flag, per call site, for: $($c.Target)" {
        $sites = @($callSites | Where-Object { $_.Target -eq $c.Target })
        if ($sites.Count -eq 0) {
            throw "no Invoke-K8ShakedownCommand call site found targeting '$($c.Target)' -- this stage is not wired up at all"
        }
        $help = & python (Join-Path $ScriptsDir $c.Script) @($c.Args) -h 2>&1 | Out-String
        $required = Get-K8RequiredFlags -HelpText $help
        foreach ($site in $sites) {
            foreach ($flag in $required) {
                if ($site.Text -notmatch [regex]::Escape($flag)) {
                    throw "required flag '$flag' (from '$($c.Target) -h') missing from this specific call site:`n$($site.Text)"
                }
            }
        }
    }
}

Assert-K8Test 'study01_collect.py is invoked for validate-evidence, finalize-evidence, and verify-integrity' {
    $sites = @($callSites | Where-Object { $_.Target -eq 'study01_collect.py' })
    foreach ($sub in @('validate-evidence', 'finalize-evidence', 'verify-integrity')) {
        if (-not ($sites | Where-Object { $_.Text -match [regex]::Escape($sub) })) {
            throw "no study01_collect.py call site found passing '$sub'"
        }
    }
}

# --- 5. Range C: exit 1 is expected, not thrown on -----------------------------

Assert-K8Test 'Run-K8ShakedownRangeC.ps1 does not throw on validator exit 1' {
    $src = Get-Content (Join-Path $ToolsDir 'Run-K8ShakedownRangeC.ps1') -Raw
    if ($src -match 'if\s*\(\s*\$exitCode\s*-ne\s*0\s*\)\s*\{\s*throw') {
        throw 'found a throw gated on non-zero validator exit code -- exit 1 is the expected outcome and must not raise'
    }
    if ($src -notmatch 'EXPECTED outcome') {
        throw 'no comment/log documenting that exit 1 is expected -- add one so this is not silently "fixed" later'
    }
}

# --- 6. Study01/ untouched on this branch -------------------------------------

Assert-K8Test 'Study01/ is byte-for-byte unchanged versus origin/main' {
    Push-Location $RepoRoot
    try {
        git fetch origin main --quiet 2>$null
        $diff = git diff --stat origin/main -- Study01 bootstrap docs/k8-packaging-certification.md 2>&1
        if ($diff) { throw "frozen paths differ from origin/main:`n$diff" }
    }
    finally { Pop-Location }
}

# --- Summary -------------------------------------------------------------------

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) check(s) FAILED: $($failures -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host 'All Shakedown regression checks PASS.' -ForegroundColor Green
exit 0
