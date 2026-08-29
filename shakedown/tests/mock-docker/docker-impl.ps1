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

if ($joined -match '\bcompose\b.*\bconfig\b.*--services') {
    # docker compose -p <id> -f <file> config --services -- the expected
    # service set Wait-K8ComposeReady/Write-K8ImageInventory compare against.
    switch ($env:K8_MOCK_DOCKER_STATE) {
        { $_ -in @('readiness-e2e-ready-with-stderr-warning', 'readiness-e2e-not-ready-missing-forever', 'readiness-e2e-malformed-json-forever') } {
            Write-Output 'svcA'; Write-Output 'svcB'; Write-Output 'svcC'; exit 0
        }
        # Faithful reproduction of the real VM false negative
        # (k8shakedown-rangea-20260829-071142): 21 real services, all
        # running, exactly the 2 declared healthchecks healthy.
        'readiness-21-services-pass' { 1..21 | ForEach-Object { Write-Output "svc$_" }; exit 0 }
        default { Write-Output 'svc1'; exit 0 }
    }
}

if ($joined -match '\bcompose\b.*\bconfig\b.*--format.*json') {
    # docker compose -p <id> -f <file> config --format json -- the fully
    # resolved compose document (a single JSON object, never NDJSON),
    # queried by the network pool-conflict preflight for THIS run's own
    # declared subnet(s). Never a hardcoded assumption about the subnet.
    switch ($env:K8_MOCK_DOCKER_STATE) {
        { $_ -in @('preflight-conflict', 'preflight-clear') } {
            Write-Output '{"name":"k8shakedown-rangea-20260829-999999","networks":{"ot_net":{"name":"ot_net","driver":"bridge","ipam":{"config":[{"subnet":"10.1.0.0/16"}]}}}}'
            exit 0
        }
        'preflight-no-subnet-declared' {
            Write-Output '{"name":"k8shakedown-rangea-20260829-999999","networks":{"ot_net":{"name":"ot_net","driver":"bridge"}}}'
            exit 0
        }
        default { Write-Output '{"name":"mock","networks":{}}'; exit 0 }
    }
}

if ($joined -match '\bnetwork\b.*\bls\b') {
    # docker network ls --format json -- candidate leftover Shakedown
    # networks for the pool-conflict preflight.
    switch ($env:K8_MOCK_DOCKER_STATE) {
        'preflight-conflict' { Write-Output '{"Name":"k8shakedown-rangea-20260801-001_default","ID":"abc123","Driver":"bridge","Scope":"local"}'; exit 0 }
        'preflight-clear'    { Write-Output '{"Name":"k8shakedown-rangea-20260801-001_default","ID":"abc123","Driver":"bridge","Scope":"local"}'; exit 0 }
        default { exit 0 }
    }
}

if ($joined -match '\bnetwork\b.*\binspect\b') {
    # docker network inspect <name> --format json -- always a JSON array,
    # even for one network; used to read the leftover network's ACTUAL
    # subnet, never assumed from its name.
    switch ($env:K8_MOCK_DOCKER_STATE) {
        'preflight-conflict' { Write-Output '[{"Name":"k8shakedown-rangea-20260801-001_default","IPAM":{"Config":[{"Subnet":"10.1.20.0/24"}]}}]'; exit 0 }
        'preflight-clear'    { Write-Output '[{"Name":"k8shakedown-rangea-20260801-001_default","IPAM":{"Config":[{"Subnet":"10.9.0.0/16"}]}}]'; exit 0 }
        default { Write-Output '[{"Name":"unknown","IPAM":{"Config":[]}}]'; exit 0 }
    }
}

if ($joined -match '\bcompose\b.*\bps\b.*--all.*--format.*json') {
    # docker compose -p <id> -f <file> ps --all --format json -- the
    # readiness poll. Root-cause reproduction states for the real VM false
    # negative (k8shakedown-rangea-20260829-071142): a stray Compose stderr
    # warning must never contaminate the parse (already fixed by stream
    # separation), and the ONLY thing that should ever block PASS is a
    # genuine missing/not-running/unhealthy service or truly malformed JSON
    # -- never a parser artifact.
    switch ($env:K8_MOCK_DOCKER_STATE) {
        'readiness-e2e-ready-with-stderr-warning' {
            [Console]::Error.WriteLine('time="2026-08-29T07:11:42Z" level=warning msg="the attribute `version` is obsolete"')
            Write-Output '{"Service":"svcA","State":"running","Health":""}'
            Write-Output '{"Service":"svcB","State":"running","Health":""}'
            Write-Output '{"Service":"svcC","State":"running","Health":""}'
            exit 0
        }
        'readiness-e2e-not-ready-missing-forever' {
            # svcC never shows up -- a genuine, persistent missing service.
            Write-Output '{"Service":"svcA","State":"running","Health":""}'
            Write-Output '{"Service":"svcB","State":"running","Health":""}'
            exit 0
        }
        'readiness-e2e-malformed-json-forever' {
            # Truncated/unbalanced JSON, persistently -- must fail-closed
            # with a parse diagnostic, never silently retried into a false
            # "not ready" with no trace of why.
            Write-Output '{"Service":"svcA","State":"running"'
            exit 0
        }
        'readiness-21-services-pass' {
            # 21 compact NDJSON rows, all State=running; only svc1/svc2
            # declare a healthcheck and both report Health=healthy; the rest
            # omit Health entirely (real Compose behavior for a service with
            # no configured healthcheck) -- must still PASS on State alone.
            for ($n = 1; $n -le 21; $n++) {
                if ($n -le 2) { Write-Output "{`"Service`":`"svc$n`",`"State`":`"running`",`"Health`":`"healthy`"}" }
                else { Write-Output "{`"Service`":`"svc$n`",`"State`":`"running`"}" }
            }
            exit 0
        }
        default { Write-Output '{"Service":"svc1","State":"running","Health":""}'; exit 0 }
    }
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
    # Invoke-K8ElasticsearchRequest's real shape: `curl -o <path> -w
    # '%{http_code}' ...` (status only on stdout, body written to a file),
    # followed by a SEPARATE `cat <path>` to read the body back. Faithfully
    # mocked end to end (never exercised behaviorally before this round,
    # which is exactly the class of untested-code-path gap this whole
    # Shakedown effort exists to close): the "container" file is a real
    # local file under a fake-fs directory, keyed by the exact temp path
    # curl/cat both reference, so `-o` "writing" and the later `cat`
    # "reading" round-trip correctly regardless of call order.
    $fakeFsDir = Join-Path $env:TEMP 'k8-mock-fake-fs'
    if ($joined -match '\bcurl\b' -and $joined -match '\s-o\s+(\S+)') {
        $remotePath = $Matches[1]
        $localPath = Join-Path $fakeFsDir (Split-Path $remotePath -Leaf)
        New-Item -ItemType Directory -Force -Path $fakeFsDir | Out-Null
        $isRuleMapping = $joined -match 'ot-signals-zone-violation.*_mapping'
        $isCollectorMapping = (-not $isRuleMapping) -and $joined -match 'ot-logs-dnp3.*_mapping'
        $isRuleSearch = $joined -match 'ot-signals-zone-violation.*_search'
        $isCollectorSearch = (-not $isRuleSearch) -and $joined -match 'ot-logs-dnp3.*_search'
        $body = switch ($env:K8_MOCK_DOCKER_STATE) {
            { $isRuleMapping -and $_ -in @('rule-index-absent', 'rangeb-fresh-no-alert') } { '{}' }
            { $isRuleMapping -and $_ -eq 'rule-index-present-good' } { '{"ot-signals-zone-violation-2026.08.29":{"mappings":{"properties":{"signal":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"src_ip":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"dst_ip":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"source_dnp3_doc_id":{"type":"text","fields":{"keyword":{"type":"keyword"}}}}}}}' }
            { $isRuleMapping -and $_ -eq 'rule-index-present-bad-mapping' } { '{"ot-signals-zone-violation-2026.08.29":{"mappings":{"properties":{"signal":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"src_ip":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"dst_ip":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"source_dnp3_doc_id":{"type":"text"}}}}}' }
            { $isCollectorMapping -and $_ -in @('rule-index-absent', 'rule-index-present-good', 'rule-index-present-bad-mapping', 'rangeb-fresh-no-alert') } {
                '{"ot-logs-dnp3-2026.08.29":{"mappings":{"properties":{"layers":{"properties":{"frame":{"properties":{"frame_frame_time":{"type":"date"}}},"ip":{"properties":{"ip_ip_src":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"ip_ip_dst":{"type":"text","fields":{"keyword":{"type":"keyword"}}}}},"tcp":{"properties":{"tcp_tcp_srcport":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"tcp_tcp_dstport":{"type":"text","fields":{"keyword":{"type":"keyword"}}}}},"dnp3":{"properties":{"dnp3_dnp3_al_func":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"dnp3_dnp3_src":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"dnp3_dnp3_dst":{"type":"text","fields":{"keyword":{"type":"keyword"}}}}}}}}}}}'
            }
            { $isCollectorSearch -and $_ -in @('rule-index-absent', 'rule-index-present-good', 'rangeb-fresh-no-alert') } {
                '{"hits":{"total":{"value":2,"relation":"eq"},"hits":[{"_id":"collector-hit-1","_source":{}},{"_id":"collector-hit-2","_source":{}}]}}'
            }
            { ($isRuleSearch -and $_ -in @('rule-index-absent', 'rangeb-fresh-no-alert')) } { '{"hits":{"total":{"value":0,"relation":"eq"},"hits":[]}}' }
            { $isRuleSearch -and $_ -eq 'rule-index-present-good' } {
                '{"hits":{"total":{"value":1,"relation":"eq"},"hits":[{"_id":"rule-hit-1","_source":{"signal":"signal-1-zone-violation","src_ip":"10.1.20.11","dst_ip":"10.1.10.10","source_dnp3_doc_id":"collector-hit-1"}}]}}'
            }
            default { '{}' }
        }
        $body | Set-Content -Path $localPath -Encoding utf8NoBOM -NoNewline
        Write-Output '200'
        exit 0
    }
    if ($joined -match '^exec\s+\S+\s+cat\s+(\S+)') {
        $remotePath = $Matches[1]
        $localPath = Join-Path $fakeFsDir (Split-Path $remotePath -Leaf)
        if (Test-Path $localPath) { Get-Content $localPath -Raw }
        exit 0
    }
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
    if ($joined -match '\bcurl\b' -and $joined -match 'ot-signals-zone-violation.*_mapping') {
        # Rule index-mapping retention: real VM reproduction states for the
        # k8shakedown-rangeb-20260829-111026 STOP (rule-mapping-gate:
        # "mapping response contains no indices"). The Rule alert index is
        # created lazily on zone_violation.py's first alert write, so a
        # genuinely negative Range B run legitimately has NO index yet --
        # ES returns HTTP 200 with an empty `{}` body for a wildcard
        # pattern matching zero concrete indices, not an error.
        switch ($env:K8_MOCK_DOCKER_STATE) {
            { $_ -in @('rule-index-absent', 'rangeb-fresh-no-alert') } { Write-Output '{}'; Write-Output 'K8_HTTP_STATUS:200'; exit 0 }
            'rule-index-present-good' {
                Write-Output '{"ot-signals-zone-violation-2026.08.29":{"mappings":{"properties":{"signal":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"src_ip":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"dst_ip":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"source_dnp3_doc_id":{"type":"text","fields":{"keyword":{"type":"keyword"}}}}}}}'
                Write-Output 'K8_HTTP_STATUS:200'
                exit 0
            }
            'rule-index-present-bad-mapping' {
                Write-Output '{"ot-signals-zone-violation-2026.08.29":{"mappings":{"properties":{"signal":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"src_ip":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"dst_ip":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"source_dnp3_doc_id":{"type":"text"}}}}}'
                Write-Output 'K8_HTTP_STATUS:200'
                exit 0
            }
            default { Write-Output '{}'; Write-Output 'K8_HTTP_STATUS:200'; exit 0 }
        }
    }
    if ($joined -match '\bcurl\b' -and $joined -match '_mapping') {
        # Collector index-mapping retention (README SS5.1 step 6). Always
        # populated for these states: ot-logs-dnp3-* is populated
        # continuously by all structured traffic, guaranteed present by
        # the pre-T0 functional-readiness canary -- unaffected by the
        # Rule-index lazy-creation defect class above.
        switch ($env:K8_MOCK_DOCKER_STATE) {
            'mapping-transport-error' { exit 7 }
            { $_ -in @('rule-index-absent', 'rule-index-present-good', 'rule-index-present-bad-mapping', 'rangeb-fresh-no-alert') } {
                Write-Output '{"ot-logs-dnp3-2026.08.29":{"mappings":{"properties":{"layers":{"properties":{"frame":{"properties":{"frame_frame_time":{"type":"date"}}},"ip":{"properties":{"ip_ip_src":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"ip_ip_dst":{"type":"text","fields":{"keyword":{"type":"keyword"}}}}},"tcp":{"properties":{"tcp_tcp_srcport":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"tcp_tcp_dstport":{"type":"text","fields":{"keyword":{"type":"keyword"}}}}},"dnp3":{"properties":{"dnp3_dnp3_al_func":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"dnp3_dnp3_src":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"dnp3_dnp3_dst":{"type":"text","fields":{"keyword":{"type":"keyword"}}}}}}}}}}}'
                Write-Output 'K8_HTTP_STATUS:200'
                exit 0
            }
            default { Write-Output '{"index":{"mappings":{"properties":{}}}}'; Write-Output 'K8_HTTP_STATUS:200'; exit 0 }
        }
    }
    if ($joined -match '\btshark\b' -and $joined -match '\s-r\s') {
        # Real target-capture decode (Write-K8TargetCaptureDecode /
        # Write-K8UnrelatedPcapRows), distinct from the /proc-probe strings
        # below which merely contain the word "tshark" as canned output text.
        switch ($env:K8_MOCK_DOCKER_STATE) {
            { $_ -in @('decode-hit', 'rule-index-absent', 'rule-index-present-good', 'rule-index-present-bad-mapping', 'rangeb-fresh-no-alert') } {
                # For the rule-index-* states this is only R-OBS-05's own
                # unrelated-flow decode (a separate, already-covered gate);
                # it is not part of the Rule-index lazy-creation scenario
                # under test, so any valid single hit keeps it out of the
                # way.
                Write-Output "1`t1767225615.0`t10.1.20.11`t10.1.10.10`t54321`t20000`t5`t1024`t1"; exit 0
            }
            'decode-empty' { exit 0 }
            'decode-transport-error' { exit 2 }
            # Multiple hits, real TAB-separated (0x09) rows -- as tshark
            # actually emits with the correct `-E separator=/t` argument
            # (k8shakedown-rangea-20260829-081151: the module was previously
            # passing `separator=\t`, a PowerShell/C-style escape that is
            # NOT tshark's own CLI syntax, and produced a backslash-
            # delimited row instead of a real tab-delimited one).
            'decode-multi-hit' {
                Write-Output "4`t1787991349.810780000`t10.1.20.11`t10.1.10.10`t58852`t20000`t5`t1024`t1"
                Write-Output "7`t1787991350.221340000`t10.1.20.11`t10.1.10.10`t58852`t20000`t5`t1024`t1"
                Write-Output "9`t1787991351.005120000`t10.1.20.11`t10.1.10.10`t58852`t20000`t5`t1024`t1"
                exit 0
            }
            # A row with the WRONG column count (8 fields, one dropped) --
            # must fail-closed, never silently accepted.
            'decode-bad-column-count' { Write-Output "4`t1787991349.810780000`t10.1.20.11`t10.1.10.10`t58852`t20000`t5`t1024"; exit 0 }
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
    if ($joined -match '\bip\b.*-o.*-4.*addr.*show') {
        # Resolve-K8GatewayInterface's `ip -o -4 addr show [dev <name>]` --
        # real VM false-negative reproduction states for the Range B
        # "Cannot find device \"UP\"" defect (k8shakedown-rangea-
        # 20260829-... , commit 5a70273 STOP). Realistic oneline-format
        # rows: `<idx>: <ifname>[@peer]    inet <addr>/<prefix> ...`.
        $loRow   = '1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever preferred_lft forever'
        $gwRow   = '6: eth6@if5890    inet 10.1.20.254/24 brd 10.1.20.255 scope global eth6\       valid_lft forever preferred_lft forever'
        $otherRow = '7: eth7@if5892    inet 172.19.0.5/16 brd 172.19.255.255 scope global eth7\       valid_lft forever preferred_lft forever'
        $dupGwRow = '8: eth8@if5894    inet 10.1.20.254/24 brd 10.1.20.255 scope global eth8\       valid_lft forever preferred_lft forever'
        $isDevQuery = $joined -match '\bdev\b'
        switch ($env:K8_MOCK_DOCKER_STATE) {
            'gateway-resolve-ok' {
                if ($isDevQuery) {
                    # Independent re-verification query for the resolved
                    # 'eth6' -- must show the SAME row confirming the CIDR.
                    if ($joined -match '\beth6\b') { Write-Output $gwRow } else { Write-Output $otherRow }
                }
                else { Write-Output $loRow; Write-Output $gwRow; Write-Output $otherRow }
                exit 0
            }
            'gateway-resolve-zero-match' {
                if (-not $isDevQuery) { Write-Output $loRow; Write-Output $otherRow }
                exit 0
            }
            'gateway-resolve-multi-match' {
                if (-not $isDevQuery) { Write-Output $loRow; Write-Output $gwRow; Write-Output $dupGwRow }
                exit 0
            }
            'gateway-resolve-exit-nonzero' {
                [Console]::Error.WriteLine('ip: command failed')
                exit 1
            }
            'gateway-resolve-stderr-noise' {
                [Console]::Error.WriteLine('net_ns: warning: nonstandard namespace label')
                if ($isDevQuery) { Write-Output $gwRow } else { Write-Output $loRow; Write-Output $gwRow; Write-Output $otherRow }
                exit 0
            }
            'gateway-resolve-state-token-regression' {
                # Contrived: simulates the EXACT original defect symptom
                # (a state token landing in the position an interface name
                # would be) even if some future edit reintroduces a wrong
                # command/column choice -- the denylist must catch this
                # independent of the structural `ip -o -4 addr show` fix.
                if (-not $isDevQuery) { Write-Output '6: UP    inet 10.1.20.254/24 brd 10.1.20.255 scope global UP\       valid_lft forever preferred_lft forever' }
                exit 0
            }
            'gateway-resolve-verify-fails' {
                # The initial scan finds a plausible match, but the
                # independent re-verification query for that SAME name
                # comes back empty -- must fail-closed anyway, never trust
                # the first pass alone.
                if ($isDevQuery) { exit 0 } else { Write-Output $loRow; Write-Output $gwRow; Write-Output $otherRow }
                exit 0
            }
            default { exit 0 }
        }
    }
    if ($joined -match '\btc\b.*\bfilter\b.*\bshow\b') {
        # Assert-K8UnrelatedMirrorFilter's per-interface tc filter query.
        switch ($env:K8_MOCK_DOCKER_STATE) {
            'gateway-resolve-ok' {
                if ($joined -match '\beth7\b') {
                    Write-Output 'filter parent ffff: protocol all pref 1 u32 action mirred (Egress Mirror to device eth5)'
                }
                exit 0
            }
            default { exit 0 }
        }
    }
    if ($joined -match '\bip\b.*-o.*\blink\b.*\bshow\b') {
        # Assert-K8UnrelatedMirrorFilter's interface enumeration.
        switch ($env:K8_MOCK_DOCKER_STATE) {
            'gateway-resolve-ok' {
                Write-Output '1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000'
                Write-Output '6: eth6@if5890: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default'
                Write-Output '7: eth7@if5892: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default'
                exit 0
            }
            default { exit 0 }
        }
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
