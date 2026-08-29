#Requires -Version 7.0
<#
    Minimal docker mock for behavioral testing of the application-readiness
    gates (Wait-K8ElasticsearchReady / Wait-K8LogStructurerReady /
    Wait-K8ZoneDetectorReady) without a real Docker daemon or VM.

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

if ($joined -match '\bexec\b') {
    if ($joined -match '\bcurl\b') {
        switch ($env:K8_MOCK_DOCKER_STATE) {
            'es-ready-yellow' { Write-Output '{"status":"yellow"}'; Write-Output 'K8_HTTP_STATUS:200'; exit 0 }
            'es-ready-green'  { Write-Output '{"status":"green"}'; Write-Output 'K8_HTTP_STATUS:200'; exit 0 }
            'es-red'          { Write-Output '{"status":"red"}'; Write-Output 'K8_HTTP_STATUS:200'; exit 0 }
            'es-http-200-no-body-status' { Write-Output '{}'; Write-Output 'K8_HTTP_STATUS:200'; exit 0 }
            'es-down'         { exit 7 }
            default           { exit 7 }
        }
    }
    # /proc probe (tr/printf loop) for structurer/detector process checks.
    switch ($env:K8_MOCK_DOCKER_STATE) {
        'structurer-installing' { Write-Output 'apt-get install -y -qq tshark python3'; exit 0 }
        'structurer-ready'      { Write-Output 'tshark -i eth0 -T ek -Y dnp3 -l '; Write-Output 'python3 /app/bulk_loader.py --index ot-logs-dnp3-* --es-url http://elasticsearch:9200'; exit 0 }
        'structurer-tshark-only' { Write-Output 'tshark -i eth0 -T ek -Y dnp3 -l '; exit 0 }
        'detector-installing'   { Write-Output 'pip install --quiet requests'; exit 0 }
        'detector-ready'        { Write-Output 'python3 /app/plugins/signal-1-zone-violation.py'; exit 0 }
        default                 { exit 0 }
    }
}

exit 1
