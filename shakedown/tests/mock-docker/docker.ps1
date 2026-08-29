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
#>
$joined = ($args -join ' ')

if ($joined -match '\bcompose\b.*\bps\b.*-q') {
    # docker compose -p <id> -f <file> ps -q <service> -- return a fake container id.
    Write-Output 'mock-container-id'
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
