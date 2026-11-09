-- ============================================================================
-- MERCADO VIVO — Testes de invariantes (correr via psql / SQL editor)
-- Verificações que NUNCA devem falhar num estado sadio da base de dados.
-- Uso:  psql "$DB_URL" -f supabase/tests/invariants.sql
-- Cada bloco RAISE EXCEPTION se a invariante for violada.
-- ============================================================================

do $$
declare
  v_bad bigint;
begin

  -- --------------------------------------------------------------------------
  -- INV-1: Dupla entrada imutável — soma global do ledger = 0.
  -- --------------------------------------------------------------------------
  select coalesce(sum(case when direction = 'debit' then -amount_cents
                           else amount_cents end), 0)
    into v_bad
    from public.ledger_entries;
  if v_bad <> 0 then
    raise exception 'INV-1 FALHOU: ledger desequilibrado em % cêntimos.', v_bad;
  end if;
  raise notice 'INV-1 OK: ledger equilibrado (dupla entrada).';

  -- --------------------------------------------------------------------------
  -- INV-2: Dupla entrada por transação — cada tx_id soma zero.
  -- --------------------------------------------------------------------------
  select count(*) into v_bad
  from (
    select tx_id, sum(case when direction = 'debit' then -amount_cents
                           else amount_cents end) as s
      from public.ledger_entries
     group by tx_id
    having sum(case when direction = 'debit' then -amount_cents
                    else amount_cents end) <> 0
  ) x;
  if v_bad > 0 then
    raise exception 'INV-2 FALHOU: % transações desequilibradas.', v_bad;
  end if;
  raise notice 'INV-2 OK: todas as transações somam zero.';

  -- --------------------------------------------------------------------------
  -- INV-3: Nenhum saldo de carteira negativo.
  -- --------------------------------------------------------------------------
  select count(*) into v_bad from public.wallets where balance_cents < 0;
  if v_bad > 0 then
    raise exception 'INV-3 FALHOU: % carteiras com saldo negativo.', v_bad;
  end if;
  raise notice 'INV-3 OK: saldos >= 0.';

  -- --------------------------------------------------------------------------
  -- INV-4: Saldo da carteira == ledger acumulado (consistência real).
  -- --------------------------------------------------------------------------
  select count(*) into v_bad
  from public.wallets w
  join lateral (
    select coalesce(sum(case when le.direction = 'credit' then le.amount_cents
                             else -le.amount_cents end), 0) as computed
      from public.ledger_entries le
     where le.wallet_id = w.id
  ) l on true
  where w.balance_cents <> l.computed;
  if v_bad > 0 then
    raise exception 'INV-4 FALHOU: % carteiras divergem do ledger.', v_bad;
  end if;
  raise notice 'INV-4 OK: carteiras consistentes com o ledger.';

  -- --------------------------------------------------------------------------
  -- INV-5: Capital inicial de 200€ (20000 cêntimos) atribuído UMA vez.
  -- --------------------------------------------------------------------------
  select count(*) into v_bad
  from (
    select w.company_id
      from public.ledger_entries le
      join public.wallets w on w.id = le.wallet_id
     where le.description like '%capital inicial%'
       and le.direction = 'credit'
     group by w.company_id
    having count(*) > 1
  ) x;
  if v_bad > 0 then
    raise exception 'INV-5 FALHOU: % empresas com capital inicial duplicado.', v_bad;
  end if;
  raise notice 'INV-5 OK: capital inicial único por empresa.';

  -- --------------------------------------------------------------------------
  -- INV-6: Stock nunca negativo.
  -- --------------------------------------------------------------------------
  select count(*) into v_bad from public.inventory where quantity < 0;
  if v_bad > 0 then
    raise exception 'INV-6 FALHOU: % registos de stock negativos.', v_bad;
  end if;
  raise notice 'INV-6 OK: stock >= 0.';

  -- --------------------------------------------------------------------------
  -- INV-7: Listings nunca vendem mais do que têm.
  -- --------------------------------------------------------------------------
  select count(*) into v_bad
  from public.listings l
  join public.inventory i on i.company_id = l.company_id
                         and i.product_id = l.product_id
  where l.sold_quantity > l.quantity;
  if v_bad > 0 then
    raise exception 'INV-7 FALHOU: % listings over-sold.', v_bad;
  end if;
  raise notice 'INV-7 OK: sem over-selling em listings.';

  -- --------------------------------------------------------------------------
  -- INV-8: Todos os valores monetários são inteiros (BIGINT) — garantido
  -- pelo schema; aqui verificamos que não existe coluna numeric/float para
  -- dinheiro no public schema.
  -- --------------------------------------------------------------------------
  select count(*) into v_bad
  from information_schema.columns
  where table_schema = 'public'
    and data_type in ('numeric', 'double precision', 'real')
    and column_name like '%cents%';
  if v_bad > 0 then
    raise exception 'INV-8 FALHOU: % colunas de dinheiro não-inteiras.', v_bad;
  end if;
  raise notice 'INV-8 OK: dinheiro apenas em BIGINT (cêntimos).';

  -- --------------------------------------------------------------------------
  -- INV-9: Empresas falidas não podem ter listings abertos nem ofertas ativas.
  -- --------------------------------------------------------------------------
  select count(*) into v_bad
  from public.companies c
  where c.status = 'bankrupt'
    and (exists (select 1 from public.listings l
                 where l.company_id = c.id and l.status = 'open')
      or exists (select 1 from public.offers o
                 where (o.buyer_company_id = c.id or o.seller_company_id = c.id)
                   and o.status = 'pending'));
  if v_bad > 0 then
    raise exception 'INV-9 FALHOU: % empresas falidas com atividade aberta.', v_bad;
  end if;
  raise notice 'INV-9 OK: falidas sem atividade pendente.';

end;
$$;

select 'ALL INVARIANTS PASSED' as result;
