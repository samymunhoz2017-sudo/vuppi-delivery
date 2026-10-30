// Teste opcional com PGlite instalado fora do projeto, em banco descartável.
// Não substitui os testes de integração contra Supabase de homologação.
const assert=require('node:assert/strict');
const {readFileSync}=require('node:fs');
const {PGlite}=require(process.env.VUPPI_PGLITE_MODULE || '@electric-sql/pglite');
(async()=>{
 const db=new PGlite();
 try{
  await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;create table public.up_cidades(id text primary key);create table public.vuppi_members(user_id uuid primary key,kind text not null default 'courier',approved boolean not null default true,member_status text not null default 'active',allow_courier_return_completion boolean default false,address text default 'Endereço de teste',lat double precision,lng double precision);create table public.vuppi_quotes(id uuid primary key,pricing_snapshot jsonb);create table public.vuppi_deliveries(id uuid primary key,route_group_id uuid,merchant uuid,city text,payment_method text,courier uuid,status text,price_cents integer,return_required boolean,quote_id uuid,route_sequence integer,pickup_address text,destination text,recipient text,created_at timestamptz default now());create table public.vuppi_delivery_events(delivery_id uuid not null,actor_id uuid,event_type text,details jsonb);create table public.up_platform_audit(actor_id uuid,action text,target text,reason text,details jsonb);create table public.vuppi_financial_transactions(id uuid primary key);create function public.up_platform_is_admin() returns boolean language sql as $$select false$$;`);
  await db.exec(readFileSync('supabase/migrations/202610300001_grouped_route_foundation.sql','utf8'));
  await db.exec(readFileSync('supabase/migrations/202610300002_grouped_route_transitions.sql','utf8'));
  await db.exec(readFileSync('supabase/migrations/202610300003_prepare_grouped_route.sql','utf8'));
  // Estas duas funções simulam dependências legadas; os testes não comprovam as regras reais delas.
  await db.exec(`create function public.vuppi_accept_delivery_offer(p_delivery uuid) returns jsonb language plpgsql as $$declare g uuid;ids jsonb;begin select route_group_id into g from public.vuppi_deliveries where id=p_delivery;update public.vuppi_deliveries set courier=auth.uid(),status='assigned' where route_group_id=g;select jsonb_agg(id) into ids from public.vuppi_deliveries where route_group_id=g;return jsonb_build_object('accepted_ids',ids);end$$;create function public.vuppi_collect_group_at_pickup(p_delivery uuid) returns jsonb language plpgsql as $$declare g uuid;addr text;begin select route_group_id,pickup_address into g,addr from public.vuppi_deliveries where id=p_delivery;update public.vuppi_deliveries set status='collected' where route_group_id=g and pickup_address=addr;return jsonb_build_object('ok',true);end$$;`);
  await db.exec(readFileSync('supabase/migrations/202610300004_grouped_route_accept_collect.sql','utf8'));
  await db.exec(readFileSync('supabase/migrations/202610300005_grouped_route_state.sql','utf8'));
  await db.exec(`insert into public.up_cidades values ('teste');insert into public.vuppi_members(user_id,kind) values ('10000000-0000-0000-0000-000000000001','merchant');insert into public.vuppi_route_operations(id,merchant_id,city,state,requires_return,return_fee_cents) values ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','teste','delivering',true,300);`);
  const route='20000000-0000-0000-0000-000000000001';
  for(let n=1;n<=25;n++){
   const id='30000000-0000-0000-0000-'+String(n).padStart(12,'0');
   await db.query('insert into public.vuppi_deliveries(id) values ($1)',[id]);
   const insert=()=>db.query("insert into public.vuppi_route_stops(route_id,delivery_id,kind,sequence,frozen_price_cents,frozen_return_cents) values($1,$2,'delivery',$3,700,0)",[route,id,n]);
   if(n<=24)await insert();else await assert.rejects(insert,/24 entregas/);
  }
  await db.query("insert into public.vuppi_route_stops(route_id,kind,sequence) values($1,'return',25)",[route]);
  await assert.rejects(()=>db.query("insert into public.vuppi_route_stops(route_id,kind,sequence) values($1,'return',26)",[route]),error=>error.code==='23505');
  await assert.rejects(()=>db.query("update public.vuppi_route_stops set sequence=1 where route_id=$1 and kind='return'",[route]),/retorno precisa permanecer/);
  await assert.rejects(()=>db.query("update public.vuppi_route_stops set status='active' where route_id=$1 and sequence=2",[route]),/parada anterior/);
  await assert.rejects(()=>db.query("update public.vuppi_route_stops set status='active' where route_id=$1 and kind='return'",[route]),/parada anterior|última entrega/);
  await db.query("update public.vuppi_route_stops set status='active' where route_id=$1 and sequence=1",[route]);
  await assert.rejects(()=>db.query('delete from public.vuppi_route_stops where route_id=$1 and sequence=1',[route]),/não podem ser excluídas/);
  await assert.rejects(()=>db.query('update public.vuppi_route_stops set frozen_price_cents=1 where route_id=$1 and sequence=1',[route]),/snapshot financeiro/);
  await assert.rejects(()=>db.query("update public.vuppi_route_operations set state='completed' where id=$1",[route]),/etapas ou liquidação/);
  await assert.rejects(()=>db.query('update public.vuppi_route_operations set return_fee_applied=true where id=$1',[route]),/lançamento financeiro/);
  await db.query("insert into public.vuppi_route_settlements(route_id,version,idempotency_key,status,gross_cents,return_fee_cents,completed_at) values($1,1,'one','completed',1000,300,now())",[route]);
  await assert.rejects(()=>db.query("insert into public.vuppi_route_settlements(route_id,version,idempotency_key,status,gross_cents,return_fee_cents,completed_at) values($1,2,'two','completed',1000,300,now())",[route]),error=>error.code==='23505');
  const result=await db.query("select relrowsecurity from pg_class where oid='public.vuppi_route_stops'::regclass");assert.equal(result.rows[0].relrowsecurity,true);
  const route2='20000000-0000-0000-0000-000000000002',merchant='10000000-0000-0000-0000-000000000001',courier='10000000-0000-0000-0000-000000000002';
  await db.query('insert into auth.users(id) values ($1),($2)',[merchant,courier]);
  await db.query('insert into public.vuppi_members(user_id) values($1)',[courier]);
  await db.query("insert into public.vuppi_route_operations(id,merchant_id,courier_id,city,state,requires_return,return_fee_cents,return_address) values($1,$2,$3,'teste','delivering',true,300,'Retorno confidencial')",[route2,merchant,courier]);
  const stops=[];
  for(let n=1;n<=3;n++){
   const delivery='40000000-0000-0000-0000-'+String(n).padStart(12,'0');
   await db.query('insert into public.vuppi_deliveries(id) values($1)',[delivery]);
   const stop=await db.query("insert into public.vuppi_route_stops(route_id,delivery_id,kind,sequence,status,frozen_price_cents,frozen_return_cents) values($1,$2,'delivery',$3,$4,1000,300) returning id",[route2,delivery,n,n===1?'active':'pending']);stops.push(stop.rows[0].id);
  }
  await db.query("insert into public.vuppi_route_stops(route_id,kind,sequence) values($1,'return',4)",[route2]);
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[courier]);
  const beforeReturn=await db.query('select public.vuppi_route_get_state($1) result',[route2]);assert.equal(JSON.stringify(beforeReturn.rows[0].result).includes('Retorno confidencial'),false);assert.equal('return_fee_cents' in beforeReturn.rows[0].result,false);
  await assert.rejects(()=>db.query('select public.vuppi_route_confirm_delivery_stop($1,$2)',[route2,stops[1]]),/não está disponível/);
  let next=await db.query('select public.vuppi_route_confirm_delivery_stop($1,$2) result',[route2,stops[0]]);assert.equal(next.rows[0].result.next_stop_id,stops[1]);
  let retry=await db.query('select public.vuppi_route_confirm_delivery_stop($1,$2) result',[route2,stops[0]]);assert.equal(retry.rows[0].result.already_confirmed,true);assert.equal(retry.rows[0].result.next_stop_id,stops[1]);
  await db.query('select public.vuppi_route_confirm_delivery_stop($1,$2)',[route2,stops[1]]);
  next=await db.query('select public.vuppi_route_confirm_delivery_stop($1,$2) result',[route2,stops[2]]);assert.equal(next.rows[0].result.state,'returning');
  const returnState=await db.query('select public.vuppi_route_get_state($1) result',[route2]);assert.equal(returnState.rows[0].result.current_stop.address,'Retorno confidencial');
  let settlements=await db.query('select count(*)::int n from public.vuppi_route_settlements where route_id=$1',[route2]);assert.equal(settlements.rows[0].n,0);
  await assert.rejects(()=>db.query('select public.vuppi_route_confirm_return($1)',[route2]),/sem permissão/);
  await db.query('select public.vuppi_route_arrive_return($1)',[route2]);
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[merchant]);
  const done=await db.query('select public.vuppi_route_confirm_return($1) result',[route2]);assert.equal(done.rows[0].result.state,'settlement_pending');
  const again=await db.query('select public.vuppi_route_confirm_return($1) result',[route2]);assert.equal(again.rows[0].result.already_confirmed,true);
  settlements=await db.query('select count(*)::int n,max(gross_cents)::int gross from public.vuppi_route_settlements where route_id=$1',[route2]);assert.equal(settlements.rows[0].n,1);assert.equal(settlements.rows[0].gross,2400);
  const eventCounts=await db.query("select event_type,count(*)::int n from public.vuppi_delivery_events where details->>'route_id'=$1 group by event_type",[route2]);assert.equal(eventCounts.rows.find(x=>x.event_type==='route_stop_confirmed').n,3);assert.equal(eventCounts.rows.find(x=>x.event_type==='route_return_confirmed').n,1);
  const settlementId=done.rows[0].result.settlement_id,tx1='60000000-0000-0000-0000-000000000001',tx2='60000000-0000-0000-0000-000000000002';
  await db.query('insert into public.vuppi_financial_transactions(id) values($1),($2)',[tx1,tx2]);
  await db.query("insert into public.vuppi_route_settlement_movements(route_id,settlement_id,financial_transaction_id,component) values($1,$2,$3,'return_fee')",[route2,settlementId,tx1]);
  await assert.rejects(()=>db.query("insert into public.vuppi_route_settlement_movements(route_id,settlement_id,financial_transaction_id,component) values($1,$2,$3,'return_fee')",[route2,settlementId,tx2]),error=>error.code==='23505');
  const route3='20000000-0000-0000-0000-000000000003';
  await db.query("insert into public.vuppi_route_operations(id,merchant_id,courier_id,city,state,requires_return) values($1,$2,$3,'teste','delivering',false)",[route3,merchant,courier]);
  const normal=[];
  for(let n=1;n<=3;n++){
   const delivery='50000000-0000-0000-0000-'+String(n).padStart(12,'0');await db.query('insert into public.vuppi_deliveries(id) values($1)',[delivery]);
   const stop=await db.query("insert into public.vuppi_route_stops(route_id,delivery_id,kind,sequence,status,frozen_price_cents,frozen_return_cents) values($1,$2,'delivery',$3,$4,700,0) returning id",[route3,delivery,n,n===1?'active':'pending']);normal.push(stop.rows[0].id);
  }
  await assert.rejects(()=>db.query('select public.vuppi_route_confirm_delivery_stop($1,$2)',[route3,normal[0]]),/não autorizada/);
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[courier]);
  for(const stop of normal)await db.query('select public.vuppi_route_confirm_delivery_stop($1,$2)',[route3,stop]);
  const finalRetry=await db.query('select public.vuppi_route_confirm_delivery_stop($1,$2) result',[route3,normal[2]]);assert.equal(finalRetry.rows[0].result.already_confirmed,true);
  const normalSettlement=await db.query('select count(*)::int n,max(gross_cents)::int gross,max(return_fee_cents)::int fee from public.vuppi_route_settlements where route_id=$1',[route3]);assert.deepEqual(normalSettlement.rows[0],{n:1,gross:2100,fee:0});
  await assert.rejects(()=>db.query('select public.vuppi_route_arrive_return($1)',[route3]),/não está em andamento/);
  await db.query("select set_config('request.jwt.claim.sub','90000000-0000-0000-0000-000000000001',false)");
  await assert.rejects(()=>db.query('select public.vuppi_route_get_state($1)',[route3]),/não autorizada/);
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[courier]);
  await db.exec('set role authenticated');
  await assert.rejects(()=>db.query('select * from public.vuppi_route_settlements'),error=>error.code==='42501');
  const authenticatedRetry=await db.query('select public.vuppi_route_confirm_delivery_stop($1,$2) result',[route3,normal[2]]);assert.equal(authenticatedRetry.rows[0].result.already_confirmed,true);
  await db.exec('reset role');
  const route4='20000000-0000-0000-0000-000000000004';
  for(let n=1;n<=3;n++){
   const quote='70000000-0000-0000-0000-'+String(n).padStart(12,'0'),delivery='80000000-0000-0000-0000-'+String(n).padStart(12,'0');
   await db.query('insert into public.vuppi_quotes values($1,$2)',[quote,{return_cents:300,tariff_id:'tarifa-congelada'}]);
   await db.query("insert into public.vuppi_deliveries(id,route_group_id,merchant,city,payment_method,status,price_cents,return_required,quote_id,route_sequence,pickup_address) values($1,$2,$3,'teste','wallet','requested',1000,true,$4,$5,$6)",[delivery,route4,merchant,quote,n,n===3?'Loja B':'Loja A']);
  }
  await assert.rejects(()=>db.query('select public.vuppi_route_prepare_group($1)',[route4]),/não autorizada/);
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[merchant]);
  const prepared=await db.query('select public.vuppi_route_prepare_group($1) result',[route4]);assert.equal(prepared.rows[0].result.gross_cents,2400);assert.equal(prepared.rows[0].result.delivery_count,3);
  const repeat=await db.query('select public.vuppi_route_prepare_group($1) result',[route4]);assert.equal(repeat.rows[0].result.already_prepared,true);
  const preparedStops=await db.query("select count(*)::int n,count(*) filter(where kind='return')::int returns from public.vuppi_route_stops where route_id=$1",[route4]);assert.deepEqual(preparedStops.rows[0],{n:4,returns:1});
  await db.query("update public.vuppi_quotes set pricing_snapshot='{\"return_cents\":999}'::jsonb where id='70000000-0000-0000-0000-000000000001'");
  const frozen=await db.query("select frozen_return_cents::int fee,tariff_snapshot->>'return_cents' snapshot_fee from public.vuppi_route_stops where route_id=$1 and sequence=1",[route4]);assert.deepEqual(frozen.rows[0],{fee:300,snapshot_fee:'300'});
  async function fixture(routeId,prefix,returns,fees){
   for(let n=1;n<=3;n++){
    const quote=`${prefix}0000000-0000-0000-0000-${String(n).padStart(12,'0')}`,delivery=`${prefix}1000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
    await db.query('insert into public.vuppi_quotes values($1,$2)',[quote,{return_cents:fees[n-1]}]);
    await db.query("insert into public.vuppi_deliveries(id,route_group_id,merchant,city,payment_method,status,price_cents,return_required,quote_id,route_sequence) values($1,$2,$3,'teste','wallet','requested',1000,$4,$5,$6)",[delivery,routeId,merchant,returns[n-1],quote,n]);
   }
  }
  const oneReturn='20000000-0000-0000-0000-000000000005',noReturn='20000000-0000-0000-0000-000000000006',conflict='20000000-0000-0000-0000-000000000007';
  await fixture(oneReturn,'9',[true,false,false],[300,300,300]);
  await fixture(noReturn,'a',[false,false,false],[300,300,300]);
  await fixture(conflict,'b',[true,true,false],[300,400,300]);
  let preparedCase=await db.query('select public.vuppi_route_prepare_group($1) result',[oneReturn]);assert.equal(preparedCase.rows[0].result.gross_cents,3000);assert.equal(preparedCase.rows[0].result.return_fee_cents,300);
  preparedCase=await db.query('select public.vuppi_route_prepare_group($1) result',[noReturn]);assert.equal(preparedCase.rows[0].result.gross_cents,3000);assert.equal(preparedCase.rows[0].result.requires_return,false);
  await assert.rejects(()=>db.query('select public.vuppi_route_prepare_group($1)',[conflict]),/Taxas de retorno diferentes/);
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[courier]);
  const firstDelivery='80000000-0000-0000-0000-000000000001',lastDelivery='80000000-0000-0000-0000-000000000003';
  const accepted=await db.query('select public.vuppi_route_accept_group($1,$2) result',[route4,firstDelivery]);assert.equal(accepted.rows[0].result.count,3);
  const acceptedAgain=await db.query('select public.vuppi_route_accept_group($1,$2) result',[route4,firstDelivery]);assert.equal(acceptedAgain.rows[0].result.already_accepted,true);
  const collection=await db.query('select public.vuppi_route_collect_group($1,$2) result',[route4,firstDelivery]);assert.equal(collection.rows[0].result.state,'collecting');assert.equal(collection.rows[0].result.next_pickup_delivery_id,lastDelivery);
  const collectionAgain=await db.query('select public.vuppi_route_collect_group($1,$2) result',[route4,firstDelivery]);assert.equal(collectionAgain.rows[0].result.already_collected,true);assert.equal(collectionAgain.rows[0].result.next_pickup_delivery_id,lastDelivery);
  const lastPickup=await db.query('select public.vuppi_route_collect_group($1,$2) result',[route4,lastDelivery]);assert.equal(lastPickup.rows[0].result.state,'delivering');
  console.log('Postgres local isolado: limite, retorno único e final, liquidação única e RLS verificados.');
 }finally{await db.close()}
})().catch(error=>{console.error(error);process.exitCode=1});
