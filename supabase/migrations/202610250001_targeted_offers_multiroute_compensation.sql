-- Vuppi Delivery 0.80.0: oferta direcionada com aceite, rotas agrupadas e repasse individual.
begin;

alter table public.vuppi_deliveries
 add column if not exists preferred_courier uuid references auth.users(id),
 add column if not exists preferred_offered_at timestamptz,
 add column if not exists preferred_offer_expires_at timestamptz;
alter table public.vuppi_members
 add column if not exists courier_share_bps_override integer check(courier_share_bps_override between 0 and 10000);
create index if not exists vuppi_deliveries_targeted_offer_idx on public.vuppi_deliveries(preferred_courier,preferred_offer_expires_at) where status='requested' and preferred_courier is not null;

create or replace function public.vuppi_courier_compensation(p_courier uuid,p_city text,p_price integer) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare city_share integer:=8500;override_share integer;effective_share integer;courier_cents integer;
begin
 select courier_share_bps into city_share from public.vuppi_finance_settings where city=p_city;
 select courier_share_bps_override into override_share from public.vuppi_members where user_id=p_courier and kind='courier';
 effective_share:=greatest(0,least(10000,coalesce(override_share,city_share,8500)));
 courier_cents:=floor(greatest(0,p_price)*effective_share::numeric/10000);
 return jsonb_build_object('courier_share_bps',effective_share,'courier_cents',courier_cents,'platform_cents',greatest(0,p_price-courier_cents),'override',override_share is not null);
end;$$;

create or replace function public.vuppi_courier_financial_rules() returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();m public.vuppi_members;cfg public.vuppi_finance_settings;share integer;
begin
 select * into m from public.vuppi_members where user_id=uid and kind='courier' and approved;
 if m.user_id is null then raise exception 'VUPPI_FINANCE: Perfil de entregador não encontrado.';end if;
 insert into public.vuppi_finance_settings(city) values(m.city) on conflict do nothing;
 select * into cfg from public.vuppi_finance_settings where city=m.city;
 share:=coalesce(m.courier_share_bps_override,cfg.courier_share_bps,8500);
 return jsonb_build_object('courier_share_bps',share,'vuppi_share_bps',10000-share,'city',m.city,'individual_override',m.courier_share_bps_override is not null);
end;$$;

create or replace function public.vuppi_courier_finance_admin(p_courier uuid,p_share_bps integer default null,p_reason text default null) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare before_share integer;city_share integer;result public.vuppi_members;
begin
 if not public.up_platform_is_admin() then raise exception 'VUPPI_FINANCE: Acesso exclusivo da administração.';end if;
 if p_share_bps is not null and (p_share_bps<0 or p_share_bps>10000) then raise exception 'VUPPI_FINANCE: Percentual individual inválido.';end if;
 if length(trim(coalesce(p_reason,'')))<3 then raise exception 'VUPPI_FINANCE: Informe o motivo da alteração.';end if;
 select courier_share_bps_override into before_share from public.vuppi_members where user_id=p_courier and kind='courier' for update;
 update public.vuppi_members set courier_share_bps_override=p_share_bps,updated_at=now() where user_id=p_courier and kind='courier' returning * into result;
 if result.user_id is null then raise exception 'VUPPI_FINANCE: Entregador não encontrado.';end if;
 select courier_share_bps into city_share from public.vuppi_finance_settings where city=result.city;
 insert into public.up_platform_audit(actor_id,action,target,reason,details) values(auth.uid(),'courier_finance_override',p_courier::text,p_reason,jsonb_build_object('before_share_bps',before_share,'after_share_bps',p_share_bps,'city_share_bps',city_share));
 return jsonb_build_object('ok',true,'courier_id',p_courier,'courier_share_bps',coalesce(p_share_bps,city_share,8500),'individual_override',p_share_bps is not null,'vuppi_share_bps',10000-coalesce(p_share_bps,city_share,8500));
end;$$;

create or replace function public.vuppi_delivery_state() returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();result jsonb;visible_offers jsonb;m public.vuppi_members;radius_km numeric:=15;has_active boolean:=false;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.';end if;
 result:=public.vuppi_delivery('state','{}'::jsonb);
 select * into m from public.vuppi_members where user_id=uid;
 select coalesce(offer_radius_km,15) into radius_km from public.vuppi_operation_settings where id='default';
 select exists(select 1 from public.vuppi_deliveries where courier=uid and status in('assigned','collected')) into has_active;
 if m.kind='courier' and m.approved and m.member_status='active' and (m.is_available or has_active) then
  select coalesce(jsonb_agg(to_jsonb(x) order by x.targeted_offer desc,coalesce(x.route_group_id,x.id),x.route_sequence nulls first,x.created_at),'[]'::jsonb) into visible_offers from(
   select d.id,d.city,d.merchant,d.merchant_name,d.pickup_address,d.destination,d.recipient,d.phone,d.notes,d.distance_m,d.price_cents,d.return_required,d.route_group_id,d.route_sequence,d.created_at,d.preferred_courier,d.preferred_offer_expires_at,
    (d.preferred_courier=uid) targeted_offer,
    count(*)over(partition by coalesce(d.route_group_id,d.id))::int route_stop_count,
    sum(d.price_cents)over(partition by coalesce(d.route_group_id,d.id))::int route_total_cents,
    (select jsonb_agg(jsonb_build_object('id',s.id,'sequence',coalesce(s.route_sequence,1),'pickup_address',s.pickup_address,'destination',s.destination,'recipient',s.recipient,'notes',s.notes,'price_cents',s.price_cents) order by coalesce(s.route_sequence,1),s.created_at) from public.vuppi_deliveries s where s.status in('requested','pending') and (s.id=d.id or (d.route_group_id is not null and s.route_group_id=d.route_group_id))) route_stops
   from public.vuppi_deliveries d where d.status='requested' and d.city=m.city and coalesce(d.dispatch_at,d.scheduled_for,d.created_at)<=now()
    and (d.preferred_courier is null or (d.preferred_courier=uid and d.preferred_offer_expires_at>now()))
    and (not has_active or d.preferred_courier=uid)
    and not exists(select 1 from public.vuppi_delivery_offer_decisions od where od.delivery_id=d.id and od.courier_id=uid)
    and (d.preferred_courier=uid or m.lat is null or m.lng is null or d.pickup_lat is null or d.pickup_lng is null or 6371*2*asin(sqrt(power(sin(radians(d.pickup_lat-m.lat)/2),2)+cos(radians(m.lat))*cos(radians(d.pickup_lat))*power(sin(radians(d.pickup_lng-m.lng)/2),2)))<=radius_km)
   limit 100
  )x;
 else visible_offers:='[]'::jsonb;end if;
 return jsonb_set(result,'{offers}',visible_offers,true);
end;$$;

create or replace function public.vuppi_accept_delivery_offer(p_delivery uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();d public.vuppi_deliveries;m public.vuppi_members;cfg public.vuppi_operation_settings;active_route public.vuppi_deliveries;ids uuid[];accepted_count integer;distance_km double precision;source text;group_id uuid;next_sequence integer;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_delivery::text,0));
 select * into m from public.vuppi_members where user_id=uid for update;
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 select * into cfg from public.vuppi_operation_settings where id='default';
 select * into active_route from public.vuppi_deliveries where courier=uid and status in('assigned','collected') order by route_sequence nulls last,created_at limit 1 for update;
 if m.user_id is null or m.kind<>'courier' or not m.approved or m.member_status<>'active' or (not m.is_available and active_route.id is null) then raise exception 'UP_CAR: Entregador indisponível.';end if;
 if d.id is null or d.status not in('requested','pending') or d.courier is not null or d.city<>m.city then raise exception 'UP_CAR: Solicitação já aceita ou indisponível.';end if;
 if d.preferred_courier is not null and d.preferred_courier<>uid then raise exception 'UP_CAR: Esta oferta foi enviada para outro entregador.';end if;
 if d.preferred_courier=uid and d.preferred_offer_expires_at<=now() then raise exception 'UP_CAR: O prazo desta oferta direcionada terminou.';end if;
 if active_route.id is not null and d.preferred_courier is null then raise exception 'UP_CAR: Conclua sua rota atual antes de aceitar outra.';end if;
 if d.status='pending' then
  if m.lat is null or m.lng is null then raise exception 'UP_CAR: Atualize sua localização para aceitar esta pendência.';end if;
  distance_km:=6371*2*asin(sqrt(power(sin(radians(d.pickup_lat-m.lat)/2),2)+cos(radians(m.lat))*cos(radians(d.pickup_lat))*power(sin(radians(d.pickup_lng-m.lng)/2),2)));
  if distance_km>coalesce(cfg.pending_accept_radius_km,20) then raise exception 'UP_CAR: Você está fora do raio máximo para aceitar esta pendência.';end if;
 end if;
 select array_agg(x.id order by coalesce(x.route_sequence,1),x.created_at) into ids from public.vuppi_deliveries x where x.status in('requested','pending') and (x.id=d.id or (d.route_group_id is not null and x.route_group_id=d.route_group_id)) and (x.preferred_courier is null or x.preferred_courier=uid);
 if exists(select 1 from public.vuppi_delivery_offer_decisions od where od.courier_id=uid and od.delivery_id=any(ids)) then raise exception 'UP_CAR: Uma entrega desta rota já foi recusada por você.';end if;
 source:=case when d.preferred_courier=uid then 'merchant_targeted_offer' when d.status='pending' then 'pending_list' when d.pending_since is not null then 'pending_resend' else 'dispatch_offer' end;
 if active_route.id is not null then
  group_id:=coalesce(active_route.route_group_id,gen_random_uuid());
  if active_route.route_group_id is null then update public.vuppi_deliveries set route_group_id=group_id,route_sequence=1,updated_at=now() where id=active_route.id;end if;
  select coalesce(max(route_sequence),0) into next_sequence from public.vuppi_deliveries where route_group_id=group_id;
  update public.vuppi_deliveries set courier=uid,status='assigned',route_group_id=group_id,route_sequence=next_sequence+q.seq,accepted_from=source,updated_at=now() from(select id,row_number()over(order by coalesce(route_sequence,1),created_at)::int seq from public.vuppi_deliveries where id=any(ids))q where vuppi_deliveries.id=q.id and vuppi_deliveries.status in('requested','pending') and vuppi_deliveries.courier is null;
 else
  update public.vuppi_deliveries set courier=uid,status='assigned',accepted_from=source,updated_at=now() where id=any(ids) and status in('requested','pending') and courier is null;
 end if;
 get diagnostics accepted_count=row_count;
 if accepted_count<>array_length(ids,1) then raise exception 'UP_CAR: Solicitação já aceita por outro entregador.';end if;
 update public.vuppi_members set is_available=false,updated_at=now() where user_id=uid;
 insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details) select x,uid,'route_accepted',jsonb_build_object('route_group_id',coalesce(group_id,d.route_group_id),'count',accepted_count,'accepted_from',source,'distance_km',distance_km) from unnest(ids)x;
 return jsonb_build_object('ok',true,'delivery_id',d.id,'accepted_ids',to_jsonb(ids),'count',accepted_count,'accepted_from',source,'route_group_id',coalesce(group_id,d.route_group_id));
end;$$;

create or replace function public.vuppi_reject_delivery_offer(p_delivery uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();d public.vuppi_deliveries;m public.vuppi_members;ids uuid[];inserted_count integer;targeted boolean;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_delivery::text,0));
 select * into m from public.vuppi_members where user_id=uid;
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 if m.user_id is null or m.kind<>'courier' or not m.approved then raise exception 'UP_CAR: Apenas entregadores aprovados podem recusar ofertas.';end if;
 if d.id is null or d.status<>'requested' or d.city<>m.city or (d.preferred_courier is not null and d.preferred_courier<>uid) then raise exception 'UP_CAR: Oferta não encontrada para este entregador.';end if;
 targeted:=d.preferred_courier=uid;
 select array_agg(x.id) into ids from public.vuppi_deliveries x where x.status='requested' and (x.id=d.id or (d.route_group_id is not null and x.route_group_id=d.route_group_id)) and (x.preferred_courier is null or x.preferred_courier=uid);
 insert into public.vuppi_delivery_offer_decisions(delivery_id,courier_id,decision) select x,uid,'rejected' from unnest(ids)x on conflict(delivery_id,courier_id) do nothing;
 get diagnostics inserted_count=row_count;
 if targeted then
  update public.vuppi_deliveries set status='unattended',pending_reason='targeted_offer_rejected',updated_at=now() where id=any(ids) and status='requested';
  insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details) select x,uid,'targeted_offer_unattended',jsonb_build_object('reason','rejected','courier_id',uid) from unnest(ids)x;
 end if;
 insert into public.up_platform_audit(actor_id,action,target,reason,details) values(uid,case when targeted then 'targeted_offer_reject' else 'delivery_route_reject' end,coalesce(d.route_group_id,d.id)::text,'Oferta recusada pelo entregador',jsonb_build_object('deliveries',ids,'count',inserted_count,'targeted',targeted));
 return jsonb_build_object('ok',true,'delivery_id',d.id,'route_group_id',d.route_group_id,'rejected_ids',to_jsonb(ids),'count',inserted_count,'unattended',targeted);
end;$$;

create or replace function public.vuppi_pending_maintenance() returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare cfg public.vuppi_operation_settings;row record;transitioned integer:=0;expired integer:=0;resent integer:=0;targeted_expired integer:=0;
begin
 if coalesce(auth.role(),'')<>'service_role' and not public.up_platform_is_admin() then raise exception 'UP_CAR: Manutenção de pendências não autorizada.';end if;
 select * into cfg from public.vuppi_operation_settings where id='default';
 for row in update public.vuppi_deliveries set status='unattended',pending_reason='targeted_offer_expired',updated_at=now() where status='requested' and courier is null and preferred_courier is not null and preferred_offer_expires_at<=now() returning id,preferred_courier loop
  insert into public.vuppi_delivery_events(delivery_id,event_type,details) values(row.id,'targeted_offer_unattended',jsonb_build_object('reason','expired','courier_id',row.preferred_courier));targeted_expired:=targeted_expired+1;
 end loop;
 for row in select d.id from public.vuppi_deliveries d where d.status='requested' and d.courier is null and d.preferred_courier is null and coalesce(d.dispatch_at,d.scheduled_for,d.created_at)<=now() and now()>=coalesce(d.dispatch_at,d.scheduled_for,d.created_at)+make_interval(secs=>greatest(15,coalesce(cfg.pending_after_seconds,90))) order by coalesce(d.dispatch_at,d.created_at) for update skip locked loop
  perform public.vuppi_transition_delivery_pending(row.id,'dispatch_cycle_exhausted',jsonb_build_object('source','maintenance'));transitioned:=transitioned+1;
 end loop;
 for row in update public.vuppi_deliveries set status='unattended',updated_at=now() where status='pending' and courier is null and pending_expires_at<=now() returning id,pending_since,pending_expires_at loop
  insert into public.vuppi_delivery_events(delivery_id,event_type,details) values(row.id,'status_unattended',jsonb_build_object('from_status','pending','to_status','unattended','reason','pending_expired','pending_since',row.pending_since,'pending_expires_at',row.pending_expires_at));expired:=expired+1;
 end loop;
 if coalesce(cfg.enable_pending_auto_resend,true) then
  for row in update public.vuppi_deliveries set pending_retry_count=pending_retry_count+1,last_dispatch_at=now(),updated_at=now() where status='pending' and courier is null and pending_retry_count<greatest(0,coalesce(cfg.pending_max_resends,3)) and now()>=coalesce(last_dispatch_at,pending_since)+make_interval(secs=>greatest(15,coalesce(cfg.pending_resend_after_seconds,60))) and pending_expires_at>now() returning id,pending_retry_count loop
   insert into public.vuppi_delivery_events(delivery_id,event_type,details) values(row.id,'pending_resend',jsonb_build_object('retry',row.pending_retry_count,'source','automatic'));resent:=resent+1;
  end loop;
 end if;
 return jsonb_build_object('ok',true,'transitioned',transitioned,'expired',expired,'resent',resent,'targeted_expired',targeted_expired,'checked_at',now());
end;$$;

revoke all on function public.vuppi_courier_compensation(uuid,text,integer),public.vuppi_courier_finance_admin(uuid,integer,text) from public,anon,authenticated;
grant execute on function public.vuppi_courier_compensation(uuid,text,integer) to service_role;
grant execute on function public.vuppi_courier_finance_admin(uuid,integer,text) to authenticated;
revoke all on function public.vuppi_delivery_state(),public.vuppi_accept_delivery_offer(uuid),public.vuppi_reject_delivery_offer(uuid) from public,anon;
grant execute on function public.vuppi_delivery_state(),public.vuppi_accept_delivery_offer(uuid),public.vuppi_reject_delivery_offer(uuid) to authenticated;
revoke all on function public.vuppi_pending_maintenance() from public,anon,authenticated;
grant execute on function public.vuppi_pending_maintenance() to service_role;
commit;
