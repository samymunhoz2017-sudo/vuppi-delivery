import assert from 'node:assert/strict';
import {existsSync,readFileSync} from 'node:fs';

const read=path=>readFileSync(new URL('../'+path,import.meta.url),'utf8');
const android=read('mobile/vuppi-entregador-android/app/src/main/java/br/com/vuppidelivery/entregador/MainActivity.java');
const web=read('dist/delivery.js'),service=read('server/delivery.mjs'),build=read('scripts/build.mjs');
const migration=read('supabase/migrations/202610260001_active_route_tracking.sql');

assert.match(android,/JSONObject\.NULL\.equals\(rawGroup\)/,'grupo nulo não pode reunir o histórico');
assert.match(android,/currentStatus="assigned"\.equals\(rowStatus\)\|\|"collected"\.equals\(rowStatus\)/,'manifesto deve conter somente a rota ativa');
assert.match(android,/vuppi_courier_helmet_marker/,'mapa Android deve usar o mascote com capacete');
assert.match(android,/publishForegroundLocation\(current\)/,'app em primeiro plano deve publicar a posição');
assert.match(web,/vuppi-courier-helmet-marker\.png/,'painel web deve usar o mesmo marcador Vuppi');
assert.match(build,/icons\/vuppi-courier-helmet-marker\.png/,'build de produção deve publicar o marcador Vuppi');
assert.match(web,/merchantMapLiveTimer=setTimeout\(renderMerchantMap,3000\)/,'painel do estabelecimento deve atualizar a posição em tempo quase real');
assert.match(web,/\['assigned','collected'\]\.includes\(order\.status\)/,'mapa do estabelecimento deve limitar-se a entregas ativas');
for(const field of ['route_group_id','route_sequence','courier_id','courier_updated_at'])assert.ok(migration.includes("'"+field+"'"),'tracking sem '+field);
assert.match(service,/!\['delivered','cancelled'\]\.includes\(order\.status\)/);
const marker=new URL('../dist/icons/vuppi-courier-helmet-marker.png',import.meta.url),androidMarker=new URL('../mobile/vuppi-entregador-android/app/src/main/res/drawable/vuppi_courier_helmet_marker.png',import.meta.url);
assert.ok(existsSync(marker)&&existsSync(androidMarker),'marcadores do mascote precisam existir nos dois clientes');
assert.deepEqual([...readFileSync(marker).subarray(0,8)],[137,80,78,71,13,10,26,10]);
console.log('active-route-live-map-v82.test.mjs passed');
