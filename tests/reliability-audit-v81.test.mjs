import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const read=path=>readFileSync(new URL('../'+path,import.meta.url),'utf8');
const cars=read('server/carros.mjs'),hostinger=read('server/hostinger.mjs');
const admin=read('dist/admin.js'),delivery=read('dist/delivery.js'),quick=read('dist/admin-quick.js');

assert.ok((cars.match(/Authorization:'Bearer '\+env\.SUPABASE_SECRET_KEY/g)||[]).length>=2,'todas as RPCs privilegiadas do despacho precisam autenticar com Bearer');
assert.match(hostinger,/lastDispatchError/,'o serviço deve impedir inundação do log pelo mesmo erro');
assert.doesNotMatch(admin,/(?<!\.)\bprompt\s*\(/,'o painel não pode usar prompt(), incompatível com o contêiner Android');
assert.doesNotMatch(delivery,/(?<!\.)\bprompt\s*\(/,'os portais não podem usar prompt(), incompatível com o contêiner Android');
assert.doesNotMatch(quick,/(?<!\.)\balert\s*\(/,'ações rápidas devem usar o sistema visual de mensagens');
assert.match(admin,/Mercado Pago conectado/,'a saúde financeira deve identificar o gateway real');
assert.match(delivery,/APP_VERSION='0\.83\.0'/);
assert.match(admin,/function adminAsk\(/);
assert.match(delivery,/function portalAskReason\(/);
console.log('reliability-audit-v81.test.mjs passed');
