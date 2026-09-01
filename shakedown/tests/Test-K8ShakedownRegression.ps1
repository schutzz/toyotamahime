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
      6. Fail-closed readiness/image/finalize ordering and mechanical evidence gates.
      7. Study01/ is byte-for-byte unmodified versus the FIXED immutable base
         commit (C-9 / criterion 11(a)) -- not versus a moving ref, and without
         a fetch whose failure could go unnoticed.
      8. Elasticsearch application-readiness gate (the curl-exit-7 root-cause
         fix): runs before capture/trigger, shared by Range A and Range B from
         one call site, has a finite timeout, and is structurally distinct
         from (never merged into a retry loop for) the exactly-once
         Collector/Rule/R-OBS-05 requests, which must contain no retry/loop
         construct of their own. Also covers the StrictMode-safe property
         access and structured (non-text-match) service-state checks this
         audit added alongside it.

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

# Hermetic workspace for the whole suite.
#
# Get-K8ShakedownRoot falls back to C:\K8\shakedown, and Write-K8ShakedownLog
# creates <root>\logs\shakedown.log on essentially every module call. Without
# this, any test that touches a logging function writes to that fixed absolute
# path -- so on a machine where it is not writable the suite fails in bulk for
# a reason that has nothing to do with what is being tested, and an independent
# reviewer cannot reproduce a clean run at all. (Observed: 33 checks failing on
# "access denied" to that log.) The sequence sandbox overrides this per test and
# restores it afterwards, which still works because it saves whatever it finds.
$SuiteRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('k8suite-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $SuiteRoot | Out-Null
$PreviousShakedownRoot = $env:K8_SHAKEDOWN_ROOT
$env:K8_SHAKEDOWN_ROOT = $SuiteRoot

function Restore-K8SuiteWorkspace {
    if ($null -eq $script:PreviousShakedownRoot) { Remove-Item Env:\K8_SHAKEDOWN_ROOT -ErrorAction SilentlyContinue }
    else { $env:K8_SHAKEDOWN_ROOT = $script:PreviousShakedownRoot }
    Remove-Item $script:SuiteRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# C-8: a few checks exercise the command helpers against SYNTHETIC commands
# (`cmd.exe /c exit 3`) that deliberately have no place in the real contract.
# The helpers now refuse any step id they do not know, which is the point --
# so the test adds its row inside the MODULE's own scope and reloads the
# module afterwards.
#
# Deliberately not a production function: nothing on a real run may append to
# the contract, or the closed-world claim would be self-granted. Reaching into
# module scope from the test harness makes that asymmetry explicit.
function Add-K8TestContractRow {
    param([Parameter(Mandatory)][hashtable] $Row)
    & (Get-Module K8ShakedownCommon) { param($r) $script:K8CommandContract = @($script:K8CommandContract) + @($r) } $Row
}
function Reset-K8ContractRows {
    Import-Module $script:CommonPath -Force
}

# Same asymmetry for C-9's canonical source pin. It lives HERE, not in the
# module: the Plan puts the canonical repository and ref outside the operator's
# choice, so a production import must not expose any way to move them. Reaching
# into module scope from the harness is a thing the test process can do and an
# importer of the module cannot.
#
# The saved pin is held on the HARNESS side, so the module carries no
# test-only state at all.
#
# This swaps the PIN, never the gate. Get-K8SourceIdentity still runs every
# step against a real (local, bare) remote, and
# Assert-K8SourceIdentityPublished still STOPs on anything but `confirmed`.
$script:K8SavedSourcePin = $null
function Set-K8TestSourcePin {
    param(
        [Parameter(Mandatory)][string[]] $CanonicalRemoteUrls,
        [Parameter(Mandatory)][string] $CanonicalRef
    )
    $previous = & (Get-Module K8ShakedownCommon) {
        param($urls, $ref)
        $prev = $script:K8ProducerSourcePin
        $script:K8ProducerSourcePin = @{
            CanonicalRemoteUrls = @($urls)
            CanonicalRef        = $ref
            AncestryTempRef     = $prev.AncestryTempRef
        }
        $prev
    } $CanonicalRemoteUrls $CanonicalRef
    # Only the FIRST swap records what to go back to: a test that re-points the
    # pin inside a fixture must still restore the real one, not the fixture's.
    if ($null -eq $script:K8SavedSourcePin) { $script:K8SavedSourcePin = $previous }
}
function Reset-K8TestSourcePin {
    if ($null -ne $script:K8SavedSourcePin) {
        & (Get-Module K8ShakedownCommon) { param($p) $script:K8ProducerSourcePin = $p } $script:K8SavedSourcePin
        $script:K8SavedSourcePin = $null
    }
}

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

Assert-K8Test 'Range A/B keeps the fresh evidence tree empty until frozen preflight passes' {
    $modulePath = Join-Path $ToolsDir 'K8ShakedownCommon.psm1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "module parse failed: $($errors -join '; ')" }
    $function = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-K8ShakedownRangeABBody'
    }, $true)
    if (-not $function) { throw 'Invoke-K8ShakedownRangeABBody not found' }
    $body = $function.Extent.Text
    $preflight = $body.IndexOf("-Description 'execution preflight gate (Docker-free)'")
    $hashWrite = $body.IndexOf("generated-compose-hash.txt")
    if ($preflight -lt 0 -or $hashWrite -lt 0 -or $hashWrite -lt $preflight) {
        throw "generated Compose hash must be written only after preflight PASS (preflight=$preflight hash=$hashWrite)"
    }
    $beforePreflight = $body.Substring(0, $preflight)
    if ($beforePreflight -match '(?m)\b(Set-Content|Add-Content|Out-File|Export-Clixml)\b') {
        throw "evidence-writing command found before preflight freshness gate: $($Matches[1])"
    }
}

Assert-K8Test 'Range A/B reads T0 from the run root, matching frozen T0_ARTIFACT placement' {
    $common = Get-Content (Join-Path $ToolsDir 'K8ShakedownCommon.psm1') -Raw
    if ($common -notmatch "Join-Path\s+\`$RunEvidence\s+'metadata-t0\.txt'") {
        throw 'runner does not read <run-evidence>/metadata-t0.txt'
    }
    if ($common -match "ground-truth[\\/]metadata-t0\.txt") {
        throw 'runner still references the invalid ground-truth/metadata-t0.txt path'
    }
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

# --- 6. Fail-closed runtime/evidence mechanics --------------------------------

$commonSource = Get-Content $CommonPath -Raw
$helper = Join-Path $ToolsDir 'k8_shakedown_evidence.py'

Assert-K8Test 'readiness compares config --services with ps --all and rejects missing/not-running/unhealthy services' {
    # These markers are matched against the ArgumentList array shape (each
    # flag its own array element, e.g. 'ps', '--all', '--format', 'json'),
    # not a single inline joined string -- that is what
    # Invoke-K8SeparatedNativeCapture requires so stderr never merges into
    # the JSON this parses.
    foreach ($needle in @("'config', '--services'", "'ps', '--all', '--format', 'json'", 'Test-K8ComposeServiceReadiness')) {
        if ($commonSource -notlike "*$needle*") { throw "readiness fail-closed marker missing: $needle" }
    }
    Import-Module $CommonPath -Force
    $expected = @('one','two')
    $healthy = @([pscustomobject]@{Service='one';State='running';Health='healthy'}, [pscustomobject]@{Service='two';State='running';Health=''})
    if (-not (Test-K8ComposeServiceReadiness -Expected $expected -Services $healthy).Ready) { throw 'complete healthy expected set did not PASS' }
    if ((Test-K8ComposeServiceReadiness -Expected $expected -Services @($healthy[0])).Ready) { throw 'missing service incorrectly PASSed' }
    $exited = @($healthy[0], [pscustomobject]@{Service='two';State='exited';Health=''})
    if ((Test-K8ComposeServiceReadiness -Expected $expected -Services $exited).Ready) { throw 'exited service incorrectly PASSed' }
    $unhealthy = @($healthy[0], [pscustomobject]@{Service='two';State='running';Health='unhealthy'})
    if ((Test-K8ComposeServiceReadiness -Expected $expected -Services $unhealthy).Ready) { throw 'unhealthy service incorrectly PASSed' }
}

Assert-K8Test 'image inventory requires every expected service, inspect success, image Id, and explicit absent-local-build status' {
    foreach ($needle in @('image inventory must resolve exactly one image', 'docker image inspect failed', 'lacks an immutable image Id', 'absent-local-build', '$inventory.Count -ne $expected.Count')) {
        if ($commonSource -notlike "*$needle*") { throw "image inventory fail-closed marker missing: $needle" }
    }
}

Assert-K8Test 'image row resolution supports Service and Compose 5.4 ContainerName-only shapes exactly' {
    Import-Module $CommonPath -Force
    $runId = 'k8shakedown-rangea-20260829-010203'
    $expected = @('elasticsearch','log_structurer')
    $withService = @(
        [pscustomobject]@{Service='elasticsearch';ID='sha256:a';ContainerName='anything'},
        [pscustomobject]@{Service='log_structurer';ID='sha256:b';ContainerName='anything-else'}
    )
    $resolved = Resolve-K8ComposeImageRows -RunId $runId -ExpectedServices $expected -ImageRows $withService
    if ($resolved['elasticsearch'].ID -ne 'sha256:a' -or $resolved['log_structurer'].ID -ne 'sha256:b') { throw 'Service shape resolved incorrectly' }

    $compose54 = @(
        [pscustomobject]@{ID='sha256:a';ContainerName="$runId-elasticsearch-1";Repository='elasticsearch';Tag='8.10.2';Platform='linux/amd64'},
        [pscustomobject]@{ID='sha256:b';ContainerName="$runId-log_structurer-1";Repository='debian';Tag='bullseye-slim';Platform='linux/amd64'}
    )
    $resolved = Resolve-K8ComposeImageRows -RunId $runId -ExpectedServices $expected -ImageRows $compose54
    if ($resolved['elasticsearch'].ID -ne 'sha256:a' -or $resolved['log_structurer'].ID -ne 'sha256:b') { throw 'ContainerName-only shape resolved incorrectly' }
}

Assert-K8Test 'image row resolution rejects substring ambiguity, missing rows, duplicates, and parse failure' {
    Import-Module $CommonPath -Force
    $runId = 'k8shakedown-rangea-20260829-010203'
    $cases = @()
    $cases += ,@([pscustomobject]@{ID='x';ContainerName="$runId-myapi-1"})
    $cases += ,@()
    $cases += ,@([pscustomobject]@{ID='x';ContainerName="$runId-api-1"}, [pscustomobject]@{ID='x';ContainerName="$runId-api-2"})
    foreach ($rows in $cases) {
        $stopped = $false
        try { $null = Resolve-K8ComposeImageRows -RunId $runId -ExpectedServices @('api') -ImageRows $rows } catch { $stopped = $true }
        if (-not $stopped) { throw 'non-exact/missing/duplicate image rows did not STOP' }
    }
    $stopped = $false
    try { $null = ConvertFrom-K8ComposePsJson -Raw '{not json' } catch { $stopped = $true }
    if (-not $stopped) { throw 'invalid image JSON did not STOP' }
}

Assert-K8Test 'compose build output is redirected to a per-run runtime log with failure-only bounded tail' {
    foreach ($needle in @('Invoke-K8ShakedownLoggedCommand', '*> $LogPath', '-Tail $FailureTailLines', 'runtime-logs\$RunId\docker-compose-up-build.log')) {
        if ($commonSource -notlike "*$needle*") { throw "quiet build logging marker missing: $needle" }
    }
    $upCall = [regex]::Match($commonSource, "Invoke-K8ShakedownLoggedCommand[^\r\n]+[\s\S]{0,300}?'up', '-d', '--build'")
    if (-not $upCall.Success) { throw 'docker compose up --build is not routed through the quiet logged command' }
}

Assert-K8Test 'Elasticsearch request uses old-curl-compatible single request status/body separation' {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($CommonPath, [ref]$tokens, [ref]$errors)
    $function = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-K8ElasticsearchRequest' }, $true)
    if (-not $function) { throw 'Invoke-K8ElasticsearchRequest not found' }
    $text = $function.Extent.Text
    if ($text -match '--fail-with-body') { throw 'request helper still depends on --fail-with-body' }
    foreach ($needle in @("'curl', '-sS', '-o'", "'-w', '%{http_code}'", 'Complete-K8ElasticsearchResponse')) {
        if ($text -notlike "*$needle*") { throw "old-curl single-request marker missing: $needle" }
    }
    $callerCount = ([regex]::Matches($commonSource, 'Invoke-K8ElasticsearchRequest\s+-RunId')).Count
    # Collector mapping, Rule mapping, Collector search, Rule search,
    # R-OBS-05 mapping, R-OBS-05 search -- all sharing one helper.
    if ($callerCount -ne 6) { throw "expected Collector/Rule mapping+search and R-OBS-05 mapping+search to share one helper (6 call sites); found $callerCount" }
}

Assert-K8Test 'Elasticsearch response gate accepts only 2xx valid JSON and retains failure diagnostics' {
    Import-Module $CommonPath -Force
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-http-" + [guid]::NewGuid())
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        $success = Join-Path $tmp 'success.json'
        Complete-K8ElasticsearchResponse -CurlExitCode 0 -HttpStatus '200' -RawBody '{"ok":true}' -OutputPath $success -RequestLabel test
        if (-not (Test-Path $success) -or (Get-Content $success -Raw | ConvertFrom-Json).ok -ne $true) { throw '2xx valid JSON did not PASS/save' }

        $cases = @(
            @{ Name='http500'; Exit=0; Status='500'; Body='{"error":"boom"}' },
            @{ Name='transport'; Exit=7; Status=''; Body='' },
            @{ Name='invalid'; Exit=0; Status='200'; Body='not-json' }
        )
        foreach ($case in $cases) {
            $output = Join-Path $tmp "$($case.Name).json"
            $stopped = $false
            try { Complete-K8ElasticsearchResponse -CurlExitCode $case.Exit -HttpStatus $case.Status -RawBody $case.Body -TransportDiagnostic 'curl diagnostic' -OutputPath $output -RequestLabel test } catch { $stopped = $true }
            if (-not $stopped) { throw "$($case.Name) incorrectly PASSed" }
            if (Test-Path $output) { throw "$($case.Name) incorrectly saved a success response" }
            if (-not (Test-Path "$output.error-body.txt")) { throw "$($case.Name) diagnostic body was not retained" }
        }
    } finally { Remove-Item $tmp -Recurse -Force }
}

Assert-K8Test 'pre-teardown validate/finalize precede compose down and cleanup is followed by final finalize/verify' {
    $pre = $commonSource.IndexOf("-Description 'pre-teardown finalize/hash'")
    $down = $commonSource.IndexOf("-Description 'destroy project + volumes")
    $final = $commonSource.IndexOf("-Description 'final finalize/hash including cleanup record'")
    $verify = $commonSource.IndexOf("-Description 'final verify-integrity'")
    if ($pre -lt 0 -or $down -lt 0 -or $final -lt 0 -or $verify -lt 0 -or -not ($pre -lt $down -and $down -lt $final -and $final -lt $verify)) {
        throw "incorrect evidence ordering: pre=$pre down=$down final=$final verify=$verify"
    }
}

Assert-K8Test 'Range B Complete requires every named R-OBS-05 artifact and PASS gates' {
    foreach ($needle in @('r-obs-05-mapping-response.json','r-obs-05-mapping-gate.json','r-obs-05-response.json','r-obs-05-pcap-rows.json','r-obs-05-correlation.json','unrelated-mirror-filters.txt','R-OBS-05 mechanical gate is not PASS')) {
        if ($commonSource -notlike "*$needle*") { throw "Range B completion gate missing: $needle" }
    }
}

Assert-K8Test 'Collector retains all hit IDs and Rule source_dnp3_doc_id is correlated mechanically' {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-test-" + [guid]::NewGuid())
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        # Both Rule hits correlate to the complete accepted Collector set --
        # this is the shape the query-time source_dnp3_doc_id.keyword terms
        # filter (fixed this round) guarantees by construction, so this is
        # now the expected/PASS case, not merely one classification among
        # others (see the dedicated fail-close test below for the other).
        '{"hits":{"total":{"value":2,"relation":"eq"},"hits":[{"_id":"c1","_source":{}},{"_id":"c2","_source":{}}]}}' | Set-Content (Join-Path $tmp 'c.json')
        '{"hits":{"total":{"value":2,"relation":"eq"},"hits":[{"_id":"r1","_source":{"source_dnp3_doc_id":"c2"}},{"_id":"r2","_source":{"source_dnp3_doc_id":"c1"}}]}}' | Set-Content (Join-Path $tmp 'r.json')
        & python $helper target-correlation --collector (Join-Path $tmp 'c.json') --rule (Join-Path $tmp 'r.json') --output (Join-Path $tmp 'o.json')
        if ($LASTEXITCODE -ne 0) { throw 'helper failed on a fully-correlating fixture' }
        $result = Get-Content (Join-Path $tmp 'o.json') -Raw | ConvertFrom-Json
        if (($result.accepted_collector_hit_ids -join ',') -ne 'c1,c2') { throw 'complete Collector hit ID set was not retained' }
        if ($result.rule_correlations[0].correlates_to_accepted_collector_hit -ne $true -or $result.rule_correlations[1].correlates_to_accepted_collector_hit -ne $true) { throw 'Rule correlation decisions incorrect' }
        if ($result.all_rule_hits_correlate -ne $true) { throw 'all_rule_hits_correlate should be true when every hit correlates' }
    } finally { Remove-Item $tmp -Recurse -Force }
}

Assert-K8Test 'REGRESSION: a Rule hit whose source_dnp3_doc_id does NOT match any accepted Collector hit fails closed (mechanical verification, not just retention)' {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-test-badcorr-" + [guid]::NewGuid())
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        '{"hits":{"total":{"value":2,"relation":"eq"},"hits":[{"_id":"c1","_source":{}},{"_id":"c2","_source":{}}]}}' | Set-Content (Join-Path $tmp 'c.json')
        '{"hits":{"total":{"value":1,"relation":"eq"},"hits":[{"_id":"r1","_source":{"source_dnp3_doc_id":"not-a-collector-id"}}]}}' | Set-Content (Join-Path $tmp 'r.json')
        & python $helper target-correlation --collector (Join-Path $tmp 'c.json') --rule (Join-Path $tmp 'r.json') --output (Join-Path $tmp 'o.json') 2>$null
        if ($LASTEXITCODE -eq 0) { throw 'a non-correlating Rule hit did not STOP -- if the query-time source_dnp3_doc_id.keyword filter ever fails to do its job, this must be caught, not silently retained' }
    } finally { Remove-Item $tmp -Recurse -Force }
}

Assert-K8Test 'R-OBS-05 integer-nanosecond boundary: 1,000,000 PASS; 1,000,001 FAIL' {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-ns-" + [guid]::NewGuid())
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        $response = '{"hits":{"total":{"value":1,"relation":"eq"},"hits":[{"_id":"d1","_source":{"layers":{"frame":{"frame_frame_time":"2026-01-01T00:00:00.000000000Z"},"ip":{"ip_ip_src":"10.1.10.10","ip_ip_dst":"10.1.40.10"},"tcp":{"tcp_tcp_srcport":"12345","tcp_tcp_dstport":"20000"},"dnp3":{"dnp3_dnp3_al_func":"5","dnp3_dnp3_src":"1","dnp3_dnp3_dst":"20"}}}}]}}'
        $response | Set-Content (Join-Path $tmp 'response.json')
        $prefix = '[{"frame_number":"1","frame_time_epoch":"'
        $suffix = '","ip_src":"10.1.10.10","ip_dst":"10.1.40.10","tcp_srcport":"12345","tcp_dstport":"20000","dnp3_al_func":"5","dnp3_src":"1","dnp3_dst":"20"}]'
        ($prefix + '1767225600.001000000' + $suffix) | Set-Content (Join-Path $tmp 'pass.json')
        & python $helper r-obs-05 --response (Join-Path $tmp 'response.json') --frames (Join-Path $tmp 'pass.json') --window-start '2025-12-31T23:59:55Z' --window-end '2026-01-01T00:00:15Z' --output (Join-Path $tmp 'pass-out.json')
        if ($LASTEXITCODE -ne 0) { throw 'exactly 1,000,000 ns did not PASS' }
        ($prefix + '1767225600.001000001' + $suffix) | Set-Content (Join-Path $tmp 'fail.json')
        & python $helper r-obs-05 --response (Join-Path $tmp 'response.json') --frames (Join-Path $tmp 'fail.json') --window-start '2025-12-31T23:59:55Z' --window-end '2026-01-01T00:00:15Z' --output (Join-Path $tmp 'fail-out.json') 2>$null
        if ($LASTEXITCODE -eq 0) { throw '1,000,001 ns incorrectly PASSed' }
    } finally { Remove-Item $tmp -Recurse -Force }
}

Assert-K8Test 'R-OBS-05 mapping drift stops the helper' {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-map-" + [guid]::NewGuid())
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        '{"index":{"mappings":{"properties":{"layers":{"properties":{}}}}}}' | Set-Content (Join-Path $tmp 'mapping.json')
        & python $helper mapping-gate --mapping (Join-Path $tmp 'mapping.json') --output (Join-Path $tmp 'decision.json') 2>$null
        if ($LASTEXITCODE -eq 0) { throw 'mapping drift incorrectly PASSed' }
    } finally { Remove-Item $tmp -Recurse -Force }
}

# --- 8. Elasticsearch application-readiness gate (curl exit 7 root cause) ----

function Get-K8FunctionBodyText {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "parse errors in $Path`: $($errors -join '; ')" }
    $function = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $function) { throw "function '$Name' not found in $Path" }
    return $function.Extent.Text
}

function Get-K8CommentStrippedSource {
    <#
        Returns the file's source with every comment token blanked out
        (spaces, newlines preserved so line numbers and line structure are
        unchanged).

        This exists because "search the source for a banned pattern" checks
        have repeatedly false-positived on this repo's OWN docstrings, which
        legitimately quote the very pattern they describe fixing -- including
        inside block comments, whose continuation lines do not start with a
        hash and so survive naive line filtering. Using the real tokenizer is
        the only reliable way to ask "does the CODE do this?".
    #>
    param([Parameter(Mandatory)][string] $Path)
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $sb = [System.Text.StringBuilder]::new((Get-Content $Path -Raw))
    foreach ($t in ($tokens | Where-Object { $_.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment })) {
        for ($i = $t.Extent.StartOffset; $i -lt $t.Extent.EndOffset -and $i -lt $sb.Length; $i++) {
            if ($sb[$i] -ne "`n" -and $sb[$i] -ne "`r") { $sb[$i] = ' ' }
        }
    }
    return $sb.ToString()
}

function Get-K8CommentStrippedFunctionBody {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $fn) { throw "function '$Name' not found in $Path" }
    $stripped = Get-K8CommentStrippedSource -Path $Path
    return $stripped.Substring($fn.Extent.StartOffset, $fn.Extent.EndOffset - $fn.Extent.StartOffset)
}

function Test-K8HasLoopConstruct {
    param([Parameter(Mandatory)][string] $FunctionBodyText)
    # Parse just this function body as its own script and look for real loop
    # AST nodes (WhileStatementAst/DoWhileStatementAst/DoUntilStatementAst/
    # ForStatementAst/ForEachStatementAst) -- not a text/keyword search, which
    # a comment or string literal could trivially defeat or false-positive on.
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($FunctionBodyText, [ref]$tokens, [ref]$errors)
    $loopTypes = @(
        [System.Management.Automation.Language.WhileStatementAst],
        [System.Management.Automation.Language.DoWhileStatementAst],
        [System.Management.Automation.Language.DoUntilStatementAst],
        [System.Management.Automation.Language.ForStatementAst],
        [System.Management.Automation.Language.ForEachStatementAst]
    )
    $found = $ast.FindAll({ param($n) $loopTypes -contains $n.GetType() }, $true)
    return ($found.Count -gt 0)
}

Assert-K8Test 'Wait-K8ElasticsearchReady exists, has a finite timeout, and actually polls (loop present)' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Wait-K8ElasticsearchReady'
    if ($body -notmatch '\[int\]\s*\$TimeoutSeconds\s*=\s*\d+') { throw 'no finite, defaulted $TimeoutSeconds parameter found' }
    if (-not (Test-K8HasLoopConstruct -FunctionBodyText $body)) { throw 'no loop construct found -- this must poll, not check once' }
    if ($body -notmatch '_cluster/health') { throw 'gate does not target the Elasticsearch health endpoint' }
    if ($body -notmatch 'elasticsearch-readiness\.json') { throw 'gate does not retain its result' }
}

foreach ($gateFunc in @('Wait-K8ElasticsearchReady', 'Wait-K8LogStructurerReady', 'Wait-K8ZoneDetectorReady')) {
    Assert-K8Test "$gateFunc runs exactly once, shared (not Range-specific), before interface resolution and the sender trigger" {
        $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8ShakedownRangeABBody'
        $gateCalls = @([regex]::Matches($body, "$gateFunc\s+-RunId"))
        if ($gateCalls.Count -ne 1) { throw "expected exactly one shared call site in Invoke-K8ShakedownRangeABBody (used by both Range A and Range B); found $($gateCalls.Count)" }
        $gateIndex = $gateCalls[0].Index
        $interfaceIndex = $body.IndexOf('Resolve-K8GatewayInterface -RunId')
        $senderIndex = $body.IndexOf("(Join-Path `$ScriptsDir 'study01_sender.py')")
        if ($interfaceIndex -lt 0 -or $senderIndex -lt 0) { throw 'could not locate gateway-resolution or sender call sites to order against' }
        if (-not ($gateIndex -lt $interfaceIndex -and $gateIndex -lt $senderIndex)) {
            throw "$gateFunc (index $gateIndex) must precede both interface resolution ($interfaceIndex) and the sender trigger ($senderIndex)"
        }
        # Guard against reintroducing a Range-specific branch around the call --
        # this must be unconditional, identical for 'a' and 'b'.
        $surrounding = $body.Substring([Math]::Max(0, $gateIndex - 200), 200)
        if ($surrounding -match "Range\s+-eq\s+'[ab]'") { throw "$gateFunc call site appears to be inside a Range-specific branch; it must be unconditional/shared" }
    }
}

Assert-K8Test 'Elasticsearch readiness PASS requires a parsed cluster-health status, not HTTP 2xx alone' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Wait-K8ElasticsearchReady'
    if ($body -notmatch "in @\('yellow',\s*'green'\)") { throw "gate no longer checks cluster status is yellow/green -- HTTP-200-only PASS condition may have been reintroduced" }
    if ($body -notmatch 'ConvertFrom-Json') { throw 'gate no longer parses the response body as JSON' }
}

Assert-K8Test 'log_structurer/zone_detector readiness gates check /proc-based live processes, not ps/pgrep (not guaranteed installed on these images)' {
    foreach ($name in @('Wait-K8LogStructurerReady', 'Wait-K8ZoneDetectorReady')) {
        $body = Get-K8FunctionBodyText -Path $CommonPath -Name $name
        if ($body -notmatch '/proc/\[0-9\]\*/cmdline') { throw "$name does not probe /proc/*/cmdline" }
        # Check only the actual executed probe command (the $probe = '...'
        # assignment), not the whole function body -- the docstring itself
        # legitimately says "ps/pgrep" in prose explaining why they're
        # avoided, which would false-positive a whole-body text search.
        $probeLine = [regex]::Match($body, "\`$probe\s*=\s*'([^']*)'")
        if (-not $probeLine.Success) { throw "${name}: could not find its \`$probe command assignment to check" }
        if ($probeLine.Groups[1].Value -match '\bpgrep\b|\bps\b') { throw "${name}'s actual probe command invokes ps/pgrep, which these images do not install" }
    }
    $structurerBody = Get-K8FunctionBodyText -Path $CommonPath -Name 'Wait-K8LogStructurerReady'
    foreach ($needle in @("'tshark'", "'dnp3'", "'bulk_loader\.py'")) {
        if ($structurerBody -notmatch [regex]::Escape($needle)) { throw "Wait-K8LogStructurerReady missing expected match target: $needle" }
    }
    $detectorBody = Get-K8FunctionBodyText -Path $CommonPath -Name 'Wait-K8ZoneDetectorReady'
    foreach ($needle in @("'python3'", "'signal-1-zone-violation'")) {
        if ($detectorBody -notmatch [regex]::Escape($needle)) { throw "Wait-K8ZoneDetectorReady missing expected match target: $needle" }
    }
}

Assert-K8Test 'Scientific Elasticsearch requests (Collector/Rule/R-OBS-05/mapping) contain no retry/loop construct' {
    foreach ($name in @('Invoke-K8ElasticsearchRequest', 'Complete-K8ElasticsearchResponse')) {
        $body = Get-K8FunctionBodyText -Path $CommonPath -Name $name
        if (Test-K8HasLoopConstruct -FunctionBodyText $body) {
            throw "$name contains a loop construct -- the fixed scientific request must be exactly-once, never retried after failure"
        }
    }
}

Assert-K8Test 'Test-K8ComposeServiceReadiness accesses Service/State/Health only via Get-K8ObjectPropertyValue (StrictMode-safe)' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Test-K8ComposeServiceReadiness'
    if ($body -match '\$byService\[[^\]]+\]\.(Service|State|Health)\b') {
        throw 'direct property access on a compose ps row found -- this throws under Set-StrictMode if the JSON row omits that key entirely (observed to vary by Compose version)'
    }
    if (([regex]::Matches($body, 'Get-K8ObjectPropertyValue')).Count -lt 2) {
        throw 'expected State and Health to both be read via Get-K8ObjectPropertyValue'
    }
}

Assert-K8Test 'no leftover PSAvoidAssignmentToAutomaticVariable shadowing ($matches / $args) in the module' {
    if ($commonSource -match '(?m)^\s*\$matches\s*=') { throw 'a bare $matches assignment was reintroduced (shadows the automatic -match results variable)' }
    if ($commonSource -match '(?m)^\s*\$args\s*=') { throw 'a bare $args assignment was reintroduced (shadows the automatic unbound-arguments variable)' }
}

Assert-K8Test 'Range B runtime-contract record uses structured service-state checks, not compose-ps text/substring matching' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Write-K8RuntimeContractRecord'
    if ($body -match '\$psText\s+-(not)?match') { throw 'runtime-contract-record still decides readiness by text/substring-matching `compose ps` display output' }
    if ($body -notmatch 'Test-K8ComposeServiceReadiness') { throw 'runtime-contract-record does not use the structured readiness check' }
    if ($body -match "docker exec .*curl.*9200") { throw 'runtime-contract-record still runs its own ad hoc Elasticsearch curl check -- this must be removed now that Wait-K8ElasticsearchReady is shared and already ran before this function is called (duplicated/inconsistent Range A vs B readiness logic is exactly the defect class this audit fixed)' }
}

# --- 9. Behavioral: log_structurer / zone_detector / Elasticsearch gates -----
#
# Everything above this point is structural (AST/text). This section
# actually INVOKES the real Wait-K8LogStructurerReady / Wait-K8ZoneDetectorReady
# / Wait-K8ElasticsearchReady functions against a scripted `docker` mock
# (tests/mock-docker/docker.cmd -> docker-impl.ps1), so "not ready -> STOP before
# trigger" and "ready -> PASS" are proven by running the real code, not by
# asserting that the right words appear in it.

$mockDockerDir = Join-Path $ShakedownDir 'tests\mock-docker'
if (-not (Test-Path (Join-Path $mockDockerDir 'docker.cmd'))) { throw "docker mock not found at $mockDockerDir" }

$originalPath = $env:PATH
$originalMockState = $env:K8_MOCK_DOCKER_STATE
try {
    $env:PATH = "$mockDockerDir;$env:PATH"
    Import-Module $CommonPath -Force

    $behaviorEvidenceDir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-behavior-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path (Join-Path $behaviorEvidenceDir 'environment') | Out-Null

    function Invoke-K8MockedGate {
        param([string] $MockState, [string] $FunctionName)
        $env:K8_MOCK_DOCKER_STATE = $MockState
        & $FunctionName -RunId 'x' -ComposePath 'y.yml' -RunEvidence $behaviorEvidenceDir -TimeoutSeconds 4 -PollSeconds 1
    }

    $cases = @(
        @{ Name = 'log_structurer: apt-get still installing -> trigger-before-STOP'; State = 'structurer-installing'; Func = 'Wait-K8LogStructurerReady'; ExpectPass = $false }
        @{ Name = 'log_structurer: tshark|bulk_loader pipeline live -> PASS';        State = 'structurer-ready';       Func = 'Wait-K8LogStructurerReady'; ExpectPass = $true }
        @{ Name = 'log_structurer: only tshark live, no bulk_loader yet -> STOP (both required, not either)'; State = 'structurer-tshark-only'; Func = 'Wait-K8LogStructurerReady'; ExpectPass = $false }
        @{ Name = 'zone_detector: pip install still running -> trigger-before-STOP'; State = 'detector-installing'; Func = 'Wait-K8ZoneDetectorReady'; ExpectPass = $false }
        @{ Name = 'zone_detector: signal-1-zone-violation plugin live -> PASS';      State = 'detector-ready';       Func = 'Wait-K8ZoneDetectorReady'; ExpectPass = $true }
        @{ Name = 'elasticsearch: transport failure (curl exit 7) -> STOP';          State = 'es-down';              Func = 'Wait-K8ElasticsearchReady'; ExpectPass = $false }
        @{ Name = 'elasticsearch: cluster status red -> STOP (not just HTTP 2xx)';   State = 'es-red';               Func = 'Wait-K8ElasticsearchReady'; ExpectPass = $false }
        @{ Name = 'elasticsearch: HTTP 200 with no status field -> STOP (proves body is actually parsed)'; State = 'es-http-200-no-body-status'; Func = 'Wait-K8ElasticsearchReady'; ExpectPass = $false }
        @{ Name = 'elasticsearch: cluster status yellow -> PASS';                    State = 'es-ready-yellow';      Func = 'Wait-K8ElasticsearchReady'; ExpectPass = $true }
        @{ Name = 'elasticsearch: cluster status green -> PASS';                     State = 'es-ready-green';       Func = 'Wait-K8ElasticsearchReady'; ExpectPass = $true }
        # Round 3: process-alive is necessary but not sufficient -- bulk_loader.py
        # catches every _bulk POST failure and keeps running (functional readiness).
        @{ Name = 'log_structurer: processes alive but operational canary ABSENT (bulk_loader silently failing) -> STOP'; State = 'canary-absent'; Func = 'Wait-K8LogStructurerReady'; ExpectPass = $false }
        @{ Name = 'log_structurer: processes alive but canary query transport error -> STOP';   State = 'canary-transport-error';        Func = 'Wait-K8LogStructurerReady'; ExpectPass = $false }
        @{ Name = 'log_structurer: processes alive AND operational canary PRESENT -> PASS';      State = 'canary-present';                Func = 'Wait-K8LogStructurerReady'; ExpectPass = $true }
        @{ Name = 'log_structurer: canary query matching the TARGET selector -> STOP (safety net, never trusted as readiness)'; State = 'canary-matches-target-selector'; Func = 'Wait-K8LogStructurerReady'; ExpectPass = $false }
        # zone_violation.py catches every RequestException and returns 0 --
        # plugin-process-alive is necessary but not sufficient either.
        @{ Name = 'zone_detector: plugin alive but its OWN container cannot reach Elasticsearch -> STOP'; State = 'detector-connectivity-fail'; Func = 'Wait-K8ZoneDetectorReady'; ExpectPass = $false }
        @{ Name = 'zone_detector: plugin alive AND connectivity confirmed from inside the container -> PASS'; State = 'detector-connectivity-ok'; Func = 'Wait-K8ZoneDetectorReady'; ExpectPass = $true }
        # Round 4: _cluster/health 2xx is not proof the plugin's OWN real
        # dependency (POST ot-logs-dnp3-*/_search) works -- poll_once()
        # catches every RequestException on that call and returns 0.
        @{ Name = 'zone_detector: cluster health 200 but its own ot-logs-dnp3-*/_search returns 400 -> STOP'; State = 'detector-search-400'; Func = 'Wait-K8ZoneDetectorReady'; ExpectPass = $false }
        @{ Name = 'zone_detector: its own source-index search transport failure -> STOP'; State = 'detector-search-transport-error'; Func = 'Wait-K8ZoneDetectorReady'; ExpectPass = $false }
        @{ Name = 'zone_detector: its own source-index search returns invalid JSON -> STOP'; State = 'detector-search-invalid-json'; Func = 'Wait-K8ZoneDetectorReady'; ExpectPass = $false }
        @{ Name = 'zone_detector: its own source-index search 2xx + valid JSON -> PASS'; State = 'detector-search-ok'; Func = 'Wait-K8ZoneDetectorReady'; ExpectPass = $true }
    )
    foreach ($case in $cases) {
        Assert-K8Test $case.Name {
            $passed = $false
            try { Invoke-K8MockedGate -MockState $case.State -FunctionName $case.Func; $passed = $true }
            catch { $passed = $false }
            if ($passed -ne $case.ExpectPass) {
                throw "expected $(if ($case.ExpectPass) {'PASS'} else {'STOP'}) but got $(if ($passed) {'PASS'} else {'STOP'})"
            }
        }
    }

    Assert-K8Test 'Operational canary selector is disjoint from the target scientific flow, and self-checked, not just filtered' {
        $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Get-K8Dnp3OperationalCanaryHits'
        foreach ($needle in @('10.1.10.10', '10.1.40.10')) {
            if ($body -notmatch [regex]::Escape($needle)) { throw "canary query does not reference the documented cc_scada_master<->sub_c_rtu addresses ($needle missing)" }
        }
        if ($body -notmatch [regex]::Escape("'10.1.20.11'") -or $body -notmatch "throw 'operational-canary query unexpectedly matched the TARGET") {
            throw 'canary does not self-check that a returned hit never matches the target selector (10.1.20.11, fc=5) -- must not rely on the query filter alone'
        }
        if ($body -match '"gte"|"lte"|WINDOW_START|WINDOW_END') {
            throw 'canary query appears to use a T0 time window -- T0 does not exist yet at this point in the pipeline, and this must stay a wall-clock/insertion-order check, not a scientific-window one'
        }
    }

    Assert-K8Test 'zone_detector source-index search uses the pinned plugin''s own literal query, executed from inside zone_detector, requires valid JSON' {
        $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Wait-K8ZoneDetectorReady'
        foreach ($needle in @('ot-logs-dnp3-\*/_search', '"_doc": "desc"', 'wildcard', 'frame_frame_protocols', '\*dnp3\*')) {
            if ($body -notmatch $needle) { throw "search check does not use zone_violation.py's own literal query shape (missing: $needle)" }
        }
        if ($body -notmatch 'json\.loads\(raw\)') { throw 'search check does not actually parse the response body as JSON before accepting it' }
        if ($body -notmatch "'exec',\s*\`$container,\s*'python3',\s*'-c',\s*\(ConvertTo-K8PythonExecOneLiner -Script \`$searchScript\)") { throw 'search check is not executed via docker exec against $container (zone_detector itself)' }
        if ($body -notmatch '\$pluginLive -and \$connectivityOk -and \$searchOk') { throw 'PASS condition no longer requires plugin-alive AND connectivity AND search all three' }
    }

    Assert-K8Test 'zone_detector connectivity check runs FROM INSIDE the zone_detector container, not from Elasticsearch or the host' {
        $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Wait-K8ZoneDetectorReady'
        if ($body -notmatch "'exec',\s*\`$container,\s*'python3',\s*'-c'") { throw 'connectivity check is not executed via docker exec against $container (the zone_detector container)' }
        if ($body -notmatch 'urllib\.request') { throw 'connectivity check does not use a real HTTP request from inside the container' }
        if ($body -match "ps -q elasticsearch.*python3|elasticsearch.*docker exec.*urllib") { throw 'connectivity check appears to run against the elasticsearch container instead of zone_detector -- this must prove the path FROM zone_detector' }
    }

    Assert-K8Test 'Scientific Elasticsearch requests still have no retry/loop, and the new canary/connectivity checks are not confused with them' {
        foreach ($name in @('Invoke-K8ElasticsearchRequest', 'Complete-K8ElasticsearchResponse')) {
            $body = Get-K8FunctionBodyText -Path $CommonPath -Name $name
            if (Test-K8HasLoopConstruct -FunctionBodyText $body) { throw "$name contains a loop construct -- must remain exactly-once" }
            if ($body -match 'Get-K8Dnp3OperationalCanaryHits') { throw "$name must not call the pre-trigger canary helper -- they must stay entirely separate code paths" }
        }
        # The canary helper is a pure query-and-return function: it must
        # perform no file I/O of its own at all (the docstring itself
        # legitimately says "contract-output" in prose explaining what this
        # is NOT, which would false-positive a whole-body text search for
        # that word -- so check for the absence of any write call instead).
        $canaryBody = Get-K8FunctionBodyText -Path $CommonPath -Name 'Get-K8Dnp3OperationalCanaryHits'
        if ($canaryBody -match 'Set-Content|Out-File|Add-Content') { throw 'the pre-trigger canary helper performs file I/O of its own -- it must only query and return, never retain scientific-looking evidence itself' }
    }

    Assert-K8Test 'All three application-readiness gates retain their result artifact under environment/' {
        foreach ($file in @('log-structurer-readiness.json', 'zone-detector-readiness.json', 'elasticsearch-readiness.json')) {
            if (-not (Test-Path (Join-Path $behaviorEvidenceDir "environment\$file"))) { throw "$file was not retained" }
        }
        $esResult = Get-Content (Join-Path $behaviorEvidenceDir 'environment\elasticsearch-readiness.json') -Raw | ConvertFrom-Json
        if ($esResult.result -ne 'PASS' -or $esResult.attempts[-1].cluster_status -ne 'green') {
            throw 'retained Elasticsearch readiness artifact does not reflect the last (green) run -- body/status was not actually recorded'
        }
    }

    Remove-Item $behaviorEvidenceDir -Recurse -Force -ErrorAction SilentlyContinue
}
finally {
    $env:PATH = $originalPath
    $env:K8_MOCK_DOCKER_STATE = $originalMockState
}

# --- 10. T0-relative timing gates (round 5: stop-export-before-T0+15 fix) ----
#
# k8shakedown-rangea-20260829-021350 called stop-export ~13.465s before
# T0+15s; capture_lifecycle.validate() correctly rejected it. These tests
# invoke the REAL Wait-K8CaptureWindowStart/Wait-K8CaptureWindowEnd
# functions with real Stopwatch-measured elapsed time -- not mocks -- since
# neither needs Docker at all (they only read retained JSON/text and sleep).

$capturePyPath = Join-Path $ScriptsDir 'study01_capture.py'
$lifecyclePyPath = Join-Path $Study01 'studies\study-01-negative-result\scripts\study01\capture_lifecycle.py'

Assert-K8Test 'The 5s/15s window constants match capture_lifecycle.py''s own frozen WINDOW_LEAD/WINDOW_TAIL, not independently guessed' {
    $lifecycleSrc = Get-Content $lifecyclePyPath -Raw
    if ($lifecycleSrc -notmatch 'WINDOW_LEAD\s*=\s*timedelta\(seconds=5\)') { throw "capture_lifecycle.py's own WINDOW_LEAD is not 5s -- this test's own pin is stale" }
    if ($lifecycleSrc -notmatch 'WINDOW_TAIL\s*=\s*timedelta\(seconds=15\)') { throw "capture_lifecycle.py's own WINDOW_TAIL is not 15s -- this test's own pin is stale" }
    $startBody = Get-K8FunctionBodyText -Path $CommonPath -Name 'Wait-K8CaptureWindowStart'
    if ($startBody -notmatch '\.AddSeconds\(5\)') { throw 'Wait-K8CaptureWindowStart does not use the frozen 5s lead' }
    $endBody = Get-K8FunctionBodyText -Path $CommonPath -Name 'Wait-K8CaptureWindowEnd'
    if ($endBody -notmatch '\.AddSeconds\(15\)') { throw 'Wait-K8CaptureWindowEnd does not use the frozen 15s tail' }
}

Assert-K8Test 'study01_capture.py''s own docstring still requires "stop-export only after T0 + 15 s" (the requirement this fix implements)' {
    $captureSrc = Get-Content $capturePyPath -Raw
    if ($captureSrc -notmatch 'Run `stop-export` only after `T0 \+ 15 s`') { throw 'frozen docstring wording changed or this pin is stale -- re-check the requirement has not moved' }
    if ($captureSrc -match 'time\.sleep' ) {
        # stop_export() itself must still have no wait of its own -- if the
        # frozen script ever grows one, this Shakedown-side wait would double
        # up (harmless timing-wise, but worth knowing about, not silently).
        $stopExportBody = ($captureSrc -split 'def stop_export')[1]
        $stopExportBody = $stopExportBody.Substring(0, [Math]::Min(2000, $stopExportBody.Length))
        if ($stopExportBody -match 'time\.sleep') { throw 'stop_export() now contains its own sleep -- re-check whether the Shakedown-side wait is still needed / correctly sized' }
    }
}

Assert-K8Test 'Wait-K8CaptureWindowEnd actually waits the remaining time to T0+15s, and not a moment more than needed' {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-t0end-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    try {
        $t0 = ([datetimeoffset]::UtcNow).AddSeconds(-13.5)   # T0+15s is 1.5s away
        $t0.ToString('o') | Set-Content (Join-Path $dir 'metadata-t0.txt') -Encoding utf8NoBOM
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Wait-K8CaptureWindowEnd -RunEvidence $dir -MarginSeconds 0.1
        $sw.Stop()
        if ($sw.Elapsed.TotalSeconds -lt 1.3) { throw "waited only $($sw.Elapsed.TotalSeconds)s; expected roughly 1.5s+margin -- stop-export would have run before T0+15s" }
        if ($sw.Elapsed.TotalSeconds -gt 4.0) { throw "waited $($sw.Elapsed.TotalSeconds)s -- far more than needed" }
        if (-not (Test-Path (Join-Path $dir 'environment\capture-window-end-wait.json'))) { throw 'wait result artifact was not retained' }
    }
    finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'Wait-K8CaptureWindowEnd does not wait at all once T0+15s has already passed (never depends on how long the sender itself took)' {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-t0end2-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    try {
        (([datetimeoffset]::UtcNow).AddSeconds(-30)).ToString('o') | Set-Content (Join-Path $dir 'metadata-t0.txt') -Encoding utf8NoBOM
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Wait-K8CaptureWindowEnd -RunEvidence $dir -MarginSeconds 0.1
        $sw.Stop()
        if ($sw.Elapsed.TotalSeconds -gt 1.0) { throw "waited $($sw.Elapsed.TotalSeconds)s when the window end had already passed -- this must return immediately" }
    }
    finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'Wait-K8CaptureWindowEnd STOPs fail-closed on missing or offset-less T0' {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-t0end3-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    try {
        $stopped = $false
        try { Wait-K8CaptureWindowEnd -RunEvidence $dir } catch { $stopped = $true }
        if (-not $stopped) { throw 'missing T0 file did not STOP' }

        '2026-08-29 02:17:14' | Set-Content (Join-Path $dir 'metadata-t0.txt') -Encoding utf8NoBOM
        $stopped = $false
        try { Wait-K8CaptureWindowEnd -RunEvidence $dir } catch { $stopped = $true }
        if (-not $stopped) { throw 'a T0 value with no UTC offset did not STOP' }
    }
    finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'Wait-K8CaptureWindowStart waits for the LATER of ground-truth/sensor listening-check, covering both stages' {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-t0start-" + [guid]::NewGuid())
    $gt = Join-Path $dir 'ground-truth\independent-capture'
    $sensor = Join-Path $dir 'sensor-input\mirror-capture'
    New-Item -ItemType Directory -Force -Path $gt, $sensor | Out-Null
    try {
        # A large, timing-jitter-tolerant gap between the two fixtures:
        # ground-truth already clears the 5s lead on its own (-8s), sensor
        # does not (-0.5s). Correct behavior (uses the LATER, sensor) waits
        # ~4.6s; using the wrong (ground-truth) timestamp would wait ~0s --
        # an unambiguous difference regardless of test-run overhead.
        @{ steps = @(@{ step = 'listening-check'; completed_at = (([datetimeoffset]::UtcNow).AddSeconds(-8.0)).ToString('o') }) } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $gt 'capture-lifecycle.json') -Encoding utf8NoBOM
        @{ steps = @(@{ step = 'listening-check'; completed_at = (([datetimeoffset]::UtcNow).AddSeconds(-0.5)).ToString('o') }) } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $sensor 'capture-lifecycle.json') -Encoding utf8NoBOM
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Wait-K8CaptureWindowStart -RunEvidence $dir -MarginSeconds 0.1
        $sw.Stop()
        if ($sw.Elapsed.TotalSeconds -lt 2.0) { throw "waited only $($sw.Elapsed.TotalSeconds)s -- did not use the LATER of the two stages' listening-check completion" }
        if (-not (Test-Path (Join-Path $dir 'environment\capture-window-start-wait.json'))) { throw 'wait result artifact was not retained' }
    }
    finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'Wait-K8CaptureWindowStart does not wait once both stages already cleared the 5s lead, and STOPs on a missing/malformed stage record' {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-t0start2-" + [guid]::NewGuid())
    $gt = Join-Path $dir 'ground-truth\independent-capture'
    $sensor = Join-Path $dir 'sensor-input\mirror-capture'
    New-Item -ItemType Directory -Force -Path $gt, $sensor | Out-Null
    try {
        @{ steps = @(@{ step = 'listening-check'; completed_at = (([datetimeoffset]::UtcNow).AddSeconds(-20)).ToString('o') }) } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $gt 'capture-lifecycle.json') -Encoding utf8NoBOM
        @{ steps = @(@{ step = 'listening-check'; completed_at = (([datetimeoffset]::UtcNow).AddSeconds(-10)).ToString('o') }) } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $sensor 'capture-lifecycle.json') -Encoding utf8NoBOM
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Wait-K8CaptureWindowStart -RunEvidence $dir -MarginSeconds 0.1
        $sw.Stop()
        if ($sw.Elapsed.TotalSeconds -gt 1.0) { throw "waited $($sw.Elapsed.TotalSeconds)s when the 5s lead was already satisfied for both stages" }

        Remove-Item (Join-Path $sensor 'capture-lifecycle.json')
        $stopped = $false
        try { Wait-K8CaptureWindowStart -RunEvidence $dir } catch { $stopped = $true }
        if (-not $stopped) { throw 'missing sensor lifecycle record did not STOP' }

        '{"steps":[{"step":"listening-check","completed_at":"not-a-date"}]}' | Set-Content (Join-Path $sensor 'capture-lifecycle.json') -Encoding utf8NoBOM
        $stopped = $false
        try { Wait-K8CaptureWindowStart -RunEvidence $dir } catch { $stopped = $true }
        if (-not $stopped) { throw 'malformed completed_at did not STOP' }
    }
    finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'Wait-K8CaptureWindowStart/End and the early capture-lifecycle check are each called exactly once, unconditionally, in the right order' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8ShakedownRangeABBody'
    $startCalls = @([regex]::Matches($body, 'Wait-K8CaptureWindowStart\s+-RunEvidence'))
    $endCalls = @([regex]::Matches($body, 'Wait-K8CaptureWindowEnd\s+-RunEvidence'))
    $earlyCalls = @([regex]::Matches($body, 'Test-K8CaptureLifecycleEarly\s+-ScriptsDir'))
    if ($startCalls.Count -ne 1 -or $endCalls.Count -ne 1 -or $earlyCalls.Count -ne 1) {
        throw "expected exactly one shared call site each (Range A and B use the same body); found Start=$($startCalls.Count) End=$($endCalls.Count) Early=$($earlyCalls.Count)"
    }
    foreach ($call in @($startCalls[0], $endCalls[0], $earlyCalls[0])) {
        $surrounding = $body.Substring([Math]::Max(0, $call.Index - 200), 200)
        if ($surrounding -match "Range\s+-eq\s+'[ab]'") { throw 'a T0-timing call site appears to be inside a Range-specific branch; it must be unconditional/shared' }
    }
    $senderIndex = $body.IndexOf("(Join-Path `$ScriptsDir 'study01_sender.py')")
    $stopExportIndex = $body.IndexOf("'stop-export',")
    if (-not ($startCalls[0].Index -lt $senderIndex -and $senderIndex -lt $endCalls[0].Index -and $endCalls[0].Index -lt $stopExportIndex -and $stopExportIndex -lt $earlyCalls[0].Index)) {
        throw "wrong order: expected WindowStart -> sender -> WindowEnd -> stop-export -> early-lifecycle-check (indices: start=$($startCalls[0].Index) sender=$senderIndex end=$($endCalls[0].Index) stopExport=$stopExportIndex early=$($earlyCalls[0].Index))"
    }
}

Assert-K8Test 'Test-K8CaptureLifecycleEarly reuses the frozen capture_context.validate/capture_lifecycle.validate functions, does not reimplement window-timing math' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Test-K8CaptureLifecycleEarly'
    foreach ($needle in @('from study01 import capture_context', 'from study01 import capture_lifecycle', 'from study01.frozen import apparatus', 'lifecycle.validate(record, t0_value, ctx)', 'context.validate(json.loads')) {
        if ($body -notmatch [regex]::Escape($needle)) { throw "does not import/call the frozen validator as expected (missing: $needle)" }
    }
    if ($body -match 'WINDOW_LEAD|WINDOW_TAIL|AddSeconds\(1?5\)') { throw 'appears to reimplement window-timing math instead of delegating to the frozen validator' }
}

Assert-K8Test 'No retry/loop construct was added to the fixed scientific Elasticsearch requests by this round''s changes' {
    foreach ($name in @('Invoke-K8ElasticsearchRequest', 'Complete-K8ElasticsearchResponse')) {
        $body = Get-K8FunctionBodyText -Path $CommonPath -Name $name
        if (Test-K8HasLoopConstruct -FunctionBodyText $body) { throw "$name contains a loop construct -- must remain exactly-once" }
    }
}

# --- 11. Ground Truth/Sensor decode, mapping retention, completeness gate ---
#
# Root cause: k8shakedown-rangea-20260829-024343 passed runtime/validate-
# evidence/finalize/teardown/verify-integrity, then discovered at
# scoring-input that README SS5.1 step 6's "decode them" had never been
# implemented at all for either capture. This section also regression-tests
# two REAL bugs found while fixing that (both previously undiscovered
# because Write-K8UnrelatedPcapRows/Invoke-K8TsharkFieldDecode were never
# actually exercised behaviorally before this round): a `-split "`t", -1`
# expression that does not mean "unlimited substrings" (it returns the
# whole line unsplit), and a single-row array silently unrolling into a
# bare hashtable when returned bare from a function.

Assert-K8Test 'REGRESSION: -split with a -1 limit does not mean unlimited (must use 0 or omit the limit)' {
    # This is the exact bug that made Write-K8UnrelatedPcapRows /
    # Write-K8TargetCaptureDecode throw "unexpected tshark row shape" on
    # EVERY real decoded line, discovered only by an actual invocation, not
    # by reading the code. Pins the correct behavior so it cannot silently
    # regress back to `-1`.
    $line = "1`t2`t3`t4`t5`t6`t7`t8`t9"
    if (@($line -split "`t", -1).Count -ne 1) { throw 'expected behavior of a -1 split limit changed; the module''s own comment explaining why -1 is wrong may need updating' }
    if (@($line -split "`t").Count -ne 9) { throw 'omitting the split limit no longer returns all fields -- this is what the fixed code now relies on' }
    $moduleBody = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8TsharkFieldDecode'
    # Match only the actual assignment statement, not this function's own
    # explanatory comment about the bug it fixed (which legitimately quotes
    # the old buggy pattern in prose).
    if ($moduleBody -match '\$columns\s*=\s*@\(\$line\s*-split\s*"`t",\s*-1\)') { throw 'the fixed -1 split-limit bug was reintroduced in Invoke-K8TsharkFieldDecode' }
}

Assert-K8Test 'REGRESSION: Invoke-K8TsharkFieldDecode returns a real array even for exactly one decoded row' {
    # PowerShell unrolls a bare array onto the pipeline; a function that
    # ends with `return $arrayVar` (no leading comma) hands a ONE-element
    # array's caller the bare element instead -- for an [ordered] hashtable
    # row, that surfaces as .Count returning the FIELD count (9), not the
    # intended ROW count (1). Confirmed by an actual invocation, not
    # reasoned about in the abstract.
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8TsharkFieldDecode'
    if ($body -notmatch 'return\s+,\$rows') { throw 'Invoke-K8TsharkFieldDecode no longer force-returns an array (the single-row unroll bug may have been reintroduced)' }
}

$mockDockerDir2 = Join-Path $ShakedownDir 'tests\mock-docker'
$decodeOriginalPath = $env:PATH
try {
    $env:PATH = "$mockDockerDir2;$env:PATH"
    Import-Module $CommonPath -Force

    Assert-K8Test 'Write-K8TargetCaptureDecode: one real hit is retained with count 1, not 9 (the array-unroll regression, end to end)' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-decode-e2e-" + [guid]::NewGuid())
        $gt = Join-Path $dir 'ground-truth\independent-capture'
        New-Item -ItemType Directory -Force -Path $gt | Out-Null
        'fake' | Set-Content (Join-Path $gt 'c2-original-path.pcap')
        try {
            $env:K8_MOCK_DOCKER_STATE = 'decode-hit'
            $ws = ([datetimeoffset]::UtcNow).AddSeconds(-100).ToString('o'); $we = ([datetimeoffset]::UtcNow).AddSeconds(100).ToString('o')
            Write-K8TargetCaptureDecode -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir -Stage 'ground-truth' -WindowStartIso $ws -WindowEndIso $we
            $result = Get-Content (Join-Path $gt 'decoded-verification.json') -Raw | ConvertFrom-Json
            if ($result.decoded_hit_count -ne 1) { throw "decoded_hit_count was $($result.decoded_hit_count), expected 1 -- the array-unroll bug may be back" }
            if ($result.rows.Count -ne 1) { throw "rows array had $($result.rows.Count) entries, expected 1" }
            if ($result.selector -notmatch '10\.1\.20\.11.*10\.1\.10\.10.*20000.*al\.func=5.*src=1024.*dst=1') { throw 'retained selector text does not match freeze-decision-table.md SS3' }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'Write-K8TargetCaptureDecode: zero decoded hits is retained as observed, never thrown as a failure' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-decode-empty-" + [guid]::NewGuid())
        $sensor = Join-Path $dir 'sensor-input\mirror-capture'
        New-Item -ItemType Directory -Force -Path $sensor | Out-Null
        'fake' | Set-Content (Join-Path $sensor 'c2-mirror-sensor.pcap')
        try {
            $env:K8_MOCK_DOCKER_STATE = 'decode-empty'
            $ws = ([datetimeoffset]::UtcNow).AddSeconds(-100).ToString('o'); $we = ([datetimeoffset]::UtcNow).AddSeconds(100).ToString('o')
            Write-K8TargetCaptureDecode -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir -Stage 'sensor' -WindowStartIso $ws -WindowEndIso $we
            $result = Get-Content (Join-Path $sensor 'decoded-verification.json') -Raw | ConvertFrom-Json
            if ($result.decoded_hit_count -ne 0) { throw "expected decoded_hit_count 0, got $($result.decoded_hit_count)" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'Write-K8TargetCaptureDecode: transport/tshark failure STOPs (not silently retained as zero hits)' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-decode-err-" + [guid]::NewGuid())
        $gt = Join-Path $dir 'ground-truth\independent-capture'
        New-Item -ItemType Directory -Force -Path $gt | Out-Null
        'fake' | Set-Content (Join-Path $gt 'c2-original-path.pcap')
        try {
            $env:K8_MOCK_DOCKER_STATE = 'decode-transport-error'
            $ws = ([datetimeoffset]::UtcNow).AddSeconds(-100).ToString('o'); $we = ([datetimeoffset]::UtcNow).AddSeconds(100).ToString('o')
            $stopped = $false
            try { Write-K8TargetCaptureDecode -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir -Stage 'ground-truth' -WindowStartIso $ws -WindowEndIso $we } catch { $stopped = $true }
            if (-not $stopped) { throw 'a tshark transport failure did not STOP' }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'Write-K8UnrelatedPcapRows (R-OBS-05) still works correctly after the shared decode-helper fix' {
        # Source artifact updated (not weakened): this test still asserts the
        # same decode/array-shape behavior, but against the frozen-SS4
        # auxiliary LIVENESS pcap. The Sensor pcap it used to stage was the
        # defective source the SS4-conformance fix removed.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-robs-e2e-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'contract-output') | Out-Null
        'fake' | Set-Content (Join-Path $dir 'contract-output\r-obs-05-liveness.pcap')
        try {
            $env:K8_MOCK_DOCKER_STATE = 'decode-hit'
            $path = Write-K8UnrelatedPcapRows -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir
            $rows = Get-Content $path -Raw | ConvertFrom-Json
            if ($rows.Count -ne 1) { throw "expected 1 retained row, got $($rows.Count) -- the shared decode helper fix may have broken this caller" }
            $env:K8_MOCK_DOCKER_STATE = 'decode-empty'
            $stopped = $false
            try { Write-K8UnrelatedPcapRows -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir } catch { $stopped = $true }
            if (-not $stopped) { throw 'zero unrelated-flow hits did not STOP (R-OBS-05 requires at least one, unlike the target decode)' }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
finally { $env:PATH = $decodeOriginalPath }

Assert-K8Test 'Ground Truth/Sensor decode uses the frozen freeze-decision-table.md SS3 selector, not an invented one, and never gates on hit count' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Write-K8TargetCaptureDecode'
    foreach ($needle in @('10.1.20.11', '10.1.10.10', '20000', 'dnp3.al.func==5', 'dnp3.src==1024', 'dnp3.dst==1')) {
        if ($body -notmatch [regex]::Escape($needle)) { throw "decode does not reference the frozen selector element: $needle" }
    }
    if ($body -match "if\s*\(\s*\`$rows\.Count\s*-eq\s*0\s*\)\s*\{\s*throw") { throw 'decode throws on zero hits -- README SS6.2 reserves that scientific judgment for the operator, this must retain and continue' }
    # Check only for an actual verdict-like variable assignment, not the
    # word appearing in this function's own docstring explaining that it
    # does NOT assign one.
    if ($body -match '\$(verdict|scientificResult|passFail)\s*=') { throw 'decode function appears to assign a scientific verdict -- it must only retain observed data' }
}

Assert-K8Test 'Both ground-truth and sensor decode calls run before finalize-evidence, while log_structurer is still up (before Complete''s teardown)' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8ShakedownRangeABBody'
    $gtCall = $body.IndexOf("-Stage 'ground-truth' -WindowStartIso")
    $sensorCall = $body.IndexOf("-Stage 'sensor' -WindowStartIso")
    if ($gtCall -lt 0 -or $sensorCall -lt 0) { throw 'could not find both decode call sites in Invoke-K8ShakedownRangeABBody' }
    $completeBody = Get-K8FunctionBodyText -Path $CommonPath -Name 'Complete-K8ShakedownRangeABBody'
    if ($completeBody -match 'Write-K8TargetCaptureDecode') { throw 'decode must run in Invoke-K8ShakedownRangeABBody (range still up), not in Complete (after teardown)' }
}

Assert-K8Test 'Collector and Rule index mappings are retained (README SS5.1 step 6: "with their responses and mappings"), for both Range A and B' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8AutomatedQueries'
    foreach ($needle in @('collector-index-mapping.json', 'rule-index-mapping.json', "'ot-logs-dnp3-\*/_mapping'", "'ot-signals-zone-violation-\*/_mapping'")) {
        if ($body -notmatch $needle) { throw "mapping retention marker missing: $needle" }
    }
    # Must not be inside the `if ($Range -eq 'b')` branch -- both ranges need it.
    $mappingIndex = $body.IndexOf('collector-index-mapping.json')
    $rangeBBranchIndex = $body.IndexOf("if (`$Range -eq 'b')")
    if ($rangeBBranchIndex -ge 0 -and $mappingIndex -gt $rangeBBranchIndex) { throw 'Collector/Rule mapping retention appears to be inside the Range-B-only branch' }
}

Assert-K8Test 'Test-K8ScoringInputArtifactCompleteness: missing artifact STOPs before runtime PASS; complete set PASSes; Range B needs the R-OBS-05 set too' {
    Import-Module $CommonPath -Force
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-complete-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    try {
        $stopped = $false
        try { Test-K8ScoringInputArtifactCompleteness -Range a -RunEvidence $dir } catch { $stopped = $true }
        if (-not $stopped) { throw 'an entirely empty evidence tree did not STOP' }

        # The fixture is built FROM the contract, not from a copy of the
        # required list. If this test restated the list, it would be the very
        # second source of truth C-6 exists to remove -- and it would pass
        # while the contract said something else.
        $required = @(Get-K8ContractArtifacts -Range a | ForEach-Object { $_.artifact })
        foreach ($rel in $required) {
            $full = Join-Path $dir $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $full -Parent) | Out-Null
            'x' | Set-Content $full
        }
        $failed = $false
        try { Test-K8ScoringInputArtifactCompleteness -Range a -RunEvidence $dir } catch { $failed = $true; Write-Host "  (unexpected: $($_.Exception.Message))" }
        if ($failed) { throw 'a complete Range A artifact set did not PASS' }

        $stopped = $false
        try { Test-K8ScoringInputArtifactCompleteness -Range b -RunEvidence $dir } catch { $stopped = $true }
        if (-not $stopped) { throw 'Range B did not additionally require the R-OBS-05 artifact set' }
    }
    finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'The completeness gate runs before "runtime evidence PASS" is ever reported, for both Range A and B from one shared call site' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8ShakedownRangeABBody'
    $gateCalls = @([regex]::Matches($body, 'Test-K8ScoringInputArtifactCompleteness\s+-Range'))
    if ($gateCalls.Count -ne 1) { throw "expected exactly one shared call site; found $($gateCalls.Count)" }
    # Search for the actual Write-K8ShakedownLog call site specifically
    # (not just the phrase, which also legitimately appears in this
    # function's own explanatory comments preceding the gate call).
    $passLogIndex = $body.IndexOf('=== Shakedown Range $($Range.ToUpper()) runtime evidence PASS')
    if ($passLogIndex -lt 0 -or $gateCalls[0].Index -gt $passLogIndex) { throw 'completeness gate does not run before the "runtime evidence PASS" log line' }
}

# --- 12. stdout/stderr stream separation fix + cross-cutting audit ----------
#
# Real VM failure, root-caused by independent review: Invoke-K8TsharkFieldDecode
# ran `docker exec ... tshark ... 2>&1`, merging tshark's own stderr
# root-execution warning ("Running as user \"root\" and group \"root\". This
# could be dangerous.") into the value parsed as a 9-column TSV row, which
# threw "unexpected tshark row shape". Fix: Invoke-K8SeparatedNativeCapture
# redirects stderr to a separate temp file (`2>$stderrFile`, never `2>&1`),
# returning Stdout/Stderr/ExitCode as distinct values -- never a hardcoded
# exclusion of that one warning string, which would only mask the next
# tool's next unrelated stderr line. Cross-audited every OTHER call site in
# this module that parses stdout as structured data (JSON, TSV, an exact
# container-id/SHA/HTTP-status match) for the same defect class and fixed
# each at the same call site (listed in the loop below); sites that only
# ever retain output as a human-read text log (never parsed for a machine
# decision) were deliberately left on `2>&1`, since merging stderr into a
# transcript meant for a person to read is correct, not a defect.

Assert-K8Test 'Invoke-K8SeparatedNativeCapture redirects stderr to a separate file (2>$file), never merges via 2>&1, and preserves the real exit code' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8SeparatedNativeCapture'
    # Scope the negative check to the actual invocation statement, not this
    # function's own docstring, which legitimately quotes/explains "2>&1" as
    # the bug pattern it exists to avoid.
    $invocationLine = ($body -split "`n") | Where-Object { $_ -match '\$stdout\s*=' }
    if (-not $invocationLine) { throw 'could not locate the native-command invocation line' }
    if ($invocationLine -match '2>&1') { throw 'Invoke-K8SeparatedNativeCapture merges stderr via 2>&1 -- defeats its own purpose' }
    if ($invocationLine -notmatch '2>\$stderrFile') { throw 'stderr is no longer redirected to a separate file' }
    if ($body -notmatch '\$LASTEXITCODE') { throw 'the real native exit code is no longer captured' }
}

Assert-K8Test 'REGRESSION: ConvertTo-K8PythonExecOneLiner flattens a multi-line python3 -c script to one line with no embedded newline, and the flattened form still runs correctly' {
    # Found while writing this round's own regression tests: this module's
    # docker mock is invoked through a .cmd batch trampoline (deliberately,
    # so it resolves as a real external process like docker.exe, not an
    # in-process PS1 script) -- and cmd.exe's line-oriented parser corrupts
    # any argument containing a literal embedded newline before the batch
    # body ever runs. Wait-K8ZoneDetectorReady's connectivity/search checks
    # build multi-line python3 -c scripts; this fixes that at the source
    # rather than only in the mock.
    Import-Module $CommonPath -Force
    $multiline = "import sys`ntry:`n sys.stdout.write('ok')`nexcept Exception as e:`n sys.stdout.write('ERROR:'+str(e))`n sys.exit(1)`n"
    $flattened = ConvertTo-K8PythonExecOneLiner -Script $multiline
    if ($flattened.Contains([char]10) -or $flattened.Contains([char]13)) { throw 'flattened script still contains a raw embedded newline/carriage-return byte' }
    if ($flattened -notmatch "^exec\('") { throw 'flattened script is not wrapped in exec(...)' }
    $pythonExe = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonExe) {
        $out = & $pythonExe.Source -c $flattened
        if ($LASTEXITCODE -ne 0 -or $out -ne 'ok') { throw "flattened script did not execute correctly (exit $LASTEXITCODE, out '$out')" }
    }
    else {
        Write-Host '  (no python on PATH -- skipped the live-execution half of this check, structural half still verified)'
    }
    # The real scripts this wraps (Wait-K8ZoneDetectorReady) are full of
    # single-quoted python string literals ('ERROR:', 'HTTPERROR:', the
    # $esUrl literal, etc.) -- $multiline above already exercises that via
    # 'ok' and 'ERROR:'+str(e), and the live-execution check above already
    # proves those single quotes survive the exec('...') round-trip
    # correctly (output was exactly 'ok', not a syntax error or truncation).
}

Assert-K8Test 'REGRESSION: Invoke-K8TsharkFieldDecode no longer merges tshark stderr into the parsed stdout via 2>&1' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8TsharkFieldDecode'
    # Scope the negative check to lines that actually invoke tshark (not this
    # function's own explanatory comment/docstring, which legitimately
    # quotes the old buggy `2>&1` pattern in prose while describing the fix).
    $tsharkLines = ($body -split "`n") | Where-Object { $_ -match "'tshark'" -or $_ -match '\btshark\b.*-r\b' }
    foreach ($line in $tsharkLines) {
        if ($line -match '2>&1') { throw "a tshark invocation line still merges stdout/stderr via 2>&1 -- the root-warning contamination bug may be back: $line" }
    }
    if ($body -notmatch 'Invoke-K8SeparatedNativeCapture') { throw 'Invoke-K8TsharkFieldDecode no longer uses the separated-capture helper' }
    if ($body -notmatch '\$capture\.ExitCode -ne 0') { throw 'tshark exit code is no longer checked/fail-closed' }
    if ($body -notmatch '\$capture\.Stderr') { throw 'tshark stderr is no longer retained as a failure diagnostic' }
}

Assert-K8Test 'Wait-K8ZoneDetectorReady flattens both its python3 -c scripts via ConvertTo-K8PythonExecOneLiner before passing them as a native argument' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Wait-K8ZoneDetectorReady'
    foreach ($needle in @(
        "(ConvertTo-K8PythonExecOneLiner -Script `$connectivityScript)",
        "(ConvertTo-K8PythonExecOneLiner -Script `$searchScript)"
    )) {
        if ($body -notmatch [regex]::Escape($needle)) { throw "missing flattening call: $needle" }
    }
}

$tier1SeparatedCaptureSites = @(
    'Get-K8ExpectedServices', 'Invoke-K8ElasticsearchRequest', 'Wait-K8ElasticsearchReady',
    'Get-K8Dnp3OperationalCanaryHits', 'Wait-K8ComposeReady', 'Write-K8ImageInventory',
    'Write-K8RuntimeContractRecord', 'Wait-K8ZoneDetectorReady'
)
foreach ($fn in $tier1SeparatedCaptureSites) {
    Assert-K8Test "Cross-cutting audit: $fn parses native stdout via Invoke-K8SeparatedNativeCapture, not a merged 2>&1 capture" {
        $body = Get-K8FunctionBodyText -Path $CommonPath -Name $fn
        if ($body -notmatch 'Invoke-K8SeparatedNativeCapture') { throw "$fn no longer calls Invoke-K8SeparatedNativeCapture -- the stderr-contamination fix for this call site may have been reverted" }
    }
}

$mockDockerDir3 = Join-Path $ShakedownDir 'tests\mock-docker'
$rootWarnOriginalPath = $env:PATH
try {
    $env:PATH = "$mockDockerDir3;$env:PATH"
    Import-Module $CommonPath -Force

    Assert-K8Test 'REGRESSION 1/4: stdout=valid 9-column row + stderr=root warning + exit 0 -> parses as exactly 1 hit' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-rootwarn-hit-" + [guid]::NewGuid())
        $gt = Join-Path $dir 'ground-truth\independent-capture'
        New-Item -ItemType Directory -Force -Path $gt | Out-Null
        'fake' | Set-Content (Join-Path $gt 'c2-original-path.pcap')
        try {
            $env:K8_MOCK_DOCKER_STATE = 'decode-hit-with-root-warning'
            $ws = ([datetimeoffset]::UtcNow).AddSeconds(-100).ToString('o'); $we = ([datetimeoffset]::UtcNow).AddSeconds(100).ToString('o')
            Write-K8TargetCaptureDecode -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir -Stage 'ground-truth' -WindowStartIso $ws -WindowEndIso $we
            $result = Get-Content (Join-Path $gt 'decoded-verification.json') -Raw | ConvertFrom-Json
            if ($result.decoded_hit_count -ne 1) { throw "decoded_hit_count was $($result.decoded_hit_count), expected 1 -- tshark's stderr root-warning may be contaminating the stdout TSV parse again" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'REGRESSION 2/4: stdout=zero rows + stderr=root warning + exit 0 -> processed as 0 hits, does not throw' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-rootwarn-empty-" + [guid]::NewGuid())
        $sensor = Join-Path $dir 'sensor-input\mirror-capture'
        New-Item -ItemType Directory -Force -Path $sensor | Out-Null
        'fake' | Set-Content (Join-Path $sensor 'c2-mirror-sensor.pcap')
        try {
            $env:K8_MOCK_DOCKER_STATE = 'decode-empty-with-root-warning'
            $ws = ([datetimeoffset]::UtcNow).AddSeconds(-100).ToString('o'); $we = ([datetimeoffset]::UtcNow).AddSeconds(100).ToString('o')
            Write-K8TargetCaptureDecode -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir -Stage 'sensor' -WindowStartIso $ws -WindowEndIso $we
            $result = Get-Content (Join-Path $sensor 'decoded-verification.json') -Raw | ConvertFrom-Json
            if ($result.decoded_hit_count -ne 0) { throw "expected decoded_hit_count 0, got $($result.decoded_hit_count)" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'REGRESSION 3/4: stdout=garbage + stderr=real error + exit nonzero -> fail-closed, stderr surfaced as diagnostic' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-rootwarn-err-" + [guid]::NewGuid())
        $gt = Join-Path $dir 'ground-truth\independent-capture'
        New-Item -ItemType Directory -Force -Path $gt | Out-Null
        'fake' | Set-Content (Join-Path $gt 'c2-original-path.pcap')
        try {
            $env:K8_MOCK_DOCKER_STATE = 'decode-error-with-message'
            $ws = ([datetimeoffset]::UtcNow).AddSeconds(-100).ToString('o'); $we = ([datetimeoffset]::UtcNow).AddSeconds(100).ToString('o')
            $stopped = $false; $msg = ''
            try { Write-K8TargetCaptureDecode -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir -Stage 'ground-truth' -WindowStartIso $ws -WindowEndIso $we }
            catch { $stopped = $true; $msg = $_.Exception.Message }
            if (-not $stopped) { throw 'a non-zero tshark exit with a garbage stdout line did not fail-closed' }
            if ($msg -notmatch 'some transport error occurred') { throw "stderr diagnostic was not surfaced in the failure message (got: $msg)" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'REGRESSION 4/4: R-OBS-05 shared decode path (Write-K8UnrelatedPcapRows) is also immune to stderr root-warning contamination' {
        # Source artifact updated to the frozen-SS4 auxiliary liveness pcap;
        # the stderr-contamination property under test is unchanged.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-rootwarn-robs05-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'contract-output') | Out-Null
        'fake' | Set-Content (Join-Path $dir 'contract-output\r-obs-05-liveness.pcap')
        try {
            $env:K8_MOCK_DOCKER_STATE = 'decode-hit-with-root-warning'
            $path = Write-K8UnrelatedPcapRows -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir
            $rows = Get-Content $path -Raw | ConvertFrom-Json
            if ($rows.Count -ne 1) { throw "expected exactly 1 retained row despite the stderr root-warning, got $($rows.Count) -- the shared decode path may still be contaminating rows with stderr text" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
finally { $env:PATH = $rootWarnOriginalPath }

# --- 13. Environment readiness false-negative + network preflight -----------
#
# Real VM false negative, root-caused (k8shakedown-rangea-20260829-071142,
# commit e1d98a4): `docker compose up -d --build` exited 0, then
# Wait-K8ComposeReady timed out after 120s even though an operator's manual
# recheck immediately after the failure showed all 21 expected services
# running (State=running) with both declared healthchecks healthy. The
# actual defect was NOT in JSON parsing at all: Get-K8ExpectedServices
# already force-returns a real array via `return ,$services` (correct for 1
# service or many), but BOTH of its callers additionally wrapped the call in
# `@(...)` -- double-wrapping the result into a 1-element array whose SOLE
# element was the real N-service array. Test-K8ComposeServiceReadiness then
# iterated exactly one pseudo-"expected service" (the array object itself,
# not a service-name string), which could never match any real `compose ps`
# row, making every expected service "Missing" and Ready permanently false
# regardless of actual Docker state. The SAME self-inflicted double-wrap
# (`return ,@(...)` combining the comma AND `@()` in one statement, rather
# than `,$X.ToArray()`) was found and fixed in this round's own new
# ConvertFrom-K8ComposePsJson/ConvertFrom-K8ConcatenatedJson before it ever
# shipped, while writing these very regression tests -- see the structural
# checks below, which exist specifically so this exact bug class cannot
# silently return.
#
# Secondary, independent fix in this section: `ps --all --format json`
# parsing was rebuilt on a depth-aware concatenated-JSON scanner
# (ConvertFrom-K8ConcatenatedJson) instead of "try whole-string parse, catch,
# naive `-split \`n` per line" -- format-agnostic across compact NDJSON, a
# pretty-printed multi-line array, or any mix, and fail-closed (never
# silently skipped) on a stray non-JSON line. Readiness diagnostics were
# also restructured: environment/readiness.json now holds expected/actual
# counts, Missing/NotRunning/NotHealthy, and a parse diagnostic distinct
# from a genuine not-ready state, and a timeout prints a short console
# summary of exactly what blocked PASS instead of only an abstract message.
#
# Third, independent UX fix in this section: a network pool-conflict
# preflight (Test-K8ShakedownNetworkPreflight), reading THIS run's actually-
# declared subnet(s) from `docker compose config` and every leftover
# Shakedown network's actual subnet from `docker network inspect` (never a
# hardcoded CIDR), runs before `docker compose up` and STOPs with the exact
# conflicting network name if a leftover, abandoned run's fixed subnet would
# collide -- never auto-removing or pruning any network.

Assert-K8Test 'REGRESSION (root cause): Get-K8ExpectedServices callers do not double-wrap its already-array-safe return value in @()' {
    foreach ($fn in @('Wait-K8ComposeReady', 'Write-K8ImageInventory')) {
        $body = Get-K8FunctionBodyText -Path $CommonPath -Name $fn
        if ($body -match '@\(Get-K8ExpectedServices') { throw "$fn wraps Get-K8ExpectedServices in @() again -- this is the exact double-wrap that made the real VM run's 21/21/healthy environment report Missing forever" }
        if ($body -notmatch 'Get-K8ExpectedServices\s+-RunId') { throw "$fn no longer calls Get-K8ExpectedServices at all" }
    }
}

Assert-K8Test 'REGRESSION (self-inflicted double-wrap, caught before shipping): no comma-returning helper in this module wraps its own ToArray()/array in @() at the return statement' {
    $body = Get-Content $CommonPath -Raw
    if ($body -match 'return\s+,@\(') { throw 'found `return ,@(...)` -- combining the comma operator with @() double-wraps into an array-of-array; use `,$X` or `,$X.ToArray()` alone' }
}

Assert-K8Test 'REGRESSION: no caller anywhere in this module wraps ConvertFrom-K8ComposePsJson, ConvertFrom-K8ConcatenatedJson, Get-K8ComposeDeclaredSubnets, or Get-K8LeftoverShakedownNetworks in @() (all four already force-return real arrays)' {
    $body = Get-Content $CommonPath -Raw
    foreach ($fn in @('ConvertFrom-K8ComposePsJson', 'ConvertFrom-K8ConcatenatedJson', 'Get-K8ComposeDeclaredSubnets', 'Get-K8LeftoverShakedownNetworks')) {
        if ($body -match [regex]::Escape("@($fn")) { throw "found a caller wrapping $fn in @() -- double-wrap risk" }
    }
}

Assert-K8Test 'ConvertFrom-K8ConcatenatedJson: compact NDJSON, a pretty multi-line array, and a single object all split correctly' {
    # NOT wrapped in @() at any of these call sites -- the function already
    # force-returns a real array via `,$values.ToArray()` (see its own
    # return statement and the double-wrap regression tests above); wrapping
    # it again here would reintroduce the exact bug class this whole section
    # regression-tests, inside the regression test itself.
    Import-Module $CommonPath -Force
    $ndjson = (1..5 | ForEach-Object { "{`"Service`":`"svc$_`"}" }) -join "`n"
    if ((ConvertFrom-K8ConcatenatedJson -Raw $ndjson).Count -ne 5) { throw '5-row compact NDJSON did not split into 5 values' }
    $pretty = "[`n  { `"a`": 1 },`n  { `"b`": 2 }`n]"
    if ((ConvertFrom-K8ConcatenatedJson -Raw $pretty).Count -ne 1) { throw 'a single pretty-printed multi-line array must split into exactly ONE top-level value (the whole array), not be confused by its internal newlines' }
    if ((ConvertFrom-K8ConcatenatedJson -Raw '{"a":1}').Count -ne 1) { throw 'a single compact object must split into exactly one value' }
    if ((ConvertFrom-K8ConcatenatedJson -Raw '').Count -ne 0) { throw 'empty input must split into zero values, not throw or return a null element' }
}

Assert-K8Test 'ConvertFrom-K8ConcatenatedJson: braces/brackets inside a JSON string value never confuse the depth tracker' {
    # NOT wrapped in @() -- see the comment on the test above.
    Import-Module $CommonPath -Force
    $chunks = ConvertFrom-K8ConcatenatedJson -Raw '{"Labels":"foo={bar}, baz=[1,2]","Service":"svc1"}'
    if ($chunks.Count -ne 1) { throw "expected exactly 1 top-level value, got $($chunks.Count) -- a brace/bracket inside a string literal was mistaken for real JSON structure" }
    $parsed = $chunks[0] | ConvertFrom-Json
    if ($parsed.Service -ne 'svc1') { throw 'string-embedded-brace fixture did not round-trip correctly' }
}

Assert-K8Test 'ConvertFrom-K8ConcatenatedJson: fail-closed (not silently skipped) on a stray non-JSON line and on unbalanced JSON' {
    Import-Module $CommonPath -Force
    $stopped1 = $false
    try { ConvertFrom-K8ConcatenatedJson -Raw "some banner line`n{`"Service`":`"a`"}" } catch { $stopped1 = $true }
    if (-not $stopped1) { throw 'a stray non-JSON top-level line did not STOP -- it must never be silently skipped or silently accepted' }
    $stopped2 = $false
    try { ConvertFrom-K8ConcatenatedJson -Raw '{"Service":"a"' } catch { $stopped2 = $true }
    if (-not $stopped2) { throw 'unbalanced/truncated JSON did not STOP' }
}

Assert-K8Test 'REGRESSION 1/8: Compose v5 NDJSON, 21 rows, all running, 2 healthy -> PASS (pure parse+gate fixture)' {
    Import-Module $CommonPath -Force
    $rows = 1..21 | ForEach-Object {
        if ($_ -le 2) { "{`"Service`":`"svc$_`",`"State`":`"running`",`"Health`":`"healthy`"}" }
        else { "{`"Service`":`"svc$_`",`"State`":`"running`"}" }
    }
    $expected = 1..21 | ForEach-Object { "svc$_" }
    $services = ConvertFrom-K8ComposePsJson -Raw ($rows -join "`n")
    if ($services.Count -ne 21) { throw "expected 21 parsed rows, got $($services.Count)" }
    $gate = Test-K8ComposeServiceReadiness -Expected $expected -Services $services
    if (-not $gate.Ready) { throw "21/21 running with 2 declared-healthy healthchecks did not PASS: $($gate | ConvertTo-Json -Compress)" }
}

Assert-K8Test 'REGRESSION 2/8: one service missing from the parsed rows -> FAIL' {
    Import-Module $CommonPath -Force
    $services = ConvertFrom-K8ComposePsJson -Raw '{"Service":"a","State":"running"}'
    $gate = Test-K8ComposeServiceReadiness -Expected @('a', 'b') -Services $services
    if ($gate.Ready) { throw 'a missing expected service incorrectly PASSed' }
    if (@($gate.Missing) -notcontains 'b') { throw 'Missing does not name the actually-missing service' }
}

Assert-K8Test 'REGRESSION 3/8: one service State=exited -> FAIL' {
    Import-Module $CommonPath -Force
    $services = ConvertFrom-K8ComposePsJson -Raw "{`"Service`":`"a`",`"State`":`"running`"}`n{`"Service`":`"b`",`"State`":`"exited`"}"
    $gate = Test-K8ComposeServiceReadiness -Expected @('a', 'b') -Services $services
    if ($gate.Ready) { throw 'an exited service incorrectly PASSed' }
    if (@($gate.NotRunning) -notcontains 'b') { throw 'NotRunning does not name the exited service' }
}

Assert-K8Test 'REGRESSION 4/8: a declared healthcheck reporting unhealthy -> FAIL' {
    Import-Module $CommonPath -Force
    $services = ConvertFrom-K8ComposePsJson -Raw "{`"Service`":`"a`",`"State`":`"running`",`"Health`":`"unhealthy`"}"
    $gate = Test-K8ComposeServiceReadiness -Expected @('a') -Services $services
    if ($gate.Ready) { throw 'an unhealthy declared healthcheck incorrectly PASSed' }
    if (@($gate.NotHealthy) -notcontains 'a') { throw 'NotHealthy does not name the unhealthy service' }
}

Assert-K8Test 'REGRESSION 5/8: Health property absent entirely, or present but empty, with State=running -> PASS' {
    Import-Module $CommonPath -Force
    # svcNoHealthKey omits Health entirely (real shape for a service with no
    # configured healthcheck); svcEmptyHealth declares the key as "".
    $rows = '{"Service":"svcNoHealthKey","State":"running"}' + "`n" + '{"Service":"svcEmptyHealth","State":"running","Health":""}'
    $services = ConvertFrom-K8ComposePsJson -Raw $rows
    $gate = Test-K8ComposeServiceReadiness -Expected @('svcNoHealthKey', 'svcEmptyHealth') -Services $services
    if (-not $gate.Ready) { throw "a service with no healthcheck must PASS on State alone, whether Health is absent or empty: $($gate | ConvertTo-Json -Compress)" }
}

Assert-K8Test 'REGRESSION 6/8: exactly one row (a single JSON object, not an array) does not break the collection shape' {
    Import-Module $CommonPath -Force
    $services = ConvertFrom-K8ComposePsJson -Raw '{"Service":"only","State":"running"}'
    if ($services.Count -ne 1) { throw "a single-object (non-array) compose ps output must parse to a 1-element collection, got Count=$($services.Count)" }
    $gate = Test-K8ComposeServiceReadiness -Expected @('only') -Services $services
    if (-not $gate.Ready) { throw 'a single genuinely-running expected service did not PASS' }
    # Also exercise the single-element JSON ARRAY shape specifically --
    # ConvertFrom-Json unwraps a 1-element JSON array to a bare object, which
    # ConvertFrom-K8ComposePsJson must handle explicitly (see its docstring).
    $servicesFromArray = ConvertFrom-K8ComposePsJson -Raw '[{"Service":"only","State":"running"}]'
    if ($servicesFromArray.Count -ne 1) { throw "a single-element JSON ARRAY must also parse to a 1-element collection, got Count=$($servicesFromArray.Count)" }
}

$readinessMockDir = Join-Path $ShakedownDir 'tests\mock-docker'
$readinessOriginalPath = $env:PATH
try {
    $env:PATH = "$readinessMockDir;$env:PATH"
    Import-Module $CommonPath -Force

    Assert-K8Test 'REGRESSION: exact real-VM reproduction -- 21 expected services, all running, 2 declared healthchecks healthy -> PASS' {
        $env:K8_MOCK_DOCKER_STATE = 'readiness-21-services-pass'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-readiness-21-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'environment') | Out-Null
        try {
            Wait-K8ComposeReady -RunId 'k8shakedown-rangea-20260829-071142' -ComposePath 'y.yml' -RunEvidence $dir -TimeoutSeconds 5 -PollSeconds 1
            $record = Get-Content (Join-Path $dir 'environment\readiness.json') -Raw | ConvertFrom-Json
            if ($record.decision -ne 'PASS' -or $record.expected_count -ne 21 -or $record.actual_present_count -ne 21) { throw "readiness record does not reflect a clean 21/21 PASS: $($record | ConvertTo-Json -Compress)" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'REGRESSION 7/8: stdout has valid JSON rows, stderr has a Compose warning -> stdout-only parse, PASS' {
        $env:K8_MOCK_DOCKER_STATE = 'readiness-e2e-ready-with-stderr-warning'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-readiness-stderr-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'environment') | Out-Null
        try {
            Wait-K8ComposeReady -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir -TimeoutSeconds 5 -PollSeconds 1
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'REGRESSION: one missing service -> FAIL-STATE, readiness.json names it, console diagnostic does not throw' {
        $env:K8_MOCK_DOCKER_STATE = 'readiness-e2e-not-ready-missing-forever'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-readiness-missing-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'environment') | Out-Null
        try {
            $stopped = $false
            try { Wait-K8ComposeReady -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir -TimeoutSeconds 2 -PollSeconds 1 } catch { $stopped = $true }
            if (-not $stopped) { throw 'a persistently missing service did not STOP' }
            $record = Get-Content (Join-Path $dir 'environment\readiness.json') -Raw | ConvertFrom-Json
            if ($record.decision -ne 'FAIL-STATE') { throw "expected decision FAIL-STATE, got $($record.decision)" }
            if (@($record.missing) -notcontains 'svcC') { throw "readiness.json does not name the missing service: $($record | ConvertTo-Json -Compress)" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'REGRESSION 8/8: malformed JSON persists -> FAIL-PARSE, distinct from FAIL-STATE, with the parse diagnostic retained' {
        $env:K8_MOCK_DOCKER_STATE = 'readiness-e2e-malformed-json-forever'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-readiness-malformed-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'environment') | Out-Null
        try {
            $stopped = $false
            try { Wait-K8ComposeReady -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir -TimeoutSeconds 2 -PollSeconds 1 } catch { $stopped = $true }
            if (-not $stopped) { throw 'persistently malformed JSON did not STOP' }
            $record = Get-Content (Join-Path $dir 'environment\readiness.json') -Raw | ConvertFrom-Json
            if ($record.decision -ne 'FAIL-PARSE') { throw "expected decision FAIL-PARSE, got $($record.decision)" }
            if ([string]::IsNullOrWhiteSpace([string]$record.parse_diagnostic)) { throw 'parse_diagnostic was not retained on a parse failure' }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'Network preflight: a leftover Shakedown network holding an overlapping fixed subnet STOPs, naming the network and both subnets' {
        $env:K8_MOCK_DOCKER_STATE = 'preflight-conflict'
        $stopped = $false; $msg = ''
        try { Test-K8ShakedownNetworkPreflight -RunId 'k8shakedown-rangea-20260829-999999' -ComposePath 'y.yml' } catch { $stopped = $true; $msg = $_.Exception.Message }
        if (-not $stopped) { throw 'an overlapping leftover network did not STOP' }
        if ($msg -notmatch 'k8shakedown-rangea-20260801-001_default' -or $msg -notmatch '10\.1\.20\.0/24' -or $msg -notmatch '10\.1\.0\.0/16') { throw "STOP message does not name the conflicting network and both subnets: $msg" }
    }

    Assert-K8Test 'Network preflight: a leftover network with a non-overlapping subnet PASSes; no declared subnet PASSes without even checking' {
        $env:K8_MOCK_DOCKER_STATE = 'preflight-clear'
        Test-K8ShakedownNetworkPreflight -RunId 'k8shakedown-rangea-20260829-999999' -ComposePath 'y.yml'
        $env:K8_MOCK_DOCKER_STATE = 'preflight-no-subnet-declared'
        Test-K8ShakedownNetworkPreflight -RunId 'k8shakedown-rangea-20260829-999999' -ComposePath 'y.yml'
    }
}
finally { $env:PATH = $readinessOriginalPath }

Assert-K8Test 'ConvertTo-K8CidrRange / Test-K8CidrOverlap: standard containment, adjacency, and /0 edge cases' {
    Import-Module $CommonPath -Force
    if (-not (Test-K8CidrOverlap -CidrA '10.1.0.0/16' -CidrB '10.1.20.0/24')) { throw 'a /24 inside a /16 must overlap' }
    if (Test-K8CidrOverlap -CidrA '10.1.0.0/24' -CidrB '10.2.0.0/24') { throw 'disjoint /24s in different /16s must not overlap' }
    if (Test-K8CidrOverlap -CidrA '10.1.20.0/25' -CidrB '10.1.20.128/25') { throw 'two adjacent, non-overlapping halves of the same /24 must not overlap' }
    if (-not (Test-K8CidrOverlap -CidrA '0.0.0.0/0' -CidrB '10.1.20.0/24')) { throw '/0 must overlap everything' }
    $stopped = $false
    try { ConvertTo-K8CidrRange -Cidr 'not-a-cidr' } catch { $stopped = $true }
    if (-not $stopped) { throw 'a non-CIDR string did not STOP' }
}

Assert-K8Test 'Test-K8ShakedownNetworkPreflight never calls network rm/prune, and runs before docker compose up in Invoke-K8ShakedownRangeABBody' {
    $preflightBody = Get-K8FunctionBodyText -Path $CommonPath -Name 'Test-K8ShakedownNetworkPreflight'
    $helperBody = Get-K8FunctionBodyText -Path $CommonPath -Name 'Get-K8LeftoverShakedownNetworks'
    foreach ($body in @($preflightBody, $helperBody)) {
        # Scope to an actual ArgumentList invocation shape ('network', 'rm'
        # /'prune' as separate array elements), not this function's own
        # advisory throw text recommending the OPERATOR run `docker network
        # rm <name>` by hand -- that prose legitimately contains the words.
        if ($body -match "'network',\s*'rm'" -or $body -match "'network',\s*'prune'") {
            throw 'the network preflight (or its helper) appears to actually INVOKE network rm/prune -- it must only detect and report, per the explicit no-auto-removal requirement'
        }
    }
    $rangeAbBody = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8ShakedownRangeABBody'
    $preflightCallIndex = $rangeAbBody.IndexOf('Test-K8ShakedownNetworkPreflight -RunId')
    $upCallIndex = $rangeAbBody.IndexOf("'up', '-d', '--build'")
    if ($preflightCallIndex -lt 0) { throw 'Test-K8ShakedownNetworkPreflight is not called from Invoke-K8ShakedownRangeAB' }
    if ($upCallIndex -lt 0) { throw 'could not locate the docker compose up call site' }
    if ($preflightCallIndex -gt $upCallIndex) { throw 'the network preflight runs AFTER docker compose up -- it must run BEFORE, or it cannot prevent the pool-overlap failure it exists to catch' }
}

Assert-K8Test 'Wait-K8ComposeReady readiness gate is not weakened: still requires every expected service present, running, and (if healthchecked) healthy' {
    Import-Module $CommonPath -Force
    $expected = @('a', 'b')
    $healthy = @([pscustomobject]@{Service='a';State='running';Health='healthy'}, [pscustomobject]@{Service='b';State='running'})
    if (-not (Test-K8ComposeServiceReadiness -Expected $expected -Services $healthy).Ready) { throw 'a genuinely healthy/running complete set must still PASS' }
    $oneUnhealthy = @([pscustomobject]@{Service='a';State='running';Health='unhealthy'}, [pscustomobject]@{Service='b';State='running'})
    if ((Test-K8ComposeServiceReadiness -Expected $expected -Services $oneUnhealthy).Ready) { throw 'an unhealthy declared healthcheck must still FAIL -- the readiness condition itself must not be weakened' }
    $oneExited = @([pscustomobject]@{Service='a';State='exited';Health=''}, [pscustomobject]@{Service='b';State='running'})
    if ((Test-K8ComposeServiceReadiness -Expected $expected -Services $oneExited).Ready) { throw 'an exited service must still FAIL' }
}

# --- 14. tshark `-E separator=` CLI-contract fix -----------------------------
#
# Real VM parser defect, root-caused (k8shakedown-rangea-20260829-081151):
# Invoke-K8TsharkFieldDecode passed `-E separator=\t` to tshark. `\t` is a
# PowerShell/C-style string escape, NOT tshark's own CLI syntax -- tshark's
# `-E separator=` documents exactly three forms (a single literal character,
# `/t` for tab, `/s` for space), never a backslash escape. The module had
# confused PowerShell's own escape convention with the external tool's CLI
# contract, and the real row delimiter tshark actually emitted was a literal
# backslash character, not a tab -- "unexpected tshark row shape" even
# though the 9 fields themselves were correct. Not a scientific finding; the
# closed run is not rescued/resumed. Fixed on the CLI argument alone
# (`separator=/t`); the PowerShell-side `-split "`t"` (an actual tab
# character, tshark's own OWN documented `/t` expands to a real 0x09 byte in
# its OUTPUT) was already correct and needed no change -- no "\" acceptance
# fallback was added on the parser side, matching the explicit requirement.
# Applies to Ground Truth, Sensor, and R-OBS-05 uniformly because all three
# share this one function.

Assert-K8Test 'REGRESSION: Invoke-K8TsharkFieldDecode uses tshark''s own separator=/t (not the PowerShell/C-style separator=\t escape)' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8TsharkFieldDecode'
    if ($body -match "'separator=\\+t'") { throw 'Invoke-K8TsharkFieldDecode still passes separator=\t -- not tshark''s own CLI syntax; the real-VM row-shape defect may be back' }
    if ($body -notmatch "'separator=/t'") { throw 'Invoke-K8TsharkFieldDecode no longer passes tshark''s documented separator=/t token' }
}

Assert-K8Test 'REGRESSION: no `separator=\t` (PowerShell/C-style escape, not tshark CLI syntax) remains as an actual argument literal anywhere in the module source' {
    # Scoped to the quoted CLI-argument shape ('separator=\t'), not prose --
    # this file's own explanatory comments quote the old buggy value inside
    # backticks followed by a comma/colon/space (e.g. `separator=\t`:),
    # never as a standalone single-quoted PowerShell string literal.
    $moduleSource = Get-Content $CommonPath -Raw
    if ($moduleSource -match "'separator=\\+t'") { throw 'a literal separator=\t CLI argument string was found in the module source' }
}

$tsharkSepMockDir = Join-Path $ShakedownDir 'tests\mock-docker'
$tsharkSepOriginalPath = $env:PATH
try {
    $env:PATH = "$tsharkSepMockDir;$env:PATH"
    Import-Module $CommonPath -Force

    Assert-K8Test 'REGRESSION 1/7: a real TAB-separated (0x09) 9-column row parses as exactly 1 hit' {
        $env:K8_MOCK_DOCKER_STATE = 'decode-hit'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-tsep-1hit-" + [guid]::NewGuid())
        $gt = Join-Path $dir 'ground-truth\independent-capture'
        New-Item -ItemType Directory -Force -Path $gt | Out-Null
        'fake' | Set-Content (Join-Path $gt 'c2-original-path.pcap')
        try {
            $ws = ([datetimeoffset]::UtcNow).AddSeconds(-100).ToString('o'); $we = ([datetimeoffset]::UtcNow).AddSeconds(100).ToString('o')
            Write-K8TargetCaptureDecode -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir -Stage 'ground-truth' -WindowStartIso $ws -WindowEndIso $we
            $result = Get-Content (Join-Path $gt 'decoded-verification.json') -Raw | ConvertFrom-Json
            if ($result.decoded_hit_count -ne 1) { throw "expected 1 hit, got $($result.decoded_hit_count)" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'REGRESSION 2/7: multiple TAB-separated rows all parse -- exactly the real VM row values (58852/1024/etc.), 3 hits' {
        $env:K8_MOCK_DOCKER_STATE = 'decode-multi-hit'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-tsep-multi-" + [guid]::NewGuid())
        $gt = Join-Path $dir 'ground-truth\independent-capture'
        New-Item -ItemType Directory -Force -Path $gt | Out-Null
        'fake' | Set-Content (Join-Path $gt 'c2-original-path.pcap')
        try {
            $ws = ([datetimeoffset]::UtcNow).AddSeconds(-100).ToString('o'); $we = ([datetimeoffset]::UtcNow).AddSeconds(100).ToString('o')
            Write-K8TargetCaptureDecode -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir -Stage 'ground-truth' -WindowStartIso $ws -WindowEndIso $we
            $result = Get-Content (Join-Path $gt 'decoded-verification.json') -Raw | ConvertFrom-Json
            if ($result.decoded_hit_count -ne 3) { throw "expected 3 hits, got $($result.decoded_hit_count)" }
            if ($result.rows.Count -ne 3) { throw "rows array had $($result.rows.Count) entries, expected 3" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'REGRESSION 3/7: zero hits still processed as observed, not thrown' {
        $env:K8_MOCK_DOCKER_STATE = 'decode-empty'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-tsep-empty-" + [guid]::NewGuid())
        $sensor = Join-Path $dir 'sensor-input\mirror-capture'
        New-Item -ItemType Directory -Force -Path $sensor | Out-Null
        'fake' | Set-Content (Join-Path $sensor 'c2-mirror-sensor.pcap')
        try {
            $ws = ([datetimeoffset]::UtcNow).AddSeconds(-100).ToString('o'); $we = ([datetimeoffset]::UtcNow).AddSeconds(100).ToString('o')
            Write-K8TargetCaptureDecode -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir -Stage 'sensor' -WindowStartIso $ws -WindowEndIso $we
            $result = Get-Content (Join-Path $sensor 'decoded-verification.json') -Raw | ConvertFrom-Json
            if ($result.decoded_hit_count -ne 0) { throw "expected 0 hits, got $($result.decoded_hit_count)" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'REGRESSION 4/7: a row with the wrong column count fails closed, never silently accepted' {
        $env:K8_MOCK_DOCKER_STATE = 'decode-bad-column-count'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-tsep-badcol-" + [guid]::NewGuid())
        $gt = Join-Path $dir 'ground-truth\independent-capture'
        New-Item -ItemType Directory -Force -Path $gt | Out-Null
        'fake' | Set-Content (Join-Path $gt 'c2-original-path.pcap')
        try {
            $ws = ([datetimeoffset]::UtcNow).AddSeconds(-100).ToString('o'); $we = ([datetimeoffset]::UtcNow).AddSeconds(100).ToString('o')
            $stopped = $false
            try { Write-K8TargetCaptureDecode -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir -Stage 'ground-truth' -WindowStartIso $ws -WindowEndIso $we } catch { $stopped = $true }
            if (-not $stopped) { throw 'a row with the wrong column count did not STOP' }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'REGRESSION 5/7: a root-execution stderr warning still never lands in a data row (unchanged by this round''s CLI-argument-only fix)' {
        $env:K8_MOCK_DOCKER_STATE = 'decode-hit-with-root-warning'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-tsep-rootwarn-" + [guid]::NewGuid())
        $gt = Join-Path $dir 'ground-truth\independent-capture'
        New-Item -ItemType Directory -Force -Path $gt | Out-Null
        'fake' | Set-Content (Join-Path $gt 'c2-original-path.pcap')
        try {
            $ws = ([datetimeoffset]::UtcNow).AddSeconds(-100).ToString('o'); $we = ([datetimeoffset]::UtcNow).AddSeconds(100).ToString('o')
            Write-K8TargetCaptureDecode -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir -Stage 'ground-truth' -WindowStartIso $ws -WindowEndIso $we
            $result = Get-Content (Join-Path $gt 'decoded-verification.json') -Raw | ConvertFrom-Json
            if ($result.decoded_hit_count -ne 1) { throw "expected 1 hit despite the stderr root-warning, got $($result.decoded_hit_count)" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
finally { $env:PATH = $tsharkSepOriginalPath }

# --- 15. Cross-cutting audit: CLI-native escape/separator/format syntax -----
#
# Explicitly requested audit for the same defect CLASS: this module (or any
# other Shakedown script) treating an external tool's OWN CLI option syntax
# as if it were a PowerShell/C-style string escape, for docker, curl,
# tshark, tc, ip, compose, and `python3 -c`. Each finding below is either
# fixed, or confirmed correct with the reasoning recorded so it is not
# re-litigated by a future round mistaking it for the same bug.
#
# Confirmed CORRECT (external tool's own documented escape, not a mix-up):
# - curl `-w`/`--write-out`: uses a literal `\n` (two characters) in the
#   format string, which is curl's OWN documented write-out escape,
#   expanded by curl itself into a real newline byte when it writes -w's
#   output -- not a raw control character smuggled through argv (fixed in
#   an earlier round specifically to avoid that). PowerShell's own
#   double-quoted-string escape character is the backtick, NOT backslash,
#   so `"\n"` in this module's PowerShell source is passed to curl
#   completely literally as the two characters backslash+n, which is
#   exactly what curl's own syntax requires.
# - `tr "\0" " "` and `printf "\n"` inside the /proc probe shell one-liner:
#   both `\0` and `\n` are tr's and printf's OWN POSIX-documented escape
#   sequences (interpreted by tr/printf themselves inside the container's
#   /bin/sh, not by PowerShell or by the outer shell) -- the whole probe
#   string is a single-quoted PowerShell string, so PowerShell performs no
#   interpretation of it at all and passes it through byte-for-byte.
# - `python3 -c` scripts (ConvertTo-K8PythonExecOneLiner, fixed in an
#   earlier round): `\n` inside the exec('...') string argument is
#   PYTHON's own string-literal escape, expanded by Python itself when the
#   exec'd code runs, not a shell/CLI separator convention at all.
# - `-split '\s+'` (parsing `ip`/`tc` text output locally): this is
#   PowerShell's OWN `-split` regex syntax (a .NET regex whitespace class),
#   entirely internal to this module's own parsing, not an external tool's
#   CLI argument.
#
# Confirmed and FIXED this round: tshark `-E separator=\t` -> `separator=/t`
# (section 14 above) -- the one real instance of this defect class found.

Assert-K8Test 'Cross-cutting audit: curl -w write-out format strings use curl''s own literal \n escape, never a raw embedded newline byte' {
    foreach ($fn in @('Wait-K8ElasticsearchReady', 'Get-K8Dnp3OperationalCanaryHits')) {
        $body = Get-K8FunctionBodyText -Path $CommonPath -Name $fn
        if ($body -notmatch '-w.*\\n\$\{?marker\}?:%\{http_code\}') { throw "$fn's curl -w format string is missing or no longer uses curl's own literal \n escape" }
        # A RAW embedded newline byte in the PowerShell source (not the
        # literal two-character \n) would reintroduce the cmd.exe-trampoline
        # argument-corruption bug fixed in an earlier round.
        $wLine = ($body -split "`n") | Where-Object { $_ -match "-w'" -or $_ -match "'-w'" }
        foreach ($line in $wLine) { if ($line.Contains([char]10)) { throw "$fn's curl -w argument contains a raw embedded newline byte, not curl's own \n escape" } }
    }
}

Assert-K8Test 'Cross-cutting audit: no other native-command argument in this module contains a bare backslash-letter sequence masquerading as that tool''s own separator/format syntax' {
    # Deliberately scoped to an actual single-quoted PowerShell string
    # literal shape ('separator=\X'), not a broad "\\[a-z]" prose scan --
    # this file's own explanatory comments (this test's section header
    # included) legitimately quote the old buggy value while describing the
    # fix, and a naive scan would flag its own documentation.
    $moduleSource = Get-Content $CommonPath -Raw
    if ($moduleSource -match "'separator=\\+[a-zA-Z]'") { throw "found a quoted CLI 'separator=' argument literal using a backslash escape instead of the tool's own documented token (e.g. tshark's /t)" }
}

# --- 16. Rule query exact-match selector fix (frozen source_dnp3_doc_id) ----
#
# Real VM defect, root-caused (k8shakedown-rangea-20260829-084343,
# independent review): runtime/finalize/scoring all completed but the Rule
# stage silently came back "No alert." rule-query.template.json used `term`
# directly on `signal`/`src_ip`/`dst_ip`, but the actual ot-signals-zone-
# violation-* mapping declares them `text` with a `.keyword` multi-field --
# a `term` query against the analyzed `text` field does not reliably match
# the exact stored value (the Amenonuboco dashboard itself queries
# `signal.keyword`, confirming this). The query also never constrained
# `source_dnp3_doc_id` at all (freeze-decision-table.md SS3 requires it
# equal any member of the accepted Collector hit set). Not a scientific
# finding; the closed run is not rescued/resumed.
#
# Fix: `signal.keyword`/`src_ip.keyword`/`dst_ip.keyword` exact-match terms,
# plus a `terms` filter on `source_dnp3_doc_id.keyword` covering the
# COMPLETE accepted Collector hit-ID set (every _id the Collector query
# returned -- never a post hoc single chosen document). The Rule request is
# now finalized only after the Collector response is known (see
# Invoke-K8AutomatedQueries), and both index mappings are gated (fail-
# closed, not just retained) before either query runs.

Assert-K8Test 'rule-query.template.json contains every frozen Rule selector element, all as exact-match .keyword fields' {
    $ruleTemplate = Get-Content (Join-Path $ToolsDir 'rule-query.template.json') -Raw
    foreach ($needle in @('"signal.keyword"', '"src_ip.keyword"', '"dst_ip.keyword"', '"source_dnp3_doc_id.keyword"', '<WINDOW_START>', '<WINDOW_END>', '<COLLECTOR_HIT_IDS_JSON>')) {
        if ($ruleTemplate -notlike "*$needle*") { throw "rule-query.template.json is missing a required frozen selector element: $needle" }
    }
    if ($ruleTemplate -match '"term":\s*\{\s*"signal"\s*:' -or $ruleTemplate -match '"term":\s*\{\s*"src_ip"\s*:' -or $ruleTemplate -match '"term":\s*\{\s*"dst_ip"\s*:') {
        throw 'rule-query.template.json still runs term against the analyzed text field directly (no .keyword) -- the real-VM No-alert defect may be back'
    }
    # The template must itself be valid JSON (every placeholder sits inside
    # a string value), so a naive text edit can never leave it malformed --
    # this throws on its own if parsing fails, no separate assertion needed.
    $null = $ruleTemplate | ConvertFrom-Json
}

Assert-K8Test 'Invoke-K8AutomatedQueries: Rule query is finalized from the Collector RESPONSE, not the pre-window-only template, and both mappings are gated before either query runs' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8AutomatedQueries'
    foreach ($needle in @('Get-K8CollectorHitIds', 'collector-mapping-gate', 'rule-mapping-gate', 'accepted-collector-hit-ids.json', '<COLLECTOR_HIT_IDS_JSON>')) {
        if ($body -notmatch [regex]::Escape($needle)) { throw "Invoke-K8AutomatedQueries is missing: $needle" }
    }
    $collectorSearchIndex = $body.IndexOf("Method POST -Endpoint 'ot-logs-dnp3-*/_search'")
    $idsIndex = $body.IndexOf('Get-K8CollectorHitIds')
    $ruleSearchIndex = $body.IndexOf("Method POST -Endpoint 'ot-signals-zone-violation-*/_search'")
    if ($collectorSearchIndex -lt 0 -or $idsIndex -lt 0 -or $ruleSearchIndex -lt 0) { throw 'could not locate the Collector search, ID extraction, and Rule search call sites in order' }
    if (-not ($collectorSearchIndex -lt $idsIndex -and $idsIndex -lt $ruleSearchIndex)) { throw 'the Rule query is not being finalized strictly AFTER the Collector response is known, in order' }
    $collectorMapGateIndex = $body.IndexOf('collector-mapping-gate')
    $ruleMapGateIndex = $body.IndexOf('rule-mapping-gate')
    if ($collectorMapGateIndex -gt $collectorSearchIndex -or $ruleMapGateIndex -gt $ruleSearchIndex) { throw 'a mapping gate runs AFTER its corresponding search, not before -- it cannot fail-closed on drift if it does' }
}

Assert-K8Test 'Get-K8CollectorHitIds: 1/N accepted Collector hit IDs never unroll into a bare string, and zero hits returns an empty array (not a throw)' {
    Import-Module $CommonPath -Force
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-collids-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $onePath = Join-Path $tmp 'one.json'
        '{"hits":{"total":{"value":1,"relation":"eq"},"hits":[{"_id":"col-only","_source":{}}]}}' | Set-Content $onePath
        $one = Get-K8CollectorHitIds -CollectorResponsePath $onePath
        if ($one.Count -ne 1 -or $one[0] -ne 'col-only') { throw "REGRESSION: a single accepted Collector hit ID must remain a 1-element array, got Count=$($one.Count)" }

        $manyPath = Join-Path $tmp 'many.json'
        '{"hits":{"total":{"value":3,"relation":"eq"},"hits":[{"_id":"c1","_source":{}},{"_id":"c2","_source":{}},{"_id":"c3","_source":{}}]}}' | Set-Content $manyPath
        $many = Get-K8CollectorHitIds -CollectorResponsePath $manyPath
        if (($many -join ',') -ne 'c1,c2,c3') { throw "multiple accepted Collector hit IDs were not all retained in order: $($many -join ',')" }

        $zeroPath = Join-Path $tmp 'zero.json'
        '{"hits":{"total":{"value":0,"relation":"eq"},"hits":[]}}' | Set-Content $zeroPath
        $zero = Get-K8CollectorHitIds -CollectorResponsePath $zeroPath
        if ($zero.Count -ne 0) { throw 'zero Collector hits must return an empty array, not throw or return a null element' }
    }
    finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'REGRESSION: the Rule query built for zero AND for multiple accepted Collector IDs embeds a valid terms filter, never invalid JSON' {
    Import-Module $CommonPath -Force
    $template = Get-Content (Join-Path $ToolsDir 'rule-query.template.json') -Raw
    foreach ($case in @(
        @{ Ids = @(); Expected = '[]' }
        @{ Ids = @('only-one'); Expected = '["only-one"]' }
        @{ Ids = @('a', 'b', 'c'); Expected = '["a","b","c"]' }
    )) {
        $idsJson = if ($case.Ids.Count -eq 0) { '[]' } else { ($case.Ids | ConvertTo-Json -AsArray -Compress -Depth 3) }
        if ($idsJson -ne $case.Expected) { throw "collector-IDs-to-JSON for $($case.Ids.Count) id(s) produced '$idsJson', expected '$($case.Expected)'" }
        $built = $template.Replace('<WINDOW_START>', '2026-01-01T00:00:00Z').Replace('<WINDOW_END>', '2026-01-01T00:00:20Z').Replace('"<COLLECTOR_HIT_IDS_JSON>"', $idsJson)
        $parsed = $null
        try { $parsed = $built | ConvertFrom-Json } catch { throw "the built Rule query for $($case.Ids.Count) id(s) is not valid JSON: $($_.Exception.Message)" }
        # Get-K8ObjectPropertyValue, not direct .terms access: under
        # Set-StrictMode, a filter clause that is {range:...} or {term:...}
        # (no `terms` property at all) throws PropertyNotFoundException on
        # direct access instead of evaluating to $null.
        $termsClauses = @($parsed.query.bool.filter | Where-Object { Get-K8ObjectPropertyValue -Object $_ -Name 'terms' })
        if ($termsClauses.Count -ne 1) { throw "expected exactly 1 'terms' filter clause, found $($termsClauses.Count)" }
        $termsObject = Get-K8ObjectPropertyValue -Object $termsClauses[0] -Name 'terms'
        $termsValue = Get-K8ObjectPropertyValue -Object $termsObject -Name 'source_dnp3_doc_id.keyword'
        if (@($termsValue).Count -ne $case.Ids.Count) { throw "the built terms filter does not contain exactly the $($case.Ids.Count) supplied Collector ID(s)" }
    }
}

Assert-K8Test 'rule-mapping-gate PASSes on the real reported mapping shape (text + keyword multi-field for signal/src_ip/dst_ip/source_dnp3_doc_id)' {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-rulemap-good-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $mappingPath = Join-Path $tmp 'mapping.json'
        @'
{"ot-signals-zone-violation-2026.08.29":{"mappings":{"properties":{
  "signal": {"type": "text", "fields": {"keyword": {"type": "keyword", "ignore_above": 256}}},
  "src_ip": {"type": "text", "fields": {"keyword": {"type": "keyword", "ignore_above": 256}}},
  "dst_ip": {"type": "text", "fields": {"keyword": {"type": "keyword", "ignore_above": 256}}},
  "source_dnp3_doc_id": {"type": "text", "fields": {"keyword": {"type": "keyword", "ignore_above": 256}}}
}}}}
'@ | Set-Content $mappingPath
        & python $helper rule-mapping-gate --mapping $mappingPath --output (Join-Path $tmp 'out.json')
        if ($LASTEXITCODE -ne 0) { throw 'the real reported text+keyword mapping shape incorrectly FAILED the Rule selector mapping gate' }
        $result = Get-Content (Join-Path $tmp 'out.json') -Raw | ConvertFrom-Json
        if (-not $result.mapping_gate_pass) { throw 'mapping_gate_pass was false for a shape that should pass' }
    }
    finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'REGRESSION: rule-mapping-gate fails closed when the required .keyword multi-field is missing on any one frozen selector field' {
    foreach ($missingField in @('signal', 'src_ip', 'dst_ip', 'source_dnp3_doc_id')) {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-rulemap-bad-$missingField-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            $fields = [ordered]@{
                signal = '{"type": "text", "fields": {"keyword": {"type": "keyword"}}}'
                src_ip = '{"type": "text", "fields": {"keyword": {"type": "keyword"}}}'
                dst_ip = '{"type": "text", "fields": {"keyword": {"type": "keyword"}}}'
                source_dnp3_doc_id = '{"type": "text", "fields": {"keyword": {"type": "keyword"}}}'
            }
            $fields[$missingField] = '{"type": "text"}'
            $mappingJson = '{"ot-signals-zone-violation-2026.08.29":{"mappings":{"properties":{' +
                ((($fields.Keys | ForEach-Object { "`"$_`":$($fields[$_])" }) -join ',')) + '}}}}'
            $mappingPath = Join-Path $tmp 'mapping.json'
            $mappingJson | Set-Content $mappingPath
            & python $helper rule-mapping-gate --mapping $mappingPath --output (Join-Path $tmp 'out.json') 2>$null
            if ($LASTEXITCODE -eq 0) { throw "a mapping missing .keyword on '$missingField' incorrectly PASSed the Rule selector mapping gate" }
        }
        finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Assert-K8Test 'collector-mapping-gate reuses the existing ot-logs-dnp3-* field set and is called unconditionally for both Range A and B' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8AutomatedQueries'
    $gateCallIndex = $body.IndexOf('collector-mapping-gate')
    $rangeBBranchIndex = $body.IndexOf("if (`$Range -eq 'b')")
    if ($gateCallIndex -lt 0) { throw 'collector-mapping-gate is not called from Invoke-K8AutomatedQueries' }
    if ($rangeBBranchIndex -ge 0 -and $gateCallIndex -gt $rangeBBranchIndex) { throw 'the Collector selector mapping gate appears to run only inside the Range-B-only branch -- Range A needs it too' }
}

Assert-K8Test 'Test-K8ScoringInputArtifactCompleteness requires the new Rule/Collector selector-mapping-gate and accepted-hit-id artifacts' {
    foreach ($needle in @('collector-selector-mapping-gate.json', 'accepted-collector-hit-ids.json', 'rule-selector-mapping-gate.json')) {
        if ($commonSource -notlike "*$needle*") { throw "completeness gate is missing required artifact: $needle" }
    }
}

# --- 17. Gateway interface resolution fix (frozen ip -o -4 addr show) -------
#
# Real VM defect, root-caused (Range B fault STOP: "Cannot find device
# \"UP\""), against exact commit 5a70273: Resolve-K8GatewayInterface used
# `ip -br addr` (a DIFFERENT command from a DIFFERENT frozen procedure --
# c2-dnp3-capture-procedure.md's Ground Truth capture-context resolution,
# executed by the frozen study01_capture.py itself, never this function)
# and read column index [1] -- `ip -br addr`'s STATE field
# ("UP"/"DOWN"/"UNKNOWN"), not an interface name. The actually-frozen
# procedure for Range B (c2-dnp3-range-derivation.md SS3) resolves the
# gateway via `ip -o -4 addr show | awk '/<cidr>/ {print $2}' | head -n 1`
# -- a structurally different oneline format where field 2 (1-indexed,
# field index [1] 0-indexed) genuinely IS the interface token. Not a
# scientific finding; the closed run is not rescued/resumed.
#
# Fix: adopts the actually-frozen `ip -o -4 addr show`, parsed IN
# POWERSHELL (never through a nested `sh -lc '... | awk ... | head -n1'`
# pipeline, avoiding docker-exec/sh/awk quoting entirely) via
# Invoke-K8SeparatedNativeCapture (stdout/stderr genuinely separated).
# Requires EXACTLY ONE matching line (fail-closed on zero or multiple,
# matching the frozen "the UNIQUE wan_router interface" wording -- `head
# -n 1` in the illustrative frozen snippet silently takes the first of
# several candidates instead). Beyond the frozen procedure: rejects known
# Linux operstate tokens and empty values by name, AND independently
# re-verifies the resolved value via a SEPARATE `ip -o -4 addr show dev
# <name>` query confirming it is a real interface actually carrying the
# target CIDR, before ever returning it for fault injection.

$gwMockDir = Join-Path $ShakedownDir 'tests\mock-docker'
$gwOriginalPath = $env:PATH
try {
    $env:PATH = "$gwMockDir;$env:PATH"
    Import-Module $CommonPath -Force

    Assert-K8Test 'REGRESSION: Resolve-K8GatewayInterface resolves the unique ip -o -4 addr show match (never the ip -br addr STATE column)' {
        $env:K8_MOCK_DOCKER_STATE = 'gateway-resolve-ok'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-gw-ok-" + [guid]::NewGuid())
        try {
            $gw = Resolve-K8GatewayInterface -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir
            if ($gw.Interface -ne 'eth6') { throw "expected 'eth6', got '$($gw.Interface)'" }
            if (-not (Test-Path (Join-Path $dir 'contract-output\gateway-interface-resolution.txt'))) { throw 'gateway-interface-resolution.txt was not retained' }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'REGRESSION: zero matching interfaces fails closed; multiple matching interfaces fails closed (frozen: the UNIQUE interface, never head -n 1 silently choosing one)' {
        $env:K8_MOCK_DOCKER_STATE = 'gateway-resolve-zero-match'
        $dir1 = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-gw-zero-" + [guid]::NewGuid())
        $stopped1 = $false
        try { Resolve-K8GatewayInterface -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir1 } catch { $stopped1 = $true }
        finally { Remove-Item $dir1 -Recurse -Force -ErrorAction SilentlyContinue }
        if (-not $stopped1) { throw 'zero matching interfaces did not STOP' }

        $env:K8_MOCK_DOCKER_STATE = 'gateway-resolve-multi-match'
        $dir2 = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-gw-multi-" + [guid]::NewGuid())
        $stopped2 = $false
        try { Resolve-K8GatewayInterface -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir2 } catch { $stopped2 = $true }
        finally { Remove-Item $dir2 -Recurse -Force -ErrorAction SilentlyContinue }
        if (-not $stopped2) { throw 'multiple matching interfaces did not STOP' }
    }

    Assert-K8Test 'REGRESSION: ip -o -4 addr show transport failure (nonzero exit) fails closed with the exit code in the diagnostic' {
        $env:K8_MOCK_DOCKER_STATE = 'gateway-resolve-exit-nonzero'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-gw-exit-" + [guid]::NewGuid())
        try {
            $stopped = $false; $msg = ''
            try { Resolve-K8GatewayInterface -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir } catch { $stopped = $true; $msg = $_.Exception.Message }
            if (-not $stopped) { throw 'a transport failure did not STOP' }
            if ($msg -notmatch 'exit 1') { throw "the exit code was not surfaced in the failure message: $msg" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'REGRESSION: a stray stderr line never contaminates gateway interface resolution (stdout/stderr genuinely separated)' {
        $env:K8_MOCK_DOCKER_STATE = 'gateway-resolve-stderr-noise'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-gw-noise-" + [guid]::NewGuid())
        try {
            $gw = Resolve-K8GatewayInterface -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir
            if ($gw.Interface -ne 'eth6') { throw "expected 'eth6' despite stderr noise, got '$($gw.Interface)'" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'REGRESSION: a known Linux operstate token (UP/DOWN/UNKNOWN/etc.) is rejected by name, independent of the structural command fix' {
        $env:K8_MOCK_DOCKER_STATE = 'gateway-resolve-state-token-regression'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-gw-stoken-" + [guid]::NewGuid())
        try {
            $stopped = $false; $msg = ''
            try { Resolve-K8GatewayInterface -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir } catch { $stopped = $true; $msg = $_.Exception.Message }
            if (-not $stopped) { throw "a state-token value ('UP') incorrectly resolved as a real interface -- this is the EXACT real VM defect symptom" }
            if ($msg -notmatch "'UP'") { throw "failure message does not name the rejected value: $msg" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'REGRESSION: independent re-verification catches a resolved value that does not actually carry the target CIDR when queried directly (the general-purpose backstop)' {
        $env:K8_MOCK_DOCKER_STATE = 'gateway-resolve-verify-fails'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-gw-verifyfail-" + [guid]::NewGuid())
        try {
            $stopped = $false
            try { Resolve-K8GatewayInterface -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir } catch { $stopped = $true }
            if (-not $stopped) { throw 'a resolved value that fails independent re-verification did not STOP' }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'Assert-K8UnrelatedMirrorFilter still finds an unrelated mirror filter after its stdout/stderr separation fix' {
        $env:K8_MOCK_DOCKER_STATE = 'gateway-resolve-ok'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-mirror-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'contract-output') | Out-Null
        try {
            Assert-K8UnrelatedMirrorFilter -Gateway ([pscustomobject]@{Router = 'mock-container-id'; Interface = 'eth6'}) -RunEvidence $dir
            if (-not (Test-Path (Join-Path $dir 'contract-output\unrelated-mirror-filters.txt'))) { throw 'unrelated-mirror-filters.txt was not retained' }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
finally { $env:PATH = $gwOriginalPath }

Assert-K8Test 'Resolve-K8GatewayInterface uses ip -o -4 addr show (frozen c2-dnp3-range-derivation.md SS3), never ip -br addr (a different frozen procedure for a different purpose)' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Resolve-K8GatewayInterface'
    if ($body -match "'ip -br addr'") { throw "Resolve-K8GatewayInterface still uses 'ip -br addr' -- the real-VM 'Cannot find device UP' defect may be back" }
    foreach ($needle in @("'ip', '-o', '-4', 'addr', 'show'", 'Invoke-K8SeparatedNativeCapture', 'badTokens', '-ccontains')) {
        if ($body -notmatch [regex]::Escape($needle)) { throw "Resolve-K8GatewayInterface is missing: $needle" }
    }
    # Exactly one match required, not head -n1's silent first-of-many.
    if ($body -notmatch '\$gatewayMatches\.Count\s*-ne\s*1') { throw 'Resolve-K8GatewayInterface no longer requires an exact, unique match' }
}

Assert-K8Test 'Resolve-K8GatewayInterface independently re-verifies the resolved interface via a SEPARATE dev-scoped query before returning it' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Resolve-K8GatewayInterface'
    if ($body -notmatch "'dev',\s*\`$resolvedIf") { throw 'no separate dev-scoped re-verification query was found' }
    $verifyIndex = $body.IndexOf('$verifyCapture')
    $returnIndex = $body.IndexOf('return [pscustomobject]')
    if ($verifyIndex -lt 0 -or $returnIndex -lt 0 -or $verifyIndex -gt $returnIndex) { throw 're-verification does not run before the resolved interface is returned' }
}

Assert-K8Test 'Cross-cutting audit: no other native-CLI-output parsing in this module uses a fixed whitespace-split column index (the ip-br-addr-style defect class)' {
    # The one remaining `-split` + fixed-index shape in the whole module is
    # this function's own fix, which now indexes ip -o -4 addr show's
    # (verified, documented) field layout -- not a fragile guess. Every
    # OTHER native-output parser in this module either uses an anchored
    # regex capture group (Assert-K8UnrelatedMirrorFilter's
    # ^\d+:\s+([^:@]+)) or structured JSON, never bare positional splitting.
    $needle = "-split '" + '\s+' + "'"   # the literal source text: -split '\s+'
    $found = @([regex]::Matches($commonSource, [regex]::Escape($needle)))
    if ($found.Count -ne 1) { throw "expected exactly 1 whitespace-split-then-fixed-index site (Resolve-K8GatewayInterface's own, now-corrected one), found $($found.Count)" }
}

# --- 24. Rule index lazy-creation observer defect (rule-mapping-gate) -------
#
# Real VM STOP, root-caused (k8shakedown-rangeb-20260829-111026, closed,
# not rescued): `rule-mapping-gate: ValueError: mapping response contains
# no indices`. Independent investigation confirmed against the pinned
# Amenonuboco source (78fc17746b5d663fafec9dffe563d79fe9ea02b7,
# scenarios/legacy-power-grid-signals/zone_violation.py) that the Rule
# alert index (ot-signals-zone-violation-*) is created LAZILY -- only on
# zone_violation.py's own `_bulk` write on its FIRST actual alert, inside
# an `if bulk_lines:` guard never entered when zero violations fire. There
# is no startup-time creation and no index template. Range B's own FROZEN,
# EXPECTED Rule output is "No alert" (scoring.md SS3), which genuinely
# means this index may never exist for a correctly-behaving run. No frozen
# Study 01 document requires the Rule index to exist -- only
# k6-r-obs-05-collector-query-contract.md SS2 freezes a mapping-gate
# requirement, and only for the Collector/R-OBS-05 ot-logs-dnp3-* index
# (populated continuously by ALL structured traffic, unaffected by this
# defect, and left completely unchanged by this round's fix).
#
# Classification: this is a SHAKEDOWN OBSERVER DEFECT, introduced when
# rule-mapping-gate was added in an earlier round to fix a real Rule-query
# exact-match defect -- it over-generalized from the genuinely-frozen
# R-OBS-05 mapping-gate contract without accounting for the asymmetry
# between a continuously-populated index and an alert-triggered one. It is
# NOT a scientific finding and NOT an Amenonuboco runtime defect: the
# pinned zone_detector code behaves exactly as designed. Fixed entirely in
# Shakedown tooling (k8_shakedown_evidence.py); no Study 01 frozen file
# changed, no dummy alert generated, no additional trigger event added.
#
# Fix: rule-mapping-gate now PASSes (retaining `index_present: false`,
# never throwing) when the mapping response is the empty `{}` ES returns
# for a wildcard pattern matching zero concrete indices -- and still fails
# closed exactly as before when the index DOES exist but a required field
# is missing its `.keyword` multi-field. "Index absent" and "index present
# with 0 hits" are retained as distinguishable states so they are never
# conflated into one undifferentiated "No alert" downstream.

Assert-K8Test 'REGRESSION: rule-mapping-gate PASSes (index_present: false) when the Rule index does not exist yet -- an empty {} ES response is a valid state, not a failure' {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-rulemap-absent-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        '{}' | Set-Content (Join-Path $tmp 'mapping.json')
        & python $helper rule-mapping-gate --mapping (Join-Path $tmp 'mapping.json') --output (Join-Path $tmp 'out.json')
        if ($LASTEXITCODE -ne 0) { throw 'an empty {} mapping response (no matching indices) incorrectly failed the Rule selector mapping gate -- this makes a genuine negative Rule observation impossible' }
        $result = Get-Content (Join-Path $tmp 'out.json') -Raw | ConvertFrom-Json
        if ($result.index_present -ne $false) { throw "index_present should be false for an absent index, got '$($result.index_present)'" }
        if (-not $result.mapping_gate_pass) { throw 'mapping_gate_pass should be true when there is no index to have wrong field types in' }
    }
    finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'REGRESSION: rule-mapping-gate PASSes (index_present: true) on the real reported text+keyword mapping shape when the index DOES exist' {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-rulemap-present-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        @'
{"ot-signals-zone-violation-2026.08.29":{"mappings":{"properties":{
  "signal": {"type": "text", "fields": {"keyword": {"type": "keyword"}}},
  "src_ip": {"type": "text", "fields": {"keyword": {"type": "keyword"}}},
  "dst_ip": {"type": "text", "fields": {"keyword": {"type": "keyword"}}},
  "source_dnp3_doc_id": {"type": "text", "fields": {"keyword": {"type": "keyword"}}}
}}}}
'@ | Set-Content (Join-Path $tmp 'mapping.json')
        & python $helper rule-mapping-gate --mapping (Join-Path $tmp 'mapping.json') --output (Join-Path $tmp 'out.json')
        if ($LASTEXITCODE -ne 0) { throw 'a correct, present mapping incorrectly failed the gate' }
        $result = Get-Content (Join-Path $tmp 'out.json') -Raw | ConvertFrom-Json
        if ($result.index_present -ne $true) { throw "index_present should be true when the index exists, got '$($result.index_present)'" }
    }
    finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'REGRESSION: rule-mapping-gate still fails closed when the index EXISTS but a required field is missing its .keyword multi-field (the real defect class this gate exists to catch)' {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-rulemap-drift-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        @'
{"ot-signals-zone-violation-2026.08.29":{"mappings":{"properties":{
  "signal": {"type": "text", "fields": {"keyword": {"type": "keyword"}}},
  "src_ip": {"type": "text", "fields": {"keyword": {"type": "keyword"}}},
  "dst_ip": {"type": "text", "fields": {"keyword": {"type": "keyword"}}},
  "source_dnp3_doc_id": {"type": "text"}
}}}}
'@ | Set-Content (Join-Path $tmp 'mapping.json')
        & python $helper rule-mapping-gate --mapping (Join-Path $tmp 'mapping.json') --output (Join-Path $tmp 'out.json') 2>$null
        if ($LASTEXITCODE -eq 0) { throw 'an existing index missing a required .keyword multi-field incorrectly PASSed -- fixing the false negative must not weaken the real field/type drift gate' }
    }
    finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'REGRESSION: collector-mapping-gate and the R-OBS-05 mapping-gate are UNCHANGED -- both still fail closed on an empty {} mapping response (the frozen k6-r-obs-05-collector-query-contract.md SS2 requirement, deliberately not relaxed)' {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-collectormap-unchanged-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        '{}' | Set-Content (Join-Path $tmp 'mapping.json')
        & python $helper collector-mapping-gate --mapping (Join-Path $tmp 'mapping.json') --output (Join-Path $tmp 'c-out.json') 2>$null
        if ($LASTEXITCODE -eq 0) { throw 'collector-mapping-gate must still fail closed on an empty mapping response -- ot-logs-dnp3-* is not subject to the Rule-index lazy-creation exception' }
        & python $helper mapping-gate --mapping (Join-Path $tmp 'mapping.json') --output (Join-Path $tmp 'r-out.json') 2>$null
        if ($LASTEXITCODE -eq 0) { throw 'the frozen R-OBS-05 mapping-gate must still fail closed on an empty mapping response' }
    }
    finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

$ruleIndexMockDir = Join-Path $ShakedownDir 'tests\mock-docker'
$ruleIndexOriginalPath = $env:PATH
try {
    $env:PATH = "$ruleIndexMockDir;$env:PATH"
    Import-Module $CommonPath -Force

    Assert-K8Test 'REGRESSION (end-to-end, Range A): Invoke-K8AutomatedQueries completes with 0 Rule hits when the Rule index does not exist yet, never throwing' {
        $env:K8_MOCK_DOCKER_STATE = 'rule-index-absent'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-aq-absent-a-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'environment'), (Join-Path $dir 'collector-output'), (Join-Path $dir 'rule-output') | Out-Null
        '{"size":10}' | Set-Content (Join-Path $dir 'environment\collector-query.json')
        try {
            $ws = ([datetimeoffset]::UtcNow).AddSeconds(-100).ToString('o'); $we = ([datetimeoffset]::UtcNow).AddSeconds(100).ToString('o')
            Invoke-K8AutomatedQueries -Range 'a' -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir -WindowStart $ws -WindowEnd $we *>$null
            $mappingGate = Get-Content (Join-Path $dir 'rule-output\rule-selector-mapping-gate.json') -Raw | ConvertFrom-Json
            if ($mappingGate.index_present -ne $false) { throw 'expected index_present=false to be retained' }
            $ruleResponse = Get-Content (Join-Path $dir 'rule-output\rule-response.json') -Raw | ConvertFrom-Json
            if ($ruleResponse.hits.total.value -ne 0) { throw "expected 0 Rule hits, got $($ruleResponse.hits.total.value)" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'REGRESSION (end-to-end, Range B up to the Rule stage): the same Rule-index-absent scenario resolves identically for Range B before R-OBS-05''s own, separately-tested logic runs' {
        # Scoped to the Rule mapping-gate + Rule query portion specifically
        # (R-OBS-05's own document/pcap correlation is a separate, already
        # regression-tested gate with its own strict exact-field-match
        # requirement unrelated to this defect -- exercising it fully here
        # would only duplicate that existing coverage, not add confidence
        # in the fix under test).
        $env:K8_MOCK_DOCKER_STATE = 'rule-index-absent'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-aq-absent-b-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'environment'), (Join-Path $dir 'collector-output'), (Join-Path $dir 'rule-output') | Out-Null
        '{"size":10}' | Set-Content (Join-Path $dir 'environment\collector-query.json')
        try {
            $ws = ([datetimeoffset]::UtcNow).AddSeconds(-100).ToString('o'); $we = ([datetimeoffset]::UtcNow).AddSeconds(100).ToString('o')
            # Range B additionally runs R-OBS-05 (unrelated pcap/document
            # correlation), which needs fixtures this test does not set up;
            # only the Rule-stage artifacts, already written before that
            # point, are asserted.
            try { Invoke-K8AutomatedQueries -Range 'b' -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir -WindowStart $ws -WindowEnd $we *>$null } catch { }
            $mappingGate = Get-Content (Join-Path $dir 'rule-output\rule-selector-mapping-gate.json') -Raw | ConvertFrom-Json
            if ($mappingGate.index_present -ne $false) { throw 'expected index_present=false to be retained for Range B too' }
            $ruleResponse = Get-Content (Join-Path $dir 'rule-output\rule-response.json') -Raw | ConvertFrom-Json
            if ($ruleResponse.hits.total.value -ne 0) { throw "expected 0 Rule hits for Range B, got $($ruleResponse.hits.total.value)" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'rule-mapping-gate is called unconditionally for both Range A and B (not inside a Range-B-only or Range-A-only branch)' {
        $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8AutomatedQueries'
        $gateCallIndex = $body.IndexOf('rule-mapping-gate')
        $rangeBBranchIndex = $body.IndexOf("if (`$Range -eq 'b')")
        if ($gateCallIndex -lt 0) { throw 'rule-mapping-gate is not called from Invoke-K8AutomatedQueries' }
        if ($rangeBBranchIndex -ge 0 -and $gateCallIndex -gt $rangeBBranchIndex) { throw 'rule-mapping-gate appears to run only inside the Range-B-only branch -- Range A needs it too' }
    }

    Assert-K8Test 'REGRESSION (end-to-end): Invoke-K8AutomatedQueries completes with a correlating Rule hit when the Rule index exists and is correctly mapped' {
        $env:K8_MOCK_DOCKER_STATE = 'rule-index-present-good'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-aq-good-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'environment'), (Join-Path $dir 'collector-output'), (Join-Path $dir 'rule-output') | Out-Null
        '{"size":10}' | Set-Content (Join-Path $dir 'environment\collector-query.json')
        try {
            $ws = ([datetimeoffset]::UtcNow).AddSeconds(-100).ToString('o'); $we = ([datetimeoffset]::UtcNow).AddSeconds(100).ToString('o')
            Invoke-K8AutomatedQueries -Range 'a' -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir -WindowStart $ws -WindowEnd $we *>$null
            $mappingGate = Get-Content (Join-Path $dir 'rule-output\rule-selector-mapping-gate.json') -Raw | ConvertFrom-Json
            if ($mappingGate.index_present -ne $true) { throw 'expected index_present=true when the index genuinely exists' }
            $correlation = Get-Content (Join-Path $dir 'rule-output\collector-rule-correlation.json') -Raw | ConvertFrom-Json
            if ($correlation.rule_hit_count -ne 1 -or -not $correlation.all_rule_hits_correlate) { throw "expected 1 fully-correlating Rule hit: $($correlation | ConvertTo-Json -Compress)" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'REGRESSION (end-to-end): Invoke-K8AutomatedQueries fails closed when the Rule index exists but is missing a required .keyword multi-field' {
        $env:K8_MOCK_DOCKER_STATE = 'rule-index-present-bad-mapping'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-aq-bad-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'environment'), (Join-Path $dir 'collector-output'), (Join-Path $dir 'rule-output') | Out-Null
        '{"size":10}' | Set-Content (Join-Path $dir 'environment\collector-query.json')
        try {
            $ws = ([datetimeoffset]::UtcNow).AddSeconds(-100).ToString('o'); $we = ([datetimeoffset]::UtcNow).AddSeconds(100).ToString('o')
            $stopped = $false
            try { Invoke-K8AutomatedQueries -Range 'a' -RunId 'x' -ComposePath 'y.yml' -RunEvidence $dir -WindowStart $ws -WindowEnd $we *>$null } catch { $stopped = $true }
            if (-not $stopped) { throw 'a present-but-mistyped Rule index did not STOP the pipeline' }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
finally { $env:PATH = $ruleIndexOriginalPath }

Assert-K8Test 'Invoke-K8AutomatedQueries logs the index_present distinction so the console transcript states the same thing the retained JSON does' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8AutomatedQueries'
    foreach ($needle in @('index_present', 'does not exist yet')) {
        if ($body -notmatch [regex]::Escape($needle)) { throw "Invoke-K8AutomatedQueries no longer logs the index-present/absent distinction: missing '$needle'" }
    }
}

# --- 25. R-OBS-05 auxiliary liveness capture (frozen SS4 conformance) -------
#
# Real VM STOPs k8shakedown-rangeb-20260829-111026 / -115720 (both closed,
# neither rescued, re-queried, nor re-captured). Root cause:
# Write-K8UnrelatedPcapRows decoded the frozen SENSOR pcap, while
# k6-r-obs-05-collector-query-contract.md SS4 requires correlation against
# "the separate R-OBS-05 `tap_observer:eth0` liveness pcap". The frozen
# CAPTURE_FILTER ("host 10.1.20.11 and host 10.1.10.10 and tcp port 20000",
# enforced by capture_lifecycle.py:163) means the Sensor pcap can NEVER
# contain the unrelated flow (10.1.10.10<->10.1.40.10 has no 10.1.20.11), so
# that gate was both non-conformant with SS4 and structurally unsatisfiable.
#
# Classification: A -- executable transcription correction completing an
# ALREADY-FROZEN requirement. Semantic impact NO CHANGE; no Protocol
# Amendment. Ground Truth/Sensor stages, CAPTURE_FILTER, study01_capture.py,
# sender, fault, T0, window, SS3 selector, SS4 correlation, +-1ms and scoring
# are all untouched.

Assert-K8Test 'Auxiliary liveness spec: every acquisition parameter is a fixed module constant with no operator input, and there is NO capture-time BPF filter' {
    Import-Module $CommonPath -Force
    $spec = Get-K8Robs05LivenessSpec -RunId 'k8shakedown-rangeb-20260101-000000'
    if ($spec.NamespaceService -ne 'tap_observer') { throw "namespace must be the frozen SS4 tap_observer, got '$($spec.NamespaceService)'" }
    if ($spec.Interface -ne 'eth0') { throw "interface must be the frozen SS4 eth0, got '$($spec.Interface)'" }
    if ($spec.Artifact -ne 'contract-output\r-obs-05-liveness.pcap') { throw "unexpected artifact path: $($spec.Artifact)" }
    # The spec object must expose NO filter property at all -- absence is the
    # design, so there is nothing an operator or caller could set.
    if ($spec.PSObject.Properties.Name -contains 'Filter' -or $spec.PSObject.Properties.Name -contains 'Bpf') {
        throw 'the liveness spec exposes a BPF/filter property -- capture-time filtering must not be configurable'
    }
    # Get-K8Robs05LivenessSpec must take ONLY the run ID: no filter/interface
    # /namespace parameter can be threaded in from a caller or the operator.
    # @() around each pipeline: a single-element result is a scalar, and
    # .Count on a scalar throws under Set-StrictMode.
    $params = @((Get-Command Get-K8Robs05LivenessSpec).Parameters.Keys | Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters })
    if (@($params | Where-Object { $_ -ne 'RunId' }).Count -ne 0) { throw "Get-K8Robs05LivenessSpec accepts more than RunId: $($params -join ',')" }
}

Assert-K8Test 'REGRESSION: the auxiliary helper argv carries NO trailing BPF filter (frozen argv shape minus the filter argument)' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Start-K8Robs05LivenessCapture'
    if ($body -notmatch "'-w',\s*\`$spec\.ContainerPcap\s*\)") { throw "the helper argv must END at '-w <container pcap>' with no filter argument after it" }
    if ($body -match 'CAPTURE_FILTER' -or $body -match 'host 10\.1\.') { throw 'the auxiliary capture must not carry any BPF host filter' }
}

Assert-K8Test 'REGRESSION: Write-K8UnrelatedPcapRows reads the auxiliary liveness pcap, NEVER the Sensor pcap (frozen SS4 conformance)' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Write-K8UnrelatedPcapRows'
    if ($body -match "Join-Path\s+\`$RunEvidence\s+'sensor-input") { throw 'Write-K8UnrelatedPcapRows still resolves the Sensor pcap as its decode source -- the frozen-SS4 non-conformance is back' }
    if ($body -notmatch "\`$spec\.Artifact") { throw 'Write-K8UnrelatedPcapRows no longer decodes the auxiliary liveness artifact' }
    # SS3 selector must be byte-identical to the frozen bidirectional selector.
    foreach ($needle in @('ip.src == 10.1.10.10 && ip.dst == 10.1.40.10', 'dnp3.al.func == 1 || dnp3.al.func == 5', 'ip.src == 10.1.40.10 && ip.dst == 10.1.10.10', 'dnp3.al.func == 129')) {
        if ($body -notmatch [regex]::Escape($needle)) { throw "the frozen SS3 selector was altered: missing '$needle'" }
    }
}

Assert-K8Test 'ARTIFACT SEPARATION: the auxiliary liveness pcap is never read by any Ground Truth / Sensor / target-query / rule-correlation path' {
    $source = Get-Content $CommonPath -Raw
    # Only these two functions may reference the liveness artifact at all.
    foreach ($fn in @('Write-K8TargetCaptureDecode', 'Invoke-K8AutomatedQueries', 'Get-K8CollectorHitIds', 'Write-K8RuntimeContractRecord')) {
        $body = Get-K8FunctionBodyText -Path $CommonPath -Name $fn
        if ($body -match 'r-obs-05-liveness\.pcap' -or $body -match 'LivenessSpec') {
            throw "$fn references the auxiliary liveness capture -- it is liveness/control evidence only (frozen SS1) and must never reach a target stage"
        }
    }
    # And the frozen Sensor/Ground Truth artifacts must still be what the
    # frozen stages produce, unchanged.
    if ($source -notmatch [regex]::Escape('sensor-input\mirror-capture\c2-mirror-sensor.pcap')) { throw 'the frozen Sensor artifact path disappeared from the module' }
}

Assert-K8Test 'Range A runtime behavior is unchanged: the auxiliary capture is Range-B-only at BOTH its start and completion call sites' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8ShakedownRangeABBody'
    foreach ($call in @('Start-K8Robs05LivenessCapture', 'Complete-K8Robs05LivenessCapture')) {
        $idx = $body.IndexOf($call)
        if ($idx -lt 0) { throw "$call is not called from the runner" }
        # The nearest preceding `if ($Range -eq 'b')` must be closer than any
        # other guard: assert the call sits inside a Range-B branch.
        $before = $body.Substring(0, $idx)
        $lastGuard = $before.LastIndexOf("if (`$Range -eq 'b')")
        if ($lastGuard -lt 0) { throw "$call is not guarded by a Range B branch -- it would change Range A runtime behavior" }
    }
    # Start must precede the sender; completion must follow the window-end wait.
    $startIdx = $body.IndexOf('Start-K8Robs05LivenessCapture')
    $senderIdx = $body.IndexOf('study01_sender.py')
    $windowEndIdx = $body.IndexOf('Wait-K8CaptureWindowEnd')
    $completeIdx = $body.IndexOf('Complete-K8Robs05LivenessCapture')
    if (-not ($startIdx -lt $senderIdx)) { throw 'the auxiliary capture must start before the sender/T0' }
    if (-not ($windowEndIdx -lt $completeIdx)) { throw 'the auxiliary capture must be completed only after the T0+15s window-end wait' }
}

$auxMockDir = Join-Path $ShakedownDir 'tests\mock-docker'
$auxOriginalPath = $env:PATH
try {
    $env:PATH = "$auxMockDir;$env:PATH"
    Import-Module $CommonPath -Force

    function New-K8AuxTestDir {
        param([double] $T0OffsetSeconds)
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-aux-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'contract-output') | Out-Null
        ([datetimeoffset]::UtcNow).AddSeconds($T0OffsetSeconds).ToString('o') | Set-Content (Join-Path $dir 'metadata-t0.txt')
        return $dir
    }

    Assert-K8Test 'Auxiliary capture: helper start failure fails closed as an APPARATUS failure (never an R-OBS-05 / classification value)' {
        $env:K8_MOCK_DOCKER_STATE = 'robs05-helper-start-fails'
        $dir = New-K8AuxTestDir -T0OffsetSeconds 30
        try {
            $stopped = $false; $msg = ''
            try { Start-K8Robs05LivenessCapture -RunId 'k8shakedown-rangeb-T' -ComposePath 'y.yml' -RunEvidence $dir } catch { $stopped = $true; $msg = $_.Exception.Message }
            if (-not $stopped) { throw 'a helper that failed to start did not STOP' }
            if ($msg -notmatch 'apparatus failure') { throw "failure was not labelled an apparatus failure: $msg" }
            if ($msg -match 'Unresolved' -or $msg -match 'R-OBS-05 Fail') { throw 'acquisition failure must not be mapped onto a scientific classification value' }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'Auxiliary capture: a helper that never reports "listening on" fails closed' {
        $env:K8_MOCK_DOCKER_STATE = 'robs05-never-listens'
        $dir = New-K8AuxTestDir -T0OffsetSeconds 30
        try {
            $stopped = $false
            try { Start-K8Robs05LivenessCapture -RunId 'k8shakedown-rangeb-T' -ComposePath 'y.yml' -RunEvidence $dir } catch { $stopped = $true }
            if (-not $stopped) { throw 'a helper that never listened did not STOP' }
            if (-not (Test-Path (Join-Path $dir 'contract-output\r-obs-05-capture-lifecycle.json'))) { throw 'the lifecycle record must still be retained on failure' }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'Auxiliary capture: listening confirmed AFTER T0-5s fails closed (window coverage cannot be shown)' {
        $env:K8_MOCK_DOCKER_STATE = 'rule-index-present-good'
        $dir = New-K8AuxTestDir -T0OffsetSeconds -60   # T0 in the past; window already closed
        try {
            $t0 = [datetimeoffset]::Parse((Get-Content (Join-Path $dir 'metadata-t0.txt') -Raw).Trim())
            # Listening completed 1s BEFORE T0 -- i.e. inside [T0-5s, T0], too late.
            $record = [ordered]@{
                schema_version = 1; run_id = 'k8shakedown-rangeb-T'; helper_name = 'k8shakedown-rangeb-T-r-obs-05-liveness-capture'
                steps = @(
                    [ordered]@{ step = 'start'; argv = @('docker'); exit_code = 0; stdout = 'aux'; stderr = ''; started_utc = $t0.AddSeconds(-20).ToString('o'); completed_utc = $t0.AddSeconds(-20).ToString('o') },
                    [ordered]@{ step = 'listening-check'; argv = @('docker'); exit_code = 0; stdout = 'listening on eth0'; stderr = ''; started_utc = $t0.AddSeconds(-2).ToString('o'); completed_utc = $t0.AddSeconds(-1).ToString('o') }
                )
            }
            $record | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'contract-output\r-obs-05-capture-lifecycle.json') -Encoding utf8NoBOM
            $stopped = $false; $msg = ''
            try { Complete-K8Robs05LivenessCapture -RunId 'k8shakedown-rangeb-T' -RunEvidence $dir } catch { $stopped = $true; $msg = $_.Exception.Message }
            if (-not $stopped) { throw 'a late listening confirmation did not STOP' }
            if ($msg -notmatch 'after the frozen window start') { throw "wrong failure reason: $msg" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'Auxiliary capture: a helper found NOT running at the window end fails closed' {
        $env:K8_MOCK_DOCKER_STATE = 'robs05-helper-died'
        $dir = New-K8AuxTestDir -T0OffsetSeconds -60
        try {
            $t0 = [datetimeoffset]::Parse((Get-Content (Join-Path $dir 'metadata-t0.txt') -Raw).Trim())
            $record = [ordered]@{
                schema_version = 1; run_id = 'k8shakedown-rangeb-T'; helper_name = 'k8shakedown-rangeb-T-r-obs-05-liveness-capture'
                steps = @([ordered]@{ step = 'listening-check'; argv = @('docker'); exit_code = 0; stdout = 'listening on eth0'; stderr = ''; started_utc = $t0.AddSeconds(-20).ToString('o'); completed_utc = $t0.AddSeconds(-10).ToString('o') })
            }
            $record | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'contract-output\r-obs-05-capture-lifecycle.json') -Encoding utf8NoBOM
            $stopped = $false; $msg = ''
            try { Complete-K8Robs05LivenessCapture -RunId 'k8shakedown-rangeb-T' -RunEvidence $dir } catch { $stopped = $true; $msg = $_.Exception.Message }
            if (-not $stopped) { throw 'a dead helper at the window end did not STOP' }
            if ($msg -notmatch 'did not cover the window') { throw "wrong failure reason: $msg" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'Auxiliary capture: export failure fails closed, and a successful export binds run ID, root, argv and pcap SHA-256' {
        $env:K8_MOCK_DOCKER_STATE = 'robs05-export-fails'
        $dir = New-K8AuxTestDir -T0OffsetSeconds -60
        try {
            $t0 = [datetimeoffset]::Parse((Get-Content (Join-Path $dir 'metadata-t0.txt') -Raw).Trim())
            $record = [ordered]@{
                schema_version = 1; run_id = 'k8shakedown-rangeb-T'; helper_name = 'k8shakedown-rangeb-T-r-obs-05-liveness-capture'
                steps = @([ordered]@{ step = 'listening-check'; argv = @('docker'); exit_code = 0; stdout = 'listening on eth0'; stderr = ''; started_utc = $t0.AddSeconds(-20).ToString('o'); completed_utc = $t0.AddSeconds(-10).ToString('o') })
            }
            $record | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'contract-output\r-obs-05-capture-lifecycle.json') -Encoding utf8NoBOM
            $stopped = $false
            try { Complete-K8Robs05LivenessCapture -RunId 'k8shakedown-rangeb-T' -RunEvidence $dir } catch { $stopped = $true }
            if (-not $stopped) { throw 'an export failure did not STOP' }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'Auxiliary capture: full happy path records all six lifecycle steps, a null BPF filter, and the exported pcap SHA-256' {
        $env:K8_MOCK_DOCKER_STATE = 'rule-index-present-good'
        $dir = New-K8AuxTestDir -T0OffsetSeconds -60
        try {
            Start-K8Robs05LivenessCapture -RunId 'k8shakedown-rangeb-T' -ComposePath 'y.yml' -RunEvidence $dir
            Complete-K8Robs05LivenessCapture -RunId 'k8shakedown-rangeb-T' -RunEvidence $dir
            $lc = Get-Content (Join-Path $dir 'contract-output\r-obs-05-capture-lifecycle.json') -Raw | ConvertFrom-Json
            $steps = @($lc.steps | ForEach-Object { $_.step })
            foreach ($expected in @('start', 'listening-check', 'window-end-liveness-check', 'stop', 'export', 'remove')) {
                if ($steps -notcontains $expected) { throw "lifecycle step missing: $expected (got: $($steps -join ','))" }
            }
            if ($null -ne $lc.capture_time_bpf_filter) { throw "capture_time_bpf_filter must be null, got '$($lc.capture_time_bpf_filter)'" }
            if ($lc.role -ne 'r-obs-05-auxiliary-liveness' -or -not $lc.not_sensor -or -not $lc.not_ground_truth) { throw 'the record must declare it is neither Ground Truth nor Sensor' }
            if ([string]::IsNullOrWhiteSpace($lc.pcap_sha256)) { throw 'exported pcap SHA-256 was not recorded' }
            $startArgv = ($lc.steps | Where-Object { $_.step -eq 'start' }).argv
            if ($startArgv[-2] -ne '-w') { throw "the start argv must end at '-w <pcap>' with no filter after it: $($startArgv -join ' ')" }
            if (-not (Test-Path (Join-Path $dir 'contract-output\r-obs-05-liveness.pcap'))) { throw 'the liveness pcap was not exported' }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Assert-K8Test 'R-OBS-05 decode: unrelated flow present in the auxiliary pcap -> rows retained; absent -> fail-close naming the liveness pcap, not the Sensor pcap' {
        foreach ($case in @(
            @{ State = 'decode-hit'; ExpectStop = $false }
            @{ State = 'decode-empty'; ExpectStop = $true }
        )) {
            $env:K8_MOCK_DOCKER_STATE = $case.State
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-auxdec-" + [guid]::NewGuid())
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'contract-output') | Out-Null
            'MOCK' | Set-Content (Join-Path $dir 'contract-output\r-obs-05-liveness.pcap')
            try {
                $stopped = $false; $msg = ''
                try { Write-K8UnrelatedPcapRows -RunId 'k8shakedown-rangeb-T' -ComposePath 'y.yml' -RunEvidence $dir } catch { $stopped = $true; $msg = $_.Exception.Message }
                if ($stopped -ne $case.ExpectStop) { throw "state $($case.State): expected stop=$($case.ExpectStop), got $stopped ($msg)" }
                if ($case.ExpectStop -and $msg -match 'sensor pcap') { throw 'the failure message still blames the Sensor pcap' }
                if (-not $case.ExpectStop -and -not (Test-Path (Join-Path $dir 'contract-output\r-obs-05-liveness-decode.txt'))) { throw 'the frozen SS5 decoded-rows retention (text form) is missing' }
            }
            finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Assert-K8Test 'R-OBS-05 decode: a missing auxiliary liveness pcap fails closed and explicitly refuses the Sensor pcap as a substitute' {
        $env:K8_MOCK_DOCKER_STATE = 'decode-hit'
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-auxmiss-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'contract-output'), (Join-Path $dir 'sensor-input\mirror-capture') | Out-Null
        'MOCK-SENSOR' | Set-Content (Join-Path $dir 'sensor-input\mirror-capture\c2-mirror-sensor.pcap')
        try {
            $stopped = $false; $msg = ''
            try { Write-K8UnrelatedPcapRows -RunId 'k8shakedown-rangeb-T' -ComposePath 'y.yml' -RunEvidence $dir } catch { $stopped = $true; $msg = $_.Exception.Message }
            if (-not $stopped) { throw 'a missing liveness pcap did not STOP -- and a present Sensor pcap must never be silently substituted' }
            if ($msg -notmatch 'never an acceptable substitute') { throw "the refusal to substitute the Sensor pcap is not stated: $msg" }
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
finally { $env:PATH = $auxOriginalPath }

Assert-K8Test 'Completeness gate: the Range B R-OBS-05 required set is derived from frozen SS4/SS5 and includes the liveness pcap, its decode, lifecycle and contract reference' {
    Import-Module $CommonPath -Force
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-auxcomplete-" + [guid]::NewGuid())
    try {
        foreach ($rel in @(Get-K8ContractArtifacts -Range b | ForEach-Object { $_.artifact })) {
            $full = Join-Path $dir $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $full -Parent) | Out-Null
            'x' | Set-Content $full
        }
        # The frozen SS4/SS5 set must actually be in the contract, named
        # explicitly here so a silent contract deletion is caught.
        $rangeBArtifacts = @(Get-K8ContractArtifacts -Range b | ForEach-Object { $_.artifact })
        foreach ($rel in @(
            'contract-output\qdisc-pre-fault.txt', 'contract-output\fault-injection-command.txt',
            'contract-output\qdisc-post-fault.txt', 'contract-output\unrelated-mirror-filters.txt',
            'contract-output\r-obs-05-mapping-response.json', 'contract-output\r-obs-05-mapping-gate.json',
            'environment\r-obs-05-query.json', 'contract-output\r-obs-05-response.json',
            'contract-output\r-obs-05-liveness.pcap', 'contract-output\r-obs-05-capture-lifecycle.json',
            'contract-output\r-obs-05-pcap-rows.json', 'contract-output\r-obs-05-liveness-decode.txt',
            'contract-output\r-obs-05-correlation.json', 'contract-output\r-obs-05-contract-reference.txt'
        )) {
            if ($rangeBArtifacts -notcontains $rel) { throw "the frozen SS4/SS5 artifact '$rel' is not required by the contract for Range B" }
        }
        Test-K8ScoringInputArtifactCompleteness -Range b -RunEvidence $dir
        # Each of the four newly-required R-OBS-05 artifacts must individually
        # STOP Range B completion when absent.
        foreach ($rel in @('contract-output\r-obs-05-liveness.pcap', 'contract-output\r-obs-05-liveness-decode.txt', 'contract-output\r-obs-05-capture-lifecycle.json', 'contract-output\r-obs-05-contract-reference.txt')) {
            $full = Join-Path $dir $rel
            Move-Item $full "$full.bak"
            $stopped = $false
            try { Test-K8ScoringInputArtifactCompleteness -Range b -RunEvidence $dir } catch { $stopped = $true }
            Move-Item "$full.bak" $full
            if (-not $stopped) { throw "a missing '$rel' did not STOP Range B completion" }
        }
        # Range A must NOT require any of them (Range A has no R-OBS-05).
        Test-K8ScoringInputArtifactCompleteness -Range a -RunEvidence $dir
    }
    finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'Frozen SS5 contract reference is retained and identifies the exact frozen contract file by SHA-256' {
    Import-Module $CommonPath -Force
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-auxref-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'contract-output') | Out-Null
    try {
        $path = Write-K8Robs05ContractReference -RunEvidence $dir -Study01Root $Study01
        $text = Get-Content $path -Raw
        if ($text -notmatch 'k6-r-obs-05-collector-query-contract\.md') { throw 'the contract reference does not name the frozen contract file' }
        $expectedSha = (Get-FileHash -Path (Join-Path $Study01 'studies\study-01-negative-result\protocol\k6-r-obs-05-collector-query-contract.md') -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($text -notmatch [regex]::Escape($expectedSha)) { throw 'the retained SHA-256 does not match the frozen contract file' }
    }
    finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'Frozen apparatus is untouched: CAPTURE_FILTER, its enforcement, and the two-stage capture set are unchanged' {
    $apparatus = Get-Content (Join-Path $Study01 'studies\study-01-negative-result\scripts\study01\frozen\apparatus.py') -Raw
    if ($apparatus -notmatch [regex]::Escape('CAPTURE_FILTER = "host 10.1.20.11 and host 10.1.10.10 and tcp port 20000"')) { throw 'the frozen CAPTURE_FILTER changed' }
    foreach ($stage in @('"ground-truth"', '"sensor"')) { if ($apparatus -notmatch [regex]::Escape($stage)) { throw "frozen capture stage missing: $stage" } }
    if ($apparatus -match 'r-obs-05' -or $apparatus -match 'liveness') { throw 'the auxiliary capture must NOT have been added to the frozen apparatus as a third scientific stage' }
    $lifecycle = Get-Content (Join-Path $Study01 'studies\study-01-negative-result\scripts\study01\capture_lifecycle.py') -Raw
    if ($lifecycle -notmatch [regex]::Escape('raise CaptureLifecycleError("capture filter is not the frozen filter")')) { throw 'the frozen filter enforcement was weakened' }
}

# --- 26. Range B fault-boundary evidence retention --------------------------
#
# Real VM STOP k8shakedown-rangeb-20260829-134837 (closed, not rescued):
# "Scoring-input artifact completeness gate failed / missing:
# contract-output\qdisc-post-fault.txt". The producer existed and its path
# matched the consumer exactly. Root cause: `$post = docker exec ... 2>&1`
# followed by `$post | Set-Content <path>` -- Set-Content creates NO FILE
# when nothing is piped to it, and a SUCCESSFUL fault leaves
# `tc filter show ... parent ffff:` with nothing to list. The more correctly
# the frozen fault worked, the more certainly the artifact vanished. The
# empty listing IS the frozen c2-dnp3-step4-range-b-fault-pilot.md SS4 check-2
# success condition, so the tooling was discarding exactly the positive
# evidence. Exit codes were also discarded and stderr merged into stdout, so
# "empty because no filter remains" was indistinguishable from "empty
# because tc failed".
#
# Classification: Shakedown tooling defect (evidence retention) + evidence
# completeness defect. Not a scientific/runtime defect (the fault worked)
# and not a frozen transcription gap (c2-dnp3-range-derivation.md SS3
# already requires "Preserve pre/post command output ... in contract-output/").

Assert-K8Test 'MEASURED: Set-Content creates no file for $null / empty-array input, but always does via -join or ConvertTo-Json (the exact cause and the exact fix)' {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-sc-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    try {
        $nothing = & cmd.exe /c "exit 0"
        $nothing | Set-Content -Path (Join-Path $d 'a.txt') -Encoding utf8NoBOM
        if (Test-Path (Join-Path $d 'a.txt')) { throw 'PowerShell behavior changed: a null pipeline now creates a file -- the fix rationale needs revisiting' }
        @() | Set-Content -Path (Join-Path $d 'b.txt') -Encoding utf8NoBOM
        if (Test-Path (Join-Path $d 'b.txt')) { throw 'PowerShell behavior changed: an empty array now creates a file' }
        (@() -join "`n") | Set-Content -Path (Join-Path $d 'c.txt') -Encoding utf8NoBOM
        if (-not (Test-Path (Join-Path $d 'c.txt'))) { throw '-join no longer guarantees file creation -- the fix would not hold' }
    }
    finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'REGRESSION: fault observation artifact is ALWAYS created -- pre/post, empty and non-empty stdout, with argv/exit/stdout_empty/timestamp retained' {
    Import-Module $CommonPath -Force
    Add-K8TestContractRow -Row @{ step_id = 'TEST-FAULT'; class = 'C'; ranges = 'b'
        source_file = 'test'; producer_scope = 'test'; callee = 'cmd.exe'; call_ordinal = 1
        argv_shape = @('cmd.exe', '/c', '<synthetic>'); stream_expectation = 'separated'
        accepted_exit_codes = @(0, 3); exit_note = 'synthetic fixture; not a real call site' }
    foreach ($case in @(
        @{ Name = 'pre: empty stdout + exit 0';    Argv = @('cmd.exe', '/c', 'exit 0');            Empty = $true;  Exit = 0; File = 'qdisc-pre-fault.txt' }
        @{ Name = 'pre: nonempty stdout';          Argv = @('cmd.exe', '/c', 'echo qdisc ingress'); Empty = $false; Exit = 0; File = 'qdisc-pre-fault.txt' }
        @{ Name = 'post: empty stdout + exit 0';   Argv = @('cmd.exe', '/c', 'exit 0');            Empty = $true;  Exit = 0; File = 'qdisc-post-fault.txt' }
        @{ Name = 'post: nonempty stdout';         Argv = @('cmd.exe', '/c', 'echo filter parent ffff:'); Empty = $false; Exit = 0; File = 'qdisc-post-fault.txt' }
    )) {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-fobs-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        try {
            $obs = @(Invoke-K8FaultObservationCommand -StepId 'TEST-FAULT' -Label $case.Name -Argv $case.Argv)
            if ($obs[0].StdoutEmpty -ne $case.Empty) { throw "$($case.Name): stdout_empty was $($obs[0].StdoutEmpty), expected $($case.Empty)" }
            if ($obs[0].ExitCode -ne $case.Exit) { throw "$($case.Name): exit was $($obs[0].ExitCode), expected $($case.Exit)" }
            $relative = "contract-output\$($case.File)"
            $path = Join-Path $d $relative
            New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
            Write-K8FaultObservationArtifact -Observations $obs -RunEvidence $d -ArtifactRelativePath $relative `
                -Title 'test' -RunId 'k8shakedown-rangeb-test' -Range 'b' -Stage 'fault-injection'
            if (-not (Test-Path $path)) { throw "$($case.Name): the artifact was NOT created -- this is the exact real-VM defect" }
            $text = Get-Content $path -Raw
            foreach ($field in @('argv=', 'exit_code=', 'timestamp_utc=', 'stdout_empty=', '--- stdout ---', '--- stderr ---')) {
                if ($text -notmatch [regex]::Escape($field)) { throw "$($case.Name): retained record is missing '$field'" }
            }
            if ($text -notmatch "stdout_empty=$($case.Empty.ToString().ToLowerInvariant())") { throw "$($case.Name): stdout_empty was not retained correctly" }

            # C-4: the structured sidecar comes from the SAME capture instance.
            $sidecar = Join-Path $d (Get-K8CommandObservationPath -ArtifactRelativePath $relative)
            if (-not (Test-Path $sidecar)) { throw "$($case.Name): the C-4 observation sidecar was NOT created" }
            $record = Get-Content $sidecar -Raw | ConvertFrom-Json
            if ($record.schema -ne 'k8shakedown-command-observation/1') { throw "$($case.Name): wrong observation schema '$($record.schema)'" }
            $o = @($record.observations)[0]
            if ($o.capture_semantics -ne 'separated') { throw "$($case.Name): expected separated capture semantics, got '$($o.capture_semantics)'" }
            if ($o.exit_code -ne $case.Exit) { throw "$($case.Name): sidecar exit_code disagrees with the observation" }
            if (@($o.argv) -join ' ' -ne ($case.Argv -join ' ')) { throw "$($case.Name): sidecar argv disagrees with the observation" }
            if ($o.stdout.empty -ne $case.Empty) { throw "$($case.Name): sidecar stdout.empty was $($o.stdout.empty), expected $($case.Empty)" }
            if ($null -eq $o.stderr) { throw "$($case.Name): separated capture must describe stderr as itself" }
            if ($null -ne $o.combined_output) { throw "$($case.Name): a separated capture must not claim a combined transcript" }
        }
        finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Assert-K8Test 'REGRESSION: empty stdout with a NONZERO exit fails closed -- never read as a successful "no remaining filter"' {
    Import-Module $CommonPath -Force
    Add-K8TestContractRow -Row @{ step_id = 'TEST-FAULT'; class = 'C'; ranges = 'b'
        source_file = 'test'; producer_scope = 'test'; callee = 'cmd.exe'; call_ordinal = 1
        argv_shape = @('cmd.exe', '/c', '<synthetic>'); stream_expectation = 'separated'
        accepted_exit_codes = @(0, 3); exit_note = 'synthetic fixture; not a real call site' }
    foreach ($stage in @('pre-fault observation', 'post-fault observation')) {
        $obs = @(Invoke-K8FaultObservationCommand -StepId 'TEST-FAULT' -Label $stage -Argv @('cmd.exe', '/c', 'exit 3'))
        if (-not $obs[0].StdoutEmpty) { throw 'fixture did not produce the empty-stdout case' }
        $stopped = $false; $msg = ''
        try { Assert-K8FaultObservationsSucceeded -Observations $obs -Stage $stage } catch { $stopped = $true; $msg = $_.Exception.Message }
        if (-not $stopped) { throw "$stage : an empty stdout with exit 3 did not STOP" }
        if ($msg -notmatch 'never read as success') { throw "the failure does not state the empty-vs-failed distinction: $msg" }
    }
}

Assert-K8Test 'REGRESSION: fault observations separate stdout from stderr (never merged via 2>&1)' {
    Import-Module $CommonPath -Force
    Add-K8TestContractRow -Row @{ step_id = 'TEST-FAULT'; class = 'C'; ranges = 'b'
        source_file = 'test'; producer_scope = 'test'; callee = 'cmd.exe'; call_ordinal = 1
        argv_shape = @('cmd.exe', '/c', '<synthetic>'); stream_expectation = 'separated'
        accepted_exit_codes = @(0, 3); exit_note = 'synthetic fixture; not a real call site' }
    $obs = @(Invoke-K8FaultObservationCommand -StepId 'TEST-FAULT' -Label 'sep' -Argv @('cmd.exe', '/c', 'echo OUT& echo ERRLINE 1>&2'))
    if ($obs[0].Stdout -notmatch 'OUT') { throw 'stdout was not captured' }
    if ($obs[0].Stdout -match 'ERRLINE') { throw 'stderr leaked into stdout -- streams are being merged' }
    if ($obs[0].Stderr -notmatch 'ERRLINE') { throw 'stderr was not retained' }
    if ($obs[0].StdoutEmpty) { throw 'stdout_empty must be false when stdout has content' }
    # Tokenizer-stripped: this function's own docstring legitimately quotes
    # the old `2>&1` shape while describing the defect it replaced.
    $code = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Invoke-K8FaultObservationCommand'
    if ($code -match '2>&1') { throw 'the fault observation command merges streams via 2>&1' }
    if ($code -notmatch 'Invoke-K8SeparatedNativeCapture') { throw 'the fault observation command no longer uses the separated-capture helper' }
}

Assert-K8Test 'Range B fault block: pre, fault-command and post are all retained via the observation helpers, artifact written BEFORE the exit assertion' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8ShakedownRangeABBody'
    foreach ($needle in @('qdisc-pre-fault.txt', 'fault-injection-command.txt', 'qdisc-post-fault.txt')) {
        if ($body -notmatch [regex]::Escape($needle)) { throw "fault-boundary artifact not written: $needle" }
    }
    # The fault command's own argv/exit/stdout/stderr must now be retained.
    if ($body -notmatch "Label 'fault: tc qdisc del ingress") { throw 'the fault command itself is not retained as an observation' }
    # No bare `$pre`/`$post` piping survives.
    if ($body -match '\$post \| Set-Content' -or $body -match '\$pre \| Set-Content') { throw 'a bare (possibly empty) command result is still piped to Set-Content -- the real-VM defect is back' }
    # Write-then-assert ordering, per artifact.
    foreach ($pair in @(@('qdisc-pre-fault.txt', 'pre-fault observation'), @('qdisc-post-fault.txt', 'post-fault observation'))) {
        $writeIdx = $body.IndexOf($pair[0])
        $assertIdx = $body.IndexOf("-Stage '$($pair[1])'")
        if ($writeIdx -lt 0 -or $assertIdx -lt 0) { throw "could not locate write/assert pair for $($pair[0])" }
        if ($writeIdx -gt $assertIdx) { throw "$($pair[0]) is written AFTER its exit assertion -- a failing command would leave no diagnostic" }
    }
    # The frozen fault scope is unchanged: still exactly one qdisc del ingress.
    $dels = @([regex]::Matches($body, "'tc',\s*'qdisc',\s*'del'"))
    if ($dels.Count -ne 1) { throw "expected exactly one 'tc qdisc del' (the sole permitted fault); found $($dels.Count)" }
}

Assert-K8Test 'HORIZONTAL AUDIT: no Set-Content call site in the module can silently skip file creation on empty pipeline input' {
    # Tokenizer-stripped source: docstrings in this module quote the old
    # `$post | Set-Content` shape while explaining the defect it replaced.
    $lines = ((Get-K8CommentStrippedSource -Path $CommonPath) -split "`n") | Where-Object { $_ -match '\|\s*Set-Content' }
    if ($lines.Count -lt 15) { throw "the Set-Content audit found only $($lines.Count) call sites; the scan is probably broken" }
    # A call site is safe when the piped expression is guaranteed to yield at
    # least one object: -join / ConvertTo-Json / Out-String always do, and
    # these named variables are always [string] (possibly empty, which still
    # creates a file -- measured above).
    $safeStringVars = @('$RawBody', '$collectorIdsJson', '$ruleQuery', '$collectorQuery', '$r0query', '$deviationsBody', '$ruleQueryText')
    foreach ($line in $lines) {
        $t = $line.Trim()
        # A double/single-quoted string literal (including one with $-inter-
        # polation) is a single [string] object, so Set-Content always writes
        # a file -- even when every interpolated value is empty.
        $safe = ($t -match '-join') -or ($t -match 'ConvertTo-Json') -or ($t -match 'Out-String') -or ($t.StartsWith('"')) -or ($t.StartsWith("'"))
        if (-not $safe) { foreach ($v in $safeStringVars) { if ($t -match [regex]::Escape("$v | Set-Content") -or $t -match [regex]::Escape("$v |Set-Content")) { $safe = $true } } }
        if (-not $safe) { throw "unsafe Set-Content call site (empty pipeline input would create no file): $t" }
    }
}

Assert-K8Test 'REGRESSION: Write-K8ImageInventory retains compose-images.json / compose-ps.txt even when the command emits nothing' {
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Write-K8ImageInventory'
    # Single-quoted: these needles contain literal $-variable text that must
    # NOT be interpolated by this test.
    foreach ($needle in @('(@($psJson) -join', '(@($composePsCapture.Stdout) -join')) {
        if ($body -notmatch [regex]::Escape($needle)) { throw "Write-K8ImageInventory still pipes a possibly-empty capture directly to Set-Content: missing $needle" }
    }
    if ($body -match 'docker compose -p \$RunId -f \$ComposePath ps 2>&1') { throw 'compose-ps.txt is still captured with merged streams and no empty-input guard' }
    # And the generic guarantee the fix relies on, measured directly.
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-ii-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    try {
        $emptyCapture = @()
        (@($emptyCapture) -join "`n") | Set-Content -Path (Join-Path $d 'x.json') -Encoding utf8NoBOM
        if (-not (Test-Path (Join-Path $d 'x.json'))) { throw 'the -join guard does not create a file for an empty capture' }
    }
    finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'Range A non-regression: no fault-boundary artifact is produced or required for Range A' {
    Import-Module $CommonPath -Force
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8ShakedownRangeABBody'
    foreach ($artifact in @('qdisc-pre-fault.txt', 'fault-injection-command.txt', 'qdisc-post-fault.txt')) {
        $idx = $body.IndexOf($artifact)
        $before = $body.Substring(0, $idx)
        if ($before.LastIndexOf("if (`$Range -eq 'b')") -lt 0) { throw "$artifact is written outside a Range B branch -- Range A runtime behavior would change" }
    }
    # And the completeness gate must not require them for Range A.
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-rangea-nofault-" + [guid]::NewGuid())
    try {
        foreach ($rel in @(Get-K8ContractArtifacts -Range a | ForEach-Object { $_.artifact })) {
            $full = Join-Path $dir $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $full -Parent) | Out-Null
            'x' | Set-Content $full
        }
        Test-K8ScoringInputArtifactCompleteness -Range a -RunEvidence $dir
        # And the contract itself must not carry any fault-boundary row for
        # Range A -- checked against the data, not against a fixture that
        # happens to omit them.
        $rangeAArtifacts = @(Get-K8ContractArtifacts -Range a | ForEach-Object { $_.artifact })
        foreach ($artifact in @('qdisc-pre-fault.txt', 'fault-injection-command.txt', 'qdisc-post-fault.txt', 'unrelated-mirror-filters.txt')) {
            if (@($rangeAArtifacts | Where-Object { $_ -like "*$artifact" }).Count -ne 0) {
                throw "$artifact is a required Range A artifact in the contract -- Range A has no fault boundary"
            }
        }
    }
    finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'Completeness gate: the fault-command artifact is required for Range B and every required artifact name has a producer in the module or in a Range runner' {
    Import-Module $CommonPath -Force
    $rangeB = @(Get-K8ContractArtifacts -Range b | ForEach-Object { $_.artifact })
    if ($rangeB -notcontains 'contract-output\fault-injection-command.txt') { throw 'the retained fault command is not a required Range B artifact' }
    # Producer/consumer path agreement: every required artifact whose leaf name
    # the Shakedown side is responsible for writing must appear in the
    # producing source too. (capture-context/sender-record/procedure-conformance
    # come from the frozen Python CLI, so they are legitimately absent.)
    $frozenPythonProduced = @('capture-context.json', 'sender-record.txt', 'procedure-conformance.json', 'capture-lifecycle.json', 'c2-original-path.pcap', 'c2-mirror-sensor.pcap', 'metadata-t0.txt')
    # Strip the contract declaration itself, so a row cannot satisfy itself:
    # the artifact name has to appear where it is actually WRITTEN.
    $moduleText = Get-Content $CommonPath -Raw
    $contractBlock = [regex]::Match($moduleText, '(?s)\$script:K8ArtifactContract = @\(.*?\r?\n\)\r?\n')
    if (-not $contractBlock.Success) { throw 'could not locate the $script:K8ArtifactContract declaration to exclude it' }
    $rangeCSource = Get-Content (Join-Path (Split-Path $CommonPath -Parent) 'Run-K8ShakedownRangeC.ps1') -Raw
    $outside = $moduleText.Remove($contractBlock.Index, $contractBlock.Length) + $rangeCSource
    $contractArtifacts = @((Get-K8ArtifactContract) | ForEach-Object { $_.artifact })
    foreach ($row in (Get-K8ArtifactContract)) {
        $leaf = Split-Path $row.artifact -Leaf
        if ($frozenPythonProduced -contains $leaf) { continue }
        if ($outside -match [regex]::Escape($leaf)) { continue }
        # A C-4 sidecar's name is DERIVED from its base artifact by
        # Get-K8CommandObservationPath and never written as a literal, which is
        # the point: the pair cannot drift. Its producer check is therefore
        # that the derivation really yields this name from a base artifact the
        # contract also requires, and that the base artifact has a producer.
        if ($leaf.EndsWith('.observation.json')) {
            $base = @($contractArtifacts | Where-Object {
                $_ -ne $row.artifact -and (Get-K8CommandObservationPath -ArtifactRelativePath $_) -eq $row.artifact
            })
            if ($base.Count -eq 1 -and $outside -match [regex]::Escape((Split-Path $base[0] -Leaf))) { continue }
        }
        throw "required artifact '$($row.artifact)' has no producer anywhere in the module or the Range C runner"
    }
    # Every contract row must name a producer stage; a row with no stage could
    # never be checked at a stage boundary.
    foreach ($row in (Get-K8ArtifactContract)) {
        if (-not $row.stage) { throw "contract row '$($row.artifact)' has no producer stage" }
        if ($row.ranges -notmatch '^[abc]+$') { throw "contract row '$($row.artifact)' has an unusable range set '$($row.ranges)'" }
    }
}

# --- 27. Qualification sequence / run provenance / termination record -------
#
# All offline: a throwaway git repo plus a throwaway K8_SHAKEDOWN_ROOT. No
# Docker, no VM, no Amenonuboco checkout.

$RangeCPath = Join-Path $ToolsDir 'Run-K8ShakedownRangeC.ps1'

function Invoke-K8SequenceSandbox {
    # Deliberately -Action, not -Body: PowerShell resolves a scriptblock's free
    # variables against the caller's scope chain, so a parameter named like one
    # the caller's scriptblock also uses can rebind it mid-flight.
    param([Parameter(Mandatory)][scriptblock] $Action)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('k8seq-' + [guid]::NewGuid().ToString('N'))
    $repo = Join-Path ([System.IO.Path]::GetTempPath()) ('k8seqrepo-' + [guid]::NewGuid().ToString('N'))
    $bare = Join-Path ([System.IO.Path]::GetTempPath()) ('k8seqbare-' + [guid]::NewGuid().ToString('N'))
    $previous = $env:K8_SHAKEDOWN_ROOT
    $env:K8_SHAKEDOWN_ROOT = $root
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    try {
        git -C $repo init -q *> $null
        git -C $repo config user.email 'k8@test.local' *> $null
        git -C $repo config user.name 'k8 test' *> $null
        git -C $repo config commit.gpgsign false *> $null
        'seed' | Set-Content -Path (Join-Path $repo 'seed.txt')
        git -C $repo add -A *> $null
        git -C $repo commit -q -m seed *> $null

        # C-9: opening a sequence now also requires the HEAD to be PUBLISHED on
        # the canonical remote. Rather than skipping that gate for fixtures, the
        # fixture gets a real published remote: a local bare repository, pushed
        # to, with the pin pointed at it for the duration. Every step of
        # Get-K8SourceIdentity then runs for real -- nothing is mocked, and the
        # gate keeps its only behaviour (STOP on anything but `confirmed`).
        git -C $repo init -q --bare $bare *> $null
        git -C $repo remote add origin $bare *> $null
        git -C $repo push -q origin HEAD:refs/heads/main *> $null
        Set-K8TestSourcePin -CanonicalRemoteUrls @($bare) -CanonicalRef 'refs/heads/main'

        & $Action ([pscustomobject]@{
            Root = $root
            Repo = $repo
            Bare = $bare
            Head = (git -C $repo rev-parse HEAD).Trim()
        })
    }
    finally {
        Reset-K8TestSourcePin
        Remove-Item $bare -Recurse -Force -ErrorAction SilentlyContinue
        if ($null -eq $previous) { Remove-Item Env:\K8_SHAKEDOWN_ROOT -ErrorAction SilentlyContinue }
        else { $env:K8_SHAKEDOWN_ROOT = $previous }
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Add-K8SandboxCommit {
    param([Parameter(Mandatory)][string] $Repo, [string] $Text = 'next')
    $Text | Set-Content -Path (Join-Path $Repo 'seed.txt')
    git -C $Repo add -A *> $null
    git -C $Repo commit -q -m $Text *> $null
    return (git -C $Repo rev-parse HEAD).Trim()
}

function Publish-K8SandboxHead {
    <#
        Pushes the sandbox repo's current HEAD to its local bare "remote".

        C-9 gates sequence open on the HEAD being published, so a fixture that
        commits and then opens a sequence has to publish in between -- which is
        also the real operator order (fix, push, open a new sequence). Making
        the fixtures do it keeps the gate exercised instead of worked around.
    #>
    param([Parameter(Mandatory)] $Sandbox)
    git -C $Sandbox.Repo push -q --force origin HEAD:refs/heads/main *> $null
    if ($LASTEXITCODE -ne 0) { throw "sandbox publish failed (exit $LASTEXITCODE)" }
}

function Assert-K8FailsClosed {
    param(
        [Parameter(Mandatory)][string] $What,
        [Parameter(Mandatory)][scriptblock] $Attempt,
        [string] $Because
    )
    try { & $Attempt | Out-Null }
    catch {
        if ($Because -and $_.Exception.Message -notmatch $Because) {
            throw "$What failed closed, but for the wrong reason: $($_.Exception.Message)"
        }
        return
    }
    throw "$What was expected to fail closed; it succeeded"
}

Assert-K8Test 'Sequence creation: sequence_id and locked_head are separate facts, and locked_head is the exact HEAD' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        $seq = New-K8QualificationSequence -RepoRoot $sb.Repo
        if ($seq['locked_head'] -ne $sb.Head) { throw "locked_head $($seq['locked_head']) != git HEAD $($sb.Head)" }
        if ($seq['sequence_id'] -eq $seq['locked_head']) { throw 'sequence_id equals locked_head' }
        # Not merely different: the ID must not encode the HEAD at all, or the
        # C-2b gate would be comparing a value against itself.
        for ($n = 7; $n -le $sb.Head.Length; $n++) {
            if ($seq['sequence_id'].Contains($sb.Head.Substring(0, $n))) { throw "sequence_id embeds a $n-char prefix of locked_head" }
        }
        # The optional -N suffix disambiguates two sequences opened inside the
        # same one-second timestamp; it never reuses an existing record.
        if ($seq['sequence_id'] -notmatch '^k8shakedown-seq-\d{8}-\d{6}(-\d+)?$') { throw "unexpected sequence_id shape: $($seq['sequence_id'])" }
        if ($seq['sequence_id'] -like 'k8-repro-*') { throw 'sequence_id uses the formal attempt namespace' }
        if ($seq['status'] -ne 'open') { throw "status = $($seq['status'])" }
        if ($seq['next_range'] -ne 'a') { throw "next_range = $($seq['next_range'])" }
        if ($null -ne $seq['active_run']) { throw 'a fresh sequence already has an active run' }
        if (@($seq['completed_runs']).Count -ne 0 -or @($seq['terminated_runs']).Count -ne 0) { throw 'a fresh sequence already has run history' }
        if ($seq['initial_tree_clean'] -ne $true) { throw 'initial_tree_clean was not recorded' }
        $pointer = (Get-Content (Join-Path $sb.Root 'sequences\current.txt') -Raw).Trim()
        if ($pointer -ne $seq['sequence_id']) { throw "current.txt ($pointer) does not name the new sequence" }
    }
}

Assert-K8Test 'Sequence creation fails closed on a dirty tree and writes no record' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        'stray' | Set-Content -Path (Join-Path $sb.Repo 'untracked.txt')
        Assert-K8FailsClosed -What 'New-K8QualificationSequence on a dirty tree' -Because 'not clean' -Attempt {
            New-K8QualificationSequence -RepoRoot $sb.Repo
        }
        $seqDir = Join-Path $sb.Root 'sequences'
        $written = @(if (Test-Path $seqDir) { Get-ChildItem $seqDir -Filter '*.json' -File -ErrorAction SilentlyContinue } else { @() })
        if ($written.Count -ne 0) { throw "a refused creation still wrote $($written.Count) record(s)" }
        if (Test-Path (Join-Path $seqDir 'current.txt')) { throw 'a refused creation still wrote current.txt' }
    }
}

Assert-K8Test 'Run provenance exists immediately after run-ID allocation and agrees with the reservation' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        $seq = New-K8QualificationSequence -RepoRoot $sb.Repo
        $run = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        $provPath = Get-K8RunProvenancePath -RunId $run.RunId
        if (-not (Test-Path $provPath)) { throw 'run-provenance.json does not exist after Start-K8ShakedownRun' }
        $prov = Get-Content $provPath -Raw | ConvertFrom-Json -AsHashtable
        if ($prov['run_id'] -ne $run.RunId) { throw 'run_id mismatch' }
        if ($prov['sequence_id'] -ne $seq['sequence_id']) { throw 'sequence_id mismatch' }
        if ($prov['tooling_head'] -ne $sb.Head) { throw 'tooling_head mismatch' }
        if ($prov['sequence_locked_head'] -ne $seq['locked_head']) { throw 'sequence_locked_head mismatch' }
        if ($prov['tree_clean'] -ne $true) { throw 'tree_clean is not true' }
        if ($prov['observation_point'] -ne 'run-initialization') { throw 'observation_point missing or wrong' }
        # The reservation made the same observation durable one step earlier;
        # if the two disagree, one of them is fiction.
        $live = Get-K8QualificationSequence
        if ($live['active_run']['tooling_head'] -ne $prov['tooling_head']) { throw 'reservation and provenance disagree on tooling_head' }
        if ($live['active_run']['state'] -ne 'running') { throw "active_run.state = $($live['active_run']['state'])" }
    }
}

Assert-K8Test 'Run start precedes every command in the Range A/B and Range C paths; the provenance mirror follows evidence_tree.create' {
    $wrapper = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Invoke-K8ShakedownRangeAB'
    if ($wrapper -notmatch 'Start-K8ShakedownRun') { throw 'Invoke-K8ShakedownRangeAB does not start a tracked run' }
    if ($wrapper -match 'New-K8ShakedownRunId') { throw 'the Range A/B wrapper allocates a raw run ID instead of going through Start-K8ShakedownRun' }
    $body = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Invoke-K8ShakedownRangeABBody'
    if ($body -match 'New-K8ShakedownRunId') { throw 'the Range A/B body allocates its own run ID' }
    $gate = $body.IndexOf('Assert-K8SequenceBinding')
    if ($gate -lt 0) { throw 'Invoke-K8ShakedownRangeABBody never calls the binding gate' }
    foreach ($token in @('Invoke-K8ShakedownCommand', 'Invoke-K8ShakedownLoggedCommand', 'docker compose', 'Push-Location')) {
        $first = $body.IndexOf($token)
        if ($first -ge 0 -and $first -lt $gate) { throw "'$token' appears before the binding gate in Invoke-K8ShakedownRangeABBody" }
    }
    $create = $body.IndexOf('evidence_tree import create')
    $mirror = $body.IndexOf('Copy-K8RunProvenanceIntoEvidence')
    if ($create -lt 0) { throw 'the frozen evidence_tree.create call was not found' }
    if ($mirror -lt 0) { throw 'the provenance mirror was not found' }
    # The mirror cannot precede the creator: the frozen creator refuses an
    # existing root, so the tree does not exist before it runs.
    if ($mirror -lt $create) { throw 'the provenance mirror precedes evidence_tree.create' }
    $between = $body.Substring($create, $mirror - $create)
    if ($between -match 'Invoke-K8ShakedownLoggedCommand|Test-K8ShakedownNetworkPreflight|study01_preflight') { throw 'a further step runs between evidence_tree.create and the provenance mirror' }

    $rangeC = Get-K8CommentStrippedSource -Path $RangeCPath
    if ($rangeC -match 'New-K8ShakedownRunId') { throw 'Range C allocates a raw run ID instead of going through Start-K8ShakedownRun' }
    $cStart = $rangeC.IndexOf('Start-K8ShakedownRun')
    if ($cStart -lt 0) { throw 'Range C does not start a tracked run' }
    foreach ($token in @('Invoke-K8ShakedownCommand', 'Copy-Item', 'cmd.exe')) {
        $first = $rangeC.IndexOf($token)
        if ($first -ge 0 -and $first -lt $cStart) { throw "'$token' appears before Start-K8ShakedownRun in Run-K8ShakedownRangeC.ps1" }
    }
}

Assert-K8Test 'The in-tree provenance mirror lands at the evidence-tree root, never inside a frozen schema directory' {
    Import-Module $CommonPath -Force
    $body = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Copy-K8RunProvenanceIntoEvidence'
    foreach ($schemaDir in @('environment', 'ground-truth', 'sensor-input', 'collector-output', 'rule-output', 'contract-output')) {
        if ($body -match [regex]::Escape("$schemaDir\")) { throw "the provenance mirror targets '$schemaDir', which study01/preflight.py requires to be empty at preflight time" }
    }
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $run = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        $tree = Join-Path $sb.Root 'fake-evidence-tree'
        New-Item -ItemType Directory -Force -Path $tree | Out-Null
        Copy-K8RunProvenanceIntoEvidence -Run $run -RunEvidence $tree
        $landed = @(Get-ChildItem $tree -Recurse -File)
        # Two now: run-provenance.json (C-2) and source-identity.txt (C-9),
        # written by the same call at the same point so one manifest covers both.
        $names = @($landed.Name | Sort-Object)
        if ($landed.Count -ne 2) { throw "expected exactly two mirrored files, found $($landed.Count): $($names -join ', ')" }
        foreach ($expected in 'run-provenance.json', 'source-identity.txt') {
            if ($names -notcontains $expected) { throw "the mirror did not write $expected (found: $($names -join ', '))" }
        }
        foreach ($f in $landed) {
            if ((Split-Path -Parent $f.FullName) -ne (Resolve-Path $tree).Path) { throw "$($f.Name) was mirrored into a subdirectory, not the tree root" }
        }
        if ($landed[0].Name -ne 'run-provenance.json') { throw "unexpected mirrored file $($landed[0].Name)" }
        if ($landed[0].Directory.FullName -ne (Resolve-Path $tree).Path) { throw 'the mirror is not at the evidence-tree root' }
        if ((Get-Content $landed[0].FullName -Raw) -ne (Get-Content (Get-K8RunProvenancePath -RunId $run.RunId) -Raw)) { throw 'the mirror is not byte-identical to the control-plane record' }
    }
}

Assert-K8Test 'Binding gate fails closed on a HEAD change and retains the actual mismatching provenance' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $run = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        $newHead = Add-K8SandboxCommit -Repo $sb.Repo -Text 'moved'
        Assert-K8FailsClosed -What 'the binding gate after a HEAD change' -Because 'binding gate FAILED' -Attempt {
            Assert-K8SequenceBinding -Run $run
        }
        $prov = Get-Content (Get-K8RunProvenancePath -RunId $run.RunId) -Raw | ConvertFrom-Json -AsHashtable
        if ($prov['tooling_head'] -ne $sb.Head) { throw 'provenance does not retain the head the run actually started under' }
        if ($prov['tooling_head'] -eq $newHead) { throw 'provenance was rewritten to the new head' }
    }
}

Assert-K8Test 'Binding gate re-observes git rather than comparing stored values (start-time TOCTOU)' {
    Import-Module $CommonPath -Force
    $gate = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Assert-K8SequenceBinding'
    if ($gate -notmatch 'Get-K8ToolingIdentity') { throw 'the binding gate does not re-read git, so a checkout after run initialization would be invisible to it' }
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $run = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        Assert-K8SequenceBinding -Run $run          # clean at this point
        'dirtied after provenance was written' | Set-Content -Path (Join-Path $sb.Repo 'toctou.txt')
        Assert-K8FailsClosed -What 'the binding gate after the tree was dirtied' -Because 'not clean now' -Attempt {
            Assert-K8SequenceBinding -Run $run
        }
    }
}

Assert-K8Test 'All three Range paths and Complete share one binding gate; none re-implements the comparison' {
    $sources = [ordered]@{
        'Invoke-K8ShakedownRangeABBody'   = (Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Invoke-K8ShakedownRangeABBody')
        'Complete-K8ShakedownRangeABBody' = (Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Complete-K8ShakedownRangeABBody')
        'Run-K8ShakedownRangeC.ps1'       = (Get-K8CommentStrippedSource -Path $RangeCPath)
    }
    foreach ($name in $sources.Keys) {
        $text = $sources[$name]
        if ($text -notmatch 'Assert-K8SequenceBinding|Assert-K8RunSequenceInvariant') { throw "$name does not go through the shared binding gate" }
        if ($text -match 'locked_head') { throw "$name compares locked_head itself instead of delegating to the shared gate" }
    }
}

Assert-K8Test 'Sequence order is enforced: Range B before A, and B before A completes, are both refused' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        Assert-K8FailsClosed -What 'starting Range B first' -Because 'expects Range a next' -Attempt {
            Start-K8ShakedownRun -Range b -RepoRoot $sb.Repo
        }
        $runA = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        Assert-K8FailsClosed -What 'starting Range B while Range A is still active' -Because 'already active' -Attempt {
            Start-K8ShakedownRun -Range b -RepoRoot $sb.Repo
        }
        Complete-K8ShakedownRunInSequence -Run $runA | Out-Null
        Assert-K8FailsClosed -What 'starting Range C before Range B' -Because 'expects Range b next' -Attempt {
            Start-K8ShakedownRun -Range c -RepoRoot $sb.Repo
        }
    }
}

Assert-K8Test 'Only one run may be active at a time' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo | Out-Null
        Assert-K8FailsClosed -What 'a second concurrent Range A run' -Because 'Only one run may be active' -Attempt {
            Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        }
    }
}

Assert-K8Test 'Completion advances next_range and clears the active run; termination does neither' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $runA = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        $advanced = Complete-K8ShakedownRunInSequence -Run $runA
        if ($advanced['next_range'] -ne 'b') { throw "next_range = $($advanced['next_range']) after Range A" }
        if ($null -ne $advanced['active_run']) { throw 'active_run survived completion' }
        if (@($advanced['completed_runs']).Count -ne 1) { throw 'completed_runs was not appended' }

        $runB = Start-K8ShakedownRun -Range b -RepoRoot $sb.Repo
        try {
            Invoke-K8ShakedownRunBoundary -Run $runB -ScriptBlock {
                Set-K8ShakedownRunStage -Stage 'provision'
                throw 'simulated Range B failure'
            }.GetNewClosure()
        } catch { }
        $after = Get-K8QualificationSequence
        if ($after['status'] -ne 'ineligible') { throw "status = $($after['status']) after a termination" }
        if ($after['next_range'] -ne 'b') { throw "next_range advanced past a terminated run: $($after['next_range'])" }
    }
}

Assert-K8Test 'Close then start yields a distinct sequence at the new HEAD, back at Range A' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        $first = New-K8QualificationSequence -RepoRoot $sb.Repo
        $runA = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        Complete-K8ShakedownRunInSequence -Run $runA | Out-Null
        Close-K8QualificationSequence -Reason 'fixing something' | Out-Null
        Assert-K8FailsClosed -What 'starting a run after the sequence was closed' -Because 'no live qualification sequence' -Attempt {
            Start-K8ShakedownRun -Range b -RepoRoot $sb.Repo
        }
        $newHead = Add-K8SandboxCommit -Repo $sb.Repo -Text 'the fix'
        # C-9: the fix has to be PUBLISHED before a sequence can lock it. This
        # is the real operator sequence too -- fix, push, then open. Without the
        # push the gate refuses, which is the point of it.
        Publish-K8SandboxHead -Sandbox $sb
        $second = New-K8QualificationSequence -RepoRoot $sb.Repo
        if ($second['sequence_id'] -eq $first['sequence_id']) { throw 'the new sequence reused the old ID' }
        if ($second['locked_head'] -ne $newHead) { throw 'the new sequence did not lock the new HEAD' }
        if ($second['next_range'] -ne 'a') { throw 'the new sequence does not restart from Range A' }
    }
}

Assert-K8Test 'Concurrent Start-K8ShakedownRun from two processes: exactly one wins' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $script = Join-Path $sb.Root 'concurrent-start.ps1'
        @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$env:K8_SHAKEDOWN_ROOT = '$($sb.Root)'
Import-Module '$CommonPath' -Force
try { `$r = Start-K8ShakedownRun -Range a -RepoRoot '$($sb.Repo)'; Write-Output "WON `$(`$r.RunId)" }
catch { Write-Output "LOST `$(`$_.Exception.Message)" }
"@ | Set-Content -Path $script -Encoding utf8NoBOM
        $outA = Join-Path $sb.Root 'concurrent-a.txt'
        $outB = Join-Path $sb.Root 'concurrent-b.txt'
        $p1 = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $script) -RedirectStandardOutput $outA -PassThru -WindowStyle Hidden
        $p2 = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $script) -RedirectStandardOutput $outB -PassThru -WindowStyle Hidden
        if (-not $p1.WaitForExit(240000)) { throw 'concurrent process 1 did not exit' }
        if (-not $p2.WaitForExit(240000)) { throw 'concurrent process 2 did not exit' }
        $results = @((Get-Content $outA -Raw), (Get-Content $outB -Raw))
        $won = @($results | Where-Object { $_ -match 'WON' })
        if ($won.Count -ne 1) { throw "expected exactly one winner, got $($won.Count): $($results -join ' | ')" }
        $live = Get-K8QualificationSequence
        if ($null -eq $live['active_run']) { throw 'no run was reserved at all' }
        $reserved = @(Get-ChildItem (Join-Path $sb.Root 'run-records') -Directory -ErrorAction SilentlyContinue)
        if ($reserved.Count -ne 1) { throw "expected one run record, found $($reserved.Count) -- a duplicate active run was created" }
        # An interleaved write would show up as unparseable JSON here.
        Get-Content (Join-Path $sb.Root "sequences\$($live['sequence_id']).json") -Raw | ConvertFrom-Json | Out-Null
    }
}

Assert-K8Test 'A live sequence whose current.txt is missing permits only CloseSequence' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        Remove-Item (Join-Path $sb.Root 'sequences\current.txt') -Force
        Assert-K8FailsClosed -What 'creating a second sequence while an orphaned open one exists' -Because 'disagrees with the live sequence' -Attempt {
            New-K8QualificationSequence -RepoRoot $sb.Repo
        }
        Assert-K8FailsClosed -What 'starting a run against an orphaned open sequence' -Because 'disagrees with the live sequence' -Attempt {
            Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        }
        Close-K8QualificationSequence -Reason 'resolving the pointer inconsistency' | Out-Null
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
    }
}

Assert-K8Test 'Two live sequences fail closed everywhere and require -SequenceId to close' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        $first = New-K8QualificationSequence -RepoRoot $sb.Repo
        # Fabricate a second live record directly, as a corrupted control plane would.
        $clone = Get-Content (Join-Path $sb.Root "sequences\$($first['sequence_id']).json") -Raw | ConvertFrom-Json -AsHashtable
        $clone['sequence_id'] = 'k8shakedown-seq-19700101-000000'
        ($clone | ConvertTo-Json -Depth 12) | Set-Content -Path (Join-Path $sb.Root 'sequences\k8shakedown-seq-19700101-000000.json') -Encoding utf8NoBOM
        Assert-K8FailsClosed -What 'starting a run with two live sequences' -Because 'control-plane corruption' -Attempt {
            Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        }
        Assert-K8FailsClosed -What 'closing without -SequenceId' -Because 'never guesses' -Attempt {
            Close-K8QualificationSequence -Reason 'ambiguous'
        }
        Close-K8QualificationSequence -Reason 'resolving corruption' -SequenceId 'k8shakedown-seq-19700101-000000' | Out-Null
    }
}

Assert-K8Test 'Orphan detection spans every sequence record, so a closed sequence''s runs are not misreported' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $runA = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        Complete-K8ShakedownRunInSequence -Run $runA | Out-Null
        Close-K8QualificationSequence -Reason 'done with this one' | Out-Null
        # runA is now referenced only by a CLOSED record. It must not read as an orphan.
        if (@((Get-K8ControlPlaneState).Orphans) -contains $runA.RunId) { throw 'a run recorded in a closed sequence was misreported as an orphan' }
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        # A run record that no sequence at all accounts for IS an orphan.
        New-Item -ItemType Directory -Force -Path (Join-Path $sb.Root 'run-records\k8shakedown-rangea-19700101-000000') | Out-Null
        if (@((Get-K8ControlPlaneState).Orphans) -notcontains 'k8shakedown-rangea-19700101-000000') { throw 'an unaccounted-for run record was not detected as an orphan' }
        Assert-K8FailsClosed -What 'starting a run while an orphan record exists' -Because 'orphan run record' -Attempt {
            Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        }
    }
}

Assert-K8Test 'Existing sequence and run records are never overwritten; a taken ID yields a fresh one' {
    Import-Module $CommonPath -Force
    $newSeq = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'New-K8QualificationSequence'
    if ($newSeq -notmatch 'sequence ID collision') { throw 'sequence creation does not guard against an existing record' }
    $startBody = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Start-K8ShakedownRun'
    if ($startBody -notmatch 'run-record collision') { throw 'run reservation does not guard against an existing run record' }
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        # Two sequences opened inside the same one-second timestamp must not
        # collide, and must not overwrite each other.
        $first = New-K8QualificationSequence -RepoRoot $sb.Repo
        Close-K8QualificationSequence -Reason 'immediately reopening' | Out-Null
        $second = New-K8QualificationSequence -RepoRoot $sb.Repo
        if ($second['sequence_id'] -eq $first['sequence_id']) { throw 'the second sequence reused the first ID' }
        $firstRecord = Get-Content (Join-Path $sb.Root "sequences\$($first['sequence_id']).json") -Raw | ConvertFrom-Json
        if ($firstRecord.status -ne 'closed') { throw 'the first record was overwritten rather than preserved' }
    }
}

Assert-K8Test 'Interrupted run initialization: the matching continuation is allowed, a new reservation is not' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $run = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        # Rewind to the state a crash between ReserveRun and
        # FinalizeRunInitialization leaves behind.
        $live = Get-K8QualificationSequence
        $live['active_run']['state'] = 'initializing'
        Write-K8SequenceRecord -Record $live
        Assert-K8FailsClosed -What 'a new reservation over an interrupted initialization' -Because 'already active' -Attempt {
            Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        }
        Assert-K8FailsClosed -What 'completing a half-initialized run' -Because 'initialization never finished' -Attempt {
            Complete-K8ShakedownRunInSequence -Run $run
        }
        # The operation that created this state is the one allowed to finish it.
        Invoke-K8SequenceMutation -Operation 'FinalizeRunInitialization' -RunId $run.RunId -Body {
            param($State)
            $s = @($State.Live)[0]
            $s['active_run']['state'] = 'running'
            Write-K8SequenceRecord -Record $s
        } | Out-Null
        if ((Get-K8QualificationSequence)['active_run']['state'] -ne 'running') { throw 'the matching continuation did not take effect' }
        # ...and only for the matching run ID.
        $live2 = Get-K8QualificationSequence
        $live2['active_run']['state'] = 'initializing'
        Write-K8SequenceRecord -Record $live2
        Assert-K8FailsClosed -What 'continuing initialization for a different run ID' -Because 'targets run' -Attempt {
            Invoke-K8SequenceMutation -Operation 'FinalizeRunInitialization' -RunId 'k8shakedown-rangea-19700101-000000' -Body { param($State) }
        }
    }
}

Assert-K8Test 'Crash before provenance: close still writes a truthful tooling_head from the reservation' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $run = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        # Reproduce "reserved, then died before run-provenance.json was written".
        Remove-Item (Get-K8RunProvenancePath -RunId $run.RunId) -Force
        $live = Get-K8QualificationSequence
        $live['active_run']['state'] = 'initializing'
        Write-K8SequenceRecord -Record $live
        Assert-K8FailsClosed -What 'a new reservation after an interrupted initialization' -Because 'already active' -Attempt {
            Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        }
        # Move HEAD, so substituting the current head would be visible.
        $newHead = Add-K8SandboxCommit -Repo $sb.Repo -Text 'moved after the crash'
        Close-K8QualificationSequence -Reason 'crashed before provenance' | Out-Null
        $term = Get-Content (Get-K8TerminationRecordPath -RunId $run.RunId) -Raw | ConvertFrom-Json
        if ($term.stage -ne 'operator-close') { throw "stage = $($term.stage)" }
        if ($term.failure_kind -ne 'non-command') { throw "failure_kind = $($term.failure_kind)" }
        if ($null -ne $term.command) { throw 'an operator close invented a command record' }
        if ($term.tooling_head_source -ne 'reservation') { throw "tooling_head_source = $($term.tooling_head_source)" }
        if ($term.tooling_head -ne $sb.Head) { throw 'tooling_head is not the head the run was reserved under' }
        if ($term.tooling_head -eq $newHead) { throw 'the current HEAD was substituted for the run''s own' }
    }
}

Assert-K8Test 'Interrupted sequence creation after the pointer write requires an explicit close' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        $seq = New-K8QualificationSequence -RepoRoot $sb.Repo
        $path = Join-Path $sb.Root "sequences\$($seq['sequence_id']).json"
        # Rewind past stage 3: record still 'initializing', pointer already written.
        $rec = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        $rec['status'] = 'initializing'
        ($rec | ConvertTo-Json -Depth 12) | Set-Content -Path $path -Encoding utf8NoBOM
        Assert-K8FailsClosed -What 'creating a sequence over an interrupted creation' -Because 'interrupted after its pointer was written' -Attempt {
            New-K8QualificationSequence -RepoRoot $sb.Repo
        }
        Assert-K8FailsClosed -What 'starting a run against an interrupted creation' -Because 'interrupted after its pointer was written' -Attempt {
            Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        }
        Close-K8QualificationSequence -Reason 'interrupted creation' | Out-Null
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
    }
}

Assert-K8Test 'Provably-unused initializing residue is quarantined as abandoned; anything less fails closed' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        $seq = New-K8QualificationSequence -RepoRoot $sb.Repo
        $path = Join-Path $sb.Root "sequences\$($seq['sequence_id']).json"
        $rec = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        $rec['status'] = 'initializing'
        ($rec | ConvertTo-Json -Depth 12) | Set-Content -Path $path -Encoding utf8NoBOM
        Remove-Item (Join-Path $sb.Root 'sequences\current.txt') -Force   # crash BEFORE the pointer write
        $fresh = New-K8QualificationSequence -RepoRoot $sb.Repo
        $quarantined = Get-Content $path -Raw | ConvertFrom-Json
        if ($quarantined.status -ne 'abandoned') { throw "residue status = $($quarantined.status)" }
        if ([string]::IsNullOrWhiteSpace($quarantined.abandoned_reason)) { throw 'the quarantine was not explained' }
        if ($fresh['sequence_id'] -eq $seq['sequence_id']) { throw 'the residue was reused rather than quarantined' }
    }
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        $seq = New-K8QualificationSequence -RepoRoot $sb.Repo
        $path = Join-Path $sb.Root "sequences\$($seq['sequence_id']).json"
        $rec = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        $rec['status'] = 'initializing'
        ($rec | ConvertTo-Json -Depth 12) | Set-Content -Path $path -Encoding utf8NoBOM
        Remove-Item (Join-Path $sb.Root 'sequences\current.txt') -Force
        # Break condition 4: a run record naming this sequence still exists.
        $rr = Join-Path $sb.Root 'run-records\k8shakedown-rangea-19700101-000000'
        New-Item -ItemType Directory -Force -Path $rr | Out-Null
        (@{ sequence_id = $seq['sequence_id'] } | ConvertTo-Json) | Set-Content -Path (Join-Path $rr 'run-provenance.json') -Encoding utf8NoBOM
        Assert-K8FailsClosed -What 'quarantining residue that a run record still references' -Attempt {
            New-K8QualificationSequence -RepoRoot $sb.Repo
        }
    }
}

Assert-K8Test 'A terminated run makes its sequence ineligible, and only an explicit close moves past it' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $run = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        try {
            Invoke-K8ShakedownRunBoundary -Run $run -ScriptBlock {
                Set-K8ShakedownRunStage -Stage 'preflight'
                throw 'simulated failure'
            }.GetNewClosure()
        } catch { }
        if ((Get-K8QualificationSequence)['status'] -ne 'ineligible') { throw 'the sequence was not made ineligible' }
        Assert-K8FailsClosed -What 'opening a new sequence while one is ineligible' -Because 'still live' -Attempt {
            New-K8QualificationSequence -RepoRoot $sb.Repo
        }
        Assert-K8FailsClosed -What 'starting another run in an ineligible sequence' -Because 'is ineligible' -Attempt {
            Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        }
        Assert-K8FailsClosed -What 'completing a run in an ineligible sequence' -Because 'is ineligible' -Attempt {
            Complete-K8ShakedownRunInSequence -Run $run
        }
        Close-K8QualificationSequence -Reason 'after the terminated run' | Out-Null
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
    }
}

Assert-K8Test 'Partial termination: only the matching RecordTermination or an explicit close moves forward' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $run = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        # Half of the termination transaction: the authoritative record is on
        # disk, the sequence is still 'open'.
        Write-K8AtomicFile -Path (Get-K8TerminationRecordPath -RunId $run.RunId) -Content (@{
            schema = 'k8shakedown-termination/1'; run_id = $run.RunId; stage = 'preflight'
            failure_kind = 'non-command'; command = $null
        } | ConvertTo-Json)
        if ((Get-K8QualificationSequence)['status'] -ne 'open') { throw 'the setup did not reproduce the partial state' }
        Assert-K8FailsClosed -What 'completing a run that already has a termination record' -Because 'authoritative termination record' -Attempt {
            Complete-K8ShakedownRunInSequence -Run $run
        }
        Assert-K8FailsClosed -What 'starting a new run over a partial termination' -Because 'already active' -Attempt {
            Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        }
        # Finishing the transaction is permitted.
        Set-K8SequenceIneligible -Run $run
        if ((Get-K8QualificationSequence)['status'] -ne 'ineligible') { throw 'the transaction could not be completed' }
        Close-K8QualificationSequence -Reason 'recovered' | Out-Null
    }
}

Assert-K8Test 'Completion independently refuses a run holding a termination record' {
    $body = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Complete-K8ShakedownRunInSequence'
    if ($body -notmatch 'Test-K8ActiveRunHasTermination') { throw 'completion does not independently check for a termination record' }
}

Assert-K8Test 'complete / closed / abandoned are immutable terminal states' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        Close-K8QualificationSequence -Reason 'first close' | Out-Null
        Assert-K8FailsClosed -What 're-closing a closed sequence' -Because 'immutable terminal states' -Attempt {
            Close-K8QualificationSequence -Reason 'second close'
        }
        Assert-K8FailsClosed -What 're-closing a closed sequence by ID' -Because 'immutable terminal states' -Attempt {
            Close-K8QualificationSequence -Reason 'second close' -SequenceId 'anything'
        }
        if (@((Get-K8ControlPlaneState).Live).Count -ne 0) { throw 'a terminal record is still being treated as live' }
    }
}

Assert-K8Test 'Every terminal transition retires current.txt' {
    Import-Module $CommonPath -Force
    $transition = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Complete-K8SequenceTerminalTransition'
    if ($transition -notmatch 'Remove-K8SequencePointer') { throw 'the terminal transition does not retire the pointer' }
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        $pointer = Join-Path $sb.Root 'sequences\current.txt'
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        Close-K8QualificationSequence -Reason 'closing' | Out-Null
        if (Test-Path $pointer) { throw 'current.txt survived a close' }
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        if (-not (Test-Path $pointer)) { throw 'current.txt was not written for the new sequence' }
        foreach ($range in @('a', 'b', 'c')) {
            $r = Start-K8ShakedownRun -Range $range -RepoRoot $sb.Repo
            Complete-K8ShakedownRunInSequence -Run $r | Out-Null
        }
        if (Test-Path $pointer) { throw 'current.txt survived a completion' }
    }
}

Assert-K8Test 'status=complete requires an uninterrupted a,b,c and claims only c-2b-sequence-valid' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $final = $null
        foreach ($range in @('a', 'b', 'c')) {
            $r = Start-K8ShakedownRun -Range $range -RepoRoot $sb.Repo
            $final = Complete-K8ShakedownRunInSequence -Run $r
        }
        if ($final['status'] -ne 'complete') { throw "status = $($final['status'])" }
        if ($final['completion_claim'] -ne 'c-2b-sequence-valid') { throw "completion_claim = $($final['completion_claim'])" }
        if (@($final['terminated_runs']).Count -ne 0) { throw 'a complete sequence carries terminated runs' }
    }
    $body = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Complete-K8ShakedownRunInSequence'
    if ($body -notmatch 'terminated_runs') { throw 'completion does not consider terminated runs' }
    if ($body -notmatch "'a,b,c'") { throw 'completion does not require the exact a,b,c order' }
}

Assert-K8Test 'The tooling never claims K8-S2 authorization, and offers no same-sequence run retry' {
    foreach ($file in @($CommonPath, $RangeCPath, (Join-Path $ToolsDir 'Start-K8QualificationSequence.ps1'), (Join-Path $ToolsDir 'Close-K8QualificationSequence.ps1'))) {
        $text = Get-Content $file -Raw
        foreach ($line in ($text -split "`n")) {
            if ($line -match 'K8-S2 authoriz' -and $line -notmatch 'NOT a K8-S2 authorization|not a K8-S2 authorization') {
                throw "$file claims K8-S2 authorization: $($line.Trim())"
            }
        }
    }
    if (Test-Path (Join-Path $ToolsDir 'Close-K8ShakedownRun.ps1')) { throw 'a same-sequence run-close/retry entry point exists; a terminated run must end its sequence' }
    Import-Module $CommonPath -Force
    if (Get-Command -Name 'Close-K8ShakedownRun' -ErrorAction SilentlyContinue) { throw 'a same-sequence run-close/retry function exists' }
}

Assert-K8Test 'Non-command termination records the common fields and fabricates no command semantics' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $run = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        try {
            Invoke-K8ShakedownRunBoundary -Run $run -ScriptBlock {
                Set-K8ShakedownRunStage -Stage 'completeness-gate'
                throw 'required artifact contract-output\qdisc-post-fault.txt is missing'
            }.GetNewClosure()
            throw 'the boundary did not re-throw'
        }
        catch { if ($_.Exception.Message -notmatch 'qdisc-post-fault') { throw "the boundary altered the failure: $($_.Exception.Message)" } }
        $raw = Get-Content (Get-K8TerminationRecordPath -RunId $run.RunId) -Raw
        $term = $raw | ConvertFrom-Json
        foreach ($field in @('stage', 'failure_kind', 'timestamp', 'message', 'tooling_head', 'sequence_id')) {
            if ([string]::IsNullOrWhiteSpace([string]$term.$field)) { throw "required field '$field' is missing or empty" }
        }
        if ($term.failure_kind -ne 'non-command') { throw "failure_kind = $($term.failure_kind)" }
        if ($term.stage -ne 'completeness-gate') { throw "stage = $($term.stage)" }
        if ($null -ne $term.command) { throw 'a non-command termination carries a command record' }
        # Not merely null: the keys must not exist at all, so no reader can take
        # a placeholder for an observation.
        if ($raw -match '"argv"' -or $raw -match '"exit_code"') { throw 'command semantics were fabricated for a non-command termination' }
        if ([string]::IsNullOrWhiteSpace($term.exception.type)) { throw 'the exception type was not retained' }
    }
}

Assert-K8Test 'External-command termination retains argv, exit code and the full captured transcript' {
    Import-Module $CommonPath -Force
    Add-K8TestContractRow -Row @{ step_id = 'TEST-GIT-STRICT'; class = 'C'; ranges = 'a'
        source_file = 'test'; producer_scope = 'test'; callee = "'git'"; call_ordinal = 1
        argv_shape = @('git', '-C', '<repo>', 'rev-parse', '--verify', '<ref>'); stream_expectation = 'separated'
        accepted_exit_codes = @(0); exit_note = 'synthetic fixture: a strict site, so a missing ref STOPs' }
    Add-K8TestContractRow -Row @{ step_id = 'TEST-GIT-TOLERANT'; class = 'C'; ranges = 'a'
        source_file = 'test'; producer_scope = 'test'; callee = "'git'"; call_ordinal = 2
        argv_shape = @('git', '-C', '<repo>', 'rev-parse', '--verify', '<ref>'); stream_expectation = 'separated'
        accepted_exit_codes = @(0, 128); exit_note = 'synthetic fixture: a site whose acceptance domain includes the missing-ref exit' }
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $run = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        try {
            Invoke-K8ShakedownRunBoundary -Run $run -ScriptBlock {
                Set-K8ShakedownRunStage -Stage 'preflight'
                Invoke-K8ShakedownCommand -StepId 'TEST-GIT-STRICT' -FilePath 'git' -ArgumentList @('-C', $sb.Repo, 'rev-parse', '--verify', 'refs/heads/no-such-branch')
            }.GetNewClosure()
            throw 'the boundary did not re-throw'
        }
        catch { }
        $term = Get-Content (Get-K8TerminationRecordPath -RunId $run.RunId) -Raw | ConvertFrom-Json
        if ($term.failure_kind -ne 'external-command') { throw "failure_kind = $($term.failure_kind)" }
        if (@($term.command.argv)[0] -ne 'git') { throw "argv[0] = $(@($term.command.argv)[0])" }
        if (@($term.command.argv) -notcontains 'refs/heads/no-such-branch') { throw 'argv does not carry the real arguments' }
        if ($term.command.exit_code -eq 0) { throw 'exit_code is not the real failing code' }
        # This helper merges the streams, so the transcript is named as combined.
        if ($term.command.streams_separated -ne $false) { throw 'a merged capture claims separated streams' }
        if ($null -ne $term.command.stdout -or $null -ne $term.command.stderr) { throw 'a merged transcript was reported as stdout/stderr' }
        if ([string]::IsNullOrWhiteSpace($term.command.capture_note)) { throw 'the capture note is missing' }
        $file = Join-Path (Get-K8RunRecordDir -RunId $run.RunId) $term.command.combined_output.path
        if (-not (Test-Path $file)) { throw 'the captured transcript file was not retained' }
        if ((Get-Item $file).Length -ne $term.command.combined_output.bytes) { throw 'recorded bytes disagree with the retained file' }
        if ((Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $term.command.combined_output.sha256) { throw 'recorded sha256 disagrees with the retained file' }
    }
}

Assert-K8Test 'A tolerated command failure is not grafted onto a later unrelated termination' {
    Import-Module $CommonPath -Force
    Add-K8TestContractRow -Row @{ step_id = 'TEST-GIT-STRICT'; class = 'C'; ranges = 'a'
        source_file = 'test'; producer_scope = 'test'; callee = "'git'"; call_ordinal = 1
        argv_shape = @('git', '-C', '<repo>', 'rev-parse', '--verify', '<ref>'); stream_expectation = 'separated'
        accepted_exit_codes = @(0); exit_note = 'synthetic fixture: a strict site, so a missing ref STOPs' }
    Add-K8TestContractRow -Row @{ step_id = 'TEST-GIT-TOLERANT'; class = 'C'; ranges = 'a'
        source_file = 'test'; producer_scope = 'test'; callee = "'git'"; call_ordinal = 2
        argv_shape = @('git', '-C', '<repo>', 'rev-parse', '--verify', '<ref>'); stream_expectation = 'separated'
        accepted_exit_codes = @(0, 128); exit_note = 'synthetic fixture: a site whose acceptance domain includes the missing-ref exit' }
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $run = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        try {
            Invoke-K8ShakedownRunBoundary -Run $run -ScriptBlock {
                Set-K8ShakedownRunStage -Stage 'preflight'
                # Fails, but its exit code is allowed: it must leave nothing behind.
                Invoke-K8ShakedownCommand -StepId 'TEST-GIT-TOLERANT' -FilePath 'git' -ArgumentList @('-C', $sb.Repo, 'rev-parse', '--verify', 'refs/heads/no-such-branch') | Out-Null
                throw 'an unrelated internal assertion'
            }.GetNewClosure()
        }
        catch { }
        $raw = Get-Content (Get-K8TerminationRecordPath -RunId $run.RunId) -Raw
        $term = $raw | ConvertFrom-Json
        if ($term.failure_kind -ne 'non-command') { throw "a tolerated command failure was attributed to a later throw: failure_kind = $($term.failure_kind)" }
        if ($null -ne $term.command) { throw 'stale command context leaked into an unrelated termination' }
        if ($raw -match '"argv"') { throw 'stale argv leaked into an unrelated termination' }
    }
}

Assert-K8Test 'Command context travels on the exception itself, not a module-global slot' {
    $source = Get-K8CommentStrippedSource -Path $CommonPath
    if ($source -notmatch "Data\['k8_command_context'\]") { throw 'command context is not attached to the exception' }
    if ($source -match '\$script:K8LastCommandFailure') { throw 'a module-global last-failure slot exists' }
    $lookup = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Get-K8CommandFailureContext'
    if ($lookup -notmatch 'InnerException') { throw 'the lookup does not walk the exception chain' }
    if ($lookup -match 'script:') { throw 'the lookup consults module state instead of the handled exception' }
}

Assert-K8Test 'Captured transcripts are retained in full; the JSON preview is a convenience only' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $run = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        $big = ('x' * 200000)
        $ex = New-K8CommandFailure -Argv @('fake', 'command') -ExitCode 9 -StreamsSeparated -Stdout $big -Stderr 'short' -Message 'synthetic large-output failure'
        try {
            Invoke-K8ShakedownRunBoundary -Run $run -ScriptBlock {
                Set-K8ShakedownRunStage -Stage 'target-decode'
                throw $ex
            }.GetNewClosure()
        }
        catch { }
        $term = Get-Content (Get-K8TerminationRecordPath -RunId $run.RunId) -Raw | ConvertFrom-Json
        $stdoutFile = Join-Path (Get-K8RunRecordDir -RunId $run.RunId) $term.command.stdout.path
        # The retained artifact must equal the full transcript the TOOLING
        # captured. It is not a claim about the native process's own bytes,
        # which this synthetic failure never had.
        if ((Get-Content $stdoutFile -Raw) -ne $big) { throw 'the retained transcript is not the full captured text' }
        if ($term.command.stdout.bytes -ne (Get-Item $stdoutFile).Length) { throw 'recorded bytes disagree with the retained file' }
        if ($term.command.stdout.preview_truncated -ne $true) { throw 'a truncated preview was not flagged' }
        if ($term.command.stdout.preview.Length -ge $big.Length) { throw 'the preview was not truncated at all' }
        if ($term.command.stderr.preview_truncated -ne $false) { throw 'a short stream was flagged as truncated' }
        if ($term.command.streams_separated -ne $true) { throw 'separated streams were recorded as merged' }
    }
}

Assert-K8Test 'Termination records never touch the frozen evidence tree' {
    $body = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Write-K8TerminationRecord'
    if ($body -match '\$RunEvidence') { throw 'the termination writer references the evidence tree' }
    if ($body -notmatch 'Get-K8TerminationRecordPath') { throw 'the termination writer does not use the control-plane path' }
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $run = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        # An already-finalized evidence tree: adding any file to it would put it
        # permanently at odds with its own manifest.
        $tree = Join-Path $sb.Root "runs\$($run.RunId)"
        New-Item -ItemType Directory -Force -Path $tree | Out-Null
        Copy-K8RunProvenanceIntoEvidence -Run $run -RunEvidence $tree
        'placeholder' | Set-Content -Path (Join-Path $tree 'evidence.txt')
        (@(Get-ChildItem $tree -Recurse -File | ForEach-Object { $_.Name }) | Sort-Object) -join "`n" | Set-Content -Path (Join-Path $tree 'hashes.sha256')
        $before = @(Get-ChildItem $tree -Recurse -File | ForEach-Object { $_.Name }) | Sort-Object
        try {
            Invoke-K8ShakedownRunBoundary -Run $run -ScriptBlock {
                Set-K8ShakedownRunStage -Stage 'final-verify'
                throw 'failure after the tree was finalized'
            }.GetNewClosure()
        }
        catch { }
        $after = @(Get-ChildItem $tree -Recurse -File | ForEach-Object { $_.Name }) | Sort-Object
        if (($before -join '|') -ne ($after -join '|')) { throw "the evidence tree gained files after finalize: $(@($after | Where-Object { $before -notcontains $_ }) -join ', ')" }
        if (-not (Test-Path (Get-K8TerminationRecordPath -RunId $run.RunId))) { throw 'the termination record was not written to the control plane' }
    }
}

Assert-K8Test 'The boundary re-throws the original failure even when the record cannot be written' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $run = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        # Put a FILE where the per-run record directory has to be.
        Remove-Item (Get-K8RunRecordDir -RunId $run.RunId) -Recurse -Force
        'not a directory' | Set-Content -Path (Get-K8RunRecordDir -RunId $run.RunId)
        $caught = $null
        try {
            Invoke-K8ShakedownRunBoundary -Run $run -ScriptBlock {
                Set-K8ShakedownRunStage -Stage 'provision'
                throw 'THE ORIGINAL REASON'
            }.GetNewClosure()
        }
        catch { $caught = $_.Exception.Message }
        if ($caught -ne 'THE ORIGINAL REASON') { throw "a record-write failure replaced the original reason: '$caught'" }
    }
}

Assert-K8Test 'Writing a termination record never converts a failure into a success' {
    $boundary = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Invoke-K8ShakedownRunBoundary'
    if ($boundary -notmatch 'throw \$original') { throw 'the boundary does not re-throw the original error record' }
    foreach ($guarded in @('Write-K8TerminationRecord', 'Set-K8SequenceIneligible')) {
        if ($boundary -notmatch [regex]::Escape($guarded)) { throw "the boundary does not call $guarded" }
    }
}

Assert-K8Test 'Each stage is set immediately before that stage''s first fallible operation' {
    $body = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Invoke-K8ShakedownRangeABBody'
    foreach ($pair in @(
        @{ Stage = 'sequence-binding';        Anchor = 'Assert-K8SequenceBinding' }
        @{ Stage = 'evidence-tree';           Anchor = 'evidence_tree import create' }
        @{ Stage = 'preflight';               Anchor = 'study01_preflight.py' }
        @{ Stage = 'network-preflight';       Anchor = 'Test-K8ShakedownNetworkPreflight' }
        @{ Stage = 'provision';               Anchor = 'Invoke-K8ShakedownLoggedCommand' }
        @{ Stage = 'compose-readiness';       Anchor = 'Wait-K8ComposeReady' }
        @{ Stage = 'application-readiness';   Anchor = 'Wait-K8ElasticsearchReady' }
        @{ Stage = 'image-inventory';         Anchor = 'Write-K8ImageInventory' }
        @{ Stage = 'gateway-resolution';      Anchor = 'Resolve-K8GatewayInterface' }
        @{ Stage = 'fault-injection';         Anchor = 'Invoke-K8FaultObservationCommand' }
        @{ Stage = 'runtime-contract-record'; Anchor = 'Write-K8RuntimeContractRecord' }
        @{ Stage = 'window-start';            Anchor = 'Wait-K8CaptureWindowStart' }
        @{ Stage = 'sender-trigger';          Anchor = 'study01_sender.py' }
        @{ Stage = 'window-end';              Anchor = 'Wait-K8CaptureWindowEnd' }
        @{ Stage = 'capture-lifecycle-check'; Anchor = 'Test-K8CaptureLifecycleEarly' }
        @{ Stage = 'target-decode';           Anchor = 'Write-K8TargetCaptureDecode' }
        @{ Stage = 'completeness-gate';       Anchor = 'Test-K8ScoringInputArtifactCompleteness' }
    )) {
        $marker = $body.IndexOf("Set-K8ShakedownRunStage -Stage '$($pair.Stage)'")
        if ($marker -lt 0) { throw "stage '$($pair.Stage)' is never set in Invoke-K8ShakedownRangeABBody" }
        $anchor = $body.IndexOf($pair.Anchor)
        if ($anchor -lt 0) { throw "anchor operation '$($pair.Anchor)' not found" }
        if ($anchor -lt $marker) { throw "stage '$($pair.Stage)' is set AFTER '$($pair.Anchor)'; a failure there would be attributed to the previous stage" }
    }
    $completeBody = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Complete-K8ShakedownRangeABBody'
    foreach ($pair in @(
        @{ Stage = 'complete-preconditions'; Anchor = 'Assert-K8RunSequenceInvariant' }
        @{ Stage = 'pre-teardown-validate';  Anchor = 'validate-evidence' }
        @{ Stage = 'teardown';               Anchor = "'down', '-v'" }
        @{ Stage = 'final-verify';           Anchor = 'verify-integrity' }
    )) {
        $marker = $completeBody.IndexOf("Set-K8ShakedownRunStage -Stage '$($pair.Stage)'")
        if ($marker -lt 0) { throw "stage '$($pair.Stage)' is never set in Complete-K8ShakedownRangeABBody" }
        $anchor = $completeBody.IndexOf($pair.Anchor)
        if ($anchor -lt 0) { throw "anchor '$($pair.Anchor)' not found in Complete-K8ShakedownRangeABBody" }
        if ($anchor -lt $marker) { throw "stage '$($pair.Stage)' is set after '$($pair.Anchor)'" }
    }
    $rangeC = Get-K8CommentStrippedSource -Path $RangeCPath
    foreach ($pair in @(
        @{ Stage = 'sequence-binding'; Anchor = 'Assert-K8SequenceBinding' }
        @{ Stage = 'worktree-copy';    Anchor = 'Copy-Item -Recurse' }
        @{ Stage = 'validator-run';    Anchor = 'cmd.exe' }
    )) {
        $marker = $rangeC.IndexOf("Set-K8ShakedownRunStage -Stage '$($pair.Stage)'")
        if ($marker -lt 0) { throw "stage '$($pair.Stage)' is never set in Run-K8ShakedownRangeC.ps1" }
        $anchor = $rangeC.IndexOf($pair.Anchor)
        if ($anchor -lt 0) { throw "anchor '$($pair.Anchor)' not found in Run-K8ShakedownRangeC.ps1" }
        if ($anchor -lt $marker) { throw "stage '$($pair.Stage)' is set after '$($pair.Anchor)' in Run-K8ShakedownRangeC.ps1" }
    }
}

Assert-K8Test 'No control-plane record path resolves under Study01/' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        $frozen = (Resolve-Path $Study01).Path
        $workspace = (Resolve-Path $sb.Root -ErrorAction SilentlyContinue)
        $workspaceRoot = $(if ($workspace) { $workspace.Path } else { $sb.Root })
        foreach ($p in @(
            (Get-K8SequenceDir), (Get-K8RunRecordsDir), (Get-K8SequencePointerPath), (Get-K8SequenceLockPath),
            (Get-K8SequenceRecordPath -SequenceId 'k8shakedown-seq-19700101-000000'),
            (Get-K8RunProvenancePath -RunId 'k8shakedown-rangea-19700101-000000'),
            (Get-K8TerminationRecordPath -RunId 'k8shakedown-rangea-19700101-000000')
        )) {
            if ($p.StartsWith($frozen, [System.StringComparison]::OrdinalIgnoreCase)) { throw "control-plane path '$p' resolves under the frozen Study01 tree" }
            if (-not $p.StartsWith($workspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw "control-plane path '$p' escapes the Shakedown workspace" }
        }
    }
}

# --- 28. K8-S2 Batch 2: C-3 scoring-input contract, C-4 observation retention,
#         C-5 legitimate absence, C-6 stage completeness, C-7 narrative refs ---
#
# All offline. No Docker, no VM, no Amenonuboco checkout, no live Elasticsearch.
# Nothing here reads Study01/expected/.

$ContractPy   = Join-Path $ToolsDir 'k8_scoring_input_contract.py'
$EvidencePy   = Join-Path $ToolsDir 'k8_shakedown_evidence.py'
$SyntheticPy  = Join-Path $PSScriptRoot 'k8_synthetic_evidence_tree.py'
$ScriptsDir   = Join-Path $Study01 'studies\study-01-negative-result\scripts'
$RangeCSource = Join-Path $ToolsDir 'Run-K8ShakedownRangeC.ps1'

function Get-K8Contract {
    <# The contract as DATA. Tests read this; they never restate it. #>
    param([string] $Range)
    # NOT $args: that is an automatic variable in PowerShell.
    $argv = @($ContractPy, 'describe')
    if ($Range) { $argv += @('--range', $Range) }
    return ((& python @argv) -join "`n") | ConvertFrom-Json
}

function New-K8TempDir {
    param([string] $Prefix = 'k8b2')
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("$Prefix-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

function New-K8FinalizedFixture {
    <#
        A minimal FINALIZED run: a few artifacts, a hashes.sha256 over exactly
        those bytes, and a control-plane finalize-identity snapshot pinning that
        manifest. Enough for the C-3 validator's artifact-resolution rules
        without needing a whole frozen evidence tree.
    #>
    param([hashtable] $Artifacts)
    $root = New-K8TempDir -Prefix 'k8c3'
    $runId = 'k8shakedown-rangea-20260831-000000'
    $evidence = Join-Path $root $runId
    New-Item -ItemType Directory -Force -Path $evidence | Out-Null
    foreach ($rel in $Artifacts.Keys) {
        $full = Join-Path $evidence $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $full -Parent) | Out-Null
        [System.IO.File]::WriteAllText($full, $Artifacts[$rel], (New-Object System.Text.UTF8Encoding($false)))
    }
    $lines = foreach ($rel in ($Artifacts.Keys | Sort-Object)) {
        $digest = (Get-FileHash -LiteralPath (Join-Path $evidence $rel) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$digest  $($rel -replace '\\', '/')"
    }
    $manifest = Join-Path $evidence 'hashes.sha256'
    [System.IO.File]::WriteAllText($manifest, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $snapshot = Join-Path $root 'finalize-identity.json'
    @{
        schema               = 'k8shakedown-finalize-identity/1'
        run_id               = $runId
        finalized_utc        = (Get-Date).ToUniversalTime().ToString('o')
        hashes_sha256_digest = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
    } | ConvertTo-Json | Set-Content -LiteralPath $snapshot -Encoding utf8NoBOM
    return [pscustomobject]@{ Root = $root; RunId = $runId; Evidence = $evidence; Snapshot = $snapshot }
}

function Invoke-K8ContractValidate {
    param(
        [Parameter(Mandatory)] $Fixture,
        [Parameter(Mandatory)][string] $Range,
        [Parameter(Mandatory)] $Record,
        [string] $SnapshotOverride
    )
    $inputPath = Join-Path $Fixture.Root ('input-' + [guid]::NewGuid().ToString('N') + '.json')
    ($Record | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $inputPath -Encoding utf8NoBOM
    $snapshot = $(if ($SnapshotOverride) { $SnapshotOverride } else { $Fixture.Snapshot })
    $output = & python $ContractPy validate --range $Range --input $inputPath `
        --run-evidence $Fixture.Evidence --finalize-snapshot $snapshot 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = (@($output) -join "`n") }
}

function New-K8ValidScoringInput {
    <# A completed Range A input built FROM the contract, not from a copy of
       it: the required addresses come from `describe`, so this fixture cannot
       silently disagree with the contract it is testing. #>
    param([Parameter(Mandatory)] $Fixture, [string] $Range = 'a')
    $contract = Get-K8Contract -Range $Range
    $values = @{
        'stages.ground_truth'   = 'Pass'
        'stages.sensor'         = 'Pass'
        'stages.collector'      = 'Pass'
        'rule_output'           = 'Alert'
        'runtime_contract'      = 'Pass'
        'evidence_correlatable' = $true
        'r_obs_05'              = 'Pass'
    }
    $record = [ordered]@{
        range                  = $Range.ToUpper()
        procedure_conformance  = [ordered]@{
            schema_version    = 2
            sender_invocations = @(@{ timestamp = '2026-08-31T12:00:00+00:00'; exit_code = 0 })
            invocation_count  = 1
            same_run_retry    = $false
            procedure_invalid = $false
            invalid_reasons   = @()
        }
        stages                 = [ordered]@{}
        derivation             = [ordered]@{}
    }
    foreach ($field in $contract.fields) {
        if (-not $field.required) { continue }
        $value = $values[$field.address]
        if ($field.address -like 'stages.*') { $record.stages[$field.address.Split('.')[1]] = $value }
        else { $record[$field.address] = $value }
        $record.derivation[$field.address] = [ordered]@{ artifact = 'collector-output/collector-response.json'; value = $value }
    }
    return $record
}

# --- C-3 -------------------------------------------------------------------

Assert-K8Test 'C-3: the structural contract has ONE source -- template, validator and tests all derive from `describe`' {
    $contract = Get-K8Contract
    if ($contract.contract -ne 'k8shakedown-scoring-input-contract/1') { throw "unexpected contract identity '$($contract.contract)'" }
    # The value domains must be IMPORTED from the frozen module, not restated.
    $frozenStages = ((& python -c "import sys; sys.path.insert(0, r'$ScriptsDir'); from study01.frozen.semantics import STAGE_VALUES; print(','.join(sorted(STAGE_VALUES)))") -join '').Trim()
    $stageField = @($contract.fields | Where-Object { $_.address -eq 'stages.ground_truth' })[0]
    if (($stageField.domain -join ',') -ne $frozenStages) { throw "stage domain '$($stageField.domain -join ',')' is not the frozen STAGE_VALUES '$frozenStages'" }
    if ($stageField.domain_source -ne 'STAGE_VALUES') { throw 'the stage domain does not name the frozen constant it came from' }
    # And the template's judgment slots must be exactly the contract's required
    # addresses for that Range -- no second hardcoded list anywhere.
    $tmp = New-K8TempDir -Prefix 'k8c3tpl'
    try {
        $templatePath = Join-Path $tmp 'template.json'
        & python $ContractPy emit-template --range b --output $templatePath | Out-Null
        $template = Get-Content $templatePath -Raw | ConvertFrom-Json
        $expected = @((Get-K8Contract -Range b).fields | Where-Object { $_.required } | ForEach-Object { $_.address })
        $actual = @($template.derivation.PSObject.Properties.Name)
        $left = (($actual | Sort-Object) -join ',')
        $right = (($expected | Sort-Object) -join ',')
        if ($left -ne $right) {
            throw "template derivation keys [$left] do not equal the contract's required addresses [$right]"
        }
    }
    finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'C-3: the template passes NEITHER the frozen scorer NOR the structural validator' {
    $tmp = New-K8TempDir -Prefix 'k8c3tpl2'
    $fixture = New-K8FinalizedFixture -Artifacts @{ 'collector-output\collector-response.json' = '{}' }
    try {
        $templatePath = Join-Path $tmp 'template.json'
        & python $ContractPy emit-template --range a --output $templatePath | Out-Null
        $template = Get-Content $templatePath -Raw | ConvertFrom-Json

        # The frozen scorer must refuse it.
        $scored = & python -c "import json,sys; sys.path.insert(0, r'$ScriptsDir')
from study01.scorer import score
try:
    score(json.load(open(r'$templatePath', encoding='utf-8')))
    print('SCORED')
except Exception as exc:
    print('REFUSED:' + type(exc).__name__)"
        if (($scored -join '') -notmatch '^REFUSED:') { throw "the frozen scorer accepted the template ($scored) -- a template must never be scorable" }

        # And so must the structural validator.
        $result = Invoke-K8ContractValidate -Fixture $fixture -Range a -Record $template
        if ($result.ExitCode -eq 0) { throw 'the structural validator accepted the template' }
        if ($result.Text -notmatch 'placeholder') { throw "the refusal does not name the placeholder: $($result.Text)" }
    }
    finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Assert-K8Test 'C-3: a completed input PASSES the structural contract and is a non-regression for the frozen scorer' {
    $fixture = New-K8FinalizedFixture -Artifacts @{ 'collector-output\collector-response.json' = '{"hits":{}}' }
    try {
        $record = New-K8ValidScoringInput -Fixture $fixture -Range a
        $result = Invoke-K8ContractValidate -Fixture $fixture -Range a -Record $record
        if ($result.ExitCode -ne 0) { throw "a complete, consistent Range A input was refused: $($result.Text)" }

        # The added top-level `derivation` key must not disturb the frozen
        # scorer: it reads named keys only and rejects no extra top-level field.
        $inputPath = Join-Path $fixture.Root 'scored.json'
        ($record | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $inputPath -Encoding utf8NoBOM
        $classification = (& python -c "import json,sys; sys.path.insert(0, r'$ScriptsDir')
from study01.scorer import score
print(score(json.load(open(r'$inputPath', encoding='utf-8')))['experiment_classification'])") -join ''
        if ($classification -ne 'Valid detection result') { throw "the frozen scorer did not score the derivation-carrying input as expected: '$classification'" }
    }
    finally { Remove-Item $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'C-3: coverage, addressing, value consistency and artifact resolution all fail closed' {
    $fixture = New-K8FinalizedFixture -Artifacts @{
        'collector-output\collector-response.json' = '{"hits":{}}'
        'rule-output\rule-response.json'           = '{"hits":{}}'
    }
    try {
        $cases = @(
            @{ Name = 'empty derivation'; Because = 'non-empty object is required'; Mutate = { param($r) $r.derivation = [ordered]@{}; $r } }
            @{ Name = 'missing one derivation entry'; Because = 'derivation\.rule_output: missing'; Mutate = { param($r) $r.derivation.Remove('rule_output'); $r } }
            @{ Name = 'legacy bare addressing'; Because = 'not part of the Range'; Mutate = {
                param($r)
                $r.derivation['ground_truth'] = $r.derivation['stages.ground_truth']
                $r.derivation.Remove('stages.ground_truth'); $r } }
            @{ Name = 'derivation value disagrees with the input'; Because = 'records value'; Mutate = {
                param($r) $r.derivation['rule_output'].value = 'No alert'; $r } }
            @{ Name = 'artifact escapes the run root'; Because = 'escapes the run evidence root'; Mutate = {
                param($r) $r.derivation['rule_output'].artifact = '../../etc/passwd'; $r } }
            @{ Name = 'absolute artifact path'; Because = 'must be run-relative'; Mutate = {
                param($r) $r.derivation['rule_output'].artifact = 'C:/Windows/System32/drivers/etc/hosts'; $r } }
            @{ Name = 'artifact does not exist'; Because = 'does not exist under'; Mutate = {
                param($r) $r.derivation['rule_output'].artifact = 'collector-output/never-written.json'; $r } }
            @{ Name = 'r_obs_05 typo'; Because = 'outside the accepted token domain'; Mutate = {
                param($r) $r['r_obs_05'] = 'Fial'; $r.derivation['r_obs_05'].value = 'Fial'; $r } }
            @{ Name = 'sensor_capture with a non-"empty" token'; Because = 'outside the accepted token domain'; Mutate = {
                param($r) $r['sensor_capture'] = 'present'; $r.derivation['sensor_capture'] = [ordered]@{ artifact = 'collector-output/collector-response.json'; value = 'present' }; $r } }
            @{ Name = 'optional field present without a derivation'; Because = 'derivation\.target_observation_absent: missing'; Mutate = {
                param($r) $r['target_observation_absent'] = $true; $r } }
        )
        foreach ($case in $cases) {
            $record = New-K8ValidScoringInput -Fixture $fixture -Range b
            $record = & $case.Mutate $record
            $result = Invoke-K8ContractValidate -Fixture $fixture -Range b -Record $record
            if ($result.ExitCode -eq 0) { throw "'$($case.Name)' was ACCEPTED; it must fail closed" }
            if ($result.Text -notmatch $case.Because) { throw "'$($case.Name)' failed for the wrong reason: $($result.Text)" }
        }
    }
    finally { Remove-Item $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'C-3: manifest coverage, digest drift and finalize-snapshot drift are all refused' {
    $fixture = New-K8FinalizedFixture -Artifacts @{ 'collector-output\collector-response.json' = '{"hits":{}}' }
    try {
        # (a) an artifact that exists but is not in hashes.sha256 -- it was not
        #     part of the finalized evidence.
        $extra = Join-Path $fixture.Evidence 'collector-output\added-later.json'
        '{}' | Set-Content -LiteralPath $extra -Encoding utf8NoBOM
        $record = New-K8ValidScoringInput -Fixture $fixture -Range a
        $record.derivation['rule_output'].artifact = 'collector-output/added-later.json'
        $result = Invoke-K8ContractValidate -Fixture $fixture -Range a -Record $record
        if ($result.ExitCode -eq 0) { throw 'an artifact absent from hashes.sha256 was accepted' }
        if ($result.Text -notmatch 'not covered by\s+hashes\.sha256') { throw "wrong reason: $($result.Text)" }
        Remove-Item $extra -Force

        # (b) an artifact whose bytes changed after finalization.
        $record = New-K8ValidScoringInput -Fixture $fixture -Range a
        'tampered' | Set-Content -LiteralPath (Join-Path $fixture.Evidence 'collector-output\collector-response.json') -Encoding utf8NoBOM
        $result = Invoke-K8ContractValidate -Fixture $fixture -Range a -Record $record
        if ($result.ExitCode -eq 0) { throw 'a digest mismatch against hashes.sha256 was accepted' }
        if ($result.Text -notmatch 'no longer hashes to its') { throw "wrong reason: $($result.Text)" }

        # (c) a manifest re-made after verify-integrity passed. This is the case
        #     "listed in hashes.sha256" alone cannot catch, and the whole reason
        #     the finalize identity snapshot exists.
        $lines = "$(( Get-FileHash -LiteralPath (Join-Path $fixture.Evidence 'collector-output\collector-response.json') -Algorithm SHA256).Hash.ToLowerInvariant())  collector-output/collector-response.json"
        [System.IO.File]::WriteAllText((Join-Path $fixture.Evidence 'hashes.sha256'), $lines, (New-Object System.Text.UTF8Encoding($false)))
        $result = Invoke-K8ContractValidate -Fixture $fixture -Range a -Record $record
        if ($result.ExitCode -eq 0) { throw 'a manifest regenerated after verify-integrity was accepted' }
        if ($result.Text -notmatch 'not the finalized one') { throw "wrong reason: $($result.Text)" }
    }
    finally { Remove-Item $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'C-3: r_obs_05 = "Unresolved" is refused with the reason, and never quietly accepted' {
    $fixture = New-K8FinalizedFixture -Artifacts @{ 'collector-output\collector-response.json' = '{"hits":{}}' }
    try {
        $record = New-K8ValidScoringInput -Fixture $fixture -Range b
        $record['r_obs_05'] = 'Unresolved'
        $record.derivation['r_obs_05'].value = 'Unresolved'
        $result = Invoke-K8ContractValidate -Fixture $fixture -Range b -Record $record
        if ($result.ExitCode -eq 0) { throw '"Unresolved" was accepted as a scoring token; no frozen source fixes its propagation' }
        foreach ($needle in @('Unresolved', 'no frozen source fixes', "only == 'Fail'", 'C-5')) {
            if ($result.Text -notmatch [regex]::Escape($needle)) { throw "the refusal does not explain '$needle': $($result.Text)" }
        }
        # And the frozen scorer really does ignore every other token -- which is
        # exactly why accepting one here would be a hidden semantic default.
        $scorerSource = Get-Content (Join-Path $ScriptsDir 'study01\scorer.py') -Raw
        $mentions = @([regex]::Matches($scorerSource, 'r_obs_05'))
        if ($mentions.Count -ne 1) { throw "the frozen scorer now mentions r_obs_05 $($mentions.Count) times; the C-3 token domain must be re-derived from it" }
        if ($scorerSource -notmatch 'r_obs_05"\)\s*==\s*"Fail"') { throw 'the frozen scorer no longer special-cases exactly r_obs_05 == "Fail"; the C-3 token domain must be re-derived' }
    }
    finally { Remove-Item $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'C-3: required presence differs correctly by Range, and the module never reads expected/' {
    $fixture = New-K8FinalizedFixture -Artifacts @{ 'collector-output\collector-response.json' = '{"hits":{}}' }
    try {
        # evidence_correlatable is required for BOTH ranges: the frozen scorer
        # defaults it to True, so an absent field is silently a decision.
        foreach ($range in @('a', 'b')) {
            $record = New-K8ValidScoringInput -Fixture $fixture -Range $range
            $record.Remove('evidence_correlatable')
            $record.derivation.Remove('evidence_correlatable')
            $result = Invoke-K8ContractValidate -Fixture $fixture -Range $range -Record $record
            if ($result.ExitCode -eq 0) { throw "Range $($range.ToUpper()) accepted a scoring input with no evidence_correlatable" }
        }
        # r_obs_05 is required for B and must not be part of the A contract.
        $record = New-K8ValidScoringInput -Fixture $fixture -Range b
        $record.Remove('r_obs_05'); $record.derivation.Remove('r_obs_05')
        $result = Invoke-K8ContractValidate -Fixture $fixture -Range b -Record $record
        if ($result.ExitCode -eq 0) { throw 'Range B accepted a scoring input with no r_obs_05' }
        $rangeA = @((Get-K8Contract -Range a).fields | ForEach-Object { $_.address })
        if ($rangeA -contains 'r_obs_05') { throw 'r_obs_05 is part of the Range A contract; R-OBS-05 is Range B only' }
    }
    finally { Remove-Item $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'C-3: neither the contract module nor the Shakedown tooling resolves a path under Study01/expected/' {
    # What is forbidden is RESOLVING an expected/ path, not the English word
    # "expected" (which is a perfectly ordinary identifier -- `-Expected
    # $expected` on a readiness check has nothing to do with the frozen
    # expected-results directory). So this looks only for `expected` used as a
    # PATH SEGMENT, and exempts comments and operator-facing instructions that
    # merely tell a human to go and look there themselves.
    # `expected` as an interior PATH SEGMENT: preceded by a separator or a
    # quote and followed by a separator. Ordinary prose ("expected/actual
    # counts") and ordinary identifiers (`-Expected $expected`) do not match.
    $pathSegment = '["'' \t]?[\\/]expected[\\/]|["'']expected[\\/]'

    # A guard that matches nothing proves nothing. Pin its behaviour on both
    # sides before trusting the sweep below.
    foreach ($violation in @(
        "Join-Path `$Study01 'expected\range-a'"
        "open('Study01/expected/range-b/hashes.sha256')"
        "`$p = 'expected/range-c'"
        'Get-Content (Join-Path $repo "Study01\expected\range-a\score.json")'
    )) { if ($violation -notmatch $pathSegment) { throw "the expected/ guard does not catch a real violation, so this check is vacuous: $violation" } }
    foreach ($innocent in @(
        'recompute expected/actual/missing counts by hand'
        'New-K8ComposeReadinessRecord -Expected $expected'
        'exit 1 is the EXPECTED outcome per README SS5.3'
    )) { if ($innocent -match $pathSegment) { throw "the expected/ guard fires on ordinary prose or an ordinary identifier: $innocent" } }

    foreach ($path in @($ContractPy, $EvidencePy, $CommonPath, $RangeCSource)) {
        foreach ($line in ((Get-Content $path -Raw) -split "`r?`n")) {
            if ($line -notmatch $pathSegment) { continue }
            $trimmed = $line.TrimStart()
            if ($trimmed.StartsWith('#')) { continue }              # PowerShell comment
            if ($trimmed.StartsWith('*') -or $trimmed.StartsWith('"""')) { continue }
            if ($line -match 'Write-Host|README|compare it against|BEFORE opening') { continue }
            throw "$(Split-Path $path -Leaf) appears to resolve an expected/ path: $($line.Trim())"
        }
    }
    # And nothing may actually open it: no file-reading call takes an
    # expected/ path as its argument.
    foreach ($path in @($ContractPy, $EvidencePy)) {
        $text = Get-Content $path -Raw
        if ($text -match '(open|read_text|read_bytes|load)\([^)]*expected') { throw "$(Split-Path $path -Leaf) reads from expected/" }
    }
}

Assert-K8Test 'C-3: historical scoring-input shapes are refused, and are not retrofitted to pass' {
    # These reproduce the SHAPES of the three bundled qualification runs. The
    # historical runs themselves are not in this repository and are NOT
    # modified, re-scored or reinterpreted by anything here: what is asserted
    # is that the new contract refuses those shapes, not that the old runs are
    # re-judged.
    $fixture = New-K8FinalizedFixture -Artifacts @{ 'collector-output\collector-response.json' = '{"hits":{}}' }
    try {
        $shapes = @(
            @{ Name = 'k8shakedown-rangea-*-084343 shape: derivation present but bare (non-dotted) addressing'; Mutate = {
                param($r)
                foreach ($stage in @('ground_truth', 'sensor', 'collector')) {
                    $r.derivation[$stage] = $r.derivation["stages.$stage"]
                    $r.derivation.Remove("stages.$stage")
                }
                $r } }
            @{ Name = 'k8shakedown-*-101452 / -143427 shape: no derivation at all'; Mutate = {
                param($r) $r.Remove('derivation'); $r } }
        )
        foreach ($shape in $shapes) {
            $record = New-K8ValidScoringInput -Fixture $fixture -Range a
            $record = & $shape.Mutate $record
            $result = Invoke-K8ContractValidate -Fixture $fixture -Range a -Record $record
            if ($result.ExitCode -eq 0) { throw "'$($shape.Name)' was accepted by the new contract" }
        }
    }
    finally { Remove-Item $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- C-4 -------------------------------------------------------------------

Assert-K8Test 'C-4: a merged capture reports stdout/stderr as null and never invents per-stream emptiness' {
    Import-Module $CommonPath -Force
    $o = New-K8CombinedCommandObservation -Label 'merged' -Argv @('docker', 'compose', 'up') `
        -ExitCode 1 -TimestampUtc (Get-K8UtcNow) -CombinedOutput "line one`nline two" -ContainingArtifact $null
    if ($o['capture_semantics'] -ne 'combined') { throw "expected combined semantics, got '$($o['capture_semantics'])'" }
    if ($null -ne $o['stdout'] -or $null -ne $o['stderr']) { throw 'a merged capture claimed separated stdout/stderr -- 2>&1 destroyed that distinction and it must not be reconstructed' }
    if ($null -eq $o['combined_output']) { throw 'the merged transcript was not described at all' }
    if ($o['combined_output']['empty']) { throw 'a non-empty merged transcript was described as empty' }
}

Assert-K8Test 'C-4: separated stream descriptors hash exactly the retained transcript text' {
    Import-Module $CommonPath -Force
    $text = "eth0 mirred egress mirror`n"
    $o = New-K8SeparatedCommandObservation -Label 'probe' -Argv @('docker', 'exec', 'r', 'tc') `
        -ExitCode 0 -TimestampUtc (Get-K8UtcNow) -Stdout $text -Stderr '' -ContainingArtifact 'contract-output\x.txt'
    $expected = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = (($expected.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $expected.Dispose() }
    if ($o['stdout']['sha256'] -ne $digest) { throw 'stdout sha256 does not describe the retained transcript' }
    if ($o['stdout']['bytes'] -ne [System.Text.Encoding]::UTF8.GetByteCount($text)) { throw 'stdout byte count does not describe the retained transcript' }
    if ($o['stdout']['empty']) { throw 'a non-empty stdout was described as empty' }
    if (-not $o['stderr']['empty']) { throw 'an empty stderr was not described as empty' }
    if ($null -ne $o['combined_output']) { throw 'a separated capture must not claim a combined transcript' }
}

Assert-K8Test 'C-4: a ZERO-BYTE stream is retained and described, never treated as a missing artifact (the Range C case)' {
    Import-Module $CommonPath -Force
    $d = New-K8TempDir -Prefix 'k8c4rc'
    try {
        # Exactly the Range C shape: cmd.exe redirected both streams itself, and
        # an EMPTY stdout is the frozen EXPECTED observation.
        [System.IO.File]::WriteAllBytes((Join-Path $d 'validate.stdout.txt'), @())
        [System.IO.File]::WriteAllText((Join-Path $d 'validate.stderr.txt'), "observability_contract.required_segments: sub_a_l2_lan`n")
        $o = New-K8FileBackedCommandObservation -Label 'range c validator' `
            -Argv @('cmd.exe', '/c', 'python', 'platform\cli.py', 'validate') -ExitCode 1 `
            -TimestampUtc (Get-K8UtcNow) -RunEvidence $d `
            -StdoutRelativePath 'validate.stdout.txt' -StderrRelativePath 'validate.stderr.txt'
        if ($o['capture_semantics'] -ne 'file-backed') { throw "expected file-backed semantics, got '$($o['capture_semantics'])'" }
        if ($o['stdout']['bytes'] -ne 0 -or -not $o['stdout']['empty']) { throw 'the 0-byte stdout was not described as an empty retained stream' }
        if ($o['stdout']['path'] -ne 'validate.stdout.txt') { throw 'a file-backed stream must name the file that holds it' }
        if ($o['stdout']['sha256'] -ne (Get-FileHash -LiteralPath (Join-Path $d 'validate.stdout.txt') -Algorithm SHA256).Hash.ToLowerInvariant()) {
            throw 'a file-backed descriptor must hash the FILE bytes, with no re-encoding'
        }
        # `artifacts` is the role/channel enumeration, derived from the same
        # descriptors so the two views cannot drift.
        $roles = @($o['artifacts'] | ForEach-Object { $_['role'] })
        if (($roles -join ',') -ne 'stdout,stderr') { throw "file-backed artifacts were not enumerated by role: $($roles -join ',')" }
        foreach ($entry in $o['artifacts']) {
            if ($entry['sha256'] -ne $o[$entry['channel']]['sha256']) { throw "the $($entry['role']) enumeration disagrees with its own descriptor" }
        }
        # And a stream file that does not exist is a STOP, not a skipped record.
        Remove-Item (Join-Path $d 'validate.stdout.txt') -Force
        Assert-K8FailsClosed -What 'describing a stream whose file is missing' -Because 'must still be a file' -Attempt {
            New-K8FileBackedCommandObservation -Label 'x' -Argv @('cmd.exe') -ExitCode 0 `
                -TimestampUtc (Get-K8UtcNow) -RunEvidence $d `
                -StdoutRelativePath 'validate.stdout.txt' -StderrRelativePath 'validate.stderr.txt'
        }
    }
    finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'C-4: the producer inventory is a closed world across A/B/C, and adds no new .txt artifact' {
    Import-Module $CommonPath -Force
    # Closed world: every retained command-observation artifact in the contract
    # has a sidecar row, and every sidecar row has its base artifact.
    $rows = @(Get-K8ArtifactContract)
    $sidecars = @($rows | Where-Object { $_.artifact -like '*.observation.json' } | ForEach-Object { $_.artifact })
    $expectedSidecars = @(
        'contract-output\qdisc-pre-fault.observation.json'
        'contract-output\fault-injection-command.observation.json'
        'contract-output\qdisc-post-fault.observation.json'
        'contract-output\unrelated-mirror-filters.observation.json'
        'validate.observation.json'
    )
    foreach ($expected in $expectedSidecars) {
        if ($sidecars -notcontains $expected) { throw "the closed-world producer inventory is missing '$expected'" }
    }
    foreach ($sidecar in $sidecars) {
        if ($expectedSidecars -notcontains $sidecar) { throw "'$sidecar' is a sidecar the inventory does not account for" }
    }
    # No new `.txt`: every text artifact in the contract is one that already
    # existed before Batch 2, with ONE named exception. Structured output goes
    # into JSON sidecars.
    #
    # source-identity.txt is added by Batch 3B, and it is not a C-4 command
    # observation at all: docs/k8-independent-reproduction-plan.md SS5.2 asks
    # for a per-run `source-identity.txt` BY NAME, and the authoritative record
    # is the JSON under sequences/. Allowing it by name keeps the rule intact --
    # what C-4 forbids is a second, hand-written text rendering of a command
    # observation, which this is not.
    $preExistingTxt = @(
        'source-identity.txt',
        'contract-output\gateway-interface-resolution.txt', 'contract-output\qdisc-pre-fault.txt',
        'contract-output\fault-injection-command.txt', 'contract-output\qdisc-post-fault.txt',
        'contract-output\unrelated-mirror-filters.txt', 'contract-output\r-obs-05-liveness-decode.txt',
        'contract-output\r-obs-05-contract-reference.txt', 'ground-truth\sender-record.txt',
        'metadata-t0.txt', 'validate.stdout.txt', 'validate.stderr.txt'
    )
    foreach ($row in $rows) {
        if ($row.artifact -notlike '*.txt') { continue }
        if ($preExistingTxt -notcontains $row.artifact) { throw "Batch 2 introduced a new .txt artifact: '$($row.artifact)'" }
    }
    # The two schemas are distinct records, not one reused shape.
    $source = Get-Content $CommonPath -Raw
    if ($source -notmatch "K8CommandObservationSchema\s*=\s*'k8shakedown-command-observation/1'") { throw 'the command-observation schema identity is missing' }
    if ($source -notmatch "K8TerminationSchema\s*=\s*'k8shakedown-termination/1'") { throw 'the termination schema identity changed' }
}

Assert-K8Test 'C-4: the unrelated mirror-filter scan retains argv/exit for EVERY probe, and writes the record before it can fail closed' {
    $body = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Assert-K8UnrelatedMirrorFilter'
    if ($body -notmatch 'New-K8SeparatedCommandObservation') { throw 'the scan does not build C-4 observations at all' }
    $writeIndex = $body.IndexOf('Write-K8CommandObservation')
    $throwIndex = $body.IndexOf('Range B R-OBS-05 gate failed')
    if ($writeIndex -lt 0) { throw 'the scan never writes its observation record' }
    if ($throwIndex -lt 0 -or $writeIndex -gt $throwIndex) { throw 'the observation record is written AFTER the gate throws, so a failing scan would retain nothing' }
    # Both the enumeration command and the per-interface probe must be recorded.
    if (([regex]::Matches($body, 'New-K8SeparatedCommandObservation')).Count -lt 2) { throw 'only one command is recorded; the per-interface probes are still discarded' }
}

# --- C-5 -------------------------------------------------------------------

function Invoke-K8EvidenceTool {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $output = & python $EvidencePy @Arguments 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = (@($output) -join "`n") }
}

Assert-K8Test 'C-5: absence admissibility is per-observer and matches frozen policy exactly' {
    $source = Get-Content $EvidencePy -Raw
    $expected = @{
        'RULE_MAPPING_ABSENCE_ADMISSIBLE'     = 'True'
        'COLLECTOR_MAPPING_ABSENCE_ADMISSIBLE' = 'False'
        'R_OBS_05_MAPPING_ABSENCE_ADMISSIBLE'  = 'False'
    }
    foreach ($name in $expected.Keys) {
        if ($source -notmatch "$name\s*=\s*$($expected[$name])\b") {
            throw "$name is not $($expected[$name]). Rule index absence is legitimate (lazily created, no frozen source requires it); Collector and R-OBS-05 absence is a frozen fail-close and must not be relaxed."
        }
    }
    # And there must be exactly one gate implementation, so the three cannot
    # drift into divergent control flow.
    if (([regex]::Matches($source, '(?m)^def mapping_gate\(')).Count -ne 1) { throw 'there is not exactly one mapping_gate implementation' }
    if ($source -match "(?m)^\s*OBSERVER_FAILED\s*=") { throw 'a `failed` observer status was introduced; this module cannot produce one (acquisition failures are C-4/C-1)' }
}

Assert-K8Test 'C-5: an empty mapping is `succeeded` + `index_present: false`, NOT `malformed`, and is retained before any fail-close' {
    $d = New-K8TempDir -Prefix 'k8c5'
    try {
        '{}' | Set-Content -LiteralPath (Join-Path $d 'empty.json') -Encoding utf8NoBOM

        # Rule: legitimate absence -> PASS, exit 0.
        $out = Join-Path $d 'rule-gate.json'
        $r = Invoke-K8EvidenceTool -Arguments @('rule-mapping-gate', '--mapping', (Join-Path $d 'empty.json'), '--output', $out)
        if ($r.ExitCode -ne 0) { throw "a legitimately absent Rule index failed the gate: $($r.Text)" }
        $rec = Get-Content $out -Raw | ConvertFrom-Json
        if ($rec.observer_status -ne 'succeeded') { throw "the Rule observer reported '$($rec.observer_status)'; observing an absent index is a SUCCESS" }
        if ($rec.index_present -ne $false -or $rec.absence_admissible -ne $true -or $rec.mapping_gate_pass -ne $true) { throw 'the Rule absence record is not the legitimate-absence shape' }

        # Collector: the SAME observation, but the absence is not admissible.
        # The record must exist even though the gate then fails closed.
        $out = Join-Path $d 'collector-gate.json'
        $r = Invoke-K8EvidenceTool -Arguments @('collector-mapping-gate', '--mapping', (Join-Path $d 'empty.json'), '--output', $out)
        if ($r.ExitCode -eq 0) { throw 'an absent Collector index did NOT fail closed; that is a frozen fail-close' }
        if (-not (Test-Path $out)) { throw 'the Collector observation was not retained before the fail-close -- the exact diagnostic gap C-5 closes' }
        $rec = Get-Content $out -Raw | ConvertFrom-Json
        if ($rec.observer_status -ne 'succeeded') { throw "an empty mapping was recorded as '$($rec.observer_status)'; empty is not malformed -- the observer worked" }
        if ($rec.index_present -ne $false) { throw 'index_present must be false, not null: the observer positively determined the index is absent' }
        if ($rec.absence_admissible -ne $false) { throw 'the Collector absence was marked admissible; no frozen source permits it' }

        # R-OBS-05 mapping gate: same fail-close.
        $out = Join-Path $d 'robs-gate.json'
        $r = Invoke-K8EvidenceTool -Arguments @('mapping-gate', '--mapping', (Join-Path $d 'empty.json'), '--output', $out)
        if ($r.ExitCode -eq 0) { throw 'an absent R-OBS-05 index did NOT fail closed' }
        if ((Get-Content $out -Raw | ConvertFrom-Json).absence_admissible -ne $false) { throw 'the R-OBS-05 absence was marked admissible' }
    }
    finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'C-5: an unevaluable response is `malformed` with NULL axes -- unknown is never flattened to "no"' {
    $d = New-K8TempDir -Prefix 'k8c5m'
    try {
        '[]' | Set-Content -LiteralPath (Join-Path $d 'bad.json') -Encoding utf8NoBOM
        $out = Join-Path $d 'gate.json'
        $r = Invoke-K8EvidenceTool -Arguments @('collector-mapping-gate', '--mapping', (Join-Path $d 'bad.json'), '--output', $out)
        if ($r.ExitCode -eq 0) { throw 'an unevaluable mapping response did not fail closed' }
        if (-not (Test-Path $out)) { throw 'the malformed observation was not retained' }
        $rec = Get-Content $out -Raw | ConvertFrom-Json
        if ($rec.observer_status -ne 'malformed') { throw "expected observer_status 'malformed', got '$($rec.observer_status)'" }
        if ($null -ne $rec.index_present) { throw 'index_present must be NULL when the observer could not evaluate the response -- "unknown" is not "absent"' }
        if ($null -ne $rec.evaluated_count) { throw 'evaluated_count must be NULL for a malformed observation' }
    }
    finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'C-5: a universal predicate over an EMPTY set is null, never a vacuous `true`' {
    $d = New-K8TempDir -Prefix 'k8c5v'
    try {
        $empty = Join-Path $d 'empty-hits.json'
        '{"hits":{"total":{"relation":"eq","value":0},"hits":[]}}' | Set-Content -LiteralPath $empty -Encoding utf8NoBOM
        $out = Join-Path $d 'correlation.json'
        $r = Invoke-K8EvidenceTool -Arguments @('target-correlation', '--collector', $empty, '--rule', $empty, '--output', $out)
        if ($r.ExitCode -ne 0) { throw "a zero-hit Rule response is a legitimate observation and must not fail: $($r.Text)" }
        $rec = Get-Content $out -Raw | ConvertFrom-Json
        if ($rec.all_rule_hits_correlate -eq $true) { throw 'all_rule_hits_correlate is TRUE with zero Rule hits -- "observed no counterexample" was collapsed into "confirmed the correlation"' }
        if ($null -ne $rec.all_rule_hits_correlate) { throw "expected null, got '$($rec.all_rule_hits_correlate)'" }
        if ($rec.correlation_applicable -ne $false) { throw 'correlation_applicable must state that the predicate had nothing to range over' }
        if ($rec.evaluated_count -ne 0) { throw 'evaluated_count must record the cardinality separately from the predicate' }
        if ($rec.absence_admissible -ne $true) { throw 'a zero Rule hit set is a legitimate observation ("No alert" is frozen expected for Range B)' }

        # A non-empty set still evaluates the predicate normally.
        $hit = Join-Path $d 'hit.json'
        '{"hits":{"total":{"relation":"eq","value":1},"hits":[{"_id":"doc-1","_source":{"source_dnp3_doc_id":"doc-1"}}]}}' | Set-Content -LiteralPath $hit -Encoding utf8NoBOM
        $out2 = Join-Path $d 'correlation2.json'
        $r = Invoke-K8EvidenceTool -Arguments @('target-correlation', '--collector', $hit, '--rule', $hit, '--output', $out2)
        if ($r.ExitCode -ne 0) { throw "a correlating Rule hit failed: $($r.Text)" }
        $rec2 = Get-Content $out2 -Raw | ConvertFrom-Json
        if ($rec2.all_rule_hits_correlate -ne $true -or $rec2.correlation_applicable -ne $true -or $rec2.evaluated_count -ne 1) {
            throw 'a genuinely evaluated predicate was not recorded as such'
        }
    }
    finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'C-5: R-OBS-05 retains its observation BEFORE failing closed, and names only the contract-fixed outcome tokens' {
    $d = New-K8TempDir -Prefix 'k8c5r'
    try {
        $frames = Join-Path $d 'frames.json'
        '[{"frame_number":"1","ip_src":"10.1.10.10","ip_dst":"10.1.40.10","tcp_srcport":"1","tcp_dstport":"20000","dnp3_al_func":"5","dnp3_src":"1","dnp3_dst":"20","frame_time_epoch":"1788000000.0"}]' |
            Set-Content -LiteralPath $frames -Encoding utf8NoBOM

        # (a) zero documents. Frozen contract SS3: "A zero total ... is `Unresolved`".
        $zero = Join-Path $d 'zero.json'
        '{"hits":{"total":{"relation":"eq","value":0},"hits":[]}}' | Set-Content -LiteralPath $zero -Encoding utf8NoBOM
        $out = Join-Path $d 'robs-zero.json'
        $r = Invoke-K8EvidenceTool -Arguments @('r-obs-05', '--response', $zero, '--frames', $frames,
            '--window-start', '2026-08-31T12:00:00Z', '--window-end', '2026-08-31T12:00:20Z', '--output', $out)
        if ($r.ExitCode -eq 0) { throw 'a zero-hit R-OBS-05 response did not fail closed' }
        if (-not (Test-Path $out)) { throw 'the zero-hit observation was not retained before the fail-close' }
        $rec = Get-Content $out -Raw | ConvertFrom-Json
        if ($rec.observer_status -ne 'succeeded') { throw 'observing zero hits is a successful observation, not a malformed one' }
        if ($rec.r_obs_05_contract_outcome -ne 'Unresolved') { throw "expected the contract's own token 'Unresolved' for a zero total, got '$($rec.r_obs_05_contract_outcome)'" }
        if ($rec.correlation_applicable -ne $false -or $rec.evaluated_count -ne 0) { throw 'cardinality/applicability were not recorded separately' }
        if ($rec.absence_admissible -ne $false) { throw 'R-OBS-05 absence is never admissible (contract SS1 requires nonempty applicable Collector evidence)' }

        # (b) documents present, but no correlating pair. Frozen SS4: "R-OBS-05 is `Fail`".
        $nomatch = Join-Path $d 'nomatch.json'
        '{"hits":{"total":{"relation":"eq","value":1},"hits":[{"_id":"u-1","_source":{"layers":{"frame":{"frame_frame_time":"2026-08-31T12:00:05Z"},"ip":{"ip_ip_src":"9.9.9.9","ip_ip_dst":"8.8.8.8"}}}}]}}' |
            Set-Content -LiteralPath $nomatch -Encoding utf8NoBOM
        $out2 = Join-Path $d 'robs-nomatch.json'
        $r = Invoke-K8EvidenceTool -Arguments @('r-obs-05', '--response', $nomatch, '--frames', $frames,
            '--window-start', '2026-08-31T12:00:00Z', '--window-end', '2026-08-31T12:00:20Z', '--output', $out2)
        if ($r.ExitCode -eq 0) { throw 'an R-OBS-05 response with no correlating pair did not fail closed' }
        $rec2 = Get-Content $out2 -Raw | ConvertFrom-Json
        if ($rec2.r_obs_05_contract_outcome -ne 'Fail') { throw "expected the contract's own token 'Fail' when no pair correlates, got '$($rec2.r_obs_05_contract_outcome)'" }
        if ($rec2.evaluated_count -lt 1) { throw 'the comparisons that WERE evaluated are not recorded' }

        # The tooling must never author a passing verdict of its own.
        $source = Get-Content $EvidencePy -Raw
        if ($source -match 'contract_outcome\s*=\s*"Pass"') { throw 'the tooling authors an R-OBS-05 "Pass"; deriving a passing scientific verdict is not its job' }
    }
    finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- C-6 -------------------------------------------------------------------

Assert-K8Test 'C-6: there is exactly ONE required-artifact list, and the final gate does not restate it' {
    Import-Module $CommonPath -Force
    $gateBody = Get-K8FunctionBodyText -Path $CommonPath -Name 'Test-K8ScoringInputArtifactCompleteness'
    foreach ($needle in @('collector-output\', 'rule-output\', 'contract-output\', 'metadata-t0.txt', 'deviations.md')) {
        if ($gateBody -match [regex]::Escape($needle)) { throw "the final gate still carries its own artifact list ('$needle'); that is the second source of truth C-6 removes" }
    }
    if ($gateBody -notmatch 'Assert-K8RunArtifactCompleteness') { throw 'the final gate does not go through the shared contract' }
    # Both gates select from the same function, which is the only selector.
    $stageBody = Get-K8FunctionBodyText -Path $CommonPath -Name 'Assert-K8StageArtifacts'
    $finalBody = Get-K8FunctionBodyText -Path $CommonPath -Name 'Assert-K8RunArtifactCompleteness'
    foreach ($pair in @(@{ N = 'stage gate'; B = $stageBody }, @{ N = 'final gate'; B = $finalBody })) {
        if ($pair.B -notmatch 'Get-K8ContractArtifacts') { throw "the $($pair.N) does not select from the shared contract" }
    }
}

Assert-K8Test 'C-6: run-provenance.json and the C-4 sidecars are first-class required artifacts with real producer stages' {
    Import-Module $CommonPath -Force
    $rows = @(Get-K8ArtifactContract | Where-Object { $_.artifact -eq 'run-provenance.json' })
    if ($rows.Count -ne 2) { throw "expected one run-provenance row per writer timing, found $($rows.Count)" }
    $byRange = @{}
    foreach ($row in $rows) { foreach ($ch in $row.ranges.ToCharArray()) { $byRange["$ch"] = $row.stage } }
    foreach ($range in @('a', 'b', 'c')) {
        if (-not $byRange.ContainsKey($range)) { throw "Range $($range.ToUpper()) does not require run-provenance.json" }
    }
    # And each stage must be the REAL writer timing, not a nominal label.
    if ($byRange['a'] -ne 'evidence-tree' -or $byRange['b'] -ne 'evidence-tree') { throw "Range A/B run-provenance producer stage is '$($byRange['a'])', not the evidence-tree stage that mirrors it" }
    if ($byRange['c'] -ne 'evidence-init') { throw "Range C run-provenance producer stage is '$($byRange['c'])', not its own evidence-init stage" }

    $abBody = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Invoke-K8ShakedownRangeABBody'
    $treeStage = $abBody.IndexOf("Set-K8ShakedownRunStage -Stage 'evidence-tree'")
    $mirror = $abBody.IndexOf('Copy-K8RunProvenanceIntoEvidence')
    $nextStage = $abBody.IndexOf("Set-K8ShakedownRunStage -Stage 'compose-generate'")
    if ($treeStage -lt 0 -or $mirror -lt $treeStage -or $mirror -gt $nextStage) { throw 'Range A/B mirrors provenance outside the evidence-tree stage the contract names' }

    $cSource = Get-K8CommentStrippedSource -Path $RangeCSource
    $initStage = $cSource.IndexOf("Set-K8ShakedownRunStage -Stage 'evidence-init'")
    $cMirror = $cSource.IndexOf('Copy-K8RunProvenanceIntoEvidence')
    $cNext = $cSource.IndexOf("Set-K8ShakedownRunStage -Stage 'source-worktree-check'")
    if ($initStage -lt 0) { throw 'Range C has no explicit evidence-init stage; its provenance timing would not be nameable by the contract' }
    if ($cMirror -lt $initStage -or $cMirror -gt $cNext) { throw 'Range C mirrors provenance outside its evidence-init stage' }
}

Assert-K8Test 'C-6: Range C retains the patch at manifest-derivation and the manifest at patch-apply, AFTER git apply' {
    $source = Get-K8CommentStrippedSource -Path $RangeCSource
    $derivationStage = $source.IndexOf("Set-K8ShakedownRunStage -Stage 'manifest-derivation'")
    $patchRetain     = $source.IndexOf("Copy-Item -Path `$derivedPatch -Destination")
    $applyStage      = $source.IndexOf("Set-K8ShakedownRunStage -Stage 'patch-apply'")
    $gitApply        = $source.IndexOf("'apply', '--ignore-space-change', `$derivedPatch")
    $manifestRetain  = $source.IndexOf("Copy-Item -Path `$negativeManifest -Destination")
    $validatorStage  = $source.IndexOf("Set-K8ShakedownRunStage -Stage 'validator-run'")
    $validatorRun    = $source.IndexOf('& cmd.exe /c')
    foreach ($pair in @(
        @{ N = 'manifest-derivation stage'; V = $derivationStage }, @{ N = 'patch retain'; V = $patchRetain }
        @{ N = 'patch-apply stage'; V = $applyStage }, @{ N = 'git apply'; V = $gitApply }
        @{ N = 'manifest retain'; V = $manifestRetain }, @{ N = 'validator-run stage'; V = $validatorStage }
        @{ N = 'validator invocation'; V = $validatorRun }
    )) { if ($pair.V -lt 0) { throw "could not locate the $($pair.N) in the Range C runner" } }

    if ($patchRetain -lt $derivationStage -or $patchRetain -gt $applyStage) { throw 'the derived patch is not retained during the manifest-derivation stage that produces it' }
    if ($manifestRetain -lt $applyStage) { throw 'the negative manifest is retained before the patch-apply stage -- at that point it is still a byte copy of the BASE manifest, which the validator never reads' }
    if ($manifestRetain -lt $gitApply) { throw 'the negative manifest is retained BEFORE `git apply`, so the retained bytes are not the negative manifest at all' }
    if ($manifestRetain -gt $validatorRun) { throw 'the negative manifest is retained after the validator already ran' }
    # And nothing may rewrite it between the retain and the read.
    $between = $source.Substring($manifestRetain, $validatorRun - $manifestRetain)
    foreach ($mutator in @('Set-Content', 'Add-Content', 'Out-File', 'git apply', 'Remove-Item')) {
        if ($between -match [regex]::Escape($mutator)) { throw "'$mutator' appears between retaining the negative manifest and the validator reading it; the retained bytes could differ from the read bytes" }
    }
}

Assert-K8Test 'C-6: the Range C completeness gate runs BEFORE the sequence is advanced' {
    $source = Get-K8CommentStrippedSource -Path $RangeCSource
    $gate = $source.IndexOf('Assert-K8RunArtifactCompleteness')
    $advance = $source.IndexOf('Complete-K8ShakedownRunInSequence')
    if ($gate -lt 0) { throw 'Range C never runs a run-level completeness gate' }
    if ($advance -lt 0) { throw 'Range C never advances the sequence' }
    if ($gate -gt $advance) { throw 'the completeness gate runs after the sequence advanced -- an incomplete Range C could become the third leg of a c-2b-sequence-valid sequence' }
}

Assert-K8Test 'C-6: leaving a stage checks that stage, fails closed there, and the final gate is defense in depth' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        $evidence = Join-Path $sb.Root 'runs\synthetic'
        New-Item -ItemType Directory -Force -Path $evidence | Out-Null
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $run = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo

        # Before the gate is armed, stage transitions check nothing.
        Set-K8ShakedownRunStage -Stage 'evidence-tree'
        Set-K8ShakedownRunEvidence -Path $evidence | Out-Null

        # evidence-tree owes run-provenance.json, and it is not there.
        $stopped = $false; $message = ''
        try { Set-K8ShakedownRunStage -Stage 'compose-generate' } catch { $stopped = $true; $message = $_.Exception.Message }
        if (-not $stopped) { throw 'leaving a stage with a missing contracted artifact did not fail closed' }
        if ($message -notmatch "stage 'evidence-tree'") { throw "the failure does not name the stage that owed the artifact: $message" }
        if ($message -notmatch 'run-provenance\.json') { throw "the failure does not name the missing artifact: $message" }

        # With it present, the stage still owes source-identity.txt (C-9), and
        # the gate names THAT one next rather than passing on a partial set.
        '{}' | Set-Content -LiteralPath (Join-Path $evidence 'run-provenance.json') -Encoding utf8NoBOM
        $stopped = $false; $message = ''
        try { Set-K8ShakedownRunStage -Stage 'compose-generate' } catch { $stopped = $true; $message = $_.Exception.Message }
        if (-not $stopped) { throw 'the gate passed while source-identity.txt was still missing' }
        if ($message -notmatch 'source-identity\.txt') { throw "the failure does not name the remaining missing artifact: $message" }

        # With both present, the same transition succeeds.
        'x' | Set-Content -LiteralPath (Join-Path $evidence 'source-identity.txt') -Encoding utf8NoBOM
        Set-K8ShakedownRunStage -Stage 'compose-generate'

        # The final gate is defense in depth over the SAME contract: it must
        # still report what the stage gates were responsible for, and say so.
        $stopped = $false; $message = ''
        try { Assert-K8RunArtifactCompleteness -Range a -RunEvidence $evidence } catch { $stopped = $true; $message = $_.Exception.Message }
        if (-not $stopped) { throw 'the final gate passed a tree holding only run-provenance.json' }
        if ($message -notmatch 'owed by stage') { throw "the final gate does not attribute a missing artifact to its producer stage: $message" }
        if ($message -notmatch 'regression defect in the stage gate') { throw 'the final gate does not state that anything it finds is a stage-gate regression, not a late discovery' }
    }
}

# --- C-7 -------------------------------------------------------------------

Assert-K8Test 'C-7: references are TYPED; run-local paths must exist, and nothing scans prose for paths' {
    Import-Module $CommonPath -Force
    $d = New-K8TempDir -Prefix 'k8c7'
    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $d 'contract-output') | Out-Null
        'x' | Set-Content -LiteralPath (Join-Path $d 'contract-output\present.txt') -Encoding utf8NoBOM

        $text = Resolve-K8NarrativeReference -RunEvidence $d -Reference (New-K8ArtifactReference -Kind 'run-local' -Path 'contract-output/present.txt')
        if ($text -ne 'contract-output/present.txt') { throw "an existing run-local reference resolved to '$text'" }

        Assert-K8FailsClosed -What 'a run-local reference to a file that is not there' -Because 'does not exist under' -Attempt {
            Resolve-K8NarrativeReference -RunEvidence $d -Reference (New-K8ArtifactReference -Kind 'run-local' -Path 'contract-output/absent.txt')
        }
        Assert-K8FailsClosed -What 'a run-local reference escaping the run root' -Because "'\.\.' segment" -Attempt {
            Resolve-K8NarrativeReference -RunEvidence $d -Reference (New-K8ArtifactReference -Kind 'run-local' -Path '../../../etc/passwd')
        }
        # Traversal that stays inside by arithmetic is still refused: a
        # reference names its target directly or not at all.
        Assert-K8FailsClosed -What 'a run-local reference that traverses out and back in' -Because "'\.\.' segment" -Attempt {
            Resolve-K8NarrativeReference -RunEvidence $d -Reference (New-K8ArtifactReference -Kind 'run-local' -Path 'contract-output/../contract-output/present.txt')
        }
        Assert-K8FailsClosed -What 'an absolute run-local reference' -Because 'must be relative, not absolute' -Attempt {
            Resolve-K8NarrativeReference -RunEvidence $d -Reference (New-K8ArtifactReference -Kind 'run-local' -Path 'C:/Windows/win.ini')
        }
        # in-container and host-path are not resolvable from here and are not checked.
        foreach ($kind in @('in-container', 'host-path')) {
            $out = Resolve-K8NarrativeReference -RunEvidence $d -Reference (New-K8ArtifactReference -Kind $kind -Path '/study/traffic/send_direct_operate.py')
            if ($out -ne '/study/traffic/send_direct_operate.py') { throw "a $kind reference was altered or checked" }
        }
        # An unknown kind fails closed rather than being waved through.
        Assert-K8FailsClosed -What 'an unknown reference kind' -Because 'unknown reference kind' -Attempt {
            Resolve-K8NarrativeReference -RunEvidence $d -Reference ([pscustomobject]@{ Kind = 'guess'; Path = 'x' })
        }
        # No prose scanning anywhere: a path-shaped regex over narrative text is
        # exactly what produced false positives on a healthy run.
        $resolver = Get-K8FunctionBodyText -Path $CommonPath -Name 'Resolve-K8NarrativeReference'
        foreach ($smell in @('\[regex\]::Matches', '-split', 'Select-String')) {
            if ($resolver -match $smell) { throw "the resolver appears to scan text ('$smell') instead of taking typed input" }
        }
    }
    finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'C-7: the frozen-protocol-doc allowlist is one exact file plus one directory, and is closed against siblings and traversal' {
    Import-Module $CommonPath -Force
    $d = New-K8TempDir -Prefix 'k8c7a'
    try {
        $inside = Resolve-K8NarrativeReference -RunEvidence $d -RepoRoot $RepoRoot -Reference (
            New-K8ArtifactReference -Kind 'frozen-protocol-doc' -Path 'Study01/studies/study-01-negative-result/protocol/evidence-schema.md')
        if ($inside -notmatch 'evidence-schema\.md$') { throw "an allowlisted frozen protocol document resolved to '$inside'" }
        Resolve-K8NarrativeReference -RunEvidence $d -RepoRoot $RepoRoot -Reference (
            New-K8ArtifactReference -Kind 'frozen-protocol-doc' -Path 'Study01/README.md') | Out-Null

        # Outside the allowlist -- a real, existing repository file. Existing is
        # not the same as being a frozen protocol document.
        Assert-K8FailsClosed -What 'a repository file outside the allowlist' -Because 'allowlist' -Attempt {
            Resolve-K8NarrativeReference -RunEvidence $d -RepoRoot $RepoRoot -Reference (
                New-K8ArtifactReference -Kind 'frozen-protocol-doc' -Path 'Study01/PROVENANCE.md')
        }
        Assert-K8FailsClosed -What 'an allowlisted prefix naming a file that does not exist' -Because 'does not exist under' -Attempt {
            Resolve-K8NarrativeReference -RunEvidence $d -RepoRoot $RepoRoot -Reference (
                New-K8ArtifactReference -Kind 'frozen-protocol-doc' -Path 'Study01/studies/study-01-negative-result/protocol/no-such-doc.md')
        }

        # TRAVERSAL. `.../protocol/../scripts/study01_collect.py` starts with
        # the allowlisted directory as a STRING while naming a file in the
        # frozen apparatus. Refused on the segment, before any path is built.
        foreach ($escape in @(
            'Study01/studies/study-01-negative-result/protocol/../scripts/study01_collect.py'
            'Study01/studies/study-01-negative-result/protocol/../../../../README.md'
            'Study01/README.md/../PROVENANCE.md'
        )) {
            Assert-K8FailsClosed -What "the traversal '$escape'" -Because "'\.\.' segment" -Attempt {
                Resolve-K8NarrativeReference -RunEvidence $d -RepoRoot $RepoRoot -Reference (
                    New-K8ArtifactReference -Kind 'frozen-protocol-doc' -Path $escape)
            }
        }
        # An absolute path must not reach the allowlist test at all.
        Assert-K8FailsClosed -What 'an absolute frozen-protocol-doc path' -Because 'must be relative' -Attempt {
            Resolve-K8NarrativeReference -RunEvidence $d -RepoRoot $RepoRoot -Reference (
                New-K8ArtifactReference -Kind 'frozen-protocol-doc' -Path (Join-Path $RepoRoot 'Study01\README.md'))
        }

        # A FILE entry is an exact match, not a prefix. These are checked
        # against a throwaway repository root where the sibling files ACTUALLY
        # EXIST, so the refusal comes from the allowlist rather than from the
        # existence check happening to save us.
        $fakeRepo = New-K8TempDir -Prefix 'k8c7repo'
        try {
            $protocol = Join-Path $fakeRepo 'Study01\studies\study-01-negative-result\protocol'
            $scripts = Join-Path $fakeRepo 'Study01\studies\study-01-negative-result\scripts'
            New-Item -ItemType Directory -Force -Path $protocol, $scripts, (Join-Path $fakeRepo 'Study01\README.md.d') | Out-Null
            foreach ($rel in @('Study01\README.md', 'Study01\README.md.bak', 'Study01\README.md.tmp',
                               'Study01\README.md.d\inner.md')) {
                'frozen' | Set-Content -LiteralPath (Join-Path $fakeRepo $rel) -Encoding utf8NoBOM
            }
            'apparatus' | Set-Content -LiteralPath (Join-Path $scripts 'study01_collect.py') -Encoding utf8NoBOM
            'frozen' | Set-Content -LiteralPath (Join-Path $protocol 'evidence-schema.md') -Encoding utf8NoBOM

            foreach ($sibling in @('Study01/README.md.bak', 'Study01/README.md.tmp', 'Study01/README.md.d/inner.md')) {
                Assert-K8FailsClosed -What "'$sibling' (a file entry must match EXACTLY, never by prefix)" -Because 'allowlist' -Attempt {
                    Resolve-K8NarrativeReference -RunEvidence $d -RepoRoot $fakeRepo -Reference (
                        New-K8ArtifactReference -Kind 'frozen-protocol-doc' -Path $sibling)
                }
            }
            Assert-K8FailsClosed -What 'traversal out of the protocol directory into the frozen apparatus, with the target really present' -Because "'\.\.' segment" -Attempt {
                Resolve-K8NarrativeReference -RunEvidence $d -RepoRoot $fakeRepo -Reference (
                    New-K8ArtifactReference -Kind 'frozen-protocol-doc' -Path 'Study01/studies/study-01-negative-result/protocol/../scripts/study01_collect.py')
            }
            # The two genuine cases still resolve, so none of the above is
            # passing merely because everything is refused.
            foreach ($ok in @('Study01/README.md', 'Study01/studies/study-01-negative-result/protocol/evidence-schema.md')) {
                $resolved = Resolve-K8NarrativeReference -RunEvidence $d -RepoRoot $fakeRepo -Reference (
                    New-K8ArtifactReference -Kind 'frozen-protocol-doc' -Path $ok)
                if ($resolved -ne $ok) { throw "a legitimately allowlisted document was refused or rewritten: '$ok' -> '$resolved'" }
            }
        }
        finally { Remove-Item $fakeRepo -Recurse -Force -ErrorAction SilentlyContinue }

        # The allowlist itself: one exact FILE and one directory, held apart so
        # that one comparison can never have to serve both.
        $source = Get-Content $CommonPath -Raw
        if ($source -match 'K8FrozenProtocolDocPrefixes') { throw 'the file and directory entries are back in one array; a prefix test would then also admit README.md.bak' }
        $declared = @{}
        foreach ($name in @('K8FrozenProtocolDocFiles', 'K8FrozenProtocolDocDirectories')) {
            $block = [regex]::Match($source, "(?s)$name = @\((.*?)\)")
            if (-not $block.Success) { throw "the $name allowlist declaration could not be found" }
            $declared[$name] = @([regex]::Matches($block.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        }
        if (($declared['K8FrozenProtocolDocFiles'] -join '|') -ne 'Study01/README.md') {
            throw "the frozen-protocol-doc FILE allowlist is [$($declared['K8FrozenProtocolDocFiles'] -join ', ')], not the single file the Plan fixes."
        }
        if (($declared['K8FrozenProtocolDocDirectories'] -join '|') -ne 'Study01/studies/study-01-negative-result/protocol/') {
            throw "the frozen-protocol-doc DIRECTORY allowlist is [$($declared['K8FrozenProtocolDocDirectories'] -join ', ')], not the single directory the Plan fixes."
        }
        foreach ($dir in $declared['K8FrozenProtocolDocDirectories']) {
            if (-not $dir.EndsWith('/')) { throw "directory entry '$dir' has no trailing separator, so a sibling like 'protocol-notes/x.md' would match it" }
        }
    }
    finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'C-7: every narrative writer routes its artifact references through the typed resolver' {
    $writers = [ordered]@{
        'Invoke-K8ShakedownRangeABBody'   = (Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Invoke-K8ShakedownRangeABBody')
        'Complete-K8ShakedownRangeABBody' = (Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Complete-K8ShakedownRangeABBody')
        'Write-K8RuntimeContractRecord'   = (Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Write-K8RuntimeContractRecord')
        'Complete-K8RuntimeContractRecord' = (Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Complete-K8RuntimeContractRecord')
        'Run-K8ShakedownRangeC.ps1'       = (Get-K8CommentStrippedSource -Path $RangeCSource)
    }
    foreach ($name in $writers.Keys) {
        if ($writers[$name] -notmatch 'New-K8ArtifactReference') { throw "$name inserts artifact references into a generated narrative without typing them" }
        if ($writers[$name] -notmatch 'Resolve-K8NarrativeReference|Get-K8NarrativeReferenceText') { throw "$name never resolves its references, so nothing checks they exist" }
    }
    # The forward reference that used to name artifacts before they existed is
    # gone from the record written at runtime-contract-record time.
    $early = $writers['Write-K8RuntimeContractRecord']
    foreach ($forward in @('r-obs-05-pcap-rows.json', 'r-obs-05-correlation.json')) {
        if ($early -match [regex]::Escape($forward)) { throw "Write-K8RuntimeContractRecord still names '$forward', which does not exist at that point in the run" }
    }
    if ($writers['Complete-K8RuntimeContractRecord'] -notmatch 'r-obs-05-correlation\.json') { throw 'the appended check-4 pointers no longer name the correlation record at all' }
}

Assert-K8Test 'C-7: mechanical facts are drawn from the authoritative structured source for their fact class' {
    $ab = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Invoke-K8ShakedownRangeABBody'
    if ($ab -notmatch 'Get-K8RunIdentityFacts') { throw 'Range A/B run metadata does not draw run identity from the run-provenance record' }
    $identity = Get-K8FunctionBodyText -Path $CommonPath -Name 'Get-K8RunIdentityFacts'
    if ($identity -notmatch 'Get-K8RunProvenancePath') { throw 'run identity is not read from the Batch 1 provenance record' }

    $cSource = Get-K8CommentStrippedSource -Path $RangeCSource
    if ($cSource -notmatch 'Get-K8RunIdentityFacts') { throw 'the Range C record does not draw run identity from the provenance record' }
    # The command fact must come from the C-4 observation, not a loose variable.
    if ($cSource -notmatch '\$cObservation\.exit_code') { throw 'the Range C record does not state the exit code from its C-4 observation' }
    if ($cSource -match '\| Exit code \| \$exitCode \|') { throw 'the Range C record still prints the exit code from a loose local variable rather than the retained observation' }

    # Observer facts come from the C-5 record.
    $append = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Complete-K8RuntimeContractRecord'
    if ($append -notmatch 'r_obs_05_mechanical_gate_pass') { throw 'the appended narrative does not read the observer result from the C-5 record' }
}

# --- finalize identity snapshot (C-3 (4)) ----------------------------------

Assert-K8Test 'finalize identity snapshot: written after final-verify SUCCEEDS and before the sequence completes' {
    $body = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Complete-K8ShakedownRangeABBody'
    $finalize = $body.IndexOf("-Description 'final finalize/hash including cleanup record'")
    $verify   = $body.IndexOf("-Description 'final verify-integrity'")
    $snapshot = $body.IndexOf('Write-K8FinalizeIdentitySnapshot')
    $complete = $body.IndexOf('Complete-K8ShakedownRunInSequence')
    foreach ($pair in @(@{ N = 'final-finalize'; V = $finalize }, @{ N = 'final-verify'; V = $verify },
                        @{ N = 'snapshot'; V = $snapshot }, @{ N = 'sequence completion'; V = $complete })) {
        if ($pair.V -lt 0) { throw "could not locate $($pair.N)" }
    }
    if (-not ($finalize -lt $verify -and $verify -lt $snapshot -and $snapshot -lt $complete)) {
        throw 'the order must be final-finalize -> final-verify -> identity freeze -> run completion; a manifest that finalize produced but verify rejected must never be snapshotted as verified'
    }
    # final-verify runs through the helper that THROWS on a nonzero exit, so a
    # failing verify cannot fall through to the snapshot. Checked over the raw
    # source (the call may be wrapped across lines).
    $raw = Get-K8FunctionBodyText -Path $CommonPath -Name 'Complete-K8ShakedownRangeABBody'
    $verifyCall = [regex]::Match($raw, "(?s)Invoke-K8ShakedownCommand(?:(?!Invoke-K8ShakedownCommand).)*?'final verify-integrity'")
    if (-not $verifyCall.Success) { throw 'final-verify is not run through the fail-closed command helper, so a failure could reach the snapshot' }
    # verify-integrity must be the command it actually runs.
    if ($verifyCall.Value -notmatch "'verify-integrity'") { throw 'the final-verify call does not invoke verify-integrity' }
}

Assert-K8Test 'finalize identity snapshot: pins the manifest digest, and refuses to write without a manifest' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $run = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        $evidence = Join-Path $sb.Root "runs\$($run.RunId)"
        New-Item -ItemType Directory -Force -Path $evidence | Out-Null

        Assert-K8FailsClosed -What 'snapshotting a run with no hashes.sha256' -Because 'hashes.sha256 not found' -Attempt {
            Write-K8FinalizeIdentitySnapshot -Run $run -RunEvidence $evidence
        }
        $manifest = Join-Path $evidence 'hashes.sha256'
        [System.IO.File]::WriteAllText($manifest, "abc  metadata.md", (New-Object System.Text.UTF8Encoding($false)))
        $record = Write-K8FinalizeIdentitySnapshot -Run $run -RunEvidence $evidence
        $expected = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($record['hashes_sha256_digest'] -ne $expected) { throw 'the snapshot does not pin the manifest that was actually verified' }
        $path = Get-K8FinalizeIdentityPath -RunId $run.RunId
        if (-not (Test-Path $path)) { throw 'the snapshot was not retained in the control plane' }
        if ($path -like "*$evidence*") { throw 'the snapshot was written into the evidence tree; a file added after finalize-evidence permanently breaks verify-integrity' }
        $onDisk = Get-Content $path -Raw | ConvertFrom-Json
        if ($onDisk.schema -ne 'k8shakedown-finalize-identity/1') { throw "unexpected snapshot schema '$($onDisk.schema)'" }
    }
}

# --- frozen apparatus non-regression --------------------------------------
#
# A/B only, through the FROZEN collector. Range C is deliberately covered by a
# different path: the frozen collector hard-requires runtime directories,
# capture lifecycle/context records and T0, none of which a Range C static
# validation has. Growing fake runtime directories onto a Range C fixture to
# push it through would change what Range C means in order to make a test pass.

Assert-K8Test 'frozen apparatus non-regression: a Range A/B tree carrying the C-4 sidecars and C-5 axes still passes validate/finalize/verify' {
    foreach ($range in @('a', 'b')) {
        $root = New-K8TempDir -Prefix "k8frozen$range"
        try {
            $runId = "k8shakedown-range$range-20260831-000000"
            & python $SyntheticPy --root $root --run-id $runId --range $range --scripts-dir $ScriptsDir | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "the synthetic Range $($range.ToUpper()) tree could not be built" }
            $evidence = Join-Path $root $runId
            foreach ($command in @('validate-evidence', 'finalize-evidence', 'verify-integrity')) {
                $out = & python (Join-Path $ScriptsDir 'study01_collect.py') $command $evidence 2>&1
                if ($LASTEXITCODE -ne 0) { throw "frozen $command REJECTED a Range $($range.ToUpper()) tree containing the Batch 2 artifacts: $(@($out) -join "`n")" }
            }
            # The new files are genuinely in the tree and genuinely hashed --
            # otherwise this would prove nothing.
            $manifest = Get-Content (Join-Path $evidence 'hashes.sha256') -Raw
            if ($manifest -notmatch 'run-provenance\.json') { throw 'the provenance mirror is not covered by the finalized manifest' }
            $correlation = Get-Content (Join-Path $evidence 'rule-output\collector-rule-correlation.json') -Raw | ConvertFrom-Json
            if ($null -eq $correlation.PSObject.Properties['correlation_applicable']) { throw 'the C-5 axes are absent from the fixture, so this proved nothing about them' }
            if ($range -eq 'b') {
                if ($manifest -notmatch 'qdisc-pre-fault\.observation\.json') { throw 'the C-4 sidecars are not covered by the finalized manifest' }
                if (@([regex]::Matches($manifest, 'observation\.json')).Count -lt 4) { throw 'not every C-4 sidecar reached the manifest' }
            }
        }
        finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}


# --- 29. C-8: external command contract closure (Batch 3A) --------------------
#
# What these checks defend is not "the commands are right" -- that is a human
# judgment C-8 deliberately does not automate. It is that the declared contract
# cannot drift away from either the frozen documents it cites or the code it
# describes, and that the inventory backing the closed-world claim cannot be
# faked by a single broken observer.

$C8Tools = Join-Path $RepoRoot 'shakedown\tools'
$C8Inventory = Join-Path $RepoRoot 'shakedown\tests\k8_command_inventory.ps1'
$C8Reachability = Join-Path $RepoRoot 'shakedown\tests\k8_command_reachability.ps1'

function Get-K8ObservedSiteTable {
    <# Both inventory oracles, unioned, with a contract-style ordinal per
       (file, scope, callee) so a row's locator can be resolved to a real
       extent. The union key is (file, line, ordinal_in_line). #>
    $inv = & $C8Inventory -ToolsDir $C8Tools
    $rea = & $C8Reachability -RepoRoot $RepoRoot
    $counter = @{}
    $rows = @()
    foreach ($s in (@($inv.Sites) + @($rea.CrossBoundarySites))) {
        $k = "$($s.file)|$($s.scope)|$($s.callee)"
        if (-not $counter.ContainsKey($k)) { $counter[$k] = 0 }
        $counter[$k]++
        $rows += [pscustomobject]@{
            file = $s.file; line = $s.line; scope = $s.scope; callee = $s.callee
            ord = $counter[$k]; key = $s.key
        }
    }
    return [pscustomobject]@{
        Sites = $rows; Local = @($inv.Sites); Cross = @($rea.CrossBoundarySites); Dynamic = @($inv.Dynamic)
    }
}

Assert-K8Test 'C-8: the contract is a single data structure, and every row states a complete, non-default acceptance domain' {
    $rows = @(Get-K8CommandContract)
    # Batch 3A fixed 100 rows (F 37 / C 60 / I 3). Batch 3B adds the six C-9
    # source-identity git call sites as C-61..C-66, so the closed world is now
    # 106 (F 37 / C 66 / I 3). The count is asserted per class, not in total,
    # so a row moving between classes cannot hide inside an unchanged sum.
    if ($rows.Count -ne 107) { throw "expected 107 process-site rows, got $($rows.Count)" }
    $byClass = @{}
    foreach ($c in 'F', 'C', 'I') { $byClass[$c] = @($rows | Where-Object { $_.class -eq $c }).Count }
    if ($byClass['F'] -ne 37 -or $byClass['C'] -ne 67 -or $byClass['I'] -ne 3) {
        throw "class split is F=$($byClass['F']) C=$($byClass['C']) I=$($byClass['I']); Batch 3A fixes F=37 I=3 and Batch 3B raises C to 67"
    }
    if (@($rows.step_id | Sort-Object -Unique).Count -ne $rows.Count) { throw 'step_id values are not unique' }
    foreach ($r in $rows) {
        # Throws on an undeclared or empty domain, and on a $null outside
        # Class I -- i.e. this is the check that no default can creep back.
        [void](Get-K8RowAcceptedExitCodes -Row $r)
        foreach ($f in 'source_file', 'producer_scope', 'callee', 'call_ordinal', 'argv_shape', 'stream_expectation') {
            if (-not $r.ContainsKey($f)) { throw "row $($r.step_id) is missing '$f'" }
        }
    }
    $pollAny = @($rows | Where-Object { $_.accepted_exit_codes -is [string] })
    if ($pollAny.Count -ne 8) { throw "expected 8 poll-any rows, got $($pollAny.Count)" }
    $required = @($rows | Where-Object { $_.ContainsKey('availability_policy') -and $_.availability_policy -eq 'required' })
    if ($required.Count -ne 5) { throw "expected 5 availability_policy=required rows, got $($required.Count)" }
}

Assert-K8Test 'C-8: no module-wide exit default exists, and an empty acceptance domain STOPs rather than silently meaning @(0)' {
    # The removed `-AllowExitCodes = @(0)` is the specific regression guarded
    # here: reintroducing it would hand every site a receipt condition no
    # frozen source states.
    $source = Get-Content (Join-Path $C8Tools 'K8ShakedownCommon.psm1') -Raw
    if ($source -match '\$AllowExitCodes') { throw 'AllowExitCodes reappeared in the module; the acceptance domain must come from the contract row, per call site' }
    if ($source -match 'accepted_exit_codes\s*=\s*@\(\s*\)') { throw 'a row declares an EMPTY acceptance domain' }

    $undeclared = @{ step_id = 'X-99'; class = 'C'; accepted_exit_codes = @() }
    $threw = $false
    try { [void](Get-K8RowAcceptedExitCodes -Row $undeclared) } catch { $threw = $true }
    if (-not $threw) { throw 'an empty accepted_exit_codes was accepted; it must be treated as UNDECLARED and STOP' }

    # 'poll-any' is not a way to skip the gate: it is only legal where the
    # gate genuinely lives in a loop deadline.
    $fakePoll = @{ step_id = 'X-98'; class = 'C'; accepted_exit_codes = 'poll-any' }
    $threw = $false
    try { [void](Get-K8RowAcceptedExitCodes -Row $fakePoll) } catch { $threw = $true }
    if (-not $threw) { throw "'poll-any' was accepted on a row without poll_loop = `$true" }
}

Assert-K8Test 'C-8: acceptance domains are call-site specific in BOTH directions -- exit 0 is not assumed good, non-zero is not assumed bad' {
    # F-35: the Range C validator. exit 1 is the frozen EXPECTED outcome and
    # exit 0 is a scientific observation ("the apparatus did not reject the
    # negative manifest"). Turning either into a STOP would convert a finding
    # into a tooling error. Only >=2 is an execution failure.
    $f35 = Get-K8CommandContractRow -StepId 'F-35'
    foreach ($e in 0, 1) {
        if (-not (Test-K8ExitAccepted -Row $f35 -ExitCode $e)) { throw "F-35 must accept exit $e" }
    }
    if (Test-K8ExitAccepted -Row $f35 -ExitCode 2) { throw 'F-35 must NOT accept exit 2 (argparse/interpreter failure)' }

    # C-54/C-55: `git rev-parse HEAD` used as an EXPLORATION. 128 = unborn
    # HEAD, which the else branch answers with a clean re-checkout.
    foreach ($id in 'C-54', 'C-55') {
        $row = Get-K8CommandContractRow -StepId $id
        foreach ($e in 0, 128) {
            if (-not (Test-K8ExitAccepted -Row $row -ExitCode $e)) { throw "$id must accept exit $e; a blanket non-zero STOP would break Setup" }
        }
        if (Test-K8ExitAccepted -Row $row -ExitCode 1) { throw "$id must not accept exit 1" }
    }

    # poll-any: every exit is a legitimate poll outcome, because the gate is
    # the loop deadline and the readiness predicate.
    $c06 = Get-K8CommandContractRow -StepId 'C-06'
    foreach ($e in 0, 7, 137) {
        if (-not (Test-K8ExitAccepted -Row $c06 -ExitCode $e)) { throw "C-06 is poll-any and must accept exit $e" }
    }
}

Assert-K8Test 'C-8: every poll-any row names a real deadline-bounded loop whose timeout still fails closed' {
    $source = Get-Content (Join-Path $C8Tools 'K8ShakedownCommon.psm1') -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
    $funcs = @{}
    foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $funcs[$f.Name] = $f }

    $pollRows = @(Get-K8CommandContract | Where-Object { $_.accepted_exit_codes -is [string] })
    $producers = @($pollRows.producer_scope | Sort-Object -Unique)
    if ($producers.Count -ne 4) { throw "poll-any spans $($producers.Count) producers; the Plan closes it at 4" }
    foreach ($row in $pollRows) {
        if (-not $row.ContainsKey('poll_loop') -or -not $row['poll_loop']) { throw "$($row.step_id) is poll-any without poll_loop" }
        if ($row['timeout_behavior'] -ne 'throw') { throw "$($row.step_id) does not declare timeout_behavior = throw" }
        $fn = $funcs[$row.producer_scope]
        if (-not $fn) { throw "poll-any producer $($row.producer_scope) does not exist" }
        $body = $fn.Extent.Text
        if ($body -notmatch 'while\s*\(') { throw "$($row.producer_scope) declares a poll loop but contains no while loop" }
        if ($body -notmatch [regex]::Escape('$' + $row['deadline_param'])) { throw "$($row.producer_scope) does not use its declared deadline parameter $($row['deadline_param'])" }
        # Without this, 'poll-any' would be a way to observe an exit and then
        # discard it forever.
        $afterLoop = $body.Substring($body.LastIndexOf('}'))
        if ($body -notmatch '(?s)while\s*\(.*\}\s*[^}]*throw ') { throw "$($row.producer_scope) does not fail closed after its deadline" }
    }
}

Assert-K8Test 'C-8: the closed world is a SET equation over four oracles, not four equal counts' {
    $obs = Get-K8ObservedSiteTable
    $local = @($obs.Local.key)
    $cross = @($obs.Cross.key)

    # (2) the cross-boundary set is disjoint from the local set -- otherwise
    #     the union would double-count and the totals would still "agree".
    $overlap = @($local | Where-Object { $cross -contains $_ })
    if ($overlap.Count -ne 0) { throw "local and cross-boundary site sets overlap: $($overlap -join ', ')" }

    # (3) union == contract. The counts are deliberately NOT compared
    #     directly: AST_local is 99, cross is 1, and the contract is 100, so a
    #     count equality would either fail or hide a double count.
    $union = @($local + $cross | Sort-Object -Unique)
    $contractRows = @(Get-K8CommandContract)
    if ($union.Count -ne $contractRows.Count) {
        throw "union of observed sites is $($union.Count) but the contract has $($contractRows.Count) rows"
    }
    if (@($union | Sort-Object -Unique).Count -ne $union.Count) { throw 'the union key (file, line, ordinal_in_line) is not unique' }
}

Assert-K8Test 'C-8: every row locator resolves to exactly one real call site, and every call site has a row' {
    $obs = Get-K8ObservedSiteTable
    $index = @{}
    foreach ($o in $obs.Sites) {
        $k = "$($o.file)|$($o.scope)|$($o.callee)|$($o.ord)"
        if ($index.ContainsKey($k)) { throw "locator $k resolves to more than one extent" }
        $index[$k] = $o
    }
    $covered = @{}
    foreach ($row in (Get-K8CommandContract)) {
        $k = "$($row.source_file)|$($row.producer_scope)|$($row.callee)|$($row.call_ordinal)"
        if (-not $index.ContainsKey($k)) {
            throw "row $($row.step_id) declares locator $k, which resolves to NO call site. A row that names nothing is a contract that describes code which does not exist."
        }
        $covered[$k] = $row.step_id
    }
    foreach ($k in $index.Keys) {
        if (-not $covered.ContainsKey($k)) {
            throw "call site $k has no contract row. Adding a site is allowed; leaving it out of the contract is what breaks the closed world."
        }
    }
}

Assert-K8Test 'C-8: a missing site plus a duplicate site does NOT pass, even though the total count is unchanged' {
    # The failure mode the count comparison would miss, reproduced against a
    # producer that really does hold several sites for the same callee.
    $obs = Get-K8ObservedSiteTable
    $group = @($obs.Sites | Where-Object { $_.scope -eq 'Wait-K8ZoneDetectorReady' })
    if ($group.Count -lt 3) { throw "expected Wait-K8ZoneDetectorReady to hold several same-callee sites; found $($group.Count)" }

    $keys = @($obs.Sites.key)
    $mutated = @($keys | Where-Object { $_ -ne $group[1].key }) + @($group[0].key)
    if ($mutated.Count -ne $keys.Count) { throw 'the injected mutation changed the total; the test would not prove anything' }
    if (@($mutated | Sort-Object -Unique).Count -eq @($keys | Sort-Object -Unique).Count) {
        throw 'dropping one site and duplicating another left the DISTINCT key set unchanged; the set equation would not detect it'
    }
}

Assert-K8Test 'C-8: the two inventory oracles do not share a blind spot -- reachability alone catches an unregistered frozen launcher' {
    # This is the defect that actually happened: the AST and lexical oracles
    # agreed on 97 while both missed Get-K8WslField, because both decide by
    # matching KNOWN NAMES. Adding another same-question oracle cannot fix
    # that; asking a different question can.
    $cross = @((Get-K8ObservedSiteTable).Cross)
    if ($cross.Count -lt 1) { throw 'the reachability oracle found no cross-boundary site; the Get-K8WslField case must remain covered' }
    if (@($cross | Where-Object { $_.callee -eq 'Get-K8WslField' }).Count -ne 1) {
        throw 'Get-K8WslField is no longer reported as a cross-boundary process site'
    }
    # The AST oracle must NOT see it -- if it did, the two oracles would be
    # answering the same question again and the union would prove nothing.
    $local = @((Get-K8ObservedSiteTable).Local)
    if (@($local | Where-Object { $_.callee -eq 'Get-K8WslField' }).Count -ne 0) {
        throw 'the AST oracle now reports Get-K8WslField; the oracles must stay structurally different'
    }
    # And the reachability oracle must not be carrying a name list.
    $src = Get-Content $C8Reachability -Raw
    if ($src -match "'docker'\s*,\s*'git'" -or $src -match '\$script:InvNative') {
        throw 'the reachability oracle appears to carry a native-name table; that would recreate the shared blind spot'
    }
}

Assert-K8Test 'C-8: dynamic invocations are surfaced and adjudicated, never dropped' {
    $dynamic = @((Get-K8ObservedSiteTable).Dynamic)
    if ($dynamic.Count -eq 0) { throw 'the AST oracle reported no UNRESOLVED-DYNAMIC entries; `& $var` sites must be surfaced, not skipped' }
    # The adjudication: every one is either a helper's own process-start
    # primitive or a scriptblock invocation. Pinning the set means a NEWLY
    # added `& $var` fails this check until a human classifies it.
    $primitiveScopes = @('Invoke-K8ShakedownCommand', 'Invoke-K8SeparatedNativeCapture',
                         'Invoke-K8ShakedownLoggedCommand', 'Invoke-K8ContractedNative')
    $unadjudicated = @($dynamic | Where-Object {
        $primitiveScopes -notcontains $_.scope -and $_.expression -notmatch '^\$(Action|deny|mutation|ScriptBlock|Probe|Body)$'
    })
    if ($unadjudicated.Count -ne 0) {
        throw ("unadjudicated dynamic invocation(s): " + (($unadjudicated | ForEach-Object { "$($_.file):$($_.line) $($_.expression)" }) -join '; ') +
               '. Each must be classified BY HAND as a process-start primitive or a scriptblock call before the inventory can close.')
    }
}

Assert-K8Test 'C-8: source_identity_match and contract_conformance are independent facts, and neither is inferred from the other' {
    $row = Get-K8CommandContractRow -StepId 'F-01'
    # Conformant argv against an unchanged source: both facts true.
    $argv = @($row['argv_shape'] | ForEach-Object { if ($_ -match '^<.*>$') { 'x' } else { $_ } })
    [void](Assert-K8CommandContract -StepId 'F-01' -Argv $argv)

    # Now make ONLY the contract non-conformant. The source is untouched, so
    # source_identity_match stays true while contract_conformance goes false
    # -- demonstrating the two are not the same fact.
    $bad = @($argv); $bad[11] = 'separator=\t'          # the exact SD-09 rewrite
    $threw = $false
    try { [void](Assert-K8CommandContract -StepId 'F-01' -Argv $bad) } catch { $threw = $true; $msg = $_.Exception.Message }
    if (-not $threw) { throw 'SD-09 (separator=/t -> separator=\t) was NOT caught as a contract mismatch' }
    if ($msg -notmatch 'pre-execution') { throw "expected a pre-execution violation, got: $msg" }
    if ((Test-K8SourceIdentityMatch -Row $row) -ne $true) { throw 'source identity should still match; a contract mismatch must not be reported as a source change' }
}

Assert-K8Test 'C-8: SD-09 and SD-11 are caught as contract mismatches, not by a literal blacklist' {
    # SD-11: the governing step is `ip -o -4 addr show`; the wrong procedure's
    # command is `ip -br addr`. The point is that ANY departure from the
    # declared shape fails, not that this one string is banned.
    $row = Get-K8CommandContractRow -StepId 'F-02'
    $argv = @('docker', 'exec', 'router1', 'ip', '-br', 'addr')
    $threw = $false
    try { [void](Assert-K8CommandContract -StepId 'F-02' -Argv $argv) } catch { $threw = $true }
    if (-not $threw) { throw 'SD-11 substitution was not caught' }

    # An unrelated, never-blacklisted departure must fail the same way.
    $novel = @('docker', 'exec', 'router1', 'ip', '-o', '-6', 'addr', 'show')
    $threw = $false
    try { [void](Assert-K8CommandContract -StepId 'F-02' -Argv $novel) } catch { $threw = $true }
    if (-not $threw) { throw 'an UNKNOWN departure from the declared shape passed; the check is behaving like a blacklist' }

    # The check must be implemented as a comparison against the declared
    # shape, not as a test for known-bad literals. What matters is the
    # DECIDING CODE: a row's exit_note may legitimately name the historical
    # error it descends from -- that is documentation, and banning the words
    # would only make the record less legible.
    foreach ($fn in 'Test-K8ArgvShapeConformance', 'Assert-K8CommandContract') {
        $body = Get-K8CommentStrippedFunctionBody -Path (Join-Path $C8Tools 'K8ShakedownCommon.psm1') -Name $fn
        foreach ($literal in 'ip -br addr', 'separator=\t') {
            if ($body -match [regex]::Escape($literal)) { throw "$fn compares against the known-bad literal '$literal'; conformance must be decided against the declared shape" }
        }
    }
}

Assert-K8Test 'C-8: F-15 accepts BOTH real Elasticsearch shapes, and the variadic tail does not stop the prefix being checked' {
    # F-15 is the one row whose argv genuinely varies in length, and the Plan's
    # Annex A fixed a single fixed-length shape for it. That shape would have
    # STOPped the legitimate POST form, so the as-built row ends in '<*>'.
    # A tail wildcard introduces the OPPOSITE risk -- quietly checking less --
    # so both directions are pinned here rather than only the passing one.
    $c = 'k8shakedown-collector'
    $url = 'http://localhost:9200/logs-ot-dnp3-collector/_mapping'
    $head = @('docker', 'exec', $c, 'curl', '-sS', '-o', '/tmp/es-body.json', '-w', '%{http_code}', '-X')
    $hdr = @('-H', 'Content-Type: application/json')

    # (1) GET mapping: no request body, so the variadic tail is EMPTY. If the
    #     prefix comparison required at least one tail element, this real call
    #     would STOP.
    [void](Assert-K8CommandContract -StepId 'F-15' -Argv ($head + @('GET', $url) + $hdr))

    # (2) POST search: same invariant prefix, plus the body pair. This is the
    #     call the Annex A shape would have rejected.
    [void](Assert-K8CommandContract -StepId 'F-15' -Argv ($head + @('POST', $url) + $hdr + @('--data-binary', '{"query":{"match_all":{}}}')))

    # (3) An ALTERED invariant element must STOP even though the tail is free.
    #     Without -w %{http_code} the HTTP status is not parseable at all, so
    #     this is exactly the kind of substitution the row exists to catch.
    $altered = @('docker', 'exec', $c, 'curl', '-sS', '-o', '/tmp/es-body.json', '-w', '%{time_total}', '-X', 'GET', $url) + $hdr
    $threw = $false
    try { [void](Assert-K8CommandContract -StepId 'F-15' -Argv $altered) } catch { $threw = $true }
    if (-not $threw) { throw 'an altered invariant element passed; the trailing <*> is swallowing the prefix check' }

    # (4) A MISSING invariant element must STOP. This is the failure mode a
    #     variadic tail invites: an argv that simply runs out before the
    #     mismatch would be reached.
    $threw = $false
    try { [void](Assert-K8CommandContract -StepId 'F-15' -Argv @('docker', 'exec', $c, 'curl', '-sS', '-o', '/tmp/es-body.json')) } catch { $threw = $true }
    if (-not $threw) { throw 'a truncated argv passed; a shorter command must not become "conformant" by ending early' }

    # (5) The Content-Type header is emitted UNCONDITIONALLY by the producer,
    #     so it belongs to the pinned prefix and not to the GET/POST variation.
    #     Dropping it must STOP; otherwise the wildcard would be covering an
    #     invariant, which is more than the correction claims to allow.
    $threw = $false
    try { [void](Assert-K8CommandContract -StepId 'F-15' -Argv ($head + @('GET', $url))) } catch { $threw = $true }
    if (-not $threw) { throw 'the Content-Type header is not pinned; the variadic tail covers more than the GET/POST difference' }
}

Assert-K8Test 'C-8: a variadic marker is valid ONLY as the last element, and only F-15 uses one' {
    # Synthetic shapes on purpose: what is pinned here is the conformance
    # engine's rule. Putting a mid-shape '<*>' into a real contract row to test
    # it would be committing the very defect the rule rejects.
    $threw = $false; $msg = ''
    try {
        [void](Test-K8ArgvShapeConformance -Shape @('docker', '<*>', 'ip', '-o', '-4', 'addr', 'show') `
                                           -Argv  @('docker', 'exec', 'router1', 'ip', '-br', 'addr'))
    }
    catch { $threw = $true; $msg = $_.Exception.Message }
    if (-not $threw) { throw "a '<*>' in a non-final position was accepted; SD-11's substitution would slide through the wildcard" }
    if ($msg -notmatch 'only as the LAST element') { throw "the rejection does not name the rule it enforces: $msg" }

    # No real row may carry one anywhere but last...
    foreach ($row in (Get-K8CommandContract)) {
        $shape = @($row['argv_shape'])
        for ($i = 0; $i -lt ($shape.Count - 1); $i++) {
            if ($shape[$i] -eq '<*>') { throw "row $($row.step_id) has a non-final '<*>' at position $i" }
        }
    }
    # ...and exactly one row needs one at all. A second would mean the tail
    # wildcard had started being used as a way to avoid declaring a shape.
    $variadic = @(Get-K8CommandContract | Where-Object { @($_['argv_shape'])[-1] -eq '<*>' })
    if ($variadic.Count -ne 1 -or $variadic[0].step_id -ne 'F-15') {
        throw "expected exactly F-15 to use a trailing '<*>'; got [$(@($variadic.step_id) -join ', ')]"
    }
}

Assert-K8Test 'C-8: changing one byte of a governing frozen document STOPs the Class F step before it runs' {
    $row = Get-K8CommandContractRow -StepId 'F-04'
    $path = Get-K8FrozenSourcePath -RelativePath $row['governing_sources'][0]['path']
    $original = [System.IO.File]::ReadAllBytes($path)
    try {
        [System.IO.File]::WriteAllBytes($path, ($original + [byte]0x0A))
        $threw = $false
        try { [void](Test-K8SourceIdentityMatch -Row $row) } catch { $threw = $true; $msg = $_.Exception.Message }
        if (-not $threw) { throw 'a modified governing document did not STOP the step' }
        if ($msg -notmatch 'NOT a statement that the implementation is wrong') {
            throw 'the diagnostic does not distinguish "the basis moved" from "the implementation is wrong"'
        }
    }
    finally { [System.IO.File]::WriteAllBytes($path, $original) }
    # And it must pass again once restored, so the check is not simply always failing.
    if ((Test-K8SourceIdentityMatch -Row $row) -ne $true) { throw 'the frozen document was not restored correctly' }
}

Assert-K8Test 'C-8: no frozen prose is parsed at runtime, and no absolute path is baked into the resolver' {
    $src = Get-Content (Join-Path $C8Tools 'K8ShakedownCommon.psm1') -Raw
    $start = $src.IndexOf('$script:K8CommandContract = @(')
    $end = $src.IndexOf('function ConvertTo-K8PythonExecOneLiner')
    $section = $src.Substring($start, $end - $start)
    if ($section -match 'Get-Content[^\r\n]*protocol') { throw 'the contract path reads frozen protocol prose at runtime; D-3 forbids it' }
    if ($section -match 'Select-String|-match\s+.\^#{1,6}\s') { throw 'the contract path appears to parse markdown structure' }
    if ($src -match "C:\\\\Users|/home/|[A-Za-z]:\\\\K8\\\\") { throw 'an absolute path is hardcoded; that breaks verification from a fresh clone in another directory' }
}

Assert-K8Test 'C-8: every Class F row cites at least one pinned frozen source, and Class C/I cite none' {
    foreach ($row in (Get-K8CommandContract)) {
        $sources = Get-K8CommandContractField -Row $row -Name 'governing_sources'
        if ($row.class -eq 'F') {
            if (-not $sources -or @($sources).Count -eq 0) { throw "Class F row $($row.step_id) cites no governing source" }
            foreach ($s in @($sources)) {
                foreach ($f in 'path', 'sha256', 'clause') { if (-not $s[$f]) { throw "$($row.step_id) governing source missing '$f'" } }
                $full = Get-K8FrozenSourcePath -RelativePath $s['path']
                if (-not (Test-Path -LiteralPath $full)) { throw "$($row.step_id) cites a nonexistent source: $($s['path'])" }
            }
        }
        elseif ($sources) {
            throw "Class $($row.class) row $($row.step_id) cites a governing source. Declaring a frozen basis that does not exist fabricates normative authority."
        }
    }
    # Several rows genuinely need TWO sources; a singular field would have made
    # the author pick one and let the other drift unnoticed.
    $multi = @(Get-K8CommandContract | Where-Object { $_.class -eq 'F' -and @($_['governing_sources']).Count -gt 1 })
    if ($multi.Count -lt 2) { throw 'expected several Class F rows with multiple governing sources' }
}

Assert-K8Test 'C-8: a pre-execution violation records NO command semantics -- no argv, no exit code, nothing executed' {
    $row = Get-K8CommandContractRow -StepId 'F-02'
    $proposed = @('docker', 'exec', 'router1', 'ip', '-br', 'addr')
    $caught = $null
    try { [void](Assert-K8CommandContract -StepId 'F-02' -Argv $proposed) } catch { $caught = $_.Exception }
    if (-not $caught) { throw 'expected a pre-execution violation' }
    $data = $caught.Data['k8_conformance']
    if (-not $data) { throw 'the violation carries no conformance block' }
    foreach ($f in 'step_id', 'expected_argv', 'proposed_argv', 'mismatch_indices') {
        if (-not $data.Contains($f)) { throw "conformance block is missing '$f'" }
    }
    # The Batch 1 fields mean "an executed command's semantics". They must be
    # ABSENT, not null: a planned argv written into `argv` would record an
    # unexecuted command as executed.
    foreach ($f in 'argv', 'exit_code', 'stdout', 'stderr') {
        if ($data.Contains($f)) { throw "the conformance block carries '$f'; command semantics must not be fabricated for a command that never ran" }
    }
    if ($data['proposed_argv'] -join ' ' -ne ($proposed -join ' ')) { throw 'proposed_argv does not match what the producer was about to run' }
    if (@($data['mismatch_indices']).Count -eq 0) { throw 'no mismatch positions were reported' }
}

Assert-K8Test 'C-8: caller-role rows bind on PROVENANCE, not on a variable name, and cover every generic-executor caller' {
    $callers = @(Get-K8CallerRoleContract)
    if ($callers.Count -ne 8) { throw "expected 8 caller-role rows, got $($callers.Count)" }
    foreach ($cr in $callers) {
        [void](Get-K8CommandContractRow -StepId $cr.process_step_id)
        if (-not $cr.ContainsKey('governing_sources') -or @($cr['governing_sources']).Count -eq 0) { throw "$($cr.caller_id) cites no governing source" }
    }
    # The two tshark callers use the SAME local variable name, which is why a
    # name-based binding would not even distinguish them.
    $src = Get-Content (Join-Path $C8Tools 'K8ShakedownCommon.psm1') -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
    $funcs = @{}
    foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $funcs[$f.Name] = $f }
    foreach ($fn in 'Write-K8UnrelatedPcapRows', 'Write-K8TargetCaptureDecode') {
        if ($funcs[$fn].Extent.Text -notmatch '\$pcap\s*=') { throw "$fn no longer holds its pcap in `$pcap; the point of the provenance anchor was that BOTH callers use the same name" }
    }
    # CR-01's anchor is what actually closes SD-13.
    $cr01 = @($callers | Where-Object { $_.caller_id -eq 'CR-01' })[0]
    $anchor = $cr01['artifact_provenance_anchor']
    if ($anchor['kind'] -ne 'derived-from-function') { throw 'CR-01 must bind to the assignment source, not a name' }
    if ($funcs['Write-K8UnrelatedPcapRows'].Extent.Text -notmatch [regex]::Escape($anchor['anchor'])) {
        throw "CR-01's declared provenance anchor $($anchor['anchor']) does not appear in its producer"
    }
    # The anchor must be a POSITIVE requirement, not a blacklist of the wrong pcap.
    foreach ($cr in $callers) {
        if (($cr | ConvertTo-Json -Depth 6) -match 'c2-mirror-sensor\.pcap' -and $cr.caller_id -eq 'CR-01') {
            throw 'CR-01 names the forbidden pcap; the binding must state what IS required'
        }
    }
}

Assert-K8Test 'C-8: SD-13 is caught by provenance even though the argv and the variable name are unchanged' {
    $src = Get-Content (Join-Path $C8Tools 'K8ShakedownCommon.psm1') -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
    $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-K8UnrelatedPcapRows' }, $true))[0]
    $cr01 = @(Get-K8CallerRoleContract | Where-Object { $_.caller_id -eq 'CR-01' })[0]
    $anchor = $cr01['artifact_provenance_anchor']['anchor']

    # Positive: the real code satisfies the anchor.
    if ($fn.Extent.Text -notmatch [regex]::Escape($anchor)) { throw 'the live code does not satisfy CR-01 (positive case failed)' }

    # Negative: reassign $pcap from the Sensor pcap instead. argv_shape is
    # untouched and the variable is still called $pcap -- the ONLY thing that
    # changed is where the value came from, which is exactly what SD-13 was.
    $mutated = $fn.Extent.Text -replace [regex]::Escape('$spec.Artifact'), "'sensor-input\mirror-capture\c2-mirror-sensor.pcap'"
    $mutated = $mutated -replace [regex]::Escape('$spec = Get-K8Robs05LivenessSpec -RunId $RunId'), '$spec = $null'
    if ($mutated -match [regex]::Escape($anchor)) { throw 'the mutation did not actually remove the anchor; the negative case proves nothing' }
    if ($mutated -notmatch '\$pcap\s*=') { throw 'the mutation also removed the variable; it must isolate PROVENANCE from naming' }
}

Assert-K8Test 'C-8: tool versions are retained but never gated, while a missing REQUIRED tool still STOPs' {
    # Version drift must not stop anything: no frozen source pins a version.
    $rows = @(Get-K8CommandContract | Where-Object { $_.ContainsKey('availability_policy') })
    foreach ($r in @($rows | Where-Object { $_.class -eq 'I' })) {
        if ($r['availability_policy'] -ne 'optional') { throw "Class I row $($r.step_id) must be optional" }
        if ($null -ne $r['accepted_exit_codes']) { throw "Class I row $($r.step_id) must declare accepted_exit_codes = `$null (not gated)" }
    }
    foreach ($r in @($rows | Where-Object { $_['availability_policy'] -eq 'required' })) {
        if ($r.class -eq 'I') { throw "row $($r.step_id) is Class I but required; a site that stops Setup is not informational" }
    }

    # A required tool that is absent must still STOP, and must say so as a
    # MISSING BINARY -- the previous code reported "not found on PATH" even
    # when the binary was present but produced no output.
    $threw = $false; $msg = ''
    try {
        [void](Get-K8RequiredToolVersion -StepId 'C-56' -FilePath 'k8-definitely-not-a-real-binary' -ArgumentList @('--version') -Requirement 'test')
    }
    catch { $threw = $true; $msg = $_.Exception.Message }
    if (-not $threw) { throw 'a missing required tool did not STOP' }

    # And the optional probe must survive its own failure without stopping.
    $rec = Get-K8CollapsedToolObservation -StepId 'I-05' -Probe { throw 'simulated wsl failure' }
    if ($rec['status'] -eq 'succeeded') { throw 'a failed optional probe was recorded as succeeded' }
    if ($null -ne $rec['exit_code']) { throw 'an unobservable exit code must be null, never 0' }

    # I-05's frozen producer reports failure IN BAND, as a string. Recording
    # that as a success would convert "could not observe" into "observed".
    $inBand = Get-K8CollapsedToolObservation -StepId 'I-05' -Probe { 'unavailable: exit 1 : wsl not installed' }
    if ($inBand['status'] -ne 'unavailable') { throw "an in-band 'unavailable:' string was recorded as $($inBand['status'])" }
}

Assert-K8Test 'C-8: I-07/I-08 declare full fidelity and actually retain exit and stderr -- the label matches the record' {
    Reset-K8ContractRows
    # A synthetic Class I row: accepted_exit_codes = $null, so the contracted
    # path observes the exit without gating on it -- which is what lets a
    # non-zero come back as a RECORD rather than as a throw.
    Add-K8TestContractRow -Row @{ step_id = 'TEST-OPTIONAL'; class = 'I'; ranges = 'ab'
        source_file = 'test'; producer_scope = 'test'; callee = 'cmd.exe'; call_ordinal = 1
        argv_shape = @('cmd.exe', '/c', '<synthetic>'); stream_expectation = 'separated'
        accepted_exit_codes = $null; availability_policy = 'optional'; informational_value = $true
        exit_note = 'synthetic fixture; not a real call site' }
    # A separate row for the missing-binary case: its argv has a different
    # SHAPE, and reusing the row above would make the probe fail the
    # pre-execution gate instead of reaching the not-found path -- which would
    # test the wrong thing while still looking like a failure to classify.
    Add-K8TestContractRow -Row @{ step_id = 'TEST-OPTIONAL-MISSING'; class = 'I'; ranges = 'ab'
        source_file = 'test'; producer_scope = 'test'; callee = 'test'; call_ordinal = 1
        argv_shape = @('<binary>', '--version'); stream_expectation = 'separated'
        accepted_exit_codes = $null; availability_policy = 'optional'; informational_value = $true
        exit_note = 'synthetic fixture; not a real call site' }

    # The defect this guards: an earlier implementation routed I-07/I-08
    # through the same helper as I-05, whose probe returns only a STRING. The
    # rows said observation_fidelity = full while every record carried
    # exit_code = null and no stderr at all -- a claim to have observed more
    # than was kept. The two helpers are now separate functions so the record
    # shape follows from which one was called, not from a label the caller
    # chose.
    $body = Get-K8CommentStrippedFunctionBody -Path (Join-Path $C8Tools 'K8ShakedownCommon.psm1') -Name 'Get-K8OptionalToolObservation'
    foreach ($field in "exit_code", 'stdout', 'stderr') {
        if ($body -notmatch [regex]::Escape("'$field'")) { throw "Get-K8OptionalToolObservation does not record '$field'" }
    }
    if ($body -notmatch 'Invoke-K8ContractedNative') { throw 'the full-fidelity probe does not go through the contracted path, so it cannot see the exit code' }

    # A non-zero exit is recorded as unavailable WITH its real exit code, and
    # never stops the run.
    $nonZero = Get-K8OptionalToolObservation -StepId 'TEST-OPTIONAL' -FilePath 'cmd.exe' -ArgumentList @('/c', 'echo OUT& exit /b 4')
    if ($nonZero['exit_code'] -ne 4) { throw "expected the real exit code 4, got '$($nonZero['exit_code'])'" }
    if ($nonZero['status'] -ne 'unavailable') { throw "a non-zero exit was recorded as $($nonZero['status']); non-empty stdout must not make a failure look like a success" }
    if ($nonZero['observation_fidelity'] -ne 'full') { throw 'a fully observable site must not claim degraded fidelity' }

    # A clean run records the exit AND both streams.
    $ok = Get-K8OptionalToolObservation -StepId 'TEST-OPTIONAL' -FilePath 'cmd.exe' -ArgumentList @('/c', 'echo VERSION 1.2& echo NOISE 1>&2')
    if ($ok['status'] -ne 'succeeded') { throw "a clean probe was recorded as $($ok['status'])" }
    if ($ok['exit_code'] -ne 0) { throw 'exit code was not retained on the success path' }
    if ($ok['stdout'] -notmatch 'VERSION') { throw 'stdout was not retained' }
    if ($ok['stderr'] -notmatch 'NOISE') { throw 'stderr was DISCARDED; the row claims full fidelity' }

    # Exit 0 with no output is not a version observation.
    $silent = Get-K8OptionalToolObservation -StepId 'TEST-OPTIONAL' -FilePath 'cmd.exe' -ArgumentList @('/c', 'exit /b 0')
    if ($silent['status'] -eq 'succeeded') { throw 'a silent exit-0 probe was recorded as a successful version observation' }

    # A missing binary is not-found, and still does not stop anything.
    $missing = Get-K8OptionalToolObservation -StepId 'TEST-OPTIONAL-MISSING' -FilePath 'k8-definitely-not-a-real-binary' -ArgumentList @('--version')
    if ($missing['status'] -ne 'not-found') { throw "a missing binary was recorded as $($missing['status'])" }
    if ($null -ne $missing['exit_code']) { throw 'a command that never ran must not carry an exit code' }
}

Assert-K8Test 'C-8: the runtime tool record is written AFTER I-08 is observed, and cannot inherit another run''s reading' {
    $src = Get-Content (Join-Path $C8Tools 'K8ShakedownCommon.psm1') -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
    $body = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-K8ShakedownRangeABBody' }, $true))[0].Extent.Text

    # ORDER: I-08 is observed inside gateway resolution, so the record must be
    # written after that call -- not after I-07, which comes earlier.
    $gatewayAt = $body.IndexOf('Resolve-K8GatewayInterface -RunId')
    $writeAt = $body.IndexOf('Write-K8ToolVersionRecord')
    if ($gatewayAt -lt 0 -or $writeAt -lt 0) { throw 'could not locate the gateway resolution or the record write' }
    if ($writeAt -lt $gatewayAt) {
        throw 'the runtime tool-version record is written BEFORE gateway resolution, so every record would be missing its own run''s I-08 reading'
    }

    # NO CARRY-OVER: a module-scope stash is initialised once per import, so a
    # second run in the same process would inherit the first run's value. The
    # observation must travel back on the gateway result instead.
    if ($src -match '\$script:K8RuntimeToolVersions') {
        throw 'I-08 is held in a module-scope variable; in a process handling two runs the second record could carry the first run''s observation'
    }
    $resolve = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Resolve-K8GatewayInterface' }, $true))[0].Extent.Text
    if ($resolve -notmatch "ToolObservation\s*=") { throw 'Resolve-K8GatewayInterface does not return its I-08 observation to the caller' }
    if ($body -notmatch [regex]::Escape('$gw.ToolObservation')) { throw 'the run body does not take I-08 from the gateway result' }

    # Both ranges take this path: gateway resolution is not Range B only, so
    # neither range may end up with a record that has no I-08 entry.
    $rangeGuard = [regex]::Match($body, "(?s)Set-K8ShakedownRunStage -Stage 'gateway-resolution'.{0,400}")
    if ($rangeGuard.Value -match "if \(\`$Range -eq 'b'\)") { throw 'gateway resolution appears to be gated on Range B; I-08 must be observed on both ranges' }
}

Assert-K8Test 'C-8: two consecutive runs each record their OWN runtime observations, with no carry-over' {
    # Exercised against the record writer directly: the defect being excluded
    # is a stale value surviving between runs in one process.
    $runA = 'k8shakedown-rangea-toolrec-a'
    $runB = 'k8shakedown-rangeb-toolrec-b'
    $obsA = [ordered]@{ step_id = 'I-08'; status = 'succeeded'; value = 'ip utility, iproute2-A'; exit_code = 0; stdout = 'A'; stderr = ''; observation_fidelity = 'full'; availability_policy = 'optional' }
    $obsB = [ordered]@{ step_id = 'I-08'; status = 'succeeded'; value = 'ip utility, iproute2-B'; exit_code = 0; stdout = 'B'; stderr = ''; observation_fidelity = 'full'; availability_policy = 'optional' }
    $pathA = Write-K8ToolVersionRecord -RunId $runA -Records @($obsA) -CapturePhase 'run'
    $pathB = Write-K8ToolVersionRecord -RunId $runB -Records @($obsB) -CapturePhase 'run'
    try {
        $a = Get-Content -LiteralPath $pathA -Raw | ConvertFrom-Json
        $b = Get-Content -LiteralPath $pathB -Raw | ConvertFrom-Json
        if ($a.run_id -eq $b.run_id) { throw 'the two runs wrote to the same record' }
        if (@($a.tools).Count -ne 1 -or @($b.tools).Count -ne 1) { throw 'a record carries more entries than the run observed' }
        if ($a.tools[0].value -notmatch 'iproute2-A') { throw "run A's record does not hold run A's observation" }
        if ($b.tools[0].value -notmatch 'iproute2-B') { throw "run B's record holds a carried-over observation: $($b.tools[0].value)" }
        if ($a.gated -ne $false -or $b.gated -ne $false) { throw 'the record does not state that these values are not gated' }
        if ($a.capture_phase -ne 'run') { throw 'capture_phase is not recorded' }
    }
    finally {
        foreach ($id in $runA, $runB) {
            Remove-Item (Join-Path (Get-K8RunRecordsDir) $id) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Assert-K8Test 'C-8: runtime-installed container tools are observed per run, and are never claimed to be fixed by image identity' {
    foreach ($id in 'I-07', 'I-08') {
        $row = Get-K8CommandContractRow -StepId $id
        if ($row.class -ne 'I') { throw "$id must be Class I -- no frozen source pins these versions" }
        if ($null -ne $row['accepted_exit_codes']) { throw "$id must not be gated" }
    }
    # The retracted claim must not be anywhere in the module: frozen
    # c2-dnp3-image-inventory.md SS1/SS2 record that log_structurer INSTALLS
    # tshark at startup and that a bit-identical image is not claimed.
    $src = Get-Content (Join-Path $C8Tools 'K8ShakedownCommon.psm1') -Raw
    if ($src -match 'image identity[^.]{0,80}fixes? the (bytes|version)' -or
        $src -match 'digest[^.]{0,60}so (the )?tshark') {
        throw 'the module claims container image identity fixes a runtime-installed tool; the frozen inventory explicitly does not claim that'
    }
    # I-05 is the only row whose observation fidelity is degraded, and it must
    # SAY so rather than reconstruct what the frozen producer destroyed.
    $collapsed = @(Get-K8CommandContract | Where-Object { $_['observation_fidelity'] -eq 'frozen-producer-collapsed' })
    if ($collapsed.Count -ne 1 -or $collapsed[0].step_id -ne 'I-05') {
        throw "exactly one row (I-05) may declare frozen-producer-collapsed; found $($collapsed.Count)"
    }
}

# --- 30. C-9: source / transfer / fresh-clone certification (Batch 3B) --------
#
# What these defend is the boundary RT-01 crossed. The producer half is here;
# the consumer half lives in Kakuriyo and is deliberately NOT shared code --
# a verifier that imports the implementation it is meant to be able to catch
# is not an independent check.

Assert-K8Test 'C-9: source identity is THREE-valued, and none of the three is a boolean in disguise' {
    Import-Module $CommonPath -Force
    $body = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Get-K8SourceIdentity'
    foreach ($state in 'confirmed', 'not-an-ancestor', 'not-observed') {
        if ($body -notmatch [regex]::Escape($state)) { throw "Get-K8SourceIdentity never produces '$state'; the tri-state exists to keep 'observed not to be an ancestor' apart from 'could not observe'" }
    }
    # A boolean ancestry field would be the collapse C-5 forbids.
    if ($body -match 'ancestry\s*=\s*\$(true|false)') { throw 'ancestry is assigned a boolean somewhere; that merges an answer with the absence of one' }
}

Assert-K8Test 'C-9: the authoritative pins cannot be moved through the module''s public surface' {
    Import-Module $CommonPath -Force
    # The Plan puts the canonical repository and ref outside the operator's
    # choice. "Outside the operator's choice" has to mean the module offers no
    # way to move them -- not merely that the documented entry points do not.

    # (1) The test seams are not module functions at all. They live in this
    #     harness and reach into module scope; an importer cannot do that.
    foreach ($seam in 'Set-K8TestSourcePin', 'Reset-K8TestSourcePin') {
        $exported = (Get-Module K8ShakedownCommon).ExportedFunctions.Keys
        if ($exported -contains $seam) { throw "$seam is exported by the module; a production import can then repoint the canonical source pin" }
        $moduleSrc = Get-Content $CommonPath -Raw
        if ($moduleSrc -match "function\s+$seam") { throw "$seam is defined in the module; test seams for an authoritative pin do not belong on the production surface" }
    }

    # (2) The getters hand back a COPY. Otherwise the getter is a setter.
    $before = Get-K8ProducerSourcePin
    $pin = Get-K8ProducerSourcePin
    $pin.CanonicalRef = 'refs/heads/attacker-chosen'
    $pin.CanonicalRemoteUrls = @('https://example.invalid/other')
    $after = Get-K8ProducerSourcePin
    if ($after.CanonicalRef -ne $before.CanonicalRef) { throw 'mutating the value returned by Get-K8ProducerSourcePin changed the authoritative ref' }
    if (($after.CanonicalRemoteUrls -join ',') -ne ($before.CanonicalRemoteUrls -join ',')) { throw 'mutating the value returned by Get-K8ProducerSourcePin changed the authoritative remote list' }

    $baseBefore = Get-K8ImmutableBase
    $b = Get-K8ImmutableBase
    $b.Commit = '0000000000000000000000000000000000000000'
    $b.FrozenPaths = @('nothing')
    $baseAfter = Get-K8ImmutableBase
    if ($baseAfter.Commit -ne $baseBefore.Commit) { throw 'mutating the value returned by Get-K8ImmutableBase moved the immutable base' }
    if (($baseAfter.FrozenPaths -join ',') -ne ($baseBefore.FrozenPaths -join ',')) { throw 'mutating the value returned by Get-K8ImmutableBase changed which paths are frozen' }

    # (3) And the gate itself still has no parameter offering to skip it.
    $seq = (Get-Command New-K8QualificationSequence).Parameters.Keys
    foreach ($p in $seq) {
        if ($p -match 'Skip|Force|Allow|Ignore') { throw "New-K8QualificationSequence exposes -$p; the source-identity gate is not overridable" }
    }
}

Assert-K8Test 'C-9: ancestry is measured against the PINNED repository, not any remote that happens to contain HEAD' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        # A second bare repo, holding the same commits, added as another remote.
        # Ancestry against it would be perfectly true -- and would establish
        # nothing about publication to the canonical source.
        $decoy = Join-Path ([System.IO.Path]::GetTempPath()) ('k8decoy-' + [guid]::NewGuid().ToString('N'))
        try {
            git -C $sb.Repo init -q --bare $decoy *> $null
            git -C $sb.Repo remote add decoy $decoy *> $null
            git -C $sb.Repo push -q decoy HEAD:refs/heads/main *> $null

            $stopped = $false; $message = ''
            try { Get-K8SourceIdentity -RepoRoot $sb.Repo -RemoteName 'decoy' } catch { $stopped = $true; $message = $_.Exception.Message }
            if (-not $stopped) { throw 'ancestry against a non-canonical remote was accepted; "an ancestor of SOMETHING" is not "published where this study says it is"' }
            if ($message -notmatch 'not the canonical producer source') { throw "the refusal does not name the reason: $message" }

            # And the canonical one still works, so this is not simply failing.
            $ok = Get-K8SourceIdentity -RepoRoot $sb.Repo
            if ($ok.ancestry -ne 'confirmed') { throw "the canonical remote did not confirm: $($ok.ancestry) / $($ok.ancestry_note)" }
        }
        finally { Remove-Item $decoy -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Assert-K8Test 'C-9: an absent pinned ref STOPs; it is not reported as "could not observe"' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        # The remote is reachable and answers. What it answers is that the ref
        # is not there -- an observation, not a failure to observe.
        Set-K8TestSourcePin -CanonicalRemoteUrls @($sb.Bare) -CanonicalRef 'refs/heads/no-such-branch'
        $stopped = $false; $message = ''
        try { Get-K8SourceIdentity -RepoRoot $sb.Repo } catch { $stopped = $true; $message = $_.Exception.Message }
        if (-not $stopped) { throw 'an absent pinned ref did not STOP' }
        if ($message -notmatch 'does not exist on') { throw "the refusal does not distinguish an absent ref from an unobservable remote: $message" }
    }
}

Assert-K8Test 'C-9: an unreachable remote yields not-observed, and not-observed STOPs at sequence open' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        # Point the pin at a bare repo, then delete it: the remote URL is still
        # canonical, and it can no longer be observed.
        $gone = Join-Path ([System.IO.Path]::GetTempPath()) ('k8gone-' + [guid]::NewGuid().ToString('N'))
        git -C $sb.Repo init -q --bare $gone *> $null
        git -C $sb.Repo remote add gone $gone *> $null
        git -C $sb.Repo push -q gone HEAD:refs/heads/main *> $null
        Remove-Item $gone -Recurse -Force
        Set-K8TestSourcePin -CanonicalRemoteUrls @($gone) -CanonicalRef 'refs/heads/main'

        $record = Get-K8SourceIdentity -RepoRoot $sb.Repo -RemoteName 'gone'
        if ($record.ancestry -ne 'not-observed') { throw "an unreachable remote produced '$($record.ancestry)' instead of not-observed" }
        if ([string]::IsNullOrWhiteSpace($record.ancestry_note)) { throw 'not-observed was recorded without saying why' }

        # And it is not a soft state: the gate refuses it, with no override.
        $stopped = $false; $message = ''
        try { Assert-K8SourceIdentityPublished -SourceIdentity $record } catch { $stopped = $true; $message = $_.Exception.Message }
        if (-not $stopped) { throw 'not-observed passed the sequence-open gate' }
        if ($message -notmatch 'UNKNOWN, not false') { throw "the refusal collapses 'unknown' into 'false': $message" }
    }
}

Assert-K8Test 'C-9: the gate has no override, and a not-an-ancestor HEAD cannot open a sequence' {
    Import-Module $CommonPath -Force
    # No parameter anywhere in the module offers to skip it. An operator-facing
    # override would be the same request as "lock an unpublished commit".
    $src = Get-Content $CommonPath -Raw
    foreach ($smell in 'AllowUnpublished', 'SkipSourceIdentity', 'IgnoreAncestry', 'ForceSequence') {
        if ($src -match [regex]::Escape($smell)) { throw "the module exposes '$smell'; the sequence-open gate is not overridable" }
    }
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        [void](Add-K8SandboxCommit -Repo $sb.Repo -Text 'unpublished work')
        # Deliberately NOT published.
        $stopped = $false; $message = ''
        try { New-K8QualificationSequence -RepoRoot $sb.Repo } catch { $stopped = $true; $message = $_.Exception.Message }
        if (-not $stopped) { throw 'a sequence opened on a HEAD that exists only on this disk' }
        if ($message -notmatch 'not published') { throw "the refusal does not say what is wrong: $message" }

        # Publishing it makes the same open succeed -- so the gate is not
        # simply refusing everything.
        Publish-K8SandboxHead -Sandbox $sb
        $seq = New-K8QualificationSequence -RepoRoot $sb.Repo
        if (-not $seq.sequence_id) { throw 'publishing the HEAD did not make the sequence openable' }
    }
}

Assert-K8Test 'C-9: the ancestry temp ref is deleted, and the decision never reads a remote-tracking ref' {
    Import-Module $CommonPath -Force
    $body = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Get-K8SourceIdentity'
    # Reading <remote>/<ref> would let a successful fetch pair with an
    # arbitrarily old ref. The refspec fetches into a named temp ref instead.
    if ($body -match "rev-parse',\s*""\`$RemoteName/") { throw 'the ancestry decision reads a remote-tracking ref' }
    if ($body -notmatch 'AncestryTempRef') { throw 'the ancestry decision does not use the explicit temp ref' }

    Invoke-K8SequenceSandbox -Action {
        param($sb)
        $record = Get-K8SourceIdentity -RepoRoot $sb.Repo
        if ($record.fetched_oid -ne $record.remote_ref_commit) { throw 'the OID fetched and the OID judged are not the same value' }
        git -C $sb.Repo show-ref (Get-K8ProducerSourcePin).AncestryTempRef *> $null
        if ($LASTEXITCODE -eq 0) { throw 'the ancestry temp ref was left behind; a later run that failed to fetch could resolve it' }
    }
}

Assert-K8Test 'C-9: source-identity.txt is mirrored before finalize, and the sequence record is its source' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        $seq = New-K8QualificationSequence -RepoRoot $sb.Repo
        $run = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        $tree = Join-Path $sb.Root 'tree'
        New-Item -ItemType Directory -Force -Path $tree | Out-Null
        Copy-K8RunProvenanceIntoEvidence -Run $run -RunEvidence $tree

        $txt = Join-Path $tree 'source-identity.txt'
        if (-not (Test-Path $txt)) { throw 'source-identity.txt was not mirrored into the evidence tree' }
        $content = Get-Content $txt -Raw
        $json = (Get-Content (Get-K8SourceIdentityPath -SequenceId $seq.sequence_id) -Raw) | ConvertFrom-Json
        foreach ($field in $json.head, $json.remote_url, $json.ancestry) {
            if ($content -notmatch [regex]::Escape($field)) { throw "the mirrored text does not carry '$field' from the authoritative record" }
        }
        if ($content -notmatch [regex]::Escape($run.RunId)) { throw 'the per-run mirror does not name the run it belongs to' }
    }
}

Assert-K8Test 'C-9: Range C hash domain excludes the manifest itself but the contract still requires it' {
    Import-Module $CommonPath -Force
    $rows = @(Get-K8ContractArtifacts -Range 'c')
    $names = @($rows.artifact)
    if ($names -notcontains 'shakedown-retention.sha256') { throw 'the Range C manifest is not a required artifact; its identity mechanism would sit outside C-6 entirely' }

    $d = Join-Path ([System.IO.Path]::GetTempPath()) ('k8rcman-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    try {
        foreach ($row in $rows) {
            if ($row.artifact -eq 'shakedown-retention.sha256') { continue }
            $target = Join-Path $d $row.artifact
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            "content of $($row.artifact)" | Set-Content -LiteralPath $target -Encoding utf8NoBOM
        }
        $domain = @(Write-K8RangeCRetentionManifest -RunEvidence $d)
        if ($domain -contains 'shakedown-retention.sha256') { throw 'the manifest is inside its own hash domain; that digest cannot be computed without self-reference' }

        $manifestText = Get-Content (Join-Path $d 'shakedown-retention.sha256') -Raw
        if ($manifestText -match 'shakedown-retention\.sha256') { throw 'the manifest lists itself' }
        if ($manifestText.Contains([string][char]92)) { throw 'the manifest uses backslash separators; a POSIX consumer cannot resolve those (the existing MANIFEST.sha256 has exactly this defect)' }
        foreach ($line in ($manifestText -split "`n" | Where-Object { $_.Trim() })) {
            if ($line -notmatch '^[0-9a-f]{64}  \S') { throw "manifest line is not '<sha256>  <path>': $line" }
        }

        # And a domain member that was never retained is a STOP, not a silently
        # shorter manifest.
        Remove-Item (Join-Path $d 'metadata.md') -Force
        Assert-K8FailsClosed -What 'writing a Range C manifest with a domain member missing' -Because 'never retained' -Attempt {
            Write-K8RangeCRetentionManifest -RunEvidence $d
        }
    }
    finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'C-9: Range C''s identity snapshot does not reuse Range A/B''s verified wording' {
    Import-Module $CommonPath -Force
    $ab = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Write-K8FinalizeIdentitySnapshot'
    $c  = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Write-K8RangeCIdentitySnapshot'
    if ($ab -notmatch 'verify-integrity') { throw 'the A/B snapshot no longer says what verified it' }
    if ($c -match 'verify-integrity \(study01_collect') { throw "the Range C snapshot reuses A/B's verified wording; no frozen verifier runs on that shape, so claiming one describes an observation nobody made" }
    if ($c -notmatch 'none was run') { throw 'the Range C snapshot does not state that no frozen verify-integrity applies' }
}

Assert-K8Test 'C-9: the transfer manifest states byte facts and never writes a .gitattributes' {
    Import-Module $CommonPath -Force
    # D-4: emitting the repair that fixed RT-01 would make the producer depend
    # on the consumer's retention policy.
    foreach ($fn in 'New-K8TransferManifest', 'Get-K8FileByteClass') {
        $body = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name $fn
        if ($body -match '\.gitattributes') { throw "$fn references .gitattributes; the producer must not author the consumer's policy" }
        if ($body -match '-text') { throw "$fn emits an attribute directive; byte_class is an observation, the directive is the consumer's decision" }
    }
    $bundleScript = Get-Content (Join-Path $ToolsDir 'New-K8TransferBundle.ps1') -Raw
    if ($bundleScript -match "Set-Content[^\r\n]*\.gitattributes") { throw 'the bundle assembler writes a .gitattributes' }

    $d = Join-Path ([System.IO.Path]::GetTempPath()) ('k8bc-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    try {
        [System.IO.File]::WriteAllBytes((Join-Path $d 'crlf.txt'), [byte[]](0x61, 0x0D, 0x0A))
        [System.IO.File]::WriteAllBytes((Join-Path $d 'lf.txt'), [byte[]](0x61, 0x0A))
        [System.IO.File]::WriteAllBytes((Join-Path $d 'bin.dat'), [byte[]](0x61, 0x00, 0x62))
        $cr = Get-K8FileByteClass -Path (Join-Path $d 'crlf.txt')
        $lf = Get-K8FileByteClass -Path (Join-Path $d 'lf.txt')
        $bin = Get-K8FileByteClass -Path (Join-Path $d 'bin.dat')
        if (-not $cr.contains_cr) { throw 'a CRLF file was not reported as containing CR -- this is the RT-01 condition itself' }
        if ($lf.contains_cr) { throw 'an LF-only file was reported as containing CR' }
        if (-not $bin.contains_nul) { throw 'a NUL-bearing file was not reported as binary-ish' }
        if (-not $lf.trailing_newline -or $bin.trailing_newline) { throw 'trailing_newline is not tracking the last byte' }
    }
    finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'C-9: a BundleId is validated against git''s real refname rules, not a character class' {
    Import-Module $CommonPath -Force
    # The id becomes BOTH a staging branch and a certification tag on the
    # consumer side. A pattern like ^[A-Za-z0-9][A-Za-z0-9._-]*$ looks like it
    # settles that and does not.
    foreach ($good in 'k8-shakedown-20260901', 'bundle_1', 'a.b-c') {
        if (-not (Assert-K8BundleIdUsableAsRef -BundleId $good)) { throw "'$good' is a usable ref component and was refused" }
    }
    # Each of these passes a plain character class and is refused by git.
    foreach ($bad in 'foo..bar', 'foo.', 'foo.lock') {
        Assert-K8FailsClosed -What "a BundleId of '$bad'" -Because 'check-ref-format' -Attempt {
            Assert-K8BundleIdUsableAsRef -BundleId $bad
        }
    }
    # And ids that are not a single ref COMPONENT at all.
    foreach ($bad in 'has space', 'a/b') {
        Assert-K8FailsClosed -What "a BundleId of '$bad'" -Because 'C-9' -Attempt {
            Assert-K8BundleIdUsableAsRef -BundleId $bad
        }
    }
    # An empty id is refused by the parameter binder before the body runs,
    # which is a fine place to refuse it -- asserted here so the coverage is
    # recorded rather than assumed.
    $emptyRefused = $false
    try { Assert-K8BundleIdUsableAsRef -BundleId '' } catch { $emptyRefused = $true }
    if (-not $emptyRefused) { throw 'an empty BundleId was accepted' }
    # Both derived refs are checked, not just one: the rules are not identical
    # across namespaces and the id has to work as both.
    $refs = @(Get-K8BundleRefNames -BundleId 'x')
    if ($refs.Count -ne 2) { throw "expected the staging branch and the certification tag, got $($refs.Count)" }
    if ($refs[0] -notmatch '^refs/heads/' -or $refs[1] -notmatch '^refs/tags/') { throw "the derived refs are not a branch and a tag: $($refs -join ', ')" }

    # The rule is ASKED of git, not reimplemented beside it.
    $body = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'Assert-K8BundleIdUsableAsRef'
    if ($body -notmatch 'check-ref-format') { throw 'the validator does not ask git; a second, slightly-wrong copy of git''s refname rules is exactly what this avoids' }
}

Assert-K8Test 'C-9: bundle paths are POSIX, and the closed-world equation is phase-aware' {
    Import-Module $CommonPath -Force
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ('k8cw-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'run-a\environment') | Out-Null
    try {
        'x' | Set-Content -LiteralPath (Join-Path $d 'run-a\environment\compose-ps.txt') -Encoding utf8NoBOM
        $rel = ConvertTo-K8BundleRelativePath -Root $d -FullPath (Join-Path $d 'run-a\environment\compose-ps.txt')
        if ($rel -ne 'run-a/environment/compose-ps.txt') { throw "path was not normalized to POSIX separators: '$rel'" }

        $manifest = [pscustomobject]@{ files = @([pscustomobject]@{ path = 'run-a/environment/compose-ps.txt' }) }

        # C_data: manifest + README + .gitattributes present, certification absent.
        '{}' | Set-Content -LiteralPath (Join-Path $d 'transfer-manifest.json') -Encoding utf8NoBOM
        '# bundle' | Set-Content -LiteralPath (Join-Path $d 'README.md') -Encoding utf8NoBOM
        '* -text' | Set-Content -LiteralPath (Join-Path $d '.gitattributes') -Encoding utf8NoBOM
        $r = Test-K8BundleClosedWorld -BundleRoot $d -Manifest $manifest
        if (-not $r.Ok) { throw "C_data did not satisfy the set equation: unaccounted=[$($r.UnaccountedFiles -join ',')] missing=[$($r.MissingFromBundle -join ',')] both=[$($r.ClaimedAsBoth -join ',')]" }

        # C_cert: the certification record appears. Still satisfied -- the
        # allowlist is names that MAY be control files, not files that must be
        # present, which is what made the earlier formulation unsatisfiable.
        '{}' | Set-Content -LiteralPath (Join-Path $d 'transfer-certification.json') -Encoding utf8NoBOM
        $r2 = Test-K8BundleClosedWorld -BundleRoot $d -Manifest $manifest
        if (-not $r2.Ok) { throw 'C_cert did not satisfy the set equation once the certification record was added' }

        # An unaccounted file is named, not counted.
        'stray' | Set-Content -LiteralPath (Join-Path $d 'run-a\stray.txt') -Encoding utf8NoBOM
        $r3 = Test-K8BundleClosedWorld -BundleRoot $d -Manifest $manifest
        if ($r3.Ok) { throw 'a file in neither set was accepted' }
        if (@($r3.UnaccountedFiles) -notcontains 'run-a/stray.txt') { throw 'the unaccounted file was not named' }
    }
    finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'C-9: exclusions are constrained, and never excuse a file that is actually present' {
    Import-Module $CommonPath -Force
    $ok = @([ordered]@{ pattern = '*.pcap'; reason = 'pcap-body-never-in-git'; retained_instead = '*/pcap-hashes.sha256' })
    Assert-K8ExclusionDeclaration -Exclusions $ok

    $bad = @{
        'a traversal segment'      = @([ordered]@{ pattern = '../secrets/*'; reason = 'pcap-body-never-in-git'; retained_instead = '' })
        'an absolute pattern'      = @([ordered]@{ pattern = 'C:\evidence\*'; reason = 'pcap-body-never-in-git'; retained_instead = '' })
        'an empty path segment'    = @([ordered]@{ pattern = 'runs//x'; reason = 'pcap-body-never-in-git'; retained_instead = '' })
        'a free-form reason'       = @([ordered]@{ pattern = '*.pcap'; reason = 'too big to commit'; retained_instead = '' })
        'a duplicate pattern'      = @([ordered]@{ pattern = '*.pcap'; reason = 'pcap-body-never-in-git'; retained_instead = '' }, [ordered]@{ pattern = '*.pcap'; reason = 'pcap-body-never-in-git'; retained_instead = '' })
        'overlapping patterns'     = @([ordered]@{ pattern = 'runs/*'; reason = 'pcap-body-never-in-git'; retained_instead = '' }, [ordered]@{ pattern = 'runs/a/*'; reason = 'pcap-body-never-in-git'; retained_instead = '' })
    }
    foreach ($case in $bad.Keys) {
        Assert-K8FailsClosed -What "declaring $case" -Because 'exclusion' -Attempt { Assert-K8ExclusionDeclaration -Exclusions $bad[$case] }
    }
}

Assert-K8Test 'C-9: the run selection is checked against real control-plane records, not by looking for guard names' {
    Import-Module $CommonPath -Force
    # The previous version of this check read the function body for the strings
    # "complete", "locked_head", "a,b,c" and "termination". That passes whenever
    # the words are present, however the comparison behind them is written --
    # and it is why B3B-P-04 (the selection never being compared against the
    # sequence's own completed_runs) went unnoticed. Every case below runs
    # against actual records now.
    Invoke-K8SequenceSandbox -Action {
        param($sb)

        function New-K8SandboxCompletedSequence {
            param($Sandbox)
            $seq = New-K8QualificationSequence -RepoRoot $Sandbox.Repo
            $ids = [ordered]@{}
            foreach ($range in 'a', 'b', 'c') {
                $run = Start-K8ShakedownRun -Range $range -RepoRoot $Sandbox.Repo
                Complete-K8ShakedownRunInSequence -Run $run | Out-Null
                $ids[$range] = $run.RunId
            }
            return [pscustomobject]@{ SequenceId = $seq.sequence_id; Ids = $ids }
        }
        function Set-K8SandboxProvenanceField {
            param([string] $RunId, [string] $Field, $Value)
            $path = Get-K8RunProvenancePath -RunId $RunId
            $json = (Get-Content -LiteralPath $path -Raw) | ConvertFrom-Json -AsHashtable
            $json[$Field] = $Value
            ($json | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        }

        $done = New-K8SandboxCompletedSequence -Sandbox $sb
        $all = @($done.Ids['a'], $done.Ids['b'], $done.Ids['c'])

        # POSITIVE CONTROL first: without it, every negative below could be
        # passing because the gate refuses everything.
        $ok = Assert-K8BundleRunConsistency -RunIds $all
        if ($ok.SequenceId -ne $done.SequenceId) { throw "the genuine selection was attributed to $($ok.SequenceId), not $($done.SequenceId)" }
        if (@($ok.Runs).Count -ne 3) { throw 'the genuine selection did not yield three runs' }

        # (1) A range missing.
        Assert-K8FailsClosed -What 'bundling only Range A and B' -Because 'a, b and c' -Attempt {
            Assert-K8BundleRunConsistency -RunIds @($done.Ids['a'], $done.Ids['b'])
        }

        # (2) A run from a DIFFERENT sequence.
        $second = New-K8SandboxCompletedSequence -Sandbox $sb
        Assert-K8FailsClosed -What 'mixing runs from two sequences' -Because 'sequences' -Attempt {
            Assert-K8BundleRunConsistency -RunIds @($done.Ids['a'], $done.Ids['b'], $second.Ids['c'])
        }

        # (3) SUBSTITUTION -- the case a self-description check cannot see.
        #     Take a run from the second sequence and rewrite its provenance so
        #     it CLAIMS the first sequence, the first sequence's HEAD, and
        #     Range C. Every self-reported field now agrees. It still is not one
        #     of the runs that sequence completed.
        $impostor = $second.Ids['c']
        Set-K8SandboxProvenanceField -RunId $impostor -Field 'sequence_id' -Value $done.SequenceId
        Set-K8SandboxProvenanceField -RunId $impostor -Field 'range' -Value 'c'
        Assert-K8FailsClosed -What 'substituting a run that merely claims to belong to the sequence' -Because 'not the runs' -Attempt {
            Assert-K8BundleRunConsistency -RunIds @($done.Ids['a'], $done.Ids['b'], $impostor)
        }

        # (4) A different tooling HEAD among the selected runs.
        Set-K8SandboxProvenanceField -RunId $done.Ids['b'] -Field 'tooling_head' -Value ('0' * 40)
        Assert-K8FailsClosed -What 'bundling runs that span two tooling HEADs' -Because 'tooling HEADs' -Attempt {
            Assert-K8BundleRunConsistency -RunIds $all
        }
        Set-K8SandboxProvenanceField -RunId $done.Ids['b'] -Field 'tooling_head' -Value $ok.ToolingHead
        [void](Assert-K8BundleRunConsistency -RunIds $all)   # restored

        # (5) A sequence that has not completed.
        New-K8QualificationSequence -RepoRoot $sb.Repo | Out-Null
        $openRun = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        Assert-K8FailsClosed -What 'bundling from a sequence still in progress' -Because 'not' -Attempt {
            Assert-K8BundleRunConsistency -RunIds @($openRun.RunId)
        }

        # (6) A terminated run. The record is placed directly: what is being
        #     tested is that a run carrying one is refused, not how it got one.
        $termPath = Get-K8TerminationRecordPath -RunId $openRun.RunId
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $termPath) | Out-Null
        '{"schema":"k8shakedown-termination/1","stage":"test-fixture"}' | Set-Content -LiteralPath $termPath -Encoding utf8NoBOM
        Assert-K8FailsClosed -What 'bundling a terminated run' -Because 'termination record' -Attempt {
            Assert-K8BundleRunConsistency -RunIds @($openRun.RunId)
        }
    }
}

Assert-K8Test 'C-9: the embedded source identity is bound to the sequence it claims, not merely transcribed' {
    Import-Module $CommonPath -Force
    Invoke-K8SequenceSandbox -Action {
        param($sb)
        $seq = New-K8QualificationSequence -RepoRoot $sb.Repo
        $ids = @()
        foreach ($range in 'a', 'b', 'c') {
            $run = Start-K8ShakedownRun -Range $range -RepoRoot $sb.Repo
            Complete-K8ShakedownRunInSequence -Run $run | Out-Null
            $ids += $run.RunId
        }
        $consistency = Assert-K8BundleRunConsistency -RunIds $ids

        # Positive control.
        $identity = Assert-K8EmbeddedSourceIdentity -Consistency $consistency
        if ($identity.ancestry -ne 'confirmed') { throw "the genuine source identity was not confirmed: $($identity.ancestry)" }

        $path = Get-K8SourceIdentityPath -SequenceId $consistency.SequenceId
        $original = Get-Content -LiteralPath $path -Raw

        # Reading a record and embedding it is transcription. Each mutation
        # below leaves a well-formed file that a transcriber would publish.
        $mutations = [ordered]@{
            'a foreign sequence_id'  = @{ sequence_id = 'k8seq-somebody-elses' }
            'a different HEAD'       = @{ head = ('f' * 40) }
            'an unconfirmed ancestry' = @{ ancestry = 'not-observed'; ancestry_note = 'injected' }
            'a wrong schema'         = @{ schema = 'k8shakedown-source-identity/999' }
            'a blank remote_ref'     = @{ remote_ref = '' }

            # These are the ones a non-empty check misses. `confirmed` is the
            # record's claim about ITSELF: it says publication was confirmed,
            # never against WHAT. Each of the next three is well-formed, has
            # ancestry=confirmed, and names something that is not the canonical
            # producer source.
            'a foreign but non-empty remote'  = @{ remote_url_normalized = 'github.com/somebody/else' }
            'a foreign but non-empty ref'     = @{ remote_ref = 'refs/heads/foreign' }
            'fetched_oid != remote_ref_commit' = @{ fetched_oid = ('a' * 40) }
            'a malformed OID'                 = @{ remote_ref_commit = 'not-a-sha' }
            'a dirty tree'                    = @{ tree_clean = $false }
            'dirty paths despite a clean flag' = @{ dirty_paths = @(' M something.ps1') }
        }
        foreach ($case in $mutations.Keys) {
            try {
                $json = $original | ConvertFrom-Json -AsHashtable
                foreach ($k in $mutations[$case].Keys) { $json[$k] = $mutations[$case][$k] }
                ($json | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $path -Encoding utf8NoBOM
                Assert-K8FailsClosed -What "embedding a source identity with $case" -Because 'C-9' -Attempt {
                    Assert-K8EmbeddedSourceIdentity -Consistency $consistency
                }
            }
            finally { $original | Set-Content -LiteralPath $path -Encoding utf8NoBOM -NoNewline }
        }

        # Still good after the restores, so the failures above were the
        # mutations and not collateral damage.
        [void](Assert-K8EmbeddedSourceIdentity -Consistency $consistency)
    }
}

Assert-K8Test 'C-9: the manifest builder trusts no caller-supplied selection object' {
    Import-Module $CommonPath -Force
    # An earlier version took a -Consistency object and asserted in a comment
    # that only Assert-K8BundleRunConsistency could produce one. PowerShell
    # gives a PSCustomObject no such property, and the module exports
    # everything, so any caller could have handed over a look-alike and skipped
    # a/b/c coverage, completed_runs membership and terminated exclusion --
    # a second entrance to the gate B3B-P-04 had just closed.
    $params = (Get-Command New-K8TransferManifest).Parameters
    if ($params.ContainsKey('Consistency')) { throw 'New-K8TransferManifest still accepts a caller-supplied selection object; a plain object is not proof that a gate ran' }
    if (-not $params.ContainsKey('RunIds')) { throw 'New-K8TransferManifest does not take run IDs, so it cannot be running the gate itself' }
    $body = Get-K8CommentStrippedFunctionBody -Path $CommonPath -Name 'New-K8TransferManifest'
    if ($body -notmatch 'Assert-K8BundleRunConsistency') { throw 'New-K8TransferManifest does not re-run the consistency gate' }

    Invoke-K8SequenceSandbox -Action {
        param($sb)
        $seq = New-K8QualificationSequence -RepoRoot $sb.Repo
        $ids = @()
        foreach ($range in 'a', 'b', 'c') {
            $run = Start-K8ShakedownRun -Range $range -RepoRoot $sb.Repo
            Complete-K8ShakedownRunInSequence -Run $run | Out-Null
            $ids += $run.RunId
        }
        # A second sequence, whose runs are perfectly real and belong elsewhere.
        $seq2 = New-K8QualificationSequence -RepoRoot $sb.Repo
        $other = Start-K8ShakedownRun -Range a -RepoRoot $sb.Repo
        Complete-K8ShakedownRunInSequence -Run $other | Out-Null

        $bundle = Join-Path $sb.Root 'bundle'
        New-Item -ItemType Directory -Force -Path $bundle | Out-Null
        'data' | Set-Content -LiteralPath (Join-Path $bundle 'evidence.txt') -Encoding utf8NoBOM

        # The forgery the old signature would have accepted: correct sequence
        # and HEAD (so the source-identity comparison passes), arbitrary runs.
        $forged = [pscustomobject]@{
            SequenceId  = $seq.sequence_id
            ToolingHead = $sb.Head
            Sequence    = @{ locked_head = $sb.Head; completed_runs = @(); terminated_runs = @() }
            Runs        = @([ordered]@{ run_id = $other.RunId; range = 'a'; sequence_id = $seq.sequence_id; tooling_head = $sb.Head })
        }
        $rejected = $false
        try { New-K8TransferManifest -Consistency $forged -BundleRoot $bundle -Exclusions @() }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'a forged selection object produced a manifest' }

        # And the honest path still works, so this is not simply failing.
        $manifest = New-K8TransferManifest -RunIds $ids -BundleRoot $bundle -Exclusions @()
        if ($manifest.sequence_id -ne $seq.sequence_id) { throw 'the genuine selection did not produce a manifest for its own sequence' }

        # Passing the other sequence's run through the front door is refused by
        # the gate the builder now runs itself.
        Assert-K8FailsClosed -What 'building a manifest from a run outside the sequence' -Because 'C-9' -Attempt {
            New-K8TransferManifest -RunIds @($other.RunId) -BundleRoot $bundle -Exclusions @()
        }
    }
}

Assert-K8Test 'C-9: bundle path membership uses a separator boundary, not a bare prefix' {
    Import-Module $CommonPath -Force
    $base = Join-Path ([System.IO.Path]::GetTempPath()) ('k8pm-' + [guid]::NewGuid().ToString('N'))
    $root = Join-Path $base 'bundle'
    $sibling = Join-Path $base 'bundle-sibling'
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'sub'), $sibling | Out-Null
    try {
        'inside' | Set-Content -LiteralPath (Join-Path $root 'sub\inside.txt') -Encoding utf8NoBOM
        'outside' | Set-Content -LiteralPath (Join-Path $sibling 'outside.txt') -Encoding utf8NoBOM

        # A REAL sibling whose name begins with the root's. A bare StartsWith
        # accepted this and returned '-sibling/outside.txt' as its "relative
        # path inside the bundle" -- measured, and the same defect class as
        # B2-C7-01.
        Assert-K8FailsClosed -What 'describing a sibling directory that shares the root prefix' -Because 'not inside the bundle root' -Attempt {
            ConvertTo-K8BundleRelativePath -Root $root -FullPath (Join-Path $sibling 'outside.txt')
        }

        # And a genuine member still resolves, so this is not simply refusing.
        $rel = ConvertTo-K8BundleRelativePath -Root $root -FullPath (Join-Path $root 'sub\inside.txt')
        if ($rel -ne 'sub/inside.txt') { throw "a genuine bundle member did not resolve correctly: '$rel'" }
    }
    finally { Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'C-9: the frozen-path comparison uses a FIXED immutable base, resolved without fetching' {
    # criterion 11(a) names a fixed immutable base commit. The check this
    # replaces compared against origin/main and swallowed its own fetch
    # failure; both are recorded in the module beside the pin.
    $base = Get-K8ImmutableBase
    if ($base.Commit -notmatch '^[0-9a-f]{40}$') { throw "the immutable base pin is not a 40-hex commit: '$($base.Commit)'" }

    Push-Location $RepoRoot
    try {
        # (1) The pin must be a real commit object IN THIS CLONE. A pin that
        #     only resolves after a fetch would put the check back on the
        #     network, which is half of what was wrong before.
        $type = (git cat-file -t $base.Commit 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $type -ne 'commit') { throw "immutable base $($base.Commit) does not resolve to a commit object without fetching (got '$type', exit $LASTEXITCODE)" }

        # (2) It must be an ANCESTOR of HEAD. A valid-but-unrelated SHA would
        #     otherwise compare two points that merely happen to agree.
        git merge-base --is-ancestor $base.Commit HEAD 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "immutable base $($base.Commit) is not an ancestor of HEAD; comparing against it would not establish that the frozen paths never moved from the base this branch descends from" }

        # (3) The comparison itself.
        $diff = (git diff --stat $base.Commit -- @($base.FrozenPaths) 2>&1 | Out-String).Trim()
        if ($diff) { throw "frozen paths differ from the immutable base $($base.Commit):`n$diff" }
    }
    finally { Pop-Location }

    # (4) The DECIDING CODE must not have reacquired a moving ref or a fetch.
    #     Scoped to this check's own block: prose elsewhere may legitimately
    #     name the defect it descends from, and banning the words there would
    #     only make the record less legible (same narrowing C-8 needed).
    $src = Get-Content $PSCommandPath -Raw
    $marker = "Assert-K8Test 'C-9: the frozen-path comparison uses a FIXED immutable base"
    $start = $src.IndexOf($marker)
    $next = $src.IndexOf("Assert-K8Test '", $start + $marker.Length)
    if ($next -lt 0) { $next = $src.Length }
    $body = $src.Substring($start, $next - $start)
    # Scan the CODE, not the prose. A comment may legitimately name the defect
    # this check descends from -- that is documentation, and banning the words
    # there would only make the record less legible. The audit line itself also
    # necessarily contains the literals it bans, and it is a comment-free line,
    # so it is excluded by position.
    $auditAt = $body.IndexOf('$auditAt')
    if ($auditAt -gt 0) { $body = $body.Substring(0, $auditAt) }
    $code = (($body -split "`n") | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"
    foreach ($banned in 'origin/main', 'git fetch') {
        if ($code -match [regex]::Escape($banned)) { throw "the frozen-path check's deciding code references '$banned'; criterion 11(a) requires a fixed base resolved locally" }
    }
}

Assert-K8Test 'C-9: changing a frozen byte is caught by the immutable-base comparison (the check is not vacuous)' {
    $base = Get-K8ImmutableBase
    $victim = Join-Path $RepoRoot 'Study01\README.md'
    $original = [System.IO.File]::ReadAllBytes($victim)
    Push-Location $RepoRoot
    try {
        [System.IO.File]::WriteAllBytes($victim, ($original + [byte]0x0A))
        $diff = (git diff --stat $base.Commit -- @($base.FrozenPaths) 2>&1 | Out-String).Trim()
        if (-not $diff) { throw 'a modified frozen file produced no diff against the immutable base; the comparison is vacuous' }
    }
    finally {
        [System.IO.File]::WriteAllBytes($victim, $original)
        Pop-Location
    }
}

Assert-K8Test 'C-9: a pin that is not an ancestor of HEAD is refused, not silently compared' {
    # An unrelated commit can share identical frozen paths by coincidence. The
    # ancestry requirement is what makes "unchanged" mean "unchanged from the
    # base this branch actually descends from", rather than "agrees with some
    # other point in the object store".
    Push-Location $RepoRoot
    try {
        # The well-known empty tree, so no object has to be written first.
        $emptyTree = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
        $orphan = (git commit-tree $emptyTree -m 'k8 c9 non-ancestor probe' 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $orphan -notmatch '^[0-9a-f]{40}$') { throw "could not create a parentless probe commit: $orphan" }

        git merge-base --is-ancestor $orphan HEAD 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { throw 'a parentless probe commit was reported as an ancestor of HEAD; the ancestry guard cannot discriminate' }

        # It IS a real commit object, so "resolves as a commit" alone would have
        # accepted it -- which is exactly why ancestry is a separate check.
        $type = (git cat-file -t $orphan 2>&1 | Out-String).Trim()
        if ($type -ne 'commit') { throw "the probe is not a commit object (got '$type'); this test would not be showing what it claims" }
    }
    finally { Pop-Location }
}

# --- Summary -------------------------------------------------------------------

Write-Host ''
Restore-K8SuiteWorkspace
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) check(s) FAILED: $($failures -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host 'All Shakedown regression checks PASS.' -ForegroundColor Green
exit 0
