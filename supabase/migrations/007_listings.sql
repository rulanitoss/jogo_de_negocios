-- ============================================================================
-- MERCADO VIVO — 007: listings
-- Anúncios de venda no mercado aberto (order book simplificado).
-- O stock anunciado fica RESERVADO (reserved_quantity) até ser vendido ou
-- o anúncio ser cancelado/expirado.
-- ============================================================================

create table public.listings (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references public.companies (id) on delete cascade,
  product_id     uuid not null references public.products (id) on delete restrict,
  unit_price_cents bigint not null check (unit_price_cents > 0),
  quantity       bigint not null check (quantity > 0),
  sold_quantity  bigint not null default 0 check (sold_quantity >= 0 and sold_quantity <= quantity),
  status         text not null default 'open'
                 check (status in ('open', 'filled', 'cancelled', 'expired')),
  created_at     timestamptz not null default now(),
  expires_at     timestamptz not null default (now() + interval '7 days'),
  closed_at      timestamptz
);

comment on table public.listings is
  'Anúncios de retalho. Reservam stock via mv_reserve/unreserve (motor em 012).';

create index listings_open_idx on public.listings (product_id, status, unit_price_cents)
  where status = 'open';
create index listings_company_idx on public.listings (company_id);

-- Trigger de validação: só pode haver reserva se existir stock livre.
create or replace function public.validate_listing_insert()
returns trigger
language plpgsql
as $$
declare
  inv public.inventory%rowtype;
begin
  select * into inv
  from public.inventory
  where company_id = new.company_id and product_id = new.product_id;

  if inv.id is null then
    raise exception 'Sem stock deste produto (empresa %, produto %).',
      new.company_id, new.product_id
      using errcode = 'MV_NO_STOCK';
  end if;

  if inv.quantity - mv_reserved_quantity(new.company_id, new.product_id) < new.quantity then
    raise exception 'Stock insuficiente para anunciar: disponível %, pretendido %.',
      inv.quantity - mv_reserved_quantity(new.company_id, new.product_id), new.quantity
      using errcode = 'MV_INSUFFICIENT_STOCK';
  end if;

  return new;
end;
$$;

create trigger listings_validate_stock
  before insert on public.listings
  for each row
  when (new.status = 'open')
  execute function public.validate_listing_insert();
