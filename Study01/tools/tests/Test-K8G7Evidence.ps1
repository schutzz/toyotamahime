#requires -Version 7.0
<#
Unit tests for K8G7Evidence.psm1 -- accepted G7 v5 evidence-generation/
validation primitives (SECTION A / SECTION D of Kakuriyo's
studies/study-01-negative-result/G7-GATE-K8-EVIDENCE-SEMANTICS-CLARIFICATION-PROPOSAL.md).

Deliberately not a Pester test file: this environment ships only Pester
3.4.0 (the old, bundled Windows version), and pinning a newer Pester was
judged out of scope for this change. This is a small, dependency-free
assertion runner instead -- see Assert-* below.

Run: pwsh -File Study01/tools/tests/Test-K8G7Evidence.ps1
Exit code 0 iff every test passed.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'K8G7Evidence.psm1') -Force

$Script:Passed = 0
$Script:Failed = 0
$Script:FailedNames = @()

function Test-Case {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [scriptblock] $Body)
    try {
        & $Body
        $Script:Passed++
        Write-Host "PASS: $Name" -ForegroundColor Green
    }
    catch {
        $Script:Failed++
        $Script:FailedNames += $Name
        Write-Host "FAIL: $Name -- $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message = '')
    if ($Expected -ne $Actual) {
        throw "Expected [$Expected] but got [$Actual]. $Message"
    }
}

function Assert-True {
    param([bool] $Condition, [string] $Message = '')
    if (-not $Condition) { throw "Expected true. $Message" }
}

function Assert-False {
    param([bool] $Condition, [string] $Message = '')
    if ($Condition) { throw "Expected false. $Message" }
}

function Assert-Throws {
    param([Parameter(Mandatory)] [scriptblock] $Body, [string] $Message = '')
    $Threw = $false
    try { & $Body | Out-Null } catch { $Threw = $true }
    if (-not $Threw) { throw "Expected a throw. $Message" }
}

# ---------------------------------------------------------------------
# command_identity (SECTION A.1a.1a)
# ---------------------------------------------------------------------

Test-Case 'command_identity is deterministic for the same command' {
    Assert-Equal (Get-K8CommandIdentity -Command 'echo hi') (Get-K8CommandIdentity -Command 'echo hi')
}

Test-Case 'command_identity folds CRLF and lone CR to LF' {
    Assert-Equal (Get-K8CommandIdentity -Command "a`r`nb") (Get-K8CommandIdentity -Command "a`nb")
    Assert-Equal (Get-K8CommandIdentity -Command "a`rb") (Get-K8CommandIdentity -Command "a`nb")
}

Test-Case 'command_identity matches Kakuriyo Python reference implementation' {
    # Cross-verified interactively against
    # kakuriyo-cyber-range-research/studies/study-01-negative-result/scripts/study01/g7_command_identity.py
    # command_identity("echo hi") -- both implementations independently
    # produce the same SHA-256 of the same canonical bytes.
    Assert-Equal '56a79f3b115448072387c2480044bfa2cf8f90e4f5fddd8c943b4e051b81f80b' (Get-K8CommandIdentity -Command 'echo hi')
}

# ---------------------------------------------------------------------
# Legal output_class/channel-expectation combinations (SECTION A.1a.1b)
# ---------------------------------------------------------------------

Test-Case 'output-bearing with both channels required_nonempty is legal' {
    Assert-True (Test-K8ExpectationCombinationLegal -OutputClass 'output-bearing' -StdoutExpectation 'required_nonempty' -StderrExpectation 'required_nonempty')
}

Test-Case 'output-bearing with neither channel required_nonempty is illegal' {
    Assert-False (Test-K8ExpectationCombinationLegal -OutputClass 'output-bearing' -StdoutExpectation 'allowed_empty' -StderrExpectation 'allowed_empty')
}

Test-Case 'output-bearing with both channels must_be_empty is illegal' {
    Assert-False (Test-K8ExpectationCombinationLegal -OutputClass 'output-bearing' -StdoutExpectation 'must_be_empty' -StderrExpectation 'must_be_empty')
}

Test-Case 'intentional-silent with both channels must_be_empty is legal' {
    Assert-True (Test-K8ExpectationCombinationLegal -OutputClass 'intentional-silent' -StdoutExpectation 'must_be_empty' -StderrExpectation 'must_be_empty')
}

Test-Case 'intentional-silent with any other pair is illegal' {
    Assert-False (Test-K8ExpectationCombinationLegal -OutputClass 'intentional-silent' -StdoutExpectation 'allowed_empty' -StderrExpectation 'must_be_empty')
}

Test-Case 'illegal output expectation is rejected at construction time' {
    Assert-Throws { New-K8StepExpectation -AttemptId 'k8-repro-20270101-001' -StepIndex 0 -Command 'x' -OutputClass 'output-bearing' -StdoutExpectation 'allowed_empty' -StderrExpectation 'allowed_empty' }
}

# ---------------------------------------------------------------------
# Expectations generated before execution / manifest hash binding
# ---------------------------------------------------------------------

Test-Case 'expectations manifest is written and its hash is recomputable' {
    $tmp = Join-Path $env:TEMP "k8g7-unit-$(Get-Random)"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $path = Join-Path $tmp 'expectations.jsonl'
        $exp0 = New-K8StepExpectation -AttemptId 'k8-repro-20270101-001' -StepIndex 0 -Command 'echo hi' -OutputClass 'output-bearing' -StdoutExpectation 'required_nonempty' -StderrExpectation 'allowed_empty'
        $hash = Write-K8ExpectationsManifest -Path $path -Expectations @($exp0)
        $verify = Test-K8ExpectationManifestBinding -ExpectationsPath $path -PinnedSha256 $hash
        Assert-True $verify.Present 'manifest file should exist'
        Assert-True $verify.Bound 'recomputed hash should match the pinned hash'
    }
    finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

Test-Case 'post-bind mutation of the manifest is detected' {
    $tmp = Join-Path $env:TEMP "k8g7-unit-$(Get-Random)"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $path = Join-Path $tmp 'expectations.jsonl'
        $exp0 = New-K8StepExpectation -AttemptId 'k8-repro-20270101-001' -StepIndex 0 -Command 'echo hi' -OutputClass 'output-bearing' -StdoutExpectation 'required_nonempty' -StderrExpectation 'allowed_empty'
        $hash = Write-K8ExpectationsManifest -Path $path -Expectations @($exp0)
        Add-Content -Path $path -Value 'tampered'
        $verify = Test-K8ExpectationManifestBinding -ExpectationsPath $path -PinnedSha256 $hash
        Assert-False $verify.Bound 'a mutated manifest must not verify as bound'
    }
    finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

Test-Case 'a missing expectations file is reported as not present, not bound' {
    $verify = Test-K8ExpectationManifestBinding -ExpectationsPath (Join-Path $env:TEMP "k8g7-does-not-exist-$(Get-Random).jsonl") -PinnedSha256 'deadbeef'
    Assert-False $verify.Present
    Assert-False $verify.Bound
}

# ---------------------------------------------------------------------
# Per-channel decision rule (SECTION A.2 / A.3): required_nonempty /
# must_be_empty / intentional-silent
# ---------------------------------------------------------------------

Test-Case 'required_nonempty with real content PASSes (satisfied)' {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes('output')
    Assert-Equal $Script:K8ChannelVerdictSatisfied (Get-K8ChannelVerdict -Expectation 'required_nonempty' -CapturePresent $true -CaptureBytes $bytes -StepChronologyProven $true -HasExpectationRecord $true)
}

Test-Case 'required_nonempty with a missing capture FAILs (defect_fail_closed)' {
    Assert-Equal $Script:K8ChannelVerdictDefectFailClosed (Get-K8ChannelVerdict -Expectation 'required_nonempty' -CapturePresent $false -CaptureBytes $null -StepChronologyProven $true -HasExpectationRecord $true)
}

Test-Case 'required_nonempty with a whitespace-only capture FAILs (defect_fail_closed)' {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("   `n`t  ")
    Assert-Equal $Script:K8ChannelVerdictDefectFailClosed (Get-K8ChannelVerdict -Expectation 'required_nonempty' -CapturePresent $true -CaptureBytes $bytes -StepChronologyProven $true -HasExpectationRecord $true)
}

Test-Case 'intentional-silent (must_be_empty) with an empty capture and proven chronology PASSes' {
    Assert-Equal $Script:K8ChannelVerdictSatisfied (Get-K8ChannelVerdict -Expectation 'must_be_empty' -CapturePresent $true -CaptureBytes ([byte[]]@()) -StepChronologyProven $true -HasExpectationRecord $true)
}

Test-Case 'must_be_empty without proven chronology FAILs (defect_fail_closed)' {
    Assert-Equal $Script:K8ChannelVerdictDefectFailClosed (Get-K8ChannelVerdict -Expectation 'must_be_empty' -CapturePresent $true -CaptureBytes ([byte[]]@()) -StepChronologyProven $false -HasExpectationRecord $true)
}

Test-Case 'must_be_empty with unexpected content is not a defect' {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes('warning')
    Assert-Equal $Script:K8ChannelVerdictNotADefect (Get-K8ChannelVerdict -Expectation 'must_be_empty' -CapturePresent $true -CaptureBytes $bytes -StepChronologyProven $true -HasExpectationRecord $true)
}

# ---------------------------------------------------------------------
# Positive leak entry identity (SECTION D.1a.1, RFC 8785/JCS)
# ---------------------------------------------------------------------

function New-TestLeakEntry {
    param($Timestamp = 't', $Reason = 'r', $ActionTaken = 'a', $Licensed = $false, $Prior = $false)
    return [ordered]@{
        timestamp = $Timestamp; reason = $Reason; action_taken = $ActionTaken
        licensed_by_readme = $Licensed; prior_knowledge_used = $Prior
    }
}

Test-Case 'positive leak entry identity is deterministic for the same semantic entry' {
    $a = Get-K8LeakEntryIdentity -Entry (New-TestLeakEntry)
    $b = Get-K8LeakEntryIdentity -Entry (New-TestLeakEntry)
    Assert-False $a.Malformed
    Assert-Equal $a.Identity $b.Identity
}

Test-Case 'positive leak entry identity matches Kakuriyo Python reference implementation' {
    # Cross-verified interactively against g7_knowledge_leak.entry_identity()
    # for the fixed entry {timestamp:"2027-01-01T00:00:00.0000000Z",
    # reason:"example", action_taken:"noted", licensed_by_readme:false,
    # prior_knowledge_used:false}.
    $entry = New-TestLeakEntry -Timestamp '2027-01-01T00:00:00.0000000Z' -Reason 'example' -ActionTaken 'noted'
    $r = Get-K8LeakEntryIdentity -Entry $entry
    Assert-Equal '5f8fda51fa5d49ec2ac26b4c2baf0e94c3eed2f37bacaa63dc16f1623290aa4e' $r.Identity
}

Test-Case 'solidus is emitted literally, not escaped' {
    $r = Get-K8LeakEntryCanonicalBytes -Entry (New-TestLeakEntry -Reason 'a/b')
    $json = [System.Text.Encoding]::UTF8.GetString($r.Bytes)
    Assert-True ($json.Contains('a/b'))
    Assert-False ($json.Contains('a\/b'))
}

Test-Case 'non-ASCII is emitted literally, not \uXXXX-escaped' {
    $r = Get-K8LeakEntryCanonicalBytes -Entry (New-TestLeakEntry -Reason 'にほんご')
    $json = [System.Text.Encoding]::UTF8.GetString($r.Bytes)
    Assert-True ($json.Contains('にほんご'))
}

Test-Case 'quotation mark and reverse solidus are escaped' {
    $r = Get-K8LeakEntryCanonicalBytes -Entry (New-TestLeakEntry -Reason 'a"b\c')
    $json = [System.Text.Encoding]::UTF8.GetString($r.Bytes)
    Assert-True ($json.Contains('a\"b\\c'))
}

Test-Case 'a C0 control character not in the short-escape set uses a lowercase-hex unicode escape' {
    $r = Get-K8LeakEntryCanonicalBytes -Entry (New-TestLeakEntry -Reason ([string]([char]1)))
    $json = [System.Text.Encoding]::UTF8.GetString($r.Bytes)
    $Backslash = [char]0x5C
    $ExpectedEscape = "${Backslash}u000" + "1"
    Assert-True ($json.Contains($ExpectedEscape))
}

Test-Case 'an unpaired surrogate is a malformed entry (authority-defined outcome)' {
    $r = Get-K8LeakEntryCanonicalBytes -Entry (New-TestLeakEntry -Reason ([string]([char]0xD800)))
    Assert-True $r.Malformed
}

Test-Case 'a valid astral character (a real surrogate pair) is not malformed' {
    $astral = [char]::ConvertFromUtf32(0x1F600)
    $r = Get-K8LeakEntryCanonicalBytes -Entry (New-TestLeakEntry -Reason $astral)
    Assert-False $r.Malformed
}

Test-Case 'a missing required field is a malformed entry' {
    $entry = New-TestLeakEntry
    $entry.Remove('reason')
    $r = Get-K8LeakEntryCanonicalBytes -Entry $entry
    Assert-True $r.Malformed
}

# ---------------------------------------------------------------------
# leak_count (SECTION D.1a.2): distinct entry identities, duplicates,
# malformed entries
# ---------------------------------------------------------------------

Test-Case 'duplicate positive entries collapse to a distinct count of one' {
    $count = Get-K8KnowledgeLeakCount -Entries @((New-TestLeakEntry), (New-TestLeakEntry))
    Assert-Equal 1 $count.DistinctCount
    Assert-True $count.Certifiable
}

Test-Case 'distinct positive entries retain their own distinct count' {
    $count = Get-K8KnowledgeLeakCount -Entries @((New-TestLeakEntry -Reason 'a'), (New-TestLeakEntry -Reason 'b'))
    Assert-Equal 2 $count.DistinctCount
}

Test-Case 'a malformed entry blocks certification without affecting the well-formed count' {
    $bad = New-TestLeakEntry
    $bad.Remove('reason')
    $count = Get-K8KnowledgeLeakCount -Entries @((New-TestLeakEntry -Reason 'a'), $bad)
    Assert-Equal 1 $count.DistinctCount
    Assert-False $count.Certifiable
}

# ---------------------------------------------------------------------
# Cross-representation consistency (SECTION D.3)
# ---------------------------------------------------------------------

Test-Case 'zero-count canonical object with no positive entries is sufficient' {
    $canonical = New-K8KnowledgeLeakZeroState -Entries @() -GeneratedAtUtc 'now'
    Assert-Equal $Script:K8CrossRepSufficient (Test-K8KnowledgeLeakCrossRepresentation -Canonical $canonical -MdEntries $null -JsonlEntries $null)
}

Test-Case 'zero-count canonical object contradicted by a positive entry is fail-closed' {
    $canonical = New-K8KnowledgeLeakZeroState -Entries @() -GeneratedAtUtc 'now'
    $verdict = Test-K8KnowledgeLeakCrossRepresentation -Canonical $canonical -MdEntries @((New-TestLeakEntry)) -JsonlEntries $null
    Assert-Equal $Script:K8CrossRepFailClosedContradiction $verdict
}

Test-Case 'a claimed count that does not match the positive entry count is fail-closed' {
    $canonical = New-K8KnowledgeLeakZeroState -Entries @((New-TestLeakEntry -Reason 'a')) -GeneratedAtUtc 'now'
    $verdict = Test-K8KnowledgeLeakCrossRepresentation -Canonical $canonical -MdEntries @((New-TestLeakEntry -Reason 'a'), (New-TestLeakEntry -Reason 'b')) -JsonlEntries $null
    Assert-Equal $Script:K8CrossRepFailClosedCountMismatch $verdict
}

Test-Case 'a matching, nonzero canonical count is sufficient' {
    $entry = New-TestLeakEntry -Reason 'a'
    $canonical = New-K8KnowledgeLeakZeroState -Entries @($entry) -GeneratedAtUtc 'now'
    $verdict = Test-K8KnowledgeLeakCrossRepresentation -Canonical $canonical -MdEntries @($entry) -JsonlEntries @($entry)
    Assert-Equal $Script:K8CrossRepSufficient $verdict
}

Test-Case '.md and .jsonl positive-entry sets that disagree are a representation mismatch (fail-closed)' {
    $entry1 = New-TestLeakEntry -Reason 'a'
    $entry2 = New-TestLeakEntry -Reason 'b'
    $canonical = New-K8KnowledgeLeakZeroState -Entries @($entry1) -GeneratedAtUtc 'now'
    $verdict = Test-K8KnowledgeLeakCrossRepresentation -Canonical $canonical -MdEntries @($entry1) -JsonlEntries @($entry2)
    Assert-Equal $Script:K8CrossRepFailClosedRenderingMismatch $verdict
}

Test-Case 'an unrecognized schema_version is UNSUPPORTED, not insufficient or sufficient' {
    $canonical = [ordered]@{ schema_version = 'k8-knowledge-leak-zero-state/2'; leak_count = 0; count_source = 'x'; generated_at = 't'; finalized = $true }
    $verdict = Test-K8KnowledgeLeakCrossRepresentation -Canonical $canonical -MdEntries $null -JsonlEntries $null
    Assert-Equal $Script:K8CrossRepUnsupportedSchemaVersion $verdict
}

Test-Case 'a canonical object with finalized=false is insufficient' {
    $canonical = [ordered]@{ schema_version = 'k8-knowledge-leak-zero-state/1'; leak_count = 0; count_source = 'x'; generated_at = 't'; finalized = $false }
    $verdict = Test-K8KnowledgeLeakCrossRepresentation -Canonical $canonical -MdEntries $null -JsonlEntries $null
    Assert-Equal $Script:K8CrossRepInsufficientNotFinalized $verdict
}

Test-Case 'no canonical object at all is insufficient for a future (non-historical) attempt' {
    Assert-Equal $Script:K8CrossRepInsufficientNoCanonical (Test-K8KnowledgeLeakCrossRepresentation -Canonical $null -MdEntries $null -JsonlEntries $null)
}

# ---------------------------------------------------------------------
# Attempt-ID collision prevention (plan section 9)
# ---------------------------------------------------------------------

Test-Case 'a novel attempt ID is available' {
    $tmpRoot = Join-Path $env:TEMP "k8g7-unit-attemptid-$(Get-Random)"
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
    try {
        Test-K8AttemptIdAvailable -AttemptId 'k8-repro-20270101-001' -AttemptRoot $tmpRoot -CanonicalInventoryRoots @()  # must not throw
    }
    finally { Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue }
}

Test-Case 'a locally-colliding attempt ID is rejected before execution' {
    $tmpRoot = Join-Path $env:TEMP "k8g7-unit-attemptid-$(Get-Random)"
    New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'k8-repro-20260922-001') -Force | Out-Null
    try {
        Assert-Throws { Test-K8AttemptIdAvailable -AttemptId 'k8-repro-20260922-001' -AttemptRoot $tmpRoot -CanonicalInventoryRoots @() }
    }
    finally { Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue }
}

Test-Case 'a canonical-inventory-only collision (simulated VM rollback) is rejected' {
    $rolledBackRoot = Join-Path $env:TEMP "k8g7-unit-rollback-$(Get-Random)"
    New-Item -ItemType Directory -Path $rolledBackRoot -Force | Out-Null  # empty: simulates the reset local volume
    $canonicalRoot = Join-Path $env:TEMP "k8g7-unit-canonical-$(Get-Random)"
    New-Item -ItemType Directory -Path (Join-Path $canonicalRoot 'k8-repro-20260828-001-v4') -Force | Out-Null
    try {
        Assert-Throws {
            Test-K8AttemptIdAvailable -AttemptId 'k8-repro-20260828-001-v4' -AttemptRoot $rolledBackRoot -CanonicalInventoryRoots @($canonicalRoot)
        }
    }
    finally { Remove-Item -Recurse -Force $rolledBackRoot, $canonicalRoot -ErrorAction SilentlyContinue }
}

Test-Case 'a malformed attempt ID is rejected' {
    $tmpRoot = Join-Path $env:TEMP "k8g7-unit-attemptid-$(Get-Random)"
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
    try {
        Assert-Throws { Test-K8AttemptIdAvailable -AttemptId 'not-an-attempt-id' -AttemptRoot $tmpRoot -CanonicalInventoryRoots @() }
    }
    finally { Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------

Write-Host ''
Write-Host "Passed: $Script:Passed  Failed: $Script:Failed"
if ($Script:Failed -gt 0) {
    Write-Host "Failing tests: $($Script:FailedNames -join '; ')" -ForegroundColor Red
    exit 1
}
exit 0
