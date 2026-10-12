-- Homologacao 0.60: pendencias auditaveis, clientes salvos e controles de despacho.
-- Preparada para homologacao. Nao aplicar em producao sem backup e validacao do ambiente.
begin;

alter table public.vuppi_operation_settings
 add column if not exists reoffer_delay_seconds integer not null default 30,
 add column if not exists pending_after_seconds integer not null default 90,
 add column if not exists max_offer_rounds integer not null default 5,
 add column if not exists offer_sound_enabled boolean not null default true,
 add column if not exists push_enabled boolean not null default true,
 add column if not exists operation_timezone text not null default 'America/Sao_Paulo';

create table if not exists public.vuppi_merchant_customers(
 id uuid primary key default gen_random_uuid(),
 merchant_id uuid not null references auth.users(id) on delete cascade,
 city text not null references public.up_cidades(id),
 phone_normalized text not null check(phone_normalized ~ '^[0-9]{10,15}$'),
 name text not null check(length(trim(name)) between 2 and 100),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(merchant_id,phone_normalized)
);
create table if not exists public.vuppi_merchant_customer_addresses(
 id uuid primary key default gen_random_uuid(),
 customer_id uuid not null references public.vuppi_merchant_customers(id) on delete cascade,
 label text not null default 'Principal', address text not null,
 complement text not null default '', usage_count integer not null default 1,
 last_used_at timestamptz not null default now(), created_at timestamptz not null default now(),
 unique(customer_id,address,complement)
);
create index if not exists vuppi_customer_phone_idx on public.vuppi_merchant_customers(merchant_id,phone_normalized);
alter table public.vuppi_merchant_customers enable row level security;
alter table public.vuppi_merchant_customer_addresses enable row level security;
revoke all on public.vuppi_merchant_customers,public.vuppi_merchant_customer_addresses from public,anon,authenticated;

create or replace function public.vuppi_merchant_customer(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); m public.vuppi_members; normalized text; customer public.vuppi_merchant_customers; address_id uuid;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 select * into m from public.vuppi_members where user_id=uid and kind='merchant' and approved;
 if m.user_id is null then raise exception 'UP_CAR: Acesso exclusivo do estabelecimento aprovado.'; end if;
 normalized:=regexp_replace(coalesce(p_data->>'phone',''),'[^0-9]','','g');
 if length(normalized) not between 10 and 15 then raise exception 'UP_CAR: Informe um telefone valido com DDD.'; end if;
 if p_action='find' then
  select * into customer from public.vuppi_merchant_customers where merchant_id=uid and phone_normalized=normalized;
  if customer.id is null then return jsonb_build_object('found',false); end if;
  return jsonb_build_object('found',true,'customer',jsonb_build_object('id',customer.id,'name',customer.name,'phone',customer.phone_normalized),
   'addresses',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'label',a.label,'address',a.address,'complement',a.complement,'last_used_at',a.last_used_at) order by a.last_used_at desc) from public.vuppi_merchant_customer_addresses a where a.customer_id=customer.id),'[]'::jsonb));
 elsif p_action='save' then
  if length(trim(coalesce(p_data->>'name','')))<2 then raise exception 'UP_CAR: Informe o nome do cliente.'; end if;
  insert into public.vuppi_merchant_customers(merchant_id,city,phone_normalized,name)
   values(uid,m.city,normalized,left(trim(p_data->>'name'),100))
   on conflict(merchant_id,phone_normalized) do update set name=excluded.name,updated_at=now() returning * into customer;
  if length(trim(coalesce(p_data->>'address','')))<5 then raise exception 'UP_CAR: Informe o endereco completo do cliente.'; end if;
  insert into public.vuppi_merchant_customer_addresses(customer_id,label,address,complement)
   values(customer.id,left(coalesce(nullif(trim(p_data->>'label'),''),'Principal'),40),left(trim(p_data->>'address'),250),coalesce(left(trim(p_data->>'complement'),120),''))
   on conflict(customer_id,address,complement) do update set usage_count=vuppi_merchant_customer_addresses.usage_count+1,last_used_at=now()
   returning id into address_id;
  return jsonb_build_object('ok',true,'customer_id',customer.id,'address_id',address_id);
 end if;
 raise exception 'UP_CAR: Operacao de cliente invalida.';
end;$$;
revoke all on function public.vuppi_merchant_customer(text,jsonb) from public,anon;
grant execute on function public.vuppi_merchant_customer(text,jsonb) to authenticated;

create or replace function public.vuppi_courier_pending_state() returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); m public.vuppi_members;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 select * into m from public.vuppi_members where user_id=uid and kind='courier' and approved;
 if m.user_id is null then raise exception 'UP_CAR: Perfil de entregador nao encontrado.'; end if;
 return jsonb_build_object(
  'available',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at) from (
    select d.id,d.merchant_name,d.pickup_address,d.destination,d.price_cents,d.distance_m,d.created_at,'available'::text as pending_status
    from public.vuppi_deliveries d where d.city=m.city and d.status='requested'
     and coalesce(d.dispatch_at,d.scheduled_for,d.created_at)<=now()
     and not exists(select 1 from public.vuppi_delivery_offer_decisions od where od.delivery_id=d.id and od.courier_id=uid)
    limit 50) x),'[]'::jsonb),
  'decisions',coalesce((select jsonb_agg(to_jsonb(x) order by x.decided_at desc) from (
    select d.id,d.merchant_name,d.destination,d.price_cents,od.decision,od.decided_at,d.status,
     case when d.status='requested' then 'reoffering' else d.status end as pending_status
    from public.vuppi_delivery_offer_decisions od join public.vuppi_deliveries d on d.id=od.delivery_id
    where od.courier_id=uid and od.decided_at>now()-interval '24 hours' limit 50) x),'[]'::jsonb),
  'updated_at',now());
end;$$;
revoke all on function public.vuppi_courier_pending_state() from public,anon;
grant execute on function public.vuppi_courier_pending_state() to authenticated;

create or replace function public.vuppi_logistics_admin(p_action text,p_data jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare s public.vuppi_operation_settings; t public.vuppi_delivery_types;
begin
 if not public.up_platform_is_admin() then raise exception 'UP_CAR: Acesso exclusivo do administrador.'; end if;
 if p_action='state' then return jsonb_build_object('settings',(select to_jsonb(x) from public.vuppi_operation_settings x where id='default'),'types',coalesce((select jsonb_agg(to_jsonb(x) order by priority,name) from public.vuppi_delivery_types x),'[]'::jsonb)); end if;
 if p_action='save_settings' then
  update public.vuppi_operation_settings set
   dispatch_lead_minutes=greatest(0,least(120,coalesce((p_data->>'dispatch_lead_minutes')::int,dispatch_lead_minutes))),
   pickup_deadline_minutes=greatest(1,least(120,coalesce((p_data->>'pickup_deadline_minutes')::int,pickup_deadline_minutes))),
   offer_radius_km=greatest(1,least(50,coalesce((p_data->>'offer_radius_km')::int,offer_radius_km))),
   route_grouping_enabled=coalesce((p_data->>'route_grouping_enabled')::boolean,route_grouping_enabled),multi_pickup_enabled=coalesce((p_data->>'multi_pickup_enabled')::boolean,multi_pickup_enabled),
   max_group_deliveries=greatest(1,least(10,coalesce((p_data->>'max_group_deliveries')::int,max_group_deliveries))),completion_radius_m=greatest(30,least(5000,coalesce((p_data->>'completion_radius_m')::int,completion_radius_m))),
   single_active_delivery=coalesce((p_data->>'single_active_delivery')::boolean,single_active_delivery),reoffer_delay_seconds=greatest(5,least(600,coalesce((p_data->>'reoffer_delay_seconds')::int,reoffer_delay_seconds))),
   pending_after_seconds=greatest(15,least(3600,coalesce((p_data->>'pending_after_seconds')::int,pending_after_seconds))),max_offer_rounds=greatest(1,least(50,coalesce((p_data->>'max_offer_rounds')::int,max_offer_rounds))),
   offer_sound_enabled=coalesce((p_data->>'offer_sound_enabled')::boolean,offer_sound_enabled),push_enabled=coalesce((p_data->>'push_enabled')::boolean,push_enabled),
   operation_timezone=case when coalesce(p_data->>'operation_timezone','') in ('America/Sao_Paulo','UTC') then p_data->>'operation_timezone' else operation_timezone end,updated_at=now(),updated_by=auth.uid()
   where id='default' returning * into s;
  return jsonb_build_object('ok',true,'settings',to_jsonb(s));
 end if;
 if p_action='save_type' then
  update public.vuppi_delivery_types set enabled=coalesce((p_data->>'enabled')::boolean,enabled),priority=greatest(1,least(99,coalesce((p_data->>'priority')::int,priority))),updated_at=now(),updated_by=auth.uid() where code=p_data->>'code' returning * into t;
  if t.code is null then raise exception 'UP_CAR: Tipo de entrega nao encontrado.'; end if;
  return jsonb_build_object('ok',true,'type',to_jsonb(t));
 end if;
 raise exception 'UP_CAR: Acao logistica invalida.';
end;$$;
revoke all on function public.vuppi_logistics_admin(text,jsonb) from public,anon;
grant execute on function public.vuppi_logistics_admin(text,jsonb) to authenticated;

commit;
