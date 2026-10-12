import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const context=vm.createContext({window:{},globalThis:{},Math});
vm.runInContext(readFileSync(new URL('../dist/app-core.js',import.meta.url),'utf8'),context);
const {compareVersions,retryDelay,OfferController}=context.window.VUPPICore;

assert.equal(compareVersions('0.51.0','0.50.9'),1);
assert.equal(compareVersions('v1.2','1.2.0'),0);
assert.equal(compareVersions('1.2.0','1.2.1'),-1);
assert.equal(retryDelay(0,{base:1000,max:60000,jitter:0}),1000);
assert.equal(retryDelay(20,{base:1000,max:60000,jitter:0}),60000);

const offers=new OfferController();
assert.equal(offers.select([{id:'a'},{id:'b'}]).id,'a');
assert.equal(offers.select([{id:'b'},{id:'a'}]).id,'a','Atualização não pode trocar a oferta exibida');
assert.equal(offers.begin('a'),true);
assert.equal(offers.begin('a'),false,'Aceite duplicado deve ser bloqueado');
offers.finish('a');assert.equal(offers.begin('a'),true);
offers.dismiss('a');assert.equal(offers.activeId,'');
assert.equal(offers.select([{id:'a'},{id:'b'}],new Set(['a'])).id,'b');

const delivery=readFileSync(new URL('../dist/delivery.js',import.meta.url),'utf8');
assert.match(delivery,/return result\}/,'A resposta da ação deve ser preservada para o fluxo de retorno');
assert.doesNotMatch(delivery,/invalidateSize\(/,'Google Maps não deve receber método da API Leaflet');
assert.match(delivery,/google\.maps\.event\.trigger\(courierMap,'resize'\)/);
console.log('App v51: versões, backoff, oferta única, aceite idempotente e redimensionamento do Google Maps aprovados.');
