import {readFileSync} from 'node:fs';
import {Script} from 'node:vm';
const files=['base.js','central.js','auth.js','auth-client.js','config.js','carros.js','admin.js','app-core.js','delivery.js','delivery-extras.js','delivery-schedule.js','sw.js'];
for(const file of files)new Script(readFileSync(new URL('../dist/'+file,import.meta.url),'utf8'),{filename:file});
for(const page of ['carros.html','admin.html','delivery.html']){const html=readFileSync(new URL('../dist/'+page,import.meta.url),'utf8');const ids=[...html.matchAll(/\bid="([^"]+)"/g)].map(m=>m[1]);if(new Set(ids).size!==ids.length)throw Error('Identificadores HTML duplicados: '+page)}
for(const file of ['database.integration.mjs','concurrency.integration.mjs'])new Script(readFileSync(new URL('../tests/'+file,import.meta.url),'utf8').replace(/^import .*?;\r?\n/gm,'').replace('export async function','async function'),{filename:file});
await import('../server/carros.mjs');await import('../server/worker.mjs');await import('../dist/server/index.js');
console.log('Sintaxe JavaScript e módulos do servidor aprovados; IDs fixos do UP Carros únicos. Não há lint ou typecheck configurados neste projeto JavaScript.');
