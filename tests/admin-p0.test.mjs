import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const quick=await readFile(new URL('../dist/admin-quick.js',import.meta.url),'utf8');
const admin=await readFile(new URL('../dist/admin.js',import.meta.url),'utf8');
const enhancements=await readFile(new URL('../dist/admin-enhancements.js',import.meta.url),'utf8');
const html=await readFile(new URL('../dist/admin.html',import.meta.url),'utf8');
const css=await readFile(new URL('../dist/admin.css',import.meta.url),'utf8');
const delivery=await readFile(new URL('../dist/delivery.js',import.meta.url),'utf8');

assert.ok(!quick.includes('location.reload'), 'entrega rápida não pode recarregar a página');
assert.match(quick,/submitting=true/,'entrega rápida bloqueia envio duplicado');
assert.match(quick,/vuppi:delivery-created/,'entrega rápida emite evento local de sucesso');
assert.match(admin,/addEventListener\('vuppi:delivery-created'/,'admin reage ao sucesso sem desmontar o shell');
assert.match(admin,/billing=f\.billing\|\|\{\}/,'billing possui fallback seguro');
assert.match(admin,/\['billing','Mensalidades'\]/,'mensalidades estão acessíveis');
assert.match(admin,/\['exemptions','Isenções'\]/,'isenções estão acessíveis');
assert.match(admin,/selector\?\.value/,'extrato não acessa seletor inexistente');
assert.ok(!enhancements.includes('setInterval'),'não existe polling global concorrente');
assert.match(html,/id="admin-command-search"/,'shell possui busca de comandos');
assert.match(css,/--admin-bg:#07111f/,'design system escuro está aplicado');
assert.match(delivery,/merchantTab==='consumers'/,'loja possui tela de consumidores');
console.log('admin-p0.test.mjs: ok');
