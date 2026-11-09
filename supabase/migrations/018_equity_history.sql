-- ============================================================================
-- MERCADO VIVO — 018: equity history (snapshot diário do património)
-- Alimenta o EquityChart do Dashboard. O snapshot é gerado por trigger nas
-- movimentações relevantes + job diário; NUNCA calculado no cliente.
-- ============================================================================

create table public.equity_history (
  id            bigint generated always as identity primary key,
  company_id    uuid not null references public.companies (id) on delete cascade,
  snapshot_date date not null,
  cash_cents    bigint not null,
  inventory_cents bigint not null,
  equity_cents  bigint not null,
  created_at    timestamptz not null default now(),
  unique (company_id, snapshot_date)
);

create index equity_history_company_idx on public.equity_history (company_id, snapshot_date);

alter table public.equity_history enable row level security;

create policy equity_read_own on public.equity_history
  for select using (
    exists (select 1 from public.companies c
            where c.id = equity_history.company_id and c.owner_id = auth.uid())
    or public.mv_is_admin()
  );

-- Upsert do dia corrente para uma empresa (chamado pelo motor após operações).
create or replace function public.mv_snapshot_equity(p_company uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cash bigint;
  v_inv  bigint;
begin
  select coalesce(w.balance_cents, 0) into v_cash
  from public.wallets w
  where w.owner_type = 'company' and w.owner_id = p_company;

  v_inv := public.mv_inventory_value(p_company);

  insert into public.equity_history (company_id, snapshot_date, cash_cents, inventory_cents, equity_cents)
  values (p_company, current_date, v_cash, v_inv, v_cash + v_inv)
  on conflict (company_id, snapshot_date) do update
    set cash_cents = excluded.cash_cents,
        inventory_cents = excluded.inventory_cents,
        equity_cents = excluded.equity_cents;
end;
$$;

-- Trigger: após qualquer movimento de ledger duma carteira de empresa,
-- atualizar o snapshot do dia (dados reais, em tempo real).
create or replace function public.mv_ledger_triggers_snapshot()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid;
begin
  select owner_id into v_owner from public.wallets
  where id = new.wallet_id and owner_type = 'company';

  if found then
    perform public.mv_snapshot_equity(v_owner);
  end if;
  return new;
end;
$$;

create trigger ledger_snapshot_equity
  after insert on public.ledger_entries
  for each row execute function public.mv_ledger_triggers_snapshot();

-- Snapshot global (para ranking/índice): percorre empresas ativas.
create or replace function public.mv_snapshot_all_equity()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  n int := 0;
begin
  for r in select id from public.companies where status in ('active','suspended') loop
    perform public.mv_snapshot_equity(r.id);
    n := n + 1;
  end loop;
  return n;
end;
$$;

grant execute on function public.mv_snapshot_all_equity() to service_role;
