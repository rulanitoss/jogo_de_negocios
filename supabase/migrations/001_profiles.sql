-- ============================================================================
-- MERCADO VIVO — 001: profiles
-- Perfil público de cada utilizador (espelho 1:1 de auth.users).
-- ============================================================================

create extension if not exists "pgcrypto";

create or replace function public.updated_at_trigger()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  username    text not null unique check (username ~ '^[a-z0-9_.-]{3,20}$'),
  display_name text not null default '',
  avatar_url  text,
  is_admin    boolean not null default false,
  banned      boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.profiles is
  'Perfil público dos jogadores. Um registo por auth.user.';

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.updated_at_trigger();

-- Cria automaticamente o profile quando um utilizador se registra.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  base_name text;
  candidate text;
  n int := 0;
begin
  base_name := lower(regexp_replace(
    coalesce(split_part(new.email, '@', 1), 'jogador'),
    '[^a-z0-9_.-]', '', 'g'
  ));
  if char_length(base_name) < 3 then
    base_name := 'jogador';
  end if;
  base_name := left(base_name, 16);

  candidate := base_name;
  while exists (select 1 from public.profiles where username = candidate) loop
    n := n + 1;
    candidate := base_name || '_' || n::text;
  end loop;

  insert into public.profiles (id, username, display_name)
  values (new.id, candidate, coalesce(new.raw_user_meta_data ->> 'display_name', candidate));

  -- Carteira pessoal do jogador (a empresa é criada no onboarding).
  insert into public.wallets (owner_type, owner_id, balance_cents)
  values ('user', new.id, 0);

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
