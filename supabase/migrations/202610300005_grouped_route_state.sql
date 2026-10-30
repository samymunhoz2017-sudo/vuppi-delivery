-- Leitura autorizada; nunca retorna o endereço de retorno antes da etapa ativa.
begin;
create function public.vuppi_route_get_state(p_route uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); route public.vuppi_route_operations; current_stop public.vuppi_route_stops;
 courier_allowed boolean:=false; merchant_allowed boolean:=false; admin_allowed boolean:=false; result jsonb;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 select * into route from public.vuppi_route_operations where id=p_route;
 if route.id is null then raise exception 'UP_CAR: Rota não encontrada.'; end if;
 if uid=route.courier_id then select true into courier_allowed from public.vuppi_members where user_id=uid and kind='courier' and approved and member_status='active'; end if;
 if uid=route.merchant_id then select true into merchant_allowed from public.vuppi_members where user_id=uid and kind='merchant' and approved and member_status='active'; end if;
 admin_allowed:=coalesce(public.up_platform_is_admin(),false);
 if not coalesce(courier_allowed,false) and not coalesce(merchant_allowed,false) and not admin_allowed then raise exception 'UP_CAR: Rota não autorizada.'; end if;
 select * into current_stop from public.vuppi_route_stops where route_id=p_route and status in ('active','arrived') order by sequence limit 1;
 result:=jsonb_build_object('route_id',route.id,'state',route.state,'requires_return',route.requires_return,
  'delivery_count',(select count(*) from public.vuppi_route_stops where route_id=p_route and kind='delivery'),
  'confirmed_count',(select count(*) from public.vuppi_route_stops where route_id=p_route and kind='delivery' and status='confirmed'),
  'delivery_stops',(select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'delivery_id',s.delivery_id,'sequence',s.sequence,'status',s.status,'destination',d.destination,'recipient',d.recipient) order by s.sequence),'[]'::jsonb) from public.vuppi_route_stops s join public.vuppi_deliveries d on d.id=s.delivery_id where s.route_id=p_route and s.kind='delivery'),
  'current_stop',case when current_stop.id is null then null
    when current_stop.kind='return' and route.state in ('returning','awaiting_return_confirmation') then jsonb_build_object('id',current_stop.id,'kind','return','status',current_stop.status,'address',route.return_address,'lat',route.return_lat,'lng',route.return_lng)
    when current_stop.kind='delivery' then (select jsonb_build_object('id',current_stop.id,'kind','delivery','delivery_id',d.id,'status',current_stop.status,'sequence',current_stop.sequence,'destination',d.destination,'recipient',d.recipient) from public.vuppi_deliveries d where d.id=current_stop.delivery_id)
    else null end);
 if coalesce(merchant_allowed,false) or admin_allowed then
  result:=result||jsonb_build_object('return_fee_cents',route.return_fee_cents,'settlement',(select jsonb_build_object('id',id,'status',status,'gross_cents',gross_cents) from public.vuppi_route_settlements where route_id=p_route order by version desc limit 1));
 end if;
 return result;
end;$$;
revoke all on function public.vuppi_route_get_state(uuid) from public,anon;
grant execute on function public.vuppi_route_get_state(uuid) to authenticated;
commit;
