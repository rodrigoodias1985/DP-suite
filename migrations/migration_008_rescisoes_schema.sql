-- ============================================================
-- DP+ Suite - migration_008_rescisoes_schema.sql
-- Modulo Rescisoes (V2): ENUMs + tabelas rs_
--
-- Aplicar apos migration_007_abrir_comp_analista_historico.sql
--
-- NATUREZA: puramente aditiva. Nao altera nenhuma tabela, funcao,
-- policy ou dado do modulo Controle. Rollback possivel via DROP
-- enquanto as tabelas estiverem vazias (ver bloco ROLLBACK no fim).
--
-- IDEMPOTENTE: ENUMs criados sob checagem em pg_type; tabelas com
-- CREATE TABLE IF NOT EXISTS; indices com IF NOT EXISTS; triggers
-- com DROP ... IF EXISTS antes do CREATE.
--
-- ATENCAO (limite conhecido de idempotencia): se uma tabela rs_ ja
-- existir, o CREATE TABLE IF NOT EXISTS e ignorado por inteiro e as
-- CONSTRAINTs declaradas dentro dele NAO sao aplicadas. Em re-execucao
-- apos alteracao manual de schema, conferir constraints com:
--   SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conrelid = 'public.rs_rescisoes'::regclass;
-- ============================================================


-- ============================================================
-- 1. ENUMS
-- Fonte: contexto_20260813.txt secoes TIPOS_RESCISAO, TIPO_AVISO,
-- STATUS_RESCISAO, TAREFAS_RESCISAO. Nenhum valor inventado.
-- ============================================================

-- Tipo de rescisao (determina matriz de tarefas na RPC abrir_rescisao - migration_010)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'rs_tipo_rescisao_t' AND n.nspname = 'public'
  ) THEN
    CREATE TYPE public.rs_tipo_rescisao_t AS ENUM (
      'sem_justa_causa',
      'pedido_demissao',
      'justa_causa',
      'acordo_mutuo',
      'termino_prazo',
      'antecipacao_empregador',
      'antecipacao_empregado'
    );
  END IF;
END$$;

-- Tipo de aviso previo: FLAG independente do tipo_rescisao.
-- Nao cria subtipos. Impacta apenas a tarefa aviso_previo.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'rs_tipo_aviso_t' AND n.nspname = 'public'
  ) THEN
    CREATE TYPE public.rs_tipo_aviso_t AS ENUM (
      'trabalhado',
      'indenizado',
      'descontado',
      'nao_aplicavel'
    );
  END IF;
END$$;

-- Pipeline de status. A ordem dos valores no ENUM e a ordem do fluxo -
-- a RPC atualizar_status_rescisao (migration_010) validara as transicoes.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'rs_status_rescisao_t' AND n.nspname = 'public'
  ) THEN
    CREATE TYPE public.rs_status_rescisao_t AS ENUM (
      'solicitada',
      'em_calculo',
      'em_conferencia',
      'aguardando_cliente',
      'aprovada',
      'guias_emitidas',
      'finalizada'
    );
  END IF;
END$$;

-- Catalogo de tarefas. Quais sao geradas depende do tipo_rescisao
-- (matriz implementada na RPC abrir_rescisao - migration_010).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'rs_tipo_tarefa_t' AND n.nspname = 'public'
  ) THEN
    CREATE TYPE public.rs_tipo_tarefa_t AS ENUM (
      'calculo_trct',
      'esocial_s2299',
      'aviso_previo',
      'grrf_multa_40',
      'grrf_multa_20',
      'grrf_fgts_mensal',
      'formulario_seguro_desemprego',
      'termo_acordo_mutuo',
      'indenizacao_art479',
      'indenizacao_art480',
      'documentacao_justa_causa',
      'recibo_quitacao_trct'
    );
  END IF;
END$$;


-- ============================================================
-- 2. FUNCAO DE updated_at
--
-- Funcao NOVA e dedicada ao modulo rs_. O corpo da funcao usada por
-- tg_empresas_updated_at / tg_entregas_updated_at nao esta documentado
-- no Project Knowledge (ver triggers.sql), entao nao foi reaproveitada
-- as cegas. Criar uma funcao propria mantem a migration 100% aditiva:
-- zero chance de sobrescrever comportamento do modulo Controle.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_rs_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;


-- ============================================================
-- 3. TABELA rs_rescisoes
-- ============================================================

CREATE TABLE IF NOT EXISTS public.rs_rescisoes (
  id                            uuid        NOT NULL DEFAULT gen_random_uuid(),

  -- Vinculos
  empresa_id                    uuid        NOT NULL,
  analista_id                   uuid        NOT NULL,  -- responsavel pela rescisao
  criado_por                    uuid        NOT NULL,  -- quem cadastrou (auth.uid() na RPC)

  -- Identificacao do funcionario
  funcionario_nome              text        NOT NULL,
  cpf                           text,

  -- Classificacao
  tipo_rescisao                 public.rs_tipo_rescisao_t NOT NULL,
  tipo_aviso                    public.rs_tipo_aviso_t    NOT NULL,

  -- Datas
  data_solicitacao              date        NOT NULL DEFAULT CURRENT_DATE,
  -- data_recebimento_apontamentos: quando o ESCRITORIO recebeu os documentos
  -- do cliente (nao quando o cliente alega ter enviado). Campo de
  -- rastreabilidade de responsabilidade. NULL = ainda nao recebido.
  data_recebimento_apontamentos date,
  data_rescisao                 date        NOT NULL,  -- ultimo dia trabalhado
  -- prazo_pagamento: data_rescisao + 9 (margem interna do escritorio),
  -- ajustado para dia util anterior se cair em sab/dom.
  -- Calculado pela RPC abrir_rescisao (migration_010), editavel depois.
  prazo_pagamento               date        NOT NULL,

  -- Pipeline
  status                        public.rs_status_rescisao_t NOT NULL DEFAULT 'solicitada',

  observacoes                   text,
  created_at                    timestamptz NOT NULL DEFAULT now(),
  updated_at                    timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT rs_rescisoes_pkey PRIMARY KEY (id),

  CONSTRAINT rs_rescisoes_empresa_id_fkey  FOREIGN KEY (empresa_id)  REFERENCES public.empresas(id),
  CONSTRAINT rs_rescisoes_analista_id_fkey FOREIGN KEY (analista_id) REFERENCES public.usuarios(id),
  CONSTRAINT rs_rescisoes_criado_por_fkey  FOREIGN KEY (criado_por)  REFERENCES public.usuarios(id),

  -- Nome nao pode ser string vazia
  CONSTRAINT rs_rescisoes_nome_nao_vazio CHECK (btrim(funcionario_nome) <> ''),

  -- CPF: aceita formatado (000.000.000-00) ou so digitos. Valida apenas
  -- a quantidade de digitos - NAO valida digito verificador (isso e
  -- responsabilidade da UI). NULL permitido.
  CONSTRAINT rs_rescisoes_cpf_formato CHECK (
    cpf IS NULL OR length(regexp_replace(cpf, '\D', '', 'g')) = 11
  )
);


-- ============================================================
-- 4. TABELA rs_tarefas
-- Gerada exclusivamente pela RPC abrir_rescisao (migration_010).
-- Nunca INSERT direto do cliente.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.rs_tarefas (
  id            uuid        NOT NULL DEFAULT gen_random_uuid(),
  rescisao_id   uuid        NOT NULL,
  tipo_tarefa   public.rs_tipo_tarefa_t NOT NULL,
  ordem         integer     NOT NULL DEFAULT 0,
  concluida     boolean     NOT NULL DEFAULT false,
  concluida_por uuid,
  concluida_em  timestamptz,
  observacao    text,
  created_at    timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT rs_tarefas_pkey PRIMARY KEY (id),

  -- CASCADE: excluir a rescisao (DELETE admin) remove o checklist junto.
  CONSTRAINT rs_tarefas_rescisao_id_fkey FOREIGN KEY (rescisao_id)
    REFERENCES public.rs_rescisoes(id) ON DELETE CASCADE,

  CONSTRAINT rs_tarefas_concluida_por_fkey FOREIGN KEY (concluida_por)
    REFERENCES public.usuarios(id),

  -- Uma tarefa de cada tipo por rescisao. Permite que abrir_rescisao use
  -- ON CONFLICT DO NOTHING e seja re-executavel sem duplicar checklist.
  CONSTRAINT rs_tarefas_rescisao_tipo_unique UNIQUE (rescisao_id, tipo_tarefa),

  -- Coerencia do estado de conclusao: nao existe tarefa concluida sem
  -- data, nem tarefa pendente com autor/data de conclusao preenchidos.
  CONSTRAINT rs_tarefas_conclusao_coerente CHECK (
    (concluida = false AND concluida_em IS NULL AND concluida_por IS NULL)
    OR
    (concluida = true  AND concluida_em IS NOT NULL)
  )
);


-- ============================================================
-- 5. TABELA rs_historico
-- Audit trail do pipeline. Escrita exclusivamente via RPC
-- SECURITY DEFINER (atualizar_status_rescisao - migration_010).
-- ============================================================

CREATE TABLE IF NOT EXISTS public.rs_historico (
  id              uuid        NOT NULL DEFAULT gen_random_uuid(),
  rescisao_id     uuid        NOT NULL,
  -- NULL apenas no registro inicial (criacao da rescisao).
  status_anterior public.rs_status_rescisao_t,
  status_novo     public.rs_status_rescisao_t NOT NULL,
  -- Nullable de proposito: historico nunca deve ser perdido por
  -- problema de resolucao de usuario.
  usuario_id      uuid,
  observacao      text,
  created_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT rs_historico_pkey PRIMARY KEY (id),

  CONSTRAINT rs_historico_rescisao_id_fkey FOREIGN KEY (rescisao_id)
    REFERENCES public.rs_rescisoes(id) ON DELETE CASCADE,

  CONSTRAINT rs_historico_usuario_id_fkey FOREIGN KEY (usuario_id)
    REFERENCES public.usuarios(id),

  -- Nao registra "transicao" para o mesmo status
  CONSTRAINT rs_historico_transicao_valida CHECK (
    status_anterior IS NULL OR status_anterior <> status_novo
  )
);


-- ============================================================
-- 6. INDEXES
-- Antecipam os padroes de acesso da rescisoes.html:
-- pipeline do analista, visao gestor/admin, relatorios por periodo.
-- ============================================================

-- Visao analista: "minhas rescisoes" (tambem usado pela policy RLS de 009)
CREATE INDEX IF NOT EXISTS idx_rs_rescisoes_analista
  ON public.rs_rescisoes (analista_id);

-- Lookup por empresa (codigo -> empresa_id -> rescisoes)
CREATE INDEX IF NOT EXISTS idx_rs_rescisoes_empresa
  ON public.rs_rescisoes (empresa_id);

-- Navegacao por coluna do pipeline
CREATE INDEX IF NOT EXISTS idx_rs_rescisoes_status
  ON public.rs_rescisoes (status);

-- Relatorios por periodo (filtro em data_rescisao) e ordenacao por prazo
CREATE INDEX IF NOT EXISTS idx_rs_rescisoes_data_rescisao
  ON public.rs_rescisoes (data_rescisao);

CREATE INDEX IF NOT EXISTS idx_rs_rescisoes_prazo_pagamento
  ON public.rs_rescisoes (prazo_pagamento);

-- Checklist de uma rescisao
CREATE INDEX IF NOT EXISTS idx_rs_tarefas_rescisao
  ON public.rs_tarefas (rescisao_id);

-- Indice parcial: contagem de pendencias por rescisao (badge do card)
CREATE INDEX IF NOT EXISTS idx_rs_tarefas_pendentes
  ON public.rs_tarefas (rescisao_id) WHERE concluida = false;

-- Timeline da rescisao (mais recente primeiro)
CREATE INDEX IF NOT EXISTS idx_rs_historico_rescisao
  ON public.rs_historico (rescisao_id, created_at DESC);


-- ============================================================
-- 7. TRIGGERS
-- ============================================================

-- 7.1 updated_at automatico em rs_rescisoes
DROP TRIGGER IF EXISTS tg_rs_rescisoes_updated_at ON public.rs_rescisoes;
CREATE TRIGGER tg_rs_rescisoes_updated_at
  BEFORE UPDATE ON public.rs_rescisoes
  FOR EACH ROW EXECUTE FUNCTION public.fn_rs_updated_at();

-- 7.2 Audit log em rs_rescisoes
-- rs_historico registra apenas mudancas de STATUS. Alteracoes de campo
-- (datas, tipo_rescisao, analista_id) ficariam sem rastro. Reutiliza a
-- fn_audit_log() ja validada em producao (migration_004) - nao altera a
-- funcao, apenas anexa mais um trigger.
DROP TRIGGER IF EXISTS audit_rs_rescisoes ON public.rs_rescisoes;
CREATE TRIGGER audit_rs_rescisoes
  AFTER INSERT OR UPDATE OR DELETE
  ON public.rs_rescisoes
  FOR EACH ROW EXECUTE FUNCTION public.fn_audit_log();

-- 7.3 Audit log em rs_tarefas
-- Rastreia des-conclusao de tarefa (concluida true -> false), que nao
-- deixa vestigio no proprio registro.
DROP TRIGGER IF EXISTS audit_rs_tarefas ON public.rs_tarefas;
CREATE TRIGGER audit_rs_tarefas
  AFTER UPDATE OR DELETE
  ON public.rs_tarefas
  FOR EACH ROW EXECUTE FUNCTION public.fn_audit_log();

-- rs_historico NAO recebe trigger de auditoria: a tabela ja E o log.


-- ============================================================
-- 8. RLS - HABILITACAO SEM POLICIES
--
-- CRITICO: tabela criada sem RLS habilitado fica LEGIVEL E GRAVAVEL
-- por qualquer usuario autenticado via PostgREST (anon key esta no
-- client-side). Habilitar aqui, com ZERO policies, fecha a tabela
-- completamente ate a migration_009 abrir os acessos corretos.
--
-- Efeito imediato: rs_ inacessivel via API para todos os perfis.
-- Isso e o comportamento desejado entre 008 e 009 - as tabelas ainda
-- estao vazias e nenhuma tela consome esses dados.
-- RPCs SECURITY DEFINER (migration_010) continuam funcionando normal.
-- ============================================================

ALTER TABLE public.rs_rescisoes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rs_tarefas   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rs_historico ENABLE ROW LEVEL SECURITY;


-- ============================================================
-- 9. VERIFICACAO POS-APLICACAO
-- Rodar apos o commit para confirmar o resultado.
-- ============================================================

-- 9.1 ENUMs criados com os valores corretos
-- SELECT t.typname, string_agg(e.enumlabel, ' | ' ORDER BY e.enumsortorder)
-- FROM pg_type t
-- JOIN pg_enum e ON e.enumtypid = t.oid
-- JOIN pg_namespace n ON n.oid = t.typnamespace
-- WHERE n.nspname = 'public' AND t.typname LIKE 'rs\_%'
-- GROUP BY t.typname ORDER BY t.typname;

-- 9.2 Tabelas criadas e RLS habilitado (rowsecurity deve ser true nas 3)
-- SELECT tablename, rowsecurity FROM pg_tables
-- WHERE schemaname = 'public' AND tablename LIKE 'rs\_%' ORDER BY tablename;

-- 9.3 Nenhuma policy ainda (esperado: 0 linhas ate a migration_009)
-- SELECT tablename, policyname FROM pg_policies
-- WHERE schemaname = 'public' AND tablename LIKE 'rs\_%';

-- 9.4 Constraints aplicadas
-- SELECT conrelid::regclass AS tabela, conname, pg_get_constraintdef(oid)
-- FROM pg_constraint
-- WHERE conrelid::regclass::text LIKE 'rs\_%' ORDER BY 1, 2;

-- 9.5 Modulo Controle intacto (contagens devem bater com antes)
-- SELECT 'empresas' t, count(*) FROM empresas
-- UNION ALL SELECT 'entregas', count(*) FROM entregas
-- UNION ALL SELECT 'atividades', count(*) FROM atividades
-- UNION ALL SELECT 'competencias', count(*) FROM competencias;


-- ============================================================
-- 10. ROLLBACK (valido apenas enquanto as tabelas estiverem vazias)
-- ============================================================
-- DROP TABLE IF EXISTS public.rs_historico;
-- DROP TABLE IF EXISTS public.rs_tarefas;
-- DROP TABLE IF EXISTS public.rs_rescisoes;
-- DROP FUNCTION IF EXISTS public.fn_rs_updated_at();
-- DROP TYPE IF EXISTS public.rs_tipo_tarefa_t;
-- DROP TYPE IF EXISTS public.rs_status_rescisao_t;
-- DROP TYPE IF EXISTS public.rs_tipo_aviso_t;
-- DROP TYPE IF EXISTS public.rs_tipo_rescisao_t;
-- (fn_audit_log NAO deve ser dropada - pertence ao modulo Controle)


-- ============================================================
-- 11. BLOCO OPCIONAL - NAO APLICAR SEM DECISAO EXPLICITA
--
-- Constraint de coerencia entre tipo_rescisao e tipo_aviso, conforme
-- a matriz documentada em contexto_20260813.txt (secao TIPO_AVISO).
--
-- MOTIVO DE ESTAR COMENTADO: a matriz nao contempla o caso de aviso
-- previo DISPENSADO pelo empregador em pedido_demissao (empregado nao
-- cumpre e o empregador nao desconta) - situacao comum na pratica e
-- sem valor correspondente no ENUM. Ativar esta constraint bloquearia
-- esse cadastro em producao e exigiria nova migration para liberar.
--
-- Decidir antes de ativar:
--   (a) deixar comentado - validacao fica na UI (rescisoes.html)
--   (b) ativar como esta - assume que o caso acima nao ocorre
--   (c) adicionar 'dispensado' ao rs_tipo_aviso_t e ativar
-- ============================================================

-- ALTER TABLE public.rs_rescisoes
--   ADD CONSTRAINT rs_rescisoes_aviso_coerente CHECK (
--     (tipo_rescisao IN ('justa_causa','termino_prazo',
--                        'antecipacao_empregador','antecipacao_empregado')
--        AND tipo_aviso = 'nao_aplicavel')
--     OR (tipo_rescisao = 'sem_justa_causa' AND tipo_aviso IN ('trabalhado','indenizado'))
--     OR (tipo_rescisao = 'pedido_demissao' AND tipo_aviso IN ('trabalhado','descontado'))
--     OR (tipo_rescisao = 'acordo_mutuo'    AND tipo_aviso IN ('trabalhado','indenizado'))
--   );

-- ============================================================
-- FIM migration_008_rescisoes_schema.sql
-- ============================================================
