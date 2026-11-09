-- ============================================================================
-- MERCADO VIVO — 013: offers functions (negociação direta)
-- mv_make_offer, mv_accept_offer, mv_reject_offer, mv_cancel_offer.
-- Aceitação = troca atómica de dinheiro por stock, 100% no servidor.
-- ---------------------------------------------------------------------------
-- Fluxo monetário na aceitação (sem escrow intermédio, transação única):
--   comprador -total | vendedor +total ; stock move-se na mesma transação.
-- ============================================================================

create or replace function public.mv_make_offer(
  p_to_company uuid,
  p_product uuid,
  p_quantity bigint,
  p_unit_price_cents bigint,
  p_message text default ''
)
returns public.offers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_from public.companies;
  v_offer public.offers;
begin
  if p_quantity <= 0 or p_unit_price_cents <= 0 then
    raise exception 'Quantidade e preço devem ser positivos.' using errcode = 'MV_INVALID_ARGS';
  end if;

  select * into v_from from public.companies
  where owner_id = auth.uid() and status = 'active';
  if not found then
    raise exception 'Empresa ativa não encontrada.' using errcode = 'MV_NO_COMPANY';
  end if;

  if p_to_company = v_from.id then
    raise exception 'Não podes fazer uma oferta a ti mesmo.' using errcode = 'MV_SELF_OFFER';
  end if;

  if not exists (select 1 from public.companies where id = p_to_company and status = 'active') then
    raise exception 'Empresa destinatária inválida.' using errcode = 'MV_NO_COMPANY';
  end if;

  if not exists (select 1 from public.products where id = p_product and active) then
    raise exception 'Produto inválido.' using errcode = 'MV_NO_PRODUCT';
  end if;

  insert into public.offers (from_company_id, to_company_id, product_id, quantity, unit_price_cents, message)
  values (v_from.id, p_to_company, p_product, p_quantity, p_unit_price_cents, coalesce(p_message, ''))
  returning * into v_offer;

  perform mv_notify(
    (select owner_id from public.companies where id = p_to_company),
    'offer_new', 'Nova oferta recebida',
    format('%s propõe %s un. a %s cêntimos/un.', v_from.name, p_quantity::text, p_unit_price_cents::text),
    'offer', v_offer.id
  );

  return v_offer;
end;
$$;

-- ---------------------------------------------------------------------------
-- Aceitar oferta: VERIFICAÇÃO DE STOCK DO EMISOR + saldo do recetor,
-- movimento monetário via dupla entrada, transferência de stock WAC.
-- ---------------------------------------------------------------------------
create or replace function public.mv_accept_offer(p_offer uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_offer    public.offers;
  v_from     public.companies;
  v_to       public.companies;
  w_from     public.wallets;
  w_to       public.wallets;
  v_inv_from public.inventory;
  v_total    bigint;
  v_txn      uuid;
begin
  select * into v_offer from public.offers where id = p_offer for update;
  if not found then
    raise exception 'Oferta não encontrada.' using errcode = 'MV_NOT_FOUND';
  end if;

  if v_offer.status <> 'pending' then
    raise exception 'Esta oferta já não está pendente.' using errcode = 'MV_OFFER_STALE';
  end if;
  if v_offer.expires_at <= now() then
    update public.offers set status = 'expired' where id = p_offer;
    raise exception 'Oferta expirada.' using errcode = 'MV_OFFER_EXPIRED';
  end if;

  -- Apenas o destinatário pode aceitar.
  select * into v_to from public.companies
  where owner_id = auth.uid() and id = v_offer.to_company_id and status = 'active';
  if not found then
    raise exception 'Não és o destinatário desta oferta (ou a tua empresa não está ativa).'
      using errcode = 'MV_FORBIDDEN';
  end if;

  select * into v_from from public.companies where id = v_offer.from_company_id and status = 'active';
  if not found then
    raise exception 'Emissor indisponível.' using errcode = 'MV_SELLER_UNAVAILABLE';
  end if;

  -- Stock livre do emissor (desconta reservas de listings).
  if public.mv_free_stock(v_from.id, v_offer.product_id) < v_offer.quantity then
    raise exception 'O emissor já não tem stock livre suficiente.'
      using errcode = 'MV_INSUFFICIENT_STOCK';
  end if;

  v_total := v_offer.total_cents;

  select * into w_to   from public.wallets where owner_type='company' and owner_id = v_to.id   for update;
  select * into w_from from public.wallets where owner_type='company' and owner_id = v_from.id for update;

  -- Movimento monetário: recetor (comprador) paga ao emissor (vendedor).
  v_txn := mv_post_double_entry(
    'offer_release', w_to.id, w_from.id, v_total,
    'offer', v_offer.id, 'Aceitação de oferta direta'
  );

  -- Transferência de stock do emissor (débito físico; o listing reservado
  -- é libertado porque o emissor mantém o anúncio? NÃO — ofertas usam stock
  -- LIVRE, portanto baixamos quantity diretamente).
  update public.inventory
     set quantity = quantity - v_offer.quantity
   where company_id = v_from.id and product_id = v_offer.product_id;

  insert into public.inventory (company_id, product_id, quantity, avg_cost_cents)
  values (v_to.id, v_offer.product_id, v_offer.quantity, v_offer.unit_price_cents)
  on conflict (company_id, product_id) do update
    set quantity = inventory.quantity + excluded.quantity,
        avg_cost_cents = ((inventory.quantity * inventory.avg_cost_cents)
                          + (excluded.quantity * excluded.avg_cost_cents))
                         / (inventory.quantity + excluded.quantity)
  returning * into v_inv_from;

  update public.offers
     set status = 'accepted', responded_at = now()
   where id = p_offer;

  perform mv_notify(v_from.owner_id, 'offer_accepted', 'Oferta aceite',
    format('%s aceitou a tua oferta (%s cêntimos).', v_to.name, v_total::text),
    'offer', v_offer.id);
  perform mv_notify(v_to.owner_id, 'purchase_completed', 'Compra em negociação concluída',
    format('Pagaste %s cêntimos por %s un.', v_total::text, v_offer.quantity::text),
    'offer', v_offer.id);

  return jsonb_build_object('ok', true, 'txn_id', v_txn, 'total_cents', v_total);
end;
$$;

create or replace function public.mv_reject_offer(p_offer uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_offer public.offers;
begin
  select * into v_offer from public.offers where id = p_offer for update;
  if not found or v_offer.status <> 'pending' then
    raise exception 'Oferta não encontrada ou já respondida.' using errcode = 'MV_OFFER_STALE';
  end if;
  if v_offer.to_company_id <> public.mv_company_of_user() then
    raise exception 'Só o destinatário pode rejeitar.' using errcode = 'MV_FORBIDDEN';
  end if;

  update public.offers set status = 'rejected', responded_at = now() where id = p_offer;

  perform mv_notify(
    (select owner_id from public.companies where id = v_offer.from_company_id),
    'offer_rejected', 'Oferta rejeitada', 'A tua oferta foi recusada.', 'offer', p_offer);
end;
$$;

create or replace function public.mv_cancel_offer(p_offer uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_offer public.offers;
begin
  select * into v_offer from public.offers where id = p_offer for update;
  if not found or v_offer.status <> 'pending' then
    raise exception 'Oferta não encontrada ou já respondida.' using errcode = 'MV_OFFER_STALE';
  end if;
  if v_offer.from_company_id <> public.mv_company_of_user() then
    raise exception 'Só o emissor pode cancelar.' using errcode = 'MV_FORBIDDEN';
  end if;

  update public.offers set status = 'cancelled', responded_at = now() where id = p_offer;

  perform mv_notify(
    (select owner_id from public.companies where id = v_offer.to_company_id),
    'offer_cancelled', 'Oferta cancelada', 'O emissor retirou a oferta.', 'offer', p_offer);
end;
$$;

-- Expiração periódica de ofertas pendentes (chamado pela Edge Function/sweep).
create or replace function public.mv_expire_offers()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  with expired as (
    update public.offers
       set status = 'expired'
     where status = 'pending' and expires_at <= now()
     returning id, from_company_id, to_company_id
  )
  select count(*) into n from expired;

  insert into public.notifications (user_id, kind, title, body, ref_type, ref_id)
  select c.owner_id, 'offer_cancelled', 'Oferta expirada',
         'Uma oferta expirou sem resposta.', 'offer', e.id
    from expired e
    join public.companies c on c.id = e.from_company_id;

  return n;
end;
$$;

grant execute on function
  public.mv_make_offer(uuid, uuid, bigint, bigint, text),
  public.mv_accept_offer(uuid),
  public.mv_reject_offer(uuid),
  public.mv_cancel_offer(uuid)
to authenticated;
