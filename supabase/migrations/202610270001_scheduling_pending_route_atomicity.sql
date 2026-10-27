-- Vuppi Delivery 0.84.0: agendamento, pendencias e aceite de rota atomicos.
begin;

create or replace function public.vuppi_create_delivery_transaction(p_data jsonb) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.vuppi_deliveries; scheduled_at timestamptz; lead integer;
begin
 if auth.uid() is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 if nullif(p_data->>'quote_id','') is null then raise exception 'UP_CAR: Cotação não informada.'; end if;
 scheduled_at:=nullif(p_data->>'scheduled_for','')::timestamptz;
 lead:=greatest(0,least(coalesce(nullif(p_data->>'dispatch_lead_minutes','')::integer,0),120));
 if scheduled_at is not null and scheduled_at<=now()+interval '5 seconds' then
  raise exception 'UP_CAR: Escolha um horário futuro para chamar o entregador.';
 end if;
 if public.up_platform_is_admin() and nullif(p_data->>'merchant','') is not null then
  perform public.vuppi_admin_create_delivery(p_data);
 else
  perform public.vuppi_delivery('create',p_data);
 end if;
 perform public.vuppi_delivery_details((p_data->>'quote_id')::uuid,p_data);
 select * into d from public.vuppi_deliveries where quote_id=(p_data->>'quote_id')::uuid for update;
 if d.id is null then raise exception 'UP_CAR: Não foi possível concluir a criação da entrega.';end if;
 if scheduled_at is not null then
  update public.vuppi_deliveries set scheduled_for=scheduled_at,dispatch_at=scheduled_at-make_interval(mins=>lead),updated_at=now() where id=d.id returning * into d;
 else
  update public.vuppi_deliveries set scheduled_for=null,dispatch_at=coalesce(dispatch_at,now()),updated_at=now() where id=d.id returning * into d;
 end if;
 return to_jsonb(d);
end;$$;

create or replace function public.vuppi_accept_delivery_offer(p_delivery uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();d public.vuppi_deliveries;m public.vuppi_members;cfg public.vuppi_operation_settings;ids uuid[];accepted_count integer;distance_km double precision;source text;lock_id uuid;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.';end if;
 select * into d from public.vuppi_deliveries where id=p_delivery;
 if d.id is null then raise exception 'UP_CAR: Solicitação não encontrada.';end if;
 lock_id:=coalesce(d.route_group_id,d.id);
 perform pg_advisory_xact_lock(hashtextextended(lock_id::text,0));
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 select * into m from public.vuppi_members where user_id=uid for update;
 select * into cfg from public.vuppi_operation_settings where id='default';
 if m.user_id is null or m.kind<>'courier' or not m.approved or m.member_status<>'active' or not m.is_available then raise exception 'UP_CAR: Entregador indisponível.';end if;
 if d.status not in('requested','pending') or d.courier is not null or d.city<>m.city then raise exception 'UP_CAR: Solicitação já aceita por outro entregador ou indisponível.';end if;
 if coalesce(d.dispatch_at,d.scheduled_for,d.created_at)>now() then raise exception 'UP_CAR: Esta entrega ainda está agendada e não foi liberada.';end if;
 if d.status='pending' and m.lat is not null and m.lng is not null and d.pickup_lat is not null and d.pickup_lng is not null then
  distance_km:=6371*2*asin(sqrt(power(sin(radians(d.pickup_lat-m.lat)/2),2)+cos(radians(m.lat))*cos(radians(d.pickup_lat))*power(sin(radians(d.pickup_lng-m.lng)/2),2)));
  if distance_km>coalesce(cfg.pending_accept_radius_km,20) then raise exception 'UP_CAR: Você está fora do raio máximo para aceitar esta pendência.';end if;
 end if;
 perform 1 from public.vuppi_deliveries x where x.status in('requested','pending') and (x.id=d.id or(d.route_group_id is not null and x.route_group_id=d.route_group_id)) order by coalesce(x.route_sequence,1),x.created_at for update;
 select array_agg(x.id order by coalesce(x.route_sequence,1),x.created_at) into ids from public.vuppi_deliveries x where x.status in('requested','pending') and x.courier is null and coalesce(x.dispatch_at,x.scheduled_for,x.created_at)<=now() and(x.id=d.id or(d.route_group_id is not null and x.route_group_id=d.route_group_id));
 if coalesce(array_length(ids,1),0)=0 then raise exception 'UP_CAR: Solicitação já aceita por outro entregador ou indisponível.';end if;
 if d.status='requested' and exists(select 1 from public.vuppi_delivery_offer_decisions od where od.courier_id=uid and od.delivery_id=any(ids)) then raise exception 'UP_CAR: Uma entrega desta rota já foi recusada por você.';end if;
 if exists(select 1 from public.vuppi_deliveries where courier=uid and status in('assigned','collected')) then raise exception 'UP_CAR: Conclua sua rota atual antes de aceitar outra.';end if;
 source:=case when d.status='pending' then 'pending_list' when d.pending_since is not null then 'pending_resend' else 'dispatch_offer' end;
 update public.vuppi_deliveries set courier=uid,status='assigned',accepted_from=source,updated_at=now() where id=any(ids) and status in('requested','pending') and courier is null;
 get diagnostics accepted_count=row_count;
 if accepted_count<>array_length(ids,1) then raise exception 'UP_CAR: Solicitação já aceita por outro entregador.';end if;
 update public.vuppi_members set is_available=false,updated_at=now() where user_id=uid;
 insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details) select x,uid,'route_accepted',jsonb_build_object('route_group_id',d.route_group_id,'count',accepted_count,'accepted_from',source,'distance_km',distance_km) from unnest(ids)x;
 return jsonb_build_object('ok',true,'delivery_id',d.id,'accepted_ids',to_jsonb(ids),'count',accepted_count,'accepted_from',source);
end;$$;

create or replace function public.vuppi_courier_pending_state() returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();m public.vuppi_members;cfg public.vuppi_operation_settings;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.';end if;
 select * into m from public.vuppi_members where user_id=uid and kind='courier' and approved and member_status='active';
 if m.user_id is null then raise exception 'UP_CAR: Perfil de entregador ativo não encontrado.';end if;
 select * into cfg from public.vuppi_operation_settings where id='default';
 return jsonb_build_object(
  'available',case when m.is_available then coalesce((select jsonb_agg(to_jsonb(x) order by x.distance_km nulls last,x.pending_since) from(
   select d.id,d.merchant_name,d.pickup_address,d.destination,d.recipient,d.notes,d.price_cents,d.distance_m,d.created_at,d.pending_since,d.pending_expires_at,d.pending_reason,d.pending_retry_count,d.last_dispatch_at,d.route_group_id,d.route_sequence,
    (select count(*)::int from public.vuppi_deliveries r where r.route_group_id=d.route_group_id and r.status in('requested','pending')) route_stop_count,
    (select coalesce(sum(r.price_cents),d.price_cents)::int from public.vuppi_deliveries r where r.route_group_id=d.route_group_id and r.status in('requested','pending')) route_total_cents,
    (select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'destination',r.destination,'recipient',r.recipient,'price_cents',r.price_cents,'route_sequence',r.route_sequence) order by coalesce(r.route_sequence,1),r.created_at),'[]'::jsonb) from public.vuppi_deliveries r where r.route_group_id=d.route_group_id and r.status in('requested','pending')) route_stops,
    case when m.lat is null or m.lng is null or d.pickup_lat is null or d.pickup_lng is null then null else 6371*2*asin(sqrt(power(sin(radians(d.pickup_lat-m.lat)/2),2)+cos(radians(m.lat))*cos(radians(d.pickup_lat))*power(sin(radians(d.pickup_lng-m.lng)/2),2))) end distance_km
   from public.vuppi_deliveries d where d.city=m.city and d.status='pending' and d.courier is null and coalesce(d.dispatch_at,d.scheduled_for,d.created_at)<=now()
    and(m.lat is null or m.lng is null or d.pickup_lat is null or d.pickup_lng is null or 6371*2*asin(sqrt(power(sin(radians(d.pickup_lat-m.lat)/2),2)+cos(radians(m.lat))*cos(radians(d.pickup_lat))*power(sin(radians(d.pickup_lng-m.lng)/2),2)))<=coalesce(cfg.pending_list_radius_km,30))
   order by distance_km nulls last,d.pending_since limit 100
  )x),'[]'::jsonb) else '[]'::jsonb end,
  'decisions',coalesce((select jsonb_agg(to_jsonb(x) order by x.decided_at desc) from(select d.id,d.merchant_name,d.destination,d.price_cents,od.decision,od.decided_at,d.status,d.pending_since from public.vuppi_delivery_offer_decisions od join public.vuppi_deliveries d on d.id=od.delivery_id where od.courier_id=uid and od.decided_at>now()-interval '24 hours' limit 50)x),'[]'::jsonb),
  'settings',jsonb_build_object('list_radius_km',cfg.pending_list_radius_km,'accept_radius_km',cfg.pending_accept_radius_km),'updated_at',now());
end;$$;

revoke all on function public.vuppi_create_delivery_transaction(jsonb),public.vuppi_accept_delivery_offer(uuid),public.vuppi_courier_pending_state() from public,anon;
grant execute on function public.vuppi_create_delivery_transaction(jsonb),public.vuppi_accept_delivery_offer(uuid),public.vuppi_courier_pending_state() to authenticated;
commit;
