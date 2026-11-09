-- ============================================================================
-- MERCADO VIVO — 014: bankruptcy (falência)
-- Empresa em falência quando: saldo = 0 E valor de stock = 0 — nada resta
-- para liquidar. Listings e ofertas são cancelados; o estado final fica
-- auditável no ledger imutável (dupla entrada sempre equilibrada).
-- ============================================================================

-- Valor de mercado do stock duma empresa (qty x avg_cost), em cêntimos.
create or replace function public.mv_inventory_value(p_company uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(quantity * avg_cost_cents), 0)::bigint
  from public.inventory
  where company_id = p_company;
$$;

-- Património (equity) da empresa = saldo da carteira + valor do stock a custo.
-- Definição do jogo: equity = cash + inventory value.
create or replace function public.mv_equity(p_company uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(w.balance_cents, 0) + public.mv_inventory_value(p_company)
  from public.companies c
  join public.wallets w on w.owner_type = 'company' and w.owner_id = c.id
  where c.id = p_company;
$$;

-- Avaliar e declarar falência duma empresa (idempotente).
create or replace function public.mv_evaluate_bankruptcy(p_company uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company public.companies;
  v_wallet  public.wallets;
  v_inv     bigint;
begin
  select * into v_company from public.companies
  where id = p_company and status = 'active' for update;
  if not found then return false; end if;

  select * into v_wallet from public.wallets
  where owner_type = 'company' and owner_id = p_company for update;

  v_inv := public.mv_inventory_value(p_company);

  -- Falência: sem dinheiro E sem ativos (stock a custo) => nada para liquidar.
  if v_wallet.balance_cents = 0 and v_inv = 0 then
    -- Cancelar listings abertos (liberta reservas inexistentes mas limpa o book).
    update public.listings set status = 'cancelled', closed_at = now()
    where company_id = p_company and status = 'open';

    -- Cancelar ofertas pendentes desta empresa.
    update public.offers set status = 'cancelled'
    where (from_company_id = p_company or to_company_id = p_company)
      and status = 'pending';

    update public.companies
       set status = 'bankrupt', bankrupt_at = now()
     where id = p_company;

    perform mv_notify(v_company.owner_id, 'bankruptcy_declared',
      'A tua empresa declarou falência',
      'Sem caixa e sem ativos, a carreira foi encerrada. Podes criar uma nova empresa.',
      'company', p_company);

    insert into public.admin_actions (admin_id, action, target_type, target_id, details)
    values (v_company.owner_id, 'bankruptcy_auto_declared', 'company', p_company,
            jsonb_build_object('wallet_cents', v_wallet.balance_cents));

    return true;
  end if;

  -- Aviso: caixa baixa (< 5% do capital inicial) sem stock vendável relevante.
  if v_wallet.balance_cents < 1000 and v_inv = 0 then
    insert into public.notifications (user_id, kind, title, body, ref_type, ref_id)
    select v_company.owner_id, 'bankruptcy_warning',
           'Risco de falência', 'Estás quase sem caixa e sem ativos.', 'company', p_company
    where not exists (
      select 1 from public.notifications n
      where n.user_id = v_company.owner_id
        and n.kind = 'bankruptcy_warning'
        and n.created_at > now() - interval '24 hours'
    );
  end if;

  return false;
end;
$$;

-- Sweep global: percorre todas as empresas ativas e avalia falência.
-- Chamado pela Edge Function bankruptcy-sweep (agendada via pg_cron/scheduler).
create or replace function public.mv_bankruptcy_sweep()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_count int := 0;
begin
  for r in select id from public.companies where status = 'active' loop
    if public.mv_evaluate_bankruptcy(r.id) then
      v_count := v_count + 1;
    end if;
  end loop;

  perform public.mv_expire_offers();

  -- Expirar listings vencidos.
  update public.listings
     set status = 'expired', closed_at = now()
   where status = 'open' and expires_at <= now();

  return jsonb_build_object('declared', v_count, 'at', now());
end;
$$;

grant execute on function public.mv_bankruptcy_sweep() to service_role;
grant execute on function public.mv_evaluate_bankruptcy(uuid) to service_role;
grant execute on function public.mv_inventory_value(uuid) to authenticated;
grant execute on function public.mv_equity(uuid) to authenticated;
