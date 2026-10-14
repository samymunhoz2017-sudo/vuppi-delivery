-- VUPPI 0.65: gestão operacional e carteira atômica.
begin;

alter table public.vuppi_deliveries
 add column if not exists redistributed_count integer not null default 0,
 add column if not exists last_redistributed_at timestamptz,
 add column if not exists last_redistributed_by uuid references auth.users(id);

create or replace function public.vuppi_create_delivery_transaction(p_data jsonb) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.vuppi_deliveries;
begin
 if auth.uid() is null then raise exception 'UP_CAR: Entre para continuar.'; end if;
 if nullif(p_data->>'quote_id','') is null then raise exception 'UP_CAR: Cotação não informada.'; end if;
 if public.up_platform_is_admin() and nullif(p_data->>'merchant','') is not null then
  perform public.vuppi_admin_create_delivery(p_data);
 else
  perform public.vuppi_delivery('create',p_data);
 end if;
 -- Forma de pagamento e reserva são aplicadas na mesma transação da criação.
 perform public.vuppi_delivery_details((p_data->>'quote_id')::uuid,p_data);
 select * into d from public.vuppi_deliveries where quote_id=(p_data->>'quote_id')::uuid;
 return to_jsonb(d);
end;$$;

create or replace function public.vuppi_delivery_wallet_sync() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare mw uuid;cw uuid;pw uuid;share bigint;margin bigint;cfg public.vuppi_finance_settings;reserve_exists boolean;
begin
 if tg_op='INSERT' and new.payment_method<>'wallet' then return new; end if;
 if tg_op='UPDATE' and old.payment_method<>'wallet' and new.payment_method<>'wallet' then return new; end if;
 insert into public.vuppi_finance_settings(city) values(new.city) on conflict do nothing;
 select * into cfg from public.vuppi_finance_settings where city=new.city;
 mw:=public.vuppi_wallet_ensure('merchant',new.merchant,new.city,'delivery');
 pw:=public.vuppi_wallet_ensure('platform',null,new.city,'delivery');
 if tg_op='INSERT' or (tg_op='UPDATE' and old.payment_method<>'wallet' and new.payment_method='wallet') then
  perform public.vuppi_post_transaction('delivery_reserve',new.city,new.price_cents,
   (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),
   (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),
   'delivery-reserve:'||new.id,'Reserva da OS',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant));
 elsif tg_op='UPDATE' and old.payment_method='wallet' and new.payment_method<>'wallet' and old.status not in ('delivered','cancelled') then
  perform public.vuppi_post_transaction('delivery_release',new.city,old.price_cents,
   (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),
   (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),
   'delivery-payment-release:'||new.id,'Liberação por troca de pagamento',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant));
 elsif tg_op='UPDATE' and old.status is distinct from new.status and new.status='cancelled' and new.payment_method='wallet' then
  perform public.vuppi_post_transaction('delivery_release',new.city,new.price_cents,
   (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),
   (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),
   'delivery-release:'||new.id,'Liberação por cancelamento',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant));
 elsif tg_op='UPDATE' and old.status is distinct from new.status and new.status='delivered' and new.payment_method='wallet' then
  if new.courier is null then raise exception 'VUPPI_FINANCE: Entrega sem entregador não pode ser liquidada.'; end if;
  -- Corridas criadas antes da reserva atomica chegavam ao fim sem saldo no bucket
  -- reservado. Reconcilia uma unica vez dentro da mesma transacao que conclui a OS.
  select exists(
   select 1 from public.vuppi_financial_transactions
   where city=new.city and product='delivery' and idempotency_key='delivery-reserve:'||new.id
  ) into reserve_exists;
  if not reserve_exists then
   perform public.vuppi_post_transaction('delivery_reserve',new.city,new.price_cents,
    (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),
    (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),
    'delivery-reserve:'||new.id,'Reserva reconciliada na conclusão da OS',
    jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant,'reconciled_on_completion',true));
  end if;
  cw:=public.vuppi_wallet_ensure('courier',new.courier,new.city,'delivery');
  share:=floor(new.price_cents*cfg.courier_share_bps::numeric/10000); margin:=new.price_cents-share;
  if share>0 then
   perform public.vuppi_post_transaction('delivery_courier_credit',new.city,share,
    (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),
    (select id from public.vuppi_wallet_accounts where wallet_id=cw and bucket=case when cfg.courier_release_delay_minutes>0 then 'pending'::public.vuppi_balance_bucket else 'available'::public.vuppi_balance_bucket end),
    'delivery-courier:'||new.id,'Crédito da entrega',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant,'courier_id',new.courier));
  end if;
  if margin>0 then
   perform public.vuppi_post_transaction('delivery_platform_revenue',new.city,margin,
    (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),
    (select id from public.vuppi_wallet_accounts where wallet_id=pw and bucket='available'),
    'delivery-margin:'||new.id,'Receita da entrega',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant,'courier_id',new.courier));
  end if;
 end if;
 return new;
end;$$;

drop trigger if exists vuppi_delivery_wallet_after_insert on public.vuppi_deliveries;
drop trigger if exists vuppi_delivery_wallet_after_update on public.vuppi_deliveries;
create trigger vuppi_delivery_wallet_after_insert after insert on public.vuppi_deliveries
 for each row execute function public.vuppi_delivery_wallet_sync();
create trigger vuppi_delivery_wallet_after_update after update of status,payment_method on public.vuppi_deliveries
 for each row execute function public.vuppi_delivery_wallet_sync();

create or replace function public.vuppi_admin_wallet_adjust(
 p_wallet uuid,p_direction text,p_amount_cents bigint,p_reason text,p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare w public.vuppi_wallets;pw uuid;tx uuid;available bigint;
begin
 if not public.up_platform_is_admin() then raise exception 'UP_CAR: Acesso exclusivo do administrador.'; end if;
 if p_direction not in ('credit','debit') then raise exception 'VUPPI_FINANCE: Tipo de ajuste inválido.'; end if;
 if p_amount_cents<1 or p_amount_cents>100000000 then raise exception 'VUPPI_FINANCE: Valor do ajuste inválido.'; end if;
 if length(trim(coalesce(p_reason,'')))<3 then raise exception 'VUPPI_FINANCE: Informe o motivo do ajuste.'; end if;
 if length(trim(coalesce(p_idempotency_key,'')))<8 then raise exception 'VUPPI_FINANCE: Chave de segurança inválida.'; end if;
 select * into w from public.vuppi_wallets where id=p_wallet and owner_type in ('merchant','courier') for update;
 if w.id is null then raise exception 'VUPPI_FINANCE: Carteira não encontrada.'; end if;
 pw:=public.vuppi_wallet_ensure('platform',null,w.city,'delivery');
 if p_direction='credit' then
  tx:=public.vuppi_post_transaction('manual_credit',w.city,p_amount_cents,
   (select id from public.vuppi_wallet_accounts where wallet_id=pw and bucket='available'),
   (select id from public.vuppi_wallet_accounts where wallet_id=w.id and bucket='available'),
   'manual-credit:'||p_idempotency_key,'Crédito manual',jsonb_build_object('reason',trim(p_reason),'wallet_id',w.id));
 else
  select balance_cents into available from public.vuppi_wallet_accounts where wallet_id=w.id and bucket='available' for update;
  if coalesce(available,0)<p_amount_cents then raise exception 'VUPPI_FINANCE: Saldo disponível insuficiente para o débito.'; end if;
  tx:=public.vuppi_post_transaction('manual_debit',w.city,p_amount_cents,
   (select id from public.vuppi_wallet_accounts where wallet_id=w.id and bucket='available'),
   (select id from public.vuppi_wallet_accounts where wallet_id=pw and bucket='available'),
   'manual-debit:'||p_idempotency_key,'Débito manual',jsonb_build_object('reason',trim(p_reason),'wallet_id',w.id));
 end if;
 insert into public.vuppi_financial_audit(actor_id,action,target_type,target_id,city,reason,details)
 values(auth.uid(),'admin_wallet_'||p_direction,'wallet',w.id::text,w.city,trim(p_reason),jsonb_build_object('amount_cents',p_amount_cents,'transaction_id',tx));
 return jsonb_build_object('ok',true,'transaction_id',tx,'wallet_id',w.id,'direction',p_direction,'amount_cents',p_amount_cents);
end;$$;

create or replace function public.vuppi_admin_manage_delivery(p_action text,p_delivery uuid,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.vuppi_deliveries;old_courier uuid;new_price integer;delta bigint;mw uuid;actor uuid:=auth.uid();
begin
 if not public.up_platform_is_admin() then raise exception 'UP_CAR: Acesso exclusivo do administrador.'; end if;
 select * into d from public.vuppi_deliveries where id=p_delivery for update;
 if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.'; end if;
 if p_action='edit' then
  if d.status not in ('requested','assigned') then raise exception 'UP_CAR: Uma OS em rota ou encerrada não pode ter valor alterado.'; end if;
  new_price:=greatest(800,least(1000000,coalesce(nullif(p_data->>'price_cents','')::integer,d.price_cents)));
  if d.payment_method='wallet' and new_price<>d.price_cents then
   mw:=public.vuppi_wallet_ensure('merchant',d.merchant,d.city,'delivery'); delta:=new_price-d.price_cents;
   if delta>0 then
    perform public.vuppi_post_transaction('delivery_price_increase',d.city,delta,
     (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),
     (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),
     'delivery-price-increase:'||d.id||':'||new_price,'Aumento do valor da OS',jsonb_build_object('delivery_id',d.id,'merchant_id',d.merchant,'reason',p_data->>'reason'));
   else
    perform public.vuppi_post_transaction('delivery_price_decrease',d.city,-delta,
     (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),
     (select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),
     'delivery-price-decrease:'||d.id||':'||new_price,'Redução do valor da OS',jsonb_build_object('delivery_id',d.id,'merchant_id',d.merchant,'reason',p_data->>'reason'));
   end if;
  end if;
  update public.vuppi_deliveries set
   recipient=left(trim(coalesce(nullif(p_data->>'recipient',''),recipient)),100),
   phone=left(trim(coalesce(nullif(p_data->>'phone',''),phone)),30),
   external_order_number=coalesce(nullif(left(trim(p_data->>'external_order_number'),60),''),external_order_number),
   notes=nullif(left(trim(coalesce(p_data->>'notes',notes)),500),''),
   cash_to_collect_cents=greatest(0,least(1000000,coalesce(nullif(p_data->>'cash_to_collect_cents','')::integer,cash_to_collect_cents))),
   price_cents=new_price,updated_at=now() where id=d.id returning * into d;
 elsif p_action='redistribute' then
  if d.status not in ('assigned','collected') then raise exception 'UP_CAR: Apenas entregas aceitas ou em andamento podem ser redistribuídas.'; end if;
  old_courier:=d.courier;
  update public.vuppi_deliveries set courier=null,status='requested',pickup_arrived_at=null,
   redistributed_count=redistributed_count+1,last_redistributed_at=now(),last_redistributed_by=actor,updated_at=now()
   where id=d.id returning * into d;
  if old_courier is not null then update public.vuppi_members set is_available=true,updated_at=now() where user_id=old_courier and approved; end if;
 elsif p_action='finalize' then
  if d.status not in ('assigned','collected') or d.courier is null then raise exception 'UP_CAR: A OS precisa ter um entregador antes da finalização.'; end if;
  update public.vuppi_deliveries set status='delivered',updated_at=now() where id=d.id returning * into d;
  update public.vuppi_members set is_available=true,updated_at=now() where user_id=d.courier and approved;
 else raise exception 'UP_CAR: Ação administrativa de OS inválida.';
 end if;
 insert into public.up_platform_audit(actor_id,action,target,reason,details)
 values(actor,'delivery_admin_'||p_action,d.id::text,coalesce(nullif(trim(p_data->>'reason'),''),'Gestão da OS pela central'),p_data||jsonb_build_object('status',d.status));
 insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details)
 values(d.id,actor,'admin_'||p_action,p_data||jsonb_build_object('status',d.status));
 return to_jsonb(d);
end;$$;

revoke all on function public.vuppi_create_delivery_transaction(jsonb),public.vuppi_admin_wallet_adjust(uuid,text,bigint,text,text),public.vuppi_admin_manage_delivery(text,uuid,jsonb) from public,anon;
grant execute on function public.vuppi_create_delivery_transaction(jsonb),public.vuppi_admin_wallet_adjust(uuid,text,bigint,text,text),public.vuppi_admin_manage_delivery(text,uuid,jsonb) to authenticated;

commit;
