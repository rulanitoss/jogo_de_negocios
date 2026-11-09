-- ============================================================================
-- MERCADO VIVO — 004: categories
-- Categorias de produtos (taxonomia do mercado). Geridas pelo admin.
-- ============================================================================

create table public.categories (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique check (slug ~ '^[a-z0-9_-]{2,40}$'),
  name        text not null,
  icon        text not null default '📦',
  parent_id   uuid references public.categories (id) on delete set null,
  sort_order  int not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create index categories_parent_idx on public.categories (parent_id);

comment on table public.categories is
  'Taxonomia de categorias do mercado. Leitura pública, escrita apenas admin (RLS em 018).';
