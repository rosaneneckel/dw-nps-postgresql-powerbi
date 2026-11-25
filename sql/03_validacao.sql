-- =============================================================================
-- 03_validacao.sql —  Confere se a carga deu certo ANTES de abrir o Power BI
-- Os números do dashboard têm que bater com estes.
-- =============================================================================

-- 0) Staging: o CSV foi importado por inteiro?
--    Esperado: 29 linhas | 0 sem data de resposta
SELECT COUNT(*) AS linhas_staging FROM stg_nps;
SELECT COUNT(*) AS sem_data_resposta FROM stg_nps WHERE respondido_em IS NULL;
SELECT * FROM stg_nps LIMIT 5;

-- 1) Quantas linhas em cada tabela
SELECT 'fato_nps' AS tabela, COUNT(*) FROM fato_nps
UNION ALL SELECT 'dim_cliente',     COUNT(*) FROM dim_cliente
UNION ALL SELECT 'dim_responsavel', COUNT(*) FROM dim_responsavel
UNION ALL SELECT 'dim_categoria',   COUNT(*) FROM dim_categoria
UNION ALL SELECT 'dim_nota',        COUNT(*) FROM dim_nota
UNION ALL SELECT 'dim_tempo',       COUNT(*) FROM dim_tempo;

-- 2) NPS geral de Fevereiro/2025 calculado direto no SQL
SELECT
    COUNT(*)                                                    AS respostas,
    SUM(flag_promotor)                                          AS promotores,
    SUM(flag_neutro)                                            AS neutros,
    SUM(flag_detrator)                                          AS detratores,
    ROUND(100.0 * SUM(flag_promotor) / COUNT(*), 1)             AS pct_promotores,
    ROUND(100.0 * SUM(flag_detrator) / COUNT(*), 1)             AS pct_detratores,
    ROUND(100.0 * (SUM(flag_promotor) - SUM(flag_detrator)) / COUNT(*), 1) AS nps,
    ROUND(AVG(nota), 2)                                         AS nota_media
FROM fato_nps;

-- 3) NPS por empresa (exemplo de consulta no modelo estrela)
SELECT c.empresa,
       COUNT(*) AS respostas,
       ROUND(100.0 * (SUM(f.flag_promotor) - SUM(f.flag_detrator)) / COUNT(*), 1) AS nps
FROM fato_nps f
JOIN dim_cliente c ON c.sk_cliente = f.sk_cliente
GROUP BY c.empresa
ORDER BY respostas DESC, nps DESC;

-- 4) Prova de anonimização: não pode aparecer nenhum nome real
SELECT DISTINCT empresa, contato FROM dim_cliente ORDER BY 1, 2;
SELECT DISTINCT analista, equipe FROM dim_responsavel ORDER BY 1;


SELECT * FROM vw_nps_respostas ORDER BY data_resposta;   -- 29 linhas
SELECT * FROM vw_nps_por_empresa ORDER BY respostas DESC; -- Empresa Alpha: 15 respostas, NPS 86.7



