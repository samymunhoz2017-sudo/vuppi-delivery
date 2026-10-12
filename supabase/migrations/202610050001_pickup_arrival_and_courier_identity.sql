begin;

alter table public.vuppi_deliveries add column if not exists pickup_arrived_at timestamptz;

create or replace function public.vuppi_delivery_pickup_arrive(p_delivery uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); d public.vuppi_deliveries;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.'; end if;
 if d.courier is distinct from uid or d.status<>'assigned' then raise exception 'UP_CAR: Esta etapa não está disponível para esta entrega.'; end if;
 if d.pickup_arrived_at is null then
  update public.vuppi_deliveries set pickup_arrived_at=now(),updated_at=now() where id=d.id;
  insert into public.up_platform_audit(actor_id,action,target,reason,details)
   values(uid,'delivery_pickup_arrived',d.id::text,'Entregador chegou ao estabelecimento',jsonb_build_object('city',d.city));
 end if;
 return jsonb_build_object('ok',true,'pickup_arrived_at',coalesce(d.pickup_arrived_at,now()));
end;$$;
revoke all on function public.vuppi_delivery_pickup_arrive(uuid) from public,anon;
grant execute on function public.vuppi_delivery_pickup_arrive(uuid) to authenticated;

create or replace function public.vuppi_delivery_tracking(p_delivery uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); adm boolean:=public.up_platform_is_admin(); d public.vuppi_deliveries; merchant public.vuppi_members; courier public.vuppi_members; city_name text;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 select * into d from public.vuppi_deliveries where id=p_delivery;
 if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.'; end if;
 if not adm and uid<>d.merchant and uid is distinct from d.courier then raise exception 'UP_CAR: Acesso negado aos dados desta entrega.'; end if;
 select * into merchant from public.vuppi_members where user_id=d.merchant;
 if d.courier is not null then select * into courier from public.vuppi_members where user_id=d.courier; end if;
 select nome into city_name from public.up_cidades where id=d.city;
 return jsonb_build_object(
  'delivery_id',d.id,'status',d.status,'pickup_arrived_at',d.pickup_arrived_at,
  'merchant_name',d.merchant_name,'merchant_phone',merchant.phone,'pickup_address',d.pickup_address,'pickup_city',coalesce(city_name,merchant.city),
  'pickup_lat',d.pickup_lat,'pickup_lng',d.pickup_lng,'destination',d.destination,'destination_lat',d.lat,'destination_lng',d.lng,
  'recipient',d.recipient,'recipient_phone',d.phone,
  'courier_name',courier.name,'courier_phone',courier.phone,'courier_avatar',courier.avatar_data,'courier_vehicle_model',courier.vehicle_model,'courier_vehicle_plate',courier.vehicle_plate,
  'courier_lat',courier.lat,'courier_lng',courier.lng,'courier_updated_at',courier.last_active_at,'updated_at',d.updated_at
 );
end;$$;
revoke all on function public.vuppi_delivery_tracking(uuid) from public,anon;
grant execute on function public.vuppi_delivery_tracking(uuid) to authenticated;

commit;

create or replace function public.vuppi_require_pickup_arrival() returns trigger
language plpgsql set search_path=public,pg_temp as $$
begin
 if old.status='assigned' and new.status='collected' and old.pickup_arrived_at is null then
  raise exception 'UP_CAR: Confirme primeiro que chegou ao estabelecimento.';
 end if;
 return new;
end;$$;
drop trigger if exists vuppi_require_pickup_arrival_trigger on public.vuppi_deliveries;
create trigger vuppi_require_pickup_arrival_trigger before update of status on public.vuppi_deliveries
for each row execute function public.vuppi_require_pickup_arrival();
revoke all on function public.vuppi_require_pickup_arrival() from public,anon,authenticated;
