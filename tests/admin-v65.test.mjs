import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const read=path=>readFileSync(new URL('../'+path,import.meta.url),'utf8');
const admin=read('dist/admin.js'),css=read('dist/admin.css'),delivery=read('server/delivery.mjs'),finance=read('server/financial.mjs'),sql=read('supabase/migrations/202610130001_operation_wallet_hardening.sql');

for(const invariant of ['dateStart','order-date-start','order-date-end','order-merchant','order-courier','admin_manage','redistribute-order','finalize-order','edit-order-form'])assert.ok(admin.includes(invariant),`gestão de OS sem ${invariant}`);
assert.match(admin,/state\.pending\?\.deliveries/);
assert.doesNotMatch(admin,/mode==='occurrences'\?orders\.filter\(o=>o\.status==='cancelled'\)/);
for(const invariant of ['wallet-adjust-modal','data-adjust-wallet','admin_adjust','amount_cents','idempotency_key'])assert.ok(admin.includes(invariant),`carteira administrativa sem ${invariant}`);
for(const invariant of ['city-grid','dispatch-flow','logistics-kpis','type-flow'])assert.ok(admin.includes(invariant),`redesign administrativo sem ${invariant}`);
assert.match(css,/Vuppi Admin v0\.65/);
assert.match(css,/\.admin-authenticated #admin-view \.admin-form/);
assert.match(delivery,/vuppi_create_delivery_transaction/);
assert.match(delivery,/vuppi_admin_manage_delivery/);
assert.match(finance,/vuppi_admin_wallet_adjust/);
for(const invariant of ['vuppi_create_delivery_transaction','vuppi_admin_wallet_adjust','vuppi_admin_manage_delivery','delivery_reserve','Saldo disponível insuficiente','manual_credit','manual_debit','redistributed_count'])assert.ok(sql.includes(invariant),`migration operacional sem ${invariant}`);
assert.match(sql,/after update of status,payment_method/);
assert.match(sql,/reconciled_on_completion/);
assert.match(sql,/idempotency_key='delivery-reserve:'\|\|new\.id/);
assert.match(sql,/if share>0 then/);
console.log('V65: OS, pendências, logística, cidades e carteira administrativa verificados.');
