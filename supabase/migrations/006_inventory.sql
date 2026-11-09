-- ============================================================================
-- MERCADO VIVO — 006: inventory
-- Stock detido por cada empresa. Quantidades inteiras; custo médio ponderado
-- (WAC) em cêntimos, recalculado no servidor em cada compra.
-- ============================================================================

create table public.inventory (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references public.companies (id) on delete cascade,
  product_id         uuid not null references public.products (id) on delete restrict,
  quantity           bigint not null default 0 check (quantity >= 0),
  -- Custo médio ponderado, em cêntimos inteiros (arredondado para baixo).
  avg_cost_cents     bigint not null default 0 check (avg_cost_cents >= 0),
  updated_at         timestamptz not null default now(),
  unique (company_id, product_id)
);

comment on table public.inventory is
  'Stock por empresa/produto. avg_cost_cents = WAC gerido pelo motor SQL (mv_buy_from_house).';

create trigger inventory_set_updated_at
  before update on public.inventory
  for each row execute function public.updated_at_trigger();

create index inventory_company_idx on public.inventory (company_id);
create index inventory_product_idx on public.inventory (product_id);
