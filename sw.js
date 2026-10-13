/* Service worker de kepasa: deja instalar el panel como app y abrirlo aunque se cortó el internet.
   Estrategia "red primero": siempre intenta traer lo último; si no hay conexión, usa la copia guardada.
   Nunca guarda llamadas a Supabase (pedidos, cuentas, etc.): esas siempre van a la red. */
const CACHE = 'kepasa-shell-v4';
const SHELL = ['./', 'index.html', 'carta.html', 'config.js', 'manifest.webmanifest', 'icons/icon-192.png?v=2', 'icons/icon-512.png?v=2', 'icons/logo-mark.svg?v=2'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => Promise.allSettled(SHELL.map(u => c.add(u)))).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== 'GET' || u.origin !== location.origin) return;       // todo lo externo (Supabase, CDN) pasa directo
  e.respondWith(
    fetch(r).then(res => {
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(r, copy)); }
      return res;
    }).catch(() => caches.match(r, { ignoreSearch: true }).then(hit => hit || (r.mode === 'navigate' ? caches.match('index.html') : Response.error())))
  );
});
