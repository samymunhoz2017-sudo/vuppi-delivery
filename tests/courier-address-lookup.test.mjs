import assert from 'node:assert/strict';
import {createWorker} from '../server/worker.mjs';

let calls=0;
const worker=createWorker({},async url=>{calls++;const parsed=new URL(url);assert.equal(parsed.hostname,'maps.googleapis.com');assert.match(parsed.searchParams.get('address'),/Rua das Flores/);return Response.json({status:'OK',results:[{formatted_address:'Rua das Flores, Pitangueiras - SP'}]});});
const env={GOOGLE_MAPS_SERVER_KEY:'test-server-key'};
const short=await worker.fetch(new Request('https://vuppi.example/api/courier/address?q=Ru'),env);
assert.deepEqual(await short.json(),{results:[]});assert.equal(calls,0);
const response=await worker.fetch(new Request('https://vuppi.example/api/courier/address?q=Rua%20das%20Flores'),env);
assert.equal(response.status,200);assert.deepEqual(await response.json(),{results:[{label:'Rua das Flores, Pitangueiras - SP'}]});assert.equal(calls,1);
const unavailable=await worker.fetch(new Request('https://vuppi.example/api/courier/address?q=Rua%20das%20Flores'),{});
assert.equal(unavailable.status,503);
console.log('Busca de endereço para cadastro: consulta sem sessão e falha segura verificadas.');
