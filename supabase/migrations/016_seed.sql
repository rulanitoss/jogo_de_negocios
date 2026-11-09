-- ============================================================================
-- MERCADO VIVO — 016: seed
-- Categorias e produtos iniciais do mercado. Valores em cêntimos (BIGINT).
-- Este seed é DADOS REAIS de arranque do jogo (não simulação no cliente).
-- ============================================================================

insert into public.categories (slug, name, icon, sort_order) values
  ('alimentacao', 'Alimentação',        '🥖', 1),
  ('tecnologia',  'Tecnologia',         '💻', 2),
  ('vestuario',   'Vestuário',          '👕', 3),
  ('materiais',   'Materiais',          '🧱', 4),
  ('servicos',    'Serviços Digitais',  '🛠️', 5)
on conflict (slug) do nothing;

insert into public.products (sku, category_id, name, description, wholesale_cents, msrp_cents, demand_index) values
  ('AL-PAN01', (select id from public.categories where slug='alimentacao'), 'Pão Artesanal',      'Unidade de pão artesanal.',            80,    120,   70),
  ('AL-CAF01', (select id from public.categories where slug='alimentacao'), 'Café (kg)',           'Café torrado, pacote de 1 kg.',       900,   1400,  65),
  ('TE-FONE1', (select id from public.categories where slug='tecnologia'),  'Auscultadores',       'Auscultadores sem fios.',           1500,  2500,  60),
  ('TE-HUB01', (select id from public.categories where slug='tecnologia'),  'Hub USB-C',           'Hub USB-C 7 portas.',                900,  1500,  45),
  ('VE-CAMI1', (select id from public.categories where slug='vestuario'),   'Camiseta Básica',     'Camiseta de algodão.',               300,   600,  75),
  ('VE-TENI1', (select id from public.categories where slug='vestuario'),   'Ténis Urbanos',       'Ténis casuais.',                   2200,  3500,  50),
  ('MA-TIJ01', (select id from public.categories where slug='materiais'),   'Lote Tijolo (100)',   'Lote de 100 tijolos.',              1800,  2600,  40),
  ('MA-MAD01', (select id from public.categories where slug='materiais'),   'Madeira (m³)',        'Madeira tratada, 1 m³.',            2500,  3800,  35),
  ('SE-LIC01', (select id from public.categories where slug='servicos'),    'Licença Software',    'Licença anual de software.',        3000,  5000,  55),
  ('SE-SUP01', (select id from public.categories where slug='servicos'),    'Suporte Premium',     'Pacote mensal de suporte.',         4000,  6500,  30)
on conflict (sku) do nothing;

comment on table public.products is 'Seed inicial do catálogo; o admin pode expandir via painel.';
