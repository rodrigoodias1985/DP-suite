# DP+ Suite

Projeto em fase de testes. Aplicação vanilla JS com Supabase.

## Setup

1. Crie um arquivo `.env` baseado em `.env.example`
2. Preencha com suas credenciais Supabase
3. Abra `index.html` no navegador

## Banco de Dados

- **Migrations**: Veja a pasta `migrations/`
- **Schema**: `migrations/001_schema_completo.sql` é o snapshot atual do banco
- **Deploy**: Aplicar mudanças manualmente no SQL Editor do Supabase

## Fluxo de Features

1. Criar `00X_nova_feature.sql` em `migrations/`
2. Aplicar no banco de testes manualmente
3. Validar no `index.html`
4. Aplicar no banco de produção
5. Push do `index.html` + migration no mesmo commit
