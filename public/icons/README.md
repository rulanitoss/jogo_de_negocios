# Ícones PWA — MERCADO VIVO

Colocar aqui dois ficheiros PNG antes do deploy:

- `icon-192.png` — 192×192 px
- `icon-512.png` — 512×512 px (recomendado também gerar `maskable-icon-512.png`)

Requisitos:
- Fundo sólido (sem transparência) para a variante *maskable*.
- Cores da marca: primário `#1a5ff5` (brand-600), fundo escuro `#0d1117`.
- Formato: PNG, otimizado (< 100 KB cada).

Geradores sugeridos: https://realfavicongenerator.net ou `pwa-asset-generator`.

Estes ficheiros NÃO estão no repositório (são binários); adicionar manualmente
antes de correr `npm run build` e do deploy para que o Lighthouse PWA passe.
