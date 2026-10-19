import http from 'node:http';
import {webcrypto} from 'node:crypto';
import app from './worker.mjs';
import {runCarDispatch} from './carros.mjs';
import {runFinanceBilling} from './financial.mjs';
import {publicOrigin,gatewayRequest,gatewayResponse} from './node-gateway.mjs';
if(!globalThis.crypto)globalThis.crypto=webcrypto;
const origin=publicOrigin(process.env.UP_PUBLIC_ORIGIN||'https://vuppidelivery.com.br');
const env={};for(const name of ['SUPABASE_URL','SUPABASE_PUBLISHABLE_KEY','UP_SESSION_KEY','UP_CITY_ID','UP_PUBLIC_ORIGIN','SUPABASE_SECRET_KEY','SUPABASE_SERVICE_ROLE_KEY','GOOGLE_MAPS_BROWSER_KEY','GOOGLE_MAPS_SERVER_KEY','UP_ANDROID_UPDATE_ACTIVE','UP_ANDROID_LATEST_VERSION','UP_ANDROID_MIN_VERSION','UP_ANDROID_UPDATE_TYPE','UP_ANDROID_STORE_URL','UP_ANDROID_UPDATE_TITLE','UP_ANDROID_UPDATE_MESSAGE','UP_ANDROID_RELEASED_AT','UP_ANDROID_ROLLOUT_PERCENTAGE','VUPPI_BILLING_SCHEDULE_ACTIVE','ASAAS_ENABLED','ASAAS_LIVE_OPERATIONS_ENABLED','ASAAS_ENV','ASAAS_API_KEY','ASAAS_WEBHOOK_TOKEN','ASAAS_BASE_URL','MERCADOPAGO_ENABLED','MERCADOPAGO_LIVE_MODE','MERCADOPAGO_ACCESS_TOKEN','MERCADOPAGO_WEBHOOK_SECRET'])env[name]=process.env[name];
const port=Number(process.env.PORT||3000);if(!Number.isInteger(port)||port<1||port>65535)throw Error('Porta inválida.');
const server=http.createServer(async(incoming,outgoing)=>{
 try{
  if(incoming.url==='/healthz'){outgoing.writeHead(200,{'Content-Type':'application/json','Cache-Control':'no-store'});outgoing.end('{"status":"ok","release":"wallet-20261012"}');return}
  // WebSocketPair pertence ao runtime Cloudflare. Node utiliza a consulta periódica.
  if(incoming.headers.upgrade){outgoing.writeHead(503,{'Content-Type':'application/json'});outgoing.end('{"message":"Atualização periódica ativa nesta hospedagem."}');return}
  const request=await gatewayRequest(incoming,origin);await gatewayResponse(await app.fetch(request,env),outgoing);
 }catch(e){if(!outgoing.headersSent)outgoing.writeHead(e.status||500,{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store'});outgoing.end(JSON.stringify({message:e.status?e.message:'Não foi possível atender a solicitação. Tente novamente.'}));}
});
server.requestTimeout=30000;server.headersTimeout=15000;server.maxHeadersCount=100;
server.on('upgrade',(_,socket)=>socket.end('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n'));
server.listen(port,'0.0.0.0',()=>console.log('Servidor UP iniciado. Segredos são carregados somente pelas variáveis do ambiente.'));
server.on('error',()=>{console.error('Não foi possível iniciar o servidor UP.');process.exitCode=1});
let running=false;const timer=setInterval(async()=>{if(running||!env.SUPABASE_SECRET_KEY||!env.GOOGLE_MAPS_SERVER_KEY)return;running=true;try{await runCarDispatch(env)}catch{console.error('Despacho indisponível. Verifique a configuração do banco e dos mapas.')}finally{running=false}},15000);timer.unref();
let billingRunning=false;const billingTimer=setInterval(async()=>{if(billingRunning||(!env.SUPABASE_SERVICE_ROLE_KEY&&!env.SUPABASE_SECRET_KEY))return;billingRunning=true;try{const date=new Date().toISOString().slice(0,10),active=env.VUPPI_BILLING_SCHEDULE_ACTIVE==='true';await runFinanceBilling(env,fetch,{dryRun:!active,runKey:`hostinger-${date}`})}catch{console.error('Rotina de mensalidades indisponível.')}finally{billingRunning=false}},60*60*1000);billingTimer.unref();
for(const signal of ['SIGTERM','SIGINT'])process.on(signal,()=>{clearInterval(timer);clearInterval(billingTimer);server.close(()=>process.exit(0));setTimeout(()=>process.exit(0),10000).unref()});
