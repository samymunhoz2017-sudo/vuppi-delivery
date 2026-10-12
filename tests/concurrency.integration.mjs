import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
export async function runConcurrency(){
 if(!['development','homologation'].includes(process.env.UP_TEST_ENV)||process.env.UP_TEST_DISPOSABLE!=='1')throw Error('Ambiente de integração não autorizado.');
 const ids=Array.from({length:12},()=>randomUUID()),[p,d1,d2,other,moto,q,r,v1,v2,o1,o2,wrongOffer]=ids;
 const city='test-car-'+randomUUID(),city2='test-car-'+randomUUID();
 const users=[p,d1,d2,other,moto].map(id=>`'${id}'`).join(',');
 const query=sql=>new Promise((resolve,reject)=>{const child=spawn(process.env.UP_PSQL_PATH||'psql',['-X','-A','-t','-q','-v','ON_ERROR_STOP=1'],{env:process.env,stdio:['pipe','pipe','pipe']});let out='',err='';child.stdout.on('data',b=>out+=b);child.stderr.on('data',b=>err+=b);child.on('error',()=>reject(Error('psql não disponível')));child.on('close',code=>code===0?resolve(out.trim()):reject(Error(err.slice(0,1500))));child.stdin.end('set search_path=public,extensions;set statement_timeout=15000;\n'+sql)});
 const asUser=(id,sql)=>`begin;set local role authenticated;select set_config('request.jwt.claim.sub','${id}',true),set_config('request.jwt.claims','{"sub":"${id}","role":"authenticated"}',true);${sql};commit;`;
 let created=false;
 try{
  await query(`begin;
insert into auth.users(id,email) values ${[p,d1,d2,other,moto].map(id=>`('${id}','${id}@example.invalid')`).join(',')};
insert into up_cidades(id,nome,uf) values('${city}','Teste isolado A','SP'),('${city2}','Teste isolado B','SP');
insert into up_car_city_settings(city_id,enabled,center) values('${city}',true,st_setsrid(st_makepoint(0,0),4326)::geography),('${city2}',true,st_setsrid(st_makepoint(0,0),4326)::geography);
insert into up_car_categories(city_id,code,name,enabled) values('${city}','standard','Teste',true),('${city2}','standard','Teste',true);
insert into up_car_profiles(user_id,full_name) values ${[p,d1,d2,other,moto].map(id=>`('${id}','Teste')`).join(',')};
insert into up_car_staff(user_id,city_id,role,active) values('${other}','${city2}','operator',true);
insert into up_car_drivers(user_id,city_id,category,state,online) values('${d1}','${city}','standard','approved',true),('${d2}','${city}','standard','approved',true),('${other}','${city2}','standard','approved',true);
insert into up_car_vehicles(id,driver_id,city_id,category,plate,brand,model,color,year,seats,approved) values('${v1}','${d1}','${city}','standard','ABC1D23','Teste','Teste','Teste',2024,4,true),('${v2}','${d2}','${city}','standard','ABC2D23','Teste','Teste','Teste',2024,4,true),(gen_random_uuid(),'${other}','${city2}','standard','ABC3D23','Teste','Teste','Teste',2024,4,true);
insert into up_car_locations(driver_id,position,accuracy_m,reported_at) select user_id,st_setsrid(st_makepoint(0,0),4326)::geography,5,now() from up_car_drivers where user_id in ('${d1}','${d2}','${other}');
insert into up_car_quotes(id,passenger_id,city_id,category,origin_label,destination_label,origin,destination,distance_m,duration_s,polyline,price_cents,tariff_snapshot) values('${q}','${p}','${city}','standard','Origem','Destino',st_setsrid(st_makepoint(0,0),4326)::geography,st_setsrid(st_makepoint(0.001,0),4326)::geography,1000,300,'fixture',1234,'{"base_cents":500}');
insert into up_car_rides(id,quote_id,passenger_id,city_id,category,idempotency_key,price_cents,tariff_snapshot,payment_method) values('${r}','${q}','${p}','${city}','standard',gen_random_uuid(),1234,'{"base_cents":500}','cash');
insert into up_car_offers(id,ride_id,driver_id,wave,eta_s,expires_at) values('${o1}','${r}','${d1}',1,30,now()+interval '5 minutes'),('${o2}','${r}','${d2}',1,30,now()+interval '5 minutes'),('${wrongOffer}','${r}','${other}',1,30,now()+interval '5 minutes');
commit;`);created=true;
  await query(asUser(moto,`do $$ begin if up_car_command('offers','{}')<>'[]'::jsonb then raise exception 'Entregador recebeu carro'; end if;begin perform up_car_command('accept','{"offer_id":"${o1}"}');raise exception 'Aceite indevido';exception when others then if sqlerrm not like 'UP_CAR:%' then raise;end if;end;end $$`));
  await query(asUser(other,`do $$ begin begin perform up_car_command('accept','{"offer_id":"${wrongOffer}"}');raise exception 'Cidade incompatível aceita';exception when others then if sqlerrm not like 'UP_CAR:%' then raise;end if;end;end $$`));
  await query(`delete from up_car_offers where id='${wrongOffer}';`);
  for(const change of [
   `update up_car_vehicles set approved=false where id='${v1}'`,
   `update up_car_vehicles set city_id='${city2}' where id='${v1}'`,
   `update up_car_categories set enabled=false where city_id='${city}'`
  ]){
   await query(change);
   await query(asUser(d1,`do $$ begin begin perform up_car_command('accept','{"offer_id":"${o1}"}');raise exception 'Incompatibilidade ignorada';exception when others then if sqlerrm not like 'UP_CAR:%' then raise;end if;end;end $$`));
   await query(`update up_car_vehicles set approved=true,city_id='${city}' where id='${v1}';update up_car_categories set enabled=true where city_id='${city}';`);
  }
  await query(asUser(other,`do $$ begin if exists(select 1 from up_car_rides where id='${r}') or exists(select 1 from up_car_locations where driver_id='${d1}') then raise exception 'Vazamento entre cidades';end if;end $$`));
  const accepted=await Promise.allSettled([[d1,o1],[d2,o2]].map(([driver,offer])=>query(asUser(driver,`select up_car_command('accept','{"offer_id":"${offer}"}')`))));
  assert.equal(accepted.filter(x=>x.status==='fulfilled').length,1,'Dois aceites devem produzir exatamente um vencedor');
  await query(`begin;do $$ declare who uuid;q2 uuid; begin
select driver_id into who from up_car_rides where id='${r}';
insert into up_car_quotes(passenger_id,city_id,category,origin_label,destination_label,origin,destination,distance_m,duration_s,polyline,price_cents,tariff_snapshot) select '${moto}',city_id,category,origin_label,destination_label,origin,destination,distance_m,duration_s,polyline,price_cents,tariff_snapshot from up_car_quotes where id='${q}' returning id into q2;
begin insert into up_car_rides(quote_id,passenger_id,driver_id,city_id,category,status,idempotency_key,price_cents,tariff_snapshot,payment_method) values(q2,'${moto}',who,'${city}','standard','accepted',gen_random_uuid(),1234,'{}','cash');raise exception 'Motorista recebeu segunda corrida ativa';exception when unique_violation then null;end;
end $$;rollback;`);
  await query(`do $$ begin if not exists(select 1 from up_car_rides where id='${r}' and status='accepted' and driver_id in ('${d1}','${d2}')) then raise exception 'Sem vencedor persistido';end if;end $$;update up_car_categories set base_cents=9900 where city_id='${city}';do $$ begin if (select price_cents from up_car_rides where id='${r}')<>1234 or (select tariff_snapshot->>'base_cents' from up_car_rides where id='${r}')<>'500' then raise exception 'Tarifa alterou corrida existente';end if;end $$;`);
  await query(asUser(moto,`do $$ begin if exists(select 1 from up_car_rides where id='${r}') or exists(select 1 from up_car_locations where driver_id in ('${d1}','${d2}')) then raise exception 'Outro usuário acessou corrida/localização';end if;end $$`));
  console.log('Integração: dois aceites simultâneos com um vencedor; rejeição de entregador/cidade incompatível; isolamento por cidade/usuário; tarifa preservada.');
 }finally{
  if(created)await query(`begin;delete from up_car_events where city_id in ('${city}','${city2}');delete from up_car_start_secrets where ride_id='${r}';delete from up_car_ratings where ride_id='${r}';delete from up_car_offers where ride_id='${r}';delete from up_car_rides where id='${r}';delete from up_car_quotes where id='${q}';delete from up_car_locations where driver_id in (${users});delete from up_car_documents where driver_id in (${users});delete from up_car_vehicles where driver_id in (${users});delete from up_car_drivers where user_id in (${users});delete from up_car_staff where user_id in (${users});delete from up_car_profiles where user_id in (${users});delete from up_car_categories where city_id in ('${city}','${city2}');delete from up_car_city_settings where city_id in ('${city}','${city2}');delete from up_cidades where id in ('${city}','${city2}');delete from auth.users where id in (${users});commit;`);
 }
}
