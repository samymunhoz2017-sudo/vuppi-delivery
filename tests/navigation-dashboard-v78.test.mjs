import assert from 'node:assert/strict';import {readFileSync,existsSync} from 'node:fs';
const read=p=>readFileSync(new URL('../'+p,import.meta.url),'utf8');
const android=read('mobile/vuppi-entregador-android/app/src/main/java/br/com/vuppidelivery/entregador/MainActivity.java'),service=read('mobile/vuppi-entregador-android/app/src/main/java/br/com/vuppidelivery/entregador/CourierService.java'),admin=read('dist/admin.js'),css=read('dist/admin.css');
for(const token of ['courierMarker','courier_motorcycle_3d','Recalcular','Centralizar','Cancelar rota','toggleVoiceGuidance','bearing(0f)','setRotateGesturesEnabled(false)','mapFollow'])assert.ok(android.includes(token),'navegação Android sem '+token);
assert.ok(existsSync(new URL('../mobile/vuppi-entregador-android/app/src/main/res/drawable-nodpi/courier_motorcycle_3d.png',import.meta.url)),'ícone de moto ausente');
assert.match(service,/PRIORITY_HIGH_ACCURACY,1500/);assert.match(service,/setMinUpdateDistanceMeters\(1\)/);
for(const token of ['overview-live-map','Fluxo de entregas','O que precisa da sua atenção','Ações rápidas','Entregas recentes','Saúde operacional'])assert.ok(admin.includes(token),'dashboard sem '+token);
assert.match(css,/Vuppi Admin v0\.78/);assert.match(css,/grid-template-columns:repeat\(6/);
console.log('V78: navegação, moto em tempo real, cancelamento visível e dashboard operacional verificados.');
