"""Targeted regression for preflight.compose_build_contexts()'s AMEND-005
published-image path.

Covers exactly the defect found by formal K8-3 attempt k8-repro-20260917-001:
the check assumed a generated Range A/B Compose file always declares a local
build context, and failed closed before Range A provisioning when AMEND-005's
--image-override/--no-build path leaves zero build contexts by design. See
Kakuriyo commit that lands this fix for the full account.
"""
import tempfile
import unittest
from pathlib import Path

import sys
ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT))
from study01 import preflight
from study01.preflight import AMEND_005_IMAGE_OVERRIDES


def _write(d, services_yaml):
    """Compose is written one level below `d`, matching the real generator's
    `../protocol-images/<name>` build-context convention (section 2.1)."""
    workspace = Path(d) / "manifests"
    workspace.mkdir(exist_ok=True)
    compose = workspace / "compose.yml"
    compose.write_text("networks:\n  cc_lan:\n    driver: bridge\nservices:\n" + services_yaml, encoding="utf-8")
    return compose


def _amend005_services_yaml(overrides=None):
    """A minimal but real-shaped services: block: every AMEND-005 service is
    image-only (no build), plus one unrelated third-party service using a
    floating tag, matching what an actual --image-override/--no-build
    generation produces."""
    merged = dict(AMEND_005_IMAGE_OVERRIDES)
    if overrides:
        merged.update(overrides)
    lines = []
    for name, image in merged.items():
        lines.append(f"  {name}:\n    image: {image}\n    restart: unless-stopped\n")
    lines.append("  log_sink:\n    image: timberio/vector:0.46.0-alpine\n")
    return "".join(lines)


class ComposeBuildContextsAmend005(unittest.TestCase):
    def test_historical_build_context_path_still_passes(self):
        """Old behaviour, unchanged: a real local build context resolves and passes."""
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "protocol-images" / "dnp3").mkdir(parents=True)
            compose = _write(d, "  cc_scada_master:\n    build:\n      context: ../protocol-images/dnp3\n")
            check = preflight.compose_build_contexts(compose)
            self.assertTrue(check.ok, check.detail)

    def test_historical_build_context_path_still_fails_when_unresolved(self):
        """Old behaviour, unchanged: an unresolved local build context still fails."""
        with tempfile.TemporaryDirectory() as d:
            compose = _write(d, "  cc_scada_master:\n    build:\n      context: ../protocol-images/does-not-exist\n")
            check = preflight.compose_build_contexts(compose)
            self.assertFalse(check.ok)

    def test_amend005_all_13_exact_digest_no_build_passes(self):
        """The exact shape k8-repro-20260917-001 hit: 0 build contexts, all 13
        AMEND-005 services image-overridden to their accepted digest."""
        with tempfile.TemporaryDirectory() as d:
            compose = _write(d, _amend005_services_yaml())
            check = preflight.compose_build_contexts(compose)
            self.assertTrue(check.ok, check.detail)

    def test_amend005_one_service_wrong_digest_fails_closed(self):
        with tempfile.TemporaryDirectory() as d:
            bad = {"wan_router": "ghcr.io/schutzz/amenonuboco-network-tools@sha256:" + "0" * 64}
            compose = _write(d, _amend005_services_yaml(overrides=bad))
            check = preflight.compose_build_contexts(compose)
            self.assertFalse(check.ok)
            self.assertIn("wan_router", check.detail)

    def test_amend005_one_service_still_building_fails_closed(self):
        with tempfile.TemporaryDirectory() as d:
            merged = dict(AMEND_005_IMAGE_OVERRIDES)
            del merged["wan_router"]
            lines = [f"  wan_router:\n    build:\n      context: ../protocol-images/network-tools\n"]
            for name, image in merged.items():
                lines.append(f"  {name}:\n    image: {image}\n")
            compose = _write(d, "".join(lines))
            check = preflight.compose_build_contexts(compose)
            self.assertFalse(check.ok)
            self.assertIn("wan_router", check.detail)

    def test_amend005_missing_service_fails_closed(self):
        """A service absent entirely (e.g. a truncated file) must not pass."""
        with tempfile.TemporaryDirectory() as d:
            merged = dict(AMEND_005_IMAGE_OVERRIDES)
            del merged["cc_ups"]
            lines = [f"  {name}:\n    image: {image}\n" for name, image in merged.items()]
            compose = _write(d, "".join(lines))
            check = preflight.compose_build_contexts(compose)
            self.assertFalse(check.ok)
            self.assertIn("cc_ups", check.detail)

    def test_third_party_image_not_required_to_be_digest_pinned(self):
        """Unrelated third-party images (vector, elasticsearch, python, grafana,
        ...) must not gain a new digest-pin requirement from this fix."""
        with tempfile.TemporaryDirectory() as d:
            compose = _write(d, _amend005_services_yaml())
            text = compose.read_text(encoding="utf-8")
            self.assertIn("timberio/vector:0.46.0-alpine", text)
            check = preflight.compose_build_contexts(compose)
            self.assertTrue(check.ok, check.detail)


if __name__ == "__main__":
    unittest.main()
