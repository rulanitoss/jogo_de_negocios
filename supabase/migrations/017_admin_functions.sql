-- ============================================================================
-- MERCADO VIVO — 017: admin functions
-- RPCs administrativas SECURITY DEFINER (nunca expostas a não-admins).
-- mv_admin_grant_role, mv_admin_adjust_balance, mv_admin_broadcast,
-- mv_admin_reopen_company. O ajuste de saldo passa SEMPRE pelo ledger.
-- ============================================================================

create or replace function public.mv_require_admin()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.mv_is_admin() then
    raise exception 'Acesso reservado a administradores.' using errcode = 'MV_FORBIDDEN';
  end if;
end;
$$;

-- Promover/rebaixar admin (o primeiro admin é definido manualmente via SQL).
create or replace function public.mv_admin_grant_role(p_user uuid, p_is_admin boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.mv_require_admin();

  update public.profiles set is_admin = p_is_admin where id = p_user;

  insert into public.admin_actions (admin_id, action, target_type, target_id, details)
  values (auth.uid(), case when p_is_admin then 'grant_admin' else 'revoke_admin' end,
          'profile', p_user, '{}'::jsonb);
end;
$$;

-- Ajuste manual de saldo (apoio/emergência): dupla entrada House <-> carteira.
create or replace function public.mv_admin_adjust_balance(
  p_owner_type text,
  p_owner_id uuid,
  p_amount_cents bigint,   -- positivo: crédito da casa; negativo: débito para a casa
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_wallet public.wallets;
  v_house  public.wallets;
begin
  perform public.mv_require_admin();

  if p_amount_cents = 0 then
    raise exception 'Montante não pode ser zero.' using errcode = 'MV_INVALID_AMOUNT';
  end if;

  select * into v_wallet from public.wallets
  where owner_type = p_owner_type and owner_id = p_owner_id for update;
  if not found then
    raise exception 'Carteira não encontrada.' using errcode = 'MV_NOT_FOUND';
  end if;

  select * into v_house from public.wallets where owner_type = 'house' for update;

  if p_amount_cents > 0 then
    perform mv_post_double_entry('admin_adjustment', v_house.id, v_wallet.id, p_amount_cents,
                                 p_owner_type, p_owner_id, coalesce(p_reason, 'Ajuste administrativo'));
  else
    perform mv_post_double_entry('admin_adjustment', v_wallet.id, v_house.id, -p_amount_cents,
                                 p_owner_type, p_owner_id, coalesce(p_reason, 'Ajuste administrativo'));
  end if;

  insert into public.admin_actions (admin_id, action, target_type, target_id, details)
  values (auth.uid(), 'adjust_balance', p_owner_type, p_owner_id,
          jsonb_build_object('amount_cents', p_amount_cents, 'reason', p_reason));
end;
$$;

-- Banir/desbanir utilizador.
create or replace function public.mv_admin_set_ban(p_user uuid, p_banned boolean, p_note text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.mv_require_admin();

  update public.profiles set banned = p_banned where id = p_user;

  -- Suspender empresa ativa do utilizador se banido.
  if p_banned then
    update public.companies set status = 'suspended'
    where owner_id = p_user and status = 'active';
  end if;

  insert into public.admin_actions (admin_id, action, target_type, target_id, details)
  values (auth.uid(), case when p_banned then 'ban' else 'unban' end,
          'profile', p_user, jsonb_build_object('note', p_note));
end;
$$;

-- Mensagem em broadcast a todos os jogadores.
create or replace function public.mv_admin_broadcast(p_title text, p_body text)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  perform public.mv_require_admin();

  with ins as (
    insert into public.notifications (user_id, kind, title, body)
    select id, 'admin_message', p_title, p_body from public.profiles
    returning 1
  )
  select count(*) into n from ins;

  insert into public.admin_actions (admin_id, action, details)
  values (auth.uid(), 'broadcast', jsonb_build_object('title', p_title, 'recipients', n));

  return n;
end;
$$;

-- Reativar empresa falida (reset de carreira sem novo capital inicial).
create or replace function public.mv_admin_reopen_company(p_company uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.mv_require_admin();

  update public.companies set status = 'active', bankrupt_at = null
  where id = p_company and status = 'bankrupt';

  insert into public.admin_actions (admin_id, action, target_type, target_id, details)
  values (auth.uid(), 'reopen_company', 'company', p_company, '{}'::jsonb);
end;
$$;

-- Visão global para o painel admin.
create or replace function public.mv_admin_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  res jsonb;
begin
  perform public.mv_require_admin();

  select jsonb_build_object(
    'players',        (select count(*) from public.profiles),
    'companies',      (select count(*) from public.companies where status = 'active'),
    'bankrupt',       (select count(*) from public.companies where status = 'bankrupt'),
    'money_supply',   (select coalesce(sum(balance_cents),0) from public.wallets where owner_type in ('user','company')),
    'house_balance',  (select coalesce(sum(balance_cents),0) from public.wallets where owner_type in ('house','tax_authority','bank')),
    'ledger_rows',    (select count(*) from public.ledger_entries),
    'ledger_sum',     (select coalesce(sum(delta_cents),0) from public.ledger_entries)
  ) into res;

  return res;
end;
$$;

grant execute on function
  public.mv_admin_grant_role(uuid, boolean),
  public.mv_admin_adjust_balance(text, uuid, bigint, text),
  public.mv_admin_set_ban(uuid, boolean, text),
  public.mv_admin_broadcast(text, text),
  public.mv_admin_reopen_company(uuid),
  public.mv_admin_overview()
to authenticated;
