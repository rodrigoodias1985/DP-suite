-- ============================================================
-- DP+ Suite - migration_012_cancelamento_e_pipeline.sql
-- Modulo Rescisoes: cancelamento reversivel + pipeline flexivel
--
-- Aplicar apos migration_011_remove_cpf.sql
--
-- NATUREZA: aditiva. Duas mudancas independentes, agrupadas na mesma
-- migration por serem do mesmo tema (fluxo de trabalho) e terem sido
-- decididas na mesma sessao:
--   PARTE A - cancelamento como atributo independente do status
--   PARTE B - remove a restricao "avanca 1 etapa por vez"
--
-- DECISOES CONFIRMADAS COM RODRIGO NESTA SESSAO:
--   - Cancelamento e REVERSIVEL (reabrir_rescisao)
--   - Quem cancela/reabre: analista responsavel, gestor ou admin
--     (mesmo criterio ja usado em atualizar_status_rescisao e
--     concluir_tarefa_rescisao - NAO reinventado aqui)
--   - Rescisoes canceladas ficam OCULTAS por padrao na listagem
--     (implementado no frontend - rescisoes.html - nao no banco)
--
-- DECISOES NAO CONFIRMADAS (assumidas com bom senso, sinalizadas
-- para revisao):
--   - Nao e possivel cancelar uma rescisao ja 'finalizada'
--   - Nao e possivel cancelar uma rescisao ja cancelada (idempotencia
--     de intencao, nao de execucao SQL)
--   - Motivo do cancelamento e OBRIGATORIO
--   - Reabrir LIMPA motivo/data/autor do cancelamento anterior (nao
--     mantém historico de ciclos cancelar->reabrir->cancelar; se no
--     futuro isso for necessario, exige tabela dedicada)
-- ============================================================


-- ============================================================
-- PARTE A — CANCELAMENTO
-- ============================================================

-- ------------------------------------------------------------
-- A.1 Colunas novas em rs_rescisoes
--
-- Deliberadamente FORA do pipeline de status (coluna `status`
-- continua representando so a etapa do processo). Cancelamento e
-- ortogonal: pode acontecer a partir de qualquer etapa, e a rescisao
-- mantem o status de onde parou ao ser cancelada/reaberta.
-- ------------------------------------------------------------

ALTER TABLE public.rs_rescisoes
  ADD COLUMN IF NOT EXISTS cancelada             boolean     NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS motivo_cancelamento    text,
  ADD COLUMN IF NOT EXISTS cancelada_em           timestamptz,
  ADD COLUMN IF NOT EXISTS cancelada_por          uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'rs_rescisoes_cancelada_por_fkey'
  ) THEN
    ALTER TABLE public.rs_rescisoes
      ADD CONSTRAINT rs_rescisoes_cancelada_por_fkey
      FOREIGN KEY (cancelada_por) REFERENCES public.usuarios(id);
  END IF;
END$$;

-- Coerencia: campos de cancelamento so fazem sentido preenchidos
-- juntos com cancelada = true. Espelha o padrao ja usado em
-- rs_tarefas_conclusao_coerente (migration_008).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'rs_rescisoes_cancelamento_coerente'
  ) THEN
    ALTER TABLE public.rs_rescisoes
      ADD CONSTRAINT rs_rescisoes_cancelamento_coerente CHECK (
        (cancelada = false AND motivo_cancelamento IS NULL
                           AND cancelada_em IS NULL AND cancelada_por IS NULL)
        OR
        (cancelada = true AND motivo_cancelamento IS NOT NULL
                          AND cancelada_em IS NOT NULL AND cancelada_por IS NOT NULL)
      );
  END IF;
END$$;

-- Indice parcial: listagem "ocultar canceladas" e o caso de uso mais
-- frequente (default do frontend). Filtro `WHERE NOT cancelada`.
CREATE INDEX IF NOT EXISTS idx_rs_rescisoes_nao_canceladas
  ON public.rs_rescisoes (id) WHERE cancelada = false;

-- IMPORTANTE: as 4 colunas novas NAO entram no GRANT UPDATE de
-- authenticated (migration_009, secao 4). Colunas novas nascem sem
-- privilegio de UPDATE por padrao (comportamento ja documentado) -
-- e e exatamente o que queremos aqui: cancelar/reabrir so pelas RPCs
-- abaixo, nunca por UPDATE direto via PostgREST.


-- ------------------------------------------------------------
-- A.2 RPC cancelar_rescisao
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.cancelar_rescisao(
  p_rescisao_id uuid,
  p_motivo      text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid         uuid;
  v_perfil      perfil_usuario;
  v_ativo       boolean;
  v_analista_id uuid;
  v_status      rs_status_rescisao_t;
  v_cancelada   boolean;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Usuario nao autenticado.';
  END IF;

  SELECT perfil, ativo INTO v_perfil, v_ativo FROM usuarios WHERE id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Usuario sem cadastro no sistema.'; END IF;
  IF NOT v_ativo THEN RAISE EXCEPTION 'Conta inativa. Contate o administrador.'; END IF;

  IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
    RAISE EXCEPTION 'Motivo do cancelamento e obrigatorio.';
  END IF;

  SELECT analista_id, status, cancelada INTO v_analista_id, v_status, v_cancelada
  FROM rs_rescisoes WHERE id = p_rescisao_id FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Rescisao nao encontrada.'; END IF;

  -- Mesmo criterio de autorizacao de atualizar_status_rescisao e
  -- concluir_tarefa_rescisao (migration_010) - nao reinventado aqui.
  IF v_perfil = 'analista' AND v_analista_id <> v_uid THEN
    RAISE EXCEPTION 'Apenas o analista responsavel, gestor ou admin podem cancelar.';
  END IF;

  IF v_cancelada THEN
    RAISE EXCEPTION 'Rescisao ja esta cancelada.';
  END IF;

  IF v_status = 'finalizada' THEN
    RAISE EXCEPTION 'Nao e possivel cancelar uma rescisao ja finalizada.';
  END IF;

  UPDATE rs_rescisoes
  SET cancelada = true,
      motivo_cancelamento = btrim(p_motivo),
      cancelada_em = now(),
      cancelada_por = v_uid
  WHERE id = p_rescisao_id;
END;
$function$;


-- ------------------------------------------------------------
-- A.3 RPC reabrir_rescisao
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.reabrir_rescisao(
  p_rescisao_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid         uuid;
  v_perfil      perfil_usuario;
  v_ativo       boolean;
  v_analista_id uuid;
  v_cancelada   boolean;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Usuario nao autenticado.';
  END IF;

  SELECT perfil, ativo INTO v_perfil, v_ativo FROM usuarios WHERE id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Usuario sem cadastro no sistema.'; END IF;
  IF NOT v_ativo THEN RAISE EXCEPTION 'Conta inativa. Contate o administrador.'; END IF;

  SELECT analista_id, cancelada INTO v_analista_id, v_cancelada
  FROM rs_rescisoes WHERE id = p_rescisao_id FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Rescisao nao encontrada.'; END IF;

  IF v_perfil = 'analista' AND v_analista_id <> v_uid THEN
    RAISE EXCEPTION 'Apenas o analista responsavel, gestor ou admin podem reabrir.';
  END IF;

  IF NOT v_cancelada THEN
    RAISE EXCEPTION 'Rescisao nao esta cancelada.';
  END IF;

  UPDATE rs_rescisoes
  SET cancelada = false,
      motivo_cancelamento = NULL,
      cancelada_em = NULL,
      cancelada_por = NULL
  WHERE id = p_rescisao_id;
END;
$function$;


-- ------------------------------------------------------------
-- A.4 Privilegios de execucao
-- ------------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.cancelar_rescisao(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancelar_rescisao(uuid, text) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.reabrir_rescisao(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reabrir_rescisao(uuid) TO authenticated;


-- ============================================================
-- PARTE B — PIPELINE FLEXIVEL (remove "avanca 1 etapa por vez")
--
-- Motivo (confirmado por Rodrigo): o fluxo real tem ramificacao a
-- partir de 'em_conferencia' - o cliente pode aprovar direto
-- (-> 'aprovada') OU pedir ajuste (-> 'aguardando_cliente'). A
-- restricao de avanco linear impedia o primeiro caminho. Simetria
-- com o retrocesso, que ja e livre desde a migration_010.
--
-- Corpo identico ao original (migration_010), MENOS o bloco
-- >>> AVANCO PASSO A PASSO <<<, que o proprio comentario original
-- ja sinalizava como removivel.
-- ============================================================

CREATE OR REPLACE FUNCTION public.atualizar_status_rescisao(
  p_rescisao_id uuid,
  p_status_novo public.rs_status_rescisao_t,
  p_observacao  text DEFAULT NULL
)
RETURNS public.rs_status_rescisao_t
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid           uuid;
  v_perfil        perfil_usuario;
  v_ativo         boolean;
  v_analista_id   uuid;
  v_status_atual  rs_status_rescisao_t;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Usuario nao autenticado.';
  END IF;

  SELECT perfil, ativo INTO v_perfil, v_ativo FROM usuarios WHERE id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Usuario sem cadastro no sistema.'; END IF;
  IF NOT v_ativo THEN RAISE EXCEPTION 'Conta inativa. Contate o administrador.'; END IF;

  IF p_status_novo IS NULL THEN
    RAISE EXCEPTION 'Status de destino e obrigatorio.';
  END IF;

  SELECT analista_id, status INTO v_analista_id, v_status_atual
  FROM rs_rescisoes WHERE id = p_rescisao_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Rescisao nao encontrada.';
  END IF;

  IF v_perfil = 'analista' AND v_analista_id <> v_uid THEN
    RAISE EXCEPTION 'Apenas o analista responsavel, gestor ou admin podem alterar o status.';
  END IF;

  IF p_status_novo = v_status_atual THEN
    RAISE EXCEPTION 'A rescisao ja esta no status "%".', p_status_novo;
  END IF;

  -- Bloco de restricao de avanco linear REMOVIDO nesta migration.
  -- Transicao para qualquer status, em qualquer direcao, e permitida
  -- (mesma liberdade que o retrocesso ja tinha).

  UPDATE rs_rescisoes SET status = p_status_novo WHERE id = p_rescisao_id;

  INSERT INTO rs_historico (rescisao_id, status_anterior, status_novo, usuario_id, observacao)
  VALUES (p_rescisao_id, v_status_atual, p_status_novo, v_uid,
          nullif(btrim(coalesce(p_observacao, '')), ''));

  RETURN p_status_novo;
END;
$function$;

-- Assinatura identica a original - sem DROP FUNCTION necessario.
REVOKE EXECUTE ON FUNCTION public.atualizar_status_rescisao(uuid,
  public.rs_status_rescisao_t, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.atualizar_status_rescisao(uuid,
  public.rs_status_rescisao_t, text) TO authenticated;


-- ============================================================
-- VERIFICACAO POS-APLICACAO
-- ============================================================

-- V1. Colunas novas presentes em rs_rescisoes
-- SELECT column_name, data_type, is_nullable, column_default
-- FROM information_schema.columns
-- WHERE table_schema = 'public' AND table_name = 'rs_rescisoes'
--   AND column_name IN ('cancelada','motivo_cancelamento','cancelada_em','cancelada_por')
-- ORDER BY column_name;

-- V2. Constraints novas aplicadas
-- SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
-- WHERE conrelid = 'public.rs_rescisoes'::regclass
--   AND conname IN ('rs_rescisoes_cancelada_por_fkey','rs_rescisoes_cancelamento_coerente');

-- V3. Nenhuma das 4 colunas novas tem UPDATE liberado para authenticated
-- (esperado: ZERO linhas)
-- SELECT column_name FROM information_schema.column_privileges
-- WHERE table_schema = 'public' AND table_name = 'rs_rescisoes'
--   AND grantee = 'authenticated' AND privilege_type = 'UPDATE'
--   AND column_name IN ('cancelada','motivo_cancelamento','cancelada_em','cancelada_por');

-- V4. RPCs novas criadas e com EXECUTE correto
-- SELECT p.proname,
--        has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_ok,
--        has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_ok
-- FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
-- WHERE n.nspname = 'public' AND p.proname IN ('cancelar_rescisao','reabrir_rescisao')
-- ORDER BY p.proname;
-- Esperado: auth_ok = true, anon_ok = false nas 2.

-- V5. atualizar_status_rescisao permite pular etapa (teste em transacao
-- abortada - nao grava nada de verdade)
-- BEGIN;
--   -- Substituir 'ID-DE-TESTE' por uma rescisao real em status 'em_conferencia'
--   SELECT atualizar_status_rescisao('ID-DE-TESTE'::uuid, 'aprovada', 'teste de pulo de etapa');
--   SELECT status FROM rs_rescisoes WHERE id = 'ID-DE-TESTE'::uuid;
-- ROLLBACK;
-- Esperado: retorna 'aprovada' sem lancar excecao de "nao e possivel pular etapas".

-- V6. Controle e demais tabelas rs_ intactos
-- SELECT 'empresas' t, count(*) FROM empresas
-- UNION ALL SELECT 'entregas', count(*) FROM entregas
-- UNION ALL SELECT 'rs_rescisoes', count(*) FROM rs_rescisoes
-- UNION ALL SELECT 'rs_tarefas', count(*) FROM rs_tarefas;


-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS public.cancelar_rescisao(uuid, text);
-- DROP FUNCTION IF EXISTS public.reabrir_rescisao(uuid);
-- ALTER TABLE public.rs_rescisoes DROP CONSTRAINT IF EXISTS rs_rescisoes_cancelamento_coerente;
-- ALTER TABLE public.rs_rescisoes DROP CONSTRAINT IF EXISTS rs_rescisoes_cancelada_por_fkey;
-- DROP INDEX IF EXISTS idx_rs_rescisoes_nao_canceladas;
-- ALTER TABLE public.rs_rescisoes DROP COLUMN IF EXISTS cancelada_por;
-- ALTER TABLE public.rs_rescisoes DROP COLUMN IF EXISTS cancelada_em;
-- ALTER TABLE public.rs_rescisoes DROP COLUMN IF EXISTS motivo_cancelamento;
-- ALTER TABLE public.rs_rescisoes DROP COLUMN IF EXISTS cancelada;
-- -- atualizar_status_rescisao: para reverter ao comportamento linear,
-- -- reaplicar o CREATE OR REPLACE original da migration_010 (secao 2).

-- ============================================================
-- FIM migration_012_cancelamento_e_pipeline.sql
-- ============================================================
