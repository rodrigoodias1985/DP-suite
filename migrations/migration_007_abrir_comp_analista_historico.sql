-- ============================================================
-- DP+ - migration_007_abrir_comp_analista_historico.sql
-- Corrige abrir_competencia: ao abrir um novo mes, o analista_id
-- de cada empresa e herdado de empresa_competencia da competencia
-- imediatamente anterior, em vez do campo cadastral empresas.analista_id.
--
-- Problema resolvido: ao inativar um usuario e redistribuir a
-- carteira via "Responsáveis por competência", empresas.analista_id
-- pode ficar NULL ou desatualizado. A RPC anterior usava esse campo,
-- abrindo o novo mes sem responsavel para essas empresas.
--
-- Comportamento novo:
--   1. Busca analista_id da competencia mais recente anterior a (p_mes, p_ano)
--      para cada empresa (fonte: empresa_competencia).
--   2. Fallback: se a empresa nao tem historico anterior (cadastro novo),
--      usa empresas.analista_id.
--
-- Idempotente: CREATE OR REPLACE. Nao altera dados ja existentes.
-- ============================================================

CREATE OR REPLACE FUNCTION public.abrir_competencia(p_mes integer, p_ano integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_comp_id        uuid;
  v_emp            record;
  v_ec             record;
  v_atv            record;
  v_nt             boolean;
  v_comp_start     date;
  v_prev_analista  uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM competencias WHERE mes = p_mes AND ano = p_ano) THEN
    RAISE EXCEPTION 'Competencia %/% ja existe.', p_mes, p_ano;
  END IF;

  v_comp_start := make_date(p_ano, p_mes, 1);

  INSERT INTO competencias (mes, ano, status)
  VALUES (p_mes, p_ano, 'aberta')
  RETURNING id INTO v_comp_id;

  FOR v_emp IN
    SELECT id, tipo_empresa, status, tem_adiantamento, funcionarios, analista_id
    FROM empresas
    WHERE status <> 'encerrado'
      AND (data_inicio IS NULL OR data_inicio <= (v_comp_start + interval '1 month - 1 day')::date)
      AND (data_fim IS NULL    OR data_fim >= v_comp_start)
  LOOP
    -- Busca o analista_id registrado na competencia imediatamente anterior
    -- a (p_mes, p_ano) para esta empresa. Isso garante que reatribuicoes
    -- feitas durante o mes anterior sejam preservadas, mesmo que
    -- empresas.analista_id esteja desatualizado ou NULL.
    SELECT ec.analista_id INTO v_prev_analista
    FROM empresa_competencia ec
    JOIN competencias c ON c.id = ec.competencia_id
    WHERE ec.empresa_id = v_emp.id
      AND (c.ano < p_ano OR (c.ano = p_ano AND c.mes < p_mes))
    ORDER BY c.ano DESC, c.mes DESC
    LIMIT 1;

    -- Fallback: empresa sem historico anterior (cadastro novo no mes corrente)
    -- usa o campo cadastral.
    v_prev_analista := COALESCE(v_prev_analista, v_emp.analista_id);

    INSERT INTO empresa_competencia
      (empresa_id, competencia_id, tem_movimento, tem_adiantamento, funcionarios, analista_id)
    VALUES (
      v_emp.id, v_comp_id,
      CASE WHEN v_emp.status = 'sem_movimento' THEN false ELSE true END,
      v_emp.tem_adiantamento,
      v_emp.funcionarios,
      v_prev_analista
    )
    ON CONFLICT (empresa_id, competencia_id) DO NOTHING;

    SELECT * INTO v_ec
    FROM empresa_competencia
    WHERE empresa_id = v_emp.id AND competencia_id = v_comp_id;

    FOR v_atv IN
      SELECT id, nome, grupo FROM atividades WHERE ativo = true ORDER BY ordem
    LOOP
      v_nt := false;

      IF v_emp.tipo_empresa = 'Domestica' AND (
            v_atv.nome ILIKE '%apontamento%'
         OR v_atv.nome ILIKE '%pr_via%'
         OR (v_atv.nome ILIKE '%ok%' AND v_atv.nome ILIKE '%cliente%')
         OR v_atv.nome ILIKE '%fgts%'
         OR v_atv.nome ILIKE '%provis%'
         OR v_atv.nome ILIKE '%sindic%'
         OR v_atv.nome ILIKE '%dctf%'
      ) THEN
        v_nt := true;

      ELSIF v_emp.tipo_empresa = 'Filial' AND NOT v_ec.tem_movimento THEN
        v_nt := true;

      ELSIF v_emp.tipo_empresa = 'Matriz' AND NOT v_ec.tem_movimento THEN
        IF v_atv.nome NOT ILIKE '%esocial%' AND v_atv.nome NOT ILIKE '%dctf%' THEN
          v_nt := true;
        END IF;

      ELSIF NOT v_ec.tem_adiantamento AND v_atv.grupo = 'adiantamento' THEN
        v_nt := true;

      ELSIF v_emp.tipo_empresa = 'Filial' AND (
            v_atv.nome ILIKE '%darf%'
         OR v_atv.nome ILIKE '%esocial%'
         OR v_atv.nome ILIKE '%dctf%'
      ) THEN
        v_nt := true;

      END IF;

      INSERT INTO entregas (competencia_id, empresa_id, atividade_id, nt, nao_ocorreu)
      VALUES (v_comp_id, v_emp.id, v_atv.id, v_nt, false)
      ON CONFLICT DO NOTHING;

    END LOOP;
  END LOOP;
END;
$function$;
