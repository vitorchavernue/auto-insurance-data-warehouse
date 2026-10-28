"""The synthetic legacy data: deterministic, consistent, and with the planted defects in place."""

from __future__ import annotations

from collections import Counter
from datetime import date, datetime

import pytest

from insurance_dw import seed

SCALE = 0.1  # 1,500 customers: enough to exercise every rule, fast enough for unit tests


@pytest.fixture(scope="module")
def world():
    return seed.generate(scale=SCALE)


@pytest.fixture(scope="module")
def first(world):
    return seed.snapshot(world, seed.FIRST_LOAD)


def test_generation_is_deterministic(world, first):
    again = seed.snapshot(seed.generate(scale=SCALE), seed.FIRST_LOAD)
    assert again == first


def test_generated_cpfs_have_valid_check_digits():
    import random

    rng = random.Random(1)
    for _ in range(200):
        cpf = seed.new_cpf(rng)
        assert cpf[9:] == seed.cpf_check_digits(cpf[:9])


def test_known_cpf_check_digits():
    assert seed.cpf_check_digits("529982247") == "25"


def test_snapshot_only_holds_what_already_happened(first):
    cut = datetime(2026, 9, 30, 23, 59, 59)
    for table, rows in first.items():
        changed_at = seed.TABLES[table].index("DtAlteracao")
        assert all(row[changed_at] <= cut for row in rows), table


def test_every_row_matches_the_table_columns(first):
    for table, rows in first.items():
        assert all(len(row) == len(seed.TABLES[table]) for row in rows), table


def test_policies_are_annual_and_coverages_belong_to_a_policy(first):
    policies = {row[0]: row for row in first["Apolice"]}
    for row in policies.values():
        start, end = row[6].date(), row[7].date()
        assert end == seed.one_year_after(start)
        if row[8]:
            assert start < row[8].date() < end  # cancellation inside the term
    assert all(row[0] in policies for row in first["ApoliceCobertura"])


def test_claim_movements_balance_the_reserve_of_closed_claims(world):
    for claim in world.claims:
        reserve = sum(m["amount"] for m in claim["movements"] if m["type"] in ("AVI", "AJU"))
        assert reserve == 0  # every claim in the timeline ends closed: denied, recovered or paid


def test_planted_defects_are_present(world, first):
    typed_categories = Counter(row[7] for row in first["Veiculo"])
    assert len(typed_categories) > 4  # several spellings of the same category
    assert any(row[3] == 0 for row in first["ApoliceCobertura"])  # premium typed as zero
    assert any(row[3] in ("00/00/0000", None) for row in first["Segurado"])  # birth date placeholder
    assert any(c["typed_policy"] for c in world.claims)  # claim with a policy number that does not exist
    assert world.orphan_movements  # payments for a claim number that does not exist


def test_one_month_of_activity(world):
    changed = seed.changes(world, seed.FIRST_LOAD, seed.MONTH_LATER)
    assert changed["Apolice"] and changed["Sinistro"] and changed["SinistroMovimento"]
    october = date(2026, 10, 1)
    moved = [c for c in world.customers if c["move"]]
    assert moved and all(c["move"]["at"].date() >= october for c in moved)
    # nothing in the month of activity happened after the end of October
    for table, rows in changed.items():
        changed_at = seed.TABLES[table].index("DtAlteracao")
        assert all(row[changed_at] <= datetime(2026, 10, 31, 23, 59, 59) for row in rows), table
