#Requires -Version 7.0
<#
    Minimal docker mock for behavioral testing of the application-readiness
    gates (Wait-K8ElasticsearchReady / Wait-K8LogStructurerReady /
    Wait-K8ZoneDetectorReady / Get-K8Dnp3OperationalCanaryHits) without a
    real Docker daemon or VM.

    Controlled entirely by $env:K8_MOCK_DOCKER_STATE. Matches only on
    whether the joined argv contains a marker substring, not exact
    positional argv shape, so it stays robust to minor argument-order
    changes in the functions under test.

    Deliberately named docker-impl.ps1, NOT docker.ps1: PowerShell's command
    resolution prefers a same-directory .ps1 "Script" over a .cmd/.exe
    "Application" for a bare command name, regardless of PATH order. If this
    file were named docker.ps1, `& docker ...` would resolve straight to it
    and run it IN-PROCESS -- and [Console]::Error.WriteLine from an in-process
    script bypasses a caller's native-command `2>$file` stderr redirection
    entirely (that redirection only captures a real OS-level stderr handle,
    which only exists for a genuine child process). That would make this
    mock silently fail to reproduce real docker.exe's stderr behavior
    (confirmed by direct A/B testing: identical script, invoked as
    docker.cmd -> real external process -> `2>$file` captures correctly;
    invoked directly as docker.ps1 -> in-process -> `2>$file` captures
    nothing). Only docker.cmd may be resolved as "docker"; it always launches
    this file as a genuinely separate pwsh.exe process via the OS.
#>
$joined = ($args -join ' ')

if ($joined -match '\bcompose\b.*\bps\b.*-q') {
    # docker compose -p <id> -f <file> ps -q <service> -- return a fake container id.
    Write-Output 'mock-container-id'
    exit 0
}

if ($joined -match '^cp\b') {
    # docker cp <local> <container>:<remote> -- pcap-into-log_structurer copy.
    exit 0
}

if ($joined -match '^logs\b') {
    # docker logs --tail N <container> -- zone_detector recent-stderr best-effort check.
    switch ($env:K8_MOCK_DOCKER_STATE) {
        'detector-log-has-error' { Write-Output '[zone_violation] search failed: some error'; exit 0 }
        default { Write-Output '[zone_violation] starting, poll every 5s, allowed_sources=[]'; exit 0 }
    }
}

if ($joined -match '\bexec\b') {
    if ($joined -match '\bcurl\b' -and $joined -match '_cluster/health') {
        switch ($env:K8_MOCK_DOCKER_STATE) {
            'es-ready-yellow' { Write-Output '{"status":"yellow"}'; Write-Output 'K8_HTTP_STATUS:200'; exit 0 }
            'es-ready-green'  { Write-Output '{"status":"green"}'; Write-Output 'K8_HTTP_STATUS:200'; exit 0 }
            'es-red'          { Write-Output '{"status":"red"}'; Write-Output 'K8_HTTP_STATUS:200'; exit 0 }
            'es-http-200-no-body-status' { Write-Output '{}'; Write-Output 'K8_HTTP_STATUS:200'; exit 0 }
            'es-down'         { exit 7 }
            default           { exit 7 }
        }
    }
    if ($joined -match '\bcurl\b' -and $joined -match '_search') {
        # Operational-canary Collector-style query against ot-logs-dnp3-*.
        $presentHit = '{"hits":{"total":{"value":1},"hits":[{"_id":"canary1","_source":{"layers":{"ip":{"ip_ip_src":"10.1.10.10","ip_ip_dst":"10.1.40.10"},"dnp3":{"dnp3_dnp3_al_func":"5"}}}}]}}'
        $emptyHits   = '{"hits":{"total":{"value":0},"hits":[]}}'
        $targetHit   = '{"hits":{"total":{"value":1},"hits":[{"_id":"bad1","_source":{"layers":{"ip":{"ip_ip_src":"10.1.20.11","ip_ip_dst":"10.1.10.10"},"dnp3":{"dnp3_dnp3_al_func":"5"}}}}]}}'
        switch ($env:K8_MOCK_DOCKER_STATE) {
            { $_ -in @('canary-present', 'structurer-ready') } { Write-Output $presentHit; Write-Output 'K8_HTTP_STATUS:200'; exit 0 }
            'canary-absent'       { Write-Output $emptyHits;  Write-Output 'K8_HTTP_STATUS:200'; exit 0 }
            'canary-transport-error' { exit 7 }
            'canary-matches-target-selector' { Write-Output $targetHit; Write-Output 'K8_HTTP_STATUS:200'; exit 0 }
            default { Write-Output $emptyHits; Write-Output 'K8_HTTP_STATUS:200'; exit 0 }
        }
    }
    if ($joined -match '\bcurl\b' -and $joined -match '_mapping') {
        # Collector/Rule index-mapping retention (README SS5.1 step 6).
        switch ($env:K8_MOCK_DOCKER_STATE) {
            'mapping-transport-error' { exit 7 }
            default { Write-Output '{"index":{"mappings":{"properties":{}}}}'; Write-Output 'K8_HTTP_STATUS:200'; exit 0 }
        }
    }
    if ($joined -match '\btshark\b' -and $joined -match '\s-r\s') {
        # Real target-capture decode (Write-K8TargetCaptureDecode /
        # Write-K8UnrelatedPcapRows), distinct from the /proc-probe strings
        # below which merely contain the word "tshark" as canned output text.
        switch ($env:K8_MOCK_DOCKER_STATE) {
            'decode-hit'   { Write-Output "1`t1767225615.0`t10.1.20.11`t10.1.10.10`t54321`t20000`t5`t1024`t1"; exit 0 }
            'decode-empty' { exit 0 }
            'decode-transport-error' { exit 2 }
            # Reproduces the real VM failure verbatim: tshark's own "Running
            # as user root..." warning on STDERR, alongside a genuinely
            # valid TSV row on STDOUT -- exit 0 either way, exactly as the
            # real tool does (the warning is not a failure).
            'decode-hit-with-root-warning' {
                [Console]::Error.WriteLine('Running as user "root" and group "root". This could be dangerous.')
                Write-Output "1`t1767225615.0`t10.1.20.11`t10.1.10.10`t54321`t20000`t5`t1024`t1"
                exit 0
            }
            'decode-empty-with-root-warning' {
                [Console]::Error.WriteLine('Running as user "root" and group "root". This could be dangerous.')
                exit 0
            }
            # Regression case 3: an arbitrary/garbage stdout line ALONGSIDE a
            # real stderr error message, non-zero exit -- must fail-closed
            # (never treated as a parsed row) and the stderr text must reach
            # the caller's failure diagnostic, not be discarded.
            'decode-error-with-message' {
                Write-Output 'not-a-real-tsv-row'
                [Console]::Error.WriteLine('tshark: some transport error occurred')
                exit 1
            }
            default { exit 0 }
        }
    }
    if ($joined -match 'ES_URL') {
        # `sh -lc 'printf "%s" "${ES_URL:-http://elasticsearch:9200}"'`
        Write-Output 'http://elasticsearch:9200'
        exit 0
    }
    if ($joined -match '\bpython3\b' -and $joined -match 'ot-logs-dnp3.*_search|_search.*wildcard') {
        # zone_detector's own literal search, from inside its own container.
        switch ($env:K8_MOCK_DOCKER_STATE) {
            { $_ -in @('detector-search-ok', 'detector-connectivity-ok', 'detector-ready', 'detector-log-has-error') } { Write-Output '200'; exit 0 }
            'detector-search-400'             { Write-Output 'HTTPERROR:400'; exit 1 }
            'detector-search-transport-error' { Write-Output 'ERROR:Connection refused'; exit 1 }
            'detector-search-invalid-json'    { Write-Output 'ERROR:Expecting value: line 1 column 1 (char 0)'; exit 1 }
            default { Write-Output 'ERROR:Connection refused'; exit 1 }
        }
    }
    if ($joined -match '\bpython3\b' -and $joined -match 'urllib') {
        switch ($env:K8_MOCK_DOCKER_STATE) {
            { $_ -in @('detector-connectivity-ok', 'detector-ready', 'detector-log-has-error', 'detector-search-400', 'detector-search-transport-error', 'detector-search-invalid-json', 'detector-search-ok') } { Write-Output '200'; exit 0 }
            'detector-connectivity-fail' { Write-Output 'ERROR:Connection refused'; exit 1 }
            default { Write-Output 'ERROR:Connection refused'; exit 1 }
        }
    }
    # /proc probe (tr/printf loop) for structurer/detector process checks.
    switch ($env:K8_MOCK_DOCKER_STATE) {
        'structurer-installing' { Write-Output 'apt-get install -y -qq tshark python3'; exit 0 }
        { $_ -in @('structurer-ready', 'canary-present', 'canary-absent', 'canary-transport-error', 'canary-matches-target-selector') } {
            Write-Output 'tshark -i eth0 -T ek -Y dnp3 -l '
            Write-Output 'python3 /app/bulk_loader.py --index ot-logs-dnp3-* --es-url http://elasticsearch:9200'
            exit 0
        }
        'structurer-tshark-only' { Write-Output 'tshark -i eth0 -T ek -Y dnp3 -l '; exit 0 }
        'detector-installing'   { Write-Output 'pip install --quiet requests'; exit 0 }
        { $_ -in @('detector-ready', 'detector-connectivity-ok', 'detector-connectivity-fail', 'detector-log-has-error', 'detector-search-ok', 'detector-search-400', 'detector-search-transport-error', 'detector-search-invalid-json') } {
            Write-Output 'python3 /app/plugins/signal-1-zone-violation.py'
            exit 0
        }
        default { exit 0 }
    }
}

exit 1
