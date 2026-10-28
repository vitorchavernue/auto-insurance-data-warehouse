"""Integration tests run against a real SQL Server (a throwaway container in CI).

They are skipped when no server is configured (MSSQL_PASSWORD not set), so the unit tests can
run anywhere.
"""

from __future__ import annotations

import os

import pytest

if not os.environ.get("MSSQL_PASSWORD"):
    pytest.skip("integration tests need a SQL Server (MSSQL_HOST / MSSQL_PASSWORD)", allow_module_level=True)

# A smaller portfolio than the demo keeps the suite quick; every rule is still exercised
SCALE = float(os.environ.get("INTEGRATION_SCALE", "0.3"))


@pytest.fixture(scope="session")
def scale() -> float:
    return SCALE


@pytest.fixture(scope="session")
def legacy_loaded(scale, tmp_path_factory):
    """Fresh databases with the legacy system as it is on the day of the first load."""
    from insurance_dw import deploy

    os.chdir(tmp_path_factory.mktemp("work"))  # run reports go to a temporary folder
    deploy.deploy()
    return deploy.load_legacy(scale)
