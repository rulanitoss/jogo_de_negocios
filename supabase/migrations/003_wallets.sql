-- ============================================================================
-- MERCADO VIVO — 003: wallets
-- Carteiras em cêntimos inteiros (BIGINT). Regra absoluta #2.
-- Cada carteira é uma conta de Ativo no razão de dupla entrada.
-- ============================================================================

create table public.wallets (
  id            uuid primary key default gen_random_uuid(),
  owner_type    text not null check (owner_type in ('user', 'company', 'house', 'tax_authority', 'bank')),
  owner_id      uuid not null,           -- profiles.id / companies.id; NULL-ish para entidades do sistema via sentinel
  balance_cents bigint not null default 0 check (balance_cents >= 0),
  currency      char(3) not null default 'EUR',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (owner_type, owner_id)
);

comment on table public.wallets is
  'Carteiras em cêntimos (BIGINT). O saldo é DERIVADO e validado contra o ledger (mv_assert_wallet_consistency).';

create trigger wallets_set_updated_at
  before update on public.wallets
  for each row execute function public.updated_at_trigger();

-- Entidades estruturais do sistema (House = emissora do capital inicial;
-- Tax Authority; Bank) — IDs fixos determinísticos.
insert into public.wallets (owner_type, owner_id, balance_cents) values
  ('house',         '00000000-0000-0000-0000-000000000001', 0),
  ('tax_authority', '00000000-0000-0000-0000-000000000002', 0),
  ('bank',          '00000000-0000-0000-0000-000000000003', 0)
on conflict (owner_type, owner_id) do nothing;

-- Carteira da empresa criada junto com a empresa (via RPC create_career, migração 010).
