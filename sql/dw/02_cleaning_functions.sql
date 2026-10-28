/* =====================================================================================
   SeguroDW - cleaning functions
   -------------------------------------------------------------------------------------
   Written as inline table-valued functions (a single SELECT): SQL Server expands them
   into the calling query, so they run set-based over thousands of rows at once instead
   of once per row like the scalar functions of the legacy report.
   ===================================================================================== */

/* CPF (individual taxpayer number) as typed -> 11 digits + whether the check digits are valid.
   - punctuation and spaces are removed
   - a CPF stored as a number lost its leading zeros: they are put back
   - anything that is not 1 to 11 digits is treated as missing
   An invalid CPF is not a reason to drop a customer (the policy and the premium are real):
   the customer is loaded and flagged, and the list goes to the registration team. */
CREATE OR ALTER FUNCTION etl.fn_parse_cpf (@typed VARCHAR(20))
RETURNS TABLE
AS
RETURN
WITH digits AS (
    SELECT REPLACE(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(@typed, ''))), '.', ''), '-', ''), '/', ''), ' ', '') AS d
),
cpf AS (
    SELECT CASE
               WHEN d = '' OR d LIKE '%[^0-9]%' OR LEN(d) > 11 THEN NULL
               ELSE RIGHT('00000000000' + d, 11)
           END AS cpf
    FROM digits
),
remainders AS (
    -- Modulo 11 of the weighted sum of the digits (weights 10..2 for the first check digit, 11..2 for the second)
    SELECT cpf,
           (CAST(SUBSTRING(cpf, 1, 1) AS INT) * 10 + CAST(SUBSTRING(cpf, 2, 1) AS INT) * 9
          + CAST(SUBSTRING(cpf, 3, 1) AS INT) * 8 + CAST(SUBSTRING(cpf, 4, 1) AS INT) * 7
          + CAST(SUBSTRING(cpf, 5, 1) AS INT) * 6 + CAST(SUBSTRING(cpf, 6, 1) AS INT) * 5
          + CAST(SUBSTRING(cpf, 7, 1) AS INT) * 4 + CAST(SUBSTRING(cpf, 8, 1) AS INT) * 3
          + CAST(SUBSTRING(cpf, 9, 1) AS INT) * 2) % 11 AS r1,
           (CAST(SUBSTRING(cpf, 1, 1) AS INT) * 11 + CAST(SUBSTRING(cpf, 2, 1) AS INT) * 10
          + CAST(SUBSTRING(cpf, 3, 1) AS INT) * 9 + CAST(SUBSTRING(cpf, 4, 1) AS INT) * 8
          + CAST(SUBSTRING(cpf, 5, 1) AS INT) * 7 + CAST(SUBSTRING(cpf, 6, 1) AS INT) * 6
          + CAST(SUBSTRING(cpf, 7, 1) AS INT) * 5 + CAST(SUBSTRING(cpf, 8, 1) AS INT) * 4
          + CAST(SUBSTRING(cpf, 9, 1) AS INT) * 3 + CAST(SUBSTRING(cpf, 10, 1) AS INT) * 2) % 11 AS r2
    FROM cpf
)
SELECT cpf,
       CAST(CASE
                WHEN cpf IS NULL THEN 0
                WHEN cpf = REPLICATE(LEFT(cpf, 1), 11) THEN 0  -- 000.000.000-00, 111.111.111-11... are invalid by rule
                WHEN CAST(SUBSTRING(cpf, 10, 1) AS INT) = CASE WHEN r1 < 2 THEN 0 ELSE 11 - r1 END
                 AND CAST(SUBSTRING(cpf, 11, 1) AS INT) = CASE WHEN r2 < 2 THEN 0 ELSE 11 - r2 END THEN 1
                ELSE 0
            END AS BIT) AS cpf_is_valid
FROM remainders;
GO

/* Birth date kept as text -> date. Accepts the two formats found in the legacy screens
   (dd/mm/yyyy and yyyy-mm-dd). Placeholders such as 00/00/0000, impossible dates and
   dates after the record was written become NULL (unknown) instead of a wrong age. */
CREATE OR ALTER FUNCTION etl.fn_parse_birth_date (@typed VARCHAR(10), @recorded_on DATE)
RETURNS TABLE
AS
RETURN
SELECT CASE WHEN p.d >= '19000101' AND p.d <= @recorded_on THEN p.d END AS birth_date
FROM (
    SELECT CASE
               WHEN @typed LIKE '[0-3][0-9]/[01][0-9]/[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, @typed, 103)
               WHEN @typed LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]' THEN TRY_CONVERT(DATE, @typed, 23)
           END AS d
) AS p;
GO

/* Date -> integer key of the date dimension (yyyymmdd). NULL dates map to -1
   ("not applicable", e.g. a policy that was never cancelled).
   A scalar function, but simple enough for SQL Server 2019+ to inline it into the query. */
CREATE OR ALTER FUNCTION etl.fn_date_key (@d DATE)
RETURNS INT
WITH SCHEMABINDING
AS
BEGIN
    RETURN ISNULL(CONVERT(INT, CONVERT(CHAR(8), @d, 112)), -1);
END
GO
