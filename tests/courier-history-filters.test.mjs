import assert from 'node:assert/strict';
import {handleDelivery} from '../server/delivery.mjs';
import {handleFinancial} from '../server/financial.mjs';
const calls=[];
const c={env:{},session:async()=>({s:{access:'courier-token'},user:{id:'courier'}}),json:(data,status=200)=>Response.json(data,{status}),renewCookie:async()=>{},upstream:async(path,options)=>{calls.push({path,options});return [{id:'one',price_cents:500}];}};
let result=await handleDelivery(new Request('https://example.test/api/delivery/history?date=2026-10-20'),c);
assert.equal(result.status,200);assert.equal((await result.json()).orders[0].price_cents,500);assert.equal(calls.at(-1).options.token,'courier-token');assert.equal(calls.at(-1).options.body.p_date,'2026-10-20');
result=await handleDelivery(new Request('https://example.test/api/delivery/history?date=bad'),c);assert.equal(result.status,400);
for(const period of ['today','yesterday','7days','30days']){result=await handleFinancial(new Request('https://example.test/api/finance/courier-statement?period='+period),c);assert.equal(result.status,200);assert.equal(calls.at(-1).options.body.p_period,period);assert.equal(calls.at(-1).options.token,'courier-token');}
result=await handleFinancial(new Request('https://example.test/api/finance/courier-statement?period=invalid'),c);assert.equal(result.status,400);
console.log('Histórico do entregador: datas, períodos e encaminhamento da sessão verificados.');
