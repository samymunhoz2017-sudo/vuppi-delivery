import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {calculateTopup,calculateWithdrawal,calculateBillingTopup,canWithdrawToday,FakePaymentProvider,AsaasPaymentProvider,cents} from '../server/financial.mjs';

assert.deepEqual(calculateTopup(10000),{amount_cents:10000,fee_cents:200,total_cents:10200,credit_cents:10000});
assert.deepEqual(calculateTopup(10000,200,'deduct'),{amount_cents:10000,fee_cents:200,total_cents:10000,credit_cents:9800});
assert.deepEqual(calculateWithdrawal(10000),{amount_cents:10000,fee_cents:150,net_cents:9850,reserve_cents:10000});
assert.deepEqual(calculateBillingTopup(10000,2990,200),{recharge_cents:10000,subscription_debt_cents:2990,fee_cents:200,total_cents:13190,wallet_credit_cents:10000});
assert.equal(canWithdrawToday(new Date('2026-10-05T15:00:00Z')),true);
assert.throws(()=>cents(1.2),/inválido/);
assert.throws(()=>calculateWithdrawal(100),/maior que a taxa/);
const fake=new FakePaymentProvider();const charge=await fake.createPixCharge({value:102});assert.equal(charge.status,'pending');assert.equal(fake.calls.length,1);
const asaas=new AsaasPaymentProvider({ASAAS_ENABLED:'false',ASAAS_LIVE_OPERATIONS_ENABLED:'false'});await assert.rejects(()=>asaas.createPixCharge({}),/desativadas/);
const sql=readFileSync(new URL('../supabase/migrations/202610050003_financial_wallet.sql',import.meta.url),'utf8');
for(const invariant of ['vuppi_ledger_entries','vuppi_financial_transactions','idempotency_key','enable row level security','vuppi_reject_ledger_mutation','delivery_reserve','delivery_release','withdrawal_reserve','admin_confirm_topup','America/Sao_Paulo'])assert.ok(sql.includes(invariant),`migration sem ${invariant}`);
assert.match(sql,/revoke all on public\.vuppi_finance_settings[\s\S]+from anon,authenticated/i);
assert.doesNotMatch(sql,/revoke all on all tables in schema public/i,'a migration financeira não pode revogar tabelas de outros módulos');
console.log('financial.test: ok');
