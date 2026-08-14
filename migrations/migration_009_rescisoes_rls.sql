-- ============================================================
-- DP+ Suite - migration_009_rescisoes_rls.sql
-- Modulo Rescisoes (V2): RLS policies + privilegios de coluna
--
-- Aplicar apos migration_008_rescisoes_schema.sql
--
-- NATUREZA: aditiva. Cria apenas policies e ajusta privilegios das
-- tabelas rs_. Nao toca em nenhuma policy, tabela ou funcao do modulo
-- Controle. meu_perfil() e apenas CHAMADA - nunca redefinida.
--
-- IDEMPOTENTE: DROP POLICY IF EXISTS antes de cada CREATE.
-- REVOKE/GRANT sao naturalmente idempotentes.
--
-- ESTADO ANTES DESTA MIGRATION: as 3 tabelas rs_ estao com RLS
-- habilitado e ZERO policies = inacessiveis via API. Esta migration
-- abre os acessos corretos.
-- ============================================================


-- ============================================================
-- 0. MODELO DE ACESSO (referencia)
--
-- meu_perfil(): STABLE SECURITY DEFINER, search_path=public.
--   Retorna usuarios.perfil de auth.uid(). Retorna NULL se o usuario
--   nao existir em usuarios -> comparacao vira NULL -> policy nega.
--   Falha fechando. Correto.
--
--   LIMITE CONHECIDO: nao verifica usuarios.ativo. Usuario inativo com
--   sessao valida ainda passa pela RLS. Isso e PRE-EXISTENTE e afeta
--   TODAS as tabelas do projeto, nao so rs_. Correcao deliberadamente
--   fora do escopo desta migration: sera feita uma unica vez alterando
--   meu_perfil(), o que corrige o projeto inteiro de forma uniforme.
--   Corrigir so nas rs_ criaria divergencia de comportamento entre
--   modulos e mascararia o problema real.
--
-- CARTEIRA DO ANALISTA: expressao identica a usada em entregas_select /
--   entregas_update (migration_002). Uniao de:
--     - empresas.analista_id            (vinculo cadastral / atual)
--     - empresa_competencia.analista_id (vinculo historico)
--   O ramo historico e o que preserva o acesso do analista as rescisoes
--   de empresas que sairam da sua carteira. Sem ele, o analista perde a
--   visao do proprio trabalho passado e o lastro de autoria deixa de
--   servir para conferencia.
--
-- AUTORIA x VISIBILIDADE:
--   rs_rescisoes.analista_id = quem EXECUTOU. Imutavel via API
--   (ver secao 4). Visibilidade e calculada pela carteira, nao pela
--   autoria - as duas coisas sao independentes de proposito.
-- ============================================================


-- ============================================================
-- 1. POLICIES - rs_rescisoes
-- ============================================================

-- 1.1 SELECT
-- admin/gestor: tudo.
-- analista: rescisoes das empresas da sua carteira (cadastral OU
--   historica) OU rescisoes das quais ele e o responsavel registrado.
-- O ramo analista_id = auth.uid() e rede de seguranca: cobre o caso de
-- rescisao atribuida a um analista que nunca constou na carteira
-- daquela empresa. Sem ele, o proprio responsavel nao veria o registro.
DROP POLICY IF EXISTS rs_rescisoes_select ON public.rs_rescisoes;
CREATE POLICY rs_rescisoes_select ON public.rs_rescisoes
  FOR SELECT TO public
  USING (
    meu_perfil() = ANY (ARRAY['admin'::perfil_usuario, 'gestor'::perfil_usuario])
    OR analista_id = auth.uid()
    OR empresa_id IN (
      SELECT empresas.id FROM empresas WHERE empresas.analista_id = auth.uid()
      UNION
      SELECT empresa_competencia.empresa_id FROM empresa_competencia
      WHERE empresa_competencia.analista_id = auth.uid()
    )
  );

-- 1.2 INSERT - admin apenas
-- Cadastro de rescisao acontece EXCLUSIVAMENTE via RPC abrir_rescisao
-- (SECURITY DEFINER, migration_010), que insere rescisao + tarefas +
-- historico inicial de forma atomica.
-- Se o cliente pudesse inserir direto aqui, criaria rescisao orfa: sem
-- checklist e sem registro inicial no historico. Mesmo padrao de
-- entregas_insert. Nao limita a UI - ela nunca insere direto.
DROP POLICY IF EXISTS rs_rescisoes_insert ON public.rs_rescisoes;
CREATE POLICY rs_rescisoes_insert ON public.rs_rescisoes
  FOR INSERT TO public
  WITH CHECK (meu_perfil() = 'admin'::perfil_usuario);

-- 1.3 UPDATE
-- Mesma expressao do SELECT no USING (quem ve, edita).
-- WITH CHECK identico: defesa em profundidade contra mover a linha para
-- fora do proprio escopo de visibilidade. Na pratica empresa_id e
-- analista_id nao sao atualizaveis via API (secao 4), entao o WITH CHECK
-- e redundante - mantido de proposito para que a policy continue correta
-- caso os privilegios de coluna sejam afrouxados no futuro.
DROP POLICY IF EXISTS rs_rescisoes_update ON public.rs_rescisoes;
CREATE POLICY rs_rescisoes_update ON public.rs_rescisoes
  FOR UPDATE TO public
  USING (
    meu_perfil() = ANY (ARRAY['admin'::perfil_usuario, 'gestor'::perfil_usuario])
    OR analista_id = auth.uid()
    OR empresa_id IN (
      SELECT empresas.id FROM empresas WHERE empresas.analista_id = auth.uid()
      UNION
      SELECT empresa_competencia.empresa_id FROM empresa_competencia
      WHERE empresa_competencia.analista_id = auth.uid()
    )
  )
  WITH CHECK (
    meu_perfil() = ANY (ARRAY['admin'::perfil_usuario, 'gestor'::perfil_usuario])
    OR analista_id = auth.uid()
    OR empresa_id IN (
      SELECT empresas.id FROM empresas WHERE empresas.analista_id = auth.uid()
      UNION
      SELECT empresa_competencia.empresa_id FROM empresa_competencia
      WHERE empresa_competencia.analista_id = auth.uid()
    )
  );

-- 1.4 DELETE - admin apenas
DROP POLICY IF EXISTS rs_rescisoes_delete ON public.rs_rescisoes;
CREATE POLICY rs_rescisoes_delete ON public.rs_rescisoes
  FOR DELETE TO public
  USING (meu_perfil() = 'admin'::perfil_usuario);


-- ============================================================
-- 2. POLICIES - rs_tarefas
--
-- DECISAO DE DESENHO: a visibilidade e HERDADA da rescisao pai, nao
-- reescrita. O EXISTS abaixo consulta rs_rescisoes, que por sua vez esta
-- sob a policy rs_rescisoes_select - se o usuario nao enxerga a rescisao,
-- o EXISTS retorna falso e a tarefa some.
--
-- Vantagem: regra de visibilidade existe em UM lugar so. Alterar o
-- criterio na secao 1 propaga automaticamente para tarefas e historico.
-- Sem risco de recursao: rs_rescisoes_select nao referencia rs_tarefas.
-- Performance coberta por idx_rs_tarefas_rescisao (migration_008).
-- ============================================================

DROP POLICY IF EXISTS rs_tarefas_select ON public.rs_tarefas;
CREATE POLICY rs_tarefas_select ON public.rs_tarefas
  FOR SELECT TO public
  USING (
    EXISTS (
      SELECT 1 FROM public.rs_rescisoes r
      WHERE r.id = rs_tarefas.rescisao_id
    )
  );

-- INSERT - admin apenas. Checklist e gerado pela RPC abrir_rescisao
-- conforme a matriz tipo_rescisao -> tarefas. INSERT manual quebraria
-- a matriz sem deixar rastro.
DROP POLICY IF EXISTS rs_tarefas_insert ON public.rs_tarefas;
CREATE POLICY rs_tarefas_insert ON public.rs_tarefas
  FOR INSERT TO public
  WITH CHECK (meu_perfil() = 'admin'::perfil_usuario);

-- UPDATE - herda a visibilidade da rescisao pai.
-- Na pratica so a coluna observacao e atualizavel via API (secao 4);
-- a conclusao da tarefa passa pela RPC concluir_tarefa_rescisao.
DROP POLICY IF EXISTS rs_tarefas_update ON public.rs_tarefas;
CREATE POLICY rs_tarefas_update ON public.rs_tarefas
  FOR UPDATE TO public
  USING (
    EXISTS (
      SELECT 1 FROM public.rs_rescisoes r
      WHERE r.id = rs_tarefas.rescisao_id
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.rs_rescisoes r
      WHERE r.id = rs_tarefas.rescisao_id
    )
  );

DROP POLICY IF EXISTS rs_tarefas_delete ON public.rs_tarefas;
CREATE POLICY rs_tarefas_delete ON public.rs_tarefas
  FOR DELETE TO public
  USING (meu_perfil() = 'admin'::perfil_usuario);


-- ============================================================
-- 3. POLICIES - rs_historico
--
-- DIVERGENCIA DELIBERADA DO CONTEXTO: contexto_20260813.txt (linha 85)
-- previa "SELECT todos autenticados". Restringido aqui a visibilidade da
-- rescisao pai, pelo mesmo criterio de rs_tarefas.
-- Motivo: o campo observacao pode conter texto sensivel sobre o
-- desligamento. Liberar para todo autenticado vazaria para analistas sem
-- relacao com a empresa - inconsistente com o proprio esforco de
-- restringir rs_rescisoes.
--
-- SEM policy de INSERT/UPDATE/DELETE = bloqueio total de escrita via API.
-- Mesmo padrao de audit_log (migration_004): so a RPC SECURITY DEFINER
-- escreve aqui. A tabela E o log - se a aplicacao pudesse grava-la
-- diretamente, o audit trail perderia o valor.
-- ============================================================

DROP POLICY IF EXISTS rs_historico_select ON public.rs_historico;
CREATE POLICY rs_historico_select ON public.rs_historico
  FOR SELECT TO public
  USING (
    EXISTS (
      SELECT 1 FROM public.rs_rescisoes r
      WHERE r.id = rs_historico.rescisao_id
    )
  );


-- ============================================================
-- 4. PRIVILEGIOS DE COLUNA
--
-- POR QUE: RLS controla QUAIS LINHAS o usuario alcanca, nunca QUAIS
-- COLUNAS. Com UPDATE liberado na tabela inteira, o cliente poderia
-- alterar rs_rescisoes.status direto pelo PostgREST, sem passar pela RPC
-- atualizar_status_rescisao - e a transicao NAO entraria no
-- rs_historico. O audit trail ficaria furado em silencio.
--
-- COMO: no Postgres, REVOKE de coluna NAO tem efeito sobre privilegio
-- concedido no nivel da tabela. E obrigatorio revogar o UPDATE da tabela
-- inteira e reconceder apenas as colunas permitidas. Fazer so o REVOKE
-- de coluna nao funcionaria (falha silenciosa).
--
-- IMPACTO ZERO NAS RPCs: funcoes SECURITY DEFINER rodam com os
-- privilegios do owner, nao do chamador. abrir_rescisao,
-- atualizar_status_rescisao e concluir_tarefa_rescisao continuam
-- escrevendo em todas as colunas normalmente.
--
-- >>> ATENCAO PARA MANUTENCAO FUTURA <<<
-- GRANT de coluna NAO e retroativo. Toda coluna NOVA adicionada a
-- rs_rescisoes ou rs_tarefas nascera SEM permissao de UPDATE para
-- authenticated. Se a UI precisar edita-la, a migration que criar a
-- coluna precisa incluir o GRANT correspondente. Sintoma se esquecer:
-- "permission denied for table" em um UPDATE que deveria funcionar.
-- ============================================================

-- 4.1 rs_rescisoes
REVOKE UPDATE ON public.rs_rescisoes FROM authenticated, anon;

-- Colunas editaveis pela UI (dados cadastrais e datas da rescisao).
-- Deliberadamente FORA da lista:
--   status       -> so via RPC atualizar_status_rescisao (garante historico)
--   analista_id  -> preserva o lastro de autoria; reatribuicao de carteira
--                   nao pode sobrescrever quem executou a rescisao
--   empresa_id   -> impede mover a rescisao entre empresas
--   criado_por   -> rastreabilidade imutavel
--   id / created_at / updated_at -> gerenciados pelo banco
GRANT UPDATE (
  funcionario_nome,
  cpf,
  tipo_rescisao,
  tipo_aviso,
  data_solicitacao,
  data_recebimento_apontamentos,
  data_rescisao,
  prazo_pagamento,
  observacoes
) ON public.rs_rescisoes TO authenticated;

-- 4.2 rs_tarefas
REVOKE UPDATE ON public.rs_tarefas FROM authenticated, anon;

-- Apenas observacao. concluida / concluida_por / concluida_em sao
-- gravadas exclusivamente pela RPC concluir_tarefa_rescisao, o que
-- garante que a CHECK rs_tarefas_conclusao_coerente nunca seja
-- contornada e que concluida_por seja sempre o usuario real.
GRANT UPDATE (observacao) ON public.rs_tarefas TO authenticated;

-- 4.3 rs_historico - nenhuma escrita via API
REVOKE INSERT, UPDATE, DELETE ON public.rs_historico FROM authenticated, anon;

-- NOTA: nao ha REVOKE contra service_role nem contra o owner. A
-- service_role key nao e usada no client-side deste projeto e as RPCs
-- rodam como owner.


-- ============================================================
-- 5. VERIFICACAO POS-APLICACAO
-- ============================================================

-- 5.1 Policies criadas (esperado: 10 linhas)
--   rs_rescisoes: select, insert, update, delete   (4)
--   rs_tarefas:   select, insert, update, delete   (4)
--   rs_historico: select                           (1)
--   ... total 9. Conferir se bate.
-- SELECT tablename, policyname, cmd FROM pg_policies
-- WHERE schemaname = 'public' AND tablename LIKE 'rs\_%'
-- ORDER BY tablename, cmd;

-- 5.2 Privilegios de coluna em rs_rescisoes
-- Esperado: 9 colunas com UPDATE para authenticated.
-- status, analista_id, empresa_id, criado_por NAO podem aparecer.
-- SELECT column_name, privilege_type
-- FROM information_schema.column_privileges
-- WHERE table_schema = 'public' AND table_name = 'rs_rescisoes'
--   AND grantee = 'authenticated' AND privilege_type = 'UPDATE'
-- ORDER BY column_name;

-- 5.3 Privilegios de coluna em rs_tarefas (esperado: so observacao)
-- SELECT column_name, privilege_type
-- FROM information_schema.column_privileges
-- WHERE table_schema = 'public' AND table_name = 'rs_tarefas'
--   AND grantee = 'authenticated' AND privilege_type = 'UPDATE'
-- ORDER BY column_name;

-- 5.4 UPDATE de tabela NAO deve mais constar para authenticated nas
-- tabelas rs_rescisoes e rs_tarefas
-- SELECT table_name, privilege_type FROM information_schema.table_privileges
-- WHERE table_schema = 'public' AND table_name LIKE 'rs\_%'
--   AND grantee = 'authenticated'
-- ORDER BY table_name, privilege_type;

-- 5.5 Policies do modulo Controle intactas (esperado: identico ao
-- snapshot de rls_policies.sql - nenhuma policy sem prefixo rs_ foi
-- criada, alterada ou removida por esta migration)
-- SELECT tablename, count(*) FROM pg_policies
-- WHERE schemaname = 'public' AND tablename NOT LIKE 'rs\_%'
-- GROUP BY tablename ORDER BY tablename;

-- 5.6 Controle intacto (deve bater com o baseline 400/14136/12/3)
-- SELECT 'empresas' t, count(*) FROM empresas
-- UNION ALL SELECT 'entregas', count(*) FROM entregas
-- UNION ALL SELECT 'atividades', count(*) FROM atividades
-- UNION ALL SELECT 'competencias', count(*) FROM competencias;


-- ============================================================
-- 6. ROLLBACK
-- Volta ao estado pos-008: RLS ativo, zero policies, tabelas fechadas.
-- ============================================================
-- DROP POLICY IF EXISTS rs_rescisoes_select ON public.rs_rescisoes;
-- DROP POLICY IF EXISTS rs_rescisoes_insert ON public.rs_rescisoes;
-- DROP POLICY IF EXISTS rs_rescisoes_update ON public.rs_rescisoes;
-- DROP POLICY IF EXISTS rs_rescisoes_delete ON public.rs_rescisoes;
-- DROP POLICY IF EXISTS rs_tarefas_select   ON public.rs_tarefas;
-- DROP POLICY IF EXISTS rs_tarefas_insert   ON public.rs_tarefas;
-- DROP POLICY IF EXISTS rs_tarefas_update   ON public.rs_tarefas;
-- DROP POLICY IF EXISTS rs_tarefas_delete   ON public.rs_tarefas;
-- DROP POLICY IF EXISTS rs_historico_select ON public.rs_historico;
-- GRANT UPDATE ON public.rs_rescisoes TO authenticated;
-- GRANT UPDATE ON public.rs_tarefas   TO authenticated;

-- ============================================================
-- FIM migration_009_rescisoes_rls.sql
-- ============================================================
