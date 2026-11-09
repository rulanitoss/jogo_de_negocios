-- ============================================================================
-- MERCADO VIVO — 002: companies
-- Empresas dos jogadores. Uma empresa por utilizador (carreira).
-- ============================================================================

create table public.companies (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references public.profiles (id) on delete cascade,
  name          text not null check (char_length(name) between 3 and 60),
  legal_form    text not null default 'Lda' check (legal_form in ('Lda', 'SA', 'ENI')),
  slogan        text not null default '',
  logo_url      text,
  -- Estado da carreira
  status        text not null default 'active'
                check (status in ('active', 'suspended', 'bankrupt', 'closed')),
  founded_at    timestamptz not null default now(),
  bankrupt_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (owner_id)
);

comment on table public.companies is
  'Empresa (carreira) de cada jogador. 1:1 com profiles.';

create trigger companies_set_updated_at
  before update on public.companies
  for each row execute function public.updated_at_trigger();

create index companies_owner_idx on public.companies (owner_id);
create index companies_status_idx on public.companies (status);
