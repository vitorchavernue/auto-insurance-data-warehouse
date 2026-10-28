# ADR 0001 — ODS and star schema next to the legacy system

**Status:** accepted

## Context

Management reports ran directly on the policy administration database. The loss ratio report alone read about
5.8 million pages for one year, with scalar functions called for every row and a loop over the months. It competed
with the operation (issuing policies, recording claims) for the same server, and every report re-implemented the
business rules in its own way.

Options considered:

1. **Tune the legacy database** (indexes, rewriting the report). Helps one report, but the schema stays built for
   operation: text dates, hand-typed codes, no history of the customer address. Every new report repeats the cleaning.
2. **Read replica of the legacy database.** Removes the competition for the server, keeps every other problem.
3. **ODS + star schema in a separate database, loaded incrementally.** Chosen.

## Decision

- An **ODS** (`ods` schema) holds the legacy data cleaned, typed and validated, in its current state. It is where
  data problems are solved once: CPF repair and validation, date parsing, code mapping, rejection with a reason.
- A **star schema** (`dw` schema) is built from the ODS for analysis, with one fact table per kind of question:
  written premium (transaction), earned premium per closed month (periodic snapshot), claim lifecycle
  (accumulating snapshot) and claim movements (transaction).
- **Business views** (`mart`) hold the official definitions (loss ratio, renewal rate…), so every report and the
  Power BI model use the same numbers.
- The two large facts use **clustered columnstore** indexes: they are read by aggregations over few columns.

## Consequences

- The loss ratio report reads 9,489 pages instead of 5,769,007 and returns the same numbers.
- The warehouse is one night behind the operation (acceptable for management reporting; operational screens keep
  using the legacy system).
- Data problems become visible and owned: rejected records and flagged customers are reported every night to the
  teams that can fix them at the source.
