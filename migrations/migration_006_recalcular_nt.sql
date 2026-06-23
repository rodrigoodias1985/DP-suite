-- ============================================================
-- DP+ Suite — Migration 006: Recálculo de NT por mudança de movimento
-- Aplicar após migration_005_audit_empresa_competencia.sql
--
-- Problema corrigido: entregas.nt é gravado apenas uma vez, no momento
-- em que abrir_competencia() roda. Se tem_movimento muda DEPOIS (via
-- toggle na aba Carteira), as tarefas já criadas continuam com o nt
-- antigo — ficam bloqueadas mesmo a empresa tendo passado a ter
-- movimento (ou vice-versa).
--
-- Esta função espelha exatamente a mesma regra de nt usada em
-- abrir_competencia, mas roda sobre as entregas JÁ EXISTENTES da
-- competência (UPDATE, nunca INSERT/DELETE — não cria nem remove
-- nenhuma linha de entrega).
-- ============================================================

CREATE OR REPLACE FUNCTION public.recalcular_nt_empresa(
  p_empresa_id      uuid,
  p_competencia_id  uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tipo_empresa  public.tipo_empresa_t;
  v_tem_mov       boolean;
  v_tem_adian     boolean;
  v_atv           record;
  v_nt            boolean;
  v_perfil        public.perfil_usuario;
BEGIN
  -- Proteção de perfil: mesma regra de acesso da policy emp_comp_update
  -- (admin/gestor) — bloqueia chamada direta via console por analista.
  -- Verificação explícita de NULL: "NULL NOT IN (...)" avalia para NULL
  -- (não TRUE) em plpgsql, o que faria a exceção não disparar se o
  -- usuário não tivesse registro em public.usuarios.
  SELECT perfil INTO v_perfil FROM public.usuarios WHERE id = auth.uid();
  IF v_perfil IS NULL OR v_perfil NOT IN ('admin', 'gestor') THEN
    RAISE EXCEPTION 'Acesso negado: apenas admin ou gestor podem recalcular tarefas.';
  END IF;

  SELECT tipo_empresa INTO v_tipo_empresa
    FROM public.empresas WHERE id = p_empresa_id;

  SELECT tem_movimento, tem_adiantamento INTO v_tem_mov, v_tem_adian
    FROM public.empresa_competencia
   WHERE empresa_id = p_empresa_id AND competencia_id = p_competencia_id;

  -- Sem empresa ou sem registro mensal: nada a recalcular
  IF v_tipo_empresa IS NULL OR v_tem_mov IS NULL THEN
    RETURN;
  END IF;

  -- Itera apenas sobre as entregas JÁ EXISTENTES desta empresa+competência
  FOR v_atv IN
    SELECT a.id, a.nome, a.grupo
      FROM public.entregas e
      JOIN public.atividades a ON a.id = e.atividade_id
     WHERE e.empresa_id = p_empresa_id
       AND e.competencia_id = p_competencia_id
  LOOP
    v_nt := false;

    -- Regra idêntica à de abrir_competencia()
    IF v_tipo_empresa = 'Domestica' AND (
          v_atv.nome ILIKE '%apontamento%'
       OR v_atv.nome ILIKE '%pr_via%'
       OR (v_atv.nome ILIKE '%ok%' AND v_atv.nome ILIKE '%cliente%')
       OR v_atv.nome ILIKE '%fgts%'
       OR v_atv.nome ILIKE '%provis%'
       OR v_atv.nome ILIKE '%sindic%'
       OR v_atv.nome ILIKE '%dctf%'
    ) THEN
      v_nt := true;

    ELSIF v_tipo_empresa = 'Filial' AND NOT v_tem_mov THEN
      v_nt := true;

    ELSIF v_tipo_empresa = 'Matriz' AND NOT v_tem_mov THEN
      IF v_atv.nome NOT ILIKE '%esocial%' AND v_atv.nome NOT ILIKE '%dctf%' THEN
        v_nt := true;
      END IF;

    ELSIF NOT v_tem_adian AND v_atv.grupo = 'adiantamento' THEN
      v_nt := true;

    ELSIF v_tipo_empresa = 'Filial' AND (
          v_atv.nome ILIKE '%darf%'
       OR v_atv.nome ILIKE '%esocial%'
       OR v_atv.nome ILIKE '%dctf%'
    ) THEN
      v_nt := true;

    END IF;

    -- Só escreve se o valor realmente mudou (evita disparar o trigger
    -- de audit_log sem necessidade)
    UPDATE public.entregas
       SET nt = v_nt
     WHERE empresa_id = p_empresa_id
       AND competencia_id = p_competencia_id
       AND atividade_id = v_atv.id
       AND nt IS DISTINCT FROM v_nt;
  END LOOP;
END;
$$;

-- ============================================================
-- NOTA: data_conclusao e nao_ocorreu de entregas que passam a ser NT
-- não são apagados — ficam "órfãos" mas inofensivos, pois a interface
-- já trata qualquer linha com nt=true como "—" independentemente do
-- conteúdo, e checkCompConcluida() já filtra .eq('nt', false) no
-- cálculo de total/concluídas.
-- ============================================================
