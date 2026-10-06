/* NueaLwoan service worker: รับแจ้งเตือนแม้ล็อกจอ */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { title: 'NueaLwoan', body: e.data ? e.data.text() : '' }; }
  const url = d.url || self.registration.scope;
  e.waitUntil(self.registration.showNotification(d.title || 'NueaLwoan', {
    body: d.body || '', tag: d.tag || undefined, renotify: !!(d.tag && d.renotify),
    requireInteraction: !!d.sticky, icon: 'images/icon-192.png', badge: 'images/icon-192.png',
    vibrate: [300, 120, 300, 120, 300], data: { url }
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || self.registration.scope;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(cs => {
    const base = url.split('?')[0];
    for (const c of cs) { if (c.url.split('?')[0] === base && 'focus' in c) return c.focus(); }
    return self.clients.openWindow(url);
  }));
});
