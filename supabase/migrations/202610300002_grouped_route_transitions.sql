-- Preparada para desenvolvimento. Não executa lançamentos financeiros.
begin;
create function public.vuppi_route_queue_settlement(p_route uuid) returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare route public.vuppi_route_operations; gross bigint; settlement uuid;
begin
 select * into route from public.vuppi_route_operations where id=p_route for update;
 if route.id is null then raise exception 'UP_CAR: Rota não encontrada.'; end if;
 if exists(select 1 from public.vuppi_route_stops where route_id=p_route and kind='delivery' and status not in ('confirmed','cancelled')) then
  raise exception 'UP_CAR: Existem entregas pendentes na rota.';
 end if;
 if not exists(select 1 from public.vuppi_route_stops where route_id=p_route and kind='delivery' and status='confirmed') then
  raise exception 'UP_CAR: Não há entrega confirmada para liquidar.';
 end if;
 if route.requires_return and route.return_completed_at is null then raise exception 'UP_CAR: O retorno ainda não foi confirmado.'; end if;
 if exists(select 1 from public.vuppi_route_stops where route_id=p_route and kind='delivery' and status='confirmed' and frozen_return_cents>0 and frozen_return_cents<>route.return_fee_cents) then
  raise exception 'UP_CAR: As taxas de retorno congeladas divergem; encaminhe para revisão.';
 end if;
 select coalesce(sum(frozen_price_cents-frozen_return_cents),0)+route.return_fee_cents into gross
  from public.vuppi_route_stops where route_id=p_route and kind='delivery' and status='confirmed';
 insert into public.vuppi_route_settlements(route_id,version,idempotency_key,status,gross_cents,return_fee_cents)
 values(p_route,1,'route-settlement:'||p_route::text||':1','pending',gross,route.return_fee_cents)
 on conflict(route_id,version) do nothing;
 select id into settlement from public.vuppi_route_settlements where route_id=p_route and version=1;
 update public.vuppi_route_operations set state='settlement_pending',updated_at=now() where id=p_route;
 return settlement;
end;$$;

create function public.vuppi_route_confirm_delivery_stop(p_route uuid,p_stop uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); route public.vuppi_route_operations; stop public.vuppi_route_stops; next_stop uuid; settlement uuid;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 select * into route from public.vuppi_route_operations where id=p_route for update;
 if route.id is null or route.courier_id is distinct from uid then raise exception 'UP_CAR: Rota não autorizada.'; end if;
 if not exists(select 1 from public.vuppi_members where user_id=uid and kind='courier' and approved and member_status='active') then raise exception 'UP_CAR: Entregador indisponível.'; end if;
 select * into stop from public.vuppi_route_stops where id=p_stop and route_id=p_route for update;
 if stop.id is null or stop.kind<>'delivery' then raise exception 'UP_CAR: Parada não encontrada.'; end if;
 if stop.status='confirmed' then
  select id into next_stop from public.vuppi_route_stops where route_id=p_route and status in ('active','arrived') order by sequence limit 1;
  return jsonb_build_object('ok',true,'already_confirmed',true,'state',route.state,'next_stop_id',next_stop);
 end if;
 if route.state<>'delivering' or stop.status not in ('active','arrived') then raise exception 'UP_CAR: Parada não está disponível para confirmação.'; end if;
 update public.vuppi_route_stops set status='confirmed',confirmed_at=now(),confirmed_by=uid where id=stop.id;
 insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details)
 values(stop.delivery_id,uid,'route_stop_confirmed',jsonb_build_object('route_id',p_route,'stop_id',stop.id,'sequence',stop.sequence));
 if exists(select 1 from public.vuppi_route_stops where route_id=p_route and kind='delivery' and status='failed') then raise exception 'UP_CAR: Resolva a ocorrência da rota antes de continuar.'; end if;
 select id into next_stop from public.vuppi_route_stops where route_id=p_route and kind='delivery' and status='pending' order by sequence limit 1 for update;
 if next_stop is not null then
  update public.vuppi_route_stops set status='active' where id=next_stop;
  return jsonb_build_object('ok',true,'already_confirmed',false,'state','delivering','next_stop_id',next_stop);
 end if;
 if route.requires_return then
  select id into next_stop from public.vuppi_route_stops where route_id=p_route and kind='return' and status='pending' for update;
  if next_stop is null then raise exception 'UP_CAR: Retorno da rota não está configurado.'; end if;
  update public.vuppi_route_stops set status='active' where id=next_stop;
  update public.vuppi_route_operations set state='returning',updated_at=now() where id=p_route;
  return jsonb_build_object('ok',true,'already_confirmed',false,'state','returning','next_stop_id',next_stop);
 end if;
 settlement:=public.vuppi_route_queue_settlement(p_route);
 return jsonb_build_object('ok',true,'already_confirmed',false,'state','settlement_pending','settlement_id',settlement);
end;$$;

create function public.vuppi_route_arrive_return(p_route uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); route public.vuppi_route_operations; stop public.vuppi_route_stops; last_delivery uuid;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 select * into route from public.vuppi_route_operations where id=p_route for update;
 if route.id is null or route.courier_id is distinct from uid then raise exception 'UP_CAR: Rota não autorizada.'; end if;
 if not exists(select 1 from public.vuppi_members where user_id=uid and kind='courier' and approved and member_status='active') then raise exception 'UP_CAR: Entregador indisponível.'; end if;
 if route.state='awaiting_return_confirmation' then return jsonb_build_object('ok',true,'already_arrived',true); end if;
 if route.state<>'returning' then raise exception 'UP_CAR: Retorno não está em andamento.'; end if;
 select * into stop from public.vuppi_route_stops where route_id=p_route and kind='return' for update;
 if stop.id is null or stop.status<>'active' then raise exception 'UP_CAR: Retorno não está ativo.'; end if;
 update public.vuppi_route_stops set status='arrived' where id=stop.id;
 update public.vuppi_route_operations set state='awaiting_return_confirmation',updated_at=now() where id=p_route;
 select delivery_id into last_delivery from public.vuppi_route_stops where route_id=p_route and kind='delivery' and status='confirmed' order by sequence desc limit 1;
 insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details)
 values(last_delivery,uid,'route_return_arrived',jsonb_build_object('route_id',p_route,'stop_id',stop.id));
 return jsonb_build_object('ok',true,'already_arrived',false,'state','awaiting_return_confirmation');
end;$$;

create function public.vuppi_route_confirm_return(p_route uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); route public.vuppi_route_operations; stop public.vuppi_route_stops; settlement uuid; last_delivery uuid; courier_allowed boolean:=false; merchant_allowed boolean:=false;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 select * into route from public.vuppi_route_operations where id=p_route for update;
 if route.id is null then raise exception 'UP_CAR: Rota não encontrada.'; end if;
 if uid=route.courier_id then select coalesce(allow_courier_return_completion,false) into courier_allowed from public.vuppi_members where user_id=uid and kind='courier' and approved and member_status='active'; end if;
 if uid=route.merchant_id then select true into merchant_allowed from public.vuppi_members where user_id=uid and kind='merchant' and approved and member_status='active'; end if;
 if not coalesce(merchant_allowed,false) and not coalesce(public.up_platform_is_admin(),false) and not coalesce(courier_allowed,false) then
  raise exception 'UP_CAR: Usuário sem permissão para confirmar retorno.';
 end if;
 if route.return_completed_at is not null then return jsonb_build_object('ok',true,'already_confirmed',true,'state',route.state); end if;
 if route.state<>'awaiting_return_confirmation' then raise exception 'UP_CAR: A chegada do retorno ainda não foi registrada.'; end if;
 select * into stop from public.vuppi_route_stops where route_id=p_route and kind='return' for update;
 if stop.id is null or stop.status not in ('active','arrived') then raise exception 'UP_CAR: Retorno não está ativo.'; end if;
 update public.vuppi_route_stops set status='confirmed',confirmed_at=now(),confirmed_by=uid where id=stop.id;
 update public.vuppi_route_operations set return_completed_at=now(),return_completed_by=uid,updated_at=now() where id=p_route;
 select delivery_id into last_delivery from public.vuppi_route_stops where route_id=p_route and kind='delivery' and status='confirmed' order by sequence desc limit 1;
 insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details)
 values(last_delivery,uid,'route_return_confirmed',jsonb_build_object('route_id',p_route,'stop_id',stop.id));
 insert into public.up_platform_audit(actor_id,action,target,reason,details)
 values(uid,'route_return_confirmed',p_route::text,'Retorno confirmado',jsonb_build_object('stop_id',stop.id));
 settlement:=public.vuppi_route_queue_settlement(p_route);
 return jsonb_build_object('ok',true,'already_confirmed',false,'state','settlement_pending','settlement_id',settlement);
end;$$;
revoke all on function public.vuppi_route_queue_settlement(uuid) from public,anon,authenticated;
revoke all on function public.vuppi_route_confirm_delivery_stop(uuid,uuid),public.vuppi_route_arrive_return(uuid),public.vuppi_route_confirm_return(uuid) from public,anon;
grant execute on function public.vuppi_route_confirm_delivery_stop(uuid,uuid),public.vuppi_route_arrive_return(uuid),public.vuppi_route_confirm_return(uuid) to authenticated;
commit;
