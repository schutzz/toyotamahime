#requires -Version 7.0
<#
Integration tests for K8AttemptCommon.psm1's G7 v5 evidence-generation
wiring: a full synthetic attempt lifecycle (allocate -> initialize ->
bind expectations -> run steps -> record knowledge leaks -> close),
exercised end to end against real files under a throwaway temp directory.
No formal K8-3 attempt, Range provisioning, or network access happens
here -- every command run by a synthetic step is a local, inert
PowerShell expression.

Deliberately not a Pester test file -- see Test-K8G7Evidence.ps1's header
for why.

Run: pwsh -File Study01/tools/tests/Test-K8AttemptLifecycle.ps1
Exit code 0 iff every test passed.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'K8AttemptCommon.psm1') -Force

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
    if ($Expected -ne $Actual) { throw "Expected [$Expected] but got [$Actual]. $Message" }
}

function Assert-True {
    param([bool] $Condition, [string] $Message = '')
    if (-not $Condition) { throw "Expected true. $Message" }
}

function Assert-Throws {
    param([Parameter(Mandatory)] [scriptblock] $Body, [string] $Message = '')
    $Threw = $false
    try { & $Body | Out-Null } catch { $Threw = $true }
    if (-not $Threw) { throw "Expected a throw. $Message" }
}

function New-TempAttemptRoot {
    $Root = Join-Path $env:TEMP "k8lifecycle-test-$(Get-Random)"
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    return $Root
}

function New-TempStepPlanFile {
    param([Parameter(Mandatory)] [array] $Steps, [Parameter(Mandatory)] [string] $Directory)
    $Path = Join-Path $Directory 'step-plan.json'
    ConvertTo-Json @($Steps) -Depth 4 | Set-Content -Path $Path -Encoding utf8
    return $Path
}

# ---------------------------------------------------------------------
# Synthetic zero-leak attempt: expectations bound, steps satisfied,
# explicit leak_count = 0 retained at close.
# ---------------------------------------------------------------------

Test-Case 'synthetic zero-leak attempt: expectations generated before execution and bound' {
    $Root = New-TempAttemptRoot
    try {
        $AttemptId = New-K8AttemptId -AttemptRoot $Root
        $Paths = Initialize-K8AttemptDirectory -AttemptRoot $Root -AttemptId $AttemptId -RepoUrl 'https://example.invalid/test' -Ref 'synthetic'

        Assert-True (Test-Path $Paths.AttemptJson) 'attempt.json should exist before any step'
        Assert-True (-not (Test-Path $Paths.ExpectationsJsonl)) 'expectations.jsonl should not exist yet'

        $StepPlan = @(
            @{ description = 'output-bearing step'; command = 'Write-Output "hello"'; output_class = 'output-bearing'; stdout_expectation = 'required_nonempty'; stderr_expectation = 'allowed_empty' },
            @{ description = 'intentional-silent step'; command = 'Test-Path $env:TEMP | Out-Null'; output_class = 'intentional-silent'; stdout_expectation = 'must_be_empty'; stderr_expectation = 'must_be_empty' }
        )
        $StepPlanPath = New-TempStepPlanFile -Steps $StepPlan -Directory $Root

        $ManifestHash = Initialize-K8ExpectationManifest -Paths $Paths -StepPlanPath $StepPlanPath
        Assert-True (Test-Path $Paths.ExpectationsJsonl) 'expectations.jsonl should now exist'

        $AttemptRecord = Get-Content -Path $Paths.AttemptJson -Raw | ConvertFrom-Json
        Assert-Equal $ManifestHash $AttemptRecord.expectation_manifest_sha256 'attempt.json should pin the manifest hash'
    }
    finally { try { Stop-Transcript | Out-Null } catch {}; Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue }
}

Test-Case 'synthetic zero-leak attempt: steps validate against bound expectations and close records leak_count=0' {
    $Root = New-TempAttemptRoot
    try {
        $AttemptId = New-K8AttemptId -AttemptRoot $Root
        $Paths = Initialize-K8AttemptDirectory -AttemptRoot $Root -AttemptId $AttemptId -RepoUrl 'https://example.invalid/test' -Ref 'synthetic'

        $StepPlan = @(
            @{ description = 'output-bearing step'; command = 'Write-Output "hello"'; output_class = 'output-bearing'; stdout_expectation = 'required_nonempty'; stderr_expectation = 'allowed_empty' },
            @{ description = 'intentional-silent step'; command = 'Test-Path $env:TEMP | Out-Null'; output_class = 'intentional-silent'; stdout_expectation = 'must_be_empty'; stderr_expectation = 'must_be_empty' }
        )
        $StepPlanPath = New-TempStepPlanFile -Steps $StepPlan -Directory $Root
        Initialize-K8ExpectationManifest -Paths $Paths -StepPlanPath $StepPlanPath | Out-Null

        $Record0 = Invoke-K8Step -Paths $Paths -Description 'output-bearing step' -Command { Write-Output "hello" }
        Assert-Equal $true $Record0.expectation_command_identity_bound 'step 0 command must match its declared expectation'
        Assert-Equal 'satisfied' $Record0.stdout_verdict

        $Record1 = Invoke-K8Step -Paths $Paths -Description 'intentional-silent step' -Command { Test-Path $env:TEMP | Out-Null }
        Assert-Equal 'satisfied' $Record1.stdout_verdict
        Assert-Equal 'satisfied' $Record1.stderr_verdict

        Complete-K8Attempt -Paths $Paths -Outcome 'Success' -Reason 'integration test'

        $Final = Get-Content -Path $Paths.FinalStatusJson -Raw | ConvertFrom-Json
        Assert-Equal 'k8-knowledge-leak-zero-state/1' $Final.knowledge_leak.schema_version
        Assert-Equal 0 $Final.knowledge_leak.leak_count
        Assert-Equal $true $Final.knowledge_leak.finalized
        Assert-Equal 'sufficient' $Final.knowledge_leak_consistency
        Assert-Equal $true $Final.expectation_manifest_present
        Assert-Equal $true $Final.expectation_manifest_bound
    }
    finally { try { Stop-Transcript | Out-Null } catch {}; Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------
# Synthetic positive-leak attempt: deterministic identity, correct
# distinct count, .md/.jsonl consistency both retained.
# ---------------------------------------------------------------------

Test-Case 'synthetic positive-leak attempt: leak_count is the distinct count and md/jsonl are consistent' {
    $Root = New-TempAttemptRoot
    try {
        $AttemptId = New-K8AttemptId -AttemptRoot $Root
        $Paths = Initialize-K8AttemptDirectory -AttemptRoot $Root -AttemptId $AttemptId -RepoUrl 'https://example.invalid/test' -Ref 'synthetic'

        Add-K8KnowledgeLeak -Paths $Paths -Reason 'used cached credential' -ActionTaken 'reused prior session token' -PriorKnowledgeUsed | Out-Null
        Add-K8KnowledgeLeak -Paths $Paths -Reason 'consulted memory for flag name' -ActionTaken 'used --force' -PriorKnowledgeUsed | Out-Null

        Complete-K8Attempt -Paths $Paths -Outcome 'Failed' -Reason 'integration test: positive leak'

        $Final = Get-Content -Path $Paths.FinalStatusJson -Raw | ConvertFrom-Json
        Assert-Equal 2 $Final.knowledge_leak.leak_count
        Assert-Equal 'sufficient' $Final.knowledge_leak_consistency
    }
    finally { try { Stop-Transcript | Out-Null } catch {}; Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------
# Fail-closed output-expectation violation: a required_nonempty step
# that actually produced empty/whitespace-only output is recorded as
# defect_fail_closed, and that verdict propagates into consistency.
# ---------------------------------------------------------------------

Test-Case 'a required_nonempty step whose actual output is empty is recorded fail-closed' {
    $Root = New-TempAttemptRoot
    try {
        $AttemptId = New-K8AttemptId -AttemptRoot $Root
        $Paths = Initialize-K8AttemptDirectory -AttemptRoot $Root -AttemptId $AttemptId -RepoUrl 'https://example.invalid/test' -Ref 'synthetic'

        $StepPlan = @(
            @{ description = 'claims output-bearing but is silent'; command = 'Write-Output ""'; output_class = 'output-bearing'; stdout_expectation = 'required_nonempty'; stderr_expectation = 'allowed_empty' }
        )
        $StepPlanPath = New-TempStepPlanFile -Steps $StepPlan -Directory $Root
        Initialize-K8ExpectationManifest -Paths $Paths -StepPlanPath $StepPlanPath | Out-Null

        $Record = Invoke-K8Step -Paths $Paths -Description 'claims output-bearing but is silent' -Command { Write-Output "" } -ContinueOnFailure
        Assert-Equal 'defect_fail_closed' $Record.stdout_verdict

        Complete-K8Attempt -Paths $Paths -Outcome 'Failed' -Reason 'integration test: fail-closed capture'
        Assert-True (Test-Path $Paths.FinalStatusJson) 'close must still complete and retain evidence despite the defect'
    }
    finally { try { Stop-Transcript | Out-Null } catch {}; Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------
# Malformed knowledge-leak entry: an authority-defined outcome
# (fail_closed:not_certifiable), not silently dropped or averaged away.
# ---------------------------------------------------------------------

Test-Case 'a malformed retained knowledge-leak entry yields fail_closed:not_certifiable, not a silent count' {
    $Root = New-TempAttemptRoot
    try {
        $AttemptId = New-K8AttemptId -AttemptRoot $Root
        $Paths = Initialize-K8AttemptDirectory -AttemptRoot $Root -AttemptId $AttemptId -RepoUrl 'https://example.invalid/test' -Ref 'synthetic'

        Add-K8KnowledgeLeak -Paths $Paths -Reason 'genuine entry' -ActionTaken 'noted' -PriorKnowledgeUsed | Out-Null
        # Hand-append a line missing a required field -- simulates a
        # corrupted/partial write, not something Add-K8KnowledgeLeak
        # itself would ever produce.
        '{"timestamp":"t","action_taken":"a","licensed_by_readme":false,"prior_knowledge_used":false}' |
            Add-Content -Path $Paths.KnowledgeLeakJsonl -Encoding utf8

        Complete-K8Attempt -Paths $Paths -Outcome 'Failed' -Reason 'integration test: malformed entry'

        $Final = Get-Content -Path $Paths.FinalStatusJson -Raw | ConvertFrom-Json
        Assert-Equal 'fail_closed:not_certifiable' $Final.knowledge_leak_consistency
    }
    finally { try { Stop-Transcript | Out-Null } catch {}; Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------
# Duplicate attempt ID rejected before execution (plan section 9)
# ---------------------------------------------------------------------

Test-Case 'a duplicate attempt ID is rejected before execution, including via a canonical-inventory-only collision' {
    $LocalRoot = New-TempAttemptRoot
    $CanonicalRoot = New-TempAttemptRoot
    try {
        $ExistingId = New-K8AttemptId -AttemptRoot $LocalRoot
        Initialize-K8AttemptDirectory -AttemptRoot $LocalRoot -AttemptId $ExistingId -RepoUrl 'https://example.invalid/test' -Ref 'synthetic' | Out-Null

        # Plain local collision: allocating again from the same root must
        # skip straight past the now-existing ID.
        $NextId = New-K8AttemptId -AttemptRoot $LocalRoot
        Assert-True ($NextId -ne $ExistingId) 'the allocator must not repeat an ID already present locally'

        # Canonical-inventory-only collision, simulating a VM snapshot
        # rollback: a fresh, empty local root plus a canonical root that
        # already retains today's next-computed ID.
        New-Item -ItemType Directory -Path (Join-Path $CanonicalRoot $NextId) -Force | Out-Null
        $RolledBackRoot = New-TempAttemptRoot
        try {
            $ThirdId = New-K8AttemptId -AttemptRoot $RolledBackRoot -CanonicalInventoryRoots @($CanonicalRoot)
            Assert-True ($ThirdId -ne $NextId) 'the allocator must avoid an ID retained only in the canonical inventory'
        }
        finally { Remove-Item -Recurse -Force $RolledBackRoot -ErrorAction SilentlyContinue }
    }
    finally { try { Stop-Transcript | Out-Null } catch {}; Remove-Item -Recurse -Force $LocalRoot, $CanonicalRoot -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------
# Closed-attempt immutability still holds for the new G7 functions
# ---------------------------------------------------------------------

Test-Case 'Initialize-K8ExpectationManifest refuses to run against an already-closed attempt' {
    $Root = New-TempAttemptRoot
    try {
        $AttemptId = New-K8AttemptId -AttemptRoot $Root
        $Paths = Initialize-K8AttemptDirectory -AttemptRoot $Root -AttemptId $AttemptId -RepoUrl 'https://example.invalid/test' -Ref 'synthetic'
        Complete-K8Attempt -Paths $Paths -Outcome 'Success' -Reason 'close before binding'

        $StepPlan = @(@{ description = 'x'; command = 'Write-Output "x"'; output_class = 'output-bearing'; stdout_expectation = 'required_nonempty'; stderr_expectation = 'allowed_empty' })
        $StepPlanPath = New-TempStepPlanFile -Steps $StepPlan -Directory $Root

        Assert-Throws { Initialize-K8ExpectationManifest -Paths $Paths -StepPlanPath $StepPlanPath }
    }
    finally { try { Stop-Transcript | Out-Null } catch {}; Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue }
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
