import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const migration=readFileSync(new URL('../supabase/migrations/202610220001_withdrawal_release_and_rejection.sql',import.meta.url),'utf8');
const server=readFileSync(new URL('../server/financial.mjs',import.meta.url),'utf8');
const admin=readFileSync(new URL('../dist/admin.js',import.meta.url),'utf8');
const css=readFileSync(new URL('../dist/admin.css',import.meta.url),'utf8');

assert.match(migration,/not public\.up_platform_is_admin\(\) and not public\.vuppi_finance_step_up\(\)/);
assert.match(migration,/create or replace function public\.vuppi_withdrawal_reject/);
assert.match(migration,/withdrawal_rejected/);
assert.match(migration,/reserved_account,available_account/);
assert.match(migration,/status='rejected'/);
assert.match(server,/action==='withdrawal_reject'/);
assert.match(admin,/data-reject-withdrawal/);
assert.match(admin,/Recusar e devolver saldo/);
assert.match(admin,/Saque recusado e saldo devolvido ao entregador/);
assert.match(admin,/enhanceAdminShell/);
assert.match(css,/Vuppi Admin v0\.77/);
assert.match(css,/tbody tr\.selected/);
assert.match(css,/prefers-reduced-motion/);
console.log('withdrawal-admin-v77.test.mjs ok');
