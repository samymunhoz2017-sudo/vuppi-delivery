-- VUPPI 0.67: precificação configurável, auditável e preservada por cotação.
begin;

create table if not exists public.vuppi_delivery_tariffs(
 id uuid primary key default gen_random_uuid(),
 city text not null references public.up_cidades(id),
 merchant uuid references public.vuppi_members(user_id) on delete cascade,
 name text not null default 'Tarifa padrão',
 enabled boolean not null default true,
 version integer not null default 1 check(version between 1 and 1000000),
 base_distance_m integer not null default 2000 check(base_distance_m between 0 and 30000),
 base_cents integer not null default 800 check(base_cents between 0 and 1000000),
 additional_step_m integer not null default 1000 check(additional_step_m between 100 and 5000),
 additional_step_cents integer not null default 150 check(additional_step_cents between 0 and 1000000),
 minimum_cents integer not null default 800 check(minimum_cents between 0 and 1000000),
 maximum_distance_m integer not null default 30000 check(maximum_distance_m between 1000 and 100000),
 return_cents integer not null default 300 check(return_cents between 0 and 1000000),
 updated_at timestamptz not null default now(),
 updated_by uuid references auth.users(id),
 check(maximum_distance_m>base_distance_m)
);
create unique index if not exists vuppi_delivery_tariff_city_default on public.vuppi_delivery_tariffs(city) where merchant is null;
create unique index if not exists vuppi_delivery_tariff_merchant on public.vuppi_delivery_tariffs(city,merchant) where merchant is not null;
alter table public.vuppi_delivery_tariffs enable row level security;
revoke all on public.vuppi_delivery_tariffs from public,anon,authenticated;

insert into public.vuppi_delivery_tariffs(city,name)
select id,'Tarifa padrão · '||nome from public.up_cidades
on conflict(city) where merchant is null do nothing;

alter table public.vuppi_quotes add column if not exists pricing_snapshot jsonb not null default '{}'::jsonb;
alter table public.vuppi_quotes add column if not exists return_required boolean not null default false;
alter table public.vuppi_quotes drop constraint if exists vuppi_quotes_price_cents_check;
alter table public.vuppi_quotes add constraint vuppi_quotes_price_cents_check check(price_cents between 0 and 1000000);

create or replace function public.vuppi_calculate_delivery_price(
 p_merchant uuid,p_city text,p_distance_m integer,p_return_required boolean default false
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare t public.vuppi_delivery_tariffs;steps integer;subtotal integer;total integer;
begin
 if p_merchant is null or nullif(trim(p_city),'') is null then raise exception 'VUPPI_PRICE: Estabelecimento e cidade são obrigatórios.'; end if;
 select * into t from public.vuppi_delivery_tariffs
  where city=p_city and enabled and (merchant=p_merchant or merchant is null)
  order by (merchant is not null) desc limit 1;
 if t.id is null then raise exception 'VUPPI_PRICE: Não há tarifa ativa para esta cidade.'; end if;
 if p_distance_m is null or p_distance_m<=0 then raise exception 'VUPPI_PRICE: Distância da rota inválida.'; end if;
 if p_distance_m>t.maximum_distance_m then raise exception 'VUPPI_PRICE: Rota fora do limite de atendimento da tarifa.'; end if;
 steps:=ceil(greatest(0,p_distance_m-t.base_distance_m)::numeric/t.additional_step_m)::integer;
 subtotal:=greatest(t.minimum_cents,t.base_cents+steps*t.additional_step_cents);
 total:=subtotal+case when coalesce(p_return_required,false) then t.return_cents else 0 end;
 if total<0 or total>1000000 then raise exception 'VUPPI_PRICE: Valor calculado fora do limite permitido.'; end if;
 return jsonb_build_object(
  'price_cents',total,'subtotal_cents',subtotal,'return_cents',case when coalesce(p_return_required,false) then t.return_cents else 0 end,
  'distance_m',p_distance_m,'return_required',coalesce(p_return_required,false),'tariff_id',t.id,'tariff_name',t.name,'tariff_version',t.version,
  'scope',case when t.merchant is null then 'city' else 'merchant' end,
  'snapshot',jsonb_build_object('tariff_id',t.id,'name',t.name,'version',t.version,'scope',case when t.merchant is null then 'city' else 'merchant' end,
   'base_distance_m',t.base_distance_m,'base_cents',t.base_cents,'additional_step_m',t.additional_step_m,
   'additional_step_cents',t.additional_step_cents,'minimum_cents',t.minimum_cents,'maximum_distance_m',t.maximum_distance_m,
   'return_cents',t.return_cents,'calculated_steps',steps,'subtotal_cents',subtotal,'total_cents',total)
 );
end;$$;

create or replace function public.vuppi_create_quote(p_data jsonb) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();target uuid:=auth.uid();adm boolean:=public.up_platform_is_admin();m public.vuppi_members;q public.vuppi_quotes;dist integer;needs_return boolean;calculation jsonb;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 if adm and nullif(p_data->>'merchant','') is not null then target:=(p_data->>'merchant')::uuid; end if;
 select * into m from public.vuppi_members where user_id=target and kind='merchant';
 if m.user_id is null or not m.approved or (adm and not m.quick_delivery_enabled) then raise exception 'UP_CAR: Estabelecimento não aprovado ou modalidade indisponível.'; end if;
 if not adm and target<>uid then raise exception 'UP_CAR: Estabelecimento inválido.'; end if;
 dist:=(p_data->>'distance_m')::integer;needs_return:=coalesce((p_data->>'return_required')::boolean,false);
 calculation:=public.vuppi_calculate_delivery_price(target,m.city,dist,needs_return);
 insert into public.vuppi_quotes(id,merchant,city,lat,lng,distance_m,price_cents,expires_at,pricing_snapshot,return_required)
 values(gen_random_uuid(),target,m.city,(p_data->>'lat')::float8,(p_data->>'lng')::float8,dist,(calculation->>'price_cents')::integer,now()+interval '5 minutes',calculation->'snapshot',needs_return)
 returning * into q;
 return to_jsonb(q)||jsonb_build_object('pricing',calculation);
end;$$;

create or replace function public.vuppi_pricing_admin(p_action text,p_data jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare t public.vuppi_delivery_tariffs;merchant_id uuid;city_id text;distance_value integer;result jsonb;
begin
 if not public.up_platform_is_admin() then raise exception 'UP_CAR: Acesso exclusivo do administrador.'; end if;
 if p_action='state' then
  return jsonb_build_object(
   'tariffs',coalesce((select jsonb_agg(to_jsonb(x) order by city,merchant nulls first) from public.vuppi_delivery_tariffs x),'[]'::jsonb),
   'cities',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.nome,'uf',c.uf,'active',c.ativa) order by c.nome) from public.up_cidades c),'[]'::jsonb),
   'merchants',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'name',m.name,'city',m.city) order by m.name) from public.vuppi_members m where m.kind='merchant' and m.approved),'[]'::jsonb)
  );
 end if;
 city_id:=nullif(trim(p_data->>'city'),'');merchant_id:=nullif(p_data->>'merchant','')::uuid;
 if p_action='test' then
  distance_value:=round(coalesce((p_data->>'distance_m')::numeric,0))::integer;
  if merchant_id is null then select user_id into merchant_id from public.vuppi_members where kind='merchant' and approved and city=city_id order by created_at limit 1; end if;
  if merchant_id is null then raise exception 'VUPPI_PRICE: Selecione um estabelecimento aprovado para simular.'; end if;
  return public.vuppi_calculate_delivery_price(merchant_id,city_id,distance_value,coalesce((p_data->>'return_required')::boolean,false));
 end if;
 if p_action='save' then
  if city_id is null then raise exception 'VUPPI_PRICE: Selecione a cidade.'; end if;
  if merchant_id is not null and not exists(select 1 from public.vuppi_members where user_id=merchant_id and kind='merchant' and city=city_id) then raise exception 'VUPPI_PRICE: O estabelecimento não pertence à cidade selecionada.'; end if;
  if merchant_id is null then
   insert into public.vuppi_delivery_tariffs(city,merchant,name,enabled,base_distance_m,base_cents,additional_step_m,additional_step_cents,minimum_cents,maximum_distance_m,return_cents,updated_by)
   values(city_id,null,left(coalesce(nullif(trim(p_data->>'name'),''),'Tarifa padrão'),80),coalesce((p_data->>'enabled')::boolean,true),
    (p_data->>'base_distance_m')::integer,(p_data->>'base_cents')::integer,(p_data->>'additional_step_m')::integer,
    (p_data->>'additional_step_cents')::integer,(p_data->>'minimum_cents')::integer,(p_data->>'maximum_distance_m')::integer,
    (p_data->>'return_cents')::integer,auth.uid())
   on conflict(city) where merchant is null do update set name=excluded.name,enabled=excluded.enabled,version=vuppi_delivery_tariffs.version+1,
    base_distance_m=excluded.base_distance_m,base_cents=excluded.base_cents,additional_step_m=excluded.additional_step_m,
    additional_step_cents=excluded.additional_step_cents,minimum_cents=excluded.minimum_cents,maximum_distance_m=excluded.maximum_distance_m,
    return_cents=excluded.return_cents,updated_at=now(),updated_by=auth.uid()
   returning * into t;
  else
   insert into public.vuppi_delivery_tariffs(city,merchant,name,enabled,base_distance_m,base_cents,additional_step_m,additional_step_cents,minimum_cents,maximum_distance_m,return_cents,updated_by)
   values(city_id,merchant_id,left(coalesce(nullif(trim(p_data->>'name'),''),'Tarifa personalizada'),80),coalesce((p_data->>'enabled')::boolean,true),
    (p_data->>'base_distance_m')::integer,(p_data->>'base_cents')::integer,(p_data->>'additional_step_m')::integer,
    (p_data->>'additional_step_cents')::integer,(p_data->>'minimum_cents')::integer,(p_data->>'maximum_distance_m')::integer,
    (p_data->>'return_cents')::integer,auth.uid())
   on conflict(city,merchant) where merchant is not null do update set name=excluded.name,enabled=excluded.enabled,version=vuppi_delivery_tariffs.version+1,
    base_distance_m=excluded.base_distance_m,base_cents=excluded.base_cents,additional_step_m=excluded.additional_step_m,
    additional_step_cents=excluded.additional_step_cents,minimum_cents=excluded.minimum_cents,maximum_distance_m=excluded.maximum_distance_m,
    return_cents=excluded.return_cents,updated_at=now(),updated_by=auth.uid()
   returning * into t;
  end if;
  insert into public.up_platform_audit(actor_id,action,target,reason,details) values(auth.uid(),'delivery_pricing_save',t.id::text,'Configuração de tarifa',to_jsonb(t));
  return jsonb_build_object('ok',true,'tariff',to_jsonb(t));
 end if;
 if p_action='delete_override' then
  if merchant_id is null then raise exception 'VUPPI_PRICE: A tarifa padrão da cidade não pode ser excluída.'; end if;
  delete from public.vuppi_delivery_tariffs where city=city_id and merchant=merchant_id returning * into t;
  if t.id is null then raise exception 'VUPPI_PRICE: Tarifa personalizada não encontrada.'; end if;
  insert into public.up_platform_audit(actor_id,action,target,reason,details) values(auth.uid(),'delivery_pricing_delete',t.id::text,'Remoção de tarifa personalizada',to_jsonb(t));
  return jsonb_build_object('ok',true);
 end if;
 raise exception 'VUPPI_PRICE: Ação de precificação inválida.';
end;$$;


-- A opção de retorno e seu preço ficam vinculados à cotação aceita; o navegador não pode alterá-los depois.
create or replace function public.vuppi_delivery_details(p_quote uuid,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); d public.vuppi_deliveries; q public.vuppi_quotes; payment text:=coalesce(nullif(p_data->>'payment_method',''),'pix'); amount integer:=coalesce((nullif(p_data->>'cash_to_collect_cents',''))::integer,0);
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 select * into d from public.vuppi_deliveries where quote_id=p_quote for update;
 select * into q from public.vuppi_quotes where id=p_quote;
 if d.id is null or q.id is null then raise exception 'UP_CAR: Entrega ou cotação não encontrada.'; end if;
 if d.merchant<>uid and not public.up_platform_is_admin() then raise exception 'UP_CAR: Acesso não autorizado.'; end if;
 if payment not in ('pix','cash','credit','wallet') then raise exception 'UP_CAR: Forma de pagamento inválida.'; end if;
 if amount<0 or amount>1000000 then raise exception 'UP_CAR: Valor a cobrar inválido.'; end if;
 update public.vuppi_deliveries set external_order_number=nullif(left(trim(p_data->>'external_order_number'),60),''),payment_method=payment,cash_to_collect_cents=amount,notes=nullif(left(trim(p_data->>'notes'),500),''),return_required=q.return_required where id=d.id returning * into d;
 return to_jsonb(d);
end;$$;

revoke all on function public.vuppi_calculate_delivery_price(uuid,text,integer,boolean),public.vuppi_create_quote(jsonb),public.vuppi_pricing_admin(text,jsonb) from public,anon;
grant execute on function public.vuppi_create_quote(jsonb),public.vuppi_pricing_admin(text,jsonb) to authenticated;
grant execute on function public.vuppi_delivery_details(uuid,jsonb) to authenticated;
commit;

