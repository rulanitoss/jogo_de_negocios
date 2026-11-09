-- ============================================================================
-- MERCADO VIVO — 008: ledger (razão de dupla entrada, IMUTÁVEL)
-- Regra absoluta #3: cada linha é um débito OU crédito; cada transação fecha
-- a zero (soma dos deltas = 0). AFTER INSERT/UPDATE/DELETE proibidos por trigger.
-- ============================================================================

create table public.ledger_entries (
  id             bigint generated always as identity primary key,
  txn_id         uuid not null default gen_random_uuid(),
  created_at     timestamptz not null default now(),
  -- Motivo contabilístico normalizado
  reason         text not null check (reason in (
                   'initial_capital', 'house_purchase', 'market_sale', 'market_purchase',
                   'offer_escrow', 'offer_release', 'offer_refund', 'order_payment',
                   'order_payout', 'order_refund', 'bankruptcy_writeoff', 'admin_adjustment',
                   'tax'
                 )),
  wallet_id      uuid not null references public.wallets (id) on delete restrict,
  -- Delta em cêntimos: positivo = crédito à carteira, negativo = débito.
  delta_cents    bigint not null check (delta_cents <> 0),
  -- Referência cruzada opcional para o documento origem.
  ref_type       text,
  ref_id         uuid,
  memo           text not null default ''
);

comment on table public.ledger_entries is
  'Razão imutável de dupla entrada. Cada txn_id soma exatamente 0.';

create index ledger_wallet_idx on public.ledger_entries (wallet_id, created_at);
create index ledger_txn_idx on public.ledger_entries (txn_id);
create index ledger_ref_idx on public.ledger_entries (ref_type, ref_id);

-- ---------------------------------------------------------------------------
-- Imutabilidade: bloquear UPDATE e DELETE.
-- ---------------------------------------------------------------------------
create or replace function public.block_ledger_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'O ledger é imutável (dupla entrada). Operações de escrita direta não são permitidas.'
    using errcode = 'MV_LEDGER_IMMUTABLE';
end;
$$;

create trigger ledger_no_update
  before update on public.ledger_entries
  for each row execute function public.block_ledger_mutation();

create trigger ledger_no_delete
  before delete on public.ledger_entries
  for each row execute function public.block_ledger_mutation();

-- ---------------------------------------------------------------------------
-- Dupla entrada: ao inserir um conjunto de linhas com o mesmo txn_id,
-- a soma dos deltas deve ser 0 (verificado no fim da statement).
-- ---------------------------------------------------------------------------
create or replace function public.assert_ledger_balance()
returns trigger
language plpgsql
as $$
declare
  bad_txn uuid;
begin
  select txn_id into bad_txn
  from (
    select txn_id, sum(delta_cents) as s
    from public.ledger_entries
    where txn_id in (select distinct txn_id from new_rows)
    group by txn_id
    having sum(delta_cents) <> 0
  ) q
  limit 1;

  if found then
    raise exception 'Transação % desequilibrada na dupla entrada.', bad_txn
      using errcode = 'MV_LEDGER_UNBALANCED';
  end if;
  return null;
end;
$$;

-- Suporte: tabela temporária populada por um trigger BEFORE para capturar os txn_ids do statement.
create or replace function public.capture_ledger_txns()
returns trigger
language plpgsql
as $$
begin
  create temp table if not exists new_rows (txn_id uuid) on commit drop;
  insert into new_rows values (new.txn_id);
  return new;
end;
$$;

create trigger ledger_capture_txns
  after insert on public.ledger_entries
  for each row execute function public.capture_ledger_txns();

create trigger ledger_assert_balance
  after statement on public.ledger_entries
  for each statement execute function public.assert_ledger_balance();

-- ---------------------------------------------------------------------------
-- Consistência carteira <-> ledger: o saldo de cada carteira deve igualar
-- a soma dos deltas do ledger. Executado como constraint trigger diferido
-- pelas funções do motor (mv_post_double_entry actualiza wallets + ledger).
-- ---------------------------------------------------------------------------
create or replace function public.mv_assert_wallet_consistency(p_wallet uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  live bigint;
  derived bigint;
begin
  select balance_cents into live from public.wallets where id = p_wallet;
  select coalesce(sum(delta_cents), 0) into derived
  from public.ledger_entries where wallet_id = p_wallet;

  if live is distinct from derived then
    raise exception 'Carteira % inconsistente: saldo %, ledger %.', p_wallet, live, derived
      using errcode = 'MV_WALLET_INCONSISTENT';
  end if;
end;
$$;
