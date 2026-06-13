-- ============================================================
-- DP+ Suite - Schema Snapshot (Ponto Zero)
-- Snapshot do banco de produção em 2026-06-13
-- Este arquivo documenta o estado atual do banco, não o histórico.
-- Não inclui: RLS policies, indexes, functions, triggers.
-- ============================================================

-- ============================================================
-- ENUMS
-- ============================================================

CREATE TYPE public.grupo_atividade_t AS ENUM (
  'adiantamento',
  'pagamento',
  'encargo_legal',
  'encargo_outros',
  'fechamento'
);

CREATE TYPE public.perfil_usuario AS ENUM (
  'admin',
  'gestor',
  'analista'
);

CREATE TYPE public.regime_tributario_t AS ENUM (
  'Simples Nacional',
  'Lucro Presumido',
  'Lucro Real'
);

CREATE TYPE public.status_comp_t AS ENUM (
  'aberta',
  'fechada',
  'concluida'
);

CREATE TYPE public.status_empresa_t AS ENUM (
  'ativo',
  'sem_movimento',
  'encerrado'
);

CREATE TYPE public.tipo_empresa_t AS ENUM (
  'Matriz',
  'Filial',
  'Domestica'
);

CREATE TYPE public.tipo_prazo_t AS ENUM (
  'legal_dia20',
  'sem_prazo'
);

-- ============================================================
-- TABLES
-- ============================================================

-- usuarios
-- id referencia auth.users(id) (padrão Supabase Auth)
CREATE TABLE public.usuarios (
  id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  nome text NOT NULL,
  email text NOT NULL,
  perfil public.perfil_usuario NOT NULL DEFAULT 'analista',
  ativo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT usuarios_pkey PRIMARY KEY (id)
);

-- atividades
CREATE TABLE public.atividades (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  nome text NOT NULL,
  label_curto text NOT NULL,
  grupo public.grupo_atividade_t NOT NULL,
  tipo_prazo public.tipo_prazo_t NOT NULL DEFAULT 'sem_prazo',
  alerta_horas integer,
  requer_adiantamento boolean NOT NULL DEFAULT false,
  apenas_matriz boolean NOT NULL DEFAULT false,
  ordem integer NOT NULL,
  ativo boolean NOT NULL DEFAULT true,
  CONSTRAINT atividades_pkey PRIMARY KEY (id)
);

-- empresas
CREATE TABLE public.empresas (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  codigo integer NOT NULL,
  cnpj text,
  razao_social text NOT NULL,
  grupo_empresarial text,
  tipo_empresa public.tipo_empresa_t NOT NULL DEFAULT 'Matriz',
  status public.status_empresa_t NOT NULL DEFAULT 'ativo',
  regime_tributario public.regime_tributario_t,
  tem_adiantamento boolean NOT NULL DEFAULT false,
  data_adiantamento text,
  data_pagamento text,
  analista_id uuid,
  funcionarios integer NOT NULL DEFAULT 0,
  data_inicio date,
  data_fim date,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  motivo_inativacao text,
  CONSTRAINT empresas_pkey PRIMARY KEY (id),
  CONSTRAINT empresas_analista_id_fkey FOREIGN KEY (analista_id) REFERENCES public.usuarios(id)
);

-- competencias
CREATE TABLE public.competencias (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  mes integer NOT NULL,
  ano integer NOT NULL,
  status public.status_comp_t NOT NULL DEFAULT 'aberta',
  aberta_por uuid,
  data_abertura timestamptz NOT NULL DEFAULT now(),
  data_fechamento timestamptz,
  CONSTRAINT competencias_pkey PRIMARY KEY (id),
  CONSTRAINT competencias_aberta_por_fkey FOREIGN KEY (aberta_por) REFERENCES public.usuarios(id)
);

-- empresa_atividades
CREATE TABLE public.empresa_atividades (
  empresa_id uuid NOT NULL,
  atividade_id uuid NOT NULL,
  aplicavel boolean NOT NULL DEFAULT false,
  CONSTRAINT empresa_atividades_pkey PRIMARY KEY (empresa_id, atividade_id),
  CONSTRAINT empresa_atividades_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES public.empresas(id),
  CONSTRAINT empresa_atividades_atividade_id_fkey FOREIGN KEY (atividade_id) REFERENCES public.atividades(id)
);

-- empresa_competencia
CREATE TABLE public.empresa_competencia (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  empresa_id uuid NOT NULL,
  competencia_id uuid NOT NULL,
  tem_movimento boolean NOT NULL DEFAULT true,
  tem_adiantamento boolean NOT NULL DEFAULT false,
  funcionarios integer NOT NULL DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  analista_id uuid,
  CONSTRAINT empresa_competencia_pkey PRIMARY KEY (id),
  CONSTRAINT empresa_competencia_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES public.empresas(id),
  CONSTRAINT empresa_competencia_competencia_id_fkey FOREIGN KEY (competencia_id) REFERENCES public.competencias(id),
  CONSTRAINT empresa_competencia_analista_id_fkey FOREIGN KEY (analista_id) REFERENCES public.usuarios(id)
);

-- entregas
CREATE TABLE public.entregas (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  empresa_id uuid NOT NULL,
  competencia_id uuid NOT NULL,
  atividade_id uuid NOT NULL,
  data_conclusao date,
  nt boolean NOT NULL DEFAULT false,
  origem_nt text,
  usuario_id uuid,
  observacao text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  nao_ocorreu boolean NOT NULL DEFAULT false,
  CONSTRAINT entregas_pkey PRIMARY KEY (id),
  CONSTRAINT entregas_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES public.empresas(id),
  CONSTRAINT entregas_competencia_id_fkey FOREIGN KEY (competencia_id) REFERENCES public.competencias(id),
  CONSTRAINT entregas_atividade_id_fkey FOREIGN KEY (atividade_id) REFERENCES public.atividades(id),
  CONSTRAINT entregas_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id)
);
