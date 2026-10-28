# ADR 0003 — Customer address as slowly changing dimension type 2

**Status:** accepted

## Context

The legacy system keeps only the current address of a customer. Theft rates — the largest cost for motorcycles —
differ a lot between states and cities, so underwriting prices a policy by the address at the time of sale. When a
customer moves and the old address is overwritten, every past policy and claim "moves" with them, and the loss ratio
by region of previous years changes after the fact.

## Decision

- `dw.dim_customer` keeps a **new version** when the state or city changes (type 2), with `valid_from` (inclusive),
  `valid_to` (exclusive) and `is_current`.
- Name, CPF and birth date are **corrections** (type 1): every version is updated.
- Facts take the version valid on the **business date** of the event: the policy start for premium, the occurrence
  date for claims. When a customer moves, policies starting and claims happening after the move are refreshed to
  the new version; older ones keep the old address.
- A change on the same day the current version started overwrites it (no one-day versions).
- The first version is valid from 1900, so any past event finds a version. History therefore starts on the day the
  warehouse started: moves that happened before it are not in the legacy system and cannot be rebuilt.
- A critical data quality check verifies that every customer has exactly one current version and no gaps or
  overlaps between versions.

## Consequences

- Loss ratio by region is stable over time and reflects the risk that was priced.
- The dimension grows with each move (about 1.5% of customers per month in the synthetic data).
- Reports that need the current address use `is_current = 1`; reports by region use the key stored in the fact.
