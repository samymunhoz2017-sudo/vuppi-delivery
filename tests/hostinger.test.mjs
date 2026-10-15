import assert from 'node:assert/strict';
import {gatewayRequest,publicOrigin} from '../server/node-gateway.mjs';
import {createWorker} from '../server/worker.mjs';
import assets from '../server/assets.mjs';
const origin=publicOrigin('https://smmidias.site');
const incoming=(url,headers={},method='GET',body='')=>({url,headers,method,async *[Symbol.asyncIterator](){if(body)yield Buffer.from(body)}});
assert.throws(()=>publicOrigin('http://smmidias.site'));assert.throws(()=>publicOrigin('https://user:password@smmidias.site'));assert.throws(()=>publicOrigin('https://smmidias.site/other'));
const request=await gatewayRequest(incoming('/admin',{host:'evil.example','x-forwarded-host':'evil.example','x-forwarded-proto':'http'}),origin);assert.equal(request.url,origin+'/admin');
const app=createWorker(assets,async()=>{throw Error('Não deveria consultar Supabase')});let response=await app.fetch(request,{});assert.equal(response.status,200);assert.match(await response.text(),/Centro de comando/);
response=await app.fetch(new Request(origin+'/'),{});assert.equal(response.status,200,'Endereço principal abre o portal de acesso');const home=await response.text();assert.match(home,/Centro de comando/);assert.match(home,/Painel do estabelecimento/);assert.match(home,/Aplicativo do entregador/);assert.match(home,/Administração da plataforma/);
for(const path of ['/operacao','/estabelecimento','/entregador']){response=await app.fetch(new Request(origin+path),{});assert.equal(response.status,200,`${path} abre seu portal separado`);assert.match(await response.text(),/id="auth"/);}
response=await app.fetch(new Request(origin+'/entregador'),{});const courierPage=await response.text();assert.match(courierPage,/manifest-courier\.webmanifest\?v=66/);assert.match(courierPage,/app-core\.js\?v=66/);
response=await app.fetch(new Request(origin+'/entregas?old-pwa=1'),{});assert.equal(response.status,302,'O endereço do PWA antigo encaminha ao app de entregador');assert.equal(response.headers.get('Location'),'/entregador?old-pwa=1');
response=await app.fetch(new Request(origin+'/admin'),{});assert.equal(response.status,200);assert.match(await response.text(),/id="admin-login"/);
await assert.rejects(()=>gatewayRequest(incoming('//evil.example/login'),origin));
const forged=await gatewayRequest(incoming('/api/auth/login',{origin:'https://evil.example','Content-Type':'application/json'},'POST','{}'),origin);response=await app.fetch(forged,{});assert.equal(response.status,403,'Não reescrever Origin e não confiar em cabeçalhos do cliente');
console.log('Hostinger: origem HTTPS fixa, headers de proxy sem influência na sessão, recusa de origem forjada e servidor integrado às telas.');
const logo=await app.fetch(new Request(origin+'/vuppi-logo.png'),{});
assert.equal(logo.headers.get('Content-Type'),'image/png');
assert.deepEqual([...new Uint8Array(await logo.arrayBuffer()).slice(0,8)],[137,80,78,71,13,10,26,10],'Logo deve ser servida como PNG binário');



