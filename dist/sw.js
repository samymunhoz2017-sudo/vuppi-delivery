// Nunca armazena respostas de autenticação, pedidos, localização ou mapas.
const CACHE='vuppi-offline-v72';
self.addEventListener('install',e=>{self.skipWaiting();e.waitUntil(caches.open(CACHE).then(c=>c.add('/offline.html')))});
self.addEventListener('activate',e=>{e.waitUntil(Promise.all([self.clients.claim(),caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('vuppi-offline-')&&k!==CACHE).map(k=>caches.delete(k))))]))});
self.addEventListener('fetch',e=>{if(e.request.mode==='navigate'&&new URL(e.request.url).origin===self.location.origin)e.respondWith(fetch(e.request).catch(()=>caches.match('/offline.html')))});

self.addEventListener('message',e=>{if(e.data?.type==='VUPPI_SKIP_WAITING')return self.skipWaiting();if(e.data?.type==='VUPPI_OFFER')e.waitUntil(self.registration.showNotification('Nova entrega VUPPI',{body:e.data.body||'Uma nova entrega está disponível. Abra para aceitar.',icon:'/pwa-icon.svg',badge:'/pwa-icon.svg',tag:'vuppi-new-delivery',renotify:true,requireInteraction:true,data:{url:'/entregador'}}))});
self.addEventListener('notificationclick',e=>{e.notification.close();e.waitUntil(clients.matchAll({type:'window',includeUncontrolled:true}).then(list=>{const open=list.find(c=>new URL(c.url).pathname==='/entregador');return open?open.focus():clients.openWindow('/entregador')}))});





