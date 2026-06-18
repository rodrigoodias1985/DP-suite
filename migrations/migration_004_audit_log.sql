-- ============================================================
-- DP+ Suite — Migration 004: Audit Log
-- Aplicar após migration_003_constraints.sql
-- Registra INSERT/UPDATE/DELETE nas tabelas críticas de forma
-- imutável (sem policy de UPDATE/DELETE na tabela de log).
-- ============================================================

-- ============================================================
-- 1. TABELA DE AUDIT LOG
-- ============================================================

CREATE TABLE IF NOT EXISTS public.audit_log (
  id             uuid        NOT NULL DEFAULT gen_random_uuid(),
  tabela         text        NOT NULL,
  operacao       text        NOT NULL, -- INSERT | UPDATE | DELETE
  registro_id    uuid,
  usuario_id     uuid,
  dados_anteriores jsonb,
  dados_novos      jsonb,
  criado_em      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT audit_log_pkey PRIMARY KEY (id),
  CONSTRAINT audit_log_operacao_check CHECK (operacao IN ('INSERT','UPDATE','DELETE'))
);

-- ============================================================
-- 2. RLS: somente admin pode consultar o log
--    Ninguém pode inserir, atualizar ou excluir via API —
--    apenas o trigger (SECURITY DEFINER) escreve aqui.
-- ============================================================

ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "audit_log_select_admin"
  ON public.audit_log FOR SELECT
  USING (meu_perfil() = 'admin');

-- Sem policies de INSERT/UPDATE/DELETE = bloqueio total via API

-- ============================================================
-- 3. FUNÇÃO DO TRIGGER
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_audit_log()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.audit_log (
    tabela,
    operacao,
    registro_id,
    usuario_id,
    dados_anteriores,
    dados_novos
  ) VALUES (
    TG_TABLE_NAME,
    TG_OP,
    CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END,
    auth.uid(),
    CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END,
    CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END
  );
  RETURN NULL; -- trigger AFTER: valor de retorno ignorado
END;
$$;

-- ============================================================
-- 4. TRIGGERS NAS TABELAS CRÍTICAS
-- ============================================================

-- entregas: toda alteração de data de entrega fica registrada
CREATE TRIGGER audit_entregas
  AFTER INSERT OR UPDATE OR DELETE
  ON public.entregas
  FOR EACH ROW EXECUTE FUNCTION public.fn_audit_log();

-- empresas: cadastros, inativações e exclusões físicas
CREATE TRIGGER audit_empresas
  AFTER INSERT OR UPDATE OR DELETE
  ON public.empresas
  FOR EACH ROW EXECUTE FUNCTION public.fn_audit_log();

-- competencias: abertura, fechamento e exclusão de competências
-- (INSERT omitido propositalmente — abertura já é rastreada via abrir_competencia RPC)
CREATE TRIGGER audit_competencias
  AFTER UPDATE OR DELETE
  ON public.competencias
  FOR EACH ROW EXECUTE FUNCTION public.fn_audit_log();

-- ============================================================
-- CONSULTAS ÚTEIS NO DIA A DIA
-- ============================================================
-- Ver últimas 50 alterações em entregas:
--   SELECT * FROM audit_log WHERE tabela = 'entregas'
--   ORDER BY criado_em DESC LIMIT 50;
--
-- Ver quem alterou uma empresa específica:
--   SELECT al.criado_em, u.nome, al.operacao,
--          al.dados_anteriores, al.dados_novos
--   FROM audit_log al
--   LEFT JOIN usuarios u ON u.id = al.usuario_id
--   WHERE al.tabela = 'empresas' AND al.registro_id = '<uuid>'
--   ORDER BY al.criado_em DESC;
-- ============================================================
