-- ============================================================================
-- MERCADO VIVO — 011: market core functions
-- Primitivas do motor financeiro: dupla entrada, reserva de stock, WAC.
-- Todas SECURITY DEFINER; NENHUMA lógica monetária no cliente (regra #1).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- mv_post_double_entry: PRIMITIVA ÚNICA de movimento de dinheiro.
-- Débito (saldo -amount) na carteira p_debit, crédito (+amount) em p_credit,
-- sempre com linhas de ledger que somam zero e atualização atómica dos saldos.
-- ---------------------------------------------------------------------------
create or replace function public.mv_post_double_entry(
  p_reason   text,
  p_debit    uuid,
  p_credit   uuid,
  p_amount   bigint,
  p_ref_type text default null,
  p_ref_id   uuid   default null,
  p_memo     text   default ''
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_txn uuid := gen_random_uuid();
  v_debit_balance bigint;
begin
  if p_amount <= 0 then
    raise exception 'Montante deve ser positivo (recebeu %).', p_amount
      using errcode = 'MV_INVALID_AMOUNT';
  end if;
  if p_debit = p_credit then
    raise exception 'Carteira de débito e crédito não podem ser iguais.'
      using errcode = 'MV_SAME_WALLET';
  end if;

  -- Bloqueio pessimista determinístico (evita deadlocks): ordenar por id.
  select balance_cents into v_debit_balance
  from public.wallets where id = least(p_debit, p_credit) for update;
  select balance_cents into v_debit_balance
  from public.wallets where id = greatest(p_debit, p_credit) for update;

  select balance_cents into v_debit_balance
  from public.wallets where id = p_debit;

  if v_debit_balance < p_amount then
    raise exception 'Saldo insuficiente: disponível %, necessário %.',
      v_debit_balance, p_amount
      using errcode = 'MV_INSUFFICIENT_FUNDS';
  end if;

  update public.wallets set balance_cents = balance_cents - p_amount where id = p_debit;
  update public.wallets set balance_cents = balance_cents + p_amount where id = p_credit;

  insert into public.ledger_entries (txn_id, reason, wallet_id, delta_cents, ref_type, ref_id, memo)
  values
    (v_txn, p_reason, p_debit,  -p_amount, p_ref_type, p_ref_id, p_memo),
    (v_txn, p_reason, p_credit,  p_amount, p_ref_type, p_ref_id, p_memo);

  return v_txn;
end;
$$;

comment on function public.mv_post_double_entry is
  'Primitiva única de movimento monetário (dupla entrada, BIGINT cêntimos).';

-- ---------------------------------------------------------------------------
-- mv_reserved_quantity: stock já comprometido por listings abertos.
-- ---------------------------------------------------------------------------
create or replace function public.mv_reserved_quantity(p_company uuid, p_product uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(quantity - sold_quantity), 0)::bigint
  from public.listings
  where company_id = p_company
    and product_id = p_product
    and status = 'open';
$$;

-- ---------------------------------------------------------------------------
-- mv_free_stock: quantidade disponível para anunciar/vender.
-- ---------------------------------------------------------------------------
create or replace function public.mv_free_stock(p_company uuid, p_product uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(i.quantity, 0) - public.mv_reserved_quantity(p_company, p_product)
  from (select 1) dummy
  left join public.inventory i
    on i.company_id = p_company and i.product_id = p_product;
$$;

-- ---------------------------------------------------------------------------
-- mv_notify: helper interno de notificações (usado pelo motor).
-- ---------------------------------------------------------------------------
create or replace function public.mv_notify(
  p_user uuid, p_kind text, p_title text, p_body text,
  p_ref_type text default null, p_ref_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user is null then return; end if;
  insert into public.notifications (user_id, kind, title, body, ref_type, ref_id)
  values (p_user, p_kind, p_title, p_body, p_ref_type, p_ref_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- mv_company_of_user: resolve a empresa do utilizador autenticado.
-- ---------------------------------------------------------------------------
create or replace function public.mv_company_of_user()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from public.companies where owner_id = auth.uid() limit 1;
$$;

-- ---------------------------------------------------------------------------
-- mv_effective_price: preço efetivo corrente de um produto para o mercado.
-- = menor preço aberto nos listings; se não houver, msrp * fator de demanda.
-- Usado pelo índice e histórico (migração 020).
-- ---------------------------------------------------------------------------
create or replace function public.mv_effective_price(p_product uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select min(l.unit_price_cents)
       from public.listings l
      where l.product_id = p_product and l.status = 'open'
        and l.expires_at > now()),
    (select pr.msrp_cents * (100 + (pr.demand_index - 50)) / 100
       from public.products pr where pr.id = p_product),
    0
  );
$$;
