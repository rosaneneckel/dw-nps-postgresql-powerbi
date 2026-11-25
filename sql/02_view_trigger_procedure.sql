
-- =============================================================================
-- 02_view_trigger_procedure.sql  —  Objetos programáveis do DW de NPS
-- Versão SEM SCHEMAS (tabelas no schema "public").
--
-- Rode este arquivo UMA vez, logo DEPOIS do 01_criar_dw.sql.
-- Ele cria:
--   1 TRIGGER   -> aplica a regra do NPS automaticamente em cada linha da fato
--   1 PROCEDURE -> faz toda a carga staging -> modelo estrela com um único CALL
--   2 VIEWS     -> consultas prontas (detalhe de cada resposta e resumo por empresa)

-- =============================================================================

-- =============================================================================
-- 1) TRIGGER: regra de negócio do NPS dentro do banco
-- -----------------------------------------------------------------------------
-- Toda vez que uma linha for INSERIDA ou ALTERADA na fato_nps, o trigger:
--   - confere se a nota está entre 0 e 10 (senão, bloqueia com erro)
--   - preenche sk_nota com a própria nota (liga com a dim_nota)
--   - calcula as flags de Promotor (9-10), Neutro (7-8) e Detrator (0-6)
-- Assim ninguém consegue gravar uma classificação errada, nem por engano.
-- =============================================================================

-- 1a) A FUNÇÃO que o trigger executa (no PostgreSQL o trigger sempre chama uma função)
CREATE OR REPLACE FUNCTION fn_classificar_nps()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- NEW = a linha que está sendo gravada
    IF NEW.nota IS NULL OR NEW.nota NOT BETWEEN 0 AND 10 THEN
        RAISE EXCEPTION 'Nota inválida (%) no ticket %. O NPS aceita apenas 0 a 10.',
                        NEW.nota, NEW.ticket_id;
    END IF;

    NEW.sk_nota       := NEW.nota;
    NEW.flag_promotor := CASE WHEN NEW.nota >= 9            THEN 1 ELSE 0 END;
    NEW.flag_neutro   := CASE WHEN NEW.nota BETWEEN 7 AND 8 THEN 1 ELSE 0 END;
    NEW.flag_detrator := CASE WHEN NEW.nota <= 6            THEN 1 ELSE 0 END;

    RETURN NEW;   -- devolve a linha já completada para ser gravada
END;
$$;

-- 1b) O TRIGGER propriamente dito: "antes de inserir ou alterar QUALQUER coluna da fato, rode a função".
-- Assim, mesmo um UPDATE direto nas flags é recalculado a partir da nota, e a classificação nunca fica errada.
DROP TRIGGER IF EXISTS trg_classificar_nps ON fato_nps;
CREATE TRIGGER trg_classificar_nps
    BEFORE INSERT OR UPDATE ON fato_nps
    FOR EACH ROW
    EXECUTE FUNCTION fn_classificar_nps();


-- =============================================================================
-- 2) PROCEDURE: a carga inteira do DW em um único comando
-- -----------------------------------------------------------------------------
-- Depois de importar o CSV na stg_nps, basta rodar:   CALL sp_carregar_dw();
-- Ela limpa o DW, preenche as dimensões e depois a fato.
-- Repare que o INSERT da fato NÃO informa flags nem sk_nota: o trigger faz isso.
-- =============================================================================
CREATE OR REPLACE PROCEDURE sp_carregar_dw()
LANGUAGE plpgsql
AS $$
DECLARE
    v_qtd_staging INTEGER;
    v_qtd_fato    INTEGER;
BEGIN
    -- Segurança: não deixa carregar se a staging estiver vazia
    SELECT COUNT(*) INTO v_qtd_staging FROM stg_nps;
    IF v_qtd_staging = 0 THEN
        RAISE EXCEPTION 'A tabela stg_nps está vazia. Importe o CSV antes de rodar a carga.';
    END IF;

    -- Limpa o DW (permite rodar a procedure várias vezes)
    TRUNCATE fato_nps, dim_tempo, dim_cliente, dim_responsavel,
             dim_categoria, dim_nota RESTART IDENTITY;

    -- DIM_TEMPO: todos os dias de 2025
    INSERT INTO dim_tempo
    SELECT
        TO_CHAR(d, 'YYYYMMDD')::INTEGER,
        d::DATE,
        EXTRACT(DAY FROM d),
        EXTRACT(MONTH FROM d),
        (ARRAY['Janeiro','Fevereiro','Março','Abril','Maio','Junho','Julho',
               'Agosto','Setembro','Outubro','Novembro','Dezembro'])[EXTRACT(MONTH FROM d)],
        EXTRACT(YEAR FROM d),
        EXTRACT(QUARTER FROM d),
        EXTRACT(ISODOW FROM d),
        (ARRAY['Segunda','Terça','Quarta','Quinta','Sexta','Sábado','Domingo'])[EXTRACT(ISODOW FROM d)],
        ((EXTRACT(DAY FROM d)::INT - 1) / 7) + 1,
        EXTRACT(ISODOW FROM d) IN (6, 7)
    FROM generate_series('2025-01-01'::DATE, '2025-12-31'::DATE, INTERVAL '1 day') AS d;

    -- DIM_NOTA: as 11 notas e a classificação NPS
    INSERT INTO dim_nota (sk_nota, nota, classificacao, ordem_classif)
    SELECT n, n,
           CASE WHEN n >= 9 THEN 'Promotor' WHEN n >= 7 THEN 'Neutro' ELSE 'Detrator' END,
           CASE WHEN n >= 9 THEN 1          WHEN n >= 7 THEN 2        ELSE 3          END
    FROM generate_series(0, 10) AS n;

    -- Demais dimensões
    INSERT INTO dim_cliente (empresa, contato)
    SELECT DISTINCT empresa, contato FROM stg_nps ORDER BY empresa, contato;

    INSERT INTO dim_responsavel (analista, equipe)
    SELECT DISTINCT analista, equipe FROM stg_nps ORDER BY analista;

    INSERT INTO dim_categoria (categoria)
    SELECT DISTINCT categoria FROM stg_nps ORDER BY categoria;

    -- FATO (recorte Fev/2025). Flags e sk_nota ficam a cargo do trigger.
    INSERT INTO fato_nps (
        ticket_id, sk_tempo, sk_cliente, sk_responsavel, sk_categoria, nota,
        horas_ate_resolucao, horas_ate_resposta_nps
    )
    SELECT
        s.ticket_id,
        TO_CHAR(s.respondido_em, 'YYYYMMDD')::INTEGER,
        c.sk_cliente,
        r.sk_responsavel,
        g.sk_categoria,
        s.nota,
        ROUND(EXTRACT(EPOCH FROM (s.resolvido_em  - s.aberto_em))    / 3600.0, 2),
        ROUND(EXTRACT(EPOCH FROM (s.respondido_em - s.resolvido_em)) / 3600.0, 2)
    FROM stg_nps s
    JOIN dim_cliente     c ON c.empresa  = s.empresa  AND c.contato = s.contato
    JOIN dim_responsavel r ON r.analista = s.analista AND r.equipe  = s.equipe
    JOIN dim_categoria   g ON g.categoria = s.categoria
    WHERE s.respondido_em >= '2025-02-01' AND s.respondido_em < '2025-03-01';

    SELECT COUNT(*) INTO v_qtd_fato FROM fato_nps;
    RAISE NOTICE 'Carga concluída: % linhas na staging, % respostas na fato_nps.',
                 v_qtd_staging, v_qtd_fato;
END;
$$;

-- =============================================================================
-- 3) VIEWS: consultas prontas, guardadas no banco
-- =============================================================================

-- 3a) Uma linha por resposta, já com os nomes de todas as dimensões.
--     Útil para conferir dados e para mostrar o modelo estrela "montado".
CREATE OR REPLACE VIEW vw_nps_respostas AS
SELECT
    f.ticket_id,
    t.data              AS data_resposta,
    t.nome_mes,
    t.dia_semana,
    c.empresa,
    c.contato,
    r.analista,
    r.equipe,
    g.categoria,
    f.nota,
    n.classificacao,
    f.horas_ate_resolucao,
    f.horas_ate_resposta_nps
FROM fato_nps f
JOIN dim_tempo       t ON t.sk_tempo       = f.sk_tempo
JOIN dim_cliente     c ON c.sk_cliente     = f.sk_cliente
JOIN dim_responsavel r ON r.sk_responsavel = f.sk_responsavel
JOIN dim_categoria   g ON g.sk_categoria   = f.sk_categoria
JOIN dim_nota        n ON n.sk_nota        = f.sk_nota;

-- 3b) NPS calculado por empresa (o mesmo cálculo que o DAX fará no Power BI)
CREATE OR REPLACE VIEW vw_nps_por_empresa AS
SELECT
    c.empresa,
    COUNT(*)                                                         AS respostas,
    SUM(f.flag_promotor)                                             AS promotores,
    SUM(f.flag_neutro)                                               AS neutros,
    SUM(f.flag_detrator)                                             AS detratores,
    ROUND(100.0 * SUM(f.flag_promotor) / COUNT(*), 1)                AS pct_promotores,
    ROUND(100.0 * SUM(f.flag_detrator) / COUNT(*), 1)                AS pct_detratores,
    ROUND(100.0 * (SUM(f.flag_promotor) - SUM(f.flag_detrator)) / COUNT(*), 1) AS nps
FROM fato_nps f
JOIN dim_cliente c ON c.sk_cliente = f.sk_cliente
GROUP BY c.empresa;


