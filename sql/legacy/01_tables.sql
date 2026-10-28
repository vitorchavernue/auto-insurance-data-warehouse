/* =====================================================================================
   SeguroLegado - legacy policy administration system
   -------------------------------------------------------------------------------------
   What: the operational database of the auto insurer, as it looks after 15 years in
   production. Portuguese column names, dates kept as text in some places, categories
   typed by hand, no foreign keys and only primary-key indexes.

   Why it is part of the project: it is the starting point. Management reports used to
   run directly against these tables, competing with the policy system for the same
   server. The warehouse (SeguroDW) is built from here.

   The database runs at compatibility level 110 (SQL Server 2012), as the original did.
   ===================================================================================== */

-- Brokers (corretores) who sell the policies
CREATE TABLE dbo.Corretor (
    CdCorretor   INT          NOT NULL CONSTRAINT PK_Corretor PRIMARY KEY,
    NmCorretor   VARCHAR(120) NOT NULL,
    NrSusep      VARCHAR(20)  NULL,      -- registration number at SUSEP (insurance regulator)
    SgUf         CHAR(2)      NULL,
    FlAtivo      CHAR(1)      NOT NULL,  -- S = active, N = no longer selling
    DtAlteracao  DATETIME     NOT NULL   -- last change of the row (used by the incremental load)
);

-- Insurance products sold
CREATE TABLE dbo.Produto (
    CdProduto    INT          NOT NULL CONSTRAINT PK_Produto PRIMARY KEY,
    DsProduto    VARCHAR(60)  NOT NULL,
    DtAlteracao  DATETIME     NOT NULL
);

-- Insured customers (segurados)
CREATE TABLE dbo.Segurado (
    CdSegurado   INT          NOT NULL CONSTRAINT PK_Segurado PRIMARY KEY,
    NmSegurado   VARCHAR(120) NOT NULL,
    NrCpf        VARCHAR(20)  NULL,      -- typed with or without punctuation; some lost their leading zeros
    DtNascimento VARCHAR(10)  NULL,      -- text: dd/mm/yyyy, yyyy-mm-dd or 00/00/0000
    SgUf         CHAR(2)      NULL,
    NmCidade     VARCHAR(80)  NULL,
    DtAlteracao  DATETIME     NOT NULL
);

-- Insured vehicles
CREATE TABLE dbo.Veiculo (
    CdVeiculo    INT           NOT NULL CONSTRAINT PK_Veiculo PRIMARY KEY,
    CdSegurado   INT           NOT NULL,
    NrPlaca      VARCHAR(8)    NULL,
    CdFipe       VARCHAR(10)   NULL,     -- code in the FIPE price table
    NmMarca      VARCHAR(40)   NULL,
    NmModelo     VARCHAR(60)   NULL,
    NrAnoModelo  SMALLINT      NULL,
    DsCategoria  VARCHAR(20)   NULL,     -- typed by hand: AUTO, Auto, AUTOMOVEL, MOTOCICLETA, CAMINHÃO...
    VlFipe       DECIMAL(12,2) NULL,     -- market value of the vehicle
    DtAlteracao  DATETIME      NOT NULL
);

-- Policies (apólices): one-year term, renewals point to the previous policy
CREATE TABLE dbo.Apolice (
    NrApolice         INT      NOT NULL CONSTRAINT PK_Apolice PRIMARY KEY,
    CdSegurado        INT      NOT NULL,
    CdVeiculo         INT      NOT NULL,
    CdCorretor        INT      NOT NULL,
    CdProduto         INT      NOT NULL,
    DtEmissao         DATETIME NOT NULL,  -- when the policy was issued
    DtInicioVigencia  DATETIME NOT NULL,  -- coverage starts (inclusive)
    DtFimVigencia     DATETIME NOT NULL,  -- coverage ends (exclusive)
    DtCancelamento    DATETIME NULL,      -- coverage stopped early on this date (exclusive)
    NrApoliceAnterior INT      NULL,      -- renewal of this policy
    DtAlteracao       DATETIME NOT NULL
);

-- Coverages of each policy and their net premium
CREATE TABLE dbo.ApoliceCobertura (
    NrApolice             INT           NOT NULL,
    CdCobertura           VARCHAR(10)   NOT NULL,  -- ROUBO (theft), COLISAO (collision), TERCEIROS (liability), VIDROS (glass)
    VlImportanciaSegurada DECIMAL(14,2) NULL,      -- sum insured
    VlPremioLiquido       DECIMAL(12,2) NULL,      -- net premium for the whole term
    DtAlteracao           DATETIME      NOT NULL,
    CONSTRAINT PK_ApoliceCobertura PRIMARY KEY (NrApolice, CdCobertura)
);

-- Claims (sinistros)
CREATE TABLE dbo.Sinistro (
    NrSinistro      INT         NOT NULL CONSTRAINT PK_Sinistro PRIMARY KEY,
    NrApolice       INT         NOT NULL,
    CdCobertura     VARCHAR(10) NOT NULL,
    DtOcorrencia    DATETIME    NOT NULL,  -- when it happened
    DtAviso         DATETIME    NOT NULL,  -- when the customer reported it
    DsCausa         VARCHAR(30) NULL,
    SgUfOcorrencia  CHAR(2)     NULL,
    CdSituacao      CHAR(1)     NOT NULL,  -- A open, P paid and closed, N denied, R vehicle recovered
    DtAlteracao     DATETIME    NOT NULL
);

-- Financial movements of each claim
CREATE TABLE dbo.SinistroMovimento (
    NrSinistro   INT           NOT NULL,
    NrSequencia  INT           NOT NULL,
    DtMovimento  DATETIME      NOT NULL,
    TpMovimento  CHAR(3)       NOT NULL,  -- AVI opening reserve, AJU reserve adjustment, PAG payment, SAL salvage/recovery
    VlMovimento  DECIMAL(14,2) NOT NULL,
    DtAlteracao  DATETIME      NOT NULL,
    CONSTRAINT PK_SinistroMovimento PRIMARY KEY (NrSinistro, NrSequencia)
);
