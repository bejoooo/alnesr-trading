// Retire the legacy localStorage app cache. The current app loads from the network.
self.addEventListener('install', event => {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names.filter(name => name.startsWith('alnesr-')).map(name => caches.delete(name)));
    await self.clients.claim();
  })());
});