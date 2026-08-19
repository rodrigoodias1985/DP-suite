-- ============================================================
-- DP+ Suite - migration_011_remove_cpf.sql
-- Modulo Rescisoes: remove o campo CPF do cadastro
--
-- Aplicar apos migration_010_rescisoes_rpcs.sql
--
-- MOTIVO: CPF nao e utilizado em nenhuma regra de negocio das RPCs
-- do modulo (prazo, checklist, status). Mante-lo e coleta de dado
-- sensivel sem finalidade documentada - contraria o principio de
-- minimizacao da LGPD. Decisao tomada com o modulo ainda vazio
-- (nenhuma rescisao cadastrada), portanto sem perda de dado real.
--
-- NATUREZA: remove coluna + constraint associada em rs_rescisoes e
-- recria abrir_rescisao sem o parametro p_cpf. Nao toca em
-- rs_tarefas, rs_historico, nem em nenhuma funcao/tabela do modulo
-- Controle.
--
-- ATENCAO - NAO IDEMPOTENTE DA FORMA CLASSICA DO PROJETO: DROP COLUMN
-- e destrutivo por natureza. Os IF EXISTS abaixo garantem que
-- reexecutar a migration nao quebra (nao falha se coluna/constraint
-- ja tiverem sido removidas), mas isso NAO E reversivel sem restaurar
-- dado a partir de backup - so seguro aplicar porque a tabela esta
-- vazia (confirmado por Rodrigo antes desta migration).
-- ============================================================


-- ============================================================
-- 1. abrir_rescisao - recriar sem p_cpf
--
-- Assinatura muda de 10 para 9 parametros. Como o modulo ainda nao
-- tem frontend (rescisoes.html sera construido depois desta
-- migration), nao ha chamador existente para quebrar.
-- ============================================================

DROP FUNCTION IF EXISTS public.abrir_rescisao(uuid, uuid, text, text,
  public.rs_tipo_rescisao_t, public.rs_tipo_aviso_t, date, date, date, text);

CREATE OR REPLACE FUNCTION public.abrir_rescisao(
  p_empresa_id                    uuid,
  p_analista_id                   uuid,
  p_funcionario_nome              text,
  p_tipo_rescisao                 public.rs_tipo_rescisao_t,
  p_tipo_aviso                    public.rs_tipo_aviso_t,
  p_data_rescisao                 date,
  p_data_solicitacao              date DEFAULT CURRENT_DATE,
  p_data_recebimento_apontamentos date DEFAULT NULL,
  p_observacoes                   text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid          uuid;
  v_perfil       perfil_usuario;
  v_ativo        boolean;
  v_prazo        date;
  v_rescisao_id  uuid;
  v_na_carteira  boolean;
BEGIN
  -- ---------- Autenticacao ----------
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Usuario nao autenticado.';
  END IF;

  SELECT perfil, ativo INTO v_perfil, v_ativo
  FROM usuarios WHERE id = v_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Usuario sem cadastro no sistema.';
  END IF;

  IF NOT v_ativo THEN
    RAISE EXCEPTION 'Conta inativa. Contate o administrador.';
  END IF;

  -- ---------- Validacao de parametros ----------
  IF p_empresa_id IS NULL OR p_analista_id IS NULL THEN
    RAISE EXCEPTION 'Empresa e analista responsavel sao obrigatorios.';
  END IF;

  IF p_funcionario_nome IS NULL OR btrim(p_funcionario_nome) = '' THEN
    RAISE EXCEPTION 'Nome do funcionario e obrigatorio.';
  END IF;

  IF p_data_rescisao IS NULL THEN
    RAISE EXCEPTION 'Data da rescisao e obrigatoria.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM empresas WHERE id = p_empresa_id) THEN
    RAISE EXCEPTION 'Empresa nao encontrada.';
  END IF;
  -- Empresa encerrada NAO bloqueia: rescisao de empresa em encerramento
  -- e cenario legitimo. O aviso e responsabilidade da UI (rescisoes.html).

  IF NOT EXISTS (SELECT 1 FROM usuarios WHERE id = p_analista_id AND ativo = true) THEN
    RAISE EXCEPTION 'Analista responsavel invalido ou inativo.';
  END IF;

  -- ---------- Autorizacao ----------
  IF v_perfil = 'analista' THEN
    -- Analista so abre rescisao para empresa da propria carteira
    -- (mesma expressao de visibilidade da migration_009: vinculo
    -- cadastral OU historico).
    SELECT EXISTS (
      SELECT 1 FROM empresas e
      WHERE e.id = p_empresa_id AND e.analista_id = v_uid
      UNION
      SELECT 1 FROM empresa_competencia ec
      WHERE ec.empresa_id = p_empresa_id AND ec.analista_id = v_uid
    ) INTO v_na_carteira;

    IF NOT v_na_carteira THEN
      RAISE EXCEPTION 'Empresa fora da sua carteira.';
    END IF;

    IF p_analista_id <> v_uid THEN
      RAISE EXCEPTION 'Analista so pode abrir rescisao sob sua propria responsabilidade.';
    END IF;
  END IF;
  -- gestor e admin: sem restricao de empresa ou de responsavel.

  -- ---------- Prazo de pagamento ----------
  -- data_rescisao + 9, recuado para sexta se cair no fim de semana.
  -- EXTRACT(DOW): 0 = domingo ... 6 = sabado.
  v_prazo := p_data_rescisao + 9;
  v_prazo := CASE EXTRACT(DOW FROM v_prazo)
               WHEN 6 THEN v_prazo - 1   -- sabado  -> sexta
               WHEN 0 THEN v_prazo - 2   -- domingo -> sexta
               ELSE v_prazo
             END;

  -- ---------- Rescisao ----------
  INSERT INTO rs_rescisoes (
    empresa_id, analista_id, criado_por,
    funcionario_nome,
    tipo_rescisao, tipo_aviso,
    data_solicitacao, data_recebimento_apontamentos,
    data_rescisao, prazo_pagamento,
    status, observacoes
  ) VALUES (
    p_empresa_id, p_analista_id, v_uid,
    btrim(p_funcionario_nome),
    p_tipo_rescisao, p_tipo_aviso,
    coalesce(p_data_solicitacao, CURRENT_DATE), p_data_recebimento_apontamentos,
    p_data_rescisao, v_prazo,
    'solicitada', nullif(btrim(coalesce(p_observacoes, '')), '')
  )
  RETURNING id INTO v_rescisao_id;

  -- ---------- Checklist (matriz por tipo de rescisao) ----------
  -- Bloco identico ao da migration_010 (nao usa cpf em nada) - copiado
  -- verbatim, nao reescrito de memoria.
  -- enum_range devolve os valores na ordem de declaracao do ENUM;
  -- WITH ORDINALITY preserva essa ordem; o WHERE e aplicado ANTES da
  -- window function, entao row_number() renumera 1..N so o que sobrou.
  INSERT INTO rs_tarefas (rescisao_id, tipo_tarefa, ordem)
  SELECT v_rescisao_id, t.tipo, row_number() OVER (ORDER BY t.ord)
  FROM unnest(enum_range(NULL::rs_tipo_tarefa_t)) WITH ORDINALITY AS t(tipo, ord)
  WHERE CASE t.tipo
          -- Todos os tipos
          WHEN 'calculo_trct'                 THEN true
          WHEN 'esocial_s2299'                THEN true
          WHEN 'recibo_quitacao_trct'         THEN true
          -- Aviso previo
          WHEN 'aviso_previo'                 THEN p_tipo_rescisao IN
                 ('sem_justa_causa','pedido_demissao','acordo_mutuo')
          -- GRRF
          WHEN 'grrf_multa_40'                THEN p_tipo_rescisao IN
                 ('sem_justa_causa','antecipacao_empregador')
          WHEN 'grrf_multa_20'                THEN p_tipo_rescisao = 'acordo_mutuo'
          WHEN 'grrf_fgts_mensal'             THEN p_tipo_rescisao = 'termino_prazo'
          -- Seguro-desemprego
          WHEN 'formulario_seguro_desemprego' THEN p_tipo_rescisao IN
                 ('sem_justa_causa','acordo_mutuo')
          -- Documentos especificos
          WHEN 'termo_acordo_mutuo'           THEN p_tipo_rescisao = 'acordo_mutuo'
          WHEN 'indenizacao_art479'           THEN p_tipo_rescisao = 'antecipacao_empregador'
          WHEN 'indenizacao_art480'           THEN p_tipo_rescisao = 'antecipacao_empregado'
          WHEN 'documentacao_justa_causa'     THEN p_tipo_rescisao = 'justa_causa'
          ELSE false
        END
  ON CONFLICT (rescisao_id, tipo_tarefa) DO NOTHING;

  -- ---------- Historico inicial ----------
  INSERT INTO rs_historico (rescisao_id, status_anterior, status_novo, usuario_id, observacao)
  VALUES (v_rescisao_id, NULL, 'solicitada', v_uid, 'Rescisao cadastrada.');

  RETURN v_rescisao_id;
END;
$function$;


-- ============================================================
-- 2. Privilegios de execucao - nova assinatura (9 parametros)
-- ============================================================

REVOKE EXECUTE ON FUNCTION public.abrir_rescisao(uuid, uuid, text,
  public.rs_tipo_rescisao_t, public.rs_tipo_aviso_t, date, date, date, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.abrir_rescisao(uuid, uuid, text,
  public.rs_tipo_rescisao_t, public.rs_tipo_aviso_t, date, date, date, text)
  TO authenticated;


-- ============================================================
-- 3. Tabela rs_rescisoes - remover constraint e coluna
--
-- Ordem: constraint primeiro, depois coluna (DROP COLUMN removeria a
-- constraint junto de qualquer forma, mas explicito e mais claro para
-- auditoria futura do que foi removido e por que).
-- ============================================================

ALTER TABLE public.rs_rescisoes
  DROP CONSTRAINT IF EXISTS rs_rescisoes_cpf_formato;

ALTER TABLE public.rs_rescisoes
  DROP COLUMN IF EXISTS cpf;

-- NOTA: o GRANT UPDATE (cpf) concedido na migration_009 nao precisa de
-- REVOKE explicito - privilegio de coluna desaparece automaticamente
-- quando a coluna e removida.


-- ============================================================
-- 4. VERIFICACAO POS-APLICACAO
-- Rodar apos o commit para confirmar o resultado.
-- ============================================================

-- 4.1 Coluna cpf nao existe mais
-- SELECT column_name FROM information_schema.columns
-- WHERE table_schema = 'public' AND table_name = 'rs_rescisoes'
-- ORDER BY ordinal_position;
-- Esperado: sem "cpf" na lista.

-- 4.2 Constraint removida
-- SELECT conname FROM pg_constraint
-- WHERE conrelid = 'public.rs_rescisoes'::regclass;
-- Esperado: sem "rs_rescisoes_cpf_formato".

-- 4.3 Nova assinatura da funcao (9 parametros, sem p_cpf)
-- SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
-- FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
-- WHERE n.nspname = 'public' AND p.proname = 'abrir_rescisao';

-- 4.4 EXECUTE ok para authenticated, negado para anon
-- SELECT has_function_privilege('authenticated', 'public.abrir_rescisao(uuid, uuid, text, public.rs_tipo_rescisao_t, public.rs_tipo_aviso_t, date, date, date, text)', 'EXECUTE') AS auth_ok,
--        has_function_privilege('anon', 'public.abrir_rescisao(uuid, uuid, text, public.rs_tipo_rescisao_t, public.rs_tipo_aviso_t, date, date, date, text)', 'EXECUTE') AS anon_ok;
-- Esperado: auth_ok = true, anon_ok = false.

-- 4.5 Modulo Controle e demais tabelas rs_ intactos
-- SELECT 'empresas' t, count(*) FROM empresas
-- UNION ALL SELECT 'entregas', count(*) FROM entregas
-- UNION ALL SELECT 'rs_rescisoes', count(*) FROM rs_rescisoes
-- UNION ALL SELECT 'rs_tarefas', count(*) FROM rs_tarefas;
-- Esperado: rs_rescisoes e rs_tarefas em 0 (modulo ainda vazio).


-- ============================================================
-- 5. ROLLBACK
--
-- Restaura a coluna e a constraint. NAO restaura a funcao antiga com
-- p_cpf automaticamente - se precisar reverter de fato, reaplicar o
-- bloco 1 da migration_010 original.
-- ============================================================
-- ALTER TABLE public.rs_rescisoes ADD COLUMN cpf text;
-- ALTER TABLE public.rs_rescisoes ADD CONSTRAINT rs_rescisoes_cpf_formato CHECK (
--   cpf IS NULL OR length(regexp_replace(cpf, '\D', '', 'g')) = 11
-- );

-- ============================================================
-- FIM migration_011_remove_cpf.sql
-- ============================================================
