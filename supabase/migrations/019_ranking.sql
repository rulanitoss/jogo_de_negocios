-- ============================================================================
-- MERCADO VIVO — 019: ranking
-- Ranking de empresas por património (equity). Vista + RPCs mv_ranking e
-- mv_my_rank. Tudo derivado de dados reais (equity_history / wallets).
-- ============================================================================

-- Estado corrente duma empresa para o ranking (cash + stock, tempo real).
create or replace function public.mv_company_equity_live(p_company uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select public.mv_inventory_value(p_company)
       + coalesce((select w.balance_cents from public.wallets w
                   where w.owner_type='company' and w.owner_id = p_company), 0);
$$;

-- RPC: top N empresas ativas por equity.
create or replace function public.mv_ranking(p_limit int default 50)
returns table (
  rank          int,
  company_id    uuid,
  company_name  text,
  legal_form    text,
  owner_username text,
  avatar_url    text,
  cash_cents    bigint,
  inventory_cents bigint,
  equity_cents  bigint,
  founded_at    timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return query
  with scored as (
    select c.id,
           c.name,
           c.legal_form,
           p.username,
           p.avatar_url,
           coalesce(w.balance_cents, 0) as cash,
           public.mv_inventory_value(c.id) as inv,
           c.founded_at
    from public.companies c
    join public.profiles p on p.id = c.owner_id
    left join public.wallets w on w.owner_type = 'company' and w.owner_id = c.id
    where c.status = 'active'
      and not p.banned
  )
  select row_number() over (order by (cash + inv) desc, founded_at asc)::int as rank,
         id, name, legal_form, username, avatar_url,
         cash, inv, (cash + inv), founded_at
  from scored
  order by (cash + inv) desc, founded_at asc
  limit greatest(1, least(coalesce(p_limit, 50), 200));
end;
$$;

-- RPC: posição exata da minha empresa no ranking (MyRankCard).
create or replace function public.mv_my_rank()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  res jsonb;
begin
  with ranked as (
    select c.id,
           row_number() over (order by (coalesce(w.balance_cents,0) + public.mv_inventory_value(c.id)) desc) as rnk,
           count(*) over () as total,
           coalesce(w.balance_cents,0) as cash,
           public.mv_inventory_value(c.id) as inv
    from public.companies c
    left join public.wallets w on w.owner_type='company' and w.owner_id = c.id
    where c.status = 'active'
  )
  select jsonb_build_object(
    'company_id', id,
    'rank', rnk,
    'total', total,
    'cash_cents', cash,
    'inventory_cents', inv,
    'equity_cents', cash + inv
  ) into res
  from ranked
  where id = public.mv_company_of_user();

  if res is null then
    return jsonb_build_object('has_company', false);
  end if;

  return res || jsonb_build_object('has_company', true);
end;
$$;

grant execute on function public.mv_ranking(int) to anon, authenticated;
grant execute on function public.mv_my_rank() to authenticated;
