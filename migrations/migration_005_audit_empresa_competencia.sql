-- ============================================================
-- DP+ Suite — Migration 005: Audit Log em empresa_competencia
-- Aplicar após migration_004_audit_log.sql (depende de fn_audit_log())
-- Registra alterações de tem_movimento, tem_adiantamento, funcionarios
-- e analista_id feitas dentro de uma competência já aberta.
--
-- Trigger AFTER: não afeta dados existentes, só passa a registrar
-- a partir de updates/deletes futuros.
-- INSERT propositalmente fora do trigger — mesma lógica usada em
-- competencias (criação inicial não gera ruído no log).
-- ============================================================

CREATE TRIGGER audit_empresa_competencia
  AFTER UPDATE OR DELETE
  ON public.empresa_competencia
  FOR EACH ROW EXECUTE FUNCTION public.fn_audit_log();

-- ============================================================
-- CONSULTA ÚTIL: histórico de alterações de uma empresa em uma competência
-- ============================================================
-- SELECT al.criado_em, u.nome AS alterado_por, al.operacao,
--        al.dados_anteriores->>'tem_movimento'    AS mov_antes,
--        al.dados_novos->>'tem_movimento'         AS mov_depois,
--        al.dados_anteriores->>'tem_adiantamento' AS adian_antes,
--        al.dados_novos->>'tem_adiantamento'      AS adian_depois,
--        al.dados_anteriores->>'funcionarios'     AS func_antes,
--        al.dados_novos->>'funcionarios'          AS func_depois
-- FROM public.audit_log al
-- LEFT JOIN public.usuarios u ON u.id = al.usuario_id
-- WHERE al.tabela = 'empresa_competencia'
--   AND al.registro_id = '<uuid_do_empresa_competencia>'
-- ORDER BY al.criado_em DESC;
-- ============================================================
