import assert from 'node:assert/strict';
import {createHmac} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {MercadoPagoPaymentProvider,paymentProvider,validateMercadoPagoSignature} from '../server/financial.mjs';

const requests=[];
const provider=new MercadoPagoPaymentProvider({MERCADOPAGO_ENABLED:'true',MERCADOPAGO_LIVE_MODE:'false',MERCADOPAGO_ACCESS_TOKEN:'TEST-token',UP_PUBLIC_ORIGIN:'https://vuppidelivery.com.br'},async(url,options)=>{
 requests.push({url,options});return new Response(JSON.stringify({id:'pref-123',init_point:'https://www.mercadopago.com.br/checkout',sandbox_init_point:'https://sandbox.mercadopago.com.br/checkout'}),{status:201,headers:{'content-type':'application/json'}});
});
const charge=await provider.createCheckoutPreference({externalReference:'11111111-1111-4111-8111-111111111111',value:102,email:'loja@example.com'});
assert.equal(charge.checkout_url,'https://sandbox.mercadopago.com.br/checkout');
assert.equal(requests[0].url,'https://api.mercadopago.com/checkout/preferences');
const sent=JSON.parse(requests[0].options.body);
assert.equal(sent.external_reference,'11111111-1111-4111-8111-111111111111');
assert.equal(sent.notification_url,'https://vuppidelivery.com.br/api/finance/mercadopago/webhook');
assert.equal(requests[0].options.headers['X-Idempotency-Key'],sent.external_reference);
assert.equal(paymentProvider({MERCADOPAGO_ENABLED:'true'}).name,'mercadopago');

const ts='1742505638683',requestId='request-1',dataId='999999999',secret='webhook-secret';
const digest=createHmac('sha256',secret).update(`id:${dataId};request-id:${requestId};ts:${ts};`).digest('hex');
assert.equal(await validateMercadoPagoSignature({signature:`ts=${ts},v1=${digest}`,requestId,dataId,secret}),true);
assert.equal(await validateMercadoPagoSignature({signature:`ts=${ts},v1=${'0'.repeat(64)}`,requestId,dataId,secret}),false);

const sql=readFileSync(new URL('../supabase/migrations/202610180004_mercadopago_wallet.sql',import.meta.url),'utf8');
for(const invariant of ['vuppi_mercadopago_link','vuppi_mercadopago_settle',"p_status<>'approved'",'p_amount_cents<>t.total_cents',"p_currency<>'BRL'",'topup-credit:','grant execute','service_role'])assert.ok(sql.includes(invariant),`Mercado Pago sem ${invariant}`);
const worker=readFileSync(new URL('../server/worker.mjs',import.meta.url),'utf8'),ui=readFileSync(new URL('../dist/delivery.js',import.meta.url),'utf8'),host=readFileSync(new URL('../server/hostinger.mjs',import.meta.url),'utf8');
assert.ok(worker.indexOf("/api/finance/mercadopago/webhook")<worker.indexOf("Sec-Fetch-Site"),'webhook deve ser validado por assinatura antes da proteção de origem do navegador');
assert.ok(ui.includes('Pagar com Mercado Pago')&&ui.includes('result.checkout_url'));
assert.ok(host.includes("'MERCADOPAGO_ACCESS_TOKEN'")&&host.includes("'MERCADOPAGO_WEBHOOK_SECRET'"));
console.log('Mercado Pago: checkout, assinatura, webhook e liquidação idempotente verificados.');
