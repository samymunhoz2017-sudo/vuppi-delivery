-- Vuppi Delivery 0.80.0: gestão da oferta direcionada e liquidação pelo percentual individual.
begin;

create or replace function public.vuppi_merchant_manage_delivery(p_action text,p_delivery uuid default null,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();merchant public.vuppi_members;d public.vuppi_deliveries;rider public.vuppi_members;active_route public.vuppi_deliveries;ids uuid[];group_id uuid:=gen_random_uuid();requested_at timestamptz;lead integer;assigned_count integer;offer_seconds integer:=60;
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
  if exists(select 1 from unnest(ids)x left join public.vuppi_deliveries v on v.id=x where v.id is null or v.merchant<>uid or v.status not in('requested','assigned','collected')) then raise exception 'UP_CAR: Uma das entregas não pode ser agrupada.';end if;
  select count(distinct courier) into assigned_count from public.vuppi_deliveries where id=any(ids) and courier is not null;if assigned_count>1 then raise exception 'UP_CAR: Não é possível juntar entregas de entregadores diferentes.';end if;
  select route_group_id into group_id from public.vuppi_deliveries where id=any(ids) and route_group_id is not null limit 1;group_id:=coalesce(group_id,gen_random_uuid());
  update public.vuppi_deliveries set route_group_id=group_id,route_sequence=x.seq,updated_at=now() from(select id,row_number()over(order by case status when 'collected' then 0 when 'assigned' then 1 else 2 end,coalesce(scheduled_for,created_at),created_at)::int seq from public.vuppi_deliveries where id=any(ids))x where vuppi_deliveries.id=x.id;
  insert into public.up_platform_audit(actor_id,action,target,reason,details) values(uid,'delivery_join',group_id::text,'Rotas agrupadas pelo estabelecimento',jsonb_build_object('deliveries',ids));return jsonb_build_object('ok',true,'route_group_id',group_id,'count',array_length(ids,1));
 end if;
 select * into d from public.vuppi_deliveries where id=p_delivery and vuppi_deliveries.merchant=uid for update;if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.';end if;
 if p_action='assign' then
  if d.status not in('requested','pending','unattended') or d.courier is not null then raise exception 'UP_CAR: Esta entrega não está disponível para oferta.';end if;
  select * into rider from public.vuppi_members where user_id=(p_data->>'courier')::uuid for update;
  select * into active_route from public.vuppi_deliveries where courier=rider.user_id and status in('assigned','collected') order by route_sequence nulls last,created_at limit 1;
  if rider.user_id is null or rider.kind<>'courier' or not rider.approved or rider.member_status<>'active' or rider.city<>d.city or coalesce(rider.last_active_at,rider.updated_at)<=now()-interval '5 minutes' or(not rider.is_available and active_route.id is null) then raise exception 'UP_CAR: Entregador não está online ou compatível.';end if;
  offer_seconds:=greatest(20,least(180,coalesce(nullif(p_data->>'offer_seconds','')::integer,60)));
  update public.vuppi_deliveries set status='requested',courier=null,preferred_courier=rider.user_id,preferred_offered_at=now(),preferred_offer_expires_at=now()+make_interval(secs=>offer_seconds),pending_since=null,pending_expires_at=null,pending_reason=null,dispatch_at=now(),last_dispatch_at=now(),accepted_from=null,updated_at=now() where id=d.id returning * into d;
  delete from public.vuppi_delivery_offer_decisions where delivery_id=d.id and courier_id=rider.user_id;
  insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details) values(d.id,uid,'merchant_targeted_offer',jsonb_build_object('courier_id',rider.user_id,'expires_at',d.preferred_offer_expires_at,'courier_in_route',active_route.id is not null));
  return jsonb_build_object('ok',true,'offered',true,'delivery_id',d.id,'courier_id',rider.user_id,'expires_at',d.preferred_offer_expires_at,'courier_in_route',active_route.id is not null);
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

create or replace function public.vuppi_reconcile_delivered_price(p_delivery public.vuppi_deliveries,p_new_price integer,p_reason text) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare mw uuid;cw uuid;pw uuid;merchant_available uuid;courier_available uuid;platform_available uuid;desired_courier bigint;desired_platform bigint;dc bigint;dp bigint;revision integer:=p_delivery.financial_revision+1;comp jsonb;
begin
 if p_delivery.status<>'delivered' or p_delivery.courier is null then return;end if;
 comp:=public.vuppi_courier_compensation(p_delivery.courier,p_delivery.city,p_new_price);desired_courier:=(comp->>'courier_cents')::bigint;desired_platform:=(comp->>'platform_cents')::bigint;
 cw:=public.vuppi_wallet_ensure('courier',p_delivery.courier,p_delivery.city,'delivery');pw:=public.vuppi_wallet_ensure('platform',null,p_delivery.city,'delivery');select id into courier_available from public.vuppi_wallet_accounts where wallet_id=cw and bucket='available';select id into platform_available from public.vuppi_wallet_accounts where wallet_id=pw and bucket='available';
 if p_delivery.payment_method='wallet' then
  mw:=public.vuppi_wallet_ensure('merchant',p_delivery.merchant,p_delivery.city,'delivery');select id into merchant_available from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available';dc:=desired_courier-p_delivery.financial_applied_courier_cents;dp:=desired_platform-p_delivery.financial_applied_platform_cents;
  if dc>0 then perform public.vuppi_post_reconciliation('delivery_courier_adjustment',p_delivery,dc,merchant_available,courier_available,'delivery-reconcile-courier:'||p_delivery.id||':'||revision,'Ajuste do repasse da OS',p_reason);elsif dc<0 then perform public.vuppi_post_reconciliation('delivery_courier_reversal',p_delivery,-dc,courier_available,merchant_available,'delivery-reconcile-courier:'||p_delivery.id||':'||revision,'Estorno do repasse da OS',p_reason);end if;
  if dp>0 then perform public.vuppi_post_reconciliation('delivery_platform_adjustment',p_delivery,dp,merchant_available,platform_available,'delivery-reconcile-platform:'||p_delivery.id||':'||revision,'Ajuste da receita da OS',p_reason);elsif dp<0 then perform public.vuppi_post_reconciliation('delivery_platform_reversal',p_delivery,-dp,platform_available,merchant_available,'delivery-reconcile-platform:'||p_delivery.id||':'||revision,'Estorno da receita da OS',p_reason);end if;
 else dp:=desired_platform-p_delivery.financial_applied_platform_cents;if dp>0 then perform public.vuppi_post_reconciliation('cash_platform_adjustment',p_delivery,dp,courier_available,platform_available,'delivery-reconcile-cash:'||p_delivery.id||':'||revision,'Ajuste da taxa da OS em dinheiro',p_reason);elsif dp<0 then perform public.vuppi_post_reconciliation('cash_platform_reversal',p_delivery,-dp,platform_available,courier_available,'delivery-reconcile-cash:'||p_delivery.id||':'||revision,'Estorno da taxa da OS em dinheiro',p_reason);end if;end if;
 update public.vuppi_deliveries set price_cents=p_new_price,courier_net_cents=desired_courier,financial_applied_price_cents=p_new_price,financial_applied_courier_cents=desired_courier,financial_applied_platform_cents=desired_platform,financial_revision=revision,updated_at=now() where id=p_delivery.id;
end;$$;

create or replace function public.vuppi_delivery_wallet_sync() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare mw uuid;cw uuid;pw uuid;share bigint;margin bigint;cfg public.vuppi_finance_settings;reserve_exists boolean;comp jsonb;
begin
 if tg_op='INSERT' and new.payment_method<>'wallet' then return new;end if;
 insert into public.vuppi_finance_settings(city) values(new.city) on conflict do nothing;select * into cfg from public.vuppi_finance_settings where city=new.city;
 if tg_op='UPDATE' and old.payment_method<>'wallet' and new.payment_method<>'wallet' then
  if old.status is distinct from new.status and new.status='delivered' and new.payment_method='cash' then comp:=public.vuppi_courier_compensation(new.courier,new.city,new.price_cents);share:=(comp->>'courier_cents')::bigint;margin:=(comp->>'platform_cents')::bigint;perform public.vuppi_post_cash_platform_fee(new,margin);update public.vuppi_deliveries set courier_net_cents=share,financial_applied_price_cents=new.price_cents,financial_applied_courier_cents=share,financial_applied_platform_cents=margin where id=new.id;end if;return new;
 end if;
 mw:=public.vuppi_wallet_ensure('merchant',new.merchant,new.city,'delivery');pw:=public.vuppi_wallet_ensure('platform',null,new.city,'delivery');
 if tg_op='INSERT' or(tg_op='UPDATE' and old.payment_method<>'wallet' and new.payment_method='wallet') then perform public.vuppi_post_transaction('delivery_reserve',new.city,new.price_cents,(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),'delivery-reserve:'||new.id,'Reserva da OS',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant));
 elsif tg_op='UPDATE' and old.status is distinct from new.status and new.status='cancelled' and new.payment_method='wallet' then perform public.vuppi_post_transaction('delivery_release',new.city,new.price_cents,(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),'delivery-release:'||new.id,'Liberação por cancelamento',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant));
 elsif tg_op='UPDATE' and old.status is distinct from new.status and new.status='delivered' and new.payment_method='wallet' then
  cw:=public.vuppi_wallet_ensure('courier',new.courier,new.city,'delivery');comp:=public.vuppi_courier_compensation(new.courier,new.city,new.price_cents);share:=(comp->>'courier_cents')::bigint;margin:=(comp->>'platform_cents')::bigint;select exists(select 1 from public.vuppi_financial_transactions where city=new.city and idempotency_key='delivery-reserve:'||new.id) into reserve_exists;
  if not reserve_exists then perform public.vuppi_post_transaction('delivery_reserve',new.city,new.price_cents,(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),'delivery-reserve:'||new.id,'Reserva reconciliada',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant));end if;
  if share>0 then perform public.vuppi_post_transaction('delivery_courier_credit',new.city,share,(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),(select id from public.vuppi_wallet_accounts where wallet_id=cw and bucket=case when cfg.courier_release_delay_minutes>0 then 'pending'::public.vuppi_balance_bucket else 'available'::public.vuppi_balance_bucket end),'delivery-courier:'||new.id,'Crédito da entrega',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant,'courier_id',new.courier,'courier_share_bps',comp->>'courier_share_bps','individual_override',comp->>'override'));end if;
  if margin>0 then perform public.vuppi_post_transaction('delivery_platform_revenue',new.city,margin,(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),(select id from public.vuppi_wallet_accounts where wallet_id=pw and bucket='available'),'delivery-margin:'||new.id,'Receita da entrega',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant,'courier_id',new.courier));end if;
  update public.vuppi_deliveries set courier_net_cents=share,financial_applied_price_cents=new.price_cents,financial_applied_courier_cents=share,financial_applied_platform_cents=margin where id=new.id;
 end if;return new;
end;$$;

revoke all on function public.vuppi_merchant_manage_delivery(text,uuid,jsonb) from public,anon;grant execute on function public.vuppi_merchant_manage_delivery(text,uuid,jsonb) to authenticated;
revoke all on function public.vuppi_reconcile_delivered_price(public.vuppi_deliveries,integer,text),public.vuppi_delivery_wallet_sync() from public,anon,authenticated;
commit;
