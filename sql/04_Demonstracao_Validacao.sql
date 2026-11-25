-- =============================================================================
-- 04_Demonstracao_Validacao.sql — Roteiro de testes para apresentar ao professor
-- Data Warehouse de NPS (PostgreSQL)
--
-- Pré-requisito: banco dw_nps carregado (01, 02, CSV importado e
-- CALL sp_carregar_dw(); já executados).
--
-- COMO EXECUTAR: um bloco por vez. No DBeaver, selecione o bloco inteiro e
-- aperte Ctrl+Enter (Mac: ⌘↩). Alguns testes dão ERRO DE PROPÓSITO: isso
-- prova que as regras do banco funcionam.
-- =============================================================================


-- =============================================================================
-- TESTE 1 — Os objetos exigidos existem no banco
-- Esperado: 7 tabelas, 2 views, 1 procedure, 1 função de trigger, 1 trigger
-- =============================================================================
SELECT 'tabelas' AS objeto, COUNT(*) AS qtd
FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
UNION ALL
SELECT 'views', COUNT(*) FROM pg_views WHERE schemaname = 'public'
UNION ALL
SELECT 'procedure', COUNT(*) FROM pg_proc WHERE proname = 'sp_carregar_dw'
UNION ALL
SELECT 'funcao do trigger', COUNT(*) FROM pg_proc WHERE proname = 'fn_classificar_nps'
UNION ALL
SELECT 'trigger', COUNT(*) FROM pg_trigger WHERE tgname = 'trg_classificar_nps';


-- =============================================================================
-- TESTE 2 — Modelo estrela carregado
-- Esperado: fato 29 | cliente 15 | responsavel 3 | categoria 5 | nota 11 | tempo 365
-- =============================================================================
SELECT 'fato_nps' AS tabela, COUNT(*) AS linhas FROM fato_nps
UNION ALL SELECT 'dim_cliente',     COUNT(*) FROM dim_cliente
UNION ALL SELECT 'dim_responsavel', COUNT(*) FROM dim_responsavel
UNION ALL SELECT 'dim_categoria',   COUNT(*) FROM dim_categoria
UNION ALL SELECT 'dim_nota',        COUNT(*) FROM dim_nota
UNION ALL SELECT 'dim_tempo',       COUNT(*) FROM dim_tempo;


-- =============================================================================
-- TESTE 3 — VIEW vw_nps_respostas: o modelo estrela "montado"
-- Uma linha por resposta, sem o usuário precisar escrever 5 JOINs.
-- Esperado: 29 linhas com empresa, analista, categoria e classificação
-- =============================================================================
SELECT * FROM vw_nps_respostas ORDER BY data_resposta;


-- =============================================================================
-- TESTE 4 — VIEW vw_nps_por_empresa: NPS calculado no banco
-- Esperado: Empresa Alpha com 15 respostas e NPS 86.7 no topo
-- =============================================================================
SELECT * FROM vw_nps_por_empresa ORDER BY respostas DESC, nps DESC;


-- =============================================================================
-- TESTE 5 — NPS geral (o mesmo número do dashboard)
-- Esperado: 29 | 24 | 4 | 1 | 82.8 | 3.4 | 79.3
-- =============================================================================
SELECT
    COUNT(*)                                           AS respostas,
    SUM(flag_promotor)                                 AS promotores,
    SUM(flag_neutro)                                   AS neutros,
    SUM(flag_detrator)                                 AS detratores,
    ROUND(100.0 * SUM(flag_promotor) / COUNT(*), 1)    AS pct_promotores,
    ROUND(100.0 * SUM(flag_detrator) / COUNT(*), 1)    AS pct_detratores,
    ROUND(100.0 * (SUM(flag_promotor) - SUM(flag_detrator)) / COUNT(*), 1) AS nps
FROM fato_nps;


-- =============================================================================
-- TESTE 6 — TRIGGER bloqueia nota inválida
-- Esperado: ERRO "Nota inválida (15) no ticket 1002. O NPS aceita apenas 0 a 10."
-- =============================================================================
UPDATE fato_nps SET nota = 15 WHERE ticket_id = 1002;


-- =============================================================================
-- TESTE 7 — TRIGGER reclassifica sozinho
-- O ticket 1002 tem nota 7 (Neutro). Ao mudar para 9, o trigger recalcula as flags.
-- Esperado no SELECT: nota 9 | sk_nota 9 | flag_promotor 1 | flag_neutro 0
-- =============================================================================
UPDATE fato_nps SET nota = 9 WHERE ticket_id = 1002;

SELECT ticket_id, nota, sk_nota, flag_promotor, flag_neutro, flag_detrator
FROM fato_nps WHERE ticket_id = 1002;


-- =============================================================================
-- TESTE 8 — TRIGGER impede adulterar a classificação
-- Tentativa de marcar como detrator uma resposta com nota 10.
-- Esperado no SELECT: nota 10 | flag_promotor 1 | flag_detrator 0
-- (o trigger ignora a alteração manual e recalcula a partir da nota)
-- =============================================================================
UPDATE fato_nps SET flag_promotor = 0, flag_detrator = 1 WHERE ticket_id = 1001;

SELECT ticket_id, nota, flag_promotor, flag_detrator
FROM fato_nps WHERE ticket_id = 1001;


-- =============================================================================
-- TESTE 9 — PROCEDURE recarrega o DW e desfaz os testes acima
-- Esperado na aba Saída: "Carga concluída: 29 linhas na staging, 29 respostas na fato_nps."
-- O ticket 1002 volta a ter nota 7.
-- =============================================================================
CALL sp_carregar_dw();

SELECT ticket_id, nota, flag_neutro FROM fato_nps WHERE ticket_id = 1002;


-- =============================================================================
-- TESTE 10 — PROCEDURE recusa carga com a staging vazia
-- 10a) guarda uma cópia da staging e esvazia a tabela
-- =============================================================================
CREATE TEMP TABLE bkp_stg AS SELECT * FROM stg_nps;
TRUNCATE stg_nps;

-- 10b) Esperado: ERRO "A tabela stg_nps está vazia. Importe o CSV antes de rodar a carga."
CALL sp_carregar_dw();

-- 10c) a fato continua intacta. Esperado: 29
SELECT COUNT(*) AS respostas_na_fato FROM fato_nps;

-- 10d) devolve os dados para a staging. Esperado: 29
INSERT INTO stg_nps SELECT * FROM bkp_stg;
SELECT COUNT(*) AS linhas_na_staging FROM stg_nps;


-- =============================================================================
-- TESTE 11 — PROCEDURE é atômica: se falhar no meio, nada é gravado
-- 11a) duplica uma resposta na staging (simula o CSV importado duas vezes)
-- =============================================================================
INSERT INTO stg_nps SELECT * FROM stg_nps WHERE ticket_id = 1001;

-- 11b) Esperado: ERRO "duplicate key value violates unique constraint fato_nps_ticket_id_key"
CALL sp_carregar_dw();

-- 11c) mesmo com o TRUNCATE dentro da procedure, o DW não foi apagado. Esperado: 29
SELECT COUNT(*) AS respostas_na_fato FROM fato_nps;

-- 11d) limpa a staging, devolve as 29 linhas originais e recarrega
TRUNCATE stg_nps;
INSERT INTO stg_nps SELECT * FROM bkp_stg;
CALL sp_carregar_dw();
DROP TABLE bkp_stg;


-- =============================================================================
-- TESTE 12 — Conferência final (o banco voltou ao estado original)
-- Esperado: 29 respostas | NPS 79.3
-- =============================================================================
SELECT COUNT(*) AS respostas,
       ROUND(100.0 * (SUM(flag_promotor) - SUM(flag_detrator)) / COUNT(*), 1) AS nps
FROM fato_nps;
