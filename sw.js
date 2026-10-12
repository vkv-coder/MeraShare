const CACHE_NAME = 'merashare-v2';
const SHELL_FILES = [
  '/index.html',
  '/login.html',
  '/dashboard.html',
  '/css/style.css',
  '/js/supabase-client.js',
  '/manifest.json'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_FILES))
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  const url = new URL(event.request.url);
  if (url.origin !== location.origin) return;

  // Page navigations: service workers force these into 'manual' redirect mode,
  // so re-fetching event.request directly would turn the server's 307
  // clean-URL redirect (e.g. /dashboard.html -> /dashboard) into an opaque,
  // unusable response and fail the whole navigation (Chrome: net::ERR_FAILED).
  // Re-issue as a fresh request with redirect:'follow' instead.
  if (event.request.mode === 'navigate') {
    event.respondWith(
      fetch(url.pathname + url.search, { redirect: 'follow' })
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
