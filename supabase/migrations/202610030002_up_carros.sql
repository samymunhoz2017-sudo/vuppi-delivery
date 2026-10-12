-- Fase 2, incremental. REVISAR SCHEMA E CONFIRMAR DEV/HOMOLOGAÇÃO ANTES DE APLICAR.
-- Não altera dados, tabelas, funções ou políticas do Delivery Moto.
begin;
set local search_path=public,extensions;
do $$ begin
 if to_regclass('public.up_cidades') is null then raise exception 'Compare o schema atual: tabela up_cidades ausente. Não aplicar migrations antigas cegamente.'; end if;
 if to_regclass('public.up_car_rides') is not null then raise exception 'UP Carros já existe. Compare o schema antes de reaplicar.'; end if;
end $$;
create schema if not exists extensions;
create extension if not exists postgis with schema extensions;
create extension if not exists pgcrypto with schema extensions;
-- search_path cobre public/ extensions; não move extensões já instaladas.
create table up_car_city_settings (
 city_id text primary key references up_cidades(id), product text not null default 'car_ride' check(product='car_ride'),
 enabled boolean not null default false, center geography(Point,4326), radius_m integer not null default 10000 check(radius_m between 500 and 100000),
 offer_seconds integer not null default 30 check(offer_seconds between 10 and 120), wave_radius_m integer not null default 3000 check(wave_radius_m between 500 and 20000),
 max_waves integer not null default 3 check(max_waves between 1 and 5), location_max_age_s integer not null default 60 check(location_max_age_s between 15 and 120),
 cancel_after_accept boolean not null default true, cancel_grace_s integer not null default 120 check(cancel_grace_s between 0 and 3600),
 cancel_fee_cents integer not null default 0 check(cancel_fee_cents between 0 and 100000), updated_at timestamptz not null default now()
);
create table up_car_categories (
 city_id text not null references up_car_city_settings(city_id), code text not null check(code ~ '^[a-z0-9_]{1,30}$'), name text not null,
 enabled boolean not null default false, seats integer not null default 4 check(seats between 1 and 8), min_year integer not null default 2010 check(min_year between 1990 and 2100),
 base_cents integer not null default 500 check(base_cents between 0 and 100000), per_km_cents integer not null default 250 check(per_km_cents between 0 and 100000),
 per_min_cents integer not null default 30 check(per_min_cents between 0 and 100000), minimum_cents integer not null default 1200 check(minimum_cents between 0 and 100000),
 primary key(city_id,code)
);
create table up_car_staff (
 user_id uuid not null references auth.users(id), city_id text not null references up_car_city_settings(city_id),
 role text not null check(role in ('manager','operator')), active boolean not null default false, primary key(user_id,city_id)
);
create table up_car_profiles (
 user_id uuid primary key references auth.users(id), full_name text not null check(length(full_name) between 1 and 70),
 phone text not null default '' check(length(phone)<=25), safety_name text not null default '' check(length(safety_name)<=70),
 safety_phone text not null default '' check(length(safety_phone)<=25), updated_at timestamptz not null default now()
);
create table up_car_drivers (
 user_id uuid primary key references auth.users(id), city_id text not null, category text not null,
 product text not null default 'car_ride' check(product='car_ride'),
 state text not null default 'analysis' check(state in ('analysis','approved','pending','rejected','blocked')),
 reason text not null default 'Aguardando documentos e análise', online boolean not null default false,
 updated_at timestamptz not null default now(), foreign key(city_id,category) references up_car_categories(city_id,code)
);
create table up_car_vehicles (
 id uuid primary key default gen_random_uuid(), driver_id uuid not null unique references up_car_drivers(user_id),
 city_id text not null, category text not null, vehicle_type text not null default 'car' check(vehicle_type='car'),
 plate text not null check(plate ~ '^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$'), brand text not null, model text not null, color text not null,
 year integer not null check(year between 1990 and 2100), seats integer not null check(seats between 1 and 8),
 approved boolean not null default false, foreign key(city_id,category) references up_car_categories(city_id,code)
);
create table up_car_documents (
 id uuid primary key default gen_random_uuid(), driver_id uuid not null references up_car_drivers(user_id),
 kind text not null check(kind in ('cnh','crlv')), object_path text not null unique, mime text not null check(mime in ('application/pdf','image/jpeg','image/png')),
 created_at timestamptz not null default now()
);
create table up_car_quotes (
 id uuid primary key default gen_random_uuid(), passenger_id uuid not null references auth.users(id), city_id text not null, category text not null,
 product text not null default 'car_ride' check(product='car_ride'), origin_label text not null, destination_label text not null,
 origin geography(Point,4326) not null, destination geography(Point,4326) not null, distance_m integer not null check(distance_m between 1 and 500000),
 duration_s integer not null check(duration_s between 1 and 36000), polyline text not null, price_cents integer not null check(price_cents>=0),
 tariff_snapshot jsonb not null, expires_at timestamptz not null default now()+interval '5 minutes', created_at timestamptz not null default now(),
 foreign key(city_id,category) references up_car_categories(city_id,code)
);
create table up_car_rides (
 id uuid primary key default gen_random_uuid(), quote_id uuid not null unique references up_car_quotes(id),
 passenger_id uuid not null references auth.users(id), driver_id uuid references up_car_drivers(user_id), vehicle_id uuid references up_car_vehicles(id),
 city_id text not null, category text not null, product text not null default 'car_ride' check(product='car_ride'),
 status text not null default 'searching' check(status in ('searching','accepted','arrived','in_progress','completed','cancelled','no_driver')), next_dispatch_at timestamptz not null default now(),
 idempotency_key uuid not null, price_cents integer not null, tariff_snapshot jsonb not null, wave integer not null default 0,
 cancel_reason text, cancel_fee_cents integer not null default 0, payment_method text not null check(payment_method in ('cash','pix','card')),
 created_at timestamptz not null default now(), accepted_at timestamptz, started_at timestamptz, ended_at timestamptz,
 unique(passenger_id,idempotency_key), foreign key(city_id,category) references up_car_categories(city_id,code)
);
create unique index up_car_one_active_driver on up_car_rides(driver_id) where driver_id is not null and status in ('accepted','arrived','in_progress');
create unique index up_car_one_active_passenger on up_car_rides(passenger_id) where status in ('searching','accepted','arrived','in_progress');
create index up_car_ops_filter on up_car_rides(city_id,created_at desc,status);
create table up_car_offers (
 id uuid primary key default gen_random_uuid(), ride_id uuid not null references up_car_rides(id), driver_id uuid not null references up_car_drivers(user_id),
 wave integer not null, eta_s integer not null check(eta_s>0), expires_at timestamptz not null,
 state text not null default 'offered' check(state in ('offered','accepted','expired','closed')), unique(ride_id,driver_id,wave)
);
create index up_car_offer_inbox on up_car_offers(driver_id,expires_at) where state='offered';
create table up_car_locations (
 driver_id uuid primary key references up_car_drivers(user_id), position geography(Point,4326) not null,
 accuracy_m numeric not null check(accuracy_m between 0 and 100), reported_at timestamptz not null, updated_at timestamptz not null default now()
);
create index up_car_locations_geo on up_car_locations using gist(position);
create table up_car_start_secrets (
 ride_id uuid primary key references up_car_rides(id), pin_hash text, attempts integer not null default 0,
 blocked_until timestamptz, changed_at timestamptz not null default now()
);
create table up_car_ratings (
 ride_id uuid primary key references up_car_rides(id), passenger_id uuid not null references auth.users(id),
 score integer not null check(score between 1 and 5), comment text not null default '' check(length(comment)<=500), created_at timestamptz not null default now()
);
create table up_car_events (
 id bigint generated always as identity primary key, ride_id uuid references up_car_rides(id), city_id text not null,
 actor_id uuid references auth.users(id), event text not null, details jsonb not null default '{}', created_at timestamptz not null default now()
);
create index up_car_events_ride on up_car_events(ride_id,created_at);

create function up_car_is_staff(p_city text,p_manage boolean default false) returns boolean
language sql stable security definer set search_path=public,extensions as $$
 select exists(select 1 from up_car_staff where user_id=auth.uid() and city_id=p_city and active and (not p_manage or role='manager'));
$$;
create function up_car_can_read(p_ride uuid) returns boolean
language sql stable security definer set search_path=public,extensions as $$
 select exists(select 1 from up_car_rides r where r.id=p_ride and (r.passenger_id=auth.uid() or r.driver_id=auth.uid() or up_car_is_staff(r.city_id)
 or exists(select 1 from up_car_offers o where o.ride_id=r.id and o.driver_id=auth.uid() and o.state='offered' and o.expires_at>now())));
$$;
create function up_car_event(p_ride uuid,p_city text,p_event text,p_details jsonb default '{}') returns void
language plpgsql security definer set search_path=public,extensions as $$ begin
 insert into up_car_events(ride_id,city_id,actor_id,event,details) values(p_ride,p_city,auth.uid(),p_event,p_details);
 if p_ride is not null then perform realtime.send(jsonb_build_object('ride_id',p_ride,'changed',p_event),'change','car_ride:'||p_ride::text,true); end if;
 perform realtime.send(jsonb_build_object('ride_id',p_ride,'changed',p_event),'change','car_ops:'||p_city,true);
end $$;
create function up_car_can_topic(p_topic text) returns boolean
language plpgsql stable security definer set search_path=public,extensions as $$ begin
 if auth.uid() is null then return false; end if;
 if p_topic like 'car_ride:%' then return up_car_can_read(substring(p_topic from 10)::uuid); end if;
 if p_topic like 'car_driver:%' then return substring(p_topic from 12)=auth.uid()::text and exists(select 1 from up_car_drivers where user_id=auth.uid() and state='approved'); end if;
 if p_topic like 'car_ops:%' then return up_car_is_staff(substring(p_topic from 9)); end if;
 return false;
exception when invalid_text_representation then return false; end $$;

do $$ declare t text; begin
 foreach t in array array['up_car_city_settings','up_car_categories','up_car_staff','up_car_profiles','up_car_drivers','up_car_vehicles','up_car_documents','up_car_quotes','up_car_rides','up_car_offers','up_car_locations','up_car_start_secrets','up_car_ratings','up_car_events'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from anon,authenticated',t);
 end loop;
end $$;
grant select on up_car_city_settings,up_car_categories,up_car_staff,up_car_profiles,up_car_drivers,up_car_vehicles,up_car_documents,up_car_quotes,up_car_rides,up_car_offers,up_car_locations,up_car_ratings,up_car_events to authenticated;
create policy car_city_read on up_car_city_settings for select to authenticated using(enabled or up_car_is_staff(city_id) or exists(select 1 from up_car_drivers d where d.user_id=auth.uid() and d.city_id=up_car_city_settings.city_id));
create policy car_category_read on up_car_categories for select to authenticated using(exists(select 1 from up_car_city_settings s where s.city_id=up_car_categories.city_id and s.enabled) or up_car_is_staff(city_id));
create policy car_staff_self on up_car_staff for select to authenticated using(user_id=auth.uid());
create policy car_profile_self on up_car_profiles for select to authenticated using(user_id=auth.uid());
create policy car_driver_read on up_car_drivers for select to authenticated using(user_id=auth.uid() or up_car_is_staff(city_id));
create policy car_vehicle_read on up_car_vehicles for select to authenticated using(driver_id=auth.uid() or up_car_is_staff(city_id));
create policy car_document_read on up_car_documents for select to authenticated using(driver_id=auth.uid() or exists(select 1 from up_car_drivers d where d.user_id=driver_id and up_car_is_staff(d.city_id)));
create policy car_quote_self on up_car_quotes for select to authenticated using(passenger_id=auth.uid());
create policy car_ride_read on up_car_rides for select to authenticated using(up_car_can_read(id));
create policy car_offer_read on up_car_offers for select to authenticated using(driver_id=auth.uid() or exists(select 1 from up_car_rides r where r.id=ride_id and up_car_is_staff(r.city_id)));
create policy car_location_read on up_car_locations for select to authenticated using(driver_id=auth.uid() or (updated_at>now()-interval '120 seconds' and exists(select 1 from up_car_drivers d where d.user_id=driver_id and up_car_is_staff(d.city_id))) or (updated_at>now()-interval '120 seconds' and exists(select 1 from up_car_rides r where r.driver_id=up_car_locations.driver_id and r.passenger_id=auth.uid() and r.status in ('accepted','arrived','in_progress'))));
create policy car_rating_read on up_car_ratings for select to authenticated using(passenger_id=auth.uid() or up_car_can_read(ride_id));
create policy car_event_read on up_car_events for select to authenticated using(up_car_is_staff(city_id) or (ride_id is not null and up_car_can_read(ride_id)));
-- Secret de início: sem SELECT, INSERT ou UPDATE por clientes; somente funções.

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('up-car-documents','up-car-documents',false,5242880,array['application/pdf','image/jpeg','image/png']) on conflict(id) do nothing;
create policy car_document_upload on storage.objects for insert to authenticated with check(bucket_id='up-car-documents' and (storage.foldername(name))[1]=auth.uid()::text and exists(select 1 from up_car_drivers d where d.user_id=auth.uid()));
create policy car_document_download on storage.objects for select to authenticated using(bucket_id='up-car-documents' and ((storage.foldername(name))[1]=auth.uid()::text or exists(select 1 from up_car_documents doc join up_car_drivers d on d.user_id=doc.driver_id where doc.object_path=name and up_car_is_staff(d.city_id))));
-- Políticas restritivas só para o novo bucket/tópicos: políticas amplas existentes não liberam Carros.
create policy car_document_isolation on storage.objects as restrictive for all to public using(bucket_id<>'up-car-documents' or ((storage.foldername(name))[1]=auth.uid()::text or exists(select 1 from up_car_documents doc join up_car_drivers d on d.user_id=doc.driver_id where doc.object_path=name and up_car_is_staff(d.city_id)))) with check(bucket_id<>'up-car-documents' or (storage.foldername(name))[1]=auth.uid()::text);
create policy car_realtime_read on realtime.messages for select to authenticated using(up_car_can_topic(realtime.topic()));
create policy car_realtime_isolation on realtime.messages as restrictive for select to public using(realtime.topic() not like 'car_%' or up_car_can_topic(realtime.topic()));
create policy car_realtime_no_client_publish on realtime.messages as restrictive for insert to public with check(realtime.topic() not like 'car_%');

create function up_car_quote_for(p_user uuid,p_city text,p_category text,p_route jsonb) returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare c up_car_categories; s up_car_city_settings; q up_car_quotes; a geography; b geography; distance integer; duration integer; price integer; snapshot jsonb;
begin
 if auth.role()<>'service_role' then raise exception 'UP_CAR: Somente o servidor pode registrar a estimativa.'; end if;
 select * into s from up_car_city_settings where city_id=p_city and enabled;
 select * into c from up_car_categories where city_id=p_city and code=p_category and enabled;
 if s.city_id is null or c.code is null or s.center is null then raise exception 'UP_CAR: Serviço ou categoria indisponível na cidade.'; end if;
 a:=st_setsrid(st_makepoint((p_route->>'origin_lng')::numeric,(p_route->>'origin_lat')::numeric),4326)::geography;
 b:=st_setsrid(st_makepoint((p_route->>'destination_lng')::numeric,(p_route->>'destination_lat')::numeric),4326)::geography;
 if not st_dwithin(a,s.center,s.radius_m) or not st_dwithin(b,s.center,s.radius_m) then raise exception 'UP_CAR: Percurso fora da área atendida.'; end if;
 distance:=(p_route->>'distance_m')::integer; duration:=(p_route->>'duration_s')::integer;
 if distance not between 1 and 500000 or duration not between 1 and 36000 or length(coalesce(p_route->>'polyline','')) not between 1 and 30000 then raise exception 'UP_CAR: Rota inválida.'; end if;
 price:=greatest(c.minimum_cents,round(c.base_cents+distance::numeric/1000*c.per_km_cents+duration::numeric/60*c.per_min_cents)::integer);
 snapshot:=jsonb_build_object('base_cents',c.base_cents,'per_km_cents',c.per_km_cents,'per_min_cents',c.per_min_cents,'minimum_cents',c.minimum_cents,'cancel_after_accept',s.cancel_after_accept,'cancel_grace_s',s.cancel_grace_s,'cancel_fee_cents',s.cancel_fee_cents);
 insert into up_car_quotes(passenger_id,city_id,category,origin_label,destination_label,origin,destination,distance_m,duration_s,polyline,price_cents,tariff_snapshot)
 values(p_user,p_city,p_category,left(p_route->>'origin_label',180),left(p_route->>'destination_label',180),a,b,distance,duration,p_route->>'polyline',price,snapshot) returning * into q;
 return jsonb_build_object('id',q.id,'price_cents',q.price_cents,'distance_m',distance,'duration_s',duration,'expires_at',q.expires_at,'polyline',q.polyline);
end $$;

create function up_car_dispatch(p_ride uuid,p_candidates jsonb default null) returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare r up_car_rides; s up_car_city_settings; q up_car_quotes; item jsonb; n integer:=0;
begin
 if auth.role()<>'service_role' then raise exception 'UP_CAR: Despacho restrito ao servidor.'; end if;
 select * into r from up_car_rides where id=p_ride for update;
 if r.id is null or r.status<>'searching' then return jsonb_build_object('candidates','[]'::jsonb); end if;
 select * into s from up_car_city_settings where city_id=r.city_id and enabled;
 select * into q from up_car_quotes where id=r.quote_id;
 if s.city_id is null then return jsonb_build_object('candidates','[]'::jsonb); end if;
 update up_car_offers set state='expired' where ride_id=r.id and state='offered' and expires_at<=now();
 if p_candidates is null then
  if exists(select 1 from up_car_offers where ride_id=r.id and state='offered' and expires_at>now()) then return jsonb_build_object('candidates','[]'::jsonb); end if;
  if r.next_dispatch_at>now() then return jsonb_build_object('candidates','[]'::jsonb); end if;
  if r.wave>=s.max_waves then update up_car_rides set status='no_driver',ended_at=now() where id=r.id; perform up_car_event(r.id,r.city_id,'no_driver'); return jsonb_build_object('candidates','[]'::jsonb); end if;
  update up_car_rides set wave=wave+1,next_dispatch_at=now()+make_interval(secs=>s.offer_seconds) where id=r.id returning * into r;
  return jsonb_build_object('wave',r.wave,'origin_lat',st_y(q.origin::geometry),'origin_lng',st_x(q.origin::geometry),'candidates',coalesce((select jsonb_agg(x) from (
   select d.user_id as driver_id,st_y(l.position::geometry) as lat,st_x(l.position::geometry) as lng
   from up_car_drivers d join up_car_vehicles v on v.driver_id=d.user_id join up_car_locations l on l.driver_id=d.user_id
   where d.city_id=r.city_id and d.category=r.category and d.product='car_ride' and d.state='approved' and d.online
   and v.vehicle_type='car' and v.approved and v.city_id=r.city_id and v.category=r.category
   and l.updated_at>now()-make_interval(secs=>s.location_max_age_s) and st_dwithin(l.position,q.origin,s.wave_radius_m*r.wave)
   and not exists(select 1 from up_car_rides active where active.driver_id=d.user_id and active.status in ('accepted','arrived','in_progress'))
   order by st_distance(l.position,q.origin) limit 6) x),'[]'::jsonb));
 end if;
 for item in select * from jsonb_array_elements(p_candidates) loop
  if (item->>'wave')::integer<>r.wave then continue; end if;
  if exists(select 1 from up_car_drivers d join up_car_vehicles v on v.driver_id=d.user_id join up_car_locations l on l.driver_id=d.user_id where d.user_id=(item->>'driver_id')::uuid and d.state='approved' and d.online and d.product='car_ride' and d.city_id=r.city_id and d.category=r.category and v.approved and v.vehicle_type='car' and v.city_id=r.city_id and v.category=r.category and l.updated_at>now()-make_interval(secs=>s.location_max_age_s) and st_dwithin(l.position,q.origin,s.wave_radius_m*r.wave) and not exists(select 1 from up_car_rides active where active.driver_id=d.user_id and active.status in ('accepted','arrived','in_progress'))) then
   insert into up_car_offers(ride_id,driver_id,wave,eta_s,expires_at) values(r.id,(item->>'driver_id')::uuid,r.wave,greatest(1,(item->>'eta_s')::integer),now()+make_interval(secs=>s.offer_seconds)) on conflict(ride_id,driver_id,wave) do nothing;
   perform realtime.send(jsonb_build_object('ride_id',r.id,'changed','offer'),'change','car_driver:'||(item->>'driver_id'),true); n:=n+1;
  end if;
 end loop;
 perform up_car_event(r.id,r.city_id,'offered',jsonb_build_object('wave',r.wave,'count',n)); return jsonb_build_object('offered',n);
end $$;

create function up_car_command(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare uid uuid:=auth.uid(); r up_car_rides; q up_car_quotes; d up_car_drivers; v up_car_vehicles; s up_car_city_settings;
 o up_car_offers; secret up_car_start_secrets; city text; code text; reason text; result jsonb; pos geography; rating integer;
begin
 if uid is null then raise exception 'UP_CAR: Autenticação necessária.'; end if;
 if (p_data ? 'product' and p_data->>'product'<>'car_ride') or (p_data ? 'vehicle_type' and p_data->>'vehicle_type'<>'car') then raise exception 'UP_CAR: Produto ou veículo incompatível.'; end if;
 if p_action='bootstrap' then
  return jsonb_build_object('profile',(select to_jsonb(x) from up_car_profiles x where user_id=uid),'driver',(select to_jsonb(x) from up_car_drivers x where user_id=uid),'vehicle',(select to_jsonb(x) from up_car_vehicles x where driver_id=uid),'documents',coalesce((select jsonb_agg(to_jsonb(x)) from up_car_documents x where driver_id=uid),'[]'::jsonb),'staff',coalesce((select jsonb_agg(to_jsonb(x)) from up_car_staff x where user_id=uid and active),'[]'::jsonb),'cities',coalesce((select jsonb_agg(jsonb_build_object('city_id',x.city_id,'enabled',x.enabled,'name',c.nome)) from up_car_city_settings x join up_cidades c on c.id=x.city_id where x.enabled or up_car_is_staff(x.city_id) or exists(select 1 from up_car_drivers dd where dd.user_id=uid and dd.city_id=x.city_id)),'[]'::jsonb),'categories',coalesce((select jsonb_agg(to_jsonb(x)) from up_car_categories x join up_car_city_settings cs on cs.city_id=x.city_id where cs.enabled and x.enabled or up_car_is_staff(x.city_id)),'[]'::jsonb));
 end if;
 if p_action='profile' then
  if length(trim(p_data->>'full_name')) not between 1 and 70 then raise exception 'UP_CAR: Nome inválido.'; end if;
  insert into up_car_profiles(user_id,full_name,phone,safety_name,safety_phone) values(uid,trim(p_data->>'full_name'),coalesce(p_data->>'phone',''),coalesce(p_data->>'safety_name',''),coalesce(p_data->>'safety_phone','')) on conflict(user_id) do update set full_name=excluded.full_name,phone=excluded.phone,safety_name=excluded.safety_name,safety_phone=excluded.safety_phone,updated_at=now(); return jsonb_build_object('saved',true);
 end if;
 if p_action='driver_register' then
  city:=p_data->>'city_id';
  if exists(select 1 from up_car_rides where driver_id=uid and status in ('accepted','arrived','in_progress')) then raise exception 'UP_CAR: Termine o atendimento antes de alterar o cadastro.'; end if;
  if not exists(select 1 from up_car_profiles where user_id=uid) then raise exception 'UP_CAR: Complete o perfil primeiro.'; end if;
  if not exists(select 1 from up_car_categories c join up_car_city_settings cs on cs.city_id=c.city_id where c.city_id=city and c.code=p_data->>'category' and c.enabled and cs.enabled and (p_data->>'year')::integer>=c.min_year and (p_data->>'seats')::integer>=c.seats) then raise exception 'UP_CAR: Cidade, categoria ou automóvel incompatível.'; end if;
  select * into d from up_car_drivers where user_id=uid for update;
  if d.state='blocked' then raise exception 'UP_CAR: Cadastro bloqueado. Procure a central.'; end if;
  insert into up_car_drivers(user_id,city_id,category) values(uid,city,p_data->>'category') on conflict(user_id) do update set city_id=excluded.city_id,category=excluded.category,state='analysis',reason='Cadastro alterado; aguardando revisão',online=false,updated_at=now();
  insert into up_car_vehicles(driver_id,city_id,category,plate,brand,model,color,year,seats) values(uid,city,p_data->>'category',upper(replace(p_data->>'plate','-','')),p_data->>'brand',p_data->>'model',p_data->>'color',(p_data->>'year')::integer,(p_data->>'seats')::integer) on conflict(driver_id) do update set city_id=excluded.city_id,category=excluded.category,plate=excluded.plate,brand=excluded.brand,model=excluded.model,color=excluded.color,year=excluded.year,seats=excluded.seats,approved=false;
  delete from up_car_locations where driver_id=uid; perform up_car_event(null,city,'driver_registration',jsonb_build_object('driver_id',uid)); return jsonb_build_object('state','analysis');
 end if;
 if p_action='document' then
  select * into d from up_car_drivers where user_id=uid for update;
  if d.user_id is null or d.state='blocked' or exists(select 1 from up_car_rides where driver_id=uid and status in ('accepted','arrived','in_progress')) then raise exception 'UP_CAR: Cadastro indisponível para alteração de documentos.'; end if;
  if split_part(p_data->>'object_path','/',1)<>uid::text or not exists(select 1 from storage.objects where bucket_id='up-car-documents' and name=p_data->>'object_path') then raise exception 'UP_CAR: Documento não encontrado no armazenamento privado.'; end if;
  insert into up_car_documents(driver_id,kind,object_path,mime) values(uid,p_data->>'kind',p_data->>'object_path',p_data->>'mime');
  update up_car_drivers set state='analysis',online=false,reason='Novo documento; aguardando revisão' where user_id=uid; update up_car_vehicles set approved=false where driver_id=uid; delete from up_car_locations where driver_id=uid;
  perform up_car_event(null,d.city_id,'document_uploaded',jsonb_build_object('driver_id',uid,'kind',p_data->>'kind')); return jsonb_build_object('saved',true);
 end if;
 if p_action in ('availability','location') then
  select * into d from up_car_drivers where user_id=uid for update;
  select * into s from up_car_city_settings where city_id=d.city_id;
  select * into v from up_car_vehicles where driver_id=uid;
  if p_action='availability' and coalesce((p_data->>'online')::boolean,true)=false then
   if exists(select 1 from up_car_rides where driver_id=uid and status in ('accepted','arrived','in_progress')) then raise exception 'UP_CAR: Termine ou resolva a corrida antes de ficar offline.'; end if;
   update up_car_drivers set online=false where user_id=uid;
   delete from up_car_locations where driver_id=uid;
   return jsonb_build_object('online',false);
  end if;
  if d.state<>'approved' or not v.approved or v.vehicle_type<>'car' or not s.enabled or not exists(select 1 from up_car_categories where city_id=d.city_id and code=d.category and enabled) then raise exception 'UP_CAR: Apenas motorista de carro aprovado e apto pode ficar disponível.'; end if;
  if p_action='availability' then
   if not (p_data->>'online')::boolean and exists(select 1 from up_car_rides where driver_id=uid and status in ('accepted','arrived','in_progress')) then raise exception 'UP_CAR: Termine ou resolva a corrida antes de ficar offline.'; end if;
   update up_car_drivers set online=(p_data->>'online')::boolean where user_id=uid;
   if not (p_data->>'online')::boolean then delete from up_car_locations where driver_id=uid; end if;
   return jsonb_build_object('online',(p_data->>'online')::boolean);
  end if;
  if not d.online or coalesce((p_data->>'consent')::boolean,false)=false or abs(extract(epoch from now()-(p_data->>'reported_at')::timestamptz))>30 then raise exception 'UP_CAR: Localização sem permissão, desatualizada ou fora da disponibilidade.'; end if;
  if (p_data->>'lat')::numeric not between -90 and 90 or (p_data->>'lng')::numeric not between -180 and 180 then raise exception 'UP_CAR: Coordenadas inválidas.'; end if;
  pos:=st_setsrid(st_makepoint((p_data->>'lng')::numeric,(p_data->>'lat')::numeric),4326)::geography;
  if not st_dwithin(pos,s.center,s.radius_m) then raise exception 'UP_CAR: Fora da área de atendimento.'; end if;
  insert into up_car_locations(driver_id,position,accuracy_m,reported_at) values(uid,pos,(p_data->>'accuracy_m')::numeric,(p_data->>'reported_at')::timestamptz) on conflict(driver_id) do update set position=excluded.position,accuracy_m=excluded.accuracy_m,reported_at=excluded.reported_at,updated_at=now();
  for r in select * from up_car_rides where driver_id=uid and status in ('accepted','arrived','in_progress') loop perform realtime.send(jsonb_build_object('ride_id',r.id,'changed','location'),'change','car_ride:'||r.id,true); end loop;
  perform realtime.send(jsonb_build_object('driver_id',uid,'changed','location'),'change','car_ops:'||d.city_id,true); return jsonb_build_object('updated',true);
 end if;
 if p_action='request' then
  select * into r from up_car_rides where passenger_id=uid and idempotency_key=(p_data->>'idempotency_key')::uuid;
  if r.id is not null then return jsonb_build_object('id',r.id,'status',r.status,'price_cents',r.price_cents); end if;
  select * into q from up_car_quotes where id=(p_data->>'quote_id')::uuid and passenger_id=uid and expires_at>now() for update;
  if q.id is null then raise exception 'UP_CAR: Estimativa ausente ou expirada.'; end if;
  select * into r from up_car_rides where passenger_id=uid and idempotency_key=(p_data->>'idempotency_key')::uuid;
  if r.id is not null then return jsonb_build_object('id',r.id,'status',r.status,'price_cents',r.price_cents); end if;
  if not exists(select 1 from up_car_city_settings where city_id=q.city_id and enabled) or not exists(select 1 from up_car_categories where city_id=q.city_id and code=q.category and enabled) then raise exception 'UP_CAR: Serviço indisponível.'; end if;
  if not exists(select 1 from up_car_profiles where user_id=uid) then raise exception 'UP_CAR: Complete seu perfil.'; end if;
  insert into up_car_rides(quote_id,passenger_id,city_id,category,idempotency_key,price_cents,tariff_snapshot,payment_method) values(q.id,uid,q.city_id,q.category,(p_data->>'idempotency_key')::uuid,q.price_cents,q.tariff_snapshot,p_data->>'payment_method') returning * into r;
  insert into up_car_start_secrets(ride_id) values(r.id); perform up_car_event(r.id,r.city_id,'requested'); return jsonb_build_object('id',r.id,'status',r.status,'price_cents',r.price_cents);
 end if;
 if p_action='offers' then
  return coalesce((select jsonb_agg(jsonb_build_object('offer_id',o.id,'ride_id',r.id,'expires_at',o.expires_at,'eta_s',o.eta_s,'origin',q.origin_label,'destination',q.destination_label,'distance_m',q.distance_m,'price_cents',r.price_cents)) from up_car_offers o join up_car_rides r on r.id=o.ride_id join up_car_quotes q on q.id=r.quote_id join up_car_drivers dd on dd.user_id=o.driver_id where o.driver_id=uid and dd.state='approved' and dd.online and o.state='offered' and o.expires_at>now() and r.status='searching' and r.product='car_ride'),'[]'::jsonb);
 end if;
 if p_action='accept' then
  select * into d from up_car_drivers where user_id=uid for update;
  select * into o from up_car_offers where id=(p_data->>'offer_id')::uuid and driver_id=uid;
  select * into r from up_car_rides where id=o.ride_id for update;
  select * into o from up_car_offers where id=(p_data->>'offer_id')::uuid and driver_id=uid for update;
  select * into s from up_car_city_settings where city_id=r.city_id;
  select * into v from up_car_vehicles where driver_id=uid;
  if o.state='accepted' and r.driver_id=uid then return jsonb_build_object('id',r.id,'status',r.status); end if;
  if d.user_id is null or d.state<>'approved' or not d.online or o.id is null or o.state<>'offered' or o.expires_at<=now() or r.status<>'searching' or r.product<>'car_ride' or not s.enabled or d.city_id<>r.city_id or d.category<>r.category or v.id is null or not v.approved or v.vehicle_type<>'car' or v.city_id<>r.city_id or v.category<>r.category then raise exception 'UP_CAR: Oferta expirada, já aceita ou parceiro incompatível.'; end if;
  if not exists(select 1 from up_car_locations where driver_id=uid and updated_at>now()-make_interval(secs=>s.location_max_age_s)) or exists(select 1 from up_car_rides where driver_id=uid and status in ('accepted','arrived','in_progress')) then raise exception 'UP_CAR: Localização desatualizada ou motorista ocupado.'; end if;
  if not exists(select 1 from up_car_categories where city_id=r.city_id and code=r.category and enabled and v.year>=min_year and v.seats>=seats) then raise exception 'UP_CAR: Categoria ou automóvel incompatível.'; end if;
  update up_car_rides set driver_id=uid,vehicle_id=v.id,status='accepted',accepted_at=now() where id=r.id;
  update up_car_offers set state=case when id=o.id then 'accepted' else 'closed' end where ride_id=r.id and state='offered'; perform up_car_event(r.id,r.city_id,'accepted'); return jsonb_build_object('id',r.id,'status','accepted');
 end if;
 if p_action in ('ride','pin','arrive','start','complete','cancel','reoffer','rate','incident') then
  select * into r from up_car_rides where id=(p_data->>'ride_id')::uuid for update;
  if r.id is null or not up_car_can_read(r.id) then raise exception 'UP_CAR: Corrida não autorizada.'; end if;
  select * into q from up_car_quotes where id=r.quote_id;
  if p_action='ride' then
   select to_jsonb(r)||jsonb_build_object('origin',q.origin_label,'destination',q.destination_label,'origin_lat',st_y(q.origin::geometry),'origin_lng',st_x(q.origin::geometry),'destination_lat',st_y(q.destination::geometry),'destination_lng',st_x(q.destination::geometry),'distance_m',q.distance_m,'duration_s',q.duration_s,'polyline',q.polyline,'vehicle',case when r.driver_id is not null then (select jsonb_build_object('plate',vv.plate,'brand',vv.brand,'model',vv.model,'color',vv.color) from up_car_vehicles vv where id=r.vehicle_id) else null end,'driver_name',case when r.driver_id is not null then (select full_name from up_car_profiles where user_id=r.driver_id) else null end,'passenger_name',case when uid=r.driver_id or up_car_is_staff(r.city_id) then (select full_name from up_car_profiles where user_id=r.passenger_id) else null end,'location',case when r.status in ('accepted','arrived','in_progress') and (uid=r.passenger_id or uid=r.driver_id or up_car_is_staff(r.city_id)) then (select jsonb_build_object('lat',st_y(l.position::geometry),'lng',st_x(l.position::geometry),'updated_at',l.updated_at) from up_car_locations l where driver_id=r.driver_id and updated_at>now()-interval '120 seconds') else null end,'rating',(select score from up_car_ratings where ride_id=r.id),'events',coalesce((select jsonb_agg(jsonb_build_object('event',e.event,'created_at',e.created_at,'details',e.details) order by e.created_at) from up_car_events e where ride_id=r.id),'[]'::jsonb)) into result; return result;
  end if;
  if p_action='pin' then
   if uid<>r.passenger_id or r.status not in ('accepted','arrived') then raise exception 'UP_CAR: Código disponível apenas ao passageiro após o aceite.'; end if;
   select * into secret from up_car_start_secrets where ride_id=r.id for update;
   if secret.blocked_until>now() then raise exception 'UP_CAR: Aguarde antes de gerar outro código.'; end if;
   code:=lpad(((('x'||encode(gen_random_bytes(4),'hex'))::bit(32)::bigint)%1000000)::text,6,'0');
   update up_car_start_secrets set pin_hash=crypt(code,gen_salt('bf')),attempts=0,changed_at=now() where ride_id=r.id; return jsonb_build_object('code',code);
  end if;
  if p_action in ('arrive','start','complete') then
   if uid<>r.driver_id then raise exception 'UP_CAR: Apenas o motorista atribuído pode executar esta ação.'; end if;
   if p_action='arrive' and r.status='accepted' then update up_car_rides set status='arrived' where id=r.id;
   elsif p_action='start' and r.status='arrived' then
    select * into secret from up_car_start_secrets where ride_id=r.id for update;
    if secret.blocked_until>now() then return jsonb_build_object('error','Aguarde cinco minutos antes de tentar novamente.'); end if;
    if secret.pin_hash is null or length(coalesce(p_data->>'code',''))<>6 or crypt(p_data->>'code',secret.pin_hash)<>secret.pin_hash then
     update up_car_start_secrets set attempts=attempts+1,blocked_until=case when attempts+1>=5 then now()+interval '5 minutes' else null end where ride_id=r.id;
     perform up_car_event(r.id,r.city_id,'invalid_start_code'); return jsonb_build_object('error','Código de início incorreto.');
    end if;
    update up_car_rides set status='in_progress',started_at=now() where id=r.id; update up_car_start_secrets set pin_hash=null where ride_id=r.id;
   elsif p_action='complete' and r.status='in_progress' then update up_car_rides set status='completed',ended_at=now() where id=r.id;
   else raise exception 'UP_CAR: Transição de estado inválida.'; end if;
   perform up_car_event(r.id,r.city_id,p_action); return jsonb_build_object('updated',true);
  end if;
  if p_action in ('cancel','reoffer','incident') then
   reason:=trim(p_data->>'reason'); if length(reason) not between 3 and 200 then raise exception 'UP_CAR: Informe o motivo.'; end if;
   if p_action='cancel' then
    if r.status in ('completed','cancelled','no_driver') then raise exception 'UP_CAR: Corrida já encerrada.'; end if;
    if not up_car_is_staff(r.city_id) then
     if (uid<>r.passenger_id and (r.driver_id is null or uid<>r.driver_id)) or r.status='in_progress' then raise exception 'UP_CAR: Cancelamento não autorizado.'; end if;
     if uid=r.passenger_id and r.status<>'searching' and not (r.tariff_snapshot->>'cancel_after_accept')::boolean then raise exception 'UP_CAR: Cancelamento após aceite requer atendimento da central.'; end if;
    end if;
    update up_car_rides set status='cancelled',cancel_reason=reason,ended_at=now(),cancel_fee_cents=case when uid=r.passenger_id and accepted_at is not null and now()>accepted_at+make_interval(secs=>(tariff_snapshot->>'cancel_grace_s')::integer) then (tariff_snapshot->>'cancel_fee_cents')::integer else 0 end where id=r.id;
    update up_car_offers set state='closed' where ride_id=r.id and state='offered'; update up_car_start_secrets set pin_hash=null where ride_id=r.id;
   elsif p_action='reoffer' then
    if not up_car_is_staff(r.city_id) or r.status not in ('searching','accepted','arrived','no_driver') then raise exception 'UP_CAR: Reoferta não autorizada.'; end if;
    update up_car_rides set status='searching',driver_id=null,vehicle_id=null,wave=0,accepted_at=null,ended_at=null,next_dispatch_at=now() where id=r.id; update up_car_offers set state='closed' where ride_id=r.id; update up_car_start_secrets set pin_hash=null where ride_id=r.id;
   elsif not up_car_is_staff(r.city_id) then raise exception 'UP_CAR: Ocorrência não autorizada.'; end if;
   perform up_car_event(r.id,r.city_id,p_action,jsonb_build_object('reason',reason)); return jsonb_build_object('updated',true);
  end if;
  if p_action='rate' then
   if uid<>r.passenger_id or r.status<>'completed' then raise exception 'UP_CAR: Avaliação disponível apenas ao passageiro após conclusão.'; end if;
   insert into up_car_ratings(ride_id,passenger_id,score,comment) values(r.id,uid,(p_data->>'score')::integer,left(coalesce(p_data->>'comment',''),500)) on conflict(ride_id) do update set score=excluded.score,comment=excluded.comment; return jsonb_build_object('saved',true);
  end if;
 end if;
 if p_action='history' then
  return coalesce((select jsonb_agg(to_jsonb(x)) from (select r.*,q.origin_label as origin,q.destination_label as destination from up_car_rides r join up_car_quotes q on q.id=r.quote_id where r.passenger_id=uid or r.driver_id=uid order by r.created_at desc limit 100) x),'[]'::jsonb);
 end if;
 if p_action in ('ops','drivers','settings','configure','driver_decision') then
  city:=p_data->>'city_id'; if not up_car_is_staff(city,p_action in ('configure','driver_decision')) then raise exception 'UP_CAR: Permissão de Carros necessária para esta cidade.'; end if;
  if p_action='ops' then
   return coalesce((select jsonb_agg(to_jsonb(x)) from (select r.*,q.origin_label as origin,q.destination_label as destination from up_car_rides r join up_car_quotes q on q.id=r.quote_id where r.city_id=city and (coalesce(p_data->>'status','')='' or r.status=p_data->>'status') and (coalesce(p_data->>'driver_id','')='' or r.driver_id=(p_data->>'driver_id')::uuid) and r.created_at>=coalesce(nullif(p_data->>'from','')::timestamptz,now()-interval '30 days') and r.created_at<=coalesce(nullif(p_data->>'to','')::timestamptz,now()) order by r.created_at desc limit 300) x),'[]'::jsonb);
  end if;
  if p_action='drivers' then
   return coalesce((select jsonb_agg(to_jsonb(d)||jsonb_build_object('profile',(select jsonb_build_object('full_name',full_name,'phone',phone) from up_car_profiles where user_id=d.user_id),'vehicle',(select to_jsonb(v) from up_car_vehicles v where driver_id=d.user_id),'documents',coalesce((select jsonb_agg(to_jsonb(doc)) from up_car_documents doc where driver_id=d.user_id),'[]'::jsonb),'location',case when d.online then (select jsonb_build_object('lat',st_y(position::geometry),'lng',st_x(position::geometry)) from up_car_locations where driver_id=d.user_id and updated_at>now()-interval '120 seconds') else null end)) from up_car_drivers d where city_id=city),'[]'::jsonb);
  end if;
  if p_action='driver_decision' then
   reason:=trim(p_data->>'reason'); if length(reason) not between 3 and 200 or p_data->>'state' not in ('analysis','approved','pending','rejected','blocked') then raise exception 'UP_CAR: Situação ou motivo inválido.'; end if;
   select * into d from up_car_drivers where user_id=(p_data->>'driver_id')::uuid and city_id=city for update;
   if d.user_id is null or exists(select 1 from up_car_rides where driver_id=d.user_id and status in ('accepted','arrived','in_progress')) then raise exception 'UP_CAR: Motorista não encontrado ou em atendimento.'; end if;
   select * into v from up_car_vehicles where driver_id=d.user_id;
   if p_data->>'state'='approved' and (not exists(select 1 from up_car_documents where driver_id=d.user_id and kind='cnh') or not exists(select 1 from up_car_documents where driver_id=d.user_id and kind='crlv') or not exists(select 1 from up_car_categories c where c.city_id=city and c.code=d.category and v.year>=c.min_year and v.seats>=c.seats and v.vehicle_type='car')) then raise exception 'UP_CAR: Documentos ou automóvel incompletos/incompatíveis.'; end if;
   update up_car_drivers set state=p_data->>'state',reason=reason,online=false,updated_at=now() where user_id=d.user_id; update up_car_vehicles set approved=(p_data->>'state'='approved') where driver_id=d.user_id; delete from up_car_locations where driver_id=d.user_id;
   perform up_car_event(null,city,'driver_decision',jsonb_build_object('driver_id',d.user_id,'state',p_data->>'state','reason',reason)); return jsonb_build_object('saved',true);
  end if;
  if p_action='settings' then return jsonb_build_object('settings',(select to_jsonb(s)||jsonb_build_object('center_lat',st_y(center::geometry),'center_lng',st_x(center::geometry)) from up_car_city_settings s where city_id=city),'categories',coalesce((select jsonb_agg(to_jsonb(c)) from up_car_categories c where city_id=city),'[]'::jsonb)); end if;
  if p_action='configure' then
   reason:=trim(p_data->>'reason'); if length(reason) not between 3 and 200 then raise exception 'UP_CAR: Informe o motivo da alteração.'; end if;
   if (p_data->>'center_lat')::numeric not between -90 and 90 or (p_data->>'center_lng')::numeric not between -180 and 180 then raise exception 'UP_CAR: Coordenadas inválidas.'; end if;
   update up_car_city_settings set enabled=(p_data->>'enabled')::boolean,center=st_setsrid(st_makepoint((p_data->>'center_lng')::numeric,(p_data->>'center_lat')::numeric),4326)::geography,radius_m=(p_data->>'radius_m')::integer,offer_seconds=(p_data->>'offer_seconds')::integer,wave_radius_m=(p_data->>'wave_radius_m')::integer,max_waves=(p_data->>'max_waves')::integer,cancel_after_accept=(p_data->>'cancel_after_accept')::boolean,cancel_grace_s=(p_data->>'cancel_grace_s')::integer,cancel_fee_cents=(p_data->>'cancel_fee_cents')::integer,updated_at=now() where city_id=city;
   for result in select * from jsonb_array_elements(p_data->'categories') loop
    insert into up_car_categories(city_id,code,name,enabled,seats,min_year,base_cents,per_km_cents,per_min_cents,minimum_cents) values(city,result->>'code',result->>'name',(result->>'enabled')::boolean,(result->>'seats')::integer,(result->>'min_year')::integer,(result->>'base_cents')::integer,(result->>'per_km_cents')::integer,(result->>'per_min_cents')::integer,(result->>'minimum_cents')::integer) on conflict(city_id,code) do update set name=excluded.name,enabled=excluded.enabled,seats=excluded.seats,min_year=excluded.min_year,base_cents=excluded.base_cents,per_km_cents=excluded.per_km_cents,per_min_cents=excluded.per_min_cents,minimum_cents=excluded.minimum_cents;
   end loop;
   perform up_car_event(null,city,'configuration_changed',jsonb_build_object('reason',reason,'configuration',p_data)); return jsonb_build_object('saved',true);
  end if;
 end if;
 raise exception 'UP_CAR: Ação não reconhecida.';
end $$;

-- Funções não ficam acessíveis por padrão a anon/public; atribuição e preço só no servidor.
create function up_car_pending_dispatch() returns jsonb
language sql security definer set search_path=public,extensions as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',id)),'[]'::jsonb) from
 (select id from up_car_rides where status='searching' and next_dispatch_at<=now() order by next_dispatch_at limit 30) due;
$$;
do $$ declare f record; begin
 for f in select oid::regprocedure as signature from pg_proc where pronamespace='public'::regnamespace and proname like 'up_car_%' loop execute 'revoke all on function '||f.signature||' from public,anon,authenticated'; end loop;
end $$;
grant execute on function up_car_is_staff(text,boolean),up_car_can_read(uuid),up_car_can_topic(text),up_car_command(text,jsonb) to authenticated;
grant execute on function up_car_quote_for(uuid,text,text,jsonb),up_car_dispatch(uuid,jsonb) to service_role;
grant execute on function up_car_pending_dispatch() to service_role;
insert into up_car_city_settings(city_id) select id from up_cidades where id='pitangueiras-sp';
insert into up_car_categories(city_id,code,name) select city_id,'standard','UP Carros' from up_car_city_settings where city_id='pitangueiras-sp';
commit;
