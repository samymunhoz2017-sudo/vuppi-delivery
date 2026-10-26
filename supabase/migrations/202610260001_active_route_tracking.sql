-- Vuppi Delivery 0.82.0: rastreamento ao vivo e contexto estrito da rota ativa.
begin;

create or replace function public.vuppi_delivery_tracking(p_delivery uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();adm boolean:=public.up_platform_is_admin();d public.vuppi_deliveries;merchant public.vuppi_members;courier public.vuppi_members;city_name text;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.';end if;
 select * into d from public.vuppi_deliveries where id=p_delivery;
 if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.';end if;
 if not adm and uid<>d.merchant and uid is distinct from d.courier then raise exception 'UP_CAR: Acesso negado aos dados desta entrega.';end if;
 select * into merchant from public.vuppi_members where user_id=d.merchant;
 if d.courier is not null then select * into courier from public.vuppi_members where user_id=d.courier;end if;
 select nome into city_name from public.up_cidades where id=d.city;
 return jsonb_build_object(
  'delivery_id',d.id,'status',d.status,'pickup_arrived_at',d.pickup_arrived_at,
  'route_group_id',d.route_group_id,'route_sequence',d.route_sequence,
  'merchant_id',d.merchant,'merchant_name',d.merchant_name,'merchant_phone',merchant.phone,'pickup_address',d.pickup_address,'pickup_city',coalesce(city_name,merchant.city),
  'pickup_lat',d.pickup_lat,'pickup_lng',d.pickup_lng,'destination',d.destination,'destination_lat',d.lat,'destination_lng',d.lng,
  'recipient',d.recipient,'recipient_phone',d.phone,
  'courier_id',d.courier,'courier_name',courier.name,'courier_phone',courier.phone,'courier_avatar',courier.avatar_data,'courier_vehicle_model',courier.vehicle_model,'courier_vehicle_plate',courier.vehicle_plate,
  'courier_lat',courier.lat,'courier_lng',courier.lng,'courier_updated_at',courier.last_active_at,'updated_at',d.updated_at
 );
end;$$;

revoke all on function public.vuppi_delivery_tracking(uuid) from public,anon;
grant execute on function public.vuppi_delivery_tracking(uuid) to authenticated;

commit;
