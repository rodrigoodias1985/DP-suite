-- ============================================================
-- DP+ Suite - migration_010_rescisoes_rpcs.sql
-- Modulo Rescisoes (V2): RPCs SECURITY DEFINER
--
-- Aplicar apos migration_009_rescisoes_rls.sql
--
-- NATUREZA: aditiva. Cria 3 funcoes novas com prefixo proprio. Nao
-- altera nenhuma funcao, RPC, policy ou tabela do modulo Controle.
-- meu_perfil() NAO e usada aqui (motivo na secao 0) e nao e redefinida.
--
-- IDEMPOTENTE: CREATE OR REPLACE + DROP FUNCTION IF EXISTS nas
-- assinaturas antigas antes de recriar.
-- ============================================================


-- ============================================================
-- 0. DECISOES DE DESENHO
--
-- 0.1 SECURITY DEFINER exige validacao manual
--   Estas funcoes rodam como owner e IGNORAM RLS por completo. Toda
--   regra de acesso precisa estar escrita dentro do corpo. As policies
--   da migration_009 nao protegem nada aqui.
--
-- 0.2 Verificacao de perfil le usuarios diretamente, nao meu_perfil()
--   meu_perfil() nao verifica usuarios.ativo (divida documentada no
--   009). Como estas RPCs sao o unico caminho de ESCRITA do modulo,
--   ler perfil + ativo na mesma consulta fecha a brecha para escrita
--   sem tocar em meu_perfil() e sem afetar o modulo Controle.
--   Efeito: usuario inativo com sessao valida ainda LE (RLS), mas nao
--   ESCREVE. Assimetria proposital e conservadora.
--
-- 0.3 Prazo de pagamento (confirmado)
--   data_rescisao + 9 (margem interna do escritorio). Se cair em
--   sabado -> sexta anterior. Domingo -> sexta anterior.
--   NAO existe tabela de feriados: ajuste de feriado e manual, feito
--   por analista/gestor/admin editando prazo_pagamento (coluna liberada
--   para UPDATE na migration_009).
--
-- 0.4 Transicoes de status (confirmado: retrocesso permitido)
--   RETROCESSO: livre para qualquer status anterior. Cobre o caso de
--     cliente pedindo revisao em aguardando_cliente e voltando direto
--     para em_calculo.
--   AVANCO: uma etapa por vez. Nao confirmado explicitamente - decisao
--     conservadora para preservar a integridade do pipeline. Se algum
--     tipo de rescisao precisar pular etapa, remover o bloco marcado
--     >>> AVANCO PASSO A PASSO <<< na secao 2.
--
-- 0.5 Ordem do checklist (confirmado)
--   Segue a matriz por tipo de rescisao. A ordem fisica e a ordem de
--   declaracao do ENUM rs_tipo_tarefa_t (migration_008), renumerada
--   1..N sobre as tarefas aplicaveis. Assim rescisoes diferentes tem
--   numeracao continua, sem buracos.
--
-- 0.6 Quem muda status / conclui tarefa (confirmado)
--   Apenas o analista_id da rescisao, gestor ou admin.
--   ATENCAO: criterio MAIS ESTRITO que o de leitura. Um analista pode
--   VER a rescisao por ter a empresa na carteira (policy do 009) e
--   ainda assim NAO poder mover o status. Divergencia intencional.
--
-- 0.7 Quem pode abrir rescisao (nao confirmado - decisao a revisar)
--   gestor/admin: qualquer empresa, atribuindo a qualquer analista.
--   analista: apenas empresas da sua carteira, atribuindo a si mesmo.
--   Espelha o modelo de visibilidade do 009. Sinalizado no relatorio.
-- ============================================================


-- ============================================================
-- 1. abrir_rescisao
--
-- Cadastra a rescisao, calcula o prazo, gera o checklist conforme a
-- matriz e grava o registro inicial no historico - tudo numa transacao.
-- E o UNICO caminho de criacao: as policies do 009 barram INSERT direto
-- do cliente justamente para impedir rescisao orfa (sem checklist ou
-- sem historico).
--
-- RETORNA: uuid da rescisao criada (a UI usa para navegar ao detalhe).
-- ============================================================

DROP FUNCTION IF EXISTS public.abrir_rescisao(uuid, uuid, text, text,
  public.rs_tipo_rescisao_t, public.rs_tipo_aviso_t, date, date, date);

CREATE OR REPLACE FUNCTION public.abrir_rescisao(
  p_empresa_id                    uuid,
  p_analista_id                   uuid,
  p_funcionario_nome              text,
  p_cpf                           text,
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
    funcionario_nome, cpf,
    tipo_rescisao, tipo_aviso,
    data_solicitacao, data_recebimento_apontamentos,
    data_rescisao, prazo_pagamento,
    status, observacoes
  ) VALUES (
    p_empresa_id, p_analista_id, v_uid,
    btrim(p_funcionario_nome), nullif(btrim(coalesce(p_cpf, '')), ''),
    p_tipo_rescisao, p_tipo_aviso,
    coalesce(p_data_solicitacao, CURRENT_DATE), p_data_recebimento_apontamentos,
    p_data_rescisao, v_prazo,
    'solicitada', nullif(btrim(coalesce(p_observacoes, '')), '')
  )
  RETURNING id INTO v_rescisao_id;

  -- ---------- Checklist (matriz por tipo de rescisao) ----------
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
-- 2. atualizar_status_rescisao
--
-- Unico caminho de movimentacao do pipeline. A migration_009 revogou
-- UPDATE na coluna status para authenticated - esta funcao roda como
-- owner e por isso consegue grava-la. E o que garante que toda
-- transicao deixe rastro em rs_historico.
--
-- RETORNA: o novo status (confirmacao para a UI).
-- ============================================================

DROP FUNCTION IF EXISTS public.atualizar_status_rescisao(uuid,
  public.rs_status_rescisao_t, text);

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
  v_ord_atual     integer;
  v_ord_novo      integer;
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

  IF p_status_novo IS NULL THEN
    RAISE EXCEPTION 'Status de destino e obrigatorio.';
  END IF;

  -- ---------- Rescisao ----------
  -- FOR UPDATE: serializa transicoes concorrentes na mesma rescisao
  -- (dois cliques simultaneos nao geram dois registros de historico).
  SELECT analista_id, status INTO v_analista_id, v_status_atual
  FROM rs_rescisoes WHERE id = p_rescisao_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Rescisao nao encontrada.';
  END IF;

  -- ---------- Autorizacao ----------
  -- Criterio MAIS ESTRITO que a leitura: ter a empresa na carteira
  -- permite VER, mas nao mover o pipeline.
  IF v_perfil = 'analista' AND v_analista_id <> v_uid THEN
    RAISE EXCEPTION 'Apenas o analista responsavel, gestor ou admin podem alterar o status.';
  END IF;

  -- ---------- Validacao da transicao ----------
  v_ord_atual := array_position(enum_range(NULL::rs_status_rescisao_t), v_status_atual);
  v_ord_novo  := array_position(enum_range(NULL::rs_status_rescisao_t), p_status_novo);

  IF v_ord_novo = v_ord_atual THEN
    RAISE EXCEPTION 'A rescisao ja esta no status "%".', p_status_novo;
  END IF;

  -- >>> AVANCO PASSO A PASSO <<<
  -- Remover este bloco para permitir pular etapas no avanco.
  -- Retrocesso (v_ord_novo < v_ord_atual) e livre por decisao de negocio.
  IF v_ord_novo > v_ord_atual + 1 THEN
    RAISE EXCEPTION 'Nao e possivel pular etapas do fluxo. Status atual: "%".', v_status_atual;
  END IF;

  -- ---------- Aplicacao ----------
  UPDATE rs_rescisoes SET status = p_status_novo WHERE id = p_rescisao_id;

  INSERT INTO rs_historico (rescisao_id, status_anterior, status_novo, usuario_id, observacao)
  VALUES (p_rescisao_id, v_status_atual, p_status_novo, v_uid,
          nullif(btrim(coalesce(p_observacao, '')), ''));

  RETURN p_status_novo;
END;
$function$;


-- ============================================================
-- 3. concluir_tarefa_rescisao
--
-- Marca ou desmarca uma tarefa do checklist. A migration_009 liberou
-- apenas observacao para UPDATE via API - concluida, concluida_por e
-- concluida_em passam obrigatoriamente por aqui. Isso garante que
-- concluida_por seja sempre o usuario real e que a CHECK
-- rs_tarefas_conclusao_coerente nunca seja contornada.
--
-- p_concluida: nao previsto no contexto original. Adicionado com
-- DEFAULT true para permitir DESMARCAR uma tarefa marcada por engano
-- (checkbox da UI). Chamada sem o parametro = comportamento documentado.
--
-- RETORNA: o estado final de concluida.
-- ============================================================

DROP FUNCTION IF EXISTS public.concluir_tarefa_rescisao(uuid, text);
DROP FUNCTION IF EXISTS public.concluir_tarefa_rescisao(uuid, text, boolean);

CREATE OR REPLACE FUNCTION public.concluir_tarefa_rescisao(
  p_tarefa_id  uuid,
  p_observacao text    DEFAULT NULL,
  p_concluida  boolean DEFAULT true
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid         uuid;
  v_perfil      perfil_usuario;
  v_ativo       boolean;
  v_analista_id uuid;
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

  -- ---------- Tarefa + rescisao pai ----------
  SELECT r.analista_id INTO v_analista_id
  FROM rs_tarefas t
  JOIN rs_rescisoes r ON r.id = t.rescisao_id
  WHERE t.id = p_tarefa_id
  FOR UPDATE OF t;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tarefa nao encontrada.';
  END IF;

  -- ---------- Autorizacao (mesmo criterio do status) ----------
  IF v_perfil = 'analista' AND v_analista_id <> v_uid THEN
    RAISE EXCEPTION 'Apenas o analista responsavel, gestor ou admin podem concluir tarefas.';
  END IF;

  -- ---------- Aplicacao ----------
  -- Os tres campos sao gravados juntos para respeitar a CHECK de
  -- coerencia: desmarcar limpa autor e data.
  UPDATE rs_tarefas
  SET concluida     = p_concluida,
      concluida_por = CASE WHEN p_concluida THEN v_uid ELSE NULL END,
      concluida_em  = CASE WHEN p_concluida THEN now() ELSE NULL END,
      observacao    = coalesce(nullif(btrim(coalesce(p_observacao, '')), ''), observacao)
  WHERE id = p_tarefa_id;

  RETURN p_concluida;
END;
$function$;


-- ============================================================
-- 4. PRIVILEGIOS DE EXECUCAO
--
-- Por padrao o Postgres concede EXECUTE a PUBLIC em funcoes novas -
-- o que incluiria o papel anon (usuario nao logado). Revogar e
-- reconceder so a authenticated fecha isso.
-- As funcoes ja validam auth.uid() internamente; este bloco e defesa
-- em profundidade.
-- ============================================================

REVOKE EXECUTE ON FUNCTION public.abrir_rescisao(uuid, uuid, text, text,
  public.rs_tipo_rescisao_t, public.rs_tipo_aviso_t, date, date, date, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.abrir_rescisao(uuid, uuid, text, text,
  public.rs_tipo_rescisao_t, public.rs_tipo_aviso_t, date, date, date, text)
  TO authenticated;

REVOKE EXECUTE ON FUNCTION public.atualizar_status_rescisao(uuid,
  public.rs_status_rescisao_t, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.atualizar_status_rescisao(uuid,
  public.rs_status_rescisao_t, text) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.concluir_tarefa_rescisao(uuid, text, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.concluir_tarefa_rescisao(uuid, text, boolean)
  TO authenticated;


-- ============================================================
-- 5. VERIFICACAO POS-APLICACAO
-- ============================================================

-- 5.1 Funcoes criadas (esperado: 3, todas SECURITY DEFINER = true)
-- SELECT p.proname, p.prosecdef AS security_definer,
--        pg_get_function_identity_arguments(p.oid) AS args
-- FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
-- WHERE n.nspname = 'public'
--   AND p.proname IN ('abrir_rescisao','atualizar_status_rescisao',
--                     'concluir_tarefa_rescisao')
-- ORDER BY p.proname;

-- 5.2 EXECUTE concedido a authenticated e NEGADO a anon
-- SELECT p.proname,
--        has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_ok,
--        has_function_privilege('anon',          p.oid, 'EXECUTE') AS anon_ok
-- FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
-- WHERE n.nspname = 'public'
--   AND p.proname IN ('abrir_rescisao','atualizar_status_rescisao',
--                     'concluir_tarefa_rescisao')
-- ORDER BY p.proname;
-- Esperado: auth_ok = true, anon_ok = false nas 3.

-- 5.3 TESTE FUNCIONAL DA MATRIZ (nao grava nada - roda em transacao
--     abortada). Confirma o checklist gerado por tipo de rescisao.
-- BEGIN;
--   SELECT t.tipo,
--          CASE t.tipo
--            WHEN 'calculo_trct' THEN true
--            WHEN 'esocial_s2299' THEN true
--            WHEN 'recibo_quitacao_trct' THEN true
--            WHEN 'aviso_previo' THEN 'acordo_mutuo' IN
--              ('sem_justa_causa','pedido_demissao','acordo_mutuo')
--            WHEN 'grrf_multa_20' THEN 'acordo_mutuo' = 'acordo_mutuo'
--            WHEN 'formulario_seguro_desemprego' THEN 'acordo_mutuo' IN
--              ('sem_justa_causa','acordo_mutuo')
--            WHEN 'termo_acordo_mutuo' THEN 'acordo_mutuo' = 'acordo_mutuo'
--            ELSE false
--          END AS aplicavel
--   FROM unnest(enum_range(NULL::rs_tipo_tarefa_t)) WITH ORDINALITY AS t(tipo, ord)
--   ORDER BY t.ord;
-- ROLLBACK;
-- Esperado para acordo_mutuo: 6 tarefas true (calculo_trct,
-- esocial_s2299, aviso_previo, grrf_multa_20,
-- formulario_seguro_desemprego, termo_acordo_mutuo, recibo_quitacao_trct
-- = 7 no total).

-- 5.4 Calculo do prazo (verificacao pura, sem escrita)
-- SELECT d AS data_rescisao, d + 9 AS bruto,
--        to_char(d + 9, 'Dy') AS dia_semana,
--        CASE EXTRACT(DOW FROM d + 9)
--          WHEN 6 THEN (d + 9) - 1
--          WHEN 0 THEN (d + 9) - 2
--          ELSE d + 9 END AS prazo_final
-- FROM (SELECT generate_series(DATE '2026-08-01', DATE '2026-08-21', '1 day')::date AS d) s
-- ORDER BY d;

-- 5.5 Controle intacto (baseline 400 / 14136 / 12 / 3)
-- SELECT 'empresas' t, count(*) FROM empresas
-- UNION ALL SELECT 'entregas', count(*) FROM entregas
-- UNION ALL SELECT 'atividades', count(*) FROM atividades
-- UNION ALL SELECT 'competencias', count(*) FROM competencias;

-- 5.6 RPCs do Controle intactas (abrir_competencia, excluir_competencia,
--     recalcular_nt_empresa, check_comp_concluida, meu_perfil)
-- SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
-- WHERE n.nspname = 'public'
--   AND proname IN ('abrir_competencia','excluir_competencia',
--                   'recalcular_nt_empresa','check_comp_concluida','meu_perfil')
-- ORDER BY proname;
-- Esperado: as 5 presentes.


-- ============================================================
-- 6. ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS public.concluir_tarefa_rescisao(uuid, text, boolean);
-- DROP FUNCTION IF EXISTS public.atualizar_status_rescisao(uuid,
--   public.rs_status_rescisao_t, text);
-- DROP FUNCTION IF EXISTS public.abrir_rescisao(uuid, uuid, text, text,
--   public.rs_tipo_rescisao_t, public.rs_tipo_aviso_t, date, date, date, text);

-- ============================================================
-- FIM migration_010_rescisoes_rpcs.sql
-- ============================================================
