-- ============================================================================
-- MERCADO VIVO — 022: market index, price history, my rank, reports
-- Índice de mercado (média geométrica simplificada dos preços efetivos),
-- série temporal de preços por produto (agregada por hora) e relatórios
-- de exportação para o utilizador/admin. Tudo derivado de dados reais da BD.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Tabela de histórico de preços (agregações horárias por produto).
-- ---------------------------------------------------------------------------
create table public.price_history (
  id             bigint generated always as identity primary key,
  product_id     uuid not null references public.products (id) on delete cascade,
  bucket         timestamptz not null,           -- hora de agregação (date_trunc('hour'))
  avg_price_cents bigint not null check (avg_price_cents >= 0),
  min_price_cents bigint not null check (min_price_cents >= 0),
  max_price_cents bigint not null check (max_price_cents >= 0),
  traded_units   bigint not null default 0 check (traded_units >= 0),
  unique (product_id, bucket)
);

create index price_history_product_bucket_idx
  on public.price_history (product_id, bucket desc);

alter table public.price_history enable row level security;

create policy price_history_read_all on public.price_history
  for select using (true);

comment on table public.price_history is
  'Série temporal horária de preços por produto. Alimentada por mv_record_price_history.';

-- ---------------------------------------------------------------------------
-- Snapshot do índice de mercado (valor global + por categoria).
-- ---------------------------------------------------------------------------
create table public.market_index (
  id          bigint generated always as identity primary key,
  bucket      timestamptz not null,
  scope       text not null default 'global' check (scope in ('global', 'category')),
  category_id uuid references public.categories (id) on delete cascade,
  index_value numeric(14,4) not null check (index_value >= 0),
  unique (bucket, scope, category_id)
);

create index market_index_bucket_idx on public.market_index (bucket desc);

alter table public.market_index enable row level security;

create policy market_index_read_all on public.market_index
  for select using (true);

-- ---------------------------------------------------------------------------
-- mv_record_price_history: agrega os últimos trades/listings por produto
-- na bucket da hora corrente e upserta em price_history. SECURITY DEFINER.
-- ---------------------------------------------------------------------------
create or replace function public.mv_record_price_history()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bucket timestamptz := date_trunc('hour', now());
  v_count  int := 0;
begin
  -- Preços correntes efetivos por produto (lado oferta real da lista aberta).
  insert into public.price_history
    (product_id, bucket, avg_price_cents, min_price_cents, max_price_cents, traded_units)
  select
    l.product_id,
    v_bucket,
    round(avg(l.unit_price_cents))::bigint,
    min(l.unit_price_cents),
    max(l.unit_price_cents),
    coalesce((
      select sum(o.quantity)
        from public.orders o
       where o.product_id = l.product_id
         and o.status = 'completed'
         and date_trunc('hour', o.updated_at) = v_bucket
    ), 0)
  from public.listings l
  where l.status = 'open' and l.expires_at > v_bucket
  group by l.product_id
  on conflict (product_id, bucket) do update
    set avg_price_cents = excluded.avg_price_cents,
        min_price_cents = least(public.price_history.min_price_cents, excluded.min_price_cents),
        max_price_cents = greatest(public.price_history.max_price_cents, excluded.max_price_cents),
        traded_units    = excluded.traded_units;
  get diagnostics v_count = row_count;

  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- mv_update_market_index: recalcula o índice global e por categoria com base
-- nos preços efetivos atuais normalizados pelo MSRP (base 100 = MSRP médio).
-- ---------------------------------------------------------------------------
create or replace function public.mv_update_market_index()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bucket timestamptz := date_trunc('minute', now());
begin
  insert into public.market_index (bucket, scope, category_id, index_value)
  select v_bucket, 'global', null,
         round(100.0 * avg(public.mv_effective_price(p.id)::numeric
                / nullif(p.msrp_cents, 0)), 4)
    from public.products p
   where p.active
  having count(*) > 0
  on conflict (bucket, scope, category_id) do nothing;

  insert into public.market_index (bucket, scope, category_id, index_value)
  select v_bucket, 'category', p.category_id,
         round(100.0 * avg(public.mv_effective_price(p.id)::numeric
                / nullif(p.msrp_cents, 0)), 4)
    from public.products p
   where p.active
   group by p.category_id
  on conflict (bucket, scope, category_id) do nothing;

  -- Regista também o histórico de preços desta execução.
  perform public.mv_record_price_history();
end;
$$;

-- ---------------------------------------------------------------------------
-- mv_price_history: série de preços de um produto (últimas `p_hours`).
-- ---------------------------------------------------------------------------
create or replace function public.mv_price_history(p_product uuid, p_hours int default 72)
returns table (bucket timestamptz, avg_price_cents bigint, min_price_cents bigint,
              max_price_cents bigint, traded_units bigint)
language sql
stable
security definer
set search_path = public
as $$
  select ph.bucket, ph.avg_price_cents, ph.min_price_cents,
         ph.max_price_cents, ph.traded_units
    from public.price_history ph
   where ph.product_id = p_product
     and ph.bucket >= now() - make_interval(hours => least(greatest(p_hours, 1), 8760))
   order by ph.bucket;
$$;

-- ---------------------------------------------------------------------------
-- mv_market_snapshot: estado atual do índice (para o dashboard do índice).
-- ---------------------------------------------------------------------------
create or replace function public.mv_market_snapshot()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  out jsonb;
begin
  select jsonb_build_object(
    'global', (
      select jsonb_build_object(
        'value', coalesce(mi.index_value, 100),
        'bucket', mi.bucket)
      from public.market_index mi
      where mi.scope = 'global'
      order by mi.bucket desc limit 1),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id, 'name', c.name, 'value', latest.index_value))
      from public.categories c
      join lateral (
        select mi.index_value from public.market_index mi
        where mi.category_id = c.id and mi.scope = 'category'
        order by mi.bucket desc limit 1) latest on true), '[]'::jsonb),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'sku', p.sku, 'name', p.name,
        'effective_price_cents', public.mv_effective_price(p.id),
        'msrp_cents', p.msrp_cents))
      from public.products p where p.active), '[]'::jsonb)
  ) into out;
  return out;
end;
$$;

-- ---------------------------------------------------------------------------
-- mv_my_rank: posição da empresa do utilizador no ranking (reutiliza 019).
-- ---------------------------------------------------------------------------
create or replace function public.mv_my_rank()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company uuid;
  out jsonb;
begin
  select id into v_company from public.companies
   where owner_id = auth.uid() and status = 'active';
  if v_company is null then
    return jsonb_build_object('found', false);
  end if;

  select jsonb_build_object(
    'found', true,
    'company_id', v_company,
    'equity_cents', public.mv_equity(v_company),
    'rank', rk.rank,
    'total', rk.total
  ) into out
  from (
    select rank() over (order by public.mv_equity(c.id) desc) as rank,
           count(*) over () as total
      from public.companies c
     where c.status = 'active'
  ) rk
  join public.companies c on c.id = v_company
  limit 1;

  return coalesce(out, jsonb_build_object('found', false));
end;
$$;

-- ---------------------------------------------------------------------------
-- mv_report_transactions: extrato do ledger da empresa do utilizador.
-- Movimentos reais, imutáveis, em cêntimos.
-- ---------------------------------------------------------------------------
create or replace function public.mv_report_transactions(p_from timestamptz default null,
                                                         p_to   timestamptz default null)
returns table (created_at timestamptz, description text, debit_cents bigint,
              credit_cents bigint, balance_after_cents bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company uuid;
begin
  select id into v_company from public.companies
   where owner_id = auth.uid() and status = 'active';
  if v_company is null then
    raise exception 'Empresa ativa não encontrada.' using errcode = 'MV_NO_COMPANY';
  end if;

  return query
    select le.created_at, le.description,
           case when le.direction = 'debit'  then le.amount_cents else 0 end,
           case when le.direction = 'credit' then le.amount_cents else 0 end,
           sum(case when le.direction = 'credit' then le.amount_cents
                    else -le.amount_cents end)
             over (order by le.created_at, le.id rows unbounded preceding)
      from public.ledger_entries le
      join public.wallets w on w.id = le.wallet_id
     where w.company_id = v_company
       and (p_from is null or le.created_at >= p_from)
       and (p_to   is null or le.created_at <= p_to)
     order by le.created_at, le.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- mv_report_summary: resumo económico da empresa (património, volume, margem).
-- ---------------------------------------------------------------------------
create or replace function public.mv_report_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company uuid;
  out jsonb;
begin
  select id into v_company from public.companies
   where owner_id = auth.uid() and status = 'active';
  if v_company is null then
    raise exception 'Empresa ativa não encontrada.' using errcode = 'MV_NO_COMPANY';
  end if;

  select jsonb_build_object(
    'company_id', v_company,
    'cash_cents', coalesce((select sum(w.balance_cents) from public.wallets w
                            where w.company_id = v_company and w.kind = 'operating'), 0),
    'inventory_value_cents', public.mv_inventory_value(v_company),
    'equity_cents', public.mv_equity(v_company),
    'units_purchased', coalesce((select sum(o.quantity) from public.orders o
                                 where o.buyer_company_id = v_company
                                   and o.status = 'completed'), 0),
    'units_sold', coalesce((select sum(o.quantity) from public.orders o
                             where o.seller_company_id = v_company
                               and o.status = 'completed'), 0),
    'revenue_cents', coalesce((select sum(o.total_cents) from public.orders o
                                where o.seller_company_id = v_company
                                  and o.status = 'completed'), 0),
    'cogs_cents', coalesce((select sum(o.quantity * p.wholesale_cents)
                              from public.orders o
                              join public.products p on p.id = o.product_id
                             where o.buyer_company_id = v_company
                               and o.status = 'completed'), 0)
  ) into out;
  return out;
end;
$$;

-- Admin pode ver relatórios de qualquer empresa.
grant execute on function public.mv_report_transactions(timestamptz, timestamptz) to authenticated;
grant execute on function public.mv_report_summary() to authenticated;
grant execute on function public.mv_price_history(uuid, int) to anon, authenticated;
grant execute on function public.mv_market_snapshot() to anon, authenticated;
grant execute on function public.mv_my_rank() to authenticated;
grant execute on function public.mv_record_price_history() to authenticated;
grant execute on function public.mv_update_market_index() to service_role;

comment on function public.mv_update_market_index is
  'Chamada via pg_cron (ou bankruptcy-sweep) a cada minuto/hora conforme ambiente.';
