"""Elasticsearch access for the frozen Collector and Rule queries.

Transcribed, not redesigned, from shakedown/tools/K8ShakedownCommon.psm1's
`Invoke-K8ElasticsearchRequest` -- the already-qualified mechanism this module
promotes into the formal package (see
protocol/c2-dnp3-collector-rule-query-procedure.md). Every formal Range A/B
query reaches Elasticsearch the same way that implementation does: a `curl`
issued through `docker exec` into the run's own `elasticsearch` service,
against that container's own `localhost:9200` -- never a host-published port,
and never a second HTTP client library.

The response body is written to a temp file inside the container by curl's
own `-o`, read back with a separate `docker exec ... cat`, then removed, so a
transport failure and an HTTP status can never be confused with one another.
"""
import subprocess
import uuid


class ElasticsearchRequestError(RuntimeError):
    """The Elasticsearch container could not be resolved, or curl/cat failed."""


def compose_argv(run_id, compose, service):
    return ["docker", "compose", "-p", run_id, "-f", str(compose), "ps", "-q", service]


def resolve_container(run_id, compose, service="elasticsearch"):
    result = subprocess.run(compose_argv(run_id, compose, service),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    container = result.stdout.strip()
    if result.returncode != 0 or not container:
        raise ElasticsearchRequestError(
            f"{service} container could not be resolved (exit {result.returncode}): {result.stderr.strip()}"
        )
    return container


def request(container, method, endpoint, body=None):
    """POST/GET against http://localhost:9200/<endpoint> inside `container`."""
    remote_body = f"/tmp/k8-es-{uuid.uuid4().hex}.body"
    curl_argv = [
        "docker", "exec", container, "curl", "-sS", "-o", remote_body, "-w", "%{http_code}",
        "-X", method, f"http://localhost:9200/{endpoint}", "-H", "Content-Type: application/json",
    ]
    if body is not None:
        curl_argv += ["--data-binary", body]
    status_capture = subprocess.run(curl_argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    body_capture = subprocess.run(["docker", "exec", container, "cat", remote_body],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    subprocess.run(["docker", "exec", container, "rm", "-f", remote_body],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if status_capture.returncode != 0:
        raise ElasticsearchRequestError(
            f"curl {method} {endpoint} exited {status_capture.returncode}: {status_capture.stderr.strip()}"
        )
    if body_capture.returncode != 0:
        raise ElasticsearchRequestError(
            f"reading the Elasticsearch response body exited {body_capture.returncode}: {body_capture.stderr.strip()}"
        )
    return status_capture.stdout.strip(), body_capture.stdout
