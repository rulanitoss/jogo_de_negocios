/* eslint-disable no-restricted-globals */
// Service Worker do MERCADO VIVO (PWA)
// Estratégia:
//  - Shell da app: cache-first (assets estáticos versionados)
//  - Chamadas à API Supabase: network-first SEMPRE (nunca servir dados económicos
//    envelhecidos de cache — regra absoluta: o estado vem da base de dados real).

const VERSION = "mv-v0.1.0";
const SHELL_CACHE = `mv-shell-${VERSION}`;

const SHELL_ASSETS = [
  "/",
  "/index.html",
  "/manifest.webmanifest",
  "/icons/icon-192.png",
  "/icons/icon-512.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(SHELL_CACHE)
      .then((cache) => cache.addAll(SHELL_ASSETS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(keys.filter((k) => k !== SHELL_CACHE).map((k) => caches.delete(k)))
      )
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);

  // Nunca interceptar POST/PUT/DELETE nem pedidos à API/Auth/Realtime do Supabase.
  if (
    event.request.method !== "GET" ||
    url.hostname.endsWith(".supabase.co") ||
    url.hostname.endsWith("supabase.io")
  ) {
    return;
  }

  // Assets com hash (Vite): cache-first.
  if (url.pathname.startsWith("/assets/")) {
    event.respondWith(
      caches.match(event.request).then(
        (hit) =>
          hit ??
          fetch(event.request).then((res) => {
            const copy = res.clone();
            caches.open(SHELL_CACHE).then((c) => c.put(event.request, copy));
            return res;
          })
      )
    );
    return;
  }

  // Navegação: network-first, fallback para a shell em cache (offline básico).
  if (event.request.mode === "navigate") {
    event.respondWith(
      fetch(event.request).catch(() => caches.match("/index.html"))
    );
    return;
  }

  // Resto: pass-through.
});
