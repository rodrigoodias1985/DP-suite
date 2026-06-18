-- ============================================================
-- DP+ Suite — Migration 002: Row Level Security + RPC check_comp_concluida
-- Aplicar no Supabase SQL Editor (produção)
-- Pré-requisito: migration 001_schema_completo.sql aplicado
-- ============================================================

-- ============================================================
-- SEÇÃO 1 — FUNÇÃO AUXILIAR DE PERFIL
-- Usada internamente pelas policies. STABLE = PostgreSQL cacheia
-- o resultado por transação, evitando N queries em selects grandes.
-- ============================================================

CREATE OR REPLACE FUNCTION public.meu_perfil()
RETURNS public.perfil_usuario
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT perfil FROM public.usuarios WHERE id = auth.uid()
$$;

-- ============================================================
-- SEÇÃO 2 — RPC: check_comp_concluida
-- Substitui as 3 queries + 2 UPDATEs diretos do cliente.
-- Qualquer perfil autenticado pode DISPARAR a verificação,
-- mas só o servidor decide se o status muda.
-- ============================================================

CREATE OR REPLACE FUNCTION public.check_comp_concluida(p_comp_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total        integer;
  v_done         integer;
  v_novo_status  text;
BEGIN
  -- Conta total de entregas aplicáveis (exclui NT)
  SELECT COUNT(*)
    INTO v_total
    FROM public.entregas
   WHERE competencia_id = p_comp_id
     AND nt = false;

  -- Sem entregas aplicáveis: nada a fazer
  IF v_total = 0 THEN
    RETURN jsonb_build_object('status', 'sem_atividades', 'total', 0, 'done', 0);
  END IF;

  -- Conta concluídas (data preenchida OU marcado como não ocorreu)
  SELECT COUNT(*)
    INTO v_done
    FROM public.entregas
   WHERE competencia_id = p_comp_id
     AND nt = false
     AND (data_conclusao IS NOT NULL OR nao_ocorreu = true);

  -- Atualiza status conforme resultado
  IF v_done >= v_total THEN
    UPDATE public.competencias
       SET status = 'concluida'
     WHERE id = p_comp_id;
    v_novo_status := 'concluida';
  ELSE
    -- Só reverte se estava concluída (evita update desnecessário)
    UPDATE public.competencias
       SET status = 'aberta'
     WHERE id = p_comp_id
       AND status = 'concluida';
    v_novo_status := 'aberta';
  END IF;

  RETURN jsonb_build_object(
    'status', v_novo_status,
    'total',  v_total,
    'done',   v_done
  );
END;
$$;

-- ============================================================
-- SEÇÃO 3 — ATIVAR RLS EM TODAS AS TABELAS
-- ============================================================

ALTER TABLE public.usuarios           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.atividades         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.empresas           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.competencias       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.empresa_atividades ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.empresa_competencia ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.entregas           ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- SEÇÃO 4 — POLICIES: usuarios
-- analista: apenas o próprio registro
-- admin/gestor: todos os registros
-- INSERT/DELETE: bloqueado (gerenciado via registro_usuarios_tool)
-- ============================================================

CREATE POLICY "usuarios_select"
  ON public.usuarios FOR SELECT
  USING (
    auth.uid() = id
    OR meu_perfil() IN ('admin', 'gestor')
  );

CREATE POLICY "usuarios_update"
  ON public.usuarios FOR UPDATE
  USING (
    auth.uid() = id
    OR meu_perfil() = 'admin'
  );

-- ============================================================
-- SEÇÃO 5 — POLICIES: atividades
-- Leitura: todos os perfis autenticados
-- Escrita: somente admin
-- ============================================================

CREATE POLICY "atividades_select"
  ON public.atividades FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY "atividades_insert"
  ON public.atividades FOR INSERT
  WITH CHECK (meu_perfil() = 'admin');

CREATE POLICY "atividades_update"
  ON public.atividades FOR UPDATE
  USING (meu_perfil() = 'admin');

CREATE POLICY "atividades_delete"
  ON public.atividades FOR DELETE
  USING (meu_perfil() = 'admin');

-- ============================================================
-- SEÇÃO 6 — POLICIES: empresas
-- analista: apenas empresas atribuídas (via analista_id direto
--           OU via empresa_competencia para histórico)
-- gestor: leitura e atribuição em lote (UPDATE)
-- admin: acesso total
-- ============================================================

CREATE POLICY "empresas_select"
  ON public.empresas FOR SELECT
  USING (
    meu_perfil() IN ('admin', 'gestor')
    OR analista_id = auth.uid()
    OR id IN (
      SELECT empresa_id
        FROM public.empresa_competencia
       WHERE analista_id = auth.uid()
    )
  );

CREATE POLICY "empresas_insert"
  ON public.empresas FOR INSERT
  WITH CHECK (meu_perfil() = 'admin');

CREATE POLICY "empresas_update"
  ON public.empresas FOR UPDATE
  USING (meu_perfil() IN ('admin', 'gestor'));

CREATE POLICY "empresas_delete"
  ON public.empresas FOR DELETE
  USING (meu_perfil() = 'admin');

-- ============================================================
-- SEÇÃO 7 — POLICIES: competencias
-- SELECT: todos os perfis (precisam ver a competência ativa)
-- INSERT/UPDATE/DELETE: somente admin
-- NOTA: updates de status (concluida/aberta) passam pela RPC
--       check_comp_concluida (SECURITY DEFINER), não diretamente.
--       abrir_competencia e excluir_competencia são SECURITY DEFINER
--       e também bypassam esta policy.
-- ============================================================

CREATE POLICY "competencias_select"
  ON public.competencias FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY "competencias_insert"
  ON public.competencias FOR INSERT
  WITH CHECK (meu_perfil() = 'admin');

CREATE POLICY "competencias_update"
  ON public.competencias FOR UPDATE
  USING (meu_perfil() = 'admin');

CREATE POLICY "competencias_delete"
  ON public.competencias FOR DELETE
  USING (meu_perfil() = 'admin');

-- ============================================================
-- SEÇÃO 8 — POLICIES: empresa_atividades
-- SELECT: todos (analista precisa para calcular NTs)
-- Escrita: somente admin
-- ============================================================

CREATE POLICY "emp_atv_select"
  ON public.empresa_atividades FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY "emp_atv_insert"
  ON public.empresa_atividades FOR INSERT
  WITH CHECK (meu_perfil() = 'admin');

CREATE POLICY "emp_atv_update"
  ON public.empresa_atividades FOR UPDATE
  USING (meu_perfil() = 'admin');

CREATE POLICY "emp_atv_delete"
  ON public.empresa_atividades FOR DELETE
  USING (meu_perfil() = 'admin');

-- ============================================================
-- SEÇÃO 9 — POLICIES: empresa_competencia
-- analista: apenas registros onde é o analista responsável
-- gestor: leitura total + update (atribuição em lote)
-- admin: acesso total
-- INSERT: admin (importações em lote) +
--         abrir_competencia RPC (SECURITY DEFINER, bypassa policy)
-- ============================================================

CREATE POLICY "emp_comp_select"
  ON public.empresa_competencia FOR SELECT
  USING (
    meu_perfil() IN ('admin', 'gestor')
    OR analista_id = auth.uid()
  );

CREATE POLICY "emp_comp_insert"
  ON public.empresa_competencia FOR INSERT
  WITH CHECK (meu_perfil() IN ('admin', 'gestor'));

CREATE POLICY "emp_comp_update"
  ON public.empresa_competencia FOR UPDATE
  USING (meu_perfil() IN ('admin', 'gestor'));

CREATE POLICY "emp_comp_delete"
  ON public.empresa_competencia FOR DELETE
  USING (meu_perfil() = 'admin');

-- ============================================================
-- SEÇÃO 10 — POLICIES: entregas
-- analista: lê e atualiza apenas entregas de empresas suas
-- gestor: leitura total + update
-- admin: acesso total
-- INSERT: bloqueado diretamente — feito via abrir_competencia RPC
-- DELETE: somente admin — feito via excluir_competencia RPC
-- ============================================================

CREATE POLICY "entregas_select"
  ON public.entregas FOR SELECT
  USING (
    meu_perfil() IN ('admin', 'gestor')
    OR empresa_id IN (
      SELECT id FROM public.empresas WHERE analista_id = auth.uid()
      UNION
      SELECT empresa_id FROM public.empresa_competencia WHERE analista_id = auth.uid()
    )
  );

CREATE POLICY "entregas_update"
  ON public.entregas FOR UPDATE
  USING (
    meu_perfil() IN ('admin', 'gestor')
    OR empresa_id IN (
      SELECT id FROM public.empresas WHERE analista_id = auth.uid()
      UNION
      SELECT empresa_id FROM public.empresa_competencia WHERE analista_id = auth.uid()
    )
  );

CREATE POLICY "entregas_insert"
  ON public.entregas FOR INSERT
  WITH CHECK (meu_perfil() = 'admin');

CREATE POLICY "entregas_delete"
  ON public.entregas FOR DELETE
  USING (meu_perfil() = 'admin');

-- ============================================================
-- NOTA SOBRE abrir_competencia E excluir_competencia
-- ============================================================
-- Essas funções são SECURITY DEFINER (criadas em migrations anteriores)
-- e bypassam RLS ao executar. Elas continuam funcionando normalmente.
--
-- Recomendação: adicionar no início de cada uma a verificação:
--
--   IF (SELECT perfil FROM public.usuarios WHERE id = auth.uid()) <> 'admin' THEN
--     RAISE EXCEPTION 'Acesso negado: apenas admin pode executar esta operação.';
--   END IF;
--
-- Isso adiciona verificação de perfil dentro da própria função,
-- impedindo que um gestor ou analista chame a RPC via console/API.
-- ============================================================
