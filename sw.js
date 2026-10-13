const CACHE_NAME = 'merashare-v6';
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

  // Network-first for everything else (JS/CSS/manifest): a stale cached
  // asset here (e.g. supabase-client.js missing a function a newer HTML
  // page already calls) silently breaks pages with no visible error --
  // they just hang on their initial "Loading..." state forever. Always
  // prefer the live network copy when online; cache is purely an
  // offline fallback now, not a way to skip re-fetching after a deploy.
  event.respondWith(
    fetch(event.request)
      .then((res) => {
        const resClone = res.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, resClone));
        return res;
      })
      .catch(() => caches.match(event.request))
  );
});
