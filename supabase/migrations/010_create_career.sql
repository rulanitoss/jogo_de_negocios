-- ============================================================================
-- MERCADO VIVO — 010: admin + create_career
-- Tabela de audit administrative actions e a RPC transacional de criação
-- de carreira (empresa + carteira + capital inicial de 200€ UMA única vez).
-- ============================================================================

create table public.admin_actions (
  id          uuid primary key default gen_random_uuid(),
  admin_id    uuid not null references public.profiles (id) on delete restrict,
  action      text not null,
  target_type text,
  target_id   uuid,
  details     jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

create index admin_actions_admin_idx on public.admin_actions (admin_id, created_at);

comment on table public.admin_actions is
  'Trilha de auditoria de ações administrativas. Escrita apenas via SECURITY DEFINER.';

-- Configuração do jogo (chave/valor), em cêntimos quando monetário.
create table public.game_config (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

insert into public.game_config (key, value) values
  ('initial_capital_cents', '20000'),          -- 200,00 € em cêntimos (regra #4)
  ('bankruptcy_threshold_cents', '0'),         -- saldo <= 0 sem ativos => falência
  ('listing_fee_bps', '50')                    -- taxa house 0,5% sobre vendas no mercado
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- mv_is_admin(): helper estável usado pelas policies RLS.
-- ---------------------------------------------------------------------------
create or replace function public.mv_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select p.is_admin from public.profiles p where p.id = auth.uid()),
    false
  );
$$;

-- ---------------------------------------------------------------------------
-- RPC: criar carreira (empresa + carteira + capital inicial 200€).
-- SECURITY DEFINER, transacional, idempotente por utilizador: o capital é
-- atribuído EXATAMENTE UMA VEZ por utilizador (regra absoluta #4).
-- ---------------------------------------------------------------------------
create or replace function public.create_career(p_name text, p_legal_form text default 'Lda')
returns public.companies
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_company  public.companies;
  v_wallet   public.wallets;
  v_house    public.wallets;
  v_capital  bigint;
begin
  if v_uid is null then
    raise exception 'Não autenticado.' using errcode = 'MV_NOT_AUTHENTICATED';
  end if;

  if exists (select 1 from public.companies where owner_id = v_uid) then
    raise exception 'Já tens uma empresa. Só é permitida uma carreira por utilizador.'
      using errcode = 'MV_CAREER_EXISTS';
  end if;

  if p_name is null or char_length(trim(p_name)) < 3 then
    raise exception 'Nome da empresa demasiado curto (mínimo 3 caracteres).'
      using errcode = 'MV_INVALID_NAME';
  end if;

  select (value #>> '{}')::bigint into v_capital
  from public.game_config where key = 'initial_capital_cents';

  -- 1) Empresa
  insert into public.companies (owner_id, name, legal_form)
  values (v_uid, trim(p_name), p_legal_form)
  returning * into v_company;

  -- 2) Carteira da empresa
  insert into public.wallets (owner_type, owner_id, balance_cents)
  values ('company', v_company.id, 0)
  returning * into v_wallet;

  -- 3) Capital inicial: dupla entrada House -> Empresa (uma única vez).
  select * into v_house
  from public.wallets
  where owner_type = 'house'
  for update;

  perform mv_post_double_entry(
    p_reason   := 'initial_capital',
    p_debit    := v_house.id,
    p_credit   := v_wallet.id,
    p_amount   := v_capital,
    p_ref_type := 'company',
    p_ref_id   := v_company.id,
    p_memo     := 'Capital inicial da carreira'
  );

  perform mv_notify(v_uid, 'system', 'Bem-vindo ao Mercado Vivo!',
                    'A tua empresa ' || v_company.name || ' foi criada com um capital virtual de 200€.');

  return v_company;
end;
$$;

grant execute on function public.create_career(text, text) to authenticated;

comment on function public.create_career is
  'Cria empresa + carteira e credita 200€ virtuais UMA única vez por utilizador.';
