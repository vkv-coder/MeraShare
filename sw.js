const CACHE_NAME = 'merashare-v4';
const SHELL_FILES = [
  '/index.html',
  '/login.html',
  '/dashboard.html',
  '/trips.html',
  '/activity.html',
  '/account.html',
  '/css/style.css',
  '/js/supabase-client.js',
  '/manifest.json'
];

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_FILES))
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    Promise.all([
      caches.keys().then((keys) =>
        Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
      ),
      self.clients.claim()
    ])
  );
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  const url = new URL(event.request.url);
  if (url.origin !== location.origin) return;

  // Page navigations always run in redirect mode 'manual' once a service
  // worker intercepts them, and Chrome refuses to respondWith() ANY response
  // whose .redirected flag is true in that case (net::ERR_FAILED) — true
  // regardless of which fetch() produced it, {redirect:'follow'} included.
  // So avoid the redirect ever happening: resolve Cloudflare's clean-URL
  // mapping (strip trailing .html; /index -> /) ourselves before fetching,
  // instead of requesting the original *.html path at all.
  if (event.request.mode === 'navigate') {
    let cleanPath = url.pathname.replace(/\.html$/, '');
    if (cleanPath === '/index' || cleanPath === '') cleanPath = '/';
    event.respondWith(
      fetch(cleanPath + url.search, { redirect: 'follow' })
        .catch(() => caches.match(event.request))
    );
    return;
  }

  event.respondWith(
    caches.match(event.request).then((cached) => {
      if (cached) return cached;
      return fetch(event.request).catch(() => cached);
    })
  );
});
