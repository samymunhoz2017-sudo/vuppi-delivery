import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const web=readFileSync(new URL('../dist/delivery.js',import.meta.url),'utf8');
const nativeService=readFileSync(new URL('../mobile/vuppi-entregador-android/app/src/main/java/br/com/vuppidelivery/entregador/CourierService.java',import.meta.url),'utf8');
const nativeUi=readFileSync(new URL('../mobile/vuppi-entregador-android/app/src/main/java/br/com/vuppidelivery/entregador/MainActivity.java',import.meta.url),'utf8');
const finance=readFileSync(new URL('../server/financial.mjs',import.meta.url),'utf8');
const host=readFileSync(new URL('../server/hostinger.mjs',import.meta.url),'utf8');
const sql=readFileSync(new URL('../supabase/migrations/202610240002_pending_routes_payouts.sql',import.meta.url),'utf8');

assert.match(web,/offerRows=filter==='available'\|\|filter==='pending'/);
assert.match(web,/\.\.\.offers,\.\.\.pendingOffers/);
assert.match(nativeService,/available&&!active\?firstEligibleOffer/);
assert.match(nativeService,/boolean access=profile!=null&&profile\.optBoolean\("approved"\)/);
assert.match(nativeUi,/data\.put\("pix_key",pixKey\)/);

for(const invariant of [
 'vuppi_merchant_courier_favorites',
 "p_action='favorite'",
 "accepted_from='merchant_route_append'",
 'vuppi_validate_courier_active_route',
 'vuppi_withdrawal_payout_secrets',
 'vuppi_withdrawal_payout_payload',
 'vuppi_withdrawal_payout_submitted',
 'vuppi_withdrawal_payout_finalize'
])assert.ok(sql.includes(invariant),`Migração v79 sem ${invariant}`);

for(const invariant of ['/v1/payouts','X-signature','Ed25519','requestPixTransfer','handleMercadoPagoPayoutWebhook','syncMercadoPagoWithdrawal'])assert.ok(finance.includes(invariant),`Payouts sem ${invariant}`);
for(const variable of ['MERCADOPAGO_PAYOUTS_ENABLED','MERCADOPAGO_PAYOUTS_ACCESS_TOKEN','MERCADOPAGO_PAYOUTS_PRIVATE_KEY'])assert.ok(host.includes(variable),`Host sem ${variable}`);
assert.match(web,/Atribuir ou adicionar à rota/);
assert.match(web,/Favoritar este entregador/);
assert.match(web,/preferredCourier/);
console.log('V79: pendências, presença online, rotas incrementais, favoritos e Payouts verificados.');
