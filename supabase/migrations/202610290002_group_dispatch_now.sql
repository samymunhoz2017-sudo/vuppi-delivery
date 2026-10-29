begin;

create or replace function public.vuppi_merchant_manage_delivery(p_action text,p_delivery uuid default null,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();merchant public.vuppi_members;d public.vuppi_deliveries;rider public.vuppi_members;active_route public.vuppi_deliveries;ids uuid[];group_id uuid:=gen_random_uuid();requested_at timestamptz;lead integer;assigned_count integer;offer_seconds integer:=60;target_result jsonb; dispatch_time timestamptz;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.';end if;
 select * into merchant from public.vuppi_members where user_id=uid and kind='merchant' and approved and member_status='active';
 if merchant.user_id is null then raise exception 'UP_CAR: Acesso exclusivo do estabelecimento aprovado.';end if;
 if p_action='couriers' then
  if p_delivery is not null then select * into d from public.vuppi_deliveries where id=p_delivery and vuppi_deliveries.merchant=uid;if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.';end if;end if;
  return coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'name',m.name,'is_available',m.is_available,'online',coalesce(m.last_active_at,m.updated_at)>now()-interval '5 minutes','favorite',f.courier_id is not null,'active_delivery_id',a.id,'active_route_group_id',a.route_group_id,'active_status',a.status,'avatar_data',m.avatar_data,'vehicle_model',m.vehicle_model,'vehicle_plate',m.vehicle_plate) order by(f.courier_id is not null)desc,(a.id is null)desc,m.is_available desc,m.name)
   from public.vuppi_members m left join public.vuppi_merchant_courier_favorites f on f.merchant_id=uid and f.courier_id=m.user_id left join lateral(select x.id,x.route_group_id,x.status from public.vuppi_deliveries x where x.courier=m.user_id and x.status in('assigned','collected') order by x.route_sequence nulls last,x.created_at limit 1)a on true
   where m.kind='courier' and m.approved and m.member_status='active' and m.city=coalesce(d.city,merchant.city) and (m.is_available or a.id is not null) and coalesce(m.last_active_at,m.updated_at)>now()-interval '5 minutes'),'[]'::jsonb);
 end if;
 if p_action='favorite' then
  select * into rider from public.vuppi_members where user_id=(p_data->>'courier')::uuid and kind='courier' and approved and city=merchant.city;
  if rider.user_id is null then raise exception 'UP_CAR: Entregador não encontrado nesta cidade.';end if;
  if coalesce((p_data->>'favorite')::boolean,true) then insert into public.vuppi_merchant_courier_favorites(merchant_id,courier_id) values(uid,rider.user_id) on conflict do nothing;else delete from public.vuppi_merchant_courier_favorites where merchant_id=uid and courier_id=rider.user_id;end if;
  return jsonb_build_object('ok',true,'favorite',coalesce((p_data->>'favorite')::boolean,true));
 end if;
 if p_action='join' then
  select array_agg(value::uuid) into ids from jsonb_array_elements_text(coalesce(p_data->'ids','[]'::jsonb));
  if coalesce(array_length(ids,1),0)<2 then raise exception 'UP_CAR: Selecione pelo menos duas entregas.';end if;
  if array_length(ids,1)<>(select count(distinct x) from unnest(ids)x) then raise exception 'UP_CAR: Não selecione a mesma entrega duas vezes.';end if;
  perform 1 from public.vuppi_deliveries where id=any(ids) order by id for update;
  if exists(select 1 from unnest(ids)x left join public.vuppi_deliveries v on v.id=x where v.id is null or v.merchant<>uid or v.status not in('requested','assigned','collected')) then raise exception 'UP_CAR: Uma das entregas não pode ser agrupada.';end if;
  select count(distinct courier) into assigned_count from public.vuppi_deliveries where id=any(ids) and courier is not null;if assigned_count>1 then raise exception 'UP_CAR: Não é possível juntar entregas de entregadores diferentes.';end if;
  if assigned_count=0 then
   select case when coalesce((p_data->>'dispatch_now')::boolean,false) then now() else greatest(now(),max(coalesce(dispatch_at,scheduled_for,created_at))) end into dispatch_time from public.vuppi_deliveries where id=any(ids);
   update public.vuppi_deliveries set dispatch_at=dispatch_time,scheduled_for=case when coalesce((p_data->>'dispatch_now')::boolean,false) then null else scheduled_for end where id=any(ids);
  elsif exists(select 1 from public.vuppi_deliveries where id=any(ids) and courier is null and coalesce(dispatch_at,scheduled_for,created_at)>now()) then raise exception 'UP_CAR: Uma entrega futura não pode ser juntada a uma rota já em andamento.';end if;
  select route_group_id into group_id from public.vuppi_deliveries where id=any(ids) and route_group_id is not null limit 1;group_id:=coalesce(group_id,gen_random_uuid());
  update public.vuppi_deliveries set route_group_id=group_id,route_sequence=x.seq,updated_at=now() from(select id,row_number()over(order by case status when 'collected' then 0 when 'assigned' then 1 else 2 end,coalesce(scheduled_for,created_at),created_at)::int seq from public.vuppi_deliveries where id=any(ids))x where vuppi_deliveries.id=x.id;
  insert into public.up_platform_audit(actor_id,action,target,reason,details) values(uid,'delivery_join',group_id::text,'Rotas agrupadas pelo estabelecimento',jsonb_build_object('deliveries',ids));
  if nullif(p_data->>'courier','') is not null then target_result:=public.vuppi_merchant_manage_delivery('assign',ids[1],jsonb_build_object('courier',p_data->>'courier')); end if;
  return jsonb_build_object('ok',true,'route_group_id',group_id,'count',array_length(ids,1),'targeted',target_result);
 end if;
 select * into d from public.vuppi_deliveries where id=p_delivery and vuppi_deliveries.merchant=uid for update;if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.';end if;
 if p_action='assign' then
  if d.status not in('requested','pending','unattended') or d.courier is not null then raise exception 'UP_CAR: Esta entrega não está disponível para oferta.';end if;
  select * into rider from public.vuppi_members where user_id=(p_data->>'courier')::uuid for update;
  select * into active_route from public.vuppi_deliveries where courier=rider.user_id and status in('assigned','collected') order by route_sequence nulls last,created_at limit 1;
  if rider.user_id is null or rider.kind<>'courier' or not rider.approved or rider.member_status<>'active' or rider.city<>d.city or coalesce(rider.last_active_at,rider.updated_at)<=now()-interval '5 minutes' or(not rider.is_available and active_route.id is null) then raise exception 'UP_CAR: Entregador não está online ou compatível.';end if;
  offer_seconds:=greatest(20,least(180,coalesce(nullif(p_data->>'offer_seconds','')::integer,60)));
  perform pg_advisory_xact_lock(hashtextextended(coalesce(d.route_group_id,d.id)::text,0));
  perform 1 from public.vuppi_deliveries x where x.id=d.id or (d.route_group_id is not null and x.route_group_id=d.route_group_id) order by x.id for update;
  select array_agg(x.id order by coalesce(x.route_sequence,1),x.created_at),greatest(now(),max(coalesce(x.dispatch_at,x.scheduled_for,x.created_at))) into ids,dispatch_time from public.vuppi_deliveries x where x.id=d.id or (d.route_group_id is not null and x.route_group_id=d.route_group_id);
  if exists(select 1 from public.vuppi_deliveries x where x.id=any(ids) and (x.merchant<>uid or x.city<>d.city or x.courier is not null or x.status not in('requested','pending','unattended'))) then raise exception 'UP_CAR: Todas as entregas da rota precisam estar livres para direcionamento.';end if;
  update public.vuppi_deliveries set status='requested',preferred_courier=rider.user_id,preferred_offered_at=dispatch_time,preferred_offer_expires_at=dispatch_time+make_interval(secs=>offer_seconds),pending_since=null,pending_expires_at=null,pending_reason=null,dispatch_at=dispatch_time,last_dispatch_at=dispatch_time,accepted_from=null,updated_at=now() where id=any(ids);
  delete from public.vuppi_delivery_offer_decisions where delivery_id=any(ids) and courier_id=rider.user_id;
  insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details) select x,uid,'merchant_targeted_offer',jsonb_build_object('courier_id',rider.user_id,'dispatch_at',dispatch_time,'expires_at',dispatch_time+make_interval(secs=>offer_seconds),'courier_in_route',active_route.id is not null) from unnest(ids)x;
  return jsonb_build_object('ok',true,'offered',true,'delivery_id',d.id,'courier_id',rider.user_id,'dispatch_at',dispatch_time,'expires_at',dispatch_time+make_interval(secs=>offer_seconds),'courier_in_route',active_route.id is not null,'count',array_length(ids,1));
 elsif p_action='redistribute' then
  if d.status not in('requested','pending','unattended') or d.courier is not null then raise exception 'UP_CAR: Esta entrega não pode ser redistribuída agora.';end if;
  update public.vuppi_deliveries set status='requested',preferred_courier=null,preferred_offered_at=null,preferred_offer_expires_at=null,pending_since=null,pending_expires_at=null,pending_reason=null,dispatch_at=now(),last_dispatch_at=now(),pending_retry_count=0,updated_at=now() where id=d.id returning * into d;
  insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details) values(d.id,uid,'merchant_redistributed',jsonb_build_object('source','merchant','reason',coalesce(p_data->>'reason','Redistribuição solicitada pela loja')));
  return jsonb_build_object('ok',true,'redistributed',true,'delivery_id',d.id);
 elsif p_action='edit' then
  if d.status<>'requested' then raise exception 'UP_CAR: A edição fica disponível antes do aceite do entregador.';end if;
  lead:=greatest(0,least(99,coalesce(nullif(p_data->>'dispatch_minutes','')::int,10)));if p_data->>'dispatch_mode'='schedule' then requested_at:=nullif(p_data->>'scheduled_for','')::timestamptz;elsif p_data->>'dispatch_mode'='minutes' then requested_at:=now()+make_interval(mins=>lead);else requested_at:=null;end if;
  if requested_at is not null and requested_at<now()+interval '1 minute' then raise exception 'UP_CAR: Escolha um horário futuro para o despacho.';end if;
  update public.vuppi_deliveries set recipient=left(trim(coalesce(p_data->>'recipient',recipient)),100),phone=left(trim(coalesce(p_data->>'phone',phone)),30),external_order_number=nullif(left(trim(p_data->>'external_order_number'),60),''),notes=nullif(left(trim(p_data->>'notes'),500),''),scheduled_for=requested_at,dispatch_at=requested_at,updated_at=now() where id=d.id;
 elsif p_action='optimize' then
  if d.route_group_id is null then update public.vuppi_deliveries set route_group_id=group_id,route_sequence=1,updated_at=now() where id=d.id;
  else select array_agg(value::uuid) into ids from jsonb_array_elements_text(coalesce(p_data->'ordered_ids','[]'::jsonb));if coalesce(array_length(ids,1),0)<>(select count(*) from public.vuppi_deliveries where route_group_id=d.route_group_id) or exists(select 1 from unnest(ids)x left join public.vuppi_deliveries v on v.id=x where v.id is null or v.route_group_id<>d.route_group_id or v.merchant<>uid) then raise exception 'UP_CAR: A sequência otimizada é inválida.';end if;update public.vuppi_deliveries set route_sequence=x.seq,updated_at=now() from(select id,ord::int seq from unnest(ids)with ordinality as t(id,ord))x where vuppi_deliveries.id=x.id;end if;
 else raise exception 'UP_CAR: Operação desconhecida.';end if;
 insert into public.up_platform_audit(actor_id,action,target,reason,details) values(uid,'merchant_delivery_'||p_action,d.id::text,'Gestão da entrega pelo estabelecimento',p_data);return jsonb_build_object('ok',true,'delivery',to_jsonb(d));
end;$$;



commit;
