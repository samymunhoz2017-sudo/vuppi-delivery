-- VUPPI 0.78: reconciliação de OS encerrada, split único e saneamento de saques.
begin;

alter table public.vuppi_deliveries add column if not exists courier_net_cents integer not null default 0;
alter table public.vuppi_deliveries add column if not exists financial_applied_price_cents integer not null default 0;
alter table public.vuppi_deliveries add column if not exists financial_applied_courier_cents integer not null default 0;
alter table public.vuppi_deliveries add column if not exists financial_applied_platform_cents integer not null default 0;
alter table public.vuppi_deliveries add column if not exists financial_revision integer not null default 0;
alter table public.vuppi_members add column if not exists state_registration text;
alter table public.vuppi_members add column if not exists responsible_name text;
alter table public.vuppi_members add column if not exists responsible_document text;
alter table public.vuppi_members add column if not exists contact_email text;
alter table public.vuppi_members add column if not exists cep text;
alter table public.vuppi_members add column if not exists address_number text;
alter table public.vuppi_members add column if not exists address_complement text;
alter table public.vuppi_members add column if not exists district text;
alter table public.vuppi_members add column if not exists proof_of_delivery_required boolean not null default false;
alter table public.vuppi_members add column if not exists pickup_code_required boolean not null default false;
alter table public.vuppi_members add column if not exists max_delivery_stops integer not null default 10;

create or replace function public.vuppi_post_reconciliation(p_type text,p_delivery public.vuppi_deliveries,p_amount bigint,p_debit uuid,p_credit uuid,p_key text,p_description text,p_reason text) returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare tid uuid;db bigint;cb bigint;
begin
 if p_amount<=0 then return null;end if;
 select id into tid from public.vuppi_financial_transactions where city=p_delivery.city and product='delivery' and idempotency_key=p_key;
 if tid is not null then return tid;end if;
 perform 1 from public.vuppi_wallet_accounts where id in(p_debit,p_credit) order by id for update;
 select balance_cents into db from public.vuppi_wallet_accounts where id=p_debit;
 select balance_cents into cb from public.vuppi_wallet_accounts where id=p_credit;
 if db is null or cb is null then raise exception 'VUPPI_FINANCE: Conta de reconciliação inválida.';end if;
 insert into public.vuppi_financial_transactions(type,status,city,amount_cents,delivery_id,merchant_id,courier_id,actor_id,description,reason,metadata,idempotency_key,posted_at)
 values(p_type,'posted',p_delivery.city,p_amount,p_delivery.id,p_delivery.merchant,p_delivery.courier,auth.uid(),p_description,p_reason,jsonb_build_object('delivery_id',p_delivery.id,'revision',p_delivery.financial_revision+1,'corrective',true),p_key,now()) returning id into tid;
 update public.vuppi_wallet_accounts set balance_cents=balance_cents-p_amount,updated_at=now() where id=p_debit;
 update public.vuppi_wallet_accounts set balance_cents=balance_cents+p_amount,updated_at=now() where id=p_credit;
 insert into public.vuppi_ledger_entries(transaction_id,account_id,direction,amount_cents,balance_before_cents,balance_after_cents)
 values(tid,p_debit,'debit',p_amount,db,db-p_amount),(tid,p_credit,'credit',p_amount,cb,cb+p_amount);
 return tid;
end;$$;

create or replace function public.vuppi_reconcile_delivered_price(p_delivery public.vuppi_deliveries,p_new_price integer,p_reason text) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare cfg public.vuppi_finance_settings;mw uuid;cw uuid;pw uuid;merchant_available uuid;courier_available uuid;platform_available uuid;desired_courier bigint;desired_platform bigint;dc bigint;dp bigint;revision integer:=p_delivery.financial_revision+1;
begin
 if p_delivery.status<>'delivered' or p_delivery.courier is null then return;end if;
 insert into public.vuppi_finance_settings(city) values(p_delivery.city) on conflict do nothing;
 select * into cfg from public.vuppi_finance_settings where city=p_delivery.city;
 desired_courier:=floor(p_new_price*cfg.courier_share_bps::numeric/10000);desired_platform:=p_new_price-desired_courier;
 cw:=public.vuppi_wallet_ensure('courier',p_delivery.courier,p_delivery.city,'delivery');pw:=public.vuppi_wallet_ensure('platform',null,p_delivery.city,'delivery');
 select id into courier_available from public.vuppi_wallet_accounts where wallet_id=cw and bucket='available';
 select id into platform_available from public.vuppi_wallet_accounts where wallet_id=pw and bucket='available';
 if p_delivery.payment_method='wallet' then
  mw:=public.vuppi_wallet_ensure('merchant',p_delivery.merchant,p_delivery.city,'delivery');select id into merchant_available from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available';
  dc:=desired_courier-p_delivery.financial_applied_courier_cents;dp:=desired_platform-p_delivery.financial_applied_platform_cents;
  if dc>0 then perform public.vuppi_post_reconciliation('delivery_courier_adjustment',p_delivery,dc,merchant_available,courier_available,'delivery-reconcile-courier:'||p_delivery.id||':'||revision,'Ajuste do repasse da OS',p_reason);
  elsif dc<0 then perform public.vuppi_post_reconciliation('delivery_courier_reversal',p_delivery,-dc,courier_available,merchant_available,'delivery-reconcile-courier:'||p_delivery.id||':'||revision,'Estorno do repasse da OS',p_reason);end if;
  if dp>0 then perform public.vuppi_post_reconciliation('delivery_platform_adjustment',p_delivery,dp,merchant_available,platform_available,'delivery-reconcile-platform:'||p_delivery.id||':'||revision,'Ajuste da receita da OS',p_reason);
  elsif dp<0 then perform public.vuppi_post_reconciliation('delivery_platform_reversal',p_delivery,-dp,platform_available,merchant_available,'delivery-reconcile-platform:'||p_delivery.id||':'||revision,'Estorno da receita da OS',p_reason);end if;
 else
  -- Em dinheiro o cliente paga o entregador. Só a margem VUPPI circula na carteira.
  dp:=desired_platform-p_delivery.financial_applied_platform_cents;
  if dp>0 then perform public.vuppi_post_reconciliation('cash_platform_adjustment',p_delivery,dp,courier_available,platform_available,'delivery-reconcile-cash:'||p_delivery.id||':'||revision,'Ajuste da taxa da OS em dinheiro',p_reason);
  elsif dp<0 then perform public.vuppi_post_reconciliation('cash_platform_reversal',p_delivery,-dp,platform_available,courier_available,'delivery-reconcile-cash:'||p_delivery.id||':'||revision,'Estorno da taxa da OS em dinheiro',p_reason);end if;
 end if;
 update public.vuppi_deliveries set price_cents=p_new_price,courier_net_cents=desired_courier,financial_applied_price_cents=p_new_price,financial_applied_courier_cents=desired_courier,financial_applied_platform_cents=desired_platform,financial_revision=revision,updated_at=now() where id=p_delivery.id;
end;$$;

-- O dinheiro obedece exatamente à mesma divisão configurada para a cidade.
create or replace function public.vuppi_delivery_wallet_sync() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare mw uuid;cw uuid;pw uuid;share bigint;margin bigint;cfg public.vuppi_finance_settings;reserve_exists boolean;
begin
 if tg_op='INSERT' and new.payment_method<>'wallet' then return new;end if;
 insert into public.vuppi_finance_settings(city) values(new.city) on conflict do nothing;select * into cfg from public.vuppi_finance_settings where city=new.city;
 if tg_op='UPDATE' and old.payment_method<>'wallet' and new.payment_method<>'wallet' then
  if old.status is distinct from new.status and new.status='delivered' and new.payment_method='cash' then
   share:=floor(new.price_cents*cfg.courier_share_bps::numeric/10000);margin:=new.price_cents-share;perform public.vuppi_post_cash_platform_fee(new,margin);
   update public.vuppi_deliveries set courier_net_cents=share,financial_applied_price_cents=new.price_cents,financial_applied_courier_cents=share,financial_applied_platform_cents=margin where id=new.id;
  end if;return new;
 end if;
 mw:=public.vuppi_wallet_ensure('merchant',new.merchant,new.city,'delivery');pw:=public.vuppi_wallet_ensure('platform',null,new.city,'delivery');
 if tg_op='INSERT' or (tg_op='UPDATE' and old.payment_method<>'wallet' and new.payment_method='wallet') then
  perform public.vuppi_post_transaction('delivery_reserve',new.city,new.price_cents,(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),'delivery-reserve:'||new.id,'Reserva da OS',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant));
 elsif tg_op='UPDATE' and old.status is distinct from new.status and new.status='cancelled' and new.payment_method='wallet' then
  perform public.vuppi_post_transaction('delivery_release',new.city,new.price_cents,(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),'delivery-release:'||new.id,'Liberação por cancelamento',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant));
 elsif tg_op='UPDATE' and old.status is distinct from new.status and new.status='delivered' and new.payment_method='wallet' then
  cw:=public.vuppi_wallet_ensure('courier',new.courier,new.city,'delivery');share:=floor(new.price_cents*cfg.courier_share_bps::numeric/10000);margin:=new.price_cents-share;
  select exists(select 1 from public.vuppi_financial_transactions where city=new.city and idempotency_key='delivery-reserve:'||new.id) into reserve_exists;
  if not reserve_exists then perform public.vuppi_post_transaction('delivery_reserve',new.city,new.price_cents,(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),'delivery-reserve:'||new.id,'Reserva reconciliada',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant));end if;
  if share>0 then perform public.vuppi_post_transaction('delivery_courier_credit',new.city,share,(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),(select id from public.vuppi_wallet_accounts where wallet_id=cw and bucket=case when cfg.courier_release_delay_minutes>0 then 'pending'::public.vuppi_balance_bucket else 'available'::public.vuppi_balance_bucket end),'delivery-courier:'||new.id,'Crédito da entrega',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant,'courier_id',new.courier));end if;
  if margin>0 then perform public.vuppi_post_transaction('delivery_platform_revenue',new.city,margin,(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),(select id from public.vuppi_wallet_accounts where wallet_id=pw and bucket='available'),'delivery-margin:'||new.id,'Receita da entrega',jsonb_build_object('delivery_id',new.id,'merchant_id',new.merchant,'courier_id',new.courier));end if;
  update public.vuppi_deliveries set courier_net_cents=share,financial_applied_price_cents=new.price_cents,financial_applied_courier_cents=share,financial_applied_platform_cents=margin where id=new.id;
 end if;return new;
end;$$;

create or replace function public.vuppi_admin_manage_delivery(p_action text,p_delivery uuid,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.vuppi_deliveries;old_courier uuid;new_price integer;delta bigint;mw uuid;actor uuid:=auth.uid();reason text:=coalesce(nullif(trim(p_data->>'reason'),''),'Correção administrativa da OS');
begin
 if not public.up_platform_is_admin() then raise exception 'UP_CAR: Acesso exclusivo do administrador.';end if;select * into d from public.vuppi_deliveries where id=p_delivery for update;if d.id is null then raise exception 'UP_CAR: Entrega não encontrada.';end if;
 if p_action='edit' then
  if d.status not in('requested','assigned','collected','delivered') then raise exception 'UP_CAR: Esta OS não pode ser alterada.';end if;
  new_price:=greatest(0,least(1000000,coalesce(nullif(p_data->>'price_cents','')::integer,d.price_cents)));
  if d.status='delivered' then perform public.vuppi_reconcile_delivered_price(d,new_price,reason);
  else
   if d.payment_method='wallet' and new_price<>d.price_cents then mw:=public.vuppi_wallet_ensure('merchant',d.merchant,d.city,'delivery');delta:=new_price-d.price_cents;if delta>0 then perform public.vuppi_post_transaction('delivery_price_increase',d.city,delta,(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),'delivery-price-increase:'||d.id||':'||new_price,'Aumento do valor da OS',jsonb_build_object('delivery_id',d.id,'merchant_id',d.merchant,'reason',reason));elsif delta<0 then perform public.vuppi_post_transaction('delivery_price_decrease',d.city,-delta,(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='reserved'),(select id from public.vuppi_wallet_accounts where wallet_id=mw and bucket='available'),'delivery-price-decrease:'||d.id||':'||new_price,'Redução do valor da OS',jsonb_build_object('delivery_id',d.id,'merchant_id',d.merchant,'reason',reason));end if;end if;
   update public.vuppi_deliveries set price_cents=new_price,updated_at=now() where id=d.id;
  end if;
  update public.vuppi_deliveries set recipient=left(trim(coalesce(nullif(p_data->>'recipient',''),recipient)),100),phone=left(trim(coalesce(nullif(p_data->>'phone',''),phone)),30),external_order_number=coalesce(nullif(left(trim(p_data->>'external_order_number'),60),''),external_order_number),notes=nullif(left(trim(coalesce(p_data->>'notes',notes)),500),''),cash_to_collect_cents=greatest(0,least(1000000,coalesce(nullif(p_data->>'cash_to_collect_cents','')::integer,cash_to_collect_cents))),updated_at=now() where id=d.id returning * into d;
 elsif p_action='redistribute' then old_courier:=d.courier;update public.vuppi_deliveries set courier=null,status='requested',pickup_arrived_at=null,redistributed_count=redistributed_count+1,last_redistributed_at=now(),last_redistributed_by=actor,updated_at=now() where id=d.id returning * into d;if old_courier is not null then update public.vuppi_members set is_available=true,updated_at=now() where user_id=old_courier;end if;
 elsif p_action='record_issue' then if length(trim(coalesce(p_data->>'reason','')))<3 then raise exception 'UP_CAR: Descreva a ocorrência.';end if;
 elsif p_action='finalize' then update public.vuppi_deliveries set status='delivered',updated_at=now() where id=d.id returning * into d;update public.vuppi_members set is_available=true,updated_at=now() where user_id=d.courier;
 else raise exception 'UP_CAR: Ação administrativa de OS inválida.';end if;
 insert into public.up_platform_audit(actor_id,action,target,reason,details) values(actor,'delivery_admin_'||p_action,d.id::text,reason,p_data||jsonb_build_object('status',d.status));insert into public.vuppi_delivery_events(delivery_id,actor_id,event_type,details) values(d.id,actor,'admin_'||p_action,p_data||jsonb_build_object('status',d.status));return to_jsonb(d);
end;$$;

create or replace function public.vuppi_withdrawal_clear_stale() returns integer
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();wid uuid;affected integer:=0;w public.vuppi_withdrawals;available_id uuid;reserved_id uuid;
begin
 select id into wid from public.vuppi_wallets where owner_type='courier' and owner_id=uid and product='delivery' order by created_at desc limit 1;
 for w in select * from public.vuppi_withdrawals where wallet_id=wid and status in('requested','under_review','processing','reconciliation_required') and (processed_at is not null or lower(coalesce(reason,'')) similar to '%(cancel|rejeit|recus)%') for update loop
  select id into available_id from public.vuppi_wallet_accounts where wallet_id=wid and bucket='available';select id into reserved_id from public.vuppi_wallet_accounts where wallet_id=wid and bucket='reserved';
  if (select balance_cents from public.vuppi_wallet_accounts where id=reserved_id)>=w.amount_cents then perform public.vuppi_post_transaction('withdrawal_stale_release',(select city from public.vuppi_wallets where id=wid),w.amount_cents,reserved_id,available_id,'withdrawal-stale-release:'||w.id,'Liberação automática de saque cancelado',jsonb_build_object('courier_id',uid));end if;
  update public.vuppi_withdrawals set status='rejected',processed_at=coalesce(processed_at,now()),reason=coalesce(reason,'Cancelado anteriormente pela central') where id=w.id;affected:=affected+1;
 end loop;return affected;
end;$$;

revoke all on function public.vuppi_post_reconciliation(text,public.vuppi_deliveries,bigint,uuid,uuid,text,text,text),public.vuppi_reconcile_delivered_price(public.vuppi_deliveries,integer,text) from public,anon,authenticated;
revoke all on function public.vuppi_withdrawal_clear_stale() from public,anon;grant execute on function public.vuppi_withdrawal_clear_stale() to authenticated;
grant execute on function public.vuppi_admin_manage_delivery(text,uuid,jsonb) to authenticated;
commit;
