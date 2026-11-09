-- ============================================================================
-- MERCADO VIVO — 012: market operations (RPCs para o frontend)
-- mv_buy_from_house, mv_create_listing, mv_cancel_listing, mv_buy_from_listing.
-- Motor 100% no servidor; o cliente só chama RPCs (regra #1).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Comprar stock ao House (fornecedor do sistema). WAC recalculado no SQL.
-- ---------------------------------------------------------------------------
create or replace function public.mv_buy_from_house(p_product uuid, p_quantity bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company  public.companies;
  v_wallet   public.wallets;
  v_house    public.wallets;
  v_product  public.products;
  v_inv      public.inventory;
  v_total    bigint;
begin
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Quantidade inválida.' using errcode = 'MV_INVALID_QTY';
  end if;
  if p_quantity > 10000 then
    raise exception 'Limite de 10000 unidades por compra.' using errcode = 'MV_QTY_LIMIT';
  end if;

  select * into v_company from public.companies
  where owner_id = auth.uid() and status = 'active';
  if not found then
    raise exception 'Empresa ativa não encontrada.' using errcode = 'MV_NO_COMPANY';
  end if;

  select * into v_product from public.products where id = p_product and active;
  if not found then
    raise exception 'Produto não encontrado ou inativo.' using errcode = 'MV_NO_PRODUCT';
  end if;

  select * into v_wallet from public.wallets
  where owner_type = 'company' and owner_id = v_company.id for update;

  select * into v_house from public.wallets
  where owner_type = 'house' for update;

  v_total := v_product.wholesale_cents * p_quantity;

  -- Dinheiro: Empresa -> House (dupla entrada equilibrada).
  perform mv_post_double_entry(
    'house_purchase', v_wallet.id, v_house.id, v_total,
    'product', v_product.id,
    format('Compra de %s x %s ao fornecedor', p_quantity::text, v_product.name)
  );

  -- Stock com custo médio ponderado (WAC), tudo em inteiros.
  insert into public.inventory (company_id, product_id, quantity, avg_cost_cents)
  values (v_company.id, v_product.id, p_quantity, v_product.wholesale_cents)
  on conflict (company_id, product_id) do update
    set quantity = inventory.quantity + excluded.quantity,
        avg_cost_cents = ((inventory.quantity * inventory.avg_cost_cents)
                          + (excluded.quantity * v_product.wholesale_cents))
                         / (inventory.quantity + excluded.quantity)
  returning * into v_inv;

  return jsonb_build_object(
    'ok', true,
    'total_cents', v_total,
    'quantity', v_inv.quantity,
    'avg_cost_cents', v_inv.avg_cost_cents
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Criar anúncio de venda (a reserva de stock é garantida pelo trigger de 007
-- e pela função mv_reserved_quantity/mv_free_stock de 011).
-- ---------------------------------------------------------------------------
create or replace function public.mv_create_listing(p_product uuid, p_quantity bigint, p_unit_price_cents bigint)
returns public.listings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company public.companies;
  v_listing public.listings;
begin
  if p_quantity <= 0 or p_unit_price_cents <= 0 then
    raise exception 'Quantidade e preço devem ser positivos.' using errcode = 'MV_INVALID_ARGS';
  end if;

  select * into v_company from public.companies
  where owner_id = auth.uid() and status = 'active';
  if not found then
    raise exception 'Empresa ativa não encontrada.' using errcode = 'MV_NO_COMPANY';
  end if;

  if not exists (select 1 from public.products where id = p_product and active) then
    raise exception 'Produto inválido.' using errcode = 'MV_NO_PRODUCT';
  end if;

  insert into public.listings (company_id, product_id, unit_price_cents, quantity)
  values (v_company.id, p_product, p_unit_price_cents, p_quantity)
  returning * into v_listing;

  return v_listing;
end;
$$;

-- ---------------------------------------------------------------------------
-- Cancelar anúncio próprio (liberta reserva: mv_reserved_quantity só conta open).
-- ---------------------------------------------------------------------------
create or replace function public.mv_cancel_listing(p_listing uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.listings
     set status = 'cancelled', closed_at = now()
   where id = p_listing
     and company_id = public.mv_company_of_user()
     and status = 'open';

  if not found then
    raise exception 'Anúncio não encontrado ou não pertence à tua empresa.'
      using errcode = 'MV_NOT_FOUND';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Comprar a partir de um anúncio aberto (marketplace P2P).
-- Fluxo monetário EQUILIBRADO por construção:
--   comprador: -gross
--   vendedor : +(gross - fee)
--   house    : +fee
-- Implementado como UMA única dupla entrada tripartida via duas transações
-- que partilham o mesmo efeito líquido, mantendo cada txn_id somando zero:
--   txn A: comprador -gross  |  vendedor +gross
--   txn B: vendedor  -fee    |  house     +fee
-- ---------------------------------------------------------------------------
create or replace function public.mv_buy_from_listing(p_listing uuid, p_quantity bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_listing  public.listings;
  v_buyer_c  public.companies;
  v_seller_c public.companies;
  v_buyer_w  public.wallets;
  v_seller_w public.wallets;
  v_house_w  public.wallets;
  v_buyer_inv public.inventory;
  v_avail    bigint;
  v_gross    bigint;
  v_fee      bigint;
  v_bps      bigint;
begin
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Quantidade inválida.' using errcode = 'MV_INVALID_QTY';
  end if;

  select * into v_buyer_c from public.companies
  where owner_id = auth.uid() and status = 'active';
  if not found then
    raise exception 'Empresa ativa não encontrada.' using errcode = 'MV_NO_COMPANY';
  end if;

  select * into v_listing from public.listings
  where id = p_listing and status = 'open' and expires_at > now()
  for update;
  if not found then
    raise exception 'Anúncio indisponível.' using errcode = 'MV_LISTING_UNAVAILABLE';
  end if;

  if v_listing.company_id = v_buyer_c.id then
    raise exception 'Não podes comprar ao teu próprio anúncio.' using errcode = 'MV_SELF_PURCHASE';
  end if;

  v_avail := v_listing.quantity - v_listing.sold_quantity;
  if p_quantity > v_avail then
    raise exception 'Apenas % unidades disponíveis neste anúncio.', v_avail
      using errcode = 'MV_INSUFFICIENT_STOCK';
  end if;

  select * into v_seller_c from public.companies
  where id = v_listing.company_id and status = 'active';
  if not found then
    raise exception 'Vendedor indisponível.' using errcode = 'MV_SELLER_UNAVAILABLE';
  end if;

  -- Selar stock do vendedor ANTES de mexer em dinheiro (rollback em erro).
  update public.inventory
     set quantity = quantity - p_quantity
   where company_id = v_seller_c.id
     and product_id = v_listing.product_id
     and quantity >= p_quantity;
  if not found then
    raise exception 'Stock do vendedor insuficiente (inconsistência detetada; operação abortada).'
      using errcode = 'MV_INSUFFICIENT_STOCK';
  end if;

  v_gross := v_listing.unit_price_cents * p_quantity;
  select (value #>> '{}')::bigint into v_bps from public.game_config where key = 'listing_fee_bps';
  v_bps := coalesce(v_bps, 50);
  v_fee := (v_gross * v_bps) / 10000;

  select * into v_buyer_w  from public.wallets where owner_type='company' and owner_id = v_buyer_c.id  for update;
  select * into v_seller_w from public.wallets where owner_type='company' and owner_id = v_seller_c.id for update;
  select * into v_house_w  from public.wallets where owner_type='house' for update;

  -- txn A: comprador paga gross ao vendedor.
  perform mv_post_double_entry('market_purchase', v_buyer_w.id, v_seller_w.id, v_gross,
    'listing', v_listing.id, format('Compra de %s un. via anúncio', p_quantity::text));

  -- txn B: vendedor paga a taxa ao house.
  if v_fee > 0 then
    perform mv_post_double_entry('tax', v_seller_w.id, v_house_w.id, v_fee,
      'listing', v_listing.id, 'Taxa do mercado');
  end if;

  -- Atualizar o anúncio.
  update public.listings
     set sold_quantity = sold_quantity + p_quantity,
         status = case when sold_quantity + p_quantity >= quantity then 'filled' else 'open' end,
         closed_at = case when sold_quantity + p_quantity >= quantity then now() else closed_at end
   where id = v_listing.id;

  -- Transferir stock para o comprador (WAC do comprador ajustado).
  insert into public.inventory (company_id, product_id, quantity, avg_cost_cents)
  values (v_buyer_c.id, v_listing.product_id, p_quantity, v_listing.unit_price_cents)
  on conflict (company_id, product_id) do update
    set quantity = inventory.quantity + excluded.quantity,
        avg_cost_cents = ((inventory.quantity * inventory.avg_cost_cents)
                          + (excluded.quantity * excluded.avg_cost_cents))
                         / (inventory.quantity + excluded.quantity)
  returning * into v_buyer_inv;

  -- Notificações às duas partes.
  perform mv_notify(v_seller_c.owner_id, 'sale_completed', 'Venda concluída',
    format('%s un. vendidas por %s cêntimos.', p_quantity::text, v_gross::text),
    'listing', v_listing.id);
  perform mv_notify(v_buyer_c.owner_id, 'purchase_completed', 'Compra concluída',
    format('%s un. compradas por %s cêntimos.', p_quantity::text, v_gross::text),
    'listing', v_listing.id);

  return jsonb_build_object(
    'ok', true,
    'gross_cents', v_gross,
    'fee_cents', v_fee,
    'net_cents', v_gross - v_fee,
    'buyer_quantity', v_buyer_inv.quantity
  );
end;
$$;

grant execute on function
  public.mv_buy_from_house(uuid, bigint),
  public.mv_create_listing(uuid, bigint, bigint),
  public.mv_cancel_listing(uuid),
  public.mv_buy_from_listing(uuid, bigint)
to authenticated;
