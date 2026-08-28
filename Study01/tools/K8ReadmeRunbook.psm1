#requires -Version 7.0
<#
K8-3 package certification -- README block extraction ("Layer C").

Purpose: let certification execute the README's own documented commands
literally, instead of a hand-copied re-implementation of them living in
test code. The two are otherwise guaranteed to drift -- exactly the
failure mode this exists to prevent (README breaks, test still passes
because it never actually reads the README).

Marker syntax, placed on the line immediately before a fenced code
block:

    <!-- k8-test:id=<short-id> mode=exec|parse|display cwd=<repo-root|Study01> -->
    ```powershell
    ...literal command text...
    ```

- exec:    certification runs this text literally, in the declared cwd.
- parse:   certification only PowerShell-parses this text (no execution)
           -- for blocks whose execution needs a mocked-out external
           dependency (network, Docker, an external repo) that this
           certification does not stand up.
- display: not certification input at all -- explanatory/placeholder
           text. Reproduction-critical-path blocks should not be marked
           display merely to dodge certification; Test-Study01Packaging.ps1
           flags a display block that looks like a real command as a
           finding, not a silent pass.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-K8ReadmeBlocks {
    <#
        Parses a markdown file for k8-test-marked fenced code blocks and
        returns one ordered object per block: Id, Mode, Cwd, Code (the
        literal text between the fences, exactly as written -- no
        re-indentation, no substitution), and LineNumber (1-based, of the
        marker comment, for error messages).
    #>
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path $Path)) {
        throw "README not found: $Path"
    }

    $Lines =
        Get-Content -Path $Path

    $MarkerPattern =
        '^<!--\s*k8-test:id=(?<id>\S+)\s+mode=(?<mode>exec|parse|display)\s+cwd=(?<cwd>\S+)\s*-->\s*$'

    $Blocks =
        [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch $MarkerPattern) {
            continue
        }

        $Id   = $Matches['id']
        $Mode = $Matches['mode']
        $Cwd  = $Matches['cwd']
        $MarkerLine = $i + 1

        $FenceOpenIndex = $i + 1

        if ($FenceOpenIndex -ge $Lines.Count -or $Lines[$FenceOpenIndex] -notmatch '^```\S*\s*$') {
            throw (
                "k8-test marker '$Id' at $Path`:$MarkerLine is not " +
                'immediately followed by an opening fenced code block ' +
                "(``` line). Marker and fence must be adjacent."
            )
        }

        $CodeLines =
            [System.Collections.Generic.List[string]]::new()

        $j = $FenceOpenIndex + 1
        $Closed = $false

        while ($j -lt $Lines.Count) {
            if ($Lines[$j] -match '^```\s*$') {
                $Closed = $true
                break
            }
            $CodeLines.Add($Lines[$j])
            $j++
        }

        if (-not $Closed) {
            throw "k8-test marker '$Id' at $Path`:$MarkerLine has no closing \`\`\` fence."
        }

        $Blocks.Add(
            [pscustomobject]@{
                Id         = $Id
                Mode       = $Mode
                Cwd        = $Cwd
                Code       = ($CodeLines -join "`n")
                LineNumber = $MarkerLine
            }
        )

        $i = $j
    }

    return $Blocks
}

function Get-K8ReadmeBlockById {
    param(
        [Parameter(Mandatory)] $Blocks,
        [Parameter(Mandatory)] [string] $Id
    )

    $Found =
        $Blocks | Where-Object { $_.Id -eq $Id }

    if (-not $Found) {
        throw "No k8-test block with id '$Id' found."
    }

    return $Found
}

Export-ModuleMember -Function @(
    'Get-K8ReadmeBlocks',
    'Get-K8ReadmeBlockById'
)
