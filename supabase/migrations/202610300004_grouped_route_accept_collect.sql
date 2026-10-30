-- Reutiliza as funções legadas de aceite e coleta dentro da mesma transação.
-- Não faz liquidação financeira e não deve ser habilitada antes da integração completa.
begin;
create function public.vuppi_route_accept_group(p_route uuid,p_delivery uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); route public.vuppi_route_operations; result jsonb; expected integer;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_route::text,0));
 select * into route from public.vuppi_route_operations where id=p_route for update;
 if route.id is null then raise exception 'UP_CAR: Rota não encontrada.'; end if;
 if route.courier_id=uid and route.state in ('accepted','collecting','picked_up','delivering','returning','awaiting_return_confirmation','settlement_pending','completed') then
  return jsonb_build_object('ok',true,'already_accepted',true,'route_id',p_route,'state',route.state);
 end if;
 if route.state not in ('dispatching','pending') or route.courier_id is not null or
    not exists(select 1 from public.vuppi_route_stops where route_id=p_route and kind='delivery' and delivery_id=p_delivery) then
  raise exception 'UP_CAR: Rota indisponível para aceite.';
 end if;
 result:=public.vuppi_accept_delivery_offer(p_delivery);
 select count(*) into expected from public.vuppi_route_stops where route_id=p_route and kind='delivery';
 if coalesce(jsonb_array_length(result->'accepted_ids'),0)<>expected or exists(
  select 1 from public.vuppi_route_stops s where s.route_id=p_route and s.kind='delivery'
   and not exists(select 1 from jsonb_array_elements_text(result->'accepted_ids') x where x=s.delivery_id::text)
 ) then raise exception 'UP_CAR: A composição da rota mudou durante o aceite.'; end if;
 update public.vuppi_route_operations set courier_id=uid,state='accepted',updated_at=now() where id=p_route;
 return jsonb_build_object('ok',true,'already_accepted',false,'route_id',p_route,'state','accepted','count',expected);
end;$$;

create function public.vuppi_route_collect_group(p_route uuid,p_delivery uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); route public.vuppi_route_operations; d public.vuppi_deliveries; result jsonb; next_delivery uuid; next_stop uuid;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_route::text,0));
 select * into route from public.vuppi_route_operations where id=p_route for update;
 if route.id is null or route.courier_id is distinct from uid then raise exception 'UP_CAR: Rota não autorizada.'; end if;
 if not exists(select 1 from public.vuppi_members where user_id=uid and kind='courier' and approved and member_status='active') then raise exception 'UP_CAR: Entregador indisponível.'; end if;
 if not exists(select 1 from public.vuppi_route_stops where route_id=p_route and kind='delivery' and delivery_id=p_delivery) then raise exception 'UP_CAR: Coleta não pertence à rota.'; end if;
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 if d.courier is distinct from uid then raise exception 'UP_CAR: Coleta não autorizada.'; end if;
 if d.status='collected' and route.state in ('collecting','delivering') then
  select s.delivery_id into next_delivery from public.vuppi_route_stops s join public.vuppi_deliveries x on x.id=s.delivery_id
   where s.route_id=p_route and s.kind='delivery' and x.status='assigned' order by s.sequence limit 1;
  select id into next_stop from public.vuppi_route_stops where route_id=p_route and status in ('active','arrived') order by sequence limit 1;
  return jsonb_build_object('ok',true,'already_collected',true,'route_id',p_route,'state',route.state,'next_pickup_delivery_id',next_delivery,'next_stop_id',next_stop);
 end if;
 if route.state not in ('accepted','collecting') or d.status<>'assigned' then raise exception 'UP_CAR: Coleta indisponível.'; end if;
 result:=public.vuppi_collect_group_at_pickup(p_delivery);
 if exists(select 1 from public.vuppi_route_stops s join public.vuppi_deliveries x on x.id=s.delivery_id where s.route_id=p_route and s.kind='delivery' and (x.courier is distinct from uid or x.status not in ('assigned','collected'))) then
  raise exception 'UP_CAR: A composição da rota mudou durante a coleta.';
 end if;
 select s.delivery_id into next_delivery from public.vuppi_route_stops s join public.vuppi_deliveries x on x.id=s.delivery_id
  where s.route_id=p_route and s.kind='delivery' and x.status='assigned' order by s.sequence limit 1;
 if next_delivery is not null then
  update public.vuppi_route_operations set state='collecting',updated_at=now() where id=p_route;
  return jsonb_build_object('ok',true,'already_collected',false,'route_id',p_route,'state','collecting','next_pickup_delivery_id',next_delivery);
 end if;
 select id into next_stop from public.vuppi_route_stops where route_id=p_route and kind='delivery' and status='pending' order by sequence limit 1 for update;
 if next_stop is null then raise exception 'UP_CAR: Rota sem destinos disponíveis.'; end if;
 update public.vuppi_route_stops set status='active' where id=next_stop;
 update public.vuppi_route_operations set state='delivering',updated_at=now() where id=p_route;
 return jsonb_build_object('ok',true,'already_collected',false,'route_id',p_route,'state','delivering','next_stop_id',next_stop);
end;$$;
revoke all on function public.vuppi_route_accept_group(uuid,uuid),public.vuppi_route_collect_group(uuid,uuid) from public,anon;
grant execute on function public.vuppi_route_accept_group(uuid,uuid),public.vuppi_route_collect_group(uuid,uuid) to authenticated;
commit;
