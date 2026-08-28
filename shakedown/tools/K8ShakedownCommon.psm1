#Requires -Version 7.0
<#
    K8ShakedownCommon.psm1

    Shared constants and helpers for the K8-3 Shakedown environment.

    WHAT SHAKEDOWN IS NOT:
      - Not a formal K8-3 reproduction attempt (no k8-repro-* attempt ID is ever
        allocated here).
      - Not Gate K8 evidence. Nothing this module writes is scored, judged, or
        promoted into evidence/reproduction/ in Kakuriyo.
      - Not a change to Study01/ itself. Every function below either shells out
        to Study01's own frozen CLI scripts unmodified, or reproduces a literal
        command already written in Study01/studies/study-01-negative-result/protocol/*.md,
        with only the run ID / paths substituted. It does not reinterpret Range
        A/B/C science.

    WHAT IT IS:
      - A disposable, debuggable workspace (default C:\K8\shakedown) used to walk
        Setup -> Range A -> Range B -> Range C -> finalize/verify once, end to
        end, fixing packaging/runtime/operator-UX problems as they are found,
        before a formal, certified, tagged K8-3 attempt is spent on the same
        problems.

    Every pinned commit/tag/digest below is copied verbatim from
    Study01/README.md SS4.1/4.2 and Study01/studies/study-01-negative-result/protocol/
    c2-dnp3-range-derivation.md. If Study01/README.md's pins ever change, these
    must be re-copied by hand -- they are intentionally not derived by scraping
    the README at runtime, so that a Shakedown run always pins to a value a human
    read and committed, not to whatever the README happens to say this second.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Reuse the formal K8-3 harness's own UTF-16LE-safe wsl.exe capture
# (Get-K8WslField / Invoke-Utf16LEProcessCapture) rather than re-solving a
# problem that module's own history already fixed once (see its docstring:
# wsl.exe writes UTF-16LE to a redirected handle, which PowerShell's ordinary
# native-command pipeline decodes as mojibake). This is read-only reuse --
# Study01/tools/K8AttemptCommon.psm1 itself is never modified by Shakedown.
$script:K8AttemptCommonPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Study01\tools\K8AttemptCommon.psm1'
if (Test-Path $script:K8AttemptCommonPath) {
    Import-Module $script:K8AttemptCommonPath -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Pinned constants (copied verbatim from Study01/README.md SS4.1/4.2 and
# Study01/studies/study-01-negative-result/protocol/c2-dnp3-range-derivation.md,
# c2-dnp3-sender-procedure.md, c2-dnp3-capture-procedure.md)
# ---------------------------------------------------------------------------

$script:K8Shakedown = @{
    AmenonubocoUrl              = 'https://github.com/schutzz/ot-range-amenonuboco'
    RangeGenCommit               = '78fc17746b5d663fafec9dffe563d79fe9ea02b7'   # Range A/B generator (v0.12.0)
    RangeCTag                    = 'v0.13.0'
    RangeCCommit                 = '0378f8a32701b481e030f3db3d5f66ea471a4675'   # Range C validator
    TcpdumpImage                 = 'corfr/tcpdump'
    TcpdumpDigest                = 'sha256:3006b3bd9f041bf73f21e626b97cca5e78fd6ce271549ca95b8e6a508165512b'
    SenderAssetSha256            = '093FEFD5F1F36D715AAE4D7AB91DBAD2D7A93BFE212705D721C95B356A7C053B'
    SenderAssetInContainerPath   = '/study/traffic/send_direct_operate.py'
    GatewayCidr                  = '10.1.20.254/24'
}

function Get-K8ShakedownConstants { $script:K8Shakedown }

# ---------------------------------------------------------------------------
# Workspace / logging
# ---------------------------------------------------------------------------

function Get-K8ShakedownRoot {
    <# Root of the whole disposable Shakedown workspace. Never inside Study01/. #>
    if ($env:K8_SHAKEDOWN_ROOT) { return $env:K8_SHAKEDOWN_ROOT }
    return 'C:\K8\shakedown'
}

function Get-K8ShakedownStatePath { Join-Path (Get-K8ShakedownRoot) 'state.json' }

function Get-K8ShakedownState {
    $p = Get-K8ShakedownStatePath
    if (-not (Test-Path $p)) {
        throw "No Shakedown state found at $p. Run .\tools\Start-K8Shakedown.ps1 first."
    }
    return Get-Content $p -Raw | ConvertFrom-Json
}

function Set-K8ShakedownState {
    param([Parameter(Mandatory)][hashtable] $Updates)
    $root = Get-K8ShakedownRoot
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $p = Get-K8ShakedownStatePath
    $state = if (Test-Path $p) { Get-Content $p -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    foreach ($k in $Updates.Keys) { $state[$k] = $Updates[$k] }
    ($state | ConvertTo-Json -Depth 10) | Set-Content -Path $p -Encoding utf8NoBOM
    return $state
}

function Write-K8ShakedownLog {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'STEP')][string] $Level = 'INFO'
    )
    $root = Get-K8ShakedownRoot
    $logDir = Join-Path $root 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $logFile = Join-Path $logDir 'shakedown.log'
    $line = "[{0}] [{1}] {2}" -f (Get-Date).ToUniversalTime().ToString('o'), $Level, $Message
    Add-Content -Path $logFile -Value $line -Encoding utf8NoBOM
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'STEP'  { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
}

function New-K8ShakedownRunId {
    <#
        Shakedown run IDs are deliberately NOT k8-repro-* (that namespace is
        reserved for formal attempts) so a Shakedown run can never be mistaken
        for, or accidentally filed alongside, formal K8-3 evidence.
    #>
    param([Parameter(Mandatory)][ValidateSet('a', 'b', 'c')][string] $Range)
    $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    return "k8shakedown-range$Range-$ts"
}

# ---------------------------------------------------------------------------
# Fail-closed helpers -- these throw rather than "fixing" anything, per the
# Shakedown rule: the runner records and stops, it does not repair.
# ---------------------------------------------------------------------------

function Invoke-K8ShakedownCommand {
    <#
        Runs an external command, logs its argv/exit code, and throws on a
        non-zero exit unless -AllowExitCodes lists it. Never retries and never
        substitutes a different command on failure.
    #>
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [string[]] $ArgumentList = @(),
        [int[]] $AllowExitCodes = @(0),
        [string] $Description = ''
    )
    $argvDisplay = ($ArgumentList | ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }) -join ' '
    Write-K8ShakedownLog -Level STEP -Message "RUN: $FilePath $argvDisplay $(if ($Description) { "  # $Description" })"
    # Assign directly rather than Tee-Object -Variable: Tee-Object never
    # creates its target variable when the pipeline emits zero objects (a
    # silent command, e.g. `git remote add`), which under Set-StrictMode
    # threw "the variable '$output' cannot be retrieved" -- found by an
    # actual dry run of this script, not assumed.
    $output = @(& $FilePath @ArgumentList 2>&1)
    $exit = $LASTEXITCODE
    $output | ForEach-Object { Write-K8ShakedownLog -Message "  | $_" }
    Write-K8ShakedownLog -Message "EXIT: $exit"
    if ($AllowExitCodes -notcontains $exit) {
        throw "Command failed (exit $exit, expected one of $($AllowExitCodes -join ',')): $FilePath $argvDisplay"
    }
    return [pscustomobject]@{ ExitCode = $exit; Output = $output }
}

function Assert-K8PinnedCommit {
    <#
        Verifies a git worktree's HEAD equals the pinned commit. Never
        auto-corrects a mismatch (no re-checkout, no "close enough") -- a
        mismatch is a STOP condition for the caller to report.
    #>
    param(
        [Parameter(Mandatory)][string] $WorktreePath,
        [Parameter(Mandatory)][string] $ExpectedCommit,
        [Parameter(Mandatory)][string] $Label
    )
    $actual = (git -C $WorktreePath rev-parse HEAD).Trim()
    if ($actual -ne $ExpectedCommit) {
        throw "$Label`: expected pinned commit $ExpectedCommit, found $actual at $WorktreePath. Not proceeding -- this is a STOP condition, not something to auto-fix."
    }
    Write-K8ShakedownLog -Message "$Label pinned-commit check PASS ($actual)"
}

# ---------------------------------------------------------------------------
# The cp932 dependency-decode fix
#
# Root cause (verified against the real pinned artifacts, not assumed):
#   - amenonuboco-v0.13.0/requirements.txt is UTF-8 text with Japanese comment
#     lines, no BOM, and no PEP263 `# coding:` declaration on either of its
#     first two lines.
#   - pip 23.0.1's requirements-file decoder (pip/_internal/utils/encoding.py,
#     auto_decode()) checks only for a BOM or a PEP263 comment; failing both,
#     it decodes straight to locale.getpreferredencoding(False) with NO UTF-8
#     attempt at all. On a Japanese-locale Windows host that is cp932, and
#     cp932 cannot decode the file's UTF-8 multi-byte sequences.
#   - Newer pip (the vendored req_file._decode_req_file added after 23.0.1)
#     tries UTF-8 first and only falls back to the locale encoding on
#     UnicodeDecodeError, which is why this does not reproduce on every pip.
#   - Setting the environment variable PYTHONUTF8=1 makes CPython's own
#     locale.getpreferredencoding(False) return 'UTF-8' regardless of pip
#     version or OS locale (verified: sys.flags.utf8_mode true => this call
#     returns 'UTF-8'), which fixes pip's decode without upgrading pip and
#     without touching Amenonuboco or its requirements.txt in any way.
#   - Reproduced and the fix confirmed end-to-end with pip 23.0.1 (the exact
#     version recorded in evidence/reproduction/k8-repro-20260828-001-v4's
#     environment.json) against the real requirements.txt bytes, on a host
#     whose default locale.getpreferredencoding(False) is itself cp932:
#     without PYTHONUTF8=1 it fails with the exact observed
#     "'cp932' codec can't decode byte 0x81 in position 39" error; with it,
#     `pip install --dry-run -r requirements.txt` resolves pydantic and PyYAML
#     cleanly.
# ---------------------------------------------------------------------------

function Install-K8RangeCDependencies {
    param([Parameter(Mandatory)][string] $RequirementsPath)
    if (-not (Test-Path $RequirementsPath)) {
        throw "Range C requirements file not found: $RequirementsPath"
    }
    $previous = $env:PYTHONUTF8
    try {
        $env:PYTHONUTF8 = '1'
        Write-K8ShakedownLog -Message "Installing Range C dependencies with PYTHONUTF8=1 (cp932 decode fix) from $RequirementsPath"
        Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @('-m', 'pip', 'install', '-r', $RequirementsPath) `
            -Description 'Range C validator dependencies (locale-safe decode)'
    }
    finally {
        if ($null -eq $previous) { Remove-Item Env:\PYTHONUTF8 -ErrorAction SilentlyContinue } else { $env:PYTHONUTF8 = $previous }
    }
}

# ---------------------------------------------------------------------------
# Range A / B shared runner
#
# Range B is, by the frozen protocol's own framing (c2-dnp3-range-derivation.md
# SS3), "the exact Range A derivation and provisioning procedure with only the
# run ID and generated output filename changed" plus exactly one added fault
# (delete the ingress qdisc on the interface carrying 10.1.20.254/24). This
# function implements both from one body so the two cannot silently drift
# apart; -Range selects which literal filename/fault behavior applies. It does
# not change what either Range does -- it mechanically sequences the same
# frozen CLI scripts (study01_preflight.py / study01_capture.py /
# study01_sender.py / study01_collect.py) and the same literal docker/tc
# commands already written in protocol/c2-dnp3-range-derivation.md,
# c2-dnp3-capture-procedure.md, and c2-dnp3-sender-procedure.md, with the run
# ID and paths substituted instead of hand-typed.
#
# What this function deliberately does NOT do (left for the operator, because
# doing it would change the frozen protocol's own epistemic discipline):
#   - It does not write scoring-input.json. README SS6.2 requires that to be
#     transcribed by hand from evidence, derived BEFORE looking at expected/ --
#     this is limitation R6, and auto-generating it would erase the exact
#     discipline the study's own limitations analysis is about. This function
#     stops after finalize/verify-integrity and prints the exact
#     study01_score.py command to run once scoring-input.json exists.
#   - It does not execute the R-OBS-05 Elasticsearch collector query (Range B
#     only). That query is a human correlation judgment against live
#     Elasticsearch, not a mechanical step with a frozen CLI wrapper. This
#     function writes the exact frozen query JSON, with T0 substituted, to
#     contract-output/r-obs-05-query.json for copy/paste, and stops there.
# ---------------------------------------------------------------------------

function Resolve-K8GatewayInterface {
    <# Literal transcription of c2-dnp3-capture-procedure.md SS3. #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence
    )
    $C = Get-K8ShakedownConstants
    $router = (docker compose -p $RunId -f $ComposePath ps -q wan_router | Out-String).Trim()
    $observer = (docker compose -p $RunId -f $ComposePath ps -q tap_observer | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($router) -or [string]::IsNullOrWhiteSpace($observer)) {
        throw "wan_router or tap_observer container was not resolved for $RunId; not starting a helper, not triggering."
    }
    $addrOutput = docker exec $router sh -lc 'ip -br addr' 2>&1
    $contractDir = Join-Path $RunEvidence 'contract-output'
    New-Item -ItemType Directory -Force -Path $contractDir | Out-Null
    $addrOutput | Set-Content -Path (Join-Path $contractDir 'gateway-interface-resolution.txt') -Encoding utf8NoBOM

    $gatewayMatches = @($addrOutput | Where-Object { $_ -match [regex]::Escape($C.GatewayCidr) })
    if ($gatewayMatches.Count -ne 1) {
        throw "Gateway interface resolution: expected exactly 1 line containing $($C.GatewayCidr), found $($gatewayMatches.Count). Not starting a helper, not triggering. See $contractDir\gateway-interface-resolution.txt."
    }
    $token = ($gatewayMatches[0] -split '\s+' | Where-Object { $_ })[1]
    $resolvedIf = ($token -split '@', 2)[0]
    if ([string]::IsNullOrWhiteSpace($resolvedIf)) {
        throw 'capture device name was not resolved'
    }
    Write-K8ShakedownLog -Message "Resolved gateway interface: $resolvedIf (from token '$token')"
    return [pscustomobject]@{ Router = $router; Observer = $observer; Interface = $resolvedIf }
}

function Invoke-K8ShakedownRangeAB {
    param(
        [Parameter(Mandatory)][ValidateSet('a', 'b')][string] $Range
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $state = Get-K8ShakedownState
    $C = Get-K8ShakedownConstants
    $Study01 = Join-Path $state.repo_root 'Study01'
    $ScriptsDir = Join-Path $Study01 'studies\study-01-negative-result\scripts'
    $SenderAssetHost = Join-Path $ScriptsDir '..\experiments\shared\traffic\send_direct_operate.py' | Resolve-Path
    $WorktreeDir = $state.amenonuboco_gen_dir

    $RunId = New-K8ShakedownRunId -Range $Range
    $RunEvidence = Join-Path $state.shakedown_root "runs\$RunId"
    $ComposeFile = "power-grid-reference.range-$Range.docker-compose.yml"
    $ComposePath = Join-Path $WorktreeDir "manifests\$ComposeFile"

    Write-K8ShakedownLog -Level STEP -Message "=== Shakedown Range $($Range.ToUpper()) starting: $RunId ==="

    # 1. Run evidence tree, via the frozen evidence_tree.create() -- not reimplemented here.
    $createScript = "import sys; sys.path.insert(0, r'$ScriptsDir'); from pathlib import Path; from study01.evidence_tree import create; create(Path(r'$RunEvidence'))"
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @('-c', $createScript) -Description 'run evidence tree (frozen evidence_tree.create)'

    # 2. Generate the Compose file fresh for this run (never reuse a stale one).
    Push-Location $WorktreeDir
    try {
        Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @('platform/cli.py', 'provision', 'manifests/power-grid-reference.yaml', '-o', "manifests/$ComposeFile") `
            -Description "generate Range $($Range.ToUpper()) Compose file"
    }
    finally { Pop-Location }
    $envDir = Join-Path $RunEvidence 'environment'
    $composeHash = (Get-FileHash -Path $ComposePath -Algorithm SHA256).Hash
    "generated compose SHA-256 (within-run integrity record only, per c2-dnp3-range-derivation.md SS2.2): $composeHash" |
        Set-Content -Path (Join-Path $envDir 'generated-compose-hash.txt') -Encoding utf8NoBOM

    # 3. Execution preflight gate -- do not provision if this fails.
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @(
        (Join-Path $ScriptsDir 'study01_preflight.py'),
        '--run-id', $RunId, '--worktree', $WorktreeDir, '--compose', $ComposePath,
        '--run-evidence', $RunEvidence, '--project-name', $RunId, '--teardown-target', $RunId,
        '--shell-probe', $PSVersionTable.PSVersion.ToString(),
        '--path-probe', '/study/traffic/send_direct_operate.py', '/data/c2-original-path.pcap', '/data/c2-mirror-sensor.pcap'
    ) -Description 'execution preflight gate (Docker-free)' |
        ForEach-Object { $_.Output | Set-Content -Path (Join-Path $envDir 'preflight.txt') -Encoding utf8NoBOM }

    # 4. Provision.
    Invoke-K8ShakedownCommand -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'up', '-d', '--build') `
        -Description "provision Range $($Range.ToUpper())"

    # 4a. Environment readiness: wait for every defined service to report a
    # running state before doing anything else (README SS5.1 step 4:
    # "establish readiness ... before the event window opens"). Fails closed
    # on timeout rather than proceeding against a half-up stack.
    Wait-K8ComposeReady -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence

    # 4b. Full image inventory (c2-dnp3-image-inventory.md SS4), before trigger:
    # per-service image reference/ID from `compose images`, THEN `docker image
    # inspect` on each resolved ID for its immutable Id + RepoDigests, exactly
    # as the frozen collection command specifies -- not just the compose-level
    # summary.
    Write-K8ImageInventory -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence

    # 5. Resolve gateway interface (needed for capture AND, on Range B, the fault).
    $gw = Resolve-K8GatewayInterface -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence

    # 6. Range B only: the sole permitted fault.
    if ($Range -eq 'b') {
        Write-K8ShakedownLog -Level STEP -Message '--- Range B fault: deleting ingress qdisc on the resolved gateway interface ---'
        $contractDir = Join-Path $RunEvidence 'contract-output'
        $pre = @()
        $pre += docker exec $gw.Router tc qdisc show dev $gw.Interface 2>&1
        $pre += docker exec $gw.Router tc filter show dev $gw.Interface parent ffff: 2>&1
        $pre | Set-Content -Path (Join-Path $contractDir 'qdisc-pre-fault.txt') -Encoding utf8NoBOM
        Invoke-K8ShakedownCommand -FilePath 'docker' -ArgumentList @('exec', $gw.Router, 'tc', 'qdisc', 'del', 'dev', $gw.Interface, 'ingress') `
            -Description 'Range B fault: delete ingress qdisc (the sole permitted fault)'
        $post = docker exec $gw.Router tc filter show dev $gw.Interface parent ffff: 2>&1
        $post | Set-Content -Path (Join-Path $contractDir 'qdisc-post-fault.txt') -Encoding utf8NoBOM
    }

    # 6a. Runtime contract observational record (evidence-schema.md SS3: "Range
    # A/B runtime-invariant record in contract-output/"). This retains what is
    # mechanically observable; it is NOT the scored Runtime Contract
    # Pass/Fail/Unresolved verdict itself -- that is derived by the operator at
    # scoring-input time (README SS6.2), from this record plus the other
    # stages.
    Write-K8RuntimeContractRecord -Range $Range -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence -Gateway $gw

    # 7. Capture: resolve then start, both stages, in this fixed order.
    foreach ($stage in @('ground-truth', 'sensor')) {
        Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @(
            (Join-Path $ScriptsDir 'study01_capture.py'), 'resolve',
            '--run-id', $RunId, '--run-evidence', $RunEvidence, '--stage', $stage, '--compose', $ComposePath
        ) -Description "capture context resolve: $stage"
    }
    foreach ($stage in @('ground-truth', 'sensor')) {
        Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @(
            (Join-Path $ScriptsDir 'study01_capture.py'), 'start',
            '--run-id', $RunId, '--run-evidence', $RunEvidence, '--stage', $stage
        ) -Description "capture helper start: $stage"
    }

    # 8. Sender: directory prep -> docker cp -> hash verify -> exactly one invocation.
    $senderContainer = (docker compose -p $RunId -f $ComposePath ps -q sub_a_ied_02 | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($senderContainer)) { throw 'sub_a_ied_02 container was not resolved' }
    Invoke-K8ShakedownCommand -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'exec', '-T', 'sub_a_ied_02', 'sh', '-lc', 'mkdir -p /study/traffic') `
        -Description 'sender directory preparation'
    Invoke-K8ShakedownCommand -FilePath 'docker' -ArgumentList @('cp', $SenderAssetHost.Path, "${senderContainer}:$($C.SenderAssetInContainerPath)") `
        -Description 'sender asset placement (docker cp is the only permitted mechanism)'
    $shaOut = (docker compose -p $RunId -f $ComposePath exec -T sub_a_ied_02 sh -lc "sha256sum $($C.SenderAssetInContainerPath)" | Out-String)
    $inContainerSha = ($shaOut.Trim().Split()[0]).ToUpperInvariant()
    if ($inContainerSha -ne $C.SenderAssetSha256) {
        throw "sender hash mismatch: expected $($C.SenderAssetSha256), got $inContainerSha"
    }
    Write-K8ShakedownLog -Message "sender asset hash verified in-container: $inContainerSha"

    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @(
        (Join-Path $ScriptsDir 'study01_sender.py'), '--run-id', $RunId, '--run-evidence', $RunEvidence, '--',
        'docker', 'compose', '-p', $RunId, '-f', $ComposePath, 'exec', '-T', 'sub_a_ied_02',
        'python3', $C.SenderAssetInContainerPath, '--target-ip', '10.1.10.10', '--target-port', '20000', '--function-code', '5', '--repeat', '1'
    ) -Description 'the one frozen trigger invocation (T0)'

    # 9. Stop/export both captures (covers the settle window internally per capture.py).
    foreach ($stage in @('ground-truth', 'sensor')) {
        Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @(
            (Join-Path $ScriptsDir 'study01_capture.py'), 'stop-export',
            '--run-id', $RunId, '--run-evidence', $RunEvidence, '--stage', $stage
        ) -Description "capture stop/export: $stage"
    }

    # 10. Write the frozen Collector and Rule queries (freeze-decision-table.md
    # SS3) with T0 substituted, plus the Range B R-OBS-05 query, for MANUAL
    # execution against the still-running Elasticsearch. These are written to
    # environment/ (not into collector-output/ / rule-output/ themselves) so
    # that those two RUNTIME_DIRS stay genuinely empty until the operator
    # saves a real response into them -- study01_collect.py validate-evidence
    # requires at least one retained file in every one of ground-truth,
    # sensor-input, collector-output, rule-output, and contract-output, and a
    # query template is not a response.
    $t0Path = Join-Path $RunEvidence 'ground-truth\metadata-t0.txt'
    if (-not (Test-Path $t0Path)) {
        throw "T0 record not found at $t0Path after stop-export; cannot window the Collector/Rule queries. This is a STOP condition -- do not proceed to teardown without it."
    }
    $t0 = (Get-Content $t0Path -Raw).Trim()
    $windowStart = ([datetimeoffset]::Parse($t0)).AddSeconds(-5).ToString('o')
    $windowEnd = ([datetimeoffset]::Parse($t0)).AddSeconds(15).ToString('o')

    $collectorQuery = (Get-Content (Join-Path $PSScriptRoot 'collector-query.template.json') -Raw).Replace('<WINDOW_START>', $windowStart).Replace('<WINDOW_END>', $windowEnd)
    $collectorQuery | Set-Content -Path (Join-Path $envDir 'collector-query.json') -Encoding utf8NoBOM
    $ruleQuery = (Get-Content (Join-Path $PSScriptRoot 'rule-query.template.json') -Raw).Replace('<WINDOW_START>', $windowStart).Replace('<WINDOW_END>', $windowEnd)
    $ruleQuery | Set-Content -Path (Join-Path $envDir 'rule-query.json') -Encoding utf8NoBOM
    Write-K8ShakedownLog -Message "Collector query (ot-logs-dnp3-*) and Rule query (ot-signals-zone-violation-*) written to environment/ with T0 window [$windowStart, $windowEnd]. VERIFY field mapping (GET <index>/_mapping) before trusting term matches -- freeze-decision-table.md SS3."

    if ($Range -eq 'b') {
        $r0query = (Get-Content (Join-Path $PSScriptRoot 'r-obs-05-query.template.json') -Raw).Replace('<WINDOW_START>', $windowStart).Replace('<WINDOW_END>', $windowEnd)
        $r0query | Set-Content -Path (Join-Path $envDir 'r-obs-05-query.json') -Encoding utf8NoBOM
        Write-K8ShakedownLog -Message "R-OBS-05 query (k6-r-obs-05-collector-query-contract.md) written to environment/. This is a human correlation judgment, not automated by this runner."
    }

    # 11. metadata.md / deviations.md -- required by study01_collect.py validate-evidence.
    # Templated from facts this runner already retained; free-text additions are still
    # the operator's -- this only removes the mechanical transcription of what the
    # machine-readable records already say. Cleanup is NOT YET performed (see below),
    # so this is updated again by Complete-K8ShakedownRangeAB once it is.
    @"
# Run metadata -- $RunId (Shakedown, NOT a formal K8-3 attempt, NOT Gate K8 evidence)

| Field | Value |
| --- | --- |
| Range | $($Range.ToUpper()) |
| Compose project / run ID | $RunId |
| Compose file | $ComposePath |
| Generated compose SHA-256 (within-run only) | $composeHash |
| Amenonuboco worktree | $WorktreeDir (pinned $($C.RangeGenCommit)) |
| Gateway interface | $($gw.Interface) |
| Sender container | $senderContainer |
| Sender asset in-container SHA-256 | $inContainerSha |
| tcpdump helper image | $($state.tcpdump_image_ref) |
| Cleanup | NOT YET PERFORMED -- range is still up pending manual Collector/Rule query execution. Run .\tools\Complete-K8ShakedownRange.ps1 once environment/collector-output and environment/rule-output responses are saved. |

See environment/, ground-truth/, sensor-input/, contract-output/ for the machine-recorded per-step argv/exit-code/timestamp evidence this table summarizes.
"@ | Set-Content -Path (Join-Path $RunEvidence 'metadata.md') -Encoding utf8NoBOM

    $deviationsBody = if ($Range -eq 'b') {
        "# Deviations -- $RunId`n`nNo unplanned deviations recorded by this runner. The ingress-qdisc deletion on the resolved gateway interface is the frozen Range B experimental condition, not a deviation -- see contract-output/qdisc-pre-fault.txt / qdisc-post-fault.txt.`n"
    } else {
        "# Deviations -- $RunId`n`nNo unplanned deviations recorded by this runner.`n"
    }
    $deviationsBody | Set-Content -Path (Join-Path $RunEvidence 'deviations.md') -Encoding utf8NoBOM

    # 12. STOP HERE. The range is deliberately left running: the Collector and
    # Rule queries (and, on Range B, R-OBS-05) can only be executed against a
    # live Elasticsearch, and evidence-schema.md's own cleanup ordering
    # ("only after every required artifact has been exported and hashed...
    # remove the project") means teardown must come AFTER those responses are
    # saved, not before. Automatically tearing down here, before those queries
    # can be run, would make target-event Collector/Rule evidence permanently
    # unobtainable for this run.
    Set-K8ShakedownState -Updates @{
        "range_$($Range)_run_id"      = $RunId
        "range_$($Range)_evidence"    = $RunEvidence
        "range_$($Range)_compose"     = $ComposePath
        "range_$($Range)_stage"       = 'awaiting-manual-queries'
    }

    Write-K8ShakedownLog -Level STEP -Message "=== Shakedown Range $($Range.ToUpper()) mechanical steps PASS, range left running: $RunId ==="
    Write-Host ''
    Write-Host "Range $($Range.ToUpper()) run '$RunId' is up and captured. The range is still running. Next:"
    Write-Host "  1. Run $envDir\collector-query.json against ot-logs-dnp3-*; save the RAW response as $RunEvidence\collector-output\collector-response.json"
    Write-Host "  2. Run $envDir\rule-query.json against ot-signals-zone-violation-*; save the RAW response as $RunEvidence\rule-output\rule-response.json"
    if ($Range -eq 'b') {
        Write-Host "  3. Run $envDir\r-obs-05-query.json against ot-logs-dnp3-*; save the RAW response under $RunEvidence\contract-output\ (k6-r-obs-05-collector-query-contract.md)."
    }
    Write-Host "  4. Then: .\tools\Complete-K8ShakedownRange.ps1 -Range $Range"
    return $RunEvidence
}

function Wait-K8ComposeReady {
    <#
        Polls `docker compose ps --format json` until every defined service
        reports a running state, or throws on timeout. README SS5.1 step 4
        requires readiness before capture context resolution; this makes that
        an explicit, fail-closed gate instead of an assumption.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence,
        [int] $TimeoutSeconds = 120,
        [int] $PollSeconds = 3
    )
    $envDir = Join-Path $RunEvidence 'environment'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastRaw = ''
    while ((Get-Date) -lt $deadline) {
        $lastRaw = (docker compose -p $RunId -f $ComposePath ps --format json 2>&1 | Out-String)
        try {
            # `compose ps --format json` emits either a single JSON array or
            # newline-delimited JSON objects depending on Compose version;
            # handle both rather than assuming one.
            $parsed = try { $lastRaw | ConvertFrom-Json } catch {
                @($lastRaw -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
            }
            $services = @($parsed)
            if ($services.Count -gt 0 -and -not ($services | Where-Object { $_.State -and $_.State -ne 'running' })) {
                $lastRaw | Set-Content -Path (Join-Path $envDir 'readiness.json') -Encoding utf8NoBOM
                Write-K8ShakedownLog -Message "Environment readiness PASS: $($services.Count) service(s) running."
                return
            }
        }
        catch {
            Write-K8ShakedownLog -Level WARN -Message "readiness poll: could not parse 'compose ps --format json' output, retrying: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $PollSeconds
    }
    $lastRaw | Set-Content -Path (Join-Path $envDir 'readiness.json') -Encoding utf8NoBOM
    throw "Environment readiness timed out after ${TimeoutSeconds}s; not all services reached 'running'. See environment/readiness.json. Not proceeding to capture/trigger."
}

function Write-K8ImageInventory {
    <#
        c2-dnp3-image-inventory.md SS4's exact collection: `compose images
        --format json` for the effective per-service references, THEN
        `docker image inspect <id> --format '{{.Id}} {{json .RepoDigests}}'`
        on each -- not just the compose-level summary alone.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence
    )
    $envDir = Join-Path $RunEvidence 'environment'
    $psJson = docker compose -p $RunId -f $ComposePath images --format json 2>&1
    $psJson | Set-Content -Path (Join-Path $envDir 'compose-images.json') -Encoding utf8NoBOM
    (docker compose -p $RunId -f $ComposePath ps 2>&1) | Set-Content -Path (Join-Path $envDir 'compose-ps.txt') -Encoding utf8NoBOM

    $inspectLines = @()
    try {
        $images = try { $psJson | Out-String | ConvertFrom-Json } catch {
            @(($psJson | Out-String) -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
        }
        foreach ($img in @($images)) {
            $ref = if ($img.ID) { $img.ID } elseif ($img.Repository -and $img.Tag) { "$($img.Repository):$($img.Tag)" } else { $null }
            if (-not $ref) { continue }
            $inspected = (docker image inspect $ref --format '{{.Id}} {{json .RepoDigests}}' 2>&1 | Out-String).Trim()
            $service = if ($img.ContainerName) { $img.ContainerName } elseif ($img.Service) { $img.Service } else { '(unknown service)' }
            $inspectLines += "$service`t$ref`t$inspected"
        }
    }
    catch {
        Write-K8ShakedownLog -Level WARN -Message "Could not fully parse 'compose images --format json' for per-role docker image inspect; compose-images.json is still retained raw. $($_.Exception.Message)"
    }
    $inspectLines | Set-Content -Path (Join-Path $envDir 'image-inventory.txt') -Encoding utf8NoBOM
    Write-K8ShakedownLog -Message "Image inventory: $($inspectLines.Count) service(s) inspected (see environment/image-inventory.txt, environment/compose-images.json)."
}

function Write-K8RuntimeContractRecord {
    <#
        evidence-schema.md SS3's "Range A/B runtime-invariant record." Retains
        what is mechanically observable. Does NOT compute the scored Runtime
        Contract Pass/Fail/Unresolved verdict -- README SS6.2 reserves that
        derivation for the operator, from this record plus the other stages.

        For Range B, c2-dnp3-step4-range-b-fault-pilot.md SS3 lists four
        required nontriviality checks. Checks 1-3 are mechanized here (service
        state, target-interface mirror filter removal, Elasticsearch
        health/zone_detector liveness via docker exec -- no host port-mapping
        knowledge required). Check 2's "one unrelated observed gateway
        interface still has a mirred egress mirror filter" and check 4's
        sensor-capture unrelated-frame content are explicitly NOT mechanized
        here (they need generated-topology / pcap-content knowledge this
        script does not have) and are marked "REQUIRES MANUAL CONFIRMATION"
        rather than guessed at.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('a', 'b')][string] $Range,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence,
        [Parameter(Mandatory)] $Gateway
    )
    $contractDir = Join-Path $RunEvidence 'contract-output'
    $psText = (docker compose -p $RunId -f $ComposePath ps 2>&1 | Out-String)
    $lines = @()
    $lines += "# Runtime contract observational record -- $RunId"
    $lines += ''
    $lines += 'This is a retained observation, not the scored Runtime Contract verdict (README SS6.2 derives that by hand).'
    $lines += ''
    $lines += '## docker compose ps'
    $lines += '```'
    $lines += $psText.TrimEnd()
    $lines += '```'

    if ($Range -eq 'b') {
        $requiredServices = @('wan_router', 'tap_observer', 'log_structurer', 'elasticsearch', 'zone_detector')
        $missing = @($requiredServices | Where-Object { $psText -notmatch [regex]::Escape($_) })
        $lines += ''
        $lines += '## c2-dnp3-step4-range-b-fault-pilot.md SS3 nontriviality checks'
        $lines += ''
        $lines += "1. Required services present in \`compose ps\`: $(if ($missing.Count -eq 0) { 'PASS (all of ' + ($requiredServices -join ', ') + ' found)' } else { 'FAIL -- missing: ' + ($missing -join ', ') })"
        $lines += "2. Target-interface ($($Gateway.Interface)) mirror filter removed: see qdisc-pre-fault.txt / qdisc-post-fault.txt in this directory. 'One unrelated observed gateway interface still has a mirred egress mirror filter' -- **REQUIRES MANUAL CONFIRMATION** (needs the generated topology's other interfaces, not resolved by this script)."
        try {
            $esContainer = (docker compose -p $RunId -f $ComposePath ps -q elasticsearch | Out-String).Trim()
            if ($esContainer) {
                $esHealth = (docker exec $esContainer curl -s -o /dev/null -w '%{http_code}' http://localhost:9200/_cluster/health 2>&1 | Out-String).Trim()
                $zoneDetectorUp = $psText -match 'zone_detector' -and $psText -notmatch 'zone_detector.*Exit'
                $lines += "3. Elasticsearch health check (docker exec -> curl localhost:9200/_cluster/health): HTTP $esHealth; zone_detector running: $zoneDetectorUp"
            }
            else {
                $lines += '3. Elasticsearch health check: FAIL -- elasticsearch container not resolved via compose ps -q.'
            }
        }
        catch {
            $lines += "3. Elasticsearch health check: could not execute ($($_.Exception.Message)) -- REQUIRES MANUAL CONFIRMATION."
        }
        $lines += '4. Sensor capture contains at least one unrelated frame during the window -- **REQUIRES MANUAL CONFIRMATION** (needs pcap content inspection; not performed by this script beyond the capture-lifecycle record already retained under sensor-input/).'
    }

    $lines -join "`n" | Set-Content -Path (Join-Path $contractDir 'runtime-contract-record.md') -Encoding utf8NoBOM
    Write-K8ShakedownLog -Message 'Runtime contract observational record written to contract-output/runtime-contract-record.md.'
}

function Complete-K8ShakedownRangeAB {
    <#
        Second half of a Range A/B Shakedown run: run this AFTER saving the
        Collector/Rule (and, for Range B, R-OBS-05) query responses into
        collector-output/ / rule-output/ / contract-output/. Tears down the
        range, updates metadata.md's cleanup row, and runs
        validate-evidence/finalize-evidence/verify-integrity. Never fills in a
        missing response itself -- an empty collector-output/ or rule-output/
        is a STOP condition here, exactly as it is for study01_collect.py.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('a', 'b')][string] $Range
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $state = Get-K8ShakedownState
    $stageKey = "range_$($Range)_stage"
    if (-not $state.PSObject.Properties[$stageKey] -or $state.$stageKey -ne 'awaiting-manual-queries') {
        throw "No Range $($Range.ToUpper()) run is awaiting completion (state.$stageKey = $(if ($state.PSObject.Properties[$stageKey]) { $state.$stageKey } else { '<none>' })). Run .\tools\Run-K8ShakedownRange$($Range.ToUpper()).ps1 first."
    }
    $RunId = $state."range_$($Range)_run_id"
    $RunEvidence = $state."range_$($Range)_evidence"
    $ComposePath = $state."range_$($Range)_compose"
    $Study01 = Join-Path $state.repo_root 'Study01'
    $ScriptsDir = Join-Path $Study01 'studies\study-01-negative-result\scripts'

    Write-K8ShakedownLog -Level STEP -Message "=== Completing Shakedown Range $($Range.ToUpper()): $RunId ==="

    foreach ($dir in @('collector-output', 'rule-output')) {
        $full = Join-Path $RunEvidence $dir
        if (-not (Get-ChildItem -Path $full -File -Recurse -ErrorAction SilentlyContinue)) {
            throw "$dir is still empty. Save the real query response there first (see environment/collector-query.json / environment/rule-query.json and the instructions printed by Run-K8ShakedownRange$($Range.ToUpper()).ps1). Not tearing down or finalizing until it is -- an empty directory here is not something this script fills in."
        }
    }
    if ($Range -eq 'b') {
        $contractFiles = Get-ChildItem -Path (Join-Path $RunEvidence 'contract-output') -File -ErrorAction SilentlyContinue
        if (-not ($contractFiles | Where-Object { $_.Name -match 'r-obs-05' })) {
            Write-K8ShakedownLog -Level WARN -Message 'No r-obs-05*-named file found in contract-output/ yet. Confirm the R-OBS-05 response was saved before trusting Range B Runtime Contract as Pass -- not blocking finalize, since R-OBS-05 evidence may be saved under a different filename.'
        }
    }

    # Cleanup: export/hash of what's already retained is complete; now destroy the project.
    Invoke-K8ShakedownCommand -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'down', '-v', '--remove-orphans') `
        -Description 'destroy project + volumes (prevent state carry-over)'
    $finalPs = (docker compose -p $RunId -f $ComposePath ps 2>&1 | Out-String)
    $finalPs | Add-Content -Path (Join-Path $RunEvidence 'environment\compose-ps.txt') -Encoding utf8NoBOM

    (Get-Content (Join-Path $RunEvidence 'metadata.md') -Raw) -replace `
        '\| Cleanup \| NOT YET PERFORMED.*\|', `
        "| Cleanup | destroyed via 'docker compose down -v --remove-orphans' at $((Get-Date).ToUniversalTime().ToString('o')); final ps: see environment/compose-ps.txt |" |
        Set-Content -Path (Join-Path $RunEvidence 'metadata.md') -Encoding utf8NoBOM

    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $ScriptsDir 'study01_collect.py'), 'validate-evidence', $RunEvidence) -Description 'validate-evidence'
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $ScriptsDir 'study01_collect.py'), 'finalize-evidence', $RunEvidence) -Description 'finalize-evidence'
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $ScriptsDir 'study01_collect.py'), 'verify-integrity', $RunEvidence) -Description 'verify-integrity'

    Set-K8ShakedownState -Updates @{ $stageKey = 'complete'; "range_$($Range)_complete_utc" = (Get-Date).ToUniversalTime().ToString('o') }

    Write-K8ShakedownLog -Level STEP -Message "=== Shakedown Range $($Range.ToUpper()) complete: $RunId ==="
    Write-Host ''
    Write-Host "Range $($Range.ToUpper()) run '$RunId' finalized/verified. Remaining manual step (by protocol design, not automated):"
    Write-Host "  README SS6.2: derive scoring-input.json by hand from $RunEvidence BEFORE opening expected/, then:"
    Write-Host "  python `"$(Join-Path $ScriptsDir 'study01_score.py')`" <path-to-scoring-input.json> --run-evidence `"$RunEvidence`" --output `"$RunEvidence\score.json`""
    return $RunEvidence
}

Export-ModuleMember -Function * -Variable K8Shakedown
