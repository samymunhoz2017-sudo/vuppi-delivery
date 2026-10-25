import assert from 'node:assert/strict';
import fs from 'node:fs';

const root=new URL('../',import.meta.url);
const sql1=fs.readFileSync(new URL('supabase/migrations/202610250001_targeted_offers_multiroute_compensation.sql',root),'utf8');
const sql2=fs.readFileSync(new URL('supabase/migrations/202610250002_targeted_merchant_wallet_settlement.sql',root),'utf8');
const server=fs.readFileSync(new URL('server/delivery.mjs',root),'utf8');
const main=fs.readFileSync(new URL('mobile/vuppi-entregador-android/app/src/main/java/br/com/vuppidelivery/entregador/MainActivity.java',root),'utf8');
const service=fs.readFileSync(new URL('mobile/vuppi-entregador-android/app/src/main/java/br/com/vuppidelivery/entregador/CourierService.java',root),'utf8');

assert.match(sql1,/preferred_courier/);
assert.match(sql1,/targeted_offer/);
assert.match(sql1,/route_stops/);
assert.match(sql1,/courier_share_bps_override/);
assert.match(sql1,/status='unattended'/);
assert.match(sql2,/p_action='redistribute'/);
assert.match(sql2,/merchant_targeted_offer/);
assert.match(server,/courier_finance_admin/);
assert.match(server,/route_total_cents/);
assert.match(main,/Ver rota completa/);
assert.match(main,/routeManifestDialog/);
assert.match(main,/targeted_offer/);
assert.match(service,/OFERTA DIRECIONADA/);
assert.match(service,/route_stops/);

console.log('targeted-offers-multiroute-v80.test.mjs passed');
