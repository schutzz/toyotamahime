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
      7. Study01/ is byte-for-byte unmodified on this branch versus origin/main.
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
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-K8ShakedownRangeAB'
    }, $true)
    if (-not $function) { throw 'Invoke-K8ShakedownRangeAB not found' }
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
    foreach ($needle in @('config --services', 'ps --all --format json', 'Test-K8ComposeServiceReadiness')) {
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
        '{"hits":{"total":{"value":2,"relation":"eq"},"hits":[{"_id":"c1","_source":{}},{"_id":"c2","_source":{}}]}}' | Set-Content (Join-Path $tmp 'c.json')
        '{"hits":{"total":{"value":2,"relation":"eq"},"hits":[{"_id":"r1","_source":{"source_dnp3_doc_id":"c2"}},{"_id":"r2","_source":{"source_dnp3_doc_id":"missing"}}]}}' | Set-Content (Join-Path $tmp 'r.json')
        & python $helper target-correlation --collector (Join-Path $tmp 'c.json') --rule (Join-Path $tmp 'r.json') --output (Join-Path $tmp 'o.json')
        if ($LASTEXITCODE -ne 0) { throw 'helper failed' }
        $result = Get-Content (Join-Path $tmp 'o.json') -Raw | ConvertFrom-Json
        if (($result.accepted_collector_hit_ids -join ',') -ne 'c1,c2') { throw 'complete Collector hit ID set was not retained' }
        if ($result.rule_correlations[0].correlates_to_accepted_collector_hit -ne $true -or $result.rule_correlations[1].correlates_to_accepted_collector_hit -ne $false) { throw 'Rule correlation decisions incorrect' }
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
        $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8ShakedownRangeAB'
        $gateCalls = @([regex]::Matches($body, "$gateFunc\s+-RunId"))
        if ($gateCalls.Count -ne 1) { throw "expected exactly one shared call site in Invoke-K8ShakedownRangeAB (used by both Range A and Range B); found $($gateCalls.Count)" }
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
# (tests/mock-docker/docker.cmd -> docker.ps1), so "not ready -> STOP before
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
        if ($body -notmatch "docker exec \`$container python3 -c \`$searchScript") { throw 'search check is not executed via docker exec against $container (zone_detector itself)' }
        if ($body -notmatch '\$pluginLive -and \$connectivityOk -and \$searchOk') { throw 'PASS condition no longer requires plugin-alive AND connectivity AND search all three' }
    }

    Assert-K8Test 'zone_detector connectivity check runs FROM INSIDE the zone_detector container, not from Elasticsearch or the host' {
        $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Wait-K8ZoneDetectorReady'
        if ($body -notmatch "docker exec \`$container python3 -c") { throw 'connectivity check is not executed via docker exec against $container (the zone_detector container)' }
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
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8ShakedownRangeAB'
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
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-robs-e2e-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'sensor-input\mirror-capture'), (Join-Path $dir 'contract-output') | Out-Null
        'fake' | Set-Content (Join-Path $dir 'sensor-input\mirror-capture\c2-mirror-sensor.pcap')
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
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8ShakedownRangeAB'
    $gtCall = $body.IndexOf("-Stage 'ground-truth' -WindowStartIso")
    $sensorCall = $body.IndexOf("-Stage 'sensor' -WindowStartIso")
    if ($gtCall -lt 0 -or $sensorCall -lt 0) { throw 'could not find both decode call sites in Invoke-K8ShakedownRangeAB' }
    $completeBody = Get-K8FunctionBodyText -Path $CommonPath -Name 'Complete-K8ShakedownRangeAB'
    if ($completeBody -match 'Write-K8TargetCaptureDecode') { throw 'decode must run in Invoke-K8ShakedownRangeAB (range still up), not in Complete (after teardown)' }
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

        $required = @(
            'ground-truth\independent-capture\c2-original-path.pcap', 'ground-truth\independent-capture\capture-lifecycle.json',
            'ground-truth\independent-capture\capture-context.json', 'ground-truth\independent-capture\decoded-verification.json',
            'ground-truth\sender-record.txt', 'ground-truth\procedure-conformance.json',
            'sensor-input\mirror-capture\c2-mirror-sensor.pcap', 'sensor-input\mirror-capture\capture-lifecycle.json',
            'sensor-input\mirror-capture\capture-context.json', 'sensor-input\mirror-capture\decoded-verification.json',
            'collector-output\collector-response.json', 'collector-output\collector-index-mapping.json',
            'rule-output\rule-response.json', 'rule-output\rule-index-mapping.json', 'rule-output\collector-rule-correlation.json',
            'contract-output\gateway-interface-resolution.txt', 'contract-output\runtime-contract-record.md',
            'environment\image-inventory.json', 'environment\collector-query.json', 'environment\rule-query.json',
            'metadata-t0.txt', 'metadata.md', 'deviations.md'
        )
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
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8ShakedownRangeAB'
    $gateCalls = @([regex]::Matches($body, 'Test-K8ScoringInputArtifactCompleteness\s+-Range'))
    if ($gateCalls.Count -ne 1) { throw "expected exactly one shared call site; found $($gateCalls.Count)" }
    # Search for the actual Write-K8ShakedownLog call site specifically
    # (not just the phrase, which also legitimately appears in this
    # function's own explanatory comments preceding the gate call).
    $passLogIndex = $body.IndexOf('=== Shakedown Range $($Range.ToUpper()) runtime evidence PASS')
    if ($passLogIndex -lt 0 -or $gateCalls[0].Index -gt $passLogIndex) { throw 'completeness gate does not run before the "runtime evidence PASS" log line' }
}

# --- 7. Study01/ untouched on this branch -------------------------------------

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
