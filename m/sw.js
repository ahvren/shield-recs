// Service worker for /m/ — app shell cache-first, data network-first with cache fallback,
// article images cached opportunistically (capped).
const VER = 'm-v5';
const SHELL = 'shell-' + VER, DATA = 'data-' + VER, IMG = 'img-' + VER;
const SHELL_FILES = ['./', './index.html', './manifest.webmanifest',
  './icons/icon-192.png', './icons/icon-512.png', './icons/maskable-512.png',
  './icons/apple-touch-icon.png', './icons/favicon-32.png'];
const IMG_MAX = 120;

self.addEventListener('install', e => {
  e.waitUntil(caches.open(SHELL).then(c => c.addAll(SHELL_FILES)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(
    ks.filter(k => !k.endsWith(VER)).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

async function networkFirst(req) {
  const cache = await caches.open(DATA);
  const key = new URL(req.url); key.search = '';           // ignore ?t= cache-busters
  try {
    const res = await fetch(req, {cache: 'no-store'});
    if (res.ok) { await cache.put(key.href, res.clone()); }
    return res;
  } catch (err) {
    const hit = await cache.match(key.href);
    if (hit) {
      const h = new Headers(hit.headers); h.set('X-From-Cache', '1');
      return new Response(await hit.blob(), {status: 200, headers: h});
    }
    throw err;
  }
}
// Page navigations: network first (3 s timeout) so updates show immediately; cache when offline.
async function pageNetworkFirst(req) {
  const cache = await caches.open(SHELL);
  try {
    const res = await Promise.race([fetch(req, {cache: 'no-store'}), new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), 3000))]);
    if (res.ok) cache.put('./index.html', res.clone());
    return res;
  } catch (err) {
    return (await cache.match('./index.html')) || (await caches.match(req, {ignoreSearch: true})) || Response.error();
  }
}
async function shellFirst(req) {
  const hit = await caches.match(req, {ignoreSearch: true});
  const net = fetch(req).then(async res => {
    if (res.ok) (await caches.open(SHELL)).put(req, res.clone());
    return res;
  }).catch(() => null);
  return hit || (await net) || caches.match('./index.html');
}
async function imageCache(req) {
  const cache = await caches.open(IMG);
  const hit = await cache.match(req);
  if (hit) return hit;
  try {
    const res = await fetch(req);
    if (res.ok || res.type === 'opaque') {
      await cache.put(req, res.clone());
      const keys = await cache.keys();
      for (let i = 0; i < keys.length - IMG_MAX; i++) await cache.delete(keys[i]);
    }
    return res;
  } catch (err) { return hit || Response.error(); }
}

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin === location.origin && /\/(news|recs)\.json$/.test(url.pathname)) {
    e.respondWith(networkFirst(req)); return;
  }
  if (req.destination === 'image') { e.respondWith(imageCache(req)); return; }
  if (req.mode === 'navigate' && url.origin === location.origin) { e.respondWith(pageNetworkFirst(req)); return; }
  if (url.origin === location.origin && url.pathname.startsWith(new URL('./', self.registration.scope).pathname)) {
    e.respondWith(shellFirst(req)); return;
  }
});
