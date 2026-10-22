-- Vuppi Delivery 0.76.0: estado canônico, expiração e reenvio de pendências.
begin;

alter table public.vuppi_deliveries drop constraint if exists vuppi_deliveries_status_check;
alter table public.vuppi_deliveries
 add constraint vuppi_deliveries_status_check
 check(status in ('requested','pending','assigned','collected','delivered','cancelled','unattended')),
 add column if not exists pending_since timestamptz,
 add column if not exists pending_expires_at timestamptz,
 add column if not exists pending_reason text,
 add column if not exists pending_retry_count integer not null default 0,
 add column if not exists last_dispatch_at timestamptz,
 add column if not exists accepted_from text;

alter table public.vuppi_operation_settings
 add column if not exists pending_expiry_seconds integer not null default 600,
 add column if not exists pending_list_radius_km numeric(6,2) not null default 30,
 add column if not exists pending_accept_radius_km numeric(6,2) not null default 20,
 add column if not exists enable_pending_auto_resend boolean not null default true,
 add column if not exists pending_resend_after_seconds integer not null default 60,
 add column if not exists pending_max_resends integer not null default 3,
 add column if not exists pending_warning_seconds integer not null default 180,
 add column if not exists pending_critical_seconds integer not null default 420;

create index if not exists vuppi_deliveries_pending_active_idx
 on public.vuppi_deliveries(city,pending_since,id) where status='pending';
create index if not exists vuppi_deliveries_pending_expiry_idx
 on public.vuppi_deliveries(pending_expires_at) where status='pending';

create or replace function public.vuppi_transition_delivery_pending(p_delivery uuid,p_reason text default 'dispatch_exhausted',p_context jsonb default '{}')
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.vuppi_deliveries; cfg public.vuppi_operation_settings; previous text;
begin
 perform pg_advisory_xact_lock(hashtextextended(p_delivery::text,0));
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.';end if;
 if d.status='pending' then return to_jsonb(d);end if;
 if d.status<>'requested' or d.courier is not null then raise exception 'UP_CAR: Entrega não pode entrar em pendência neste estado.';end if;
 select * into cfg from public.vuppi_operation_settings where id='default';
 previous:=d.status;
 update public.vuppi_deliveries set status='pending',pending_since=coalesce(pending_since,now()),
  pending_expires_at=coalesce(pending_expires_at,now()+make_interval(secs=>greatest(60,coalesce(cfg.pending_expiry_seconds,600)))),
  pending_reason=left(coalesce(nullif(trim(p_reason),''),'dispatch_exhausted'),120),
  last_dispatch_at=coalesce(last_dispatch_at,dispatch_at,created_at),updated_at=now()
 where id=d.id returning * into d;
 insert into public.vuppi_delivery_events(delivery_id,event_type,details)
 values(d.id,'status_pending',jsonb_build_object('from_status',previous,'to_status','pending','reason',d.pending_reason,'context',coalesce(p_context,'{}')));
 return to_jsonb(d);
end;$$;

create or replace function public.vuppi_pending_maintenance()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare cfg public.vuppi_operation_settings; row record; transitioned integer:=0; expired integer:=0; resent integer:=0;
begin
 if coalesce(auth.role(),'')<>'service_role' and not public.up_platform_is_admin() then raise exception 'UP_CAR: Manutenção de pendências não autorizada.';end if;
 select * into cfg from public.vuppi_operation_settings where id='default';
 for row in
  select d.id from public.vuppi_deliveries d
  where d.status='requested' and d.courier is null
   and coalesce(d.dispatch_at,d.scheduled_for,d.created_at)<=now()
   and now()>=coalesce(d.dispatch_at,d.scheduled_for,d.created_at)+make_interval(secs=>greatest(15,coalesce(cfg.pending_after_seconds,90)))
  order by coalesce(d.dispatch_at,d.created_at) for update skip locked
 loop
  perform public.vuppi_transition_delivery_pending(row.id,'dispatch_cycle_exhausted',jsonb_build_object('source','maintenance'));
  transitioned:=transitioned+1;
 end loop;

 for row in
  update public.vuppi_deliveries set status='unattended',updated_at=now()
  where status='pending' and courier is null and pending_expires_at<=now()
  returning id,pending_since,pending_expires_at
 loop
  insert into public.vuppi_delivery_events(delivery_id,event_type,details)
  values(row.id,'status_unattended',jsonb_build_object('from_status','pending','to_status','unattended','reason','pending_expired','pending_since',row.pending_since,'pending_expires_at',row.pending_expires_at));
  expired:=expired+1;
 end loop;

 if coalesce(cfg.enable_pending_auto_resend,true) then
  for row in
   update public.vuppi_deliveries set pending_retry_count=pending_retry_count+1,last_dispatch_at=now(),updated_at=now()
   where status='pending' and courier is null and pending_retry_count<greatest(0,coalesce(cfg.pending_max_resends,3))
    and now()>=coalesce(last_dispatch_at,pending_since)+make_interval(secs=>greatest(15,coalesce(cfg.pending_resend_after_seconds,60)))
    and pending_expires_at>now()
   returning id,pending_retry_count
  loop
   insert into public.vuppi_delivery_events(delivery_id,event_type,details)
   values(row.id,'pending_resend',jsonb_build_object('retry',row.pending_retry_count,'source','automatic'));
   resent:=resent+1;
  end loop;
 end if;
 return jsonb_build_object('ok',true,'transitioned',transitioned,'expired',expired,'resent',resent,'checked_at',now());
end;$$;

create or replace function public.vuppi_pending_admin(p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.vuppi_deliveries; actor uuid:=auth.uid();
begin
 if not public.up_platform_is_admin() then raise exception 'UP_CAR: Acesso exclusivo do administrador.';end if;
 if p_action='state' then
  return jsonb_build_object(
   'deliveries',coalesce((select jsonb_agg(to_jsonb(x) order by x.pending_since) from (
    select d.*,coalesce((select count(*) from public.vuppi_members m where m.kind='courier' and m.approved and m.member_status='active' and m.is_available and m.city=d.city),0)::int eligible_count
    from public.vuppi_deliveries d where d.status='pending' order by d.pending_since limit 500
   )x),'[]'::jsonb),
   'count',(select count(*) from public.vuppi_deliveries where status='pending'),
   'anomalies',jsonb_build_object(
    'missing_since',(select count(*) from public.vuppi_deliveries where status='pending' and pending_since is null),
    'assigned_pending',(select count(*) from public.vuppi_deliveries where status='pending' and courier is not null),
    'expired_pending',(select count(*) from public.vuppi_deliveries where status='pending' and pending_expires_at<=now())
   ),'updated_at',now());
 end if;
 select * into d from public.vuppi_deliveries where id=(p_data->>'id')::uuid for update;
 if d.id is null or d.status<>'pending' then raise exception 'UP_CAR: Pendência não está mais disponível.';end if;
 if p_action='resend' then
  update public.vuppi_deliveries set pending_retry_count=pending_retry_count+1,last_dispatch_at=now(),updated_at=now() where id=d.id returning * into d;
  insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details) values(d.id,actor,'pending_resend',jsonb_build_object('retry',d.pending_retry_count,'source','admin','reason',p_data->>'reason'));
  return to_jsonb(d);
 end if;
 raise exception 'UP_CAR: Ação de pendência inválida.';
end;$$;

create or replace function public.vuppi_assign_delivery(p_delivery uuid,p_courier uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.vuppi_deliveries; rider public.vuppi_members; source text;
begin
 if not public.up_platform_is_admin() then raise exception 'UP_CAR: Acesso exclusivo do administrador.';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_delivery::text,0));
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 select * into rider from public.vuppi_members where user_id=p_courier for update;
 if d.id is null or d.status not in('requested','pending') or d.courier is not null then raise exception 'UP_CAR: Entrega não está disponível.';end if;
 if rider.user_id is null or rider.kind<>'courier' or not rider.approved or rider.member_status<>'active' or rider.city<>d.city then raise exception 'UP_CAR: Entregador incompatível ou inativo.';end if;
 if exists(select 1 from public.vuppi_deliveries where courier=p_courier and status in('assigned','collected')) then raise exception 'UP_CAR: Entregador já possui rota em andamento.';end if;
 source:=case when d.status='pending' then 'pending_admin_assignment' else 'admin_assignment' end;
 update public.vuppi_deliveries set courier=p_courier,status='assigned',accepted_from=source,updated_at=now() where id=d.id returning * into d;
 update public.vuppi_members set is_available=false,updated_at=now() where user_id=p_courier;
 insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details) values(d.id,auth.uid(),'assigned',jsonb_build_object('courier_id',p_courier,'accepted_from',source));
 return to_jsonb(d);
end;$$;

create or replace function public.vuppi_accept_delivery_offer(p_delivery uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); d public.vuppi_deliveries; m public.vuppi_members; cfg public.vuppi_operation_settings; ids uuid[]; accepted_count integer; distance_km double precision; source text;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_delivery::text,0));
 select * into m from public.vuppi_members where user_id=uid for update;
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 select * into cfg from public.vuppi_operation_settings where id='default';
 if m.user_id is null or m.kind<>'courier' or not m.approved or m.member_status<>'active' or not m.is_available then raise exception 'UP_CAR: Entregador indisponível.';end if;
 if d.id is null or d.status not in('requested','pending') or d.courier is not null or d.city<>m.city then raise exception 'UP_CAR: Solicitação já aceita ou indisponível.';end if;
 if d.status='pending' then
  if m.lat is null or m.lng is null then raise exception 'UP_CAR: Atualize sua localização para aceitar esta pendência.';end if;
  distance_km:=6371*2*asin(sqrt(power(sin(radians(d.pickup_lat-m.lat)/2),2)+cos(radians(m.lat))*cos(radians(d.pickup_lat))*power(sin(radians(d.pickup_lng-m.lng)/2),2)));
  if distance_km>coalesce(cfg.pending_accept_radius_km,20) then raise exception 'UP_CAR: Você está fora do raio máximo para aceitar esta pendência.';end if;
 end if;
 select array_agg(x.id order by coalesce(x.route_sequence,1),x.created_at) into ids
 from public.vuppi_deliveries x where x.status in('requested','pending') and (x.id=d.id or (d.route_group_id is not null and x.route_group_id=d.route_group_id));
 if d.status='requested' and exists(select 1 from public.vuppi_delivery_offer_decisions od where od.courier_id=uid and od.delivery_id=any(ids)) then raise exception 'UP_CAR: Uma entrega desta rota já foi recusada por você.';end if;
 if exists(select 1 from public.vuppi_deliveries where courier=uid and status in('assigned','collected')) then raise exception 'UP_CAR: Conclua sua rota atual antes de aceitar outra.';end if;
 source:=case when d.status='pending' then 'pending_list' when d.pending_since is not null then 'pending_resend' else 'dispatch_offer' end;
 update public.vuppi_deliveries set courier=uid,status='assigned',accepted_from=source,updated_at=now() where id=any(ids) and status in('requested','pending') and courier is null;
 get diagnostics accepted_count=row_count;
 if accepted_count<>array_length(ids,1) then raise exception 'UP_CAR: Solicitação já aceita por outro entregador.';end if;
 update public.vuppi_members set is_available=false,updated_at=now() where user_id=uid;
 insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details)
 select x,uid,'route_accepted',jsonb_build_object('route_group_id',d.route_group_id,'count',accepted_count,'accepted_from',source,'distance_km',distance_km) from unnest(ids)x;
 return jsonb_build_object('ok',true,'delivery_id',d.id,'accepted_ids',to_jsonb(ids),'count',accepted_count,'accepted_from',source);
end;$$;

create or replace function public.vuppi_courier_pending_state() returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); m public.vuppi_members; cfg public.vuppi_operation_settings;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.';end if;
 select * into m from public.vuppi_members where user_id=uid and kind='courier' and approved and member_status='active';
 if m.user_id is null then raise exception 'UP_CAR: Perfil de entregador ativo não encontrado.';end if;
 select * into cfg from public.vuppi_operation_settings where id='default';
 return jsonb_build_object(
  'available',case when m.is_available then coalesce((select jsonb_agg(to_jsonb(x) order by x.distance_km nulls last,x.pending_since) from (
   select d.id,d.merchant_name,d.pickup_address,d.destination,d.recipient,d.notes,d.price_cents,d.distance_m,d.created_at,d.pending_since,d.pending_expires_at,d.pending_reason,d.pending_retry_count,d.last_dispatch_at,
    case when m.lat is null or m.lng is null then null else 6371*2*asin(sqrt(power(sin(radians(d.pickup_lat-m.lat)/2),2)+cos(radians(m.lat))*cos(radians(d.pickup_lat))*power(sin(radians(d.pickup_lng-m.lng)/2),2))) end distance_km
   from public.vuppi_deliveries d where d.city=m.city and d.status='pending' and d.courier is null
    and (m.lat is null or m.lng is null or 6371*2*asin(sqrt(power(sin(radians(d.pickup_lat-m.lat)/2),2)+cos(radians(m.lat))*cos(radians(d.pickup_lat))*power(sin(radians(d.pickup_lng-m.lng)/2),2)))<=coalesce(cfg.pending_list_radius_km,30))
   order by distance_km nulls last,d.pending_since limit 100
  )x),'[]'::jsonb) else '[]'::jsonb end,
  'decisions',coalesce((select jsonb_agg(to_jsonb(x) order by x.decided_at desc) from (
   select d.id,d.merchant_name,d.destination,d.price_cents,od.decision,od.decided_at,d.status,d.pending_since
   from public.vuppi_delivery_offer_decisions od join public.vuppi_deliveries d on d.id=od.delivery_id
   where od.courier_id=uid and od.decided_at>now()-interval '24 hours' limit 50
  )x),'[]'::jsonb),
  'settings',jsonb_build_object('list_radius_km',cfg.pending_list_radius_km,'accept_radius_km',cfg.pending_accept_radius_km),
  'updated_at',now());
end;$$;

create or replace function public.vuppi_logistics_admin(p_action text,p_data jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare s public.vuppi_operation_settings; t public.vuppi_delivery_types;
begin
 if not public.up_platform_is_admin() then raise exception 'UP_CAR: Acesso exclusivo do administrador.';end if;
 if p_action='state' then return jsonb_build_object('settings',(select to_jsonb(x) from public.vuppi_operation_settings x where id='default'),'types',coalesce((select jsonb_agg(to_jsonb(x) order by priority,name) from public.vuppi_delivery_types x),'[]'::jsonb));end if;
 if p_action='save_settings' then
  update public.vuppi_operation_settings set
   dispatch_lead_minutes=greatest(0,least(120,coalesce((p_data->>'dispatch_lead_minutes')::int,dispatch_lead_minutes))),pickup_deadline_minutes=greatest(1,least(120,coalesce((p_data->>'pickup_deadline_minutes')::int,pickup_deadline_minutes))),offer_radius_km=greatest(1,least(50,coalesce((p_data->>'offer_radius_km')::int,offer_radius_km))),route_grouping_enabled=coalesce((p_data->>'route_grouping_enabled')::boolean,route_grouping_enabled),multi_pickup_enabled=coalesce((p_data->>'multi_pickup_enabled')::boolean,multi_pickup_enabled),max_group_deliveries=greatest(1,least(10,coalesce((p_data->>'max_group_deliveries')::int,max_group_deliveries))),completion_radius_m=greatest(30,least(5000,coalesce((p_data->>'completion_radius_m')::int,completion_radius_m))),single_active_delivery=coalesce((p_data->>'single_active_delivery')::boolean,single_active_delivery),reoffer_delay_seconds=greatest(5,least(600,coalesce((p_data->>'reoffer_delay_seconds')::int,reoffer_delay_seconds))),pending_after_seconds=greatest(15,least(3600,coalesce((p_data->>'pending_after_seconds')::int,pending_after_seconds))),max_offer_rounds=greatest(1,least(50,coalesce((p_data->>'max_offer_rounds')::int,max_offer_rounds))),offer_sound_enabled=coalesce((p_data->>'offer_sound_enabled')::boolean,offer_sound_enabled),push_enabled=coalesce((p_data->>'push_enabled')::boolean,push_enabled),operation_timezone=case when coalesce(p_data->>'operation_timezone','') in('America/Sao_Paulo','UTC') then p_data->>'operation_timezone' else operation_timezone end,
   pending_expiry_seconds=greatest(60,least(86400,coalesce((p_data->>'pending_expiry_seconds')::int,pending_expiry_seconds))),pending_list_radius_km=greatest(1,least(100,coalesce((p_data->>'pending_list_radius_km')::numeric,pending_list_radius_km))),pending_accept_radius_km=greatest(1,least(100,coalesce((p_data->>'pending_accept_radius_km')::numeric,pending_accept_radius_km))),enable_pending_auto_resend=coalesce((p_data->>'enable_pending_auto_resend')::boolean,enable_pending_auto_resend),pending_resend_after_seconds=greatest(15,least(3600,coalesce((p_data->>'pending_resend_after_seconds')::int,pending_resend_after_seconds))),pending_max_resends=greatest(0,least(50,coalesce((p_data->>'pending_max_resends')::int,pending_max_resends))),pending_warning_seconds=greatest(30,least(86400,coalesce((p_data->>'pending_warning_seconds')::int,pending_warning_seconds))),pending_critical_seconds=greatest(60,least(86400,coalesce((p_data->>'pending_critical_seconds')::int,pending_critical_seconds))),updated_at=now(),updated_by=auth.uid()
  where id='default' returning * into s;return jsonb_build_object('ok',true,'settings',to_jsonb(s));
 end if;
 if p_action='save_type' then update public.vuppi_delivery_types set enabled=coalesce((p_data->>'enabled')::boolean,enabled),priority=greatest(1,least(99,coalesce((p_data->>'priority')::int,priority))),updated_at=now(),updated_by=auth.uid() where code=p_data->>'code' returning * into t;if t.code is null then raise exception 'UP_CAR: Tipo de entrega não encontrado.';end if;return jsonb_build_object('ok',true,'type',to_jsonb(t));end if;
 raise exception 'UP_CAR: Ação logística inválida.';
end;$$;

revoke all on function public.vuppi_transition_delivery_pending(uuid,text,jsonb),public.vuppi_pending_maintenance() from public,anon,authenticated;
grant execute on function public.vuppi_transition_delivery_pending(uuid,text,jsonb),public.vuppi_pending_maintenance() to service_role;
revoke all on function public.vuppi_pending_admin(text,jsonb),public.vuppi_assign_delivery(uuid,uuid),public.vuppi_accept_delivery_offer(uuid),public.vuppi_courier_pending_state() from public,anon;
grant execute on function public.vuppi_pending_admin(text,jsonb),public.vuppi_assign_delivery(uuid,uuid),public.vuppi_accept_delivery_offer(uuid),public.vuppi_courier_pending_state() to authenticated;
revoke all on function public.vuppi_logistics_admin(text,jsonb) from public,anon;
grant execute on function public.vuppi_logistics_admin(text,jsonb) to authenticated;

commit;

