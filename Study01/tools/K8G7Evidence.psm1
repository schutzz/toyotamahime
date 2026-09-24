#requires -Version 7.0
<#
G7 v5 evidence-generation/validation primitives -- accepted authority.

Kakuriyo (the private research repository)'s
studies/study-01-negative-result/G7-GATE-K8-EVIDENCE-SEMANTICS-CLARIFICATION-PROPOSAL.md
v5, ACCEPTED / AUTHORITY INCORPORATED, is the normative source for every
rule this module implements. This module does not invent any new evidence
semantics; it is a from-scratch PowerShell/.NET implementation of that
document's SECTION A (per-step output expectations) and SECTION D
(knowledge-leak zero-state / positive entry identity / cross-representation
consistency), plus an attempt-ID collision check for plan section 9. Where
this file's comments cite "SECTION X", that is a section of the accepted
proposal, not a section of this file.

Kakuriyo also carries an independent Python reference/checker implementation
of the same rules (scripts/study01/g7_*.py) -- that implementation is not
itself normative; it exists to validate evidence a formal attempt (this
harness) produces. This module and that one are two independent
implementations of the one authority document, so a formal attempt's
generated evidence can be cross-checked by both.

Scope discipline (same as K8AttemptCommon.psm1, which this module is
imported by): this module only generates and validates evidence bytes. It
never decides, scores, or interprets a reproduction outcome, and it never
issues or claims Gate K8.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------
# Shared string canonicalization (SECTION A.1a.1a steps 1-4), reused by
# command_identity and, before JCS serialization, by leak-entry fields.
# ---------------------------------------------------------------------

function ConvertTo-K8CanonicalString {
    <#
        NFC-normalize, then fold CRLF/CR to LF. No other change is made.
        SECTION A.1a.1a steps 1-4 (step 1, JSON-string-decoding, is the
        caller's responsibility -- every caller here already has a plain
        .NET string, not a raw JSON literal).
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value
    )

    $Normalized = $Value.Normalize([System.Text.NormalizationForm]::FormC)
    $Normalized = $Normalized -replace "`r`n", "`n"
    $Normalized = $Normalized -replace "`r", "`n"
    return $Normalized
}

# ---------------------------------------------------------------------
# command_identity (SECTION A.1a.1a)
# ---------------------------------------------------------------------

function Get-K8CommandIdentity {
    <#
        Canonical command_identity: NFC + CRLF/CR->LF, UTF-8 (no BOM), no
        terminal newline, SHA-256 (lowercase hex). The single canonical
        procedure -- no other representation is valid. Both a step's
        pre-execution expectation record and its actually-executed
        command must be hashed through this same function so the two can
        be compared (SECTION A.1a.1's command_identity binding check).
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Command
    )

    $Canonical = ConvertTo-K8CanonicalString -Value $Command
    $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $Bytes = $Utf8NoBom.GetBytes($Canonical)
    $Hash = [System.Security.Cryptography.SHA256]::HashData($Bytes)
    return ([System.BitConverter]::ToString($Hash) -replace '-', '').ToLowerInvariant()
}

# ---------------------------------------------------------------------
# Per-step expectation schema (SECTION A.1a.1 / A.1a.1b)
# ---------------------------------------------------------------------

$Script:K8StepExpectationSchemaVersion = 'k8-step-expectation/1'
$Script:K8KnowledgeLeakSchemaVersion = 'k8-knowledge-leak-zero-state/1'

function Test-K8ExpectationCombinationLegal {
    <#
        SECTION A.1a.1b's general rule: intentional-silent legally pairs
        with exactly must_be_empty/must_be_empty; output-bearing legally
        pairs with any combination where at least one channel is
        required_nonempty and not both channels are must_be_empty. Every
        other combination is schema-invalid.
    #>
    param(
        [Parameter(Mandatory)] [string] $OutputClass,
        [Parameter(Mandatory)] [string] $StdoutExpectation,
        [Parameter(Mandatory)] [string] $StderrExpectation
    )

    $ValidChannel = @('required_nonempty', 'allowed_empty', 'must_be_empty')
    if ($OutputClass -notin @('output-bearing', 'intentional-silent')) { return $false }
    if ($StdoutExpectation -notin $ValidChannel) { return $false }
    if ($StderrExpectation -notin $ValidChannel) { return $false }

    if ($OutputClass -eq 'intentional-silent') {
        return ($StdoutExpectation -eq 'must_be_empty' -and $StderrExpectation -eq 'must_be_empty')
    }

    # output-bearing
    $HasRequired = ($StdoutExpectation -eq 'required_nonempty') -or ($StderrExpectation -eq 'required_nonempty')
    $BothSilent = ($StdoutExpectation -eq 'must_be_empty') -and ($StderrExpectation -eq 'must_be_empty')
    return ($HasRequired -and -not $BothSilent)
}

function New-K8StepExpectation {
    <#
        Builds one SECTION A.1a.1 expectation record. Throws if the
        output_class/channel combination is not one of SECTION A.1a.1b's
        legal rows -- reject at schema-validation time, not accept with
        an unusual meaning.
    #>
    param(
        [Parameter(Mandatory)] [string] $AttemptId,
        [Parameter(Mandatory)] [int] $StepIndex,
        [Parameter(Mandatory)] [string] $Command,
        [Parameter(Mandatory)] [string] $OutputClass,
        [Parameter(Mandatory)] [string] $StdoutExpectation,
        [Parameter(Mandatory)] [string] $StderrExpectation
    )

    if (-not (Test-K8ExpectationCombinationLegal -OutputClass $OutputClass `
                -StdoutExpectation $StdoutExpectation -StderrExpectation $StderrExpectation)) {
        throw (
            "Illegal output_class/channel-expectation combination for step " +
            "${StepIndex}: OutputClass=$OutputClass StdoutExpectation=$StdoutExpectation " +
            "StderrExpectation=$StderrExpectation (SECTION A.1a.1b)."
        )
    }

    return [ordered]@{
        schema_version          = $Script:K8StepExpectationSchemaVersion
        attempt_id              = $AttemptId
        step_index              = $StepIndex
        command_identity        = Get-K8CommandIdentity -Command $Command
        output_class            = $OutputClass
        stdout_expectation      = $StdoutExpectation
        stderr_expectation      = $StderrExpectation
        bound_before_execution  = $true
    }
}

function Write-K8ExpectationsManifest {
    <#
        SECTION A.1a.2 steps 1-3: writes expectations.jsonl (one compact
        JSON object per line, in step_index order) and returns its
        SHA-256 (lowercase hex) -- the value the caller pins into
        attempt.json.expectation_manifest_sha256 before any step runs.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [array] $Expectations
    )

    $Ordered = $Expectations | Sort-Object { [int]$_.step_index }

    $Lines = foreach ($Expectation in $Ordered) {
        $Expectation | ConvertTo-Json -Compress -Depth 4
    }

    $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $Content = (($Lines -join "`n") + "`n")
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)

    $Bytes = [System.IO.File]::ReadAllBytes($Path)
    $Hash = [System.Security.Cryptography.SHA256]::HashData($Bytes)
    return ([System.BitConverter]::ToString($Hash) -replace '-', '').ToLowerInvariant()
}

function ConvertFrom-K8JsonLine {
    <#
        Parses one compact JSON object line without PowerShell's
        ConvertFrom-Json cmdlet -- which, on this platform, silently
        upgrades an ISO-8601-shaped JSON string (e.g. a knowledge-leak
        entry's `timestamp` field) to a .NET [DateTime] value. That
        breaks SECTION D.1a.1's requirement that timestamp/reason/
        action_taken are string field values: a re-serialized DateTime
        is not byte-identical to the original JSON string, and a third
        party's plain JSON parser (which has no such special case) would
        never produce that type in the first place. Using
        System.Text.Json.JsonDocument directly keeps every JSON string a
        PowerShell [string] and every JSON true/false a [bool], with no
        cmdlet-level type inference layered on top.
    #>
    param(
        [Parameter(Mandatory)] [string] $Line
    )

    $Doc = [System.Text.Json.JsonDocument]::Parse($Line)
    try {
        $Result = [ordered]@{}
        foreach ($Prop in $Doc.RootElement.EnumerateObject()) {
            $Result[$Prop.Name] =
                switch ($Prop.Value.ValueKind) {
                    'String' { $Prop.Value.GetString() }
                    'True'   { $true }
                    'False'  { $false }
                    'Null'   { $null }
                    'Number' { $Prop.Value.GetDouble() }
                    default  { $Prop.Value.GetRawText() }
                }
        }
        return $Result
    }
    finally {
        $Doc.Dispose()
    }
}

function Get-K8KnowledgeLeakMdEntries {
    <#
        Parses knowledge-leak-log.md back into the same 5-field shape as
        the .jsonl entries, using the exact block format
        Add-K8KnowledgeLeak writes (## <timestamp> heading, then
        **Reason:**/**Action taken:**/**Licensed by README:**/
        **Prior/operator knowledge used:** lines). This lets
        Test-K8KnowledgeLeakCrossRepresentation's rows 8-9 (the .md/.jsonl
        rendering-consistency check) actually run against this harness's
        two retained representations, rather than being skipped. Returns
        an empty array (not $null) if the file does not exist -- "the
        file is absent" and "the file exists with zero entries" are
        different facts elsewhere in this module; a caller that needs
        that distinction should Test-Path separately.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path $Path)) { return @() }

    $Text = Get-Content -Path $Path -Raw
    $BlockPattern = [regex]'(?ms)^## (?<timestamp>\S+)\s*\r?\n\r?\n\*\*Reason:\*\* (?<reason>.*?)\r?\n\*\*Action taken:\*\* (?<action_taken>.*?)\r?\n\*\*Licensed by README:\*\* (?<licensed>True|False)\r?\n\*\*Prior/operator knowledge used:\*\* (?<prior>True|False)'

    $Entries = @(
        foreach ($Match in $BlockPattern.Matches($Text)) {
            $ActionTaken = $Match.Groups['action_taken'].Value
            if ($ActionTaken -eq '(none recorded)') { $ActionTaken = '' }

            [ordered]@{
                timestamp             = $Match.Groups['timestamp'].Value
                reason                = $Match.Groups['reason'].Value
                action_taken          = $ActionTaken
                licensed_by_readme    = [bool]::Parse($Match.Groups['licensed'].Value)
                prior_knowledge_used  = [bool]::Parse($Match.Groups['prior'].Value)
            }
        }
    )

    return $Entries
}

function Get-K8ExpectationForStep {
    <#
        The pre-execution-bound expectation record for one step_index, or
        $null if expectations.jsonl does not exist or has no record for
        that index (SECTION A.3's last row: the historical-applicability
        rule then applies -- this is not itself a defect for an attempt
        that never claimed to bind expectations).
    #>
    param(
        [Parameter(Mandatory)] [string] $ExpectationsPath,
        [Parameter(Mandatory)] [int] $StepIndex
    )

    if (-not (Test-Path $ExpectationsPath)) { return $null }

    foreach ($Line in Get-Content -Path $ExpectationsPath) {
        if (-not $Line.Trim()) { continue }
        $Record = $Line | ConvertFrom-Json
        if ([int]$Record.step_index -eq $StepIndex) { return $Record }
    }

    return $null
}

function Test-K8ExpectationManifestBinding {
    <#
        SECTION A.1a.2 step 4: recompute expectations.jsonl's SHA-256 and
        compare against the pinned attempt.json value. Returns $true/
        $false; never throws -- a mismatch is recorded as a fact by the
        caller (fail-closed at certification time), not a crash of the
        attempt-close sequence.
    #>
    param(
        [Parameter(Mandatory)] [string] $ExpectationsPath,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $PinnedSha256
    )

    if (-not (Test-Path $ExpectationsPath)) {
        return [pscustomobject]@{ Present = $false; Bound = $false; RecomputedSha256 = $null }
    }

    $Bytes = [System.IO.File]::ReadAllBytes($ExpectationsPath)
    $Hash = [System.Security.Cryptography.SHA256]::HashData($Bytes)
    $Recomputed = ([System.BitConverter]::ToString($Hash) -replace '-', '').ToLowerInvariant()

    return [pscustomobject]@{
        Present          = $true
        Bound            = ($Recomputed -eq $PinnedSha256)
        RecomputedSha256 = $Recomputed
    }
}

# ---------------------------------------------------------------------
# Non-empty capture / per-channel decision rule (SECTION A.2 / A.3)
# ---------------------------------------------------------------------

function Test-K8NonEmptyCapture {
    <#
        SECTION A.2: at least one byte of content beyond whitespace-only
        padding. A whitespace-only capture is treated as empty.
    #>
    param(
        [byte[]] $Bytes
    )

    if (-not $Bytes -or $Bytes.Count -eq 0) { return $false }

    $Text = [System.Text.Encoding]::UTF8.GetString($Bytes)
    return ($Text.Trim().Length -gt 0)
}

$Script:K8ChannelVerdictSatisfied = 'satisfied'
$Script:K8ChannelVerdictDefectFailClosed = 'defect_fail_closed'
$Script:K8ChannelVerdictNotADefect = 'not_a_defect'
$Script:K8ChannelVerdictHistoricalApplicabilityRuleApplies = 'historical_applicability_rule_applies'

function Get-K8ChannelVerdict {
    <#
        SECTION A.3's decision table, evaluated per channel.
        -StepChronologyProven is the must_be_empty proviso: independent
        evidence (a steps.jsonl entry with a matching command, exit code,
        transcript step-marker, and command_identity match) that the step
        actually ran -- not merely that its declaration exists.
    #>
    param(
        [Parameter(Mandatory)] [string] $Expectation,
        [Parameter(Mandatory)] [bool] $CapturePresent,
        [byte[]] $CaptureBytes,
        [Parameter(Mandatory)] [bool] $StepChronologyProven,
        [Parameter(Mandatory)] [bool] $HasExpectationRecord
    )

    if (-not $HasExpectationRecord) {
        return $Script:K8ChannelVerdictHistoricalApplicabilityRuleApplies
    }

    $NonEmpty = $CapturePresent -and (Test-K8NonEmptyCapture -Bytes $CaptureBytes)

    switch ($Expectation) {
        'required_nonempty' {
            if ($NonEmpty) { return $Script:K8ChannelVerdictSatisfied }
            return $Script:K8ChannelVerdictDefectFailClosed
        }
        'must_be_empty' {
            $Empty = (-not $CapturePresent) -or (-not (Test-K8NonEmptyCapture -Bytes $CaptureBytes))
            if ($Empty) {
                if ($StepChronologyProven) { return $Script:K8ChannelVerdictSatisfied }
                return $Script:K8ChannelVerdictDefectFailClosed
            }
            return $Script:K8ChannelVerdictNotADefect
        }
        'allowed_empty' {
            return $Script:K8ChannelVerdictSatisfied
        }
        default {
            throw "Unknown channel expectation: $Expectation"
        }
    }
}

# ---------------------------------------------------------------------
# Knowledge-leak positive entry identity (SECTION D.1a.1, RFC 8785/JCS)
# ---------------------------------------------------------------------

$Script:K8LeakEntryFields = @('action_taken', 'licensed_by_readme', 'prior_knowledge_used', 'reason', 'timestamp')
$Script:K8LeakEntryStringFields = @('timestamp', 'reason', 'action_taken')
$Script:K8LeakEntryBoolFields = @('licensed_by_readme', 'prior_knowledge_used')

function ConvertTo-K8JcsEscapedString {
    <#
        SECTION D.1a.1 step 3's string-value escaping rule: quotation
        mark / reverse solidus / the five named C0 controls use their
        short escapes; every other C0 control uses \u00XX lowercase hex;
        solidus and every other code unit (including both halves of a
        valid surrogate pair, i.e. genuine non-ASCII/astral text) is
        passed through literally. This function does not itself detect
        an unpaired surrogate -- Get-K8LeakEntryCanonicalBytes does, by
        encoding the assembled string with a throwing UTF-8 encoder,
        which is the correct place to detect ill-formed UTF-16 in .NET's
        string model (unlike Python, a valid astral character is
        legitimately two UTF-16 code units here).
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value
    )

    $Builder = [System.Text.StringBuilder]::new()

    foreach ($Ch in $Value.ToCharArray()) {
        $Cp = [int][char]$Ch
        switch ($Cp) {
            0x22 { [void]$Builder.Append('\"'); continue }
            0x5C { [void]$Builder.Append('\\'); continue }
            0x08 { [void]$Builder.Append('\b'); continue }
            0x0C { [void]$Builder.Append('\f'); continue }
            0x0A { [void]$Builder.Append('\n'); continue }
            0x0D { [void]$Builder.Append('\r'); continue }
            0x09 { [void]$Builder.Append('\t'); continue }
            default {
                if ($Cp -lt 0x20) {
                    [void]$Builder.Append('\u{0:x4}' -f $Cp)
                }
                else {
                    [void]$Builder.Append($Ch)
                }
            }
        }
    }

    return $Builder.ToString()
}

function Get-K8LeakEntryCanonicalBytes {
    <#
        SECTION D.1a.1 steps 1-4: canonical JCS bytes for one leak entry.
        Never throws -- a malformed entry (missing/mistyped field, or an
        unpaired surrogate in a string field) is signaled by returning
        .Malformed = $true / .Reason, not by raising an exception. This
        (rather than a custom exception type) is deliberate: a type
        caught with `catch [SomeType]` only resolves across an
        Import-Module boundary via `using module`, which is more
        machinery than this needs, and "this entry is malformed" is
        recoverable, retained-evidence data, not a crash.
    #>
    param(
        [Parameter(Mandatory)] $Entry
    )

    foreach ($Field in $Script:K8LeakEntryFields) {
        $HasField =
            if ($Entry -is [System.Collections.IDictionary]) { $Entry.Contains($Field) }
            else { [bool]($Entry.PSObject.Properties.Name -contains $Field) }

        if (-not $HasField) {
            return [pscustomobject]@{ Malformed = $true; Reason = "missing field: $Field"; Bytes = $null }
        }
    }

    $Parts = @()
    foreach ($Field in $Script:K8LeakEntryFields) {
        $Value = $Entry.$Field

        if ($Field -in $Script:K8LeakEntryStringFields) {
            if ($Value -isnot [string]) {
                return [pscustomobject]@{ Malformed = $true; Reason = "field '$Field' must be a string"; Bytes = $null }
            }
            # .NET's String.Normalize() itself rejects an unpaired
            # surrogate as an invalid Unicode code point -- that is this
            # rule's malformed-entry case (SECTION D.1a.1's last bullet),
            # detected here rather than at the later UTF-8 encode step.
            try {
                $Canonical = ConvertTo-K8CanonicalString -Value $Value
            }
            catch {
                return [pscustomobject]@{ Malformed = $true; Reason = 'unpaired surrogate code point in string field'; Bytes = $null }
            }
            $Escaped = ConvertTo-K8JcsEscapedString -Value $Canonical
            $Parts += ('"{0}":"{1}"' -f $Field, $Escaped)
        }
        elseif ($Field -in $Script:K8LeakEntryBoolFields) {
            if ($Value -isnot [bool]) {
                return [pscustomobject]@{ Malformed = $true; Reason = "field '$Field' must be a boolean"; Bytes = $null }
            }
            $Parts += ('"{0}":{1}' -f $Field, $(if ($Value) { 'true' } else { 'false' }))
        }
    }

    $Json = '{' + ($Parts -join ',') + '}'

    # Throwing UTF-8 encoder: an unpaired surrogate anywhere in $Json
    # raises here, which is this rule's malformed-entry case (SECTION
    # D.1a.1's last bullet). A valid surrogate pair (real astral text)
    # encodes correctly and is emitted literally, per that same bullet.
    $ThrowingUtf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)

    try {
        $Bytes = $ThrowingUtf8NoBom.GetBytes($Json)
        return [pscustomobject]@{ Malformed = $false; Reason = $null; Bytes = $Bytes }
    }
    catch [System.Text.EncoderFallbackException] {
        return [pscustomobject]@{ Malformed = $true; Reason = 'unpaired surrogate code point in string field'; Bytes = $null }
    }
}

function Get-K8LeakEntryIdentity {
    <#
        SECTION D.1a.1: SHA-256 (lowercase hex) of the canonical bytes.
        Returns .Malformed/.Reason/.Identity, mirroring
        Get-K8LeakEntryCanonicalBytes -- see that function for why this
        does not throw.
    #>
    param(
        [Parameter(Mandatory)] $Entry
    )

    $Canonical = Get-K8LeakEntryCanonicalBytes -Entry $Entry
    if ($Canonical.Malformed) {
        return [pscustomobject]@{ Malformed = $true; Reason = $Canonical.Reason; Identity = $null }
    }

    $Hash = [System.Security.Cryptography.SHA256]::HashData($Canonical.Bytes)
    $Identity = ([System.BitConverter]::ToString($Hash) -replace '-', '').ToLowerInvariant()
    return [pscustomobject]@{ Malformed = $false; Reason = $null; Identity = $Identity }
}

function Get-K8KnowledgeLeakCount {
    <#
        SECTION D.1a.2: leak_count = distinct entry identities among
        well-formed entries. Malformed entries are excluded from the
        count and returned separately; their presence means the count
        cannot be certified (Certifiable = $false).
    #>
    param(
        [array] $Entries = @()
    )

    $Identities = [System.Collections.Generic.HashSet[string]]::new()
    $Malformed = @()

    foreach ($Entry in $Entries) {
        $Result = Get-K8LeakEntryIdentity -Entry $Entry
        if ($Result.Malformed) {
            $Malformed += [pscustomobject]@{ Entry = $Entry; Reason = $Result.Reason }
        }
        else {
            [void]$Identities.Add($Result.Identity)
        }
    }

    return [pscustomobject]@{
        DistinctCount = $Identities.Count
        Identities    = $Identities
        Malformed     = $Malformed
        Certifiable   = ($Malformed.Count -eq 0)
    }
}

function New-K8KnowledgeLeakZeroState {
    <#
        SECTION D.1: the canonical final-status.json.knowledge_leak
        object, built from whatever positive entries the attempt
        actually retained (leak_count = 0 when there are none). Always
        called at attempt close (Complete-K8Attempt) -- explicit
        positive evidence, never an omission a reviewer must interpret.
    #>
    param(
        [array] $Entries = @(),
        [Parameter(Mandatory)] [string] $GeneratedAtUtc,
        [bool] $Finalized = $true
    )

    $Count = Get-K8KnowledgeLeakCount -Entries $Entries

    return [ordered]@{
        schema_version = $Script:K8KnowledgeLeakSchemaVersion
        leak_count     = $Count.DistinctCount
        count_source   = 'harness-counted: Add-K8KnowledgeLeak invocation count'
        generated_at   = $GeneratedAtUtc
        finalized      = $Finalized
    }
}

# ---------------------------------------------------------------------
# Cross-representation consistency (SECTION D.3)
# ---------------------------------------------------------------------

$Script:K8CrossRepSufficient = 'sufficient'
$Script:K8CrossRepFailClosedContradiction = 'fail_closed:contradiction'
$Script:K8CrossRepFailClosedCountMismatch = 'fail_closed:count_mismatch'
$Script:K8CrossRepFailClosedRenderingMismatch = 'fail_closed:rendering_mismatch'
$Script:K8CrossRepFailClosedNotCertifiable = 'fail_closed:not_certifiable'
$Script:K8CrossRepUnsupportedSchemaVersion = 'unsupported:schema_version'
$Script:K8CrossRepInsufficientNotFinalized = 'insufficient:not_finalized'
$Script:K8CrossRepInsufficientNoCanonical = 'insufficient:no_canonical'

function Test-K8KnowledgeLeakCrossRepresentation {
    <#
        SECTION D.3's table, evaluated mechanically for what a single
        attempt actually retains: the canonical final-status.json object,
        and independently-parsed .md/.jsonl positive-entry sets (this
        harness never retains a separate SECTION D.2 standalone record,
        so that comparison is out of scope here -- rows 6/7/11's
        standalone-specific checks are covered on the Kakuriyo side for
        any representation that later adds one).
    #>
    param(
        $Canonical,
        [array] $MdEntries,
        [array] $JsonlEntries
    )

    if ($null -eq $Canonical) {
        return $Script:K8CrossRepInsufficientNoCanonical
    }

    if ($Canonical.schema_version -ne $Script:K8KnowledgeLeakSchemaVersion) {
        return $Script:K8CrossRepUnsupportedSchemaVersion
    }

    if ($Canonical.finalized -ne $true) {
        return $Script:K8CrossRepInsufficientNotFinalized
    }

    # NOTE: every branch below assigns via a plain imperative if/elseif/else
    # STATEMENT, deliberately, rather than `$x = if (...) {...} else {...}`
    # as an expression. PowerShell unrolls an IEnumerable (a HashSet
    # included) when it is the captured "value" of a script-block/if-branch
    # expression, which silently turns an empty HashSet into $null and a
    # multi-item HashSet into an array of its elements. A plain assignment
    # statement inside each branch does not go through that pipeline-output
    # path, so it does not unroll.
    $MdResult = $null
    if ($null -ne $MdEntries) { $MdResult = Get-K8KnowledgeLeakCount -Entries $MdEntries }

    $JsonlResult = $null
    if ($null -ne $JsonlEntries) { $JsonlResult = Get-K8KnowledgeLeakCount -Entries $JsonlEntries }

    foreach ($Result in @($MdResult, $JsonlResult)) {
        if ($null -ne $Result -and -not $Result.Certifiable) {
            return $Script:K8CrossRepFailClosedNotCertifiable
        }
    }

    $PositiveIdentities = [System.Collections.Generic.HashSet[string]]::new()
    if ($null -ne $MdResult -and $null -ne $JsonlResult) {
        if (-not $MdResult.Identities.SetEquals($JsonlResult.Identities)) {
            return $Script:K8CrossRepFailClosedRenderingMismatch
        }
        $PositiveIdentities = $MdResult.Identities
    }
    elseif ($null -ne $MdResult) {
        $PositiveIdentities = $MdResult.Identities
    }
    elseif ($null -ne $JsonlResult) {
        $PositiveIdentities = $JsonlResult.Identities
    }

    $PositiveCount = $PositiveIdentities.Count
    $ClaimedCount = [int]$Canonical.leak_count

    if ($ClaimedCount -eq 0 -and $PositiveCount -gt 0) {
        return $Script:K8CrossRepFailClosedContradiction
    }
    if ($ClaimedCount -ne 0 -and $ClaimedCount -ne $PositiveCount) {
        return $Script:K8CrossRepFailClosedCountMismatch
    }

    return $Script:K8CrossRepSufficient
}

# ---------------------------------------------------------------------
# Attempt-ID collision prevention (plan section 9)
# ---------------------------------------------------------------------

$Script:K8AttemptIdPattern = '^k8-repro-\d{8}-\d{3}(-v\d+)?$'

function Get-K8CanonicalAttemptIds {
    <#
        The set of attempt_ids already present as a directory or a
        <id>.zip archive under one inventory root -- either the local
        $AttemptRoot on this VM, or any additional -CanonicalInventoryRoots
        the caller supplies (e.g. a copy of Kakuriyo's
        evidence/reproduction/ tree, or any other retained-archive
        location that is not reset by a VM-local snapshot rollback).
    #>
    param(
        [Parameter(Mandatory)] [string] $Root
    )

    if (-not (Test-Path $Root)) { return @() }

    return @(
        Get-ChildItem -Path $Root -Force -ErrorAction SilentlyContinue |
            ForEach-Object { ($_.Name -replace '\.zip$', '') -replace '\.zip\.sha256$', '' } |
            Where-Object { $_ -match $Script:K8AttemptIdPattern } |
            Sort-Object -Unique
    )
}

function Test-K8AttemptIdAvailable {
    <#
        Raises if -AttemptId is malformed, or collides with an attempt_id
        already retained under -AttemptRoot (the local VM) or any of
        -CanonicalInventoryRoots. This is the actual defense against the
        VM-snapshot-rollback class that produced
        k8-repro-20260828-001-v4's same-ID violation: a rollback resets
        $AttemptRoot, but not a canonical inventory root that lives
        outside the rolled-back volume (a mounted/synced copy of
        Kakuriyo's evidence/reproduction/, or any other retained-archive
        location the operator points this at). Fail-closed on collision;
        never silently repairs with a suffix.
    #>
    param(
        [Parameter(Mandatory)] [string] $AttemptId,
        [Parameter(Mandatory)] [string] $AttemptRoot,
        [string[]] $CanonicalInventoryRoots = @()
    )

    if ($AttemptId -notmatch $Script:K8AttemptIdPattern) {
        throw "'$AttemptId' does not match the k8-repro-YYYYMMDD-NNN[-vN] pattern."
    }

    $Roots = @($AttemptRoot) + @($CanonicalInventoryRoots)

    foreach ($Root in $Roots) {
        $Existing = Get-K8CanonicalAttemptIds -Root $Root
        if ($AttemptId -in $Existing) {
            throw (
                "Attempt ID '$AttemptId' collides with an attempt already retained " +
                "under '$Root'. Refusing to reuse or overwrite -- this is the same " +
                'failure class a VM snapshot rollback previously produced ' +
                "(k8-repro-20260828-001-v4). Investigate before retrying; do not " +
                'append a suffix to work around this.'
            )
        }
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-K8CanonicalString',
    'Get-K8CommandIdentity',
    'Test-K8ExpectationCombinationLegal',
    'New-K8StepExpectation',
    'Write-K8ExpectationsManifest',
    'ConvertFrom-K8JsonLine',
    'Get-K8KnowledgeLeakMdEntries',
    'Get-K8ExpectationForStep',
    'Test-K8ExpectationManifestBinding',
    'Test-K8NonEmptyCapture',
    'Get-K8ChannelVerdict',
    'ConvertTo-K8JcsEscapedString',
    'Get-K8LeakEntryCanonicalBytes',
    'Get-K8LeakEntryIdentity',
    'Get-K8KnowledgeLeakCount',
    'New-K8KnowledgeLeakZeroState',
    'Test-K8KnowledgeLeakCrossRepresentation',
    'Get-K8CanonicalAttemptIds',
    'Test-K8AttemptIdAvailable'
) -Variable @(
    'K8StepExpectationSchemaVersion',
    'K8KnowledgeLeakSchemaVersion',
    'K8ChannelVerdictSatisfied',
    'K8ChannelVerdictDefectFailClosed',
    'K8ChannelVerdictNotADefect',
    'K8ChannelVerdictHistoricalApplicabilityRuleApplies',
    'K8CrossRepSufficient',
    'K8CrossRepFailClosedContradiction',
    'K8CrossRepFailClosedCountMismatch',
    'K8CrossRepFailClosedRenderingMismatch',
    'K8CrossRepFailClosedNotCertifiable',
    'K8CrossRepUnsupportedSchemaVersion',
    'K8CrossRepInsufficientNotFinalized',
    'K8CrossRepInsufficientNoCanonical'
)
