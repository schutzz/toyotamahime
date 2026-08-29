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
            'collector-output\collector-selector-mapping-gate.json', 'collector-output\accepted-collector-hit-ids.json',
            'rule-output\rule-response.json', 'rule-output\rule-index-mapping.json',
            'rule-output\rule-selector-mapping-gate.json', 'rule-output\collector-rule-correlation.json',
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

Assert-K8Test 'Test-K8ShakedownNetworkPreflight never calls network rm/prune, and runs before docker compose up in Invoke-K8ShakedownRangeAB' {
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
    $rangeAbBody = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8ShakedownRangeAB'
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
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8ShakedownRangeAB'
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
        $rangeA = @(
            'ground-truth\independent-capture\c2-original-path.pcap', 'ground-truth\independent-capture\capture-lifecycle.json',
            'ground-truth\independent-capture\capture-context.json', 'ground-truth\independent-capture\decoded-verification.json',
            'ground-truth\sender-record.txt', 'ground-truth\procedure-conformance.json',
            'sensor-input\mirror-capture\c2-mirror-sensor.pcap', 'sensor-input\mirror-capture\capture-lifecycle.json',
            'sensor-input\mirror-capture\capture-context.json', 'sensor-input\mirror-capture\decoded-verification.json',
            'collector-output\collector-response.json', 'collector-output\collector-index-mapping.json',
            'collector-output\collector-selector-mapping-gate.json', 'collector-output\accepted-collector-hit-ids.json',
            'rule-output\rule-response.json', 'rule-output\rule-index-mapping.json',
            'rule-output\rule-selector-mapping-gate.json', 'rule-output\collector-rule-correlation.json',
            'contract-output\gateway-interface-resolution.txt', 'contract-output\runtime-contract-record.md',
            'environment\image-inventory.json', 'environment\collector-query.json', 'environment\rule-query.json',
            'metadata-t0.txt', 'metadata.md', 'deviations.md'
        )
        $rangeBExtra = @(
            'contract-output\qdisc-pre-fault.txt', 'contract-output\fault-injection-command.txt',
            'contract-output\qdisc-post-fault.txt', 'contract-output\unrelated-mirror-filters.txt',
            'contract-output\r-obs-05-mapping-response.json', 'contract-output\r-obs-05-mapping-gate.json',
            'environment\r-obs-05-query.json', 'contract-output\r-obs-05-response.json',
            'contract-output\r-obs-05-liveness.pcap', 'contract-output\r-obs-05-capture-lifecycle.json',
            'contract-output\r-obs-05-pcap-rows.json', 'contract-output\r-obs-05-liveness-decode.txt',
            'contract-output\r-obs-05-correlation.json', 'contract-output\r-obs-05-contract-reference.txt'
        )
        foreach ($rel in ($rangeA + $rangeBExtra)) {
            $full = Join-Path $dir $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $full -Parent) | Out-Null
            'x' | Set-Content $full
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
    foreach ($case in @(
        @{ Name = 'pre: empty stdout + exit 0';    Argv = @('cmd.exe', '/c', 'exit 0');            Empty = $true;  Exit = 0; File = 'qdisc-pre-fault.txt' }
        @{ Name = 'pre: nonempty stdout';          Argv = @('cmd.exe', '/c', 'echo qdisc ingress'); Empty = $false; Exit = 0; File = 'qdisc-pre-fault.txt' }
        @{ Name = 'post: empty stdout + exit 0';   Argv = @('cmd.exe', '/c', 'exit 0');            Empty = $true;  Exit = 0; File = 'qdisc-post-fault.txt' }
        @{ Name = 'post: nonempty stdout';         Argv = @('cmd.exe', '/c', 'echo filter parent ffff:'); Empty = $false; Exit = 0; File = 'qdisc-post-fault.txt' }
    )) {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-fobs-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        try {
            $obs = @(Invoke-K8FaultObservationCommand -Label $case.Name -Argv $case.Argv)
            if ($obs[0].StdoutEmpty -ne $case.Empty) { throw "$($case.Name): stdout_empty was $($obs[0].StdoutEmpty), expected $($case.Empty)" }
            if ($obs[0].ExitCode -ne $case.Exit) { throw "$($case.Name): exit was $($obs[0].ExitCode), expected $($case.Exit)" }
            $path = Join-Path $d $case.File
            Write-K8FaultObservationArtifact -Observations $obs -Path $path -Title 'test'
            if (-not (Test-Path $path)) { throw "$($case.Name): the artifact was NOT created -- this is the exact real-VM defect" }
            $text = Get-Content $path -Raw
            foreach ($field in @('argv=', 'exit_code=', 'timestamp_utc=', 'stdout_empty=', '--- stdout ---', '--- stderr ---')) {
                if ($text -notmatch [regex]::Escape($field)) { throw "$($case.Name): retained record is missing '$field'" }
            }
            if ($text -notmatch "stdout_empty=$($case.Empty.ToString().ToLowerInvariant())") { throw "$($case.Name): stdout_empty was not retained correctly" }
        }
        finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Assert-K8Test 'REGRESSION: empty stdout with a NONZERO exit fails closed -- never read as a successful "no remaining filter"' {
    Import-Module $CommonPath -Force
    foreach ($stage in @('pre-fault observation', 'post-fault observation')) {
        $obs = @(Invoke-K8FaultObservationCommand -Label $stage -Argv @('cmd.exe', '/c', 'exit 3'))
        if (-not $obs[0].StdoutEmpty) { throw 'fixture did not produce the empty-stdout case' }
        $stopped = $false; $msg = ''
        try { Assert-K8FaultObservationsSucceeded -Observations $obs -Stage $stage } catch { $stopped = $true; $msg = $_.Exception.Message }
        if (-not $stopped) { throw "$stage : an empty stdout with exit 3 did not STOP" }
        if ($msg -notmatch 'never read as success') { throw "the failure does not state the empty-vs-failed distinction: $msg" }
    }
}

Assert-K8Test 'REGRESSION: fault observations separate stdout from stderr (never merged via 2>&1)' {
    Import-Module $CommonPath -Force
    $obs = @(Invoke-K8FaultObservationCommand -Label 'sep' -Argv @('cmd.exe', '/c', 'echo OUT& echo ERRLINE 1>&2'))
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
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8ShakedownRangeAB'
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
    $body = Get-K8FunctionBodyText -Path $CommonPath -Name 'Invoke-K8ShakedownRangeAB'
    foreach ($artifact in @('qdisc-pre-fault.txt', 'fault-injection-command.txt', 'qdisc-post-fault.txt')) {
        $idx = $body.IndexOf($artifact)
        $before = $body.Substring(0, $idx)
        if ($before.LastIndexOf("if (`$Range -eq 'b')") -lt 0) { throw "$artifact is written outside a Range B branch -- Range A runtime behavior would change" }
    }
    # And the completeness gate must not require them for Range A.
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-rangea-nofault-" + [guid]::NewGuid())
    try {
        foreach ($rel in @(
            'ground-truth\independent-capture\c2-original-path.pcap', 'ground-truth\independent-capture\capture-lifecycle.json',
            'ground-truth\independent-capture\capture-context.json', 'ground-truth\independent-capture\decoded-verification.json',
            'ground-truth\sender-record.txt', 'ground-truth\procedure-conformance.json',
            'sensor-input\mirror-capture\c2-mirror-sensor.pcap', 'sensor-input\mirror-capture\capture-lifecycle.json',
            'sensor-input\mirror-capture\capture-context.json', 'sensor-input\mirror-capture\decoded-verification.json',
            'collector-output\collector-response.json', 'collector-output\collector-index-mapping.json',
            'collector-output\collector-selector-mapping-gate.json', 'collector-output\accepted-collector-hit-ids.json',
            'rule-output\rule-response.json', 'rule-output\rule-index-mapping.json',
            'rule-output\rule-selector-mapping-gate.json', 'rule-output\collector-rule-correlation.json',
            'contract-output\gateway-interface-resolution.txt', 'contract-output\runtime-contract-record.md',
            'environment\image-inventory.json', 'environment\collector-query.json', 'environment\rule-query.json',
            'metadata-t0.txt', 'metadata.md', 'deviations.md'
        )) {
            $full = Join-Path $dir $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $full -Parent) | Out-Null
            'x' | Set-Content $full
        }
        Test-K8ScoringInputArtifactCompleteness -Range a -RunEvidence $dir
    }
    finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Assert-K8Test 'Completeness gate: the fault-command artifact is required for Range B and every required artifact name has a producer in the module' {
    Import-Module $CommonPath -Force
    $source = Get-Content $CommonPath -Raw
    $completeness = (Get-Command Test-K8ScoringInputArtifactCompleteness).ScriptBlock.Ast.Extent.Text
    if ($completeness -notmatch [regex]::Escape('contract-output\fault-injection-command.txt')) { throw 'the retained fault command is not a required Range B artifact' }
    # Producer/consumer path agreement: every required artifact whose leaf name
    # this module is responsible for writing must appear outside the gate too.
    # (capture-context/sender-record/procedure-conformance come from the frozen
    # Python CLI, so they are legitimately absent from this module's text.)
    $frozenPythonProduced = @('capture-context.json', 'sender-record.txt', 'procedure-conformance.json', 'capture-lifecycle.json', 'c2-original-path.pcap', 'c2-mirror-sensor.pcap', 'metadata-t0.txt')
    $required = [regex]::Matches($completeness, "'((?:contract-output|collector-output|rule-output|environment)\\[^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    $outside = $source.Replace($completeness, '')
    foreach ($r in $required) {
        $leaf = Split-Path $r -Leaf
        if ($frozenPythonProduced -contains $leaf) { continue }
        if ($outside -notmatch [regex]::Escape($leaf)) { throw "required artifact '$r' has no producer anywhere in the module" }
    }
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
