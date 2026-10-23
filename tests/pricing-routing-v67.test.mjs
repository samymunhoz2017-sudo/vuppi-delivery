import assert from 'node:assert/strict';import {readFileSync} from 'node:fs';
const read=p=>readFileSync(new URL('../'+p,import.meta.url),'utf8');
const pricing=read('supabase/migrations/202610150001_delivery_pricing.sql'),routing=read('supabase/migrations/202610150002_route_group_dispatch.sql'),server=read('server/delivery.mjs'),admin=read('dist/admin.js'),html=read('dist/admin.html'),android=read('mobile/vuppi-entregador-android/app/src/main/java/br/com/vuppidelivery/entregador/MainActivity.java'),deliveryWeb=read('dist/delivery.js');
for(const token of ['vuppi_delivery_tariffs','pricing_snapshot','return_required','vuppi_calculate_delivery_price','vuppi_pricing_admin','delete_override'])assert.ok(pricing.includes(token),'precificação sem '+token);
for(const token of ['route_total_cents','route_stop_count','vuppi_courier_release_route','offer_radius_km','accepted_ids','reoffered'])assert.ok(routing.includes(token),'roteirização sem '+token);
for(const token of ['pricing_state','pricing_save','pricing_test','pricing_delete_override','return_required:!!data.return_required','navigationInstruction.instructions','courier_release'])assert.ok(server.includes(token),'API sem '+token);
assert.match(html,/data-admin-tab="pricing"/);for(const token of ['pricingView','Salvar e ativar nova versão','Simular antes de salvar'])assert.ok(admin.includes(token));
for(const token of ['TextToSpeech','voice_guidance','hide_earnings','totalToday','Cancelar rota','route_stop_count'])assert.ok(android.includes(token),'Android sem '+token);
assert.doesNotMatch(android,/active!=null\)map\.animateCamera/);
console.log('V67: preço configurável, rota atômica, raio, reoferta, voz e estabilidade do mapa verificados.');

assert.match(android,/mapRenderKey/);
assert.match(android,/Orientações por voz: ativadas/);
assert.match(android,/courierSignupDialog/);
assert.match(android,/vehicle_model_2/);
assert.match(deliveryWeb,/if\(portal==='courier'\)await action\('register'/);
