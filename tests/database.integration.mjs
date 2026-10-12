import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
// Integração explícita: nunca aplica migrations nem usa produção automaticamente.
if(!['development','homologation'].includes(process.env.UP_TEST_ENV)||process.env.UP_TEST_DISPOSABLE!=='1'){
 console.log('NÃO EXECUTADO: requer banco descartável de desenvolvimento/homologação, UP_TEST_ENV e UP_TEST_DISPOSABLE=1.');
 process.exit(0);
}
if(!process.env.PGHOST||!process.env.PGUSER||!process.env.PGPASSWORD){console.error('Configure PGHOST, PGPORT, PGDATABASE, PGUSER e PGPASSWORD fora do código.');process.exit(1)}
const uid=randomUUID(),outsider=randomUUID();
const sql=`\set ON_ERROR_STOP on
begin;
set local search_path=public,extensions;
insert into auth.users(id,email) values('${uid}','${uid}@example.invalid'),('${outsider}','${outsider}@example.invalid');
insert into up_car_profiles(user_id,full_name) values('${uid}','Teste isolado');
do $$ begin
 if has_function_privilege('authenticated','public.up_car_quote_for(uuid,text,text,jsonb)','EXECUTE') then raise exception 'Preço privilegiado exposto ao usuário'; end if;
 if has_function_privilege('authenticated','public.up_car_dispatch(uuid,jsonb)','EXECUTE') then raise exception 'Despacho privilegiado exposto'; end if;
 if has_table_privilege('authenticated','public.up_car_start_secrets','SELECT') then raise exception 'Segredo de início exposto'; end if;
 if has_table_privilege('authenticated','public.up_car_rides','INSERT') then raise exception 'Inserção direta exposta'; end if;
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','${outsider}',true),set_config('request.jwt.claims','{"sub":"${outsider}","role":"authenticated"}',true);
do $$ begin if exists(select 1 from up_car_profiles where user_id='${uid}') then raise exception 'RLS não isolou outro usuário'; end if; end $$;
select set_config('request.jwt.claim.sub','${uid}',true),set_config('request.jwt.claims','{"sub":"${uid}","role":"authenticated"}',true);
do $$ begin if not exists(select 1 from up_car_profiles where user_id='${uid}') then raise exception 'Titular sem acesso ao perfil'; end if; end $$;
select up_car_command('profile','{"full_name":"Teste atualizado","phone":"","safety_name":"","safety_phone":""}');
do $$ begin
 begin
  perform up_car_command('driver_register','{"vehicle_type":"moto","product":"delivery_moto"}');
  raise exception 'Teste falhou: moto aceita';
 exception when others then if sqlerrm not like 'UP_CAR:%' then raise; end if; end;
end $$;
reset role;
rollback;
`;
const child=spawn(process.env.UP_PSQL_PATH||'psql',['-X','-q','-v','ON_ERROR_STOP=1'],{env:process.env,stdio:['pipe','pipe','pipe']});
let error='';child.stdout.resume();child.stderr.on('data',chunk=>error+=chunk);
child.on('error',()=>{console.error('Não foi possível executar psql. Configure UP_PSQL_PATH.');process.exitCode=1});
child.on('close',async code=>{if(code===0){console.log('Integração aprovada: RLS de perfil, permissões de RPC, proteção de PIN e rejeição de moto. Transação revertida.');try{await (await import('./concurrency.integration.mjs')).runConcurrency()}catch(e){console.error('Integração concorrente falhou: '+e.message);process.exitCode=1}}else{console.error('Integração falhou. Nenhuma fixture foi confirmada. '+error.slice(0,1500));process.exitCode=1}});
child.stdin.end(sql);
