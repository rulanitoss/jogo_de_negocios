-- ============================================================================
-- MERCADO VIVO — 020: bankruptcy sweep (agendamento)
-- Agendador do sweep de falência/expirações. Usa pg_cron quando disponível;
-- caso contrário, a Edge Function bankruptcy-sweep (invocada pelo Supabase
-- Scheduler) chama mv_bankruptcy_sweep() com service_role.
-- Esta migração documenta e prepara ambos os caminhos.
-- ============================================================================

-- Caminho A (preferido em projetos com add-on): pg_cron a cada 15 minutos.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'mv-bankruptcy-sweep',
      '*/15 * * * *',
      $q$ select public.mv_bankruptcy_sweep(); $q$
    );
  end if;
end;
$$;

-- Caminho B: view leve para monitorizar candidatos a falência (admin).
create or replace view public.mv_bankruptcy_candidates as
select c.id as company_id,
       c.name,
       c.owner_id,
       coalesce(w.balance_cents, 0) as cash_cents,
       public.mv_inventory_value(c.id) as inventory_cents
from public.companies c
left join public.wallets w on w.owner_type = 'company' and w.owner_id = c.id
where c.status = 'active'
  and coalesce(w.balance_cents, 0) < 1000;

alter view public.mv_bankruptcy_candidates owner to postgres;

grant select on public.mv_bankruptcy_candidates to authenticated;

comment on view public.mv_bankruptcy_candidates is
  'Empresas ativas com caixa baixa — visíveis no painel admin (dados reais).';
