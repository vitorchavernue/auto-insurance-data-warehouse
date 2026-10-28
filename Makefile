PY ?= python
export PYTHONPATH := src

.PHONY: setup up down lint test test-integration demo clean

setup:
	$(PY) -m pip install -r requirements.txt

# SQL Server 2022 with SQL Server Agent in a container (password in .env)
up:
	docker compose up -d

down:
	docker compose down -v

# Python style + T-SQL syntax
lint:
	ruff check .
	ruff format --check .
	sqlfluff parse --dialect tsql sql > /dev/null

# Synthetic data rules, no database needed
test:
	$(PY) -m pytest -q tests/unit

# The whole life of the warehouse against the SQL Server
test-integration:
	$(PY) -m pytest -q tests/integration

# Deploy -> first load (30/09/2026) -> one month of business -> incremental load -> benchmark
demo:
	$(PY) -m insurance_dw demo
	@cat reports/latest.md reports/benchmark.md

clean:
	rm -rf reports .pytest_cache .ruff_cache
