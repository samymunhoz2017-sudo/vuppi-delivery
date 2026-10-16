-- VUPPI 0.67: aceite/recusa/reoferta atômicos para rotas agrupadas e raio real de despacho.
begin;

create or replace function public.vuppi_accept_delivery_offer(p_delivery uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); d public.vuppi_deliveries; m public.vuppi_members; ids uuid[]; accepted_count integer;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_delivery::text,0));
 select * into m from public.vuppi_members where user_id=uid for update;
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 if m.user_id is null or m.kind<>'courier' or not m.approved or not m.is_available then raise exception 'UP_CAR: Entregador indisponível.'; end if;
 if d.id is null or d.status<>'requested' or d.city<>m.city then raise exception 'UP_CAR: Esta oferta não está mais disponível.'; end if;
 select array_agg(x.id order by coalesce(x.route_sequence,1),x.created_at) into ids from public.vuppi_deliveries x where x.status='requested' and (x.id=d.id or (d.route_group_id is not null and x.route_group_id=d.route_group_id));
 if exists(select 1 from public.vuppi_delivery_offer_decisions od where od.courier_id=uid and od.delivery_id=any(ids)) then raise exception 'UP_CAR: Uma entrega desta rota já foi recusada por você.'; end if;
 if exists(select 1 from public.vuppi_deliveries where courier=uid and status in ('assigned','collected')) then raise exception 'UP_CAR: Conclua sua rota atual antes de aceitar outra.'; end if;
 update public.vuppi_deliveries set courier=uid,status='assigned',updated_at=now() where id=any(ids) and status='requested';
 get diagnostics accepted_count=row_count;
 if accepted_count<>array_length(ids,1) then raise exception 'UP_CAR: A rota mudou enquanto era aceita. Atualize as ofertas.'; end if;
 update public.vuppi_members set is_available=false,updated_at=now() where user_id=uid;
 insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details) select x,uid,'route_accepted',jsonb_build_object('route_group_id',d.route_group_id,'count',accepted_count) from unnest(ids) x;
 return jsonb_build_object('ok',true,'delivery_id',d.id,'route_group_id',d.route_group_id,'accepted_ids',to_jsonb(ids),'count',accepted_count);
end;$$;

create or replace function public.vuppi_reject_delivery_offer(p_delivery uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); d public.vuppi_deliveries; m public.vuppi_members; ids uuid[]; inserted_count integer;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_delivery::text,0));
 select * into m from public.vuppi_members where user_id=uid;
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 if m.user_id is null or m.kind<>'courier' or not m.approved then raise exception 'UP_CAR: Apenas entregadores aprovados podem recusar ofertas.'; end if;
 if d.id is null or d.status<>'requested' or d.city<>m.city then raise exception 'UP_CAR: Oferta não encontrada para este entregador.'; end if;
 select array_agg(x.id) into ids from public.vuppi_deliveries x where x.status='requested' and (x.id=d.id or (d.route_group_id is not null and x.route_group_id=d.route_group_id));
 insert into public.vuppi_delivery_offer_decisions(delivery_id,courier_id,decision) select x,uid,'rejected' from unnest(ids) x on conflict(delivery_id,courier_id) do nothing;
 get diagnostics inserted_count=row_count;
 insert into public.up_platform_audit(actor_id,action,target,reason,details) values(uid,'delivery_route_reject',coalesce(d.route_group_id,d.id)::text,'Rota recusada pelo entregador',jsonb_build_object('deliveries',ids,'count',inserted_count));
 return jsonb_build_object('ok',true,'delivery_id',d.id,'route_group_id',d.route_group_id,'rejected_ids',to_jsonb(ids),'count',inserted_count);
end;$$;

create or replace function public.vuppi_courier_release_route(p_delivery uuid,p_reason text default null) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); d public.vuppi_deliveries; ids uuid[]; released integer; reason text:=left(coalesce(nullif(trim(p_reason),''),'Cancelada pelo entregador antes da coleta'),250);
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_delivery::text,0));
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 if d.id is null or d.courier is distinct from uid or d.status<>'assigned' or d.pickup_arrived_at is not null then raise exception 'UP_CAR: O cancelamento pelo app só é permitido antes da chegada ao estabelecimento.'; end if;
 select array_agg(x.id) into ids from public.vuppi_deliveries x where x.courier=uid and x.status='assigned' and (x.id=d.id or (d.route_group_id is not null and x.route_group_id=d.route_group_id));
 insert into public.vuppi_delivery_offer_decisions(delivery_id,courier_id,decision) select x,uid,'rejected' from unnest(ids) x on conflict(delivery_id,courier_id) do nothing;
 update public.vuppi_deliveries set courier=null,status='requested',pickup_arrived_at=null,dispatch_at=now(),updated_at=now() where id=any(ids);
 get diagnostics released=row_count;
 update public.vuppi_members set is_available=true,updated_at=now() where user_id=uid;
 insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details) select x,uid,'courier_released',jsonb_build_object('reason',reason,'route_group_id',d.route_group_id) from unnest(ids) x;
 insert into public.up_platform_audit(actor_id,action,target,reason,details) values(uid,'delivery_route_release',coalesce(d.route_group_id,d.id)::text,reason,jsonb_build_object('deliveries',ids,'reoffer_at',now()));
 return jsonb_build_object('ok',true,'released',released,'reoffered',true,'route_group_id',d.route_group_id);
end;$$;

create or replace function public.vuppi_delivery_state() returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); result jsonb; visible_offers jsonb; m public.vuppi_members; radius_km numeric:=15;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 result:=public.vuppi_delivery('state','{}'::jsonb);
 select * into m from public.vuppi_members where user_id=uid;
 select coalesce(offer_radius_km,15) into radius_km from public.vuppi_operation_settings where id='default';
 if m.kind='courier' and m.approved and m.is_available then
  select coalesce(jsonb_agg(to_jsonb(x) order by coalesce(x.route_group_id,x.id),x.route_sequence nulls first,x.created_at),'[]'::jsonb) into visible_offers from (
   select d.id,d.city,d.merchant,d.merchant_name,d.pickup_address,d.destination,d.recipient,d.phone,d.notes,d.distance_m,d.price_cents,d.return_required,d.route_group_id,d.route_sequence,d.created_at,
    count(*) over(partition by coalesce(d.route_group_id,d.id))::int route_stop_count,
    sum(d.price_cents) over(partition by coalesce(d.route_group_id,d.id))::int route_total_cents
   from public.vuppi_deliveries d where d.status='requested' and d.city=m.city and coalesce(d.dispatch_at,d.scheduled_for,d.created_at)<=now()
    and not exists(select 1 from public.vuppi_delivery_offer_decisions od where od.delivery_id=d.id and od.courier_id=uid)
    and (m.lat is null or m.lng is null or d.pickup_lat is null or d.pickup_lng is null or 6371*2*asin(sqrt(power(sin(radians(d.pickup_lat-m.lat)/2),2)+cos(radians(m.lat))*cos(radians(d.pickup_lat))*power(sin(radians(d.pickup_lng-m.lng)/2),2)))<=radius_km)
   limit 100
  ) x;
 else visible_offers:='[]'::jsonb; end if;
 return jsonb_set(result,'{offers}',visible_offers,true);
end;$$;

revoke all on function public.vuppi_accept_delivery_offer(uuid),public.vuppi_reject_delivery_offer(uuid),public.vuppi_courier_release_route(uuid,text),public.vuppi_delivery_state() from public,anon;
grant execute on function public.vuppi_accept_delivery_offer(uuid),public.vuppi_reject_delivery_offer(uuid),public.vuppi_courier_release_route(uuid,text),public.vuppi_delivery_state() to authenticated;
commit;
