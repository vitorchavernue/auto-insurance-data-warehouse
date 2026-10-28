/* =====================================================================================
   SeguroLegado - the original monthly loss ratio report (kept for comparison)
   -------------------------------------------------------------------------------------
   What: the report the board used to receive. For each closed month of a year, by
   vehicle category and coverage: earned premium, incurred claims, number of claims
   and loss ratio (incurred / earned).

   Why it is kept: it is the "before" of the project. It is written the way it was
   found: scalar functions called row by row, a month-by-month loop, YEAR()/MONTH()
   applied to columns (no index can help) and the same tables read again for every
   month. scripts/benchmark compares it with the warehouse: same numbers, far fewer
   reads. It is not used by the warehouse.

   Business definitions (the warehouse uses exactly the same):
   - Earned premium: the premium is earned day by day while the policy is in force.
     Earned in a month = premium x days in force in that month / days of the term.
     A cancellation stops the earning on the cancellation date.
   - Incurred claims of a month: payments + reserve changes - recoveries recorded
     in that month.
   - Claims of a month: claims that happened in the month, except denied ones.
   ===================================================================================== */

-- Vehicle category with the hand-typed variations mapped (one lookup per call)
CREATE FUNCTION dbo.fn_Categoria (@CdVeiculo INT)
RETURNS VARCHAR(10)
AS
BEGIN
    DECLARE @Categoria VARCHAR(20);
    SELECT @Categoria = UPPER(LTRIM(RTRIM(DsCategoria))) FROM dbo.Veiculo WHERE CdVeiculo = @CdVeiculo;
    RETURN CASE
        WHEN @Categoria IN ('AUTO', 'AUTOMOVEL') THEN 'AUTO'
        WHEN @Categoria IN ('MOTO', 'MOTOCICLETA') THEN 'MOTO'
        WHEN @Categoria IN ('CAMINHAO', N'CAMINHÃO') THEN 'CAMINHAO'
        ELSE 'OUTROS'
    END;
END
GO

-- Premium of one coverage earned in one month (reads the policy again on every call)
CREATE FUNCTION dbo.fn_PremioGanhoMes (@NrApolice INT, @CdCobertura VARCHAR(10), @Ano INT, @Mes INT)
RETURNS DECIMAL(18,6)
AS
BEGIN
    DECLARE @Premio DECIMAL(12,2), @Inicio DATETIME, @Fim DATETIME, @FimEfetivo DATETIME;

    SELECT @Premio = c.VlPremioLiquido,
           @Inicio = a.DtInicioVigencia,
           @Fim = a.DtFimVigencia,
           @FimEfetivo = ISNULL(a.DtCancelamento, a.DtFimVigencia)
    FROM dbo.ApoliceCobertura AS c
    JOIN dbo.Apolice AS a ON a.NrApolice = c.NrApolice
    WHERE c.NrApolice = @NrApolice AND c.CdCobertura = @CdCobertura;

    -- First day of the month and first day of the next month
    DECLARE @IniMes DATETIME = DATEADD(MONTH, @Mes - 1, DATEADD(YEAR, @Ano - 1900, 0));
    DECLARE @FimMes DATETIME = DATEADD(MONTH, 1, @IniMes);

    -- Part of the month in which the policy was in force
    DECLARE @De DATETIME = CASE WHEN @Inicio > @IniMes THEN @Inicio ELSE @IniMes END;
    DECLARE @Ate DATETIME = CASE WHEN @FimEfetivo < @FimMes THEN @FimEfetivo ELSE @FimMes END;

    IF @Premio IS NULL OR @Ate <= @De
        RETURN 0;
    RETURN CAST(@Premio AS DECIMAL(18,6)) * DATEDIFF(DAY, @De, @Ate) / DATEDIFF(DAY, @Inicio, @Fim);
END
GO

CREATE PROCEDURE dbo.usp_RelatorioSinistralidade
    @Ano INT,                 -- year of the report
    @DataFechamento DATETIME  -- closing date: only months that ended on or before it are reported
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #Resultado (
        Mes               INT,
        Categoria         VARCHAR(10),
        Cobertura         VARCHAR(10),
        PremioGanho       DECIMAL(18,6),
        SinistroIncorrido DECIMAL(18,2),
        QtdSinistros      INT
    );

    DECLARE @Mes INT = 1;
    WHILE @Mes <= 12
    BEGIN
        -- Only closed months (the last day of the month is on or before the closing date)
        IF DATEADD(DAY, -1, DATEADD(MONTH, @Mes, DATEADD(YEAR, @Ano - 1900, 0))) <= @DataFechamento
        BEGIN
            -- Earned premium: policies that started this year or last year can be in force in the month
            INSERT INTO #Resultado
            SELECT @Mes, dbo.fn_Categoria(a.CdVeiculo), c.CdCobertura,
                   SUM(dbo.fn_PremioGanhoMes(c.NrApolice, c.CdCobertura, @Ano, @Mes)), 0, 0
            FROM dbo.ApoliceCobertura AS c
            JOIN dbo.Apolice AS a ON a.NrApolice = c.NrApolice
            WHERE YEAR(a.DtInicioVigencia) IN (@Ano - 1, @Ano)
            GROUP BY dbo.fn_Categoria(a.CdVeiculo), c.CdCobertura;

            -- Incurred claims: every movement recorded in the month (recoveries reduce the cost)
            INSERT INTO #Resultado
            SELECT @Mes, dbo.fn_Categoria(a.CdVeiculo), s.CdCobertura, 0,
                   SUM(CASE m.TpMovimento WHEN 'SAL' THEN -m.VlMovimento ELSE m.VlMovimento END), 0
            FROM dbo.SinistroMovimento AS m
            JOIN dbo.Sinistro AS s ON s.NrSinistro = m.NrSinistro
            JOIN dbo.Apolice AS a ON a.NrApolice = s.NrApolice
            WHERE YEAR(m.DtMovimento) = @Ano AND MONTH(m.DtMovimento) = @Mes
            GROUP BY dbo.fn_Categoria(a.CdVeiculo), s.CdCobertura;

            -- Number of claims that happened in the month (denied claims do not count)
            INSERT INTO #Resultado
            SELECT @Mes, dbo.fn_Categoria(a.CdVeiculo), s.CdCobertura, 0, 0, COUNT(*)
            FROM dbo.Sinistro AS s
            JOIN dbo.Apolice AS a ON a.NrApolice = s.NrApolice
            WHERE YEAR(s.DtOcorrencia) = @Ano AND MONTH(s.DtOcorrencia) = @Mes AND s.CdSituacao <> 'N'
            GROUP BY dbo.fn_Categoria(a.CdVeiculo), s.CdCobertura;
        END
        SET @Mes = @Mes + 1;
    END

    SELECT @Ano AS Ano,
           Mes,
           Categoria,
           Cobertura,
           CAST(ROUND(SUM(PremioGanho), 2) AS DECIMAL(18,2)) AS PremioGanho,
           SUM(SinistroIncorrido) AS SinistroIncorrido,
           SUM(QtdSinistros) AS QtdSinistros,
           CASE WHEN SUM(PremioGanho) > 0 THEN SUM(SinistroIncorrido) / SUM(PremioGanho) END AS Sinistralidade
    FROM #Resultado
    GROUP BY Mes, Categoria, Cobertura
    ORDER BY Mes, Categoria, Cobertura;
END
GO
