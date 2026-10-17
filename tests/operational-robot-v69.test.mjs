import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {handleDelivery} from '../server/delivery.mjs';

const read=path=>readFileSync(new URL('../'+path,import.meta.url),'utf8');
const delivery=read('dist/delivery.js');
const html=read('dist/delivery.html');
const admin=read('dist/admin.js');
const activity=read('mobile/vuppi-entregador-android/app/src/main/java/br/com/vuppidelivery/entregador/MainActivity.java');
const server=read('server/delivery.mjs');

// Robô de homologação: cadastro pendente não pode iniciar a operação.
let profile={kind:'courier',approved:false,member_status:'pending'},calls=[];
const context={
  env:{},
  session:async()=>({s:{access:'courier-token'},user:{id:'courier-1'}}),
  readJson:request=>request.json(),
  json:(data,status=200)=>Response.json(data,{status}),
  renewCookie:async()=>{},
  upstream:async(path,options)=>{
    calls.push({path,options});
    if(options?.body?.p_action==='state')return {profile,orders:[],offers:[]};
    return {ok:true};
  }
};
const action=(name,data={})=>new Request('https://vuppi.test/api/delivery/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:name,data})});
let response=await handleDelivery(action('availability',{available:true}),context);
assert.equal(response.status,403);
assert.match((await response.json()).message,/análise/i);
assert.equal(calls.some(call=>call.options?.body?.p_action==='availability'),false);

// Após a aprovação, o mesmo login pode ficar disponível sem novo cadastro.
profile={...profile,approved:true,member_status:'active'};calls=[];
response=await handleDelivery(action('availability',{available:true}),context);
assert.equal(response.status,200);
assert.equal(calls.some(call=>call.options?.body?.p_action==='availability'),true);

// Suspensão posterior interrompe localização e despacho no backend.
profile={...profile,approved:true,member_status:'suspended'};calls=[];
response=await handleDelivery(action('location',{lat:-21.01,lng:-48.22}),context);
assert.equal(response.status,403);
assert.equal(calls.some(call=>call.path?.includes('vuppi_driver_location')),false);

// Contratos visuais e operacionais das três interfaces.
for(const invariant of ['id="accessGate"','id="courierHome"','id="merchantHome"'])assert.ok(html.includes(invariant));
for(const invariant of ['memberAccess','renderAccessGate','Seu cadastro está em análise','courierLocationWatch=null','todayStart.setHours(0,0,0,0)','courier-motorcycle-3d.svg','courier-settings-hero'])assert.ok(delivery.includes(invariant),`interface sem ${invariant}`);
for(const invariant of ['courierMapIcon','courier-motorcycle-3d.svg','liveCourierMarkers'])assert.ok(admin.includes(invariant),`mapa administrativo sem ${invariant}`);
for(const invariant of ['hasOperationalAccess','showAccessGate','Verificar liberação','stopService(new Intent(this,CourierService.class))','api.get("/api/delivery/state")'])assert.ok(activity.includes(invariant),`Android sem ${invariant}`);
assert.match(server,/courierActions/);
assert.match(server,/status!==\'active\'/);

console.log('Robô operacional V69: bloqueio pendente/suspenso, ativação, privacidade da localização, mapa diário e marcadores validados.');
