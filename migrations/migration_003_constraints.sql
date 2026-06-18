-- ============================================================
-- DP+ Suite — Migration 003: Constraints ausentes no schema
-- Aplicar após migration_002_rls_policies.sql
-- Todas as alterações são NÃO-DESTRUTIVAS (não afetam dados existentes)
-- ============================================================

-- ============================================================
-- 1. competencias: UNIQUE(mes, ano)
-- Impede abertura duplicada do mesmo mês/ano.
-- Antes de aplicar: verificar se não há duplicatas com:
--   SELECT mes, ano, COUNT(*) FROM competencias GROUP BY mes, ano HAVING COUNT(*) > 1;
-- ============================================================

ALTER TABLE public.competencias
  ADD CONSTRAINT competencias_mes_ano_unique UNIQUE (mes, ano);

-- ============================================================
-- 2. competencias: CHECK mes entre 1 e 12
-- Impede meses inválidos (0, 13, negativos).
-- ============================================================

ALTER TABLE public.competencias
  ADD CONSTRAINT competencias_mes_valido CHECK (mes BETWEEN 1 AND 12);

-- ============================================================
-- 3. usuarios: UNIQUE(email)
-- Supabase Auth já garante unicidade no layer de autenticação,
-- mas a tabela pública não tinha essa garantia.
-- Antes de aplicar: verificar duplicatas com:
--   SELECT email, COUNT(*) FROM usuarios GROUP BY email HAVING COUNT(*) > 1;
-- ============================================================

ALTER TABLE public.usuarios
  ADD CONSTRAINT usuarios_email_unique UNIQUE (email);

-- ============================================================
-- 4. INDEX de performance para queries frequentes
-- (não obrigatório mas recomendado com ~400 empresas)
-- ============================================================

-- Busca de entregas por competência + empresa (fetchAllEntregas)
CREATE INDEX IF NOT EXISTS idx_entregas_comp_empresa
  ON public.entregas (competencia_id, empresa_id);

-- Busca de empresa_competencia por competência (renderAnalista, renderCarteiras)
CREATE INDEX IF NOT EXISTS idx_emp_comp_competencia
  ON public.empresa_competencia (competencia_id);

-- Busca de empresa_competencia por analista (policy RLS entregas)
CREATE INDEX IF NOT EXISTS idx_emp_comp_analista
  ON public.empresa_competencia (analista_id);

-- Busca de empresas por analista (policy RLS entregas)
CREATE INDEX IF NOT EXISTS idx_empresas_analista
  ON public.empresas (analista_id);
