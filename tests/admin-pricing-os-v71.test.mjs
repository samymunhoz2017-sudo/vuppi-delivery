import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const read=path=>readFileSync(new URL('../'+path,import.meta.url),'utf8');
const admin=read('dist/admin.js');
const pricing=read('supabase/migrations/202610180001_fix_pricing_admin.sql');
const incidents=read('supabase/migrations/202610180002_os_incidents.sql');

assert.match(pricing,/c\.nome/);
assert.match(pricing,/jsonb_build_object\('id',c\.id,'name',c\.nome/);
assert.match(pricing,/steps:=ceil/);
assert.match(pricing,/tariff_version','prévia'/);
assert.doesNotMatch(pricing,/return public\.vuppi_calculate_delivery_price\(merchant_id/);
assert.match(admin,/Alteração e ocorrências de OS/);
assert.match(admin,/Analisar e corrigir/);
assert.match(admin,/operation:'record_issue'/);
assert.match(admin,/Tipo da correção/);
assert.match(admin,/Tarifas cadastradas/);
assert.match(admin,/pricing-list[\s\S]*\$\{cards\}/);
assert.match(incidents,/record_issue/);
assert.match(incidents,/requested','assigned','collected/);

console.log('V71: precificação, lista de tarifas e gestão auditada de ocorrências de OS verificadas.');
