import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const migration=readFileSync(new URL('../supabase/migrations/202610200001_financial_settings_and_courier_net.sql',import.meta.url),'utf8');
const withdrawalMigration=readFileSync(new URL('../supabase/migrations/202610210001_withdrawal_approval_rules.sql',import.meta.url),'utf8');
const deliveryServer=readFileSync(new URL('../server/delivery.mjs',import.meta.url),'utf8');
const financeServer=readFileSync(new URL('../server/financial.mjs',import.meta.url),'utf8');
const admin=readFileSync(new URL('../dist/admin.js',import.meta.url),'utf8');
const courier=readFileSync(new URL('../dist/delivery.js',import.meta.url),'utf8');

for(const invariant of ['vuppi_finance_settings_admin','vuppi_courier_financial_rules','courier_share_bps','merchant_minimum_balance_cents','min_topup_cents','min_withdrawal_cents','vuppi_financial_audit'])assert.ok(migration.includes(invariant),`Regra financeira sem ${invariant}`);
assert.ok(financeServer.includes("action==='settings_save'")&&financeServer.includes('vuppi_finance_settings_admin'));
assert.ok(financeServer.includes("action==='withdrawal_review'")&&financeServer.includes('vuppi_withdrawal_review'));
for(const invariant of ['withdrawal_dual_approval_threshold_cents','dual_required','result_status','A segunda aprovação deve ser feita por outra pessoa'])assert.ok(withdrawalMigration.includes(invariant),`Revisão de saque sem ${invariant}`);
assert.ok(deliveryServer.includes('Math.floor(gross*share/10000)'),'o backend deve substituir o bruto pelo líquido antes de responder ao entregador');
assert.ok(deliveryServer.includes('delete copy.merchant_price_cents')&&deliveryServer.includes('delete copy.platform_fee_cents'));
for(const label of ['ESTABELECIMENTO','ENTREGADOR','VUPPI MATRIZ','Valor líquido da entrega','Simulação sobre R$ 10,00'])assert.ok(admin.includes(label),`Central de taxas sem ${label}`);
for(const invariant of ['withdrawalModal','data-review-withdrawal','Sincronizar pagamento Pix','admin-flash'])assert.ok(admin.includes(invariant),`Revisão de saque sem ${invariant}`);
assert.ok(!admin.includes("prompt('Motivo da aprovação"),'A revisão de saque ainda depende de prompt incompatível.');
assert.ok(admin.includes("action:'withdrawal_review'"),'O modal deve usar a revisão transacional de saques.');
assert.ok(courier.includes('valor líquido a receber'));
assert.ok(courier.includes('checkUniversalPending')&&courier.includes('Entrega pendente disponível'));
assert.ok(courier.includes('courier-cancel-zone')&&courier.includes('Cancelar e redistribuir'));
console.log('Regras financeiras, privacidade do valor bruto e pendências universais verificadas.');
