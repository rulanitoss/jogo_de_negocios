-- ============================================================================
-- MERCADO VIVO — 021: orders (encomendas com escrow no Bank)
-- Ciclo de vida: escrow -> shipped -> completed | refunded | disputed.
-- O dinheiro sai do comprador para o Bank (escrow real via dupla entrada) e
-- só é libertado ao vendedor na confirmação de receção. Stock move-se na
-- criação da encomenda (reserva física), devolvendo ao vendedor em refund.
-- ============================================================================

create table public.orders (
  id                uuid primary key default gen_random_uuid(),
  listing_id        uuid not null references public.listings (id) on delete restrict,
  buyer_company_id  uuid not null references public.companies (id) on delete restrict,
  seller_company_id uuid not null references public.companies (id) on delete restrict,
  product_id        uuid not null references public.products (id) on delete restrict,
  quantity          bigint not null check (quantity > 0),
  unit_price_cents  bigint not null check (unit_price_cents > 0),
  total_cents       bigint generated always as (quantity * unit_price_cents) stored,
  status            text not null default 'escrow'
                    check (status in ('escrow', 'shipped', 'completed', 'refunded', 'disputed')),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create trigger orders_set_updated_at
  before update on public.orders
  for each row execute function public.updated_at_trigger();

create index orders_buyer_idx  on public.orders (buyer_company_id, status);
create index orders_seller_idx on public.orders (seller_company_id, status);

alter table public.orders enable row level security;

create policy orders_read_parties on public.orders
  for select using (
    buyer_company_id = public.mv_company_of_user()
    or seller_company_id = public.mv_company_of_user()
    or public.mv_is_admin()
  );

comment on table public.orders is
  'Encomendas P2P com escrow no Bank. mv_buy_from_listing mantém a compra imediata; orders é o fluxo com entrega/confirmação.';

-- ---------------------------------------------------------------------------
-- Criar encomenda: reserva stock + dinheiro vai para escrow (Bank).
-- ---------------------------------------------------------------------------
create or replace function public.mv_create_order(p_listing uuid, p_quantity bigint)
returns public.orders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_listing public.listings;
  v_buyer   public.companies;
  v_seller  public.companies;
  w_buyer   public.wallets;
  w_bank    public.wallets;
  v_order   public.orders;
  v_avail   bigint;
  v_total   bigint;
begin
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Quantidade inválida.' using errcode = 'MV_INVALID_QTY';
  end if;

  select * into v_buyer from public.companies where owner_id = auth.uid() and status='active';
  if not found then raise exception 'Empresa ativa não encontrada.' using errcode = 'MV_NO_COMPANY'; end if;

  select * into v_listing from public.listings
  where id = p_listing and status = 'open' and expires_at > now() for update;
  if not found then raise exception 'Anúncio indisponível.' using errcode = 'MV_LISTING_UNAVAILABLE'; end if;

  if v_listing.company_id = v_buyer.id then
    raise exception 'Não podes comprar ao teu próprio anúncio.' using errcode = 'MV_SELF_PURCHASE';
  end if;

  v_avail := v_listing.quantity - v_listing.sold_quantity;
  if p_quantity > v_avail then
    raise exception 'Apenas % unidades disponíveis neste anúncio.', v_avail
      using errcode = 'MV_INSUFFICIENT_STOCK';
  end if;

  select * into v_seller from public.companies where id = v_listing.company_id and status='active';
  if not found then raise exception 'Vendedor indisponível.' using errcode = 'MV_SELLER_UNAVAILABLE'; end if;

  -- Movimentação física do stock para o "limbo" da encomenda: baixa já o
  -- stock do vendedor (fica comprometido pela order até complete/refund).
  update public.inventory set quantity = quantity - p_quantity
  where company_id = v_seller.id and product_id = v_listing.product_id
    and quantity >= p_quantity;
  if not found then
    raise exception 'Stock do vendedor insuficiente.' using errcode = 'MV_INSUFFICIENT_STOCK';
  end if;

  update public.listings
     set sold_quantity = sold_quantity + p_quantity,
         status = case when sold_quantity + p_quantity >= quantity then 'filled' else 'open' end,
         closed_at = case when sold_quantity + p_quantity >= quantity then now() else closed_at end
  where id = v_listing.id;

  v_total := v_listing.unit_price_cents * p_quantity;

  select * into w_buyer from public.wallets where owner_type='company' and owner_id = v_buyer.id for update;
  select * into w_bank  from public.wallets where owner_type='bank' for update;

  perform mv_post_double_entry('order_escrow', w_buyer.id, w_bank.id, v_total,
    'listing', v_listing.id, 'Escrow de encomenda');

  insert into public.orders (listing_id, buyer_company_id, seller_company_id, product_id, quantity, unit_price_cents)
  values (v_listing.id, v_buyer.id, v_seller.id, v_listing.product_id, p_quantity, v_listing.unit_price_cents)
  returning * into v_order;

  perform mv_notify(v_seller.owner_id, 'system', 'Nova encomenda recebida',
    format('Encomenda de %s un. criada. Confirma o envio.', p_quantity::text), 'order', v_order.id);

  return v_order;
end;
$$;

-- Marcar como enviado (vendedor).
create or replace function public.mv_ship_order(p_order uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.orders set status = 'shipped'
  where id = p_order
    and seller_company_id = public.mv_company_of_user()
    and status = 'escrow';
  if not found then
    raise exception 'Encomenda não encontrada ou estado inválido.' using errcode = 'MV_NOT_FOUND';
  end if;

  perform mv_notify(
    (select b.owner_id from public.orders o join public.companies b on b.id = o.buyer_company_id where o.id = p_order),
    'system', 'Encomenda enviada', 'O vendedor confirmou o envio.', 'order', p_order);
end;
$$;

-- Confirmar receção (comprador): Bank liberta (total - taxa) ao vendedor,
-- taxa ao House, e o stock entra na carteira do comprador (WAC).
create or replace function public.mv_complete_order(p_order uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order   public.orders;
  w_bank    public.wallets;
  w_seller  public.wallets;
  w_house   public.wallets;
  v_seller  public.companies;
  v_buyer   public.companies;
  v_fee     bigint;
  v_bps     bigint;
begin
  select * into v_order from public.orders where id = p_order for update;
  if not found then raise exception 'Encomenda não encontrada.' using errcode = 'MV_NOT_FOUND'; end if;
  if v_order.status <> 'shipped' then
    raise exception 'Estado inválido para confirmação.' using errcode = 'MV_BAD_STATE';
  end if;
  if v_order.buyer_company_id <> public.mv_company_of_user() then
    raise exception 'Só o comprador pode confirmar a receção.' using errcode = 'MV_FORBIDDEN';
  end if;

  select * into v_seller from public.companies where id = v_order.seller_company_id;
  select * into v_buyer  from public.companies where id = v_order.buyer_company_id;

  select (value #>> '{}')::bigint into v_bps from public.game_config where key = 'listing_fee_bps';
  v_bps := coalesce(v_bps, 50);
  v_fee := (v_order.total_cents * v_bps) / 10000;

  select * into w_bank   from public.wallets where owner_type='bank' for update;
  select * into w_seller from public.wallets where owner_type='company' and owner_id = v_seller.id for update;
  select * into w_house  from public.wallets where owner_type='house' for update;

  -- Bank -> vendedor (líquido) e Bank -> house (taxa). Cada txn soma zero.
  perform mv_post_double_entry('order_payout', w_bank.id, w_seller.id, v_order.total_cents - v_fee,
    'order', v_order.id, 'Libertação de escrow (vendedor)');
  if v_fee > 0 then
    perform mv_post_double_entry('tax', w_bank.id, w_house.id, v_fee,
      'order', v_order.id, 'Taxa do mercado (pago do escrow)');
  end if;

  -- Stock físico entregue ao comprador.
  insert into public.inventory (company_id, product_id, quantity, avg_cost_cents)
  values (v_buyer.id, v_order.product_id, v_order.quantity, v_order.unit_price_cents)
  on conflict (company_id, product_id) do update
    set quantity = inventory.quantity + excluded.quantity,
        avg_cost_cents = ((inventory.quantity * inventory.avg_cost_cents)
                          + (excluded.quantity * excluded.avg_cost_cents))
                         / (inventory.quantity + excluded.quantity);

  update public.orders set status = 'completed' where id = p_order;

  perform mv_notify(v_seller.owner_id, 'sale_completed', 'Encomenda concluída',
    format('Recebeste %s cêntimos (líquidos).', (v_order.total_cents - v_fee)::text), 'order', v_order.id);
  perform mv_notify(v_buyer.owner_id, 'purchase_completed', 'Receção confirmada',
    'Stock adicionado ao teu inventário.', 'order', v_order.id);

  return jsonb_build_object('ok', true, 'net_cents', v_order.total_cents - v_fee, 'fee_cents', v_fee);
end;
$$;

-- Reembolsar (antes do shipping, pelo comprador; ou por decisão admin/após disputa):
-- devolve dinheiro do Bank ao comprador e stock ao vendedor.
create or replace function public.mv_refund_order(p_order uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order  public.orders;
  w_bank   public.wallets;
  w_buyer  public.wallets;
begin
  select * into v_order from public.orders where id = p_order for update;
  if not found then raise exception 'Encomenda não encontrada.' using errcode = 'MV_NOT_FOUND'; end if;
  if v_order.status not in ('escrow', 'disputed') then
    raise exception 'Refund apenas permitido em escrow/disputa.' using errcode = 'MV_BAD_STATE';
  end if;
  if v_order.buyer_company_id <> public.mv_company_of_user() and not public.mv_is_admin() then
    raise exception 'Sem permissão para reembolsar.' using errcode = 'MV_FORBIDDEN';
  end if;

  select * into w_bank  from public.wallets where owner_type='bank' for update;
  select * into w_buyer from public.wallets where owner_type='company' and owner_id = v_order.buyer_company_id for update;

  perform mv_post_double_entry('order_refund', w_bank.id, w_buyer.id, v_order.total_cents,
    'order', v_order.id, 'Reembolso de escrow');

  -- Devolver stock ao vendedor.
  insert into public.inventory (company_id, product_id, quantity, avg_cost_cents)
  values (v_order.seller_company_id, v_order.product_id, v_order.quantity, v_order.unit_price_cents)
  on conflict (company_id, product_id) do update
    set quantity = inventory.quantity + excluded.quantity;

  update public.orders set status = 'refunded' where id = p_order;

  perform mv_notify(
    (select s.owner_id from public.companies s where s.id = v_order.seller_company_id),
    'system', 'Encomenda reembolsada', 'O stock foi devolvido ao teu inventário.', 'order', v_order.id);
end;
$$;

grant execute on function
  public.mv_create_order(uuid, bigint),
  public.mv_ship_order(uuid),
  public.mv_complete_order(uuid),
  public.mv_refund_order(uuid)
to authenticated;
