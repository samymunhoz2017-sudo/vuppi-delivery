import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const sql=readFileSync(new URL('../supabase/migrations/202610110001_vuppi_wallet_billing.sql',import.meta.url),'utf8');
const admin=readFileSync(new URL('../dist/admin.js',import.meta.url),'utf8');
const merchant=readFileSync(new URL('../dist/delivery.js',import.meta.url),'utf8');
const worker=readFileSync(new URL('../server/worker.mjs',import.meta.url),'utf8');
for(const invariant of [
 'merchant_monthly_fee_cents bigint not null default 2990',
 'vuppi_store_billing_profiles','vuppi_subscription_invoices','vuppi_payment_allocations',
 'vuppi_billing_run_execute','vuppi_topup_allocate_subscription','vuppi_withdrawal_risk_gate',
 'enable row level security','Autenticação reforçada necessária','idempotency_key',
 "merchant_monthly_billing boolean not null default false"
])assert.ok(sql.includes(invariant),`billing migration sem ${invariant}`);
assert.match(sql,/revoke all on public\.vuppi_finance_permissions[\s\S]+from anon,authenticated/i);
assert.match(sql,/if not p_dry_run and not cfg\.merchant_monthly_billing then raise exception/i);
assert.ok(admin.includes('billing_run_preview'));
assert.ok(admin.includes('billing_exemption_mass_apply'));
assert.ok(admin.includes('withdrawal_review'));
assert.ok(admin.includes('free_period_days'));
assert.ok(merchant.includes('Mensalidades pendentes'));
assert.ok(merchant.includes('subscriptionDebt'));
assert.ok(worker.includes("VUPPI_BILLING_SCHEDULE_ACTIVE==='true'"));
console.log('wallet-billing.test: ok');
