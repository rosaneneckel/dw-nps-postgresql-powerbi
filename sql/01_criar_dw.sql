
-- =============================================================================
-- 01_criar_dw.sql —  DDL do Data Warehouse de NPS (PostgreSQL)
-- =============================================================================
-- PASSO 0 (rodar UMA vez, conectado ao banco padrão "postgres"):
--     CREATE DATABASE dw_nps ENCODING 'UTF8';
-- Depois, conecte-se ao banco dw_nps e rode o restante deste arquivo.
-- =============================================================================

-- VERSÃO SEM SCHEMAS: todas as tabelas ficam no schema padrão "public".
-- stg_nps    -> área de chegada, recebe o CSV do jeito que ele é
-- dim_* e fato_nps -> o modelo estrela final, que o Power BI vai ler

-- -----------------------------------------------------------------------------
-- STAGING: espelho exato do CSV (dados/nps_fev2025_anonimizado.csv)
-- -----------------------------------------------------------------------------

CREATE TABLE stg_nps (
    ticket_id      INTEGER,
    empresa        VARCHAR(50),
    contato        VARCHAR(50),
    analista       VARCHAR(50),
    equipe         VARCHAR(50),
    categoria      VARCHAR(50),
    aberto_em      TIMESTAMP,
    resolvido_em   TIMESTAMP,
    respondido_em  TIMESTAMP,
    nota           SMALLINT
);

-- -----------------------------------------------------------------------------
-- DIMENSÃO TEMPO: um registro por dia (calendário)
-- sk_tempo no formato AAAAMMDD (ex.: 20250214) facilita a leitura
-- -----------------------------------------------------------------------------
CREATE TABLE dim_tempo (
    sk_tempo        INTEGER PRIMARY KEY,       -- 20250214
    data            DATE NOT NULL UNIQUE,
    dia             SMALLINT NOT NULL,
    mes             SMALLINT NOT NULL,
    nome_mes        VARCHAR(15) NOT NULL,
    ano             SMALLINT NOT NULL,
    trimestre       SMALLINT NOT NULL,
    dia_semana_num  SMALLINT NOT NULL,         -- 1 = segunda ... 7 = domingo
    dia_semana      VARCHAR(15) NOT NULL,
    semana_do_mes   SMALLINT NOT NULL,
    fim_de_semana   BOOLEAN NOT NULL
);

-- -----------------------------------------------------------------------------
-- DIMENSÃO CLIENTE: empresa (organização) + contato que respondeu
-- Já ficam juntas (desnormalizadas): isso é o que caracteriza o modelo ESTRELA
-- -----------------------------------------------------------------------------
CREATE TABLE dim_cliente (
    sk_cliente   SERIAL PRIMARY KEY,           -- chave substituta (surrogate key)
    empresa      VARCHAR(50) NOT NULL,         -- já anonimizada: "Empresa Alpha"
    contato      VARCHAR(50) NOT NULL,         -- já anonimizado: "Contato 01"
    UNIQUE (empresa, contato)
);

-- -----------------------------------------------------------------------------
-- DIMENSÃO RESPONSÁVEL: quem atendeu o chamado e de qual equipe
-- -----------------------------------------------------------------------------
CREATE TABLE dim_responsavel (
    sk_responsavel  SERIAL PRIMARY KEY,
    analista        VARCHAR(50) NOT NULL,      -- "Analista 01"
    equipe          VARCHAR(50) NOT NULL,      -- "Product Owner" / "Agentes"
    UNIQUE (analista, equipe)
);

-- -----------------------------------------------------------------------------
-- DIMENSÃO CATEGORIA: tipo de assunto do chamado
-- -----------------------------------------------------------------------------
CREATE TABLE dim_categoria (
    sk_categoria  SERIAL PRIMARY KEY,
    categoria     VARCHAR(50) NOT NULL UNIQUE
);

-- -----------------------------------------------------------------------------
-- DIMENSÃO NOTA: as 11 notas possíveis (0 a 10) e a classificação NPS de cada uma
-- Aqui fica a REGRA DE NEGÓCIO do NPS, num lugar só.
-- -----------------------------------------------------------------------------
CREATE TABLE dim_nota (
    sk_nota          SMALLINT PRIMARY KEY,     -- a própria nota (0..10)
    nota             SMALLINT NOT NULL CHECK (nota BETWEEN 0 AND 10),
    classificacao    VARCHAR(10) NOT NULL,     -- Promotor / Neutro / Detrator
    ordem_classif    SMALLINT NOT NULL         -- 1 Promotor, 2 Neutro, 3 Detrator (para ordenar gráficos)
);


-- -----------------------------------------------------------------------------
-- TABELA FATO: uma linha = uma resposta de NPS (grão da tabela)
-- -----------------------------------------------------------------------------
CREATE TABLE fato_nps (
    sk_fato                 SERIAL PRIMARY KEY,
    ticket_id               INTEGER NOT NULL UNIQUE,  -- "dimensão degenerada": o nº do chamado
    sk_tempo                INTEGER  NOT NULL REFERENCES dim_tempo(sk_tempo),          -- data da resposta
    sk_cliente              INTEGER  NOT NULL REFERENCES dim_cliente(sk_cliente),
    sk_responsavel          INTEGER  NOT NULL REFERENCES dim_responsavel(sk_responsavel),
    sk_categoria            INTEGER  NOT NULL REFERENCES dim_categoria(sk_categoria),
    sk_nota                 SMALLINT NOT NULL REFERENCES dim_nota(sk_nota),
    -- métricas (números que o BI soma / calcula média)
    nota                    SMALLINT NOT NULL CHECK (nota BETWEEN 0 AND 10),
    flag_promotor           SMALLINT NOT NULL,        -- 1 se nota 9 ou 10, senão 0
    flag_neutro             SMALLINT NOT NULL,        -- 1 se nota 7 ou 8, senão 0
    flag_detrator           SMALLINT NOT NULL,        -- 1 se nota 0 a 6, senão 0
    horas_ate_resolucao     NUMERIC(10,2),            -- Aberto em -> Resolvido em
    horas_ate_resposta_nps  NUMERIC(10,2)             -- Resolvido em -> Respondido em
);

-- Índices nas chaves estrangeiras (deixam as consultas mais rápidas)
CREATE INDEX ix_fato_tempo       ON fato_nps (sk_tempo);
CREATE INDEX ix_fato_cliente     ON fato_nps (sk_cliente);
CREATE INDEX ix_fato_responsavel ON fato_nps (sk_responsavel);
CREATE INDEX ix_fato_categoria   ON fato_nps (sk_categoria);
CREATE INDEX ix_fato_nota        ON fato_nps (sk_nota);