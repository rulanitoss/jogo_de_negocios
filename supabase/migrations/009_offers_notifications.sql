-- ============================================================================
-- MERCADO VIVO — 009: offers + notifications
-- Ofertas diretas empresa->empresa (negociação) e notificações em tempo real.
-- ============================================================================

create table public.offers (
  id              uuid primary key default gen_random_uuid(),
  from_company_id uuid not null references public.companies (id) on delete cascade,
  to_company_id   uuid not null references public.companies (id) on delete cascade,
  product_id      uuid not null references public.products (id) on delete restrict,
  quantity        bigint not null check (quantity > 0),
  unit_price_cents bigint not null check (unit_price_cents > 0),
  total_cents     bigint generated always as (quantity * unit_price_cents) stored,
  message         text not null default '',
  status          text not null default 'pending'
                  check (status in ('pending', 'accepted', 'rejected', 'cancelled', 'expired', 'escrowed')),
  created_at      timestamptz not null default now(),
  expires_at      timestamptz not null default (now() + interval '48 hours'),
  responded_at    timestamptz,
  check (from_company_id <> to_company_id)
);

comment on table public.offers is
  'Negociação direta entre empresas. Aceitação corre mv_accept_offer (motor 013).';

create index offers_to_pending_idx on public.offers (to_company_id, status)
  where status = 'pending';
create index offers_from_idx on public.offers (from_company_id);

-- ---------------------------------------------------------------------------

create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  kind        text not null check (kind in (
                'offer_new', 'offer_accepted', 'offer_rejected', 'offer_cancelled',
                'sale_completed', 'purchase_completed', 'listing_expired',
                'bankruptcy_warning', 'bankruptcy_declared', 'admin_message', 'system'
              )),
  title       text not null,
  body        text not null default '',
  ref_type    text,
  ref_id      uuid,
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);

create index notifications_user_idx on public.notifications (user_id, read_at, created_at);

comment on table public.notifications is
  'Notificações por utilizador. Realtime publication: supabase_realtime (migração 018).';
