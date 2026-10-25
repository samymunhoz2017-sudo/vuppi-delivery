-- VUPPI 0.79: pendências online, rotas incrementais do lojista e Payouts Pix.
begin;

-- Uma rota pode conter várias OSs do mesmo entregador. A trava anterior por
-- entregador impedia o agrupamento que a interface já oferecia.
drop index if exists public.vuppi_one_active_delivery;

create or replace function public.vuppi_validate_courier_active_route() returns trigger
language plpgsql set search_path=public,pg_temp as $$
begin
 if new.courier is null or new.status not in('assigned','collected') then return new;end if;
 if exists(
  select 1 from public.vuppi_deliveries d
  where d.courier=new.courier and d.id<>new.id and d.status in('assigned','collected')
   and (new.route_group_id is null or d.route_group_id is distinct from new.route_group_id)
 ) then raise exception 'UP_CAR: Entregador já possui outra rota em andamento.';end if;
 return new;
end;$$;
drop trigger if exists vuppi_validate_courier_active_route_trigger on public.vuppi_deliveries;
create trigger vuppi_validate_courier_active_route_trigger before insert or update of courier,status,route_group_id
on public.vuppi_deliveries for each row execute function public.vuppi_validate_courier_active_route();

create table if not exists public.vuppi_merchant_courier_favorites(
 merchant_id uuid not null references auth.users(id) on delete cascade,
 courier_id uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default now(),
 primary key(merchant_id,courier_id)
);
alter table public.vuppi_merchant_courier_favorites enable row level security;
revoke all on public.vuppi_merchant_courier_favorites from anon,authenticated;

create or replace function public.vuppi_merchant_manage_delivery(p_action text,p_delivery uuid default null,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); merchant public.vuppi_members; d public.vuppi_deliveries; rider public.vuppi_members; active_route public.vuppi_deliveries; ids uuid[]; group_id uuid:=gen_random_uuid(); requested_at timestamptz; lead integer; assigned_count integer; next_sequence integer;
begin
 if uid is null then raise exception 'UP_CAR: Entre para continuar.';end if;
 select * into merchant from public.vuppi_members where user_id=uid and kind='merchant' and approved and member_status='active';
 if merchant.user_id is null then raise exception 'UP_CAR: Acesso exclusivo do estabelecimento aprovado.';end if;
 if p_action='couriers' then
  if p_delivery is not null then select * into d from public.vuppi_deliveries where id=p_delivery and vuppi_deliveries.merchant=uid;if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.';end if;end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'user_id',m.user_id,'name',m.name,'is_available',m.is_available,'online',m.updated_at>now()-interval '10 minutes',
    'favorite',f.courier_id is not null,'active_delivery_id',a.id,'active_route_group_id',a.route_group_id,
    'active_status',a.status,'avatar_data',m.avatar_data,'vehicle_model',m.vehicle_model,'vehicle_plate',m.vehicle_plate
   ) order by (f.courier_id is not null) desc,(a.id is null) desc,m.is_available desc,m.name)
   from public.vuppi_members m
   left join public.vuppi_merchant_courier_favorites f on f.merchant_id=uid and f.courier_id=m.user_id
   left join lateral(select x.id,x.route_group_id,x.status from public.vuppi_deliveries x where x.courier=m.user_id and x.status in('assigned','collected') order by x.route_sequence nulls last,x.created_at limit 1)a on true
   where m.kind='courier' and m.approved and m.member_status='active' and m.city=coalesce(d.city,merchant.city)
    and (m.is_available or a.id is not null) and m.updated_at>now()-interval '10 minutes'),'[]'::jsonb);
 end if;
 if p_action='favorite' then
  select * into rider from public.vuppi_members where user_id=(p_data->>'courier')::uuid and kind='courier' and approved and city=merchant.city;
  if rider.user_id is null then raise exception 'UP_CAR: Entregador não encontrado nesta cidade.';end if;
  if coalesce((p_data->>'favorite')::boolean,true) then insert into public.vuppi_merchant_courier_favorites(merchant_id,courier_id) values(uid,rider.user_id) on conflict do nothing;
  else delete from public.vuppi_merchant_courier_favorites where merchant_id=uid and courier_id=rider.user_id;end if;
  return jsonb_build_object('ok',true,'favorite',coalesce((p_data->>'favorite')::boolean,true));
 end if;
 if p_action='join' then
  select array_agg(value::uuid) into ids from jsonb_array_elements_text(coalesce(p_data->'ids','[]'::jsonb));
  if coalesce(array_length(ids,1),0)<2 then raise exception 'UP_CAR: Selecione pelo menos duas entregas.';end if;
  if exists(select 1 from unnest(ids)x left join public.vuppi_deliveries v on v.id=x where v.id is null or v.merchant<>uid or v.status not in('requested','assigned','collected')) then raise exception 'UP_CAR: Uma das entregas não pode ser agrupada.';end if;
  select count(distinct courier) into assigned_count from public.vuppi_deliveries where id=any(ids) and courier is not null;
  if assigned_count>1 then raise exception 'UP_CAR: Não é possível juntar entregas de entregadores diferentes.';end if;
  select route_group_id into group_id from public.vuppi_deliveries where id=any(ids) and route_group_id is not null limit 1;
  group_id:=coalesce(group_id,gen_random_uuid());
  update public.vuppi_deliveries set route_group_id=group_id,route_sequence=x.seq,updated_at=now()
  from(select id,row_number()over(order by case status when 'collected' then 0 when 'assigned' then 1 else 2 end,coalesce(scheduled_for,created_at),created_at)::int seq from public.vuppi_deliveries where id=any(ids))x where vuppi_deliveries.id=x.id;
  insert into public.up_platform_audit(actor_id,action,target,reason,details) values(uid,'delivery_join',group_id::text,'Rotas agrupadas pelo estabelecimento',jsonb_build_object('deliveries',ids));
  return jsonb_build_object('ok',true,'route_group_id',group_id,'count',array_length(ids,1));
 end if;
 select * into d from public.vuppi_deliveries where id=p_delivery and vuppi_deliveries.merchant=uid for update;
 if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.';end if;
 if p_action='assign' then
  if d.status not in('requested','pending') or d.courier is not null then raise exception 'UP_CAR: Esta entrega não está disponível para atribuição.';end if;
  select * into rider from public.vuppi_members where user_id=(p_data->>'courier')::uuid for update;
  select * into active_route from public.vuppi_deliveries where courier=rider.user_id and status in('assigned','collected') order by route_sequence nulls last,created_at limit 1 for update;
  if rider.user_id is null or rider.kind<>'courier' or not rider.approved or rider.member_status<>'active' or rider.city<>d.city or rider.updated_at<=now()-interval '10 minutes' or (not rider.is_available and active_route.id is null) then raise exception 'UP_CAR: Entregador não está online ou compatível.';end if;
  if active_route.id is not null then
   group_id:=coalesce(active_route.route_group_id,gen_random_uuid());
   if active_route.route_group_id is null then update public.vuppi_deliveries set route_group_id=group_id,route_sequence=1,updated_at=now() where id=active_route.id;end if;
   select coalesce(max(route_sequence),0)+1 into next_sequence from public.vuppi_deliveries where route_group_id=group_id;
   update public.vuppi_deliveries set courier=rider.user_id,status='assigned',route_group_id=group_id,route_sequence=next_sequence,accepted_from='merchant_route_append',updated_at=now() where id=d.id;
  else
   update public.vuppi_deliveries set courier=rider.user_id,status='assigned',accepted_from='merchant_assignment',updated_at=now() where id=d.id;
  end if;
  update public.vuppi_members set is_available=false,updated_at=now() where user_id=rider.user_id;
  insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details) values(d.id,uid,'merchant_assigned',jsonb_build_object('courier_id',rider.user_id,'route_group_id',group_id,'appended',active_route.id is not null));
 elsif p_action='edit' then
  if d.status<>'requested' then raise exception 'UP_CAR: A edição fica disponível antes do aceite do entregador.';end if;
  lead:=greatest(0,least(99,coalesce(nullif(p_data->>'dispatch_minutes','')::int,10)));
  if p_data->>'dispatch_mode'='schedule' then requested_at:=nullif(p_data->>'scheduled_for','')::timestamptz;elsif p_data->>'dispatch_mode'='minutes' then requested_at:=now()+make_interval(mins=>lead);else requested_at:=null;end if;
  if requested_at is not null and requested_at<now()+interval '1 minute' then raise exception 'UP_CAR: Escolha um horário futuro para o despacho.';end if;
  update public.vuppi_deliveries set recipient=left(trim(coalesce(p_data->>'recipient',recipient)),100),phone=left(trim(coalesce(p_data->>'phone',phone)),30),external_order_number=nullif(left(trim(p_data->>'external_order_number'),60),''),notes=nullif(left(trim(p_data->>'notes'),500),''),scheduled_for=requested_at,dispatch_at=requested_at,updated_at=now() where id=d.id;
 elsif p_action='optimize' then
  if d.route_group_id is null then update public.vuppi_deliveries set route_group_id=group_id,route_sequence=1,updated_at=now() where id=d.id;
  else select array_agg(value::uuid) into ids from jsonb_array_elements_text(coalesce(p_data->'ordered_ids','[]'::jsonb));if coalesce(array_length(ids,1),0)<>(select count(*) from public.vuppi_deliveries where route_group_id=d.route_group_id) or exists(select 1 from unnest(ids)x left join public.vuppi_deliveries v on v.id=x where v.id is null or v.route_group_id<>d.route_group_id or v.merchant<>uid) then raise exception 'UP_CAR: A sequência otimizada é inválida.';end if;update public.vuppi_deliveries set route_sequence=x.seq,updated_at=now() from(select id,ord::int seq from unnest(ids)with ordinality as t(id,ord))x where vuppi_deliveries.id=x.id;end if;
 else raise exception 'UP_CAR: Operação desconhecida.';end if;
 insert into public.up_platform_audit(actor_id,action,target,reason,details) values(uid,'merchant_delivery_'||p_action,d.id::text,'Gestão do pedido pelo estabelecimento',coalesce(p_data,'{}'::jsonb));
 return jsonb_build_object('ok',true,'delivery_id',d.id,'route_group_id',group_id);
end;$$;

-- A chave integral fica numa tabela separada e inacessível ao cliente. A tabela
-- pública de saques continua contendo apenas pix_key_masked.
create table if not exists public.vuppi_withdrawal_payout_secrets(
 withdrawal_id uuid primary key references public.vuppi_withdrawals(id) on delete cascade,
 pix_key text not null,
 pix_type text not null check(pix_type in('EMAIL','PHONE','CPF','CNPJ','PIX_CODE')),
 created_at timestamptz not null default now()
);
alter table public.vuppi_withdrawal_payout_secrets enable row level security;
revoke all on public.vuppi_withdrawal_payout_secrets from anon,authenticated;

create or replace function public.vuppi_withdrawal_store_pix(p_id uuid,p_key text,p_type text) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'VUPPI_FINANCE: Serviço não autorizado.';end if;
 if length(trim(coalesce(p_key,'')))<5 or p_type not in('EMAIL','PHONE','CPF','CNPJ','PIX_CODE') then raise exception 'VUPPI_FINANCE: Chave Pix inválida.';end if;
 if not exists(select 1 from public.vuppi_withdrawals where id=p_id and status='requested') then raise exception 'VUPPI_FINANCE: Saque não encontrado para vincular Pix.';end if;
 insert into public.vuppi_withdrawal_payout_secrets(withdrawal_id,pix_key,pix_type) values(p_id,trim(p_key),p_type)
 on conflict(withdrawal_id) do update set pix_key=excluded.pix_key,pix_type=excluded.pix_type;
end;$$;

create or replace function public.vuppi_withdrawal_payout_payload(p_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare w public.vuppi_withdrawals;s public.vuppi_withdrawal_payout_secrets;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'VUPPI_FINANCE: Serviço não autorizado.';end if;
 select * into w from public.vuppi_withdrawals where id=p_id and status='processing' for update;
 if w.id is null then raise exception 'VUPPI_FINANCE: Saque não está pronto para envio.';end if;
 select * into s from public.vuppi_withdrawal_payout_secrets where withdrawal_id=w.id;
 if s.withdrawal_id is null then raise exception 'VUPPI_FINANCE: Chave Pix integral ausente. Recuse esta solicitação antiga e peça um novo saque.';end if;
 return jsonb_build_object('id',w.id,'net_cents',w.net_cents,'pix_key',s.pix_key,'pix_type',s.pix_type,'provider_reference',w.provider_reference,'metadata',w.metadata);
end;$$;

create or replace function public.vuppi_withdrawal_payout_submitted(p_id uuid,p_payout text,p_transaction text,p_status text,p_details jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'VUPPI_FINANCE: Serviço não autorizado.';end if;
 update public.vuppi_withdrawals set provider='mercadopago',provider_reference=p_payout,metadata=metadata||jsonb_build_object('payout_id',p_payout,'transaction_id',p_transaction,'provider_status',p_status,'provider_details',p_details,'submitted_at',now()) where id=p_id and status='processing';
 return jsonb_build_object('ok',found,'status','processing');
end;$$;

create or replace function public.vuppi_withdrawal_payout_finalize(p_id uuid,p_status text,p_details jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare w public.vuppi_withdrawals;platform_wallet uuid;city_id text;available_id uuid;reserved_id uuid;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'VUPPI_FINANCE: Serviço não autorizado.';end if;
 select * into w from public.vuppi_withdrawals where id=p_id for update;if w.id is null then raise exception 'VUPPI_FINANCE: Saque não encontrado.';end if;
 if w.status='paid' then return jsonb_build_object('ok',true,'status','paid');end if;
 if w.status<>'processing' then raise exception 'VUPPI_FINANCE: Saque não está em processamento.';end if;
 select city into city_id from public.vuppi_wallets where id=w.wallet_id;select id into reserved_id from public.vuppi_wallet_accounts where wallet_id=w.wallet_id and bucket='reserved';select id into available_id from public.vuppi_wallet_accounts where wallet_id=w.wallet_id and bucket='available';
 if p_status='success' then
  platform_wallet:=public.vuppi_wallet_ensure('platform',null,city_id,'delivery');
  perform public.vuppi_post_transaction('withdrawal_paid',city_id,w.net_cents,reserved_id,(select id from public.vuppi_wallet_accounts where wallet_id=platform_wallet and bucket='pending'),'withdrawal-paid:'||w.id,'Saque Pix liquidado',jsonb_build_object('courier_id',w.requested_by,'provider','mercadopago'));
  if w.fee_cents>0 then perform public.vuppi_post_transaction('withdrawal_fee',city_id,w.fee_cents,reserved_id,(select id from public.vuppi_wallet_accounts where wallet_id=platform_wallet and bucket='available'),'withdrawal-fee:'||w.id,'Taxa de saque','{}');end if;
  update public.vuppi_withdrawals set status='paid',processed_at=now(),metadata=metadata||p_details||jsonb_build_object('provider_status','success','settled_at',now()) where id=w.id;delete from public.vuppi_withdrawal_payout_secrets where withdrawal_id=w.id;
 else
  perform public.vuppi_post_transaction('withdrawal_provider_failed',city_id,w.amount_cents,reserved_id,available_id,'withdrawal-provider-failed:'||w.id,'Falha no envio Pix',jsonb_build_object('courier_id',w.requested_by,'provider','mercadopago'));
  update public.vuppi_withdrawals set status='failed',processed_at=now(),reason=coalesce(p_details->>'message','Transferência Pix recusada pelo provedor'),metadata=metadata||p_details||jsonb_build_object('provider_status',p_status) where id=w.id;delete from public.vuppi_withdrawal_payout_secrets where withdrawal_id=w.id;
 end if;
 return jsonb_build_object('ok',true,'status',case when p_status='success' then 'paid' else 'failed' end);
end;$$;

-- Evita que a chave integral passe a ser serializada pelo select * legado.
create or replace function public.vuppi_withdrawal_public(p_id uuid) returns jsonb
language sql security definer set search_path=public,pg_temp as $$
 select to_jsonb(x) from(select id,wallet_id,amount_cents,fee_cents,net_cents,status,pix_key_masked,provider,provider_reference,idempotency_key,requested_by,reviewed_by,reason,created_at,processed_at,metadata from public.vuppi_withdrawals where id=p_id)x;
$$;

revoke all on function public.vuppi_validate_courier_active_route(),public.vuppi_merchant_manage_delivery(text,uuid,jsonb) from public,anon;
grant execute on function public.vuppi_merchant_manage_delivery(text,uuid,jsonb) to authenticated;
revoke all on function public.vuppi_withdrawal_store_pix(uuid,text,text),public.vuppi_withdrawal_payout_payload(uuid),public.vuppi_withdrawal_payout_submitted(uuid,text,text,text,jsonb),public.vuppi_withdrawal_payout_finalize(uuid,text,jsonb),public.vuppi_withdrawal_public(uuid) from public,anon,authenticated;
grant execute on function public.vuppi_withdrawal_store_pix(uuid,text,text),public.vuppi_withdrawal_payout_payload(uuid),public.vuppi_withdrawal_payout_submitted(uuid,text,text,text,jsonb),public.vuppi_withdrawal_payout_finalize(uuid,text,jsonb),public.vuppi_withdrawal_public(uuid) to service_role;
commit;
