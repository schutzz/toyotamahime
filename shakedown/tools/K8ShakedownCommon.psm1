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

function Invoke-K8SeparatedNativeCapture {
    <#
        Runs a native command with STDOUT and STDERR captured into SEPARATE
        values -- never merged via `2>&1` -- for exactly one purpose: this
        module parsing that command's stdout as machine-readable data (JSON,
        TSV, a bare container ID/SHA/HTTP status).

        Root cause this exists to fix (independent review, real VM run
        k8shakedown-rangea-20260829-033618): `docker exec ... tshark ...
        2>&1` merged tshark's own "Running as user root and group root.
        This could be dangerous." stderr warning into the captured stdout,
        which the caller then tried to parse as a 9-column TSV row and
        threw "unexpected tshark row shape." This was a Shakedown parser
        defect, not a scientific finding, and the fix is structural stream
        separation -- NOT a hardcoded exclusion of that one warning string,
        which would only mask the next tool's next unrelated stderr line.

        Cross-audited (same review round) for the same defect class across
        every OTHER call site in this module that parses stdout as
        structured data (JSON via ConvertFrom-Json, an exact single-value
        match, a fixed-column TSV row) and fixed at each -- see this
        function's callers. Call sites that only ever retain output as a
        raw text log for human review (never parsed for a machine
        decision) were deliberately left on `2>&1`, since merging stderr
        into a HUMAN-READ transcript is correct, not a defect.

        Exit code is always the real native exit code (never swallowed);
        stderr is always returned so a caller can put it in a fail-closed
        diagnostic rather than discarding it.
    #>
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [string[]] $ArgumentList = @()
    )
    $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-stderr-" + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        $stdout = @(& $FilePath @ArgumentList 2>$stderrFile)
        $exitCode = $LASTEXITCODE
        $stderr = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw } else { '' }
    }
    finally {
        Remove-Item $stderrFile -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ Stdout = $stdout; Stderr = $(if ($stderr) { $stderr } else { '' }); ExitCode = $exitCode }
}

function ConvertTo-K8PythonExecOneLiner {
    <#
        Flattens a multi-line `python3 -c` script into a single logical line
        with no embedded newline byte, by wrapping it in exec('...') and
        replacing real newlines with Python's own `\n` string escape (which
        exec()'s string literal decodes back into a real newline when the
        code actually runs) -- the same "let the consumer's own escape
        syntax do the work, never smuggle a raw control character through an
        argv boundary" principle as the curl `-w` `\n` fix elsewhere in this
        module.

        Found necessary during this round's own regression testing: this
        module's docker mock (tests/mock-docker) is invoked through a .cmd
        batch trampoline so it resolves as a real external process (the same
        Application-type resolution as real docker.exe, not the PS1
        Script-type resolution that would run it in-process and mask stderr
        behavior). cmd.exe is a line-oriented interpreter -- a literal
        embedded newline inside a single argument corrupts its OWN
        command-line parsing before the batch file's body ever runs,
        silently truncating/splitting the argument (confirmed by direct A/B
        testing: identical args survive intact through a raw native process,
        but not through a .cmd trampoline). Real docker.exe is a native
        binary and never has this problem, but flattening the source here
        removes the dependency on a raw control character surviving several
        stacked process boundaries at all, which is worth doing regardless
        of the mock.
    #>
    param([Parameter(Mandatory)][string] $Script)
    $escaped = $Script.Replace('\', '\\').Replace("'", "\'").Replace("`r`n", "`n").Replace("`n", '\n')
    return "exec('$escaped')"
}

function Invoke-K8ShakedownLoggedCommand {
    <# Runs a noisy native command with its complete combined output redirected
       to a per-run Shakedown runtime log outside the scientific evidence tree.
       Only failures echo a bounded tail to the console. #>
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [string[]] $ArgumentList = @(),
        [Parameter(Mandatory)][string] $LogPath,
        [string] $Description = '',
        [int] $FailureTailLines = 50
    )
    $argvDisplay = ($ArgumentList | ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }) -join ' '
    $parent = Split-Path -Parent $LogPath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Write-K8ShakedownLog -Level STEP -Message "RUN: $FilePath $argvDisplay $(if ($Description) { "  # $Description" }) (full output: $LogPath)"
    # Inspect the native exit code ourselves so a host-level preference cannot
    # throw before the bounded failure-tail/reporting path runs.
    $PSNativeCommandUseErrorActionPreference = $false
    & $FilePath @ArgumentList *> $LogPath
    $exit = $LASTEXITCODE
    Write-K8ShakedownLog -Message "EXIT: $exit (full output: $LogPath)"
    if ($exit -ne 0) {
        Write-K8ShakedownLog -Level ERROR -Message "Command failed; last $FailureTailLines log lines follow:"
        Get-Content -LiteralPath $LogPath -Tail $FailureTailLines | ForEach-Object {
            Write-K8ShakedownLog -Level ERROR -Message "  | $_"
        }
        throw "Command failed (exit $exit): $FilePath $argvDisplay. Full Shakedown runtime log: $LogPath"
    }
    return [pscustomobject]@{ ExitCode=$exit; LogPath=$LogPath }
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
# study01_sender.py / study01_collect.py), the fixed Collector/Rule/R-OBS-05
# queries against Elasticsearch (mechanical: fetching a mapping, running a
# fixed query, saving the raw response, and computing a mechanical
# correlation are automated; only the SCIENTIFIC judgment of what a result
# means is left to the operator at scoring-input time), and the same literal
# docker/tc commands already written in protocol/c2-dnp3-range-derivation.md,
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
#   - It does not decide what a Collector/Rule/R-OBS-05 result MEANS
#     scientifically (Pass/Fail/Unresolved for scoring purposes). It runs the
#     fixed query, saves the raw response, and computes the fixed mechanical
#     correlation the freeze documents themselves define; the classification
#     of that into a scored field happens by hand at README SS6.2.
#
# LEAST-VERIFIED PART OF THIS FILE: the pcap-to-document nanosecond
# correlation in k8_shakedown_evidence.py, and the tshark `-T fields` names
# used by Write-K8UnrelatedPcapRows, have never been run against a real DNP3 capture
# or a real Elasticsearch response in this development environment (no
# Docker daemon / no live stack was available while writing this). Treat
# their output as provisional until the first real VM run confirms the
# field names and precision handling against actual retained bytes -- the
# raw tshark/ES output is always retained alongside the computed result
# specifically so a human can redo the exact SS4 decimal-nanosecond
# comparison by hand if this code's approximation is ever in doubt.
#
# CROSS-SERVICE STARTUP-RACE AUDIT (independent review round 2, after the
# curl-exit-7 failure): every generator in the pinned Amenonuboco commit
# (78fc17746b5d663fafec9dffe563d79fe9ea02b7) that runs an install step
# before its real payload was enumerated by grepping
# platform/generators/*.py for apt-get/apt/pip/apk install, at that exact
# commit -- not guessed. Exactly three exist:
#   1. structuring.py (log_structurer): apt-get tshark/python3, then the
#      tshark|bulk_loader.py DNP3 pipeline -- BLOCKER, gated by
#      Wait-K8LogStructurerReady.
#   2. plugins.py (zone_detector): pip install <requires>, then the
#      signal-1-zone-violation plugin -- BLOCKER, gated by
#      Wait-K8ZoneDetectorReady.
#   3. compose.py's _INSTALL_IPROUTE2 (any non-gateway asset needing
#      `ip route add`, and wan_router itself for its own mirror/qdisc
#      setup): `(command -v ip || apt-get install iproute2 || apk add
#      iproute2)`. NOT separately gated here, and deliberately so: unlike
#      the two above, this race fails LOUDLY rather than silently. Every
#      Shakedown command against wan_router that depends on `ip`/`tc`
#      (Resolve-K8GatewayInterface, the Range B fault) already throws
#      immediately if the binary is not yet present -- e.g.
#      Resolve-K8GatewayInterface's own "found $($gatewayMatches.Count)"
#      check throws on zero matches, which is exactly what an
#      `ip: not found` stderr line inside $addrOutput produces. A loud,
#      immediate STOP is not the silent-scientific-corruption shape the
#      other two gates exist to prevent, so no additional gate was added
#      for it; this is a recorded audit conclusion, not an oversight.
# No other generator (mirroring.py, impairment.py, attack.py, shell.py,
# visualization/*) contains an install-then-exec pattern at this pinned
# commit.
# ---------------------------------------------------------------------------

function Get-K8ExpectedServices {
    <# The Compose file's own declared service set -- not a hardcoded list,
       so a manifest variant with more/fewer services is still checked
       correctly against itself. STDOUT/STDERR captured separately: a
       Compose deprecation notice or similar warning on stderr must not be
       merged in and mistaken for a service name. #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath
    )
    $capture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'config', '--services')
    if ($capture.ExitCode -ne 0) {
        throw "'docker compose config --services' failed for $ComposePath (exit $($capture.ExitCode)). stderr: $($capture.Stderr.Trim())"
    }
    $services = @($capture.Stdout | Where-Object { $_ -and $_.Trim() })
    if ($services.Count -eq 0) {
        throw "Could not determine the expected service set via 'compose config --services' for $ComposePath; not proceeding without knowing what 'ready' means."
    }
    return ,$services
}

function ConvertFrom-K8ConcatenatedJson {
    <#
        Splits $Raw into one or more top-level JSON values (each a balanced
        `{...}` object or `[...]` array), tracking bracket depth and string
        literal/escape state -- NOT naive newline-splitting.

        Root cause this exists to fix (real VM run k8shakedown-rangea-
        20260829-071142, independent review): the prior ConvertFrom-K8ComposePsJson
        tried `$Raw | ConvertFrom-Json` once, and on ANY failure fell back to
        `$Raw -split "`n" | ForEach-Object { ConvertFrom-Json }` with no
        further diagnostic -- a strategy that assumes Compose's `ps --all
        --format json` is always either one compact single-line array, or
        compact one-object-per-line NDJSON, and gives up with a bare WARN
        (no persisted reason) on anything else, including a single stray
        non-JSON line accidentally sharing stdout with otherwise-valid rows.
        A real VM run's environment reported 21/21 services running with the
        two declared healthchecks healthy (confirmed by an operator's manual
        recheck immediately after the failure) yet Wait-K8ComposeReady still
        exhausted its full 120s timeout -- meaning readiness was blocked by
        this module's OWN parsing, not by Docker Compose's real state, and
        the retained evidence at the time gave no way to tell which of
        "parse failed" vs "genuinely not ready" had actually happened.

        This scanner is deliberately format-agnostic: it does not care
        whether the N rows are compact-NDJSON, or the whole document is one
        pretty-printed multi-line array, or any mix of the two, because it
        never splits on newlines at all -- only on where a top-level
        value's own brackets balance back to zero. A brace/bracket
        character INSIDE a JSON string (e.g. a container's Labels or Mounts
        field containing literal `{`/`[`) is correctly ignored because
        string state is tracked with escape-awareness. Any top-level
        non-whitespace byte that is not the start of `{` or `[` (a stray
        banner/warning line landing on stdout instead of stderr, for
        example) is a hard, fail-closed parse error with an exact offset and
        surrounding snippet -- real docker/compose/network JSON output never
        contains a bare top-level scalar, so this can never silently skip
        real data, and it can never silently accept corrupt data either.

        Returns the array of still-unparsed top-level substrings; callers
        parse each with ConvertFrom-Json and flatten arrays themselves (see
        ConvertFrom-K8ComposePsJson below) -- kept separate from JSON
        parsing itself so this scanner can be unit-tested purely as a
        string-splitting algorithm.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Raw)
    $values = New-Object System.Collections.Generic.List[string]
    $depth = 0
    $inString = $false
    $escape = $false
    $start = -1
    for ($i = 0; $i -lt $Raw.Length; $i++) {
        $ch = $Raw[$i]
        if ($inString) {
            if ($escape) { $escape = $false }
            elseif ($ch -eq '\') { $escape = $true }
            elseif ($ch -eq '"') { $inString = $false }
            continue
        }
        if ($ch -eq '"') { $inString = $true; continue }
        if ($ch -eq '{' -or $ch -eq '[') {
            if ($depth -eq 0) { $start = $i }
            $depth++
            continue
        }
        if ($ch -eq '}' -or $ch -eq ']') {
            $depth--
            if ($depth -lt 0) {
                $lo = [Math]::Max(0, $i - 40); $len = [Math]::Min(80, $Raw.Length - $lo)
                throw ('unbalanced JSON at offset {0} (unexpected closing bracket): ...{1}...' -f $i, $Raw.Substring($lo, $len))
            }
            if ($depth -eq 0) {
                $values.Add($Raw.Substring($start, $i - $start + 1))
                $start = -1
            }
            continue
        }
        if ($depth -eq 0 -and -not [char]::IsWhiteSpace($ch)) {
            $lo = [Math]::Max(0, $i - 20); $len = [Math]::Min(60, $Raw.Length - $lo)
            throw ('unexpected non-JSON content at top level, offset {0}: ...{1}...' -f $i, $Raw.Substring($lo, $len))
        }
    }
    if ($inString) { throw 'unterminated string literal in JSON output' }
    if ($depth -ne 0) { throw "unbalanced JSON: $depth unclosed bracket(s) at end of input" }
    # A single comma, NOT `,@(...)`: `@()` around an already-real array does
    # not change it, but the leading comma then wraps THAT into a further
    # 1-element array-of-array -- the exact double-wrap defect class this
    # whole round is about, self-inflicted here if both were combined. See
    # ConvertFrom-K8ComposePsJson's return statement for the same fix and
    # Get-K8ExpectedServices' callers for the caller-side half of this bug.
    return ,$values.ToArray()
}

function ConvertFrom-K8ComposePsJson {
    <#
        `compose ps --format json` / `compose images --format json` / `network
        ls --format json` etc. emit either one JSON array or newline-
        delimited JSON objects depending on Docker/Compose version -- and,
        per ConvertFrom-K8ConcatenatedJson's docstring, possibly other
        line-layout variants this module must not assume away. Delegates the
        splitting to that depth-aware scanner (fail-closed on anything not a
        clean top-level array/object), then flattens: a single top-level
        array is expanded to its elements; each top-level object is one row.
        This is also where the well-known ConvertFrom-Json single-element-
        array-unwrap quirk (a JSON array with exactly one element
        deserializes to a bare object, not a 1-element array) is handled
        explicitly via the `-is [array]` check below, rather than papered
        over with an `@()` wrap that would be correct for that one quirk but
        wrong for the many-rows-NDJSON case.
    #>
    param([string] $Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { throw 'empty output: no JSON value to parse' }
    $chunks = ConvertFrom-K8ConcatenatedJson -Raw $Raw
    if ($chunks.Count -eq 0) { throw 'no JSON value found in output' }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($chunk in $chunks) {
        $parsed = $chunk | ConvertFrom-Json
        if ($parsed -is [array]) { foreach ($item in $parsed) { $rows.Add($item) } }
        else { $rows.Add($parsed) }
    }
    # Single comma only (see ConvertFrom-K8ConcatenatedJson above) -- and
    # every CALLER of this function must NOT wrap it in @() either, for the
    # same reason: this already force-returns a real array for 1 row or N.
    return ,$rows.ToArray()
}

function Get-K8ObjectPropertyValue {
    param([Parameter(Mandatory)] $Object, [Parameter(Mandatory)][string] $Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Resolve-K8ComposeImageRows {
    <# Compose v5.4 `images --format json` omits Service. Resolve that shape
       only through an anchored Compose container name:
       <project>-<service>-<replica> (or legacy underscore separators).
       Substring/ambiguous matches are forbidden. #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string[]] $ExpectedServices,
        [Parameter(Mandatory)][object[]] $ImageRows
    )
    $resolved = @{}
    foreach ($service in $ExpectedServices) {
        $dashName = '^{0}-{1}-[0-9]+$' -f [regex]::Escape($RunId), [regex]::Escape($service)
        $underscoreName = '^{0}_{1}_[0-9]+$' -f [regex]::Escape($RunId), [regex]::Escape($service)
        $imageMatches = @($ImageRows | Where-Object {
            $declaredService = Get-K8ObjectPropertyValue -Object $_ -Name 'Service'
            if (-not [string]::IsNullOrWhiteSpace([string]$declaredService)) {
                return ([string]$declaredService -ceq $service)
            }
            $containerName = Get-K8ObjectPropertyValue -Object $_ -Name 'ContainerName'
            return (-not [string]::IsNullOrWhiteSpace([string]$containerName) -and
                (([string]$containerName -cmatch $dashName) -or ([string]$containerName -cmatch $underscoreName)))
        })
        if ($imageMatches.Count -ne 1) {
            throw "image inventory must resolve exactly one image for expected service '$service'; found $($imageMatches.Count)"
        }
        $resolved[$service] = $imageMatches[0]
    }
    return $resolved
}

function Test-K8ComposeServiceReadiness {
    <#
        Container-state readiness only: every expected service present,
        State 'running', and -- for a service that DOES declare a Docker
        healthcheck -- Health 'healthy'. A service with NO healthcheck
        (Health blank/absent) is deliberately treated as ready on State alone,
        because that is the only signal Docker itself exposes for it; this is
        a conscious scope limit, not an oversight, and it is exactly why
        Elasticsearch -- which is slow to actually accept HTTP connections
        after its container reaches 'running', and had no healthcheck in the
        generated manifest -- needed its OWN application-level gate
        (Wait-K8ElasticsearchReady) rather than being trusted on State alone.
        See that function's docstring.

        Uses Get-K8ObjectPropertyValue rather than direct .Service/.State/
        .Health property access: under Set-StrictMode, a `compose ps --format
        json` row that omits a key entirely (observed to vary across Compose
        versions -- Health in particular) would throw
        PropertyNotFoundException on direct access instead of evaluating to
        $null.
    #>
    param([Parameter(Mandatory)][string[]] $Expected, [Parameter(Mandatory)][object[]] $Services)
    $byService = @{}
    foreach ($service in $Services) {
        $name = Get-K8ObjectPropertyValue -Object $service -Name 'Service'
        if ([string]::IsNullOrWhiteSpace([string]$name)) { throw 'compose ps row has no Service field' }
        $byService[[string]$name] = $service
    }
    $missing = @($Expected | Where-Object { -not $byService.ContainsKey($_) })
    $notRunning = @($Expected | Where-Object {
        $byService.ContainsKey($_) -and (Get-K8ObjectPropertyValue -Object $byService[$_] -Name 'State') -ne 'running'
    })
    $notHealthy = @($Expected | Where-Object {
        if (-not $byService.ContainsKey($_)) { return $false }
        $health = Get-K8ObjectPropertyValue -Object $byService[$_] -Name 'Health'
        (-not [string]::IsNullOrWhiteSpace([string]$health)) -and $health -ne 'healthy'
    })
    return [pscustomobject]@{ Ready=($missing.Count -eq 0 -and $notRunning.Count -eq 0 -and $notHealthy.Count -eq 0); Missing=$missing; NotRunning=$notRunning; NotHealthy=$notHealthy }
}

function Wait-K8ElasticsearchReady {
    <#
        APPLICATION-level readiness gate for Elasticsearch, distinct from and
        in addition to Test-K8ComposeServiceReadiness's container-state check.

        ROOT CAUSE this exists to fix: a real VM Shakedown run
        (k8shakedown-rangea-20260829-010502) reached the fixed Collector
        request and got curl exit 7 (transport/connect failure) against
        http://localhost:9200 from inside the elasticsearch container.
        Wait-K8ComposeReady had already reported the container 'running'
        (Elasticsearch has no Docker healthcheck in the generated manifest,
        so Test-K8ComposeServiceReadiness's State-only fallback passed it).
        A JVM-backed service reaching container 'running' state proves the
        process started, not that it has finished initializing and is
        actually accepting HTTP connections on 9200 -- that gap is exactly
        what produced the transport failure, on whichever Range reached the
        query first (Range A here; Range B's Runtime Contract record used to
        run its own ad hoc, non-polling `curl` check after the fault, which
        would have caught this by accident on Range B but never gated Range A
        and was not a real finite-timeout readiness gate).

        Contract (all required by the K8-3 Shakedown audit that added this):
          - Runs BEFORE T0/the sender trigger, for BOTH Range A and Range B,
            from one shared call site -- not duplicated, not Range-B-only.
          - Finite timeout; never blocks forever.
          - Polls only $Endpoint ('_cluster/health'); never changes the
            endpoint, an index pattern, or any frozen selector to "make it
            work."
          - On timeout, throws (STOP before capture/sender/trigger) and
            retains every poll attempt's diagnostic -- never silently
            continues with an unconfirmed endpoint.
          - Retains its PASS result too, so a review can see the gate ran.
          - Never retried after the fact and never reused to retry a
            SCIENTIFIC request (the Collector/Rule/R-OBS-05 calls in
            Invoke-K8ElasticsearchRequest/Complete-K8ElasticsearchResponse
            remain exactly-once with no retry loop; grepping either of those
            two function bodies for a loop construct must find none -- see
            Test-K8ShakedownRegression.ps1).

        PASS condition (independent review round 2: HTTP 200 alone is an
        HTTP-listener check, not evidence the cluster can actually index/
        search -- a JVM that has bound the port but not yet formed a cluster
        can still answer HTTP before it can serve _search/_bulk correctly).
        The response BODY is retained and parsed, not discarded: PASS
        requires HTTP 2xx, a JSON body, and its "status" field to be
        "yellow" or "green". "red" means at least one primary shard is
        unassigned -- not accepted as ready. "yellow" (not "green") is
        accepted because this scenario is a single-node cluster with default
        replica settings, where "green" is not a normally reachable steady
        state; requiring it would make every run fail on a fully healthy
        single-node cluster, which is not what this gate is for.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence,
        [int] $TimeoutSeconds = 240,
        [int] $PollSeconds = 3
    )
    $envDir = Join-Path $RunEvidence 'environment'
    $container = (docker compose -p $RunId -f $ComposePath ps -q elasticsearch | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($container)) {
        throw 'Elasticsearch container could not be resolved for the application-readiness gate; not proceeding to capture/trigger.'
    }
    $marker = 'K8_HTTP_STATUS'
    $attempts = @()
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $attemptStart = (Get-Date).ToUniversalTime().ToString('o')
        # STDOUT/STDERR captured separately: curl's own stderr diagnostics
        # must never be merged into the body+marker text this regex parses.
        # The -w value uses curl's OWN literal `\n` escape (two characters,
        # backslash-then-n; curl expands it to a real newline when it writes
        # -w's output), not a raw embedded newline byte in the argument --
        # curl documents this escape specifically so callers never have to
        # smuggle a literal control character through a shell/argv boundary.
        $healthCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('exec', $container, 'curl', '-sS', '--max-time', '5', '-w', "\n${marker}:%{http_code}", 'http://localhost:9200/_cluster/health')
        $raw = ($healthCapture.Stdout | Out-String)
        $curlExit = $healthCapture.ExitCode
        $record = [ordered]@{ attempt_utc=$attemptStart; curl_exit=$curlExit; curl_stderr=$healthCapture.Stderr.Trim(); http_status=$null; cluster_status=$null; body_parsed=$false }
        if ($curlExit -eq 0 -and $raw -match "(?s)^(.*)\r?\n${marker}:(\d+)\s*$") {
            $bodyText = $Matches[1]
            $record.http_status = $Matches[2]
            if ($record.http_status -match '^2[0-9][0-9]$') {
                try {
                    $parsed = $bodyText | ConvertFrom-Json
                    $record.body_parsed = $true
                    $record.cluster_status = Get-K8ObjectPropertyValue -Object $parsed -Name 'status'
                    if ($record.cluster_status -in @('yellow', 'green')) {
                        $attempts += $record
                        [ordered]@{ gate='elasticsearch-application-readiness'; result='PASS'; container=$container; pass_condition='HTTP 2xx, parsed JSON body, cluster status in {yellow, green}'; final_body=$parsed; attempts=$attempts } |
                            ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $envDir 'elasticsearch-readiness.json') -Encoding utf8NoBOM
                        Write-K8ShakedownLog -Message "Elasticsearch application readiness PASS after $($attempts.Count) attempt(s) (HTTP $($record.http_status), cluster status '$($record.cluster_status)')."
                        return
                    }
                }
                catch { }
            }
        }
        $attempts += $record
        Start-Sleep -Seconds $PollSeconds
    }
    [ordered]@{ gate='elasticsearch-application-readiness'; result='TIMEOUT'; container=$container; pass_condition='HTTP 2xx, parsed JSON body, cluster status in {yellow, green}'; attempts=$attempts } |
        ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $envDir 'elasticsearch-readiness.json') -Encoding utf8NoBOM
    throw "Elasticsearch application-readiness gate timed out after ${TimeoutSeconds}s ($($attempts.Count) attempt(s); none returned HTTP 2xx with a parsed _cluster/health body whose status was yellow or green). Not proceeding to capture/trigger. See environment/elasticsearch-readiness.json. This is the pre-trigger gate for the curl-exit-7 class of failure; it is not retried here, and the fixed Collector/Rule/R-OBS-05 requests downstream are still never retried either."
}

function Get-K8Dnp3OperationalCanaryHits {
    <#
        PRE-TRIGGER READINESS CANARY -- not the scientific R-OBS-05 request.

        Independent review round 3 found that "log_structurer's tshark and
        bulk_loader.py processes are both alive" (round 2's fix) still does
        not prove documents are actually landing in ot-logs-dnp3-*:
        platform/generators/assets/bulk_loader.py's own flush() catches
        every _bulk POST failure (HTTPError and bare Exception alike),
        prints to stderr, and keeps running -- a process that is alive but
        silently failing every flush looks identical, from a process-table
        check alone, to one that is delivering correctly.

        This queries ot-logs-dnp3-* for the cc_scada_master (10.1.10.10,
        link source 1) <-> sub_c_rtu (10.1.40.10, link source 20) periodic
        DNP3 Integrity Poll -- genuine, pre-existing normal-operations
        traffic (an ~8s background interval; see
        k6-r-obs-05-collector-query-contract.md SS1/SS3, whose own frozen
        "unrelated flow" selector this reuses verbatim as VALUES only, for
        an entirely different purpose). No fixed selector/index pattern/
        query shape is invented here -- the field names and addresses are
        copied from that already-frozen contract, not guessed.

        This is deliberately NOT the scientific R-OBS-05 evidence request:
          - No T0 window (T0 does not exist yet -- this runs before the
            sender). Sorted `_doc desc` (insertion order) instead, exactly
            as scenarios/legacy-power-grid-signals/zone_violation.py itself
            does for the same "give me whatever is most recently indexed"
            need.
          - Result is NOT retained under contract-output/ and is not an
            R-OBS-05 artifact. It exists only to prove the pipeline is
            functionally delivering before the one scientific trigger.
          - Never touches, and is asserted never to match, the target
            attack selector (10.1.20.11 -> 10.1.10.10, fc=5, link
            1024->1): every returned hit's source IP/function code is
            checked against that tuple and this throws if it ever matches,
            rather than silently trusting the query filter alone to keep
            them disjoint.
          - Executed once per poll attempt by the caller's own loop; it is
            not itself retried past that caller's timeout, and it never
            substitutes for or is confused with the fixed, exactly-once
            Collector/Rule/R-OBS-05 requests in Invoke-K8ElasticsearchRequest.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath
    )
    $container = (docker compose -p $RunId -f $ComposePath ps -q elasticsearch | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($container)) {
        throw 'elasticsearch container could not be resolved for the operational-canary readiness check'
    }
    # Same cc_scada_master<->sub_c_rtu selector VALUES as
    # k6-r-obs-05-collector-query-contract.md SS3, no time window, sorted by
    # insertion order (matching zone_violation.py's own approach) rather
    # than by a T0 this check runs before.
    $query = '{"size":3,"track_total_hits":true,"sort":[{"_doc":"desc"}],"query":{"bool":{"minimum_should_match":1,"should":[{"bool":{"filter":[{"term":{"layers.ip.ip_ip_src.keyword":"10.1.10.10"}},{"term":{"layers.ip.ip_ip_dst.keyword":"10.1.40.10"}},{"term":{"layers.tcp.tcp_tcp_dstport.keyword":"20000"}},{"terms":{"layers.dnp3.dnp3_dnp3_al_func.keyword":["1","5"]}},{"term":{"layers.dnp3.dnp3_dnp3_src.keyword":"1"}},{"term":{"layers.dnp3.dnp3_dnp3_dst.keyword":"20"}}]}},{"bool":{"filter":[{"term":{"layers.ip.ip_ip_src.keyword":"10.1.40.10"}},{"term":{"layers.ip.ip_ip_dst.keyword":"10.1.10.10"}},{"term":{"layers.tcp.tcp_tcp_srcport.keyword":"20000"}},{"term":{"layers.dnp3.dnp3_dnp3_al_func.keyword":"129"}},{"term":{"layers.dnp3.dnp3_dnp3_src.keyword":"20"}},{"term":{"layers.dnp3.dnp3_dnp3_dst.keyword":"1"}}]}}]}}}'
    $marker = 'K8_HTTP_STATUS'
    # STDOUT/STDERR captured separately: curl's own stderr must not be
    # merged into the body+marker text this regex parses. As above, `\n` is
    # curl's OWN -w escape (expanded by curl itself), not a raw embedded
    # newline byte in the argument.
    $canaryCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('exec', $container, 'curl', '-sS', '--max-time', '5', '-X', 'POST', 'http://localhost:9200/ot-logs-dnp3-*/_search', '-H', 'Content-Type: application/json', '--data-binary', $query, '-w', "\n${marker}:%{http_code}")
    $raw = ($canaryCapture.Stdout | Out-String)
    $curlExit = $canaryCapture.ExitCode
    if ($curlExit -ne 0 -or $raw -notmatch "(?s)^(.*)\r?\n${marker}:(\d+)\s*$") {
        throw "operational-canary query transport failure (curl exit $curlExit): stdout=$raw stderr=$($canaryCapture.Stderr.Trim())"
    }
    $bodyText = $Matches[1]
    $httpStatus = $Matches[2]
    if ($httpStatus -notmatch '^2[0-9][0-9]$') {
        throw "operational-canary query returned HTTP ${httpStatus}: $bodyText"
    }
    $parsed = $bodyText | ConvertFrom-Json
    $hitsBlock = Get-K8ObjectPropertyValue -Object $parsed -Name 'hits'
    $hits = @(Get-K8ObjectPropertyValue -Object $hitsBlock -Name 'hits')
    $totalBlock = Get-K8ObjectPropertyValue -Object $hitsBlock -Name 'total'
    $total = [int](Get-K8ObjectPropertyValue -Object $totalBlock -Name 'value')
    foreach ($hit in $hits) {
        $source = Get-K8ObjectPropertyValue -Object $hit -Name '_source'
        $layers = Get-K8ObjectPropertyValue -Object $source -Name 'layers'
        $ipLayer = Get-K8ObjectPropertyValue -Object $layers -Name 'ip'
        $dnp3Layer = Get-K8ObjectPropertyValue -Object $layers -Name 'dnp3'
        $srcIp = Get-K8ObjectPropertyValue -Object $ipLayer -Name 'ip_ip_src'
        $func = Get-K8ObjectPropertyValue -Object $dnp3Layer -Name 'dnp3_dnp3_al_func'
        if ($srcIp -eq '10.1.20.11' -and $func -eq '5') {
            throw 'operational-canary query unexpectedly matched the TARGET scientific selector (src=10.1.20.11, fc=5) -- the canary selector must stay disjoint from the target attack flow by construction. STOP.'
        }
    }
    return [pscustomobject]@{ TotalHits = $total; Hits = $hits; RawBody = $bodyText }
}

function Wait-K8LogStructurerReady {
    <#
        APPLICATION-level readiness gate for log_structurer's DNP3
        tshark|bulk_loader.py pipeline -- the pipeline that actually feeds
        the ot-logs-dnp3-* index the fixed Collector request reads.

        Root cause this closes (independent review round 2, BLOCKER):
        Amenonuboco platform/generators/structuring.py, pinned
        78fc17746b5d663fafec9dffe563d79fe9ea02b7, generates log_structurer's
        OWN container startup script to run
        `apt-get update && apt-get install -y tshark python3` FIRST, and only
        after that succeeds does it launch, per declared protocol,
        `tshark -i $IF -T ek -Y "dnp3" -l | python3 /app/bulk_loader.py
        --index "ot-logs-dnp3-*" ...` as a background pipeline (source
        reviewed directly at the pinned commit, not assumed). Container
        'running' only proves that install step's shell started; a Collector
        query fired before the pipeline is actually live would not error --
        it would return zero/incomplete hits that look exactly like a
        legitimate negative scientific result. That silent-corruption shape
        (vs. wan_router's own iproute2 install, which fails LOUDLY when `ip`/
        `tc` are not yet present, because Resolve-K8GatewayInterface's own
        line-count check throws on zero matches) is why this one is a
        BLOCKER and wan_router's install race is not; see the cross-service
        audit note in this module's top-of-file comment.

        Mechanism: checked via /proc/*/cmdline (present on any Linux
        container regardless of whether ps/pgrep are installed -- this image
        installs only tshark/python3, not procps) for a live process whose
        argv contains BOTH 'tshark' and 'dnp3' (the launched tshark), and a
        second live process whose argv contains BOTH 'bulk_loader.py' and
        'dnp3' (the launched loader, `--index "ot-logs-dnp3-*"`). Sender
        argument quoting is stripped by the shell that execs these processes
        (compose.py wraps every generated command in `sh -c "..."`), so
        their real /proc/PID/cmdline never contains the source's own
        double-quote characters -- confirmed by reading compose.py's command
        assembly, not assumed.

        Process-alive is NECESSARY but not SUFFICIENT (independent review
        round 3, BLOCKER): platform/generators/assets/bulk_loader.py's own
        flush() catches every Elasticsearch _bulk POST failure (HTTPError
        and any other Exception alike), prints it to stderr, and keeps
        running -- so tshark+bulk_loader can both be alive while zero
        documents are actually reaching ot-logs-dnp3-*. PASS therefore also
        requires Get-K8Dnp3OperationalCanaryHits to find at least one
        real, pre-existing, non-target-selector DNP3 document -- proof the
        FULL observe -> structure -> index chain is functioning, not just
        that its processes started.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence,
        [int] $TimeoutSeconds = 240,
        [int] $PollSeconds = 3
    )
    $envDir = Join-Path $RunEvidence 'environment'
    $container = (docker compose -p $RunId -f $ComposePath ps -q log_structurer | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($container)) {
        throw 'log_structurer container could not be resolved for the application-readiness gate; not proceeding to capture/trigger.'
    }
    $probe = 'for p in /proc/[0-9]*/cmdline; do tr "\0" " " < "$p" 2>/dev/null; printf "\n"; done'
    $attempts = @()
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $attemptStart = (Get-Date).ToUniversalTime().ToString('o')
        $dump = @((docker exec $container sh -lc $probe 2>&1 | Out-String) -split "`n")
        $tsharkLive = [bool]($dump | Where-Object { $_ -match 'tshark' -and $_ -match 'dnp3' })
        $bulkLoaderLive = [bool]($dump | Where-Object { $_ -match 'bulk_loader\.py' -and $_ -match 'dnp3' })
        $canaryHitCount = 0
        $canaryError = $null
        try {
            $canary = Get-K8Dnp3OperationalCanaryHits -RunId $RunId -ComposePath $ComposePath
            $canaryHitCount = $canary.TotalHits
        }
        catch { $canaryError = $_.Exception.Message }
        $attempts += [ordered]@{
            attempt_utc=$attemptStart; tshark_dnp3_process_found=$tsharkLive; bulk_loader_dnp3_process_found=$bulkLoaderLive
            operational_canary_hit_count=$canaryHitCount; operational_canary_query_error=$canaryError
        }
        if ($tsharkLive -and $bulkLoaderLive -and $canaryHitCount -gt 0) {
            [ordered]@{ gate='log-structurer-dnp3-functional-readiness'; result='PASS'; container=$container; attempts=$attempts } |
                ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $envDir 'log-structurer-readiness.json') -Encoding utf8NoBOM
            Write-K8ShakedownLog -Message "log_structurer functional readiness PASS after $($attempts.Count) attempt(s): pipeline processes live AND $canaryHitCount operational-canary document(s) observed in ot-logs-dnp3-*."
            return
        }
        Start-Sleep -Seconds $PollSeconds
    }
    [ordered]@{ gate='log-structurer-dnp3-functional-readiness'; result='TIMEOUT'; container=$container; attempts=$attempts } |
        ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $envDir 'log-structurer-readiness.json') -Encoding utf8NoBOM
    throw "log_structurer's DNP3 tshark|bulk_loader pipeline did not reach functional readiness within ${TimeoutSeconds}s (process-alive and/or the operational-canary document check in ot-logs-dnp3-* never both held -- see environment/log-structurer-readiness.json for which). Not proceeding to capture/trigger -- a Collector query against a non-functional structuring pipeline would return an empty/incomplete result that looks like a legitimate negative finding rather than a startup race."
}

function Wait-K8ZoneDetectorReady {
    <#
        APPLICATION-level readiness gate for zone_detector's
        signal-1-zone-violation detection plugin process -- the process that
        actually populates ot-signals-zone-violation-*, which the fixed Rule
        request reads.

        Root cause this closes (independent review round 2, BLOCKER):
        Amenonuboco platform/generators/plugins.py, pinned
        78fc17746b5d663fafec9dffe563d79fe9ea02b7, generates the detection
        plugin host's startup script to run
        `pip install --quiet --no-cache-dir <requires>` FIRST, and only
        after that succeeds does it launch
        `python3 /app/plugins/signal-1-zone-violation.py &` (source reviewed
        directly at the pinned commit; plugin container path/name confirmed
        against c2-dnp3-step3-pilot.md's own record of the mount target).
        Container 'running' only proves the pip-install shell started, not
        that the detector process is live. A Rule query fired before it
        starts would return zero hits indistinguishable from a genuine
        'No alert' scientific result.

        Mechanism: same /proc/*/cmdline approach as
        Wait-K8LogStructurerReady, for the same reason (this image's own
        startup script installs only what `requires` declares, not procps).

        Process-alive is NECESSARY but not SUFFICIENT (independent review
        round 3, BLOCKER):
        scenarios/legacy-power-grid-signals/zone_violation.py's own
        poll_once() wraps its Elasticsearch search in
        `except requests.exceptions.RequestException: ... return 0` --
        "sidecar must not crash" is the stated design intent, so a plugin
        that cannot reach Elasticsearch at all keeps running forever,
        indistinguishable by process state alone from one that is actually
        polling successfully. PASS therefore also requires an HTTP
        connectivity check issued FROM WITHIN the zone_detector container
        itself (not from the elasticsearch container, not from the
        Shakedown host) against that container's own resolved $ES_URL (read
        from its actual environment, falling back to the script's own
        documented default only if unset) -- proving the same network path
        the real plugin process depends on, not a proxy for it. Uses
        `python3 -c` with stdlib `urllib.request` only, not curl: this
        image is python:3.11-slim with no guarantee curl was ever
        installed (only what `plugin.requires` declares is pip-installed;
        curl is not a Python package).

        Round 4 (BLOCKER, independent review): a bare `_cluster/health` 2xx
        proves TCP/HTTP reachability but not that the plugin's ACTUAL
        dependency -- `POST <ES_URL>/ot-logs-dnp3-*/_search` -- succeeds.
        poll_once() catches every requests.exceptions.RequestException on
        that search (a 400 from a query/mapping incompatibility included)
        and returns 0, so "process alive + generic ES reachable + this one
        specific search permanently failing" was a real, undetected PASS
        condition. This gate now also issues, FROM WITHIN the zone_detector
        container, the plugin's own literal query --
        `{"size": 50, "sort": [{"_doc": "desc"}], "query": {"wildcard":
        {"layers.frame.frame_frame_protocols": "*dnp3*"}}}` -- copied
        verbatim from scenarios/legacy-power-grid-signals/zone_violation.py
        poll_once() at the pinned commit, not reconstructed or
        approximated, against ot-logs-dnp3-* (already known to hold at
        least one document at this point in the pipeline, since
        Wait-K8LogStructurerReady's operational canary already required
        that). PASS requires HTTP 2xx AND a body that parses as JSON.

        Best-effort, non-blocking: the container's recent stderr is also
        checked for zone_violation's own "search failed"/"bulk write
        failed" lines and recorded (not gated on) -- a transient old error
        from before Elasticsearch itself became ready is expected and must
        not by itself fail a run that is otherwise functionally ready now.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence,
        [int] $TimeoutSeconds = 240,
        [int] $PollSeconds = 3
    )
    $envDir = Join-Path $RunEvidence 'environment'
    $container = (docker compose -p $RunId -f $ComposePath ps -q zone_detector | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($container)) {
        throw 'zone_detector container could not be resolved for the application-readiness gate; not proceeding to capture/trigger.'
    }
    $probe = 'for p in /proc/[0-9]*/cmdline; do tr "\0" " " < "$p" 2>/dev/null; printf "\n"; done'
    $attempts = @()
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $attemptStart = (Get-Date).ToUniversalTime().ToString('o')
        $dump = @((docker exec $container sh -lc $probe 2>&1 | Out-String) -split "`n")
        $pluginLive = [bool]($dump | Where-Object { $_ -match 'python3' -and $_ -match 'signal-1-zone-violation' })

        # Resolve the container's OWN configured ES_URL (zone_violation.py's
        # own default if unset), then check connectivity from inside it.
        $esUrlRaw = (docker exec $container sh -lc 'printf "%s" "${ES_URL:-http://elasticsearch:9200}"' 2>&1 | Out-String).Trim()
        $esUrl = if ($esUrlRaw) { $esUrlRaw } else { 'http://elasticsearch:9200' }
        # STDOUT/STDERR captured separately for both python3 checks below: a
        # stray interpreter warning on stderr (e.g. a DeprecationWarning)
        # merged into stdout would corrupt the exact `^2[0-9][0-9]$` match
        # even on an otherwise-successful request -- the same defect class
        # as the tshark stdout/stderr bug this round's review found.
        $connectivityScript = "import sys,urllib.request`ntry:`n r=urllib.request.urlopen('$esUrl/_cluster/health',timeout=5)`n sys.stdout.write(str(r.status))`nexcept Exception as e:`n sys.stdout.write('ERROR:'+str(e))`n sys.exit(1)`n"
        $connCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('exec', $container, 'python3', '-c', (ConvertTo-K8PythonExecOneLiner -Script $connectivityScript))
        $connOut = ($connCapture.Stdout | Out-String).Trim()
        $connExit = $connCapture.ExitCode
        $connectivityOk = ($connExit -eq 0 -and $connOut -match '^2[0-9][0-9]$')

        # The plugin's own literal search, from inside its own container,
        # against its own real dependency (not just a generic health check).
        $searchOk = $false
        $searchResult = $null
        if ($connectivityOk) {
            $searchScript = "import sys,json,urllib.request,urllib.error`nbody=b'{`"size`": 50, `"sort`": [{`"_doc`": `"desc`"}], `"query`": {`"wildcard`": {`"layers.frame.frame_frame_protocols`": `"*dnp3*`"}}}'`ntry:`n req=urllib.request.Request('$esUrl/ot-logs-dnp3-*/_search',data=body,headers={'Content-Type':'application/json'},method='POST')`n r=urllib.request.urlopen(req,timeout=5)`n raw=r.read()`n json.loads(raw)`n sys.stdout.write(str(r.status))`nexcept urllib.error.HTTPError as e:`n sys.stdout.write('HTTPERROR:'+str(e.code))`n sys.exit(1)`nexcept Exception as e:`n sys.stdout.write('ERROR:'+str(e))`n sys.exit(1)`n"
            $searchCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('exec', $container, 'python3', '-c', (ConvertTo-K8PythonExecOneLiner -Script $searchScript))
            $searchResult = ($searchCapture.Stdout | Out-String).Trim()
            $searchExit = $searchCapture.ExitCode
            $searchOk = ($searchExit -eq 0 -and $searchResult -match '^2[0-9][0-9]$')
        }

        $recentLog = (docker logs --tail 20 $container 2>&1 | Out-String)
        $recentLogHasError = [bool]($recentLog -match 'search failed|bulk write failed')

        $attempts += [ordered]@{
            attempt_utc=$attemptStart; signal1_plugin_process_found=$pluginLive
            es_url_used=$esUrl; zone_detector_to_es_connectivity_ok=$connectivityOk; zone_detector_to_es_result=$connOut
            zone_detector_source_index_search_ok=$searchOk; zone_detector_source_index_search_result=$searchResult
            # Recorded for review, not gated on: a transient old error from
            # before Elasticsearch itself became ready must not by itself
            # fail a run that is otherwise functionally ready now.
            recent_log_tail_error_seen_best_effort_non_blocking=$recentLogHasError
        }
        if ($pluginLive -and $connectivityOk -and $searchOk) {
            [ordered]@{ gate='zone-detector-functional-readiness'; result='PASS'; container=$container; attempts=$attempts } |
                ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $envDir 'zone-detector-readiness.json') -Encoding utf8NoBOM
            Write-K8ShakedownLog -Message "zone_detector functional readiness PASS after $($attempts.Count) attempt(s): plugin process live, HTTP $connOut to $esUrl, AND its own ot-logs-dnp3-*/_search query returned HTTP $searchResult with a parseable body."
            return
        }
        Start-Sleep -Seconds $PollSeconds
    }
    [ordered]@{ gate='zone-detector-functional-readiness'; result='TIMEOUT'; container=$container; attempts=$attempts } |
        ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $envDir 'zone-detector-readiness.json') -Encoding utf8NoBOM
    throw "zone_detector did not reach functional readiness within ${TimeoutSeconds}s (plugin-process-alive, its own container-to-Elasticsearch connectivity, and/or its own literal ot-logs-dnp3-*/_search query never all three held -- see environment/zone-detector-readiness.json for which). Not proceeding to capture/trigger -- a Rule query against a detector whose own search is failing (query/mapping incompatibility, a 400, etc.) would return zero hits indistinguishable from a genuine 'No alert' result."
}

function Complete-K8ElasticsearchResponse {
    <# Pure fail-closed response gate, split from Docker/curl so every outcome
       is regression-testable without a live VM. #>
    param(
        [Parameter(Mandatory)][int] $CurlExitCode,
        [string] $HttpStatus = '',
        [string] $RawBody = '',
        [string] $TransportDiagnostic = '',
        [Parameter(Mandatory)][string] $OutputPath,
        [Parameter(Mandatory)][string] $RequestLabel
    )
    $diagnosticPath = "$OutputPath.error-body.txt"
    if ($CurlExitCode -ne 0) {
        "transport_exit=$CurlExitCode`n$TransportDiagnostic`n$RawBody" | Set-Content -Path $diagnosticPath -Encoding utf8NoBOM
        throw "$RequestLabel transport/curl failure (exit $CurlExitCode); fixed request was not retried. Diagnostic: $diagnosticPath"
    }
    if ($HttpStatus -notmatch '^2[0-9][0-9]$') {
        $RawBody | Set-Content -Path $diagnosticPath -Encoding utf8NoBOM
        throw "$RequestLabel returned HTTP $HttpStatus; expected 2xx. Fixed request was not retried. Response body: $diagnosticPath"
    }
    try { $null = $RawBody | ConvertFrom-Json }
    catch {
        $RawBody | Set-Content -Path $diagnosticPath -Encoding utf8NoBOM
        throw "$RequestLabel returned invalid JSON with HTTP $HttpStatus. Diagnostic: $diagnosticPath"
    }
    $RawBody | Set-Content -Path $OutputPath -Encoding utf8NoBOM
}

function Invoke-K8ElasticsearchRequest {
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $Method,
        [Parameter(Mandatory)][string] $Endpoint,
        [string] $Body = '',
        [Parameter(Mandatory)][string] $OutputPath
    )
    $container = (docker compose -p $RunId -f $ComposePath ps -q elasticsearch | Out-String).Trim()
    if (-not $container) { throw 'Elasticsearch container could not be resolved' }
    if (Test-Path $OutputPath) { throw "refusing to overwrite existing Elasticsearch response: $OutputPath" }
    $remoteBody = "/tmp/k8-es-$([guid]::NewGuid().ToString('N')).body"
    # Old curl compatibility: one HTTP request writes the body separately and
    # emits only the status. No newer curl failure-body flag, retry, or resend.
    # STDOUT/STDERR captured SEPARATELY throughout: curl's own `-sS` still
    # shows real errors on stderr, and merging that into the expected
    # bare-3-digit-status stdout would corrupt every scientific ES request's
    # HTTP-status parse (Collector, Rule, mapping, R-OBS-05 all share this).
    $curlArgs = @('exec', $container, 'curl', '-sS', '-o', $remoteBody, '-w', '%{http_code}', '-X', $Method,
        "http://localhost:9200/$Endpoint", '-H', 'Content-Type: application/json')
    if ($Body) { $curlArgs += @('--data-binary', $Body) }
    $statusCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList $curlArgs
    $curlExit = $statusCapture.ExitCode
    $bodyCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('exec', $container, 'cat', $remoteBody)
    $bodyExit = $bodyCapture.ExitCode
    docker exec $container rm -f $remoteBody 2>&1 | Out-Null
    $rawBody = if ($bodyExit -eq 0) { $bodyCapture.Stdout | Out-String } else { '' }
    $effectiveExit = if ($curlExit -ne 0) { $curlExit } elseif ($bodyExit -ne 0) { 98 } else { 0 }
    $diagnostic = "stdout: $($statusCapture.Stdout -join ' ') | stderr: $($statusCapture.Stderr.Trim()) | body-read stderr: $($bodyCapture.Stderr.Trim())"
    Complete-K8ElasticsearchResponse -CurlExitCode $effectiveExit `
        -HttpStatus $(if ($curlExit -eq 0) { ($statusCapture.Stdout -join '').Trim() } else { '' }) `
        -RawBody $rawBody -TransportDiagnostic $diagnostic -OutputPath $OutputPath `
        -RequestLabel "Elasticsearch $Method $Endpoint"
}

function Assert-K8UnrelatedMirrorFilter {
    param([Parameter(Mandatory)] $Gateway, [Parameter(Mandatory)][string] $RunEvidence)
    $contractDir = Join-Path $RunEvidence 'contract-output'
    $links = @(docker exec $Gateway.Router ip -o link show 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'could not enumerate gateway interfaces for the unrelated mirror-filter gate' }
    $records = @()
    $found = $false
    foreach ($line in $links) {
        if ($line -notmatch '^\d+:\s+([^:@]+)') { continue }
        $interface = $Matches[1]
        if ($interface -eq 'lo' -or $interface -eq $Gateway.Interface) { continue }
        $filter = (docker exec $Gateway.Router tc filter show dev $interface parent ffff: 2>&1 | Out-String)
        $records += "### $interface`n$filter"
        if ($filter -match 'mirred\s+.*egress\s+mirror') { $found = $true }
    }
    $records -join "`n" | Set-Content -Path (Join-Path $contractDir 'unrelated-mirror-filters.txt') -Encoding utf8NoBOM
    if (-not $found) { throw 'Range B R-OBS-05 gate failed: no unrelated gateway interface retained a mirred egress mirror filter' }
}

function Invoke-K8TsharkFieldDecode {
    <#
        Shared low-level pcap decode: copies a retained pcap into the
        already-running log_structurer container (which already has tshark
        installed for its own DNP3 structuring pipeline -- no new install on
        the Windows host, no operator-run analysis), runs tshark there with
        a caller-supplied display filter against the SAME fixed field set
        every decode in this module uses, and returns the parsed rows. The
        remote copy is always removed afterward, success or failure.
    #>
    param(
        [Parameter(Mandatory)][string] $Container,
        [Parameter(Mandatory)][string] $LocalPcapPath,
        [Parameter(Mandatory)][string] $DisplayFilter,
        [Parameter(Mandatory)][string] $RemoteNameHint
    )
    if (-not (Test-Path $LocalPcapPath)) { throw "pcap not found for decode: $LocalPcapPath" }
    $remote = "/tmp/$RemoteNameHint.pcap"
    & docker cp $LocalPcapPath "${Container}:$remote" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not copy $LocalPcapPath into log_structurer for decode" }
    try {
        # STDOUT and STDERR captured SEPARATELY: tshark writes "Running as
        # user 'root' and group 'root'. This could be dangerous." (and
        # similar diagnostics) to stderr, which a merged `2>&1` capture
        # would hand to the TSV parser below as if it were a data row.
        #
        # `-E separator=/t`, NOT `separator=\t`: real VM run
        # k8shakedown-rangea-20260829-081151 showed a row delimited by a
        # literal backslash character instead of an actual tab byte -- `\t`
        # is a C-style/PowerShell escape, not tshark's own CLI syntax.
        # TShark's `-E separator=` documents exactly three forms: a single
        # literal character, `/t` for tab, or `/s` for space (never a
        # backslash escape) -- this module had been confusing PowerShell's
        # own string-escape convention with tshark's CLI contract. `/t` is
        # an instruction tshark itself expands into a real tab (0x09) byte
        # in ITS OWN output; the fix is entirely on this command-line
        # argument, so the `-split "`t"` below (an actual PowerShell tab
        # character, unrelated to this CLI syntax) is correct exactly as it
        # already was and needs no change once tshark is emitting real tabs.
        $capture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @(
            'exec', $Container, 'tshark', '-r', $remote, '-Y', $DisplayFilter, '-T', 'fields', '-E', 'separator=/t',
            '-e', 'frame.number', '-e', 'frame.time_epoch', '-e', 'ip.src', '-e', 'ip.dst',
            '-e', 'tcp.srcport', '-e', 'tcp.dstport', '-e', 'dnp3.al.func', '-e', 'dnp3.src', '-e', 'dnp3.dst'
        )
        if ($capture.ExitCode -ne 0) {
            throw "tshark decode failed (exit $($capture.ExitCode)) for $LocalPcapPath. stderr: $($capture.Stderr.Trim())"
        }
        $raw = $capture.Stdout
    }
    finally {
        docker exec $Container rm -f $remote 2>&1 | Out-Null
    }
    $rows = @()
    foreach ($line in $raw) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # NOT `-split "`t", -1`: a -1 limit to the -split operator does not
        # mean "unlimited" (it degenerately returns the whole line unsplit,
        # count 1) -- confirmed by direct testing, not assumed. Omitting the
        # limit (or passing 0) is what actually returns all 9 fields.
        $columns = @($line -split "`t")
        if ($columns.Count -ne 9) { throw "unexpected tshark row shape for $LocalPcapPath`: $line" }
        $rows += [ordered]@{ frame_number=$columns[0]; frame_time_epoch=$columns[1]; ip_src=$columns[2]; ip_dst=$columns[3]; tcp_srcport=$columns[4]; tcp_dstport=$columns[5]; dnp3_al_func=$columns[6]; dnp3_src=$columns[7]; dnp3_dst=$columns[8] }
    }
    # `,$rows` (not bare `$rows`): PowerShell unrolls an array onto the
    # output pipeline element-by-element, so a ONE-hit decode (the common
    # case) would otherwise hand the caller the bare [ordered] hashtable
    # instead of a one-element array -- confirmed by direct testing, not
    # assumed (a real invocation returned .Count=9, the FIELD count of that
    # single row, not the intended row count). The comma forces this
    # function to always return one array, whatever its length.
    return ,$rows
}

function Write-K8UnrelatedPcapRows {
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence
    )
    $pcap = Join-Path $RunEvidence 'sensor-input\mirror-capture\c2-mirror-sensor.pcap'
    $container = (docker compose -p $RunId -f $ComposePath ps -q log_structurer | Out-String).Trim()
    if (-not $container) { throw 'log_structurer container could not be resolved for frozen pcap decode' }
    $display = '(ip.src == 10.1.10.10 && ip.dst == 10.1.40.10 && tcp.dstport == 20000 && (dnp3.al.func == 1 || dnp3.al.func == 5) && dnp3.src == 1 && dnp3.dst == 20) || (ip.src == 10.1.40.10 && ip.dst == 10.1.10.10 && tcp.srcport == 20000 && dnp3.al.func == 129 && dnp3.src == 20 && dnp3.dst == 1)'
    $rows = Invoke-K8TsharkFieldDecode -Container $container -LocalPcapPath $pcap -DisplayFilter $display -RemoteNameHint "$RunId-r-obs-05"
    $path = Join-Path $RunEvidence 'contract-output\r-obs-05-pcap-rows.json'
    ConvertTo-Json -InputObject @($rows) -Depth 4 | Set-Content -Path $path -Encoding utf8NoBOM
    if ($rows.Count -eq 0) { throw 'Range B R-OBS-05 gate failed: sensor pcap contains no unrelated-flow frame' }
    return $path
}

function Write-K8TargetCaptureDecode {
    <#
        README Study01/README.md SS5.1 step 6 requires "decode them" right
        after capture stop/export; c2-dnp3-capture-procedure.md SS5 requires
        retaining "decoded verification" alongside each stage's artifact;
        c2-dnp3-sender-procedure.md SS4 condition 3 requires the independent
        original-path pcap to satisfy the frozen Ground Truth selector in
        freeze-decision-table.md SS3, which also fixes the Sensor selector
        ("same tuple/function/link-address constraints ... in the
        mirror-side pcap"). A real VM run reached scoring-input with no
        machine-readable decode of either pcap at all -- this was entirely
        missing, not merely incomplete.

        Uses the EXACT frozen selector from freeze-decision-table.md SS3,
        copied verbatim, never approximated or independently invented:
        source 10.1.20.11, destination 10.1.10.10, TCP destination port
        20000, DNP3 function 5, link source 1024, link destination 1.
        Decoded via Invoke-K8TsharkFieldDecode -- the same log_structurer-
        container tshark mechanism as Write-K8UnrelatedPcapRows -- so no new
        tool install on the Windows host and no operator-run analysis.

        Retains the decoded hit count and every hit's fields/timestamp, and
        flags (informationally only) whether each frame's time falls inside
        the frozen [T0-5s, T0+15s] window -- this in-window flag is
        advisory, not a scientific gate: it does NOT use the same
        exact-integer-nanosecond comparison k8_shakedown_evidence.py uses
        for the R-OBS-05 correlation, because this artifact makes no
        pass/fail claim for it to gate. A decoded hit count of zero is
        retained exactly as observed and does NOT throw -- deciding whether
        the Ground Truth/Sensor predicate is satisfied remains the
        operator's scoring-input judgment (README SS6.2); this only removes
        the mechanical burden of running tshark and transcribing its output
        by hand. Must run while log_structurer is still up (before
        Complete's teardown) and before Complete's finalize-evidence, and
        writes into the same stage directory study01_capture.py itself
        writes into, so it is covered by validate-evidence's per-directory
        check and by the eventual hashes.sha256.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence,
        [Parameter(Mandatory)][ValidateSet('ground-truth', 'sensor')][string] $Stage,
        [Parameter(Mandatory)][string] $WindowStartIso,
        [Parameter(Mandatory)][string] $WindowEndIso
    )
    $stagePaths = @{
        'ground-truth' = @{ pcap = 'ground-truth\independent-capture\c2-original-path.pcap'; out = 'ground-truth\independent-capture\decoded-verification.json' }
        'sensor'       = @{ pcap = 'sensor-input\mirror-capture\c2-mirror-sensor.pcap'; out = 'sensor-input\mirror-capture\decoded-verification.json' }
    }
    $pcap = Join-Path $RunEvidence $stagePaths[$Stage].pcap
    $container = (docker compose -p $RunId -f $ComposePath ps -q log_structurer | Out-String).Trim()
    if (-not $container) { throw "log_structurer container could not be resolved for the $Stage capture decode" }
    # freeze-decision-table.md SS3, Ground Truth/Sensor row, verbatim.
    $display = 'ip.src==10.1.20.11 && ip.dst==10.1.10.10 && tcp.dstport==20000 && dnp3.al.func==5 && dnp3.src==1024 && dnp3.dst==1'
    $rows = Invoke-K8TsharkFieldDecode -Container $container -LocalPcapPath $pcap -DisplayFilter $display -RemoteNameHint "$RunId-$Stage-decode"

    $windowStart = [datetimeoffset]::Parse($WindowStartIso)
    $windowEnd = [datetimeoffset]::Parse($WindowEndIso)
    foreach ($row in $rows) {
        $inWindow = $false
        $parsedTime = 0.0
        if ([double]::TryParse($row.frame_time_epoch, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedTime)) {
            $frameInstant = [datetimeoffset]::FromUnixTimeMilliseconds([long]($parsedTime * 1000))
            $inWindow = ($frameInstant -ge $windowStart -and $frameInstant -le $windowEnd)
        }
        $row['in_frozen_window_advisory'] = $inWindow
    }
    $outPath = Join-Path $RunEvidence $stagePaths[$Stage].out
    [ordered]@{
        stage = $Stage
        selector = 'freeze-decision-table.md SS3: src=10.1.20.11 dst=10.1.10.10 tcp.dstport=20000 dnp3.al.func=5 dnp3.src=1024 dnp3.dst=1'
        window_start = $WindowStartIso; window_end = $WindowEndIso
        decoded_hit_count = $rows.Count
        hits_in_frozen_window_advisory = @($rows | Where-Object { $_.in_frozen_window_advisory }).Count
        rows = $rows
    } | ConvertTo-Json -Depth 6 | Set-Content -Path $outPath -Encoding utf8NoBOM
    Write-K8ShakedownLog -Message "$Stage capture decode retained: $($rows.Count) matching frame(s) at $outPath (zero is retained as observed, not treated as failure -- README SS6.2 governs the scoring judgment)."
}

function Get-K8CollectorHitIds {
    <#
        Extracts every hit's document _id from a retained Collector response
        (ot-logs-dnp3-* search result). Every _id here is, by construction,
        an ACCEPTED Collector hit: the Collector query itself already
        enforces the complete frozen Collector selector
        (freeze-decision-table.md SS3), so this never re-derives, narrows,
        or judges that -- it only reads back what the Collector query
        already decided. Returns the COMPLETE matching-hit set, never a
        post hoc single chosen document (frozen: "Multiple matching
        collector documents do not fail the criterion and may not be
        reduced to a post hoc chosen document"). Zero hits is a valid
        observed Collector state and returns an empty array, not a throw --
        deciding whether the Collector stage itself passes remains the
        operator's scoring-input judgment (README SS6.2); this function only
        reads IDs back for the Rule query filter.
    #>
    param([Parameter(Mandatory)][string] $CollectorResponsePath)
    $response = Get-Content $CollectorResponsePath -Raw | ConvertFrom-Json
    $hitsBlock = Get-K8ObjectPropertyValue -Object $response -Name 'hits'
    if (-not $hitsBlock) { throw "Collector response at $CollectorResponsePath has no 'hits' block; cannot resolve the accepted Collector hit set for the Rule selector." }
    $rows = Get-K8ObjectPropertyValue -Object $hitsBlock -Name 'hits'
    $ids = New-Object System.Collections.Generic.List[string]
    if ($null -ne $rows) {
        # `@($null)` is a 1-element array CONTAINING null, not an empty
        # array -- guard explicitly rather than iterate blindly.
        foreach ($row in @($rows)) {
            if ($null -eq $row) { continue }
            $id = Get-K8ObjectPropertyValue -Object $row -Name '_id'
            if (-not [string]::IsNullOrWhiteSpace([string]$id)) { $ids.Add([string]$id) }
        }
    }
    return ,$ids.ToArray()
}

function Invoke-K8AutomatedQueries {
    <#
        Root cause this closes (real VM run k8shakedown-rangea-20260829-084343,
        independent review): the Rule query used `term` directly on `signal`
        /`src_ip`/`dst_ip`, but the actual ot-signals-zone-violation-*
        mapping declares them `text` with a `.keyword` multi-field -- a
        `term` query against the analyzed `text` field does not reliably
        match the exact stored value, so the Rule stage silently came back
        "No alert" regardless of whether zone_violation.py had actually
        written a matching document. The query ALSO never constrained
        `source_dnp3_doc_id` at all, so even a successful match would not
        have mechanically enforced the frozen correlation requirement.

        Fix: `signal.keyword`/`src_ip.keyword`/`dst_ip.keyword` exact-match
        terms, AND a `terms` filter on `source_dnp3_doc_id.keyword` set to
        the COMPLETE accepted Collector hit-ID set (every _id the Collector
        query returned -- never a post hoc single chosen document, per
        freeze-decision-table.md SS3). This makes the frozen Rule selector's
        correlation requirement part of the query itself, not something
        checked only afterward. Both index mappings are gated (fail-closed,
        not just retained) BEFORE either query runs, so a future mapping
        drift STOPs here with a clear diagnostic instead of silently
        producing another false "No alert".
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('a','b')][string] $Range,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence,
        [Parameter(Mandatory)][string] $WindowStart,
        [Parameter(Mandatory)][string] $WindowEnd
    )
    $envDir = Join-Path $RunEvidence 'environment'
    $collectorResponse = Join-Path $RunEvidence 'collector-output\collector-response.json'
    $ruleResponse = Join-Path $RunEvidence 'rule-output\rule-response.json'
    $collectorMapping = Join-Path $RunEvidence 'collector-output\collector-index-mapping.json'
    $ruleMapping = Join-Path $RunEvidence 'rule-output\rule-index-mapping.json'
    # README SS5.1 step 6: "retain the Collector and Rule queries with their
    # responses and mappings."
    Invoke-K8ElasticsearchRequest -RunId $RunId -ComposePath $ComposePath -Method GET -Endpoint 'ot-logs-dnp3-*/_mapping' -OutputPath $collectorMapping
    Invoke-K8ElasticsearchRequest -RunId $RunId -ComposePath $ComposePath -Method GET -Endpoint 'ot-signals-zone-violation-*/_mapping' -OutputPath $ruleMapping

    # Mechanically verify the frozen selector's exact-match fields BEFORE
    # either query is trusted -- fail-closed on drift, for both ranges (not
    # only when Range B's R-OBS-05 happens to share the same ot-logs-dnp3-*
    # index and field set).
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $PSScriptRoot 'k8_shakedown_evidence.py'), 'collector-mapping-gate', '--mapping', $collectorMapping, '--output', (Join-Path $RunEvidence 'collector-output\collector-selector-mapping-gate.json')) -Description 'Collector selector exact-match mapping gate'
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $PSScriptRoot 'k8_shakedown_evidence.py'), 'rule-mapping-gate', '--mapping', $ruleMapping, '--output', (Join-Path $RunEvidence 'rule-output\rule-selector-mapping-gate.json')) -Description 'Rule selector exact-match mapping gate (signal/src_ip/dst_ip/source_dnp3_doc_id)'

    Invoke-K8ElasticsearchRequest -RunId $RunId -ComposePath $ComposePath -Method POST -Endpoint 'ot-logs-dnp3-*/_search' -Body (Get-Content (Join-Path $envDir 'collector-query.json') -Raw) -OutputPath $collectorResponse

    # The Rule query cannot be finalized until the Collector response is
    # known: it must filter on the COMPLETE accepted Collector hit-ID set,
    # read back mechanically, never a post hoc single chosen document.
    $collectorIds = Get-K8CollectorHitIds -CollectorResponsePath $collectorResponse
    # `ConvertTo-Json -AsArray` on an EMPTY input produces an empty STRING,
    # not the literal `[]` -- a zero-Collector-hit run is a valid observed
    # state (see Get-K8CollectorHitIds), and substituting an empty string
    # into the Rule query would produce invalid JSON, not a valid "match
    # nothing" terms filter. Must special-case zero explicitly.
    $collectorIdsJson = if ($collectorIds.Count -eq 0) { '[]' } else { ($collectorIds | ConvertTo-Json -AsArray -Compress -Depth 3) }
    $collectorIdsJson | Set-Content -Path (Join-Path $RunEvidence 'collector-output\accepted-collector-hit-ids.json') -Encoding utf8NoBOM
    $ruleQuery = (Get-Content (Join-Path $PSScriptRoot 'rule-query.template.json') -Raw).
        Replace('<WINDOW_START>', $WindowStart).Replace('<WINDOW_END>', $WindowEnd).
        Replace('"<COLLECTOR_HIT_IDS_JSON>"', $collectorIdsJson)
    $ruleQuery | Set-Content -Path (Join-Path $envDir 'rule-query.json') -Encoding utf8NoBOM
    Write-K8ShakedownLog -Message "Rule request finalized against $($collectorIds.Count) accepted Collector hit ID(s)."

    Invoke-K8ElasticsearchRequest -RunId $RunId -ComposePath $ComposePath -Method POST -Endpoint 'ot-signals-zone-violation-*/_search' -Body $ruleQuery -OutputPath $ruleResponse
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $PSScriptRoot 'k8_shakedown_evidence.py'), 'target-correlation', '--collector', $collectorResponse, '--rule', $ruleResponse, '--output', (Join-Path $RunEvidence 'rule-output\collector-rule-correlation.json')) -Description 'retain complete Collector hit IDs and mechanically verify every Rule hit correlates'
    if ($Range -eq 'b') {
        $mappingPath = Join-Path $RunEvidence 'contract-output\r-obs-05-mapping-response.json'
        $mappingDecision = Join-Path $RunEvidence 'contract-output\r-obs-05-mapping-gate.json'
        Invoke-K8ElasticsearchRequest -RunId $RunId -ComposePath $ComposePath -Method GET -Endpoint 'ot-logs-dnp3-*/_mapping' -OutputPath $mappingPath
        Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $PSScriptRoot 'k8_shakedown_evidence.py'), 'mapping-gate', '--mapping', $mappingPath, '--output', $mappingDecision) -Description 'R-OBS-05 exact mapping field/type gate'
        $response = Join-Path $RunEvidence 'contract-output\r-obs-05-response.json'
        Invoke-K8ElasticsearchRequest -RunId $RunId -ComposePath $ComposePath -Method POST -Endpoint 'ot-logs-dnp3-*/_search' -Body (Get-Content (Join-Path $envDir 'r-obs-05-query.json') -Raw) -OutputPath $response
        $frames = Write-K8UnrelatedPcapRows -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence
        Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $PSScriptRoot 'k8_shakedown_evidence.py'), 'r-obs-05', '--response', $response, '--frames', $frames, '--window-start', $WindowStart, '--window-end', $WindowEnd, '--output', (Join-Path $RunEvidence 'contract-output\r-obs-05-correlation.json')) -Description 'R-OBS-05 exact integer-nanosecond pcap/document correlation'
    }
}

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

# ---------------------------------------------------------------------------
# T0-relative timing gates (independent review round 5, BLOCKER)
#
# ROOT CAUSE, confirmed against the frozen source, not assumed: this module
# previously called `study01_capture.py stop-export` immediately after the
# sender, commented "covers the settle window internally per capture.py".
# That comment was simply wrong. Study01/studies/study-01-negative-result/
# scripts/study01_capture.py's own docstring says "Run `stop-export` only
# after `T0 + 15 s`" -- stop_export() itself contains no wait at all; the
# 15s wait is entirely the CALLER's responsibility. capture_lifecycle.py's
# validate() enforces this by requiring the window-end-liveness-check step's
# own START timestamp to be >= T0 + 15s. A real VM run
# (k8shakedown-rangea-20260829-021350) called stop-export ~13.465s too
# early and the frozen validator correctly rejected it:
#   "helper liveness was not observed at or after the window end
#    (2026-08-29T02:17:14.197604+00:00 < 2026-08-29T02:17:27.662946+00:00)"
#
# Auditing the SAME class of bug at the OTHER edge of the frozen window
# (the window-START requirement, capture_lifecycle.py: each stage's
# listening-check must COMPLETE at or before T0 - 5s) found it was ALSO
# only true "by luck" -- this runner's prior code relied on the sender-prep
# docker exec round trips (mkdir, docker cp, sha256sum) happening to take
# at least 5 seconds after the last listening-check, with no explicit
# guarantee. On a fast host that gap could plausibly be under 5 seconds,
# which would fail the SAME validator the SAME way, just at the other edge.
# Wait-K8CaptureWindowStart closes that proactively, before it was ever hit
# on a real run.
#
# Neither gate ever re-sends the sender, retries a capture step, or changes
# WINDOW_LEAD/WINDOW_TAIL (5s/15s) -- both are read from
# capture_lifecycle.py's own frozen values in spirit (hardcoded here as the
# same 5/15 since this is PowerShell, not importing Python), never widened,
# and both fail closed on a missing/malformed/offset-less timestamp rather
# than silently proceeding.
# ---------------------------------------------------------------------------

function Wait-K8CaptureWindowStart {
    <#
        Frozen requirement: capture_lifecycle.py's validate() requires each
        capture stage's OWN retained "listening-check" step to have
        COMPLETED (`completed_at`) at or before T0 - 5s. T0 does not exist
        yet at this point (it is stamped by study01_sender.py at the moment
        it actually sends), so this reads back the real retained completion
        timestamp for BOTH stages' listening-check (never a guessed
        wall-clock mark) and waits, if needed, until at least 5s (plus a
        small safety margin) have elapsed since the LATER of the two --
        guaranteeing that whenever the sender ends up stamping T0, the
        already-completed listening-checks are mechanically at or before
        T0 - 5s. Never retries a capture step and never touches the sender.
    #>
    param(
        [Parameter(Mandatory)][string] $RunEvidence,
        [double] $MarginSeconds = 0.5
    )
    $lifecyclePaths = @(
        (Join-Path $RunEvidence 'ground-truth\independent-capture\capture-lifecycle.json'),
        (Join-Path $RunEvidence 'sensor-input\mirror-capture\capture-lifecycle.json')
    )
    $latest = $null
    foreach ($path in $lifecyclePaths) {
        if (-not (Test-Path $path)) {
            throw "capture-lifecycle record not found at $path; cannot confirm the frozen window-start lead time before invoking the sender. Not proceeding."
        }
        $record = Get-Content $path -Raw | ConvertFrom-Json
        $step = $record.steps | Where-Object { $_.step -eq 'listening-check' } | Select-Object -First 1
        if (-not $step -or -not (Get-K8ObjectPropertyValue -Object $step -Name 'completed_at')) {
            throw "no 'listening-check' step with a completed_at timestamp found in $path. Not proceeding."
        }
        try { $completed = [datetimeoffset]::Parse($step.completed_at) }
        catch { throw "listening-check completed_at in $path ('$($step.completed_at)') could not be parsed: $($_.Exception.Message)" }
        if ($null -eq $latest -or $completed -gt $latest) { $latest = $completed }
    }
    $targetSenderNotBefore = $latest.AddSeconds(5).AddSeconds($MarginSeconds)
    $now = [datetimeoffset]::UtcNow
    $remaining = ($targetSenderNotBefore - $now).TotalSeconds
    if ($remaining -gt 0) {
        Write-K8ShakedownLog -Message "Waiting $([Math]::Round($remaining,3))s so both capture stages' listening-check (latest completion: $($latest.ToString('o'))) will be at least 5s before the sender fires (frozen window-start requirement)."
        Start-Sleep -Seconds $remaining
    }
    else {
        Write-K8ShakedownLog -Message "Capture listening-check (latest: $($latest.ToString('o'))) already more than 5s ago; no extra wait needed before the sender."
    }
    $envDir = Join-Path $RunEvidence 'environment'
    New-Item -ItemType Directory -Force -Path $envDir | Out-Null
    [ordered]@{
        latest_listening_check_completed_utc = $latest.ToString('o')
        target_sender_not_before_utc = $targetSenderNotBefore.ToString('o')
        waited_seconds = [Math]::Max(0, $remaining)
        sender_proceeding_utc = ([datetimeoffset]::UtcNow).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $envDir 'capture-window-start-wait.json') -Encoding utf8NoBOM
}

function Wait-K8CaptureWindowEnd {
    <#
        Frozen requirement: Study01/studies/study-01-negative-result/
        scripts/study01_capture.py's own docstring: "Run `stop-export` only
        after `T0 + 15 s`." stop_export() itself has no wait -- it is the
        caller's responsibility, and capture_lifecycle.py's validate()
        enforces it by requiring the window-end-liveness-check step's own
        START timestamp to be >= T0 + 15s.

        Computes T0+15s from the retained metadata-t0.txt (written by
        study01_sender.py at the run evidence root) and sleeps only the
        REMAINING wall-clock time -- never a fixed "sleep N seconds after
        the sender returns" (which would be wrong by exactly however long
        the sender invocation itself took), and never re-sends/retries the
        sender. If wall-clock time already exceeds T0+15s, returns
        immediately with no extra wait.

        Fail-closed on a missing, unparseable, or offset-less T0 artifact.
    #>
    param(
        [Parameter(Mandatory)][string] $RunEvidence,
        [double] $MarginSeconds = 0.5
    )
    $t0Path = Join-Path $RunEvidence 'metadata-t0.txt'
    if (-not (Test-Path $t0Path)) {
        throw "T0 record not found at $t0Path after the sender invocation; cannot compute the T0+15s window end. Not proceeding to stop-export."
    }
    $t0Raw = (Get-Content $t0Path -Raw).Trim()
    if ($t0Raw -notmatch 'Z$|[+-]\d{2}:\d{2}$') {
        throw "T0 record at $t0Path ('$t0Raw') does not carry an explicit UTC offset (no trailing Z or +hh:mm/-hh:mm). Not proceeding to stop-export."
    }
    try { $t0 = [datetimeoffset]::Parse($t0Raw) }
    catch { throw "T0 record at $t0Path could not be parsed as a timestamp ('$t0Raw'): $($_.Exception.Message). Not proceeding to stop-export." }

    $windowEnd = $t0.AddSeconds(15)
    $targetWait = $windowEnd.AddSeconds($MarginSeconds)
    $now = [datetimeoffset]::UtcNow
    $remaining = ($targetWait - $now).TotalSeconds
    if ($remaining -gt 0) {
        Write-K8ShakedownLog -Message "Waiting $([Math]::Round($remaining,3))s for the frozen T0+15s window end (T0=$($t0.ToString('o')), window_end=$($windowEnd.ToString('o'))) before stop-export."
        Start-Sleep -Seconds $remaining
    }
    else {
        Write-K8ShakedownLog -Message "T0+15s window end ($($windowEnd.ToString('o'))) already passed by $([Math]::Round(-$remaining,3))s; not waiting further before stop-export."
    }
    $envDir = Join-Path $RunEvidence 'environment'
    New-Item -ItemType Directory -Force -Path $envDir | Out-Null
    [ordered]@{
        t0 = $t0.ToString('o'); window_end = $windowEnd.ToString('o'); target_wait_with_margin = $targetWait.ToString('o')
        waited_seconds = [Math]::Max(0, $remaining)
        stop_export_proceeding_utc = ([datetimeoffset]::UtcNow).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $envDir 'capture-window-end-wait.json') -Encoding utf8NoBOM
}

function Test-K8CaptureLifecycleEarly {
    <#
        Runs the FROZEN capture_lifecycle.validate()/capture_context.validate()
        functions directly against both stages' already-retained records,
        right after stop-export and BEFORE this runner ever prints "runtime
        evidence PASS" -- so a capture-lifecycle timing violation (the exact
        class of bug this round's fix addresses) surfaces here, not three
        steps later inside Complete-K8ShakedownRange.ps1's pre-teardown
        validate-evidence.

        This is NOT a re-run of `study01_collect.py validate-evidence`: that
        full check also requires metadata.md, deviations.md, and non-empty
        collector-output/rule-output, none of which exist yet at this point
        in the pipeline (they are written later, and populated by the
        Elasticsearch queries that have not run yet). Rather than write
        those prematurely just to satisfy an unrelated check, this imports
        and calls the SAME two frozen validator functions
        study01_collect.py itself uses for the capture-lifecycle portion --
        so the semantics are identical, not reimplemented, just scoped to
        what is actually available this early. The remaining full
        validate-evidence still runs, unchanged, in
        Complete-K8ShakedownRangeAB before teardown.
    #>
    param(
        [Parameter(Mandatory)][string] $ScriptsDir,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $RunEvidence
    )
    $script = @'
import sys, json
sys.path.insert(0, sys.argv[3])
from pathlib import Path
from datetime import datetime
from study01 import capture_context as context
from study01 import capture_lifecycle as lifecycle
from study01.frozen import apparatus

run_evidence = Path(sys.argv[1])
run_id = sys.argv[2]

t0_path = run_evidence / apparatus.T0_ARTIFACT
if not t0_path.is_file():
    raise SystemExit(f"{apparatus.T0_ARTIFACT} not found at {t0_path}")
t0_value = datetime.fromisoformat(t0_path.read_text(encoding="utf-8").strip().replace("Z", "+00:00"))

for stage, spec in apparatus.CAPTURE_STAGES.items():
    context_path = run_evidence / spec["context"]
    lifecycle_path = run_evidence / spec["lifecycle"]
    if not context_path.is_file() or not lifecycle_path.is_file():
        raise SystemExit(f"{stage}: context or lifecycle record missing")
    ctx = context.validate(json.loads(context_path.read_text(encoding="utf-8")), run_id)
    record = json.loads(lifecycle_path.read_text(encoding="utf-8"))
    retained = lifecycle.validate(record, t0_value, ctx)
    if retained["run_id"] != run_id:
        raise SystemExit(f"{stage}: run_id does not match the evidence directory")

print("capture-lifecycle early check: PASS for ground-truth and sensor")
'@
    $tmpScript = Join-Path ([System.IO.Path]::GetTempPath()) ("k8-early-lifecycle-" + [guid]::NewGuid().ToString('N') + '.py')
    Set-Content -Path $tmpScript -Value $script -Encoding utf8NoBOM
    try {
        Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @($tmpScript, $RunEvidence, $RunId, $ScriptsDir) `
            -Description 'early capture-lifecycle check (frozen capture_lifecycle.validate/capture_context.validate, before runtime PASS is reported)'
    }
    finally {
        Remove-Item $tmpScript -ErrorAction SilentlyContinue
    }
}

function Test-K8ScoringInputArtifactCompleteness {
    <#
        Shakedown-specific completeness gate (independent review round 6,
        BLOCKER): a real VM run reached scoring-input with runtime/
        validate-evidence/finalize/teardown/verify-integrity all already
        PASS, only to discover then that README SS5.1 step 6's "decode
        them" had never been implemented at all -- no per-stage
        machine-readable decode of either capture existed anywhere in the
        run. study01_collect.py's validate-evidence cannot catch this
        class of gap: it has no notion that README requires a pcap decode
        artifact, only that the schema-defined directories are non-empty
        and the capture-lifecycle/procedure-conformance records are
        internally consistent -- all of which were already true.

        This checks, by file path, every primary artifact README SS5/SS6.2
        actually requires before scoring-input can be started, for BOTH
        Range A and Range B from one shared list, plus Range B's own
        R-OBS-05-specific set. It is intentionally a Shakedown-only
        convenience check, not a frozen-protocol validator: it never scores
        anything, never decides Pass/Fail for any stage, and a file's mere
        presence is not asserted to prove its content correct (that is what
        the frozen validators, and ultimately the operator's own scoring-
        input transcription, are for). It exists solely so a missing
        primary artifact is caught here, before "runtime evidence PASS" is
        ever printed, rather than only much later when an operator reaches
        scoring-input on an already-closed, already-torn-down run.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('a', 'b')][string] $Range,
        [Parameter(Mandatory)][string] $RunEvidence
    )
    $required = @(
        'ground-truth\independent-capture\c2-original-path.pcap'
        'ground-truth\independent-capture\capture-lifecycle.json'
        'ground-truth\independent-capture\capture-context.json'
        'ground-truth\independent-capture\decoded-verification.json'
        'ground-truth\sender-record.txt'
        'ground-truth\procedure-conformance.json'
        'sensor-input\mirror-capture\c2-mirror-sensor.pcap'
        'sensor-input\mirror-capture\capture-lifecycle.json'
        'sensor-input\mirror-capture\capture-context.json'
        'sensor-input\mirror-capture\decoded-verification.json'
        'collector-output\collector-response.json'
        'collector-output\collector-index-mapping.json'
        'collector-output\collector-selector-mapping-gate.json'
        'collector-output\accepted-collector-hit-ids.json'
        'rule-output\rule-response.json'
        'rule-output\rule-index-mapping.json'
        'rule-output\rule-selector-mapping-gate.json'
        'rule-output\collector-rule-correlation.json'
        'contract-output\gateway-interface-resolution.txt'
        'contract-output\runtime-contract-record.md'
        'environment\image-inventory.json'
        'environment\collector-query.json'
        'environment\rule-query.json'
        'metadata-t0.txt'
        'metadata.md'
        'deviations.md'
    )
    if ($Range -eq 'b') {
        $required += @(
            'contract-output\qdisc-pre-fault.txt'
            'contract-output\qdisc-post-fault.txt'
            'contract-output\unrelated-mirror-filters.txt'
            'contract-output\r-obs-05-mapping-response.json'
            'contract-output\r-obs-05-mapping-gate.json'
            'contract-output\r-obs-05-response.json'
            'contract-output\r-obs-05-pcap-rows.json'
            'contract-output\r-obs-05-correlation.json'
            'environment\r-obs-05-query.json'
        )
    }
    $missing = @($required | Where-Object { -not (Test-Path (Join-Path $RunEvidence $_)) })
    if ($missing.Count -gt 0) {
        throw "Scoring-input artifact completeness gate failed -- missing $($missing.Count) required file(s), before this run is ever reported as runtime-PASS or handed to Complete: $($missing -join ', ')"
    }
    Write-K8ShakedownLog -Message "Scoring-input artifact completeness gate PASS: all $($required.Count) required primary artifact(s) present for Range $($Range.ToUpper())."
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

    # 3. Execution preflight gate -- do not provision if this fails.
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @(
        (Join-Path $ScriptsDir 'study01_preflight.py'),
        '--run-id', $RunId, '--worktree', $WorktreeDir, '--compose', $ComposePath,
        '--run-evidence', $RunEvidence, '--project-name', $RunId, '--teardown-target', $RunId,
        '--shell-probe', $PSVersionTable.PSVersion.ToString(),
        '--path-probe', '/study/traffic/send_direct_operate.py', '/data/c2-original-path.pcap', '/data/c2-mirror-sensor.pcap'
    ) -Description 'execution preflight gate (Docker-free)' |
        ForEach-Object { $_.Output | Set-Content -Path (Join-Path $envDir 'preflight.txt') -Encoding utf8NoBOM }

    # The frozen preflight requires every runtime evidence directory to be
    # empty at invocation time. Retain the generated Compose hash only after
    # that freshness gate has passed; writing it earlier invalidates the run.
    "generated compose SHA-256 (within-run integrity record only, per c2-dnp3-range-derivation.md SS2.2): $composeHash" |
        Set-Content -Path (Join-Path $envDir 'generated-compose-hash.txt') -Encoding utf8NoBOM

    # 3a. Network pool-conflict preflight -- BEFORE `compose up`, never
    # after. A leftover network from an older, abandoned k8shakedown-range*
    # run holding this run's same fixed subnet would otherwise only surface
    # as `docker compose up`'s own opaque "invalid pool request: Pool
    # overlaps with other one on this address space" failure. Read-only:
    # never removes/prunes a network itself.
    Test-K8ShakedownNetworkPreflight -RunId $RunId -ComposePath $ComposePath

    # 4. Provision. Compose build output is intentionally kept outside the
    # scientific evidence tree as a per-run Shakedown runtime/debug log.
    $buildLog = Join-Path $state.shakedown_root "runtime-logs\$RunId\docker-compose-up-build.log"
    Invoke-K8ShakedownLoggedCommand -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'up', '-d', '--build') `
        -LogPath $buildLog -Description "provision Range $($Range.ToUpper())" | Out-Null

    # 4a. Environment readiness: wait for every defined service to report a
    # running state before doing anything else (README SS5.1 step 4:
    # "establish readiness ... before the event window opens"). Fails closed
    # on timeout rather than proceeding against a half-up stack.
    Wait-K8ComposeReady -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence

    # 4a-2. APPLICATION readiness, shared identically by Range A and Range B,
    # run this early (before image inventory, the fault, capture, and the
    # sender trigger) precisely because container 'running' state proves
    # none of these three: that Elasticsearch's HTTP endpoint is accepting
    # connections and can serve a search (Wait-K8ElasticsearchReady), that
    # log_structurer's own apt-get-installed tshark|bulk_loader DNP3 pipeline
    # has actually started (Wait-K8LogStructurerReady), or that
    # zone_detector's own pip-installed signal-1-zone-violation plugin
    # process has actually started (Wait-K8ZoneDetectorReady). All three
    # services are present in BOTH Range A and Range B's generated manifest
    # (same base manifest per c2-dnp3-range-derivation.md SS1), so all three
    # gates run for both Ranges from these same three call sites -- not
    # duplicated, not Range-specific. See each function's own docstring for
    # the real VM failure / pinned-source root cause it closes.
    Wait-K8ElasticsearchReady -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence
    Wait-K8LogStructurerReady -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence
    Wait-K8ZoneDetectorReady -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence

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
        Assert-K8UnrelatedMirrorFilter -Gateway $gw -RunEvidence $RunEvidence
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

    # 7a. Frozen window-start requirement: both stages' listening-check must
    # have COMPLETED at least 5s before T0 (which the sender is about to
    # stamp). Waits only the remaining time actually needed; never touches
    # the sender.
    Wait-K8CaptureWindowStart -RunEvidence $RunEvidence

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

    # 8a. Frozen window-end requirement: `stop-export` must not run before
    # T0+15s (study01_capture.py's own docstring; stop_export() itself has
    # no wait). Waits only the remaining time actually needed; never
    # re-sends the sender.
    Wait-K8CaptureWindowEnd -RunEvidence $RunEvidence

    # 9. Stop/export both captures. The T0+15s wait is Wait-K8CaptureWindowEnd's
    # job (above), not this loop's or capture.py's own -- see that function's
    # docstring for the real VM failure this fixed.
    foreach ($stage in @('ground-truth', 'sensor')) {
        Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @(
            (Join-Path $ScriptsDir 'study01_capture.py'), 'stop-export',
            '--run-id', $RunId, '--run-evidence', $RunEvidence, '--stage', $stage
        ) -Description "capture stop/export: $stage"
    }

    # 9a. Frozen capture-lifecycle check, reusing the same validator functions
    # study01_collect.py itself uses, scoped to what already exists at this
    # point (both stages' context+lifecycle records and T0) -- so a timing
    # violation surfaces here, before this runner ever reports "runtime
    # evidence PASS", not only later inside Complete's pre-teardown
    # validate-evidence. Full validate-evidence still cannot run yet
    # (metadata.md/deviations.md/collector-output/rule-output do not exist
    # until later steps); this is not a substitute for it, and
    # Complete-K8ShakedownRangeAB's own pre-teardown validate-evidence call
    # is unchanged.
    Test-K8CaptureLifecycleEarly -ScriptsDir $ScriptsDir -RunId $RunId -RunEvidence $RunEvidence

    # 10. Instantiate the fixed queries from retained T0. The exact requests,
    # raw responses and mechanical correlations are executed below without
    # retries, selector changes, field substitution, or result-driven widening.
    $t0Path = Join-Path $RunEvidence 'metadata-t0.txt'
    if (-not (Test-Path $t0Path)) {
        throw "T0 record not found at $t0Path after stop-export; cannot window the Collector/Rule queries. This is a STOP condition -- do not proceed to teardown without it."
    }
    $t0 = (Get-Content $t0Path -Raw).Trim()
    $windowStart = ([datetimeoffset]::Parse($t0)).AddSeconds(-5).ToString('o')
    $windowEnd = ([datetimeoffset]::Parse($t0)).AddSeconds(15).ToString('o')

    # 9b. README SS5.1 step 6: "decode them" -- both retained pcaps, against
    # the frozen Ground Truth/Sensor selector (freeze-decision-table.md SS3).
    # Must run before Complete's teardown (log_structurer must still be up)
    # and before finalize-evidence (so the artifact is hashed).
    Write-K8TargetCaptureDecode -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence -Stage 'ground-truth' -WindowStartIso $windowStart -WindowEndIso $windowEnd
    Write-K8TargetCaptureDecode -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence -Stage 'sensor' -WindowStartIso $windowStart -WindowEndIso $windowEnd

    $collectorQuery = (Get-Content (Join-Path $PSScriptRoot 'collector-query.template.json') -Raw).Replace('<WINDOW_START>', $windowStart).Replace('<WINDOW_END>', $windowEnd)
    $collectorQuery | Set-Content -Path (Join-Path $envDir 'collector-query.json') -Encoding utf8NoBOM
    # The Rule request is NOT finalized/written here: freeze-decision-
    # table.md SS3 requires its source_dnp3_doc_id filter to cover the
    # COMPLETE accepted Collector hit-ID set, which is only known once the
    # Collector query has actually run. Invoke-K8AutomatedQueries below
    # reads rule-query.template.json itself, resolves the real IDs from the
    # Collector response, and writes the one true environment/rule-query.json
    # -- writing an incomplete window-only version here first would leave a
    # stale, misleading artifact between this line and that one.
    Write-K8ShakedownLog -Message "Fixed Collector request retained with T0 window [$windowStart, $windowEnd]. Rule request will be retained once the accepted Collector hit-ID set is resolved."

    if ($Range -eq 'b') {
        $r0query = (Get-Content (Join-Path $PSScriptRoot 'r-obs-05-query.template.json') -Raw).Replace('<WINDOW_START>', $windowStart).Replace('<WINDOW_END>', $windowEnd)
        $r0query | Set-Content -Path (Join-Path $envDir 'r-obs-05-query.json') -Encoding utf8NoBOM
        Write-K8ShakedownLog -Message 'Fixed R-OBS-05 request retained; mapping/query/correlation gates will execute mechanically.'
    }

    Invoke-K8AutomatedQueries -Range $Range -RunId $RunId -ComposePath $ComposePath -RunEvidence $RunEvidence -WindowStart $windowStart -WindowEnd $windowEnd

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
| Cleanup | NOT YET PERFORMED -- all runtime evidence has been exported; pre-teardown validation/hash remains before destruction. |

See environment/, ground-truth/, sensor-input/, contract-output/ for the machine-recorded per-step argv/exit-code/timestamp evidence this table summarizes.
"@ | Set-Content -Path (Join-Path $RunEvidence 'metadata.md') -Encoding utf8NoBOM

    $deviationsBody = if ($Range -eq 'b') {
        "# Deviations -- $RunId`n`nNo unplanned deviations recorded by this runner. The ingress-qdisc deletion on the resolved gateway interface is the frozen Range B experimental condition, not a deviation -- see contract-output/qdisc-pre-fault.txt / qdisc-post-fault.txt.`n"
    } else {
        "# Deviations -- $RunId`n`nNo unplanned deviations recorded by this runner.`n"
    }
    $deviationsBody | Set-Content -Path (Join-Path $RunEvidence 'deviations.md') -Encoding utf8NoBOM

    # 11a. Shakedown-specific completeness gate: every primary artifact
    # README SS5/SS6.2 requires before scoring-input can even be started
    # must exist BEFORE this runner ever reports "runtime evidence PASS" --
    # not discovered only once the operator reaches scoring-input on an
    # already-closed run. study01_collect.py validate-evidence does not
    # catch this class of gap (it does not know README requires a pcap
    # decode at all); this is a Shakedown-side check on top of it.
    Test-K8ScoringInputArtifactCompleteness -Range $Range -RunEvidence $RunEvidence

    # 12. Leave the range running only until Complete performs the mandatory
    # pre-teardown validate/finalize gate. No operator query/curl step remains.
    Set-K8ShakedownState -Updates @{
        "range_$($Range)_run_id"      = $RunId
        "range_$($Range)_evidence"    = $RunEvidence
        "range_$($Range)_compose"     = $ComposePath
        "range_$($Range)_stage"       = 'awaiting-completion'
    }

    Write-K8ShakedownLog -Level STEP -Message "=== Shakedown Range $($Range.ToUpper()) runtime evidence PASS, range left running for ordered finalize/teardown: $RunId ==="
    Write-Host ''
    Write-Host "Range $($Range.ToUpper()) run '$RunId' retained all automated runtime evidence. Next:"
    Write-Host "  .\tools\Complete-K8ShakedownRange.ps1 -Range $Range"
    return $RunEvidence
}

function ConvertTo-K8CidrRange {
    <# Returns @(networkAddress, broadcastAddress) as UInt32 for an IPv4
       CIDR string, for range-overlap comparison. Masking is done entirely
       in UInt64 before narrowing to UInt32, because `[uint32](0xFFFFFFFF
       -shl n)` overflows UInt32 directly for any n between 1 and 31 (the
       shift itself is computed in a wider type first). #>
    param([Parameter(Mandatory)][string] $Cidr)
    $parts = $Cidr -split '/'
    if ($parts.Count -ne 2) { throw "not a CIDR (expected address/prefix): '$Cidr'" }
    $ip = [System.Net.IPAddress]::Parse($parts[0].Trim())
    if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { throw "not an IPv4 CIDR: '$Cidr'" }
    $prefix = [int]$parts[1]
    if ($prefix -lt 0 -or $prefix -gt 32) { throw "invalid IPv4 prefix length in '$Cidr'" }
    $bytes = $ip.GetAddressBytes()
    if ([BitConverter]::IsLittleEndian) { [array]::Reverse($bytes) }
    $ipUInt = [BitConverter]::ToUInt32($bytes, 0)
    $fullMask = [uint64]4294967295
    $maskU64 = if ($prefix -eq 0) { [uint64]0 } else { ($fullMask -shl (32 - $prefix)) -band $fullMask }
    $mask = [uint32]$maskU64
    $network = $ipUInt -band $mask
    $broadcast = [uint32]($network -bor ($fullMask -band (-bnot [uint64]$mask)))
    return @($network, $broadcast)
}

function Test-K8CidrOverlap {
    param([Parameter(Mandatory)][string] $CidrA, [Parameter(Mandatory)][string] $CidrB)
    $ra = ConvertTo-K8CidrRange -Cidr $CidrA
    $rb = ConvertTo-K8CidrRange -Cidr $CidrB
    return ($ra[0] -le $rb[1]) -and ($rb[0] -le $ra[1])
}

function Get-K8ComposeDeclaredSubnets {
    <#
        Resolves the IPv4 subnet(s) THIS run's compose file declares via
        `docker compose config --format json` (the fully-resolved compose
        document -- name/services/networks/volumes as one JSON object,
        never NDJSON, since it is a single document, not a per-item list),
        never a hardcoded/assumed CIDR. Only networks with an explicit
        `ipam.config[].subnet` are returned; a network with no declared
        subnet (Docker assigns one from its default pool) is not a FIXED
        CIDR and cannot deterministically collide the way the reported UX
        defect requires, so it is intentionally excluded here.
    #>
    param([Parameter(Mandatory)][string] $RunId, [Parameter(Mandatory)][string] $ComposePath)
    $capture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'config', '--format', 'json')
    if ($capture.ExitCode -ne 0) {
        throw "'docker compose config --format json' failed (exit $($capture.ExitCode)); cannot resolve this run's declared network subnets for the pool-conflict preflight. stderr: $($capture.Stderr.Trim())"
    }
    $config = ($capture.Stdout | Out-String) | ConvertFrom-Json
    $subnets = New-Object System.Collections.Generic.List[string]
    $networks = Get-K8ObjectPropertyValue -Object $config -Name 'networks'
    if ($networks) {
        foreach ($netProp in $networks.PSObject.Properties) {
            $ipam = Get-K8ObjectPropertyValue -Object $netProp.Value -Name 'ipam'
            $ipamConfig = if ($ipam) { Get-K8ObjectPropertyValue -Object $ipam -Name 'config' } else { $null }
            # `@($null)` is a 1-element array CONTAINING null, not an empty
            # array -- must skip explicitly, not just iterate blindly, or a
            # network with no ipam/config at all throws on the null $entry.
            if ($null -ne $ipamConfig) {
                foreach ($entry in @($ipamConfig)) {
                    if ($null -eq $entry) { continue }
                    $subnet = Get-K8ObjectPropertyValue -Object $entry -Name 'subnet'
                    if (-not [string]::IsNullOrWhiteSpace([string]$subnet)) { $subnets.Add([string]$subnet) }
                }
            }
        }
    }
    return ,$subnets.ToArray()
}

function Get-K8LeftoverShakedownNetworks {
    <#
        Enumerates EXISTING docker networks that look like a leftover
        network from a PRIOR (not this) Shakedown run -- name matching
        `k8shakedown-range[abc]-<digits>...`, excluding $RunId's own -- and
        returns each with whatever IPv4 subnet(s) it actually has, via
        `docker network inspect`. Read-only: never removes, prunes, or
        otherwise mutates any network. That decision is the operator's, by
        design (see Test-K8ShakedownNetworkPreflight's docstring).
    #>
    param([Parameter(Mandatory)][string] $RunId)
    $lsCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('network', 'ls', '--format', 'json')
    if ($lsCapture.ExitCode -ne 0) {
        throw "'docker network ls --format json' failed (exit $($lsCapture.ExitCode)); cannot check for leftover Shakedown networks. stderr: $($lsCapture.Stderr.Trim())"
    }
    $raw = ($lsCapture.Stdout | Out-String)
    $networks = if ([string]::IsNullOrWhiteSpace($raw)) { @() } else { ConvertFrom-K8ComposePsJson -Raw $raw }
    $candidates = @($networks | Where-Object {
        $name = [string](Get-K8ObjectPropertyValue -Object $_ -Name 'Name')
        $name -match '^k8shakedown-range[abc]-\d' -and $name -ne $RunId -and -not $name.StartsWith("$RunId-") -and -not $name.StartsWith("${RunId}_")
    })
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($net in $candidates) {
        $name = [string](Get-K8ObjectPropertyValue -Object $net -Name 'Name')
        $inspectCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('network', 'inspect', $name, '--format', 'json')
        if ($inspectCapture.ExitCode -ne 0) { continue }  # network may have been removed between ls and inspect; not this preflight's concern
        $inspectRaw = ($inspectCapture.Stdout | Out-String)
        if ([string]::IsNullOrWhiteSpace($inspectRaw)) { continue }
        $inspected = ConvertFrom-K8ComposePsJson -Raw $inspectRaw
        foreach ($detail in $inspected) {
            $ipam = Get-K8ObjectPropertyValue -Object $detail -Name 'IPAM'
            $ipamConfig = if ($ipam) { Get-K8ObjectPropertyValue -Object $ipam -Name 'Config' } else { $null }
            $subnets = New-Object System.Collections.Generic.List[string]
            # See the matching guard in Get-K8ComposeDeclaredSubnets: `@($null)`
            # is a 1-element array containing null, not an empty array.
            if ($null -ne $ipamConfig) {
                foreach ($entry in @($ipamConfig)) {
                    if ($null -eq $entry) { continue }
                    $subnet = Get-K8ObjectPropertyValue -Object $entry -Name 'Subnet'
                    if (-not [string]::IsNullOrWhiteSpace([string]$subnet)) { $subnets.Add([string]$subnet) }
                }
            }
            if ($subnets.Count -gt 0) {
                $result.Add([pscustomobject]@{ Name = $name; Subnets = $subnets.ToArray() })
            }
        }
    }
    return ,$result.ToArray()
}

function Test-K8ShakedownNetworkPreflight {
    <#
        UX defect this exists to fix (real VM finding, reported alongside
        the readiness false-negative): a leftover docker network from an
        OLDER k8shakedown-rangea-* project, still holding a fixed subnet, is
        never torn down by an abandoned/non-rescued run -- a fresh
        `docker compose up` for a NEW run then fails with "invalid pool
        request: Pool overlaps with other one on this address space" during
        provisioning, with no earlier, clearer signal of why.

        Runs BEFORE `docker compose up` (never after -- the whole point is
        to fail before provisioning attempts anything). Compares THIS run's
        actually-declared subnet(s) (read from `compose config`, never
        hardcoded) against every discoverable leftover Shakedown network's
        actual subnet(s) (read from `docker network inspect`, never
        assumed). On overlap, STOPs with the exact conflicting network name
        and both subnets so the operator can decide what to do.

        Deliberately does NOT remove, prune, or otherwise touch any
        network -- `docker network prune`/`rm` are explicitly out of scope
        here. An old network may still be attached to a container the
        operator wants to inspect, or may belong to a run under active
        investigation; only the operator can safely judge that, never this
        preflight.
    #>
    param([Parameter(Mandatory)][string] $RunId, [Parameter(Mandatory)][string] $ComposePath)
    # NOT wrapped in @() -- both helpers already force-return a real array
    # via `,$X.ToArray()`; see their own return statements and the
    # Get-K8ExpectedServices comment earlier in this module for why
    # wrapping the call site AGAIN would double-wrap into an array-of-array.
    $ourSubnets = Get-K8ComposeDeclaredSubnets -RunId $RunId -ComposePath $ComposePath
    if ($ourSubnets.Count -eq 0) {
        Write-K8ShakedownLog -Message 'Network preflight: this run declares no fixed-subnet networks; nothing to check for pool conflicts.'
        return
    }
    $leftovers = Get-K8LeftoverShakedownNetworks -RunId $RunId
    $conflicts = New-Object System.Collections.Generic.List[string]
    foreach ($leftover in $leftovers) {
        foreach ($theirSubnet in $leftover.Subnets) {
            foreach ($ourSubnet in $ourSubnets) {
                if (Test-K8CidrOverlap -CidrA $ourSubnet -CidrB $theirSubnet) {
                    $conflicts.Add("network '$($leftover.Name)' holds subnet $theirSubnet, which overlaps this run's $ourSubnet")
                }
            }
        }
    }
    if ($conflicts.Count -gt 0) {
        $detail = $conflicts.ToArray() -join '; '
        throw "Network preflight STOP: a leftover Shakedown network's fixed subnet overlaps this run's intended network(s): $detail. This run will not proceed automatically -- Shakedown does not remove or prune docker networks. Inspect and, if it is safe to do so, remove the conflicting network yourself (docker network rm <name>), then retry with a fresh run ID."
    }
    Write-K8ShakedownLog -Message "Network preflight PASS: this run's subnet(s) ($($ourSubnets -join ', ')) do not overlap any of the $($leftovers.Count) leftover Shakedown network(s) found."
}

function New-K8ComposeReadinessRecord {
    <#
        Builds the structured readiness record Wait-K8ComposeReady retains,
        and writes it to $Path. Root cause this exists to fix: a real VM run
        (k8shakedown-rangea-20260829-071142) timed out after 120s with only
        an abstract "missing/not running/unhealthy or output could not be
        parsed" message, and environment/readiness.json held nothing but the
        LAST raw `compose ps` text dump -- an operator had to manually
        recompute expected/actual/missing counts by hand to discover the
        real 21/21/all-running/declared-healthchecks-healthy state had
        already been reached, meaning readiness itself, not Docker, was the
        false negative. This record makes that distinction mechanically
        explicit and persisted, every poll, not just reconstructible after
        the fact from a raw dump.
    #>
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string[]] $Expected,
        [string] $Decision,
        [string] $RawPsOutput,
        [string] $ParseDiagnostic,
        $Gate,
        [int] $Attempts = 0
    )
    $actualCount = 0
    $missing = @(); $notRunning = @(); $notHealthy = @()
    if ($Gate) {
        $missing = @($Gate.Missing); $notRunning = @($Gate.NotRunning); $notHealthy = @($Gate.NotHealthy)
        $actualCount = $Expected.Count - $missing.Count
    }
    $record = [ordered]@{
        decision              = $Decision
        expected_count        = $Expected.Count
        expected_services     = @($Expected)
        actual_present_count  = $actualCount
        missing               = $missing
        not_running           = $notRunning
        not_healthy           = $notHealthy
        parse_diagnostic      = $(if ($ParseDiagnostic) { $ParseDiagnostic } else { $null })
        poll_attempts         = $Attempts
        raw_ps_output         = $RawPsOutput
    }
    $record | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Encoding utf8NoBOM
    return $record
}

function Write-K8ComposeReadinessTimeoutDiagnostic {
    <# Prints the 5-10 line console summary a timeout must show: not just
       "timed out", but exactly what evaluation blocked PASS the last time
       it was actually checked. #>
    param([Parameter(Mandatory)][int] $TimeoutSeconds, [Parameter(Mandatory)] $Record)
    Write-Host ''
    Write-Host "Environment readiness timed out after ${TimeoutSeconds}s. Last poll result:" -ForegroundColor Yellow
    Write-Host "  Expected services : $($Record.expected_count)"
    if ($Record.parse_diagnostic) {
        Write-Host "  Actual services   : could not be determined (parse failed)"
        Write-Host "  Parse diagnostic  : $($Record.parse_diagnostic)"
    }
    else {
        Write-Host "  Actual present    : $($Record.actual_present_count)"
        Write-Host "  Missing           : $(if ($Record.missing.Count) { $Record.missing -join ', ' } else { '(none)' })"
        Write-Host "  Not running       : $(if ($Record.not_running.Count) { $Record.not_running -join ', ' } else { '(none)' })"
        Write-Host "  Not healthy       : $(if ($Record.not_healthy.Count) { $Record.not_healthy -join ', ' } else { '(none)' })"
    }
    Write-Host "  Poll attempts     : $($Record.poll_attempts)"
    Write-Host "  Full record       : environment/readiness.json"
    Write-Host ''
}

function Wait-K8ComposeReady {
    <#
        Polls `docker compose ps --format json` until every defined service
        reports a running state, or throws on timeout. README SS5.1 step 4
        requires readiness before capture context resolution; this makes that
        an explicit, fail-closed gate instead of an assumption.

        Never weakens the readiness condition itself: every expected service
        must be present, State 'running', and -- for a service that DOES
        declare a Docker healthcheck -- Health 'healthy' (see
        Test-K8ComposeServiceReadiness, unchanged). What changed (see
        New-K8ComposeReadinessRecord's docstring for the root cause) is that
        a parse failure is now tracked SEPARATELY from a genuine
        missing/not-running/unhealthy result across the whole polling loop,
        surfaced in both the persisted record and an explicit console
        diagnostic on timeout, rather than being indistinguishable WARN-and-
        retry noise with no persisted trace of which one actually happened.
    #>
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ComposePath,
        [Parameter(Mandatory)][string] $RunEvidence,
        [int] $TimeoutSeconds = 120,
        [int] $PollSeconds = 3
    )
    $envDir = Join-Path $RunEvidence 'environment'
    # NOT wrapped in @() here: Get-K8ExpectedServices already force-returns a
    # real array via `return ,$services` (correct for 1 element AND for many).
    # Wrapping ITS call site in @() as well double-wraps the result into a
    # 1-element array whose sole element is the real array -- Test-K8Compose
    # ServiceReadiness would then iterate exactly one pseudo-"expected
    # service" (the array object itself, not a service name string), which
    # can never match any real row, making Missing non-empty and Ready
    # false FOREVER regardless of actual Docker state. Root cause of the
    # real VM false negative (k8shakedown-rangea-20260829-071142): 21/21
    # services were genuinely running and healthy the whole time; this
    # double-wrap is what made Test-K8ComposeServiceReadiness never see them.
    $expected = Get-K8ExpectedServices -RunId $RunId -ComposePath $ComposePath
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastRaw = ''
    $lastGate = $null
    $lastParseDiagnostic = $null
    $attempts = 0
    while ((Get-Date) -lt $deadline) {
        $attempts++
        # STDOUT/STDERR captured separately: a Compose warning on stderr
        # must not be merged into the JSON this parses.
        $psCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'ps', '--all', '--format', 'json')
        $lastRaw = ($psCapture.Stdout | Out-String)
        if ($psCapture.ExitCode -ne 0) {
            $lastParseDiagnostic = "'docker compose ps' failed (exit $($psCapture.ExitCode)): $($psCapture.Stderr.Trim())"
            $lastGate = $null
            Write-K8ShakedownLog -Level WARN -Message "readiness poll: $lastParseDiagnostic"
        }
        else {
            try {
                # NOT wrapped in @() -- ConvertFrom-K8ComposePsJson already
                # force-returns a real array; see its own return statement.
                $services = ConvertFrom-K8ComposePsJson -Raw $lastRaw
                $gate = Test-K8ComposeServiceReadiness -Expected $expected -Services $services
                $lastGate = $gate
                $lastParseDiagnostic = $null
                if ($gate.Ready) {
                    New-K8ComposeReadinessRecord -Path (Join-Path $envDir 'readiness.json') -Expected $expected `
                        -Decision 'PASS' -RawPsOutput $lastRaw -Gate $gate -Attempts $attempts | Out-Null
                    Write-K8ShakedownLog -Message "Environment readiness PASS: all $($expected.Count) expected service(s) present/running and all reported healthchecks healthy (after $attempts poll(s))."
                    return
                }
            }
            catch {
                $lastParseDiagnostic = $_.Exception.Message
                $lastGate = $null
                Write-K8ShakedownLog -Level WARN -Message "readiness poll: could not parse 'compose ps --format json' output, retrying: $lastParseDiagnostic"
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }
    $record = New-K8ComposeReadinessRecord -Path (Join-Path $envDir 'readiness.json') -Expected $expected `
        -Decision $(if ($lastParseDiagnostic) { 'FAIL-PARSE' } else { 'FAIL-STATE' }) `
        -RawPsOutput $lastRaw -ParseDiagnostic $lastParseDiagnostic -Gate $lastGate -Attempts $attempts
    Write-K8ComposeReadinessTimeoutDiagnostic -TimeoutSeconds $TimeoutSeconds -Record $record
    throw "Environment readiness timed out after ${TimeoutSeconds}s; an expected service was missing/not running/unhealthy or output could not be parsed. See environment/readiness.json."
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
    # NOT wrapped in @() here: Get-K8ExpectedServices already force-returns a
    # real array via `return ,$services` (correct for 1 element AND for many).
    # Wrapping ITS call site in @() as well double-wraps the result into a
    # 1-element array whose sole element is the real array -- Test-K8Compose
    # ServiceReadiness would then iterate exactly one pseudo-"expected
    # service" (the array object itself, not a service name string), which
    # can never match any real row, making Missing non-empty and Ready
    # false FOREVER regardless of actual Docker state. Root cause of the
    # real VM false negative (k8shakedown-rangea-20260829-071142): 21/21
    # services were genuinely running and healthy the whole time; this
    # double-wrap is what made Test-K8ComposeServiceReadiness never see them.
    $expected = Get-K8ExpectedServices -RunId $RunId -ComposePath $ComposePath
    # STDOUT/STDERR captured separately throughout: a stray Compose/Docker
    # stderr line merged into either JSON capture below would corrupt the
    # mandatory image inventory (a completeness-gate-required artifact).
    $imagesCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'images', '--format', 'json')
    if ($imagesCapture.ExitCode -ne 0) { throw "docker compose images failed (exit $($imagesCapture.ExitCode)); image inventory is mandatory. stderr: $($imagesCapture.Stderr.Trim())" }
    $psJson = $imagesCapture.Stdout
    $psJson | Set-Content -Path (Join-Path $envDir 'compose-images.json') -Encoding utf8NoBOM
    (docker compose -p $RunId -f $ComposePath ps 2>&1) | Set-Content -Path (Join-Path $envDir 'compose-ps.txt') -Encoding utf8NoBOM

    # NOT wrapped in @() -- ConvertFrom-K8ComposePsJson already force-returns
    # a real array; see its own return statement.
    try { $images = ConvertFrom-K8ComposePsJson -Raw ($psJson | Out-String) }
    catch { throw "could not parse mandatory compose image inventory JSON: $($_.Exception.Message)" }
    $resolvedRows = Resolve-K8ComposeImageRows -RunId $RunId -ExpectedServices $expected -ImageRows $images
    $inventory = @()
    foreach ($service in $expected) {
        $img = $resolvedRows[$service]
        $id = Get-K8ObjectPropertyValue -Object $img -Name 'ID'
        $repository = Get-K8ObjectPropertyValue -Object $img -Name 'Repository'
        $tag = Get-K8ObjectPropertyValue -Object $img -Name 'Tag'
        $ref = if ($id) { $id } elseif ($repository -and $tag) { "${repository}:$tag" } else { $null }
        if (-not $ref) { throw "image reference/ID missing for expected service '$service'" }
        $inspectCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('image', 'inspect', $ref)
        if ($inspectCapture.ExitCode -ne 0) { throw "docker image inspect failed for service '$service' image '$ref' (exit $($inspectCapture.ExitCode)). stderr: $($inspectCapture.Stderr.Trim())" }
        $raw = ($inspectCapture.Stdout | Out-String)
        $inspection = @($raw | ConvertFrom-Json)
        if ($inspection.Count -ne 1 -or -not $inspection[0].Id) { throw "inspect result for '$service' lacks an immutable image Id" }
        $digests = @($inspection[0].RepoDigests | Where-Object { $_ })
        $inventory += [ordered]@{ service=$service; resolved_reference=$ref; image_id=$inspection[0].Id; repo_digests=$digests; repo_digests_status=$(if ($digests.Count) {'present'} else {'absent-local-build'}) }
    }
    if ($inventory.Count -ne $expected.Count) { throw 'image inventory is incomplete' }
    $inventory | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $envDir 'image-inventory.json') -Encoding utf8NoBOM
    Write-K8ShakedownLog -Message "Image inventory PASS: all $($inventory.Count) expected service(s) inspected."
}

function Write-K8RuntimeContractRecord {
    <#
        evidence-schema.md SS3's "Range A/B runtime-invariant record." Retains
        what is mechanically observable. Does NOT compute the scored Runtime
        Contract Pass/Fail/Unresolved verdict -- README SS6.2 reserves that
        derivation for the operator, from this record plus the other stages.

        For Range B, c2-dnp3-step4-range-b-fault-pilot.md SS3 lists four
        required nontriviality checks. Checks 1-3 are mechanized here (service
        state via structured `compose ps --format json`, target-interface
        mirror filter removal, zone_detector liveness). Elasticsearch's own
        endpoint readiness is NOT re-checked here -- it already ran, shared
        identically for Range A and Range B, in
        Wait-K8ElasticsearchReady before this function is ever called;
        duplicating that curl call here (as an earlier revision did, with its
        own separate non-polling check) is exactly the kind of Range A/B
        readiness-logic inconsistency that let Range A reach the fixed
        Collector query with no Elasticsearch gate at all. Check 2's "one
        unrelated observed gateway interface still has a mirred egress mirror
        filter" is mechanized via Assert-K8UnrelatedMirrorFilter (called by
        the caller before this function). Check 4's sensor-capture
        unrelated-frame content is mechanized after capture export via
        Write-K8UnrelatedPcapRows; this function only points at where that
        result lands, since the pcap does not exist yet at this call site.
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
    # STDOUT/STDERR captured separately: a stray stderr line must not be
    # merged into the JSON this parses for the Range B service-state gate.
    $psJsonCapture = Invoke-K8SeparatedNativeCapture -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'ps', '--all', '--format', 'json')
    if ($psJsonCapture.ExitCode -ne 0) { throw "docker compose ps --format json failed while building the runtime contract record (exit $($psJsonCapture.ExitCode)). stderr: $($psJsonCapture.Stderr.Trim())" }
    # NOT wrapped in @() -- ConvertFrom-K8ComposePsJson already force-returns
    # a real array; see its own return statement.
    $services = ConvertFrom-K8ComposePsJson -Raw ($psJsonCapture.Stdout | Out-String)
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
        # Structured lookup, not a text/substring match against `compose ps`
        # display output: a service name can appear as a substring of a
        # container/image name unrelated to whether that SERVICE row itself
        # is present and running.
        $readinessCheck = Test-K8ComposeServiceReadiness -Expected $requiredServices -Services $services
        $lines += ''
        $lines += '## c2-dnp3-step4-range-b-fault-pilot.md SS3 nontriviality checks'
        $lines += ''
        if (-not $readinessCheck.Ready) {
            throw "Range B service-state gate failed -- missing: $($readinessCheck.Missing -join ', '); not running: $($readinessCheck.NotRunning -join ', '); unhealthy: $($readinessCheck.NotHealthy -join ', ')"
        }
        $lines += "1. Required services present/running in structured \`compose ps\`: PASS (all of $($requiredServices -join ', ') found)"
        $lines += "2. Target-interface ($($Gateway.Interface)) mirror filter removed: see qdisc-pre-fault.txt / qdisc-post-fault.txt. Unrelated mirror-filter gate: see unrelated-mirror-filters.txt (runner stops unless another interface retains mirred egress mirror)."
        $lines += '3. Elasticsearch endpoint readiness: see environment/elasticsearch-readiness.json (shared Wait-K8ElasticsearchReady gate, already PASS before this record was written -- not re-queried here). zone_detector service state: PASS (checked structurally above, not by text-matching `compose ps` display output).'
        $lines += '4. Sensor unrelated-flow frame and Collector correlation are checked after capture export; see r-obs-05-pcap-rows.json and r-obs-05-correlation.json (runner stops unless the gate passes).'
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
    if (-not $state.PSObject.Properties[$stageKey] -or $state.$stageKey -ne 'awaiting-completion') {
        throw "No Range $($Range.ToUpper()) run is awaiting completion (state.$stageKey = $(if ($state.PSObject.Properties[$stageKey]) { $state.$stageKey } else { '<none>' })). Run .\tools\Run-K8ShakedownRange$($Range.ToUpper()).ps1 first."
    }
    $RunId = $state."range_$($Range)_run_id"
    $RunEvidence = $state."range_$($Range)_evidence"
    $ComposePath = $state."range_$($Range)_compose"
    $Study01 = Join-Path $state.repo_root 'Study01'
    $ScriptsDir = Join-Path $Study01 'studies\study-01-negative-result\scripts'

    Write-K8ShakedownLog -Level STEP -Message "=== Completing Shakedown Range $($Range.ToUpper()): $RunId ==="

    foreach ($required in @('collector-output\collector-response.json', 'rule-output\rule-response.json', 'rule-output\collector-rule-correlation.json')) {
        if (-not (Test-Path (Join-Path $RunEvidence $required))) { throw "required automated runtime evidence missing: $required" }
    }
    if ($Range -eq 'b') {
        foreach ($required in @('r-obs-05-mapping-response.json','r-obs-05-mapping-gate.json','r-obs-05-response.json','r-obs-05-pcap-rows.json','r-obs-05-correlation.json','unrelated-mirror-filters.txt')) {
            if (-not (Test-Path (Join-Path $RunEvidence "contract-output\$required"))) { throw "Range B cannot complete: required R-OBS-05 evidence missing: $required" }
        }
        $mappingGate = Get-Content (Join-Path $RunEvidence 'contract-output\r-obs-05-mapping-gate.json') -Raw | ConvertFrom-Json
        $correlationGate = Get-Content (Join-Path $RunEvidence 'contract-output\r-obs-05-correlation.json') -Raw | ConvertFrom-Json
        if ($mappingGate.mapping_gate_pass -ne $true -or $correlationGate.r_obs_05_mechanical_gate_pass -ne $true) { throw 'Range B cannot complete: an R-OBS-05 mechanical gate is not PASS' }
    }

    # Frozen ordering: prove the runtime evidence is complete and hash it while
    # the project still exists. Only then may cleanup destroy project/volumes.
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $ScriptsDir 'study01_collect.py'), 'validate-evidence', $RunEvidence) -Description 'pre-teardown validate-evidence'
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $ScriptsDir 'study01_collect.py'), 'finalize-evidence', $RunEvidence) -Description 'pre-teardown finalize/hash'
    if (-not (Test-Path (Join-Path $RunEvidence 'hashes.sha256'))) { throw 'pre-teardown finalize did not create hashes.sha256; refusing teardown' }

    Invoke-K8ShakedownCommand -FilePath 'docker' -ArgumentList @('compose', '-p', $RunId, '-f', $ComposePath, 'down', '-v', '--remove-orphans') `
        -Description 'destroy project + volumes (prevent state carry-over)'
    $finalPs = (docker compose -p $RunId -f $ComposePath ps 2>&1 | Out-String)
    $finalPs | Add-Content -Path (Join-Path $RunEvidence 'environment\compose-ps.txt') -Encoding utf8NoBOM

    (Get-Content (Join-Path $RunEvidence 'metadata.md') -Raw) -replace `
        '\| Cleanup \| NOT YET PERFORMED.*\|', `
        "| Cleanup | destroyed via 'docker compose down -v --remove-orphans' at $((Get-Date).ToUniversalTime().ToString('o')); final ps: see environment/compose-ps.txt |" |
        Set-Content -Path (Join-Path $RunEvidence 'metadata.md') -Encoding utf8NoBOM

    "cleanup_utc=$((Get-Date).ToUniversalTime().ToString('o'))`ncommand=docker compose -p $RunId -f $ComposePath down -v --remove-orphans`nresult=PASS" |
        Set-Content -Path (Join-Path $RunEvidence 'environment\cleanup-result.txt') -Encoding utf8NoBOM
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $ScriptsDir 'study01_collect.py'), 'finalize-evidence', $RunEvidence) -Description 'final finalize/hash including cleanup record'
    Invoke-K8ShakedownCommand -FilePath 'python' -ArgumentList @((Join-Path $ScriptsDir 'study01_collect.py'), 'verify-integrity', $RunEvidence) -Description 'final verify-integrity'

    Set-K8ShakedownState -Updates @{ $stageKey = 'complete'; "range_$($Range)_complete_utc" = (Get-Date).ToUniversalTime().ToString('o') }

    Write-K8ShakedownLog -Level STEP -Message "=== Shakedown Range $($Range.ToUpper()) complete: $RunId ==="
    Write-Host ''
    Write-Host "Range $($Range.ToUpper()) run '$RunId' finalized/verified. Remaining manual step (by protocol design, not automated):"
    Write-Host "  README SS6.2: derive scoring-input.json by hand from $RunEvidence BEFORE opening expected/, then:"
    Write-Host "  python `"$(Join-Path $ScriptsDir 'study01_score.py')`" <path-to-scoring-input.json> --run-evidence `"$RunEvidence`" --output `"$RunEvidence\score.json`""
    return $RunEvidence
}

Export-ModuleMember -Function * -Variable K8Shakedown
