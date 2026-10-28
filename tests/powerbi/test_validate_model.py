"""The dashboard quality gate passes and catches the mistakes it is meant to catch."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

if importlib.util.find_spec("pythonnet") is None or importlib.util.find_spec("sempy") is None:
    pytest.skip("needs pythonnet and the TOM assemblies (semantic-link-sempy)", allow_module_level=True)

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import validate_model  # noqa: E402


@pytest.fixture(scope="module")
def model():
    return validate_model.load_model()


def failed_rules(model) -> set[str]:
    return {r.rule for r in validate_model.model_rules(model) if not r.passed}


def test_dashboard_passes_every_rule(model):
    failed = [r.rule for r in validate_model.model_rules(model) + validate_model.report_rules(model) if not r.passed]
    assert failed == []


def test_a_ratio_divided_with_a_slash_is_caught(model):
    # "/" returns an error when the earned premium of a filter is zero; DIVIDE returns blank
    measure = model.Tables.Find("Claim Movements").Measures.Find("Loss Ratio")
    original = measure.Expression
    measure.Expression = "[Incurred Claims] / [Earned Premium]"
    try:
        assert "Measures divide with DIVIDE (no division by zero errors)" in failed_rules(model)
    finally:
        measure.Expression = original


def test_a_fact_without_the_calendar_is_caught(model):
    # without the relationship, the year filter would not filter the claims and "last year" would be blank
    relationship = next(r for r in model.Relationships if r.FromTable.Name == "Claims" and r.ToTable.Name == "Date")
    relationship.IsActive = False
    try:
        assert "Every fact table is filtered by the calendar" in failed_rules(model)
    finally:
        relationship.IsActive = True
