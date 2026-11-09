-- ============================================================================
-- MERCADO VIVO — 015: RLS (Row Level Security) em TODAS as tabelas (regra #5)
-- Políticas: leitura mínima necessária; escrita apenas via RPCs SECURITY
-- DEFINER ou dono do recurso. Admin usa mv_is_admin().
-- ============================================================================

alter table public.profiles        enable row level security;
alter table public.companies       enable row level security;
alter table public.wallets         enable row level security;
alter table public.categories      enable row level security;
alter table public.products        enable row level security;
alter table public.inventory       enable row level security;
alter table public.listings        enable row level security;
alter table public.ledger_entries  enable row level security;
alter table public.offers          enable row level security;
alter table public.notifications   enable row level security;
alter table public.admin_actions   enable row level security;
alter table public.game_config     enable row level security;

-- ---------------------------------------------------------------------------
-- profiles: leitura pública, edição apenas do próprio registo (nunca is_admin).
-- ---------------------------------------------------------------------------
create policy profiles_read on public.profiles
  for select using (true);

create policy profiles_update_self on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());
-- INSERT é feito pelo trigger handle_new_user (security definer). Sem policy de insert.

-- ---------------------------------------------------------------------------
-- companies: qualquer um vê empresas ativas; o dono vê/gere a sua.
-- ---------------------------------------------------------------------------
create policy companies_read on public.companies
  for select using (status <> 'bankrupt' or owner_id = auth.uid() or public.mv_is_admin());

create policy companies_insert_self on public.companies
  for insert with check (owner_id = auth.uid());

create policy companies_update_owner on public.companies
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- ---------------------------------------------------------------------------
-- wallets: só o dono (user ou empresa) e o admin leem. Escrita DIRETA proibida
-- ao utilizador comum — saldos movem-se exclusivamente via mv_post_double_entry.
-- ---------------------------------------------------------------------------
create policy wallets_read_own on public.wallets
  for select using (
    (owner_type = 'user'  and owner_id = auth.uid()) or
    (owner_type = 'company' and exists (
       select 1 from public.companies c
       where c.id = wallets.owner_id and c.owner_id = auth.uid())) or
    public.mv_is_admin()
  );

-- Sem policies de insert/update/delete para authenticated: o motor (definer)
-- é a única via. O trigger handle_new_user e create_career usam definer.

-- ---------------------------------------------------------------------------
-- categories / products: catálogo público em leitura; escrita só admin.
-- ---------------------------------------------------------------------------
create policy categories_read on public.categories for select using (active or public.mv_is_admin());
create policy categories_admin_write on public.categories
  for all using (public.mv_is_admin()) with check (public.mv_is_admin());

create policy products_read on public.products for select using (active or public.mv_is_admin());
create policy products_admin_write on public.products
  for all using (public.mv_is_admin()) with check (public.mv_is_admin());

-- ---------------------------------------------------------------------------
-- inventory: a empresa vê o seu stock; admin vê tudo. Escrita só via motor.
-- ---------------------------------------------------------------------------
create policy inventory_read_own on public.inventory
  for select using (
    exists (select 1 from public.companies c
            where c.id = inventory.company_id and c.owner_id = auth.uid())
    or public.mv_is_admin()
  );

-- ---------------------------------------------------------------------------
-- listings: anúncios abertos são públicos; os próprios donos veem tudo.
-- Insert/update apenas via RPCs (definer). Cancelamento direto permitido ao dono
-- APENAS para mudar status (a policy abaixo restringe colunas sensíveis? Não —
-- usamos RPC mv_cancel_listing; aqui só permitimos leitura).
-- ---------------------------------------------------------------------------
create policy listings_read on public.listings
  for select using (status = 'open' or company_id = public.mv_company_of_user() or public.mv_is_admin());

-- ---------------------------------------------------------------------------
-- ledger: imutável; cada utilizador lê apenas linhas das SUAS carteiras
-- (pessoal + empresa). Admin lê tudo para auditoria.
-- ---------------------------------------------------------------------------
create policy ledger_read_own on public.ledger_entries
  for select using (
    public.mv_is_admin()
    or wallet_id in (
      select w.id from public.wallets w
      where (w.owner_type = 'user' and w.owner_id = auth.uid())
         or (w.owner_type = 'company' and exists
              (select 1 from public.companies c
               where c.id = w.owner_id and c.owner_id = auth.uid()))
    )
  );
-- Sem write policies: escrita exclusivamente via SECURITY DEFINER (motor).

-- ---------------------------------------------------------------------------
-- offers: visíveis apenas às duas partes envolvidas (+admin).
-- ---------------------------------------------------------------------------
create policy offers_read_parties on public.offers
  for select using (
    from_company_id = public.mv_company_of_user()
    or to_company_id = public.mv_company_of_user()
    or public.mv_is_admin()
  );
-- Escrita via RPCs mv_make/accept/reject/cancel_offer.

-- ---------------------------------------------------------------------------
-- notifications: apenas o destinatário (e admin). Marcar lida é permitido.
-- ---------------------------------------------------------------------------
create policy notifications_read_own on public.notifications
  for select using (user_id = auth.uid());

create policy notifications_update_own on public.notifications
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- admin_actions / game_config: só admin (leitura); escrita via funções admin.
-- ---------------------------------------------------------------------------
create policy admin_actions_read on public.admin_actions
  for select using (public.mv_is_admin() or admin_id = auth.uid());

create policy game_config_read on public.game_config
  for select using (auth.role() = 'authenticated');

create policy game_config_admin_write on public.game_config
  for all using (public.mv_is_admin()) with check (public.mv_is_admin());

-- ---------------------------------------------------------------------------
-- Realtime: expor canais necessários.
-- ---------------------------------------------------------------------------
alter publication supabase_realtime add table public.notifications;
alter publication supabase_realtime add table public.listings;
alter publication supabase_realtime add table public.offers;
