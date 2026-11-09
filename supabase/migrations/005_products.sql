-- ============================================================================
-- MERCADO VIVO — 005: products
-- Catálogo de produtos base (SKU global). Os jogadores compram stock ao
-- "house" (fornecedor do sistema) e revendem a outros jogadores.
-- ============================================================================

create table public.products (
  id              uuid primary key default gen_random_uuid(),
  sku             text not null unique check (sku ~ '^[A-Z0-9-]{3,32}$'),
  category_id     uuid not null references public.categories (id) on delete restrict,
  name            text not null check (char_length(name) between 2 and 80),
  description     text not null default '',
  -- Preço a que o HOUSE vende aos jogadores (compra de stock), em cêntimos.
  wholesale_cents bigint not null check (wholesale_cents > 0),
  -- Preço sugerido de retalho (referência para o índice de mercado), em cêntimos.
  msrp_cents      bigint not null check (msrp_cents >= wholesale_cents),
  -- Demanda base usada pelo motor de preços (0..100).
  demand_index    int not null default 50 check (demand_index between 0 and 100),
  image_url       text,
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create trigger products_set_updated_at
  before update on public.products
  for each row execute function public.updated_at_trigger();

create index products_category_idx on public.products (category_id);
create index products_active_idx on public.products (active);

comment on table public.products is
  'Catálogo global de SKUs. Todos os valores em cêntimos (BIGINT).';
